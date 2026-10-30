import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/async_semaphore.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

/// Optional observer invoked after each Kitty graphics decode attempt.
///
/// The app wires this to its diagnostics log to surface inflate/decode timing
/// and payload size; it stays null in tests and standalone xterm so the decode
/// path keeps no dependency on the host application.
void Function({
  required int payloadBytes,
  required int inflateMicros,
  required int decodeMicros,
  required bool compressed,
  required bool success,
  String? imageId,
  String? action,
  bool? reused,
})? terminalGraphicsDecodeObserver;

/// Bounds all terminal image decodes across eager and deferred graphics paths.
final AsyncSemaphore terminalGraphicsDecodeGate = AsyncSemaphore(3);

/// Playback state for a Kitty graphics animation.
enum TerminalAnimationState {
  /// The current frame remains visible until explicitly changed.
  stopped,

  /// Frames advance until the last available frame, then wait for more frames.
  loading,

  /// Frames advance and loop according to the image's loop count.
  running,
}

/// Result of a Kitty `a=f` frame transmission.
enum TerminalAnimationFrameResult {
  /// The frame was added or edited.
  success,

  /// The target image no longer exists.
  imageNotFound,

  /// A requested base or edit frame does not exist.
  frameNotFound,

  /// The transmitted frame rectangle is invalid.
  invalidRectangle,

  /// The frame would exceed the decoded-image memory budget.
  noSpace,

  /// The engine could not rasterize the composed frame.
  rasterizationFailed,
}

/// Result of a Kitty `a=c` frame composition request.
enum TerminalAnimationCompositionResult {
  /// The destination frame was updated.
  success,

  /// The image no longer exists.
  imageNotFound,

  /// The source or destination frame does not exist.
  frameNotFound,

  /// A rectangle is out of bounds or overlaps itself.
  invalidRectangle,

  /// The composed frame would exceed the decoded-image memory budget.
  noSpace,

  /// The engine could not rasterize the composed frame.
  rasterizationFailed,
}

/// A fully decoded frame and the time it remains visible.
class TerminalImageFrame {
  /// Creates a decoded terminal image frame.
  const TerminalImageFrame(this.image, {this.duration});

  /// The decoded pixels for this frame.
  final ui.Image image;

  /// Time to show the frame before advancing.
  ///
  /// `null` means the frame remains indefinitely. [Duration.zero] is a Kitty
  /// protocol gapless frame that is skipped immediately.
  final Duration? duration;

  /// Approximate decoded RGBA memory used by this frame.
  int get sizeBytes => image.width * image.height * 4;
}

/// A decoded static or animated image before it is assigned a terminal id.
class DecodedTerminalImage {
  /// Creates a decoded terminal image.
  DecodedTerminalImage({
    required List<TerminalImageFrame> frames,
    required this.sourceWidth,
    required this.sourceHeight,
    this.repetitionCount = 0,
  }) : frames = _validateFrames(frames);

  /// Creates a one-frame image whose logical dimensions match [image].
  factory DecodedTerminalImage.single(ui.Image image) => DecodedTerminalImage(
        frames: <TerminalImageFrame>[TerminalImageFrame(image)],
        sourceWidth: image.width,
        sourceHeight: image.height,
      );

  static List<TerminalImageFrame> _validateFrames(
    List<TerminalImageFrame> frames,
  ) {
    if (frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'must not be empty');
    }
    return List<TerminalImageFrame>.unmodifiable(frames);
  }

  /// Fully composed frames in playback order.
  final List<TerminalImageFrame> frames;

  /// Original image width before decode-time downscaling.
  final int sourceWidth;

  /// Original image height before decode-time downscaling.
  final int sourceHeight;

  /// Number of repeats requested by the encoded image.
  ///
  /// Matches [ui.Codec.repetitionCount]: `0` plays once and `-1` repeats
  /// forever.
  final int repetitionCount;

  /// Approximate decoded RGBA memory used by every frame.
  int get sizeBytes =>
      frames.fold<int>(0, (total, frame) => total + frame.sizeBytes);
}

/// A decoded image retained for the Kitty graphics protocol.
class TerminalImage {
  TerminalImage(
    this.id,
    ui.Image image, {
    this.sourceSignature = 0,
    this.transient = false,
  })  : sourceWidth = image.width,
        sourceHeight = image.height,
        _frames = <TerminalImageFrame>[TerminalImageFrame(image)];

  /// Creates a retained image from a decoded frame sequence.
  TerminalImage.fromDecoded(
    this.id,
    DecodedTerminalImage decoded, {
    this.sourceSignature = 0,
    this.transient = false,
  })  : sourceWidth = decoded.sourceWidth,
        sourceHeight = decoded.sourceHeight,
        _frames = List<TerminalImageFrame>.of(decoded.frames) {
    if (_frames.length > 1) {
      _animationState = TerminalAnimationState.running;
      _maxLoops = decoded.repetitionCount < 0 ? 0 : decoded.repetitionCount + 1;
      _timedFrameCount = _frames
          .where(
            (frame) =>
                frame.duration != null && frame.duration! > Duration.zero,
          )
          .length;
    }
  }

  /// Image id assigned by the [GraphicsManager].
  final int id;

  /// The image for the frame that should currently be painted.
  ui.Image get image => _frames[_currentFrameIndex].image;

  /// Original image width before decode-time downscaling.
  final int sourceWidth;

  /// Original image height before decode-time downscaling.
  final int sourceHeight;

  /// Number of decoded frames, including the root frame.
  int get frameCount => _frames.length;

  /// Current frame number using Kitty's one-based frame numbering.
  int get currentFrame => _currentFrameIndex + 1;

  /// Current animation playback state.
  TerminalAnimationState get animationState => _animationState;

  /// Duration for the one-based [frameNumber], or null if it is invalid or
  /// remains visible indefinitely.
  Duration? frameDuration(int frameNumber) {
    final index = frameNumber - 1;
    if (index < 0 || index >= _frames.length) {
      return null;
    }
    return _frames[index].duration;
  }

  /// Decoded image for the one-based [frameNumber], or null if it is invalid.
  ui.Image? imageAtFrame(int frameNumber) {
    final index = frameNumber - 1;
    if (index < 0 || index >= _frames.length) {
      return null;
    }
    return _frames[index].image;
  }

  /// A cheap hash of the source payload this image was decoded from. Used to
  /// skip re-decoding when the same id is transmitted again with identical
  /// bytes (e.g. MonkeyMux replays cached images on every window switch).
  /// Zero means "unknown" and never matches an incoming signature.
  final int sourceSignature;

  /// Whether the client marked the image transient (Kitty usage hint `N=1`):
  /// it is used briefly, so under memory pressure it is evicted before other
  /// images.
  final bool transient;

  /// Approximate size of every decoded frame in bytes (RGBA).
  int get sizeBytes =>
      _frames.fold<int>(0, (total, frame) => total + frame.sizeBytes);

  int _lastAccess = 0;
  final List<TerminalImageFrame> _frames;
  var _animationState = TerminalAnimationState.stopped;
  var _currentFrameIndex = 0;
  var _maxLoops = 0;
  var _currentLoop = 0;
  var _frameElapsed = Duration.zero;
  var _waitingForFrames = false;
  var _timedFrameCount = 0;
  var _protocolAnimationModified = false;

  bool get _atLoopLimit => _maxLoops > 0 && _currentLoop >= _maxLoops;

  bool get _needsAnimationTick =>
      _animationState != TerminalAnimationState.stopped &&
      _frames.length > 1 &&
      !_waitingForFrames &&
      !_atLoopLimit &&
      _timedFrameCount > 0 &&
      _frames[_currentFrameIndex].duration != null;

  bool _advance(Duration elapsed) {
    if (!_needsAnimationTick || elapsed.isNegative) {
      return false;
    }
    _frameElapsed += elapsed;
    var changed = false;

    // At most one timed frame advances per render tick. Gapless frames may be
    // skipped in the same tick, matching Kitty's reference implementation.
    for (var transitions = 0; transitions <= _frames.length; transitions++) {
      final duration = _frames[_currentFrameIndex].duration;
      if (duration == null) {
        break;
      }
      if (duration > Duration.zero && _frameElapsed < duration) {
        break;
      }
      if (duration > Duration.zero) {
        _frameElapsed -= duration;
      }
      if (!_moveToNextFrame()) {
        break;
      }
      changed = true;
      if (_frames[_currentFrameIndex].duration case final nextDuration?
          when nextDuration > Duration.zero) {
        break;
      }
    }
    return changed;
  }

  bool _moveToNextFrame() {
    final next = (_currentFrameIndex + 1) % _frames.length;
    if (next == 0) {
      if (_animationState == TerminalAnimationState.loading) {
        _waitingForFrames = true;
        return false;
      }
      _currentLoop += 1;
      if (_atLoopLimit) {
        return false;
      }
    }
    _currentFrameIndex = next;
    return true;
  }

  bool _setCurrentFrame(int frameNumber) {
    final index = frameNumber - 1;
    if (index < 0 || index >= _frames.length || index == _currentFrameIndex) {
      return false;
    }
    _currentFrameIndex = index;
    _frameElapsed = Duration.zero;
    _waitingForFrames = false;
    _protocolAnimationModified = true;
    return true;
  }

  void _setAnimationState(TerminalAnimationState state) {
    final previous = _animationState;
    _animationState = state;
    _currentLoop = 0;
    if (state == TerminalAnimationState.stopped) {
      _frameElapsed = Duration.zero;
      _waitingForFrames = false;
    } else if (previous == TerminalAnimationState.stopped) {
      _frameElapsed = Duration.zero;
      _waitingForFrames = false;
    } else if (state != previous) {
      _waitingForFrames = false;
    }
    _protocolAnimationModified = true;
  }

  void _setProtocolLoopCount(int loopCount) {
    if (loopCount <= 0) {
      return;
    }
    _maxLoops = loopCount - 1;
    _protocolAnimationModified = true;
  }

  bool _setFrameDuration(int frameNumber, Duration duration) {
    final index = frameNumber - 1;
    if (index < 0 || index >= _frames.length) {
      return false;
    }
    final previous = _frames[index];
    if (previous.duration == duration) {
      return false;
    }
    if (previous.duration != null && previous.duration! > Duration.zero) {
      _timedFrameCount -= 1;
    }
    if (duration > Duration.zero) {
      _timedFrameCount += 1;
    }
    _frames[index] = TerminalImageFrame(previous.image, duration: duration);
    if (index == _currentFrameIndex) {
      _frameElapsed = Duration.zero;
      _waitingForFrames = false;
    }
    _protocolAnimationModified = true;
    return true;
  }

  void _appendProtocolFrame(ui.Image image, Duration duration) {
    if (_frames.length == 1 && _frames.first.duration == null) {
      _frames[0] = TerminalImageFrame(
        _frames.first.image,
        duration: Duration.zero,
      );
    }
    if (_waitingForFrames) {
      final currentDuration = _frames[_currentFrameIndex].duration;
      _frameElapsed = currentDuration ?? Duration.zero;
      _waitingForFrames = false;
    }
    _frames.add(TerminalImageFrame(image, duration: duration));
    if (duration > Duration.zero) {
      _timedFrameCount += 1;
    }
    _protocolAnimationModified = true;
  }

  bool _replaceFrame(int frameNumber, ui.Image image) {
    final index = frameNumber - 1;
    if (index < 0 || index >= _frames.length) {
      return false;
    }
    final previous = _frames[index];
    _frames[index] = TerminalImageFrame(image, duration: previous.duration);
    _protocolAnimationModified = true;
    return index == _currentFrameIndex;
  }
}

/// A placement of a [TerminalImage] anchored to a cell in the buffer.
///
/// The placement is anchored with a [CellAnchor] so it tracks its cell across
/// scrollback and reflow, and detaches when that cell is evicted. A Kitty
/// relative placement (`P=`, `Q=`, `H=`, `V=`) has no anchor of its own: it
/// sits a cell offset away from the top-left cell of its parent placement and
/// moves with it.
class TerminalImagePlacement {
  TerminalImagePlacement({
    required this.placementId,
    required this.imageId,
    required CellAnchor this.anchor,
    required int fallbackCol,
    required int fallbackRow,
    this.clientPlacementId = 0,
    this.cols = 0,
    this.rows = 0,
    this.z = 0,
    this.srcX = 0,
    this.srcY = 0,
    this.srcWidth = 0,
    this.srcHeight = 0,
    this.xOffset = 0,
    this.yOffset = 0,
  })  : _fallbackCol = fallbackCol,
        _fallbackRow = fallbackRow,
        _parent = null,
        horizontalOffset = 0,
        verticalOffset = 0,
        _resolvePosition = null;

  TerminalImagePlacement._relative({
    required this.placementId,
    required this.imageId,
    required _TerminalPlacementParent parent,
    required this.horizontalOffset,
    required this.verticalOffset,
    required ({int col, int row})? Function(TerminalImagePlacement placement)
        resolvePosition,
    this.clientPlacementId = 0,
    this.cols = 0,
    this.rows = 0,
    this.z = 0,
    this.srcX = 0,
    this.srcY = 0,
    this.srcWidth = 0,
    this.srcHeight = 0,
    this.xOffset = 0,
    this.yOffset = 0,
  })  : anchor = null,
        _fallbackCol = 0,
        _fallbackRow = 0,
        _parent = parent,
        _resolvePosition = resolvePosition;

  /// Internal placement id assigned by the [GraphicsManager], unique per
  /// placement and monotonically increasing (used for stable paint ordering).
  /// Re-placing an image with the same image and placement id keeps it, as
  /// Kitty updates such a placement in place, so relative placements that
  /// refer to it follow it to its new position.
  final int placementId;

  /// The id of the placed [TerminalImage].
  final int imageId;

  /// Client-assigned placement id (the Kitty `p=` key, 0 when unspecified). This
  /// — not [placementId] — is what a delete command (`a=d` with `p=`) targets.
  final int clientPlacementId;

  /// Anchor for the top-left cell of the placement, or null for a relative
  /// placement, which is positioned from its parent instead.
  final CellAnchor? anchor;

  final int _fallbackCol;
  final int _fallbackRow;

  final _TerminalPlacementParent? _parent;
  final ({int col, int row})? Function(TerminalImagePlacement placement)?
      _resolvePosition;

  /// Whether this is a Kitty relative placement (`P=`), positioned from a
  /// parent placement rather than a cell of its own.
  bool get isRelative => _parent != null;

  /// Image id of the parent placement (`P=`), or 0 for a placement anchored to
  /// a cell.
  int get parentImageId => _parent?.imageId ?? 0;

  /// Columns from the parent's top-left cell (`H=`); negative moves left.
  final int horizontalOffset;

  /// Rows from the parent's top-left cell (`V=`); negative moves up.
  final int verticalOffset;

  /// Number of columns the image should occupy (from `c=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int cols;

  /// Number of rows the image should occupy (from `r=`), or `0` to size the
  /// image from its own pixel dimensions.
  final int rows;

  /// Z-index (`z=`). Higher values stack above lower ones; negative values are
  /// drawn behind the terminal text.
  final int z;

  /// Left edge of the source rectangle within the image, in pixels (`x=`).
  final int srcX;

  /// Top edge of the source rectangle within the image, in pixels (`y=`).
  final int srcY;

  /// Width of the source rectangle in pixels (`w=`), or `0` for the full width
  /// from [srcX].
  final int srcWidth;

  /// Height of the source rectangle in pixels (`h=`), or `0` for the full height
  /// from [srcY].
  final int srcHeight;

  /// Horizontal pixel offset within the top-left cell (`X=`).
  final int xOffset;

  /// Vertical pixel offset within the top-left cell (`Y=`).
  final int yOffset;

  /// Column of the top-left cell.
  int get col {
    final anchor = this.anchor;
    if (anchor == null) return _resolvePosition?.call(this)?.col ?? 0;
    return anchor.attached ? anchor.x : _fallbackCol;
  }

  /// Absolute buffer row of the top-left cell.
  int get row {
    final anchor = this.anchor;
    if (anchor == null) return _resolvePosition?.call(this)?.row ?? 0;
    return anchor.attached ? anchor.y : _fallbackRow;
  }

  /// Whether the anchored cell is still present in the buffer. A relative
  /// placement is attached while its parent chain resolves to a position: a
  /// virtual parent with no placeholder cells on screen leaves it unplaced but
  /// kept, as Kitty does.
  bool get attached {
    final anchor = this.anchor;
    if (anchor == null) return _resolvePosition?.call(this) != null;
    return anchor.attached;
  }

  /// [xOffset] limited to the top-left cell for a cell [cellWidth] pixels wide.
  ///
  /// Kitty keeps the in-cell offset inside the first cell (`X=` is at most one
  /// pixel less than the cell width), so a large value can never move an image
  /// away from the cell it is placed at.
  double cellXOffset(double cellWidth) =>
      xOffset.toDouble().clamp(0.0, math.max(0.0, cellWidth - 1));

  /// [yOffset] limited to the top-left cell; see [cellXOffset].
  double cellYOffset(double cellHeight) =>
      yOffset.toDouble().clamp(0.0, math.max(0.0, cellHeight - 1));

