import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../domain/services/local_notification_service.dart';

const _homeTabQueryKey = 'tab';
const _connectionsTabQueryValue = 'connections';

/// Builds the home route that should sit underneath a tmux alert terminal.
String buildTmuxAlertHomeLocation() => Uri(
  path: '/',
  queryParameters: const <String, String>{
    _homeTabQueryKey: _connectionsTabQueryValue,
  },
).toString();

/// Builds the terminal route for a tmux alert notification navigation.
String buildTmuxAlertNotificationTerminalLocation(
  TmuxAlertNotificationPayload payload, {
  required String notificationTapId,
}) {
  final targetUri = Uri.parse(buildTmuxAlertTerminalLocation(payload));
  final queryParameters = Map<String, String>.from(targetUri.queryParameters)
    ..['notificationTap'] = notificationTapId;
  return targetUri.replace(queryParameters: queryParameters).toString();
}

/// Opens a tmux alert notification with the same stack as manual navigation.
void openTmuxAlertNotificationStack({
  required GoRouter router,
  required TmuxAlertNotificationPayload payload,
  required String notificationTapId,
}) {
  router.go(buildTmuxAlertHomeLocation());
  unawaited(
    router.push<void>(
      buildTmuxAlertNotificationTerminalLocation(
        payload,
        notificationTapId: notificationTapId,
      ),
    ),
  );
}

/// Opens an ACP notification with Connections beneath the native chat so
/// system and predictive Back match manual navigation.
void openAcpNotificationStack({
  required GoRouter router,
  required AcpNotificationPayload payload,
}) {
  router.go(buildTmuxAlertHomeLocation());
  unawaited(router.push<void>(buildAcpNotificationLocation(payload)));
}

/// Builds the terminal route for a terminal desktop notification navigation.
String buildTerminalNotificationNavigationLocation(
  TerminalNotificationPayload payload, {
  required String notificationTapId,
}) {
  final targetUri = Uri.parse(buildTerminalNotificationLocation(payload));
  final queryParameters = Map<String, String>.from(targetUri.queryParameters)
    ..['notificationTap'] = notificationTapId;
  return targetUri.replace(queryParameters: queryParameters).toString();
}

/// Opens a terminal desktop notification with the same stack as manual
/// navigation.
void openTerminalNotificationStack({
  required GoRouter router,
  required TerminalNotificationPayload payload,
  required String notificationTapId,
}) {
  router.go(buildTmuxAlertHomeLocation());
  unawaited(
    router.push<void>(
      buildTerminalNotificationNavigationLocation(
        payload,
        notificationTapId: notificationTapId,
      ),
    ),
  );
}

/// Retains the latest tap until navigation is allowed after a frame.
class NotificationNavigationScheduler<T extends Object> {
  /// Creates a queue for one notification policy.
  NotificationNavigationScheduler({
    required this.canNavigate,
    required this.open,
  });

  /// Whether the owner is mounted and authentication permits navigation.
  final bool Function() canNavigate;

  /// Opens this notification type's destination.
  final void Function(T payload) open;
  T? _pending;
  bool _queued = false;

  /// Replaces a pending tap and requests navigation.
  void add(T payload) {
    _pending = payload;
    flush();
  }

  /// Retries pending navigation, for example after unlocking.
  void flush() {
    if (_queued || _pending == null || !canNavigate()) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!canNavigate()) return;
      final payload = _pending;
      if (payload == null) return;
      _pending = null;
      open(payload);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
