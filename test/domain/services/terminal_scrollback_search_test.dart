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
      ))!;
      expect(found.matches, [(line: 2, start: 15, end: 20)]);
    });

    test('stops at the match limit', () async {
      final found = (await findTerminalLiteralMatches(
        [_line('aaaaaa')],
        buildTerminalSearchPattern('a', caseSensitive: false, regex: false),
        maxMatches: 4,
      ))!;
      expect(found.matches, hasLength(4));
      expect(found.capped, isTrue);
    });

    test('returns null once cancelled', () async {
      final found = await findTerminalLiteralMatches(
        lines,
        buildTerminalSearchPattern('e', caseSensitive: false, regex: false),
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
