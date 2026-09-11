import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}

Color _rawRgbaPixel(ByteData data, int width, int x, int y) {
  final offset = ((y * width) + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

void main() {
  for (final index in [11, 226]) {
    testWidgets('palette-only updates and resets repaint index $index', (
      tester,
    ) async {
      final terminal = Terminal()..write('\x1b[38;5;${index}m██MM\x1b[?25l');
      final key = GlobalKey();
      const base = TerminalThemes.defaultDarkTheme;
      final original = index == 11
          ? base.brightYellow
          : const Color(0xFFFFFF00);
      Color? previous;
      for (final color in [
        original,
        const Color(0xFF00FF00),
        const Color(0xFF00FFFF),
        original,
      ]) {
        final theme = base.copyWith(
          paletteOverrides: color == original ? {} : {index: color},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 120,
                height: 60,
                child: RepaintBoundary(
                  key: key,
                  child: MonkeyTerminalView(
                    terminal,
                    theme: theme.toXtermTheme(),
                    hardwareKeyboardOnly: true,
                    readOnly: true,
                  ),
                ),
              ),
            ),
          ),
        );
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final data = (await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            return await image.toByteData();
          } finally {
            image.dispose();
          }
        }))!;
        final pixels = <Color>{
          for (var offset = 0; offset < data.lengthInBytes; offset += 4)
            _rawRgbaPixel(data, data.lengthInBytes ~/ 4, offset ~/ 4, 0),
        };
        expect(pixels, contains(color));
        if (previous != null) expect(pixels, isNot(contains(previous)));
        previous = color;
      }
    });
  }

  group('resolveTerminalRenderPadding', () {
    test('keeps portrait terminal rendering edge-to-edge', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
    });

    test('stays edge-to-edge in portrait when the keyboard is visible', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 0),
        viewPadding: EdgeInsets.fromLTRB(12, 18, 16, 34),
        viewInsets: EdgeInsets.fromLTRB(0, 0, 0, 320),
      );

      expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
    });

    test(
      'stays edge-to-edge when the keyboard shrinks a portrait viewport',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(390, 524),
          padding: EdgeInsets.fromLTRB(12, 18, 16, 0),
          viewPadding: EdgeInsets.fromLTRB(12, 18, 16, 34),
          viewInsets: EdgeInsets.fromLTRB(0, 0, 0, 320),
        );

        expect(resolveTerminalRenderPadding(mediaQuery), EdgeInsets.zero);
      },
    );

    test('keeps horizontal cutout padding in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
        viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.only(left: 44, right: 34),
      );
    });

    test('uses landscape safe-area insets from viewPadding', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalRenderPadding(mediaQuery),
        const EdgeInsets.only(left: 44, right: 34),
      );
    });

    test(
      'prefers larger landscape insets when padding exceeds viewPadding',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(844, 390),
          padding: EdgeInsets.fromLTRB(72, 0, 54, 0),
          viewPadding: EdgeInsets.fromLTRB(44, 0, 34, 21),
          viewInsets: EdgeInsets.only(bottom: 200),
        );

        expect(
          resolveTerminalRenderPadding(mediaQuery),
          const EdgeInsets.only(left: 72, right: 54),
        );
      },
    );
  });

  group('resolveTerminalViewportPadding', () {
    test('keeps portrait viewport padding edge-to-edge', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(12, 18, 16, 34),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(0, 8, 0, 0),
      );
    });

    test('keeps landscape viewport inside the horizontal safe area', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTerminalViewportPadding(
          mediaQuery,
          basePadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        ),
        const EdgeInsets.fromLTRB(44, 8, 34, 0),
      );
    });
  });

  group('landscape terminal alignment', () {
    test('keeps trailing-edge alignment enabled in landscape', () {
      const mediaQuery = MediaQueryData(
        size: Size(844, 390),
        viewInsets: EdgeInsets.only(bottom: 200),
      );

      expect(shouldAlignTerminalToTrailingEdges(mediaQuery), isTrue);
    });

    test('shifts partial-cell slack to the leading and top edges', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(844, 390),
          cellSize: const Size(10, 20),
          columns: 70,
          rows: 18,
          padding: const EdgeInsets.only(left: 72, right: 54),
          alignToTrailingEdges: true,
        ),
        const Offset(90, 30),
      );
    });

    test('keeps portrait content anchored to the origin', () {
      expect(
        resolveTerminalContentOrigin(
          viewportSize: const Size(390, 844),
          cellSize: const Size(10, 20),
          columns: 39,
          rows: 42,
        ),
        Offset.zero,
      );
    });
  });

  group('resolveTerminalHorizontalFillScale', () {
    test('fills the final horizontal remainder without shrinking', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 40,
        ),
        closeTo(1.0263, 0.0001),
      );
    });

    test('returns 1 for invalid dimensions', () {
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 0,
          cellWidth: 9.5,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 0,
          columns: 40,
        ),
        1,
      );
      expect(
        resolveTerminalHorizontalFillScale(
          viewportWidth: 390,
          cellWidth: 9.5,
          columns: 0,
        ),
        1,
      );
    });
  });

  group('resolveTerminalResizePixelDimensions', () {
    test('reports the padded terminal viewport in pixels', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(390.4, 844.6),
          padding: const EdgeInsets.fromLTRB(4.2, 8.8, 5.4, 10.1),
        ),
        (width: 381, height: 826),
      );
    });

    test('clamps fully padded viewports to zero', () {
      expect(
        resolveTerminalResizePixelDimensions(
          viewportSize: const Size(10, 12),
          padding: const EdgeInsets.all(20),
        ),
        (width: 0, height: 0),
      );
    });
  });

  group('text attribute rendering', () {
    test('conceal (SGR 8) does not draw the glyph', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();

      Future<int> foregroundPixels(String sequence) async {
        final terminal = Terminal()
          ..resize(1, 1)
          ..write(sequence);
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final width = painter.cellSize.width.ceil();
        final height = painter.cellSize.height.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );

        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

        final image = await recorder.endRecording().toImage(width, height);
        final byteData = (await image.toByteData())!;
        var count = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            if (_rawRgbaPixel(byteData, width, x, y) != theme.background) {
              count++;
            }
          }
        }
        return count;
      }

      final visible = await foregroundPixels('\x1b[37mM');
      final concealed = await foregroundPixels('\x1b[37;8mM');

      expect(visible, greaterThan(0), reason: 'visible glyph should be drawn');
      expect(concealed, 0, reason: 'concealed glyph should not be drawn');
    });

    test(
      'foreground picture cache reuses unchanged lines and re-renders changes',
      () async {
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        // One painter shared across renders so its per-line picture cache is
        // exercised (a fresh painter per render would always miss).
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final terminal = Terminal()..resize(4, 1);

        Future<int> foregroundPixels(BufferLine line) async {
          final width = (painter.cellSize.width * 4).ceil();
          final height = painter.cellSize.height.ceil();
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawRect(
              Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
              Paint()..color = theme.background,
            );
          painter.paintLineForegrounds(canvas, Offset.zero, line);
          final image = await recorder.endRecording().toImage(width, height);
          final byteData = (await image.toByteData())!;
          var count = 0;
          for (var i = 0; i + 4 <= byteData.lengthInBytes; i += 4) {
            final pixel = Color.fromARGB(
              byteData.getUint8(i + 3),
              byteData.getUint8(i),
              byteData.getUint8(i + 1),
              byteData.getUint8(i + 2),
            );
            if (pixel != theme.background) {
              count++;
            }
          }
          return count;
        }

        terminal.write('\x1b[37mMMMM');
        final first = await foregroundPixels(terminal.buffer.lines[0]);
        expect(first, greaterThan(0), reason: 'glyphs render');

        // Same content again → a cache hit must render identically.
        final second = await foregroundPixels(terminal.buffer.lines[0]);
        expect(
          second,
          first,
          reason: 'a cached unchanged line renders identically',
        );

        // Overwrite the same line with blanks → different content must not
        // reuse the stale cached glyph picture.
        terminal.write('\x1b[2K');
        final cleared = await foregroundPixels(terminal.buffer.lines[0]);
        expect(
          cleared,
          0,
          reason:
              'a changed line re-renders instead of reusing a stale picture',
        );
      },
    );

    test('style-run batching matches per-cell foreground rendering', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(fontSize: 20),
        textScaler: TextScaler.noScaling,
      );
      const columns = 24;
      // A line that forces several run breaks: a colored run, a bold color
      // change, an undrawn gap space, a decorated (SGR 4/58) cell, and a wide
      // (2-cell) glyph. Batched output must equal the per-cell reference.
      final terminal = Terminal()
        ..resize(columns, 2)
        ..write(
          '\x1b[37mhello \x1b[1;32mWorld\x1b[0m '
          '\x1b[4;58:2::255:0:0mx\x1b[0m \x1b[53mA B\x1b[0m \u4e2d\u6587',
        );
      final line = terminal.buffer.lines[0];

      final width = (painter.cellSize.width * columns).ceil();
      final height = painter.cellSize.height.ceil();

      Future<ByteData> render(void Function(Canvas) paint) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );
        paint(canvas);
        final image = await recorder.endRecording().toImage(width, height);
        return (await image.toByteData())!;
      }

      // Reference: draw every cell individually, the pre-batching behaviour.
      // Wide-glyph spacer cells are empty, so paintCellForeground draws
      // nothing for them and the wide glyph is drawn once at its own column.
      final reference = await render((canvas) {
        final cellData = CellData.empty();
        final cellWidth = painter.cellSize.width;
        for (var i = 0; i < line.length; i++) {
          line.getCellData(i, cellData);
          painter.paintCellForeground(
            canvas,
            Offset(i * cellWidth, 0),
            cellData,
          );
        }
      });

      // Batched: the production foreground pass with style-run coalescing.
      final batched = await render(
        (canvas) => painter.paintLineForegrounds(canvas, Offset.zero, line),
      );

      final referenceBytes = reference.buffer.asUint8List();
      final batchedBytes = batched.buffer.asUint8List();
      expect(
        referenceBytes.any((byte) => byte != 0),
        isTrue,
        reason: 'the reference must actually draw glyphs',
      );
      expect(
        batchedBytes,
        referenceBytes,
        reason: 'style-run batching must be pixel-identical to per-cell',
      );
    });

    test(
      'coalesces consecutive same-style cells into one run paragraph',
      () async {
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        // Four distinct glyphs sharing one style: batching must cache a single
        // 4-glyph run paragraph, not one paragraph per cell. (Without coalescing
        // these would be four separate length-1 runs, i.e. four cache entries.)
        final terminal = Terminal()
          ..resize(8, 1)
          ..write('\x1b[37mABCD');
        expect(
          painter.runParagraphCacheLength,
          0,
          reason: 'a fresh painter has cached no runs yet',
        );

        final recorder = ui.PictureRecorder();
        painter.paintLineForegrounds(
          Canvas(recorder),
          Offset.zero,
          terminal.buffer.lines[0],
        );
        recorder.endRecording();

        expect(
          painter.runParagraphCacheLength,
          1,
          reason: 'four same-style cells coalesce into one run paragraph',
        );
      },
    );

    test('style-run batching falls back to per-cell for combining marks, '
        'complex scripts, and emoji', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(fontSize: 20),
        textScaler: TextScaler.noScaling,
      );
      const columns = 32;
      // Cells that must NOT be coalesced into a run: a combining mark (width
      // 0, which would shape with its neighbour and desync the grid), a
      // cursive-joining script (Arabic, which would connect when concatenated
      // but is drawn isolated per cell), and an emoji (wide, non-monospace
      // fallback). All must fall back to the per-cell path unchanged.
      final terminal = Terminal()
        ..resize(columns, 2)
        ..write('\x1b[37mabc e\u0301f \u0627\u0644\u0645 \u{1F600} xyz');
      final line = terminal.buffer.lines[0];

      final width = (painter.cellSize.width * columns).ceil();
      final height = painter.cellSize.height.ceil();

      Future<ByteData> render(void Function(Canvas) paint) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );
        paint(canvas);
        final image = await recorder.endRecording().toImage(width, height);
        return (await image.toByteData())!;
      }

      // Reference: every cell drawn individually (the pre-batching path).
      final reference = await render((canvas) {
        final cellData = CellData.empty();
        final cellWidth = painter.cellSize.width;
        for (var i = 0; i < line.length; i++) {
          line.getCellData(i, cellData);
          painter.paintCellForeground(
            canvas,
            Offset(i * cellWidth, 0),
            cellData,
          );
        }
      });

      final batched = await render(
        (canvas) => painter.paintLineForegrounds(canvas, Offset.zero, line),
      );

      expect(
        batched.buffer.asUint8List(),
        reference.buffer.asUint8List(),
        reason:
            'non-batchable cells must render identically to the per-cell path',
      );
    });

    test(
      'box-drawing stays per-cell so TUI borders keep the monospace grid',
      () async {
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        // Rounded Codex-style frame: corners + a long horizontal rule. Platform
        // monospace faces often fall back for U+2500–U+257F; coalescing them into
        // one paragraph drifts the right border off the verticals.
        const columns = 40;
        final top =
            '\x1b[37m\u256d${'\u2500' * (columns - 2)}\u256e'; // ╭──…──╮
        final mid = '\x1b[37m\u2502${' ' * (columns - 2)}\u2502'; // │      │
        final terminal = Terminal()
          ..resize(columns, 2)
          ..write('$top\r\n$mid');
        final topLine = terminal.buffer.lines[0];
        final midLine = terminal.buffer.lines[1];

        final width = (painter.cellSize.width * columns).ceil();
        final height = (painter.cellSize.height * 2).ceil();

        Future<ByteData> render(void Function(Canvas) paint) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawRect(
              Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
              Paint()..color = theme.background,
            );
          paint(canvas);
          final image = await recorder.endRecording().toImage(width, height);
          return (await image.toByteData())!;
        }

        final reference = await render((canvas) {
          final cellData = CellData.empty();
          final cellWidth = painter.cellSize.width;
          final cellHeight = painter.cellSize.height;
          for (final entry in [
            (line: topLine, y: 0.0),
            (line: midLine, y: cellHeight),
          ]) {
            for (var i = 0; i < entry.line.length; i++) {
              entry.line.getCellData(i, cellData);
              painter.paintCellForeground(
                canvas,
                Offset(i * cellWidth, entry.y),
                cellData,
              );
            }
          }
        });

        expect(painter.runParagraphCacheLength, 0);

        final batched = await render((canvas) {
          painter
            ..paintLineForegrounds(canvas, Offset.zero, topLine)
            ..paintLineForegrounds(
              canvas,
              Offset(0, painter.cellSize.height),
              midLine,
            );
        });

        expect(
          painter.runParagraphCacheLength,
          0,
          reason: 'box-drawing must not coalesce into style-run paragraphs',
        );
        expect(
          batched.buffer.asUint8List(),
          reference.buffer.asUint8List(),
          reason:
              'box-drawing borders must stay pixel-identical to the per-cell path',
        );
      },
    );

    test('colored underline (SGR 58) tints the underline', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();

      Future<ByteData> render(String sequence) async {
        final terminal = Terminal()
          ..resize(1, 1)
          ..write(sequence);
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final width = painter.cellSize.width.ceil();
        // Add headroom below the cell so a curly underline that dips into the
        // descender space is captured (it is drawn in a separate overlay pass).
        final height = painter.cellSize.height.ceil() + 8;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );
        painter
          ..paintLine(canvas, Offset.zero, terminal.buffer.lines[0])
          ..paintLineCellUnderlines(
            canvas,
            Offset.zero,
            terminal.buffer.lines[0],
          );
        final image = await recorder.endRecording().toImage(width, height);
        return (await image.toByteData())!;
      }

      bool hasRedDominantPixel(ByteData data) {
        for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
          final r = data.getUint8(i);
          final g = data.getUint8(i + 1);
          final b = data.getUint8(i + 2);
          // An (anti-aliased) red underline pixel: red clearly dominates.
          if (r > 100 && r > g + 60 && r > b + 60) {
            return true;
          }
        }
        return false;
      }

      // Same white glyph + underline; only SGR 58 changes the underline color.
      final whiteUnderline = await render('\x1b[37;4mx');
      final redUnderline = await render('\x1b[37;4;58:2::255:0:0mx');

      expect(
        hasRedDominantPixel(whiteUnderline),
        isFalse,
        reason: 'a default underline should not introduce red pixels',
      );
      expect(
        hasRedDominantPixel(redUnderline),
        isTrue,
        reason: 'SGR 58 should tint the underline red',
      );
    });

    test('underline styles render distinctly', () async {
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();

      Future<ByteData> render(String sequence) async {
        final terminal = Terminal()
          ..resize(1, 1)
          ..write(sequence);
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 24),
          textScaler: TextScaler.noScaling,
        );
        final width = painter.cellSize.width.ceil();
        // Add headroom below the cell so a curly underline that dips into the
        // descender space is captured (it is drawn in a separate overlay pass).
        final height = painter.cellSize.height.ceil() + 8;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint()..color = theme.background,
          );
        painter
          ..paintLine(canvas, Offset.zero, terminal.buffer.lines[0])
          ..paintLineCellUnderlines(
            canvas,
            Offset.zero,
            terminal.buffer.lines[0],
          );
        final image = await recorder.endRecording().toImage(width, height);
        return (await image.toByteData())!;
      }

      bool bytesEqual(ByteData a, ByteData b) {
        if (a.lengthInBytes != b.lengthInBytes) return false;
        for (var i = 0; i < a.lengthInBytes; i++) {
          if (a.getUint8(i) != b.getUint8(i)) return false;
        }
        return true;
      }

      // A blank cell under a single underline: only the underline differs
      // between styles, so each style must produce a different image.
      final single = await render('\x1b[4m ');
      final curly = await render('\x1b[4:3m ');
      final dotted = await render('\x1b[4:4m ');
      final dashed = await render('\x1b[4:5m ');
      final double = await render('\x1b[21m ');

      expect(bytesEqual(single, curly), isFalse, reason: 'curly != single');
      expect(bytesEqual(single, dotted), isFalse, reason: 'dotted != single');
      expect(bytesEqual(single, dashed), isFalse, reason: 'dashed != single');
      expect(bytesEqual(single, double), isFalse, reason: 'double != single');
    });
  });

  group('explicit cell background rendering', () {
    test(
      'clears normal-background cells before drawing terminal rows',
      () async {
        final terminal = Terminal()..resize(8, 1);
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 20),
          textScaler: TextScaler.noScaling,
        );
        final cellSize = painter.cellSize;
        final imageWidth = (cellSize.width * 8).ceil();
        final imageHeight = cellSize.height.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
            Paint()..color = const Color(0xFFFF0000),
          );

        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

        final image = await recorder.endRecording().toImage(
          imageWidth,
          imageHeight,
        );
        final byteData = await image.toByteData();
        expect(byteData, isNotNull);

        final sample = _rawRgbaPixel(
          byteData!,
          imageWidth,
          imageWidth ~/ 2,
          imageHeight ~/ 2,
        );
        expect(sample, theme.background);
      },
    );

    test('keeps bright-black rows readable on the light theme', () {
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: TerminalThemes.defaultLightTheme.foreground,
        background: TerminalThemes.defaultLightTheme.brightBlack,
        terminalBackground: TerminalThemes.defaultLightTheme.background,
      );

      expect(
        _contrastRatio(TerminalThemes.defaultLightTheme.foreground, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(background, TerminalThemes.defaultLightTheme.background),
        greaterThanOrEqualTo(1.04),
      );
      expect(background, isNot(TerminalThemes.defaultLightTheme.brightBlack));
      expect(
        background.computeLuminance(),
        greaterThan(
          TerminalThemes.defaultLightTheme.brightBlack.computeLuminance(),
        ),
      );
    });

    test('keeps bright-black backgrounds readable across built-in themes', () {
      for (final themeData in TerminalThemes.all) {
        final theme = themeData.toXtermTheme();
        final background = resolveMonkeyTerminalReadableBackgroundColor(
          foreground: theme.foreground,
          background: theme.brightBlack,
          terminalBackground: theme.background,
        );
        final foreground = resolveMonkeyTerminalReadableForegroundColor(
          foreground: theme.foreground,
          background: background,
          terminalForeground: theme.foreground,
          terminalBackground: theme.background,
        );

        expect(
          _contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: themeData.id,
        );
      }
    });

    test('tones neutral truecolor backgrounds on dark themes', () {
      const theme = TerminalThemes.defaultDarkTheme;
      const geminiBackground = Color(0xFF5F5F5F);
      const typedForeground = Color(0xFFFFFFFF);
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: typedForeground,
        background: geminiBackground,
        terminalBackground: theme.background,
      );

      expect(background, isNot(geminiBackground));
      expect(
        _contrastRatio(typedForeground, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(background, theme.background),
        lessThanOrEqualTo(1.75),
      );
    });

    test('keeps Gemini neutral rows consistent across composer text', () {
      const theme = TerminalThemes.defaultDarkTheme;
      const geminiBackground = Color(0xFF5F5F5F);
      const promptAccent = Color(0xFFFF87AF);
      const placeholderForeground = Color(0xFFAFAFAF);
      const typedForeground = Color(0xFFFFFFFF);

      final accentBackground = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: promptAccent,
        background: geminiBackground,
        terminalBackground: theme.background,
      );
      final typedBackground = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: typedForeground,
        background: geminiBackground,
        terminalBackground: theme.background,
      );
      final placeholderBackground =
          resolveMonkeyTerminalReadableBackgroundColor(
            foreground: placeholderForeground,
            background: geminiBackground,
            terminalBackground: theme.background,
          );

      expect(accentBackground, typedBackground);
      expect(accentBackground, placeholderBackground);
      expect(
        _contrastRatio(placeholderForeground, placeholderBackground),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('keeps readable semantic truecolor backgrounds unchanged', () {
      const semanticBackground = Color(0xFFA82F45);
      const foreground = Color(0xFFFFFFFF);
      final background = resolveMonkeyTerminalReadableBackgroundColor(
        foreground: foreground,
        background: semanticBackground,
        terminalBackground: TerminalThemes.defaultDarkTheme.background,
      );

      expect(background, semanticBackground);
    });

    test('keeps neutral composer panels uniform on light themes', () {
      // opencode paints its whole composer with one truecolor background
      // (#D3DAD9) and varies only the per-glyph foreground. The panel must
      // resolve to the same gray for every glyph; otherwise muted-text cells
      // get lightened toward the near-white terminal background and the panel
      // tears into white patches behind the hints/labels.
      const theme = TerminalThemes.defaultLightTheme;
      const panelBackground = Color(0xFFD3DAD9);
      const mutedForeground = Color(0xFF616161);
      const accentForeground = Color(0xFF5B5C9C);
      const typedForeground = Color(0xFF0D2B28);
      const hintForeground = Color(0xFFCED4CF);

      final resolvedBackgrounds =
          [
            mutedForeground,
            accentForeground,
            typedForeground,
            hintForeground,
          ].map(
            (foreground) => resolveMonkeyTerminalReadableBackgroundColor(
              foreground: foreground,
              background: panelBackground,
              terminalBackground: theme.background,
            ),
          );

      for (final background in resolvedBackgrounds) {
        expect(background, panelBackground);
        // Never lighten the panel toward the lighter terminal background.
        expect(
          background.computeLuminance(),
          lessThanOrEqualTo(theme.background.computeLuminance()),
        );
      }

      // Muted text is instead made readable against the uniform panel.
      final mutedText = resolveMonkeyTerminalReadableForegroundColor(
        foreground: mutedForeground,
        background: panelBackground,
        terminalForeground: theme.foreground,
        terminalBackground: theme.background,
      );
      expect(
        _contrastRatio(mutedText, panelBackground),
        greaterThanOrEqualTo(4.5),
      );
    });

    test(
      'paints Claude logo block cells as solid terminal rectangles',
      () async {
        const claudePink = Color(0xFFD77757);
        const logoBlack = Color(0xFF000000);
        final terminal = Terminal()
          ..resize(12, 2)
          ..write('\x1b[38;2;215;119;87m ▐\x1b[48;2;0;0;0m▛███▜\x1b[49m▌');
        final theme = TerminalThemes.defaultLightTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(fontSize: 32),
          textScaler: TextScaler.noScaling,
        );
        final cellSize = painter.cellSize;
        final imageWidth = (cellSize.width * 12).ceil() + 2;
        final imageHeight = cellSize.height.ceil() + 2;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
            Paint()..color = theme.background,
          );
        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);
        final image = await recorder.endRecording().toImage(
          imageWidth,
          imageHeight,
        );
        final byteData = await image.toByteData();
        expect(byteData, isNotNull);

        Color sample(double x, double y) => _rawRgbaPixel(
          byteData!,
          imageWidth,
          math.max(0, math.min(imageWidth - 1, x.round())),
          math.max(0, math.min(imageHeight - 1, y.round())),
        );

        expect(
          sample((cellSize.width * 3) + 1, cellSize.height / 2),
          claudePink,
        );
        expect(
          sample(
            (cellSize.width * 3) + cellSize.width - 1,
            cellSize.height / 2,
          ),
          claudePink,
        );
        expect(
          sample((cellSize.width * 2) + (cellSize.width * 0.25), 1),
          claudePink,
        );
        expect(
          sample(
            (cellSize.width * 2) + (cellSize.width * 0.75),
            cellSize.height * 0.75,
          ),
          logoBlack,
        );
      },
    );

    test('does not paint an inline code-span background past the span', () async {
      const codeBackground = Color(0xFFD0DAD9);
      // A neutral inline code span (Copilot-style padding spaces) followed by
      // normal text. The span background must stay within its own cells and
      // never bleed to the end of the row.
      final terminal = Terminal()
        ..resize(40, 2)
        ..write('\x1b[48;2;208;218;217m main \x1b[49m and more text');
      final theme = TerminalThemes.defaultLightTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellSize = painter.cellSize;
      final imageWidth = (cellSize.width * terminal.viewWidth).ceil();
      final imageHeight = cellSize.height.ceil();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
          Paint()..color = theme.background,
        );

      painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

      final image = await recorder.endRecording().toImage(
        imageWidth,
        imageHeight,
      );
      final byteData = await image.toByteData();
      expect(byteData, isNotNull);

      Color sample(int column) => _rawRgbaPixel(
        byteData!,
        imageWidth,
        ((column + 0.5) * cellSize.width).round(),
        (cellSize.height / 2).round(),
      );

      // The leading padding space of the code span carries the code background.
      expect(sample(0), codeBackground);
      // The empty tail of the row keeps the terminal background (no bleed).
      expect(sample(35), theme.background);
    });

    test(
      'renders a full-width prompt background painted with real cells',
      () async {
        // When a CLI detects a capable terminal (via XTVERSION) it paints the
        // prompt row background across the whole width with real bg-coloured
        // space cells. This must render edge to edge with no help from any fill
        // heuristic. Models the captured Copilot rich-mode prompt.
        final promptRow = '\x1b[48;2;20;27;34m\u276F ok${' ' * 36}\x1b[m';
        final terminal = Terminal()
          ..resize(40, 2)
          ..write(promptRow);
        final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
        final painter = MonkeyTerminalPainter(
          theme: theme,
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        );
        final cellSize = painter.cellSize;
        final imageWidth = (cellSize.width * terminal.viewWidth).ceil();
        final imageHeight = cellSize.height.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawRect(
            Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
            Paint()..color = theme.background,
          );

        painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

        final image = await recorder.endRecording().toImage(
          imageWidth,
          imageHeight,
        );
        final byteData = await image.toByteData();
        expect(byteData, isNotNull);

        Color sample(int column) => _rawRgbaPixel(
          byteData!,
          imageWidth,
          ((column + 0.5) * cellSize.width).round(),
          (cellSize.height / 2).round(),
        );

        // Both an early fill cell and a far-right fill cell share the same
        // explicit prompt background, distinct from the terminal background.
        expect(sample(10), isNot(theme.background));
        expect(sample(35), sample(10));
      },
    );

    test('lifts low-contrast foreground-only ANSI colors', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[90mforeground only');
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellData = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cellData);

      final foreground = painter.resolveMonkeyTerminalCellForegroundColor(
        cellData,
      );

      expect(
        _contrastRatio(foreground, theme.background),
        greaterThanOrEqualTo(4.5),
      );
      expect(foreground, isNot(theme.brightBlack));
    });

    test('keeps readable foreground-only ANSI colors unchanged', () {
      final terminal = Terminal()
        ..resize(24, 2)
        ..write('\x1b[96mforeground only');
      final theme = TerminalThemes.defaultDarkTheme.toXtermTheme();
      final painter = MonkeyTerminalPainter(
        theme: theme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final cellData = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cellData);

      expect(
        painter.resolveMonkeyTerminalCellForegroundColor(cellData),
        theme.brightCyan,
      );
    });
  });
}
