// ignore_for_file: public_member_api_docs, directives_ordering

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/app/auth_lifecycle_controller.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class _MockAuthService extends Mock implements AuthService {}

void registerAuthLifecycleControllerTests() {
  group('auth_lifecycle_controller', () {
    late _MockAuthService authService;
    late AppDatabase database;
    late ProviderContainer container;
    late DateTime now;

    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() {
      authService = _MockAuthService();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      now = DateTime(2026, 3, 24, 12);

      when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);
      when(() => authService.verifyPin(any())).thenAnswer((_) async => true);

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          authServiceProvider.overrideWithValue(authService),
          secretEncryptionServiceProvider.overrideWithValue(
            SecretEncryptionService.forTesting(),
          ),
          dateTimeNowProvider.overrideWithValue(() => now),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    group('AuthLifecycleController', () {
      test('locks on resume after the auto-lock timeout elapses', () async {
        container.read(authStateProvider);
        await pumpEventQueue();
        await container.read(authStateProvider.notifier).unlockWithPin('1234');

        final controller = container.read(authLifecycleControllerProvider);
        await controller.handleLifecycleStateChanged(AppLifecycleState.paused);

        now = now.add(const Duration(minutes: 5));
        await controller.handleLifecycleStateChanged(AppLifecycleState.resumed);

        expect(container.read(authStateProvider), AuthState.locked);
      });

      test(
        'locks on resume after timing out from an inactive-only transition',
        () async {
          container.read(authStateProvider);
          await pumpEventQueue();
          await container
              .read(authStateProvider.notifier)
              .unlockWithPin('1234');

          final controller = container.read(authLifecycleControllerProvider);
          await controller.handleLifecycleStateChanged(
            AppLifecycleState.inactive,
          );

          now = now.add(const Duration(minutes: 5));
          await controller.handleLifecycleStateChanged(
            AppLifecycleState.resumed,
          );

          expect(container.read(authStateProvider), AuthState.locked);
        },
      );

      test('does not lock on resume before the timeout elapses', () async {
        container.read(authStateProvider);
        await pumpEventQueue();
        await container.read(authStateProvider.notifier).unlockWithPin('1234');

        final controller = container.read(authLifecycleControllerProvider);
        await controller.handleLifecycleStateChanged(AppLifecycleState.hidden);

        now = now.add(const Duration(minutes: 4, seconds: 59));
        await controller.handleLifecycleStateChanged(AppLifecycleState.resumed);

        expect(container.read(authStateProvider), AuthState.unlocked);
      });

      test('treats zero timeout as intentionally disabled', () async {
        container.read(authStateProvider);
        await pumpEventQueue();
        await container.read(authStateProvider.notifier).unlockWithPin('1234');
        await container
            .read(autoLockTimeoutNotifierProvider.notifier)
            .setTimeout(0);

        final controller = container.read(authLifecycleControllerProvider);
        await controller.handleLifecycleStateChanged(AppLifecycleState.paused);

        now = now.add(const Duration(minutes: 30));
        await controller.handleLifecycleStateChanged(AppLifecycleState.resumed);

        expect(container.read(authStateProvider), AuthState.unlocked);
      });

      test('clears repository decrypt caches when auto-locking', () async {
        container.read(authStateProvider);
        await pumpEventQueue();
        await container.read(authStateProvider.notifier).unlockWithPin('1234');

        final hostRepository = container.read(hostRepositoryProvider);
        final keyRepository = container.read(keyRepositoryProvider);

        final hostId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Host',
            hostname: 'host.example.com',
            username: 'user',
            password: const Value('host-secret'),
          ),
        );
        final keyId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: 'key-secret',
            passphrase: const Value('passphrase-secret'),
          ),
        );

        await hostRepository.getById(hostId);
        await keyRepository.getById(keyId);
        expect(hostRepository.debugDecryptionCacheSize, 1);
        expect(keyRepository.debugDecryptionCacheSize, 2);

        final controller = container.read(authLifecycleControllerProvider);
        await controller.handleLifecycleStateChanged(AppLifecycleState.paused);
        now = now.add(const Duration(minutes: 5));
        await controller.handleLifecycleStateChanged(AppLifecycleState.resumed);

        expect(container.read(authStateProvider), AuthState.locked);
        expect(hostRepository.debugDecryptionCacheSize, 0);
        expect(keyRepository.debugDecryptionCacheSize, 0);
      });
    });
  });
}
