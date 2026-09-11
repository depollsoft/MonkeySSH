// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/port_forward_edit_screen.dart';
import 'package:monkeyssh/presentation/widgets/host_port_forward_editor_sheet.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _RecordingSshSession extends SshSession {
  _RecordingSshSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    this.startSucceeds = true,
  }) : super(
         config: const SshConnectionConfig(
           hostname: 'example.com',
           port: 22,
           username: 'user',
         ),
       );

  final List<int> starts = [];
  final bool startSucceeds;

  @override
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    starts.add(portForwardId);
    return startSucceeds;
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => {
    session.connectionId: SshConnectionState.connected,
  };

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? [session.connectionId] : const [];

  @override
  SshConnectionState getState(int connectionId) =>
      connectionId == session.connectionId
      ? SshConnectionState.connected
      : SshConnectionState.disconnected;

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;
}

Host _host() => Host(
  id: 10,
  label: 'Dev box',
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
  for (final (fails, hostFails) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      '${hostFails ? 'host ' : ''}edit load ${fails ? 'failure' : 'missing record'} leaves loading',
      (tester) async {
        final hosts = _MockHostRepository();
        final forwards = _MockPortForwardRepository();
        when(hosts.getAll).thenAnswer((_) async {
          if (hostFails) throw Exception('read failed');
          return [_host()];
        });
        when(() => forwards.getById(999)).thenAnswer((_) async {
          if (fails) throw Exception('read failed');
          return null;
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              hostRepositoryProvider.overrideWithValue(hosts),
              portForwardRepositoryProvider.overrideWithValue(forwards),
            ],
            child: const MaterialApp(
              home: PortForwardEditScreen(portForwardId: 999),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text(
            fails
                ? 'Could not load port forward. Try again.'
                : 'Port forward not found.',
          ),
          findsOneWidget,
        );
        expect(find.text('Save Changes'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  setUpAll(() {
    registerFallbackValue(
      PortForwardsCompanion.insert(
        name: 'Fallback',
        hostId: 1,
        forwardType: 'local',
        localPort: 1,
        remoteHost: 'localhost',
        remotePort: 1,
        autoStart: const Value(false),
      ),
    );
  });

  for (final startSucceeds in [true, false]) {
    testWidgets(
      'persists a new rule when live activation succeeds: $startSucceeds',
      (tester) async {
        final hostRepository = _MockHostRepository();
        final portForwardRepository = _MockPortForwardRepository();
        final session = _RecordingSshSession(
          connectionId: 7,
          startSucceeds: startSucceeds,
          hostId: 10,
          client: _MockSshClient(),
        );
        when(hostRepository.getAll).thenAnswer((_) async => [_host()]);
        when(
          () => portForwardRepository.insert(any()),
        ).thenAnswer((_) async => 11);
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => Scaffold(
                body: FilledButton(
                  onPressed: () => context.push('/editor'),
                  child: const Text('Open Editor'),
                ),
              ),
            ),
            GoRoute(
              path: '/editor',
              builder: (context, state) => const PortForwardEditScreen(),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              hostRepositoryProvider.overrideWithValue(hostRepository),
              portForwardRepositoryProvider.overrideWithValue(
                portForwardRepository,
              ),
              activeSessionsProvider.overrideWith(
                () => _TestActiveSessionsNotifier(session),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        await tester.tap(find.text('Open Editor'));
        await tester.pumpAndSettle();

        expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
        await tester.tap(find.byType(DropdownButtonFormField<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dev box').last);
        await tester.pumpAndSettle();

        final fields = find.byType(TextFormField);
        expect(tester.widget<TextFormField>(fields.at(3)).controller!.text, '');
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        await tester.enterText(fields.at(0), 'Web preview');
        await tester.enterText(fields.at(2), '8080');
        await tester.enterText(fields.at(3), 'localhost');
        await tester.enterText(fields.at(4), '3000');
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Auto-start'));
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(
          true,
        );
        await tester.pump();
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        final saveButton = find.bySubtype<FilledButton>();
        expect(saveButton, findsOneWidget);
        await tester.ensureVisible(saveButton);
        await tester.tap(saveButton);
        await tester.pumpAndSettle();

        verify(() => portForwardRepository.insert(any())).called(1);
        expect(session.starts, [11]);
        expect(
          find.text(
            startSucceeds
                ? 'Port forward added and started'
                : 'Port forward saved, but it couldn’t start. Check the configured ports.',
          ),
          findsOneWidget,
        );
        expect(find.text('Open Editor'), findsOneWidget);
        expect(find.text('Discard changes?'), findsNothing);
      },
    );
  }

  testWidgets('host sheet keeps its defaults and cancels without saving', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showHostPortForwardEditorSheet(
                  context: context,
                  hostId: 10,
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
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    final fields = find.byType(TextFormField);
    expect(
      tester.widget<TextFormField>(fields.at(1)).controller!.text,
      '127.0.0.1',
    );
    expect(
      tester.widget<TextFormField>(fields.at(3)).controller!.text,
      'localhost',
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.enterText(fields.first, 'Unsaved rule');
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(PortForwardEditorForm), findsNothing);
    expect(find.text('Discard changes?'), findsNothing);
  });
}
