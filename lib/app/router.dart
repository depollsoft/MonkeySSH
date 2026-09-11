import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/monetization.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/local_notification_service.dart';
import '../domain/services/port_forward_browser_service.dart';
import '../domain/services/telemetry_service.dart';
import '../presentation/screens/agent_chat_screen.dart';
import '../presentation/screens/app_review_demo_screen.dart';
import '../presentation/screens/auth_setup_screen.dart';
import '../presentation/screens/home_screen.dart';
import '../presentation/screens/host_edit_screen.dart';
import '../presentation/screens/hosts_screen.dart';
import '../presentation/screens/key_add_screen.dart';
import '../presentation/screens/keys_screen.dart';
import '../presentation/screens/lock_screen.dart';
import '../presentation/screens/port_forward_browser_screen.dart';
import '../presentation/screens/port_forward_edit_screen.dart';
import '../presentation/screens/port_forwards_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/sftp_screen.dart';
import '../presentation/screens/snippet_edit_screen.dart';
import '../presentation/screens/snippets_screen.dart';
import '../presentation/screens/terminal_screen.dart';
import '../presentation/screens/upgrade_screen.dart';
import 'keyboard_dismiss_route_observer.dart';
import 'routes.dart';
import 'telemetry_route_observer.dart';

/// Root navigator key used for global modal prompts.
final appNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'appNavigator');

