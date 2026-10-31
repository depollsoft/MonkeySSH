import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// DECRQCRA (`CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y`) and XTCHECKSUM
/// (`CSI Ps # y`). The expected sums follow xterm's `xtermCheckRect` and the
/// cases Ghostty checks its own implementation with.
void main() {
  late List<String> output;

  Terminal newTerminal({int cols = 10, int rows = 5, int extension = 0}) {
    output = [];
    final terminal = Terminal(inputHandler: null)
      ..onOutput = output.add
      ..rectangularAreaChecksumEnabled = true
      ..defaultChecksumExtension = extension;
    terminal.resize(cols, rows);
    return terminal;
  }

  String reply(int id, int sum) =>
      '\x1bP$id!~${sum.toRadixString(16).toUpperCase().padLeft(4, '0')}\x1b\\';

  /// The checksum of the rectangle, as the terminal reports it.
  int checksum(Terminal terminal, String rect) {
    output.clear();
    terminal.write('\x1b[7;1;$rect*y');
    expect(output, hasLength(1));
    final match =
        RegExp(r'^\x1bP7!~([0-9A-F]{4})\x1b\\$').firstMatch(output[0]);
    expect(match, isNotNull, reason: output[0]);
    return int.parse(match!.group(1)!, radix: 16);
  }

  group('off by default', () {
    test('a default terminal answers neither DECRQCRA nor XTCHECKSUM', () {
      final replies = <String>[];
      final terminal = Terminal(inputHandler: null)..onOutput = replies.add;
      expect(terminal.rectangularAreaChecksumEnabled, isFalse);

      terminal.write('hello\x1b[1;1;1;1;1;5*y\x1b[*y\x1b[1#y');
      expect(replies, isEmpty);

      // The XTCHECKSUM sent while it was off changed nothing.
      terminal.rectangularAreaChecksumEnabled = true;
      terminal.write('\x1b[2;1;1;1;1;5*y');
      expect(replies, [reply(2, -0x214 & 0xffff)]);
    });

    test('the request does not print or move the cursor', () {
      final terminal = Terminal(inputHandler: null);
      terminal.write('ab\x1b[1;1;1;1;1;5*yc');
      expect(terminal.buffer.lines[0].toString(), startsWith('abc'));
      expect(terminal.buffer.cursorX, 3);
    });
  });

  test('replies with the request id and the negated DEC sum', () {
    final terminal = newTerminal();
    // "hello" sums to 0x214, which the DEC checksum negates.
    terminal.write('hello\x1b[3;1;1;1;1;5*y');
    expect(output, [reply(3, 0xFDEC)]);
  });

  test('XTCHECKSUM changes the sum until RIS or DECSTR restores the default',
      () {
    final terminal = newTerminal();
    terminal.write('hello\x1b[1#y');
    expect(checksum(terminal, '1;1;1;5'), 0x214);

    terminal.write('\x1bchello');
    expect(checksum(terminal, '1;1;1;5'), 0xFDEC);

    terminal.write('\x1b[1#y\x1b[!p');
    expect(checksum(terminal, '1;1;1;5'), 0xFDEC);

    terminal.defaultChecksumExtension = ChecksumExtension.positive;
    expect(checksum(terminal, '1;1;1;5'), 0x214);
    terminal.write('\x1b[#y');
    expect(checksum(terminal, '1;1;1;5'), 0xFDEC);
    terminal.write('\x1b[!p');
    expect(checksum(terminal, '1;1;1;5'), 0x214);
  });

  test('DEC trims blanks and skips cells never written to', () {
    final terminal = newTerminal();
    terminal.write('a b');
    const positive = ChecksumExtension.positive;

    terminal.defaultChecksumExtension = 0;
    expect(checksum(terminal, '1;1;1;10'), -(0x61 + 0x62) & 0xffff);
    terminal.defaultChecksumExtension = positive;
    expect(checksum(terminal, '1;1;1;10'), 0x61 + 0x62);
    // Untrimmed counts the space and the unwritten cells as spaces.
    terminal.defaultChecksumExtension = positive | ChecksumExtension.noTrim;
    expect(checksum(terminal, '1;1;1;10'), 0x61 + 0x62 + 0x20 * 8);
    // Unwritten cells become spaces, which are then trimmed.
    terminal.defaultChecksumExtension = positive | ChecksumExtension.undrawn;
    expect(checksum(terminal, '1;1;1;10'), 0x61 + 0x62);
  });

  test('DEC keeps only the first space of the rectangle', () {
    final terminal = newTerminal(extension: ChecksumExtension.positive);
    terminal.write(' a\r\n b');
    expect(checksum(terminal, ''), 0x20 + 0x61 + 0x62);
  });

  test('adds the VT100 video attributes unless told not to', () {
    final terminal = newTerminal(extension: ChecksumExtension.positive);
    terminal.write('\x1b[1;4ma\x1b[0;7;5m \x1b[0;8mb\x1b[0m');
    expect(
      checksum(terminal, '1;1;1;10'),
      0x61 + 0x80 + 0x10 + 0x20 + 0x20 + 0x40 + 0x62 + 0x08,
    );
    terminal.defaultChecksumExtension =
        ChecksumExtension.positive | ChecksumExtension.noAttributes;
    expect(checksum(terminal, '1;1;1;10'), 0x61 + 0x62);
  });

  test('extended attributes keep a blank from being trimmed', () {
    final terminal = newTerminal(extension: ChecksumExtension.positive);
    terminal.write('a\x1b[3m \x1b[0m \x1b[4:2m \x1b[0m');
    terminal.defaultChecksumExtension =
        ChecksumExtension.positive | ChecksumExtension.noAttributes;
    // The italic and the double-underlined blanks count; the plain one not.
    expect(checksum(terminal, '1;1;1;10'), 0x61 + 0x20 + 0x20);
  });

  test('DEC uses the 8-bit value, the full mode the code point', () {
    final terminal = newTerminal(extension: ChecksumExtension.positive);
    // é is 0xE9, masked to 7 bits; the euro sign is outside 8 bits.
    terminal.write('é€');
    expect(checksum(terminal, '1;1;1;10'), 0x69 + 0x1B);
    terminal.defaultChecksumExtension =
        ChecksumExtension.positive | ChecksumExtension.fullCodePoint;
    expect(checksum(terminal, '1;1;1;10'), 0xE9 + 0x20AC);
  });

  test('wide characters', () {
    final terminal = newTerminal(extension: ChecksumExtension.positive);
    terminal.write('橋');
    // DEC counts both halves as ESC.
    expect(checksum(terminal, '1;1;1;10'), 0x1B + 0x1B);
    terminal.defaultChecksumExtension =
        ChecksumExtension.positive | ChecksumExtension.fullCodePoint;
    expect(checksum(terminal, '1;1;1;10'), 0x6A4B);
    expect(checksum(terminal, '1;2;1;2'), 0);
  });

  test('the esctest variant reads one cell as its character or a space', () {
    // xterm's `checksumExtension: 23`, which esctest expects.
    final terminal = newTerminal(
      extension: ChecksumExtension.positive |
          ChecksumExtension.noAttributes |
          ChecksumExtension.noTrim |
          ChecksumExtension.fullCodePoint,
    );
    terminal.write('\x1b[1mx\x1b[0m\x1b[2C ');
    expect(checksum(terminal, '1;1;1;1'), 0x78);
    expect(checksum(terminal, '1;2;1;2'), 0x20);
    expect(checksum(terminal, '1;4;1;4'), 0x20);
  });

  group('rectangle', () {
    late Terminal terminal;

    setUp(() {
      terminal = newTerminal(extension: ChecksumExtension.positive);
      terminal.write('abc\r\ndef\r\nghi');
    });

    test('is inclusive and one-based', () {
      expect(checksum(terminal, '2;2;3;3'), 0x65 + 0x66 + 0x68 + 0x69);
    });

    test('defaults to the whole screen and is clamped to it', () {
      final all = 'abcdefghi'.codeUnits.reduce((a, b) => a + b);
      expect(checksum(terminal, ''), all);
      expect(checksum(terminal, '0;0;99;99'), all);
      expect(checksum(terminal, '2;3'), 0x66 + 0x69);
    });

    test('an empty rectangle sums to zero', () {
      expect(checksum(terminal, '1;3;1;2'), 0);
      expect(checksum(terminal, '3;1;2;1'), 0);
    });

    test('counts rows from the top margin under origin mode', () {
      terminal.write('\x1b[2;4r\x1b[?6h');
      expect(checksum(terminal, '1;1;1;3'), 0x64 + 0x65 + 0x66);
      expect(checksum(terminal, '2;1;9;1'), 0x67);
      terminal.write('\x1b[?6l');
      expect(checksum(terminal, '1;1;1;3'), 0x61 + 0x62 + 0x63);
    });

    test('reads the visible screen, not the scrollback', () {
      terminal.write('\r\njkl\r\nmno\r\npqr\r\nstu');
      expect(terminal.buffer.scrollBack, greaterThan(0));
      expect(checksum(terminal, '1;1;1;3'), 0x67 + 0x68 + 0x69);
    });
  });

  test('ignores a request with too many parameters or a private prefix', () {
    final terminal = newTerminal();
    terminal.write('hello\x1b[1;1;1;1;1;5;9*y\x1b[?1;1;1;1;1;5*y\x1b[1;2#y');
    expect(output, isEmpty);
    expect(checksum(terminal, '1;1;1;5'), 0xFDEC);
  });
}
