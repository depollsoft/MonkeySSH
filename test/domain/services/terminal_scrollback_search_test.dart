import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_scrollback_search.dart';
import 'package:monkeyssh/domain/services/terminal_scrollback_text.dart';
import 'package:xterm/xterm.dart';

TerminalTextLine _line(String text) => TerminalTextLine(
  rows: <BufferLine>[BufferLine(text.length)],
  rowStarts: const <int>[0],
  text: text,
);

void main() {
  group('buildTerminalSearchPattern', () {
    test('escapes literal queries', () {
      final pattern = buildTerminalSearchPattern(
        'a.b(',
        caseSensitive: true,
        regex: false,
      );
      expect(pattern.hasMatch('xa.b(y'), isTrue);
      expect(pattern.hasMatch('axb('), isFalse);
    });

    test('rejects an invalid regular expression', () {
      expect(
        () => buildTerminalSearchPattern(
          'a(b',
          caseSensitive: false,
          regex: true,
        ),
        throwsFormatException,
      );
    });
  });

  group('findTerminalLiteralMatches', () {
    final lines = [
      _line('Error: disk full'),
      _line(''),
      _line('no error here, ERROR there'),
    ];

    test('matches case-insensitively by default', () async {
      final found = (await findTerminalLiteralMatches(
        lines,
        buildTerminalSearchPattern('error', caseSensitive: false, regex: false),
        literalLength: 5,
      ))!;
      expect(found.capped, isFalse);
      expect(found.matches, [
        (line: 0, start: 0, end: 5),
        (line: 2, start: 3, end: 8),
        (line: 2, start: 15, end: 20),
      ]);
    });

    test('honours the case toggle', () async {
      final found = (await findTerminalLiteralMatches(
        lines,
        buildTerminalSearchPattern('ERROR', caseSensitive: true, regex: false),
        literalLength: 5,
      ))!;
      expect(found.matches, [(line: 2, start: 15, end: 20)]);
    });

    test('stops at the match limit', () async {
      final found = (await findTerminalLiteralMatches(
        [_line('aaaaaa')],
        buildTerminalSearchPattern('a', caseSensitive: false, regex: false),
        literalLength: 1,
        anchorLine: 0,
        maxMatches: 4,
      ))!;
      expect(found.matches, hasLength(4));
      expect(found.capped, isTrue);
    });

    test('keeps the capped matches around the anchor', () async {
      final many = [for (var index = 0; index < 20; index++) _line('hit')];
      final pattern = buildTerminalSearchPattern(
        'hit',
        caseSensitive: false,
        regex: false,
      );
      final nearEnd = (await findTerminalLiteralMatches(
        many,
        pattern,
        literalLength: 3,
        anchorLine: 18,
        maxMatches: 4,
      ))!;
      expect(nearEnd.matches.map((match) => match.line), [16, 17, 18, 19]);
      expect(nearEnd.capped, isTrue);

      final middle = (await findTerminalLiteralMatches(
        many,
        pattern,
        literalLength: 3,
        anchorLine: 10,
        maxMatches: 4,
      ))!;
      expect(middle.matches.map((match) => match.line), [8, 9, 10, 11]);
    });

    test(
      'scans a long line in chunks and keeps matches across chunk edges',
      () async {
        const chunk = 16;
        // `NEEDLE` straddles the first chunk edge, `needle` sits in the fourth
        // chunk, and `needleneedle` must not overlap itself.
        final text = '${'a' * 14}NEEDLE${'b' * 30}needle${'c' * 6}needleneedle';
        var checks = 0;
        final found = (await findTerminalLiteralMatches(
          [_line(text)],
          buildTerminalSearchPattern(
            'needle',
            caseSensitive: false,
            regex: false,
          ),
          literalLength: 6,
          scanChunk: chunk,
          sliceBudget: Duration.zero,
          isCancelled: () {
            checks++;
            return false;
          },
        ))!;
        expect(found.matches, [
          (line: 0, start: 14, end: 20),
          (line: 0, start: 50, end: 56),
          (line: 0, start: 62, end: 68),
          (line: 0, start: 68, end: 74),
        ]);
        // Once for the line and once per further chunk.
        expect(checks, (text.length / chunk).ceil());
      },
    );

    test(
      'chunked scan matches a self-overlapping query like one pass',
      () async {
        final pattern = buildTerminalSearchPattern(
          'aaa',
          caseSensitive: true,
          regex: false,
        );
        for (final text in ['a' * 20, '${'x' * 13}${'a' * 12}']) {
          final whole = (await findTerminalLiteralMatches(
            [_line(text)],
            pattern,
            literalLength: 3,
          ))!;
          final chunked = (await findTerminalLiteralMatches(
            [_line(text)],
            pattern,
            literalLength: 3,
            scanChunk: 8,
          ))!;
          expect(chunked.matches, whole.matches, reason: text);
        }
      },
    );

    test('centres the cap on a position inside one long line', () async {
      final text = 'hit ' * 20;
      final pattern = buildTerminalSearchPattern(
        'hit',
        caseSensitive: false,
        regex: false,
      );
      final literal = (await findTerminalLiteralMatches(
        [_line(text)],
        pattern,
        literalLength: 3,
        anchorLine: 0,
        anchorOffset: 70,
        maxMatches: 4,
      ))!;
      expect(literal.matches.map((match) => match.start), [64, 68, 72, 76]);

      final regex = await findTerminalRegexMatches(
        [text],
        'hit',
        caseSensitive: false,
        anchorLine: 0,
        anchorOffset: 70,
        maxMatches: 4,
      );
      expect(regex.matches!.matches.map((match) => match.start), [
        64,
        68,
        72,
        76,
      ]);
    });

    test('returns null once cancelled', () async {
      final found = await findTerminalLiteralMatches(
        lines,
        buildTerminalSearchPattern('e', caseSensitive: false, regex: false),
        literalLength: 1,
        sliceBudget: Duration.zero,
        isCancelled: () => true,
      );
      expect(found, isNull);
    });
  });

  group('findTerminalRegexMatches', () {
    test('matches each line on its own and skips empty matches', () async {
      final result = await findTerminalRegexMatches(
        ['build 12 ok', 'took 340ms', '', 'no digits'],
        r'\d*',
        caseSensitive: false,
      );
      expect(result.outcome, TerminalRegexSearchOutcome.completed);
      expect(result.matches!.matches, [
        (line: 0, start: 6, end: 8),
        (line: 1, start: 5, end: 8),
      ]);
    });

    test('anchors to line boundaries and reports the cap', () async {
      final result = await findTerminalRegexMatches(
        ['ok one', 'fail two', 'ok three', 'ok four'],
        '^ok',
        caseSensitive: true,
        anchorLine: 0,
        maxMatches: 2,
      );
      expect(result.outcome, TerminalRegexSearchOutcome.completed);
      expect(result.matches!.matches, [
        (line: 0, start: 0, end: 2),
        (line: 2, start: 0, end: 2),
      ]);
      expect(result.matches!.capped, isTrue);
    });

    test('kills a catastrophically backtracking pattern', () async {
      final stopwatch = Stopwatch()..start();
      final result = await findTerminalRegexMatches(
        ['${'a' * 40}!'],
        r'^(a+)+$',
        caseSensitive: true,
        budget: const Duration(milliseconds: 300),
      );
      expect(result.outcome, TerminalRegexSearchOutcome.timedOut);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('stops when cancelled', () async {
      final cancel = Completer<void>();
      final pending = findTerminalRegexMatches(
        ['${'a' * 40}!'],
        r'^(a+)+$',
        caseSensitive: true,
        budget: const Duration(seconds: 30),
        cancel: cancel.future,
      );
      cancel.complete();
      expect((await pending).outcome, TerminalRegexSearchOutcome.cancelled);
    });
  });
}
