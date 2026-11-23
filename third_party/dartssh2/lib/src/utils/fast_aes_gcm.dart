import 'dart:typed_data';

import 'package:dartssh2/src/utils/int.dart';
import 'package:dartssh2/src/utils/list.dart';
import 'package:pointycastle/export.dart';

/// Fast, reusable AES-GCM (96-bit nonce, 128-bit tag) implementation tailored
/// to SSH's `aes128-gcm@openssh.com` and `aes256-gcm@openssh.com`.
///
/// Unlike PointyCastle's [GCMBlockCipher], this class:
/// - Expands the AES key schedule and derives the GHASH subkey `H` once per
///   rekey instead of on every SSH packet.
/// - Uses an 8-bit Shoup GHASH multiplication table (`4 KiB`) with a 256-entry
///   reduction table instead of a 128-iteration bit-by-bit loop.
/// - Reuses scratch buffers across packets for zero per-block heap allocations.
/// - Authenticates the tag before decrypting on receive.
class FastAesGcm {
  static const int blockSize = 16;
  static const int nonceSize = 12;
  static const int tagSize = 16;

  /// Precomputed 8-bit reduction table for GF(2^128) with polynomial
  /// `x^128 + x^7 + x^2 + x + 1` (represented as `0xE1000000` in bit-reflected
  /// GCM order).
  static final Uint32List _ghashReduction = _buildReductionTable();

  static Uint32List _buildReductionTable() {
    final table = Uint32List(256);
    for (var rem = 0; rem < 256; rem++) {
      var r = 0;
      for (var bit = 0; bit < 8; bit++) {
        if ((rem & (1 << bit)) != 0) {
          r ^= 0xE1000000 >>> (7 - bit);
        }
      }
      table[rem] = r;
    }
    return table;
  }

  final AESEngine _aes;
  final Uint32List _ghashTable;
  final Uint8List _baseIv;

  // Reusable per-instance scratch buffers (single-threaded per transport).
  final Uint8List _counter = Uint8List(16);
  final Uint8List _j0Mask = Uint8List(16);
  final Uint8List _keystream = Uint8List(16);
  final Uint8List _partialBlock = Uint8List(16);
  final Uint8List _nonceBuf = Uint8List(12);
  late final ByteData _nonceView = ByteData.sublistView(_nonceBuf);

  // GHASH accumulator (four unsigned 32-bit big-endian words).
  int _s0 = 0;
  int _s1 = 0;
  int _s2 = 0;
  int _s3 = 0;

  FastAesGcm(Uint8List key, Uint8List baseIv)
      : _aes = AESEngine()..init(true, KeyParameter(key)),
        _ghashTable = Uint32List(256 * 4),
        _baseIv = Uint8List.fromList(baseIv) {
    if (baseIv.length != nonceSize) {
      throw ArgumentError.value(
        baseIv,
        'baseIv',
        'AEAD IV must be $nonceSize bytes long',
      );
    }

    // Compute GHASH subkey H = AES_K(0^128).
    final hBytes = Uint8List(16);
    _aes.processBlock(hBytes, 0, hBytes, 0);

    var w0 = _readUint32BE(hBytes, 0);
    var w1 = _readUint32BE(hBytes, 4);
    var w2 = _readUint32BE(hBytes, 8);
    var w3 = _readUint32BE(hBytes, 12);

    // M[0x80] = H, then M[0x40] = H*x, ..., M[0x01] = H*x^7.
    final table = _ghashTable;
    var base = 0x80 * 4;
    table[base] = w0;
    table[base + 1] = w1;
    table[base + 2] = w2;
    table[base + 3] = w3;

    for (var bit = 0x40; bit >= 1; bit >>= 1) {
      final carry = w3 & 1;
      w3 = (w3 >>> 1) | ((w2 & 1) << 31);
      w2 = (w2 >>> 1) | ((w1 & 1) << 31);
      w1 = (w1 >>> 1) | ((w0 & 1) << 31);
      w0 = (w0 >>> 1) ^ (carry != 0 ? 0xE1000000 : 0);

      base = bit * 4;
      table[base] = w0;
      table[base + 1] = w1;
      table[base + 2] = w2;
      table[base + 3] = w3;
    }

    // Fill linear combinations for all 256 byte values.
    for (var i = 2; i < 256; i <<= 1) {
      final iOff = i * 4;
      final i0 = table[iOff];
      final i1 = table[iOff + 1];
      final i2 = table[iOff + 2];
      final i3 = table[iOff + 3];
      for (var j = 1; j < i; j++) {
        final jOff = j * 4;
        final dst = (i | j) * 4;
        table[dst] = i0 ^ table[jOff];
        table[dst + 1] = i1 ^ table[jOff + 1];
        table[dst + 2] = i2 ^ table[jOff + 2];
        table[dst + 3] = i3 ^ table[jOff + 3];
      }
    }
  }

