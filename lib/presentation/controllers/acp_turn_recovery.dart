/// What the native chat composer offers when a submitted prompt's turn did
/// not finish normally.
library;

import 'package:flutter/foundation.dart';

import '../../domain/services/acp_json_rpc_connection.dart';
import '../../domain/services/acp_session_manager.dart';
import 'acp_composer_controller.dart';

/// Whether [error] confirms that the prompt failed, so offering to send it
/// again is safe to suggest.
///
/// The agent answering `session/prompt` with an error, or the local queue
/// refusing the prompt, is confirmation. A closed connection, a timeout, a
/// bridge failure or a detach during the turn is not: the agent may have run
/// the prompt and only its answer was lost, and sending it again could repeat
/// what it already did.
bool isConfirmedAcpPromptFailure(Object error) => switch (error) {
  AcpRequestCancelledException() => false,
  AcpRemoteException() => true,
  AcpPromptQueueFullException() => true,
  _ => false,
};

/// Why a submitted prompt can be put back in the composer.
enum AcpTurnRecoveryKind {
  /// The agent's answer was lost; it may still have run the prompt.
  unconfirmed,

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
  /// Creates a recovery offer.
  AcpTurnRecovery({required this.kind, required List<AcpSubmittedDraft> drafts})
    : drafts = List<AcpSubmittedDraft>.unmodifiable(drafts);

  /// Why the prompts can be restored.
  final AcpTurnRecoveryKind kind;

  /// The submitted prompts, oldest first.
  final List<AcpSubmittedDraft> drafts;
}
