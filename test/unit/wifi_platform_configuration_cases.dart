import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void registerWifiPlatformConfigurationTests() {
  group('wifi_platform_configuration', () {
    group('Wi-Fi SSID platform configuration', () {
      test('android declares Wi-Fi SSID permissions', () {
        final manifest = File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync();

        expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
        expect(manifest, contains('android.permission.ACCESS_COARSE_LOCATION'));
        expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
      });

      test('ios enables Wi-Fi SSID entitlement and location prompt', () {
        final entitlements = File('ios/Runner/Runner.entitlements')
            .readAsStringSync();
        final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

        expect(
          entitlements,
          contains('com.apple.developer.networking.wifi-info'),
        );
        expect(
          infoPlist,
          contains('NSLocationAlwaysAndWhenInUseUsageDescription'),
        );
        // LocationPermissionStrategy stays compiled in as long as any location
        // macro is set, and the always-key above already sets PERMISSION_LOCATION,
        // so dropping this key would not remove the strategy. It would instead
        // fail at runtime: the PermissionGroupLocationWhenInUse branch reads
        // NSLocationWhenInUseUsageDescription from the bundle before calling
        // requestWhenInUseAuthorization, and errors with MISSING_USAGE_DESCRIPTION
        // when it is absent -- which breaks Wi-Fi SSID lookup.
        expect(infoPlist, contains('NSLocationWhenInUseUsageDescription'));
        expect(infoPlist, contains('current Wi-Fi network name'));
      });
    });
  });
}
