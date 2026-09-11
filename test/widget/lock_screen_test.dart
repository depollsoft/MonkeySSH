// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/lock_screen.dart';

const _shortPinHash = 'AAECAwQFBgcICQoLDA0ODw==';
const _validPinSalt = 'AAECAwQFBgcICQoLDA0ODw==';

class _MockAuthService extends Mock implements AuthService {}

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

class _MockLocalAuthentication extends Mock implements LocalAuthentication {}

class _LockedAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.locked;
}

class _BlockingUnlockAuthStateNotifier extends _LockedAuthStateNotifier {
  final unlockCompleter = Completer<bool>();

  @override
  Future<bool> unlockWithPin(String pin) => unlockCompleter.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LockScreen', () {
    testWidgets('stays fail-closed when auth method lookup throws', (
      tester,
    ) async {
      final authService = _MockAuthService();
      final reportedErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;

      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      when(
        authService.getAuthMethod,
      ).thenThrow(Exception('secure storage unavailable'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(authService),
            authStateProvider.overrideWith(_LockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: LockScreen()),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(reportedErrors, hasLength(1));
      expect(find.text('Retry'), findsOneWidget);
      expect(
        find.text(
          'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
        ),
        findsOneWidget,
      );
      expect(find.text('Unlock'), findsNothing);
      expect(find.text('Use biometrics'), findsNothing);
    });

    testWidgets(
      'retry refreshes auth state when storage recovers without auth configured',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;
        addTearDown(container.dispose);
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        var authEnabledCalls = 0;
        when(authService.isAuthEnabled).thenAnswer((_) async {
          if (authEnabledCalls++ == 0) {
            throw Exception('storage unavailable');
          }
          return false;
        });

        var authMethodCalls = 0;
        when(authService.getAuthMethod).thenAnswer((_) async {
          if (authMethodCalls++ == 0) {
            throw Exception('secure storage unavailable');
          }
          return AuthMethod.none;
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(reportedErrors, hasLength(2));

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.notConfigured);
        expect(find.text('Retry'), findsNothing);
        expect(reportedErrors, hasLength(2));
      },
    );

    testWidgets(
      'keeps retry UI when auth method recovers to none but refresh stays locked',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;
        addTearDown(container.dispose);
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        when(authService.isAuthEnabled).thenAnswer((_) async {
          throw Exception('storage unavailable');
        });

        var authMethodCalls = 0;
        when(authService.getAuthMethod).thenAnswer((_) async {
          if (authMethodCalls++ == 0) {
            throw Exception('secure storage unavailable');
          }
          return AuthMethod.none;
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(reportedErrors, hasLength(2));

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
        expect(reportedErrors, hasLength(3));
      },
    );

    testWidgets(
      'shows retry UI on initial load when state is locked without an auth method',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        addTearDown(container.dispose);

        when(authService.isAuthEnabled).thenAnswer((_) async => true);
        when(
          authService.getAuthMethod,
        ).thenAnswer((_) async => AuthMethod.none);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
      },
    );

    testWidgets(
      'shows retry UI when auth is enabled but PIN material is partial and biometrics are unavailable',
      (tester) async {
        final storage = _MockFlutterSecureStorage();
        final localAuth = _MockLocalAuthentication();
        final authService = AuthService(storage: storage, localAuth: localAuth);
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;

        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        when(() => storage.read(key: any(named: 'key'))).thenAnswer((
          invocation,
        ) async {
          final key = invocation.namedArguments[const Symbol('key')] as String;
          switch (key) {
            case 'flutty_auth_enabled':
              return 'true';
            case 'flutty_biometric_enabled':
              return null;
            case 'flutty_pin_hash':
              return '{"version":1,"iterations":120000,"hash":"somehash"}';
            case 'flutty_pin_salt':
              return null;
            default:
              return null;
          }
        });
        when(localAuth.isDeviceSupported).thenAnswer((_) async => false);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [authServiceProvider.overrideWithValue(authService)],
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(reportedErrors, hasLength(1));
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
      },
    );

    testWidgets(
      'shows retry UI when auth is enabled but PIN hash is decodable with an invalid length',
      (tester) async {
        final storage = _MockFlutterSecureStorage();
        final localAuth = _MockLocalAuthentication();
        final authService = AuthService(storage: storage, localAuth: localAuth);
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;

        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        when(() => storage.read(key: any(named: 'key'))).thenAnswer((
          invocation,
        ) async {
          final key = invocation.namedArguments[const Symbol('key')] as String;
          switch (key) {
            case 'flutty_auth_enabled':
              return 'true';
            case 'flutty_biometric_enabled':
              return null;
            case 'flutty_pin_hash':
              return '{"version":1,"iterations":120000,"hash":"$_shortPinHash"}';
            case 'flutty_pin_salt':
              return _validPinSalt;
            default:
              return null;
          }
        });
        when(localAuth.isDeviceSupported).thenAnswer((_) async => false);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [authServiceProvider.overrideWithValue(authService)],
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(reportedErrors, hasLength(1));
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
      },
    );

    testWidgets('ignores an unlock result after the screen is removed', (
      tester,
    ) async {
      final authService = _MockAuthService();
      final notifier = _BlockingUnlockAuthStateNotifier();

      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(authService),
            authStateProvider.overrideWith(() => notifier),
          ],
          child: const MaterialApp(home: LockScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pump();

      // The router swaps the lock screen out while the unlock is in flight.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      notifier.unlockCompleter.complete(false);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('balances PIN field icon spacing to keep entry centered', (
      tester,
    ) async {
      final authService = _MockAuthService();

      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(authService),
            authStateProvider.overrideWith(_LockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: LockScreen()),
        ),
      );

      await tester.pump();
      await tester.pump();

      final pinField = tester.widget<TextField>(find.byType(TextField));
      final decoration = pinField.decoration!;

      expect(decoration.prefixIcon, isNotNull);
      expect(decoration.suffixIcon, isNotNull);
      expect(decoration.prefixIconConstraints?.minWidth, 48);
      expect(decoration.suffixIconConstraints?.minWidth, 48);
    });
  });
}