  /// Releases the underlying anchor.
  void dispose() => anchor?.dispose();

  TerminalImagePlacement _withAnchor(
    CellAnchor anchor, {
    int? rows,
    int? srcY,
    int? srcHeight,
    int? yOffset,
  }) =>
      TerminalImagePlacement(
        placementId: placementId,
        imageId: imageId,
        anchor: anchor,
        fallbackCol: anchor.x,
        fallbackRow: anchor.y,
        clientPlacementId: clientPlacementId,
        cols: cols,
        rows: rows ?? this.rows,
        z: z,
        srcX: srcX,
        srcY: srcY ?? this.srcY,
        srcWidth: srcWidth,
        srcHeight: srcHeight ?? this.srcHeight,
        xOffset: xOffset,
        yOffset: yOffset ?? this.yOffset,
      );
}

/// The parent of a relative placement: either another placement, by its
/// internal [TerminalImagePlacement.placementId], or the virtual (Unicode
/// placeholder) placement of [imageId] when [placementId] is null.
class _TerminalPlacementParent {
  const _TerminalPlacementParent.placement(this.imageId, int this.placementId);

  const _TerminalPlacementParent.virtual(this.imageId) : placementId = null;

  final int imageId;
  final int? placementId;
}

/// Placements a scroll region is moving; see
/// [GraphicsManager.beginRegionScroll].
class GraphicsRegionScroll {
  GraphicsRegionScroll._(
    this._moves, {
    required this.top,
    required this.bottom,
    required this.delta,
    required this.hasMargins,
  });

  final List<_RegionScrollMove> _moves;

  /// First absolute row of the region.
  final int top;

  /// Last absolute row of the region.
  final int bottom;

  /// Rows the region scrolls by; negative scrolls up.
  final int delta;

  /// Whether the region is narrower than the screen.
  final bool hasMargins;
}

typedef _RegionScrollMove = ({
  TerminalImagePlacement placement,
  int row,
  int col,
  bool scrolls,
});

/// Why a Kitty relative placement (`P=`) was rejected.
enum TerminalRelativePlacementError {
  /// The parent image (`P=`) does not exist (`ENOPARENT`).
  parentImageNotFound,

  /// The parent image has no placement, or none with the requested `Q=`
  /// (`ENOPARENT`).
  parentPlacementNotFound,

  /// The placement names itself as its parent (`EINVAL`).
  selfParent,

  /// The parent chain would loop back to the placement (`ECYCLE`).
  cycle,

  /// The parent chain would exceed the depth limit (`ETOODEEP`).
  tooDeep,
}

/// Largest image id a Kitty client can name (`i=` is a 32-bit value).
const _maxProtocolImageId = 0xFFFFFFFF;

/// First id of the range the terminal gives images transmitted without an id.
const _firstAnonymousImageId = _maxProtocolImageId + 1;

/// Maximum number of parent links in a relative placement chain. The Kitty
/// protocol requires at least 8 and Kitty allows exactly 8.
const kittyRelativePlacementDepthLimit = 8;

/// The on-screen size, in pixels, of [placement] showing a source rectangle
/// [sourceWidth] x [sourceHeight] pixels, with cells [cellWidth] x [cellHeight]
/// pixels and [availableColumns] columns to the right edge of the screen.
///
/// An explicit cell span (`c=`, `r=`) fixes the far edges at those cell
/// boundaries, so the in-cell offset (`X=`, `Y=`, kept inside the first cell)
/// shrinks the image rather than pushing it into the next cell, as Kitty draws
/// it. With one span the other side follows the source aspect ratio. With
/// neither the image keeps its own pixel size, scaled down to fit the columns
/// left on the row. An unknown source size falls back to the cell span.
({double width, double height}) terminalImagePlacementSize(
  TerminalImagePlacement placement, {
  required double sourceWidth,
  required double sourceHeight,
  required double cellWidth,
  required double cellHeight,
  required int availableColumns,
}) =>
    terminalImageSpanSize(
      cols: placement.cols,
      rows: placement.rows,
      xOffset: placement.cellXOffset(cellWidth),
      yOffset: placement.cellYOffset(cellHeight),
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      availableColumns: availableColumns,
    );

/// [terminalImagePlacementSize] for a cell span [cols] x [rows] (0 for a side
/// the image sizes) and in-cell offsets already kept inside the first cell.
({double width, double height}) terminalImageSpanSize({
  required int cols,
  required int rows,
  required double xOffset,
  required double yOffset,
  required double sourceWidth,
  required double sourceHeight,
  required double cellWidth,
  required double cellHeight,
  required int availableColumns,
}) {
  final spanWidth = cols * cellWidth - xOffset;
  final spanHeight = rows * cellHeight - yOffset;
  if (cols > 0 && rows > 0) {
    return (width: spanWidth, height: spanHeight);
  }
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    return (
      width: math.max(1, cols) * cellWidth,
      height: math.max(1, rows) * cellHeight,
    );
  }
  if (cols > 0) {
    return (width: spanWidth, height: sourceHeight * spanWidth / sourceWidth);
  }
  if (rows > 0) {
    return (width: sourceWidth * spanHeight / sourceHeight, height: spanHeight);
  }
  final maxWidth = math.max(1, availableColumns) * cellWidth;
  final scale = sourceWidth > maxWidth ? maxWidth / sourceWidth : 1.0;
  return (width: sourceWidth * scale, height: sourceHeight * scale);
}

/// A Kitty Unicode-placeholder cell that references a stored image.
class TerminalImagePlaceholder {
  TerminalImagePlaceholder._({
    required this.imageId,
    required this.imageIdBitWidth,
    required this.anchor,
    required this.row,
    required this.col,
    required this.sequence,
    required _TerminalImagePlaceholderGrid grid,
    required _TerminalImagePlaceholderGrid Function(
      _TerminalImagePlaceholderGrid current,
      int oldRow,
      int oldCol,
      int imageId,
      int bitWidth,
      int row,
      int col,
    ) rebindGrid,
  })  : _grid = grid,
        _rebindGrid = rebindGrid;

  /// The referenced Kitty graphics image id.
  int imageId;

  /// Number of image-id bits encoded directly in the foreground color.
  int imageIdBitWidth;

  /// Anchor for this placeholder cell.
  final CellAnchor anchor;

  /// Row within the virtual image placement.
  int row;

  /// Column within the virtual image placement.
  int col;

  /// Monotonic write order used to choose the newest visible image instance.
  final int sequence;

  _TerminalImagePlaceholderGrid _grid;
  final _TerminalImagePlaceholderGrid Function(
    _TerminalImagePlaceholderGrid current,
    int oldRow,
    int oldCol,
    int imageId,
    int bitWidth,
    int row,
    int col,
  ) _rebindGrid;

  /// Largest placeholder column observed for this image, plus one.
  int get gridColumns => _grid.columns;

  /// Largest placeholder row observed for this image, plus one.
  int get gridRows => _grid.rows;

  /// Applies Kitty diacritics that finalize this cell's image/grid metadata.
  void updateMetadata({
    required int imageId,
    required int imageIdBitWidth,
    required int row,
    required int col,
  }) {
    _grid = _rebindGrid(
      _grid,
      this.row,
      this.col,
      imageId,
      imageIdBitWidth,
      row,
      col,
    );
    this.imageId = imageId;
    this.imageIdBitWidth = imageIdBitWidth;
    this.row = row;
    this.col = col;
  }

  /// Column of the placeholder cell.
  int get cellCol => anchor.x;

  /// Absolute buffer row of the placeholder cell.
  int get cellRow => anchor.y;

  /// Whether the anchored cell is still present in the buffer.
  bool get attached => anchor.attached;

  /// Releases the underlying anchor.
  void dispose() => anchor.dispose();
}

class _TerminalImagePlaceholderGrid {
  _TerminalImagePlaceholderGrid(this.imageId, this.bitWidth);

  final int imageId;
  final int bitWidth;
  final SplayTreeMap<int, int> _rowCounts = SplayTreeMap();
  final SplayTreeMap<int, int> _columnCounts = SplayTreeMap();
  int references = 0;
  int get columns => _columnCounts.isEmpty ? 1 : _columnCounts.lastKey()! + 1;
  int get rows => _rowCounts.isEmpty ? 1 : _rowCounts.lastKey()! + 1;

  void add(int row, int col) {
    references += 1;
    _rowCounts.update(row, (count) => count + 1, ifAbsent: () => 1);
    _columnCounts.update(col, (count) => count + 1, ifAbsent: () => 1);
  }

  void remove(int row, int col) {
    if (!_rowCounts.containsKey(row) || !_columnCounts.containsKey(col)) return;
    references -= 1;
    void decrement(SplayTreeMap<int, int> counts, int key) {
      final count = counts[key];
      if (count == null || count <= 1) {
        counts.remove(key);
      } else {
        counts[key] = count - 1;
      }
    }

    decrement(_rowCounts, row);
    decrement(_columnCounts, col);
  }
}

/// A virtual Kitty Unicode-placeholder placement prototype.
class TerminalImageVirtualPlacement {
  TerminalImageVirtualPlacement({
    required this.cols,
    required this.rows,
    this.clientPlacementId = 0,
  });

  /// Number of columns the image should occupy.
  final int cols;

  /// Number of rows the image should occupy.
  final int rows;

  /// Client-assigned placement id (`p=`), 0 when unspecified. A relative
  /// placement's `Q=` selects the virtual placement by it.
  final int clientPlacementId;
}

/// A transmitted-but-not-yet-decoded image, held so its decode can be deferred
/// until something actually needs to paint it.
///
/// A MonkeyMux window switch replays every retained Kitty image up front
/// (store-only, `a=t`), but a foreground app such as the Copilot CLI only
/// re-emits placeholder cells for the few images currently on screen. Decoding
/// all of them eagerly wastes CPU, memory and raster bandwidth on images the
/// user never sees; keeping the encoded payload and decoding on first reference
/// bounds the work to the visible set.
typedef _PendingImageNumberReservation = ({
  int number,
  int mappedImageId,
  int? previousImageId,
});

class _PendingGraphicsImage {
  _PendingGraphicsImage({
    required this.payload,
    required this.format,
    required this.width,
    required this.height,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceSignature,
    this.transient = false,
    this.imageNumberReservations = const <_PendingImageNumberReservation>[],
  });

  final Uint8List payload;
  final int format;
  final int width;
  final int height;
  final int sourceWidth;
  final int sourceHeight;
  final int sourceSignature;
  final bool transient;
  final List<_PendingImageNumberReservation> imageNumberReservations;
}

/// Stores decoded terminal images and their placements with count and memory
/// caps.
class GraphicsManager {
  GraphicsManager({
    this.maxImageCount = 256,
    this.maxMemoryBytes = 100 * 1024 * 1024,
  });

  /// Maximum number of decoded images retained before the oldest are evicted.
  final int maxImageCount;

  /// Maximum approximate decoded image memory retained before LRU eviction.
  final int maxMemoryBytes;

  final Map<int, TerminalImage> _images = {};
  final Map<CellAnchor, TerminalImagePlacement> _placementsByAnchor = {};
  // Relative placements (`P=`), which have no anchor, oldest first.
  final Map<int, TerminalImagePlacement> _relativePlacements = {};
  // Every placement, anchored or relative, by its internal placement id: the
  // key a relative placement's parent link resolves through.
  final Map<int, TerminalImagePlacement> _placementsById = {};
  final Map<CellAnchor, TerminalImagePlaceholder> _placeholdersByAnchor = {};
  final Map<({int imageId, int bitWidth}), _TerminalImagePlaceholderGrid>
      _placeholderGrids = {};
  final Map<int, TerminalImageVirtualPlacement> _virtualPlacements = {};
  final Set<int> _retainedImageIds = {};
  // Encoded images awaiting a first paint reference (see [_PendingGraphicsImage]
  // and [storePendingImage]). Insertion-ordered so the oldest can be evicted.
  final Map<int, _PendingGraphicsImage> _pendingImages = {};
  final Map<int, Future<TerminalImage?>> _decodingImages = {};
  final Set<CellAnchor> _pendingPlacementAnchors = <CellAnchor>{};
  // Maps a client-assigned image number (`I=`) to the most recent image id it
  // was transmitted with, so later commands can address the image by number.
  final Map<int, int> _imageNumberToId = {};
  final Map<int, int> _imageNumberLastAccess = {};
  final Map<int, int> _pendingAnimationMutations = {};
  final Map<int, Map<int, int?>> _failedImageNumberReservations = {};
  final Map<
      int,
      Map<
          int,
          ({
            int count,
            int? previousImageId,
            bool hasSuccessfulReservation
          })>> _activeImageNumberReservations = {};

  /// Invoked after a deferred image finishes decoding so the host can repaint.
  /// The [Terminal] wires this to `notifyListeners`; it stays null in tests and
  /// standalone xterm.
  void Function()? onChanged;

  /// Bounds the encoded bytes retained for not-yet-decoded images. Small
  /// relative to the decoded-image budget because encoded payloads are far
  /// smaller than their RGBA bitmaps.
  static const int _maxPendingBytes = 64 * 1024 * 1024;

  /// Bounds the number of not-yet-decoded images retained.
  static const int _maxPendingImages = 128;

  int _pendingBytes = 0;

  // Next candidate for an image id the terminal picks for an `I=` number.
  int _nextImageId = 1;
  // Ids of images transmitted without `i=` or `I=`, from a range above Kitty's
  // 32-bit ids so they can never collide with an id a program chooses.
  int _nextAnonymousImageId = _firstAnonymousImageId;
  // Explicit ids of transmissions still being decoded, so an id the terminal
  // assigns meanwhile never takes one a program is about to store.
  final Map<int, int> _transmittingImageIds = {};
  int _nextPlacementId = 1;
  int _nextPlaceholderSequence = 1;
  int _generation = 0;
  int _clears = 0;
  final SplayTreeMap<int, int> _placementFirstRowCounts = SplayTreeMap();
  final SplayTreeMap<int, int> _placementLastRowCounts = SplayTreeMap();
  final Map<CellAnchor, ({int first, int last})> _placementRowsByAnchor = {};
  final Map<int, int> _placementCountByImage = {};
  bool _placementRelativeRowsDirty = false;
  int _placementExtentRebuildCount = 0;
  int _currentMemoryBytes = 0;
  int _accessClock = 0;
  double _cellPixelWidth = 0;
  double _cellPixelHeight = 0;
  int _viewportColumns = 80;

  /// Active placements: anchored placements oldest first, then relative ones.
  List<TerminalImagePlacement> get placements => <TerminalImagePlacement>[
        ..._placementsByAnchor.values,
        ..._relativePlacements.values,
      ];

  /// Active Unicode-placeholder cells, oldest first.
  List<TerminalImagePlaceholder> get placeholders =>
      _placeholdersByAnchor.values.toList(growable: false);

  /// Number of full placement-extent rebuilds (diagnostics/tests).
  int get placementExtentRebuildCount => _placementExtentRebuildCount;

  /// Number of active Unicode-placeholder cells.
  int get placeholderCount => _placeholdersByAnchor.length;

  /// Number of shared placeholder grid trackers retained for diagnostics/tests.
  int get placeholderGridCount => _placeholderGrids.length;

  /// The `{imageId: sourceSignature}` of every image the client is guaranteed to
  /// still hold after a window switch — retained decoded images and pending
  /// (transmitted but not yet decoded) ones.
  ///
  /// Reported to the MonkeyMux server on a window switch so it can omit
  /// re-transmitting images the client already has, sparing the client from
  /// re-parsing several megabytes of image data it would immediately discard as
  /// a duplicate. The signature disambiguates content, so a different window
  /// that reuses the same protocol id for different bytes is never skipped.
  ///
  /// Only images that survive [clear] are reported. A window switch replays
  /// `CSI ? 1049 h`, which clears the screen and drops every decoded image that
  /// is not retained (i.e. a physical `a=T` placement rather than a
  /// Unicode-placeholder virtual image). Reporting such an image would let the
  /// server skip re-transmitting it, and then the switch's own clear would drop
  /// it — leaving the redrawn cells with no image to composite (blank until the
  /// app fully redraws). Pending images survive the clear untouched, so they are
  /// always safe to report.
  Map<int, int> heldImageSignatures() {
    final result = <int, int>{};
    for (final entry in _images.entries) {
      if (!_retainedImageIds.contains(entry.key) ||
          _pendingAnimationMutations.containsKey(entry.key) ||
          entry.value._protocolAnimationModified) {
        continue;
      }
      final signature = entry.value.sourceSignature;
      if (signature != 0) {
        result[entry.key] = signature;
      }
    }
    for (final entry in _pendingImages.entries) {
      if (_pendingAnimationMutations.containsKey(entry.key)) {
        continue;
      }
      final signature = entry.value.sourceSignature;
      if (signature != 0) {
        result[entry.key] = signature;
      }
    }
    return result;
  }

