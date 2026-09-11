import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service that encrypts and decrypts sensitive values stored in SQLite.
class SecretEncryptionService {
  /// Creates a new [SecretEncryptionService].
  SecretEncryptionService({FlutterSecureStorage? storage, Random? random})
    : _storage = storage ?? _secureStorage,
      _random = random ?? Random.secure(),
      _testingMasterKey = null;

  /// Creates a [SecretEncryptionService] configured for tests.
  SecretEncryptionService.forTesting({List<int>? masterKey, Random? random})
    : _storage = null,
      _random = random ?? Random(1),
      _testingMasterKey = masterKey ?? SecretKeyData.random(length: 32).bytes;

  final FlutterSecureStorage? _storage;
  final AesGcm _algorithm = AesGcm.with256bits();
  final Random _random;
  final List<int>? _testingMasterKey;

  static const _legacyMasterKeyStorageEntry =
      'flutty_db_'
      'secret'
      '_key_v1';
  static const _masterKeyStorageEntry = 'flutty_db_encryption_key_v1';
  static const _encryptedPrefix = 'ENCv1:';
  static const _masterKeyBytes = 32;
  static const _nonceBytes = 12;
  static const _errSecDuplicateItem = -25299;
  static const _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _hardenedIosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _legacyIosOptions = IOSOptions.defaultOptions;

  SecretKey? _cachedMasterKey;
  Future<void> _masterKeyQueue = Future<void>.value();

  /// Returns whether [value] is already in encrypted envelope format.
  bool isEncryptedValue(String value) => value.startsWith(_encryptedPrefix);

