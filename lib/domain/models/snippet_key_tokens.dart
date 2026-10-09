import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'snippet_variables.dart';

/// Longest pause one `{delay:N}` token may ask for.
const kSnippetMaxDelay = Duration(milliseconds: 5000);

final _lineBreaks = RegExp(r'\r\n|\r|\n');

/// `{key:...}` and `{delay:...}` tokens in a snippet command. The `key` and
/// `delay` names are lower case only, so code such as `{KEY:1}` stays text.
final _tokenPattern = RegExp(r'\{(key|delay):([^{}\s]+)\}');

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

  /// Whether the chord submits a line in a shell: Enter with any modifiers,
  /// or Ctrl+M and Ctrl+J, which send the same bytes.
  bool get submitsLine =>
      key == TerminalKey.enter ||
      (ctrl && (character == 'm' || character == 'j'));

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
  const SnippetKeySequence(
    this.steps, {
    this.errors = const <String>[],
    this.warnings = const <String>[],
  });

  /// A snippet read as plain text, with no tokens at all: what a snippet is
  /// while the key-token upgrade of stored snippets has not run.
  factory SnippetKeySequence.literal(String text) =>
      SnippetKeySequence([if (text.isNotEmpty) SnippetTextStep(text)]);

  /// The steps, in order. Adjacent text is merged into one step.
  final List<SnippetStep> steps;

  /// Why tokens could not be read, one message per bad token. A snippet with
  /// errors must not be sent.
  final List<String> errors;

  /// Things that are allowed but probably not what was meant, such as a key
  /// token after `$`, which stays text. They do not stop the snippet.
  final List<String> warnings;

  /// Whether the snippet has key presses or pauses, so it cannot be pasted
  /// as plain text.
  bool get hasActions => steps.any((step) => step is! SnippetTextStep);

  /// Whether the snippet has a key or delay token, valid or not, so it only
  /// makes sense in a terminal. A chat draft holds text and has nowhere to
  /// press a key.
  bool get needsTerminal => hasActions || errors.isNotEmpty;

  /// Whether text is typed after a line was submitted (by an Enter-like key
  /// or a line break in the text): a second command line, as opposed to one
  /// command followed by the key that runs it, or by more keys.
  bool get typesAfterSubmit {
    var submitted = false;
    for (final step in steps) {
      switch (step) {
        case SnippetKeyStep(:final chord) when chord.submitsLine:
          submitted = true;
        case SnippetTextStep(:final text):
          for (final (index, line) in text.split(_lineBreaks).indexed) {
            if (index > 0) {
              submitted = true;
            }
            if (submitted && line.trim().isNotEmpty) {
              return true;
            }
          }
        default:
          break;
      }
    }
    return false;
  }

  /// The snippet's text with key and delay tokens left out. For a snippet
  /// without [hasActions] this is the text to paste, with escaped tokens
  /// already turned into their literal text.
  String get plainText => [
    for (final step in steps)
      if (step is SnippetTextStep) step.text,
  ].join();

  /// The snippet as a command line would see it, for review before sending:
  /// keys that submit a line (Enter, Ctrl+M, Ctrl+J) become a line break,
  /// other keys show as their tokens and pauses are left out.
  String get reviewText => [
    for (final step in steps)
      switch (step) {
        SnippetTextStep(:final text) => text,
        SnippetKeyStep(:final chord) => chord.submitsLine ? '\n' : chord.token,
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
    return SnippetKeySequence(
      [
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
      ],
      errors: errors,
      warnings: warnings,
    );
  }
}

/// Splits [command] into text, `{key:...}` presses and `{delay:N}` pauses.
///
/// - `{key:esc}`, `{key:ctrl+c}`, `{key:shift+tab}`, `{key:enter}`: a key
///   with optional `ctrl`, `alt` (or `option`, `meta`) and `shift` modifiers
///   joined by `+`. Keys are named keys (`esc`, `tab`, `enter`, `backspace`,
///   `delete`, `insert`, `space`, arrows `up` `down` `left` `right`, `home`,
///   `end`, `pageup`, `pagedown`, `f1`-`f12`) or a single character. Named
///   keys ignore case. A shifted symbol such as `?` or `+` means Shift plus
///   its key on a US layout, and so does a capital letter on its own:
///   `{key:G}` is Shift+G, while `{key:ctrl+C}` is still Ctrl+C.
/// - `{delay:100}` or `{delay:100ms}`: a pause of 1 to 5000 milliseconds.
/// - A backslash before a token types the token as text: `\{key:esc}` types
///   `{key:esc}`. Two backslashes type one backslash and keep the token.
/// - A token right after `$` is shell syntax (`${key:1}`, `${delay:-1}`), not
///   a key, and stays text.
///
/// A token with an unknown key, a Ctrl chord a terminal has no code for, or
/// an out-of-range delay is reported in [SnippetKeySequence.errors]. Text that
/// is not a complete token, such as `{key:` on its own or `{key: esc}` with a
/// space, is left as text.
SnippetKeySequence parseSnippetKeySequence(String command) {
  final steps = <SnippetStep>[];
  final errors = <String>[];
  final warnings = <String>[];
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
    if (_followsDollar(command, match)) {
      if (_isValidToken(match)) {
        final token = match.group(0)!;
        warnings.add(
          '\$$token is typed as text, like shell syntax. To type \$ and '
          'then press the key, write {key:\$}$token.',
        );
      }
      continue;
    }
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

    final kind = match.group(1)!;
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
      if (chord.ctrl &&
          chord.character != null &&
          snippetControlCode(chord.character!, shift: chord.shift) == null) {
        errors.add(
          'Ctrl has no terminal code with this key: ${match.group(0)}',
        );
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
    warnings: List.unmodifiable(warnings),
  );
}

