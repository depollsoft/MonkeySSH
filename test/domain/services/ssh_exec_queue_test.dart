import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';

import '../../helpers/mocks.dart';
import 'ssh_exec_queue_crashlytics_cases.dart';

class _MockChannel extends Mock implements SSHChannel {}

void main() {
  group('ssh_exec_queue', () {
    tearDown(resetQueuedSshExecsForTesting);

    for (final lateResult in ['never', 'channel', 'error']) {
      test('bounded opens release queue slots with late $lateResult', () async {
        final openings = [Completer<SSHSession>(), Completer<SSHSession>()];
        final jobs = [
          for (final opening in openings)
            runQueuedSshExec(
              5,
              () =>
                  openSshExec(opening.future, const Duration(milliseconds: 10)),
            ),
        ];
        final errors = [
          for (final job in jobs)
            expectLater(job, throwsA(isA<TimeoutException>())),
        ];
        final next = runQueuedSshExec(5, () async => 'next');
        expect(activeQueuedSshExecCountForTesting(5), 2);
        expect(pendingQueuedSshExecCountForTesting(5), 1);
        await Future.wait(errors);
        expect(await next, 'next');
        expect(activeQueuedSshExecCountForTesting(5), 0);
        expect(pendingQueuedSshExecCountForTesting(5), 0);
        final channels = <SSHSession>[];
        for (final opening in openings) {
          if (lateResult == 'channel') {
            final channel = MockSSHSession();
            when(() => channel.channel).thenReturn(_MockChannel());
            channels.add(channel);
            opening.complete(channel);
          } else if (lateResult == 'error') {
            opening.completeError(StateError('late failure'));
          }
        }
        await pumpEventQueue();
        for (final channel in channels) {
          final underlying = channel.channel;
          verify(underlying.destroy).called(1);
        }
      });
    }

    for (final peerCloses in [true, false]) {
      test('abandoned exec cleanup destroys the channel when the peer '
          '${peerCloses ? 'closes' : 'ignores EOF'}', () async {
        final session = MockSSHSession();
        final channel = _MockChannel();
        when(() => session.channel).thenReturn(channel);
        when(() => session.done).thenAnswer(
          (_) => peerCloses ? Future.value() : Completer<void>().future,
        );

        await closeAbandonedSshExec(
          session,
          grace: const Duration(milliseconds: 1),
        );

        verify(session.close).called(1);
        verify(channel.destroy).called(1);
      });
    }

    test('limits normal exec jobs per connection', () async {
      final startedJobs = <int>[];
      final completers = List.generate(5, (_) => Completer<int>());
      final futures = [
        for (var index = 0; index < completers.length; index++)
          runQueuedSshExec(1, () {
            startedJobs.add(index);
            return completers[index].future;
          }),
      ];

      await pumpEventQueue();

      expect(startedJobs, [0, 1]);
      expect(activeQueuedSshExecCountForTesting(1), 2);
      expect(pendingQueuedSshExecCountForTesting(1), 3);

      completers[0].complete(0);
      await pumpEventQueue();

      expect(startedJobs, [0, 1, 2]);
      expect(activeQueuedSshExecCountForTesting(1), 2);
      expect(pendingQueuedSshExecCountForTesting(1), 2);

      for (var index = 1; index < completers.length; index++) {
        completers[index].complete(index);
      }

      expect(await Future.wait(futures), [0, 1, 2, 3, 4]);
    });

    test(
      'keeps low-priority discovery from occupying every exec slot',
      () async {
        final startedJobs = <String>[];
        final lows = List.generate(4, (_) => Completer<String>());
        final normal = Completer<String>();

        final lowFutures = [
          for (var index = 0; index < lows.length; index++)
            runQueuedSshExec(2, () {
              startedJobs.add('low-$index');
              return lows[index].future;
            }, priority: SshExecPriority.low),
        ];

        await pumpEventQueue();

        expect(startedJobs, ['low-0']);
        expect(activeQueuedSshExecCountForTesting(2), 1);
        expect(pendingQueuedSshExecCountForTesting(2), 3);

        final normalFuture = runQueuedSshExec(2, () {
          startedJobs.add('normal');
          return normal.future;
        });

        await pumpEventQueue();

        expect(startedJobs, ['low-0', 'normal']);
        expect(activeQueuedSshExecCountForTesting(2), 2);
        expect(pendingQueuedSshExecCountForTesting(2), 3);

        normal.complete('normal');
        await pumpEventQueue();

        expect(startedJobs, ['low-0', 'normal']);

        lows[0].complete('low-0');
        await pumpEventQueue();

        expect(startedJobs, ['low-0', 'normal', 'low-1']);

        for (var index = 1; index < lows.length; index++) {
          lows[index].complete('low-$index');
        }

        expect(await Future.wait([...lowFutures, normalFuture]), [
          'low-0',
          'low-1',
          'low-2',
          'low-3',
          'normal',
        ]);
      },
    );

    test('a queued job runs in the zone it was submitted from', () async {
      const tag = #submitter;
      final release = Completer<void>();
      final seen = <String, Object?>{};
      Future<void> submit(String name, {Future<void>? hold}) => runZoned(
        () => runQueuedSshExec(9, () async {
          seen[name] = Zone.current[tag];
          await hold;
        }),
        zoneValues: {tag: name},
      );

      // Two jobs fill the connection; the third waits and is started by
      // whichever of them finishes, which must not lend it its own zone.
      final quiet = submit('quiet', hold: release.future);
      final other = submit('other', hold: release.future);
      final queued = submit('queued');
      expect(pendingQueuedSshExecCountForTesting(9), 1);
      release.complete();
      await Future.wait([quiet, other, queued]);

      expect(seen, {'quiet': 'quiet', 'other': 'other', 'queued': 'queued'});
    });

    test('propagates operation errors to the caller', () async {
      await expectLater(
        runQueuedSshExec<void>(3, () => throw StateError('boom')),
        throwsStateError,
      );
      expect(activeQueuedSshExecCountForTesting(3), 0);
      expect(pendingQueuedSshExecCountForTesting(3), 0);
    });

    test('a stale queue finishing after reset keeps its replacement', () async {
      final stale = Completer<void>();
      final staleFuture = runQueuedSshExec(4, () => stale.future);
      await pumpEventQueue();
      resetQueuedSshExecsForTesting();

      final blockers = [Completer<void>(), Completer<void>()];
      final active = [
        for (final blocker in blockers)
          runQueuedSshExec(4, () => blocker.future),
      ];
      final queued = runQueuedSshExec(4, () async => 'queued');
      await pumpEventQueue();
      expect(activeQueuedSshExecCountForTesting(4), 2);
      expect(pendingQueuedSshExecCountForTesting(4), 1);

      stale.complete();
      await staleFuture;
      await pumpEventQueue();

      expect(activeQueuedSshExecCountForTesting(4), 2);
      expect(pendingQueuedSshExecCountForTesting(4), 1);

      for (final blocker in blockers) {
        blocker.complete();
      }
      expect(await queued, 'queued');
      await Future.wait(active);
      expect(activeQueuedSshExecCountForTesting(4), 0);
    });
  });
  registerSshExecQueueCrashlyticsTests();
}
