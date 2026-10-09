// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_composer_draft.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/services/acp_composer_draft_store.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

const _identity = AcpComposerDraftIdentity(
  hostId: 1,
  providerId: 'builtin:copilot-cli',
  acpSessionId: 'session-1',
);

const _otherIdentity = AcpComposerDraftIdentity(
  hostId: 2,
  providerId: 'builtin:claude-code',
  acpSessionId: 'session-2',
);

const _photoPath = '/tmp/picked/photo.jpg';
const _photoStamp = AcpDraftFileStamp(sizeBytes: 42, modifiedMs: 1000);

final _draftKey = '${SettingKeys.acpComposerDraftPrefix}${_identity.value}';
final _chipsKey =
    '${SettingKeys.acpComposerDraftChipsPrefix}${_identity.value}';

AcpAttachmentDraft _pastedText(String text) => AcpAttachmentDraft(
  candidate: AcpAttachmentCandidate.memory(
    name: 'Pasted text · 3 lines',
    bytes: Uint8List.fromList(utf8.encode(text)),
    mimeType: kAcpPastedTextMimeType,
  ),
);

AcpAttachmentDraft _pastedImage() => AcpAttachmentDraft(
  candidate: AcpAttachmentCandidate.memory(
    name: 'Pasted image.png',
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
    mimeType: 'image/png',
  ),
);

AcpAttachmentDraft _localFile({String? path = _photoPath}) =>
    AcpAttachmentDraft(
      candidate: AcpAttachmentCandidate.localFile(
        name: 'photo.jpg',
        openRead: () => const Stream<List<int>>.empty(),
        sizeBytes: 42,
        mimeType: 'image/jpeg',
        localPath: path,
      ),
      fallback: AcpAttachmentFallback.remoteUpload,
    );

AcpAttachmentDraft _remoteFile() => const AcpAttachmentDraft(
  candidate: AcpAttachmentCandidate.remoteFile(
    name: 'notes.md',
    remotePath: '/home/dev/notes.md',
    sizeBytes: 7,
  ),
);

class _RecordingSettings extends SettingsService {
  _RecordingSettings(super.db);

  final List<String> written = <String>[];
  int reads = 0;
  Completer<void>? readGate;
  Object? readError;

  @override
  Future<String?> getString(String key) async {
    reads++;
    await readGate?.future;
    final error = readError;
    // ignore: only_throw_errors
    if (error != null) throw error;
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) {
    written.add(key);
    return super.setString(key, value);
  }
}

class _FailingSettings extends SettingsService {
  _FailingSettings(super.db);

  @override
  Future<String?> getString(String key) => throw StateError('closed');

  @override
  Future<void> setString(String key, String value) =>
      throw StateError('closed');

  @override
  Future<void> setStrings(Map<String, String?> values) =>
      throw StateError('closed');

  @override
  Future<Map<String, String>> getStringsWithPrefix(
    String prefix, {
    int? valueLength,
  }) => throw StateError('closed');
}

