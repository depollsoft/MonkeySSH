import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../domain/services/terminal_scrollback_search.dart';
import '../../domain/services/terminal_scrollback_text.dart';
import 'monkey_terminal_view.dart';

/// State of a terminal scrollback search.
enum TerminalSearchStatus {
  /// The query is empty.
  idle,

  /// A search is running. Results from the previous search stay visible.
  searching,

  /// The last search finished; see [TerminalScrollbackSearchController.matchCount].
  ready,

  /// The regular expression does not compile.
  invalidPattern,

  /// The regular expression ran past its time budget and was stopped.
  tooSlow,

  /// The regular-expression worker could not run.
  failed,
}

/// One search match: a range of a hard line's text.
@immutable
class TerminalSearchMatch {
  /// Creates a match of `[start, end)` in [line].
  const TerminalSearchMatch(this.line, this.start, this.end);

  /// The hard line the match is in.
  final TerminalTextLine line;

  /// UTF-16 offset of the match in [TerminalTextLine.text].
  final int start;

  /// UTF-16 offset just past the match.
  final int end;

  /// The buffer row the match starts on.
  BufferLine get startRow => line.rows[line.rowIndexForOffset(start)];

  /// Offset of the match within the text of [startRow].
  int get startOffsetInRow =>
      start - line.rowStarts[line.rowIndexForOffset(start)];
}

class _RowHits {
  _RowHits(this.line, this.rowIndex);

  final TerminalTextLine line;
  final int rowIndex;
  final matchIndices = <int>[];
  List<TerminalSearchHitSpan>? spans;
  int spansStamp = -1;
  int spansCurrent = -1;
}

