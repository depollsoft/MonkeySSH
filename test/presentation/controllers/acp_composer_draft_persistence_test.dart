// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_composer_draft.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/services/acp_attachment_service.dart';
import 'package:monkeyssh/domain/services/acp_composer_draft_store.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_draft_persistence.dart';

import '../../support/fake_acp_session_manager.dart';
import '../../support/memory_settings_service.dart';

AcpSessionKey _key({String acpSessionId = 'session'}) => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: acpSessionId,
);

final _identity = AcpComposerDraftIdentity.of(_key());

AcpSessionState _session({
  AcpConnectionStatus status = AcpConnectionStatus.ready,
}) {
  final now = DateTime(2026);
  return AcpSessionState(
    key: _key(),
    providerLabel: 'Copilot',
    cwd: '/home',
    status: status,
    createdAt: now,
    lastActivityAt: now,
  );
}

AcpComposerController _controller(
  RecordingAcpSessionManager manager, {
  AcpAttachmentUploader? Function()? uploaderBuilder,
}) => AcpComposerController(
  manager: manager,
  sessionKey: _key(),
  uploaderBuilder: uploaderBuilder,
  initialSession: _session(),
);

AcpComposerDraftStore _store(MemorySettingsService settings) =>
    AcpComposerDraftStore(settings, probeLocalFile: (_) async => null);

String? _savedText(
  MemorySettingsService settings, [
  AcpComposerDraftIdentity? identity,
]) {
  final raw = settings
      .values['${SettingKeys.acpComposerDraftPrefix}${(identity ?? _identity).value}'];
  if (raw == null) return null;
  return (jsonDecode(raw) as Map<String, dynamic>)['text'] as String?;
}

Future<void> _saveEarlierRun(
  MemorySettingsService settings,
  AcpComposerDraftSnapshot draft,
) => _store(settings).save(_identity, draft);

AcpAttachmentCandidate _image() => AcpAttachmentCandidate.memory(
  name: 'Pasted image.png',
  bytes: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]),
  mimeType: 'image/png',
);

class _Harness {
  _Harness(
    this.settings, {
    AcpComposerDraftStore? store,
    AcpSessionKey? key,
    this.uploaderBuilder,
  }) : store = store ?? _store(settings),
       key = key ?? _key();

  final MemorySettingsService settings;
  final AcpComposerDraftStore store;
  final AcpSessionKey key;
  final AcpAttachmentUploader? Function()? uploaderBuilder;
  final manager = RecordingAcpSessionManager();
  late final AcpComposerController controller = AcpComposerController(
    manager: manager,
    sessionKey: key,
    uploaderBuilder: uploaderBuilder,
    initialSession: _session(),
  );
  late final AcpComposerDraftPersistence persistence =
      AcpComposerDraftPersistence(controller: controller, store: store);

  void start() => persistence.start();

  var _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    persistence.dispose();
    controller.dispose();
  }
}

