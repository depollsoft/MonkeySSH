import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Kitty keyboard protocol', () {
    test('sets, queries, pushes, and pops progressive enhancement flags', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=9u');
      expect(terminal.kittyKeyboardFlags, 9);
      expect(terminal.kittyKeyboardMode, isTrue);

      terminal.write('\x1b[?u');
      expect(output, ['\x1b[?9u']);

      terminal.write('\x1b[=2;2u');
      expect(terminal.kittyKeyboardFlags, 11);

      terminal.write('\x1b[=8;3u');
      expect(terminal.kittyKeyboardFlags, 3);

      terminal.write('\x1b[>1u');
      expect(terminal.kittyKeyboardFlags, 1);

      terminal.write('\x1b[>9u');
      expect(terminal.kittyKeyboardFlags, 9);

      terminal.write('\x1b[<u');
      expect(terminal.kittyKeyboardFlags, 1);

      terminal.write('\x1b[<u');
      expect(terminal.kittyKeyboardFlags, 3);

      terminal.write('\x1b[<u');
      expect(terminal.kittyKeyboardFlags, 0);
      expect(terminal.kittyKeyboardMode, isFalse);
    });

    test('maintains separate main and alternate screen flag stacks', () {
      final terminal = Terminal();

      terminal.write('\x1b[>1u');
      expect(terminal.kittyKeyboardFlags, 1);

      terminal.write('\x1b[?1049h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.kittyKeyboardFlags, 0);

      terminal.write('\x1b[>9u');
      expect(terminal.kittyKeyboardFlags, 9);

      terminal.write('\x1b[?1049l');
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.kittyKeyboardFlags, 1);
    });

    test('uses CSI-u for disambiguated modified text keys', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.keyA, ctrl: true);
      expect(output.removeLast(), '\x01');

      terminal.write('\x1b[>1u');

      expect(terminal.keyInput(TerminalKey.keyA), isFalse);
      expect(output, isEmpty);

      expect(terminal.keyInput(TerminalKey.keyA, ctrl: true), isTrue);
      expect(output.removeLast(), '\x1b[97;5u');

      expect(terminal.keyInput(TerminalKey.keyA, alt: true), isTrue);
      expect(output.removeLast(), '\x1b[97;3u');
    });

    test('keeps bare enter compatible but encodes modified enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[>1u');

      expect(terminal.keyInput(TerminalKey.enter), isTrue);
      expect(output.removeLast(), '\r');

      expect(terminal.keyInput(TerminalKey.enter, shift: true), isTrue);
      expect(output.removeLast(), '\x1b[13;2u');

      expect(terminal.keyInput(TerminalKey.enter, ctrl: true), isTrue);
      expect(output.removeLast(), '\x1b[13;5u');
    });

    test('reports release and repeat events when requested', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=3u');

      expect(
        terminal.keyInput(
          TerminalKey.arrowUp,
          type: TerminalKeyEventType.release,
        ),
        isTrue,
      );
      expect(output.removeLast(), '\x1b[1;1:3A');

      expect(
        terminal.keyInput(
          TerminalKey.arrowUp,
          type: TerminalKeyEventType.repeat,
        ),
        isTrue,
      );
      expect(output.removeLast(), '\x1b[1;1:2A');

      expect(
        terminal.keyInput(
          TerminalKey.enter,
          type: TerminalKeyEventType.release,
        ),
        isFalse,
      );

      terminal.write('\x1b[=11u');
      expect(
        terminal.keyInput(
          TerminalKey.enter,
          type: TerminalKeyEventType.release,
        ),
        isTrue,
      );
      expect(output.removeLast(), '\x1b[13;1:3u');
    });

    test('reports text input as associated codepoints when requested', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=24u');
      terminal.textInput('é');

      expect(output, ['\x1b[0;;233u']);
    });
  });
}
