import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_protocol.dart';
import 'acp_session_keys.dart';
import 'acp_timeline.dart';
import 'acp_updates.dart';
import 'monkeymux_acp_bridge.dart';

/// High-level connection status of an ACP session as seen by the local app.
enum AcpConnectionStatus {
  /// No bridge/transport work has begun yet.
  idle,

  /// Starting or attaching to the remote bridge transport.
  connecting,

  /// The transport is up; the ACP `initialize`/session handshake is running.
  initializing,

  /// The agent requires authentication before a session can be used.
  authenticationRequired,

  /// The session is fully established and interactive.
  ready,

  /// The transport temporarily detached and is retrying.
  reconnecting,

  /// The session is intentionally detached locally; the remote bridge keeps
  /// running so it can be reconnected later.
  detached,

  /// The remote bridge could not be found or has expired.
  bridgeExpired,

  /// The remote provider process exited.
  providerExited,

  /// The session failed with a terminal error.
  failed,

  /// The session was explicitly closed and its resources released.
  closed,
}

/// Status of the current prompt turn for a session.
enum AcpPromptStatus {
  /// No prompt turn is in flight.
  idle,

  /// A prompt is being submitted.
  sending,

  /// The agent is streaming a response.
  streaming,

  /// A cancellation has been requested for the active turn.
  cancelling,
}

/// Stable, content-free error categories surfaced for an ACP session.
enum AcpSessionErrorKind {
  /// The remote bridge is unavailable or could not be installed.
  bridgeUnavailable,

  /// The remote bridge expired or no longer exists.
  bridgeExpired,

  /// The remote provider process exited unexpectedly.
  providerExited,

  /// The provider requires authentication that has not been completed.
  authenticationRequired,

  /// A requested ACP capability is not advertised by the agent.
  unsupportedCapability,

  /// The custom provider's command has not been approved for launch.
  commandNotApproved,

  /// The SSH transport failed or could not reconnect.
  transport,

  /// The bridge's bounded replay buffer overflowed, so some earlier history
  /// could not be replayed.
  ///
  /// This is a non-fatal warning: the session remains usable and can continue,
  /// but the missing portion cannot be restored in the current view. It is
  /// never a fatal transport failure.
  replayOverflow,

  /// The live provider retained the session but could not replay its earlier
  /// messages into this client view.
  ///
  /// This is non-fatal. New prompts still target the existing remote session.
  historyUnavailable,

  /// The ACP protocol was violated by the peer.
  protocol,

  /// A request exceeded its deadline.
  timeout,

  /// The free concurrency limit blocked the requested transition.
  concurrencyBlocked,

  /// An otherwise uncategorized failure.
  unknown,
}

/// A safe, content-free error surfaced for an ACP session.
///
/// [message] must never contain transcript content, prompts, paths, commands,
/// or any other sensitive data. It is a short, human-readable summary only.
@immutable
final class AcpSessionError {
  /// Creates a session error.
  const AcpSessionError({
    required this.kind,
    required this.message,
    this.retryable = false,
  });

  /// Stable error category.
  final AcpSessionErrorKind kind;

  /// Short, safe description.
  final String message;

  /// Whether retrying the same operation may recover without user action.
  final bool retryable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionError &&
          kind == other.kind &&
          message == other.message &&
          retryable == other.retryable;

  @override
  int get hashCode => Object.hash(kind, message, retryable);

  @override
  String toString() => 'AcpSessionError(${kind.name})';
}

/// A permission request awaiting a user decision.
///
/// Holds only the identifiers, short title, and choices needed to render and
/// answer the request. The remaining tool-call content stays in memory with the
/// live capability request and is never persisted.
@immutable
final class AcpPendingPermission {
  /// Creates a pending permission reference.
  ///
  /// [options] is defensively copied into an unmodifiable list.
  AcpPendingPermission({
    required this.requestKey,
    required this.sessionId,
    required this.toolCallId,
    required List<AcpPermissionOption> options,
    required this.requestedAt,
    this.toolTitle,
  }) : options = List<AcpPermissionOption>.unmodifiable(options);

  /// Local key that uniquely identifies this pending request within a session.
  final String requestKey;

  /// Remote ACP session identifier the request belongs to.
  final String sessionId;

  /// Tool call awaiting permission.
  final String toolCallId;

  /// Short tool or interaction title supplied by the agent.
  final String? toolTitle;

  /// Choices offered by the agent.
  final List<AcpPermissionOption> options;