bool _isValidToken(Match match) => match.group(1) == 'delay'
    ? _parseDelay(match.group(2)!) != null
    : parseSnippetKeyChord(match.group(2)!) != null;

/// The text a consumer that cannot press keys should use for a snippet:
/// auto-connect, a cached auto-connect command, or Copy.
///
/// A snippet without key or delay tokens returns its text with escaped
/// tokens turned back into literal text, so a snippet the key-token upgrade
/// escaped still reads exactly as it did. A snippet with tokens returns its
/// stored text unchanged; such a snippet only does what it says in a
/// terminal.
String snippetLiteralText(String command) {
  final parsed = parseSnippetKeySequence(command);
  return parsed.needsTerminal ? command : parsed.plainText;
}

bool _followsDollar(String command, Match match) =>
    match.start > 0 && command.codeUnitAt(match.start - 1) == 0x24;

/// Rewrites [command], written before snippets had key tokens, so that it
/// still reads as the same text: every `{key:...}` or `{delay:...}` that would
/// now be a token gets a backslash, and the backslashes already in front of
/// it are doubled.
///
/// `parseSnippetKeySequence(escapeSnippetKeyTokens(text)).plainText` is
/// `text` for any [command].
String escapeSnippetKeyTokens(String command) {
  final out = StringBuffer();
  var cursor = 0;
  for (final match in _tokenPattern.allMatches(command)) {
    if (_followsDollar(command, match)) {
      continue;
    }
    var backslashes = 0;
    while (match.start - backslashes - 1 >= cursor &&
        command.codeUnitAt(match.start - backslashes - 1) == 0x5C) {
      backslashes++;
    }
    out
      ..write(command.substring(cursor, match.start - backslashes))
      ..write(r'\' * (backslashes * 2 + 1))
      ..write(match.group(0));
    cursor = match.end;
  }
  out.write(command.substring(cursor));
  return out.toString();
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
  // `+` joins modifiers, so the plus key itself is the last `+`: `{key:+}`
  // or `{key:ctrl++}`.
  final List<String> parts;
  if (chord == '+') {
    parts = ['+'];
  } else if (chord.endsWith('++')) {
    parts = [...chord.substring(0, chord.length - 2).split('+'), '+'];
  } else {
    parts = chord.split('+');
  }
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
  // A shifted symbol is Shift plus the key under it. A capital letter is
  // Shift only on its own (`{key:G}`): with Ctrl or Alt it is the usual way
  // to write the chord, so `{key:ctrl+C}` stays Ctrl+C.
  var character = name;
  final unshifted = _unshiftedCharacters[character];
  if (unshifted != null) {
    character = unshifted;
    shift = true;
  } else if (character.toLowerCase() != character) {
    character = character.toLowerCase();
    shift = shift || (!ctrl && !alt);
  }
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

/// What a US keyboard types for [character] with Shift held: the upper-case
/// letter or the shifted symbol. Characters without a shifted form are
/// returned unchanged.
String snippetShiftedCharacter(String character) =>
    _shiftedCharacters[character] ?? character.toUpperCase();

/// The control byte a terminal sends for Ctrl plus the key that types
/// [character], following xterm: letters map to 1-26, and Space and a few
/// digit and punctuation keys to the remaining C0 codes. Null when there is
/// none, as for Ctrl+1.
int? snippetControlCode(String character, {bool shift = false}) {
  final unit = character.codeUnitAt(0);
  if (unit >= 0x61 && unit <= 0x7A) {
    return unit - 0x60;
  }
  if (shift && character == '/') {
    // Ctrl+? is Delete.
    return 0x7F;
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

const _shiftedCharacters = <String, String>{
  '1': '!',
  '2': '@',
  '3': '#',
  '4': r'$',
  '5': '%',
  '6': '^',
  '7': '&',
  '8': '*',
  '9': '(',
  '0': ')',
  '-': '_',
  '=': '+',
  '[': '{',
  ']': '}',
  r'\': '|',
  ';': ':',
  "'": '"',
  '`': '~',
  ',': '<',
  '.': '>',
  '/': '?',
};

final _unshiftedCharacters = <String, String>{
  for (final entry in _shiftedCharacters.entries) entry.value: entry.key,
};

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
