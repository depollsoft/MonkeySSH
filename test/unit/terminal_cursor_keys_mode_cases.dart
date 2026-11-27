import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Regression tests for arrow/navigation key encoding under the terminal's
/// cursor-key application mode (DECCKM) vs application keypad mode (DECKPAM).
///
/// Windows remotes (PowerShell/PSReadLine) enable application keypad mode while
/// keeping cursor keys in their normal (CSI) form. Encoding arrows as SS3 in
/// that state made the shell insert the literal `OA`/`OB`… characters instead
/// of cycling through history. Arrow encoding must depend on DECCKM only.
/// Registers tests from terminal_cursor_keys_mode_test.dart.
void registerUnitTerminalCursorKeysModeTests() {
  group('terminal_cursor_keys_mode', () {
    String? emit(Terminal terminal, TerminalKey key) {
      final output = <String>[];
      terminal
        ..onOutput = output.add
        ..keyInput(key);
      return output.isEmpty ? null : output.single;
    }

    group('cursor keys honor DECCKM, not DECKPAM', () {
      test('default (both modes off) emits CSI arrows', () {
        final terminal = Terminal();
        expect(terminal.cursorKeysMode, isFalse);
        expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
        expect(emit(terminal, TerminalKey.arrowDown), '\x1b[B');
        expect(emit(terminal, TerminalKey.arrowRight), '\x1b[C');
        expect(emit(terminal, TerminalKey.arrowLeft), '\x1b[D');
        expect(emit(terminal, TerminalKey.home), '\x1b[H');
        expect(emit(terminal, TerminalKey.end), '\x1b[F');
      });

      test('DECCKM on emits SS3 arrows', () {
        final terminal = Terminal()..write('\x1b[?1h');
        expect(terminal.cursorKeysMode, isTrue);
        expect(emit(terminal, TerminalKey.arrowUp), '\x1bOA');
        expect(emit(terminal, TerminalKey.arrowDown), '\x1bOB');
        expect(emit(terminal, TerminalKey.arrowRight), '\x1bOC');
        expect(emit(terminal, TerminalKey.arrowLeft), '\x1bOD');
        expect(emit(terminal, TerminalKey.home), '\x1bOH');
        expect(emit(terminal, TerminalKey.end), '\x1bOF');
      });

      test('application keypad mode alone keeps CSI arrows', () {
        final terminal = Terminal()..write('\x1b=');
        expect(terminal.appKeypadMode, isTrue);
        expect(terminal.cursorKeysMode, isFalse);
        expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
        expect(emit(terminal, TerminalKey.arrowDown), '\x1b[B');
        expect(emit(terminal, TerminalKey.arrowLeft), '\x1b[D');
        expect(emit(terminal, TerminalKey.home), '\x1b[H');
      });

      test('resetting DECCKM restores CSI arrows while keypad stays on', () {
        // Mirrors an app enabling smkx (`ESC [ ? 1 h ESC =`) then only resetting
        // cursor-key mode: application keypad mode may linger, but arrows must go
        // back to CSI so a plain prompt recognizes them.
        final terminal = Terminal()..write('\x1b[?1h\x1b=\x1b[?1l');
        expect(terminal.appKeypadMode, isTrue);
        expect(terminal.cursorKeysMode, isFalse);
        expect(emit(terminal, TerminalKey.arrowUp), '\x1b[A');
      });

      test('Enter stays CR regardless of keypad mode', () {
        final terminal = Terminal()..write('\x1b=');
        expect(emit(terminal, TerminalKey.enter), '\r');
      });
    });
  });
}
