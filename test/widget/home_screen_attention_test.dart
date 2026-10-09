// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';
import 'package:monkeyssh/presentation/providers/connection_attention_provider.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/providers/host_row_providers.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockTmuxService extends Mock implements TmuxService {}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

class _TestTransferIntentService extends TransferIntentService {
  @override
  Stream<String> get incomingPayloads => const Stream<String>.empty();

  @override
  Future<String?> consumeIncomingTransferPayload() async => null;

  @override
  Future<void> dispose() async {}
}

class _TestHomeScreenShortcutService extends HomeScreenShortcutService {
  @override
  Stream<int> get hostLaunches => const Stream<int>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> updateShortcuts({
    required List<Host> hosts,
    required Set<int> pinnedHostIds,
  }) async {}

  @override
  Future<void> dispose() async {}
}

const _workspace = 'mmux';

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(this.sessions);

  final List<SshSession> sessions;

  @override
  Map<int, SshConnectionState> build() => {
    for (final session in sessions)
      session.connectionId: SshConnectionState.connected,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) => [
    for (final session in sessions)
      if (session.hostId == hostId) session.connectionId,
  ];

  @override
  SshSession? getSession(int connectionId) => sessions
      .where((session) => session.connectionId == connectionId)
      .firstOrNull;

  @override
  ActiveConnection? getActiveConnection(int connectionId) {
    if (!state.containsKey(connectionId)) return null;
    final session = getSession(connectionId);
    if (session == null) return null;
    return ActiveConnection(
      connectionId: connectionId,
      hostId: session.hostId,
      state: SshConnectionState.connected,
      createdAt: DateTime(2026),
      config: session.config,
      remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      remoteMuxSessionName: _workspace,
    );
  }

  @override
  List<ActiveConnection> getActiveConnections() => [
    for (final session in sessions) getActiveConnection(session.connectionId)!,
  ];
}

SshSession _session(int connectionId, int hostId) =>
    SshSession(
        connectionId: connectionId,
        hostId: hostId,
        client: _MockSshClient(),
        config: SshConnectionConfig(
          hostname: 'host$hostId.example.com',
          port: 22,
          username: 'dev',
        ),
      )
      ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
      ..remoteMuxSessionName = _workspace;

Host _host(int id, String label) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
  port: 22,
  username: 'dev',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoForwardPorts: false,
  autoConnectRequiresConfirmation: false,
  tmuxSessionName: _workspace,
  remoteMuxBackend: RemoteMuxBackend.monkeyMux.storageValue,
  sortOrder: id,
);

MonkeyMuxAcpBridgeMetadata _bridge({required int pending}) =>
    MonkeyMuxAcpBridgeMetadata(
      id: 'bridge-b',
      providerId: 'builtin:claude-code',
      sessionId: 'remote-session',
      cwd: '/home/dev/api',
      provider: 'Claude Code',
      commandHash: 'hash',
      state: MonkeyMuxAcpProviderState.running,
      clientCount: 0,
      pendingRequestCount: pending,
      inFlightTurnCount: 0,
      lastActivity: DateTime.now(),
      startedAt: DateTime(2026),
      nextSequence: 1,
    );

void main() {
  late AppDatabase db;
  late _MockMonkeyMuxService monkeyMux;
  late FakeAcpSessionManager manager;
  late List<String> opened;
  late GoRouter router;
  var hostBPending = 0;
  final sessions = [_session(7, 1), _session(8, 2)];

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    monkeyMux = _MockMonkeyMuxService();
    manager = FakeAcpSessionManager();
    opened = [];
    hostBPending = 0;
    for (final session in sessions) {
      when(
        () => monkeyMux.watchWindowChanges(
          session,
          _workspace,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) {
        final controller = StreamController<TmuxWindowChangeEvent>(
          onCancel: () async {},
        );
        addTearDown(controller.close);
        return controller.stream;
      });
      when(
        () => monkeyMux.listWindows(
          session,
          _workspace,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer(
        (_) async => const [
          TmuxWindow(index: 0, name: 'shell', isActive: true),
        ],
      );
    }
    Widget record(GoRouterState state) {
      opened.add(state.uri.toString());
      return const Scaffold(body: Text('opened'));
    }

    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const HomeScreen(initialTab: HomeScreenTab.connections),
        ),
        GoRoute(
          path: '/terminal/:hostId',
          builder: (context, state) => record(state),
        ),
        GoRoute(
          path: '/agents/chat',
          builder: (context, state) => record(state),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await manager.dispose();
    await db.close();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          agentLaunchPresetMapProvider.overrideWith(
            (ref) => Stream.value(const <String, AgentLaunchPreset>{}),
          ),
          transferIntentServiceProvider.overrideWith(
            (ref) => _TestTransferIntentService(),
          ),
          homeScreenShortcutServiceProvider.overrideWith(
            (ref) => _TestHomeScreenShortcutService(),
          ),
          pinnedHomeScreenShortcutHostIdsProvider.overrideWith(
            (ref) => Stream<Set<int>>.value(const <int>{}),
          ),
          activeSessionsProvider.overrideWith(() => _Sessions(sessions)),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([_host(1, 'Alpha'), _host(2, 'Beta')]),
          ),
          tmuxServiceProvider.overrideWithValue(_MockTmuxService()),
          monkeyMuxServiceProvider.overrideWithValue(monkeyMux),
          acpSessionManagerProvider.overrideWithValue(manager),
          connectionBridgeListerProvider.overrideWithValue(
            (session) async =>
                session.hostId == 2 ? [_bridge(pending: hostBPending)] : [],
          ),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'a request on another host reaches the top within one poll and opens it',
    (tester) async {
      await pumpHome(tester);
      expect(find.text('waiting on you'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);

      hostBPending = 1;
      await tester.pump(connectionAttentionPollInterval);
      await tester.pump();

      expect(find.text('waiting on you'), findsOneWidget);
      expect(find.text('request'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('waiting on you')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
        reason: 'The section sits above every connection.',
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final location = Uri.parse(opened.single);
      expect(location.path, '/terminal/2');
      expect(location.queryParameters, {
        'connectionId': '8',
        'p': 'builtin:claude-code',
        'b': 'bridge-b',
        's': 'remote-session',
      });
    },
  );

  testWidgets('a tracked permission request opens its chat at once', (
    tester,
  ) async {
    await pumpHome(tester);
    final waiting = fakeAcpSession(
      key: fakeAcpKey(hostId: 2, bridgeId: 'bridge-b'),
      title: 'Ship the fix',
      pendingPermissions: [
        AcpPendingPermission(
          requestKey: 'r1',
          sessionId: 'session-1',
          toolCallId: 't1',
          options: const [],
          requestedAt: DateTime.now(),
        ),
      ],
    );
    manager.emit(AcpSessionManagerState(sessions: [waiting]));
    await tester.pump();
    await tester.pump();

    expect(find.text('Ship the fix'), findsOneWidget);
    expect(find.text('permission'), findsOneWidget);

    await tester.tap(find.text('Ship the fix'));
    await tester.pumpAndSettle();
    final location = Uri.parse(opened.single);
    expect(location.path, '/agents/chat');
    expect(location.queryParameters, {
      'h': '2',
      'p': waiting.key.providerId,
      'b': 'bridge-b',
      's': 'session-1',
    });
  });
}