  /// Derives the 12-byte RFC 5647 nonce into [_nonceBuf] without allocating.
  Uint8List _prepareNonce(int sequence) {
    for (var i = 0; i < 12; i++) {
      _nonceBuf[i] = _baseIv[i];
    }
    _nonceView.addToUint64Split(4, sequence);
    return _nonceBuf;
  }

  /// Encrypts [plaintext] starting at [plaintextOffset] for [plaintextLength]
  /// bytes, writing ciphertext to [output] at [outputOffset] and the 16-byte
  /// authentication tag immediately after it (`outputOffset + plaintextLength`).
  ///
  /// Supports in-place encryption when [plaintext] and [output] alias at the
  /// same offset.
  void encryptInto({
    required int sequence,
    required Uint8List aad,
    required int aadOffset,
    required int aadLength,
    required Uint8List plaintext,
    required int plaintextOffset,
    required int plaintextLength,
    required Uint8List output,
    required int outputOffset,
  }) {
    final nonce = _prepareNonce(sequence);
    _initCounterAndJ0(nonce);

    // Reset GHASH and process AAD.
    _s0 = 0;
    _s1 = 0;
    _s2 = 0;
    _s3 = 0;
    _ghashUpdate(aad, aadOffset, aadLength);

    // AES-CTR encrypt + incremental GHASH over produced ciphertext.
    final fullEnd = plaintextLength & ~15;
    var off = 0;
    while (off < fullEnd) {
      _incrementCounter();
      _aes.processBlock(_counter, 0, _keystream, 0);
      final src = plaintextOffset + off;
      final dst = outputOffset + off;
      for (var i = 0; i < 16; i++) {
        output[dst + i] = plaintext[src + i] ^ _keystream[i];
      }
      _ghashBlock(output, dst);
      off += 16;
    }

    final rem = plaintextLength - fullEnd;
    if (rem > 0) {
      _incrementCounter();
      _aes.processBlock(_counter, 0, _keystream, 0);
      final src = plaintextOffset + fullEnd;
      final dst = outputOffset + fullEnd;
      for (var i = 0; i < rem; i++) {
        final c = plaintext[src + i] ^ _keystream[i];
        output[dst + i] = c;
        _partialBlock[i] = c;
      }
      for (var i = rem; i < 16; i++) {
        _partialBlock[i] = 0;
      }
      _ghashBlock(_partialBlock, 0);
    }

    _ghashLengths(aadLength, plaintextLength);
    _writeTag(output, outputOffset + plaintextLength);
  }

