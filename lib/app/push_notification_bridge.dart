import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/services/auth_service.dart';
import '../domain/services/host_notification_prefs_reader.dart';
import '../domain/services/push/push_event.dart';
import '../domain/services/push/push_messaging_gateway.dart';
import '../domain/services/push/push_notification_service.dart';
import 'notification_navigation.dart';
import 'router.dart';

final _terminalPathPattern = RegExp(r'^/terminal/(\d+)$');

/// Builds the terminal location a push notification tap opens.
///
/// A target that names a window opens that MonkeyMux session and selects the
/// window, which shows a native agent window as its chat. The URL carries the
/// host and connection ids, the MonkeyMux session name and the window id; it
/// stays inside the app's router and is never logged.
String buildPushNotificationTerminalLocation(
  PushNavigationTarget target, {
  required String notificationTapId,
}) => Uri(
  path: '/terminal/${target.hostId}',
  queryParameters: <String, String>{
    if (target.connectionId case final int connectionId)
      'connectionId': '$connectionId',
    if (target.hasWindow) ...<String, String>{
      'tmuxSession': target.sessionName!,
      // The id selects the window; the route still requires an index.
      'tmuxWindow': '0',
      'tmuxWindowId': target.windowId!,
    },
    'notificationTap': notificationTapId,
  },
).toString();

/// Opens a push notification with Connections beneath the terminal, matching
/// manual navigation. A test notification, or one that could not be read,
/// only opens Connections.
void openPushNotificationStack({
  required GoRouter router,
  required PushNavigationTarget? target,
  required String notificationTapId,
}) {
  router.go(buildTmuxAlertHomeLocation());
  if (target == null || target.kind == PushEventKind.test) return;
  unawaited(
    router.push<void>(
      buildPushNotificationTerminalLocation(
        target,
        notificationTapId: notificationTapId,
      ),
    ),
  );
}

/// Snackbar text for a push that arrived while the app was open.
String pushForegroundMessage(PushEventKind kind) => switch (kind) {
  PushEventKind.permission => 'An agent is waiting for your approval.',
  PushEventKind.input => 'An agent is waiting for your answer.',
  PushEventKind.finished => 'An agent finished its turn.',
  PushEventKind.alert => 'A terminal window wants your attention.',
  PushEventKind.test => 'Test notification received. Push is working.',
};

@immutable
class _PushTap {
  const _PushTap(this.target);

  final PushNavigationTarget? target;
}

