import 'dart:async';

/// Runs async tasks one at a time, in submission order.
///
/// A failed task does not stop later tasks: its error reaches the caller of
/// [run] and, when given, the `onError` callback, but the queue moves on.
class SerialTaskQueue {
  Future<void>? _tail;

  /// Completes once every task queued so far has settled; null when idle.
  Future<void>? get pending => _tail;

  /// Queues [task] after every earlier task and returns its result.
  ///
  /// The task starts asynchronously even when the queue is idle.
  Future<T> run<T>(
    Future<T> Function() task, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    final operation = (_tail ?? Future<void>.value()).then((_) => task());
    final settled = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) =>
          onError?.call(error, stackTrace),
    );
    _tail = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_tail, settled)) {
          _tail = null;
        }
      }),
    );
    return operation;
  }
}

/// Runs at most one task per key at a time.
///
/// A caller for a busy key waits until the running task finishes, then
/// re-checks, so tasks for one key never overlap. Errors reach only the
/// caller whose task failed.
class KeyedTaskGate<K> {
  final Map<K, Completer<void>> _running = {};

  /// Keys whose task is currently running.
  Iterable<K> get keys => _running.keys;

  /// Whether a task for [key] is currently running.
  bool isRunning(K key) => _running.containsKey(key);

  /// Runs [task] once no other task for [key] is running.
  ///
  /// When [key] is idle, [task] starts synchronously.
  Future<T> run<T>(K key, Future<T> Function() task) async {
    while (true) {
      final running = _running[key];
      if (running == null) {
        break;
      }
      await running.future;
    }

    final done = _running[key] = Completer<void>();
    try {
      return await task();
    } finally {
      _running.remove(key);
      done.complete();
    }
  }
}
