import 'dart:async';

import 'package:xterm/xterm.dart';

import '../../domain/models/snippet_key_tokens.dart';
import 'terminal_key_input.dart';

/// Pause after a bare Escape byte before the next step, so the remote
/// program's escape parser times the Escape out instead of reading it and the
/// next key as one Alt chord. Matches the keyboard toolbar's Esc key.
const kSnippetEscapeSettle = Duration(milliseconds: 100);

/// How sending a snippet sequence ended.
enum SnippetSendOutcome {
  /// Every step was sent.
  completed,

  /// The sequence stopped early because its target went away, for example a
  /// disconnect or a window switch.
  stopped,
}

/// Sends [sequence] to [terminal] one step at a time.
///
/// Text is typed rather than pasted, because a key sequence stands in for
/// keystrokes: `{key:esc}:wq{key:enter}` must reach vim as commands, not as a
/// bracketed paste. A line break in the text is sent as Enter. Keys go
/// through [sendSnippetKey], which encodes them the way the keyboard toolbar
/// does in both kitty and legacy keyboard modes.
///
/// [canContinue] is checked before every step and after every pause; once it
/// returns false nothing more is sent. Callers make it false on a disconnect,
/// a reconnect, a window switch or a newer sequence.
Future<SnippetSendOutcome> sendSnippetKeySequence(
  Terminal terminal,
  SnippetKeySequence sequence, {
  required bool Function() canContinue,
  Future<void> Function(Duration duration) wait = _wait,
}) async {
  final steps = sequence.steps;
  for (var index = 0; index < steps.length; index++) {
    if (!canContinue()) {
      return SnippetSendOutcome.stopped;
    }
    switch (steps[index]) {
      case SnippetTextStep(:final text):
        _typeText(terminal, text);
      case SnippetKeyStep(:final chord):
        final sent = _forwardingOutput(
          terminal,
          () => sendSnippetKey(terminal, chord),
        );
        if (sent == '\x1b' && index + 1 < steps.length) {
          await wait(kSnippetEscapeSettle);
        }
      case SnippetDelayStep(:final duration):
        await wait(duration);
    }
  }
  return SnippetSendOutcome.completed;
}

Future<void> _wait(Duration duration) => Future<void>.delayed(duration);

final _lineBreak = RegExp(r'\r\n|\r|\n');

// C0 and C1 controls other than Tab. Keys are sent through tokens, so a
// stray control character in the text (from a variable value, say) is
// dropped rather than typed.
final _controlCharacters = RegExp(r'[\x00-\x08\x0B-\x1F\x7F-\x9F]');

void _typeText(Terminal terminal, String text) {
  final lines = text.split(_lineBreak);
  for (var index = 0; index < lines.length; index++) {
    if (index > 0) {
      sendTerminalEnterInput(
        terminal,
        shiftActive: false,
        altActive: false,
        ctrlActive: false,
      );
    }
    final line = lines[index].replaceAll(_controlCharacters, '');
    if (line.isNotEmpty) {
      terminal.textInput(line);
    }
  }
}

// Runs [send] and returns everything it wrote, while still passing each write
// on to the terminal's output sink as it happens.
String _forwardingOutput(Terminal terminal, void Function() send) {
  final output = terminal.onOutput;
  final sent = StringBuffer();
  terminal.onOutput = (data) {
    sent.write(data);
    output?.call(data);
  };
  try {
    send();
  } finally {
    terminal.onOutput = output;
  }
  return sent.toString();
}

/// Sends one key chord from a snippet to [terminal]. Returns whether
/// anything was sent.
///
/// Enter goes through [sendTerminalEnterInput], like the toolbar's Enter.
/// When the program has turned on kitty keyboard flags
/// ([terminalUsesKittyKeyEncoding]) every key goes through
/// [Terminal.keyInput], which encodes it as CSI u. Otherwise:
/// - letter, digit, space and punctuation keys are typed, Ctrl turning them
///   into their control byte and Alt adding an Escape prefix;
/// - named keys use the terminal's legacy key table, which honours cursor-key
///   mode and xterm modifier parameters. Alt on a key the table has no Alt
///   form for becomes an Escape prefix; any other modifier it has no form for
///   is dropped.
bool sendSnippetKey(Terminal terminal, SnippetKeyChord chord) {
  final key = chord.key;
  if (key == TerminalKey.enter) {
    return sendTerminalEnterInput(
      terminal,
      shiftActive: chord.shift,
      altActive: chord.alt,
      ctrlActive: chord.ctrl,
    );
  }
  if (terminalUsesKittyKeyEncoding(terminal)) {
    return terminal.keyInput(
      key,
      shift: chord.shift,
      alt: chord.alt,
      ctrl: chord.ctrl,
    );
  }
  final character = key == TerminalKey.space ? ' ' : chord.character;
  if (character != null) {
    terminal.textInput(legacySnippetCharacterInput(chord, character));
    return true;
  }

  String? encode({bool shift = false, bool alt = false, bool ctrl = false}) =>
      _captureOutput(
        terminal,
        () => terminal.keyInput(key, shift: shift, alt: alt, ctrl: ctrl),
      );
  final withoutAlt = encode(shift: chord.shift, ctrl: chord.ctrl);
  var output = chord.alt
      ? encode(shift: chord.shift, alt: true, ctrl: chord.ctrl)
      : withoutAlt;
  if (chord.alt && (output == null || output == withoutAlt)) {
    // The key table has no Alt form for this key (Esc, for one), so send
    // Alt the way xterm's meta-sends-escape does: an Escape prefix.
    final base = withoutAlt ?? encode();
    output = base == null ? null : '\x1b$base';
  }
  output ??= encode();
  if (output == null) {
    return false;
  }
  terminal.onOutput?.call(output);
  return true;
}

/// Legacy bytes for a character key: Shift upper-cases a letter, Ctrl turns
/// the character into its control byte when it has one, and Alt adds an
/// Escape prefix.
String legacySnippetCharacterInput(SnippetKeyChord chord, String character) {
  var text = chord.shift ? character.toUpperCase() : character;
  if (chord.ctrl) {
    final code = _controlCode(character);
    if (code != null) {
      text = String.fromCharCode(code);
    }
  }
  return chord.alt ? '\x1b$text' : text;
}

// The control byte a terminal sends for Ctrl plus [character], following
// xterm: letters map to 1-26 and a few punctuation and digit keys to the
// remaining C0 codes.
int? _controlCode(String character) {
  final unit = character.toLowerCase().codeUnitAt(0);
  if (unit >= 0x61 && unit <= 0x7A) {
    return unit - 0x60;
  }
  return switch (character) {
    ' ' || '2' => 0x00,
    '[' || '3' => 0x1B,
    r'\' || '4' => 0x1C,
    ']' || '5' => 0x1D,
    '6' => 0x1E,
    '-' || '/' || '7' => 0x1F,
    '8' => 0x7F,
    _ => null,
  };
}

String? _captureOutput(Terminal terminal, bool Function() send) {
  final output = terminal.onOutput;
  final chunks = <String>[];
  terminal.onOutput = chunks.add;
  final bool handled;
  try {
    handled = send();
  } finally {
    terminal.onOutput = output;
  }
  return handled ? chunks.join() : null;
}
