import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:xterm/xterm.dart';

import '../../helpers/mock_ssh_exec_session.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends MockSessionWithChannel {}

const _begin = '\x1b[?2026h';
const _end = '\x1b[?2026l';

/// One Codex-style inline frame: erase the viewport rows from the composer
/// row down, then redraw the composer, all inside one 2026 transaction.
const _eraseComposer = '$_begin\x1b[6;1H\x1b[J';
const _drawComposer = '\x1b[6;1H> composer$_end';

/// One real Codex 0.155 inline-viewport frame captured through MonkeyMux on a
/// 69x55 client: erase from the viewport top (row 15) to the end of the
/// screen, then redraw the composer (`›` on row 17) and the status line.
const _codexFrame =
    '\x1b[?2026h\x1b[15;1H\x1b[J\x1b[15;2H\x1b[0m\x1b[49m\x1b[K\x1b[16;2H\x1b[0m\x1b[49m\x1b[K\x1b[17;27H\x1b[0m\x1b[49m\x1b[K\x1b[18;2H\x1b[0m\x1b[49m\x1b[K\x1b[15;1H \x1b[16;1H \x1b[17;1H\x1b[1m›\x1b[22m \x1b[2mAsk Codex to do anything\x1b[18;1H\x1b[22m \x1b[19;1H  \x1b[38;2;246;226;183;49mgpt-6-astra high\x1b[2m\x1b[39;49m · \x1b[22m\x1b[38;2;171;223;167;49m~/Code/MonkeySSH.worktrees/codex-composer-flick…\x1b[39m\x1b[49m\x1b[0m\x1b[15;1H\x1b[0 q\x1b[15;1H \x1b[39m\x1b[49m\x1b[0m\x1b[17;3H\x1b[?25h\x1b[?2026l';

String _row(Terminal terminal, int index) =>
    terminal.buffer.lines[index].toString().trimRight();

