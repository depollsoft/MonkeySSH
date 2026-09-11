// ignore_for_file: public_member_api_docs, directives_ordering, avoid_redundant_argument_values

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_preview.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/providers/host_row_providers.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/connection_preview_snippet.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../support/fake_acp_session_manager.dart';
import '../support/settings_import_test_helpers.dart'
    show FakeAuthService, MockAuthStateNotifier;

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSnippetRepository extends Mock implements SnippetRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockTmuxService extends Mock implements TmuxService {}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

Stream<TmuxWindowChangeEvent> _idleWindowChanges() {
  // Keep cancellation futures in the widget test's fake-async zone. Empty
  // streams and broadcast controllers can return a cached root-zone future.
  final controller = StreamController<TmuxWindowChangeEvent>(
    onCancel: () async {},
  );
  addTearDown(controller.close);
  return controller.stream;
}

class _MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

class _CountingSettingsService extends SettingsService {
  _CountingSettingsService(super.db);

  int preferenceReads = 0;
  int presetSubscriptions = 0;

  @override
  Future<Map<String, dynamic>?> getJson(String key) {
    if (key == SettingKeys.agentLaunchPresets ||
        key == SettingKeys.hostCliLaunchPreferences) {
      preferenceReads++;
    }
    return super.getJson(key);
  }

  @override
  Stream<String?> watchString(String key) {
    if (key == SettingKeys.agentLaunchPresets) presetSubscriptions++;
    return super.watchString(key);
  }
}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _MockSecureTransferService extends Mock
    implements SecureTransferService {}

void _callReorderItemCallback(
  ReorderCallback? callback,
  int oldIndex,
  int newIndex,
) {
  expect(callback, isNotNull);
  callback?.call(oldIndex, newIndex);
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) => const [];

  @override
  ActiveConnection? getActiveConnection(int connectionId) => null;
}

class _MutableActiveSessionsNotifier extends ActiveSessionsNotifier {
  _MutableActiveSessionsNotifier({
    List<ActiveConnection> initialConnections = const <ActiveConnection>[],
    List<SshSession> initialSessions = const <SshSession>[],
  }) {
    _connections.addEntries(
      initialConnections.map(
        (connection) => MapEntry(connection.connectionId, connection),
      ),
    );
    _sessions.addEntries(
      initialSessions.map((session) => MapEntry(session.connectionId, session)),
    );
  }

  final Map<int, ActiveConnection> _connections = <int, ActiveConnection>{};
  final Map<int, SshSession> _sessions = <int, SshSession>{};

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
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  @override
  List<ActiveConnection> getActiveConnections() =>
      _connections.values.toList(growable: false);

  @override
  void updateConnectionSessionTitle(int connectionId, String? sessionTitle) {
    final existing = _connections[connectionId];
    if (existing == null) return;
    final normalizedTitle = sessionTitle?.trim();
    final nextSessionTitle = normalizedTitle == null || normalizedTitle.isEmpty
        ? null
        : normalizedTitle;
    if (existing.sessionTitle == nextSessionTitle) return;
    _connections[connectionId] = ActiveConnection(
      connectionId: existing.connectionId,
      hostId: existing.hostId,
      state: existing.state,
      createdAt: existing.createdAt,
      config: existing.config,
      preview: existing.preview,
      previewSnapshot: existing.previewSnapshot,
      terminalTheme: existing.terminalTheme,
      sessionTitle: nextSessionTitle,
      windowTitle: existing.windowTitle,
      iconName: existing.iconName,
      workingDirectory: existing.workingDirectory,
      shellStatus: existing.shellStatus,
      lastExitCode: existing.lastExitCode,
      remoteMuxBackend: existing.remoteMuxBackend,
      remoteMuxSessionName: existing.remoteMuxSessionName,
      terminalThemeLightId: existing.terminalThemeLightId,
      terminalThemeDarkId: existing.terminalThemeDarkId,
    );
    state = {...state};
  }

  void setActiveConnections(List<ActiveConnection> connections) {
    _connections
      ..clear()
      ..addEntries(
        connections.map(
          (connection) => MapEntry(connection.connectionId, connection),
        ),
      );
    state = {
      for (final connection in connections)
        connection.connectionId: connection.state,
    };
  }

  void setSessions(List<SshSession> sessions) {
    _sessions
      ..clear()
      ..addEntries(
        sessions.map((session) => MapEntry(session.connectionId, session)),
      );
    state = {...state};
  }
}

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

class _RecordingTerminalPage extends StatefulWidget {
  const _RecordingTerminalPage({
    required this.route,
    required this.openedRoutes,
  });

  final String route;
  final List<String> openedRoutes;

  @override
  State<_RecordingTerminalPage> createState() => _RecordingTerminalPageState();
}

class _RecordingTerminalPageState extends State<_RecordingTerminalPage> {
  @override
  void initState() {
    super.initState();
    widget.openedRoutes.add(widget.route);
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('Terminal ${widget.route}'));
}

class _TerminalThemeOverridePage extends ConsumerStatefulWidget {
  const _TerminalThemeOverridePage();

  @override
  ConsumerState<_TerminalThemeOverridePage> createState() =>
      _TerminalThemeOverridePageState();
}

