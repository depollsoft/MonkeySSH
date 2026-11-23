import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/src/algorithm/ssh_compression_type.dart';
import 'package:dartssh2/src/ssh_errors.dart';
import 'package:dartssh2/src/utils/ssh_compression.dart';

/// Default compression list on `dart:io`: delayed zlib first, fallback to none.
const List<SSHCompressionType> defaultCompressionAlgorithms = [
  SSHCompressionType.zlibDelayed,
  SSHCompressionType.none,
];

/// OpenSSH's `PACKET_MAX_SIZE` (256 KiB), capping decompressed packet payloads
/// to defend against zip-bomb DoS packets.
const int _defaultMaxDecompressedBytes = 256 * 1024;

SSHPacketCompressor? createCompressor(SSHCompressionType type) {
  if (type == SSHCompressionType.none) return null;
  return _NativeZlibPacketCompressor();
}

SSHPacketDecompressor? createDecompressor(SSHCompressionType type) {
  if (type == SSHCompressionType.none) return null;
  return _NativeZlibPacketDecompressor();
}

class _NativeZlibPacketCompressor extends SSHPacketCompressor {
  // Level 4 balances compression ratio (within ~1-2% of level 6 on terminal
  // streams & JSON) with ~2x faster CPU speed on mobile devices.
  final RawZLibFilter _filter = RawZLibFilter.deflateFilter(level: 4);

  @override
  Uint8List compress(Uint8List payload) {
    _filter.process(payload, 0, payload.length);
    List<int>? first;
    BytesBuilder? builder;
    while (true) {
      final chunk = _filter.processed(flush: true, end: false);
      if (chunk == null) break;
      if (chunk.isEmpty) continue;
      if (first == null) {
        first = chunk;
      } else {
        builder ??= BytesBuilder(copy: false)..add(first);
        builder.add(chunk);
      }
    }
    if (builder != null) {
      return builder.takeBytes();
    }
    if (first == null) {
      return Uint8List(0);
    }
    return first is Uint8List ? first : Uint8List.fromList(first);
  }
}

class _NativeZlibPacketDecompressor extends SSHPacketDecompressor {
  final RawZLibFilter _filter = RawZLibFilter.inflateFilter();

  @override
  Uint8List decompress(
    Uint8List compressed, {
    int maxDecompressedBytes = _defaultMaxDecompressedBytes,
  }) {
    try {
      _filter.process(compressed, 0, compressed.length);
      List<int>? first;
      BytesBuilder? builder;
      var total = 0;
      while (true) {
        final chunk = _filter.processed(flush: true, end: false);
        if (chunk == null) break;
        if (chunk.isEmpty) continue;
        total += chunk.length;
        if (total > maxDecompressedBytes) {
          throw SSHPacketError(
            'Decompressed packet exceeds maximum size ($maxDecompressedBytes bytes)',
          );
        }
        if (first == null) {
          first = chunk;
        } else {
          builder ??= BytesBuilder(copy: false)..add(first);
          builder.add(chunk);
        }
      }
      if (builder != null) {
        return builder.takeBytes();
      }
      if (first == null) {
        return Uint8List(0);
      }
      return first is Uint8List ? first : Uint8List.fromList(first);
    } on FormatException catch (e) {
      throw SSHPacketError('Decompression failed: $e');
    } on FileSystemException catch (e) {
      throw SSHPacketError('Decompression failed: $e');
    }
  }
}
