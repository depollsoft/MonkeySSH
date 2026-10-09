/// The non-visual state and behaviour behind the ACP composer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';

import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_content.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_updates.dart';
import '../../domain/services/acp_attachment_service.dart';
import '../../domain/services/acp_session_manager.dart';
import '../models/acp_slash_command.dart';
import 'acp_turn_recovery.dart';

/// Minimum insertion size promoted to a compact pasted-text chip.
const int kAcpLargePasteThresholdChars = 2000;

/// Minimum line count promoted to a compact pasted-text chip.
const int kAcpLargePasteThresholdLines = 20;

int _acpComposerPasteLineCount(String text) =>
    text.codeUnits.where((unit) => unit == 10).length + 1;

/// Whether [text] is large enough to collapse out of the editable field.
bool shouldCollapseAcpComposerPaste(String text) =>
    text.length >= kAcpLargePasteThresholdChars ||
    _acpComposerPasteLineCount(text) >= kAcpLargePasteThresholdLines;

/// Coarse activity of the composer's primary action.
enum AcpComposerActivity {
  /// Nothing is in flight; the primary action sends.
  idle,

  /// Attachments are being prepared before submission.
  preparing,

  /// A prompt is being submitted to the agent.
  sending,

  /// The agent is streaming a response.
  streaming,

  /// A cancellation is in progress.
  cancelling,
}

/// Category of a content-free composer error.
enum AcpComposerErrorKind {
  /// An attachment could not be added or prepared.
  attachment,

  /// The prompt could not be submitted.
  send,
}

/// A safe, content-free composer error.
@immutable
class AcpComposerError {
  /// Creates a composer error.
  const AcpComposerError(this.kind, this.message, {this.attachmentFailure});

  /// Error category.
  final AcpComposerErrorKind kind;

  /// Short, content-free explanation.
  final String message;

  /// The attachment failure category, when [kind] is
  /// [AcpComposerErrorKind.attachment].
  final AcpAttachmentFailure? attachmentFailure;

  /// Whether this error can be resolved by uploading attachments to the
  /// private remote directory instead of embedding them inline.
  bool get isUploadRecoverable =>
      attachmentFailure == AcpAttachmentFailure.inlineSizeLimit ||
      attachmentFailure == AcpAttachmentFailure.imageSizeLimit ||
      attachmentFailure == AcpAttachmentFailure.audioSizeLimit ||
      attachmentFailure == AcpAttachmentFailure.unsupportedCapability;

  @override
  bool operator ==(Object other) =>
      other is AcpComposerError &&
      other.kind == kind &&
      other.message == message &&
      other.attachmentFailure == attachmentFailure;

  @override
  int get hashCode => Object.hash(kind, message, attachmentFailure);
}

/// Preparation status of a single composer attachment.
enum AcpComposerAttachmentStatus {
  /// Selected and waiting to be sent.
  ready,

  /// Currently uploading during preparation.
  uploading,

  /// Preparation failed; the attachment can be retried or removed.
  failed,
}

/// An ordered attachment draft held by the composer.
@immutable
class AcpComposerAttachment {
  /// Creates a composer attachment view model.
  const AcpComposerAttachment({
    required this.id,
    required this.candidate,
    this.fallback = AcpAttachmentFallback.reject,
    this.status = AcpComposerAttachmentStatus.ready,
    this.progress,
    this.errorMessage,
  });

  /// Stable local identifier for keying and updates.
  final String id;

  /// The selected attachment source.
  final AcpAttachmentCandidate candidate;

  /// Behaviour when the attachment cannot be embedded inline.
  final AcpAttachmentFallback fallback;

  /// Current preparation status.
  final AcpComposerAttachmentStatus status;

  /// Upload progress fraction in `0.0`–`1.0`, when uploading and known.
  final double? progress;

  /// Content-free failure explanation, when [status] is failed.
  final String? errorMessage;

  /// User-visible file name.
  String get name => candidate.name;

  /// Whether this attachment resolves to an image, for thumbnail rendering.
  bool get isImage => (candidate.mimeType ?? '').startsWith('image/');

  /// Whether this attachment looks like audio, from its MIME type or name.
  bool get isAudio =>
      (candidate.mimeType ?? lookupMimeType(candidate.name) ?? '').startsWith(
        'audio/',
      );

  /// Whether this is full prompt text represented by a compact paste chip.
  bool get isPastedText => candidate.isPastedText;

