import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('input methods notify listeners after emitting output', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    var notifications = 0;
    terminal.addListener(() => notifications++);

    expect(terminal.keyInput(TerminalKey.enter), isTrue);
    terminal.textInput('a');

    expect(output, ['\r', 'a']);
    expect(notifications, 2);
  });

  test('paste strips controls and normalizes line endings', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.paste(
      'a\x07\x0cb\x1b[7mc\x1b[200~d\x1b[?25le'
      '\x1b]52;c;AAAA\x07f\x1b_Ga=d\x1b\\g\x1bh\r\nh\ri\n',
    );

    expect(output, ['abcdefg\rh\ri\r']);
  });

  test('bracketed paste wraps sanitized text', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?2004h');
    terminal.paste('a\nb');

    expect(output, ['\x1b[200~a\rb\x1b[201~']);
  });

  test('shift enter emits a newline', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    expect(terminal.keyInput(TerminalKey.enter, shift: true), isTrue);

    expect(output, ['\n']);
  });

  group('cursor keys application mode (DECCKM)', () {
    String? emit(Terminal terminal, TerminalKey key) {
      final output = <String>[];
      terminal.onOutput = output.add;
      terminal.keyInput(key);
      return output.isEmpty ? null : output.single;
    }

    test('arrows emit CSI form by default', () {
      final terminal = Terminal();
      expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
      expect(emit(terminal, TerminalKey.arrowDown), '\x1b[B');
      expect(emit(terminal, TerminalKey.arrowRight), '\x1b[C');
      expect(emit(terminal, TerminalKey.arrowLeft), '\x1b[D');
      expect(emit(terminal, TerminalKey.home), '\x1b[H');
      expect(emit(terminal, TerminalKey.end), '\x1b[F');
    });

    test('DECCKM (CSI ? 1 h) switches arrows to SS3 form', () {
      final terminal = Terminal()..write('\x1b[?1h');
      expect(terminal.cursorKeysMode, isTrue);
      expect(emit(terminal, TerminalKey.arrowUp), '\x1bOA');
      expect(emit(terminal, TerminalKey.arrowDown), '\x1bOB');
      expect(emit(terminal, TerminalKey.arrowRight), '\x1bOC');
      expect(emit(terminal, TerminalKey.arrowLeft), '\x1bOD');
      expect(emit(terminal, TerminalKey.home), '\x1bOH');
      expect(emit(terminal, TerminalKey.end), '\x1bOF');
    });

    test('DECKPAM alone keeps arrows in CSI form', () {
      // Application keypad mode (DECKPAM, `ESC =`) must not turn cursor keys
      // into their application (SS3) form. PowerShell/PSReadLine enables app
      // keypad mode while leaving cursor keys normal; emitting SS3 arrows there
      // made the shell insert the literal characters instead of recalling
      // history.
      final terminal = Terminal()..write('\x1b=');
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
      expect(emit(terminal, TerminalKey.arrowDown), '\x1b[B');
      expect(emit(terminal, TerminalKey.home), '\x1b[H');
    });

    test('resetting DECCKM restores CSI arrows even if keypad stays on', () {
      final terminal = Terminal()..write('\x1b[?1h\x1b=\x1b[?1l');
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
    });
  });
}
