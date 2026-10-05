// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/hosts_screen.dart';
import 'package:monkeyssh/presentation/widgets/brand_list_skeleton.dart';

import '../helpers/mocks.dart';

void _callReorderItemCallback(
  ReorderCallback? callback,
  int oldIndex,
  int newIndex,
) {
  expect(callback, isNotNull);
  callback?.call(oldIndex, newIndex);
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier({
    List<ActiveConnection> initialConnections = const <ActiveConnection>[],
  }) {
    _connections.addEntries(
      initialConnections.map(
        (connection) => MapEntry(connection.connectionId, connection),
      ),
    );
  }

  final Map<int, ActiveConnection> _connections = <int, ActiveConnection>{};
  final List<int> disconnectedConnectionIds = <int>[];

  @override
  Map<int, SshConnectionState> build() => {
    for (final connection in _connections.values)
      connection.connectionId: connection.state,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) => _connections.values
      .where((connection) => connection.hostId == hostId)
      .map((connection) => connection.connectionId)
      .toList(growable: false);

  @override
  ActiveConnection? getActiveConnection(int connectionId) =>
      _connections[connectionId];

  @override
  Future<void> disconnect(int connectionId) async {
    disconnectedConnectionIds.add(connectionId);
    _connections.remove(connectionId);
    state = {
      for (final connection in _connections.values)
        connection.connectionId: connection.state,
    };
  }
}

Host _buildHost({
  required int id,
  required String label,
  required int sortOrder,
}) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
  port: 22,
  username: 'root',
  password: null,
  keyId: null,
  groupId: null,
  jumpHostId: null,
  isFavorite: false,
  color: null,
  notes: null,
  tags: null,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoForwardPorts: false,
  lastConnectedAt: null,
  terminalThemeLightId: null,
  terminalThemeDarkId: null,
  terminalFontFamily: null,
  autoConnectCommand: null,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  sortOrder: sortOrder,
);

ActiveConnection _buildActiveConnection({
  required int connectionId,
  required int hostId,
  SshConnectionState state = SshConnectionState.connected,
}) => ActiveConnection(
  connectionId: connectionId,
  hostId: hostId,
  state: state,
  createdAt: DateTime(2026),
  config: const SshConnectionConfig(
    hostname: 'alpha.example.com',
    port: 22,
    username: 'root',
  ),
);

Widget _buildHostsScreen({required AppDatabase db, required List overrides}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pinnedHomeScreenShortcutHostIdsProvider.overrideWith(
          (ref) => Stream<Set<int>>.value(const <int>{}),
        ),
        ...overrides,
      ],
      child: const MaterialApp(home: HostsScreen()),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  testWidgets('shows imported hosts after the provider updates', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hostsController = StreamController<List<Host>>();
    addTearDown(hostsController.close);

    await tester.pumpWidget(
      _buildHostsScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
        ],
      ),
    );

    hostsController.add(const <Host>[]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('no hosts yet'), findsOneWidget);

    hostsController.add([
      _buildHost(id: 1, label: 'Imported host', sortOrder: 0),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Imported host'), findsOneWidget);
  });

  testWidgets('loading state shows a skeleton placeholder', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hostsController = StreamController<List<Host>>();
    addTearDown(hostsController.close);

    await tester.pumpWidget(
      _buildHostsScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
        ],
      ),
    );

    expect(find.byType(BrandListSkeleton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('reordering hosts persists the new order', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hostRepository = MockHostRepository();
    when(() => hostRepository.reorderByIds(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      _buildHostsScreen(
        db: db,
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith(
            (ref) => Stream.value([
              _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              _buildHost(id: 2, label: 'Beta', sortOrder: 1),
            ]),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Reorder'), findsNWidgets(2));

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    _callReorderItemCallback(list.onReorderItem, 0, 1);
    await tester.pumpAndSettle();

    verify(() => hostRepository.reorderByIds([2, 1])).called(1);
  });

  testWidgets('host actions are exposed through the context menu trigger', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      _buildHostsScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(_TestActiveSessionsNotifier.new),
          allHostsProvider.overrideWith(
            (ref) =>
                Stream.value([_buildHost(id: 1, label: 'Alpha', sortOrder: 0)]),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Host actions'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    await tester.tap(find.byTooltip('Host actions'));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('New connection'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Disconnect all'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Export Encrypted File (Pro)'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets(
    'connected host long press can disconnect from the context menu',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final sessionsNotifier = _TestActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: 1),
        ],
      );

      await tester.pumpWidget(
        _buildHostsScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(find.text('Disconnect'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(sessionsNotifier.disconnectedConnectionIds, orderedEquals([7]));
    },
  );
}
