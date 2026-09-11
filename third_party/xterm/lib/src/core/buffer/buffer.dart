import 'dart:collection';
import 'dart:math' show max, min;

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/charset.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/graphics_manager.dart';
import 'package:xterm/src/core/reflow.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

class Buffer {
  final TerminalState terminal;

  final int maxLines;

  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  /// Kitty-graphics-protocol images placed in this buffer. Each buffer (main and
  /// alternate) keeps its own set so images do not leak between them.
  final GraphicsManager graphics = GraphicsManager();

  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
  }) {
    for (int i = 0; i < terminal.viewHeight; i++) {
      lines.push(_newEmptyLine());
    }

    resetVerticalMargins();
  }

  int _cursorX = 0;

  int _cursorY = 0;

  late int _marginTop;

  late int _marginBottom;

  var _savedCursorX = 0;

  var _savedCursorY = 0;

  final _savedCursorStyle = CursorStyle();

  final charset = Charset();

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(maxLines);

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX => _cursorX.clamp(0, terminal.viewWidth - 1);

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _cursorY;

  /// Index of the first line in the scroll region.
  int get marginTop => _marginTop;

  /// Index of the last line in the scroll region.
  int get marginBottom => _marginBottom;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => _cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => _marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => _marginBottom + scrollBack;

  /// Writes data to the _terminal. Terminal sequences or special characters are
  /// not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    for (var char in text.runes) {
      writeChar(char);
    }
  }

  /// Writes a single character to the _terminal. Escape sequences or special
  /// characters are not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.writeChar]
  void writeChar(int codePoint) {
    codePoint = charset.translate(codePoint);

    final cellWidth = unicodeV11.wcwidth(codePoint);
    if (_cursorX >= terminal.viewWidth) {
      index();
      setCursorX(0);
      if (terminal.autoWrapMode) {
        currentLine.isWrapped = true;
      }
    }

    final line = currentLine;
    graphics.removePlaceholderAt(line, _cursorX);
    line.setCell(_cursorX, codePoint, cellWidth, terminal.cursor);

    if (_cursorX < viewWidth) {
      _cursorX++;
    }

    if (cellWidth == 2) {
      writeChar(0);
    }
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  void backspace() {
    if (_cursorX == 0 && currentLine.isWrapped) {
      currentLine.isWrapped = false;
      moveCursor(viewWidth - 1, -1);
    } else if (_cursorX == viewWidth) {
      moveCursor(-2, 0);
    } else {
      moveCursor(-1, 0);
    }
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor() {
    eraseLineFromCursor();

    for (var i = absoluteCursorY + 1; i < height; i++) {
      final line = lines[i];
      line.isWrapped = false;
      _eraseRange(line, 0, viewWidth);
    }
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor() {
    eraseLineToCursor();

    for (var i = 0; i < _cursorY; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      _eraseRange(line, 0, viewWidth);
    }
  }

  /// Erases the whole viewport.
  void eraseDisplay() {
    for (var i = 0; i < viewHeight; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      _eraseRange(line, 0, viewWidth);
    }
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor() {
    currentLine.isWrapped = false;
    _eraseRange(currentLine, cursorX, viewWidth);
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor() {
    currentLine.isWrapped = false;
    _eraseRange(currentLine, 0, cursorX + 1);
  }

  /// Erases the line at the current cursor position.
  void eraseLine() {
    currentLine.isWrapped = false;
    _eraseRange(currentLine, 0, viewWidth);
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count) {
    final start = cursorX;
    _eraseRange(currentLine, start, start + count);
  }

  void _eraseRange(BufferLine line, int start, int end) {
    graphics.removePlaceholdersInLineRange(line, start, end);
    line.eraseRange(
      start,
      end,
      terminal.cursor,
      preservedAnchors: graphics.physicalPlacementAnchorsInLine(line),
    );
  }

  void scrollDown(int lines) {
    final top = absoluteMarginTop;
    final bottom = absoluteMarginBottom;
    final regionHeight = bottom - top + 1;
    if (regionHeight <= 0) return;
    final count = lines < regionHeight ? lines : regionHeight;
    if (count <= 0) return;
    for (var i = bottom - count + 1; i <= bottom; i++) {
      graphics.removeGraphicsAnchoredToLine(this.lines[i]);
    }
    final reordered = <BufferLine>[
      for (var i = 0; i < count; i++) _newEmptyLine(),
      for (var i = top; i <= bottom - count; i++) this.lines[i],
    ];
    this.lines.reassignRange(top, reordered);
  }

  void scrollUp(int lines) {
    final top = absoluteMarginTop;
    final bottom = absoluteMarginBottom;
    final regionHeight = bottom - top + 1;
    if (regionHeight <= 0) return;
    final count = lines < regionHeight ? lines : regionHeight;
    if (count <= 0) return;
    for (var i = top; i < top + count; i++) {
      graphics.removeGraphicsAnchoredToLine(this.lines[i]);
    }
    final reordered = <BufferLine>[
      for (var i = top + count; i <= bottom; i++) this.lines[i],
      for (var i = 0; i < count; i++) _newEmptyLine(),
    ];
    this.lines.reassignRange(top, reordered);
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginBottom) {
        if (marginTop == 0 && !isAltBuffer) {
          if (lines.isFull) {
            graphics.removeGraphicsAnchoredToLine(lines[0]);
          }
          lines.insert(absoluteMarginBottom + 1, _newEmptyLine());
        } else {
          scrollUp(1);
        }
      } else {
        moveCursorY(1);
      }
      return;
    }

    // the cursor is not in the scrollable region
    if (_cursorY >= viewHeight - 1) {
      // we are at the bottom
      if (isAltBuffer) {
        scrollUp(1);
      } else {
        if (lines.isFull) {
          graphics.removeGraphicsAnchoredToLine(lines[0]);
        }
        lines.push(_newEmptyLine());
      }
    } else {
      // there're still lines so we simply move cursor down.
      moveCursorY(1);
    }
  }

  void lineFeed() {
    index();
    if (terminal.lineFeedMode) {
      setCursorX(0);
    }
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginTop) {
        scrollDown(1);
      } else {
        moveCursorY(-1);
      }
    } else {
      moveCursorY(-1);
    }
  }

  void cursorGoForward() {
    _cursorX = min(_cursorX + 1, viewWidth);
  }

  void setCursorX(int cursorX) {
    _cursorX = cursorX.clamp(0, viewWidth - 1);
  }

  void setCursorY(int cursorY) {
    _cursorY = cursorY.clamp(0, viewHeight - 1);
  }

  void moveCursorX(int offset) {
    setCursorX(_cursorX + offset);
  }

  void moveCursorY(int offset) {
    setCursorY(_cursorY + offset);
  }

  void setCursor(int cursorX, int cursorY) {
    var maxCursorY = viewHeight - 1;

    if (terminal.originMode) {
      cursorY += _marginTop;
      maxCursorY = _marginBottom;
    }

    _cursorX = cursorX.clamp(0, viewWidth - 1);
    _cursorY = cursorY.clamp(0, maxCursorY);
  }

  void moveCursor(int offsetX, int offsetY) {
    final cursorX = _cursorX + offsetX;
    final cursorY = _cursorY + offsetY;
    setCursor(cursorX, cursorY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor() {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedCursorStyle.foreground = terminal.cursor.foreground;
    _savedCursorStyle.background = terminal.cursor.background;
    _savedCursorStyle.attrs = terminal.cursor.attrs;
    _savedCursorStyle.underlineColor = terminal.cursor.underlineColor;
    charset.save();
  }

  /// Restore cursor position, charmap and text attributes.
  void restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = _savedCursorY;
    terminal.cursor.foreground = _savedCursorStyle.foreground;
    terminal.cursor.background = _savedCursorStyle.background;
    terminal.cursor.attrs = _savedCursorStyle.attrs;
    terminal.cursor.underlineColor = _savedCursorStyle.underlineColor;
    charset.restore();
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _marginTop = top.clamp(0, viewHeight - 1);
    _marginBottom = bottom.clamp(0, viewHeight - 1);

    _marginTop = min(_marginTop, _marginBottom);
    _marginBottom = max(_marginTop, _marginBottom);
  }

  bool get isInVerticalMargin {
    return _cursorY >= _marginTop && _cursorY <= _marginBottom;
  }

  void resetVerticalMargins() {
    setVerticalMargins(0, viewHeight - 1);
  }

  void deleteChars(int count) {
    final start = cursorX;
    count = min(count, viewWidth - start);
    currentLine.removeCells(start, count, terminal.cursor);
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    if (height <= viewHeight) {
      return;
    }

    graphics.removePlacementsInRows(0, scrollBack - 1);
    for (var row = 0; row < scrollBack; row++) {
      graphics.removeGraphicsAnchoredToLine(lines[row]);
    }
    lines.trimStart(scrollBack);
  }

  /// Clears the viewport and scrollback buffer. Then fill with empty lines.
  void clear() {
    graphics.clear();
    lines.clear();
    for (int i = 0; i < viewHeight; i++) {
      lines.push(_newEmptyLine());
    }
  }

  void insertBlankChars(int count) {
    currentLine.insertCells(cursorX, count, terminal.cursor);
  }

  void insertLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    // Number of lines from the cursor to the bottom of the scrollable region
    // including the cursor itself.
    final linesBelow = absoluteMarginBottom - absoluteCursorY + 1;

    // Number of empty lines to insert.
    final linesToInsert = min(count, linesBelow);

    // Number of lines to move up.
    final linesToMove = linesBelow - linesToInsert;

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteMarginBottom - i;
      graphics.removeGraphicsAnchoredToLine(lines[index]);
      lines[index] = lines.swap(index - linesToInsert, _newEmptyLine());
    }

    for (var i = linesToMove; i < linesToInsert; i++) {
      final index = absoluteCursorY + i;
      graphics.removeGraphicsAnchoredToLine(lines[index]);
      lines[index] = _newEmptyLine();
    }
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    count = min(count, absoluteMarginBottom - absoluteCursorY + 1);

    for (var i = absoluteCursorY; i < absoluteCursorY + count; i++) {
      graphics.removeGraphicsAnchoredToLine(lines[i]);
    }
    final reordered = <BufferLine>[
      for (var i = absoluteCursorY + count; i <= absoluteMarginBottom; i++)
        lines[i],
      for (var i = 0; i < count; i++) _newEmptyLine(),
    ];
    lines.reassignRange(absoluteCursorY, reordered);
  }

  void resize(int oldWidth, int oldHeight, int newWidth, int newHeight) {
    // 1. Adjust the height.
    if (newHeight > oldHeight) {
      // Grow larger
      for (var i = 0; i < newHeight - oldHeight; i++) {
        if (newHeight > lines.length) {
          lines.push(_newEmptyLine(newWidth));
        } else {
          _cursorY++;
        }
      }
    } else {
      // Shrink smaller.
      //
      // Two ways to lose a row, and only one of them is lossless. Dropping the
      // last buffer line keeps the viewport anchored where it is but destroys
      // whatever that line held; scrolling the viewport down one row (which is
      // what decrementing the cursor does, since the viewport top is derived
      // from lines.length - viewHeight) pushes the top row into scrollback and
      // keeps every line. Prefer discarding trailing blank rows, then scrolling,
      // and only drop a line with content when the cursor has nowhere left to
      // go.
      //
      // The naive "pop unless the cursor would fall off the bottom" rule ate
      // content on every shrink step for full-screen TUIs that park the cursor
      // above their own footer (Copilot CLI, Claude Code): the keyboard-open
      // animation resizes a dozen times, and each step deleted another row the
      // TUI still believed it owned, desynchronising its cursor-relative
      // repaints from the buffer.
      //
      // None of that holds on the alternate screen, which has no scrollback: a
      // row pushed above the viewport is deleted outright by the
      // `clearScrollback()` that follows every resize. So there the choice is
      // not lossless-vs-destructive, it is only *which* rows to destroy — and
      // the answer has to be whichever ones the host destroys, because the
      // client is mirroring a remote grid and a TUI repaints against the host's
      // row indices. tmux (`screen_resize_y`, with `GRID_HISTORY` cleared for
      // the alternate grid by `screen_alternate_on`) gives up the rows *below*
      // the cursor first, blank or not, and only once the cursor has nothing
      // left below it deletes from the top, moving the cursor up with them.
      //
      // Preferring blank rows there — refusing to drop a TUI's non-blank footer
      // and taking the row off the top instead — diverges from the host by
      // exactly the number of rows the app keeps under its cursor, on every one
      // of the dozen steps an Android keyboard animation produces. The frame
      // then sits at an offset the app never applies, so its cursor-relative
      // repaints land on the wrong rows and leave stale bands behind.
      //
      for (var i = 0; i < oldHeight - newHeight; i++) {
        final lastIndex = lines.length - 1;
        if (isAltBuffer) {
          if (lastIndex <= 0) {
            break;
          }
          if (lastIndex > _cursorY) {
            // The host gives up rows below the cursor first. Remove graphics
            // before detaching their anchors so stale placements cannot keep
            // decoded images alive after the row is gone.
            graphics.removePlacementsInRows(lastIndex, lastIndex);
            graphics.removeGraphicsAnchoredToLine(lines[lastIndex]);
            lines.pop();
          } else if (_cursorY > 0) {
            // Once no rows remain below the cursor, the no-history host drops
            // rows from the top and moves the cursor up with them. Commit that
            // trim here instead of deferring it to clearScrollback(): resize
            // runs for the inactive alt buffer too, where clearScrollback()
            // would otherwise never run and the discarded rows could reappear.
            graphics.removePlacementsInRows(0, 0);
            graphics.removeGraphicsAnchoredToLine(lines[0]);
            lines.trimStart(1);
            _cursorY--;
          } else {
            graphics.removePlacementsInRows(lastIndex, lastIndex);
            graphics.removeGraphicsAnchoredToLine(lines[lastIndex]);
            lines.pop();
          }
          continue;
        }
        final canDropLast = lastIndex > absoluteCursorY;
        if (canDropLast && _isReclaimableRow(lastIndex)) {
          graphics.removeGraphicsAnchoredToLine(lines[lastIndex]);
          lines.pop();
        } else if (_cursorY > 0) {
          _cursorY--;
        } else if (canDropLast) {
          graphics.removeGraphicsAnchoredToLine(lines[lastIndex]);
          lines.pop();
        }
      }
    }

    // Ensure cursor is within the screen.
    _cursorX = _cursorX.clamp(0, newWidth - 1);
    _cursorY = _cursorY.clamp(0, newHeight - 1);
    _savedCursorX = _savedCursorX.clamp(0, newWidth - 1);
    _savedCursorY = _savedCursorY.clamp(0, newHeight - 1);

    // 2. Adjust the width.
    if (newWidth != oldWidth) {
      if (terminal.reflowEnabled && !isAltBuffer) {
        final reflowResult = reflow(lines, oldWidth, newWidth);

        while (reflowResult.length < newHeight) {
          reflowResult.add(_newEmptyLine(newWidth));
        }

        final retainedStart = max(0, reflowResult.length - lines.maxLength);
        final retainedLines = HashSet<BufferLine>.identity()
          ..addAll(reflowResult.skip(retainedStart));
        for (var row = 0; row < lines.length; row++) {
          final line = lines[row];
          if (!retainedLines.contains(line)) {
            graphics.removeGraphicsAnchoredToLine(line);
          }
        }
        lines.replaceWith(reflowResult);
      } else {
        lines.forEach((item) => item.resize(newWidth));
      }
    }
  }

  /// Whether the row at [index] carries nothing worth keeping, so a shrink can
  /// reclaim it instead of scrolling.
  ///
  /// Deliberately measures the line's whole retained capacity rather than the
  /// visible width. When reflow is off (and always on the alt buffer) a width
  /// shrink keeps the cells past the new width so they reappear on the way back
  /// out, so a row can look empty across the visible columns while still
  /// holding text. Measuring only the visible width would call that row blank
  /// and pop it, destroying cells the non-reflowing contract promises to keep.
  ///
  /// A row holding a Kitty physical placement is likewise not blank even with
  /// no code points at all: the image hangs off a [CellAnchor] on the line, so
  /// popping the line detaches the anchor and loses the image. In-flight
  /// decodes count too — their anchor is registered before the image arrives.
  bool _isReclaimableRow(int index) {
    if (lines[index].getTrimmedLength() != 0) {
      return false;
    }
    return graphics.physicalPlacementAnchorsInLine(lines[index]).isEmpty;
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// Create a new empty [BufferLine] with the current [viewWidth] if [width]
  /// is not specified.
  BufferLine _newEmptyLine([int? width]) {
    final line = BufferLine(width ?? viewWidth);
    return line;
  }

  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    r'.'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r'-'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
    r'"'.codeUnitAt(0),
    r'*'.codeUnitAt(0),
    r'+'.codeUnitAt(0),
    r'/'.codeUnitAt(0),
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    var separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    var line = lines[position.y];
    var start = position.x;
    var end = position.x;

    do {
      if (start == 0) {
        break;
      }
      final char = line.getCodePoint(start - 1);
      if (separators.contains(char)) {
        break;
      }
      start--;
    } while (true);

    do {
      if (end >= viewWidth) {
        break;
      }
      final char = line.getCodePoint(end);
      if (separators.contains(char)) {
        break;
      }
      end++;
    } while (true);

    if (start == end) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(start, position.y),
      CellOffset(end, position.y),
    );
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  String getText([BufferRange? range]) {
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth - 1, height - 1),
    );

    range = range.normalized;

    final builder = StringBuffer();

    for (var segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= height) {
        continue;
      }
      final line = lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write("\n");
      }
      builder.write(line.getText(segment.start, segment.end));
    }

    return builder.toString();
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = lines.length.toString().length;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |${lines[i]}|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }
}
