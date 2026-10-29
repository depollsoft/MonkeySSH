import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/input/kitty_keyboard.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/semantic_prompt.dart';
import 'package:xterm/src/terminal.dart';

/// Click-to-move inside a shell prompt, for shells that advertise it with
/// OSC 133 (see [SemanticPromptState]): kitty's `click_events`, which reports
/// the click to the shell as an SGR mouse event, and the `cl` option of the
/// semantic prompts specification, for which the terminal sends the cursor
/// keys that walk the shell's cursor to the clicked cell.
extension TerminalPromptClick on Terminal {
  /// Moves the shell's cursor to [position], a cell in absolute buffer rows,
  /// by writing [promptClickInput] to [onOutput]. Returns whether anything
  /// was written.
  bool clickPrompt(CellOffset position) {
    final input = promptClickInput(position);
    if (input == null || input.isEmpty) return false;
    onOutput?.call(input);
    return true;
  }

  /// The input that moves the shell's cursor to [position], a cell in absolute
  /// buffer rows. It is null unless the cursor is at a prompt that asked for
  /// clicks to be handled, on the main screen with mouse tracking off, and
  /// [position] is in that prompt's input: on its rows, at or after the first
  /// input cell (or the cursor, before anything is typed), and not on prompt
  /// text. It is empty when the cursor is already there.
  ///
  /// Cursor keys move one character per press, so a wide glyph is one press
  /// and only input cells count; prompt text and cells the shell skipped
  /// (indentation, the gap before a right prompt) take none. Each line break
  /// between input lines is one press for `cl=m`.
  String? promptClickInput(CellOffset position) {
    if (isUsingAltBuffer || mouseMode != MouseMode.none) return null;
    final buffer = this.buffer;
    final state = buffer.semanticPrompt;
    if (!state.handlesClicks) return null;
    final rows = buffer.currentPromptRows;
    if (rows == null || position.y < rows.start || position.y > rows.end) {
      return null;
    }
    final lines = buffer.lines;
    final width = buffer.viewWidth;
    final column = position.x.clamp(0, width - 1);
    final clickLine = lines[position.y];
    // The second half of a wide glyph is the glyph.
    final clickX =
        column > 0 && clickLine.getWidth(column - 1) == 2 ? column - 1 : column;
    if (clickLine.getSemanticContent(clickX) == SemanticContent.prompt) {
      return null;
    }
    final click = CellOffset(clickX, position.y);
    // With a wrap pending the cursor is past the character in the last
    // column, not on it.
    final cursor = CellOffset(
      buffer.isWrapPending ? width : buffer.cursorX,
      buffer.absoluteCursorY,
    );

    // The input lines of the prompt, each a row and the rows wrapping from
    // it, as the input characters on them.
    final inputLines = <List<CellOffset>>[];
    var clickLineIndex = 0;
    var cursorLineIndex = 0;
    for (var y = rows.start; y <= rows.end; y++) {
      final line = lines[y];
      if (y == rows.start || !line.isWrapped) inputLines.add([]);
      if (y == click.y) clickLineIndex = inputLines.length - 1;
      if (y == cursor.y) cursorLineIndex = inputLines.length - 1;
      for (var x = 0; x < width && x < line.length; x++) {
        if (x > 0 && line.getWidth(x - 1) == 2) continue;
        if (line.getSemanticContent(x) == SemanticContent.input) {
          inputLines.last.add(CellOffset(x, y));
        }
      }
    }

    // The input starts at its first character, or at the cursor while the
    // shell waits for the first one.
    CellOffset? inputStart;
    for (final line in inputLines) {
      if (line.isNotEmpty) {
        inputStart = line.first;
        break;
      }
    }
    if (state.content == SemanticContent.input &&
        (inputStart == null || cursor.isBefore(inputStart))) {
      inputStart = cursor;
    }
    if (inputStart == null || click.isBefore(inputStart)) return null;

    if (state.clickEvents != 0) {
      return _promptClickEvent(position, rows.start,
          relative: state.clickEvents == 2);
    }

    int charactersBefore(List<CellOffset> line, CellOffset cell) =>
        line.where((input) => input.isBefore(cell)).length;
    final cursorColumn = charactersBefore(inputLines[cursorLineIndex], cursor);
    final clickColumn = charactersBefore(inputLines[clickLineIndex], click);
    final lineDelta = clickLineIndex - cursorLineIndex;

    final out = StringBuffer();
    void horizontal(int count) {
      if (count == 0) return;
      final String? key;
      if (state.specialKey) {
        key = count > 0 ? '\x1b[1u' : '\x1b[1;1u';
      } else {
        key = _encodeKey(
          count > 0 ? TerminalKey.arrowRight : TerminalKey.arrowLeft,
        );
      }
      if (key == null) return;
      for (var i = 0; i < count.abs(); i++) {
        out.write(key);
      }
    }

    void vertical(int count) {
      if (count == 0) return;
      final key = _encodeKey(
        count > 0 ? TerminalKey.arrowDown : TerminalKey.arrowUp,
      );
      if (key == null) return;
      for (var i = 0; i < count.abs(); i++) {
        out.write(key);
      }
    }

    switch (state.cursorKeys!) {
      case PromptCursorKeys.line:
        if (lineDelta != 0) return null;
        horizontal(clickColumn - cursorColumn);
      case PromptCursorKeys.multiple:
        // Left and right cross a line break as one character.
        int offset(int lineIndex, int column) {
          var total = column;
          for (var i = 0; i < lineIndex; i++) {
            total += inputLines[i].length + 1;
          }
          return total;
        }
        horizontal(
          offset(clickLineIndex, clickColumn) -
              offset(cursorLineIndex, cursorColumn),
        );
      case PromptCursorKeys.conservativeVertical:
        if (lineDelta == 0) {
          horizontal(clickColumn - cursorColumn);
        } else {
          // From the start of the line, which every line has, so trailing
          // spaces the editor keeps cannot shift the column it lands on.
          horizontal(-cursorColumn);
          vertical(lineDelta);
          horizontal(clickColumn);
        }
      case PromptCursorKeys.smartVertical:
        if (lineDelta == 0) {
          horizontal(clickColumn - cursorColumn);
        } else {
          // The editor keeps the column, clamped to the line it lands on.
          vertical(lineDelta);
          final landed = cursorColumn < inputLines[clickLineIndex].length
              ? cursorColumn
              : inputLines[clickLineIndex].length;
          horizontal(clickColumn - landed);
        }
    }
    return out.toString();
  }

