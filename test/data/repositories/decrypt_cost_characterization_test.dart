// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';

/// Inserts [count] SSH keys with encrypted private key + passphrase.
Future<void> _insertKeysWithSecrets(KeyRepository repo, int count) async {
  for (var i = 0; i < count; i++) {
    await repo.insert(
      SshKeysCompanion.insert(
        name: 'key-$i',
        keyType: 'ed25519',
        publicKey: 'ssh-ed25519 AAAA$i',
        privateKey: 'encrypted-key-payload-$i',
        passphrase: Value('passphrase-$i'),
      ),
    );
  }
}

class _PausedEncryptionService extends SecretEncryptionService {
  _PausedEncryptionService() : super.forTesting();

  final started = Completer<void>();
  final resume = Completer<void>();
  int validationCount = 0;
  int decryptCount = 0;

  @override
  bool isValidEncryptedEnvelope(String value) {
    validationCount++;
    return super.isValidEncryptedEnvelope(value);
  }

  bool pauseDecrypt = false;
  bool pauseEncrypt = false;

  @override
  Future<String?> decryptNullable(String? value) async {
    decryptCount++;
    if (pauseDecrypt) {
      pauseDecrypt = false;
      started.complete();
      await resume.future;
    }
    return super.decryptNullable(value);
  }

  @override
  Future<String?> encryptNullable(String? value) async {
    if (pauseEncrypt) {
      pauseEncrypt = false;
      started.complete();
      await resume.future;
    }
    return super.encryptNullable(value);
  }
}

