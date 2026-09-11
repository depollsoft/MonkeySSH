// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';

import '../test/support/settings_import_test_helpers.dart';

Widget _buildApp(ProviderContainer container) =>
    UncontrolledProviderScope(container: container, child: const FluttyApp());

Future<void> _openSettings(WidgetTester tester) async {
  final settingsLabel = find.text('Settings');
  if (settingsLabel.evaluate().isNotEmpty) {
    await tester.tap(settingsLabel.first);
  } else {
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
  }
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final testCase in const [
    (name: 'mounted', size: Size(400, 1400), checkConnections: false),
    (name: 'wide', size: Size(1200, 900), checkConnections: true),
  ]) {
    testWidgets(
      'replace import refreshes the ${testCase.name} home screen after returning from settings',
      (tester) async {
        await tester.binding.setSurfaceSize(testCase.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService();
        final hostRepository = HostRepository(db, encryptionService);
        final keyRepository = KeyRepository(db, encryptionService);
        await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Current Host',
            hostname: 'current.example.com',
            username: 'tester',
            password: const Value('before-import'),
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
            password: const Value('hunter2'),
          ),
        );
        final sourceTransferService = SecureTransferService(
          sourceDb,
          sourceKeyRepository,
          sourceHostRepository,
        );
        final encodedPayload = await sourceTransferService
            .createFullMigrationPayload(transferPassphrase: '1234');

        final transferService = SecureTransferService(
          db,
          keyRepository,
          hostRepository,
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            secureTransferServiceProvider.overrideWithValue(transferService),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_buildApp(container));
        await tester.pumpAndSettle();

        expect(find.text('Current Host'), findsOneWidget);

        await _openSettings(tester);

        final payload = await transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: '1234',
        );
        await transferService.importFullMigrationPayload(
          payload: payload,
          mode: MigrationImportMode.replace,
        );
        container
          ..invalidate(themeModeNotifierProvider)
          ..invalidate(fontSizeNotifierProvider)
          ..invalidate(fontFamilyNotifierProvider)
          ..invalidate(cursorStyleNotifierProvider)
          ..invalidate(bellSoundNotifierProvider)
          ..invalidate(sharedClipboardNotifierProvider)
          ..invalidate(sharedClipboardProvider)
          ..invalidate(terminalThemeSettingsProvider);
        invalidateImportedEntityProviders(container.invalidate);
        await tester.pumpAndSettle();

        await tester.pageBack();
        await tester.pumpAndSettle();

        final storedHosts = await hostRepository.getAll();
        expect(
          storedHosts.map((host) => host.label),
          isNot(contains('Current Host')),
        );
        expect(
          storedHosts.map((host) => host.label),
          contains('Imported Host'),
        );

        final hostsState = container.read(allHostsProvider);
        expect(hostsState.hasValue, isTrue);
        expect(
          hostsState.asData?.value.map((host) => host.label).toList(),
          contains('Imported Host'),
        );

        expect(find.text('Imported Host'), findsOneWidget);

        if (testCase.checkConnections) {
          await tester.tap(find.text('Connections').first);
          await tester.pumpAndSettle();
          expect(find.text('No active connections'), findsOneWidget);
        }
      },
    );
  }
}
