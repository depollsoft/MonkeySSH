import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';

class _Client extends Mock implements SSHClient {}

class _Shell extends MockSessionWithChannel {}

void main() {
  testWidgets('Windows detection opening times out and closes a late probe', (
    tester,
  ) async {
    final client = _Client();
    final shell = _Shell();
    final opening = Completer<SSHSession>();
    when(
      () => client.remoteVersion,
    ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
    when(
      () => client.shell(
        pty: any(named: 'pty'),
        environment: any(named: 'environment'),
      ),
    ).thenThrow(SSHChannelRequestError('env rejected'));
    final commands = <String>[];
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) {
      commands.add(invocation.positionalArguments.first as String);
      return invocation.namedArguments[#pty] == null
          ? opening.future
          : Future.value(shell);
    });
    when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
    when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
    when(() => shell.done).thenAnswer((_) => Completer<void>().future);
    final session = SshSession(
      connectionId: 88003,
      hostId: 1,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'tester',
      ),
    );
    final result = session.getShell();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(await result, same(shell));
    expect(commands, hasLength(2));
    expect(commands.last, startsWith('cmd.exe /d /k'));
    final lateProbe = _Shell();
    opening.complete(lateProbe);
    await tester.pump();
    verify(lateProbe.channel.destroy).called(1);
    verifyNever(() => lateProbe.stdout);
    await session.closeShell(waitForStreams: false);
  });

  group('concurrent shell opens', () {
    late _Client client;
    late SshSession session;
    late _Shell shell;

    setUp(() {
      client = _Client();
      shell = _Shell();
      session = SshSession(
        connectionId: 123,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );
      when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
      when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
      when(() => shell.done).thenAnswer((_) => Completer<void>().future);
    });

    tearDown(() => session.closeShell(waitForStreams: false));

    test('ordinary getters share one pending channel negotiation', () async {
      final opening = Completer<SSHSession>();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => opening.future);
      final first = session.getShell(requestPty: false, command: 'first');
      final second = session.getShell(requestPty: false, command: 'second');
      final results = Future.wait([first, second]);
      opening.complete(shell);

      expect(await results, [same(shell), same(shell)]);
      expect(await session.getShell(), same(shell));
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
      verifyNever(shell.close);
    });

    test(
      'ordinary getters wait for forceNew teardown before joining',
      () async {
        final opening = Completer<SSHSession>();
        final started = Completer<void>();
        final commands = <String>[];
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) {
          commands.add(invocation.positionalArguments.first as String);
          if (!started.isCompleted) started.complete();
          return opening.future;
        });
        final replacement = session.getShell(
          requestPty: false,
          command: 'replacement',
          forceNew: true,
        );
        final ordinary = session.getShell(
          requestPty: false,
          command: 'ordinary',
        );
        final results = Future.wait([replacement, ordinary]);
        await started.future;
        opening.complete(shell);

        expect(await results, [same(shell), same(shell)]);
        expect(commands, hasLength(1));
        expect(commands.single, endsWith("sh 'replacement'"));
      },
    );

    test('failed shared negotiation can be retried', () async {
      final opening = Completer<SSHSession>();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => opening.future);
      final failure = StateError('channel rejected');
      final first = expectLater(
        session.getShell(requestPty: false, command: 'first'),
        throwsA(same(failure)),
      );
      final second = expectLater(
        session.getShell(requestPty: false, command: 'first'),
        throwsA(same(failure)),
      );
      opening.completeError(failure);
      await Future.wait([first, second]);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => shell);
      expect(
        await session.getShell(requestPty: false, command: 'retry'),
        same(shell),
      );
    });

    test(
      'forceNew invalidates an older open without losing the new one',
      () async {
        final oldOpening = Completer<SSHSession>();
        final newOpening = Completer<SSHSession>();
        final replacementStarted = Completer<void>();
        final discarded = _Shell();
        var opens = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) {
          if (opens++ == 0) return oldOpening.future;
          if (!replacementStarted.isCompleted) replacementStarted.complete();
          return newOpening.future;
        });
        final oldResult = expectLater(
          session.getShell(requestPty: false, command: 'old'),
          throwsA(isA<StateError>()),
        );
        final replacement = session.getShell(
          requestPty: false,
          command: 'new',
          forceNew: true,
        );
        await replacementStarted.future;
        oldOpening.complete(discarded);
        await oldResult;
        final joined = session.getShell(requestPty: false, command: 'ignored');
        final results = Future.wait([replacement, joined]);
        newOpening.complete(shell);

        expect(await results, [same(shell), same(shell)]);
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
        verify(discarded.close).called(1);
        verifyNever(() => discarded.stdout);
      },
    );
  });

  test(
    'shell arriving after close is discarded without replacing a new shell',
    () async {
      final client = _Client();
      final lateShell = _Shell();
      final replacement = _Shell();
      final opening = Completer<SSHSession>();
      final session = SshSession(
        connectionId: 123,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => opening.future);
      for (final shell in [lateShell, replacement]) {
        when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
        when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => shell.done).thenAnswer((_) => Completer<void>().future);
      }
      addTearDown(() => session.closeShell(waitForStreams: false));

      final pending = session.getShell(requestPty: false, command: 'first');
      final rejected = expectLater(pending, throwsA(isA<StateError>()));
      await session.closeShell(waitForStreams: false);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => replacement);
      expect(
        await session.getShell(requestPty: false, command: 'second'),
        same(replacement),
      );
      opening.complete(lateShell);
      await rejected;
      expect(await session.getShell(), same(replacement));
      verify(lateShell.close).called(1);
      verifyNever(() => lateShell.stdout);
    },
  );
}
