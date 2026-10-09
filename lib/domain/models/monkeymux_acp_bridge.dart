import 'package:flutter/foundation.dart';

/// Protocol version spoken by the persistent MonkeyMux ACP bridge.
const monkeyMuxAcpBridgeProtocolVersion = 1;

/// Maximum encoded size of one bridge or ACP NDJSON frame.
const monkeyMuxAcpBridgeMaxFrameBytes = 20 * 1024 * 1024;

/// Bridge hello capability: the bridge reports who holds the input lease and
/// accepts a request to take it over.
const monkeyMuxAcpWriterLeaseCapability = 'writer_lease';

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
    this.writer,
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

  /// Client holding the input lease, when a lease-aware helper reports one.
  final MonkeyMuxAcpLeaseHolder? writer;
}

/// The client holding a bridge's input lease, as listed by the helper.
@immutable
final class MonkeyMuxAcpLeaseHolder {
  /// Creates a lease holder description.
  const MonkeyMuxAcpLeaseHolder({
    required this.lastActiveAt,
    required this.stale,
    this.label,
  });

  /// Short device description that client supplied, if any.
  final String? label;

  /// Local time of the holder's last input.
  final DateTime lastActiveAt;

  /// Whether the holder has been silent long enough that the next attach
  /// takes the lease without asking.
  final bool stale;
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

  /// Another client holds the bridge's input lease, so this transport closed
  /// without sending anything. See [MonkeyMuxAcpTransportState.writer].
  heldElsewhere,
}

/// The client that holds a bridge's input lease, as seen by one that does not.
@immutable
final class MonkeyMuxAcpRemoteWriter {
  /// Creates a remote writer description.
  const MonkeyMuxAcpRemoteWriter({
    required this.lastActiveAt,
    required this.leaseLost,
    this.label,
  });

  /// Short device description that client supplied, such as `iPad`, or null
  /// when it gave none (an older MonkeySSH).
  final String? label;

  /// Local time of the writer's last input, derived from the bridge's idle
  /// count so it needs no clock agreement with the host.
  final DateTime lastActiveAt;

  /// Whether this client held the lease until the writer took it.
  final bool leaseLost;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MonkeyMuxAcpRemoteWriter &&
          label == other.label &&
          lastActiveAt == other.lastActiveAt &&
          leaseLost == other.leaseLost;

  @override
  int get hashCode => Object.hash(label, lastActiveAt, leaseLost);
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
    this.writer,
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

  /// Client holding the input lease, when [status] is
  /// [MonkeyMuxAcpTransportStatus.heldElsewhere].
  final MonkeyMuxAcpRemoteWriter? writer;
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
