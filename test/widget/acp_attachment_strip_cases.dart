// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/widgets/acp_attachment_strip.dart';

Uint8List _png() => Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  ...List<int>.filled(16, 0),
]);

AcpComposerAttachment _attachment({
  required String id,
  required AcpAttachmentCandidate candidate,
  AcpComposerAttachmentStatus status = AcpComposerAttachmentStatus.ready,
  double? progress,
}) => AcpComposerAttachment(
  id: id,
  candidate: candidate,
  status: status,
  progress: progress,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<AcpComposerAttachment> attachments,
  ValueChanged<String>? onRemove,
  ValueChanged<String>? onRetry,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: AcpAttachmentStrip(
        attachments: attachments,
        onRemove: onRemove ?? (_) {},
        onRetry: onRetry ?? (_) {},
      ),
    ),
  ),
);

void registerAcpAttachmentStripTests() {
  group('acp_attachment_strip', () {
    testWidgets('preserves order and renders image thumbnail + remote chip', (
      tester,
    ) async {
      await _pump(
        tester,
        attachments: [
          _attachment(
            id: 'a',
            candidate: AcpAttachmentCandidate.memory(
              name: 'photo.png',
              bytes: _png(),
              mimeType: 'image/png',
            ),
          ),
          _attachment(
            id: 'b',
            candidate: const AcpAttachmentCandidate.remoteFile(
              name: 'log.txt',
              remotePath: '/var/log.txt',
            ),
          ),
        ],
      );

      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('log.txt'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    });

    testWidgets('shows a progress bar while uploading', (tester) async {
      await _pump(
        tester,
        attachments: [
          _attachment(
            id: 'a',
            candidate: AcpAttachmentCandidate.memory(
              name: 'big.bin',
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
            ),
            status: AcpComposerAttachmentStatus.uploading,
            progress: 0.4,
          ),
        ],
      );
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0.4);
    });

    testWidgets('exposes a retry action for failed attachments', (
      tester,
    ) async {
      final retried = <String>[];
      await _pump(
        tester,
        attachments: [
          _attachment(
            id: 'a',
            candidate: AcpAttachmentCandidate.memory(
              name: 'x.bin',
              bytes: Uint8List.fromList(<int>[1]),
            ),
            status: AcpComposerAttachmentStatus.failed,
          ),
        ],
        onRetry: retried.add,
      );
      expect(find.text('Failed — tap retry'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry x.bin'));
      await tester.pump();
      expect(retried, ['a']);
    });
  });
}
