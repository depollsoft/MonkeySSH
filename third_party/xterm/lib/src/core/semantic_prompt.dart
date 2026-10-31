import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';

/// The `cl` option of `OSC 133 ; A`: which cursor keys the shell's line
/// editor takes for moving its cursor to a clicked cell.
enum PromptCursorKeys {
  /// `cl=line`: left and right, within one input line.
  line,

  /// `cl=m`: left and right, across the lines of the input.
  multiple,

  /// `cl=v`: up and down between lines too, from the start of a line, since
  /// the editor may keep spurious spaces at line ends.
  conservativeVertical,

  /// `cl=w`: up and down from any column; the editor keeps the column it
  /// moves from, clamped to the shorter lines it lands on.
  smartVertical,
}

/// Semantic prompt (OSC 133, and VS Code's OSC 633) state of one screen
/// buffer: what the next written cell is, and how the current prompt asked
/// for clicks to be handled. Rows and cells keep their own marks
/// ([BufferLine.semanticPrompt], [BufferLine.getSemanticContent]).
///
/// Follows Ghostty: `A` (and `N`) start a fresh line and a primary prompt,
/// `P` a prompt of any kind, `B` the input until `C`, `I` the input until the
/// end of the line, `C` the command output, `D` the end of the command. A wrap
/// or newline inside a prompt or its input marks the row it reaches as a
/// continuation, unless the row has a mark already. The MonkeyMux screen model
/// (remote/monkeymux/vtscreen_prompt.go) applies the same rules.
class SemanticPromptState {
  /// The [SemanticContent] the next written cell takes.
  int content = SemanticContent.output;

  /// Whether the input ends at the end of the line (`OSC 133 ; I`) rather
  /// than at `OSC 133 ; C`.
  bool inputEndsAtEol = false;

  /// `click_events` of the current prompt: 0 when unset, 1 for clicks
  /// reported with absolute rows, 2 for rows counted from the prompt.
  int clickEvents = 0;

  /// `cl` of the current prompt, or null when unset.
  PromptCursorKeys? cursorKeys;

  /// `special_key=1`: the shell binds kitty's `CSI 1 u` and `CSI 1 ; 1 u` to
  /// move its cursor right and left, in place of arrow keys that may have
  /// side effects such as accepting a suggestion.
  bool specialKey = false;

  /// `redraw=0` turns this off: the shell does not redraw its prompt after a
  /// resize.
  bool redraw = true;

  /// `aid` of the current prompt, the application it belongs to.
  String? aid;

  /// Whether the current prompt asked for clicks inside it to move the cursor,
  /// by click events or cursor keys.
  bool get handlesClicks => clickEvents != 0 || cursorKeys != null;

  /// Back to no shell integration, as after a full reset.
  void reset() {
    resetCursor();
    _resetOptions();
  }

  /// Ends any prompt or input the cursor was writing: the next cell written is
  /// output.
  void resetCursor() {
    content = SemanticContent.output;
    inputEndsAtEol = false;
  }

  void _resetOptions() {
    clickEvents = 0;
    cursorKeys = null;
    specialKey = false;
    redraw = true;
    aid = null;
  }

  /// Applies the `key=value` options of `OSC 133 ; A`. Unknown and malformed
  /// options are ignored, as the specification asks.
  void _applyOptions(List<String> options) {
    for (final option in options) {
      final equals = option.indexOf('=');
      if (equals < 0) continue;
      final key = option.substring(0, equals);
      final value = option.substring(equals + 1);
      switch (key) {
        case 'click_events':
          if (value == '0' || value == '1' || value == '2') {
            clickEvents = int.parse(value);
          }
        case 'cl':
          final keys = switch (value) {
            'line' => PromptCursorKeys.line,
            'm' => PromptCursorKeys.multiple,
            'v' => PromptCursorKeys.conservativeVertical,
            'w' => PromptCursorKeys.smartVertical,
            _ => null,
          };
          if (keys != null) cursorKeys = keys;
        case 'special_key':
          if (value == '0' || value == '1') specialKey = value == '1';
        case 'redraw':
          // Ghostty's `redraw=last` still redraws.
          if (value == '0' || value == '1' || value == 'last') {
            redraw = value != '0';
          }
        case 'aid':
          aid = value;
      }
    }
  }

  /// Applied after every index (LF, IND, NEL, autowrap): a row reached while
  /// a prompt or its input is being written continues it, unless the input
  /// was to end with its line. A row the prompt already marked keeps its
  /// mark: the shell moved up and back down without repainting it.
  void afterIndex(BufferLine line) {
    if (content == SemanticContent.output) return;
    if (inputEndsAtEol) {
      resetCursor();
      return;
    }
    if (line.semanticPrompt == SemanticPromptRow.none) {
      line.semanticPrompt = SemanticPromptRow.continuation;
    }
  }
}

/// The prompt kind an `OSC 133` command names with `k=`, as the row mark it
/// gives: `i` (the default) and `r` start a primary prompt, `c` a
/// continuation and `s` a secondary prompt.
SemanticPromptRow _promptKind(List<String> options) {
  for (final option in options) {
    if (option.length == 3 && option.startsWith('k=')) {
      switch (option[2]) {
        case 'c':
          return SemanticPromptRow.continuation;
        case 's':
          return SemanticPromptRow.secondary;
        case 'i':
        case 'r':
          return SemanticPromptRow.prompt;
      }
    }
  }
  return SemanticPromptRow.prompt;
}

