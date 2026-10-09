// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_attachment_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/controllers/acp_turn_recovery.dart';

import '../../support/fake_acp_session_manager.dart';

class _ThrowingUploader implements AcpAttachmentUploader {
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
  }) => throw StateError('unexpected uploader failure');
}

class _GatedUploader implements AcpAttachmentUploader {
  _GatedUploader({this.gate});

  final Completer<void>? gate;

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
    onProgress?.call(
      AcpAttachmentUploadProgress(
        attachmentIndex: attachmentIndex,
        attachmentCount: attachmentCount,
        bytesTransferred: 5,
        totalBytes: 10,
      ),
    );
    if (gate != null) {
      await gate!.future;
    }
    if (cancellationToken.isCancelled) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.cancelled,
        'cancelled',
      );
    }
    await stream.drain<void>();
    return AcpUploadedAttachment(
      remotePath: '/uploads/$originalName',
      displayName: originalName,
      sizeBytes: totalBytes ?? 0,
      mimeType: mimeType,
    );
  }
}

/// The agent answered `session/prompt` with an error: a confirmed failure.
const _agentError = AcpRemoteException(code: -32603, message: 'Internal error');

/// Completes every prompt with [stopReason] instead of `end_turn`.
/// Completes the nth prompt with the nth of [stopReasons], repeating the
/// last one, instead of `end_turn`.
class _StoppingAcpSessionManager extends RecordingAcpSessionManager {
  _StoppingAcpSessionManager(this.stopReasons);

  List<AcpStopReason> stopReasons;
  var _calls = 0;

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) async {
    final reason = stopReasons[_calls.clamp(0, stopReasons.length - 1)];
    _calls++;
    await super.prompt(key, content);
    return AcpPromptResult(stopReason: reason);
  }
}

AcpSessionKey _key() => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: 'session',
);

AcpSessionState _session({
  AcpConnectionStatus status = AcpConnectionStatus.ready,
  AcpPromptStatus promptStatus = AcpPromptStatus.idle,
  bool image = false,
  bool embeddedContext = false,
  List<AcpAvailableCommand> commands = const <AcpAvailableCommand>[],
}) {
  final now = DateTime(2026);
  return AcpSessionState(
    key: _key(),
    providerLabel: 'Copilot',
    cwd: '/home',
    status: status,
    createdAt: now,
    lastActivityAt: now,
    promptStatus: promptStatus,
    availableCommands: commands,
    initialization: AcpInitializeResult(
      protocolVersion: 1,
      agentCapabilities: AcpAgentCapabilities(
        prompt: AcpPromptCapabilities(
          image: image,
          embeddedContext: embeddedContext,
        ),
      ),
    ),
  );
}

AcpComposerController _controller(
  RecordingAcpSessionManager manager, {
  AcpAttachmentPreparationService? preparation,
  AcpAttachmentUploader? Function()? uploaderBuilder,
  AcpSessionState? session,
}) => AcpComposerController(
  manager: manager,
  sessionKey: _key(),
  preparationService: preparation ?? const AcpAttachmentPreparationService(),
  uploaderBuilder: uploaderBuilder,
  initialSession: session ?? _session(),
);

Uint8List _png() => Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  ...List<int>.filled(32, 0),
]);

