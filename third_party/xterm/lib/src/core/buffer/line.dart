import 'dart:math' show min;
import 'dart:typed_data';

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

const _cellSize = 5;

const _cellForeground = 0;

const _cellBackground = 1;

const _cellAttributes = 2;

const _cellContent = 3;

const _cellUnderlineColor = 4;

/// The cell's [SemanticContent] lives in two bits of the attribute word, above
/// the [CellAttr] bits. [BufferLine.getCellData] leaves them out, so painters
/// and anything else comparing attributes never see them.
const _cellSemanticShift = 16;

const _cellSemanticMask = 3 << _cellSemanticShift;

/// What OSC 133 shell integration marked a row as, as Ghostty marks its rows.
enum SemanticPromptRow {
  /// Nothing, as far as the terminal knows: command output, or no shell
  /// integration at all.
  none,

  /// A primary prompt starts on this row (`OSC 133 ; A` or `P`, kinds `i` and
  /// `r`).
  prompt,

  /// The row continues a prompt or the input after it: a row that a wrap or
  /// newline reached while a prompt or its input was being written, or a
  /// continuation prompt (`k=c`, VS Code's `OSC 633 ; F`).
  continuation,

  /// The row continues a prompt as a secondary prompt (`k=s`), which kitty's
  /// relative click events count rows from.
  secondary;

  /// Whether the row continues the prompt on the row above.
  bool get continuesPrompt => this == continuation || this == secondary;

  /// Whether the shell marked a prompt as starting on the row, rather than
  /// the row being reached inside one: a mark a reflow keeps with the row's
  /// text.
  bool get startsPrompt => this == prompt || this == secondary;
}

class BufferLine with IndexedItem {
  BufferLine(
    this._length, {
    this.isWrapped = false,
  }) : _data = Uint32List(_calcCapacity(_length) * _cellSize);

  int _length;

  Uint32List _data;

  /// The raw cell words. A cell's [getGraphemeExtras] live outside them, so
  /// copying cells through [data] loses them; [copyFrom] keeps them.
  Uint32List get data => _data;

  /// The most code points a cell holds after its base, as in Ghostty and the
  /// MonkeyMux screen model. Further ones joining the cluster are dropped.
  static const maxGraphemeExtras = 15;

  /// [getGraphemeExtras] of the cells that have any, by column, created on
  /// first use since most lines have none. Every operation that writes,
  /// erases or moves cells keeps it in step with [_data], including the cells
  /// past [length] that a shrink keeps.
  Map<int, List<int>>? _graphemeExtras;

  var isWrapped = false;

  /// The shell-integration mark of this row. It moves with the row, is
  /// cleared when an erase clears the whole row, and a reflow keeps it on
  /// the first row of the line and marks the rest as continuations.
  var semanticPrompt = SemanticPromptRow.none;

  int get length => _length;

  final _anchors = <CellAnchor>[];

  List<CellAnchor> get anchors => _anchors;

  int getForeground(int index) {
    return _data[index * _cellSize + _cellForeground];
  }

  int getBackground(int index) {
    return _data[index * _cellSize + _cellBackground];
  }

  int getContent(int index) {
    return _data[index * _cellSize + _cellContent];
  }

  /// The first code point of the cell at [index], or 0 for an empty cell or
  /// the right half of a wide one. [getGrapheme] has the cell's whole text.
  int getCodePoint(int index) {
    return _data[index * _cellSize + _cellContent] & CellContent.codepointMask;
  }

  /// Whether the cell at [index] holds code points after its first one, which
  /// [getGraphemeExtras] returns. Its content word has
  /// [CellContent.graphemeFlag] then.
  bool hasGraphemeExtras(int index) {
    return _data[index * _cellSize + _cellContent] & CellContent.graphemeFlag !=
        0;
  }

  /// The code points the cell at [index] holds after [getCodePoint]: the rest
  /// of its grapheme cluster. Empty for most cells. The list must not be
  /// changed.
  List<int> getGraphemeExtras(int index) {
    if (!hasGraphemeExtras(index)) return const [];
    return _graphemeExtras![index]!;
  }

  /// The text of the cell at [index]: its first code point and every one
  /// joined to it, or an empty string for an empty cell or the right half of
  /// a wide one.
  String getGrapheme(int index) {
    final codePoint = getCodePoint(index);
    if (codePoint == 0) return '';
    if (!hasGraphemeExtras(index)) return String.fromCharCode(codePoint);
    return String.fromCharCodes([codePoint, ...getGraphemeExtras(index)]);
  }

  int getWidth(int index) {
    return _data[index * _cellSize + _cellContent] >> CellContent.widthShift;
  }

