import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/socks5_protocol.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

const _timeout = Duration(seconds: 5);

class _MockSshClient extends Mock implements SSHClient {}

/// SSH channel stand-in that relays to a real socket on this machine.
class _SocketForwardChannel implements SSHForwardChannel {
  _SocketForwardChannel(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

/// Reads a socket as a byte stream with blocking helpers.
class _Peer {
  _Peer(this.socket) {
    _subscription = socket.listen(
      (data) {
        _buffer.addAll(data);
        _notify();
      },
      onDone: () {
        _closed = true;
        _notify();
      },
      onError: (Object _) {
        _closed = true;
        _notify();
      },
    );
  }

  static Future<_Peer> connect(int port) async =>
      _Peer(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = <int>[];
  var _closed = false;
  Completer<void>? _signal;

  bool get isClosed => _closed;

  void _notify() {
    final signal = _signal;
    _signal = null;
    signal?.complete();
  }

  Future<void> _wait() =>
      (_signal ??= Completer<void>()).future.timeout(_timeout);

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_closed) {
        throw StateError('closed after ${_buffer.length} bytes');
      }
      await _wait();
    }
    final bytes = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return bytes;
  }

  Future<String> readHeaders() async {
    while (true) {
      final text = latin1.decode(_buffer);
      final end = text.indexOf('\r\n\r\n');
      if (end >= 0) {
        _buffer.removeRange(0, end + 4);
        return text.substring(0, end);
      }
      if (_closed) {
        throw StateError('closed before headers');
      }
      await _wait();
    }
  }

  Future<String> readToEnd() async {
    while (!_closed) {
      await _wait();
    }
    final text = utf8.decode(_buffer);
    _buffer.clear();
    return text;
  }

  Future<void> untilClosed() async {
    while (!_closed) {
      await _wait();
    }
  }

  /// Runs the SOCKS5 handshake and returns the server's reply code.
  Future<int> socksConnect(String host, int port) async {
    socket.add([0x05, 0x01, 0x00]);
    expect(await read(2), [0x05, 0x00]);
    socket.add([
      0x05,
      0x01,
      0x00,
      0x03,
      host.length,
      ...ascii.encode(host),
      port >> 8,
      port & 0xff,
    ]);
    final reply = await read(10);
    expect(reply.first, 0x05);
    return reply[1];
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    socket.destroy();
  }
}

class _BindRecordingSession extends SshSession {
  _BindRecordingSession({required super.client})
    : super(
        connectionId: 1,
        hostId: 42,
        config: const SshConnectionConfig(
          hostname: 'host.example.com',
          port: 22,
          username: 'tester',
        ),
      );

  final boundHosts = <Object>[];
  ServerSocket? Function()? serverSocketOverride;

  @override
  Future<ServerSocket> bindPortForwardServerSocket(
    Object host,
    int port, {
    bool v6Only = false,
  }) {
    boundHosts.add(host);
    final override = serverSocketOverride?.call();
    if (override != null) {
      return Future.value(override);
    }
    return super.bindPortForwardServerSocket(host, port, v6Only: v6Only);
  }
}

/// A listener whose accept stream the test can end, like iOS reclaiming it.
class _ClosableServerSocket extends Stream<Socket> implements ServerSocket {
  // Closed by the test to end the accept stream.
  // ignore: close_sinks
  final connections = StreamController<Socket>();

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  int get port => 41080;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => connections.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<ServerSocket> close() async => this;
}

