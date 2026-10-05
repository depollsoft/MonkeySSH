import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

class _ParagraphCanvas extends Fake implements Canvas {
  final paragraphs = <ui.Paragraph>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(paragraph);
  }
}

void registerMonkeyTerminalPainterLifetimeTests() {
  group('monkey_terminal_painter_lifetime', () {
    test('painter disposal clears glyph, underline, and style-run caches', () {
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(fontSize: 17),
        textScaler: TextScaler.noScaling,
      );
      final terminal = Terminal()
        ..resize(8, 1)
        ..write('ABCD');
      final line = terminal.buffer.lines[0];
      final cell = CellData.empty();
      line.getCellData(0, cell);
      final canvas = _ParagraphCanvas();
      painter
        ..paintCellForeground(canvas, Offset.zero, cell)
        ..paintCellInlineUnderline(canvas, Offset.zero, cell);
      expect(canvas.paragraphs, hasLength(2));
      expect(canvas.paragraphs.every((p) => !p.debugDisposed), isTrue);

      final recorder = ui.PictureRecorder();
      painter.paintLineForegrounds(Canvas(recorder), Offset.zero, line);
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);
      expect(painter.runParagraphCacheLength, greaterThan(0));

      painter.dispose();
      expect(canvas.paragraphs.every((p) => p.debugDisposed), isTrue);
      expect(painter.runParagraphCacheLength, 0);
      expect(painter.dispose, returnsNormally);
    });

    test(
      'recorded glyph pictures remain drawable after font cache clearing',
      () async {
        final painter = MonkeyTerminalPainter(
          theme: TerminalThemes.defaultTheme,
          textStyle: const TerminalStyle(fontSize: 17),
          textScaler: TextScaler.noScaling,
        );
        addTearDown(painter.dispose);
        final terminal = Terminal()
          ..resize(8, 1)
          ..write('ABCD');
        final recorder = ui.PictureRecorder();
        painter.paintLineForegrounds(
          Canvas(recorder),
          Offset.zero,
          terminal.buffer.lines[0],
        );
        final picture = recorder.endRecording();
        addTearDown(picture.dispose);
        final before = await picture.toImage(160, 40);
        addTearDown(before.dispose);
        final beforeBytes = (await before.toByteData())!.buffer.asUint8List();
        expect(beforeBytes.any((byte) => byte != 0), isTrue);

        painter.clearFontCache();
        expect(painter.runParagraphCacheLength, 0);
        final after = await picture.toImage(160, 40);
        addTearDown(after.dispose);
        final afterBytes = (await after.toByteData())!.buffer.asUint8List();
        expect(afterBytes, orderedEquals(beforeBytes));
      },
    );

    test('contrast resolvers run once per distinct cell colour pair', () {
      final painter = MonkeyTerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(fontSize: 17),
        textScaler: TextScaler.noScaling,
      );
      addTearDown(painter.dispose);
      final terminal = Terminal()
        ..resize(16, 2)
        ..write('\x1b[41mred red\x1b[0m\x1b[44mblue\x1b[0m\r\n')
        ..write('\x1b[41mred\x1b[0m\x1b[2;44mfaint\x1b[0m');
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      addTearDown(() => recorder.endRecording().dispose());
      final lines = [terminal.buffer.lines[0], terminal.buffer.lines[1]];

      for (var pass = 0; pass < 2; pass++) {
        for (final line in lines) {
          painter.paintLineBackgrounds(canvas, Offset.zero, line);
        }
      }
      // Ten red-background cells and four blue ones: two background keys.
      expect(painter.readableColorResolutions, 2);

      final cell = CellData.empty();
      for (var pass = 0; pass < 2; pass++) {
        for (final line in lines) {
          for (var column = 0; column < line.length; column++) {
            line.getCellData(column, cell);
            painter.resolveMonkeyTerminalCellForegroundColor(cell);
          }
        }
      }
      // Foreground keys: default, red bg, blue bg, faint blue bg.
      expect(painter.readableColorResolutions, 6);

      painter
        ..theme = monkey_themes.TerminalThemes.defaultLightTheme.toXtermTheme()
        ..paintLineBackgrounds(canvas, Offset.zero, lines[0]);
      expect(
        painter.readableColorResolutions,
        8,
        reason: 'a theme change must drop the memoised colours',
      );
    });
  });
}
