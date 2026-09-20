import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Future<String> _buildPngBase64(
  int width,
  int height, {
  Color color = const Color(0xFFFF0000),
}) async {
  final image = await _buildImage(width, height, color: color);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64.encode(bytes!.buffer.asUint8List());
}

Future<ui.Image> _buildImage(
  int width,
  int height, {
  Color color = const Color(0xFFFF0000),
}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(width, height);
}

Future<Color> _pixelColor(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  return Color.fromARGB(
    data!.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

const _animatedGifBase64 =
    'R0lGODlhAwADAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQE'
    'BwAAACwAAAAAAwADAAAIBwABCBw4MCAAIfkEBA0AAAAsAAAAAAMAAwCBAAD/AAAA'
    'AAAAAAAACAcAAQgcODAgADs=';

const _zeroDelayGifBase64 =
    'R0lGODlhAwADAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQE'
    'AAAAACwAAAAAAwADAAAIBwABCBw4MCAAIfkEBAAAAAAsAAAAAAMAAwCBAAD/AAAA'
    'AAAAAAAACAcAAQgcODAgADs=';

const _jpeg240x160Base64 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIf'
    'IiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7'
    'Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCACgAPADASIA'
    'AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEB'
    'AQEAAAAAAAAAAAAAAAAAAAYH/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AlQE6'
    '2YAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB/9k=';

/// Waits until image [id] has finished its (deferred) decode and is stored.
Future<void> _awaitImage(Terminal terminal, int id) async {
  var waited = 0;
  while (terminal.graphics.imageById(id) == null && waited < 2000) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    waited += 20;
  }
}

/// Store-only (`a=t`) and virtual (`a=T,U=1`) images are decoded lazily: the
/// bytes are retained and only decoded when something paints them. Tests that
/// assert on the decoded image must first reference it the way the renderer
/// does on a visible frame, then wait for the async decode.
Future<void> _decodeDeferredImage(Terminal terminal, int id) async {
  terminal.graphics.imageForPlacement(id);
  await _awaitImage(terminal, id);
}

/// Splits [base64Payload] into a Kitty multi-chunk (`m=1`) transmission the way
/// the protocol requires for payloads over 4096 base64 bytes: the first APC
/// carries the control keys, every APC sets `m=1` except the last which sets
/// `m=0`. MonkeyMux stores and replays exactly this byte stream, so the client
/// must reassemble it into a single image.
String _multiChunkTransmission(
  String base64Payload, {
  required String firstControl,
  int chunkSize = 4096,
}) {
  final buffer = StringBuffer();
  var offset = 0;
  var first = true;
  while (offset < base64Payload.length) {
    final end = math.min(offset + chunkSize, base64Payload.length);
    final chunk = base64Payload.substring(offset, end);
    final isLast = end >= base64Payload.length;
    final more = isLast ? '0' : '1';
    if (first) {
      buffer.write('\x1b_G$firstControl,m=$more;$chunk\x1b\\');
      first = false;
    } else {
      buffer.write('\x1b_Gm=$more;$chunk\x1b\\');
    }
    offset = end;
  }
  return buffer.toString();
}

/// Base64 of a raw RGBA image of [width] x [height] filled with pseudo-random
/// bytes so it does not compress and is large enough to force multiple chunks.
String _rawRgbaBase64(int width, int height) {
  final bytes = Uint8List(width * height * 4);
  var seed = 0x12345678;
  for (var i = 0; i < bytes.length; i++) {
    // xorshift keeps the payload incompressible and deterministic.
    seed ^= (seed << 13) & 0xFFFFFFFF;
    seed ^= seed >> 17;
    seed ^= (seed << 5) & 0xFFFFFFFF;
    bytes[i] = seed & 0xFF;
  }
  return base64.encode(bytes);
}

void main() {
  test('counted image-number reservations restore their first predecessor', () {
    final manager = GraphicsManager();
    final firstPrevious = manager.reserveExplicitImageIdForNumber(5, 100);
    final secondPrevious = manager.reserveExplicitImageIdForNumber(5, 100);
    expect(firstPrevious.accepted, isTrue);
    expect(secondPrevious.accepted, isTrue);
    manager
      ..rollbackImageIdReservation(5, 100, firstPrevious.previousImageId)
      ..rollbackImageIdReservation(5, 100, secondPrevious.previousImageId);
    expect(manager.imageIdForNumber(5), isNull);
  });

  test('DecodedTerminalImage rejects an empty frame sequence', () {
    expect(
      () => DecodedTerminalImage(
        frames: const <TerminalImageFrame>[],
        sourceWidth: 1,
        sourceHeight: 1,
      ),
      throwsArgumentError,
    );
  });

  testWidgets('Kitty graphics a=T decodes, stores and places an image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      expect(terminal.graphics.hasPlacements, isFalse);

      terminal.write('\x1b_Ga=T,f=100;$pngBase64\x1b\\');

      // The decode runs asynchronously; give it time to complete.
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final placement = terminal.graphics.placements.single;
      expect(placement.col, 0);
      expect(placement.row, 0);

      final stored = terminal.graphics.imageById(placement.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('a burst of images all decode despite the concurrency gate', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // Transmit more images at once than the decode gate's permits (3) to
      // exercise queueing. Decoding is deferred until each is referenced, so
      // reference them all (as the painter would) and confirm none deadlock.
      const count = 8;
      for (var id = 1; id <= count; id++) {
        terminal.write('\x1b_Ga=t,f=100,i=$id;$pngBase64\x1b\\');
      }
      for (var id = 1; id <= count; id++) {
        terminal.graphics.imageForPlacement(id);
      }

      var waited = 0;
      bool allStored() => List.generate(count, (i) => i + 1)
          .every((id) => terminal.graphics.imageById(id) != null);
      while (!allStored() && waited < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      for (var id = 1; id <= count; id++) {
        expect(
          terminal.graphics.imageById(id),
          isNotNull,
          reason: 'image $id should have decoded despite throttling',
        );
      }
    });
  });

  testWidgets('Kitty graphics payload tolerates embedded whitespace', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      // Splice newlines/spaces into the payload; the streaming decoder must
      // skip them, matching the previous lenient whitespace-stripping behavior.
      final mid = pngBase64.length ~/ 2;
      final noisy =
          '${pngBase64.substring(0, mid)}\n \r\t${pngBase64.substring(mid)}';

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100;$noisy\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics omitted format defaults to RGBA', (tester) async {
    await tester.runAsync(() async {
      final rgbaBase64 = base64.encode([0xFF, 0x00, 0x00, 0xFF]);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,s=1,v=1;$rgbaBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final placement = terminal.graphics.placements.single;
      final stored = terminal.graphics.imageById(placement.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 1);
      expect(stored.image.height, 1);
    });
  });

  testWidgets('Kitty graphics query responds before following DA1', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\\x1b[c',
    );

    expect(output, ['\x1b_Gi=31;OK\x1b\\', '\x1b[?62;22c']);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query reports disabled capability', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)
      ..kittyGraphicsEnabled = false;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\',
    );

    expect(output, ['\x1b_Gi=31;ENOTSUP: graphics disabled\x1b\\']);
    expect(terminal.graphics.imageCount, 0);
    expect(terminal.heldImageSignatures(), isEmpty);
  });

  testWidgets('Kitty graphics query rejects unsupported transmission media', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,a=q,t=f;${base64.encode('/tmp/image.png'.codeUnits)}'
      '\x1b\\',
    );

    expect(
      output,
      ['\x1b_Gi=31;EINVAL: unsupported transmission medium\x1b\\'],
    );
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query honors quiet OK suppression', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,q=1,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\',
    );

    expect(output, isEmpty);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty graphics query q=2 suppresses successful responses', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    terminal.write(
      '\x1b_Gi=31,s=1,v=1,a=q,q=2,t=d,f=24;${base64.encode([0, 0, 0])}'
      '\x1b\\',
    );

    expect(output, isEmpty);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  testWidgets('Kitty transmit-only images are stored by protocol id', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=t,i=42,f=100;$pngBase64\x1b\\');

      // Deferred: the bytes are retained but not decoded until referenced.
      expect(terminal.graphics.imageById(42), isNull);
      expect(terminal.graphics.hasPendingImage(42), isTrue);

      await _decodeDeferredImage(terminal, 42);

      final stored = terminal.graphics.imageById(42);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('transmit-only images are not decoded until referenced', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // A window switch replays every retained image up front (store-only).
      const count = 5;
      for (var id = 1; id <= count; id++) {
        terminal.write('\x1b_Ga=t,f=100,i=$id;$pngBase64\x1b\\');
      }

      // Give any (unwanted) eager decode ample time to run.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      for (var id = 1; id <= count; id++) {
        expect(
          terminal.graphics.imageById(id),
          isNull,
          reason: 'image $id must stay deferred until something paints it',
        );
        expect(terminal.graphics.hasPendingImage(id), isTrue);
      }

      // Reference only image 3, the way the painter would for a visible cell.
      await _decodeDeferredImage(terminal, 3);

      expect(terminal.graphics.imageById(3), isNotNull);
      for (final id in [1, 2, 4, 5]) {
        expect(
          terminal.graphics.imageById(id),
          isNull,
          reason: 'off-screen image $id must not be decoded',
        );
        expect(terminal.graphics.hasPendingImage(id), isTrue);
      }
    });
  });

  testWidgets('re-transmitting an identical image id reuses the cached decode',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // First transmit + reference decodes and stores the image.
      terminal.write('\x1b_Ga=t,i=77,f=100;$pngBase64\x1b\\');
      await _decodeDeferredImage(terminal, 77);
      final first = terminal.graphics.imageById(77);
      expect(first, isNotNull);

      // Re-transmitting the same id with identical bytes (as a window-switch
      // replay does) must reuse the existing decoded image, not replace it.
      terminal.write('\x1b_Ga=t,i=77,f=100;$pngBase64\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final second = terminal.graphics.imageById(77);
      expect(
        identical(first!.image, second!.image),
        isTrue,
        reason: 'identical replay should reuse the same ui.Image',
      );
    });
  });

  testWidgets('re-transmitting an id with new bytes decodes a fresh image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final smallPng = await _buildPngBase64(3, 2);
      final largerPng = await _buildPngBase64(5, 4);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=t,i=88,f=100;$smallPng\x1b\\');
      await _decodeDeferredImage(terminal, 88);
      expect(terminal.graphics.imageById(88)!.image.width, 3);

      // Different bytes for the same id must miss the dedup, supersede the stale
      // image and re-decode once referenced again.
      terminal.write('\x1b_Ga=t,i=88,f=100;$largerPng\x1b\\');
      terminal.graphics.imageForPlacement(88);
      var waited = 0;
      while ((terminal.graphics.imageById(88)?.image.width ?? 3) != 5 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(88)!.image.width, 5);
    });
  });

  testWidgets('resolveImage retries a pending replacement after a stale decode',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      const imageId = 89;
      manager.storePendingImage(
        imageId,
        payload: base64.decode(await _buildPngBase64(3, 2)),
        format: 100,
      );

      final resolving = manager.resolveImage(imageId);
      manager.storePendingImage(
        imageId,
        payload: base64.decode(await _buildPngBase64(5, 4)),
        format: 100,
      );

      final resolved = await resolving;
      expect(resolved, isNotNull);
      expect(resolved!.image.width, 5);
      expect(resolved.image.height, 4);
      expect(manager.hasPendingImage(imageId), isFalse);
    });
  });

  testWidgets('an eager replacement invalidates an older pending decode', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      const imageId = 90;
      final replacement = await _buildImage(5, 4);
      manager.storePendingImage(
        imageId,
        payload: base64.decode(await _buildPngBase64(3, 2)),
        format: 100,
      );

      final staleDecode = manager.resolveImage(imageId);
      manager.storeImageWithId(imageId, replacement);
      await staleDecode;

      final stored = manager.imageById(imageId);
      expect(stored, isNotNull);
      expect(identical(stored!.image, replacement), isTrue);
      expect(manager.hasPendingImage(imageId), isFalse);
    });
  });

  testWidgets('collapsed pending reservations settle one active outcome', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      final payload = base64.decode('AAAA');
      final firstPrevious = manager.reserveExplicitImageIdForNumber(5, 7);
      manager.storePendingImage(
        7,
        payload: payload,
        format: 100,
        sourceSignature: 1,
        imageNumber: 5,
        mappedImageId: 7,
        previousImageId: firstPrevious.previousImageId,
      );
      final secondPrevious = manager.reserveExplicitImageIdForNumber(5, 7);
      manager.storePendingImage(
        7,
        payload: payload,
        format: 100,
        sourceSignature: 1,
        imageNumber: 5,
        mappedImageId: 7,
        previousImageId: secondPrevious.previousImageId,
      );

      expect(await manager.resolveImage(7), isNull);
      expect(manager.imageIdForNumber(5), isNull);
      expect(manager.hasPendingImage(7), isFalse);
    });
  });

  test('terminalGraphicsSourceSignature distinguishes content and is stable',
      () {
    final a = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));
    final b = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));
    final c =
        Uint8List.fromList(List<int>.generate(5000, (i) => (i + 1) % 251));
    expect(terminalGraphicsSourceSignature(a), isNot(0));
    expect(
      terminalGraphicsSourceSignature(a),
      terminalGraphicsSourceSignature(b),
      reason: 'identical bytes hash equally',
    );
    expect(
      terminalGraphicsSourceSignature(a),
      isNot(terminalGraphicsSourceSignature(c)),
      reason: 'different bytes hash differently',
    );
    expect(terminalGraphicsSourceSignature(Uint8List(0)), 0);
  });

  test('terminalGraphicsSourceSignature is a 32-bit value', () {
    // The MonkeyMux server matches this hash as a Go uint32, so it must never
    // exceed 32 bits or exactly match a known reference value.
    final bytes = Uint8List.fromList('hello'.codeUnits);
    final sig = terminalGraphicsSourceSignature(bytes);
    expect(sig, lessThanOrEqualTo(0xFFFFFFFF));
    expect(sig, 3314369016, reason: 'must match the Go server FNV-1a-32');
  });

  testWidgets('heldImageSignatures reports decoded and pending images', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      // Two store-only images: one decoded (referenced), one left pending.
      terminal
        ..write('\x1b_Ga=t,i=71,f=100;$pngBase64\x1b\\')
        ..write('\x1b_Ga=t,i=72,f=100;$pngBase64\x1b\\');
      await _decodeDeferredImage(terminal, 71);

      final held = terminal.heldImageSignatures();
      expect(held.keys, containsAll(<int>[71, 72]));
      expect(held[71], isNot(0));
      // Both images share identical bytes, so their signatures match.
      expect(held[71], held[72]);
      expect(terminal.graphics.imageById(71), isNotNull);
      expect(terminal.graphics.hasPendingImage(72), isTrue);
    });
  });

  testWidgets('held signatures exclude queued animation mutations', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=t,i=73,f=100;$pngBase64\x1b\\');
      await _decodeDeferredImage(terminal, 73);
      expect(terminal.heldImageSignatures(), contains(73));

      await terminalGraphicsDecodeGate.acquire();
      await terminalGraphicsDecodeGate.acquire();
      await terminalGraphicsDecodeGate.acquire();
      try {
        terminal.write(
          '\x1b_Ga=f,i=73,f=32,s=1,v=1,q=2;$pixel\x1b\\',
        );
        expect(
          terminal.heldImageSignatures(),
          isNot(contains(73)),
          reason: 'a queued frame must dirty the held root before decode',
        );
      } finally {
        terminalGraphicsDecodeGate.release();
        terminalGraphicsDecodeGate.release();
        terminalGraphicsDecodeGate.release();
      }
    });
  });

  testWidgets('pending decode promotion preserves animation-dirty state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      manager.storePendingImage(
        74,
        payload: base64.decode('AAAA'),
        format: 100,
        sourceSignature: 555,
      );
      expect(manager.heldImageSignatures(), {74: 555});

      manager.markImageAnimationDirty(74);
      expect(manager.heldImageSignatures(), isEmpty);
      manager.storeDecodedImageWithId(
        74,
        DecodedTerminalImage.single(await _buildImage(1, 1)),
        sourceSignature: 555,
      );

      expect(manager.heldImageSignatures(), isEmpty);
      manager.markImageAnimationDirty(74);
      manager.settleImageAnimationMutation(74);
      expect(
        manager.heldImageSignatures(),
        isEmpty,
        reason: 'one of two pending mutations remains unsettled',
      );
      manager.settleImageAnimationMutation(74);
      expect(manager.heldImageSignatures(), {74: 555});
    });
  });

  testWidgets(
    'heldImageSignatures omits an image that would not survive a clear',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(3, 2);
        final terminal = Terminal();

        // A physical a=T image with no protocol id is stored under an
        // auto-assigned id and is NOT retained, so entering the alternate
        // screen (a window switch's `CSI ? 1049 h`) drops it. It must therefore
        // never be reported as held: doing so would let the server skip
        // re-transmitting it, and then the switch's own clear would drop it,
        // leaving the redrawn placement blank.
        terminal.write('\x1b_Ga=T,f=100;$pngBase64\x1b\\');
        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        expect(terminal.graphics.hasPlacements, isTrue);
        expect(
          terminal.heldImageSignatures(),
          isEmpty,
          reason: 'a non-retained image must not be reported as held',
        );

        // Entering the alternate screen clears it, confirming the image really
        // does not survive — exactly why it must not be reported.
        terminal.write('\x1b[?1049h');
        expect(terminal.graphics.hasPlacements, isFalse);
      });
    },
  );

  testWidgets('decodeTerminalImage downscales an oversized image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A 2400x1200 PNG must come back capped to 1280 on its longest side with
      // aspect ratio preserved (so it can't blow up decoded memory on mobile).
      final pngBytes = base64.decode(await _buildPngBase64(2400, 1200));
      final image = await decodeTerminalImage(pngBytes, format: 100);
      expect(image, isNotNull);
      expect(image!.width, 1280);
      expect(image.height, 640);
    });
  });

  testWidgets('decodeTerminalImage leaves a small image untouched', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(320, 200));
      final image = await decodeTerminalImage(pngBytes, format: 100);
      expect(image, isNotNull);
      expect(image!.width, 320);
      expect(image.height, 200);
    });
  });

  testWidgets('static encoded root keeps a gapless zero duration', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final decoded = await decodeTerminalImageSequence(
        base64.decode(await _buildPngBase64(3, 2)),
      );

      expect(decoded, isNotNull);
      expect(decoded!.frames, hasLength(1));
      expect(decoded.frames.single.duration, Duration.zero);
    });
  });

  testWidgets('animated GIF decode preserves every frame and duration', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final decoded = await decodeTerminalImageSequence(
        base64.decode(_animatedGifBase64),
        format: 100,
      );

      expect(decoded, isNotNull);
      expect(decoded!.frames, hasLength(2));
      expect(decoded.frames[0].duration, const Duration(milliseconds: 70));
      expect(decoded.frames[1].duration, const Duration(milliseconds: 130));
      expect(decoded.repetitionCount, -1);
      expect(
        await _pixelColor(decoded.frames[0].image, 0, 0),
        const Color(0xFFFF0000),
      );
      expect(
        await _pixelColor(decoded.frames[1].image, 0, 0),
        const Color(0xFF0000FF),
      );
    });
  });

  testWidgets('decodeTerminalImage keeps first-frame compatibility for GIF', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await decodeTerminalImage(
        base64.decode(_animatedGifBase64),
      );

      expect(image, isNotNull);
      expect(await _pixelColor(image!, 0, 0), const Color(0xFFFF0000));
    });
  });

  testWidgets('first-frame sequence decode does not expand an animated GIF', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final decoded = await decodeTerminalImageFirstFrameSequence(
        base64.decode(_animatedGifBase64),
      );

      expect(decoded, isNotNull);
      expect(decoded!.frames, hasLength(1));
      expect(decoded.sourceWidth, 3);
      expect(decoded.sourceHeight, 3);
    });
  });

  testWidgets('animation timing carries overshoot into the next frame', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,i=61,f=100,c=2,r=2;$_animatedGifBase64\x1b\\',
      );
      var waited = 0;
      while ((terminal.graphics.imageById(61)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(61)!;

      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 80),
        ),
        isTrue,
      );
      expect(image.currentFrame, 2);
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 120),
        ),
        isTrue,
      );
      expect(image.currentFrame, 1);
    });
  });

  testWidgets('zero-delay GIF frames use a finite playback floor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,i=6,f=100,c=2,r=2;$_zeroDelayGifBase64\x1b\\',
      );

      var waited = 0;
      while ((terminal.graphics.imageById(6)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(6)!;
      expect(image.frameDuration(1), const Duration(milliseconds: 10));
      expect(terminal.graphics.hasActiveAnimations, isTrue);
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 10),
        ),
        isTrue,
      );
      expect(image.currentFrame, 2);
    });
  });

  testWidgets('Kitty a=f and a=a advance, stop and honor loop limits', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);

      terminal
        ..write('\x1b_Ga=T,i=7,f=32,s=1,v=1,c=1,r=1;$red\x1b\\')
        ..write('\x1b_Ga=f,i=7,f=32,s=1,v=1,z=50;$blue\x1b\\')
        ..write('\x1b_Ga=a,i=7,r=1,z=30,s=3,v=2\x1b\\');

      var waited = 0;
      while (waited < 2000) {
        final image = terminal.graphics.imageById(7);
        if (image?.frameCount == 2 &&
            image?.animationState == TerminalAnimationState.running) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(7);
      expect(image, isNotNull);
      expect(image!.frameCount, 2);
      expect(image.currentFrame, 1);
      expect(image.frameDuration(1), const Duration(milliseconds: 30));
      expect(image.frameDuration(2), const Duration(milliseconds: 50));
      expect(image.animationState, TerminalAnimationState.running);
      expect(terminal.graphics.hasActiveAnimations, isTrue);

      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 29),
        ),
        isFalse,
      );
      expect(image.currentFrame, 1);
      expect(
        terminal.graphics.advanceAnimations(const Duration(milliseconds: 1)),
        isTrue,
      );
      expect(image.currentFrame, 2);
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 50),
        ),
        isFalse,
        reason: 'v=2 stops at the first completed-loop boundary',
      );
      expect(image.currentFrame, 2);
      expect(terminal.graphics.hasActiveAnimations, isFalse);

      terminal.write('\x1b_Ga=a,i=7,c=1,s=1\x1b\\');
      waited = 0;
      while (image.animationState != TerminalAnimationState.stopped &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(image.currentFrame, 1);
      expect(image.animationState, TerminalAnimationState.stopped);
      expect(
        terminal.graphics.advanceAnimations(const Duration(seconds: 1)),
        isFalse,
      );
      expect(image.currentFrame, 1);
    });
  });

  testWidgets('Kitty loading mode resumes when another frame arrives', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      final green = base64.encode(<int>[0, 255, 0, 255]);

      terminal
        ..write('\x1b_Ga=T,i=17,f=32,s=1,v=1,c=1,r=1;$red\x1b\\')
        ..write('\x1b_Ga=f,i=17,f=32,s=1,v=1,z=50;$blue\x1b\\')
        ..write('\x1b_Ga=a,i=17,r=1,z=20,s=2\x1b\\');

      var waited = 0;
      while (waited < 2000) {
        final image = terminal.graphics.imageById(17);
        if (image?.frameCount == 2 &&
            image?.animationState == TerminalAnimationState.loading) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(17)!;
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 20),
        ),
        isTrue,
      );
      expect(image.currentFrame, 2);
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      expect(terminal.graphics.hasActiveAnimations, isFalse);

      terminal.write('\x1b_Ga=f,i=17,f=32,s=1,v=1,z=40;$green\x1b\\');
      waited = 0;
      while (image.frameCount != 3 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.hasActiveAnimations, isTrue);
      expect(terminal.graphics.advanceAnimations(Duration.zero), isTrue);
      expect(image.currentFrame, 3);
      expect(
        await _pixelColor(image.image, 0, 0),
        const Color(0xFF00FF00),
      );
    });
  });

  testWidgets('repeated running control resets the finite loop counter', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      terminal
        ..write('\x1b_Ga=T,i=18,f=32,s=1,v=1;$red\x1b\\')
        ..write('\x1b_Ga=f,i=18,f=32,s=1,v=1,z=20;$blue\x1b\\')
        ..write('\x1b_Ga=a,i=18,r=1,z=20,s=3,v=3\x1b\\');

      var waited = 0;
      while ((terminal.graphics.imageById(18)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(18)!;
      terminal.graphics
        ..advanceAnimations(const Duration(milliseconds: 20))
        ..advanceAnimations(const Duration(milliseconds: 20));
      expect(image.currentFrame, 1, reason: 'first loop completed');

      terminal.write('\x1b_Ga=a,i=18,s=3\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      terminal.graphics
        ..advanceAnimations(const Duration(milliseconds: 20))
        ..advanceAnimations(const Duration(milliseconds: 20));

      expect(image.currentFrame, 1);
      expect(terminal.graphics.hasActiveAnimations, isTrue);
      terminal.graphics
        ..advanceAnimations(const Duration(milliseconds: 20))
        ..advanceAnimations(const Duration(milliseconds: 20));
      expect(image.currentFrame, 2);
      expect(terminal.graphics.hasActiveAnimations, isFalse);
    });
  });

  testWidgets('a=f reports success and structured failures', (tester) async {
    await tester.runAsync(() async {
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      terminal
        ..write('\x1b_Ga=T,i=19,f=32,s=1,v=1;$pixel\x1b\\')
        ..write('\x1b_Ga=f,i=19,f=32,s=1,v=1,q=0;$pixel\x1b\\');
      var waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, '\x1b_Gi=19;OK\x1b\\');

      responses.clear();
      terminal.write('\x1b_Ga=f,i=999,f=32,s=1,v=1,q=0;$pixel\x1b\\');
      waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('ENOENT'));

      responses.clear();
      terminal.write(
        '\x1b_Ga=f,i=19,f=32,s=1,v=1,x=2,q=0;$pixel\x1b\\',
      );
      waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('EINVAL'));

      responses.clear();
      terminal.write('\x1b_Ga=f,i=19,q=0\x1b\\');
      expect(responses.single, contains('EINVAL: missing frame data'));

      responses.clear();
      terminal.write('\x1b_Ga=f,i=19,q=2\x1b\\');
      expect(responses, isEmpty);
    });
  });

  testWidgets('empty a=f failure preserves per-image response order', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(512, 512);
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      terminal
        ..write('\x1b_Ga=t,i=66,f=100;$pngBase64\x1b\\')
        ..write('\x1b_Ga=f,i=66,f=32,s=1,v=1,q=0;$pixel\x1b\\')
        ..write('\x1b_Ga=f,i=66,q=0\x1b\\');

      var waited = 0;
      while (responses.length < 2 && waited < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses, hasLength(2));
      expect(responses.first, '\x1b_Gi=66;OK\x1b\\');
      expect(responses.last, contains('EINVAL: missing frame data'));
    });
  });

  testWidgets('Kitty a=f composes partial frames and a=c copies regions', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);
      final redGreen = base64.encode(<int>[
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
      ]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);

      terminal
        ..write('\x1b_Ga=t,i=8,f=32,s=2,v=1;$redGreen\x1b\\')
        ..write(
          '\x1b_Ga=f,i=8,f=32,s=1,v=1,x=1,c=1,X=1,z=60,q=2;'
          '$blue\x1b\\',
        );

      var waited = 0;
      while ((terminal.graphics.imageById(8)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(8)!;
      final second = image.imageAtFrame(2)!;
      expect(await _pixelColor(second, 0, 0), const Color(0xFFFF0000));
      expect(await _pixelColor(second, 1, 0), const Color(0xFF0000FF));

      terminal.write(
        '\x1b_Ga=c,i=8,r=2,c=1,x=0,y=0,X=1,Y=0,w=1,h=1,C=1,q=0\x1b\\',
      );
      waited = 0;
      while (await _pixelColor(image.imageAtFrame(1)!, 0, 0) !=
              const Color(0xFF0000FF) &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final root = image.imageAtFrame(1)!;
      expect(await _pixelColor(root, 0, 0), const Color(0xFF0000FF));
      expect(await _pixelColor(root, 1, 0), const Color(0xFF00FF00));
      expect(responses, ['\x1b_Gi=8;OK\x1b\\']);

      responses.clear();
      terminal.write(
        '\x1b_Ga=c,i=8,r=2,c=1,x=0,y=0,X=1,Y=0,w=1,h=1,C=1,q=1\x1b\\',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(responses, isEmpty);
    });
  });

  testWidgets('Copilot c-only animation survives the following prompt', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await _buildPngBase64(240, 160);
      final teal = await _buildPngBase64(
        240,
        160,
        color: const Color(0xFF00A6A6),
      );
      final purple = await _buildPngBase64(
        240,
        160,
        color: const Color(0xFF5B5BD6),
      );
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal
        ..write('\x1b_Ga=T,f=100,i=3102001,q=2,c=30,m=0;$root\x1b\\')
        ..write('\x1b_Ga=a,i=3102001,r=1,z=450,q=2\x1b\\')
        ..write(
          '\x1b_Ga=f,f=100,i=3102001,q=2,z=450,X=1,m=0;'
          '$teal\x1b\\',
        )
        ..write(
          '\x1b_Ga=f,f=100,i=3102001,q=2,z=450,X=1,m=0;'
          '$purple\x1b\\',
        )
        ..write('\x1b_Ga=a,i=3102001,s=3,v=1,q=2\x1b\\');

      var waited = 0;
      while ((terminal.graphics.imageById(3102001)?.frameCount ?? 0) < 3 &&
          waited < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.buffer.cursorY, 10);
      expect(terminal.graphics.placements, hasLength(1));

      // Copilot/shell redraws the current row after the image command. The
      // placement is anchored above it and must remain active.
      terminal.write('\x1b[2Kprompt');
      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.hasActiveAnimations, isTrue);

      final image = terminal.graphics.imageById(3102001)!;
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 450),
        ),
        isTrue,
      );
      expect(image.currentFrame, 2);
    });
  });

  testWidgets('protocol animation frames respect the decoded memory cap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager(maxMemoryBytes: 8);
      final root = await _buildImage(1, 1);
      final firstFrame = await _buildImage(1, 1);
      final rejectedFrame = await _buildImage(1, 1);
      manager.storeImageWithId(1, root);

      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(firstFrame),
        ),
        TerminalAnimationFrameResult.success,
      );
      expect(manager.currentMemoryBytes, 8);
      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(rejectedFrame),
        ),
        TerminalAnimationFrameResult.noSpace,
      );
      expect(manager.imageById(1)!.frameCount, 2);
      expect(manager.currentMemoryBytes, 8);
    });
  });

  testWidgets('protocol animation frames respect the frame-count cap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      final root = await _buildImage(1, 1);
      manager.storeDecodedImageWithId(
        1,
        DecodedTerminalImage(
          frames: List<TerminalImageFrame>.generate(
            256,
            (_) => TerminalImageFrame(root),
          ),
          sourceWidth: 1,
          sourceHeight: 1,
        ),
      );
      final rejectedFrame = await _buildImage(1, 1);

      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(rejectedFrame),
        ),
        TerminalAnimationFrameResult.noSpace,
      );
      expect(manager.imageById(1)!.frameCount, 256);
      expect(rejectedFrame.debugDisposed, isTrue);
    });
  });

  testWidgets('future r= frame numbers append and existing numbers edit', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      manager.storeImageWithId(1, await _buildImage(1, 1));

      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(await _buildImage(1, 1)),
          editFrame: 2,
        ),
        TerminalAnimationFrameResult.success,
      );
      expect(manager.imageById(1)!.frameCount, 2);

      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(await _buildImage(1, 1)),
          editFrame: 99,
        ),
        TerminalAnimationFrameResult.success,
      );
      expect(manager.imageById(1)!.frameCount, 3);

      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(await _buildImage(1, 1)),
          editFrame: 2,
        ),
        TerminalAnimationFrameResult.success,
      );
      expect(manager.imageById(1)!.frameCount, 3);
    });
  });

  testWidgets('decoded root storage rejects sequences over the memory cap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager(maxMemoryBytes: 4);
      final rejectedImages = <ui.Image>[
        await _buildImage(1, 1),
        await _buildImage(1, 1),
      ];
      final rejected = DecodedTerminalImage(
        frames:
            rejectedImages.map((image) => TerminalImageFrame(image)).toList(),
        sourceWidth: 1,
        sourceHeight: 1,
      );

      expect(manager.storeDecodedImage(rejected), 0);
      expect(rejectedImages.every((image) => image.debugDisposed), isTrue);
      expect(manager.imageCount, 0);
      expect(manager.currentMemoryBytes, 0);

      final replacingManager = GraphicsManager(maxMemoryBytes: 8);
      final existing = await _buildImage(1, 1);
      replacingManager.storeImageWithId(7, existing);
      final replacementImages = <ui.Image>[
        await _buildImage(1, 1),
        await _buildImage(1, 1),
        await _buildImage(1, 1),
      ];
      final replacement = DecodedTerminalImage(
        frames: replacementImages
            .map((image) => TerminalImageFrame(image))
            .toList(),
        sourceWidth: 1,
        sourceHeight: 1,
      );

      expect(replacingManager.storeDecodedImageWithId(7, replacement), 0);
      expect(
        replacementImages.every((image) => image.debugDisposed),
        isTrue,
      );
      expect(identical(replacingManager.imageById(7)!.image, existing), isTrue);
      expect(replacingManager.currentMemoryBytes, 4);
    });
  });

  testWidgets('impossible animation frame does not evict unrelated images', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager(maxMemoryBytes: 100);
      manager
        ..storeImageWithId(1, await _buildImage(3, 5))
        ..storeImageWithId(2, await _buildImage(1, 1));
      final rejectedFrame = await _buildImage(3, 5);

      expect(manager.currentMemoryBytes, 64);
      expect(
        await manager.addAnimationFrame(
          1,
          DecodedTerminalImage.single(rejectedFrame),
        ),
        TerminalAnimationFrameResult.noSpace,
      );

      expect(manager.imageById(2), isNotNull);
      expect(manager.currentMemoryBytes, 64);
      expect(rejectedFrame.debugDisposed, isTrue);
    });
  });

  testWidgets('protocol animation consumes every decoded payload frame', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final manager = GraphicsManager();
      manager.storeImageWithId(1, await _buildImage(3, 3));
      final decoded = await decodeTerminalImageSequence(
        base64.decode(_animatedGifBase64),
      );
      expect(decoded, isNotNull);
      final payloadImages =
          decoded!.frames.map((frame) => frame.image).toList();

      expect(
        await manager.addAnimationFrame(1, decoded),
        TerminalAnimationFrameResult.success,
      );
      expect(payloadImages.every((image) => image.debugDisposed), isTrue);
      expect(manager.imageById(1)!.frameCount, 2);
    });
  });

  testWidgets('retransmitting an animated id resets stale protocol frames', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);

      terminal
        ..write('\x1b_Ga=t,i=27,f=32,s=1,v=1;$red\x1b\\')
        ..write('\x1b_Ga=f,i=27,f=32,s=1,v=1,z=50;$blue\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(27)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(27)!.frameCount, 2);
      expect(
        terminal.heldImageSignatures(),
        isNot(contains(27)),
        reason:
            'a root-only signature cannot prove that animation state is current',
      );

      terminal.write('\x1b_Ga=t,i=27,f=32,s=1,v=1;$red\x1b\\');
      terminal.graphics.imageForPlacement(27);
      waited = 0;
      while ((terminal.graphics.imageById(27)?.frameCount ?? 2) != 1 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(27)!.frameCount, 1);
      expect(
        terminal.graphics.imageById(27)!.animationState,
        TerminalAnimationState.stopped,
      );
    });
  });

  testWidgets('image id and number animation commands share one decode queue', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);

      terminal
        ..write('\x1b_Ga=T,i=28,I=9,f=32,s=1,v=1;$red\x1b\\')
        ..write('\x1b_Ga=f,I=9,f=32,s=1,v=1,z=50;$blue\x1b\\')
        ..write('\x1b_Ga=a,I=9,r=1,z=40,s=3,v=1\x1b\\');

      var waited = 0;
      while (waited < 2000) {
        final image = terminal.graphics.imageById(28);
        if (image?.frameCount == 2 &&
            image?.animationState == TerminalAnimationState.running) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      final image = terminal.graphics.imageById(28);
      expect(image, isNotNull);
      expect(image!.frameCount, 2);
      expect(image.frameDuration(1), const Duration(milliseconds: 40));
      expect(image.animationState, TerminalAnimationState.running);
    });
  });

  testWidgets('newest explicit id remains authoritative for an image number', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final slowPng = await _buildPngBase64(1200, 800);
      final fastPng = await _buildPngBase64(2, 2);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=100,I=5,f=100,c=4,r=2;$slowPng\x1b\\')
        ..write('\x1b_Ga=T,i=200,I=5,f=100,c=4,r=2;$fastPng\x1b\\');

      var waited = 0;
      while ((terminal.graphics.imageById(100) == null ||
              terminal.graphics.imageById(200) == null) &&
          waited < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(100), isNotNull);
      expect(terminal.graphics.imageById(200), isNotNull);
      expect(terminal.graphics.imageIdForNumber(5), 200);
    });
  });

  testWidgets('queued I= frame keeps its command-time image mapping', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final slowPng = await _buildPngBase64(1200, 800);
      final fastPng = await _buildPngBase64(2, 2);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      final terminal = Terminal();

      terminal
        ..write(
          '\x1b_Ga=T,i=100,I=5,f=100,c=4,r=2,C=1;$slowPng\x1b\\',
        )
        ..write('\x1b_Ga=f,I=5,f=32,s=1,v=1,q=2;$blue\x1b\\')
        ..write('\x1b_Ga=t,i=200,I=5,f=100;$fastPng\x1b\\');

      var waited = 0;
      while ((terminal.graphics.imageById(100)?.frameCount ?? 0) < 2 &&
          waited < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(100)?.frameCount, 2);
      expect(terminal.graphics.imageIdForNumber(5), 200);
      expect(terminal.graphics.imageById(200), isNull);
      expect(terminal.graphics.hasPendingImage(200), isTrue);
    });
  });

  testWidgets('I=-only root reserves a new mapping for queued frames', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=T,i=1,I=5,f=32,s=1,v=1,C=1;$red\x1b\\');
      var waited = 0;
      while (terminal.graphics.imageById(1) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageIdForNumber(5), 1);

      terminal
        ..write('\x1b_Ga=t,I=5,f=32,s=1,v=1,q=2;$red\x1b\\')
        ..write('\x1b_Ga=f,I=5,f=32,s=1,v=1,q=2;$blue\x1b\\');
      final replacementId = terminal.graphics.imageIdForNumber(5)!;
      expect(replacementId, isNot(1));

      waited = 0;
      while (
          (terminal.graphics.imageById(replacementId)?.frameCount ?? 0) < 2 &&
              waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(1)!.frameCount, 1);
      expect(terminal.graphics.imageById(replacementId)!.frameCount, 2);
    });
  });

  testWidgets('failed I=-only root restores the previous image mapping', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final terminal = Terminal();

      terminal.write(
        '\x1b_Ga=T,i=1,I=5,f=32,s=1,v=1,C=1;$pixel\x1b\\',
      );
      var waited = 0;
      while (terminal.graphics.imageById(1) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageIdForNumber(5), 1);

      terminal.write(
        '\x1b_Ga=T,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\',
      );
      waited = 0;
      while (terminal.graphics.imageIdForNumber(5) != 1 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), 1);
      expect(terminal.graphics.imageById(1), isNotNull);

      terminal.write(
        '\x1b_Ga=T,i=2,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\',
      );
      waited = 0;
      while (terminal.graphics.imageIdForNumber(5) != 1 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), 1);
      expect(terminal.graphics.imageById(2), isNull);

      terminal.write(
        '\x1b_Ga=t,i=3,I=5,f=32,s=0,v=0,q=2;$pixel\x1b\\',
      );
      expect(terminal.graphics.imageIdForNumber(5), 3);
      expect(terminal.graphics.imageById(3), isNull);
      expect(terminal.graphics.hasPendingImage(3), isTrue);
      terminal.graphics.imageForPlacement(3);
      waited = 0;
      while (terminal.graphics.imageIdForNumber(5) != 1 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), 1);
      expect(terminal.graphics.hasPendingImage(3), isFalse);

      terminal.graphics.registerImageNumber(6, 2);
      terminal
        ..write('\x1b_Ga=t,i=4,I=5,f=32,s=0,v=0,q=2;$pixel\x1b\\')
        ..write('\x1b_Ga=t,i=4,I=6,f=32,s=0,v=0,q=2;$pixel\x1b\\');
      expect(terminal.graphics.imageIdForNumber(5), 4);
      expect(terminal.graphics.imageIdForNumber(6), 4);
      terminal.graphics.imageForPlacement(4);
      waited = 0;
      while ((terminal.graphics.imageIdForNumber(5) != 1 ||
              terminal.graphics.imageIdForNumber(6) != 2) &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), 1);
      expect(terminal.graphics.imageIdForNumber(6), 2);
    });
  });

  testWidgets('I= root with i=0 stores under its reserved command id', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=0,I=7,f=32,s=1,v=1,C=1,q=2;$red\x1b\\')
        ..write('\x1b_Ga=f,I=7,f=32,s=1,v=1,q=2;$blue\x1b\\');
      final reservedId = terminal.graphics.imageIdForNumber(7)!;
      var waited = 0;
      while ((terminal.graphics.imageById(reservedId)?.frameCount ?? 0) < 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(reservedId, greaterThan(0));
      expect(terminal.graphics.imageById(reservedId)?.frameCount, 2);
    });
  });

  testWidgets('failed remap chains skip failed predecessor reservations', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=t,i=1,I=5,f=32,s=1,v=1,q=2;$pixel\x1b\\')
        ..write('\x1b_Ga=T,i=100,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\')
        ..write('\x1b_Ga=T,i=200,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\');

      var waited = 0;
      while (terminal.graphics.imageIdForNumber(5) != 1 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), 1);
      expect(terminal.graphics.imageById(100), isNull);
      expect(terminal.graphics.imageById(200), isNull);
    });
  });

  testWidgets('synchronous remap survives completion of older reservations', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final pngBase64 = await _buildPngBase64(1200, 800);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=100,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\')
        ..write('\x1b_Ga=T,i=200,I=5,f=100,C=1,q=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=a,i=300,I=5,q=2\x1b\\');
      expect(terminal.graphics.imageIdForNumber(5), 300);

      var waited = 0;
      while (terminal.graphics.imageById(200) == null && waited < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(100), isNull);
      expect(terminal.graphics.imageById(200), isNotNull);
      expect(terminal.graphics.imageIdForNumber(5), 300);
    });
  });

  testWidgets('same-id concurrent reservations keep a later successful root', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final pngBase64 = await _buildPngBase64(8, 8);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=100,I=5,f=32,s=0,v=0,C=1,q=2;$pixel\x1b\\')
        ..write('\x1b_Ga=T,i=100,I=5,f=100,C=1,q=2;$pngBase64\x1b\\');

      var waited = 0;
      while (terminal.graphics.imageById(100) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(100), isNotNull);
      expect(terminal.graphics.imageIdForNumber(5), 100);
    });
  });

  testWidgets('same-id concurrent failures restore a null predecessor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final invalid = base64.encode(<int>[255, 0, 0, 255]);
      final terminal = Terminal();

      await terminalGraphicsDecodeGate.acquire();
      await terminalGraphicsDecodeGate.acquire();
      await terminalGraphicsDecodeGate.acquire();
      try {
        terminal
          ..write('\x1b_Ga=T,i=100,I=5,f=32,s=0,v=0,C=1,q=2;$invalid\x1b\\')
          ..write('\x1b_Ga=T,i=100,I=5,f=32,s=0,v=0,C=1,q=2;$invalid\x1b\\');
        expect(terminal.graphics.imageIdForNumber(5), 100);
      } finally {
        terminalGraphicsDecodeGate.release();
        terminalGraphicsDecodeGate.release();
        terminalGraphicsDecodeGate.release();
      }

      var waited = 0;
      while (terminal.graphics.imageIdForNumber(5) != null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageIdForNumber(5), isNull);
      expect(terminal.graphics.imageById(100), isNull);
    });
  });

  testWidgets('invalid a=c reports a protocol error unless silenced', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      terminal
        ..write('\x1b_Ga=t,i=29,f=32,s=1,v=1;$red\x1b\\')
        ..write('\x1b_Ga=c,i=29,r=2,c=1,w=1,h=1\x1b\\');
      var waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('ENOENT'));

      responses.clear();
      terminal.write('\x1b_Ga=c,i=29,r=2,c=1,w=1,h=1,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(responses, isEmpty);

      terminal.write('\x1b_Ga=c,i=999,r=1,c=1,q=0\x1b\\');
      waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('ENOENT'));

      responses.clear();
      terminal.write('\x1b_Ga=c,i=29,q=0\x1b\\');
      waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('ENOENT'));
    });
  });

  testWidgets('unknown a=a target reports ENOENT unless silenced', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      terminal.write('\x1b_Ga=a,i=999,s=3,q=0\x1b\\');
      var waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, contains('ENOENT'));

      responses.clear();
      terminal.write('\x1b_Ga=a,i=999,s=3,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(responses, isEmpty);
    });
  });

  testWidgets('mapping-only a=a keeps a retained root lazily encoded', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=t,i=42,f=100,q=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=a,i=42,I=9,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terminal.graphics.imageIdForNumber(9), 42);
      expect(terminal.graphics.hasPendingImage(42), isTrue);
      expect(terminal.graphics.imageById(42), isNull);
    });
  });

  testWidgets('mapping-only commands keep image-number aliases bounded', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.graphics.storeImageWithId(1, await _buildImage(1, 1));

      for (var number = 1; number <= 300; number++) {
        terminal.write('\x1b_Ga=a,i=1,I=$number,q=2\x1b\\');
      }

      expect(terminal.graphics.imageIdForNumber(1), isNull);
      expect(terminal.graphics.imageIdForNumber(300), 1);
    });
  });

  testWidgets('targeted delete waits for an in-flight transmit', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(512, 512);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=73,f=100,c=8,r=4;$pngBase64\x1b\\')
        ..write('\x1b_Ga=d,d=I,i=73\x1b\\');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(terminal.graphics.imageById(73), isNull);
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('unkeyed delete waits for an in-flight unkeyed transmit', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(512, 512);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,f=100,c=8,r=4;$pngBase64\x1b\\')
        ..write('\x1b_Ga=d,d=a\x1b\\');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('queued positional delete snapshots the command-time cursor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final visiblePng = await _buildPngBase64(8, 8);
      final pendingPng = await _buildPngBase64(256, 256);
      final pixel = base64.encode(<int>[255, 0, 0, 255]);
      final terminal = Terminal();

      terminal.write(
        '\x1b_Ga=T,i=301,f=100,c=4,r=2,C=1;$visiblePng\x1b\\',
      );
      var waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      terminal
        ..write('\x1b_Ga=t,i=300,f=100;$pendingPng\x1b\\')
        ..write('\x1b_Ga=f,i=300,f=32,s=1,v=1,q=2;$pixel\x1b\\')
        ..write('\x1b[5;1H')
        ..write('\x1b_Ga=d,d=c,q=2\x1b\\')
        ..write('\x1b[H');

      waited = 0;
      while ((terminal.graphics.imageById(300)?.frameCount ?? 0) < 2 &&
          waited < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        terminal.graphics.placements.map((placement) => placement.imageId),
        contains(301),
        reason: 'd=c must target row 5 even though the cursor later moved home',
      );
    });
  });

  testWidgets('Kitty placeholder color can resolve high-byte image ids', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      const imageId = 42 + (2 << 24);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=t,i=$imageId,f=100;$pngBase64\x1b\\');

      // Referencing by the placeholder color (low byte 42) triggers the
      // deferred decode via the low-bits fallback.
      terminal.graphics.imageByPlaceholderColorId(42, bitWidth: 8);
      await _awaitImage(terminal, imageId);

      final stored = terminal.graphics.imageByPlaceholderColorId(
        42,
        bitWidth: 8,
      );
      expect(stored, isNotNull);
      expect(stored!.id, imageId);
    });
  });

  testWidgets('Kitty virtual transmit-and-place uses a virtual placement', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,U=1,i=43,f=100,c=3,r=2;$pngBase64\x1b\\');

      // U=1 means the client displays the image through Unicode placeholder
      // cells, so the terminal must not create a physical placement (that would
      // draw a duplicate image at the cursor). The virtual placement is
      // registered immediately even though the decode is deferred.
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        terminal.graphics.virtualPlacementById(43),
        isNotNull,
        reason: 'Unicode placeholder clients reference the virtual placement',
      );
      expect(
        terminal.graphics.imageById(43),
        isNull,
        reason:
            'virtual images stay encoded until visible placeholders need them',
      );
      expect(terminal.graphics.hasPendingImage(43), isTrue);

      await _decodeDeferredImage(terminal, 43);

      final stored = terminal.graphics.imageById(43);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
      expect(terminal.graphics.hasPlacements, isFalse);

      terminal.write('\x1b[2J');
      expect(
        terminal.graphics.imageById(43),
        isNotNull,
        reason: 'virtual placeholder redraws can still reuse the image bytes',
      );
    });
  });

  testWidgets(
    'virtual placement survives the alt-screen reattach clear',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(3, 2);
        final terminal = Terminal();

        // A full-screen TUI such as the Copilot CLI runs in the alternate
        // screen, so its images (and their virtual placements) live on the alt
        // buffer. Enter the alt screen, then transmit a virtual image with a
        // known cell grid (c=8, r=4).
        terminal.write('\x1b[?1049h');
        terminal.write('\x1b_Ga=T,U=1,i=43,f=100,c=8,r=4;$pngBase64\x1b\\');
        final before = terminal.graphics.virtualPlacementById(43);
        expect(before, isNotNull);
        expect(before!.cols, 8);
        expect(before.rows, 4);

        // The MonkeyMux reattach/window-switch replay re-enters the alternate
        // screen (`CSI ? 1049 h`), which clears it. The image bytes are
        // retained, and — because the app redraws only placeholder cells and
        // never re-sends the image or its virtual placement — the virtual
        // placement (the grid size the painter needs to slice the image) must
        // survive too. Before the fix this was wiped, so the painter guessed
        // the grid from visible cells and mis-sliced the image.
        terminal.write('\x1b[?1049h');

        final after = terminal.graphics.virtualPlacementById(43);
        expect(
          after,
          isNotNull,
          reason: 'entering the alt screen must not drop the virtual placement '
              'of a retained image',
        );
        expect(after!.cols, 8);
        expect(after.rows, 4);
      });
    },
  );

  testWidgets('Kitty protocol-id image survives clear for placeholder redraw', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,i=44,f=100,c=3,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.imageById(44), isNotNull);
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write('\x1b_Ga=d,d=i,i=44\x1b\\\x1b[2J');

      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        terminal.graphics.imageById(44),
        isNotNull,
        reason: 'placeholder redraws can follow a screen clear',
      );
    });
  });

  testWidgets('Kitty Unicode placeholder diacritics do not consume cells', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write('\x1b[38;5;42m$placeholder\u0305\u0305X');

    final line = terminal.buffer.lines[terminal.buffer.absoluteCursorY];
    expect(line.getCodePoint(0), kittyGraphicsPlaceholderCodePoint);
    expect(line.getCodePoint(1), 'X'.codeUnitAt(0));
    expect(line.getText(0, 2), '${placeholder}X');
  });

  testWidgets('Kitty Unicode row-only placeholders reset columns per row', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write(
      '\x1b[38;5;42m'
      '$placeholder\u0305$placeholder$placeholder\r\n'
      '$placeholder\u030D$placeholder$placeholder',
    );

    final placeholders = terminal.graphics.placeholders;
    expect(placeholders.map((p) => (p.row, p.col)).toList(), [
      (0, 0),
      (0, 1),
      (0, 2),
      (1, 0),
      (1, 1),
      (1, 2),
    ]);
  });

  testWidgets('placeholders survive the image decode that backs them', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();
      final placeholder =
          String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

      // The image transmit and the placeholder cells that reference it arrive
      // together, but the PNG decode completes asynchronously afterwards. The
      // decode must not drop the placeholder cells waiting on that image.
      terminal
        ..write('\x1b_Ga=T,U=1,i=77,f=100,c=3,r=2;$pngBase64\x1b\\')
        ..write('\x1b[38;2;0;0;77m'
            '$placeholder\u0305\u0305$placeholder\u0305\u030D'
            '$placeholder\u0305\u030E');

      expect(terminal.graphics.placeholders, isNotEmpty);
      final before = terminal.graphics.placeholders.length;

      // The painter references the backing image on the next frame, which
      // starts the deferred decode; that decode must not drop the placeholders.
      terminal.graphics.imageForPlacement(77);
      await _awaitImage(terminal, 77);

      expect(terminal.graphics.imageById(77), isNotNull);
      expect(
        terminal.graphics.placeholders.length,
        before,
        reason: 'storing the decoded image must not drop its placeholder cells',
      );
    });
  });

  testWidgets('Kitty Unicode placeholders stay attached across a scroll', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 100)..resize(20, 4);
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    terminal.write('\x1b[38;5;42m$placeholder\u0305\u0305');
    final placeholdersBefore = terminal.graphics.placeholders.length;
    expect(placeholdersBefore, greaterThan(0));

    // Emit far more lines than the 4-row viewport so the buffer scrolls. This
    // used to detach the line that owns the placeholder anchor, dropping it.
    for (var i = 0; i < 20; i++) {
      terminal.write('row $i\r\n');
    }

    expect(
      terminal.graphics.placeholders.every((p) => p.attached),
      isTrue,
      reason: 'scrolling must not orphan placeholder anchors',
    );
    expect(terminal.graphics.placeholders.length, placeholdersBefore);
  });

  testWidgets(
      'Kitty Unicode placeholders support high-byte diacritics above 127', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
    const imageId = 42 + (200 << 24);

    terminal
      ..graphics.storeImageWithId(imageId, await _buildImage(1, 1))
      ..write('\x1b[38;5;42m$placeholder\u0305\u0305\u20D4');

    final placeholders = terminal.graphics.placeholders;
    expect(placeholders, hasLength(1));
    expect(placeholders.single.imageId, imageId);
    expect(
      terminal.graphics.imageByPlaceholderColorId(
        placeholders.single.imageId,
        bitWidth: placeholders.single.imageIdBitWidth,
      ),
      isNotNull,
    );
  });

  testWidgets(
      'unresolvedPlaceholderImageIds lists placeholder ids with no image', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    // A placeholder cell referencing image id 77 whose bytes never arrived
    // (e.g. dropped by a bounded switch/reconnect replay) resolves to nothing.
    terminal.write('\x1b[38;5;77m$placeholder');
    final placeholders = terminal.graphics.placeholders;
    expect(placeholders, hasLength(1));
    expect(placeholders.single.imageId, 77);
    expect(terminal.unresolvedPlaceholderImageIds(), {77});

    // Once the bytes arrive (server replay of the requested id), the placeholder
    // resolves and the id drops out of the missing set.
    terminal.graphics.storeImageWithId(77, await _buildImage(1, 1));
    expect(terminal.unresolvedPlaceholderImageIds(), isEmpty);
  });

  testWidgets('unresolvedPlaceholderImageIds excludes still-pending images', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    // Image 88's bytes are in hand but not yet decoded (a store-only transmit
    // deferred to first paint). A placeholder for it must not be reported as
    // missing — re-requesting bytes already held would be wasteful.
    terminal.graphics.storePendingImage(
      88,
      payload: base64.decode('AAAA'),
      format: 100,
    );
    terminal.write('\x1b[38;5;88m$placeholder');
    expect(terminal.graphics.hasPendingImage(88), isTrue);
    expect(terminal.graphics.placeholders.single.imageId, 88);
    expect(terminal.unresolvedPlaceholderImageIds(), isNot(contains(88)));
  });

  testWidgets('unresolvedPlaceholderImageIds reports only the active buffer', (
    tester,
  ) async {
    final terminal = Terminal();
    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);

    // Draw an unresolved placeholder on the primary screen, then switch to the
    // alternate screen. Only the active buffer is visible and only it can be
    // repopulated by a replay, so the inactive primary-screen id must not be
    // reported while the alt screen is active — reporting it would request bytes
    // that land on the wrong buffer and get recorded as already handled.
    terminal.write('\x1b[38;5;55m$placeholder');
    expect(terminal.unresolvedPlaceholderImageIds(), {55});

    terminal.write('\x1b[?1049h'); // enter alternate screen
    expect(terminal.unresolvedPlaceholderImageIds(), isEmpty);

    terminal.write('\x1b[?1049l'); // back to the primary screen
    expect(terminal.unresolvedPlaceholderImageIds(), {55});
  });

  testWidgets('a=T advances the cursor below the image by r rows', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(2, 2);
      final terminal = Terminal();

      terminal.write('\x1b_Ga=T,f=100,r=3;$pngBase64\x1b\\X');

      // 'X' should land three rows below where the image was anchored.
      expect(terminal.buffer.lines[3].getText().trimRight(), 'X');
    });
  });

  testWidgets('a=T computes cursor rows when only c is specified', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(240, 160);
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal.write('\x1b_Ga=T,f=100,c=30;$pngBase64\x1b\\X');

      // 240x160 at 30 ten-pixel columns is 200 pixels high, or ten rows.
      expect(terminal.buffer.lines[10].getText().trimRight(), 'X');
      expect(terminal.buffer.lines[0].getText().trimRight(), isEmpty);
    });
  });

  testWidgets('inferred cursor rows are bounded by the viewport', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bytes = Uint8List(24);
      bytes.setRange(0, 8, const <int>[0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10]);
      final header = ByteData.view(bytes.buffer)
        ..setUint32(16, 1)
        ..setUint32(20, 0xFFFFFFFF);
      expect(header.getUint32(20), 0xFFFFFFFF);
      final terminal = Terminal()..resize(80, 24);

      terminal.write(
        '\x1b_Ga=T,f=100,c=2147483647;'
        '${base64.encode(bytes)}\x1b\\',
      );

      expect(terminal.buffer.cursorY, 23);
    });
  });

  testWidgets('compressed c-only placement computes rows and decodes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(240, 160));
      final compressed = base64.encode(ZLibEncoder().encode(pngBytes));
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal.write('\x1b_Ga=T,i=92,f=100,o=z,c=30;$compressed\x1b\\X');

      expect(terminal.buffer.lines[10].getText().trimRight(), 'X');
      await _awaitImage(terminal, 92);
      expect(terminal.graphics.imageById(92), isNotNull);
    });
  });

  testWidgets('c-only cursor rows use the effective source crop', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(240, 160);
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal.write(
        '\x1b_Ga=T,f=100,c=30,x=120;$pngBase64\x1b\\X',
      );

      // Cropping 120 pixels from the 240-pixel width leaves a 120x160 source.
      expect(terminal.buffer.lines[20].getText().trimRight(), 'X');
    });
  });

  testWidgets('JPEG c-only placement computes its cursor rows', (tester) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal.write(
        '\x1b_Ga=T,f=98,c=30;$_jpeg240x160Base64\x1b\\X',
      );

      expect(terminal.buffer.cursorY, 10);
      expect(terminal.buffer.lines[10].getText().trimRight(), 'X');
    });
  });

  testWidgets('pending a=p computes cursor rows when only c is specified', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(240, 160);
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);
      terminal.write('\x1b_Ga=t,f=100,i=42;$pngBase64\x1b\\');
      expect(terminal.graphics.hasPendingImage(42), isTrue);

      terminal.write('\x1b_Ga=p,i=42,c=30\x1b\\X');

      expect(terminal.buffer.lines[10].getText().trimRight(), 'X');
    });
  });

  testWidgets('a=T with C=1 leaves the cursor where it is', (tester) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(2, 2);
      final terminal = Terminal();

      // C=1 is the Kitty "do not move the cursor" policy: the following 'X' must
      // stay on the same row as the image anchor rather than dropping r rows.
      terminal.write('\x1b_Ga=T,f=100,r=3,C=1;$pngBase64\x1b\\X');

      expect(terminal.buffer.lines[0].getText().trimRight(), 'X');
      expect(terminal.buffer.lines[3].getText().trimRight(), isEmpty);
    });
  });

  testWidgets('explicit row spans retain geometry beyond the viewport', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(8, 8);
      final terminal = Terminal()..resize(80, 10);

      terminal.write(
        '\x1b_Ga=T,i=401,f=100,c=4,r=30;$pngBase64\x1b\\',
      );
      var waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements.single.rows, 30);

      terminal.write('\x1b_Ga=t,i=402,f=100,q=2;$pngBase64\x1b\\');
      terminal.graphics.imageForPlacement(402);
      await _awaitImage(terminal, 402);
      terminal.write('\x1b_Ga=p,i=402,c=4,r=30\x1b\\');
      expect(
        terminal.graphics.placements
            .where((placement) => placement.imageId == 402)
            .single
            .rows,
        30,
      );
    });
  });

  testWidgets('re-placing with the same image and placement id replaces', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(80, 24);
      terminal.write('\x1b_Ga=t,f=100,i=77,q=2;$pngBase64\x1b\\');
      terminal.graphics.imageForPlacement(77);
      await _awaitImage(terminal, 77);

      // A client moving an inline image during a scroll repaint (e.g. Grok
      // CLI) re-places it with the same p= at the new cursor position on
      // every frame. Each re-place must replace the previous placement, not
      // leave a stale copy one row behind.
      terminal
        ..write('\x1b[3;1H')
        ..write('\x1b_Ga=p,i=77,p=5,c=4,r=2,z=0,C=1,q=2\x1b\\')
        ..write('\x1b[6;2H')
        ..write('\x1b_Ga=p,i=77,p=5,c=4,r=2,z=0,C=1,q=2\x1b\\');

      final placement = terminal.graphics.placements
          .where((placement) => placement.imageId == 77)
          .single;
      expect(placement.clientPlacementId, 5);
      expect(placement.row, 5);
      expect(placement.col, 1);
    });
  });

  testWidgets('distinct placement ids of one image are all kept', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(80, 24);
      terminal.write('\x1b_Ga=t,f=100,i=78,q=2;$pngBase64\x1b\\');
      terminal.graphics.imageForPlacement(78);
      await _awaitImage(terminal, 78);

      terminal
        ..write('\x1b_Ga=p,i=78,p=1,c=2,r=1,C=1,q=2\x1b\\')
        ..write('\x1b[5;1H')
        ..write('\x1b_Ga=p,i=78,p=2,c=2,r=1,C=1,q=2\x1b\\');

      expect(
        terminal.graphics.placements
            .where((placement) => placement.imageId == 78)
            .map((placement) => placement.clientPlacementId),
        unorderedEquals([1, 2]),
      );
    });
  });

  testWidgets('placements without a placement id accumulate', (tester) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(80, 24);
      terminal.write('\x1b_Ga=t,f=100,i=79,q=2;$pngBase64\x1b\\');
      terminal.graphics.imageForPlacement(79);
      await _awaitImage(terminal, 79);

      terminal
        ..write('\x1b_Ga=p,i=79,c=2,r=1,C=1,q=2\x1b\\')
        ..write('\x1b[5;1H')
        ..write('\x1b_Ga=p,i=79,c=2,r=1,C=1,q=2\x1b\\');

      expect(
        terminal.graphics.placements
            .where((placement) => placement.imageId == 79)
            .length,
        2,
      );
    });
  });

  testWidgets('a=T with the same image and placement id replaces', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(80, 24);

      terminal
        ..write('\x1b[2;1H')
        ..write('\x1b_Ga=T,f=100,i=80,p=3,c=2,r=1,C=1,q=2;$pngBase64\x1b\\');
      await _awaitImage(terminal, 80);
      terminal
        ..write('\x1b[7;1H')
        ..write('\x1b_Ga=T,f=100,i=80,p=3,c=2,r=1,C=1,q=2;$pngBase64\x1b\\');
      var waited = 0;
      bool moved() {
        final placements = terminal.graphics.placements
            .where((placement) => placement.imageId == 80)
            .toList();
        return placements.length == 1 && placements.single.row == 6;
      }

      while (!moved() && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      final placement = terminal.graphics.placements
          .where((placement) => placement.imageId == 80)
          .single;
      expect(placement.row, 6);
    });
  });

  testWidgets('invalid graphics payload is ignored without placing', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100;bm90LWFuLWltYWdl\x1b\\');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(terminal.graphics.hasPlacements, isFalse);
    });
  });

  testWidgets('a viewport image keeps its row after clearing scrollback', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal(maxLines: 1000)..resize(40, 10);
      // Build some scrollback, then a marker line and the image right below it,
      // all kept inside the viewport.
      for (var i = 0; i < 20; i++) {
        terminal.write('pre $i\r\n');
      }
      terminal.write('MARKER\r\n');
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      int markerRow() {
        for (var i = 0; i < terminal.buffer.lines.length; i++) {
          if (terminal.buffer.lines[i].getText().contains('MARKER')) return i;
        }
        return -1;
      }

      expect(terminal.graphics.placements.single.row, markerRow() + 1);

      // Clearing the scrollback (CSI 3 J) shifts every surviving line up; the
      // image must move with its anchor line, not stay at the old absolute row.
      terminal.write('\x1b[3J');
      expect(terminal.graphics.hasPlacements, isTrue);
      expect(
        terminal.graphics.placements.single.row,
        markerRow() + 1,
        reason:
            'the image must stay glued to its content after clearScrollback',
      );
    });
  });

  testWidgets('terminal erases preserve physical image placements', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
        '\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.hasPlacements, isTrue);

      terminal.write('\x1b[2J');
      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'ED clears text/cell images, not physical Kitty placements',
      );
      terminal.write('\x1b[H\x1b[2K');
      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'EL must not delete physical Kitty placements',
      );
      terminal.write('\x1b[H\x1b[4X');
      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'ECH must not delete physical Kitty placements',
      );
    });
  });

  testWidgets('terminal erases remove Unicode cell-image references', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      final placeholder = String.fromCharCode(
        kittyGraphicsPlaceholderCodePoint,
      );
      terminal
        ..write(
          '\x1b_Ga=T,U=1,i=42,f=100,c=1,r=1;'
          '${await _buildPngBase64(2, 2)}\x1b\\',
        )
        ..write('\x1b[38;5;42m$placeholder\u0305\u0305\x1b[39m');
      expect(terminal.graphics.placeholders, hasLength(1));

      terminal.write('\x1b[H\x1b[2K');

      expect(terminal.graphics.placeholders, isEmpty);
      expect(
        terminal.graphics.hasPendingImage(42) ||
            terminal.graphics.imageById(42) != null,
        isTrue,
        reason: 'erasing a cell image must not free its retained image data',
      );
    });
  });

  testWidgets('Copilot C=1 animation survives a TUI screen redraw', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final red = base64.encode(<int>[255, 0, 0, 255]);
      final blue = base64.encode(<int>[0, 0, 255, 255]);
      final terminal = Terminal();
      terminal
        ..write(
          '\x1b_Ga=T,i=91,f=32,s=1,v=1,c=1,r=1,C=1;'
          '$red\x1b\\',
        )
        ..write('\x1b_Ga=f,i=91,f=32,s=1,v=1,z=40,X=1;$blue\x1b\\')
        ..write('\x1b_Ga=a,i=91,r=1,z=40,s=3,v=1\x1b\\');

      var waited = 0;
      while ((terminal.graphics.imageById(91)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.hasActiveAnimations, isTrue);

      // Copilot redraws its alternate-screen TUI immediately after the helper
      // returns. Standard text erases must not delete the physical animation.
      terminal.write('\x1b[2J\x1b[H\x1b[2Kprompt');

      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.hasActiveAnimations, isTrue);
      expect(
        terminal.graphics.advanceAnimations(
          const Duration(milliseconds: 40),
        ),
        isTrue,
      );
      expect(terminal.graphics.imageById(91)!.currentFrame, 2);
    });
  });

  testWidgets(
    'clearing does not dispose the decoded image (no use-after-free)',
    (tester) async {
      await tester.runAsync(() async {
        final terminal = Terminal();
        terminal.write(
          '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
          '\x1b\\',
        );
        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        final placement = terminal.graphics.placements.single;
        final image = terminal.graphics.imageById(placement.imageId)!.image;
        expect(image.debugDisposed, isFalse);

        // Terminal erases preserve physical placements and must never dispose an
        // image that a frame may already reference.
        terminal.write('\x1b[2J');
        expect(terminal.graphics.hasPlacements, isTrue);
        expect(
          image.debugDisposed,
          isFalse,
          reason: 'the decoded image must not be force-disposed on clear',
        );
      });
    },
  );

  testWidgets('an erase racing a physical decode preserves its placement', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal()..resize(40, 10);
      // Physical placements are independent of text erases, even when decode
      // finishes after the erase.
      terminal
        ..write('\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\')
        ..write('\x1b[H\x1b[2J\x1b[3J');

      // Give any pending decode time to complete.
      var waited = 0;
      while (waited < 600) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'ED/ECH must not invalidate a physical image placement',
      );
    });
  });

  testWidgets('an unrelated erase does not discard an in-flight image decode', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal()..resize(40, 10);
      terminal
        ..write('\x1b[H')
        ..write('\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}\x1b\\')
        // Erase a prompt/status row that does not intersect the image while the
        // decode is still in flight. Replay streams commonly contain such
        // erases after the image APC; they must not cancel the image.
        ..write('\x1b[10;1H\x1b[2K');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(
        terminal.graphics.hasPlacements,
        isTrue,
        reason: 'unrelated erases during replay must not drop the image',
      );
    });
  });

  testWidgets('images do not leak across the alternate screen', (tester) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.write(
        '\x1b_Ga=T,f=100,c=4,r=2;${await _buildPngBase64(8, 8)}'
        '\x1b\\',
      );
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.hasPlacements, isTrue);

      // The alternate screen has its own (empty) image set.
      terminal.write('\x1b[?47h');
      expect(terminal.graphics.hasPlacements, isFalse);

      // Returning to the main screen restores the image.
      terminal.write('\x1b[?47l');
      expect(terminal.graphics.hasPlacements, isTrue);
    });
  });

  testWidgets(
    'Kitty graphics a=d removes a placement the client deletes by id',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(4, 3);
        final terminal = Terminal();

        // Transmit-and-display a physical placement with an explicit image and
        // placement id, exactly as Copilot CLI does for its full-screen image
        // viewer (a=T, p=1, i=..., no Unicode placeholder).
        const imageId = 13912678;
        terminal
            .write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=8,r=4;$pngBase64\x1b\\');

        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
        expect(
          terminal.graphics.placements,
          hasLength(1),
          reason: 'the transmit-and-display must create a placement',
        );

        // Closing the viewer sends a delete-by-id (d=i). The placement must be
        // removed so it does not linger as a background overlay.
        terminal.write('\x1b_Ga=d,d=i,i=$imageId,p=1,q=2\x1b\\');

        expect(
          terminal.graphics.placements,
          isEmpty,
          reason: 'a=d,d=i must remove the matching placement',
        );
        expect(
          terminal.graphics.imageById(imageId),
          isNotNull,
          reason: 'a lowercase d=i deletes the placement but keeps image data',
        );
      });
    },
  );

  testWidgets(
    'Kitty graphics a=d,d=i matches the client placement id, not paint order',
    (tester) async {
      await tester.runAsync(() async {
        final pngBase64 = await _buildPngBase64(4, 3);
        final terminal = Terminal();

        // A first physical placement of a different image. Its decode finishes
        // before the next, so it takes the first internal placement slot.
        terminal.write('\x1b_Ga=T,i=999,p=7,f=100,c=4,r=2;$pngBase64\x1b\\');
        var waited = 0;
        while (terminal.graphics.placements.isEmpty && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }

        // The full-screen image, transmitted later, with client placement id 1.
        // Its internal placement id therefore differs from its p= value.
        const imageId = 13912678;
        terminal
            .write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=8,r=4;$pngBase64\x1b\\');
        waited = 0;
        while (terminal.graphics.placements.length < 2 && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }

        // Closing the viewer deletes by image id + client placement id 1. The
        // match must be on the client p= value, not the internal ordering, or
        // the image lingers as a background ghost.
        terminal.write('\x1b_Ga=d,d=i,i=$imageId,p=1,q=2\x1b\\');

        final remaining =
            terminal.graphics.placements.map((p) => p.imageId).toList();
        expect(
          remaining,
          isNot(contains(imageId)),
          reason: 'the targeted placement must be deleted by its client p=',
        );
        expect(
          remaining,
          contains(999),
          reason: 'the unrelated placement must survive',
        );
      });
    },
  );

  testWidgets('implicit placement deletes use inferred cell spans', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(240, 160);
      final terminal = Terminal();
      terminal.graphics.setCellPixelSize(10, 20);

      terminal.write(
        '\x1b_Ga=T,i=201,f=100,c=30,C=1;$pngBase64\x1b\\',
      );
      var waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements.single.rows, 0);

      // The inferred c-only footprint is 30x10 cells; row 5 must hit it even
      // though only the anchor row is explicitly stored on the placement.
      terminal.write('\x1b_Ga=d,d=p,x=1,y=5,q=2\x1b\\');
      expect(terminal.graphics.placements, isEmpty);

      terminal.write(
        '\x1b_Ga=T,i=202,f=100,r=10,C=1;$pngBase64\x1b\\',
      );
      waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements.single.cols, 0);

      // The inferred r-only footprint is 30x10 cells; column 20 must hit it.
      terminal.write('\x1b_Ga=d,d=x,x=20,q=2\x1b\\');
      expect(terminal.graphics.placements, isEmpty);

      terminal.write(
        '\x1b_Ga=T,i=203,f=100,C=1;$pngBase64\x1b\\',
      );
      waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements.single.cols, 0);
      expect(terminal.graphics.placements.single.rows, 0);

      // At its natural 240x160 size this placement occupies 24x8 cells.
      terminal.write('\x1b_Ga=d,d=p,x=1,y=5,q=2\x1b\\');
      expect(terminal.graphics.placements, isEmpty);

      terminal.resize(10, 24);
      terminal.write(
        '\x1b_Ga=T,i=204,f=100,C=1;$pngBase64\x1b\\',
      );
      waited = 0;
      while (terminal.graphics.placements.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements.single.row, 0);
      expect(terminal.graphics.placements.single.col, 0);

      // Width fitting scales the natural footprint to 10x4 cells.
      terminal.write('\x1b[5;1H');
      expect(terminal.buffer.cursorY, 4);
      terminal.write('\x1b_Ga=d,d=c,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(terminal.graphics.placements, hasLength(1));
      terminal.write('\x1b[3;1H');
      expect(terminal.buffer.cursorY, 2);
      terminal.write('\x1b_Ga=d,d=c,q=2\x1b\\');
      waited = 0;
      while (terminal.graphics.placements.isNotEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, isEmpty);
    });
  });

  testWidgets('Kitty graphics a=d with no selector deletes all placements', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 3);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=T,i=1,f=100,c=4,r=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=T,i=2,f=100,c=4,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (terminal.graphics.placements.length < 2 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(2));

      // The Kitty default selector when d= is omitted is 'a' (all placements).
      terminal.write('\x1b_Ga=d\x1b\\');

      expect(terminal.graphics.placements, isEmpty);
    });
  });

  testWidgets('Kitty graphics a=D (uppercase) frees the image data too', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 3);
      final terminal = Terminal();

      const imageId = 777;
      terminal.write('\x1b_Ga=T,i=$imageId,p=1,f=100,c=4,r=2;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(imageId), isNotNull);

      terminal.write('\x1b_Ga=d,d=I,i=$imageId\x1b\\');

      expect(terminal.graphics.placements, isEmpty);
      expect(
        terminal.graphics.imageById(imageId),
        isNull,
        reason: 'an uppercase d=I must also free the image data',
      );
    });
  });

  testWidgets('unknown targeted hard delete leaves all placements intact', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 3);
      final terminal = Terminal();
      terminal
        ..write('\x1b_Ga=T,i=1,I=5,f=100,c=4,r=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=T,i=2,I=6,f=100,c=4,r=2;$pngBase64\x1b\\');
      var waited = 0;
      while (terminal.graphics.placements.length < 2 && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      terminal.write('\x1b_Ga=d,d=I,I=999,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terminal.graphics.placements, hasLength(2));
      expect(terminal.graphics.imageById(1), isNotNull);
      expect(terminal.graphics.imageById(2), isNotNull);

      terminal.write('\x1b_Ga=d,d=i,q=2\x1b\\');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(terminal.graphics.placements, hasLength(2));
    });
  });

  testWidgets('Kitty graphics o=z inflates a zlib-compressed RGBA payload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A 2x2 solid red RGBA image, zlib-compressed (o=z).
      final raw = Uint8List.fromList(
        List<int>.generate(
            2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : (i % 4 == 0 ? 0xFF : 0)),
      );
      final compressed = ZLibEncoder().encode(raw);
      final payload = base64.encode(compressed);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=32,o=z,s=2,v=2;$payload\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 2);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics o=z inflates a zlib-compressed PNG payload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(3, 2));
      final compressed = ZLibEncoder().encode(pngBytes);
      final payload = base64.encode(compressed);

      final terminal = Terminal();
      terminal.write('\x1b_Ga=T,f=100,o=z;$payload\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }

      expect(terminal.graphics.placements, hasLength(1));
      final stored = terminal.graphics
          .imageById(terminal.graphics.placements.single.imageId);
      expect(stored, isNotNull);
      expect(stored!.image.width, 3);
      expect(stored.image.height, 2);
    });
  });

  testWidgets('Kitty graphics query accepts o=z and rejects other o values', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBytes = base64.decode(await _buildPngBase64(3, 2));
      final compressed = base64.encode(ZLibEncoder().encode(pngBytes));

      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      // q=0 so success responses are emitted; o=z must validate OK.
      terminal.write('\x1b_Ga=q,i=1,f=100,o=z,q=0;$compressed\x1b\\');
      expect(responses.single, contains('OK'));

      responses.clear();
      // An unknown compression value must still be rejected.
      terminal.write(
        '\x1b_Ga=q,i=2,f=100,o=w,q=0;${base64.encode(pngBytes)}\x1b\\',
      );
      expect(responses.single, contains('EINVAL'));
    });
  });

  testWidgets('Kitty graphics image numbers: transmit, place and delete by I=',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final responses = <String>[];
      final terminal = Terminal(onOutput: responses.add);

      // Transmit-only with an image number (no id). The terminal must answer the
      // handshake echoing the number and the id it assigned.
      terminal.write('\x1b_Ga=t,I=5,f=100,q=0;$pngBase64\x1b\\');
      var waited = 0;
      while (responses.isEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(responses.single, matches(RegExp(r'I=5,i=\d+;OK')));

      // The image can be placed by number.
      terminal.write('\x1b_Ga=p,I=5,c=3,r=2\x1b\\');
      expect(terminal.graphics.placements, hasLength(1));

      // ...and deleted by number (lowercase keeps the image data).
      terminal.write('\x1b_Ga=d,d=n,I=5\x1b\\');
      waited = 0;
      while (terminal.graphics.placements.isNotEmpty && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, isEmpty);
      expect(
        terminal.graphics.imageIdForNumber(5),
        isNotNull,
        reason: 'd=n keeps the image data; only the placement is removed',
      );
    });
  });

  testWidgets('I=-only root supports an immediate placement by number', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(3, 2);
      final terminal = Terminal();

      terminal
        ..write('\x1b_Ga=t,I=15,f=100,q=2;$pngBase64\x1b\\')
        ..write('\x1b_Ga=p,I=15,c=3,r=2,q=2\x1b\\');
      final imageId = terminal.graphics.imageIdForNumber(15)!;

      expect(terminal.graphics.hasPendingImage(imageId), isTrue);
      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.placements.single.imageId, imageId);
    });
  });

  testWidgets('I=-only virtual placement resolves an explicit placement remap',
      (
    tester,
  ) async {
    await tester.runAsync(() async {
      final terminal = Terminal();
      terminal.graphics.storeImageWithId(7, await _buildImage(2, 2));

      terminal.write('\x1b_Ga=p,U=1,i=7,I=9,c=1,r=1\x1b\\');
      expect(terminal.graphics.imageIdForNumber(9), 7);

      terminal.write('\x1b_Ga=p,U=1,I=9,c=3,r=2\x1b\\');
      final virtual = terminal.graphics.virtualPlacementById(7);
      expect(virtual, isNotNull);
      expect(virtual!.cols, 3);
      expect(virtual.rows, 2);
    });
  });

  test(
    'an orphaned continuation chunk does not poison the next real image',
    () {
      // If a multi-chunk transmission is truncated (its first chunk lost to a
      // racing replay), a bare `m=1` continuation can arrive with no active
      // transmission. It must be ignored: decoding it headless fails, and — the
      // real danger — leaving it "active" would swallow the next real image's
      // first chunk as a no-op start and finalize that image under empty args,
      // dropping it. The following real image must still store correctly.
      final rgba = _rawRgbaBase64(16, 16);

      final terminal = Terminal();
      // Orphaned continuation: only the more-data flag, no id/action/format.
      terminal.write('\x1b_Gm=1;${rgba.substring(0, 64)}\x1b\\');
      expect(
        terminal.heldImageSignatures().keys,
        isEmpty,
        reason: 'a headless continuation must not create an image',
      );

      // A real, well-formed image immediately after must be unaffected.
      terminal.write('\x1b_Ga=t,i=94,f=32,s=16,v=16;$rgba\x1b\\');
      expect(
        terminal.heldImageSignatures().keys,
        <int>[94],
        reason: 'the next real image must not be swallowed by the orphan',
      );
    },
  );

  test(
    'a truncated multi-chunk transmission does not swallow the next image',
    () {
      // The first chunk of image 93 arrives with full args and `m=1`, but its
      // remaining chunks are lost (a discarded parse backlog). The next image's
      // first chunk carries its own action/format/id, so it is a new command,
      // not a continuation: the truncated transmission must be dropped and the
      // new image stored under its own args.
      final rgba = _rawRgbaBase64(16, 16);

      final terminal = Terminal();
      terminal.write(
          '\x1b_Ga=t,i=93,f=32,s=16,v=16,m=1;${rgba.substring(0, 64)}\x1b\\');
      expect(terminal.heldImageSignatures().keys, isEmpty);

      terminal.write('\x1b_Ga=t,i=94,f=32,s=16,v=16;$rgba\x1b\\');
      expect(
        terminal.heldImageSignatures().keys,
        <int>[94],
        reason: 'the next image must be stored under its own args, not 93',
      );
      final clean = Terminal();
      clean.write('\x1b_Ga=t,i=94,f=32,s=16,v=16;$rgba\x1b\\');
      expect(
        terminal.heldImageSignatures()[94],
        clean.heldImageSignatures()[94],
        reason: 'the payload must not include the truncated chunk',
      );
    },
  );

  test(
    'multi-chunk image reassembles to one image with the full-payload signature',
    () {
      // Kitty caps each APC payload at 4096 base64 bytes, so any real image is
      // transmitted as m=1 continuation chunks. The client must concatenate
      // every chunk's decoded payload into one image whose signature is taken
      // over the whole payload — this is what the MonkeyMux skip protocol keys
      // on, and hashing only the first chunk (the old server bug) would never
      // let a switch-back skip a real screenshot.
      final rgba = _rawRgbaBase64(48, 48);
      final fullPayload = base64.decode(rgba);
      final expectedSignature = terminalGraphicsSourceSignature(
        Uint8List.fromList(fullPayload),
      );

      final transmission = _multiChunkTransmission(
        rgba,
        firstControl: 'a=t,i=91,f=32,s=48,v=48',
      );
      // Sanity: the payload really did split into several chunks.
      expect('\x1b_G'.allMatches(transmission).length, greaterThan(1));

      final terminal = Terminal();
      terminal.write(transmission);

      final held = terminal.heldImageSignatures();
      expect(
        held[91],
        expectedSignature,
        reason: 'the id must hash over the concatenation of all chunk payloads',
      );
      // No stray images from continuation chunks being mis-parsed as their own
      // headless transmissions.
      expect(held.keys, <int>[91]);
    },
  );

  test(
    'multi-chunk image split across arbitrary write boundaries never leaks '
    'base64 as text',
    () {
      // A window-switch replay is pumped through the parser in fixed-size
      // slices that fall at arbitrary byte offsets — mid-control, mid-payload,
      // and across the ESC/ST that frame each chunk. The parser must hold the
      // incomplete APC and resume, never dropping the introducer and rendering
      // the base64 as ground-state text (the on-screen "gibberish").
      final rgba = _rawRgbaBase64(40, 40);
      final transmission = _multiChunkTransmission(
        rgba,
        firstControl: 'a=t,i=92,f=32,s=40,v=40',
      );

      // Prefix/suffix with ordinary text so a leak is unmistakable in the
      // buffer and the parser has real ground-state work around the image.
      const prefix = 'BEGIN';
      const suffix = 'END';
      final stream = '$prefix$transmission$suffix';

      for (final sliceSize in <int>[1, 7, 64, 293, 4096]) {
        final terminal = Terminal();
        for (var offset = 0; offset < stream.length; offset += sliceSize) {
          final end = math.min(offset + sliceSize, stream.length);
          terminal.write(stream.substring(offset, end));
        }

        final text = terminal.buffer.getText().replaceAll('\n', '');
        expect(
          text,
          'BEGINEND',
          reason: 'slice size $sliceSize leaked image payload into the buffer',
        );
        expect(
          terminal.heldImageSignatures().keys,
          <int>[92],
          reason:
              'slice size $sliceSize must still reassemble exactly one image',
        );
      }
    },
  );

  // A row whose only content is a Kitty physical placement has no code points,
  // so a naive "is this row blank" check reads it as empty. Popping it detaches
  // the anchor the image hangs off and loses the image for good — a shrink must
  // take the lossless scrolling path instead.
  testWidgets('shrinking preserves a physical placement below the cursor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(20, 10);

      // Park an image on the last row, leaving it otherwise blank, then bring
      // the cursor back up so the image sits below it.
      terminal.write('\x1b[10;1H');
      terminal.write('\x1b_Ga=T,f=100,C=1;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.placements.single.row, 9);

      terminal.write('\x1b[5;1H');
      terminal.resize(20, 6);

      expect(
        terminal.graphics.placements,
        hasLength(1),
        reason: 'shrinking must not drop the row the image is anchored to',
      );
      expect(terminal.graphics.placements.single.anchor.attached, isTrue);
    });
  });

  // A full-screen agent CLI keeps a non-blank footer under its cursor. Refusing
  // to give those rows up on an alternate-screen shrink — and taking rows off
  // the top instead — destroys whatever is anchored up there, which on a Copilot
  // CLI frame is its images. The host drops the footer rows first, so matching
  // it keeps images that sit above the cursor attached through the dozen shrink
  // steps an Android keyboard animation produces.
  testWidgets('alternate screen shrink keeps images above the cursor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(20, 10);

      terminal.write('\x1b[?1049h');
      terminal.write('\x1b[2;1H');
      terminal.write('\x1b_Ga=T,f=100,C=1;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(1));
      expect(terminal.graphics.placements.single.row, 1);

      // A non-blank footer under the cursor: the rows the host gives up first,
      // and the rows the blank-row preference used to refuse to touch. They have
      // to reach the bottom of the screen, or the shrink just reclaims the blank
      // rows past them and never has to choose.
      for (var row = 7; row <= 10; row++) {
        terminal.write('\x1b[$row;1Hfooter$row');
      }
      terminal.write('\x1b[6;1H'); // park the cursor above the footer

      terminal.resize(20, 8);

      expect(
        terminal.graphics.placements,
        hasLength(1),
        reason: 'dropping the footer must not reach the image row',
      );
      expect(terminal.graphics.placements.single.anchor.attached, isTrue);
      expect(terminal.graphics.placements.single.row, 1);
    });
  });

  testWidgets('alternate screen shrink releases images below the cursor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pngBase64 = await _buildPngBase64(4, 4);
      final terminal = Terminal()..resize(20, 10);

      terminal.write('\x1b[?1049h\x1b[10;1H');
      terminal.write('\x1b_Ga=T,f=100,C=1;$pngBase64\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.placements, hasLength(1));
      terminal.write('\x1b[5;1H');

      terminal.resize(20, 8);

      expect(
        terminal.graphics.placements,
        isEmpty,
        reason: 'the host discards bottom rows below the cursor',
      );
      expect(
        terminal.graphics.imageCount,
        0,
        reason: 'the detached placement must not retain decoded image memory',
      );
    });
  });
}
