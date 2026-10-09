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
/// On [start] it puts back the session's draft: this run's copy straight from
/// memory, otherwise the copy an earlier run saved, which the composer then
/// marks as restored. Restoring never sends anything.
///
/// Edits are saved [saveDelay] after the user stops typing, and at once when
/// the app leaves the foreground or the composer goes away. An emptied draft,
/// including one just accepted by [AcpComposerController.send], is deleted
/// straight away. Nothing is written until the saved draft has been read, so
/// an empty composer can never overwrite it.
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
  ({AcpComposerDraftSnapshot draft, AcpRestoredDraftNotice? notice})?
  _pendingRestore;
  var _started = false;
  var _applyingRestore = false;
  var _ready = false;
  var _changedBeforeReady = false;
  var _dirty = false;
  var _disposed = false;
  String? _lastText;
  List<AcpComposerAttachment> _lastAttachments =
      const <AcpComposerAttachment>[];

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
    final remembered = _store.rememberedDraft(_identity);
    if (remembered != null) {
      _restore(remembered, notice: null);
      return;
    }
    final announce = !_store.seenThisRun(_identity);
    unawaited(_loadSaved(announce: announce));
  }

  Future<void> _loadSaved({required bool announce}) async {
    AcpRestoredComposerDraft? restored;
    try {
      restored = await _store.loadSaved(_identity);
    } on Object {
      restored = null;
    }
    if (_disposed) {
      return;
    }
    if (restored == null) {
      _becomeReady();
      return;
    }
    _restore(
      restored.draft,
      notice: announce
          ? AcpRestoredDraftNotice(
              unavailableAttachmentCount: restored.unavailableAttachmentCount,
            )
          : null,
    );
  }

  void _restore(
    AcpComposerDraftSnapshot draft, {
    required AcpRestoredDraftNotice? notice,
  }) {
    if (draft.isEmpty) {
      _becomeReady();
      return;
    }
    _pendingRestore = (draft: draft, notice: notice);
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
    final text = _controller.text;
    final attachments = _controller.attachments;
    if (text == _lastText && _sameAttachments(attachments)) {
      return;
    }
    _lastText = text;
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

  /// Saves pending edits and stops observing the composer.
  ///
  /// Call before disposing the controller.
  void dispose() {
    if (_disposed) {
      return;
    }
    unawaited(flush());
    _disposed = true;
    _pendingRestore = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_started) {
      _controller.removeListener(_onControllerChanged);
    }
  }
}
