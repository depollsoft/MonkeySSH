import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
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
String acpWriterDeviceName(MonkeyMuxAcpRemoteWriter writer) =>
    writer.label ?? 'another device';

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
    this.clock = DateTime.now,
    super.key,
  });

  /// Device that holds the chat's input.
  final MonkeyMuxAcpRemoteWriter writer;

  /// Moves the input to this device.
  final VoidCallback onTakeOver;

  /// Asks who holds the chat again, about once a minute while the app is in
  /// the foreground and the banner is visible, so the activity time follows
  /// the other device's use. A refresh still running skips the next one.
  final Future<void> Function()? onRefresh;

  /// Whether a take-over is already in progress.
  final bool busy;

  /// Time source for the relative activity label.
  final DateTime Function() clock;

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
    _lifecycle = state;
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefresh;
    final foreground =
        _lifecycle == null || _lifecycle == AppLifecycleState.resumed;
    if (refresh == null || _refreshing || !foreground || !_visible) return;
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
    _visible = TickerMode.valuesOf(context).enabled;
    final scheme = Theme.of(context).colorScheme;
    final mono = AcpChatTypography.monoStyleOf(context);
    final device = acpWriterDeviceName(widget.writer);
    final activity = formatAcpWriterActivity(
      widget.writer.lastActiveAt,
      widget.clock(),
    );
    final actionLabel = widget.writer.leaseLost ? 'Take back' : 'Take over';
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Controlled by $device, $activity. Read-only on this device.',
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
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.devices_other,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'controlled by $device',
                        style: mono.copyWith(
                          color: scheme.onSurface,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$activity · read-only here',
                        style: mono.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              Semantics(
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
                  child: Text(widget.busy ? 'Connecting' : actionLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
