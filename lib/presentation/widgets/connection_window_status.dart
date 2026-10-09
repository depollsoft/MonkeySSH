/// Attention-first ordering and status chips for a connection's window list.
///
/// Native rows show state reported by the app or the host bridge. Terminal
/// rows show what the program reported (bell, notification escape, OSC 9;4
/// progress) and otherwise output timing, which is drawn as an outlined chip
/// so inferred activity never looks like a reported state.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_usage_rings.dart';
import '../../domain/models/connection_attention.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/models/terminal_progress.dart';
import '../../domain/models/tmux_state.dart';
import 'acp_session_presentation.dart';
import 'attention_presentation.dart';
import 'mux_window_status_badge.dart';
import 'tmux_window_navigator.dart' show MuxWindowProjection;

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
Iterable<(AgentLaunchTool, String?)> connectionWindowQuotaIdentities({
  required List<TmuxWindow> windows,
  required List<AcpSessionState> sessions,
}) sync* {
  for (final window in windows) {
    if (window.isNativeAcp) continue;
    final tool = window.foregroundAgentTool;
    if (tool != null) yield (tool, window.agentModelProvider);
  }
  for (final session in sessions) {
    final tool = agentLaunchToolForBuiltinAcpProviderId(session.key.providerId);
    if (tool != null) yield (tool, piUsageModelProvider(session));
  }
}

/// Merges server windows with tracked native sessions and orders them by
/// attention, then recency, then window number.
///
/// A tracked session bound to a server window is shown once, as that window.
/// Sessions without a server window get numbers after the last server window,
/// matching the terminal's window navigator.
List<ConnectionWindowEntry> buildConnectionWindowEntries({
  required List<TmuxWindow> windows,
  required List<AcpSessionState> sessions,
  Map<String, MonkeyMuxAcpBridgeMetadata> bridges =
      const <String, MonkeyMuxAcpBridgeMetadata>{},
  Set<(AgentLaunchTool, String?)> lowQuota =
      const <(AgentLaunchTool, String?)>{},
  DateTime? now,
}) {
  final projection = MuxWindowProjection(windows, sessions);
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
          if (window != null) terminalWindowLastActivity(window),
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
          session: projection.sessionForWindow(window),
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
                terminalWindowRecentlyActive(window, now: now),
            lastActivity: terminalWindowLastActivity(window),
          ),
        ),
    for (final session in projection.orphanSessions)
      native(
        index: projection.nativeIndices[session.key]!,
        providerId: session.key.providerId,
        session: session,
        bridge: bridges[session.key.bridgeId],
      ),
  ];
  return entries
    ..sort((a, b) => compareAttentionSortKeys(a.sortKey, b.sortKey));
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
        final display = session == null
            ? const AcpStatusDisplay(
                label: 'native',
                icon: Icons.smart_toy_outlined,
                tone: AcpStatusTone.neutral,
              )
            : acpStatusDisplay(session.status);
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
  final last = terminalWindowLastActivity(window);
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
  final last = terminalWindowLastActivity(window);
  if (last == null) return null;
  final age = now.difference(last);
  const quietAfter = Duration(seconds: terminalQuietAfterSeconds + 1);
  if (age < quietAfter) return quietAfter - age;
  if (age.inHours < 1) {
    return Duration(minutes: age.inMinutes + 1) - age;
  }
  if (age.inDays < 1) return Duration(hours: age.inHours + 1) - age;
  return null;
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