  /// When the request was first observed locally.
  final DateTime requestedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpPendingPermission &&
          requestKey == other.requestKey &&
          sessionId == other.sessionId &&
          toolCallId == other.toolCallId &&
          toolTitle == other.toolTitle &&
          requestedAt == other.requestedAt &&
          const ListEquality<AcpPermissionOption>().equals(
            options,
            other.options,
          );

  @override
  int get hashCode => Object.hash(
    requestKey,
    sessionId,
    toolCallId,
    toolTitle,
    requestedAt,
    const ListEquality<AcpPermissionOption>().hash(options),
  );
}

/// A file write awaiting an explicit local approval.
///
/// Holds only enough information to prompt for approval. The full write
/// content is retained by the capability service that owns the live
/// responder, never duplicated here, and is never persisted or logged.
@immutable
final class AcpPendingWrite {
  /// Creates a pending write reference.
  const AcpPendingWrite({
    required this.requestKey,
    required this.sessionId,
    required this.path,
    required this.contentByteLength,
    required this.requestedAt,
  });

  /// Local key that uniquely identifies this pending request within a session.
  final String requestKey;

  /// Remote ACP session identifier the request belongs to.
  final String sessionId;

  /// Target remote path. Shown so a user can approve/reject with context; it
  /// is never persisted or written to diagnostics/telemetry.
  final String path;

  /// UTF-8 byte length of the pending write content (never the content).
  final int contentByteLength;

  /// When the request was first observed locally.
  final DateTime requestedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpPendingWrite &&
          requestKey == other.requestKey &&
          sessionId == other.sessionId &&
          path == other.path &&
          contentByteLength == other.contentByteLength &&
          requestedAt == other.requestedAt;

  @override
  int get hashCode =>
      Object.hash(requestKey, sessionId, path, contentByteLength, requestedAt);
}

/// Immutable snapshot of a single ACP session's normalized state.
///
/// Everything here is either an identifier, a capability/config descriptor, a
/// coarse status, or in-memory streaming state. Transcript content lives only
/// inside [timeline], which is never persisted or logged.
@immutable
final class AcpSessionState {
  /// Creates a session state snapshot.
  ///
  /// Every list field is defensively copied into an unmodifiable list so a
  /// caller can never mutate a published snapshot after construction.
  AcpSessionState({
    required this.key,
    required this.providerLabel,
    required this.cwd,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.isCustomProvider = false,
    this.title,
    this.attached = true,
    this.initialization,
    List<AcpAuthMethod> authMethods = const <AcpAuthMethod>[],
    this.pendingAuthentication = false,
    this.modeState,
    this.modelState,
    List<AcpSessionConfigOption> configOptions =
        const <AcpSessionConfigOption>[],
    this.autoApprovePermissions = false,
    List<AcpAvailableCommand> availableCommands = const <AcpAvailableCommand>[],
    List<AcpPlanEntry> plan = const <AcpPlanEntry>[],
    this.usage,
    this.lastStopReason,
    this.promptStatus = AcpPromptStatus.idle,
    List<AcpPendingPermission> pendingPermissions =
        const <AcpPendingPermission>[],
    List<AcpPendingWrite> pendingWrites = const <AcpPendingWrite>[],
    this.transportState,
    this.error,
    this.warning,
    this.timeline = const AcpTimeline.empty(),
  }) : authMethods = List<AcpAuthMethod>.unmodifiable(authMethods),
       configOptions = List<AcpSessionConfigOption>.unmodifiable(configOptions),
       availableCommands = List<AcpAvailableCommand>.unmodifiable(
         availableCommands,
       ),
       plan = List<AcpPlanEntry>.unmodifiable(plan),
       pendingPermissions = List<AcpPendingPermission>.unmodifiable(
         pendingPermissions,
       ),
       pendingWrites = List<AcpPendingWrite>.unmodifiable(pendingWrites);

  /// Stable composite identity of this session.
  final AcpSessionKey key;

  /// Provider display label.
  final String providerLabel;

  /// Whether the backing provider is a user-defined custom provider.
  final bool isCustomProvider;

  /// Working directory the session launched into.
  final String cwd;

  /// Optional session title reported by the agent.
  final String? title;

  /// High-level connection status.
  final AcpConnectionStatus status;

  /// Whether a local client is currently attached to the remote bridge.
  final bool attached;

  /// When the session was first created locally.
  final DateTime createdAt;

  /// Most recent local activity timestamp.
  final DateTime lastActivityAt;

  /// Most recent successful ACP initialization result, if any.
  final AcpInitializeResult? initialization;

  /// Authentication methods advertised by the agent.
  final List<AcpAuthMethod> authMethods;

