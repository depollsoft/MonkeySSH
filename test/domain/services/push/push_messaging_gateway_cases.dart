// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';

import '../../../helpers/permission_channel_test_helper.dart';

/// Registers tests for PushMessagingGateway and App Check failure fields.
void registerDomainServicesPushMessagingGatewayTests() {
  group('push_messaging_gateway', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    group('appCheckFailureFields', () {
      FirebaseException failure(String code, String message) =>
          FirebaseException(
            plugin: 'firebase_app_check',
            code: code,
            message: message,
          );

      test('keeps the Play Integrity error code, not the message', () {
        final fields = appCheckFailureFields(
          failure(
            'unknown',
            '-16: Integrity API error (-16): Cloud project number is invalid. '
                'Use the cloud project number 529923319565 from your app.',
          ),
        );
        expect(fields, {'code': 'unknown', 'integrityError': -16});
      });

      test('keeps the token exchange HTTP status', () {
        final fields = appCheckFailureFields(
          failure(
            'unknown',
            'Error returned from API. code: 403 body: App attestation failed.',
          ),
        );
        expect(fields, {'code': 'unknown', 'httpStatus': 403});
      });

      test('drops anything outside a short code', () {
        final fields = appCheckFailureFields(
          failure('weird code/with "quotes"', 'no numbers here'),
        );
        expect(fields, {'code': 'weirdcodewithquotes'});
      });
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      group('FirebasePushMessagingGateway.requestPermission on $platform', () {
        setUp(() => debugDefaultTargetPlatformOverride = platform);
        tearDown(() => debugDefaultTargetPlatformOverride = null);

        for (final status in AppPermissionStatus.values) {
          test('reads ${status.name} from the permissions channel', () async {
            final calls = answerPermissionChannel((_) async => status.name);

            expect(
              await FirebasePushMessagingGateway().requestPermission(),
              status.isGranted,
            );
            expect(calls.map((call) => (call.method, call.arguments)), [
              ('request', AppPermission.notifications.name),
            ]);
          });
        }

        test('surfaces a failed request', () async {
          answerPermissionChannel(
            (_) async => throw PlatformException(code: 'invalid_args'),
          );

          await expectLater(
            FirebasePushMessagingGateway().requestPermission(),
            throwsA(isA<PlatformException>()),
          );
        });
      });
    }

    group('registerForFid', () {
      const timeout = Duration(seconds: 30);

      test('takes an FID that arrives while register() runs', () async {
        final registered = StreamController<String>.broadcast();
        addTearDown(registered.close);

        final fid = await registerForFid(registered.stream, () async {
          registered.add('fid-during');
        }, timeout: timeout);

        expect(fid, 'fid-during');
        expect(registered.hasListener, isFalse);
      });

      test(
        'waits for an FID that arrives after register() completes',
        () async {
          final registered = StreamController<String>.broadcast();
          addTearDown(registered.close);

          final fid = registerForFid(
            registered.stream,
            () async => Timer.run(() {
              registered
                ..add('fid-after')
                ..add('fid-later');
            }),
            timeout: timeout,
          );

          expect(await fid, 'fid-after');
          expect(registered.hasListener, isFalse);
        },
      );

      test('surfaces a failed register() and stops listening', () async {
        final registered = StreamController<String>.broadcast();
        addTearDown(registered.close);

        await expectLater(
          registerForFid(
            registered.stream,
            () async => throw StateError('API disabled'),
            timeout: timeout,
          ),
          throwsStateError,
        );
        expect(registered.hasListener, isFalse);
      });

      test('times out when FCM never reports an FID', () async {
        final registered = StreamController<String>.broadcast();
        addTearDown(registered.close);

        await expectLater(
          registerForFid(
            registered.stream,
            () async {},
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(registered.hasListener, isFalse);
      });
    });

    test('a legacy token from older Play services registers as a token', () {
      expect(pushRegistrationField('cR1oNotARealFid_123456'), 'fid');
      expect(
        pushRegistrationField('cR1oNotARealFid_123456:APA91bLegacyToken'),
        'token',
      );
    });
  });
}
