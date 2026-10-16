import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void registerBrowserCleartextPlatformConfigurationTests() {
  group('browser_cleartext_platform_configuration', () {
    // The SOCKS browser defaults internal addresses to plain HTTP, and the
    // platforms refuse cleartext before the proxy sees the request.
    test('android lets the in-app browsers load plain HTTP on any host', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      final config = File(
        'android/app/src/main/res/xml/network_security_config.xml',
      ).readAsStringSync();

      expect(
        manifest,
        contains(
          'android:networkSecurityConfig="@xml/network_security_config"',
        ),
      );
      expect(
        config,
        matches(RegExp(r'<base-config\s+cleartextTrafficPermitted="true"')),
      );
    });

    test('ios exempts only web content from App Transport Security', () {
      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(
        infoPlist,
        matches(
          RegExp(r'<key>NSAllowsArbitraryLoadsInWebContent</key>\s*<true/>'),
        ),
      );
      // The app-wide switch would also drop ATS for native networking.
      expect(infoPlist, isNot(contains('<key>NSAllowsArbitraryLoads</key>')));
    });
  });
}
