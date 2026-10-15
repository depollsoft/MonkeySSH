import 'package:flutter/foundation.dart';

import 'acp_session_state.dart';
import 'monkeymux_acp_bridge.dart';
import 'terminal_program_status.dart';
import 'terminal_progress.dart';
import 'tmux_state.dart';

/// Why a window or native session asks for the user, most urgent first.
///
/// Every reason is reported by a program or the host: a native agent's
/// pending request, an OSC 7501 program status, a bell, a desktop
/// notification escape, OSC 9;4 progress, or an account allowance. None is
/// guessed from screen contents or keyed on an agent's name.
enum AttentionReason {
  /// A native agent asked to run a tool or write a file, or a terminal
  /// program reported it is blocked on permission.
  permission,

  /// A native agent asked a question (`elicitation/create`), or a terminal
  /// program reported it is blocked on a question.
  input,

  /// A native agent or a terminal program needs the user to sign in.
  signIn,

  /// The host reports a native agent request with no attached client, of a
  /// kind it does not name (a file or terminal call, or any request from a
  /// helper that predates request kinds).
  hostRequest,

  /// A terminal program reported it cannot continue until the user acts,
  /// without saying what it needs.
  blocked,

  /// A terminal window rang the bell or raised a multiplexer alert flag.
  alert,

  /// A terminal window sent a desktop notification escape in the background.
  notification,

  /// A terminal program reported an error: OSC 9;4 progress in its error
  /// state, or an OSC 7501 error status.
  progressError,

  /// A terminal program reported OSC 9;4 progress paused or in warning.
  progressPaused,

  /// The agent's reported account allowance is at or below the warning level.
  lowQuota;

  /// Whether the agent is blocked until the user answers.
  bool get isWaitingOnYou => index <= blocked.index;

  /// Sort tier: blocked agents, then alerts, then warnings.
  int get tier => switch (this) {
    permission || input || signIn || hostRequest || blocked => 0,
    alert || notification || progressError => 1,
    progressPaused || lowQuota => 2,
  };
}

/// Sort tier for windows without an attention reason.
const attentionQuietTier = 3;

/// Seconds without output after which a terminal window counts as quiet.
///
/// Matches the idle threshold the existing window status badges use.
const terminalQuietAfterSeconds = 15;

/// Bridges on which this app holds the client of a live native session, as
/// `(hostId, bridgeId)`. Forks on one bridge share that one client.
Set<(int, String)> locallyAttachedBridges(Iterable<AcpSessionState> sessions) =>
    {
      for (final session in sessions)
        if (session.isLive) (session.key.hostId, session.key.bridgeId),
    };

/// Whether a running [bridge] holds a request that no client is answering.
///
/// [attachedHere] says this app holds the bridge's client for a live fork
/// (see [locallyAttachedBridges]). That client answers only its live
/// sessions' requests, so it does not count for a detached fork's. Its own
/// file and terminal requests are answered within moments, though, so while
/// it is attached only a request the user must decide counts, when the
/// helper names kinds.
bool bridgeRequestUnanswered(
  MonkeyMuxAcpBridgeMetadata bridge, {
  bool attachedHere = false,
}) {
  if (bridge.state != MonkeyMuxAcpProviderState.running ||
      bridge.pendingRequestCount <= 0) {
    return false;
  }
  if (!attachedHere) return bridge.clientCount == 0;
  if (bridge.clientCount > 1) return false;
  final permissions = bridge.pendingPermissionCount;
  final questions = bridge.pendingInputCount;
  return permissions == null ||
      questions == null ||
      permissions + questions > 0;
}

