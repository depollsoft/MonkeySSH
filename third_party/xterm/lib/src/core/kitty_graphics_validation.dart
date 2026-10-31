import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Kitty graphics data formats (`f=`).
///
/// Kitty reads `f=0`, like an absent `f`, as RGBA.
const kittyGraphicsFormatRgb = 24;
const kittyGraphicsFormatRgba = 32;
const kittyGraphicsFormatPng = 100;

/// A MonkeySSH-private format for any container Flutter decodes (PNG, JPEG,
/// GIF, APNG), used by the iTerm2 inline image bridge. Programs cannot use it.
const kittyGraphicsFormatEncoded = 98;

/// Largest width or height Kitty accepts for an image (`s=`, `v=`).
const kittyGraphicsMaxImageDimension = 10000;

/// The format a command transmits, or null when `f=` names one Kitty does not
/// know. [allowEncoded] admits the private [kittyGraphicsFormatEncoded].
int? kittyGraphicsFormat(
  Map<String, String> args, {
  bool allowEncoded = false,
}) {
  final raw = args['f'];
  if (raw == null || raw.isEmpty) return kittyGraphicsFormatRgba;
  final format = int.tryParse(raw);
  return switch (format) {
    0 || kittyGraphicsFormatRgba => kittyGraphicsFormatRgba,
    kittyGraphicsFormatRgb => kittyGraphicsFormatRgb,
    kittyGraphicsFormatPng => kittyGraphicsFormatPng,
    kittyGraphicsFormatEncoded when allowEncoded => kittyGraphicsFormatEncoded,
    _ => null,
  };
}

/// Whether the single-letter keys Kitty validates while parsing a graphics
/// command hold values it knows. Kitty drops a command with an unknown action
/// (`a=`), delete selector (`d=`), medium (`t=`) or compression (`o=`) without
/// any reply, before it runs.
bool kittyGraphicsFlagKeysValid(Map<String, String> args) {
  bool known(String key, String values) {
    final value = args[key];
    return value == null ||
        value.isEmpty ||
        (value.length == 1 && values.contains(value));
  }

  return known('a', 'tTqpdfac') &&
      known('d', 'aAiIcCnNpPqQxXyYzZrRfF') &&
      known('t', 'dfts') &&
      known('o', 'z');
}

/// The error a transmission (`a=t`, `a=T`, `a=q`, `a=f`) gets before its data
/// is looked at, or null when its keys are acceptable: a medium other than
/// direct data (the files named by `t=f`, `t=t` and `t=s` are on the remote
/// host, out of the terminal's reach), an unknown format, or raw pixels
/// without a usable size.
String? kittyGraphicsTransmissionError(
  Map<String, String> args, {
  bool allowEncoded = false,
}) {
  final medium = args['t'];
  if (medium != null && medium.isNotEmpty && medium != 'd') {
    return 'EINVAL: unsupported transmission medium';
  }
  final format = kittyGraphicsFormat(args, allowEncoded: allowEncoded);
  if (format == null) {
    return 'EINVAL: unsupported format';
  }
  final width = int.tryParse(args['s'] ?? '') ?? 0;
  final height = int.tryParse(args['v'] ?? '') ?? 0;
  if (width > kittyGraphicsMaxImageDimension ||
      height > kittyGraphicsMaxImageDimension) {
    return 'EINVAL: image too large';
  }
  if ((format == kittyGraphicsFormatRgb || format == kittyGraphicsFormatRgba) &&
      (width <= 0 || height <= 0)) {
    return 'EINVAL: missing image dimensions';
  }
  return null;
}

/// The error the (inflated) [payload] of a transmission in [format] gets, or
/// null when it holds a valid image.
///
/// Raw pixels must be exactly `s` x `v` pixels, as Kitty requires. PNG data
/// is checked structurally: signature, chunk lengths and CRCs, a valid IHDR
/// first and an IEND last. With [deep], as for a query, the image data is
/// also inflated and must hold every scanline, so a truncated or corrupt PNG
/// is not reported as loadable. Other formats are left to the decoder.
///
/// Unlike Kitty, MonkeySSH also decodes GIF, JPEG and WebP sent as `f=100`;
/// outside a query such data is left to the decoder too.
String? kittyGraphicsPayloadError(
  int format,
  Uint8List payload, {
  int width = 0,
  int height = 0,
  bool deep = false,
}) {
  if (payload.isEmpty) {
    return 'EINVAL: missing image data';
  }
  switch (format) {
    case kittyGraphicsFormatRgb:
    case kittyGraphicsFormatRgba:
      final bytesPerPixel = format == kittyGraphicsFormatRgb ? 3 : 4;
      return payload.length == width * height * bytesPerPixel
          ? null
          : 'EINVAL: image data size does not match its dimensions';
    case kittyGraphicsFormatPng:
      if (!deep && _isOtherEncodedImage(payload)) return null;
      return _pngError(payload, deep: deep);
    default:
      return null;
  }
}

