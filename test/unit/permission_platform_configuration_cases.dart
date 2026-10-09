import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';

const _androidPlugin =
    'android/app/src/main/kotlin/xyz/depollsoft/monkeyssh/AppPermissionsPlugin.kt';
const _iosPlugin = 'ios/Runner/AppPermissionsPlugin.swift';

/// Asserts [registration] (built from the registry argument captured by
/// [generated]) appears in [source] inside the same function as that
/// GeneratedPluginRegistrant call, so the channel registers on the same engine
/// at the same time as every other plugin.
void _expectRegisteredBesideGeneratedPlugins(
  String source, {
  required RegExp generated,
  required String Function(String registry) registration,
  required String functionKeyword,
}) {
  final match = generated.firstMatch(source);
  expect(match, isNotNull, reason: 'GeneratedPluginRegistrant call not found');
  final expected = registration(match!.group(1)!);
  final index = source.indexOf(expected);
  expect(index, isNot(-1), reason: 'expected `$expected`');
  expect(
    source.lastIndexOf(functionKeyword, index),
    source.lastIndexOf(functionKeyword, match.start),
    reason: '`$expected` must sit in the function that registers the plugins',
  );
}

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

      _expectRegisteredBesideGeneratedPlugins(
        application,
        generated: RegExp(r'GeneratedPluginRegistrant\.registerWith\((\w+)\)'),
        registration: (engine) => '$engine.plugins.add(AppPermissionsPlugin())',
        functionKeyword: 'fun ',
      );
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
      // Under the UIScene lifecycle (#907) the engine, and so a registrar,
      // exists only from didInitializeImplicitFlutterEngine; registering on the
      // app delegate at launch would leave the channel unregistered.
      _expectRegisteredBesideGeneratedPlugins(
        appDelegate,
        generated: RegExp(
          r'GeneratedPluginRegistrant\.register\(with: ([^)]+)\)',
        ),
        registration: (registry) =>
            'AppPermissionsPlugin.register(in: $registry)',
        functionKeyword: 'func ',
      );
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
