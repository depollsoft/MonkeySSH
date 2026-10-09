/// Attention-first ordering and status chips for a connection's window list.
///
/// Native rows show state reported by the app or the host bridge. Terminal
/// rows show what the program reported (bell, notification escape, OSC 9;4
/// progress) and otherwise output timing, which is drawn as an outlined chip
/// so inferred activity never looks like a reported state.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_usage_rings.dart';
import '../../domain/models/connection_attention.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/models/terminal_progress.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/connection_attention_provider.dart';
import 'acp_session_presentation.dart';
import 'attention_presentation.dart';
import 'mux_window_status_badge.dart';

/// One row of a connection's window list.
@immutable
class ConnectionWindowEntry {
  /// Creates an entry.
  const ConnectionWindowEntry({
    required this.index,
    required this.sortKey,
    this.window,
    this.session,
    this.bridge,
    this.isNative = false,
  });

  /// Window number shown on the row.
  final int index;

  /// Server window, when the multiplexer reports one.
  final TmuxWindow? window;

  /// Tracked native session, when the app has one for this window.
  final AcpSessionState? session;

  /// Host-reported bridge metadata, when polled.
  final MonkeyMuxAcpBridgeMetadata? bridge;

  /// Whether this row is a native agent window.
  final bool isNative;

  /// Attention, activity and recency used to order the row.
  final AttentionSortKey sortKey;

  /// Most urgent attention reason, if any.
  AttentionReason? get reason => sortKey.reason;
}

/// Agent identities (tool plus Pi's model provider) whose account allowance
/// can mark rows in [windows] and [sessions] as low on quota.
///
/// Native server windows count even when no local session tracks them.
Iterable<(AgentLaunchTool, String?)> connectionWindowQuotaIdentities({
  required List<TmuxWindow> windows,
  required List<AcpSessionState> sessions,
}) sync* {
  for (final window in windows) {
    final tool = window.isNativeAcp
        ? agentLaunchToolForBuiltinAcpProviderId(window.nativeAcpProviderId!)
        : window.foregroundAgentTool;
    if (tool != null) {
      yield (tool, window.isNativeAcp ? null : window.agentModelProvider);
    }
  }
  for (final session in sessions) {
    final tool = agentLaunchToolForBuiltinAcpProviderId(session.key.providerId);
    if (tool != null) yield (tool, piUsageModelProvider(session));
  }
}

int _byCreation(AcpSessionState a, AcpSessionState b) {
  final created = a.createdAt.compareTo(b.createdAt);
  return created != 0 ? created : a.key.value.compareTo(b.key.value);
}

