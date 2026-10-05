import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:xterm/xterm.dart';

/// Kitty row/column placeholder diacritics (row/column order), enough to drive
/// small placeholder grids in tests.
const _kittyDiacritics = <int>[
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
];

ui.Image _solidImage(ui.Color color, int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  return recorder.endRecording().toImageSync(width, height);
}

/// Emits the Kitty Unicode-placeholder cells for [imageId] across [cols]x[rows]
/// cells, exactly as a kitty-aware client does.
String _placeholderGrid(int imageId, {required int cols, required int rows}) {
  final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
  final r = (imageId >> 16) & 0xFF;
  final g = (imageId >> 8) & 0xFF;
  final b = imageId & 0xFF;
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    buffer.write('\x1b[38;2;$r;$g;${b}m');
    for (var col = 0; col < cols; col++) {
      buffer
        ..write(placeholder)
        ..writeCharCode(_kittyDiacritics[row])
        ..writeCharCode(_kittyDiacritics[col]);
    }
    buffer.write('\x1b[39m');
    if (row < rows - 1) buffer.write('\r\n');
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('terminal preview image capture', () {
    test('has no images for a plain terminal', () {
      final terminal = Terminal(maxLines: 100)..write('plain output');

      final snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;

      expect(snapshot.images, isEmpty);
    });

    test('captures a Unicode-placeholder image as a single merged rect', () {
      final terminal = Terminal(maxLines: 100)..resize(40, 12);
      terminal.graphics.storeImageWithId(
        42,
        _solidImage(const ui.Color(0xFFFF0000), 32, 32),
      );
      terminal
        ..write('before\r\n')
        ..write(_placeholderGrid(42, cols: 8, rows: 4))
        ..write('\r\nafter');

      final snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;

      // A solid 8x4 grid collapses into one rectangle covering all cells.
      expect(snapshot.images, hasLength(1));
      final image = snapshot.images.single;
      expect(image.col, 0);
      expect(image.row, 1, reason: 'image starts on the row after "before"');
      expect(image.colSpan, 8);
      expect(image.rowSpan, 4);
      expect(image.fitToWidth, isFalse);
      expect(image.src, const ui.Rect.fromLTWH(0, 0, 32, 32));
    });

    test('captures a classic placement with an explicit cell span', () {
      final terminal = Terminal(maxLines: 100)
        ..resize(40, 12)
        ..write('row0\r\nrow1\r\nimg:');
      terminal.graphics.storeImageWithId(
        1,
        _solidImage(const ui.Color(0xFF0000FF), 24, 24),
      );
      terminal.graphics.placeImage(
        1,
        terminal.buffer.createAnchorFromCursor(),
        cols: 6,
        rows: 2,
      );

      final snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;

      final placement = snapshot.images.singleWhere((i) => !i.fitToWidth);
      expect(placement.colSpan, 6);
      expect(placement.rowSpan, 2);
    });

    test('maps a source-space crop into a downsampled decoded image', () {
      final terminal = Terminal(maxLines: 100)
        ..resize(40, 12)
        ..write('img:');
      // A 2560px source decoded at half size; Kitty crop coordinates stay in
      // the 2560px source space.
      terminal.graphics.storeDecodedImageWithId(
        2,
        DecodedTerminalImage(
          frames: [
            TerminalImageFrame(
              _solidImage(const ui.Color(0xFF0000FF), 1280, 20),
            ),
          ],
          sourceWidth: 2560,
          sourceHeight: 40,
        ),
      );
      terminal.graphics.placeImage(
        2,
        terminal.buffer.createAnchorFromCursor(),
        cols: 6,
        rows: 3,
        srcX: 1280,
        srcWidth: 1280,
      );

      final snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;

      expect(
        snapshot.images.single.src,
        const ui.Rect.fromLTWH(640, 0, 640, 20),
      );
    });

    test(
      'drops the previous placeholder ghost, keeping the newest instance',
      () {
        final terminal = Terminal(maxLines: 100)..resize(40, 12);
        terminal.graphics.storeImageWithId(
          7,
          _solidImage(const ui.Color(0xFF00FF00), 32, 32),
        );
        // Draw the image, clear the screen, then redraw it lower down.
        terminal
          ..write(_placeholderGrid(7, cols: 8, rows: 4))
          ..write('\x1b[H\x1b[2J')
          ..write('\r\n\r\n')
          ..write(_placeholderGrid(7, cols: 8, rows: 4));

        final snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;

        // Only the most recent placement survives (no lingering ghost copy).
        expect(snapshot.images, hasLength(1));
      },
    );
  });
}