  /// Whether the agent still requires authentication before use.
  final bool pendingAuthentication;

  /// Latest legacy mode state, if reported.
  final AcpSessionModeState? modeState;

  /// Latest legacy model state, if reported.
  final AcpModelState? modelState;

  /// Latest generic session configuration options.
  final List<AcpSessionConfigOption> configOptions;

  /// Whether MonkeySSH auto-approves supported requests for this session.
  final bool autoApprovePermissions;

  /// Latest available slash commands.
  final List<AcpAvailableCommand> availableCommands;

  /// Latest execution plan entries.
  final List<AcpPlanEntry> plan;

  /// Latest usage/context update.
  final AcpUsageUpdate? usage;

  /// Stop reason of the most recent completed prompt turn.
  final AcpStopReason? lastStopReason;

  /// Current prompt turn status.
  final AcpPromptStatus promptStatus;

  /// Permission requests awaiting a user decision.
  final List<AcpPendingPermission> pendingPermissions;

  /// File write requests awaiting a user decision.
  final List<AcpPendingWrite> pendingWrites;

  /// Latest transport state, when connected through a MonkeyMux bridge.
  final MonkeyMuxAcpTransportState? transportState;

  /// Latest fatal, safe error surfaced for this session, if any.
  final AcpSessionError? error;

  /// Latest non-fatal warning surfaced for this session, if any.
  ///
  /// Kept separate from [error] so a recoverable condition — such as a bridge
  /// replay-buffer overflow — is never conflated with a fatal transport
  /// failure. The session remains usable while a warning is present.
  final AcpSessionError? warning;

  /// In-memory normalized conversation timeline.
  final AcpTimeline timeline;

  /// Agent capabilities negotiated during initialization.
  AcpAgentCapabilities get capabilities =>
      initialization?.agentCapabilities ?? const AcpAgentCapabilities();

  /// Whether the session is currently live and locally attached.
  ///
  /// Live sessions are the ones counted by the concurrency policy. A detached,
  /// failed, expired, exited, or closed session is not live even though its
  /// remote bridge may still be running.
  bool get isLive =>
      attached &&
      switch (status) {
        AcpConnectionStatus.idle ||
        AcpConnectionStatus.connecting ||
        AcpConnectionStatus.initializing ||
        AcpConnectionStatus.authenticationRequired ||
        AcpConnectionStatus.ready ||
        AcpConnectionStatus.reconnecting => true,
        AcpConnectionStatus.detached ||
        AcpConnectionStatus.bridgeExpired ||
        AcpConnectionStatus.providerExited ||
        AcpConnectionStatus.failed ||
        AcpConnectionStatus.closed => false,
      };

  /// Whether this tracked session still represents an open persistent mux
  /// window, even when its local ACP transport is parked.
  ///
  /// Detached sessions keep their remote MonkeyMux bridge/provider alive and
  /// remain switchable. Terminal bridge/provider states are no longer windows.
  bool get isOpenMuxWindow => switch (status) {
    AcpConnectionStatus.idle ||
    AcpConnectionStatus.connecting ||
    AcpConnectionStatus.initializing ||
    AcpConnectionStatus.authenticationRequired ||
    AcpConnectionStatus.ready ||
    AcpConnectionStatus.reconnecting ||
    AcpConnectionStatus.detached => true,
    AcpConnectionStatus.bridgeExpired ||
    AcpConnectionStatus.providerExited ||
    AcpConnectionStatus.failed ||
    AcpConnectionStatus.closed => false,
  };

