// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';

import 'host_key_prompt_cases.dart';
import 'host_key_trust_dialog_cases.dart';
import 'known_hosts_repository_cases.dart';

void main() {
  group('host_key_verification', () {
    late AppDatabase db;
    late KnownHostsRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = KnownHostsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    group('HostKeyVerificationService', () {
      test('accepts and persists an unknown host after TOFU trust', () async {
        final service = HostKeyVerificationService(
          knownHostsRepository: repository,
          promptHandler: (_) async => HostKeyTrustDecision.trust,
        );
        final presentedHostKey = _verifiedHostKey('new.example.com', 22, [
          1,
          2,
          3,
        ]);

        final update = await service.verify(presentedHostKey);
        await update.persistTrustDecision(repository);

        final storedHost = await repository.getByHost('new.example.com', 22);
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, presentedHostKey.encodedHostKey);
        expect(storedHost.fingerprint, presentedHostKey.fingerprint);
      });

      test('rejects an unknown host without persisting trust', () async {
        final service = HostKeyVerificationService(
          knownHostsRepository: repository,
          promptHandler: (request) async {
            expect(request.existingKnownHost, isNull);
            expect(request.isReplacement, isFalse);
            return HostKeyTrustDecision.reject;
          },
        );
        final presentedHostKey = _verifiedHostKey('reject.example.com', 22, [
          1,
          3,
          5,
        ]);

        await expectLater(
          service.verify(presentedHostKey),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              contains('not trusted yet'),
            ),
          ),
        );

        expect(await repository.getByHost('reject.example.com', 22), isNull);
      });

      test(
        'fails closed for unknown hosts when no prompt is available',
        () async {
          final service = HostKeyVerificationService(
            knownHostsRepository: repository,
          );
          final presentedHostKey = _verifiedHostKey(
            'headless.example.com',
            22,
            [2, 4, 6],
          );

          await expectLater(
            service.verify(presentedHostKey),
            throwsA(
              isA<HostKeyVerificationException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('verification is required'),
                  contains('no trust'),
                ),
              ),
            ),
          );
          expect(
            await repository.getByHost('headless.example.com', 22),
            isNull,
          );
        },
      );

      test('rejects changed host keys by default', () async {
        final originalHostKey = _verifiedHostKey('change.example.com', 22, [
          4,
          5,
          6,
        ]);
        await repository.upsertTrustedHost(
          hostname: originalHostKey.hostname,
          port: originalHostKey.port,
          keyType: originalHostKey.keyType,
          fingerprint: originalHostKey.fingerprint,
          encodedHostKey: originalHostKey.encodedHostKey,
          resetFirstSeen: true,
        );
        final service = HostKeyVerificationService(
          knownHostsRepository: repository,
          promptHandler: (_) async => HostKeyTrustDecision.reject,
        );
        final presentedHostKey = _verifiedHostKey('change.example.com', 22, [
          7,
          8,
          9,
        ]);

        await expectLater(
          service.verify(presentedHostKey),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              contains('changed'),
            ),
          ),
        );

        final storedHost = await repository.getByHost('change.example.com', 22);
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
        expect(storedHost.fingerprint, originalHostKey.fingerprint);
      });

      test(
        'fails closed for changed host keys when no prompt is available',
        () async {
          final originalHostKey = _verifiedHostKey('noprompt.example.com', 22, [
            4,
            5,
            6,
          ]);
          await repository.upsertTrustedHost(
            hostname: originalHostKey.hostname,
            port: originalHostKey.port,
            keyType: originalHostKey.keyType,
            fingerprint: originalHostKey.fingerprint,
            encodedHostKey: originalHostKey.encodedHostKey,
            resetFirstSeen: true,
          );
          final service = HostKeyVerificationService(
            knownHostsRepository: repository,
          );
          final presentedHostKey = _verifiedHostKey(
            'noprompt.example.com',
            22,
            [7, 8, 9],
          );

          await expectLater(
            service.verify(presentedHostKey),
            throwsA(
              isA<HostKeyVerificationException>().having(
                (error) => error.message,
                'message',
                contains('replacement prompt is not available'),
              ),
            ),
          );

          final storedHost = await repository.getByHost(
            'noprompt.example.com',
            22,
          );
          expect(storedHost, isNotNull);
          expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
        },
      );

      test(
        'allows explicit replacement of a changed trusted host key',
        () async {
          final originalHostKey = _verifiedHostKey('replace.example.com', 22, [
            4,
            5,
            6,
          ]);
          await repository.upsertTrustedHost(
            hostname: originalHostKey.hostname,
            port: originalHostKey.port,
            keyType: originalHostKey.keyType,
            fingerprint: originalHostKey.fingerprint,
            encodedHostKey: originalHostKey.encodedHostKey,
            resetFirstSeen: true,
          );
          final service = HostKeyVerificationService(
            knownHostsRepository: repository,
            promptHandler: (request) async {
              expect(request.existingKnownHost, isNotNull);
              expect(
                request.existingKnownHost!.hostKey,
                originalHostKey.encodedHostKey,
              );
              return HostKeyTrustDecision.replace;
            },
          );
          final replacementHostKey = _verifiedHostKey(
            'replace.example.com',
            22,
            [7, 8, 9],
          );

          final update = await service.verify(replacementHostKey);
          await update.persistTrustDecision(repository);
          var storedHost = await repository.getByHost(
            'replace.example.com',
            22,
          );
          expect(storedHost, isNotNull);
          expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
          expect(storedHost.fingerprint, originalHostKey.fingerprint);

          await update.commitAfterAuthentication(repository);

          storedHost = await repository.getByHost('replace.example.com', 22);
          expect(storedHost, isNotNull);
          expect(storedHost!.hostKey, replacementHostKey.encodedHostKey);
          expect(storedHost.fingerprint, replacementHostKey.fingerprint);
        },
      );

      test('accepts a pretrusted host key without prompting', () async {
        final trustedHostKey = _verifiedHostKey('trusted.example.com', 22, [
          1,
          2,
          3,
        ]);
        await repository.upsertTrustedHost(
          hostname: trustedHostKey.hostname,
          port: trustedHostKey.port,
          keyType: trustedHostKey.keyType,
          fingerprint: trustedHostKey.fingerprint,
          encodedHostKey: trustedHostKey.encodedHostKey,
          resetFirstSeen: true,
        );

        var prompted = false;
        final service = HostKeyVerificationService(
          knownHostsRepository: repository,
          promptHandler: (_) async {
            prompted = true;
            return HostKeyTrustDecision.reject;
          },
        );

        final update = await service.verify(trustedHostKey);
        await update.commitAfterAuthentication(repository);

        expect(prompted, isFalse);
        final storedHost = await repository.getByHost(
          'trusted.example.com',
          22,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, trustedHostKey.encodedHostKey);
      });

      test(
        'accepts RSA host keys across signature algorithm variants',
        () async {
          final storedHostKey = _rsaVerifiedHostKey(
            'rsa.example.com',
            22,
            exponent: const [1, 0, 1],
            modulus: const [1, 2, 3, 4, 5, 6, 7, 8],
            keyType: 'rsa-sha2-256',
          );
          await repository.upsertTrustedHost(
            hostname: storedHostKey.hostname,
            port: storedHostKey.port,
            keyType: storedHostKey.keyType,
            fingerprint: storedHostKey.fingerprint,
            encodedHostKey: storedHostKey.encodedHostKey,
            resetFirstSeen: true,
          );

          var prompted = false;
          final service = HostKeyVerificationService(
            knownHostsRepository: repository,
            promptHandler: (_) async {
              prompted = true;
              return HostKeyTrustDecision.replace;
            },
          );
          final presentedHostKey = _rsaVerifiedHostKey(
            'rsa.example.com',
            22,
            exponent: const [1, 0, 1],
            modulus: const [1, 2, 3, 4, 5, 6, 7, 8],
            keyType: 'rsa-sha2-512',
          );

          final update = await service.verify(presentedHostKey);
          await update.commitAfterAuthentication(repository);

          final storedHost = await repository.getByHost('rsa.example.com', 22);
          expect(prompted, isFalse);
          expect(storedHost, isNotNull);
          expect(storedHost!.hostKey, presentedHostKey.encodedHostKey);
          expect(storedHost.fingerprint, presentedHostKey.fingerprint);
          expect(storedHost.keyType, 'ssh-rsa');
        },
      );
    });

    group('formatSshHostKeyFingerprint', () {
      test('produces the correct SHA-256 fingerprint for a known key blob', () {
        // A minimal ed25519 host key blob for a known byte sequence.
        final keyBlob = _ed25519HostKeyBlob([0x01, 0x02, 0x03, 0x04]);
        final fingerprint = formatSshHostKeyFingerprint(keyBlob);

        // Expected value pre-computed with SHA-256 for this exact blob:
        expect(
          fingerprint,
          'SHA256:huY78Jldb5S8vXxjT3nKH+i2oG/1vi/D8uOVazYreOQ',
        );
      });

      test('fingerprint is deterministic for the same key bytes', () {
        final keyBlob = _ed25519HostKeyBlob([0x01, 0x02, 0x03, 0x04]);

        expect(
          formatSshHostKeyFingerprint(keyBlob),
          formatSshHostKeyFingerprint(keyBlob),
          reason: 'fingerprint must be deterministic',
        );
      });

      test('different key bytes produce different fingerprints', () {
        final blobA = _ed25519HostKeyBlob([0xAA, 0xBB]);
        final blobB = _ed25519HostKeyBlob([0xCC, 0xDD]);

        expect(
          formatSshHostKeyFingerprint(blobA),
          isNot(formatSshHostKeyFingerprint(blobB)),
        );
      });

      test('fingerprint matches the SSH wire format SHA-256 convention', () {
        // OpenSSH displays fingerprints as "SHA256:<base64-without-padding>".
        // Verify the prefix and that no padding characters are present.
        final keyBlob = _ed25519HostKeyBlob([1, 2, 3]);
        final fingerprint = formatSshHostKeyFingerprint(keyBlob);

        expect(fingerprint, startsWith('SHA256:'));
        expect(fingerprint, isNot(contains('=')));
      });

      test(
        'formatLegacySshHostKeyFingerprint produces colon-separated MD5',
        () {
          final keyBlob = _ed25519HostKeyBlob([0x01, 0x02, 0x03]);
          final md5Fingerprint = formatLegacySshHostKeyFingerprint(keyBlob);

          // Legacy format: 16 hex pairs joined by colons (47 chars total).
          expect(
            md5Fingerprint,
            matches(RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2}){15}$')),
          );
        },
      );

      test('SHA-256 and MD5 fingerprints differ for the same key blob', () {
        final keyBlob = _ed25519HostKeyBlob([0xDE, 0xAD, 0xBE, 0xEF]);
        final sha256fp = formatSshHostKeyFingerprint(keyBlob);
        final md5fp = formatLegacySshHostKeyFingerprint(keyBlob);

        expect(sha256fp, isNot(md5fp));
      });
    });
  });
  registerHostKeyPromptTests();
  registerHostKeyTrustDialogTests();
  registerKnownHostsRepositoryTests();
}

