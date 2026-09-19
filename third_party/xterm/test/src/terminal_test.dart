import 'package:test/test.dart';
import 'package:xterm/core.dart';

void main() {
  group('Terminal.writeSilently', () {
    test('applies output to the buffer without notifying listeners', () {
      final terminal = Terminal();
      var notifications = 0;
      terminal.addListener(() => notifications++);

      terminal.writeSilently('hello');

      // The buffer reflects the write, but no repaint was requested.
      expect(terminal.buffer.lines[0].toString().trimRight(), 'hello');
      expect(notifications, 0);

      // A subsequent write() flushes the coalesced state with a single notify.
      terminal.write(' world');
      expect(terminal.buffer.lines[0].toString().trimRight(), 'hello world');
      expect(notifications, 1);
    });

    test('notifyListeners repaints the silently written state', () {
      final terminal = Terminal();
      var notifications = 0;
      terminal.addListener(() => notifications++);

      terminal
        ..writeSilently('a')
        ..writeSilently('b')
        ..writeSilently('c');
      expect(notifications, 0);

      // The host coalesces several silent slices into one repaint.
      terminal.notifyListeners();
      expect(notifications, 1);
      expect(terminal.buffer.lines[0].toString().trimRight(), 'abc');
    });
  });

  group('Terminal.inputHandler', () {
    test('can be set to null', () {
      final terminal = Terminal(inputHandler: null);
      expect(() => terminal.keyInput(TerminalKey.keyA), returnsNormally);
    });

    test('can be changed', () {
      final handler1 = _TestInputHandler();
      final handler2 = _TestInputHandler();
      final terminal = Terminal(inputHandler: handler1);

      terminal.keyInput(TerminalKey.keyA);
      expect(handler1.events, isNotEmpty);

      terminal.inputHandler = handler2;

      terminal.keyInput(TerminalKey.keyA);
      expect(handler2.events, isNotEmpty);
    });
  });

  group('MonkeyMux synchronized output', () {
    test('repaints only after the synchronized redraw ends', () {
      final terminal = Terminal()..resize(20, 2);
      var notifications = 0;
      terminal.addListener(() => notifications++);

      // The whole redraw (begin marker, intermediate frame, settled frame, end
      // marker) arrives in one buffer, mirroring how the server writes it. The
      // caller (the parse pump) drives the notification.
      terminal.writeSilently(
        '\x1b[?9002h\x1b[2J\x1b[Htemporary layout'
        '\x1b[2J\x1b[Hfinal layout\x1b[?9002l',
      );
      terminal.notifyListeners();

      expect(notifications, 1);
      expect(
        terminal.buffer.lines[0].toString().trimRight(),
        'final layout',
      );
    });

    test('holds the repaint while the transaction is open', () {
      final terminal = Terminal()..resize(20, 2);
      var notifications = 0;
      terminal.addListener(() => notifications++);

      // A caller notification that lands mid-transaction (e.g. a chunk boundary
      // between the begin and end markers) must not paint the hidden frame.
      terminal.writeSilently('\x1b[?9002h\x1b[2J\x1b[Htemporary layout');
      terminal.notifyListeners();
      expect(notifications, 0);

      terminal.writeSilently('\x1b[2J\x1b[Hfinal layout\x1b[?9002l');
      terminal.notifyListeners();
      expect(notifications, 1);
      expect(
        terminal.buffer.lines[0].toString().trimRight(),
        'final layout',
      );
    });

    test('writeSilently never notifies on its own', () {
      final terminal = Terminal()..resize(20, 2);
      var notifications = 0;
      terminal.addListener(() => notifications++);

      // writeSilently is always silent, including when it parses the closing
      // marker; the caller owns the single settled repaint.
      terminal.writeSilently(
        '\x1b[?9002hhidden\x1b[?9002lfinal layout',
      );
      expect(notifications, 0);
    });

    test('transport reset flushes an interrupted synchronized redraw', () {
      final terminal = Terminal();
      var notifications = 0;
      terminal.addListener(() => notifications++);

      terminal.writeSilently('\x1b[?9002hpartial');
      terminal.notifyListeners();
      expect(notifications, 0);

      // Resetting the transport mid-transaction (reattach / reconnect) must not
      // strand the held repaint: reset itself flushes it.
      terminal.resetHostResizeState();

      expect(notifications, 1);
    });

    test('terminal replies remain active while repaint is synchronized', () {
      final terminal = Terminal();
      final output = <String>[];
      var notifications = 0;
      terminal
        ..onOutput = output.add
        ..addListener(() => notifications++);

      terminal.writeSilently('\x1b[?9002h\x1b[c');
      terminal.notifyListeners();

      // Device-attribute reply still fires while the repaint is held.
      expect(output, isNotEmpty);
      expect(notifications, 0);

      terminal.writeSilently('\x1b[?9002l');
      terminal.notifyListeners();

      expect(notifications, 1);
    });
  });

  group('DEC 2026 synchronized output', () {
    test('tracks the mode for DECRQM without holding repaints', () {
      final terminal = Terminal()..resize(20, 2);
      var notifications = 0;
      terminal.addListener(() => notifications++);
      expect(terminal.synchronizedOutputMode, isFalse);

      // The atomic apply is owned by the session runtime, which withholds the
      // bytes of an open transaction. Once bytes reach the core they must
      // paint normally, so a program that dies mid-frame never freezes the
      // view (resize and scroll repaints still go through).
      terminal.write('\x1b[?2026hpartial');
      expect(terminal.synchronizedOutputMode, isTrue);
      expect(notifications, 1);

      terminal.write('\x1b[?2026l');
      expect(terminal.synchronizedOutputMode, isFalse);
      expect(notifications, 2);
    });

    test('transport reset clears the mode', () {
      final terminal = Terminal()..write('\x1b[?2026h');
      expect(terminal.synchronizedOutputMode, isTrue);
      terminal.resetHostResizeState();
      expect(terminal.synchronizedOutputMode, isFalse);
    });

    test('endSynchronizedOutput releases a held 9002 repaint', () {
      final terminal = Terminal()..resize(20, 2);
      var notifications = 0;
      terminal.addListener(() => notifications++);

      terminal.writeSilently('\x1b[?9002hpartial');
      terminal.notifyListeners();
      expect(terminal.isMonkeyMuxSynchronizedOutputOpen, isTrue);
      expect(notifications, 0);

      expect(terminal.endSynchronizedOutput(), isTrue);
      expect(terminal.isMonkeyMuxSynchronizedOutputOpen, isFalse);
      expect(notifications, 1);

      // Nothing was open: no repaint is emitted.
      expect(terminal.endSynchronizedOutput(), isFalse);
      terminal.notifyListeners();
      expect(notifications, 2);
    });
  });

  group('Terminal.resizeFromHost', () {
    test('ignores private host resizes unless explicitly enabled', () {
      final terminal = Terminal(maxLines: 10)..resize(80, 24);

      terminal.write('\x1b[?8;30;100t');

      expect(terminal.viewWidth, 80);
      expect(terminal.viewHeight, 24);
      expect(terminal.hostResizeGeneration, 0);
    });

    test('applies private host resizes when enabled by MonkeyMux', () {
      final terminal = Terminal(maxLines: 10)
        ..resize(80, 24)
        ..canResizeFromHost = () => true;

      terminal.write('\x1b[?8;30;100t');

      expect(terminal.viewWidth, 100);
      expect(terminal.viewHeight, 30);
      expect(terminal.hostResizeGeneration, 1);
    });
  });

  group('Terminal.mouseInput', () {
    test('can handle mouse events', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, isEmpty);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, ['\x1B[M ++']);
    });
  });

  group('Terminal.reflowEnabled', () {
    test('prevents reflow when set to false', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('preserves hidden cells when reflow is disabled', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello World');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('can be set at runtime', () {
      final terminal = Terminal(reflowEnabled: true);

      terminal.resize(5, 5);
      terminal.write('Hello World');
      terminal.reflowEnabled = false;
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), ' Worl');
      expect(terminal.buffer.lines[2].toString(), 'd');
    });
  });

  group('Terminal.mouseInput', () {
    test('applys to the main buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.mainBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });

    test('applys to the alternate buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.altBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });
  });

  group('Terminal.onPrivateOSC', () {
    test(r'works with \a end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x07');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x07');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x07');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x07');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test(r'works with \x1b\ end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x1b\\');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x1b\\');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x1b\\');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x1b\\');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test('do not receive common osc', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]0;hello world\x07');

      expect(lastCode, isNull);
      expect(lastData, isNull);
    });
  });
}

class _TestInputHandler implements TerminalInputHandler {
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return null;
  }
}