/// Returns why a tracked native [session] is blocked on the user, if it is.
///
/// Local session state is authoritative while a client is attached. Once
/// detached, or after its transport failed, the session stops hearing about
/// requests, both new ones and ones another client answers, so only fresh
/// host-reported [bridge] metadata can say it waits ([attachedHere] as in
/// [bridgeRequestUnanswered]):
///
/// - No [bridge]: not claimed. Either its host has not been polled since the
///   app came back, so retained requests may already be answered, or the poll
///   no longer lists the bridge because the agent was stopped.
/// - [bridge] present: it waits only while the bridge holds a request that no
///   attached client is answering. A retained request names the kind while
///   the bridge still holds one of that kind (a helper that reports kinds
///   says so; an older one cannot, so a retained request is trusted).
///   Otherwise it waits on whatever the bridge reports, and only when the
///   bridge's own session is this one, so a detached fork does not echo a
///   sibling's request. A retained sign-in counts only while nothing else
///   is attached to the agent or waiting on it.
AttentionReason? acpSessionWaitingReason(
  AcpSessionState session, {
  MonkeyMuxAcpBridgeMetadata? bridge,
  bool attachedHere = false,
}) {
  final authFailed =
      session.error?.kind == AcpSessionErrorKind.authenticationRequired;
  switch (session.status) {
    case AcpConnectionStatus.closed ||
        AcpConnectionStatus.bridgeExpired ||
        AcpConnectionStatus.providerExited:
      return null;
    case AcpConnectionStatus.failed:
      // Unless sign-in failed, the agent may still run on the host and ask
      // for the user; read the host as for a detached session.
      if (authFailed) return AttentionReason.signIn;
    case AcpConnectionStatus.idle ||
        AcpConnectionStatus.connecting ||
        AcpConnectionStatus.initializing ||
        AcpConnectionStatus.authenticationRequired ||
        AcpConnectionStatus.ready ||
        AcpConnectionStatus.reconnecting ||
        AcpConnectionStatus.detached:
      break;
  }
  final needsSignIn =
      session.status == AcpConnectionStatus.authenticationRequired ||
      session.pendingAuthentication ||
      authFailed;
  if (session.isLive) {
    if (session.pendingPermissions.isNotEmpty ||
        session.pendingWrites.isNotEmpty) {
      return AttentionReason.permission;
    }
    if (session.pendingElicitations.isNotEmpty) return AttentionReason.input;
    return needsSignIn ? AttentionReason.signIn : null;
  }
  if (bridge == null || bridge.state != MonkeyMuxAcpProviderState.running) {
    return null;
  }
  final unanswered = bridgeRequestUnanswered(
    bridge,
    attachedHere: attachedHere,
  );
  if (unanswered) {
    final permissions = bridge.pendingPermissionCount;
    if (session.pendingPermissions.isNotEmpty &&
        (permissions == null || permissions > 0)) {
      return AttentionReason.permission;
    }
    // A file write the client asks the user to approve is a file request to
    // the host, which counts it but does not type it.
    if (session.pendingWrites.isNotEmpty) return AttentionReason.permission;
    final questions = bridge.pendingInputCount;
    if (session.pendingElicitations.isNotEmpty &&
        (questions == null || questions > 0)) {
      return AttentionReason.input;
    }
  }
  // The host does not report sign-in, and it belongs to the agent process
  // that every fork on the bridge shares. An attached client or a request in
  // flight means something else is talking to the agent and may have signed
  // it in, so only an untouched bridge keeps the retained sign-in.
  if (needsSignIn && bridge.clientCount == 0 && bridge.inFlightTurnCount == 0) {
    return AttentionReason.signIn;
  }
  final bridgeSession = bridge.sessionId;
  return unanswered &&
          (bridgeSession == null || bridgeSession == session.key.acpSessionId)
      ? _hostReportedReason(bridge)
      : null;
}

/// Returns why a running [bridge] waits when it holds a provider request and
/// no client is attached to answer it ([attachedHere] as in
/// [bridgeRequestUnanswered]).
///
/// An attached client (another device, or a forked sibling) answers its own
/// file and terminal requests within moments; counting them would flash rows.
AttentionReason? bridgeWaitingReason(
  MonkeyMuxAcpBridgeMetadata bridge, {
  bool attachedHere = false,
}) => bridgeRequestUnanswered(bridge, attachedHere: attachedHere)
    ? _hostReportedReason(bridge)
    : null;

