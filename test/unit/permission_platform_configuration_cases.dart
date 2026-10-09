import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';

const _androidPlugin =
    'android/app/src/main/kotlin/xyz/depollsoft/monkeyssh/AppPermissionsPlugin.kt';
const _iosPlugin = 'ios/Runner/AppPermissionsPlugin.swift';

void registerPermissionPlatformConfigurationTests() {
  group('permission_platform_configuration', () {
    test('both native handlers listen on the Dart channel name', () {
      for (final path in [_androidPlugin, _iosPlugin]) {
        expect(
          File(path).readAsStringSync(),
          contains('"${AppPermissionService.channelName}"'),
          reason: path,
        );
      }
    });

    test('both native handlers accept every Dart permission name', () {
      for (final path in [_androidPlugin, _iosPlugin]) {
        final source = File(path).readAsStringSync();
        for (final permission in AppPermission.values) {
          expect(source, contains('"${permission.name}"'), reason: path);
        }
      }
    });

    test('android registers the plugin on the shared engine', () {
      final application = File(
        'android/app/src/main/kotlin/xyz/depollsoft/monkeyssh/MonkeySshApplication.kt',
      ).readAsStringSync();

      expect(application, contains('plugins.add(AppPermissionsPlugin())'));
    });

    test('android declares every permission the plugin requests', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();

      for (final permission in [
        'android.permission.CAMERA',
        'android.permission.RECORD_AUDIO',
        'android.permission.ACCESS_COARSE_LOCATION',
        'android.permission.ACCESS_FINE_LOCATION',
      ]) {
        expect(manifest, contains(permission));
      }
    });

    test('ios compiles and registers the plugin', () {
      final project = File('ios/Runner.xcodeproj/project.pbxproj')
          .readAsStringSync();
      final appDelegate = File('ios/Runner/AppDelegate.swift')
          .readAsStringSync();

      expect(project, contains('AppPermissionsPlugin.swift in Sources'));
      expect(appDelegate, contains('AppPermissionsPlugin.register('));
    });

    test('ios declares a purpose string for every prompt', () {
      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

      // Without these the plugin reports denied instead of prompting; for
      // camera and microphone, prompting without one terminates the app.
      for (final key in [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSLocationWhenInUseUsageDescription',
      ]) {
        expect(infoPlist, contains('<key>$key</key>'));
      }
    });
  });
}
