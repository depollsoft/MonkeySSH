import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/mocks.dart';

class _MockExecSession extends MockSessionWithChannel {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const SSHPtyConfig());
  registerFallbackValue(Uint8List(0));

  group('session runtime terminal replies', () {
    late MockSshClient client;
    late _MockExecSession shell;
    late StreamController<Uint8List> stdout;
    late SshSession session;
    late List<String> writes;

    Future<void> feed(String data) async {
      stdout.add(Uint8List.fromList(utf8.encode(data)));
      await pumpEventQueue();
    }

    Future<void> start() async {
      client = MockSshClient();
      shell = _MockExecSession();
      stdout = StreamController<Uint8List>();
      writes = [];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => stdout.stream);
      when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
      when(() => shell.done).thenAnswer((_) => Completer<void>().future);
      when(() => shell.write(any())).thenAnswer((invocation) {
        writes.add(
          utf8.decode(invocation.positionalArguments.single as List<int>),
        );
      });
      when(shell.close).thenAnswer((_) {});
      session = SshSession(
        connectionId: 33,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      )..debugTerminalOutputFlushInterval = Duration.zero;
      session.getOrCreateTerminal().resize(40, 6);
      await session.getShell(requestPty: false, command: 'tui');
      addTearDown(() async {
        await session.closeShell(waitForStreams: false);
        if (!stdout.isClosed) {
          await stdout.close();
        }
      });
    }

    test('answers each DEC mode query once, in stream order', () async {
      await start();

      await feed('\x1b[?1\$p\x1b[?1h\x1b[?1\$p\x1b[?2048\$p');
      expect(writes.join(), '\x1b[?1;2\$y\x1b[?1;1\$y\x1b[?2048;0\$y');
    });

    test('reports the modes the runtime tracks as of each query', () async {
      await start();

      await feed('\x1b[?2031\$p\x1b[?2031h\x1b[?2031\$p\x1b[?2031l');
      expect(writes.join(), '\x1b[?2031;2\$y\x1b[?2031;1\$y');

      writes.clear();
      await feed('\x1b[?2031\$p\x1b[?9001\$p');
      expect(writes.join(), '\x1b[?2031;2\$y\x1b[?9001;2\$y');
    });

    test('sends 1-based cursor reports unchanged', () async {
      await start();

      await feed('\x1b[2;5H\x1b[6n\x1b[?6n');
      expect(writes.join(), '\x1b[2;5R\x1b[?2;5R');
    });

    test('answers visibility queries from the terminal', () async {
      await start();
      final terminal = session.getOrCreateTerminal();

      await feed('\x1b[?998n');
      expect(writes.join(), '\x1b[?999;1n');

      writes.clear();
      await feed('\x1b[?2033h');
      terminal.visible = false;
      expect(writes.join(), '\x1b[?999;1n\x1b[?999;2n');
    });
  });
}
