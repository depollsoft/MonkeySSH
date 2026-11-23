import 'dart:io';
import 'dart:typed_data';

/// Native C zlib inflation via `dart:io`'s [RawZLibFilter], enforcing
/// [maxBytes] incrementally so oversized payloads abort before allocating
/// unbounded memory.
Uint8List? inflateZlibPlatform(Uint8List bytes, {required int maxBytes}) {
  if (bytes.isEmpty || maxBytes <= 0) {
    return null;
  }
  try {
    final filter = RawZLibFilter.inflateFilter();
    filter.process(bytes, 0, bytes.length);
    final builder = BytesBuilder(copy: false);
    var total = 0;
    while (true) {
      final chunk = filter.processed(flush: true, end: true);
      if (chunk == null) {
        break;
      }
      if (chunk.isEmpty) {
        continue;
      }
      total += chunk.length;
      if (total > maxBytes) {
        return null;
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  }
}
