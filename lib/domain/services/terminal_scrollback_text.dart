import 'dart:async';

import 'package:xterm/xterm.dart';

/// One hard line of terminal text: a buffer row plus the rows that soft-wrap
/// after it, read as a single string.
///
/// Rows are held by reference rather than by index. Output that arrives later
/// evicts the oldest rows from the scrollback, which shifts every index, while
/// a row object keeps its identity and reports [BufferLine.attached] as false
/// once it has been evicted.
final class TerminalTextLine {
  /// Creates a hard line read from [rows].
  const TerminalTextLine({
    required this.rows,
    required this.rowStarts,
    required this.text,
  });

  /// The buffer rows that make up this line, top to bottom. Every row after
  /// the first had [BufferLine.isWrapped] set when the line was read.
  final List<BufferLine> rows;

  /// Offset in [text] at which each row of [rows] starts.
  final List<int> rowStarts;

  /// The line's text. A soft wrap adds nothing between rows.
  final String text;

  /// Offset in [text] just past the text of row [rowIndex].
  int rowEnd(int rowIndex) =>
      rowIndex + 1 < rows.length ? rowStarts[rowIndex + 1] : text.length;

  /// Index into [rows] of the row that holds the code unit at [offset].
  ///
  /// A binary search: one hard line can wrap across the whole 10,000-row
  /// buffer.
  int rowIndexForOffset(int offset) {
    var low = 0;
    var high = rows.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (rowStarts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }
}

/// Text of [row], read the way terminal copy reads it.
///
/// This matches [BufferLine.getText]: the right half of a wide glyph adds
/// nothing, an empty cell reads as a space when text follows it (TUIs and
/// tmux skip blank runs with cursor movement instead of writing spaces), and
/// trailing empty cells are padding.
String terminalRowText(BufferLine row) {
  final out = StringBuffer();
  _writeRowText(row, out, null);
  return out.toString();
}

/// Text of [row] as [terminalRowText] reads it, plus the cell column that
/// produced each UTF-16 code unit of that text.
({String text, List<int> columns}) terminalRowTextWithColumns(BufferLine row) {
  final out = StringBuffer();
  final columns = <int>[];
  _writeRowText(row, out, columns);
  return (text: out.toString(), columns: columns);
}

/// Column just past the cell that starts at [column] in [row].
int terminalCellEndColumn(BufferLine row, int column) =>
    column + (column < row.length && row.getWidth(column) == 2 ? 2 : 1);

void _writeRowText(BufferLine row, StringBuffer out, List<int>? columns) {
  final length = row.length;
  var pendingBlankStart = 0;
  var pendingBlankCount = 0;
  for (var column = 0; column < length; column++) {
    final codePoint = row.getCodePoint(column);
    if (codePoint == 0) {
      // A width-2 cell always holds a code point, so the blanks between two
      // glyphs are one contiguous run of cells.
      if (column == 0 || row.getWidth(column - 1) != 2) {
        if (pendingBlankCount == 0) {
          pendingBlankStart = column;
        }
        pendingBlankCount++;
      }
      continue;
    }
    if (column + row.getWidth(column) > length) {
      continue;
    }
    for (var blank = 0; blank < pendingBlankCount; blank++) {
      out.writeCharCode(0x20);
      columns?.add(pendingBlankStart + blank);
    }
    pendingBlankCount = 0;
    out.writeCharCode(codePoint);
    if (columns != null) {
      columns.add(column);
      if (codePoint > 0xFFFF) {
        // A supplementary code point is two UTF-16 code units.
        columns.add(column);
      }
    }
  }
}

/// Default work per slice before [readTerminalTextLines] yields to the event
/// loop, so a frame can be drawn between slices.
const kTerminalTextSliceBudget = Duration(milliseconds: 4);

/// Yields to the event loop whenever a slice of work has used its budget.
final class TerminalWorkSlicer {
  /// Creates a slicer that allows [budget] of work between yields.
  TerminalWorkSlicer({this.budget = kTerminalTextSliceBudget})
    : _stopwatch = Stopwatch()..start();

  /// Work allowed between yields.
  final Duration budget;

