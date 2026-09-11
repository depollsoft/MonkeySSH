import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide Uint8List;
import 'package:flutter/foundation.dart' hide Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/export.dart'
    show Argon2BytesGenerator, Argon2Parameters;

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../models/auto_connect_command.dart';
import '../models/host_cli_launch_preferences.dart';
import 'diagnostics_log_service.dart';
import 'host_cli_launch_preferences_service.dart';
import 'host_key_verification.dart';
import 'key_service.dart';
import 'port_forward_browser_service.dart';
import 'settings_service.dart';
import 'ssh_service.dart';

/// Supported transfer payload types.
enum TransferPayloadType {
  /// Host transfer payload.
  host,

  /// SSH key transfer payload.
  key,

  /// Full migration payload.
  fullMigration,
}

/// Full migration import mode.
enum MigrationImportMode {
  /// Keep existing data and add imported records.
  merge,

  /// Replace existing data with imported records.
  replace,
}

/// Decrypted transfer payload.
class TransferPayload {
  /// Creates a new [TransferPayload].
  const TransferPayload({
    required this.type,
    required this.schemaVersion,
    required this.createdAt,
    required this.data,
  });

  /// Builds payload from JSON.
  factory TransferPayload.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String?;
    final type = switch (rawType) {
      'host' => TransferPayloadType.host,
      'key' => TransferPayloadType.key,
      'full-migration' => TransferPayloadType.fullMigration,
      _ => throw const FormatException('Unsupported transfer payload type'),
    };

    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (createdAt == null) {
      throw const FormatException('Invalid transfer payload timestamp');
    }

    final rawData = json['data'];
    if (rawData is! Map) {
      throw const FormatException('Invalid transfer payload data');
    }

    return TransferPayload(
      type: type,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      createdAt: createdAt,
      data: Map<String, dynamic>.from(rawData),
    );
  }

  /// Payload type.
  final TransferPayloadType type;

  /// Payload schema version.
  final int schemaVersion;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Payload data.
  final Map<String, dynamic> data;

  /// Converts payload to JSON.
  Map<String, dynamic> toJson() => {
    'type': switch (type) {
      TransferPayloadType.host => 'host',
      TransferPayloadType.key => 'key',
      TransferPayloadType.fullMigration => 'full-migration',
    },
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'data': data,
  };
}

/// Human-readable migration preview counts.
class MigrationPreview {
  /// Creates a new [MigrationPreview].
  const MigrationPreview({
    required this.settingsCount,
    required this.hostCount,
    required this.keyCount,
    required this.groupCount,
    required this.snippetCount,
    required this.snippetFolderCount,
    required this.portForwardCount,
    required this.knownHostCount,
  });

  /// Number of settings records.
  final int settingsCount;

  /// Number of host records.
  final int hostCount;

  /// Number of SSH key records.
  final int keyCount;

  /// Number of host groups.
  final int groupCount;

  /// Number of snippets.
  final int snippetCount;

  /// Number of snippet folders.
  final int snippetFolderCount;

  /// Number of port forwards.
  final int portForwardCount;

  /// Number of known hosts.
  final int knownHostCount;
}

/// Service that encrypts and imports offline transfer payloads.
class SecureTransferService {
  /// Creates a new [SecureTransferService].
  SecureTransferService(
    this._db,
    this._keyRepository,
    this._hostRepository, {
    DiagnosticsLogger diagnosticsLogger = const NoopDiagnosticsLogger(),
    Future<void> Function()? onHostsChanged,
  }) : _diagnosticsLogger = diagnosticsLogger,
       _onHostsChanged = onHostsChanged;

  final AppDatabase _db;
  final KeyRepository _keyRepository;
  final HostRepository _hostRepository;
  final DiagnosticsLogger _diagnosticsLogger;
  final Future<void> Function()? _onHostsChanged;

  static const _minEpochMilliseconds = -8640000000000000;
  static const _maxEpochMilliseconds = 8640000000000000;
  static const _schemaVersion = 1;
  static const _hostScopedSettingsKeys = {
    SettingKeys.agentLaunchPresets,
    SettingKeys.hostCliLaunchPreferences,
  };

  /// Creates an encrypted host transfer payload.
  Future<String> createHostPayload({
    required Host host,
    required String transferPassphrase,
    bool includeReferencedKey = false,
  }) async {
    SshKey? referencedKey;
    if (includeReferencedKey && host.keyId != null) {
      referencedKey = await _keyRepository.getById(host.keyId!);
    }
    _ensureExportableSecrets(hosts: [host], keys: [?referencedKey]);
    final cliLaunchPreferences = await _hostCliLaunchPreferencesService
        .getPreferencesForHost(host.id);

    final hostData = Map<String, dynamic>.from(host.toJson())
      ..['keyId'] = referencedKey == null ? null : host.keyId
      ..['groupId'] = null
      ..['jumpHostId'] = null
      ..['autoConnectSnippetId'] = null;

    final payload = TransferPayload(
      type: TransferPayloadType.host,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: {
        'host': hostData,
        'referencedKey': referencedKey?.toJson(),
        if (!cliLaunchPreferences.isEmpty)
          'hostCliLaunchPreferences': cliLaunchPreferences.toJson(),
      },
    );
    return compute(_encryptTransferPayload, (payload, transferPassphrase));
  }

  /// Creates an encrypted SSH key transfer payload.
  Future<String> createKeyPayload({
    required SshKey key,
    required String transferPassphrase,
  }) async {
    _ensureExportableSecrets(keys: [key]);
    final payload = TransferPayload(
      type: TransferPayloadType.key,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: {'key': key.toJson()},
    );
    return compute(_encryptTransferPayload, (payload, transferPassphrase));
  }

  /// Creates an encrypted full migration payload.
  Future<String> createFullMigrationPayload({
    required String transferPassphrase,
  }) async {
    final payload = TransferPayload(
      type: TransferPayloadType.fullMigration,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: await createMigrationData(),
    );

    return compute(_encryptTransferPayload, (payload, transferPassphrase));
  }