/// The decision a [bridge] with a pending request waits on: a permission or
/// a question when its helper names one, otherwise a generic request.
AttentionReason _hostReportedReason(MonkeyMuxAcpBridgeMetadata bridge) {
  if ((bridge.pendingPermissionCount ?? 0) > 0) {
    return AttentionReason.permission;
  }
  if ((bridge.pendingInputCount ?? 0) > 0) return AttentionReason.input;
  return AttentionReason.hostRequest;
}

/// When the oldest decision a tracked [session] waits on was first seen, or
/// its last activity when no request carries a timestamp.
DateTime acpSessionWaitingSince(AcpSessionState session) {
  DateTime? since;
  for (final requestedAt in [
    for (final pending in session.pendingPermissions) pending.requestedAt,
    for (final pending in session.pendingWrites) pending.requestedAt,
    for (final pending in session.pendingElicitations) pending.requestedAt,
  ]) {
    if (since == null || requestedAt.isBefore(since)) since = requestedAt;
  }
  return since ?? session.lastActivityAt;
}

/// Returns the most urgent generic signal a terminal [window] reports.
///
/// Uses only the program's OSC 7501 status, multiplexer flags, forwarded
/// notification escapes and OSC 9;4 progress, plus [lowQuota] from the
/// account allowance rings. Output timing is activity, not attention, and
/// never produces a reason here.
///
/// A blocked program outranks an alert, as the status badges rank them; any
/// other reported status yields to an alert, and replaces OSC 9;4 progress.
AttentionReason? terminalWindowAttentionReason(
  TmuxWindow window, {
  bool lowQuota = false,
}) {
  switch (window.reportedStatus) {
    case TerminalProgramStatus(
      state: TerminalProgramState.blocked,
      :final kind,
    ):
      return switch (kind) {
        TerminalProgramBlockedKind.permission => AttentionReason.permission,
        TerminalProgramBlockedKind.question => AttentionReason.input,
        TerminalProgramBlockedKind.auth => AttentionReason.signIn,
        null => AttentionReason.blocked,
      };
    case TerminalProgramStatus(state: TerminalProgramState.error):
      return AttentionReason.progressError;
    case _:
      break;
  }
  if (window.hasAlert) return AttentionReason.alert;
  if (window.pendingNotifications.isNotEmpty) {
    return AttentionReason.notification;
  }
  switch (window.activityProgress?.state) {
    case TerminalProgressState.error:
      return AttentionReason.progressError;
    case TerminalProgressState.pausedOrWarning:
      return AttentionReason.progressPaused;
    case TerminalProgressState.normal ||
        TerminalProgressState.indeterminate ||
        null:
      break;
  }
  return lowQuota ? AttentionReason.lowQuota : null;
}

/// Turn state of a native agent as reported by the app or the host.
enum NativeTurnState {
  /// A prompt turn is in flight.
  running,

  /// No prompt turn is in flight.
  idle,

  /// Neither the local session nor the host reported a turn state.
  unknown,
}

/// Resolves whether a native agent is working.
///
/// An attached [session] knows its own prompt status. Otherwise the host's
/// [bridge] metadata counts in-flight client requests (`inFlightTurnCount`).
NativeTurnState nativeTurnState({
  AcpSessionState? session,
  MonkeyMuxAcpBridgeMetadata? bridge,
}) {
  if (session != null && session.isLive) {
    if (session.status != AcpConnectionStatus.ready) {
      return NativeTurnState.unknown;
    }
    return session.promptStatus == AcpPromptStatus.idle
        ? NativeTurnState.idle
        : NativeTurnState.running;
  }
  if (bridge == null || bridge.state != MonkeyMuxAcpProviderState.running) {
    return NativeTurnState.unknown;
  }
  return bridge.inFlightTurnCount > 0
      ? NativeTurnState.running
      : NativeTurnState.idle;
}

