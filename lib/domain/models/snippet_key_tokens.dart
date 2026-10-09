import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'snippet_variables.dart';

/// Longest pause one `{delay:N}` token may ask for.
const kSnippetMaxDelay = Duration(milliseconds: 5000);

/// `{key:...}` and `{delay:...}` tokens in a snippet command.
final _tokenPattern = RegExp(
  r'\{(key|delay):([^{}\s]+)\}',
  caseSensitive: false,
);

/// A key and the modifiers held with it, such as Ctrl+C or Shift+Tab.
@immutable
class SnippetKeyChord {
  /// Creates a chord for [key].
  const SnippetKeyChord(
    this.key, {
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.character,
  });

  /// The key pressed.
  final TerminalKey key;

  /// Whether Ctrl is held.
  final bool ctrl;

  /// Whether Alt (Option, Meta) is held.
  final bool alt;

  /// Whether Shift is held.
  final bool shift;

  /// The unshifted character the key types, for letter, digit, space and
  /// punctuation keys; null for named keys such as Esc or Up.
  final String? character;

  /// The token that sends this chord, written the canonical way, such as
  /// `{key:ctrl+c}`.
  String get token {
    final parts = [
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      _canonicalKeyNames[key] ?? character ?? key.name,
    ];
    return '{key:${parts.join('+')}}';
  }

  @override
  bool operator ==(Object other) =>
      other is SnippetKeyChord &&
      other.key == key &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift &&
      other.character == character;

  @override
  int get hashCode => Object.hash(key, ctrl, alt, shift, character);

  @override
  String toString() => 'SnippetKeyChord($token)';
}

/// One step of a parsed snippet.
@immutable
sealed class SnippetStep {
  const SnippetStep();
}

/// Text typed as it is written.
final class SnippetTextStep extends SnippetStep {
  /// Creates a text step.
  const SnippetTextStep(this.text);

  /// The text.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SnippetTextStep && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SnippetTextStep(${text.length} chars)';
}

/// A key press from a `{key:...}` token.
final class SnippetKeyStep extends SnippetStep {
  /// Creates a key step.
  const SnippetKeyStep(this.chord);

  /// The key and its modifiers.
  final SnippetKeyChord chord;

  @override
  bool operator ==(Object other) =>
      other is SnippetKeyStep && other.chord == chord;

  @override
  int get hashCode => chord.hashCode;

  @override
  String toString() => 'SnippetKeyStep(${chord.token})';
}

/// A pause from a `{delay:N}` token.
final class SnippetDelayStep extends SnippetStep {
  /// Creates a delay step.
  const SnippetDelayStep(this.duration);

  /// How long to wait.
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is SnippetDelayStep && other.duration == duration;

  @override
  int get hashCode => duration.hashCode;

  @override
  String toString() => 'SnippetDelayStep(${duration.inMilliseconds} ms)';
}

/// A snippet command split into text, key presses and pauses.
@immutable
class SnippetKeySequence {
  /// Creates a parsed snippet.
  const SnippetKeySequence(this.steps, {this.errors = const <String>[]});

  /// The steps, in order. Adjacent text is merged into one step.
  final List<SnippetStep> steps;

  /// Why tokens could not be read, one message per bad token. A snippet with
  /// errors must not be sent.
  final List<String> errors;

  /// Whether the snippet has key presses or pauses, so it cannot be pasted
  /// as plain text.
  bool get hasActions => steps.any((step) => step is! SnippetTextStep);

  /// Whether the snippet has a key or delay token, valid or not, so it only
  /// makes sense in a terminal. A chat draft holds text and has nowhere to
  /// press a key.
  bool get needsTerminal => hasActions || errors.isNotEmpty;

  /// The snippet's text with key and delay tokens left out. For a snippet
  /// without [hasActions] this is the text to paste, with escaped tokens
  /// already turned into their literal text.
  String get plainText => [
    for (final step in steps)
      if (step is SnippetTextStep) step.text,
  ].join();

  /// The snippet as a command line would see it, for review before sending:
  /// Enter becomes a line break, other keys show as their tokens and pauses
  /// are left out.
  String get reviewText => [
    for (final step in steps)
      switch (step) {
        SnippetTextStep(:final text) => text,
        SnippetKeyStep(:final chord) =>
          chord.key == TerminalKey.enter &&
                  !chord.ctrl &&
                  !chord.alt &&
                  !chord.shift
              ? '\n'
              : chord.token,
        SnippetDelayStep() => '',
      },
  ].join();