/// Finds text in a terminal's buffer, scrollback included, and supplies the
/// hits for the terminal view to paint.
///
/// Behaviour:
/// - A match may run across soft-wrapped rows (one long line the terminal
///   wrapped) and is highlighted on each row it covers. It never crosses a hard
///   line break.
/// - Matches are tied to buffer rows, not row numbers. When new output evicts
///   a row from the 10,000-row scrollback, its matches stop painting, are
///   skipped by next and previous, and leave the count on the next refresh.
/// - A full-screen app on the alternate screen has no scrollback, so only the
///   visible screen is searched; [searchesAlternateScreen] reports this. The
///   main buffer is searched again once the app exits.
/// - While the query is set, new output refreshes the results after
///   [refreshDelay], keeping the current match where possible.
/// - Literal queries are matched on the UI isolate in slices that yield to the
///   event loop between frames. Regular expressions run on a worker isolate
///   that is killed after [regexBudget].
class TerminalScrollbackSearchController extends ChangeNotifier
    implements TerminalSearchHitSource {
  /// Creates a search over [terminal].
  ///
  /// [anchorRow] returns the buffer row the user is looking at (the bottom of
  /// the viewport). A new search starts from the last match at or above it.
  TerminalScrollbackSearchController({
    required Terminal terminal,
    this.anchorRow,
    this.typingDebounce = const Duration(milliseconds: 120),
    this.refreshDelay = const Duration(milliseconds: 500),
    this.regexBudget = kTerminalRegexSearchBudget,
    this.maxMatches = kTerminalSearchMaxMatches,
    this.sliceBudget = kTerminalTextSliceBudget,
  }) : _terminal = terminal,
       _wasUsingAltBuffer = terminal.isUsingAltBuffer {
    _terminal.addListener(_handleTerminalChanged);
  }

  /// Returns the buffer row at the bottom of the viewport, if known.
  final int? Function()? anchorRow;

  /// Delay after the last query edit before searching.
  final Duration typingDebounce;

  /// Delay after new output before the results refresh.
  final Duration refreshDelay;

  /// Time budget for a regular-expression search.
  final Duration regexBudget;

  /// Most matches reported.
  final int maxMatches;

  /// Work per slice before a literal search yields to the event loop.
  final Duration sliceBudget;

  Terminal _terminal;
  bool _wasUsingAltBuffer;
  bool _disposed = false;

  String _query = '';
  bool _caseSensitive = false;
  bool _regex = false;
  TerminalSearchStatus _status = TerminalSearchStatus.idle;
  bool _searchesAlternateScreen = false;

  List<TerminalSearchMatch> _matches = const <TerminalSearchMatch>[];
  bool _capped = false;
  int _currentIndex = -1;
  HashMap<BufferLine, _RowHits> _rowHits = HashMap.identity();
  int _terminalChangeStamp = 0;
  int _revealRequest = 0;
  int _userUpdateCount = 0;

  int _generation = 0;
  bool _running = false;
  bool _refreshPending = false;
  Timer? _debounceTimer;
  Timer? _refreshTimer;
  Completer<void>? _regexCancel;

  /// The terminal being searched.
  Terminal get terminal => _terminal;

  /// Points the search at [value], for example after the screen swaps in a
  /// session's terminal, and searches it again.
  set terminal(Terminal value) {
    if (identical(value, _terminal)) {
      return;
    }
    _terminal.removeListener(_handleTerminalChanged);
    _terminal = value;
    _wasUsingAltBuffer = value.isUsingAltBuffer;
    value.addListener(_handleTerminalChanged);
    _scheduleSearch(Duration.zero, reveal: true);
  }

  /// The current query.
  String get query => _query;

  /// Whether letter case must match.
  bool get caseSensitive => _caseSensitive;

  /// Whether the query is a regular expression.
  bool get regex => _regex;

  /// Current state of the search.
  TerminalSearchStatus get status => _status;

  /// Whether the last search ran on the alternate screen, which has no
  /// scrollback, so only the visible screen was searched.
  bool get searchesAlternateScreen => _searchesAlternateScreen;

  /// Number of matches found, up to [maxMatches].
  int get matchCount => _matches.length;

  /// Whether the search stopped at [maxMatches].
  bool get isCapped => _capped;

  /// Index of the current match, oldest first, or null when there is none.
  int? get currentIndex => _currentIndex < 0 ? null : _currentIndex;

  /// The matches found, oldest first.
  List<TerminalSearchMatch> get matches => _matches;

  /// Bumped whenever the view should scroll to the current match: after a new
  /// search or a step, but not after a refresh for new output.
  int get revealRequest => _revealRequest;

  /// Bumped when the results or the current match change because of the user
  /// (a new query or option, or a step) rather than new output, so the bar
  /// can announce those changes and stay quiet for the rest.
  int get userUpdateCount => _userUpdateCount;

  /// Buffer row index where the current match starts, or null when there is
  /// no current match or its row has been evicted.
  int? get currentMatchRow {
    if (_currentIndex < 0) {
      return null;
    }
    final row = _matches[_currentIndex].startRow;
    return row.attached ? row.index : null;
  }

  /// Sets the query and searches after [typingDebounce].
  void setQuery(String value) {
    if (value == _query) {
      return;
    }
    _query = value;
    _scheduleSearch(typingDebounce, reveal: true);
  }

  /// Sets whether letter case must match, and searches again.
  void setCaseSensitive({required bool value}) {
    if (value == _caseSensitive) {
      return;
    }
    _caseSensitive = value;
    _scheduleSearch(Duration.zero, reveal: true);
  }

  /// Sets whether the query is a regular expression, and searches again.
  void setRegex({required bool value}) {
    if (value == _regex) {
      return;
    }
    _regex = value;
    _scheduleSearch(Duration.zero, reveal: true);
  }

  /// Steps to the next newer match (down), wrapping to the oldest.
  void showNext() => _step(1);

  /// Steps to the next older match (up), wrapping to the newest.
  void showPrevious() => _step(-1);

  void _step(int direction) {
    final count = _matches.length;
    if (count == 0) {
      return;
    }
    var index = _currentIndex < 0
        ? (direction > 0 ? 0 : count - 1)
        : _currentIndex + direction;
    for (var tries = 0; tries < count; tries++) {
      index = (index + count) % count;
      if (_matches[index].startRow.attached) {
        _currentIndex = index;
        _revealRequest++;
        _userUpdateCount++;
        notifyListeners();
        return;
      }
      index += direction;
    }
  }

  @override
  List<TerminalSearchHitSpan> hitsForRow(BufferLine row) {
    final entry = _rowHits[row];
    if (entry == null) {
      return const <TerminalSearchHitSpan>[];
    }
    final cached = entry.spans;
    if (cached != null &&
        entry.spansStamp == _terminalChangeStamp &&
        entry.spansCurrent == _currentIndex) {
      return cached;
    }
    final spans = _computeSpans(row, entry);
    entry
      ..spans = spans
      ..spansStamp = _terminalChangeStamp
      ..spansCurrent = _currentIndex;
    return spans;
  }

  List<TerminalSearchHitSpan> _computeSpans(BufferLine row, _RowHits entry) {
    final line = entry.line;
    final rowStart = line.rowStarts[entry.rowIndex];
    final rowEnd = line.rowEnd(entry.rowIndex);
    final current = terminalRowTextWithColumns(row);
    // The row changed after it was searched, so the match offsets no longer
    // describe its cells. Paint nothing until the next refresh.
    if (current.text.length != rowEnd - rowStart ||
        !line.text.startsWith(current.text, rowStart)) {
      return const <TerminalSearchHitSpan>[];
    }
    final spans = <TerminalSearchHitSpan>[];
    for (final matchIndex in entry.matchIndices) {
      final match = _matches[matchIndex];
      final start = math.max(match.start, rowStart) - rowStart;
      final end = math.min(match.end, rowEnd) - rowStart;
      if (end <= start) {
        continue;
      }
      spans.add((
        startColumn: current.columns[start],
        endColumn: terminalCellEndColumn(row, current.columns[end - 1]),
        isCurrent: matchIndex == _currentIndex,
      ));
    }
    return spans;
  }

  void _handleTerminalChanged() {
    _terminalChangeStamp++;
    final usingAltBuffer = _terminal.isUsingAltBuffer;
    if (usingAltBuffer != _wasUsingAltBuffer) {
      _wasUsingAltBuffer = usingAltBuffer;
      _scheduleSearch(Duration.zero, reveal: true);
      return;
    }
    // Errors wait for the user to change the query: a pattern that timed out
    // would only time out again on every refresh.
    if (_query.isEmpty ||
        (_status != TerminalSearchStatus.ready &&
            _status != TerminalSearchStatus.searching)) {
      return;
    }
    if (_running) {
      _refreshPending = true;
      return;
    }
    if (_debounceTimer?.isActive ?? false) {
      return;
    }
    _refreshTimer ??= Timer(refreshDelay, () {
      _refreshTimer = null;
      unawaited(_search(reveal: false));
    });
  }

  void _scheduleSearch(Duration delay, {required bool reveal}) {
    _cancelInFlight();
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () => unawaited(_search(reveal: reveal)));
  }

  void _cancelInFlight() {
    // A cancelled run stops at its next slice and leaves this state alone,
    // since its generation is no longer current.
    _generation++;
    _running = false;
    _refreshPending = false;
    final cancel = _regexCancel;
    _regexCancel = null;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete();
    }
  }

  Future<void> _search({required bool reveal}) async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    bool isStale() => _disposed || generation != _generation;
    final query = _query;
    if (query.isEmpty) {
      _applyResults(
        const <TerminalSearchMatch>[],
        capped: false,
        status: TerminalSearchStatus.idle,
        reveal: false,
      );
      return;
    }
    final RegExp pattern;
    try {
      pattern = buildTerminalSearchPattern(
        query,
        caseSensitive: _caseSensitive,
        regex: _regex,
      );
    } on FormatException {
      _applyResults(
        const <TerminalSearchMatch>[],
        capped: false,
        status: TerminalSearchStatus.invalidPattern,
        reveal: false,
      );
      return;
    }

    _running = true;
    if (_status != TerminalSearchStatus.searching) {
      _status = TerminalSearchStatus.searching;
      notifyListeners();
    }
    try {
      final usingAltBuffer = _terminal.isUsingAltBuffer;
      final lines = await readTerminalTextLines(
        _terminal.buffer,
        isCancelled: isStale,
        sliceBudget: sliceBudget,
      );
      if (lines == null || isStale()) {
        return;
      }
      _searchesAlternateScreen = usingAltBuffer;

      TerminalTextMatches? found;
      var status = TerminalSearchStatus.ready;
      if (_regex) {
        final cancel = Completer<void>();
        _regexCancel = cancel;
        final result = await findTerminalRegexMatches(
          [for (final line in lines) line.text],
          query,
          caseSensitive: _caseSensitive,
          maxMatches: maxMatches,
          budget: regexBudget,
          cancel: cancel.future,
        );
        if (identical(_regexCancel, cancel)) {
          _regexCancel = null;
        }
        if (isStale()) {
          return;
        }
        switch (result.outcome) {
          case TerminalRegexSearchOutcome.completed:
            found = result.matches;
          case TerminalRegexSearchOutcome.timedOut:
            status = TerminalSearchStatus.tooSlow;
          case TerminalRegexSearchOutcome.failed:
            status = TerminalSearchStatus.failed;
          case TerminalRegexSearchOutcome.cancelled:
            return;
        }
      } else {
        found = await findTerminalLiteralMatches(
          lines,
          pattern,
          maxMatches: maxMatches,
          isCancelled: isStale,
          sliceBudget: sliceBudget,
        );
        if (found == null || isStale()) {
          return;
        }
      }

      _applyResults(
        [
          for (final match in found?.matches ?? const <TerminalTextMatch>[])
            TerminalSearchMatch(lines[match.line], match.start, match.end),
        ],
        capped: found?.capped ?? false,
        status: status,
        reveal: reveal,
      );
    } finally {
      if (generation == _generation) {
        _running = false;
        if (_refreshPending && !_disposed) {
          _refreshPending = false;
          _refreshTimer ??= Timer(refreshDelay, () {
            _refreshTimer = null;
            unawaited(_search(reveal: false));
          });
        }
      }
    }
  }

  void _applyResults(
    List<TerminalSearchMatch> matches, {
    required bool capped,
    required TerminalSearchStatus status,
    required bool reveal,
  }) {
    if (_disposed) {
      return;
    }
    final previous = _currentIndex < 0 ? null : _matches[_currentIndex];
    final rowHits = HashMap<BufferLine, _RowHits>.identity();
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final line = match.line;
      final firstRow = line.rowIndexForOffset(match.start);
      final lastRow = line.rowIndexForOffset(match.end - 1);
      for (var rowIndex = firstRow; rowIndex <= lastRow; rowIndex++) {
        rowHits
            .putIfAbsent(line.rows[rowIndex], () => _RowHits(line, rowIndex))
            .matchIndices
            .add(index);
      }
    }
    _matches = matches;
    _capped = capped;
    _rowHits = rowHits;
    _status = status;
    _currentIndex = reveal
        ? _indexNearAnchor(previous)
        : _indexKeeping(previous);
    if (reveal) {
      _userUpdateCount++;
      if (_currentIndex >= 0) {
        _revealRequest++;
      }
    }
    notifyListeners();
  }

  // After new output, keep the same match current if it is still there,
  // otherwise the nearest match at or above its row.
  int _indexKeeping(TerminalSearchMatch? previous) {
    if (_matches.isEmpty) {
      return -1;
    }
    if (previous == null) {
      return _indexNearAnchor(null);
    }
    final previousRow = previous.startRow;
    final previousOffset = previous.startOffsetInRow;
    for (var index = 0; index < _matches.length; index++) {
      final match = _matches[index];
      if (identical(match.startRow, previousRow) &&
          match.startOffsetInRow == previousOffset) {
        return index;
      }
    }
    return _indexNearAnchor(previous);
  }

  // The last match at or above the anchor: the previous current match while
  // the query is being refined, otherwise the bottom of the viewport. Falls
  // back to the first match below it.
  int _indexNearAnchor(TerminalSearchMatch? previous) {
    if (_matches.isEmpty) {
      return -1;
    }
    final previousRow = previous?.startRow;
    final int anchorRowIndex;
    final int anchorColumn;
    if (previousRow != null && previousRow.attached) {
      anchorRowIndex = previousRow.index;
      anchorColumn = previous!.startOffsetInRow;
    } else {
      anchorRowIndex =
          anchorRow?.call() ?? math.max(0, _terminal.buffer.lines.length - 1);
      anchorColumn = 1 << 30;
    }
    var best = -1;
    var firstAttached = -1;
    for (var index = 0; index < _matches.length; index++) {
      final match = _matches[index];
      final row = match.startRow;
      if (!row.attached) {
        continue;
      }
      if (firstAttached < 0) {
        firstAttached = index;
      }
      final rowIndex = row.index;
      if (rowIndex < anchorRowIndex ||
          (rowIndex == anchorRowIndex &&
              match.startOffsetInRow <= anchorColumn)) {
        best = index;
      } else {
        break;
      }
    }
    return best >= 0 ? best : firstAttached;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelInFlight();
    _debounceTimer?.cancel();
    _refreshTimer?.cancel();
    _terminal.removeListener(_handleTerminalChanged);
    super.dispose();
  }
}

