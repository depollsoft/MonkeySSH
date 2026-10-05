import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'diagnostics_log_service.dart';

/// Logs janky frames so a hang can be attributed to the correct thread.
///
/// Flutter runs the build/layout/paint phase on the UI (Dart) thread and the
/// rasterization/compositing phase on the raster (GPU) thread. A frozen UI can
/// come from either: heavy parsing/layout (UI thread) or compositing many large
/// images (raster thread). [FrameTiming] reports both durations per frame, so a
/// frame that exceeds [_jankThreshold] is logged with its build and raster cost.
/// This discriminates "our terminal parse/layout is slow" from "image
/// compositing is slow" without guessing.
///
/// Gated to diagnostics-enabled builds via [DiagnosticsLogService.enabled]; in
/// other builds it never registers a callback and costs nothing.
class PerformanceDiagnosticsService {
  /// Creates a performance diagnostics service backed by [logger].
  PerformanceDiagnosticsService({DiagnosticsLogger? logger})
    : _logger = logger ?? DiagnosticsLogService.instance,
      _enabled = logger != null || DiagnosticsLogService.instance.enabled;

  /// Shared instance wired to the app diagnostics log.
  static final instance = PerformanceDiagnosticsService();

  final DiagnosticsLogger _logger;
  final bool _enabled;

  // A frame slower than this is reported. 60fps is ~16.7ms and 120fps ~8.3ms,
  // so 32ms is ~2 dropped frames — sensitive enough to catch sustained sluggish
  // (not-fully-frozen) periods while still ignoring the odd hitch.
  static const _jankThreshold = Duration(milliseconds: 32);

  bool _started = false;

  /// Registers the frame-timings callback. Safe to call more than once.
  void start() {
    if (!_enabled || _started) {
      return;
    }
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(handleTimings);
    _logger.info('perf.frame', 'monitor_started');
  }

  /// Processes [timings] and logs any janky frame.
  @visibleForTesting
  void handleTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final build = timing.buildDuration;
      final raster = timing.rasterDuration;
      final total = timing.totalSpan;
      if (build < _jankThreshold && raster < _jankThreshold) {
        continue;
      }
      _logger.warning(
        'perf.frame',
        'jank',
        fields: {
          'buildMs': build.inMilliseconds,
          'rasterMs': raster.inMilliseconds,
          'totalMs': total.inMilliseconds,
          // The dominant phase points straight at the bottleneck thread.
          'bound': build >= raster ? 'ui' : 'raster',
        },
      );
    }
  }
}

/// Records a single terminal graphics decode's cost for diagnostics.
///
/// Inflation (zlib for `o=z` payloads) runs synchronously on the UI thread
/// before the async image decode, so a large compressed image can block the UI
/// thread inside a single `terminal.write`. Surfacing inflate vs decode time and
/// payload size shows whether image processing is the hang.
@immutable
class TerminalGraphicsDecodeStats {
  /// Creates decode timing stats.
  const TerminalGraphicsDecodeStats({
    required this.payloadBytes,
    required this.inflateMicros,
    required this.decodeMicros,
    required this.compressed,
    required this.success,
    this.imageId,
    this.action,
    this.reused = false,
  });

  /// Size of the (post-inflate) payload handed to the image decoder, in bytes.
  final int payloadBytes;

  /// Synchronous zlib inflate time in microseconds (0 when not compressed).
  final int inflateMicros;

  /// Image decode time in microseconds (spans an async gap; wall-clock).
  final int decodeMicros;

  /// Whether the payload was zlib-compressed (`o=z`).
  final bool compressed;

  /// Whether decoding produced an image.
  final bool success;

  /// Kitty protocol image id (`i=`), a transmission identifier — not user
  /// content. Repeated ids across one switch indicate re-transmission.
  final String? imageId;

  /// Kitty graphics action (`a=`): `T`/`t` transmit(+display), etc. Lets us
  /// tell live app transmits from MonkeyMux store-only cache replay.
  final String? action;

  /// Whether the image was reused from cache (id + identical bytes) instead of
  /// decoded again. Confirms the window-switch dedup is firing.
  final bool reused;
}

/// Logs terminal graphics decode timing for diagnostics builds.
///
/// Wired into the vendored xterm via [terminalGraphicsDecodeObserver] so the
/// decode path stays free of any app dependency.
void logTerminalGraphicsDecode(TerminalGraphicsDecodeStats stats) {
  final logger = DiagnosticsLogService.instance;
  if (!logger.enabled) {
    return;
  }
  logger.debug(
    'terminal.graphics',
    'decode',
    fields: {
      'payloadKiB': (stats.payloadBytes / 1024).round(),
      'inflateMs': (stats.inflateMicros / 1000).round(),
      'decodeMs': (stats.decodeMicros / 1000).round(),
      'compressed': stats.compressed,
      'success': stats.success,
      'reused': stats.reused,
      if (stats.imageId != null && stats.imageId!.isNotEmpty)
        'imageId': stats.imageId,
      if (stats.action != null && stats.action!.isNotEmpty)
        'action': stats.action,
    },
  );
}
