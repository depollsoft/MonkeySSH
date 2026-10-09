/// The post-connect setup checklist shown on host rows: key login, MonkeyMux,
/// a detected coding agent, and a first signed-in agent session.
///
/// Completed steps are remembered per host; probe results that say a step is
/// still missing only live for the app run, so the checklist re-checks after a
/// restart instead of trusting stale negatives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_installer_service.dart';
import 'settings_service.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

/// Settings key holding completed and dismissed checklist state per host.
const hostSetupChecklistSettingKey = 'host_setup_checklist';

/// One checklist step, in the order the checklist suggests them.
enum HostSetupStep {
  /// The host signs in with a key instead of a saved password.
  keyLogin('key'),

  /// The MonkeyMux helper is installed on the host.
  monkeyMux('monkeymux'),

  /// At least one coding-agent CLI is on the host.
  agents('agents'),

  /// An agent session has started on the host, which needs a signed-in
  /// agent.
  agentSignIn('signed_in');

  const HostSetupStep(this.storageValue);

  /// Stable value persisted in settings.
  final String storageValue;
}

/// What the app knows about a step.
enum HostSetupStepStatus {
  /// The step is complete.
  done,

  /// The step still needs doing.
  missing,

  /// The app has not checked yet (usually because the host isn't connected).
  unknown,
}

/// Persisted checklist state for one host.
@immutable
class HostSetupPersistedState {
  /// Creates persisted state.
  const HostSetupPersistedState({
    this.done = const <HostSetupStep>{},
    this.dismissed = false,
  });

  /// Steps known to be complete.
  final Set<HostSetupStep> done;

  /// Whether the user hid the checklist for this host.
  final bool dismissed;

  @override
  bool operator ==(Object other) =>
      other is HostSetupPersistedState &&
      setEquals(other.done, done) &&
      other.dismissed == dismissed;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(done), dismissed);
}

/// Result of probing one connection.
@immutable
class HostSetupProbeResult {
  /// Creates a probe result. Null means the probe could not tell.
  const HostSetupProbeResult({
    required this.connectionId,
    this.monkeyMuxInstalled,
    this.agentsDetected,
  });

  /// Connection the probe ran on.
  final int connectionId;

  /// Whether the bundled MonkeyMux helper is installed.
  final bool? monkeyMuxInstalled;

  /// Whether any coding-agent CLI was found.
  final bool? agentsDetected;

  @override
  bool operator ==(Object other) =>
      other is HostSetupProbeResult &&
      other.connectionId == connectionId &&
      other.monkeyMuxInstalled == monkeyMuxInstalled &&
      other.agentsDetected == agentsDetected;

  @override
  int get hashCode =>
      Object.hash(connectionId, monkeyMuxInstalled, agentsDetected);
}

/// The checklist for one host.
@immutable
class HostSetupChecklist {
  /// Creates a checklist.
  const HostSetupChecklist({
    required this.hostId,
    required this.statuses,
    required this.dismissed,
    required this.hasConnected,
  });

  /// Saved host ID.
  final int hostId;

  /// Status of every step.
  final Map<HostSetupStep, HostSetupStepStatus> statuses;

  /// Whether the user hid the checklist.
  final bool dismissed;

  /// Whether the host has connected at least once.
  final bool hasConnected;

  /// Status of [step].
  HostSetupStepStatus statusOf(HostSetupStep step) =>
      statuses[step] ?? HostSetupStepStatus.unknown;

  /// The first step that is not done, when the app knows it is missing.
  ///
  /// Steps run in order, so an unchecked earlier step hides later ones.
  HostSetupStep? get nextStep {
    for (final step in HostSetupStep.values) {
      switch (statusOf(step)) {
        case HostSetupStepStatus.done:
          continue;
        case HostSetupStepStatus.missing:
          return step;
        case HostSetupStepStatus.unknown:
          return null;
      }
    }
    return null;
  }

  /// Number of completed steps.
  int get doneCount => HostSetupStep.values
      .where((step) => statusOf(step) == HostSetupStepStatus.done)
      .length;