VerifiedHostKey _verifiedHostKey(
  String hostname,
  int port,
  List<int> keyData,
) => VerifiedHostKey(
  hostname: hostname,
  port: port,
  keyType: 'ssh-ed25519',
  hostKeyBytes: _ed25519HostKeyBlob(keyData),
);

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-ed25519')))
    ..add(_sshString(keyData));
  return writer.takeBytes();
}

VerifiedHostKey _rsaVerifiedHostKey(
  String hostname,
  int port, {
  required List<int> exponent,
  required List<int> modulus,
  String keyType = 'ssh-rsa',
}) => VerifiedHostKey(
  hostname: hostname,
  port: port,
  keyType: keyType,
  hostKeyBytes: _rsaHostKeyBlob(exponent: exponent, modulus: modulus),
);

Uint8List _rsaHostKeyBlob({
  required List<int> exponent,
  required List<int> modulus,
}) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-rsa')))
    ..add(_mpInt(exponent))
    ..add(_mpInt(modulus));
  return writer.takeBytes();
}

Uint8List _mpInt(List<int> bytes) {
  final normalizedBytes = bytes.isNotEmpty && bytes.first >= 0x80
      ? <int>[0, ...bytes]
      : bytes;
  return _sshString(normalizedBytes);
}

Uint8List _sshString(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
