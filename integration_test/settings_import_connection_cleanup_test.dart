// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/background_ssh_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';
import 'package:monkeyssh/presentation/screens/settings_screen.dart';

import '../test/helpers/mocks.dart';
import '../test/support/settings_import_test_helpers.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

class _FakeActiveSessionsSshService extends SshService {
  final Map<int, SshSession> _sessions = {};
  final Map<int, Completer<void>> _clientDoneCompleters = {};
  int _nextConnectionId = 1;

  @override
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  @override
  Iterable<SshSession> get allSessions => _sessions.values;

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    final connectionId = _nextConnectionId++;
    final client = MockSshClient();
    final clientDoneCompleter = Completer<void>();
    _clientDoneCompleters[connectionId] = clientDoneCompleter;
    when(() => client.done).thenAnswer((_) => clientDoneCompleter.future);
    final session = SshSession(
      connectionId: connectionId,
      hostId: hostId,
      client: client,
      config: SshConnectionConfig(
        hostname: 'host-$hostId.example.com',
        port: 22,
        username: 'tester',
      ),
    );
    _sessions[connectionId] = session;
    return SshConnectionResult(success: true, connectionId: connectionId);
  }

  @override
  Future<void> disconnect(int connectionId) async {
    _sessions.remove(connectionId);
    _clientDoneCompleters.remove(connectionId);
  }

  @override
  Future<void> disconnectAll() async {
    _sessions.clear();
    _clientDoneCompleters.clear();
  }

  @override
  SshSession? getSession(int connectionId) => _sessions[connectionId];
}

Widget _buildScreen({
  required ProviderContainer container,
  required Widget child,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(home: child),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'replace import clears stale connections before returning to HomeScreen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      BackgroundSshService.debugIsSupportedPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (_) async => null);
      addTearDown(() async {
        BackgroundSshService.debugIsSupportedPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_backgroundSshChannel, null);
      });

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepository = HostRepository(db, encryptionService);
      final keyRepository = KeyRepository(db, encryptionService);
      final originalHostId = await hostRepository.insert(
        HostsCompanion.insert(
          label: 'Current Host',
          hostname: 'current.example.com',
          username: 'tester',
        ),
      );

      final sourceDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(sourceDb.close);
      final sourceEncryptionService = SecretEncryptionService.forTesting();
      final sourceHostRepository = HostRepository(
        sourceDb,
        sourceEncryptionService,
      );
      final sourceKeyRepository = KeyRepository(
        sourceDb,
        sourceEncryptionService,
      );
      await sourceHostRepository.insert(
        HostsCompanion.insert(
          label: 'Imported Host',
          hostname: 'imported.example.com',
          username: 'importer',
        ),
      );
      final sourceTransferService = SecureTransferService(
        sourceDb,
        sourceKeyRepository,
        sourceHostRepository,
      );
      final encodedPayload = await sourceTransferService
          .createFullMigrationPayload(transferPassphrase: '1234');

      setFakeFilePickerResult(
        result: [
          AppPlatformFile(
            name: 'migration.monkeysshx',
            size: encodedPayload.length,
            bytes: Uint8List.fromList(utf8.encode(encodedPayload)),
          ),
        ],
      );

      final fakeSshService = _FakeActiveSessionsSshService();
      final transferService = SecureTransferService(
        db,
        keyRepository,
        hostRepository,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretEncryptionServiceProvider.overrideWithValue(encryptionService),
          authServiceProvider.overrideWithValue(FakeAuthService()),
          authStateProvider.overrideWith(MockAuthStateNotifier.new),
          sshServiceProvider.overrideWithValue(fakeSshService),
          secureTransferServiceProvider.overrideWithValue(transferService),
          themeModeNotifierProvider.overrideWith(StaticThemeModeNotifier.new),
          fontSizeNotifierProvider.overrideWith(StaticFontSizeNotifier.new),
          fontFamilyNotifierProvider.overrideWith(StaticFontFamilyNotifier.new),
          cursorStyleNotifierProvider.overrideWith(
            StaticCursorStyleNotifier.new,
          ),
          bellSoundNotifierProvider.overrideWith(StaticBellSoundNotifier.new),
          terminalThemeSettingsProvider.overrideWith(
            StaticTerminalThemeSettingsNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _buildScreen(container: container, child: const HomeScreen()),
      );
      await tester.pumpAndSettle();

      final connectResult = await container
          .read(activeSessionsProvider.notifier)
          .connect(originalHostId, forceNew: true);
      expect(connectResult.success, isTrue);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connections'));
      await tester.pumpAndSettle();
      expect(find.text('Current Host'), findsOneWidget);

      await tester.pumpWidget(
        _buildScreen(container: container, child: const SettingsScreen()),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Import migration package'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Import migration package'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, '1234');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _buildScreen(container: container, child: const HomeScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Imported Host'), findsOneWidget);

      await tester.tap(find.text('Connections'));
      await tester.pumpAndSettle();

      expect(find.text('No active connections'), findsOneWidget);
      expect(find.text('Host $originalHostId'), findsNothing);
    },
  );
}
