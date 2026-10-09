/// Attention data for the Connections tab and the native session switcher.
///
/// Polls safe MonkeyMux bridge metadata for connected hosts while a surface
/// that shows it is on screen, and merges it with tracked native session state
/// into a "waiting on you" list. Nothing here is persisted: disconnected hosts
/// drop out on the next poll, the last snapshot is kept in memory for a short
/// grace period only, and no window title or path is stored or logged.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_usage_rings.dart';
import '../../domain/models/connection_attention.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/acp_notification_target.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monkeymux_acp_bridge_service.dart';
import '../../domain/services/ssh_exec_queue.dart';
import '../../domain/services/ssh_service.dart';
import '../widgets/acp_session_presentation.dart';
import 'agent_usage_rings_provider.dart';
import 'entity_list_providers.dart';

/// How often visible attention surfaces refresh host-reported bridge state.
///
/// A permission request on a detached or untracked native session reaches
/// the "waiting on you" list within one interval. Attached sessions update
/// immediately from their own state.
const connectionAttentionPollInterval = Duration(seconds: 5);

/// Lists safe bridge metadata over one SSH connection.
typedef ConnectionBridgeLister =
    Future<List<MonkeyMuxAcpBridgeMetadata>> Function(SshSession session);

/// Reads bridge metadata without ever prompting to install MonkeyMux.
///
/// Runs at low exec priority, behind user-visible work on the connection, and
/// without the routine debug entries a five-second poll would otherwise add
/// to the diagnostics ring buffer.
final connectionBridgeListerProvider = Provider<ConnectionBridgeLister>((ref) {
  final service = ref.watch(monkeyMuxAcpBridgeServiceProvider);
  return (session) => DiagnosticsLogService.runWithoutDebugEntries(
    () => service.list(session, priority: SshExecPriority.low),
  );
});

/// Whether attention surfaces under [context] are on screen.
///
/// Both checks are needed. An opaque route above disables tickers, but the
/// terminal route is not opaque (predictive back reveals Home), so Home keeps
/// its tickers under it; it is only the current route while nothing covers it.
bool attentionSurfaceVisible(BuildContext context) =>
    TickerMode.valuesOf(context).enabled &&
    (ModalRoute.isCurrentOf(context) ?? true);

/// Bridges reported by one connected host.
@immutable
final class HostBridges {
  /// Creates a host's bridge list.
  HostBridges({
    required this.connectionId,
    required Iterable<MonkeyMuxAcpBridgeMetadata> bridges,
  }) : byId = Map.unmodifiable({
         for (final bridge in bridges) bridge.id: bridge,
       });

  /// Connection the metadata was read over.
  final int connectionId;

  /// Bridges by opaque bridge id.
  final Map<String, MonkeyMuxAcpBridgeMetadata> byId;

  static Object _signature(MonkeyMuxAcpBridgeMetadata bridge) => (
    bridge.id,
    bridge.providerId,
    bridge.sessionId,
    bridge.cwd,
    bridge.provider,
    bridge.state,
    bridge.pendingRequestCount,
    bridge.inFlightTurnCount,
    bridge.lastActivity,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostBridges &&
          connectionId == other.connectionId &&
          setEquals(
            byId.values.map(_signature).toSet(),
            other.byId.values.map(_signature).toSet(),
          );

  @override
  int get hashCode => Object.hash(
    connectionId,
    Object.hashAllUnordered(byId.values.map(_signature)),
  );
}

/// Latest host-reported bridge metadata for connected hosts.
@immutable
final class HostBridgeMetadata {
  /// Creates a snapshot from per-host bridge lists.
  HostBridgeMetadata(Map<int, HostBridges> hosts)
    : hosts = Map.unmodifiable(hosts);

  /// No hosts polled yet.
  static final empty = HostBridgeMetadata(const <int, HostBridges>{});

  /// Bridge lists by host id.
  final Map<int, HostBridges> hosts;

  /// Metadata for [bridgeId] on [hostId], when the host reported it.
  MonkeyMuxAcpBridgeMetadata? bridge(int hostId, String bridgeId) =>
      hosts[hostId]?.byId[bridgeId];