  /// Authenticates and decrypts [ciphertextAndTag] (containing `ciphertext || tag`)
  /// into a newly allocated [Uint8List] of length `ciphertextAndTagLength - 16`.
  ///
  /// Throws [InvalidCipherTextException] if the authentication tag is invalid.
  Uint8List decrypt({
    required int sequence,
    required Uint8List aad,
    required int aadOffset,
    required int aadLength,
    required Uint8List ciphertextAndTag,
    required int ciphertextOffset,
    required int ciphertextAndTagLength,
  }) {
    if (ciphertextAndTagLength < tagSize) {
      throw InvalidCipherTextException('Ciphertext shorter than GCM tag');
    }

    final ctLength = ciphertextAndTagLength - tagSize;
    final nonce = _prepareNonce(sequence);
    _initCounterAndJ0(nonce);

    // Authenticate BEFORE decrypting: compute GHASH(AAD, ciphertext) and
    // verify the tag in constant time.
    _s0 = 0;
    _s1 = 0;
    _s2 = 0;
    _s3 = 0;
    _ghashUpdate(aad, aadOffset, aadLength);
    _ghashUpdate(ciphertextAndTag, ciphertextOffset, ctLength);
    _ghashLengths(aadLength, ctLength);

    // Compute expected tag into _partialBlock and compare in constant time.
    _writeTag(_partialBlock, 0);
    final actualTag = Uint8List.sublistView(
      ciphertextAndTag,
      ciphertextOffset + ctLength,
      ciphertextOffset + ciphertextAndTagLength,
    );
    if (!constantTimeEquals(_partialBlock, actualTag)) {
      throw InvalidCipherTextException('mac check in GCM failed');
    }

    // Tag is valid: decrypt ciphertext with AES-CTR.
    final plaintext = Uint8List(ctLength);
    final fullEnd = ctLength & ~15;
    var off = 0;
    while (off < fullEnd) {
      _incrementCounter();
      _aes.processBlock(_counter, 0, _keystream, 0);
      final src = ciphertextOffset + off;
      for (var i = 0; i < 16; i++) {
        plaintext[off + i] = ciphertextAndTag[src + i] ^ _keystream[i];
      }
      off += 16;
    }

    final rem = ctLength - fullEnd;
    if (rem > 0) {
      _incrementCounter();
      _aes.processBlock(_counter, 0, _keystream, 0);
      final src = ciphertextOffset + fullEnd;
      for (var i = 0; i < rem; i++) {
        plaintext[fullEnd + i] = ciphertextAndTag[src + i] ^ _keystream[i];
      }
    }

    return plaintext;
  }

  @pragma('vm:prefer-inline')
  void _initCounterAndJ0(Uint8List nonce) {
    final c = _counter;
    for (var i = 0; i < 12; i++) {
      c[i] = nonce[i];
    }
    c[12] = 0;
    c[13] = 0;
    c[14] = 0;
    c[15] = 1;
    // Precompute AES_K(J0) for final tag XOR while counter == J0.
    _aes.processBlock(c, 0, _j0Mask, 0);
  }

  @pragma('vm:prefer-inline')
  void _incrementCounter() {
    final c = _counter;
    final b3 = (c[15] + 1) & 0xff;
    c[15] = b3;
    if (b3 != 0) return;
    final b2 = (c[14] + 1) & 0xff;
    c[14] = b2;
    if (b2 != 0) return;
    final b1 = (c[13] + 1) & 0xff;
    c[13] = b1;
    if (b1 != 0) return;
    c[12] = (c[12] + 1) & 0xff;
  }

  void _ghashUpdate(Uint8List data, int offset, int length) {
    final fullEnd = length & ~15;
    var off = 0;
    while (off < fullEnd) {
      _ghashBlock(data, offset + off);
      off += 16;
    }
    final rem = length - fullEnd;
    if (rem > 0) {
      final src = offset + fullEnd;
      for (var i = 0; i < rem; i++) {
        _partialBlock[i] = data[src + i];
      }
      for (var i = rem; i < 16; i++) {
        _partialBlock[i] = 0;
      }
      _ghashBlock(_partialBlock, 0);
    }
  }

  void _ghashLengths(int aadBytes, int ctBytes) {
    // Bit lengths as two big-endian 64-bit integers.
    final aadBitsHi = aadBytes >>> 29;
    final aadBitsLo = (aadBytes << 3) & 0xffffffff;
    final ctBitsHi = ctBytes >>> 29;
    final ctBitsLo = (ctBytes << 3) & 0xffffffff;
    _s0 ^= aadBitsHi;
    _s1 ^= aadBitsLo;
    _s2 ^= ctBitsHi;
    _s3 ^= ctBitsLo;
    _ghashMultiply();
  }

  @pragma('vm:prefer-inline')
  void _ghashBlock(Uint8List data, int offset) {
    _s0 ^= _readUint32BE(data, offset);
    _s1 ^= _readUint32BE(data, offset + 4);
    _s2 ^= _readUint32BE(data, offset + 8);
    _s3 ^= _readUint32BE(data, offset + 12);
    _ghashMultiply();
  }

