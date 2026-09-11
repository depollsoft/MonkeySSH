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
}