  final Stopwatch _stopwatch;

  /// Yields if this slice has used its budget. Returns false when
  /// [isCancelled] reports that the caller should stop.
  Future<bool> maybeYield(bool Function() isCancelled) async {
    if (_stopwatch.elapsed < budget) {
      return !isCancelled();
    }
    await Future<void>.delayed(Duration.zero);
    _stopwatch.reset();
    return !isCancelled();
  }
}

bool _neverCancelled() => false;

/// Reads every row of [buffer], scrollback included, as hard lines.
///
/// The rows are captured up front, which is cheap, and their text is read in
/// slices that yield to the event loop, so reading a full 10,000-row buffer
/// does not drop frames. The slices are checked per row, so one hard line
/// that wraps across thousands of rows does not block either. Output that
/// arrives between slices may change a row that has not been read yet; the
/// reader returns what each row held when it was read. Returns null if
/// [isCancelled] reports true between slices.
Future<List<TerminalTextLine>?> readTerminalTextLines(
  Buffer buffer, {
  bool Function() isCancelled = _neverCancelled,
  Duration sliceBudget = kTerminalTextSliceBudget,
}) async {
  final lineCount = buffer.lines.length;
  final rows = List<BufferLine>.generate(
    lineCount,
    (index) => buffer.lines[index],
    growable: false,
  );
  final wrapped = List<bool>.generate(
    lineCount,
    (index) => index > 0 && rows[index].isWrapped,
    growable: false,
  );
  final slicer = TerminalWorkSlicer(budget: sliceBudget);
  final lines = <TerminalTextLine>[];
  final out = StringBuffer();
  var index = 0;
  while (index < lineCount) {
    if (!await slicer.maybeYield(isCancelled)) {
      return null;
    }
    var end = index + 1;
    while (end < lineCount && wrapped[end]) {
      end++;
    }
    if (end == index + 1) {
      final row = rows[index];
      out.clear();
      _writeRowText(row, out, null);
      lines.add(
        TerminalTextLine(
          rows: <BufferLine>[row],
          rowStarts: const <int>[0],
          text: out.toString(),
        ),
      );
    } else {
      out.clear();
      final lineRows = rows.sublist(index, end);
      final rowStarts = List<int>.filled(lineRows.length, 0);
      for (var rowIndex = 0; rowIndex < lineRows.length; rowIndex++) {
        if (rowIndex > 0 && !await slicer.maybeYield(isCancelled)) {
          return null;
        }
        rowStarts[rowIndex] = out.length;
        _writeRowText(lineRows[rowIndex], out, null);
      }
      lines.add(
        TerminalTextLine(
          rows: lineRows,
          rowStarts: rowStarts,
          text: out.toString(),
        ),
      );
    }
    index = end;
  }
  return lines;
}

/// Reads [buffer] as plain text for export.
///
/// Soft-wrapped rows join into one line, trailing cell padding and spaces are
/// dropped from each line, and the blank rows below the last output (the
/// unused part of the screen) are left out.
Future<String?> readTerminalBufferPlainText(
  Buffer buffer, {
  bool Function() isCancelled = _neverCancelled,
  Duration sliceBudget = kTerminalTextSliceBudget,
}) async {
  final lines = await readTerminalTextLines(
    buffer,
    isCancelled: isCancelled,
    sliceBudget: sliceBudget,
  );
  if (lines == null) {
    return null;
  }
  return terminalTextLinesToPlainText(lines.map((line) => line.text));
}

final _trailingSpaces = RegExp(r' +$');

/// Joins hard lines into export text: trailing spaces are trimmed from each
/// line and trailing blank lines are dropped. Non-empty text ends with a
/// newline.
String terminalTextLinesToPlainText(Iterable<String> lines) {
  final trimmed = [
    for (final line in lines) line.replaceFirst(_trailingSpaces, ''),
  ];
  var end = trimmed.length;
  while (end > 0 && trimmed[end - 1].isEmpty) {
    end--;
  }
  if (end == 0) {
    return '';
  }
  return '${trimmed.take(end).join('\n')}\n';
}
