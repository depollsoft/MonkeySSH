import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  for (final cancel in ['\x18', '\x1a']) {
    for (var split = 0; split <= 5; split++) {
      test('CSI ${cancel.codeUnitAt(0)} cancellation at split $split', () {
        final terminal = Terminal()..write('keep');
        final sequence = '\x1b[2${cancel}J';
        terminal
          ..write(sequence.substring(0, split))
          ..write(sequence.substring(split));

        // CAN and SUB return to ground state without executing erase-display.
        // The byte that would have been the CSI final is now ordinary text.
        expect(terminal.buffer.getText().trimRight(), 'keepJ');
        terminal.write('\x1b[2J');
        expect(terminal.buffer.getText().trim(), isEmpty);
      });
    }
  }
}
