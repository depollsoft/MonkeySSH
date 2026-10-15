import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/app/push_notification_bridge.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/domain/models/host_notifications.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/host_notification_prefs_reader.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class _TerminalNotifications extends TerminalNotificationsNotifier {
  _TerminalNotifications({required this.enabled});

  final bool enabled;

  @override
  bool build() => enabled;
}

/// Local notifications whose current Android activity was started by a tap
/// on [activityPayload].
class _ActivityNotifications extends LocalNotificationService {
  String? activityPayload;

  @override
  Future<String?> consumeLaunchPushPayload() async => null;

  @override
  Future<String?> currentActivityPushPayload() async => activityPayload;
}

class _UnlockedAuth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;
}

class _Gateway implements PushMessagingGateway {
  final messages = StreamController<PushRemoteMessage>.broadcast();
  final opened = StreamController<PushRemoteMessage>.broadcast();
  PushRemoteMessage? initial;

  Future<void> close() async {
    await messages.close();
    await opened.close();
  }

  @override
  Stream<PushRemoteMessage> get onMessage => messages.stream;

  @override
  Stream<PushRemoteMessage> get onMessageOpenedApp => opened.stream;

  @override
  Future<PushRemoteMessage?> getInitialMessage() async => initial;

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

class _Controller extends PushNotificationController {
  PushNavigationTarget? target;
  bool suppress = false;
  final visibility = <(bool, int?)>[];

  @override
  PushNotificationState build() =>
      const PushNotificationState(available: true, loaded: true);

  @override
  Future<PushNavigationTarget?> resolve(PushRemoteMessage message) async =>
      target;

  @override
  bool shouldSuppressInForeground(PushNavigationTarget target) => suppress;

  @override
  void reportVisibility({
    required bool foreground,
    int? viewedHostId,
    int? viewedConnectionId,
  }) {
    visibility.add((foreground, viewedHostId));
    connections.add(viewedConnectionId);
  }

  final connections = <int?>[];
}

const _message = PushRemoteMessage(data: {'v': '1', 'p': 'sealed'});

/// Notification taps whose terminal page was built. A real terminal starts
/// connecting when it is built, even if a later navigation replaces it.
final _terminalTaps = <String?>{};

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) =>
          Scaffold(body: Text('home ${state.uri.queryParameters['tab']}')),
    ),
    GoRoute(
      path: '/terminal/:hostId',
      builder: (context, state) {
        _terminalTaps.add(state.uri.queryParameters['notificationTap']);
        return Scaffold(body: Text('terminal ${state.uri}'));
      },
    ),
  ],
);

/// Stands in for the app's router provider, which builds a new router on
/// auth transitions.
class _RouterHolder extends Notifier<GoRouter> {
  @override
  GoRouter build() => _router();

  void rebuild() => state = _router();
}

final _routerHolder = NotifierProvider<_RouterHolder, GoRouter>(
  _RouterHolder.new,
);

Future<(_Gateway, _Controller, GoRouter)> _pump(
  WidgetTester tester, {
  bool available = true,
  PushRemoteMessage? initial,
  PushNavigationTarget? target,
  HostNotificationPrefs prefs = const HostNotificationPrefs(),
  bool terminalNotifications = true,
  LocalNotificationService? notifications,
}) async {
  final gateway = _Gateway()..initial = initial;
  addTearDown(gateway.close);
  final controller = _Controller()..target = target;
  final router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pushNotificationsAvailableProvider.overrideWithValue(available),
        pushMessagingGatewayProvider.overrideWithValue(gateway),
        pushNotificationControllerProvider.overrideWith(() => controller),
        routerProvider.overrideWithValue(router),
        authStateProvider.overrideWith(_UnlockedAuth.new),
        hostNotificationPrefsReaderProvider.overrideWithValue(
          (_) async => prefs,
        ),
        terminalNotificationsNotifierProvider.overrideWith(
          () => _TerminalNotifications(enabled: terminalNotifications),
        ),
        if (notifications != null)
          localNotificationServiceProvider.overrideWithValue(notifications),
      ],
      child: PushNotificationBridge(
        child: MaterialApp.router(routerConfig: router),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (gateway, controller, router);
}

