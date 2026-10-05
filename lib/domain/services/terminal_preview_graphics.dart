import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:xterm/xterm.dart';

import '../models/terminal_preview.dart';
import 'kitty_placeholder_runs.dart';

/// Resolves the Kitty-graphics images that intersect the captured preview rows
/// ([startRow]..[endRow], inclusive absolute buffer rows) into cell-space draws.
///
/// The result mirrors the compositing done live in `monkey_terminal_view.dart`
/// (`_paintGraphics` + `_paintKittyPlaceholderGraphics`), but expressed in cells
/// relative to [startRow] so the connection-preview painter can scale it to its
/// own (smaller) cell size. Classic placements come first (sorted by z-index,
/// then placement id) followed by Unicode-placeholder strips, so a single
/// stable pass draws z<0 below the text and the rest above it.
List<TerminalPreviewImage> buildTerminalPreviewImages(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final graphics = terminal.graphics;
  if (!graphics.hasPlacements && graphics.imageCount == 0) {
    return const [];
  }

  final images = <TerminalPreviewImage>[
    ..._resolveClassicPlacements(terminal, startRow: startRow, endRow: endRow),
    ..._resolvePlaceholderStrips(terminal, startRow: startRow, endRow: endRow),
  ];
  return images;
}

/// Resolves classic (`a=p`/`a=T`) Kitty placements overlapping the preview rows.
List<TerminalPreviewImage> _resolveClassicPlacements(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final graphics = terminal.graphics;
  final viewWidth = terminal.viewWidth;
  if (viewWidth <= 0) {
    return const [];
  }

  final resolved = <TerminalPreviewImage>[];
  for (final placement in graphics.placements) {
    if (!placement.attached) {
      continue;
    }
    final stored = graphics.imageById(placement.imageId);
    if (stored == null) {
      continue;
    }
    final image = stored.image;
    final imageWidth = image.width.toDouble();
    final imageHeight = image.height.toDouble();

    // Source rectangle: the optional crop (x=,y=,w=,h=), clamped to the image.
    final srcLeft = placement.srcX.toDouble().clamp(0.0, imageWidth);
    final srcTop = placement.srcY.toDouble().clamp(0.0, imageHeight);
    final srcWidth =
        (placement.srcWidth > 0
                ? placement.srcWidth.toDouble()
                : imageWidth - srcLeft)
            .clamp(0.0, imageWidth - srcLeft);
    final srcHeight =
        (placement.srcHeight > 0
                ? placement.srcHeight.toDouble()
                : imageHeight - srcTop)
            .clamp(0.0, imageHeight - srcTop);
    if (srcWidth <= 0 || srcHeight <= 0) {
      continue;
    }

    final bool fitToWidth;
    final int colSpan;
    final int rowSpan;
    if (placement.cols > 0 && placement.rows > 0) {
      fitToWidth = false;
      colSpan = placement.cols;
      rowSpan = placement.rows;
    } else {
      // No explicit cell span: the painter fits the source width within the
      // available columns (mirrors the live view's pixel fit, resolution-free).
      fitToWidth = true;
      colSpan = (viewWidth - placement.col).clamp(1, viewWidth);
      // Approximate the covered rows only to cull placements that cannot reach
      // the captured window; the painter derives the real height when drawing.
      rowSpan = math.max(1, (srcHeight / srcWidth * colSpan).ceil());
    }

    // Skip placements entirely outside the captured rows.
    if (placement.row > endRow || placement.row + rowSpan < startRow) {
      continue;
    }

    resolved.add(
      TerminalPreviewImage(
        image: image,
        src: Rect.fromLTWH(srcLeft, srcTop, srcWidth, srcHeight),
        col: placement.col,
        row: placement.row - startRow,
        colSpan: colSpan,
        rowSpan: rowSpan,
        xOffset: placement.xOffset.toDouble(),
        yOffset: placement.yOffset.toDouble(),
        z: placement.z,
        order: placement.placementId,
        fitToWidth: fitToWidth,
      ),
    );
  }

  resolved.sort((a, b) {
    final byZ = a.z.compareTo(b.z);
    return byZ != 0 ? byZ : a.order.compareTo(b.order);
  });
  return resolved;
}

/// Resolves Kitty Unicode-placeholder images into preview strips.
///
/// The per-row runs come from the same resolver the live terminal paints with,
/// so partial/ghost placements are handled identically. Vertically adjacent
/// runs are then stacked into one rectangle per image so a solid image is
/// drawn once rather than row by row (no per-row sampling seams).
List<TerminalPreviewImage> _resolvePlaceholderStrips(
  Terminal terminal, {
  required int startRow,
  required int endRow,
}) {
  final runs =
      resolveKittyPlaceholderRuns(
        terminal,
        firstRow: startRow,
        lastRow: endRow,
      ).runs.toList()..sort((a, b) {
        if (a.imageKey != b.imageKey) return a.imageKey - b.imageKey;
        if (a.cellCol != b.cellCol) return a.cellCol - b.cellCol;
        return a.cellRow - b.cellRow;
      });

  final strips = <TerminalPreviewImage>[];
  var order = 0;
  var r = 0;
  while (r < runs.length) {
    final start = runs[r];
    var end = r;
    while (end + 1 < runs.length) {
      final cur = runs[end];
      final next = runs[end + 1];
      if (identical(next.stored, cur.stored) &&
          next.cellCol == cur.cellCol &&
          next.colSpan == cur.colSpan &&
          next.imgCol == cur.imgCol &&
          next.cellRow == cur.cellRow + 1 &&
          next.imgRow == cur.imgRow + 1) {
        end++;
      } else {
        break;
      }
    }
    final rowSpan = runs[end].cellRow - start.cellRow + 1;
    r = end + 1;

    final src = Rect.fromLTWH(
      start.imgCol * start.srcCellWidth,
      start.imgRow * start.srcCellHeight,
      start.colSpan * start.srcCellWidth,
      rowSpan * start.srcCellHeight,
    );
    if (src.width <= 0 || src.height <= 0) {
      continue;
    }

    strips.add(
      TerminalPreviewImage(
        image: start.stored.image,
        src: src,
        col: start.cellCol,
        row: start.cellRow - startRow,
        colSpan: start.colSpan,
        rowSpan: rowSpan,
        order: order++,
      ),
    );
  }
  return strips;
}
