// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/biometric_prompt_coordinator.dart';

import '../../helpers/mocks.dart';

class _MockLocalAuthentication extends Mock implements LocalAuthentication {}

class _MockAuthService extends Mock implements AuthService {}

void main() {
  tearDown(
    () => BiometricPromptCoordinator.instance.setAppLocked(locked: false),
  );

  test('runs prompts one at a time, in order', () async {
    final coordinator = BiometricPromptCoordinator();
    final events = <String>[];
    final firstDone = Completer<void>();

    final first = coordinator.run(() async {
      events.add('first start');
      await firstDone.future;
      events.add('first end');
    });
    final second = coordinator.run(() async => events.add('second'));
    await pumpEventQueue();
    expect(events, ['first start']);

    firstDone.complete();
    await Future.wait([first, second]);
    expect(events, ['first start', 'first end', 'second']);
  });

  test('a failed prompt releases the next one', () async {
    final coordinator = BiometricPromptCoordinator();
    await expectLater(
      coordinator.run<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(await coordinator.run(() async => 7), 7);
  });

  test('waits while the app lock is up', () async {
    final coordinator = BiometricPromptCoordinator()
      ..setAppLocked(locked: true);
    var unlocked = false;
    unawaited(coordinator.waitUntilAppUnlocked().then((_) => unlocked = true));
    await pumpEventQueue();
    expect(unlocked, isFalse);

    coordinator.setAppLocked(locked: false);
    await pumpEventQueue();
    expect(unlocked, isTrue);
  });

  test('the app lock prompt waits for a hardware key prompt', () async {
    final storage = MockFlutterSecureStorage();
    final localAuth = _MockLocalAuthentication();
    when(() => localAuth.canCheckBiometrics).thenAnswer((_) async => true);
    when(localAuth.getAvailableBiometrics)
        .thenAnswer((_) async => [BiometricType.face]);
    when(
      () => localAuth.authenticate(
        localizedReason: any(named: 'localizedReason'),
        biometricOnly: any(named: 'biometricOnly'),
        persistAcrossBackgrounding: any(named: 'persistAcrossBackgrounding'),
      ),
    ).thenAnswer((_) async => true);
    final service = AuthService(storage: storage, localAuth: localAuth);
    final hardwarePrompt = Completer<void>();
    final holding = BiometricPromptCoordinator.instance.run(
      () => hardwarePrompt.future,
    );

    final unlocking = service.authenticateWithBiometrics(reason: 'Unlock');
    await pumpEventQueue();
    verifyNever(
      () => localAuth.authenticate(
        localizedReason: any(named: 'localizedReason'),
        biometricOnly: any(named: 'biometricOnly'),
        persistAcrossBackgrounding: any(named: 'persistAcrossBackgrounding'),
      ),
    );

    hardwarePrompt.complete();
    await holding;
    expect(await unlocking, isTrue);
  });

  test('the lock state reaches the coordinator', () async {
    final authService = _MockAuthService();
    when(authService.isAuthEnabled).thenAnswer((_) async => true);
    when(() => authService.verifyPin(any())).thenAnswer((_) async => true);
    final container = ProviderContainer(
      overrides: [authServiceProvider.overrideWithValue(authService)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(authStateProvider, (_, _) {});
    addTearDown(subscription.close);
    final coordinator = BiometricPromptCoordinator.instance;

    await pumpEventQueue();
    expect(container.read(authStateProvider), AuthState.locked);
    expect(coordinator.isAppLocked, isTrue);

    await container.read(authStateProvider.notifier).unlockWithPin('1234');
    expect(coordinator.isAppLocked, isFalse);

    container.read(authStateProvider.notifier).lockForAutoLock();
    expect(coordinator.isAppLocked, isTrue);

    container.dispose();
    expect(coordinator.isAppLocked, isFalse);
  });
}
