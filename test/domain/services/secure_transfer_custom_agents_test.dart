// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase db;
  late SecureTransferService transfer;
  late AcpCustomProviderService customProviders;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final encryption = SecretEncryptionService.forTesting();
    transfer = SecureTransferService(
      db,
      KeyRepository(db, encryption),
      HostRepository(db, encryption),
    );
    customProviders = AcpCustomProviderService(SettingsService(db));
  });

  tearDown(() => db.close());

  AcpCustomProviderDefinition goose({List<String> arguments = const ['acp']}) =>
      AcpCustomProviderDefinition.create(
        id: 'goose',
        label: 'Goose',
        launchCommand: AcpLaunchCommand(
          executable: 'goose',
          arguments: arguments,
        ),
      );

  Map<String, dynamic> migrationWith(List<AcpCustomProviderDefinition> list) =>
      {
        'settings': {
          SettingKeys.acpCustomProviders: jsonEncode([
            for (final definition in list) definition.toJson(),
          ]),
        },
      };

  for (final mode in MigrationImportMode.values) {
    test(
      'a migration import never carries approvals in (${mode.name})',
      () async {
        // The payload claims approval for a command this device never saw.
        final forged = goose(arguments: const ['acp', '--yolo']).approve();
        expect(forged.isCommandApproved, isTrue);

        await transfer.importMigrationData(
          data: migrationWith([forged]),
          mode: mode,
        );

        final stored = await customProviders.listCustomProviders();
        expect(stored.single.id, 'goose');
        expect(stored.single.isCommandApproved, isFalse);
      },
    );

    test('a migration import keeps this device\'s approval for an identical '
        'agent (${mode.name})', () async {
      final local = await customProviders.create(
        label: 'Goose',
        launchCommand: AcpLaunchCommand(
          executable: 'goose',
          arguments: const ['acp'],
        ),
      );
      await customProviders.approve(
        local.id,
        reviewedFingerprint: local.fingerprint,
      );
      final data = await transfer.createMigrationData();

      await transfer.importMigrationData(data: data, mode: mode);

      final stored = await customProviders.listCustomProviders();
      expect(stored.single.isCommandApproved, isTrue);
    });
  }
}
