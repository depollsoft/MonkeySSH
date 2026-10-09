import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// SOCKS protocol version 5 (RFC 1928).
const socks5Version = 0x05;

const _noAuthenticationMethod = 0x00;
const _noAcceptableMethods = 0xff;
const _connectCommand = 0x01;
const _ipv4AddressType = 0x01;
const _domainNameAddressType = 0x03;
const _ipv6AddressType = 0x04;

/// Reply codes a SOCKS5 server sends for a request (RFC 1928, section 6).
enum Socks5Reply {
  /// The connection to the destination is open.
  succeeded(0x00),

  /// The server failed for a reason no other code covers.
  generalFailure(0x01),

  /// Policy forbids the connection.
  connectionNotAllowed(0x02),

  /// The destination network is unreachable.
  networkUnreachable(0x03),

  /// The destination host is unreachable or its name did not resolve.
  hostUnreachable(0x04),

  /// The destination refused the connection.
  connectionRefused(0x05),

  /// The destination did not answer in time.
  ttlExpired(0x06),

  /// The request used a command other than CONNECT.
  commandNotSupported(0x07),

  /// The request used an unknown address type.
  addressTypeNotSupported(0x08);

  const Socks5Reply(this.code);

  /// Wire value of this reply.
  final int code;
}

/// Address form a SOCKS5 client used for its CONNECT destination.
enum Socks5AddressType {
  /// A literal IPv4 address.
  ipv4,

  /// A host name the server must resolve.
  domainName,

  /// A literal IPv6 address.
  ipv6,
}

/// Encodes [reply] with an unspecified bound address, which CONNECT clients
/// ignore.
Uint8List encodeSocks5Reply(Socks5Reply reply) => Uint8List.fromList([
  socks5Version,
  reply.code,
  0x00,
  _ipv4AddressType,
  0,
  0,
  0,
  0,
  0,
  0,
]);

/// Why a SOCKS5 handshake ended before it produced a CONNECT destination.
enum Socks5HandshakeFailure {
  /// The client closed the connection first.
  closed,

  /// The caller cancelled the handshake.
  cancelled,

  /// The client did not finish the handshake in time.
  timedOut,

  /// The client spoke another protocol or SOCKS version.
  unsupportedVersion,

  /// The client offered no authentication method the server accepts.
  noAcceptableAuthMethod,

  /// The client asked for BIND or UDP ASSOCIATE instead of CONNECT.
  unsupportedCommand,

  /// The client used an unknown address type.
  unsupportedAddressType,

  /// The destination was empty, not valid text, or used port zero.
  invalidDestination,
}

/// Thrown when a SOCKS5 handshake fails. Carries no client data, so it is safe
/// to log.
class Socks5HandshakeException implements Exception {
  /// Creates a handshake exception for [failure].
  const Socks5HandshakeException(this.failure);

  /// Why the handshake failed.
  final Socks5HandshakeFailure failure;

  @override
  String toString() => 'Socks5HandshakeException(${failure.name})';
}

/// A CONNECT request read from a SOCKS5 client.
class Socks5ConnectRequest {
  Socks5ConnectRequest._({
    required this.host,
    required this.port,
    required this.addressType,
    required this.upload,
    required Future<void> Function() discard,
  }) : _discard = discard;

  /// Destination host exactly as the client sent it.
  ///
  /// A [Socks5AddressType.domainName] destination is never resolved on this
  /// device; the SSH server resolves it.
  final String host;

  /// Destination port.
  final int port;

  /// Address form the client used for [host].
  final Socks5AddressType addressType;

  /// Client bytes that arrived after the request, then the rest of the
  /// client's stream.
  ///
  /// Single-subscription. Pausing it pauses reads from the client, so a slow
  /// destination applies backpressure to the client.
  final Stream<Uint8List> upload;

  final Future<void> Function() _discard;

  /// Stops reading from the client when [upload] will never be consumed.
  Future<void> discard() => _discard();
}

