import 'package:flutter/foundation.dart';

import 'acp_session_state.dart';
import 'monkeymux_acp_bridge.dart';
import 'terminal_progress.dart';
import 'tmux_state.dart';

/// Why a window or native session asks for the user, most urgent first.
///
/// Every reason is reported by a program or the host: a native agent's
/// pending request, a bell, a desktop notification escape, OSC 9;4 progress,
/// or an account allowance. None is guessed from screen contents or keyed on
/// an agent's name.
enum AttentionReason {
  /// A native agent asked to run a tool or write a file.
  permission,

  /// A native agent asked a question (`elicitation/create`).
  input,

  /// A native agent needs the user to sign in.
  signIn,

  /// The host reports a native agent request with no attached client.
  ///
  /// The request's kind is unknown until the session is opened.
  hostRequest,

  /// A terminal window rang the bell or raised a multiplexer alert flag.
  alert,

  /// A terminal window sent a desktop notification escape in the background.
  notification,

  /// A terminal program reported OSC 9;4 progress in its error state.
  progressError,

  /// A terminal program reported OSC 9;4 progress paused or in warning.
  progressPaused,

  /// The agent's reported account allowance is at or below the warning level.
  lowQuota;

  /// Whether the agent is blocked until the user answers.
  bool get isWaitingOnYou => index <= hostRequest.index;

  /// Sort tier: blocked agents, then alerts, then warnings.
  int get tier => switch (this) {
    permission || input || signIn || hostRequest => 0,
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

/// Returns why a tracked native [session] is blocked on the user, if it is.
///
/// Local session state is authoritative while a client is attached. A
/// detached session cannot see requests that arrived after it detached, so
/// its host-reported [bridge] metadata fills the gap.
AttentionReason? acpSessionWaitingReason(
  AcpSessionState session, {
  MonkeyMuxAcpBridgeMetadata? bridge,
}) {
  final authFailed =
      session.error?.kind == AcpSessionErrorKind.authenticationRequired;
  switch (session.status) {
    case AcpConnectionStatus.closed ||
        AcpConnectionStatus.bridgeExpired ||
        AcpConnectionStatus.providerExited:
      return null;
    case AcpConnectionStatus.failed:
      return authFailed ? AttentionReason.signIn : null;
    case AcpConnectionStatus.idle ||
        AcpConnectionStatus.connecting ||
        AcpConnectionStatus.initializing ||
        AcpConnectionStatus.authenticationRequired ||
        AcpConnectionStatus.ready ||
        AcpConnectionStatus.reconnecting ||
        AcpConnectionStatus.detached:
      break;
  }
  if (session.pendingPermissions.isNotEmpty ||
      session.pendingWrites.isNotEmpty) {
    return AttentionReason.permission;
  }
  if (session.pendingElicitations.isNotEmpty) return AttentionReason.input;
  if (session.status == AcpConnectionStatus.authenticationRequired ||
      session.pendingAuthentication ||
      authFailed) {
    return AttentionReason.signIn;
  }
  if (!session.isLive && bridge != null) return bridgeWaitingReason(bridge);
  return null;
}

/// Returns [AttentionReason.hostRequest] when a running [bridge] holds a
/// provider request that no client has answered.
AttentionReason? bridgeWaitingReason(MonkeyMuxAcpBridgeMetadata bridge) =>
    bridge.state == MonkeyMuxAcpProviderState.running &&
        bridge.pendingRequestCount > 0
    ? AttentionReason.hostRequest
    : null;

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
/// Uses only multiplexer flags, forwarded notification escapes and OSC 9;4
/// progress, plus [lowQuota] from the account allowance rings. Output timing
/// is activity, not attention, and never produces a reason here.
AttentionReason? terminalWindowAttentionReason(
  TmuxWindow window, {
  bool lowQuota = false,
}) {
  if (window.hasAlert) return AttentionReason.alert;
  if (window.pendingNotifications.isNotEmpty) {
    return AttentionReason.notification;
  }
  switch (window.terminalProgress?.state) {
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
DateTime? terminalWindowLastActivity(TmuxWindow window) {
  final epoch = window.lastActivityEpochSeconds;
  return epoch == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
}

/// Whether a terminal [window] printed within [terminalQuietAfterSeconds] of
/// [now]. This is inferred from output timing, never reported by the program.
bool terminalWindowRecentlyActive(TmuxWindow window, {DateTime? now}) {
  final last = terminalWindowLastActivity(window);
  if (last == null) return false;
  final reference = now ?? DateTime.now();
  return reference.difference(last).inSeconds <= terminalQuietAfterSeconds;
}
