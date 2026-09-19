// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';

void registerKnownHostsRepositoryTests() {
  group('known_hosts_repository', () {
    late AppDatabase db;
    late KnownHostsRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = KnownHostsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    group('KnownHostsRepository', () {
      test('upsertTrustedHost stores a new trusted host key', () async {
        final hostKey = _verifiedHostKey('server.example.com', 22, [
          1,
          2,
          3,
          4,
        ]);

        await repository.upsertTrustedHost(
          hostname: hostKey.hostname,
          port: hostKey.port,
          keyType: hostKey.keyType,
          fingerprint: hostKey.fingerprint,
          encodedHostKey: hostKey.encodedHostKey,
          resetFirstSeen: true,
        );

        final storedHost = await repository.getByHost(
          hostKey.hostname,
          hostKey.port,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.keyType, hostKey.keyType);
        expect(storedHost.fingerprint, hostKey.fingerprint);
        expect(storedHost.hostKey, hostKey.encodedHostKey);
        expect(storedHost.firstSeen, isNotNull);
        expect(storedHost.lastSeen, isNotNull);
      });

      test(
        'upsertTrustedHost atomically updates an existing trusted host key',
        () async {
          final originalTime = DateTime(2024);
          await db
              .into(db.knownHosts)
              .insert(
                KnownHostsCompanion.insert(
                  hostname: 'server.example.com',
                  port: 22,
                  keyType: 'ssh-ed25519',
                  fingerprint: 'legacy',
                  hostKey: 'legacy-key',
                  firstSeen: Value(originalTime),
                  lastSeen: Value(originalTime),
                ),
              );
          final updatedHostKey = _verifiedHostKey('server.example.com', 22, [
            9,
            8,
            7,
            6,
          ]);

          await repository.upsertTrustedHost(
            hostname: updatedHostKey.hostname,
            port: updatedHostKey.port,
            keyType: updatedHostKey.keyType,
            fingerprint: updatedHostKey.fingerprint,
            encodedHostKey: updatedHostKey.encodedHostKey,
            resetFirstSeen: false,
          );

          final storedHost = await repository.getByHost(
            updatedHostKey.hostname,
            updatedHostKey.port,
          );
          expect(storedHost, isNotNull);
          expect(storedHost!.fingerprint, updatedHostKey.fingerprint);
          expect(storedHost.hostKey, updatedHostKey.encodedHostKey);
          expect(storedHost.firstSeen, originalTime);
          expect(storedHost.lastSeen.isAfter(originalTime), isTrue);
        },
      );

      test(
        'markTrustedHostSeen refreshes lastSeen and normalizes imported data',
        () async {
          final now = DateTime(2024);
          await db
              .into(db.knownHosts)
              .insert(
                KnownHostsCompanion.insert(
                  hostname: 'server.example.com',
                  port: 22,
                  keyType: 'ssh-ed25519',
                  fingerprint: 'legacy-md5',
                  hostKey: '',
                  firstSeen: Value(now),
                  lastSeen: Value(now),
                ),
              );
          final hostKey = _verifiedHostKey('server.example.com', 22, [
            9,
            8,
            7,
            6,
          ]);

          await repository.markTrustedHostSeen(
            hostname: hostKey.hostname,
            port: hostKey.port,
            keyType: hostKey.keyType,
            fingerprint: hostKey.fingerprint,
            encodedHostKey: hostKey.encodedHostKey,
          );

          final storedHost = await repository.getByHost(
            hostKey.hostname,
            hostKey.port,
          );
          expect(storedHost, isNotNull);
          expect(storedHost!.firstSeen, now);
          expect(storedHost.lastSeen.isAfter(now), isTrue);
          expect(storedHost.fingerprint, hostKey.fingerprint);
          expect(storedHost.hostKey, hostKey.encodedHostKey);
        },
      );
    });
  });
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
  final typeBytes = utf8.encode('ssh-ed25519');
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32(keyData.length))
    ..add(keyData);
  return writer.takeBytes();
}

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