/// Provider for the app router.
final routerProvider = Provider<GoRouter>((ref) {
  // Keep this watch: rebuilding the router on auth transitions intentionally
  // clears protected navigation history when the app locks.
  // TODO(router): only switch to a persistent GoRouter/refreshListenable after
  // tests prove locked routes cannot be revealed via back navigation and
  // notification deep-link navigation remains compatible.
  final authState = ref.watch(authStateProvider);
  final telemetryService = ref.watch(telemetryServiceProvider);

  return GoRouter(
    navigatorKey: appNavigatorKey,
    initialLocation: '/',
    observers: [
      TelemetryRouteObserver(telemetryService: telemetryService),
      KeyboardDismissRouteObserver(),
    ],
    redirect: (context, state) => redirectForAuthState(
      authState: authState,
      matchedLocation: state.matchedLocation,
    ),
    routes: [
      GoRoute(
        path: '/',
        name: Routes.home,
        builder: (context, state) => HomeScreen(
          initialTab: _homeScreenTabFromRoute(state.uri.queryParameters['tab']),
        ),
      ),
      GoRoute(
        path: '/lock',
        name: 'lock',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: '/auth-setup',
        name: Routes.authSetup,
        builder: (context, state) => const AuthSetupScreen(),
      ),
      GoRoute(
        path: '/terminal/:hostId',
        name: Routes.terminal,
        pageBuilder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          final connectionId = int.tryParse(
            state.uri.queryParameters['connectionId'] ?? '',
          );
          final initialTmuxSessionName =
              state.uri.queryParameters['tmuxSession'];
          final initialTmuxWindowIndex = int.tryParse(
            state.uri.queryParameters['tmuxWindow'] ?? '',
          );
          final initialTmuxWindowId = state.uri.queryParameters['tmuxWindowId'];
          final initiallyExpandTmuxWindows =
              state.uri.queryParameters['expandTmux'] == '1';
          final initiallyShowKeyboard =
              state.uri.queryParameters['showKeyboard'] == '1';
          final pasteDemoImage =
              state.uri.queryParameters['pasteDemoImage'] == '1';
          if (hostId == null) {
            return _buildTerminalPage(
              state: state,
              child: const Scaffold(
                body: Center(child: Text('Invalid host ID')),
              ),
            );
          }
          return _buildTerminalPage(
            state: state,
            child: TerminalScreen(
              key: ValueKey<Object>(
                Object.hash(
                  hostId,
                  connectionId,
                  initialTmuxSessionName,
                  initialTmuxWindowIndex,
                  initialTmuxWindowId,
                  state.uri.queryParameters['notificationTap'],
                  initiallyExpandTmuxWindows,
                  initiallyShowKeyboard,
                  pasteDemoImage,
                ),
              ),
              hostId: hostId,
              connectionId: connectionId,
              initialTmuxSessionName: initialTmuxSessionName,
              initialTmuxWindowIndex: initialTmuxWindowIndex,
              initialTmuxWindowId: initialTmuxWindowId,
              initialTmuxWindowRequiresVisibleSession:
                  state.uri.queryParameters['notificationTap'] != null,
              initiallyExpandTmuxWindows: initiallyExpandTmuxWindows,
              initiallyShowKeyboard: initiallyShowKeyboard,
              pasteDemoImage: pasteDemoImage,
            ),
          );
        },
      ),
      GoRoute(
        path: '/hosts',
        name: Routes.hosts,
        builder: (context, state) => const HostsScreen(),
      ),
      GoRoute(
        path: '/hosts/add',
        name: 'host-add',
        builder: (context, state) =>
            HostEditScreen(initialSshUrl: state.uri.queryParameters['sshUrl']),
      ),
      GoRoute(
        path: '/hosts/edit/:hostId',
        name: 'host-edit',
        builder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          return HostEditScreen(hostId: hostId);
        },
      ),
      GoRoute(
        path: '/keys',
        name: Routes.keys,
        builder: (context, state) => const KeysScreen(),
      ),
      GoRoute(
        path: '/keys/add',
        name: 'key-add',
        builder: (context, state) => KeyAddScreen(
          initialTabIndex: state.uri.queryParameters['tab'] == 'import' ? 1 : 0,
        ),
      ),
      GoRoute(
        path: '/sftp/:hostId',
        name: Routes.sftp,
        pageBuilder: (context, state) {
          final hostId = int.tryParse(state.pathParameters['hostId'] ?? '');
          final connectionId = int.tryParse(
            state.uri.queryParameters['connectionId'] ?? '',
          );
          final initialPath = state.uri.queryParameters['path'];
          final initialWorkingDirectory = state.uri.queryParameters['cwd'];
          final connectionStartDirectory =
              state.uri.queryParameters['connectionCwd'];
          final tmuxPaneDirectory = state.uri.queryParameters['tmuxCwd'];
          if (hostId == null) {
            return _buildSlideUpPage<String>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(child: Text('Invalid host ID')),
              ),
            );
          }
          return _buildSlideUpPage<String>(
            key: state.pageKey,
            child: SftpScreen(
              hostId: hostId,
              connectionId: connectionId,
              initialPath: initialPath,
              initialWorkingDirectory: initialWorkingDirectory,
              connectionStartDirectory: connectionStartDirectory,
              tmuxPaneDirectory: tmuxPaneDirectory,
              showCloseButton: true,
            ),
          );
        },
      ),
      GoRoute(
        path: '/snippets',
        name: Routes.snippets,
        builder: (context, state) => const SnippetsScreen(),
      ),
      GoRoute(
        path: acpAgentChatRoutePath,
        name: Routes.agentChat,
        pageBuilder: (context, state) {
          final hostId = int.tryParse(
            state.uri.queryParameters[acpAgentChatHostQueryKey] ?? '',
          );
          final providerId =
              state.uri.queryParameters[acpAgentChatProviderQueryKey];
          final bridgeId =
              state.uri.queryParameters[acpAgentChatBridgeQueryKey];
          final acpSessionId =
              state.uri.queryParameters[acpAgentChatSessionQueryKey];
          if (hostId == null ||
              providerId == null ||
              providerId.isEmpty ||
              bridgeId == null ||
              bridgeId.isEmpty ||
              acpSessionId == null ||
              acpSessionId.isEmpty) {
            return _buildSlideUpPage<void>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(child: Text('Invalid agent session')),
              ),
            );
          }
          return _buildSlideUpPage<void>(
            key: state.pageKey,
            child: AgentChatScreen(
              key: ValueKey<String>(
                'agent-chat:$hostId:$providerId:$bridgeId:$acpSessionId',
              ),
              hostId: hostId,
              providerId: providerId,
              bridgeId: bridgeId,
              acpSessionId: acpSessionId,
            ),
          );
        },
      ),
      GoRoute(
        path: '/snippets/add',
        name: Routes.snippetAdd,
        builder: (context, state) {
          final extra = state.extra;
          final prefill = extra is SnippetEditPrefill
              ? extra
              : const SnippetEditPrefill();
          return SnippetEditScreen(prefill: prefill);
        },
      ),
      GoRoute(
        path: '/snippets/edit/:snippetId',
        name: Routes.snippetEdit,
        builder: (context, state) {
          final snippetId = int.tryParse(
            state.pathParameters['snippetId'] ?? '',
          );
          return SnippetEditScreen(snippetId: snippetId);
        },
      ),
      GoRoute(
        path: '/port-forwards',
        name: Routes.portForwards,
        builder: (context, state) => const PortForwardsScreen(),
      ),
      GoRoute(
        path: '/port-forwards/add',
        name: 'port-forward-add',
        builder: (context, state) => const PortForwardEditScreen(),
      ),
      GoRoute(
        path: '/port-forwards/edit/:id',
        name: 'port-forward-edit',
        builder: (context, state) {
          final portForwardId = int.tryParse(state.pathParameters['id'] ?? '');
          return PortForwardEditScreen(portForwardId: portForwardId);
        },
      ),
      GoRoute(
        path: '/port-forwards/browser',
        name: Routes.portForwardBrowser,
        pageBuilder: (context, state) {
          if (!isPortForwardBrowserSupported()) {
            return _buildSlideUpPage<String>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(
                  child: Text('In-app browser is not supported here.'),
                ),
              ),
            );
          }
          final launch = _portForwardBrowserLaunchFromRouteState(state);
          if (launch == null) {
            return _buildSlideUpPage<String>(
              key: state.pageKey,
              child: const Scaffold(
                body: Center(child: Text('Invalid port-forward browser URL')),
              ),
            );
          }
          return _buildSlideUpPage<String>(
            key: state.pageKey,
            child: PortForwardBrowserScreen(
              initialTabs: launch.tabs,
              initialTabIndex: launch.selectedIndex,
            ),
          );
        },
      ),
      GoRoute(
        path: '/settings',
        name: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/settings/app-review-demo',
        name: Routes.appReviewDemo,
        builder: (context, state) => const AppReviewDemoScreen(),
      ),
      GoRoute(
        path: '/upgrade',
        name: Routes.upgrade,
        builder: (context, state) {
          final featureName = state.uri.queryParameters['feature'];
          final feature = MonetizationFeature.values.firstWhereOrNull(
            (value) => value.name == featureName,
          );
          return UpgradeScreen(
            feature: feature,
            blockedAction: state.uri.queryParameters['action'],
            blockedOutcome: state.uri.queryParameters['outcome'],
          );
        },
      ),
    ],
  );
});

