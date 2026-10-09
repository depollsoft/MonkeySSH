/// Keeps unsent native chat drafts so they survive the OS evicting the app.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_attachment.dart';
import '../models/acp_composer_draft.dart';
import 'diagnostics_log_service.dart';
import 'settings_json_list.dart';
import 'settings_service.dart';

/// Returns the current size of the local file at a path, or `null` when it
/// is gone or unreadable.
typedef AcpDraftLocalFileProbe = Future<int?> Function(String path);

/// A draft saved by an earlier run of the app, ready to put back in the
/// composer.
@immutable
final class AcpRestoredComposerDraft {
  /// Creates a restored draft.
  const AcpRestoredComposerDraft({
    required this.draft,
    this.unavailableAttachmentCount = 0,
  });

  /// The text and attachments that could be restored.
  final AcpComposerDraftSnapshot draft;

  /// Attachments that were dropped because they expired, disappeared, or
  /// were never storable.
  final int unavailableAttachmentCount;
}

/// Saves one unsent composer draft per ACP session.
///
/// Drafts live in the app database (one settings row per session, under
/// [SettingKeys.acpComposerDraftPrefix]), which is file-protected on Apple
/// platforms and excluded from migration exports. The store also remembers
/// the latest draft of each session in memory for the life of the process,
/// so reopening a session in the same run is instant and keeps attachments
/// that cannot be stored.
///
/// Draft text is user content: it is never logged. Diagnostics carry only
/// error types.
class AcpComposerDraftStore {
  /// Creates a draft store backed by [settings].
  AcpComposerDraftStore(
    this._settings, {
    DiagnosticsLogger diagnostics = const NoopDiagnosticsLogger(),
    DateTime Function()? clock,
    AcpDraftLocalFileProbe? probeLocalFile,
    this.attachmentLifetime = const Duration(hours: 24),
    this.draftLifetime = const Duration(days: 30),
    this.maxSavedDrafts = 50,
    this.maxRememberedDrafts = 12,
    this.pastedTextBudget = 4 * 1024 * 1024,
  }) : _diagnostics = diagnostics,
       _clock = clock ?? DateTime.now,
       _probeLocalFile = probeLocalFile ?? _defaultProbe;

  final SettingsService _settings;
  final DiagnosticsLogger _diagnostics;
  final DateTime Function() _clock;
  final AcpDraftLocalFileProbe _probeLocalFile;

  /// How long picked-file references stay usable after the last save.
  final Duration attachmentLifetime;

  /// How long an untouched draft is kept at all.
  final Duration draftLifetime;

  /// Most drafts kept on disk; the oldest go first.
  final int maxSavedDrafts;

  /// Most drafts kept in memory for this run; the least recent go first.
  final int maxRememberedDrafts;

  /// Combined length of pasted-text chips kept per draft, in UTF-16 units.
  final int pastedTextBudget;

  final _mutations = SerializedMutations();
  final LinkedHashMap<String, AcpComposerDraftSnapshot> _remembered =
      LinkedHashMap<String, AcpComposerDraftSnapshot>();
  final Set<String> _seen = <String>{};
  Future<void>? _pruning;

  /// This run's latest draft for [identity], or `null` when it is not in
  /// memory. An empty snapshot means the draft was cleared in this run.
  AcpComposerDraftSnapshot? rememberedDraft(AcpComposerDraftIdentity identity) {
    final key = identity.value;
    final draft = _remembered.remove(key);
    if (draft != null) _remembered[key] = draft;
    return draft;
  }

  /// Whether this run already opened or saved [identity]'s draft, so a saved
  /// copy on disk is not news to the user.
  bool seenThisRun(AcpComposerDraftIdentity identity) =>
      _seen.contains(identity.value);

  /// Records [draft] as this run's latest draft for [identity], in memory.
  void remember(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot draft,
  ) {
    final key = identity.value;
    _seen.add(key);
    _remembered
      ..remove(key)
      ..[key] = draft;
    while (_remembered.length > maxRememberedDrafts) {
      _remembered.remove(_remembered.keys.first);
    }
  }

  /// Loads the draft an earlier run saved for [identity].
  ///
  /// Expired drafts are deleted. Picked-file references older than
  /// [attachmentLifetime], or whose file is gone or changed size, are dropped
  /// and counted in [AcpRestoredComposerDraft.unavailableAttachmentCount].
  /// Returns `null` when nothing restorable is left.
  Future<AcpRestoredComposerDraft?> loadSaved(
    AcpComposerDraftIdentity identity,
  ) async {
    _seen.add(identity.value);
    final storageKey = _storageKey(identity);
    String? raw;
    await _run('load_failed', () async {
      await _pruneOnce();
      raw = await _settings.getString(storageKey);
    });
    final encoded = raw;
    if (encoded == null) return null;
    final saved = _decode(encoded);
    final now = _clock().toUtc();
    if (saved == null || now.difference(saved.savedAt) > draftLifetime) {
      unawaited(_run('delete_failed', () => _settings.delete(storageKey)));
      return null;
    }
    final attachmentsExpired =
        now.difference(saved.savedAt) > attachmentLifetime;
    final attachments = <AcpAttachmentDraft>[];
    var unavailable = saved.unsavedAttachmentCount;
    for (final attachment in saved.attachments) {
      final restored = await _restoreAttachment(
        attachment,
        expired: attachmentsExpired,
      );
      if (restored == null) {
        unavailable++;
      } else {
        attachments.add(restored);
      }
    }
    final draft = AcpComposerDraftSnapshot(
      text: saved.text,
      caret: saved.caret,
      attachments: attachments,
    );
    if (draft.isEmpty) {
      unawaited(_run('delete_failed', () => _settings.delete(storageKey)));
      return null;
    }
    return AcpRestoredComposerDraft(
      draft: draft,
      unavailableAttachmentCount: unavailable,
    );
  }

