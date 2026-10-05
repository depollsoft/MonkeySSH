import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage that keeps iOS keychain items at
/// `first_unlock_this_device` accessibility.
///
/// Items written by older builds with the default accessibility are read
/// through a fallback and rewritten under the hardened accessibility. Other
/// platforms use [FlutterSecureStorage] unchanged.
class HardenedKeychainStore {
  /// Creates a store backed by [storage], or the hardened default.
  const HardenedKeychainStore([FlutterSecureStorage? storage])
    : _storage = storage ?? _defaultStorage;

  final FlutterSecureStorage _storage;

  static const _errSecDuplicateItem = -25299;
  static const _hardenedIosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _legacyIosOptions = IOSOptions.defaultOptions;
  static const _defaultStorage = FlutterSecureStorage(
    iOptions: _hardenedIosOptions,
  );

  /// Reads [key], migrating an iOS item stored with legacy accessibility.
  Future<String?> read(String key) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return _storage.read(key: key);
    }

    String? current;
    try {
      current = await _storage.read(key: key, iOptions: _hardenedIosOptions);
    } on PlatformException {
      final legacy = await _readLegacy(key);
      if (legacy != null) {
        return legacy;
      }
      rethrow;
    }
    return current ?? _readLegacy(key);
  }

  /// Writes [value] for [key] with hardened iOS accessibility.
  Future<void> write(String key, String value) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return _storage.write(key: key, value: value);
    }
    return _storage.write(
      key: key,
      value: value,
      iOptions: _hardenedIosOptions,
    );
  }

  Future<String?> _readLegacy(String key) async {
    final legacy = await _storage.read(key: key, iOptions: _legacyIosOptions);
    if (legacy == null) {
      return null;
    }
    try {
      await write(key, legacy);
    } on PlatformException catch (error) {
      if (!_isDuplicateKeychainItem(error)) {
        rethrow;
      }
      await _storage.delete(key: key, iOptions: _legacyIosOptions);
      await write(key, legacy);
    }
    return legacy;
  }

  static bool _isDuplicateKeychainItem(PlatformException error) =>
      error.details == _errSecDuplicateItem ||
      error.details == _errSecDuplicateItem.toString() ||
      (error.message?.contains(_errSecDuplicateItem.toString()) ?? false) ||
      (error.message?.contains('already exists') ?? false);
}
