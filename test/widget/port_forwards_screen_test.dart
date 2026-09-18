// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/presentation/screens/port_forwards_screen.dart';

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

class _MockHostRepository extends Mock implements HostRepository {}

PortForward _buildPortForward({
  required int id,
  required int hostId,
  required String name,
  String forwardType = 'local',
}) => PortForward(
  id: id,
  hostId: hostId,
  name: name,
  localHost: '127.0.0.1',
  localPort: 8080,
  remoteHost: 'example.com',
  remotePort: 80,
  forwardType: forwardType,
  autoStart: false,
  createdAt: DateTime(2026),
);

Host _buildHost({required int id, required String label}) => Host(
  id: id,
  label: label,
  hostname: 'example.com',
  username: 'user',
  port: 22,
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  sortOrder: 0,
);

void main() {
  late _MockPortForwardRepository portForwardRepository;
  late _MockHostRepository hostRepository;

  setUp(() {
    portForwardRepository = _MockPortForwardRepository();
    hostRepository = _MockHostRepository();
  });

  Widget buildWidget() => ProviderScope(
    overrides: [
      portForwardRepositoryProvider.overrideWithValue(portForwardRepository),
      hostRepositoryProvider.overrideWithValue(hostRepository),
    ],
    child: const MaterialApp(home: PortForwardsScreen()),
  );

  group('PortForwardsScreen', () {
    testWidgets('shows empty state when no port forwards', (tester) async {
      when(portForwardRepository.watchAll)
          .thenAnswer((_) => Stream.value(const <PortForward>[]));
      when(hostRepository.watchAll)
          .thenAnswer((_) => Stream.value(const <Host>[]));

      await tester.pumpWidget(buildWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('no forwards yet'), findsOneWidget);
    });

    testWidgets('shows port forwards grouped by host', (tester) async {
      final host = _buildHost(id: 1, label: 'My Server');
      final pf = _buildPortForward(id: 1, hostId: 1, name: 'Web Forward');

      when(portForwardRepository.watchAll)
          .thenAnswer((_) => Stream.value([pf]));
      when(hostRepository.watchAll).thenAnswer((_) => Stream.value([host]));

      await tester.pumpWidget(buildWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('My Server'), findsOneWidget);
      expect(find.text('Web Forward'), findsOneWidget);
    });

    testWidgets('shows browser action for local forwards only', (tester) async {
      final host = _buildHost(id: 1, label: 'My Server');
      final localForward = _buildPortForward(
        id: 1,
        hostId: 1,
        name: 'Web Forward',
      );
      final remoteForward = _buildPortForward(
        id: 2,
        hostId: 1,
        name: 'Remote Forward',
        forwardType: 'remote',
      );

      when(portForwardRepository.watchAll)
          .thenAnswer((_) => Stream.value([localForward, remoteForward]));
      when(hostRepository.watchAll).thenAnswer((_) => Stream.value([host]));

      await tester.pumpWidget(buildWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Open in app browser'), findsOneWidget);
    });

    testWidgets('live-updates list when stream emits new data', (tester) async {
      final controller = StreamController<List<PortForward>>();
      addTearDown(controller.close);

      when(portForwardRepository.watchAll).thenAnswer((_) => controller.stream);
      when(hostRepository.watchAll)
          .thenAnswer((_) => Stream.value(const <Host>[]));

      await tester.pumpWidget(buildWidget());

      controller.add(const <PortForward>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('no forwards yet'), findsOneWidget);

      final host = _buildHost(id: 1, label: 'Server');
      final pf = _buildPortForward(id: 1, hostId: 1, name: 'SSH Tunnel');
      controller.add([pf]);
      // Host provider is a broadcast stream; swap in a controller for hosts too
      when(hostRepository.watchAll).thenAnswer((_) => Stream.value([host]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('SSH Tunnel'), findsOneWidget);
    });

    testWidgets('routes to add screen via FAB', (tester) async {
      when(portForwardRepository.watchAll)
          .thenAnswer((_) => Stream.value(const <PortForward>[]));
      when(hostRepository.watchAll)
          .thenAnswer((_) => Stream.value(const <Host>[]));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            portForwardRepositoryProvider.overrideWithValue(
              portForwardRepository,
            ),
            hostRepositoryProvider.overrideWithValue(hostRepository),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const PortForwardsScreen(),
                ),
                GoRoute(
                  path: '/port-forwards/add',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Add Forward Screen')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Add Forward'));
      await tester.pumpAndSettle();

      expect(find.text('Add Forward Screen'), findsOneWidget);
    });
  });
}
