import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/services/acp_device_label.dart';
import 'acp_chat_typography.dart';

/// Describes how long ago [lastActiveAt] was, such as `active 3 min ago`.
String formatAcpWriterActivity(DateTime lastActiveAt, DateTime now) {
  final elapsed = now.difference(lastActiveAt);
  if (elapsed.inMinutes < 1) return 'active just now';
  if (elapsed.inHours < 1) return 'active ${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return 'active ${elapsed.inHours} h ago';
  return 'active ${elapsed.inDays} d ago';
}

/// Names the device holding a chat's input, falling back for older clients
/// that sent no label.
///
/// A holder with this device's own label, [localLabel], is another device of
/// the same kind, so it reads as `another iPhone` rather than `iPhone`.
String acpWriterDeviceName(
  MonkeyMuxAcpRemoteWriter writer, {
  String? localLabel,
}) {
  final label = writer.label;
  if (label == null) return 'another device';
  return label == localLabel ? 'another $label' : label;
}

/// Read-only notice shown while another device holds a native chat's input.
///
/// It says which device has the chat and when it was last used, and offers
/// to take the chat over (or back, after this device lost it). It sits just
/// above the composer it disables, within thumb reach.
class AcpWriterLeaseBanner extends StatefulWidget {
  /// Creates a writer lease banner.
  const AcpWriterLeaseBanner({
    required this.writer,
    required this.onTakeOver,
    this.onRefresh,
    this.busy = false,
    this.failed = false,
    this.clock = DateTime.now,
    this.localDeviceLabel,
    super.key,
  });

  /// Device that holds the chat's input.
  final MonkeyMuxAcpRemoteWriter writer;

  /// Moves the input to this device.
  final VoidCallback onTakeOver;

  /// Asks who holds the chat again: about once a minute while the app is in
  /// the foreground and the banner is visible, and whenever the app or the
  /// chat comes back into view, so the activity time follows the other
  /// device's use. A refresh still running skips the next one.
  final Future<void> Function()? onRefresh;

  /// Whether a take-over is already in progress.
  final bool busy;

  /// Whether the last take-over attempt failed. The chat stays read-only and
  /// the banner offers to try again.
  final bool failed;

  /// Time source for the relative activity label.
  final DateTime Function() clock;

  /// This device's own label; defaults to [currentAcpDeviceLabel].
  final String? localDeviceLabel;

  @override
  State<AcpWriterLeaseBanner> createState() => _AcpWriterLeaseBannerState();
}

class _AcpWriterLeaseBannerState extends State<AcpWriterLeaseBanner>
    with WidgetsBindingObserver {
  // Keeps "active N min ago" current while the banner stays on screen.
  Timer? _ticker;
  var _ticks = 0;
  var _refreshing = false;
  // Whether the route showing the banner is current; set during build.
  var _visible = true;
  AppLifecycleState? _lifecycle;
  late final String _localDeviceLabel =
      widget.localDeviceLabel ?? currentAcpDeviceLabel();

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      _ticks += 1;
      if (_ticks.isEven) unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _lifecycle = state;
    // The other device may have been in use the whole time this one was
    // away; ask now rather than show a stale time until the next tick.
    if (!wasForeground && _foreground && mounted) {
      setState(() {});
      unawaited(_refresh());
    }
  }

  bool get _foreground =>
      _lifecycle == null || _lifecycle == AppLifecycleState.resumed;

  Future<void> _refresh() async {
    final refresh = widget.onRefresh;
    if (refresh == null || _refreshing || !_foreground || !_visible) return;
    _refreshing = true;
    try {
      await refresh();
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Tickers are muted when another route covers this one.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) {
      // Back from a covering route: ask who holds the chat now.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh());
      });
    }
    _visible = visible;
    final scheme = Theme.of(context).colorScheme;
    final mono = AcpChatTypography.monoStyleOf(context);
    final device = acpWriterDeviceName(
      widget.writer,
      localLabel: _localDeviceLabel,
    );
    final activity = formatAcpWriterActivity(
      widget.writer.lastActiveAt,
      widget.clock(),
    );
    final actionLabel = widget.writer.leaseLost ? 'Take back' : 'Take over';
    // The button keeps its label while connecting, so it never changes
    // width under the user's thumb; the status line says what is going on.
    final shownLabel = widget.failed && !widget.busy
        ? _retryLabel
        : actionLabel;
    final detail = widget.busy
        ? 'connecting…'
        : widget.failed
        ? "couldn't take over"
        : activity;
    // Only this sentence is a live region, so a screen reader announces the
    // banner and a change of holder or a failed take over, not every minute
    // the activity time moves on.
    final liveLabel = StringBuffer(
      'Controlled by $device. Read-only on this device.',
    );
    if (widget.failed && !widget.busy) {
      liveLabel.write(' Could not take over.');
    }
    final failedNow = widget.failed && !widget.busy;
    final labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          label: liveLabel.toString(),
          excludeSemantics: true,
          child: Text(
            'controlled by $device',
            style: mono.copyWith(
              color: scheme.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            // Wrap rather than clip the device name at large text sizes; it
            // is the point of the banner.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Semantics(
          container: true,
          // A failure is already in the live sentence.
          label: failedNow ? '' : _sentenceCase(detail),
          excludeSemantics: true,
          child: Text(
            detail,
            style: mono.copyWith(
              color: failedNow ? scheme.onSurface : scheme.onSurfaceVariant,
              fontSize: 12,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final icon = ExcludeSemantics(
      child: Icon(
        failedNow ? Icons.error_outline : Icons.devices_other,
        size: 18,
        color: failedNow ? scheme.error : scheme.onSurfaceVariant,
      ),
    );
    final button = Semantics(
      hint: '$device becomes read-only',
      child: FilledButton(
        onPressed: widget.busy ? null : widget.onTakeOver,
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingMd,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        child: _StableLabel(
          shown: shownLabel,
          reserved: [actionLabel, _retryLabel],
        ),
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingMd,
            vertical: FluttyTheme.spacingSm,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // With large text on a phone the button would squeeze the
              // device name into a sliver; put it under the text instead.
              final scale = MediaQuery.textScalerOf(context).scale(1);
              if (constraints.maxWidth / scale < _stackBelowWidth) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        icon,
                        const SizedBox(width: FluttyTheme.spacingSm),
                        Expanded(child: labels),
                      ],
                    ),
                    const SizedBox(height: FluttyTheme.spacingSm),
                    button,
                  ],
                );
              }
              return Row(
                children: [
                  icon,
                  const SizedBox(width: FluttyTheme.spacingSm),
                  Expanded(child: labels),
                  const SizedBox(width: FluttyTheme.spacingSm),
                  button,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // Width, in unscaled logical pixels, below which the button moves under
  // the text: a phone at about 1.4x text size or more.
  static const _stackBelowWidth = 260.0;
  static const _retryLabel = 'Try again';
}

String _sentenceCase(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// Shows [shown] at the width of the widest of [reserved], so the button does
/// not change size, and shift the text beside it, as its label changes.
class _StableLabel extends StatelessWidget {
  const _StableLabel({required this.shown, required this.reserved});

  final String shown;
  final List<String> reserved;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      for (final label in reserved)
        if (label != shown)
          Visibility.maintain(visible: false, child: Text(label)),
      Text(shown),
    ],
  );
}
