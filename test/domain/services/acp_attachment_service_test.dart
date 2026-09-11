import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/services/acp_attachment_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

class _RecordingUploader implements AcpAttachmentUploader {
  final uploadedBytes = <int>[];
  final uploadedPayloads = <List<int>>[];
  int calls = 0;

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
    calls++;
    final payload = await stream.expand((chunk) => chunk).toList();
    uploadedBytes.add(payload.length);
    uploadedPayloads.add(payload);
    return AcpUploadedAttachment(
      remotePath: '/home/demo/.cache/monkeyssh/uploads/safe-$calls.bin',
      displayName: 'safe-$calls.bin',
      sizeBytes: payload.length,
      mimeType: mimeType,
    );
  }
}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockRemoteFileService extends Mock implements RemoteFileService {}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<List<int>>.empty());
  });

  group('AcpAttachmentPreparationService', () {
    const capabilities = AcpPromptCapabilities(
      image: true,
      embeddedContext: true,
    );

    test(
      'preserves ordered mixed text, image, text, and binary blocks',
      () async {
        const service = AcpAttachmentPreparationService();
        final blocks = await service.prepare(
          draft: AcpPromptDraft([
            const AcpPromptTextDraft('before'),
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'photo.png',
                bytes: Uint8List.fromList(_pngHeader),
              ),
            ),
            const AcpPromptTextDraft('between'),
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'notes.txt',
                bytes: Uint8List.fromList(<int>[104, 101, 108, 108, 111]),
              ),
            ),
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'archive.bin',
                bytes: Uint8List.fromList(<int>[0, 1, 2, 3]),
              ),
            ),
          ]),
          capabilities: capabilities,
        );

        expect(blocks, hasLength(5));
        expect((blocks[0] as AcpTextContent).text, 'before');
        final image = blocks[1] as AcpImageContent;
        expect(image.mimeType, 'image/png');
        expect(base64Decode(image.data), _pngHeader);
        expect((blocks[2] as AcpTextContent).text, 'between');
        final textResource =
            (blocks[3] as AcpResourceContent).resource as AcpTextResource;
        expect(textResource.text, 'hello');
        expect(textResource.mimeType, 'text/plain');
        final blobResource =
            (blocks[4] as AcpResourceContent).resource as AcpBlobResource;
        expect(base64Decode(blobResource.blob), <int>[0, 1, 2, 3]);
        expect(blobResource.mimeType, 'application/octet-stream');
      },
    );

    test('uses an embedded blob when image prompts are unsupported', () async {
      final blocks = await const AcpAttachmentPreparationService().prepare(
        draft: AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'photo.png',
              bytes: Uint8List.fromList(_pngHeader),
            ),
          ),
        ]),
        capabilities: const AcpPromptCapabilities(embeddedContext: true),
      );

      final resource =
          (blocks.single as AcpResourceContent).resource as AcpBlobResource;
      expect(resource.mimeType, 'image/png');
    });

    test('requires explicit upload fallback for unsupported content', () async {
      const service = AcpAttachmentPreparationService();
      final draft = AcpPromptDraft([
        AcpAttachmentDraft(
          candidate: AcpAttachmentCandidate.memory(
            name: 'notes.txt',
            bytes: Uint8List.fromList(utf8.encode('hello')),
          ),
        ),
      ]);

      await expectLater(
        service.prepare(
          draft: draft,
          capabilities: const AcpPromptCapabilities(),
          uploader: _RecordingUploader(),
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.unsupportedCapability,
          ),
        ),
      );
    });

    test('uploads only when fallback was explicitly selected', () async {
      final uploader = _RecordingUploader();
      final blocks = await const AcpAttachmentPreparationService().prepare(
        draft: AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'notes.txt',
              bytes: Uint8List.fromList(utf8.encode('hello')),
            ),
            fallback: AcpAttachmentFallback.remoteUpload,
          ),
        ]),
        capabilities: const AcpPromptCapabilities(),
        uploader: uploader,
      );

      expect(uploader.calls, 1);
      expect(uploader.uploadedBytes, <int>[5]);
      final link = blocks.single as AcpResourceLinkContent;
      expect(link.name, 'notes.txt');
      expect(link.uri, startsWith('file:///home/demo/'));
      expect(link.mimeType, 'text/plain');
      expect(link.size, 5);
    });

    test('detects MIME type from header bytes without an extension', () async {
      final blocks = await const AcpAttachmentPreparationService().prepare(
        draft: AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'photo',
              bytes: Uint8List.fromList(_pngHeader),
            ),
          ),
        ]),
        capabilities: const AcpPromptCapabilities(image: true),
      );

      expect((blocks.single as AcpImageContent).mimeType, 'image/png');
    });

    test('enforces count, file, total, filename, and MIME limits', () async {
      const service = AcpAttachmentPreparationService(
        limits: AcpAttachmentLimits(
          maxCount: 1,
          maxFileBytes: 4,
          maxTotalBytes: 6,
          maxEmbeddedBytes: 4,
          maxImageBytes: 4,
          maxFileNameBytes: 8,
          maxMimeTypeBytes: 20,
        ),
      );

      Future<void> expectFailure(
        AcpPromptDraft draft,
        AcpAttachmentFailure failure,
      ) async {
        await expectLater(
          service.prepare(draft: draft, capabilities: capabilities),
          throwsA(
            isA<AcpAttachmentException>().having(
              (error) => error.failure,
              'failure',
              failure,
            ),
          ),
        );
      }

      await expectFailure(
        AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'a',
              bytes: Uint8List(1),
            ),
          ),
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'b',
              bytes: Uint8List(1),
            ),
          ),
        ]),
        AcpAttachmentFailure.countLimit,
      );
      await expectFailure(
        AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'a.bin',
              bytes: Uint8List(5),
            ),
          ),
        ]),
        AcpAttachmentFailure.fileSizeLimit,
      );

      const totalService = AcpAttachmentPreparationService(
        limits: AcpAttachmentLimits(
          maxCount: 2,
          maxFileBytes: 4,
          maxTotalBytes: 6,
          maxEmbeddedBytes: 4,
          maxImageBytes: 4,
        ),
      );
      await expectLater(
        totalService.prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'a.bin',
                bytes: Uint8List(4),
              ),
            ),
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'b.bin',
                bytes: Uint8List(3),
              ),
            ),
          ]),
          capabilities: capabilities,
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.totalSizeLimit,
          ),
        ),
      );
      await expectFailure(
        AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: '../bad',
              bytes: Uint8List(1),
            ),
          ),
        ]),
        AcpAttachmentFailure.invalidFileName,
      );
      await expectFailure(
        AcpPromptDraft([
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.memory(
              name: 'a',
              bytes: Uint8List(1),
              mimeType: 'not a mime',
            ),
          ),
        ]),
        AcpAttachmentFailure.invalidMimeType,
      );
    });

    for (final size in [6 * 1024 * 1024, kAcpAttachmentImageDisplayMaxBytes]) {
      test('accepts a $size byte image for inline display', () async {
        final bytes = Uint8List(size)
          ..setRange(0, _pngHeader.length, _pngHeader);
        final blocks = await const AcpAttachmentPreparationService().prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'large.png',
                bytes: bytes,
              ),
            ),
          ]),
          capabilities: const AcpPromptCapabilities(image: true),
        );
        expect(
          base64Decode((blocks.single as AcpImageContent).data).length,
          size,
        );
      });
    }

    test('enforces the 10 MiB image display cap', () async {
      final bytes = Uint8List(kAcpAttachmentImageDisplayMaxBytes + 1)
        ..setRange(0, _pngHeader.length, _pngHeader);
      await expectLater(
        const AcpAttachmentPreparationService().prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'large.png',
                bytes: bytes,
              ),
            ),
          ]),
          capabilities: const AcpPromptCapabilities(image: true),
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.imageSizeLimit,
          ),
        ),
      );
    });

    test(
      'image upload fallback preserves bytes beyond the sniff prefix',
      () async {
        final uploader = _RecordingUploader();
        final payload = <int>[..._pngHeader, 1, 2, 3, 4, 5, 6, 7, 8];
        final blocks =
            await const AcpAttachmentPreparationService(
              limits: AcpAttachmentLimits(
                maxImageBytes: 32,
                maxEmbeddedBytes: 10,
                mimeSniffBytes: 8,
              ),
            ).prepare(
              draft: AcpPromptDraft([
                AcpAttachmentDraft(
                  candidate: AcpAttachmentCandidate.localFile(
                    name: 'image.png',
                    openRead: () => Stream<List<int>>.fromIterable([
                      payload.sublist(0, 8),
                      payload.sublist(8),
                    ]),
                  ),
                  fallback: AcpAttachmentFallback.remoteUpload,
                ),
              ]),
              capabilities: const AcpPromptCapabilities(embeddedContext: true),
              uploader: uploader,
            );
        expect(uploader.uploadedPayloads, [payload]);
        expect((blocks.single as AcpResourceLinkContent).size, payload.length);
      },
    );

    test(
      'local images can use the larger advertised embedded budget',
      () async {
        final payload = <int>[..._pngHeader, 1, 2, 3, 4];
        final blocks =
            await const AcpAttachmentPreparationService(
              limits: AcpAttachmentLimits(
                maxImageBytes: 8,
                maxEmbeddedBytes: 32,
                mimeSniffBytes: 8,
              ),
            ).prepare(
              draft: AcpPromptDraft([
                AcpAttachmentDraft(
                  candidate: AcpAttachmentCandidate.localFile(
                    name: 'image.png',
                    sizeBytes: payload.length,
                    openRead: () => Stream<List<int>>.value(payload),
                  ),
                ),
              ]),
              capabilities: capabilities,
            );
        final resource =
            (blocks.single as AcpResourceContent).resource as AcpBlobResource;
        expect(base64Decode(resource.blob), payload);
      },
    );

    test(
      'cancellation during the final local read rejects preparation',
      () async {
        final token = AcpAttachmentCancellationToken();
        var sourceClosed = false;
        await expectLater(
          const AcpAttachmentPreparationService().prepare(
            draft: AcpPromptDraft([
              AcpAttachmentDraft(
                candidate: AcpAttachmentCandidate.localFile(
                  name: 'notes.txt',
                  openRead: () async* {
                    try {
                      yield utf8.encode('hello');
                      token.cancel();
                    } finally {
                      sourceClosed = true;
                    }
                  },
                ),
              ),
            ]),
            capabilities: const AcpPromptCapabilities(embeddedContext: true),
            cancellationToken: token,
          ),
          throwsA(
            isA<AcpAttachmentException>().having(
              (error) => error.failure,
              'failure',
              AcpAttachmentFailure.cancelled,
            ),
          ),
        );
        expect(sourceClosed, isTrue);
      },
    );

    test('reads local candidates lazily and accepts chunked streams', () async {
      var opens = 0;
      final candidate = AcpAttachmentCandidate.localFile(
        name: 'notes.txt',
        sizeBytes: 5,
        openRead: () {
          opens++;
          return Stream<List<int>>.fromIterable(<List<int>>[
            <int>[104, 101],
            <int>[108, 108, 111],
          ]);
        },
      );
      final draft = AcpPromptDraft([AcpAttachmentDraft(candidate: candidate)]);
      expect(opens, 0);

      final blocks = await const AcpAttachmentPreparationService().prepare(
        draft: draft,
        capabilities: const AcpPromptCapabilities(embeddedContext: true),
      );

      expect(opens, 1);
      final resource =
          (blocks.single as AcpResourceContent).resource as AcpTextResource;
      expect(resource.text, 'hello');
    });

    test('uploads all local chunks after the MIME-sniff fallback', () async {
      var chunksRead = 0;
      final uploader = _RecordingUploader();
      final candidate = AcpAttachmentCandidate.localFile(
        name: 'data.bin',
        sizeBytes: 9,
        openRead: () async* {
          for (final chunk in const <List<int>>[
            <int>[1, 2, 3],
            <int>[4, 5, 6],
            <int>[7, 8, 9],
          ]) {
            chunksRead++;
            yield chunk;
          }
        },
      );

      final blocks =
          await const AcpAttachmentPreparationService(
            limits: AcpAttachmentLimits(mimeSniffBytes: 4),
          ).prepare(
            draft: AcpPromptDraft([
              AcpAttachmentDraft(
                candidate: candidate,
                fallback: AcpAttachmentFallback.remoteUpload,
              ),
            ]),
            capabilities: const AcpPromptCapabilities(),
            uploader: uploader,
          );

      expect(chunksRead, 3);
      expect(uploader.uploadedBytes, <int>[9]);
      expect(uploader.uploadedPayloads, <List<int>>[
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9],
      ]);
      expect((blocks.single as AcpResourceLinkContent).size, 9);
    });

    test('uploads all local chunks after inline buffering overflows', () async {
      var chunksRead = 0;
      final uploader = _RecordingUploader();
      final candidate = AcpAttachmentCandidate.localFile(
        name: 'data.bin',
        openRead: () async* {
          for (final chunk in const <List<int>>[
            <int>[1, 2, 3],
            <int>[4, 5, 6],
            <int>[7, 8, 9],
          ]) {
            chunksRead++;
            yield chunk;
          }
        },
      );

      final blocks =
          await const AcpAttachmentPreparationService(
            limits: AcpAttachmentLimits(maxEmbeddedBytes: 7, mimeSniffBytes: 4),
          ).prepare(
            draft: AcpPromptDraft([
              AcpAttachmentDraft(
                candidate: candidate,
                fallback: AcpAttachmentFallback.remoteUpload,
              ),
            ]),
            capabilities: const AcpPromptCapabilities(embeddedContext: true),
            uploader: uploader,
          );

      expect(chunksRead, 3);
      expect(uploader.uploadedBytes, <int>[9]);
      expect(uploader.uploadedPayloads, <List<int>>[
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9],
      ]);
      expect((blocks.single as AcpResourceLinkContent).size, 9);
    });

    test('stops reading an unknown-size file at the byte limit', () async {
      var chunksRead = 0;
      final candidate = AcpAttachmentCandidate.localFile(
        name: 'data.bin',
        openRead: () async* {
          for (final chunk in const <List<int>>[
            <int>[1, 2, 3],
            <int>[4, 5, 6],
            <int>[7, 8, 9],
          ]) {
            chunksRead++;
            yield chunk;
          }
        },
      );

      await expectLater(
        const AcpAttachmentPreparationService(
          limits: AcpAttachmentLimits(
            maxFileBytes: 5,
            maxTotalBytes: 10,
            maxEmbeddedBytes: 5,
            maxImageBytes: 5,
          ),
        ).prepare(
          draft: AcpPromptDraft([AcpAttachmentDraft(candidate: candidate)]),
          capabilities: const AcpPromptCapabilities(embeddedContext: true),
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.fileSizeLimit,
          ),
        ),
      );
      expect(chunksRead, 2);
    });

    test('maps local read failures to a safe unreadable error', () async {
      await expectLater(
        const AcpAttachmentPreparationService().prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.localFile(
                name: 'notes.txt',
                openRead: () => Stream<List<int>>.error(
                  StateError('private source detail'),
                ),
              ),
            ),
          ]),
          capabilities: const AcpPromptCapabilities(embeddedContext: true),
        ),
        throwsA(
          isA<AcpAttachmentException>()
              .having(
                (error) => error.failure,
                'failure',
                AcpAttachmentFailure.unreadable,
              )
              .having(
                (error) => error.toString(),
                'safe text',
                isNot(contains('private source detail')),
              ),
        ),
      );
    });

    test('rejects invalid UTF-8 text safely', () async {
      await expectLater(
        const AcpAttachmentPreparationService().prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.memory(
                name: 'notes.txt',
                bytes: Uint8List.fromList(<int>[0xC3, 0x28]),
              ),
            ),
          ]),
          capabilities: const AcpPromptCapabilities(embeddedContext: true),
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.invalidUtf8,
          ),
        ),
      );
    });

    test('maps remote selections directly to resource links', () async {
      final blocks = await const AcpAttachmentPreparationService().prepare(
        draft: AcpPromptDraft(const [
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.remoteFile(
              name: 'report.txt',
              remotePath: '/srv/private/report.txt',
              sizeBytes: 42,
              mimeType: 'text/plain',
            ),
          ),
        ]),
        capabilities: const AcpPromptCapabilities(),
      );

      final link = blocks.single as AcpResourceLinkContent;
      expect(link.uri, 'file:///srv/private/report.txt');
      expect(link.name, 'report.txt');
      expect(link.size, 42);
    });

    test('supports cancellation before any file read', () async {
      var opened = false;
      final token = AcpAttachmentCancellationToken()..cancel();
      await expectLater(
        const AcpAttachmentPreparationService().prepare(
          draft: AcpPromptDraft([
            AcpAttachmentDraft(
              candidate: AcpAttachmentCandidate.localFile(
                name: 'notes.txt',
                openRead: () {
                  opened = true;
                  return const Stream<List<int>>.empty();
                },
              ),
            ),
          ]),
          capabilities: const AcpPromptCapabilities(embeddedContext: true),
          cancellationToken: token,
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.cancelled,
          ),
        ),
      );
      expect(opened, isFalse);
    });

    test('diagnostics contain no names, paths, or content', () async {
      final diagnostics = RecordingDiagnosticsLogger();
      await AcpAttachmentPreparationService(diagnostics: diagnostics).prepare(
        draft: AcpPromptDraft(const [
          AcpPromptTextDraft('PRIVATE PROMPT'),
          AcpAttachmentDraft(
            candidate: AcpAttachmentCandidate.remoteFile(
              name: 'secret-name.txt',
              remotePath: '/secret/private/path.txt',
              sizeBytes: 12,
              mimeType: 'text/plain',
            ),
          ),
        ]),
        capabilities: const AcpPromptCapabilities(),
      );

      expect(
        diagnostics.events.map((event) => event.message),
        contains('prepare_completed'),
      );
      final logged = diagnostics.events
          .map((event) => event.searchableText)
          .join('\n');
      expect(logged, isNot(contains('PRIVATE PROMPT')));
      expect(logged, isNot(contains('secret-name')));
      expect(logged, isNot(contains('/secret/')));
      expect(logged, isNot(contains('path')));
    });
  });

  group('SftpAcpAttachmentUploader', () {
    late _MockSftpClient sftp;
    late _MockRemoteFileService remoteFileService;

    setUp(() {
      sftp = _MockSftpClient();
      remoteFileService = _MockRemoteFileService();
      when(
        () => remoteFileService.resolveInitialDirectory(sftp),
      ).thenAnswer((_) async => '/home/demo');
      when(
        () => remoteFileService.ensureDirectoryExists(
          sftp,
          any(),
          mode: any(named: 'mode'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => remoteFileService.uploadStream(
          sftp: sftp,
          remotePath: any(named: 'remotePath'),
          stream: any(named: 'stream'),
          applyPrivateMode: any(named: 'applyPrivateMode'),
        ),
      ).thenAnswer((invocation) async {
        final stream = invocation.namedArguments[#stream] as Stream<List<int>>;
        await stream.drain<void>();
      });
      when(() => sftp.remove(any())).thenAnswer((_) async {});
    });

    test(
      'uploads privately with progress and sanitized collision-safe name',
      () async {
        final progress = <int>[];
        final uploader = SftpAcpAttachmentUploader(
          sftp: sftp,
          remoteFileService: remoteFileService,
          now: () => DateTime.utc(2026, 7, 12),
          uniqueId: () => 'id-123',
        );

        final result = await uploader.upload(
          originalName: r'../../My secret $(id).txt',
          mimeType: 'text/plain',
          stream: Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3, 4, 5],
          ]),
          totalBytes: 5,
          maxBytes: 10,
          attachmentIndex: 1,
          attachmentCount: 2,
          cancellationToken: AcpAttachmentCancellationToken(),
          onProgress: (value) => progress.add(value.bytesTransferred),
        );

        expect(result.displayName, 'acp-1783814400000-id123-My-secret-id-.txt');
        expect(result.sizeBytes, 5);
        expect(progress, <int>[0, 2, 5]);
        verify(
          () => remoteFileService.ensureDirectoryExists(
            sftp,
            '/home/demo/.cache/monkeyssh',
            mode: remoteUploadDirectoryMode,
          ),
        ).called(1);
        verify(
          () => remoteFileService.ensureDirectoryExists(
            sftp,
            '/home/demo/.cache/monkeyssh/uploads',
            mode: remoteUploadDirectoryMode,
          ),
        ).called(1);
        verify(
          () => remoteFileService.uploadStream(
            sftp: sftp,
            remotePath:
                '/home/demo/.cache/monkeyssh/uploads/'
                'acp-1783814400000-id123-My-secret-id-.txt',
            stream: any(named: 'stream'),
          ),
        ).called(1);
        verifyNever(() => sftp.remove(any()));
      },
    );

    test('cancels and cleans a partial upload', () async {
      final token = AcpAttachmentCancellationToken();
      final uploader = SftpAcpAttachmentUploader(
        sftp: sftp,
        remoteFileService: remoteFileService,
        now: () => DateTime.utc(2026, 7, 12),
        uniqueId: () => 'cancel',
      );

      await expectLater(
        uploader.upload(
          originalName: 'file.bin',
          mimeType: 'application/octet-stream',
          stream: Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3, 4],
          ]),
          totalBytes: 4,
          maxBytes: 10,
          attachmentIndex: 0,
          attachmentCount: 1,
          cancellationToken: token,
          onProgress: (progress) {
            if (progress.bytesTransferred == 2) token.cancel();
          },
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.cancelled,
          ),
        ),
      );
      verify(
        () => sftp.remove(
          '/home/demo/.cache/monkeyssh/uploads/'
          'acp-1783814400000-cancel-file.bin',
        ),
      ).called(1);
    });

    test(
      'preparation cancellation closes the source and cleans upload',
      () async {
        var sourceClosed = false;
        final token = AcpAttachmentCancellationToken();
        final uploader = SftpAcpAttachmentUploader(
          sftp: sftp,
          remoteFileService: remoteFileService,
          now: () => DateTime.utc(2026, 7, 12),
          uniqueId: () => 'pipeline-cancel',
        );
        final candidate = AcpAttachmentCandidate.localFile(
          name: 'file.bin',
          sizeBytes: 9,
          openRead: () async* {
            try {
              yield const <int>[1, 2, 3];
              yield const <int>[4, 5, 6];
              yield const <int>[7, 8, 9];
            } finally {
              sourceClosed = true;
            }
          },
        );

        await expectLater(
          const AcpAttachmentPreparationService(
            limits: AcpAttachmentLimits(mimeSniffBytes: 4),
          ).prepare(
            draft: AcpPromptDraft([
              AcpAttachmentDraft(
                candidate: candidate,
                fallback: AcpAttachmentFallback.remoteUpload,
              ),
            ]),
            capabilities: const AcpPromptCapabilities(),
            uploader: uploader,
            cancellationToken: token,
            onUploadProgress: (progress) {
              if (progress.bytesTransferred > 0) token.cancel();
            },
          ),
          throwsA(
            isA<AcpAttachmentException>().having(
              (error) => error.failure,
              'failure',
              AcpAttachmentFailure.cancelled,
            ),
          ),
        );
        expect(sourceClosed, isTrue);
        verify(
          () => sftp.remove(
            '/home/demo/.cache/monkeyssh/uploads/'
            'acp-1783814400000-pipelinecancel-file.bin',
          ),
        ).called(1);
      },
    );

    test('cleans a partial file when SFTP upload fails', () async {
      when(
        () => remoteFileService.uploadStream(
          sftp: sftp,
          remotePath: any(named: 'remotePath'),
          stream: any(named: 'stream'),
          applyPrivateMode: any(named: 'applyPrivateMode'),
        ),
      ).thenThrow(StateError('write failed'));
      final uploader = SftpAcpAttachmentUploader(
        sftp: sftp,
        remoteFileService: remoteFileService,
        now: () => DateTime.utc(2026, 7, 12),
        uniqueId: () => 'failure',
      );

      await expectLater(
        uploader.upload(
          originalName: 'file.bin',
          mimeType: 'application/octet-stream',
          stream: Stream<List<int>>.value(<int>[1, 2]),
          totalBytes: 2,
          maxBytes: 10,
          attachmentIndex: 0,
          attachmentCount: 1,
          cancellationToken: AcpAttachmentCancellationToken(),
        ),
        throwsA(
          isA<AcpAttachmentException>().having(
            (error) => error.failure,
            'failure',
            AcpAttachmentFailure.uploadFailed,
          ),
        ),
      );
      verify(
        () => sftp.remove(
          '/home/demo/.cache/monkeyssh/uploads/'
          'acp-1783814400000-failure-file.bin',
        ),
      ).called(1);
    });
  });

  group('attachment models', () {
    test(
      'defensively copies bytes and does not expose content in toString',
      () {
        final source = Uint8List.fromList(<int>[1, 2, 3]);
        final candidate =
            AcpAttachmentCandidate.memory(
                  name: 'private.txt',
                  bytes: source,
                  mimeType: 'text/plain',
                )
                as AcpMemoryAttachmentCandidate;
        source[0] = 9;

        expect(candidate.bytes, <int>[1, 2, 3]);
        expect(() => candidate.bytes[0] = 8, throwsA(isA<UnsupportedError>()));
        expect(candidate.toString(), isNot(contains('private.txt')));
        expect(candidate.toString(), isNot(contains('1, 2, 3')));
      },
    );
  });
}

const _pngHeader = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13];
