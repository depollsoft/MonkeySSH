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

/// A prompt the user sent, kept so it can be edited and sent again.
typedef AcpSubmittedDraft = ({
  String text,
  List<AcpComposerAttachment> attachments,
});

/// Prompts the composer can restore after a turn ended without a reply.
@immutable
final class AcpTurnRecovery {
  /// Creates a recovery offer recorded when [submission] was the latest send.
  AcpTurnRecovery({
    required this.kind,
    required List<AcpSubmittedDraft> drafts,
    required this.submission,
    this.turnResumed = false,
  }) : drafts = List<AcpSubmittedDraft>.unmodifiable(drafts);

  /// Why the prompts can be restored.
  final AcpTurnRecoveryKind kind;

  /// The submitted prompts, oldest first.
  final List<AcpSubmittedDraft> drafts;

  /// The composer's send count when this offer was made.
  final int submission;

  /// Whether a reattach showed the lost turn still running on the host.
  final bool turnResumed;

  /// Whether sending another prompt withdraws the offer. Only a stopped
  /// turn's prompt is: a lost or failed prompt stays until the user edits or
  /// dismisses it, so it is never discarded silently.
  bool get withdrawnBySend => kind == AcpTurnRecoveryKind.cancelled;

  /// This offer after the session moved from [previous] to [session].
  ///
  /// A lost answer is withdrawn once a reattach shows the turn running on the
  /// host and it then finishes, because the reply is in the transcript. Any
  /// newer send ([latestSubmission]) stops that tracking.
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
    if (!turnResumed) {
      final reattachedMidTurn =
          previous?.status != AcpConnectionStatus.ready &&
          session.status == AcpConnectionStatus.ready &&
          session.promptStatus == AcpPromptStatus.streaming;
      return reattachedMidTurn
          ? AcpTurnRecovery(
              kind: kind,
              drafts: drafts,
              submission: submission,
              turnResumed: true,
            )
          : this;
    }
    return session.promptStatus == AcpPromptStatus.idle ? null : this;
  }
}