  /// Whether every step is done.
  bool get isComplete => doneCount == HostSetupStep.values.length;

  /// Whether the host row should show the checklist.
  bool get isVisible => hasConnected && !dismissed && nextStep != null;

  /// Whether a connection probe could fill in unknown steps.
  bool get needsProbe =>
      !dismissed &&
      (statusOf(HostSetupStep.monkeyMux) == HostSetupStepStatus.unknown ||
          statusOf(HostSetupStep.agents) == HostSetupStepStatus.unknown);

  @override
  bool operator ==(Object other) =>
      other is HostSetupChecklist &&
      other.hostId == hostId &&
      mapEquals(other.statuses, statuses) &&
      other.dismissed == dismissed &&
      other.hasConnected == hasConnected;

  @override
  int get hashCode => Object.hash(
    hostId,
    Object.hashAllUnordered(statuses.entries.map((e) => (e.key, e.value))),
    dismissed,
    hasConnected,
  );
}

/// Whether [host] still signs in with a saved password and no key.
bool hostUsesPasswordOnly(Host host) =>
    host.keyId == null && (host.password?.isNotEmpty ?? false);

/// Builds the checklist for [host].
HostSetupChecklist computeHostSetupChecklist({
  required Host host,
  required HostSetupPersistedState persisted,
  required bool hasAgentSession,
  required bool isConnected,
  HostSetupProbeResult? probe,
}) {
  HostSetupStepStatus fromProbe(HostSetupStep step, {bool? value}) {
    if (persisted.done.contains(step) || value == true) {
      return HostSetupStepStatus.done;
    }
    return value == false
        ? HostSetupStepStatus.missing
        : HostSetupStepStatus.unknown;
  }

  return HostSetupChecklist(
    hostId: host.id,
    dismissed: persisted.dismissed,
    hasConnected: isConnected || host.lastConnectedAt != null,
    statuses: {
      HostSetupStep.keyLogin: hostUsesPasswordOnly(host)
          ? HostSetupStepStatus.missing
          : HostSetupStepStatus.done,
      HostSetupStep.monkeyMux: fromProbe(
        HostSetupStep.monkeyMux,
        value: probe?.monkeyMuxInstalled,
      ),
      HostSetupStep.agents: fromProbe(
        HostSetupStep.agents,
        value: probe?.agentsDetected,
      ),
      HostSetupStep.agentSignIn:
          hasAgentSession || persisted.done.contains(HostSetupStep.agentSignIn)
          ? HostSetupStepStatus.done
          : HostSetupStepStatus.missing,
    },
  );
}

/// Decodes the persisted settings value.
Map<int, HostSetupPersistedState> decodeHostSetupPersistedState(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};
  final states = <int, HostSetupPersistedState>{};
  for (final entry in decoded.entries) {
    final hostId = int.tryParse('${entry.key}');
    final value = entry.value;
    if (hostId == null || value is! Map) continue;
    final doneValues = value['done'];
    states[hostId] = HostSetupPersistedState(
      done: {
        if (doneValues is List)
          for (final step in HostSetupStep.values)
            if (doneValues.contains(step.storageValue)) step,
      },
      dismissed: value['dismissed'] == true,
    );
  }
  return states;
}

/// Reads and writes persisted checklist state.
class HostSetupChecklistStore {
  /// Creates a store over [settings].
  HostSetupChecklistStore(this._settings);

  final SettingsService _settings;

  /// Loads persisted state for every host.
  ///
  /// A one-shot read rather than a watched query: the checklist notifier
  /// applies its own writes, and widget tests can dispose it without leaving
  /// a stream-query timer behind.
  Future<Map<int, HostSetupPersistedState>> load() async =>
      decodeHostSetupPersistedState(
        await _settings.getString(hostSetupChecklistSettingKey),
      );

