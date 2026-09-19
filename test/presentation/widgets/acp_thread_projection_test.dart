import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_thread_projection.dart';

// A tiny valid 1x1 PNG.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  test('tail projection bounds short history and handles no entries', () {
    final empty = projectAcpThreadWindow([]);
    expect(empty.startEntryIndex, 0);
    expect(empty.children, isEmpty);
    expect(empty.initialVisibleChildren, 0);
    final entries = [
      for (var i = 0; i < 100; i++)
        AcpAssistantMessageEntry(id: '$i', markdown: 'message $i'),
    ];
    final tail = projectAcpThreadWindow(entries);
    expect(tail.startEntryIndex, 52);
    expect(tail.initialVisibleChildren, 48);
    expect(tail.children.map((child) => child.entry), entries.skip(52));
    expect(
      tail.children.map((child) => child.entryIndex),
      List.generate(48, (i) => i + 52),
    );
  });
  test('oversized assistant tail starts at its last virtual segment', () {
    final markdown = List.filled(1200, 'A paragraph of response.\n\n').join();
    final entry = AcpAssistantMessageEntry(id: 'large', markdown: markdown);
    final tail = projectAcpThreadWindow([
      entry,
      const AcpStatusEntry(id: 'done', message: 'done'),
    ]);
    expect(tail.startEntryIndex, 0);
    expect(tail.initialVisibleChildren, 2);
    final chunks = tail.children
        .where((child) => child.entry.id == 'large')
        .toList();
    expect(chunks.length, greaterThan(1));
    expect(chunks.first.keyValue, 'large');
    expect(chunks.last.keyValue, 'large-markdown-part-${chunks.length - 1}');
    expect(chunks.map((child) => child.markdown).join(), markdown);
    expect(chunks.first.isEntryContinuation, isFalse);
    expect(chunks.last.isEntryContinuation, isTrue);
  });

  test('user prompt summary normalizes text and attachment-only prompts', () {
    expect(
      acpUserPromptSummary(
        AcpUserPromptEntry(
          id: 'text',
          parts: const [AcpTextPart('  first\nline  '), AcpTextPart('second')],
        ),
      ),
      'first line second',
    );
    final hugeSummary = acpUserPromptSummary(
      AcpUserPromptEntry(
        id: 'huge-text',
        parts: [AcpTextPart(List.filled(50000, 'diagnostic').join(' '))],
      ),
    );
    expect(hugeSummary, hasLength(240));
    expect(hugeSummary, endsWith('…'));

    expect(
      acpUserPromptSummary(
        AcpUserPromptEntry(
          id: 'attachments',
          parts: [
            AcpImagePart(AcpImageContent(bytes: _pngBytes, label: 'diagram')),
            const AcpResourcePart(
              AcpResourceRef(uri: 'file:///repo/lib/main.dart'),
            ),
          ],
        ),
      ),
      'diagram · main.dart',
    );
  });
}
