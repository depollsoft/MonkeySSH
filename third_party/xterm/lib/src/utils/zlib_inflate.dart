import 'dart:typed_data';

import 'package:xterm/src/utils/zlib_inflate_stub.dart'
    if (dart.library.io) 'package:xterm/src/utils/zlib_inflate_io.dart'
    as impl;

/// Inflates zlib-compressed [bytes], returning `null` on invalid data or if
/// the output would exceed [maxBytes].
Uint8List? inflateZlibNative(Uint8List bytes, {required int maxBytes}) =>
    impl.inflateZlibPlatform(bytes, maxBytes: maxBytes);
