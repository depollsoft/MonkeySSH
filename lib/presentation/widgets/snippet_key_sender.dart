import 'dart:async';

import 'package:xterm/xterm.dart';

import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/snippet_key_tokens.dart';
import '../../domain/services/ssh_service.dart' show TerminalShellStatus;
import 'terminal_key_input.dart';

/// Pause after a bare Escape byte before the next step, so the remote
/// program's escape parser times the Escape out instead of reading it and the
/// next key as one Alt chord. Matches the keyboard toolbar's Esc key.
const kSnippetEscapeSettle = Duration(milliseconds: 100);

/// Pause after a key that submits a line before the next step, so what
/// follows reaches the program in a later read. Prompt TUIs read text that
/// arrives with a Return as a paste: Claude Code above 64 characters, Copilot
/// CLI above 32, and both then treat the Return as a line break.
const kSnippetSubmitSettle = TerminalEnterPacer.defaultGap;

/// How sending a snippet sequence ended.
enum SnippetSendOutcome {
  /// Every step was sent.
  completed,

  /// The sequence stopped early because its target went away, for example a
  /// disconnect or a window switch.
  stopped,
}

/// How a snippet with key tokens goes through the command review.
enum SnippetReviewMode {
  /// Shell integration reports a prompt: the same review as a plain snippet,
  /// so a key that submits a line counts as a line break.
  full,

  /// The prompt state is unknown (the shell does not report it): review only
  /// what the plain-snippet classifier finds suspicious (chaining,
  /// redirection, command substitution, control characters, variables, text
  /// typed after a submitted line). One command followed by the key that
  /// submits it, or by more keys, does not ask on its own.
  suspiciousOnly,

  /// A full-screen program, a detected agent or a running command owns the
  /// input: the snippet is a macro for that program and goes out in one tap.
  none,
}

/// Picks the [SnippetReviewMode] for a key snippet.
SnippetReviewMode snippetKeySequenceReviewMode({
  required TerminalShellStatus? shellStatus,
  required bool isUsingAltBuffer,
  required bool isAgentToolActive,
}) {
  if (isUsingAltBuffer ||
      isAgentToolActive ||
      shellStatus == TerminalShellStatus.runningCommand) {
    return SnippetReviewMode.none;
  }
  return shellStatus == null
      ? SnippetReviewMode.suspiciousOnly
      : SnippetReviewMode.full;
}

/// Narrows [review] to what [mode] reviews. In
/// [SnippetReviewMode.suspiciousOnly] a line break that only submits the
/// command does not ask; a second command line ([typesAfterSubmit], from
/// [SnippetKeySequence.typesAfterSubmit]) still does.
TerminalCommandReview reviewForSnippetMode(
  TerminalCommandReview review,
  SnippetReviewMode mode, {
  required bool typesAfterSubmit,
}) {
  if (mode != SnippetReviewMode.suspiciousOnly || typesAfterSubmit) {
    return review;
  }
  return TerminalCommandReview(
    command: review.command,
    reasons: [
      for (final reason in review.reasons)
        if (reason != TerminalCommandReviewReason.multiline) reason,
    ],
    bracketedPasteModeEnabled: review.bracketedPasteModeEnabled,
  );
}

