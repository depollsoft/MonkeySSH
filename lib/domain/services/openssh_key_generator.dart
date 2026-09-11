import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart' as cg;
import 'package:dartssh2/dartssh2.dart';
// The OpenSSH bcrypt-pbkdf key-derivation function is not exported from the
// dartssh2 barrel, but it is the exact routine dartssh2 uses to *decrypt*
// passphrase-protected keys. Reusing it guarantees the keys we generate here
// round-trip through `SSHKeyPair.fromPem` (and OpenSSH itself).
// ignore: implementation_imports
import 'package:dartssh2/src/utils/bcrypt.dart' show bcrypt_pbkdf;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;

import 'key_service.dart';

/// Parses and decrypts PEM identities away from the UI isolate.
Future<List<SSHKeyPair>> parseOpenSshPrivateKey(
  String privateKey,
  String? passphrase,
) => compute(_parseOpenSshPrivateKey, (privateKey, passphrase));

List<SSHKeyPair> _parseOpenSshPrivateKey((String, String?) params) =>
    SSHKeyPair.fromPem(
      params.$1,
      (params.$2?.isEmpty ?? false) ? null : params.$2,
    );

/// Parameters passed to the background isolate that builds the key.
typedef _GenerateParams = ({
  SshKeyType keyType,
  String comment,
  String? passphrase,
});

/// Generated OpenSSH private key and its encoded public key.
typedef GeneratedOpenSshKey = ({String privateKeyPem, Uint8List publicKeyBlob});

/// Generates a private key in the OpenSSH format
/// (`-----BEGIN OPENSSH PRIVATE KEY-----`) entirely in Dart.
///
/// Works on every platform (including mobile, where no `ssh-keygen` binary is
/// available). When [passphrase] is non-empty the key is encrypted with
/// `aes256-ctr` using an OpenSSH `bcrypt` KDF, exactly like `ssh-keygen`.
///
/// The heavy cryptographic work (RSA prime search, bcrypt rounds) runs in a
/// background isolate so the UI stays responsive.
Future<GeneratedOpenSshKey> generateOpenSshKey({
  required SshKeyType keyType,
  required String comment,
  String? passphrase,
}) => compute(_generateOpenSshKey, (
  keyType: keyType,
  comment: comment,
  passphrase: passphrase,
));

Future<GeneratedOpenSshKey> _generateOpenSshKey(_GenerateParams params) async {
  final passphrase = (params.passphrase?.isEmpty ?? true)
      ? null
      : params.passphrase;

  switch (params.keyType) {
    case SshKeyType.ed25519:
      return _buildEd25519Pem(params.comment, passphrase);
    case SshKeyType.rsa2048:
      return _buildRsaPem(2048, params.comment, passphrase);
    case SshKeyType.rsa4096:
      return _buildRsaPem(4096, params.comment, passphrase);
  }
}

Future<GeneratedOpenSshKey> _buildEd25519Pem(
  String comment,
  String? passphrase,
) async {
  // Force the pure-Dart implementation so generation is deterministic and safe
  // to run inside a background isolate (a platform-backed implementation could
  // rely on a message channel that is unavailable off the root isolate).
  final algorithm = cg.DartEd25519();
  final keyPair = await algorithm.newKeyPair();
  final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  final publicKey = Uint8List.fromList(
    (await keyPair.extractPublicKey()).bytes,
  );
  // OpenSSH stores the Ed25519 private scalar as seed(32) || public(32).
  final privateKey = Uint8List.fromList([...seed, ...publicKey]);

  final publicKeyBlob =
      (_SshWire()
            ..writeString('ssh-ed25519')
            ..writeBytes(publicKey))
          .toBytes();

  final privateSection = _SshWire()
    ..writeString('ssh-ed25519')
    ..writeBytes(publicKey)
    ..writeBytes(privateKey)
    ..writeString(comment);

  return _assembleOpenSshKey(
    publicKeyBlob: publicKeyBlob,
    privateSection: privateSection.toBytes(),
    passphrase: passphrase,
  );
}

GeneratedOpenSshKey _buildRsaPem(int bits, String comment, String? passphrase) {
  final pair = _generateRsaKeyPair(bits);
  final public = pair.publicKey as pc.RSAPublicKey;
  final private = pair.privateKey as pc.RSAPrivateKey;

  final n = private.modulus!;
  final e = public.publicExponent!;
  final d = private.privateExponent!;
  // OpenSSH/OpenSSL convention keeps p > q so that iqmp = q^-1 mod p.
  var p = private.p!;
  var q = private.q!;
  if (p < q) {
    final swap = p;
    p = q;
    q = swap;
  }
  final iqmp = q.modInverse(p);

  final publicKeyBlob =
      (_SshWire()
            ..writeString('ssh-rsa')
            ..writeMpint(e)
            ..writeMpint(n))
          .toBytes();

  final privateSection = _SshWire()
    ..writeString('ssh-rsa')
    ..writeMpint(n)
    ..writeMpint(e)
    ..writeMpint(d)
    ..writeMpint(iqmp)
    ..writeMpint(p)
    ..writeMpint(q)
    ..writeString(comment);

  return _assembleOpenSshKey(
    publicKeyBlob: publicKeyBlob,
    privateSection: privateSection.toBytes(),
    passphrase: passphrase,
  );
}

pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> _generateRsaKeyPair(
  int bits,
) {
  final seed = _randomBytes(32);
  final secureRandom = pc.SecureRandom('Fortuna')..seed(pc.KeyParameter(seed));
  final generator = pc.RSAKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        secureRandom,
      ),
    );
  return generator.generateKeyPair();
}

/// Wraps [publicKeyBlob] and [privateSection] into the `openssh-key-v1`
/// container, optionally encrypting the private half with [passphrase].
GeneratedOpenSshKey _assembleOpenSshKey({
  required Uint8List publicKeyBlob,
  required Uint8List privateSection,
  required String? passphrase,
}) {
  final encrypt = passphrase != null && passphrase.isNotEmpty;
  final blockSize = encrypt ? 16 : 8;

  // checkint appears twice so the parser can detect a wrong passphrase.
  final checkInt = _random.nextInt(0xFFFFFFFF);
  final unencrypted = _SshWire()
    ..writeUint32(checkInt)
    ..writeUint32(checkInt)
    ..writeRaw(privateSection);
  // Pad with 1, 2, 3, ... up to the cipher block size.
  for (var i = 1; unencrypted.length % blockSize != 0; i++) {
    unencrypted.writeByte(i);
  }
  var privateBlob = unencrypted.toBytes();

  var cipherName = 'none';
  var kdfName = 'none';
  var kdfOptions = Uint8List(0);

  if (encrypt) {
    final salt = _randomBytes(16);
    const rounds = 16;
    final derived = Uint8List(48); // 32-byte key + 16-byte IV
    final passphraseBytes = Uint8List.fromList(utf8.encode(passphrase));
    final result = bcrypt_pbkdf(
      passphraseBytes,
      passphraseBytes.length,
      salt,
      salt.length,
      derived,
      derived.length,
      rounds,
    );
    if (result != 0) {
      throw StateError('bcrypt_pbkdf failed to derive an encryption key');
    }
    final key = Uint8List.view(derived.buffer, 0, 32);
    final iv = Uint8List.view(derived.buffer, 32, 16);
    final cipher = pc.CTRStreamCipher(pc.AESEngine())
      ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    privateBlob = cipher.process(privateBlob);
    cipherName = 'aes256-ctr';
    kdfName = 'bcrypt';
    kdfOptions =
        (_SshWire()
              ..writeBytes(salt)
              ..writeUint32(rounds))
            .toBytes();
  }

  final container = _SshWire()
    ..writeRaw(Uint8List.fromList(utf8.encode('openssh-key-v1')))
    ..writeByte(0)
    ..writeString(cipherName)
    ..writeString(kdfName)
    ..writeBytes(kdfOptions)
    ..writeUint32(1)
    ..writeBytes(publicKeyBlob)
    ..writeBytes(privateBlob);

  return (
    privateKeyPem: _wrapPem(container.toBytes()),
    publicKeyBlob: publicKeyBlob,
  );
}

String _wrapPem(Uint8List content) {
  final base64Content = base64.encode(content);
  final buffer = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
  for (var i = 0; i < base64Content.length; i += 70) {
    buffer.writeln(
      base64Content.substring(i, min(i + 70, base64Content.length)),
    );
  }
  buffer.write('-----END OPENSSH PRIVATE KEY-----\n');
  return buffer.toString();
}

final Random _random = Random.secure();

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

/// Minimal writer for the SSH wire format (RFC 4251): length-prefixed strings,
/// big-endian integers, and multiple-precision integers.
class _SshWire {
  final BytesBuilder _builder = BytesBuilder();

  int get length => _builder.length;

  void writeByte(int value) => _builder.addByte(value & 0xff);

  void writeRaw(Uint8List value) => _builder.add(value);

  void writeUint32(int value) => _builder.add([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);

  void writeBytes(List<int> value) {
    writeUint32(value.length);
    _builder.add(value);
  }

  void writeString(String value) => writeBytes(utf8.encode(value));

  void writeMpint(BigInt value) => writeBytes(_encodeMpint(value));

  Uint8List toBytes() => _builder.toBytes();
}

/// Encodes a non-negative [BigInt] as an SSH mpint: big-endian, minimal length,
/// with a leading zero byte when the most-significant bit would otherwise be
/// interpreted as a sign bit.
Uint8List _encodeMpint(BigInt value) {
  if (value == BigInt.zero) return Uint8List(0);
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  if (bytes.first & 0x80 != 0) {
    return Uint8List.fromList([0, ...bytes]);
  }
  return Uint8List.fromList(bytes);
}
