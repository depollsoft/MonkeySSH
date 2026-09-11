// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/domain/services/port_forward_browser_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/brand_list_skeleton.dart';
import 'package:monkeyssh/presentation/widgets/terminal_port_forwards_sheet.dart';

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _LiveTestSession extends SshSession {
  _LiveTestSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
  }) : super(
         config: const SshConnectionConfig(
           hostname: 'example.com',
           port: 22,
           username: 'user',
         ),
       );

  final Map<int, ActiveTunnelInfo> tunnels = {};
  final changes = StreamController<void>.broadcast();
  final List<int> starts = [];
  final List<int> stops = [];

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
    starts.add(portForwardId);
    tunnels[portForwardId] = ActiveTunnelInfo(
      portForwardId: portForwardId,
      localHost: localHost,
      localPort: localPort,
      browserHost: portForwardBrowserHostForPortForwardId(portForwardId),
      browserPort: localPort,
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
    starts.add(portForwardId);
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
    tunnels.remove(portForwardId);
    changes.add(null);
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(
    this.sessions, {
    this.connectionState = SshConnectionState.connected,
  });

  final List<SshSession> sessions;
  final SshConnectionState connectionState;
  final List<int> reconfiguredHostIds = [];

  @override
  Map<int, SshConnectionState> build() {
    for (final session in sessions) {
      final subscription = session.portForwardChanges.listen((_) {
        state = {...state};
      });
      ref.onDispose(subscription.cancel);
    }
    return {
      for (final session in sessions) session.connectionId: connectionState,
    };
  }

  @override
  SshSession? getSession(int connectionId) {
    for (final session in sessions) {
      if (session.connectionId == connectionId) {
        return session;
      }
    }
    return null;
  }

  @override
  Future<void> reconfigureAutomaticPortForwardingForHost(int hostId) async {
    reconfiguredHostIds.add(hostId);
  }

  @override
  List<int> getConnectionsForHost(int hostId) => sessions
      .where((session) => session.hostId == hostId)
      .map((session) => session.connectionId)
      .toList(growable: false);
}

Host _host({bool autoForwardPorts = false}) => Host(
  id: 10,
  label: 'Dev box',
  hostname: 'example.com',
  port: 22,
  username: 'user',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoForwardPorts: autoForwardPorts,
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  sortOrder: 0,
);

