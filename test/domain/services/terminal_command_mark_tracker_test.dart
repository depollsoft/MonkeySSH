import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_command_mark_tracker.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('tracks OSC 133/633 command starts and iTerm2 marks', () {
    final terminal = Terminal()..resize(20, 4);
    final tracker = TerminalCommandMarkTracker()..attach(terminal);

    terminal.write('prompt\r\n');
    tracker.handlePrivateOsc('133', const ['C']);
    terminal.write('output\r\nnext\r\n');
    tracker.handlePrivateOsc('633', const ['C']);
    terminal.write('more\r\n');
    tracker.handlePrivateOsc('1337', const ['SetMark']);

    expect(tracker.debugMarkRows, [1, 3, 4]);
    expect(tracker.previousMarkRow(4), 3);
    expect(tracker.previousMarkRow(3), 1);
    expect(tracker.previousMarkRow(1), 4, reason: 'navigation wraps');
  });

  test('keeps command navigation and deduplication in the active buffer', () {
    final terminal = Terminal()..resize(20, 4);
    final tracker = TerminalCommandMarkTracker()..attach(terminal);
    addTearDown(tracker.reset);

    terminal.write('prompt\r\n');
    tracker.handlePrivateOsc('133', const ['C']);
    terminal.useAltBuffer();

    expect(tracker.markCount, 0);
    expect(tracker.previousMarkRow(4), isNull);
    terminal.write('alternate\r\n');
    expect(tracker.handlePrivateOsc('1337', const ['SetMark']), isTrue);
    terminal.write('next\r\n');
    tracker.handlePrivateOsc('633', const ['C']);
    expect(tracker.debugMarkRows, [1, 2]);
    expect(tracker.previousMarkRow(1), 2);

    terminal.useMainBuffer();
    expect(tracker.markCount, 1);
    expect(tracker.debugMarkRows, [1]);
    expect(tracker.previousMarkRow(4), 1);
    expect(tracker.handlePrivateOsc('133', const ['C']), isFalse);
  });

  test('prunes alternate-buffer anchors without losing main marks', () {
    final terminal = Terminal()..resize(20, 4);
    final tracker = TerminalCommandMarkTracker()..attach(terminal);
    addTearDown(tracker.reset);

    tracker.handlePrivateOsc('133', const ['C']);
    terminal
      ..useAltBuffer()
      ..write('\r\n');
    tracker.handlePrivateOsc('1337', const ['SetMark']);
    terminal.clearAltBuffer();
    expect(tracker.markCount, 0);
    terminal.useMainBuffer();
    expect(tracker.debugMarkRows, [0]);
  });

  test('enforces one retention cap across both buffers', () {
    final terminal = Terminal()..resize(20, 4);
    final tracker = TerminalCommandMarkTracker(maxRetainedMarks: 2)
      ..attach(terminal);
    addTearDown(tracker.reset);

    tracker.handlePrivateOsc('133', const ['C']);
    terminal.useAltBuffer();
    tracker.handlePrivateOsc('133', const ['C']);
    terminal
      ..useMainBuffer()
      ..write('\r\n');
    tracker.handlePrivateOsc('133', const ['C']);
    expect(tracker.debugMarkRows, [1]);
    terminal.useAltBuffer();
    expect(tracker.debugMarkRows, [0]);
  });

  test('deduplicates rows and evicts oldest marks over the cap', () {
    final terminal = Terminal()..resize(20, 2);
    final tracker = TerminalCommandMarkTracker(maxRetainedMarks: 2)
      ..attach(terminal);

    void mark(String code, List<String> args) =>
        tracker.handlePrivateOsc(code, args);
    mark('133', const ['C']);
    mark('1337', const ['SetMark']);
    terminal.write('\r\none\r\ntwo');
    mark('133', const ['C']);
    terminal.write('\r\nthree');
    mark('133', const ['C']);

    expect(tracker.markCount, 2);
    expect(tracker.debugMarkRows, [2, 3]);
  });
}
