import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// The ECDSA public-key and signature codecs are not exported from the
// dartssh2 barrel; they mirror what an SSH server verifies.
// ignore: implementation_imports
import 'package:dartssh2/src/hostkey/hostkey_ecdsa.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/hardware_key.dart';
import 'package:monkeyssh/domain/services/hardware_key_service.dart';
import 'package:pointycastle/export.dart' as pc;

/// Signs [data] with SHA-256 ECDSA and returns the X9.62 DER encoding, the
/// form Secure Enclave and Android Keystore return.
Uint8List derSignP256(pc.ECPrivateKey privateKey, Uint8List data) {
  final signer = pc.ECDSASigner(
    pc.SHA256Digest(),
    pc.HMac(pc.SHA256Digest(), 64),
  )..init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(privateKey));
  final signature = signer.generateSignature(data) as pc.ECSignature;
  return derEncodeSignature(signature.r, signature.s);
}

/// DER-encodes `SEQUENCE { INTEGER r, INTEGER s }`.
Uint8List derEncodeSignature(BigInt r, BigInt s) {
  final body = [..._derInteger(r), ..._derInteger(s)];
  return Uint8List.fromList([0x30, body.length, ...body]);
}

List<int> _derInteger(BigInt value) {
  final bytes = <int>[];
  var remaining = value;
  while (remaining > BigInt.zero) {
    bytes.insert(0, (remaining & BigInt.from(0xff)).toInt());
    remaining >>= 8;
  }
  if (bytes.isEmpty || bytes.first & 0x80 != 0) {
    bytes.insert(0, 0);
  }
  return [0x02, bytes.length, ...bytes];
}

/// Generates a P-256 key pair.
pc.AsymmetricKeyPair<pc.ECPublicKey, pc.ECPrivateKey> generateP256KeyPair() {
  final random = Random.secure();
  final secureRandom = pc.FortunaRandom()
    ..seed(
      pc.KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
      ),
    );
  final generator = pc.ECKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.ECKeyGeneratorParameters(pc.ECCurve_secp256r1()),
        secureRandom,
      ),
    );
  return generator.generateKeyPair();
}

/// Verifies an SSH-encoded signature the way a server would.
bool verifySshSignature({
  required Uint8List publicKeyBlob,
  required Uint8List data,
  required Uint8List signature,
}) =>
    SSHEcdsaPublicKey.decode(publicKeyBlob)
        .verify(data, SSHEcdsaSignature.decode(signature));

/// One `sign` request seen by [FakeHardwareKeyPlatform].
typedef FakeSignRequest = ({
  String alias,
  Uint8List data,
  String reason,
  String requestId,
});

/// In-memory [HardwareKeyPlatform] with real P-256 keys.
class FakeHardwareKeyPlatform implements HardwareKeyPlatform {
  /// Keys by alias.
  final keys =
      <String, pc.AsymmetricKeyPair<pc.ECPublicKey, pc.ECPrivateKey>>{};

  /// Capability map returned to the service.
  Map<Object?, Object?> capabilities = const {
    'available': true,
    'backing': 'secureEnclave',
    'userPresenceAvailable': true,
  };

  /// Backing reported for generated keys.
  HardwareKeyBacking backing = HardwareKeyBacking.secureEnclave;

  /// Thrown by [generateKey] when set.
  HardwareKeyException? generateError;

  /// Thrown by [sign] when set, after any held prompt resolves.
  HardwareKeyException? signError;

  /// Public point returned by [generateKey] instead of the real one.
  Uint8List? publicPointOverride;

  /// Holds each [sign] until [approve] or [cancelSign], like a biometric
  /// prompt waiting for the user.
  bool holdSigns = false;

  /// Every sign request, in order.
  final signRequests = <FakeSignRequest>[];

  /// Request IDs passed to [cancelSign].
  final cancelledRequests = <String>[];

  /// Aliases passed to [deleteKey].
  final deletedAliases = <String>[];

  final _heldPrompts = <String, Completer<void>>{};

  /// Request IDs of prompts still waiting for the user.
  Iterable<String> get heldRequestIds => _heldPrompts.keys;

  /// Waits until a held prompt is showing and returns its request ID.
  Future<String> waitForPrompt() async {
    for (var attempt = 0; attempt < 1000; attempt++) {
      if (_heldPrompts.isNotEmpty) {
        return _heldPrompts.keys.last;
      }
      await Future<void>.delayed(Duration.zero);
    }
    throw StateError('No hardware key prompt appeared');
  }

  /// Lets the held prompt for [requestId] sign.
  void approve(String requestId) => _heldPrompts.remove(requestId)?.complete();

  @override
  Future<Map<Object?, Object?>> getCapabilities() async => capabilities;

  @override
  Future<HardwareKeyGenerationResult> generateKey({
    required String alias,
    required bool requireUserPresence,
  }) async {
    final error = generateError;
    if (error != null) {
      throw error;
    }
    final pair = generateP256KeyPair();
    keys[alias] = pair;
    return (
      publicKey: publicPointOverride ?? pair.publicKey.Q!.getEncoded(false),
      backing: backing,
      isEmulated: false,
    );
  }

  @override
  Future<Uint8List> sign({
    required String alias,
    required Uint8List data,
    required String reason,
    required String requestId,
  }) async {
    signRequests.add((
      alias: alias,
      data: data,
      reason: reason,
      requestId: requestId,
    ));
    if (holdSigns) {
      final prompt = Completer<void>();
      _heldPrompts[requestId] = prompt;
      await prompt.future;
    }
    final error = signError;
    if (error != null) {
      throw error;
    }
    final pair = keys[alias];
    if (pair == null) {
      throw const HardwareKeyException(HardwareKeyErrorCode.keyNotFound);
    }
    return derSignP256(pair.privateKey, data);
  }

  @override
  Future<void> cancelSign(String requestId) async {
    cancelledRequests.add(requestId);
    _heldPrompts
        .remove(requestId)
        ?.completeError(
          const HardwareKeyException(HardwareKeyErrorCode.cancelled),
        );
  }

  @override
  Future<void> deleteKey(String alias) async {
    deletedAliases.add(alias);
    keys.remove(alias);
  }
}

/// A hardware key stored in [platform] and its encoded reference.
Future<GeneratedHardwareKey> generateFakeHardwareKey(
  FakeHardwareKeyPlatform platform, {
  bool requireUserPresence = false,
}) => HardwareKeyService(
  platform: platform,
  isPlatformSupported: true,
).generate(requireUserPresence: requireUserPresence);

/// The OpenSSH public-key line for a hardware key blob.
String openSshPublicKeyLine(Uint8List blob) =>
    '$hardwareKeyAlgorithm ${base64Encode(blob)}';

/// A stored hardware-backed [SshKey] for widget tests.
SshKey hardwareSshKeyFixture({
  int id = 1,
  String name = 'Phone key',
  HardwareKeyBacking backing = HardwareKeyBacking.secureEnclave,
  bool requireUserPresence = false,
}) {
  final blob = encodeEcdsaP256PublicKeyBlob(
    Uint8List.fromList([0x04, ...List.filled(64, id)]),
  );
  return SshKey(
    id: id,
    name: name,
    keyType: hardwareKeyAlgorithm,
    publicKey: openSshPublicKeyLine(blob),
    privateKey: HardwareKeyReference(
      alias: 'xyz.depollsoft.monkeyssh.sshkey.test$id',
      backing: backing,
      publicKeyBlob: blob,
      requiresUserPresence: requireUserPresence,
    ).encode(),
    fingerprint: 'SHA256:hardware$id',
    createdAt: DateTime(2026),
  );
}
