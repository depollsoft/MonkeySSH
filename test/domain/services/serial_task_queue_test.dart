import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/serial_task_queue.dart';

void main() {
  group('SerialTaskQueue', () {
    test('runs tasks in order and isolates a failed task', () async {
      final queue = SerialTaskQueue();
      final first = Completer<void>();
      final events = <String>[];
      final errors = <Object>[];

      final a = queue.run(() async {
        events.add('a');
        await first.future;
      });
      final b = queue.run<void>(
        () async => throw StateError('b'),
        onError: (error, _) => errors.add(error),
      );
      final c = queue.run(() async => events.add('c'));
      await pumpEventQueue();
      expect(events, ['a']);
      expect(queue.pending, isNotNull);

      first.complete();
      await a;
      await expectLater(b, throwsStateError);
      await c;
      expect(events, ['a', 'c']);
      expect(errors.single, isA<StateError>());
      await pumpEventQueue();
      expect(queue.pending, isNull);
    });
  });

  group('KeyedTaskGate', () {
    test(
      'serializes one key, leaves others free, and survives errors',
      () async {
        final gate = KeyedTaskGate<int>();
        final release = Completer<void>();
        final events = <String>[];

        final first = gate.run(1, () async {
          events.add('1a');
          await release.future;
          throw StateError('1a');
        });
        final second = gate.run(1, () async => events.add('1b'));
        final other = gate.run(2, () async => events.add('2'));
        expect(events, ['1a', '2']);
        await other;
        expect(gate.isRunning(1), isTrue);
        expect(gate.keys, [1]);

        release.complete();
        await expectLater(first, throwsStateError);
        await second;
        expect(events, ['1a', '2', '1b']);
        expect(gate.isRunning(1), isFalse);
      },
    );
  });
}
