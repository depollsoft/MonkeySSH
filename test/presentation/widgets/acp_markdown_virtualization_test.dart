// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_data_images.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_virtualization.dart';

void main() {
  test('keeps short Markdown as one unchanged segment', () {
    const source = 'A short **response**.';

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks, [source]);
  });

  test('bounds long prose without dropping or reordering content', () {
    final source = List.generate(
      1200,
      (index) => 'Paragraph $index with enough text to exercise segmentation.',
    ).join('\n\n');

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(
      chunks.every((chunk) => chunk.length <= kAcpMarkdownVirtualChunkChars),
      isTrue,
    );
    expect(chunks.join(), source);
  });

  test('normalizes and keeps a wrapped inline data image atomic', () {
    final payload = List.filled(9000, 'A').join();
    final wrappedPayload = payload.replaceAllMapped(
      RegExp('.{1,72}'),
      (match) => '${match.group(0)}\n',
    );
    final source =
        'before\n\n![diagram](data:image/\npng;base64,$wrappedPayload)\n\nafter';

    final chunks = splitAcpMarkdownForVirtualization(source, targetChars: 1024);

    final imageChunks = chunks.where((chunk) => chunk.contains('![diagram]'));
    expect(imageChunks, hasLength(1));
    expect(imageChunks.single.length, greaterThan(1024));
    expect(imageChunks.single, isNot(contains('image/\npng')));
    expect(imageChunks.single, isNot(contains('\nAAAA')));
    expect(chunks.join(), contains('data:image/png;base64,$payload'));
    expect(chunks.join(), startsWith('before'));
    expect(chunks.join(), endsWith('after'));
  });

  test('returns normalized data-image Markdown by identity', () {
    final payload = List.filled(9000, 'A').join();
    final source = '![diagram](data:image/png;base64,$payload)';

    expect(identical(normalizeAcpMarkdownDataImages(source), source), isTrue);
  });

  test('leaves wrapped data-image syntax unchanged inside code fences', () {
    const source =
        '```text\n'
        '![literal](data:image/\npng;base64,AAAA\nBBBB)\n'
        '```\n';

    expect(normalizeAcpMarkdownDataImages(source), source);
  });

  test('bounds long literal text without changing pasted diagnostics', () {
    final source = List.generate(
      1200,
      (index) => 'diagnostic $index: state, timing, and stack details',
    ).join('\n');

    final chunks = splitAcpTextForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(
      chunks.every((chunk) => chunk.length <= kAcpTextVirtualChunkChars),
      isTrue,
    );
    expect(chunks.join(), source);
  });

  for (final (payload, budget) in [
    (
      List.generate(1200, (index) => 'print($index);').join('\n'),
      kAcpMarkdownVirtualChunkChars,
    ),
    ('x' * 9000, kAcpMarkdownVirtualChunkChars),
    ('x' * 25, 32),
    ('🙂' * 12, 1),
    ('🙂' * 12, 9),
    ('x' * 12, 4),
  ]) {
    test('splits fenced line of ${payload.length} units at budget $budget', () {
      final chunks = splitAcpMarkdownForVirtualization(
        '```dart\n$payload\n```${payload.contains('\n') ? '\n' : ''}',
        targetChars: budget,
      );

      expect(chunks.length, greaterThan(1));
      final recovered = StringBuffer();
      for (final chunk in chunks) {
        expect(chunk, startsWith('```dart\n'));
        expect(chunk.trimRight(), endsWith('```'));
        final code = chunk.substring(8, chunk.lastIndexOf('\n```'));
        expect(code, isNotEmpty);
        expect(
          chunk.runes.any((rune) => rune >= 0xD800 && rune <= 0xDFFF),
          isFalse,
        );
        expect(chunk.length, lessThanOrEqualTo(budget + 14));
        recovered.write(code);
      }
      if (!payload.contains('\n')) expect(recovered.toString(), payload);
    });
  }

  test('tiny budgets preserve complete code points in Markdown and text', () {
    const source = '🙂🙂x';
    for (final chunks in [
      splitAcpMarkdownForVirtualization(source, targetChars: 1),
      splitAcpTextForVirtualization(source, targetChars: 1),
    ]) {
      expect(chunks, ['🙂', '🙂', 'x']);
    }
  });

  test('splits one giant line without breaking surrogate pairs', () {
    final source = List.filled(10000, '🙂 word').join(' ');

    final chunks = splitAcpMarkdownForVirtualization(source);

    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), source);
    for (final chunk in chunks) {
      expect(chunk.runes.toList(), isNotEmpty);
    }
  });
}
