import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../../domain/services/acp_audio_clip_cache.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';
import 'acp_resource_chip.dart' show formatResourceSize;

const _diagnosticsCategory = 'acp_audio';

/// Whether inline ACP audio can play in-app on [platform].
///
/// Playback uses `video_player`, whose federated implementations cover
/// Android, iOS, and macOS. Windows and Linux have none, so [AcpAudioPlayer]
/// offers to open the clip in another app or save it instead.
bool acpAudioPlaybackSupported([TargetPlatform? platform]) {
  if (kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.windows => false,
  };
}

/// Creates a playback controller for a decoded clip file.
typedef AcpAudioControllerFactory = VideoPlayerController Function(File file);

/// A decoded clip handed to another app or saved by the user.
@immutable
class AcpAudioExport {
  /// Creates an audio export.
  const AcpAudioExport({
    required this.file,
    required this.fileName,
    required this.mimeType,
  });

  /// The decoded clip on local storage.
  final File file;

  /// A generic suggested file name; never derived from clip content.
  final String fileName;

  /// The clip MIME type.
  final String mimeType;
}

/// Opens, shares, or saves a decoded clip.
typedef AcpAudioExportAction = Future<void> Function(
  BuildContext context,
  AcpAudioExport export,
);

/// Opens [export] in another app: the share sheet on mobile, or the default
/// handler for the file type on desktop.
Future<void> openAcpAudioExternally(
  BuildContext context,
  AcpAudioExport export,
) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android || TargetPlatform.iOS:
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              export.file.path,
              mimeType: export.mimeType,
              name: export.fileName,
            ),
          ],
          sharePositionOrigin: box != null && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    case TargetPlatform.fuchsia ||
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows:
      final opened = await launchUrl(Uri.file(export.file.path));
      if (!opened) {
        throw const AcpAudioClipException('No app could open the clip.');
      }
  }
}

/// Saves [export] through the platform save dialog.
Future<void> saveAcpAudioClip(
  BuildContext context,
  AcpAudioExport export,
) async {
  final bytes = await export.file.readAsBytes();
  final destination = await FilePicker.saveFile(
    dialogTitle: 'Save audio clip',
    fileName: export.fileName,
    mimeType: export.mimeType,
    bytes: bytes,
  );
  if (destination != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('Audio clip saved')));
  }
}