  /// Saves [draft] for [identity], or deletes the saved copy when [draft] is
  /// empty. Writes run in call order; failures are swallowed.
  Future<void> save(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot draft,
  ) {
    remember(identity, draft);
    final storageKey = _storageKey(identity);
    if (draft.isEmpty) {
      return _run('delete_failed', () => _settings.delete(storageKey));
    }
    final saved = AcpSavedComposerDraft.capture(
      draft,
      savedAt: _clock(),
      pastedTextBudget: pastedTextBudget,
    );
    return _run('save_failed', () async {
      await _pruneOnce();
      await _settings.setString(storageKey, jsonEncode(saved.toJson()));
    });
  }

  /// Forgets and deletes [identity]'s draft.
  Future<void> clear(AcpComposerDraftIdentity identity) =>
      save(identity, AcpComposerDraftSnapshot(text: ''));

  Future<AcpAttachmentDraft?> _restoreAttachment(
    AcpSavedDraftAttachment attachment, {
    required bool expired,
  }) async {
    switch (attachment) {
      case AcpSavedPastedText(:final name, :final text):
        return AcpAttachmentDraft(
          candidate: AcpAttachmentCandidate.memory(
            name: name,
            bytes: Uint8List.fromList(utf8.encode(text)),
            mimeType: kAcpPastedTextMimeType,
          ),
        );
      case AcpSavedLocalFile(
        :final name,
        :final path,
        :final sizeBytes,
        :final mimeType,
        :final fallback,
      ):
        if (expired) return null;
        int? currentSize;
        try {
          currentSize = await _probeLocalFile(path);
        } on Object {
          currentSize = null;
        }
        if (currentSize == null ||
            (sizeBytes != null && sizeBytes != currentSize)) {
          return null;
        }
        return AcpAttachmentDraft(
          candidate: AcpAttachmentCandidate.localFile(
            name: name,
            openRead: () => File(path).openRead(),
            sizeBytes: currentSize,
            mimeType: mimeType,
            localPath: path,
          ),
          fallback: fallback,
        );
      case AcpSavedRemoteFile(
        :final name,
        :final remotePath,
        :final sizeBytes,
        :final mimeType,
        :final fallback,
      ):
        if (expired) return null;
        return AcpAttachmentDraft(
          candidate: AcpAttachmentCandidate.remoteFile(
            name: name,
            remotePath: remotePath,
            sizeBytes: sizeBytes,
            mimeType: mimeType,
          ),
          fallback: fallback,
        );
    }
  }

  /// Deletes expired, unreadable, and surplus drafts once per run. A failed
  /// prune is logged and not retried, so it never blocks saving.
  Future<void> _pruneOnce() => _pruning ??= _prune().catchError((Object error) {
    _diagnostics.warning(
      'acp.composer_draft',
      'prune_failed',
      fields: {'errorType': error.runtimeType},
    );
  });

  Future<void> _prune() async {
    final rows = await _settings.getStringsWithPrefix(
      SettingKeys.acpComposerDraftPrefix,
    );
    final now = _clock().toUtc();
    final kept = <({String key, DateTime savedAt})>[];
    for (final MapEntry(:key, :value) in rows.entries) {
      final savedAt =
          AcpSavedComposerDraft.peekSavedAt(value) ?? _decode(value)?.savedAt;
      if (savedAt == null || now.difference(savedAt) > draftLifetime) {
        await _settings.delete(key);
      } else {
        kept.add((key: key, savedAt: savedAt));
      }
    }
    if (kept.length <= maxSavedDrafts) return;
    kept.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    for (final stale in kept.skip(maxSavedDrafts)) {
      await _settings.delete(stale.key);
    }
  }

  Future<void> _run(String failure, Future<void> Function() action) =>
      _mutations.run(action).catchError((Object error) {
        _diagnostics.warning(
          'acp.composer_draft',
          failure,
          fields: {'errorType': error.runtimeType},
        );
      });

  static AcpSavedComposerDraft? _decode(String encoded) {
    try {
      return AcpSavedComposerDraft.tryFromJson(jsonDecode(encoded));
    } on FormatException {
      return null;
    }
  }

  static String _storageKey(AcpComposerDraftIdentity identity) =>
      '${SettingKeys.acpComposerDraftPrefix}${identity.value}';

  static Future<int?> _defaultProbe(String path) async {
    final stat = await FileStat.stat(path);
    return stat.type == FileSystemEntityType.file ? stat.size : null;
  }
}

/// Provider for [AcpComposerDraftStore].
final acpComposerDraftStoreProvider = Provider<AcpComposerDraftStore>(
  (ref) => AcpComposerDraftStore(
    ref.watch(settingsServiceProvider),
    diagnostics: ref.watch(diagnosticsLoggerProvider),
  ),
);
