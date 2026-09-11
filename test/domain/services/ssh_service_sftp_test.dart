import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSftpClient extends Mock implements SftpClient {}

void main() {
  late _MockSshClient client;
  late SshSession session;
  late _MockSftpClient oldClient;
  late _MockSftpClient replacement;

  setUp(() {
    client = _MockSshClient();
    oldClient = _MockSftpClient();
    replacement = _MockSftpClient();
    when(client.close).thenAnswer((_) async {});
    when(oldClient.close).thenAnswer((_) async {});
    when(replacement.close).thenAnswer((_) async {});
    session = SshSession(
      connectionId: 91,
      hostId: 2,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'tester',
      ),
    );
  });

  tearDown(() => session.close());

  test('concurrent SFTP opens share one client and cache it', () async {
    final open = Completer<SftpClient>();
    when(client.sftp).thenAnswer((_) => open.future);

    final first = session.sftp();
    final second = session.sftp();
    expect(second, same(first));
    open.complete(oldClient);

    expect(await first, same(oldClient));
    expect(await second, same(oldClient));
    expect(await session.sftp(), same(oldClient));
    verify(client.sftp).called(1);
    verifyNever(oldClient.close);

    session.discardSftpClient(await first);

    verify(oldClient.close).called(1);
  });

  for (final oldCompletesFirst in [true, false]) {
    test('invalidated SFTP open rejects all waiters and preserves replacement '
        'when old completes ${oldCompletesFirst ? 'first' : 'last'}', () async {
      final oldOpen = Completer<SftpClient>();
      final newOpen = Completer<SftpClient>();
      var opens = 0;
      when(
        client.sftp,
      ).thenAnswer((_) => opens++ == 0 ? oldOpen.future : newOpen.future);
      final oldFuture = session.sftp();
      final first = expectLater(oldFuture, throwsA(isA<SSHStateError>()));
      final second = expectLater(session.sftp(), throwsA(isA<SSHStateError>()));

      session.discardSftpOpen(oldFuture);
      final next = session.sftp();
      if (oldCompletesFirst) {
        oldOpen.complete(oldClient);
        await Future.wait([first, second]);
        newOpen.complete(replacement);
      } else {
        newOpen.complete(replacement);
        expect(await next, same(replacement));
        oldOpen.complete(oldClient);
        await Future.wait([first, second]);
      }

      expect(await next, same(replacement));
      expect(await session.sftp(), same(replacement));
      verify(oldClient.close).called(1);
      verifyNever(replacement.close);
      verify(client.sftp).called(2);
    });
  }

  test('null SFTP cleanup preserves pending and cached clients', () async {
    final open = Completer<SftpClient>();
    when(client.sftp).thenAnswer((_) => open.future);
    final pending = session.sftp();

    session.discardSftpClient(null);
    expect(session.sftp(), same(pending));
    open.complete(replacement);
    expect(await pending, same(replacement));

    session.discardSftpClient(null);
    expect(await session.sftp(), same(replacement));
    verifyNever(replacement.close);
    verify(client.sftp).called(1);
  });

  test('discarding a completed SFTP open releases its client', () async {
    when(client.sftp).thenAnswer((_) async => oldClient);
    final open = session.sftp();
    await open;

    session.discardSftpOpen(open);
    await pumpEventQueue();

    verify(oldClient.close).called(1);
    when(client.sftp).thenAnswer((_) async => replacement);
    expect(await session.sftp(), same(replacement));
  });

  test('shutdown closes the cached SFTP client', () async {
    when(client.sftp).thenAnswer((_) async => oldClient);
    await session.sftp();

    await session.close();

    verify(oldClient.close).called(1);
  });

  test('stale SFTP discard closes only the supplied client', () async {
    when(client.sftp).thenAnswer((_) async => replacement);
    await session.sftp();

    session.discardSftpClient(oldClient);

    verify(oldClient.close).called(1);
    verifyNever(replacement.close);
    expect(await session.sftp(), same(replacement));
    verify(client.sftp).called(1);
  });

  for (final standalone in [false, true]) {
    test('closes late ${standalone ? 'standalone' : 'shared'} SFTP client '
        'after session shutdown', () async {
      final open = Completer<SftpClient>();
      when(client.sftp).thenAnswer((_) => open.future);
      final result = expectLater(
        standalone ? session.openStandaloneSftp() : session.sftp(),
        throwsA(isA<SSHStateError>()),
      );

      await session.close();
      open.complete(oldClient);
      await result;

      verify(oldClient.close).called(1);
    });
  }

  test('rejects shared and standalone SFTP opens after shutdown', () async {
    when(client.sftp).thenAnswer((_) async => oldClient);
    await session.close();

    await expectLater(session.sftp(), throwsA(isA<SSHStateError>()));
    await expectLater(
      session.openStandaloneSftp(),
      throwsA(isA<SSHStateError>()),
    );

    verifyNever(client.sftp);
  });

  test(
    'does not retry SFTP negotiation after shutdown during backoff',
    () async {
      var opens = 0;
      when(client.sftp).thenAnswer((_) {
        if (opens++ == 0) {
          return Future<SftpClient>.error(
            SSHChannelOpenError(2, 'open failed'),
          );
        }
        return Future.value(oldClient);
      });
      final result = expectLater(session.sftp(), throwsA(isA<SSHStateError>()));
      await pumpEventQueue();

      await session.close();
      await result;

      verify(client.sftp).called(1);
    },
  );
}
