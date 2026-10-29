import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('CSI cursor parameters', () {
    for (final finalByte in ['H', 'f']) {
      for (final entry in <String, List<int>>{
        '': [0, 0],
        '3': [0, 2],
        ';5': [4, 0],
        '3;': [0, 2],
        '0;0': [0, 0],
        '3;5': [4, 2],
      }.entries) {
        test('$finalByte defaults omitted parameters in ${entry.key}', () {
          final sequence = '\x1b[${entry.key}$finalByte';
          for (var split = 0; split <= sequence.length; split++) {
            final terminal = Terminal()..resize(10, 5);
            terminal.write('\x1b[5;10H');
            terminal.write(sequence.substring(0, split));
            terminal.write(sequence.substring(split));
            expect(terminal.buffer.cursorX, entry.value[0],
                reason: 'split $split');
            expect(terminal.buffer.cursorY, entry.value[1],
                reason: 'split $split');
          }
        });
      }
    }

    test('a leading empty SGR parameter resets existing attributes', () {
      final terminal = Terminal();
      terminal.write('\x1b[1;44m\x1b[;31mX');
      expect(terminal.cursor.isBold, isFalse);
      expect(terminal.cursor.background, 0);
      expect(terminal.cursor.foreground, NamedColor.red | CellColor.named);
    });

    test('overflowing CSI counts cannot become negative cell ranges', () {
      final terminal = Terminal()..resize(5, 2);
      terminal.write('ABCDE\r\x1b[9223372036854775808PZ');
      expect(terminal.buffer.lines[0].getText(), 'Z');
      expect(terminal.buffer.cursorX, 1);
    });
  });

  test('HTS sets a tab stop at the cursor after clearing defaults', () {
    final terminal = Terminal()..resize(16, 2);
    terminal.write('\x1b[3g\x1b[1;4H\x1bH\r\t');
    expect(terminal.buffer.cursorX, 3);
    expect(terminal.buffer.cursorY, 0);
    terminal.write('X');
    expect(terminal.buffer.lines[0].getCodePoint(3), 'X'.codeUnitAt(0));
  });

  group('erase boundaries', () {
    for (final finalByte in ['K', 'J']) {
      for (final column in [0, 2, 4]) {
        test('1$finalByte includes cursor column $column', () {
          final terminal = Terminal()..resize(5, 2);
          terminal.write('ABCDE');
          terminal.setCursor(column, 0);
          terminal.write('\x1b[1$finalByte');
          final line = terminal.buffer.lines[0];
          for (var x = 0; x < 5; x++) {
            expect(
                line.getCodePoint(x), x <= column ? 0 : 'ABCDE'.codeUnitAt(x));
          }
          expect(terminal.buffer.cursorX, column);
          expect(terminal.buffer.cursorY, 0);
        });
      }
    }

    for (final command in ['K', 'J', 'X', 'P', '@']) {
      test('$command addresses the last cell during pending wrap', () {
        final terminal = Terminal()..resize(5, 2);
        terminal.write('ABCDE\x1b[$command');
        expect(terminal.buffer.lines[0].getText(), 'ABCD');
        expect(terminal.buffer.cursorX, 4);
        expect(terminal.buffer.cursorY, 0);
      });
    }
  });

  group('saved cursor', () {
    for (final alternate in [false, true]) {
      test('saved position is clamped after shrinking, alternate=$alternate',
          () {
        final terminal = Terminal()..resize(10, 5);
        if (alternate) terminal.write('\x1b[?1049h');
        terminal.write('\x1b[5;10H\x1b7');
        terminal.resize(4, 2);
        terminal.write('\x1b8');
        expect(terminal.buffer.cursorX, 3);
        expect(terminal.buffer.cursorY, 1);
        terminal.write('Z');
        expect(terminal.buffer.currentLine.getCodePoint(3), 'Z'.codeUnitAt(0));
      });
    }

    test('save and restore includes underline color', () {
      final terminal = Terminal();
      terminal.write('\x1b[4:3;58:5:160m\x1b7\x1b[0m\x1b8X');
      expect(terminal.cursor.underlineStyle, UnderlineStyle.curly);
      expect(terminal.cursor.underlineColor, 160 | CellColor.palette);
      final cell = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cell);
      expect(cell.underlineColor, 160 | CellColor.palette);
    });

    test('save and restore without resizing retains pending wrap', () {
      final terminal = Terminal()..resize(5, 2);
      terminal.write('ABCDE\x1b7\r\x1b8Z');
      expect(terminal.buffer.lines[0].getText(), 'ABCDE');
      expect(terminal.buffer.lines[1].getText(), 'Z');
    });
  });

  group('MonkeyMux screen model agreement', () {
    String row(Terminal terminal, int y) =>
        terminal.buffer.lines[terminal.buffer.scrollBack + y].getText();

    int foregroundAt(Terminal terminal, int x, int y) {
      final cell = CellData.empty();
      terminal.buffer.lines[terminal.buffer.scrollBack + y]
          .getCellData(x, cell);
      return cell.foreground;
    }

    test('a huge forward-tab count stops at the right edge', () {
      final terminal = Terminal()..resize(20, 2);
      final stopwatch = Stopwatch()..start();
      terminal.write('\x1b[2147483647IZ');
      // Each stop past the edge used to cost a loop iteration: seconds of UI
      // freeze for one malformed sequence.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(row(terminal, 0), '');
      expect(row(terminal, 1), 'Z');
    });

    test('a huge repeat count writes at most one row', () {
      final terminal = Terminal()..resize(4, 3);
      final stopwatch = Stopwatch()..start();
      terminal.write('a\x1b[2147483647b');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(row(terminal, 0), 'aaaa');
      expect(row(terminal, 1), 'a');
    });

    test('without autowrap output overwrites the last column', () {
      final terminal = Terminal()..resize(4, 2);
      terminal.write('\x1b[?7labcde');
      expect(row(terminal, 0), 'abce');
      expect(row(terminal, 1), '');
      terminal.write('\u754c');
      expect(row(terminal, 0), 'ab\u754c');
      expect(terminal.buffer.cursorY, 0);
    });

    test('overwriting the second half of a wide character blanks the first',
        () {
      final terminal = Terminal()..resize(6, 1);
      terminal.write('\u754cZ\x1b[1;2HA');
      expect(terminal.buffer.lines[0].getWidth(0), isNot(2));
      expect(row(terminal, 0), ' AZ');
      terminal.write('\r\u4e2dZ\x1b[1;2H\u754c');
      expect(row(terminal, 0), ' \u754c');
    });

    test('zero-width code points do not take a column', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('e\u0301f\u2764\uFE0Fx\u200D');
      expect(terminal.buffer.cursorX, 4);
      expect(row(terminal, 0), 'ef\u2764x');
      terminal.write('\x1b[b');
      expect(row(terminal, 0), 'ef\u2764xx');
    });

    test('vertical moves and VPA stay inside the scroll region', () {
      final terminal = Terminal()..resize(10, 8);
      terminal.write('\x1b[3;6r\x1b[?6h\x1b[1;1H\x1b[1AX');
      expect(terminal.buffer.cursorY, 2);
      expect(row(terminal, 2), 'X');
      terminal.write('\x1b[1dY');
      expect(row(terminal, 2), 'XY');
      terminal.write('\x1b[20B');
      expect(terminal.buffer.cursorY, 5);
      terminal.write('\x1b[20d');
      expect(terminal.buffer.cursorY, 5);
      // Without origin mode a cursor inside the region still stops at its
      // margins, and one outside it moves over the whole screen.
      terminal.write('\x1b[?6l\x1b[4;1H\x1b[9A');
      expect(terminal.buffer.cursorY, 2);
      terminal.write('\x1b[9E');
      expect(terminal.buffer.cursorY, 5);
      terminal.write('\x1b[8;1H\x1b[9F');
      expect(terminal.buffer.cursorY, 0);
    });

    test('leaving mode 1049 restores the rendition saved on entry', () {
      final terminal = Terminal();
      terminal.write('\x1b[31mA\x1b[?1049h\x1b[32mB\x1b[?1049lC');
      expect(foregroundAt(terminal, 1, 0), NamedColor.red | CellColor.named);
    });

    for (final entry in <String, List<String>>{
      '\r\x1b[0P': ['BC', 'D'],
      '\r\x1b[0@': [' ABC', 'D'],
      '\r\x1b[0X': [' BC', 'D'],
      '\x1b[H\x1b[0L': ['', 'ABC'],
      '\x1b[2;1H\x1b[0M': ['ABC', ''],
      '\x1b[0S': ['D', ''],
      '\x1b[0T': ['', 'ABC'],
    }.entries) {
      test(
          'an explicit zero count in ${entry.key.substring(entry.key.length - 2)} means one',
          () {
        final terminal = Terminal()..resize(5, 3);
        terminal.write('ABC\r\nD\x1b[1;4H');
        terminal.write(entry.key);
        expect([row(terminal, 0), row(terminal, 1)], entry.value);
      });
    }

    test('C0 controls inside a CSI run once, before it', () {
      const sequence = 'ab\x1b[1\r\nmX';
      for (var split = 0; split <= sequence.length; split++) {
        final terminal = Terminal()..resize(5, 3);
        terminal.write(sequence.substring(0, split));
        terminal.write(sequence.substring(split));
        expect([
          row(terminal, 0),
          row(terminal, 1),
          row(terminal, 2)
        ], [
          'ab',
          'X',
          ''
        ], reason: 'split $split');
        expect(terminal.cursor.isBold, isTrue, reason: 'split $split');
      }
    });

    test('LF and IND below the scroll region stop at the last row', () {
      for (final control in ['\n', '\x0b', '\x0c', '\x1bD', '\x1bE']) {
        final terminal = Terminal()..resize(5, 6);
        terminal.write('top\x1b[2;3r\x1b[5;1Hx');
        terminal.write(control * 6);
        expect(terminal.buffer.cursorY, 5, reason: control);
        expect([row(terminal, 0), row(terminal, 4)], ['top', 'x'],
            reason: control);
        expect(terminal.buffer.scrollBack, 0, reason: control);
      }
    });

    test('BS and CUB from a pending wrap count from the last column', () {
      final terminal = Terminal()..resize(5, 2);
      terminal.write('ABCDE\bX');
      expect(row(terminal, 0), 'ABCXE');
      terminal.write('\r\nABCDE\x1b[2DY');
      expect(row(terminal, 1), 'ABYDE');
    });

    test('SOS and PM strings are skipped', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('A\x1bXsos\x1b\\B\x1b^pm\x1b\\C');
      expect(row(terminal, 0), 'ABC');
      terminal.write('\x1b^pm\x07still pm\x1b\\D');
      expect(row(terminal, 0), 'ABCD');
    });

    for (final save in ['\x1b7', '\x1b[s', '\x1b[?1048h']) {
      final restore = {
        '\x1b7': '\x1b8',
        '\x1b[s': '\x1b[u',
        '\x1b[?1048h': '\x1b[?1048l',
      }[save]!;
      test('restoring the cursor restores origin mode (${save.substring(1)})',
          () {
        final terminal = Terminal()..resize(10, 8);
        terminal.write('\x1b[6;5H$save\x1b[5;7r\x1b[?6h$restore');
        expect(terminal.originMode, isFalse);
        expect(terminal.buffer.cursorY, 5);
        expect(terminal.buffer.cursorX, 4);
        terminal.write('\x1b[1;1HX');
        expect(row(terminal, 0), 'X');
      });
    }

    test('SCORC restores what DECSC saved, rendition included', () {
      final terminal = Terminal()..resize(10, 3);
      terminal.write('\x1b[2;2H\x1b[31m\x1b7\x1b[0m\x1b[3;3H\x1b[uY');
      expect(row(terminal, 1), ' Y');
      expect(foregroundAt(terminal, 1, 1), NamedColor.red | CellColor.named);
    });

    test('switching screens with 47 and 1047 leaves the cursor in place', () {
      for (final mode in ['47', '1047']) {
        final terminal = Terminal()..resize(10, 4);
        terminal.write('abc\r\nabc\x1b[?${mode}h');
        expect([terminal.buffer.cursorX, terminal.buffer.cursorY], [3, 1],
            reason: mode);
        terminal.write('\x1b[2J\x1b[2;1Hdef\r\ndef\x1b[?${mode}l');
        expect([terminal.buffer.cursorX, terminal.buffer.cursorY], [3, 2],
            reason: mode);
        expect([row(terminal, 0), row(terminal, 1)], ['abc', 'abc'],
            reason: mode);
        terminal.write('\x1b[?${mode}h');
        expect(row(terminal, 1), mode == '47' ? 'def' : '', reason: mode);
      }
      final terminal = Terminal()..resize(5, 3);
      terminal.write('ABCDE\x1b[?47hZ');
      expect([row(terminal, 0), row(terminal, 1)], ['', 'Z']);
    });

    test('1049 saves and restores the cursor without a screen change', () {
      final terminal = Terminal()..resize(10, 3);
      terminal.write('\x1b[2;3H\x1b7\x1b[3;5H\x1b[?1049lX');
      expect(row(terminal, 1), '  X');
      terminal.write('\x1b[?1049h\x1b[Hfoo\x1b[2;2H\x1b[?1049hY');
      expect([row(terminal, 0), row(terminal, 1)], ['', ' Y']);
    });

    test('DECSTBM reads a zero bottom as the last row and homes the cursor',
        () {
      final terminal = Terminal()..resize(5, 4);
      terminal.write('\x1b[3;3H\x1b[1;0r');
      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, 3);
      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);
      terminal.write('\x1b[3;3H\x1b[3;2r');
      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, 3);
      expect(terminal.buffer.cursorY, 2);
      terminal.write('\x1b[?6h\x1b[2;3r');
      expect(terminal.buffer.cursorY, 1);
    });
  });
}
