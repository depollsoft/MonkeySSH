import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';
import 'plaintext_cache.dart';

enum _KeySecretColumn { privateKey, passphrase }

/// Result from loading decryptable SSH keys while tolerating unreadable rows.
class SshKeyLoadResult {
  /// Creates a new [SshKeyLoadResult].
  const SshKeyLoadResult({
    required this.keys,
    required this.unreadableCount,
    this.firstUnreadableErrorType,
  });

  /// Stored keys, with unreadable secret fields returned as empty or null.
  final List<SshKey> keys;

  /// Number of stored keys with unreadable secrets.
  final int unreadableCount;

  /// Runtime type for the first unreadable-key error, if any.
  final String? firstUnreadableErrorType;
}

/// Repository for managing SSH keys.
class KeyRepository {
  /// Creates a new [KeyRepository].
  KeyRepository(
    this._db,
    this._secretEncryptionService, {
    DiagnosticsLogService? diagnosticsLog,
  }) : _diagnosticsLog = diagnosticsLog ?? DiagnosticsLogService.instance;

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;
  final DiagnosticsLogService _diagnosticsLog;
  late final _decryptCache = PlaintextCache(_secretEncryptionService);
  final _undecryptablePrivateKeyIds = <int>{};
  final _undecryptablePassphraseKeyIds = <int>{};
  final _loggedUndecryptableKeyIds = <int>{};

  /// Clears cached decrypted secret plaintexts.
  void clearDecryptionCache() {
    _decryptCache.clear();
  }

  /// Whether the saved private key needs to be re-entered after a failed read.
  bool hasUnreadablePrivateKey(int keyId) =>
      _undecryptablePrivateKeyIds.contains(keyId);

  /// Whether the saved passphrase needs to be re-entered after a failed read.
  bool hasUnreadablePassphrase(int keyId) =>
      _undecryptablePassphraseKeyIds.contains(keyId);

  /// Number of cached decrypted secret plaintexts.
  @visibleForTesting
  int get debugDecryptionCacheSize => _decryptCache.length;

  /// Get all keys.
  Future<List<SshKey>> getAll() async {
    final keys = await _db.select(_db.sshKeys).get();
    return Future.wait(keys.map(_decryptKey));
  }

  /// Get all keys, reporting rows with unreadable secret fields.
  Future<SshKeyLoadResult> getAllDecryptable() async {
    final keys = await _db.select(_db.sshKeys).get();
    return _loadDecryptable(keys);
  }

  /// Watch all keys.
  Stream<List<SshKey>> watchAll() => _db
      .select(_db.sshKeys)
      .watch()
      .asyncMap((keys) async => (await _loadDecryptable(keys)).keys);

