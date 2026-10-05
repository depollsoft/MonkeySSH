import 'package:flutter/foundation.dart';

/// Protocol version spoken by the persistent MonkeyMux ACP bridge.
const monkeyMuxAcpBridgeProtocolVersion = 1;

/// Maximum encoded size of one bridge or ACP NDJSON frame.
const monkeyMuxAcpBridgeMaxFrameBytes = 20 * 1024 * 1024;

/// Helper failure message for a locked Cursor Agent login keychain.
///
/// Mirrors `errCursorAgentKeychainLocked` in `remote/monkeymux/acp_bridge.go`;
/// the two must stay identical until the helper reports a structured code.
const monkeyMuxCursorKeychainLockedMessage =
    'Cursor Agent login keychain is locked';

/// State of the ACP provider process retained by MonkeyMux.
enum MonkeyMuxAcpProviderState {
  /// The provider is starting.
  starting,

  /// The provider is running.
  running,

  /// The provider exited.
  exited,

  /// The bridge was explicitly stopped.
  stopped,

  /// The provider emitted invalid ACP protocol data.
  protocolError,

  /// A newer helper returned an unrecognized state.
  unknown,
}

/// Safe, versioned metadata returned by the MonkeyMux ACP bridge.
@immutable
final class MonkeyMuxAcpBridgeMetadata {
  /// Creates bridge metadata.
  const MonkeyMuxAcpBridgeMetadata({
    required this.id,
    required this.provider,
    required this.commandHash,
    required this.state,
    required this.clientCount,
    required this.pendingRequestCount,
    required this.inFlightTurnCount,
    required this.lastActivity,
    required this.startedAt,
    required this.nextSequence,
    this.providerId,
    this.sessionId,
    this.cwd,
  });

  /// Opaque bridge identifier.
  final String id;

  /// Stable ACP provider identifier, when supplied by a current helper.
  final String? providerId;

  /// Remote ACP session identifier captured from setup traffic.
  final String? sessionId;

  /// Remote working directory retained for reconnecting the session.
  final String? cwd;

  /// Provider display label retained by the helper.
  final String provider;

  /// SHA-256 hash of the approved provider command.
  final String commandHash;

  /// Current provider process state.
  final MonkeyMuxAcpProviderState state;

  /// Number of attached bridge clients.
  final int clientCount;

  /// Number of pending provider-to-client requests.
  final int pendingRequestCount;

  /// Number of in-flight client-to-provider requests.
  final int inFlightTurnCount;

  /// Last safe bridge activity timestamp.
  final DateTime lastActivity;

  /// Provider start timestamp.
  final DateTime startedAt;

  /// Latest sequence allocated by the bridge.
  final int nextSequence;
}

/// Result of starting a persistent bridge.
@immutable
final class MonkeyMuxAcpBridgeStartResult {
  /// Creates a bridge start result.
  const MonkeyMuxAcpBridgeStartResult({required this.bridgeId, this.windowId});

  /// Opaque identifier allocated by MonkeyMux.
  final String bridgeId;

  /// Real MonkeyMux window that owns this bridge, when created in a workspace.
  final String? windowId;
}

/// Connection lifecycle exposed separately from raw ACP bytes.
enum MonkeyMuxAcpTransportStatus {
  /// Opening the first SSH bridge channel.
  connecting,

  /// Attached as the bridge's writer.
  connected,

  /// Waiting to retry a temporarily detached SSH channel.
  reconnecting,

  /// The provider exited.
  providerExited,

  /// The transport encountered a terminal failure.
  failed,

  /// The local transport was explicitly closed.
  closed,
}

/// Typed transport state that never contains ACP payloads or launch data.
@immutable
final class MonkeyMuxAcpTransportState {
  /// Creates a transport state update.
  const MonkeyMuxAcpTransportState({
    required this.status,
    required this.bridgeId,
    required this.lastDeliveredSequence,
    this.attempt = 0,
    this.providerState,
    this.exitCode,
    this.retainedFrom,
  });

  /// Current local connection status.
  final MonkeyMuxAcpTransportStatus status;

  /// Opaque bridge identifier.
  final String bridgeId;

  /// Latest bridge event sequence delivered and acknowledged by the transport.
  final int lastDeliveredSequence;

  /// Consecutive reconnect attempt, when reconnecting.
  final int attempt;

  /// Current remote provider state, when known.
  final MonkeyMuxAcpProviderState? providerState;

  /// Provider exit code, when supplied by the helper.
  final int? exitCode;

  /// Oldest retained sequence after replay overflow.
  final int? retainedFrom;
}

/// Stable categories for bridge service and transport failures.
enum MonkeyMuxAcpBridgeErrorKind {
  /// A bridge identifier was malformed.
  invalidBridgeId,

  /// Provider launch configuration was invalid or oversized.
  invalidLaunch,

  /// The helper could not be installed or launched.
  helperUnavailable,

  /// A helper command failed or returned no response.
  helperProcess,

  /// A bridge frame exceeded its limit.
  frameTooLarge,

  /// A frame was not valid UTF-8, NDJSON, or bridge protocol data.
  invalidFrame,

  /// The helper uses an incompatible bridge protocol version.
  unsupportedVersion,

  /// Safe bridge metadata was invalid or oversized.
  invalidMetadata,

  /// Another attached client owns provider input.
  nonWriter,

  /// Requested replay data is no longer retained.
  replayOverflow,

  /// Sequenced output contained an unexplained gap.
  sequenceGap,

  /// The provider is no longer accepting input.
  providerUnavailable,

  /// Cursor Agent cannot read credentials because the macOS keychain is locked.
  keychainLocked,

  /// The provider process exited.
  providerExited,

  /// The SSH channel detached or could not reconnect.
  sshChannel,

  /// The operation was attempted after local close.
  closed,
}

/// Typed bridge failure with a safe, payload-free message.
final class MonkeyMuxAcpBridgeException implements Exception {
  /// Creates a bridge failure.
  const MonkeyMuxAcpBridgeException(this.kind, this.message);

  /// Stable error category.
  final MonkeyMuxAcpBridgeErrorKind kind;

  /// Safe human-readable description.
  final String message;

  @override
  String toString() => 'MonkeyMux ACP bridge error: $message';
}
