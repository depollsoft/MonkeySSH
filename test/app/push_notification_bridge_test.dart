import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/app/push_notification_bridge.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';

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

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) =>
          Scaffold(body: Text('home ${state.uri.queryParameters['tab']}')),
    ),
    GoRoute(
      path: '/terminal/:hostId',
      builder: (context, state) =>
          Scaffold(body: Text('terminal ${state.uri}')),
    ),
  ],
);

Future<(_Gateway, _Controller, GoRouter)> _pump(
  WidgetTester tester, {
  bool available = true,
  PushRemoteMessage? initial,
  PushNavigationTarget? target,
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
