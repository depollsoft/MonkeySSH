import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Hosts table - stores SSH connection configurations.
class Hosts extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Display label for the host.
  TextColumn get label => text().withLength(min: 1, max: 255)();

  /// Hostname or IP address.
  TextColumn get hostname => text().withLength(min: 1, max: 255)();

  /// SSH port (default 22).
  IntColumn get port => integer().withDefault(const Constant(22))();

  /// Username for authentication.
  TextColumn get username => text().withLength(min: 1, max: 255)();

  /// Optional password (stored encrypted).
  TextColumn get password => text().nullable()();

  /// Reference to SSH key for authentication.
  IntColumn get keyId => integer().nullable().references(SshKeys, #id)();

  /// Reference to parent group.
  IntColumn get groupId => integer().nullable().references(Groups, #id)();

  /// Reference to jump host for proxy connections.
  IntColumn get jumpHostId => integer().nullable().references(Hosts, #id)();

  /// Newline-separated list of Wi-Fi SSIDs on which the configured jump host
  /// should be skipped (the host is reached directly when the device is on
  /// one of these networks).
  TextColumn get skipJumpHostOnSsids => text().nullable()();

  /// Whether this host is marked as favorite.
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  /// Custom color for the host (hex string).
  TextColumn get color => text().nullable()();

  /// Additional notes.
  TextColumn get notes => text().nullable()();

  /// Comma-separated tags.
  TextColumn get tags => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Last modified timestamp.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// Last connection timestamp.
  DateTimeColumn get lastConnectedAt => dateTime().nullable()();

  /// Terminal theme ID for light mode (null = use global default).
  TextColumn get terminalThemeLightId => text().nullable()();

  /// Terminal theme ID for dark mode (null = use global default).
  TextColumn get terminalThemeDarkId => text().nullable()();

  /// Terminal font family (null = use global default).
  TextColumn get terminalFontFamily => text().nullable()();

  /// Cached command to run automatically after connecting/reconnecting.
  TextColumn get autoConnectCommand => text().nullable()();

  /// Referenced snippet to run automatically after connecting/reconnecting.
  IntColumn get autoConnectSnippetId =>
      integer().nullable().references(Snippets, #id)();

  /// Whether auto-connect should require user review before it can run.
  BoolColumn get autoConnectRequiresConfirmation =>
      boolean().withDefault(const Constant(false))();

  /// tmux session name to attach/create on connect.
  ///
  /// When set, the app generates a `tmux new-session -A -s <name>` command
  /// instead of using [autoConnectCommand], and knows the session name
  /// directly for window navigation.
  TextColumn get tmuxSessionName => text().nullable()();

  /// Working directory to use when starting a tmux session.
  ///
  /// Passed as `-c <dir>` to `tmux new-session`.
  TextColumn get tmuxWorkingDirectory => text().nullable()();

  /// Extra tmux flags appended to the generated `tmux new-session` command.
  TextColumn get tmuxExtraFlags => text().nullable()();

  /// Remote multiplexer backend used with [tmuxSessionName].
  ///
  /// Null preserves legacy behavior and means tmux when [tmuxSessionName] is
  /// populated.
  TextColumn get remoteMuxBackend => text().nullable()();

  /// Whether newly opened remote TCP ports should be forwarded automatically.
  BoolColumn get autoForwardPorts =>
      boolean().withDefault(const Constant(false))();

  /// Optional user-defined prefix for this host's `.localhost` proxy domain.
  TextColumn get portProxyName => text().nullable()();

  /// Display order within the hosts list.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// SSH Keys table - stores SSH key pairs.
class SshKeys extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Display name for the key.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Key type (ed25519, rsa, etc.).
  TextColumn get keyType => text().withLength(min: 1, max: 50)();

  /// Public key content.
  TextColumn get publicKey => text()();

  /// Private key content (stored encrypted).
  TextColumn get privateKey => text()();

  /// Optional passphrase for the key (stored encrypted).
  TextColumn get passphrase => text().nullable()();

  /// Key fingerprint for display.
  TextColumn get fingerprint => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Groups table - organizes hosts into folders.
class Groups extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Group name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Parent group for nested folders.
  IntColumn get parentId => integer().nullable().references(Groups, #id)();

  /// Display order within parent.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Custom color for the group (hex string).
  TextColumn get color => text().nullable()();

  /// Custom icon name.
  TextColumn get icon => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Snippets table - stores reusable command snippets.
class Snippets extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Snippet name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// The command content.
  TextColumn get command => text()();

  /// Optional description.
  TextColumn get description => text().nullable()();

  /// Reference to parent folder.
  IntColumn get folderId =>
      integer().nullable().references(SnippetFolders, #id)();

  /// Whether to auto-execute on selection.
  BoolColumn get autoExecute => boolean().withDefault(const Constant(false))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Last used timestamp.
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  /// Usage count for sorting by frequency.
  IntColumn get usageCount => integer().withDefault(const Constant(0))();

  /// Display order within the snippets list.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Snippet folders for organizing snippets.
class SnippetFolders extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Folder name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Parent folder for nesting.
  IntColumn get parentId =>
      integer().nullable().references(SnippetFolders, #id)();

  /// Display order.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Port forwarding rules table.
class PortForwards extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Rule name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Associated host.
  IntColumn get hostId => integer().references(Hosts, #id)();

  /// Forward type: 'local' or 'remote'.
  TextColumn get forwardType => text().withLength(min: 1, max: 10)();

  /// Local bind address.
  TextColumn get localHost => text().withDefault(const Constant('127.0.0.1'))();

  /// Local port.
  IntColumn get localPort => integer()();

  /// Remote host.
  TextColumn get remoteHost => text()();

  /// Remote port.
  IntColumn get remotePort => integer()();

  /// Whether to auto-start on host connection.
  BoolColumn get autoStart => boolean().withDefault(const Constant(false))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Known hosts for SSH host key verification.
class KnownHosts extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Hostname or IP.
  TextColumn get hostname => text()();

  /// Port number.
  IntColumn get port => integer()();

  /// Host key type.
  TextColumn get keyType => text()();

  /// Host key fingerprint.
  TextColumn get fingerprint => text()();

  /// Full host key.
  TextColumn get hostKey => text()();

  /// When the key was first seen.
  DateTimeColumn get firstSeen => dateTime().withDefault(currentDateAndTime)();

  /// When the key was last verified.
  DateTimeColumn get lastSeen => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column<Object>>>? get uniqueKeys => [
    {hostname, port},
  ];
}

/// App settings table for key-value storage.
class Settings extends Table {
  /// Setting key.
  TextColumn get key => text()();

  /// Setting value (JSON encoded for complex values).
  TextColumn get value => text()();

  @override
  Set<Column<Object>>? get primaryKey => {key};
}

/// The main database class.
@DriftDatabase(
  tables: [
    Hosts,
    SshKeys,
    Groups,
    Snippets,
    SnippetFolders,
    PortForwards,
    KnownHosts,
    Settings,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Creates a new database instance.
  AppDatabase() : this.withDatabaseFile(resolveDatabaseFile());

  /// Creates a new database instance backed by [databaseFileFuture].
  AppDatabase.withDatabaseFile(
    Future<File> databaseFileFuture, {
    AppleDatabaseFilePolicyApplier? applyAppleFilePolicy,
  }) : _databaseFileFuture = databaseFileFuture,
       _appleDatabaseFilePolicyApplier =
           applyAppleFilePolicy ?? _applyAppleDatabaseFilePolicy,
       super(_openConnection(databaseFileFuture));

  /// Creates a database for testing with an in-memory database.
  AppDatabase.forTesting(super.e)
    : _databaseFileFuture = null,
      _appleDatabaseFilePolicyApplier = _noOpAppleDatabaseFilePolicy;

  final Future<File>? _databaseFileFuture;
  final AppleDatabaseFilePolicyApplier _appleDatabaseFilePolicyApplier;

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(hosts, hosts.terminalThemeLightId);
        await m.addColumn(hosts, hosts.terminalThemeDarkId);
      }
      if (from < 3) {
        await m.addColumn(hosts, hosts.terminalFontFamily);
      }
      if (from < 4) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.autoConnectCommand.$name)) {
          await m.addColumn(hosts, hosts.autoConnectCommand);
        }
        if (!hostColumnNames.contains(hosts.autoConnectSnippetId.$name)) {
          await m.addColumn(hosts, hosts.autoConnectSnippetId);
        }
      }
      if (from < 5) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(
          hosts.autoConnectRequiresConfirmation.$name,
        )) {
          await m.addColumn(hosts, hosts.autoConnectRequiresConfirmation);
        }
      }
      if (from < 6) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.sortOrder.$name)) {
          await m.addColumn(hosts, hosts.sortOrder);
          await _backfillSortOrder(
            tableName: 'hosts',
            columnName: 'sort_order',
          );
        }

        final snippetColumnNames = await _readColumnNames('snippets');
        if (!snippetColumnNames.contains(snippets.sortOrder.$name)) {
          await m.addColumn(snippets, snippets.sortOrder);
          await _backfillSortOrder(
            tableName: 'snippets',
            columnName: 'sort_order',
          );
        }
      }
      if (from < 7) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.tmuxSessionName.$name)) {
          await m.addColumn(hosts, hosts.tmuxSessionName);
        }
        if (!hostColumnNames.contains(hosts.tmuxWorkingDirectory.$name)) {
          await m.addColumn(hosts, hosts.tmuxWorkingDirectory);
        }
        if (!hostColumnNames.contains(hosts.tmuxExtraFlags.$name)) {
          await m.addColumn(hosts, hosts.tmuxExtraFlags);
        }
      }
      if (from < 8) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.skipJumpHostOnSsids.$name)) {
          await m.addColumn(hosts, hosts.skipJumpHostOnSsids);
        }
      }
      if (from < 9) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.remoteMuxBackend.$name)) {
          await m.addColumn(hosts, hosts.remoteMuxBackend);
        }
      }
      if (from < 10) {
        final hostColumnNames = await _readColumnNames('hosts');
        if (!hostColumnNames.contains(hosts.autoForwardPorts.$name)) {
          await m.addColumn(hosts, hosts.autoForwardPorts);
        }
        if (!hostColumnNames.contains(hosts.portProxyName.$name)) {
          await m.addColumn(hosts, hosts.portProxyName);
        }
      }
    },
    beforeOpen: (details) async {
      final databaseFileFuture = _databaseFileFuture;
      if (databaseFileFuture != null) {
        await _applyDatabaseFilePolicy(
          await databaseFileFuture,
          applyFilePolicy: _appleDatabaseFilePolicyApplier,
        );
      }

      // Fix any keys with "unknown" type or malformed public keys
      // by re-extracting from the private key
      final unknownKeys = await (select(
        sshKeys,
      )..where((k) => k.keyType.equals('unknown'))).get();
      for (final key in unknownKeys) {
        // If public key looks malformed (debug toString format), try to fix it
        if (key.publicKey.startsWith('SSH') && key.privateKey.isNotEmpty) {
          // We can't easily fix this without dartssh2 in the database layer
          // Just detect type from the malformed string
          var detectedType = 'unknown';
          if (key.publicKey.contains('Ed25519')) {
            detectedType = 'ssh-ed25519';
          } else if (key.publicKey.contains('Rsa')) {
            detectedType = 'ssh-rsa';
          } else if (key.publicKey.contains('Ecdsa')) {
            detectedType = 'ecdsa-sha2-nistp256';
          }
          if (detectedType != 'unknown') {
            await (update(sshKeys)..where((k) => k.id.equals(key.id))).write(
              SshKeysCompanion(keyType: Value(detectedType)),
            );
          }
        } else {
          // Try standard detection from public key prefix
          final detectedType = _detectKeyTypeFromPublicKey(key.publicKey);
          if (detectedType != 'unknown') {
            await (update(sshKeys)..where((k) => k.id.equals(key.id))).write(
              SshKeysCompanion(keyType: Value(detectedType)),
            );
          }
        }
      }
    },
  );

  Future<Set<String>> _readColumnNames(String tableName) async {
    final columns = await customSelect('PRAGMA table_info($tableName)').get();
    return columns.map((row) => row.read<String>('name')).toSet();
  }

  Future<void> _backfillSortOrder({
    required String tableName,
    required String columnName,
  }) async {
    final rows = await customSelect('SELECT id FROM $tableName ORDER BY id')
        .get();
    for (var index = 0; index < rows.length; index += 1) {
      await customStatement(
        'UPDATE $tableName SET $columnName = ? WHERE id = ?',
        [index, rows[index].read<int>('id')],
      );
    }
  }

  String _detectKeyTypeFromPublicKey(String publicKey) {
    final trimmed = publicKey.trim();
    if (trimmed.startsWith('ssh-ed25519')) {
      return 'ed25519';
    } else if (trimmed.startsWith('ssh-rsa')) {
      return 'rsa';
    } else if (trimmed.startsWith('ecdsa-sha2-nistp256')) {
      return 'ecdsa-256';
    } else if (trimmed.startsWith('ecdsa-sha2-nistp384')) {
      return 'ecdsa-384';
    } else if (trimmed.startsWith('ecdsa-sha2-nistp521')) {
      return 'ecdsa-521';
    } else if (trimmed.startsWith('ecdsa-')) {
      return 'ecdsa';
    } else if (trimmed.startsWith('ssh-dss')) {
      return 'dsa';
    } else if (trimmed.startsWith('sk-ssh-ed25519')) {
      return 'ed25519-sk';
    } else if (trimmed.startsWith('sk-ecdsa-')) {
      return 'ecdsa-sk';
    }
    return 'unknown';
  }
}

