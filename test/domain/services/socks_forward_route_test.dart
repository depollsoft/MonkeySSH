import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/socks_forward_route.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mocks.dart';
import '../../helpers/terminal_session_fixture.dart';

PortForward _forward({String forwardType = 'dynamic'}) => PortForward(
  id: 7,
  name: 'Office',
  hostId: 42,
  forwardType: forwardType,
  localHost: '127.0.0.1',
  localPort: 0,
  remoteHost: forwardType == 'dynamic' ? '' : 'localhost',
  remotePort: forwardType == 'dynamic' ? 0 : 80,
  autoStart: false,
  createdAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SshSession session;
  late ActiveSessionsNotifier sessions;

  setUp(() {
    session = SshSession(
      connectionId: 3,
      hostId: 42,
      client: MockSshClient(),
      config: const SshConnectionConfig(
        hostname: 'host.example.com',
        port: 22,
        username: 'tester',
      ),
    );
    addTearDown(session.stopAllForwards);
    final container = ProviderContainer(
      overrides: [
        activeSessionsProvider.overrideWith(
          () => TestActiveSessionsNotifier(session),
        ),
      ],
    );
    addTearDown(container.dispose);
    sessions = container.read(activeSessionsProvider.notifier);
  });

  test('finds only a running SOCKS tunnel for the forward', () async {
    expect(
      findSocksForwardRoute(sessions, hostId: 42, portForwardId: 7),
      isNull,
    );

    await session.startLocalForward(
      portForwardId: 7,
      localHost: '127.0.0.1',
      localPort: 0,
      remoteHost: 'localhost',
      remotePort: 80,
    );
    expect(
      findSocksForwardRoute(sessions, hostId: 42, portForwardId: 7),
      isNull,
    );
    await session.stopForward(7);

    await session.startPortForward(_forward());
    final route = findSocksForwardRoute(sessions, hostId: 42, portForwardId: 7);
    expect(route?.connectionId, 3);
    expect(route?.port, session.activeTunnels.single.localPort);
    expect(
      findSocksForwardRoute(sessions, hostId: 43, portForwardId: 7),
      isNull,
    );
  });

  test('starts the forward on the connected session and reuses it', () async {
    final started = await startSocksForwardRoute(sessions, _forward());
    expect(started.errorMessage, isNull);
    expect(started.route?.port, session.activeTunnels.single.localPort);

    final reused = await startSocksForwardRoute(sessions, _forward());
    expect(reused.route, started.route);
    expect(session.activeTunnels, hasLength(1));
  });

  test('the live source follows the forward and probes its listener', () async {
    final source = SessionSocksForwardRouteSource(
      sessions: sessions,
      portForward: _forward(),
    );
    addTearDown(source.dispose);
    var notifications = 0;
    source
      ..addListener(() => notifications++)
      ..refresh();
    expect(source.route, isNull);
    expect(await source.probe(), isFalse);

    expect((await source.restart()).route, isNotNull);
    final route = source.route!;
    expect(notifications, 1);
    expect(await source.probe(), isTrue);

    await session.stopForward(7);
    expect(source.route, isNull);
    expect(notifications, 2);

    // A dead listener on a still-listed route is replaced in place.
    await session.startPortForward(_forward());
    expect(source.route, isNotNull);
    expect((await source.restart()).route, isNotNull);
    expect(source.route, isNotNull);
    expect(route.connectionId, source.route!.connectionId);
  });

  test('probe fails once the listener stops accepting', () async {
    final source = SessionSocksForwardRouteSource(
      sessions: sessions,
      portForward: _forward(),
    );
    addTearDown(source.dispose);
    source.refresh();
    await source.restart();
    final port = source.route!.port;
    await session.stopForward(7);

    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );
    expect(await source.probe(), isFalse);
  });

  test('stopForward stops the forward, even after dispose', () async {
    final source = SessionSocksForwardRouteSource(
      sessions: sessions,
      portForward: _forward(),
    )..refresh();
    await source.restart();
    expect(session.activeTunnels, hasLength(1));
    source.dispose();

    await source.stopForward();
    expect(session.activeTunnels, isEmpty);
  });

  test('restart reports the started forward even after dispose', () async {
    final source =
        SessionSocksForwardRouteSource(
            sessions: sessions,
            portForward: _forward(),
          )
          ..refresh()
          // A browser closed mid-start disposes its source before the start ends.
          ..dispose();

    final result = await source.restart();
    expect(result.errorMessage, isNull);
    expect(result.route?.port, session.activeTunnels.single.localPort);
    expect(source.route, isNull);
  });
}
