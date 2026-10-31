import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mocks.dart';

SshSession _session() => SshSession(
  connectionId: 1,
  hostId: 1,
  client: MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

void main() {
  test('Kitty graphics acknowledgements are off behind a multiplexer', () {
    final session = _session();
    final terminal = session.getOrCreateTerminal();
    expect(terminal.kittyGraphicsTransmissionReplies, isTrue);

    for (final backend in [RemoteMuxBackend.monkeyMux, RemoteMuxBackend.tmux]) {
      session.remoteMuxBackend = backend;
      expect(terminal.kittyGraphicsTransmissionReplies, isFalse);
    }
    session.remoteMuxBackend = null;
    expect(terminal.kittyGraphicsTransmissionReplies, isTrue);
  });

  testWidgets('a terminal made behind MonkeyMux sends no OK for a=T', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final session = _session()..remoteMuxBackend = RemoteMuxBackend.monkeyMux;
      final responses = <String>[];
      final terminal = session.getOrCreateTerminal()..onOutput = responses.add;
      expect(terminal.kittyGraphicsTransmissionReplies, isFalse);

      terminal.write('\x1b_Ga=T,i=1,f=32,s=1,v=1;/wAA/w==\x1b\\');
      var waited = 0;
      while (terminal.graphics.imageById(1) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      expect(terminal.graphics.imageById(1), isNotNull);
      expect(responses, isEmpty);
    });
  });
}
