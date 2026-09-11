// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

const _publicKeyA =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwEkW+K+T0BVhCHT/6o4p9FdlaUJD/yPJfHziYQuwnK a';
const _publicKeyAFingerprint =
    'SHA256:KN1Ih6apKdkbSOKekPapKbXepsF6rVo5M5srTRe71fI';
const _publicKeyB =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHOD6YHh4xjr8IcP0uT8DODGjPEDGqX2i4eyNvtXq2D+ b';
const _publicKeyBFingerprint =
    'SHA256:v6rpW34v6+w8LPSvW6v1+Dm8Z6sRf/VNAFNbr8FG3sg';

// Fixed PBKDF2 v1 and pre-refactor v2 envelopes using deterministic test entropy.
const _v1EnvelopeFixture =
    'MSSH1:eyJ2IjoxLCJhbGciOiJBRVMtR0NNLTI1NiIsImtkZiI6IlBCS0RGMi1ITUFDLVNIQTI1Ni'
    'IsIml0ZXIiOjEyMDAwMCwic2FsdCI6IkFBRUNBd1FGQmdjSUNRb0xEQTBPRHc9PSIsIm5vbmNlIj'
    'oiRUJFU0V4UVZGaGNZR1JvYiIsImNpcGhlcnRleHQiOiJldlhucm1JWnNCRENHeG53S252aHN6c1'
    'dENEIwU0lrN3JkRHVET3dTRnh5SHZpcThfRnJqbG54VmtyMUcyUWE1LWFBTVRMQVBJVnJyRXZRNW'
    'xfTmlVTmVGUk14RG1ZVFF0U1hpYVZzaWR0RWdwZVpMVk1aWXZvN3AwWTNSaGVCSXdvcURwYkVCd3'
    'JUQklNbV9QVFExd21iNWxvZWY4T185VUNYellvQXBWa2czV05FbW1pYVlKVll3NjVPMXFEZEFiY1'
    'ZMejFWV3Q3ZEpQaXprIiwibWFjIjoiWHd0WFcxa3VZNjNKWHJoLU1RcGZFdz09IiwiY2hlY2tzdW'
    '0iOiJsWWtwUGRCQkwxOFhTU0NwV1VGRURuUklaR0ZTTHZGZEpPQm9IRkpodGNjPSJ9';
const _v2EnvelopeFixture =
    'MSSH1:eyJ2IjoyLCJhbGciOiJBRVMtR0NNLTI1NiIsImtkZiI6IkFyZ29uMmlkIiwiaXRlciI6My'
    'wibWVtIjozMjc2OCwibGFuZXMiOjEsInNhbHQiOiJNNjdFWGJWb2p6MHd1UF9rTTNOTkdnPT0iLC'
    'Jub25jZSI6InAxbm5ycVFhVHlCYVpHNVEiLCJjaXBoZXJ0ZXh0IjoiYlp3TkJaMFhTRjZ0Q2Ntdj'
    'J2clh5QWhiNzhXODZkZTlHVU5HY1ZWUVg1WEVBc0VNeldjbExRZEJJMWJudV9GSW8yWEdKT0J6bE'
    'IyN2h2dEJzWTREYnIzakdQNGtXemxQYnZ0ZDBUYWJVall5RW42WndtZjluWm9MMzg0dGcyOVhwVU'
    'VUcm55YWZReW5jLUxic1ZmTkJOVm9tTVJxR3FXclVSWmRpQmdNTEJEZFVxM0YwSXRHSFh4YjhuX2'
    '1wWGpVbEVFYURXTGZ4RmFvWHo0TiIsIm1hYyI6IkFFTndaSHhRWVNWdjl2WVhSbkZFQlE9PSIsIm'
    'NoZWNrc3VtIjoibFlrcFBkQkJMMThYU1NDcFdVRkVEblJJWkdGU0x2RmRKT0JvSEZKaHRjYz0ifQ'
    '==';