PortForwardBrowserLaunch? _portForwardBrowserLaunchFromRouteState(
  GoRouterState state,
) {
  final extra = state.extra;
  if (extra is PortForwardBrowserLaunch &&
      _portForwardBrowserLaunchIsValid(extra)) {
    return extra;
  }

  final uri = Uri.tryParse(state.uri.queryParameters['url'] ?? '');
  if (uri == null || !isPortForwardBrowserEntryUri(uri)) {
    return null;
  }

  return PortForwardBrowserLaunch(
    tabs: [
      PortForwardBrowserInitialTab(
        uri: normalizePortForwardBrowserUri(uri),
        title: state.uri.queryParameters['title'],
      ),
    ],
  );
}

bool _portForwardBrowserLaunchIsValid(PortForwardBrowserLaunch launch) =>
    launch.tabs.isNotEmpty &&
    launch.selectedIndex >= 0 &&
    launch.selectedIndex < launch.tabs.length &&
    launch.tabs.every(
      (tab) =>
          isPortForwardBrowserEntryUri(tab.uri) &&
          (tab.sourceUri == null ||
              isPortForwardBrowserEntryUri(tab.sourceUri!)) &&
          (tab.fallbackUri == null ||
              isPortForwardBrowserEntryUri(tab.fallbackUri!)),
    );

HomeScreenTab _homeScreenTabFromRoute(String? tab) => switch (tab) {
  'connections' => HomeScreenTab.connections,
  'keys' => HomeScreenTab.keys,
  'snippets' => HomeScreenTab.snippets,
  _ => HomeScreenTab.hosts,
};

_LiveMaterialPage<void> _buildTerminalPage({
  required GoRouterState state,
  required Widget child,
}) => _LiveMaterialPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: state.pageKey.value,
  child: child,
);

class _LiveMaterialPage<T> extends Page<T> {
  const _LiveMaterialPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      _LiveMaterialPageRoute<T>(page: this);
}

class _LiveMaterialPageRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _LiveMaterialPageRoute({required _LiveMaterialPage<T> page})
    : super(settings: page, allowSnapshotting: false);

  _LiveMaterialPage<T> get _page => settings as _LiveMaterialPage<T>;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  String get debugLabel => '${super.debugLabel}(${settings.name})';
}

CustomTransitionPage<T> _buildSlideUpPage<T>({
  required LocalKey key,
  required Widget child,
}) => CustomTransitionPage<T>(
  key: key,
  fullscreenDialog: true,
  transitionDuration: const Duration(milliseconds: 280),
  reverseTransitionDuration: const Duration(milliseconds: 220),
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: child,
      ),
  child: child,
);

/// Computes the route redirect for the given authentication state.
String? redirectForAuthState({
  required AuthState authState,
  required String matchedLocation,
}) {
  final isBlocked =
      authState == AuthState.unknown || authState == AuthState.locked;
  final isNotConfigured = authState == AuthState.notConfigured;
  final isOnLockScreen = matchedLocation == '/lock';
  final isOnSetupScreen = matchedLocation == '/auth-setup';

  if (isBlocked) {
    return isOnLockScreen ? null : '/lock';
  }

  if (isNotConfigured && isOnLockScreen) {
    return '/';
  }

  if (!isNotConfigured && (isOnLockScreen || isOnSetupScreen)) {
    return '/';
  }

  return null;
}
