import '../security/secret_encryption_service.dart';

/// Bounded ciphertext-keyed LRU cache, invalidated across asynchronous work.
class PlaintextCache {
  /// Creates an independent cache for a repository.
  PlaintextCache(this._encryption);

  final SecretEncryptionService _encryption;
  final _entries = <String, String>{};

  /// Changes whenever plaintext is cleared.
  int get generation => _generation;
  int _generation = 0;

  /// Number of retained plaintexts.
  int get length => _entries.length;

  /// Clears plaintext and rejects insertions from earlier operations.
  void clear() {
    _generation++;
    _entries.clear();
  }

  /// Removes a stored ciphertext, if present.
  void remove(String? ciphertext) => _entries.remove(ciphertext);

  /// Looks up plaintext and marks a cache hit as most recently used.
  String? lookup(String ciphertext) {
    final hit = _entries.remove(ciphertext);
    if (hit != null) {
      _entries[ciphertext] = hit;
    }
    return hit;
  }

  /// Decrypts a value, retaining it only while the operation is still current.
  Future<String?> decrypt(String ciphertext, int generation) async {
    final hit = lookup(ciphertext);
    if (hit != null) return hit;
    final plaintext = await _encryption.decryptNullable(ciphertext);
    remember(ciphertext, plaintext, generation);
    return plaintext;
  }

  /// Admits nonempty plaintext from a current decrypt, migration, or write.
  void remember(
    String? ciphertext,
    String? plaintext,
    int generation, {
    bool isWrite = false,
  }) {
    if (generation != _generation ||
        ciphertext == null ||
        ciphertext.isEmpty ||
        plaintext == null ||
        plaintext.isEmpty ||
        (isWrite && _encryption.isEncryptedValue(plaintext))) {
      return;
    }
    _entries.remove(ciphertext);
    _entries[ciphertext] = plaintext;
    while (_entries.length > 512) {
      _entries.remove(_entries.keys.first);
    }
  }
}