  /// The [SemanticContent] the cell at [index] was written with.
  int getSemanticContent(int index) {
    return (_data[index * _cellSize + _cellAttributes] & _cellSemanticMask) >>
        _cellSemanticShift;
  }

  void getCellData(int index, CellData cellData) {
    final offset = index * _cellSize;
    cellData.foreground = _data[offset + _cellForeground];
    cellData.background = _data[offset + _cellBackground];
    cellData.flags = _data[offset + _cellAttributes] & ~_cellSemanticMask;
    cellData.content = _data[offset + _cellContent];
    cellData.underlineColor = _data[offset + _cellUnderlineColor];
    cellData.graphemeExtras = getGraphemeExtras(index);
  }

  /// Replaces the content word of the cell at [index], which starts a new
  /// glyph: the cell's [getGraphemeExtras] are dropped, and so is a
  /// [CellContent.graphemeFlag] in [value].
  void setContent(int index, int value) {
    _clearGraphemeExtras(index);
    _data[index * _cellSize + _cellContent] = value & ~CellContent.graphemeFlag;
  }

  /// Changes the width of the cell at [index] to [width], keeping its code
  /// points and attributes, for a grapheme cluster that a code point joining
  /// it widened or narrowed.
  void setWidth(int index, int width) {
    final offset = index * _cellSize + _cellContent;
    final content = _data[offset];
    _data[offset] = (content & ((1 << CellContent.widthShift) - 1)) |
        (width << CellContent.widthShift);
  }

  /// Sets the code points the cell at [index] holds after its first one to
  /// [codePoints], at most [maxGraphemeExtras] of them. The cell must not be
  /// empty.
  void setGraphemeExtras(int index, List<int> codePoints) {
    assert(codePoints.length <= maxGraphemeExtras);
    final offset = index * _cellSize + _cellContent;
    if (codePoints.isEmpty) {
      _clearGraphemeExtras(index);
      _data[offset] &= ~CellContent.graphemeFlag;
      return;
    }
    (_graphemeExtras ??= {})[index] = List.unmodifiable(codePoints);
    _data[offset] |= CellContent.graphemeFlag;
  }

  /// Joins [codePoint] to the grapheme cluster of the cell at [index], after
  /// its other code points.
  void addGraphemeExtra(int index, int codePoint) {
    setGraphemeExtras(index, [...getGraphemeExtras(index), codePoint]);
  }

  bool get _hasAnyGraphemeExtras => _graphemeExtras?.isNotEmpty ?? false;

  /// Forgets the extra code points of the cell at [index], whose content word
  /// is about to be replaced.
  @pragma('vm:prefer-inline')
  void _clearGraphemeExtras(int index) {
    final extras = _graphemeExtras;
    if (extras != null && extras.isNotEmpty) extras.remove(index);
  }

  void setCodePoint(int index, int char) {
    final width = unicodeV11.wcwidth(char);
    setContent(index, char | (width << CellContent.widthShift));
  }

