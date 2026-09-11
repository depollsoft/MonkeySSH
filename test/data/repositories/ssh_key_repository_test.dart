// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';

import '../../helpers/pausing_secret_encryption_service.dart';

void main() {
  late AppDatabase db;
  late KeyRepository repository;
  late SecretEncryptionService encryptionService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    repository = KeyRepository(db, encryptionService);
  });

  tearDown(() async {
    await db.close();
  });

  group('KeyRepository', () {
    test('getAll returns empty list initially', () async {
      final keys = await repository.getAll();
      expect(keys, isEmpty);
    });

    test('insert creates a new key', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'My Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'fixture-open-ssh-material...',
          fingerprint: const Value('SHA256:DE:AD:BE:EF'),
        ),
      );

      expect(id, greaterThan(0));

      final keys = await repository.getAll();
      expect(keys, hasLength(1));
      expect(keys.first.name, 'My Key');
      expect(keys.first.keyType, 'ed25519');
      expect(keys.first.id, id);
      expect(keys.first.publicKey, 'ssh-ed25519 AAAA...');
      expect(keys.first.privateKey, 'fixture-open-ssh-material...');
      expect(keys.first.fingerprint, 'SHA256:DE:AD:BE:EF');
    });

    test('insert encrypts private key and passphrase at rest', () async {
      const privateKey = 'fixture-open-ssh-material...';
      const passphrase = 'my-passphrase';
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Encrypted Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: privateKey,
          passphrase: const Value(passphrase),
        ),
      );

      final storedKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(storedKey.privateKey, isNot(privateKey));
      expect(storedKey.privateKey, startsWith('ENCv1:'));
      expect(storedKey.passphrase, isNot(passphrase));
      expect(storedKey.passphrase, startsWith('ENCv1:'));

      final key = await repository.getById(id);
      expect(key!.privateKey, privateKey);
      expect(key.passphrase, passphrase);
    });

    test('getById migrates legacy plaintext key secrets', () async {
      const privateKey = 'legacy-open-ssh-material...';
      const passphrase = 'legacy-passphrase';
      final id = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Legacy Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAA...',
              privateKey: privateKey,
              passphrase: const Value(passphrase),
            ),
          );

      final key = await repository.getById(id);
      expect(key!.privateKey, privateKey);
      expect(key.passphrase, passphrase);

      final storedKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(storedKey.privateKey, startsWith('ENCv1:'));
      expect(storedKey.privateKey, isNot(privateKey));
      expect(storedKey.passphrase, startsWith('ENCv1:'));
      expect(storedKey.passphrase, isNot(passphrase));

      final migratedKey = await repository.getById(id);
      expect(migratedKey!.privateKey, privateKey);
      expect(migratedKey.passphrase, passphrase);
    });

    for (final corruption in ['malformed envelope', 'wrong key']) {
      for (final damagedField in ['privateKey', 'passphrase', 'both']) {
        test('$corruption in $damagedField recovers per field', () async {
          final diagnostics = DiagnosticsLogService(enabled: true);
          addTearDown(diagnostics.dispose);
          repository = KeyRepository(
            db,
            encryptionService,
            diagnosticsLog: diagnostics,
          );
          final otherEncryptionService = SecretEncryptionService.forTesting(
            masterKey: List<int>.filled(32, 255),
          );
          final corruptPrivateKey = corruption == 'malformed envelope'
              ? 'ENCv1:not-a-valid-key-envelope'
              : await otherEncryptionService.encryptRequired(
                  'lost-private-key',
                );
          final corruptPassphrase = corruption == 'malformed envelope'
              ? 'ENCv1:not-a-valid-passphrase-envelope'
              : await otherEncryptionService.encryptRequired('lost-passphrase');
          final privateKeyUnreadable = damagedField != 'passphrase';
          final passphraseUnreadable = damagedField != 'privateKey';
          final storedPrivateKey = privateKeyUnreadable
              ? corruptPrivateKey
              : await encryptionService.encryptRequired('readable-private-key');
          final storedPassphrase = passphraseUnreadable
              ? corruptPassphrase
              : await encryptionService.encryptRequired('readable-passphrase');
          final id = await db
              .into(db.sshKeys)
              .insert(
                SshKeysCompanion.insert(
                  name: 'Damaged Key',
                  keyType: 'ed25519',
                  publicKey: 'ssh-ed25519 AAAA...',
                  privateKey: storedPrivateKey,
                  passphrase: Value(storedPassphrase),
                ),
              );
          final healthyId = await repository.insert(
            SshKeysCompanion.insert(
              name: 'Healthy Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 BBBB...',
              privateKey: 'healthy-private-key',
              passphrase: const Value('healthy-passphrase'),
            ),
          );

          void expectDamagedKey(SshKey key) {
            expect(key.id, id);
            expect(
              key.privateKey,
              privateKeyUnreadable ? '' : 'readable-private-key',
            );
            expect(
              key.passphrase,
              passphraseUnreadable ? null : 'readable-passphrase',
            );
            expect(
              repository.hasUnreadablePrivateKey(id),
              privateKeyUnreadable,
            );
            expect(
              repository.hasUnreadablePassphrase(id),
              passphraseUnreadable,
            );
          }

          final key = (await repository.getById(id))!;
          expectDamagedKey(key);
          for (final keys in [
            await repository.getAll(),
            await repository.watchAll().first,
          ]) {
            expect(keys, hasLength(2));
            expectDamagedKey(keys.firstWhere((key) => key.id == id));
            final healthy = keys.firstWhere((key) => key.id == healthyId);
            expect(healthy.privateKey, 'healthy-private-key');
            expect(healthy.passphrase, 'healthy-passphrase');
          }
          final result = await repository.getAllDecryptable();
          expect(result.keys, hasLength(2));
          expectDamagedKey(result.keys.firstWhere((key) => key.id == id));
          expect(result.unreadableCount, 1);
          expect(result.firstUnreadableErrorType, 'FormatException');
          expect(repository.hasUnreadablePrivateKey(healthyId), isFalse);
          expect(repository.hasUnreadablePassphrase(healthyId), isFalse);

          // Locking must not discard recovery markers or allow a metadata save
          // to erase ciphertext. Both null and empty passphrases preserve it.
          repository.clearDecryptionCache();
          expect(repository.debugDecryptionCacheSize, 0);
          expectDamagedKey(key);
          expect(
            await repository.update(key.copyWith(name: 'Renamed Key')),
            isTrue,
          );
          if (passphraseUnreadable) {
            expect(
              await repository.update(
                key.copyWith(name: 'Renamed Key', passphrase: const Value('')),
              ),
              isTrue,
            );
          }
          repository.clearDecryptionCache();
          expectDamagedKey((await repository.getById(id))!);
          final stored = await (db.select(
            db.sshKeys,
          )..where((key) => key.id.equals(id))).getSingle();
          expect(stored.name, 'Renamed Key');
          if (privateKeyUnreadable) {
            expect(stored.privateKey, storedPrivateKey);
          } else {
            expect(
              await encryptionService.decryptNullable(stored.privateKey),
              'readable-private-key',
            );
          }
          if (passphraseUnreadable) {
            expect(stored.passphrase, storedPassphrase);
          } else {
            expect(
              await encryptionService.decryptNullable(stored.passphrase),
              'readable-passphrase',
            );
          }
          final entries = diagnostics.snapshot();
          expect(entries, hasLength(1));
          expect(entries.single.category, 'key.secrets');
          expect(entries.single.message, 'secret_decryption_failed');
          expect(entries.single.fields, {
            'keyId': id,
            'errorType': 'FormatException',
          });
          expect(diagnostics.exportText(), isNot(contains(corruptPrivateKey)));
          expect(diagnostics.exportText(), isNot(contains(corruptPassphrase)));
          expect(diagnostics.exportText(), isNot(contains('Damaged Key')));

          // Repairing one field must preserve the other field's ciphertext and
          // diagnostic suppression until it too is repaired.
          expect(
            await repository.update(
              key.copyWith(privateKey: 'replacement-key'),
            ),
            isTrue,
          );
          repository.clearDecryptionCache();
          final partiallyRepaired = (await repository.getById(id))!;
          expect(partiallyRepaired.privateKey, 'replacement-key');
          expect(repository.hasUnreadablePrivateKey(id), isFalse);
          expect(repository.hasUnreadablePassphrase(id), passphraseUnreadable);
          expect(diagnostics.snapshot(), hasLength(1));
          expect(
            await repository.update(
              partiallyRepaired.copyWith(
                passphrase: const Value('replacement-passphrase'),
              ),
            ),
            isTrue,
          );
          repository.clearDecryptionCache();
          final repaired = (await repository.getById(id))!;
          expect(repaired.privateKey, 'replacement-key');
          expect(repaired.passphrase, 'replacement-passphrase');
          expect(repository.hasUnreadablePassphrase(id), isFalse);
          expect((await repository.getAllDecryptable()).unreadableCount, 0);
          expect(diagnostics.snapshot(), hasLength(1));
        });
      }
    }

    test('new secrets may literally start with the envelope prefix', () async {
      const privateKey = 'ENCv1:not-a-valid-key-envelope';
      const passphrase = 'ENCv1:not-a-valid-passphrase-envelope';
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'New Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: privateKey,
          passphrase: const Value(passphrase),
        ),
      );
      final key = (await repository.getById(id))!;
      expect(key.privateKey, privateKey);
      expect(key.passphrase, passphrase);
      expect(repository.hasUnreadablePrivateKey(id), isFalse);
      expect(repository.hasUnreadablePassphrase(id), isFalse);
    });

    test('legacy key migration does not overwrite newer writes', () async {
      final encryptionService = PausingSecretEncryptionService(
        pausePlaintext: 'legacy-open-ssh-material...',
      );
      repository = KeyRepository(db, encryptionService);
      final id = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Legacy Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAA...',
              privateKey: 'legacy-open-ssh-material...',
            ),
          );

      final pendingRead = repository.getById(id);
      await encryptionService.paused;
      final newerEncryptedPrivateKey = await encryptionService.encryptNullable(
        'newer-open-ssh-material...',
      );
      await (db.update(db.sshKeys)..where((k) => k.id.equals(id))).write(
        SshKeysCompanion(privateKey: Value(newerEncryptedPrivateKey!)),
      );
      encryptionService.resume();

      final key = await pendingRead;
      expect(key!.privateKey, 'legacy-open-ssh-material...');

      final storedKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      await expectLater(
        encryptionService.decryptNullable(storedKey.privateKey),
        completion('newer-open-ssh-material...'),
      );
    });

    test('getById returns key when exists', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Test Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa AAAA...',
          privateKey: 'fixture-rsa-material...',
        ),
      );

      final key = await repository.getById(id);

      expect(key, isNotNull);
      expect(key!.id, id);
      expect(key.name, 'Test Key');
      expect(key.keyType, 'rsa');
    });

    test('getById returns null when not exists', () async {
      final key = await repository.getById(999);
      expect(key, isNull);
    });

    test('insert does not double-encrypt a pre-encrypted private key', () async {
      const privateKey = 'fixture-open-ssh-material...';
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: privateKey,
        ),
      );

      // Read the raw stored row (private key already encrypted by insert).
      final rawKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(rawKey.privateKey, startsWith('ENCv1:'));
      final storedEncryptedPrivKey = rawKey.privateKey;

      // Reinsert the encrypted row to verify that valid envelopes are preserved.
      await repository.delete(id);
      await repository.insert(rawKey.toCompanion(true));

      final afterInsert = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(afterInsert.privateKey, startsWith('ENCv1:'));
      expect(afterInsert.privateKey, isNot(contains('ENCv1:ENCv1:')));
      // Service skips re-encrypting a valid envelope, so the stored bytes
      // must be identical.
      expect(afterInsert.privateKey, storedEncryptedPrivKey);

      // Round-trip through the repository must still yield the original key.
      final decrypted = await repository.getById(id);
      expect(decrypted!.privateKey, privateKey);
    });

    test('insert does not double-encrypt a pre-encrypted passphrase', () async {
      const privateKey = 'fixture-open-ssh-material...';
      const passphrase = 'my-passphrase';
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key With Passphrase',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: privateKey,
          passphrase: const Value(passphrase),
        ),
      );

      final rawKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(rawKey.passphrase, startsWith('ENCv1:'));
      final storedEncryptedPassphrase = rawKey.passphrase;

      await repository.delete(id);
      await repository.insert(rawKey.toCompanion(true));

      final afterInsert = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();
      expect(afterInsert.passphrase, startsWith('ENCv1:'));
      expect(afterInsert.passphrase, isNot(contains('ENCv1:ENCv1:')));
      expect(afterInsert.passphrase, storedEncryptedPassphrase);

      final decrypted = await repository.getById(id);
      expect(decrypted!.passphrase, passphrase);
    });

    test('delete removes key', () async {
      final id = await repository.insert(
        SshKeysCompanion.insert(
          name: 'To Delete',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'fixture-open-ssh-material...',
        ),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final key = await repository.getById(id);
      expect(key, isNull);
    });

    test('delete returns 0 when key not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('watchAll emits updates when keys change', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'New Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'fixture-open-ssh-material...',
        ),
      );

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchAll retains unreadable stored keys', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Readable Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'fixture-open-ssh-material...',
        ),
      );
      final otherEncryptionService = SecretEncryptionService.forTesting(
        masterKey: List<int>.generate(32, (index) => 255 - index),
      );
      final unreadablePrivateKey = await otherEncryptionService.encryptRequired(
        'unreadable-open-ssh-material...',
      );
      await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Unreadable Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 BBBB...',
              privateKey: unreadablePrivateKey,
            ),
          );

      final firstValue = await repository.watchAll().first;

      expect(firstValue, hasLength(2));
      expect(firstValue.first.name, 'Readable Key');
      expect(firstValue.last.name, 'Unreadable Key');
      expect(firstValue.last.privateKey, isEmpty);
    });

    test('getAllDecryptable reports unreadable stored keys', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Readable Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'fixture-open-ssh-material...',
        ),
      );
      final otherEncryptionService = SecretEncryptionService.forTesting(
        masterKey: List<int>.generate(32, (index) => 255 - index),
      );
      final unreadablePrivateKey = await otherEncryptionService.encryptRequired(
        'unreadable-open-ssh-material...',
      );
      await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Unreadable Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 BBBB...',
              privateKey: unreadablePrivateKey,
            ),
          );

      final result = await repository.getAllDecryptable();

      expect(result.keys, hasLength(2));
      expect(result.keys.first.name, 'Readable Key');
      expect(result.keys.last.name, 'Unreadable Key');
      expect(result.keys.last.privateKey, isEmpty);
      expect(result.unreadableCount, 1);
      expect(result.firstUnreadableErrorType, 'FormatException');
    });

    test('insert multiple keys', () async {
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 1',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA1...',
          privateKey: 'fixture-open-ssh-material-1...',
        ),
      );
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 2',
          keyType: 'rsa',
          publicKey: 'ssh-rsa AAAA2...',
          privateKey: 'fixture-rsa-material-2...',
        ),
      );
      await repository.insert(
        SshKeysCompanion.insert(
          name: 'Key 3',
          keyType: 'ecdsa',
          publicKey: 'ecdsa-sha2-nistp256 AAAA3...',
          privateKey: 'fixture-ec-material-3...',
        ),
      );

      final keys = await repository.getAll();
      expect(keys, hasLength(3));
    });
  });
}
