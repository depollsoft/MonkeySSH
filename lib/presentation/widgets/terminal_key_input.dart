import 'dart:async';
import 'dart:collection';

import 'package:xterm/xterm.dart';

/// Sends Enter via [Terminal.keyInput] with the active modifiers.
///
/// Outside Kitty mode, non-press events are ignored (legacy keytabs only emit
/// on press). Kitty mode forwards press/repeat/release so the remote gets the
/// full progressive-enhancement sequence, except Alt+Enter. That chord keeps
/// the broadly-supported meta-sends-escape form (`ESC CR`) because Pi and
/// other prompt TUIs bind it to queue/enqueue while treating CSI-u Alt+Enter
/// as a literal multiline insertion.
///
/// Two legacy keytab gaps are corrected only for this Enter keystroke:
/// - DEC LNM makes unmodified Return emit CRLF; collapse that to CR so prompt
///   TUIs do not also see LF as newline. Paste and other producers are untouched.
/// - There is no Enter+Alt keytab record, so Alt is dropped; apply
///   meta-sends-escape (ESC CR) when Alt is the only modifier.
bool sendTerminalEnterInput(
  Terminal terminal, {
  required bool shiftActive,
  required bool altActive,
  required bool ctrlActive,
  bool metaActive = false,
  TerminalKeyEventType type = TerminalKeyEventType.press,
}) {
  if (type != TerminalKeyEventType.press && !terminal.kittyKeyboardMode) {
    return false;
  }

  final altOnly = altActive && !shiftActive && !ctrlActive && !metaActive;
  if (altOnly) {
    if (type == TerminalKeyEventType.press) {
      _writeEnterKey(terminal.onOutput, '\x1b\r');
    }
    // Do not send a CSI-u repeat/release after the legacy press sequence.
    return true;
  }

  final previousOutput = terminal.onOutput;
  final chunks = <String>[];
  terminal.onOutput = chunks.add;
  final bool handled;
  try {
    handled = terminal.keyInput(
      TerminalKey.enter,
      shift: shiftActive,
      alt: altActive,
      ctrl: ctrlActive,
      meta: metaActive,
      type: type,
    );
  } finally {
    terminal.onOutput = previousOutput;
  }

  if (!handled) {
    return false;
  }

  var payload = chunks.join();
  final hasModifiers = shiftActive || altActive || ctrlActive || metaActive;
  if (!hasModifiers && payload == '\r\n') {
    // LNM Return keytab emits CRLF as one keystroke.
    payload = '\r';
  }

  _writeEnterKey(previousOutput, payload);
  return true;
}

/// Whether [sendTerminalEnterInput] is writing an Enter keystroke right now,
/// so an output sink can tell it from text; see [TerminalEnterPacer].
bool get isWritingTerminalEnterKey => _writingTerminalEnterKey;
var _writingTerminalEnterKey = false;

void _writeEnterKey(void Function(String)? output, String payload) {
  if (output == null) {
    return;
  }
  _writingTerminalEnterKey = true;
  try {
    output(payload);
  } finally {
    _writingTerminalEnterKey = false;
  }
}

/// Whether [writeKeyboardSpace] is writing right now, so an output sink can
/// tell a space the keyboard added on its own from typed text; see
/// [TerminalEnterPacer].
bool get isWritingKeyboardSpace => _writingKeyboardSpace;
var _writingKeyboardSpace = false;

/// Runs [write], marking its output as a space the soft keyboard added on its
/// own, with no Space key pressed for it.
void writeKeyboardSpace(void Function() write) {
  _writingKeyboardSpace = true;
  try {
    write();
  } finally {
    _writingKeyboardSpace = false;
  }
}

