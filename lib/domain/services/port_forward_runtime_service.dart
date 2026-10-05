import 'dart:async';

import '../../data/database/database.dart';
import 'serial_task_queue.dart';
import 'ssh_service.dart';

final _portForwardRuntimeOperations = KeyedTaskGate<int>();
final _deletedPortForwardCreatedAt = <int, DateTime>{};

/// Outcome of applying a saved port forward to a connected SSH session.
enum PortForwardActivationStatus {
  /// The forward started, or restarted with updated runtime settings.
  started,

  /// The forward was already active on a connected session.
  alreadyActive,

  /// No connected session was available for the forward's host.
  noConnectedSession,

  /// A connected session was available, but the forward could not start.
  failed,

  /// The saved rule was deleted before this queued activation could run.
  superseded,
}

/// Result of applying a saved port forward to a connected SSH session.
class PortForwardActivationResult {
  /// Creates an activation result.
  const PortForwardActivationResult({
    required this.status,
    this.connectionId,
    this.affectedConnectionCount = 0,
  });

  /// Activation outcome.
  final PortForwardActivationStatus status;

  /// Preferred or affected connection, when one was available.
  final int? connectionId;

  /// Number of connected sessions started or restarted.
  final int affectedConnectionCount;
}

/// Whether editing [previous] into [current] changes the live tunnel.
bool portForwardRuntimeConfigurationChanged(
  PortForward previous,
  PortForward current,
) =>
    previous.hostId != current.hostId ||
    previous.forwardType != current.forwardType ||
    previous.localHost != current.localHost ||
    previous.localPort != current.localPort ||
    previous.remoteHost != current.remoteHost ||
    previous.remotePort != current.remotePort;

/// Whether [portForward] is active on any connected session for its host.
bool isPortForwardActiveOnConnectedSession({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
}) => _connectedSessionsForHost(sessions, portForward.hostId).any(
  (session) =>
      session.isPortForwardActive(portForward.id) ||
      session.isPortForwardStarting(portForward.id),
);

/// Whether saving [portForward] should update a connected session immediately.
///
/// Auto-start rules always apply live when a connection is available. A
/// manually started rule also applies live so edited endpoints cannot diverge
/// from the running tunnel.
bool shouldApplyPortForwardLive({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
  PortForward? previous,
}) =>
    portForward.autoStart ||
    (previous != null &&
        isPortForwardActiveOnConnectedSession(
          sessions: sessions,
          portForward: previous,
        ));

/// Applies [portForward] to an existing connection without reconnecting.
///
/// An already-active rule is reused. If an edit changed its runtime
/// configuration, every connected session currently owning the rule is
/// restarted with the saved configuration. Otherwise the preferred connected
/// session for the host is used.
Future<PortForwardActivationResult> activatePortForwardOnConnectedSession({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
  PortForward? previous,
  int? preferredConnectionId,
}) {
  final deletedCreatedAt = _deletedPortForwardCreatedAt[portForward.id];
  if (deletedCreatedAt != null && deletedCreatedAt != portForward.createdAt) {
    _deletedPortForwardCreatedAt.remove(portForward.id);
  }
  return _portForwardRuntimeOperations.run(portForward.id, () {
    if (_deletedPortForwardCreatedAt[portForward.id] == portForward.createdAt) {
      return Future<PortForwardActivationResult>.value(
        const PortForwardActivationResult(
          status: PortForwardActivationStatus.superseded,
        ),
      );
    }
    return _activatePortForwardOnConnectedSession(
      sessions: sessions,
      portForward: portForward,
      previous: previous,
      preferredConnectionId: preferredConnectionId,
    );
  });
}

