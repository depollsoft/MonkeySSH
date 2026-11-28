import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/acp_protocol.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_transport.dart';
import 'ssh_exec_queue.dart';

/// ACP byte transport backed by a non-PTY SSH exec channel.
///
/// Stderr is drained without logging because it can contain private provider
/// output. This adapter is intentionally short-lived; reconnectable MonkeyMux
/// bridge transport is implemented by the integration branch.
final class AcpSshExecTransport implements AcpTransport {
  /// Wraps an established SSH exec channel.
  AcpSshExecTransport(SSHSession session) : _session = session {
    _stderrSubscription = session.stderr.listen((_) {}, onError: _ignoreError);
  }

  final SSHSession _session;
  late final StreamSubscription<Uint8List> _stderrSubscription;
  Future<void>? _closeFuture;

  @override
  Stream<List<int>> get incoming => _session.stdout.cast<List<int>>();

  @override
  Future<void> write(List<int> bytes) async {
    if (_closeFuture != null) {
      throw const AcpTransportClosedException('ACP SSH transport is closed');
    }
    _session.write(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() => _closeFuture ??= Future<void>.microtask(_close);

  Future<void> _close() async {
    try {
      await _stderrSubscription.cancel();
    } finally {
      _session.close();
    }
  }
}

void _ignoreError(Object _, StackTrace _) {}

/// Outcome of a one-shot ACP `session/list` query over an SSH exec channel.
typedef AcpExecSessionListResult = ({
  bool supported,
  List<AcpSessionInfo> sessions,
  bool hadError,
});

/// Starts an ACP agent on [exec], performs `initialize`, and paginates
/// `session/list` across [workingDirectories] until [max] sessions are
/// collected or pagination completes.
Future<AcpExecSessionListResult> listRemoteAcpSessionsOverExec(
  SSHSession exec, {
  required Duration timeout,
  required int max,
  List<String?> workingDirectories = const <String?>[null],
  int? maxPagesPerDirectory,
  bool continueOnListError = false,
  bool destroyAbandonedExec = false,
  Object Function()? requestIdFactory,
}) async {
  final client = AcpClient(
    AcpJsonRpcConnection(
      transport: AcpSshExecTransport(exec),
      defaultRequestTimeout: timeout,
      requestIdFactory: requestIdFactory,
    ),
  );
  try {
    final initialization = await client.initialize(
      capabilities: const AcpClientCapabilities(
        fileSystem: AcpFileSystemCapabilities(),
        booleanConfigOptions: false,
      ),
      timeout: timeout,
    );
    if (!initialization.agentCapabilities.session.list) {
      return (
        supported: false,
        sessions: const <AcpSessionInfo>[],
        hadError: false,
      );
    }

    final sessionsById = <String, AcpSessionInfo>{};
    var hadError = false;
    for (final cwd in workingDirectories) {
      String? cursor;
      final seenCursors = <String>{};
      var page = 0;
      do {
        if (maxPagesPerDirectory != null && page >= maxPagesPerDirectory) {
          break;
        }
        page++;
        late final AcpSessionListResult result;
        try {
          result = await client.listSessions(
            cwd: cwd,
            cursor: cursor,
            timeout: timeout,
          );
        } on AcpProtocolException {
          if (!continueOnListError) rethrow;
          hadError = true;
          break;
        } on AcpRemoteException {
          if (!continueOnListError) rethrow;
          hadError = true;
          break;
        }
        for (final info in result.sessions) {
          sessionsById.putIfAbsent(info.sessionId, () => info);
        }
        cursor = result.nextCursor;
        if (cursor != null && !seenCursors.add(cursor)) {
          if (continueOnListError) hadError = true;
          break;
        }
      } while (cursor != null && sessionsById.length < max);
    }

    return (
      supported: true,
      sessions: sessionsById.values.toList(growable: false),
      hadError: hadError,
    );
  } finally {
    try {
      await client.close();
    } finally {
      if (destroyAbandonedExec) {
        // Closing the client only sends EOF; an agent that ignores it would
        // keep the channel and its process. Destroy it after a short grace.
        await closeAbandonedSshExec(exec);
      }
    }
  }
}
