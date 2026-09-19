// ignore_for_file: public_member_api_docs

import '../models/acp_timeline.dart';
import 'acp_markdown_virtualization.dart';

final Expando<String> _userPromptSummaryCache = Expando<String>(
  'ACP user prompt summary',
);

/// Builds the compact context shown when a user prompt is above the viewport.
String acpUserPromptSummary(AcpUserPromptEntry entry) {
  final cached = _userPromptSummaryCache[entry];
  if (cached != null) return cached;
  final summary = _buildAcpUserPromptSummary(entry);
  _userPromptSummaryCache[entry] = summary;
  return summary;
}

String _buildAcpUserPromptSummary(AcpUserPromptEntry entry) {
  const maxLength = 240;
  final text = StringBuffer();
  var pendingSpace = false;
  var truncated = false;
  outer:
  for (final part in entry.parts.whereType<AcpTextPart>()) {
    for (final rune in part.text.runes) {
      if (_isPromptSummaryWhitespace(rune)) {
        pendingSpace = text.isNotEmpty;
        continue;
      }
      if (pendingSpace && text.length < maxLength) text.write(' ');
      pendingSpace = false;
      if (text.length >= maxLength) {
        truncated = true;
        break outer;
      }
      text.writeCharCode(rune);
    }
    pendingSpace = text.isNotEmpty;
  }
  if (text.isNotEmpty) {
    final value = text.toString();
    return truncated && value.length >= maxLength
        ? '${value.substring(0, maxLength - 1)}…'
        : value;
  }

  final attachments = <String>[
    for (final part in entry.parts)
      switch (part) {
        AcpImagePart(:final image) =>
          (image.label?.trim().isNotEmpty ?? false)
              ? image.label!.trim()
              : 'Image',
        AcpResourcePart(:final resource) => resource.displayName,
        AcpTextPart() => '',
      },
  ]..removeWhere((label) => label.isEmpty);
  if (attachments.isEmpty) return 'Your message';
  final summary = attachments.join(' · ');
  return summary.length <= 240 ? summary : '${summary.substring(0, 239)}…';
}

bool _isPromptSummaryWhitespace(int rune) =>
    rune <= 0x20 ||
    const <int>{
      0x0085,
      0x00A0,
      0x1680,
      0x2000,
      0x2001,
      0x2002,
      0x2003,
      0x2004,
      0x2005,
      0x2006,
      0x2007,
      0x2008,
      0x2009,
      0x200A,
      0x2028,
      0x2029,
      0x202F,
      0x205F,
      0x3000,
    }.contains(rune);

final Expando<List<String>> _assistantMarkdownChunks = Expando<List<String>>(
  'ACP virtual Markdown segments',
);
final Expando<List<List<AcpPromptPart>>> _userPromptSegments =
    Expando<List<List<AcpPromptPart>>>('ACP virtual user prompt segments');

const int _maxInitialTailChildren = 48;
const int _maxInitialTailSourceChars = 16 * 1024;

final class AcpThreadChild {
  const AcpThreadChild({
    required this.entry,
    required this.entryIndex,
    this.markdown,
    this.markdownPartIndex,
    this.markdownPartCount,
    this.userParts,
    this.userPartIndex,
    this.userPartCount,
  });

  final AcpTimelineEntry entry;
  final int entryIndex;
  final String? markdown;
  final int? markdownPartIndex;
  final int? markdownPartCount;
  final List<AcpPromptPart>? userParts;
  final int? userPartIndex;
  final int? userPartCount;

  bool get isEntryContinuation =>
      (markdownPartIndex ?? 0) > 0 || (userPartIndex ?? 0) > 0;

  String get keyValue {
    final markdownPart = markdownPartIndex;
    if (markdownPart != null && markdownPart > 0) {
      return '${entry.id}-markdown-part-$markdownPart';
    }
    final userPart = userPartIndex;
    if (userPart != null && userPart > 0) {
      return '${entry.id}-user-part-$userPart';
    }
    return entry.id;
  }
}

