import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/app/notification_navigation.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';

void main() {
  testWidgets('scheduler holds locked taps and delivers latest after unlock', (
    tester,
  ) async {
    var unlocked = false;
    final opened = <String>[];
    final queue =
        NotificationNavigationScheduler<String>(
            canNavigate: () => unlocked,
            open: opened.add,
          )
          ..add('first')
          ..add('latest');
    await tester.pump();
    expect(opened, isEmpty);
    unlocked = true;
    queue
      ..flush()
      ..flush();
    await tester.pump();
    expect(opened, ['latest']);
  });

  testWidgets('scheduler rechecks lock and disposal before navigation', (
    tester,
  ) async {
    var mounted = true;
    var unlocked = true;
    final opened = <String>[];
    final queue = NotificationNavigationScheduler<String>(
      canNavigate: () => mounted && unlocked,
      open: opened.add,
    )..add('locked before frame');
    unlocked = false;
    await tester.pump();
    expect(opened, isEmpty);
    unlocked = true;
    queue.flush();
    mounted = false;
    await tester.pump();
    expect(opened, isEmpty);
  });

  testWidgets('scheduler retains independent notification types', (
    tester,
  ) async {
    final opened = <String>[];
    final terminal = NotificationNavigationScheduler<String>(
      canNavigate: () => true,
      open: opened.add,
    );
    final acp = NotificationNavigationScheduler<int>(
      canNavigate: () => true,
      open: (id) => opened.add('acp:$id'),
    );
    terminal.add('terminal');
    acp.add(7);
    await tester.pump();
    expect(opened, ['terminal', 'acp:7']);
  });

  testWidgets('tmux alert opens terminal above the connections screen', (
    tester,
  ) async {
    final terminalLocations = <String>[];
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Text('home:${state.uri.queryParameters['tab'] ?? 'hosts'}'),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/terminal/:hostId',
          builder: (context, state) {
            terminalLocations.add(state.uri.toString());
            return Scaffold(
              body: Text('terminal:${state.pathParameters['hostId']}'),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('settings'), findsOneWidget);

    openTmuxAlertNotificationStack(
      router: router,
      payload: const TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'work',
        windowIndex: 5,
        windowId: '@9',
      ),
      notificationTapId: 'tap-1',
    );
    await tester.pumpAndSettle();

    expect(find.text('terminal:12'), findsOneWidget);
    expect(router.canPop(), isTrue);
    expect(
      terminalLocations.single,
      '/terminal/12?connectionId=34&tmuxSession=work&tmuxWindow=5&tmuxWindowId=%409&notificationTap=tap-1',
    );

    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('home:connections'), findsOneWidget);
    expect(find.text('settings'), findsNothing);
  });

  for (final kind in AcpNotificationKind.values) {
    testWidgets('ACP $kind opens its terminal above connections on every tap', (
      tester,
    ) async {
      final locations = <Uri>[];
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Text('home:${state.uri.queryParameters['tab'] ?? 'hosts'}'),
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const Scaffold(body: Text('settings')),
          ),
          GoRoute(
            path: '/terminal/:hostId',
            builder: (context, state) {
              locations.add(state.uri);
              return Scaffold(
                body: Text('terminal:${state.pathParameters['hostId']}'),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      for (final tap in ['first', 'repeat']) {
        openAcpNotificationStack(
          router: router,
          payload: AcpNotificationPayload(
            kind: kind,
            hostId: 7,
            providerId: 'builtin:copilot-cli',
            bridgeId: 'bridge-1',
            acpSessionId: 'session-1',
          ),
          notificationTapId: tap,
        );
        await tester.pumpAndSettle();
        expect(find.text('terminal:7'), findsOneWidget);
        expect(locations.last.queryParameters, {
          'p': 'builtin:copilot-cli',
          'b': 'bridge-1',
          's': 'session-1',
          'notificationTap': tap,
        });
        expect(router.canPop(), isTrue);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('home:connections'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });
  }

  testWidgets('terminal notification opens terminal above connections', (
    tester,
  ) async {
    final terminalLocations = <String>[];
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Text('home:${state.uri.queryParameters['tab'] ?? 'hosts'}'),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/terminal/:hostId',
          builder: (context, state) {
            terminalLocations.add(state.uri.toString());
            return Scaffold(
              body: Text('terminal:${state.pathParameters['hostId']}'),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openTerminalNotificationStack(
      router: router,
      payload: const TerminalNotificationPayload(hostId: 7, connectionId: 21),
      notificationTapId: 'tap-2',
    );
    await tester.pumpAndSettle();

    expect(find.text('terminal:7'), findsOneWidget);
    expect(router.canPop(), isTrue);
    expect(
      terminalLocations.single,
      '/terminal/7?connectionId=21&notificationTap=tap-2',
    );

    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('home:connections'), findsOneWidget);
  });
}
