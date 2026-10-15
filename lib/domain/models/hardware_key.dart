import 'dart:convert';
import 'dart:typed_data';

/// Secure hardware that holds a non-exportable SSH private key.
enum HardwareKeyBacking {
  /// Apple Secure Enclave (iPhone and iPad).
  secureEnclave('secureEnclave', 'Secure Enclave'),

  /// Android StrongBox: a dedicated secure element.
  strongBox('strongBox', 'StrongBox'),

  /// Android Keystore in the trusted execution environment.
  tee('tee', 'TEE');

  const HardwareKeyBacking(this.wireName, this.label);

  /// Name used on the platform channel and in stored references.
  final String wireName;

  /// Short user-facing name.
  final String label;

  /// Parses a [wireName], returning `null` for unknown values.
  static HardwareKeyBacking? fromWireName(Object? name) {
    for (final backing in values) {
      if (backing.wireName == name) {
        return backing;
      }
    }
    return null;
  }
}

/// Why this device cannot generate a hardware-backed key.
enum HardwareKeyUnavailableReason {
  /// The iOS Simulator has no Secure Enclave.
  simulator('simulator'),

  /// An Android emulator whose keystore keeps keys in software.
  emulator('emulator'),

  /// The device has no Secure Enclave or secure keystore.
  noSecureHardware('noSecureHardware'),

  /// The keystore only produced software-backed keys.
  softwareKeystoreOnly('softwareKeystoreOnly'),

  /// The OS version predates the hardware keystore APIs the app needs.
  osTooOld('osTooOld'),

  /// Hardware-backed keys are not built for this platform.
  unsupportedPlatform('unsupportedPlatform'),

  /// The capability check itself failed.
  checkFailed('checkFailed');

  const HardwareKeyUnavailableReason(this.wireName);

  /// Name used on the platform channel.
  final String wireName;

  /// Parses a [wireName], defaulting to [checkFailed].
  static HardwareKeyUnavailableReason fromWireName(Object? name) {
    for (final reason in values) {
      if (reason.wireName == name) {
        return reason;
      }
    }
    return checkFailed;
  }

  /// Plain explanation shown in place of the generate action.
  String get message => switch (this) {
    simulator =>
      'The iOS Simulator has no Secure Enclave. Generate this key on a '
          'physical iPhone or iPad, or use an Ed25519 key here.',
    emulator =>
      'This emulator keeps keystore keys in software, so it can’t hold a '
          'hardware-backed key. Use a physical Android device, or an Ed25519 '
          'key here.',
    noSecureHardware =>
      'This device has no secure hardware for SSH keys. Use an Ed25519 key '
          'instead.',
    softwareKeystoreOnly =>
      'This device’s keystore only offers software-backed keys, which this '
          'option doesn’t accept. Use an Ed25519 key instead.',
    osTooOld =>
      'Hardware-backed keys need Android 6 or later. Use an Ed25519 key '
          'instead.',
    unsupportedPlatform =>
      'Hardware-backed keys are available on iPhone, iPad and Android.',
    checkFailed =>
      'Couldn’t check this device’s secure hardware. Try again, or use an '
          'Ed25519 key.',
  };
}

/// What the device's secure hardware can do for SSH keys.
class HardwareKeyCapabilities {
  /// Capabilities of a device that can generate a hardware-backed key.
  const HardwareKeyCapabilities.available({
    required HardwareKeyBacking this.backing,
    required this.userPresenceAvailable,
    this.userPresenceAllowsPasscode = true,
    this.isEmulator = false,
    this.strongBoxAvailable = false,
  }) : unavailableReason = null;

  /// Capabilities of a device that cannot generate a hardware-backed key.
  const HardwareKeyCapabilities.unavailable(
    HardwareKeyUnavailableReason this.unavailableReason,
  ) : backing = null,
      userPresenceAvailable = false,
      userPresenceAllowsPasscode = false,
      isEmulator = false,
      strongBoxAvailable = false;

  /// Parses the platform channel's capability map.
  factory HardwareKeyCapabilities.fromMap(Map<Object?, Object?> map) {
    final backing = HardwareKeyBacking.fromWireName(map['backing']);
    if (map['available'] != true || backing == null) {
      return HardwareKeyCapabilities.unavailable(
        HardwareKeyUnavailableReason.fromWireName(map['reason']),
      );
    }
    return HardwareKeyCapabilities.available(
      backing: backing,
      userPresenceAvailable: map['userPresenceAvailable'] == true,
      userPresenceAllowsPasscode: map['userPresenceAllowsPasscode'] != false,
      isEmulator: map['isEmulator'] == true,
      strongBoxAvailable: map['strongBoxAvailable'] == true,
    );
  }

