// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/hardware_key.dart';
import 'package:monkeyssh/domain/services/hardware_key_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';

import '../../helpers/fake_hardware_key_platform.dart';
import '../../helpers/ssh_key_fixtures.dart';

const _fastArgon2idProfile = TransferArgon2idProfile(
  iterations: 1,
  memoryKiB: 8192,
);

void main() {
  late AppDatabase db;
  late HostRepository hostRepository;
  late KeyRepository keyRepository;
  late KeyService keyService;
  late SecureTransferService transferService;
  late FakeHardwareKeyPlatform platform;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final encryptionService = SecretEncryptionService.forTesting();
    hostRepository = HostRepository(db, encryptionService);
    keyRepository = KeyRepository(db, encryptionService);
    platform = FakeHardwareKeyPlatform();
    keyService = KeyService(
      keyRepository,
      hardwareKeyService: HardwareKeyService(
        platform: platform,
        isPlatformSupported: true,
      ),
    );
    transferService = SecureTransferService(
      db,
      keyRepository,
      hostRepository,
      argon2idProfile: _fastArgon2idProfile,
    );
  });

  tearDown(() => db.close());

  Future<SshKey> hardwareKey() async => (await keyService.generateHardwareKey(
    name: 'Phone key',
    requireUserPresence: false,
  ))!;

  Future<SshKey> softwareKey() async => (await keyService.importKey(
    name: 'Laptop key',
    privateKeyPem: sshEd25519PrivateKey,
  ))!;

  Future<Host> host({required int keyId, String label = 'Server'}) async {
    final id = await hostRepository.insert(
      HostsCompanion.insert(
        label: label,
        hostname: 'example.com',
        username: 'demo',
        keyId: Value(keyId),
      ),
    );
    return (await hostRepository.getById(id))!;
  }

  Future<TransferPayload> decrypt(String encoded) => transferService
      .decryptPayload(encodedPayload: encoded, transferPassphrase: 'pass');

  test('refuses to export a hardware-backed key', () async {
    final key = await hardwareKey();

    await expectLater(
      transferService.createKeyPayload(key: key, transferPassphrase: 'pass'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          hardwareKeyExportBlockedMessage,
        ),
      ),
    );
  });

  test('exports a host without its hardware-backed key', () async {
    final key = await hardwareKey();
    final original = await host(keyId: key.id);

    final payload = await decrypt(
      await transferService.createHostPayload(
        host: original,
        transferPassphrase: 'pass',
        includeReferencedKey: true,
      ),
    );

    expect(payload.data['referencedKey'], isNull);
    expect((payload.data['host'] as Map)['keyId'], isNull);
    expect(
      payload.data.toString(),
      isNot(contains(HardwareKeyReference.prefix)),
    );
  });

  test(
    'migration data leaves hardware keys and their references out',
    () async {
      final software = await softwareKey();
      final hardware = await hardwareKey();
      await host(keyId: software.id, label: 'Software');
      await host(keyId: hardware.id, label: 'Hardware');

      final data = await transferService.createMigrationData();

      final keys = (data['keys'] as List).cast<Map<String, dynamic>>();
      expect(keys.map((key) => key['id']), [software.id]);
      final hosts = {
        for (final item in (data['hosts'] as List).cast<Map<String, dynamic>>())
          item['label']: item['keyId'],
      };
      expect(hosts, {'Software': software.id, 'Hardware': null});
      expect(data.toString(), isNot(contains(HardwareKeyReference.prefix)));

      final encoded = await transferService.createFullMigrationPayload(
        transferPassphrase: 'pass',
      );
      final payload = await decrypt(encoded);
      expect((payload.data['keys'] as List).map((key) => (key as Map)['id']), [
        software.id,
      ]);
    },
  );

  test('rejects payloads that smuggle a hardware key reference', () async {
    final key = await hardwareKey();
    final payload = TransferPayload(
      type: TransferPayloadType.key,
      schemaVersion: 1,
      createdAt: DateTime.utc(2026),
      data: {'key': key.toJson()},
    );

    await expectLater(
      transferService.importKeyPayload(payload),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('hardware-backed'),
        ),
      ),
    );
    expect(await keyRepository.getAll(), hasLength(1));
  });

  test('a replacing import keeps this device’s hardware keys', () async {
    final hardware = await hardwareKey();
    await softwareKey();
    final imported = {
      'keys': [
        {
          'id': 77,
          'name': 'Imported key',
          'keyType': 'ssh-ed25519',
          'publicKey': 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwEkW+K+T0BVhCHT/6o4p9FdlaUJD/yPJfHziYQuwnK a',
          'privateKey': '',
        },
      ],
    };

    await transferService.importMigrationData(
      data: imported,
      mode: MigrationImportMode.replace,
    );

    final keys = await keyRepository.getAll();
    expect(keys.map((key) => key.name).toSet(), {'Phone key', 'Imported key'});
    final kept = keys.singleWhere((key) => key.id == hardware.id);
    expect(
      kept.hardwareKeyReference!.alias,
      hardware.hardwareKeyReference!.alias,
    );
    expect(platform.deletedAliases, isEmpty);
  });
}
