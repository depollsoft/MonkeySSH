import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/tabs.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TabStops', () {
    test('has default tab stops after created', () {
      final tabStops = TabStops();

      expect(tabStops.isSetAt(0), true);
      expect(tabStops.isSetAt(1), false);
      expect(tabStops.isSetAt(7), false);
      expect(tabStops.isSetAt(8), true);
      expect(tabStops.isSetAt(9), false);
      expect(tabStops.isSetAt(15), false);
      expect(tabStops.isSetAt(16), true);
    });
  });

  group('TabStops.find()', () {
    test('includes start', () {
      final tabStops = TabStops();
      expect(tabStops.find(0, 10), 0);
    });

    test('excludes end', () {
      final tabStops = TabStops();
      expect(tabStops.find(0, 8), 0);
      expect(tabStops.find(1, 9), 8);
    });
  });

  group('TabStops.findBackward()', () {
    test('includes start', () {
      final tabStops = TabStops();
      expect(tabStops.findBackward(8), 8);
      expect(tabStops.findBackward(9), 8);
      expect(tabStops.findBackward(15), 8);
    });

    test('returns null when nothing is set at or before start', () {
      final tabStops = TabStops()..clearAll();
      expect(tabStops.findBackward(20), isNull);
      expect(TabStops().findBackward(-1), isNull);
    });
  });

  group('CBT (CSI Ps Z) and CHT (CSI Ps I)', () {
    Terminal terminalAtColumn(int column) {
      final terminal = Terminal()..resize(80, 24);
      terminal.write('\x1b[${column + 1}G');
      expect(terminal.buffer.cursorX, column);
      return terminal;
    }

    test('CBT moves back one tab stop', () {
      // Without CBT, nano's own cursor model diverges from the buffer by the
      // skipped tab distance and a syntax-highlighted line renders garbled.
      final terminal = terminalAtColumn(19);
      terminal.write('\x1b[Z');
      expect(terminal.buffer.cursorX, 16);
    });

    test('CBT honours a repeat count', () {
      final terminal = terminalAtColumn(19);
      terminal.write('\x1b[2Z');
      expect(terminal.buffer.cursorX, 8);
    });

    test('CBT stops at column 0 instead of underflowing', () {
      final terminal = terminalAtColumn(3);
      terminal.write('\x1b[9Z');
      expect(terminal.buffer.cursorX, 0);
    });

    test('CBT from a tab stop moves to the previous one', () {
      final terminal = terminalAtColumn(16);
      terminal.write('\x1b[Z');
      expect(terminal.buffer.cursorX, 8);
    });

    test('CHT advances by the requested number of tab stops', () {
      final terminal = terminalAtColumn(1);
      terminal.write('\x1b[2I');
      expect(terminal.buffer.cursorX, 16);
    });

    test('CHT defaults to a single tab stop', () {
      final terminal = terminalAtColumn(1);
      terminal.write('\x1b[I');
      expect(terminal.buffer.cursorX, 8);
    });

    test('CBT respects cleared tab stops', () {
      final terminal = terminalAtColumn(19);
      // Clear the stop at column 16 so the next one back is column 8.
      terminal.write('\x1b[17G\x1b[0g');
      terminal.write('\x1b[20G\x1b[Z');
      expect(terminal.buffer.cursorX, 8);
    });
  });
}
