import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A line feed on the bottom margin of a DECSTBM region whose top margin is
/// the first row feeds the scrollback, whatever the bottom margin: that is
/// xterm's rule (top_marg == 0) and what ratatui's inline viewport relies on
/// for the Codex CLI. Its transcript lines are pushed out of a `CSI 1 ; N r`
/// region above the viewport; discarding them instead makes the transcript
/// impossible to scroll back to. The rows under the region keep their screen
/// position throughout. A region that starts lower scrolls its own rows.
void main() {
  List<String> rows(Terminal terminal) => [
        for (var i = 0; i < terminal.buffer.lines.length; i++)
          terminal.buffer.lines[i].toString().trimRight(),
      ];

  List<String> visible(Terminal terminal) => [
        for (var i = 0; i < terminal.viewHeight; i++)
          terminal.buffer.lines[i + terminal.buffer.scrollBack]
              .toString()
              .trimRight(),
      ];

  Terminal sixRowTerminal() {
    final terminal = Terminal()..resize(10, 6);
    terminal.write('L0\r\nL1\r\nL2\r\nL3\r\nL4\r\nL5');
    return terminal;
  }

  group('partial DECSTBM scroll region', () {
    test('scrolling a top-anchored partial region keeps the top row as history',
        () {
      final terminal = sixRowTerminal();

      // Rows 1..3 of 6: top margin is row 0, but the bottom margin is above
      // the last row.
      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H'); // park on the bottom margin
      terminal.write('\n'); // index -> scroll the region

      expect(terminal.buffer.lines.length, 7,
          reason: 'the row leaving the region is preserved as scrollback');
      expect(rows(terminal), ['L0', 'L1', 'L2', '', 'L3', 'L4', 'L5']);
      expect(visible(terminal), ['L1', 'L2', '', 'L3', 'L4', 'L5'],
          reason: 'the rows below the region keep their screen position');
      expect(terminal.buffer.cursorY, 2);
    });

    test('repeated scrolls of a partial region keep feeding the scrollback',
        () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H');
      terminal.write('\nA\n');

      expect(terminal.buffer.lines.length, 8);
      expect(rows(terminal), ['L0', 'L1', 'L2', 'A', '', 'L3', 'L4', 'L5']);
      expect(visible(terminal), ['L2', 'A', '', 'L3', 'L4', 'L5']);
    });

    test('an inline viewport inserts transcript lines above itself', () {
      // ratatui's insert_before as used by the Codex CLI: the viewport is
      // the last three rows, the region above it is `CSI 1 ; 3 r`, and each
      // transcript line is written after a CR LF on the region's bottom row.
      final terminal = Terminal()..resize(10, 6);
      terminal.write('\x1b[4;1HV0\r\nV1\r\nV2');
      terminal.write('\x1b7\x1b[1;3r\x1b[3;1H');
      for (final line in ['T0', 'T1', 'T2', 'T3', 'T4']) {
        terminal.write('\r\n$line');
      }
      terminal.write('\x1b[r\x1b8');

      expect(visible(terminal), ['T2', 'T3', 'T4', 'V0', 'V1', 'V2'],
          reason: 'the viewport never moves while the transcript grows');
      expect(rows(terminal).sublist(0, terminal.buffer.scrollBack),
          ['', '', '', 'T0', 'T1'],
          reason: 'every transcript line that left the region is history');
      expect(terminal.buffer.cursorY, 5);
      expect(terminal.buffer.cursorX, 2);
    });

    test('a full scrollback still keeps the rows below the region in place',
        () {
      // Fill a 40-line buffer so every insert has to trim the oldest line.
      final terminal = Terminal(maxLines: 40)..resize(10, 6);
      terminal.write([for (var i = 0; i < 40; i++) 'L$i'].join('\r\n'));
      expect(terminal.buffer.lines.isFull, isTrue);

      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H');
      terminal.write('\nA\n');

      expect(terminal.buffer.lines.length, 40,
          reason: 'the oldest history line is trimmed');
      expect(rows(terminal).first, 'L2');
      expect(visible(terminal), ['L36', 'A', '', 'L37', 'L38', 'L39']);
    });

    test('a full-height region still grows the scrollback', () {
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

    test('a partial region that does not start at the top scrolls in place',
        () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[2;4r');
      terminal.write('\x1b[4;1H');
      terminal.write('\n');

      expect(terminal.buffer.lines.length, 6,
          reason: 'nothing enters the scrollback');
      expect(rows(terminal), ['L0', 'L2', 'L3', '', 'L4', 'L5']);
    });

    test('the alternate screen never grows the scrollback', () {
      final terminal = sixRowTerminal();

      terminal.write('\x1b[?1049h');
      terminal.write('\x1b[1;3r');
      terminal.write('\x1b[3;1H');
      terminal.write('\n');

      expect(terminal.buffer.lines.length, 6);
    });
  });
}
