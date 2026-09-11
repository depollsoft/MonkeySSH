/// Tracks the SFTP client used by the agent chat for remote uploads and
/// resource reads, keyed by the SSH connection that owns it.
///
/// When the host reconnects under a new `connectionId`, the previously cached
/// client belongs to a dead connection and must never be reused. This cache
/// discards the stale reference and reopens against the live connection before
/// any upload or read.
library;

import 'package:dartssh2/dartssh2.dart';

/// Borrows the SSH session-owned SFTP client for the current connection.
///
/// `SshSession.sftp` caches and closes this shared channel. Callers here must
/// never close a displaced result because the browser and capability service
/// may be using the same instance.
typedef AcpSftpClientOpener = Future<SftpClient> Function();

/// Connection-aware reference cache for a single host's shared SFTP client.
///
/// This object never owns the channel. Invalidation only drops a borrowed
/// reference; the corresponding SSH session owns channel disposal.
class AcpSftpClientCache {
  SftpClient? _client;
  int? _connectionId;
  Future<SftpClient?>? _opening;
  int? _openingConnectionId;

  // Monotonic id of the latest open request. Each newly started open captures
  // the value bumped here; only the request whose generation still matches
  // [_generation] when it completes may populate the cache. This guards
  // against an older, slower open (e.g. connection A) resolving *after* a newer
  // one (connection B) and overwriting the cache with a stale client.
  int _generation = 0;

  /// The connectionId that currently owns the cached client, if any.
  int? get connectionId => _connectionId;

  /// Returns the cached client only when it is owned by [connectionId];
  /// otherwise returns `null` (the caller should [ensure] a fresh one).
  SftpClient? clientForConnection(int? connectionId) {
    if (_client == null || connectionId == null) {
      return null;
    }
    return connectionId == _connectionId ? _client : null;
  }

  /// Drops cached and in-flight clients not owned by [connectionId].
  void invalidateIfStale(int? connectionId) {
    if (_opening != null && _openingConnectionId != connectionId) {
      _generation++;
      _opening = null;
      _openingConnectionId = null;
    }
    if (connectionId != _connectionId) {
      _client = null;
      _connectionId = null;
    }
  }

  /// Returns a client owned by [connectionId], reusing the cached one when it
  /// matches and otherwise opening a fresh client via [open].
  ///
  /// Concurrent calls for the same connection share one in-flight open. A
  /// `null` [connectionId] (no live SSH session) clears the cache and resolves
  /// to `null`. If a newer open (for a different connection) supersedes this
  /// one before it completes, this call resolves to `null` and never replaces
  /// the current cache.
  Future<SftpClient?> ensure({
    required int? connectionId,
    required AcpSftpClientOpener open,
  }) async {
    if (connectionId == null) {
      invalidateIfStale(null);
      return null;
    }
    if (_client != null && _connectionId == connectionId) {
      return _client;
    }
    // The cached client (if any) belongs to a stale connection.
    _client = null;
    _connectionId = null;
    final pending = _opening;
    if (pending != null && _openingConnectionId == connectionId) {
      return pending;
    }
    final generation = ++_generation;
    final future = _open(connectionId, generation, open);
    _opening = future;
    _openingConnectionId = connectionId;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) {
        _opening = null;
        _openingConnectionId = null;
      }
    }
  }

  Future<SftpClient?> _open(
    int connectionId,
    int generation,
    AcpSftpClientOpener open,
  ) async {
    try {
      final client = await open();
      // A newer request superseded this borrowed session-owned client. Do not
      // cache it and do not close it: other SSH-session consumers may share it.
      if (generation != _generation) {
        return null;
      }
      _client = client;
      _connectionId = connectionId;
      return client;
    } on Object {
      return null;
    }
  }
}