/// Formats a playback [duration] as `m:ss` or `h:mm:ss`.
String formatAcpAudioDuration(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

enum _AcpAudioPhase {
  idle,
  loading,
  ready,

  /// The platform player could not open the decoded clip.
  failed,

  /// The payload itself could not be decoded.
  damaged,
}

/// A compact, accessible player for an inline ACP audio clip.
///
/// Nothing is decoded until the user presses play: the bounded base64 payload
/// is then written to a private temporary file through [AcpAudioClipCache]
/// and played with `video_player`. Disposing the widget (for example when the
/// chat list scrolls it away) stops playback and releases the file. Starting
/// one clip pauses any other clip that is playing.
///
/// Where in-app playback is unavailable (Windows and Linux), or the platform
/// cannot decode the clip, the player instead offers to open the clip in
/// another app or save it.
class AcpAudioPlayer extends StatefulWidget {
  /// Creates an audio player for [clip].
  const AcpAudioPlayer({
    required this.clip,
    super.key,
    this.cache,
    this.controllerFactory,
    this.playbackSupported,
    this.onOpenExternally,
    this.onSave,
    this.maxWidth = 360,
  });

  /// The clip to play.
  final AcpAudioClip clip;

  /// Decoded-file cache; defaults to [AcpAudioClipCache.instance].
  final AcpAudioClipCache? cache;

  /// Creates playback controllers; defaults to [VideoPlayerController.file].
  final AcpAudioControllerFactory? controllerFactory;

  /// Overrides platform detection from [acpAudioPlaybackSupported].
  final bool? playbackSupported;

  /// Opens the clip in another app; defaults to [openAcpAudioExternally].
  final AcpAudioExportAction? onOpenExternally;

  /// Saves the clip; defaults to [saveAcpAudioClip].
  final AcpAudioExportAction? onSave;

  /// Maximum rendered width.
  final double maxWidth;

  @override
  State<AcpAudioPlayer> createState() => _AcpAudioPlayerState();
}

class _AcpAudioPlayerState extends State<AcpAudioPlayer> {
  static _AcpAudioPlayerState? _activePlayer;

  var _phase = _AcpAudioPhase.idle;
  var _generation = 0;
  var _exporting = false;
  AcpAudioClipLease? _lease;
  VideoPlayerController? _controller;
  double? _dragPositionMs;

  AcpAudioClipCache get _cache => widget.cache ?? AcpAudioClipCache.instance;

  bool get _playbackSupported =>
      widget.playbackSupported ?? acpAudioPlaybackSupported();

  @override
  void didUpdateWidget(covariant AcpAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip != widget.clip) {
      _teardown();
      _phase = _AcpAudioPhase.idle;
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _generation++;
    _dragPositionMs = null;
    if (identical(_activePlayer, this)) _activePlayer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerValue);
      unawaited(controller.dispose());
    }
    _lease?.release();
    _lease = null;
  }

  Future<bool> _load() async {
    final data = widget.clip.data;
    if (data == null || data.isEmpty) return false;
    final generation = ++_generation;
    setState(() => _phase = _AcpAudioPhase.loading);
    final stopwatch = Stopwatch()..start();
    VideoPlayerController? controller;
    try {
      final lease = await _cache.acquire(
        data: data,
        mimeType: widget.clip.mimeType,
      );
      if (!mounted || generation != _generation) {
        lease.release();
        return false;
      }
      _lease = lease;
      controller = (widget.controllerFactory ?? VideoPlayerController.file)(
        lease.file,
      );
      _controller = controller..addListener(_onControllerValue);
      await controller.initialize();
      if (!mounted || generation != _generation) return false;
      DiagnosticsLogService.instance.info(
        _diagnosticsCategory,
        'playback_ready',
        fields: <String, Object?>{
          'durationMs': stopwatch.elapsedMilliseconds,
          'clipSeconds': controller.value.duration.inSeconds,
        },
      );
      setState(() => _phase = _AcpAudioPhase.ready);
      return true;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        _diagnosticsCategory,
        'playback_failed',
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'durationMs': stopwatch.elapsedMilliseconds,
          'stage': controller == null ? 'decode' : 'initialize',
        },
      );
      if (mounted && generation == _generation) {
        // Keep the decoded file leased so open/save can reuse it.
        if (controller != null && identical(_controller, controller)) {
          controller.removeListener(_onControllerValue);
          _controller = null;
          unawaited(controller.dispose());
        }
        setState(
          () => _phase = controller == null
              ? _AcpAudioPhase.damaged
              : _AcpAudioPhase.failed,
        );
      }
      return false;
    }
  }

  void _onControllerValue() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.hasError && _phase != _AcpAudioPhase.failed) {
      DiagnosticsLogService.instance.warning(
        _diagnosticsCategory,
        'playback_error',
        fields: const <String, Object?>{'stage': 'playing'},
      );
      if (identical(_activePlayer, this)) _activePlayer = null;
      setState(() => _phase = _AcpAudioPhase.failed);
      return;
    }
    setState(() {});
  }

  bool _isComplete(VideoPlayerValue value) =>
      !value.isPlaying &&
      (value.isCompleted ||
          (value.duration > Duration.zero && value.position >= value.duration));

  Future<void> _togglePlayback() async {
    if (_phase == _AcpAudioPhase.loading) return;
    if (_controller == null && !await _load()) return;
    final controller = _controller;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.isPlaying) {
      await controller.pause();
      return;
    }
    final active = _activePlayer;
    if (active != null && !identical(active, this)) {
      unawaited(active._controller?.pause());
    }
    _activePlayer = this;
    if (_isComplete(value)) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
  }

  Future<void> _export({required bool open}) async {
    final data = widget.clip.data;
    if (_exporting || data == null) return;
    setState(() => _exporting = true);
    AcpAudioClipLease? lease;
    try {
      lease = await _cache.acquire(data: data, mimeType: widget.clip.mimeType);
      if (!mounted) return;
      final mimeType = normalizeAcpAudioMimeType(widget.clip.mimeType ?? '');
      final export = AcpAudioExport(
        file: lease.file,
        fileName: 'audio-clip.${acpAudioFileExtension(mimeType)}',
        mimeType: mimeType.startsWith('audio/')
            ? mimeType
            : 'application/octet-stream',
      );
      final action = open
          ? widget.onOpenExternally ?? openAcpAudioExternally
          : widget.onSave ?? saveAcpAudioClip;
      await action(context, export);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        _diagnosticsCategory,
        open ? 'open_failed' : 'save_failed',
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              open
                  ? 'Couldn’t open the audio clip in another app.'
                  : 'Couldn’t save the audio clip.',
            ),
          ),
        );
      }
    } finally {
      lease?.release();
      if (mounted) setState(() => _exporting = false);
    }
  }

  String? get _formatLabel {
    final extension = acpAudioFileExtension(widget.clip.mimeType);
    return extension == 'audio' ? null : extension.toUpperCase();
  }

  String get _details {
    final size = widget.clip.sizeBytes;
    return [
      ?_formatLabel,
      if (size != null && size > 0) formatResourceSize(size),
    ].join(' · ');
  }

  String get _title {
    final label = widget.clip.label?.trim();
    return label == null || label.isEmpty ? 'Audio clip' : label;
  }

  /// A short status for states where the clip cannot play in place.
  String? get _unavailableStatus {
    if (_phase == _AcpAudioPhase.damaged) return 'Couldn’t decode this clip';
    if (widget.clip.isPlayable) return null;
    final tooLarge = (widget.clip.sizeBytes ?? 0) > kAcpAttachmentAudioMaxBytes;
    return tooLarge
        ? 'Too large to play · '
              '${formatResourceSize(kAcpAttachmentAudioMaxBytes)} max'
        : 'Audio unavailable';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = AcpChatTypography.monoStyleOf(context);
    final details = _details;
    final controller = _controller;
    final value = controller?.value;
    final ready = _phase == _AcpAudioPhase.ready && value != null;
    final unavailable = _unavailableStatus;
    final exportOnly =
        unavailable == null &&
        (!_playbackSupported || _phase == _AcpAudioPhase.failed);
    final playing = value?.isPlaying ?? false;

    final Widget leading;
    if (unavailable != null) {
      leading = _Well(
        child: Icon(
          Icons.music_off_outlined,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
      );
    } else if (exportOnly) {
      final failed = _phase == _AcpAudioPhase.failed;
      leading = _Well(
        child: Icon(
          failed ? Icons.error_outline : Icons.graphic_eq_rounded,
          size: 18,
          color: failed ? scheme.error : scheme.onSurfaceVariant,
        ),
      );
    } else if (_phase == _AcpAudioPhase.loading) {
      leading = _Well(
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.primary,
          ),
        ),
      );
    } else {
      final complete = value != null && _isComplete(value);
      leading = IconButton(
        key: const ValueKey('acp-audio-play-toggle'),
        tooltip: playing ? 'Pause audio clip' : 'Play audio clip',
        constraints: const BoxConstraints.tightFor(
          width: _tapTarget,
          height: _tapTarget,
        ),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        onPressed: _togglePlayback,
        icon: _Well(
          active: playing,
          child: Icon(
            playing
                ? Icons.pause_rounded
                : complete
                ? Icons.replay_rounded
                : Icons.play_arrow_rounded,
            size: 20,
            color: playing ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      );
    }

    // Line two keeps a fixed height across idle, loading, and ready so the
    // chip never jumps when the seek bar replaces the metadata.
    final Widget secondLine;
    String? semanticsValue;
    if (ready) {
      final duration = value.duration;
      final position = value.position > duration ? duration : value.position;
      semanticsValue =
          '${formatAcpAudioDuration(position)} of '
          '${formatAcpAudioDuration(duration)}'
          '${playing ? ', playing' : ''}';
      secondLine = _SeekBar(
        position: position,
        duration: duration,
        // Only the clip that is playing (or being scrubbed) carries the
        // accent, so several loaded clips never compete for attention.
        active: playing || _dragPositionMs != null,
        dragPositionMs: _dragPositionMs,
        onDrag: (ms) => setState(() => _dragPositionMs = ms),
        onSeek: (ms) {
          setState(() => _dragPositionMs = null);
          unawaited(controller!.seekTo(Duration(milliseconds: ms.round())));
        },
      );
    } else {
      final failed = _phase == _AcpAudioPhase.failed;
      final status =
          unavailable ??
          (exportOnly
              ? failed
                    ? 'Can’t play here'
                    : 'Plays in another app'
              : null);
      if (_phase == _AcpAudioPhase.loading) semanticsValue = 'loading';
      final muted = theme.textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
      );
      secondLine = Text.rich(
        TextSpan(
          children: [
            if (details.isNotEmpty)
              TextSpan(text: status == null ? details : '$details · '),
            if (status != null)
              TextSpan(
                text: status,
                // The error glyph in the well carries the state too; colour
                // never stands alone.
                style: failed ? TextStyle(color: scheme.error) : null,
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      );
    }

    final Widget? trailingTime = ready
        ? Text(
            '${formatAcpAudioDuration(Duration(milliseconds: (_dragPositionMs ?? value.position.inMilliseconds.toDouble()).round()))}'
            ' / ${formatAcpAudioDuration(value.duration)}',
            style: mono.copyWith(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          )
        : null;

    final mobile = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

    return Semantics(
      container: true,
      label: details.isEmpty ? _title : '$_title, $details',
      value: semanticsValue,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: DecoratedBox(
          key: const ValueKey('acp-audio-player'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
            border: Border.all(color: scheme.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, FluttyTheme.spacingSm, 2),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: _tapTarget,
                  child: Center(child: leading),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The container label announces the title and details;
                      // only the live position and controls are read below.
                      ExcludeSemantics(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono.copyWith(
                                  fontSize: 12,
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            ?trailingTime,
                          ],
                        ),
                      ),
                      SizedBox(
                        height: _secondLineHeight,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ready
                              ? secondLine
                              : ExcludeSemantics(
                                  excluding: unavailable == null && !exportOnly,
                                  child: secondLine,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (exportOnly) ...[
                  const SizedBox(width: FluttyTheme.spacingXs),
                  _ActionButton(
                    tooltip: mobile
                        ? 'Share audio clip'
                        : 'Open audio clip in another app',
                    icon: mobile ? Icons.ios_share : Icons.open_in_new,
                    onPressed: _exporting ? null : () => _export(open: true),
                  ),
                  _ActionButton(
                    tooltip: 'Save audio clip',
                    icon: Icons.download_outlined,
                    onPressed: _exporting ? null : () => _export(open: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const double _tapTarget = 44;
const double _wellDiameter = 36;
const double _secondLineHeight = 20;

/// The circular well behind the leading glyph, shared by every state so the
/// chip keeps one silhouette whether it can play, is loading, or falls back.
class _Well extends StatelessWidget {
  const _Well({required this.child, this.active = false});

  final Widget child;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: MediaQuery.maybeOf(context)?.disableAnimations ?? false
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      width: _wellDiameter,
      height: _wellDiameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? scheme.primary : scheme.surface,
        border: Border.all(color: active ? scheme.primary : scheme.outline),
      ),
      child: Center(child: child),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    constraints: const BoxConstraints.tightFor(
      width: _tapTarget,
      height: _tapTarget,
    ),
    padding: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: Icon(icon, size: 19),
    onPressed: onPressed,
  );
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.active,
    required this.dragPositionMs,
    required this.onDrag,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final bool active;
  final double? dragPositionMs;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalMs = duration.inMilliseconds;
    final canSeek = totalMs > 0;
    final max = canSeek ? totalMs.toDouble() : 1.0;
    final current = (dragPositionMs ?? position.inMilliseconds.toDouble())
        .clamp(0.0, max);
    // A translucent ink keeps a paused clip's progress legible without
    // matching the weight of the playing clip's accent.
    final accent = active
        ? scheme.primary
        : Color.alphaBlend(
            scheme.onSurface.withAlpha(120),
            scheme.surfaceContainerHighest,
          );
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        activeTrackColor: accent,
        inactiveTrackColor: scheme.outline,
        thumbColor: accent,
        overlayColor: scheme.primary.withAlpha(36),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        trackShape: const RoundedRectSliderTrackShape(),
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: Padding(
        // Pull the track flush with the title above; the overlay radius
        // otherwise insets it.
        padding: const EdgeInsets.only(right: FluttyTheme.spacingXs),
        child: Slider(
          key: const ValueKey('acp-audio-seek'),
          value: canSeek ? current : 0,
          max: max,
          padding: EdgeInsets.zero,
          semanticFormatterCallback: (value) =>
              formatAcpAudioDuration(Duration(milliseconds: value.round())),
          onChanged: canSeek ? onDrag : null,
          onChangeEnd: canSeek ? onSeek : null,
        ),
      ),
    );
  }
}
