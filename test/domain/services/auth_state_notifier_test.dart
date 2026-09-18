// ignore_for_file: public_member_api_docs, directives_ordering

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';

class _MockAuthService extends Mock implements AuthService {}

void main() {
  late _MockAuthService authService;
  late ProviderContainer container;

  setUp(() {
    authService = _MockAuthService();
    container = ProviderContainer(
      overrides: [authServiceProvider.overrideWithValue(authService)],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('AuthStateNotifier', () {
    test(
      'starts unknown and resolves to locked when auth is enabled',
      () async {
        when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);

        expect(container.read(authStateProvider), AuthState.unknown);

        await pumpEventQueue();

        expect(container.read(authStateProvider), AuthState.locked);
      },
    );

    test(
      'starts unknown and resolves to notConfigured when auth is disabled',
      () async {
        when(() => authService.isAuthEnabled()).thenAnswer((_) async => false);

        expect(container.read(authStateProvider), AuthState.unknown);

        await pumpEventQueue();

        expect(container.read(authStateProvider), AuthState.notConfigured);
      },
    );

    test('fails closed when auth initialization throws', () async {
      final reportedErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      when(() => authService.isAuthEnabled())
          .thenThrow(Exception('storage unavailable'));

      expect(container.read(authStateProvider), AuthState.unknown);

      await pumpEventQueue();

      expect(container.read(authStateProvider), AuthState.locked);
      expect(reportedErrors, hasLength(1));
    });

    test('skip keeps auth unconfigured instead of pseudo-unlocked', () async {
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => false);
      await pumpEventQueue();

      container.read(authStateProvider.notifier).skip();

      expect(container.read(authStateProvider), AuthState.notConfigured);
    });

    test('lock returns to notConfigured when auth is disabled', () async {
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => false);
      await pumpEventQueue();

      await container.read(authStateProvider.notifier).lock();

      expect(container.read(authStateProvider), AuthState.notConfigured);
    });

    test(
      'refresh recovers from fail-closed startup when storage recovers',
      () async {
        var isAuthEnabledCalls = 0;
        when(() => authService.isAuthEnabled()).thenAnswer((_) async {
          if (isAuthEnabledCalls++ == 0) {
            throw Exception('storage unavailable');
          }
          return false;
        });

        expect(container.read(authStateProvider), AuthState.unknown);

        await pumpEventQueue();

        expect(container.read(authStateProvider), AuthState.locked);

        await container.read(authStateProvider.notifier).refresh();

        expect(container.read(authStateProvider), AuthState.notConfigured);
      },
    );

    test('lockForAutoLock locks without re-reading auth storage', () async {
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);
      when(() => authService.verifyPin(any())).thenAnswer((_) async => true);

      container.read(authStateProvider);
      await pumpEventQueue();
      await container.read(authStateProvider.notifier).unlockWithPin('1234');

      clearInteractions(authService);
      container.read(authStateProvider.notifier).lockForAutoLock();

      expect(container.read(authStateProvider), AuthState.locked);
      verifyNever(() => authService.isAuthEnabled());
    });
  });
}
