import 'dart:math';

import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

class _LineBuilder {
  _LineBuilder(this._capacity);

  final int _capacity;

  /// Allocated on first use: most logical lines never need a builder line, and
  /// a reflow visits every line of the scrollback.
  BufferLine? _result;

  BufferLine get _line => _result ??= BufferLine(_capacity);

  /// Whether [_result] came from [setBuffer] and may still hold cells past
  /// [_length].
  var _reused = false;

  int _length = 0;

  int get length => _length;

  bool get isNotEmpty => _length != 0;

  /// Adds a range of cells from [src] to the builder. Anchors within the range
  /// will be reparented to the new line returned by [take].
  void add(BufferLine src, int start, int length) {
    final line = _line..copyFrom(src, start, _length, length);
    _length += length;
    if (_reused) {
      // A line reused by [setBuffer] ends at the added cells; the cells it
      // had past them must not reappear when it is resized to the new width.
      // A fresh line has nothing there, and later adds only append.
      line.truncate(_length);
      _reused = false;
    }
  }

  /// Reuses the given [line] as the initial buffer for this builder.
  void setBuffer(BufferLine line, int length) {
    _result = line;
    _length = length;
    _reused = true;
  }

  void addAnchor(CellAnchor anchor, int offset) {
    anchor.reparent(_line, _length + offset);
  }

  BufferLine take({required bool wrapped}) {
    final result = _line..isWrapped = wrapped;
    _result = null;
    _reused = false;
    _length = 0;
    return result;
  }
}

/// Holds a the state of reflow operation of a single logical line.
class _LineReflow {
  final int oldWidth;

  final int newWidth;

  _LineReflow(this.oldWidth, this.newWidth);

  final _lines = <BufferLine>[];

  late final _builder = _LineBuilder(newWidth);

  /// Adds a line to the reflow operation. This method will try to reuse the
  /// given line if possible.
  void add(BufferLine line) {
    if (line.restoreOneColumnHalf()) {
      // Whatever followed the glyph, such as a cursor waiting to wrap, now
      // follows its second half.
      for (final anchor in line.anchors) {
        if (anchor.x >= 1) anchor.reposition(anchor.x + 1);
      }
    }
    final trimmedLength = line.getTrimmedLength(oldWidth);

    // A fast path for empty lines. Cells still waiting in the builder come
    // before it; adding it first put an erased continuation row ahead of the
    // text it continued.
    if (trimmedLength == 0) {
      if (_builder.isNotEmpty) {
        _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
      }
      _lines.add(line);
      return;
    }

    // We already have some content in the buffer, so we copy the content into
    // the builder instead of reusing the line.
    if (_lines.isNotEmpty || _builder.isNotEmpty) {
      _addPart(line, from: 0, to: trimmedLength);
      return;
    }

    if (newWidth >= oldWidth) {
      // Reuse the line to avoid copying the content and object allocation.
      _builder.setBuffer(line, trimmedLength);
    } else {
      _lines.add(line);

      if (trimmedLength > newWidth) {
        var from = newWidth;
        if (line.getWidth(newWidth - 1) == 2) {
          // The glyph stays on a line one column wide, as [_addPart] keeps
          // it there, with its second half; an anchor on that half stays
          // past the line's end. A wider line passes it on.
          from = newWidth == 1 ? 2 : newWidth - 1;
        }
        if (from < trimmedLength) {
          _addPart(line, from: from, to: trimmedLength);
        }
      }
    }

    if (newWidth >= oldWidth) {
      line.resize(newWidth);
    } else {
      // Whatever lay past the new width now continues on the next line.
      line.truncate(newWidth);
    }

    if (newWidth > 1 && line.getWidth(newWidth - 1) == 2) {
      line.resetCell(newWidth - 1);
    }
  }

