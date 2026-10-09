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
  Timer? _timer;
  var _timerResetsActive = false;
  var _disposed = false;

  /// Whether the search bar is showing.
  bool get isOpen => _open;

  /// The text being searched for.
  String get query => _query;

  /// The latest matches.
  AcpTranscriptSearchResult get result => _result;

  /// Whether [result] reflects the current [query], rather than a search
  /// still waiting for typing to pause.
  bool get isSettled => _timer == null && _resultQuery == _query.trim();

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

  /// Shows the search bar.
  void open() {
    if (_open) return;
    _open = true;
    _notify();
  }

  /// Hides the search bar and forgets the query and its matches.
  void close() {
    if (!_open && _query.isEmpty) return;
    _timer?.cancel();
    _timer = null;
    _open = false;
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
    _schedule(queryDebounce, resetActive: true);
    _notify();
  }

  /// Supplies the transcript being searched. Safe to call during build: the
  /// search re-runs later, and only while a query is active.
  void updateEntries(List<AcpTimelineEntry> entries) {
    if (identical(entries, _entries)) return;
    _entries = entries;
    if (!_open || _query.trim().isEmpty) return;
    if (_timer != null) return;
    _schedule(refreshInterval, resetActive: false);
  }

  /// Runs any pending search immediately.
  void searchNow() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _run(resetActive: _timerResetsActive);
  }

  /// Moves to the next, newer match, wrapping to the oldest.
  void next() => _step(1);

  /// Moves to the previous, older match, wrapping to the newest.
  void previous() => _step(-1);

  void _step(int delta) {
    searchNow();
    final count = _result.matches.length;
    if (count == 0) return;
    final current = _activeIndex ?? (delta > 0 ? -1 : count);
    _activeIndex = (current + delta) % count;
    _serial++;
    _notify();
  }

  void _schedule(Duration delay, {required bool resetActive}) {
    _timer?.cancel();
    _timerResetsActive = resetActive || _timerResetsActive;
    _timer = Timer(delay, () {
      _timer = null;
      _run(resetActive: _timerResetsActive);
    });
  }

  void _run({required bool resetActive}) {
    _timerResetsActive = false;
    if (_disposed) return;
    final trimmed = _query.trim();
    final previous = activeMatch;
    _result = searchAcpTranscript(_entries, trimmed);
    _resultQuery = trimmed;
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
            match.childKey == previous.childKey &&
            match.start == previous.start,
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
    _timer?.cancel();
    super.dispose();
  }
}
