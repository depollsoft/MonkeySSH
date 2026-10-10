import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Push must not contact FCM or App Check before the user opts in, and the
/// native code that guarantees it lives outside Dart. These checks pin it.
void main() {
  String read(String path) => File(path).readAsStringSync();

  bool plistFalse(String plist, String key) =>
      RegExp('<key>${RegExp.escape(key)}</key>\\s*<false/>').hasMatch(plist);

  test('iOS keeps FCM and App Check idle until opt-in', () {
    final plist = read('ios/Runner/Info.plist');
    expect(plistFalse(plist, 'FirebaseMessagingAutoInitEnabled'), isTrue);
    // FirebaseAppCheckPlugin installs a provider factory at launch; without
    // this key App Check would fetch a token at every start.
    expect(
      plistFalse(plist, 'FirebaseAppCheckTokenAutoRefreshEnabled'),
      isTrue,
    );
  });

  test('Android keeps FCM idle until opt-in', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(
      RegExp(
        r'android:name="firebase_messaging_auto_init_enabled"\s*'
        'android:value="false"',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('Release builds use production APNs and Debug builds development', () {
    final release = read('ios/Runner/Runner.entitlements');
    final debug = read('ios/Runner/RunnerDebug.entitlements');
    expect(
      release,
      matches(
        RegExp(r'<key>aps-environment</key>\s*<string>production</string>'),
      ),
    );
    expect(
      debug,
      matches(
        RegExp(r'<key>aps-environment</key>\s*<string>development</string>'),
      ),
    );

    final project = read('ios/Runner.xcodeproj/project.pbxproj');
    final configurations = RegExp(
      r'/\* ([A-Za-z-]+) \*/ = \{\s*isa = XCBuildConfiguration;'
      r'([\s\S]*?)\n\t\t\};',
    ).allMatches(project);
    var checked = 0;
    for (final match in configurations) {
      final entitlements = RegExp('CODE_SIGN_ENTITLEMENTS = ([^;]+);')
          .firstMatch(match.group(2)!)
          ?.group(1);
      if (entitlements == null) continue;
      checked++;
      final isDebug = match.group(1)!.startsWith('Debug');
      expect(
        entitlements,
        isDebug
            ? 'Runner/RunnerDebug.entitlements'
            : 'Runner/Runner.entitlements',
        reason: match.group(1),
      );
    }
    expect(checked, 9);
  });

  test('the AppDelegate answers notification callbacks itself', () {
    final delegate = read('ios/Runner/AppDelegate.swift');
    expect(
      delegate,
      contains('UNUserNotificationCenter.current().delegate = self'),
    );
    expect(delegate, contains('willPresent notification: UNNotification'));
    expect(delegate, contains('didReceive response: UNNotificationResponse'));
    expect(delegate, contains('completionHandler([])'));
  });
}
