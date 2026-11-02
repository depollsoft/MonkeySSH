import 'package:test/test.dart';
import 'package:xterm/core.dart';

void main() {
  test('reflow() can reflow a single line', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(10, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890');
    expect(terminal.buffer.lines[1].toString(), 'abcdefg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(13, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890abc');
    expect(terminal.buffer.lines[1].toString(), 'defg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(20, 10);

    expect(terminal.buffer.lines[0].toString(), '1234567890abcdefg');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });

  test('reflow() can reflow a single line to multiple lines', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(5, 10);

    expect(terminal.buffer.lines[0].toString(), '12345');
    expect(terminal.buffer.lines[1].toString(), '67890');
    expect(terminal.buffer.lines[2].toString(), 'abcde');
    expect(terminal.buffer.lines[3].toString(), 'fg');

    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[2].isWrapped, isTrue);
    expect(terminal.buffer.lines[3].isWrapped, isTrue);

    terminal.resize(6, 10);

    expect(terminal.buffer.lines[0].toString(), '123456');
    expect(terminal.buffer.lines[1].toString(), '7890ab');
    expect(terminal.buffer.lines[2].toString(), 'cdefg');

    expect(terminal.buffer.lines[0].isWrapped, isFalse);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[2].isWrapped, isTrue);
  });

  test('reflow() can reflow wide characters', () {
    final terminal = Terminal();

    terminal.write('床前明月光疑是地上霜');
    terminal.resize(10, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月光');
    expect(terminal.buffer.lines[1].toString(), '疑是地上霜');

    terminal.resize(9, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月');
    expect(terminal.buffer.lines[1].toString(), '光疑是地');
    expect(terminal.buffer.lines[2].toString(), '上霜');

    terminal.resize(11, 10);

    expect(terminal.buffer.lines[0].toString(), '床前明月光');
    expect(terminal.buffer.lines[1].toString(), '疑是地上霜');

    terminal.resize(13, 10);
    expect(terminal.buffer.lines[0].toString(), '床前明月光疑');
    expect(terminal.buffer.lines[1].toString(), '是地上霜');
  });

  test('reflow() keeps boundary anchors on the next wrapped line', () {
    final terminal = Terminal()..resize(10, 10);
    terminal.write('0123456789');
    final anchor = terminal.buffer.lines[0].createAnchor(5);

    terminal.resize(5, 10);

    expect(anchor.attached, isTrue);
    expect(anchor.x, 0);
    expect(anchor.y, 1);
  });

  test('reflow() makes progress for a wide character at width 1', () {
    final terminal = Terminal()..resize(10, 10);
    terminal.write('床');

    expect(() => terminal.resize(1, 10), returnsNormally);
    for (final line in terminal.buffer.lines.toList()) {
      expect(line.length, 1);
    }
  });

  // A one-column screen holds a wide character without its second half,
  // which goes past the line's end, and a wider screen gives it back: a line
  // two columns wide is then full with it.
  test('reflow() widens wide characters a one-column screen holds', () {
    for (final (width, rows) in [
      (2, ['\u{1F468}', '\u{1F469}']),
      (3, ['\u{1F468}', '\u{1F469}']),
      (4, ['\u{1F468}\u{1F469}']),
    ]) {
      final terminal = Terminal()..resize(1, 3);
      terminal.write('\u{1F468}\u{1F469}');

      expect(() => terminal.resize(width, 3), returnsNormally);

      final lines = terminal.buffer.lines;
      for (var i = 0; i < rows.length; i++) {
        expect(lines[i].toString(), rows[i], reason: 'width $width row $i');
        expect(lines[i].getWidth(0), 2);
        expect(lines[i].isWrapped, i > 0);
      }
    }
  });

  // A wider screen gives a wide character a one-column screen holds its
  // second half in the character's rendition: cells an earlier narrowing hid
  // under it do not come back, and neither does a half of a character the
  // one-column screen replaced.
  test('a wide character on a one-column screen widens over hidden cells', () {
    final terminal = Terminal(reflowEnabled: false)..resize(3, 2);
    terminal.write('abc');
    terminal.resize(1, 2);
    terminal.write('\x1b[1;1H\u{1F468}');
    terminal.resize(3, 2);

    expect(terminal.buffer.lines[0].toString(), '\u{1F468}c');
    expect(terminal.buffer.lines[0].getCodePoint(1), 0);

    // Without a reflow too, as on the alternate screen, where a second half
    // the glyph got in another rendition is not kept.
    final alternate = Terminal()..resize(2, 3);
    alternate.write('\x1b[?47h\u00A9\x1b[41m\uFE0F');
    alternate.resize(1, 3);
    alternate.resize(2, 3);
    expect(alternate.buffer.lines[0].getWidth(0), 2);
    expect(alternate.buffer.lines[0].getBackground(1), 0);

    // Nor does a second half given back once: narrowed again, the glyph
    // drops it, and a later widening finds nothing where the glyph went.
    for (final replace in ['x', '\x1b[X', '\x1b[P']) {
      final terminal = Terminal()..resize(1, 5);
      terminal.write('\x1b[?47h\x1b[7;32;41m\u754C');
      terminal
        ..resize(2, 5)
        ..resize(1, 5);
      terminal.write('\r\x1b[0m$replace');
      terminal.resize(2, 5);
      final cell = CellData.empty();
      terminal.buffer.lines[0].getCellData(1, cell);
      expect([cell.foreground, cell.background, cell.flags], [0, 0, 0],
          reason: replace);
    }

    for (final replace in ['x', '\x1b[X']) {
      final terminal = Terminal()..resize(1, 3);
      terminal.write('\x1b[41m\u754C\r\x1b[0m$replace');
      terminal.resize(3, 3);
      for (var column = 1; column < 3; column++) {
        expect(terminal.buffer.lines[0].getBackground(column), 0,
            reason: '$replace $column');
      }
    }
  });

  // Widening and narrowing again gives back what the one-column screen
  // held: the glyph in its rendition on its own row, the cursor waiting to
  // wrap after it, and no rows for its second half. Each round trip added
  // one before.
  test('reflow() round-trips a wide character on one column', () {
    final terminal = Terminal()..resize(1, 5);
    terminal.write('\x1b[7;32;41m\u754C');
    for (var trip = 0; trip < 3; trip++) {
      terminal
        ..resize(2, 5)
        ..resize(1, 5);

      final buffer = terminal.buffer;
      expect(buffer.lines.length, 5, reason: 'trip $trip');
      final cell = CellData.empty();
      buffer.lines[0].getCellData(0, cell);
      expect(
        [cell.content & CellContent.codepointMask, cell.background],
        [0x754C, CellColor.named | 1],
        reason: 'trip $trip',
      );
      expect(buffer.lines[1].getTrimmedLength(), 0, reason: 'trip $trip');
      expect([buffer.cursorY, buffer.cursorX, buffer.isWrapPending],
          [0, 0, true],
          reason: 'trip $trip');
    }
  });

  // An anchor right after a wide character, such as a Kitty placement's,
  // comes back to its cell after a one-column screen, as in the MonkeyMux
  // model, rather than one column further each time.
  test('reflow() brings an anchor after a wide character back', () {
    final terminal = Terminal()..resize(5, 4);
    terminal.write('a界');
    final anchor = terminal.buffer.lines[0].createAnchor(3);

    for (var trip = 0; trip < 2; trip++) {
      terminal
        ..resize(1, 4)
        ..resize(5, 4);
      expect(anchor.attached, isTrue, reason: 'trip $trip');
      expect([anchor.y, anchor.x], [0, 3], reason: 'trip $trip');
    }
  });

  // A narrowing to one column keeps a wide character, as printing it there
  // does, on a line of its own, and its second half gets none.
  test('reflow() keeps a wide character at width 1', () {
    final terminal = Terminal()..resize(2, 4);
    terminal.write('a\u{1F468}b');

    terminal.resize(1, 4);

    final lines = terminal.buffer.lines;
    expect([for (var i = 0; i < 4; i++) lines[i].getCodePoint(0)],
        ['a'.codeUnitAt(0), 0x1F468, 'b'.codeUnitAt(0), 0]);
    expect(lines[1].getWidth(0), 2);
    expect([for (var i = 0; i < 4; i++) lines[i].isWrapped],
        [false, true, true, false]);
  });

  // With one cell left on a line, a wide character goes to the next line
  // whole instead of leaving its first half in the last column.
  test('reflow() moves a wide character whole when one cell is left', () {
    final terminal = Terminal()..resize(3, 5);
    terminal.write('abc床');
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(4, 5);

    expect(terminal.buffer.lines[0].toString(), 'abc');
    expect(terminal.buffer.lines[1].toString(), '床');
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[1].getWidth(0), 2);
  });

  // A narrowing moves the end of a long line onto a wrapped line of its own.
  // Once an application erases that line, widening must not show its text
  // again at the end of the line it came from.
  test('reflow() does not bring back text erased after a narrowing', () {
    final terminal = Terminal()..resize(20, 4);
    terminal.write('AAAAAAAAAABBBBBBBBBB\r\n');
    terminal.resize(10, 4);
    expect(terminal.buffer.lines[1].toString(), 'BBBBBBBBBB');

    terminal.write('\x1b[1;1H\x1b[2K'); // the first row on screen is lines[1]
    terminal.resize(20, 4);

    expect(terminal.buffer.lines[0].toString(), 'AAAAAAAAAA');
    expect(terminal.buffer.getText(), isNot(contains('B')));
  });

  // The cursor stays on the cell it was on, wherever the reflow moves it.
  test('reflow() keeps the cursor on its cell', () {
    final terminal = Terminal()..resize(20, 5);
    terminal.write('0123456789abcdef\r\nxy');

    terminal.resize(8, 5);

    final buffer = terminal.buffer;
    expect(buffer.lines[buffer.absoluteCursorY].toString(), 'xy');
    expect(buffer.cursorX, 2);
  });

  test('reflow() keeps a wrap pending after text that fills the line', () {
    final terminal = Terminal()..resize(8, 5);
    terminal.write('abcdefgh');

    terminal.resize(4, 5);
    terminal.write('i');

    final lines = terminal.buffer.lines;
    final row = terminal.buffer.absoluteCursorY;
    expect(lines[row - 1].toString(), 'efgh');
    expect(lines[row].toString(), 'i');
    expect(lines[row].isWrapped, isTrue);
  });

  // A cursor past the new edge on a line its text does not fill sits on the
  // last column; no wrap is pending there.
  test('reflow() does not make a wrap pending for a cursor it cuts short', () {
    final terminal = Terminal()..resize(8, 3);
    terminal.write('\x1b[1;8H');

    terminal.resize(4, 3);
    terminal.write('X');

    final buffer = terminal.buffer;
    expect(buffer.lines[buffer.absoluteCursorY].toString(), '   X');
    expect(buffer.lines[buffer.absoluteCursorY].isWrapped, isFalse);
  });

  // Nor with autowrap off: the next character replaces the last one.
  test('reflow() does not make a wrap pending with autowrap off', () {
    final terminal = Terminal()..resize(8, 3);
    terminal.write('\x1b[?7labcd');

    terminal.resize(4, 3);
    terminal.write('X');

    final buffer = terminal.buffer;
    expect(buffer.lines[buffer.absoluteCursorY].toString(), 'abcX');
  });

  // An application that redraws after a resize moves up from the cursor over
  // the rows its output takes once rewrapped. With the cursor kept on its
  // cell, that move covers exactly the old input area: nothing of it is left
  // behind and nothing above it is erased.
  test('reflow() lets a redraw from the cursor replace what it drew', () {
    final terminal = Terminal()..resize(30, 8);
    for (var line = 1; line <= 9; line++) {
      terminal.write('$line. some answer text\r\n');
    }
    String chrome(int width) {
      final rule = '─' * width;
      final status = ' status${' ' * (width - 8)}!';
      return '$status\r\n$rule\r\n❯ hi\r\n$rule\x1b[A\r\x1b[2C';
    }

    terminal.write('END-OF-ANSWER\r\n${chrome(30)}');
    terminal.resize(13, 16);
    terminal.write('\x1b[2D\x1b[6A\x1b[J${chrome(13)}');

    final text = terminal.buffer.getText();
    expect(' status'.allMatches(text).length, 1);
    expect(text, contains('END-OF-ANSWER'));
    expect(text, contains('9. some answe'));
  });

  // An erased row that still continues the text above it (ECH keeps the
  // wrap) stays after that text when a reflow joins them.
  test('reflow() keeps an erased continuation after its text', () {
    final terminal = Terminal()..resize(4, 3);
    terminal.write('abcde\x1b[2;1H\x1b[4X');
    expect(terminal.buffer.lines[1].isWrapped, isTrue);

    terminal.resize(8, 3);

    expect(terminal.buffer.lines[0].toString(), 'abcd');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });

  // A row that a scroll, a line insertion or a deletion moves next to a
  // different row starts a line of its own, so a later width change does not
  // join it to its new neighbour.
  for (final entry in {
    'region scroll up': '\x1b[2;4r\x1b[S\x1b[r',
    'delete line': '\x1b[2;1H\x1b[M',
    'region scroll down': '\x1b[3;4r\x1b[T\x1b[r',
    'insert line': '\x1b[3;1H\x1b[L',
  }.entries) {
    test('reflow() does not join rows moved by ${entry.key}', () {
      final terminal = Terminal()..resize(4, 4);
      terminal.write('HEAD\r\nabcdefgh');
      expect(terminal.buffer.lines[2].isWrapped, isTrue);

      terminal.write(entry.value);
      final lines = terminal.buffer.lines;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].toString() == 'efgh') {
          expect(lines[i].isWrapped, isFalse);
        }
      }

      terminal.resize(8, 4);
      expect(terminal.buffer.getText(), isNot(contains('HEADefgh')));
    });
  }

  // A tab with no stop left leaves the cursor past the edge with a wrap
  // pending; a reflow keeps that state, so the next character starts the
  // next line.
  for (final tab in ['\t', '\x1b[I']) {
    test(
        'reflow() keeps the wrap an exhausted ${tab == '\t' ? 'HT' : 'CHT'} left pending',
        () {
      final terminal = Terminal()..resize(8, 3);
      terminal.write(tab);

      terminal.resize(4, 3);
      terminal.write('X');

      expect(terminal.buffer.lines[0].toString(), '');
      expect(terminal.buffer.lines[1].toString(), 'X');
    });
  }

  test('lines has correct length after reflow', () {
    final terminal = Terminal();

    terminal.write('1234567890abcdefg');
    terminal.resize(10, 10);

    for (var i = 0; i < 10; i++) {
      expect(terminal.buffer.lines[i].length, 10);
    }

    terminal.resize(13, 10);
    for (var i = 0; i < 10; i++) {
      expect(terminal.buffer.lines[i].length, 13);
    }
  });
}
