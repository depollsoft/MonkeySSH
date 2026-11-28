// ignore_for_file: public_member_api_docs

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
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_mcp_server_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/acp_test_fakes.dart';

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

class _Connector extends FakeAcpBridgeConnector {
  _Connector({
    bool http = false,
    bool additionalDirectories = true,
    super.capabilityBinding,
  }) : super(
         transportFactory: (_, _, _, {required takeOver}) => FakeAcpTransport(
           agentCapabilities: <String, Object?>{
             'loadSession': true,
             'mcpCapabilities': <String, Object?>{'http': http, 'sse': false},
             'sessionCapabilities': <String, Object?>{
               'resume': <String, Object?>{},
               'fork': <String, Object?>{},
               if (additionalDirectories)
                 'additionalDirectories': <String, Object?>{},
             },
           },
         ),
       );

  Set<String> get bridges => availableBridges;
  final Set<String> unresolvable = {};

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
}

Future<void> _pump() => pumpAcpEventLoop();

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

/// Registers tests from acp_session_manager_workspace_test.dart.
void registerDomainServicesAcpSessionManagerWorkspaceTests() {
  group('acp_session_manager_workspace', () {
    late AppDatabase database;
    late SettingsService settings;
    late AcpRecentSessionsService recents;
    late AcpMcpServerService mcpServers;

    AcpSessionManager build(_Connector connector) {
      final manager = AcpSessionManager(
        connector: connector,
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

      final params = connector.transports[key.bridgeId]!
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

        final params = connector.transports[key.bridgeId]!
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
      final params = connector.transports[key.bridgeId]!
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
      final resume = connector.transports[key.bridgeId]!
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
      final load = connector.transports[key.bridgeId]!
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
      final fork = connector.transports[key.bridgeId]!
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
        capabilityBinding: AcpHostCapabilityBinding(
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
      final agent = connector.transports[key.bridgeId]!;
      final allowed = agent.sendServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/docs/guide.md',
      });
      final refused = agent.sendServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/etc/passwd',
      });
      await _pump();
      expect((agent.responses[allowed]!['result']! as Map)['content'], 'guide');
      expect(agent.responses[refused]!.containsKey('error'), isTrue);
    });

    test('directories an agent was not sent are not opened to it', () async {
      final fileSystem = _MemoryFileSystem()
        ..files['/repo/readme.md'] = 'readme'
        ..files['/docs/guide.md'] = 'guide';
      final connector = _Connector(
        additionalDirectories: false,
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _NoTerminals(),
        ),
      );
      final manager = build(connector);
      final key = await start(
        manager,
        workspace: AcpSessionWorkspaceOptions(
          additionalDirectories: const ['/docs'],
        ),
      );
      final agent = connector.transports[key.bridgeId]!;
      expect(
        agent
            .paramsFor('session/new')
            .single
            .containsKey('additionalDirectories'),
        isFalse,
      );
      final cwdRead = agent.sendServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/repo/readme.md',
      });
      final extraRead = agent.sendServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/docs/guide.md',
      });
      await _pump();
      expect(
        (agent.responses[cwdRead]!['result']! as Map)['content'],
        'readme',
      );
      expect(agent.responses[extraRead]!.containsKey('error'), isTrue);
    });
  });
}