const _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Whether [data] starts like a GIF, JPEG or WebP image.
bool _isOtherEncodedImage(Uint8List data) {
  bool startsWith(List<int> prefix, [int at = 0]) {
    if (data.length < at + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[at + i] != prefix[i]) return false;
    }
    return true;
  }

  return startsWith(const [0x47, 0x49, 0x46, 0x38]) || // GIF8
      startsWith(const [0xFF, 0xD8, 0xFF]) || // JPEG SOI
      (startsWith(const [0x52, 0x49, 0x46, 0x46]) && // RIFF....WEBP
          startsWith(const [0x57, 0x45, 0x42, 0x50], 8));
}

String? _pngError(Uint8List data, {required bool deep}) {
  const invalid = 'EINVAL: invalid PNG data';
  if (data.length < _pngSignature.length) return invalid;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (data[i] != _pngSignature[i]) return invalid;
  }
  final view = ByteData.sublistView(data);
  var offset = _pngSignature.length;
  var sawHeader = false;
  var sawData = false;
  var width = 0;
  var height = 0;
  var bitDepth = 0;
  var colorType = 0;
  var interlaced = false;
  final imageData = deep ? BytesBuilder(copy: false) : null;
  while (true) {
    if (offset + 12 > data.length) return invalid;
    final length = view.getUint32(offset);
    final typeStart = offset + 4;
    final dataStart = typeStart + 4;
    final dataEnd = dataStart + length;
    if (length > data.length || dataEnd + 4 > data.length) return invalid;
    final crc = view.getUint32(dataEnd);
    if (getCrc32(Uint8List.sublistView(data, typeStart, dataEnd)) != crc) {
      return invalid;
    }
    final type = String.fromCharCodes(data, typeStart, dataStart);
    if (!sawHeader && type != 'IHDR') return invalid;
    switch (type) {
      case 'IHDR':
        if (sawHeader || length != 13) return invalid;
        sawHeader = true;
        width = view.getUint32(dataStart);
        height = view.getUint32(dataStart + 4);
        bitDepth = data[dataStart + 8];
        colorType = data[dataStart + 9];
        final compression = data[dataStart + 10];
        final filter = data[dataStart + 11];
        final interlace = data[dataStart + 12];
        interlaced = interlace == 1;
        if (width == 0 ||
            height == 0 ||
            !_pngBitDepthAllowed(colorType, bitDepth) ||
            compression != 0 ||
            filter != 0 ||
            interlace > 1) {
          return invalid;
        }
      case 'IDAT':
        sawData = true;
        imageData?.add(Uint8List.sublistView(data, dataStart, dataEnd));
      case 'IEND':
        if (!sawData) return invalid;
        if (imageData == null) return null;
        return _pngImageDataComplete(
          imageData.takeBytes(),
          width: width,
          height: height,
          bitsPerPixel: _pngChannels(colorType) * bitDepth,
          interlaced: interlaced,
        )
            ? null
            : invalid;
    }
    offset = dataEnd + 4;
  }
}

/// The bit depths PNG allows for [colorType]; none for an unknown type.
bool _pngBitDepthAllowed(int colorType, int bitDepth) => switch (colorType) {
      0 => const [1, 2, 4, 8, 16].contains(bitDepth),
      3 => const [1, 2, 4, 8].contains(bitDepth),
      2 || 4 || 6 => bitDepth == 8 || bitDepth == 16,
      _ => false,
    };

int _pngChannels(int colorType) => switch (colorType) {
      0 || 3 => 1,
      2 => 3,
      4 => 2,
      6 => 4,
      _ => 0,
    };

/// Largest image data a query's PNG check inflates; a bigger image is only
/// checked structurally, so a query never decodes much on the UI thread.
const _maxCheckedPngImageDataBytes = 16 * 1024 * 1024;

/// Extra bytes accepted after a PNG's last scanline, as decoders ignore them.
const _pngImageDataSlackBytes = 1024;

bool _pngImageDataComplete(
  Uint8List compressed, {
  required int width,
  required int height,
  required int bitsPerPixel,
  required bool interlaced,
}) {
  int scanlines(int passWidth, int passHeight) =>
      passWidth <= 0 || passHeight <= 0
          ? 0
          : passHeight * (1 + (passWidth * bitsPerPixel + 7) ~/ 8);
  var expected = 0;
  if (!interlaced) {
    expected = scanlines(width, height);
  } else {
    // Adam7 passes: (x start, y start, x step, y step).
    const passes = <List<int>>[
      [0, 0, 8, 8],
      [4, 0, 8, 8],
      [0, 4, 4, 8],
      [2, 0, 4, 4],
      [0, 2, 2, 4],
      [1, 0, 2, 2],
      [0, 1, 1, 2],
    ];
    for (final pass in passes) {
      expected += scanlines(
        math.max(0, (width - pass[0] + pass[2] - 1) ~/ pass[2]),
        math.max(0, (height - pass[1] + pass[3] - 1) ~/ pass[3]),
      );
    }
  }
  if (expected > _maxCheckedPngImageDataBytes) {
    return true;
  }
  // The scanlines the header declares bound the inflate, so image data that
  // expands past them (a small file of compressed zeros, say) is rejected as
  // soon as it does rather than decoded in full.
  final List<int> inflated;
  try {
    inflated = const ZLibDecoder().decodeBytes(
      compressed,
      maxOutputSize: expected + _pngImageDataSlackBytes,
    );
  } catch (_) {
    return false;
  }
  return inflated.length >= expected;
}