void main() {
  late AppDatabase db;
  late HostRepository hostRepository;
  late KeyRepository keyRepository;
  late SecretEncryptionService encryptionService;
  late SecureTransferService transferService;
  late int hostsChangedCount;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    hostRepository = HostRepository(db, encryptionService);
    keyRepository = KeyRepository(db, encryptionService);
    hostsChangedCount = 0;
    transferService = SecureTransferService(
      db,
      keyRepository,
      hostRepository,
      onHostsChanged: () async {
        hostsChangedCount++;
      },
    );
  });

  tearDown(() async {
    await db.close();
  });

  for (final migration in [false, true]) {
    test(
      'round trips structured multiplexer settings, migration=$migration',
      () async {
        final id = await hostRepository.insert(
          HostsCompanion.insert(
            sortOrder: const Value(8),
            label: 'Mux host',
            hostname: 'example.com',
            username: 'demo',
            tmuxSessionName: const Value('workspace'),
            tmuxWorkingDirectory: const Value('/repo'),
            remoteMuxBackend: const Value('monkeyMux'),
            tmuxExtraFlags: const Value('-f /untrusted/config'),
            autoConnectCommand: const Value('echo review'),
          ),
        );
        final original = (await hostRepository.getById(id))!;
        final encoded = migration
            ? await transferService.createFullMigrationPayload(
                transferPassphrase: 'test',
              )
            : await transferService.createHostPayload(
                host: original,
                transferPassphrase: 'test',
              );
        final payload = await transferService.decryptPayload(
          encodedPayload: encoded,
          transferPassphrase: 'test',
        );
        final Host imported;
        if (migration) {
          await transferService.importFullMigrationPayload(
            payload: payload,
            mode: MigrationImportMode.replace,
          );
          imported = (await hostRepository.getAll()).single;
        } else {
          imported = await transferService.importHostPayload(payload);
        }
        expect(imported.sortOrder, migration ? 8 : 9);
        expect(imported.tmuxSessionName, 'workspace');
        expect(imported.tmuxWorkingDirectory, '/repo');
        expect(imported.remoteMuxBackend, 'monkeyMux');
        expect(imported.tmuxExtraFlags, isNull);
        expect(imported.autoConnectRequiresConfirmation, isTrue);
      },
    );
  }

  for (final table in ['groups', 'snippetFolders']) {
    for (final cycle in [false, true]) {
      test('rolls back invalid $table hierarchy, cycle=$cycle', () async {
        await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Keep',
            hostname: 'example.com',
            username: 'demo',
          ),
        );
        await expectLater(
          transferService.importMigrationData(
            mode: MigrationImportMode.replace,
            data: {
              table: [
                {'id': 1, 'name': 'Root'},
                {'id': 2, 'name': 'Child', 'parentId': 3},
                if (cycle) {'id': 3, 'name': 'Cycle', 'parentId': 2},
              ],
            },
          ),
          throwsFormatException,
        );
        expect((await hostRepository.getAll()).single.label, 'Keep');
        expect(await db.select(db.groups).get(), isEmpty);
        expect(await db.select(db.snippetFolders).get(), isEmpty);
      });
    }
  }

  group('SecureTransferService', () {
    group('unreadable secrets during export', () {
      const unreadableSecret = 'ENCv1:unreadable-secret';

      Matcher unreadableExport(List<String> descriptions) => throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf([
            contains('Cannot export'),
            for (final description in descriptions) contains(description),
            contains('Re-enter these secrets before exporting'),
          ]),
        ),
      );

      for (final export in ['migration data', 'full migration', 'host']) {
        test('$export fails naming the unreadable host password', () async {
          final hostId = await db
              .into(db.hosts)
              .insert(
                HostsCompanion.insert(
                  label: 'Production server',
                  hostname: 'example.com',
                  username: 'demo',
                  password: const Value(unreadableSecret),
                ),
              );

          final Future<Object> result;
          switch (export) {
            case 'migration data':
              result = transferService.createMigrationData();
            case 'full migration':
              result = transferService.createFullMigrationPayload(
                transferPassphrase: 'test',
              );
            default:
              final host = (await hostRepository.getById(hostId))!;
              expect(host.password, isNull);
              result = transferService.createHostPayload(
                host: host,
                transferPassphrase: 'test',
              );
          }

          await expectLater(
            result,
            unreadableExport(['password for host "Production server"']),
          );
          expect(
            (await db.select(db.hosts).getSingle()).password,
            unreadableSecret,
          );
        });
      }

      for (final secret in ['private key', 'passphrase']) {
        for (final export in [
          'migration data',
          'full migration',
          'key',
          'referenced key',
        ]) {
          test('$export fails naming the unreadable $secret', () async {
            final keyId = await db
                .into(db.sshKeys)
                .insert(
                  SshKeysCompanion.insert(
                    name: 'Deploy key',
                    keyType: 'ed25519',
                    publicKey: _publicKeyA,
                    privateKey: secret == 'private key' ? unreadableSecret : '',
                    passphrase: Value(
                      secret == 'passphrase' ? unreadableSecret : null,
                    ),
                  ),
                );

            final Future<Object> result;
            switch (export) {
              case 'migration data':
                result = transferService.createMigrationData();
              case 'full migration':
                result = transferService.createFullMigrationPayload(
                  transferPassphrase: 'test',
                );
              case 'key':
                final key = (await keyRepository.getById(keyId))!;
                expect(key.privateKey, isEmpty);
                expect(key.passphrase, isNull);
                result = transferService.createKeyPayload(
                  key: key,
                  transferPassphrase: 'test',
                );
              default:
                final hostId = await hostRepository.insert(
                  HostsCompanion.insert(
                    label: 'Production server',
                    hostname: 'example.com',
                    username: 'demo',
                    keyId: Value(keyId),
                  ),
                );
                result = transferService.createHostPayload(
                  host: (await hostRepository.getById(hostId))!,
                  transferPassphrase: 'test',
                  includeReferencedKey: true,
                );
            }

            await expectLater(
              result,
              unreadableExport(['$secret for SSH key "Deploy key"']),
            );
            final storedKey = await db.select(db.sshKeys).getSingle();
            expect(
              secret == 'private key'
                  ? storedKey.privateKey
                  : storedKey.passphrase,
              unreadableSecret,
            );
          });
        }
      }

      test('migration reports every affected host and key', () async {
        for (final label in ['Production server', 'Staging server']) {
          await db
              .into(db.hosts)
              .insert(
                HostsCompanion.insert(
                  label: label,
                  hostname: 'example.com',
                  username: 'demo',
                  password: const Value(unreadableSecret),
                ),
              );
        }
        await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Deploy key',
                keyType: 'ed25519',
                publicKey: _publicKeyA,
                privateKey: unreadableSecret,
                passphrase: const Value(unreadableSecret),
              ),
            );

        await expectLater(
          transferService.createMigrationData(),
          unreadableExport([
            'password for host "Production server"',
            'password for host "Staging server"',
            'private key for SSH key "Deploy key"',
            'passphrase for SSH key "Deploy key"',
          ]),
        );
      });

      test('host export can omit an unreadable referenced key', () async {
        final keyId = await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Deploy key',
                keyType: 'ed25519',
                publicKey: _publicKeyA,
                privateKey: unreadableSecret,
              ),
            );
        await keyRepository.getById(keyId);
        final hostId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Production server',
            hostname: 'example.com',
            username: 'demo',
            keyId: Value(keyId),
          ),
        );
        final encoded = await transferService.createHostPayload(
          host: (await hostRepository.getById(hostId))!,
          transferPassphrase: 'test',
        );
        final payload = await transferService.decryptPayload(
          encodedPayload: encoded,
          transferPassphrase: 'test',
        );
        expect(payload.data['referencedKey'], isNull);
        expect((payload.data['host'] as Map)['keyId'], isNull);
      });

      test('healthy secrets survive every export path', () async {
        final keyId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Deploy key',
            keyType: 'ed25519',
            publicKey: _publicKeyA,
            privateKey: 'private-key-material',
            passphrase: const Value('key-passphrase'),
          ),
        );
        final hostId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Production server',
            hostname: 'example.com',
            username: 'demo',
            password: const Value('host-password'),
            keyId: Value(keyId),
          ),
        );
        final host = (await hostRepository.getById(hostId))!;
        final key = (await keyRepository.getById(keyId))!;
        final data = await transferService.createMigrationData();
        expect((data['hosts'] as List).single, host.toJson());
        expect((data['keys'] as List).single, key.toJson());

        for (final export in ['full migration', 'host', 'key']) {
          final encoded = await switch (export) {
            'full migration' => transferService.createFullMigrationPayload(
              transferPassphrase: 'test',
            ),
            'host' => transferService.createHostPayload(
              host: host,
              transferPassphrase: 'test',
              includeReferencedKey: true,
            ),
            _ => transferService.createKeyPayload(
              key: key,
              transferPassphrase: 'test',
            ),
          };
          final payload = await transferService.decryptPayload(
            encodedPayload: encoded,
            transferPassphrase: 'test',
          );
          switch (export) {
            case 'full migration':
              expect(payload.data, data);
            case 'host':
              expect(payload.data['host'], host.toJson());
              expect(payload.data['referencedKey'], key.toJson());
            default:
              expect(payload.data['key'], key.toJson());
          }
        }
      });
    });

    test(
      'imports a public-only key payload without inventing a private key',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.key,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'key': {
              'name': 'Public reference',
              'keyType': 'ed25519',
              'publicKey': _publicKeyA,
              'privateKey': '',
            },
          },
        );

        final imported = await transferService.importKeyPayload(payload);
        expect(imported.privateKey, isEmpty);
        expect(imported.publicKey, _publicKeyA);
        expect(imported.fingerprint, _publicKeyAFingerprint);
        expect((await db.select(db.sshKeys).getSingle()).privateKey, isEmpty);
      },
    );

    test('roundtrips public-only keys through replacement migration', () async {
      await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Public reference',
          keyType: 'ed25519',
          publicKey: _publicKeyA,
          privateKey: '',
        ),
      );
      final data = await transferService.createMigrationData();

      await transferService.importMigrationData(
        data: data,
        mode: MigrationImportMode.replace,
      );

      final keys = await keyRepository.getAll();
      expect(keys, hasLength(1));
      expect(keys.single.privateKey, isEmpty);
      expect(keys.single.publicKey, _publicKeyA);
      expect(hostsChangedCount, 1);
    });

    for (final publicOnlyFirst in [true, false]) {
      test('replacement preserves matching public and private keys '
          'with public-only first=$publicOnlyFirst', () async {
        final publicId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Public reference',
            keyType: 'ed25519',
            publicKey: _publicKeyA,
            privateKey: '',
            fingerprint: const Value(_publicKeyAFingerprint),
          ),
        );
        final privateId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Private key',
            keyType: 'ed25519',
            publicKey: _publicKeyA,
            privateKey: 'private-key-material',
            passphrase: const Value('key-passphrase'),
            fingerprint: const Value(_publicKeyAFingerprint),
          ),
        );
        for (final entry in {
          'Public host': publicId,
          'Private host': privateId,
        }.entries) {
          await hostRepository.insert(
            HostsCompanion.insert(
              label: entry.key,
              hostname: 'example.com',
              username: 'test',
              keyId: Value(entry.value),
            ),
          );
        }
        final data = await transferService.createMigrationData();
        final exportedKeys = (data['keys'] as List)
            .cast<Map<String, dynamic>>();
        final publicKey = exportedKeys.singleWhere(
          (key) => key['privateKey'] == '',
        );
        final privateKey = exportedKeys.singleWhere(
          (key) => key['privateKey'] != '',
        );
        data['keys'] = publicOnlyFirst
            ? [publicKey, privateKey]
            : [privateKey, publicKey];

        await transferService.importMigrationData(
          data: data,
          mode: MigrationImportMode.replace,
        );

        expect(await keyRepository.getAll(), hasLength(2));
        final hosts = await hostRepository.getAll();
        final publicHost = hosts.singleWhere(
          (host) => host.label == 'Public host',
        );
        final privateHost = hosts.singleWhere(
          (host) => host.label == 'Private host',
        );
        expect(publicHost.keyId, isNot(privateHost.keyId));
        expect(
          (await keyRepository.getById(publicHost.keyId!))!.privateKey,
          isEmpty,
        );
        final importedPrivate = (await keyRepository.getById(
          privateHost.keyId!,
        ))!;
        expect(importedPrivate.privateKey, 'private-key-material');
        expect(importedPrivate.passphrase, 'key-passphrase');
      });
    }

    test('encrypts and decrypts host payload', () async {
      final snippetId = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: 'Attach tmux',
              command: 'tmux new -As MonkeySSH',
            ),
          );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Production',
              hostname: 'prod.example.com',
              username: 'root',
              password: const Value('secret'),
              skipJumpHostOnSsids: const Value('Home WiFi\nOffice WiFi'),
              autoConnectCommand: const Value('tmux new -As MonkeySSH'),
              autoConnectSnippetId: Value(snippetId),
              autoForwardPorts: const Value(true),
              portProxyName: const Value('production'),
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();

      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );
      final decrypted = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: '1234',
      );

      expect(decrypted.type, TransferPayloadType.host);
      final hostData = Map<String, dynamic>.from(decrypted.data['host'] as Map);
      expect(hostData['label'], 'Production');
      expect(hostData['hostname'], 'prod.example.com');
      expect(hostData['autoConnectCommand'], 'tmux new -As MonkeySSH');
      expect(hostData['autoConnectSnippetId'], isNull);
      expect(hostData['skipJumpHostOnSsids'], 'Home WiFi\nOffice WiFi');
      expect(hostData['autoForwardPorts'], isTrue);
      expect(hostData['portProxyName'], 'production');
    });

    for (final (version, fixture) in [
      (1, _v1EnvelopeFixture),
      (2, _v2EnvelopeFixture),
    ]) {
      test('decrypts the fixed v$version envelope', () async {
        for (final encoded in [fixture, '  ${fixture.substring(6)}\n']) {
          final payload = await transferService.decryptPayload(
            encodedPayload: encoded,
            transferPassphrase: 'fixture passphrase 🔐',
          );
          expect(payload.type, TransferPayloadType.host);
          expect(payload.schemaVersion, 1);
          expect(payload.createdAt, DateTime.utc(2026, 1, 2));
          expect(payload.data, {
            'host': {
              'label': 'Fixture 🐒',
              'hostname': 'example.com',
              'username': 'user',
            },
          });
        }
      });
    }

    test('round-trips a large migration payload', () async {
      final command = List.filled(2048, 'echo "migration 🐒"\n').join();
      await db.batch((batch) {
        batch.insertAll(db.snippets, [
          for (var i = 0; i < 32; i++)
            SnippetsCompanion.insert(name: 'Snippet $i', command: command),
        ]);
      });
      final expected = await transferService.createMigrationData();
      expect(
        utf8.encode(jsonEncode(expected)).length,
        greaterThan(1024 * 1024),
      );

      final encoded = await transferService.createFullMigrationPayload(
        transferPassphrase: 'large migration 🔐',
      );
      final decoded = await transferService.decryptPayload(
        encodedPayload: encoded,
        transferPassphrase: 'large migration 🔐',
      );

      expect(decoded.type, TransferPayloadType.fullMigration);
      expect(decoded.schemaVersion, 1);
      expect(decoded.data, expected);
      await transferService.importFullMigrationPayload(
        payload: decoded,
        mode: MigrationImportMode.replace,
      );
      final imported = await db.select(db.snippets).get();
      expect(imported, hasLength(32));
      expect(imported.every((snippet) => snippet.command == command), isTrue);
      expect(hostsChangedCount, 1);
    });

    test(
      'migration records use canonical JSON lexicographic ordering',
      () async {
        for (final id in [2, 10, 1]) {
          await db
              .into(db.groups)
              .insert(
                GroupsCompanion.insert(
                  id: Value(id),
                  name: 'Group $id',
                  createdAt: Value(DateTime.utc(2026)),
                ),
              );
        }
        final data = await transferService.createMigrationData();
        final groups = (data['groups'] as List).cast<Map<String, dynamic>>();
        expect(groups.map((group) => group['id']), [1, 10, 2]);
        for (final group in groups) {
          expect(group.keys, [
            'color',
            'createdAt',
            'icon',
            'id',
            'name',
            'parentId',
            'sortOrder',
          ]);
        }
        expect(await transferService.createMigrationData(), data);
      },
    );

    test(
      'createMigrationData includes skip-jump SSIDs in host exports',
      () async {
        await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Production',
            hostname: 'prod.example.com',
            username: 'root',
            skipJumpHostOnSsids: const Value('Home WiFi\nOffice WiFi'),
          ),
        );

        final migrationData = await transferService.createMigrationData();
        final hosts = migrationData['hosts'] as List;
        final hostData = Map<String, dynamic>.from(hosts.single as Map);

        expect(hostData['skipJumpHostOnSsids'], 'Home WiFi\nOffice WiFi');
      },
    );

    test(
      'full migration removes missing jump hosts and remains importable',
      () async {
        await db.customStatement('PRAGMA foreign_keys = OFF');
        await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Production',
                hostname: 'prod.example.com',
                username: 'root',
                jumpHostId: const Value(999),
              ),
            );

        final diagnosticsLogger = RecordingDiagnosticsLogger();
        final exportingService = SecureTransferService(
          db,
          keyRepository,
          hostRepository,
          diagnosticsLogger: diagnosticsLogger,
        );
        final encodedPayload = await exportingService
            .createFullMigrationPayload(transferPassphrase: '1234');

        final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(importedDb.close);
        final importedEncryptionService = SecretEncryptionService.forTesting();
        final importedTransferService = SecureTransferService(
          importedDb,
          KeyRepository(importedDb, importedEncryptionService),
          HostRepository(importedDb, importedEncryptionService),
        );
        final payload = await importedTransferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: '1234',
        );
        final exportedHosts = payload.data['hosts'] as List;
        final exportedHost = Map<String, dynamic>.from(
          exportedHosts.single as Map,
        );
        expect(exportedHost['jumpHostId'], isNull);
        final warning = diagnosticsLogger.events.singleWhere(
          (event) =>
              event.message == 'migration_export_jump_host_references_removed',
        );
        expect(warning.fields, {'removedCount': 1});

        await importedTransferService.importFullMigrationPayload(
          payload: payload,
          mode: MigrationImportMode.replace,
        );

        final importedHost = await importedDb
            .select(importedDb.hosts)
            .getSingle();
        expect(importedHost.label, 'Production');
        expect(importedHost.jumpHostId, isNull);
      },
    );

    test(
      'createMigrationData excludes port forwards for missing hosts',
      () async {
        final hostId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Production',
            hostname: 'prod.example.com',
            username: 'root',
          ),
        );
        await db
            .into(db.portForwards)
            .insert(
              PortForwardsCompanion.insert(
                name: 'valid',
                hostId: hostId,
                forwardType: 'local',
                localPort: 10022,
                remoteHost: '127.0.0.1',
                remotePort: 22,
              ),
            );
        await db.customStatement('PRAGMA foreign_keys = OFF');
        await db
            .into(db.portForwards)
            .insert(
              PortForwardsCompanion.insert(
                name: 'orphaned',
                hostId: 999,
                forwardType: 'local',
                localPort: 10023,
                remoteHost: '127.0.0.1',
                remotePort: 22,
              ),
            );

        final migrationData = await transferService.createMigrationData();
        final portForwards = migrationData['portForwards'] as List;
        final portForwardData = Map<String, dynamic>.from(
          portForwards.single as Map,
        );

        expect(portForwardData['name'], 'valid');
        expect(portForwardData['hostId'], hostId);

        final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(importedDb.close);
        final importedEncryptionService = SecretEncryptionService.forTesting();
        final importedTransferService = SecureTransferService(
          importedDb,
          KeyRepository(importedDb, importedEncryptionService),
          HostRepository(importedDb, importedEncryptionService),
        );

        await importedTransferService.importMigrationData(
          data: migrationData,
          mode: MigrationImportMode.replace,
        );

        final importedPortForwards = await importedDb
            .select(importedDb.portForwards)
            .get();
        expect(importedPortForwards, hasLength(1));
      },
    );

    test(
      'includes referenced key data when requested for host export',
      () async {
        final keyId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Deploy Key',
            keyType: 'ed25519',
            publicKey: _publicKeyA,
            privateKey: 'test-open-ssh-key-materialxyz',
          ),
        );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Production',
                hostname: 'prod.example.com',
                username: 'root',
                keyId: Value(keyId),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((h) => h.id.equals(hostId))).getSingle();

        final encodedPayload = await transferService.createHostPayload(
          host: host,
          transferPassphrase: '1234',
          includeReferencedKey: true,
        );
        final decrypted = await transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: '1234',
        );

        final hostData = Map<String, dynamic>.from(
          decrypted.data['host'] as Map,
        );
        final referencedKey = decrypted.data['referencedKey'];
        expect(hostData['keyId'], keyId);
        expect(referencedKey, isA<Map>());
        expect((referencedKey as Map)['name'], 'Deploy Key');
      },
    );

    test(
      'importKeyPayload encrypts imported private material at rest',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.key,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'key': {
              'name': 'Imported Key',
              'keyType': 'ed25519',
              'publicKey': _publicKeyA,
              'privateKey': 'test-open-ssh-key-materialabc',
              'passphrase': 'pass',
            },
          },
        );

        final imported = await transferService.importKeyPayload(payload);
        expect(imported.privateKey, 'test-open-ssh-key-materialabc');
        expect(imported.passphrase, 'pass');

        final stored = await (db.select(
          db.sshKeys,
        )..where((k) => k.id.equals(imported.id))).getSingle();
        expect(stored.privateKey, startsWith('ENCv1:'));
        expect(stored.passphrase, startsWith('ENCv1:'));
      },
    );

    test('importHostPayload encrypts imported password at rest', () async {
      final payload = TransferPayload(
        type: TransferPayloadType.host,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'host': {
            'label': 'Imported Host',
            'hostname': 'imported.example.com',
            'port': 22,
            'username': 'root',
            'password': 'host-pass',
            'skipJumpHostOnSsids': 'Home WiFi\nOffice WiFi',
            'isFavorite': false,
            'autoForwardPorts': true,
            'portProxyName': 'Imported.Dev.LocalHost',
          },
        },
      );

      final imported = await transferService.importHostPayload(payload);
      expect(imported.password, 'host-pass');
      expect(imported.skipJumpHostOnSsids, 'Home WiFi\nOffice WiFi');
      expect(imported.autoConnectRequiresConfirmation, isFalse);
      expect(imported.autoForwardPorts, isTrue);
      expect(imported.portProxyName, 'imported.dev');
      expect(hostsChangedCount, 1);

      final stored = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(imported.id))).getSingle();
      expect(stored.password, startsWith('ENCv1:'));
      expect(stored.skipJumpHostOnSsids, 'Home WiFi\nOffice WiFi');
    });

    test('importHostPayload drops invalid optional proxy domains', () async {
      final payload = TransferPayload(
        type: TransferPayloadType.host,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'host': {
            'label': 'Imported Host',
            'hostname': 'imported.example.com',
            'username': 'root',
            'portProxyName': '-invalid',
          },
        },
      );

      final imported = await transferService.importHostPayload(payload);

      expect(imported.portProxyName, isNull);
    });

    test('importHostPayload preserves host CLI launch preferences', () async {
      final settingsService = SettingsService(db);
      final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
        settingsService,
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Imported Host',
              hostname: 'imported.example.com',
              username: 'root',
            ),
          );
      await cliLaunchPreferencesService.setPreferencesForHost(
        hostId,
        const HostCliLaunchPreferences(startInYoloMode: true),
      );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();

      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: '1234',
      );
      final decryptedPayload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: '1234',
      );

      final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(importedDb.close);
      final importedEncryptionService = SecretEncryptionService.forTesting();
      final importedTransferService = SecureTransferService(
        importedDb,
        KeyRepository(importedDb, importedEncryptionService),
        HostRepository(importedDb, importedEncryptionService),
      );
      final importedSettingsService = SettingsService(importedDb);
      final importedCliLaunchPreferencesService =
          HostCliLaunchPreferencesService(importedSettingsService);

      final importedHost = await importedTransferService.importHostPayload(
        decryptedPayload,
      );
      final importedPreferences = await importedCliLaunchPreferencesService
          .getPreferencesForHost(importedHost.id);

      expect(importedPreferences.startInYoloMode, isTrue);
    });

    test(
      'marks imported auto-connect commands for review before first run',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.host,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'host': {
              'label': 'Imported Host',
              'hostname': 'imported.example.com',
              'port': 22,
              'username': 'root',
              'autoConnectCommand': '  tmux attach  ',
            },
          },
        );

        final imported = await transferService.importHostPayload(payload);

        expect(imported.autoConnectCommand, 'tmux attach');
        expect(imported.autoConnectRequiresConfirmation, isTrue);
      },
    );

    test(
      'rejects imported auto-connect commands with hidden control characters',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.host,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'host': {
              'label': 'Imported Host',
              'hostname': 'imported.example.com',
              'port': 22,
              'username': 'root',
              'autoConnectCommand': 'tmux attach\x00rm -rf /',
            },
          },
        );

        await expectLater(
          transferService.importHostPayload(payload),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects imported auto-connect snippets with hidden control characters',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'snippets': [
              {'id': 5, 'name': 'Auto connect', 'command': 'printf "ok"\x00'},
            ],
            'hosts': [
              {
                'id': 1,
                'label': 'Imported Host',
                'hostname': 'imported.example.com',
                'port': 22,
                'username': 'root',
                'autoConnectSnippetId': 5,
              },
            ],
          },
        );

        await expectLater(
          transferService.importFullMigrationPayload(
            payload: payload,
            mode: MigrationImportMode.merge,
          ),
          throwsFormatException,
        );
      },
    );

    test('rejects invalid passphrase', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Host',
              hostname: 'example.com',
              username: 'user',
            ),
          );
      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(hostId))).getSingle();
      final encodedPayload = await transferService.createHostPayload(
        host: host,
        transferPassphrase: 'correct',
      );

      await expectLater(
        transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: 'wrong',
        ),
        throwsFormatException,
      );
    });

    for (final (name, field, value) in [
      ('invalid component lengths', 'salt', base64Url.encode(const [1, 2, 3])),
      ('non-string encoded components', 'salt', 42),
      ('invalid iteration count', 'iter', 0),
      ('excessive iteration count', 'iter', 1000001),
    ]) {
      test('rejects envelope with $name', () async {
        final envelope = <String, dynamic>{
          'v': 2,
          'alg': 'AES-GCM-256',
          'kdf': 'Argon2id',
          'iter': 3,
          'mem': 32768,
          'lanes': 1,
          'salt': base64Url.encode(List<int>.filled(16, 0)),
          'nonce': base64Url.encode(List<int>.filled(12, 0)),
          'mac': base64Url.encode(List<int>.filled(16, 0)),
          'ciphertext': base64Url.encode([1]),
          'checksum': base64Url.encode(List<int>.filled(32, 0)),
        };
        envelope[field] = value;
        final tampered =
            'MSSH1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';

        await expectLater(
          transferService.decryptPayload(
            encodedPayload: tampered,
            transferPassphrase: '1234',
          ),
          throwsFormatException,
        );
      });
    }

    test('fails migration when host references missing key mapping', () async {
      final payload = TransferPayload(
        type: TransferPayloadType.fullMigration,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'keys': <Map<String, dynamic>>[],
          'groups': <Map<String, dynamic>>[],
          'hosts': [
            {
              'id': 1,
              'label': 'Host',
              'hostname': 'example.com',
              'username': 'root',
              'keyId': 999,
            },
          ],
        },
      );

      await expectLater(
        transferService.importFullMigrationPayload(
          payload: payload,
          mode: MigrationImportMode.merge,
        ),
        throwsFormatException,
      );
    });

    test('removes missing jump host references during import', () async {
      final diagnosticsLogger = RecordingDiagnosticsLogger();
      final service = SecureTransferService(
        db,
        keyRepository,
        hostRepository,
        diagnosticsLogger: diagnosticsLogger,
      );
      final payload = TransferPayload(
        type: TransferPayloadType.fullMigration,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'hosts': [
            {
              'id': 1,
              'label': 'Host',
              'hostname': 'example.com',
              'username': 'root',
              'jumpHostId': 999,
            },
          ],
        },
      );

      await service.importFullMigrationPayload(
        payload: payload,
        mode: MigrationImportMode.merge,
      );

      final importedHost = await db.select(db.hosts).getSingle();
      expect(importedHost.jumpHostId, isNull);
      final warning = diagnosticsLogger.events.singleWhere(
        (event) =>
            event.message == 'migration_import_jump_host_references_removed',
      );
      expect(warning.fields, {'removedCount': 1});
    });

    test(
      'skips migration port forwards that reference missing hosts',
      () async {
        final payload = TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'hosts': <Map<String, dynamic>>[],
            'portForwards': [
              {
                'name': 'pf',
                'hostId': 999,
                'forwardType': 'local',
                'localPort': 10022,
                'remoteHost': '127.0.0.1',
                'remotePort': 22,
              },
            ],
          },
        );

        await transferService.importFullMigrationPayload(
          payload: payload,
          mode: MigrationImportMode.merge,
        );

        final portForwards = await db.select(db.portForwards).get();
        expect(portForwards, isEmpty);
      },
    );

    test(
      'imports full migration in replace mode with self references',
      () async {
        await db
            .into(db.settings)
            .insert(SettingsCompanion.insert(key: 'extra', value: '1'));
        await transferService.importMigrationData(
          mode: MigrationImportMode.replace,
          data: {
            'settings': {'theme_mode': 'dark'},
            'groups': [
              {'id': 101, 'name': 'Parent Group'},
              {'id': 102, 'name': 'Child Group', 'parentId': 101},
            ],
            'keys': [
              {
                'id': 201,
                'name': 'Main Key',
                'keyType': 'ed25519',
                'publicKey': _publicKeyA,
                'privateKey': 'test-open-ssh-key-materialabc',
              },
            ],
            'hosts': [
              {
                'id': 301,
                'label': 'A',
                'hostname': 'a.example.com',
                'username': 'root',
                'keyId': 201,
                'groupId': 102,
                'autoConnectCommand': 'ls -la',
                'autoConnectSnippetId': 501,
              },
              {
                'id': 302,
                'label': 'B',
                'hostname': 'b.example.com',
                'username': 'root',
                'jumpHostId': 301,
                'skipJumpHostOnSsids': 'Home WiFi\nOffice WiFi',
              },
            ],
            'snippetFolders': [
              {'id': 401, 'name': 'Parent Folder'},
              {'id': 402, 'name': 'Child Folder', 'parentId': 401},
            ],
            'snippets': [
              {
                'id': 501,
                'name': 'List files',
                'command': 'ls -la',
                'folderId': 402,
              },
            ],
            'portForwards': [
              {
                'name': 'pf',
                'hostId': 301,
                'forwardType': 'local',
                'localPort': 10022,
                'remoteHost': '127.0.0.1',
                'remotePort': 22,
              },
            ],
            'knownHosts': [
              {
                'hostname': 'example.com',
                'port': 22,
                'keyType': 'ssh-ed25519',
                'fingerprint': 'abc',
                'hostKey': 'ssh-ed25519 AAAA',
              },
            ],
          },
        );

        final extraSetting = await (db.select(
          db.settings,
        )..where((s) => s.key.equals('extra'))).getSingleOrNull();
        final hosts = await db.select(db.hosts).get();
        final hostA = hosts.firstWhere((host) => host.label == 'A');
        final hostB = hosts.firstWhere((host) => host.label == 'B');
        final importedSnippet = await (db.select(
          db.snippets,
        )..where((snippet) => snippet.name.equals('List files'))).getSingle();
        final groups = await db.select(db.groups).get();
        final snippetFolders = await db.select(db.snippetFolders).get();
        final portForwards = await db.select(db.portForwards).get();

        expect(extraSetting, isNull);
        expect(hosts, hasLength(2));
        expect(hostA.autoConnectCommand, 'ls -la');
        expect(hostA.autoConnectSnippetId, importedSnippet.id);
        expect(hostA.autoConnectRequiresConfirmation, isTrue);
        expect(hostB.skipJumpHostOnSsids, 'Home WiFi\nOffice WiFi');
        expect(groups, hasLength(2));
        expect(snippetFolders, hasLength(2));
        expect(portForwards, hasLength(1));
        final parentGroup = groups.firstWhere(
          (group) => group.name == 'Parent Group',
        );
        final childGroup = groups.firstWhere(
          (group) => group.name == 'Child Group',
        );
        final parentFolder = snippetFolders.firstWhere(
          (folder) => folder.name == 'Parent Folder',
        );
        final childFolder = snippetFolders.firstWhere(
          (folder) => folder.name == 'Child Folder',
        );
        expect(childGroup.parentId, parentGroup.id);
        expect(hostA.groupId, childGroup.id);
        expect(hostA.keyId, (await keyRepository.getAll()).single.id);
        expect(hostB.jumpHostId, hostA.id);
        expect(childFolder.parentId, parentFolder.id);
        expect(importedSnippet.folderId, childFolder.id);
        expect(portForwards.single.hostId, hostA.id);
        expect(
          (await db.select(db.knownHosts).get()).single.hostname,
          'example.com',
        );
        expect((await db.select(db.settings).get()).single.value, 'dark');
      },
    );

    test(
      'imports full migration in merge mode and preserves extra data',
      () async {
        await db
            .into(db.settings)
            .insert(
              SettingsCompanion.insert(key: 'theme_mode', value: 'light'),
            );
        await db
            .into(db.settings)
            .insert(SettingsCompanion.insert(key: 'extra', value: '1'));
        await transferService.importMigrationData(
          data: {
            'settings': {'theme_mode': 'dark', 'incoming': 'new'},
          },
          mode: MigrationImportMode.merge,
        );

        final settings = await db.select(db.settings).get();
        expect(
          {for (final setting in settings) setting.key: setting.value},
          {'theme_mode': 'dark', 'incoming': 'new', 'extra': '1'},
        );
      },
    );

    test(
      'logs migration diagnostics without sensitive payload values',
      () async {
        final diagnosticsLogger = RecordingDiagnosticsLogger();
        final service = SecureTransferService(
          db,
          keyRepository,
          hostRepository,
          diagnosticsLogger: diagnosticsLogger,
        );
        final data = {
          'settings': {'recentCommand': 'cat /Users/alice/.ssh/id_ed25519'},
          'snippets': [
            {
              'id': 5,
              'name': 'Deploy secret title',
              'command': 'cat /Users/alice/.ssh/config',
            },
          ],
          'hosts': [
            {
              'id': 1,
              'label': 'Production secret label',
              'hostname': 'prod.secret.example.com',
              'port': 22,
              'username': 'deploy-user',
              'password': 'host-password',
              'autoConnectSnippetId': 5,
            },
          ],
          'portForwards': [
            {
              'name': 'Private database tunnel',
              'hostId': 1,
              'forwardType': 'local',
              'localHost': '127.0.0.1',
              'localPort': 15432,
              'remoteHost': 'db.internal.example.com',
              'remotePort': 5432,
            },
          ],
        };

        await service.importMigrationData(
          data: data,
          mode: MigrationImportMode.merge,
        );

        expect(
          diagnosticsLogger.events.map((event) => event.message),
          containsAll([
            'migration_import_started',
            'migration_import_completed',
          ]),
        );
        expect(diagnosticsLogger.events.first.fields, {
          'mode': MigrationImportMode.merge,
          'settingsCount': 1,
          'groupCount': 0,
          'keyCount': 0,
          'hostCount': 1,
          'snippetFolderCount': 0,
          'snippetCount': 1,
          'portForwardCount': 1,
          'knownHostCount': 0,
        });

        final diagnosticsText = diagnosticsLogger.events
            .map((event) => event.searchableText)
            .join('\n');
        for (final sensitiveValue in [
          'cat /Users/alice/.ssh/id_ed25519',
          'cat /Users/alice/.ssh/config',
          'Deploy secret title',
          'Production secret label',
          'prod.secret.example.com',
          'deploy-user',
          'host-password',
          'Private database tunnel',
          'db.internal.example.com',
        ]) {
          expect(diagnosticsText, isNot(contains(sensitiveValue)));
        }
      },
    );

    test(
      'importMigrationData preserves epoch-millisecond host timestamps',
      () async {
        final createdAt = DateTime.utc(2026, 4, 9, 4);
        final updatedAt = DateTime.utc(2026, 4, 9, 4, 0, 5);
        await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Timestamped Host',
            hostname: 'timestamps.example.com',
            username: 'root',
            createdAt: Value(createdAt),
            updatedAt: Value(updatedAt),
          ),
        );

        final migrationData = await transferService.createMigrationData();

        final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(importedDb.close);
        final importedEncryptionService = SecretEncryptionService.forTesting();
        final importedTransferService = SecureTransferService(
          importedDb,
          KeyRepository(importedDb, importedEncryptionService),
          HostRepository(importedDb, importedEncryptionService),
        );

        await importedTransferService.importMigrationData(
          data: migrationData,
          mode: MigrationImportMode.replace,
        );

        final importedHost = await importedDb
            .select(importedDb.hosts)
            .getSingle();
        expect(importedHost.createdAt.toUtc(), createdAt);
        expect(importedHost.updatedAt.toUtc(), updatedAt);
      },
    );

    test(
      'merge import remaps and preserves host-scoped launch settings',
      () async {
        final sourceSettingsService = SettingsService(db);
        final sourcePresetService = AgentLaunchPresetService(
          sourceSettingsService,
        );
        final sourceCliLaunchPreferencesService =
            HostCliLaunchPreferencesService(sourceSettingsService);
        final sourceHostId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'Imported Host',
            hostname: 'imported.example.com',
            username: 'root',
          ),
        );
        await sourcePresetService.setPresetForHost(
          sourceHostId,
          const AgentLaunchPreset(
            tool: AgentLaunchTool.codex,
            additionalArguments: '--model gpt-5.4',
          ),
        );
        await sourceCliLaunchPreferencesService.setPreferencesForHost(
          sourceHostId,
          const HostCliLaunchPreferences(startInYoloMode: true),
        );
        final migrationData = await transferService.createMigrationData();

        final importedDb = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(importedDb.close);
        final importedEncryptionService = SecretEncryptionService.forTesting();
        final importedHostRepository = HostRepository(
          importedDb,
          importedEncryptionService,
        );
        final importedTransferService = SecureTransferService(
          importedDb,
          KeyRepository(importedDb, importedEncryptionService),
          importedHostRepository,
        );
        final importedSettingsService = SettingsService(importedDb);
        final importedPresetService = AgentLaunchPresetService(
          importedSettingsService,
        );
        final importedCliLaunchPreferencesService =
            HostCliLaunchPreferencesService(importedSettingsService);

        final localHostId = await importedHostRepository.insert(
          HostsCompanion.insert(
            label: 'Local Host',
            hostname: 'local.example.com',
            username: 'root',
          ),
        );
        await importedPresetService.setPresetForHost(
          localHostId,
          const AgentLaunchPreset(
            tool: AgentLaunchTool.claudeCode,
            additionalArguments: '--resume',
          ),
        );
        await importedCliLaunchPreferencesService.setPreferencesForHost(
          localHostId,
          const HostCliLaunchPreferences(startInYoloMode: true),
        );

        await importedTransferService.importMigrationData(
          data: migrationData,
          mode: MigrationImportMode.merge,
        );

        final importedHost = await (importedDb.select(
          importedDb.hosts,
        )..where((host) => host.label.equals('Imported Host'))).getSingle();
        final localPreset = await importedPresetService.getPresetForHost(
          localHostId,
        );
        final importedPreset = await importedPresetService.getPresetForHost(
          importedHost.id,
        );
        final localPreferences = await importedCliLaunchPreferencesService
            .getPreferencesForHost(localHostId);
        final importedPreferences = await importedCliLaunchPreferencesService
            .getPreferencesForHost(importedHost.id);

        expect(importedHost.id, isNot(localHostId));
        expect(localPreset?.tool, AgentLaunchTool.claudeCode);
        expect(localPreset?.additionalArguments, '--resume');
        expect(importedPreset?.tool, AgentLaunchTool.codex);
        expect(importedPreset?.additionalArguments, '--model gpt-5.4');
        expect(localPreferences.startInYoloMode, isTrue);
        expect(importedPreferences.startInYoloMode, isTrue);
      },
    );

    test(
      'importMigrationData tolerates out-of-range epoch-millisecond host timestamps',
      () async {
        await transferService.importMigrationData(
          data: {
            'hosts': [
              {
                'id': 1,
                'label': 'Out Of Range Host',
                'hostname': 'out-of-range.example.com',
                'username': 'root',
                'createdAt': 8640000000000001,
                'updatedAt': '8640000000000001',
              },
            ],
          },
          mode: MigrationImportMode.replace,
        );

        final now = DateTime.now().toUtc();
        final importedHost = await db.select(db.hosts).getSingle();

        expect(importedHost.label, 'Out Of Range Host');
        expect(
          importedHost.createdAt.toUtc().difference(now).abs(),
          lessThan(const Duration(minutes: 1)),
        );
        expect(
          importedHost.updatedAt.toUtc().difference(now).abs(),
          lessThan(const Duration(minutes: 1)),
        );
      },
    );

    test(
      'merge import replaces an older known-host entry with newer trust data',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);
        final importedKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [9, 8, 7, 6],
          firstSeen: importedFirstSeen,
          lastSeen: importedLastSeen,
        );

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [importedKnownHost.toJson()],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.hostKey, importedKnownHost.hostKey);
        expect(storedKnownHost.fingerprint, importedKnownHost.fingerprint);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    test(
      'merge import preserves a newer local known-host entry when import is older',
      () async {
        final existingFirstSeen = DateTime.utc(2024, 2);
        final existingLastSeen = DateTime.utc(2024, 2, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [9, 8, 7, 6],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        final importedKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: DateTime.utc(2024),
          lastSeen: DateTime.utc(2024, 1, 2),
        );

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [importedKnownHost.toJson()],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.hostKey, existingKnownHost.hostKey);
        expect(storedKnownHost.fingerprint, existingKnownHost.fingerprint);
        expect(storedKnownHost.firstSeen.toUtc(), existingFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), existingLastSeen);
      },
    );

    test('imports fingerprint-only legacy known-host rows', () async {
      const importedFingerprint = 'SHA256:legacyFingerprintOnlyRow';
      final importedFirstSeen = DateTime.utc(2024, 3);
      final importedLastSeen = DateTime.utc(2024, 3, 2);

      await transferService.importFullMigrationPayload(
        payload: TransferPayload(
          type: TransferPayloadType.fullMigration,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'knownHosts': [
              {
                'hostname': 'legacy.example.com',
                'port': 2222,
                'keyType': 'ssh-ed25519',
                'fingerprint': importedFingerprint,
                'hostKey': '',
                'firstSeen': importedFirstSeen.toIso8601String(),
                'lastSeen': importedLastSeen.toIso8601String(),
              },
            ],
          },
        ),
        mode: MigrationImportMode.merge,
      );

      final storedKnownHost =
          await (db.select(db.knownHosts)..where(
                (knownHost) => knownHost.hostname.equals('legacy.example.com'),
              ))
              .getSingle();
      expect(storedKnownHost.port, 2222);
      expect(storedKnownHost.keyType, 'ssh-ed25519');
      expect(storedKnownHost.fingerprint, importedFingerprint);
      expect(storedKnownHost.hostKey, isEmpty);
      expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
      expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
    });

    test(
      'merge import falls back to fingerprint-only trust for malformed host keys',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        const importedFingerprint = 'SHA256:malformedImportedHostKey';
        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [
                {
                  'hostname': 'shared.example.com',
                  'port': 22,
                  'keyType': 'ssh-ed25519',
                  'fingerprint': importedFingerprint,
                  'hostKey': 'not base64',
                  'firstSeen': importedFirstSeen.toIso8601String(),
                  'lastSeen': importedLastSeen.toIso8601String(),
                },
              ],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.keyType, 'ssh-ed25519');
        expect(storedKnownHost.fingerprint, importedFingerprint);
        expect(storedKnownHost.hostKey, isEmpty);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    test(
      'merge import falls back to fingerprint-only trust for non-host-key base64 blobs',
      () async {
        final existingFirstSeen = DateTime.utc(2024);
        final existingLastSeen = DateTime.utc(2024, 1, 2);
        final existingKnownHost = _knownHostRecord(
          hostname: 'shared.example.com',
          keyData: const [1, 2, 3, 4],
          firstSeen: existingFirstSeen,
          lastSeen: existingLastSeen,
        );
        await db.into(db.knownHosts).insert(existingKnownHost.toCompanion());

        const importedFingerprint = 'SHA256:decodableButNotHostKey';
        final importedFirstSeen = DateTime.utc(2024, 2);
        final importedLastSeen = DateTime.utc(2024, 2, 2);

        await transferService.importFullMigrationPayload(
          payload: TransferPayload(
            type: TransferPayloadType.fullMigration,
            schemaVersion: 1,
            createdAt: DateTime.now().toUtc(),
            data: {
              'knownHosts': [
                {
                  'hostname': 'shared.example.com',
                  'port': 22,
                  'keyType': 'ssh-ed25519',
                  'fingerprint': importedFingerprint,
                  'hostKey': base64.encode(utf8.encode('not-an-ssh-host-key')),
                  'firstSeen': importedFirstSeen.toIso8601String(),
                  'lastSeen': importedLastSeen.toIso8601String(),
                },
              ],
            },
          ),
          mode: MigrationImportMode.merge,
        );

        final storedKnownHost =
            await (db.select(db.knownHosts)..where(
                  (knownHost) =>
                      knownHost.hostname.equals('shared.example.com'),
                ))
                .getSingle();
        expect(storedKnownHost.keyType, 'ssh-ed25519');
        expect(storedKnownHost.fingerprint, importedFingerprint);
        expect(storedKnownHost.hostKey, isEmpty);
        expect(storedKnownHost.firstSeen.toUtc(), importedFirstSeen);
        expect(storedKnownHost.lastSeen.toUtc(), importedLastSeen);
      },
    );

    for (final (
          encryptedAtRest,
          name,
          privateKey,
          keyPassphrase,
          transferPassphrase,
        )
        in [
          (
            false,
            'Deploy Key',
            'test-open-ssh-key-materialxyz',
            'key-passphrase',
            '1234',
          ),
          (
            true,
            'Unprotected Key',
            'test-open-ssh-key-unprotectedxyz',
            null,
            'pass',
          ),
        ]) {
      test('encrypts and imports $name payload', () async {
        final entry = SshKeysCompanion.insert(
          name: name,
          keyType: 'ed25519',
          publicKey: _publicKeyA,
          privateKey: privateKey,
          passphrase: Value(keyPassphrase),
        );
        final keyId = encryptedAtRest
            ? await keyRepository.insert(entry)
            : await db.into(db.sshKeys).insert(entry);
        final key = await (db.select(
          db.sshKeys,
        )..where((k) => k.id.equals(keyId))).getSingle();

        final encodedPayload = await transferService.createKeyPayload(
          key: key,
          transferPassphrase: transferPassphrase,
        );

        await db.delete(db.sshKeys).go();

        final decrypted = await transferService.decryptPayload(
          encodedPayload: encodedPayload,
          transferPassphrase: transferPassphrase,
        );
        final importedKey = await transferService.importKeyPayload(decrypted);

        expect(importedKey.name, name);
        expect(importedKey.privateKey, privateKey);
        expect(importedKey.passphrase, keyPassphrase);
      });
    }

    test(
      'importKeyPayload does not deduplicate by fingerprint alone',
      () async {
        final existingId = await keyRepository.insert(
          SshKeysCompanion.insert(
            name: 'Existing Key',
            keyType: 'ed25519',
            publicKey: _publicKeyA,
            privateKey: 'test-open-ssh-key-existing',
            fingerprint: const Value(_publicKeyAFingerprint),
          ),
        );

        // Import a payload that lies about sharing the same fingerprint.
        final payload = TransferPayload(
          type: TransferPayloadType.key,
          schemaVersion: 1,
          createdAt: DateTime.now().toUtc(),
          data: {
            'key': {
              'name': 'Re-imported Key',
              'keyType': 'ed25519',
              'publicKey': _publicKeyB,
              'privateKey': 'test-open-ssh-key-different',
              'fingerprint': _publicKeyAFingerprint,
            },
          },
        );

        final imported = await transferService.importKeyPayload(payload);

        expect(imported.id, isNot(existingId));
        expect(imported.name, 'Re-imported Key');
        expect(imported.fingerprint, _publicKeyBFingerprint);

        final allKeys = await db.select(db.sshKeys).get();
        expect(allKeys, hasLength(2));
      },
    );

    test('importKeyPayload deduplicates by public+private key pair when no '
        'fingerprint is present', () async {
      const publicKey = _publicKeyA;
      const privateKey = 'test-open-ssh-key-sharedprivkey';

      final existingId = await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Existing Key',
          keyType: 'ed25519',
          publicKey: publicKey,
          privateKey: privateKey,
        ),
      );

      final payload = TransferPayload(
        type: TransferPayloadType.key,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'key': {
            'name': 'Duplicate Key',
            'keyType': 'ed25519',
            'publicKey': publicKey,
            'privateKey': privateKey,
          },
        },
      );

      final imported = await transferService.importKeyPayload(payload);

      expect(imported.id, existingId);

      final allKeys = await db.select(db.sshKeys).get();
      expect(allKeys, hasLength(1));
    });

    test('importKeyPayload inserts a new key when neither fingerprint nor '
        'key material matches an existing entry', () async {
      await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Unrelated Key',
          keyType: 'ed25519',
          publicKey: _publicKeyA,
          privateKey: 'test-open-ssh-key-unrelated',
          fingerprint: const Value(_publicKeyAFingerprint),
        ),
      );

      final payload = TransferPayload(
        type: TransferPayloadType.key,
        schemaVersion: 1,
        createdAt: DateTime.now().toUtc(),
        data: {
          'key': {
            'name': 'Brand New Key',
            'keyType': 'ed25519',
            'publicKey': _publicKeyB,
            'privateKey': 'test-open-ssh-key-newkey',
            'fingerprint': 'SHA256:forged',
          },
        },
      );

      final imported = await transferService.importKeyPayload(payload);

      expect(imported.name, 'Brand New Key');

      final allKeys = await db.select(db.sshKeys).get();
      expect(allKeys, hasLength(2));
    });

    test(
      'rejects invalid auto-connect snippet reference in migration',
      () async {
        await expectLater(
          transferService.importMigrationData(
            data: {
              'snippets': [
                {'id': 101, 'name': 'List files', 'command': 'ls -la'},
              ],
              'hosts': [
                {
                  'id': 201,
                  'label': 'A',
                  'hostname': 'a.example.com',
                  'username': 'root',
                  'autoConnectCommand': 'ls -la',
                  'autoConnectSnippetId': 999,
                },
              ],
            },
            mode: MigrationImportMode.merge,
          ),
          throwsFormatException,
        );
      },
    );
  });
}

