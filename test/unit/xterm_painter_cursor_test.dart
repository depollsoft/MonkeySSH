import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

class _LineCanvas extends Fake implements Canvas {
  final lines = <(Offset, Offset)>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));
}

void main() {
  for (final cursorType in [
    TerminalCursorType.underline,
    TerminalCursorType.verticalBar,
  ]) {
    test('$cursorType follows the cursor offset on both axes', () {
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(fontSize: 17),
        textScaler: TextScaler.noScaling,
      );
      addTearDown(painter.dispose);
      const offset = Offset(29, 63);
      final canvas = _LineCanvas();
      painter.paintCursor(canvas, offset, cursorType: cursorType);

      final expected = cursorType == TerminalCursorType.underline
          ? (
              offset.translate(0, painter.cellSize.height - 1),
              offset.translate(
                painter.cellSize.width,
                painter.cellSize.height - 1,
              ),
            )
          : (offset, offset.translate(0, painter.cellSize.height));
      expect(canvas.lines, [expected]);
    });
  }
}