  /// Writes a cell. [semanticContent] is the [SemanticContent] in force.
  void setCell(
    int index,
    int char,
    int witdh,
    CursorStyle style, [
    int semanticContent = SemanticContent.output,
  ]) {
    _clearGraphemeExtras(index);
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] =
        style.attrs | (semanticContent << _cellSemanticShift);
    _data[offset + _cellContent] = char | (witdh << CellContent.widthShift);
    _data[offset + _cellUnderlineColor] = style.underlineColor;
  }

  /// Erases a cell to a blank in [style]'s background, the only part of the
  /// rendition an erase keeps, as in xterm.js, Ghostty and the MonkeyMux
  /// screen model: a blank painted in an inverse or coloured foreground
  /// would come back without it in a MonkeyMux replay.
  void eraseCell(int index, CursorStyle style) {
    _clearGraphemeExtras(index);
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = 0;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = 0;
    _data[offset + _cellContent] = 0;
    _data[offset + _cellUnderlineColor] = 0;
  }

  void resetCell(int index) {
    _clearGraphemeExtras(index);
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = 0;
    _data[offset + _cellBackground] = 0;
    _data[offset + _cellAttributes] = 0;
    _data[offset + _cellContent] = 0;
    _data[offset + _cellUnderlineColor] = 0;
  }

  /// Erase cells whose index satisfies [start] <= index < [end]. Erased cells
  /// are filled with [style].
  void eraseRange(
    int start,
    int end,
    CursorStyle style, {
    Set<CellAnchor> preservedAnchors = const <CellAnchor>{},
  }) {
    start = start.clamp(0, _length);
    end = end.clamp(0, _length);
    if (start >= end) return;

    // Include both halves of a wide cell, including their anchors.
    if (start > 0 && getWidth(start - 1) == 2) start--;
    if (end < _length && getWidth(end - 1) == 2) end++;

    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }

    // Erased cells no longer own anchored text/cell-image content. Physical
    // Kitty placements are independent terminal layers and are explicitly
    // preserved by the buffer until a graphics delete or buffer reset.
    for (final anchor in _anchors.toList()) {
      if (anchor.x >= start &&
          anchor.x < end &&
          !preservedAnchors.contains(anchor)) {
        anchor.dispose();
      }
    }
  }

  /// Remove [count] cells starting at [start]. Cells that are empty after the
  /// removal are filled with [style].
  void removeCells(int start, int count, [CursorStyle? style]) {
    assert(start >= 0 && start < _length);
    assert(count >= 0 && start + count <= _length);
    if (count <= 0) return;

    style ??= CursorStyle.empty;

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      _data.setRange(moveStart, moveEnd, _data, moveStart + count * _cellSize);
    }
    if (_hasAnyGraphemeExtras) {
      _remapGraphemeExtras((column) {
        if (column < start || column >= _length) return column;
        return column < start + count ? null : column - count;
      });
    }

    for (var i = _length - count; i < _length; i++) {
      eraseCell(i, style);
    }

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    // Update anchors, remove anchors that are inside the removed range.
    for (final anchor in _anchors.toList()) {
      if (anchor.x >= start) {
        if (anchor.x < start + count) {
          anchor.dispose();
        } else {
          anchor.reposition(anchor.x - count);
        }
      }
    }
  }

  /// Inserts [count] cells at [start]. New cells are initialized with [style].
  void insertCells(int start, int count, [CursorStyle? style]) {
    if (count <= 0) return;
    style ??= CursorStyle.empty;

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      final moveOffset = count * _cellSize;
      _data.setRange(
          moveStart + moveOffset, moveEnd + moveOffset, _data, moveStart);
    }
    if (_hasAnyGraphemeExtras) {
      _remapGraphemeExtras((column) {
        if (column < start || column >= _length) return column;
        return column + count < _length ? column + count : null;
      });
    }

    final end = min(start + count, _length);
    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }

    if (getWidth(_length - 1) == 2) {
      eraseCell(_length - 1, style);
    }

    // Update anchors, move anchors that are after the inserted range.
    for (final anchor in _anchors.toList()) {
      if (anchor.x >= start) {
        anchor.reposition(anchor.x + count);

        // Remove anchors that are now outside the buffer.
        if (anchor.x >= _length) {
          anchor.dispose();
        }
      }
    }
  }

  void resize(int length) {
    assert(length >= 0);

    if (length == _length) {
      return;
    }

    if (length > _length) {
      final newBufferSize = _calcCapacity(length) * _cellSize;

      if (newBufferSize > _data.length) {
        final newBuffer = Uint32List(newBufferSize);
        newBuffer.setRange(0, _data.length, _data);
        _data = newBuffer;
      }
    }

    _length = length;

    for (var i = 0; i < _anchors.length; i++) {
      final anchor = _anchors[i];
      if (anchor.x > _length) {
        anchor.reposition(_length);
      }
    }
  }

  /// Shrinks the line to [length] and drops the cells past it. [resize] keeps
  /// them, so that a width that only hides them can bring them back; a reflow
  /// has moved them to the next line instead, and a line that kept its copy
  /// showed it again, erased or not, once it grew.
  void truncate(int length) {
    resize(length);
    _data.fillRange(length * _cellSize, _data.length, 0);
    _graphemeExtras?.removeWhere((column, _) => column >= length);
  }

  /// Moves [getGraphemeExtras] along with cells that moved: each column's
  /// extras go to the column [move] returns, or are dropped when it returns
  /// null.
  void _remapGraphemeExtras(int? Function(int column) move) {
    final moved = <int, List<int>>{};
    _graphemeExtras!.forEach((column, codePoints) {
      final to = move(column);
      if (to != null) moved[to] = codePoints;
    });
    _graphemeExtras = moved;
  }

  /// Returns the offset of the last cell that has content from the start of
  /// the line.
  int getTrimmedLength([int? cols]) {
    final maxCols = _data.length ~/ _cellSize;

    if (cols == null || cols > maxCols) {
      cols = maxCols;
    }

    if (cols <= 0) {
      return 0;
    }

    for (var i = cols - 1; i >= 0; i--) {
      var codePoint = getCodePoint(i);

      if (codePoint != 0) {
        // we are at the last cell in this line that has content.
        // the length of this line is the index of this cell + 1
        // the only exception is that if that last cell is wider
        // than 1 then we have to add the diff
        final lastCellWidth = getWidth(i);
        return i + lastCellWidth;
      }
    }
    return 0;
  }

  /// Copies [len] cells from [src] starting at [srcCol] to [dstCol] at this
  /// line.
  void copyFrom(BufferLine src, int srcCol, int dstCol, int len) {
    resize(dstCol + len);
    final dstOffset = dstCol * _cellSize;
    _data.setRange(
        dstOffset, dstOffset + len * _cellSize, src._data, srcCol * _cellSize);

    // Read before writing: [src] may be this line.
    final srcExtras = src._graphemeExtras;
    final copied = srcExtras == null || srcExtras.isEmpty
        ? const <MapEntry<int, List<int>>>[]
        : [
            for (final MapEntry(key: column, value: codePoints)
                in srcExtras.entries)
              if (column >= srcCol && column < srcCol + len)
                MapEntry(column - srcCol + dstCol, codePoints),
          ];
    _graphemeExtras
        ?.removeWhere((column, _) => column >= dstCol && column < dstCol + len);
    if (copied.isNotEmpty) {
      (_graphemeExtras ??= {}).addEntries(copied);
    }
  }

  static int _calcCapacity(int length) {
    assert(length >= 0);

    var capacity = 64;

    if (length < 256) {
      while (capacity < length) {
        capacity *= 2;
      }
    } else {
      capacity = 256;
      while (capacity < length) {
        capacity += 32;
      }
    }

    return capacity;
  }

  String getText([int? from, int? to]) {
    if (from == null || from < 0) {
      from = 0;
    }

    if (to == null || to > _length) {
      to = _length;
    }

    final builder = StringBuffer();
    var pendingBlankCells = 0;
    for (var i = from; i < to; i++) {
      final codePoint = getCodePoint(i);
      if (codePoint == 0) {
        // The right half of a wide character carries no text of its own. Any
        // other empty cell was skipped by cursor movement or erased, which
        // TUIs and tmux use in place of writing spaces, so it reads as a
        // space when text follows it. Trailing empty cells stay padding.
        if (i == 0 || getWidth(i - 1) != 2) {
          pendingBlankCells++;
        }
        continue;
      }
      if (i + getWidth(i) > to) {
        continue;
      }
      for (; pendingBlankCells > 0; pendingBlankCells--) {
        builder.writeCharCode(0x20);
      }
      builder.writeCharCode(codePoint);
      if (hasGraphemeExtras(i)) {
        for (final extra in getGraphemeExtras(i)) {
          builder.writeCharCode(extra);
        }
      }
    }

    return builder.toString();
  }

  CellAnchor createAnchor(int offset) {
    final anchor = CellAnchor(offset, owner: this);
    _anchors.add(anchor);
    return anchor;
  }

  @override
  String toString() {
    return getText();
  }
}