const _databaseFileName = 'flutty.db';
const _migrationMarkerSuffix = '.legacy-migration-incomplete';
const _databaseCompanionSuffixes = ['-journal', '-wal', '-shm'];
const _appleDatabaseFileProtectionChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/apple_file_protection',
);

/// Applies the Apple database storage policy to a database directory and file.
typedef AppleDatabaseFilePolicyApplier = Future<void> Function(
  Directory databaseDirectory,
  File databaseFile,
);

Future<void> _noOpAppleDatabaseFilePolicy(
  Directory databaseDirectory,
  File databaseFile,
) async {}

/// Resolves the database file path and migrates legacy storage if needed.
Future<File> resolveDatabaseFile({
  Future<Directory> Function()? getSupportDirectory,
  Future<Directory> Function()? getDocumentsDirectory,
  AppleDatabaseFilePolicyApplier? applyFilePolicy,
}) async {
  final supportDirectoryProvider =
      getSupportDirectory ?? getApplicationSupportDirectory;
  final documentsDirectoryProvider =
      getDocumentsDirectory ?? getApplicationDocumentsDirectory;
  final filePolicyApplier = applyFilePolicy ?? _applyAppleDatabaseFilePolicy;

  final supportDirectory = await supportDirectoryProvider();
  await supportDirectory.create(recursive: true);
  final supportFile = File(p.join(supportDirectory.path, _databaseFileName));
  final migrationMarker = File(
    p.join(supportDirectory.path, '$_databaseFileName$_migrationMarkerSuffix'),
  );
  final documentsDirectory = await documentsDirectoryProvider();
  final legacyFile = File(p.join(documentsDirectory.path, _databaseFileName));

  if (supportFile.existsSync()) {
    if (migrationMarker.existsSync()) {
      if (legacyFile.existsSync()) {
        await _moveFileWithFallback(legacyFile, supportFile);
      }
      await _moveLegacyCompanionFiles(legacyFile, supportFile);
      await migrationMarker.delete();
    } else {
      await _deleteLegacyCompanionFiles(legacyFile);
    }
    await filePolicyApplier(supportDirectory, supportFile);
    return supportFile;
  }

  if (legacyFile.existsSync()) {
    await migrationMarker.writeAsString('pending');
    await _moveFileWithFallback(legacyFile, supportFile);
    await _moveLegacyCompanionFiles(legacyFile, supportFile);
    await migrationMarker.delete();
  }

  await filePolicyApplier(supportDirectory, supportFile);
  return supportFile;
}

