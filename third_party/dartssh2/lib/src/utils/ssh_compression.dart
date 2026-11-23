import 'dart:typed_data';

import 'package:dartssh2/src/algorithm/ssh_compression_type.dart';
import 'package:dartssh2/src/utils/ssh_compression_stub.dart'
    if (dart.library.io) 'package:dartssh2/src/utils/ssh_compression_io.dart'
    as impl;

/// Default compression preference list for the current platform.
///
/// On `dart:io` platforms, native C zlib (`RawZLibFilter`) is available, so
/// `zlib@openssh.com` is advertised ahead of `none`. On web, only `none` is
/// advertised.
List<SSHCompressionType> get defaultSSHCompressionAlgorithms =>
    impl.defaultCompressionAlgorithms;

/// Stateful per-packet zlib compressor (RFC 4253 §6.2 / `zlib@openssh.com`).
abstract class SSHPacketCompressor {
  /// Compresses one SSH packet payload and flushes (`Z_SYNC_FLUSH`).
  Uint8List compress(Uint8List payload);

  /// Releases native resources if any.
  void close() {}
}

/// Stateful per-packet zlib decompressor (RFC 4253 §6.2 / `zlib@openssh.com`).
abstract class SSHPacketDecompressor {
  /// Decompresses one SSH packet payload, enforcing [maxDecompressedBytes] to
  /// protect against zip-bomb packets.
  Uint8List decompress(Uint8List compressed, {int maxDecompressedBytes});

  /// Releases native resources if any.
  void close() {}
}

/// Creates a compressor for [type], or returns `null` for [SSHCompressionType.none].
SSHPacketCompressor? createSSHPacketCompressor(SSHCompressionType type) =>
    impl.createCompressor(type);

/// Creates a decompressor for [type], or returns `null` for [SSHCompressionType.none].
SSHPacketDecompressor? createSSHPacketDecompressor(SSHCompressionType type) =>
    impl.createDecompressor(type);
