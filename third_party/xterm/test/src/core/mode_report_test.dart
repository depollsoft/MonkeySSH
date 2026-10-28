import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

({Terminal terminal, List<String> output}) _terminal() {
  final output = <String>[];
  final terminal = Terminal(maxLines: 100)..onOutput = output.add;
  return (terminal: terminal, output: output);
}

String _decQuery(Terminal terminal, List<String> output, int mode) {
  output.clear();
  terminal.write('\x1b[?$mode\$p');
  expect(output, hasLength(1), reason: 'one reply for ?$mode');
  return output.single;
}

void main() {
  group('DECRQM for DEC private modes', () {
    test('answers every tracked mode with its live state', () {
      final (:terminal, :output) = _terminal();
      // Mode, the sequence that changes it, and its power-up state.
      const cases = <(int, String, int)>[
        (1, '\x1b[?1h', 2),
        (5, '\x1b[?5h', 2),
        (6, '\x1b[?6h', 2),
        (7, '\x1b[?7l', 1),
        (9, '\x1b[?9h', 2),
        (12, '\x1b[?12h', 2),
        (25, '\x1b[?25l', 1),
        (66, '\x1b[?66h', 2),
        (67, '\x1b[?67h', 2),
        (1000, '\x1b[?1000h', 2),
        (1002, '\x1b[?1002h', 2),
        (1003, '\x1b[?1003h', 2),
        (1004, '\x1b[?1004h', 2),
        (1005, '\x1b[?1005h', 2),
        (1006, '\x1b[?1006h', 2),
        (1007, '\x1b[?1007h', 2),
        (1015, '\x1b[?1015h', 2),
        (1048, '\x1b[?1048h', 2),
        (2004, '\x1b[?2004h', 2),
        (2026, '\x1b[?2026h', 2),
        (5522, '\x1b[?5522h', 2),
      ];
      for (final (mode, change, initial) in cases) {
        expect(
          _decQuery(terminal, output, mode),
          '\x1b[?$mode;$initial\$y',
          reason: 'power-up state of ?$mode',
        );
        terminal.write(change);
        final changed = initial == 1 ? 2 : 1;
        expect(
          _decQuery(terminal, output, mode),
          '\x1b[?$mode;$changed\$y',
          reason: 'state of ?$mode after $change',
        );
      }
    });

    test('reports every alternate screen mode while the screen is active', () {
      for (final enter in ['\x1b[?47h', '\x1b[?1047h', '\x1b[?1049h']) {
        final (:terminal, :output) = _terminal();
        terminal.write(enter);
        for (final mode in [47, 1047, 1049]) {
          expect(_decQuery(terminal, output, mode), '\x1b[?$mode;1\$y');
        }
      }
      final (:terminal, :output) = _terminal();
      for (final mode in [47, 1047, 1049]) {
        expect(_decQuery(terminal, output, mode), '\x1b[?$mode;2\$y');
      }
    });

    test('reports modes the terminal can never change as permanent', () {
      final (:terminal, :output) = _terminal();
      for (final mode in [3, 8, 117]) {
        expect(_decQuery(terminal, output, mode), '\x1b[?$mode;4\$y');
      }
    });

    test('reports unknown modes, including large ones, as not recognized', () {
      final (:terminal, :output) = _terminal();
      for (final mode in [1001, 1016, 2027, 2048, 9999, 32772, 65535, 70000]) {
        expect(_decQuery(terminal, output, mode), '\x1b[?$mode;0\$y');
      }
    });

    test('asks the host for modes the terminal does not track', () {
      final (:terminal, :output) = _terminal();
      final asked = <int>[];
      terminal.externalDecModeState = (mode) {
        asked.add(mode);
        return mode == 2031 ? ModeReportState.set : null;
      };

      expect(_decQuery(terminal, output, 2031), '\x1b[?2031;1\$y');
      expect(_decQuery(terminal, output, 4242), '\x1b[?4242;0\$y');
      // The terminal's own modes never reach the host.
      expect(_decQuery(terminal, output, 25), '\x1b[?25;1\$y');
      expect(asked, [2031, 4242]);
    });

    test('a soft reset and a mode set in one write answer in order', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[?2004h\x1b[?2004\$p\x1b[!p\x1b[?2004\$p');
      expect(output, ['\x1b[?2004;1\$y', '\x1b[?2004;2\$y']);
    });
  });

  group('DECRQM for ANSI modes', () {
    test('reports unimplemented standard modes as permanently reset', () {
      final (:terminal, :output) = _terminal();
      for (final mode in [1, 2, 3, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19]) {
        output.clear();
        terminal.write('\x1b[$mode\$p');
        expect(output, ['\x1b[$mode;4\$y']);
      }
      output.clear();
      terminal.write('\x1b[12\$p\x1b[9\$p\x1b[32772\$p');
      expect(output, ['\x1b[12;3\$y', '\x1b[9;0\$y', '\x1b[32772;0\$y']);
    });

    test('reports insert and line feed modes', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[4h\x1b[4\$p\x1b[20\$p\x1b[20h\x1b[20\$p');
      expect(output, ['\x1b[4;1\$y', '\x1b[20;2\$y', '\x1b[20;1\$y']);
    });
  });

  group('cursor position reports', () {
    test('CPR is 1-based', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[6n');
      expect(output, ['\x1b[1;1R']);
      output.clear();
      terminal.write('\x1b[5;8H\x1b[6n');
      expect(output, ['\x1b[5;8R']);
    });

    test('DECXCPR keeps the ? prefix and, like a VT220 xterm, has no page', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[3;4H\x1b[?6n');
      expect(output, ['\x1b[?3;4R']);
    });

    test('a pending wrap reports the last column', () {
      final (:terminal, :output) = _terminal();
      terminal
        ..resize(10, 5)
        ..write('0123456789\x1b[6n');
      expect(output, ['\x1b[1;10R']);
    });

    test('origin mode reports the row from the top margin', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[5;20r\x1b[?6h\x1b[2;3H\x1b[6n\x1b[?6n');
      expect(output, ['\x1b[2;3R', '\x1b[?2;3R']);
    });

    test('other prefixed status reports are not answered as plain DSR', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[?5n\x1b[>6n\x1b[?15n');
      expect(output, isEmpty);
    });
  });

  group('visibility reports (mode 2033)', () {
    test('enabling reports at once, even when already enabled', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[?2033h');
      expect(output, ['\x1b[?999;1n']);
      terminal
        ..visible = false
        ..write('\x1b[?2033h');
      expect(output, ['\x1b[?999;1n', '\x1b[?999;2n', '\x1b[?999;2n']);
    });

    test('reports each change once while enabled', () {
      final (:terminal, :output) = _terminal();
      terminal
        ..visible = false
        ..visible = true;
      expect(output, isEmpty, reason: 'disabled by default');

      terminal.write('\x1b[?2033h');
      output.clear();
      terminal
        ..visible = false
        ..visible = false
        ..visible = true
        ..visible = true;
      expect(output, ['\x1b[?999;2n', '\x1b[?999;1n']);

      output.clear();
      terminal
        ..write('\x1b[?2033l')
        ..visible = false;
      expect(output, isEmpty);
    });

    test('CSI ? 998 n always answers without enabling the mode', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[?998n');
      expect(output, ['\x1b[?999;1n']);
      expect(terminal.reportVisibilityMode, isFalse);
      terminal
        ..visible = false
        ..write('\x1b[?998n\x1b[?998n');
      expect(output, ['\x1b[?999;1n', '\x1b[?999;2n', '\x1b[?999;2n']);
    });

    test('DECRQM reports the mode and RIS clears it but keeps visibility', () {
      final (:terminal, :output) = _terminal();
      expect(_decQuery(terminal, output, 2033), '\x1b[?2033;2\$y');
      terminal.write('\x1b[?2033h');
      expect(_decQuery(terminal, output, 2033), '\x1b[?2033;1\$y');

      terminal
        ..visible = false
        ..write('\x1bc');
      expect(_decQuery(terminal, output, 2033), '\x1b[?2033;2\$y');
      output.clear();
      terminal.write('\x1b[?998n');
      expect(output, ['\x1b[?999;2n']);
    });
  });

  group('DECBKM (mode 67)', () {
    test('swaps BS and DEL for Backspace in legacy encoding', () {
      final (:terminal, :output) = _terminal();
      terminal
        ..keyInput(TerminalKey.backspace)
        ..keyInput(TerminalKey.backspace, ctrl: true);
      expect(output, ['\x7f', '\b']);
      expect(terminal.backspaceInput, '\x7f');

      output.clear();
      terminal
        ..write('\x1b[?67h')
        ..keyInput(TerminalKey.backspace)
        ..keyInput(TerminalKey.backspace, ctrl: true)
        ..keyInput(TerminalKey.backspace, alt: true);
      expect(output, ['\b', '\x7f', '\x17']);
      expect(terminal.backspaceInput, '\b');
    });

    test('Kitty keyboard mode ignores DECBKM', () {
      final (:terminal, :output) = _terminal();
      terminal
        ..write('\x1b[?67h\x1b[>1u')
        ..keyInput(TerminalKey.backspace);
      expect(output, ['\x7f']);
      expect(terminal.backspaceInput, '\x7f');
    });

    test('RIS resets it and DECSTR does not', () {
      final (:terminal, :output) = _terminal();
      terminal.write('\x1b[?67h\x1b[!p');
      expect(terminal.backarrowKeyMode, isTrue);
      terminal.write('\x1bc');
      expect(terminal.backarrowKeyMode, isFalse);
      expect(_decQuery(terminal, output, 67), '\x1b[?67;2\$y');
    });
  });
}