/// Merges server windows with tracked native sessions and orders them by
/// attention, then recency, then window number.
///
/// Each native server window shows the session the terminal's window
/// navigator binds to it, once. Sessions whose bridge has no server window
/// number after the last server window in the navigator's order, and forks
/// that share a bound bridge follow them, so none is dropped.
List<ConnectionWindowEntry> buildConnectionWindowEntries({
  required List<TmuxWindow> windows,
  required List<AcpSessionState> sessions,
  Map<String, MonkeyMuxAcpBridgeMetadata> bridges =
      const <String, MonkeyMuxAcpBridgeMetadata>{},
  Set<(AgentLaunchTool, String?)> lowQuota =
      const <(AgentLaunchTool, String?)>{},
  DateTime? now,
}) {
  final reference = now ?? DateTime.now();
  final boundByBridge = <(String, String), AcpSessionState>{
    for (final session in sessions)
      (session.key.bridgeId, session.key.providerId): session,
  };
  final serverBridges = <String>{};
  final bound = <AcpSessionKey>{};
  var nextIndex = 0;
  for (final window in windows) {
    nextIndex = math.max(nextIndex, window.index + 1);
    final bridgeId = window.nativeAcpBridgeId;
    if (bridgeId == null) continue;
    serverBridges.add(bridgeId);
    final session = boundByBridge[(bridgeId, window.nativeAcpProviderId ?? '')];
    if (session != null) bound.add(session.key);
  }
  final unbound = [
    ...sessions
        .where((session) => !serverBridges.contains(session.key.bridgeId))
        .toList()
      ..sort(_byCreation),
    ...sessions
        .where(
          (session) =>
              serverBridges.contains(session.key.bridgeId) &&
              !bound.contains(session.key),
        )
        .toList()
      ..sort(_byCreation),
  ];

  ConnectionWindowEntry native({
    required int index,
    required String providerId,
    TmuxWindow? window,
    AcpSessionState? session,
    MonkeyMuxAcpBridgeMetadata? bridge,
  }) {
    var reason = session != null
        ? acpSessionWaitingReason(session, bridge: bridge)
        : bridge == null
        ? null
        : bridgeWaitingReason(bridge);
    final tool = agentLaunchToolForBuiltinAcpProviderId(providerId);
    if (reason == null &&
        tool != null &&
        lowQuota.contains((tool, piUsageModelProvider(session)))) {
      reason = AttentionReason.lowQuota;
    }
    return ConnectionWindowEntry(
      index: index,
      window: window,
      session: session,
      bridge: bridge,
      isNative: true,
      sortKey: AttentionSortKey(
        index: index,
        reason: reason,
        active:
            nativeTurnState(session: session, bridge: bridge) ==
            NativeTurnState.running,
        lastActivity: _latest([
          session?.lastActivityAt,
          bridge?.lastActivity,
          if (window != null)
            terminalWindowLastActivity(window, now: reference),
        ]),
      ),
    );
  }

  final entries = <ConnectionWindowEntry>[
    for (final window in windows)
      if (window.isNativeAcp)
        native(
          index: window.index,
          providerId: window.nativeAcpProviderId!,
          window: window,
          session:
              boundByBridge[(
                window.nativeAcpBridgeId!,
                window.nativeAcpProviderId!,
              )],
          bridge: bridges[window.nativeAcpBridgeId],
        )
      else
        ConnectionWindowEntry(
          index: window.index,
          window: window,
          sortKey: AttentionSortKey(
            index: window.index,
            reason: terminalWindowAttentionReason(
              window,
              lowQuota: switch (window.foregroundAgentTool) {
                final tool? => lowQuota.contains((
                  tool,
                  window.agentModelProvider,
                )),
                null => false,
              },
            ),
            active:
                terminalProgressIsRunning(window.terminalProgress) ||
                terminalWindowRecentlyActive(window, now: reference),
            lastActivity: terminalWindowLastActivity(window, now: reference),
          ),
        ),
    for (final session in unbound)
      native(
        index: nextIndex++,
        providerId: session.key.providerId,
        session: session,
        bridge: bridges[session.key.bridgeId],
      ),
  ];
  return entries
    ..sort((a, b) => compareAttentionSortKeys(a.sortKey, b.sortKey));
}

/// Attention inputs for one connection's window list.
///
/// Reads bridge metadata and quota rings only while the list is on screen,
/// and keeps the last values otherwise, so a dialog or a covering route does
/// not reshuffle rows underneath it. Also re-sorts the list when an inferred
/// "active" terminal row goes quiet, which no window event announces.
class ConnectionAttentionInputs {
  /// Creates the inputs; [onResort] rebuilds the owning list.
  ConnectionAttentionInputs({required this.onResort});

  /// Called when the order may have changed without a new window event.
  final VoidCallback onResort;

  Map<String, MonkeyMuxAcpBridgeMetadata> _bridges =
      const <String, MonkeyMuxAcpBridgeMetadata>{};
  Set<(AgentLaunchTool, String?)> _lowQuota =
      const <(AgentLaunchTool, String?)>{};
  Timer? _resort;

  /// Builds the ordered entries for [windows] and [sessions] on [hostId].
  List<ConnectionWindowEntry> entries(
    BuildContext context,
    WidgetRef ref, {
    required List<TmuxWindow> windows,
    required List<AcpSessionState> sessions,
    required int? hostId,
    required bool usesMonkeyMux,
    required SshSession? session,
    DateTime? now,
  }) {
    if (attentionSurfaceVisible(context)) {
      _bridges = hostId != null && usesMonkeyMux
          ? ref.watch(connectionBridgeMetadataProvider).forHost(hostId)
          : const <String, MonkeyMuxAcpBridgeMetadata>{};
      _lowQuota = watchLowQuotaTools(
        context,
        ref,
        session: session,
        tools: connectionWindowQuotaIdentities(
          windows: windows,
          sessions: sessions,
        ),
      );
    }
    final reference = now ?? DateTime.now();
    final entries = buildConnectionWindowEntries(
      windows: windows,
      sessions: sessions,
      bridges: _bridges,
      lowQuota: _lowQuota,
      now: reference,
    );
    _resort?.cancel();
    final wait = connectionWindowsNextResort(entries, now: reference);
    _resort = wait == null ? null : Timer(wait, onResort);
    return entries;
  }

