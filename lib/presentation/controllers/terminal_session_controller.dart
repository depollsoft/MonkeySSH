import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_wake_lock_service.dart';

/// Coordinates non-visual terminal session state for [TerminalScreen].
///
/// This is a compatibility seam: terminal I/O and rendering stay in the screen
/// while session observation, target-session resolution, clipboard setting
/// application, and wake-lock ownership move behind a small controller API.
class TerminalSessionController {
  /// Creates a controller for one terminal screen instance.
  TerminalSessionController({
    required TerminalWakeLockService wakeLockService,
    required int wakeLockOwnerId,
    required SshConnectionState Function() readCurrentConnectionState,
    required SshSession? Function(int connectionId) getSession,
    required int? Function() connectionId,
    required bool Function() hasActiveShell,
    required bool Function() hasError,
    required bool Function() isBackgrounded,
    required VoidCallback onSessionMetadataChanged,
    Duration sessionMetadataDebounce = const Duration(milliseconds: 75),
  }) : _wakeLockService = wakeLockService,
       _wakeLockOwnerId = wakeLockOwnerId,
       _readCurrentConnectionState = readCurrentConnectionState,
       _getSession = getSession,
       _connectionId = connectionId,
       _hasActiveShell = hasActiveShell,
       _hasError = hasError,
       _isBackgrounded = isBackgrounded,
       _onSessionMetadataChanged = onSessionMetadataChanged,
       _sessionMetadataDebounce = sessionMetadataDebounce;

  final TerminalWakeLockService _wakeLockService;
  final int _wakeLockOwnerId;
  final SshConnectionState Function() _readCurrentConnectionState;
  final SshSession? Function(int connectionId) _getSession;
  final int? Function() _connectionId;
  final bool Function() _hasActiveShell;
  final bool Function() _hasError;
  final bool Function() _isBackgrounded;
  final VoidCallback _onSessionMetadataChanged;
  final Duration _sessionMetadataDebounce;

  SshSession? _observedSession;
  Timer? _sessionMetadataDebounceTimer;
  bool _hasPendingSessionMetadataChange = false;

  /// Whether the user setting allows the terminal to hold a wake lock.
  bool wakeLockEnabled = false;

  /// The SSH session currently driving terminal metadata in the UI.
  SshSession? get observedSession => _observedSession;

  /// Starts observing metadata for [session].
  ///
  /// Returns `true` when the observed session changed.
  bool observeSessionMetadata(SshSession session) {
    if (identical(_observedSession, session)) {
      return false;
    }

    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _sessionMetadataDebounceTimer?.cancel();
    _sessionMetadataDebounceTimer = null;
    _hasPendingSessionMetadataChange = false;
    _observedSession = session
      ..removeMetadataListener(_handleSessionMetadataChanged)
      ..addMetadataListener(_handleSessionMetadataChanged);
    return true;
  }

  void _handleSessionMetadataChanged() {
    if (_sessionMetadataDebounce == Duration.zero) {
      _onSessionMetadataChanged();
      return;
    }
    _hasPendingSessionMetadataChange = true;
    if (_sessionMetadataDebounceTimer?.isActive ?? false) {
      return;
    }
    _sessionMetadataDebounceTimer = Timer(_sessionMetadataDebounce, () {
      _sessionMetadataDebounceTimer = null;
      if (!_hasPendingSessionMetadataChange) {
        return;
      }
      _hasPendingSessionMetadataChange = false;
      _onSessionMetadataChanged();
    });
  }

  /// Returns whether [session] is the currently observed session.
  bool isObservingSession(SshSession session) =>
      identical(_observedSession, session);

  /// Stops observing terminal metadata for the current session.
  void clearObservedSession({SshSession? session}) {
    final observedSession = _observedSession;
    if (observedSession == null ||
        (session != null && !identical(observedSession, session))) {
      return;
    }

    observedSession.removeMetadataListener(_handleSessionMetadataChanged);
    _sessionMetadataDebounceTimer?.cancel();
    _sessionMetadataDebounceTimer = null;
    _hasPendingSessionMetadataChange = false;
    _observedSession = null;
  }

  /// Resolves the session that should receive a coordinated terminal setting.
  SshSession? resolveTargetSession({SshSession? session}) {
    final connectionId = _connectionId();
    return session ??
        _observedSession ??
        (connectionId == null ? null : _getSession(connectionId));
  }

  /// Applies shared clipboard flags and starts or stops the sync loop.
  Future<void> applySharedClipboardSetting({
    required bool enabled,
    required bool allowLocalClipboardRead,
    required Future<void> Function(SshSession session) startSync,
    required VoidCallback stopSync,
    SshSession? session,
    bool waitForInitialSync = true,
  }) async {
    final targetSession = resolveTargetSession(session: session);
    if (targetSession == null) {
      return;
    }

    targetSession
      ..clipboardSharingEnabled = enabled
      ..localClipboardReadEnabled = enabled && allowLocalClipboardRead;
    if (!enabled) {
      stopSync();
      return;
    }

    if (waitForInitialSync) {
      await startSync(targetSession);
      return;
    }

    unawaited(startSync(targetSession));
  }

  /// Selects the active connection state from [states].
  SshConnectionState selectTrackedConnectionState(
    Map<int, SshConnectionState> states,
  ) {
    final connectionId = _connectionId();
    if (connectionId == null) {
      return SshConnectionState.disconnected;
    }
    if (_getSession(connectionId) == null) {
      return SshConnectionState.disconnected;
    }
    return states[connectionId] ?? SshConnectionState.disconnected;
  }

  /// Synchronizes wake-lock ownership with the current terminal state.
  void syncWakeLock([SshConnectionState? connectionState]) {
    final connectionId = _connectionId();
    final shouldHold =
        wakeLockEnabled &&
        !_isBackgrounded() &&
        connectionId != null &&
        _hasActiveShell() &&
        !_hasError() &&
        (connectionState ?? _readCurrentConnectionState()) ==
            SshConnectionState.connected;
    unawaited(
      _wakeLockService.setOwnerActive(_wakeLockOwnerId, active: shouldHold),
    );
  }

  /// Releases session listeners and wake-lock ownership.
  void dispose() {
    _sessionMetadataDebounceTimer?.cancel();
    _sessionMetadataDebounceTimer = null;
    _hasPendingSessionMetadataChange = false;
    _observedSession?.removeMetadataListener(_handleSessionMetadataChanged);
    _observedSession = null;
    unawaited(_wakeLockService.releaseOwner(_wakeLockOwnerId));
  }
}
