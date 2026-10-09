// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/connection_attention_provider.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';

import '../../support/fake_acp_session_manager.dart';

class _MockSshClient extends Mock implements SSHClient {}

SshSession _session({
  required int connectionId,
  required int hostId,
  RemoteMuxBackend? backend = RemoteMuxBackend.monkeyMux,
}) => SshSession(
  connectionId: connectionId,
  hostId: hostId,
  client: _MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.test',
    port: 22,
    username: 'dev',
  ),
)..remoteMuxBackend = backend;

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(List<SshSession> sessions) : sessions = [...sessions];

  final List<SshSession> sessions;

  void replace(List<SshSession> next) {
    sessions
      ..clear()
      ..addAll(next);
    state = {
      for (final session in sessions)
        session.connectionId: SshConnectionState.connected,
    };
  }

  @override
  Map<int, SshConnectionState> build() => {
    for (final session in sessions)
      session.connectionId: SshConnectionState.connected,
  };

  @override
  SshSession? getSession(int connectionId) => sessions
      .where((session) => session.connectionId == connectionId)
      .firstOrNull;

  @override
  ActiveConnection? getActiveConnection(int connectionId) {
    final session = getSession(connectionId);
    if (session == null) return null;
    return ActiveConnection(
      connectionId: connectionId,
      hostId: session.hostId,
      state: SshConnectionState.connected,
      createdAt: DateTime(2026),
      config: session.config,
    );
  }

  void dropAll() => state = const {};
}

TmuxWindow _nativeWindow(String bridgeId) => TmuxWindow(
  index: 3,
  name: 'agent',
  isActive: false,
  nativeAcpBridgeId: bridgeId,
  nativeAcpProviderId: 'builtin:copilot-cli',
);

ProviderContainer _container({
  required _Sessions sessions,
  required FakeAcpSessionManager manager,
  required ConnectionBridgeLister lister,
}) => ProviderContainer(
  overrides: [
    activeSessionsProvider.overrideWith(() => sessions),
    acpSessionManagerProvider.overrideWithValue(manager),
    allHostsProvider.overrideWith((ref) => Stream.value(const [])),
    connectionBridgeListerProvider.overrideWithValue(lister),
  ],
);

HostBridgeMetadata _read(ProviderContainer container) =>
    container.read(connectionBridgeMetadataProvider);

