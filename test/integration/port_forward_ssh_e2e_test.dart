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
}
