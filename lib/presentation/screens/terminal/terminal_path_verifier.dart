import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../../domain/services/diagnostics_log_service.dart';
import '../../../domain/services/remote_file_service.dart';
import '../../../domain/services/ssh_service.dart';
import 'terminal_screen_policy.dart';

const _maxVerifiedTerminalPathCacheEntries = 128;
const _terminalPathVerificationTimeout = Duration(seconds: 5);
const _terminalPathVerificationChannelBackoff = Duration(seconds: 10);
const _terminalPathVerificationBatchDelay = Duration(milliseconds: 50);
typedef _VerifiedTerminalPath = ({
  String terminalPath,
  String resolvedPath,
  bool exists,
});

/// Verifies terminal paths with bounded caches, serialized batches and backoff.
class TerminalPathVerifier {
  /// Callbacks supply the owning connection's current scope and lifecycle.
  TerminalPathVerifier({
    required this.currentScope,
    required this.workingDirectory,
    required SshSession? Function() activeSession,
    required bool Function() isMounted,
    required this.onCacheChanged,
    required void Function(String) showMessage,
    this.now = DateTime.now,
  }) : _activeSession = activeSession,
       _isMounted = isMounted,
       _showTerminalLinkMessage = showMessage;

  /// Reads the current host, connection and directory cache scope.
  final String Function() currentScope;

  /// Reads the current remote working directory.
  final String? Function() workingDirectory;
  final SshSession? Function() _activeSession;
  final bool Function() _isMounted;

  /// Refreshes path decoration after a background batch updates the cache.
  final void Function() onCacheChanged;
  final void Function(String) _showTerminalLinkMessage;

  /// Clock used to expire transport backoff.
  final DateTime Function() now;

  /// Whether the owning screen still accepts verification results.
  bool get mounted => _isMounted();

  /// Session that owns the cached SFTP transport.
  SshSession? get verificationSession => _terminalPathVerificationSession;

  /// Cancels the scheduled batch when the owner is disposed.
  void cancelPendingBatch() => _terminalPathVerificationBatchTimer?.cancel();
  final Map<String, _VerifiedTerminalPath> _verifiedTerminalPathCache =
      <String, _VerifiedTerminalPath>{};
  String? _activeTerminalPathVerificationKey;
  String? _terminalPathCacheScope;
  SshSession? _terminalPathVerificationSession;
  Future<SftpClient?>? _terminalPathVerificationSftpFuture;
  SftpClient? _terminalPathVerificationSftp;
  String? _terminalPathVerificationHomeDirectory;
  DateTime? _terminalPathVerificationBackoffUntil;
  final Map<String, String> _pendingTerminalPathVerifications = {};
  bool _isTerminalPathVerificationBatchScheduled = false;
  Timer? _terminalPathVerificationBatchTimer;
  String _terminalPathCacheKey(String terminalPath) =>
      '${_currentTerminalPathCacheScope()}:$terminalPath';

  String _currentTerminalPathCacheScope() => currentScope();

  /// Drops cached and queued paths when the directory or connection changes.
  void syncVerifiedTerminalPathCacheScope() {
    final nextScope = _currentTerminalPathCacheScope();
    if (_terminalPathCacheScope == nextScope) {
      return;
    }
    _terminalPathCacheScope = nextScope;
    resetVerifiedTerminalPathCache();
  }

  /// Clears both positive and negative verification results and queued paths.
  void resetVerifiedTerminalPathCache() {
    _verifiedTerminalPathCache.clear();
    _activeTerminalPathVerificationKey = null;
    _pendingTerminalPathVerifications.clear();
  }

  void _cacheVerifiedTerminalPath(
    String cacheKey, {
    required String terminalPath,
    required String resolvedPath,
  }) => _storeVerifiedTerminalPath(cacheKey, (
    terminalPath: terminalPath,
    resolvedPath: resolvedPath,
    exists: true,
  ));

  /// Remembers that no substring of the path at [cacheKey] exists remotely, so
  /// the link is dropped and the dead path is not repeatedly re-probed.
  void _cacheNonexistentTerminalPath(
    String cacheKey, {
    required String terminalPath,
  }) => _storeVerifiedTerminalPath(cacheKey, (
    terminalPath: terminalPath,
    resolvedPath: '',
    exists: false,
  ));

