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
      expect(parsed.reviewText, '{key:ctrl+c}ls\n{key:shift+enter}');
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
