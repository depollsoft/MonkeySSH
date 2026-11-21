import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

class _ParagraphCanvas extends Fake implements Canvas {
  final drawn = <ui.Paragraph>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    drawn.add(paragraph);
  }

  @override
  void drawRect(Rect rect, Paint paint) {}
}

/// Two different cells whose [CellData.getHash] is the same. The hash keeps
/// 29 bits and its seed changes from run to run, so among this many cells
/// with mixed colours two collide in every run, a different pair each time.
(CellData, CellData) collidingCells() {
  final random = Random(1);
  final seen = <int, CellData>{};
  for (var i = 0; i < 400000; i++) {
    final cell = CellData(
      foreground: CellColor.rgb | random.nextInt(1 << 24),
      background: CellColor.rgb | random.nextInt(1 << 24),
      flags: 0,
      content:
          (0x4E00 + random.nextInt(0x5200)) | (2 << CellContent.widthShift),
    );
    final other = seen.putIfAbsent(cell.getHash(), () => cell);
    if (!identical(other, cell)) return (other, cell);
  }
  throw StateError('no collision');
}

void main() {
  // A paragraph cache keyed by the hash drew one cell with the other's glyph
  // and colours, a different pair each run: the colour golden test failed now
  // and then with stray glyphs.
  test('cells whose hashes collide get their own paragraphs', () {
    final (first, second) = collidingCells();
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final canvas = _ParagraphCanvas();
    painter
      ..paintCellForeground(canvas, Offset.zero, first)
      ..paintCellForeground(canvas, Offset.zero, second)
      ..paintCellForeground(canvas, Offset.zero, first);
    expect(canvas.drawn, hasLength(3));
    expect(identical(canvas.drawn[0], canvas.drawn[1]), isFalse);
    // An unchanged cell still hits the cache.
    expect(identical(canvas.drawn[0], canvas.drawn[2]), isTrue);
  });
}