  /// Returns a copy with the provided fields replaced.
  AcpComposerAttachment copyWith({
    AcpAttachmentFallback? fallback,
    AcpComposerAttachmentStatus? status,
    double? progress,
    bool clearProgress = false,
    String? errorMessage,
    bool clearError = false,
  }) => AcpComposerAttachment(
    id: id,
    candidate: candidate,
    fallback: fallback ?? this.fallback,
    status: status ?? this.status,
    progress: clearProgress ? null : (progress ?? this.progress),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Holds and coordinates the multiline text, ordered attachments, preparation
/// progress, slash-command query, and send/cancel lifecycle for one ACP
/// session's composer.
///
/// Sending is atomic: it snapshots the current text and attachments, prepares
/// the ACP content blocks through [AcpAttachmentPreparationService], and queues
/// them with [AcpSessionManager.prompt]. Once queued, the submitted draft clears
/// immediately so the user can type steering or follow-up text while the active
/// turn continues. Failed submissions are restored without dropping newer text.
/// A prompt whose answer was lost, or whose turn the user stopped, is offered
/// back through [turnRecovery] instead, since the agent may already have run
/// it.
class AcpComposerController extends ChangeNotifier {
  /// Creates a composer controller for [sessionKey].
  AcpComposerController({
    required AcpSessionManager manager,
    required AcpSessionKey sessionKey,
    AcpAttachmentPreparationService preparationService =
        const AcpAttachmentPreparationService(),
    AcpAttachmentUploader? Function()? uploaderBuilder,
    AcpSessionState? initialSession,
  }) : _manager = manager,
       _sessionKey = sessionKey,
       _preparationService = preparationService,
       _uploaderBuilder = uploaderBuilder,
       _session = initialSession {
    _recomputeSlash();
  }

  final AcpSessionManager _manager;

  /// The session this composer submits prompts to.
  AcpSessionKey get sessionKey => _sessionKey;

  AcpSessionKey _sessionKey;

  final AcpAttachmentPreparationService _preparationService;
  final AcpAttachmentUploader? Function()? _uploaderBuilder;

  AcpSessionState? _session;
  var _text = '';
  var _caret = 0;
  final List<AcpComposerAttachment> _attachments = <AcpComposerAttachment>[];
  var _nextAttachmentId = 0;

  var _sendState = _SendState.idle;
  AcpAttachmentCancellationToken? _cancellation;
  AcpComposerError? _error;

  // A rejected prompt's draft, held while a newer send is still preparing so
  // that send's clear cannot wipe the restored text and attachments.
  /// Rejected drafts waiting for the in-flight send to clear the field,
  /// oldest first; every one of them is merged back once it does.
  final List<({String text, List<AcpComposerAttachment> attachments})>
  _pendingRestores = [];

  AcpSlashQuery? _slashQuery;
  List<AcpAvailableCommand> _slashCommands = const <AcpAvailableCommand>[];

  var _submissions = 0;
  var _retryableFailure = false;
  AcpTurnRecovery? _turnRecovery;

  var _disposed = false;

  /// The current multiline composer text.
  String get text => _text;

  /// The current caret offset within [text].
  int get caret => _caret;

  /// The ordered attachment drafts.
  List<AcpComposerAttachment> get attachments =>
      List<AcpComposerAttachment>.unmodifiable(_attachments);

  /// The latest content-free error, if any.
  AcpComposerError? get error => _error;

  /// Prompts that can be put back in the draft after the agent's answer was
  /// lost or the user stopped the last turn.
  AcpTurnRecovery? get turnRecovery => _turnRecovery;

  /// Whether the draft restored after a confirmed send failure can be sent
  /// again as is. A lost answer never qualifies: the agent may have run it.
  bool get canRetryFailedPrompt =>
      _retryableFailure && _error?.kind == AcpComposerErrorKind.send && canSend;

  /// The ranked slash-command matches for the active query.
  List<AcpAvailableCommand> get slashCommands => _slashCommands;

  /// Whether a slash-command picker should currently be shown.
  bool get isSlashActive => _slashQuery != null && _slashCommands.isNotEmpty;

  /// Attachment safety and resource limits in effect.
  AcpAttachmentLimits get limits => _preparationService.limits;

  /// Whether at least one more attachment can be added.
  bool get canAddAttachment => _attachments.length < limits.maxCount;

  /// The prompt content capabilities advertised by the current session.
  AcpPromptCapabilities get promptCapabilities =>
      _session?.capabilities.prompt ?? const AcpPromptCapabilities();

  /// The coarse activity state of the primary action.
  AcpComposerActivity get activity {
    if (_sendState == _SendState.preparing) {
      return AcpComposerActivity.preparing;
    }
    return switch (_session?.promptStatus) {
      AcpPromptStatus.sending => AcpComposerActivity.sending,
      AcpPromptStatus.streaming => AcpComposerActivity.streaming,
      AcpPromptStatus.cancelling => AcpComposerActivity.cancelling,
      AcpPromptStatus.idle || null => AcpComposerActivity.idle,
    };
  }

  /// Whether the primary action should currently render as a stop control.
  bool get isBusy => activity != AcpComposerActivity.idle;

  /// Whether the composer currently holds text or attachments to send.
  bool get hasContent => _text.trim().isNotEmpty || _attachments.isNotEmpty;

  /// Whether the session is connected and ready to accept a prompt.
  bool get isSessionReady => _session?.status == AcpConnectionStatus.ready;

  /// Whether the primary action can send or queue the current draft right now.
  bool get canSend =>
      _sendState == _SendState.idle && hasContent && isSessionReady;

  /// Whether the in-flight action can be cancelled.
  bool get canCancel =>
      _sendState == _SendState.preparing ||
      activity == AcpComposerActivity.sending ||
      activity == AcpComposerActivity.streaming;

  /// Whether the draft currently accepts edits.
  ///
  /// Active agent turns never lock the next draft. Only local attachment
  /// preparation briefly locks mutation of the snapshot being prepared.
  bool get isEditable => !_disposed && _sendState == _SendState.idle;

  /// Updates the composer text and caret, recomputing the slash query.
  void setText(String value, {int? caret}) {
    if (!isEditable) {
      return;
    }
    final nextCaret = (caret ?? value.length).clamp(0, value.length);
    if (value == _text && nextCaret == _caret) {
      return;
    }
    _text = value;
    _caret = nextCaret;
    _recomputeSlash();
    notifyListeners();
  }

  /// Applies the latest session snapshot, refreshing derived state.
  ///
  /// Callers wire this to the session's state stream so slash commands, prompt
  /// capabilities, and the streaming/idle activity stay live.
  ///
  /// Listeners are only notified when something the composer reads changed:
  /// a streaming pump that touches only the timeline is ignored.
  void updateSession(AcpSessionState? session) {
    if (_applySession(session)) {
      notifyListeners();
    }
  }

  bool _applySession(AcpSessionState? session) {
    final previous = _session;
    _session = session;
    // Snapshots re-wrap the command list, so compare contents rather than
    // list identity; the commands themselves are reused between snapshots.
    final commandsChanged = !listEquals(
      previous?.availableCommands,
      session?.availableCommands,
    );
    if (commandsChanged) {
      _recomputeSlash();
    }
    final previousPrompt = previous?.capabilities.prompt;
    final prompt = session?.capabilities.prompt;
    final recovery = _turnRecovery?.afterSessionUpdate(
      previous: previous,
      session: session,
      latestSubmission: _submissions,
    );
    final recoveryChanged = !identical(recovery, _turnRecovery);
    _turnRecovery = recovery;
    return recoveryChanged ||
        commandsChanged ||
        previous?.status != session?.status ||
        previous?.promptStatus != session?.promptStatus ||
        previousPrompt?.image != prompt?.image ||
        previousPrompt?.audio != prompt?.audio ||
        previousPrompt?.embeddedContext != prompt?.embeddedContext;
  }

  /// Rebinds this draft to [sessionKey] after a resumed ACP session recreates
  /// its expired remote bridge.
  void rebindSession(
    AcpSessionKey sessionKey, {
    required AcpSessionState? session,
  }) {
    _sessionKey = sessionKey;
    _applySession(session);
    notifyListeners();
  }

  /// Adds [candidate] as an ordered attachment.
  ///
  /// Obvious oversize selections (whose reported size already exceeds the
  /// per-file limit) and count-limit violations are rejected here, before the
  /// UI accepts them, and surface a content-free [error].
  bool addAttachment(AcpAttachmentCandidate candidate) {
    if (!isEditable) {
      return false;
    }
    if (!canAddAttachment) {
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.attachment,
          'You can attach up to the allowed number of files.',
        ),
      );
      return false;
    }
    final size = candidate.sizeBytes;
    if (size != null && size > limits.maxFileBytes) {
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.attachment,
          'That file is too large to attach.',
        ),
      );
      return false;
    }
    _attachments.add(
      AcpComposerAttachment(
        id: 'att-${_nextAttachmentId++}',
        candidate: candidate,
      ),
    );
    _error = null;
    notifyListeners();
    return true;
  }

  /// Collapses a large clipboard insertion into an attachment-like text chip.
  bool addPastedText(String text) {
    if (!isEditable || text.isEmpty) return false;
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > limits.maxEmbeddedBytes) {
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.attachment,
          'That pasted text is too large to send.',
        ),
      );
      return false;
    }
    final lineCount = _acpComposerPasteLineCount(text);
    return addAttachment(
      AcpAttachmentCandidate.memory(
        name: lineCount == 1 ? 'Pasted text' : 'Pasted text · $lineCount lines',
        bytes: bytes,
        mimeType: kAcpPastedTextMimeType,
      ),
    );
  }

  /// Removes the attachment with [id].
  void removeAttachment(String id) {
    if (!isEditable) {
      return;
    }
    final before = _attachments.length;
    _attachments.removeWhere((attachment) => attachment.id == id);
    if (_attachments.length != before) {
      notifyListeners();
    }
  }

  /// Clears a failed attachment's error so it is retried on the next send.
  void retryAttachment(String id) {
    if (!isEditable) {
      return;
    }
    final index = _attachments.indexWhere((attachment) => attachment.id == id);
    if (index < 0) {
      return;
    }
    _attachments[index] = _attachments[index].copyWith(
      status: AcpComposerAttachmentStatus.ready,
      clearError: true,
      clearProgress: true,
    );
    notifyListeners();
  }

  /// Marks every attachment to fall back to a private remote upload.
  ///
  /// The UI calls this only after an explicit user confirmation, so a large or
  /// unsupported attachment is never uploaded off-device without consent.
  void enableRemoteUploadFallback() {
    if (!isEditable || _attachments.isEmpty) {
      return;
    }
    for (var i = 0; i < _attachments.length; i++) {
      _attachments[i] = _attachments[i].copyWith(
        fallback: AcpAttachmentFallback.remoteUpload,
        status: AcpComposerAttachmentStatus.ready,
        clearError: true,
      );
    }
    _error = null;
    notifyListeners();
  }

  /// Inserts [command] for the active leading slash token.
  void selectSlashCommand(AcpAvailableCommand command) {
    if (!isEditable) {
      return;
    }
    final insertion = applySlashCommand(fullText: _text, command: command);
    _text = insertion.text;
    _caret = insertion.caret;
    _recomputeSlash();
    notifyListeners();
  }

  /// Dismisses the slash-command picker without changing the text.
  void dismissSlash() {
    if (_slashQuery == null && _slashCommands.isEmpty) {
      return;
    }
    _slashQuery = null;
    _slashCommands = const <AcpAvailableCommand>[];
    notifyListeners();
  }

  /// Clears the current error.
  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    notifyListeners();
  }

  /// Atomically snapshots and submits the current composer contents.
  ///
  /// Returns `true` as soon as the prompt is accepted into the bounded local
  /// session queue, or `false` when preparation/submission failed before it
  /// could be queued.
  Future<bool> send() async {
    if (!canSend) {
      return false;
    }

    final snapshotText = _text.trim();
    final snapshotAttachments = List<AcpComposerAttachment>.of(_attachments);
    final draft = AcpPromptDraft(<AcpPromptDraftItem>[
      if (snapshotText.isNotEmpty) AcpPromptTextDraft(snapshotText),
      for (final attachment in snapshotAttachments)
        AcpAttachmentDraft(
          candidate: attachment.candidate,
          fallback: attachment.fallback,
        ),
    ]);

    final cancellation = AcpAttachmentCancellationToken();
    _cancellation = cancellation;
    _error = null;
    _retryableFailure = false;
    _sendState = _SendState.preparing;
    _markAttachments(AcpComposerAttachmentStatus.ready, clearError: true);
    notifyListeners();

    List<AcpContentBlock> content;
    try {
      content = await _preparationService.prepare(
        draft: draft,
        capabilities: promptCapabilities,
        uploader: _uploaderBuilder?.call(),
        cancellationToken: cancellation,
        onUploadProgress: _onUploadProgress,
      );
    } on AcpAttachmentException catch (exception) {
      if (_disposed) {
        return false;
      }
      _cancellation = null;
      _sendState = _SendState.idle;
      _applyAttachmentFailure(exception);
      _applyPendingRestore();
      notifyListeners();
      return false;
    } on Object {
      if (_disposed) {
        return false;
      }
      _cancellation = null;
      _sendState = _SendState.idle;
      _markAttachments(AcpComposerAttachmentStatus.ready, clearProgress: true);
      _error = const AcpComposerError(
        AcpComposerErrorKind.send,
        'Your message could not be prepared. Try again.',
      );
      _applyPendingRestore();
      notifyListeners();
      return false;
    }

    if (_disposed) {
      return false;
    }
    _cancellation = null;
    _sendState = _SendState.idle;
    _markAttachments(AcpComposerAttachmentStatus.ready, clearProgress: true);

    final Future<AcpPromptResult> promptFuture;
    try {
      promptFuture = _manager.prompt(sessionKey, content);
    } on Object {
      if (_disposed) {
        return false;
      }
      _error = _sendFailedError;
      _applyPendingRestore();
      notifyListeners();
      return false;
    }

    if (_disposed) {
      return true;
    }
    _text = '';
    _caret = 0;
    _attachments.clear();
    _error = null;
    if (_turnRecovery?.withdrawnBySend ?? false) _turnRecovery = null;
    _applyPendingRestore();
    _recomputeSlash();
    notifyListeners();
    unawaited(
      _observePromptResult(
        promptFuture,
        snapshotText,
        snapshotAttachments,
        ++_submissions,
      ),
    );
    return true;
  }

  Future<void> _observePromptResult(
    Future<AcpPromptResult> promptFuture,
    String snapshotText,
    List<AcpComposerAttachment> snapshotAttachments,
    int submission,
  ) async {
    try {
      final result = await promptFuture;
      if (!_disposed &&
          result.stopReason == AcpStopReason.cancelled &&
          submission == _submissions) {
        // An earlier lost or failed prompt still on offer keeps its more
        // cautious wording, with the stopped prompt added after it.
        final previous = _turnRecovery;
        final keepPrevious = previous != null && !previous.withdrawnBySend;
        _turnRecovery = AcpTurnRecovery(
          kind: keepPrevious ? previous.kind : AcpTurnRecoveryKind.cancelled,
          drafts: [
            if (keepPrevious) ...previous.drafts,
            (text: snapshotText, attachments: snapshotAttachments),
          ],
          submission: _submissions,
        );
        notifyListeners();
      }
    } on Object catch (error) {
      if (_disposed) {
        return;
      }
      final failure = classifyAcpPromptFailure(error);
      if (failure != AcpPromptFailure.refused) {
        // The agent may have acted on it: keep the prompt out of the draft so
        // it is not resent by reflex, and offer it back explicitly, together
        // with any earlier prompt still waiting there.
        final previous = _turnRecovery;
        _turnRecovery = AcpTurnRecovery(
          kind: failure == AcpPromptFailure.lost
              ? AcpTurnRecoveryKind.unconfirmed
              : AcpTurnRecoveryKind.failedMidTurn,
          drafts: [
            if (previous != null && !previous.withdrawnBySend)
              ...previous.drafts,
            (text: snapshotText, attachments: snapshotAttachments),
          ],
          submission: _submissions,
        );
        notifyListeners();
        return;
      }
      _retryableFailure = true;
      if (_sendState != _SendState.idle) {
        // A newer send is still preparing and will clear the draft when it
        // finishes; restore after that so the rejected draft survives.
        _pendingRestores.add((
          text: snapshotText,
          attachments: snapshotAttachments,
        ));
        return;
      }
      _error = null;
      _restoreSnapshot(snapshotText, snapshotAttachments);
      _recomputeSlash();
      notifyListeners();
    }
  }

  static const _restoreLimitError = AcpComposerError(
    AcpComposerErrorKind.attachment,
    'Remove some attachments to restore the rest of the prompt.',
  );

  static const _sendFailedError = AcpComposerError(
    AcpComposerErrorKind.send,
    'Your message could not be sent. Try again.',
  );

  /// Resends the draft restored after a confirmed failure.
  Future<bool> retryFailedPrompt() async =>
      canRetryFailedPrompt && await send();

  /// Puts the prompts offered by [turnRecovery] back into the draft, ahead of
  /// anything typed since. Prompts whose attachments would exceed the
  /// attachment limit stay offered.
  void editLastPrompt() {
    final recovery = _turnRecovery;
    if (recovery == null || !isEditable) {
      return;
    }
    var room = limits.maxCount - _attachments.length;
    final restored = <AcpSubmittedDraft>[];
    final kept = <AcpSubmittedDraft>[];
    for (final draft in recovery.drafts) {
      if (kept.isEmpty && draft.attachments.length <= room) {
        restored.add(draft);
        room -= draft.attachments.length;
      } else {
        kept.add(draft);
      }
    }
    _turnRecovery = kept.isEmpty
        ? null
        : AcpTurnRecovery(
            kind: recovery.kind,
            drafts: kept,
            submission: recovery.submission,
            turnResumed: recovery.turnResumed,
          );
    if (kept.isNotEmpty) {
      _error = _restoreLimitError;
    } else if (_error == _restoreLimitError) {
      _error = null;
    }
    for (final draft in restored.reversed) {
      _mergeDraft(draft.text, draft.attachments);
    }
    _recomputeSlash();
    notifyListeners();
  }

  /// Dismisses the offer to restore [turnRecovery].
  void dismissTurnRecovery() {
    if (_turnRecovery == null) {
      return;
    }
    _turnRecovery = null;
    notifyListeners();
  }

  /// Merges a rejected prompt back into the draft. A failure the current send
  /// already reported stays visible; otherwise the send error is shown.
  void _restoreSnapshot(
    String snapshotText,
    List<AcpComposerAttachment> snapshotAttachments,
  ) {
    _mergeDraft(snapshotText, snapshotAttachments);
    _error ??= _sendFailedError;
  }

  void _mergeDraft(
    String snapshotText,
    List<AcpComposerAttachment> snapshotAttachments,
  ) {
    if (snapshotText.isNotEmpty) {
      _text = _text.trim().isEmpty ? snapshotText : '$snapshotText\n\n$_text';
      _caret = _text.length;
    }
    final currentIds = _attachments.map((attachment) => attachment.id).toSet();
    _attachments.insertAll(
      0,
      snapshotAttachments.where(
        (attachment) => !currentIds.contains(attachment.id),
      ),
    );
  }

  void _applyPendingRestore() {
    if (_pendingRestores.isEmpty) {
      return;
    }
    // _restoreSnapshot prepends, so merging newest first keeps the drafts in
    // the order they were sent.
    final restores = _pendingRestores.reversed.toList();
    _pendingRestores.clear();
    for (final restore in restores) {
      _restoreSnapshot(restore.text, restore.attachments);
    }
  }

  /// Cancels the in-flight preparation or streaming turn.
  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    if (_sendState == _SendState.preparing) {
      _cancellation?.cancel();
      return;
    }
    await _manager.cancelPrompt(sessionKey);
  }

  void _onUploadProgress(AcpAttachmentUploadProgress progress) {
    if (_disposed || _sendState != _SendState.preparing) {
      return;
    }
    final index = progress.attachmentIndex;
    if (index < 0 || index >= _attachments.length) {
      return;
    }
    final total = progress.totalBytes;
    final fraction = total != null && total > 0
        ? (progress.bytesTransferred / total).clamp(0.0, 1.0)
        : null;
    _attachments[index] = _attachments[index].copyWith(
      status: AcpComposerAttachmentStatus.uploading,
      progress: fraction,
      clearProgress: fraction == null,
    );
    notifyListeners();
  }

  void _applyAttachmentFailure(AcpAttachmentException exception) {
    if (exception.failure == AcpAttachmentFailure.cancelled) {
      _markAttachments(
        AcpComposerAttachmentStatus.ready,
        clearProgress: true,
        clearError: true,
      );
      return;
    }
    _markAttachments(AcpComposerAttachmentStatus.failed, clearProgress: true);
    _setError(
      AcpComposerError(
        AcpComposerErrorKind.attachment,
        exception.message,
        attachmentFailure: exception.failure,
      ),
    );
  }

  void _markAttachments(
    AcpComposerAttachmentStatus status, {
    bool clearProgress = false,
    bool clearError = false,
  }) {
    for (var i = 0; i < _attachments.length; i++) {
      _attachments[i] = _attachments[i].copyWith(
        status: status,
        clearProgress: clearProgress,
        clearError: clearError,
      );
    }
  }

  void _recomputeSlash() {
    final textBeforeCaret = _text.substring(0, _caret.clamp(0, _text.length));
    final query = parseSlashQuery(textBeforeCaret);
    _slashQuery = query;
    if (query == null) {
      _slashCommands = const <AcpAvailableCommand>[];
      return;
    }
    _slashCommands = matchSlashCommands(
      query.query,
      _session?.availableCommands ?? const <AcpAvailableCommand>[],
    );
  }

  void _setError(AcpComposerError error) {
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    super.dispose();
  }
}

enum _SendState { idle, preparing }
