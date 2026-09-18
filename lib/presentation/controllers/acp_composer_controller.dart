/// The non-visual state and behaviour behind the ACP composer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_content.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_updates.dart';
import '../../domain/services/acp_attachment_service.dart';
import '../../domain/services/acp_session_manager.dart';
import '../models/acp_slash_command.dart';

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

  // Monotonic id of the current send operation. Bumped when a send starts so
  // any awaited continuation from a superseded (or post-dispose) operation can
  // detect that it is stale and avoid mutating state or notifying listeners.
  var _operation = 0;

  AcpSlashQuery? _slashQuery;
  List<AcpAvailableCommand> _slashCommands = const <AcpAvailableCommand>[];

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
    switch (_sendState) {
      case _SendState.preparing:
        return AcpComposerActivity.preparing;
      case _SendState.submitting:
        return AcpComposerActivity.sending;
      case _SendState.idle:
        break;
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

  bool _isStale(int generation) => _disposed || generation != _operation;

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
  void updateSession(AcpSessionState? session) {
    final commandsChanged = !identical(
      _session?.availableCommands,
      session?.availableCommands,
    );
    _session = session;
    if (commandsChanged) {
      _recomputeSlash();
    }
    notifyListeners();
  }

  /// Rebinds this draft to [sessionKey] after a resumed ACP session recreates
  /// its expired remote bridge.
  void rebindSession(
    AcpSessionKey sessionKey, {
    required AcpSessionState? session,
  }) {
    _sessionKey = sessionKey;
    updateSession(session);
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

    final generation = ++_operation;
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
      if (_isStale(generation)) {
        return false;
      }
      _cancellation = null;
      _sendState = _SendState.idle;
      _applyAttachmentFailure(exception);
      notifyListeners();
      return false;
    } on Object {
      if (_isStale(generation)) {
        return false;
      }
      _cancellation = null;
      _sendState = _SendState.idle;
      _markAttachments(AcpComposerAttachmentStatus.ready, clearProgress: true);
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.send,
          'Your message could not be prepared. Try again.',
        ),
      );
      notifyListeners();
      return false;
    }

    if (_isStale(generation)) {
      return false;
    }
    _cancellation = null;
    _sendState = _SendState.submitting;
    _markAttachments(AcpComposerAttachmentStatus.ready, clearProgress: true);
    notifyListeners();

    final Future<AcpPromptResult> promptFuture;
    try {
      promptFuture = _manager.prompt(sessionKey, content);
    } on Object {
      if (_isStale(generation)) {
        return false;
      }
      _sendState = _SendState.idle;
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.send,
          'Your message could not be sent. Try again.',
        ),
      );
      return false;
    }

    if (_isStale(generation)) {
      return true;
    }
    _sendState = _SendState.idle;
    _text = '';
    _caret = 0;
    _attachments.clear();
    _error = null;
    _recomputeSlash();
    notifyListeners();
    unawaited(
      _observePromptResult(promptFuture, snapshotText, snapshotAttachments),
    );
    return true;
  }

  Future<void> _observePromptResult(
    Future<AcpPromptResult> promptFuture,
    String snapshotText,
    List<AcpComposerAttachment> snapshotAttachments,
  ) async {
    try {
      await promptFuture;
    } on Object {
      if (_disposed) {
        return;
      }
      if (snapshotText.isNotEmpty) {
        _text = _text.trim().isEmpty ? snapshotText : '$snapshotText\n\n$_text';
        _caret = _text.length;
      }
      final currentIds = _attachments
          .map((attachment) => attachment.id)
          .toSet();
      _attachments.insertAll(
        0,
        snapshotAttachments.where(
          (attachment) => !currentIds.contains(attachment.id),
        ),
      );
      _setError(
        const AcpComposerError(
          AcpComposerErrorKind.send,
          'Your message could not be sent. Try again.',
        ),
      );
      _recomputeSlash();
      notifyListeners();
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

enum _SendState { idle, preparing, submitting }