Future<void> _moveLegacyCompanionFiles(
  File legacyFile,
  File supportFile,
) async {
  for (final suffix in _databaseCompanionSuffixes) {
    final legacyCompanion = File('${legacyFile.path}$suffix');
    final supportCompanion = File('${supportFile.path}$suffix');
    if (!legacyCompanion.existsSync()) {
      continue;
    }
    if (supportCompanion.existsSync()) {
      await legacyCompanion.delete();
      continue;
    }
    await _moveFileWithFallback(legacyCompanion, supportCompanion);
  }
}

Future<void> _deleteLegacyCompanionFiles(File legacyFile) async {
  for (final suffix in _databaseCompanionSuffixes) {
    final legacyCompanion = File('${legacyFile.path}$suffix');
    if (legacyCompanion.existsSync()) {
      await legacyCompanion.delete();
    }
  }
}

Future<void> _applyAppleDatabaseFilePolicy(
  Directory databaseDirectory,
  File databaseFile,
) async {
  if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) {
    return;
  }

  await _appleDatabaseFileProtectionChannel.invokeMethod<void>(
    'applyDatabaseFilePolicy',
    <String, Object?>{
      'databaseDirectoryPath': databaseDirectory.path,
      'databasePath': databaseFile.path,
      'companionPaths': [
        for (final suffix in _databaseCompanionSuffixes)
          '${databaseFile.path}$suffix',
      ],
      'applyFileProtection': Platform.isIOS,
    },
  );
}