/// A handle to a cell in a [BufferLine] that can be used to track the location
/// of the cell. Anchors are guaranteed to be stable, retaining their relative
/// position to each other after mutations to the buffer.
class CellAnchor {
  CellAnchor(int offset, {BufferLine? owner})
      : _offset = offset,
        _owner = owner;

  int _offset;

  int get x {
    return _offset;
  }

  int get y {
    final owner = _owner;
    if (owner == null || !owner.attached) {
      throw StateError('Cannot access y on detached CellAnchor');
    }
    return owner.index;
  }

  CellOffset get offset {
    final owner = _owner;
    if (owner == null || !owner.attached) {
      throw StateError('Cannot access offset on detached CellAnchor');
    }
    return CellOffset(_offset, owner.index);
  }

  BufferLine? _owner;

  /// Called immediately before this anchor detaches from its line.
  void Function(CellAnchor anchor)? onDispose;

  BufferLine? get line => _owner;

  bool get attached => _owner?.attached ?? false;

  void reparent(BufferLine owner, int offset) {
    _owner?._anchors.remove(this);
    _owner = owner;
    _owner?._anchors.add(this);
    _offset = offset;
  }

  void reposition(int offset) {
    _offset = offset;
  }

  void dispose() {
    if (_owner == null) return;
    final callback = onDispose;
    onDispose = null;
    callback?.call(this);
    _owner?._anchors.remove(this);
    _owner = null;
  }

  @override
  String toString() {
    if (attached) {
      return 'CellAnchor($x, $y)';
    } else {
      return 'CellAnchor($x, detached)';
    }
  }
}