void main() {
  const target = PushNavigationTarget(
    hostId: 4,
    kind: PushEventKind.permission,
    sessionName: 'main',
    windowId: '@3',
    connectionId: 21,
  );

  test('the terminal location carries ids and the session name', () {
    final location = Uri.parse(
      buildPushNotificationTerminalLocation(target, notificationTapId: 't1'),
    );
    expect(location.path, '/terminal/4');
    expect(location.queryParameters, {
      'connectionId': '21',
      'tmuxSession': 'main',
      'tmuxWindow': '0',
      'tmuxWindowId': '@3',
      'notificationTap': 't1',
    });

    final hostOnly = Uri.parse(
      buildPushNotificationTerminalLocation(
        const PushNavigationTarget(hostId: 4, kind: PushEventKind.finished),
        notificationTapId: 't2',
      ),
    );
    expect(hostOnly.queryParameters, {'notificationTap': 't2'});
  });

  testWidgets('without push support the bridge is inert', (tester) async {
    final (gateway, controller, _) = await _pump(tester, available: false);
    expect(gateway.messages.hasListener, isFalse);
    expect(gateway.opened.hasListener, isFalse);
    expect(controller.visibility, isEmpty);
  });

  testWidgets('a tap opens the host window above Connections', (tester) async {
    final (gateway, controller, router) = await _pump(tester, target: target);
    expect(controller.visibility.last, (true, null));

    gateway.opened.add(_message);
    await tester.pumpAndSettle();

    expect(find.textContaining('terminal /terminal/4?'), findsOneWidget);
    expect(router.state.uri.queryParameters['tmuxWindowId'], '@3');
    expect(controller.visibility.last, (true, 4));
    // The route names the connection, so presence is per connection.
    expect(controller.connections.last, 21);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('home connections'), findsOneWidget);
  });

  testWidgets('a cold-start tap is routed once the app is ready', (
    tester,
  ) async {
    await _pump(tester, initial: _message, target: target);
    expect(find.textContaining('terminal /terminal/4?'), findsOneWidget);
  });

  testWidgets('a tap delivered as both initial and opened opens once', (
    tester,
  ) async {
    // When FCM started the process just before the tap, Android reports it
    // through getInitialMessage and onMessageOpenedApp. Opening it twice
    // built two terminals; the first was replaced but had already opened a
    // second connection to the host.
    _terminalTaps.clear();
    final (gateway, _, _) = await _pump(
      tester,
      initial: _message,
      target: target,
    );
    gateway.opened.add(_message);
    await tester.pumpAndSettle();
    expect(_terminalTaps, hasLength(1));

    // A different message is a different tap.
    gateway.opened.add(const PushRemoteMessage(data: {'v': '1', 'p': 'next'}));
    await tester.pumpAndSettle();
    expect(_terminalTaps, hasLength(2));
    expect(find.textContaining('terminal /terminal/4?'), findsOneWidget);
  });

  testWidgets('watching follows the router the app rebuilds', (tester) async {
    final gateway = _Gateway();
    addTearDown(gateway.close);
    final controller = _Controller();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushNotificationsAvailableProvider.overrideWithValue(true),
          pushMessagingGatewayProvider.overrideWithValue(gateway),
          pushNotificationControllerProvider.overrideWith(() => controller),
          routerProvider.overrideWith((ref) => ref.watch(_routerHolder)),
          authStateProvider.overrideWith(_UnlockedAuth.new),
          hostNotificationPrefsReaderProvider.overrideWithValue(
            (_) async => const HostNotificationPrefs(),
          ),
        ],
        child: PushNotificationBridge(
          child: Consumer(
            builder: (context, ref, _) =>
                MaterialApp.router(routerConfig: ref.watch(routerProvider)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Auth transitions while the app starts replace the router. A bridge
    // still listening to the first one never saw a terminal, so every host
    // was told no one was watching.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PushNotificationBridge)),
    );
    container.read(_routerHolder.notifier).rebuild();
    await tester.pumpAndSettle();
    unawaited(
      container.read(routerProvider).push('/terminal/4?connectionId=21'),
    );
    await tester.pumpAndSettle();

    expect(controller.visibility.last, (true, 4));
    expect(controller.connections.last, 21);
  });

  testWidgets('an unreadable tap opens Connections', (tester) async {
    final (gateway, _, _) = await _pump(tester);
    gateway.opened.add(_message);
    await tester.pumpAndSettle();
    expect(find.text('home connections'), findsOneWidget);
  });

  testWidgets('a foreground push offers to open it', (tester) async {
    final (gateway, _, _) = await _pump(tester, target: target);
    gateway.messages.add(_message);
    await tester.pumpAndSettle();

    expect(
      find.text(pushForegroundMessage(PushEventKind.permission)),
      findsOneWidget,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('terminal /terminal/4?'), findsOneWidget);
  });

  testWidgets('a foreground push of a kind the host turned off is dropped', (
    tester,
  ) async {
    final (gateway, _, _) = await _pump(
      tester,
      target: target,
      prefs: const HostNotificationPrefs(agentAttention: false),
    );
    gateway.messages.add(_message);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a foreground program notification follows the app-wide '
      'switch', (tester) async {
    const notice = PushNavigationTarget(
      hostId: 4,
      kind: PushEventKind.alert,
      sessionName: 'main',
      windowId: '@3',
      alertCategories: {'notice'},
    );
    for (final enabled in [true, false]) {
      final (gateway, _, _) = await _pump(
        tester,
        target: notice,
        terminalNotifications: enabled,
      );
      gateway.messages.add(_message);
      await tester.pumpAndSettle();
      expect(
        find.byType(SnackBar),
        enabled ? findsOneWidget : findsNothing,
        reason: 'app-wide switch on: $enabled',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a tap that started a new activity opens when it resumes', (
    tester,
  ) async {
    final notifications = _ActivityNotifications();
    await _pump(tester, target: target, notifications: notifications);
    expect(find.textContaining('terminal /terminal/4?'), findsNothing);

    notifications.activityPayload = 'sealed';
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('terminal /terminal/4?'), findsOneWidget);
  });

  testWidgets('a foreground push for what is on screen is dropped', (
    tester,
  ) async {
    final (gateway, controller, _) = await _pump(tester, target: target);
    controller.suppress = true;
    gateway.messages.add(_message);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('backgrounding reports the app as not watching', (tester) async {
    final (_, controller, _) = await _pump(tester, target: target);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(controller.visibility.last, (false, null));
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(controller.visibility.last.$1, isTrue);
  });
}