  /// Cancels the pending re-sort.
  void dispose() {
    _resort?.cancel();
    _resort = null;
  }
}

/// When an inferred "active" row in [entries] goes quiet, so the list can
/// re-sort at that moment rather than at the next window event.
Duration? connectionWindowsNextResort(
  List<ConnectionWindowEntry> entries, {
  required DateTime now,
}) {
  Duration? soonest;
  for (final entry in entries) {
    final window = entry.window;
    if (entry.isNative || window == null || entry.reason != null) continue;
    if (terminalProgressIsRunning(window.terminalProgress)) continue;
    final epoch = window.lastActivityEpochSeconds;
    if (epoch == null) continue;
    final age = now.difference(
      DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
    );
    const quietAfter = Duration(seconds: terminalQuietAfterSeconds + 1);
    if (age >= quietAfter) continue;
    final wait = quietAfter - age;
    if (soonest == null || wait < soonest) soonest = wait;
  }
  return soonest;
}

DateTime? _latest(Iterable<DateTime?> times) {
  DateTime? latest;
  for (final time in times) {
    if (time != null && (latest == null || time.isAfter(latest))) {
      latest = time;
    }
  }
  return latest;
}

/// Whether OSC 9;4 progress reports work underway.
bool terminalProgressIsRunning(TerminalProgress? progress) =>
    progress?.state == TerminalProgressState.normal ||
    progress?.state == TerminalProgressState.indeterminate;

/// Compact status chip for a [ConnectionWindowEntry].
///
/// Reported states are filled pills with an icon and a label. Terminal output
/// timing is outlined and worded differently (`active` / `quiet`) because the
/// program never said it was running or idle.
class ConnectionWindowStatusChip extends StatefulWidget {
  /// Creates a status chip.
  const ConnectionWindowStatusChip({required this.entry, this.now, super.key});

  /// Row to describe.
  final ConnectionWindowEntry entry;

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  State<ConnectionWindowStatusChip> createState() =>
      _ConnectionWindowStatusChipState();
}

/// What a chip shows and whether it was reported or inferred.
@immutable
class ConnectionWindowStatus {
  /// Creates a status descriptor.
  const ConnectionWindowStatus({
    required this.label,
    required this.icon,
    required this.tone,
    required this.reported,
    required this.semanticsLabel,
  });

  /// Short visible label.
  final String label;

  /// Icon paired with [label].
  final IconData icon;

  /// Semantic tone.
  final AcpStatusTone tone;

  /// Whether a program, agent or host reported this state.
  final bool reported;

  /// Full screen-reader description.
  final String semanticsLabel;
}

