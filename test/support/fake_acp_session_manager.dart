// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';

class _FakeConnector extends Fake implements AcpBridgeConnector {}

class _FakeProviderService extends Fake implements AcpProviderService {}

class _FakeRecent extends Fake implements AcpRecentSessionsService {}

/// A controllable [AcpSessionManager] test double that records the UI actions
/// invoked against it and lets tests drive the aggregate state stream.
class FakeAcpSessionManager extends AcpSessionManager {
  FakeAcpSessionManager({
    List<AcpSessionState> sessions = const <AcpSessionState>[],
    this.recents = const <AcpRecentSessionRef>[],
    this.lastSelected,
    bool isProUnlocked = false,
  }) : _current = AcpSessionManagerState(sessions: sessions),
       super(
         connector: _FakeConnector(),
         providerService: _FakeProviderService(),
         recentSessions: _FakeRecent(),
         isProUnlocked: () => isProUnlocked,
       );

  AcpSessionManagerState _current;
  List<AcpRecentSessionRef> recents;
  AcpSessionKey? lastSelected;
  final StreamController<AcpSessionManagerState> _emitter =
      StreamController<AcpSessionManagerState>.broadcast();

  final List<String> stopped = <String>[];
  final List<String> detached = <String>[];
  final List<String> deleted = <String>[];
  final List<String> selected = <String>[];
  final List<({int hostId, String providerId, String cwd})> starts = [];
  final List<AcpLaunchCommand?> startLaunchOverrides = <AcpLaunchCommand?>[];
  final List<bool> startAutoApprovePermissions = <bool>[];
  final List<AcpLaunchCommand?> reconnectLaunchOverrides =
      <AcpLaunchCommand?>[];
  final List<bool> reconnectSelectOnSuccess = <bool>[];
  final List<List<AcpSessionKey>> reconnectReplaceKeys =
      <List<AcpSessionKey>>[];
  final List<MonkeyMuxAcpBridgeMetadata?> reconnectKnownBridges =
      <MonkeyMuxAcpBridgeMetadata?>[];
  final List<(String, String)> permissionResponses = <(String, String)>[];
  final List<String> cancelledPermissions = <String>[];
  final List<String> approvedWrites = <String>[];
  final List<String> rejectedWrites = <String>[];
  final List<({int hostId, String bridgeId})> releasedMuxBridges = [];
  final Map<String, String> pendingWriteContents = <String, String>{};

  /// Results returned by successive [forkSession] calls, consumed FIFO. When
  /// exhausted, a safe failure is returned.
  final List<AcpSessionLaunchResult> forkResults = <AcpSessionLaunchResult>[];
  int forkCount = 0;

  /// Result returned by [startNewSession]; defaults to a safe failure.
  AcpSessionLaunchResult startNewSessionResult = const AcpSessionLaunchFailed(
    null,
    AcpSessionError(kind: AcpSessionErrorKind.unknown, message: 'No launch.'),
  );

  /// FIFO reconnect results consumed before the fallback result/future.
  final List<AcpSessionLaunchResult> reconnectSessionResults = [];

  /// Fallback returned by [reconnectSession]; defaults to a safe failure.
  AcpSessionLaunchResult reconnectSessionResult = const AcpSessionLaunchFailed(
    null,
    AcpSessionError(kind: AcpSessionErrorKind.unknown, message: 'No resume.'),
  );

  /// Optional asynchronous reconnect result used to hold loading-state tests.
  Future<AcpSessionLaunchResult>? reconnectSessionFuture;

  /// Optional provisional state published while a reconnect is pending.
  AcpSessionState? reconnectSessionPendingState;

  /// Optional manager state installed immediately before a successful resume
  /// result is returned.
  AcpSessionState? reconnectSessionState;

  /// Remote bridges returned by [listRemoteBridges].
  List<MonkeyMuxAcpBridgeMetadata> remoteBridges = const [];

  final List<
    ({
      int hostId,
      String providerId,
      String bridgeId,
      String acpSessionId,
      String cwd,
    })
  >
  reconnects = [];

  final List<(String, Object)> configOptionSets = <(String, Object)>[];
  final List<bool> autoApprovePermissionSets = <bool>[];
  final List<String> modeSets = <String>[];
  final List<String> modelSets = <String>[];

  void emit(AcpSessionManagerState state) {
    _current = state;
    _emitter.add(state);
  }

  @override
  AcpSessionManagerState get state => _current;

  @override
  Stream<AcpSessionManagerState> get states async* {
    yield _current;
    yield* _emitter.stream;
  }

  @override
  Future<List<AcpRecentSessionRef>> loadRecentSessions() async => recents;

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listRemoteBridges(
    int hostId,
  ) async => remoteBridges;

  @override
  Future<AcpSessionKey?> loadLastSelected() async => lastSelected;

  @override
  Future<void> selectSession(AcpSessionKey key) async {
    selected.add(key.value);
  }

  @override
  Future<void> releaseSessionsForClosingMuxWindow({
    required int hostId,
    required String bridgeId,
  }) async {
    releasedMuxBridges.add((hostId: hostId, bridgeId: bridgeId));
  }

  @override
  Future<void> stopSession(AcpSessionKey key) async {
    stopped.add(key.value);
  }

  @override
  Future<void> detachSession(AcpSessionKey key) async {
    detached.add(key.value);
  }

  @override
  Future<void> deleteSession(AcpSessionKey key) async {
    deleted.add(key.value);
  }

  @override
  Future<void> respondToPermission(
    AcpSessionKey key,
    String requestKey,
    String optionId,
  ) async {
    permissionResponses.add((requestKey, optionId));
  }

