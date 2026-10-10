import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/push/push_crypto.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';

Map<String, Object?> _vectors() =>
    jsonDecode(File('docs/push-notification-vectors.json').readAsStringSync())
        as Map<String, Object?>;

/// Vector material is derived from public labels (SHA-256, truncated), so
/// the shared file holds no key bytes.
List<int> _fromLabel(Object? label, int size) =>
    crypto.sha256.convert(utf8.encode(label! as String)).bytes.sublist(0, size);

String _digest(List<int> value) => crypto.sha256.convert(value).toString();

List<int> _bytes(Object? value) {
  final decoded = decodePushBase64(value! as String);
  expect(decoded, isNotNull, reason: 'vector is not base64url: $value');
  return decoded!;
}

void main() {
  final vector = _vectors()['payload']! as Map<String, Object?>;

  group('push payload vectors', () {
    test('the device key derives the pinned public key', () async {
      final device = await pushDeviceKeyPairFromSeed(
        _fromLabel(vector['deviceLabel'], 32),
      );
      expect(device.encodedPublicKey, vector['devicePublic']);
      final ephemeral = await pushDeviceKeyPairFromSeed(
        _fromLabel(vector['ephemeralLabel'], 32),
      );
      expect(ephemeral.encodedPublicKey, vector['ephemeralPublic']);
    });

    test('the X25519 and HKDF outputs match the pinned digests', () async {
      final x25519 = X25519();
      final ephemeral = await x25519.newKeyPairFromSeed(
        _fromLabel(vector['ephemeralLabel'], 32),
      );
      final shared = await (await x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: SimplePublicKey(
          _bytes(vector['devicePublic']),
          type: KeyPairType.x25519,
        ),
      )).extractBytes();
      expect(_digest(shared), vector['sharedDigest']);
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: SecretKey(shared),
            nonce: [
              ..._bytes(vector['ephemeralPublic']),
              ..._bytes(vector['devicePublic']),
            ],
            info: utf8.encode(vector['info']! as String),
          );
      expect(_digest(await derived.extractBytes()), vector['derivedDigest']);
    });

    test('sealing with the pinned randomness matches MonkeyMux', () async {
      final sealed = await sealPushPayloadForTesting(
        devicePublicKey: _bytes(vector['devicePublic']),
        plaintext: utf8.encode(vector['plaintext']! as String),
        ephemeralSeed: _fromLabel(vector['ephemeralLabel'], 32),
        nonce: _fromLabel(vector['nonceLabel'], 12),
      );
      expect(sealed, vector['payload']);
    });

    test('the device opens the pinned payload', () async {
      final device = await pushDeviceKeyPairFromSeed(
        _fromLabel(vector['deviceLabel'], 32),
      );
      final plaintext = await openPushPayload(
        device: device,
        payload: vector['payload']! as String,
      );
      expect(utf8.decode(plaintext!), vector['plaintext']);
      final event = PushEvent.tryParse(plaintext)!;
      expect(event.kind, PushEventKind.permission);
      expect(event.hostRef, 'Vv2a6mQZbW3x9R1c');
      expect(event.windowId, '@3');
      expect(event.sessionName, 'main');
      expect(event.timestamp.millisecondsSinceEpoch, 1760000000 * 1000);
    });

    test('rejected payloads do not open', () async {
      final device = await pushDeviceKeyPairFromSeed(
        _fromLabel(vector['deviceLabel'], 32),
      );
      for (final rejected in vector['rejected']! as List<Object?>) {
        final entry = rejected! as Map<String, Object?>;
        expect(
          await openPushPayload(
            device: device,
            payload: entry['payload']! as String,
          ),
          isNull,
          reason: entry['reason']! as String,
        );
      }
    });

    test('another device cannot open the payload', () async {
      final stranger = await generatePushDeviceKeyPair();
      expect(
        await openPushPayload(
          device: stranger,
          payload: vector['payload']! as String,
        ),
        isNull,
      );
    });
  });

  group('host references', () {
    test('are stable, short, opaque and keyed', () async {
      final key = List<int>.filled(32, 7);
      final first = await derivePushHostRef(hostRefKey: key, hostId: 12);
      expect(first, await derivePushHostRef(hostRefKey: key, hostId: 12));
      expect(first, hasLength(16));
      expect(first, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(first, isNot(contains('12')));
      expect(
        await derivePushHostRef(hostRefKey: key, hostId: 13),
        isNot(first),
      );
      expect(
        await derivePushHostRef(
          hostRefKey: List<int>.filled(32, 8),
          hostId: 12,
        ),
        isNot(first),
      );
    });
  });

  group('base64url', () {
    test('decoding is strict', () {
      expect(decodePushBase64('YQ=='), isNull);
      expect(decodePushBase64('a+b/'), isNull);
      expect(decodePushBase64('abcde'), isNull);
      expect(decodePushBase64('YQ'), utf8.encode('a'));
      expect(encodePushBase64(utf8.encode('a')), 'YQ');
    });
  });

  group('push event parsing', () {
    test('ignores malformed or unknown payloads', () {
      for (final raw in [
        'not json',
        '[]',
        '{"v":2,"hostRef":"a","kind":"alert","ts":1}',
        '{"v":1,"kind":"alert","ts":1}',
        '{"v":1,"hostRef":"a","kind":"gossip","ts":1}',
        '{"v":1,"hostRef":"a","kind":"alert"}',
      ]) {
        expect(PushEvent.tryParse(utf8.encode(raw)), isNull, reason: raw);
      }
    });

    test('drops window ids that are not MonkeyMux ids', () {
      final event = PushEvent.tryParse(
        utf8.encode(
          '{"v":1,"hostRef":"a","kind":"test","ts":1,"window":"../x",'
          '"sessionId":"","extra":true}',
        ),
      )!;
      expect(event.kind, PushEventKind.test);
      expect(event.windowId, isNull);
      expect(event.sessionName, isNull);
    });
  });

  group('registration response', () {
    test('parses the callable result', () {
      final registration = parsePushRegistrationResponse(
        200,
        '{"result":{"deviceId":"pX7cQe2LrV0sNw4yJk9aTg","ticket":"v1.k1.abc"}}',
      );
      expect(registration.deviceId, 'pX7cQe2LrV0sNw4yJk9aTg');
      expect(registration.ticket, 'v1.k1.abc');
    });

    test('rejects callable errors and malformed bodies', () {
      for (final (status, body) in [
        (401, '{"error":{"status":"UNAUTHENTICATED"}}'),
        (200, '{"error":{"status":"INTERNAL"}}'),
        (200, 'not json'),
        (200, '{"result":{"deviceId":"x","ticket":"v2.k1.abc"}}'),
      ]) {
        expect(
          () => parsePushRegistrationResponse(status, body),
          throwsA(
            isA<PushSetupException>().having(
              (error) => error.failure,
              'failure',
              PushSetupFailure.registrationFailed,
            ),
          ),
        );
      }
    });
  });
}