/// Sends [sequence] to [terminal] one step at a time.
///
/// Text is typed rather than pasted, because a key sequence stands in for
/// keystrokes: `{key:esc}:wq{key:enter}` must reach vim as commands, not as a
/// bracketed paste. A line break in the text is sent as Enter. Keys go
/// through [sendSnippetKey], which encodes them the way the keyboard toolbar
/// does in both kitty and legacy keyboard modes.
///
/// [outputIdle] returns a future that completes once output held back by the
/// terminal's Enter pacer has gone out, or null when nothing is held. Every
/// pause (an Escape settle, the gap after a submitted line, a `{delay}`) waits
/// for it first, so the pause separates the bytes on the wire and not just
/// the calls that queued them.
///
/// [canContinue] is checked before every step and after every pause; once it
/// returns false nothing more is sent. Callers make it false on a disconnect,
/// a reconnect, a window switch, typing or a newer sequence.
Future<SnippetSendOutcome> sendSnippetKeySequence(
  Terminal terminal,
  SnippetKeySequence sequence, {
  required bool Function() canContinue,
  Future<void>? Function()? outputIdle,
  Future<void> Function(Duration duration) wait = _wait,
}) async {
  Future<void> drain() async {
    final idle = outputIdle?.call();
    if (idle != null) {
      await idle;
    }
  }

  final steps = _expandLineBreaks(sequence.steps);
  for (var index = 0; index < steps.length; index++) {
    if (!canContinue()) {
      return SnippetSendOutcome.stopped;
    }
    Duration? settle;
    switch (steps[index]) {
      case SnippetTextStep(:final text):
        terminal.textInput(text);
      case SnippetKeyStep(:final chord):
        final sent = _forwardingOutput(
          terminal,
          () => sendSnippetKey(terminal, chord),
        );
        if (chord.submitsLine) {
          settle = kSnippetSubmitSettle;
        } else if (sent == '\x1b') {
          settle = kSnippetEscapeSettle;
        }
      case SnippetDelayStep(:final duration):
        settle = duration;
    }
    if (settle != null && index + 1 < steps.length) {
      await drain();
      await wait(settle);
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

const _enter = SnippetKeyStep(SnippetKeyChord(TerminalKey.enter));

// Splits text steps at line breaks into text and Enter steps, so a typed
// line break gets the same pacing as `{key:enter}`.
List<SnippetStep> _expandLineBreaks(List<SnippetStep> steps) => [
  for (final step in steps)
    if (step is SnippetTextStep)
      for (final (index, line) in step.text.split(_lineBreak).indexed) ...[
        if (index > 0) _enter,
        if (line.replaceAll(_controlCharacters, '') case final text
            when text.isNotEmpty)
          SnippetTextStep(text),
      ]
    else
      step,
];

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
/// ([terminalUsesKittyKeyEncoding]) keys go through [Terminal.keyInput],
/// which encodes them as CSI u. Kitty leaves printable keys without Ctrl or
/// Alt to text input, so those are typed, as the toolbar's text keys are.
/// Otherwise:
/// - letter, digit, space and punctuation keys are typed: Shift gives the US
///   shifted character, Ctrl the control byte, Alt an Escape prefix;
/// - arrows, Home and End with modifiers send `CSI 1 ; <mod> <final>`, the
///   xterm form the toolbar uses; without modifiers they use the terminal's
///   key table, which honours cursor-key mode;
/// - other named keys use the key table. Alt on a key the table has no Alt
///   form for becomes an Escape prefix; any other modifier it has no form
///   for is dropped.
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
  final character = key == TerminalKey.space ? ' ' : chord.character;
  if (terminalUsesKittyKeyEncoding(terminal)) {
    if (terminal.keyInput(
      key,
      shift: chord.shift,
      alt: chord.alt,
      ctrl: chord.ctrl,
    )) {
      return true;
    }
    if (character == null) {
      return false;
    }
    terminal.textInput(legacySnippetCharacterInput(chord, character));
    return true;
  }
  if (character != null) {
    terminal.textInput(legacySnippetCharacterInput(chord, character));
    return true;
  }

  final hasModifiers = chord.shift || chord.alt || chord.ctrl;
  final cursorFinal = _cursorKeyFinals[key];
  if (hasModifiers && cursorFinal != null) {
    final modifier =
        1 + (chord.shift ? 1 : 0) + (chord.alt ? 2 : 0) + (chord.ctrl ? 4 : 0);
    terminal.textInput('\x1b[1;$modifier$cursorFinal');
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

const _cursorKeyFinals = <TerminalKey, String>{
  TerminalKey.arrowUp: 'A',
  TerminalKey.arrowDown: 'B',
  TerminalKey.arrowRight: 'C',
  TerminalKey.arrowLeft: 'D',
  TerminalKey.home: 'H',
  TerminalKey.end: 'F',
};

/// Legacy bytes for a character key: Shift gives the US shifted character,
/// Ctrl the control byte ([snippetControlCode]) and Alt an Escape prefix.
String legacySnippetCharacterInput(SnippetKeyChord chord, String character) {
  var text = chord.shift ? snippetShiftedCharacter(character) : character;
  if (chord.ctrl) {
    final code = snippetControlCode(character, shift: chord.shift);
    if (code != null) {
      text = String.fromCharCode(code);
    }
  }
  return chord.alt ? '\x1b$text' : text;
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
