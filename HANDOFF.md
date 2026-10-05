# HANDOFF: refactor/sa5-ssh2

## Merging with refactor/sa5-ssh1 (lib/domain/services/ssh_service.dart)

ssh1 replaces `_PortForwardOperationKind` with a `bool isStop` (its finding 9).
This branch replaces the hand-rolled port-forward gate with `KeyedTaskGate`.
Expect three textual conflicts in `SshSession`; resolve them as:

1. Field declarations: keep this branch's lines
   ```dart
   final _portForwardOperations = KeyedTaskGate<int>();
   final Set<int> _stoppingPortForwardIds = {};
   ```
2. `isPortForwardStarting`: keep this branch's body
   (`_portForwardOperations.isRunning(id) && !_stoppingPortForwardIds.contains(id) && !isPortForwardActive(id)`).
3. `_runPortForwardOperation`: keep ssh1's signature (`{bool isStop = false}`)
   with this branch's body, testing `!isStop` instead of
   `kind != _PortForwardOperationKind.stop`:
   ```dart
   Future<T> _runPortForwardOperation<T>(
     int portForwardId,
     Future<T> Function() operation, {
     bool isStop = false,
   }) => _portForwardOperations.run(portForwardId, () async {
     if (!isStop) {
       return operation();
     }
     _stoppingPortForwardIds.add(portForwardId);
     try {
       return await operation();
     } finally {
       _stoppingPortForwardIds.remove(portForwardId);
     }
   });
   ```

## ssh_service.dart edits outside the assigned regions

All are one-line or declaration edits required by the queue/gate swap:

- Imports: added `serial_task_queue.dart` and `ssh_wire.dart`.
- `SshSession` fields: `_portForwardOperations`, `_stoppingPortForwardIds`,
  `_automaticPortForwardSnapshotQueue`, `_automaticPortForwardConfiguration`
  now hold `KeyedTaskGate` / `SerialTaskQueue`.
- `isPortForwardStarting` reads the gate (see conflict 2 above).
- `_stopAutomaticPortForwarding` and `close()`: `_automaticPortForwardSnapshotQueue`
  became `_automaticPortForwardSnapshotQueue.pending`.
- `ActiveSessionsNotifier` fields: the two reconfiguration queue maps now map to
  `SerialTaskQueue`, and `_backgroundStatusSyncQueue` is a `SerialTaskQueue`.