  /// Creates canonical migration data that can be reused by sync flows.
  Future<Map<String, dynamic>> createMigrationData() async {
    final settings = await _db.select(_db.settings).get();
    final groups = await _db.select(_db.groups).get();
    final keys = await _keyRepository.getAll();
    final hosts = await _hostRepository.getAll();
    _ensureExportableSecrets(hosts: hosts, keys: keys);
    final snippetFolders =
        await (_db.select(_db.snippetFolders)..orderBy([
              (folder) => OrderingTerm.asc(folder.sortOrder),
              (folder) => OrderingTerm.asc(folder.id),
            ]))
            .get();
    final snippets =
        await (_db.select(_db.snippets)..orderBy([
              (snippet) => OrderingTerm.asc(snippet.sortOrder),
              (snippet) => OrderingTerm.asc(snippet.id),
            ]))
            .get();
    final rawPortForwards = await _db.select(_db.portForwards).get();
    final exportedHostIds = hosts.map((host) => host.id).toSet();
    var removedJumpHostReferenceCount = 0;
    final exportedHosts = hosts
        .map((host) {
          final hostData = Map<String, dynamic>.from(host.toJson());
          final jumpHostId = host.jumpHostId;
          if (jumpHostId != null && !exportedHostIds.contains(jumpHostId)) {
            hostData['jumpHostId'] = null;
            removedJumpHostReferenceCount += 1;
          }
          return hostData;
        })
        .toList(growable: false);
    if (removedJumpHostReferenceCount > 0) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'migration_export_jump_host_references_removed',
        fields: {'removedCount': removedJumpHostReferenceCount},
      );
    }
    final portForwards = rawPortForwards
        .where((portForward) => exportedHostIds.contains(portForward.hostId))
        .toList(growable: false);
    final skippedPortForwardCount =
        rawPortForwards.length - portForwards.length;
    if (skippedPortForwardCount > 0) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'migration_export_port_forwards_skipped',
        fields: {'skippedCount': skippedPortForwardCount},
      );
    }
    final knownHosts = await _db.select(_db.knownHosts).get();
    final rawSettings = <String, String>{
      for (final setting in settings) setting.key: setting.value,
    };

    return {
      'settings': _sortedStringMap(rawSettings),
      'groups': _sortedJsonRecords(groups.map((item) => item.toJson())),
      'keys': _sortedJsonRecords(keys.map((item) => item.toJson())),
      'hosts': _sortedJsonRecords(exportedHosts),
      'snippetFolders': _sortedJsonRecords(
        snippetFolders.map((item) => item.toJson()),
      ),
      'snippets': _sortedJsonRecords(snippets.map((item) => item.toJson())),
      'portForwards': _sortedJsonRecords(
        portForwards.map((item) => item.toJson()),
      ),
      'knownHosts': _sortedJsonRecords(knownHosts.map((item) => item.toJson())),
    };
  }

  // Repository reads retain rows with unreadable secrets but return null/empty
  // placeholders. Exporting those placeholders would erase secrets on import.
  // Keep using strict getAll reads above: tolerant loaders can omit failed rows.
  void _ensureExportableSecrets({
    Iterable<Host> hosts = const [],
    Iterable<SshKey> keys = const [],
  }) {
    final unreadableSecrets = <String>[
      for (final host in hosts)
        if (_hostRepository.hasUnreadablePassword(host.id))
          'password for host "${host.label}"',
      for (final key in keys) ...[
        if (_keyRepository.hasUnreadablePrivateKey(key.id))
          'private key for SSH key "${key.name}"',
        if (_keyRepository.hasUnreadablePassphrase(key.id))
          'passphrase for SSH key "${key.name}"',
      ],
    ];
    if (unreadableSecrets.isNotEmpty) {
      throw FormatException(
        'Cannot export because saved secrets could not be read: '
        '${unreadableSecrets.join('; ')}. '
        'Re-enter these secrets before exporting.',
      );
    }
  }

  /// Decrypts and parses an encrypted payload.
  Future<TransferPayload> decryptPayload({
    required String encodedPayload,
    required String transferPassphrase,
  }) => compute(_decryptTransferPayload, (encodedPayload, transferPassphrase));

  /// Imports a host payload and returns the created host.
  Future<Host> importHostPayload(TransferPayload payload) async {
    if (payload.type != TransferPayloadType.host) {
      throw const FormatException('Payload is not a host transfer');
    }

    final rawHost = payload.data['host'];
    if (rawHost is! Map) {
      throw const FormatException('Host payload data missing');
    }
    final hostData = Map<String, dynamic>.from(rawHost);
    final autoConnectCommand = normalizeImportedAutoConnectCommand(
      _optionalString(hostData['autoConnectCommand']),
    );
    final requiresAutoConnectReview = importedAutoConnectRequiresReview(
      command: autoConnectCommand,
      snippetId: null,
    );
    final importedHost = await _db.transaction(() async {
      int? keyId;
      final rawReferencedKey = payload.data['referencedKey'];
      if (rawReferencedKey is Map) {
        final importedKey = await _importKeyMap(
          Map<String, dynamic>.from(rawReferencedKey),
        );
        keyId = importedKey.id;
      }

      final hostId = await _hostRepository.insert(
        _importedHostCompanion(
          hostData,
          keyId: keyId,
          autoConnectCommand: autoConnectCommand,
          requiresAutoConnectReview: requiresAutoConnectReview,
        ),
      );
      final rawCliLaunchPreferences = payload.data['hostCliLaunchPreferences'];
      if (rawCliLaunchPreferences is Map) {
        final cliLaunchPreferences = HostCliLaunchPreferences.fromJson(
          Map<String, dynamic>.from(rawCliLaunchPreferences),
        );
        if (!cliLaunchPreferences.isEmpty) {
          await _hostCliLaunchPreferencesService.setPreferencesForHost(
            hostId,
            cliLaunchPreferences,
          );
        }
      }

      final createdHost = await _hostRepository.getById(hostId);
      if (createdHost == null) {
        throw const FormatException('Failed to import host');
      }
      return createdHost;
    });
    await _notifyHostsChanged();
    return importedHost;
  }

  /// Imports a key payload and returns the created key.
  Future<SshKey> importKeyPayload(TransferPayload payload) async {
    if (payload.type != TransferPayloadType.key) {
      throw const FormatException('Payload is not a key transfer');
    }
    final rawKey = payload.data['key'];
    if (rawKey is! Map) {
      throw const FormatException('Key payload data missing');
    }
    return _importKeyMap(Map<String, dynamic>.from(rawKey));
  }

  /// Produces a migration preview from a decrypted payload.
  MigrationPreview previewMigrationPayload(TransferPayload payload) {
    if (payload.type != TransferPayloadType.fullMigration) {
      throw const FormatException('Payload is not a full migration transfer');
    }

    return previewMigrationData(payload.data);
  }

  /// Produces a migration preview from raw migration data.
  MigrationPreview previewMigrationData(Map<String, dynamic> data) {
    final settingsMap = data['settings'];
    final settingsCount = settingsMap is Map ? settingsMap.length : 0;

    return MigrationPreview(
      settingsCount: settingsCount,
      hostCount: _listFromData(data, 'hosts').length,
      keyCount: _listFromData(data, 'keys').length,
      groupCount: _listFromData(data, 'groups').length,
      snippetCount: _listFromData(data, 'snippets').length,
      snippetFolderCount: _listFromData(data, 'snippetFolders').length,
      portForwardCount: _listFromData(data, 'portForwards').length,
      knownHostCount: _listFromData(data, 'knownHosts').length,
    );
  }

  /// Imports a full migration payload.
  Future<void> importFullMigrationPayload({
    required TransferPayload payload,
    required MigrationImportMode mode,
  }) async {
    if (payload.type != TransferPayloadType.fullMigration) {
      throw const FormatException('Payload is not a full migration transfer');
    }

    await importMigrationData(data: payload.data, mode: mode);
  }

  /// Imports canonical migration data for migration or sync flows.
  Future<void> importMigrationData({
    required Map<String, dynamic> data,
    required MigrationImportMode mode,
  }) async {
    final diagnosticsFields = _migrationImportDiagnosticsFields(
      data: data,
      mode: mode,
    );
    _diagnosticsLogger.info(
      'secure_transfer',
      'migration_import_started',
      fields: diagnosticsFields,
    );
    try {
      await _db.transaction(() async {
        var deferForeignKeysEnabled = false;
        try {
          if (mode == MigrationImportMode.replace) {
            await _db.customStatement('PRAGMA defer_foreign_keys = ON');
            deferForeignKeysEnabled = true;
            await _clearMigrationTables();
          }

          final groupMapping = await _importGroups(
            _listFromData(data, 'groups'),
          );
          final keyMapping = await _importKeys(_listFromData(data, 'keys'));
          final snippetFolderMapping = await _importSnippetFolders(
            _listFromData(data, 'snippetFolders'),
          );
          final rawHosts = _listFromData(data, 'hosts');
          final importedAutoConnectSnippetIds = rawHosts
              .map((host) => _optionalInt(host['autoConnectSnippetId']))
              .whereType<int>()
              .toSet();
          final snippetMapping = await _importSnippets(
            _listFromData(data, 'snippets'),
            snippetFolderMapping: snippetFolderMapping,
            autoConnectSnippetIds: importedAutoConnectSnippetIds,
          );
          final hostMapping = await _importHosts(
            rawHosts,
            groupMapping: groupMapping,
            keyMapping: keyMapping,
            snippetMapping: snippetMapping,
          );
          await _importPortForwards(
            _listFromData(data, 'portForwards'),
            hostMapping: hostMapping,
          );
          await _importKnownHosts(
            _listFromData(data, 'knownHosts'),
            mode: mode,
          );
          await _importSettings(
            _settingsFromData(data),
            clearExisting: mode == MigrationImportMode.replace,
            hostMapping: hostMapping,
          );
        } finally {
          if (deferForeignKeysEnabled) {
            await _db.customStatement('PRAGMA defer_foreign_keys = OFF');
          }
        }
      });
      await _notifyHostsChanged();
      _diagnosticsLogger.info(
        'secure_transfer',
        'migration_import_completed',
        fields: diagnosticsFields,
      );
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'migration_import_failed',
        fields: {
          ...diagnosticsFields,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  Future<void> _notifyHostsChanged() async {
    final onHostsChanged = _onHostsChanged;
    if (onHostsChanged == null) {
      return;
    }
    try {
      await onHostsChanged();
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'host_alias_reconfiguration_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<SshKey> _importKeyMap(
    Map<String, dynamic> keyData, {
    List<SshKey>? existingKeysCache,
  }) async {
    final publicKey = _requiredString(keyData, 'publicKey');
    // Public-only reference keys deliberately store an empty private key.
    final privateKey = keyData['privateKey'];
    if (privateKey is! String) {
      throw const FormatException('Missing required field: privateKey');
    }
    final fingerprint = computeOpenSshPublicKeyFingerprint(publicKey);
    final existingKeys = existingKeysCache ?? await _keyRepository.getAll();
    if (fingerprint.isNotEmpty) {
      for (final key in existingKeys) {
        // A reference key and a signing key are not interchangeable. Keep
        // both records so replacement imports preserve private material and
        // each host's choice of a public-only or private-bearing key.
        if (key.fingerprint == fingerprint &&
            key.publicKey == publicKey &&
            key.privateKey.isEmpty == privateKey.isEmpty) {
          return key;
        }
      }
    }

    for (final key in existingKeys) {
      if (key.publicKey == publicKey && key.privateKey == privateKey) {
        return key;
      }
    }

    final keyId = await _keyRepository.insert(
      SshKeysCompanion.insert(
        name: _requiredString(keyData, 'name'),
        keyType: _requiredString(keyData, 'keyType'),
        publicKey: publicKey,
        privateKey: privateKey,
        passphrase: Value(_optionalString(keyData['passphrase'])),
        fingerprint: Value(fingerprint),
        createdAt: Value(
          _optionalDateTime(keyData['createdAt']) ?? DateTime.now(),
        ),
      ),
    );
    final createdKey = await _keyRepository.getById(keyId);
    if (createdKey == null) {
      throw const FormatException('Failed to import SSH key');
    }
    existingKeysCache?.add(createdKey);
    return createdKey;
  }

  Future<void> _clearMigrationTables() async {
    await _db.customStatement('DELETE FROM port_forwards');
    await _db.customStatement('DELETE FROM snippets');
    await _db.customStatement('DELETE FROM snippet_folders');
    await _db.customStatement('DELETE FROM hosts');
    await _db.customStatement('DELETE FROM ssh_keys');
    await _db.customStatement('DELETE FROM groups');
    await _db.customStatement('DELETE FROM known_hosts');
  }

  Future<Map<int, int>> _importGroups(List<Map<String, dynamic>> rawGroups) =>
      _importHierarchy(
        rawGroups,
        errorMessage: 'Invalid group hierarchy in migration payload',
        insert: (item, parentId) => _db
            .into(_db.groups)
            .insert(
              GroupsCompanion.insert(
                name: _requiredString(item, 'name'),
                parentId: Value(parentId),
                sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
                color: Value(_optionalString(item['color'])),
                icon: Value(_optionalString(item['icon'])),
                createdAt: Value(
                  _optionalDateTime(item['createdAt']) ?? DateTime.now(),
                ),
              ),
            ),
      );

  Future<Map<int, int>> _importHierarchy(
    List<Map<String, dynamic>> items, {
    required Future<int> Function(Map<String, dynamic>, int?) insert,
    required String errorMessage,
  }) async {
    final pending = <int, Map<String, dynamic>>{};
    for (final item in items) {
      final oldId = _optionalInt(item['id']);
      if (oldId != null) {
        pending[oldId] = item;
      }
    }

    final idMapping = <int, int>{};
    while (pending.isNotEmpty) {
      var progress = false;
      final pendingIds = pending.keys.toList(growable: false);
      for (final oldId in pendingIds) {
        final item = pending[oldId];
        if (item == null) {
          continue;
        }
        final parentOldId = _optionalInt(item['parentId']);
        if (parentOldId != null && !idMapping.containsKey(parentOldId)) {
          continue;
        }

        final newId = await insert(
          item,
          parentOldId == null ? null : idMapping[parentOldId],
        );
        idMapping[oldId] = newId;
        pending.remove(oldId);
        progress = true;
      }

      if (!progress) {
        throw FormatException(errorMessage);
      }
    }

    return idMapping;
  }

  Future<Map<int, int>> _importKeys(List<Map<String, dynamic>> rawKeys) async {
    final idMapping = <int, int>{};
    final existingKeys = await _keyRepository.getAll();
    for (final item in rawKeys) {
      final oldId = _optionalInt(item['id']);
      final importedKey = await _importKeyMap(
        item,
        existingKeysCache: existingKeys,
      );
      if (oldId != null) {
        idMapping[oldId] = importedKey.id;
      }
    }
    return idMapping;
  }

  HostsCompanion _importedHostCompanion(
    Map<String, dynamic> item, {
    required String? autoConnectCommand,
    required bool requiresAutoConnectReview,
    int? keyId,
    int? groupId,
    int? snippetId,
    Value<int> sortOrder = const Value.absent(),
  }) => HostsCompanion.insert(
    label: _requiredString(item, 'label'),
    hostname: _requiredString(item, 'hostname'),
    port: Value(_optionalInt(item['port']) ?? 22),
    username: _requiredString(item, 'username'),
    password: Value(_optionalString(item['password'])),
    keyId: Value(keyId),
    groupId: Value(groupId),
    jumpHostId: const Value(null),
    skipJumpHostOnSsids: Value(_optionalString(item['skipJumpHostOnSsids'])),
    isFavorite: Value((item['isFavorite'] as bool?) ?? false),
    color: Value(_optionalString(item['color'])),
    notes: Value(_optionalString(item['notes'])),
    tags: Value(_optionalString(item['tags'])),
    createdAt: Value(_optionalDateTime(item['createdAt']) ?? DateTime.now()),
    updatedAt: Value(_optionalDateTime(item['updatedAt']) ?? DateTime.now()),
    lastConnectedAt: Value(_optionalDateTime(item['lastConnectedAt'])),
    terminalThemeLightId: Value(_optionalString(item['terminalThemeLightId'])),
    terminalThemeDarkId: Value(_optionalString(item['terminalThemeDarkId'])),
    terminalFontFamily: Value(_optionalString(item['terminalFontFamily'])),
    tmuxSessionName: Value(_optionalString(item['tmuxSessionName'])),
    tmuxWorkingDirectory: Value(_optionalString(item['tmuxWorkingDirectory'])),
    remoteMuxBackend: Value(_optionalString(item['remoteMuxBackend'])),
    autoConnectCommand: Value(autoConnectCommand),
    autoConnectSnippetId: Value(snippetId),
    autoConnectRequiresConfirmation: Value(requiresAutoConnectReview),
    autoForwardPorts: Value((item['autoForwardPorts'] as bool?) ?? false),
    portProxyName: Value(_importedPortProxyName(item['portProxyName'])),
    sortOrder: sortOrder,
  );

  Future<Map<int, int>> _importHosts(
    List<Map<String, dynamic>> rawHosts, {
    required Map<int, int> groupMapping,
    required Map<int, int> keyMapping,
    required Map<int, int> snippetMapping,
  }) async {
    final idMapping = <int, int>{};
    final jumpMapping = <int, int?>{};
    var removedJumpHostReferenceCount = 0;

    for (final item in rawHosts) {
      final oldId = _optionalInt(item['id']);
      final oldGroupId = _optionalInt(item['groupId']);
      final oldKeyId = _optionalInt(item['keyId']);
      final oldJumpId = _optionalInt(item['jumpHostId']);
      final oldSnippetId = _optionalInt(item['autoConnectSnippetId']);
      final autoConnectCommand = normalizeImportedAutoConnectCommand(
        _optionalString(item['autoConnectCommand']),
      );
      int? mappedGroupId;
      int? mappedKeyId;
      int? mappedSnippetId;
      if (oldGroupId != null) {
        mappedGroupId = groupMapping[oldGroupId];
        if (mappedGroupId == null) {
          throw const FormatException(
            'Invalid group reference in migration payload',
          );
        }
      }
      if (oldKeyId != null) {
        mappedKeyId = keyMapping[oldKeyId];
        if (mappedKeyId == null) {
          throw const FormatException(
            'Invalid key reference in migration payload',
          );
        }
      }
      if (oldSnippetId != null) {
        mappedSnippetId = snippetMapping[oldSnippetId];
        if (mappedSnippetId == null) {
          throw const FormatException(
            'Invalid snippet reference in migration payload',
          );
        }
      }

      final requiresAutoConnectReview = importedAutoConnectRequiresReview(
        command: autoConnectCommand,
        snippetId: mappedSnippetId,
      );

      final newId = await _hostRepository.insert(
        _importedHostCompanion(
          item,
          keyId: mappedKeyId,
          groupId: mappedGroupId,
          snippetId: mappedSnippetId,
          autoConnectCommand: autoConnectCommand,
          requiresAutoConnectReview: requiresAutoConnectReview,
          sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
        ),
      );

      if (oldId != null) {
        idMapping[oldId] = newId;
      }
      jumpMapping[newId] = oldJumpId;
    }

    for (final entry in jumpMapping.entries) {
      final newHostId = entry.key;
      final oldJumpId = entry.value;
      if (oldJumpId == null) {
        continue;
      }
      final mappedJumpId = idMapping[oldJumpId];
      if (mappedJumpId == null) {
        removedJumpHostReferenceCount += 1;
        continue;
      }
      await (_db.update(_db.hosts)..where((tbl) => tbl.id.equals(newHostId)))
          .write(HostsCompanion(jumpHostId: Value(mappedJumpId)));
    }
    if (removedJumpHostReferenceCount > 0) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'migration_import_jump_host_references_removed',
        fields: {'removedCount': removedJumpHostReferenceCount},
      );
    }

    return idMapping;
  }

  Future<Map<int, int>> _importSnippetFolders(
    List<Map<String, dynamic>> rawFolders,
  ) => _importHierarchy(
    rawFolders,
    errorMessage: 'Invalid snippet folder hierarchy in migration payload',
    insert: (item, parentId) => _db
        .into(_db.snippetFolders)
        .insert(
          SnippetFoldersCompanion.insert(
            name: _requiredString(item, 'name'),
            parentId: Value(parentId),
            sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
            createdAt: Value(
              _optionalDateTime(item['createdAt']) ?? DateTime.now(),
            ),
          ),
        ),
  );

  Future<Map<int, int>> _importSnippets(
    List<Map<String, dynamic>> rawSnippets, {
    required Map<int, int> snippetFolderMapping,
    required Set<int> autoConnectSnippetIds,
  }) async {
    final idMapping = <int, int>{};
    for (final item in rawSnippets) {
      final oldId = _optionalInt(item['id']);
      final oldFolderId = _optionalInt(item['folderId']);
      if (oldFolderId != null &&
          !snippetFolderMapping.containsKey(oldFolderId)) {
        throw const FormatException(
          'Invalid snippet folder reference in migration payload',
        );
      }
      final command = _requiredString(item, 'command');
      if (oldId != null && autoConnectSnippetIds.contains(oldId)) {
        validateImportedAutoConnectCommandText(command);
      }
      final newId = await _db
          .into(_db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: _requiredString(item, 'name'),
              command: command,
              description: Value(_optionalString(item['description'])),
              folderId: Value(
                oldFolderId == null ? null : snippetFolderMapping[oldFolderId],
              ),
              autoExecute: Value((item['autoExecute'] as bool?) ?? false),
              createdAt: Value(
                _optionalDateTime(item['createdAt']) ?? DateTime.now(),
              ),
              lastUsedAt: Value(_optionalDateTime(item['lastUsedAt'])),
              usageCount: Value(_optionalInt(item['usageCount']) ?? 0),
              sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
            ),
          );
      if (oldId != null) {
        idMapping[oldId] = newId;
      }
    }
    return idMapping;
  }

  Future<void> _importPortForwards(
    List<Map<String, dynamic>> rawPortForwards, {
    required Map<int, int> hostMapping,
  }) async {
    var skippedPortForwardCount = 0;
    for (final item in rawPortForwards) {
      final oldHostId = _optionalInt(item['hostId']);
      if (oldHostId == null) {
        skippedPortForwardCount += 1;
        continue;
      }
      final mappedHostId = hostMapping[oldHostId];
      if (mappedHostId == null) {
        skippedPortForwardCount += 1;
        continue;
      }

      await _db
          .into(_db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              name: _requiredString(item, 'name'),
              hostId: mappedHostId,
              forwardType: _requiredString(item, 'forwardType'),
              localHost: Value(
                _optionalString(item['localHost']) ?? '127.0.0.1',
              ),
              localPort: _optionalInt(item['localPort']) ?? 0,
              remoteHost: _requiredString(item, 'remoteHost'),
              remotePort: _optionalInt(item['remotePort']) ?? 0,
              autoStart: Value((item['autoStart'] as bool?) ?? false),
              createdAt: Value(
                _optionalDateTime(item['createdAt']) ?? DateTime.now(),
              ),
            ),
          );
    }
    if (skippedPortForwardCount > 0) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'migration_import_port_forwards_skipped',
        fields: {'skippedCount': skippedPortForwardCount},
      );
    }
  }

  Future<void> _importKnownHosts(
    List<Map<String, dynamic>> rawKnownHosts, {
    required MigrationImportMode mode,
  }) async {
    for (final item in rawKnownHosts) {
      final importedKnownHost = _ImportedKnownHost(
        hostname: _requiredString(item, 'hostname'),
        port: _optionalInt(item['port']) ?? 22,
        keyType: _normalizedImportedKnownHostKeyType(item),
        fingerprint: _normalizedImportedKnownHostFingerprint(item),
        hostKey: _normalizedImportedKnownHostHostKey(item),
        firstSeen: _optionalDateTime(item['firstSeen']) ?? DateTime.now(),
        lastSeen: _optionalDateTime(item['lastSeen']) ?? DateTime.now(),
      );

      if (mode == MigrationImportMode.replace) {
        await _db
            .into(_db.knownHosts)
            .insertOnConflictUpdate(importedKnownHost.toCompanion());
        continue;
      }

      final existingKnownHost =
          await ((_db.select(_db.knownHosts))..where(
                (knownHost) =>
                    knownHost.hostname.equals(importedKnownHost.hostname) &
                    knownHost.port.equals(importedKnownHost.port),
              ))
              .getSingleOrNull();
      if (existingKnownHost == null) {
        await _db.into(_db.knownHosts).insert(importedKnownHost.toCompanion());
        continue;
      }

      final isSameTrustedKey = sshHostTrustMatches(
        firstFingerprint: existingKnownHost.fingerprint,
        firstEncodedHostKey: existingKnownHost.hostKey,
        secondFingerprint: importedKnownHost.fingerprint,
        secondEncodedHostKey: importedKnownHost.hostKey,
      );
      if (isSameTrustedKey) {
        await (_db.update(_db.knownHosts)
              ..where((knownHost) => knownHost.id.equals(existingKnownHost.id)))
            .write(_mergeKnownHosts(existingKnownHost, importedKnownHost));
        continue;
      }

      if (!importedKnownHost.lastSeen.isAfter(existingKnownHost.lastSeen)) {
        continue;
      }

      await (_db.update(_db.knownHosts)
            ..where((knownHost) => knownHost.id.equals(existingKnownHost.id)))
          .write(importedKnownHost.toCompanion());
    }
  }

  Future<void> _importSettings(
    Map<String, String> settings, {
    required bool clearExisting,
    required Map<int, int> hostMapping,
  }) async {
    final preparedSettings = _prepareImportedSettings(
      _sortedStringMap(settings),
      hostMapping: hostMapping,
    );
    if (clearExisting) {
      await _db.customStatement('DELETE FROM settings');
    }
    for (final entry in preparedSettings.entries) {
      final value =
          !clearExisting && _hostScopedSettingsKeys.contains(entry.key)
          ? await _mergeHostScopedSettingValue(entry.key, entry.value)
          : entry.value;
      await _db
          .into(_db.settings)
          .insertOnConflictUpdate(
            SettingsCompanion.insert(key: entry.key, value: value),
          );
    }
  }

  List<Map<String, dynamic>> _listFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final rawList = data[key];
    if (rawList is! List) {
      return <Map<String, dynamic>>[];
    }
    return rawList
        .map((item) {
          if (item is! Map) {
            throw FormatException('Invalid $key entry in migration payload');
          }
          return Map<String, dynamic>.from(item);
        })
        .toList(growable: false);
  }

  Map<String, Object?> _migrationImportDiagnosticsFields({
    required Map<String, dynamic> data,
    required MigrationImportMode mode,
  }) => {
    'mode': mode,
    'settingsCount': _mapCount(data, 'settings'),
    'groupCount': _listCount(data, 'groups'),
    'keyCount': _listCount(data, 'keys'),
    'hostCount': _listCount(data, 'hosts'),
    'snippetFolderCount': _listCount(data, 'snippetFolders'),
    'snippetCount': _listCount(data, 'snippets'),
    'portForwardCount': _listCount(data, 'portForwards'),
    'knownHostCount': _listCount(data, 'knownHosts'),
  };

  int _listCount(Map<String, dynamic> data, String key) {
    final value = data[key];
    return value is List ? value.length : 0;
  }

  int _mapCount(Map<String, dynamic> data, String key) {
    final value = data[key];
    return value is Map ? value.length : 0;
  }

  Map<String, String> _settingsFromData(Map<String, dynamic> data) {
    final rawSettings = data['settings'];
    if (rawSettings is! Map) {
      return <String, String>{};
    }
    final result = <String, String>{};
    for (final entry in rawSettings.entries) {
      if (entry.key is String && entry.value is String) {
        result[entry.key as String] = entry.value as String;
      }
    }
    return result;
  }

  Map<String, String> _prepareImportedSettings(
    Map<String, String> settings, {
    required Map<int, int> hostMapping,
  }) {
    final preparedSettings = <String, String>{};
    for (final entry in settings.entries) {
      if (!_hostScopedSettingsKeys.contains(entry.key)) {
        preparedSettings[entry.key] = entry.value;
        continue;
      }

      final remappedValue = _remapHostScopedSettingValue(
        entry.value,
        hostMapping,
      );
      if (remappedValue != null) {
        preparedSettings[entry.key] = remappedValue;
      }
    }
    return _sortedStringMap(preparedSettings);
  }

  String? _remapHostScopedSettingValue(
    String rawValue,
    Map<int, int> hostMapping,
  ) {
    final decodedSetting = _decodeHostScopedSettingValue(rawValue);
    final remappedSetting = <String, dynamic>{};
    for (final entry in decodedSetting.entries) {
      final oldHostId = int.tryParse(entry.key);
      if (oldHostId == null) {
        remappedSetting[entry.key] = entry.value;
        continue;
      }

      final mappedHostId = hostMapping[oldHostId];
      if (mappedHostId != null) {
        remappedSetting[mappedHostId.toString()] = entry.value;
      }
    }

    if (remappedSetting.isEmpty) {
      return null;
    }
    return jsonEncode(_canonicalizeJsonValue(remappedSetting));
  }

  Future<String> _mergeHostScopedSettingValue(
    String key,
    String importedValue,
  ) async {
    final existingSetting = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    if (existingSetting == null) {
      return importedValue;
    }

    final mergedSetting = <String, dynamic>{
      ..._decodeHostScopedSettingValue(existingSetting.value),
      ..._decodeHostScopedSettingValue(importedValue),
    };
    return jsonEncode(_canonicalizeJsonValue(mergedSetting));
  }

  Map<String, dynamic> _decodeHostScopedSettingValue(String rawValue) {
    final decodedValue = jsonDecode(rawValue);
    if (decodedValue is! Map) {
      throw const FormatException('Invalid host-scoped setting payload');
    }
    return {
      for (final entry in decodedValue.entries)
        '${entry.key}': _canonicalizeJsonValue(entry.value),
    };
  }

  Map<String, String> _sortedStringMap(Map<String, String> settings) =>
      Map<String, String>.fromEntries(
        settings.entries.toList(growable: false)
          ..sort((first, second) => first.key.compareTo(second.key)),
      );

  SettingsService get _settingsService => SettingsService(_db);

  HostCliLaunchPreferencesService get _hostCliLaunchPreferencesService =>
      HostCliLaunchPreferencesService(_settingsService);

  List<Map<String, dynamic>> _sortedJsonRecords(
    Iterable<Map<String, dynamic>> records,
  ) {
    final sorted =
        records
            .map((record) {
              final canonical = Map<String, dynamic>.from(
                _canonicalizeJsonValue(record)! as Map,
              );
              return (record: canonical, sortKey: jsonEncode(canonical));
            })
            .toList(growable: false)
          ..sort((first, second) => first.sortKey.compareTo(second.sortKey));
    return sorted.map((item) => item.record).toList(growable: false);
  }

  Object? _canonicalizeJsonValue(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList(growable: false)
        ..sort((first, second) => '${first.key}'.compareTo('${second.key}'));
      return <String, dynamic>{
        for (final entry in entries)
          '${entry.key}': _canonicalizeJsonValue(entry.value),
      };
    }
    if (value is List) {
      return value.map(_canonicalizeJsonValue).toList(growable: false);
    }
    return value;
  }

  String _requiredString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('Missing required field: $key');
  }

  String? _optionalString(Object? value) => value is String ? value : null;

  String? _importedPortProxyName(Object? value) {
    final normalized = normalizeOptionalPortProxyName(_optionalString(value));
    if (validatePortProxyName(normalized) != null) {
      _diagnosticsLogger.warning(
        'secure_transfer',
        'invalid_port_proxy_name_skipped',
      );
      return null;
    }
    return normalized;
  }

  DateTime? _optionalDateTime(Object? value) {
    if (value is DateTime) {
      return value;
    }
    if (value is num) {
      return _dateTimeFromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
      final millisecondsSinceEpoch = int.tryParse(value);
      if (millisecondsSinceEpoch != null) {
        return _dateTimeFromMillisecondsSinceEpoch(millisecondsSinceEpoch);
      }
    }
    return null;
  }

  DateTime? _dateTimeFromMillisecondsSinceEpoch(int millisecondsSinceEpoch) {
    if (millisecondsSinceEpoch < _minEpochMilliseconds ||
        millisecondsSinceEpoch > _maxEpochMilliseconds) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(
      millisecondsSinceEpoch,
      isUtc: true,
    );
  }

  String _normalizedImportedKnownHostFingerprint(Map<String, dynamic> item) {
    final hostKey = _normalizedImportedKnownHostHostKey(item);
    if (hostKey.isNotEmpty) {
      try {
        final hostKeyBytes = base64.decode(hostKey);
        return formatSshHostKeyFingerprint(hostKeyBytes);
      } on FormatException {
        return _requiredString(item, 'fingerprint');
      }
    }
    return _requiredString(item, 'fingerprint');
  }

  String _normalizedImportedKnownHostHostKey(Map<String, dynamic> item) {
    final hostKey = _optionalString(item['hostKey']) ?? '';
    if (hostKey.isEmpty || _tryDecodeKnownHostKey(hostKey) != null) {
      return hostKey;
    }
    return '';
  }

  String _normalizedImportedKnownHostKeyType(Map<String, dynamic> item) =>
      canonicalizeSshHostKeyType(
        _requiredString(item, 'keyType'),
        encodedHostKey: _normalizedImportedKnownHostHostKey(item),
      );

  KnownHostsCompanion _mergeKnownHosts(
    KnownHost existingKnownHost,
    _ImportedKnownHost importedKnownHost,
  ) {
    final mergedHostKey = importedKnownHost.hostKey.isNotEmpty
        ? importedKnownHost.hostKey
        : existingKnownHost.hostKey;
    final mergedFirstSeen =
        importedKnownHost.firstSeen.isBefore(existingKnownHost.firstSeen)
        ? importedKnownHost.firstSeen
        : existingKnownHost.firstSeen;
    final mergedLastSeen =
        importedKnownHost.lastSeen.isAfter(existingKnownHost.lastSeen)
        ? importedKnownHost.lastSeen
        : existingKnownHost.lastSeen;
    final preferImported = importedKnownHost.lastSeen.isAfter(
      existingKnownHost.lastSeen,
    );
    final mergedHostKeyBytes = _tryDecodeKnownHostKey(mergedHostKey);

    if (mergedHostKeyBytes != null) {
      return KnownHostsCompanion(
        keyType: Value(
          canonicalizeSshHostKeyType(
            importedKnownHost.keyType,
            encodedHostKey: mergedHostKey,
          ),
        ),
        fingerprint: Value(formatSshHostKeyFingerprint(mergedHostKeyBytes)),
        hostKey: Value(mergedHostKey),
        firstSeen: Value(mergedFirstSeen),
        lastSeen: Value(mergedLastSeen),
      );
    }

    final fallbackHostKey =
        preferImported ||
            _tryDecodeKnownHostKey(existingKnownHost.hostKey) == null
        ? ''
        : existingKnownHost.hostKey;
    final mergedFingerprint = _preferKnownHostFingerprint(
      existingKnownHost.fingerprint,
      importedKnownHost.fingerprint,
      preferSecond: preferImported,
    );
    final mergedKeyType = canonicalizeSshHostKeyType(
      preferImported ? importedKnownHost.keyType : existingKnownHost.keyType,
      encodedHostKey: fallbackHostKey.isEmpty ? null : fallbackHostKey,
    );

    return KnownHostsCompanion(
      keyType: Value(mergedKeyType),
      fingerprint: Value(mergedFingerprint),
      hostKey: Value(fallbackHostKey),
      firstSeen: Value(mergedFirstSeen),
      lastSeen: Value(mergedLastSeen),
    );
  }

  Uint8List? _tryDecodeKnownHostKey(String encodedHostKey) {
    if (encodedHostKey.isEmpty) {
      return null;
    }

    try {
      final decoded = Uint8List.fromList(base64.decode(encodedHostKey));
      if (!_looksLikeKnownHostKeyBlob(decoded)) {
        return null;
      }
      return decoded;
    } on FormatException {
      return null;
    }
  }

  bool _looksLikeKnownHostKeyBlob(Uint8List hostKeyBytes) {
    final keyTypeBytes = _readSshBlobString(hostKeyBytes, 0);
    if (keyTypeBytes == null) {
      return false;
    }

    final keyType = utf8.decode(keyTypeBytes, allowMalformed: true);
    return keyType == 'ssh-rsa' ||
        keyType == 'ssh-ed25519' ||
        keyType.startsWith('ecdsa-sha2-');
  }

  Uint8List? _readSshBlobString(Uint8List bytes, int offset) {
    if (bytes.length - offset < 4) {
      return null;
    }

    final length =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final start = offset + 4;
    final end = start + length;
    if (length < 0 || end > bytes.length) {
      return null;
    }
    return Uint8List.sublistView(bytes, start, end);
  }

  String _preferKnownHostFingerprint(
    String firstFingerprint,
    String secondFingerprint, {
    required bool preferSecond,
  }) {
    final firstIsSha256 = firstFingerprint.startsWith('SHA256:');
    final secondIsSha256 = secondFingerprint.startsWith('SHA256:');
    if (firstIsSha256 != secondIsSha256) {
      return secondIsSha256 ? secondFingerprint : firstFingerprint;
    }
    return preferSecond ? secondFingerprint : firstFingerprint;
  }
}

