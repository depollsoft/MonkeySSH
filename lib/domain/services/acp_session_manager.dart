import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_client_capabilities.dart' as cap;
import '../models/acp_content.dart';
import '../models/acp_protocol.dart';
import '../models/acp_provider.dart';
import '../models/acp_recent_session.dart';
import '../models/acp_session_keys.dart';
import '../models/acp_session_state.dart';
import '../models/acp_timeline.dart';
import '../models/acp_updates.dart';
import '../models/monkeymux_acp_bridge.dart';
import 'acp_bridge_connector.dart';
import 'acp_client.dart';
import 'acp_client_capability_service.dart';
import 'acp_concurrency_policy.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_provider_service.dart';
import 'acp_recent_sessions_service.dart';
import 'acp_telemetry.dart';
import 'acp_telemetry_adapter.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'monkeymux_installer_service.dart';
import 'ssh_service.dart';
import 'telemetry_service.dart';

/// Result of a request to start or reconnect a live ACP session.
@immutable
sealed class AcpSessionLaunchResult {
  const AcpSessionLaunchResult();
}

/// The requested live session started (or was already live) successfully.
@immutable
final class AcpSessionLaunchStarted extends AcpSessionLaunchResult {
  /// Creates a successful launch result.
  const AcpSessionLaunchStarted(this.key);

  /// Stable key of the started session.
  final AcpSessionKey key;
}

/// The free concurrency limit blocked the requested transition.
///
/// The caller must resolve this in the UI by stopping/replacing one of the
/// blocking sessions or unlocking [AcpConcurrencyRequiresChoice.requiredFeature].
/// Domain code never navigates or shows a paywall.
@immutable
final class AcpSessionLaunchBlocked extends AcpSessionLaunchResult {
  /// Creates a blocked launch result.
  const AcpSessionLaunchBlocked(this.decision);

  /// The concurrency choice the user must make.
  final AcpConcurrencyRequiresChoice decision;
}

/// The requested launch failed with a safe, categorized error.
@immutable
final class AcpSessionLaunchFailed extends AcpSessionLaunchResult {
  /// Creates a failed launch result.
  const AcpSessionLaunchFailed(this.key, this.error);

  /// Key of the session that failed, when one was allocated.
  final AcpSessionKey? key;

  /// Safe failure description.
  final AcpSessionError error;
}

/// Aggregate, immutable snapshot of every tracked ACP session.
@immutable
final class AcpSessionManagerState {
  /// Creates a manager state snapshot.
  ///
  /// [sessions] is defensively copied into an unmodifiable list.
  AcpSessionManagerState({
    List<AcpSessionState> sessions = const <AcpSessionState>[],
    this.selectedKey,
  }) : sessions = List<AcpSessionState>.unmodifiable(sessions);

  /// All tracked sessions, ordered by creation time.
  final List<AcpSessionState> sessions;

  /// Canonical value of the currently selected session, if any.
  final String? selectedKey;

  /// Returns the session state for [keyValue], if tracked.
  AcpSessionState? byKeyValue(String keyValue) =>
      sessions.firstWhereOrNullValue(keyValue);

  /// The currently selected session state, if any.
  AcpSessionState? get selected =>
      selectedKey == null ? null : byKeyValue(selectedKey!);

  /// Keys of remote mux windows that count against the concurrency limit.
  ///
  /// A local detach does not stop the provider, so it must not free a slot.
  Set<String> get liveSessionKeyValues => {
    for (final session in sessions)
      if (session.isOpenMuxWindow) session.key.value,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionManagerState &&
          selectedKey == other.selectedKey &&
          listEquals(sessions, other.sessions);

  @override
  int get hashCode => Object.hash(selectedKey, Object.hashAll(sessions));
}

extension _FirstWhereOrNull on List<AcpSessionState> {
  AcpSessionState? firstWhereOrNullValue(String keyValue) {
    for (final session in this) {
      if (session.key.value == keyValue) return session;
    }
    return null;
  }
}

/// Manages multiple simultaneous ACP sessions across hosts and providers.
///
/// Each session runs in an isolated failure domain: one failed SSH connection,
/// bridge, or provider can never tear down unrelated sessions. Transcript
/// content lives only in each session's in-memory timeline and is never
/// persisted or logged.
class AcpSessionManager {
  /// Creates a session manager.
  AcpSessionManager({
    required AcpBridgeConnector connector,
    required AcpProviderService providerService,
    required AcpRecentSessionsService recentSessions,
    required bool Function() isProUnlocked,
    AcpConcurrencyPolicy concurrencyPolicy = const AcpConcurrencyPolicy(),
    DiagnosticsLogger? diagnostics,
    AcpTelemetrySink telemetry = const NoopAcpTelemetrySink(),
    DateTime Function() clock = DateTime.now,
    Duration detachedTurnPollInterval = const Duration(seconds: 3),
  }) : _connector = connector,
       _providerService = providerService,
       _recentSessions = recentSessions,
       _isProUnlocked = isProUnlocked,
       _policy = concurrencyPolicy,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance,
       _telemetry = telemetry,
       _clock = clock,
       _detachedTurnPollInterval = detachedTurnPollInterval;

  final AcpBridgeConnector _connector;
  final AcpProviderService _providerService;
  final AcpRecentSessionsService _recentSessions;
  final bool Function() _isProUnlocked;
  final AcpConcurrencyPolicy _policy;
  final DiagnosticsLogger _diagnostics;
  final AcpTelemetrySink _telemetry;
  final DateTime Function() _clock;
  final Duration _detachedTurnPollInterval;

  final Map<String, _SessionController> _controllers =
      <String, _SessionController>{};
  final Map<String, _BridgeAttachment> _attachments =
      <String, _BridgeAttachment>{};
  final StreamController<AcpSessionManagerState> _stateController =
      StreamController<AcpSessionManagerState>.broadcast();

  // Serializes lifecycle mutations so concurrency decisions always observe a
  // consistent live-session set.
  Future<void> _mutationQueue = Future<void>.value();

  String? _selectedKeyValue;
  AcpSessionManagerState _state = AcpSessionManagerState();
  var _disposed = false;

  /// Current aggregate state.
  AcpSessionManagerState get state => _state;

  /// Stream of aggregate state snapshots, starting with the current value.
  Stream<AcpSessionManagerState> get states async* {
    yield _state;
    yield* _stateController.stream;
  }

  /// Canonical values of every currently live session.
  Set<String> get liveSessionKeyValues => _state.liveSessionKeyValues;

