// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/app_link_handler.dart';
import 'package:monkeyssh/app/app_link_navigation.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/app_link_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../helpers/mocks.dart';
import '../helpers/recording_diagnostics_logger.dart';

class _TestAuth extends AuthStateNotifier {
  _TestAuth(this._initial);

  final AuthState _initial;

  @override
  AuthState build() => _initial;

  AuthState get current => state;

  set current(AuthState next) => state = next;
}

/// Connects instantly, as a stand-in for the SSH session layer.
class _InstantSessions extends ActiveSessionsNotifier {
  final connects = <({int hostId, bool forceNew})>[];

  @override
  Map<int, SshConnectionState> build() => {};

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    connects.add((hostId: hostId, forceNew: forceNew));
    return const SshConnectionResult(success: true, connectionId: 42);
  }
}

const _proState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

class _MockRecentSessions extends Mock implements AcpRecentSessionsService {}

class _MockPresetService extends Mock implements AgentLaunchPresetService {}

class _MockCliPreferences extends Mock
    implements HostCliLaunchPreferencesService {}

Host _host(int id) => Host(
  id: id,
  label: 'build box',
  hostname: 'build.example.com',
  username: 'deploy',
  port: 22,
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  sortOrder: 0,
);

void main() {
  late MockHostRepository hosts;
  late _MockRecentSessions recentSessions;
  late _MockPresetService presets;
  late _MockCliPreferences cliPreferences;
  late AppLinkService links;
  late GoRouter router;
  late MockMonetizationService monetization;
  late _InstantSessions sessions;

  setUpAll(() {
    registerFallbackValue(MonetizationFeature.autoConnectAutomation);
  });

  setUp(() {
    hosts = MockHostRepository();
    recentSessions = _MockRecentSessions();
    presets = _MockPresetService();
    cliPreferences = _MockCliPreferences();
    links = AppLinkService(
      channel: const MethodChannel('test/app_links'),
      diagnostics: RecordingDiagnosticsLogger(),
    );
    monetization = MockMonetizationService();
    when(() => monetization.canUseFeature(any())).thenAnswer((_) async => true);
    when(() => monetization.currentState).thenReturn(_proState);
    sessions = _InstantSessions();
    router = GoRouter(
      navigatorKey: appNavigatorKey,
      // The production guard: a platform deep link never becomes a route.
      onEnter: (_, _, next, _) => guardExternalLocation(next.uri, links),
      routes: [
        GoRoute(
          path: '/',
          builder: (_, state) => Scaffold(body: Text('home ${state.uri}')),
        ),
        GoRoute(
          path: '/terminal/:hostId',
          builder: (_, state) => Scaffold(body: Text('terminal ${state.uri}')),
        ),
        GoRoute(
          path: '/hosts/add',
          builder: (_, state) => Scaffold(
            body: Text('add host ${state.uri.queryParameters['sshUrl']}'),
          ),
        ),
      ],
    );
    when(() => hosts.getById(any())).thenAnswer((_) async => null);
    when(() => hosts.getAll()).thenAnswer((_) async => const <Host>[]);
    when(() => recentSessions.list()).thenAnswer((_) async => const []);
    when(() => presets.getPresetStateForHost(any()))
        .thenAnswer((_) async => (preset: null, isUnsupported: false));
    when(() => cliPreferences.getPreferencesForHost(any()))
        .thenAnswer((_) async => const HostCliLaunchPreferences());
  });

  tearDown(() {
    router.dispose();
    links.dispose();
  });

  Future<_TestAuth> pumpBridge(
    WidgetTester tester, {
    AuthState authState = AuthState.notConfigured,
  }) async {
    final auth = _TestAuth(authState);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(() => auth),
          routerProvider.overrideWithValue(router),
          appLinkServiceProvider.overrideWithValue(links),
          hostRepositoryProvider.overrideWithValue(hosts),
          acpRecentSessionsServiceProvider.overrideWithValue(recentSessions),
          agentLaunchPresetServiceProvider.overrideWithValue(presets),
          hostCliLaunchPreferencesServiceProvider.overrideWithValue(
            cliPreferences,
          ),
          monetizationServiceProvider.overrideWithValue(monetization),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proState),
          ),
          activeSessionsProvider.overrideWith(() => sessions),
        ],
        child: AppLinkNavigationBridge(
          child: MaterialApp.router(
            theme: FluttyTheme.dark,
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  void stubYoloPreset(int hostId) {
    when(() => hosts.getById(hostId)).thenAnswer((_) async => _host(hostId));
    when(() => presets.getPresetStateForHost(hostId)).thenAnswer(
      (_) async => (
        preset: const AgentLaunchPreset(tool: AgentLaunchTool.claudeCode),
        isUnsupported: false,
      ),
    );
    when(() => cliPreferences.getPreferencesForHost(hostId)).thenAnswer(
      (_) async => const HostCliLaunchPreferences(startInYoloMode: true),
    );
  }

  testWidgets('a link received while locked waits until unlock', (
    tester,
  ) async {
    when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
    final auth = await pumpBridge(tester, authState: AuthState.locked);

    links.receive(Uri.parse('monkeyssh://open?host=3&window=1'));
    await tester.pumpAndSettle();

    expect(find.textContaining('terminal'), findsNothing);
    verifyNever(() => hosts.getById(any()));

    auth.current = AuthState.unlocked;
    await tester.pumpAndSettle();

    expect(
      find.textContaining('terminal /terminal/3?tmuxWindow=1&linkTap='),
      findsOneWidget,
    );
    // Connections sits underneath, as when opening the host by hand.
    expect(router.canPop(), isTrue);
  });

  testWidgets('an unknown host shows a clear message', (tester) async {
    await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://open?host=99'));
    await tester.pumpAndSettle();

    expect(find.text(AppLinkMessages.hostMissing), findsOneWidget);
    expect(find.textContaining('terminal'), findsNothing);
  });

  testWidgets('a malformed link shows a clear message', (tester) async {
    await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://run?command=whoami'));
    await tester.pumpAndSettle();

    expect(find.text(AppLinkMessages.invalid), findsOneWidget);
  });

  testWidgets('a preset link shows its YOLO command and Cancel runs nothing', (
    tester,
  ) async {
    stubYoloPreset(7);
    await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://preset?id=7'));
    await tester.pumpAndSettle();

    expect(find.text('Run launch preset?'), findsOneWidget);
    expect(find.text('YOLO mode is on'), findsOneWidget);
    final command = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('app-link-preset-command')),
    );
    expect(command.data, 'claude --dangerously-skip-permissions');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Run launch preset?'), findsNothing);
    expect(find.textContaining('terminal'), findsNothing);
    expect(router.canPop(), isFalse);
  });

  testWidgets('a link that arrives during a preset review waits for it', (
    tester,
  ) async {
    stubYoloPreset(7);
    when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
    await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://preset?id=7'));
    await tester.pumpAndSettle();
    links.receive(Uri.parse('monkeyssh://open?host=3'));
    await tester.pumpAndSettle();

    expect(find.text('Run launch preset?'), findsOneWidget);
    expect(find.textContaining('terminal'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('terminal /terminal/3?linkTap='),
      findsOneWidget,
    );
  });

  testWidgets('Run connects anew and opens a terminal that starts the preset', (
    tester,
  ) async {
    stubYoloPreset(7);
    await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://preset?id=7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run in YOLO mode'));
    await tester.pumpAndSettle();

    expect(sessions.connects, [(hostId: 7, forceNew: true)]);
    expect(
      find.text('terminal /terminal/7?connectionId=42&presetRun=1'),
      findsOneWidget,
    );
    expect(router.canPop(), isTrue);
  });

  testWidgets('locking during a preset review runs nothing', (tester) async {
    stubYoloPreset(7);
    final auth = await pumpBridge(tester);

    links.receive(Uri.parse('monkeyssh://preset?id=7'));
    await tester.pumpAndSettle();
    auth.current = AuthState.locked;
    await tester.tap(find.text('Run in YOLO mode'));
    await tester.pumpAndSettle();

    expect(sessions.connects, isEmpty);
    expect(find.textContaining('terminal'), findsNothing);
  });

  testWidgets('a platform deep link goes through the router guard', (
    tester,
  ) async {
    when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
    await pumpBridge(tester);

    // What iOS sends after the first frame for monkeyssh://open?host=3.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('pushRouteInformation', <String, Object?>{
          'location': 'monkeyssh://open?host=3&window=2',
          'state': null,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('terminal /terminal/3?tmuxWindow=2&linkTap='),
      findsOneWidget,
    );
    expect(find.textContaining('monkeyssh'), findsNothing);
  });

  testWidgets('an ssh link with a password is refused', (tester) async {
    await pumpBridge(tester);

    links.receive(Uri.parse('ssh://root:hunter2@example.com'));
    await tester.pumpAndSettle();

    expect(find.text(AppLinkMessages.embeddedCredentials), findsOneWidget);
    expect(find.textContaining('add host'), findsNothing);
    expect(find.textContaining('hunter2'), findsNothing);
  });

  testWidgets('an ssh link for a new host opens the reviewed form', (
    tester,
  ) async {
    await pumpBridge(tester);

    links.receive(Uri.parse('ssh://deploy@example.com:2200/srv?prompt=hi'));
    await tester.pumpAndSettle();

    expect(find.text('add host ssh://deploy@example.com:2200'), findsOneWidget);
  });
}