  /// Returns a copy with the provided fields replaced.
  ///
  /// Nullable fields use dedicated `clear*` flags so an explicit `null` can be
  /// distinguished from "leave unchanged".
  ///
  /// [key] may be supplied to rebuild the snapshot under a new identity (for
  /// example once a brand-new session's remote id becomes known). Because this
  /// is the single copy path, changing the key can never silently drop other
  /// fields the way a hand-written field-by-field reconstruction could.
  AcpSessionState copyWith({
    AcpSessionKey? key,
    String? providerLabel,
    String? cwd,
    String? title,
    bool clearTitle = false,
    AcpConnectionStatus? status,
    bool? attached,
    DateTime? lastActivityAt,
    AcpInitializeResult? initialization,
    List<AcpAuthMethod>? authMethods,
    bool? pendingAuthentication,
    AcpSessionModeState? modeState,
    bool clearModeState = false,
    AcpModelState? modelState,
    bool clearModelState = false,
    List<AcpSessionConfigOption>? configOptions,
    bool? autoApprovePermissions,
    List<AcpAvailableCommand>? availableCommands,
    List<AcpPlanEntry>? plan,
    AcpUsageUpdate? usage,
    bool clearUsage = false,
    AcpStopReason? lastStopReason,
    bool clearLastStopReason = false,
    AcpPromptStatus? promptStatus,
    List<AcpPendingPermission>? pendingPermissions,
    List<AcpPendingWrite>? pendingWrites,
    MonkeyMuxAcpTransportState? transportState,
    bool clearTransportState = false,
    AcpSessionError? error,
    bool clearError = false,
    AcpSessionError? warning,
    bool clearWarning = false,
    AcpTimeline? timeline,
  }) => AcpSessionState(
    key: key ?? this.key,
    providerLabel: providerLabel ?? this.providerLabel,
    isCustomProvider: isCustomProvider,
    cwd: cwd ?? this.cwd,
    title: clearTitle ? null : (title ?? this.title),
    status: status ?? this.status,
    attached: attached ?? this.attached,
    createdAt: createdAt,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    initialization: initialization ?? this.initialization,
    authMethods: authMethods ?? this.authMethods,
    pendingAuthentication: pendingAuthentication ?? this.pendingAuthentication,
    modeState: clearModeState ? null : (modeState ?? this.modeState),
    modelState: clearModelState ? null : (modelState ?? this.modelState),
    configOptions: configOptions ?? this.configOptions,
    autoApprovePermissions:
        autoApprovePermissions ?? this.autoApprovePermissions,
    availableCommands: availableCommands ?? this.availableCommands,
    plan: plan ?? this.plan,
    usage: clearUsage ? null : (usage ?? this.usage),
    lastStopReason: clearLastStopReason
        ? null
        : (lastStopReason ?? this.lastStopReason),
    promptStatus: promptStatus ?? this.promptStatus,
    pendingPermissions: pendingPermissions ?? this.pendingPermissions,
    pendingWrites: pendingWrites ?? this.pendingWrites,
    transportState: clearTransportState
        ? null
        : (transportState ?? this.transportState),
    error: clearError ? null : (error ?? this.error),
    warning: clearWarning ? null : (warning ?? this.warning),
    timeline: timeline ?? this.timeline,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionState &&
          key == other.key &&
          providerLabel == other.providerLabel &&
          isCustomProvider == other.isCustomProvider &&
          cwd == other.cwd &&
          title == other.title &&
          status == other.status &&
          attached == other.attached &&
          createdAt == other.createdAt &&
          lastActivityAt == other.lastActivityAt &&
          initialization == other.initialization &&
          pendingAuthentication == other.pendingAuthentication &&
          modeState == other.modeState &&
          modelState == other.modelState &&
          autoApprovePermissions == other.autoApprovePermissions &&
          usage == other.usage &&
          lastStopReason == other.lastStopReason &&
          promptStatus == other.promptStatus &&
          transportState == other.transportState &&
          error == other.error &&
          warning == other.warning &&
          timeline == other.timeline &&
          const ListEquality<AcpAuthMethod>().equals(
            authMethods,
            other.authMethods,
          ) &&
          const ListEquality<AcpSessionConfigOption>().equals(
            configOptions,
            other.configOptions,
          ) &&
          const ListEquality<AcpAvailableCommand>().equals(
            availableCommands,
            other.availableCommands,
          ) &&
          const ListEquality<AcpPlanEntry>().equals(plan, other.plan) &&
          const ListEquality<AcpPendingPermission>().equals(
            pendingPermissions,
            other.pendingPermissions,
          ) &&
          const ListEquality<AcpPendingWrite>().equals(
            pendingWrites,
            other.pendingWrites,
          );

  @override
  int get hashCode => Object.hash(
    key,
    providerLabel,
    cwd,
    title,
    status,
    attached,
    createdAt,
    lastActivityAt,
    initialization,
    pendingAuthentication,
    autoApprovePermissions,
    promptStatus,
    usage,
    lastStopReason,
    transportState,
    error,
    warning,
    timeline,
    Object.hash(
      const ListEquality<AcpAuthMethod>().hash(authMethods),
      const ListEquality<AcpSessionConfigOption>().hash(configOptions),
      const ListEquality<AcpAvailableCommand>().hash(availableCommands),
      const ListEquality<AcpPlanEntry>().hash(plan),
      const ListEquality<AcpPendingPermission>().hash(pendingPermissions),
      const ListEquality<AcpPendingWrite>().hash(pendingWrites),
    ),
  );
}