PortForward _socksForward({String localHost = '127.0.0.1'}) => PortForward(
  id: 7,
  name: 'Office',
  hostId: 42,
  forwardType: 'dynamic',
  localHost: localHost,
  localPort: 0,
  remoteHost: '',
  remotePort: 0,
  autoStart: false,
  createdAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockSshClient client;
  late _BindRecordingSession session;

  setUp(() {
    client = _MockSshClient();
    session = _BindRecordingSession(client: client);
    addTearDown(session.stopAllForwards);
  });

  Future<int> startSocks({String localHost = '127.0.0.1'}) async {
    expect(
      await session.startPortForward(_socksForward(localHost: localHost)),
      isTrue,
    );
    return session.activeTunnels.single.localPort;
  }

  /// Answers every dial by connecting to [port] on this machine, so a name
  /// that only the "host" knows still reaches the test server.
  List<(String, int)> dialEverythingTo(int port) {
    final dials = <(String, int)>[];
    when(() => client.forwardLocal(any(), any()))
        .thenAnswer((invocation) async {
          dials.add((
            invocation.positionalArguments[0] as String,
            invocation.positionalArguments[1] as int,
          ));
          return _SocketForwardChannel(
            await Socket.connect(InternetAddress.loopbackIPv4, port),
          );
        });
    return dials;
  }

  test('reports a loopback SOCKS tunnel with no fixed destination', () async {
    final port = await startSocks(localHost: '0.0.0.0');

    final tunnel = session.activeTunnels.single;
    expect(port, greaterThan(0));
    expect(tunnel.isDynamic, isTrue);
    expect(tunnel.isLocal, isTrue);
    expect(tunnel.localHost, '127.0.0.1');
    expect(tunnel.remoteHost, isEmpty);
    expect(tunnel.remotePort, 0);
    expect(tunnel.browserHost, isNull);
    // Even an imported rule that names a wildcard address binds loopback.
    expect(session.boundHosts, [InternetAddress.loopbackIPv4]);
  });

  test(
    'relays HTTP and redirects, leaving name resolution to the host',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/old') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://next.internal/new',
            );
        } else {
          request.response.write('routed:${request.headers.host}');
        }
        await request.response.close();
      });
      final dials = dialEverythingTo(server.port);
      final proxyPort = await startSocks();

      final first = await _Peer.connect(proxyPort);
      addTearDown(first.dispose);
      expect(await first.socksConnect('app.internal', 80), 0x00);
      first.socket.write(
        'GET /old HTTP/1.1\r\nHost: app.internal\r\nConnection: close\r\n\r\n',
      );
      final redirect = await first.readToEnd();
      expect(redirect, startsWith('HTTP/1.1 302'));
      expect(
        redirect.toLowerCase(),
        contains('location: http://next.internal/new'),
      );

      final second = await _Peer.connect(proxyPort);
      addTearDown(second.dispose);
      expect(await second.socksConnect('next.internal', 80), 0x00);
      second.socket.write(
        'GET /new HTTP/1.1\r\nHost: next.internal\r\nConnection: close\r\n\r\n',
      );
      final page = await second.readToEnd();
      expect(page, startsWith('HTTP/1.1 200'));
      expect(page, contains('routed:next.internal'));

      expect(dials, [('app.internal', 80), ('next.internal', 80)]);
    },
  );

  test('relays a WebSocket in both directions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      // Closed when the server is force-closed in tear-down.
      // ignore: close_sinks
      final webSocket = await WebSocketTransformer.upgrade(request);
      webSocket.listen((message) => webSocket.add('echo:$message'));
    });
    dialEverythingTo(server.port);
    final proxyPort = await startSocks();

    final peer = await _Peer.connect(proxyPort);
    addTearDown(peer.dispose);
    expect(await peer.socksConnect('ws.internal', 8080), 0x00);
    peer.socket.write(
      'GET /live HTTP/1.1\r\n'
      'Host: ws.internal:8080\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: ${base64Encode(List<int>.generate(16, (i) => i * 11 + 3))}\r\n'
      'Sec-WebSocket-Version: 13\r\n\r\n',
    );
    expect(await peer.readHeaders(), startsWith('HTTP/1.1 101'));

    for (final message in ['ping', 'pong', 'still here']) {
      final payload = utf8.encode(message);
      const mask = [0x12, 0x34, 0x56, 0x78];
      peer.socket.add([
        0x81,
        0x80 | payload.length,
        ...mask,
        for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4],
      ]);
      final header = await peer.read(2);
      expect(header[0], 0x81);
      final echoed = await peer.read(header[1]);
      expect(utf8.decode(echoed), 'echo:$message');
    }
  });

  test('maps refused and prohibited destinations to SOCKS replies', () async {
    final proxyPort = await startSocks();
    for (final (error, reply) in [
      (
        SSHChannelOpenError(2, 'Connection refused'),
        Socks5Reply.connectionRefused,
      ),
      (
        SSHChannelOpenError(1, 'administratively prohibited'),
        Socks5Reply.connectionNotAllowed,
      ),
      (
        SSHChannelOpenError(2, 'connect failed: Name or service not known'),
        Socks5Reply.hostUnreachable,
      ),
    ]) {
      when(() => client.forwardLocal(any(), any())).thenThrow(error);
      final peer = await _Peer.connect(proxyPort);
      addTearDown(peer.dispose);
      expect(await peer.socksConnect('db.internal', 5432), reply.code);
      await peer.untilClosed();
    }
    expect(session.activeTunnels, hasLength(1));
  });

  test('caps simultaneous SOCKS clients', () async {
    final proxyPort = await startSocks();
    final waiting = <_Peer>[];
    for (var i = 0; i < dynamicPortForwardMaxConnections; i++) {
      final peer = await _Peer.connect(proxyPort);
      waiting.add(peer);
      addTearDown(peer.dispose);
    }
    // Let the listener accept every pending client before the next one.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final overflow = await _Peer.connect(proxyPort);
    addTearDown(overflow.dispose);
    await overflow.untilClosed();
    expect(waiting.where((peer) => peer.isClosed), isEmpty);

    await session.stopForward(7);
    for (final peer in waiting) {
      await peer.untilClosed();
    }
  });

  test('stopping the forward ends pending handshakes promptly', () async {
    final proxyPort = await startSocks();
    final peer = await _Peer.connect(proxyPort);
    addTearDown(peer.dispose);
    peer.socket.add([0x05, 0x01, 0x00]);
    expect(await peer.read(2), [0x05, 0x00]);

    final stopwatch = Stopwatch()..start();
    await session.stopForward(7);
    await peer.untilClosed();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(session.activeTunnels, isEmpty);
    verifyNever(() => client.forwardLocal(any(), any()));
  });

  test('retires the tunnel when its listener closes unexpectedly', () async {
    final listener = _ClosableServerSocket();
    session.serverSocketOverride = () => listener;
    await startSocks();
    final changes = <void>[];
    final subscription = session.portForwardChanges.listen(changes.add);
    addTearDown(subscription.cancel);

    await listener.connections.close();
    await pumpEventQueue();

    expect(session.activeTunnels, isEmpty);
    expect(changes, isNotEmpty);
  });
}
