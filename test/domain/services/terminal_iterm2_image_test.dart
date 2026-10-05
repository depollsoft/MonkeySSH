import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_iterm2_image.dart';
import 'package:xterm/xterm.dart';

// 1x1 transparent PNG.
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUB'
    'AScY42YAAAAASUVORK5CYII=';

void main() {
  test('displays an iTerm2 inline file through terminal graphics', () async {
    final terminal = Terminal()
      ..resize(80, 24)
      ..kittyGraphicsEnabled = true;

    expect(
      handleIterm2InlineImageOsc(terminal, [
        'File=inline=1',
        'width=25%',
        'height=4',
        'doNotMoveCursor=1:$_pngBase64',
      ]),
      isTrue,
    );

    for (
      var attempt = 0;
      attempt < 20 && !terminal.graphics.hasPlacements;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(terminal.graphics.placements, hasLength(1));
    final placement = terminal.graphics.placements.single;
    expect(placement.cols, 8);
    expect(placement.rows, 4);
    // The 1:1 image fits inside the requested 20x4 cell bounding box.
    expect(terminal.buffer.cursorY, 0);
  });

  test(
    'honors both dimensions when aspect-ratio preservation is disabled',
    () async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..kittyGraphicsEnabled = true;

      handleIterm2InlineImageOsc(terminal, [
        'File=inline=1',
        'width=8',
        'height=3',
        'preserveAspectRatio=0:$_pngBase64',
      ]);

      for (
        var attempt = 0;
        attempt < 20 && !terminal.graphics.hasPlacements;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final placement = terminal.graphics.placements.single;
      expect(placement.cols, 8);
      expect(placement.rows, 3);
    },
  );

  test('translates pixel dimensions using terminal cell metrics', () async {
    final terminal = Terminal()
      ..resize(80, 24)
      ..kittyGraphicsEnabled = true;

    handleIterm2InlineImageOsc(
      terminal,
      ['File=inline=1', 'width=18px:$_pngBase64'],
      cellPixelWidth: 8,
      cellPixelHeight: 16,
    );

    for (
      var attempt = 0;
      attempt < 20 && !terminal.graphics.hasPlacements;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(terminal.graphics.placements.single.cols, 3);
  });

  test('rejects out-of-range pixel dimensions without throwing', () {
    final terminal = Terminal()
      ..resize(80, 24)
      ..kittyGraphicsEnabled = true;
    final hugePixels = '${'9' * 4096}px';

    expect(
      handleIterm2InlineImageOsc(terminal, [
        'File=inline=1',
        'width=$hugePixels:$_pngBase64',
      ], cellPixelWidth: 8),
      isTrue,
    );
  });

  test('consumes downloads and rejects malformed or oversized payloads', () {
    final terminal = Terminal()..kittyGraphicsEnabled = true;

    expect(
      handleIterm2InlineImageOsc(terminal, ['File=name=dGVzdA==:$_pngBase64']),
      isTrue,
    );
    expect(
      handleIterm2InlineImageOsc(terminal, const ['File=inline=1:not-base64']),
      isTrue,
    );
    expect(
      handleIterm2InlineImageOsc(terminal, [
        'File=inline=1:$_pngBase64',
        'trailing',
      ]),
      isTrue,
    );
    final oversized = base64Encode(
      List<int>.filled(maxIterm2InlineImageBytes + 1, 0),
    );
    expect(
      handleIterm2InlineImageOsc(terminal, ['File=inline=1:$oversized']),
      isTrue,
    );
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  test('rejects oversized aggregate arguments before joining them', () {
    final terminal = Terminal()..kittyGraphicsEnabled = true;
    final repeatedChunk = 'x' * 8192;
    final args = <String>[
      'File=inline=1',
      ...List<String>.filled(3000, repeatedChunk),
    ];

    expect(handleIterm2InlineImageOsc(terminal, args), isTrue);
    expect(terminal.graphics.hasPlacements, isFalse);
  });

  test('does not corrupt an active Kitty multipart transmission', () async {
    final terminal = Terminal()
      ..resize(80, 24)
      ..kittyGraphicsEnabled = true;
    final pngBytes = base64Decode(_pngBase64);
    terminal
      ..graphicsCommandStart(const {'a': 'T', 'f': '98', 'q': '2'})
      ..graphicsDataChunk(pngBytes);

    expect(
      handleIterm2InlineImageOsc(terminal, ['File=inline=1:$_pngBase64']),
      isTrue,
    );
    expect(terminal.graphics.hasPlacements, isFalse);

    terminal.graphicsCommandEnd();
    for (
      var attempt = 0;
      attempt < 20 && !terminal.graphics.hasPlacements;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(terminal.graphics.placements, hasLength(1));
  });

  test('leaves unrelated OSC 1337 commands for other handlers', () {
    expect(
      handleIterm2InlineImageOsc(Terminal(), const ['CurrentDir=/tmp']),
      isFalse,
    );
  });
}
