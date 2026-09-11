// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/openssh_key_generator.dart';

class _GenerationOnlyKeyService extends KeyService {
  _GenerationOnlyKeyService(super.keyRepository);

  @override
  Future<SshKey?> importKey({
    required String name,
    required String privateKeyPem,
    String? passphrase,
  }) => throw StateError('Generation must not decrypt PEM through importKey');
}

void main() {
  late AppDatabase db;
  late KeyRepository keyRepository;
  late KeyService keyService;
  late SecretEncryptionService encryptionService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    keyRepository = KeyRepository(db, encryptionService);
    keyService = KeyService(keyRepository);
  });

  tearDown(() async {
    await db.close();
  });

  group('KeyService', () {
    group('importKey', () {
      test('returns null for invalid PEM', () async {
        final result = await keyService.importKey(
          name: 'Invalid Key',
          privateKeyPem: 'not a valid key',
        );
        expect(result, isNull);
        expect(await keyRepository.getAll(), isEmpty);
      });

      test(
        'returns null for an encrypted key with the wrong passphrase',
        () async {
          final encryptedPem = (await generateOpenSshKey(
            keyType: SshKeyType.ed25519,
            comment: 'unit@test',
            passphrase: 'correct-passphrase',
          )).privateKeyPem;

          final result = await keyService.importKey(
            name: 'Encrypted',
            privateKeyPem: encryptedPem,
            passphrase: 'wrong-passphrase',
          );
          expect(result, isNull);
          expect(await keyRepository.getAll(), isEmpty);
        },
      );

      test('returns null for an encrypted key with no passphrase', () async {
        final encryptedPem = (await generateOpenSshKey(
          keyType: SshKeyType.ed25519,
          comment: 'unit@test',
          passphrase: 'correct-passphrase',
        )).privateKeyPem;

        final result = await keyService.importKey(
          name: 'Encrypted',
          privateKeyPem: encryptedPem,
        );
        expect(result, isNull);
        expect(await keyRepository.getAll(), isEmpty);
      });
    });

    group('generateKey', () {
      test('generates and stores an Ed25519 key', () async {
        final key = await keyService.generateKey(
          name: 'Generated Ed25519',
          keyType: SshKeyType.ed25519,
        );

        expect(key, isNotNull);
        expect(key!.keyType, 'ssh-ed25519');
        expect(key.publicKey, startsWith('ssh-ed25519 '));
        expect(key.privateKey, contains('OPENSSH PRIVATE KEY'));
        expect(key.fingerprint, startsWith('SHA256:'));
        expect(SSHKeyPair.fromPem(key.privateKey), isNotEmpty);
        expect(await keyRepository.getAll(), hasLength(1));
      });

      test(
        'generates and stores an RSA key with the canonical prefix',
        () async {
          final key = await keyService.generateKey(
            name: 'Generated RSA',
            keyType: SshKeyType.rsa2048,
          );

          expect(key, isNotNull);
          expect(key!.keyType, 'ssh-rsa');
          expect(key.publicKey, startsWith('ssh-rsa '));
          expect(SSHKeyPair.fromPem(key.privateKey), isNotEmpty);
        },
      );

      test(
        'stores encrypted keys without importing the generated PEM',
        () async {
          keyService = _GenerationOnlyKeyService(keyRepository);
          const passphrase = 'unit-test-passphrase';
          final key = await keyService.generateKey(
            name: 'Protected',
            keyType: SshKeyType.ed25519,
            passphrase: passphrase,
          );

          expect(key, isNotNull);
          // The stored private key really is encrypted with the passphrase.
          expect(
            () => SSHKeyPair.fromPem(key!.privateKey),
            throwsA(isA<SSHError>()),
          );
          expect(SSHKeyPair.fromPem(key!.privateKey, passphrase), isNotEmpty);
          expect(key.passphrase, passphrase);
          final publicBlob = SSHKeyPair.fromPem(
            key.privateKey,
            passphrase,
          ).single.toPublicKey().encode();
          expect(key.publicKey, 'ssh-ed25519 ${base64Encode(publicBlob)}');
          expect(
            key.fingerprint,
            computeOpenSshPublicKeyFingerprint(key.publicKey),
          );
        },
      );

      test('treats an empty passphrase as unencrypted', () async {
        final key = await keyService.generateKey(
          name: 'No passphrase',
          keyType: SshKeyType.ed25519,
          passphrase: '',
        );

        expect(key, isNotNull);
        expect(SSHKeyPair.fromPem(key!.privateKey), isNotEmpty);
        expect(key.passphrase, isNull);
      });
    });
  });
}
