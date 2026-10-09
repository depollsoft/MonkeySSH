import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'terminal_scrollback_text.dart';

/// Most matches a search reports. Past this the count reads as "5000+".
const kTerminalSearchMaxMatches = 5000;

/// Longest a regular-expression search may run before it is abandoned.
const kTerminalRegexSearchBudget = Duration(seconds: 2);

/// One match in a list of [TerminalTextLine]s: the line's index in that list
/// and the UTF-16 range of the match in the line's text.
typedef TerminalTextMatch = ({int line, int start, int end});

/// Matches found by a search, in line order.
typedef TerminalTextMatches = ({List<TerminalTextMatch> matches, bool capped});

/// Builds the pattern for a search.
///
/// A literal [query] is escaped, which leaves a plain character sequence: it
/// cannot backtrack, so it is safe to run on the UI isolate. A [regex] query
/// is compiled as written; this throws [FormatException] for invalid syntax.
/// Compiling only parses the pattern, so it cannot hang.
RegExp buildTerminalSearchPattern(
  String query, {
  required bool caseSensitive,
  required bool regex,
}) =>
    RegExp(regex ? query : RegExp.escape(query), caseSensitive: caseSensitive);

bool _neverCancelled() => false;

/// Finds a literal pattern in [lines] on the calling isolate, yielding to the
/// event loop between slices of work. Returns null if [isCancelled] reports
/// true between slices.
///
/// Only call this with a pattern from [buildTerminalSearchPattern] with
/// `regex: false`. A user regex can backtrack catastrophically and a Dart
/// [RegExp] match cannot be interrupted; use [findTerminalRegexMatches].
///
/// Matches never span hard lines. Zero-length matches are skipped.
Future<TerminalTextMatches?> findTerminalLiteralMatches(
  List<TerminalTextLine> lines,
  RegExp literalPattern, {
  int maxMatches = kTerminalSearchMaxMatches,
  bool Function() isCancelled = _neverCancelled,
  Duration sliceBudget = kTerminalTextSliceBudget,
}) async {
  final slicer = TerminalWorkSlicer(budget: sliceBudget);
  final matches = <TerminalTextMatch>[];
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (!await slicer.maybeYield(isCancelled)) {
      return null;
    }
    final text = lines[lineIndex].text;
    if (text.isEmpty) {
      continue;
    }
    for (final match in literalPattern.allMatches(text)) {
      if (match.end == match.start) {
        continue;
      }
      if (matches.length == maxMatches) {
        return (matches: matches, capped: true);
      }
      matches.add((line: lineIndex, start: match.start, end: match.end));
    }
  }
  return (matches: matches, capped: false);
}

/// How a regular-expression search ended.
enum TerminalRegexSearchOutcome {
  /// The search ran to the end, or to the match limit.
  completed,

  /// The search ran past its time budget and was stopped.
  timedOut,

  /// The search was cancelled by the caller.
  cancelled,

  /// The worker could not start or failed.
  failed,
}

/// Result of [findTerminalRegexMatches].
typedef TerminalRegexSearchResult = ({
  TerminalRegexSearchOutcome outcome,
  TerminalTextMatches? matches,
});

/// Finds [pattern] in [lines] on a separate isolate.
///
/// A user pattern can backtrack catastrophically (`(a+)+$` against a long run
/// of `a`s runs for minutes), and a Dart [RegExp] cannot be interrupted except
/// by killing its isolate. The worker is therefore killed when [budget]
/// elapses or [cancel] completes, whichever comes first.
///
/// Each line is matched on its own, so matches never span hard lines and `^`
/// and `$` anchor to line boundaries. Zero-length matches are skipped.
Future<TerminalRegexSearchResult> findTerminalRegexMatches(
  List<String> lines,
  String pattern, {
  required bool caseSensitive,
  int maxMatches = kTerminalSearchMaxMatches,
  Duration budget = kTerminalRegexSearchBudget,
  Future<void>? cancel,
}) async {
  final replies = ReceivePort();
  final reply = Completer<Object?>();
  final timedOut = Object();
  final cancelled = Object();
  replies.listen((message) {
    if (!reply.isCompleted) {
      reply.complete(message);
    }
  });
  final timer = Timer(budget, () {
    if (!reply.isCompleted) {
      reply.complete(timedOut);
    }
  });
  unawaited(
    cancel?.then((_) {
      if (!reply.isCompleted) {
        reply.complete(cancelled);
      }
    }),
  );
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _findRegexMatches,
      (replies.sendPort, lines, pattern, caseSensitive, maxMatches),
      // A crashed worker exits with `null`, which reads as a failure.
      onExit: replies.sendPort,
    );
    final message = await reply.future;
    if (identical(message, timedOut)) {
      return (outcome: TerminalRegexSearchOutcome.timedOut, matches: null);
    }
    if (identical(message, cancelled)) {
      return (outcome: TerminalRegexSearchOutcome.cancelled, matches: null);
    }
    if (message is! Int32List) {
      return (outcome: TerminalRegexSearchOutcome.failed, matches: null);
    }
    return (
      outcome: TerminalRegexSearchOutcome.completed,
      matches: _decodeMatches(message),
    );
  } on Object {
    return (outcome: TerminalRegexSearchOutcome.failed, matches: null);
  } finally {
    timer.cancel();
    isolate?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

// The worker replies with a flat list: a capped flag, then a
// (line, start, end) triple per match.
TerminalTextMatches _decodeMatches(Int32List encoded) {
  final matches = <TerminalTextMatch>[
    for (var index = 1; index + 2 < encoded.length; index += 3)
      (
        line: encoded[index],
        start: encoded[index + 1],
        end: encoded[index + 2],
      ),
  ];
  return (matches: matches, capped: encoded.isNotEmpty && encoded[0] != 0);
}

void _findRegexMatches((SendPort, List<String>, String, bool, int) message) {
  final (replies, lines, pattern, caseSensitive, maxMatches) = message;
  final regex = RegExp(pattern, caseSensitive: caseSensitive);
  final encoded = <int>[0];
  var count = 0;
  search:
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final text = lines[lineIndex];
    for (final match in regex.allMatches(text)) {
      if (match.end == match.start) {
        continue;
      }
      if (count == maxMatches) {
        encoded[0] = 1;
        break search;
      }
      encoded
        ..add(lineIndex)
        ..add(match.start)
        ..add(match.end);
      count++;
    }
  }
  Isolate.exit(replies, Int32List.fromList(encoded));
}