bool _showsCodexComposer(Terminal terminal) =>
    Iterable<int>.generate(terminal.viewHeight)
        .any((index) => _row(terminal, index).contains('›'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const SSHPtyConfig());
  registerFallbackValue(Uint8List(0));

  group('splitSynchronizedOutputHold', () {
    test('passes plain output straight through', () {
      final split = splitSynchronizedOutputHold('hello\x1b[?25l');
      expect(split.apply, 'hello\x1b[?25l');
      expect(split.hold, isEmpty);
    });

    test('withholds an open transaction from its begin marker', () {
      final split = splitSynchronizedOutputHold('before$_eraseComposer');
      expect(split.apply, 'before');
      expect(split.hold, _eraseComposer);
    });

    test('applies a closed transaction and holds the next open one', () {
      // Codex writes the next frame's begin marker right after the previous
      // end marker; the completed frame must apply now, not wait for the
      // following frame to finish.
      final split = splitSynchronizedOutputHold(
        '$_eraseComposer$_drawComposer${_begin}next',
      );
      expect(split.apply, '$_eraseComposer$_drawComposer');
      expect(split.hold, '${_begin}next');
    });

    test('treats MonkeyMux mode 9002 the same way', () {
      final split = splitSynchronizedOutputHold('a\x1b[?9002h\x1b[2Jb');
      expect(split.apply, 'a');
      expect(split.hold, '\x1b[?9002h\x1b[2Jb');
      expect(
        splitSynchronizedOutputHold('\x1b[?9002h\x1b[2Jb\x1b[?9002l').hold,
        isEmpty,
      );
    });

    test('keeps an outer 9002 open across an inner closed 2026 frame', () {
      final split = splitSynchronizedOutputHold(
        'x\x1b[?9002h$_eraseComposer$_drawComposer',
      );
      expect(split.apply, 'x');
      expect(split.hold, '\x1b[?9002h$_eraseComposer$_drawComposer');
    });

    test('withholds a trailing fragment of a begin marker', () {
      for (final fragment in [
        '\x1b',
        '\x1b[',
        '\x1b[?',
        '\x1b[?2',
        '\x1b[?2026',
      ]) {
        final split = splitSynchronizedOutputHold('text$fragment');
        expect(split.apply, 'text', reason: 'fragment ${fragment.length}');
        expect(split.hold, fragment, reason: 'fragment ${fragment.length}');
      }
      // A tail that cannot become a marker is not withheld.
      expect(splitSynchronizedOutputHold('text\x1b[?25').hold, isEmpty);
      expect(splitSynchronizedOutputHold('text\x1b]0;t').hold, isEmpty);
    });

    test('gives up holding past the size cap', () {
      final body = 'x' * (maxSynchronizedOutputHoldChars + 1);
      final split = splitSynchronizedOutputHold('$_begin$body');
      expect(split.hold, isEmpty);
      expect(split.apply.length, _begin.length + body.length);
    });

    test('handles empty input', () {
      final split = splitSynchronizedOutputHold('');
      expect(split.apply, isEmpty);
      expect(split.hold, isEmpty);
    });
  });

  group('session runtime synchronized output', () {
    late _MockSshClient client;
    late _MockExecSession shell;
    late StreamController<Uint8List> stdout;
    late SshSession session;
    late Terminal terminal;
    late int notifications;

    Future<void> feed(String data) async {
      stdout.add(Uint8List.fromList(utf8.encode(data)));
      await pumpEventQueue();
    }

    Future<void> start() async {
      client = _MockSshClient();
      shell = _MockExecSession();
      stdout = StreamController<Uint8List>();
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => stdout.stream);
      when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
      when(() => shell.done).thenAnswer((_) => Completer<void>().future);
      when(() => shell.write(any())).thenAnswer((_) {});
      when(shell.close).thenAnswer((_) {});
      session =
          SshSession(
              connectionId: 2026,
              hostId: 1,
              client: client,
              config: const SshConnectionConfig(
                hostname: 'example.com',
                port: 22,
                username: 'tester',
              ),
            )
            // Let a chunk without an escape introducer (which does not bypass the
            // output coalescer) reach the parser on the next event-queue turn.
            ..debugTerminalOutputFlushInterval = Duration.zero;
      terminal = session.getOrCreateTerminal()..resize(40, 6);
      notifications = 0;
      terminal.addListener(() => notifications++);
      await session.getShell(requestPty: false, command: 'codex');
      // Seed a settled frame with the composer on the last row.
      await feed('$_begin\x1b[1;1Htranscript$_drawComposer');
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 1);
    }

    Future<void> stop() async {
      await session.closeShell(waitForStreams: false);
      if (!stdout.isClosed) {
        await stdout.close();
      }
    }

    test('applies a frame split across chunks atomically', () async {
      await start();
      addTearDown(stop);

      // The erase half arrives alone, as SSH chunking routinely delivers it.
      // Nothing may be applied or painted: the composer must still be there.
      await feed(_eraseComposer);
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 1);

      await feed(_drawComposer);
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 2);
    });

    test('applies a completed frame even when the next one is open', () async {
      await start();
      addTearDown(stop);

      await feed('$_eraseComposer\x1b[6;1H> typed$_end$_begin\x1b[6;1H\x1b[J');
      expect(_row(terminal, 5), '> typed');
      expect(notifications, 2);

      await feed('\x1b[6;1H> typed more$_end');
      expect(_row(terminal, 5), '> typed more');
      expect(notifications, 3);
    });

    test('a lost end marker is flushed by the watchdog', () async {
      await start();
      addTearDown(stop);

      await feed(_eraseComposer);
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 1);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 1);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(_row(terminal, 5), isEmpty);
      expect(notifications, 2);

      // Output after the flush keeps flowing normally.
      await feed(_drawComposer);
      expect(_row(terminal, 5), '> composer');
      expect(notifications, 3);
    });

    test('closing the shell applies a withheld frame', () async {
      await start();

      await feed(_eraseComposer);
      expect(_row(terminal, 5), '> composer');

      await session.closeShell(waitForStreams: false);
      await stdout.close();
      expect(_row(terminal, 5), isEmpty);
    });

    test('a real Codex frame survives every chunk split', () async {
      await start();
      addTearDown(stop);
      terminal.resize(69, 55);
      await feed(_codexFrame);
      expect(_showsCodexComposer(terminal), isTrue);

      // SSH delivers a frame split at an arbitrary byte. Whatever the split,
      // the erased half must never be visible on its own.
      for (var split = 1; split < _codexFrame.length; split += 5) {
        final before = notifications;
        await feed(_codexFrame.substring(0, split));
        expect(
          _showsCodexComposer(terminal),
          isTrue,
          reason: 'composer erased after first chunk of split $split',
        );
        expect(notifications, before, reason: 'repainted mid-frame at $split');
        await feed(_codexFrame.substring(split));
        expect(
          _showsCodexComposer(terminal),
          isTrue,
          reason: 'composer missing after split $split',
        );
        expect(notifications, before + 1, reason: 'no repaint at $split');
      }
    });

    test('reports DEC 2026 as supported', () async {
      await start();
      addTearDown(stop);
      final writes = <String>[];
      when(() => shell.write(any())).thenAnswer((invocation) {
        writes.add(
          utf8.decode(invocation.positionalArguments.single as List<int>),
        );
      });

      await feed('\x1b[?2026\$p');
      expect(writes, ['\x1b[?2026;2\$y']);

      // A query inside an open transaction is answered once the frame is
      // applied, not while its bytes are withheld.
      await feed('$_begin\x1b[?2026\$p');
      expect(writes, hasLength(1));
      await feed(_end);
      expect(writes, hasLength(2));
      expect(writes.last, startsWith('\x1b[?2026;'));
    });
  });
}
