// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_telemetry.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/acp_test_fakes.dart';

class _Connector extends FakeAcpBridgeConnector {
  _Connector()
    : super(
        defaultProviderLabel: 'Goose',
        transportFactory: (_, _, _, {required takeOver}) => FakeAcpTransport(
          onRequest: (transport, id, method, _) {
            if (method == 'session/new') {
              transport.reply(id, const {'sessionId': 'custom-session'});
              return true;
            }
            return false;
          },
        ),
        workingDirectoryResolver: (_, cwd, {required trustAbsolute}) async {
          if (cwd == '~') return '/home/test';
          return cwd.startsWith('/') ? cwd : '/home/test/$cwd';
        },
      );

  Map<String, FakeAcpTransport> get agents => transports;
  List<String> get stopped => stoppedBridges;

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => [
    for (final id in runningLabels.keys)
      fakeAcpBridgeMetadata(id, provider: runningLabels[id] ?? 'Goose'),
  ];
}

class _Lookup implements AcpCustomProviderLookup {
  final Map<String, AcpCustomProviderDefinition> definitions = {};

  @override
  Future<AcpCustomProviderDefinition?> getCustomProvider(String id) async =>
      definitions[id];
}

class _RecordingTelemetry implements AcpTelemetrySink {
  final List<String> openedCategories = [];

  @override
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) {
    openedCategories.add(providerCategory);
  }

  @override
  void featureOpened() {}

  @override
  void sessionEnded({required String reason}) {}

  @override
  void reconnectOutcome({required bool succeeded, String? failureCategory}) {}

  @override
  void attachmentSent({required String category, required int count}) {}

  @override
  void permissionOutcome({required String outcome}) {}

  @override
  void failure({required String category}) {}
}

AcpCustomProviderDefinition _goose({
  AcpCustomProviderCwdPolicy cwdPolicy =
      AcpCustomProviderCwdPolicy.chosenDirectory,
}) => AcpCustomProviderDefinition.create(
  id: 'goose',
  label: 'Goose',
  launchCommand: AcpLaunchCommand(
    executable: '/opt/goose/bin/goose',
    arguments: const ['acp', '--with-builtin', 'developer'],
  ),
  cwdPolicy: cwdPolicy,
);