  /// Returns whether [value] is a structurally valid encrypted envelope.
  bool isValidEncryptedEnvelope(String value) {
    if (!isEncryptedValue(value)) return false;
    try {
      _decodeEnvelope(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Encrypts an optional value for database persistence.
  Future<String?> encryptNullable(String? plaintext) async {
    if (plaintext == null || plaintext.isEmpty) {
      return plaintext;
    }
    if (isValidEncryptedEnvelope(plaintext)) {
      return plaintext;
    }

    final secretKey = await _getOrCreateMasterKey();
    final nonce = _randomBytes(_nonceBytes);
    final ciphertext = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    final envelope = {
      'n': base64Url.encode(nonce),
      'c': base64Url.encode(ciphertext.cipherText),
      'm': base64Url.encode(ciphertext.mac.bytes),
    };
    return '$_encryptedPrefix${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
  }

  /// Encrypts a required value for database persistence.
  Future<String> encryptRequired(String plaintext) async =>
      (await encryptNullable(plaintext)) ?? '';

  /// Decrypts an optional value loaded from database persistence.
  Future<String?> decryptNullable(String? storedValue) async {
    if (storedValue == null || storedValue.isEmpty) {
      return storedValue;
    }
    final secretBox = _decodeEnvelope(storedValue);
    final secretKey = await _getOrCreateMasterKey();
    try {
      final plainTextBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return utf8.decode(plainTextBytes);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Invalid encrypted value');
    }
  }

  SecretBox _decodeEnvelope(String value) {
    if (!isEncryptedValue(value)) {
      throw const FormatException('Unexpected plaintext secret value');
    }
    final compact = value.substring(_encryptedPrefix.length);
    final envelopeJson = utf8.decode(
      base64Url.decode(base64Url.normalize(compact)),
    );
    final decodedEnvelope = jsonDecode(envelopeJson);
    if (decodedEnvelope is! Map) {
      throw const FormatException('Invalid encrypted value envelope');
    }
    final envelope = Map<String, dynamic>.from(decodedEnvelope);
    final nonce = _decodeEnvelopeField(envelope, 'n');
    final cipherText = _decodeEnvelopeField(envelope, 'c');
    final mac = _decodeEnvelopeField(envelope, 'm');
    if (nonce.length != _nonceBytes || mac.length != 16) {
      throw const FormatException('Invalid encrypted value envelope');
    }
    return SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  }

  Future<SecretKey> _getOrCreateMasterKey() async {
    if (_cachedMasterKey != null) {
      return _cachedMasterKey!;
    }

    if (_testingMasterKey != null) {
      _cachedMasterKey = SecretKey(List<int>.unmodifiable(_testingMasterKey));
      return _cachedMasterKey!;
    }

    final storage = _storage;
    if (storage == null) {
      throw StateError('Secure storage is not available for secret encryption');
    }

    await _withMasterKeyLock(() async {
      if (_cachedMasterKey != null) {
        return;
      }

      final existing = await _readStorageValue(storage, _masterKeyStorageEntry);
      if (existing != null) {
        final decoded = base64Decode(existing);
        if (decoded.length != _masterKeyBytes) {
          throw const FormatException('Invalid secret encryption key');
        }
        _cachedMasterKey = SecretKey(decoded);
        return;
      }

      final legacyExisting = await _readStorageValue(
        storage,
        _legacyMasterKeyStorageEntry,
      );
      if (legacyExisting != null) {
        final decoded = base64Decode(legacyExisting);
        if (decoded.length != _masterKeyBytes) {
          throw const FormatException('Invalid secret encryption key');
        }
        await _writeStorageValue(
          storage,
          key: _masterKeyStorageEntry,
          value: legacyExisting,
        );
        _cachedMasterKey = SecretKey(decoded);
        return;
      }

      final generated = SecretKeyData.random(length: _masterKeyBytes).bytes;
      await _writeStorageValue(
        storage,
        key: _masterKeyStorageEntry,
        value: base64Encode(generated),
      );
      _cachedMasterKey = SecretKey(generated);
    });

    return _cachedMasterKey!;
  }

  Future<void> _withMasterKeyLock(Future<void> Function() action) {
    final operation = _masterKeyQueue.then((_) => action());
    _masterKeyQueue = operation.catchError((_) {});
    return operation;
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256), growable: false);

  Future<String?> _readStorageValue(
    FlutterSecureStorage storage,
    String key,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return storage.read(key: key);
    }

    String? current;
    try {
      current = await storage.read(key: key, iOptions: _hardenedIosOptions);
    } on PlatformException {
      final legacy = await storage.read(key: key, iOptions: _legacyIosOptions);
      if (legacy != null) {
        await _migrateStorageValue(storage, key: key, value: legacy);
        return legacy;
      }
      rethrow;
    }
    if (current != null) return current;

    final legacy = await storage.read(key: key, iOptions: _legacyIosOptions);
    if (legacy != null) {
      await _migrateStorageValue(storage, key: key, value: legacy);
    }
    return legacy;
  }

  Future<void> _migrateStorageValue(
    FlutterSecureStorage storage, {
    required String key,
    required String value,
  }) async {
    try {
      await _writeStorageValue(storage, key: key, value: value);
    } on PlatformException catch (error) {
      if (!_isDuplicateKeychainItem(error)) {
        rethrow;
      }
      await storage.delete(key: key, iOptions: _legacyIosOptions);
      await _writeStorageValue(storage, key: key, value: value);
    }
  }

  Future<void> _writeStorageValue(
    FlutterSecureStorage storage, {
    required String key,
    required String value,
  }) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return storage.write(key: key, value: value);
    }
    return storage.write(key: key, value: value, iOptions: _hardenedIosOptions);
  }

  bool _isDuplicateKeychainItem(PlatformException error) =>
      error.details == _errSecDuplicateItem ||
      error.details == _errSecDuplicateItem.toString() ||
      (error.message?.contains(_errSecDuplicateItem.toString()) ?? false) ||
      (error.message?.contains('already exists') ?? false);

  List<int> _decodeEnvelopeField(Map<String, dynamic> envelope, String key) {
    final value = envelope[key];
    if (value is! String || value.isEmpty) {
      throw const FormatException('Invalid encrypted value envelope');
    }
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('Invalid encrypted value envelope');
    }
  }
}

/// Provider for [SecretEncryptionService].
final secretEncryptionServiceProvider = Provider<SecretEncryptionService>(
  (ref) => SecretEncryptionService(),
);
