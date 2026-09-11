// ignore_for_file: public_member_api_docs

import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/openssh_key_generator.dart';

bool _sshKeygenAvailable() {
  try {
    // We only care that the binary can be launched; any exit code means it is
    // present. A missing binary throws a ProcessException.
    Process.runSync('ssh-keygen', ['-y', '-f', '/nonexistent-monkeyssh-probe']);
    return true;
  } on ProcessException {
    return false;
  }
}

/// Reads the algorithm name (first SSH string) from a public-key blob.
String _algorithm(Uint8List blob) {
  final length = (blob[0] << 24) | (blob[1] << 16) | (blob[2] << 8) | blob[3];
  return String.fromCharCodes(blob.sublist(4, 4 + length));
}

Future<String> _sshKeygenPublicKey(String pem, String passphrase) async {
  final dir = await Directory.systemTemp.createTemp('keygen-test-');
  try {
    final file = File('${dir.path}/id');
    await file.writeAsString(pem);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
    final result = await Process.run('ssh-keygen', [
      '-y',
      '-P',
      passphrase,
      '-f',
      file.path,
    ]);
    if (result.exitCode != 0) {
      fail('ssh-keygen rejected the key: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  final sshKeygen = _sshKeygenAvailable();

  group('generateOpenSshKey', () {
    test('generates a parseable unencrypted Ed25519 key', () async {
      final (privateKeyPem: pem, :publicKeyBlob) = await generateOpenSshKey(
        keyType: SshKeyType.ed25519,
        comment: 'unit@test',
      );

      expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(pem.trimRight(), endsWith('-----END OPENSSH PRIVATE KEY-----'));

      final keyPairs = SSHKeyPair.fromPem(pem);
      expect(keyPairs, hasLength(1));
      expect(publicKeyBlob, keyPairs.first.toPublicKey().encode());

      final keyPair = keyPairs.first;
      expect(_algorithm(keyPair.toPublicKey().encode()), 'ssh-ed25519');
      // A usable private key can sign.
      expect(keyPair.sign(Uint8List.fromList([1, 2, 3])).encode(), isNotEmpty);
    });

    test('generates a parseable unencrypted RSA key', () async {
      final (privateKeyPem: pem, :publicKeyBlob) = await generateOpenSshKey(
        keyType: SshKeyType.rsa2048,
        comment: 'unit@test',
      );

      final keyPairs = SSHKeyPair.fromPem(pem);
      expect(keyPairs, hasLength(1));
      expect(publicKeyBlob, keyPairs.first.toPublicKey().encode());
      expect(_algorithm(keyPairs.first.toPublicKey().encode()), 'ssh-rsa');
      expect(
        keyPairs.first.sign(Uint8List.fromList([1, 2, 3])).encode(),
        isNotEmpty,
      );
    });

    test('encrypts the key with the passphrase (Ed25519)', () async {
      const passphrase = 'correct horse battery staple';
      final (privateKeyPem: pem, :publicKeyBlob) = await generateOpenSshKey(
        keyType: SshKeyType.ed25519,
        comment: 'unit@test',
        passphrase: passphrase,
      );

      // Encrypted: cannot be parsed without the passphrase.
      expect(SSHKeyPair.isEncryptedPem(pem), isTrue);
      expect(() => SSHKeyPair.fromPem(pem), throwsA(isA<Object>()));

      // Wrong passphrase is rejected.
      expect(() => SSHKeyPair.fromPem(pem, 'wrong'), throwsA(isA<Object>()));

      // Correct passphrase decrypts to a usable key.
      final keyPairs = SSHKeyPair.fromPem(pem, passphrase);
      expect(keyPairs, hasLength(1));
      expect(publicKeyBlob, keyPairs.first.toPublicKey().encode());
      expect(
        keyPairs.first.sign(Uint8List.fromList([9, 9, 9])).encode(),
        isNotEmpty,
      );
    });

    test('encrypts the key with the passphrase (RSA)', () async {
      const passphrase = 'p@ss with spaces';
      final (privateKeyPem: pem, :publicKeyBlob) = await generateOpenSshKey(
        keyType: SshKeyType.rsa2048,
        comment: 'unit@test',
        passphrase: passphrase,
      );

      expect(SSHKeyPair.isEncryptedPem(pem), isTrue);
      expect(() => SSHKeyPair.fromPem(pem, 'nope'), throwsA(isA<Object>()));
      final keyPairs = SSHKeyPair.fromPem(pem, passphrase);
      expect(keyPairs, hasLength(1));
      expect(publicKeyBlob, keyPairs.first.toPublicKey().encode());
    });

    test('produces a different key on each call', () async {
      final a = (await generateOpenSshKey(
        keyType: SshKeyType.ed25519,
        comment: 'unit@test',
      )).privateKeyPem;
      final b = (await generateOpenSshKey(
        keyType: SshKeyType.ed25519,
        comment: 'unit@test',
      )).privateKeyPem;
      expect(a, isNot(equals(b)));
    });

    test('treats an empty passphrase as no passphrase', () async {
      final pem = (await generateOpenSshKey(
        keyType: SshKeyType.ed25519,
        comment: 'unit@test',
        passphrase: '',
      )).privateKeyPem;
      expect(SSHKeyPair.isEncryptedPem(pem), isFalse);
      expect(SSHKeyPair.fromPem(pem), hasLength(1));
    });
  });

  group('OpenSSH interop (real ssh-keygen)', () {
    test(
      'ssh-keygen accepts an unencrypted Ed25519 key',
      () async {
        final pem = (await generateOpenSshKey(
          keyType: SshKeyType.ed25519,
          comment: 'unit@test',
        )).privateKeyPem;
        final publicKey = await _sshKeygenPublicKey(pem, '');
        expect(publicKey, startsWith('ssh-ed25519 '));
      },
      skip: sshKeygen ? false : 'ssh-keygen not available',
    );

    test(
      'ssh-keygen accepts a passphrase-encrypted RSA key',
      () async {
        const passphrase = 'interop-secret';
        final pem = (await generateOpenSshKey(
          keyType: SshKeyType.rsa2048,
          comment: 'unit@test',
          passphrase: passphrase,
        )).privateKeyPem;
        final publicKey = await _sshKeygenPublicKey(pem, passphrase);
        expect(publicKey, startsWith('ssh-rsa '));
      },
      skip: sshKeygen ? false : 'ssh-keygen not available',
    );
  });
}