/// Resolves the chip for [entry] at [now].
ConnectionWindowStatus connectionWindowStatus(
  ConnectionWindowEntry entry, {
  required DateTime now,
}) {
  final kind = entry.isNative ? 'native agent' : 'terminal window';
  final reason = entry.reason;
  if (reason != null) {
    return ConnectionWindowStatus(
      label: reason.label,
      icon: reason.icon,
      tone: reason.tone,
      reported: true,
      semanticsLabel: '$kind ${reason.description}',
    );
  }
  if (entry.isNative) {
    final session = entry.session;
    switch (nativeTurnState(session: session, bridge: entry.bridge)) {
      case NativeTurnState.running:
        return ConnectionWindowStatus(
          label: 'running',
          icon: Icons.play_arrow,
          tone: AcpStatusTone.active,
          reported: true,
          semanticsLabel: '$kind running, reported',
        );
      case NativeTurnState.idle:
        return ConnectionWindowStatus(
          label: 'idle',
          icon: Icons.circle_outlined,
          tone: AcpStatusTone.neutral,
          reported: true,
          semanticsLabel: '$kind idle, reported',
        );
      case NativeTurnState.unknown:
        final display = switch (session?.status) {
          null => const AcpStatusDisplay(
            label: 'native',
            icon: Icons.smart_toy_outlined,
            tone: AcpStatusTone.neutral,
          ),
          // Not the turn's "idle": nothing has attached to the bridge yet.
          AcpConnectionStatus.idle => const AcpStatusDisplay(
            label: 'starting',
            icon: Icons.sync,
            tone: AcpStatusTone.neutral,
          ),
          final AcpConnectionStatus status => acpStatusDisplay(status),
        };
        return ConnectionWindowStatus(
          label: display.label,
          icon: display.icon,
          tone: display.tone,
          reported: true,
          semanticsLabel: '$kind ${display.label}',
        );
    }
  }
  final window = entry.window!;
  final progress = window.terminalProgress;
  if (terminalProgressIsRunning(progress)) {
    final percentage = progress!.percentage;
    final label = percentage == null ? 'working' : '$percentage%';
    return ConnectionWindowStatus(
      label: label,
      icon: Icons.autorenew,
      tone: AcpStatusTone.active,
      reported: true,
      semanticsLabel: '$kind progress $label, reported by the program',
    );
  }
  if (terminalWindowRecentlyActive(window, now: now)) {
    return ConnectionWindowStatus(
      label: 'active',
      icon: Icons.graphic_eq,
      tone: AcpStatusTone.neutral,
      reported: false,
      semanticsLabel: '$kind active, inferred from recent output',
    );
  }
  final last = terminalWindowLastActivity(window, now: now);
  final age = last == null ? null : _coarseAge(now.difference(last));
  return ConnectionWindowStatus(
    label: age == null ? 'quiet' : 'quiet $age',
    icon: Icons.schedule,
    tone: AcpStatusTone.neutral,
    reported: false,
    semanticsLabel: age == null
        ? '$kind quiet, inferred from output'
        : '$kind quiet for $age, inferred from output',
  );
}

String? _coarseAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return null;
  if (age.inHours < 1) return '${age.inMinutes}m';
  if (age.inDays < 1) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// When [entry]'s inferred label next changes, if it can change on its own.
Duration? _nextLabelChange(ConnectionWindowEntry entry, DateTime now) {
  if (entry.isNative || entry.reason != null) return null;
  final window = entry.window!;
  if (terminalProgressIsRunning(window.terminalProgress)) return null;
  // An idle-only snapshot never ages, so only a reported epoch can roll over.
  final epoch = window.lastActivityEpochSeconds;
  if (epoch == null) return null;
  final age = now.difference(DateTime.fromMillisecondsSinceEpoch(epoch * 1000));
  const quietAfter = Duration(seconds: terminalQuietAfterSeconds + 1);
  if (age < quietAfter) return quietAfter - age;
  if (age.inHours < 1) {
    return Duration(minutes: age.inMinutes + 1) - age;
  }
  if (age.inDays < 1) return Duration(hours: age.inHours + 1) - age;
  return Duration(days: age.inDays + 1) - age;
}

class _ConnectionWindowStatusChipState
    extends State<ConnectionWindowStatusChip> {
  Timer? _refresh;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _scheduleRefresh(DateTime now) {
    _refresh?.cancel();
    final wait = _nextLabelChange(widget.entry, now);
    _refresh = wait == null
        ? null
        : Timer(wait, () {
            if (mounted) setState(() {});
          });
  }

  @override
  Widget build(BuildContext context) {
    final now = _now();
    _scheduleRefresh(now);
    final status = connectionWindowStatus(widget.entry, now: now);
    final scheme = Theme.of(context).colorScheme;
    if (status.reported) {
      final (foreground, background) = attentionToneColors(scheme, status.tone);
      return MuxWindowStatusBadge(
        semanticsLabel: status.semanticsLabel,
        label: status.label,
        icon: status.icon,
        foregroundColor: foreground,
        backgroundColor: background,
      );
    }
    return InferredActivityChip(
      semanticsLabel: status.semanticsLabel,
      label: status.label,
      icon: status.icon,
    );
  }
}

/// Outlined pill for activity inferred from output timing.
class InferredActivityChip extends StatelessWidget {
  /// Creates an outlined activity pill.
  const InferredActivityChip({
    required this.semanticsLabel,
    required this.label,
    required this.icon,
    super.key,
  });

  /// Screen-reader label, which says the state is inferred.
  final String semanticsLabel;

  /// Short visible label.
  final String label;

  /// Icon shown before [label].
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: DecoratedBox(
        key: const ValueKey('inferred-activity-chip'),
        decoration: BoxDecoration(
          // Muted ink, not the hairline: the outline is what marks the state
          // as inferred, so it has to stay visible on every surface.
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
