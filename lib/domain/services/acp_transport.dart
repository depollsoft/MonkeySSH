import '../models/acp_json.dart';

/// Bidirectional byte transport used by an ACP JSON-RPC connection.
abstract interface class AcpTransport {
  /// Bytes received from the remote ACP peer.
  Stream<List<int>> get incoming;

  /// Writes a complete sequence of bytes to the remote peer.
  Future<void> write(List<int> bytes);

  /// Closes the transport and releases all resources.
  Future<void> close();
}

/// Optional decoded input for transports that already parse a JSON envelope.
///
/// Consumers subscribe to this OR [AcpTransport.incoming], not both. This avoids
/// encoding and parsing large history payloads a second time on the UI isolate.
/// Input received before subscription must be retained for either view; choosing
/// one view must not strand earlier output in the other view.
abstract interface class AcpDecodedTransport implements AcpTransport {
  /// Ordered, deeply immutable JSON objects with their encoded frame size.
  Stream<AcpDecodedFrame> get incomingFrames;
}

/// A decoded ACP frame. The transport must provide a deeply immutable message.
final class AcpDecodedFrame {
  /// Creates a frame with its UTF-8 size, excluding the NDJSON newline.
  const AcpDecodedFrame({required this.message, required this.byteLength});

  /// Deeply immutable JSON object.
  final AcpJsonMap message;

  /// Encoded size used to enforce the connection's own frame limit.
  final int byteLength;
}