MonkeyMuxAcpBridgeMetadata _bridge({
  String id = 'bridge-1',
  String? providerId = 'builtin:copilot-cli',
  String? sessionId = 'session-1',
  int pending = 0,
  int inFlight = 0,
  int clients = 0,
  DateTime? lastActivity,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  providerId: providerId,
  sessionId: sessionId,
  cwd: '/home/dev/project',
  provider: 'Copilot CLI',
  commandHash: 'hash',
  state: MonkeyMuxAcpProviderState.running,
  clientCount: clients,
  pendingRequestCount: pending,
  inFlightTurnCount: inFlight,
  lastActivity: lastActivity ?? DateTime(2026, 1, 1, 12),
  startedAt: DateTime(2026),
  nextSequence: 1,
);

AcpPendingPermission _permission(DateTime at) => AcpPendingPermission(
  requestKey: 'r1',
  sessionId: 'session-1',
  toolCallId: 't1',
  options: const [],
  requestedAt: at,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildWaitingOnYouItems', () {
    test('lists blocked sessions on connected hosts only', () {
      final onB = fakeAcpSession(
        key: fakeAcpKey(hostId: 2, bridgeId: 'b2'),
        title: 'Fix the flaky test',
        pendingPermissions: [_permission(DateTime(2026, 1, 1, 11))],
      );
      final disconnected = fakeAcpSession(
        key: fakeAcpKey(hostId: 3, bridgeId: 'b3'),
        pendingPermissions: [_permission(DateTime(2026))],
      );
      final idle = fakeAcpSession(key: fakeAcpKey());

      final items = buildWaitingOnYouItems(
        sessions: [idle, onB, disconnected],
        bridges: HostBridgeMetadata.empty,
        connectedHosts: const {1, 2},
        hostLabels: const {2: 'Beta'},
      );

      expect(items, hasLength(1));
      final item = items.single;
      expect(item.reason, AttentionReason.permission);
      expect(item.key, onB.key);
      expect(item.hostLabel, 'Beta');
      expect(item.title, 'Fix the flaky test');
      expect(item.since, DateTime(2026, 1, 1, 11));
      expect(item.tracked, isTrue);
      expect(item.chatLocation, startsWith('/agents/chat?'));
      expect(Uri.parse(item.chatLocation).queryParameters['b'], 'b2');
      expect(Uri.parse(item.chatLocation).queryParameters['s'], 'session-1');
    });

    test('adds host-reported requests for detached and untracked bridges', () {
      final detached = fakeAcpSession(
        key: fakeAcpKey(bridgeId: 'tracked'),
        status: AcpConnectionStatus.detached,
      );
      final bridges = HostBridgeMetadata(const {}).withHost(
        1,
        HostBridges(
          connectionId: 10,
          bridges: [
            _bridge(id: 'tracked', pending: 1),
            _bridge(
              id: 'untracked',
              sessionId: 'remote-session',
              pending: 2,
              lastActivity: DateTime(2026, 1, 1, 13),
            ),
            _bridge(id: 'no-session', sessionId: null, pending: 1),
            _bridge(id: 'quiet', sessionId: 'quiet-session'),
            // Another client is attached and answers its own requests.
            _bridge(
              id: 'attached',
              sessionId: 'elsewhere',
              pending: 1,
              clients: 1,
            ),
          ],
        ),
      );

      final items = buildWaitingOnYouItems(
        sessions: [detached],
        bridges: bridges,
        connectedHosts: const {1},
        hostLabels: const {1: 'Alpha'},
      );

      expect(items.map((item) => item.key.bridgeId), ['untracked', 'tracked']);
      expect(
        items.map((item) => item.reason),
        everyElement(AttentionReason.hostRequest),
      );
      expect(items.first.tracked, isFalse);
      expect(items.first.key.acpSessionId, 'remote-session');
    });

    test('a detached request answered elsewhere leaves the list', () {
      final detached = fakeAcpSession(
        key: fakeAcpKey(bridgeId: 'b1'),
        status: AcpConnectionStatus.detached,
        pendingPermissions: [_permission(DateTime(2026))],
      );
      List<WaitingOnYouItem> items(int pending) => buildWaitingOnYouItems(
        sessions: [detached],
        bridges: HostBridgeMetadata(const {}).withHost(
          1,
          HostBridges(
            connectionId: 10,
            bridges: [_bridge(id: 'b1', pending: pending)],
          ),
        ),
        connectedHosts: const {1},
        hostLabels: const {},
      );
      expect(items(1).single.reason, AttentionReason.permission);
      expect(items(0), isEmpty);
    });

    test('a detached request whose agent was stopped elsewhere leaves', () {
      final detached = fakeAcpSession(
        key: fakeAcpKey(bridgeId: 'b1'),
        status: AcpConnectionStatus.detached,
        pendingPermissions: [_permission(DateTime(2026))],
      );
      List<WaitingOnYouItem> items(HostBridgeMetadata bridges) =>
          buildWaitingOnYouItems(
            sessions: [detached],
            bridges: bridges,
            connectedHosts: const {1},
            hostLabels: const {},
          );
      // The stopped bridge no longer appears in `acp list`.
      expect(
        items(
          HostBridgeMetadata(const {})
              .withHost(1, HostBridges(connectionId: 10, bridges: const [])),
        ),
        isEmpty,
      );
      // Before the first poll after returning, retained requests are not
      // claimed either; they may have been answered meanwhile.
      expect(items(HostBridgeMetadata.empty), isEmpty);
    });

    test('orders permission before sign-in, then most recent first', () {
      AcpSessionState waiting(String bridgeId, DateTime at) => fakeAcpSession(
        key: fakeAcpKey(bridgeId: bridgeId),
        lastActivityAt: at,
        pendingPermissions: [_permission(at)],
      );
      final items = buildWaitingOnYouItems(
        sessions: [
          fakeAcpSession(
            key: fakeAcpKey(bridgeId: 'auth'),
            status: AcpConnectionStatus.authenticationRequired,
            lastActivityAt: DateTime(2027),
          ),
          waiting('older', DateTime(2026)),
          waiting('newer', DateTime(2026, 6)),
        ],
        bridges: HostBridgeMetadata.empty,
        connectedHosts: const {1},
        hostLabels: const {},
      );
      expect(items.map((item) => item.key.bridgeId), [
        'newer',
        'older',
        'auth',
      ]);
      expect(items.last.reason, AttentionReason.signIn);
      expect(items.first.hostLabel, 'Host 1');
    });
  });

  group('resolveWaitingOnYouLocation', () {
    WaitingOnYouItem untracked() => buildWaitingOnYouItems(
      sessions: const [],
      bridges: HostBridgeMetadata(const {}).withHost(
        1,
        HostBridges(connectionId: 10, bridges: [_bridge(pending: 1)]),
      ),
      connectedHosts: const {1},
      hostLabels: const {},
    ).single;

    test('opens the workspace whose window hosts the bridge', () async {
      final polled = _session(connectionId: 10, hostId: 1)
        ..remoteMuxSessionName = 'a';
      final owner = _session(connectionId: 11, hostId: 1)
        ..remoteMuxSessionName = 'b';
      final location = Uri.parse(
        await resolveWaitingOnYouLocation(
          untracked(),
          sessions: [polled, owner],
          listWindows: (session, workspace) async =>
              workspace == 'b' ? [_nativeWindow('bridge-1')] : const [],
        ),
      );
      expect(location.path, '/terminal/1');
      expect(location.queryParameters, {
        'connectionId': '11',
        'p': 'builtin:copilot-cli',
        'b': 'bridge-1',
        's': 'session-1',
      });
    });

    test('falls back to the chat when no window hosts the bridge', () async {
      final location = await resolveWaitingOnYouLocation(
        untracked(),
        sessions: [
          _session(connectionId: 10, hostId: 1)..remoteMuxSessionName = 'a',
        ],
        listWindows: (session, workspace) async => const [],
      );
      expect(location, untracked().chatLocation);
    });

    test('a tracked session opens its chat without listing windows', () async {
      final item = buildWaitingOnYouItems(
        sessions: [
          fakeAcpSession(pendingPermissions: [_permission(DateTime(2026))]),
        ],
        bridges: HostBridgeMetadata.empty,
        connectedHosts: const {1},
        hostLabels: const {},
      ).single;
      final location = await resolveWaitingOnYouLocation(
        item,
        sessions: [_session(connectionId: 10, hostId: 1)],
        listWindows: (session, workspace) => throw StateError('not expected'),
      );
      expect(location, item.chatLocation);
    });
  });

  test('a change in attached clients is a change in the snapshot', () {
    HostBridges host(int clients) => HostBridges(
      connectionId: 10,
      bridges: [_bridge(pending: 1, clients: clients)],
    );
    expect(host(0), host(0));
    expect(host(0), isNot(host(1)));
  });

  group('connectionBridgeMetadataProvider', () {
    test('polls connected MonkeyMux hosts once per interval', () {
      fakeAsync((async) {
        final monkeyMux = _session(connectionId: 10, hostId: 1);
        final plainShell = _session(connectionId: 20, hostId: 2, backend: null);
        final sessions = _Sessions([monkeyMux, plainShell]);
        final manager = FakeAcpSessionManager();
        final polled = <int>[];
        var pending = 1;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) async {
            polled.add(session.connectionId);
            return [_bridge(pending: pending)];
          },
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();

        expect(polled, [10], reason: 'Plain shells are never probed.');
        expect(_read(container).bridge(1, 'bridge-1')?.pendingRequestCount, 1);

        pending = 0;
        async.elapse(connectionAttentionPollInterval);
        expect(polled, [10, 10]);
        expect(_read(container).bridge(1, 'bridge-1')?.pendingRequestCount, 0);

        sessions.dropAll();
        async.elapse(connectionAttentionPollInterval);
        expect(polled, [10, 10], reason: 'Disconnected hosts drop out.');
        expect(_read(container).hosts, isEmpty);

        subscription.close();
        async.elapse(connectionAttentionPollInterval * 3);
        expect(polled, [10, 10], reason: 'Polling stops with its watchers.');
        container.dispose();
        unawaited(manager.dispose());
      });
    });

    test('a watcher rebuilt by each result does not trigger extra polls', () {
      fakeAsync((async) {
        final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
        final manager = FakeAcpSessionManager();
        var calls = 0;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) async {
            calls++;
            if (calls > 20) throw StateError('poll loop');
            // A running agent's activity time moves on every read.
            return [
              _bridge(lastActivity: DateTime.fromMillisecondsSinceEpoch(calls)),
            ];
          },
        );
        final subscription = container.listen(waitingOnYouProvider, (_, _) {});
        for (var tick = 0; tick < 50; tick++) {
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 20));
        }
        expect(calls, 1);
        async.elapse(connectionAttentionPollInterval);
        expect(calls, 2);

        subscription.close();
        container.dispose();
        unawaited(manager.dispose());
      });
    });

    test('stops polling without watchers but keeps the snapshot briefly', () {
      fakeAsync((async) {
        final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
        final manager = FakeAcpSessionManager();
        var calls = 0;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) async {
            calls++;
            return [_bridge(pending: 1)];
          },
        );
        var subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();
        expect(calls, 1);

        subscription.close();
        async.elapse(connectionAttentionPollInterval * 2);
        expect(calls, 1);
        expect(_read(container).hosts, contains(1));

        subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();
        expect(calls, 2, reason: 'A returning watcher refreshes at once.');

        subscription.close();
        async
          ..elapse(
            connectionAttentionRetainAfterHidden + const Duration(seconds: 2),
          )
          ..flushMicrotasks();
        subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        expect(
          subscription.read().hosts,
          isEmpty,
          reason: 'The snapshot is dropped after the grace period.',
        );
        subscription.close();
        container.dispose();
        unawaited(manager.dispose());
      });
    });

    test('drops a failing host and backs off its retries', () {
      fakeAsync((async) {
        final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
        final manager = FakeAcpSessionManager();
        var fail = false;
        var calls = 0;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) async {
            calls++;
            if (fail) throw StateError('channel closed');
            return [_bridge(pending: 1)];
          },
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();
        expect(_read(container).hosts, contains(1));

        fail = true;
        // Failed attempts at 5 s, 10 s, 20 s and 40 s: retries wait 1, 2 and
        // 4 intervals rather than reopening a channel every five seconds.
        async.elapse(connectionAttentionPollInterval);
        expect(_read(container).hosts, isEmpty);
        expect(calls, 2);
        async.elapse(connectionAttentionPollInterval * 6);
        expect(calls, 4);
        async.elapse(connectionAttentionPollInterval);
        expect(calls, 5);

        subscription.close();
        container.dispose();
        unawaited(manager.dispose());
      });
    });

    test('a failure that lands after the host switched connection is '
        'ignored', () {
      fakeAsync((async) {
        final old = _session(connectionId: 10, hostId: 1);
        final sessions = _Sessions([old]);
        final manager = FakeAcpSessionManager();
        final oldList = Completer<List<MonkeyMuxAcpBridgeMetadata>>();
        var calls = 0;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) async {
            calls++;
            if (identical(session, old)) return oldList.future;
            return [_bridge(pending: 1)];
          },
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();

        sessions.replace([_session(connectionId: 11, hostId: 1)]);
        async.elapse(connectionAttentionPollInterval);
        expect(_read(container).hosts[1]?.connectionId, 11);

        oldList.completeError(StateError('channel closed'));
        async.flushMicrotasks();
        expect(
          _read(container).hosts[1]?.connectionId,
          11,
          reason: 'The old failure does not drop the new state.',
        );
        async.elapse(connectionAttentionPollInterval);
        expect(calls, 3, reason: 'Nor does it back off the new connection.');

        subscription.close();
        container.dispose();
        unawaited(manager.dispose());
      });
    });

    test('a list that finishes after its host disconnects is dropped', () {
      fakeAsync((async) {
        final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
        final manager = FakeAcpSessionManager();
        final pendingList = Completer<List<MonkeyMuxAcpBridgeMetadata>>();
        var calls = 0;
        final container = _container(
          sessions: sessions,
          manager: manager,
          lister: (session) {
            calls++;
            return pendingList.future;
          },
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async
          ..flushMicrotasks()
          ..elapse(connectionAttentionPollInterval * 2);
        expect(calls, 1, reason: 'Overlapping polls share one request.');

        sessions.dropAll();
        pendingList.complete([_bridge(pending: 1)]);
        async.flushMicrotasks();
        expect(_read(container).hosts, isEmpty);

        subscription.close();
        container.dispose();
        unawaited(manager.dispose());
      });
    });
  });

  testWidgets('polling follows the app lifecycle, not window focus', (
    tester,
  ) async {
    final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
    final manager = FakeAcpSessionManager();
    var calls = 0;
    final container = _container(
      sessions: sessions,
      manager: manager,
      lister: (session) async {
        calls++;
        return [_bridge(pending: 1)];
      },
    );
    final subscription = container.listen(
      connectionBridgeMetadataProvider,
      (_, _) {},
    );
    await tester.pump();
    expect(calls, 1);

    // An unfocused desktop or split-screen window is still on screen.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(connectionAttentionPollInterval);
    expect(calls, 2);

    for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(
      _read(container).hosts,
      isEmpty,
      reason: 'Stale counts are dropped.',
    );
    await tester.pump(connectionAttentionPollInterval * 3);
    expect(calls, 2);

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(calls, 3, reason: 'Returning to the foreground refreshes at once.');
    expect(_read(container).hosts, contains(1));

    // With nothing watching, returning does not run an unwatched poll.
    subscription.close();
    await tester.pump(const Duration(seconds: 2));
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(calls, 3);

    container.dispose();
    await manager.dispose();
  });

  test('waitingOnYouProvider surfaces a request within one poll', () {
    fakeAsync((async) {
      final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
      final manager = FakeAcpSessionManager();
      var pending = 0;
      final container = _container(
        sessions: sessions,
        manager: manager,
        lister: (session) async => [_bridge(pending: pending)],
      );
      final subscription = container.listen(waitingOnYouProvider, (_, _) {});
      async.flushMicrotasks();
      expect(container.read(waitingOnYouProvider).items, isEmpty);

      pending = 1;
      async.elapse(connectionAttentionPollInterval);
      final items = container.read(waitingOnYouProvider).items;
      expect(items, hasLength(1));
      expect(
        items.single.key,
        AcpSessionKey.of(
          hostId: 1,
          providerId: 'builtin:copilot-cli',
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
        ),
      );

      subscription.close();
      container.dispose();
      unawaited(manager.dispose());
    });
  });
}