  /// Adds part of [line] from [from] to [to] to the reflow operation.
  /// Anchors within the range will be removed from [line] and reparented to
  /// the new line(s) returned by [finish].
  void _addPart(BufferLine line, {required int from, required int to}) {
    var cellsLeft = to - from;

    while (cellsLeft > 0) {
      if (_builder.length >= newWidth) {
        // A line one column wide holding a wide glyph fills a line two
        // columns wide by itself when [setBuffer] reuses it.
        _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
      }
      final bufferRemainingCells = newWidth - _builder.length;

      // How many cells we should copy in this iteration.
      var cellsToCopy = cellsLeft;

      // Whether the buffer is filled up in this iteration.
      var lineFilled = false;

      if (cellsToCopy >= bufferRemainingCells) {
        cellsToCopy = bufferRemainingCells;
        lineFilled = true;
      }

      // Leave the last cell to the next iteration if it's a wide char.
      if (lineFilled && line.getWidth(from + cellsToCopy - 1) == 2) {
        if (cellsToCopy > 1) {
          cellsToCopy--;
        } else if (_builder.isNotEmpty) {
          // One cell is left on this line and the wide char needs two: end
          // the line here and start the next one with it. Copying only its
          // first half put it in the last column with its second half on the
          // next line, which no terminal can print.
          cellsToCopy = 0;
        }
        // When newWidth is 1, the wide cell cannot be deferred: copying zero
        // cells into an empty line would make the loop spin forever. Keep one
        // cell so the reflow always makes progress; the one-column display is
        // inherently lossy for full-width glyphs, but it must never hang the
        // terminal.
      }

      // A line one column wide takes the wide glyph whole, as printing it
      // there does: its second half goes with it rather than onto a line of
      // its own, and an anchor on that half follows the glyph.
      var copyEnd = from + cellsToCopy;
      if (newWidth == 1 &&
          cellsToCopy == 1 &&
          line.getWidth(from) == 2 &&
          copyEnd < to &&
          line.getWidth(copyEnd) == 0) {
        copyEnd++;
      }

      for (var anchor in line.anchors.toList()) {
        final isExclusiveRangeEnd = anchor.x == to && anchor.x == copyEnd;
        if (anchor.x >= from && (anchor.x < copyEnd || isExclusiveRangeEnd)) {
          // One just past that second half lands just past the line's end
          // too, as in the MonkeyMux model. Nothing clamps it later: resizing
          // a line that is already one column long leaves its anchors alone.
          _builder.addAnchor(anchor, min(anchor.x - from, cellsToCopy));
        }
      }

      _builder.add(line, from, cellsToCopy);

      cellsLeft -= copyEnd - from;
      from = copyEnd;

      // Create a new line if the buffer is filled up.
      if (lineFilled) {
        _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
      }
    }

    if (line.anchors.isNotEmpty) {
      for (var anchor in line.anchors.toList()) {
        if (anchor.x >= to) {
          _builder.addAnchor(anchor, anchor.x - to);
        }
      }
    }
  }

  /// Finalizes the reflow operation and returns the result.
  List<BufferLine> finish() {
    if (_builder.isNotEmpty) {
      _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
    }

    return _lines;
  }
}

List<BufferLine> reflow(
  IndexAwareCircularBuffer<BufferLine> lines,
  int oldWidth,
  int newWidth,
) {
  final result = <BufferLine>[];

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    final reflow = _LineReflow(oldWidth, newWidth);

    final firstMark = line.semanticPrompt;
    var marked = firstMark != SemanticPromptRow.none;

    // A prompt the shell marked on a row inside the logical line (VS Code's A
    // after output that wrapped, a secondary prompt after prompt text that
    // did) travels with the first cell of that row, like any anchor.
    final markAnchors = <(CellAnchor, SemanticPromptRow)>[];

    reflow.add(line);

    for (var offset = i + 1; offset < lines.length; offset++) {
      final nextLine = lines[offset];

      if (!nextLine.isWrapped) {
        break;
      }

      i++;

      final mark = nextLine.semanticPrompt;
      marked |= mark != SemanticPromptRow.none;
      if (mark.startsPrompt) {
        markAnchors.add((nextLine.createAnchor(0), mark));
      }
      reflow.add(nextLine);
    }

    // The line keeps its shell-integration mark on its first row; the rows it
    // wraps onto continue it when any of its rows was part of a prompt, and
    // the row that now holds the start of a marked row's text takes its mark,
    // unless a prompt starts on it already.
    final reflowed = reflow.finish();
    for (var row = 0; row < reflowed.length; row++) {
      reflowed[row].semanticPrompt = row == 0
          ? firstMark
          : marked
              ? SemanticPromptRow.continuation
              : SemanticPromptRow.none;
    }
    for (final (anchor, mark) in markAnchors) {
      final target = anchor.line;
      anchor.dispose();
      if (target != null && !target.semanticPrompt.startsPrompt) {
        target.semanticPrompt = mark;
      }
    }
    result.addAll(reflowed);
  }

  for (var line in result) {
    if (line.length > newWidth) {
      line.truncate(newWidth);
    } else {
      line.resize(newWidth);
    }
  }

  return result;
}
