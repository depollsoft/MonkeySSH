import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_scrollback_text.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('terminalRowText', () {
    test('reads rows the way copy does', () {
      // Cursor movement and erases instead of spaces, a wide glyph, a
      // supplementary code point and trailing padding.
      final terminal = Terminal()
        ..resize(20, 3)
        ..write('\x1b[1;1H\$\x1b[1Cgit\x1b[1Cstatus')
        ..write('\x1b[2;1H漢字 ok\x1b[3;1H😀 x   ');
      for (var row = 0; row < 3; row++) {
        final line = terminal.buffer.lines[row];
        expect(terminalRowText(line), line.getText(), reason: 'row $row');
      }
      expect(terminalRowText(terminal.buffer.lines[0]), r'$ git status');
    });

    test('maps every code unit to the cell it came from', () {
      final terminal = Terminal()
        ..resize(20, 2)
        ..write('a漢\x1b[1Cb😀c');
      final row = terminalRowTextWithColumns(terminal.buffer.lines[0]);
      // a(0) 漢(1-2) blank(3) b(4) 😀(5-6, two code units) c(7)
      expect(row.text, 'a漢 b😀c');
      expect(row.columns, [0, 1, 3, 4, 5, 5, 7]);
      expect(terminalCellEndColumn(terminal.buffer.lines[0], 1), 3);
      expect(terminalCellEndColumn(terminal.buffer.lines[0], 4), 5);
    });
  });

  group('readTerminalTextLines', () {
    test('joins soft-wrapped rows and records where each row starts', () async {
      final terminal = Terminal()
        ..resize(10, 5)
        ..write('short\r\n0123456789abcdefghijXYZ\r\nlast');
      final lines = (await readTerminalTextLines(terminal.buffer))!;

      expect(lines.map((line) => line.text).take(3), [
        'short',
        '0123456789abcdefghijXYZ',
        'last',
      ]);
      final wrapped = lines[1];
      expect(wrapped.rows, hasLength(3));
      expect(wrapped.rowStarts, [0, 10, 20]);
      expect(wrapped.rowIndexForOffset(9), 0);
      expect(wrapped.rowIndexForOffset(10), 1);
      expect(wrapped.rowIndexForOffset(22), 2);
      expect(wrapped.rowEnd(1), 20);
      expect(wrapped.rowEnd(2), 23);
      expect(identical(wrapped.rows[1], terminal.buffer.lines[2]), isTrue);
    });

    test('a wide glyph that wrapped adds no space at the row end', () async {
      final terminal = Terminal()
        ..resize(5, 3)
        ..write('abcd漢x');
      final lines = (await readTerminalTextLines(terminal.buffer))!;
      expect(lines.first.text, 'abcd漢x');
    });

    test(
      'reads a full scrollback across slices and can be cancelled',
      () async {
        final terminal = Terminal(maxLines: 400)..resize(40, 10);
        for (var index = 0; index < 600; index++) {
          terminal.write('line $index\r\n');
        }
        final lines = (await readTerminalTextLines(
          terminal.buffer,
          sliceBudget: Duration.zero,
        ))!;
        expect(lines, hasLength(400));
        expect(lines.first.text, 'line 201');

        var checks = 0;
        final cancelled = await readTerminalTextLines(
          terminal.buffer,
          sliceBudget: Duration.zero,
          isCancelled: () => ++checks > 3,
        );
        expect(cancelled, isNull);
      },
    );
  });

  group('readTerminalBufferPlainText', () {
    test('trims padding and the unused rows below the output', () async {
      final terminal = Terminal()
        ..resize(10, 8)
        ..write('one   \r\n\r\n0123456789abc\r\nlast  \r\n');
      expect(
        await readTerminalBufferPlainText(terminal.buffer),
        'one\n\n0123456789abc\nlast\n',
      );
    });

    test('an empty buffer exports nothing', () async {
      final terminal = Terminal()..resize(10, 4);
      expect(await readTerminalBufferPlainText(terminal.buffer), '');
    });

    test('the alternate screen exports only the screen', () async {
      final terminal = Terminal()
        ..resize(20, 3)
        ..write('history 1\r\nhistory 2\r\nhistory 3\r\nhistory 4\r\n')
        ..write('\x1b[?1049h\x1b[Hfull screen app');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(
        await readTerminalBufferPlainText(terminal.buffer),
        'full screen app\n',
      );
    });
  });
}