class _ImportedKnownHost {
  const _ImportedKnownHost({
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
}

/// Provider for [SecureTransferService].
final secureTransferServiceProvider = Provider<SecureTransferService>(
  (ref) => SecureTransferService(
    ref.watch(databaseProvider),
    ref.watch(keyRepositoryProvider),
    ref.watch(hostRepositoryProvider),
    diagnosticsLogger: ref.watch(diagnosticsLoggerProvider),
    onHostsChanged: () => ref
        .read(activeSessionsProvider.notifier)
        .reconfigureAutomaticPortForwardingForConnectedHosts(),
  ),
);

const _payloadPrefix = 'MSSH1:';
const _legacyEnvelopeVersion = 1;
const _envelopeVersion = 2;
const _saltBytes = 16;
const _nonceBytes = 12;
const _pbkdf2Iterations = 120000;
const _maxPbkdf2Iterations = 1000000;
const _argon2idIterations = 3;
const _argon2idMemoryKiB = 32768;
const _argon2idLanes = 1;

Future<String> _encryptTransferPayload(
  (TransferPayload, String) request,
) async {
  final (payload, transferPassphrase) = request;
  if (transferPassphrase.trim().isEmpty) {
    throw const FormatException('Transfer passphrase is required');
  }

  final payloadBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(payload.toJson())),
  );
  final random = Random.secure();
  final salt = List<int>.generate(
    _saltBytes,
    (_) => random.nextInt(256),
    growable: false,
  );
  final nonce = List<int>.generate(
    _nonceBytes,
    (_) => random.nextInt(256),
    growable: false,
  );
  final secretKey = _deriveArgon2idKey(
    transferPassphrase,
    salt,
    iterations: _argon2idIterations,
    memoryKiB: _argon2idMemoryKiB,
    lanes: _argon2idLanes,
  );
  final encryptedBox = await AesGcm.with256bits().encrypt(
    payloadBytes,
    secretKey: secretKey,
    nonce: nonce,
  );
  final checksum = await Sha256().hash(payloadBytes);