_KnownHostFixture _knownHostRecord({
  required String hostname,
  required List<int> keyData,
  required DateTime firstSeen,
  required DateTime lastSeen,
  int port = 22,
  String keyType = 'ssh-ed25519',
}) {
  final hostKeyBytes = _ed25519HostKeyBlob(keyData);
  final hostKey = base64.encode(hostKeyBytes);
  return _KnownHostFixture(
    hostname: hostname,
    port: port,
    keyType: keyType,
    fingerprint: formatSshHostKeyFingerprint(hostKeyBytes),
    hostKey: hostKey,
    firstSeen: firstSeen,
    lastSeen: lastSeen,
  );
}

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-ed25519')))
    ..add(_sshString(keyData));
  return writer.takeBytes();
}

Uint8List _sshString(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

class _KnownHostFixture {
  const _KnownHostFixture({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.hostKey,
    required this.firstSeen,
    required this.lastSeen,
  });

  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;
  final String hostKey;
  final DateTime firstSeen;
  final DateTime lastSeen;

  KnownHostsCompanion toCompanion() => KnownHostsCompanion.insert(
    hostname: hostname,
    port: port,
    keyType: keyType,
    fingerprint: fingerprint,
    hostKey: hostKey,
    firstSeen: Value(firstSeen),
    lastSeen: Value(lastSeen),
  );

  Map<String, dynamic> toJson() => {
    'hostname': hostname,
    'port': port,
    'keyType': keyType,
    'fingerprint': fingerprint,
    'hostKey': hostKey,
    'firstSeen': firstSeen.toIso8601String(),
    'lastSeen': lastSeen.toIso8601String(),
  };
}
