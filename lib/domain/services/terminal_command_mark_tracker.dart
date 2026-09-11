import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// Tracks semantic command locations emitted by OSC 133/633 and iTerm2 SetMark.
class TerminalCommandMarkTracker {
  /// Creates a bounded command-mark tracker.
  TerminalCommandMarkTracker({this.maxRetainedMarks = 200});

  /// Maximum attached anchors retained across both terminal buffers.
  final int maxRetainedMarks;
  Terminal? _terminal;
  final _marks = <({Buffer buffer, CellAnchor anchor})>[];

  Iterable<CellAnchor> get _activeMarks => _marks
      .where((mark) => identical(mark.buffer, _terminal?.buffer))
      .map((mark) => mark.anchor);

  /// Number of marks still attached to the active terminal buffer.
  int get markCount {
    _pruneDetached();
    return _activeMarks.length;
  }

  /// Attaches this tracker to a persistent terminal.
  void attach(Terminal terminal) {
    if (identical(_terminal, terminal)) return;
    reset(keepTerminalReference: false);
    _terminal = terminal;
  }

  /// Handles command-executed markers and explicit iTerm2 marks.
  bool handlePrivateOsc(String code, List<String> args) {
    final isCommandExecuted =
        (code == '133' || code == '633') && args.firstOrNull == 'C';
    final isExplicitMark = code == '1337' && args.firstOrNull == 'SetMark';
    if (!isCommandExecuted && !isExplicitMark) return false;
    final terminal = _terminal;
    if (terminal == null || maxRetainedMarks <= 0) return false;

    _pruneDetached();
    final buffer = terminal.buffer;
    final offset = CellOffset(buffer.cursorX, buffer.absoluteCursorY);
    if (_activeMarks.lastOrNull?.y == offset.y) return false;
    _marks.add((buffer: buffer, anchor: buffer.createAnchorFromOffset(offset)));
    while (_marks.length > maxRetainedMarks) {
      _marks.removeAt(0).anchor.dispose();
    }
    return true;
  }

  /// Returns the closest mark before [absoluteRow], wrapping to the newest.
  /// Only marks in the active terminal buffer participate in navigation.
  int? previousMarkRow(int absoluteRow) {
    _pruneDetached();
    int? newestRow;
    for (final mark in _marks.reversed) {
      if (!identical(mark.buffer, _terminal?.buffer)) continue;
      final row = mark.anchor.y;
      newestRow ??= row;
      if (row < absoluteRow) return row;
    }
    return newestRow;
  }

  /// Clears retained anchors.
  void reset({bool keepTerminalReference = true}) {
    for (final mark in _marks) {
      mark.anchor.dispose();
    }
    _marks.clear();
    if (!keepTerminalReference) _terminal = null;
  }

  void _pruneDetached() {
    _marks.removeWhere((mark) {
      if (mark.anchor.attached) return false;
      mark.anchor.dispose();
      return true;
    });
  }

  /// Attached mark rows in the active buffer exposed for focused tracker tests.
  @visibleForTesting
  List<int> get debugMarkRows {
    _pruneDetached();
    return _activeMarks.map((mark) => mark.y).toList(growable: false);
  }
}
