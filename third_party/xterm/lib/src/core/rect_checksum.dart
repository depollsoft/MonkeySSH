import 'dart:math' show min;

import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/cell.dart';

/// The XTCHECKSUM (`CSI Ps # y`) bits, which select how DECRQCRA computes its
/// checksum. Zero is the DEC checksum, which a full or soft reset restores
/// unless the terminal was given another default.
///
/// These are xterm's `CSBITS`, which it also reads from its
/// `checksumExtension` resource. xterm's documentation and code disagree on
/// bit 3; like Ghostty, this follows the code.
abstract class ChecksumExtension {
  /// Don't negate the sum.
  static const positive = 1 << 0;

  /// Don't add the VT100 video attributes to each cell.
  static const noAttributes = 1 << 1;

  /// Don't omit blanks. The DEC checksum only counts a plain space when it is
  /// the first cell counted in the rectangle.
  static const noTrim = 1 << 2;

  /// Count cells that were never written to as spaces instead of skipping
  /// them.
  static const undrawn = 1 << 3;

  /// Sum the code point (low 16 bits) instead of the DEC 8-bit value, and skip
  /// the right half of a wide character.
  static const fullCodePoint = 1 << 4;

  /// Every bit XTCHECKSUM can set. xterm ignores the others.
  static const mask = 0x1f;
}

/// The DECRQCRA reply (`DCS Pi ! ~ xxxx ST`) to
/// `CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y`, given its parameters.
///
/// Follows xterm's `xtermCheckRect`. Coordinates are one-based and a zero
/// (omitted) one takes its default; under origin mode (DECOM) rows count from
/// the top margin. The rectangle is clamped to the screen, and an empty one
/// sums to zero. The page (Pg) is ignored because there is only one.
String rectangularAreaChecksumReport(
  Buffer buffer,
  List<int> params, {
  required int extension,
  required bool originMode,
}) {
  int param(int index) => index < params.length ? params[index] : 0;
  int limit(int value, int fallback, int margin, int max) =>
      ((value == 0 ? fallback : value) + margin).clamp(1, max);

  final rows = buffer.viewHeight;
  final cols = buffer.viewWidth;
  final topMargin = originMode ? buffer.marginTop : 0;
  final top = limit(param(2), 1, topMargin, rows);
  final left = limit(param(3), 1, 0, cols);
  final bottom = limit(param(4), rows, topMargin, rows);
  final right = limit(param(5), cols, 0, cols);

  final sum = top > bottom || left > right
      ? 0
      : rectangularAreaChecksum(
          buffer,
          top: top - 1,
          left: left - 1,
          bottom: bottom - 1,
          right: right - 1,
          extension: extension,
        );
  final hex = sum.toRadixString(16).toUpperCase().padLeft(4, '0');
  return '\x1bP${param(0)}!~$hex\x1b\\';
}

/// The 16-bit checksum of the cells from ([left], [top]) to ([right],
/// [bottom]) of the visible screen, all zero-based and inclusive, computed as
/// the [ChecksumExtension] bits in [extension] select.
int rectangularAreaChecksum(
  Buffer buffer, {
  required int top,
  required int left,
  required int bottom,
  required int right,
  required int extension,
}) {
  final noAttributes = extension & ChecksumExtension.noAttributes != 0;
  final noTrim = extension & ChecksumExtension.noTrim != 0;
  final undrawn = extension & ChecksumExtension.undrawn != 0;
  final full = extension & ChecksumExtension.fullCodePoint != 0;

  final cell = CellData.empty();
  var sum = 0;
  // The DEC checksum omits plain spaces except for the very first cell
  // counted in the rectangle.
  var first = true;

  for (var row = top; row <= bottom; row++) {
    final line = buffer.lines[buffer.scrollBack + row];
    final end = min(right + 1, line.length);
    for (var col = left; col < end; col++) {
      line.getCellData(col, cell);
      final codePoint = cell.content & CellContent.codepointMask;

      int ch;
      if (codePoint != 0) {
        ch = full ? codePoint & 0xffff : _decValue(codePoint);
      } else if (col > 0 && line.getWidth(col - 1) == 2) {
        // The right half of a wide character. xterm keeps a placeholder
        // outside 8 bits there, which the DEC checksum counts as ESC.
        if (full) continue;
        ch = 0x1b;
      } else {
        // Never written to, or erased.
        if (!noTrim && !undrawn) continue;
        ch = 0x20;
      }

      if (!noAttributes) ch += _videoAttributes(cell.flags);

      if (noTrim || first || ch != 0x20 || _keepsBlank(cell.flags)) {
        sum += ch;
      }
      first = noTrim;
    }
    if (!noTrim) first = false;
  }

  sum &= 0xffff;
  if (extension & ChecksumExtension.positive != 0) return sum;
  return -sum & 0xffff;
}

/// The DEC 8-bit value of [codePoint], as xterm's `xtermCharSetDec` gives it
/// for the ASCII character set. xterm sums the byte it received, before
/// character set translation; only the translated code point is kept here, so
/// DEC line drawing counts as a character outside 8 bits.
int _decValue(int codePoint) {
  if (codePoint == 0x7f || codePoint == 0xff) return 0;
  if ((codePoint >= 0x20 && codePoint <= 0x7e) ||
      (codePoint >= 0x80 && codePoint <= 0x9f) ||
      (codePoint >= 0xa1 && codePoint <= 0xfe)) {
    return codePoint & 0x7f;
  }
  return 0x1b;
}

/// The VT100 video attributes xterm adds to each cell. This terminal has no
/// DECSCA protection, which xterm counts as 0x04.
int _videoAttributes(int flags) {
  var result = 0;
  if (flags & CellAttr.invisible != 0) result += 0x08;
  if (flags & CellAttr.underline != 0) result += 0x10;
  if (flags & CellAttr.inverse != 0) result += 0x20;
  if (flags & CellAttr.blink != 0) result += 0x40;
  if (flags & CellAttr.bold != 0) result += 0x80;
  return result;
}

/// Attributes xterm doesn't add to the sum but that still keep a blank from
/// being trimmed.
bool _keepsBlank(int flags) {
  final underlineStyle =
      (flags & CellAttr.underlineStyleMask) >> CellAttr.underlineStyleShift;
  return flags & (CellAttr.faint | CellAttr.italic | CellAttr.strikethrough) !=
          0 ||
      underlineStyle == UnderlineStyle.double.index;
}
