// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_telemetry.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// Minimal ACP agent that answers setup requests and records their params.
class _Agent implements AcpTransport {
  final _incoming = StreamController<List<int>>(sync: true);
  final Map<String, List<Map<String, Object?>>> params = {};
  var _closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes).trim())! as Map)
        .cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];
    if (method is! String || id == null) return;
    params
        .putIfAbsent(method, () => [])
        .add((message['params'] as Map?)?.cast<String, Object?>() ?? {});
    _reply(id, switch (method) {
      'initialize' => {
        'protocolVersion': 1,
        'agentCapabilities': {'loadSession': true},
      },
      'session/new' => {'sessionId': 'custom-session'},
      _ => <String, Object?>{},
    });
  }

  void _reply(Object id, Object? result) {
    if (_closed) return;
    _incoming.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n',
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

typedef _StartedBridge = ({
  String providerId,
  String providerLabel,
  List<String> launchArgv,
  String cwd,
});

class _Connector implements AcpBridgeConnector {
  final List<_StartedBridge> started = [];
  final Map<String, _Agent> agents = {};
  var _counter = 0;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    started.add((
      providerId: providerId,
      providerLabel: providerLabel,
      launchArgv: launchArgv,
      cwd: cwd,
    ));
    return MonkeyMuxAcpBridgeStartResult(bridgeId: 'bridge-${++_counter}');
  }

  MonkeyMuxAcpBridgeMetadata _metadata(String bridgeId) =>
      MonkeyMuxAcpBridgeMetadata(
        id: bridgeId,
        provider: 'Goose',
        commandHash: 'hash',
        state: MonkeyMuxAcpProviderState.running,
        clientCount: 0,
        pendingRequestCount: 0,
        inFlightTurnCount: 0,
        lastActivity: DateTime.now(),
        startedAt: DateTime.now(),
        nextSequence: 1,
      );

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => const [];

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async {
    if (cwd == '~') return '/home/test';
    return cwd.startsWith('/') ? cwd : '/home/test/$cwd';
  }

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async => _metadata(bridgeId);

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {}

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    final agent = agents[bridgeId] = _Agent();
    final client = AcpClient(AcpJsonRpcConnection(transport: agent));
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast();
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    return AcpBridgeSession(
      client: client,
      transportStates: states.stream,
      transportErrors: errors.stream,
      onClose: () async {
        await client.close();
        await states.close();
        await errors.close();
      },
    );
  }

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => null;
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

void main() {
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

  test('refuses a custom agent whose command changed since approval', () async {
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
  });

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
      final goose = _goose(cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory)
          .approve();
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
}
