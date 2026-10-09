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
      remoteMuxSessionName: session.remoteMuxSessionName,
    );
  }

  @override
  List<ActiveConnection> getActiveConnections() => [
    for (final session in sessions) getActiveConnection(session.connectionId)!,
  ];
}

SshSession _session(
  int connectionId,
  int hostId, {
  String workspace = _workspace,
}) =>
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
      ..remoteMuxSessionName = workspace;

const _shell = TmuxWindow(index: 0, name: 'shell', isActive: true);

TmuxWindow _nativeWindow(String bridgeId, String providerId) => TmuxWindow(
  index: 1,
  name: 'agent',
  isActive: false,
  nativeAcpBridgeId: bridgeId,
  nativeAcpProviderId: providerId,
);

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
  late Map<int, List<TmuxWindow>> windows;
  var hostBPending = 0;
  var listCalls = 0;
  // Host 2 has two MonkeyMux workspaces; its waiting bridge lives in the
  // second, which is not the connection the poller happens to use.
  final sessions = [
    _session(7, 1),
    _session(8, 2),
    _session(9, 2, workspace: 'side'),
  ];

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    monkeyMux = _MockMonkeyMuxService();
    manager = FakeAcpSessionManager();
    opened = [];
    hostBPending = 0;
    listCalls = 0;
    windows = {
      7: const [_shell],
      8: const [_shell],
      9: [_shell, _nativeWindow('bridge-b', 'builtin:claude-code')],
    };
    for (final session in sessions) {
      final workspace = session.remoteMuxSessionName!;
      when(
        () => monkeyMux.watchWindowChanges(
          session,
          workspace,
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
          workspace,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async => windows[session.connectionId]!);
      when(
        () => monkeyMux.killWindow(
          session,
          workspace,
          any(),
          windowId: any(named: 'windowId'),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});
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
        // Like the app's terminal route: not opaque, so Home keeps its
        // tickers underneath it.
        GoRoute(
          path: '/terminal/:hostId',
          pageBuilder: (context, state) => CustomTransitionPage<void>(
            opaque: false,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            transitionsBuilder: (context, animation, secondary, child) => child,
            child: record(state),
          ),
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
    // Tall enough that every connection row is built.
    tester.view
      ..physicalSize = const Size(1200, 6000)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
          connectionBridgeListerProvider.overrideWithValue((session) async {
            listCalls++;
            return session.hostId == 2 ? [_bridge(pending: hostBPending)] : [];
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'a request on another host reaches the top within one poll and opens '
    'the workspace that hosts it',
    (tester) async {
      final semantics = tester.ensureSemantics();
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
      expect(
        find.bySemanticsLabel(RegExp('1 window needs attention')),
        findsOneWidget,
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final location = Uri.parse(opened.single);
      expect(location.path, '/terminal/2');
      expect(location.queryParameters, {
        'connectionId': '9',
        'p': 'builtin:claude-code',
        'b': 'bridge-b',
        's': 'remote-session',
      });
      semantics.dispose();
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

    expect(find.text('Ship the fix'), findsWidgets);
    expect(find.text('permission'), findsWidgets);

    await tester.tap(find.text('Ship the fix').first);
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

  testWidgets('polling stops while a terminal covers Connections', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.pump(connectionAttentionPollInterval);
    expect(listCalls, greaterThan(0));

    await tester.tap(find.text('Alpha'));
    // Home's cursor keeps blinking under a non-opaque route, so this cannot
    // settle; pump the push explicitly.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened.single, '/terminal/1?connectionId=7');
    final callsUnderTerminal = listCalls;
    await tester.pump(connectionAttentionPollInterval * 4);
    expect(listCalls, callsUnderTerminal);

    router.pop();
    await tester.pump();
    await tester.pump();
    expect(
      listCalls,
      greaterThan(callsUnderTerminal),
      reason: 'Back on Connections, it refreshes at once.',
    );
  });

  testWidgets('closing a bound native window asks first and closes the '
      'window instead of stopping the agent', (tester) async {
    windows[7] = [_shell, _nativeWindow('bridge-a', 'builtin:copilot-cli')];
    final bound = fakeAcpSession(key: fakeAcpKey(bridgeId: 'bridge-a'));
    manager.emit(AcpSessionManagerState(sessions: [bound]));
    await pumpHome(tester);

    await tester.tap(find.text('$_workspace · 2 windows').first);
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('connection-native-acp-close-${bound.key.value}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Close window?'), findsOneWidget);
    expect(manager.stopped, isEmpty);

    await tester.tap(find.text('Close window'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    verify(
      () => monkeyMux.killWindow(
        sessions.first,
        _workspace,
        1,
        windowId: any(named: 'windowId'),
        extraFlags: any(named: 'extraFlags'),
      ),
    ).called(1);
    expect(manager.releasedMuxBridges, [(hostId: 1, bridgeId: 'bridge-a')]);
    expect(manager.stopped, isEmpty);
  });
}
