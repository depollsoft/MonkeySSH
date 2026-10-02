// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_mcp_server.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_session_workspace.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_mcp_server_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// Minimal ACP agent that records every session-setup request's params.
class _RecordingAgent implements AcpTransport {
  _RecordingAgent({
    required this.http,
    required this.sse,
    required this.additionalDirectories,
  });

  final bool http;
  final bool sse;
  final bool additionalDirectories;

  final _incoming = StreamController<List<int>>(sync: true);
  final Map<String, List<Map<String, Object?>>> params = {};
  final Map<Object, Object?> responses = {};
  var _sessions = 0;
  var _serverRequests = 0;
  var _closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  List<Map<String, Object?>> paramsFor(String method) =>
      params[method] ?? const [];

  @override
  Future<void> write(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes).trim())! as Map)
        .cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];
    if (method == null && id != null) {
      responses[id] = message['result'] ?? message['error'];
      return;
    }
    if (method is! String || id == null) return;
    params
        .putIfAbsent(method, () => [])
        .add((message['params'] as Map?)?.cast<String, Object?>() ?? {});
    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': true,
            'mcpCapabilities': {'http': http, 'sse': sse},
            'sessionCapabilities': {
              'resume': <String, Object?>{},
              'fork': <String, Object?>{},
              if (additionalDirectories)
                'additionalDirectories': <String, Object?>{},
            },
          },
        });
      case 'session/new':
        _reply(id, {'sessionId': 'session-${++_sessions}'});
      case 'session/fork':
        _reply(id, {'sessionId': 'fork-${++_sessions}'});
      default:
        _reply(id, <String, Object?>{});
    }
  }

  Object request(String method, Map<String, Object?> requestParams) {
    final id = 'srv-${++_serverRequests}';
    _push({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': requestParams,
    });
    return id;
  }

  void _reply(Object id, Object? result) =>
      _push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _push(Map<String, Object?> message) {
    if (_closed) return;
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

class _MemoryFileSystem implements AcpRemoteFileSystem {
  final files = <String, String>{};
  final missing = <String>{};

  @override
  Future<String> canonicalizeExistingPath(String path) async {
    if (missing.contains(path)) throw const AcpClientCapabilityException('x');
    return path;
  }

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    final content = files[path];
    if (content == null) {
      throw const AcpClientCapabilityException('Missing file');
    }
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {}
}

class _NoTerminals implements AcpTerminalExecutor {
  @override
  Future<AcpTerminalProcess> start(String command) =>
      throw UnimplementedError();
}

class _Connector implements AcpBridgeConnector {
  _Connector({
    this.http = false,
    this.additionalDirectories = true,
    this.binding,
  });

  final bool http;
  final bool additionalDirectories;
  final AcpHostCapabilityBinding? binding;
  final Map<String, _RecordingAgent> agents = {};
  final Set<String> bridges = {};
  final Set<String> unresolvable = {};
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
    final bridgeId = 'bridge-${++_counter}';
    bridges.add(bridgeId);
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  MonkeyMuxAcpBridgeMetadata _metadata(String bridgeId) =>
      MonkeyMuxAcpBridgeMetadata(
        id: bridgeId,
        provider: 'Copilot CLI',
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
  }) async => [for (final bridgeId in bridges) _metadata(bridgeId)];

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async {
    if (unresolvable.contains(cwd)) throw const AcpWorkingDirectoryException();
    if (cwd == '~') return '/home/test';
    if (cwd.startsWith('~/')) return '/home/test/${cwd.substring(2)}';
    return cwd.startsWith('/') ? cwd : '/home/test/$cwd';
  }

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async => _metadata(bridgeId);

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    bridges.remove(bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    final agent = _RecordingAgent(
      http: http,
      sse: false,
      additionalDirectories: additionalDirectories,
    );
    agents[bridgeId] = agent;
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
  ) async => binding;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

final _stdio = AcpMcpServerConfig(
  id: 'mcp-stdio',
  name: 'filesystem',
  transport: AcpMcpServerTransport.stdio,
  command: '/usr/local/bin/mcp-fs',
  args: const ['--stdio'],
  env: const [AcpMcpNameValue(name: 'TOKEN', value: 'secret')],
  useByDefault: true,
);

final _http = AcpMcpServerConfig(
  id: 'mcp-http',
  name: 'github',
  transport: AcpMcpServerTransport.http,
  url: 'https://mcp.example.com/mcp',
  headers: const [AcpMcpNameValue(name: 'Authorization', value: 'Bearer t')],
  useByDefault: true,
);

final _sse = AcpMcpServerConfig(
  id: 'mcp-sse',
  name: 'events',
  transport: AcpMcpServerTransport.sse,
  url: 'https://events.example.com/sse',
);

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpRecentSessionsService recents;
  late AcpMcpServerService mcpServers;

  AcpSessionManager build(_Connector connector) {
    final manager = AcpSessionManager(
      connector: connector,
      providerService: AcpProviderService(settings),
      recentSessions: recents,
      mcpServerService: mcpServers,
      isProUnlocked: () => true,
      diagnostics: const NoopDiagnosticsLogger(),
    );
    addTearDown(manager.dispose);
    return manager;
  }

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    recents = AcpRecentSessionsService(settings);
    mcpServers = AcpMcpServerService(
      settings,
      SecretEncryptionService.forTesting(),
    );
    for (final server in [_stdio, _http, _sse]) {
      await mcpServers.saveServer(server);
    }
  });

  tearDown(() async {
    await database.close();
  });

  Future<AcpSessionKey> start(
    AcpSessionManager manager, {
    AcpSessionWorkspaceOptions? workspace,
  }) async {
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
      workspace: workspace,
    );
    expect(result, isA<AcpSessionLaunchStarted>());
    return (result as AcpSessionLaunchStarted).key;
  }

  test('session/new sends the default servers and resolved directories when '
      'the agent supports them', () async {
    final connector = _Connector(http: true);
    final manager = build(connector);
    final key = await start(
      manager,
      workspace: AcpSessionWorkspaceOptions(
        additionalDirectories: const ['~/shared', '/repo', '/docs', '/docs'],
      ),
    );

    final params = connector.agents[key.bridgeId]!
        .paramsFor('session/new')
        .single;
    expect(params['cwd'], '/repo');
    expect(params['mcpServers'], [_stdio.toAcpJson(), _http.toAcpJson()]);
    expect(params['additionalDirectories'], ['/home/test/shared', '/docs']);
    expect(manager.state.byKeyValue(key.value)!.warning, isNull);
  });

  test(
    'filters servers by advertised transports and surfaces a notice',
    () async {
      final connector = _Connector(additionalDirectories: false);
      final manager = build(connector);
      final key = await start(
        manager,
        workspace: AcpSessionWorkspaceOptions(
          mcpServerIds: const ['mcp-stdio', 'mcp-http', 'mcp-sse'],
          additionalDirectories: const ['/docs'],
        ),
      );

      final params = connector.agents[key.bridgeId]!
          .paramsFor('session/new')
          .single;
      expect(params['mcpServers'], [_stdio.toAcpJson()]);
      expect(params.containsKey('additionalDirectories'), isFalse);
      final warning = manager.state.byKeyValue(key.value)!.warning!;
      expect(warning.kind, AcpSessionErrorKind.unsupportedCapability);
      expect(warning.message, contains('2 MCP servers were skipped'));
      expect(warning.message, contains('additional directories'));
      expect(warning.message, isNot(contains('github')));
    },
  );

  test('an explicit empty selection sends no servers', () async {
    final connector = _Connector(http: true);
    final manager = build(connector);
    final key = await start(
      manager,
      workspace: AcpSessionWorkspaceOptions(mcpServerIds: const []),
    );
    final params = connector.agents[key.bridgeId]!
        .paramsFor('session/new')
        .single;
    expect(params['mcpServers'], isEmpty);
  });

  test('an unresolvable additional directory fails the launch', () async {
    final connector = _Connector()..unresolvable.add('/missing');
    final manager = build(connector);
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
      workspace: AcpSessionWorkspaceOptions(
        additionalDirectories: const ['/missing'],
      ),
    );
    expect(result, isA<AcpSessionLaunchFailed>());
    expect(connector.bridges, isEmpty);
  });

  test('persists the chosen ids and directories with the recent session and '
      're-sends them on reconnect', () async {
    final connector = _Connector(http: true);
    final first = build(connector);
    final key = await start(
      first,
      workspace: AcpSessionWorkspaceOptions(
        mcpServerIds: const ['mcp-http'],
        additionalDirectories: const ['/docs'],
      ),
    );
    final recent = (await recents.list()).single;
    expect(recent.mcpServerIds, ['mcp-http']);
    expect(recent.additionalDirectories, ['/docs']);

    // A new default must not leak into the reconnected session.
    await mcpServers.saveServer(_sse.copyWith(useByDefault: true));
    await first.detachSession(key);

    final second = build(connector);
    final result = await second.reconnectSession(
      hostId: key.hostId,
      providerId: key.providerId,
      bridgeId: key.bridgeId,
      acpSessionId: key.acpSessionId,
      cwd: '/repo',
    );
    expect(result, isA<AcpSessionLaunchStarted>());
    final resume = connector.agents[key.bridgeId]!
        .paramsFor('session/resume')
        .single;
    expect(resume['sessionId'], key.acpSessionId);
    expect(resume['mcpServers'], [_http.toAcpJson()]);
    expect(resume['additionalDirectories'], ['/docs']);
  });

  test('resuming a discovered session through session/load sends the '
      'workspace', () async {
    final connector = _Connector();
    final manager = build(connector);
    final result = await manager.resumeProviderSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      acpSessionId: 'discovered-1',
      cwd: '/repo',
      workspace: AcpSessionWorkspaceOptions(
        additionalDirectories: const ['/listed-root'],
      ),
    );
    final key = (result as AcpSessionLaunchStarted).key;
    final load = connector.agents[key.bridgeId]!
        .paramsFor('session/load')
        .single;
    expect(load['sessionId'], 'discovered-1');
    // Defaults apply without an explicit choice; HTTP is unsupported here.
    expect(load['mcpServers'], [_stdio.toAcpJson()]);
    expect(load['additionalDirectories'], ['/listed-root']);
  });

  test('fork re-sends the parent session workspace', () async {
    final connector = _Connector(http: true);
    final manager = build(connector);
    final key = await start(
      manager,
      workspace: AcpSessionWorkspaceOptions(
        mcpServerIds: const ['mcp-stdio'],
        additionalDirectories: const ['/docs'],
      ),
    );
    final result = await manager.forkSession(key);
    expect(result, isA<AcpSessionLaunchStarted>());
    final fork = connector.agents[key.bridgeId]!
        .paramsFor('session/fork')
        .single;
    expect(fork['mcpServers'], [_stdio.toAcpJson()]);
    expect(fork['additionalDirectories'], ['/docs']);
    final forkKey = (result as AcpSessionLaunchStarted).key;
    final forkRecent = (await recents.list()).firstWhere(
      (recent) => recent.key == forkKey,
    );
    expect(forkRecent.mcpServerIds, ['mcp-stdio']);
    expect(forkRecent.additionalDirectories, ['/docs']);
  });

  test('fs requests inside an additional directory are allowed', () async {
    final fileSystem = _MemoryFileSystem()
      ..files['/docs/guide.md'] = 'guide'
      ..files['/etc/passwd'] = 'nope'
      // A root that vanished must not make the other roots unusable.
      ..missing.add('/missing-root');
    final connector = _Connector(
      binding: AcpHostCapabilityBinding(
        fileSystem: fileSystem,
        terminalExecutor: _NoTerminals(),
      ),
    );
    final manager = build(connector);
    final key = await start(
      manager,
      workspace: AcpSessionWorkspaceOptions(
        additionalDirectories: const ['/docs', '/missing-root'],
      ),
    );
    final agent = connector.agents[key.bridgeId]!;
    final allowed = agent.request('fs/read_text_file', {
      'sessionId': key.acpSessionId,
      'path': '/docs/guide.md',
    });
    final refused = agent.request('fs/read_text_file', {
      'sessionId': key.acpSessionId,
      'path': '/etc/passwd',
    });
    await _pump();
    expect((agent.responses[allowed]! as Map)['content'], 'guide');
    expect((agent.responses[refused]! as Map).containsKey('code'), isTrue);
  });
}
