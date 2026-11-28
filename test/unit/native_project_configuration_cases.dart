// ignore_for_file: public_member_api_docs

import 'android_ssh_service_crash_regression_cases.dart';
import 'biometric_platform_configuration_cases.dart';
import 'browser_cleartext_platform_configuration_cases.dart';
import 'permission_platform_configuration_cases.dart';
import 'socks_browser_webkit_start_cases.dart';
import 'wifi_platform_configuration_cases.dart';

/// Registers tests from native_project_configuration_test.dart.
void registerUnitNativeProjectConfigurationTests() {
  registerAndroidSshServiceCrashRegressionTests();
  registerBiometricPlatformConfigurationTests();
  registerBrowserCleartextPlatformConfigurationTests();
  registerPermissionPlatformConfigurationTests();
  registerSocksBrowserWebKitStartTests();
  registerWifiPlatformConfigurationTests();
}
