import 'package:test/test.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/xterm.dart';

void registerInputHandlerTests() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });

    test('uses VT52 key mappings while DECANM is reset', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.arrowUp);
      expect(output.last, '\x1b[A');

      terminal.write('\x1b[?2l');
      expect(terminal.ansiMode, isFalse);
      terminal.keyInput(TerminalKey.arrowUp);
      expect(output.last, '\x1bA');
      terminal.keyInput(TerminalKey.tab, shift: true);
      expect(output.last, '\t');

      terminal.write('\x1b[?2h');
      expect(terminal.ansiMode, isTrue);
      terminal.keyInput(TerminalKey.arrowUp);
      expect(output.last, '\x1b[A');
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });
  });
}