  /// Records [steps] as done for [hostId].
  Future<void> markDone(int hostId, Set<HostSetupStep> steps) {
    if (steps.isEmpty) return Future<void>.value();
    return _update(hostId, (current) {
      final done = <String>{
        ...(current['done'] as List?)?.whereType<String>() ?? const [],
        for (final step in steps) step.storageValue,
      };
      return {...current, 'done': done.toList()..sort()};
    });
  }

  /// Hides the checklist for [hostId].
  Future<void> dismiss(int hostId) =>
      _update(hostId, (current) => {...current, 'dismissed': true});

  Future<void> _update(
    int hostId,
    Map<String, dynamic> Function(Map<String, dynamic> current) change,
  ) => _settings.updateJson(hostSetupChecklistSettingKey, (current) {
    final next = Map<String, dynamic>.of(current ?? const {});
    final existing = next['$hostId'];
    next['$hostId'] = change(
      existing is Map<String, dynamic> ? existing : <String, dynamic>{},
    );
    return next;
  });
}

/// Provider for [HostSetupChecklistStore].
final hostSetupChecklistStoreProvider = Provider<HostSetupChecklistStore>(
  (ref) => HostSetupChecklistStore(ref.watch(settingsServiceProvider)),
);

/// Probes one connected session for checklist steps.
typedef HostSetupStepProbe = Future<bool?> Function(SshSession session);

/// Runs the checklist probes on a connected session.
class HostSetupProber {
  /// Creates a prober with the given step probes.
  HostSetupProber({
    required HostSetupStepProbe probeMonkeyMux,
    required HostSetupStepProbe probeAgents,
    DiagnosticsLogger? diagnostics,
  }) : _probeMonkeyMux = probeMonkeyMux,
       _probeAgents = probeAgents,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  /// Creates a prober backed by the MonkeyMux installer and agent detection.
  factory HostSetupProber.live({
    required MonkeyMuxInstallerService installer,
    required TmuxService tmuxService,
  }) => HostSetupProber(
    probeMonkeyMux: (session) async {
      try {
        // Without a confirmation callback this only checks; it never uploads.
        await installer.ensureInstalled(session);
        return true;
      } on MonkeyMuxInstallConfirmationRequiredException {
        return false;
      } on MonkeyMuxInstallException {
        return null;
      }
    },
    probeAgents: (session) async =>
        (await tmuxService.detectInstalledAgentTools(session)).isNotEmpty,
  );

  final HostSetupStepProbe _probeMonkeyMux;
  final HostSetupStepProbe _probeAgents;
  final DiagnosticsLogger _diagnostics;

  /// Probes [session]. Failures become unknown rather than missing.
  Future<HostSetupProbeResult> probe(SshSession session) async {
    final startedAt = DateTime.now();
    Future<bool?> guarded(String name, HostSetupStepProbe probe) async {
      try {
        return await probe(session);
      } on Object catch (error) {
        _diagnostics.debug(
          'onboarding.checklist',
          'probe_failed',
          fields: {
            'connectionId': session.connectionId,
            'probe': name,
            'errorType': error.runtimeType,
          },
        );
        return null;
      }
    }

    final results = await Future.wait([
      guarded('monkeymux', _probeMonkeyMux),
      guarded('agents', _probeAgents),
    ]);
    final result = HostSetupProbeResult(
      connectionId: session.connectionId,
      monkeyMuxInstalled: results[0],
      agentsDetected: results[1],
    );
    _diagnostics.info(
      'onboarding.checklist',
      'probe_finished',
      fields: {
        'hostId': session.hostId,
        'connectionId': session.connectionId,
        'monkeyMux': result.monkeyMuxInstalled?.toString() ?? 'unknown',
        'agents': result.agentsDetected?.toString() ?? 'unknown',
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
      },
    );
    return result;
  }
}

/// Provider for [HostSetupProber].
final hostSetupProberProvider = Provider<HostSetupProber>(
  (ref) => HostSetupProber.live(
    installer: ref.watch(monkeyMuxInstallerServiceProvider),
    tmuxService: ref.watch(tmuxServiceProvider),
  ),
);
