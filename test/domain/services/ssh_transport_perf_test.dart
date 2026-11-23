import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/utils/fast_aes_gcm.dart';
import 'package:dartssh2/src/utils/openssh_chacha20_poly1305.dart';
import 'package:dartssh2/src/utils/ssh_compression.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('FastAesGcm correctness', () {
    test(
      'matches PointyCastle GCMBlockCipher bit-for-bit across lengths and keys',
      () {
        final rng = Random(42);
        for (final keyLen in [16, 32]) {
          final key = Uint8List.fromList(
            List.generate(keyLen, (_) => rng.nextInt(256)),
          );
          final iv = Uint8List.fromList(
            List.generate(12, (_) => rng.nextInt(256)),
          );
          final fastEnc = FastAesGcm(key, iv);
          final fastDec = FastAesGcm(key, iv);

          for (final seq in [0, 1, 7, 255, 65535, 0x12345678]) {
            for (final len in [0, 1, 5, 15, 16, 17, 31, 32, 64, 1000, 32768]) {
              final aad = Uint8List(4)..buffer.asByteData().setUint32(0, len);
              final pt = Uint8List.fromList(
                List.generate(len, (_) => rng.nextInt(256)),
              );

              // Reference PointyCastle AES-GCM with RFC 5647 nonce = iv + seq
              final refNonce = Uint8List.fromList(iv);
              final view = ByteData.sublistView(refNonce);
              final lo = view.getUint32(8) + (seq & 0xffffffff);
              final hi = view.getUint32(4) + (lo >>> 32);
              view
                ..setUint32(8, lo & 0xffffffff)
                ..setUint32(4, hi & 0xffffffff);

              final pcEnc = GCMBlockCipher(AESEngine())
                ..init(
                  true,
                  AEADParameters(KeyParameter(key), 128, refNonce, aad),
                );
              final expectedCtAndTag = pcEnc.process(pt);

              // FastAesGcm encrypt (both out-of-place and in-place)
              final outBuf = Uint8List(4 + len + 16)
                ..setRange(0, 4, aad)
                ..setRange(4, 4 + len, pt);
              fastEnc.encryptInto(
                sequence: seq,
                aad: outBuf,
                aadOffset: 0,
                aadLength: 4,
                plaintext: outBuf,
                plaintextOffset: 4,
                plaintextLength: len,
                output: outBuf,
                outputOffset: 4,
              );
              final actualCtAndTag = Uint8List.sublistView(outBuf, 4);
              expect(
                actualCtAndTag,
                equals(expectedCtAndTag),
                reason: 'encrypt mismatch keyLen=$keyLen seq=$seq len=$len',
              );

              // FastAesGcm decrypt
              final decrypted = fastDec.decrypt(
                sequence: seq,
                aad: outBuf,
                aadOffset: 0,
                aadLength: 4,
                ciphertextAndTag: outBuf,
                ciphertextOffset: 4,
                ciphertextAndTagLength: len + 16,
              );
              expect(
                decrypted,
                equals(pt),
                reason: 'decrypt mismatch keyLen=$keyLen seq=$seq len=$len',
              );

              // Tampered tag must throw InvalidCipherTextException
              final tamperedTag = Uint8List.fromList(outBuf);
              tamperedTag[tamperedTag.length - 1] ^= 0x01;
              expect(
                () => fastDec.decrypt(
                  sequence: seq,
                  aad: tamperedTag,
                  aadOffset: 0,
                  aadLength: 4,
                  ciphertextAndTag: tamperedTag,
                  ciphertextOffset: 4,
                  ciphertextAndTagLength: len + 16,
                ),
                throwsA(isA<InvalidCipherTextException>()),
              );

              // Tampered AAD must throw InvalidCipherTextException
              final tamperedAad = Uint8List.fromList(outBuf);
              tamperedAad[0] ^= 0x80;
              expect(
                () => fastDec.decrypt(
                  sequence: seq,
                  aad: tamperedAad,
                  aadOffset: 0,
                  aadLength: 4,
                  ciphertextAndTag: tamperedAad,
                  ciphertextOffset: 4,
                  ciphertextAndTagLength: len + 16,
                ),
                throwsA(isA<InvalidCipherTextException>()),
              );
            }
          }
        }
      },
    );
  });

  group('OpenSSHChaCha20Poly1305 correctness', () {
    test('round-trips with knownPacketLength and rejects tampered tags', () {
      final key = Uint8List.fromList(List.generate(64, (i) => (i * 7) & 0xff));
      final enc = OpenSSHChaCha20Poly1305(key);
      final dec = OpenSSHChaCha20Poly1305(key);
      for (final len in [16, 64, 4096, 32768]) {
        final packet = Uint8List(4 + len);
        ByteData.sublistView(packet, 0, 4).setUint32(0, len);
        for (var i = 0; i < len; i++) {
          packet[4 + i] = (i * 13) & 0xff;
        }
        final encrypted = enc.encryptPacket(packet, len);
        final decodedLen = dec.decryptPacketLength(
          Uint8List.sublistView(encrypted, 0, 4),
          len,
        );
        expect(decodedLen, len);
        final decrypted = dec.decryptPacket(
          encrypted,
          len,
          knownPacketLength: decodedLen,
        );
        expect(decrypted, equals(packet));
      }
    });
  });

  group('SSH zlib@openssh.com stateful packet compression', () {
    test('round-trips multi-packet stateful stream with Z_SYNC_FLUSH', () {
      final comp = createSSHPacketCompressor(SSHCompressionType.zlibDelayed)!;
      final decomp = createSSHPacketDecompressor(
        SSHCompressionType.zlibDelayed,
      )!;
      var totalRaw = 0;
      var totalComp = 0;
      for (var i = 0; i < 100; i++) {
        final msg = Uint8List.fromList(
          utf8.encode(
            '\x1b[38;2;200;220;240mpacket $i: typical terminal line with ANSI codes and repeated words\r\n' *
                8,
          ),
        );
        totalRaw += msg.length;
        final c = comp.compress(msg);
        totalComp += c.length;
        final d = decomp.decompress(c);
        expect(d, equals(msg));
      }
      // Stateful zlib should achieve >5x compression on repeated ANSI lines.
      expect(totalComp, lessThan(totalRaw ~/ 5));
    });

    test('enforces maxDecompressedBytes against zip bombs', () {
      final comp = createSSHPacketCompressor(SSHCompressionType.zlibDelayed)!;
      final decomp = createSSHPacketDecompressor(
        SSHCompressionType.zlibDelayed,
      )!;
      final bigZeros = Uint8List(300 * 1024);
      final compressed = comp.compress(bigZeros);
      expect(compressed.length, lessThan(2048));
      expect(
        () => decomp.decompress(compressed, maxDecompressedBytes: 256 * 1024),
        throwsA(isA<SSHPacketError>()),
      );
    });
  });
}
