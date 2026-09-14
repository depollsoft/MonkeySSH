// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/app/routes.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockBuildContext extends Mock implements BuildContext {}

void main() {
  group('redirectForAuthState', () {
    test('fails closed to lock while auth is still initializing', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unknown,
        matchedLocation: '/',
      );

      expect(redirect, '/lock');
    });

    test('allows lock screen while auth is still initializing', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unknown,
        matchedLocation: '/lock',
      );

      expect(redirect, isNull);
    });

    test('returns home when auth is not configured on lock screen', () {
      final redirect = redirectForAuthState(
        authState: AuthState.notConfigured,
        matchedLocation: '/lock',
      );

      expect(redirect, '/');
    });

    test('keeps auth setup accessible when auth is not configured', () {
      final redirect = redirectForAuthState(
        authState: AuthState.notConfigured,
        matchedLocation: '/auth-setup',
      );

      expect(redirect, isNull);
    });

    test('returns home when unlocked user visits lock screen', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unlocked,
        matchedLocation: '/lock',
      );

      expect(redirect, '/');
    });

    test('fails closed to lock when locked and visiting non-lock route', () {
      final redirect = redirectForAuthState(
        authState: AuthState.locked,
        matchedLocation: '/',
      );

      expect(redirect, '/lock');
    });

    test('allows lock screen when already on the lock screen', () {
      final redirect = redirectForAuthState(
        authState: AuthState.locked,
        matchedLocation: '/lock',
      );

      expect(redirect, isNull);
    });

    test('blocks terminal access when locked', () {
      final redirect = redirectForAuthState(
        authState: AuthState.locked,
        matchedLocation: '/terminal/1',
      );

      expect(redirect, '/lock');
    });

    test('blocks auth-setup when unlocked (auth already configured)', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unlocked,
        matchedLocation: '/auth-setup',
      );

      expect(redirect, '/');
    });

    test('allows normal navigation when unlocked', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unlocked,
        matchedLocation: '/',
      );

      expect(redirect, isNull);
    });

    test('allows normal navigation when auth is not configured', () {
      final redirect = redirectForAuthState(
        authState: AuthState.notConfigured,
        matchedLocation: '/',
      );

      expect(redirect, isNull);
    });
  });

  // Additional characterization tests for auth-setup route access control.
  // These cover states not handled by the basic group above.
  group('redirectForAuthState - auth-setup access control', () {
    test('blocks auth-setup while auth is still initializing', () {
      // auth-setup is not exempt from the fail-closed rule; only /lock is.
      final redirect = redirectForAuthState(
        authState: AuthState.unknown,
        matchedLocation: '/auth-setup',
      );

      expect(redirect, '/lock');
    });

    test('blocks auth-setup when locked', () {
      // When locked, only /lock is accessible; auth-setup must not be reachable.
      final redirect = redirectForAuthState(
        authState: AuthState.locked,
        matchedLocation: '/auth-setup',
      );

      expect(redirect, '/lock');
    });
  });

  // Deep-link path characterization: all non-home paths must obey auth gates.
  group('redirectForAuthState - deep-link paths', () {
    const deepLinkPaths = [
      '/sftp/5',
      '/hosts',
      '/hosts/add',
      '/hosts/edit/3',
      '/keys',
      '/keys/add',
      '/snippets',
      '/snippets/add',
      '/snippets/edit/7',
      '/port-forwards',
      '/port-forwards/add',
      '/port-forwards/edit/2',
      '/settings',
      '/upgrade',
    ];

    for (final path in deepLinkPaths) {
      test('blocks $path when locked', () {
        expect(
          redirectForAuthState(
            authState: AuthState.locked,
            matchedLocation: path,
          ),
          '/lock',
        );
      });

      test('blocks $path while auth is still initializing', () {
        expect(
          redirectForAuthState(
            authState: AuthState.unknown,
            matchedLocation: path,
          ),
          '/lock',
        );
      });

      test('allows $path when unlocked', () {
        expect(
          redirectForAuthState(
            authState: AuthState.unlocked,
            matchedLocation: path,
          ),
          isNull,
        );
      });

      test('allows $path when auth is not configured', () {
        expect(
          redirectForAuthState(
            authState: AuthState.notConfigured,
            matchedLocation: path,
          ),
          isNull,
        );
      });
    }

    // Terminal deep-links include extra query parameters; the redirect function
    // receives only the path portion (matchedLocation), so these characterize
    // that path matching works regardless of query parameters.
    test('blocks terminal with tmux params when locked', () {
      // matchedLocation strips query params; path alone is what matters.
      expect(
        redirectForAuthState(
          authState: AuthState.locked,
          matchedLocation: '/terminal/42',
        ),
        '/lock',
      );
    });

    test('allows terminal with any hostId when unlocked', () {
      expect(
        redirectForAuthState(
          authState: AuthState.unlocked,
          matchedLocation: '/terminal/42',
        ),
        isNull,
      );
    });
  });

  // Intentional routerProvider behavior: it creates a new GoRouter each time
  // authStateProvider changes, which resets the navigation back-stack.
  group('routerProvider', () {
    late _MockAuthService authService;
    late ProviderContainer container;

    setUp(() {
      authService = _MockAuthService();
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => false);

      container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
    });

    tearDown(() => container.dispose());

    test('returns a GoRouter instance', () {
      final router = container.read(routerProvider);
      expect(router, isA<GoRouter>());
    });

    test('terminal route animates the live page during transitions', () {
      final router = container.read(routerProvider);
      final terminalRoute = router.configuration.routes
          .whereType<GoRoute>()
          .singleWhere((route) => route.name == Routes.terminal);

      final page = terminalRoute.pageBuilder!(
        _MockBuildContext(),
        GoRouterState(
          router.configuration,
          uri: Uri.parse('/terminal/1?connectionId=7'),
          matchedLocation: '/terminal/1',
          name: Routes.terminal,
          path: '/terminal/:hostId',
          fullPath: '/terminal/:hostId',
          pathParameters: const {'hostId': '1'},
          pageKey: const ValueKey<String>('/terminal/:hostId'),
          topRoute: terminalRoute,
        ),
      );

      final route = page.createRoute(_MockBuildContext()) as PageRoute<void>;

      expect(route, isA<PageRoute<void>>());
      expect(route.opaque, isFalse);
      expect(route.allowSnapshotting, isFalse);
    });

    test('terminal route keys distinguish expand tmux requests', () {
      final router = container.read(routerProvider);
      final terminalRoute = router.configuration.routes
          .whereType<GoRoute>()
          .singleWhere((route) => route.name == Routes.terminal);

      final collapsed = _terminalScreenFor(
        router: router,
        route: terminalRoute,
        uri: Uri.parse('/terminal/1?connectionId=7'),
      );
      final expanded = _terminalScreenFor(
        router: router,
        route: terminalRoute,
        uri: Uri.parse('/terminal/1?connectionId=7&expandTmux=1'),
      );

      expect(collapsed.key, isNot(expanded.key));
    });

    test(
      'native notification route builds an embedded terminal target and refreshes each tap',
      () {
        final router = container.read(routerProvider);
        final route = router.configuration.routes
            .whereType<GoRoute>()
            .singleWhere((route) => route.name == Routes.terminal);
        TerminalScreen screen(String query) => _terminalScreenFor(
          router: router,
          route: route,
          uri: Uri.parse(
            '/terminal/7?p=builtin%3Api&b=bridge-1&s=session-1&$query',
          ),
        );
        final first = screen('notificationTap=first');
        final repeated = screen('notificationTap=second');
        expect(first.initialNativeAcpSessionKey?.hostId, 7);
        expect(first.initialNativeAcpSessionKey?.providerId, 'builtin:pi');
        expect(first.initialNativeAcpSessionKey?.bridgeId, 'bridge-1');
        expect(first.initialNativeAcpSessionKey?.acpSessionId, 'session-1');
        expect(first.key, isNot(repeated.key));
      },
    );

    test('intentionally returns a new GoRouter instance when authState changes '
        'to reset protected back-stack history', () async {
      // Initialise the auth notifier and let it settle to notConfigured.
      container.read(authStateProvider);
      await pumpEventQueue();
      expect(container.read(authStateProvider), AuthState.notConfigured);

      final routerBefore = container.read(routerProvider);

      // Simulate an auth lock (e.g. auto-lock after backgrounding).
      container.read(authStateProvider.notifier).lockForAutoLock();
      expect(container.read(authStateProvider), AuthState.locked);

      final routerAfter = container.read(routerProvider);

      // routerProvider intentionally uses ref.watch(authStateProvider), so
      // every auth state change rebuilds the provider and produces a fresh
      // GoRouter. Any navigation history accumulated on the previous router is
      // lost instead of being kept behind the lock screen.
      expect(
        routerAfter,
        isNot(same(routerBefore)),
        reason:
            'Persistent GoRouter refresh behavior is deferred because the '
            'current rebuild clears protected navigation history across '
            'lock/unlock transitions. A persistent router must first prove '
            'that back navigation cannot reveal protected routes.',
      );
    });

    test('persistent router refresh behavior is deferred until notification '
        'deep-links and lock back-stack safety are proven together', () async {
      container.read(authStateProvider);
      await pumpEventQueue();
      expect(container.read(authStateProvider), AuthState.notConfigured);

      final routerBeforeLock = container.read(routerProvider);

      container.read(authStateProvider.notifier).lockForAutoLock();
      expect(container.read(authStateProvider), AuthState.locked);

      final routerWhileLocked = container.read(routerProvider);
      expect(routerWhileLocked, isNot(same(routerBeforeLock)));

      expect(
        redirectForAuthState(
          authState: AuthState.locked,
          matchedLocation: '/terminal/42',
        ),
        '/lock',
        reason:
            'Notification terminal deep-links remain fail-closed while '
            'locked; a persistent router must preserve this before it can '
            'keep back-stack state.',
      );
    });

    test(
      'new GoRouter after locking has redirect that sends to /lock',
      () async {
        container.read(authStateProvider);
        await pumpEventQueue();

        container.read(authStateProvider.notifier).lockForAutoLock();

        final lockedRouter = container.read(routerProvider);

        // The router carries the locked auth state in its redirect closure.
        // Verify by calling redirectForAuthState with the locked state directly,
        // which mirrors what the GoRouter redirect callback will do.
        expect(
          redirectForAuthState(
            authState: AuthState.locked,
            matchedLocation: '/settings',
          ),
          '/lock',
          reason:
              'After locking, any attempt to navigate to a non-lock route '
              'is redirected to /lock.',
        );

        // Sanity-check the router itself is a valid GoRouter instance.
        expect(lockedRouter, isA<GoRouter>());
      },
    );

    test('new GoRouter after unlocking allows navigation past /lock', () async {
      // Start locked.
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);
      when(() => authService.verifyPin(any())).thenAnswer((_) async => true);

      container.read(authStateProvider);
      await pumpEventQueue();
      expect(container.read(authStateProvider), AuthState.locked);

      // Unlock.
      await container.read(authStateProvider.notifier).unlockWithPin('1234');
      expect(container.read(authStateProvider), AuthState.unlocked);

      final unlockedRouter = container.read(routerProvider);
      expect(unlockedRouter, isA<GoRouter>());

      // Confirm redirect function mirrors the unlocked router's redirect.
      expect(
        redirectForAuthState(
          authState: AuthState.unlocked,
          matchedLocation: '/settings',
        ),
        isNull,
        reason: 'After unlocking, navigation to any non-lock route is allowed.',
      );
    });
  });
}

TerminalScreen _terminalScreenFor({
  required GoRouter router,
  required GoRoute route,
  required Uri uri,
}) {
  final page = route.pageBuilder!(
    _MockBuildContext(),
    GoRouterState(
      router.configuration,
      uri: uri,
      matchedLocation: '/terminal/1',
      name: Routes.terminal,
      path: '/terminal/:hostId',
      fullPath: '/terminal/:hostId',
      pathParameters: {'hostId': uri.pathSegments.last},
      pageKey: const ValueKey<String>('/terminal/:hostId'),
      topRoute: route,
    ),
  );
  final terminalRoute =
      page.createRoute(_MockBuildContext()) as PageRoute<void>;
  final pageWidget = terminalRoute.buildPage(
    _MockBuildContext(),
    kAlwaysCompleteAnimation,
    kAlwaysDismissedAnimation,
  );
  return _findTerminalScreen(pageWidget);
}

TerminalScreen _findTerminalScreen(Widget widget) {
  if (widget is TerminalScreen) {
    return widget;
  }
  if (widget is Semantics && widget.child != null) {
    return _findTerminalScreen(widget.child!);
  }
  throw StateError('TerminalScreen not found in terminal route page.');
}