void main() {
  group('restoring', () {
    testWidgets('a draft from an earlier run comes back marked and unsent', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(text: 'Draft from before', caret: 5),
      );

      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();

      expect(harness.controller.text, 'Draft from before');
      expect(harness.controller.caret, 5);
      expect(
        harness.controller.restoredDraftNotice,
        const AcpRestoredDraftNotice(),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(harness.manager.prompts, isEmpty);
    });

    testWidgets('reports attachments that could not be restored', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(
          text: 'With a screenshot',
          attachments: [AcpAttachmentDraft(candidate: _image())],
        ),
      );

      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();

      expect(harness.controller.attachments, isEmpty);
      expect(
        harness.controller.restoredDraftNotice,
        const AcpRestoredDraftNotice(unavailableAttachmentCount: 1),
      );
    });

    testWidgets('reopening in the same run restores silently from memory, '
        'pasted images included', (tester) async {
      final settings = MemorySettingsService();
      final store = _store(settings);
      final first = _Harness(settings, store: store)..start();
      await tester.pump();
      first.controller
        ..setText('Keep me')
        ..addAttachment(_image());
      first.dispose();

      final second = _Harness(settings, store: store)..start();
      addTearDown(second.dispose);

      expect(second.controller.text, 'Keep me');
      expect(second.controller.attachments, hasLength(1));
      expect(second.controller.restoredDraftNotice, isNull);
    });

    testWidgets('edits made before the saved draft loads are merged, and '
        'nothing is written until then', (tester) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(text: 'Saved earlier'),
      );
      final writesBefore = settings.writeCount;
      final gate = settings.readGate = Completer<void>();

      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      harness.controller.setText('typed meanwhile');
      await tester.pump(const Duration(seconds: 2));
      expect(settings.writeCount, writesBefore);
      expect(_savedText(settings), 'Saved earlier');

      gate.complete();
      await tester.pump();
      expect(harness.controller.text, 'Saved earlier\n\ntyped meanwhile');

      await tester.pump(kAcpComposerDraftSaveDelay);
      expect(_savedText(settings), 'Saved earlier\n\ntyped meanwhile');
    });
  });

  group('saving', () {
    testWidgets('edits are saved after a pause in typing', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();

      harness.controller.setText('hel');
      await tester.pump(const Duration(milliseconds: 500));
      harness.controller.setText('hello');
      await tester.pump(const Duration(milliseconds: 500));
      expect(_savedText(settings), isNull);

      await tester.pump(const Duration(milliseconds: 300));
      expect(_savedText(settings), 'hello');
    });

    testWidgets('leaving the foreground saves at once', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pump();

      harness.controller.setText('switching to Safari');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      expect(_savedText(settings), 'switching to Safari');
    });

    testWidgets('closing the composer saves pending edits', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      await tester.pump();

      harness.controller.setText('half written');
      harness.dispose();
      await tester.pump();

      expect(_savedText(settings), 'half written');
    });

    testWidgets('an accepted send deletes the saved draft at once', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();
      harness.controller.setText('ship it');
      await tester.pump(kAcpComposerDraftSaveDelay);
      expect(_savedText(settings), 'ship it');

      expect(await harness.controller.send(), isTrue);
      await tester.pump();

      expect(harness.manager.prompts, hasLength(1));
      expect(
        settings.values.keys.where(SettingKeys.isAcpComposerDraft),
        isEmpty,
      );
      expect(harness.store.peek(_identity)!.draft.isEmpty, isTrue);
    });

    testWidgets('a rejected send is saved again', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();
      harness.manager.throwOnPrompt = StateError('rejected');
      harness.controller.setText('try again');

      expect(await harness.controller.send(), isTrue);
      await tester.pump();
      expect(harness.controller.text, 'try again');

      await tester.pump(kAcpComposerDraftSaveDelay);
      expect(_savedText(settings), 'try again');
    });

    testWidgets('a session that comes back under a new id keeps its draft', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();
      harness.controller.setText('follow me');
      await tester.pump(kAcpComposerDraftSaveDelay);

      final resumed = _key(acpSessionId: 'resumed');
      harness.controller.rebindSession(resumed, session: null);
      await tester.pump(kAcpComposerDraftSaveDelay);

      expect(_savedText(settings), isNull);
      expect(
        _savedText(settings, AcpComposerDraftIdentity.of(resumed)),
        'follow me',
      );
    });
  });

  group('review round 1', () {
    testWidgets('edits survive the composer closing before the saved draft '
        'loads', (tester) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(text: 'Saved earlier'),
      );
      final gate = settings.readGate = Completer<void>();
      final store = _store(settings);

      final first = _Harness(settings, store: store)..start();
      first.controller.setText('typed meanwhile');
      first.dispose();
      gate.complete();
      await tester.pump();

      expect(_savedText(settings), 'Saved earlier\n\ntyped meanwhile');
      final reopened = _Harness(settings, store: store)..start();
      addTearDown(reopened.dispose);
      expect(reopened.controller.text, 'Saved earlier\n\ntyped meanwhile');
      expect(reopened.controller.restoredDraftNotice, isNotNull);
    });

    testWidgets('edits survive an early close with no saved draft', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      final gate = settings.readGate = Completer<void>();

      final harness = _Harness(settings)..start();
      harness.controller.setText('first words');
      harness.dispose();
      gate.complete();
      await tester.pump();

      expect(_savedText(settings), 'first words');
    });

    testWidgets('a draft with only a lost attachment still shows the note', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(
          text: '',
          attachments: [AcpAttachmentDraft(candidate: _image())],
        ),
      );

      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();

      expect(harness.controller.text, isEmpty);
      expect(
        harness.controller.restoredDraftNotice,
        const AcpRestoredDraftNotice(unavailableAttachmentCount: 1),
      );
    });

    testWidgets('the note follows the session to a re-keyed composer until '
        'it is dismissed', (tester) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(settings, AcpComposerDraftSnapshot(text: 'kept'));
      final store = _store(settings);

      final provisional = _Harness(settings, store: store)..start();
      await tester.pump();
      expect(provisional.controller.restoredDraftNotice, isNotNull);
      provisional.dispose();

      final recreatedBridge = AcpSessionKey.of(
        hostId: 1,
        providerId: 'copilot',
        bridgeId: 'new-bridge',
        acpSessionId: 'session',
      );
      final rekeyed = _Harness(settings, store: store, key: recreatedBridge)
        ..start();
      expect(rekeyed.controller.text, 'kept');
      expect(rekeyed.controller.restoredDraftNotice, isNotNull);
      rekeyed.controller.dismissRestoredDraftNotice();
      rekeyed.dispose();

      final later = _Harness(settings, store: store)..start();
      addTearDown(later.dispose);
      expect(later.controller.text, 'kept');
      expect(later.controller.restoredDraftNotice, isNull);
    });

    testWidgets('flicking past a session before it loads keeps the note', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(settings, AcpComposerDraftSnapshot(text: 'kept'));
      final gate = settings.readGate = Completer<void>();
      final store = _store(settings);

      (_Harness(settings, store: store)..start()).dispose();
      final second = _Harness(settings, store: store)..start();
      addTearDown(second.dispose);
      gate.complete();
      await tester.pump();

      expect(second.controller.text, 'kept');
      expect(second.controller.restoredDraftNotice, isNotNull);
    });

    testWidgets('moving the caret alone is saved', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();
      harness.controller.setText('hello world');
      await tester.pump(kAcpComposerDraftSaveDelay);

      harness.controller.setText('hello world', caret: 5);
      harness.dispose();
      await tester.pump();

      final reopened = _Harness(settings)..start();
      addTearDown(reopened.dispose);
      await tester.pump();
      expect(reopened.controller.caret, 5);
    });

    testWidgets('a failed read keeps the saved draft from being overwritten', (
      tester,
    ) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(
        settings,
        AcpComposerDraftSnapshot(text: 'precious'),
      );
      settings.readError = StateError('disk busy');

      final harness = _Harness(settings)..start();
      addTearDown(harness.dispose);
      await tester.pump();
      harness.controller.setText('typed after a failed read');
      await tester.pump(kAcpComposerDraftSaveDelay);
      harness.dispose();
      await tester.pump();

      expect(_savedText(settings), 'precious');
    });

    testWidgets('a restore that arrives during a send is applied once the '
        'send finishes', (tester) async {
      final settings = MemorySettingsService();
      await _saveEarlierRun(settings, AcpComposerDraftSnapshot(text: 'saved'));
      final readGate = settings.readGate = Completer<void>();
      final uploadGate = Completer<void>();
      final harness = _Harness(
        settings,
        uploaderBuilder: () => _GatedUploader(uploadGate),
      )..start();
      addTearDown(harness.dispose);
      harness.controller
        ..setText('sent first')
        ..addAttachment(
          AcpAttachmentCandidate.memory(
            name: 'big.bin',
            bytes: Uint8List(16),
            mimeType: 'application/octet-stream',
          ),
        )
        ..enableRemoteUploadFallback();
      final sending = harness.controller.send();
      await tester.pump();
      expect(harness.controller.isEditable, isFalse);

      readGate.complete();
      await tester.pump();
      expect(harness.controller.text, 'sent first');
      expect(harness.persistence.isReady, isFalse);

      uploadGate.complete();
      expect(await sending, isTrue);
      await tester.pump();
      expect(harness.manager.prompts, hasLength(1));
      expect(harness.controller.text, 'saved');
      expect(harness.persistence.isReady, isTrue);
      await tester.pump(kAcpComposerDraftSaveDelay);
      expect(_savedText(settings), 'saved');
    });

    testWidgets('discarding a deleted session deletes its draft and stops '
        'saving', (tester) async {
      final settings = MemorySettingsService();
      final harness = _Harness(settings)..start();
      await tester.pump();
      harness.controller.setText('about to be deleted');
      await tester.pump(kAcpComposerDraftSaveDelay);
      expect(_savedText(settings), 'about to be deleted');

      harness.persistence.discard();
      harness.controller.setText('typed after delete');
      harness.dispose();
      await tester.pump(kAcpComposerDraftSaveDelay);

      expect(
        settings.values.keys.where(SettingKeys.isAcpComposerDraft),
        isEmpty,
      );
    });
  });

  group('controller', () {
    test('restoreDraft puts saved text before newer text and never sends', () {
      final manager = RecordingAcpSessionManager();
      final controller = _controller(manager)..setText('newer');
      addTearDown(controller.dispose);

      final applied = controller.restoreDraft(
        AcpComposerDraftSnapshot(text: 'older'),
        notice: const AcpRestoredDraftNotice(),
      );

      expect(applied, isTrue);
      expect(controller.text, 'older\n\nnewer');
      expect(controller.caret, controller.text.length);
      expect(controller.restoredDraftNotice, isNotNull);
      expect(manager.prompts, isEmpty);
    });

    test('restoreDraft waits while a send is being prepared', () async {
      final manager = RecordingAcpSessionManager();
      final gate = Completer<void>();
      final controller = _controller(
        manager,
        uploaderBuilder: () => _GatedUploader(gate),
      )..setText('sending');
      addTearDown(controller.dispose);
      controller
        ..addAttachment(
          AcpAttachmentCandidate.memory(
            name: 'big.bin',
            bytes: Uint8List(16),
            mimeType: 'application/octet-stream',
          ),
        )
        ..enableRemoteUploadFallback();
      final sending = controller.send();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isEditable, isFalse);

      expect(
        controller.restoreDraft(AcpComposerDraftSnapshot(text: 'saved')),
        isFalse,
      );
      gate.complete();
      await sending;
    });

    test('attachments beyond the limit are counted as unavailable', () {
      final manager = RecordingAcpSessionManager();
      final controller = _controller(manager);
      addTearDown(controller.dispose);
      for (var i = 0; i < controller.limits.maxCount - 1; i++) {
        controller.addAttachment(_image());
      }

      controller.restoreDraft(
        AcpComposerDraftSnapshot(
          text: '',
          attachments: [
            AcpAttachmentDraft(candidate: _image()),
            AcpAttachmentDraft(candidate: _image()),
          ],
        ),
        notice: const AcpRestoredDraftNotice(unavailableAttachmentCount: 1),
      );

      expect(controller.attachments, hasLength(controller.limits.maxCount));
      expect(
        controller.restoredDraftNotice,
        const AcpRestoredDraftNotice(unavailableAttachmentCount: 2),
      );
    });

    test('the notice clears on dismiss, on emptying, and on send', () async {
      final manager = RecordingAcpSessionManager();
      final controller = _controller(manager);
      addTearDown(controller.dispose);
      void restore() => controller.restoreDraft(
        AcpComposerDraftSnapshot(text: 'draft'),
        notice: const AcpRestoredDraftNotice(),
      );

      restore();
      controller.dismissRestoredDraftNotice();
      expect(controller.restoredDraftNotice, isNull);
      expect(controller.text, 'draft');

      controller.setText('');
      restore();
      controller.setText('');
      expect(controller.restoredDraftNotice, isNull);

      restore();
      controller.setText('draft, edited');
      expect(controller.restoredDraftNotice, isNotNull);
      expect(await controller.send(), isTrue);
      expect(controller.restoredDraftNotice, isNull);
    });
  });
}

class _GatedUploader implements AcpAttachmentUploader {
  _GatedUploader(this.gate);

  final Completer<void> gate;

  @override
  Future<AcpUploadedAttachment> upload({
    required String originalName,
    required String mimeType,
    required Stream<List<int>> stream,
    required int? totalBytes,
    required int maxBytes,
    required int attachmentIndex,
    required int attachmentCount,
    required AcpAttachmentCancellationToken cancellationToken,
    void Function(AcpAttachmentUploadProgress progress)? onProgress,
  }) async {
    await gate.future;
    await stream.drain<void>();
    return AcpUploadedAttachment(
      remotePath: '/uploads/$originalName',
      displayName: originalName,
      sizeBytes: totalBytes ?? 0,
      mimeType: mimeType,
    );
  }
}
