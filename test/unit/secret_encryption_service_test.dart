// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/security/secret_encryption_service.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

const _legacyMasterKeyStorageEntry =
    'flutty_db_'
    'secret'
    '_key_v1';

void main() {
  setUpAll(() {
    registerFallbackValue(IOSOptions.defaultOptions);
  });

  group('SecretEncryptionService', () {
    late SecretEncryptionService service;

    setUp(() {
      service = SecretEncryptionService.forTesting();
    });

    test('encrypt/decrypt roundtrip for plaintext', () async {
      const plaintext = 's3cret-value';
      final encrypted = await service.encryptNullable(plaintext);

      expect(encrypted, isNotNull);
      expect(encrypted, startsWith('ENCv1:'));
      expect(encrypted, isNot(plaintext));
      await expectLater(
        service.decryptNullable(encrypted),
        completion(plaintext),
      );
    });

    test('keeps already encrypted values unchanged', () async {
      const plaintext = 'already-encrypted-value';
      final encrypted = await service.encryptNullable(plaintext);
      final reencrypted = await service.encryptNullable(encrypted);

      expect(reencrypted, encrypted);
      await expectLater(
        service.decryptNullable(reencrypted),
        completion(plaintext),
      );
    });

    test(
      'encryptRequired does not double-encrypt an already-encrypted value',
      () async {
        const plaintext = 'secret-for-required';
        final encrypted = await service.encryptRequired(plaintext);
        final reencrypted = await service.encryptRequired(encrypted);

        expect(reencrypted, encrypted);
        await expectLater(
          service.decryptNullable(reencrypted),
          completion(plaintext),
        );
      },
    );

    test('encryptNullable is idempotent under repeated calls', () async {
      const plaintext = 'repeat-me';
      final once = await service.encryptNullable(plaintext);
      final twice = await service.encryptNullable(once);
      final thrice = await service.encryptNullable(twice);

      expect(twice, once);
      expect(thrice, once);
      await expectLater(service.decryptNullable(thrice), completion(plaintext));
    });

    test('encrypts malformed ENCv1-prefixed plaintext', () async {
      const prefixedPlaintext = 'ENCv1:not-a-valid-envelope';
      final encrypted = await service.encryptNullable(prefixedPlaintext);

      expect(encrypted, isNot(prefixedPlaintext));
      expect(encrypted, startsWith('ENCv1:'));
      await expectLater(
        service.decryptNullable(encrypted),
        completion(prefixedPlaintext),
      );
    });

    test('validates encrypted envelope structure', () async {
      const prefixedPlaintext = 'ENCv1:not-a-valid-envelope';
      final encrypted = await service.encryptNullable(prefixedPlaintext);

      expect(service.isEncryptedValue(prefixedPlaintext), isTrue);
      expect(service.isValidEncryptedEnvelope(prefixedPlaintext), isFalse);
      expect(service.isValidEncryptedEnvelope(encrypted!), isTrue);
    });

    test(
      'validation and decryption reject the same malformed structures',
      () async {
        final encrypted = await service.encryptRequired('secret');
        final envelope =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(encrypted.substring('ENCv1:'.length)),
                  ),
                )
                as Map<String, dynamic>;
        final malformed = <Object>[
          [],
          {...envelope}..remove('c'),
          {...envelope, 'n': base64Url.encode(List.filled(11, 0))},
          {...envelope, 'm': base64Url.encode(List.filled(15, 0))},
          {...envelope, 'm': base64Url.encode(List.filled(17, 0))},
          {...envelope, 'c': 42},
          {...envelope, 'm': '!'},
        ];
        for (final value in malformed) {
          final stored =
              'ENCv1:${base64Url.encode(utf8.encode(jsonEncode(value)))}';
          expect(service.isValidEncryptedEnvelope(stored), isFalse);
          await expectLater(
            service.decryptNullable(stored),
            throwsFormatException,
          );
        }
      },
    );

    test('reuses and migrates the legacy master key entry', () async {
      final storage = _MockFlutterSecureStorage();
      final writes = <String, String>{};
      final legacyValue = base64Encode(
        List<int>.generate(32, (index) => index),
      );

      when(
        () => storage.read(key: 'flutty_db_encryption_key_v1'),
      ).thenAnswer((_) async => null);
      when(
        () => storage.read(key: _legacyMasterKeyStorageEntry),
      ).thenAnswer((_) async => legacyValue);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        writes[invocation.namedArguments[#key] as String] =
            invocation.namedArguments[#value] as String;
      });

      service = SecretEncryptionService(storage: storage, random: Random(1));

      final encrypted = await service.encryptNullable('migrate-me');

      expect(encrypted, startsWith('ENCv1:'));
      expect(writes['flutty_db_encryption_key_v1'], legacyValue);
      verify(() => storage.read(key: 'flutty_db_encryption_key_v1')).called(1);
      verify(() => storage.read(key: _legacyMasterKeyStorageEntry)).called(1);
      verify(
        () => storage.write(
          key: 'flutty_db_encryption_key_v1',
          value: legacyValue,
        ),
      ).called(1);
    });

    test('migrates iOS master key stored with legacy accessibility', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final storage = _MockFlutterSecureStorage();
      final legacyValue = base64Encode(
        List<int>.generate(32, (index) => index),
      );
      const hardenedOptions = IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      );
      const legacyOptions = IOSOptions.defaultOptions;

      when(
        () => storage.read(
          key: 'flutty_db_encryption_key_v1',
          iOptions: hardenedOptions,
        ),
      ).thenAnswer((_) async => null);
      when(
        () => storage.read(
          key: 'flutty_db_encryption_key_v1',
          iOptions: legacyOptions,
        ),
      ).thenAnswer((_) async => legacyValue);
      when(
        () => storage.write(
          key: 'flutty_db_encryption_key_v1',
          value: legacyValue,
          iOptions: hardenedOptions,
        ),
      ).thenAnswer((_) async {});

      service = SecretEncryptionService(storage: storage, random: Random(1));

      final encrypted = await service.encryptNullable('migrate-me');

      expect(encrypted, startsWith('ENCv1:'));
      verify(
        () => storage.write(
          key: 'flutty_db_encryption_key_v1',
          value: legacyValue,
          iOptions: hardenedOptions,
        ),
      ).called(1);
      verifyNever(
        () => storage.read(
          key: _legacyMasterKeyStorageEntry,
          iOptions: any(named: 'iOptions'),
        ),
      );
    });

    test(
      'falls back to legacy iOS accessibility when hardened read throws',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
        });
        final storage = _MockFlutterSecureStorage();
        final legacyValue = base64Encode(
          List<int>.generate(32, (index) => index),
        );
        const hardenedOptions = IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        );
        const legacyOptions = IOSOptions.defaultOptions;

        when(
          () => storage.read(
            key: 'flutty_db_encryption_key_v1',
            iOptions: hardenedOptions,
          ),
        ).thenThrow(PlatformException(code: 'read_failed'));
        when(
          () => storage.read(
            key: 'flutty_db_encryption_key_v1',
            iOptions: legacyOptions,
          ),
        ).thenAnswer((_) async => legacyValue);
        when(
          () => storage.write(
            key: 'flutty_db_encryption_key_v1',
            value: legacyValue,
            iOptions: hardenedOptions,
          ),
        ).thenAnswer((_) async {});

        service = SecretEncryptionService(storage: storage, random: Random(1));

        final encrypted = await service.encryptNullable('migrate-me');

        expect(encrypted, startsWith('ENCv1:'));
        verify(
          () => storage.read(
            key: 'flutty_db_encryption_key_v1',
            iOptions: legacyOptions,
          ),
        ).called(1);
        verify(
          () => storage.write(
            key: 'flutty_db_encryption_key_v1',
            value: legacyValue,
            iOptions: hardenedOptions,
          ),
        ).called(1);
      },
    );

    test(
      'replaces duplicate legacy iOS keychain item during migration',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
        });
        final storage = _MockFlutterSecureStorage();
        final legacyValue = base64Encode(
          List<int>.generate(32, (index) => index),
        );
        const hardenedOptions = IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        );
        const legacyOptions = IOSOptions.defaultOptions;

        when(
          () => storage.read(
            key: 'flutty_db_encryption_key_v1',
            iOptions: hardenedOptions,
          ),
        ).thenAnswer((_) async => null);
        when(
          () => storage.read(
            key: 'flutty_db_encryption_key_v1',
            iOptions: legacyOptions,
          ),
        ).thenAnswer((_) async => legacyValue);
        var writeCount = 0;
        when(
          () => storage.write(
            key: 'flutty_db_encryption_key_v1',
            value: legacyValue,
            iOptions: hardenedOptions,
          ),
        ).thenAnswer((_) async {
          writeCount++;
          if (writeCount == 1) {
            throw PlatformException(
              code: 'Unexpected security result code',
              message: 'The specified item already exists in the keychain.',
              details: -25299,
            );
          }
        });
        when(
          () => storage.delete(
            key: 'flutty_db_encryption_key_v1',
            iOptions: legacyOptions,
          ),
        ).thenAnswer((_) async {});

        service = SecretEncryptionService(storage: storage, random: Random(1));

        final encrypted = await service.encryptNullable('migrate-me');

        expect(encrypted, startsWith('ENCv1:'));
        expect(writeCount, 2);
        verify(
          () => storage.delete(
            key: 'flutty_db_encryption_key_v1',
            iOptions: legacyOptions,
          ),
        ).called(1);
      },
    );

    group('tamper and corruption resistance', () {
      test('rejects a value with a tampered MAC', () async {
        const plaintext = 'sensitive-data';
        final encrypted = await service.encryptNullable(plaintext);

        // Decode the envelope, flip one byte in the MAC, re-encode.
        final compact = encrypted!.substring('ENCv1:'.length);
        final envelopeJson = utf8.decode(
          base64Url.decode(base64Url.normalize(compact)),
        );
        final envelope = Map<String, dynamic>.from(
          jsonDecode(envelopeJson) as Map,
        );
        final macBytes = base64Url.decode(
          base64Url.normalize(envelope['m'] as String),
        );
        macBytes[0] ^= 0xFF;
        envelope['m'] = base64Url.encode(macBytes);

        final tamperedCompact = base64Url.encode(
          utf8.encode(jsonEncode(envelope)),
        );
        final tampered = 'ENCv1:$tamperedCompact';

        await expectLater(
          service.decryptNullable(tampered),
          throwsFormatException,
        );
      });

      test('rejects a value with corrupted ciphertext', () async {
        const plaintext = 'sensitive-data';
        final encrypted = await service.encryptNullable(plaintext);

        final compact = encrypted!.substring('ENCv1:'.length);
        final envelopeJson = utf8.decode(
          base64Url.decode(base64Url.normalize(compact)),
        );
        final envelope = Map<String, dynamic>.from(
          jsonDecode(envelopeJson) as Map,
        );
        final cipherBytes = base64Url.decode(
          base64Url.normalize(envelope['c'] as String),
        );
        cipherBytes[0] ^= 0xFF;
        envelope['c'] = base64Url.encode(cipherBytes);

        final tamperedCompact = base64Url.encode(
          utf8.encode(jsonEncode(envelope)),
        );
        final tampered = 'ENCv1:$tamperedCompact';

        await expectLater(
          service.decryptNullable(tampered),
          throwsFormatException,
        );
      });

      test('rejects a value encrypted with a different master key', () async {
        const plaintext = 'sensitive-data';
        final otherKey = List<int>.generate(32, (i) => 255 - i);
        final otherService = SecretEncryptionService.forTesting(
          masterKey: otherKey,
        );
        final encryptedByOther = await otherService.encryptNullable(plaintext);

        await expectLater(
          service.decryptNullable(encryptedByOther),
          throwsFormatException,
        );
      });

      test('rejects an envelope with a missing nonce field', () async {
        const plaintext = 'sensitive-data';
        final encrypted = await service.encryptNullable(plaintext);

        final compact = encrypted!.substring('ENCv1:'.length);
        final envelopeJson = utf8.decode(
          base64Url.decode(base64Url.normalize(compact)),
        );
        final envelope = Map<String, dynamic>.from(
          jsonDecode(envelopeJson) as Map,
        )..remove('n');

        final badCompact = base64Url.encode(utf8.encode(jsonEncode(envelope)));
        final badValue = 'ENCv1:$badCompact';

        await expectLater(
          service.decryptNullable(badValue),
          throwsFormatException,
        );
      });

      test('rejects an envelope with a missing ciphertext field', () async {
        const plaintext = 'sensitive-data';
        final encrypted = await service.encryptNullable(plaintext);

        final compact = encrypted!.substring('ENCv1:'.length);
        final envelopeJson = utf8.decode(
          base64Url.decode(base64Url.normalize(compact)),
        );
        final envelope = Map<String, dynamic>.from(
          jsonDecode(envelopeJson) as Map,
        )..remove('c');

        final badCompact = base64Url.encode(utf8.encode(jsonEncode(envelope)));
        final badValue = 'ENCv1:$badCompact';

        await expectLater(
          service.decryptNullable(badValue),
          throwsFormatException,
        );
      });

      test('rejects an envelope with a missing MAC field', () async {
        const plaintext = 'sensitive-data';
        final encrypted = await service.encryptNullable(plaintext);

        final compact = encrypted!.substring('ENCv1:'.length);
        final envelopeJson = utf8.decode(
          base64Url.decode(base64Url.normalize(compact)),
        );
        final envelope = Map<String, dynamic>.from(
          jsonDecode(envelopeJson) as Map,
        )..remove('m');

        final badCompact = base64Url.encode(utf8.encode(jsonEncode(envelope)));
        final badValue = 'ENCv1:$badCompact';

        await expectLater(
          service.decryptNullable(badValue),
          throwsFormatException,
        );
      });

      test('rejects a completely invalid encrypted payload', () async {
        const garbage = 'ENCv1:not-even-base64!!!';
        await expectLater(
          service.decryptNullable(garbage),
          throwsFormatException,
        );
      });

      test('rejects an unexpected plaintext value (no ENCv1 prefix)', () async {
        const rawPlaintext = 'no-prefix-secret';
        await expectLater(
          service.decryptNullable(rawPlaintext),
          throwsFormatException,
        );
      });
    });
  });
}
