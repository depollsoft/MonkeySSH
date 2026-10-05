import 'package:xterm/src/core/cell.dart';

class CursorStyle {
  int foreground;

  int background;

  int attrs;

  /// Underline color, encoded like [foreground]/[background]. `0` means the
  /// underline uses the text color.
  int underlineColor;

  CursorStyle({
    this.foreground = 0,
    this.background = 0,
    this.attrs = 0,
    this.underlineColor = 0,
  });

  static final empty = CursorStyle();

  void setBold() {
    attrs |= CellAttr.bold;
  }

  void setFaint() {
    attrs |= CellAttr.faint;
  }

  void setItalic() {
    attrs |= CellAttr.italic;
  }

  void setUnderline() {
    attrs &= ~CellAttr.underlineStyleMask;
    attrs |= CellAttr.underline;
  }

  /// Applies an underline [style]. [UnderlineStyle.none] removes the underline.
  void setUnderlineStyle(UnderlineStyle style) {
    attrs &= ~CellAttr.underlineStyleMask;
    if (style == UnderlineStyle.none) {
      attrs &= ~CellAttr.underline;
    } else {
      attrs |= CellAttr.underline;
      attrs |= (style.index << CellAttr.underlineStyleShift) &
          CellAttr.underlineStyleMask;
    }
  }

  void setOverline() {
    attrs |= CellAttr.overline;
  }

  void setBlink() {
    attrs |= CellAttr.blink;
  }

  void setInverse() {
    attrs |= CellAttr.inverse;
  }

  void setInvisible() {
    attrs |= CellAttr.invisible;
  }

  void setStrikethrough() {
    attrs |= CellAttr.strikethrough;
  }

  void unsetBold() {
    attrs &= ~CellAttr.bold;
  }

  void unsetFaint() {
    attrs &= ~CellAttr.faint;
  }

  void unsetItalic() {
    attrs &= ~CellAttr.italic;
  }

  void unsetUnderline() {
    attrs &= ~CellAttr.underline;
    attrs &= ~CellAttr.underlineStyleMask;
  }

  void unsetBlink() {
    attrs &= ~CellAttr.blink;
  }

  void unsetInverse() {
    attrs &= ~CellAttr.inverse;
  }

  void unsetInvisible() {
    attrs &= ~CellAttr.invisible;
  }

  void unsetStrikethrough() {
    attrs &= ~CellAttr.strikethrough;
  }

  void unsetOverline() {
    attrs &= ~CellAttr.overline;
  }

  bool get isBold => (attrs & CellAttr.bold) != 0;

  bool get isStrikethrough => (attrs & CellAttr.strikethrough) != 0;

  bool get isOverline => (attrs & CellAttr.overline) != 0;

  UnderlineStyle get underlineStyle {
    if ((attrs & CellAttr.underline) == 0) {
      return UnderlineStyle.none;
    }
    final index =
        (attrs & CellAttr.underlineStyleMask) >> CellAttr.underlineStyleShift;
    // A set underline bit with a 0 style index means the legacy single style.
    if (index == 0 || index >= UnderlineStyle.values.length) {
      return UnderlineStyle.single;
    }
    return UnderlineStyle.values[index];
  }

  void setForegroundColor16(int color) {
    foreground = color | CellColor.named;
  }

  void setForegroundColor256(int color) {
    foreground = color | CellColor.palette;
  }

  void setForegroundColorRgb(int r, int g, int b) {
    foreground = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetForegroundColor() {
    foreground = 0; // | CellColor.normal;
  }

  void setBackgroundColor16(int color) {
    background = color | CellColor.named;
  }

  void setBackgroundColor256(int color) {
    background = color | CellColor.palette;
  }

  void setBackgroundColorRgb(int r, int g, int b) {
    background = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetBackgroundColor() {
    background = 0; // | CellColor.normal;
  }

  void setUnderlineColor256(int color) {
    underlineColor = color | CellColor.palette;
  }

  void setUnderlineColorRgb(int r, int g, int b) {
    underlineColor = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetUnderlineColor() {
    underlineColor = 0;
  }

  void reset() {
    foreground = 0;
    background = 0;
    attrs = 0;
    underlineColor = 0;
  }
}