  /// Starts a brand-new provider bridge and ACP session on [hostId].
  ///
  /// When the free concurrency limit is reached, returns
  /// [AcpSessionLaunchBlocked] without starting a bridge. Provide [replace] to
  /// first stop those live sessions and continue.
  Future<AcpSessionLaunchResult> startNewSession({
    required int hostId,
    required String providerId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) => _serialize(() async {
    _telemetry.featureOpened();
    final launch = await _resolveLaunch(
      providerId,
      launchCommandOverride: launchCommandOverride,
    );
    if (launch is _LaunchError) {
      return AcpSessionLaunchFailed(null, launch.error);
    }
    final resolved = _withProviderLabel(
      launch as _ResolvedLaunch,
      providerLabelOverride,
    );
    final workingDirectory = await _resolveWorkingDirectory(hostId, cwd);
    if (workingDirectory.error case final error?) {
      return AcpSessionLaunchFailed(null, error);
    }

    await _stopAll(replace);

    final decision = _evaluate('\u0000new');
    if (decision is AcpConcurrencyRequiresChoice) {
      return AcpSessionLaunchBlocked(decision);
    }

    return _startBridgeAndSession(
      hostId: hostId,
      launch: resolved,
      cwd: workingDirectory.value!,
      confirmInstall: confirmInstall,
      existingSessionId: null,
      autoApprovePermissions: autoApprovePermissions,
    );
  });

  /// Starts a fresh provider bridge and loads/resumes [acpSessionId].
  ///
  /// This is used for sessions discovered from an agent's own CLI history,
  /// where the ACP session ID is known but no persistent MonkeyMux bridge has
  /// been created yet. Concurrency and install behavior match [startNewSession].
  Future<AcpSessionLaunchResult> resumeProviderSession({
    required int hostId,
    required String providerId,
    required String acpSessionId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) => _serialize(() async {
    _telemetry.featureOpened();
    final launch = await _resolveLaunch(
      providerId,
      launchCommandOverride: launchCommandOverride,
    );
    if (launch is _LaunchError) {
      return AcpSessionLaunchFailed(null, launch.error);
    }
    final resolved = _withProviderLabel(
      launch as _ResolvedLaunch,
      providerLabelOverride,
    );
    final workingDirectory = await _resolveWorkingDirectory(hostId, cwd);
    if (workingDirectory.error case final error?) {
      return AcpSessionLaunchFailed(null, error);
    }

    await _stopAll(replace);

    final decision = _evaluate('\u0000resume');
    if (decision is AcpConcurrencyRequiresChoice) {
      return AcpSessionLaunchBlocked(decision);
    }

    return _startBridgeAndSession(
      hostId: hostId,
      launch: resolved,
      cwd: workingDirectory.value!,
      confirmInstall: confirmInstall,
      existingSessionId: acpSessionId,
      autoApprovePermissions: autoApprovePermissions,
    );
  });

  /// Reconnects to an existing remote bridge and resumes/loads its ACP session.
  ///
  /// Used on app restart, host reconnect, and when opening a recent session.
  /// If the session is already live and attached, it is simply selected unless
  /// [selectOnSuccess] is false for a background preload.
  Future<AcpSessionLaunchResult> reconnectSession({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    bool selectOnSuccess = true,
    MonkeyMuxAcpBridgeMetadata? knownRemoteBridge,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) => _serialize(() async {
    if (selectOnSuccess) _telemetry.featureOpened();
    final key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );
    final existing = _controllers[key.value];
    if (existing != null && existing.state.isLive) {
      if (selectOnSuccess) _select(key.value);
      return AcpSessionLaunchStarted(key);
    }

    final launch = await _resolveLaunch(
      providerId,
      launchCommandOverride: launchCommandOverride,
    );
    if (launch is _LaunchError) {
      return AcpSessionLaunchFailed(key, launch.error);
    }
    final resolved = _withProviderLabel(
      launch as _ResolvedLaunch,
      providerLabelOverride,
    );
    final workingDirectory = await _resolveWorkingDirectory(
      hostId,
      cwd,
      trustAbsolute: true,
    );
    if (workingDirectory.error case final error?) {
      return AcpSessionLaunchFailed(key, error);
    }
    final resolvedCwd = workingDirectory.value!;

    await _stopAll(replace);

    final decision = _evaluate(key.value);
    if (decision is AcpConcurrencyRequiresChoice) {
      return AcpSessionLaunchBlocked(decision);
    }

    MonkeyMuxAcpBridgeMetadata? remoteBridge;
    if (knownRemoteBridge?.id == bridgeId) {
      remoteBridge = knownRemoteBridge;
    } else {
      final List<MonkeyMuxAcpBridgeMetadata> remoteBridges;
      try {
        remoteBridges = await _connector.listBridges(
          hostId,
          confirmInstall: confirmInstall,
        );
      } on Object catch (error) {
        return AcpSessionLaunchFailed(key, _mapBridgeError(error));
      }
      remoteBridge = remoteBridges.firstWhereOrNull(
        (bridge) => bridge.id == bridgeId,
      );
    }
    final bridgeCanResume =
        remoteBridge != null &&
        remoteBridge.state != MonkeyMuxAcpProviderState.exited &&
        remoteBridge.state != MonkeyMuxAcpProviderState.stopped &&
        remoteBridge.state != MonkeyMuxAcpProviderState.protocolError;
    if (!bridgeCanResume) {
      if (!selectOnSuccess) {
        return AcpSessionLaunchFailed(
          key,
          const AcpSessionError(
            kind: AcpSessionErrorKind.bridgeExpired,
            message: 'The remote native agent window is no longer available.',
          ),
        );
      }
      if (existing != null) {
        _controllers.remove(key.value);
        await existing.disposeLocal();
        _emit();
      }
      _diagnostics.info(
        'acp.manager',
        'resume_bridge_recreated',
        fields: {'hostId': hostId, 'bridgeId': bridgeId},
      );
      final restarted = await _startBridgeAndSession(
        hostId: hostId,
        launch: resolved,
        cwd: resolvedCwd,
        confirmInstall: confirmInstall,
        existingSessionId: acpSessionId,
        autoApprovePermissions: autoApprovePermissions,
      );
      if (restarted is AcpSessionLaunchStarted) {
        await _recentSessions.remove(key);
      }
      return restarted;
    }

    // Re-attach an existing (detached) controller in place when possible.
    if (existing != null) {
      existing.updateWorkingDirectory(resolvedCwd);
      try {
        await existing.reconnect(remoteBridge: remoteBridge);
      } on _LaunchException catch (error) {
        _emit();
        return AcpSessionLaunchFailed(error.key ?? key, error.error);
      }
      if (selectOnSuccess) {
        _select(key.value);
      } else {
        _emit();
      }
      if (selectOnSuccess) await _recordRecent(existing.state);
      return AcpSessionLaunchStarted(key);
    }

    return _attachAndOpen(
      hostId: hostId,
      launch: resolved,
      bridgeId: bridgeId,
      cwd: resolvedCwd,
      existingSessionId: acpSessionId,
      confirmInstall: null,
      autoApprovePermissions: autoApprovePermissions,
      liveBridge: remoteBridge,
      selectOnSuccess: selectOnSuccess,
    );
  });

  /// Lists safe metadata for remote bridges on [hostId].
  Future<List<MonkeyMuxAcpBridgeMetadata>> listRemoteBridges(int hostId) =>
      _connector.listBridges(hostId);

  /// Selects [key] as the active session and persists it as last-selected.
  Future<void> selectSession(AcpSessionKey key) async {
    if (!_controllers.containsKey(key.value)) return;
    _select(key.value);
    await _recentSessions.setLastSelected(key);
  }

  /// Sends a prompt turn on [key], snapshotting [content] atomically.
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) {
    _reportAttachmentTelemetry(content);
    final controller = _requireController(key);
    return controller.prompt(content);
  }

  /// Reports coarse, allowlisted attachment counts for one prompt turn.
  ///
  /// Only category and count are reported; content, file names, and paths
  /// are never inspected beyond determining the ACP content-block type.
  void _reportAttachmentTelemetry(List<AcpContentBlock> content) {
    final counts = <String, int>{};
    for (final block in content) {
      final category = switch (block) {
        AcpImageContent() => 'image',
        AcpAudioContent() => 'audio',
        AcpResourceContent() || AcpResourceLinkContent() => 'resource',
        AcpTextContent() || AcpUnknownContent() => null,
      };
      if (category == null) continue;
      counts[category] = (counts[category] ?? 0) + 1;
    }
    counts.forEach(
      (category, count) =>
          _telemetry.attachmentSent(category: category, count: count),
    );
  }

  /// Cancels the active prompt turn for [key].
  Future<void> cancelPrompt(AcpSessionKey key) =>
      _requireController(key).cancelPrompt();

  /// Sets a generic session configuration option.
  Future<void> setConfigOption(
    AcpSessionKey key, {
    required String configId,
    required Object value,
  }) =>
      _requireController(key).setConfigOption(configId: configId, value: value);

  /// Changes MonkeySSH's Ask/YOLO behavior for one live session.
  Future<void> setAutoApprovePermissions(
    AcpSessionKey key, {
    required bool enabled,
  }) => _requireController(key).setAutoApprovePermissions(enabled: enabled);

  /// Sets the legacy session mode.
  Future<void> setMode(AcpSessionKey key, String modeId) =>
      _requireController(key).setMode(modeId);

  /// Sets the legacy session model.
  Future<void> setModel(AcpSessionKey key, String modelId) =>
      _requireController(key).setModel(modelId);

  /// Answers a pending permission request with [optionId].
  Future<void> respondToPermission(
    AcpSessionKey key,
    String requestKey,
    String optionId,
  ) => _requireController(key).respondToPermission(requestKey, optionId);

  /// Cancels a pending permission request.
  Future<void> cancelPermission(AcpSessionKey key, String requestKey) =>
      _requireController(key).cancelPermission(requestKey);

  /// Returns a pending write body for explicit in-memory review only.
  String? pendingWriteContent(AcpSessionKey key, String requestKey) =>
      _requireController(key).pendingWriteContent(requestKey);

  /// Approves a pending file write after explicit user confirmation.
  Future<void> approveWrite(AcpSessionKey key, String requestKey) =>
      _requireController(key).approveWrite(requestKey);

  /// Rejects a pending file write.
  Future<void> rejectWrite(AcpSessionKey key, String requestKey) =>
      _requireController(key).rejectWrite(requestKey);

  /// Detaches locally from [key] while leaving the remote bridge running.
  Future<void> detachSession(AcpSessionKey key) =>
      _serialize(() => _requireController(key).detach());

  /// Explicitly stops the remote bridge for [key] and releases resources.
  Future<void> stopSession(AcpSessionKey key) =>
      _serialize(() => _stopAll([key]));

  /// Releases every local session owned by a MonkeyMux window that is about to
  /// be closed. The mux close command owns remote bridge termination; tearing
  /// down locally first prevents its expected socket closure from entering the
  /// transport reconnect backoff.
  Future<void> releaseSessionsForClosingMuxWindow({
    required int hostId,
    required String bridgeId,
  }) => _serialize(() {
    final keys = _controllers.values
        .where(
          (controller) =>
              controller.state.key.hostId == hostId &&
              controller.state.key.bridgeId == bridgeId,
        )
        .map((controller) => controller.state.key)
        .toList(growable: false);
    return _stopAll(keys, stopRemoteBridges: false);
  });

  /// Closes the ACP session on the agent (when supported) and stops the bridge.
  Future<void> closeSession(AcpSessionKey key) => _serialize(() async {
    final controller = _controllers[key.value];
    if (controller == null) return;
    await controller.closeRemoteSession();
    await _stopAll([key]);
  });

  /// Deletes the stored ACP session (when supported), stops the bridge, and
  /// removes the recent-session reference.
  Future<void> deleteSession(AcpSessionKey key) => _serialize(() async {
    final controller = _controllers[key.value];
    if (controller != null) {
      await controller.deleteRemoteSession();
    }
    await _stopAll([key]);
    await _recentSessions.remove(key);
  });

  /// Forks [key] into a new ACP session on the same bridge, when supported.
  ///
  /// Returns the new session's launch result. The original session is not
  /// disturbed. Forking counts as a new live session for concurrency.
  Future<AcpSessionLaunchResult> forkSession(AcpSessionKey key) =>
      _serialize(() async {
        final controller = _controllers[key.value];
        if (controller == null) {
          return AcpSessionLaunchFailed(
            key,
            const AcpSessionError(
              kind: AcpSessionErrorKind.unknown,
              message: 'Session is not tracked.',
            ),
          );
        }
        final decision = _evaluate('\u0000fork');
        if (decision is AcpConcurrencyRequiresChoice) {
          return AcpSessionLaunchBlocked(decision);
        }
        return controller.fork();
      });

  /// Loads persisted recent sessions.
  Future<List<AcpRecentSessionRef>> loadRecentSessions() =>
      _recentSessions.list();

  /// Loads host-scoped native sessions from both local recents and the remote
  /// MonkeyMux bridge registry. Current helper metadata is persisted locally so
  /// the same session remains navigable through transient SSH disconnects.
  Future<List<AcpRecentSessionRef>> loadNavigableSessions(int hostId) async {
    final local = (await _recentSessions.list())
        .where((recent) => recent.hostId == hostId)
        .toList(growable: true);
    try {
      final providers = await _providerService.listAllProviders();
      final providerByLabel = <String, String>{
        for (final provider in providers) provider.label: provider.id,
      };
      final remote = await _connector.listBridges(hostId);
      for (final bridge in remote) {
        final sessionId = bridge.sessionId;
        final providerId =
            bridge.providerId ?? providerByLabel[bridge.provider];
        if (sessionId == null ||
            sessionId.isEmpty ||
            providerId == null ||
            providerId.isEmpty) {
          continue;
        }
        final recent = AcpRecentSessionRef(
          hostId: hostId,
          providerId: providerId,
          bridgeId: bridge.id,
          acpSessionId: sessionId,
          cwd: bridge.cwd,
          createdAt: bridge.startedAt,
          lastActivityAt: bridge.lastActivity,
        );
        final index = local.indexWhere(
          (candidate) => candidate.key.value == recent.key.value,
        );
        final merged = index >= 0
            ? local[index].copyWith(
                cwd: recent.cwd,
                lastActivityAt: recent.lastActivityAt,
              )
            : recent;
        if (index >= 0) {
          local[index] = merged;
        } else {
          local.add(merged);
        }
        await _recentSessions.record(merged);
      }
    } on Object {
      // Local recents remain available while SSH/helper discovery is offline.
    }
    local.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return List<AcpRecentSessionRef>.unmodifiable(local);
  }

  /// Loads the persisted last-selected session key.
  Future<AcpSessionKey?> loadLastSelected() =>
      _recentSessions.getLastSelected();

  /// Releases every session, attachment, and stream. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controllers = _controllers.values.toList(growable: false);
    _controllers.clear();
    for (final controller in controllers) {
      // App/provider teardown is a local detach, not an explicit user stop.
      // Leave MonkeyMux and any in-flight agent turn running remotely.
      await controller.disposeLocal(permanent: false);
    }
    final attachments = _attachments.values.toList(growable: false);
    _attachments.clear();
    for (final attachment in attachments) {
      await attachment.forceClose();
    }
    await _stateController.close();
  }

  // ---- internal lifecycle ------------------------------------------------

  Future<AcpSessionLaunchResult> _startBridgeAndSession({
    required int hostId,
    required _ResolvedLaunch launch,
    required String cwd,
    required MonkeyMuxInstallConfirmation? confirmInstall,
    required String? existingSessionId,
    required bool autoApprovePermissions,
  }) async {
    final startedAt = _clock();
    MonkeyMuxAcpBridgeStartResult startResult;
    try {
      startResult = await _connector.startBridge(
        hostId: hostId,
        providerId: launch.providerId,
        providerLabel: launch.label,
        launchArgv: launch.argv,
        cwd: cwd,
        confirmInstall: confirmInstall,
      );
    } on Object catch (error) {
      _diagnostics.error(
        'acp.manager',
        'bridge_start_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      return AcpSessionLaunchFailed(null, _mapBridgeError(error));
    }
    return _attachAndOpen(
      hostId: hostId,
      launch: launch,
      bridgeId: startResult.bridgeId,
      cwd: cwd,
      existingSessionId: existingSessionId,
      confirmInstall: confirmInstall,
      startedBridge: true,
      bridgeStartedAt: startedAt,
      autoApprovePermissions: autoApprovePermissions,
    );
  }

  Future<AcpSessionLaunchResult> _attachAndOpen({
    required int hostId,
    required _ResolvedLaunch launch,
    required String bridgeId,
    required String cwd,
    required String? existingSessionId,
    required MonkeyMuxInstallConfirmation? confirmInstall,
    required bool autoApprovePermissions,
    MonkeyMuxAcpBridgeMetadata? liveBridge,
    bool selectOnSuccess = true,
    bool startedBridge = false,
    DateTime? bridgeStartedAt,
  }) async {
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );
    final attachment =
        _attachments[bridgeKey.value] ??
        _BridgeAttachment(
          bridgeKey: bridgeKey,
          providerId: launch.providerId,
          session: _connector.connect(
            hostId: hostId,
            bridgeId: bridgeId,
            providerId: launch.providerId,
          ),
          capabilityServiceFactory: _capabilityServiceFactory(
            hostId: hostId,
            cwd: cwd,
            autoApprovePermissions: autoApprovePermissions,
          ),
        );
    _attachments[bridgeKey.value] = attachment;

    final controller = _SessionController(
      manager: this,
      attachment: attachment,
      providerLabel: launch.label,
      isCustomProvider: launch.isCustom,
      cwd: cwd,
      clock: _clock,
      diagnostics: _diagnostics,
      autoApprovePermissions: autoApprovePermissions,
      freshBridge: startedBridge,
      detachedTurnPollInterval: _detachedTurnPollInterval,
    ).._acquireLease(attachment);

    final selectedKeyBeforeProvisional = _selectedKeyValue;
    String? provisionalKeyValue;

    void discardProvisionalController() {
      final value = provisionalKeyValue;
      if (value == null || !identical(_controllers[value], controller)) return;
      _controllers.remove(value);
      if (_selectedKeyValue == value) {
        final prior = selectedKeyBeforeProvisional;
        _selectedKeyValue =
            prior != null && (_controllers[prior]?.state.isLive ?? false)
            ? prior
            : null;
      }
      _emit();
    }

    try {
      final openFuture = controller.open(
        hostId: hostId,
        providerId: launch.providerId,
        bridgeId: bridgeId,
        existingSessionId: existingSessionId,
        liveBridge: liveBridge,
      );
      if (existingSessionId != null) {
        // The reconnect identity is already stable. Publish its connecting
        // state before session/load replays history so the real conversation
        // shell can replace the terminal immediately while history rebuilds
        // atomically off-screen from its final tail.
        provisionalKeyValue = controller.state.key.value;
        controller._commitPublishedState();
        _controllers[provisionalKeyValue] = controller;
        if (selectOnSuccess) {
          _select(provisionalKeyValue);
        } else {
          _emit();
        }
      }
      final key = await openFuture;
      final previousPublishedKey = provisionalKeyValue;
      if (previousPublishedKey != null &&
          previousPublishedKey != key.value &&
          identical(_controllers[previousPublishedKey], controller)) {
        _controllers.remove(previousPublishedKey);
      }
      _controllers[key.value] = controller;
      provisionalKeyValue = key.value;
      if (selectOnSuccess) {
        _select(key.value);
      } else {
        _emit();
      }
      if (selectOnSuccess) await _recordRecent(controller.state);
      _diagnostics.info(
        'acp.manager',
        'session_open',
        fields: {
          'hostId': hostId,
          'bridgeId': bridgeId,
          'reconnect': existingSessionId != null,
          if (bridgeStartedAt != null)
            'startMs': _clock().difference(bridgeStartedAt).inMilliseconds,
        },
      );
      if (selectOnSuccess) {
        _telemetry.sessionOpened(
          providerCategory: launch.providerId,
          isReconnect: existingSessionId != null,
        );
      }
      return AcpSessionLaunchStarted(key);
    } on _LaunchException catch (error) {
      discardProvisionalController();
      await controller.disposeLocal();
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      _telemetry.failure(category: error.error.kind.name);
      return AcpSessionLaunchFailed(error.key, error.error);
    } on Object catch (error) {
      discardProvisionalController();
      await controller.disposeLocal();
      final mapped = _mapBridgeError(error);
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      _telemetry.failure(category: mapped.kind.name);
      return AcpSessionLaunchFailed(null, mapped);
    }
  }

