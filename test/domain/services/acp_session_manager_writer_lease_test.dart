// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_writer_lease.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// In-memory agent standing in for the provider behind one bridge attachment.
class _Agent implements AcpTransport {
  _Agent({required this.onFirstRequest});

  /// Runs when the first request is written, standing in for the bridge's
  /// reply to the attach hello.
  final void Function(_Agent agent)? onFirstRequest;
  final _incoming = StreamController<List<int>>(sync: true);
  final methods = <String>[];
  final heldPromptIds = <Object>[];
  var _sessions = 0;
  var _sawRequest = false;
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    if (closed) throw StateError('agent closed');
    final message = (jsonDecode(utf8.decode(bytes).trim()) as Map)
        .cast<String, Object?>();
    final id = message['id'];
    final method = message['method'];
    if (method is String) methods.add(method);
    if (!_sawRequest && id != null && method != null) {
      _sawRequest = true;
      onFirstRequest?.call(this);
      if (closed) return;
    }
    if (id == null || method == null) return;
    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {'loadSession': true},
        });
      case 'session/new':
        _reply(id, {'sessionId': 'session-${++_sessions}'});
      case 'session/prompt':
        heldPromptIds.add(id);
      default:
        _reply(id, <String, Object?>{});
    }
  }

  void requestPermission(String id, String sessionId) => _push({
    'jsonrpc': '2.0',
    'id': id,
    'method': 'session/request_permission',
    'params': {
      'sessionId': sessionId,
      'toolCall': {'toolCallId': 'tool-1', 'title': 'Write file'},
      'options': [
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    },
  });

  void _reply(Object id, Object? result) =>
      _push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _push(Map<String, Object?> message) {
    if (closed) return;
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

/// Connector whose attaches can find the input lease held by another device.
class _Connector implements AcpBridgeConnector {
  final agents = <_Agent>[];
  final states = <StreamController<MonkeyMuxAcpTransportState>>[];
  final takeOvers = <bool>[];

  /// When set, an attach that does not take over finds this writer.
  MonkeyMuxAcpRemoteWriter? heldBy;

  /// What each attach reports about prompts once the input moved.
  final promptDeliveries = <String, AcpInputDelivery>{};
  var _bridges = 0;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => MonkeyMuxAcpBridgeStartResult(bridgeId: 'bridge-${++_bridges}');

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => [_metadata('bridge-1')];

  int statusCount = 0;

  MonkeyMuxAcpBridgeMetadata _metadata(String bridgeId) {
    final writer = heldBy;
    return MonkeyMuxAcpBridgeMetadata(
      id: bridgeId,
      provider: 'Copilot CLI',
      commandHash: 'hash',
      state: MonkeyMuxAcpProviderState.running,
      clientCount: 1,
      pendingRequestCount: 0,
      inFlightTurnCount: 0,
      lastActivity: DateTime.now(),
      startedAt: DateTime.now(),
      nextSequence: 4,
      writer: writer == null
          ? null
          : MonkeyMuxAcpLeaseHolder(
              label: writer.label,
              lastActiveAt: writer.lastActiveAt,
              stale: false,
            ),
    );
  }

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async => cwd;

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async {
    statusCount += 1;
    return _metadata(bridgeId);
  }

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {}

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
    bool takeOver = false,
  }) {
    takeOvers.add(takeOver);
    final stateController =
        StreamController<MonkeyMuxAcpTransportState>.broadcast(sync: true);
    final writer = heldBy;
    final agent = _Agent(
      onFirstRequest: writer == null || takeOver
          ? null
          : (agent) {
              // Like the real transport: report the writer, then end the
              // stream so the pending request fails at once.
              stateController.add(
                MonkeyMuxAcpTransportState(
                  status: MonkeyMuxAcpTransportStatus.heldElsewhere,
                  bridgeId: bridgeId,
                  lastDeliveredSequence: 0,
                  writer: writer,
                ),
              );
              unawaited(agent.close());
            },
    );
    agents.add(agent);
    states.add(stateController);
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    final client = AcpClient(AcpJsonRpcConnection(transport: agent));
    return AcpBridgeSession(
      client: client,
      transportStates: stateController.stream,
      transportErrors: errors.stream,
      promptDelivery: (sessionId) =>
          promptDeliveries[sessionId] ?? AcpInputDelivery.notSent,
      onClose: () async {
        await client.close();
        await stateController.close();
        await errors.close();
      },
    );
  }

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => null;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

List<String> _timelineTexts(AcpSessionState state) => [
  for (final entry in state.timeline.entries)
    if (entry is AcpMessageEntry)
      for (final block in entry.content)
        if (block is AcpTextContent) block.text,
];

void main() {
  late AppDatabase database;
  late _Connector connector;
  late AcpSessionManager manager;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    connector = _Connector();
    manager = AcpSessionManager(
      connector: connector,
      recentSessions: AcpRecentSessionsService(SettingsService(database)),
      isProUnlocked: () => true,
      diagnostics: const NoopDiagnosticsLogger(),
    );
  });

  tearDown(() async {
    await manager.dispose();
    await database.close();
  });

  final ipad = MonkeyMuxAcpRemoteWriter(
    label: 'iPad',
    lastActiveAt: DateTime(2026, 10, 9, 12),
    leaseLost: false,
  );

  Future<AcpSessionLaunchResult> open({bool takeOver = false}) =>
      manager.reconnectSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
        cwd: '/repo',
        takeOver: takeOver,
      );

  AcpSessionState stateOf(AcpSessionKey key) =>
      manager.state.byKeyValue(key.value)!;

  test('opening a chat another device holds shows it read-only', () async {
    connector.heldBy = ipad;

    final result = await open();

    expect(result, isA<AcpSessionLaunchStarted>());
    final key = (result as AcpSessionLaunchStarted).key;
    final state = stateOf(key);
    expect(state.remoteWriter, ipad);
    expect(state.status, AcpConnectionStatus.detached);
    expect(state.isLive, isFalse);
    expect(manager.state.selectedKey, key.value);
    // Nothing past the first request was sent from the read-only attach.
    expect(connector.agents.single.methods, ['initialize']);
  });

  test('take over opens a writer attach and loads the history', () async {
    connector.heldBy = ipad;
    final held = (await open()) as AcpSessionLaunchStarted;

    final result = await open(takeOver: true);

    expect(result, isA<AcpSessionLaunchStarted>());
    final state = stateOf((result as AcpSessionLaunchStarted).key);
    expect(state.remoteWriter, isNull);
    expect(state.status, AcpConnectionStatus.ready);
    expect(state.key, held.key);
    expect(connector.takeOvers, [false, true]);
    expect(connector.agents.last.methods, contains('session/load'));
  });

  test(
    're-opening a held chat without take over refreshes the writer',
    () async {
      connector.heldBy = ipad;
      await open();
      final later = MonkeyMuxAcpRemoteWriter(
        label: 'iPad',
        lastActiveAt: DateTime(2026, 10, 9, 13),
        leaseLost: false,
      );
      connector.heldBy = later;

      final result = (await open()) as AcpSessionLaunchStarted;

      expect(stateOf(result.key).remoteWriter, later);
      // The frozen view stays; only who holds it is refreshed.
      expect(connector.takeOvers, [false]);
    },
  );

  test('reopening a sibling chat reuses the input this device took', () async {
    connector.heldBy = ipad;
    Future<AcpSessionLaunchResult> openSession(
      String sessionId, {
      bool takeOver = false,
    }) => manager.reconnectSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      bridgeId: 'bridge-1',
      acpSessionId: sessionId,
      cwd: '/repo',
      takeOver: takeOver,
    );
    final first = (await openSession('session-1')) as AcpSessionLaunchStarted;
    final sibling = (await openSession('session-2')) as AcpSessionLaunchStarted;
    expect(stateOf(sibling.key).remoteWriter, isNotNull);

    await openSession('session-1', takeOver: true);
    expect(stateOf(first.key).status, AcpConnectionStatus.ready);
    // The bridge now names this device as the holder.
    connector.heldBy = MonkeyMuxAcpRemoteWriter(
      label: 'iPhone',
      lastActiveAt: DateTime(2026, 10, 9, 12),
      leaseLost: false,
    );
    final attaches = connector.agents.length;

    await openSession('session-2');

    final state = stateOf(sibling.key);
    expect(state.remoteWriter, isNull);
    expect(state.status, AcpConnectionStatus.ready);
    // It shares the attachment that holds the lease instead of taking it
    // from itself.
    expect(connector.agents, hasLength(attaches));
  });

  test('a device that lost the chat keeps its transcript on return', () async {
    final started = (await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    )) as AcpSessionLaunchStarted;
    final key = started.key;
    connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.delivered;
    final sent = manager.prompt(key, const [AcpTextContent('kept')]);
    unawaited(sent.then<void>((_) {}, onError: (Object _) {}));
    await _pump();
    final iphone = MonkeyMuxAcpRemoteWriter(
      label: 'iPhone',
      lastActiveAt: DateTime(2026, 10, 9, 12),
      leaseLost: true,
    );
    connector.states.single.add(
      MonkeyMuxAcpTransportState(
        status: MonkeyMuxAcpTransportStatus.heldElsewhere,
        bridgeId: key.bridgeId,
        lastDeliveredSequence: 0,
        writer: iphone,
      ),
    );
    await _pump();
    connector.heldBy = MonkeyMuxAcpRemoteWriter(
      label: 'iPhone',
      lastActiveAt: DateTime(2026, 10, 9, 12, 30),
      leaseLost: false,
    );

    final result = await manager.reconnectSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      bridgeId: key.bridgeId,
      acpSessionId: key.acpSessionId,
      cwd: '/repo',
    );

    expect(result, isA<AcpSessionLaunchStarted>());
    final state = stateOf(key);
    expect(_timelineTexts(state), ['kept']);
    expect(state.remoteWriter!.leaseLost, isTrue);
    expect(state.remoteWriter!.lastActiveAt, DateTime(2026, 10, 9, 12, 30));
    expect(connector.agents, hasLength(1));

    connector.heldBy = MonkeyMuxAcpRemoteWriter(
      label: 'iPhone',
      lastActiveAt: DateTime(2026, 10, 9, 12, 45),
      leaseLost: false,
    );
    await manager.refreshHeldSession(key);
    expect(
      stateOf(key).remoteWriter!.lastActiveAt,
      DateTime(2026, 10, 9, 12, 45),
    );
    expect(connector.statusCount, 1);
  });

  test(
    'reopening a detached chat another device took stays read-only',
    () async {
      final started = (await manager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      )) as AcpSessionLaunchStarted;
      final key = started.key;
      await manager.detachSession(key);
      connector.heldBy = ipad;

      final reopened = await manager.reconnectSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );

      expect(reopened, isA<AcpSessionLaunchStarted>());
      final held = stateOf(key);
      expect(held.remoteWriter, ipad);
      expect(held.status, AcpConnectionStatus.detached);
      expect(held.error, isNull);

      final back = await manager.reconnectSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
        takeOver: true,
      );
      expect(back, isA<AcpSessionLaunchStarted>());
      expect(stateOf(key).status, AcpConnectionStatus.ready);
      expect(connector.takeOvers, [false, false, true]);
    },
  );

  test(
    'a prompt the bridge dropped leaves the transcript and returns',
    () async {
      final started = (await manager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      )) as AcpSessionLaunchStarted;
      final key = started.key;
      // Sent during the takeover round trip: the bridge already dropped it.
      connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.notSent;
      final sent = manager.prompt(key, const [AcpTextContent('late')]);
      final sentError = expectLater(
        sent,
        throwsA(
          isA<AcpInputHeldElsewhereException>().having(
            (error) => error.delivery,
            'delivery',
            AcpInputDelivery.notSent,
          ),
        ),
      );
      await _pump();
      expect(_timelineTexts(stateOf(key)), ['late']);

      connector.states.single.add(
        MonkeyMuxAcpTransportState(
          status: MonkeyMuxAcpTransportStatus.heldElsewhere,
          bridgeId: key.bridgeId,
          lastDeliveredSequence: 0,
          writer: ipad,
        ),
      );
      await sentError;
      await _pump();

      expect(_timelineTexts(stateOf(key)), isEmpty);
    },
  );

  test(
    'losing the lease makes the chat read-only and returns unsent prompts',
    () async {
      final started = (await manager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      )) as AcpSessionLaunchStarted;
      final key = started.key;
      final agent = connector.agents.single;
      connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.delivered;
      final delivered = manager.prompt(key, const [AcpTextContent('first')]);
      final queued = manager.prompt(key, const [AcpTextContent('second')]);
      final deliveredError = expectLater(
        delivered,
        throwsA(
          isA<AcpInputHeldElsewhereException>().having(
            (error) => error.delivered,
            'delivered',
            isTrue,
          ),
        ),
      );
      final queuedError = expectLater(
        queued,
        throwsA(
          isA<AcpInputHeldElsewhereException>().having(
            (error) => error.delivered,
            'delivered',
            isFalse,
          ),
        ),
      );
      await _pump();
      expect(agent.heldPromptIds, hasLength(1));
      agent.requestPermission('permission-1', key.acpSessionId);
      await _pump();
      expect(stateOf(key).pendingPermissions, hasLength(1));
      final methodsBefore = List<String>.of(agent.methods);

      final iphone = MonkeyMuxAcpRemoteWriter(
        label: 'iPhone',
        lastActiveAt: DateTime(2026, 10, 9, 12),
        leaseLost: true,
      );
      connector.states.single.add(
        MonkeyMuxAcpTransportState(
          status: MonkeyMuxAcpTransportStatus.heldElsewhere,
          bridgeId: key.bridgeId,
          lastDeliveredSequence: 3,
          writer: iphone,
        ),
      );
      await deliveredError;
      await queuedError;
      await _pump();

      final state = stateOf(key);
      expect(state.remoteWriter, iphone);
      expect(state.isLive, isFalse);
      expect(state.promptStatus, AcpPromptStatus.idle);
      // The decision now belongs to the device that took the chat.
      expect(state.pendingPermissions, isEmpty);
      // The delivered prompt stays in the transcript; the unsent one is gone.
      expect(_timelineTexts(state), ['first']);
      // Nothing more, and in particular no permission answer, was sent.
      expect(agent.methods, methodsBefore);
      expect(agent.closed, isTrue);

      connector.heldBy = null;
      final back = await open(takeOver: true);
      expect(back, isA<AcpSessionLaunchStarted>());
      final resumed = stateOf((back as AcpSessionLaunchStarted).key);
      expect(resumed.status, AcpConnectionStatus.ready);
      expect(resumed.remoteWriter, isNull);
      expect(connector.takeOvers.last, isTrue);
    },
  );
}
