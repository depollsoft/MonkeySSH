// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('database open strategy', () {
    test('uses background opening only for non-Apple native platforms', () {
      expect(
        shouldOpenDatabaseInBackground(
          isWeb: false,
          isIOS: false,
          isMacOS: false,
        ),
        isTrue,
      );
      expect(
        shouldOpenDatabaseInBackground(
          isWeb: false,
          isIOS: true,
          isMacOS: false,
        ),
        isFalse,
      );
      expect(
        shouldOpenDatabaseInBackground(
          isWeb: false,
          isIOS: false,
          isMacOS: true,
        ),
        isFalse,
      );
      expect(
        shouldOpenDatabaseInBackground(
          isWeb: true,
          isIOS: false,
          isMacOS: false,
        ),
        isFalse,
      );
    });
  });

  group('Database storage path', () {
    Future<void> noOpFilePolicy(
      Directory databaseDirectory,
      File databaseFile,
    ) async {}

    Future<Directory> createTestRootDirectory(String name) async {
      final rootDirectory = Directory(
        p.join(
          Directory.current.path,
          '.dart_tool',
          'database_test',
          '$name-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await rootDirectory.create(recursive: true);
      addTearDown(() async {
        if (rootDirectory.existsSync()) {
          await rootDirectory.delete(recursive: true);
        }
      });
      return rootDirectory;
    }

    test('migrates legacy flutty.db from documents to app support', () async {
      final rootDirectory = await createTestRootDirectory('migration');

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);

      final legacyFile = File(p.join(documentsDirectory.path, 'flutty.db'));
      await legacyFile.writeAsString('legacy-db');
      final legacyJournalFile = File('${legacyFile.path}-journal');
      await legacyJournalFile.writeAsString('legacy-journal');
      Directory? protectedDirectory;
      File? protectedFile;

      final resolvedFile = await resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
        applyFilePolicy: (databaseDirectory, databaseFile) async {
          protectedDirectory = databaseDirectory;
          protectedFile = databaseFile;
        },
      );

      expect(resolvedFile.path, p.join(supportDirectory.path, 'flutty.db'));
      expect(resolvedFile.existsSync(), isTrue);
      expect(await resolvedFile.readAsString(), 'legacy-db');
      final migratedJournalFile = File('${resolvedFile.path}-journal');
      expect(migratedJournalFile.existsSync(), isTrue);
      expect(await migratedJournalFile.readAsString(), 'legacy-journal');
      expect(legacyFile.existsSync(), isFalse);
      expect(legacyJournalFile.existsSync(), isFalse);
      expect(protectedDirectory?.path, supportDirectory.path);
      expect(protectedFile?.path, resolvedFile.path);
    });

    test('moves legacy companion files when migration marker exists', () async {
      final rootDirectory = await createTestRootDirectory(
        'companion-migration',
      );

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);
      await supportDirectory.create(recursive: true);

      final supportFile = File(p.join(supportDirectory.path, 'flutty.db'));
      await supportFile.writeAsString('new-db');
      final markerFile = File(
        p.join(supportDirectory.path, 'flutty.db.legacy-migration-incomplete'),
      );
      await markerFile.writeAsString('pending');

      final legacyJournalFile = File(
        p.join(documentsDirectory.path, 'flutty.db-journal'),
      );
      await legacyJournalFile.writeAsString('legacy-journal');
      Directory? protectedDirectory;
      File? protectedFile;

      final resolvedFile = await resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
        applyFilePolicy: (databaseDirectory, databaseFile) async {
          protectedDirectory = databaseDirectory;
          protectedFile = databaseFile;
        },
      );

      expect(resolvedFile.path, supportFile.path);
      final migratedJournalFile = File('${resolvedFile.path}-journal');
      expect(migratedJournalFile.existsSync(), isTrue);
      expect(await migratedJournalFile.readAsString(), 'legacy-journal');
      expect(legacyJournalFile.existsSync(), isFalse);
      expect(markerFile.existsSync(), isFalse);
      expect(protectedDirectory?.path, supportDirectory.path);
      expect(protectedFile?.path, resolvedFile.path);
    });

    test(
      'deletes orphan legacy companion files after migration completion',
      () async {
        final rootDirectory = await createTestRootDirectory(
          'companion-cleanup',
        );

        final documentsDirectory = Directory(
          p.join(rootDirectory.path, 'docs'),
        );
        final supportDirectory = Directory(
          p.join(rootDirectory.path, 'support'),
        );
        await documentsDirectory.create(recursive: true);
        await supportDirectory.create(recursive: true);

        final supportFile = File(p.join(supportDirectory.path, 'flutty.db'));
        await supportFile.writeAsString('new-db');

        final legacyJournalFile = File(
          p.join(documentsDirectory.path, 'flutty.db-journal'),
        );
        await legacyJournalFile.writeAsString('orphan-journal');

        await resolveDatabaseFile(
          getSupportDirectory: () async => supportDirectory,
          getDocumentsDirectory: () async => documentsDirectory,
          applyFilePolicy: noOpFilePolicy,
        );

        expect(File('${supportFile.path}-journal').existsSync(), isFalse);
        expect(legacyJournalFile.existsSync(), isFalse);
      },
    );

    test('applies file policy for a new database location', () async {
      final rootDirectory = await createTestRootDirectory('file-policy');

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);
      Directory? protectedDirectory;
      File? protectedFile;

      final resolvedFile = await resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
        applyFilePolicy: (databaseDirectory, databaseFile) async {
          protectedDirectory = databaseDirectory;
          protectedFile = databaseFile;
        },
      );

      expect(resolvedFile.path, p.join(supportDirectory.path, 'flutty.db'));
      expect(supportDirectory.existsSync(), isTrue);
      expect(protectedDirectory?.path, supportDirectory.path);
      expect(protectedFile?.path, resolvedFile.path);
    });

    test(
      'propagates file policy failures before opening a new database location',
      () async {
        final rootDirectory = await createTestRootDirectory(
          'pre-open-policy-failure',
        );

        final documentsDirectory = Directory(
          p.join(rootDirectory.path, 'docs'),
        );
        final supportDirectory = Directory(
          p.join(rootDirectory.path, 'support'),
        );
        await documentsDirectory.create(recursive: true);

        await expectLater(
          resolveDatabaseFile(
            getSupportDirectory: () async => supportDirectory,
            getDocumentsDirectory: () async => documentsDirectory,
            applyFilePolicy: (databaseDirectory, databaseFile) async {
              throw StateError('pre-open policy failed');
            },
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'fails startup when post-open file policy application fails',
      () async {
        final rootDirectory = await createTestRootDirectory(
          'post-open-policy-failure',
        );

        final documentsDirectory = Directory(
          p.join(rootDirectory.path, 'docs'),
        );
        final supportDirectory = Directory(
          p.join(rootDirectory.path, 'support'),
        );
        await documentsDirectory.create(recursive: true);

        final databaseFileFuture = resolveDatabaseFile(
          getSupportDirectory: () async => supportDirectory,
          getDocumentsDirectory: () async => documentsDirectory,
          applyFilePolicy: noOpFilePolicy,
        );
        final failingDb = AppDatabase.withDatabaseFile(
          databaseFileFuture,
          applyAppleFilePolicy: (databaseDirectory, databaseFile) async {
            throw StateError('post-open policy failed');
          },
        );
        addTearDown(() async {
          await failingDb.close();
        });

        await expectLater(
          failingDb.select(failingDb.settings).get(),
          throwsA(
            anyOf(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('post-open policy failed'),
              ),
              isA<DriftRemoteException>().having(
                (error) => error.remoteCause.toString(),
                'remoteCause',
                contains('post-open policy failed'),
              ),
            ),
          ),
        );
      },
    );

    test('reapplies file policy after the database file is created', () async {
      final rootDirectory = await createTestRootDirectory(
        'fresh-install-policy',
      );

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);
      final fileExistenceChecks = <bool>[];

      Future<void> recordFilePolicyState(
        Directory databaseDirectory,
        File databaseFile,
      ) async {
        fileExistenceChecks.add(databaseFile.existsSync());
      }

      final databaseFileFuture = resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
        applyFilePolicy: recordFilePolicyState,
      );
      final dbWithReappliedPolicy = AppDatabase.withDatabaseFile(
        databaseFileFuture,
        applyAppleFilePolicy: recordFilePolicyState,
      );
      addTearDown(() async {
        await dbWithReappliedPolicy.close();
      });

      await dbWithReappliedPolicy.select(dbWithReappliedPolicy.settings).get();

      expect(fileExistenceChecks, [isFalse, isTrue]);
      expect((await databaseFileFuture).existsSync(), isTrue);
    });
  });

  group('Schema integrity', () {
    Future<Set<String>> columnNames(AppDatabase db, String tableName) async {
      final rows = await db.customSelect('PRAGMA table_info($tableName)').get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    test('hosts table has all expected columns after fresh open', () async {
      final columns = await columnNames(db, 'hosts');
      for (final expected in [
        'id',
        'label',
        'hostname',
        'port',
        'username',
        'password',
        'key_id',
        'group_id',
        'jump_host_id',
        'skip_jump_host_on_ssids',
        'is_favorite',
        'color',
        'notes',
        'tags',
        'created_at',
        'updated_at',
        'last_connected_at',
        'terminal_theme_light_id',
        'terminal_theme_dark_id',
        'terminal_font_family',
        'auto_connect_command',
        'auto_connect_snippet_id',
        'auto_connect_requires_confirmation',
        'sort_order',
        'tmux_session_name',
        'tmux_working_directory',
        'tmux_extra_flags',
        'remote_mux_backend',
        'auto_forward_ports',
        'port_proxy_name',
      ]) {
        expect(
          columns,
          contains(expected),
          reason: 'hosts table is missing column: $expected',
        );
      }
    });

    test('snippets table has sort_order column after fresh open', () async {
      final columns = await columnNames(db, 'snippets');
      expect(
        columns,
        containsAll(['id', 'name', 'command', 'sort_order', 'usage_count']),
      );
    });

    test('stored user_version matches schemaVersion', () async {
      final rows = await db.customSelect('PRAGMA user_version').get();
      final stored = rows.first.read<int>('user_version');
      expect(stored, equals(db.schemaVersion));
    });
  });

  group('beforeOpen key type repair', () {
    Future<File> createTestDbFile(String name) async {
      final dir = Directory(
        p.join(
          Directory.current.path,
          '.dart_tool',
          'database_test',
          '$name-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await dir.create(recursive: true);
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      return File(p.join(dir.path, 'test.db'));
    }

    Future<int> insertUnknownKey(
      AppDatabase target, {
      required String publicKey,
    }) => target
        .into(target.sshKeys)
        .insert(
          SshKeysCompanion.insert(
            name: 'repair-test-key',
            keyType: 'unknown',
            publicKey: publicKey,
            privateKey: 'private-key-material',
          ),
        );

    Future<String> reopenAndGetKeyType(File dbFile, int keyId) async {
      final db2 = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(() async => db2.close());
      final key = await (db2.select(
        db2.sshKeys,
      )..where((k) => k.id.equals(keyId))).getSingle();
      return key.keyType;
    }

    test('repairs key with ssh-ed25519 public key prefix', () async {
      final dbFile = await createTestDbFile('repair-ed25519-prefix');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'ed25519');
    });

    test('repairs key with ssh-rsa public key prefix', () async {
      final dbFile = await createTestDbFile('repair-rsa-prefix');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'ssh-rsa AAAAB3NzaC1yc2EAAAA...',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'rsa');
    });

    test('repairs key with ecdsa-sha2-nistp256 public key prefix', () async {
      final dbFile = await createTestDbFile('repair-ecdsa-prefix');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'ecdsa-sha2-nistp256 AAAAE2VjZHNh...',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'ecdsa-256');
    });

    test('repairs key with malformed Ed25519 toString public key', () async {
      final dbFile = await createTestDbFile('repair-ed25519-tostring');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'SSH(Ed25519PublicKey abc123)',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'ssh-ed25519');
    });

    test('repairs key with malformed RSA toString public key', () async {
      final dbFile = await createTestDbFile('repair-rsa-tostring');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'SSH(RsaPublicKey abc123)',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'ssh-rsa');
    });

    test('repairs key with malformed ECDSA toString public key', () async {
      final dbFile = await createTestDbFile('repair-ecdsa-tostring');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'SSH(EcdsaPublicKey abc123)',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'ecdsa-sha2-nistp256');
    });

    test('leaves key unchanged when type cannot be determined', () async {
      final dbFile = await createTestDbFile('repair-unrecognised');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await insertUnknownKey(
        db1,
        publicKey: 'UNRECOGNISED key-material',
      );
      await db1.close();

      expect(await reopenAndGetKeyType(dbFile, id), 'unknown');
    });

    test('does not modify keys that already have a known type', () async {
      final dbFile = await createTestDbFile('repair-skip-known');
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.select(db1.settings).get();
      final id = await db1
          .into(db1.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'known-key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAAC3Nz...',
              privateKey: 'private-key-material',
            ),
          );
      await db1.close();

      // Key type already correct — repair logic must leave it as-is.
      expect(await reopenAndGetKeyType(dbFile, id), 'ed25519');
    });
  });

  group('Migration idempotency guards', () {
    Future<File> createTestDbFile(String name) async {
      final dir = Directory(
        p.join(
          Directory.current.path,
          '.dart_tool',
          'database_test',
          '$name-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await dir.create(recursive: true);
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      return File(p.join(dir.path, 'test.db'));
    }

    test(
      'v4+ guarded migrations succeed when run on an already-complete schema',
      () async {
        final dbFile = await createTestDbFile('idempotent-v3');

        // Initialise a fresh database so onCreate runs and all columns exist.
        final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
        await db1.select(db1.settings).get();
        // Roll user_version back so the next open reruns all guarded upgrades.
        // Migrations from v4 onward use _readColumnNames guards, so they must
        // tolerate existing columns without error.
        await db1.customStatement('PRAGMA user_version = 3');
        await db1.close();

        final db2 = AppDatabase.forTesting(NativeDatabase(dbFile));
        addTearDown(() async => db2.close());

        await expectLater(
          db2.select(db2.hosts).get(),
          completes,
          reason: 'guarded migrations must be idempotent',
        );

        // Confirm the guarded columns are still present and accessible.
        final hostColumns = await db2
            .customSelect('PRAGMA table_info(hosts)')
            .get();
        final names = hostColumns.map((r) => r.read<String>('name')).toSet();
        expect(
          names,
          containsAll([
            'auto_connect_command',
            'auto_connect_requires_confirmation',
            'sort_order',
            'tmux_session_name',
            'skip_jump_host_on_ssids',
            'remote_mux_backend',
            'auto_forward_ports',
            'port_proxy_name',
          ]),
        );
      },
    );

    test(
      'v11 moves the per-host push opt-outs from Settings onto the hosts',
      () async {
        final dbFile = await createTestDbFile('push-opt-outs-v10');
        final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
        for (final label in ['one', 'two', 'three']) {
          await db1
              .into(db1.hosts)
              .insert(
                HostsCompanion.insert(
                  label: label,
                  hostname: '$label.example',
                  username: 'u',
                ),
              );
        }
        await db1
            .into(db1.settings)
            .insert(
              SettingsCompanion.insert(
                key: 'push_notifications_disabled_hosts',
                value: '[2,3,99]',
              ),
            );
        await db1.customStatement('PRAGMA user_version = 10');
        await db1.close();

        final db2 = AppDatabase.forTesting(NativeDatabase(dbFile));
        addTearDown(() async => db2.close());
        final hosts = await (db2.select(
          db2.hosts,
        )..orderBy([(h) => OrderingTerm.asc(h.id)])).get();
        expect(hosts.map((host) => host.pushWhenClosed), [true, false, false]);
        // Everything else stays on.
        expect(
          hosts.every(
            (host) =>
                host.notifyAgentAttention &&
                host.notifyAgentFinished &&
                host.notifyWindowAlerts &&
                host.notifyShellNotifications,
          ),
          isTrue,
        );
        final leftover =
            await (db2.select(db2.settings)..where(
                  (row) => row.key.equals('push_notifications_disabled_hosts'),
                ))
                .get();
        expect(leftover, isEmpty);
      },
    );

    test(
      '_readColumnNames equivalent correctly reports existing columns',
      () async {
        // The migration guards rely on PRAGMA table_info to detect existing
        // columns before calling addColumn.  Verify that the PRAGMA result
        // contains every column name used as a guard key.
        final rows = await db.customSelect('PRAGMA table_info(hosts)').get();
        final names = rows.map((r) => r.read<String>('name')).toSet();

        for (final guarded in [
          'auto_connect_command',
          'auto_connect_snippet_id',
          'auto_connect_requires_confirmation',
          'sort_order',
          'tmux_session_name',
          'tmux_working_directory',
          'tmux_extra_flags',
          'skip_jump_host_on_ssids',
          'remote_mux_backend',
          'auto_forward_ports',
          'port_proxy_name',
        ]) {
          expect(
            names,
            contains(guarded),
            reason: 'PRAGMA table_info must include guarded column: $guarded',
          );
        }
      },
    );
  });
}