  /// Best-effort stops a freshly started bridge that never produced a usable
  /// session, so a failed launch does not orphan the remote process.
  ///
  /// This includes authentication-required failures: there is no
  /// authenticate/retry-on-existing-bridge path in this release, so a retained
  /// auth-blocked bridge would be unreachable and each retry would spawn
  /// another. The UI instead offers the provider's terminal-auth command and
  /// the user retries cleanly, starting a fresh bridge. The bridge is still
  /// retained when another session already uses it.
  Future<void> _maybeStopOrphanBridge({
    required bool startedBridge,
    required int hostId,
    required String bridgeId,
  }) async {
    if (!startedBridge) return;
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );
    final stillUsed = _controllers.values.any(
      (controller) => controller.bridgeKey == bridgeKey,
    );
    if (stillUsed) return;
    try {
      await _connector.stopBridge(hostId, bridgeId);
      _diagnostics.info(
        'acp.manager',
        'orphan_bridge_stopped',
        fields: {'hostId': hostId, 'bridgeId': bridgeId},
      );
    } on Object catch (stopError) {
      _diagnostics.warning(
        'acp.manager',
        'orphan_bridge_stop_failed',
        fields: {'hostId': hostId, 'errorType': stopError.runtimeType},
      );
    }
  }

  Future<void> _recordRecent(AcpSessionState state) async {
    String? bounded(String? value, int maxCharacters) {
      if (value == null) return null;
      return value.length <= maxCharacters
          ? value
          : value.substring(0, maxCharacters);
    }

    try {
      await _recentSessions.record(
        AcpRecentSessionRef(
          hostId: state.key.hostId,
          providerId: state.key.providerId,
          bridgeId: state.key.bridgeId,
          acpSessionId: state.key.acpSessionId,
          title: bounded(state.title, kAcpRecentTitleMaxCharacters),
          cwd: bounded(state.cwd, kAcpRecentCwdMaxCharacters),
          createdAt: state.createdAt,
          lastActivityAt: state.lastActivityAt,
        ),
      );
    } on Object catch (error) {
      // Recents are optional navigation metadata. A settings failure must never
      // tear down an already-running provider/session.
      _diagnostics.warning(
        'acp.manager',
        'recent_persist_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  Future<void> _stopAll(
    List<AcpSessionKey> keys, {
    bool stopRemoteBridges = true,
  }) async {
    for (final key in keys) {
      final controller = _controllers[key.value];
      if (controller == null) continue;
      // Confirm termination before dropping local ownership. Otherwise a
      // transient SSH/control failure makes the UI report success while an
      // untracked provider keeps running and frees a concurrency slot.
      final bridgeStillUsed = _controllers.values.any(
        (other) =>
            !identical(other, controller) && other.bridgeKey == key.bridge,
      );
      if (stopRemoteBridges && !bridgeStillUsed) {
        try {
          await _connector.stopBridge(key.hostId, key.bridgeId);
        } on Object catch (error) {
          _diagnostics.warning(
            'acp.manager',
            'bridge_stop_failed',
            fields: {'hostId': key.hostId, 'errorType': error.runtimeType},
          );
          rethrow;
        }
      }

      _controllers.remove(key.value);
      // Cancel only this session's own pending permission/write requests
      // before releasing its lease. A sibling fork keeps its own requests and
      // terminals through the shared capability service.
      await controller.attachment.capabilityService?.closeSession(
        key.acpSessionId,
      );
      await controller.disposeLocal();
      _telemetry.sessionEnded(reason: 'stopped');
    }
    _emit();
  }

  /// Builds a lazy capability-service factory bound to [hostId] and [cwd].
  ///
  /// Resolved once per [_BridgeAttachment], immediately before its first
  /// `initialize`, so it observes whichever SSH session is active for the
  /// host at that moment (including after an SSH reconnect). The capability
  /// service is always created so `session/request_permission` is always
  /// routed and answered; when no same-host filesystem/terminal binding can
  /// be resolved, `fs/*`/`terminal/*` requests are simply declined as
  /// unavailable rather than left unanswered.
  ///
  /// When [existingRegistry] is provided (a prior attachment's still-pending
  /// permission/write decisions, carried across a soft detach/reconnect), it
  /// is reused instead of creating an empty registry so those decisions stay
  /// visible immediately and rebind by request id once the agent replays
  /// them, rather than silently disappearing until/unless a replay arrives.
  Future<AcpClientCapabilityService> Function() _capabilityServiceFactory({
    required int hostId,
    required String cwd,
    required bool autoApprovePermissions,
    AcpPendingRequestRegistry? existingRegistry,
  }) => () async {
    AcpHostCapabilityBinding? binding;
    try {
      binding = await _connector.resolveCapabilityBinding(hostId);
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.manager',
        'capability_binding_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      binding = null;
    }
    return AcpClientCapabilityService(
      fileSystem: binding?.fileSystem,
      terminalExecutor: binding?.terminalExecutor,
      allowedRoots: <String>[cwd],
      registry: existingRegistry ?? AcpPendingRequestRegistry(),
      autoApprovePermissions: autoApprovePermissions,
      diagnostics: _diagnostics,
    );
  };

  Future<bool> _releaseAttachment(
    _BridgeAttachment attachment, {
    bool permanent = false,
  }) async {
    final closed = await attachment.release(permanent: permanent);
    if (closed &&
        identical(_attachments[attachment.bridgeKey.value], attachment)) {
      _attachments.remove(attachment.bridgeKey.value);
    }
    return closed;
  }

  AcpConcurrencyDecision _evaluate(String candidateKeyValue) =>
      _policy.evaluate(
        currentLiveSessionKeys: liveSessionKeyValues,
        candidateSessionKey: candidateKeyValue,
        isProUnlocked: _isProUnlocked(),
      );

  _ResolvedLaunch _withProviderLabel(
    _ResolvedLaunch launch,
    String? providerLabelOverride,
  ) {
    final label = providerLabelOverride?.trim();
    if (label == null || label.isEmpty || label == launch.label) return launch;
    return _ResolvedLaunch(
      providerId: launch.providerId,
      label: label,
      argv: launch.argv,
      isCustom: launch.isCustom,
    );
  }

  Future<({AcpSessionError? error, String? value})> _resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async {
    try {
      final resolved = await _connector.resolveWorkingDirectory(
        hostId,
        cwd,
        trustAbsolute: trustAbsolute,
      );
      if (resolved.trim().isEmpty) {
        throw const AcpWorkingDirectoryException();
      }
      return (error: null, value: resolved);
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.manager',
        'cwd_resolution_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      return (
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.bridgeUnavailable,
          message: 'The working directory is unavailable on this host.',
        ),
        value: null,
      );
    }
  }

  Future<_LaunchOutcome> _resolveLaunch(
    String providerId, {
    AcpLaunchCommand? launchCommandOverride,
  }) async {
    final builtin = acpBuiltinProviders.firstWhereOrNull(
      (provider) => provider.id == providerId,
    );
    if (builtin != null) {
      if (launchCommandOverride != null &&
          !isApprovedAcpBuiltinLaunchOverride(builtin, launchCommandOverride)) {
        return const _LaunchError(
          AcpSessionError(
            kind: AcpSessionErrorKind.commandNotApproved,
            message: 'The adapter launch command is not approved.',
          ),
        );
      }
      return _ResolvedLaunch(
        providerId: builtin.id,
        label: builtin.label,
        argv: (launchCommandOverride ?? builtin.launchCommand).argv,
        isCustom: false,
      );
    }
    final custom = await _providerService.getCustomProvider(providerId);
    if (custom == null) {
      return const _LaunchError(
        AcpSessionError(
          kind: AcpSessionErrorKind.unknown,
          message: 'Unknown ACP provider.',
        ),
      );
    }
    if (!custom.isCommandApproved) {
      return const _LaunchError(
        AcpSessionError(
          kind: AcpSessionErrorKind.commandNotApproved,
          message: 'This provider\'s launch command must be re-approved.',
        ),
      );
    }
    return _ResolvedLaunch(
      providerId: custom.id,
      label: custom.label,
      argv: custom.launchCommand.argv,
      isCustom: true,
    );
  }

  _SessionController _requireController(AcpSessionKey key) {
    final controller = _controllers[key.value];
    if (controller == null) {
      throw StateError('No ACP session for the requested key.');
    }
    return controller;
  }

  void _select(String? keyValue) {
    _selectedKeyValue = keyValue;
    _emit();
  }

