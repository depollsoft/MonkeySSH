import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

/// Records the paragraphs drawn and where.
class _ParagraphCanvas extends Fake implements Canvas {
  final drawn = <(ui.Paragraph, Offset)>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    drawn.add((paragraph, offset));
  }

  @override
  void drawRect(Rect rect, Paint paint) {}
}

/// The UTF-16 length of the text [paragraph] laid out, which is one line.
int _textLength(ui.Paragraph paragraph) =>
    paragraph.getLineBoundary(const TextPosition(offset: 0)).end;

void main() {
  test('a grapheme cluster is drawn as one paragraph of its whole text', () {
    const family = '\u{1F468}\u200D\u{1F469}';
    final terminal = Terminal()..resize(10, 1);
    terminal.write('e\u0301${family}x\re\u0302');

    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final canvas = _ParagraphCanvas();
    painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);

    // The acute e was overwritten by a circumflex one in the same cell.
    expect(
      [for (final (paragraph, _) in canvas.drawn) _textLength(paragraph)],
      ['e\u0302'.length, family.length, 1],
    );
    final cellWidth = painter.cellSize.width;
    expect(
      [for (final (_, offset) in canvas.drawn) offset.dx],
      [0, cellWidth, 3 * cellWidth],
    );

    // A cell with the same base and attributes but other extras gets its own
    // paragraph, and the same cluster again comes from the cache.
    final circumflex = canvas.drawn.first.$1;
    terminal.write('\re\u0301\u0323');
    canvas.drawn.clear();
    painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);
    final acute = canvas.drawn.first.$1;
    expect(acute, isNot(same(circumflex)));
    expect(_textLength(acute), 'e\u0301\u0323'.length);
    canvas.drawn.clear();
    painter.paintLine(canvas, Offset.zero, terminal.buffer.lines[0]);
    expect(canvas.drawn.first.$1, same(acute));
    painter.dispose();
  });

  test('a cluster with VS16 asks for the colour emoji fonts first', () {
    expect(requestsEmojiPresentation(const [0xFE0F]), isTrue);
    expect(requestsEmojiPresentation(const [0x0301]), isFalse);
    expect(requestsEmojiPresentation(const []), isFalse);
    final style = withEmojiPresentation(
      const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier']),
    );
    expect(style.fontFamily, 'Apple Color Emoji');
    expect(style.fontFamilyFallback, [
      'Noto Color Emoji',
      'Segoe UI Emoji',
      'Menlo',
      'Courier',
    ]);
  });
}
