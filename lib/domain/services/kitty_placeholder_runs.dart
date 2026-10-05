import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:xterm/xterm.dart';

/// Source rectangle of a classic Kitty [placement] within [stored]'s decoded
/// image, or null when the crop is empty.
///
/// Kitty crop coordinates (`x=`, `y=`, `w=`, `h=`) refer to the original
/// source dimensions. The decoder may have downscaled the image, so the crop
/// is clamped in source space and then scaled into decoded pixels.
Rect? resolveKittyPlacementSourceRect(
  TerminalImage stored,
  TerminalImagePlacement placement,
) {
  final imageWidth = stored.image.width.toDouble();
  final imageHeight = stored.image.height.toDouble();
  final sourceWidth = stored.sourceWidth > 0
      ? stored.sourceWidth.toDouble()
      : imageWidth;
  final sourceHeight = stored.sourceHeight > 0
      ? stored.sourceHeight.toDouble()
      : imageHeight;
  final left = placement.srcX.toDouble().clamp(0.0, sourceWidth);
  final top = placement.srcY.toDouble().clamp(0.0, sourceHeight);
  final width =
      (placement.srcWidth > 0
              ? placement.srcWidth.toDouble()
              : sourceWidth - left)
          .clamp(0.0, sourceWidth - left);
  final height =
      (placement.srcHeight > 0
              ? placement.srcHeight.toDouble()
              : sourceHeight - top)
          .clamp(0.0, sourceHeight - top);
  final scaleX = imageWidth / sourceWidth;
  final scaleY = imageHeight / sourceHeight;
  final src = Rect.fromLTWH(
    left * scaleX,
    top * scaleY,
    width * scaleX,
    height * scaleY,
  );
  return src.width > 0 && src.height > 0 ? src : null;
}

/// Minimum density of live cells within their bounding box for a Kitty
/// Unicode-placeholder image instance to be composited. A solidly displayed
/// image, or a clean scroll crop where whole rows have scrolled off, fills its
/// bounding box (~1.0). A torn-down remnant, whose cells are overwritten in a
/// scattered pattern, leaves a box full of holes (well below this), so it is
/// dismissed rather than drawn as stale fragments/stripes.
const double kittyPlaceholderRenderThreshold = 0.85;

/// Stride used to fold a (row, column) pair into a single int key. Larger than
/// any realistic terminal width or image column count so pairs never collide.
const int kittyGridStride = 100003;

/// One horizontal run of contiguous live Kitty Unicode-placeholder cells on a
/// single screen row, resolved to its stored image and source slice.
class KittyPlaceholderRun {
  /// Creates a run; see the field docs for each argument.
  const KittyPlaceholderRun({
    required this.imageKey,
    required this.stored,
    required this.srcCellWidth,
    required this.srcCellHeight,
    required this.cellRow,
    required this.cellCol,
    required this.colSpan,
    required this.imgRow,
    required this.imgCol,
  });

  /// Identity of the referenced image: `imageId * 64 + imageIdBitWidth`.
  final int imageKey;

  /// The stored image this run draws from.
  final TerminalImage stored;

  /// Source pixel width covered by one placeholder cell.
  final double srcCellWidth;

  /// Source pixel height covered by one placeholder cell.
  final double srcCellHeight;

  /// Absolute buffer row of the run on screen.
  final int cellRow;

  /// First screen column of the run.
  final int cellCol;

  /// Number of screen columns the run spans.
  final int colSpan;

  /// Image-grid row of the run's cells.
  final int imgRow;

  /// Image-grid column of the run's first cell.
  final int imgCol;

  /// Source rectangle of this run within [stored]'s image, in image pixels.
  Rect get src => Rect.fromLTWH(
    imgCol * srcCellWidth,
    imgRow * srcCellHeight,
    colSpan * srcCellWidth,
    srcCellHeight,
  );
}

/// Result of [resolveKittyPlaceholderRuns].
class KittyPlaceholderRunResolution {
  /// Creates a resolution; both lists default to empty.
  const KittyPlaceholderRunResolution({
    this.runs = const [],
    this.unresolved = const [],
  });

  /// Runs whose image has decoded, sorted by image, row, column.
  final List<KittyPlaceholderRun> runs;

  /// Images referenced by renderable runs that have not decoded yet (or are
  /// missing), one entry per such run.
  final List<({int imageId, int bitWidth})> unresolved;
}

class _PlaceholderCell {
  const _PlaceholderCell({
    required this.imageKey,
    required this.imageId,
    required this.bitWidth,
    required this.cellRow,
    required this.cellCol,
    required this.imgRow,
    required this.imgCol,
  });

  final int imageKey;
  final int imageId;
  final int bitWidth;
  final int cellRow;
  final int cellCol;
  final int imgRow;
  final int imgCol;
}

