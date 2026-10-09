import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'terminal_scrollback_text.dart';

/// Most matches a search reports. Past this the count reads as "5000+".
const kTerminalSearchMaxMatches = 5000;

/// Longest stretch of one hard line a literal search scans before it may
/// yield. A line that wraps across the whole buffer is about 1.2 million
/// characters.
const kTerminalLiteralScanChunk = 32 * 1024;

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

/// Collects matches in line order and keeps at most `maxMatches` of them
/// around `anchorLine`: up to half before it (the newest of those), and the
/// rest at or after it. When one side has fewer, the other side gets the
/// room. A search with too many matches thus still covers the part of the
/// buffer the user is looking at.
class _MatchWindow {
  _MatchWindow(this.maxMatches, this.anchorLine);

  final int maxMatches;
  final int anchorLine;
  final _before = ListQueue<TerminalTextMatch>();
  final _after = <TerminalTextMatch>[];
  var _dropped = false;

  /// Whether the window is full past the anchor, so scanning can stop.
  bool get isComplete => _after.length > maxMatches;

  void add(TerminalTextMatch match) {
    if (match.line < anchorLine) {
      _before.add(match);
      if (_before.length > maxMatches) {
        _before.removeFirst();
        _dropped = true;
      }
    } else if (!isComplete) {
      _after.add(match);
    }
  }

  TerminalTextMatches result() {
    final int keepAfter = math.min(
      _after.length,
      maxMatches - math.min<int>(_before.length, maxMatches ~/ 2),
    );
    final int keepBefore = math.min(_before.length, maxMatches - keepAfter);
    return (
      matches: [
        ..._before.skip(_before.length - keepBefore),
        ..._after.take(keepAfter),
      ],
      capped:
          _dropped || keepBefore < _before.length || keepAfter < _after.length,
    );
  }
}

/// Finds a literal pattern in [lines] on the calling isolate, yielding to the
/// event loop between slices of work. Returns null if [isCancelled] reports
/// true between slices.
///
/// Only call this with a pattern from [buildTerminalSearchPattern] with
/// `regex: false`. A user regex can backtrack catastrophically and a Dart
/// [RegExp] match cannot be interrupted; use [findTerminalRegexMatches].
///
/// A hard line longer than [scanChunk] is scanned in chunks
/// that overlap by [literalLength] - 1 characters, so a single wrapped line
/// filling the buffer cannot block a frame. Matches never span hard lines,
/// never overlap, and zero-length matches are skipped. At most [maxMatches]
/// are kept, centred on [anchorLine] (the last line when null).
Future<TerminalTextMatches?> findTerminalLiteralMatches(
  List<TerminalTextLine> lines,
  RegExp literalPattern, {
  required int literalLength,
  int? anchorLine,
  int maxMatches = kTerminalSearchMaxMatches,
  int scanChunk = kTerminalLiteralScanChunk,
  bool Function() isCancelled = _neverCancelled,
  Duration sliceBudget = kTerminalTextSliceBudget,
}) async {
  final slicer = TerminalWorkSlicer(budget: sliceBudget);
  final window = _MatchWindow(
    maxMatches,
    anchorLine ?? math.max(0, lines.length - 1),
  );
  final overlap = math.max(0, literalLength - 1);
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (!await slicer.maybeYield(isCancelled)) {
      return null;
    }
    final text = lines[lineIndex].text;
    if (text.isEmpty) {
      continue;
    }
    var lastEnd = 0;
    for (
      var chunkStart = 0;
      chunkStart < text.length;
      chunkStart += scanChunk
    ) {
      if (chunkStart > 0 && !await slicer.maybeYield(isCancelled)) {
        return null;
      }
      final chunkEnd = math.min(text.length, chunkStart + scanChunk);
      final scanEnd = math.min(text.length, chunkEnd + overlap);
      final chunk = chunkStart == 0 && scanEnd == text.length
          ? text
          : text.substring(chunkStart, scanEnd);
      for (final match in literalPattern.allMatches(chunk)) {
        final start = chunkStart + match.start;
        final end = chunkStart + match.end;
        if (start >= chunkEnd) {
          break;
        }
        if (end == start || start < lastEnd) {
          continue;
        }
        lastEnd = end;
        window.add((line: lineIndex, start: start, end: end));
      }
      if (window.isComplete) {
        return window.result();
      }
    }
  }
  return window.result();
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
  int? anchorLine,
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
      (
        replies.sendPort,
        lines,
        pattern,
        caseSensitive,
        maxMatches,
        anchorLine ?? math.max(0, lines.length - 1),
      ),
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

void _findRegexMatches(
  (SendPort, List<String>, String, bool, int, int) message,
) {
  final (replies, lines, pattern, caseSensitive, maxMatches, anchorLine) =
      message;
  final regex = RegExp(pattern, caseSensitive: caseSensitive);
  final window = _MatchWindow(maxMatches, anchorLine);
  search:
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    for (final match in regex.allMatches(lines[lineIndex])) {
      if (match.end == match.start) {
        continue;
      }
      window.add((line: lineIndex, start: match.start, end: match.end));
      if (window.isComplete) {
        break search;
      }
    }
  }
  final found = window.result();
  final encoded = <int>[if (found.capped) 1 else 0];
  for (final match in found.matches) {
    encoded
      ..add(match.line)
      ..add(match.start)
      ..add(match.end);
  }
  Isolate.exit(replies, Int32List.fromList(encoded));
}
