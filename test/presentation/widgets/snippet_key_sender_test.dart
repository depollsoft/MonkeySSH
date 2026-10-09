import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/snippet_key_tokens.dart';
import 'package:monkeyssh/presentation/widgets/snippet_key_sender.dart';
import 'package:monkeyssh/presentation/widgets/terminal_key_input.dart';
import 'package:xterm/xterm.dart';

({Terminal terminal, List<String> writes, List<bool> enterFlags}) _terminal({
  String setup = '',
}) {
  final writes = <String>[];
  final enterFlags = <bool>[];
  final terminal = Terminal()
    ..write(setup)
    ..onOutput = (data) {
      writes.add(data);
      enterFlags.add(isWritingTerminalEnterKey);
    };
  return (terminal: terminal, writes: writes, enterFlags: enterFlags);
}

String _send(String token, {String setup = ''}) {
  final target = _terminal(setup: setup);
  final chord = parseSnippetKeyChord(token)!;
  expect(sendSnippetKey(target.terminal, chord), isTrue, reason: token);
  return target.writes.join();
}

String _hardwareKey(TerminalKey key, {bool alt = false}) {
  final target = _terminal();
  target.terminal.keyInput(key, alt: alt);
  return target.writes.join();
}

// Claude Code and Codex push `CSI > 5 u`: disambiguate plus alternate keys.
const _kittyAgent = '\x1b[>5u';

void main() {
  group('sendSnippetKey', () {
    test('uses legacy encodings when no kitty flags are set', () {
      expect(_send('esc'), '\x1b');
      expect(_send('shift+tab'), '\x1b[Z');
      expect(_send('tab'), '\t');
      expect(_send('enter'), '\r');
      expect(_send('ctrl+c'), '\x03');
      expect(_send('ctrl+shift+c'), '\x03');
      expect(_send('alt+b'), '\x1bb');
      expect(_send('alt+shift+b'), '\x1bB');
      expect(_send('ctrl+['), '\x1b');
      expect(_send('ctrl+space'), '\x00');
      expect(_send('up'), '\x1b[A');
      expect(_send('ctrl+left'), '\x1b[1;5D');
      expect(_send('f5'), '\x1b[15~');
      expect(_send('backspace'), '\x7f');
    });

    test('follows cursor-key application mode', () {
      expect(_send('up', setup: '\x1b[?1h'), '\x1bOA');
    });

    test('adds Escape for Alt the key table has no form for', () {
      expect(_send('alt+esc'), '\x1b\x1b');
      // Keys the table does know with Alt match a hardware keyboard.
      expect(_send('alt+left'), _hardwareKey(TerminalKey.arrowLeft, alt: true));
    });

    test('uses CSI u once a program pushes kitty flags', () {
      expect(_send('esc', setup: _kittyAgent), '\x1b[27u');
      expect(_send('shift+tab', setup: _kittyAgent), '\x1b[9;2u');
      expect(_send('ctrl+c', setup: '\x1b[>1u'), '\x1b[99;5u');
      expect(_send('enter', setup: _kittyAgent), '\r');
    });

    test('marks Enter so the pacer keeps it apart from text', () {
      final target = _terminal();
      sendSnippetKey(target.terminal, parseSnippetKeyChord('enter')!);
      expect(target.enterFlags, [true]);
    });
  });

  group('sendSnippetKeySequence', () {
    test('types text, presses keys and waits', () async {
      final target = _terminal();
      final waits = <Duration>[];
      final outcome = await sendSnippetKeySequence(
        target.terminal,
        parseSnippetKeySequence('{key:esc}{key:esc}:wq{delay:40}{key:enter}'),
        canContinue: () => true,
        wait: (duration) async => waits.add(duration),
      );

      expect(outcome, SnippetSendOutcome.completed);
      expect(target.writes, ['\x1b', '\x1b', ':wq', '\r']);
      expect(target.enterFlags, [false, false, false, true]);
      // A bare Escape settles before the next key; the explicit delay follows.
      expect(waits, [
        kSnippetEscapeSettle,
        kSnippetEscapeSettle,
        const Duration(milliseconds: 40),
      ]);
    });

    test('sends line breaks as Enter and drops control characters', () async {
      final target = _terminal();
      await sendSnippetKeySequence(
        target.terminal,
        parseSnippetKeySequence('one\x07\ntwo{key:enter}')
            .withVariables(const {}),
        canContinue: () => true,
        wait: (_) async {},
      );
      expect(target.writes, ['one', '\r', 'two', '\r']);
      expect(target.enterFlags, [false, true, false, true]);
    });

    test('never sends a step after it is told to stop', () async {
      final target = _terminal();
      var allowed = true;
      final outcome = await sendSnippetKeySequence(
        target.terminal,
        parseSnippetKeySequence('{key:ctrl+c}{delay:500}{key:shift+tab}'),
        canContinue: () => allowed,
        wait: (_) async {
          // The connection drops, or the window switches, during the pause.
          allowed = false;
        },
      );

      expect(outcome, SnippetSendOutcome.stopped);
      expect(target.writes, ['\x03']);
    });

    test('a bare Escape at the end needs no settle time', () async {
      final target = _terminal();
      final waits = <Duration>[];
      await sendSnippetKeySequence(
        target.terminal,
        parseSnippetKeySequence('x{key:esc}'),
        canContinue: () => true,
        wait: (duration) async => waits.add(duration),
      );
      expect(waits, isEmpty);
    });
  });
}
