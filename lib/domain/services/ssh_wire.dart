import 'dart:convert';
import 'dart:typed_data';

/// Reads a big-endian SSH `uint32` at [offset].
int readSshUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Reads a length-prefixed SSH `string` at [offset] as a view of [bytes].
///
/// Returns `null` when the length prefix or the payload is truncated.
Uint8List? readSshString(Uint8List bytes, int offset) {
  if (bytes.length - offset < 4) {
    return null;
  }

  final length = readSshUint32(bytes, offset);
  final start = offset + 4;
  final end = start + length;
  if (length < 0 || end > bytes.length) {
    return null;
  }

  return Uint8List.sublistView(bytes, start, end);
}

/// Reads the leading key-type string of an SSH public-key [blob].
///
/// Returns `null` when the type is missing, empty, truncated, or not UTF-8.
String? readSshHostKeyType(Uint8List? blob) {
  if (blob == null) {
    return null;
  }
  final typeBytes = readSshString(blob, 0);
  if (typeBytes == null || typeBytes.isEmpty) {
    return null;
  }

  try {
    return utf8.decode(typeBytes);
  } on FormatException {
    return null;
  }
}

/// Returns whether [blob] starts with an RSA, Ed25519, or ECDSA key type.
bool looksLikeSshHostKeyBlob(Uint8List blob) {
  final type = readSshHostKeyType(blob);
  return type != null &&
      (type == 'ssh-rsa' ||
          type == 'ssh-ed25519' ||
          type.startsWith('ecdsa-sha2-'));
}