  /// Fills `{{name}}` placeholders in the text steps from [values].
  ///
  /// Only the snippet's own text is searched, so a value that happens to look
  /// like a key token is typed as text and never pressed as a key.
  SnippetKeySequence withVariables(Map<String, String> values) {
    if (values.isEmpty) {
      return this;
    }
    return SnippetKeySequence([
      for (final step in steps)
        if (step is SnippetTextStep)
          SnippetTextStep(
            step.text.replaceAllMapped(
              snippetVariablePattern,
              (match) => values[match.group(1)] ?? match.group(0)!,
            ),
          )
        else
          step,
    ], errors: errors);
  }
}

/// Splits [command] into text, `{key:...}` presses and `{delay:N}` pauses.
///
/// - `{key:esc}`, `{key:ctrl+c}`, `{key:shift+tab}`, `{key:enter}`: a key
///   with optional `ctrl`, `alt` (or `option`, `meta`) and `shift` modifiers
///   joined by `+`. Keys are named keys (`esc`, `tab`, `enter`, `backspace`,
///   `delete`, `insert`, `space`, arrows `up` `down` `left` `right`, `home`,
///   `end`, `pageup`, `pagedown`, `f1`-`f12`) or a single letter, digit or
///   punctuation character. Names are case-insensitive.
/// - `{delay:100}` or `{delay:100ms}`: a pause of 1 to 5000 milliseconds.
/// - A backslash before a token types the token as text: `\{key:esc}` types
///   `{key:esc}`. Two backslashes type one backslash and keep the token.
///
/// A token with an unknown key or an out-of-range delay is reported in
/// [SnippetKeySequence.errors]. Text that is not a complete token, such as
/// `{key:` on its own, is left as text.
SnippetKeySequence parseSnippetKeySequence(String command) {
  final steps = <SnippetStep>[];
  final errors = <String>[];
  final text = StringBuffer();

  void flushText() {
    if (text.isEmpty) {
      return;
    }
    steps.add(SnippetTextStep(text.toString()));
    text.clear();
  }

  var cursor = 0;
  for (final match in _tokenPattern.allMatches(command)) {
    var backslashes = 0;
    while (match.start - backslashes - 1 >= cursor &&
        command.codeUnitAt(match.start - backslashes - 1) == 0x5C) {
      backslashes++;
    }
    text
      ..write(command.substring(cursor, match.start - backslashes))
      ..write(r'\' * (backslashes ~/ 2));
    cursor = match.end;
    if (backslashes.isOdd) {
      text.write(match.group(0));
      continue;
    }

    final kind = match.group(1)!.toLowerCase();
    final argument = match.group(2)!;
    if (kind == 'delay') {
      final delay = _parseDelay(argument);
      if (delay == null) {
        errors.add(
          'Delays take 1 to ${kSnippetMaxDelay.inMilliseconds} ms: '
          '${match.group(0)}',
        );
        continue;
      }
      flushText();
      steps.add(SnippetDelayStep(delay));
    } else {
      final chord = parseSnippetKeyChord(argument);
      if (chord == null) {
        errors.add('Unknown key: ${match.group(0)}');
        continue;
      }
      flushText();
      steps.add(SnippetKeyStep(chord));
    }
  }
  text.write(command.substring(cursor));
  flushText();
  return SnippetKeySequence(
    List.unmodifiable(steps),
    errors: List.unmodifiable(errors),
  );
}

Duration? _parseDelay(String argument) {
  var digits = argument.toLowerCase();
  if (digits.endsWith('ms')) {
    digits = digits.substring(0, digits.length - 2);
  }
  if (digits.isEmpty || digits.length > 6 || !_digitsOnly.hasMatch(digits)) {
    return null;
  }
  final milliseconds = int.parse(digits);
  if (milliseconds < 1 || milliseconds > kSnippetMaxDelay.inMilliseconds) {
    return null;
  }
  return Duration(milliseconds: milliseconds);
}

final _digitsOnly = RegExp(r'^[0-9]+$');

/// Reads a chord such as `ctrl+c` or `shift+tab`; null when it names no key.
SnippetKeyChord? parseSnippetKeyChord(String chord) {
  if (chord.isEmpty) {
    return null;
  }
  final parts = chord.split('+');
  if (parts.any((part) => part.isEmpty)) {
    return null;
  }
  var ctrl = false;
  var alt = false;
  var shift = false;
  for (final modifier in parts.take(parts.length - 1)) {
    switch (modifier.toLowerCase()) {
      case 'ctrl' || 'control':
        ctrl = true;
      case 'alt' || 'option' || 'opt' || 'meta':
        alt = true;
      case 'shift':
        shift = true;
      default:
        return null;
    }
  }
  final name = parts.last;
  final named = _namedKeys[name.toLowerCase()];
  if (named != null) {
    return SnippetKeyChord(named, ctrl: ctrl, alt: alt, shift: shift);
  }
  if (name.length != 1) {
    return null;
  }
  final character = name.toLowerCase();
  final key = _characterKeys[character];
  if (key == null) {
    return null;
  }
  return SnippetKeyChord(
    key,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    character: character,
  );
}

const _namedKeys = <String, TerminalKey>{
  'esc': TerminalKey.escape,
  'escape': TerminalKey.escape,
  'enter': TerminalKey.enter,
  'return': TerminalKey.enter,
  'tab': TerminalKey.tab,
  'backspace': TerminalKey.backspace,
  'bs': TerminalKey.backspace,
  'delete': TerminalKey.delete,
  'del': TerminalKey.delete,
  'insert': TerminalKey.insert,
  'ins': TerminalKey.insert,
  'space': TerminalKey.space,
  'up': TerminalKey.arrowUp,
  'down': TerminalKey.arrowDown,
  'left': TerminalKey.arrowLeft,
  'right': TerminalKey.arrowRight,
  'home': TerminalKey.home,
  'end': TerminalKey.end,
  'pageup': TerminalKey.pageUp,
  'pgup': TerminalKey.pageUp,
  'pagedown': TerminalKey.pageDown,
  'pgdn': TerminalKey.pageDown,
  'f1': TerminalKey.f1,
  'f2': TerminalKey.f2,
  'f3': TerminalKey.f3,
  'f4': TerminalKey.f4,
  'f5': TerminalKey.f5,
  'f6': TerminalKey.f6,
  'f7': TerminalKey.f7,
  'f8': TerminalKey.f8,
  'f9': TerminalKey.f9,
  'f10': TerminalKey.f10,
  'f11': TerminalKey.f11,
  'f12': TerminalKey.f12,
};

const _canonicalKeyNames = <TerminalKey, String>{
  TerminalKey.escape: 'esc',
  TerminalKey.enter: 'enter',
  TerminalKey.tab: 'tab',
  TerminalKey.backspace: 'backspace',
  TerminalKey.delete: 'delete',
  TerminalKey.insert: 'insert',
  TerminalKey.space: 'space',
  TerminalKey.arrowUp: 'up',
  TerminalKey.arrowDown: 'down',
  TerminalKey.arrowLeft: 'left',
  TerminalKey.arrowRight: 'right',
  TerminalKey.home: 'home',
  TerminalKey.end: 'end',
  TerminalKey.pageUp: 'pageup',
  TerminalKey.pageDown: 'pagedown',
  TerminalKey.f1: 'f1',
  TerminalKey.f2: 'f2',
  TerminalKey.f3: 'f3',
  TerminalKey.f4: 'f4',
  TerminalKey.f5: 'f5',
  TerminalKey.f6: 'f6',
  TerminalKey.f7: 'f7',
  TerminalKey.f8: 'f8',
  TerminalKey.f9: 'f9',
  TerminalKey.f10: 'f10',
  TerminalKey.f11: 'f11',
  TerminalKey.f12: 'f12',
};

final Map<String, TerminalKey> _characterKeys = {
  for (var index = 0; index < 26; index++)
    String.fromCharCode(0x61 + index):
        TerminalKey.values[TerminalKey.keyA.index + index],
  '1': TerminalKey.digit1,
  '2': TerminalKey.digit2,
  '3': TerminalKey.digit3,
  '4': TerminalKey.digit4,
  '5': TerminalKey.digit5,
  '6': TerminalKey.digit6,
  '7': TerminalKey.digit7,
  '8': TerminalKey.digit8,
  '9': TerminalKey.digit9,
  '0': TerminalKey.digit0,
  '-': TerminalKey.minus,
  '=': TerminalKey.equal,
  '[': TerminalKey.bracketLeft,
  ']': TerminalKey.bracketRight,
  r'\': TerminalKey.backslash,
  ';': TerminalKey.semicolon,
  "'": TerminalKey.quote,
  '`': TerminalKey.backquote,
  ',': TerminalKey.comma,
  '.': TerminalKey.period,
  '/': TerminalKey.slash,
};
