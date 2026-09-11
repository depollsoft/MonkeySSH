import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('BufferLine.eraseRange()', () {
    test('empty ranges do not access or erase adjacent cells', () {
      final line = BufferLine(4);
      line.setCell(0, 0x754c, 2, CursorStyle());
      for (final index in [0, 1, 4]) {
        line.eraseRange(index, index, CursorStyle());
      }
      expect(line.getCodePoint(0), 0x754c);
    });

    for (final start in [0, 1]) {
      test('erasing wide cell half $start clears both halves and anchors', () {
        final terminal = Terminal()..resize(4, 2);
        terminal.write('\x1b[41m界Z');
        final line = terminal.buffer.lines[0];
        final left = line.createAnchor(0);
        final right = line.createAnchor(1);
        final outside = line.createAnchor(2);
        final physicalPlacement = line.createAnchor(0);
        final erasedStyle = CursorStyle(background: 42);

        line.eraseRange(start, start + 1, erasedStyle,
            preservedAnchors: {physicalPlacement});

        for (var x = 0; x < 2; x++) {
          expect(line.getContent(x), 0);
          expect(line.getBackground(x), 42);
        }
        expect(line.getCodePoint(2), 'Z'.codeUnitAt(0));
        expect(left.attached, isFalse);
        expect(right.attached, isFalse);
        expect(outside.attached, isTrue);
        expect(physicalPlacement.attached, isTrue);
      });
    }
  });

  group('BufferLine.getText()', () {
    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(), 'Hello World');
    });

    test('getText() should support wide characters', () {
      final text = '😀😁😂🤣😃';
      final terminal = Terminal();
      terminal.write(text);
      expect(terminal.buffer.lines[0].getText(), equals(text));
    });

    test('can specify a range', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 5), 'Hello');
    });

    test('can handle invalid ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 100), 'Hello World');
    });

    test('can handle negative ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(-100, 100), 'Hello World');
    });

    test('can handle reversed ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(5, 0), '');
    });
  });

  group('BufferLine.getTrimmedLength()', () {
    test('can get trimmed length', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(), equals(text.length));
    });

    test('can get trimmed length with wide characters', () {
      final terminal = Terminal();
      final text = '😀😁😂🤣😃';

      terminal.write(text);

      expect(terminal.buffer.lines[0].getTrimmedLength(), equals(text.length));
    });

    test('can handle length larger than the line', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(1000), equals(text.length));
    });

    test('can handle negative start', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(-1000), equals(0));
    });
  });

  group('BufferLine.resize', () {
    test('can resize', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      line.resize(20);

      expect(line.length, equals(20));
    });
  });

  group('Buffer.createAnchor', () {
    test('works', () {
      final terminal = Terminal();
      final line = terminal.buffer.lines[3];
      final anchor = line.createAnchor(5);

      terminal.insertLines(5);
      expect(anchor.x, 5);
      expect(anchor.y, 8);

      terminal.buffer.clear();
      expect(line.attached, false);
      expect(anchor.attached, false);
      expect(() => anchor.y, throwsStateError);
      expect(() => anchor.offset, throwsStateError);
    });
  });
}
