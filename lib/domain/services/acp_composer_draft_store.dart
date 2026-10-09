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

/// Returns the size and modification time of the local file at a path, or
/// `null` when it is gone or is not a regular file.
typedef AcpDraftLocalFileProbe = Future<AcpDraftFileStamp?> Function(
  String path,
);

/// A session's draft as a composer should open it.
@immutable
final class AcpOpenedComposerDraft {
  /// Creates an opened draft.
  const AcpOpenedComposerDraft({
    required this.draft,
    this.notice,
    this.writable = true,
  });

  /// Text and attachments to put in the composer.
  final AcpComposerDraftSnapshot draft;

  /// Set while the draft came from an earlier run of the app and the user
  /// has not yet sent, emptied or dismissed it.
  final AcpRestoredDraftNotice? notice;

  /// Whether edits may be saved. `false` after the saved draft could not be
  /// read, so a failed read never turns into an overwrite.
  final bool writable;
}

/// Saves one unsent composer draft per ACP session.
///
/// Drafts live in the app database, which is file-protected on Apple
/// platforms and excluded from migration exports. Each session has a small
/// draft row under [SettingKeys.acpComposerDraftPrefix] that is rewritten as
/// the user types, and a chips row under
/// [SettingKeys.acpComposerDraftChipsPrefix] with the text of large pastes,
/// written only when the chips change.
///
/// The store also keeps each session's state for the life of the process:
/// the latest draft (so reopening a session is instant and keeps pasted
/// images, which are never stored), whether the restored-draft notice is
/// still pending, and whether the saved draft could be read at all.
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
    this.pastedTextBudget = 1024 * 1024,
  }) : _diagnostics = diagnostics,
       _clock = clock ?? DateTime.now,
       _probeLocalFile = probeLocalFile ?? _defaultProbe;

  final SettingsService _settings;
  final DiagnosticsLogger _diagnostics;
  final DateTime Function() _clock;
  final AcpDraftLocalFileProbe _probeLocalFile;

  /// How long a picked-file reference stays usable after it was added.
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
  final Map<String, int> _pendingNotices = <String, int>{};
  final Set<String> _unreadable = <String>{};
  final Map<String, Future<AcpOpenedComposerDraft>> _loads = {};
  final Map<String, List<AcpAttachmentCandidate>> _savedChips = {};
  final Map<String, int> _generations = <String, int>{};
  final Map<String, List<({AcpComposerDraftSnapshot typed, int? max})>>
  _pendingAppends = {};
  final Set<int> _forgottenHosts = <int>{};
  final Expando<DateTime> _addedAt = Expando<DateTime>('addedAt');
  final Expando<AcpDraftFileStamp> _fileStamps = Expando<AcpDraftFileStamp>(
    'fileStamp',
  );
  final Expando<String> _chipTexts = Expando<String>('chipText');
  Future<void>? _pruning;

  /// This run's state for [identity] when it is known without reading
  /// storage, or `null` when the saved draft still has to be read.
  AcpOpenedComposerDraft? peek(AcpComposerDraftIdentity identity) {
    final key = identity.value;
    final draft = _remembered.remove(key);
    if (draft != null) _remembered[key] = draft;
    if (_unreadable.contains(key)) {
      return AcpOpenedComposerDraft(draft: draft ?? _empty, writable: false);
    }
    if (draft == null) return null;
    return AcpOpenedComposerDraft(draft: draft, notice: _noticeFor(key));
  }

  /// Opens [identity]'s draft: this run's state when known, otherwise the
  /// draft an earlier run saved. Concurrent callers share one read.
  Future<AcpOpenedComposerDraft> open(AcpComposerDraftIdentity identity) {
    final known = peek(identity);
    if (known != null) return Future<AcpOpenedComposerDraft>.value(known);
    final key = identity.value;
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _loads[key] ??= _load(identity)
        .catchError((Object error) {
          // Unexpected: treat like a failed read, never as "no draft".
          _log('load_failed', error);
          _unreadable.add(key);
          return peek(identity)!;
        })
        .whenComplete(() {
          _loads.remove(key);
        });
  }

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
      final evicted = _remembered.keys.first;
      _remembered.remove(evicted);
      // Drop the chips record with the snapshot, so evicted pastes are not
      // kept alive; the next save of that session rewrites its chips row.
      _savedChips.remove(evicted);
    }
  }

  /// Marks [identity]'s restored-draft notice as seen to the end: sent,
  /// emptied or dismissed. Later opens in this run show no notice.
  void acknowledgeRestore(AcpComposerDraftIdentity identity) =>
      _pendingNotices.remove(identity.value);

  /// Saves [draft] for [identity], or deletes the saved copy when [draft] is
  /// empty. Writes run in call order; failures are logged and swallowed.
  ///
  /// Nothing is written for a session whose saved draft could not be read
  /// in this run, so the unread draft is never overwritten.
  Future<void> save(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot draft,
  ) {
    remember(identity, draft);
    if (draft.isEmpty) _pendingNotices.remove(identity.value);
    if (_unreadable.contains(identity.value) ||
        _forgottenHosts.contains(identity.hostId)) {
      return Future<void>.value();
    }
    final savedAt = _clock().toUtc();
    for (final attachment in draft.attachments) {
      _addedAt[attachment.candidate] ??= savedAt;
    }
    // Queued ahead of the write, so this session's row is never pruned.
    unawaited(_pruneOnce());
    return _run('save_failed', () => _write(identity, draft, savedAt: savedAt));
  }

  /// Forgets and deletes [identity]'s draft, for example when its session is
  /// deleted. A read still in flight for it is abandoned, so it cannot write
  /// the draft back.
  Future<void> clear(AcpComposerDraftIdentity identity) {
    final key = identity.value;
    _invalidate(key);
    _unreadable.remove(key);
    return save(identity, AcpComposerDraftSnapshot(text: ''));
  }

  /// Moves this run's draft state from [from] to [to], for a session that
  /// came back under a new ACP session id. The caller saves the draft under
  /// [to] next.
  ///
  /// When [from]'s saved draft could not be read, its rows are left alone
  /// and [to] is not written either, so the unread draft survives.
  Future<void> move(
    AcpComposerDraftIdentity from,
    AcpComposerDraftIdentity to,
  ) {
    final fromKey = from.value;
    final toKey = to.value;
    if (fromKey == toKey) return Future<void>.value();
    final notice = _pendingNotices.remove(fromKey);
    if (notice != null) _pendingNotices[toKey] = notice;
    if (_unreadable.contains(fromKey)) {
      _unreadable.add(toKey);
      _remembered.remove(fromKey);
      return Future<void>.value();
    }
    return clear(from);
  }

  /// Adds [typed], from a composer that closed before [identity]'s saved
  /// draft was read, after that draft, and saves the result.
  ///
  /// When the read is still in flight, the text is merged before the read
  /// completes, so every composer waiting on it gets the merged draft.
  void appendWhenOpened(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot typed, {
    int? maxAttachments,
  }) {
    if (typed.isEmpty) return;
    final key = identity.value;
    if (peek(identity) == null) unawaited(open(identity));
    if (_loads.containsKey(key)) {
      (_pendingAppends[key] ??= []).add((typed: typed, max: maxAttachments));
      return;
    }
    final base = peek(identity)?.draft ?? _empty;
    unawaited(
      save(identity, base.followedBy(typed, maxAttachments: maxAttachments)),
    );
  }

  /// Forgets every draft of deleted host [hostId] and deletes its rows.
  ///
  /// The deletion is queued behind writes already in flight, and later
  /// saves for the host are dropped for the rest of the run.
  Future<void> forgetHost(int hostId) {
    _forgottenHosts.add(hostId);
    final prefix = '[$hostId,';
    final keys = <String>{
      ..._remembered.keys,
      ..._pendingNotices.keys,
      ..._unreadable,
      ..._loads.keys,
      ..._savedChips.keys,
      ..._pendingAppends.keys,
    }.where((key) => key.startsWith(prefix));
    for (final key in keys.toList()) {
      _invalidate(key);
      _remembered.remove(key);
      _pendingNotices.remove(key);
      _unreadable.remove(key);
    }
    return _run('delete_failed', () async {
      final doomed = <String, String?>{};
      for (final rowPrefix in SettingKeys.acpComposerDraftHostPrefixes(
        hostId,
      )) {
        for (final key in await _settings.getKeysWithPrefix(rowPrefix)) {
          doomed[key] = null;
        }
      }
      if (doomed.isNotEmpty) await _settings.setStrings(doomed);
    });
  }

  /// Abandons any read in flight for [key] and drops its queued appends.
  void _invalidate(String key) {
    _generations[key] = (_generations[key] ?? 0) + 1;
    _pendingAppends.remove(key);
    _savedChips.remove(key);
  }

  int _generation(String key) => _generations[key] ?? 0;

  /// Deletes expired, unreadable and surplus drafts. Runs once per process;
  /// later calls return the first run's future. Drafts opened or saved in
  /// this run are never deleted here.
  Future<void> pruneExpired() => _pruneOnce();

  Future<AcpOpenedComposerDraft> _load(
    AcpComposerDraftIdentity identity,
  ) async {
    final key = identity.value;
    final generation = _generation(key);
    final draftKey = _draftKey(identity);
    final chipsKey = _chipsKey(identity);
    String? raw;
    String? rawChips;
    try {
      await _mutations.run(() async {
        raw = await _settings.getString(draftKey);
        if (raw != null) rawChips = await _settings.getString(chipsKey);
      });
    } on Object catch (error) {
      _log('load_failed', error);
      if (_generation(key) != generation) return _abandoned(identity);
      _unreadable.add(key);
      // Keep anything typed meanwhile in memory; it is never written.
      final typed = _takeAppends(key, _empty);
      if (!typed.isEmpty) remember(identity, typed);
      return peek(identity)!;
    }
    if (_generation(key) != generation) return _abandoned(identity);
    final announce = !_seen.contains(key);
    final encoded = raw;
    final saved = encoded == null ? null : _decode(encoded);
    final now = _clock().toUtc();
    if (saved == null || now.difference(saved.savedAt) > draftLifetime) {
      if (encoded != null) _queueCleanup(identity, generation, _empty);
      return _finishLoad(identity, generation, _empty);
    }
    final chips = rawChips == null
        ? const <String>[]
        : AcpSavedComposerDraft.decodeChips(rawChips!) ?? const <String>[];
    final attachments = <AcpAttachmentDraft>[];
    final restoredChips = <AcpAttachmentCandidate>[];
    var unavailable = saved.unsavedAttachmentCount;
    for (final attachment in saved.attachments) {
      final restored = await _restoreAttachment(attachment, chips, now);
      if (restored == null) {
        unavailable++;
        continue;
      }
      _addedAt[restored.candidate] = attachment.addedAt;
      if (attachment is AcpSavedPastedText) {
        restoredChips.add(restored.candidate);
      }
      attachments.add(restored);
    }
    // A clear() during the file checks wins: write and remember nothing.
    if (_generation(key) != generation) return _abandoned(identity);
    final draft = AcpComposerDraftSnapshot(
      text: saved.text,
      caret: saved.caret,
      attachments: attachments,
    );
    if (unavailable > 0 || saved.isLegacy) {
      // Rewrite without what was lost, in the current format, so the next
      // launch does not report the same loss again. Keep the save time.
      _queueCleanup(identity, generation, draft, savedAt: saved.savedAt);
    } else {
      _savedChips[key] = restoredChips;
    }
    // A draft from an earlier run is announced. A draft from this run that
    // comes back from disk (its memory copy was evicted) is announced only
    // if something was lost, such as a pasted image.
    if (announce ? (!draft.isEmpty || unavailable > 0) : unavailable > 0) {
      _pendingNotices[key] = unavailable;
    }
    return _finishLoad(identity, generation, draft);
  }

  /// Folds in text from composers that closed during the read, saves the
  /// merged draft if there was any, and records the result.
  AcpOpenedComposerDraft _finishLoad(
    AcpComposerDraftIdentity identity,
    int generation,
    AcpComposerDraftSnapshot loaded,
  ) {
    final merged = _takeAppends(identity.value, loaded);
    if (!identical(merged, loaded)) {
      _queueCleanup(identity, generation, merged, savedAt: _clock().toUtc());
    }
    return _opened(identity, merged);
  }

  AcpComposerDraftSnapshot _takeAppends(
    String key,
    AcpComposerDraftSnapshot base,
  ) {
    final appends = _pendingAppends.remove(key);
    if (appends == null) return base;
    var merged = base;
    for (final append in appends) {
      merged = merged.followedBy(append.typed, maxAttachments: append.max);
    }
    return merged;
  }

  /// Queues a write of [draft] (or a delete when it is empty) that is
  /// skipped if [identity] was cleared after [generation] was taken.
  void _queueCleanup(
    AcpComposerDraftIdentity identity,
    int generation,
    AcpComposerDraftSnapshot draft, {
    DateTime? savedAt,
  }) {
    final key = identity.value;
    unawaited(
      _run('save_failed', () async {
        if (_generation(key) != generation ||
            _forgottenHosts.contains(identity.hostId)) {
          return;
        }
        if (draft.isEmpty) {
          await _deleteRows(identity);
        } else {
          await _write(
            identity,
            draft,
            savedAt: savedAt ?? _clock().toUtc(),
            rewriteChips: true,
          );
        }
      }),
    );
  }

  /// The result for a read whose session was cleared meanwhile.
  AcpOpenedComposerDraft _abandoned(AcpComposerDraftIdentity identity) =>
      peek(identity) ??
      AcpOpenedComposerDraft(draft: _empty, notice: _noticeFor(identity.value));

  AcpOpenedComposerDraft _opened(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot draft,
  ) {
    remember(identity, draft);
    return AcpOpenedComposerDraft(
      draft: draft,
      notice: _noticeFor(identity.value),
    );
  }

  AcpRestoredDraftNotice? _noticeFor(String key) {
    final unavailable = _pendingNotices[key];
    return unavailable == null
        ? null
        : AcpRestoredDraftNotice(unavailableAttachmentCount: unavailable);
  }

  Future<AcpAttachmentDraft?> _restoreAttachment(
    AcpSavedDraftAttachment attachment,
    List<String> chips,
    DateTime now,
  ) async {
    if (attachment is! AcpSavedPastedText &&
        now.difference(attachment.addedAt) > attachmentLifetime) {
      return null;
    }
    switch (attachment) {
      case AcpSavedPastedText(:final name):
        final text = attachment.textFrom(chips);
        if (text == null) return null;
        final candidate = AcpAttachmentCandidate.memory(
          name: name,
          bytes: Uint8List.fromList(utf8.encode(text)),
          mimeType: kAcpPastedTextMimeType,
        );
        _chipTexts[candidate] = text;
        return AcpAttachmentDraft(candidate: candidate);
      case AcpSavedLocalFile(
        :final name,
        :final path,
        :final stamp,
        :final mimeType,
        :final fallback,
      ):
        AcpDraftFileStamp? current;
        try {
          current = await _probeLocalFile(path);
        } on Object {
          current = null;
        }
        if (current != stamp) return null;
        final candidate = AcpAttachmentCandidate.localFile(
          name: name,
          openRead: () => File(path).openRead(),
          sizeBytes: stamp.sizeBytes,
          mimeType: mimeType,
          localPath: path,
        );
        _fileStamps[candidate] = stamp;
        return AcpAttachmentDraft(candidate: candidate, fallback: fallback);
      case AcpSavedRemoteFile(
        :final name,
        :final remotePath,
        :final sizeBytes,
        :final mimeType,
        :final fallback,
      ):
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

  /// Writes [draft]'s rows. The chips row is rewritten only when the chips
  /// differ from what this run last wrote, or with [rewriteChips].
  Future<void> _write(
    AcpComposerDraftIdentity identity,
    AcpComposerDraftSnapshot draft, {
    required DateTime savedAt,
    bool rewriteChips = false,
  }) async {
    final key = identity.value;
    if (draft.isEmpty) {
      await _deleteRows(identity);
      return;
    }
    final attachments = <AcpSavedDraftAttachment>[];
    final chipCandidates = <AcpAttachmentCandidate>[];
    final chipTexts = <String>[];
    var unsaved = 0;
    var budget = pastedTextBudget;
    for (final draftAttachment in draft.attachments) {
      final candidate = draftAttachment.candidate;
      final addedAt = _addedAt[candidate] ?? savedAt;
      final AcpSavedDraftAttachment? saved;
      switch (candidate) {
        case AcpMemoryAttachmentCandidate() when candidate.isPastedText:
          final text = _chipText(candidate);
          if (text == null || text.length > budget) {
            saved = null;
          } else {
            budget -= text.length;
            saved = AcpSavedPastedText(
              name: candidate.name,
              chip: chipTexts.length,
              addedAt: addedAt,
            );
            chipCandidates.add(candidate);
            chipTexts.add(text);
          }
        case AcpMemoryAttachmentCandidate():
          saved = null;
        case AcpLocalFileAttachmentCandidate(:final localPath?):
          final stamp = await _fileStamp(candidate, localPath);
          saved = stamp == null
              ? null
              : AcpSavedLocalFile(
                  name: candidate.name,
                  path: localPath,
                  stamp: stamp,
                  mimeType: candidate.mimeType,
                  fallback: draftAttachment.fallback,
                  addedAt: addedAt,
                );
        case AcpLocalFileAttachmentCandidate():
          saved = null;
        case AcpRemoteFileAttachmentCandidate(:final remotePath):
          saved = AcpSavedRemoteFile(
            name: candidate.name,
            remotePath: remotePath,
            sizeBytes: candidate.sizeBytes,
            mimeType: candidate.mimeType,
            fallback: draftAttachment.fallback,
            addedAt: addedAt,
          );
      }
      if (saved == null) {
        unsaved++;
      } else {
        attachments.add(saved);
      }
    }
    final saved = AcpSavedComposerDraft(
      text: draft.text,
      caret: draft.caret.clamp(0, draft.text.length),
      savedAt: savedAt,
      attachments: attachments,
      unsavedAttachmentCount: unsaved,
    );
    final lastChips = rewriteChips ? null : _savedChips[key];
    final chipsChanged =
        lastChips == null || !_sameCandidates(lastChips, chipCandidates);
    await _settings.setStrings(<String, String?>{
      _draftKey(identity): jsonEncode(saved.toJson()),
      if (chipsChanged)
        _chipsKey(identity): chipTexts.isEmpty
            ? null
            : AcpSavedComposerDraft.encodeChips(chipTexts),
    });
    _savedChips[key] = chipCandidates;
  }

  Future<void> _deleteRows(AcpComposerDraftIdentity identity) async {
    await _settings.setStrings(<String, String?>{
      _draftKey(identity): null,
      _chipsKey(identity): null,
    });
    _savedChips[identity.value] = const <AcpAttachmentCandidate>[];
  }

  String? _chipText(AcpMemoryAttachmentCandidate candidate) {
    final cached = _chipTexts[candidate];
    if (cached != null) return cached;
    try {
      return _chipTexts[candidate] = utf8.decode(candidate.bytes);
    } on FormatException {
      return null;
    }
  }

  Future<AcpDraftFileStamp?> _fileStamp(
    AcpLocalFileAttachmentCandidate candidate,
    String path,
  ) async {
    final cached = _fileStamps[candidate];
    if (cached != null) return cached;
    AcpDraftFileStamp? stamp;
    try {
      stamp = await _probeLocalFile(path);
    } on Object {
      stamp = null;
    }
    if (stamp != null) _fileStamps[candidate] = stamp;
    return stamp;
  }

  static bool _sameCandidates(
    List<AcpAttachmentCandidate> a,
    List<AcpAttachmentCandidate> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  Future<void> _pruneOnce() => _pruning ??= _mutations
      .run(_prune)
      .catchError((Object error) => _log('prune_failed', error));

  Future<void> _prune() async {
    // Only the start of each value is read: enough for the save time.
    final heads = await _settings.getStringsWithPrefix(
      SettingKeys.acpComposerDraftPrefix,
      valueLength: AcpSavedComposerDraft.peekLength,
    );
    final now = _clock().toUtc();
    final kept = <({String suffix, DateTime savedAt})>[];
    final doomed = <String>[];
    for (final MapEntry(:key, :value) in heads.entries) {
      final suffix = key.substring(SettingKeys.acpComposerDraftPrefix.length);
      if (_isActive(suffix)) continue;
      final savedAt = AcpSavedComposerDraft.peekSavedAt(value);
      if (savedAt == null || now.difference(savedAt) > draftLifetime) {
        doomed.add(suffix);
      } else {
        kept.add((suffix: suffix, savedAt: savedAt));
      }
    }
    kept.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    final active = heads.length - doomed.length - kept.length;
    final room = (maxSavedDrafts - active).clamp(0, kept.length);
    doomed.addAll(kept.skip(room).map((entry) => entry.suffix));
    // Chips rows whose draft row is gone are left over from a failed write.
    final chipKeys = await _settings.getKeysWithPrefix(
      SettingKeys.acpComposerDraftChipsPrefix,
    );
    for (final key in chipKeys) {
      final suffix = key.substring(
        SettingKeys.acpComposerDraftChipsPrefix.length,
      );
      final hasDraft = heads.containsKey(
        '${SettingKeys.acpComposerDraftPrefix}$suffix',
      );
      if (!hasDraft && !_isActive(suffix)) doomed.add(suffix);
    }
    if (doomed.isEmpty) return;
    await _settings.setStrings(<String, String?>{
      for (final suffix in doomed) ...{
        '${SettingKeys.acpComposerDraftPrefix}$suffix': null,
        '${SettingKeys.acpComposerDraftChipsPrefix}$suffix': null,
      },
    });
  }

  bool _isActive(String key) => _seen.contains(key) || _loads.containsKey(key);

  Future<void> _run(String failure, Future<void> Function() action) =>
      _mutations.run(action).catchError((Object error) => _log(failure, error));

  void _log(String failure, Object error) => _diagnostics.warning(
    'acp.composer_draft',
    failure,
    fields: {'errorType': error.runtimeType},
  );

  static final _empty = AcpComposerDraftSnapshot(text: '');

  static AcpSavedComposerDraft? _decode(String encoded) {
    try {
      return AcpSavedComposerDraft.tryFromJson(jsonDecode(encoded));
    } on Object {
      // Malformed JSON, or values out of range: the row is corrupt.
      return null;
    }
  }

  static String _draftKey(AcpComposerDraftIdentity identity) =>
      '${SettingKeys.acpComposerDraftPrefix}${identity.value}';

  static String _chipsKey(AcpComposerDraftIdentity identity) =>
      '${SettingKeys.acpComposerDraftChipsPrefix}${identity.value}';

  static Future<AcpDraftFileStamp?> _defaultProbe(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return AcpDraftFileStamp(
      sizeBytes: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }
}

/// Provider for [AcpComposerDraftStore].
final acpComposerDraftStoreProvider = Provider<AcpComposerDraftStore>(
  (ref) => AcpComposerDraftStore(
    ref.watch(settingsServiceProvider),
    diagnostics: ref.watch(diagnosticsLoggerProvider),
  ),
);