  /// Protocol image ids referenced by attached Kitty Unicode-placeholder cells
  /// that resolve to no stored or pending image.
  ///
  /// The foreground app has drawn placeholder cells for these images, but their
  /// bytes were never received (or have been evicted) — for example when a
  /// window switch replay is bounded and drops images the app still shows, or a
  /// reconnect replays fewer images than the app references. Such placeholders
  /// render blank until the bytes arrive. A caller can ask the MonkeyMux server
  /// to replay exactly these ids from its per-window retained cache.
  ///
  /// Pending (transmitted but not yet decoded) ids are treated as resolvable and
  /// excluded: their bytes are already in flight. The result is de-duplicated by
  /// image id, so a full-screen image made of hundreds of placeholder cells
  /// contributes a single id.
  Set<int> unresolvedPlaceholderImageIds() {
    if (_placeholdersByAnchor.isEmpty) {
      return const <int>{};
    }
    final unresolved = <int>{};
    final resolvable = <int>{};
    for (final placeholder in _placeholdersByAnchor.values) {
      if (!placeholder.attached) {
        continue;
      }
      final id = placeholder.imageId;
      if (id <= 0 || unresolved.contains(id) || resolvable.contains(id)) {
        continue;
      }
      if (_canResolvePlaceholderId(id, placeholder.imageIdBitWidth)) {
        resolvable.add(id);
      } else {
        unresolved.add(id);
      }
    }
    return unresolved;
  }

  /// Whether a placeholder color [id] maps to any stored or pending image,
  /// directly or via the low-bit masked fallback used by
  /// [imageByPlaceholderColorId]. Unlike that method this never starts a decode,
  /// so it is safe to call while merely probing for missing images.
  bool _canResolvePlaceholderId(int id, int bitWidth) {
    if (_images.containsKey(id) || _pendingImages.containsKey(id)) {
      return true;
    }
    final mask = bitWidth >= 24 ? 0xFFFFFF : 0xFF;
    for (final key in _images.keys) {
      if (_retainedImageIds.contains(key) && (key & mask) == id) {
        return true;
      }
    }
    for (final key in _pendingImages.keys) {
      if ((key & mask) == id) {
        return true;
      }
    }
    return false;
  }

  /// Approximate decoded image memory currently retained.
  int get currentMemoryBytes => _currentMemoryBytes;

