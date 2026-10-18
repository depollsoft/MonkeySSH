// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/host_setup_checklist_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/mocks.dart';
import '../../helpers/recording_diagnostics_logger.dart';

Host _host({int? keyId, String? password = 'secret', DateTime? connected}) =>
    Host(
      id: 4,
      label: 'box',
      hostname: 'box.example.com',
      port: 22,
      username: 'me',
      password: password,
      keyId: keyId,
      isFavorite: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      lastConnectedAt: connected ?? DateTime(2026, 10),
      autoConnectRequiresConfirmation: false,
      autoForwardPorts: false,
      sortOrder: 0,
      notifyAgentAttention: true,
      notifyAgentFinished: true,
      notifyWindowAlerts: true,
      notifyShellNotifications: true,
      pushWhenClosed: true,
    );

HostSetupChecklist _checklist({
  Host? host,
  HostSetupPersistedState persisted = const HostSetupPersistedState(),
  HostSetupProbeResult? probe,
  bool hasAgentSession = false,
}) => computeHostSetupChecklist(
  host: host ?? _host(),
  persisted: persisted,
  probe: probe,
  hasAgentSession: hasAgentSession,
);

void main() {
  group('computeHostSetupChecklist', () {
    test('a password-only host starts with key login', () {
      final checklist = _checklist();
      expect(checklist.nextStep, HostSetupStep.keyLogin);
      expect(checklist.doneCount, 0);
    });

    test('a key or no saved password counts as key login', () {
      expect(
        _checklist(host: _host(keyId: 1)).statusOf(HostSetupStep.keyLogin),
        HostSetupStepStatus.done,
      );
      expect(
        _checklist(host: _host(password: null))
            .statusOf(HostSetupStep.keyLogin),
        HostSetupStepStatus.done,
      );
      expect(
        _checklist(host: _host(password: '')).statusOf(HostSetupStep.keyLogin),
        HostSetupStepStatus.done,
      );
    });

    test('unknown probe results hide later steps until checked', () {
      final checklist = _checklist(host: _host(keyId: 1));
      expect(
        checklist.statusOf(HostSetupStep.monkeyMux),
        HostSetupStepStatus.unknown,
      );
      expect(checklist.nextStep, isNull);
      expect(checklist.needsProbe, isTrue);
    });

    test('probe results drive the next step in order', () {
      final missingMux = _checklist(
        host: _host(keyId: 1),
        probe: const HostSetupProbeResult(
          connectionId: 1,
          monkeyMuxInstalled: false,
          agentsDetected: false,
        ),
      );
      expect(missingMux.nextStep, HostSetupStep.monkeyMux);

      final missingAgents = _checklist(
        host: _host(keyId: 1),
        probe: const HostSetupProbeResult(
          connectionId: 1,
          monkeyMuxInstalled: true,
          agentsDetected: false,
        ),
      );
      expect(missingAgents.nextStep, HostSetupStep.agents);

      final needsSignIn = _checklist(
        host: _host(keyId: 1),
        probe: const HostSetupProbeResult(
          connectionId: 1,
          monkeyMuxInstalled: true,
          agentsDetected: true,
        ),
      );
      expect(needsSignIn.nextStep, HostSetupStep.agentSignIn);
      expect(needsSignIn.doneCount, 3);
    });

    test('a negative probe still wants a probe on the next connection', () {
      final checklist = _checklist(
        host: _host(keyId: 1),
        probe: const HostSetupProbeResult(
          connectionId: 1,
          monkeyMuxInstalled: false,
          agentsDetected: true,
        ),
      );
      expect(checklist.nextStep, HostSetupStep.monkeyMux);
      expect(checklist.needsProbe, isTrue);
    });

    test('persisted steps stay done without a probe', () {
      final checklist = _checklist(
        host: _host(keyId: 1),
        persisted: const HostSetupPersistedState(
          done: {HostSetupStep.monkeyMux, HostSetupStep.agents},
        ),
      );
      expect(checklist.nextStep, HostSetupStep.agentSignIn);
      expect(checklist.needsProbe, isFalse);
    });

    test('an agent session completes the checklist', () {
      final checklist = _checklist(
        host: _host(keyId: 1),
        persisted: const HostSetupPersistedState(
          done: {HostSetupStep.monkeyMux, HostSetupStep.agents},
        ),
        hasAgentSession: true,
      );
      expect(checklist.isComplete, isTrue);
      expect(checklist.nextStep, isNull);
    });
  });

  group('HostSetupChecklistStore', () {
    late AppDatabase db;
    late HostSetupChecklistStore store;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = HostSetupChecklistStore(SettingsService(db));
    });

    tearDown(() => db.close());

    test('records done steps per host', () async {
      await store.markDone(1, {HostSetupStep.monkeyMux});
      await store.markDone(1, {HostSetupStep.agents});
      await store.markDone(2, {HostSetupStep.keyLogin});
      final states = await store.load();
      expect(states[1]!.done, {HostSetupStep.monkeyMux, HostSetupStep.agents});
      expect(states[2]!.done, {HostSetupStep.keyLogin});
    });

    test('ignores the dismissed flag older versions saved', () {
      // The checklist used to show on host rows until hidden; it now opens
      // only from the host menu, so an old hide no longer applies.
      expect(
        decodeHostSetupPersistedState(
          '{"3":{"done":["agents"],"dismissed":true},"4":{"dismissed":true}}',
        ),
        {
          3: const HostSetupPersistedState(done: {HostSetupStep.agents}),
          4: const HostSetupPersistedState(),
        },
      );
    });

    test('ignores malformed storage', () {
      expect(decodeHostSetupPersistedState('not json'), isEmpty);
      expect(decodeHostSetupPersistedState('[1,2]'), isEmpty);
      expect(
        decodeHostSetupPersistedState(
          '{"x":{"done":["monkeymux"]},"3":{"done":["bogus","agents"]}}',
        ),
        {
          3: const HostSetupPersistedState(done: {HostSetupStep.agents}),
        },
      );
    });
  });

  group('HostSetupProber', () {
    test('turns probe failures into unknown and logs no content', () async {
      final session = MockSshSession();
      when(() => session.connectionId).thenReturn(9);
      when(() => session.hostId).thenReturn(4);
      final diagnostics = RecordingDiagnosticsLogger();
      final prober = HostSetupProber(
        probeMonkeyMux: (_) async => true,
        probeAgents: (_) async => throw StateError('boom'),
        diagnostics: diagnostics,
      );
      final result = await prober.probe(session);
      expect(result.connectionId, 9);
      expect(result.monkeyMuxInstalled, isTrue);
      expect(result.agentsDetected, isNull);
      final finished = diagnostics.events.last;
      expect(finished.message, 'probe_finished');
      expect(finished.fields['agents'], 'unknown');
    });

    test('runs both probes concurrently', () async {
      final session = MockSshSession();
      when(() => session.connectionId).thenReturn(1);
      when(() => session.hostId).thenReturn(1);
      final mux = Completer<bool?>();
      var agentsStarted = false;
      final prober = HostSetupProber(
        probeMonkeyMux: (_) => mux.future,
        probeAgents: (_) async {
          agentsStarted = true;
          return true;
        },
        diagnostics: RecordingDiagnosticsLogger(),
      );
      final pending = prober.probe(session);
      await Future<void>.delayed(Duration.zero);
      expect(agentsStarted, isTrue);
      mux.complete(false);
      final result = await pending;
      expect(result.monkeyMuxInstalled, isFalse);
      expect(result.agentsDetected, isTrue);
    });
  });
}