/// Registers tests from acp_session_manager_custom_provider_test.dart.
void registerDomainServicesAcpSessionManagerCustomProviderTests() {
  group('acp_session_manager_custom_provider', () {
    late AppDatabase database;
    late _Connector connector;
    late _Lookup lookup;
    late _RecordingTelemetry telemetry;
    late AcpSessionManager manager;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      connector = _Connector();
      lookup = _Lookup();
      telemetry = _RecordingTelemetry();
      manager = AcpSessionManager(
        connector: connector,
        recentSessions: AcpRecentSessionsService(SettingsService(database)),
        customProviders: lookup,
        isProUnlocked: () => true,
        diagnostics: const NoopDiagnosticsLogger(),
        telemetry: telemetry,
      );
    });

    tearDown(() async {
      await manager.dispose();
      await database.close();
    });

    test('launches an approved custom agent through the bridge with its '
        'exact argv', () async {
      final goose = _goose().approve();
      lookup.definitions[goose.id] = goose;

      final result = await manager.startNewSession(
        hostId: 1,
        providerId: goose.id,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchStarted>());
      final bridge = connector.started.single;
      expect(bridge.providerId, 'goose');
      expect(bridge.providerLabel, 'Goose');
      expect(bridge.launchArgv, [
        '/opt/goose/bin/goose',
        'acp',
        '--with-builtin',
        'developer',
      ]);
      expect(bridge.cwd, '/repo');
      final agent = connector.agents.values.single;
      expect(agent.params['session/new']!.single['cwd'], '/repo');

      final session = manager.state.sessions.single;
      expect(session.providerLabel, 'Goose');
      // Notifications and telemetry never see the user-chosen label or id.
      expect(acpSafeAgentDisplayLabel(session), acpGenericAgentLabel);
      expect(telemetry.openedCategories, ['goose']);
    });

    test(
      'refuses a custom agent whose command changed since approval',
      () async {
        final approved = _goose().approve();
        lookup.definitions['goose'] = approved.edit(
          launchCommand: AcpLaunchCommand(
            executable: '/opt/goose/bin/goose',
            arguments: const ['acp', '--yolo'],
          ),
        );

        final result = await manager.startNewSession(
          hostId: 1,
          providerId: 'goose',
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchFailed>());
        expect(
          (result as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.commandNotApproved,
        );
        expect(connector.started, isEmpty);
      },
    );

    test('never runs a launch override for a custom agent', () async {
      final goose = _goose().approve();
      lookup.definitions[goose.id] = goose;

      final result = await manager.startNewSession(
        hostId: 1,
        providerId: goose.id,
        cwd: '/repo',
        launchCommandOverride: AcpLaunchCommand(executable: '/bin/sh'),
      );

      expect(
        (result as AcpSessionLaunchFailed).error.kind,
        AcpSessionErrorKind.commandNotApproved,
      );
      expect(connector.started, isEmpty);
    });

    test(
      'a home-folder agent starts in home whatever folder was chosen',
      () async {
        final goose = _goose(
          cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory,
        ).approve();
        lookup.definitions[goose.id] = goose;

        final result = await manager.startNewSession(
          hostId: 1,
          providerId: goose.id,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.started.single.cwd, '/home/test');
        expect(
          connector.agents.values.single.params['session/new']!.single['cwd'],
          '/home/test',
        );
      },
    );

    test(
      'a home-folder agent resumes a listed session in its own folder',
      () async {
        final goose = _goose(
          cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory,
        ).approve();
        lookup.definitions[goose.id] = goose;

        final result = await manager.resumeProviderSession(
          hostId: 1,
          providerId: goose.id,
          acpSessionId: 'listed-session',
          cwd: '/work/project',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.started.single.cwd, '/work/project');
        expect(
          connector.agents.values.single.params['session/load']!.single['cwd'],
          '/work/project',
        );
      },
    );

    group('a running custom agent after its definition changes', () {
      late AcpSessionKey key;

      setUp(() async {
        final goose = _goose().approve();
        lookup.definitions[goose.id] = goose;
        final result = await manager.startNewSession(
          hostId: 1,
          providerId: goose.id,
          cwd: '/repo',
        );
        key = (result as AcpSessionLaunchStarted).key;
        // Leave the bridge running on the host, as after an app restart.
        await manager.detachSession(key);
      });

      Future<AcpSessionLaunchResult> reconnect() => manager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );

      for (final (change, apply) in <(String, void Function(_Lookup))>[
        (
          'edited and awaiting approval',
          (lookup) =>
              lookup.definitions['goose'] = lookup.definitions['goose']!.edit(
                launchCommand: AcpLaunchCommand(
                  executable: '/opt/goose/bin/goose',
                  arguments: const ['acp', '--yolo'],
                ),
              ),
        ),
        ('deleted', (lookup) => lookup.definitions.remove('goose')),
      ]) {
        test('reattaches its live bridge when $change', () async {
          apply(lookup);

          final result = await reconnect();

          expect(result, isA<AcpSessionLaunchStarted>());
          expect(connector.started, hasLength(1), reason: 'no new process');
          expect(manager.state.sessions.single.providerLabel, 'Goose');
        });
      }

      test('reattaches after an app restart once the definition is '
          'deleted', () async {
        lookup.definitions.remove('goose');
        final restarted = AcpSessionManager(
          connector: connector,
          recentSessions: AcpRecentSessionsService(SettingsService(database)),
          customProviders: lookup,
          isProUnlocked: () => true,
          diagnostics: const NoopDiagnosticsLogger(),
        );
        addTearDown(restarted.dispose);

        final result = await restarted.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.started, hasLength(1), reason: 'no new process');
        // The label comes from the running bridge.
        expect(restarted.state.sessions.single.providerLabel, 'Goose');
      });

      test('does not start a new process for an unapproved definition when '
          'the bridge is gone', () async {
        lookup.definitions['goose'] = lookup.definitions['goose']!.edit(
          label: 'Goose (edited)',
        );
        connector.runningLabels.clear();

        final result = await reconnect();

        expect(
          (result as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.commandNotApproved,
        );
        expect(connector.started, hasLength(1));
      });

      test('ends no other session when the bridge is gone and the agent '
          'cannot start', () async {
        final kimi = AcpCustomProviderDefinition.create(
          id: 'kimi',
          label: 'Kimi',
          launchCommand: AcpLaunchCommand(
            executable: 'kimi',
            arguments: const ['acp'],
          ),
        ).approve();
        lookup.definitions[kimi.id] = kimi;
        final other = await manager.startNewSession(
          hostId: 1,
          providerId: kimi.id,
          cwd: '/repo',
        );
        final otherKey = (other as AcpSessionLaunchStarted).key;
        lookup.definitions['goose'] = lookup.definitions['goose']!.edit(
          label: 'Goose (edited)',
        );
        connector.runningLabels.remove(key.bridgeId);

        // As when a free-tier user picks "end the other session" to make room.
        final result = await manager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
          replace: [otherKey],
        );

        expect(
          (result as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.commandNotApproved,
        );
        expect(connector.stopped, isEmpty);
        expect(connector.runningLabels, contains(otherKey.bridgeId));
      });
    });

    group('restart after sign-in', () {
      late AcpSessionKey key;

      setUp(() async {
        final goose = _goose().approve();
        lookup.definitions[goose.id] = goose;
        final result = await manager.startNewSession(
          hostId: 1,
          providerId: goose.id,
          cwd: '/repo',
        );
        key = (result as AcpSessionLaunchStarted).key;
      });

      test('reruns the approved command', () async {
        final result = await manager.restartAfterSignIn(key);

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.started, hasLength(2));
        expect(
          connector.started.last.launchArgv,
          connector.started.first.launchArgv,
        );
      });

      test('starts the bridge under the name approved now', () async {
        final renamed = lookup.definitions['goose']!.edit(
          label: 'Goose (work)',
        );
        lookup.definitions['goose'] = renamed.approve();

        final result = await manager.restartAfterSignIn(key);

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.started.last.providerLabel, 'Goose (work)');
      });

      test(
        'starts nothing once the definition is no longer approved',
        () async {
          lookup.definitions['goose'] = lookup.definitions['goose']!.edit(
            launchCommand: AcpLaunchCommand(executable: '/bin/sh'),
          );

          final result = await manager.restartAfterSignIn(key);

          expect(result, isA<AcpSessionLaunchStarted>());
          expect(connector.started, hasLength(1));
          expect(connector.stopped, isEmpty);
        },
      );
    });

    test('an unknown provider id still fails as unknown', () async {
      final result = await manager.startNewSession(
        hostId: 1,
        providerId: 'missing',
        cwd: '/repo',
      );
      expect(
        (result as AcpSessionLaunchFailed).error.kind,
        AcpSessionErrorKind.unknown,
      );
      expect(connector.started, isEmpty);
    });
  });
}
