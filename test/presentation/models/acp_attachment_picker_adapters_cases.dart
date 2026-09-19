import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/presentation/models/acp_attachment_picker_adapters.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

void registerAcpAttachmentPickerAdaptersTests() {
  group('acp_attachment_picker_adapters', () {
    test('adapts PlatformFile bytes into an in-memory candidate', () async {
      final candidate = await acpAttachmentCandidateFromPlatformFile(
        AppPlatformFile(
          name: 'notes.txt',
          size: 5,
          bytes: Uint8List.fromList(<int>[104, 101, 108, 108, 111]),
        ),
      );

      expect(candidate, isA<AcpMemoryAttachmentCandidate>());
      final memory = candidate as AcpMemoryAttachmentCandidate;
      expect(memory.name, 'notes.txt');
      expect(memory.sizeBytes, 5);
      expect(memory.bytes, 'hello'.codeUnits);
    });

    test('keeps path-backed PlatformFile reads lazy', () async {
      final candidate = await acpAttachmentCandidateFromPlatformFile(
        AppPlatformFile(name: 'notes.txt', path: 'unopened/notes.txt', size: 5),
      );

      expect(candidate, isA<AcpLocalFileAttachmentCandidate>());
      final local = candidate as AcpLocalFileAttachmentCandidate;
      expect(local.name, 'notes.txt');
      expect(local.sizeBytes, 5);
    });

    test('adapts XFile data while preserving MIME type and label', () async {
      final candidate = await acpAttachmentCandidateFromXFile(
        XFile.fromData(
          Uint8List.fromList(<int>[1, 2, 3]),
          name: 'photo.png',
          mimeType: 'image/png',
        ),
        displayName: 'photo.png',
      );

      expect(candidate, isA<AcpLocalFileAttachmentCandidate>());
      final local = candidate as AcpLocalFileAttachmentCandidate;
      expect(local.name, 'photo.png');
      expect(local.mimeType, 'image/png');
      expect(local.sizeBytes, 3);
      expect(await local.openRead().expand((chunk) => chunk).toList(), <int>[
        1,
        2,
        3,
      ]);
    });

    test('maps RemoteFileSelection without reading or downloading', () {
      final candidate = acpAttachmentCandidateFromRemoteFileSelection(
        const RemoteFileSelection(
          remotePath: '/home/demo/report.txt',
          displayName: 'report.txt',
          sizeBytes: 42,
          mimeType: 'text/plain',
        ),
      );

      expect(candidate, isA<AcpRemoteFileAttachmentCandidate>());
      final remote = candidate as AcpRemoteFileAttachmentCandidate;
      expect(remote.remotePath, '/home/demo/report.txt');
      expect(remote.name, 'report.txt');
      expect(remote.sizeBytes, 42);
      expect(remote.mimeType, 'text/plain');
    });
  });
}
