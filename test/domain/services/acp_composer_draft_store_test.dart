// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
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

AcpAttachmentDraft _localFile({String? path = '/tmp/picked/photo.jpg'}) =>
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

void main() {
  late AppDatabase db;
  late SettingsService settings;
  late DateTime now;
  late Map<String, int> files;

  AcpComposerDraftStore store({
    RecordingDiagnosticsLogger? diagnostics,
    int maxSavedDrafts = 50,
    int pastedTextBudget = 4 * 1024 * 1024,
  }) => AcpComposerDraftStore(
    settings,
    diagnostics: diagnostics ?? RecordingDiagnosticsLogger(),
    clock: () => now,
    probeLocalFile: (path) async => files[path],
    maxSavedDrafts: maxSavedDrafts,
    pastedTextBudget: pastedTextBudget,
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(db);
    now = DateTime.utc(2026, 10, 9, 8);
    files = <String, int>{'/tmp/picked/photo.jpg': 42};
  });

  tearDown(() => db.close());

  test('a draft saved in one run is restored by the next', () async {
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
    final restored = await store().loadSaved(_identity);

    expect(restored, isNotNull);
    expect(restored!.unavailableAttachmentCount, 0);
    final draft = restored.draft;
    expect(draft.text, 'Explain the failing test');
    expect(draft.caret, 7);
    expect(draft.attachments, hasLength(3));
    final pasted =
        draft.attachments[0].candidate as AcpMemoryAttachmentCandidate;
    expect(pasted.isPastedText, isTrue);
    expect(utf8.decode(pasted.bytes), 'line 1\nline 2\nline 3');
    final local =
        draft.attachments[1].candidate as AcpLocalFileAttachmentCandidate;
    expect(local.localPath, '/tmp/picked/photo.jpg');
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
    expect((await next.loadSaved(_identity))!.draft.text, 'one');
    expect((await next.loadSaved(_otherIdentity))!.draft.text, 'two');
  });

  test('the identity ignores the bridge, so a resumed session keeps its '
      'draft', () {
    expect(
      AcpComposerDraftIdentity.of(
        AcpSessionKeyFixture.key(bridgeId: 'old-bridge'),
      ),
      AcpComposerDraftIdentity.of(
        AcpSessionKeyFixture.key(bridgeId: 'new-bridge'),
      ),
    );
  });

  test('an empty draft deletes the saved copy', () async {
    final first = store();
    await first.save(_identity, AcpComposerDraftSnapshot(text: 'sent soon'));
    await first.save(_identity, AcpComposerDraftSnapshot(text: '  \n'));

    expect(
      await settings.getStringsWithPrefix(SettingKeys.acpComposerDraftPrefix),
      isEmpty,
    );
    expect(await store().loadSaved(_identity), isNull);
  });

  test('pasted images and pathless files are dropped and counted', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Look at this',
        attachments: [_pastedImage(), _localFile(path: null)],
      ),
    );

    final restored = await store().loadSaved(_identity);
    expect(restored!.draft.text, 'Look at this');
    expect(restored.draft.attachments, isEmpty);
    expect(restored.unavailableAttachmentCount, 2);
  });

  test('pasted text beyond the budget is dropped and counted', () async {
    await store(pastedTextBudget: 10).save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'two pastes',
        attachments: [_pastedText('0123456789'), _pastedText('abc')],
      ),
    );

    final restored = await store().loadSaved(_identity);
    expect(restored!.draft.attachments, hasLength(1));
    expect(restored.unavailableAttachmentCount, 1);
  });

  test('file references expire after a day but the text stays', () async {
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Still here',
        attachments: [_pastedText('kept'), _localFile(), _remoteFile()],
      ),
    );

    now = now.add(const Duration(hours: 25));
    final restored = await store().loadSaved(_identity);
    expect(restored!.draft.text, 'Still here');
    expect(restored.draft.attachments, hasLength(1));
    expect(restored.draft.attachments.single.candidate.isPastedText, isTrue);
    expect(restored.unavailableAttachmentCount, 2);
  });

  test('a picked file that is gone or changed is dropped', () async {
    files['/tmp/picked/other.jpg'] = 42;
    await store().save(
      _identity,
      AcpComposerDraftSnapshot(
        text: 'Files',
        attachments: [
          _localFile(),
          _localFile(path: '/tmp/picked/other.jpg'),
        ],
      ),
    );
    files
      ..remove('/tmp/picked/photo.jpg')
      ..['/tmp/picked/other.jpg'] = 99;

    final restored = await store().loadSaved(_identity);
    expect(restored!.draft.attachments, isEmpty);
    expect(restored.unavailableAttachmentCount, 2);
  });

  test('drafts older than 30 days are deleted instead of restored', () async {
    await store().save(_identity, AcpComposerDraftSnapshot(text: 'old'));

    now = now.add(const Duration(days: 31));
    expect(await store().loadSaved(_identity), isNull);
    expect(
      await settings.getStringsWithPrefix(SettingKeys.acpComposerDraftPrefix),
      isEmpty,
    );
  });

  test('corrupt rows are deleted and never surface', () async {
    final key = '${SettingKeys.acpComposerDraftPrefix}${_identity.value}';
    await settings.setString(key, '{not json');

    expect(await store().loadSaved(_identity), isNull);
    expect(await settings.getString(key), isNull);
  });

  test(
    'the first write of a run prunes drafts beyond the limit, oldest first',
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

      now = now.add(const Duration(minutes: 1));
      await store(maxSavedDrafts: 2)
          .save(_identity, AcpComposerDraftSnapshot(text: 'newest'));

      final remaining = await settings.getStringsWithPrefix(
        SettingKeys.acpComposerDraftPrefix,
      );
      expect(
        remaining.values.map(
          (value) => (jsonDecode(value) as Map<String, dynamic>)['text'],
        ),
        unorderedEquals(<String>['draft 2', 'draft 3', 'newest']),
      );
    },
  );

  test('memory remembers this run, including attachments that are never '
      'stored', () async {
    final draftStore = store();
    expect(draftStore.rememberedDraft(_identity), isNull);
    expect(draftStore.seenThisRun(_identity), isFalse);

    final image = _pastedImage();
    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'with image', attachments: [image]),
    );

    expect(draftStore.seenThisRun(_identity), isTrue);
    final remembered = draftStore.rememberedDraft(_identity)!;
    expect(remembered.text, 'with image');
    expect(remembered.attachments.single, same(image));

    await draftStore.clear(_identity);
    expect(draftStore.rememberedDraft(_identity)!.isEmpty, isTrue);
  });

  test('storage failures are logged without draft content', () async {
    final diagnostics = RecordingDiagnosticsLogger();
    final draftStore = AcpComposerDraftStore(
      _FailingSettings(db),
      diagnostics: diagnostics,
    );

    await draftStore.save(
      _identity,
      AcpComposerDraftSnapshot(text: 'secret prompt text'),
    );
    expect(await draftStore.loadSaved(_identity), isNull);

    expect(diagnostics.events, isNotEmpty);
    for (final event in diagnostics.events) {
      expect(event.category, 'acp.composer_draft');
      expect(event.searchableText, isNot(contains('secret prompt text')));
    }
  });

  test('prefix reads return only keys with that exact prefix', () async {
    const prefix = SettingKeys.acpComposerDraftPrefix;
    await settings.setString('${prefix}a', '1');
    await settings.setString('${prefix}b', '2');
    await settings.setString('acp_composer_draft;', 'next');
    await settings.setString('acp_composer_drafts', 'longer');
    await settings.setString('ACP_COMPOSER_DRAFT:a', 'upper');

    expect(await settings.getStringsWithPrefix(prefix), {
      '${prefix}a': '1',
      '${prefix}b': '2',
    });
  });
}

class _FailingSettings extends SettingsService {
  _FailingSettings(super.db);

  @override
  Future<String?> getString(String key) => throw StateError('closed');

  @override
  Future<void> setString(String key, String value) =>
      throw StateError('closed');

  @override
  Future<void> delete(String key) => throw StateError('closed');

  @override
  Future<Map<String, String>> getStringsWithPrefix(String prefix) =>
      throw StateError('closed');
}

/// Builds session keys that differ only in the parts a test names.
abstract final class AcpSessionKeyFixture {
  static AcpSessionKey key({String bridgeId = 'bridge-1'}) => AcpSessionKey.of(
    hostId: 1,
    providerId: 'builtin:copilot-cli',
    bridgeId: bridgeId,
    acpSessionId: 'session-1',
  );
}
