// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// Minimal in-memory agent: answers setup requests and lets tests push
/// agent-to-client requests and notifications.
class _Agent implements AcpTransport {
  final _incoming = StreamController<List<int>>(sync: true);
  final responses = <Object, Map<String, Object?>>{};
  Map<String, Object?>? clientCapabilities;
  Object? heldPromptId;
  Object? heldSetupId;
  bool holdSetup = false;
  int _sessions = 0;
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes).trim()) as Map)
        .cast<String, Object?>();
    final id = message['id'];
    final method = message['method'];
    if (method == null && id != null) {
      responses[id] = message;
      return;
    }
    if (id == null) return;
    switch (method) {
      case 'initialize':
        clientCapabilities =
            ((message['params']! as Map)['clientCapabilities']! as Map)
                .cast<String, Object?>();
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': true,
            'sessionCapabilities': {'fork': <String, Object?>{}},
          },
        });
      case 'session/new':
        _reply(id, {'sessionId': 'session-${++_sessions}'});
      case 'session/fork':
        _reply(id, {'sessionId': 'fork-${++_sessions}'});
      case 'session/prompt':
        heldPromptId = id;
      case 'session/load' || 'session/resume' when holdSetup:
        heldSetupId = id;
      default:
        _reply(id, <String, Object?>{});
    }
  }

  void request(Object id, String method, Map<String, Object?> params) =>
      push({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

  void notify(String method, Map<String, Object?> params) =>
      push({'jsonrpc': '2.0', 'method': method, 'params': params});

  void failPrompt(int code) => push({
    'jsonrpc': '2.0',
    'id': heldPromptId,
    'error': {'code': code, 'message': 'Request cancelled'},
  });

  void releaseSetup() => _reply(heldSetupId!, <String, Object?>{});

  void _reply(Object id, Object? result) =>
      push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void push(Map<String, Object?> message) {
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

class _Connector implements AcpBridgeConnector {
  final agents = <String, _Agent>{};
  bool holdSessionSetup = false;
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
  }) async => const [];

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
  ) => throw UnimplementedError();

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {}

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    final agent = agents[bridgeId] = _Agent()..holdSetup = holdSessionSetup;
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast();
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    final client = AcpClient(AcpJsonRpcConnection(transport: agent));
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

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

const _form = <String, Object?>{
  'mode': 'form',
  'message': 'Pick a strategy',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'strategy': {
        'type': 'string',
        'enum': ['safe', 'fast'],
      },
    },
    'required': ['strategy'],
  },
};

