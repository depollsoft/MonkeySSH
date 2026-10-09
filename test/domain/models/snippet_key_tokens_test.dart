import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/snippet_key_tokens.dart';
import 'package:xterm/xterm.dart';

SnippetKeyStep _key(
  TerminalKey key, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  String? character,
}) => SnippetKeyStep(
  SnippetKeyChord(
    key,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    character: character,
  ),
);

void main() {
  group('parseSnippetKeySequence', () {
    test('leaves a plain command as text', () {
      final parsed = parseSnippetKeySequence('docker restart {{name}}');
      expect(parsed.hasActions, isFalse);
      expect(parsed.errors, isEmpty);
      expect(parsed.plainText, 'docker restart {{name}}');
    });

    test('reads keys, modifiers and pauses', () {
      final parsed = parseSnippetKeySequence(
        [
          '{key:esc}{key:ESC}git status{key:Enter}{delay:100}{key:shift+tab}',
          '{delay:250ms}{key:ctrl+c}{key:alt+left}{key:f5}',
        ].join(),
      );
      expect(parsed.errors, isEmpty);
      expect(parsed.hasActions, isTrue);
      expect(parsed.steps, [
        _key(TerminalKey.escape),
        _key(TerminalKey.escape),
        const SnippetTextStep('git status'),
        _key(TerminalKey.enter),
        const SnippetDelayStep(Duration(milliseconds: 100)),
        _key(TerminalKey.tab, shift: true),
        const SnippetDelayStep(Duration(milliseconds: 250)),
        _key(TerminalKey.keyC, ctrl: true, character: 'c'),
        _key(TerminalKey.arrowLeft, alt: true),
        _key(TerminalKey.f5),
      ]);
    });

    test('accepts modifier aliases and punctuation keys', () {
      final parsed = parseSnippetKeySequence(
        r'{key:control+option+shift+x}{key:meta+[}{key:ctrl+\}{key:pgdn}',
      );
      expect(parsed.errors, isEmpty);
      expect(parsed.steps, [
        _key(
          TerminalKey.keyX,
          ctrl: true,
          alt: true,
          shift: true,
          character: 'x',
        ),
        _key(TerminalKey.bracketLeft, alt: true, character: '['),
        _key(TerminalKey.backslash, ctrl: true, character: r'\'),
        _key(TerminalKey.pageDown),
      ]);
    });

    test('reports unknown keys and out-of-range delays', () {
      final parsed = parseSnippetKeySequence(
        'a{key:hyper}b{key:cmd+c}{key:ctrl+}{delay:0}{delay:5001}{delay:x}',
      );
      expect(parsed.errors, [
        'Unknown key: {key:hyper}',
        'Unknown key: {key:cmd+c}',
        'Unknown key: {key:ctrl+}',
        'Delays take 1 to 5000 ms: {delay:0}',
        'Delays take 1 to 5000 ms: {delay:5001}',
        'Delays take 1 to 5000 ms: {delay:x}',
      ]);
      expect(parseSnippetKeySequence('{delay:5000}').steps, [
        const SnippetDelayStep(Duration(seconds: 5)),
      ]);
    });

    test('a backslash types a token as text', () {
      expect(parseSnippetKeySequence(r'echo \{key:esc} \{delay:9}').steps, [
        const SnippetTextStep('echo {key:esc} {delay:9}'),
      ]);
      // Two backslashes type one and keep the token.
      expect(parseSnippetKeySequence(r'a\\{key:esc}').steps, [
        const SnippetTextStep(r'a\'),
        _key(TerminalKey.escape),
      ]);
      expect(parseSnippetKeySequence(r'a\\\{key:esc}').steps, [
        const SnippetTextStep(r'a\{key:esc}'),
      ]);
      // Backslashes elsewhere are left alone.
      expect(
        parseSnippetKeySequence(r'find . -exec rm {} \;').plainText,
        r'find . -exec rm {} \;',
      );
    });

    test('incomplete tokens stay text', () {
      final parsed = parseSnippetKeySequence('{key:esc {key: } {delay:}x');
      expect(parsed.hasActions, isFalse);
      expect(parsed.plainText, '{key:esc {key: } {delay:}x');
    });

    test('renders review text with Enter as a line break', () {
      final parsed = parseSnippetKeySequence(
        '{key:ctrl+c}ls{delay:50}{key:enter}{key:shift+enter}',
      );
      expect(parsed.reviewText, '{key:ctrl+c}ls\n\n');
    });

    test('fills variables in text only', () {
      final parsed = parseSnippetKeySequence('echo {{name}}{key:enter}')
          .withVariables({'name': '{key:ctrl+c}'});
      expect(parsed.steps, [
        const SnippetTextStep('echo {key:ctrl+c}'),
        _key(TerminalKey.enter),
      ]);
    });
  });

  group('text that only looks like a token', () {
    test('a token after a dollar sign is shell syntax', () {
      for (final command in [
        r'echo ${key:1}',
        r'echo ${KEY:-x} ${delay:-1}',
        r'echo $\{key:esc}',
      ]) {
        final parsed = parseSnippetKeySequence(command);
        expect(parsed.hasActions, isFalse, reason: command);
        expect(parsed.errors, isEmpty, reason: command);
      }
      expect(
        parseSnippetKeySequence(r'echo ${key:1}').plainText,
        r'echo ${key:1}',
      );
    });

    test('token names are lower case only', () {
      final parsed = parseSnippetKeySequence('{KEY:1} {Delay:500}');
      expect(parsed.hasActions, isFalse);
      expect(parsed.plainText, '{KEY:1} {Delay:500}');
    });

    test('escaping old snippets keeps their text', () {
      for (final command in [
        'db.c.createIndex({key:1})',
        'jq "{key:.}"',
        'run({delay:500})',
        r'a\{key:esc} b\\{key:esc} c\\\{delay:9}',
        r'echo ${key:1} {key:esc}',
        'plain text',
        '',
      ]) {
        final escaped = escapeSnippetKeyTokens(command);
        final parsed = parseSnippetKeySequence(escaped);
        expect(parsed.hasActions, isFalse, reason: command);
        expect(parsed.errors, isEmpty, reason: command);
        expect(parsed.plainText, command, reason: command);
      }
      expect(escapeSnippetKeyTokens('f({key:1})'), r'f(\{key:1})');
      expect(escapeSnippetKeyTokens('plain'), 'plain');
    });
  });

  group('shifted characters', () {
    test('capital letters and shifted symbols are Shift plus the key', () {
      expect(
        parseSnippetKeyChord('G'),
        const SnippetKeyChord(TerminalKey.keyG, shift: true, character: 'g'),
      );
      expect(
        parseSnippetKeyChord('ctrl+C'),
        const SnippetKeyChord(TerminalKey.keyC, ctrl: true, character: 'c'),
      );
      expect(
        parseSnippetKeyChord('?'),
        const SnippetKeyChord(TerminalKey.slash, shift: true, character: '/'),
      );
      expect(
        parseSnippetKeyChord('ctrl+_'),
        const SnippetKeyChord(
          TerminalKey.minus,
          ctrl: true,
          shift: true,
          character: '-',
        ),
      );
      expect(
        parseSnippetKeyChord('+'),
        const SnippetKeyChord(TerminalKey.equal, shift: true, character: '='),
      );
      expect(
        parseSnippetKeyChord('alt++'),
        const SnippetKeyChord(
          TerminalKey.equal,
          alt: true,
          shift: true,
          character: '=',
        ),
      );
    });

    test('Ctrl chords without a terminal code are errors', () {
      for (final token in ['{key:ctrl+1}', '{key:ctrl+,}', '{key:ctrl+.}']) {
        expect(parseSnippetKeySequence(token).errors, [
          'Ctrl has no terminal code with this key: $token',
        ]);
      }
      for (final token in [
        '{key:ctrl+@}',
        '{key:ctrl+[}',
        '{key:ctrl+space}',
        '{key:ctrl+?}',
      ]) {
        expect(parseSnippetKeySequence(token).errors, isEmpty, reason: token);
      }
    });
  });

  test('review text shows every key that submits a line as a line break', () {
    expect(
      parseSnippetKeySequence(
        'a{key:ctrl+m}b{key:ctrl+j}c{key:shift+enter}d{key:ctrl+c}',
      ).reviewText,
      'a\nb\nc\nd{key:ctrl+c}',
    );
  });

  group('round 2', () {
    test('literal text undoes the upgrade escapes but keeps key snippets', () {
      expect(
        snippetLiteralText(r"mongosh --eval 'db.c.find(\{key:1})'"),
        "mongosh --eval 'db.c.find({key:1})'",
      );
      expect(snippetLiteralText('plain'), 'plain');
      expect(snippetLiteralText('claude{key:enter}'), 'claude{key:enter}');
      expect(snippetLiteralText('{key:nope}'), '{key:nope}');
    });

    test('warns when a valid token after a dollar sign stays text', () {
      final parsed = parseSnippetKeySequence(r'/foo${key:enter}');
      expect(parsed.hasActions, isFalse);
      expect(parsed.warnings, hasLength(1));
      expect(
        parsed.warnings.single,
        r'${key:enter} is typed as text, like shell syntax. To type $ and '
        r'then press the key, write {key:$}{key:enter}.',
      );
      // Shell syntax that is not a token gets no warning.
      expect(parseSnippetKeySequence(r'${KEY:-x} ${key:-1}').warnings, isEmpty);
      // The suggested form works.
      expect(parseSnippetKeySequence(r'/foo{key:$}{key:enter}').steps, [
        const SnippetTextStep('/foo'),
        const SnippetKeyStep(
          SnippetKeyChord(TerminalKey.digit4, shift: true, character: '4'),
        ),
        const SnippetKeyStep(SnippetKeyChord(TerminalKey.enter)),
      ]);
    });

    test('a literal sequence has no tokens at all', () {
      final literal = SnippetKeySequence.literal('{key:esc}');
      expect(literal.hasActions, isFalse);
      expect(literal.plainText, '{key:esc}');
    });
  });

  test('snippets with any key token need a terminal', () {
    expect(parseSnippetKeySequence('echo hi').needsTerminal, isFalse);
    expect(parseSnippetKeySequence(r'echo \{key:esc}').needsTerminal, isFalse);
    expect(parseSnippetKeySequence('/clear{key:enter}').needsTerminal, isTrue);
    expect(parseSnippetKeySequence('{delay:10}').needsTerminal, isTrue);
    expect(parseSnippetKeySequence('{key:nope}').needsTerminal, isTrue);
  });

  test('chords print as canonical tokens', () {
    expect(parseSnippetKeyChord('Control+C')!.token, '{key:ctrl+c}');
    expect(parseSnippetKeyChord('shift+tab')!.token, '{key:shift+tab}');
    expect(parseSnippetKeyChord('opt+Left')!.token, '{key:alt+left}');
    expect(parseSnippetKeyChord('escape')!.token, '{key:esc}');
    expect(parseSnippetKeyChord('ctrl+shift'), isNull);
  });
}