List<AcpThreadChild> buildAcpThreadChildren(
  List<AcpTimelineEntry> entries, {
  required int startEntryIndex,
  int? endEntryIndex,
}) {
  final children = <AcpThreadChild>[];
  final end = endEntryIndex ?? entries.length;
  for (var entryIndex = startEntryIndex; entryIndex < end; entryIndex++) {
    final entry = entries[entryIndex];
    if (entry case AcpUserPromptEntry(:final parts)
        when parts.any(
          (part) =>
              part is AcpTextPart &&
              part.text.length > kAcpTextVirtualChunkChars,
        )) {
      final segments = _userPromptSegments[entry] ??= <List<AcpPromptPart>>[
        for (final part in parts)
          if (part case AcpTextPart(:final text)
              when text.length > kAcpTextVirtualChunkChars)
            for (final chunk in splitAcpTextForVirtualization(text))
              <AcpPromptPart>[AcpTextPart(chunk)]
          else
            <AcpPromptPart>[part],
      ];
      for (var partIndex = 0; partIndex < segments.length; partIndex++) {
        children.add(
          AcpThreadChild(
            entry: entry,
            entryIndex: entryIndex,
            userParts: segments[partIndex],
            userPartIndex: partIndex,
            userPartCount: segments.length,
          ),
        );
      }
      continue;
    }
    if (entry case AcpAssistantMessageEntry(:final markdown)
        when markdown.length > kAcpMarkdownVirtualChunkChars) {
      final chunks = _assistantMarkdownChunks[entry] ??=
          splitAcpMarkdownForVirtualization(markdown);
      for (var partIndex = 0; partIndex < chunks.length; partIndex++) {
        children.add(
          AcpThreadChild(
            entry: entry,
            entryIndex: entryIndex,
            markdown: chunks[partIndex],
            markdownPartIndex: partIndex,
            markdownPartCount: chunks.length,
          ),
        );
      }
      continue;
    }
    children.add(AcpThreadChild(entry: entry, entryIndex: entryIndex));
  }
  return children;
}

({
  int startEntryIndex,
  List<AcpThreadChild> children,
  int initialVisibleChildren,
})
projectAcpThreadWindow(List<AcpTimelineEntry> entries) {
  var startEntryIndex = entries.length;
  var initialVisibleChildren = 0;
  var sourceChars = 0;
  final children = <AcpThreadChild>[];
  while (startEntryIndex > 0 &&
      initialVisibleChildren < _maxInitialTailChildren &&
      sourceChars < _maxInitialTailSourceChars) {
    startEntryIndex -= 1;
    final entry = entries[startEntryIndex];
    final entryChildren = buildAcpThreadChildren(
      entries,
      startEntryIndex: startEntryIndex,
      endEntryIndex: startEntryIndex + 1,
    );
    children.insertAll(0, entryChildren);
    final entrySourceChars = switch (entry) {
      AcpUserPromptEntry(:final parts) => parts.whereType<AcpTextPart>().fold(
        0,
        (length, part) => length + part.text.length,
      ),
      AcpAssistantMessageEntry(:final markdown) ||
      AcpThoughtEntry(:final markdown) => markdown.length,
      _ => 128,
    };
    if (entryChildren.length > 1 ||
        entrySourceChars > _maxInitialTailSourceChars) {
      // For oversized content, mount only its final virtual segment plus any
      // already-selected lightweight rows after it. This is the critical
      // bottom-first path: no older Markdown participates in initial layout.
      initialVisibleChildren += 1;
      break;
    }
    initialVisibleChildren += entryChildren.length;
    sourceChars += entrySourceChars;
  }
  return (
    startEntryIndex: startEntryIndex,
    children: children,
    initialVisibleChildren: children.isEmpty
        ? 0
        : initialVisibleChildren.clamp(1, children.length),
  );
}
