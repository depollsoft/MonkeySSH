import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

class _LineBuilder {
  _LineBuilder([this._capacity = 80]) {
    _result = BufferLine(_capacity);
  }

  final int _capacity;

  late BufferLine _result;

  int _length = 0;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Adds a range of cells from [src] to the builder. Anchors within the range
  /// will be reparented to the new line returned by [take].
  void add(BufferLine src, int start, int length) {
    _result.copyFrom(src, start, _length, length);
    _length += length;
    // A line reused by [setBuffer] ends at the added cells; the cells it had
    // past them must not reappear when it is resized to the new width.
    _result.truncate(_length);
  }

  /// Reuses the given [line] as the initial buffer for this builder.
  void setBuffer(BufferLine line, int length) {
    _result = line;
    _length = length;
  }

  void addAnchor(CellAnchor anchor, int offset) {
    anchor.reparent(_result, _length + offset);
  }

  BufferLine take({required bool wrapped}) {
    final result = _result;
    result.isWrapped = wrapped;
    // result.resize(_length);

    _result = BufferLine(_capacity);
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
    final trimmedLength = line.getTrimmedLength(oldWidth);

    // A fast path for empty lines
    if (trimmedLength == 0) {
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
        if (line.getWidth(newWidth - 1) == 2) {
          _addPart(line, from: newWidth - 1, to: trimmedLength);
        } else {
          _addPart(line, from: newWidth, to: trimmedLength);
        }
      }
    }

    if (newWidth >= oldWidth) {
      line.resize(newWidth);
    } else {
      // Whatever lay past the new width now continues on the next line.
      line.truncate(newWidth);
    }

    if (line.getWidth(newWidth - 1) == 2) {
      line.resetCell(newWidth - 1);
    }
  }

  /// Adds part of [line] from [from] to [to] to the reflow operation.
  /// Anchors within the range will be removed from [line] and reparented to
  /// the new line(s) returned by [finish].
  void _addPart(BufferLine line, {required int from, required int to}) {
    var cellsLeft = to - from;

    while (cellsLeft > 0) {
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

      for (var anchor in line.anchors.toList()) {
        final copyEnd = from + cellsToCopy;
        final isExclusiveRangeEnd = anchor.x == to && anchor.x == copyEnd;
        if (anchor.x >= from && (anchor.x < copyEnd || isExclusiveRangeEnd)) {
          _builder.addAnchor(anchor, anchor.x - from);
        }
      }

      _builder.add(line, from, cellsToCopy);

      from += cellsToCopy;
      cellsLeft -= cellsToCopy;

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

    reflow.add(line);

    for (var offset = i + 1; offset < lines.length; offset++) {
      final nextLine = lines[offset];

      if (!nextLine.isWrapped) {
        break;
      }

      i++;

      reflow.add(nextLine);
    }

    result.addAll(reflow.finish());
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
