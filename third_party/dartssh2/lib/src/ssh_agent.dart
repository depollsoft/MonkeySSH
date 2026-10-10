import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/src/hostkey/hostkey_rsa.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_hostkey.dart';
import 'package:dartssh2/src/ssh_key_pair.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:dartssh2/src/ssh_transport.dart';
import 'package:pointycastle/api.dart' hide Signature;
import 'package:pointycastle/asymmetric/api.dart' as asymmetric;
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

abstract class SSHAgentHandler {
  Future<Uint8List> handleRequest(Uint8List request);
}

class SSHKeyPairAgent implements SSHAgentHandler {
  SSHKeyPairAgent(this._identities, {this.comment});

  final List<SSHKeyPair> _identities;
  final String? comment;

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    if (request.isEmpty) {
      return _failure();
    }
    final reader = SSHMessageReader(request);
    final messageType = reader.readUint8();
    switch (messageType) {
      case SSHAgentProtocol.requestIdentities:
        return _handleRequestIdentities();
      case SSHAgentProtocol.signRequest:
        return _handleSignRequest(reader);
      default:
        return _failure();
    }
  }

  Uint8List _handleRequestIdentities() {
    final writer = SSHMessageWriter();
    writer.writeUint8(SSHAgentProtocol.identitiesAnswer);
    writer.writeUint32(_identities.length);
    for (final identity in _identities) {
      final publicKey = identity.toPublicKey().encode();
      writer.writeString(publicKey);
      writer.writeUtf8(comment ?? '');
    }
    return writer.takeBytes();
  }

  Uint8List _handleSignRequest(SSHMessageReader reader) {
    final keyBlob = reader.readString();
    final data = reader.readString();
    final flags = reader.readUint32();

    final identity = _findIdentity(keyBlob);
    if (identity == null) {
      return _failure();
    }

    final signature = _sign(identity, data, flags);
    final writer = SSHMessageWriter();
    writer.writeUint8(SSHAgentProtocol.signResponse);
    writer.writeString(signature.encode());
    return writer.takeBytes();
  }

  SSHSignature _sign(SSHKeyPair identity, Uint8List data, int flags) {
    if (identity is OpenSSHRsaKeyPair || identity is RsaPrivateKey) {
      final signatureType = _rsaSignatureTypeForFlags(flags);
      return _signRsa(identity, data, signatureType);
    }
    return identity.sign(data);
  }

  String _rsaSignatureTypeForFlags(int flags) {
    if (flags & SSHAgentProtocol.rsaSha2_512 != 0) {
      return SSHRsaSignatureType.sha512;
    }
    if (flags & SSHAgentProtocol.rsaSha2_256 != 0) {
      return SSHRsaSignatureType.sha256;
    }
    return SSHRsaSignatureType.sha1;
  }

  SSHRsaSignature _signRsa(
    SSHKeyPair identity,
    Uint8List data,
    String signatureType,
  ) {
    final key = _rsaKeyFrom(identity);
    if (key == null) {
      final signature = identity.sign(data);
      if (signature is SSHRsaSignature) {
        if (signature.type != signatureType) {
          throw StateError(
              'RSA signature type mismatch: requested $signatureType but identity produced ${signature.type}');
        }
        return signature;
      }
      throw StateError(
          'RSA signing requested but identity produced non-RSA signature: ${signature.runtimeType}');
    }

    final signer = _rsaSignerFor(signatureType);
    signer.init(true, PrivateKeyParameter<asymmetric.RSAPrivateKey>(key));
    return SSHRsaSignature(signatureType, signer.generateSignature(data).bytes);
  }

  asymmetric.RSAPrivateKey? _rsaKeyFrom(SSHKeyPair identity) {
    if (identity is OpenSSHRsaKeyPair) {
      return asymmetric.RSAPrivateKey(
          identity.n, identity.d, identity.p, identity.q);
    }
    if (identity is RsaPrivateKey) {
      return asymmetric.RSAPrivateKey(
          identity.n, identity.d, identity.p, identity.q);
    }
    return null;
  }

  RSASigner _rsaSignerFor(String signatureType) {
    switch (signatureType) {
      case SSHRsaSignatureType.sha1:
        return RSASigner(SHA1Digest(), '06052b0e03021a');
      case SSHRsaSignatureType.sha256:
        return RSASigner(SHA256Digest(), '0609608648016503040201');
      case SSHRsaSignatureType.sha512:
        return RSASigner(SHA512Digest(), '0609608648016503040203');
      default:
        return RSASigner(SHA256Digest(), '0609608648016503040201');
    }
  }

  SSHKeyPair? _findIdentity(Uint8List keyBlob) {
    for (final identity in _identities) {
      final publicKey = identity.toPublicKey().encode();
      if (_bytesEqual(publicKey, keyBlob)) {
        return identity;
      }
    }
    return null;
  }

  Uint8List _failure() {
    final writer = SSHMessageWriter();
    writer.writeUint8(SSHAgentProtocol.failure);
    return writer.takeBytes();
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Serves agent requests arriving on one forwarded agent channel.
///
/// MonkeySSH patch: the upstream channel copied the rest of its buffer for
/// every frame, drained a burst of frames without yielding to the event loop,
/// and queued replies without limit, so a process on the server could stall
/// the client and grow its memory until it was killed. This version:
///
/// * buffers input in a growable buffer and parses frames at an offset, so
///   neither many small frames nor one frame split into many small writes
///   cost more than linear copying;
/// * handles one request at a time and yields to the event loop before the
///   next, so a flood of frames cannot starve timers, input or rendering;
/// * closes the channel when more than [maxBufferedInputBytes] of requests
///   are waiting, which a client that waits for each reply never reaches;
/// * closes the channel when more than [maxPendingReplyBytes] of replies are
///   waiting for the peer to read them;
/// * serves at most [maxChannelsPerHandler] channels per handler at once.
///
/// When the peer sends EOF, requests it already sent are still answered, as
/// upstream does; only the limits above drop work.
class SSHAgentChannel {
  static const maxFrameSize = 256 * 1024;

  /// Unprocessed request bytes allowed before the channel is closed. Room for
  /// one maximum-size frame, its length prefix and a maximum-size packet.
  static const maxBufferedInputBytes = maxFrameSize + 4 + 32 * 1024;

  /// Reply bytes the peer may leave unread before the channel is closed.
  static const maxPendingReplyBytes = 256 * 1024;

  /// Agent channels served at once for one handler; more are refused. Each
  /// `ssh` run on the server holds one while it authenticates, so this is
  /// the number of onward connections that can sign in at the same moment.
  static const maxChannelsPerHandler = 32;

  static const _initialBufferSize = 4096;

  static final _openChannels = Expando<int>('SSHAgentChannel.open');

  /// Whether [handler] can take another agent channel. The client refuses
  /// the channel open when it cannot, before allocating anything for it.
  static bool hasRoomFor(SSHAgentHandler handler) =>
      (_openChannels[handler] ?? 0) < maxChannelsPerHandler;

  SSHAgentChannel(this._channel, this._handler, {this.printDebug}) {
    final open = (_openChannels[_handler] ?? 0) + 1;
    _openChannels[_handler] = open;
    _channel.done.whenComplete(_handleClosed);
    _subscription = _channel.stream.listen(
      _handleData,
      onDone: _handleInputDone,
      onError: (_, __) => _handleInputDone(),
    );
    if (open > maxChannelsPerHandler) {
      _abort('too many agent channels');
    }
  }

  final SSHChannel _channel;
  final SSHAgentHandler _handler;
  final SSHPrintHandler? printDebug;

  StreamSubscription<SSHChannelData>? _subscription;
  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int _end = 0;
  bool _processing = false;
  bool _closed = false;

  int get _bufferedBytes => _end - _start;

  /// The peer sent EOF: stop reading, but answer what it already sent.
  void _handleInputDone() {
    _subscription?.cancel();
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
    _openChannels[_handler] = (_openChannels[_handler] ?? 1) - 1;
    _subscription?.cancel();
    _buffer = Uint8List(0);
    _start = 0;
    _end = 0;
  }

  void _abort(String reason) {
    printDebug?.call('SSH agent: $reason, closing channel');
    _handleClosed();
    _channel.destroy();
  }

  void _handleData(SSHChannelData data) {
    if (_closed) return;
    if (_bufferedBytes + data.bytes.length > maxBufferedInputBytes) {
      _abort('too many unanswered requests');
      return;
    }
    _append(data.bytes);
    _drainRequests();
  }

  void _append(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final needed = _bufferedBytes + bytes.length;
    if (_end + bytes.length > _buffer.length) {
      if (_start >= _buffer.length ~/ 2 && needed <= _buffer.length) {
        // At least half the buffer has been consumed: slide the rest down.
        _buffer.setRange(0, _bufferedBytes, _buffer, _start);
      } else {
        var capacity = _buffer.isEmpty ? _initialBufferSize : _buffer.length;
        while (capacity < needed) {
          capacity *= 2;
        }
        final grown = Uint8List(capacity);
        grown.setRange(0, _bufferedBytes, _buffer, _start);
        _buffer = grown;
      }
      _end = _bufferedBytes;
      _start = 0;
    }
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;
  }

  void _drainRequests() {
    if (_processing || _closed) return;
    _processing = true;
    _processQueue().whenComplete(() => _processing = false);
  }

  Future<void> _processQueue() async {
    while (!_closed && _bufferedBytes >= 4) {
      final length =
          ByteData.sublistView(_buffer, _start, _start + 4).getUint32(0);
      if (length == 0 || length > maxFrameSize) {
        _abort('invalid frame length $length');
        return;
      }
      if (_bufferedBytes < 4 + length) return;
      final payloadStart = _start + 4;
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_buffer, payloadStart, payloadStart + length),
      );
      _start = payloadStart + length;
      if (_start == _end) {
        _start = 0;
        _end = 0;
      }
      Uint8List response;
      try {
        response = await _handler.handleRequest(payload);
      } catch (error) {
        printDebug?.call('SSH agent handler error: $error');
        response = _failureResponse();
      }
      if (_closed) return;
      if (_channel.pendingOutputBytes + response.length + 4 >
          maxPendingReplyBytes) {
        _abort('peer is not reading replies');
        return;
      }
      _sendResponse(response);
      // Let timers, input and rendering run before the next request.
      await Future<void>.delayed(Duration.zero);
    }
  }

  Uint8List _failureResponse() {
    final writer = SSHMessageWriter();
    writer.writeUint8(SSHAgentProtocol.failure);
    return writer.takeBytes();
  }

  void _sendResponse(Uint8List payload) {
    final writer = SSHMessageWriter();
    writer.writeUint32(payload.length);
    writer.writeBytes(payload);
    _channel.addData(writer.takeBytes());
  }
}

abstract class SSHAgentProtocol {
  static const int failure = 5;
  static const int requestIdentities = 11;
  static const int identitiesAnswer = 12;
  static const int signRequest = 13;
  static const int signResponse = 14;
  static const int rsaSha2_256 = 2;
  static const int rsaSha2_512 = 4;
}