Future<void> _moveFileWithFallback(File source, File destination) async {
  if (!source.existsSync()) {
    return;
  }
  try {
    await source.rename(destination.path);
  } on FileSystemException {
    await source.copy(destination.path);
    await source.delete();
  }
}

Future<void> _applyDatabaseFilePolicy(
  File databaseFile, {
  AppleDatabaseFilePolicyApplier? applyFilePolicy,
}) {
  final filePolicyApplier = applyFilePolicy ?? _applyAppleDatabaseFilePolicy;
  return filePolicyApplier(databaseFile.parent, databaseFile);
}

@visibleForTesting
/// Whether the database may safely open in a background isolate.
bool shouldOpenDatabaseInBackground({
  required bool isWeb,
  required bool isIOS,
  required bool isMacOS,
}) => !isWeb && !isIOS && !isMacOS;

LazyDatabase _openConnection(Future<File> databaseFileFuture) =>
    LazyDatabase(() async {
      final file = await databaseFileFuture;
      if (!shouldOpenDatabaseInBackground(
        isWeb: kIsWeb,
        isIOS: !kIsWeb && Platform.isIOS,
        isMacOS: !kIsWeb && Platform.isMacOS,
      )) {
        return NativeDatabase(file);
      }
      return NativeDatabase.createInBackground(file);
    });

/// Provider for the app database.
final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase());