void main() {
  test('cannot send without content or when disconnected', () {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(manager);
    addTearDown(controller.dispose);
    expect(controller.canSend, isFalse);

    controller.setText('hello');
    expect(controller.canSend, isTrue);

    controller.updateSession(
      _session(status: AcpConnectionStatus.reconnecting),
    );
    expect(controller.canSend, isFalse);
  });

  test('successful send snapshots atomically, clears on queue, and permits '
      'the next draft', () async {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(manager, session: _session(image: true))
      ..setText('do the thing');
    addTearDown(controller.dispose);
    controller.addAttachment(
      AcpAttachmentCandidate.memory(
        name: 'shot.png',
        bytes: _png(),
        mimeType: 'image/png',
      ),
    );

    final gate = Completer<void>();
    manager.promptGate = gate;
    expect(await controller.send(), isTrue);

    expect(controller.text, isEmpty);
    expect(controller.attachments, isEmpty);
    expect(controller.isEditable, isTrue);
    controller
      ..updateSession(
        _session(image: true, promptStatus: AcpPromptStatus.streaming),
      )
      ..setText('follow up');
    expect(controller.text, 'follow up');
    expect(controller.canSend, isTrue);

    final content = manager.prompts.single;
    expect(content.first, isA<AcpTextContent>());
    expect((content.first as AcpTextContent).text, 'do the thing');
    expect(content[1], isA<AcpImageContent>());
    gate.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('unexpected preparation failure preserves an editable draft', () async {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(
      manager,
      uploaderBuilder: _ThrowingUploader.new,
    )..setText('keep this draft');
    addTearDown(controller.dispose);
    controller
      ..addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'shot.png',
          bytes: _png(),
          mimeType: 'image/png',
        ),
      )
      ..enableRemoteUploadFallback();

    expect(await controller.send(), isFalse);
    expect(controller.text, 'keep this draft');
    expect(controller.attachments, hasLength(1));
    expect(controller.isEditable, isTrue);
    expect(controller.error?.message, contains('could not be prepared'));
    expect(manager.prompts, isEmpty);
  });

  test('preserves mixed attachment ordering in the prepared content', () async {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(
      manager,
      session: _session(image: true, embeddedContext: true),
    );
    addTearDown(controller.dispose);
    controller
      ..addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'a.png',
          bytes: _png(),
          mimeType: 'image/png',
        ),
      )
      ..addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'b.txt',
          bytes: Uint8List.fromList('hello'.codeUnits),
          mimeType: 'text/plain',
        ),
      );

    expect(await controller.send(), isTrue);
    final content = manager.prompts.single;
    expect(content[0], isA<AcpImageContent>());
    expect(content[1], isA<AcpResourceContent>());
  });

  test(
    'restores queued input and surfaces a send error when submission fails',
    () async {
      final manager = RecordingAcpSessionManager()..throwOnPrompt = _agentError;
      final controller = _controller(manager)..setText('keep me');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, 'keep me');
      expect(controller.error?.kind, AcpComposerErrorKind.send);
      expect(controller.activity, AcpComposerActivity.idle);
    },
  );

  test(
    'parks a rejected prompt restore while a newer send is still preparing',
    () async {
      final manager = RecordingAcpSessionManager();
      final promptGate = Completer<void>();
      final uploadGate = Completer<void>();
      manager
        ..promptGate = promptGate
        ..throwOnPrompt = _agentError;
      final controller = _controller(
        manager,
        preparation: const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(maxEmbeddedBytes: 1),
        ),
        uploaderBuilder: () => _GatedUploader(gate: uploadGate),
        session: _session(embeddedContext: true),
      )..setText('first');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      controller
        ..setText('second')
        ..addAttachment(
          AcpAttachmentCandidate.memory(
            name: 'big.txt',
            bytes: Uint8List.fromList('hello world'.codeUnits),
            mimeType: 'text/plain',
          ),
        )
        ..enableRemoteUploadFallback();
      final second = controller.send();
      await Future<void>.delayed(Duration.zero);
      expect(controller.activity, AcpComposerActivity.preparing);

      // The first prompt is rejected while the second is still uploading.
      promptGate.complete();
      await Future<void>.delayed(Duration.zero);
      uploadGate.complete();
      expect(await second, isTrue);

      expect(controller.text, 'first');
      expect(controller.attachments, isEmpty);
      expect(controller.error?.kind, AcpComposerErrorKind.send);
    },
  );

  test(
    'restores every rejected draft parked behind a preparing send',
    () async {
      final manager = RecordingAcpSessionManager();
      final promptGate = Completer<void>();
      final uploadGate = Completer<void>();
      manager
        ..promptGate = promptGate
        ..throwOnPrompt = _agentError;
      final controller = _controller(
        manager,
        preparation: const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(maxEmbeddedBytes: 1),
        ),
        uploaderBuilder: () => _GatedUploader(gate: uploadGate),
        session: _session(embeddedContext: true),
      )..setText('first');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      controller.setText('second');
      expect(await controller.send(), isTrue);
      controller
        ..setText('third')
        ..addAttachment(
          AcpAttachmentCandidate.memory(
            name: 'big.txt',
            bytes: Uint8List.fromList('hello world'.codeUnits),
            mimeType: 'text/plain',
          ),
        )
        ..enableRemoteUploadFallback();
      final third = controller.send();
      await Future<void>.delayed(Duration.zero);
      expect(controller.activity, AcpComposerActivity.preparing);

      // Both queued prompts are rejected while the third is still uploading.
      promptGate.complete();
      await Future<void>.delayed(Duration.zero);
      uploadGate.complete();
      expect(await third, isTrue);

      expect(controller.text, 'first\n\nsecond');
      expect(controller.attachments, isEmpty);
      expect(controller.error?.kind, AcpComposerErrorKind.send);
    },
  );

  test('session snapshots notify only when composer-visible state changes', () {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(manager);
    addTearDown(controller.dispose);
    var notifications = 0;
    controller
      ..addListener(() => notifications++)
      ..updateSession(_session());
    expect(notifications, 0);

    controller.updateSession(_session(promptStatus: AcpPromptStatus.streaming));
    expect(notifications, 1);
    expect(controller.activity, AcpComposerActivity.streaming);

    controller.updateSession(
      _session(status: AcpConnectionStatus.reconnecting),
    );
    expect(notifications, 2);

    controller.updateSession(_session(image: true));
    expect(notifications, 3);
    expect(controller.promptCapabilities.image, isTrue);
  });

  test('cancel while streaming cancels the turn', () async {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(
      manager,
      session: _session(promptStatus: AcpPromptStatus.streaming),
    );
    addTearDown(controller.dispose);
    expect(controller.activity, AcpComposerActivity.streaming);
    expect(controller.canCancel, isTrue);
    await controller.cancel();
    expect(manager.cancelCount, 1);
  });

  test('rejects oversize and over-count attachments before accepting', () {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(
      manager,
      preparation: const AcpAttachmentPreparationService(
        limits: AcpAttachmentLimits(maxCount: 1),
      ),
    );
    addTearDown(controller.dispose);

    expect(
      controller.addAttachment(
        const AcpAttachmentCandidate.remoteFile(
          name: 'huge.bin',
          remotePath: '/huge.bin',
          sizeBytes: 200 * 1024 * 1024,
        ),
      ),
      isFalse,
    );
    expect(controller.attachments, isEmpty);

    controller.clearError();
    expect(
      controller.addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'ok.txt',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      ),
      isTrue,
    );
    expect(
      controller.addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'second.txt',
          bytes: Uint8List.fromList(<int>[4]),
        ),
      ),
      isFalse,
    );
    expect(controller.attachments, hasLength(1));
  });

  group('slash commands', () {
    test('activates and inserts a command', () {
      final manager = RecordingAcpSessionManager();
      final controller = _controller(
        manager,
        session: _session(
          commands: [
            const AcpAvailableCommand(name: 'deploy', description: 'Deploy'),
          ],
        ),
      )..setText('/dep');
      addTearDown(controller.dispose);

      expect(controller.isSlashActive, isTrue);
      expect(controller.slashCommands.single.name, 'deploy');

      controller.selectSlashCommand(controller.slashCommands.single);
      expect(controller.text, '/deploy ');
      expect(controller.isSlashActive, isFalse);
    });

    test('reflects dynamically reloaded commands', () {
      final manager = RecordingAcpSessionManager();
      final controller = _controller(manager)..setText('/b');
      addTearDown(controller.dispose);
      expect(controller.slashCommands, isEmpty);

      controller.updateSession(
        _session(
          commands: [
            const AcpAvailableCommand(name: 'build', description: 'Build'),
          ],
        ),
      );
      expect(controller.slashCommands.single.name, 'build');
    });
  });

  test('reports upload progress on the affected attachment', () async {
    final manager = RecordingAcpSessionManager();
    final gate = Completer<void>();
    final controller = _controller(
      manager,
      preparation: const AcpAttachmentPreparationService(
        limits: AcpAttachmentLimits(maxEmbeddedBytes: 1),
      ),
      uploaderBuilder: () => _GatedUploader(gate: gate),
      session: _session(embeddedContext: true),
    );
    addTearDown(controller.dispose);
    controller
      ..addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'big.txt',
          bytes: Uint8List.fromList('hello world'.codeUnits),
          mimeType: 'text/plain',
        ),
      )
      ..enableRemoteUploadFallback();

    final future = controller.send();
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.attachments.single.status,
      AcpComposerAttachmentStatus.uploading,
    );
    expect(controller.attachments.single.progress, closeTo(0.5, 0.01));

    gate.complete();
    expect(await future, isTrue);
  });

  test(
    'cancelling during preparation retains input without an error',
    () async {
      final manager = RecordingAcpSessionManager();
      final gate = Completer<void>();
      final controller = _controller(
        manager,
        preparation: const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(maxEmbeddedBytes: 1),
        ),
        uploaderBuilder: () => _GatedUploader(gate: gate),
        session: _session(embeddedContext: true),
      )..setText('draft');
      addTearDown(controller.dispose);
      controller
        ..addAttachment(
          AcpAttachmentCandidate.memory(
            name: 'big.txt',
            bytes: Uint8List.fromList('hello world'.codeUnits),
            mimeType: 'text/plain',
          ),
        )
        ..enableRemoteUploadFallback();

      final future = controller.send();
      await Future<void>.delayed(Duration.zero);
      await controller.cancel();
      gate.complete();

      expect(await future, isFalse);
      expect(controller.text, 'draft');
      expect(controller.attachments, hasLength(1));
      expect(controller.error, isNull);
      expect(manager.prompts, isEmpty);
    },
  );

  test('accepts a new draft while the submitted snapshot is active', () async {
    final manager = RecordingAcpSessionManager();
    final gate = Completer<void>();
    manager.promptGate = gate;
    final controller = _controller(manager)..setText('snapshot');
    addTearDown(controller.dispose);

    expect(await controller.send(), isTrue);
    expect(controller.isEditable, isTrue);
    controller
      ..updateSession(_session(promptStatus: AcpPromptStatus.streaming))
      ..setText('post-snapshot edit');
    expect(
      controller.addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'x.txt',
          bytes: Uint8List.fromList(<int>[1]),
        ),
      ),
      isTrue,
    );
    expect(controller.text, 'post-snapshot edit');
    expect(controller.attachments, hasLength(1));

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.text, 'post-snapshot edit');
  });

  test('accepts draft mutations while a turn is streaming', () {
    final manager = RecordingAcpSessionManager();
    final controller = _controller(
      manager,
      session: _session(promptStatus: AcpPromptStatus.streaming),
    );
    addTearDown(controller.dispose);
    expect(controller.isEditable, isTrue);

    controller.setText('typed while streaming');
    expect(controller.text, 'typed while streaming');
    expect(controller.canSend, isTrue);
  });

  test('does not mutate or notify after dispose mid-send', () async {
    final manager = RecordingAcpSessionManager();
    final gate = Completer<void>();
    manager.promptGate = gate;
    final controller = _controller(manager)..setText('hi');
    var notifications = 0;
    controller.addListener(() => notifications++);

    final future = controller.send();
    await Future<void>.delayed(Duration.zero);
    final countBeforeDispose = notifications;
    controller.dispose();
    gate.complete();

    // Completing the awaited prompt after dispose must not notify listeners
    // (which would throw on a disposed ChangeNotifier) or clear state.
    expect(await future, isTrue);
    expect(notifications, countBeforeDispose);
  });

  group('failed and stopped turns', () {
    test('a confirmed failure restores the draft and offers a retry', () async {
      final manager = RecordingAcpSessionManager()..throwOnPrompt = _agentError;
      final controller = _controller(manager)..setText('run the tests');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, 'run the tests');
      expect(controller.canRetryFailedPrompt, isTrue);
      expect(controller.turnRecovery, isNull);

      manager.throwOnPrompt = null;
      expect(await controller.retryFailedPrompt(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(manager.prompts, hasLength(2));
      expect(
        (manager.prompts.last.single as AcpTextContent).text,
        'run the tests',
      );
      expect(controller.text, isEmpty);
      expect(controller.canRetryFailedPrompt, isFalse);
      expect(controller.error, isNull);
    });

    test('a full local queue counts as a confirmed failure', () async {
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpPromptQueueFullException();
      final controller = _controller(manager)..setText('later');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, 'later');
      expect(controller.canRetryFailedPrompt, isTrue);
    });

    for (final (name, error) in <(String, Object)>[
      ('a closed connection', const AcpConnectionClosedException()),
      (
        'a timeout',
        AcpRequestTimeoutException(1, 'session/prompt', Duration.zero),
      ),
      ('an unknown error', StateError('lost')),
    ]) {
      test(
        '$name keeps the prompt out of the draft and offers no retry',
        () async {
          final manager = RecordingAcpSessionManager()..throwOnPrompt = error;
          final controller = _controller(manager)..setText('deploy');
          addTearDown(controller.dispose);

          expect(await controller.send(), isTrue);
          await Future<void>.delayed(Duration.zero);
          expect(controller.text, isEmpty);
          expect(controller.error, isNull);
          expect(controller.canRetryFailedPrompt, isFalse);
          expect(
            controller.turnRecovery?.kind,
            AcpTurnRecoveryKind.unconfirmed,
          );

          controller.editLastPrompt();
          expect(controller.text, 'deploy');
          expect(controller.turnRecovery, isNull);
          expect(manager.prompts, hasLength(1));
        },
      );
    }

    test(
      'every prompt whose answer was lost can be edited, oldest first',
      () async {
        final manager = RecordingAcpSessionManager();
        final gate = Completer<void>();
        manager
          ..promptGate = gate
          ..throwOnPrompt = const AcpConnectionClosedException();
        final controller = _controller(manager)..setText('first');
        addTearDown(controller.dispose);

        expect(await controller.send(), isTrue);
        controller.setText('second');
        expect(await controller.send(), isTrue);
        controller.setText('typed since');
        gate.complete();
        await Future<void>.delayed(Duration.zero);

        expect(controller.turnRecovery?.drafts, hasLength(2));
        controller.editLastPrompt();
        expect(controller.text, 'first\n\nsecond\n\ntyped since');
      },
    );

    test('a stopped last turn offers its prompt back for editing', () async {
      final manager = _StoppingAcpSessionManager([AcpStopReason.cancelled]);
      final controller = _controller(
        manager,
        session: _session(embeddedContext: true),
      )..setText('refactor it');
      addTearDown(controller.dispose);
      controller.addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'notes.txt',
          bytes: Uint8List.fromList('notes'.codeUnits),
        ),
      );

      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, isEmpty);
      expect(controller.turnRecovery?.kind, AcpTurnRecoveryKind.cancelled);
      expect(controller.canRetryFailedPrompt, isFalse);

      controller.editLastPrompt();
      expect(controller.text, 'refactor it');
      expect(controller.attachments.single.name, 'notes.txt');
      expect(controller.turnRecovery, isNull);
    });

    test('only the latest submission offers a stopped prompt', () async {
      // The first prompt is stopped, but a newer one was sent after it.
      final manager = _StoppingAcpSessionManager([
        AcpStopReason.cancelled,
        AcpStopReason.endTurn,
      ]);
      final gate = Completer<void>();
      manager.promptGate = gate;
      final controller = _controller(manager)..setText('first');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      controller.setText('second');
      expect(await controller.send(), isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(controller.turnRecovery, isNull);
    });

    test('sending a new prompt or dismissing clears the offer', () async {
      final manager = _StoppingAcpSessionManager([AcpStopReason.cancelled]);
      final controller = _controller(manager)..setText('one');
      addTearDown(controller.dispose);

      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.turnRecovery, isNotNull);
      controller.dismissTurnRecovery();
      expect(controller.turnRecovery, isNull);

      manager.stopReasons = [AcpStopReason.endTurn];
      controller.setText('two');
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.turnRecovery, isNull);
    });
  });

  group('prompt failure outcomes', () {
    test(
      'a prompt that was never sent returns to the draft with Retry',
      () async {
        final manager = RecordingAcpSessionManager()
          ..throwOnPrompt = const AcpPromptNotSentException();
        final controller = _controller(manager)..setText('queued work');
        addTearDown(controller.dispose);

        expect(await controller.send(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(controller.text, 'queued work');
        expect(controller.canRetryFailedPrompt, isTrue);
        expect(controller.turnRecovery, isNull);
      },
    );

    test(
      'an agent error after the turn started offers Edit, not Retry',
      () async {
        final manager = RecordingAcpSessionManager()
          ..throwOnPrompt = const AcpPromptFailedMidTurnException(_agentError);
        final controller = _controller(manager)..setText('migrate');
        addTearDown(controller.dispose);

        expect(await controller.send(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(controller.text, isEmpty);
        expect(controller.canRetryFailedPrompt, isFalse);
        expect(
          controller.turnRecovery?.kind,
          AcpTurnRecoveryKind.failedMidTurn,
        );
        controller.editLastPrompt();
        expect(controller.text, 'migrate');
      },
    );

    test('a lost prompt survives sending another one', () async {
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpConnectionClosedException();
      final controller = _controller(manager)..setText('deploy');
      addTearDown(controller.dispose);
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);

      manager.throwOnPrompt = null;
      controller.setText('continue');
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(controller.turnRecovery?.kind, AcpTurnRecoveryKind.unconfirmed);
      expect(controller.turnRecovery?.drafts.single.text, 'deploy');
    });

    test(
      'a lost answer is withdrawn once its reattached turn finishes',
      () async {
        final manager = RecordingAcpSessionManager()
          ..throwOnPrompt = const AcpConnectionClosedException();
        final controller = _controller(
          manager,
          session: _session(promptStatus: AcpPromptStatus.streaming),
        )..setText('long build');
        addTearDown(controller.dispose);
        expect(await controller.send(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(controller.turnRecovery, isNotNull);

        // The failing turn's own settling is not a reattached turn finishing.
        controller.updateSession(_session());
        expect(controller.turnRecovery, isNotNull);
        controller.updateSession(
          _session(
            status: AcpConnectionStatus.detached,
            promptStatus: AcpPromptStatus.streaming,
          ),
        );
        expect(controller.turnRecovery, isNotNull);
        controller.updateSession(
          _session(promptStatus: AcpPromptStatus.streaming),
        );
        expect(controller.turnRecovery, isNotNull);
        controller.updateSession(_session());
        expect(controller.turnRecovery, isNull);
      },
    );

    group('when a reattached lost turn ends', () {
      Future<AcpComposerController> twoLost() async {
        final manager = RecordingAcpSessionManager()
          ..throwOnPrompt = const AcpConnectionClosedException();
        final controller = _controller(
          manager,
          session: _session(promptStatus: AcpPromptStatus.streaming),
        )..setText('older X');
        addTearDown(controller.dispose);
        expect(await controller.send(), isTrue);
        await Future<void>.delayed(Duration.zero);
        controller.setText('newer A');
        expect(await controller.send(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(controller.turnRecovery?.drafts, hasLength(2));
        // Reattach: the host is still running A's turn.
        controller
          ..updateSession(
            _session(
              status: AcpConnectionStatus.detached,
              promptStatus: AcpPromptStatus.streaming,
            ),
          )
          ..updateSession(_session(promptStatus: AcpPromptStatus.streaming));
        return controller;
      }

      List<String>? offered(AcpComposerController controller) =>
          controller.turnRecovery?.drafts.map((draft) => draft.text).toList();

      test('only its own draft is withdrawn', () async {
        final controller = await twoLost();
        controller.updateSession(_session());
        expect(offered(controller), ['older X']);
      });

      test('stopping it keeps every draft', () async {
        final controller = await twoLost();
        controller
          ..updateSession(_session(promptStatus: AcpPromptStatus.cancelling))
          ..updateSession(_session());
        expect(offered(controller), ['older X', 'newer A']);
      });

      test('a relaunch onto another session keeps every draft', () async {
        final controller = await twoLost();
        final relaunched = _session().copyWith(
          key: AcpSessionKey.of(
            hostId: 1,
            providerId: 'copilot',
            bridgeId: 'new-bridge',
            acpSessionId: 'session',
          ),
        );
        controller.updateSession(relaunched);
        expect(offered(controller), ['older X', 'newer A']);
      });
    });

    test('several prompts that never left come back in send order', () async {
      final manager = RecordingAcpSessionManager();
      final gate = Completer<void>();
      manager
        ..promptGate = gate
        ..throwOnPrompt = const AcpPromptNotSentException();
      final controller = _controller(manager)..setText('B');
      addTearDown(controller.dispose);
      expect(await controller.send(), isTrue);
      controller.setText('C');
      expect(await controller.send(), isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, 'B\n\nC');
    });

    test('removing an attachment between refused prompts is safe', () async {
      final manager = RecordingAcpSessionManager();
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      manager
        ..promptGate = firstGate
        ..throwOnPrompt = const AcpPromptNotSentException();
      final controller = _controller(
        manager,
        session: _session(embeddedContext: true),
      )..setText('B');
      addTearDown(controller.dispose);
      controller.addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'b.txt',
          bytes: Uint8List.fromList('notes'.codeUnits),
          mimeType: 'text/plain',
        ),
      );
      expect(await controller.send(), isTrue);
      manager.promptGate = secondGate;
      controller.setText('C');
      expect(await controller.send(), isTrue);

      // B is refused and restored, then the user removes its attachment
      // before C is refused too.
      firstGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.text, 'B');
      controller.removeAttachment(controller.attachments.single.id);
      secondGate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(controller.text, 'B\n\nC');
      expect(controller.attachments, isEmpty);
    });

    test('refused prompts with too many attachments together are not '
        'offered for retry', () async {
      final manager = RecordingAcpSessionManager();
      final gate = Completer<void>();
      manager
        ..promptGate = gate
        ..throwOnPrompt = const AcpPromptNotSentException();
      final controller = _controller(
        manager,
        preparation: const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(maxCount: 1),
        ),
        session: _session(embeddedContext: true),
      );
      addTearDown(controller.dispose);
      AcpAttachmentCandidate file(String name) => AcpAttachmentCandidate.memory(
        name: name,
        bytes: Uint8List.fromList('notes'.codeUnits),
        mimeType: 'text/plain',
      );
      controller
        ..setText('A')
        ..addAttachment(file('a.txt'));
      expect(await controller.send(), isTrue);
      controller
        ..setText('B')
        ..addAttachment(file('b.txt'));
      expect(await controller.send(), isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      // Each prompt fitted alone; together they do not, so Retry would fail.
      expect(controller.text, 'A\n\nB');
      expect(controller.attachments.map((a) => a.name), ['a.txt', 'b.txt']);
      expect(controller.canRetryFailedPrompt, isFalse);
      expect(controller.error?.kind, AcpComposerErrorKind.attachment);

      controller.removeAttachment(controller.attachments.last.id);
      expect(controller.error?.kind, AcpComposerErrorKind.send);
      expect(controller.canRetryFailedPrompt, isTrue);
    });

    test('editing keeps prompts whose attachments would not fit', () async {
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpConnectionClosedException();
      final controller = _controller(
        manager,
        preparation: const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(maxCount: 2),
        ),
        session: _session(embeddedContext: true),
      )..setText('with files');
      addTearDown(controller.dispose);
      AcpAttachmentCandidate file(String name) => AcpAttachmentCandidate.memory(
        name: name,
        bytes: Uint8List.fromList('notes'.codeUnits),
        mimeType: 'text/plain',
      );
      controller
        ..addAttachment(file('a.txt'))
        ..addAttachment(file('b.txt'));
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.turnRecovery, isNotNull);

      controller
        ..addAttachment(file('c.txt'))
        ..editLastPrompt();
      expect(controller.turnRecovery, isNotNull);
      expect(controller.attachments, hasLength(1));
      expect(controller.error?.kind, AcpComposerErrorKind.attachment);

      controller
        ..removeAttachment(controller.attachments.single.id)
        ..editLastPrompt();
      expect(controller.turnRecovery, isNull);
      expect(controller.attachments.map((a) => a.name), ['a.txt', 'b.txt']);
      expect(controller.text, 'with files');
      expect(controller.error, isNull);
    });

    test('a stopped prompt joins an earlier lost one on offer', () async {
      final manager = _StoppingAcpSessionManager([AcpStopReason.cancelled])
        ..throwOnPrompt = const AcpConnectionClosedException();
      final controller = _controller(manager)..setText('lost one');
      addTearDown(controller.dispose);
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);

      manager.throwOnPrompt = null;
      controller.setText('stopped one');
      expect(await controller.send(), isTrue);
      await Future<void>.delayed(Duration.zero);

      final recovery = controller.turnRecovery!;
      expect(recovery.kind, AcpTurnRecoveryKind.unconfirmed);
      expect(recovery.drafts.map((draft) => draft.text), [
        'lost one',
        'stopped one',
      ]);
    });
  });
}
