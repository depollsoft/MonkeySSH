// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';
import 'package:monkeyssh/domain/services/wifi_network_service.dart';

import 'app_permission_service_cases.dart';

void main() {
  registerAppPermissionServiceTests();

  group('WifiNetworkService.requestPermission', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (status, expected) in [
        (AppPermissionStatus.granted, WifiPermissionStatus.granted),
        (AppPermissionStatus.approximate, WifiPermissionStatus.approximate),
        (AppPermissionStatus.denied, WifiPermissionStatus.denied),
        (
          AppPermissionStatus.permanentlyDenied,
          WifiPermissionStatus.permanentlyDenied,
        ),
        (AppPermissionStatus.restricted, WifiPermissionStatus.denied),
      ]) {
        test('maps ${status.name} on ${platform.name}', () async {
          debugDefaultTargetPlatformOverride = platform;
          final calls = answerPermissionChannel((_) async => status.name);

          expect(await WifiNetworkService().requestPermission(), expected);
          expect(calls.single.arguments, AppPermission.locationWhenInUse.name);
        });
      }
    }

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      test('needs no runtime grant on ${platform.name}', () async {
        debugDefaultTargetPlatformOverride = platform;
        final calls = answerPermissionChannel((_) async => 'denied');

        expect(
          await WifiNetworkService().requestPermission(),
          WifiPermissionStatus.granted,
        );
        expect(calls, isEmpty);
      });
    }

    test('reads a platform error as denied', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      answerPermissionChannel(
        (_) async => throw PlatformException(code: 'unavailable'),
      );

      expect(
        await WifiNetworkService().requestPermission(),
        WifiPermissionStatus.denied,
      );
    });

    test(
      'surfaces a missing channel handler instead of reading it as denied',
      () async {
        // An unregistered channel is a build bug; reporting it as the user's
        // denial would hide it behind "Location permission is required".
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        await expectLater(
          WifiNetworkService().requestPermission(),
          throwsA(isA<MissingPluginException>()),
        );
      },
    );
  });

  group('encodeSkipJumpHostSsids', () {
    test('returns null for empty input', () {
      expect(encodeSkipJumpHostSsids(const []), isNull);
      expect(encodeSkipJumpHostSsids(const ['', '   ']), isNull);
    });

    test('joins entries with newline and trims', () {
      expect(
        encodeSkipJumpHostSsids(const ['home', '  office  ']),
        'home\noffice',
      );
    });

    test('deduplicates entries while preserving order', () {
      expect(encodeSkipJumpHostSsids(const ['a', 'b', 'a', 'c']), 'a\nb\nc');
    });

    test('strips embedded line breaks so each entry stays single-line', () {
      expect(
        encodeSkipJumpHostSsids(const ['ho\nme', 'shop\rfloor']),
        'home\nshopfloor',
      );
    });

    test('drops entries that become empty after stripping line breaks', () {
      expect(encodeSkipJumpHostSsids(const ['\n\r\n', 'home']), 'home');
    });

    test('strips zero-width and bidi format characters from SSIDs', () {
      // U+200B zero-width space, U+200E left-to-right mark, U+FEFF BOM.
      expect(encodeSkipJumpHostSsids(const ['​ho‎me﻿']), 'home');
    });

    test('drops entries that contain only invisible characters', () {
      expect(encodeSkipJumpHostSsids(const ['​‎﻿', 'home']), 'home');
    });

    test('drops entries built only from variation selectors', () {
      // U+FE0F is a variation selector — invisible on its own.
      expect(encodeSkipJumpHostSsids(const ['️️️', 'home']), 'home');
    });

    test('drops entries built only from combining marks', () {
      // U+034F combining grapheme joiner — invisible alone, no Letter/Number.
      expect(encodeSkipJumpHostSsids(const ['͏͏', 'home']), 'home');
    });

    test('preserves emoji SSIDs (Symbol category)', () {
      expect(encodeSkipJumpHostSsids(const ['🏠']), '🏠');
    });
  });

  group('decodeSkipJumpHostSsids', () {
    test('returns empty for null/empty', () {
      expect(decodeSkipJumpHostSsids(null), isEmpty);
      expect(decodeSkipJumpHostSsids(''), isEmpty);
    });

    test('splits and trims', () {
      expect(decodeSkipJumpHostSsids('home\n office \n\nshop'), const [
        'home',
        'office',
        'shop',
      ]);
    });

    test('round-trips with encode', () {
      const input = ['network one', 'two', 'café'];
      final encoded = encodeSkipJumpHostSsids(input);
      expect(decodeSkipJumpHostSsids(encoded), input);
    });

    test('cleans invisible characters from previously-stored values', () {
      // Simulates a row written before encoder hardening that still has a
      // BOM/ZWSP/LRM lurking in it.
      expect(decodeSkipJumpHostSsids('﻿ho​m‎e\nshop'), const ['home', 'shop']);
    });
  });

  group('shouldSkipJumpHostForSsid', () {
    test('returns false when current SSID is null', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: null,
          skipJumpHostOnSsids: 'home',
        ),
        isFalse,
      );
    });

    test('returns false when stored list is empty', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'home',
          skipJumpHostOnSsids: null,
        ),
        isFalse,
      );
    });

    test('returns true on exact match', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'office',
          skipJumpHostOnSsids: 'home\noffice',
        ),
        isTrue,
      );
    });

    test('match is case-sensitive', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'Home',
          skipJumpHostOnSsids: 'home',
        ),
        isFalse,
      );
    });
  });
}