  /// Updates the cell pixel dimensions used to resolve one-dimensional Kitty
  /// placements (`c=` without `r=`, or vice versa).
  void setCellPixelSize(double width, double height) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    if (_cellPixelWidth != width || _cellPixelHeight != height) {
      _placementRelativeRowsDirty = true;
    }
    _cellPixelWidth = width;
    _cellPixelHeight = height;
  }

  /// Updates the terminal viewport width used to size natural Kitty placements.
  void setViewportColumns(int columns) {
    if (columns > 0) {
      if (_viewportColumns != columns) {
        _placementRelativeRowsDirty = true;
      }
      _viewportColumns = columns;
    }
  }

  /// Cell width in pixels, with the same fallback the placement geometry uses
  /// before the renderer has reported one.
  double get cellPixelWidth => _cellPixelWidth > 0 ? _cellPixelWidth : 10.0;

  /// Cell height in pixels; see [cellPixelWidth].
  double get cellPixelHeight => _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;

  /// Cell width divided by cell height, with a terminal-like fallback.
  double get cellPixelAspectRatio => _cellPixelWidth > 0 && _cellPixelHeight > 0
      ? _cellPixelWidth / _cellPixelHeight
      : 0.5;

  /// Number of decoded images currently retained.
  int get imageCount => _images.length;

  /// Number of retained images that contain more than one frame.
  int get animationImageCount =>
      _images.values.where((image) => image.frameCount > 1).length;

  /// Whether any images are currently placed.
  bool get hasPlacements =>
      _placementsByAnchor.isNotEmpty || _relativePlacements.isNotEmpty;

  /// Whether any Unicode-placeholder cells are currently tracked.
  bool get hasPlaceholders => _placeholdersByAnchor.isNotEmpty;

  /// Keeps an in-flight physical placement anchor attached through text erases.
  void retainPendingPlacementAnchor(CellAnchor anchor) {
    anchor.onDispose = _handleAnchorDisposed;
    _pendingPlacementAnchors.add(anchor);
  }

  /// Releases an in-flight physical placement anchor after decode/placement.
  void releasePendingPlacementAnchor(CellAnchor anchor) {
    _pendingPlacementAnchors.remove(anchor);
  }

  /// Physical placement anchors owned by [line], including in-flight decodes.
  ///
  /// Looking through the line's anchors keeps terminal erase and resize work
  /// proportional to that one row instead of every image in scrollback.
  Set<CellAnchor> physicalPlacementAnchorsInLine(BufferLine line) =>
      <CellAnchor>{
        for (final anchor in line.anchors)
          if (_placementsByAnchor.containsKey(anchor) ||
              _pendingPlacementAnchors.contains(anchor))
            anchor,
      };

  /// Takes the placements anchored in a scroll region out of their rows before
  /// the region scrolls by [delta] rows (negative scrolls up), for
  /// [endRegionScroll] to put back once the rows have moved.
  ///
  /// [top] and [bottom] are absolute buffer rows. As Kitty specifies, an image
  /// entirely inside the region scrolls with the text and is clipped where it
  /// would leave the region; one that extends past a margin stays where it
  /// is. [hasMargins] is false for a region spanning the whole screen, where
  /// an image may run off the bottom and still scroll, and is only clipped at
  /// the top edge, as the screen would clip it.
  ///
  /// Returns null, cheaply, when nothing is anchored in the region.
  GraphicsRegionScroll? beginRegionScroll(
    IndexAwareCircularBuffer<BufferLine> lines, {
    required int top,
    required int bottom,
    required int delta,
    required bool hasMargins,
  }) {
    if (_placementsByAnchor.isEmpty || delta == 0 || bottom < top) return null;
    final moves = <_RegionScrollMove>[];
    final lastRow = math.min(bottom, lines.length - 1);
    for (var row = math.max(0, top); row <= lastRow; row++) {
      for (final anchor in lines[row].anchors.toList()) {
        final placement = _placementsByAnchor[anchor];
        if (placement == null) continue;
        final range = _placementRelativeCellRange(placement);
        final scrolls = row + range.firstRow >= top &&
            (!hasMargins || row + range.lastRow <= bottom);
        // The column is read while the anchor is attached: insertions and
        // deletions may have moved it since the placement was made.
        moves.add((
          placement: placement,
          row: row,
          col: anchor.x,
          scrolls: scrolls,
        ));
        // Detach without disposing: the placement keeps its internal id, so
        // relative placements that refer to it survive the move.
        _placementsByAnchor.remove(anchor);
        _unindexPlacementRows(anchor);
        anchor.onDispose = null;
        anchor.dispose();
      }
    }
    if (moves.isEmpty) return null;
    return GraphicsRegionScroll._(
      moves,
      top: top,
      bottom: bottom,
      delta: delta,
      hasMargins: hasMargins,
    );
  }

  /// Re-anchors the placements [beginRegionScroll] took out, after the region's
  /// rows have moved: moved and clipped, kept in place, or removed once they
  /// have scrolled out of the region entirely.
  void endRegionScroll(
    IndexAwareCircularBuffer<BufferLine> lines,
    GraphicsRegionScroll? scroll,
  ) {
    if (scroll == null) return;
    var removed = false;
    for (final move in scroll._moves) {
      final placement = move.placement;
      final row = move.scrolls ? move.row + scroll.delta : move.row;
      final next = move.scrolls
          ? _scrolledPlacement(placement, row, move.col, scroll, lines)
          : placement._withAnchor(lines[row].createAnchor(move.col));
      if (next == null) {
        _placementsById.remove(placement.placementId);
        _decrementPlacementImageCount(placement.imageId);
        removed = true;
        continue;
      }
      _placementsById[next.placementId] = next;
      final anchor = next.anchor!;
      anchor.onDispose = _handleAnchorDisposed;
      _placementsByAnchor[anchor] = next;
      if (!_placementRelativeRowsDirty) _indexPlacementRows(next);
    }
    if (removed) _removeOrphanedRelativePlacements();
  }

  /// [placement] moved to [row] by a region scroll, clipped to the region the
  /// way Kitty clips it, or null once no part of it is left inside.
  TerminalImagePlacement? _scrolledPlacement(
    TerminalImagePlacement placement,
    int row,
    int col,
    GraphicsRegionScroll scroll,
    IndexAwareCircularBuffer<BufferLine> lines,
  ) {
    final range = _placementRelativeCellRange(placement, column: col);
    final first = row + range.firstRow;
    final last = row + range.lastRow;
    if (last < scroll.top || first > scroll.bottom) return null;
    final clipTop = first < scroll.top;
    final clipBottom = scroll.hasMargins && last > scroll.bottom;
    if (!clipTop && !clipBottom) {
      return placement._withAnchor(lines[row].createAnchor(col));
    }

    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    final destinationHeight =
        _placementDestinationSize(placement, column: col).height;
    final source = _placementLogicalSourceRect(placement);
    if (source == null || destinationHeight <= 0) {
      // Without the image size the crop cannot be computed; drop what would
      // otherwise spill out of the region.
      return null;
    }
    // Source pixels per screen pixel, as Kitty derives it from the placement.
    final scale = source.height / destinationHeight;
    final yOffset = placement.cellYOffset(cellHeight);
    var srcY = source.top;
    var srcHeight = source.height;
    var rows = placement.rows;
    var anchorRow = row;
    var newYOffset = placement.yOffset;
    // The image was inside the region before it scrolled one way, so only
    // one edge can cut it.
    if (clipTop) {
      final clippedRows = scroll.top - row;
      final clip = scale * (cellHeight * clippedRows - yOffset);
      if (srcHeight <= clip) return null;
      srcY += clip;
      srcHeight -= clip;
      if (rows > 0) rows = math.max(1, rows - clippedRows);
      anchorRow = scroll.top;
      newYOffset = 0;
    } else {
      final clippedRows = last - scroll.bottom;
      final visibleHeight =
          cellHeight * (last - first + 1 - clippedRows) - yOffset;
      final visibleSource = scale * visibleHeight;
      if (visibleSource <= 0) return null;
      if (visibleSource < srcHeight) srcHeight = visibleSource;
      if (rows > 0) rows = math.max(1, rows - clippedRows);
    }
    // The crop is kept in whole source pixels; round outwards so a sliver of
    // a small image is not lost.
    final top = srcY.floor();
    final bottom = (srcY + srcHeight).ceil();
    if (bottom <= top) return null;
    return placement._withAnchor(
      lines[anchorRow].createAnchor(col),
      rows: rows,
      srcY: top,
      srcHeight: bottom - top,
      yOffset: newYOffset,
    );
  }

  /// The source rectangle a placement shows, in the image's original pixels.
  ({double top, double height})? _placementLogicalSourceRect(
    TerminalImagePlacement placement,
  ) {
    final image = _images[placement.imageId];
    final pending = _pendingImages[placement.imageId];
    final sourceHeight = image?.sourceHeight ?? pending?.sourceHeight ?? 0;
    if (sourceHeight <= 0) return null;
    final top = placement.srcY.clamp(0, sourceHeight).toDouble();
    final available = sourceHeight - top;
    final height = placement.srcHeight > 0
        ? math.min(placement.srcHeight.toDouble(), available)
        : available;
    return height > 0 ? (top: top, height: height) : null;
  }

  /// Removes Unicode placeholders attached to [line] within `[start, end)`.
  /// Physical placement anchors are independent layers and are left intact.
  void removePlaceholdersInLineRange(BufferLine line, int start, int end) {
    if (end <= start) return;
    for (final anchor in line.anchors.toList()) {
      if (anchor.x < start || anchor.x >= end) continue;
      final placeholder = _placeholdersByAnchor[anchor];
      if (placeholder != null) {
        _disposePlaceholder(placeholder);
      }
    }
  }

  /// Removes an existing Unicode placeholder at one cell before it is rewritten.
  void removePlaceholderAt(BufferLine line, int column) =>
      removePlaceholdersInLineRange(line, column, column + 1);

  /// Attached physical placements intersecting the requested buffer rows.
  ///
  /// Placements can shift above or below their anchor with `Y=`, so candidate
  /// anchor rows use the retained minimum/maximum shifted cell extents.
  List<TerminalImagePlacement> placementsInRows(
    IndexAwareCircularBuffer<BufferLine> lines,
    int firstRow,
    int lastRow,
  ) {
    if (!hasPlacements || lines.length == 0) {
      return const <TerminalImagePlacement>[];
    }
    final first = firstRow.clamp(0, lines.length - 1);
    final last = lastRow.clamp(0, lines.length - 1);
    if (last < first) {
      return const <TerminalImagePlacement>[];
    }
    final result = <TerminalImagePlacement>[];
    if (_placementsByAnchor.isNotEmpty) {
      final relativeRows = _placementRelativeRowExtent;
      final firstAnchorRow = math.max(0, first - relativeRows.last);
      final lastAnchorRow = math.min(
        lines.length - 1,
        last - relativeRows.first,
      );
      final candidateRowCount = math.max(0, lastAnchorRow - firstAnchorRow + 1);
      if (candidateRowCount > _placementsByAnchor.length) {
        for (final placement in _placementsByAnchor.values) {
          if (placement.attached &&
              _placementIntersectsRows(placement, first, last)) {
            result.add(placement);
          }
        }
      } else {
        for (var row = firstAnchorRow; row <= lastAnchorRow; row++) {
          for (final anchor in lines[row].anchors) {
            final placement = _placementsByAnchor[anchor];
            if (placement != null &&
                placement.attached &&
                _placementIntersectsRows(placement, first, last)) {
              result.add(placement);
            }
          }
        }
      }
    }
    // Relative placements move with their parents, so they cannot be found
    // through line anchors; there are few of them, so test each one.
    for (final placement in _relativePlacements.values) {
      if (placement.attached &&
          _placementIntersectsRows(placement, first, last)) {
        result.add(placement);
      }
    }
    return result;
  }

  ({int first, int last}) get _placementRelativeRowExtent {
    if (_placementRelativeRowsDirty) {
      _placementExtentRebuildCount += 1;
      _placementFirstRowCounts.clear();
      _placementLastRowCounts.clear();
      _placementRowsByAnchor.clear();
      for (final placement in _placementsByAnchor.values) {
        if (placement.attached) _indexPlacementRows(placement);
      }
      _placementRelativeRowsDirty = false;
    }
    return (
      first: _placementFirstRowCounts.isEmpty
          ? 0
          : _placementFirstRowCounts.firstKey()!,
      last: _placementLastRowCounts.isEmpty
          ? 0
          : _placementLastRowCounts.lastKey()!,
    );
  }

  void _indexPlacementRows(TerminalImagePlacement placement) {
    final range = _placementCandidateRelativeRows(placement);
    _placementRowsByAnchor[placement.anchor!] = range;
    _placementFirstRowCounts.update(
      range.first,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    _placementLastRowCounts.update(
      range.last,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  void _unindexPlacementRows(CellAnchor anchor) {
    final range = _placementRowsByAnchor.remove(anchor);
    if (range == null) return;
    void decrement(SplayTreeMap<int, int> counts, int key) {
      final count = counts[key];
      if (count == null || count <= 1) {
        counts.remove(key);
      } else {
        counts[key] = count - 1;
      }
    }

    decrement(_placementFirstRowCounts, range.first);
    decrement(_placementLastRowCounts, range.last);
  }

  /// Attached Unicode placeholders whose cells are within the requested rows.
  ///
  /// The line owns the anchors, so this lookup stays proportional to visible
  /// placeholder cells even when a long session retains thousands off screen.
  List<TerminalImagePlaceholder> placeholdersInRows(
    IndexAwareCircularBuffer<BufferLine> lines,
    int firstRow,
    int lastRow,
  ) {
    if (_placeholdersByAnchor.isEmpty || lines.length == 0) {
      return const <TerminalImagePlaceholder>[];
    }
    final first = firstRow.clamp(0, lines.length - 1);
    final last = lastRow.clamp(0, lines.length - 1);
    if (last < first) {
      return const <TerminalImagePlaceholder>[];
    }
    final result = <TerminalImagePlaceholder>[];
    for (var row = first; row <= last; row++) {
      for (final anchor in lines[row].anchors) {
        final placeholder = _placeholdersByAnchor[anchor];
        if (placeholder != null && placeholder.attached) {
          result.add(placeholder);
        }
      }
    }
    return result;
  }

  /// Removes graphics anchored to [line] before the circular scrollback buffer
  /// evicts it. Work is proportional to anchors on that line, not total history.
  void removeGraphicsAnchoredToLine(BufferLine line) {
    for (final anchor in line.anchors.toList()) {
      final placement = _placementsByAnchor[anchor];
      if (placement != null) {
        _disposePlacement(placement);
      }
      final placeholder = _placeholdersByAnchor[anchor];
      if (placeholder != null) {
        _disposePlaceholder(placeholder);
      }
      _pendingPlacementAnchors.remove(anchor);
    }
    // Do not bump the global generation: an unrelated in-flight decode must
    // survive local scrollback eviction. The evicted anchor itself is detached
    // and therefore cannot materialize later. Decoded image memory remains
    // bounded by the manager's count/byte eviction policy; explicit prune/clear
    // operations reclaim unreferenced images away from this hot path.
    // Indexed removal and placeholder grid release are O(anchors on this line).
  }

  /// Bumped whenever placements are cleared outside the command queues (a
  /// reset, a screen clear, rows removed). An asynchronous image decode
  /// captures this before it starts and skips placing if it changed, so a clear
  /// that races an in-flight decode cannot leave a stale image behind.
  int get generation => _generation;

  /// Bumped by every [clear]. Commands wait in a queue while earlier images
  /// decode; one that places an image without an anchor cell (a relative
  /// placement) captures this when it arrives and places nothing if it
  /// changed, as the clear would have taken the placement had the command run
  /// at once.
  int get clears => _clears;

  /// Looks up a stored image by id.
  TerminalImage? imageById(int id) {
    final image = _images[id];
    if (image != null) {
      image._lastAccess = ++_accessClock;
    }
    return image;
  }

  /// Looks up virtual placement dimensions for [imageId].
  TerminalImageVirtualPlacement? virtualPlacementById(int imageId) =>
      _virtualPlacements[imageId];

  /// Associates a client image number (`I=`) with the [imageId] it was
  /// transmitted with. Later transmits of the same number overwrite the mapping.
  bool registerImageNumber(int number, int imageId) {
    if (number <= 0 || imageId <= 0 || !_makeRoomForImageNumber(number)) {
      return false;
    }
    _imageNumberToId[number] = imageId;
    _imageNumberLastAccess[number] = ++_accessClock;
    return true;
  }

  /// Reserves a fresh protocol image id and maps [number] to it immediately.
  ///
  /// I-only roots use this before their asynchronous decode so following
  /// commands in the same stream bind to the new root rather than an older image
  /// that previously used the number.
  ({int imageId, int? previousImageId}) reserveImageIdForNumber(int number) {
    if (number <= 0) {
      return (imageId: 0, previousImageId: null);
    }
    if (!_makeRoomForImageNumber(number)) {
      return (imageId: 0, previousImageId: null);
    }
    final previousImageId = _imageNumberToId[number];
    final imageId = _allocateProtocolImageId();
    _imageNumberToId[number] = imageId;
    _imageNumberLastAccess[number] = ++_accessClock;
    _trackImageNumberReservation(number, imageId, previousImageId);
    return (imageId: imageId, previousImageId: previousImageId);
  }

  /// Maps [number] to an explicit [imageId] while its root is being validated.
  ({bool accepted, int? previousImageId}) reserveExplicitImageIdForNumber(
    int number,
    int imageId,
  ) {
    if (number <= 0 || imageId <= 0 || !_makeRoomForImageNumber(number)) {
      return (accepted: false, previousImageId: null);
    }
    final previousImageId = _imageNumberToId[number];
    _imageNumberToId[number] = imageId;
    _imageNumberLastAccess[number] = ++_accessClock;
    _trackImageNumberReservation(number, imageId, previousImageId);
    return (accepted: true, previousImageId: previousImageId);
  }

  /// Picks a protocol image id for an `I=` number that no image, placement,
  /// mapping or in-flight transmission uses, so it never collides with an id
  /// the program chose (Kitty picks a free one too).
  int _allocateProtocolImageId() {
    for (var probes = 0; probes <= _maxProtocolImageId; probes++) {
      var id = _nextImageId;
      if (id <= 0 || id > _maxProtocolImageId) id = 1;
      _nextImageId = id + 1;
      if (!_protocolImageIdInUse(id)) return id;
    }
    return 0;
  }

  bool _protocolImageIdInUse(int id) =>
      _images.containsKey(id) ||
      _pendingImages.containsKey(id) ||
      _decodingImages.containsKey(id) ||
      _transmittingImageIds.containsKey(id) ||
      _virtualPlacements.containsKey(id) ||
      (_placementCountByImage[id] ?? 0) > 0 ||
      _imageNumberToId.containsValue(id) ||
      _activeImageNumberReservations.values.any(
        (reservations) => reservations.containsKey(id),
      );

  /// Notes that a transmission with the explicit protocol id [id] has started,
  /// so [reserveImageIdForNumber] will not hand the id out before it is stored.
  /// Pair with [endImageTransmission].
  void beginImageTransmission(int id) {
    if (id <= 0) return;
    _transmittingImageIds.update(id, (count) => count + 1, ifAbsent: () => 1);
    if (id >= _nextImageId && id < _maxProtocolImageId) {
      _nextImageId = id + 1;
    }
  }

  /// Whether image [id] is still arriving: a transmission with that explicit
  /// id, or one an `I=` number reserved it for, has not been stored yet.
  bool isImageTransmitting(int id) =>
      _transmittingImageIds.containsKey(id) ||
      _activeImageNumberReservations.values.any(
        (reservations) => reservations.containsKey(id),
      );

  /// Ends a transmission noted by [beginImageTransmission].
  void endImageTransmission(int id) {
    final count = _transmittingImageIds[id];
    if (count == null) return;
    if (count <= 1) {
      _transmittingImageIds.remove(id);
    } else {
      _transmittingImageIds[id] = count - 1;
    }
  }

  /// Applies a retransmission of protocol image [id]. Kitty replaces the
  /// image: every placement of the old one goes now (anchored, relative and
  /// virtual, with the relative placements that hang off them), and so does
  /// its data unless [keepData] says the new bytes are identical. A
  /// retransmission that then fails or never completes leaves no image rather
  /// than the stale one. Image-number mappings to [id] are kept.
  void replaceImageForRetransmission(int id, {required bool keepData}) {
    if (id <= 0) return;
    final hadVirtual = _virtualPlacements.remove(id) != null;
    final removed = _removePlacementsWhere(
      (placement) => placement.imageId == id,
    );
    if (hadVirtual && removed.isEmpty) _removeOrphanedRelativePlacements();
    if (keepData) return;
    final image = _images.remove(id);
    if (image != null) {
      _currentMemoryBytes -= image.sizeBytes;
    }
    final pending = _pendingImages.remove(id);
    if (pending != null) {
      _pendingBytes -= pending.payload.length;
      for (final reservation in pending.imageNumberReservations) {
        commitImageIdReservation(reservation.number, reservation.mappedImageId);
      }
    }
    _pendingAnimationMutations.remove(id);
  }

  bool _makeRoomForImageNumber(int number) {
    if (_imageNumberToId.containsKey(number) ||
        _imageNumberToId.length < maxImageCount) {
      return true;
    }
    int? oldestNumber;
    var oldestAccess = 0;
    for (final entry in _imageNumberLastAccess.entries) {
      if (_activeImageNumberReservations[entry.key]?.isNotEmpty ?? false) {
        continue;
      }
      if (oldestNumber == null || entry.value < oldestAccess) {
        oldestNumber = entry.key;
        oldestAccess = entry.value;
      }
    }
    if (oldestNumber == null) {
      return false;
    }
    _imageNumberToId.remove(oldestNumber);
    _imageNumberLastAccess.remove(oldestNumber);
    _failedImageNumberReservations.remove(oldestNumber);
    return true;
  }

  void _trackImageNumberReservation(
    int number,
    int imageId,
    int? previousImageId,
  ) {
    final active = _activeImageNumberReservations.putIfAbsent(number, () => {});
    final existing = active[imageId];
    active[imageId] = (
      count: (existing?.count ?? 0) + 1,
      previousImageId:
          existing == null ? previousImageId : existing.previousImageId,
      hasSuccessfulReservation: existing?.hasSuccessfulReservation ?? false,
    );
  }

  /// Rolls back a failed reservation unless a later command remapped [number].
  void rollbackImageIdReservation(
    int number,
    int reservedImageId,
    int? previousImageId,
  ) {
    final active = _activeImageNumberReservations[number];
    final reservation = active?[reservedImageId];
    final effectivePreviousImageId =
        reservation == null ? previousImageId : reservation.previousImageId;
    if (reservation != null && reservation.count > 1) {
      active![reservedImageId] = (
        count: reservation.count - 1,
        previousImageId: reservation.previousImageId,
        hasSuccessfulReservation: reservation.hasSuccessfulReservation,
      );
      return;
    }
    active?.remove(reservedImageId);
    final noActiveReservations = active?.isEmpty ?? true;
    if (noActiveReservations) {
      _activeImageNumberReservations.remove(number);
    }
    if (reservation?.hasSuccessfulReservation ?? false) {
      if (_imageNumberToId[number] == reservedImageId) {
        _failedImageNumberReservations.remove(number);
      }
      return;
    }
    if (_imageNumberToId[number] != reservedImageId) {
      if (_activeImageNumberReservations[number]?.containsKey(
            _imageNumberToId[number],
          ) ??
          false) {
        _failedImageNumberReservations.putIfAbsent(
            number, () => {})[reservedImageId] = effectivePreviousImageId;
      }
      if (noActiveReservations) {
        _failedImageNumberReservations.remove(number);
      }
      return;
    }
    final failed = _failedImageNumberReservations.putIfAbsent(number, () => {})
      ..[reservedImageId] = effectivePreviousImageId;
    var restoredImageId = effectivePreviousImageId;
    while (restoredImageId != null && failed.containsKey(restoredImageId)) {
      final failedImageId = restoredImageId;
      restoredImageId = failed.remove(failedImageId);
    }
    failed.remove(reservedImageId);
    if (failed.isEmpty) {
      _failedImageNumberReservations.remove(number);
    }
    if (restoredImageId == null) {
      _imageNumberToId.remove(number);
      _imageNumberLastAccess.remove(number);
    } else {
      _imageNumberToId[number] = restoredImageId;
      _imageNumberLastAccess[number] = ++_accessClock;
    }
  }

  /// Marks a reserved mapping as valid and discards failed predecessor history.
  void commitImageIdReservation(int number, int imageId) {
    final active = _activeImageNumberReservations[number];
    final reservation = active?[imageId];
    if (reservation != null && reservation.count > 1) {
      active![imageId] = (
        count: reservation.count - 1,
        previousImageId: reservation.previousImageId,
        hasSuccessfulReservation: true,
      );
    } else {
      active?.remove(imageId);
    }
    if (active?.isEmpty ?? true) {
      _activeImageNumberReservations.remove(number);
      _failedImageNumberReservations.remove(number);
    }
    if (_imageNumberToId[number] == imageId) {
      _imageNumberLastAccess[number] = ++_accessClock;
      _failedImageNumberReservations.remove(number);
    } else {
      _failedImageNumberReservations[number]?.remove(imageId);
    }
  }

  /// Settles one duplicate reservation collapsed into an existing pending decode.
  void collapseImageIdReservation(int number, int imageId) {
    final active = _activeImageNumberReservations[number];
    final reservation = active?[imageId];
    if (reservation == null || reservation.count <= 1) {
      return;
    }
    active![imageId] = (
      count: reservation.count - 1,
      previousImageId: reservation.previousImageId,
      hasSuccessfulReservation: reservation.hasSuccessfulReservation,
    );
  }

  /// Resolves a client image number (`I=`) to its current image id, if known.
  int? imageIdForNumber(int number) {
    final imageId = _imageNumberToId[number];
    if (imageId != null) {
      _imageNumberLastAccess[number] = ++_accessClock;
    }
    return imageId;
  }

  /// Marks [imageId] as having queued or applied animation state changes.
  void markImageAnimationDirty(int imageId) {
    if (imageId > 0) {
      _pendingAnimationMutations.update(
        imageId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  /// Settles one queued animation mutation for [imageId].
  void settleImageAnimationMutation(int imageId) {
    final count = _pendingAnimationMutations[imageId];
    if (count == null) {
      return;
    }
    if (count <= 1) {
      _pendingAnimationMutations.remove(imageId);
    } else {
      _pendingAnimationMutations[imageId] = count - 1;
    }
  }

  /// Looks up an image referenced by a Kitty Unicode placeholder color.
  ///
  /// Placeholders encode the low 8 or 24 bits of the protocol image id in the
  /// foreground color, with higher bits optionally carried by combining
  /// diacritics. When that high-byte metadata is not available, fall back to the
  /// retained protocol image whose low bits match the color value.
  ///
  /// If the referenced image is still pending (transmitted but not decoded), its
  /// decode is started and null is returned; the caller (renderer) paints
  /// nothing this frame and repaints via [onChanged] once the decode completes.
  TerminalImage? imageByPlaceholderColorId(int id, {required int bitWidth}) {
    final direct = imageById(id);
    if (direct != null) {
      return direct;
    }
    if (_pendingImages.containsKey(id)) {
      unawaited(resolveImage(id));
      return null;
    }

    final mask = bitWidth >= 24 ? 0xFFFFFF : 0xFF;
    TerminalImage? best;
    for (final entry in _images.entries) {
      if (!_retainedImageIds.contains(entry.key)) {
        continue;
      }
      if ((entry.key & mask) != id) {
        continue;
      }
      if (best == null || entry.value._lastAccess >= best._lastAccess) {
        best = entry.value;
      }
    }
    if (best != null) {
      best._lastAccess = ++_accessClock;
      return best;
    }

    // No decoded image matches; a pending one whose low bits match must be
    // decoded before it can be composited.
    int? pendingMatch;
    for (final pendingId in _pendingImages.keys) {
      if ((pendingId & mask) == id) {
        pendingMatch = pendingId; // keep scanning: newest insertion wins
      }
    }
    if (pendingMatch != null) {
      unawaited(resolveImage(pendingMatch));
    }
    return null;
  }

  /// Resolves a placement's image for painting, starting a deferred decode if
  /// the image is pending. Returns null (paint nothing this frame) until the
  /// decode completes and triggers a repaint via [onChanged].
  TerminalImage? imageForPlacement(int id) {
    final image = imageById(id);
    if (image != null) {
      return image;
    }
    if (_pendingImages.containsKey(id)) {
      unawaited(resolveImage(id));
    }
    return null;
  }

  /// Resolves [id] to a decoded image, awaiting a deferred decode when needed.
  ///
  /// Concurrent callers share one decode. This is used by animation-frame
  /// commands, which need the root image's pixels before they can compose a new
  /// frame.
  Future<TerminalImage?> resolveImage(int id) {
    final decoded = imageById(id);
    if (decoded != null) {
      return Future<TerminalImage?>.value(decoded);
    }
    final inFlight = _decodingImages[id];
    if (inFlight != null) {
      return _resolvePendingReplacementAfter(id, inFlight);
    }
    final pending = _pendingImages[id];
    if (pending == null) {
      return Future<TerminalImage?>.value();
    }

    late final Future<TerminalImage?> future;
    future = _decodePendingImage(id, pending).whenComplete(() {
      if (identical(_decodingImages[id], future)) {
        _decodingImages.remove(id);
      }
    });
    _decodingImages[id] = future;
    return _resolvePendingReplacementAfter(id, future);
  }

  Future<TerminalImage?> _resolvePendingReplacementAfter(
    int id,
    Future<TerminalImage?> decoding,
  ) {
    return decoding.then((image) {
      if (image != null || !_pendingImages.containsKey(id)) {
        return image;
      }
      // The completed decode belonged to bytes that were replaced while it was
      // in flight. Resolve the replacement rather than reporting a transient
      // miss to an animation command queued behind the root.
      return resolveImage(id);
    });
  }

  /// Whether image [id] has been transmitted but not yet decoded.
  bool hasPendingImage(int id) => _pendingImages.containsKey(id);

  /// The source size of image [id], decoded or pending, and the size its
  /// pixels are kept at: the decoded size, or for a pending image the size
  /// the decoder will keep (see [terminalDecodedImageSize]). Placement
  /// geometry is computed in the kept size, so an image covers the same
  /// cells before and after its decode. Null when the image or its size is
  /// unknown.
  ({int sourceWidth, int sourceHeight, int width, int height})? imageGeometry(
    int id,
  ) {
    final image = _images[id];
    if (image != null) {
      return (
        sourceWidth: image.sourceWidth,
        sourceHeight: image.sourceHeight,
        width: image.image.width,
        height: image.image.height,
      );
    }
    final pending = _pendingImages[id];
    if (pending == null ||
        pending.sourceWidth <= 0 ||
        pending.sourceHeight <= 0) {
      return null;
    }
    final kept = terminalDecodedImageSize(
      pending.sourceWidth,
      pending.sourceHeight,
      format: pending.format,
    );
    return (
      sourceWidth: pending.sourceWidth,
      sourceHeight: pending.sourceHeight,
      width: kept.width,
      height: kept.height,
    );
  }

  /// Intrinsic dimensions retained for a pending encoded image, if known.
  ({int width, int height})? pendingImageDimensions(int id) {
    final pending = _pendingImages[id];
    if (pending == null ||
        pending.sourceWidth <= 0 ||
        pending.sourceHeight <= 0) {
      return null;
    }
    return (width: pending.sourceWidth, height: pending.sourceHeight);
  }

  /// Whether a pending (undecoded) image [id] carries a matching
  /// [sourceSignature], so a replay can skip re-storing identical bytes. A zero
  /// signature never matches.
  bool hasPendingWithSignature(int id, int sourceSignature) {
    if (id <= 0 || sourceSignature == 0) {
      return false;
    }
    final pending = _pendingImages[id];
    return pending != null && pending.sourceSignature == sourceSignature;
  }

  /// Retains an encoded image for [id] without decoding it, to be decoded on
  /// first paint reference. See [_PendingGraphicsImage].
  void storePendingImage(
    int id, {
    required Uint8List payload,
    required int format,
    int width = 0,
    int height = 0,
    int sourceWidth = 0,
    int sourceHeight = 0,
    int sourceSignature = 0,
    bool transient = false,
    int? imageNumber,
    int? mappedImageId,
    int? previousImageId,
  }) {
    if (id <= 0) {
      return;
    }
    // Already decoded from identical bytes: nothing to defer.
    if (hasImageWithSignature(id, sourceSignature)) {
      return;
    }
    if ((_placementCountByImage[id] ?? 0) > 0) {
      _placementRelativeRowsDirty = true;
    }
    // New bytes for an id whose previous image is already decoded supersede it;
    // drop the stale bitmap (keeping any placements/placeholders that reference
    // the id) so the deferred decode of the new bytes is what gets painted.
    final stale = _images.remove(id);
    if (stale != null) {
      _currentMemoryBytes -= stale.sizeBytes;
    }
    final existing = _pendingImages.remove(id);
    final reservations = <_PendingImageNumberReservation>[
      ...?existing?.imageNumberReservations,
    ];
    if (existing != null) {
      _pendingBytes -= existing.payload.length;
    }
    if (imageNumber != null && mappedImageId != null) {
      var rollbackImageId = previousImageId;
      for (final reservation in reservations) {
        if (reservation.number == imageNumber &&
            reservation.mappedImageId == mappedImageId) {
          collapseImageIdReservation(imageNumber, mappedImageId);
          if (previousImageId == mappedImageId) {
            rollbackImageId = reservation.previousImageId;
          }
          break;
        }
      }
      reservations.removeWhere(
        (reservation) => reservation.number == imageNumber,
      );
      reservations.add((
        number: imageNumber,
        mappedImageId: mappedImageId,
        previousImageId: rollbackImageId,
      ));
    }
    _pendingImages[id] = _PendingGraphicsImage(
      payload: payload,
      format: format,
      width: width,
      height: height,
      sourceWidth: sourceWidth > 0 ? sourceWidth : width,
      sourceHeight: sourceHeight > 0 ? sourceHeight : height,
      sourceSignature: sourceSignature,
      transient: transient,
      imageNumberReservations:
          List<_PendingImageNumberReservation>.unmodifiable(reservations),
    );
    _pendingBytes += payload.length;
    if (id >= _nextImageId && id < _maxProtocolImageId) {
      _nextImageId = id + 1;
    }
    _evictPendingIfNeeded();
  }

  void _evictPendingIfNeeded() {
    while (_pendingImages.isNotEmpty &&
        (_pendingBytes > _maxPendingBytes ||
            _pendingImages.length > _maxPendingImages)) {
      final oldest = _pendingEvictionCandidate();
      final removed = _pendingImages.remove(oldest);
      if (removed != null) {
        _pendingBytes -= removed.payload.length;
        _rollbackPendingImageNumber(removed);
      }
      // The image bytes are gone, so its virtual placement (if any) can no
      // longer back a placeholder; drop it unless a decoded image kept the id.
      if (!_images.containsKey(oldest)) {
        _virtualPlacements.remove(oldest);
      }
    }
    _removeOrphanedRelativePlacements();
  }

  /// The pending image to evict first: by [_evictionRank], oldest first.
  int _pendingEvictionCandidate() {
    int? best;
    var bestRank = 0;
    for (final entry in _pendingImages.entries) {
      final rank = _evictionRank(entry.key, transient: entry.value.transient);
      if (best == null || rank < bestRank) {
        best = entry.key;
        bestRank = rank;
      }
    }
    return best!;
  }

  /// Eviction order under memory pressure, lowest first, as Ghostty orders
  /// it: unplaced transient images (Kitty usage hint `N=1`), other unplaced
  /// images, placed transient images, then placed images.
  int _evictionRank(int imageId, {required bool transient}) =>
      (transient ? 0 : 1) +
      (_imageHasPlacements(imageId) || _isReferencedByPlaceholder(imageId)
          ? 2
          : 0);

  bool _isReferencedByPlaceholder(int imageId) =>
      _placeholderGrids.keys.any((key) => key.imageId == imageId);

  Future<TerminalImage?> _decodePendingImage(
    int id,
    _PendingGraphicsImage pending,
  ) async {
    final observer = terminalGraphicsDecodeObserver;
    final stopwatch = observer == null ? null : (Stopwatch()..start());
    DecodedTerminalImage? decoded;
    await terminalGraphicsDecodeGate.acquire();
    try {
      decoded = await decodeTerminalImageSequence(
        pending.payload,
        format: pending.format,
        width: pending.width,
        height: pending.height,
      );
    } finally {
      terminalGraphicsDecodeGate.release();
    }

    // The pending entry may have been evicted, deleted (`a=d`) or replaced with
    // fresh bytes while decoding; only commit when it is still the same image.
    if (!identical(_pendingImages[id], pending)) {
      if (decoded != null) {
        _disposeDecodedTerminalImage(decoded);
      }
      return imageById(id);
    }
    observer?.call(
      payloadBytes: pending.payload.length,
      inflateMicros: 0,
      decodeMicros: stopwatch?.elapsedMicroseconds ?? 0,
      compressed: false,
      success: decoded != null,
      imageId: id.toString(),
      action: 'lazy',
      reused: false,
    );
    _pendingImages.remove(id);
    _pendingBytes -= pending.payload.length;
    if (decoded == null) {
      _rollbackPendingImageNumber(pending);
      return null;
    }
    final storedImageId = storeDecodedImageWithId(
      id,
      decoded,
      sourceSignature: pending.sourceSignature,
      transient: pending.transient,
    );
    if (storedImageId <= 0) {
      _rollbackPendingImageNumber(pending);
      return null;
    }
    for (final reservation in pending.imageNumberReservations) {
      commitImageIdReservation(
        reservation.number,
        reservation.mappedImageId,
      );
    }
    onChanged?.call();
    return imageById(id);
  }

  void _rollbackPendingImageNumber(_PendingGraphicsImage pending) {
    for (final reservation in pending.imageNumberReservations) {
      rollbackImageIdReservation(
        reservation.number,
        reservation.mappedImageId,
        reservation.previousImageId,
      );
    }
  }

  /// Stores a decoded static or animated [image] and returns its new id.
  ///
  /// Returns `0` and disposes [image] when its decoded frames exceed
  /// [maxMemoryBytes].
  int storeDecodedImage(
    DecodedTerminalImage image, {
    int sourceSignature = 0,
    bool transient = false,
  }) {
    final sizeBytes = image.sizeBytes;
    if (sizeBytes > maxMemoryBytes) {
      _disposeDecodedTerminalImage(image);
      return 0;
    }
    _evictIfNeeded(sizeBytes);

    final id = _nextAnonymousImageId++;
    _images[id] = TerminalImage.fromDecoded(
      id,
      image,
      sourceSignature: sourceSignature,
      transient: transient,
    ).._lastAccess = ++_accessClock;
    _currentMemoryBytes += sizeBytes;
    return id;
  }

  /// Stores [image] using an id supplied by the Kitty graphics protocol.
  /// Returns `0` when it exceeds the memory budget.
  ///
  /// Any existing image with [id] is replaced in place. Crucially, placements,
  /// placeholders and the virtual placement that already reference [id] are
  /// preserved: Kitty Unicode placeholders are frequently written *before* the
  /// referenced image finishes decoding, so dropping them here (as a full
  /// [_dropImage] would) leaves the freshly stored image with nothing to paint
  /// over — the cells render as bare placeholder glyphs instead of the image.
  int storeImageWithId(int id, ui.Image image, {int sourceSignature = 0}) =>
      storeDecodedImageWithId(
        id,
        DecodedTerminalImage.single(image),
        sourceSignature: sourceSignature,
      );

  /// Stores a decoded static or animated [image] using a protocol-supplied id.
  ///
  /// Returns `0` and disposes [image] when its decoded frames exceed
  /// [maxMemoryBytes]. Any existing image or pending payload for [id] is
  /// preserved when admission fails.
  int storeDecodedImageWithId(
    int id,
    DecodedTerminalImage image, {
    int sourceSignature = 0,
    bool transient = false,
  }) {
    if (id <= 0) {
      return storeDecodedImage(
        image,
        sourceSignature: sourceSignature,
        transient: transient,
      );
    }

    final sizeBytes = image.sizeBytes;
    if (sizeBytes > maxMemoryBytes) {
      _disposeDecodedTerminalImage(image);
      return 0;
    }
    if ((_placementCountByImage[id] ?? 0) > 0) {
      _placementRelativeRowsDirty = true;
    }
    final pending = _pendingImages.remove(id);
    if (pending != null) {
      _pendingBytes -= pending.payload.length;
      for (final reservation in pending.imageNumberReservations) {
        commitImageIdReservation(
          reservation.number,
          reservation.mappedImageId,
        );
      }
    }
    final existing = _images.remove(id);
    if (existing != null) {
      _currentMemoryBytes -= existing.sizeBytes;
    }
    _evictIfNeeded(sizeBytes);

    _images[id] = TerminalImage.fromDecoded(
      id,
      image,
      sourceSignature: sourceSignature,
      transient: transient,
    ).._lastAccess = ++_accessClock;
    _retainedImageIds.add(id);
    _currentMemoryBytes += sizeBytes;
    if (id >= _nextImageId && id < _maxProtocolImageId) {
      _nextImageId = id + 1;
    }
    return id;
  }

  /// Whether image [id] is already stored with a matching [sourceSignature].
  ///
  /// Lets the transmit path skip re-decoding an identical image that the same
  /// id was already decoded from (e.g. a window switch replaying cached images
  /// the client still holds). A zero signature never matches.
  bool hasImageWithSignature(int id, int sourceSignature) {
    if (id <= 0 || sourceSignature == 0) {
      return false;
    }
    final existing = _images[id];
    return existing != null &&
        !existing._protocolAnimationModified &&
        existing.sourceSignature == sourceSignature;
  }

  /// Whether at least one displayed image currently needs animation ticks.
  bool get hasActiveAnimations => hasActiveAnimationsFor();

  /// Whether at least one active animation is displayed.
  ///
  /// When [imageIds] is supplied, only those images are considered. The render
  /// widget uses this to stop ticking animations outside the visible viewport.
  bool hasActiveAnimationsFor([Set<int>? imageIds]) {
    bool Function(int)? isDisplayed = imageIds?.contains;
    for (final entry in _images.entries) {
      if (!entry.value._needsAnimationTick) continue;
      isDisplayed ??= _displayedImageTest();
      if (isDisplayed(entry.key)) return true;
    }
    return false;
  }

  /// Advances displayed animations by [elapsed].
  ///
  /// Returns true when at least one current frame changed. The host renderer
  /// calls this from its ticker and repaints through [onChanged].
  bool advanceAnimations(Duration elapsed, {Set<int>? imageIds}) {
    var changed = false;
    bool Function(int)? isDisplayed = imageIds?.contains;
    for (final entry in _images.entries) {
      isDisplayed ??= _displayedImageTest();
      if (isDisplayed(entry.key) && entry.value._advance(elapsed)) {
        entry.value._lastAccess = ++_accessClock;
        changed = true;
      }
    }
    if (changed) {
      onChanged?.call();
    }
    return changed;
  }

  /// Applies Kitty `a=a` playback controls to [imageId].
  ///
  /// [currentFrame], [gapFrame], and frame numbering are one-based. A
  /// [protocolLoopCount] of `1` means infinite playback; larger values follow
  /// Kitty's `v - 1` loop-limit representation.
  bool controlAnimation(
    int imageId, {
    int? currentFrame,
    TerminalAnimationState? state,
    int? protocolLoopCount,
    int? gapFrame,
    Duration? gap,
  }) {
    final image = _images[imageId];
    if (image == null) {
      return false;
    }
    var applied = false;
    if (gapFrame != null && gap != null) {
      applied = image._setFrameDuration(gapFrame, gap) || applied;
    }
    if (currentFrame != null) {
      applied = image._setCurrentFrame(currentFrame) || applied;
    }
    if (state != null) {
      image._setAnimationState(state);
      applied = true;
    }
    if (protocolLoopCount != null && protocolLoopCount > 0) {
      image._setProtocolLoopCount(protocolLoopCount);
      applied = true;
    }
    if (applied) {
      image._lastAccess = ++_accessClock;
      onChanged?.call();
    }
    return applied;
  }

  /// Adds or edits a Kitty protocol animation frame.
  ///
  /// [x], [y], [width], and [height] describe the transmitted block in the
  /// image's original pixel coordinate space. New frames may use a prior
  /// [backgroundFrame] or an RGBA [backgroundColor]. [editFrame] composites the
  /// block onto an existing one-based frame instead.
  Future<TerminalAnimationFrameResult> addAnimationFrame(
    int imageId,
    DecodedTerminalImage frameData, {
    int x = 0,
    int y = 0,
    int width = 0,
    int height = 0,
    int backgroundFrame = 0,
    int? backgroundColor,
    bool replace = false,
    int editFrame = 0,
    Duration? gap,
  }) async {
    try {
      final image = _images[imageId];
      if (image == null || frameData.frames.isEmpty) {
        return TerminalAnimationFrameResult.imageNotFound;
      }
      final existingEditFrame =
          editFrame > 0 && editFrame <= image.frameCount ? editFrame : 0;
      if (existingEditFrame <= 0 &&
          image.frameCount >= _maxDecodedAnimationFrames) {
        return TerminalAnimationFrameResult.noSpace;
      }
      final regionWidth = width > 0 ? width : frameData.sourceWidth;
      final regionHeight = height > 0 ? height : frameData.sourceHeight;
      if (x < 0 ||
          y < 0 ||
          regionWidth <= 0 ||
          regionHeight <= 0 ||
          x + regionWidth > image.sourceWidth ||
          y + regionHeight > image.sourceHeight) {
        return TerminalAnimationFrameResult.invalidRectangle;
      }

      ui.Image? background;
      if (existingEditFrame > 0) {
        background = image.imageAtFrame(existingEditFrame);
      } else if (backgroundFrame > 0) {
        background = image.imageAtFrame(backgroundFrame);
        if (background == null) {
          return TerminalAnimationFrameResult.frameNotFound;
        }
      }

      final root = image.imageAtFrame(1);
      if (root == null) {
        return TerminalAnimationFrameResult.frameNotFound;
      }
      final newFrameBytes = root.width * root.height * 4;
      if (existingEditFrame <= 0 &&
          !_evictAdditionalMemory(
            newFrameBytes,
            protectedImageId: imageId,
          )) {
        return TerminalAnimationFrameResult.noSpace;
      }
      final composed = await _composeTerminalFrame(
        outputWidth: root.width,
        outputHeight: root.height,
        logicalWidth: image.sourceWidth,
        logicalHeight: image.sourceHeight,
        background: background,
        backgroundColor: existingEditFrame > 0 ? null : backgroundColor,
        overlay: frameData.frames.first.image,
        overlayX: x,
        overlayY: y,
        overlayWidth: regionWidth,
        overlayHeight: regionHeight,
        replace: replace,
      );
      if (composed == null) {
        return TerminalAnimationFrameResult.rasterizationFailed;
      }
      if (!identical(_images[imageId], image)) {
        // This image was never stored or exposed to a painter, so unlike
        // retained Kitty images it is safe to release immediately.
        composed.dispose();
        return TerminalAnimationFrameResult.imageNotFound;
      }

      if (existingEditFrame > 0) {
        final previous = image.imageAtFrame(existingEditFrame)!;
        final delta = composed.width * composed.height * 4 -
            previous.width * previous.height * 4;
        if (!_evictAdditionalMemory(
          math.max(0, delta),
          protectedImageId: imageId,
        )) {
          composed.dispose();
          return TerminalAnimationFrameResult.noSpace;
        }
        image._replaceFrame(existingEditFrame, composed);
        _currentMemoryBytes += delta;
        if (gap != null) {
          image._setFrameDuration(existingEditFrame, gap);
        }
        image._lastAccess = ++_accessClock;
        onChanged?.call();
        return TerminalAnimationFrameResult.success;
      }

      if (!_evictAdditionalMemory(newFrameBytes, protectedImageId: imageId)) {
        composed.dispose();
        return TerminalAnimationFrameResult.noSpace;
      }
      image._appendProtocolFrame(
        composed,
        gap ?? const Duration(milliseconds: 40),
      );
      _currentMemoryBytes += newFrameBytes;
      image._lastAccess = ++_accessClock;
      onChanged?.call();
      return TerminalAnimationFrameResult.success;
    } finally {
      _disposeDecodedTerminalImage(frameData);
    }
  }

  /// Composes a rectangle from [sourceFrame] onto [destinationFrame].
  ///
  /// Frame numbers and coordinates use Kitty's one-based frame numbers and
  /// original image pixel coordinate space.
  Future<TerminalAnimationCompositionResult> composeAnimationFrames(
    int imageId, {
    required int sourceFrame,
    required int destinationFrame,
    int sourceX = 0,
    int sourceY = 0,
    int destinationX = 0,
    int destinationY = 0,
    int width = 0,
    int height = 0,
    bool replace = false,
  }) async {
    final image = _images[imageId];
    if (image == null) {
      return TerminalAnimationCompositionResult.imageNotFound;
    }
    final source = image.imageAtFrame(sourceFrame);
    final destination = image.imageAtFrame(destinationFrame);
    if (source == null || destination == null) {
      return TerminalAnimationCompositionResult.frameNotFound;
    }
    final regionWidth = width > 0 ? width : image.sourceWidth;
    final regionHeight = height > 0 ? height : image.sourceHeight;
    if (!_rectWithinImage(
          sourceX,
          sourceY,
          regionWidth,
          regionHeight,
          image.sourceWidth,
          image.sourceHeight,
        ) ||
        !_rectWithinImage(
          destinationX,
          destinationY,
          regionWidth,
          regionHeight,
          image.sourceWidth,
          image.sourceHeight,
        )) {
      return TerminalAnimationCompositionResult.invalidRectangle;
    }
    if (sourceFrame == destinationFrame &&
        _rectanglesOverlap(
          sourceX,
          sourceY,
          destinationX,
          destinationY,
          regionWidth,
          regionHeight,
        )) {
      return TerminalAnimationCompositionResult.invalidRectangle;
    }

    final composed = await _composeTerminalFrameRegion(
      destination: destination,
      source: source,
      logicalWidth: image.sourceWidth,
      logicalHeight: image.sourceHeight,
      sourceX: sourceX,
      sourceY: sourceY,
      destinationX: destinationX,
      destinationY: destinationY,
      width: regionWidth,
      height: regionHeight,
      replace: replace,
    );
    if (composed == null) {
      return TerminalAnimationCompositionResult.rasterizationFailed;
    }
    if (!identical(_images[imageId], image)) {
      // The composed image has never been retained or painted.
      composed.dispose();
      return TerminalAnimationCompositionResult.imageNotFound;
    }

    final previousBytes = destination.width * destination.height * 4;
    final nextBytes = composed.width * composed.height * 4;
    if (!_evictAdditionalMemory(
      math.max(0, nextBytes - previousBytes),
      protectedImageId: imageId,
    )) {
      composed.dispose();
      return TerminalAnimationCompositionResult.noSpace;
    }
    image._replaceFrame(destinationFrame, composed);
    _currentMemoryBytes += nextBytes - previousBytes;
    image._lastAccess = ++_accessClock;
    onChanged?.call();
    return TerminalAnimationCompositionResult.success;
  }

  /// Tests whether an image is placed at an attached anchor or referenced by
  /// an attached placeholder (a retained image also by the low 8 or 24 bits
  /// of its id). Built once per animation tick rather than scanning every
  /// placement and placeholder for each image.
  bool Function(int imageId) _displayedImageTest() {
    final placed = <int>{
      for (final placement in _placementsByAnchor.values)
        if (placement.attached) placement.imageId,
      for (final placement in _relativePlacements.values)
        if (placement.attached) placement.imageId,
    };
    final narrow = <int>{};
    final wide = <int>{};
    for (final placeholder in _placeholdersByAnchor.values) {
      if (placeholder.attached) {
        (placeholder.imageIdBitWidth >= 24 ? wide : narrow)
            .add(placeholder.imageId);
      }
    }
    return (imageId) =>
        placed.contains(imageId) ||
        narrow.contains(imageId) ||
        wide.contains(imageId) ||
        (_retainedImageIds.contains(imageId) &&
            (wide.contains(imageId & 0xFFFFFF) ||
                narrow.contains(imageId & 0xFF)));
  }

  /// Creates a placement of [imageId] anchored at [anchor], optionally spanning
  /// [cols] x [rows] cells, with an optional source crop, cell pixel offset and
  /// z-index.
  TerminalImagePlacement placeImage(
    int imageId,
    CellAnchor anchor, {
    int cols = 0,
    int rows = 0,
    int z = 0,
    int clientPlacementId = 0,
    int srcX = 0,
    int srcY = 0,
    int srcWidth = 0,
    int srcHeight = 0,
    int xOffset = 0,
    int yOffset = 0,
  }) {
    // Kitty: a placement is uniquely identified by (image id, placement id),
    // and re-sending one with the same pair replaces the first — this is how
    // clients move or resize a displayed image without flicker (e.g. the Grok
    // CLI re-places its inline image with the same p= at a new cursor position
    // on every scroll repaint). Appending instead of replacing left a stale
    // copy behind at every scroll step. Placements without a client id (p=0)
    // always accumulate, per the spec.
    final placementId = _takePlacementIdForReplacement(
          imageId,
          clientPlacementId,
        ) ??
        _nextPlacementId++;
    final placement = TerminalImagePlacement(
      placementId: placementId,
      imageId: imageId,
      anchor: anchor,
      fallbackCol: anchor.x,
      fallbackRow: anchor.y,
      clientPlacementId: clientPlacementId,
      cols: cols,
      rows: rows,
      z: z,
      srcX: srcX,
      srcY: srcY,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      xOffset: xOffset,
      yOffset: yOffset,
    );
    _addAnchoredPlacement(placement);
    return placement;
  }

  void _addAnchoredPlacement(TerminalImagePlacement placement) {
    final anchor = placement.anchor!;
    anchor.onDispose = _handleAnchorDisposed;
    _placementsByAnchor[anchor] = placement;
    _placementsById[placement.placementId] = placement;
    _incrementPlacementImageCount(placement.imageId);
    if (!_placementRelativeRowsDirty) _indexPlacementRows(placement);
  }

  void _incrementPlacementImageCount(int imageId) {
    _placementCountByImage.update(
      imageId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  /// Removes the placement of [imageId] with client id [clientPlacementId], if
  /// any, and returns its internal id for the placement replacing it. Kitty
  /// updates such a placement in place, so the relative placements that refer
  /// to it are kept and follow the replacement.
  int? _takePlacementIdForReplacement(int imageId, int clientPlacementId) {
    if (clientPlacementId <= 0) return null;
    final existing = _placementWithClientId(imageId, clientPlacementId);
    if (existing == null) return null;
    _disposePlacement(existing, removeOrphans: false);
    return existing.placementId;
  }

  TerminalImagePlacement? _placementWithClientId(
    int imageId,
    int clientPlacementId,
  ) {
    for (final placement in _placementsById.values) {
      if (placement.imageId == imageId &&
          placement.clientPlacementId == clientPlacementId) {
        return placement;
      }
    }
    return null;
  }

  /// Places [imageId] relative to a parent placement, as a Kitty `a=p` or
  /// `a=T` command with `P=` does.
  ///
  /// The parent is the placement of [parentImageId] whose client placement id
  /// is [parentPlacementId], or its oldest placement when that is 0; a virtual
  /// (Unicode placeholder) placement of the image counts too. The new placement
  /// sits [horizontalOffset] columns and [verticalOffset] rows from the
  /// parent's top-left cell, moves with it, and is removed with it.
  ///
  /// Returns the placement, or why it was rejected, following Kitty: a missing
  /// parent, a placement that would be its own parent, a cycle, or a chain
  /// deeper than [kittyRelativePlacementDepthLimit].
  ({TerminalImagePlacement? placement, TerminalRelativePlacementError? error})
      placeRelativeImage(
    int imageId, {
    required int parentImageId,
    int parentPlacementId = 0,
    int horizontalOffset = 0,
    int verticalOffset = 0,
    int cols = 0,
    int rows = 0,
    int z = 0,
    int clientPlacementId = 0,
    int srcX = 0,
    int srcY = 0,
    int srcWidth = 0,
    int srcHeight = 0,
    int xOffset = 0,
    int yOffset = 0,
  }) {
    if (!_images.containsKey(parentImageId) &&
        !_pendingImages.containsKey(parentImageId)) {
      return (
        placement: null,
        error: TerminalRelativePlacementError.parentImageNotFound,
      );
    }
    final parent = _findParentPlacement(parentImageId, parentPlacementId);
    if (parent == null) {
      return (
        placement: null,
        error: TerminalRelativePlacementError.parentPlacementNotFound,
      );
    }
    final replaced = clientPlacementId > 0
        ? _placementWithClientId(imageId, clientPlacementId)
        : null;
    final chainError = _relativeChainError(parent, replaced?.placementId);
    if (chainError != null) {
      return (placement: null, error: chainError);
    }
    final placementId = _takePlacementIdForReplacement(
          imageId,
          clientPlacementId,
        ) ??
        _nextPlacementId++;
    final placement = TerminalImagePlacement._relative(
      placementId: placementId,
      imageId: imageId,
      parent: parent,
      horizontalOffset: horizontalOffset,
      verticalOffset: verticalOffset,
      resolvePosition: _resolveRelativePosition,
      clientPlacementId: clientPlacementId,
      cols: cols,
      rows: rows,
      z: z,
      srcX: srcX,
      srcY: srcY,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      xOffset: xOffset,
      yOffset: yOffset,
    );
    _relativePlacements[placementId] = placement;
    _placementsById[placementId] = placement;
    _incrementPlacementImageCount(imageId);
    return (placement: placement, error: null);
  }

  _TerminalPlacementParent? _findParentPlacement(
    int parentImageId,
    int parentPlacementId,
  ) {
    TerminalImagePlacement? oldest;
    for (final placement in _placementsById.values) {
      if (placement.imageId != parentImageId) continue;
      if (parentPlacementId > 0) {
        if (placement.clientPlacementId == parentPlacementId) {
          return _TerminalPlacementParent.placement(
            parentImageId,
            placement.placementId,
          );
        }
      } else if (oldest == null || placement.placementId < oldest.placementId) {
        oldest = placement;
      }
    }
    if (oldest != null) {
      return _TerminalPlacementParent.placement(
        parentImageId,
        oldest.placementId,
      );
    }
    final virtual = _virtualPlacements[parentImageId];
    if (virtual != null &&
        (parentPlacementId <= 0 ||
            virtual.clientPlacementId == parentPlacementId)) {
      return _TerminalPlacementParent.virtual(parentImageId);
    }
    return null;
  }

  /// Validates the chain a placement would get from [parent]: it must not be
  /// its own parent ([replacedPlacementId] is the placement it replaces, if
  /// any), must not loop back to itself, and must stay within the depth limit.
  TerminalRelativePlacementError? _relativeChainError(
    _TerminalPlacementParent parent,
    int? replacedPlacementId,
  ) {
    if (replacedPlacementId != null &&
        parent.placementId == replacedPlacementId) {
      return TerminalRelativePlacementError.selfParent;
    }
    var link = parent;
    // Counts parent links, starting with the one being created.
    var depth = 1;
    while (true) {
      final id = link.placementId;
      if (id == null) return null; // a virtual placement is a chain root
      if (id == replacedPlacementId) {
        return TerminalRelativePlacementError.cycle;
      }
      final ancestor = _placementsById[id];
      if (ancestor == null) {
        return TerminalRelativePlacementError.parentPlacementNotFound;
      }
      final next = ancestor._parent;
      if (next == null) return null; // an anchored placement is a chain root
      if (depth >= kittyRelativePlacementDepthLimit) {
        return TerminalRelativePlacementError.tooDeep;
      }
      depth += 1;
      link = next;
    }
  }

  /// Resolves a relative placement to the cell its parent chain puts it at, or
  /// null when the chain is broken, too deep, or ends at a virtual placement
  /// with no placeholder cells in the buffer.
  ({int col, int row})? _resolveRelativePosition(
    TerminalImagePlacement placement,
  ) {
    var col = placement.horizontalOffset;
    var row = placement.verticalOffset;
    var link = placement._parent;
    var depth = 1;
    while (link != null) {
      final id = link.placementId;
      if (id == null) {
        final origin = _virtualPlacementOrigin(link.imageId);
        if (origin == null) return null;
        return (col: origin.col + col, row: origin.row + row);
      }
      final parent = _placementsById[id];
      if (parent == null) return null;
      final anchor = parent.anchor;
      if (anchor != null) {
        if (!anchor.attached) return null;
        return (col: anchor.x + col, row: anchor.y + row);
      }
      if (depth >= kittyRelativePlacementDepthLimit) return null;
      depth += 1;
      col += parent.horizontalOffset;
      row += parent.verticalOffset;
      link = parent._parent;
    }
    return null;
  }

  /// Top-left of a virtual placement: as Kitty specifies, the smallest column
  /// and the smallest row of the placeholder cells that show [imageId].
  ({int col, int row})? _virtualPlacementOrigin(int imageId) {
    int? minCol;
    int? minRow;
    void include(TerminalImagePlaceholder placeholder) {
      final col = placeholder.cellCol;
      final row = placeholder.cellRow;
      if (minCol == null || col < minCol!) minCol = col;
      if (minRow == null || row < minRow!) minRow = row;
    }

    for (final placeholder in _placeholdersByAnchor.values) {
      if (placeholder.attached && placeholder.imageId == imageId) {
        include(placeholder);
      }
    }
    if (minCol == null) {
      // A placeholder whose color carries only the low bits of the id.
      for (final placeholder in _placeholdersByAnchor.values) {
        final mask = placeholder.imageIdBitWidth >= 24 ? 0xFFFFFF : 0xFF;
        if (placeholder.attached &&
            placeholder.imageId == (imageId & mask) &&
            placeholder.imageId != imageId) {
          include(placeholder);
        }
      }
    }
    if (minCol == null || minRow == null) return null;
    return (col: minCol!, row: minRow!);
  }

  /// Removes relative placements whose parent is gone, repeatedly, so a whole
  /// orphaned subtree goes: a relative placement lives only as long as its
  /// parent. Call after anything that removes a placement or a virtual one.
  void _removeOrphanedRelativePlacements() {
    var removed = true;
    while (removed && _relativePlacements.isNotEmpty) {
      removed = false;
      for (final placement in _relativePlacements.values.toList()) {
        final parent = placement._parent!;
        final id = parent.placementId;
        final exists = id == null
            ? _virtualPlacements.containsKey(parent.imageId)
            : _placementsById.containsKey(id);
        if (!exists) {
          _disposePlacement(placement, removeOrphans: false);
          removed = true;
        }
      }
    }
  }

  /// Records a virtual placement prototype for [imageId].
  void setVirtualPlacement(
    int imageId, {
    required int cols,
    required int rows,
    int clientPlacementId = 0,
  }) {
    if (imageId <= 0 || cols <= 0 || rows <= 0) {
      return;
    }
    _virtualPlacements[imageId] = TerminalImageVirtualPlacement(
      cols: cols,
      rows: rows,
      clientPlacementId: clientPlacementId,
    );
    _retainedImageIds.add(imageId);
  }

  /// Adds a Kitty Unicode-placeholder cell.
  TerminalImagePlaceholder addPlaceholder({
    required int imageId,
    required int imageIdBitWidth,
    required CellAnchor anchor,
    required int row,
    required int col,
  }) {
    final grid = _placeholderGridFor(imageId, imageIdBitWidth, row, col)
      ..add(row, col);
    final placeholder = TerminalImagePlaceholder._(
      imageId: imageId,
      imageIdBitWidth: imageIdBitWidth,
      anchor: anchor,
      row: row,
      col: col,
      sequence: _nextPlaceholderSequence++,
      grid: grid,
      rebindGrid: _rebindPlaceholderGrid,
    );
    anchor.onDispose = _handleAnchorDisposed;
    _placeholdersByAnchor[anchor] = placeholder;
    return placeholder;
  }

  /// Drops placeholder cells whose anchors have been evicted.
  bool pruneDetachedPlaceholders() {
    final detached = <TerminalImagePlaceholder>[
      for (final placeholder in _placeholdersByAnchor.values)
        if (!placeholder.attached) placeholder,
    ];
    for (final placeholder in detached) {
      _disposePlaceholder(placeholder);
    }
    return detached.isNotEmpty;
  }

  /// Removes placements anchored within rows `[firstRow, lastRow]` (inclusive),
  /// or whose anchor has detached. Used when scrollback rows are evicted.
  ///
  /// The decoded [ui.Image]s are intentionally *not* disposed here. A placement
  /// that was painted in a still-in-flight frame would otherwise have its image
  /// freed out from under the raster thread, which crashes the engine ("Cannot
  /// draw a disposed image"). Dropping the references is enough: any picture
  /// that already drew the image keeps its own reference alive, and the image is
  /// reclaimed by the GC finalizer once nothing can paint it.
  void removePlacementsInRows(int firstRow, int lastRow) {
    final removed = _removePlacementsWhere(
      (placement) =>
          // A relative placement whose virtual parent shows no placeholder
          // cells is unplaced, not gone; it goes with its parent instead.
          (!placement.isRelative && !placement.attached) ||
          (placement.attached &&
              _placementIntersectsRows(placement, firstRow, lastRow)),
    );
    if (removed.isNotEmpty) {
      _generation++;
    }
    pruneDetachedPlaceholders();
    _dropUnreferencedImages();
  }

  /// Deletes image placements in response to a Kitty graphics delete command
  /// (`a=d`), following Kitty's reference implementation.
  ///
  /// [what] is the `d=` selector; Kitty's default when `d=` is omitted is `a`.
  /// Lowercase selectors remove the matching placements only (an image without
  /// a protocol id that loses its last placement goes too, since nothing could
  /// place it again). Uppercase selectors also free the image data of every
  /// image that had a matching placement and has none left; `I` and `R` free a
  /// matching image that has no placements at all as well.
  ///
  /// * `a`: placements on the visible screen, rows from [firstVisibleRow]
  ///   down; placements wholly in the scrollback stay.
  /// * `i`: placements of [imageId], only the one with client id
  ///   [placementId] when given. Its virtual (Unicode placeholder) placement
  ///   counts as one of them.
  /// * `r`: placements of images whose id is in [rangeStart]..[rangeEnd]; an
  ///   empty range matches nothing.
  /// * `c`, `p`, `q`: placements covering the cursor cell
  ///   ([cursorCol]/[cursorRow]) or [cellCol]/[cellRow]; `q` also needs
  ///   z-index [zIndex].
  /// * `x`, `y`, `z`: placements covering column [cellCol], row [cellRow], or
  ///   with z-index [zIndex].
  ///
  /// Other selectors (animation frames) delete nothing. Relative placements
  /// match at their resolved position, and every placement removed takes its
  /// relative placements with it.
  ///
  /// Returns true if anything was removed.
  bool deletePlacements({
    String what = 'a',
    int? imageId,
    int? placementId,
    int? cursorCol,
    int? cursorRow,
    int? cellCol,
    int? cellRow,
    int? zIndex,
    int? rangeStart,
    int? rangeEnd,
    int firstVisibleRow = 0,
  }) {
    final selector = what.isEmpty ? 'a' : what;
    final mode = selector.toLowerCase();
    final freeImages = selector != mode; // an uppercase selector frees data

    bool atCell(TerminalImagePlacement placement, int? col, int? row) =>
        col != null &&
        row != null &&
        placement.attached &&
        _placementIntersectsRows(placement, row, row) &&
        _placementIntersectsCols(placement, col, col);

    bool imageMatches(int id) => switch (mode) {
          'i' => id == imageId,
          'r' => rangeStart != null &&
              rangeEnd != null &&
              id >= rangeStart &&
              id <= rangeEnd,
          _ => false,
        };

    bool matches(TerminalImagePlacement placement) {
      switch (mode) {
        case 'a':
          return placement.attached &&
              _placementIntersectsRows(
                placement,
                firstVisibleRow,
                _maxPlacementRow,
              );
        case 'i':
          return imageMatches(placement.imageId) &&
              (placementId == null ||
                  placementId <= 0 ||
                  placement.clientPlacementId == placementId);
        case 'r':
          return imageMatches(placement.imageId);
        case 'c':
          return atCell(placement, cursorCol, cursorRow);
        case 'p':
          return atCell(placement, cellCol, cellRow);
        case 'q':
          return placement.z == zIndex && atCell(placement, cellCol, cellRow);
        case 'x':
          return cellCol != null &&
              placement.attached &&
              _placementIntersectsCols(placement, cellCol, cellCol);
        case 'y':
          return cellRow != null &&
              placement.attached &&
              _placementIntersectsRows(placement, cellRow, cellRow);
        case 'z':
          return zIndex != null && placement.z == zIndex;
        default:
          // Animation frame deletes (`f`) are not supported: delete nothing
          // rather than risk wiping live images.
          return false;
      }
    }

    final matchedImageIds = <int>{};
    var changed = false;
    if (mode == 'i' || mode == 'r') {
      // Kitty's id selectors cover the image's virtual placement too.
      for (final entry in _virtualPlacements.entries.toList()) {
        if (imageMatches(entry.key) &&
            (mode == 'r' ||
                placementId == null ||
                placementId <= 0 ||
                entry.value.clientPlacementId == placementId)) {
          _virtualPlacements.remove(entry.key);
          matchedImageIds.add(entry.key);
          changed = true;
        }
      }
    }
    final removed = _removePlacementsWhere(matches);
    if (changed) _removeOrphanedRelativePlacements();
    changed = changed || removed.isNotEmpty;
    matchedImageIds.addAll(removed.map((placement) => placement.imageId));

    if (freeImages) {
      final candidates = <int>{...matchedImageIds};
      if ((mode == 'i' || mode == 'r') &&
          (mode == 'r' || placementId == null || placementId <= 0)) {
        // Kitty frees a matching image that has no placement at all.
        candidates.addAll(_images.keys.where(imageMatches));
        candidates.addAll(_pendingImages.keys.where(imageMatches));
      }
      for (final id in candidates) {
        if (!_imageHasPlacements(id) &&
            (_images.containsKey(id) || _pendingImages.containsKey(id))) {
          _dropImage(id);
          changed = true;
        }
      }
      if (mode == 'i' &&
          imageId != null &&
          (placementId == null || placementId <= 0) &&
          !_images.containsKey(imageId) &&
          !_pendingImages.containsKey(imageId) &&
          _placeholdersByAnchor.values.any((p) => p.imageId == imageId)) {
        // Freed data must not be asked for again by placeholder cells that
        // still name it.
        _dropImage(imageId);
        changed = true;
      }
    } else if (removed.isNotEmpty) {
      _dropUnreferencedImages();
    }

    // No generation bump: a delete runs in its image's queue or as a barrier
    // (Terminal), so nothing parsed before it is still in flight, and a bump
    // would drop the placements parsed after it, such as the next window's
    // images behind a deferred delete.
    return changed;
  }

  /// Whether [imageId] still has a physical, relative or virtual placement.
  bool _imageHasPlacements(int imageId) =>
      (_placementCountByImage[imageId] ?? 0) > 0 ||
      _virtualPlacements.containsKey(imageId);

  /// A row past any placement, for row ranges open at the bottom.
  static const _maxPlacementRow = 1 << 40;

  /// Removes every physical placement and drops placement-only images. Images
  /// with protocol ids are retained so Unicode-placeholder redraws can reuse
  /// them after a clear.
  void clear() {
    _generation++;
    _clears++;
    // Placements still queued behind a decode lose their anchor cells, so
    // they cannot land on the cleared screen. A screen erased in place, as a
    // full reset erases the main screen, keeps the rows they were anchored to.
    for (final anchor in _pendingPlacementAnchors.toList()) {
      anchor.dispose();
    }
    _pendingPlacementAnchors.clear();
    for (final placement in _placementsById.values.toList()) {
      _disposePlacement(placement, removeOrphans: false);
    }
    for (final placeholder in _placeholdersByAnchor.values.toList()) {
      _disposePlaceholder(placeholder);
    }
    _placementsByAnchor.clear();
    _relativePlacements.clear();
    _placementsById.clear();
    _placeholdersByAnchor.clear();
    _placeholderGrids.clear();
    for (final id in _images.keys.toList()) {
      if (!_retainedImageIds.contains(id)) {
        _dropImage(id);
      }
    }
    // Keep virtual placements for images that survive the clear (retained
    // decoded images and not-yet-decoded pending ones). A virtual placement
    // records how a retained image maps onto Unicode-placeholder cells
    // (its cell columns/rows), and a placeholder-protocol app such as the
    // Copilot CLI redraws only the placeholder cells after a clear/reattach —
    // it never re-transmits the image or its virtual placement. Entering the
    // alternate screen (`CSI ? 1049 h`, part of the MonkeyMux reattach replay)
    // calls clear(); wiping the virtual placements here left the painter to
    // guess the image grid from the visible cells and mis-slice it. Dropped
    // images already had their virtual placement removed by [_dropImage].
    _virtualPlacements.removeWhere(
      (id, _) =>
          !_retainedImageIds.contains(id) && !_pendingImages.containsKey(id),
    );
  }

  /// Drops stored images that no longer have a placement referencing them.
  ///
  /// Retained protocol-id images (Unicode-placeholder backing) and images still
  /// referenced by a placement or placeholder cell are kept.
  void pruneUnreferencedImages() => _dropUnreferencedImages();

  /// Drops stored images that no longer have a placement referencing them.
  void _dropUnreferencedImages() {
    if (_images.isEmpty) return;
    pruneDetachedPlaceholders();
    final referenced = {
      ..._placementsByAnchor.values.map((p) => p.imageId),
      ..._placeholdersByAnchor.values.map((p) => p.imageId),
    };
    for (final id in _images.keys.toList()) {
      if (!referenced.contains(id) && !_retainedImageIds.contains(id)) {
        _dropImage(id);
      }
    }
  }

  bool _placementIntersectsRows(
    TerminalImagePlacement placement,
    int firstRow,
    int lastRow,
  ) {
    final range = _placementRelativeCellRange(placement);
    final placementFirst = placement.row + range.firstRow;
    final placementLast = placement.row + range.lastRow;
    return placementFirst <= lastRow && placementLast >= firstRow;
  }

  bool _placementIntersectsCols(
    TerminalImagePlacement placement,
    int firstCol,
    int lastCol,
  ) {
    final range = _placementRelativeCellRange(placement);
    final placementFirst = placement.col + range.firstCol;
    final placementLast = placement.col + range.lastCol;
    return placementFirst <= lastCol && placementLast >= firstCol;
  }

  /// [column] overrides the placement's own column, for a placement whose
  /// anchor is detached while it moves.
  ({int firstCol, int lastCol, int firstRow, int lastRow})
      _placementRelativeCellRange(
    TerminalImagePlacement placement, {
    int? column,
  }) {
    final size = _placementDestinationSize(placement, column: column);
    final cellWidth = _cellPixelWidth > 0 ? _cellPixelWidth : 10.0;
    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    final xOffset = placement.cellXOffset(cellWidth);
    final yOffset = placement.cellYOffset(cellHeight);
    final lastCol = ((xOffset + size.width) / cellWidth).ceil() - 1;
    final lastRow = ((yOffset + size.height) / cellHeight).ceil() - 1;
    return (
      firstCol: 0,
      lastCol: math.max(0, lastCol),
      firstRow: 0,
      lastRow: math.max(0, lastRow),
    );
  }

  ({int first, int last}) _placementCandidateRelativeRows(
    TerminalImagePlacement placement,
  ) {
    final size = _placementDestinationSize(
      placement,
      maximizeNaturalWidth: true,
    );
    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    final yOffset = placement.cellYOffset(cellHeight);
    final last = ((yOffset + size.height) / cellHeight).ceil() - 1;
    return (first: 0, last: math.max(0, last));
  }

  ({double width, double height}) _placementDestinationSize(
    TerminalImagePlacement placement, {
    bool maximizeNaturalWidth = false,
    int? column,
  }) {
    final cellWidth = _cellPixelWidth > 0 ? _cellPixelWidth : 10.0;
    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    final source = placement.cols > 0 && placement.rows > 0
        ? null
        : _placementSourceSize(placement);
    return terminalImagePlacementSize(
      placement,
      sourceWidth: source?.width ?? 0,
      sourceHeight: source?.height ?? 0,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      availableColumns: maximizeNaturalWidth
          ? math.max(1, _viewportColumns)
          : math.max(1, _viewportColumns - (column ?? placement.col)),
    );
  }

  ({double width, double height})? _placementSourceSize(
    TerminalImagePlacement placement,
  ) {
    final geometry = imageGeometry(placement.imageId);
    if (geometry == null) {
      return null;
    }
    final sourceWidth = geometry.sourceWidth;
    final sourceHeight = geometry.sourceHeight;

    final left = placement.srcX.clamp(0, sourceWidth).toDouble();
    final top = placement.srcY.clamp(0, sourceHeight).toDouble();
    final availableWidth = sourceWidth - left;
    final availableHeight = sourceHeight - top;
    final logicalWidth = (placement.srcWidth > 0
            ? math.min(placement.srcWidth.toDouble(), availableWidth)
            : availableWidth)
        .toDouble();
    final logicalHeight = (placement.srcHeight > 0
            ? math.min(placement.srcHeight.toDouble(), availableHeight)
            : availableHeight)
        .toDouble();
    if (logicalWidth <= 0 || logicalHeight <= 0) {
      return null;
    }

    // In the kept pixels, as the painter sizes it.
    return (
      width: logicalWidth * geometry.width / sourceWidth,
      height: logicalHeight * geometry.height / sourceHeight,
    );
  }

  void _evictIfNeeded(int requiredBytes) {
    if (_images.isEmpty) return;

    final highWaterMemory = (maxMemoryBytes * 0.7).toInt();
    if (_currentMemoryBytes + requiredBytes <= highWaterMemory &&
        _images.length < maxImageCount) {
      return;
    }

    final targetMemory = (maxMemoryBytes * 0.5).toInt();
    while (_images.isNotEmpty &&
        (_currentMemoryBytes + requiredBytes > targetMemory ||
            _images.length >= maxImageCount)) {
      _dropImage(_imageEvictionCandidate()!);
    }
  }

  /// The decoded image to evict first: by [_evictionRank], then least recently
  /// used. Never [protectedImageId].
  int? _imageEvictionCandidate({int? protectedImageId}) {
    int? best;
    var bestRank = 0;
    var bestAccess = 0;
    for (final entry in _images.entries) {
      if (entry.key == protectedImageId) continue;
      final rank = _evictionRank(entry.key, transient: entry.value.transient);
      final access = entry.value._lastAccess;
      if (best == null ||
          rank < bestRank ||
          (rank == bestRank && access < bestAccess)) {
        best = entry.key;
        bestRank = rank;
        bestAccess = access;
      }
    }
    return best;
  }

  bool _evictAdditionalMemory(
    int requiredBytes, {
    required int protectedImageId,
  }) {
    if (requiredBytes <= 0) {
      return true;
    }
    final protectedBytes = _images[protectedImageId]?.sizeBytes ?? 0;
    if (protectedBytes + requiredBytes > maxMemoryBytes) {
      return false;
    }
    final highWaterMemory = (maxMemoryBytes * 0.7).toInt();
    if (_currentMemoryBytes + requiredBytes <= highWaterMemory) {
      return true;
    }

    final targetMemory = (maxMemoryBytes * 0.5).toInt();
    while (_images.length > 1 &&
        _currentMemoryBytes + requiredBytes > targetMemory) {
      final victim = _imageEvictionCandidate(
        protectedImageId: protectedImageId,
      );
      if (victim == null) {
        break;
      }
      _dropImage(victim);
    }
    return _currentMemoryBytes + requiredBytes <= maxMemoryBytes;
  }

  void _dropImage(int imageId) {
    final image = _images.remove(imageId);
    if (image != null) {
      _currentMemoryBytes -= image.sizeBytes;
    }
    final pending = _pendingImages.remove(imageId);
    if (pending != null) {
      _pendingBytes -= pending.payload.length;
      _rollbackPendingImageNumber(pending);
    }
    _retainedImageIds.remove(imageId);
    _pendingAnimationMutations.remove(imageId);
    _virtualPlacements.remove(imageId);
    final removedNumbers = _imageNumberToId.entries
        .where((entry) => entry.value == imageId)
        .map((entry) => entry.key)
        .toList();
    for (final number in removedNumbers) {
      _imageNumberToId.remove(number);
      _imageNumberLastAccess.remove(number);
      _failedImageNumberReservations.remove(number);
      _activeImageNumberReservations.remove(number);
    }
    _removePlacementsWhere((placement) => placement.imageId == imageId);
    _removeOrphanedRelativePlacements();
    final imagePlaceholders = <TerminalImagePlaceholder>[
      for (final placeholder in _placeholdersByAnchor.values)
        if (placeholder.imageId == imageId) placeholder,
    ];
    for (final placeholder in imagePlaceholders) {
      _disposePlaceholder(placeholder);
    }
    _placeholderGrids.removeWhere((key, _) => key.imageId == imageId);
  }

  _TerminalImagePlaceholderGrid _placeholderGridFor(
    int imageId,
    int bitWidth,
    int row,
    int col,
  ) =>
      _placeholderGrids.putIfAbsent(
        (imageId: imageId, bitWidth: bitWidth),
        () => _TerminalImagePlaceholderGrid(imageId, bitWidth),
      );

  _TerminalImagePlaceholderGrid _rebindPlaceholderGrid(
    _TerminalImagePlaceholderGrid current,
    int oldRow,
    int oldCol,
    int imageId,
    int bitWidth,
    int row,
    int col,
  ) {
    final next = _placeholderGridFor(imageId, bitWidth, row, col);
    current.remove(oldRow, oldCol);
    next.add(row, col);
    _removePlaceholderGridIfEmpty(current);
    return next;
  }

  void _releasePlaceholderGrid(
    _TerminalImagePlaceholderGrid grid,
    int row,
    int col,
  ) {
    grid.remove(row, col);
    _removePlaceholderGridIfEmpty(grid);
  }

  void _removePlaceholderGridIfEmpty(_TerminalImagePlaceholderGrid grid) {
    if (grid.references > 0) return;
    final key = (imageId: grid.imageId, bitWidth: grid.bitWidth);
    if (identical(_placeholderGrids[key], grid)) {
      _placeholderGrids.remove(key);
    }
  }

  /// Removes every placement matching [predicate], then the relative
  /// placements orphaned by that. Returns the matched placements.
  List<TerminalImagePlacement> _removePlacementsWhere(
    bool Function(TerminalImagePlacement placement) predicate,
  ) {
    final removed = <TerminalImagePlacement>[
      for (final placement in _placementsByAnchor.values)
        if (predicate(placement)) placement,
      for (final placement in _relativePlacements.values)
        if (predicate(placement)) placement,
    ];
    for (final placement in removed) {
      _disposePlacement(placement, removeOrphans: false);
    }
    if (removed.isNotEmpty) _removeOrphanedRelativePlacements();
    return removed;
  }

  void _disposePlacement(
    TerminalImagePlacement placement, {
    bool removeOrphans = true,
  }) {
    if (!identical(_placementsById[placement.placementId], placement)) {
      return; // already removed, e.g. as an orphan of an earlier removal
    }
    _placementsById.remove(placement.placementId);
    _decrementPlacementImageCount(placement.imageId);
    final anchor = placement.anchor;
    if (anchor == null) {
      _relativePlacements.remove(placement.placementId);
    } else {
      _placementsByAnchor.remove(anchor);
      _unindexPlacementRows(anchor);
      anchor.onDispose = null;
      placement.dispose();
    }
    if (removeOrphans) _removeOrphanedRelativePlacements();
  }

  void _decrementPlacementImageCount(int imageId) {
    final count = _placementCountByImage[imageId];
    if (count == null || count <= 1) {
      _placementCountByImage.remove(imageId);
    } else {
      _placementCountByImage[imageId] = count - 1;
    }
  }

  void _handleAnchorDisposed(CellAnchor anchor) {
    final placement = _placementsByAnchor.remove(anchor);
    if (placement != null) {
      _unindexPlacementRows(anchor);
      _decrementPlacementImageCount(placement.imageId);
      if (identical(_placementsById[placement.placementId], placement)) {
        _placementsById.remove(placement.placementId);
      }
      _removeOrphanedRelativePlacements();
    }
    final placeholder = _placeholdersByAnchor.remove(anchor);
    if (placeholder != null) {
      _releasePlaceholderGrid(
        placeholder._grid,
        placeholder.row,
        placeholder.col,
      );
    }
    _pendingPlacementAnchors.remove(anchor);
  }

  void _disposePlaceholder(TerminalImagePlaceholder placeholder) {
    _placeholdersByAnchor.remove(placeholder.anchor);
    placeholder.anchor.onDispose = null;
    _releasePlaceholderGrid(
      placeholder._grid,
      placeholder.row,
      placeholder.col,
    );
    placeholder.dispose();
  }
}

/// Computes a cheap, stable signature of an image payload for dedup and for the
/// window-switch replay skip protocol.
///
/// Used to skip re-decoding an identical image (same id, same bytes) that a
/// window switch replays, and — reported to the MonkeyMux server — to let the
/// server omit re-transmitting images the client already holds. Not
/// cryptographic: a collision merely causes a redundant decode (or, for the skip
/// protocol, a rare re-send), never corruption.
///
/// FNV-1a over 32 bits (so it stays within a Dart small-int and matches a Go
/// `uint32` exactly, with no signed-shift ambiguity across languages), mixing
/// the exact length plus an evenly-spaced sample of bytes (<= ~4096) rather than
/// every byte to stay fast on very large payloads. The server computes the same
/// hash over the base64-decoded transmission payload, so both sides must keep
/// the algorithm identical. Returns a non-zero value for non-empty input.
int terminalGraphicsSourceSignature(Uint8List bytes) {
  if (bytes.isEmpty) {
    return 0;
  }
  const fnvOffset = 0x811c9dc5;
  const fnvPrime = 0x01000193;
  const mask = 0xFFFFFFFF;
  var hash = fnvOffset;
  // Mix the exact length (little-endian bytes) so payloads that share a sample
  // but differ in length still diverge.
  var length = bytes.length;
  for (var i = 0; i < 4; i++) {
    hash = ((hash ^ (length & 0xFF)) * fnvPrime) & mask;
    length >>= 8;
  }
  final step = bytes.length <= 4096 ? 1 : bytes.length ~/ 4096;
  for (var i = 0; i < bytes.length; i += step) {
    hash = ((hash ^ bytes[i]) * fnvPrime) & mask;
  }
  return hash == 0 ? 1 : hash;
}

bool _rectWithinImage(
  int x,
  int y,
  int width,
  int height,
  int imageWidth,
  int imageHeight,
) =>
    x >= 0 &&
    y >= 0 &&
    width > 0 &&
    height > 0 &&
    x + width <= imageWidth &&
    y + height <= imageHeight;

bool _rectanglesOverlap(
  int sourceX,
  int sourceY,
  int destinationX,
  int destinationY,
  int width,
  int height,
) =>
    math.max(sourceX, destinationX) <
        math.min(sourceX + width, destinationX + width) &&
    math.max(sourceY, destinationY) <
        math.min(sourceY + height, destinationY + height);

ui.Rect _scaledTerminalRect(
  int x,
  int y,
  int width,
  int height, {
  required int logicalWidth,
  required int logicalHeight,
  required int pixelWidth,
  required int pixelHeight,
}) {
  final scaleX = pixelWidth / logicalWidth;
  final scaleY = pixelHeight / logicalHeight;
  return ui.Rect.fromLTWH(
    x * scaleX,
    y * scaleY,
    width * scaleX,
    height * scaleY,
  );
}

ui.Color _colorFromRgba(int rgba) => ui.Color.fromARGB(
      rgba & 0xFF,
      (rgba >> 24) & 0xFF,
      (rgba >> 16) & 0xFF,
      (rgba >> 8) & 0xFF,
    );

Future<ui.Image?> _composeTerminalFrame({
  required int outputWidth,
  required int outputHeight,
  required int logicalWidth,
  required int logicalHeight,
  required ui.Image? background,
  required int? backgroundColor,
  required ui.Image overlay,
  required int overlayX,
  required int overlayY,
  required int overlayWidth,
  required int overlayHeight,
  required bool replace,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (background != null) {
    canvas.drawImageRect(
      background,
      ui.Rect.fromLTWH(
        0,
        0,
        background.width.toDouble(),
        background.height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
      ui.Paint()..blendMode = ui.BlendMode.src,
    );
  } else if (backgroundColor != null) {
    canvas.drawColor(_colorFromRgba(backgroundColor), ui.BlendMode.src);
  }
  canvas.drawImageRect(
    overlay,
    ui.Rect.fromLTWH(0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
    _scaledTerminalRect(
      overlayX,
      overlayY,
      overlayWidth,
      overlayHeight,
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      pixelWidth: outputWidth,
      pixelHeight: outputHeight,
    ),
    ui.Paint()
      ..blendMode = replace ? ui.BlendMode.src : ui.BlendMode.srcOver
      ..filterQuality = ui.FilterQuality.medium,
  );
  return _rasterizeTerminalPicture(recorder, outputWidth, outputHeight);
}

Future<ui.Image?> _composeTerminalFrameRegion({
  required ui.Image destination,
  required ui.Image source,
  required int logicalWidth,
  required int logicalHeight,
  required int sourceX,
  required int sourceY,
  required int destinationX,
  required int destinationY,
  required int width,
  required int height,
  required bool replace,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas
    ..drawImageRect(
      destination,
      ui.Rect.fromLTWH(
        0,
        0,
        destination.width.toDouble(),
        destination.height.toDouble(),
      ),
      ui.Rect.fromLTWH(
        0,
        0,
        destination.width.toDouble(),
        destination.height.toDouble(),
      ),
      ui.Paint()..blendMode = ui.BlendMode.src,
    )
    ..drawImageRect(
      source,
      _scaledTerminalRect(
        sourceX,
        sourceY,
        width,
        height,
        logicalWidth: logicalWidth,
        logicalHeight: logicalHeight,
        pixelWidth: source.width,
        pixelHeight: source.height,
      ),
      _scaledTerminalRect(
        destinationX,
        destinationY,
        width,
        height,
        logicalWidth: logicalWidth,
        logicalHeight: logicalHeight,
        pixelWidth: destination.width,
        pixelHeight: destination.height,
      ),
      ui.Paint()
        ..blendMode = replace ? ui.BlendMode.src : ui.BlendMode.srcOver
        ..filterQuality = ui.FilterQuality.medium,
    );
  return _rasterizeTerminalPicture(
    recorder,
    destination.width,
    destination.height,
  );
}

Future<ui.Image?> _rasterizeTerminalPicture(
  ui.PictureRecorder recorder,
  int width,
  int height,
) async {
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } catch (_) {
    return null;
  } finally {
    picture.dispose();
  }
}

void _disposeDecodedTerminalImage(DecodedTerminalImage decoded) {
  for (final frame in decoded.frames) {
    frame.image.dispose();
  }
}

/// Maximum width/height a decoded terminal image is kept at. Source images
/// larger than this on their longest side are downscaled during decode, with
/// aspect ratio preserved. A terminal renders images into a small cell grid, so
/// full-resolution screenshots (often several megapixels) waste large amounts of
/// decoded RGBA memory and raster bandwidth; on mobile, decoding many at once
/// can exhaust memory and crash. 1280px keeps images crisp at terminal sizes
/// while bounding each decode to ~6.5 MB.
const _maxDecodedImageDimension = 1280;

/// Format standing for any encoded container in [terminalDecodedImageSize].
const _encodedImageFormat = 100;

/// The size the decoder keeps an image of [width] x [height] source pixels
/// in Kitty [format] at: raw pixels (`f=24`, `f=32`) as they are, an encoded
/// image scaled down to [_maxDecodedImageDimension] on its longest side.
/// Placement geometry uses it before the decode as well as after, so the
/// cursor, row lookups and painting all size an image the same way.
({int width, int height}) terminalDecodedImageSize(
  int width,
  int height, {
  required int format,
}) {
  final longest = math.max(width, height);
  if (format == 24 ||
      format == 32 ||
      longest <= _maxDecodedImageDimension ||
      width <= 0 ||
      height <= 0) {
    return (width: width, height: height);
  }
  final scale = _maxDecodedImageDimension / longest;
  return (
    width: (width * scale).round().clamp(1, _maxDecodedImageDimension),
    height: (height * scale).round().clamp(1, _maxDecodedImageDimension),
  );
}

/// Maximum number of frames decoded from one encoded animation.
const _maxDecodedAnimationFrames = 256;

/// Maximum approximate RGBA bytes decoded for one animation before storage.
const _maxDecodedAnimationBytes = 100 * 1024 * 1024;

/// Minimum delay for encoded frames whose codec reports zero.
///
/// Flutter's own animated-image scheduler treats a zero duration as immediately
/// eligible for the next frame. A small positive floor preserves that behavior
/// without making a fully zero-delay GIF churn through multiple frames per
/// display tick.
const _minimumEncodedFrameDuration = Duration(milliseconds: 10);

/// Decodes Kitty graphics payload [bytes] into all available frames.
///
/// Uses Flutter's built-in codecs for `f=100`/`f=98` (PNG/JPEG/GIF/APNG) and
/// [ui.decodeImageFromPixels] for raw pixels (`f=32` RGBA, `f=24` RGB).
/// Encoded images larger than [_maxDecodedImageDimension] are downscaled during
/// decode to bound memory. Frame count and aggregate decoded bytes are capped to
/// prevent a compact hostile animation from exhausting memory.
Future<DecodedTerminalImage?> decodeTerminalImageSequence(
  Uint8List bytes, {
  int format = 100,
  int width = 0,
  int height = 0,
}) async {
  if (bytes.isEmpty) return null;
  try {
    if (format == 32 || format == 24) {
      if (width <= 0 || height <= 0) return null;
      final rgba = format == 24 ? _rgbToRgba(bytes) : bytes;
      if (rgba.length < width * height * 4) return null;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw 'timeout',
      );
      return DecodedTerminalImage(
        frames: <TerminalImageFrame>[TerminalImageFrame(image)],
        sourceWidth: width,
        sourceHeight: height,
      );
    }
    return await _decodeEncodedImageSequenceBounded(bytes);
  } catch (_) {
    return null;
  }
}

/// Decodes Kitty graphics payload [bytes] and returns its first frame.
///
/// Prefer [decodeTerminalImageSequence] when retaining the result so animated
/// GIF/APNG frames and durations are preserved.
Future<ui.Image?> decodeTerminalImage(
  Uint8List bytes, {
  int format = 100,
  int width = 0,
  int height = 0,
}) async {
  if (bytes.isEmpty) {
    return null;
  }
  final decoded = await decodeTerminalImageFirstFrameSequence(
    bytes,
    format: format,
    width: width,
    height: height,
  );
  if (decoded == null || decoded.frames.isEmpty) {
    return null;
  }
  return decoded.frames.first.image;
}

/// Decodes one frame while preserving the encoded image's source dimensions.
///
/// Protocol `a=f` transmits one logical frame per command even when its payload
/// happens to use a multi-frame container. Limiting the codec avoids decoding
/// and allocating frames that cannot affect that command.
Future<DecodedTerminalImage?> decodeTerminalImageFirstFrameSequence(
  Uint8List bytes, {
  int format = 100,
  int width = 0,
  int height = 0,
}) async {
  if (bytes.isEmpty) {
    return null;
  }
  try {
    return format == 32 || format == 24
        ? await decodeTerminalImageSequence(
            bytes,
            format: format,
            width: width,
            height: height,
          )
        : await _decodeEncodedImageSequenceBounded(bytes, maxFrames: 1);
  } catch (_) {
    return null;
  }
}

/// Decodes an encoded image sequence, downscaling to
/// [_maxDecodedImageDimension] on its longest side when larger.
Future<DecodedTerminalImage?> _decodeEncodedImageSequenceBounded(
  Uint8List bytes, {
  int? maxFrames,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final srcWidth = descriptor.width;
    final srcHeight = descriptor.height;
    int? targetWidth;
    int? targetHeight;
    final kept = terminalDecodedImageSize(
      srcWidth,
      srcHeight,
      format: _encodedImageFormat,
    );
    if (kept.width != srcWidth || kept.height != srcHeight) {
      targetWidth = kept.width;
      targetHeight = kept.height;
    }
    final codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    try {
      final decodedWidth = targetWidth ?? srcWidth;
      final decodedHeight = targetHeight ?? srcHeight;
      final frameBytes = decodedWidth * decodedHeight * 4;
      final memoryFrameLimit = frameBytes <= 0
          ? 1
          : math.max(1, _maxDecodedAnimationBytes ~/ frameBytes);
      final frameLimit = math.min(
        codec.frameCount,
        math.min(
          maxFrames ?? _maxDecodedAnimationFrames,
          math.min(_maxDecodedAnimationFrames, memoryFrameLimit),
        ),
      );
      final frames = <TerminalImageFrame>[];
      try {
        for (var index = 0; index < frameLimit; index++) {
          final frame = await codec.getNextFrame();
          frames.add(
            TerminalImageFrame(
              frame.image,
              duration: codec.frameCount > 1 && frame.duration == Duration.zero
                  ? _minimumEncodedFrameDuration
                  : frame.duration,
            ),
          );
        }
      } catch (_) {
        for (final frame in frames) {
          frame.image.dispose();
        }
        rethrow;
      }
      if (frames.isEmpty) {
        return null;
      }
      return DecodedTerminalImage(
        frames: frames,
        sourceWidth: srcWidth,
        sourceHeight: srcHeight,
        repetitionCount: codec.repetitionCount,
      );
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// Largest Kitty graphics payload the terminal accepts, compressed or, once
/// inflated, uncompressed.
const maxTerminalGraphicsPayloadBytes = 16 * 1024 * 1024;

/// Inflates a zlib-compressed (`o=z`) Kitty graphics payload.
///
/// Returns null if [bytes] is empty, is not valid zlib data, or would inflate
/// past [maxBytes]: the decoder stops there, so a small payload cannot expand
/// to fill memory or hold up the UI thread. Uses `package:archive`, whose
/// decoder works on both `dart:io` and web targets.
Uint8List? inflateZlibData(
  Uint8List bytes, {
  int maxBytes = maxTerminalGraphicsPayloadBytes,
}) {
  if (bytes.isEmpty) {
    return null;
  }
  try {
    return const ZLibDecoder().decodeBytes(bytes, maxOutputSize: maxBytes);
  } catch (_) {
    return null;
  }
}

Uint8List _rgbToRgba(Uint8List rgb) {
  final pixels = rgb.length ~/ 3;
  final rgba = Uint8List(pixels * 4);
  for (var i = 0; i < pixels; i++) {
    rgba[i * 4] = rgb[i * 3];
    rgba[i * 4 + 1] = rgb[i * 3 + 1];
    rgba[i * 4 + 2] = rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 0xFF;
  }
  return rgba;
}
