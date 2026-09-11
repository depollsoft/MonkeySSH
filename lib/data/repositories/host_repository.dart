import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/port_proxy_name.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';
import 'plaintext_cache.dart';

/// Repository for managing host entities.
class HostRepository {
  /// Creates a new [HostRepository].
  HostRepository(
    this._db,
    this._secretEncryptionService, {
    DiagnosticsLogService? diagnosticsLog,
  }) : _diagnosticsLog = diagnosticsLog ?? DiagnosticsLogService.instance;

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;
  final DiagnosticsLogService _diagnosticsLog;
  late final _decryptCache = PlaintextCache(_secretEncryptionService);

  final _undecryptablePasswordHostIds = <int>{};

  /// Clears cached decrypted secret plaintexts.
  void clearDecryptionCache() {
    _decryptCache.clear();
  }

  /// Whether the saved password needs to be re-entered after a failed read.
  bool hasUnreadablePassword(int hostId) =>
      _undecryptablePasswordHostIds.contains(hostId);

  /// Number of cached decrypted secret plaintexts.
  @visibleForTesting
  int get debugDecryptionCacheSize => _decryptCache.length;

  /// Get all hosts.
  Future<List<Host>> getAll() => _orderedHostsQuery().get().then(_decryptHosts);

  /// Watch all hosts.
  Stream<List<Host>> watchAll() =>
      _orderedHostsQuery().watch().asyncMap(_decryptHosts);

  /// Get a host by ID.
  Future<Host?> getById(int id) async {
    final host = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    if (host == null) {
      return null;
    }
    return _decryptHost(host);
  }

  /// Watch a single host by ID.
  Stream<Host?> watchById(int id) =>
      (_db.select(
        _db.hosts,
      )..where((h) => h.id.equals(id))).watchSingleOrNull().asyncMap(
        (host) => host == null ? Future.value() : _decryptHost(host),
      );

  /// Resolves this host's collision-free custom or generated proxy name.
  Future<String> resolveProxyName({
    required int hostId,
    required String label,
    String? customName,
  }) async {
    final rows =
        await (_db.selectOnly(_db.hosts)..addColumns([
              _db.hosts.id,
              _db.hosts.label,
              _db.hosts.portProxyName,
            ]))
            .get();
    final normalizedCustomName = normalizeOptionalStoredPortProxyName(
      customName,
    );
    if (normalizedCustomName != null &&
        isReservedSavedForwardProxyName(normalizedCustomName)) {
      throw PortProxyNameConflictException(normalizedCustomName);
    }
    final customNamesById = <int, String>{};
    final hosts = [
      for (final row in rows)
        (
          id: row.read(_db.hosts.id)!,
          label: row.read(_db.hosts.id) == hostId
              ? label
              : row.read(_db.hosts.label) ?? '',
        ),
    ];
    if (!hosts.any((host) => host.id == hostId)) {
      hosts.add((id: hostId, label: label));
    }
    for (final row in rows) {
      final id = row.read(_db.hosts.id)!;
      final name = normalizeOptionalStoredPortProxyName(
        id == hostId ? customName : row.read(_db.hosts.portProxyName),
      );
      if (name != null) {
        customNamesById[id] = name;
      }
    }
    if (normalizedCustomName != null) {
      customNamesById[hostId] = normalizedCustomName;
      if (customNamesById.entries.any(
        (entry) => entry.key != hostId && entry.value == normalizedCustomName,
      )) {
        throw PortProxyNameConflictException(normalizedCustomName);
      }
    }

    final generatedHosts = hosts
        .where((host) => !customNamesById.containsKey(host.id))
        .toList(growable: false);
    final existingGeneratedNames = resolveGeneratedPortProxyNames(
      generatedHosts,
      reservedNames: normalizedCustomName == null
          ? customNamesById.values
          : customNamesById.entries
                .where((entry) => entry.key != hostId)
                .map((entry) => entry.value),
    );
    if (normalizedCustomName != null) {
      if (existingGeneratedNames.values.contains(normalizedCustomName)) {
        throw PortProxyNameConflictException(normalizedCustomName);
      }
      return normalizedCustomName;
    }
    return existingGeneratedNames[hostId] ?? generatedPortProxySlug(label);
  }

