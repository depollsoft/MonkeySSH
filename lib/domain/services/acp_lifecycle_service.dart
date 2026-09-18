import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_provider.dart';
import '../models/acp_session_keys.dart';
import '../models/acp_session_state.dart';
import 'acp_session_manager.dart';
import 'auth_service.dart';
import 'diagnostics_log_service.dart';
import 'local_notification_service.dart';
import 'ssh_service.dart';

/// Generic, privacy-safe display label used for any provider whose real
/// label cannot be shown safely (every custom/user-defined provider, and any
/// provider id this coordinator does not recognize).
const acpGenericAgentLabel = 'Coding agent';

/// Resolves a safe, allowlisted display label for [session].
///
/// Built-in providers (Copilot CLI, OpenCode, Pi) use their fixed, known-safe
/// label. Every custom provider's user-chosen label is never used here: it
/// is arbitrary, user-controlled text that must never appear in an OS
/// notification (visible on a lock screen, in notification history, and to
/// any other app that can read notifications).
String acpSafeAgentDisplayLabel(AcpSessionState session) {
  if (!session.isCustomProvider) {
    final builtin = acpBuiltinProviders.firstWhereOrNull(
      (provider) => provider.id == session.key.providerId,
    );
    if (builtin != null) return builtin.label;
  }
  return acpGenericAgentLabel;
}

/// Coordinates ACP session behavior with app foreground/background state,
/// auth lock, and SSH host disconnects.
///
/// This never talks to a remote bridge directly. Healthy attachments remain
/// live in the background; only auth lock or loss of the host's SSH path asks
/// [AcpSessionManager.detachSession] for an idempotent local detach.
///
/// No push notification is ever possible while the phone has no network path
/// to the SSH host: local notifications here are best-effort, in-app-only
/// signals shown while this process is still running in the background.
class AcpLifecycleService {
  /// Creates an ACP lifecycle coordinator.
  AcpLifecycleService({
    required AcpSessionManager sessionManager,
    required bool Function(int hostId) hasActiveSshSession,
    required LocalNotificationService notificationService,
    DiagnosticsLogger? diagnostics,
  }) : _sessionManager = sessionManager,
       _hasActiveSshSession = hasActiveSshSession,
       _notificationService = notificationService,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final AcpSessionManager _sessionManager;
  final bool Function(int hostId) _hasActiveSshSession;
  final LocalNotificationService _notificationService;

  final DiagnosticsLogger _diagnostics;

  StreamSubscription<AcpSessionManagerState>? _stateSubscription;
  bool _isForeground = true;
  bool _started = false;
  bool _disposed = false;

  // Lightweight transition state only; never retain timeline/content snapshots.
  final Map<String, _AcpNotificationSnapshot> _lastKnownStates =
      <String, _AcpNotificationSnapshot>{};

  /// Starts observing session-manager state for notification gating.
  ///
  /// Safe to call more than once; only the first call attaches a listener.
  void start() {
    if (_started) return;
    _started = true;
    _stateSubscription = _sessionManager.states.listen(_onManagerStateChanged);
  }