/// Applies an `OSC 133` or `OSC 633` shell integration mark to [buffer].
/// [args] are the OSC's parameters after the code. The app still receives
/// the OSC through [Terminal.onPrivateOSC].
void applySemanticPromptOsc(Buffer buffer, String code, List<String> args) {
  if (args.isEmpty) return;
  final state = buffer.semanticPrompt;
  if (code == '633') {
    // VS Code's marks: A prompt, B input, C output, D finished, F and G the
    // continuation prompt and its end, H and I the right prompt and its end.
    // Its A does not start a fresh line.
    switch (args.first) {
      case 'A':
        _startPrompt(buffer, const [], SemanticPromptRow.prompt);
      case 'B':
      case 'G':
      case 'I':
        state
          ..content = SemanticContent.input
          ..inputEndsAtEol = false;
      case 'C':
        _endInput(buffer);
      case 'D':
        state.resetCursor();
      case 'F':
        _markPrompt(buffer, SemanticPromptRow.continuation);
      case 'H':
        state
          ..content = SemanticContent.prompt
          ..inputEndsAtEol = false;
    }
    return;
  }
  if (code != '133') return;
  final options = args.sublist(1);
  switch (args.first) {
    case 'A':
    case 'N':
      // N first ends a command with the same aid; nothing tracks commands.
      _freshLine(buffer);
      _startPrompt(buffer, options, _promptKind(options));
    case 'P':
      _markPrompt(buffer, _promptKind(options));
    case 'B':
      state
        ..content = SemanticContent.input
        ..inputEndsAtEol = false;
    case 'I':
      state
        ..content = SemanticContent.input
        ..inputEndsAtEol = true;
    case 'C':
      _endInput(buffer);
    case 'D':
      state.resetCursor();
    case 'L':
      _freshLine(buffer);
  }
}

/// `OSC 133 ; L`: a new line unless the cursor is already at its start.
void _freshLine(Buffer buffer) {
  if (buffer.cursorX == 0) return;
  buffer.setCursorX(0);
  buffer.index();
}

/// Starts a prompt of kind [row]. A primary prompt is a new one, so the
/// options of the last prompt go; any other keeps them and takes any it names.
void _startPrompt(Buffer buffer, List<String> options, SemanticPromptRow row) {
  final state = buffer.semanticPrompt;
  if (row == SemanticPromptRow.prompt) state._resetOptions();
  state._applyOptions(options);
  _markPrompt(buffer, row);
}

void _markPrompt(Buffer buffer, SemanticPromptRow row) {
  buffer.semanticPrompt
    ..content = SemanticContent.prompt
    ..inputEndsAtEol = false;
  buffer.currentLine.semanticPrompt = row;
}

/// `OSC 133 ; C`. A prompt row the cursor is at the start of is output after
/// all: fish marks no continuation prompts, so the newline that ends its input
/// marks the next row as one, and then starts the output there.
void _endInput(Buffer buffer) {
  buffer.semanticPrompt.resetCursor();
  if (buffer.cursorX == 0) {
    buffer.currentLine.semanticPrompt = SemanticPromptRow.none;
  }
}

/// Semantic prompt queries and the clear-at-prompt rule on a [Buffer].
extension SemanticPromptBuffer on Buffer {
  /// Whether the cursor is at a shell prompt: on the main screen, on a prompt
  /// row or writing a prompt or its input. Without shell integration it never
  /// is.
  bool get cursorIsAtPrompt {
    if (isAltBuffer) return false;
    return currentLine.semanticPrompt != SemanticPromptRow.none ||
        semanticPrompt.content != SemanticContent.output;
  }

  /// The absolute rows of the prompt the cursor is at, from its first row to
  /// the last row continuing it, or null when the cursor is not at a prompt.
  ({int start, int end})? get currentPromptRows {
    if (!cursorIsAtPrompt) return null;
    final cursorRow = absoluteCursorY;
    var start = cursorRow;
    while (lines[start].semanticPrompt.continuesPrompt &&
        start > 0 &&
        lines[start - 1].semanticPrompt != SemanticPromptRow.none) {
      start--;
    }
    var end = cursorRow;
    while (end + 1 < lines.length &&
        lines[end + 1].semanticPrompt.continuesPrompt) {
      end++;
    }
    return (start: start, end: end);
  }

  /// `CSI 2 J` at a prompt keeps what the screen showed: on the main screen,
  /// when the last row with text, or a prompt row below it, is part of a
  /// prompt, every row down to the last non-empty one scrolls into the
  /// scrollback before the erase. Shells clear the screen this way for
  /// Ctrl-L, after moving the cursor home, so the cursor itself cannot tell.
  /// Ghostty 1.4 does the same; without shell integration nothing changes.
  void scrollClearAtPrompt() {
    if (isAltBuffer) return;
    var atPrompt = false;
    for (var row = viewHeight - 1; row >= 0; row--) {
      final line = lines[scrollBack + row];
      if (line.semanticPrompt != SemanticPromptRow.none) {
        atPrompt = true;
        break;
      }
      if (_hasText(line)) break;
    }
    if (!atPrompt) return;
    var rows = 0;
    for (var row = viewHeight - 1; row >= 0; row--) {
      if (!_isEmpty(lines[scrollBack + row])) {
        rows = row + 1;
        break;
      }
    }
    for (var i = 0; i < rows; i++) {
      if (lines.isFull) {
        graphics.removeGraphicsAnchoredToLine(lines[0]);
      }
      lines.push(BufferLine(viewWidth));
    }
  }

  bool _hasText(BufferLine line) {
    for (var x = 0; x < line.length && x < viewWidth; x++) {
      if (line.getCodePoint(x) != 0) return true;
    }
    return false;
  }

  /// Whether a row has neither text nor a coloured background.
  bool _isEmpty(BufferLine line) {
    for (var x = 0; x < line.length && x < viewWidth; x++) {
      if (line.getCodePoint(x) != 0 || line.getBackground(x) != 0) {
        return false;
      }
    }
    return true;
  }
}
