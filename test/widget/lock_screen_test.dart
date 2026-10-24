// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/lock_screen.dart';

import '../helpers/mocks.dart';

const _shortPinHash = 'AAECAwQFBgcICQoLDA0ODw==';
const _validPinSalt = 'AAECAwQFBgcICQoLDA0ODw==';

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
      final authService = MockAuthService();
      final reportedErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;

      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      when(authService.getAuthMethod)
          .thenThrow(Exception('secure storage unavailable'));

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
        final authService = MockAuthService();
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
        final authService = MockAuthService();
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
        final authService = MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        addTearDown(container.dispose);

        when(authService.isAuthEnabled).thenAnswer((_) async => true);
        when(authService.getAuthMethod)
            .thenAnswer((_) async => AuthMethod.none);

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
        final storage = MockFlutterSecureStorage();
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
        final storage = MockFlutterSecureStorage();
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
      final authService = MockAuthService();
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

    for (final (name, size, fold) in [
      (
        'held like a book',
        const Size(951, 669),
        const Rect.fromLTWH(475, 0, 0, 669),
      ),
      ('propped up', const Size(669, 951), const Rect.fromLTWH(0, 475, 669, 0)),
    ]) {
      testWidgets('keeps the brand and the PIN on their own pages $name', (
        tester,
      ) async {
        final authService = MockAuthService();
        when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1
          ..displayFeatures = [
            DisplayFeature(
              bounds: fold,
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ];
        addTearDown(tester.view.reset);

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

        final icon = tester.getRect(find.byType(Image));
        final pin = tester.getRect(find.byType(TextField));
        final unlock = tester.getRect(find.text('Unlock'));
        if (fold.width == 0) {
          expect(icon.right, lessThanOrEqualTo(fold.left));
          expect(pin.left, greaterThanOrEqualTo(fold.right));
          expect(unlock.left, greaterThanOrEqualTo(fold.right));
        } else {
          expect(icon.bottom, lessThanOrEqualTo(fold.top));
          expect(pin.top, greaterThanOrEqualTo(fold.bottom));
          expect(unlock.top, greaterThanOrEqualTo(fold.bottom));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('keeps Unlock above the fold when the keyboard stops short '
        'of it', (tester) async {
      final authService = MockAuthService();
      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
      tester.view
        ..physicalSize = const Size(669, 951)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(top: 82)
        ..viewInsets = const FakeViewPadding(bottom: 360)
        ..displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTRB(0, 455.5, 669, 495.5),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ];
      addTearDown(tester.view.reset);

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

      // The keyboard leaves too little of the bottom page, so the PIN keeps
      // to the top page, clear of the fold and in view without scrolling.
      expect(find.text('Unlock').hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byType(TextField)).top, greaterThan(82));
      expect(tester.getRect(find.text('Unlock')).bottom, lessThan(455.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('gives the PIN the top page when the keyboard takes the '
        'bottom page', (tester) async {
      // iPhone Duo propped up: a 40 pt fold band, and a keyboard that covers
      // the whole bottom page up to the fold, as the iOS 27.1 simulator
      // reports them.
      final authService = MockAuthService();
      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
      tester.view
        ..physicalSize = const Size(669, 951)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(top: 82, bottom: 34)
        ..displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTRB(0, 455.5, 669, 495.5),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ];
      addTearDown(tester.view.reset);

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
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final field = tester.state<EditableTextState>(find.byType(EditableText));

      tester.view
        ..padding = const FakeViewPadding(top: 82)
        ..viewInsets = const FakeViewPadding(bottom: 495.5);
      await tester.pump();
      await tester.pump();

      // The number pad has no Return key, so Unlock must show without
      // scrolling; the brand gives way to make room.
      expect(find.byType(Image), findsNothing);
      expect(find.text('Unlock').hitTestable(), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(tester.getRect(find.text('Unlock')).bottom, lessThan(455.5));
      expect(tester.getRect(find.byType(TextField)).top, greaterThan(82));
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(field),
      );
      expect(field.widget.focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the brand above a keyboard that leaves room', (
      tester,
    ) async {
      final authService = MockAuthService();
      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(top: 62)
        ..viewInsets = const FakeViewPadding(bottom: 291);
      addTearDown(tester.view.reset);

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

      expect(find.byType(Image), findsOneWidget);
      expect(tester.getRect(find.text('Unlock')).bottom, lessThan(874 - 291));
    });

    testWidgets('falls back to one page when the keyboard covers the PIN '
        'page', (tester) async {
      final authService = MockAuthService();
      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
      tester.view
        ..physicalSize = const Size(951, 669)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 360)
        ..displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 334, 951, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ];
      addTearDown(tester.view.reset);

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

      await tester.ensureVisible(find.text('Unlock'));
      await tester.pump();
      expect(
        tester.getRect(find.text('Unlock')).bottom,
        lessThanOrEqualTo(669 - 360),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the PIN field focused as the keyboard folds the '
        'spread into one page', (tester) async {
      final authService = MockAuthService();
      when(authService.getAuthMethod).thenAnswer((_) async => AuthMethod.pin);
      tester.view
        ..physicalSize = const Size(669, 951)
        ..devicePixelRatio = 1
        ..displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 475, 669, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ];
      addTearDown(tester.view.reset);

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
      expect(
        tester.getRect(find.byType(TextField)).top,
        greaterThanOrEqualTo(475),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      final field = tester.state<EditableTextState>(find.byType(EditableText));
      expect(field.widget.focusNode.hasFocus, isTrue);

      // The keyboard rises over the bottom page and the screen becomes one
      // page; the same field keeps focus and its input connection.
      tester.view.viewInsets = const FakeViewPadding(bottom: 360);
      await tester.pump();
      await tester.pump();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(field),
      );
      expect(field.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(
        tester.getRect(find.byType(TextField)).bottom,
        lessThanOrEqualTo(951 - 360),
      );
    });

    testWidgets('balances PIN field icon spacing to keep entry centered', (
      tester,
    ) async {
      final authService = MockAuthService();

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
