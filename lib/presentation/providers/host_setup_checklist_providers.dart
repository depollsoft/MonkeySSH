import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/acp_recent_session.dart';
import '../../domain/services/app_review_demo_service.dart';
import '../../domain/services/host_setup_checklist_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import 'entity_list_providers.dart';

/// Persisted checklist state for every host.
final hostSetupPersistedStateProvider =
    AsyncNotifierProvider<
      HostSetupPersistedStateNotifier,
      Map<int, HostSetupPersistedState>
    >(HostSetupPersistedStateNotifier.new);

/// Loads persisted checklist state and applies changes to it.
class HostSetupPersistedStateNotifier
    extends AsyncNotifier<Map<int, HostSetupPersistedState>> {
  @override
  Future<Map<int, HostSetupPersistedState>> build() {
    ref.watch(settingsGenerationProvider);
    return ref.watch(hostSetupChecklistStoreProvider).load();
  }

  /// Records [steps] as done for [hostId].
  Future<void> markDone(int hostId, Set<HostSetupStep> steps) async {
    if (steps.isEmpty) return;
    final store = ref.read(hostSetupChecklistStoreProvider);
    await store.markDone(hostId, steps);
    if (ref.mounted) state = AsyncData(await store.load());
  }

  /// Hides the checklist for [hostId].
  Future<void> dismiss(int hostId) async {
    final store = ref.read(hostSetupChecklistStoreProvider);
    await store.dismiss(hostId);
    if (ref.mounted) state = AsyncData(await store.load());
  }
}

/// Hosts where a native agent session has started, which proves an agent
/// there is signed in. The ACP manager records a recent entry as soon as a
/// session starts. Read once and refreshed when a host is probed or its
/// checklist sheet opens.
final hostIdsWithAgentSessionsProvider = FutureProvider<Set<int>>((ref) async {
  ref.watch(settingsGenerationProvider);
  return _decodeRecentHostIds(
    await ref
        .watch(settingsServiceProvider)
        .getString(SettingKeys.acpRecentSessions),
  );
});

Set<int> _decodeRecentHostIds(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const {};
    return {
      for (final entry in decoded)
        if (AcpRecentSessionRef.tryFromJson(entry) case final ref?) ref.hostId,
    };
  } on FormatException {
    return const {};
  }
}

/// The first connected connection for a host, if any.
final hostConnectedConnectionIdProvider = Provider.autoDispose
    .family<int?, int>((ref, hostId) {
      final sessions = ref.read(activeSessionsProvider.notifier);
      return ref.watch(
        activeSessionsProvider.select(
          (states) => sessions
              .getConnectionsForHost(hostId)
              .firstWhereOrNull(
                (id) => states[id] == SshConnectionState.connected,
              ),
        ),
      );
    });

/// In-memory probe results, keyed by host ID.
final hostSetupProbeResultsProvider =
    NotifierProvider<
      HostSetupProbeResultsNotifier,
      Map<int, HostSetupProbeResult>
    >(HostSetupProbeResultsNotifier.new);

/// Runs checklist probes once per connection and remembers their results.
class HostSetupProbeResultsNotifier
    extends Notifier<Map<int, HostSetupProbeResult>> {
  final _inFlight = <int>{};

  @override
  Map<int, HostSetupProbeResult> build() => const {};

  /// Probes [connectionId] for [hostId] unless it already ran.
  Future<void> ensureProbed(int hostId, int connectionId) async {
    if (state[hostId]?.connectionId == connectionId ||
        !_inFlight.add(connectionId)) {
      return;
    }
    try {
      final session = ref.read(sshServiceProvider).getSession(connectionId);
      if (session == null) return;
      final result = await ref.read(hostSetupProberProvider).probe(session);
      if (!ref.mounted) return;
      state = {...state, hostId: result};
      ref.invalidate(hostIdsWithAgentSessionsProvider);
      await ref.read(hostSetupPersistedStateProvider.notifier).markDone(
        hostId,
        {
          if (result.monkeyMuxInstalled ?? false) HostSetupStep.monkeyMux,
          if (result.agentsDetected ?? false) HostSetupStep.agents,
        },
      );
    } finally {
      _inFlight.remove(connectionId);
    }
  }

  /// Forgets [hostId]'s probe so the next connected build checks again.
  void forget(int hostId) {
    if (!state.containsKey(hostId)) return;
    state = Map.of(state)..remove(hostId);
  }
}

/// The setup checklist for one host, or null when it should not appear (the
/// host is gone, is the App Review demo host, or state is still loading).
final hostSetupChecklistProvider = Provider.autoDispose
    .family<HostSetupChecklist?, int>((ref, hostId) {
      final host = ref.watch(
        allHostsProvider.select(
          (hosts) =>
              hosts.asData?.value.firstWhereOrNull((host) => host.id == hostId),
        ),
      );
      if (host == null || isAppReviewDemoHost(host)) return null;
      final persisted = ref.watch(
        hostSetupPersistedStateProvider.select(
          (value) => value.whenData((states) => states[hostId]),
        ),
      );
      final recentsLoaded = ref.watch(
        hostIdsWithAgentSessionsProvider.select((value) => value.hasValue),
      );
      if (!persisted.hasValue || !recentsLoaded) return null;
      return computeHostSetupChecklist(
        host: host,
        persisted: persisted.value ?? const HostSetupPersistedState(),
        probe: ref.watch(
          hostSetupProbeResultsProvider.select((results) => results[hostId]),
        ),
        hasAgentSession: ref.watch(
          hostIdsWithAgentSessionsProvider.select(
            (ids) => ids.value?.contains(hostId) ?? false,
          ),
        ),
        isConnected:
            ref.watch(hostConnectedConnectionIdProvider(hostId)) != null,
      );
    });
