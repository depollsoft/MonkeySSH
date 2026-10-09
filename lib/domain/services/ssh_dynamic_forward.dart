part of 'ssh_service.dart';

/// Most SOCKS clients one dynamic forward relays at once.
///
/// Each client holds an SSH channel. Chromium opens at most 32 sockets per
/// proxy, so the in-app browser stays under this; the cap bounds what any
/// other client on the device can open through the listener.
const dynamicPortForwardMaxConnections = 64;

/// How long a SOCKS client may take to send its greeting and CONNECT request.
const _dynamicForwardHandshakeTimeout = Duration(seconds: 10);

/// How long a failure reply may take to reach the client before the socket is
/// destroyed.
const _dynamicForwardFailureReplyGrace = Duration(seconds: 1);

/// SOCKS5 (`ssh -D`) forwarding for [SshSession].
///
/// Lives in a part file so it shares the session's tunnel bookkeeping without
/// growing the session class itself.
extension _SshSessionDynamicForward on SshSession {
  Future<bool> _startDynamicForward({
    required int portForwardId,
    required int localPort,
  }) async {
    if (_activeTunnels.containsKey(portForwardId)) {
      return true;
    }
    ServerSocket? serverSocket;
    try {
      // The listener has no authentication, so it only ever binds loopback,
      // whatever bind host a saved or imported rule carries.
      serverSocket = await _bindPortForwardServerSocketWithCancellation(
        host: InternetAddress.loopbackIPv4,
        port: localPort,
      );
      if (serverSocket == null) {
        return false;
      }
      if (_isClosing) {
        await serverSocket.close();
        return false;
      }
      final tunnel = _ActiveTunnel.dynamic(
        serverSocket: serverSocket,
        localHost: dynamicPortForwardBindHost,
        localPort: serverSocket.port,
      );
      _activeTunnels[portForwardId] = tunnel;
      tunnel.subscription = serverSocket.listen(
        (socket) => _acceptDynamicForwardConnection(socket, tunnel),
        onError: (Object error, StackTrace _) =>
            _logDynamicForwardEvent('dynamic_listener_error', error: error),
        onDone: () =>
            _handleDynamicForwardListenerClosed(portForwardId, tunnel),
      );
      _notifyPortForwardsChanged();
      return true;
    } on Exception catch (error) {
      final removedActiveTunnel = _activeTunnels.remove(portForwardId) != null;
      await serverSocket?.close();
      if (removedActiveTunnel) {
        _notifyPortForwardsChanged();
      }
      _logDynamicForwardEvent('dynamic_start_failed', error: error);
      return false;
    }
  }

  /// Retires a tunnel whose listener closed without a stop request.
  ///
  /// iOS can reclaim a suspended app's listening sockets. Removing the tunnel
  /// reports the drop to the UI, so the browser can show its error and offer
  /// a restart instead of a dead proxy that looks active.
  void _handleDynamicForwardListenerClosed(
    int portForwardId,
    _ActiveTunnel tunnel,
  ) {
    if (tunnel.stopped.isCompleted || _isClosing) {
      return;
    }
    _logDynamicForwardEvent('dynamic_listener_closed');
    unawaited(
      _runPortForwardOperation(portForwardId, () async {
        if (identical(_activeTunnels[portForwardId], tunnel)) {
          await _stopForward(portForwardId);
        }
      }, isStop: true),
    );
  }

  void _acceptDynamicForwardConnection(Socket socket, _ActiveTunnel tunnel) {
    if (tunnel.stopped.isCompleted) {
      socket.destroy();
      return;
    }
    if (tunnel.connections.length >= dynamicPortForwardMaxConnections) {
      socket.destroy();
      if (!tunnel.connectionLimitLogged) {
        tunnel.connectionLimitLogged = true;
        DiagnosticsLogService.instance.warning(
          'ssh.forward',
          'dynamic_connection_limit',
          fields: {
            'connectionId': connectionId,
            'hostId': hostId,
            'limit': dynamicPortForwardMaxConnections,
          },
        );
      }
      return;
    }
    final connection = _handleDynamicForwardConnection(socket, tunnel);
    tunnel.connections.add(connection);
    unawaited(
      connection.whenComplete(() => tunnel.connections.remove(connection)),
    );
  }

