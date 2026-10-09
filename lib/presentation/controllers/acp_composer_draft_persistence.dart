/// Saves and restores a native chat composer's unsent draft.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/models/acp_composer_draft.dart';
import '../../domain/services/acp_composer_draft_store.dart';
import 'acp_composer_controller.dart';

/// Delay after the last edit before a draft is written to storage.
const Duration kAcpComposerDraftSaveDelay = Duration(milliseconds: 750);

/// Keeps one composer's draft in an [AcpComposerDraftStore].
///
/// On [start] it opens the session's draft through the store: this run's
/// copy straight from memory, otherwise the copy an earlier run saved. A
/// draft from an earlier run carries a restored-draft notice until the user
/// sends, empties or dismisses it, even across composers for the same
/// session. Restoring never sends anything.
///
/// Edits, caret moves included, are saved [saveDelay] after the user stops,
/// and at once when the app leaves the foreground or the composer goes away.
/// An emptied draft, including one just accepted by
/// [AcpComposerController.send], is deleted straight away.
///
/// Nothing is written until the saved draft has been read, so an empty
/// composer can never overwrite it. If the composer goes away first, what
/// was typed is merged after the saved draft once the read finishes.
class AcpComposerDraftPersistence {
  /// Creates a draft binding for [controller].
  AcpComposerDraftPersistence({
    required AcpComposerController controller,
    required AcpComposerDraftStore store,
    this.saveDelay = kAcpComposerDraftSaveDelay,
  }) : _controller = controller,
       _store = store,
       _identity = AcpComposerDraftIdentity.of(controller.sessionKey);

  final AcpComposerController _controller;
  final AcpComposerDraftStore _store;

  /// Delay after the last edit before saving.
  final Duration saveDelay;

  AcpComposerDraftIdentity _identity;
  AppLifecycleListener? _lifecycle;
  Timer? _saveTimer;
  AcpOpenedComposerDraft? _pendingRestore;
  var _started = false;
  var _applyingRestore = false;
  var _ready = false;
  var _changedBeforeReady = false;
  var _dirty = false;
  var _disposed = false;
  String? _lastText;
  int? _lastCaret;
  List<AcpComposerAttachment> _lastAttachments =
      const <AcpComposerAttachment>[];
  AcpRestoredDraftNotice? _lastNotice;

  /// Whether the saved draft has been read and applied, so edits are saved.
  @visibleForTesting
  bool get isReady => _ready;

  /// Restores the session's draft and starts saving edits.
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _controller.addListener(_onControllerChanged);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    final known = _store.peek(_identity);
    if (known != null) {
      _restore(known);
      return;
    }
    unawaited(_open());
  }

  Future<void> _open() async {
    final opened = await _store.open(_identity);
    if (_disposed) {
      return;
    }
    // Another composer for this session may have merged edits into the
    // store while the read was in flight; the store holds the latest.
    _restore(_store.peek(_identity) ?? opened);
  }

  void _restore(AcpOpenedComposerDraft opened) {
    if (opened.draft.isEmpty && opened.notice == null) {
      _becomeReady();
      return;
    }
    _pendingRestore = opened;
    _applyPendingRestore();
  }

  void _applyPendingRestore() {
    final pending = _pendingRestore;
    if (pending == null) {
      return;
    }
    _pendingRestore = null;
    _applyingRestore = true;
    final bool applied;
    try {
      applied = _controller.restoreDraft(pending.draft, notice: pending.notice);
    } finally {
      _applyingRestore = false;
    }
    if (!applied) {
      // A send is being prepared; merge once it finishes.
      _pendingRestore = pending;
      return;
    }
    _becomeReady();
  }

  void _becomeReady() {
    if (_ready || _disposed) {
      return;
    }
    _ready = true;
    _lastNotice = _controller.restoredDraftNotice;
    // Only save if the user edited before the saved draft arrived; otherwise
    // the composer already matches what is stored.
    _sync(save: _changedBeforeReady);
  }

  void _onControllerChanged() {
    if (_disposed || _applyingRestore) {
      return;
    }
    if (!_ready) {
      if (_controller.hasContent) {
        _changedBeforeReady = true;
      }
      _applyPendingRestore();
      return;
    }
    _sync(save: true);
  }

  void _sync({required bool save}) {
    var shouldSave = save;
    final identity = AcpComposerDraftIdentity.of(_controller.sessionKey);
    if (identity != _identity) {
      // A resumed session may come back under a new ACP session id; move the
      // draft with it.
      unawaited(_store.clear(_identity));
      _identity = identity;
      _lastText = null;
      shouldSave = true;
    }
    final notice = _controller.restoredDraftNotice;
    if (_lastNotice != null && notice == null) {
      // Sent, emptied or dismissed: no other composer should show it again.
      _store.acknowledgeRestore(_identity);
    }
    _lastNotice = notice;
    final text = _controller.text;
    final caret = _controller.caret;
    final attachments = _controller.attachments;
    if (text == _lastText &&
        caret == _lastCaret &&
        _sameAttachments(attachments)) {
      return;
    }
    _lastText = text;
    _lastCaret = caret;
    _lastAttachments = attachments;
    final draft = _controller.draftSnapshot;
    _store.remember(_identity, draft);
    if (!shouldSave) {
      return;
    }
    if (draft.isEmpty) {
      _saveTimer?.cancel();
      _saveTimer = null;
      _dirty = false;
      unawaited(_store.save(_identity, draft));
      return;
    }
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  bool _sameAttachments(List<AcpComposerAttachment> attachments) {
    if (attachments.length != _lastAttachments.length) {
      return false;
    }
    for (var i = 0; i < attachments.length; i++) {
      final current = attachments[i];
      final previous = _lastAttachments[i];
      if (current.id != previous.id || current.fallback != previous.fallback) {
        return false;
      }
    }
    return true;
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(flush());
    }
  }

  /// Writes any unsaved edits now.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty || !_ready) {
      return Future<void>.value();
    }
    _dirty = false;
    // Snapshot synchronously: the controller may be disposed right after.
    return _store.save(_identity, _controller.draftSnapshot);
  }

  /// Stops saving and deletes the session's draft, for a deleted session.
  void discard() {
    if (_disposed) {
      return;
    }
    final identity = _identity;
    _stop();
    unawaited(_store.clear(identity));
  }

  /// Saves pending edits and stops observing the composer.
  ///
  /// Call before disposing the controller.
  void dispose() {
    if (_disposed) {
      return;
    }
    if (_ready) {
      unawaited(flush());
    } else if (_started && _controller.hasContent) {
      unawaited(_saveAfterOpen(_controller.draftSnapshot));
    }
    _stop();
  }

  /// Merges [typed], captured before the saved draft was read, after that
  /// draft once the read finishes, and saves the result.
  Future<void> _saveAfterOpen(AcpComposerDraftSnapshot typed) async {
    final identity = _identity;
    final maxAttachments = _controller.limits.maxCount;
    final opened = await _store.open(identity);
    if (!opened.writable) {
      return;
    }
    final saved = _store.peek(identity)?.draft ?? opened.draft;
    await _store.save(
      identity,
      saved.followedBy(typed, maxAttachments: maxAttachments),
    );
  }

  void _stop() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _disposed = true;
    _pendingRestore = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_started) {
      _controller.removeListener(_onControllerChanged);
    }
  }
}
