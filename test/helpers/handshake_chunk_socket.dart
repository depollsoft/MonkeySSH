import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

/// Captures a host key from fragmented SSH handshake chunks using the real
/// socket wrapper and parser path.
Future<Uint8List> captureHostKeyFromHandshakeChunks(
  Iterable<Uint8List> chunks,
) {
  final capturingSocket = HostKeyCapturingSshSocket(
    FiniteChunkSshSocket(chunks),
  );
  unawaited(capturingSocket.stream.drain<void>());
  return capturingSocket.hostKeyBytes;
}

/// A read-only transport that replays [chunks] and then ends.
class FiniteChunkSshSocket implements SSHSocket {
  FiniteChunkSshSocket(Iterable<Uint8List> chunks)
    : stream = Stream<Uint8List>.fromIterable(chunks);

  @override
  final Stream<Uint8List> stream;

  final _sinkController = StreamController<List<int>>();

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() => _sinkController.close();

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}