  /// Insert a new host.
  Future<int> insert(HostsCompanion host) async {
    if (host.portProxyName.present && host.portProxyName.value != null) {
      await validateProxyName(
        hostId: -1,
        label: host.label.value,
        customName: host.portProxyName.value,
      );
    }
    final encryptedHost = await _encryptHostCompanion(
      host.copyWith(
        sortOrder: host.sortOrder.present
            ? host.sortOrder
            : Value(await _nextSortOrder()),
      ),
    );
    return _db.into(_db.hosts).insert(encryptedHost);
  }

  /// Validates a custom proxy name against every saved alias.
  Future<void> validateProxyName({
    required int hostId,
    required String label,
    String? customName,
  }) async {
    if (normalizeOptionalStoredPortProxyName(customName) == null) {
      return;
    }
    await resolveProxyName(
      hostId: hostId,
      label: label,
      customName: customName,
    );
  }

  /// Reorders all hosts to match [orderedIds].
  Future<void> reorderByIds(List<int> orderedIds) async {
    if (orderedIds.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await (_db.update(_db.hosts)
              ..where((h) => h.id.equals(orderedIds[index])))
            .write(HostsCompanion(sortOrder: Value(index)));
      }
    });
  }

  /// Duplicate an existing host and its port forwards.
  Future<int> duplicate(Host host) => _db.transaction(() async {
    final duplicateHostId = await insert(
      host
          .toCompanion(false)
          .copyWith(
            id: const Value.absent(),
            label: Value('${host.label} (copy)'),
            createdAt: const Value.absent(),
            updatedAt: const Value.absent(),
            lastConnectedAt: const Value(null),
            portProxyName: const Value(null),
            sortOrder: const Value.absent(),
          ),
    );

    final portForwards = await (_db.select(
      _db.portForwards,
    )..where((portForward) => portForward.hostId.equals(host.id))).get();

    for (final portForward in portForwards) {
      await _db
          .into(_db.portForwards)
          .insert(
            portForward
                .toCompanion(false)
                .copyWith(
                  id: const Value.absent(),
                  hostId: Value(duplicateHostId),
                  createdAt: const Value.absent(),
                ),
          );
    }

    return duplicateHostId;
  });

  /// Update an existing host.
  Future<bool> update(Host host) async {
    final generation = _decryptCache.generation;
    final previousStoredPassword = await _storedPasswordForHost(host.id);
    final preservesUnreadablePassword =
        _undecryptablePasswordHostIds.contains(host.id) &&
        (host.password == null || host.password!.isEmpty) &&
        previousStoredPassword != null;
    final encryptedPassword = preservesUnreadablePassword
        ? previousStoredPassword
        : await _secretEncryptionService.encryptNullable(host.password);
    final updated = await _db
        .update(_db.hosts)
        .replace(host.copyWith(password: Value(encryptedPassword)));
    if (updated && !preservesUnreadablePassword) {
      _undecryptablePasswordHostIds.remove(host.id);
      _decryptCache
        ..remove(previousStoredPassword)
        ..remember(encryptedPassword, host.password, generation, isWrite: true);
    }
    return updated;
  }

  /// Delete a host.
  Future<int> delete(int id) async {
    final host = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    if (host == null) {
      return 0;
    }
    final previousStoredPassword = host.password;
    final deleted = await _db.transaction(() async {
      await (_db.delete(
        _db.portForwards,
      )..where((portForward) => portForward.hostId.equals(id))).go();
      return (_db.delete(_db.hosts)..where((h) => h.id.equals(id))).go();
    });
    if (deleted > 0) {
      _decryptCache.remove(previousStoredPassword);
      _undecryptablePasswordHostIds.remove(id);
    }
    return deleted;
  }

  /// Applies a partial column update to a single host.
  ///
  /// Unlike [update], this never rewrites columns the caller did not set, so a
  /// stale in-memory [Host] snapshot cannot clobber fields changed elsewhere.
  /// The `password` column is always left untouched here; use [update] for
  /// credential changes so the secret is encrypted and cached correctly.
  Future<bool> updateFields(int id, HostsCompanion changes) async {
    final updatedRows =
        await (_db.update(_db.hosts)..where((h) => h.id.equals(id))).write(
          changes.copyWith(
            id: const Value.absent(),
            password: const Value.absent(),
          ),
        );
    return updatedRows > 0;
  }

  /// Enable or disable automatic forwarding of newly opened remote ports.
  Future<bool> setAutoForwardPorts(int id, {required bool enabled}) =>
      updateFields(id, HostsCompanion(autoForwardPorts: Value(enabled)));

  /// Update last connected timestamp.
  Future<bool> updateLastConnected(int id) =>
      updateFields(id, HostsCompanion(lastConnectedAt: Value(DateTime.now())));

  Future<List<Host>> _decryptHosts(List<Host> hosts) =>
      Future.wait(hosts.map(_decryptHost));

  Future<Host> _decryptHost(Host host) async {
    final storedPassword = host.password;
    if (storedPassword == null || storedPassword.isEmpty) {
      _undecryptablePasswordHostIds.remove(host.id);
      return host;
    }

    final decryptedPassword = await _cachedDecryptOrMigratePassword(
      host.id,
      storedPassword,
    );
    return host.copyWith(password: Value(decryptedPassword));
  }

  Future<String?> _cachedDecryptOrMigratePassword(
    int hostId,
    String storedPassword,
  ) async {
    final generation = _decryptCache.generation;
    final cached = _decryptCache.lookup(storedPassword);
    if (cached != null) {
      _undecryptablePasswordHostIds.remove(hostId);
      return cached;
    }
    // A damaged encrypted envelope is not a legacy plaintext password.
    if (_secretEncryptionService.isEncryptedValue(storedPassword)) {
      try {
        final decryptedPassword = await _decryptCache.decrypt(
          storedPassword,
          generation,
        );
        _undecryptablePasswordHostIds.remove(hostId);
        return decryptedPassword;
      } on FormatException catch (error) {
        // Keep the host usable without allowing metadata writes to erase the
        // ciphertext if secure storage loses its encryption key.
        if (_undecryptablePasswordHostIds.add(hostId)) {
          _diagnosticsLog.warning(
            'host.secrets',
            'password_decryption_failed',
            fields: {
              'hostId': hostId,
              'errorType': error.runtimeType.toString(),
            },
          );
        }
        return null;
      }
    }

    _undecryptablePasswordHostIds.remove(hostId);
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      storedPassword,
    );
    if (encryptedPassword != null && encryptedPassword != storedPassword) {
      await (_db.update(_db.hosts)..where(
            (h) => h.id.equals(hostId) & h.password.equals(storedPassword),
          ))
          .write(HostsCompanion(password: Value(encryptedPassword)));
      _decryptCache.remember(encryptedPassword, storedPassword, generation);
    }
    return storedPassword;
  }

  Future<String?> _storedPasswordForHost(int id) async {
    final row = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    return row?.password;
  }

  Future<HostsCompanion> _encryptHostCompanion(HostsCompanion host) async {
    if (!host.password.present || host.password.value == null) {
      return host;
    }
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      host.password.value,
    );
    return host.copyWith(password: Value(encryptedPassword));
  }

  SimpleSelectStatement<$HostsTable, Host> _orderedHostsQuery() =>
      _db.select(_db.hosts)..orderBy([
        (h) => OrderingTerm.asc(h.sortOrder),
        (h) => OrderingTerm.asc(h.id),
      ]);

  Future<int> _nextSortOrder() async {
    final expression = _db.hosts.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.hosts,
    )..addColumns([expression])).getSingleOrNull();
    return (row?.read(expression) ?? -1) + 1;
  }
}

/// Provider for [HostRepository].
final hostRepositoryProvider = Provider<HostRepository>((ref) {
  final repository = HostRepository(
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
