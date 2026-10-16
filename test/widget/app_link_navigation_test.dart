// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/app_link_handler.dart';
import 'package:monkeyssh/app/app_link_navigation.dart';
import 'package:monkeyssh/app/notification_navigation.dart';
import 'package:monkeyssh/app/push_notification_bridge.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/app_link.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/host_notifications.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/app_link_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/host_notification_prefs_reader.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';
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
  final holds = <int>[];

  @override
  void holdAutomaticForwardingUntilStarted(int hostId) => holds.add(hostId);

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

/// Push messages a test taps on.
class _PushGateway implements PushMessagingGateway {
  // Closed by the test group's tearDown.
  // ignore: close_sinks
  final opened = StreamController<PushRemoteMessage>.broadcast();

  @override
  Stream<PushRemoteMessage> get onMessage =>
      const Stream<PushRemoteMessage>.empty();

  @override
  Stream<PushRemoteMessage> get onMessageOpenedApp => opened.stream;

  @override
  Future<PushRemoteMessage?> getInitialMessage() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> getToken() async => null;

  @override
  Future<PushRegistration> register({
    required String token,
    required String platform,
    String? deviceId,
    bool appNotifications = false,
  }) => throw UnimplementedError();

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> setAutoInitEnabled({required bool enabled}) async {}
}

/// Resolves every tap to [target].
class _PushController extends PushNotificationController {
  _PushController(this.target);

  final PushNavigationTarget target;

  @override
  PushNotificationState build() =>
      const PushNotificationState(available: true, loaded: true);

  @override
  Future<PushNavigationTarget?> resolve(PushRemoteMessage message) async =>
      target;

  @override
  void reportVisibility({
    required bool foreground,
    int? viewedHostId,
    int? viewedConnectionId,
  }) {}
}

class _NoLaunchNotifications extends LocalNotificationService {
  @override
  Future<String?> consumeLaunchPushPayload() async => null;

  @override
  Future<String?> currentActivityPushPayload() async => null;
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
  notifyAgentAttention: true,
  notifyAgentFinished: true,
  notifyWindowAlerts: true,
  notifyShellNotifications: true,
  pushWhenClosed: true,
);

