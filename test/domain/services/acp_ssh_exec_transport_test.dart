import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/acp_ssh_exec_transport.dart';

class _MockSession extends Mock implements SSHSession {}

void main() {
  setUpAll(() => registerFallbackValue(Uint8List(0)));

  test('forwards stdout and writes while draining stderr errors', () async {
    final session = _MockSession();
    final stdout = StreamController<Uint8List>();
    final stderr = StreamController<Uint8List>();
    when(() => session.stdout).thenAnswer((_) => stdout.stream);
    when(() => session.stderr).thenAnswer((_) => stderr.stream);
    final writes = <Uint8List>[];
    when(() => session.write(any())).thenAnswer((call) {
      writes.add(call.positionalArguments.single as Uint8List);
    });
    final transport = AcpSshExecTransport(session);
    final received = transport.incoming.toList();
    stdout.add(Uint8List.fromList([1, 2]));
    stderr
      ..add(Uint8List.fromList([3]))
      ..addError(StateError('private provider error'));
    final input = <int>[4, 5];
    await transport.write(input);
    input[0] = 0;
    expect(writes.single, [4, 5]);
    await stdout.close();
    expect(await received, [
      [1, 2],
    ]);
    await transport.close();
    await stderr.close();
    verify(session.close).called(1);
  });

  test('close marks shutdown before invoking cancellation callbacks', () async {
    final session = _MockSession();
    late AcpSshExecTransport transport;
    late Future<void> reentrantClose;
    late Future<void> rejectedWrite;
    final stderr = StreamController<Uint8List>(
      onCancel: () {
        reentrantClose = transport.close();
        rejectedWrite = expectLater(transport.write([1]), throwsStateError);
      },
    );
    when(() => session.stderr).thenAnswer((_) => stderr.stream);
    transport = AcpSshExecTransport(session);
    final closing = transport.close();
    await closing;
    await rejectedWrite;
    await stderr.close();
    expect(reentrantClose, same(closing));
    verify(session.close).called(1);
    verifyNever(() => session.write(any()));
  });

  for (final failCancellation in [false, true]) {
    test('close shares cleanup and closes the channel with '
        'cancellation failure=$failCancellation', () async {
      final session = _MockSession();
      final cancellationStarted = Completer<void>();
      final finishCancellation = Completer<void>();
      final stderr = StreamController<Uint8List>(
        onCancel: () {
          cancellationStarted.complete();
          return finishCancellation.future;
        },
      );
      when(() => session.stderr).thenAnswer((_) => stderr.stream);
      final transport = AcpSshExecTransport(session);
      final first = transport.close();
      await cancellationStarted.future;
      var secondFinished = false;
      final second = transport.close();
      final observed = second.then<void>(
        (_) => secondFinished = true,
        onError: (Object _, StackTrace _) => secondFinished = true,
      );
      final firstCheck = expectLater(
        first,
        failCancellation ? throwsStateError : completes,
      );
      final secondCheck = expectLater(
        second,
        failCancellation ? throwsStateError : completes,
      );
      await expectLater(transport.write([1]), throwsStateError);
      final finishedBeforeCleanup = secondFinished;
      if (failCancellation) {
        finishCancellation.completeError(StateError('cancel failed'));
      } else {
        finishCancellation.complete();
      }
      await Future.wait([firstCheck, secondCheck, observed]);
      await stderr.close();
      expect(finishedBeforeCleanup, isFalse);
      verify(session.close).called(1);
      expect(transport.close(), same(first));
      verifyNever(() => session.write(any()));
    });
  }
}
