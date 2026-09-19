import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
// fake_async is supplied by flutter_test; dependency manifests are outside this job.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';

void registerTmuxWindowLoaderTests() {
  group('tmux window loading', () {
    const windows = [
      TmuxWindow(
        index: 1,
        name: 'agent',
        paneTitle: '✨ Editing main.dart',
        isActive: true,
      ),
    ];
    for (final failOldLoad in [false, true]) {
      test(
        'bar recovery discards an old ${failOldLoad ? 'error' : 'result'}',
        () {
          fakeAsync((async) {
            final oldLoad = Completer<List<TmuxWindow>>();
            final freshLoad = Completer<List<TmuxWindow>>();
            var calls = 0;
            Future<List<TmuxWindow>> fetch() {
              calls++;
              if (calls == 1) return oldLoad.future;
              if (calls == 2) {
                return Future.value(const [
                  TmuxWindow(index: 0, name: 'recovered', isActive: true),
                ]);
              }
              return freshLoad.future;
            }

            final state = _LoaderState(fetch);
            final loader = state.loader;
            unawaited(loader.load());
            async.flushMicrotasks();
            expect(calls, 1);
            loader.invalidate();
            fetch().then((windows) => state.windows = windows);
            unawaited(loader.load());
            async.elapse(const Duration(milliseconds: 500));
            expect(calls, 2);
            if (failOldLoad) {
              oldLoad.completeError(StateError('old load'));
            } else {
              oldLoad.complete(const [
                TmuxWindow(index: 0, name: 'stale', isActive: true),
              ]);
            }
            async.flushMicrotasks();
            expect(calls, 3);
            expect(
              state.windows?.map((window) => window.name),
              isNot(contains('stale')),
            );
            async.elapse(const Duration(seconds: 1));
            freshLoad.complete(const [
              TmuxWindow(index: 0, name: 'fresh', isActive: true),
            ]);
            async.flushMicrotasks();
            expect(state.windows!.single.name, 'fresh');
            expect(calls, 3);
            loader.dispose();
          });
        },
      );
    }

    for (final (dispose, fail) in [
      (true, false),
      (true, true),
      (false, true),
    ]) {
      test(
        dispose
            ? 'does not run queued reload after disposal, failure=$fail'
            : 'ignores late failure after a newer window snapshot',
        () {
          fakeAsync((async) {
            final pending = Completer<List<TmuxWindow>>();
            var calls = 0;
            final state = _LoaderState(() {
              calls++;
              return pending.future;
            });
            unawaited(state.loader.load());
            async.flushMicrotasks();
            if (dispose) {
              unawaited(state.loader.load());
              state.loader.dispose();
            } else {
              state.loader.invalidate();
              state.windows = windows;
              expect(
                state.windows!.where(
                  (w) => w.displayTitle == '✨ Editing main.dart',
                ),
                hasLength(1),
              );
            }
            if (fail) {
              pending.completeError(Exception('late window failure'));
            } else {
              pending.complete(windows);
            }
            async
              ..flushMicrotasks()
              ..elapse(const Duration(seconds: 2));
            expect(state.error, isNull);
            expect(calls, 1);
            if (!dispose) {
              expect(
                state.windows!.where(
                  (w) => w.displayTitle == '✨ Editing main.dart',
                ),
                hasLength(1),
              );
              expect(
                state.windows,
                isNotNull,
                reason:
                    'The loaded snapshot remains available instead of pending',
              );
              state.loader.dispose();
            }
          });
        },
      );
    }

    test('recovers from a transient empty window reload', () {
      fakeAsync((async) {
        var calls = 0;
        final state = _LoaderState(
          () => Future.value(calls++ == 0 ? const [] : windows),
        );
        unawaited(state.loader.load());
        async.flushMicrotasks();
        expect(
          state.windows?.where(
                (w) => w.displayTitle == '✨ Editing main.dart',
              ) ??
              [],
          isEmpty,
        );
        async.elapse(const Duration(seconds: 2));
        expect(
          state.windows!.where((w) => w.displayTitle == '✨ Editing main.dart'),
          hasLength(1),
        );
        state.loader.dispose();
      });
    });

    test('contains SSH channel errors while loading windows', () {
      fakeAsync((async) {
        var calls = 0;
        final state = _LoaderState(() {
          calls++;
          return Future.error(
            SSHChannelOpenError(1, 'administratively prohibited'),
          );
        });
        var completed = false;
        unawaited(state.loader.load().then((_) => completed = true));
        async.flushMicrotasks();
        expect(
          completed,
          isTrue,
          reason: 'The channel error is contained by load',
        );
        expect(calls, 1);
        expect(state.error?.error, isA<SSHChannelOpenError>());
        state.loader.dispose();
      });
    });
  });
}

class _LoaderState {
  _LoaderState(Future<List<TmuxWindow>> Function() fetch) {
    loader = TmuxWindowLoader(
      fetch: fetch,
      currentWindows: () => windows,
      connectionId: () => 7,
      onChanged: (next, failure, {required shouldRecover}) {
        windows = next;
        error = failure;
      },
    );
  }
  late final TmuxWindowLoader loader;
  List<TmuxWindow>? windows;
  AsyncError? error;
}