class _TerminalThemeOverridePageState
    extends ConsumerState<_TerminalThemeOverridePage> {
  final Object _overrideOwner = Object();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref
          .read(terminalAppThemeOverrideProvider.notifier)
          .activeOverride = TerminalAppThemeOverride(
        owner: _overrideOwner,
        darkThemeId: 'active-terminal-theme',
        lightThemeId: 'active-terminal-theme',
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Terminal route'));
}

class _ThemeOverrideTestApp extends ConsumerWidget {
  const _ThemeOverrideTestApp({required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTerminalOverride =
        ref.watch(terminalAppThemeOverrideProvider) != null;
    final onSurface = hasTerminalOverride ? Colors.white : Colors.black;
    final surface = hasTerminalOverride ? Colors.black : Colors.white;
    final colorScheme = ColorScheme.light(
      primary: Colors.blue,
      surface: surface,
      onSurface: onSurface,
    );
    final textTheme = TextTheme(
      titleMedium: TextStyle(color: onSurface),
      bodyMedium: TextStyle(color: onSurface),
      labelMedium: TextStyle(color: onSurface),
    );

    return MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: MaterialApp.router(
        theme: ThemeData(
          colorScheme: colorScheme,
          scaffoldBackgroundColor: surface,
          textTheme: textTheme,
        ),
        routerConfig: router,
      ),
    );
  }
}

Host _buildHost({
  required int id,
  required String label,
  required int sortOrder,
  String? autoConnectCommand,
  String? tmuxSessionName,
  String? tmuxExtraFlags,
  RemoteMuxBackend? remoteMuxBackend,
  String? tags,
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
  tags: tags,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoForwardPorts: false,
  lastConnectedAt: null,
  terminalThemeLightId: null,
  terminalThemeDarkId: null,
  terminalFontFamily: null,
  autoConnectCommand: autoConnectCommand,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  tmuxSessionName: tmuxSessionName,
  tmuxWorkingDirectory: null,
  tmuxExtraFlags: tmuxExtraFlags,
  remoteMuxBackend: remoteMuxBackend?.storageValue,
  sortOrder: sortOrder,
);

Snippet _buildSnippet({
  required int id,
  required String name,
  required int sortOrder,
}) => Snippet(
  id: id,
  name: name,
  command: 'echo $name',
  autoExecute: false,
  createdAt: DateTime(2026),
  usageCount: 0,
  sortOrder: sortOrder,
);

ActiveConnection _buildActiveConnection({
  required int connectionId,
  required int hostId,
  SshConnectionState state = SshConnectionState.connected,
  String? preview,
  TerminalPreviewSnapshot? previewSnapshot,
  TerminalThemeData? terminalTheme,
  String? sessionTitle,
  String? windowTitle,
  String? iconName,
  RemoteMuxBackend? remoteMuxBackend,
  String? remoteMuxSessionName,
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
  preview: preview,
  previewSnapshot: previewSnapshot,
  terminalTheme: terminalTheme,
  sessionTitle: sessionTitle,
  windowTitle: windowTitle,
  iconName: iconName,
  remoteMuxBackend: remoteMuxBackend,
  remoteMuxSessionName: remoteMuxSessionName,
);

SshSession _badgeSession({int hostId = 1}) => SshSession(
  connectionId: 7,
  hostId: hostId,
  client: _MockSshClient(),
  config: _buildActiveConnection(connectionId: 7, hostId: hostId).config,
);

TerminalPreviewSnapshot _buildStyledPreviewSnapshot() {
  final terminal = Terminal(maxLines: 100)..write('\x1b[31mready\x1b[0m');
  return SshSession.buildTerminalPreviewSnapshot(terminal)!;
}

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
    registerFallbackValue(MonetizationFeature.agentLaunchPresets);
  });

  Widget buildMobileHomeScreen({
    required AppDatabase db,
    required List overrides,
    Size size = const Size(400, 800),
    HomeScreenTab initialTab = HomeScreenTab.hosts,
    Widget? child,
    bool stubLaunchPresets = true,
    MediaQueryData mediaQueryData = const MediaQueryData(),
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Badge tests control presets independently of Drift's stream lifecycle.
      if (stubLaunchPresets)
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
      ...overrides,
    ],
    child: MediaQuery(
      data: mediaQueryData.copyWith(size: size),
      child: child ?? MaterialApp(home: HomeScreen(initialTab: initialTab)),
    ),
  );

  for (final tab in [HomeScreenTab.hosts, HomeScreenTab.keys]) {
    testWidgets(
      '${tab.name} export shows unreadable secrets without reporting an error',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final host = _buildHost(id: 1, label: 'Alpha', sortOrder: 0);
        final key = SshKey(
          id: 1,
          name: 'Alpha key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 test',
          privateKey: '',
          fingerprint: 'SHA256:test',
          createdAt: DateTime(2026),
        );
        final transferService = _MockSecureTransferService();
        final message = tab == HomeScreenTab.hosts
            ? 'Cannot export: re-enter the password for host "Alpha".'
            : 'Cannot export: re-enter the private key for SSH key "Alpha key".';
        final createPayload = tab == HomeScreenTab.hosts
            ? () => transferService.createHostPayload(
                host: host,
                transferPassphrase: 'transfer-passphrase',
                includeReferencedKey: false,
              )
            : () => transferService.createKeyPayload(
                key: key,
                transferPassphrase: 'transfer-passphrase',
              );
        when(
          createPayload,
        ).thenAnswer((_) async => throw FormatException(message));
        final billing = _MockMonetizationService();
        when(() => billing.currentState).thenReturn(_proMonetizationState);
        when(
          () => billing.canUseFeature(MonetizationFeature.encryptedTransfers),
        ).thenAnswer((_) async => true);
        try {
          await tester.pumpWidget(
            buildMobileHomeScreen(
              db: db,
              initialTab: tab,
              overrides: [
                activeSessionsProvider.overrideWith(
                  _TestActiveSessionsNotifier.new,
                ),
                allHostsProvider.overrideWith((ref) => Stream.value([host])),
                allKeysProvider.overrideWith((ref) => Stream.value([key])),
                authServiceProvider.overrideWithValue(FakeAuthService()),
                authStateProvider.overrideWith(MockAuthStateNotifier.new),
                secureTransferServiceProvider.overrideWithValue(
                  transferService,
                ),
                monetizationServiceProvider.overrideWithValue(billing),
                monetizationStateProvider.overrideWith(
                  (ref) => Stream.value(_proMonetizationState),
                ),
              ],
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          if (tab == HomeScreenTab.hosts) {
            await tester.tap(find.byTooltip('Host actions'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text('Export Encrypted File (Pro)'));
          } else {
            await tester.tap(find.byTooltip('Export encrypted'));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(TextField, 'Transfer passphrase'),
            'transfer-passphrase',
          );
          final reportedErrors = <FlutterErrorDetails>[];
          final originalOnError = FlutterError.onError;
          addTearDown(() => FlutterError.onError = originalOnError);
          FlutterError.onError = reportedErrors.add;
          try {
            await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
            await tester.pump();
            // Exercise a frame during dismissal, when the TextField still needs
            // its controller, then finish the dialog and SnackBar animations.
            await tester.pump(const Duration(milliseconds: 100));
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pump();
          } finally {
            FlutterError.onError = originalOnError;
          }

          expect(
            reportedErrors,
            isEmpty,
            reason: reportedErrors.map((error) => error.toString()).join('\n'),
          );

          verify(createPayload).called(1);
          expect(find.widgetWithText(SnackBar, message), findsOneWidget);
          expect(find.text('Export failed. Try again.'), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(HomeScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          // Pump cleanup inside the test's fake async zone, before database
          // teardown, and resolve any dialog left open by a failed assertion.
          final navigators = find.byType(Navigator);
          if (navigators.evaluate().isNotEmpty) {
            tester
                .state<NavigatorState>(navigators)
                .popUntil((route) => route.isFirst);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  group('HomeScreen mobile insets', () {
    const systemNavigationBarHeight = 24.0;
    const staleKeyboardInset = 240.0;
    const insetMediaQueryData = MediaQueryData(
      padding: EdgeInsets.zero,
      viewPadding: EdgeInsets.only(bottom: systemNavigationBarHeight),
      viewInsets: EdgeInsets.only(bottom: staleKeyboardInset),
    );

    testWidgets('keeps navigation destinations above the system bar', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          mediaQueryData: insetMediaQueryData,
          overrides: [
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();

      final scaffoldRect = tester.getRect(find.byType(Scaffold).first);
      final hostsDestinationRect = tester.getRect(find.text('Hosts').last);

      expect(
        hostsDestinationRect.bottom,
        lessThanOrEqualTo(scaffoldRect.bottom - systemNavigationBarHeight),
      );
    });

    testWidgets('does not shrink the home content for a stale keyboard inset', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          mediaQueryData: insetMediaQueryData,
          overrides: [
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      final bodyRect = tester.getRect(find.byWidget(scaffold.body!));
      final navigationBarRect = tester.getRect(find.byType(NavigationBar));

      expect(bodyRect.bottom, closeTo(navigationBarRect.top, 0.01));
    });
  });

  group('HomeScreen reorder affordance', () {
    testWidgets('shows reorder handles and persists host order on mobile', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final hostRepository = _MockHostRepository();
      when(() => hostRepository.reorderByIds(any())).thenAnswer((_) async {});

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            hostRepositoryProvider.overrideWithValue(hostRepository),
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                _buildHost(id: 2, label: 'Beta', sortOrder: 1),
              ]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      _callReorderItemCallback(list.onReorderItem, 0, 1);
      await tester.pump();

      verify(() => hostRepository.reorderByIds([2, 1])).called(1);
    });

    testWidgets('shows reorder handles and persists snippet order on mobile', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.watchAll).thenAnswer(
        (_) => Stream.value([
          _buildSnippet(id: 1, name: 'First', sortOrder: 0),
          _buildSnippet(id: 2, name: 'Second', sortOrder: 1),
        ]),
      );
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));
      when(
        () => snippetRepository.reorderByIds(any()),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Snippets').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      _callReorderItemCallback(list.onReorderItem, 0, 1);
      await tester.pump();

      verify(() => snippetRepository.reorderByIds([2, 1])).called(1);
    });
  });

  group('HomeScreen empty states', () {
    testWidgets('hosts empty state offers first-run actions', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('no hosts yet'), findsOneWidget);
      expect(find.text('Import config'), findsNothing);
      expect(find.text('Paste SSH URL'), findsOneWidget);
      expect(find.text('Try local test host'), findsNothing);
    });

    testWidgets('connections empty state explains where sessions appear', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(
              _TestActiveSessionsNotifier.new,
            ),
            allHostsProvider.overrideWith(
              (ref) => Stream.value(const <Host>[]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Connections').first);
      await tester.pump();

      expect(find.text('no active sessions'), findsOneWidget);
      expect(
        find.textContaining('live terminals show up here'),
        findsOneWidget,
      );
    });

    testWidgets('repeated connection taps push one terminal route', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final openedRoutes = <String>[];
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            state: SshConnectionState.connecting,
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const HomeScreen(initialTab: HomeScreenTab.connections),
          ),
          GoRoute(
            path: '/terminal/:hostId',
            builder: (context, state) => _RecordingTerminalPage(
              route: state.uri.toString(),
              openedRoutes: openedRoutes,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          stubLaunchPresets: false,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              ]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final connectionPosition = tester.getCenter(find.text('Alpha'));
      await tester.tapAt(connectionPosition);
      await tester.tapAt(connectionPosition);
      await tester.pumpAndSettle();

      expect(openedRoutes, ['/terminal/1?connectionId=7']);
      expect(find.text('Terminal /terminal/1?connectionId=7'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Terminal /terminal/1?connectionId=7'), findsNothing);
    });

    testWidgets('terminal opens again after the route is removed via go()', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final openedRoutes = <String>[];
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            state: SshConnectionState.connecting,
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const HomeScreen(initialTab: HomeScreenTab.connections),
          ),
          GoRoute(
            path: '/terminal/:hostId',
            builder: (context, state) => _RecordingTerminalPage(
              route: state.uri.toString(),
              openedRoutes: openedRoutes,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          stubLaunchPresets: false,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              ]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tapAt(tester.getCenter(find.text('Alpha')));
      await tester.pumpAndSettle();

      expect(openedRoutes, ['/terminal/1?connectionId=7']);

      // Returning home via go(...) removes the terminal route without popping,
      // which orphans the push future. The open guard must still be released so
      // the connection can be reopened instead of becoming permanently stuck.
      router.go('/');
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);

      await tester.tapAt(tester.getCenter(find.text('Alpha')));
      await tester.pumpAndSettle();

      expect(openedRoutes, [
        '/terminal/1?connectionId=7',
        '/terminal/1?connectionId=7',
      ]);
    });

    testWidgets('connections preview tap opens terminal route', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final openedRoutes = <String>[];
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            state: SshConnectionState.connecting,
            preview: 'ready',
            previewSnapshot: _buildStyledPreviewSnapshot(),
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const HomeScreen(initialTab: HomeScreenTab.connections),
          ),
          GoRoute(
            path: '/terminal/:hostId',
            builder: (context, state) => _RecordingTerminalPage(
              route: state.uri.toString(),
              openedRoutes: openedRoutes,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          stubLaunchPresets: false,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              ]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(
        find
            .descendant(
              of: find.byType(ConnectionPreviewStack),
              matching: find.byType(CustomPaint),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(openedRoutes, ['/terminal/1?connectionId=7']);
    });

    testWidgets(
      'terminal route return clears the app theme override immediately',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 7,
              hostId: 1,
              state: SshConnectionState.connecting,
              preview: 'ready',
              previewSnapshot: _buildStyledPreviewSnapshot(),
            ),
          ],
        );
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const HomeScreen(initialTab: HomeScreenTab.connections),
            ),
            GoRoute(
              path: '/terminal/:hostId',
              builder: (context, state) => const _TerminalThemeOverridePage(),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            stubLaunchPresets: false,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                ]),
              ),
            ],
            child: _ThemeOverrideTestApp(router: router),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        Finder connectionsHeader() => find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.textSpan?.toPlainText().startsWith('connections') ??
                  false),
        );
        Color? connectionsHeaderColor() {
          final span =
              tester.widget<Text>(connectionsHeader()).textSpan! as TextSpan;
          return span.children!.first.style?.color;
        }

        expect(connectionsHeaderColor(), Colors.black);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );

        await tester.tap(
          find
              .descendant(
                of: find.byType(ConnectionPreviewStack),
                matching: find.byType(CustomPaint),
              )
              .last,
        );
        await tester.pumpAndSettle();

        expect(container.read(terminalAppThemeOverrideProvider), isNotNull);

        router.pop();
        await tester.pumpAndSettle();

        expect(container.read(terminalAppThemeOverrideProvider), isNull);
        expect(connectionsHeaderColor(), Colors.black);
      },
    );

    testWidgets('hosts preview tap opens terminal route', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final openedRoutes = <String>[];
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            state: SshConnectionState.connecting,
            preview: 'ready',
            previewSnapshot: _buildStyledPreviewSnapshot(),
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(
            path: '/terminal/:hostId',
            builder: (context, state) => _RecordingTerminalPage(
              route: state.uri.toString(),
              openedRoutes: openedRoutes,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          stubLaunchPresets: false,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
              ]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(
        find
            .descendant(
              of: find.byType(ConnectionPreviewStack),
              matching: find.byType(CustomPaint),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(openedRoutes, ['/terminal/1?connectionId=7']);
    });
    testWidgets('connection chooser rebuilds after its host row is removed', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final hosts = StreamController<List<Host>>();
      addTearDown(hosts.close);
      final sessions = _MutableActiveSessionsNotifier(
        initialConnections: [
          for (var id = 1; id <= 2; id++)
            _buildActiveConnection(
              connectionId: id,
              hostId: 1,
              state: SshConnectionState.connecting,
            ),
        ],
      );
      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessions),
            allHostsProvider.overrideWith((ref) => hosts.stream),
          ],
        ),
      );
      await tester.pump();
      hosts.add([_buildHost(id: 1, label: 'Alpha', sortOrder: 0)]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final row = tester.element(find.text('Alpha'));
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('2 active connections'), findsOneWidget);

      hosts.add([]);
      await tester.pumpAndSettle();
      expect(row.mounted, isFalse);
      // Re-run the route builder after the originating Consumer is disposed.
      tester.element(find.byType(BottomSheet)).markNeedsBuild();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Connection #1'), findsOneWidget);
      expect(find.text('Connection #2'), findsOneWidget);
      await tester.tap(find.text('Connection #1'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'connection chooser scrolls to old connections on a short viewport',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final openedRoutes = <String>[];
        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            for (var id = 1; id <= 30; id++)
              _buildActiveConnection(
                connectionId: id,
                hostId: 1,
                state: SshConnectionState.connecting,
                preview: 'connection $id',
                previewSnapshot: _buildStyledPreviewSnapshot(),
              ),
          ],
        );
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
            GoRoute(
              path: '/terminal/:hostId',
              builder: (context, state) => _RecordingTerminalPage(
                route: state.uri.toString(),
                openedRoutes: openedRoutes,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            stubLaunchPresets: false,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                ]),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.ensureVisible(find.text('Alpha'));
        await tester.tap(find.text('Alpha'));
        await tester.pumpAndSettle();

        expect(find.text('30 active connections'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final list = find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('New connection'),
          250,
          scrollable: list,
        );
        expect(find.text('New connection').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        final oldest = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Connection #1'),
        );
        await tester.ensureVisible(oldest);
        await tester.tap(oldest);
        await tester.pumpAndSettle();
        expect(openedRoutes, ['/terminal/1?connectionId=1']);
      },
    );
  });

  testWidgets('context menu triggers expose semantics labels', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      buildMobileHomeScreen(
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Host actions' &&
            (widget.properties.button ?? false) &&
            widget.properties.onTap != null,
      ),
      findsOneWidget,
    );
  });

  testWidgets('updates the tmux badge when host session info loads later', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tmuxService = _MockTmuxService();

    final hostsController = StreamController<List<Host>>.broadcast();
    addTearDown(hostsController.close);

    final session = _badgeSession();
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [_buildActiveConnection(connectionId: 7, hostId: 1)],
      initialSessions: [session],
    );

    when(() => tmuxService.isTmuxActive(session)).thenAnswer((_) async => true);
    when(
      () => tmuxService.currentSessionName(session),
    ).thenAnswer((_) async => 'wrong-session');
    when(
      () => tmuxService.hasSession(session, 'correct-session'),
    ).thenAnswer((_) async => true);
    when(
      () => tmuxService.watchWindowChanges(session, any()),
    ).thenAnswer((_) => _idleWindowChanges());
    when(() => tmuxService.listWindows(session, any())).thenAnswer(
      (_) async => const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'editor', isActive: true),
      ],
    );

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
          tmuxServiceProvider.overrideWithValue(tmuxService),
        ],
      ),
    );
    hostsController.add(<Host>[]);
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('wrong-session · 1 windows'), findsOneWidget);

    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'correct-session',
      ),
    ]);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('correct-session · 1 windows'), findsOneWidget);
    expect(find.text('wrong-session · 1 windows'), findsNothing);
  });

  for (final backend in [RemoteMuxBackend.tmux, RemoteMuxBackend.monkeyMux]) {
    testWidgets(
      'preview updates reuse preferences and saved ${backend.name} presets refresh the badge',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final settings = _CountingSettingsService(db);
        final presets = AgentLaunchPresetService(settings);
        final tmux = _MockTmuxService();
        final monkeyMux = _MockMonkeyMuxService();
        final session = _badgeSession();
        final sessions = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(connectionId: 7, hostId: 1),
          ],
          initialSessions: [session],
        );
        when(
          () => tmux.currentSessionName(session),
        ).thenAnswer((_) async => 'shell');
        when(
          () => tmux.watchWindowChanges(session, any()),
        ).thenAnswer((_) => _idleWindowChanges());
        when(
          () => monkeyMux.watchWindowChanges(session, any()),
        ).thenAnswer((_) => _idleWindowChanges());
        const windows = [TmuxWindow(index: 0, name: 'editor', isActive: true)];
        var queries = 0;
        when(() => tmux.listWindows(session, any())).thenAnswer((_) async {
          queries++;
          return windows;
        });
        when(() => monkeyMux.listWindows(session, any())).thenAnswer((_) async {
          queries++;
          return windows;
        });
        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            initialTab: HomeScreenTab.connections,
            stubLaunchPresets: false,
            overrides: [
              settingsServiceProvider.overrideWithValue(settings),
              activeSessionsProvider.overrideWith(() => sessions),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                ]),
              ),
              tmuxServiceProvider.overrideWithValue(tmux),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMux),
              acpSessionManagerProvider.overrideWithValue(
                FakeAcpSessionManager(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('shell · 1 windows'), findsOneWidget);
        expect(queries, 1);
        expect(settings.preferenceReads, 0);
        expect(settings.presetSubscriptions, 1);

        for (var update = 0; update < 5; update++) {
          sessions.setActiveConnections([
            _buildActiveConnection(
              connectionId: 7,
              hostId: 1,
              preview: 'output $update',
            ),
          ]);
          await tester.pump();
        }
        expect(settings.preferenceReads, 0);
        expect(settings.presetSubscriptions, 1);
        expect(queries, 1);

        final preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: ' saved-session ',
          remoteMuxBackend: backend,
        );
        await presets.setPresetForHost(1, preset);
        await tester.pumpAndSettle();
        expect(find.text('saved-session · 1 windows'), findsOneWidget);
        expect(queries, 2);
        if (backend == RemoteMuxBackend.monkeyMux) {
          verify(
            () => monkeyMux.listWindows(session, 'saved-session'),
          ).called(1);
        } else {
          verify(() => tmux.listWindows(session, 'saved-session')).called(1);
        }
        await presets.setPresetForHost(2, preset);
        await presets.setPresetForHost(
          1,
          AgentLaunchPreset(
            tool: preset.tool,
            tmuxSessionName: preset.tmuxSessionName,
            remoteMuxBackend: preset.remoteMuxBackend,
            workingDirectory: '~/another-directory',
          ),
        );
        await tester.pumpAndSettle();
        expect(queries, 2);
        expect(settings.presetSubscriptions, 1);
        await presets.deletePresetForHost(1);
        await tester.pumpAndSettle();
        expect(find.text('shell · 1 windows'), findsOneWidget);
        expect(queries, 3);
        await tester.pumpWidget(const SizedBox.shrink());
        // Cancelling the real settings stream schedules Drift's zero-duration
        // cache cleanup timer. A pump without a duration only flushes microtasks.
        await tester.pump(Duration.zero);
      },
    );
  }

  for (final duringCancellation in [false, true]) {
    testWidgets(
      'stops tmux work after disposal during ${duringCancellation ? 'cancellation' : 'preferences'}',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final cliLaunchPreferencesService =
            _MockHostCliLaunchPreferencesService();
        final tmuxService = _MockTmuxService();
        final presetCompleter = Completer<Map<String, AgentLaunchPreset>>();
        final cancellation = Completer<void>();
        var cancelling = false;
        final changes = StreamController<TmuxWindowChangeEvent>(
          onCancel: () {
            cancelling = true;
            return cancellation.future;
          },
        );
        addTearDown(() {
          if (!cancellation.isCompleted) cancellation.complete();
          if (!presetCompleter.isCompleted) presetCompleter.complete(const {});
          if (!cancelling && !changes.hasListener) {
            unawaited(changes.stream.listen((_) {}).cancel());
          }
          return changes.close();
        });

        var presetLoadStarted = false;
        final session = _badgeSession();
        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(connectionId: 7, hostId: 1),
          ],
          initialSessions: [session],
        );

        when(
          () => tmuxService.isTmuxActive(session),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.currentSessionName(session),
        ).thenAnswer((_) async => 'work');
        when(() => tmuxService.watchWindowChanges(session, 'work')).thenAnswer(
          (_) => duringCancellation ? changes.stream : _idleWindowChanges(),
        );
        when(
          () => tmuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => const <TmuxWindow>[]);

        try {
          await tester.pumpWidget(
            buildMobileHomeScreen(
              db: db,
              stubLaunchPresets: false,
              overrides: [
                activeSessionsProvider.overrideWith(() => sessionsNotifier),
                allHostsProvider.overrideWith(
                  (ref) => Stream.value([
                    _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                  ]),
                ),
                agentLaunchPresetMapProvider.overrideWith((ref) {
                  presetLoadStarted = true;
                  return Stream.fromFuture(
                    duringCancellation
                        ? Future.value(const <String, AgentLaunchPreset>{})
                        : presetCompleter.future,
                  );
                }),
                hostCliLaunchPreferencesServiceProvider.overrideWithValue(
                  cliLaunchPreferencesService,
                ),
                tmuxServiceProvider.overrideWithValue(tmuxService),
              ],
            ),
          );
          await tester.pump();
          await tester.tap(find.text('Connections').first);
          await tester.pump();
          // The preset event schedules a provider rebuild and then a query
          // after that frame; flush both before inspecting service calls.
          await tester.pump();
          await tester.pump();
          expect(presetLoadStarted, isTrue);
          if (duringCancellation) {
            verify(
              () => tmuxService.watchWindowChanges(session, 'work'),
            ).called(1);
            verify(() => tmuxService.listWindows(session, 'work')).called(1);
            expect(cancelling, isFalse);
            // Empty windows schedule a retry that replaces the subscription.
            await tester.pump(const Duration(seconds: 10));
            await tester.pump();
            expect(cancelling, isTrue);
            expect(cancellation.isCompleted, isFalse);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          if (duringCancellation) {
            cancellation.complete();
          } else {
            presetCompleter.complete(const {});
          }
          await tester.pump();
          await tester.pump();

          expect(tester.takeException(), isNull);
          verifyNever(() => tmuxService.watchWindowChanges(session, 'work'));
          verifyNever(() => tmuxService.listWindows(session, 'work'));
          if (!duringCancellation) {
            verifyNever(() => tmuxService.currentSessionName(session));
            verifyNever(
              () => cliLaunchPreferencesService.getPreferencesForHost(any()),
            );
          }
        } finally {
          // Dispose providers and cancel retry timers even if an assertion fails.
          await tester.pumpWidget(const SizedBox.shrink());
          if (!cancellation.isCompleted) cancellation.complete();
          if (!presetCompleter.isCompleted) presetCompleter.complete(const {});
          await tester.pump();
          await tester.pump();
        }
      },
    );
  }

  for (final backend in [RemoteMuxBackend.tmux, RemoteMuxBackend.monkeyMux]) {
    testWidgets(
      '${backend.name} badge switches and closes using the stable window ID',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final acpManager = FakeAcpSessionManager();
        addTearDown(acpManager.dispose);
        const sessionName = 'work';
        final session = _badgeSession()
          ..remoteMuxBackend = backend
          ..remoteMuxSessionName = sessionName;
        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 7,
              hostId: 1,
              remoteMuxBackend: backend,
              remoteMuxSessionName: sessionName,
            ),
          ],
          initialSessions: [session],
        );
        final watchWindows = backend == RemoteMuxBackend.monkeyMux
            ? () => monkeyMuxService.watchWindowChanges(session, sessionName)
            : () => tmuxService.watchWindowChanges(session, sessionName);
        final listWindows = backend == RemoteMuxBackend.monkeyMux
            ? () => monkeyMuxService.listWindows(session, sessionName)
            : () => tmuxService.listWindows(session, sessionName);
        final selectWindow = backend == RemoteMuxBackend.monkeyMux
            ? () => monkeyMuxService.selectWindow(
                session,
                sessionName,
                1,
                windowId: '@42',
              )
            : () => tmuxService.selectWindow(
                session,
                sessionName,
                1,
                windowId: '@42',
              );
        final killWindow = backend == RemoteMuxBackend.monkeyMux
            ? () => monkeyMuxService.killWindow(
                session,
                sessionName,
                1,
                windowId: '@42',
              )
            : () => tmuxService.killWindow(
                session,
                sessionName,
                1,
                windowId: '@42',
              );
        when(watchWindows).thenAnswer((_) => _idleWindowChanges());
        when(listWindows).thenAnswer(
          (_) async => const [
            TmuxWindow(id: '@1', index: 0, name: 'shell', isActive: true),
            TmuxWindow(id: '@42', index: 1, name: 'target', isActive: false),
          ],
        );
        when(selectWindow).thenAnswer((_) async {});
        when(killWindow).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(
                    id: 1,
                    label: 'Alpha',
                    sortOrder: 0,
                    tmuxSessionName: sessionName,
                    remoteMuxBackend: backend,
                  ),
                ]),
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
              acpSessionManagerProvider.overrideWithValue(acpManager),
            ],
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Connections').first);
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.tap(find.text('$sessionName · 2 windows'));
        await tester.pump();

        await tester.tap(find.text('target'));
        await tester.pump();
        verify(selectWindow).called(1);

        final targetRow = find
            .ancestor(of: find.text('target'), matching: find.byType(InkWell))
            .first;
        await tester.tap(
          find.descendant(of: targetRow, matching: find.byIcon(Icons.close)),
        );
        await tester.pump();
        verify(killWindow).called(1);
        expect(find.text('target'), findsNothing);
        expect(find.text('shell'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'loads the current tmux query after an overlapping stale refresh finishes',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final tmuxService = _MockTmuxService();
      final preferences = StreamController<Map<String, AgentLaunchPreset>>();
      final oldWindows = Completer<List<TmuxWindow>>();
      final oldSubscriptionCancellation = Completer<void>();
      final windowChangeControllers =
          <StreamController<TmuxWindowChangeEvent>>[];
      var oldSubscriptionCancellationStarted = false;
      var currentSessionName = 'old-session';
      final session = _badgeSession();
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: 1),
        ],
        initialSessions: [session],
      );
      when(
        () => tmuxService.currentSessionName(session),
      ).thenAnswer((_) async => currentSessionName);
      when(() => tmuxService.watchWindowChanges(session, any())).thenAnswer((
        invocation,
      ) {
        // Cancelling Stream.empty() returns a root-zone future that tester.pump
        // cannot flush. Keep cancellation futures in this test's fake-async zone.
        final controller = StreamController<TmuxWindowChangeEvent>(
          onCancel: () async {
            if (invocation.positionalArguments[1] == 'old-session') {
              oldSubscriptionCancellationStarted = true;
              await oldSubscriptionCancellation.future;
            }
          },
        );
        windowChangeControllers.add(controller);
        return controller.stream;
      });
      when(
        () => tmuxService.listWindows(session, 'old-session'),
      ).thenAnswer((_) => oldWindows.future);
      when(() => tmuxService.listWindows(session, 'new-session')).thenAnswer(
        (_) async => const [
          TmuxWindow(index: 0, name: 'current-window', isActive: true),
        ],
      );

      try {
        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            stubLaunchPresets: false,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                ]),
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              agentLaunchPresetMapProvider.overrideWith(
                (ref) => preferences.stream,
              ),
            ],
          ),
        );
        preferences.add(const {});
        await tester.pump();
        await tester.tap(find.text('Connections').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        verify(() => tmuxService.listWindows(session, 'old-session')).called(1);

        // A saved tool change starts a query while the old windows load.
        currentSessionName = 'new-session';
        preferences.add(const {
          '1': AgentLaunchPreset(tool: AgentLaunchTool.codex),
        });
        await tester.pump();
        await tester.pump();
        verify(() => tmuxService.currentSessionName(session)).called(2);
        expect(oldSubscriptionCancellationStarted, isTrue);
        verifyNever(
          () => tmuxService.watchWindowChanges(session, 'new-session'),
        );

        // Let the new query subscribe and queue its initial window load while
        // the old query's listWindows call is still outstanding.
        oldSubscriptionCancellation.complete();
        await tester.pump();
        await tester.pump();
        verify(
          () => tmuxService.watchWindowChanges(session, 'new-session'),
        ).called(1);
        expect(oldWindows.isCompleted, isFalse);
        verifyNever(() => tmuxService.listWindows(session, 'new-session'));

        oldWindows.complete(const [
          TmuxWindow(index: 0, name: 'stale-window', isActive: true),
        ]);
        await tester.pump();
        await tester.pump();
        verify(() => tmuxService.listWindows(session, 'new-session')).called(1);
        expect(find.text('new-session · 1 windows'), findsOneWidget);
        expect(find.text('old-session · 1 windows'), findsNothing);
        await tester.tap(find.text('new-session · 1 windows'));
        await tester.pump();
        expect(find.text('current-window'), findsOneWidget);
        expect(find.text('stale-window'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        unawaited(preferences.close());
        if (!oldWindows.isCompleted) oldWindows.complete(const []);
        if (!oldSubscriptionCancellation.isCompleted) {
          oldSubscriptionCancellation.complete();
        }
        for (final controller in windowChangeControllers) {
          unawaited(controller.close());
        }
        await tester.pump();
      }
    },
  );

  testWidgets(
    'connection badge includes native windows in MonkeyMux window list',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final tmuxService = _MockTmuxService();
      final monkeyMuxService = _MockMonkeyMuxService();

      final acpManager = FakeAcpSessionManager(
        sessions: [
          fakeAcpSession(
            title: 'Native task',
            providerLabel: 'Copilot CLI',
            cwd: '/home/dev/project',
          ),
        ],
      );
      addTearDown(acpManager.dispose);
      const sessionName = 'mmux-work';
      final session = _badgeSession()
        ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
        ..remoteMuxSessionName = sessionName;
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            remoteMuxBackend: RemoteMuxBackend.monkeyMux,
            remoteMuxSessionName: sessionName,
          ),
        ],
        initialSessions: [session],
      );

      when(
        () => monkeyMuxService.watchWindowChanges(
          session,
          sessionName,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) => _idleWindowChanges());
      when(
        () => monkeyMuxService.listWindows(
          session,
          sessionName,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer(
        (_) async => const <TmuxWindow>[
          TmuxWindow(index: 0, name: 'monkey', isActive: true),
        ],
      );

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(
                  id: 1,
                  label: 'Alpha',
                  sortOrder: 0,
                  tmuxSessionName: sessionName,
                  remoteMuxBackend: RemoteMuxBackend.monkeyMux,
                ),
              ]),
            ),
            tmuxServiceProvider.overrideWithValue(tmuxService),
            monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            acpSessionManagerProvider.overrideWithValue(acpManager),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('$sessionName · 2 windows'), findsOneWidget);
      await tester.tap(find.text('$sessionName · 2 windows'));
      await tester.pump();
      expect(find.text('Native task'), findsOneWidget);
      expect(find.text('NATIVE'), findsOneWidget);
      final nativeRow = find.byKey(
        ValueKey('connection-native-acp-window-${fakeAcpKey().value}'),
      );
      expect(nativeRow, findsOneWidget);
      final nativeIcon = tester.widget<AgentToolIcon>(
        find.byKey(
          ValueKey('connection-native-acp-agent-icon-${fakeAcpKey().value}'),
        ),
      );
      expect(
        nativeIcon.color,
        Theme.of(tester.element(nativeRow)).colorScheme.onSurfaceVariant,
      );
      await tester.pump(const Duration(seconds: 1));
      verify(
        () => monkeyMuxService.listWindows(
          session,
          sessionName,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).called(greaterThanOrEqualTo(1));
      verifyNever(() => tmuxService.listWindows(session, any()));
    },
  );

  testWidgets(
    'connection preview prefers active agent session title from mux',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final tmuxService = _MockTmuxService();

      const sessionName = 'work';
      final session = _badgeSession();
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(
            connectionId: 7,
            hostId: 1,
            preview: 'ready',
            windowTitle: 'Designing app prompt',
            iconName: 'Designing app prompt',
          ),
        ],
        initialSessions: [session],
      );

      when(
        () => tmuxService.watchWindowChanges(session, sessionName),
      ).thenAnswer((_) => _idleWindowChanges());
      when(() => tmuxService.listWindows(session, sessionName)).thenAnswer(
        (_) async => const <TmuxWindow>[
          TmuxWindow(
            index: 0,
            name: 'codex',
            isActive: true,
            agentSessionTitle: 'Implement onboarding',
          ),
        ],
      );

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(
                  id: 1,
                  label: 'Alpha',
                  sortOrder: 0,
                  tmuxSessionName: sessionName,
                ),
              ]),
            ),
            tmuxServiceProvider.overrideWithValue(tmuxService),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Connection #7 • Implement onboarding'), findsOneWidget);
      expect(find.text('Connection #7 • Designing app prompt'), findsNothing);
    },
  );

  testWidgets(
    'ignores stale tmux retries after host session info loads later',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final tmuxService = _MockTmuxService();

      final hostsController = StreamController<List<Host>>.broadcast();
      addTearDown(hostsController.close);

      final delayedWindows = Completer<List<TmuxWindow>>();
      final session = _badgeSession();
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: 1),
        ],
        initialSessions: [session],
      );

      when(
        () => tmuxService.isTmuxActive(session),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.currentSessionName(session),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.hasSession(session, 'correct-session'),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.watchWindowChanges(session, any()),
      ).thenAnswer((_) => _idleWindowChanges());
      when(
        () => tmuxService.listWindows(session, 'correct-session'),
      ).thenAnswer((_) => delayedWindows.future);

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith((ref) => hostsController.stream),
            tmuxServiceProvider.overrideWithValue(tmuxService),
          ],
        ),
      );
      hostsController.add(<Host>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pump();
      verify(() => tmuxService.currentSessionName(session)).called(1);

      hostsController.add([
        _buildHost(
          id: 1,
          label: 'Alpha',
          sortOrder: 0,
          tmuxSessionName: 'correct-session',
        ),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pump(const Duration(seconds: 2));

      delayedWindows.complete(const <TmuxWindow>[
        TmuxWindow(index: 0, name: 'editor', isActive: true),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('correct-session · 1 windows'), findsOneWidget);
      verifyNever(() => tmuxService.currentSessionName(session));
      verify(
        () => tmuxService.listWindows(session, 'correct-session'),
      ).called(1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('refreshes tmux badge when host extra flags change', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tmuxService = _MockTmuxService();

    final hostsController = StreamController<List<Host>>.broadcast();
    addTearDown(hostsController.close);

    final session = _badgeSession();
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [_buildActiveConnection(connectionId: 7, hostId: 1)],
      initialSessions: [session],
    );

    const oldFlags = '-S /tmp/old.sock';
    const newFlags = '-S /tmp/new.sock';
    for (final (flags, name) in [
      (oldFlags, 'old-server'),
      (newFlags, 'new-server'),
    ]) {
      when(
        () => tmuxService.hasSession(session, 'work', extraFlags: flags),
      ).thenAnswer((_) async => true);
      when(
        () =>
            tmuxService.watchWindowChanges(session, 'work', extraFlags: flags),
      ).thenAnswer((_) => _idleWindowChanges());
      when(
        () => tmuxService.listWindows(session, 'work', extraFlags: flags),
      ).thenAnswer(
        (_) async => [TmuxWindow(index: 0, name: name, isActive: true)],
      );
    }

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith((ref) => hostsController.stream),
          tmuxServiceProvider.overrideWithValue(tmuxService),
        ],
      ),
    );
    await tester.pump();
    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
        tmuxExtraFlags: oldFlags,
      ),
    ]);
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('work · 1 windows'), findsOneWidget);
    await tester.tap(find.text('work · 1 windows'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('old-server'), findsOneWidget);

    hostsController.add([
      _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
        tmuxExtraFlags: newFlags,
      ),
    ]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('new-server'), findsOneWidget);
    expect(find.text('old-server'), findsNothing);
    verify(
      () => tmuxService.listWindows(session, 'work', extraFlags: oldFlags),
    ).called(1);
    verify(
      () => tmuxService.listWindows(session, 'work', extraFlags: newFlags),
    ).called(1);
  });

  testWidgets(
    'home tmux badge uses latest host yolo preference when resuming a session',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settingsService = SettingsService(db);
      final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
        settingsService,
      );
      final tmuxService = _MockTmuxService();
      final discoveryService = _MockAgentSessionDiscoveryService();
      final monetizationService = _MockMonetizationService();

      final host = _buildHost(
        id: 1,
        label: 'Alpha',
        sortOrder: 0,
        tmuxSessionName: 'work',
      );
      final session = _badgeSession(hostId: host.id);
      final sessionsNotifier = _MutableActiveSessionsNotifier(
        initialConnections: [
          _buildActiveConnection(connectionId: 7, hostId: host.id),
        ],
        initialSessions: [session],
      );
      const codexSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'codex-session',
        workingDirectory: '/home/demo/project',
        summary: 'Resume codex work',
      );

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(
        () => monetizationService.states,
      ).thenAnswer((_) => Stream.value(_proMonetizationState));
      when(
        monetizationService.initialize,
      ).thenAnswer((_) => Future<void>.value());
      when(
        () => monetizationService.canUseFeature(any()),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.watchWindowChanges(session, 'work'),
      ).thenAnswer((_) => _idleWindowChanges());
      when(() => tmuxService.listWindows(session, 'work')).thenAnswer(
        (_) async => const <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
        ],
      );
      when(
        () => tmuxService.createWindow(
          session,
          'work',
          command: any(named: 'command'),
          name: any(named: 'name'),
          workingDirectory: any(named: 'workingDirectory'),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer((invocation) {
        final toolName = invocation.namedArguments[#toolName] as String?;
        return Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(
            sessions: toolName == 'Codex'
                ? const <ToolSessionInfo>[codexSession]
                : const <ToolSessionInfo>[],
            attemptedTools: toolName == null ? const <String>[] : [toolName],
          ),
        );
      });
      when(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).thenReturn("codex --yolo resume 'codex-session'");

      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          overrides: [
            settingsServiceProvider.overrideWithValue(settingsService),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
            activeSessionsProvider.overrideWith(() => sessionsNotifier),
            allHostsProvider.overrideWith((ref) => Stream.value([host])),
            tmuxServiceProvider.overrideWithValue(tmuxService),
            agentSessionDiscoveryServiceProvider.overrideWithValue(
              discoveryService,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connections').first);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('work · 1 windows'), findsOneWidget);

      await cliLaunchPreferencesService.setPreferencesForHost(
        host.id,
        const HostCliLaunchPreferences(startInYoloMode: true),
      );

      await tester.tap(find.text('work · 1 windows'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI Sessions'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.drag(find.text('work · 1 windows'), const Offset(0, -120));
      await tester.pump();
      await tester.tap(find.text('Codex'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Resume codex work'));
      await tester.tap(find.text('Resume codex work'));
      await tester.pump();
      await tester.pumpAndSettle();

      verify(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).called(1);
      verify(
        () => tmuxService.createWindow(
          session,
          'work',
          command: "codex --yolo resume 'codex-session'",
          name: 'Codex',
          workingDirectory: '/home/demo/project',
          extraFlags: null,
        ),
      ).called(1);
    },
  );

  testWidgets('returns to Hosts when the last active connection disappears', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final sessionsNotifier = _MutableActiveSessionsNotifier(
      initialConnections: [
        _buildActiveConnection(
          connectionId: 7,
          hostId: 1,
          state: SshConnectionState.connecting,
        ),
      ],
    );

    await tester.pumpWidget(
      buildMobileHomeScreen(
        db: db,
        overrides: [
          activeSessionsProvider.overrideWith(() => sessionsNotifier),
          allHostsProvider.overrideWith(
            (ref) =>
                Stream.value([_buildHost(id: 1, label: 'Alpha', sortOrder: 0)]),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Connections').first);
    await tester.pump();
    expect(find.text('no active sessions'), findsNothing);

    sessionsNotifier.setActiveConnections(const <ActiveConnection>[]);
    await tester.pump();
    await tester.pump();

    expect(find.text('no active sessions'), findsNothing);
  });

  group('HostRowData value equality', () {
    test('equal when all fields are identical', () {
      const a = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        connectionAttemptMessage: null,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );
      const b = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        connectionAttemptMessage: null,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('unequal when isConnected differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionIds differ', () {
      const a = HostRowData(
        connectionIds: [1],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [2],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionAttemptMessage differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Connecting…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Authenticating…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when isPinnedToHomeScreen differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: true,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('connectionCount reflects connectionIds length', () {
      const data = HostRowData(
        connectionIds: [10, 20, 30],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(data.connectionCount, 3);
    });
  });

  for (final tab in [HomeScreenTab.hosts, HomeScreenTab.connections]) {
    testWidgets('${tab.name} isolates live preview updates by connection', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final connectionA = _buildActiveConnection(
        connectionId: 1,
        hostId: 1,
        preview: 'A unchanged',
      );
      ActiveConnection connectionB(String preview) =>
          _buildActiveConnection(connectionId: 2, hostId: 2, preview: preview);
      final sessions = _MutableActiveSessionsNotifier(
        initialConnections: [connectionA, connectionB('B before')],
      );
      await tester.pumpWidget(
        buildMobileHomeScreen(
          db: db,
          initialTab: tab,
          overrides: [
            activeSessionsProvider.overrideWith(() => sessions),
            allHostsProvider.overrideWith(
              (ref) => Stream.value([
                _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                _buildHost(id: 2, label: 'Beta', sortOrder: 1),
              ]),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final previewA = find.ancestor(
        of: find.text('A unchanged'),
        matching: find.byType(ConnectionPreviewStack),
      );
      final beforeA = tester.widget<ConnectionPreviewStack>(previewA);
      final list = find.ancestor(of: previewA, matching: find.byType(ListView));
      final beforeList = tab == HomeScreenTab.connections
          ? tester.widget(list)
          : null;
      expect(find.text('B before'), findsOneWidget);

      sessions.setActiveConnections([connectionA, connectionB('B after')]);
      await tester.pump();
      expect(tester.widget<ConnectionPreviewStack>(previewA), same(beforeA));
      expect(find.text('B before'), findsNothing);
      expect(find.text('B after'), findsOneWidget);
      if (tab == HomeScreenTab.connections) {
        expect(tester.widget(list), same(beforeList));
        sessions.setActiveConnections([connectionB('B after'), connectionA]);
        await tester.pump();
        expect(
          tester.getTopLeft(find.text('B after')).dy,
          lessThan(tester.getTopLeft(find.text('A unchanged')).dy),
        );
        sessions.setActiveConnections([connectionA]);
        await tester.pump();
        expect(find.text('A unchanged'), findsOneWidget);
        expect(find.text('B after'), findsNothing);
      }

      // Connected rows without SSH sessions leave tmux discovery retries pending.
      // Unmount before completing their delay so they cannot schedule more work.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  }

  group('hostRowDataProvider per-host isolation', () {
    testWidgets(
      'host row shows connected indicator when its connection is active',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 1,
              hostId: 1,
              state: SshConnectionState.connected,
            ),
          ],
        );

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                  _buildHost(id: 2, label: 'Beta', sortOrder: 1),
                ]),
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Host 1 has a connection, shown with a count badge.
        expect(find.text('1'), findsOneWidget);
        // Host 2 has no connection badge.
        expect(find.text('2'), findsNothing);
      },
    );

    testWidgets(
      'adding a connection to host B does not remove host A connection badge',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final sessionsNotifier = _MutableActiveSessionsNotifier(
          initialConnections: [
            _buildActiveConnection(
              connectionId: 1,
              hostId: 1,
              state: SshConnectionState.connected,
            ),
          ],
        );

        await tester.pumpWidget(
          buildMobileHomeScreen(
            db: db,
            overrides: [
              activeSessionsProvider.overrideWith(() => sessionsNotifier),
              allHostsProvider.overrideWith(
                (ref) => Stream.value([
                  _buildHost(id: 1, label: 'Alpha', sortOrder: 0),
                  _buildHost(id: 2, label: 'Beta', sortOrder: 1),
                ]),
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('1'), findsOneWidget);

        // Add a connection for host 2. Host 1's badge must still be present.
        sessionsNotifier.setActiveConnections([
          _buildActiveConnection(
            connectionId: 1,
            hostId: 1,
            state: SshConnectionState.connected,
          ),
          _buildActiveConnection(
            connectionId: 2,
            hostId: 2,
            state: SshConnectionState.connected,
          ),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Both hosts should now show a connection count badge.
        expect(find.text('1'), findsNWidgets(2));
      },
    );
  });
}
