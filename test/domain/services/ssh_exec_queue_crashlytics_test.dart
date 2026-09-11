import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  const connectionId = 910;
  const service = TmuxService();

  tearDown(() async {
    await service.clearCache(connectionId);
    resetQueuedSshExecsForTesting();
  });

  for (final error in [
    SSHChannelOpenError(2, 'Session channel refused'),
    SSHStateError('Transport is closed'),
  ]) {
    test(
      'background redraw owns ${error.runtimeType}',
      () => _expectNoUnhandledErrors(() async {
        final session = _FakeSession(
          connectionId,
          () => Future<SSHSession>.error(error),
        );
        // Match the fire-and-forget call in TerminalScreen after a window switch.
        unawaited(service.refreshForegroundClients(session, 'main'));
        await pumpEventQueue();
        expect(session.executeCalls, 1);
      }),
    );

    test(
      'background theme refresh owns ${error.runtimeType}',
      () => _expectNoUnhandledErrors(() async {
        final session = _FakeSession(
          connectionId,
          () => Future<SSHSession>.error(error),
        );
        unawaited(
          service.refreshTerminalTheme(
            session,
            'main',
            TerminalThemes.defaultDarkTheme,
          ),
        );
        await pumpEventQueue();
        expect(session.executeCalls, 1);
      }),
    );

    final queries = <String, Future<Object?> Function(SshSession)>{
      'isTmuxActive': service.isTmuxActive,
      'foregroundSessionName': service.foregroundSessionName,
      'hasSession': (session) => service.hasSession(session, 'main'),
      'currentPaneContext': (session) =>
          service.currentPaneContext(session, 'main'),
      'hasForegroundClient': (session) =>
          service.hasForegroundClient(session, 'main'),
    };
    for (final query in queries.entries) {
      test(
        '${query.key} handles ${error.runtimeType}',
        () => _expectNoUnhandledErrors(() async {
          final probesPath = query.key != 'currentPaneContext';
          var calls = 0;
          final session = _FakeSession(connectionId, () {
            // Let the preliminary path probe succeed so the actual query
            // receives the SSH error rather than a cooldown exception.
            if (probesPath && calls++ == 0) {
              return Future.value(_FakeExec(output: 'sh\n/usr/bin/tmux\n'));
            }
            return Future<SSHSession>.error(error);
          });
          expect(await query.value(session), anyOf(isNull, isFalse));
          expect(session.executeCalls, probesPath ? 2 : 1);
        }),
      );
    }

    for (final synchronous in [true, false]) {
      test(
        'queue delivers ${error.runtimeType} once, synchronous=$synchronous',
        () => _expectNoUnhandledErrors(() async {
          final stack = StackTrace.current;
          var deliveries = 0;
          final blockers = [Completer<void>(), Completer<void>()];
          final running = [
            for (final blocker in blockers)
              runQueuedSshExec(connectionId, () => blocker.future),
          ];
          final failed =
              runQueuedSshExec<void>(connectionId, () {
                if (synchronous) Error.throwWithStackTrace(error, stack);
                return Future<void>.error(error, stack);
              }).then<void>(
                (_) => fail('Expected the operation to fail'),
                onError: (Object actual, StackTrace actualStack) {
                  deliveries++;
                  expect(actual, same(error));
                  expect(actualStack, same(stack));
                },
              );
          final next = runQueuedSshExec(connectionId, () async => 'next');
          for (final blocker in blockers) {
            blocker.complete();
          }
          await Future.wait([...running, failed]);
          expect(await next, 'next');
          expect(deliveries, 1);
          expect(activeQueuedSshExecCountForTesting(connectionId), 0);
          expect(pendingQueuedSshExecCountForTesting(connectionId), 0);
        }),
      );

      test(
        'tmux routes ${error.runtimeType}, synchronous=$synchronous',
        () => _expectNoUnhandledErrors(() async {
          final session = _FakeSession(connectionId, () {
            if (synchronous) {
              Error.throwWithStackTrace(error, StackTrace.current);
            }
            return Future<SSHSession>.error(error);
          });
          await expectLater(
            service.listWindows(session, 'main'),
            throwsA(same(error)),
          );
          // Repeated poll requests must not open more channels on this session.
          for (var attempt = 0; attempt < 29; attempt++) {
            await expectLater(
              service.listWindows(session, 'main'),
              throwsA(anyOf(isA<Exception>(), isA<SSHStateError>())),
            );
          }
          expect(session.executeCalls, 1);
        }),
      );
    }
  }

  test('background redraw does not swallow programming errors', () async {
    final error = StateError('Invalid local state');
    final session = _FakeSession(
      connectionId,
      () => Future<SSHSession>.error(error),
    );
    await expectLater(
      service.refreshForegroundClients(session, 'main'),
      throwsA(same(error)),
    );
  });

  testWidgets('watcher stops restarting after transport failure', (
    tester,
  ) async {
    final session = _FakeSession(
      connectionId,
      () => Future<SSHSession>.error(SSHStateError('Transport is closed')),
    );
    final watcher = service.watchWindowChanges(session, 'main').listen((_) {});
    try {
      await tester.pump();
      expect(session.executeCalls, 1);
      await tester.pump(const Duration(minutes: 1));
      expect(session.executeCalls, 1);
    } finally {
      // Dispose while listening so stream completion stays in fake time.
      // Awaiting cancel() can resume from Dart's shared real-zone null
      // future, leaving a subsequent cleanup await unflushed in fake time.
      var disposed = false;
      unawaited(service.clearCache(connectionId).then((_) => disposed = true));
      await tester.pump();
      unawaited(watcher.cancel());
      expect(disposed, isTrue);
    }
  });

  test('closed clients skip exec and watcher startup', () async {
    await _expectNoUnhandledErrors(() async {
      final client = _FakeClient()..isClosed = true;
      final session = _FakeSession(
        connectionId,
        () async => _FakeExec(),
        client: client,
      );
      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<SSHStateError>()),
      );
      final watcher = service
          .watchWindowChanges(session, 'main')
          .listen((_) {});
      await pumpEventQueue();
      expect(service.isExecChannelCoolingDown(session), isTrue);
      expect(session.executeCalls, 0);
      await watcher.cancel();
    });
  });

  test(
    'dead session stays dead after cache clear; replacement can execute',
    () => _expectNoUnhandledErrors(() async {
      final dead = _FakeSession(
        connectionId,
        () => Future<SSHSession>.error(SSHStateError('Transport is closed')),
      );
      await expectLater(
        service.listWindows(dead, 'main'),
        throwsA(isA<SSHStateError>()),
      );
      await service.clearCache(connectionId);
      await expectLater(
        service.listWindows(dead, 'main'),
        throwsA(isA<SSHStateError>()),
      );
      final replacement = _FakeSession(connectionId, () async => _FakeExec());
      expect(await service.listWindows(replacement, 'main'), isEmpty);
      expect(dead.executeCalls, 1);
      expect(replacement.executeCalls, 1);
    }),
  );

  test(
    'refusal backoff grows across expiry and resets only after success',
    () => _expectNoUnhandledErrors(() async {
      var now = DateTime.utc(2026, 9, 10);
      final service = TmuxService(execChannelNow: () => now);
      var refused = true;
      final session = _FakeSession(connectionId, () async {
        if (refused) {
          return Future<SSHSession>.error(
            SSHChannelOpenError(2, 'Session channel refused'),
          );
        }
        return _FakeExec();
      });
      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<SSHChannelOpenError>()),
      );
      now = now.add(const Duration(seconds: 2));
      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<SSHChannelOpenError>()),
      );
      expect(
        TmuxService.execChannelBackoffFailureCountForTesting(connectionId),
        2,
      );
      // The second cooldown is four seconds, not another two seconds.
      now = now.add(const Duration(seconds: 2));
      expect(service.isExecChannelCoolingDown(session), isTrue);
      refused = false;
      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<Exception>()),
      );
      expect(session.executeCalls, 2);
      now = now.add(const Duration(seconds: 2));
      expect(await service.listWindows(session, 'main'), isEmpty);
      expect(TmuxService.hasExecChannelBackoffEntry(connectionId), isFalse);
    }),
  );

  for (final lateError in [
    null,
    SSHChannelOpenError(2, 'Late channel refusal'),
    SSHStateError('Transport is closed'),
  ]) {
    test(
      'timeout owns the result before late ${lateError?.runtimeType}',
      () => _expectNoUnhandledErrors(() async {
        const fastService = TmuxService(
          execOpenTimeout: Duration(milliseconds: 1),
        );
        final opening = Completer<SSHSession>();
        final session = _FakeSession(connectionId, () => opening.future);
        var deliveries = 0;
        await fastService
            .listWindows(session, 'main')
            .then<void>(
              (_) => fail('Expected an open timeout'),
              onError: (Object error, StackTrace stack) {
                deliveries++;
                expect(error, isA<TimeoutException>());
              },
            );
        final exec = _FakeExec();
        if (lateError == null) {
          opening.complete(exec);
        } else {
          opening.completeError(lateError);
        }
        await pumpEventQueue();
        expect(deliveries, 1);
        expect(exec.destroyCalls, lateError == null ? 1 : 0);
        expect(activeQueuedSshExecCountForTesting(connectionId), 0);
        if (lateError is SSHStateError) {
          await service.clearCache(connectionId);
          await expectLater(
            service.listWindows(session, 'main'),
            throwsA(isA<SSHStateError>()),
          );
          expect(session.executeCalls, 1);
        }
      }),
    );
  }

  test(
    'late channel cleanup tolerates a closed transport',
    () => _expectNoUnhandledErrors(() async {
      const fastService = TmuxService(
        execOpenTimeout: Duration(milliseconds: 1),
      );
      final opening = Completer<SSHSession>();
      final session = _FakeSession(connectionId, () => opening.future);
      await expectLater(
        fastService.listWindows(session, 'main'),
        throwsA(isA<TimeoutException>()),
      );
      final exec = _FakeExec()
        ..closeError = SSHStateError('Transport is closed');
      opening.complete(exec);
      await pumpEventQueue();
      await service.clearCache(connectionId);
      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<SSHStateError>()),
      );
      expect(exec.destroyCalls, 1);
      expect(session.executeCalls, 1);
    }),
  );
}

