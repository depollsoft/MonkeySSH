import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_key_input.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('sendTerminalEnterInput', () {
    test('plain Enter matches keyInput', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      expect(output, ['\r']);
    });

    test('Shift+Enter matches keyInput newline encoding', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      // Legacy keytab: Enter+Shift → LF (newline without submit).
      expect(output, ['\n']);
    });

    test('plain Enter under LNM collapses CRLF only on the Enter path', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[20h');

      expect(terminal.lineFeedMode, isTrue);
      expect(terminal.keyInput(TerminalKey.enter), isTrue);
      expect(output, ['\r\n']);
      output.clear();

      // Paste of a single newline under LNM also emits exact CRLF — that must
      // not be rewritten by sendTerminalEnterInput's Enter-only collapse.
      terminal.paste('\n');
      expect(output, ['\r\n']);
      output.clear();

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\r']);
    });

    test('Alt+Enter applies meta-sends-escape when keytab drops Alt', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(terminal.keyInput(TerminalKey.enter, alt: true), isTrue);
      expect(output, ['\r']);
      output.clear();

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b\r']);
    });

    test('uses Kitty keyboard encoding when mode is active', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>1u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );

      expect(output, ['\x1b[13;2u']);
    });

    test('Kitty report-all mode encodes plain Enter as CSI-u', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>9u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: false,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b[13u']);
    });

    test('Kitty Alt+Enter keeps Pi enqueue encoding', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[>1u');

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
        ),
        isTrue,
      );
      expect(output, ['\x1b\r']);
      output.clear();

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
          type: TerminalKeyEventType.release,
        ),
        isTrue,
      );
      expect(output, isEmpty);
    });

    test('ignores non-press Enter events outside Kitty keyboard mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: true,
          altActive: false,
          ctrlActive: false,
          type: TerminalKeyEventType.repeat,
        ),
        isFalse,
      );
      expect(
        sendTerminalEnterInput(
          terminal,
          shiftActive: false,
          altActive: true,
          ctrlActive: false,
          type: TerminalKeyEventType.release,
        ),
        isFalse,
      );

      expect(output, isEmpty);
    });
  });

  test('sendTerminalEnterInput marks its writes as an Enter keystroke', () {
    final writes = <(String, bool)>[];
    final terminal = Terminal(
      onOutput: (data) => writes.add((data, isWritingTerminalEnterKey)),
    )..textInput('hi');
    for (final (shift, alt) in [(false, false), (true, false), (false, true)]) {
      sendTerminalEnterInput(
        terminal,
        shiftActive: shift,
        altActive: alt,
        ctrlActive: false,
      );
    }
    terminal.textInput('x');

    expect(writes, [
      ('hi', false),
      ('\r', true),
      ('\n', true),
      ('\x1b\r', true),
      ('x', false),
    ]);
    expect(isWritingTerminalEnterKey, isFalse);
  });

  group('TerminalEnterPacer', () {
    test('holds an Enter sent with text until the gap has passed', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026));
        final written = <String>[];
        // A soft keyboard commits the word and its space with the Return.
        final pacer = TerminalEnterPacer(write: written.add, now: clock.now)
          ..add('what?', enter: false)
          ..add(' ', enter: false)
          ..add('\r', enter: true);
        expect(written, ['what?', ' ']);

        async.elapse(const Duration(milliseconds: 110));
        // Anything typed meanwhile waits behind the Enter.
        pacer.add('n', enter: false);
        expect(written, ['what?', ' ']);

        async.elapse(const Duration(milliseconds: 39));
        expect(written, ['what?', ' ']);
        async.elapse(const Duration(milliseconds: 1));
        expect(written, ['what?', ' ', '\r', 'n']);
      });
    });

    test('sends an Enter at once when no text came just before it', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026));
        final written = <String>[];
        final pacer = TerminalEnterPacer(write: written.add, now: clock.now)
          ..add('\r', enter: true);
        expect(written, ['\r']);

        pacer.add('ls', enter: false);
        async.elapse(TerminalEnterPacer.defaultGap);
        pacer
          ..add('\r', enter: true)
          ..add('\r', enter: true);
        expect(written, ['\r', 'ls', '\r', '\r']);
      });
    });

    test('idle completes once a held Enter has gone out', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026));
        final written = <String>[];
        final pacer = TerminalEnterPacer(write: written.add, now: clock.now);
        expect(pacer.idle, isNull);

        var idle = false;
        pacer
          ..add('a', enter: false)
          ..add('\r', enter: true);
        unawaited(pacer.idle!.then((_) => idle = true));
        async
          ..elapse(const Duration(milliseconds: 149))
          ..flushMicrotasks();
        expect(idle, isFalse);
        async
          ..elapse(const Duration(milliseconds: 1))
          ..flushMicrotasks();
        expect(idle, isTrue);
        expect(written, ['a', '\r']);
        expect(pacer.idle, isNull);

        idle = false;
        pacer
          ..add('b', enter: false)
          ..add('\r', enter: true);
        unawaited(pacer.idle!.then((_) => idle = true));
        pacer.dispose();
        async.flushMicrotasks();
        expect(idle, isTrue);
      });
    });

    test('dispose drops a held Enter', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026));
        final written = <String>[];
        TerminalEnterPacer(write: written.add, now: clock.now)
          ..add('a', enter: false)
          ..add('\r', enter: true)
          ..dispose();

        async.elapse(const Duration(seconds: 1));
        expect(written, ['a']);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