void main() {
  group('takeExternalLocation', () {
    late AppLinkService links;

    setUp(() {
      links = AppLinkService(
        channel: const MethodChannel('test/app_links'),
        diagnostics: RecordingDiagnosticsLogger(),
      );
    });

    tearDown(() => links.dispose());

    test('leaves in-app locations to the router', () {
      for (final location in [
        '/',
        '/terminal/1',
        buildTmuxAlertHomeLocation(),
        // A session name is user text, so it may itself look like a URL.
        buildPushNotificationTerminalLocation(
          const PushNavigationTarget(
            hostId: 3,
            kind: PushEventKind.permission,
            sessionName: 'monkeyssh://open?host=4',
            windowId: '@2',
            connectionId: 9,
          ),
          notificationTapId: 'tap',
        ),
        '/hosts/import-ssh-config',
      ]) {
        expect(
          takeExternalLocation(Uri.parse(location), links),
          isFalse,
          reason: location,
        );
      }
      expect(links.hasPending, isFalse);
    });

    test('queues app links', () {
      expect(
        takeExternalLocation(
          Uri.parse('monkeyssh://open/?host=3&window=1'),
          links,
        ),
        isTrue,
      );
      expect(
        links.takePending(),
        const OpenHostAppLink(hostId: 3, windowIndex: 1),
      );
    });

    test('queues ssh links for review', () {
      takeExternalLocation(Uri.parse('ssh://root@example.com/'), links);

      expect(
        links.takePending(),
        const SshHostAppLink(hostname: 'example.com', username: 'root'),
      );
    });

    test('drops other deep links without turning them into routes', () {
      for (final location in [
        'https://example.com/terminal/1',
        'content://provider/document/1',
        'file:///private/var/mobile/a.txt',
      ]) {
        expect(
          takeExternalLocation(Uri.parse(location), links),
          isTrue,
          reason: location,
        );
      }
      expect(links.hasPending, isFalse);
    });
  });

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
    // Like the production router, no onEnter guard: the bridge takes
    // platform deep links before the router sees them.
    router = GoRouter(
      navigatorKey: appNavigatorKey,
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
    _PushGateway? push,
  }) async {
    final auth = _TestAuth(authState);
    Widget app = AppLinkNavigationBridge(
      child: MaterialApp.router(theme: FluttyTheme.dark, routerConfig: router),
    );
    if (push != null) {
      // As in the app: push taps and links share the router.
      app = PushNotificationBridge(child: app);
    }
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
          if (push != null) ...[
            pushNotificationsAvailableProvider.overrideWithValue(true),
            pushMessagingGatewayProvider.overrideWithValue(push),
            pushNotificationControllerProvider.overrideWith(
              () => _PushController(
                const PushNavigationTarget(
                  hostId: 4,
                  kind: PushEventKind.permission,
                  sessionName: 'main',
                  windowId: '@3',
                  connectionId: 21,
                ),
              ),
            ),
            hostNotificationPrefsReaderProvider.overrideWithValue(
              (_) async => const HostNotificationPrefs(),
            ),
            localNotificationServiceProvider.overrideWithValue(
              _NoLaunchNotifications(),
            ),
          ],
        ],
        child: app,
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

  for (final newerLink in [false, true]) {
    testWidgets('a lock during the lookup keeps the link waiting, '
        'newer link: $newerLink', (tester) async {
      final lookup = Completer<Host?>();
      when(() => hosts.getById(3)).thenAnswer((_) => lookup.future);
      when(() => hosts.getById(4)).thenAnswer((_) async => _host(4));
      final auth = await pumpBridge(tester);

      links.receive(Uri.parse('monkeyssh://open?host=3'));
      await tester.pump();
      await tester.pump();
      verify(() => hosts.getById(3)).called(1);

      auth.current = AuthState.locked;
      if (newerLink) {
        links.receive(Uri.parse('monkeyssh://open?host=4'));
      }
      lookup.complete(_host(3));
      await tester.pumpAndSettle();
      expect(find.textContaining('terminal'), findsNothing);

      when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
      auth.current = AuthState.unlocked;
      await tester.pumpAndSettle();

      // The newest link wins, as it does for links that arrive while locked.
      expect(
        find.textContaining('terminal /terminal/${newerLink ? 4 : 3}?linkTap='),
        findsOneWidget,
      );
    });
  }

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
    // The review showed only the agent, so open-port detection waits.
    expect(sessions.holds, [7]);
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

  /// Delivers [location] the way the platform does, as iOS sends
  /// `monkeyssh://open?host=3` after the first frame.
  Future<void> platformPush(WidgetTester tester, String location) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        MethodCall('pushRouteInformation', <String, Object?>{
          'location': location,
          'state': null,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a platform deep link reaches the bridge, not the router', (
    tester,
  ) async {
    when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
    await pumpBridge(tester);

    await platformPush(tester, 'monkeyssh://open?host=3&window=2');

    expect(
      find.textContaining('terminal /terminal/3?tmuxWindow=2&linkTap='),
      findsOneWidget,
    );
    expect(find.textContaining('monkeyssh'), findsNothing);
  });

  testWidgets('other platform URLs with a scheme leave the route alone', (
    tester,
  ) async {
    await pumpBridge(tester);

    for (final location in [
      'content://provider/document/1',
      'file:///private/var/mobile/a.txt',
      'https://example.com/terminal/1',
    ]) {
      await platformPush(tester, location);
      expect(router.state.uri.toString(), '/', reason: location);
    }
    expect(links.hasPending, isFalse);
    expect(tester.takeException(), isNull);

    // Platform paths without a scheme still reach the router.
    await platformPush(tester, '/terminal/5');
    expect(router.state.uri.path, '/terminal/5');
  });

  group('with push notifications', () {
    late _PushGateway push;

    setUp(() => push = _PushGateway());
    tearDown(() => push.opened.close());

    var message = 0;
    void tapPush() => push.opened.add(
      PushRemoteMessage(data: {'v': '1', 'p': 'sealed-${message++}'}),
    );

    testWidgets('push taps and links each open their own terminal', (
      tester,
    ) async {
      when(() => hosts.getById(7)).thenAnswer((_) async => _host(7));
      await pumpBridge(tester, push: push);

      links.receive(Uri.parse('monkeyssh://open?host=7&window=1'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/terminal/7');
      expect(router.state.uri.queryParameters['tmuxWindow'], '1');
      expect(router.state.uri.queryParameters, contains('linkTap'));

      tapPush();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/terminal/4');
      expect(router.state.uri.queryParameters['tmuxWindowId'], '@3');
      expect(router.state.uri.queryParameters['connectionId'], '21');
      expect(router.state.uri.queryParameters, isNot(contains('linkTap')));

      links.receive(Uri.parse('monkeyssh://open?host=7&window=2'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/terminal/7');
      expect(router.state.uri.queryParameters['tmuxWindow'], '2');

      // Each one replaced the stack, leaving Connections underneath.
      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.toString(), '/?tab=connections');
      expect(router.canPop(), isFalse);
    });

    testWidgets('a push tap during a preset review opens its terminal and '
        'runs nothing', (tester) async {
      stubYoloPreset(7);
      when(() => hosts.getById(3)).thenAnswer((_) async => _host(3));
      await pumpBridge(tester, push: push);

      links.receive(Uri.parse('monkeyssh://preset?id=7'));
      await tester.pumpAndSettle();
      expect(find.text('Run launch preset?'), findsOneWidget);

      tapPush();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/terminal/4');
      expect(sessions.connects, isEmpty);

      // The review is still waiting, and links after it still open.
      links.receive(Uri.parse('monkeyssh://open?host=3'));
      await tester.pumpAndSettle();
      expect(sessions.connects, isEmpty);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Run launch preset?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(sessions.connects, isEmpty);
      expect(router.state.uri.path, '/terminal/3');
    });
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