  void _onControllerChanged(_SessionController controller) {
    if (!_controllers.containsValue(controller)) return;
    controller._commitPublishedState();
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    final sessions =
        _controllers.values
            .map((controller) => controller.publishedState)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (_selectedKeyValue != null &&
        !_controllers.containsKey(_selectedKeyValue)) {
      _selectedKeyValue = sessions.isEmpty ? null : sessions.last.key.value;
    }
    _state = AcpSessionManagerState(
      sessions: sessions,
      selectedKey: _selectedKeyValue,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  AcpSessionError _mapBridgeError(Object error) {
    if (error is MonkeyMuxInstallConfirmationRequiredException) {
      return const AcpSessionError(
        kind: AcpSessionErrorKind.bridgeUnavailable,
        message: 'MonkeyMux needs to be installed or updated on this host.',
      );
    }
    if (error is MonkeyMuxInstallDeclinedException) {
      return const AcpSessionError(
        kind: AcpSessionErrorKind.bridgeUnavailable,
        message: 'MonkeyMux installation was canceled.',
      );
    }
    if (error is MonkeyMuxInstallException) {
      return const AcpSessionError(
        kind: AcpSessionErrorKind.bridgeUnavailable,
        message: 'MonkeyMux could not be prepared on this host.',
      );
    }
    if (error is MonkeyMuxAcpBridgeException) {
      return AcpSessionError(
        kind: switch (error.kind) {
          MonkeyMuxAcpBridgeErrorKind.helperUnavailable ||
          MonkeyMuxAcpBridgeErrorKind.helperProcess ||
          MonkeyMuxAcpBridgeErrorKind.invalidMetadata ||
          MonkeyMuxAcpBridgeErrorKind.unsupportedVersion =>
            AcpSessionErrorKind.bridgeUnavailable,
          MonkeyMuxAcpBridgeErrorKind.keychainLocked =>
            AcpSessionErrorKind.authenticationRequired,
          MonkeyMuxAcpBridgeErrorKind.providerExited =>
            AcpSessionErrorKind.providerExited,
          MonkeyMuxAcpBridgeErrorKind.replayOverflow ||
          MonkeyMuxAcpBridgeErrorKind.sequenceGap ||
          MonkeyMuxAcpBridgeErrorKind.sshChannel ||
          MonkeyMuxAcpBridgeErrorKind.nonWriter ||
          MonkeyMuxAcpBridgeErrorKind.frameTooLarge ||
          MonkeyMuxAcpBridgeErrorKind.invalidFrame ||
          MonkeyMuxAcpBridgeErrorKind.closed => AcpSessionErrorKind.transport,
          MonkeyMuxAcpBridgeErrorKind.providerUnavailable =>
            AcpSessionErrorKind.providerExited,
          MonkeyMuxAcpBridgeErrorKind.invalidBridgeId ||
          MonkeyMuxAcpBridgeErrorKind.invalidLaunch =>
            AcpSessionErrorKind.bridgeUnavailable,
        },
        retryable: switch (error.kind) {
          MonkeyMuxAcpBridgeErrorKind.sshChannel ||
          MonkeyMuxAcpBridgeErrorKind.closed => true,
          _ => false,
        },
        message: switch (error.kind) {
          MonkeyMuxAcpBridgeErrorKind.invalidMetadata ||
          MonkeyMuxAcpBridgeErrorKind.unsupportedVersion =>
            'MonkeyMux needs to be updated on this host. Reconnect and try again.',
          MonkeyMuxAcpBridgeErrorKind.invalidLaunch =>
            'The agent launch configuration was rejected.',
          MonkeyMuxAcpBridgeErrorKind.invalidBridgeId =>
            'The saved native agent session is no longer available.',
          MonkeyMuxAcpBridgeErrorKind.keychainLocked =>
            'Unlock the Mac login keychain to start Cursor Agent.',
          MonkeyMuxAcpBridgeErrorKind.providerExited ||
          MonkeyMuxAcpBridgeErrorKind.providerUnavailable =>
            'The native agent process exited.',
          MonkeyMuxAcpBridgeErrorKind.helperUnavailable ||
          MonkeyMuxAcpBridgeErrorKind.helperProcess =>
            'MonkeyMux could not start the native agent bridge. Reconnect and try again.',
          _ => 'The native agent connection was interrupted.',
        },
      );
    }
    return const AcpSessionError(
      kind: AcpSessionErrorKind.unknown,
      message: 'Failed to start the agent session.',
    );
  }
}

/// A reference-counted attachment to one remote bridge (one writer client).
///
/// Multiple sessions (for example, an original and its fork) can share a single
/// attachment. Its underlying client, JSON-RPC connection, and transport are
/// released only when the last leaseholder releases it. Release is guarded so
/// the reference count can never go negative and the transport is closed at
/// most once.
class _BridgeAttachment {
  _BridgeAttachment({
    required this.bridgeKey,
    required this.providerId,
    required AcpBridgeSession session,
    required Future<AcpClientCapabilityService> Function()
    capabilityServiceFactory,
    AcpInitializeResult? initialization,
    AcpClientCapabilityService? capabilityService,
  }) : _session = session,
       _capabilityServiceFactory = capabilityServiceFactory,
       _initialization = initialization,
       _capabilityService = capabilityService;

  final AcpBridgeKey bridgeKey;
  final String providerId;
  final AcpBridgeSession _session;
  final Future<AcpClientCapabilityService> Function() _capabilityServiceFactory;
  int _refCount = 0;
  AcpInitializeResult? _initialization;
  Future<AcpInitializeResult>? _initializeFuture;
  Future<void>? _closeFuture;
  AcpClientCapabilityService? _capabilityService;
  var _terminated = false;

  AcpClient get client => _session.client;
  Stream<AcpSessionNotification> get notifications => client.updates;
  Stream<MonkeyMuxAcpTransportState> get transportStates =>
      _session.transportStates;
  Stream<MonkeyMuxAcpBridgeException> get transportErrors =>
      _session.transportErrors;
  AcpInitializeResult? get initialization => _initialization;
  bool get skippedHistoricalReplay => _session.skippedHistoricalReplay;
  int get lastDeliveredSequence => _session.lastDeliveredSequence;

  /// The capability service bound to this attachment's client, or `null` when
  /// no same-host filesystem/terminal binding was available at initialize
  /// time (the ACP session still works; fs/terminal requests are declined).
  AcpClientCapabilityService? get capabilityService => _capabilityService;

  /// Whether the underlying transport has terminally failed or been closed and
  /// this attachment must be replaced rather than reused on reconnect.
  bool get isTerminated => _terminated || _closeFuture != null;

  /// Current lease count. Exposed only for assertions and diagnostics.
  int get refCount => _refCount;

  /// Marks the transport as terminally unusable without releasing a lease, so
  /// the next reconnect replaces it. Idempotent.
  void markTerminated() => _terminated = true;

  void retain() => _refCount++;

  /// Releases one lease. Returns `true` only when this call dropped the last
  /// lease and closed the transport. Never decrements below zero and never
  /// closes the transport more than once.
  ///
  /// [permanent] distinguishes a temporary local detach (the remote bridge
  /// stays alive and pending permissions/writes must survive to be replayed
  /// on the next reconnect) from a genuinely final teardown such as an
  /// explicit stop or app disposal, where outstanding requests are cancelled
  /// because no one will ever answer them.
  Future<bool> release({bool permanent = false}) async {
    if (_refCount <= 0) return false;
    _refCount--;
    if (_refCount > 0) return false;
    await _close(permanent: permanent);
    return true;
  }

  Future<void> forceClose() async {
    _refCount = 0;
    await _close(permanent: true);
  }

  Future<void> _close({required bool permanent}) =>
      _closeFuture ??= _performClose(permanent: permanent);

  Future<void> _performClose({required bool permanent}) async {
    if (permanent) {
      // Fully destroys session-owned terminals and pending requests: once
      // the last session leasing this bridge attachment releases it for
      // good, there is no one left to answer them.
      await _capabilityService?.close();
    } else {
      // Only stops routing new server requests locally; the registry (and
      // any pending permissions/writes) survives so the next reconnect can
      // rebind and replay them without duplicating or auto-answering them.
      await _capabilityService?.detach();
    }
    await _session.close();
  }

  Future<AcpInitializeResult> ensureInitialized() =>
      _initializeFuture ??= _doInitialize();

  Future<AcpInitializeResult> _doInitialize() async {
    final service = _capabilityService ??= await _capabilityServiceFactory();
    final retainedInitialization = _initialization;
    if (retainedInitialization != null) {
      service.attach(client);
      return retainedInitialization;
    }
    final result = await service.initialize(client);
    _initialization = result;
    return result;
  }
}

/// Maximum number of submitted prompts retained while another turn runs.
const acpPromptQueueMaxCount = 16;

/// Maximum encoded bytes retained across queued prompts for one session.
const acpPromptQueueMaxBytes = acpJsonRpcDefaultMaxFrameBytes;

/// Raised when a session's bounded local steering queue is full.
class AcpPromptQueueFullException implements Exception {
  /// Creates a queue-full failure.
  const AcpPromptQueueFullException();

  @override
  String toString() => 'The agent prompt queue is full.';
}

class _QueuedAcpPrompt {
  _QueuedAcpPrompt({
    required this.content,
    required this.localMessageId,
    required this.encodedBytes,
  });

  final List<AcpContentBlock> content;
  final String localMessageId;
  final int encodedBytes;
  final Completer<AcpPromptResult> completer = Completer<AcpPromptResult>();
}

/// Maximum retained entries for session-scoped lists (plan steps, available
/// commands, config options) that a misbehaving agent could otherwise grow
/// without bound. Oldest entries are dropped, keeping the most recent state.
const _maxSessionListEntries = 200;
const _sessionUpdateTurnMaxCount = 16;
const _sessionUpdateTurnTimeBudget = Duration(milliseconds: 4);
const _maxCoalescedReplayTextChars = 32 * 1024;

/// Owns the normalized state and streaming lifecycle for one ACP session.
class _SessionController {
  _SessionController({
    required AcpSessionManager manager,
    required this.attachment,
    required String providerLabel,
    required bool isCustomProvider,
    required String cwd,
    required DateTime Function() clock,
    required DiagnosticsLogger diagnostics,
    required bool autoApprovePermissions,
    required bool freshBridge,
    required Duration detachedTurnPollInterval,
  }) : _manager = manager,
       _providerLabel = providerLabel,
       _isCustomProvider = isCustomProvider,
       _cwd = cwd,
       _clock = clock,
       _diagnostics = diagnostics,
       _autoApprovePermissions = autoApprovePermissions,
       _freshBridge = freshBridge,
       _detachedTurnPollInterval = detachedTurnPollInterval;

  final AcpSessionManager _manager;

  /// Shared bridge attachment backing this session.
  _BridgeAttachment attachment;

  final String _providerLabel;
  final bool _isCustomProvider;
  String _cwd;
  final DateTime Function() _clock;
  final DiagnosticsLogger _diagnostics;
  bool _autoApprovePermissions;
  bool _freshBridge;
  final Duration _detachedTurnPollInterval;

  final AcpTimelineBuilder _timelineBuilder = AcpTimelineBuilder();
  final Queue<AcpSessionNotification> _pendingSessionUpdates =
      Queue<AcpSessionNotification>();
  Future<void>? _sessionUpdatePumpFuture;
  var _sessionUpdatesEnqueued = 0;
  var _sessionUpdatesApplied = 0;
  var _coalescingSessionUpdateNotifications = false;
  var _historyReplayPublicationHeld = false;
  var _historyRestoreUnavailable = false;
  var _managerNotificationPending = false;
  final Queue<_QueuedAcpPrompt> _promptQueue = Queue<_QueuedAcpPrompt>();
  var _queuedPromptBytes = 0;
  var _promptActive = false;
  var _detachedTurnInFlight = false;
  Timer? _detachedTurnStatusTimer;
  Timer? _recentPersistTimer;
  var _detachedTurnMonitorGeneration = 0;
  var _lastAcknowledgedBridgeSequence = 0;

  StreamSubscription<AcpSessionNotification>? _updatesSub;
  StreamSubscription<List<cap.AcpPendingClientRequest>>? _capabilityRequestsSub;
  StreamSubscription<MonkeyMuxAcpTransportState>? _transportSub;
  StreamSubscription<MonkeyMuxAcpBridgeException>? _transportErrorSub;

  late AcpSessionState _state;
  AcpSessionState? _publishedState;
  late AcpSessionKey _key;
  var _holdsAttachment = false;
  var _disposed = false;

  /// Current immutable working state.
  AcpSessionState get state => _state;

  /// Last state atomically committed to aggregate manager listeners.
  AcpSessionState get publishedState => _publishedState ?? _state;

  void _commitPublishedState() => _publishedState = _state;

  /// Bridge key of the attachment currently backing this session.
  AcpBridgeKey get bridgeKey => _key.bridge;

  void updateWorkingDirectory(String cwd) {
    if (_cwd == cwd) {
      return;
    }
    _cwd = cwd;
    _update((state) => state.copyWith(cwd: cwd));
  }

  /// Acquires a lease on [target], making it this controller's attachment.
  void _acquireLease(_BridgeAttachment target) {
    attachment = target;
    target.retain();
    _holdsAttachment = true;
  }

  /// Releases this controller's lease exactly once, if it holds one.
  ///
  /// Returns whether releasing dropped the attachment's last lease (closing
  /// the local transport). A controller that already released (for example a
  /// detached original) never decrements the count again. See
  /// [_BridgeAttachment.release] for the meaning of [permanent].
  Future<bool> _releaseLease({bool permanent = false}) async {
    if (!_holdsAttachment) return false;
    final deliveredSequence = attachment.lastDeliveredSequence;
    if (deliveredSequence > _lastAcknowledgedBridgeSequence) {
      _lastAcknowledgedBridgeSequence = deliveredSequence;
    }
    _holdsAttachment = false;
    return _manager._releaseAttachment(attachment, permanent: permanent);
  }

  /// Opens the session: initializes the connection and creates/loads/resumes
  /// the ACP session capability-adaptively.
  Future<AcpSessionKey> open({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String? existingSessionId,
    MonkeyMuxAcpBridgeMetadata? liveBridge,
  }) async {
    final now = _clock();
    // Provisional key until the real session id is known.
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: existingSessionId ?? '',
    );
    _state = AcpSessionState(
      key: _key,
      providerLabel: _providerLabel,
      isCustomProvider: _isCustomProvider,
      cwd: _cwd,
      status: AcpConnectionStatus.connecting,
      autoApprovePermissions: _autoApprovePermissions,
      createdAt: now,
      lastActivityAt: now,
    );

    final reattachingLiveBridge =
        existingSessionId != null && liveBridge != null;
    final reattachingActiveTurn =
        reattachingLiveBridge && liveBridge.inFlightTurnCount > 0;
    final holdHistoryReplay = existingSessionId != null;
    _historyRestoreUnavailable = false;
    if (holdHistoryReplay) _historyReplayPublicationHeld = true;
    _subscribeTransport();
    if (reattachingLiveBridge) {
      // The MonkeyMux writer handshake can immediately replay notifications.
      // Subscribe before initialize so process-restart reattachment loses none.
      _subscribeSessionNotifications();
    }

    AcpInitializeResult init;
    final initialize = Stopwatch()..start();
    try {
      _update((s) => s.copyWith(status: AcpConnectionStatus.initializing));
      init = await attachment.ensureInitialized();
    } on Object catch (error) {
      if (holdHistoryReplay) _historyReplayPublicationHeld = false;
      throw _LaunchException(_key, _mapClientError(error));
    }

    _diagnostics.info(
      'acp.session',
      'initialize_complete',
      fields: {
        'durationMs': initialize.elapsedMilliseconds,
        'reconnect': existingSessionId != null,
      },
    );
    _update(
      (s) => s.copyWith(initialization: init, authMethods: init.authMethods),
    );
    if (reattachingLiveBridge) _subscribeCapabilityRequests();

    // For an existing session, the id is already known, so subscribe to session
    // updates BEFORE issuing session/load or session/resume. History replay is
    // emitted while the load RPC is still in flight; subscribing first ensures
    // those replayed updates are retained rather than dropped.
    if (existingSessionId != null && !reattachingLiveBridge) {
      _subscribeSessionStreams();
    }

    late final String resolvedSessionId;
    try {
      resolvedSessionId = reattachingActiveTurn
          ? existingSessionId
          : await _establishSession(existingSessionId, init);
      if (holdHistoryReplay) {
        await _drainHistoryReplayNotifications();
        _applyHistoryUnavailableWarningIfNeeded();
      }
    } finally {
      if (holdHistoryReplay) _finishHistoryReplayPublication();
    }
    _freshBridge = false;
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: resolvedSessionId,
    );
    attachment.capabilityService?.setSessionAutoApprovePermissions(
      resolvedSessionId,
      enabled: _autoApprovePermissions,
    );
    _update(
      (s) => s.copyWith(
        status: AcpConnectionStatus.ready,
        promptStatus: reattachingActiveTurn
            ? AcpPromptStatus.streaming
            : AcpPromptStatus.idle,
        lastActivityAt: _clock(),
      ),
      key: _key,
    );

    // A brand-new session's id was unknown until session/new returned, so its
    // update subscription is established here.
    if (existingSessionId == null) {
      _subscribeSessionStreams();
    }
    if (reattachingActiveTurn) _startDetachedTurnMonitor();
    return _key;
  }

