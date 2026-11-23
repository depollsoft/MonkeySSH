import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List? inflateZlibPlatform(Uint8List bytes, {required int maxBytes}) {
  if (bytes.isEmpty || maxBytes <= 0) {
    return null;
  }
  try {
    return const ZLibDecoder().decodeBytes(bytes, maxOutputSize: maxBytes);
  } catch (_) {
    return null;
  }
}