  final envelope = {
    'v': _envelopeVersion,
    'alg': 'AES-GCM-256',
    'kdf': 'Argon2id',
    'iter': _argon2idIterations,
    'mem': _argon2idMemoryKiB,
    'lanes': _argon2idLanes,
    'salt': base64Url.encode(salt),
    'nonce': base64Url.encode(nonce),
    'ciphertext': base64Url.encode(encryptedBox.cipherText),
    'mac': base64Url.encode(encryptedBox.mac.bytes),
    'checksum': base64Url.encode(checksum.bytes),
  };
  return '$_payloadPrefix${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
}

Future<TransferPayload> _decryptTransferPayload(
  (String, String) request,
) async {
  final (encodedPayload, transferPassphrase) = request;
  final normalized = encodedPayload.trim();
  if (normalized.isEmpty) {
    throw const FormatException('Transfer payload is empty');
  }

  if (transferPassphrase.trim().isEmpty) {
    throw const FormatException('Transfer passphrase is required');
  }

  final compactPayload = normalized.startsWith(_payloadPrefix)
      ? normalized.substring(_payloadPrefix.length)
      : normalized;
  final envelopeJson = utf8.decode(
    base64Url.decode(base64Url.normalize(compactPayload)),
  );
  final envelope = jsonDecode(envelopeJson);
  if (envelope is! Map) {
    throw const FormatException('Invalid transfer envelope');
  }

  final envelopeMap = Map<String, dynamic>.from(envelope);
  final versionValue = envelopeMap['v'];
  if (versionValue is! num) {
    throw const FormatException('Unsupported transfer envelope version');
  }
  final envelopeVersion = versionValue.toInt();
  if (envelopeVersion != _legacyEnvelopeVersion &&
      envelopeVersion != _envelopeVersion) {
    throw const FormatException('Unsupported transfer envelope version');
  }

  final salt = _decodeEnvelopeField(envelopeMap, 'salt');
  final nonce = _decodeEnvelopeField(envelopeMap, 'nonce');
  final cipherText = _decodeEnvelopeField(envelopeMap, 'ciphertext');
  final macBytes = _decodeEnvelopeField(envelopeMap, 'mac');
  if (salt.length != _saltBytes ||
      nonce.length != _nonceBytes ||
      macBytes.length < 16) {
    throw const FormatException('Invalid transfer envelope');
  }

  final secretKey = await _deriveEnvelopeKey(
    transferPassphrase: transferPassphrase,
    salt: salt,
    envelope: envelopeMap,
    version: envelopeVersion,
  );
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

  late List<int> plaintext;
  try {
    plaintext = await AesGcm.with256bits().decrypt(
      secretBox,
      secretKey: secretKey,
    );
  } on SecretBoxAuthenticationError {
    throw const FormatException('Invalid passphrase or transfer payload');
  }

  final expectedChecksumValue = envelopeMap['checksum'];
  if (expectedChecksumValue != null) {
    if (expectedChecksumValue is! String || expectedChecksumValue.isEmpty) {
      throw const FormatException('Invalid transfer envelope');
    }
    final actualChecksum = await Sha256().hash(plaintext);
    final encodedChecksum = base64Url.encode(actualChecksum.bytes);
    if (encodedChecksum != expectedChecksumValue) {
      throw const FormatException('Transfer payload checksum mismatch');
    }
  }

  final payloadJson = jsonDecode(utf8.decode(plaintext));
  if (payloadJson is! Map) {
    throw const FormatException('Invalid decrypted payload');
  }
  return TransferPayload.fromJson(Map<String, dynamic>.from(payloadJson));
}

