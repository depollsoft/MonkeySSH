import 'dart:math';

import 'dart:typed_data';

final _secureRandom = Random.secure();
const _randomPoolSize = 4096;
final _randomPool = Uint8List(_randomPoolSize);
var _randomPoolOffset = _randomPoolSize;

void _refillRandomPool() {
  for (var i = 0; i < _randomPoolSize; i += 4) {
    final word = _secureRandom.nextInt(0x100000000);
    _randomPool[i] = word & 0xff;
    _randomPool[i + 1] = (word >>> 8) & 0xff;
    _randomPool[i + 2] = (word >>> 16) & 0xff;
    _randomPool[i + 3] = (word >>> 24) & 0xff;
  }
  _randomPoolOffset = 0;
}

/// Fills [target] from [offset] for [length] bytes with cryptographically
/// secure random bytes drawn from a batched CSPRNG pool.
void fillRandomBytes(Uint8List target, int offset, int length) {
  var written = 0;
  while (written < length) {
    if (_randomPoolOffset >= _randomPoolSize) {
      _refillRandomPool();
    }
    final available = _randomPoolSize - _randomPoolOffset;
    final take = (length - written) < available ? (length - written) : available;
    target.setRange(
      offset + written,
      offset + written + take,
      _randomPool,
      _randomPoolOffset,
    );
    _randomPoolOffset += take;
    written += take;
  }
}

Uint8List randomBytes(int length) {
  final bytes = Uint8List(length);
  fillRandomBytes(bytes, 0, length);
  return bytes;
}

extension ListX<T> on List<T> {
  bool equals(List<T> other) {
    if (other.length != length) return false;
    for (int i = 0; i < length; i++) {
      if (this[i] != other[i]) return false;
    }
    return true;
  }
}

/// Compares [a] and [b] for equality without leaking timing information
/// about the contents of either list.
///
/// Every byte is XORed and accumulated with a bitwise OR; there is a single
/// comparison at the end and no data-dependent branch or early return based
/// on byte contents, unlike [ListX.equals]. Intended for comparing secret
/// values such as MACs, where an early-exit comparison lets an attacker
/// learn how many leading bytes of their guess were correct from response
/// timing.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
