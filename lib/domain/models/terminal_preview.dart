import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// A value-equal snapshot of terminal rows used by connection preview cards.
@immutable
class TerminalPreviewSnapshot {
  /// Creates a [TerminalPreviewSnapshot].
  const TerminalPreviewSnapshot({
    required this.lines,
    required this.plainText,
    this.images = const [],
  });

  /// Preview rows in display order.
  final List<TerminalPreviewLine> lines;

  /// Plain-text fallback matching the rendered preview rows.
  final String plainText;

  /// Terminal-graphics images (Kitty protocol) composited over [lines], resolved
  /// into cell-space geometry relative to the first preview row. Empty when the
  /// captured rows contain no images.
  final List<TerminalPreviewImage> images;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPreviewSnapshot &&
          plainText == other.plainText &&
          listEquals(lines, other.lines) &&
          listEquals(images, other.images);

  @override
  int get hashCode =>
      Object.hash(plainText, Object.hashAll(lines), Object.hashAll(images));
}

/// A single terminal-graphics image draw captured for a connection preview.
///
/// Geometry is expressed in *cells* relative to the preview's first visible row
/// (row `0` is the top preview line, column `0` is the leftmost cell), so the
/// preview painter can scale it to its own cell size — the preview is a scaled
/// thumbnail of the live terminal. Mirrors the compositing in
/// `monkey_terminal_view.dart` (`_paintGraphics` / `_paintKittyPlaceholderGraphics`).
@immutable
class TerminalPreviewImage {
  /// Creates a [TerminalPreviewImage].
  const TerminalPreviewImage({
    required this.image,
    required this.src,
    required this.col,
    required this.row,
    required this.colSpan,
    required this.rowSpan,
    this.xOffset = 0,
    this.yOffset = 0,
    this.z = 0,
    this.order = 0,
    this.fitToWidth = false,
  });

  /// The decoded image to composite.
  final ui.Image image;

  /// Source rectangle within [image], in image pixels.
  final ui.Rect src;

  /// Left cell column of the destination (0 = leftmost preview cell).
  final int col;

  /// Top cell row of the destination, relative to the first preview row. May be
  /// negative when a placement starts above the captured rows.
  final int row;

  /// Number of cell columns the destination spans. When [fitToWidth] is true
  /// this is the maximum available width used to fit the image.
  final int colSpan;

  /// Number of cell rows the destination spans. Ignored when [fitToWidth] is
  /// true (the height is derived from the fitted width).
  final int rowSpan;

  /// Horizontal offset within the top-left cell (Kitty `X=`), as a fraction
  /// of a cell so it scales with the preview's cells.
  final double xOffset;

  /// Vertical offset within the top-left cell (Kitty `Y=`), as a fraction of
  /// a cell.
  final double yOffset;

  /// Z-index. Negative values are drawn behind the terminal text.
  final int z;

  /// Stable ordering key (placement id / write order) for equal z-indices.
  final int order;

  /// Whether the image should be scaled to fit [colSpan] columns preserving its
  /// aspect ratio (Kitty auto-sized placement with no explicit `c=`/`r=`).
  final bool fitToWidth;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPreviewImage &&
          identical(image, other.image) &&
          src == other.src &&
          col == other.col &&
          row == other.row &&
          colSpan == other.colSpan &&
          rowSpan == other.rowSpan &&
          xOffset == other.xOffset &&
          yOffset == other.yOffset &&
          z == other.z &&
          order == other.order &&
          fitToWidth == other.fitToWidth;

  @override
  int get hashCode => Object.hash(
    identityHashCode(image),
    src,
    col,
    row,
    colSpan,
    rowSpan,
    xOffset,
    yOffset,
    z,
    order,
    fitToWidth,
  );
}

/// One terminal display row in a [TerminalPreviewSnapshot].
@immutable
class TerminalPreviewLine {
  /// Creates a [TerminalPreviewLine].
  const TerminalPreviewLine({required this.text, required this.cells});

  /// Sanitized plain text for the row.
  final String text;

  /// Copied xterm cell data for this display row.
  final BufferLine cells;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPreviewLine &&
          text == other.text &&
          _bufferLineEquals(cells, other.cells);

  @override
  int get hashCode => Object.hash(text, _bufferLineHash(cells));
}

bool _bufferLineEquals(BufferLine a, BufferLine b) {
  if (a.length != b.length || a.isWrapped != b.isWrapped) {
    return false;
  }
  final cellA = CellData.empty();
  final cellB = CellData.empty();
  for (var index = 0; index < a.length; index++) {
    a.getCellData(index, cellA);
    b.getCellData(index, cellB);
    if (cellA.foreground != cellB.foreground ||
        cellA.background != cellB.background ||
        cellA.flags != cellB.flags ||
        cellA.content != cellB.content ||
        cellA.underlineColor != cellB.underlineColor) {
      return false;
    }
  }
  return true;
}

int _bufferLineHash(BufferLine line) {
  var result = Object.hash(line.length, line.isWrapped);
  final cell = CellData.empty();
  for (var index = 0; index < line.length; index++) {
    line.getCellData(index, cell);
    result = Object.hash(result, cell.getHash());
  }
  return result;
}