Future<SecretKey> _deriveEnvelopeKey({
  required String transferPassphrase,
  required List<int> salt,
  required Map<String, dynamic> envelope,
  required int version,
}) async {
  if (version == _legacyEnvelopeVersion) {
    final iterations = _optionalInt(envelope['iter']) ?? _pbkdf2Iterations;
    if (iterations <= 0 || iterations > _maxPbkdf2Iterations) {
      throw const FormatException('Invalid transfer envelope');
    }
    return _derivePbkdf2Key(transferPassphrase, salt, iterations: iterations);
  }

  final iterations = _optionalInt(envelope['iter']) ?? _argon2idIterations;
  final memoryKiB = _optionalInt(envelope['mem']) ?? _argon2idMemoryKiB;
  final lanes = _optionalInt(envelope['lanes']) ?? _argon2idLanes;
  if (iterations <= 0 ||
      iterations > 10 ||
      memoryKiB < 8192 ||
      memoryKiB > 262144 ||
      lanes <= 0 ||
      lanes > 4) {
    throw const FormatException('Invalid transfer envelope');
  }

  return _deriveArgon2idKey(
    transferPassphrase,
    salt,
    iterations: iterations,
    memoryKiB: memoryKiB,
    lanes: lanes,
  );
}

Future<SecretKey> _derivePbkdf2Key(
  String passphrase,
  List<int> salt, {
  required int iterations,
}) {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  return pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
}

SecretKey _deriveArgon2idKey(
  String passphrase,
  List<int> salt, {
  required int iterations,
  required int memoryKiB,
  required int lanes,
}) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        Uint8List.fromList(salt),
        desiredKeyLength: 32,
        iterations: iterations,
        memory: memoryKiB,
        lanes: lanes,
      ),
    );
  return SecretKey(
    generator.process(Uint8List.fromList(utf8.encode(passphrase))),
  );
}

int? _optionalInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

List<int> _decodeEnvelopeField(Map<String, dynamic> envelope, String key) {
  final value = envelope[key];
  if (value is! String || value.isEmpty) {
    throw const FormatException('Invalid transfer envelope');
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw const FormatException('Invalid transfer envelope');
  }
}
