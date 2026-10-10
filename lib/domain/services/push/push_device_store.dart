import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../data/security/hardened_keychain_store.dart';
import 'push_crypto.dart';

/// Minimal secure key-value seam so tests can use memory.
abstract interface class PushSecretStore {
  /// Reads [key].
  Future<String?> read(String key);

  /// Writes [key].
  Future<void> write(String key, String value);

  /// Deletes [key].
  Future<void> delete(String key);
}

/// [PushSecretStore] backed by the platform keychain or keystore.
class SecurePushSecretStore implements PushSecretStore {
  /// Creates a store using the hardened keychain accessibility on iOS.
  const SecurePushSecretStore();

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _hardened = HardenedKeychainStore(_storage);

  @override
  Future<String?> read(String key) => _hardened.read(key);

  @override
  Future<void> write(String key, String value) => _hardened.write(key, value);

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _storage.delete(key: key, iOptions: IOSOptions.defaultOptions);
      } on PlatformException {
        // Nothing stored under the legacy accessibility.
      }
    }
  }
}

/// The secrets this device keeps for push notifications.
@immutable
class PushDeviceSecrets {
  /// Creates the secrets.
  const PushDeviceSecrets({
    required this.keyPair,
    required this.hostRefKey,
    this.deviceId,
    this.ticket,
    this.tokenFingerprint,
    this.ticketIssuedAt,
  });

  /// X25519 key pair payloads are sealed to.
  final PushDeviceKeyPair keyPair;

  /// Key that turns host ids into opaque references.
  final Uint8List hostRefKey;

  /// Device id the function assigned, once registered.
  final String? deviceId;

  /// Sealed ticket for hosts, once registered.
  final String? ticket;

  /// Hash of the FCM token the ticket seals, to notice refreshes.
  final String? tokenFingerprint;

  /// When the function issued [ticket]; tickets are renewed weekly.
  final DateTime? ticketIssuedAt;

  /// Whether the function has registered this device.
  bool get isRegistered => deviceId != null && ticket != null;

  /// Returns a copy with a new registration.
  PushDeviceSecrets withRegistration({
    required String deviceId,
    required String ticket,
    required String tokenFingerprint,
    required DateTime ticketIssuedAt,
  }) => PushDeviceSecrets(
    keyPair: keyPair,
    hostRefKey: hostRefKey,
    deviceId: deviceId,
    ticket: ticket,
    tokenFingerprint: tokenFingerprint,
    ticketIssuedAt: ticketIssuedAt,
  );
}

/// Persists [PushDeviceSecrets] as one secure-storage entry.
class PushDeviceStore {
  /// Creates a store over [secrets].
  PushDeviceStore({PushSecretStore secrets = const SecurePushSecretStore()})
    : _secrets = secrets;

  static const _entry = 'monkeyssh_push_device_v1';

  final PushSecretStore _secrets;

  /// Loads the stored secrets, or null when none exist or they are unreadable.
  Future<PushDeviceSecrets?> load() async {
    final raw = await _secrets.read(_entry);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> || decoded['v'] != 1) return null;
      String? text(String key) => switch (decoded[key]) {
        final String value when value.isNotEmpty => value,
        _ => null,
      };
      final seed = decodePushBase64(text('seed') ?? '');
      final hostRefKey = decodePushBase64(text('hostRefKey') ?? '');
      // A short host key would make host references predictable; treat the
      // record as unreadable so loadOrCreate makes a new one.
      if (seed == null ||
          seed.length != 32 ||
          hostRefKey == null ||
          hostRefKey.length != 32) {
        return null;
      }
      return PushDeviceSecrets(
        keyPair: await pushDeviceKeyPairFromSeed(seed),
        hostRefKey: hostRefKey,
        deviceId: text('deviceId'),
        ticket: text('ticket'),
        tokenFingerprint: text('tokenFingerprint'),
        ticketIssuedAt: switch (decoded['ticketIssuedAt']) {
          final int seconds when seconds > 0 && seconds < 1 << 40 =>
            DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
          _ => null,
        },
      );
    } on FormatException {
      return null;
    }
  }

  /// Loads the secrets, creating a fresh key pair and host key if needed.
  Future<PushDeviceSecrets> loadOrCreate() async {
    final existing = await load();
    if (existing != null) return existing;
    final created = PushDeviceSecrets(
      keyPair: await generatePushDeviceKeyPair(),
      hostRefKey: generatePushHostRefKey(),
    );
    await save(created);
    return created;
  }

  /// Saves [secrets].
  Future<void> save(PushDeviceSecrets secrets) => _secrets.write(
    _entry,
    jsonEncode(<String, Object?>{
      'v': 1,
      'seed': encodePushBase64(secrets.keyPair.seed),
      'hostRefKey': encodePushBase64(secrets.hostRefKey),
      'deviceId': ?secrets.deviceId,
      'ticket': ?secrets.ticket,
      'tokenFingerprint': ?secrets.tokenFingerprint,
      'ticketIssuedAt': ?switch (secrets.ticketIssuedAt) {
        final DateTime at => at.millisecondsSinceEpoch ~/ 1000,
        null => null,
      },
    }),
  );

  /// Deletes the device key, host key, device id and ticket.
  Future<void> clear() => _secrets.delete(_entry);
}
