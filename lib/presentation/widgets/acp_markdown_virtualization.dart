import 'package:flutter/foundation.dart';

import 'acp_markdown_data_images.dart';

/// Target source size for one lazily rendered Markdown segment.
///
/// `MarkdownBody` eagerly parses and lays out its complete source. Keeping each
/// segment small lets the surrounding sliver dispose distant parts of a long
/// response instead of blocking the UI isolate on the whole document.
const int kAcpMarkdownVirtualChunkChars = 8 * 1024;

/// Smaller bound for literal user text, whose long wrapped lines are costly.
const int kAcpTextVirtualChunkChars = 2 * 1024;

/// Splits a large Markdown document into independently renderable segments.
///
/// Short documents retain their original identity. Long documents prefer
/// blank-line boundaries and preserve fenced code validity by closing and
/// reopening a fence when a segment boundary falls inside it. Exceptionally
/// long lines are split near whitespace so provider output cannot bypass the
/// rendering bound with one giant paragraph.
List<String> splitAcpMarkdownForVirtualization(
  String source, {
  int targetChars = kAcpMarkdownVirtualChunkChars,
}) {
  assert(targetChars > 0);
  final normalizedSource = normalizeAcpMarkdownDataImages(source);
  if (normalizedSource.length <= targetChars) return <String>[normalizedSource];

  final lines = _markdownLines(normalizedSource);
  final chunks = <String>[];
  var current = StringBuffer();
  String? fenceMarker;
  String? fenceOpening;
  var hasPayload = false;

  void flush({bool reopenFence = false}) {
    if (current.isEmpty) return;
    if (fenceMarker != null) {
      final separator = current.toString().endsWith('\n') ? '' : '\n';
      current
        ..write(separator)
        ..write('$fenceMarker\n');
    }
    chunks.add(current.toString());
    current = StringBuffer();
    hasPayload = false;
    if (reopenFence && fenceOpening != null) {
      current
        ..write(fenceOpening)
        ..write('\n');
    }
  }

  for (final originalLine in lines) {
    var isFenceLine = false;
    _updateFenceState(
      originalLine,
      currentFence: fenceMarker,
      onOpen: (marker, opening) {
        if (current.length + originalLine.length > targetChars) flush();
        fenceMarker = marker;
        fenceOpening = opening;
        isFenceLine = true;
      },
      onClose: () {
        fenceMarker = null;
        fenceOpening = null;
        isFenceLine = true;
      },
    );
    if (isFenceLine) {
      // Fence delimiters stay atomic even when the requested budget is tiny.
      current.write(originalLine);
      if (fenceMarker == null && current.length >= targetChars) flush();
      continue;
    }
    var line = originalLine;
    while (line.isNotEmpty) {
      if (fenceMarker == null &&
          line.length > targetChars &&
          containsAcpMarkdownDataImage(line)) {
        // Parsing the data URI once is cheaper and correct; splitting it would
        // turn every later chunk into visible base64 text. AcpInlineImage still
        // enforces encoded-byte and decoded-pixel limits before display.
        flush();
        chunks.add(line);
        line = '';
        continue;
      }
      final remaining = targetChars - current.length;
      if (line.length > remaining) {
        if (current.isNotEmpty && (fenceMarker == null || hasPayload)) {
          // Prefer a line boundary, but never flush just a reopened fence.
          flush(reopenFence: fenceMarker != null);
          continue;
        }
        // A fence can exhaust a tiny budget. Still consume at least one
        // complete code point so every overflow iteration makes progress.
        final splitAt = _safeLineSplit(line, remaining);
        current.write(line.substring(0, splitAt));
        hasPayload = true;
        line = line.substring(splitAt);
        if (fenceMarker != null && (line == '\n' || line == '\r\n')) {
          current.write(line);
          line = '';
        }
        if (line.isNotEmpty) flush(reopenFence: fenceMarker != null);
        continue;
      }

      current.write(line);
      hasPayload = true;
      line = '';

      if (current.length >= targetChars && fenceMarker == null) {
        flush();
      }
    }
  }
  flush();
  return List<String>.unmodifiable(chunks);
}

/// Splits large literal user text into bounded, lossless render segments.
///
/// Unlike Markdown segmentation this never inserts formatting delimiters: a
/// pasted diagnostics payload must copy back byte-for-byte in the same order.
List<String> splitAcpTextForVirtualization(
  String source, {
  int targetChars = kAcpTextVirtualChunkChars,
}) {
  assert(targetChars > 0);
  if (source.length <= targetChars) return <String>[source];

  final chunks = <String>[];
  var current = StringBuffer();

  void flush() {
    if (current.isEmpty) return;
    chunks.add(current.toString());
    current = StringBuffer();
  }

  for (final originalLine in _markdownLines(source)) {
    var line = originalLine;
    while (line.isNotEmpty) {
      final remaining = targetChars - current.length;
      if (remaining <= 0) {
        flush();
        continue;
      }
      if (line.length <= remaining) {
        current.write(line);
        line = '';
        continue;
      }
      if (current.isNotEmpty) {
        flush();
        continue;
      }
      final splitAt = _safeLineSplit(line, targetChars);
      current.write(line.substring(0, splitAt));
      line = line.substring(splitAt);
      flush();
    }
  }
  flush();
  return List<String>.unmodifiable(chunks);
}

List<String> _markdownLines(String source) {
  final lines = <String>[];
  var start = 0;
  while (start < source.length) {
    final newline = source.indexOf('\n', start);
    if (newline < 0) {
      lines.add(source.substring(start));
      break;
    }
    lines.add(source.substring(start, newline + 1));
    start = newline + 1;
  }
  return lines;
}

int _safeLineSplit(String line, int preferred) {
  final limit = preferred.clamp(1, line.length);
  final searchStart = (limit ~/ 2).clamp(1, limit);
  for (var index = limit; index >= searchStart; index--) {
    if (_isWhitespace(line.codeUnitAt(index - 1))) return index;
  }
  // Avoid separating a UTF-16 surrogate pair at an emergency hard boundary.
  if (limit < line.length && _isHighSurrogate(line.codeUnitAt(limit - 1))) {
    return limit == 1 ? 2 : limit - 1;
  }
  return limit;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

void _updateFenceState(
  String line, {
  required String? currentFence,
  required void Function(String marker, String opening) onOpen,
  required VoidCallback onClose,
}) {
  final trimmed = line.trimLeft().trimRight();
  if (trimmed.isEmpty) return;
  if (currentFence != null) {
    if (trimmed.startsWith(currentFence) &&
        trimmed.substring(currentFence.length).trim().isEmpty) {
      onClose();
    }
    return;
  }
  final match = RegExp('^(`{3,}|~{3,})').firstMatch(trimmed);
  if (match == null) return;
  final marker = match.group(1)!;
  onOpen(marker, trimmed);
}