void main() {
  late AppDatabase database;
  late _Connector connector;
  late AcpSessionManager manager;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = SettingsService(database);
    connector = _Connector();
    manager = AcpSessionManager(
      connector: connector,
      providerService: AcpProviderService(settings),
      recentSessions: AcpRecentSessionsService(settings),
      isProUnlocked: () => true,
      diagnostics: const NoopDiagnosticsLogger(),
    );
  });

  tearDown(() async {
    await manager.dispose();
    await database.close();
  });

  Future<AcpSessionKey> start() async {
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    );
    return (result as AcpSessionLaunchStarted).key;
  }

  AcpSessionState stateOf(AcpSessionKey key) =>
      manager.state.byKeyValue(key.value)!;

  test('advertises elicitation modes during initialize', () async {
    final key = await start();
    expect(connector.agents[key.bridgeId]!.clientCapabilities!['elicitation'], {
      'form': {},
      'url': {},
    });
  });

  test('surfaces a form elicitation and answers the submission', () async {
    final key = await start();
    final agent = connector.agents[key.bridgeId]!
      ..request('elicit-1', 'elicitation/create', {
        ..._form,
        'sessionId': key.acpSessionId,
      });
    await _pump();

    final pending = stateOf(key).pendingElicitations.single;
    expect(pending.requestKey, 's:elicit-1');
    expect(pending.request, isA<AcpFormElicitation>());

    await manager.acceptElicitation(
      key,
      pending.requestKey,
      content: {'strategy': 'safe'},
    );
    await _pump();
    expect(stateOf(key).pendingElicitations, isEmpty);
    expect(agent.responses['elicit-1']!['result'], {
      'action': 'accept',
      'content': {'strategy': 'safe'},
    });
  });

  test(
    r'agent $/cancel_request removes the prompt from session state',
    () async {
      final key = await start();
      final agent = connector.agents[key.bridgeId]!
        ..request('perm-1', 'session/request_permission', {
          'sessionId': key.acpSessionId,
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        })
        ..request(2, 'elicitation/create', {
          ..._form,
          'sessionId': key.acpSessionId,
        });
      await _pump();
      expect(stateOf(key).pendingPermissions, hasLength(1));
      expect(stateOf(key).pendingElicitations, hasLength(1));

      agent
        ..notify(acpCancelRequestMethod, {'requestId': 'perm-1'})
        ..notify(acpCancelRequestMethod, {'requestId': 2});
      await _pump();
      expect(stateOf(key).pendingPermissions, isEmpty);
      expect(stateOf(key).pendingElicitations, isEmpty);
      expect(
        (agent.responses['perm-1']!['error']! as Map)['code'],
        acpRequestCancelledErrorCode,
      );
      expect(
        (agent.responses[2]!['error']! as Map)['code'],
        acpRequestCancelledErrorCode,
      );
    },
  );

  test('an elicitation sent while a session loads is shown before the load '
      'finishes', () async {
    connector.holdSessionSetup = true;
    final reconnect = manager.reconnectSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      bridgeId: 'bridge-gone',
      acpSessionId: 'session-9',
      cwd: '/repo',
    );
    await _pump();
    final agent = connector.agents.values.single;
    expect(agent.heldSetupId, isNotNull);

    // The agent needs an answer before it can finish loading the session,
    // while the replayed transcript is still held back.
    agent.request('elicit-load', 'elicitation/create', {
      ..._form,
      'sessionId': 'session-9',
    });
    await _pump();
    final session = manager.state.sessions.single;
    expect(session.status, isNot(AcpConnectionStatus.ready));
    final pending = session.pendingElicitations.single;
    expect(pending.requestKey, 's:elicit-load');

    await manager.acceptElicitation(
      session.key,
      pending.requestKey,
      content: {'strategy': 'safe'},
    );
    await _pump();
    expect(agent.responses['elicit-load']!['result'], {
      'action': 'accept',
      'content': {'strategy': 'safe'},
    });
    agent.releaseSetup();
    expect(await reconnect, isA<AcpSessionLaunchStarted>());
    expect(manager.state.sessions.single.pendingElicitations, isEmpty);
  });

  test('an accepted URL waits for elicitation/complete', () async {
    final key = await start();
    final agent = connector.agents[key.bridgeId]!
      ..request('url-1', 'elicitation/create', {
        'sessionId': key.acpSessionId,
        'mode': 'url',
        'elicitationId': 'oauth-1',
        'url': 'https://auth.example.com/connect',
        'message': 'Connect your account',
      });
    await _pump();
    await manager.acceptElicitation(
      key,
      stateOf(key).pendingElicitations.single.requestKey,
    );
    await _pump();
    expect(agent.responses['url-1']!['result'], {'action': 'accept'});
    expect(stateOf(key).awaitingElicitations.single.host, 'auth.example.com');

    agent.notify('elicitation/complete', {'elicitationId': 'oauth-1'});
    await _pump();
    expect(stateOf(key).awaitingElicitations, isEmpty);
  });

  test(
    'a request-scoped elicitation shows on every session of the bridge',
    () async {
      final key = await start();
      final fork =
          (await manager.forkSession(key) as AcpSessionLaunchStarted).key;
      final agent = connector.agents[key.bridgeId]!
        ..request('scoped', 'elicitation/create', {..._form, 'requestId': 99});
      await _pump();
      expect(stateOf(key).pendingElicitations.single.isRequestScoped, isTrue);
      expect(stateOf(fork).pendingElicitations, hasLength(1));

      await manager.declineElicitation(fork, 's:scoped');
      await _pump();
      expect(stateOf(key).pendingElicitations, isEmpty);
      expect(stateOf(fork).pendingElicitations, isEmpty);
      expect(agent.responses['scoped']!['result'], {'action': 'decline'});
    },
  );

  test('stopping the session cancels its pending elicitation', () async {
    final key = await start();
    final agent = connector.agents[key.bridgeId]!
      ..request('elicit', 'elicitation/create', {
        ..._form,
        'sessionId': key.acpSessionId,
      });
    await _pump();
    await manager.stopSession(key);
    expect(agent.responses['elicit']!['result'], {'action': 'cancel'});
  });

  test('a cancelled prompt request ends the turn without an error', () async {
    final key = await start();
    final agent = connector.agents[key.bridgeId]!;
    final prompt = manager.prompt(key, const [AcpTextContent('hello')]);
    await _pump();
    expect(stateOf(key).promptStatus, AcpPromptStatus.streaming);
    agent.failPrompt(acpRequestCancelledErrorCode);
    final result = await prompt;
    expect(result.stopReason, AcpStopReason.cancelled);
    final state = stateOf(key);
    expect(state.promptStatus, AcpPromptStatus.idle);
    expect(state.error, isNull);
    expect(state.lastStopReason, AcpStopReason.cancelled);
  });
}
