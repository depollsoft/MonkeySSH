// Kitty graphics behaviours checked against Kitty's reference implementation
// and the conformance fixes in Ghostty 1.4. Where the two differ, Kitty wins.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/kitty_graphics_validation.dart';
import 'package:xterm/xterm.dart';

Future<Uint8List> _png(int width, int height, {Color? color}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color ?? const Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Future<String> _pngBase64(int width, int height, {Color? color}) async =>
    base64.encode(await _png(width, height, color: color));

/// A 1x1 RGBA pixel, valid for `f=32,s=1,v=1`.
final _pixel = base64.encode(<int>[255, 0, 0, 255]);

Future<void> _until(bool Function() condition) async {
  var waited = 0;
  while (!condition() && waited < 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    waited += 20;
  }
}

Terminal _terminal({List<String>? responses, int width = 40, int height = 12}) {
  final terminal = Terminal(onOutput: responses?.add)..resize(width, height);
  terminal.graphics.setCellPixelSize(10, 20);
  return terminal;
}

/// Stores a 1x1 image under [id] without placing it.
void _store(Terminal terminal, int id) =>
    terminal.write('\x1b_Ga=t,i=$id,f=32,s=1,v=1,q=2;$_pixel\x1b\\');

TerminalImagePlacement? _placementOf(
  Terminal terminal,
  int imageId, {
  int clientPlacementId = 0,
}) {
  for (final placement in terminal.graphics.placements) {
    if (placement.imageId == imageId &&
        (clientPlacementId == 0 ||
            placement.clientPlacementId == clientPlacementId)) {
      return placement;
    }
  }
  return null;
}

void main() {
  group('relative placements', () {
    test('a child sits H/V cells from its parent and leaves the cursor', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b[3;4H\x1b_Ga=p,i=1,p=7,c=2,r=1,C=1,q=2\x1b\\')
        ..write('\x1b[10;10H')
        ..write('\x1b_Ga=p,i=2,p=3,P=1,Q=7,H=2,V=-1,c=1,r=1\x1b\\');

      expect(responses, ['\x1b_Gi=2,p=3;OK\x1b\\']);
      final child = _placementOf(terminal, 2)!;
      expect(child.isRelative, isTrue);
      expect(child.parentImageId, 1);
      expect((col: child.col, row: child.row), (col: 5, row: 1));
      expect(child.attached, isTrue);
      // A relative placement never moves the cursor, whatever C says.
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (9, 9));
      expect(
        terminal.graphics.placementsInRows(terminal.buffer.lines, 1, 1),
        [child],
      );
    });

    test('a child follows its parent when the parent is re-placed', () {
      final terminal = _terminal();
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b[2;2H\x1b_Ga=p,i=1,p=1,c=1,r=1,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,Q=1,H=1,V=1,c=1,r=1,q=2\x1b\\')
        ..write('\x1b[6;8H\x1b_Ga=p,i=1,p=1,c=1,r=1,C=1,q=2\x1b\\');

      final child = _placementOf(terminal, 2)!;
      expect((col: child.col, row: child.row), (col: 8, row: 6));
      expect(terminal.graphics.placements, hasLength(2));
    });

    test('a child scrolls with its parent', () {
      final terminal = _terminal(height: 5);
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b[3;1H\x1b_Ga=p,i=1,c=1,r=1,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,V=1,c=1,r=1,q=2\x1b\\')
        ..write('\x1b[5;1H\n\n');

      final parent = _placementOf(terminal, 1)!;
      final child = _placementOf(terminal, 2)!;
      expect(child.row, parent.row + 1);
      final firstVisible = terminal.buffer.scrollBack;
      expect(parent.row - firstVisible, 0);
    });

    test('deleting a parent deletes its relative placements transitively', () {
      final terminal = _terminal();
      for (var id = 1; id <= 4; id++) {
        _store(terminal, id);
      }
      terminal
        ..write('\x1b_Ga=p,i=1,c=1,r=1,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,H=1,c=1,r=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=3,P=2,H=1,c=1,r=1,q=2\x1b\\')
        ..write('\x1b[5;5H\x1b_Ga=p,i=4,c=1,r=1,C=1,q=2\x1b\\');
      expect(terminal.graphics.placements, hasLength(4));

      terminal.write('\x1b_Ga=d,d=i,i=1,q=2\x1b\\');
      expect(
        terminal.graphics.placements.map((placement) => placement.imageId),
        [4],
      );
      // Lowercase keeps the data of images with an id.
      expect(terminal.graphics.hasPendingImage(2), isTrue);
    });

    test('a missing parent is ENOPARENT', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      _store(terminal, 1);
      _store(terminal, 2);

      terminal.write('\x1b_Ga=p,i=2,P=9\x1b\\');
      expect(
          responses.last, '\x1b_Gi=2;ENOPARENT: parent image not found\x1b\\');

      terminal.write('\x1b_Ga=p,i=2,P=1\x1b\\');
      expect(
        responses.last,
        '\x1b_Gi=2;ENOPARENT: parent placement not found\x1b\\',
      );

      terminal
        ..write('\x1b_Ga=p,i=1,p=4,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,Q=5\x1b\\');
      expect(
        responses.last,
        '\x1b_Gi=2;ENOPARENT: parent placement not found\x1b\\',
      );
      expect(_placementOf(terminal, 2), isNull);
    });

    test('self parents, cycles and deep chains are rejected', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      for (var id = 1; id <= 12; id++) {
        _store(terminal, id);
      }
      terminal.write('\x1b_Ga=p,i=1,p=1,C=1,q=2\x1b\\');

      // A placement cannot name itself as its parent.
      terminal.write('\x1b_Ga=p,i=1,p=1,P=1,Q=1\x1b\\');
      expect(
        responses.last,
        '\x1b_Gi=1,p=1;EINVAL: placement cannot be its own parent\x1b\\',
      );

      // 2 hangs off 1; making 1 hang off 2 would close a loop.
      terminal
        ..write('\x1b_Ga=p,i=2,p=1,P=1,Q=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=1,p=1,P=2,Q=1\x1b\\');
      expect(
        responses.last,
        '\x1b_Gi=1,p=1;ECYCLE: parent chain creates a cycle\x1b\\',
      );
      // The rejected replacement leaves the original placement alone.
      expect(_placementOf(terminal, 1)!.isRelative, isFalse);

      // Eight links are allowed: 3..9 continue the chain from 2.
      for (var id = 3; id <= 9; id++) {
        terminal.write('\x1b_Ga=p,i=$id,p=1,P=${id - 1},Q=1,q=1\x1b\\');
      }
      expect(_placementOf(terminal, 9), isNotNull);
      terminal.write('\x1b_Ga=p,i=10,p=1,P=9,Q=1\x1b\\');
      expect(
        responses.last,
        '\x1b_Gi=10,p=1;ETOODEEP: parent chain too deep\x1b\\',
      );
      expect(_placementOf(terminal, 10), isNull);
    });

    test('a virtual placement cannot be relative', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      _store(terminal, 1);
      terminal.write('\x1b_Ga=p,U=1,i=1,P=1,c=1,r=1\x1b\\');
      expect(
        responses.single,
        '\x1b_Gi=1;EINVAL: virtual placement cannot refer to a parent\x1b\\',
      );
      expect(terminal.graphics.virtualPlacementById(1), isNull);
    });

    test('a child of a virtual placement sits at its placeholder cells', () {
      final terminal = _terminal();
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b_Ga=p,U=1,i=1,c=3,r=2,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,H=1,V=1,c=1,r=1,q=2\x1b\\');

      final child = _placementOf(terminal, 2)!;
      // No placeholder cell shows the image yet: kept, but not placed.
      expect(child.attached, isFalse);

      // Image 1 in an 8-bit foreground color on screen rows 3 and 4, from
      // columns 6 and 5: the virtual placement's origin is (5, 3).
      terminal
        ..write('\x1b[38;5;1m')
        ..write('\x1b[4;7H\u{10EEEE}\u{10EEEE}')
        ..write('\x1b[5;6H\u{10EEEE}\u{10EEEE}\u{10EEEE}')
        ..write('\x1b[m');
      expect(child.attached, isTrue);
      expect((col: child.col, row: child.row), (col: 6, row: 4));

      // Freeing the parent's image and its virtual placement takes the child.
      terminal.write('\x1b_Ga=d,d=I,i=1,q=2\x1b\\');
      expect(_placementOf(terminal, 2), isNull);
    });

    test('a=T with P transmits and places relative to a parent', () async {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      _store(terminal, 1);
      terminal.write('\x1b[2;3H\x1b_Ga=p,i=1,c=2,r=2,C=1,q=2\x1b\\');

      terminal.write(
        '\x1b_Ga=T,i=2,p=5,f=32,s=1,v=1,P=1,H=2;$_pixel\x1b\\',
      );
      expect(responses, ['\x1b_Gi=2,p=5;OK\x1b\\']);
      final child = _placementOf(terminal, 2)!;
      expect((col: child.col, row: child.row), (col: 4, row: 1));
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (2, 1));
    });

    test('retransmitting the parent image deletes relative placements', () {
      final terminal = _terminal();
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b_Ga=p,i=1,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=2,P=1,q=2\x1b\\');
      expect(terminal.graphics.placements, hasLength(2));

      terminal.write(
        '\x1b_Ga=t,i=1,f=32,s=1,v=1,q=2;'
        '${base64.encode(<int>[0, 255, 0, 255])}\x1b\\',
      );
      expect(terminal.graphics.placements, isEmpty);
    });
  });

  group('retransmission', () {
    testWidgets('a=T with an existing id replaces its old placements', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        final red = await _pngBase64(2, 2);
        final blue = await _pngBase64(2, 2, color: const Color(0xFF0000FF));

        terminal.write('\x1b_Ga=T,i=5,f=100,c=2,r=1,q=2;$red\x1b\\');
        await _until(() => terminal.graphics.hasPlacements);
        terminal.write('\x1b[6;1H\x1b_Ga=T,i=5,f=100,c=2,r=1,q=2;$blue\x1b\\');
        await _until(() => _placementOf(terminal, 5)?.row == 5);

        expect(terminal.graphics.placements, hasLength(1));
        expect(terminal.graphics.placements.single.row, 5);

        // Identical bytes replace the placements as well.
        terminal.write('\x1b[9;1H\x1b_Ga=T,i=5,f=100,c=2,r=1,q=2;$blue\x1b\\');
        await _until(() => _placementOf(terminal, 5)?.row == 8);
        expect(terminal.graphics.placements, hasLength(1));
      });
    });

    testWidgets('the old image keeps painting while its replacement decodes', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        final red = await _pngBase64(2, 2);
        final blue = await _pngBase64(2, 2, color: const Color(0xFF0000FF));
        terminal.write('\x1b_Ga=T,i=5,f=100,c=2,r=1,q=2;$red\x1b\\');
        await _until(() => terminal.graphics.hasPlacements);
        final old = terminal.graphics.imageById(5);

        // Hold every decode slot so the replacement cannot finish yet.
        for (var i = 0; i < 3; i++) {
          await terminalGraphicsDecodeGate.acquire();
        }
        try {
          terminal.write(
            '\x1b[6;1H\x1b_Ga=T,i=5,f=100,c=2,r=1,q=2;$blue\x1b\\',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(identical(terminal.graphics.imageById(5), old), isTrue);
          expect(_placementOf(terminal, 5)!.row, 0);
        } finally {
          for (var i = 0; i < 3; i++) {
            terminalGraphicsDecodeGate.release();
          }
        }
        await _until(() => _placementOf(terminal, 5)?.row == 5);
        expect(terminal.graphics.placements, hasLength(1));
        expect(identical(terminal.graphics.imageById(5), old), isFalse);
      });
    });

    test('a=t with an existing id drops the placements of the old image', () {
      final terminal = _terminal();
      _store(terminal, 5);
      terminal
        ..write('\x1b_Ga=p,i=5,c=1,r=1,C=1,q=2\x1b\\')
        ..write('\x1b_Ga=p,U=1,i=5,c=2,r=2,q=2\x1b\\');
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write(
        '\x1b_Ga=t,i=5,f=32,s=1,v=1,q=2;'
        '${base64.encode(<int>[0, 0, 255, 255])}\x1b\\',
      );
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(terminal.graphics.virtualPlacementById(5), isNull);
      expect(terminal.graphics.hasPendingImage(5), isTrue);
    });

    testWidgets('a failed retransmission leaves no stale image', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = _terminal(responses: responses);
        _store(terminal, 5);
        terminal.write('\x1b_Ga=p,i=5,c=1,r=1,C=1,q=2\x1b\\');

        terminal.write('\x1b_Ga=T,i=5,f=100;${base64.encode([1, 2, 3])}\x1b\\');
        await _until(() => responses.isNotEmpty);

        expect(responses.single, startsWith('\x1b_Gi=5;EINVAL'));
        expect(terminal.graphics.hasPendingImage(5), isFalse);
        expect(terminal.graphics.imageById(5), isNull);
        expect(terminal.graphics.hasPlacements, isFalse);
      });
    });

    test('an interrupted retransmission leaves no stale image', () {
      final terminal = _terminal();
      _store(terminal, 5);
      terminal.write('\x1b_Ga=p,i=5,c=1,r=1,C=1,q=2\x1b\\');

      // The final chunk never comes: a new command interrupts the load.
      terminal
        ..write('\x1b_Ga=t,i=5,f=32,s=1,v=1,m=1;AAAA\x1b\\')
        ..write('\x1b_Ga=d,d=z,z=99\x1b\\');

      expect(terminal.graphics.hasPendingImage(5), isFalse);
      expect(terminal.graphics.hasPlacements, isFalse);
    });

    test('a load cut short by CAN leaves no stale image', () {
      final terminal = _terminal();
      _store(terminal, 7);
      terminal.write('\x1b_Ga=t,i=7,f=32,s=1,v=1,m=1;AAAA\x1b\\');
      terminal.write('\x1b_Gm=0;AAAA\x18');
      expect(terminal.graphics.hasPendingImage(7), isFalse);

      // A first transmission cancelled by CAN stores nothing at all.
      terminal.write('\x1b_Ga=t,i=8,f=32,s=1,v=1;$_pixel\x18');
      expect(terminal.graphics.hasPendingImage(8), isFalse);
    });
  });

  group('scrolling', () {
    TerminalImagePlacement place(
      Terminal terminal,
      int imageId, {
      required int row,
      int rows = 2,
    }) {
      _store(terminal, imageId);
      terminal.write(
        '\x1b[${row + 1};1H\x1b_Ga=p,i=$imageId,c=2,r=$rows,C=1,q=2\x1b\\',
      );
      return _placementOf(terminal, imageId)!;
    }

    test('an image inside the margins scrolls with CSI S and CSI T', () {
      final terminal = _terminal();
      terminal.write('\x1b[3;8r'); // rows 2..7
      place(terminal, 1, row: 4);

      terminal.write('\x1b[S');
      expect(_placementOf(terminal, 1)!.row, 3);
      terminal.write('\x1b[2T');
      expect(_placementOf(terminal, 1)!.row, 5);
      expect(_placementOf(terminal, 1)!.rows, 2);
    });

    test('an image straddling a margin stays where it is', () {
      final terminal = _terminal();
      terminal.write('\x1b[3;8r');
      place(terminal, 1, row: 6, rows: 3); // rows 6..8, past the bottom

      terminal.write('\x1b[S');
      final placement = _placementOf(terminal, 1)!;
      expect(placement.row, 6);
      expect(placement.rows, 3);
    });

    test('scrolling up clips an image at the top margin', () {
      final terminal = _terminal();
      terminal.write('\x1b[3;8r');
      // A 1x40 source over two 20-pixel rows: one source pixel per pixel.
      terminal.write(
        '\x1b[3;1H\x1b_Ga=t,i=1,f=32,s=1,v=40,q=2;'
        '${base64.encode(List<int>.filled(160, 255))}\x1b\\'
        '\x1b_Ga=p,i=1,c=1,r=2,C=1,q=2\x1b\\',
      );

      terminal.write('\x1b[S');
      final clipped = _placementOf(terminal, 1)!;
      expect(clipped.row, 2);
      expect(clipped.rows, 1);
      expect(clipped.srcY, 20);
      expect(clipped.srcHeight, 20);

      terminal.write('\x1b[S');
      expect(_placementOf(terminal, 1), isNull);
    });

    test('scrolling down clips an image at the bottom margin', () {
      final terminal = _terminal();
      terminal.write('\x1b[3;8r');
      _store(terminal, 1);
      terminal.write(
        '\x1b[7;1H\x1b_Ga=t,i=2,f=32,s=1,v=4,q=2;'
        '${base64.encode(List<int>.filled(16, 255))}\x1b\\'
        '\x1b_Ga=p,i=2,c=1,r=2,C=1,q=2\x1b\\',
      );

      terminal.write('\x1b[T');
      final clipped = _placementOf(terminal, 2)!;
      expect(clipped.row, 7);
      expect(clipped.rows, 1);
      expect(clipped.srcY, 0);
      expect(clipped.srcHeight, 2);
    });

    test('an image scrolled entirely out of the region is removed', () {
      final terminal = _terminal();
      terminal.write('\x1b[3;8r');
      place(terminal, 1, row: 3, rows: 1);
      terminal.write('\x1b[3S');
      expect(_placementOf(terminal, 1), isNull);
    });

    test('the alternate screen clips an image scrolled off the top', () {
      final terminal = _terminal(height: 6)..write('\x1b[?1049h');
      place(terminal, 1, row: 0, rows: 3);
      terminal.write('\x1b[S');
      final clipped = _placementOf(terminal, 1)!;
      expect(clipped.row, 0);
      expect(clipped.rows, 2);
    });

    test('a full-screen CSI S keeps the image whole in the scrollback', () {
      final terminal = _terminal(height: 6);
      place(terminal, 1, row: 0, rows: 3);
      terminal.write('\x1b[S');
      final placement = _placementOf(terminal, 1)!;
      expect(placement.row - terminal.buffer.scrollBack, -1);
      expect(placement.rows, 3);
    });
  });

  group('image ids', () {
    testWidgets('ids for I= numbers avoid ids the program is still sending', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = _terminal(responses: responses);
        final png = await _pngBase64(400, 400);
        // Explicit id 1 is still decoding when the number request comes in.
        terminal
          ..write('\x1b_Ga=T,i=1,f=100,c=1,r=1,q=2;$png\x1b\\')
          ..write('\x1b_Ga=t,I=4,f=32,s=1,v=1;$_pixel\x1b\\');
        final assigned = terminal.graphics.imageIdForNumber(4)!;
        expect(assigned, isNot(1));
        expect(responses.single, '\x1b_Gi=$assigned,I=4;OK\x1b\\');
        await _until(() => terminal.graphics.imageById(1) != null);
        expect(terminal.graphics.hasPendingImage(assigned), isTrue);
      });
    });

    testWidgets('images sent without an id never collide with program ids', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        terminal.write('\x1b_Ga=T,f=32,s=1,v=1,c=1,r=1;$_pixel\x1b\\');
        await _until(() => terminal.graphics.hasPlacements);
        final anonymous = terminal.graphics.placements.single.imageId;
        expect(anonymous, greaterThan(0xFFFFFFFF));

        // The program picks id 1; the anonymous image keeps its placement.
        terminal.write('\x1b_Ga=t,i=1,f=32,s=1,v=1,q=2;$_pixel\x1b\\');
        expect(terminal.graphics.placements.single.imageId, anonymous);
      });
    });
  });

  group('deletes', () {
    test('d=p and d=c remove only placements covering that cell', () {
      final terminal = _terminal();
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b[1;1H\x1b_Ga=p,i=1,c=2,r=1,C=1,q=2\x1b\\')
        ..write('\x1b[1;3H\x1b_Ga=p,i=2,c=2,r=1,C=1,q=2\x1b\\');

      terminal.write('\x1b_Ga=d,d=p,x=2,y=1,q=2\x1b\\');
      expect(terminal.graphics.placements.map((p) => p.imageId), [2]);

      terminal.write('\x1b[1;5H\x1b_Ga=d,d=c,q=2\x1b\\');
      expect(terminal.graphics.placements.map((p) => p.imageId), [2]);
      terminal.write('\x1b[1;4H\x1b_Ga=d,d=c,q=2\x1b\\');
      expect(terminal.graphics.hasPlacements, isFalse);
    });

    test('d=a removes only placements on the visible screen', () {
      final terminal = _terminal(height: 4);
      _store(terminal, 1);
      _store(terminal, 2);
      terminal.write('\x1b_Ga=p,i=1,c=1,r=1,C=1,q=2\x1b\\');
      terminal.write('\n\n\n\n\n\n');
      terminal.write('\x1b_Ga=p,i=2,c=1,r=1,C=1,q=2\x1b\\');

      terminal.write('\x1b_Ga=d,q=2\x1b\\');
      expect(terminal.graphics.placements.map((p) => p.imageId), [1]);
    });

    test('range deletes accept empty ranges and free by id range', () {
      final terminal = _terminal();
      for (var id = 1; id <= 3; id++) {
        _store(terminal, id);
        terminal.write('\x1b_Ga=p,i=$id,c=1,r=1,q=2\x1b\\');
      }

      final responses = <String>[];
      final quiet = Terminal(onOutput: responses.add);
      quiet.write('\x1b_Ga=d,d=r,x=5,y=3\x1b\\');
      expect(responses, isEmpty);

      terminal.write('\x1b_Ga=d,d=r,x=5,y=3,q=2\x1b\\');
      expect(terminal.graphics.placements, hasLength(3));

      terminal.write('\x1b_Ga=d,d=r,x=1,y=2,q=2\x1b\\');
      expect(terminal.graphics.placements.map((p) => p.imageId), [3]);
      expect(terminal.graphics.hasPendingImage(1), isTrue);

      terminal.write('\x1b_Ga=d,d=R,x=1,y=3,q=2\x1b\\');
      expect(terminal.graphics.hasPlacements, isFalse);
      for (var id = 1; id <= 3; id++) {
        expect(terminal.graphics.hasPendingImage(id), isFalse);
      }
    });

    test('deleting a missing placement does not free the image', () {
      final terminal = _terminal();
      _store(terminal, 5);
      terminal.write('\x1b_Ga=p,i=5,p=1,c=1,r=1,C=1,q=2\x1b\\');

      terminal.write('\x1b_Ga=d,d=I,i=5,p=9,q=2\x1b\\');
      expect(terminal.graphics.hasPendingImage(5), isTrue);
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write('\x1b_Ga=d,d=I,i=5,p=1,q=2\x1b\\');
      expect(terminal.graphics.hasPendingImage(5), isFalse);
      expect(terminal.graphics.hasPlacements, isFalse);

      // With no placement left, d=I without p= frees the data on its own.
      _store(terminal, 6);
      terminal.write('\x1b_Ga=d,d=I,i=6,q=2\x1b\\');
      expect(terminal.graphics.hasPendingImage(6), isFalse);
    });

    test('d=z and d=q select by z-index', () {
      final terminal = _terminal();
      _store(terminal, 1);
      _store(terminal, 2);
      terminal
        ..write('\x1b[1;1H\x1b_Ga=p,i=1,c=1,r=1,z=4,C=1,q=2\x1b\\')
        ..write('\x1b[1;1H\x1b_Ga=p,i=2,c=1,r=1,z=-2,C=1,q=2\x1b\\');

      terminal.write('\x1b_Ga=d,d=q,x=1,y=1,z=4,q=2\x1b\\');
      expect(terminal.graphics.placements.map((p) => p.imageId), [2]);
      terminal.write('\x1b_Ga=d,d=z,z=-2,q=2\x1b\\');
      expect(terminal.graphics.hasPlacements, isFalse);
    });

    test('d=i removes the virtual placement too', () {
      final terminal = _terminal();
      _store(terminal, 5);
      terminal.write('\x1b_Ga=p,U=1,i=5,c=2,r=1,q=2\x1b\\');
      terminal.write('\x1b_Ga=d,d=i,i=5,q=2\x1b\\');
      expect(terminal.graphics.virtualPlacementById(5), isNull);
      expect(terminal.graphics.hasPendingImage(5), isTrue);
    });
  });

  group('validation and replies', () {
    testWidgets('invalid image data gets an error reply', (tester) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = _terminal(responses: responses);
        final garbage = base64.encode(utf8.encode('not an image'));

        terminal.write('\x1b_Ga=T,i=3,f=100;$garbage\x1b\\');
        await _until(() => responses.isNotEmpty);
        expect(responses.single, startsWith('\x1b_Gi=3;EINVAL'));

        responses.clear();
        terminal.write('\x1b_Ga=t,i=4,f=100;$garbage\x1b\\');
        expect(responses.single, '\x1b_Gi=4;EINVAL: invalid PNG data\x1b\\');
        expect(terminal.graphics.hasPendingImage(4), isFalse);

        responses.clear();
        terminal.write('\x1b_Ga=t,i=5,f=32,s=2,v=1;$_pixel\x1b\\');
        expect(responses.single, contains('i=5;EINVAL'));

        responses.clear();
        terminal.write('\x1b_Ga=t,i=6,f=42,s=1,v=1;$_pixel\x1b\\');
        expect(
          responses.single,
          '\x1b_Gi=6;EINVAL: unsupported format\x1b\\',
        );
        expect(terminal.graphics.hasPendingImage(6), isFalse);

        // Without an id or number Kitty has nowhere to address a reply.
        responses.clear();
        terminal.write('\x1b_Ga=T,f=100;$garbage\x1b\\');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(responses, isEmpty);
      });
    });

    test('f=0 means RGBA and stores successfully', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal.write('\x1b_Ga=t,i=1,f=0,s=1,v=1;$_pixel\x1b\\');
      expect(responses.single, '\x1b_Gi=1;OK\x1b\\');
      expect(terminal.graphics.hasPendingImage(1), isTrue);
    });

    test('files and shared memory are refused, not misread as data', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      for (final medium in ['f', 't', 's']) {
        responses.clear();
        terminal.write(
          '\x1b_Ga=T,i=1,t=$medium,f=100,S=4;'
          '${base64.encode(utf8.encode('/tmp/x.png'))}\x1b\\',
        );
        expect(
          responses.single,
          '\x1b_Gi=1;EINVAL: unsupported transmission medium\x1b\\',
        );
      }
      expect(terminal.graphics.hasPlacements, isFalse);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 0));
    });

    testWidgets('queries load the data, with no false positives', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = _terminal(responses: responses);
        final png = await _png(2, 2);

        terminal
            .write('\x1b_Ga=q,i=31,I=9,p=2,f=100;${base64.encode(png)}\x1b\\');
        // Kitty checks i and I before anything else, and echoes both.
        expect(responses, [
          '\x1b_Gi=31,I=9,p=2;'
              'EINVAL: image ID and number are mutually exclusive\x1b\\',
        ]);
        responses.clear();

        terminal.write('\x1b_Ga=q,i=31,p=2,f=100;${base64.encode(png)}\x1b\\');
        expect(responses.single, '\x1b_Gi=31;OK\x1b\\');

        for (final bad in [
          png.sublist(0, png.length - 12), // truncated, no IEND
          Uint8List.fromList(png)..[png.length - 20] ^= 0xFF, // bad CRC
        ]) {
          responses.clear();
          terminal.write('\x1b_Ga=q,i=31,f=100;${base64.encode(bad)}\x1b\\');
          expect(responses.single, startsWith('\x1b_Gi=31;EINVAL'));
        }

        responses.clear();
        terminal.write('\x1b_Ga=q,i=31,f=32,s=2,v=2;$_pixel\x1b\\');
        expect(responses.single, startsWith('\x1b_Gi=31;EINVAL'));

        // A query without an image id gets no reply at all.
        responses.clear();
        terminal.write('\x1b_Ga=q,f=100;${base64.encode(png)}\x1b\\');
        expect(responses, isEmpty);
        expect(terminal.graphics.hasPendingImage(31), isFalse);
      });
    });

    test('the PNG check needs every scanline only when deep', () {
      // A valid header and IEND around image data too short for the image.
      Uint8List chunk(String type, List<int> data) {
        final body = Uint8List.fromList([...utf8.encode(type), ...data]);
        final out = BytesBuilder()
          ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
          ..add(body)
          ..add(
            (ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List(),
          );
        return out.takeBytes();
      }

      final header = (ByteData(13)
            ..setUint32(0, 4)
            ..setUint32(4, 4)
            ..setUint8(8, 8)
            ..setUint8(9, 6))
          .buffer
          .asUint8List();
      // zlib of a single zero byte: far less than 4 rows of 17 bytes.
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        ...chunk('IHDR', header),
        ...chunk(
            'IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]),
        ...chunk('IEND', const []),
      ]);
      expect(kittyGraphicsPayloadError(kittyGraphicsFormatPng, png), isNull);
      expect(
        kittyGraphicsPayloadError(kittyGraphicsFormatPng, png, deep: true),
        isNotNull,
      );
    });

    testWidgets('chunked transmissions keep their ids in the reply', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = _terminal(responses: responses);
        final png = await _pngBase64(2, 2);
        final half = png.length ~/ 2;

        terminal
          ..write('\x1b_Ga=T,i=9,p=3,f=100,C=1,m=1;${png.substring(0, half)}')
          ..write('\x1b\\\x1b_Gm=0;${png.substring(half)}\x1b\\');
        await _until(() => responses.isNotEmpty);
        expect(responses.single, '\x1b_Gi=9,p=3;OK\x1b\\');

        responses.clear();
        terminal
          ..write('\x1b_Ga=t,I=12,f=100,m=1;${png.substring(0, half)}\x1b\\')
          ..write('\x1b_Gm=0;${png.substring(half)}\x1b\\');
        final assigned = terminal.graphics.imageIdForNumber(12);
        expect(responses.single, '\x1b_Gi=$assigned,I=12;OK\x1b\\');

        // A quiet setting on the last chunk applies to the reply.
        responses.clear();
        terminal
          ..write('\x1b_Ga=t,i=10,f=100,m=1;${png.substring(0, half)}\x1b\\')
          ..write('\x1b_Gm=0,q=1;${png.substring(half)}\x1b\\');
        expect(responses, isEmpty);
      });
    });

    test('a non-chunk command interrupts a load in progress', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal
        ..write('\x1b_Ga=t,i=1,f=32,s=1,v=1,m=1;AAAA\x1b\\')
        ..write('\x1b_Ga=t,i=2,t=f;${base64.encode(utf8.encode('/x'))}\x1b\\')
        // The orphaned final chunk of image 1 completes nothing.
        ..write('\x1b_Gm=0;AAAA\x1b\\');
      expect(responses, [
        '\x1b_Gi=2;EINVAL: unsupported transmission medium\x1b\\',
      ]);
      expect(terminal.graphics.hasPendingImage(1), isFalse);
    });

    test('quiet values follow Kitty: q=1 hides OK, q>=2 hides errors', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal
        ..write('\x1b_Ga=p,i=99,q=1\x1b\\')
        ..write('\x1b_Ga=p,i=99,q=3\x1b\\');
      expect(responses, ['\x1b_Gi=99;ENOENT: image not found\x1b\\']);

      responses.clear();
      _store(terminal, 1);
      terminal
        ..write('\x1b_Ga=p,i=1,p=4,C=1\x1b\\')
        ..write('\x1b_Ga=p,i=1,p=5,C=1,q=1\x1b\\');
      expect(responses, ['\x1b_Gi=1,p=4;OK\x1b\\']);
    });

    test('Kitty reads U and compose C as any non-zero value', () {
      final terminal = _terminal();
      _store(terminal, 1);
      terminal.write('\x1b_Ga=p,U=2,i=1,c=2,r=1,q=2\x1b\\');
      expect(terminal.graphics.virtualPlacementById(1), isNotNull);
      expect(terminal.graphics.hasPlacements, isFalse);
    });

    test('unknown action, medium or compression is dropped silently', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal
        ..write('\x1b_Ga=z,i=1\x1b\\')
        ..write('\x1b_Ga=t,i=1,t=q;$_pixel\x1b\\')
        ..write('\x1b_Ga=t,i=1,o=q;$_pixel\x1b\\')
        ..write('\x1b_Ga=d,d=w,i=1\x1b\\');
      expect(responses, isEmpty);
    });
  });

  group('geometry', () {
    test('a crop without w/h is not stretched to the full image', () {
      final terminal = _terminal();
      // 4x2 RGBA, cropped at x=2: a 2x2 source. At c=4 (40 pixels wide) it
      // is 40 pixels high, two rows; the full image would be one row.
      terminal.write(
        '\x1b_Ga=t,i=1,f=32,s=4,v=2,q=2;'
        '${base64.encode(List<int>.filled(32, 255))}\x1b\\'
        '\x1b_Ga=p,i=1,c=4,x=2,q=2\x1b\\',
      );
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (4, 1));

      final placement = _placementOf(terminal, 1)!;
      final size = terminalImagePlacementSize(
        placement,
        sourceWidth: 2,
        sourceHeight: 2,
        cellWidth: 10,
        cellHeight: 20,
        availableColumns: 40,
      );
      expect((size.width, size.height), (40.0, 40.0));
      expect(
        terminal.graphics.placementsInRows(terminal.buffer.lines, 1, 1),
        [placement],
      );
    });

    test('offsets stay in the first cell and do not enlarge c/r', () {
      final terminal = _terminal();
      _store(terminal, 1);
      terminal.write('\x1b_Ga=p,i=1,c=2,r=1,X=500,Y=7,C=1,q=2\x1b\\');
      final placement = _placementOf(terminal, 1)!;
      expect(placement.cellXOffset(10), 9);
      expect(placement.cellYOffset(20), 7);
      final size = terminalImagePlacementSize(
        placement,
        sourceWidth: 1,
        sourceHeight: 1,
        cellWidth: 10,
        cellHeight: 20,
        availableColumns: 40,
      );
      // The far edges stay on the c/r cell boundaries.
      expect((size.width, size.height), (11.0, 13.0));
      expect(
        terminal.graphics.deletePlacements(what: 'p', cellCol: 2, cellRow: 0),
        isFalse,
      );
    });

    test('the cursor moves past the image as it is painted, offset included',
        () {
      final terminal = _terminal();
      // A square 2x2 image at 10x20 px cells.
      terminal.write(
        '\x1b_Ga=t,i=1,f=32,s=2,v=2,q=2;'
        '${base64.encode(List<int>.filled(16, 255))}\x1b\\',
      );

      // c=2 with X=9: 11 px wide, so 11 px high, inside the first row.
      terminal.write('\x1b_Ga=p,i=1,p=1,c=2,X=9,q=2\x1b\\');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (2, 0));
      final narrow = _placementOf(terminal, 1, clientPlacementId: 1)!;
      expect(
        terminal.graphics.placementsInRows(terminal.buffer.lines, 1, 1),
        isNot(contains(narrow)),
      );

      // r=2 with Y=19: 21 px high, so 21 px wide, into a third column.
      terminal.write('\x1b[5;1H\x1b_Ga=p,i=1,p=2,r=2,Y=19,q=2\x1b\\');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (3, 5));
    });

    testWidgets(
        'a downscaled image covers the same cells before and after '
        'its decode', (tester) async {
      await tester.runAsync(() async {
        // 3000x1501 decodes to 1280x640: 25 px high at c=5, where the
        // source ratio would give 25.02 px. With Y=15 the kept pixels end on
        // the second row's bottom edge; the source ones would reach a third.
        final png = base64.encode(await _png(3000, 1501));
        final terminal = _terminal();
        final lines = terminal.buffer.lines;

        terminal
          ..write('\x1b_Ga=t,i=1,f=100,q=2;$png\x1b\\')
          ..write('\x1b[H\x1b_Ga=p,i=1,p=1,c=5,Y=15,q=2\x1b\\');
        expect(terminal.graphics.hasPendingImage(1), isTrue);
        expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (5, 1));

        await terminal.graphics.resolveImage(1);
        final decoded = terminal.graphics.imageById(1)!.image;
        expect((decoded.width, decoded.height), (1280, 640));
        terminal.write('\x1b[H\x1b_Ga=p,i=1,p=2,c=5,Y=15,q=2\x1b\\');
        expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (5, 1));

        final placement = _placementOf(terminal, 1, clientPlacementId: 2)!;
        expect(terminal.graphics.placementsInRows(lines, 1, 1), [
          _placementOf(terminal, 1, clientPlacementId: 1),
          placement,
        ]);
        expect(terminal.graphics.placementsInRows(lines, 2, 2), isEmpty);
        // The painter sizes the crop in the decoded pixels.
        final painted = terminalImagePlacementSize(
          placement,
          sourceWidth: 1280,
          sourceHeight: 640,
          cellWidth: 10,
          cellHeight: 20,
          availableColumns: 40,
        );
        expect((painted.width, painted.height), (50.0, 25.0));

        // A transmission placed before it decodes moves the cursor the same.
        terminal.write('\x1b[H\x1b_Ga=T,i=2,f=100,c=5,Y=15,q=2;$png\x1b\\');
        expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (5, 1));
      });
    });

    test('consecutive tall images do not overlap', () {
      // An eight-row, full-width image in a five-row terminal: the cursor
      // ends up below it after four moves and four scrolls (Ghostty #13887).
      final terminal = _terminal(width: 10, height: 5);
      _store(terminal, 1);
      terminal
        ..write('\x1b_Ga=p,i=1,c=10,r=8,q=2\x1b\\')
        ..write('\x1b_Ga=p,i=1,c=10,r=8,q=2\x1b\\');
      final placements = terminal.graphics.placements;
      expect(placements, hasLength(2));
      expect(placements[1].row, placements[0].row + 8);
      expect(terminal.buffer.cursorX, 0);
    });

    test('the cursor wraps when an image reaches the right edge', () {
      final terminal = _terminal(width: 10, height: 5);
      _store(terminal, 1);
      terminal.write('\x1b[1;7H\x1b_Ga=p,i=1,c=4,r=2,q=2\x1b\\');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 2));
    });
  });

  group('review fixes', () {
    test('a region scroll keeps the column insertions moved an image to', () {
      final terminal = _terminal();
      _store(terminal, 1);
      terminal.write('\x1b[1;6H\x1b_Ga=p,i=1,c=1,r=1,C=1,q=2\x1b\\');
      expect(_placementOf(terminal, 1)!.col, 5);
      // Two cells inserted before the anchor move it to column 7.
      terminal.write('\x1b[1;1H\x1b[2@');
      expect(_placementOf(terminal, 1)!.col, 7);

      terminal.write('\x1b[T');
      final moved = _placementOf(terminal, 1)!;
      expect((col: moved.col, row: moved.row), (col: 7, row: 1));
    });

    testWidgets('a queued virtual placement lands on the screen it named', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        final png = await _pngBase64(400, 400);
        for (var i = 0; i < 3; i++) {
          await terminalGraphicsDecodeGate.acquire();
        }
        try {
          terminal
            ..write('\x1b_Ga=T,i=1,f=100,c=1,r=1,C=1,q=2;$png\x1b\\')
            ..write('\x1b_Ga=p,i=1,U=1,c=2,r=2,q=2\x1b\\')
            ..write('\x1b[?1049h');
        } finally {
          for (var i = 0; i < 3; i++) {
            terminalGraphicsDecodeGate.release();
          }
        }
        // The decode finishes while the alternate screen is up.
        final main = terminal.mainBuffer.graphics;
        await _until(() => main.virtualPlacementById(1) != null);
        expect(terminal.isUsingAltBuffer, isTrue);
        expect(main.virtualPlacementById(1), isNotNull);
        expect(terminal.altBuffer.graphics.virtualPlacementById(1), isNull);
      });
    });

    testWidgets('a queued virtual placement keeps the image its I= named', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        final png = await _pngBase64(400, 400);
        for (var i = 0; i < 3; i++) {
          await terminalGraphicsDecodeGate.acquire();
        }
        late int first;
        late int second;
        try {
          terminal
            ..write('\x1b_Ga=T,I=5,f=100,c=1,r=1,C=1,q=2;$png\x1b\\')
            ..write('\x1b_Ga=p,I=5,U=1,c=2,r=2,q=2\x1b\\');
          first = terminal.graphics.imageIdForNumber(5)!;
          terminal.write('\x1b_Ga=t,I=5,f=32,s=1,v=1,q=2;$_pixel\x1b\\');
          second = terminal.graphics.imageIdForNumber(5)!;
        } finally {
          for (var i = 0; i < 3; i++) {
            terminalGraphicsDecodeGate.release();
          }
        }
        await _until(
          () => terminal.graphics.virtualPlacementById(first) != null,
        );
        expect(terminal.graphics.virtualPlacementById(first), isNotNull);
        expect(terminal.graphics.virtualPlacementById(second), isNull);
      });
    });

    test('compressed data never inflates past what it may hold', () {
      // 8 MiB of zeros compresses to a few kilobytes.
      final bomb = Uint8List.fromList(
        const ZLibEncoder().encode(Uint8List(8 << 20)),
      );
      expect(bomb.length, lessThan(16 * 1024));
      expect(inflateZlibData(bomb, maxBytes: 4), isNull);

      expect(inflateZlibData(bomb)!.length, 8 << 20);

      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal.write(
        '\x1b_Ga=t,i=1,f=32,s=1,v=1,o=z;${base64.encode(bomb)}\x1b\\',
      );
      expect(responses.single, startsWith('\x1b_Gi=1;EINVAL'));
      expect(terminal.graphics.hasPendingImage(1), isFalse);
    });

    test('a PNG query stops inflating at the declared image size', () {
      Uint8List chunk(String type, List<int> data) {
        final body = Uint8List.fromList([...utf8.encode(type), ...data]);
        return (BytesBuilder()
              ..add(
                  (ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
              ..add(body)
              ..add(
                (ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List(),
              ))
            .takeBytes();
      }

      // A CRC-correct 1x1 RGBA PNG whose image data inflates to 8 MiB.
      final header = (ByteData(13)
            ..setUint32(0, 1)
            ..setUint32(4, 1)
            ..setUint8(8, 8)
            ..setUint8(9, 6))
          .buffer
          .asUint8List();
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        ...chunk('IHDR', header),
        ...chunk('IDAT', const ZLibEncoder().encode(Uint8List(8 << 20))),
        ...chunk('IEND', const []),
      ]);
      expect(
        kittyGraphicsPayloadError(kittyGraphicsFormatPng, png, deep: true),
        isNotNull,
      );

      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      terminal.write('\x1b_Ga=q,i=1,f=100;${base64.encode(png)}\x1b\\');
      expect(responses.single, startsWith('\x1b_Gi=1;EINVAL'));
    });
  });

  group('behind a multiplexer', () {
    Terminal multiplexed(List<String> responses) =>
        _terminal(responses: responses)
          ..kittyGraphicsTransmissionReplies = false;

    testWidgets('transmissions and placements send no acknowledgements', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final responses = <String>[];
        final terminal = multiplexed(responses);
        final png = await _pngBase64(2, 2);
        terminal
          ..write('\x1b_Ga=T,i=1,f=100;$png\x1b\\')
          ..write('\x1b_Ga=t,i=2,f=32,s=1,v=1;$_pixel\x1b\\')
          ..write('\x1b_Ga=t,i=3,f=42,s=1,v=1;$_pixel\x1b\\')
          ..write('\x1b_Ga=t,i=4,f=100;${base64.encode([1, 2])}\x1b\\')
          ..write('\x1b_Ga=p,i=2,p=1\x1b\\')
          ..write('\x1b_Ga=p,i=99\x1b\\')
          ..write('\x1b_Ga=p,i=2,I=5\x1b\\')
          ..write('\x1b_Ga=d,d=i,i=2\x1b\\');
        await _until(() => terminal.graphics.imageById(1) != null);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(responses, isEmpty);
      });
    });

    test(
      'queries, numbers and animation commands still get their replies',
      () async {
        final responses = <String>[];
        final terminal = multiplexed(responses);
        terminal
          ..write('\x1b_Ga=t,I=5,f=32,s=1,v=1;$_pixel\x1b\\')
          ..write('\x1b_Ga=q,i=31,s=1,v=1,f=24;AAAA\x1b\\')
          ..write('\x1b_Ga=q,s=1,v=1,f=24;AAAA\x1b\\')
          ..write('\x1b_Ga=q,i=31,I=9,f=24;AAAA\x1b\\')
          ..write('\x1b_Ga=a,i=99,s=3\x1b\\');
        await _until(() => responses.length >= 5);
        final assigned = terminal.graphics.imageIdForNumber(5);
        expect(responses, [
          '\x1b_GI=5,i=$assigned;OK\x1b\\',
          '\x1b_Gi=31;OK\x1b\\',
          '\x1b_G;OK\x1b\\',
          '\x1b_Gi=31,I=9;'
              'EINVAL: image ID and number are mutually exclusive\x1b\\',
          '\x1b_Gi=99;ENOENT: image not found\x1b\\',
        ]);
      },
    );
  });

  group('reset and storage', () {
    test('a full reset keeps graphics enabled and the storage limits', () {
      final responses = <String>[];
      final terminal = _terminal(responses: responses);
      final limit = terminal.graphics.maxMemoryBytes;
      final count = terminal.graphics.maxImageCount;
      terminal.write('\x1bc');
      expect(terminal.kittyGraphicsEnabled, isTrue);
      expect(terminal.graphics.maxMemoryBytes, limit);
      expect(terminal.graphics.maxImageCount, count);
      terminal.write('\x1b_Ga=t,i=1,f=32,s=1,v=1;$_pixel\x1b\\');
      expect(responses.single, '\x1b_Gi=1;OK\x1b\\');
    });

    testWidgets('transient images are evicted first', (tester) async {
      await tester.runAsync(() async {
        // Two 4x4 images (64 bytes each) fit under the 70% high water mark;
        // a third evicts down to the 50% target, which leaves room for one.
        final manager = GraphicsManager(maxMemoryBytes: 260);
        Future<DecodedTerminalImage> image() async {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 4, 4),
            Paint()..color = const Color(0xFF00FF00),
          );
          return DecodedTerminalImage.single(
            await recorder.endRecording().toImage(4, 4),
          );
        }

        manager.storeDecodedImageWithId(1, await image());
        manager.storeDecodedImageWithId(2, await image(), transient: true);
        manager.imageById(1); // the transient image is the older access
        manager.storeDecodedImageWithId(3, await image());

        expect(manager.imageById(2), isNull);
        expect(manager.imageById(1), isNotNull);
        expect(manager.imageById(3), isNotNull);
      });
    });

    /// Writes [before], then [reset], while every decode slot is held, so
    /// whatever [before] queued behind a decode is still waiting at the reset;
    /// then lets the decodes finish.
    Future<void> resetWhileQueued(
      Terminal terminal,
      String before, {
      String reset = '\x1bc',
    }) async {
      for (var i = 0; i < 3; i++) {
        await terminalGraphicsDecodeGate.acquire();
      }
      try {
        terminal.write('$before$reset');
      } finally {
        for (var i = 0; i < 3; i++) {
          terminalGraphicsDecodeGate.release();
        }
      }
    }

    testWidgets('a placement queued before a reset does not land after it', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final terminal = _terminal();
        // The display command waits for the transmission's decode.
        await resetWhileQueued(
          terminal,
          '\x1b_Ga=T,i=1,f=32,s=1,v=1,C=1,q=2;$_pixel\x1b\\'
          '\x1b_Ga=p,i=1,c=4,r=4,C=1,q=2\x1b\\',
        );
        await _until(() => terminal.graphics.imageById(1) != null);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(terminal.graphics.imageById(1), isNotNull);
        expect(terminal.graphics.placements, isEmpty);
      });
    });

    testWidgets('a relative placement queued before a clear stays away', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final png = await _pngBase64(4, 4);
        // A full reset, and the clear of the alternate screen on entering it.
        for (final (screen, reset) in [
          ('', '\x1bc'),
          ('\x1b[?1049h', '\x1b[?1049l\x1b[?1049h'),
        ]) {
          final terminal = _terminal()..write(screen);
          // The parent is a virtual placement, which a clear keeps.
          _store(terminal, 1);
          _store(terminal, 2);
          terminal.write('\x1b_Ga=p,U=1,i=1,c=3,r=2,q=2\x1b\\');
          await resetWhileQueued(
            terminal,
            '\x1b_Ga=T,i=3,f=100,C=1,q=2;$png\x1b\\'
            '\x1b_Ga=p,i=2,P=1,H=1,V=1,c=1,r=1,q=2\x1b\\'
            '\x1b_Ga=T,i=4,f=100,P=1,c=1,r=1,q=2;$png\x1b\\',
            reset: reset,
          );
          // Both wait for every earlier operation, image 3's decode included.
          final graphics = terminal.graphics;
          await _until(() => graphics.hasPendingImage(4));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(graphics.virtualPlacementById(1), isNotNull, reason: reset);
          expect(graphics.placements, isEmpty, reason: reset);
        }
      });
    });

    test('the transient hint is read from N on transmission', () {
      final terminal = _terminal();
      terminal.write('\x1b_Ga=t,i=1,N=1,f=32,s=1,v=1,q=2;$_pixel\x1b\\');
      expect(terminal.graphics.hasPendingImage(1), isTrue);
    });
  });
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