  Future<String> _establishSession(
    String? existingSessionId,
    AcpInitializeResult init,
  ) async {
    final caps = init.agentCapabilities;
    try {
      if (existingSessionId == null) {
        final sessionNew = Stopwatch()..start();
        final result = await attachment.client.newSession(cwd: _cwd);
        _applySetupResult(result);
        _diagnostics.info(
          'acp.session',
          'new_session_complete',
          fields: {'durationMs': sessionNew.elapsedMilliseconds},
        );
        final id = result.sessionId;
        if (id == null || id.isEmpty) {
          throw _LaunchException(
            _key,
            const AcpSessionError(
              kind: AcpSessionErrorKind.protocol,
              message: 'The agent did not return a session id.',
            ),
          );
        }
        return id;
      }
      // A newly started adapter must load historical state from its durable
      // store. `session/resume` is for a session already owned by the live ACP
      // process and can acknowledge without loading CLI history (observed with
      // Claude and Codex adapters), which looks like a successful fresh chat.
      if ((_freshBridge || attachment.skippedHistoricalReplay) &&
          caps.loadSession) {
        final historyLoad = Stopwatch()..start();
        final result = await _loadExistingSession(existingSessionId);
        if (result != null) {
          _clearHistoryUnavailableWarning();
          _applySetupResult(result);
          _diagnostics.info(
            'acp.session',
            'history_load_complete',
            fields: {
              'durationMs': historyLoad.elapsedMilliseconds,
              'freshBridge': _freshBridge,
              'skippedBridgeReplay': attachment.skippedHistoricalReplay,
            },
          );
        } else {
          if (caps.session.resume) {
            try {
              final resumed = await attachment.client.resumeSession(
                sessionId: existingSessionId,
                cwd: _cwd,
              );
              _applySetupResult(resumed);
            } on AcpRemoteException catch (error) {
              // The exact load response proved the live provider already owns
              // this session. A provider-specific resume refusal only prevents
              // optional setup refresh; transport/time-out failures still flow.
              _diagnostics.info(
                'acp.session',
                'already_loaded_resume_rejected',
                fields: {'errorCode': error.code},
              );
            }
          }
        }
        return existingSessionId;
      }
      if (caps.session.resume) {
        final result = await attachment.client.resumeSession(
          sessionId: existingSessionId,
          cwd: _cwd,
        );
        _applySetupResult(result);
        return existingSessionId;
      }
      if (caps.loadSession) {
        final result = await _loadExistingSession(existingSessionId);
        if (result != null) {
          _clearHistoryUnavailableWarning();
          _applySetupResult(result);
        }
        return existingSessionId;
      }
      if (_freshBridge) {
        throw const AcpUnsupportedCapabilityException('session/load');
      }
      // Neither resume nor load is advertised. An existing bridge still owns
      // the live provider session, so reconnect can safely retain its id.
      return existingSessionId;
    } on _LaunchException {
      rethrow;
    } on AcpRemoteException catch (error) {
      if (existingSessionId != null &&
          _isAcpSessionAlreadyLoadedError(error, existingSessionId)) {
        _diagnostics.info(
          'acp.session',
          'already_loaded_reused',
          fields: {'setupMethod': 'resume'},
        );
        _historyRestoreUnavailable = true;
        return existingSessionId;
      }
      if (init.authMethods.isNotEmpty && error.code == -32000) {
        _update(
          (s) => s.copyWith(
            status: AcpConnectionStatus.authenticationRequired,
            pendingAuthentication: true,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.authenticationRequired,
              message: 'The agent requires authentication.',
            ),
          ),
        );
        throw _LaunchException(
          _key,
          const AcpSessionError(
            kind: AcpSessionErrorKind.authenticationRequired,
            message: 'The agent requires authentication.',
          ),
        );
      }
      throw _LaunchException(
        _key,
        AcpSessionError(
          kind: AcpSessionErrorKind.protocol,
          message: _safeAcpRemoteError(error.code, error.message),
        ),
      );
    } on Object catch (error) {
      throw _LaunchException(_key, _mapClientError(error));
    }
  }

  Future<AcpSessionSetupResult?> _loadExistingSession(String sessionId) async {
    try {
      return await attachment.client.loadSession(
        sessionId: sessionId,
        cwd: _cwd,
      );
    } on AcpRemoteException catch (error) {
      if (!_isAcpSessionAlreadyLoadedError(error, sessionId)) rethrow;
      _diagnostics.info(
        'acp.session',
        'already_loaded_reused',
        fields: {'setupMethod': 'load'},
      );
      _historyRestoreUnavailable = true;
      return null;
    }
  }

  void _clearHistoryUnavailableWarning() {
    if (_state.warning?.kind == AcpSessionErrorKind.historyUnavailable) {
      _update((state) => state.copyWith(clearWarning: true));
    }
  }

  void _applyHistoryUnavailableWarningIfNeeded() {
    if (!_historyRestoreUnavailable ||
        _timelineBuilder.snapshot().entries.isNotEmpty) {
      return;
    }
    _update(
      (state) => state.copyWith(
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.historyUnavailable,
          message: 'Earlier messages could not be restored in this view.',
        ),
      ),
    );
  }

  void _applySetupResult(AcpSessionSetupResult result) {
    _update(
      (s) => s.copyWith(
        modeState: result.modes,
        modelState: result.models,
        configOptions: result.configOptions.isEmpty
            ? s.configOptions
            : _bounded(result.configOptions, _maxSessionListEntries),
      ),
    );
  }

  void _subscribeTransport() {
    _transportSub = attachment.transportStates.listen(_onTransportState);
    _transportErrorSub = attachment.transportErrors.listen(_onTransportError);
  }

  void _subscribeSessionStreams() {
    _subscribeSessionNotifications();
    _subscribeCapabilityRequests();
  }

  void _subscribeSessionNotifications() {
    _updatesSub?.cancel();
    _updatesSub = attachment.notifications
        .where((notification) => notification.sessionId == _key.acpSessionId)
        .listen(_onSessionUpdate);
  }

  void _subscribeCapabilityRequests() {
    _capabilityRequestsSub?.cancel();
    // The capability service (not this controller) is the sole subscriber of
    // `serverRequests`: it is the only place that answers fs/terminal/
    // permission requests, so there is exactly one responder per request.
    // This controller only mirrors the shared registry's current pending
    // requests for this session into UI-facing state.
    final capabilityService = attachment.capabilityService;
    if (capabilityService != null) {
      _onCapabilityRequestsChanged(capabilityService.registry.requests);
      _capabilityRequestsSub = capabilityService.registry.changes.listen(
        _onCapabilityRequestsChanged,
      );
    }
  }

  void _onSessionUpdate(AcpSessionNotification notification) {
    _pendingSessionUpdates.addLast(notification);
    _sessionUpdatesEnqueued += 1;
    _scheduleSessionUpdatePump();
  }

  void _scheduleSessionUpdatePump() {
    if (_sessionUpdatePumpFuture != null || _disposed) return;
    // Defer one microtask so a synchronous replay burst coalesces into this
    // bounded queue instead of doing all timeline work inside the transport's
    // stream callback.
    _sessionUpdatePumpFuture = Future<void>.microtask(_pumpSessionUpdates);
  }

  Future<void> _pumpSessionUpdates() async {
    // Bound this pump to the notifications present when it starts. Updates
    // arriving from a still-running turn form the next pump, so reconnect can
    // await its replay high-water mark without starving on live output.
    final targetAppliedCount = _sessionUpdatesEnqueued;
    final burst = Stopwatch()..start();
    var updateCount = 0;
    var yieldCount = 0;
    _coalescingSessionUpdateNotifications = true;
    try {
      while (_sessionUpdatesApplied < targetAppliedCount &&
          _pendingSessionUpdates.isNotEmpty &&
          !_disposed) {
        final turn = Stopwatch()..start();
        var turnCount = 0;
        do {
          final queued = _removeNextSessionUpdate();
          _applySessionUpdate(queued.notification, notifyManager: false);
          _sessionUpdatesApplied += queued.consumedCount;
          updateCount += queued.consumedCount;
          turnCount += 1;
        } while (_sessionUpdatesApplied < targetAppliedCount &&
            _pendingSessionUpdates.isNotEmpty &&
            turnCount < _sessionUpdateTurnMaxCount &&
            turn.elapsed < _sessionUpdateTurnTimeBudget);
        if (_sessionUpdatesApplied < targetAppliedCount) {
          yieldCount += 1;
          await Future<void>.delayed(Duration.zero);
        }
      }
      // Apply replay chronologically off-screen for protocol correctness, then
      // publish one complete immutable snapshot. The first transcript frame can
      // therefore mount the final tail instead of visibly walking from the
      // oldest history toward the newest message.
    } finally {
      _coalescingSessionUpdateNotifications = false;
      if ((updateCount > 0 || _managerNotificationPending) && !_disposed) {
        if (_historyReplayPublicationHeld) {
          _managerNotificationPending = true;
        } else {
          _managerNotificationPending = false;
          _manager._onControllerChanged(this);
        }
      }
      _sessionUpdatePumpFuture = null;
      if (_pendingSessionUpdates.isNotEmpty && !_disposed) {
        _scheduleSessionUpdatePump();
      }
      if (yieldCount > 0) {
        _diagnostics.debug(
          'acp.session',
          'update_burst_drained',
          fields: {
            'updateCount': updateCount,
            'yieldCount': yieldCount,
            'durationMs': burst.elapsedMilliseconds,
          },
        );
      }
    }
  }

  ({AcpSessionNotification notification, int consumedCount})
  _removeNextSessionUpdate() {
    final first = _pendingSessionUpdates.removeFirst();
    if (!_historyReplayPublicationHeld ||
        first.update is! AcpContentChunkUpdate ||
        (first.update as AcpContentChunkUpdate).content is! AcpTextContent) {
      return (notification: first, consumedCount: 1);
    }

    final firstUpdate = first.update as AcpContentChunkUpdate;
    final firstText = firstUpdate.content as AcpTextContent;
    final text = StringBuffer(firstText.text);
    var consumedCount = 1;
    while (_pendingSessionUpdates.isNotEmpty) {
      final next = _pendingSessionUpdates.first;
      if (!_canCoalesceReplayText(first, next)) break;
      final nextText =
          ((next.update as AcpContentChunkUpdate).content as AcpTextContent)
              .text;
      if (text.length + nextText.length > _maxCoalescedReplayTextChars) break;
      _pendingSessionUpdates.removeFirst();
      text.write(nextText);
      consumedCount += 1;
    }
    if (consumedCount == 1) {
      return (notification: first, consumedCount: 1);
    }
    return (
      notification: AcpSessionNotification(
        sessionId: first.sessionId,
        update: AcpContentChunkUpdate(
          kind: firstUpdate.kind,
          content: AcpTextContent(
            text.toString(),
            annotations: firstText.annotations,
            meta: firstText.meta,
            extensions: firstText.extensions,
          ),
          messageId: firstUpdate.messageId,
          meta: firstUpdate.meta,
          extensions: firstUpdate.extensions,
        ),
        meta: first.meta,
        extensions: first.extensions,
      ),
      consumedCount: consumedCount,
    );
  }

  bool _canCoalesceReplayText(
    AcpSessionNotification first,
    AcpSessionNotification next,
  ) {
    if (first.sessionId != next.sessionId) return false;
    final firstUpdate = first.update;
    final nextUpdate = next.update;
    if (firstUpdate is! AcpContentChunkUpdate ||
        nextUpdate is! AcpContentChunkUpdate ||
        firstUpdate.kind != nextUpdate.kind ||
        firstUpdate.messageId != nextUpdate.messageId ||
        firstUpdate.content is! AcpTextContent ||
        nextUpdate.content is! AcpTextContent) {
      return false;
    }
    final firstText = firstUpdate.content as AcpTextContent;
    final nextText = nextUpdate.content as AcpTextContent;
    const equality = DeepCollectionEquality();
    return equality.equals(first.meta, next.meta) &&
        equality.equals(first.extensions, next.extensions) &&
        equality.equals(firstUpdate.meta, nextUpdate.meta) &&
        equality.equals(firstUpdate.extensions, nextUpdate.extensions) &&
        equality.equals(
          firstText.annotations?.toJson(),
          nextText.annotations?.toJson(),
        ) &&
        equality.equals(firstText.meta, nextText.meta) &&
        equality.equals(firstText.extensions, nextText.extensions);
  }

  void _scheduleRecentPersistence() {
    _recentPersistTimer?.cancel();
    _recentPersistTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_manager._recordRecent(_state)),
    );
  }

  void _finishHistoryReplayPublication() {
    if (!_historyReplayPublicationHeld) return;
    _state = _state.copyWith(timeline: _timelineBuilder.snapshot());
    _historyReplayPublicationHeld = false;
  }

  Future<void> _drainHistoryReplayNotifications() async {
    var stableTurns = 0;
    for (var turn = 0; turn < 64 && stableTurns < 2; turn++) {
      await Future<void>.delayed(Duration.zero);
      final pump = _sessionUpdatePumpFuture;
      if (pump != null) await pump;
      final appliedThroughHighWater =
          _sessionUpdatesApplied == _sessionUpdatesEnqueued &&
          _pendingSessionUpdates.isEmpty &&
          _sessionUpdatePumpFuture == null;
      if (appliedThroughHighWater) {
        stableTurns += 1;
      } else {
        stableTurns = 0;
      }
    }
  }

  void _applySessionUpdate(
    AcpSessionNotification notification, {
    bool notifyManager = true,
  }) {
    final update = notification.update;
    final timeline = _timelineBuilder.apply(
      update,
      createSnapshot: !_historyReplayPublicationHeld,
    );
    _update((s) {
      var next = s.copyWith(lastActivityAt: _clock());
      if (timeline != null) next = next.copyWith(timeline: timeline);
      switch (update) {
        case AcpPlanUpdate(:final entries):
          next = next.copyWith(plan: _bounded(entries, _maxSessionListEntries));
        case AcpAvailableCommandsUpdate(:final commands):
          next = next.copyWith(
            availableCommands: _bounded(commands, _maxSessionListEntries),
          );
        case AcpConfigOptionsUpdate(:final options):
          next = next.copyWith(
            configOptions: _bounded(options, _maxSessionListEntries),
          );
        case AcpUsageUpdate():
          next = next.copyWith(usage: update);
        case AcpCurrentModeUpdate(:final modeId):
          final modes = next.modeState;
          if (modes != null) {
            next = next.copyWith(
              modeState: AcpSessionModeState(
                currentModeId: modeId,
                availableModes: modes.availableModes,
                meta: modes.meta,
                extensions: modes.extensions,
              ),
            );
          }
        case AcpCurrentModelUpdate(:final modelId):
          final models = next.modelState;
          if (models != null) {
            next = next.copyWith(
              modelState: AcpModelState(
                currentModelId: modelId,
                availableModels: models.availableModels,
                meta: models.meta,
                extensions: models.extensions,
              ),
            );
          }
        case AcpSessionInfoUpdate(:final hasTitle, :final title):
          if (hasTitle) {
            next = title == null
                ? next.copyWith(clearTitle: true)
                : next.copyWith(title: title);
          }
        case AcpContentChunkUpdate():
        case AcpToolCallUpdate():
        case AcpUnknownSessionUpdate():
          break;
      }
      return next;
    }, notifyManager: notifyManager);
    _scheduleRecentPersistence();
  }

  static List<T> _bounded<T>(List<T> values, int maxLength) =>
      values.length <= maxLength
      ? values
      : values.sublist(values.length - maxLength);

  /// Mirrors the shared capability registry's pending requests that belong to
  /// this ACP session into UI-facing [AcpSessionState] snapshots.
  ///
  /// This is the single place pending permissions/writes are derived: the
  /// registry (owned by the bridge attachment's capability service) is the
  /// only live responder, so there is nothing left to deduplicate here beyond
  /// filtering by session id.
  void _onCapabilityRequestsChanged(
    List<cap.AcpPendingClientRequest> requests,
  ) {
    final permissions = <AcpPendingPermission>[];
    final writes = <AcpPendingWrite>[];
    for (final request in requests) {
      if (request.sessionId != _key.acpSessionId) continue;
      switch (request) {
        case cap.AcpPendingPermission(:final permission):
          final toolTitle = permission.toolCall.title?.trim();
          permissions.add(
            AcpPendingPermission(
              requestKey: request.id,
              sessionId: request.sessionId,
              toolCallId: permission.toolCall.toolCallId,
              toolTitle: toolTitle?.isEmpty ?? true ? null : toolTitle,
              options: permission.options,
              requestedAt: request.requestedAt,
            ),
          );
        case cap.AcpPendingFileWrite(:final path, :final content):
          writes.add(
            AcpPendingWrite(
              requestKey: request.id,
              sessionId: request.sessionId,
              path: path,
              contentByteLength: utf8.encode(content).length,
              requestedAt: request.requestedAt,
            ),
          );
      }
    }
    _update(
      (s) => s.copyWith(pendingPermissions: permissions, pendingWrites: writes),
    );
  }

  Future<void> respondToPermission(String requestKey, String optionId) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.selectPermission(requestKey, optionId);
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'selected'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'selected');
  }

  Future<void> cancelPermission(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.cancelPermission(requestKey);
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'cancelled'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'cancelled');
  }

  String? pendingWriteContent(String requestKey) =>
      attachment.capabilityService?.pendingWriteContent(requestKey);

  Future<void> approveWrite(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.approveWrite(requestKey);
    _diagnostics.debug(
      'acp.session',
      'write_resolved',
      fields: {'outcome': 'approved'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'write_approved');
  }

  Future<void> rejectWrite(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.rejectWrite(requestKey);
    _diagnostics.debug(
      'acp.session',
      'write_resolved',
      fields: {'outcome': 'rejected'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'write_rejected');
  }

  Future<AcpPromptResult> prompt(List<AcpContentBlock> content) {
    if (_disposed) {
      return Future<AcpPromptResult>.error(
        const AcpConnectionClosedException(),
      );
    }
    final snapshot = List<AcpContentBlock>.unmodifiable(content);
    final encodedBytes = utf8
        .encode(jsonEncode(snapshot.map((block) => block.toJson()).toList()))
        .length;
    final pendingCount =
        _promptQueue.length + (_promptActive || _detachedTurnInFlight ? 1 : 0);
    if (pendingCount >= acpPromptQueueMaxCount ||
        _queuedPromptBytes + encodedBytes > acpPromptQueueMaxBytes) {
      return Future<AcpPromptResult>.error(const AcpPromptQueueFullException());
    }

    final queuedBehindTurn =
        _promptActive || _detachedTurnInFlight || _promptQueue.isNotEmpty;
    final localMessageId = _timelineBuilder.appendLocalUserPrompt(
      snapshot,
      queued: queuedBehindTurn,
    );
    final queued = _QueuedAcpPrompt(
      content: snapshot,
      localMessageId: localMessageId,
      encodedBytes: encodedBytes,
    );
    _promptQueue.addLast(queued);
    _queuedPromptBytes += encodedBytes;
    _update(
      (s) => s.copyWith(
        clearLastStopReason: true,
        lastActivityAt: _clock(),
        timeline: _timelineBuilder.snapshot(),
      ),
    );
    unawaited(_drainPromptQueue());
    return queued.completer.future;
  }

  Future<void> _drainPromptQueue() async {
    if (_promptActive || _detachedTurnInFlight || _disposed) {
      return;
    }
    _promptActive = true;
    try {
      while (_promptQueue.isNotEmpty &&
          !_disposed &&
          !_detachedTurnInFlight &&
          _holdsAttachment &&
          _state.attached) {
        final queued = _promptQueue.removeFirst();
        _queuedPromptBytes -= queued.encodedBytes;
        final dispatchedTimeline = _timelineBuilder
            .markLocalUserPromptDispatched(queued.localMessageId);
        _update(
          (s) => s.copyWith(
            promptStatus: AcpPromptStatus.streaming,
            clearLastStopReason: true,
            clearError: true,
            lastActivityAt: _clock(),
            timeline: dispatchedTimeline,
          ),
        );
        final promptAttachment = attachment;
        try {
          final result = await promptAttachment.client.prompt(
            sessionId: _key.acpSessionId,
            content: queued.content,
          );
          _update(
            (s) => s.copyWith(
              promptStatus: AcpPromptStatus.idle,
              lastStopReason: result.stopReason,
              lastActivityAt: _clock(),
            ),
          );
          if (!queued.completer.isCompleted) {
            queued.completer.complete(result);
          }
        } on Object catch (error, stackTrace) {
          final detachedInFlight =
              !identical(attachment, promptAttachment) ||
              !_holdsAttachment ||
              !_state.attached ||
              _state.status == AcpConnectionStatus.detached;
          if (detachedInFlight) {
            _diagnostics.info(
              'acp.session',
              'prompt_detached_in_flight',
              fields: {'queuedPromptCount': _promptQueue.length},
            );
            if (!queued.completer.isCompleted) {
              queued.completer.completeError(error, stackTrace);
            }
            continue;
          }
          final rolledBackTimeline = _timelineBuilder.removeLocalUserPrompt(
            queued.localMessageId,
          );
          final mapped = _mapClientError(error);
          _update(
            (s) => s.copyWith(
              status: mapped.kind == AcpSessionErrorKind.authenticationRequired
                  ? AcpConnectionStatus.authenticationRequired
                  : s.status,
              pendingAuthentication:
                  mapped.kind == AcpSessionErrorKind.authenticationRequired,
              promptStatus: AcpPromptStatus.idle,
              error: mapped,
              timeline: rolledBackTimeline,
            ),
          );
          if (!queued.completer.isCompleted) {
            queued.completer.completeError(error, stackTrace);
          }
        }
      }
    } finally {
      _promptActive = false;
    }
  }

  Future<void> cancelPrompt() async {
    _update((s) => s.copyWith(promptStatus: AcpPromptStatus.cancelling));
    await attachment.client.cancel(_key.acpSessionId);
  }

  Future<void> setAutoApprovePermissions({required bool enabled}) async {
    if (_autoApprovePermissions == enabled) return;
    _autoApprovePermissions = enabled;
    attachment.capabilityService?.setSessionAutoApprovePermissions(
      _key.acpSessionId,
      enabled: enabled,
    );
    _update((state) => state.copyWith(autoApprovePermissions: enabled));
  }

  Future<void> setConfigOption({
    required String configId,
    required Object value,
  }) async {
    final options = await attachment.client.setConfigOption(
      sessionId: _key.acpSessionId,
      configId: configId,
      value: value,
    );
    if (options.isNotEmpty) {
      _update((s) => s.copyWith(configOptions: options));
    }
  }

  Future<void> setMode(String modeId) async {
    await attachment.client.setMode(
      sessionId: _key.acpSessionId,
      modeId: modeId,
    );
    final modes = _state.modeState;
    if (modes != null) {
      _update(
        (s) => s.copyWith(
          modeState: AcpSessionModeState(
            currentModeId: modeId,
            availableModes: modes.availableModes,
            meta: modes.meta,
            extensions: modes.extensions,
          ),
        ),
      );
    }
  }

  Future<void> setModel(String modelId) async {
    await attachment.client.setModel(
      sessionId: _key.acpSessionId,
      modelId: modelId,
    );
  }

  Future<void> closeRemoteSession() async {
    try {
      await attachment.client.closeSession(_key.acpSessionId);
    } on AcpUnsupportedCapabilityException {
      // Closing is optional; ignore when unsupported.
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.session',
        'close_failed',
        fields: {'errorType': error.runtimeType},
      );
      rethrow;
    }
  }

  Future<void> deleteRemoteSession() async {
    try {
      await attachment.client.deleteSession(_key.acpSessionId);
    } on AcpUnsupportedCapabilityException {
      // Deleting is optional; ignore when unsupported.
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.session',
        'delete_failed',
        fields: {'errorType': error.runtimeType},
      );
      rethrow;
    }
  }

  Future<AcpSessionLaunchResult> fork() async {
    try {
      final result = await attachment.client.forkSession(
        sessionId: _key.acpSessionId,
        cwd: _cwd,
      );
      final newId = result.sessionId;
      if (newId == null || newId.isEmpty) {
        return AcpSessionLaunchFailed(
          _key,
          const AcpSessionError(
            kind: AcpSessionErrorKind.protocol,
            message: 'The agent did not return a forked session id.',
          ),
        );
      }
      final forkController = _SessionController(
        manager: _manager,
        attachment: attachment,
        providerLabel: _providerLabel,
        isCustomProvider: _isCustomProvider,
        cwd: _cwd,
        clock: _clock,
        diagnostics: _diagnostics,
        autoApprovePermissions: _autoApprovePermissions,
        freshBridge: false,
        detachedTurnPollInterval: _detachedTurnPollInterval,
      ).._acquireLease(attachment);
      final key = await forkController.adoptForked(
        hostId: _key.hostId,
        providerId: _key.providerId,
        bridgeId: _key.bridgeId,
        acpSessionId: newId,
        setupResult: result,
      );
      _manager._controllers[key.value] = forkController;
      _manager
        .._select(key.value)
        .._emit();
      await _manager._recordRecent(forkController.state);
      return AcpSessionLaunchStarted(key);
    } on AcpUnsupportedCapabilityException {
      return AcpSessionLaunchFailed(
        _key,
        const AcpSessionError(
          kind: AcpSessionErrorKind.unsupportedCapability,
          message: 'This agent does not support forking sessions.',
        ),
      );
    } on Object catch (error) {
      return AcpSessionLaunchFailed(_key, _mapClientError(error));
    }
  }

  /// Adopts an already-forked session id onto a fresh controller that shares
  /// the parent's bridge attachment.
  Future<AcpSessionKey> adoptForked({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
    required AcpSessionSetupResult setupResult,
  }) async {
    final now = _clock();
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );
    _state = AcpSessionState(
      key: _key,
      providerLabel: _providerLabel,
      isCustomProvider: _isCustomProvider,
      cwd: _cwd,
      status: AcpConnectionStatus.ready,
      autoApprovePermissions: _autoApprovePermissions,
      createdAt: now,
      lastActivityAt: now,
      initialization: attachment.initialization,
      authMethods: attachment.initialization?.authMethods ?? const [],
    );
    attachment.capabilityService?.setSessionAutoApprovePermissions(
      acpSessionId,
      enabled: _autoApprovePermissions,
    );
    _applySetupResult(setupResult);
    _subscribeTransport();
    _subscribeSessionStreams();
    return _key;
  }

  /// Detaches locally while leaving the remote bridge running.
  ///
  /// Idempotent: calling it again after the session is already detached (or has
  /// no lease) is a no-op and never decrements the shared attachment's
  /// reference count a second time. A detached original therefore can never
  /// stop a bridge still used by a fork.
  Future<void> detach() async {
    if (!_holdsAttachment) return;
    _stopDetachedTurnMonitor();
    _update(
      (s) => s.copyWith(status: AcpConnectionStatus.detached, attached: false),
    );
    await _cancelSubscriptions();
    final closed = await _releaseLease();
    _diagnostics.info(
      'acp.session',
      'detached',
      fields: {'bridgeReleased': closed},
    );
  }

  /// Re-attaches a detached session and resumes/loads it.
  ///
  /// Replaces a terminally failed or closed attachment with a fresh one,
  /// cancels any stale subscriptions before resubscribing, balances the
  /// attachment lease, and surfaces failures as a typed [_LaunchException]
  /// after recording safe error state — it never throws a raw error.
  Future<void> reconnect({
    required MonkeyMuxAcpBridgeMetadata remoteBridge,
  }) async {
    final wasDetached = _state.status == AcpConnectionStatus.detached;
    _stopDetachedTurnMonitor();
    // Captured before this controller's own lease is released: a solo
    // (non-forked) session's soft detach closes its bridge attachment, which
    // only *stops routing* new server requests locally (see
    // `_BridgeAttachment._performClose`) — it never cancels the capability
    // service's registry. Carrying that same registry into the replacement
    // attachment below preserves any still-pending permission/write
    // decisions across the detach instead of silently discarding them in
    // favor of a fresh, empty registry.
    final priorCapabilityService = wasDetached
        ? attachment.capabilityService
        : null;
    final priorRegistry = priorCapabilityService?.registry;
    final priorInitialization =
        attachment.initialization ?? _state.initialization;

    // Discard any stale subscriptions and lease left over from a previous
    // (possibly failed) attempt so retries start clean and balanced.
    await _cancelSubscriptions();
    await _releaseLease();

    final hostId = _key.hostId;
    final providerId = _key.providerId;
    final bridgeId = _key.bridgeId;
    final sessionId = _key.acpSessionId;
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );

    final existing = _manager._attachments[bridgeKey.value];
    final _BridgeAttachment target;
    if (existing != null && !existing.isTerminated) {
      target = existing;
    } else {
      if (existing != null) {
        _manager._attachments.remove(bridgeKey.value);
        if (priorCapabilityService == null) {
          await existing.forceClose();
        }
      }
      target = _BridgeAttachment(
        bridgeKey: bridgeKey,
        providerId: providerId,
        session: _manager._connector.connect(
          hostId: hostId,
          bridgeId: bridgeId,
          providerId: providerId,
          lastAcknowledgedSequence: _lastAcknowledgedBridgeSequence,
        ),
        capabilityServiceFactory: _manager._capabilityServiceFactory(
          hostId: hostId,
          cwd: _cwd,
          autoApprovePermissions: _autoApprovePermissions,
          existingRegistry: priorRegistry,
        ),
        initialization: priorInitialization,
        capabilityService: priorCapabilityService,
      );
      _manager._attachments[bridgeKey.value] = target;
    }
    _acquireLease(target);

    _update(
      (s) => s.copyWith(
        status: AcpConnectionStatus.connecting,
        attached: true,
        clearError: true,
      ),
    );
    try {
      _subscribeTransport();
      final init = await attachment.ensureInitialized();
      _update((s) => s.copyWith(initialization: init));
      // Subscribe before any replay so detached notifications are retained.
      _subscribeSessionStreams();
      final detachedTurnRunning =
          wasDetached && remoteBridge.inFlightTurnCount > 0;
      _historyRestoreUnavailable = false;
      if (!detachedTurnRunning) {
        _historyReplayPublicationHeld = true;
        try {
          await _establishSession(sessionId, init);
          await _drainHistoryReplayNotifications();
          _applyHistoryUnavailableWarningIfNeeded();
        } finally {
          _finishHistoryReplayPublication();
        }
      }
      _update(
        (s) => s.copyWith(
          status: AcpConnectionStatus.ready,
          promptStatus: detachedTurnRunning
              ? AcpPromptStatus.streaming
              : AcpPromptStatus.idle,
          clearError: true,
        ),
      );
      if (detachedTurnRunning) {
        _startDetachedTurnMonitor();
      } else {
        unawaited(_drainPromptQueue());
      }
      _manager._telemetry.reconnectOutcome(succeeded: true);
    } on Object catch (error) {
      final mapped = error is _LaunchException
          ? error.error
          : _mapClientError(error);
      _update(
        (s) => s.copyWith(
          status: AcpConnectionStatus.failed,
          attached: false,
          error: mapped,
        ),
      );
      _stopDetachedTurnMonitor();
      await _cancelSubscriptions();
      await _releaseLease();
      _manager._telemetry.reconnectOutcome(
        succeeded: false,
        failureCategory: mapped.kind.name,
      );
      throw _LaunchException(_key, mapped);
    }
  }

  void _startDetachedTurnMonitor() {
    _stopDetachedTurnMonitor();
    _detachedTurnInFlight = true;
    final generation = _detachedTurnMonitorGeneration;
    _scheduleDetachedTurnStatusPoll(generation);
  }

  void _scheduleDetachedTurnStatusPoll(int generation) {
    if (_disposed ||
        generation != _detachedTurnMonitorGeneration ||
        !_holdsAttachment ||
        !_state.attached) {
      return;
    }
    _detachedTurnStatusTimer = Timer(
      _detachedTurnPollInterval,
      () => unawaited(_pollDetachedTurnStatus(generation)),
    );
  }

  Future<void> _pollDetachedTurnStatus(int generation) async {
    if (_disposed ||
        generation != _detachedTurnMonitorGeneration ||
        !_holdsAttachment ||
        !_state.attached) {
      return;
    }
    try {
      final status = await _manager._connector.bridgeStatus(
        _key.hostId,
        _key.bridgeId,
      );
      if (_disposed || generation != _detachedTurnMonitorGeneration) return;
      if (status.inFlightTurnCount > 0) {
        _scheduleDetachedTurnStatusPoll(generation);
        return;
      }
      final init = attachment.initialization;
      if (init != null) {
        try {
          await _establishSession(_key.acpSessionId, init);
        } on Object catch (error) {
          // The remote turn is already complete and the session is usable.
          // Missing setup controls are preferable to disrupting or failing it.
          _diagnostics.debug(
            'acp.session',
            'detached_setup_refresh_failed',
            fields: {'errorType': error.runtimeType},
          );
        }
      }
      if (_disposed || generation != _detachedTurnMonitorGeneration) return;
      _stopDetachedTurnMonitor();
      _update(
        (s) => s.copyWith(
          promptStatus: AcpPromptStatus.idle,
          lastActivityAt: _clock(),
        ),
      );
      _diagnostics.info(
        'acp.session',
        'detached_turn_complete',
        fields: {'queuedPromptCount': _promptQueue.length},
      );
      unawaited(_drainPromptQueue());
    } on Object catch (error) {
      _diagnostics.debug(
        'acp.session',
        'detached_turn_status_retry',
        fields: {'errorType': error.runtimeType},
      );
      _scheduleDetachedTurnStatusPoll(generation);
    }
  }

  void _stopDetachedTurnMonitor() {
    _detachedTurnInFlight = false;
    _detachedTurnMonitorGeneration++;
    _detachedTurnStatusTimer?.cancel();
    _detachedTurnStatusTimer = null;
  }

  void _onTransportState(MonkeyMuxAcpTransportState transportState) {
    _update((s) {
      var next = s.copyWith(transportState: transportState);
      switch (transportState.status) {
        case MonkeyMuxAcpTransportStatus.connecting:
          break;
        case MonkeyMuxAcpTransportStatus.connected:
          if (s.status == AcpConnectionStatus.reconnecting) {
            next = next.copyWith(status: AcpConnectionStatus.ready);
          }
        case MonkeyMuxAcpTransportStatus.reconnecting:
          if (s.attached) {
            next = next.copyWith(status: AcpConnectionStatus.reconnecting);
          }
        case MonkeyMuxAcpTransportStatus.providerExited:
          attachment.markTerminated();
          next = next.copyWith(
            status: AcpConnectionStatus.providerExited,
            attached: false,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.providerExited,
              message: 'The remote agent process exited.',
            ),
          );
          _manager._telemetry.sessionEnded(reason: 'provider_exited');
        case MonkeyMuxAcpTransportStatus.failed:
          attachment.markTerminated();
          next = next.copyWith(
            status: AcpConnectionStatus.failed,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.transport,
              message: 'The agent connection failed.',
            ),
          );
          _manager._telemetry.sessionEnded(reason: 'transport_failed');
        case MonkeyMuxAcpTransportStatus.closed:
          if (s.status != AcpConnectionStatus.detached) {
            next = next.copyWith(status: AcpConnectionStatus.closed);
          }
      }
      return next;
    });
    switch (transportState.status) {
      case MonkeyMuxAcpTransportStatus.providerExited:
      case MonkeyMuxAcpTransportStatus.failed:
      case MonkeyMuxAcpTransportStatus.closed:
        // The transport is confirmed gone (not merely reconnecting): release
        // local subscriptions and the attachment lease so terminals and
        // stream listeners never leak. This never stops an unrelated bridge:
        // it only releases this controller's own lease, and the shared
        // attachment only closes once every session leasing it has done so.
        unawaited(_cleanUpAfterTerminalTransport());
      case MonkeyMuxAcpTransportStatus.connecting:
      case MonkeyMuxAcpTransportStatus.connected:
      case MonkeyMuxAcpTransportStatus.reconnecting:
        break;
    }
  }

  Future<void> _cleanUpAfterTerminalTransport() async {
    _stopDetachedTurnMonitor();
    await _cancelSubscriptions();
    await _releaseLease();
  }

  void _onTransportError(MonkeyMuxAcpBridgeException error) {
    // A replay-buffer overflow is a non-fatal warning: older history could
    // not be replayed, but the session remains usable. Preserve it in `warning`,
    // distinct from a fatal `error`, and never change connection status.
    if (error.kind == MonkeyMuxAcpBridgeErrorKind.replayOverflow) {
      _update(
        (s) => s.copyWith(
          warning: const AcpSessionError(
            kind: AcpSessionErrorKind.replayOverflow,
            message:
                'Some earlier history exceeds the session replay buffer. '
                'You can continue, but the missing portion cannot be restored '
                'in this view.',
          ),
        ),
      );
      _diagnostics.info(
        'acp.session',
        'replay_overflow',
        fields: {'attached': _state.attached},
      );
      return;
    }
    final kind = switch (error.kind) {
      MonkeyMuxAcpBridgeErrorKind.providerExited ||
      MonkeyMuxAcpBridgeErrorKind.providerUnavailable =>
        AcpSessionErrorKind.providerExited,
      MonkeyMuxAcpBridgeErrorKind.helperUnavailable ||
      MonkeyMuxAcpBridgeErrorKind.helperProcess ||
      MonkeyMuxAcpBridgeErrorKind.unsupportedVersion =>
        AcpSessionErrorKind.bridgeUnavailable,
      _ => AcpSessionErrorKind.transport,
    };
    _update(
      (s) => s.copyWith(
        error: AcpSessionError(
          kind: kind,
          message: 'The agent connection reported an error.',
        ),
      ),
    );
  }

  Future<void> disposeLocal({bool permanent = true}) async {
    if (_disposed) return;
    _disposed = true;
    _recentPersistTimer?.cancel();
    _recentPersistTimer = null;
    _stopDetachedTurnMonitor();
    while (_promptQueue.isNotEmpty) {
      final queued = _promptQueue.removeFirst();
      if (!queued.completer.isCompleted) {
        queued.completer.completeError(const AcpConnectionClosedException());
      }
    }
    _queuedPromptBytes = 0;
    await _cancelSubscriptions();
    // Release the local lease exactly once (a no-op if already detached).
    // Explicit stop/delete uses permanent cleanup and answers pending requests;
    // app/provider teardown uses soft cleanup so MonkeyMux keeps the remote
    // session and in-flight turn alive for the next process attachment.
    await _releaseLease(permanent: permanent);
    if (_state.status != AcpConnectionStatus.detached) {
      _state = _state.copyWith(
        status: AcpConnectionStatus.closed,
        attached: false,
      );
    }
  }

  Future<void> _cancelSubscriptions() async {
    await _updatesSub?.cancel();
    _pendingSessionUpdates.clear();
    _sessionUpdatesApplied = _sessionUpdatesEnqueued;
    final updatePump = _sessionUpdatePumpFuture;
    if (updatePump != null) await updatePump;
    _pendingSessionUpdates.clear();
    _sessionUpdatesApplied = _sessionUpdatesEnqueued;
    await _capabilityRequestsSub?.cancel();
    await _transportSub?.cancel();
    await _transportErrorSub?.cancel();
    _updatesSub = null;
    _capabilityRequestsSub = null;
    _transportSub = null;
    _transportErrorSub = null;
  }

  void _update(
    AcpSessionState Function(AcpSessionState) transform, {
    AcpSessionKey? key,
    bool notifyManager = true,
  }) {
    _state = transform(_state);
    // Rebuild under a new identity through the single copyWith path so no
    // field can ever be silently dropped when the key changes.
    if (key != null && key != _state.key) {
      _state = _state.copyWith(key: key);
    }
    if (notifyManager) {
      if (_coalescingSessionUpdateNotifications ||
          _historyReplayPublicationHeld) {
        _managerNotificationPending = true;
      } else {
        _managerNotificationPending = false;
        _manager._onControllerChanged(this);
      }
    }
  }

  AcpSessionError _mapClientError(Object error) => switch (error) {
    AcpUnsupportedCapabilityException() => const AcpSessionError(
      kind: AcpSessionErrorKind.unsupportedCapability,
      message: 'The agent does not support this operation.',
    ),
    AcpRequestTimeoutException() => const AcpSessionError(
      kind: AcpSessionErrorKind.timeout,
      message: 'The agent request timed out.',
    ),
    AcpProtocolException() => const AcpSessionError(
      kind: AcpSessionErrorKind.protocol,
      message: 'The agent sent invalid protocol data.',
    ),
    AcpRemoteException(:final message)
        when _isAcpAuthenticationRequired(message) =>
      const AcpSessionError(
        kind: AcpSessionErrorKind.authenticationRequired,
        message: 'The agent requires authentication.',
      ),
    AcpRemoteException(:final code, :final message) => AcpSessionError(
      kind: AcpSessionErrorKind.protocol,
      message: _safeAcpRemoteError(code, message),
    ),
    AcpConnectionClosedException() => const AcpSessionError(
      kind: AcpSessionErrorKind.transport,
      message: 'The agent connection closed.',
      retryable: true,
    ),
    MonkeyMuxAcpBridgeException() => _manager._mapBridgeError(error),
    _ => const AcpSessionError(
      kind: AcpSessionErrorKind.unknown,
      message: 'The agent session encountered an error.',
    ),
  };
}

