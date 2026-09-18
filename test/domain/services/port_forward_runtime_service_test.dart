// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/port_forward_runtime_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

class _MockRemoteForward extends Mock implements SSHRemoteForward {}

class _MockServerSocket extends Mock implements ServerSocket {}

class _ShortTimeoutSshSession extends SshSession {
  _ShortTimeoutSshSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    this.socketBinder,
  }) : super(
         config: const SshConnectionConfig(
           hostname: 'example.com',
           port: 22,
           username: 'user',
         ),
       );

  final Future<ServerSocket> Function(Object host, int port, {bool v6Only})?
  socketBinder;

  @override
  Duration get portForwardStartTimeout => const Duration(milliseconds: 10);

  @override
  Future<ServerSocket> bindPortForwardServerSocket(
    Object host,
    int port, {
    bool v6Only = false,
  }) {
    final binder = socketBinder;
    if (binder != null) {
      return binder(host, port, v6Only: v6Only);
    }
    return super.bindPortForwardServerSocket(host, port, v6Only: v6Only);
  }
}

class _RecordingSshSession extends SshSession {
  _RecordingSshSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    this.startSucceeds = true,
    this.replaceGate,
  }) : super(
         config: const SshConnectionConfig(
           hostname: 'example.com',
           port: 22,
           username: 'user',
         ),
       );

  final bool startSucceeds;
  final Completer<void>? replaceGate;
  final Map<int, ActiveTunnelInfo> tunnels = {};
  final List<int> localStarts = [];
  final List<int> remoteStarts = [];
  final List<int> stops = [];
  final changes = StreamController<void>.broadcast();

  @override
  List<ActiveTunnelInfo> get activeTunnels => tunnels.values.toList();

  @override
  Stream<void> get portForwardChanges => changes.stream;

  @override
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    localStarts.add(portForwardId);
    if (!startSucceeds) {
      return false;
    }
    tunnels[portForwardId] = ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      isLocal: true,
    );
    changes.add(null);
    return true;
  }

  @override
  Future<bool> startRemoteForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String localHost,
    required int localPort,
  }) async {
    remoteStarts.add(portForwardId);
    if (!startSucceeds) {
      return false;
    }
    tunnels[portForwardId] = ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      isLocal: false,
    );
    changes.add(null);
    return true;
  }

  @override
  Future<void> stopForward(int portForwardId) async {
    stops.add(portForwardId);
    if (tunnels.remove(portForwardId) != null) {
      changes.add(null);
    }
  }

  @override
  Future<bool> replacePortForward(PortForward portForward) async {
    await replaceGate?.future;
    await stopForward(portForward.id);
    return startPortForward(portForward);
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.sessions);

  final List<SshSession> sessions;

  @override
  Map<int, SshConnectionState> build() => {
    for (final session in sessions)
      session.connectionId: SshConnectionState.connected,
  };

  @override
  List<int> getConnectionsForHost(int hostId) => sessions
      .where((session) => session.hostId == hostId)
      .map((session) => session.connectionId)
      .toList(growable: false);

  @override
  SshConnectionState getState(int connectionId) =>
      sessions.any((session) => session.connectionId == connectionId)
      ? SshConnectionState.connected
      : SshConnectionState.disconnected;

  @override
  SshSession? getSession(int connectionId) => sessions
      .where((session) => session.connectionId == connectionId)
      .firstOrNull;
}

PortForward _portForward({
  int id = 1,
  int hostId = 10,
  String forwardType = 'local',
  int localPort = 8080,
  int remotePort = 80,
  bool autoStart = true,
}) => PortForward(
  id: id,
  name: 'Web',
  hostId: hostId,
  forwardType: forwardType,
  localHost: '127.0.0.1',
  localPort: localPort,
  remoteHost: 'localhost',
  remotePort: remotePort,
  autoStart: autoStart,
  createdAt: DateTime(2026),
);

