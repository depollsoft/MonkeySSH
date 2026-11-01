import 'dart:math';

import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

// Cases shared with the MonkeyMux screen model are in
// grapheme_cluster_parity_test.dart; these cover what only the client keeps:
// the cells' storage, text extraction and mode reports.

const family = '\u{1F468}\u200D\u{1F469}'; // man ZWJ woman, two columns
const eAcute = 'e\u0301';

Terminal _terminal(int width, int height, {int maxLines = 1000}) =>
    Terminal(maxLines: maxLines)..resize(width, height);

BufferLine _row(Terminal terminal, int y) =>
    terminal.buffer.lines[terminal.buffer.scrollBack + y];

void main() {
  group('mode 2027', () {
    String query(Terminal terminal) {
      final output = <String>[];
      terminal.onOutput = output.add;
      terminal.write('\x1b[?2027\$p');
      return output.single;
    }

    test('is set at power-up and DECRQM reports it', () {
      final terminal = _terminal(10, 2);
      expect(terminal.graphemeClusterMode, isTrue);
      expect(query(terminal), '\x1b[?2027;1\$y');
      terminal.write('\x1b[?2027l');
      expect(terminal.graphemeClusterMode, isFalse);
      expect(query(terminal), '\x1b[?2027;2\$y');
      terminal.write('\x1b[?2027h');
      expect(query(terminal), '\x1b[?2027;1\$y');
    });

    test('RIS and a new program set it again; DECSTR leaves it', () {
      final terminal = _terminal(10, 2);
      terminal.write('\x1b[?2027l\x1b[!p');
      expect(terminal.graphemeClusterMode, isFalse);
      terminal.write('\x1bc');
      expect(terminal.graphemeClusterMode, isTrue);
      terminal.write('\x1b[?2027l');
      terminal.resetForNextProgram();
      expect(terminal.graphemeClusterMode, isTrue);
    });

    test('VS15 leaves the old right half an ordinary empty cell', () {
      final terminal = _terminal(10, 2);
      terminal.write('\u231A\uFE0E');
      final line = _row(terminal, 0);
      expect(line.getWidth(0), 1);
      // Content 0, like a cell nothing was written to: not a right half.
      expect(line.getContent(1), 0);
      expect(terminal.buffer.cursorX, 1);
    });

    test('VS15 keeps only the background on the old right half', () {
      // As the MonkeyMux model blanks it, so a replayed frame matches: an
      // inverse empty cell would paint its foreground colour as background.
      final terminal = _terminal(10, 2);
      terminal.write('\x1b[7;41m\u231A\uFE0E');
      final line = _row(terminal, 0);
      final half = CellData.empty();
      line.getCellData(1, half);
      expect(half.flags, 0);
      expect(half.foreground, 0);
      expect(half.background, CellColor.named | 1);
      expect(line.getSemanticContent(1), SemanticContent.output);
    });

    test(
        'a widened cluster keeps only the background on the right half of '
        'the wide glyph it covers', () {
      // As the MonkeyMux model blanks it; the shared case "a cluster widened
      // over a wide glyph blanks that glyph's right half" checks the cells.
      final terminal = _terminal(10, 2);
      terminal.write('\u2665\x1b[7;31;44m\u754C\x1b[2G\x1b[0m\uFE0F');
      final line = _row(terminal, 0);
      expect(line.getWidth(0), 2);
      expect(line.getContent(2), 0);
      final half = CellData.empty();
      line.getCellData(2, half);
      expect(half.flags, 0);
      expect(half.foreground, 0);
      expect(half.background, CellColor.named | 4);
    });

    test(
        'blanking half a wide glyph leaves the other half in the current '
        'background', () {
      // As the MonkeyMux model blanks it
      // (TestBlankingHalfAWideGlyphUsesTheCurrentBackground): an erase, a
      // glyph printed over the second half, and a wide glyph that does not
      // fit in the last column.
      for (final (input, blanks) in [
        ('\x1b[41m\x1b[1;3H界\x1b[44m\x1b[1;4H界', [2, 3]),
        ('\x1b[41m界\x1b[44m\x1b[2G\x1b[X', [0, 1]),
        ('\x1b[41m界\x1b[44m\x1b[1;1H\x1b[X', [0, 1]),
        ('\x1b[41m界\x1b[44m\x1b[2Gx', [0]),
      ]) {
        final terminal = _terminal(4, 3);
        terminal.write(input);
        final line = _row(terminal, 0);
        final cell = CellData.empty();
        for (final column in blanks) {
          line.getCellData(column, cell);
          expect(cell.content, 0, reason: '$input $column');
          expect(cell.background, CellColor.named | 4,
              reason: '$input $column');
        }
      }
    });

    test('covers both screens', () {
      final terminal = _terminal(10, 2);
      terminal.write('\x1b[?2027l\x1b[?1049h$family');
      expect(_row(terminal, 0).getGrapheme(0), '\u{1F468}\u200D');
      terminal.write('\x1b[?1049l');
      expect(terminal.graphemeClusterMode, isFalse);
    });
  });

  group('cell storage', () {
    test('marks a cluster cell in its content word only', () {
      final terminal = _terminal(10, 2);
      terminal.write('a$family');
      final line = _row(terminal, 0);
      final cell = CellData.empty();

      line.getCellData(0, cell);
      expect(cell.content & CellContent.graphemeFlag, 0);
      expect(cell.graphemeExtras, isEmpty);
      expect(line.hasGraphemeExtras(0), isFalse);

      line.getCellData(1, cell);
      expect(cell.content & CellContent.graphemeFlag, isNot(0));
      expect(cell.content & CellContent.codepointMask, 0x1F468);
      expect(cell.content >> CellContent.widthShift, 2);
      expect(cell.graphemeExtras, [0x200D, 0x1F469]);
      expect(line.hasGraphemeExtras(1), isTrue);
      expect(line.getCodePoint(1), 0x1F468);
      expect(line.getWidth(1), 2);
      expect(line.getGraphemeExtras(1), [0x200D, 0x1F469]);
      expect(line.getGrapheme(1), family);
      expect(line.getGrapheme(2), '');
    });

    test('keeps at most 15 code points after the base', () {
      final marks = '\u0301' * 20;
      for (final mode in ['h', 'l']) {
        final terminal = _terminal(10, 2);
        terminal.write('\x1b[?2027${mode}e${marks}x');
        final line = _row(terminal, 0);
        expect(line.getGraphemeExtras(0), List.filled(15, 0x301));
        expect(line.getGrapheme(1), 'x');
      }
    });

    test('a hash of the cell tells clusters apart', () {
      final terminal = _terminal(10, 2);
      terminal.write('e\u0301 e\u0302');
      final line = _row(terminal, 0);
      final a = CellData.empty();
      final b = CellData.empty();
      line.getCellData(0, a);
      line.getCellData(2, b);
      expect(a.content, b.content);
      expect(a.getHash(), isNot(b.getHash()));
    });

    test('an overwrite or an erase drops the extras', () {
      // Each erase, and the columns it clears: an acute e at 0 and a wide
      // cluster at 1 and 2.
      final erases = {
        'EL': ('\r\x1b[K', [0, 1]),
        'EL 1': ('\x1b[1K', [0, 1]),
        'ED': ('\x1b[2J', [0, 1]),
        'ECH': ('\r\x1b[3X', [0, 1]),
        'overwrite': ('\rxyz', [0, 1]),
        'ECH on the right half': ('\x1b[1;3H\x1b[1X', [1]),
        'a glyph on the right half': ('\x1b[1;3Hx', [1]),
      };
      for (final MapEntry(key: name, value: (erase, cleared))
          in erases.entries) {
        final terminal = _terminal(10, 2);
        terminal.write('$eAcute$family');
        terminal.write(erase);
        final line = _row(terminal, 0);
        for (final x in cleared) {
          expect(line.hasGraphemeExtras(x), isFalse, reason: '$name at $x');
          expect(line.getGraphemeExtras(x), isEmpty, reason: '$name at $x');
        }
        if (!cleared.contains(0)) {
          expect(line.getGrapheme(0), eAcute, reason: name);
        }
      }
    });

    test('ICH and DCH move clusters with their cells', () {
      final terminal = _terminal(10, 2);
      terminal.write('a${eAcute}b$family');
      terminal.write('\r\x1b[2@');
      final line = _row(terminal, 0);
      expect(line.getText(), '  a${eAcute}b$family');
      expect(line.getGrapheme(3), eAcute);
      expect(line.getGrapheme(5), family);
      expect(line.hasGraphemeExtras(0), isFalse);

      terminal.write('\x1b[3P');
      expect(line.getText(), '${eAcute}b$family');
      expect(line.getGrapheme(0), eAcute);
      expect(line.getGrapheme(2), family);
      for (var x = 4; x < 10; x++) {
        expect(line.hasGraphemeExtras(x), isFalse, reason: 'column $x');
      }
    });

    test('ICH drops a cluster pushed past the edge', () {
      final terminal = _terminal(5, 2);
      terminal.write('abc$family\r\x1b[2@');
      final line = _row(terminal, 0);
      expect(line.getText(), '  abc');
      for (var x = 0; x < 5; x++) {
        expect(line.hasGraphemeExtras(x), isFalse, reason: 'column $x');
      }
    });

    test('IL, DL and scrolling move clusters with their rows', () {
      final terminal = _terminal(10, 4);
      terminal.write('\x1b[2H$eAcute\x1b[1H\x1b[L');
      expect(_row(terminal, 2).getGrapheme(0), eAcute);
      terminal.write('\x1b[1H\x1b[M');
      expect(_row(terminal, 1).getGrapheme(0), eAcute);
      terminal.write('\x1b[T');
      expect(_row(terminal, 2).getGrapheme(0), eAcute);
      terminal.write('\x1b[2;4r\x1b[S');
      expect(_row(terminal, 1).getGrapheme(0), eAcute);
    });

    test('clusters scroll into the scrollback and come back', () {
      final terminal = _terminal(10, 3);
      terminal.write('$family\r\n$eAcute\r\n\r\n\r\n');
      expect(terminal.buffer.scrollBack, 2);
      expect(terminal.buffer.lines[0].getGrapheme(0), family);
      expect(terminal.buffer.lines[1].getGrapheme(0), eAcute);

      // Growing pulls the rows back from the scrollback.
      terminal.resize(10, 5);
      expect(terminal.buffer.scrollBack, 0);
      expect(_row(terminal, 0).getGrapheme(0), family);
      expect(_row(terminal, 1).getGrapheme(0), eAcute);
    });

    test('a reflow carries clusters to their new rows and back', () {
      final terminal = _terminal(8, 4);
      final lines = terminal.buffer.lines;
      terminal.write('abcd${eAcute}f$family');
      expect(lines[0].getText(), 'abcd${eAcute}f$family');

      terminal.resize(4, 4);
      expect(lines[0].getText(), 'abcd');
      expect(lines[1].getText(), '${eAcute}f$family');
      expect(lines[1].isWrapped, isTrue);
      expect(lines[1].getGrapheme(0), eAcute);
      expect(lines[1].getGrapheme(2), family);
      for (var x = 0; x < 4; x++) {
        expect(lines[0].hasGraphemeExtras(x), isFalse);
      }

      // A wide cluster that no longer fits in the last column moves down.
      terminal.resize(7, 4);
      expect(lines[0].getText(), 'abcd${eAcute}f');
      expect(lines[1].getText(), family);
      expect(lines[1].getGrapheme(0), family);

      terminal.resize(8, 4);
      expect(lines[0].getText(), 'abcd${eAcute}f$family');
      expect(lines[0].getGrapheme(4), eAcute);
      expect(lines[0].getGrapheme(6), family);
      expect(lines[1].getText(), '');
      for (var x = 0; x < 8; x++) {
        expect(lines[1].hasGraphemeExtras(x), isFalse);
      }
    });

    test('a narrower screen without reflow keeps hidden clusters', () {
      final terminal = _terminal(8, 3);
      terminal.write('\x1b[?1049habcdef$eAcute');
      terminal.resize(4, 3);
      expect(_row(terminal, 0).getText(), 'abcd');
      terminal.resize(8, 3);
      expect(_row(terminal, 0).getText(), 'abcdef$eAcute');
      expect(_row(terminal, 0).getGrapheme(6), eAcute);
    });

    test('copyFrom copies clusters and truncate drops them', () {
      final terminal = _terminal(8, 2);
      terminal.write('a${eAcute}b$family');
      final source = _row(terminal, 0);
      final copy = BufferLine(8)..copyFrom(source, 0, 0, 8);
      expect(copy.getText(), 'a${eAcute}b$family');
      expect(copy.getGrapheme(3), family);

      final part = BufferLine(8)..copyFrom(source, 1, 4, 2);
      expect(part.getGrapheme(4), eAcute);
      expect(part.hasGraphemeExtras(1), isFalse);

      copy.truncate(3);
      copy.resize(8);
      expect(copy.getText(), 'a${eAcute}b');
      expect(copy.hasGraphemeExtras(3), isFalse);
    });

    test('Kitty placeholder diacritics are not kept as cluster text', () {
      final terminal = _terminal(10, 2);
      // Row 0, column 1 of image 1.
      terminal.write('\x1b[38;5;1m\u{10EEEE}\u0305\u030D');
      final line = _row(terminal, 0);
      expect(line.getCodePoint(0), kittyGraphicsPlaceholderCodePoint);
      expect(line.hasGraphemeExtras(0), isFalse);
    });
  });

  group('text', () {
    test('getText and selections include whole clusters', () {
      final terminal = _terminal(10, 2);
      terminal.write('a$eAcute$family\r\n${eAcute}x');
      expect(_row(terminal, 0).getText(), 'a$eAcute$family');
      expect(terminal.buffer.getText(), 'a$eAcute$family\n${eAcute}x');

      final selection = BufferRangeLine(CellOffset(1, 0), CellOffset(4, 0));
      expect(terminal.buffer.getText(selection), '$eAcute$family');
      final half = BufferRangeLine(CellOffset(1, 0), CellOffset(3, 0));
      expect(terminal.buffer.getText(half), eAcute);
    });

    test('legacy mode keeps joined code points too', () {
      final terminal = _terminal(10, 2);
      terminal.write('\x1b[?2027l$eAcute\u2764\uFE0F');
      expect(_row(terminal, 0).getText(), '$eAcute\u2764\uFE0F');
      expect(terminal.buffer.cursorX, 2);
    });
  });

  test('random edits leave every cell readable', () {
    // Every operation that moves or clears cells keeps the extras in step
    // with the cells; a flag left without its code points would throw here.
    final random = Random(2027);
    const pieces = [
      'a',
      'xyz',
      '\u754c',
      '\u{1F44D}\u{1F3FD}',
      eAcute,
      family,
      '\u2764\uFE0F',
      '\u231A\uFE0E',
      '\u0301',
      '\u200D',
      '\u{1F1FA}\u{1F1F8}',
      '\r\n',
      '\x1b[2@',
      '\x1b[3P',
      '\x1b[L',
      '\x1b[2M',
      '\x1b[S',
      '\x1b[T',
      '\x1b[K',
      '\x1b[1K',
      '\x1b[2X',
      '\x1b[J',
      '\x1b[4h',
      '\x1b[4l',
      '\x1b[?7l',
      '\x1b[?7h',
      '\x1b[?2027l',
      '\x1b[?2027h',
      '\x1b[2;5r',
      '\x1b[r',
      '\x1b[?1049h',
      '\x1b[?1049l',
      '\x1b[D',
      '\x1b[3C',
      '\x1b[H',
    ];
    final terminal = _terminal(12, 6, maxLines: 20);
    var clusters = 0;
    for (var step = 0; step < 4000; step++) {
      if (random.nextInt(40) == 0) {
        terminal.resize(2 + random.nextInt(14), 2 + random.nextInt(6));
      } else if (random.nextInt(30) == 0) {
        terminal
            .write('\x1b[${1 + random.nextInt(6)};${1 + random.nextInt(14)}H');
      } else {
        terminal.write(pieces[random.nextInt(pieces.length)]);
      }
      for (final buffer in [terminal.mainBuffer, terminal.altBuffer]) {
        for (var y = 0; y < buffer.lines.length; y++) {
          final line = buffer.lines[y];
          for (var x = 0; x < line.data.length ~/ 5; x++) {
            if (!line.hasGraphemeExtras(x)) continue;
            clusters++;
            expect(line.getCodePoint(x), isNot(0), reason: 'step $step');
            expect(
              line.getGraphemeExtras(x),
              hasLength(inInclusiveRange(1, BufferLine.maxGraphemeExtras)),
            );
          }
          line.getText();
        }
      }
    }
    expect(clusters, greaterThan(1000));
  });
}
