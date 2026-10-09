import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/socks5_protocol.dart';

const _timeout = Duration(seconds: 5);

List<int> _greeting([List<int> methods = const [0x00]]) => [
  0x05,
  methods.length,
  ...methods,
];

List<int> _domainRequest(String host, int port, {int command = 0x01}) => [
  0x05,
  command,
  0x00,
  0x03,
  host.length,
  ...ascii.encode(host),
  port >> 8,
  port & 0xff,
];

class _Handshake {
  _Handshake({Future<void>? cancel, Duration timeout = _timeout}) {
    request = readSocks5ConnectRequest(
      input.stream,
      write: written.addAll,
      timeout: timeout,
      cancel: cancel,
    );
  }

  final input = StreamController<Uint8List>();
  final written = <int>[];
  late final Future<Socks5ConnectRequest> request;

  void send(List<int> bytes) => input.add(Uint8List.fromList(bytes));
}

Matcher _failsWith(Socks5HandshakeFailure failure) => throwsA(
  isA<Socks5HandshakeException>().having(
    (error) => error.failure,
    'failure',
    failure,
  ),
);

void main() {
  test('accepts a domain CONNECT and keeps the name for remote DNS', () async {
    final handshake = _Handshake()
      ..send(_greeting([0x02, 0x00]))
      ..send([..._domainRequest('grafana.internal', 3000), ...'GET'.codeUnits]);

    final request = await handshake.request;

    expect(handshake.written, [0x05, 0x00]);
    expect(request.host, 'grafana.internal');
    expect(request.port, 3000);
    expect(request.addressType, Socks5AddressType.domainName);

    final upload = <int>[];
    final done = Completer<void>();
    request.upload.listen(upload.addAll, onDone: done.complete);
    handshake.send(' /'.codeUnits);
    await handshake.input.close();
    await done.future;
    expect(utf8.decode(upload), 'GET /');
  });

  test('parses a request delivered one byte at a time', () async {
    final handshake = _Handshake();
    for (final byte in [..._greeting(), ..._domainRequest('db', 5432)]) {
      handshake.send([byte]);
      await Future<void>.delayed(Duration.zero);
    }

    final request = await handshake.request;
    expect(request.host, 'db');
    expect(request.port, 5432);
  });

  test('formats IPv4 and IPv6 destinations', () async {
    final ipv4 = _Handshake()
      ..send(_greeting())
      ..send([0x05, 0x01, 0x00, 0x01, 10, 0, 0, 5, 0x1f, 0x90]);
    final ipv4Request = await ipv4.request;
    expect(ipv4Request.host, '10.0.0.5');
    expect(ipv4Request.port, 8080);
    expect(ipv4Request.addressType, Socks5AddressType.ipv4);

    final ipv6 = _Handshake()
      ..send(_greeting())
      ..send([
        0x05,
        0x01,
        0x00,
        0x04,
        ...List<int>.filled(15, 0),
        1,
        0x00,
        0x50,
      ]);
    final ipv6Request = await ipv6.request;
    expect(ipv6Request.host, '::1');
    expect(ipv6Request.port, 80);
    expect(ipv6Request.addressType, Socks5AddressType.ipv6);
  });

  test('refuses clients that require authentication', () async {
    final handshake = _Handshake()..send(_greeting([0x02]));

    await expectLater(
      handshake.request,
      _failsWith(Socks5HandshakeFailure.noAcceptableAuthMethod),
    );
    expect(handshake.written, [0x05, 0xff]);
  });

  test('refuses BIND and UDP ASSOCIATE', () async {
    final handshake = _Handshake()
      ..send(_greeting())
      ..send(_domainRequest('example.com', 80, command: 0x02));

    await expectLater(
      handshake.request,
      _failsWith(Socks5HandshakeFailure.unsupportedCommand),
    );
    expect(handshake.written.skip(2).take(2), [
      0x05,
      Socks5Reply.commandNotSupported.code,
    ]);
  });

  test('refuses unknown address types', () async {
    final handshake = _Handshake()
      ..send(_greeting())
      ..send([0x05, 0x01, 0x00, 0x09, 0, 0]);

    await expectLater(
      handshake.request,
      _failsWith(Socks5HandshakeFailure.unsupportedAddressType),
    );
    expect(handshake.written[3], Socks5Reply.addressTypeNotSupported.code);
  });

  test('refuses empty names, control bytes and port zero', () async {
    for (final request in [
      _domainRequest('', 80),
      _domainRequest('bad host', 80),
      _domainRequest('example.com', 0),
    ]) {
      final handshake = _Handshake()
        ..send(_greeting())
        ..send(request);
      await expectLater(
        handshake.request,
        _failsWith(Socks5HandshakeFailure.invalidDestination),
      );
      expect(handshake.written[3], Socks5Reply.hostUnreachable.code);
    }
  });

  test('rejects other protocols without answering', () async {
    final handshake = _Handshake()..send(ascii.encode('GET / HTTP/1.1\r\n'));

    await expectLater(
      handshake.request,
      _failsWith(Socks5HandshakeFailure.unsupportedVersion),
    );
    expect(handshake.written, isEmpty);
  });

  test('reports an early close, a timeout and a cancellation', () async {
    final closed = _Handshake()..send(_greeting());
    await closed.input.close();
    await expectLater(
      closed.request,
      _failsWith(Socks5HandshakeFailure.closed),
    );

    final slow = _Handshake(timeout: const Duration(milliseconds: 20))
      ..send(_greeting());
    await expectLater(
      slow.request,
      _failsWith(Socks5HandshakeFailure.timedOut),
    );

    final stop = Completer<void>();
    final cancelled = _Handshake(cancel: stop.future)..send(_greeting());
    stop.complete();
    await expectLater(
      cancelled.request,
      _failsWith(Socks5HandshakeFailure.cancelled),
    );
  });

  test('pausing the upload pauses the client stream', () async {
    final handshake = _Handshake()
      ..send(_greeting())
      ..send(_domainRequest('example.com', 443));
    final request = await handshake.request;

    final subscription = request.upload.listen((_) {})..pause();
    await Future<void>.delayed(Duration.zero);
    expect(handshake.input.isPaused, isTrue);
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(handshake.input.isPaused, isFalse);
    await subscription.cancel();
  });

  test('discard stops reading an unused client stream', () async {
    final handshake = _Handshake()
      ..send(_greeting())
      ..send(_domainRequest('example.com', 443));
    final request = await handshake.request;

    await request.discard();
    expect(handshake.input.hasListener, isFalse);
  });

  test('encodes replies with an unspecified bound address', () {
    expect(encodeSocks5Reply(Socks5Reply.succeeded), [
      0x05,
      0x00,
      0x00,
      0x01,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    expect(encodeSocks5Reply(Socks5Reply.connectionRefused)[1], 0x05);
  });
}
