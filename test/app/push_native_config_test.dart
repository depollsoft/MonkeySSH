import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Push must not contact FCM or App Check before the user opts in, and the
/// native code that guarantees it lives outside Dart. These checks pin it.
void main() {
  String read(String path) => File(path).readAsStringSync();

  bool plistFalse(String plist, String key) =>
      RegExp('<key>${RegExp.escape(key)}</key>\\s*<false/>').hasMatch(plist);

  bool plistTrue(String plist, String key) =>
      RegExp('<key>${RegExp.escape(key)}</key>\\s*<true/>').hasMatch(plist);

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

  // The push function sends to the Firebase Installation ID. Without these
  // flags FCM rejects register() and the app could not opt in.
  test('FCM registers the Firebase Installation ID on both platforms', () {
    expect(
      plistTrue(
        read('ios/Runner/Info.plist'),
        'FirebaseMessagingInstallationIdEnabled',
      ),
      isTrue,
    );
    expect(
      RegExp(
        r'android:name="firebase_messaging_installation_id_enabled"\s*'
        'android:value="true"',
      ).hasMatch(read('android/app/src/main/AndroidManifest.xml')),
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
    const extensionEntitlements =
        'NotificationServiceExtension/NotificationServiceExtension.entitlements';
    var checked = 0;
    var extensionChecked = 0;
    for (final match in configurations) {
      final entitlements = RegExp('CODE_SIGN_ENTITLEMENTS = ([^;]+);')
          .firstMatch(match.group(2)!)
          ?.group(1);
      if (entitlements == null) continue;
      if (entitlements == extensionEntitlements) {
        extensionChecked++;
        continue;
      }
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
    expect(extensionChecked, 9);
  });

  test('the app shares one keychain group with its notification service', () {
    const pushGroup = r'$(AppIdentifierPrefix)$(MONKEYSSH_APP_BUNDLE_ID).push';
    List<String> groups(String path) {
      final array = RegExp(
        r'<key>keychain-access-groups</key>\s*<array>([\s\S]*?)</array>',
      ).firstMatch(read(path))!.group(1)!;
      return [
        for (final value in RegExp(
          '<string>([^<]*)</string>',
        ).allMatches(array))
          value.group(1)!,
      ];
    }

    // The app's own group must stay first: it is the default access group,
    // so every existing keychain item keeps being written where it was.
    for (final path in [
      'ios/Runner/Runner.entitlements',
      'ios/Runner/RunnerDebug.entitlements',
    ]) {
      expect(groups(path), [
        r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)',
        pushGroup,
      ], reason: path);
    }
    expect(
      groups(
        'ios/NotificationServiceExtension/'
        'NotificationServiceExtension.entitlements',
      ),
      [pushGroup],
    );
    for (final path in [
      'ios/Runner/Info.plist',
      'ios/NotificationServiceExtension/Info.plist',
    ]) {
      expect(
        read(path),
        contains(
          '<key>MonkeySSHPushKeychainGroup</key>\n\t<string>$pushGroup</string>',
        ),
        reason: path,
      );
    }
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