Widget _buildSheetHost({
  required _LiveTestSession session,
  required _TestActiveSessionsNotifier notifier,
  required PortForwardRepository portForwardRepository,
  required HostRepository hostRepository,
  required Stream<Host?> hostStream,
}) => ProviderScope(
  overrides: [
    portForwardRepositoryProvider.overrideWithValue(portForwardRepository),
    hostRepositoryProvider.overrideWithValue(hostRepository),
    hostByIdProvider(session.hostId).overrideWith((ref) => hostStream),
    activeSessionsProvider.overrideWith(() => notifier),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => FilledButton(
          onPressed: () => unawaited(
            showTerminalPortForwardsSheet(
              context: context,
              hostId: session.hostId,
              connectionId: session.connectionId,
              session: session,
              onOpenInBrowser: (_) async {},
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

PortForward _portForward() => PortForward(
  id: 1,
  name: 'Web preview',
  hostId: 10,
  forwardType: 'local',
  localHost: '127.0.0.1',
  localPort: 8080,
  remoteHost: 'localhost',
  remotePort: 3000,
  autoStart: true,
  createdAt: DateTime(2026),
);

void main() {
  setUpAll(() {
    registerFallbackValue(
      PortForwardsCompanion.insert(
        name: 'Fallback',
        hostId: 1,
        forwardType: 'local',
        localPort: 1,
        remoteHost: 'localhost',
        remotePort: 1,
      ),
    );
  });

  testWidgets('closing releases host streams and reopening loads again', (
    tester,
  ) async {
    final repository = _MockPortForwardRepository();
    final hostRepository = _MockHostRepository();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);
    var hostListens = 0;
    var forwardListens = 0;
    var hostCancels = 0;
    var forwardCancels = 0;
    final hosts = StreamController<Host?>.broadcast(
      onListen: () => hostListens++,
      onCancel: () => hostCancels++,
    );
    final forwards = StreamController<List<PortForward>>.broadcast(
      onListen: () => forwardListens++,
      onCancel: () => forwardCancels++,
    );
    addTearDown(hosts.close);
    addTearDown(forwards.close);
    when(() => repository.watchByHostId(10)).thenAnswer((_) => forwards.stream);
    await tester.pumpWidget(
      _buildSheetHost(
        session: session,
        notifier: _TestActiveSessionsNotifier([session]),
        portForwardRepository: repository,
        hostRepository: hostRepository,
        hostStream: hosts.stream,
      ),
    );
    for (var visit = 1; visit <= 2; visit++) {
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(hostListens, visit);
      expect(forwardListens, visit);
      expect(find.byType(BrandListSkeleton), findsWidgets);
      hosts.add(_host());
      forwards.add([_portForward()]);
      await tester.pumpAndSettle();
      expect(find.text('Web preview'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump();
      expect(hostCancels, visit);
      expect(forwardCancels, visit);
    }
  });

  testWidgets('live switch starts and stops the current session rule', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final repository = _MockPortForwardRepository();
    final insertCompleter = Completer<int>();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    final automaticOwner = _LiveTestSession(
      connectionId: 8,
      hostId: 10,
      client: _MockSshClient(),
    );
    final openedTunnels = <ActiveTunnelInfo>[];
    automaticOwner.tunnels[-3000] = const ActiveTunnelInfo(
      portForwardId: -3000,
      localHost: '127.0.0.1',
      localPort: 49152,
      browserHost: 'dev-box.localhost',
      browserPort: 49152,
      remoteHost: '127.0.0.2',
      remotePort: 3000,
      isLocal: true,
      isAutomatic: true,
      isShellRelated: true,
    );
    automaticOwner.tunnels[-4000] = const ActiveTunnelInfo(
      portForwardId: -4000,
      localHost: '127.0.0.1',
      localPort: 49153,
      browserHost: 'dev-box.localhost',
      browserPort: 49153,
      remoteHost: '127.0.0.1',
      remotePort: 4000,
      isLocal: true,
      isAutomatic: true,
    );
    addTearDown(session.changes.close);
    addTearDown(automaticOwner.changes.close);
    when(
      () => repository.watchByHostId(session.hostId),
    ).thenAnswer((_) => Stream.value([_portForward()]));
    when(
      () => repository.insert(any()),
    ).thenAnswer((_) => insertCompleter.future);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          portForwardRepositoryProvider.overrideWithValue(repository),
          hostByIdProvider(
            session.hostId,
          ).overrideWith((ref) => Stream.value(_host())),
          activeSessionsProvider.overrideWith(
            () => _TestActiveSessionsNotifier([session, automaticOwner]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  showTerminalPortForwardsSheet(
                    context: context,
                    hostId: session.hostId,
                    connectionId: session.connectionId,
                    session: session,
                    onOpenInBrowser: (tunnel) async {
                      openedTunnels.add(tunnel);
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Port Forwards'), findsOneWidget);
    expect(find.text('this saved host'), findsOneWidget);
    expect(find.text('shared host services'), findsOneWidget);
    expect(find.text('Port 3000'), findsOneWidget);
    expect(find.text('Port 4000'), findsOneWidget);
    expect(find.textContaining('dev-box.localhost:49152'), findsOneWidget);
    expect(find.textContaining('Started from this saved host'), findsOneWidget);
    expect(find.text('Web preview'), findsOneWidget);
    expect(find.text('Stopped • Auto-start'), findsOneWidget);

    await tester.ensureVisible(find.text('Port 3000'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Port 3000'));
    await tester.pump();

    expect(openedTunnels.map((tunnel) => tunnel.portForwardId), [-3000]);

    await tester.ensureVisible(find.text('Web preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Web preview'));
    await tester.pump();

    expect(openedTunnels.map((tunnel) => tunnel.portForwardId), [-3000]);

    await tester.tap(find.byKey(const Key('port-forward-switch-1')));
    await tester.pumpAndSettle();

    expect(session.starts, [1]);
    expect(find.text('Active now • Auto-start'), findsOneWidget);

    await tester.ensureVisible(find.text('Web preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Web preview'));
    await tester.pump();

    expect(openedTunnels.map((tunnel) => tunnel.portForwardId), [-3000, 1]);
    final activeTunnel = session.tunnels[1]!;

    await tester.tap(find.byKey(const Key('port-forward-switch-1')));
    await tester.pumpAndSettle();

    expect(session.stops, [1]);
    expect(find.text('Stopped • Auto-start'), findsOneWidget);

    session.tunnels[1] = activeTunnel;
    session.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Active now • Auto-start'), findsOneWidget);
    session.tunnels.remove(1);
    session.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Stopped • Auto-start'), findsOneWidget);

    automaticOwner.tunnels.clear();
    automaticOwner.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Port 3000'), findsNothing);
    expect(find.text('Port 4000'), findsNothing);
    expect(find.text('this saved host'), findsNothing);
    expect(find.text('shared host services'), findsNothing);

    await tester.tap(find.text('Add Forward'));
    await tester.pumpAndSettle();

    expect(find.text('Add Port Forward'), findsOneWidget);
    expect(find.text('Forward Type'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet).last).enableDrag,
      isFalse,
    );

    await tester.tap(find.text('Remote').first);
    await tester.pump();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Database');
    await tester.enterText(fields.at(1), '127.0.0.1');
    await tester.enterText(fields.at(2), '5432');
    await tester.enterText(fields.at(3), '0.0.0.0');
    await tester.enterText(fields.at(4), '15432');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Expose remote port forward?'), findsOneWidget);
    expect(
      find.textContaining('devices that can access the SSH host'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Add Port Forward'), findsOneWidget);

    insertCompleter.complete(11);
    await tester.pumpAndSettle();

    expect(session.starts, [1, 11]);
    expect(find.text('Port forward added and started'), findsOneWidget);
    final inserted =
        verify(() => repository.insert(captureAny())).captured.single
            as PortForwardsCompanion;
    expect(inserted.forwardType.value, 'remote');
  });

  testWidgets(
    'auto-forward switch persists the host setting and reconfigures',
    (tester) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
      final portForwardRepository = _MockPortForwardRepository();
      final hostRepository = _MockHostRepository();
      final session = _LiveTestSession(
        connectionId: 7,
        hostId: 10,
        client: _MockSshClient(),
      );
      addTearDown(session.changes.close);
      final hosts = StreamController<Host?>.broadcast();
      addTearDown(hosts.close);
      final notifier = _TestActiveSessionsNotifier([session]);

      when(
        () => portForwardRepository.watchByHostId(session.hostId),
      ).thenAnswer((_) => Stream.value([_portForward()]));
      when(
        () => hostRepository.setAutoForwardPorts(
          any(),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((_) async {
        hosts.add(_host(autoForwardPorts: true));
        return true;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            portForwardRepositoryProvider.overrideWithValue(
              portForwardRepository,
            ),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            hostByIdProvider(session.hostId).overrideWith((ref) async* {
              yield _host();
              yield* hosts.stream;
            }),
            activeSessionsProvider.overrideWith(() => notifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => unawaited(
                    showTerminalPortForwardsSheet(
                      context: context,
                      hostId: session.hostId,
                      connectionId: session.connectionId,
                      session: session,
                      onOpenInBrowser: (_) async {},
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final autoSwitch = find.byKey(
        const Key('terminal-auto-forward-ports-switch'),
      );
      expect(autoSwitch, findsOneWidget);
      expect(
        find.text('Automatically proxy new remote listeners on this host'),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(autoSwitch).value, isFalse);

      await tester.tap(autoSwitch);
      await tester.pumpAndSettle();

      verify(
        () => hostRepository.setAutoForwardPorts(10, enabled: true),
      ).called(1);
      expect(notifier.reconfiguredHostIds, [10]);
      expect(tester.widget<SwitchListTile>(autoSwitch).value, isTrue);
      expect(
        find.text('Watching this host for new remote listeners'),
        findsOneWidget,
      );
      expect(find.text('Detecting open ports on this host.'), findsOneWidget);
    },
  );

  testWidgets('auto-forward switch stays usable while saved forwards load', (
    tester,
  ) async {
    final portForwardRepository = _MockPortForwardRepository();
    final hostRepository = _MockHostRepository();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);
    final notifier = _TestActiveSessionsNotifier([session]);

    // Saved forwards never resolve, so the sheet stays in its loading state.
    when(
      () => portForwardRepository.watchByHostId(session.hostId),
    ).thenAnswer((_) => const Stream<List<PortForward>>.empty());
    when(
      () => hostRepository.setAutoForwardPorts(
        any(),
        enabled: any(named: 'enabled'),
      ),
    ).thenAnswer((_) async => true);

    await tester.pumpWidget(
      _buildSheetHost(
        session: session,
        notifier: notifier,
        portForwardRepository: portForwardRepository,
        hostRepository: hostRepository,
        hostStream: Stream.value(_host()),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(BrandListSkeleton), findsOneWidget);
    final autoSwitch = find.byKey(
      const Key('terminal-auto-forward-ports-switch'),
    );
    expect(autoSwitch, findsOneWidget);

    await tester.tap(autoSwitch);
    await tester.pumpAndSettle();

    verify(
      () => hostRepository.setAutoForwardPorts(10, enabled: true),
    ).called(1);
    expect(notifier.reconfiguredHostIds, [10]);
  });

  testWidgets('auto-forward subtitle reflects a disconnected session', (
    tester,
  ) async {
    final portForwardRepository = _MockPortForwardRepository();
    final hostRepository = _MockHostRepository();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);

    when(
      () => portForwardRepository.watchByHostId(session.hostId),
    ).thenAnswer((_) => Stream.value([_portForward()]));

    await tester.pumpWidget(
      _buildSheetHost(
        session: session,
        notifier: _TestActiveSessionsNotifier([
          session,
        ], connectionState: SshConnectionState.disconnected),
        portForwardRepository: portForwardRepository,
        hostRepository: hostRepository,
        hostStream: Stream.value(_host(autoForwardPorts: true)),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      find.text('Will watch for new remote listeners once connected'),
      findsOneWidget,
    );
  });

  testWidgets('dismissing the sheet mid-save still reconfigures sessions', (
    tester,
  ) async {
    final portForwardRepository = _MockPortForwardRepository();
    final hostRepository = _MockHostRepository();
    final session = _LiveTestSession(
      connectionId: 7,
      hostId: 10,
      client: _MockSshClient(),
    );
    addTearDown(session.changes.close);
    final notifier = _TestActiveSessionsNotifier([session]);
    final saveCompleter = Completer<bool>();

    when(
      () => portForwardRepository.watchByHostId(session.hostId),
    ).thenAnswer((_) => Stream.value([_portForward()]));
    when(
      () => hostRepository.setAutoForwardPorts(
        any(),
        enabled: any(named: 'enabled'),
      ),
    ).thenAnswer((_) => saveCompleter.future);

    await tester.pumpWidget(
      _buildSheetHost(
        session: session,
        notifier: notifier,
        portForwardRepository: portForwardRepository,
        hostRepository: hostRepository,
        hostStream: Stream.value(_host()),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('terminal-auto-forward-ports-switch')),
    );
    await tester.pump();

    // Dismiss the sheet while the write is still in flight.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Detect open ports'), findsNothing);

    saveCompleter.complete(true);
    await tester.pumpAndSettle();

    expect(notifier.reconfiguredHostIds, [10]);
  });
}
