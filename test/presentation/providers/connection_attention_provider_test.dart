// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
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
  _Sessions(this.sessions);

  final List<SshSession> sessions;

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

MonkeyMuxAcpBridgeMetadata _bridge({
  String id = 'bridge-1',
  String? providerId = 'builtin:copilot-cli',
  String? sessionId = 'session-1',
  int pending = 0,
  int inFlight = 0,
  DateTime? lastActivity,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  providerId: providerId,
  sessionId: sessionId,
  cwd: '/home/dev/project',
  provider: 'Copilot CLI',
  commandHash: 'hash',
  state: MonkeyMuxAcpProviderState.running,
  clientCount: 0,
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
        connectedHosts: const {1: 10, 2: 20},
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
      expect(item.location, startsWith('/agents/chat?'));
      expect(Uri.parse(item.location).queryParameters['b'], 'b2');
      expect(Uri.parse(item.location).queryParameters['s'], 'session-1');
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
          ],
        ),
      );

      final items = buildWaitingOnYouItems(
        sessions: [detached],
        bridges: bridges,
        connectedHosts: const {1: 10},
        hostLabels: const {1: 'Alpha'},
      );

      expect(items.map((item) => item.key.bridgeId), ['untracked', 'tracked']);
      expect(
        items.map((item) => item.reason),
        everyElement(AttentionReason.hostRequest),
      );
      final untracked = items.first;
      expect(untracked.tracked, isFalse);
      final location = Uri.parse(untracked.location);
      expect(location.path, '/terminal/1');
      expect(location.queryParameters['connectionId'], '10');
      expect(location.queryParameters['b'], 'untracked');
      expect(location.queryParameters['s'], 'remote-session');
      expect(location.queryParameters['p'], 'builtin:copilot-cli');
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
        connectedHosts: const {1: 10},
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

  group('connectionBridgeMetadataProvider', () {
    test('polls connected MonkeyMux hosts once per interval', () {
      fakeAsync((async) {
        final monkeyMux = _session(connectionId: 10, hostId: 1);
        final plainShell = _session(connectionId: 20, hostId: 2, backend: null);
        final sessions = _Sessions([monkeyMux, plainShell]);
        final manager = FakeAcpSessionManager();
        final polled = <int>[];
        var pending = 1;
        final container = ProviderContainer(
          overrides: [
            activeSessionsProvider.overrideWith(() => sessions),
            acpSessionManagerProvider.overrideWithValue(manager),
            connectionBridgeListerProvider.overrideWithValue((session) async {
              polled.add(session.connectionId);
              return [_bridge(pending: pending)];
            }),
          ],
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();

        expect(polled, [10], reason: 'Plain shells are never probed.');
        expect(
          container
              .read(connectionBridgeMetadataProvider)
              .bridge(1, 'bridge-1')
              ?.pendingRequestCount,
          1,
        );

        pending = 0;
        async.elapse(connectionAttentionPollInterval);
        expect(polled, [10, 10]);
        expect(
          container
              .read(connectionBridgeMetadataProvider)
              .bridge(1, 'bridge-1')
              ?.pendingRequestCount,
          0,
        );

        sessions.dropAll();
        async.elapse(connectionAttentionPollInterval);
        expect(polled, [10, 10], reason: 'Disconnected hosts drop out.');
        expect(container.read(connectionBridgeMetadataProvider).hosts, isEmpty);

        subscription.close();
        async.elapse(connectionAttentionPollInterval * 3);
        expect(polled, [10, 10], reason: 'Polling stops with its watchers.');
        container.dispose();
        manager.dispose();
      });
    });

    test('drops a host whose bridge list fails', () {
      fakeAsync((async) {
        final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
        final manager = FakeAcpSessionManager();
        var fail = false;
        final container = ProviderContainer(
          overrides: [
            activeSessionsProvider.overrideWith(() => sessions),
            acpSessionManagerProvider.overrideWithValue(manager),
            connectionBridgeListerProvider.overrideWithValue((session) async {
              if (fail) throw StateError('channel closed');
              return [_bridge(pending: 1)];
            }),
          ],
        );
        final subscription = container.listen(
          connectionBridgeMetadataProvider,
          (_, _) {},
        );
        async.flushMicrotasks();
        expect(container.read(connectionBridgeMetadataProvider).hosts, {
          1: isA<HostBridges>(),
        });

        fail = true;
        async.elapse(connectionAttentionPollInterval);
        expect(container.read(connectionBridgeMetadataProvider).hosts, isEmpty);

        subscription.close();
        container.dispose();
        manager.dispose();
      });
    });
  });

  test('waitingOnYouProvider surfaces a request within one poll', () {
    fakeAsync((async) {
      final sessions = _Sessions([_session(connectionId: 10, hostId: 1)]);
      final manager = FakeAcpSessionManager();
      var pending = 0;
      final container = ProviderContainer(
        overrides: [
          activeSessionsProvider.overrideWith(() => sessions),
          acpSessionManagerProvider.overrideWithValue(manager),
          allHostsProvider.overrideWith((ref) => Stream.value(const [])),
          connectionBridgeListerProvider.overrideWithValue(
            (session) async => [_bridge(pending: pending)],
          ),
        ],
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
      manager.dispose();
    });
  });
}
