/// Shared scan of the tail of terminal text for a bare prompt marker.
library;

/// Whether [codeUnit] is an ASCII letter or digit.
bool isAsciiLetterOrDigitCodeUnit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

/// Whether [codeUnit] is a space, tab or line break.
bool isPromptWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

/// Longest run of visible code units still read as a prompt marker (`$ `,
/// `> `, `>>> `, ...).
const promptMarkerMaxLength = 4;

/// Walks [text] backwards from its end and describes the last line.
///
/// [endsAtLineStart] is true when only prompt whitespace follows the last
/// line break (or the whole text is whitespace). Otherwise
/// [promptMarkerLength] is the number of visible code units on the last line
/// when they could be a prompt marker (at most [promptMarkerMaxLength], none
/// an ASCII letter or digit), and null when that line holds other text.
({bool endsAtLineStart, int? promptMarkerLength}) scanPromptTail(String text) {
  var index = text.length - 1;
  while (index >= 0) {
    final codeUnit = text.codeUnitAt(index);
    if (codeUnit == 0x0A || codeUnit == 0x0D) {
      return (endsAtLineStart: true, promptMarkerLength: null);
    }
    if (!isPromptWhitespaceCodeUnit(codeUnit)) {
      break;
    }
    index--;
  }
  if (index < 0) {
    return (endsAtLineStart: true, promptMarkerLength: null);
  }

  var visibleCodeUnitCount = 0;
  while (index >= 0) {
    final codeUnit = text.codeUnitAt(index);
    if (codeUnit == 0x0A || codeUnit == 0x0D) {
      break;
    }
    if (!isPromptWhitespaceCodeUnit(codeUnit)) {
      visibleCodeUnitCount++;
      if (visibleCodeUnitCount > promptMarkerMaxLength ||
          isAsciiLetterOrDigitCodeUnit(codeUnit)) {
        return (endsAtLineStart: false, promptMarkerLength: null);
      }
    }
    index--;
  }
  return (endsAtLineStart: false, promptMarkerLength: visibleCodeUnitCount);
}
