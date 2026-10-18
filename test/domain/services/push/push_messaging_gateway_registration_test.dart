import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';

void main() {
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

    test('waits for an FID that arrives after register() completes', () async {
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
    });

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
}