  void _storeVerifiedTerminalPath(
    String cacheKey,
    _VerifiedTerminalPath verifiedPath,
  ) {
    _verifiedTerminalPathCache.remove(cacheKey);
    _verifiedTerminalPathCache[cacheKey] = verifiedPath;
    while (_verifiedTerminalPathCache.length >
        _maxVerifiedTerminalPathCacheEntries) {
      _verifiedTerminalPathCache.remove(_verifiedTerminalPathCache.keys.first);
    }
  }

  /// Forgets the transport, home directory, backoff and pending paths.
  void disposeTerminalPathVerificationSftp() {
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationSftpFuture = null;
    _terminalPathVerificationSession = null;
    _terminalPathVerificationHomeDirectory = null;
    _terminalPathVerificationBackoffUntil = null;
    _pendingTerminalPathVerifications.clear();
    _activeTerminalPathVerificationKey = null;
  }

  Future<SftpClient> _openTerminalPathVerificationSftp(
    SshSession session,
  ) async {
    final sftpOpenFuture = session.sftp();
    try {
      return await sftpOpenFuture.timeout(_terminalPathVerificationTimeout);
    } on TimeoutException {
      session.discardSftpOpen(sftpOpenFuture);
      rethrow;
    }
  }

  Future<SftpClient?> _resolveTerminalPathVerificationSftp(
    SshSession session, {
    required bool allowBackoff,
  }) async {
    if (!identical(_terminalPathVerificationSession, session)) {
      if (_terminalPathVerificationSession != null) {
        disposeTerminalPathVerificationSftp();
      }
      _terminalPathVerificationSession = session;
    }

    final cachedSftp = _terminalPathVerificationSftp;
    if (cachedSftp != null) {
      return cachedSftp;
    }

    final inFlight = _terminalPathVerificationSftpFuture;
    if (inFlight != null) {
      return inFlight;
    }

    if (allowBackoff && _isTerminalPathVerificationBackedOff()) {
      DiagnosticsLogService.instance.debug(
        'terminal',
        'sftp_path_resolution_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return null;
    }

    final future = _openTerminalPathVerificationSftp(session)
        .then<SftpClient?>((sftp) {
          if (!identical(_terminalPathVerificationSession, session)) {
            return null;
          }
          _terminalPathVerificationBackoffUntil = null;
          _terminalPathVerificationSftp = sftp;
          return sftp;
        });
    _terminalPathVerificationSftpFuture = future;
    try {
      return await future;
    } on Object catch (error) {
      _recordTerminalPathVerificationBackoff(session, error);
      rethrow;
    } finally {
      if (identical(_terminalPathVerificationSftpFuture, future)) {
        _terminalPathVerificationSftpFuture = null;
      }
    }
  }

  bool _isTerminalPathVerificationBackedOff() =>
      _terminalPathVerificationBackoffRemaining() != null;

  Duration? _terminalPathVerificationBackoffRemaining() {
    final backoffUntil = _terminalPathVerificationBackoffUntil;
    if (backoffUntil == null) {
      return null;
    }
    final remaining = backoffUntil.difference(now());
    if (remaining > Duration.zero) {
      return remaining;
    }
    _terminalPathVerificationBackoffUntil = null;
    return null;
  }

  void _recordTerminalPathVerificationBackoff(
    SshSession session,
    Object error,
  ) {
    if (!_isRecoverableTerminalPathVerificationSftpError(error)) {
      return;
    }
    _terminalPathVerificationBackoffUntil = now().add(
      _terminalPathVerificationChannelBackoff,
    );
    DiagnosticsLogService.instance.debug(
      'terminal',
      'sftp_path_resolution_backoff',
      fields: {
        'connectionId': session.connectionId,
        'delayMs': _terminalPathVerificationChannelBackoff.inMilliseconds,
        'errorType': error.runtimeType.toString(),
      },
    );
  }

  bool _isRecoverableTerminalPathVerificationSftpError(Object error) =>
      error is TimeoutException ||
      error is SSHError ||
      error is SftpError && error is! SftpStatusError;

  void _handleTerminalPathVerificationSftpFailure(
    SftpClient sftp,
    Object error,
  ) {
    if (!_isRecoverableTerminalPathVerificationSftpError(error)) {
      return;
    }
    final session = _terminalPathVerificationSession;
    if (session != null) {
      _recordTerminalPathVerificationBackoff(session, error);
    }
    if (!identical(_terminalPathVerificationSftp, sftp)) {
      return;
    }
    DiagnosticsLogService.instance.debug(
      'terminal',
      'sftp_path_resolution_client_discarded',
      fields: {
        if (session != null) 'connectionId': session.connectionId,
        'errorType': error.runtimeType.toString(),
      },
    );
    session?.discardSftpClient(sftp);
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationHomeDirectory = null;
  }

  Future<String?> _resolveTerminalPathVerificationHomeDirectory(
    SftpClient sftp,
    String terminalPath,
    String scope,
  ) async {
    if (terminalPath != '~' && !terminalPath.startsWith('~/')) {
      return null;
    }
    final cachedHomeDirectory = _terminalPathVerificationHomeDirectory;
    if (cachedHomeDirectory != null) {
      return cachedHomeDirectory;
    }

    final homeDirectory = normalizeSftpAbsolutePath(
      await _resolveTerminalPathVerificationSftpOperation(
        sftp,
        () => sftp.absolute('.'),
        scope: scope,
      ),
    );
    if (!mounted ||
        scope != _currentTerminalPathCacheScope() ||
        !identical(sftp, _terminalPathVerificationSftp) ||
        !identical(_activeSession(), _terminalPathVerificationSession)) {
      return null;
    }
    _terminalPathVerificationHomeDirectory = homeDirectory;
    return homeDirectory;
  }

  Future<T> _resolveTerminalPathVerificationSftpOperation<T>(
    SftpClient sftp,
    Future<T> Function() operation, {
    required String scope,
  }) async {
    try {
      return await operation().timeout(_terminalPathVerificationTimeout);
    } on Object catch (error) {
      if (mounted &&
          scope == _currentTerminalPathCacheScope() &&
          identical(_activeSession(), _terminalPathVerificationSession) &&
          identical(sftp, _terminalPathVerificationSftp)) {
        _handleTerminalPathVerificationSftpFailure(sftp, error);
      }
      rethrow;
    }
  }

  _VerifiedTerminalPath? _verifiedTerminalPath(String terminalPath) {
    syncVerifiedTerminalPathCacheScope();
    return _verifiedTerminalPathCache[_terminalPathCacheKey(terminalPath)];
  }

  /// Returns the verified substring, or an optimistic explicit path.
  String? interactiveTerminalFilePathCandidate(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      // Verification has resolved: link the longest existing substring, or
      // nothing if no substring of the path exists remotely.
      return verifiedPath.exists ? verifiedPath.terminalPath : null;
    }
    // Verification is still pending: optimistically link explicit paths so the
    // link appears immediately, then it shrinks (or drops) once `stat` lands.
    return _isOptimisticTerminalFilePath(terminalPath) ? terminalPath : null;
  }