  Future<void> _handleDynamicForwardConnection(
    Socket socket,
    _ActiveTunnel tunnel,
  ) async {
    final Socks5ConnectRequest request;
    try {
      request = await readSocks5ConnectRequest(
        socket,
        write: socket.add,
        timeout: _dynamicForwardHandshakeTimeout,
        cancel: tunnel.stopped.future,
      );
    } on Socks5HandshakeException catch (error) {
      switch (error.failure) {
        case Socks5HandshakeFailure.closed:
        case Socks5HandshakeFailure.cancelled:
        case Socks5HandshakeFailure.timedOut:
          socket.destroy();
        case Socks5HandshakeFailure.unsupportedVersion:
        case Socks5HandshakeFailure.noAcceptableAuthMethod:
        case Socks5HandshakeFailure.unsupportedCommand:
        case Socks5HandshakeFailure.unsupportedAddressType:
        case Socks5HandshakeFailure.invalidDestination:
          DiagnosticsLogService.instance.debug(
            'ssh.forward',
            'dynamic_handshake_failed',
            fields: {
              'connectionId': connectionId,
              'hostId': hostId,
              'failure': error.failure.name,
            },
          );
          // The handshake already queued its failure reply.
          await _closeAfterFailureReply(socket);
      }
      return;
    } on Object catch (error) {
      if (error is! Exception && error is! SSHError) rethrow;
      socket.destroy();
      return;
    }

    if (_isClosing || tunnel.stopped.isCompleted) {
      await request.discard();
      socket.destroy();
      return;
    }

    // The destination goes to the SSH server as given. A host name is never
    // looked up on this device, so DNS for routed pages stays on the host.
    final opening = Future<SSHForwardChannel>.sync(
      () => client.forwardLocal(request.host, request.port),
    );
    final SSHForwardChannel? channel;
    try {
      channel = await Future.any<SSHForwardChannel?>([
        opening,
        tunnel.stopped.future.then((_) => null),
        _closeStarted.future.then((_) => null),
      ]).timeout(portForwardStartTimeout);
    } on Object catch (error) {
      if (error is! Exception && error is! SSHError) rethrow;
      _destroyLateDynamicForwardChannel(opening);
      await request.discard();
      _logDynamicForwardFailure(error);
      if (_tryAddToSocket(
        socket,
        encodeSocks5Reply(_socks5ReplyForDialError(error)),
      )) {
        await _closeAfterFailureReply(socket);
      } else {
        socket.destroy();
      }
      return;
    }
    if (channel == null ||
        _isClosing ||
        tunnel.stopped.isCompleted ||
        !_tryAddToSocket(socket, encodeSocks5Reply(Socks5Reply.succeeded))) {
      if (channel == null) {
        _destroyLateDynamicForwardChannel(opening);
      } else {
        _destroyLocalForwardChannel(channel);
      }
      await request.discard();
      socket.destroy();
      return;
    }

    try {
      await relayPortForward(
        socket,
        () => channel,
        clientData: request.upload,
        stopped: tunnel.stopped.future,
        destroyChannel: _destroyLocalForwardChannel,
      );
    } on Object catch (error) {
      if (error is! SSHError &&
          error is! Exception &&
          !_isClosedForwardSinkError(error)) {
        rethrow;
      }
      _logDynamicForwardFailure(error);
    }
  }

  /// Adds [bytes] to [socket], returning false when the client already left.
  bool _tryAddToSocket(Socket socket, List<int> bytes) {
    try {
      socket.add(bytes);
      return true;
    } on Object catch (error) {
      if (error is! Exception && error is! StateError) rethrow;
      return false;
    }
  }

  /// Lets a queued failure reply reach the client, then drops the connection.
  Future<void> _closeAfterFailureReply(Socket socket) async {
    try {
      await socket.close().timeout(_dynamicForwardFailureReplyGrace);
    } on Object catch (error) {
      if (error is! Exception && !_isClosedForwardSinkError(error)) rethrow;
    } finally {
      socket.destroy();
    }
  }

  void _destroyLateDynamicForwardChannel(Future<SSHForwardChannel> opening) {
    unawaited(
      opening.then<void>(
        _destroyLocalForwardChannel,
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  void _logDynamicForwardFailure(Object error) {
    _logDynamicForwardEvent('dynamic_connection_failed', error: error);
    _reportConnectionHealthFailureIfClosed(error, operation: 'forward_dynamic');
  }

  void _logDynamicForwardEvent(String event, {Object? error}) {
    DiagnosticsLogService.instance.warning(
      'ssh.forward',
      event,
      fields: {
        'connectionId': connectionId,
        'hostId': hostId,
        if (error != null) ..._diagnosticSshExecErrorFields(error),
      },
    );
  }
}

/// Maps a failed SSH channel open to the closest SOCKS5 reply, so the browser
/// can tell a refused port from an unknown host.
Socks5Reply _socks5ReplyForDialError(Object error) => switch (error) {
  SSHChannelOpenError(code: 1) => Socks5Reply.connectionNotAllowed,
  SSHChannelOpenError(:final description)
      when description.toLowerCase().contains('refused') =>
    Socks5Reply.connectionRefused,
  SSHChannelOpenError() => Socks5Reply.hostUnreachable,
  TimeoutException() => Socks5Reply.ttlExpired,
  _ => Socks5Reply.generalFailure,
};