  /// Get a key by ID.
  Future<SshKey?> getById(int id) async {
    final key = await (_db.select(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).getSingleOrNull();
    if (key == null) {
      return null;
    }
    return _decryptKey(key);
  }

  /// Insert a new key.
  Future<int> insert(SshKeysCompanion key) async {
    final encryptedKey = await _encryptKeyCompanion(key);
    return _db.into(_db.sshKeys).insert(encryptedKey);
  }

  /// Updates a key, preserving unreadable secrets until they are replaced.
  Future<bool> update(SshKey key) async {
    final generation = _decryptCache.generation;
    final previousStoredSecrets = await _storedSecretsForKey(key.id);
    final preservesUnreadablePrivateKey =
        hasUnreadablePrivateKey(key.id) &&
        key.privateKey.isEmpty &&
        previousStoredSecrets != null;
    final preservesUnreadablePassphrase =
        hasUnreadablePassphrase(key.id) &&
        (key.passphrase == null || key.passphrase!.isEmpty) &&
        previousStoredSecrets?.passphrase != null;
    final encryptedPrivateKey = preservesUnreadablePrivateKey
        ? previousStoredSecrets.privateKey
        : await _secretEncryptionService.encryptRequired(key.privateKey);
    final encryptedPassphrase = preservesUnreadablePassphrase
        ? previousStoredSecrets!.passphrase
        : await _secretEncryptionService.encryptNullable(key.passphrase);
    final updated = await _db
        .update(_db.sshKeys)
        .replace(
          key.copyWith(
            privateKey: encryptedPrivateKey,
            passphrase: Value(encryptedPassphrase),
          ),
        );
    if (updated) {
      if (!preservesUnreadablePrivateKey) {
        _undecryptablePrivateKeyIds.remove(key.id);
        _decryptCache
          ..remove(previousStoredSecrets?.privateKey)
          ..remember(
            encryptedPrivateKey,
            key.privateKey,
            generation,
            isWrite: true,
          );
      }
      if (!preservesUnreadablePassphrase) {
        _undecryptablePassphraseKeyIds.remove(key.id);
        _decryptCache
          ..remove(previousStoredSecrets?.passphrase)
          ..remember(
            encryptedPassphrase,
            key.passphrase,
            generation,
            isWrite: true,
          );
      }
      _clearRecoveredKeyDiagnostic(key.id);
    }
    return updated;
  }

  /// Delete a key.
  Future<int> delete(int id) async {
    final previousStoredSecrets = await _storedSecretsForKey(id);
    final deleted = await (_db.delete(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).go();
    if (deleted > 0) {
      _undecryptablePrivateKeyIds.remove(id);
      _undecryptablePassphraseKeyIds.remove(id);
      _loggedUndecryptableKeyIds.remove(id);
      _decryptCache
        ..remove(previousStoredSecrets?.privateKey)
        ..remove(previousStoredSecrets?.passphrase);
    }
    return deleted;
  }

  Future<SshKeyLoadResult> _loadDecryptable(List<SshKey> keys) async {
    final generation = _decryptCache.generation;
    final decryptedKeys = <SshKey>[];
    var unreadableCount = 0;
    String? firstUnreadableErrorType;

    for (final key in keys) {
      try {
        decryptedKeys.add(await _decryptKey(key, generation: generation));
        if (hasUnreadablePrivateKey(key.id) ||
            hasUnreadablePassphrase(key.id)) {
          unreadableCount++;
          firstUnreadableErrorType ??= 'FormatException';
        }
      } on Exception catch (error) {
        unreadableCount++;
        firstUnreadableErrorType ??= error.runtimeType.toString();
      }
    }

    return SshKeyLoadResult(
      keys: List.unmodifiable(decryptedKeys),
      unreadableCount: unreadableCount,
      firstUnreadableErrorType: firstUnreadableErrorType,
    );
  }

  Future<SshKey> _decryptKey(SshKey key, {int? generation}) async {
    generation ??= _decryptCache.generation;
    final decryptedPrivateKey =
        await _decryptOrMigrateKeySecret(
          key.id,
          key.privateKey,
          _KeySecretColumn.privateKey,
          generation,
        ) ??
        '';
    final decryptedPassphrase = await _decryptOrMigrateKeySecret(
      key.id,
      key.passphrase,
      _KeySecretColumn.passphrase,
      generation,
    );
    _clearRecoveredKeyDiagnostic(key.id);

    return key.copyWith(
      privateKey: decryptedPrivateKey,
      passphrase: Value(decryptedPassphrase),
    );
  }

  Future<String?> _decryptOrMigrateKeySecret(
    int keyId,
    String? storedSecret,
    _KeySecretColumn column,
    int generation,
  ) async {
    final undecryptableKeyIds = switch (column) {
      _KeySecretColumn.privateKey => _undecryptablePrivateKeyIds,
      _KeySecretColumn.passphrase => _undecryptablePassphraseKeyIds,
    };
    if (storedSecret == null || storedSecret.isEmpty) {
      undecryptableKeyIds.remove(keyId);
      return storedSecret;
    }
    final cached = _decryptCache.lookup(storedSecret);
    if (cached != null) {
      undecryptableKeyIds.remove(keyId);
      return cached;
    }
    // A damaged encrypted envelope is not a legacy plaintext secret.
    if (_secretEncryptionService.isEncryptedValue(storedSecret)) {
      try {
        final decryptedSecret = await _decryptCache.decrypt(
          storedSecret,
          generation,
        );
        undecryptableKeyIds.remove(keyId);
        return decryptedSecret;
      } on FormatException catch (error) {
        undecryptableKeyIds.add(keyId);
        if (_loggedUndecryptableKeyIds.add(keyId)) {
          _diagnosticsLog.warning(
            'key.secrets',
            'secret_decryption_failed',
            fields: {'keyId': keyId, 'errorType': error.runtimeType.toString()},
          );
        }
        return null;
      }
    }

    final encryptedSecret = await _secretEncryptionService.encryptNullable(
      storedSecret,
    );
    if (encryptedSecret != null && encryptedSecret != storedSecret) {
      await (_db.update(_db.sshKeys)..where(
            (k) =>
                k.id.equals(keyId) &
                (switch (column) {
                  _KeySecretColumn.privateKey => k.privateKey.equals(
                    storedSecret,
                  ),
                  _KeySecretColumn.passphrase => k.passphrase.equals(
                    storedSecret,
                  ),
                }),
          ))
          .write(switch (column) {
            _KeySecretColumn.privateKey => SshKeysCompanion(
              privateKey: Value(encryptedSecret),
            ),
            _KeySecretColumn.passphrase => SshKeysCompanion(
              passphrase: Value(encryptedSecret),
            ),
          });
      _decryptCache.remember(encryptedSecret, storedSecret, generation);
    }
    undecryptableKeyIds.remove(keyId);
    return storedSecret;
  }

  void _clearRecoveredKeyDiagnostic(int keyId) {
    if (!hasUnreadablePrivateKey(keyId) && !hasUnreadablePassphrase(keyId)) {
      _loggedUndecryptableKeyIds.remove(keyId);
    }
  }

  Future<({String? passphrase, String privateKey})?> _storedSecretsForKey(
    int id,
  ) async {
    final row = await (_db.select(
      _db.sshKeys,
    )..where((k) => k.id.equals(id))).getSingleOrNull();
    if (row == null) {
      return null;
    }
    return (privateKey: row.privateKey, passphrase: row.passphrase);
  }

  Future<SshKeysCompanion> _encryptKeyCompanion(SshKeysCompanion key) async {
    final encryptedPrivateKey = key.privateKey.present
        ? await _secretEncryptionService.encryptRequired(key.privateKey.value)
        : '';

    if (!key.privateKey.present) {
      throw ArgumentError('SSH key privateKey must be present');
    }

    if (!key.passphrase.present) {
      return key.copyWith(privateKey: Value(encryptedPrivateKey));
    }

    final encryptedPassphrase = await _secretEncryptionService.encryptNullable(
      key.passphrase.value,
    );
    return key.copyWith(
      privateKey: Value(encryptedPrivateKey),
      passphrase: Value(encryptedPassphrase),
    );
  }
}

/// Provider for [KeyRepository].
final keyRepositoryProvider = Provider<KeyRepository>((ref) {
  final repository = KeyRepository(
    ref.watch(databaseProvider),
    ref.watch(secretEncryptionServiceProvider),
  );
  ref.listen<AuthState>(authStateProvider, (_, next) {
    if (next == AuthState.locked) {
      repository.clearDecryptionCache();
    }
  });
  return repository;
});