  @override
  Future<void> cancelPermission(AcpSessionKey key, String requestKey) async {
    cancelledPermissions.add(requestKey);
  }

  @override
  String? pendingWriteContent(AcpSessionKey key, String requestKey) =>
      pendingWriteContents[requestKey];

  @override
  Future<void> approveWrite(AcpSessionKey key, String requestKey) async {
    approvedWrites.add(requestKey);
  }

  @override
  Future<void> rejectWrite(AcpSessionKey key, String requestKey) async {
    rejectedWrites.add(requestKey);
  }

  @override
  Future<AcpSessionLaunchResult> forkSession(AcpSessionKey key) async {
    forkCount++;
    if (forkResults.isNotEmpty) {
      return forkResults.removeAt(0);
    }
    return const AcpSessionLaunchFailed(
      null,
      AcpSessionError(
        kind: AcpSessionErrorKind.unknown,
        message: 'Fork failed.',
      ),
    );
  }

  @override
  Future<AcpSessionLaunchResult> startNewSession({
    required int hostId,
    required String providerId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    starts.add((hostId: hostId, providerId: providerId, cwd: cwd));
    startLaunchOverrides.add(launchCommandOverride);
    startAutoApprovePermissions.add(autoApprovePermissions);
    return startNewSessionResult;
  }

  @override
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
  }) async {
    reconnectLaunchOverrides.add(launchCommandOverride);
    reconnectSelectOnSuccess.add(selectOnSuccess);
    reconnectReplaceKeys.add(List<AcpSessionKey>.unmodifiable(replace));
    reconnectKnownBridges.add(knownRemoteBridge);
    reconnects.add((
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
      cwd: cwd,
    ));
    final pendingState = reconnectSessionPendingState;
    if (pendingState != null) {
      emit(
        AcpSessionManagerState(
          sessions: [
            ..._current.sessions.where(
              (session) => session.key != pendingState.key,
            ),
            pendingState,
          ],
          selectedKey: _current.selectedKey,
        ),
      );
    }
    final result = reconnectSessionResults.isNotEmpty
        ? reconnectSessionResults.removeAt(0)
        : reconnectSessionFuture == null
        ? reconnectSessionResult
        : await reconnectSessionFuture!;
    final resumedState = reconnectSessionState;
    if (resumedState != null && result is AcpSessionLaunchStarted) {
      emit(AcpSessionManagerState(sessions: [resumedState]));
    }
    return result;
  }

  @override
  Future<void> setConfigOption(
    AcpSessionKey key, {
    required String configId,
    required Object value,
  }) async {
    configOptionSets.add((configId, value));
  }

  @override
  Future<void> setAutoApprovePermissions(
    AcpSessionKey key, {
    required bool enabled,
  }) async {
    autoApprovePermissionSets.add(enabled);
  }

  @override
  Future<void> setMode(AcpSessionKey key, String modeId) async {
    modeSets.add(modeId);
  }

  @override
  Future<void> setModel(AcpSessionKey key, String modelId) async {
    modelSets.add(modelId);
  }

  @override
  Future<void> dispose() async {
    await _emitter.close();
  }
}

/// Builds a stable session key for tests.
AcpSessionKey fakeAcpKey({
  int hostId = 1,
  String providerId = 'builtin:copilot-cli',
  String bridgeId = 'bridge-1',
  String acpSessionId = 'session-1',
}) => AcpSessionKey.of(
  hostId: hostId,
  providerId: providerId,
  bridgeId: bridgeId,
  acpSessionId: acpSessionId,
);

/// Builds an in-memory session state for tests.
AcpSessionState fakeAcpSession({
  AcpSessionKey? key,
  String providerLabel = 'Copilot CLI',
  String cwd = '/home/dev/project',
  AcpConnectionStatus status = AcpConnectionStatus.ready,
  String? title,
  DateTime? lastActivityAt,
  AcpAgentCapabilities? capabilities,
  List<AcpSessionConfigOption> configOptions = const <AcpSessionConfigOption>[],
  AcpSessionModeState? modeState,
  AcpModelState? modelState,
  AcpPromptStatus promptStatus = AcpPromptStatus.idle,
  List<AcpPlanEntry> plan = const <AcpPlanEntry>[],
  List<AcpPendingPermission> pendingPermissions =
      const <AcpPendingPermission>[],
  List<AcpPendingWrite> pendingWrites = const <AcpPendingWrite>[],
  AcpTimeline timeline = const AcpTimeline.empty(),
}) {
  final now = lastActivityAt ?? DateTime(2026);
  return AcpSessionState(
    key: key ?? fakeAcpKey(),
    providerLabel: providerLabel,
    cwd: cwd,
    status: status,
    createdAt: DateTime(2025),
    lastActivityAt: now,
    title: title,
    initialization: capabilities == null
        ? null
        : AcpInitializeResult(
            protocolVersion: 1,
            agentCapabilities: capabilities,
          ),
    configOptions: configOptions,
    modeState: modeState,
    modelState: modelState,
    promptStatus: promptStatus,
    plan: plan,
    pendingPermissions: pendingPermissions,
    pendingWrites: pendingWrites,
    timeline: timeline,
  );
}

/// Agent capabilities advertising session fork/delete support.
AcpAgentCapabilities fakeAcpForkCapabilities() => const AcpAgentCapabilities(
  session: AcpSessionCapabilities(fork: true, delete: true),
);

/// Builds an agent message timeline entry.
AcpTimeline fakeAcpTimeline(String agentText) => AcpTimeline(
  entries: [
    AcpMessageEntry(
      order: 0,
      role: AcpMessageRole.agent,
      content: [AcpTextContent(agentText)],
    ),
  ],
);
