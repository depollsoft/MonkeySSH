/// What the native chat composer offers when a submitted prompt's turn did
/// not finish normally.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_session_state.dart';
import '../../domain/services/acp_json_rpc_connection.dart';
import '../../domain/services/acp_session_manager.dart';
import 'acp_composer_controller.dart';

/// How a prompt that did not complete normally ended.
enum AcpPromptFailure {
  /// The prompt never ran: it was never sent, the local queue refused it, or
  /// the agent rejected it before doing anything. Sending it again is safe.
  refused,

  /// The agent failed after it had started on the prompt, so sending it again
  /// may repeat what it already did.
  failedMidTurn,

  /// The answer was lost (connection closed, timeout, bridge failure, detach
  /// mid-turn). The agent may have run the prompt.
  lost,
}

/// Classifies why a prompt's future failed.
AcpPromptFailure classifyAcpPromptFailure(Object error) => switch (error) {
  AcpPromptNotSentException() ||
  AcpPromptQueueFullException() => AcpPromptFailure.refused,
  AcpPromptFailedMidTurnException() => AcpPromptFailure.failedMidTurn,
  AcpRequestCancelledException() => AcpPromptFailure.lost,
  AcpRemoteException() => AcpPromptFailure.refused,
  _ => AcpPromptFailure.lost,
};

/// Why a submitted prompt can be put back in the composer.
enum AcpTurnRecoveryKind {
  /// The agent's answer was lost; it may still have run the prompt.
  unconfirmed,

  /// The agent failed partway through the prompt.
  failedMidTurn,

  /// The user stopped the turn.
  cancelled,
}

/// A prompt the user sent, kept so it can be edited and sent again, with the
/// composer's send count when it was sent.
typedef AcpSubmittedDraft = ({
  String text,
  List<AcpComposerAttachment> attachments,
  int submission,
});

/// Prompts the composer can restore after a turn ended without a reply.
@immutable
final class AcpTurnRecovery {
  /// Creates a recovery offer recorded when [submission] was the latest send.
  AcpTurnRecovery({
    required this.kind,
    required List<AcpSubmittedDraft> drafts,
    required this.submission,
    this.resumedSubmission,
  }) : drafts = List<AcpSubmittedDraft>.unmodifiable(drafts);

  /// Why the prompts can be restored.
  final AcpTurnRecoveryKind kind;

  /// The submitted prompts, oldest first.
  final List<AcpSubmittedDraft> drafts;

  /// The composer's send count when this offer was made.
  final int submission;

  /// The draft whose lost turn a reattach showed still running on the host.
  final int? resumedSubmission;

  /// Whether sending another prompt withdraws the offer. Only a stopped
  /// turn's prompt is: a lost or failed prompt stays until the user edits or
  /// dismisses it, so it is never discarded silently.
  bool get withdrawnBySend => kind == AcpTurnRecoveryKind.cancelled;

  /// This offer after the session moved from [previous] to [session].
  ///
  /// When a reattach shows the newest lost prompt's turn running on the host
  /// and that turn then finishes on the same session, its reply is in the
  /// transcript, so that draft alone is withdrawn; older drafts stay. A
  /// relaunch onto another session, or the user stopping the resumed turn,
  /// says nothing about whether the prompt ran, so every draft stays. Any
  /// newer send ([latestSubmission]) stops the tracking.
  AcpTurnRecovery? afterSessionUpdate({
    required AcpSessionState? previous,
    required AcpSessionState? session,
    required int latestSubmission,
  }) {
    if (kind != AcpTurnRecoveryKind.unconfirmed ||
        latestSubmission != submission ||
        session == null) {
      return this;
    }
    final resumed = resumedSubmission;
    if (resumed == null) {
      final reattachedMidTurn =
          previous?.status != AcpConnectionStatus.ready &&
          session.status == AcpConnectionStatus.ready &&
          session.promptStatus == AcpPromptStatus.streaming;
      return reattachedMidTurn
          ? _with(drafts, resumedSubmission: drafts.last.submission)
          : this;
    }
    final sameSession = previous != null && previous.key == session.key;
    final finished =
        sameSession &&
        session.status == AcpConnectionStatus.ready &&
        previous.promptStatus == AcpPromptStatus.streaming &&
        session.promptStatus == AcpPromptStatus.idle;
    if (finished) {
      final remaining = [
        for (final draft in drafts)
          if (draft.submission != resumed) draft,
      ];
      return remaining.isEmpty ? null : _with(remaining);
    }
    if (!sameSession || session.promptStatus == AcpPromptStatus.idle) {
      return _with(drafts);
    }
    return this;
  }

  /// This offer with only [kept] drafts, no longer tracking a resumed turn
  /// unless [resumedSubmission] is given.
  AcpTurnRecovery _with(
    List<AcpSubmittedDraft> kept, {
    int? resumedSubmission,
  }) => AcpTurnRecovery(
    kind: kind,
    drafts: kept,
    submission: submission,
    resumedSubmission: resumedSubmission,
  );
}
