import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// HKDF info string pinned by `docs/push-notifications.md`.
const pushPayloadInfo = 'monkeyssh-push-v1';

const _keyBytes = 32;
const _nonceBytes = 12;
const _tagBytes = 16;
const _hostRefLength = 16;
final _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]*$');

/// Encodes [bytes] as unpadded base64url.
String encodePushBase64(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes strict unpadded base64url, returning null for anything else.
Uint8List? decodePushBase64(String value) {
  if (!_base64UrlPattern.hasMatch(value) || value.length % 4 == 1) {
    return null;
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

/// A device's X25519 key pair. The seed never leaves secure storage.
@immutable
class PushDeviceKeyPair {
  /// Creates a key pair from its raw parts.
  const PushDeviceKeyPair({required this.seed, required this.publicKey});

  /// The 32-byte private seed.
  final Uint8List seed;

  /// The 32-byte public key.
  final Uint8List publicKey;

  /// The public key as hosts receive it.
  String get encodedPublicKey => encodePushBase64(publicKey);
}

final _x25519 = X25519();

/// Derives the key pair for a stored [seed].
Future<PushDeviceKeyPair> pushDeviceKeyPairFromSeed(List<int> seed) async {
  if (seed.length != _keyBytes) {
    throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  }
  final keyPair = await _x25519.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return PushDeviceKeyPair(
    seed: Uint8List.fromList(seed),
    publicKey: Uint8List.fromList(publicKey.bytes),
  );
}

/// Creates a new device key pair from a secure random seed.
Future<PushDeviceKeyPair> generatePushDeviceKeyPair({Random? random}) {
  final source = random ?? Random.secure();
  return pushDeviceKeyPairFromSeed(
    List<int>.generate(_keyBytes, (_) => source.nextInt(256)),
  );
}

/// Creates the random key behind host references.
Uint8List generatePushHostRefKey({Random? random}) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(_keyBytes, (_) => source.nextInt(256)),
  );
}

/// Derives the opaque reference a host carries for [hostId].
Future<String> derivePushHostRef({
  required List<int> hostRefKey,
  required int hostId,
}) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode('host:$hostId'),
    secretKey: SecretKey(hostRefKey),
  );
  return encodePushBase64(mac.bytes).substring(0, _hostRefLength);
}

Future<SecretKey> _payloadKey({
  required List<int> devicePrivateSeed,
  required List<int> devicePublicKey,
  required List<int> ephemeralPublicKey,
}) async {
  final keyPair = await _x25519.newKeyPairFromSeed(devicePrivateSeed);
  final shared = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(
      ephemeralPublicKey,
      type: KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();
  // A low-order ephemeral key forces an all-zero secret; refuse it.
  if (sharedBytes.every((byte) => byte == 0)) {
    throw const FormatException('degenerate shared secret');
  }
  return Hkdf(hmac: Hmac.sha256(), outputLength: _keyBytes).deriveKey(
    secretKey: SecretKey(sharedBytes),
    nonce: <int>[...ephemeralPublicKey, ...devicePublicKey],
    info: utf8.encode(pushPayloadInfo),
  );
}

/// Opens a host's payload with the device key, or returns null when it was
/// not sealed to this device, was altered, or is malformed.
Future<Uint8List?> openPushPayload({
  required PushDeviceKeyPair device,
  required String payload,
}) async {
  final sealed = decodePushBase64(payload);
  if (sealed == null || sealed.length <= _keyBytes + _nonceBytes + _tagBytes) {
    return null;
  }
  try {
    final ephemeralPublic = sealed.sublist(0, _keyBytes);
    final key = await _payloadKey(
      devicePrivateSeed: device.seed,
      devicePublicKey: device.publicKey,
      ephemeralPublicKey: ephemeralPublic,
    );
    final cipherEnd = sealed.length - _tagBytes;
    final plaintext = await AesGcm.with256bits().decrypt(
      SecretBox(
        sealed.sublist(_keyBytes + _nonceBytes, cipherEnd),
        nonce: sealed.sublist(_keyBytes, _keyBytes + _nonceBytes),
        mac: Mac(sealed.sublist(cipherEnd)),
      ),
      secretKey: key,
    );
    return Uint8List.fromList(plaintext);
  } on SecretBoxAuthenticationError {
    return null;
  } on FormatException {
    return null;
  }
}

/// Seals [plaintext] the way MonkeyMux does, with caller-chosen randomness.
///
/// The app never sends payloads; this exists so tests can check the format
/// against the shared vectors.
@visibleForTesting
Future<String> sealPushPayloadForTesting({
  required List<int> devicePublicKey,
  required List<int> plaintext,
  required List<int> ephemeralSeed,
  required List<int> nonce,
}) async {
  final ephemeral = await pushDeviceKeyPairFromSeed(ephemeralSeed);
  final keyPair = await _x25519.newKeyPairFromSeed(ephemeralSeed);
  final shared = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(devicePublicKey, type: KeyPairType.x25519),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: _keyBytes)
      .deriveKey(
        secretKey: SecretKey(await shared.extractBytes()),
        nonce: <int>[...ephemeral.publicKey, ...devicePublicKey],
        info: utf8.encode(pushPayloadInfo),
      );
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
  );
  return encodePushBase64(<int>[
    ...ephemeral.publicKey,
    ...nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}
