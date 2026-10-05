import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('CursorStyle underline styles', () {
    test('setUnderlineStyle stores the style and sets the underline bit', () {
      final style = CursorStyle();
      style.setUnderlineStyle(UnderlineStyle.curly);

      expect(style.underlineStyle, UnderlineStyle.curly);
      expect(style.attrs & CellFlags.underline, isNot(0));
      final index = (style.attrs & CellFlags.underlineStyleMask) >>
          CellFlags.underlineStyleShift;
      expect(index, UnderlineStyle.curly.index);
    });

    test('setUnderlineStyle(none) clears the underline', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.dashed);
      style.setUnderlineStyle(UnderlineStyle.none);

      expect(style.underlineStyle, UnderlineStyle.none);
      expect(style.attrs & CellFlags.underline, 0);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });

    test('legacy setUnderline reports a single style', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.curly);
      // A following plain underline should reset the style back to single.
      style.setUnderline();

      expect(style.underlineStyle, UnderlineStyle.single);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });

    test('unsetUnderline clears both the bit and the style field', () {
      final style = CursorStyle()..setUnderlineStyle(UnderlineStyle.dotted);
      style.unsetUnderline();

      expect(style.underlineStyle, UnderlineStyle.none);
      expect(style.attrs & CellFlags.underlineStyleMask, 0);
    });
  });

  group('CursorStyle overline and strikethrough', () {
    test('overline can be toggled', () {
      final style = CursorStyle()..setOverline();
      expect(style.isOverline, isTrue);
      expect(style.attrs & CellFlags.overline, isNot(0));

      style.unsetOverline();
      expect(style.isOverline, isFalse);
      expect(style.attrs & CellFlags.overline, 0);
    });

    test('strikethrough bit is visible to the painter flags', () {
      final style = CursorStyle()..setStrikethrough();
      expect(style.isStrikethrough, isTrue);
      expect(style.attrs & CellFlags.strikethrough, isNot(0));
    });
  });

  group('CellAttr layout', () {
    test('underline style field does not collide with other flags', () {
      const otherFlags = CellFlags.bold |
          CellFlags.faint |
          CellFlags.italic |
          CellFlags.underline |
          CellFlags.blink |
          CellFlags.inverse |
          CellFlags.invisible |
          CellFlags.strikethrough |
          CellFlags.overline;
      expect(CellFlags.underlineStyleMask & otherFlags, 0);
    });
  });

  group('CursorStyle underline color', () {
    test('setters encode the color like a foreground color', () {
      final style = CursorStyle()..setUnderlineColor256(160);
      expect(style.underlineColor, 160 | CellColor.palette);

      style.setUnderlineColorRgb(10, 20, 30);
      expect(style.underlineColor, (10 << 16) | (20 << 8) | 30 | CellColor.rgb);

      style.resetUnderlineColor();
      expect(style.underlineColor, 0);
    });

    test('reset() clears the underline color', () {
      final style = CursorStyle()..setUnderlineColorRgb(1, 2, 3);
      style.reset();
      expect(style.underlineColor, 0);
    });

    test('underline color round-trips through a buffer cell', () {
      final line = BufferLine(4);
      final style = CursorStyle()
        ..setUnderline()
        ..setUnderlineColorRgb(255, 0, 0);
      line.setCell(0, 0x41, 1, style);

      final cell = CellData.empty();
      line.getCellData(0, cell);
      expect(cell.underlineColor, (255 << 16) | CellColor.rgb);
      expect(cell.flags & CellFlags.underline, isNot(0));
    });
  });
}