/// Reads a SOCKS5 greeting and CONNECT request from [input].
///
/// Accepts only the no-authentication method and the CONNECT command, writing
/// the method selection and any failure reply through [write]. The caller
/// writes the reply for a successful request after it opens the destination.
///
/// Fails with a [Socks5HandshakeException] when the client sends anything
/// else, closes early, takes longer than [timeout], or [cancel] completes
/// first.
Future<Socks5ConnectRequest> readSocks5ConnectRequest(
  Stream<Uint8List> input, {
  required void Function(List<int> bytes) write,
  required Duration timeout,
  Future<void>? cancel,
}) {
  final result = Completer<Socks5ConnectRequest>();
  final buffered = <int>[];
  var greeted = false;
  late final StreamSubscription<Uint8List> subscription;
  late final Timer timer;

  void fail(Socks5HandshakeFailure failure, {List<int>? reply}) {
    if (result.isCompleted) return;
    timer.cancel();
    if (reply != null) {
      try {
        write(reply);
      } on Object {
        // The client may already be gone; the handshake fails either way.
      }
    }
    unawaited(subscription.cancel());
    result.completeError(Socks5HandshakeException(failure));
  }

  void failRequest(Socks5HandshakeFailure failure, Socks5Reply reply) =>
      fail(failure, reply: encodeSocks5Reply(reply));

  // Returns the greeting length once it is complete, or null to wait.
  int? parseGreeting() {
    if (buffered.length < 2) return null;
    if (buffered[0] != socks5Version) {
      fail(Socks5HandshakeFailure.unsupportedVersion);
      return null;
    }
    final length = 2 + buffered[1];
    if (buffered.length < length) return null;
    if (!buffered.sublist(2, length).contains(_noAuthenticationMethod)) {
      fail(
        Socks5HandshakeFailure.noAcceptableAuthMethod,
        reply: const [socks5Version, _noAcceptableMethods],
      );
      return null;
    }
    write(const [socks5Version, _noAuthenticationMethod]);
    return length;
  }

  void handOff({
    required String host,
    required int port,
    required Socks5AddressType addressType,
    required int requestLength,
  }) {
    timer.cancel();
    subscription.pause();
    final leftover = Uint8List.fromList(buffered.sublist(requestLength));
    var listened = false;
    late final StreamController<Uint8List> upload;
    upload = StreamController<Uint8List>(
      onListen: () {
        listened = true;
        if (leftover.isNotEmpty) upload.add(leftover);
        subscription
          ..onData(upload.add)
          ..onError(upload.addError)
          ..onDone(() => unawaited(upload.close()))
          ..resume();
      },
      onPause: subscription.pause,
      onResume: subscription.resume,
      onCancel: subscription.cancel,
    );
    result.complete(
      Socks5ConnectRequest._(
        host: host,
        port: port,
        addressType: addressType,
        upload: upload.stream,
        discard: () async {
          if (!listened) await subscription.cancel();
        },
      ),
    );
  }

  void parseRequest() {
    if (buffered.length < 5) return;
    if (buffered[0] != socks5Version) {
      failRequest(
        Socks5HandshakeFailure.unsupportedVersion,
        Socks5Reply.generalFailure,
      );
      return;
    }
    if (buffered[1] != _connectCommand) {
      failRequest(
        Socks5HandshakeFailure.unsupportedCommand,
        Socks5Reply.commandNotSupported,
      );
      return;
    }
    final addressType = switch (buffered[3]) {
      _ipv4AddressType => Socks5AddressType.ipv4,
      _domainNameAddressType => Socks5AddressType.domainName,
      _ipv6AddressType => Socks5AddressType.ipv6,
      _ => null,
    };
    if (addressType == null) {
      failRequest(
        Socks5HandshakeFailure.unsupportedAddressType,
        Socks5Reply.addressTypeNotSupported,
      );
      return;
    }
    final addressLength = switch (addressType) {
      Socks5AddressType.ipv4 => 4,
      Socks5AddressType.domainName => 1 + buffered[4],
      Socks5AddressType.ipv6 => 16,
    };
    final requestLength = 4 + addressLength + 2;
    if (buffered.length < requestLength) return;
    final address = buffered.sublist(4, 4 + addressLength);
    final String host;
    switch (addressType) {
      case Socks5AddressType.ipv4:
        host = address.join('.');
      case Socks5AddressType.ipv6:
        host = InternetAddress.fromRawAddress(
          Uint8List.fromList(address),
          type: InternetAddressType.IPv6,
        ).address;
      case Socks5AddressType.domainName:
        final name = address.sublist(1);
        if (name.isEmpty || name.any((byte) => byte <= 0x20 || byte >= 0x7f)) {
          failRequest(
            Socks5HandshakeFailure.invalidDestination,
            Socks5Reply.hostUnreachable,
          );
          return;
        }
        host = ascii.decode(name);
    }
    final port =
        (buffered[requestLength - 2] << 8) | buffered[requestLength - 1];
    if (port == 0) {
      failRequest(
        Socks5HandshakeFailure.invalidDestination,
        Socks5Reply.hostUnreachable,
      );
      return;
    }
    handOff(
      host: host,
      port: port,
      addressType: addressType,
      requestLength: requestLength,
    );
  }

  void process() {
    if (!greeted) {
      final greetingLength = parseGreeting();
      if (greetingLength == null) return;
      greeted = true;
      buffered.removeRange(0, greetingLength);
    }
    parseRequest();
  }

  timer = Timer(timeout, () => fail(Socks5HandshakeFailure.timedOut));
  subscription = input.listen(
    (chunk) {
      if (result.isCompleted) return;
      buffered.addAll(chunk);
      try {
        process();
      } on Object {
        // A write to a client that has gone away; treat it as a close.
        fail(Socks5HandshakeFailure.closed);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (result.isCompleted) return;
      timer.cancel();
      unawaited(subscription.cancel());
      result.completeError(error, stackTrace);
    },
    onDone: () => fail(Socks5HandshakeFailure.closed),
  );
  if (cancel != null) {
    void cancelled() => fail(Socks5HandshakeFailure.cancelled);
    unawaited(
      cancel.then((_) => cancelled(), onError: (Object _) => cancelled()),
    );
  }
  return result.future;
}