int _imageKeyFor(TerminalImagePlaceholder placeholder) =>
    placeholder.imageId * 64 + placeholder.imageIdBitWidth;

/// Every cell of one on-screen placement shares the same `cell - img` offset,
/// so distinct placements (and the holes an app punches into an image) fall
/// into separate instances. The offsets are biased so negative values, which a
/// partially scrolled-off image produces, stay unique.
int _instanceKeyFor(TerminalImagePlaceholder placeholder, int imageKey) {
  const bias = kittyGridStride ~/ 2;
  final offsetRow = placeholder.cellRow - placeholder.row + bias;
  final offsetCol = placeholder.cellCol - placeholder.col + bias;
  return (imageKey * kittyGridStride + offsetRow) * kittyGridStride + offsetCol;
}

/// Resolves the Kitty Unicode-placeholder cells within absolute buffer rows
/// [firstRow]..[lastRow] (inclusive) into per-row image runs.
///
/// A Kitty Unicode-placeholder image is conceptually a solid rectangle: clients
/// (e.g. Copilot CLI) emit every cell of the grid. The same image id can be
/// displayed several times at different screen positions, and an image can be
/// partially scrolled off or partially overwritten. Cells are grouped into
/// display *instances* by the placement offset they share, and each instance
/// is judged on two axes:
///
///  * Density: a solid image or a clean scroll crop fills its bounding box; a
///    torn remnant leaves a box full of holes and is dropped.
///  * Recency: when an app re-displays an image without clearing the previous
///    copy's cells, the old copy lingers as a ghost. Among the dense instances
///    of one image only the most recently written placement survives.
///
/// Only placeholders anchored in the requested rows are examined, so a scroll
/// frame or preview refresh never walks the thousands of off-screen cells a
/// long agent transcript retains. Grid dimensions stay correct for cropped
/// images because each placeholder shares a grid tracker recording the largest
/// row/column ever seen for its image; virtual placements still win when the
/// protocol supplied explicit dimensions.
KittyPlaceholderRunResolution resolveKittyPlaceholderRuns(
  Terminal terminal, {
  required int firstRow,
  required int lastRow,
}) {
  final graphics = terminal.graphics;
  final buffer = terminal.buffer;
  final placeholders = graphics.placeholdersInRows(
    buffer.lines,
    firstRow,
    lastRow,
  );
  if (placeholders.isEmpty) {
    return const KittyPlaceholderRunResolution();
  }

  final lineCount = buffer.lines.length;
  bool cellIsLivePlaceholder(int cellRow, int cellCol) {
    if (cellRow < 0 || cellRow >= lineCount) {
      return false;
    }
    final line = buffer.lines[cellRow];
    if (cellCol < 0 || cellCol >= line.length) {
      return false;
    }
    return line.getCodePoint(cellCol) == kittyGraphicsPlaceholderCodePoint;
  }

  // Pass 1: group live placeholder cells into display instances.
  final gridColsByImage = <int, int>{};
  final gridRowsByImage = <int, int>{};
  final instanceCellCount = <int, int>{};
  final instanceRowBounds = <int, List<int>>{};
  final instanceColBounds = <int, List<int>>{};
  // Recency of each instance: the highest monotonic placeholder sequence seen
  // for it, independent of row/anchor traversal order.
  final instanceRecency = <int, int>{};
  final instanceImageKey = <int, int>{};

  for (final placeholder in placeholders) {
    if (!placeholder.attached) {
      continue;
    }
    final imageKey = _imageKeyFor(placeholder);
    final virtualPlacement = graphics.virtualPlacementById(placeholder.imageId);
    gridColsByImage[imageKey] = (virtualPlacement?.cols ?? 0) > 0
        ? virtualPlacement!.cols
        : placeholder.gridColumns;
    gridRowsByImage[imageKey] = (virtualPlacement?.rows ?? 0) > 0
        ? virtualPlacement!.rows
        : placeholder.gridRows;

    final cellRow = placeholder.cellRow;
    if (cellRow < firstRow || cellRow > lastRow) {
      continue;
    }
    if (!cellIsLivePlaceholder(cellRow, placeholder.cellCol)) {
      continue;
    }
    final instanceKey = _instanceKeyFor(placeholder, imageKey);
    instanceImageKey[instanceKey] = imageKey;
    instanceCellCount[instanceKey] = (instanceCellCount[instanceKey] ?? 0) + 1;
    instanceRecency[instanceKey] = math.max(
      instanceRecency[instanceKey] ?? -1,
      placeholder.sequence,
    );
    final rowBounds = instanceRowBounds[instanceKey] ??= <int>[
      placeholder.row,
      placeholder.row,
    ];
    rowBounds[0] = math.min(rowBounds[0], placeholder.row);
    rowBounds[1] = math.max(rowBounds[1], placeholder.row);
    final colBounds = instanceColBounds[instanceKey] ??= <int>[
      placeholder.col,
      placeholder.col,
    ];
    colBounds[0] = math.min(colBounds[0], placeholder.col);
    colBounds[1] = math.max(colBounds[1], placeholder.col);
  }

  // Keep the instances dense enough to be a real display, and among those of
  // one image only the most recently drawn one.
  final newestInstanceForImage = <int, int>{};
  for (final entry in instanceCellCount.entries) {
    final rowBounds = instanceRowBounds[entry.key]!;
    final colBounds = instanceColBounds[entry.key]!;
    final boxArea =
        (rowBounds[1] - rowBounds[0] + 1) * (colBounds[1] - colBounds[0] + 1);
    if (boxArea <= 0 ||
        entry.value < boxArea * kittyPlaceholderRenderThreshold) {
      continue;
    }
    final imageKey = instanceImageKey[entry.key]!;
    final current = newestInstanceForImage[imageKey];
    if (current == null ||
        instanceRecency[entry.key]! > instanceRecency[current]!) {
      newestInstanceForImage[imageKey] = entry.key;
    }
  }
  if (newestInstanceForImage.isEmpty) {
    return const KittyPlaceholderRunResolution();
  }
  final renderableInstances = newestInstanceForImage.values.toSet();

  // Pass 2: collect the cells of renderable instances, at most one live cell
  // per on-screen position.
  final cellByPosition = <int, _PlaceholderCell>{};
  for (final placeholder in placeholders) {
    if (!placeholder.attached) {
      continue;
    }
    final cellRow = placeholder.cellRow;
    if (cellRow < firstRow || cellRow > lastRow) {
      continue;
    }
    final imageKey = _imageKeyFor(placeholder);
    if (!renderableInstances.contains(_instanceKeyFor(placeholder, imageKey))) {
      continue;
    }
    final cellCol = placeholder.cellCol;
    if (!cellIsLivePlaceholder(cellRow, cellCol)) {
      continue;
    }
    cellByPosition[cellRow * kittyGridStride + cellCol] = _PlaceholderCell(
      imageKey: imageKey,
      imageId: placeholder.imageId,
      bitWidth: placeholder.imageIdBitWidth,
      cellRow: cellRow,
      cellCol: cellCol,
      imgRow: placeholder.row,
      imgCol: placeholder.col,
    );
  }
  if (cellByPosition.isEmpty) {
    return const KittyPlaceholderRunResolution();
  }

  // Merge contiguous cells of one image on one screen row into a single run.
  final visible = cellByPosition.values.toList()
    ..sort((a, b) {
      if (a.imageKey != b.imageKey) return a.imageKey - b.imageKey;
      if (a.cellRow != b.cellRow) return a.cellRow - b.cellRow;
      return a.cellCol - b.cellCol;
    });

  final imageCache = <int, TerminalImage?>{};
  final runs = <KittyPlaceholderRun>[];
  final unresolved = <({int imageId, int bitWidth})>[];
  var i = 0;
  while (i < visible.length) {
    final start = visible[i];
    var end = i;
    while (end + 1 < visible.length) {
      final cur = visible[end];
      final next = visible[end + 1];
      if (next.imageKey == cur.imageKey &&
          next.cellRow == cur.cellRow &&
          next.cellCol == cur.cellCol + 1 &&
          next.imgRow == cur.imgRow &&
          next.imgCol == cur.imgCol + 1) {
        end++;
      } else {
        break;
      }
    }
    final last = visible[end];
    i = end + 1;

    final stored = imageCache.putIfAbsent(
      start.imageKey,
      () => graphics.imageByPlaceholderColorId(
        start.imageId,
        bitWidth: start.bitWidth,
      ),
    );
    if (stored == null) {
      unresolved.add((imageId: start.imageId, bitWidth: start.bitWidth));
      continue;
    }
    final cols = gridColsByImage[start.imageKey] ?? 1;
    final rows = gridRowsByImage[start.imageKey] ?? 1;
    if (cols <= 0 || rows <= 0) {
      continue;
    }
    runs.add(
      KittyPlaceholderRun(
        imageKey: start.imageKey,
        stored: stored,
        srcCellWidth: stored.image.width / cols,
        srcCellHeight: stored.image.height / rows,
        cellRow: start.cellRow,
        cellCol: start.cellCol,
        colSpan: last.cellCol - start.cellCol + 1,
        imgRow: start.imgRow,
        imgCol: start.imgCol,
      ),
    );
  }
  return KittyPlaceholderRunResolution(runs: runs, unresolved: unresolved);
}