  /// Multiplies the 128-bit accumulator `(_s0, _s1, _s2, _s3)` by `H` in
  /// GF(2^128) using the 8-bit Shoup table.
  @pragma('vm:prefer-inline')
  void _ghashMultiply() {
    final table = _ghashTable;
    final red = _ghashReduction;
    final x0 = _s0;
    final x1 = _s1;
    final x2 = _s2;
    final x3 = _s3;

    // Start with byte 15 (least significant byte of x3).
    var idx = (x3 & 0xff) << 2;
    var z0 = table[idx];
    var z1 = table[idx + 1];
    var z2 = table[idx + 2];
    var z3 = table[idx + 3];

    // Bytes 14, 13, 12 from x3.
    for (var shift = 8; shift <= 24; shift += 8) {
      final rem = z3 & 0xff;
      z3 = (z3 >>> 8) | ((z2 & 0xff) << 24);
      z2 = (z2 >>> 8) | ((z1 & 0xff) << 24);
      z1 = (z1 >>> 8) | ((z0 & 0xff) << 24);
      z0 = (z0 >>> 8) ^ red[rem];
      idx = ((x3 >>> shift) & 0xff) << 2;
      z0 ^= table[idx];
      z1 ^= table[idx + 1];
      z2 ^= table[idx + 2];
      z3 ^= table[idx + 3];
    }

    // Bytes 11..8 from x2.
    for (var shift = 0; shift <= 24; shift += 8) {
      final rem = z3 & 0xff;
      z3 = (z3 >>> 8) | ((z2 & 0xff) << 24);
      z2 = (z2 >>> 8) | ((z1 & 0xff) << 24);
      z1 = (z1 >>> 8) | ((z0 & 0xff) << 24);
      z0 = (z0 >>> 8) ^ red[rem];
      idx = ((x2 >>> shift) & 0xff) << 2;
      z0 ^= table[idx];
      z1 ^= table[idx + 1];
      z2 ^= table[idx + 2];
      z3 ^= table[idx + 3];
    }

    // Bytes 7..4 from x1.
    for (var shift = 0; shift <= 24; shift += 8) {
      final rem = z3 & 0xff;
      z3 = (z3 >>> 8) | ((z2 & 0xff) << 24);
      z2 = (z2 >>> 8) | ((z1 & 0xff) << 24);
      z1 = (z1 >>> 8) | ((z0 & 0xff) << 24);
      z0 = (z0 >>> 8) ^ red[rem];
      idx = ((x1 >>> shift) & 0xff) << 2;
      z0 ^= table[idx];
      z1 ^= table[idx + 1];
      z2 ^= table[idx + 2];
      z3 ^= table[idx + 3];
    }

    // Bytes 3..0 from x0.
    for (var shift = 0; shift <= 24; shift += 8) {
      final rem = z3 & 0xff;
      z3 = (z3 >>> 8) | ((z2 & 0xff) << 24);
      z2 = (z2 >>> 8) | ((z1 & 0xff) << 24);
      z1 = (z1 >>> 8) | ((z0 & 0xff) << 24);
      z0 = (z0 >>> 8) ^ red[rem];
      idx = ((x0 >>> shift) & 0xff) << 2;
      z0 ^= table[idx];
      z1 ^= table[idx + 1];
      z2 ^= table[idx + 2];
      z3 ^= table[idx + 3];
    }

    _s0 = z0;
    _s1 = z1;
    _s2 = z2;
    _s3 = z3;
  }

  void _writeTag(Uint8List output, int offset) {
    final m = _j0Mask;
    final t0 = _s0 ^ _readUint32BE(m, 0);
    final t1 = _s1 ^ _readUint32BE(m, 4);
    final t2 = _s2 ^ _readUint32BE(m, 8);
    final t3 = _s3 ^ _readUint32BE(m, 12);
    _writeUint32BE(output, offset, t0);
    _writeUint32BE(output, offset + 4, t1);
    _writeUint32BE(output, offset + 8, t2);
    _writeUint32BE(output, offset + 12, t3);
  }

  @pragma('vm:prefer-inline')
  static int _readUint32BE(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];

  @pragma('vm:prefer-inline')
  static void _writeUint32BE(Uint8List b, int offset, int value) {
    b[offset] = (value >>> 24) & 0xff;
    b[offset + 1] = (value >>> 16) & 0xff;
    b[offset + 2] = (value >>> 8) & 0xff;
    b[offset + 3] = value & 0xff;
  }
}