bool _isAcpSessionAlreadyLoadedError(
  AcpRemoteException error,
  String sessionId,
) {
  if (error.code != -32602 || sessionId.isEmpty) return false;
  final message = error.message.trim();
  final lower = message.toLowerCase();
  const prefix = 'session ';
  if (!lower.startsWith(prefix)) return false;
  for (final suffix in const <String>[
    ' is already loaded',
    ' is already loaded.',
    ' is already loaded!',
  ]) {
    if (!lower.endsWith(suffix)) continue;
    final namedSessionId = message.substring(
      prefix.length,
      message.length - suffix.length,
    );
    // Provider prose is case-insensitive; the opaque identity is byte-exact.
    return namedSessionId == sessionId;
  }
  return false;
}

bool _isAcpAuthenticationRequired(String message) {
  final normalized = message.trim().toLowerCase();
  return normalized.contains('authentication required') ||
      normalized.contains('not authenticated') ||
      normalized.contains('unauthorized');
}

String _safeAcpRemoteError(int code, String message) {
  final compact = message
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (compact.isEmpty) {
    return 'The agent rejected the request ($code).';
  }
  const maxChars = 180;
  final bounded = compact.length <= maxChars
      ? compact
      : '${compact.substring(0, maxChars - 1)}…';
  return 'The agent rejected the request ($code): $bounded';
}

