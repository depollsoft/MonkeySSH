// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';

const _validPinHash = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const _shortPinHash = 'AAECAwQFBgcICQoLDA0ODw==';
const _validPinSalt = 'AAECAwQFBgcICQoLDA0ODw==';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

class MockLocalAuthentication extends Mock implements LocalAuthentication {}

void main() {
  setUpAll(() {
    registerFallbackValue(IOSOptions.defaultOptions);
  });

  late AuthService authService;
  late MockFlutterSecureStorage mockStorage;
  late MockLocalAuthentication mockLocalAuth;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    mockLocalAuth = MockLocalAuthentication();
    authService = AuthService(storage: mockStorage, localAuth: mockLocalAuth);
    when(
      () => mockStorage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => null);
    when(
      () => mockStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockStorage.delete(key: any(named: 'key')),
    ).thenAnswer((_) async {});
  });

  group('AuthService', () {
    group('isAuthEnabled', () {
      test('returns false when not configured', () async {
        when(
          () => mockStorage.read(key: any(named: 'key')),
        ).thenAnswer((_) async => null);

        final result = await authService.isAuthEnabled();

        expect(result, false);
      });

      test('returns true when configured', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');

        final result = await authService.isAuthEnabled();

        expect(result, true);
      });

      test(
        'reads and migrates iOS keychain items with legacy accessibility',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() {
            debugDefaultTargetPlatformOverride = null;
          });
          const hardenedOptions = IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          );
          const legacyOptions = IOSOptions.defaultOptions;
          when(
            () => mockStorage.read(
              key: 'flutty_auth_enabled',
              iOptions: hardenedOptions,
            ),
          ).thenAnswer((_) async => null);
          when(
            () => mockStorage.read(
              key: 'flutty_auth_enabled',
              iOptions: legacyOptions,
            ),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.write(
              key: 'flutty_auth_enabled',
              value: 'true',
              iOptions: hardenedOptions,
            ),
          ).thenAnswer((_) async {});

          final result = await authService.isAuthEnabled();

          expect(result, true);
          verify(
            () => mockStorage.write(
              key: 'flutty_auth_enabled',
              value: 'true',
              iOptions: hardenedOptions,
            ),
          ).called(1);
        },
      );
    });

    group('setupPin', () {
      test('stores hardened PIN data and enables auth', () async {
        final writes = <String, String>{};
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          writes[invocation.namedArguments[const Symbol('key')] as String] =
              invocation.namedArguments[const Symbol('value')] as String;
        });

        await authService.setupPin('1234');

        expect(writes['flutty_pin_salt'], isNotNull);
        expect(writes['flutty_auth_enabled'], 'true');
        final pinPayload =
            jsonDecode(writes['flutty_pin_hash']!) as Map<String, dynamic>;
        expect(pinPayload['version'], 1);
        expect(pinPayload['iterations'], greaterThan(0));
        expect(pinPayload['hash'], isA<String>());
      });
    });

    group('verifyPin', () {
      for (final (description, pin, expected) in [
        ('returns true for correct PIN', '1234', true),
        ('returns false for incorrect PIN', '9999', false),
      ]) {
        test(description, () async {
          final storage = <String, String>{};
          when(
            () => mockStorage.write(
              key: any(named: 'key'),
              value: any(named: 'value'),
            ),
          ).thenAnswer((invocation) async {
            storage[invocation.namedArguments[const Symbol('key')] as String] =
                invocation.namedArguments[const Symbol('value')] as String;
          });
          when(() => mockStorage.read(key: any(named: 'key'))).thenAnswer(
            (invocation) async =>
                storage[invocation.namedArguments[const Symbol('key')]],
          );

          await authService.setupPin('1234');

          final result = await authService.verifyPin(pin);

          expect(result, expected);
        });
      }

      for (final (description, stored) in [
        ('legacy PIN hash format', 'legacy-hash-value'),
        (
          'unsupported PIN KDF version',
          jsonEncode({'version': 99, 'iterations': 120000, 'hash': 'hash'}),
        ),
        (
          'invalid PIN KDF iterations',
          jsonEncode({'version': 1, 'iterations': 0, 'hash': 'hash'}),
        ),
        (
          'decodable PIN hash with invalid length',
          jsonEncode({
            'version': 1,
            'iterations': 120000,
            'hash': _shortPinHash,
          }),
        ),
        ('no PIN is set', null),
      ]) {
        test('returns false for $description', () async {
          when(
            () => mockStorage.read(key: 'flutty_pin_hash'),
          ).thenAnswer((_) async => stored);
          when(
            () => mockStorage.read(key: 'flutty_pin_salt'),
          ).thenAnswer((_) async => _validPinSalt);
          final result = await authService.verifyPin('1234');
          expect(result, false);
        });
      }
    });

    group('isDeviceAuthSupported', () {
      test(
        'returns true when device auth is supported without biometrics',
        () async {
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.canCheckBiometrics,
          ).thenAnswer((_) async => false);

          final result = await authService.isDeviceAuthSupported();

          expect(result, true);
        },
      );

      test('returns false when device auth is unsupported', () async {
        when(
          () => mockLocalAuth.isDeviceSupported(),
        ).thenAnswer((_) async => false);

        final result = await authService.isDeviceAuthSupported();

        expect(result, false);
      });
    });

    group('isBiometricHardwareSupported', () {
      test('returns true when the device can check biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);

        final result = await authService.isBiometricHardwareSupported();

        expect(result, true);
      });

      test('returns false when the device cannot check biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => false);

        final result = await authService.isBiometricHardwareSupported();

        expect(result, false);
      });
    });

    group('isBiometricAvailable', () {
      test('returns true when biometrics available', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => [BiometricType.fingerprint]);

        final result = await authService.isBiometricAvailable();

        expect(result, true);
      });

      test('returns false when no biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => []);

        final result = await authService.isBiometricAvailable();

        expect(result, false);
      });

      test('returns false when device cannot check biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => false);

        final result = await authService.isBiometricAvailable();

        expect(result, false);
      });
    });

    group('getBiometricAvailability', () {
      test(
        'distinguishes device credentials from biometric hardware',
        () async {
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.canCheckBiometrics,
          ).thenAnswer((_) async => false);

          final result = await authService.getBiometricAvailability();

          expect(result.isDeviceAuthSupported, true);
          expect(result.isBiometricHardwareSupported, false);
          expect(result.canAuthenticateWithBiometrics, false);
          verifyNever(() => mockLocalAuth.getAvailableBiometrics());
        },
      );
    });

    group('setBiometricEnabled', () {
      test('does not enable biometrics before enrollment is ready', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => []);

        await authService.setBiometricEnabled(enabled: true);

        verify(
          () => mockStorage.write(
            key: 'flutty_biometric_enabled',
            value: 'false',
          ),
        ).called(1);
      });
    });

    group('authenticateWithBiometrics', () {
      test(
        'does not open a platform prompt before enrollment is ready',
        () async {
          when(
            () => mockLocalAuth.canCheckBiometrics,
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.getAvailableBiometrics(),
          ).thenAnswer((_) async => []);

          final result = await authService.authenticateWithBiometrics(
            reason: 'Unlock MonkeySSH',
          );

          expect(result, false);
          verifyNever(
            () => mockLocalAuth.authenticate(
              localizedReason: any(named: 'localizedReason'),
              biometricOnly: any(named: 'biometricOnly'),
              persistAcrossBackgrounding: any(
                named: 'persistAcrossBackgrounding',
              ),
            ),
          );
        },
      );
    });

    group('getAuthMethod', () {
      test('returns none when auth not enabled', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => null);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.none);
      });

      test('returns pin when only PIN is configured', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');
        when(
          () => mockStorage.read(key: 'flutty_biometric_enabled'),
        ).thenAnswer((_) async => null);
        when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
          (_) async => jsonEncode({
            'version': 1,
            'iterations': 120000,
            'hash': _validPinHash,
          }),
        );
        when(
          () => mockStorage.read(key: 'flutty_pin_salt'),
        ).thenAnswer((_) async => _validPinSalt);
        when(
          () => mockLocalAuth.isDeviceSupported(),
        ).thenAnswer((_) async => false);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.pin);
      });

      test(
        'throws when auth is enabled but PIN material is partial and biometrics are unavailable',
        () async {
          when(
            () => mockStorage.read(key: 'flutty_auth_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_biometric_enabled'),
          ).thenAnswer((_) async => null);
          when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
            (_) async => jsonEncode({
              'version': 1,
              'iterations': 120000,
              'hash': 'somehash',
            }),
          );
          when(
            () => mockStorage.read(key: 'flutty_pin_salt'),
          ).thenAnswer((_) async => null);
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => false);

          await expectLater(
            authService.getAuthMethod(),
            throwsA(isA<StateError>()),
          );
        },
      );

      test(
        'throws when auth is enabled but the stored PIN salt decodes to an invalid length',
        () async {
          when(
            () => mockStorage.read(key: 'flutty_auth_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_biometric_enabled'),
          ).thenAnswer((_) async => null);
          when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
            (_) async => jsonEncode({
              'version': 1,
              'iterations': 120000,
              'hash': 'somehash',
            }),
          );
          when(
            () => mockStorage.read(key: 'flutty_pin_salt'),
          ).thenAnswer((_) async => '');
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => false);

          await expectLater(
            authService.getAuthMethod(),
            throwsA(isA<StateError>()),
          );
        },
      );

      test(
        'throws when auth is enabled but the stored PIN hash decodes to an invalid length',
        () async {
          when(
            () => mockStorage.read(key: 'flutty_auth_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_biometric_enabled'),
          ).thenAnswer((_) async => null);
          when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
            (_) async => jsonEncode({
              'version': 1,
              'iterations': 120000,
              'hash': _shortPinHash,
            }),
          );
          when(
            () => mockStorage.read(key: 'flutty_pin_salt'),
          ).thenAnswer((_) async => _validPinSalt);
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => false);

          await expectLater(
            authService.getAuthMethod(),
            throwsA(isA<StateError>()),
          );
        },
      );

      test(
        'returns biometric when biometrics work but PIN material is corrupt',
        () async {
          when(
            () => mockStorage.read(key: 'flutty_auth_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_biometric_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_pin_hash'),
          ).thenAnswer((_) async => 'legacy-hash-value');
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.canCheckBiometrics,
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.getAvailableBiometrics(),
          ).thenAnswer((_) async => [BiometricType.fingerprint]);

          final result = await authService.getAuthMethod();

          expect(result, AuthMethod.biometric);
        },
      );

      test(
        'returns biometric when biometrics work but the stored PIN hash decodes to an invalid length',
        () async {
          when(
            () => mockStorage.read(key: 'flutty_auth_enabled'),
          ).thenAnswer((_) async => 'true');
          when(
            () => mockStorage.read(key: 'flutty_biometric_enabled'),
          ).thenAnswer((_) async => 'true');
          when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
            (_) async => jsonEncode({
              'version': 1,
              'iterations': 120000,
              'hash': _shortPinHash,
            }),
          );
          when(
            () => mockStorage.read(key: 'flutty_pin_salt'),
          ).thenAnswer((_) async => _validPinSalt);
          when(
            () => mockLocalAuth.isDeviceSupported(),
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.canCheckBiometrics,
          ).thenAnswer((_) async => true);
          when(
            () => mockLocalAuth.getAvailableBiometrics(),
          ).thenAnswer((_) async => [BiometricType.fingerprint]);

          final result = await authService.getAuthMethod();

          expect(result, AuthMethod.biometric);
        },
      );

      test('returns both when PIN and biometric enabled', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');
        when(
          () => mockStorage.read(key: 'flutty_biometric_enabled'),
        ).thenAnswer((_) async => 'true');
        when(() => mockStorage.read(key: 'flutty_pin_hash')).thenAnswer(
          (_) async => jsonEncode({
            'version': 1,
            'iterations': 120000,
            'hash': _validPinHash,
          }),
        );
        when(
          () => mockStorage.read(key: 'flutty_pin_salt'),
        ).thenAnswer((_) async => _validPinSalt);
        when(
          () => mockLocalAuth.isDeviceSupported(),
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => [BiometricType.fingerprint]);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.both);
      });
    });

    group('changePin', () {
      test('changes PIN when current PIN is correct', () async {
        final storage = <String, String>{};
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          storage[invocation.namedArguments[const Symbol('key')] as String] =
              invocation.namedArguments[const Symbol('value')] as String;
        });
        when(() => mockStorage.read(key: any(named: 'key'))).thenAnswer(
          (invocation) async =>
              storage[invocation.namedArguments[const Symbol('key')]],
        );

        await authService.setupPin('1234');

        final result = await authService.changePin('1234', '5678');

        expect(result, true);
      });

      test('fails when current PIN is incorrect', () async {
        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => 'wronghash');

        final result = await authService.changePin('1234', '5678');

        expect(result, false);
      });
    });
  });
}