/// Sort key for one row of a connection's window list.
@immutable
class AttentionSortKey {
  /// Creates a sort key.
  const AttentionSortKey({
    required this.index,
    this.reason,
    this.active = false,
    this.lastActivity,
  });

  /// Window number, used as the stable final tie-break.
  final int index;

  /// Most urgent attention reason, if any.
  final AttentionReason? reason;

  /// Whether the row is working now: a reported running turn, or terminal
  /// output within [terminalQuietAfterSeconds].
  final bool active;

  /// Latest activity, when known.
  final DateTime? lastActivity;

  /// Sort tier, lowest first.
  int get tier => reason?.tier ?? attentionQuietTier;
}

/// Orders rows by attention, then recency, then window number.
///
/// Rows that are working now share a recency slot and keep window order, so a
/// list does not reshuffle every time a busy window prints. Quiet rows sort by
/// their last activity, newest first; their timestamps do not move.
int compareAttentionSortKeys(AttentionSortKey a, AttentionSortKey b) {
  final tier = a.tier.compareTo(b.tier);
  if (tier != 0) return tier;
  final reasonOrder = (a.reason?.index ?? 0).compareTo(b.reason?.index ?? 0);
  if (reasonOrder != 0) return reasonOrder;
  if (a.active != b.active) return a.active ? -1 : 1;
  if (!a.active) {
    final aTime = a.lastActivity;
    final bTime = b.lastActivity;
    if (aTime != null && bTime != null) {
      final recency = bTime.compareTo(aTime);
      if (recency != 0) return recency;
    } else if (aTime != null || bTime != null) {
      return aTime != null ? -1 : 1;
    }
  }
  return a.index.compareTo(b.index);
}

/// Latest output time of a terminal [window], when the multiplexer reports it.
///
/// Prefers the reported epoch. A snapshot that carries only an idle duration,
/// such as the App Review demo workspace, is read relative to [now].
DateTime? terminalWindowLastActivity(TmuxWindow window, {DateTime? now}) {
  final epoch = window.lastActivityEpochSeconds;
  if (epoch != null) return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  final idle = window.idleSeconds;
  if (idle == null) return null;
  return (now ?? DateTime.now()).subtract(Duration(seconds: idle));
}

/// Whether a terminal [window] printed within [terminalQuietAfterSeconds] of
/// [now]. This is inferred from output timing, never reported by the program.
bool terminalWindowRecentlyActive(TmuxWindow window, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final last = terminalWindowLastActivity(window, now: reference);
  if (last == null) return false;
  return reference.difference(last).inSeconds <= terminalQuietAfterSeconds;
}

/// Whether OSC 9;4 progress, or the OSC 7501 status that replaces it, reports
/// work underway.
bool terminalProgressIsRunning(TerminalProgress? progress) =>
    progress?.state == TerminalProgressState.normal ||
    progress?.state == TerminalProgressState.indeterminate;

/// Whether a terminal [window] is working now.
///
/// A program's OSC 7501 status is authoritative: it says working or it does
/// not. A program that speaks OSC 7501 but reports nothing now is not
/// working, since a redraw (such as the one entering its window causes)
/// would otherwise read as work. Without either, OSC 9;4 progress counts as
/// work, and so does output within [terminalQuietAfterSeconds] of [now].
bool terminalWindowWorking(TmuxWindow window, {DateTime? now}) {
  if (window.programStatus case final status?) {
    return status.state == TerminalProgramState.working;
  }
  if (window.programStatusReporter) return false;
  return terminalProgressIsRunning(window.activityProgress) ||
      terminalWindowRecentlyActive(window, now: now);
}

/// Whether a terminal [window]'s state comes from its program alone, so
/// nothing about it is inferred from output timing.
bool terminalWindowReportsOwnStatus(TmuxWindow window) =>
    window.programStatus != null || window.programStatusReporter;
