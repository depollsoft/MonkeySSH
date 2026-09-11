import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final width = paragraph.maxIntrinsicWidth / test.length;
    final height = paragraph.height;
    paragraph.dispose();

    // Never return a degenerate cell size. A zero/NaN/Infinity dimension (e.g.
    // from a sub-pixel or non-finite font size during a pinch) would otherwise
    // crash downstream integer math like `width ~/ cellSize.width` or
    // `(dstHeight / cellSize.height).ceil()` with "Infinity or NaN toInt".
    return Size(
      width.isFinite && width > 0 ? width : 1.0,
      // Use an integer cell height so row offsets do not get rounded down and
      // compressed by callers that align terminal rows to device pixels. A
      // fractional height like 19.6 followed by truncation makes the next row's
      // background start above the previous glyph's descenders, clipping the
      // bottoms of letters such as "g".
      height.isFinite && height > 0 ? height.ceilToDouble() : 1.0,
    );
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  /// Releases cached native text resources when the render object is disposed.
  void dispose() {
    _paragraphCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          offset.translate(0, _cellSize.height - 1),
          offset.translate(_cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          offset,
          offset.translate(0, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCell(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;
    if (charCode == kittyGraphicsPlaceholderCodePoint) return;

    // Conceal (SGR 8): the cell keeps its content for selection/copy but the
    // glyph is not drawn.
    final cellFlags = cellData.flags;
    if (cellFlags & CellFlags.invisible != 0) return;

    var color = cellFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);

    if (cellFlags & CellFlags.faint != 0) {
      color = color.withValues(alpha: 0.5);
    }

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final overline = cellFlags & CellFlags.overline != 0;
      final strikethrough = cellFlags & CellFlags.strikethrough != 0;

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        // The underline is drawn manually below so styled underlines render and
        // connect across cells; Flutter's per-glyph decoration cannot.
        overline: overline,
        strikethrough: strikethrough,
        decorationColor: cellData.underlineColor != 0
            ? resolveForegroundColor(cellData.underlineColor)
            : null,
      );

      // Flutter does not draw a line decoration below/over/through a space
      // which is not between other regular characters. As only single
      // characters are drawn, this will never produce a decoration on a space
      // in the terminal. As a workaround the regular space CodePoint 0x20 is
      // replaced with the CodePoint 0xA0, a non breaking space below which a
      // line can be drawn.
      var char = String.fromCharCode(charCode);
      if ((overline || strikethrough) && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);

    if (cellFlags & CellFlags.underline != 0) {
      final styleIndex = (cellFlags & CellFlags.underlineStyleMask) >>
          CellFlags.underlineStyleShift;
      final underlineColor = cellData.underlineColor != 0
          ? resolveForegroundColor(cellData.underlineColor)
          : color;
      paintTerminalCellUnderline(
        canvas,
        offset,
        _cellSize,
        styleIndex,
        underlineColor,
      );
    }
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}

/// Draws a cell underline of [styleIndex] (matching the index of an
/// `UnderlineStyle`) in [color], filling the cell at [offset] whose size is
/// [cellSize].
///
/// The underline is drawn directly on the canvas rather than via Flutter's
/// per-glyph text decoration, so the double/curly/dotted/dashed styles render
/// and connect across adjacent cells (which per-glyph decoration cannot).
void paintTerminalCellUnderline(
  Canvas canvas,
  Offset offset,
  Size cellSize,
  int styleIndex,
  Color color,
) {
  final cellWidth = cellSize.width;
  final cellHeight = cellSize.height;
  // Guard against non-finite/degenerate cell metrics (e.g. transient values
  // mid-pinch-zoom): `clamp` lets NaN through, and a NaN offset crashes the
  // engine. Skip drawing rather than risk it.
  if (!cellWidth.isFinite ||
      !cellHeight.isFinite ||
      !offset.dx.isFinite ||
      !offset.dy.isFinite ||
      cellWidth <= 0 ||
      cellHeight <= 0) {
    return;
  }
  final thickness = (cellHeight * 0.07).clamp(1.0, 2.5);
  final baseY = offset.dy + cellHeight - thickness;
  final x0 = offset.dx;
  final x1 = x0 + cellWidth;

  final paint = Paint()
    ..color = color
    ..strokeWidth = thickness
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..isAntiAlias = true;

  switch (styleIndex) {
    case 2: // UnderlineStyle.double
      final gap = (thickness * 1.6).clamp(1.5, 3.0);
      canvas.drawLine(Offset(x0, baseY - gap), Offset(x1, baseY - gap), paint);
      canvas.drawLine(Offset(x0, baseY), Offset(x1, baseY), paint);
    case 3: // UnderlineStyle.curly
      // Anchor the wave's top at [baseY] (the single-underline position, which
      // sits just below the glyphs) and let it dip downward into the descender/
      // leading space. This keeps the curl out of the letter bodies regardless
      // of the font's baseline, instead of cresting up through the text.
      final amplitude = (cellHeight * 0.05).clamp(1.0, 1.8);
      final period = math.max(cellWidth, 4.0);
      final midY = baseY + amplitude;
      final path = Path();
      const steps = 12;
      for (var i = 0; i <= steps; i++) {
        final x = x0 + (x1 - x0) * (i / steps);
        final y = midY + math.sin((x / period) * 2 * math.pi) * amplitude;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    case 4: // UnderlineStyle.dotted
      final unit = math.max(thickness * 1.5, 2.0);
      _paintDashedLine(canvas, baseY, x0, x1, unit, unit, paint);
    case 5: // UnderlineStyle.dashed
      final dash = math.max(cellWidth * 0.35, 3.0);
      final gap = math.max(cellWidth * 0.2, 2.0);
      _paintDashedLine(canvas, baseY, x0, x1, dash, gap, paint);
    default: // UnderlineStyle.single / legacy
      canvas.drawLine(Offset(x0, baseY), Offset(x1, baseY), paint);
  }
}

void _paintDashedLine(
  Canvas canvas,
  double y,
  double x0,
  double x1,
  double dash,
  double gap,
  Paint paint,
) {
  final period = dash + gap;
  // Phase by absolute x so segments align across adjacent cells.
  var x = x0 - (x0 % period);
  while (x < x1) {
    final start = math.max(x, x0);
    final end = math.min(x + dash, x1);
    if (end > start) {
      canvas.drawLine(Offset(start, y), Offset(end, y), paint);
    }
    x += period;
  }
}
