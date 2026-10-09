// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/models/acp_mcp_server.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_session_workspace.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';

class FakeAcpConnector extends Fake implements AcpBridgeConnector {}

class FakeAcpRecentSessions extends Fake implements AcpRecentSessionsService {}

/// A real [AcpSessionManager] that records composer prompts and cancels
/// instead of sending them.
class RecordingAcpSessionManager extends AcpSessionManager {
  RecordingAcpSessionManager()
    : super(
        connector: FakeAcpConnector(),
        recentSessions: FakeAcpRecentSessions(),
        isProUnlocked: () => true,
      );

  final List<List<AcpContentBlock>> prompts = <List<AcpContentBlock>>[];
  int cancelCount = 0;
  Object? throwOnPrompt;
  Completer<void>? promptGate;

  int get promptCount => prompts.length;

  List<AcpContentBlock>? get lastPrompt => prompts.lastOrNull;

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) async {
    prompts.add(List<AcpContentBlock>.of(content));
    final gate = promptGate;
    if (gate != null) {
      await gate.future;
    }
    final error = throwOnPrompt;
    if (error != null) {
      // ignore: only_throw_errors
      throw error;
    }
    return const AcpPromptResult(stopReason: AcpStopReason.endTurn);
  }

  @override
  Future<void> cancelPrompt(AcpSessionKey key) async {
    cancelCount++;
  }
}

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
         connector: FakeAcpConnector(),
         recentSessions: FakeAcpRecentSessions(),
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
  final List<AcpSessionWorkspaceOptions?> startWorkspaces =
      <AcpSessionWorkspaceOptions?>[];
  final List<AcpSessionWorkspaceOptions?> reconnectWorkspaces =
      <AcpSessionWorkspaceOptions?>[];

  /// Whether each [reconnectSession] call asked to take the input over.
  final List<bool> reconnectTakeOvers = <bool>[];

  /// MCP servers returned by [loadMcpServers].
  List<AcpMcpServerConfig> mcpServers = const <AcpMcpServerConfig>[];
  final List<bool> reconnectSelectOnSuccess = <bool>[];
  final List<List<AcpSessionKey>> reconnectReplaceKeys =
      <List<AcpSessionKey>>[];
  final List<MonkeyMuxAcpBridgeMetadata?> reconnectKnownBridges =
      <MonkeyMuxAcpBridgeMetadata?>[];
  final List<(String, String)> permissionResponses = <(String, String)>[];
  final List<({int hostId, String bridgeId})> releasedMuxBridges = [];
  final Map<String, String> pendingWriteContents = <String, String>{};
  final List<String> declinedElicitations = <String>[];

  /// Results returned by successive [forkSession] calls, consumed FIFO. When
  /// exhausted, a safe failure is returned.
  final List<AcpSessionLaunchResult> forkResults = <AcpSessionLaunchResult>[];
  int forkCount = 0;
  final List<List<AcpSessionKey>> forkReplaceKeys = <List<AcpSessionKey>>[];

  /// Result returned by [startNewSession]; defaults to a safe failure.
  AcpSessionLaunchResult startNewSessionResult = const AcpSessionLaunchFailed(
    null,
    AcpSessionError(kind: AcpSessionErrorKind.unknown, message: 'No launch.'),
  );

  /// FIFO start results consumed before [startNewSessionResult].
  final List<AcpSessionLaunchResult> startNewSessionResults = [];

  /// FIFO reconnect results consumed before the fallback result.
  final List<AcpSessionLaunchResult> reconnectSessionResults = [];

  /// Fallback returned by [reconnectSession]; defaults to a safe failure.
  AcpSessionLaunchResult reconnectSessionResult = const AcpSessionLaunchFailed(
    null,
    AcpSessionError(kind: AcpSessionErrorKind.unknown, message: 'No resume.'),
  );

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

  /// Sign-in choosers passed to [startNewSession], in call order.
  final List<AcpAuthenticationChooser?> startChoosers =
      <AcpAuthenticationChooser?>[];

  /// Sign-in choosers passed to [reconnectSession], in call order.
  final List<AcpAuthenticationChooser?> reconnectChoosers =
      <AcpAuthenticationChooser?>[];

  /// When set, a launch with a chooser asks it with this request before
  /// returning its configured result. The choices are recorded.
  AcpAuthenticationRequest? authenticationRequest;
  final List<AcpAuthenticationChoice?> authenticationChoices =
      <AcpAuthenticationChoice?>[];

  /// Agent sign-in methods sent through [authenticateSession].
  final List<String> authenticatedMethodIds = <String>[];

  /// Error returned by [authenticateSession]; `null` means success.
  AcpSessionError? authenticateSessionError;

  /// Optional gate holding [authenticateSession] until completed.
  Completer<void>? authenticateSessionGate;

  /// Sessions logged out through [logout].
  final List<String> loggedOut = <String>[];

  /// Terminal login returned by [terminalAuthenticationLaunch].
  AcpTerminalAuthLaunch? terminalLaunch;
  final List<bool> autoApprovePermissionSets = <bool>[];
  final List<String> modeSets = <String>[];

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
  Future<List<AcpMcpServerConfig>> loadMcpServers() async => mcpServers;

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
  Future<void> cancelPermission(AcpSessionKey key, String requestKey) async {}

  @override
  String? pendingWriteContent(AcpSessionKey key, String requestKey) =>
      pendingWriteContents[requestKey];

  @override
  Future<void> approveWrite(AcpSessionKey key, String requestKey) async {}

  @override
  Future<void> rejectWrite(AcpSessionKey key, String requestKey) async {}

  @override
  Future<void> acceptElicitation(
    AcpSessionKey key,
    String requestKey, {
    Map<String, Object?>? content,
  }) async {}

  @override
  Future<void> declineElicitation(AcpSessionKey key, String requestKey) async {
    declinedElicitations.add(requestKey);
  }

  @override
  Future<void> cancelElicitation(AcpSessionKey key, String requestKey) async {}

  @override
  void dismissAwaitingElicitation(AcpSessionKey key, String elicitationId) {}

  @override
  Future<AcpSessionLaunchResult> forkSession(
    AcpSessionKey key, {
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    forkCount++;
    forkReplaceKeys.add(List<AcpSessionKey>.unmodifiable(replace));
    stopped.addAll(replace.map((key) => key.value));
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
    AcpAuthenticationChooser? chooseAuthentication,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
    AcpSessionWorkspaceOptions? workspace,
  }) async {
    starts.add((hostId: hostId, providerId: providerId, cwd: cwd));
    startLaunchOverrides.add(launchCommandOverride);
    startAutoApprovePermissions.add(autoApprovePermissions);
    startWorkspaces.add(workspace);
    startChoosers.add(chooseAuthentication);
    await _askChooser(chooseAuthentication);
    return startNewSessionResults.isNotEmpty
        ? startNewSessionResults.removeAt(0)
        : startNewSessionResult;
  }

  Future<void> _askChooser(AcpAuthenticationChooser? chooser) async {
    final request = authenticationRequest;
    if (chooser == null || request == null) return;
    authenticationChoices.add(await chooser(request));
  }

  @override
  Future<AcpSessionLaunchResult> reconnectSession({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpAuthenticationChooser? chooseAuthentication,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    bool selectOnSuccess = true,
    MonkeyMuxAcpBridgeMetadata? knownRemoteBridge,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
    AcpSessionWorkspaceOptions? workspace,
    bool takeOver = false,
  }) async {
    reconnectTakeOvers.add(takeOver);
    reconnectWorkspaces.add(workspace);
    reconnectChoosers.add(chooseAuthentication);
    await _askChooser(chooseAuthentication);
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
    final result = reconnectSessionResults.isNotEmpty
        ? reconnectSessionResults.removeAt(0)
        : reconnectSessionResult;
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
  Future<void> setModel(AcpSessionKey key, String modelId) async {}

  @override
  Future<AcpSessionError?> authenticateSession(
    AcpSessionKey key,
    AcpAuthMethod method, {
    AcpRequestCancellation? cancellation,
  }) async {
    authenticatedMethodIds.add(method.id);
    await authenticateSessionGate?.future;
    return authenticateSessionError;
  }

  @override
  AcpTerminalAuthLaunch? terminalAuthenticationLaunch(
    AcpSessionKey key,
    AcpAuthMethod method,
  ) => terminalLaunch;

  /// Keys passed to [stopUnusedBridge], in call order.
  final List<String> stoppedUnusedBridges = <String>[];

  @override
  Future<void> stopUnusedBridge(AcpSessionKey key) async {
    stoppedUnusedBridges.add(key.value);
  }

  @override
  Future<AcpSessionLaunchResult> restartAfterSignIn(AcpSessionKey key) async =>
      AcpSessionLaunchStarted(key);

  @override
  Future<AcpSessionError?> logout(AcpSessionKey key) async {
    loggedOut.add(key.value);
    return null;
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
  List<AcpSessionElicitation> pendingElicitations =
      const <AcpSessionElicitation>[],
  List<AcpAwaitingElicitation> awaitingElicitations =
      const <AcpAwaitingElicitation>[],
  AcpTimeline timeline = const AcpTimeline.empty(),
  List<AcpAuthMethod> authMethods = const <AcpAuthMethod>[],
  AcpSessionError? error,
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
    initialization: capabilities == null && authMethods.isEmpty
        ? null
        : AcpInitializeResult(
            protocolVersion: 1,
            agentCapabilities: capabilities ?? const AcpAgentCapabilities(),
            authMethods: authMethods,
          ),
    authMethods: authMethods,
    pendingAuthentication: status == AcpConnectionStatus.authenticationRequired,
    error: error,
    configOptions: configOptions,
    modeState: modeState,
    modelState: modelState,
    promptStatus: promptStatus,
    plan: plan,
    pendingPermissions: pendingPermissions,
    pendingWrites: pendingWrites,
    pendingElicitations: pendingElicitations,
    awaitingElicitations: awaitingElicitations,
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