  /// Whether this path currently has an optimistic or verified link target.
  bool isInteractiveTerminalFilePath(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      return verifiedPath.exists;
    }
    return _isOptimisticTerminalFilePath(terminalPath);
  }

  /// Whether a not-yet-verified path should behave like a link in the meantime.
  bool _isOptimisticTerminalFilePath(String terminalPath) =>
      shouldActivateTerminalFilePath(terminalPath, hasVerifiedPath: false);

  /// Queues a supported path once, retaining at most 128 pending candidates.
  void primeTerminalFilePathVerification(String terminalPath) {
    if (!isSupportedTerminalFilePath(terminalPath)) {
      return;
    }

    syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    if (_verifiedTerminalPathCache.containsKey(cacheKey) ||
        _activeTerminalPathVerificationKey == cacheKey ||
        _pendingTerminalPathVerifications.containsKey(cacheKey)) {
      return;
    }

    _enqueueTerminalPathVerification(cacheKey, terminalPath);
    _scheduleTerminalPathVerificationBatch();
  }

  void _enqueueTerminalPathVerification(String cacheKey, String terminalPath) {
    _pendingTerminalPathVerifications[cacheKey] = terminalPath;
    while (_pendingTerminalPathVerifications.length >
        _maxVerifiedTerminalPathCacheEntries) {
      _pendingTerminalPathVerifications.remove(
        _pendingTerminalPathVerifications.keys.first,
      );
    }
  }

  void _scheduleTerminalPathVerificationBatch([
    Duration delay = _terminalPathVerificationBatchDelay,
  ]) {
    if (_isTerminalPathVerificationBatchScheduled) {
      return;
    }
    _isTerminalPathVerificationBatchScheduled = true;
    // Use a cancelable timer (not Future.delayed) so the pending batch is torn
    // down in dispose() rather than lingering until it fires.
    _terminalPathVerificationBatchTimer = Timer(delay, () async {
      _terminalPathVerificationBatchTimer = null;
      Duration? nextDelay;
      try {
        if (!mounted) {
          _pendingTerminalPathVerifications.clear();
          _activeTerminalPathVerificationKey = null;
          return;
        }
        nextDelay = await _verifyPendingTerminalFilePaths();
      } finally {
        _isTerminalPathVerificationBatchScheduled = false;
        if (mounted && _pendingTerminalPathVerifications.isNotEmpty) {
          _scheduleTerminalPathVerificationBatch(
            nextDelay ?? _terminalPathVerificationBatchDelay,
          );
        }
      }
    });
  }

  Future<Duration?> _verifyPendingTerminalFilePaths() async {
    syncVerifiedTerminalPathCacheScope();
    if (_pendingTerminalPathVerifications.isEmpty) {
      return null;
    }

    final backoffRemaining = _terminalPathVerificationBackoffRemaining();
    if (backoffRemaining != null) {
      DiagnosticsLogService.instance.debug(
        'terminal',
        'sftp_path_resolution_batch_deferred',
        fields: {'pendingCount': _pendingTerminalPathVerifications.length},
      );
      return backoffRemaining;
    }

    final session = _activeSession();
    if (session == null) {
      _pendingTerminalPathVerifications.clear();
      _activeTerminalPathVerificationKey = null;
      return null;
    }

    final scope = _currentTerminalPathCacheScope();
    final workingDirectory = this.workingDirectory();
    bool ownsScope() =>
        mounted &&
        scope == _currentTerminalPathCacheScope() &&
        identical(session, _activeSession());
    var cacheChanged = false;
    try {
      final sftp = await _resolveTerminalPathVerificationSftp(
        session,
        allowBackoff: true,
      );
      if (sftp == null || !ownsScope()) {
        return null;
      }

      while (_pendingTerminalPathVerifications.isNotEmpty) {
        if (!ownsScope()) return null;
        final entry = _pendingTerminalPathVerifications.entries.first;
        _pendingTerminalPathVerifications.remove(entry.key);
        _activeTerminalPathVerificationKey = entry.key;
        if (_verifiedTerminalPathCache.containsKey(entry.key)) {
          continue;
        }
        try {
          await _resolveVerifiedTerminalFilePathWithSftp(
            sftp,
            entry.value,
            showErrors: false,
            scope: scope,
            workingDirectory: workingDirectory,
          );
          // A positive or negative result was cached: refresh underlines so an
          // optimistic link shrinks to (or drops below) the verified extent.
          cacheChanged = true;
        } on TimeoutException {
          rethrow;
        } on SftpStatusError {
          // Background path verification is opportunistic.
        } on SSHError {
          rethrow;
        } on SftpError {
          rethrow;
        } on Object catch (error, stackTrace) {
          DiagnosticsLogService.instance.warning(
            'terminal',
            'sftp_path_resolution_failed',
            fields: {'errorType': error.runtimeType.toString()},
          );
          if (kDebugMode) {
            debugPrint('Failed to resolve terminal file path: $error');
            debugPrint('$stackTrace');
          }
        }
      }
    } on Object catch (error, stackTrace) {
      if (!ownsScope()) return null;
      // Background verification is opportunistic. Abandon this batch on a
      // client failure instead of retrying it indefinitely while output is
      // idle. New output can enqueue these paths again, respecting channel
      // backoff; failures must not be cached as nonexistent paths.
      _pendingTerminalPathVerifications.clear();
      if (_isTerminalPathVerificationBackedOff()) {
        return null;
      }
      DiagnosticsLogService.instance.warning(
        'terminal',
        'sftp_path_resolution_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      if (kDebugMode) {
        debugPrint('Failed to resolve terminal file paths: $error');
        debugPrint('$stackTrace');
      }
    } finally {
      _activeTerminalPathVerificationKey = null;
    }

    if (cacheChanged && ownsScope()) {
      onCacheChanged();
    }
    return null;
  }

  Future<String?> _resolveVerifiedTerminalFilePathWithSftp(
    SftpClient sftp,
    String terminalPath, {
    required bool showErrors,
    required String scope,
    required String? workingDirectory,
  }) async {
    bool ownsScope() =>
        mounted &&
        scope == _currentTerminalPathCacheScope() &&
        identical(sftp, _terminalPathVerificationSftp) &&
        identical(_activeSession(), _terminalPathVerificationSession);
    if (!ownsScope()) return null;
    final cacheKey = '$scope:$terminalPath';
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.exists ? cachedPath.resolvedPath : null;
    }

    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    // Probe from the full path down through its directory prefixes so the
    // longest substring that actually exists wins (candidates are ordered
    // longest first).
    final verificationCandidates = resolveTerminalFilePathExistenceCandidates(
      terminalPath,
    );
    for (final candidate in verificationCandidates) {
      final homeDirectory = await _resolveTerminalPathVerificationHomeDirectory(
        sftp,
        candidate,
        scope,
      );
      if (!ownsScope()) return null;
      final resolvedPath = resolveRequestedSftpPath(
        candidate,
        workingDirectory: workingDirectory,
        homeDirectory: homeDirectory,
      );
      if (resolvedPath == null) {
        continue;
      }

      try {
        await _resolveTerminalPathVerificationSftpOperation(
          sftp,
          () => sftp.stat(resolvedPath),
          scope: scope,
        );
      } on SftpStatusError catch (error) {
        if (!ownsScope()) return null;
        if (error.code == SftpStatusCode.noSuchFile) {
          continue;
        }
        rethrow;
      }

      if (!ownsScope()) return null;
      _cacheVerifiedTerminalPath(
        cacheKey,
        terminalPath: candidate,
        resolvedPath: resolvedPath,
      );
      return resolvedPath;
    }

    if (!ownsScope()) return null;
    _cacheNonexistentTerminalPath(cacheKey, terminalPath: terminalPath);
    if (showErrors && isExplicitPath) {
      _showTerminalLinkMessage(
        'Could not open "$terminalPath" in SFTP: path does not exist',
      );
    }
    return null;
  }

  /// Resolves a tapped path immediately, bypassing background channel backoff.
  Future<String?> resolveVerifiedTerminalFilePath(String terminalPath) async {
    syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.exists ? cachedPath.resolvedPath : null;
    }

    final scope = _currentTerminalPathCacheScope();
    final workingDirectory = this.workingDirectory();
    final session = _activeSession();
    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    if (session == null) {
      if (isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }

    try {
      final sftp = await _resolveTerminalPathVerificationSftp(
        session,
        allowBackoff: false,
      );
      if (sftp == null) {
        return null;
      }
      return await _resolveVerifiedTerminalFilePathWithSftp(
        sftp,
        terminalPath,
        showErrors: true,
        scope: scope,
        workingDirectory: workingDirectory,
      );
    } on TimeoutException {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      if (isExplicitPath) {
        _showTerminalLinkMessage('Timed out opening "$terminalPath" in SFTP');
      }
      return null;
    } on SftpStatusError catch (error) {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      if (isExplicitPath) {
        final message = error.code == SftpStatusCode.noSuchFile
            ? 'Could not open "$terminalPath" in SFTP: path does not exist'
            : 'Could not open "$terminalPath" in SFTP';
        _showTerminalLinkMessage(message);
      }
      return null;
    } on Object catch (error, stackTrace) {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      DiagnosticsLogService.instance.warning(
        'terminal',
        'sftp_path_resolution_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (kDebugMode) {
        debugPrint(
          'Failed to resolve terminal file path "$terminalPath": $error',
        );
        debugPrint('$stackTrace');
      }
      if (isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }
  }
}