  /// Hardware a new key would be generated in, or `null` when unavailable.
  final HardwareKeyBacking? backing;

  /// Why no hardware-backed key can be generated, when [backing] is `null`.
  final HardwareKeyUnavailableReason? unavailableReason;

  /// Whether per-use biometric or passcode confirmation can be required.
  final bool userPresenceAvailable;

  /// Whether per-use confirmation accepts the screen lock, not only a
  /// biometric (false on Android 10 and earlier).
  final bool userPresenceAllowsPasscode;

  /// Whether the app runs on an emulator whose keystore is itself emulated.
  final bool isEmulator;

  /// Whether the device advertises a StrongBox secure element.
  final bool strongBoxAvailable;

  /// Whether a hardware-backed key can be generated.
  bool get isAvailable => backing != null;
}

/// Pointer to a key held in secure hardware.
///
/// Stored in the SSH key row's private-key column in place of key material.
/// It names the keystore alias, carries the public key, and records how the
/// key was created; it is useless on any other device, and it is never
/// exported.
class HardwareKeyReference {
  /// Creates a [HardwareKeyReference].
  const HardwareKeyReference({
    required this.alias,
    required this.backing,
    required this.publicKeyBlob,
    required this.requiresUserPresence,
    this.userPresenceAllowsPasscode = true,
    this.isEmulated = false,
  });

  /// Marker that starts every encoded reference.
  static const prefix = 'monkeyssh-hardware-key-v1:';

  /// Keystore alias (Android) or keychain application tag (iOS).
  final String alias;

  /// Secure hardware that holds the private key.
  final HardwareKeyBacking backing;

  /// OpenSSH `ecdsa-sha2-nistp256` public-key blob.
  final Uint8List publicKeyBlob;

  /// Whether every signature needs biometric or passcode confirmation.
  final bool requiresUserPresence;

  /// Whether that confirmation accepts the screen lock, not only a
  /// biometric (false for Android 10 and earlier).
  final bool userPresenceAllowsPasscode;

  /// Whether the key was generated in an emulator's simulated keystore.
  final bool isEmulated;

  /// Whether [value] is a stored hardware key reference, even a damaged one.
  static bool looksLikeReference(String? value) =>
      value != null && value.startsWith(prefix);

  /// Reads only the keystore alias of a stored reference, however damaged
  /// the rest is, so cleanup can still find the key.
  static String? tryParseAlias(String? value) {
    if (!looksLikeReference(value)) {
      return null;
    }
    try {
      final decoded = jsonDecode(value!.substring(prefix.length));
      final alias = decoded is Map ? decoded['alias'] : null;
      return alias is String && alias.isNotEmpty ? alias : null;
    } on FormatException {
      return null;
    }
  }

  /// Parses an encoded reference, returning `null` when [value] is not one.
  static HardwareKeyReference? tryParse(String? value) {
    if (!looksLikeReference(value)) {
      return null;
    }
    try {
      final decoded = jsonDecode(value!.substring(prefix.length));
      if (decoded is! Map) {
        return null;
      }
      final alias = decoded['alias'];
      final backing = HardwareKeyBacking.fromWireName(decoded['backing']);
      final publicKey = decoded['publicKey'];
      if (alias is! String ||
          alias.isEmpty ||
          backing == null ||
          publicKey is! String) {
        return null;
      }
      final publicKeyBlob = base64Decode(publicKey);
      if (publicKeyBlob.isEmpty) {
        return null;
      }
      return HardwareKeyReference(
        alias: alias,
        backing: backing,
        publicKeyBlob: publicKeyBlob,
        requiresUserPresence: decoded['userPresence'] == true,
        userPresenceAllowsPasscode: decoded['passcode'] != false,
        isEmulated: decoded['emulated'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  /// Encodes this reference for storage.
  String encode() {
    final fields = {
      'alias': alias,
      'backing': backing.wireName,
      'publicKey': base64Encode(publicKeyBlob),
      'userPresence': requiresUserPresence,
      if (requiresUserPresence && !userPresenceAllowsPasscode)
        'passcode': false,
      if (isEmulated) 'emulated': true,
    };
    return '$prefix${jsonEncode(fields)}';
  }

  /// Label for the backing, noting an emulated keystore.
  String get backingLabel =>
      isEmulated ? '${backing.label} (emulator)' : backing.label;
}