void main() {
  test('clear during a key list decrypt also rejects later rows', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final encryption = _PausedEncryptionService();
    final repository = KeyRepository(db, encryption);
    await _insertKeysWithSecrets(repository, 2);
    encryption.pauseDecrypt = true;
    final pending = repository.getAllDecryptable();
    await encryption.started.future;
    repository.clearDecryptionCache();
    encryption.resume.complete();
    expect((await pending).keys, hasLength(2));
    expect(repository.debugDecryptionCacheSize, 0);
  });

  for (final kind in ['host', 'key']) {
    test('$kind cache hits skip envelope validation until cleared', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = _PausedEncryptionService();
      final hosts = HostRepository(db, encryption);
      final keys = KeyRepository(db, encryption);
      await hosts.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: 'example.com',
          username: 'user',
          password: const Value('secret'),
        ),
      );
      await _insertKeysWithSecrets(keys, 1);
      Future<void> read() async {
        if (kind == 'host') {
          expect((await hosts.getAll()).single.password, 'secret');
        } else {
          final key = (await keys.getAll()).single;
          expect(key.privateKey, 'encrypted-key-payload-0');
          expect(key.passphrase, 'passphrase-0');
        }
      }

      final secretCount = kind == 'host' ? 1 : 2;
      encryption.validationCount = 0;
      // Reads validate envelopes inside decryptNullable, without the separate
      // validation probe that previously classified corrupt data as plaintext.
      await read();
      expect(encryption.validationCount, 0);
      expect(encryption.decryptCount, secretCount);
      encryption.decryptCount = 0;
      await read();
      expect(encryption.validationCount, 0);
      expect(encryption.decryptCount, 0);
      hosts.clearDecryptionCache();
      keys.clearDecryptionCache();
      await read();
      expect(encryption.validationCount, 0);
      expect(encryption.decryptCount, secretCount);
      await read();
      expect(encryption.validationCount, 0);
      expect(encryption.decryptCount, secretCount);
    });

    for (final operation in [
      'decrypt',
      'migration',
      if (kind == 'host') 'update',
    ]) {
      test('$kind cache rejects $operation insertion after clear', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryption = _PausedEncryptionService();
        final hosts = HostRepository(db, encryption);
        final keys = KeyRepository(db, encryption);
        final stored = operation == 'migration'
            ? 'secret'
            : (await encryption.encryptNullable('secret'))!;
        final id = kind == 'host'
            ? await db
                  .into(db.hosts)
                  .insert(
                    HostsCompanion.insert(
                      label: 'Host',
                      hostname: 'example.com',
                      username: 'user',
                      password: Value(stored),
                    ),
                  )
            : await db
                  .into(db.sshKeys)
                  .insert(
                    SshKeysCompanion.insert(
                      name: 'Key',
                      keyType: 'ed25519',
                      publicKey: 'public',
                      privateKey: stored,
                      passphrase: Value(stored),
                    ),
                  );
        final host = kind == 'host' && operation == 'update'
            ? await hosts.getById(id)
            : null;
        encryption
          ..pauseDecrypt = operation == 'decrypt'
          ..pauseEncrypt = operation != 'decrypt';
        final pending = operation == 'update'
            ? hosts.update(host!.copyWith(password: const Value('new secret')))
            : kind == 'host'
            ? hosts.getById(id)
            : keys.getById(id);
        await encryption.started.future;
        hosts.clearDecryptionCache();
        keys.clearDecryptionCache();
        encryption.resume.complete();
        await pending;
        expect(hosts.debugDecryptionCacheSize, 0);
        expect(keys.debugDecryptionCacheSize, 0);
        if (kind == 'host') {
          expect(
            (await hosts.getById(id))!.password,
            operation == 'update' ? 'new secret' : 'secret',
          );
          expect(hosts.debugDecryptionCacheSize, greaterThan(0));
        } else {
          expect(
            (await keys.getById(id))!.privateKey,
            operation == 'update' ? 'new secret' : 'secret',
          );
          expect(keys.debugDecryptionCacheSize, greaterThan(0));
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Cache correctness tests
  //
  // Verify that the ciphertext-diff cache does not corrupt decrypted values
  // across repeated calls, and that updated fields (new ciphertext) are still
  // correctly decrypted after the cache warms up.
  // ---------------------------------------------------------------------------
  group('Cache correctness – HostRepository', () {
    test('repeated getAll calls return correct plaintext passwords', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      const password = 'cached-password';
      await repo.insert(
        HostsCompanion.insert(
          label: 'Host A',
          hostname: 'a.example.com',
          username: 'user',
          password: const Value(password),
        ),
      );

      // First call: cold cache – decrypt runs for real.
      final first = await repo.getAll();
      expect(first.first.password, password);

      // Second and third calls: cache hit – same result.
      final second = await repo.getAll();
      expect(second.first.password, password);
      final third = await repo.getAll();
      expect(third.first.password, password);
    });

    test('cache does not serve stale value after password update', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: 'h.example.com',
          username: 'user',
          password: const Value('old-password'),
        ),
      );

      // Warm the cache with the old password.
      expect((await repo.getById(id))!.password, 'old-password');
      expect(repo.debugDecryptionCacheSize, 1);

      // Update to a new password – this writes a new ciphertext (new nonce),
      // evicting the old ciphertext while remembering the new one.
      final host = await repo.getById(id);
      await repo.update(host!.copyWith(password: const Value('new-password')));
      expect(repo.debugDecryptionCacheSize, 1);

      // Must return the new plaintext, not the stale cached one.
      final updated = await repo.getById(id);
      expect(updated!.password, 'new-password');

      // getAll must also reflect the new value.
      final all = await repo.getAll();
      expect(all.first.password, 'new-password');
    });

    test('cache evicts deleted host password plaintext', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: 'h.example.com',
          username: 'user',
          password: const Value('deleted-password'),
        ),
      );

      expect((await repo.getById(id))!.password, 'deleted-password');
      expect(repo.debugDecryptionCacheSize, 1);

      await repo.delete(id);

      expect(repo.debugDecryptionCacheSize, 0);
    });

    test('hosts without passwords are unaffected by cache', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = HostRepository(db, enc);
      addTearDown(db.close);

      await repo.insert(
        HostsCompanion.insert(
          label: 'Key-auth host',
          hostname: 'k.example.com',
          username: 'user',
        ),
      );

      final hosts = await repo.getAll();
      expect(hosts.first.password, isNull);

      final again = await repo.getAll();
      expect(again.first.password, isNull);
    });
  });

  group('Cache correctness – KeyRepository', () {
    test(
      'repeated getAll calls return correct decrypted private key and passphrase',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final enc = SecretEncryptionService.forTesting();
        final repo = KeyRepository(db, enc);
        addTearDown(db.close);

        const privateKey = 'encrypted-key-payload';
        const passphrase = 'key-passphrase';
        await repo.insert(
          SshKeysCompanion.insert(
            name: 'Test Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA',
            privateKey: privateKey,
            passphrase: const Value(passphrase),
          ),
        );

        for (var i = 0; i < 3; i++) {
          final keys = await repo.getAll();
          expect(keys.first.privateKey, privateKey);
          expect(keys.first.passphrase, passphrase);
        }
      },
    );

    test('cache does not serve stale private key after replacement', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        SshKeysCompanion.insert(
          name: 'Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: '-----BEGIN old',
        ),
      );

      // Warm up the cache.
      expect((await repo.getById(id))!.privateKey, '-----BEGIN old');
      expect(repo.debugDecryptionCacheSize, 1);

      final key = await repo.getById(id);
      await repo.delete(id);
      await repo.insert(
        key!
            .toCompanion(true)
            .copyWith(privateKey: const Value('-----BEGIN new')),
      );
      expect(repo.debugDecryptionCacheSize, 0);

      expect((await repo.getById(id))!.privateKey, '-----BEGIN new');

      final all = await repo.getAll();
      expect(all.first.privateKey, '-----BEGIN new');
    });

    test('cache evicts deleted key plaintexts', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      final id = await repo.insert(
        SshKeysCompanion.insert(
          name: 'Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: '-----BEGIN deleted',
          passphrase: const Value('deleted-passphrase'),
        ),
      );

      final key = await repo.getById(id);
      expect(key!.privateKey, '-----BEGIN deleted');
      expect(key.passphrase, 'deleted-passphrase');
      expect(repo.debugDecryptionCacheSize, 2);

      await repo.delete(id);

      expect(repo.debugDecryptionCacheSize, 0);
    });

    test('keys without passphrase are unaffected by cache', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final enc = SecretEncryptionService.forTesting();
      final repo = KeyRepository(db, enc);
      addTearDown(db.close);

      await repo.insert(
        SshKeysCompanion.insert(
          name: 'No-passphrase key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: 'encrypted-key-payload',
        ),
      );

      for (var i = 0; i < 2; i++) {
        final keys = await repo.getAll();
        expect(keys.first.passphrase, isNull);
      }
    });
  });
}