/// Internal launch outcome union.
sealed class _LaunchOutcome {
  const _LaunchOutcome();
}

final class _ResolvedLaunch extends _LaunchOutcome {
  const _ResolvedLaunch({
    required this.providerId,
    required this.label,
    required this.argv,
    required this.isCustom,
  });

  final String providerId;
  final String label;
  final List<String> argv;
  final bool isCustom;
}

final class _LaunchError extends _LaunchOutcome {
  const _LaunchError(this.error);
  final AcpSessionError error;
}

class _LaunchException implements Exception {
  _LaunchException(this.key, this.error);
  final AcpSessionKey? key;
  final AcpSessionError error;
}

/// Provider for the production [AcpBridgeConnector].
final acpBridgeConnectorProvider = Provider<AcpBridgeConnector>((ref) {
  final bridgeService = ref.watch(monkeyMuxAcpBridgeServiceProvider);
  final sshService = ref.watch(sshServiceProvider);
  return MonkeyMuxAcpBridgeConnector(
    bridgeService: bridgeService,
    sessionResolver: (hostId) async {
      final session = sshService.getSessionsForHost(hostId).firstOrNull;
      if (session == null) {
        throw StateError('No active SSH session for host $hostId.');
      }
      return session;
    },
  );
});

/// Provider for the [AcpSessionManager].
final acpSessionManagerProvider = Provider<AcpSessionManager>((ref) {
  final manager = AcpSessionManager(
    connector: ref.watch(acpBridgeConnectorProvider),
    providerService: ref.watch(acpProviderServiceProvider),
    recentSessions: ref.watch(acpRecentSessionsServiceProvider),
    isProUnlocked: () =>
        ref.read(monetizationServiceProvider).currentState.isProUnlocked,
    telemetry: AcpTelemetryAdapter(ref.watch(telemetryServiceProvider)),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Streams the aggregate ACP session manager state.
final acpSessionManagerStateProvider = StreamProvider<AcpSessionManagerState>(
  (ref) => ref.watch(acpSessionManagerProvider).states,
);
