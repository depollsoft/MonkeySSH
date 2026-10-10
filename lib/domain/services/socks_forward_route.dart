import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import 'port_forward_runtime_service.dart';
import 'ssh_service.dart';

/// Where a SOCKS forward is running: the owning connection and its loopback
/// listener port.
@immutable
class SocksForwardRoute {
  /// Creates a route.
  const SocksForwardRoute({required this.connectionId, required this.port});

  /// Connection whose SSH session relays the forward.
  final int connectionId;

  /// Loopback port of the SOCKS listener.
  final int port;

  @override
  bool operator ==(Object other) =>
      other is SocksForwardRoute &&
      other.connectionId == connectionId &&
      other.port == port;

  @override
  int get hashCode => Object.hash(connectionId, port);
}

/// Finds the connected session for [hostId] that runs [portForwardId] as a
/// SOCKS forward.
SocksForwardRoute? findSocksForwardRoute(
  ActiveSessionsNotifier sessions, {
  required int hostId,
  required int portForwardId,
}) {
  for (final connectionId in sessions.getConnectionsForHost(hostId).reversed) {
    if (sessions.getState(connectionId) != SshConnectionState.connected) {
      continue;
    }
    final session = sessions.getSession(connectionId);
    if (session == null || session.hostId != hostId) {
      continue;
    }
    for (final tunnel in session.activeTunnels) {
      if (tunnel.portForwardId == portForwardId &&
          tunnel.isDynamic &&
          tunnel.localPort > 0) {
        return SocksForwardRoute(
          connectionId: connectionId,
          port: tunnel.localPort,
        );
      }
    }
  }
  return null;
}

/// Result of starting a SOCKS forward for the in-app browser.
@immutable
class SocksForwardStartResult {
  const SocksForwardStartResult._({this.route, this.errorMessage});

  /// A result for a forward running at [route].
  @visibleForTesting
  const SocksForwardStartResult.running(SocksForwardRoute this.route)
    : errorMessage = null;

  /// A result for a forward that did not start, because of [errorMessage].
  @visibleForTesting
  const SocksForwardStartResult.failed(String this.errorMessage) : route = null;

  /// The running forward, when it started.
  final SocksForwardRoute? route;

  /// Why the forward is not running, when it did not start.
  final String? errorMessage;
}

/// Starts [portForward] so the browser can route through it.
///
/// Reuses a forward that is already running. Otherwise it starts on the
/// preferred or newest connected session for the host, connecting first when
/// [connectIfNeeded] is set and no session is connected.
Future<SocksForwardStartResult> startSocksForwardRoute(
  ActiveSessionsNotifier sessions,
  PortForward portForward, {
  int? preferredConnectionId,
  bool connectIfNeeded = true,
}) async {
  SocksForwardRoute? findRoute() => findSocksForwardRoute(
    sessions,
    hostId: portForward.hostId,
    portForwardId: portForward.id,
  );

  final existing = findRoute();
  if (existing != null) {
    return SocksForwardStartResult._(route: existing);
  }

  var preferred = preferredConnectionId;
  final hasConnectedSession = sessions
      .getConnectionsForHost(portForward.hostId)
      .any(
        (connectionId) =>
            sessions.getState(connectionId) == SshConnectionState.connected,
      );
  if (!hasConnectedSession) {
    if (!connectIfNeeded) {
      return const SocksForwardStartResult._(
        errorMessage: 'Connect to the host to start this forward.',
      );
    }
    final result = await sessions.connect(portForward.hostId);
    if (!result.success || result.connectionId == null) {
      return SocksForwardStartResult._(
        errorMessage:
            result.error ?? 'Could not connect to start the SOCKS forward.',
      );
    }
    preferred = result.connectionId;
  }

  final activation = await activatePortForwardOnConnectedSession(
    sessions: sessions,
    portForward: portForward,
    preferredConnectionId: preferred,
  );
  final route = findRoute();
  if (route != null) {
    return SocksForwardStartResult._(route: route);
  }
  return SocksForwardStartResult._(
    errorMessage: switch (activation.status) {
      PortForwardActivationStatus.noConnectedSession =>
        'Connect to the host to start this forward.',
      PortForwardActivationStatus.superseded => 'This forward was deleted.',
      PortForwardActivationStatus.started ||
      PortForwardActivationStatus.alreadyActive ||
      PortForwardActivationStatus.failed =>
        'Could not start "${portForward.name}". Check its local port.',
    },
  );
}

