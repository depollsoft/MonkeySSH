// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

import '../../helpers/mocks.dart';

MonkeyMuxAcpBridgeService _unusedBridgeService() => MonkeyMuxAcpBridgeService(
  installer: MonkeyMuxInstallerService(
    manifestFuture: Future.value(
      const MonkeyMuxManifest(version: 'test', entries: []),
    ),
    remoteFileService: const RemoteFileService(),
  ),
);

void main() {
  testWidgets('capability binding applies the configured terminal open limit', (
    tester,
  ) async {
    final session = MockSshSession();
    final opening = Completer<SSHSession>();
    when(() => session.remoteIsWindows).thenReturn(false);
    when(() => session.execute('task')).thenAnswer((_) => opening.future);
    final connector = MonkeyMuxAcpBridgeConnector(
      bridgeService: _unusedBridgeService(),
      sessionResolver: (_) async => session,
      capabilityLimits: const AcpClientCapabilityLimits(
        terminalOpenTimeout: Duration(seconds: 3),
      ),
    );
    final binding = (await connector.resolveCapabilityBinding(42))!;
    var completed = false;
    final checked = expectLater(
      binding.terminalExecutor
          .start('task')
          .whenComplete(() => completed = true),
      throwsA(
        isA<AcpClientCapabilityException>().having(
          (error) => error.message,
          'message',
          'Terminal channel opening timed out',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(completed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, isTrue);
    await checked;
  });

  test(
    'capability operations resolve the replacement same-host SSH session',
    () async {
      final first = MockSshSession();
      final second = MockSshSession();
      final sftp = MockSftpClient();
      final firstTerminal = MockSSHSession();
      final secondTerminal = MockSSHSession();
      when(() => first.remoteIsWindows).thenReturn(true);
      when(() => first.execute('first')).thenAnswer((_) async => firstTerminal);
      when(second.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('/workspace'))
          .thenAnswer((_) async => '/workspace');
      when(() => second.execute('second'))
          .thenAnswer((_) async => secondTerminal);
      var activeSession = first;
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (hostId) async {
          expect(hostId, 42);
          return activeSession;
        },
      );
      final binding = (await connector.resolveCapabilityBinding(42))!;
      final existing = await binding.terminalExecutor.start('first');

      activeSession = second;
      expect(
        await binding.fileSystem.canonicalizeExistingPath('/workspace'),
        '/workspace',
      );
      final replacement = await binding.terminalExecutor.start('second');
      for (final terminal in [firstTerminal, secondTerminal]) {
        when(terminal.waitForExit).thenAnswer((_) async => null);
      }
      await existing.kill();
      await replacement.kill();

      verifyNever(first.sftp);
      verify(() => second.execute('second')).called(1);
      verify(() => firstTerminal.kill(SSHSignal.TERM)).called(1);
      verify(() => secondTerminal.kill(SSHSignal.TERM)).called(1);
    },
  );

  for (final (home, expected) in [
    ('/Users/demo', '/Users/demo/Code/project'),
    ('/C:/Users/demo', r'C:\Users\demo\Code\project'),
  ]) {
    test('canonicalizes tilde cwd under $home to native syntax', () async {
      final sftp = MockSftpClient();
      final session = MockSshSession();
      when(session.sftp).thenAnswer((_) async => sftp);
      when(() => session.remoteIsWindows).thenReturn(false);
      when(() => sftp.absolute('.')).thenAnswer((_) async => home);
      when(() => sftp.absolute('$home/Code/project'))
          .thenAnswer((_) async => '$home/Code/project');
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (_) async => session,
      );
      expect(
        await connector.resolveWorkingDirectory(1, '~/Code/project'),
        expected,
      );
    });
  }

  test(
    'trusts a stored absolute cwd on reconnect without opening SFTP',
    () async {
      var resolvedSession = false;
      final connector = MonkeyMuxAcpBridgeConnector(
        bridgeService: _unusedBridgeService(),
        sessionResolver: (_) async {
          resolvedSession = true;
          throw StateError('SFTP should not be needed');
        },
      );

      final resolved = await connector.resolveWorkingDirectory(
        1,
        '/Users/demo/Code/project',
        trustAbsolute: true,
      );

      expect(resolved, '/Users/demo/Code/project');
      expect(resolvedSession, isFalse);
    },
  );
}
