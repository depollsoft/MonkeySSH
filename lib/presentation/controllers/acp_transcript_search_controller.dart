/// State behind find-in-transcript for one native agent chat.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/acp_timeline.dart';
import '../models/acp_transcript_search.dart';
import '../widgets/acp_message_thread.dart';

/// Holds the query, matches and active match of a transcript search.
///
/// Searching is debounced while the user types and re-run, more slowly, as
/// new output streams in. A new query starts at the newest match, because a
/// chat is usually read from the bottom; [previous] walks towards older
/// messages. Nothing here logs or persists the query or the transcript.
class AcpTranscriptSearchController extends ChangeNotifier {
  /// Creates a search controller.
  AcpTranscriptSearchController({
    this.queryDebounce = const Duration(milliseconds: 150),
    this.refreshInterval = const Duration(milliseconds: 400),
  });

  /// Delay between the last keystroke and running the search.
  final Duration queryDebounce;

  /// Minimum delay before re-running a search over newly streamed entries.
  final Duration refreshInterval;

  var _open = false;
  var _query = '';
  List<AcpTimelineEntry> _entries = const <AcpTimelineEntry>[];
  AcpTranscriptSearchResult _result = AcpTranscriptSearchResult.empty;
  String? _resultQuery;
  int? _activeIndex;
  var _serial = 0;
  Timer? _queryTimer;
  Timer? _refreshTimer;
  var _index = AcpTranscriptSearchIndex();
  var _focusRequest = 0;
  var _fieldFocused = false;
  var _announcement = 0;
  var _disposed = false;

  /// Whether the search bar is showing.
  bool get isOpen => _open;

  /// The text being searched for.
  String get query => _query;

  /// The latest matches.
  AcpTranscriptSearchResult get result => _result;

  /// Whether [result] reflects the current [query], rather than a search
  /// still waiting for typing to pause. Re-searching streamed output does not
  /// unsettle it.
  bool get isSettled => _queryTimer == null && _resultQuery == _query.trim();

  /// Index of the active match in [result], if any.
  int? get activeIndex => _activeIndex;

  /// The active match, if any.
  AcpTranscriptMatch? get activeMatch {
    final index = _activeIndex;
    final matches = _result.matches;
    return index == null || index < 0 || index >= matches.length
        ? null
        : matches[index];
  }

  /// What the transcript should reveal and highlight, if anything.
  AcpThreadSearchFocus? get focus {
    final match = activeMatch;
    if (!_open || match == null) return null;
    return AcpThreadSearchFocus(
      entryIndex: match.entryIndex,
      childKey: match.childKey,
      entryId: match.entryId,
      serial: _serial,
    );
  }

  /// Grows when the search field should take focus again, for example when
  /// search is opened while it is already showing.
  int get focusRequest => _focusRequest;

  /// Whether the search field has keyboard focus.
  bool get fieldFocused => _fieldFocused;

  set fieldFocused(bool value) {
    if (value == _fieldFocused) return;
    _fieldFocused = value;
    _notify();
  }

  /// Grows when the result should be announced: a new search or a step.
  /// Re-searching streamed output keeps the active match and stays quiet.
  int get announcement => _announcement;

  /// Shows the search bar, or returns focus to its field when it is already
  /// showing.
  void open() {
    if (_open) {
      _focusRequest++;
    }
    _open = true;
    _notify();
  }

  /// Hides the search bar and forgets the query and its matches.
  void close() {
    if (!_open && _query.isEmpty) return;
    _queryTimer?.cancel();
    _queryTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    // Drop the lower-cased copies of the transcript held for searching.
    _index = AcpTranscriptSearchIndex();
    _open = false;
    _fieldFocused = false;
    _query = '';
    _resultQuery = null;
    _result = AcpTranscriptSearchResult.empty;
    _activeIndex = null;
    _notify();
  }

  /// Changes the query; the search runs once typing pauses.
  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    _queryTimer?.cancel();
    _queryTimer = Timer(queryDebounce, () {
      _queryTimer = null;
      _run(resetActive: true);
    });
    _notify();
  }

  /// Supplies the transcript being searched. Safe to call during build: the
  /// search re-runs later, and only while a query is active.
  void updateEntries(List<AcpTimelineEntry> entries) {
    if (identical(entries, _entries)) return;
    _entries = entries;
    if (!_open || _query.trim().isEmpty) return;
    if (_queryTimer != null || _refreshTimer != null) return;
    _refreshTimer = Timer(refreshInterval, () {
      _refreshTimer = null;
      if (_queryTimer == null) _run(resetActive: false);
    });
  }

  /// Runs a search still waiting for typing to pause. Returns whether there
  /// was one.
  bool searchNow() {
    final pending = _queryTimer;
    if (pending == null) return false;
    pending.cancel();
    _queryTimer = null;
    _run(resetActive: true);
    return true;
  }

  /// Moves to the next, newer match, wrapping to the oldest.
  void next() => _step(1);

  /// Moves to the previous, older match, wrapping to the newest.
  void previous() => _step(-1);

  void _step(int delta) {
    // A search still waiting for typing to pause lands on the newest match
    // first; stepping past it would skip it.
    if (searchNow()) return;
    final count = _result.matches.length;
    if (count == 0) return;
    final current = _activeIndex ?? (delta > 0 ? -1 : count);
    _activeIndex = (current + delta) % count;
    _serial++;
    _announcement++;
    _notify();
  }

  void _run({required bool resetActive}) {
    if (_disposed) return;
    final trimmed = _query.trim();
    final previous = activeMatch;
    _result = _index.search(_entries, trimmed);
    _resultQuery = trimmed;
    if (resetActive) _announcement++;
    final matches = _result.matches;
    if (matches.isEmpty) {
      _activeIndex = null;
    } else if (resetActive || previous == null) {
      _activeIndex = matches.length - 1;
      _serial++;
    } else {
      // Streaming output re-ran the search: stay on the same occurrence
      // without scrolling, unless it no longer exists.
      final kept = matches.indexWhere(
        (match) =>
            match.entryId == previous.entryId && match.start == previous.start,
      );
      if (kept >= 0) {
        _activeIndex = kept;
      } else {
        _activeIndex = (_activeIndex ?? 0).clamp(0, matches.length - 1);
        _serial++;
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queryTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}
