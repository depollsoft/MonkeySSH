import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'acp_transport.dart';

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
    if (_closeFuture != null) throw StateError('ACP SSH transport is closed');
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