/// Keeps an Enter keystroke apart from text sent just before it.
///
/// A soft keyboard commits the word being typed at the moment Return is
/// pressed, so that text and the Enter leave together. Prompt TUIs read input
/// arriving that fast as a paste or dictation and take the Return for a line
/// break inside it: Hermes inserts a newline for an Enter within 50 ms of a
/// change to its input, Muse Code within about 120 ms of a burst of typed
/// characters. The pacer holds such an Enter until [gap] after the text, so it
/// arrives as the separate keystroke the user pressed. Output written while an
/// Enter waits queues behind it, so the order never changes. An Enter with no
/// recent text goes out at once. Anything that changes where input goes, such
/// as switching the active window, waits for [idle] first, so a held keystroke
/// reaches the program it was typed into.
///
/// Gboard also commits the space it adds after punctuation when Return is
/// pressed, a few milliseconds before the key event. The user never typed that
/// space, and holding the Enter behind it would show it in the prompt for
/// [gap] before the Return submitted. So a space marked as the keyboard's own
/// (see [writeKeyboardSpace]) waits up to [spaceHold] for what follows: an
/// Enter in that time replaces it, and anything else sends it first. A space
/// from a Space key, or from anywhere else, goes out at once, since a quick
/// Space and Enter can be two keystrokes, such as toggling a checklist item
/// and confirming it.
class TerminalEnterPacer {
  /// Creates a pacer that passes output to [write].
  TerminalEnterPacer({
    required void Function(String data) write,
    this.gap = defaultGap,
    this.spaceHold = defaultSpaceHold,
    DateTime Function()? now,
  }) : _write = write,
       _now = now ?? DateTime.now;

  /// The default distance between text and a following Enter: the longest
  /// such window among the agents the app launches, with room for jitter.
  static const defaultGap = Duration(milliseconds: 150);

  /// The default wait for an Enter after the keyboard's own space. Gboard's
  /// space lands within a few milliseconds of its Return; the rest is room for
  /// a busy frame between the two.
  static const defaultSpaceHold = Duration(milliseconds: 50);

  /// How long after the last text an Enter is held back.
  final Duration gap;

  /// How long the keyboard's own space waits for an Enter that would replace
  /// it.
  final Duration spaceHold;

  final void Function(String data) _write;
  final DateTime Function() _now;
  final _pending = Queue<_PacedOutput>();
  DateTime? _lastTextAt;
  Timer? _timer;
  // Whether [_timer] holds the keyboard's own space rather than an Enter.
  bool _holdingSpace = false;
  Completer<void>? _idle;

  /// Completes once the held Enter or space and anything queued behind it have
  /// gone out; null when nothing is held back.
  Future<void>? get idle =>
      _timer == null ? null : (_idle ??= Completer<void>()).future;

  /// Sends [data], an Enter keystroke when [enter] is set and a space the
  /// keyboard added on its own when [keyboardSpace] is.
  void add(String data, {required bool enter, bool keyboardSpace = false}) {
    if (_holdingSpace) {
      _timer!.cancel();
      _timer = null;
      _holdingSpace = false;
      if (enter) {
        // The keyboard committed this space as Return was pressed.
        _pending.removeLast();
      }
    }
    _pending.add((data: data, enter: enter, keyboardSpace: keyboardSpace));
    if (_timer == null) {
      _pump();
    }
  }

  void _pump() {
    while (_pending.isNotEmpty) {
      final next = _pending.first;
      final lastTextAt = _lastTextAt;
      if (next.enter && lastTextAt != null) {
        final wait = gap - _now().difference(lastTextAt);
        if (wait > Duration.zero) {
          _timer = Timer(wait, () {
            _timer = null;
            _lastTextAt = null;
            _pump();
          });
          return;
        }
      } else if (next.keyboardSpace && _pending.length == 1) {
        _holdingSpace = true;
        _timer = Timer(spaceHold, () {
          _timer = null;
          _holdingSpace = false;
          _send(_pending.removeFirst());
          _pump();
        });
        return;
      }
      _send(_pending.removeFirst());
    }
    _completeIdle();
  }

  void _send(_PacedOutput output) {
    _lastTextAt = output.enter ? null : _now();
    _write(output.data);
  }

  void _completeIdle() {
    final idle = _idle;
    _idle = null;
    idle?.complete();
  }

  /// Drops anything still waiting, for a connection that is gone.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _holdingSpace = false;
    _pending.clear();
    _completeIdle();
  }
}

typedef _PacedOutput = ({String data, bool enter, bool keyboardSpace});
