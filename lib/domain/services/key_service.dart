import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';
import '../models/hardware_key.dart';
import 'diagnostics_log_service.dart';
import 'hardware_key_service.dart';
import 'openssh_key_generator.dart';

/// Key type for SSH key generation.
enum SshKeyType {
  /// Ed25519 key (recommended).
  ed25519,

  /// RSA 2048-bit key.
  rsa2048,

  /// RSA 4096-bit key.
  rsa4096,
}

/// Service for SSH key management.
class KeyService {
  /// Creates a new [KeyService].
  KeyService(this._keyRepository, {HardwareKeyService? hardwareKeyService})
    : _hardwareKeyService = hardwareKeyService ?? HardwareKeyService();

  final KeyRepository _keyRepository;
  final HardwareKeyService _hardwareKeyService;

  /// Import a key from PEM content.
  Future<SshKey?> importKey({
    required String name,
    required String privateKeyPem,
    String? passphrase,
  }) async {
    try {
      // Parse the key to validate and extract public key
      final keyPairs = await parseOpenSshPrivateKey(privateKeyPem, passphrase);

      if (keyPairs.isEmpty) return null;

      return await _insertKey(
        name: name,
        privateKeyPem: privateKeyPem,
        publicKeyBlob: keyPairs.first.toPublicKey().encode(),
        passphrase: passphrase,
      );
    } on FormatException {
      return null;
    } on SSHError {
      // Malformed OpenSSH structure, or an encrypted key with a missing or
      // incorrect passphrase (SSHKeyDecryptError). Report as "unimportable"
      // so the UI shows its "invalid key / incorrect passphrase" message
      // instead of surfacing an uncaught error (SSHError is not an Exception).
      return null;
    }
  }

  /// Generate an SSH key pair in-process and store it.
  ///
  /// Works on every platform: the key is produced in pure Dart in the OpenSSH
  /// private-key format (optionally encrypted with [passphrase]), so no
  /// `ssh-keygen` binary is required on mobile.
  Future<SshKey?> generateKey({
    required String name,
    required SshKeyType keyType,
    String? passphrase,
  }) async {
    final normalizedPassphrase = (passphrase?.isEmpty ?? true)
        ? null
        : passphrase;

    final generated = await generateOpenSshKey(
      keyType: keyType,
      comment: name,
      passphrase: normalizedPassphrase,
    );

    return _insertKey(
      name: name,
      privateKeyPem: generated.privateKeyPem,
      publicKeyBlob: generated.publicKeyBlob,
      passphrase: normalizedPassphrase,
    );
  }

  /// Generate a non-exportable ECDSA P-256 key in secure hardware.
  ///
  /// Only the keystore alias and the public key are stored. When
  /// [requireUserPresence] is set, every signature needs biometric or
  /// passcode confirmation, so the key cannot sign in the background.
  Future<SshKey?> generateHardwareKey({
    required String name,
    required bool requireUserPresence,
  }) async {
    final generated = await _hardwareKeyService.generate(
      requireUserPresence: requireUserPresence,
    );
    try {
      return await _insertKey(
        name: name,
        privateKeyPem: generated.reference.encode(),
        publicKeyBlob: generated.publicKeyBlob,
      );
    } on Object {
      await _deleteHardwareKey(generated.reference.alias);
      rethrow;
    }
  }

  /// Delete [key], removing a hardware-backed private key from the device.
  ///
  /// The hardware key goes first, and the row only once it is gone, so a
  /// failure keeps the alias for a retry; deleting a missing key succeeds.
  /// Returns false, keeping the row, when secure hardware refused.
  Future<bool> deleteKey(SshKey key) async {
    // Only the alias matters for cleanup, so a reference damaged anywhere
    // else still removes its key. An alias the app could not have created
    // is never sent to the keystore, and its row is simply dropped.
    final alias = HardwareKeyReference.tryParseAlias(key.privateKey);
    if (alias != null &&
        alias.startsWith(hardwareKeyAliasPrefix) &&
        !await _deleteHardwareKey(alias)) {
      return false;
    }
    await _keyRepository.delete(key.id);
    return true;
  }

  Future<bool> _deleteHardwareKey(String alias) async {
    try {
      await _hardwareKeyService.deleteAlias(alias);
      return true;
    } on HardwareKeyException catch (error) {
      DiagnosticsLogService.instance.warning(
        'hardware_key',
        'delete_failed',
        fields: {'code': error.code.wireName},
      );
      return false;
    }
  }

  Future<SshKey?> _insertKey({
    required String name,
    required String privateKeyPem,
    required List<int> publicKeyBlob,
    String? passphrase,
  }) async {
    final keyType = _readPublicKeyAlgorithm(publicKeyBlob);
    final publicKey = '$keyType ${base64Encode(publicKeyBlob)}';
    final id = await _keyRepository.insert(
      SshKeysCompanion.insert(
        name: name,
        keyType: keyType,
        publicKey: publicKey,
        privateKey: privateKeyPem,
        passphrase: Value(passphrase),
        fingerprint: Value(computeOpenSshPublicKeyFingerprint(publicKey)),
      ),
    );
    return _keyRepository.getById(id);
  }

  /// Reads the algorithm name embedded at the start of an OpenSSH public-key
  /// blob (an SSH length-prefixed string), e.g. 'ssh-ed25519' or 'ssh-rsa'.
  String _readPublicKeyAlgorithm(List<int> publicKeyBlob) {
    if (publicKeyBlob.length < 4) return 'unknown';
    final length =
        (publicKeyBlob[0] << 24) |
        (publicKeyBlob[1] << 16) |
        (publicKeyBlob[2] << 8) |
        publicKeyBlob[3];
    if (length <= 0 || 4 + length > publicKeyBlob.length) return 'unknown';
    return ascii.decode(publicKeyBlob.sublist(4, 4 + length));
  }
}

/// Computes the OpenSSH SHA256 fingerprint for a public key string.
String computeOpenSshPublicKeyFingerprint(String publicKey) {
  final parts = publicKey.trim().split(RegExp(r'\s+'));
  if (parts.length < 2 || parts[1].isEmpty) {
    throw const FormatException('Invalid OpenSSH public key');
  }

  final publicKeyBlob = base64Decode(parts[1]);
  final digest = crypto.sha256.convert(publicKeyBlob).bytes;
  return 'SHA256:${base64Encode(digest).replaceAll('=', '')}';
}

/// Provider for [KeyService].
final keyServiceProvider = Provider<KeyService>(
  (ref) => KeyService(
    ref.watch(keyRepositoryProvider),
    hardwareKeyService: ref.watch(hardwareKeyServiceProvider),
  ),
);
