import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/services/telemetry_service.dart';
import 'routes.dart';

/// Navigator observer that records route-level feature usage without paths.
class TelemetryRouteObserver extends NavigatorObserver {
  /// Creates a route observer backed by [telemetryService].
  TelemetryRouteObserver({required TelemetryService telemetryService})
    : _telemetryService = telemetryService;

  final TelemetryService _telemetryService;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _recordRoute(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      _recordRoute(newRoute);
    }
  }

  void _recordRoute(Route<dynamic> route) {
    final feature = _featureForRouteName(route.settings.name);
    if (feature == null) {
      return;
    }
    unawaited(_telemetryService.logFeatureOpened(feature: feature));
  }
}

String? _featureForRouteName(String? routeName) => switch (routeName) {
  Routes.home => 'home',
  Routes.authSetup || 'lock' => 'auth',
  Routes.hosts => 'hosts',
  'host-add' || 'host-edit' => 'host_editor',
  Routes.keys => 'keys',
  'key-add' => 'key_editor',
  Routes.terminal => 'terminal',
  Routes.sftp => 'sftp',
  Routes.snippets => 'snippets',
  Routes.snippetAdd || Routes.snippetEdit => 'snippet_editor',
  Routes.portForwards => 'port_forwards',
  'port-forward-add' || 'port-forward-edit' => 'port_forward_editor',
  Routes.portForwardBrowser => 'port_forward_browser',
  Routes.settings => 'settings',
  Routes.upgrade => 'upgrade',
  _ => null,
};