/// Live view of where one SOCKS forward runs, for the in-app browser.
abstract interface class SocksForwardRouteSource implements Listenable {
  /// The running forward, or null while it is stopped.
  SocksForwardRoute? get route;

  /// Re-reads the sessions; call when the set of connections changes.
  void refresh();

  /// Starts the forward, or restarts it when its listener stopped answering.
  ///
  /// The result is read from the sessions, not from [route], so it stays
  /// accurate after [dispose]: a browser closed mid-start still learns that
  /// the forward came up and can stop it.
  Future<SocksForwardStartResult> restart();

  /// Whether the listener still accepts connections.
  ///
  /// iOS can reclaim a suspended app's listening sockets, so the browser
  /// checks after the app resumes.
  Future<bool> probe();

  /// Stops the forward wherever it runs.
  ///
  /// The browser calls this on close for a forward it started, so the
  /// unauthenticated listener only runs while something uses it. Still works
  /// after [dispose].
  Future<void> stopForward();

  /// Stops listening to the sessions.
  void dispose();
}

/// [SocksForwardRouteSource] backed by the app's live SSH sessions.
class SessionSocksForwardRouteSource extends ChangeNotifier
    implements SocksForwardRouteSource {
  /// Creates a source for [portForward] over [sessions].
  SessionSocksForwardRouteSource({
    required ActiveSessionsNotifier sessions,
    required this.portForward,
    this.probeTimeout = const Duration(seconds: 1),
  }) : _sessions = sessions;

  /// The SOCKS forward this source tracks.
  final PortForward portForward;

  /// How long [probe] waits for the listener to accept.
  final Duration probeTimeout;

  final ActiveSessionsNotifier _sessions;
  final Map<int, StreamSubscription<void>> _subscriptions = {};
  SocksForwardRoute? _route;
  var _disposed = false;

  @override
  SocksForwardRoute? get route => _route;

  @override
  void refresh() {
    if (_disposed) {
      return;
    }
    final connectionIds = _sessions
        .getConnectionsForHost(portForward.hostId)
        .toSet();
    for (final connectionId in _subscriptions.keys.toList()) {
      if (!connectionIds.contains(connectionId)) {
        unawaited(_subscriptions.remove(connectionId)!.cancel());
      }
    }
    for (final connectionId in connectionIds) {
      if (_subscriptions.containsKey(connectionId)) {
        continue;
      }
      final session = _sessions.getSession(connectionId);
      if (session == null) {
        continue;
      }
      _subscriptions[connectionId] = session.portForwardChanges.listen(
        (_) => _recompute(),
      );
    }
    _recompute();
  }

  void _recompute() {
    if (_disposed) {
      return;
    }
    final next = _findRoute();
    if (next == _route) {
      return;
    }
    _route = next;
    notifyListeners();
  }

  @override
  Future<SocksForwardStartResult> restart() async {
    final current = _route;
    if (current != null) {
      final session = _sessions.getSession(current.connectionId);
      if (session != null && await session.replacePortForward(portForward)) {
        refresh();
        final replaced = _findRoute();
        if (replaced != null) {
          return SocksForwardStartResult._(route: replaced);
        }
      }
    }
    final result = await startSocksForwardRoute(_sessions, portForward);
    refresh();
    return result.route == null && result.errorMessage == null
        ? const SocksForwardStartResult._(
            errorMessage: 'Could not start the SOCKS forward.',
          )
        : result;
  }

  SocksForwardRoute? _findRoute() => findSocksForwardRoute(
    _sessions,
    hostId: portForward.hostId,
    portForwardId: portForward.id,
  );

  @override
  Future<bool> probe() async {
    final port = _route?.port;
    if (port == null) {
      return false;
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: probeTimeout,
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  @override
  Future<void> stopForward() async {
    for (final connectionId in _sessions.getConnectionsForHost(
      portForward.hostId,
    )) {
      final session = _sessions.getSession(connectionId);
      if (session != null && session.isPortForwardActive(portForward.id)) {
        await session.stopForward(portForward.id);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}

/// Creates the route source the SOCKS browser watches; overridable in tests.
final socksForwardRouteSourceFactoryProvider =
    Provider<SocksForwardRouteSource Function(PortForward portForward)>(
      (ref) =>
          (portForward) => SessionSocksForwardRouteSource(
            sessions: ref.read(activeSessionsProvider.notifier),
            portForward: portForward,
          ),
    );
