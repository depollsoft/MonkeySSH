import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

// Run with scripts/test_port_forward_ssh.sh on a machine with localhost SSH.
// The target HTTP server also runs locally, so SSH must connect to this machine.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final keyPath = Platform.environment['MONKEYSSH_FORWARD_E2E_KEY'];
  test(
    'browser traffic preserves shared SSH connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      // Exceed the SSH receive window so downloads exercise window adjustments.
      final body = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
      server.listen((request) async {
        await request.drain<void>();
        request.response.contentLength = body.length;
        request.response.add(body);
        try {
          await request.response.close();
        } on SocketException {
          // The cancellation probe deliberately drops an unfinished response.
        }
      });
      final client = SSHClient(
        await SSHSocket.connect('127.0.0.1', 22),
        username: Platform.environment['USER']!,
        identities: SSHKeyPair.fromPem(await File(keyPath!).readAsString()),
      );
      addTearDown(client.close);
      final transportErrors = <Object>[];
      unawaited(client.done.then<void>((_) {}, onError: transportErrors.add));
      await client.authenticated;
      final shell = await client.execute('cat');
      final lines = StreamIterator(
        utf8.decoder.bind(shell.stdout).transform(const LineSplitter()),
      );
      addTearDown(() async {
        shell.close();
        await lines.cancel();
      });
      Future<void> checkShell() async {
        shell.stdin.add(utf8.encode('still connected\n'));
        expect(await lines.moveNext(), isTrue);
        expect(lines.current, 'still connected');
      }

      final session = SshSession(
        connectionId: 1,
        hostId: 42,
        client: client,
        config: SshConnectionConfig(
          hostname: '127.0.0.1',
          port: 22,
          username: Platform.environment['USER']!,
        ),
      );
      addTearDown(session.stopAllForwards);
      expect(
        await session.startLocalForward(
          portForwardId: 1,
          localHost: '127.0.0.1',
          localPort: 0,
          remoteHost: '127.0.0.1',
          remotePort: server.port,
        ),
        isTrue,
      );
      final http = _RealHttpOverrides().createHttpClient(null);
      addTearDown(() => http.close(force: true));
      final tunnel = session.activeTunnels.single;
      expect(tunnel.browserPort, isNotNull);
      // Exercise the primary listener and the browser's IPv6 relay without
      // depending on *.localhost DNS. macOS may not bind additional 127/8
      // addresses without a loopback alias, so only use an available fallback.
      for (final host in ['127.0.0.1', '::1', ?tunnel.browserFallbackHost]) {
        final uri = Uri(scheme: 'http', host: host, port: tunnel.localPort);
        await Future.wait([
          ...List.generate(6, (index) async {
            final request = await http.getUrl(uri);
            request.persistentConnection = index.isEven;
            final response = await request.close();
            expect(response.statusCode, HttpStatus.ok);
            final bytes = await response.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            expect(bytes.length, body.length);
            expect(listEquals(bytes, body), isTrue);
          }),
          checkShell(),
        ]);
        await checkShell();
      }

      // Navigating away mid-load must only close that forwarding channel.
      final cancelled = await Socket.connect('127.0.0.1', tunnel.localPort);
      addTearDown(cancelled.destroy);
      cancelled.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');
      await cancelled.first;
      cancelled.destroy();
      await checkShell();
      http.close(force: true);
      await session.stopAllForwards();
      await checkShell();
      expect(utf8.decode(await client.run('printf alive')), 'alive');
      expect(transportErrors, isEmpty);
      expect(client.isClosed, isFalse);
    },
    skip: keyPath == null
        ? 'Set MONKEYSSH_FORWARD_E2E_KEY for localhost SSH'
        : false,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'SOCKS forward reaches host-only services by name',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          // Closed when the server is force-closed in tear-down.
          // ignore: close_sinks
          final webSocket = await WebSocketTransformer.upgrade(request);
          webSocket.listen((message) => webSocket.add('echo:$message'));
          return;
        }
        request.response.write('host-only');
        await request.response.close();
      });
      // Nothing listens here, so OpenSSH refuses the channel.
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = closed.port;
      await closed.close();

      final client = SSHClient(
        await SSHSocket.connect('127.0.0.1', 22),
        username: Platform.environment['USER']!,
        identities: SSHKeyPair.fromPem(await File(keyPath!).readAsString()),
      );
      addTearDown(client.close);
      await client.authenticated;
      final session = SshSession(
        connectionId: 2,
        hostId: 42,
        client: client,
        config: SshConnectionConfig(
          hostname: '127.0.0.1',
          port: 22,
          username: Platform.environment['USER']!,
        ),
      );
      addTearDown(session.stopAllForwards);
      expect(
        await session.startDynamicForward(portForwardId: 9, localPort: 0),
        isTrue,
      );
      final proxyPort = session.activeTunnels.single.localPort;

      Future<(Socket, StreamIterator<Uint8List>, int)> socks(int port) async {
        // Each caller destroys the returned socket in tear-down.
        // ignore: close_sinks
        final socket = await Socket.connect('127.0.0.1', proxyPort);
        final reader = StreamIterator(socket);
        final pending = <int>[];
        Future<List<int>> read(int count) async {
          while (pending.length < count) {
            expect(await reader.moveNext(), isTrue);
            pending.addAll(reader.current);
          }
          final bytes = pending.sublist(0, count);
          pending.removeRange(0, count);
          return bytes;
        }

        socket.add([0x05, 0x01, 0x00]);
        expect(await read(2), [0x05, 0x00]);
        // 'localhost' is resolved by sshd, not by the client.
        socket.add([
          0x05, 0x01, 0x00, 0x03, 9, //
          ...ascii.encode('localhost'),
          port >> 8, port & 0xff,
        ]);
        final reply = await read(10);
        expect(pending, isEmpty);
        return (socket, reader, reply[1]);
      }

      final (page, pageReader, pageReply) = await socks(server.port);
      addTearDown(page.destroy);
      expect(pageReply, 0x00);
      page.write(
        'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
      );
      final body = StringBuffer();
      while (await pageReader.moveNext()) {
        body.write(latin1.decode(pageReader.current));
      }
      expect(body.toString(), contains('host-only'));

      final (ws, wsReader, wsReply) = await socks(server.port);
      addTearDown(ws.destroy);
      expect(wsReply, 0x00);
      ws.write(
        'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: ${base64Encode(List<int>.generate(16, (i) => i * 11 + 3))}\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n',
      );
      final received = <int>[];
      while (!latin1.decode(received).contains('\r\n\r\n')) {
        expect(await wsReader.moveNext(), isTrue);
        received.addAll(wsReader.current);
      }
      expect(latin1.decode(received), startsWith('HTTP/1.1 101'));
      final payload = utf8.encode('ping');
      ws.add([
        0x81, 0x80 | payload.length, 1, 2, 3, 4, //
        for (var i = 0; i < payload.length; i++) payload[i] ^ (i % 4 + 1),
      ]);
      final frame = received.sublist(
        latin1.decode(received).indexOf('\r\n\r\n') + 4,
      );
      while (frame.length < 2 || frame.length < 2 + frame[1]) {
        expect(await wsReader.moveNext(), isTrue);
        frame.addAll(wsReader.current);
      }
      expect(utf8.decode(frame.sublist(2, 2 + frame[1])), 'echo:ping');

      final (refused, refusedReader, refusedReply) = await socks(closedPort);
      addTearDown(refused.destroy);
      expect(refusedReply, 0x05);
      await refusedReader.cancel();
      expect(utf8.decode(await client.run('printf alive')), 'alive');
    },
    skip: keyPath == null
        ? 'Set MONKEYSSH_FORWARD_E2E_KEY for localhost SSH'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
