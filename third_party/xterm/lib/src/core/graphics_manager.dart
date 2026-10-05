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
  TerminalImage(this.id, ui.Image image, {this.sourceSignature = 0})
      : sourceWidth = image.width,
        sourceHeight = image.height,
        _frames = <TerminalImageFrame>[TerminalImageFrame(image)];

  /// Creates a retained image from a decoded frame sequence.
  TerminalImage.fromDecoded(
    this.id,
    DecodedTerminalImage decoded, {
    this.sourceSignature = 0,
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
/// scrollback and reflow, and detaches when that cell is evicted.
class TerminalImagePlacement {
  TerminalImagePlacement({
    required this.placementId,
    required this.imageId,
    required this.anchor,
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
        _fallbackRow = fallbackRow;

  /// Internal placement id assigned by the [GraphicsManager], unique per
  /// placement and monotonically increasing (used for stable paint ordering).
  final int placementId;

  /// The id of the placed [TerminalImage].
  final int imageId;

  /// Client-assigned placement id (the Kitty `p=` key, 0 when unspecified). This
  /// — not [placementId] — is what a delete command (`a=d` with `p=`) targets.
  final int clientPlacementId;

  /// Anchor for the top-left cell of the placement.
  final CellAnchor anchor;

  final int _fallbackCol;
  final int _fallbackRow;

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
  int get col => anchor.attached ? anchor.x : _fallbackCol;

  /// Absolute buffer row of the top-left cell.
  int get row => anchor.attached ? anchor.y : _fallbackRow;

  /// Whether the anchored cell is still present in the buffer.
  bool get attached => anchor.attached;

  /// Releases the underlying anchor.
  void dispose() => anchor.dispose();
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
  TerminalImageVirtualPlacement({required this.cols, required this.rows});

  /// Number of columns the image should occupy.
  final int cols;

  /// Number of rows the image should occupy.
  final int rows;
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
    this.imageNumberReservations = const <_PendingImageNumberReservation>[],
  });

  final Uint8List payload;
  final int format;
  final int width;
  final int height;
  final int sourceWidth;
  final int sourceHeight;
  final int sourceSignature;
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

  int _nextImageId = 1;
  int _nextPlacementId = 1;
  int _nextPlaceholderSequence = 1;
  int _generation = 0;
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

  /// Active placements, oldest first.
  List<TerminalImagePlacement> get placements =>
      _placementsByAnchor.values.toList(growable: false);

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
  bool get hasPlacements => _placementsByAnchor.isNotEmpty;

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
    if (_placementsByAnchor.isEmpty || lines.length == 0) {
      return const <TerminalImagePlacement>[];
    }
    final first = firstRow.clamp(0, lines.length - 1);
    final last = lastRow.clamp(0, lines.length - 1);
    if (last < first) {
      return const <TerminalImagePlacement>[];
    }
    final relativeRows = _placementRelativeRowExtent;
    final firstAnchorRow = math.max(0, first - relativeRows.last);
    final lastAnchorRow = math.min(
      lines.length - 1,
      last - relativeRows.first,
    );
    final candidateRowCount = math.max(0, lastAnchorRow - firstAnchorRow + 1);
    if (candidateRowCount > _placementsByAnchor.length) {
      return <TerminalImagePlacement>[
        for (final placement in _placementsByAnchor.values)
          if (placement.attached &&
              _placementIntersectsRows(placement, first, last))
            placement,
      ];
    }
    final result = <TerminalImagePlacement>[];
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
    _placementRowsByAnchor[placement.anchor] = range;
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

  /// Bumped whenever placements are cleared. An asynchronous image decode
  /// captures this before it starts and skips placing if it changed, so a clear
  /// that races an in-flight decode cannot leave a stale image behind.
  int get generation => _generation;

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
    final imageId = _nextImageId++;
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
      imageNumberReservations:
          List<_PendingImageNumberReservation>.unmodifiable(reservations),
    );
    _pendingBytes += payload.length;
    if (id >= _nextImageId) {
      _nextImageId = id + 1;
    }
    _evictPendingIfNeeded();
  }

  void _evictPendingIfNeeded() {
    while (_pendingImages.isNotEmpty &&
        (_pendingBytes > _maxPendingBytes ||
            _pendingImages.length > _maxPendingImages)) {
      final oldest = _pendingImages.keys.first;
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
  }

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
  int storeDecodedImage(DecodedTerminalImage image, {int sourceSignature = 0}) {
    final sizeBytes = image.sizeBytes;
    if (sizeBytes > maxMemoryBytes) {
      _disposeDecodedTerminalImage(image);
      return 0;
    }
    _evictIfNeeded(sizeBytes);

    final id = _nextImageId++;
    _images[id] = TerminalImage.fromDecoded(
      id,
      image,
      sourceSignature: sourceSignature,
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
  }) {
    if (id <= 0) {
      return storeDecodedImage(image, sourceSignature: sourceSignature);
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
    ).._lastAccess = ++_accessClock;
    _retainedImageIds.add(id);
    _currentMemoryBytes += sizeBytes;
    if (id >= _nextImageId) {
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
    for (final entry in _images.entries) {
      if ((imageIds == null
              ? _isImageDisplayed(entry.key)
              : imageIds.contains(entry.key)) &&
          entry.value._needsAnimationTick) {
        return true;
      }
    }
    return false;
  }

  /// Advances displayed animations by [elapsed].
  ///
  /// Returns true when at least one current frame changed. The host renderer
  /// calls this from its ticker and repaints through [onChanged].
  bool advanceAnimations(Duration elapsed, {Set<int>? imageIds}) {
    var changed = false;
    for (final entry in _images.entries) {
      final displayed = imageIds == null
          ? _isImageDisplayed(entry.key)
          : imageIds.contains(entry.key);
      if (displayed && entry.value._advance(elapsed)) {
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

  bool _isImageDisplayed(int imageId) {
    if (_placementsByAnchor.values.any(
      (placement) => placement.imageId == imageId && placement.attached,
    )) {
      return true;
    }
    for (final placeholder in _placeholdersByAnchor.values) {
      if (!placeholder.attached) {
        continue;
      }
      final mask = placeholder.imageIdBitWidth >= 24 ? 0xFFFFFF : 0xFF;
      if (placeholder.imageId == imageId ||
          (_retainedImageIds.contains(imageId) &&
              (imageId & mask) == placeholder.imageId)) {
        return true;
      }
    }
    return false;
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
    if (clientPlacementId > 0) {
      _removePlacementsWhere(
        (existing) =>
            existing.imageId == imageId &&
            existing.clientPlacementId == clientPlacementId,
      );
    }
    final placement = TerminalImagePlacement(
      placementId: _nextPlacementId++,
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
    anchor.onDispose = _handleAnchorDisposed;
    _placementsByAnchor[anchor] = placement;
    _placementCountByImage.update(
      imageId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    if (!_placementRelativeRowsDirty) _indexPlacementRows(placement);
    return placement;
  }

  /// Records a virtual placement prototype for [imageId].
  void setVirtualPlacement(
    int imageId, {
    required int cols,
    required int rows,
  }) {
    if (imageId <= 0 || cols <= 0 || rows <= 0) {
      return;
    }
    _virtualPlacements[imageId] = TerminalImageVirtualPlacement(
      cols: cols,
      rows: rows,
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
          !placement.attached ||
          _placementIntersectsRows(placement, firstRow, lastRow),
    );
    if (removed.isNotEmpty) {
      _generation++;
    }
    pruneDetachedPlaceholders();
    _dropUnreferencedImages();
  }

  /// Deletes physical image placements in response to a Kitty graphics delete
  /// command (`a=d`).
  ///
  /// [what] is the `d=` selector. The Kitty default, when `d=` is omitted, is
  /// `a` — every placement currently on screen. Lowercase selectors remove the
  /// matching placement(s) only; uppercase selectors additionally free the
  /// underlying image data (and, for the id form, its Unicode placeholders).
  /// Selectors target placements by image/placement id ([imageId]/[placementId]
  /// for `i`/`I`), the cursor cell ([cursorCol]/[cursorRow] for `c`/`C`), or an
  /// explicit cell, column or row ([cellCol]/[cellRow] for `p`/`P`, `x`/`X`,
  /// `y`/`Y`). Unsupported selectors delete nothing.
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
  }) {
    final selector = what.isEmpty ? 'a' : what;
    final mode = selector.toLowerCase();
    final freeImages = selector != mode; // an uppercase selector frees data

    bool matches(TerminalImagePlacement placement) {
      switch (mode) {
        case 'a':
          return true;
        case 'i':
          if (imageId != null && placement.imageId != imageId) return false;
          if (placementId != null &&
              placement.clientPlacementId != placementId) {
            return false;
          }
          return true;
        case 'c':
          return cursorCol != null &&
              cursorRow != null &&
              _placementIntersectsRows(placement, cursorRow, cursorRow) &&
              _placementIntersectsCols(placement, cursorCol, cursorCol);
        case 'p':
          return cellCol != null &&
              cellRow != null &&
              _placementIntersectsRows(placement, cellRow, cellRow) &&
              _placementIntersectsCols(placement, cellCol, cellCol);
        case 'x':
          return cellCol != null &&
              _placementIntersectsCols(placement, cellCol, cellCol);
        case 'y':
          return cellRow != null &&
              _placementIntersectsRows(placement, cellRow, cellRow);
        default:
          // Unsupported selector (image number, z-index, animation frames,
          // ranges): delete nothing rather than risk wiping live images.
          return false;
      }
    }

    final removed = _removePlacementsWhere(matches);
    final freedImageIds = {for (final placement in removed) placement.imageId};
    var changed = removed.isNotEmpty;

    if (freeImages) {
      // The client explicitly asked to free the image data, so allow even
      // images retained for Unicode-placeholder reuse to be reclaimed.
      for (final id in freedImageIds) {
        _retainedImageIds.remove(id);
      }
      if (mode == 'i' && imageId != null) {
        // `d=I` with an id frees the image and all of its placements and
        // placeholders, whether or not a physical placement was on screen.
        if (_images.containsKey(imageId) ||
            _placeholdersByAnchor.values.any((p) => p.imageId == imageId)) {
          _dropImage(imageId);
          changed = true;
        }
      } else {
        _dropUnreferencedImages();
      }
    }

    if (changed) {
      _generation++;
    }
    return changed;
  }

  /// Removes every physical placement and drops placement-only images. Images
  /// with protocol ids are retained so Unicode-placeholder redraws can reuse
  /// them after a clear.
  void clear() {
    _generation++;
    _pendingPlacementAnchors.clear();
    for (final placement in _placementsByAnchor.values.toList()) {
      _disposePlacement(placement);
    }
    for (final placeholder in _placeholdersByAnchor.values.toList()) {
      _disposePlaceholder(placeholder);
    }
    _placementsByAnchor.clear();
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

  ({int firstCol, int lastCol, int firstRow, int lastRow})
      _placementRelativeCellRange(TerminalImagePlacement placement) {
    final size = _placementDestinationSize(placement);
    final cellWidth = _cellPixelWidth > 0 ? _cellPixelWidth : 10.0;
    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    final firstCol = (placement.xOffset / cellWidth).floor();
    final firstRow = (placement.yOffset / cellHeight).floor();
    final lastCol = ((placement.xOffset + size.width) / cellWidth).ceil() - 1;
    final lastRow = ((placement.yOffset + size.height) / cellHeight).ceil() - 1;
    return (
      firstCol: firstCol,
      lastCol: math.max(firstCol, lastCol),
      firstRow: firstRow,
      lastRow: math.max(firstRow, lastRow),
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
    final first = (placement.yOffset / cellHeight).floor();
    final last = ((placement.yOffset + size.height) / cellHeight).ceil() - 1;
    return (first: first, last: math.max(first, last));
  }

  ({double width, double height}) _placementDestinationSize(
    TerminalImagePlacement placement, {
    bool maximizeNaturalWidth = false,
  }) {
    final cellWidth = _cellPixelWidth > 0 ? _cellPixelWidth : 10.0;
    final cellHeight = _cellPixelHeight > 0 ? _cellPixelHeight : 20.0;
    if (placement.cols > 0 && placement.rows > 0) {
      return (
        width: placement.cols * cellWidth,
        height: placement.rows * cellHeight,
      );
    }
    final source = _placementSourceSize(placement);
    if (source == null) {
      return (
        width: math.max(1, placement.cols) * cellWidth,
        height: math.max(1, placement.rows) * cellHeight,
      );
    }
    if (placement.cols > 0) {
      final width = placement.cols * cellWidth;
      return (width: width, height: source.height * (width / source.width));
    }
    if (placement.rows > 0) {
      final height = placement.rows * cellHeight;
      return (width: source.width * (height / source.height), height: height);
    }
    final availableColumns = maximizeNaturalWidth
        ? math.max(1, _viewportColumns)
        : math.max(1, _viewportColumns - placement.col);
    final maxWidth = availableColumns * cellWidth;
    final scale = source.width > maxWidth ? maxWidth / source.width : 1.0;
    return (width: source.width * scale, height: source.height * scale);
  }

  ({double width, double height})? _placementSourceSize(
    TerminalImagePlacement placement,
  ) {
    final image = _images[placement.imageId];
    final pending = _pendingImages[placement.imageId];
    final sourceWidth = image?.sourceWidth ?? pending?.sourceWidth ?? 0;
    final sourceHeight = image?.sourceHeight ?? pending?.sourceHeight ?? 0;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }

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

    final decoded = image?.image;
    return (
      width: logicalWidth * (decoded == null ? 1 : decoded.width / sourceWidth),
      height:
          logicalHeight * (decoded == null ? 1 : decoded.height / sourceHeight),
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
      final oldest = _images.entries.reduce((a, b) {
        return a.value._lastAccess <= b.value._lastAccess ? a : b;
      });
      _dropImage(oldest.key);
    }
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
      MapEntry<int, TerminalImage>? oldest;
      for (final entry in _images.entries) {
        if (entry.key == protectedImageId) {
          continue;
        }
        if (oldest == null ||
            entry.value._lastAccess < oldest.value._lastAccess) {
          oldest = entry;
        }
      }
      if (oldest == null) {
        break;
      }
      _dropImage(oldest.key);
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

  List<TerminalImagePlacement> _removePlacementsWhere(
    bool Function(TerminalImagePlacement placement) predicate,
  ) {
    final removed = <TerminalImagePlacement>[
      for (final placement in _placementsByAnchor.values)
        if (predicate(placement)) placement,
    ];
    for (final placement in removed) {
      _disposePlacement(placement);
    }
    return removed;
  }

  void _disposePlacement(TerminalImagePlacement placement) {
    _placementsByAnchor.remove(placement.anchor);
    _unindexPlacementRows(placement.anchor);
    _decrementPlacementImageCount(placement.imageId);
    placement.anchor.onDispose = null;
    placement.dispose();
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
    final longest = srcWidth > srcHeight ? srcWidth : srcHeight;
    if (longest > _maxDecodedImageDimension && longest > 0) {
      final scale = _maxDecodedImageDimension / longest;
      targetWidth = (srcWidth * scale).round().clamp(
            1,
            _maxDecodedImageDimension,
          );
      targetHeight = (srcHeight * scale).round().clamp(
            1,
            _maxDecodedImageDimension,
          );
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

/// Inflates a zlib-compressed (`o=z`) Kitty graphics payload.
///
/// Returns null if [bytes] is empty or not valid zlib data. Uses
/// `package:archive`, whose decoder works on both `dart:io` and web targets.
Uint8List? inflateZlibData(Uint8List bytes) {
  if (bytes.isEmpty) {
    return null;
  }
  try {
    // archive 3.x returns List<int>, 4.x returns Uint8List; widen to List<int>
    // and copy so this compiles cleanly against both without a type check.
    final List<int> inflated = const ZLibDecoder().decodeBytes(bytes);
    return Uint8List.fromList(inflated);
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