/// Scroll offset that brings buffer row [row] into view, or null when it is
/// already comfortably visible.
///
/// A row counts as visible when it sits inside the viewport and above
/// [obscuredBottom], the part covered by the search bar. Otherwise it is
/// placed about a third of the way down, which leaves context above it.
double? resolveTerminalSearchRevealOffset({
  required int row,
  required double lineHeight,
  required double viewportExtent,
  required double currentOffset,
  required double minScrollExtent,
  required double maxScrollExtent,
  double obscuredBottom = 0,
}) {
  if (!lineHeight.isFinite || lineHeight <= 0) {
    return null;
  }
  final rowTop = row * lineHeight;
  final rowBottom = rowTop + lineHeight;
  final visibleBottom =
      currentOffset + math.max(lineHeight, viewportExtent - obscuredBottom);
  if (rowTop >= currentOffset && rowBottom <= visibleBottom) {
    return null;
  }
  final target = (rowTop - (viewportExtent - obscuredBottom) / 3).clamp(
    minScrollExtent,
    maxScrollExtent,
  );
  return target == currentOffset ? null : target;
}

/// Buffer row at the bottom of the viewport of [controller], or null when it
/// has no position yet.
int? terminalViewportBottomRow(
  ScrollController controller, {
  required double lineHeight,
}) {
  if (!controller.hasClients || !lineHeight.isFinite || lineHeight <= 0) {
    return null;
  }
  final position = controller.position;
  return math.max(
    0,
    ((position.pixels + position.viewportDimension) / lineHeight).floor() - 1,
  );
}
