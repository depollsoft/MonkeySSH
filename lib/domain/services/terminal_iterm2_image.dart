import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

/// Maximum decoded payload accepted from an iTerm2 inline-file sequence.
///
/// This matches the Kitty graphics transmission cap in the vendored xterm
/// renderer, preventing OSC 1337 from becoming a less-bounded path to the same
/// image decoder.
const int maxIterm2InlineImageBytes = 16 * 1024 * 1024;

/// Parses and displays an iTerm2 `OSC 1337 ; File=...` inline image.
///
/// Returns `true` for every `File=` command, including unsupported downloads or
/// malformed payloads, so the caller can consume the command without logging
/// user-controlled file metadata. Only `inline=1` payloads are decoded; remote
/// file downloads are deliberately not supported.
bool handleIterm2InlineImageOsc(
  Terminal terminal,
  List<String> args, {
  double? cellPixelWidth,
  double? cellPixelHeight,
}) {
  if (args.isEmpty || !args.first.startsWith('File=')) {
    return false;
  }

  const maxMetadataLength = 8 * 1024;
  var aggregateLength = 0;
  var metadataLength = 0;
  var payloadArg = -1;
  var payloadSeparator = -1;
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    aggregateLength += arg.length + 1;
    if (payloadArg < 0) {
      final separator = arg.indexOf(':');
      metadataLength += separator < 0 ? arg.length + 1 : separator;
      if (separator >= 0) {
        payloadArg = index;
        payloadSeparator = separator;
      }
    }
    if (metadataLength > maxMetadataLength ||
        aggregateLength > _maxEncodedImageLength + maxMetadataLength) {
      return true;
    }
  }
  // Base64 never contains `;`, so a valid payload is confined to the argument
  // holding the `:` separator; trailing arguments mean a malformed payload.
  if (payloadArg < 0 || payloadArg != args.length - 1) {
    return true;
  }

  final metadata = _parseIterm2FileMetadata([
    for (var index = 0; index <= payloadArg; index += 1)
      args[index].substring(
        index == 0 ? 'File='.length : 0,
        index == payloadArg ? payloadSeparator : null,
      ),
  ]);
  if (metadata['inline'] != '1') {
    return true;
  }

  final encoded = args[payloadArg].substring(payloadSeparator + 1);
  if (encoded.isEmpty || encoded.length > _maxEncodedImageLength) {
    return true;
  }

  final Uint8List imageBytes;
  try {
    imageBytes = base64Decode(encoded);
  } on FormatException {
    return true;
  }
  if (imageBytes.isEmpty || imageBytes.length > maxIterm2InlineImageBytes) {
    return true;
  }

  final graphicsArgs = <String, String>{
    'a': 'T',
    // The vendored renderer uses f=98 for Flutter-supported encoded image
    // containers, including PNG, JPEG, GIF, and APNG.
    'f': '98',
    'q': '2',
  };
  final columns = _parseIterm2CellDimension(
    metadata['width'],
    availableCells: terminal.viewWidth,
    cellPixelExtent: cellPixelWidth,
  );
  final rows = _parseIterm2CellDimension(
    metadata['height'],
    availableCells: terminal.viewHeight,
    cellPixelExtent: cellPixelHeight,
  );
  final preservesAspectRatio = metadata['preserveAspectRatio'] != '0';
  var displayColumns = columns;
  var displayRows = rows;
  if (preservesAspectRatio && columns != null && rows != null) {
    final fitted = terminal.fitGraphicsInCellBounds(
      imageBytes,
      maxColumns: columns,
      maxRows: rows,
    );
    displayColumns = fitted?.columns ?? columns;
    displayRows = fitted?.rows ?? rows;
  }
  if (displayColumns != null) {
    graphicsArgs['c'] = '$displayColumns';
  }
  if (displayRows != null) {
    graphicsArgs['r'] = '$displayRows';
  }
  if (metadata['doNotMoveCursor'] == '1') {
    graphicsArgs['C'] = '1';
  }

  terminal.submitGraphicsCommand(graphicsArgs, imageBytes);
  return true;
}

const int _maxEncodedImageLength = ((maxIterm2InlineImageBytes + 2) ~/ 3) * 4;

Map<String, String> _parseIterm2FileMetadata(List<String> fields) {
  final metadata = <String, String>{};
  for (final field in fields) {
    final separator = field.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    metadata[field.substring(0, separator)] = field.substring(separator + 1);
  }
  return metadata;
}

int? _parseIterm2CellDimension(
  String? raw, {
  required int availableCells,
  required double? cellPixelExtent,
}) {
  if (raw == null || raw.isEmpty || raw == 'auto' || availableCells <= 0) {
    return null;
  }
  final percentage = RegExp(r'^(\d{1,3})%$').firstMatch(raw);
  if (percentage != null) {
    final value = int.parse(percentage.group(1)!).clamp(1, 100);
    return ((availableCells * value) / 100).ceil().clamp(1, availableCells);
  }
  final pixels = RegExp(r'^(\d+)px$').firstMatch(raw);
  if (pixels != null &&
      cellPixelExtent != null &&
      cellPixelExtent.isFinite &&
      cellPixelExtent > 0) {
    final pixelValue = int.tryParse(pixels.group(1)!);
    if (pixelValue == null || pixelValue <= 0) return null;
    return (pixelValue / cellPixelExtent).ceil().clamp(1, availableCells);
  }
  final cells = int.tryParse(raw);
  if (cells == null || cells <= 0) return null;
  return cells.clamp(1, availableCells);
}