Future<PortForwardActivationResult> _activatePortForwardOnConnectedSession({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
  PortForward? previous,
  int? preferredConnectionId,
}) async {
  if (previous != null && previous.hostId != portForward.hostId) {
    await _stopPortForwardOnConnectedSessions(
      sessions: sessions,
      portForward: previous,
    );
  }

  final connectedSessions = _connectedSessionsForHost(
    sessions,
    portForward.hostId,
  );
  final activeOwners = connectedSessions
      .where(
        (session) =>
            session.isPortForwardActive(portForward.id) ||
            session.isPortForwardStarting(portForward.id),
      )
      .toList(growable: false);
  final requiresRestart =
      previous != null &&
      portForwardRuntimeConfigurationChanged(previous, portForward);

  if (activeOwners.isNotEmpty) {
    if (!requiresRestart) {
      return PortForwardActivationResult(
        status: PortForwardActivationStatus.alreadyActive,
        connectionId: activeOwners.first.connectionId,
      );
    }

    var restartedCount = 0;
    for (final session in activeOwners) {
      if (await session.replacePortForward(portForward)) {
        restartedCount++;
      }
    }
    return PortForwardActivationResult(
      status: restartedCount == activeOwners.length
          ? PortForwardActivationStatus.started
          : PortForwardActivationStatus.failed,
      connectionId: activeOwners.first.connectionId,
      affectedConnectionCount: restartedCount,
    );
  }

  SshSession? targetSession;
  if (preferredConnectionId != null) {
    targetSession = connectedSessions
        .where((session) => session.connectionId == preferredConnectionId)
        .firstOrNull;
  }
  targetSession ??= connectedSessions.firstOrNull;
  if (targetSession == null) {
    return const PortForwardActivationResult(
      status: PortForwardActivationStatus.noConnectedSession,
    );
  }

  final started = await targetSession.startPortForward(portForward);
  return PortForwardActivationResult(
    status: started
        ? PortForwardActivationStatus.started
        : PortForwardActivationStatus.failed,
    connectionId: targetSession.connectionId,
    affectedConnectionCount: started ? 1 : 0,
  );
}

/// Stops [portForward] on every connected session that currently owns it.
Future<int> stopPortForwardOnConnectedSessions({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
}) async {
  _deletedPortForwardCreatedAt[portForward.id] = portForward.createdAt;
  var completed = false;
  try {
    final stoppedCount = await _portForwardRuntimeOperations.run(
      portForward.id,
      () => _stopPortForwardOnConnectedSessions(
        sessions: sessions,
        portForward: portForward,
      ),
    );
    completed = true;
    return stoppedCount;
  } finally {
    if (!completed) {
      restorePortForwardAfterFailedDeletion(portForward);
    }
  }
}

/// Clears a deletion tombstone when the database deletion did not complete.
void restorePortForwardAfterFailedDeletion(PortForward portForward) {
  if (_deletedPortForwardCreatedAt[portForward.id] == portForward.createdAt) {
    _deletedPortForwardCreatedAt.remove(portForward.id);
  }
}

Future<int> _stopPortForwardOnConnectedSessions({
  required ActiveSessionsNotifier sessions,
  required PortForward portForward,
}) async {
  var stoppedCount = 0;
  for (final session in _connectedSessionsForHost(
    sessions,
    portForward.hostId,
  )) {
    final wasActiveOrStarting =
        session.isPortForwardActive(portForward.id) ||
        session.isPortForwardStarting(portForward.id);
    await session.stopForward(portForward.id);
    if (wasActiveOrStarting) {
      stoppedCount++;
    }
  }
  return stoppedCount;
}

List<SshSession> _connectedSessionsForHost(
  ActiveSessionsNotifier sessions,
  int hostId,
) {
  final connectedSessions = <SshSession>[];
  for (final connectionId in sessions.getConnectionsForHost(hostId).reversed) {
    if (sessions.getState(connectionId) != SshConnectionState.connected) {
      continue;
    }
    final session = sessions.getSession(connectionId);
    if (session != null && session.hostId == hostId) {
      connectedSessions.add(session);
    }
  }
  return connectedSessions;
}