  /// A left-button press at [position] in SGR encoding, as kitty's
  /// `click_events` asks. Like kitty and Ghostty, no release follows: the
  /// shell moves the cursor on the press. Absolute rows count from the top of the
  /// screen; relative rows from the current prompt's top line, or, as kitty
  /// does, from a secondary prompt (`k=s`) at or above the clicked row. Rows
  /// the prompt or its input reached with a wrap or a newline start none: a
  /// prompt of two lines that marks only the first counts from the first.
  String? _promptClickEvent(
    CellOffset position,
    int promptStart, {
    required bool relative,
  }) {
    final buffer = this.buffer;
    final int row;
    if (relative) {
      var top = promptStart;
      for (var y = position.y; y > promptStart; y--) {
        if (buffer.lines[y].semanticPrompt == SemanticPromptRow.secondary) {
          top = y;
          break;
        }
      }
      row = position.y - top + 1;
    } else {
      row = position.y - buffer.scrollBack + 1;
      if (row < 1) return null;
    }
    final column = position.x.clamp(0, buffer.viewWidth - 1) + 1;
    return '\x1b[<0;$column;${row}M';
  }

  /// The bytes the key encoder sends for [key] pressed now: DECCKM picks
  /// `ESC O` or `CSI` arrows, and the kitty keyboard flags apply, exactly as
  /// for a typed key.
  String? _encodeKey(TerminalKey key) {
    final event = TerminalKeyboardEvent(
      key: key,
      shift: false,
      alt: false,
      ctrl: false,
      state: this,
      altBuffer: isUsingAltBuffer,
      platform: platform,
    );
    return encodeKittyKeyboardEvent(event, kittyKeyboardFlags) ??
        inputHandler?.call(event);
  }
}