/// Wires Firebase push messages to navigation and reports app visibility to
/// the push controller. Does nothing in builds without push support.
class PushNotificationBridge extends ConsumerStatefulWidget {
  /// Creates the bridge around [child].
  const PushNotificationBridge({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<PushNotificationBridge> createState() =>
      _PushNotificationBridgeState();
}

class _PushNotificationBridgeState
    extends ConsumerState<PushNotificationBridge> {
  AppLifecycleListener? _lifecycle;
  StreamSubscription<PushRemoteMessage>? _foregroundMessages;
  StreamSubscription<PushRemoteMessage>? _openedMessages;
  ProviderSubscription<AuthState>? _authSubscription;
  ProviderSubscription<GoRouter>? _routerSubscription;
  GoRouter? _router;
  bool _active = false;
  bool _foreground = true;

  /// Payloads of the taps already opened. When FCM started the process just
  /// before the tap, Android delivers that tap through both
  /// `onMessageOpenedApp` and `getInitialMessage`, and opening it twice
  /// stacked two terminals that each connected to the host. A payload is
  /// unique to its message (fresh key and nonce), so it identifies the tap.
  final _openedPayloads = <String>{};

  late final _navigation = NotificationNavigationScheduler<_PushTap>(
    canNavigate: () {
      final auth = ref.read(authStateProvider);
      return mounted && auth != AuthState.unknown && auth != AuthState.locked;
    },
    open: (tap) => openPushNotificationStack(
      router: ref.read(routerProvider),
      target: tap.target,
      notificationTapId: 'push-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );

  @override
  void initState() {
    super.initState();
    if (!ref.read(pushNotificationsAvailableProvider)) return;
    _active = true;
    _lifecycle = AppLifecycleListener(onStateChange: _handleLifecycle);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    // Builds the controller, which loads settings and starts host sync.
    ref.read(pushNotificationControllerProvider);
    final gateway = ref.read(pushMessagingGatewayProvider);
    _foregroundMessages = gateway.onMessage.listen(_handleForegroundMessage);
    _openedMessages = gateway.onMessageOpenedApp.listen(_handleOpenedMessage);
    unawaited(_handleInitialMessage(gateway));
    // The router is rebuilt on auth transitions, which happen while the app
    // starts. Following only the first one left presence on a discarded
    // router whose location stayed `/`, so no device ever reported watching
    // a terminal and hosts pushed alerts for the window on screen.
    _routerSubscription = ref.listenManual<GoRouter>(
      routerProvider,
      (previous, next) => _followRouter(next, report: previous != null),
      fireImmediately: true,
    );
    _authSubscription = ref.listenManual<AuthState>(
      authStateProvider,
      (_, _) => _navigation.flush(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportVisibility());
  }

  @override
  void dispose() {
    if (_active) {
      _lifecycle?.dispose();
      _routerSubscription?.close();
      _router?.routerDelegate.removeListener(_reportVisibility);
      unawaited(_foregroundMessages?.cancel());
      unawaited(_openedMessages?.cancel());
      _authSubscription?.close();
    }
    super.dispose();
  }

  /// Moves the visibility listener to [router], the one the app now shows.
  void _followRouter(GoRouter router, {required bool report}) {
    if (identical(router, _router)) return;
    _router?.routerDelegate.removeListener(_reportVisibility);
    router.routerDelegate.addListener(_reportVisibility);
    _router = router;
    if (report) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportVisibility());
    }
  }

  void _handleLifecycle(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    if (foreground == _foreground) return;
    _foreground = foreground;
    _reportVisibility();
  }

  /// The host and, when the route names it, the connection whose terminal
  /// is on top.
  ({int? hostId, int? connectionId}) _viewedTerminal() {
    final router = _router;
    if (router == null) return (hostId: null, connectionId: null);
    try {
      final uri = router.state.uri;
      final match = _terminalPathPattern.firstMatch(uri.path);
      if (match == null) return (hostId: null, connectionId: null);
      return (
        hostId: int.tryParse(match.group(1)!),
        connectionId: int.tryParse(uri.queryParameters['connectionId'] ?? ''),
      );
    } on Object {
      // The router has no configuration yet.
      return (hostId: null, connectionId: null);
    }
  }

  void _reportVisibility() {
    if (!mounted) return;
    final viewed = _foreground
        ? _viewedTerminal()
        : (hostId: null, connectionId: null);
    ref
        .read(pushNotificationControllerProvider.notifier)
        .reportVisibility(
          foreground: _foreground,
          viewedHostId: viewed.hostId,
          viewedConnectionId: viewed.connectionId,
        );
  }

  Future<void> _handleInitialMessage(PushMessagingGateway gateway) async {
    final PushRemoteMessage? message;
    try {
      message = await gateway.getInitialMessage();
    } on Object {
      return;
    }
    if (message != null) await _handleOpenedMessage(message);
  }

  Future<void> _handleOpenedMessage(PushRemoteMessage message) async {
    final payload = message.encryptedPayload;
    if (payload == null || !_openedPayloads.add(payload)) return;
    if (_openedPayloads.length > 32) {
      _openedPayloads.remove(_openedPayloads.first);
    }
    final target = await ref
        .read(pushNotificationControllerProvider.notifier)
        .resolve(message);
    if (!mounted) return;
    _navigation.add(_PushTap(target));
  }

  Future<void> _handleForegroundMessage(PushRemoteMessage message) async {
    if (message.encryptedPayload == null) return;
    final controller = ref.read(pushNotificationControllerProvider.notifier);
    final target = await controller.resolve(message);
    if (!mounted || target == null) return;
    if (controller.shouldSuppressInForeground(target)) return;
    // A registration can lag a change to the host's kinds until the host is
    // reached again; what the user turned off does not show here either.
    final prefs = await ref.read(hostNotificationPrefsReaderProvider)(
      target.hostId,
    );
    if (!mounted || !pushKindAllowedByHost(target.kind, prefs)) return;
    final navigatorContext = ref
        .read(routerProvider)
        .routerDelegate
        .navigatorKey
        .currentContext;
    if (navigatorContext == null || !navigatorContext.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(navigatorContext);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(pushForegroundMessage(target.kind)),
        action: target.kind == PushEventKind.test
            ? null
            : SnackBarAction(
                label: 'Open',
                onPressed: () => _navigation.add(_PushTap(target)),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
