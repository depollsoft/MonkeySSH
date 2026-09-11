import 'dart:async';
import 'dart:collection';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'diagnostics_log_service.dart';

const _maxExecJobsPerConnection = 2;
const _maxLowPriorityExecJobsPerConnection = 1;

final _execQueues = <int, _SshExecQueue>{};

/// Priority for queued SSH exec jobs.
enum SshExecPriority {
  /// User-visible or correctness-critical work.
  normal,

  /// Background prefetching and discovery work that should not crowd out UI.
  low,
}

/// Runs [operation] through a bounded per-connection SSH exec queue.
///
/// SSH exec channels are single-use, so this does not reuse a channel. Instead,
/// it bounds short-lived exec channels per connection, preserving room for the
/// terminal, tmux watcher, SFTP, and other long-lived channels.
Future<T> runQueuedSshExec<T>(
  int connectionId,
  Future<T> Function() operation, {
  SshExecPriority priority = SshExecPriority.normal,
}) {
  final queue = _execQueues.putIfAbsent(
    connectionId,
    () => _SshExecQueue(connectionId),
  );
  return queue.run(operation, priority: priority);
}

/// Bounds channel creation and closes channels that arrive after the deadline.
/// Late opening failures are consumed without changing the timeout result.
Future<SSHSession> openSshExec(
  Future<SSHSession> opening,
  Duration timeout, {
  void Function(Object error, StackTrace stackTrace)? onLateError,
}) => opening.timeout(
  timeout,
  onTimeout: () {
    opening
        // SSHSession.close only sends EOF until the peer finishes. A command
        // that ignores EOF must not keep an abandoned session slot occupied.
        .then((session) => session.channel.destroy())
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            onLateError?.call(error, stackTrace);
          },
        )
        .ignore();
    throw TimeoutException('Timed out opening SSH exec channel', timeout);
  },
);

/// Clears queued exec state for tests.
@visibleForTesting
void resetQueuedSshExecsForTesting() {
  _execQueues.clear();
}

/// Returns the number of active queued exec jobs for tests.
@visibleForTesting
int activeQueuedSshExecCountForTesting(int connectionId) =>
    _execQueues[connectionId]?.activeCount ?? 0;

/// Returns the number of pending queued exec jobs for tests.
@visibleForTesting
int pendingQueuedSshExecCountForTesting(int connectionId) =>
    _execQueues[connectionId]?.pendingCount ?? 0;

class _SshExecQueue {
  _SshExecQueue(this.connectionId);

  final int connectionId;
  final _normalJobs = Queue<_QueuedSshExecJob<dynamic>>();
  final _lowJobs = Queue<_QueuedSshExecJob<dynamic>>();
  int _activeCount = 0;
  int _activeLowPriorityCount = 0;
  int _nextJobId = 0;

  int get activeCount => _activeCount;

  int get pendingCount => _normalJobs.length + _lowJobs.length;

  Future<T> run<T>(
    Future<T> Function() operation, {
    required SshExecPriority priority,
  }) {
    final job = _QueuedSshExecJob<T>(
      id: _nextJobId++,
      priority: priority,
      enqueuedAt: DateTime.now(),
      operation: operation,
    );
    switch (priority) {
      case SshExecPriority.normal:
        _normalJobs.add(job);
      case SshExecPriority.low:
        _lowJobs.add(job);
    }
    if (_activeCount >= _maxExecJobsPerConnection || pendingCount > 1) {
      DiagnosticsLogService.instance.debug(
        'ssh.exec_queue',
        'queued',
        fields: {
          'connectionId': connectionId,
          'jobId': job.id,
          'priority': priority.name,
          'activeCount': _activeCount,
          'pendingCount': pendingCount,
        },
      );
    }
    _drain();
    return job.future;
  }

  void _drain() {
    while (_activeCount < _maxExecJobsPerConnection) {
      final job = _takeNextJob();
      if (job == null) return;
      _start(job);
    }
  }

  _QueuedSshExecJob<dynamic>? _takeNextJob() {
    if (_normalJobs.isNotEmpty) {
      return _normalJobs.removeFirst();
    }
    if (_lowJobs.isEmpty ||
        _activeLowPriorityCount >= _maxLowPriorityExecJobsPerConnection) {
      return null;
    }
    return _lowJobs.removeFirst();
  }

  void _start(_QueuedSshExecJob<dynamic> job) {
    _activeCount += 1;
    if (job.priority == SshExecPriority.low) {
      _activeLowPriorityCount += 1;
    }
    final startedAt = DateTime.now();
    DiagnosticsLogService.instance.debug(
      'ssh.exec_queue',
      'start',
      fields: {
        'connectionId': connectionId,
        'jobId': job.id,
        'priority': job.priority.name,
        'queuedMs': startedAt.difference(job.enqueuedAt).inMilliseconds,
        'activeCount': _activeCount,
        'pendingCount': pendingCount,
      },
    );
    unawaited(
      Future.sync(job.operation)
          .then<void>(
            job.completer.complete,
            onError: job.completer.completeError,
          )
          .whenComplete(() {
            _activeCount -= 1;
            if (job.priority == SshExecPriority.low) {
              _activeLowPriorityCount -= 1;
            }
            DiagnosticsLogService.instance.debug(
              'ssh.exec_queue',
              'complete',
              fields: {
                'connectionId': connectionId,
                'jobId': job.id,
                'priority': job.priority.name,
                'durationMs': DateTime.now()
                    .difference(startedAt)
                    .inMilliseconds,
                'activeCount': _activeCount,
                'pendingCount': pendingCount,
              },
            );
            _drain();
            // Only evict this queue; a replacement registered for the same
            // connection must keep its own pending jobs.
            if (_activeCount == 0 &&
                pendingCount == 0 &&
                identical(_execQueues[connectionId], this)) {
              _execQueues.remove(connectionId);
            }
          }),
    );
  }
}

class _QueuedSshExecJob<T> {
  _QueuedSshExecJob({
    required this.id,
    required this.priority,
    required this.enqueuedAt,
    required this.operation,
  });

  final int id;
  final SshExecPriority priority;
  final DateTime enqueuedAt;
  final Future<T> Function() operation;
  final completer = Completer<T>();

  Future<T> get future => completer.future;
}
