import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void registerBiometricPlatformConfigurationTests() {
  group('biometric_platform_configuration', () {
    group('biometric platform configuration', () {
      test('android uses FlutterFragmentActivity for local_auth', () {
        final mainActivity = File(
          'android/app/src/main/kotlin/xyz/depollsoft/monkeyssh/MainActivity.kt',
        ).readAsStringSync();

        expect(mainActivity, contains('FlutterFragmentActivity'));
        expect(
          mainActivity,
          isNot(contains('class MainActivity : FlutterActivity')),
        );
      });

      test('ios declares a Face ID usage description', () {
        final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

        expect(infoPlist, contains('NSFaceIDUsageDescription'));
        expect(
          infoPlist,
          contains('uses Face ID to unlock your encrypted SSH credentials'),
        );
      });
    });
  });
}