  /// Releases this coordinator's state subscription.
  ///
  /// Never touches remote bridges or healthy local attachments.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
  }

  /// Call when the app returns to the foreground. Healthy attachments remain
  /// live across ordinary app backgrounding, so this never performs a bulk
  /// reconnect sweep.
  Future<void> handleForeground() async {
    _isForeground = true;
  }

  /// Call when the app enters the background.
  ///
  /// Keep healthy ACP attachments alive so running agents can complete, request
  /// permission, and notify the user without paying a multi-session reconnect
  /// and history-load cost on every app switch. Auth lock, SSH disconnect,
  /// explicit detach/close, and terminal transport failure remain teardown
  /// boundaries.
  Future<void> handleBackground() async {
    _isForeground = false;
  }

  /// Call when the app locks (auto-lock or explicit lock).
  ///
  /// Detaches every live session locally without touching remote bridges, so
  /// a locked app never keeps a live client attached to a session the user
  /// can no longer see. Foreground lifecycle events never auto-reconnect an
  /// auth-detached session; the user must unlock and open it explicitly.
  Future<void> handleAuthLocked() async {
    final live = _sessionManager.state.sessions
        .where((session) => session.isLive)
        .toList(growable: false);
    for (final session in live) {
      await _detachSafely(session.key, reason: 'auth_locked');
    }
  }

  /// Call whenever the set of currently connected SSH hosts may have
  /// changed (for example after [SshService] active-session changes).
  ///
  /// Detaches every live ACP session whose host no longer has an active SSH
  /// session, isolating each host's cleanup from every other host's.
  Future<void> handleSshConnectivityChanged() async {
    final live = _sessionManager.state.sessions
        .where((session) => session.isLive)
        .toList(growable: false);
    for (final session in live) {
      if (_hasActiveSshSession(session.key.hostId)) {
        continue;
      }
      await _detachSafely(session.key, reason: 'ssh_disconnected');
    }
  }

  Future<bool> _detachSafely(
    AcpSessionKey key, {
    required String reason,
  }) async {
    try {
      await _sessionManager.detachSession(key);
      _diagnostics.info(
        'acp.lifecycle',
        'auto_detached',
        fields: {'hostId': key.hostId, 'reason': reason},
      );
      return true;
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.lifecycle',
        'auto_detach_failed',
        fields: {
          'hostId': key.hostId,
          'reason': reason,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  void _onManagerStateChanged(AcpSessionManagerState state) {
    final currentKeyValues = <String>{};
    for (final session in state.sessions) {
      currentKeyValues.add(session.key.value);
      final previous = _lastKnownStates[session.key.value];
      _maybeNotifyNewPermission(session, previous);
      _maybeNotifyNewWrite(session, previous);
      _maybeNotifyCompletion(session, previous);
      _lastKnownStates[session.key.value] =
          _AcpNotificationSnapshot.fromSession(session);
    }
    _lastKnownStates.removeWhere(
      (keyValue, _) => !currentKeyValues.contains(keyValue),
    );
  }

  void _maybeNotifyNewPermission(
    AcpSessionState session,
    _AcpNotificationSnapshot? previous,
  ) {
    final previousCount = previous?.pendingPermissionCount ?? 0;
    if (session.pendingPermissions.length <= previousCount) return;
    if (!_canNotify(session.key.hostId)) return;
    final payload = _payload(session, AcpNotificationKind.permission);
    unawaited(
      _notificationService.showAcpNotification(
        notificationId: acpNotificationIdFor(payload),
        title: '${acpSafeAgentDisplayLabel(session)} needs your permission',
        body: 'Open the app to review and respond.',
        payload: payload,
      ),
    );
  }

  void _maybeNotifyNewWrite(
    AcpSessionState session,
    _AcpNotificationSnapshot? previous,
  ) {
    final previousCount = previous?.pendingWriteCount ?? 0;
    if (session.pendingWrites.length <= previousCount) return;
    if (!_canNotify(session.key.hostId)) return;
    final payload = _payload(session, AcpNotificationKind.writeApproval);
    unawaited(
      _notificationService.showAcpNotification(
        notificationId: acpNotificationIdFor(payload),
        title: '${acpSafeAgentDisplayLabel(session)} needs write approval',
        body: 'Open the app to review and respond.',
        payload: payload,
      ),
    );
  }

  void _maybeNotifyCompletion(
    AcpSessionState session,
    _AcpNotificationSnapshot? previous,
  ) {
    final wasStreaming = switch (previous?.promptStatus) {
      AcpPromptStatus.sending || AcpPromptStatus.streaming => true,
      _ => false,
    };
    if (!wasStreaming) return;
    if (session.promptStatus != AcpPromptStatus.idle) return;
    if (session.lastStopReason == null) return;
    if (!_canNotify(session.key.hostId)) return;
    final payload = _payload(session, AcpNotificationKind.completion);
    unawaited(
      _notificationService.showAcpNotification(
        notificationId: acpNotificationIdFor(payload),
        title: '${acpSafeAgentDisplayLabel(session)} finished',
        body: 'Open the app to see the result.',
        payload: payload,
      ),
    );
  }

  /// A local notification is only ever safe/useful while the app is
  /// backgrounded (so the user wouldn't otherwise see it) and there is a live
  /// SSH path to the host (so the state that triggered it is not already
  /// stale). There is no push path when disconnected, so this coordinator
  /// never attempts to notify in that case.
  bool _canNotify(int hostId) {
    if (_isForeground) return false;
    return _hasActiveSshSession(hostId);
  }

  AcpNotificationPayload _payload(
    AcpSessionState session,
    AcpNotificationKind kind,
  ) => AcpNotificationPayload(
    kind: kind,
    hostId: session.key.hostId,
    providerId: session.key.providerId,
    bridgeId: session.key.bridgeId,
    acpSessionId: session.key.acpSessionId,
  );
}

final class _AcpNotificationSnapshot {
  const _AcpNotificationSnapshot({
    required this.pendingPermissionCount,
    required this.pendingWriteCount,
    required this.promptStatus,
  });

  factory _AcpNotificationSnapshot.fromSession(AcpSessionState session) =>
      _AcpNotificationSnapshot(
        pendingPermissionCount: session.pendingPermissions.length,
        pendingWriteCount: session.pendingWrites.length,
        promptStatus: session.promptStatus,
      );

  final int pendingPermissionCount;
  final int pendingWriteCount;
  final AcpPromptStatus promptStatus;
}

/// Provider for [AcpLifecycleService].
final acpLifecycleServiceProvider = Provider<AcpLifecycleService>((ref) {
  final sshService = ref.watch(sshServiceProvider);
  final service = AcpLifecycleService(
    sessionManager: ref.watch(acpSessionManagerProvider),
    hasActiveSshSession: (hostId) =>
        sshService.getSessionsForHost(hostId).isNotEmpty,
    notificationService: ref.watch(localNotificationServiceProvider),
  )..start();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Reacts to SSH active-session changes by detaching any ACP session whose
/// host lost its last active SSH session.
///
/// Kept as its own provider (rather than inline in
/// [acpLifecycleServiceProvider]) so tests can construct
/// [AcpLifecycleService] directly without pulling in the full Riverpod
/// SSH-session graph.
final acpSshConnectivityWatcherProvider = Provider<void>((ref) {
  final service = ref.watch(acpLifecycleServiceProvider);
  ref.listen<Map<int, SshConnectionState>>(activeSessionsProvider, (
    previous,
    next,
  ) {
    unawaited(service.handleSshConnectivityChanged());
  });
});

/// Reacts to auth-state transitions into `locked` by detaching every live
/// ACP session locally.
///
/// Kept as its own provider for the same reason as
/// [acpSshConnectivityWatcherProvider].
final acpAuthLockWatcherProvider = Provider<void>((ref) {
  final service = ref.watch(acpLifecycleServiceProvider);
  ref.listen<AuthState>(authStateProvider, (previous, next) {
    if (next == AuthState.locked && previous != AuthState.locked) {
      unawaited(service.handleAuthLocked());
    }
  });
});
