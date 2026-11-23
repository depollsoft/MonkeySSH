import 'dart:typed_data';

import 'package:dartssh2/src/utils/int.dart';
import 'package:pointycastle/export.dart';

/// The packet cipher defined by `chacha20-poly1305@openssh.com`.
///
/// This is not the RFC 8439 AEAD construction. OpenSSH uses two independent
/// ChaCha20 keys, encrypts the packet length separately, and authenticates the
/// raw encrypted length and body with Poly1305.
class OpenSSHChaCha20Poly1305 {
  static const keySize = 64;
  static const ivSize = 0;
  static const blockSize = 8;
  static const tagSize = 16;
  static const encryptedLengthSize = 4;

  OpenSSHChaCha20Poly1305(Uint8List keyMaterial) {
    if (keyMaterial.length != keySize) {
      throw ArgumentError.value(
        keyMaterial.length,
        'keyMaterial.length',
        'OpenSSH ChaCha20-Poly1305 requires exactly $keySize bytes',
      );
    }

    // PROTOCOL.chacha20poly1305 names these K_2 and K_1 respectively.
    _payloadKeyParam =
        KeyParameter(Uint8List.fromList(keyMaterial.sublist(0, 32)));
    _lengthKeyParam =
        KeyParameter(Uint8List.fromList(keyMaterial.sublist(32, 64)));
  }

  late final KeyParameter _payloadKeyParam;
  late final KeyParameter _lengthKeyParam;

  // Reusable per-instance cipher/MAC engines and scratch buffers.
  final _lengthCipher = ChaCha20Engine();
  final _payloadCipherEngine = ChaCha20Engine();
  final _poly1305 = Poly1305();
  final _nonceBuf = Uint8List(8);
  late final ByteData _nonceView = ByteData.sublistView(_nonceBuf);
  final _zeroBlock = Uint8List(64);
  final _polyKeyBlock = Uint8List(64);
  late final Uint8List _polyKeyView =
      Uint8List.sublistView(_polyKeyBlock, 0, 32);
  final _lenScratch = Uint8List(encryptedLengthSize);
  late final ByteData _lenScratchView = ByteData.sublistView(_lenScratch);
  final _tagScratch = Uint8List(tagSize);

  /// Encrypts `packet_length || padding_length || payload || padding`.
  Uint8List encryptPacket(Uint8List packet, int sequenceNumber) {
    if (packet.length < encryptedLengthSize) {
      throw ArgumentError.value(
        packet,
        'packet',
        'Packet must include a four-byte length field',
      );
    }

    final nonce = _prepareNonce(sequenceNumber);
    final output = Uint8List(packet.length + tagSize);

    _lengthCipher.init(true, ParametersWithIV(_lengthKeyParam, nonce));
    _lengthCipher.processBytes(packet, 0, encryptedLengthSize, output, 0);

    _payloadCipherEngine.init(true, ParametersWithIV(_payloadKeyParam, nonce));
    _payloadCipherEngine.processBytes(_zeroBlock, 0, 64, _polyKeyBlock, 0);
    _payloadCipherEngine.processBytes(
      packet,
      encryptedLengthSize,
      packet.length - encryptedLengthSize,
      output,
      encryptedLengthSize,
    );

    _poly1305.init(KeyParameter(_polyKeyView));
    _poly1305.update(output, 0, packet.length);
    _poly1305.doFinal(output, packet.length);

    return output;
  }

  /// Decrypts the encrypted four-byte packet length without authenticating it.
  ///
  /// SSH needs this value to determine how many bytes belong to the packet.
  /// Call [decryptPacket] before using any packet contents.
  int decryptPacketLength(Uint8List encryptedLength, int sequenceNumber) {
    if (encryptedLength.length < encryptedLengthSize) {
      throw ArgumentError.value(
        encryptedLength,
        'encryptedLength',
        'Encrypted packet length must contain at least four bytes',
      );
    }

    final nonce = _prepareNonce(sequenceNumber);
    _lengthCipher.init(true, ParametersWithIV(_lengthKeyParam, nonce));
    _lengthCipher.processBytes(
      encryptedLength,
      0,
      encryptedLengthSize,
      _lenScratch,
      0,
    );
    return _lenScratchView.getUint32(0);
  }

  /// Authenticates and decrypts a complete OpenSSH ChaCha20-Poly1305 packet.
  ///
  /// The returned bytes include the decrypted four-byte packet length. No
  /// plaintext is returned unless the Poly1305 tag is valid.
  ///
  /// When [knownPacketLength] is supplied (already decrypted by
  /// [decryptPacketLength] for the same [sequenceNumber]), skips re-decrypting
  /// the 4-byte length header after Poly1305 authentication succeeds.
  Uint8List decryptPacket(
    Uint8List packet,
    int sequenceNumber, {
    int? knownPacketLength,
  }) {
    const minimumPacketSize = encryptedLengthSize + tagSize;
    if (packet.length < minimumPacketSize) {
      throw ArgumentError.value(
        packet,
        'packet',
        'Encrypted packet is too short',
      );
    }

    final ciphertextLength = packet.length - tagSize;
    final actualTag = Uint8List.sublistView(packet, ciphertextLength);

    final nonce = _prepareNonce(sequenceNumber);
    _payloadCipherEngine.init(true, ParametersWithIV(_payloadKeyParam, nonce));
    _payloadCipherEngine.processBytes(_zeroBlock, 0, 64, _polyKeyBlock, 0);

    _poly1305.init(KeyParameter(_polyKeyView));
    _poly1305.update(packet, 0, ciphertextLength);
    _poly1305.doFinal(_tagScratch, 0);

    if (!_constantTimeEquals(_tagScratch, actualTag)) {
      throw InvalidCipherTextException(
        'OpenSSH ChaCha20-Poly1305 authentication failed',
      );
    }

    final output = Uint8List(ciphertextLength);
    if (knownPacketLength != null) {
      ByteData.sublistView(output, 0, encryptedLengthSize)
          .setUint32(0, knownPacketLength);
    } else {
      _lengthCipher.init(true, ParametersWithIV(_lengthKeyParam, nonce));
      _lengthCipher.processBytes(packet, 0, encryptedLengthSize, output, 0);
    }

    _payloadCipherEngine.processBytes(
      packet,
      encryptedLengthSize,
      ciphertextLength - encryptedLengthSize,
      output,
      encryptedLengthSize,
    );

    return output;
  }

  Uint8List _prepareNonce(int sequenceNumber) {
    if (sequenceNumber < 0 || sequenceNumber > 0xffffffff) {
      throw RangeError.range(
        sequenceNumber,
        0,
        0xffffffff,
        'sequenceNumber',
      );
    }

    // Two 32-bit writes rather than setUint64, which throws when compiled
    // to JavaScript: see utils/int.dart. sequenceNumber is checked above to
    // fit in 32 bits, so this is always exact.
    _nonceView.setUint64Split(0, sequenceNumber);
    return _nonceBuf;
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
