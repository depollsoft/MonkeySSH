import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xterm/src/utils/unicode_v11.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Buffer.getText()', () {
    test('without a range includes the last column', () {
      final terminal = Terminal()..resize(3, 1);
      terminal.write('abc');
      expect(terminal.buffer.getText(), 'abc');
    });

    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.getText(), startsWith('Hello World'));
    });

    test('can handle line wrap', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      final line1 = 'This is a long line that should wrap';
      final line2 = 'This is a short line';
      final line3 = 'This is a long long long long line that should wrap';
      final line4 = 'Short';

      terminal.write('$line1\r\n');
      terminal.write('$line2\r\n');
      terminal.write('$line3\r\n');
      terminal.write('$line4\r\n');

      final lines = terminal.buffer.getText().split('\n');
      expect(lines[0], line1);
      expect(lines[1], line2);
      expect(lines[2], line3);
      expect(lines[3], line4);
    });

    test('can handle negative start', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(-100, -100), CellOffset(100, 100)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle invalid end', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(0, 0), CellOffset(100, 100)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle reversed range', () {
      final terminal = Terminal();

      terminal.write('Hello World');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(5, 5), CellOffset(0, 0)),
        ),
        startsWith('Hello World'),
      );
    });

    test('can handle block range', () {
      final terminal = Terminal();

      terminal.write('Hello World\r\n');
      terminal.write('Nice to meet you\r\n');

      expect(
        terminal.buffer.getText(
          BufferRangeBlock(CellOffset(2, 0), CellOffset(5, 1)),
        ),
        startsWith('llo\nce '),
      );
    });

    test('keeps spaces a TUI drew with cursor movement and erases', () {
      final terminal = Terminal();
      terminal.resize(20, 4);

      // Redraws that skip or erase blank runs instead of writing spaces.
      terminal.write('\x1b[1;1Hgit\x1b[1Cstatus\x1b[2C--short');
      terminal
          .write('\x1b[2;1Hecho_hello_world\x1b[2;5H\x1b[X\x1b[2;11H\x1b[X');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(CellOffset(0, 0), CellOffset(20, 1)),
        ),
        'git status  --short\necho hello world',
      );
    });

    test('wraps a wide character that does not fit in the last column', () {
      final terminal = Terminal();
      terminal.resize(4, 2);

      terminal.write('abc界Z');

      expect(terminal.buffer.lines[0].getCodePoint(3), 0);
      expect(terminal.buffer.lines[1].isWrapped, isTrue);
      expect(terminal.buffer.lines[1].getText(), '界Z');
      expect(terminal.buffer.cursorX, 3);
      expect(terminal.buffer.getText(), 'abc界Z');
    });

    test('keeps a wide character in the last two columns without autowrap', () {
      final terminal = Terminal();
      terminal.resize(4, 2);

      terminal.write('\x1b[?7labc界');

      expect(terminal.buffer.lines[0].getText(), 'ab界');
      expect(terminal.buffer.lines[1].getText(), isEmpty);
    });

    test('wraps a newer wide emoji like the MonkeyMux screen model', () {
      final terminal = Terminal()..resize(4, 2);

      terminal.write('abc\u{1FAE0}X');

      expect(terminal.buffer.lines[0].getText(), 'abc');
      expect(terminal.buffer.lines[1].getText(), '\u{1FAE0}X');
    });
  });

  // remote/monkeymux/runewidth_table.go is generated from the same table and
  // checked against the same digest, so the client and the MonkeyMux screen
  // model agree on every code point's width.
  test('wcwidth matches the shared width table digest', () {
    final digest = <String, String>{};
    for (final line
        in File('../../scripts/unicode_width_table.crc32').readAsLinesSync()) {
      final fields = line.trim().split(' ');
      if (fields.length == 2 && !line.startsWith('#')) {
        digest[fields[0]] = fields[1];
      }
    }
    final widths = Uint8List(0x110000);
    for (var codePoint = 0; codePoint < widths.length; codePoint++) {
      widths[codePoint] = unicodeV11.wcwidth(codePoint);
    }
    expect(digest['unicode'], unicodeWidthVersion);
    expect(
      digest['crc32'],
      getCrc32(widths).toRadixString(16).padLeft(8, '0'),
      reason: 'rerun scripts/generate_unicode_width_tables.py',
    );
  });

  group('Buffer.resize()', () {
    test('should resize the buffer', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      expect(terminal.viewWidth, 10);
      expect(terminal.viewHeight, 10);

      for (var i = 0; i < terminal.lines.length; i++) {
        final line = terminal.lines[i];
        expect(line.length, 10);
      }

      terminal.resize(20, 20);

      expect(terminal.viewWidth, 20);
      expect(terminal.viewHeight, 20);

      for (var i = 0; i < terminal.lines.length; i++) {
        final line = terminal.lines[i];
        expect(line.length, 20);
      }
    });

    // A full-screen TUI (Copilot CLI, Claude Code) parks its cursor on its
    // input line and keeps a footer below it. Shrinking must not drop those
    // rows: the TUI still repaints relative to its own cursor, so deleting
    // lines it believes it owns desynchronises every later frame.
    test('shrinking keeps content below the cursor', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      for (var i = 1; i <= 7; i++) {
        terminal.write('line$i\r\n');
      }
      terminal.write('prompt>\r\n footer-1\r\n footer-2');
      terminal.write('\x1b[2A\r'); // park the cursor back on the prompt

      terminal.resize(20, 5);

      expect(terminal.buffer.lines[7].toString().trimRight(), 'prompt>');
      expect(terminal.buffer.lines[8].toString().trimRight(), ' footer-1');
      expect(terminal.buffer.lines[9].toString().trimRight(), ' footer-2');
    });

    // The keyboard-open/close animation resizes a dozen times in each
    // direction. The round trip has to land exactly where it started or the
    // TUI's frame drifts away from the bottom of the buffer, stranding it
    // behind a block of blank rows.
    test('a shrink/grow cycle round-trips buffer and cursor', () {
      final terminal = Terminal(maxLines: 500);
      terminal.resize(20, 20);
      for (var i = 1; i <= 60; i++) {
        terminal.write('line$i\r\n');
      }
      terminal.write('prompt>\r\n footer-1\r\n footer-2');
      terminal.write('\x1b[2A\r');

      final beforeText = terminal.buffer.getText();
      final beforeCursorY = terminal.buffer.absoluteCursorY;
      final beforeHeight = terminal.buffer.height;

      for (var height = 19; height >= 8; height--) {
        terminal.resize(20, height);
      }
      for (var height = 9; height <= 20; height++) {
        terminal.resize(20, height);
      }

      expect(terminal.buffer.getText(), beforeText);
      expect(terminal.buffer.absoluteCursorY, beforeCursorY);
      expect(terminal.buffer.height, beforeHeight);
    });

    // The alternate screen has no scrollback, so the rows a shrink scrolls above
    // the viewport are deleted by the `clearScrollback()` that follows the
    // resize. Scrolling there therefore destroys the *top* rows, while the host
    // gives up the rows below the cursor first. tmux's `screen_resize_y` runs
    // with `GRID_HISTORY` cleared on the alternate grid, so it deletes up to
    // `oldHeight - 1 - cursorY` rows off the bottom before it touches the top.
    // Preferring blank rows instead — refusing a TUI's non-blank footer and
    // taking the row off the top — offsets the whole frame from the grid the
    // app repaints against.
    test('alternate screen shrink gives up the rows below the cursor', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      terminal.write('\x1b[?1049h');
      for (var row = 1; row <= 10; row++) {
        terminal.write('\x1b[$row;1Hrow$row');
      }
      terminal.write('\x1b[8;1H'); // park the cursor above a non-blank footer

      terminal.resize(20, 8); // exactly the two rows below the cursor

      expect(terminal.buffer.height, 8);
      for (var row = 1; row <= 8; row++) {
        expect(
          terminal.buffer.lines[row - 1].toString().trimRight(),
          'row$row',
          reason: 'nothing above the cursor may move',
        );
      }
      expect(
        terminal.buffer.cursorY,
        7,
        reason: 'the cursor keeps its row when only the footer is dropped',
      );
    });

    // Once the cursor has nothing left below it the host takes the remainder off
    // the top and moves the cursor up with it, so the cursor always keeps its
    // own line. Popping past the cursor instead would delete the TUI's input
    // line and everything it had just drawn above it.
    test('alternate screen deep shrink trims the top and keeps the cursor', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      terminal.write('\x1b[?1049h');
      for (var row = 1; row <= 10; row++) {
        terminal.write('\x1b[$row;1Hrow$row');
      }
      terminal.write('\x1b[8;1H');

      terminal.resize(20, 6); // 2 rows below the cursor, 2 more off the top

      expect(terminal.buffer.height, 6);
      expect(terminal.buffer.lines[0].toString().trimRight(), 'row3');
      expect(terminal.buffer.lines[5].toString().trimRight(), 'row8');
      expect(
        terminal.buffer.cursorY,
        5,
        reason: 'the cursor must still sit on row8, its own line',
      );
    });

    // The Android keyboard animation shrinks and grows a dozen times per open.
    // Whatever it destroys, the cursor has to come out still on its own line and
    // the buffer has to be exactly one viewport tall, so the `clearScrollback()`
    // after the next resize has nothing left to trim.
    test('alternate screen shrink/grow keeps the cursor on its line', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      terminal.write('\x1b[?1049h');
      for (var row = 1; row <= 10; row++) {
        terminal.write('\x1b[$row;1Hrow$row');
      }
      terminal.write('\x1b[8;1H');

      for (final height in [8, 6, 5, 4]) {
        terminal.resize(20, height);
        expect(
          terminal.buffer.height,
          height,
          reason: 'the alternate screen never keeps scrollback',
        );
        expect(
          terminal.buffer.scrollBack,
          0,
          reason: 'clearScrollback() must have nothing left to trim',
        );
        expect(
          terminal.buffer.lines[terminal.buffer.cursorY].toString().trimRight(),
          'row8',
          reason: 'the cursor may move index, never leave its line',
        );
      }

      terminal.resize(20, 10);

      expect(terminal.buffer.height, 10);
      expect(
        terminal.buffer.lines[terminal.buffer.cursorY].toString().trimRight(),
        'row8',
      );
      expect(
        terminal.buffer.lines[9].toString().trimRight(),
        isEmpty,
        reason: 'regrown rows are appended below the survivors',
      );
    });

    test('inactive alternate screen commits top trim during resize', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      terminal.write('\x1b[?47h');
      for (var row = 1; row <= 10; row++) {
        terminal.write('\x1b[$row;1Hrow$row');
      }
      terminal.write('\x1b[8;1H');
      terminal
          .write('\x1b[?47l'); // preserve the alt buffer while main is active

      terminal.resize(20, 6);
      terminal.write('\x1b[?47h');

      expect(terminal.buffer.height, 6);
      expect(terminal.buffer.scrollBack, 0);
      expect(terminal.buffer.lines[0].toString().trimRight(), 'row3');
      expect(terminal.buffer.lines[5].toString().trimRight(), 'row8');
      expect(terminal.buffer.cursorY, 5);
    });

    // With reflow off (and always on the alt buffer) a width shrink keeps the
    // cells past the new width so they reappear when it grows back. A row whose
    // only text lives in that hidden region reads as blank across the visible
    // columns, so measuring blankness by visible width alone would pop it and
    // break that contract.
    test('shrinking keeps rows whose only content is hidden past the width',
        () {
      final terminal = Terminal(reflowEnabled: false, maxLines: 200);
      terminal.resize(20, 5);
      // Write past column 5 so every visible cell of the last row stays unset,
      // then park the cursor above it with room left to scroll.
      terminal.write('\x1b[5;11HWorld');
      terminal.write('\x1b[3;1H');

      terminal.resize(5, 5); // hide the text past the new width
      terminal.resize(5, 4); // the shrink under test
      terminal.resize(20, 5); // bring the hidden cells back

      expect(
        terminal.buffer.getText().contains('World'),
        isTrue,
        reason: 'hidden cells must survive a height shrink',
      );
    });

    // Scrolling during a shrink does not move the cursor off its line, so an
    // empty row the cursor sits on is never one of the rows below it. Dropping
    // it moved the cursor onto the content above, and the next output
    // overwrote that content.
    test('shrinking keeps the cursor on its own empty row', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 6);
      terminal.write('one\r\ntwo\r\nthree\r\n');

      terminal.resize(20, 2);
      terminal.write('next');

      final lines = terminal.buffer.lines;
      expect(lines[lines.length - 2].toString().trimRight(), 'three');
      expect(lines[lines.length - 1].toString().trimRight(), 'next');
    });

    // Trailing blank rows are the rows a shrink should consume first: real
    // terminals reclaim them instead of scrolling live content into scrollback.
    test('shrinking reclaims trailing blank rows before scrolling', () {
      final terminal = Terminal(maxLines: 200);
      terminal.resize(20, 10);
      terminal.write('line1\r\nline2\r\nline3');
      terminal.setCursor(0, 0);

      terminal.resize(20, 6);

      expect(terminal.buffer.height, 6);
      expect(terminal.buffer.lines[0].toString().trimRight(), 'line1');
      expect(terminal.buffer.absoluteCursorY, 0);
    });
  });

  group('Buffer.deleteLines()', () {
    test('works', () {
      final terminal = Terminal();
      terminal.resize(10, 10);

      for (var i = 1; i <= 10; i++) {
        terminal.write('line$i');

        if (i < 10) {
          terminal.write('\r\n');
        }
      }

      terminal.setMargins(3, 7);
      terminal.setCursor(0, 5);

      terminal.buffer.deleteLines(1);

      expect(terminal.buffer.lines[2].toString(), 'line3');
      expect(terminal.buffer.lines[3].toString(), 'line4');
      expect(terminal.buffer.lines[4].toString(), 'line5');
      expect(terminal.buffer.lines[5].toString(), 'line7');
      expect(terminal.buffer.lines[6].toString(), 'line8');
      expect(terminal.buffer.lines[7].toString(), '');
      expect(terminal.buffer.lines[8].toString(), 'line9');
      expect(terminal.buffer.lines[9].toString(), 'line10');
    });
  });

  group('Buffer.insertLines()', () {
    test('works', () {
      final terminal = Terminal();

      for (var i = 0; i < 10; i++) {
        terminal.write('line$i\r\n');
      }

      print(terminal.buffer);

      terminal.setMargins(2, 6);
      terminal.setCursor(0, 4);

      print(terminal.buffer.absoluteCursorY);

      terminal.buffer.insertLines(1);

      print(terminal.buffer);

      expect(terminal.buffer.lines[3].toString(), 'line3');
      expect(terminal.buffer.lines[4].toString(), ''); // inserted
      expect(terminal.buffer.lines[5].toString(), 'line4'); // moved
      expect(terminal.buffer.lines[6].toString(), 'line5'); // moved
      expect(terminal.buffer.lines[7].toString(), 'line7');
    });

    test('has no effect if cursor is out of scroll region', () {
      final terminal = Terminal();

      for (var i = 0; i < 10; i++) {
        terminal.write('line$i\r\n');
      }

      terminal.setMargins(2, 6);
      terminal.setCursor(0, 1);

      terminal.buffer.insertLines(1);

      expect(terminal.buffer.lines[2].toString(), 'line2');
      expect(terminal.buffer.lines[3].toString(), 'line3');
      expect(terminal.buffer.lines[4].toString(), 'line4');
      expect(terminal.buffer.lines[5].toString(), 'line5');
      expect(terminal.buffer.lines[6].toString(), 'line6');
      expect(terminal.buffer.lines[7].toString(), 'line7');
    });
  });

  group('Buffer.getWordBoundary supports custom word separators', () {
    test('can set word separators', () {
      final terminal = Terminal(wordSeparators: {'o'.codeUnitAt(0)});

      terminal.write('Hello World');

      expect(
        terminal.mainBuffer.getWordBoundary(CellOffset(0, 0)),
        BufferRangeLine(CellOffset(0, 0), CellOffset(4, 0)),
      );

      expect(
        terminal.mainBuffer.getWordBoundary(CellOffset(5, 0)),
        BufferRangeLine(CellOffset(5, 0), CellOffset(7, 0)),
      );
    });
  });

  test('does not delete lines beyond the scroll region', () {
    final terminal = Terminal();
    terminal.resize(10, 10);

    for (var i = 1; i <= 10; i++) {
      terminal.write('line$i');

      if (i < 10) {
        terminal.write('\r\n');
      }
    }

    terminal.setMargins(3, 7);
    terminal.setCursor(0, 5);

    terminal.buffer.deleteLines(20);

    expect(terminal.buffer.lines[2].toString(), 'line3');
    expect(terminal.buffer.lines[3].toString(), 'line4');
    expect(terminal.buffer.lines[4].toString(), 'line5');
    expect(terminal.buffer.lines[5].toString(), '');
    expect(terminal.buffer.lines[6].toString(), '');
    expect(terminal.buffer.lines[7].toString(), '');
    expect(terminal.buffer.lines[8].toString(), 'line9');
    expect(terminal.buffer.lines[9].toString(), 'line10');
  });

  group('Buffer.eraseDisplayFromCursor()', () {
    test('works', () {
      final terminal = Terminal();
      terminal.resize(3, 3);
      terminal.write('123\r\n456\r\n789');

      terminal.setCursor(1, 1);
      terminal.buffer.eraseDisplayFromCursor();

      expect(terminal.buffer.lines[0].toString(), '123');
      expect(terminal.buffer.lines[1].toString(), '4');
      expect(terminal.buffer.lines[2].toString(), '');
    });
  });
}