  /// All bridges on [hostId], keyed by bridge id.
  Map<String, MonkeyMuxAcpBridgeMetadata> forHost(int hostId) =>
      hosts[hostId]?.byId ?? const <String, MonkeyMuxAcpBridgeMetadata>{};

  /// Returns a copy with [hostId] replaced or removed.
  HostBridgeMetadata withHost(int hostId, HostBridges? bridges) {
    final next = Map.of(hosts);
    if (bridges == null) {
      next.remove(hostId);
    } else {
      next[hostId] = bridges;
    }
    return HostBridgeMetadata(next);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostBridgeMetadata && mapEquals(hosts, other.hosts);

  @override
  int get hashCode => Object.hashAllUnordered(
    hosts.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

/// Polls bridge metadata for connected MonkeyMux hosts while watched.
///
/// Watch it only from visible surfaces (see [attentionSurfaceVisible]).
/// Polling stops as soon as the last watcher leaves; the snapshot is kept for
/// [connectionAttentionRetainAfterHidden] so a closing dialog does not flash
/// rows, then dropped.
final connectionBridgeMetadataProvider =
    NotifierProvider.autoDispose<
      ConnectionBridgeMetadataNotifier,
      HostBridgeMetadata
    >(ConnectionBridgeMetadataNotifier.new);

/// How long an unwatched snapshot stays in memory before it is dropped.
const connectionAttentionRetainAfterHidden = Duration(seconds: 30);

/// How long polling continues after the last watcher leaves.
const _pauseAfterUnwatched = Duration(seconds: 1);

/// Longest wait, in poll intervals, before retrying a host whose list failed.
const _maxFailureBackoffIntervals = 12;

/// Refreshes [HostBridgeMetadata] every [connectionAttentionPollInterval].
class ConnectionBridgeMetadataNotifier extends Notifier<HostBridgeMetadata> {
  Timer? _timer;
  Timer? _pause;
  Timer? _release;
  AppLifecycleListener? _lifecycle;
  bool _backgrounded = false;
  final _inFlight = <int>{};
  final _failures = <int, int>{};
  final _skipPolls = <int, int>{};

  @override
  HostBridgeMetadata build() {
    final link = ref.keepAlive();
    ref
      ..onCancel(() {
        // A dependent provider that rebuilds (for example on each new poll
        // result) unsubscribes and resubscribes a scheduler tick later.
        // Pausing and polling again at once would loop, so wait a moment for
        // a watcher to come back before pausing.
        _pause?.cancel();
        _pause = Timer(_pauseAfterUnwatched, () {
          _pause = null;
          _stopTimer();
          _release?.cancel();
          _release = Timer(connectionAttentionRetainAfterHidden, link.close);
        });
      })
      ..onResume(() {
        if (_pause != null) {
          _pause!.cancel();
          _pause = null;
          return;
        }
        _release?.cancel();
        _release = null;
        _startTimer();
        // Lifecycle callbacks may not read other providers; poll right after.
        _scheduleImmediatePoll();
      })
      ..onDispose(() {
        _stopTimer();
        _pause?.cancel();
        _release?.cancel();
        _lifecycle?.dispose();
      });
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _backgrounded = !_appVisible(WidgetsBinding.instance.lifecycleState);
    _startTimer();
    _scheduleImmediatePoll();
    return HostBridgeMetadata.empty;
  }

  void _scheduleImmediatePoll() => scheduleMicrotask(() {
    if (ref.mounted) unawaited(poll());
  });

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      connectionAttentionPollInterval,
      (_) => unawaited(poll()),
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  bool updateShouldNotify(
    HostBridgeMetadata previous,
    HostBridgeMetadata next,
  ) => previous != next;

  /// Desktop and split-screen windows stay visible while `inactive`, so only
  /// hidden, paused and detached apps stop polling.
  static bool _appVisible(AppLifecycleState? lifecycle) => switch (lifecycle) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => false,
  };

  void _onLifecycle(AppLifecycleState lifecycle) {
    if (!ref.mounted) return;
    if (!_appVisible(lifecycle)) {
      _backgrounded = true;
      // Counts read before backgrounding are stale by the time anyone looks.
      state = HostBridgeMetadata.empty;
      return;
    }
    if (_backgrounded) {
      _backgrounded = false;
      unawaited(poll());
    }
  }

  /// Picks one connected session per host: a MonkeyMux workspace connection
  /// when there is one, otherwise any connection to a host with tracked
  /// native sessions. Hosts without either are never touched.
  Map<int, SshSession> _targets() {
    final states = ref.read(activeSessionsProvider);
    final sessions = ref.read(activeSessionsProvider.notifier);
    final nativeHosts = {
      for (final session in ref.read(acpSessionManagerProvider).state.sessions)
        session.key.hostId,
    };
    final targets = <int, SshSession>{};
    for (final entry in states.entries) {
      if (entry.value != SshConnectionState.connected) continue;
      final session = sessions.getSession(entry.key);
      if (session == null) continue;
      final usesMonkeyMux =
          session.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
      if (!usesMonkeyMux && !nativeHosts.contains(session.hostId)) continue;
      final existing = targets[session.hostId];
      if (existing == null ||
          (usesMonkeyMux &&
              existing.remoteMuxBackend != RemoteMuxBackend.monkeyMux)) {
        targets[session.hostId] = session;
      }
    }
    return targets;
  }

  /// Polls every target host once. Exposed for tests.
  @visibleForTesting
  Future<void> poll() async {
    if (!ref.mounted || _backgrounded) return;
    final targets = _targets();
    var next = state;
    for (final hostId in state.hosts.keys) {
      if (!targets.containsKey(hostId)) next = next.withHost(hostId, null);
    }
    _failures.removeWhere((hostId, _) => !targets.containsKey(hostId));
    _skipPolls.removeWhere((hostId, _) => !targets.containsKey(hostId));
    state = next;
    final lister = ref.read(connectionBridgeListerProvider);
    await Future.wait([
      for (final MapEntry(key: hostId, value: session) in targets.entries)
        if (!_backingOff(hostId)) _pollHost(lister, hostId, session),
    ]);
  }

  bool _backingOff(int hostId) {
    final skip = _skipPolls[hostId] ?? 0;
    if (skip <= 0) return false;
    _skipPolls[hostId] = skip - 1;
    return true;
  }

  /// Whether [session] is still the connection polled for [hostId].
  bool _stillTarget(int hostId, SshSession session) =>
      ref.mounted && !_backgrounded && identical(_targets()[hostId], session);

  Future<void> _pollHost(
    ConnectionBridgeLister lister,
    int hostId,
    SshSession session,
  ) async {
    if (!_inFlight.add(hostId)) return;
    try {
      final bridges = await lister(session);
      // The host may have disconnected, or the app gone to the background,
      // while the list was in flight; never resurrect it.
      if (!_stillTarget(hostId, session)) return;
      _failures.remove(hostId);
      _skipPolls.remove(hostId);
      state = state.withHost(
        hostId,
        HostBridges(connectionId: session.connectionId, bridges: bridges),
      );
    } on Object catch (error) {
      if (!ref.mounted) return;
      // Stale counts would claim an agent is waiting when it may not be.
      state = state.withHost(hostId, null);
      final failures = (_failures[hostId] ?? 0) + 1;
      _failures[hostId] = failures;
      // An older helper without these fields fails every time; back off
      // 1, 2, 4 ... intervals up to a minute instead of opening a channel
      // every five seconds.
      _skipPolls[hostId] = math.min(
        (1 << math.min(failures - 1, 4)) - 1,
        _maxFailureBackoffIntervals - 1,
      );
      if (failures == 1) {
        DiagnosticsLogService.instance.info(
          'connections.attention',
          'bridge_poll_failed',
          fields: {
            'hostId': hostId,
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
    } finally {
      _inFlight.remove(hostId);
    }
  }
}

/// One native session that is blocked until the user answers.
@immutable
final class WaitingOnYouItem {
  /// Creates a waiting item.
  const WaitingOnYouItem({
    required this.reason,
    required this.key,
    required this.hostLabel,
    required this.title,
    required this.providerLabel,
    required this.since,
    required this.tracked,
    this.cwdSummary,
  });

  /// Why the session is blocked.
  final AttentionReason reason;

  /// Exact native session to open.
  final AcpSessionKey key;

  /// Saved host label, shown so the user knows which machine is waiting.
  final String hostLabel;

  /// Session title, or the provider label when the agent reported none.
  final String title;

  /// Provider display label.
  final String providerLabel;

  /// Short working-directory summary, when known.
  final String? cwdSummary;

  /// When the session started waiting, or its last reported activity.
  final DateTime since;

  /// Whether the app tracks this session. Untracked sessions open through
  /// the MonkeyMux window that hosts their bridge, which can reattach them.
  final bool tracked;

  /// Terminal identity used for the row's agent icon.
  AgentLaunchTool? get tool =>
      agentLaunchToolForBuiltinAcpProviderId(key.providerId);

  /// The session's chat, where its pending request is shown.
  String get chatLocation => buildAgentChatLocation(
    hostId: key.hostId,
    providerId: key.providerId,
    bridgeId: key.bridgeId,
    acpSessionId: key.acpSessionId,
  );

  /// The session inside the MonkeyMux window on [connectionId] that hosts its
  /// bridge, the same destination a notification tap resolves to.
  String terminalLocation(int connectionId) => Uri(
    path: '/terminal/${key.hostId}',
    queryParameters: <String, String>{
      'connectionId': '$connectionId',
      acpAgentChatProviderQueryKey: key.providerId,
      acpAgentChatBridgeQueryKey: key.bridgeId,
      acpAgentChatSessionQueryKey: key.acpSessionId,
    },
  ).toString();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaitingOnYouItem &&
          reason == other.reason &&
          key == other.key &&
          hostLabel == other.hostLabel &&
          title == other.title &&
          providerLabel == other.providerLabel &&
          cwdSummary == other.cwdSummary &&
          since == other.since &&
          tracked == other.tracked;

  @override
  int get hashCode => Object.hash(
    reason,
    key,
    hostLabel,
    title,
    providerLabel,
    cwdSummary,
    since,
    tracked,
  );
}

/// Value-equal list of waiting items, most urgent first.
@immutable
final class WaitingOnYouSnapshot {
  /// Creates a snapshot.
  WaitingOnYouSnapshot(Iterable<WaitingOnYouItem> items)
    : items = List.unmodifiable(items);

  /// Nothing is waiting.
  static final empty = WaitingOnYouSnapshot(const <WaitingOnYouItem>[]);

  /// Items in display order.
  final List<WaitingOnYouItem> items;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaitingOnYouSnapshot && listEquals(items, other.items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// Builds the "waiting on you" list from tracked sessions and host-reported
/// bridges on [connectedHosts].
///
/// Tracked sessions use their own state, falling back to bridge counts only
/// while detached. A host-reported request on an untracked bridge is listed
/// when the bridge names its provider and session, so it can be opened.
List<WaitingOnYouItem> buildWaitingOnYouItems({
  required List<AcpSessionState> sessions,
  required HostBridgeMetadata bridges,
  required Set<int> connectedHosts,
  required Map<int, String> hostLabels,
}) {
  String hostLabel(int hostId) => hostLabels[hostId] ?? 'Host $hostId';
  final items = <WaitingOnYouItem>[];
  final trackedBridges = <(int, String)>{};
  for (final session in sessions) {
    final hostId = session.key.hostId;
    trackedBridges.add((hostId, session.key.bridgeId));
    if (!connectedHosts.contains(hostId)) continue;
    final bridge = bridges.bridge(hostId, session.key.bridgeId);
    final reason = acpSessionWaitingReason(session, bridge: bridge);
    if (reason == null) continue;
    items.add(
      WaitingOnYouItem(
        reason: reason,
        key: session.key,
        hostLabel: hostLabel(hostId),
        title: acpSessionDisplayTitle(session),
        providerLabel: session.providerLabel,
        cwdSummary: acpCwdSummary(session.cwd),
        since: reason == AttentionReason.hostRequest && bridge != null
            ? bridge.lastActivity
            : acpSessionWaitingSince(session),
        tracked: true,
      ),
    );
  }
  for (final MapEntry(key: hostId, value: host) in bridges.hosts.entries) {
    if (!connectedHosts.contains(hostId)) continue;
    for (final bridge in host.byId.values) {
      if (trackedBridges.contains((hostId, bridge.id))) continue;
      final reason = bridgeWaitingReason(bridge);
      final providerId = bridge.providerId?.trim();
      final sessionId = bridge.sessionId?.trim();
      if (reason == null ||
          providerId == null ||
          providerId.isEmpty ||
          sessionId == null ||
          sessionId.isEmpty) {
        continue;
      }
      final label = bridge.provider.trim().isEmpty
          ? 'Native agent'
          : bridge.provider.trim();
      items.add(
        WaitingOnYouItem(
          reason: reason,
          key: AcpSessionKey.of(
            hostId: hostId,
            providerId: providerId,
            bridgeId: bridge.id,
            acpSessionId: sessionId,
          ),
          hostLabel: hostLabel(hostId),
          title: label,
          providerLabel: label,
          cwdSummary: bridge.cwd == null ? null : acpCwdSummary(bridge.cwd),
          since: bridge.lastActivity,
          tracked: false,
        ),
      );
    }
  }
  items.sort((a, b) {
    final reason = a.reason.index.compareTo(b.reason.index);
    if (reason != 0) return reason;
    final recency = b.since.compareTo(a.since);
    if (recency != 0) return recency;
    return a.key.value.compareTo(b.key.value);
  });
  return items;
}

/// Native sessions waiting on the user across every connected host.
///
/// Watching this starts [connectionBridgeMetadataProvider] polling.
final waitingOnYouProvider = Provider.autoDispose<WaitingOnYouSnapshot>((ref) {
  final manager = ref.watch(acpSessionManagerProvider);
  final sessions =
      ref.watch(acpSessionManagerStateProvider).asData?.value.sessions ??
      manager.state.sessions;
  final bridges = ref.watch(connectionBridgeMetadataProvider);
  final states = ref.watch(activeSessionsProvider);
  final activeSessions = ref.read(activeSessionsProvider.notifier);
  final connectedHosts = <int>{
    for (final entry in states.entries)
      if (entry.value == SshConnectionState.connected)
        ?activeSessions.getActiveConnection(entry.key)?.hostId,
  };
  final hosts = ref.watch(allHostsProvider).asData?.value ?? const <Host>[];
  final items = buildWaitingOnYouItems(
    sessions: sessions,
    bridges: bridges,
    connectedHosts: connectedHosts,
    hostLabels: {for (final host in hosts) host.id: host.label},
  );
  return items.isEmpty
      ? WaitingOnYouSnapshot.empty
      : WaitingOnYouSnapshot(items);
});

/// Resolves where Open should land for [item].
///
/// A tracked session opens its chat. An untracked one opens inside the
/// connected MonkeyMux workspace whose window hosts its bridge, found with the
/// same lookup a notification tap uses; with no such window (a bridge started
/// outside a workspace), its chat reattaches it directly.
Future<String> resolveWaitingOnYouLocation(
  WaitingOnYouItem item, {
  required Iterable<SshSession> sessions,
  required Future<List<TmuxWindow>> Function(SshSession, String) listWindows,
}) async {
  if (item.tracked) return item.chatLocation;
  final connectionId = await resolveAcpNotificationConnection(
    target: item.key,
    sessions: sessions,
    listWindows: listWindows,
  );
  return connectionId == null
      ? item.chatLocation
      : item.terminalLocation(connectionId);
}

/// Agent identities on [session]'s host whose reported allowance is low.
///
/// Each identity is a tool plus Pi's live model provider. Reads the same
/// account rings the terminal bar shows, so it is empty unless usage rings
/// are enabled. Watches nothing while [context] is offstage.
Set<(AgentLaunchTool, String?)> watchLowQuotaTools(
  BuildContext context,
  WidgetRef ref, {
  required SshSession? session,
  required Iterable<(AgentLaunchTool, String?)> tools,
}) {
  if (session == null || !attentionSurfaceVisible(context)) {
    return const <(AgentLaunchTool, String?)>{};
  }
  final low = <(AgentLaunchTool, String?)>{};
  for (final identity in tools.toSet()) {
    final (tool, modelProvider) = identity;
    if (!supportsAgentUsageRings(tool, modelProvider: modelProvider)) continue;
    final rings = ref
        .watch(
          agentUsageRingsProvider((
            session: session,
            tool: tool,
            modelProvider: modelProvider,
          )),
        )
        .asData
        ?.value;
    if (rings?.isLow ?? false) low.add(identity);
  }
  return low;
}