void main() {
  late AppDatabase db;
  late _RecordingSettings settings;
  late DateTime now;
  late Map<String, AcpDraftFileStamp> files;

  AcpComposerDraftStore store({
    SettingsService? using,
    RecordingDiagnosticsLogger? diagnostics,
    int maxSavedDrafts = 50,
    int pastedTextBudget = 1024 * 1024,
  }) => AcpComposerDraftStore(
    using ?? settings,
    diagnostics: diagnostics ?? RecordingDiagnosticsLogger(),
    clock: () => now,
    probeLocalFile: (path) async => files[path],
    maxSavedDrafts: maxSavedDrafts,
    pastedTextBudget: pastedTextBudget,
  );

  Future<List<String>> draftKeys() async => [
    ...(await settings.getStringsWithPrefix(SettingKeys.acpComposerDraftPrefix))
        .keys,
    ...(await settings.getStringsWithPrefix(
      SettingKeys.acpComposerDraftChipsPrefix,
    )).keys,
  ];

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = _RecordingSettings(db);
    now = DateTime.utc(2026, 10, 9, 8);
    files = <String, AcpDraftFileStamp>{_photoPath: _photoStamp};
  });

  tearDown(() => db.close());

  test('a draft saved in one run is restored by the next, marked', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Explain the failing test',
        caret: 7,
        attachments: [
          _pastedText('line 1\nline 2\nline 3'),
          _localFile(),
          _remoteFile(),
        ],
      ),
    );

    now = now.add(const Duration(hours: 2));
    final opened = await store().open(_identity);

    expect(opened.writable, isTrue);
    expect(opened.notice, const AcpRestoredDraftNotice());
    final draft = opened.draft;
    expect(draft.text, 'Explain the failing test');
    expect(draft.caret, 7);
    expect(draft.attachments, hasLength(3));
    final pasted =
        draft.attachments[0].candidate as AcpMemoryAttachmentCandidate;
    expect(pasted.isPastedText, isTrue);
    expect(utf8.decode(pasted.bytes), 'line 1\nline 2\nline 3');
    final local =
        draft.attachments[1].candidate as AcpLocalFileAttachmentCandidate;
    expect(local.localPath, _photoPath);
    expect(local.sizeBytes, 42);
    expect(local.mimeType, 'image/jpeg');
    expect(draft.attachments[1].fallback, AcpAttachmentFallback.remoteUpload);
    final remote =
        draft.attachments[2].candidate as AcpRemoteFileAttachmentCandidate;
    expect(remote.remotePath, '/home/dev/notes.md');
  });

  test('drafts are kept per session', () async {
    final first = store();
    await first.save(_identity, AcpComposerDraftSnapshot(text: 'one'));
    await first.save(_otherIdentity, AcpComposerDraftSnapshot(text: 'two'));

    final next = store();
    expect((await next.open(_identity)).draft.text, 'one');
    expect((await next.open(_otherIdentity)).draft.text, 'two');
  });

  test('the identity ignores the bridge, so a resumed session keeps its '
      'draft', () {
    AcpSessionKey key(String bridgeId) => AcpSessionKey.of(
      hostId: 1,
      providerId: 'builtin:copilot-cli',
      bridgeId: bridgeId,
      acpSessionId: 'session-1',
    );
    expect(
      AcpComposerDraftIdentity.of(key('old-bridge')),
      AcpComposerDraftIdentity.of(key('new-bridge')),
    );
  });

  test('an empty draft deletes both saved rows', () async {
    final first = store();
    await first.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'soon', attachments: [_pastedText('x')]),
    );
    expect(await draftKeys(), hasLength(2));

    await first.save(_identity, AcpComposerDraftSnapshot(text: '  \n'));

    expect(await draftKeys(), isEmpty);
    final opened = await store().open(_identity);
    expect(opened.draft.isEmpty, isTrue);
    expect(opened.notice, isNull);
  });

  test('a draft with only a pasted image reports the loss once, on an '
      'empty composer', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(text: '', attachments: [_pastedImage()]),
    );

    final relaunched = store();
    final opened = await relaunched.open(_identity);
    expect(opened.draft.isEmpty, isTrue);
    expect(
      opened.notice,
      const AcpRestoredDraftNotice(unavailableAttachmentCount: 1),
    );
    await relaunched.pruneExpired(); // queued after the clean-up write
    expect(await draftKeys(), isEmpty);

    final nextLaunch = await store().open(_identity);
    expect(nextLaunch.notice, isNull);
  });

  test('a photo-only draft opened after its reference expired reports the '
      'loss', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(text: '', attachments: [_localFile()]),
    );

    now = now.add(const Duration(hours: 25));
    final opened = await store().open(_identity);
    expect(opened.draft.isEmpty, isTrue);
    expect(opened.notice?.unavailableAttachmentCount, 1);
  });

  test('pasted images and pathless files are dropped and counted', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Look at this',
        attachments: [_pastedImage(), _localFile(path: null)],
      ),
    );

    final opened = await store().open(_identity);
    expect(opened.draft.text, 'Look at this');
    expect(opened.draft.attachments, isEmpty);
    expect(opened.notice?.unavailableAttachmentCount, 2);
  });

  test('the loss is reported once; the next launch restores what is left '
      'without repeating it', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Two things',
        attachments: [_pastedImage(), _pastedText('kept paste')],
      ),
    );

    final relaunched = store();
    final firstLaunch = await relaunched.open(_identity);
    expect(firstLaunch.notice?.unavailableAttachmentCount, 1);
    await relaunched.pruneExpired(); // queued after the clean-up write

    final secondLaunch = await store().open(_identity);
    expect(secondLaunch.notice, const AcpRestoredDraftNotice());
    expect(secondLaunch.draft.attachments, hasLength(1));
    expect(
      secondLaunch.draft.attachments.single.candidate.isPastedText,
      isTrue,
    );
  });

  test('pasted text beyond the budget is dropped and counted', () async {
    await store(pastedTextBudget: 10).save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'two pastes',
        attachments: [_pastedText('0123456789'), _pastedText('abc')],
      ),
    );

    final opened = await store().open(_identity);
    expect(opened.draft.attachments, hasLength(1));
    expect(opened.notice?.unavailableAttachmentCount, 1);
  });

  test('typing rewrites the small draft row, never the pasted chips', () async {
    final draftStore = store();
    final paste = _pastedText('a large paste\n' * 50);
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'a', attachments: [paste]),
    );
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'ab', attachments: [paste]),
    );
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'abc', attachments: [paste]),
    );

    expect(settings.written.where((key) => key == _chipsKey), hasLength(1));
    expect(settings.written.where((key) => key == _draftKey), hasLength(3));
    expect((await draftKeys()).toSet(), {_draftKey, _chipsKey});

    final restored = await store().open(_identity);
    final chip =
        restored.draft.attachments.single.candidate
            as AcpMemoryAttachmentCandidate;
    expect(utf8.decode(chip.bytes), 'a large paste\n' * 50);
  });

  test('file references expire a day after they were added, however often '
      'the draft is edited', () async {
    final draftStore = store();
    final paste = _pastedText('kept');
    final photo = _localFile();
    final remote = _remoteFile();
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'v1', attachments: [paste, photo, remote]),
    );
    now = now.add(const Duration(hours: 20));
    final later = _localFile(path: '/tmp/picked/later.jpg');
    files['/tmp/picked/later.jpg'] = _photoStamp;
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'v2',
        attachments: [paste, photo, remote, later],
      ),
    );

    now = now.add(const Duration(hours: 5));
    final opened = await store().open(_identity);
    expect(opened.draft.text, 'v2');
    // Pasted text never expires; the file added 5 hours ago is still fresh.
    expect(opened.draft.attachments, hasLength(2));
    expect(opened.draft.attachments.first.candidate.isPastedText, isTrue);
    final fresh =
        opened.draft.attachments.last.candidate
            as AcpLocalFileAttachmentCandidate;
    expect(fresh.localPath, '/tmp/picked/later.jpg');
    expect(opened.notice?.unavailableAttachmentCount, 2);
  });

  test('a picked file that is gone, resized or modified is dropped', () async {
    const resized = '/tmp/picked/resized.jpg';
    const touched = '/tmp/picked/touched.jpg';
    files[resized] = _photoStamp;
    files[touched] = _photoStamp;
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Files',
        attachments: [
          _localFile(),
          _localFile(path: resized),
          _localFile(path: touched),
        ],
      ),
    );
    files
      ..remove(_photoPath)
      ..[resized] = const AcpDraftFileStamp(sizeBytes: 99, modifiedMs: 1000)
      ..[touched] = const AcpDraftFileStamp(sizeBytes: 42, modifiedMs: 2000);

    final opened = await store().open(_identity);
    expect(opened.draft.attachments, isEmpty);
    expect(opened.notice?.unavailableAttachmentCount, 3);
  });

  test('drafts older than 30 days are deleted instead of restored', () async {
    await store().save(_identity, AcpComposerDraftSnapshot(text: 'old'));

    now = now.add(const Duration(days: 31));
    final opened = await store().open(_identity);
    expect(opened.draft.isEmpty, isTrue);
    expect(opened.notice, isNull);
    await store().pruneExpired();
    expect(await draftKeys(), isEmpty);
  });

  test('corrupt rows are deleted and never surface', () async {
    await settings.setString(_draftKey, '{not json');

    final opened = await store().open(_identity);
    expect(opened.draft.isEmpty, isTrue);
    expect(opened.notice, isNull);
    await store().pruneExpired();
    expect(await settings.getString(_draftKey), isNull);
  });

  test('startup pruning removes expired drafts and orphaned chips without '
      'opening a chat', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(text: 'stale', attachments: [_pastedText('x')]),
    );
    final orphanChips =
        '${SettingKeys.acpComposerDraftChipsPrefix}${_otherIdentity.value}';
    await settings.setString(orphanChips, '["left over"]');

    now = now.add(const Duration(days: 31));
    await store().pruneExpired();

    expect(await draftKeys(), isEmpty);
  });

  test(
    'pruning keeps the newest drafts and never the one being opened',
    () async {
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(minutes: 1));
        await store().save(
          AcpComposerDraftIdentity(
            hostId: 1,
            providerId: 'p',
            acpSessionId: 'session-$i',
          ),
          AcpComposerDraftSnapshot(text: 'draft $i'),
        );
      }

      final draftStore = store(maxSavedDrafts: 2);
      const oldest = AcpComposerDraftIdentity(
        hostId: 1,
        providerId: 'p',
        acpSessionId: 'session-0',
      );
      final opening = draftStore.open(oldest);
      await draftStore.pruneExpired();
      expect((await opening).draft.text, 'draft 0');

      final remaining = await settings.getStringsWithPrefix(
        SettingKeys.acpComposerDraftPrefix,
      );
      expect(
        remaining.values.map(
          (value) => (jsonDecode(value) as Map<String, dynamic>)['text'],
        ),
        unorderedEquals(<String>['draft 0', 'draft 3']),
      );
    },
  );

  test('concurrent opens share one read', () async {
    await store().save(_identity, AcpComposerDraftSnapshot(text: 'shared'));
    final readsBefore = settings.reads;
    final gate = settings.readGate = Completer<void>();

    final draftStore = store();
    final first = draftStore.open(_identity);
    final second = draftStore.open(_identity);
    gate.complete();

    expect((await first).draft.text, 'shared');
    expect((await second).notice, isNotNull);
    expect(settings.reads - readsBefore, 2); // draft row, then chips row
  });

  test(
    'the notice stays pending for every composer until acknowledged',
    () async {
      await store().save(_identity, AcpComposerDraftSnapshot(text: 'pending'));

      final draftStore = store();
      expect((await draftStore.open(_identity)).notice, isNotNull);
      expect(draftStore.peek(_identity)!.notice, isNotNull);

      draftStore.acknowledgeRestore(_identity);
      expect(draftStore.peek(_identity)!.notice, isNull);
    },
  );

  test('a failed read never turns into an overwrite', () async {
    await store().save(_identity, AcpComposerDraftSnapshot(text: 'precious'));
    settings.readError = StateError('disk busy');

    final draftStore = store();
    final opened = await draftStore.open(_identity);
    expect(opened.writable, isFalse);
    await draftStore.save(_identity, AcpComposerDraftSnapshot(text: 'typed'));
    expect(draftStore.peek(_identity)!.draft.text, 'typed');

    settings.readError = null;
    expect((await store().open(_identity)).draft.text, 'precious');
  });

  test('memory keeps this run’s draft, including attachments that are never '
      'stored', () async {
    final draftStore = store();
    expect(draftStore.peek(_identity), isNull);

    final image = _pastedImage();
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'with image', attachments: [image]),
    );

    final remembered = draftStore.peek(_identity)!;
    expect(remembered.draft.text, 'with image');
    expect(remembered.draft.attachments.single, same(image));
    expect(remembered.notice, isNull);

    await draftStore.clear(_identity);
    expect(draftStore.peek(_identity)!.draft.isEmpty, isTrue);
    expect(await draftKeys(), isEmpty);
  });

  test('deleting a host deletes its drafts and nothing else', () async {
    final hosts = HostRepository(db, SecretEncryptionService.forTesting());
    final hostId = await hosts.insert(
      HostsCompanion.insert(label: 'Box', hostname: 'box', username: 'dev'),
    );
    final hostDraft = AcpComposerDraftIdentity(
      hostId: hostId,
      providerId: 'p',
      acpSessionId: 's',
    );
    final otherHost = AcpComposerDraftIdentity(
      hostId: hostId + 10,
      providerId: 'p',
      acpSessionId: 's',
    );
    final draftStore = store();
    await draftStore.save(
      hostDraft,
      AcpComposerDraftSnapshot(text: 'gone', attachments: [_pastedText('x')]),
    );
    await draftStore.save(otherHost, AcpComposerDraftSnapshot(text: 'kept'));

    await hosts.delete(hostId);

    expect(await draftKeys(), [
      '${SettingKeys.acpComposerDraftPrefix}${otherHost.value}',
    ]);
  });

  test('storage failures are logged without draft content', () async {
    final diagnostics = RecordingDiagnosticsLogger();
    final draftStore = store(
      using: _FailingSettings(db),
      diagnostics: diagnostics,
    );

    await draftStore.save(
      _otherIdentity,
      AcpComposerDraftSnapshot(text: 'secret prompt text'),
    );
    expect((await draftStore.open(_identity)).writable, isFalse);

    expect(diagnostics.events, isNotEmpty);
    for (final event in diagnostics.events) {
      expect(event.category, 'acp.composer_draft');
      expect(event.searchableText, isNot(contains('secret prompt text')));
    }
  });

  test(
    'prefix reads are exact and can read only the start of values',
    () async {
      const prefix = SettingKeys.acpComposerDraftPrefix;
      await settings.setString('${prefix}a', '0123456789');
      await settings.setString('${prefix}b', '2');
      await settings.setString('acp_composer_draft;', 'next');
      await settings.setString('acp_composer_drafts', 'longer');
      await settings.setString('ACP_COMPOSER_DRAFT:a', 'upper');

      expect(await settings.getStringsWithPrefix(prefix), {
        '${prefix}a': '0123456789',
        '${prefix}b': '2',
      });
      expect(await settings.getStringsWithPrefix(prefix, valueLength: 4), {
        '${prefix}a': '0123',
        '${prefix}b': '2',
      });
    },
  );
}