void _stubRemoteForward(
  _MockRemoteForward remoteForward, {
  required int port,
  Stream<SSHForwardChannel> connections =
      const Stream<SSHForwardChannel>.empty(),
}) {
  when(() => remoteForward.host).thenReturn('localhost');
  when(() => remoteForward.port).thenReturn(port);
  when(() => remoteForward.connections).thenAnswer((_) => connections);
}

void main() {
  group('activatePortForwardOnConnectedSession', () {
    test('starts a local rule on the preferred connected session', () async {
      final session = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
      );
      addTearDown(session.changes.close);

      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier([session]),
        portForward: _portForward(),
        preferredConnectionId: session.connectionId,
      );

      expect(result.status, PortForwardActivationStatus.started);
      expect(result.connectionId, session.connectionId);
      expect(session.localStarts, [1]);
      expect(session.isPortForwardActive(1), isTrue);
    });

    test('reuses a rule already active on a sibling connection', () async {
      final older = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
      );
      final newer = _RecordingSshSession(
        connectionId: 8,
        hostId: 10,
        client: _MockSshClient(),
      );
      addTearDown(older.changes.close);
      addTearDown(newer.changes.close);
      older.tunnels[1] = const ActiveTunnelInfo(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: true,
      );

      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier([older, newer]),
        portForward: _portForward(),
        preferredConnectionId: newer.connectionId,
      );

      expect(result.status, PortForwardActivationStatus.alreadyActive);
      expect(older.localStarts, isEmpty);
      expect(newer.localStarts, isEmpty);
    });

    test('serializes concurrent activation across sibling sessions', () async {
      final older = SshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'user',
        ),
      );
      final newer = SshSession(
        connectionId: 8,
        hostId: 10,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'user',
        ),
      );
      addTearDown(older.stopAllForwards);
      addTearDown(newer.stopAllForwards);
      final sessions = _TestActiveSessionsNotifier([older, newer]);
      final portForward = _portForward(localPort: 0);

      final results = await Future.wait([
        activatePortForwardOnConnectedSession(
          sessions: sessions,
          portForward: portForward,
          preferredConnectionId: older.connectionId,
        ),
        activatePortForwardOnConnectedSession(
          sessions: sessions,
          portForward: portForward,
          preferredConnectionId: newer.connectionId,
        ),
      ]);

      expect(
        results.map((result) => result.status),
        containsAll([
          PortForwardActivationStatus.started,
          PortForwardActivationStatus.alreadyActive,
        ]),
      );
      expect(older.activeTunnels.length + newer.activeTunnels.length, 1);
    });

    test('restarts an active rule after its endpoints change', () async {
      final session = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
      );
      addTearDown(session.changes.close);
      session.tunnels[1] = const ActiveTunnelInfo(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: true,
      );

      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier([session]),
        previous: _portForward(),
        portForward: _portForward(remotePort: 3000),
      );

      expect(result.status, PortForwardActivationStatus.started);
      expect(session.stops, [1]);
      expect(session.localStarts, [1]);
      expect(session.activeTunnels.single.remotePort, 3000);
    });

    test('preserves an edit restart ahead of a later auto-start', () async {
      final replaceGate = Completer<void>();
      final session = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
        replaceGate: replaceGate,
      );
      addTearDown(session.changes.close);
      session.tunnels[1] = const ActiveTunnelInfo(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: true,
      );
      final previous = _portForward();
      final current = _portForward(remotePort: 3000);
      final sessions = _TestActiveSessionsNotifier([session]);

      final editFuture = activatePortForwardOnConnectedSession(
        sessions: sessions,
        previous: previous,
        portForward: current,
      );
      await Future<void>.delayed(Duration.zero);
      final autoStartFuture = activatePortForwardOnConnectedSession(
        sessions: sessions,
        portForward: current,
      );
      replaceGate.complete();

      expect((await editFuture).status, PortForwardActivationStatus.started);
      expect(
        (await autoStartFuture).status,
        PortForwardActivationStatus.alreadyActive,
      );
      expect(session.activeTunnels.single.remotePort, 3000);
    });

    test('moves an active rule from its old host to the new host', () async {
      final oldSession = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
      );
      final newSession = _RecordingSshSession(
        connectionId: 8,
        hostId: 20,
        client: _MockSshClient(),
      );
      addTearDown(oldSession.changes.close);
      addTearDown(newSession.changes.close);
      oldSession.tunnels[1] = const ActiveTunnelInfo(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: true,
      );

      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier([oldSession, newSession]),
        previous: _portForward(),
        portForward: _portForward(hostId: 20),
      );

      expect(result.status, PortForwardActivationStatus.started);
      expect(oldSession.stops, [1]);
      expect(newSession.localStarts, [1]);
    });

    test('returns noConnectedSession without starting', () async {
      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier(const []),
        portForward: _portForward(),
      );

      expect(result.status, PortForwardActivationStatus.noConnectedSession);
    });

    test('reports a failed remote start', () async {
      final session = _RecordingSshSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
        startSucceeds: false,
      );
      addTearDown(session.changes.close);

      final result = await activatePortForwardOnConnectedSession(
        sessions: _TestActiveSessionsNotifier([session]),
        portForward: _portForward(forwardType: 'remote'),
      );

      expect(result.status, PortForwardActivationStatus.failed);
      expect(session.remoteStarts, [1]);
    });
  });

  test('stops local and remote instances across connected sessions', () async {
    const portForwardId = 50;
    final localSession = _RecordingSshSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    final remoteSession = _RecordingSshSession(
      connectionId: 8,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(localSession.changes.close);
    addTearDown(remoteSession.changes.close);
    localSession.tunnels[portForwardId] = const ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: '127.0.0.1',
      localPort: 8080,
      remoteHost: 'localhost',
      remotePort: 80,
      isLocal: true,
    );
    remoteSession.tunnels[portForwardId] = const ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: '127.0.0.1',
      localPort: 22,
      remoteHost: '127.0.0.1',
      remotePort: 8022,
      isLocal: false,
    );

    final stopped = await stopPortForwardOnConnectedSessions(
      sessions: _TestActiveSessionsNotifier([localSession, remoteSession]),
      portForward: _portForward(id: portForwardId),
    );

    expect(stopped, 2);
    expect(localSession.stops, [portForwardId]);
    expect(remoteSession.stops, [portForwardId]);
  });

  test('restores activation when database deletion fails', () async {
    final portForward = _portForward(id: 51);
    final sessions = _TestActiveSessionsNotifier(const []);

    await stopPortForwardOnConnectedSessions(
      sessions: sessions,
      portForward: portForward,
    );
    final blockedActivation = await activatePortForwardOnConnectedSession(
      sessions: sessions,
      portForward: portForward,
    );
    expect(blockedActivation.status, PortForwardActivationStatus.superseded);

    restorePortForwardAfterFailedDeletion(portForward);

    final restoredActivation = await activatePortForwardOnConnectedSession(
      sessions: sessions,
      portForward: portForward,
    );
    expect(
      restoredActivation.status,
      PortForwardActivationStatus.noConnectedSession,
    );
  });

  test('applies edits to a manually started non-auto rule', () {
    final session = _RecordingSshSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);
    session.tunnels[1] = const ActiveTunnelInfo(
      portForwardId: 1,
      localHost: '127.0.0.1',
      localPort: 8080,
      remoteHost: 'localhost',
      remotePort: 80,
      isLocal: true,
    );
    final previous = _portForward(autoStart: false);

    expect(
      shouldApplyPortForwardLive(
        sessions: _TestActiveSessionsNotifier([session]),
        previous: previous,
        portForward: _portForward(autoStart: false, remotePort: 3000),
      ),
      isTrue,
    );
  });

  test('serializes concurrent starts for the same rule', () async {
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );
    var changeCount = 0;
    final subscription = session.portForwardChanges.listen(
      (_) => changeCount++,
    );
    addTearDown(subscription.cancel);
    addTearDown(session.stopAllForwards);

    final results = await Future.wait([
      session.startLocalForward(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 0,
        remoteHost: 'localhost',
        remotePort: 80,
      ),
      session.startLocalForward(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 0,
        remoteHost: 'localhost',
        remotePort: 80,
      ),
    ]);

    expect(results, [isTrue, isTrue]);
    expect(session.activeTunnels, hasLength(1));
    expect(changeCount, 1);
  });

  test('does not start a forward after the session closes', () async {
    final client = _MockSshClient();
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );

    await session.close();

    expect(
      await session.startLocalForward(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 0,
        remoteHost: 'localhost',
        remotePort: 80,
      ),
      isFalse,
    );
  });

  test('delete waits for and stops a pending remote forward', () async {
    const portForwardId = 60;
    final client = _MockSshClient();
    final remoteForward = _MockRemoteForward();
    final pendingForward = Completer<SSHRemoteForward?>();
    _stubRemoteForward(remoteForward, port: 8022);
    when(() => client.forwardRemote(host: 'localhost', port: 8022))
        .thenAnswer((_) => pendingForward.future);
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );
    addTearDown(session.close);
    final portForward = _portForward(
      id: portForwardId,
      forwardType: 'remote',
      remotePort: 8022,
    );
    final sessions = _TestActiveSessionsNotifier([session]);

    final startFuture = session.startPortForward(portForward);
    await Future<void>.delayed(Duration.zero);
    expect(session.isPortForwardStarting(portForward.id), isTrue);

    final stopFuture = stopPortForwardOnConnectedSessions(
      sessions: sessions,
      portForward: portForward,
    );
    final staleActivationFuture = activatePortForwardOnConnectedSession(
      sessions: sessions,
      portForward: portForward,
    );
    pendingForward.complete(remoteForward);

    expect(await startFuture, isTrue);
    expect(await stopFuture, 1);
    expect(
      (await staleActivationFuture).status,
      PortForwardActivationStatus.superseded,
    );
    expect(session.isPortForwardActive(portForward.id), isFalse);
    verify(remoteForward.close).called(1);
  });

  test('edit replaces a pending remote forward atomically', () async {
    const portForwardId = 61;
    final client = _MockSshClient();
    final oldRemoteForward = _MockRemoteForward();
    final newRemoteForward = _MockRemoteForward();
    final pendingOldForward = Completer<SSHRemoteForward?>();
    _stubRemoteForward(oldRemoteForward, port: 8022);
    _stubRemoteForward(newRemoteForward, port: 9022);
    when(() => client.forwardRemote(host: 'localhost', port: 8022))
        .thenAnswer((_) => pendingOldForward.future);
    when(() => client.forwardRemote(host: 'localhost', port: 9022))
        .thenAnswer((_) async => newRemoteForward);
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );
    addTearDown(session.close);
    final previous = _portForward(
      id: portForwardId,
      forwardType: 'remote',
      remotePort: 8022,
      autoStart: false,
    );
    final current = _portForward(
      id: portForwardId,
      forwardType: 'remote',
      remotePort: 9022,
      autoStart: false,
    );
    final sessions = _TestActiveSessionsNotifier([session]);

    final startFuture = session.startPortForward(previous);
    await Future<void>.delayed(Duration.zero);
    final activationFuture = activatePortForwardOnConnectedSession(
      sessions: sessions,
      previous: previous,
      portForward: current,
    );
    pendingOldForward.complete(oldRemoteForward);

    expect(await startFuture, isTrue);
    final result = await activationFuture;
    expect(result.status, PortForwardActivationStatus.started);
    expect(session.activeTunnels.single.remotePort, 9022);
    verify(oldRemoteForward.close).called(1);
  });

  test('remote timeout releases the gate and closes a late forward', () async {
    final client = _MockSshClient();
    final lateRemoteForward = _MockRemoteForward();
    final pendingForward = Completer<SSHRemoteForward?>();
    _stubRemoteForward(lateRemoteForward, port: 8022);
    when(() => client.forwardRemote(host: 'localhost', port: 8022))
        .thenAnswer((_) => pendingForward.future);
    final session = _ShortTimeoutSshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
    );
    addTearDown(session.close);

    expect(
      await session.startRemoteForward(
        portForwardId: 1,
        remoteHost: 'localhost',
        remotePort: 8022,
        localHost: 'localhost',
        localPort: 22,
      ),
      isFalse,
    );
    await session.stopForward(1).timeout(const Duration(seconds: 1));

    pendingForward.complete(lateRemoteForward);
    await Future<void>.delayed(Duration.zero);
    verify(lateRemoteForward.close).called(1);
  });

  test('local timeout releases the gate and closes a late socket', () async {
    final client = _MockSshClient();
    final lateServerSocket = _MockServerSocket();
    final pendingSocket = Completer<ServerSocket>();
    when(lateServerSocket.close).thenAnswer((_) async => lateServerSocket);
    final session = _ShortTimeoutSshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      socketBinder: (_, _, {bool v6Only = false}) => pendingSocket.future,
    );
    addTearDown(session.close);

    expect(
      await session.startLocalForward(
        portForwardId: 1,
        localHost: 'slow.example.com',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
      ),
      isFalse,
    );
    await session.stopForward(1).timeout(const Duration(seconds: 1));

    pendingSocket.complete(lateServerSocket);
    await Future<void>.delayed(Duration.zero);
    verify(lateServerSocket.close).called(1);
  });

  test('closing cancels a pending remote-forward request', () async {
    final client = _MockSshClient();
    final lateRemoteForward = _MockRemoteForward();
    final pendingForward = Completer<SSHRemoteForward?>();
    _stubRemoteForward(lateRemoteForward, port: 8022);
    when(() => client.forwardRemote(host: 'localhost', port: 8022))
        .thenAnswer((_) => pendingForward.future);
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );

    final startFuture = session.startPortForward(
      _portForward(forwardType: 'remote', remotePort: 8022),
    );
    await Future<void>.delayed(Duration.zero);

    await session.close().timeout(const Duration(seconds: 1));

    expect(await startFuture, isFalse);
    pendingForward.complete(lateRemoteForward);
    await Future<void>.delayed(Duration.zero);
    verify(lateRemoteForward.close).called(1);
  });

  test('does not classify an in-flight stop as a pending start', () async {
    final client = _MockSshClient();
    final remoteForward = _MockRemoteForward();
    final cancelCompleter = Completer<void>();
    final connections = StreamController<SSHForwardChannel>(
      onCancel: () => cancelCompleter.future,
    );
    addTearDown(connections.close);
    _stubRemoteForward(
      remoteForward,
      port: 8022,
      connections: connections.stream,
    );
    when(() => client.forwardRemote(host: 'localhost', port: 8022))
        .thenAnswer((_) async => remoteForward);
    final session = SshSession(
      connectionId: 7,
      hostId: 10,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      ),
    );
    addTearDown(session.close);
    const portForwardId = 1;
    expect(
      await session.startRemoteForward(
        portForwardId: portForwardId,
        remoteHost: 'localhost',
        remotePort: 8022,
        localHost: 'localhost',
        localPort: 22,
      ),
      isTrue,
    );

    final stopFuture = session.stopForward(portForwardId);
    await Future<void>.delayed(Duration.zero);

    expect(session.isPortForwardActive(portForwardId), isFalse);
    expect(session.isPortForwardStarting(portForwardId), isFalse);
    cancelCompleter.complete();
    await stopFuture;
  });
}
