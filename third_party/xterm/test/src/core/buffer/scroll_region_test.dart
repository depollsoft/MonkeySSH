import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A line feed on the bottom margin of a *partial* DECSTBM region must scroll
/// the region's own rows. Growing the scrollback instead (inserting a line just
/// below the region) shoves every row underneath out of place, which scrambled
/// the inline viewport ratatui draws for the Codex CLI.
void main() {
  List<String> rows(Terminal terminal) => [
        for (var i = 0; i < terminal.buffer.lines.length; i++)
          terminal.buffer.lines[i].toString().trimRight(),
      ];

  Terminal sixRowTerminal() {
    final terminal = Terminal()..resize(10, 6);
    terminal.write('L0\r\nL1\r\nL2\r\nL3\r\nL4\r\nL5');
    return terminal;
  }

  group('partial DECSTBM scroll region', () {
    test('scrolling a top-anchored partial region leaves the rows below it',
        () {
      final terminal = sixRowTerminal();

      // Rows 1..3 of 6: top margin is row 0, but the bottom margin is above
      // the last row, so this is not a full-height scroll.
      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H'); // park on the bottom margin
      terminal.write('\n'); // index -> scroll the region

      expect(terminal.buffer.lines.length, 6,
          reason: 'no line may be inserted below the region');
      expect(rows(terminal), ['L1', 'L2', '', 'L3', 'L4', 'L5']);
    });

    test('repeated scrolls of a partial region stay inside it', () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H');
      terminal.write('\nA\n');

      expect(terminal.buffer.lines.length, 6);
      expect(rows(terminal), ['L2', 'A', '', 'L3', 'L4', 'L5']);
    });

    test('a full-height region still grows the scrollback', () {
      // The top row must keep scrolling into history when the region reaches
      // the last row -- that is the ordinary scrolling shell case.
      final terminal = sixRowTerminal();

      terminal.write('\x1b[1;6r');
      terminal.write('\x1b[6;1H');
      terminal.write('\n');

      expect(terminal.buffer.lines.length, 7,
          reason: 'the top row is preserved as scrollback');
      expect(rows(terminal), ['L0', 'L1', 'L2', 'L3', 'L4', 'L5', '']);
    });

    test('the default (unset) scroll region still grows the scrollback', () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[6;1H');
      terminal.write('\n');

      expect(terminal.buffer.lines.length, 7);
      expect(rows(terminal), ['L0', 'L1', 'L2', 'L3', 'L4', 'L5', '']);
    });

    test('a partial region that does not start at the top is unchanged', () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[2;4r');
      terminal.write('\x1b[4;1H');
      terminal.write('\n');

      expect(terminal.buffer.lines.length, 6);
      expect(rows(terminal), ['L0', 'L2', 'L3', '', 'L4', 'L5']);
    });
  });
}