Future<void> _expectNoUnhandledErrors(Future<void> Function() body) async {
  final unhandled = <Object>[];
  final completed = Completer<void>();
  runZonedGuarded(() {
    Future<void>(() async {
      await body();
      await pumpEventQueue();
    }).then(completed.complete, onError: completed.completeError);
  }, (error, stack) => unhandled.add(error));
  await completed.future;
  expect(unhandled, isEmpty);
}

class _FakeClient extends Fake implements SSHClient {
  @override
  bool isClosed = false;
}

class _FakeSession extends SshSession {
  _FakeSession(int connectionId, this.onExecute, {SSHClient? client})
    : super(
        connectionId: connectionId,
        hostId: 1,
        client: client ?? _FakeClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );

  final Future<SSHSession> Function() onExecute;
  int executeCalls = 0;

  @override
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty}) {
    executeCalls++;
    return onExecute();
  }
}

class _FakeExec extends Fake implements SSHSession {
  _FakeExec({this.output = ''});

  final String output;
  int closeCalls = 0;
  int destroyCalls = 0;
  SSHError? closeError;

  @override
  late final SSHChannel channel = _FakeExecChannel(this);

  @override
  Stream<Uint8List> get stdout => Stream.value(
    Uint8List.fromList(utf8.encode('${output}__flutty_tmux_exec_done__:0\n')),
  );

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => Completer<void>().future;

  @override
  void close() {
    closeCalls++;
    final error = closeError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }
}

class _FakeExecChannel extends Fake implements SSHChannel {
  _FakeExecChannel(this.session);
  final _FakeExec session;

  @override
  void destroy() {
    session.destroyCalls++;
    final error = session.closeError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }
}
