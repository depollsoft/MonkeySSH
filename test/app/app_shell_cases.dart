// ignore_for_file: public_member_api_docs

import 'app_cases.dart';
import 'auth_lifecycle_controller_cases.dart';
import 'keyboard_dismiss_route_observer_cases.dart';
import 'notification_navigation_cases.dart';
import 'router_cases.dart';
import 'theme_cases.dart';

/// Registers tests from app_shell_test.dart.
void registerAppAppShellTests() {
  registerAppTests();
  registerAuthLifecycleControllerTests();
  registerKeyboardDismissRouteObserverTests();
  registerNotificationNavigationTests();
  registerRouterTests();
  registerThemeTests();
}
