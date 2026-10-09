/// Find-in-transcript for a native agent chat.
///
/// Matching runs over the same presentation entries the thread renders, split
/// into the same virtual segments, so every match names the exact list child
/// to scroll to. The query and the transcript are user content: nothing here
/// logs or persists either.
library;

import 'package:flutter/foundation.dart';

import '../widgets/acp_thread_projection.dart';
import 'acp_timeline.dart';

/// Most matches one search reports. Further occurrences are counted as
/// "more" without being indexed, which keeps a one-letter query on a long
/// transcript bounded.
const int kAcpTranscriptSearchMaxMatches = 999;

/// Characters of context kept before a match in its snippet.
const int _snippetLeadingChars = 32;

/// Characters of context kept after a match in its snippet.
const int _snippetTrailingChars = 96;

/// Inline base64 payloads are not searchable text: a short query would
/// otherwise match random image bytes.
final RegExp _dataUriPattern = RegExp(r'data:[^,\s)>"]*,[^\s)>"]*');

final RegExp _whitespaceRun = RegExp(r'\s+');

final Expando<Map<int, String>> _searchTextCache = Expando<Map<int, String>>(
  'ACP transcript search text',
);

/// Which part of the conversation a match was found in.
enum AcpTranscriptMatchSource {
  /// A prompt the user sent.
  user,

  /// An agent reply.
  agent,

  /// The agent's reasoning, collapsed by default.
  reasoning,

  /// A tool call's title, input, output, diff or locations.
  tool,

  /// A plan item.
  plan,

  /// A status, stop reason or error line.
  status,
}

/// Short context around a match, split so the match itself can be styled.
@immutable
final class AcpTranscriptSnippet {
  /// Creates a snippet.
  const AcpTranscriptSnippet({
    required this.before,
    required this.match,
    required this.after,
  });

  /// Context before the match, with whitespace collapsed.
  final String before;

  /// The matched text as it appears in the transcript.
  final String match;

  /// Context after the match, with whitespace collapsed.
  final String after;
}

/// One occurrence of the query in the loaded transcript.
final class AcpTranscriptMatch {
  AcpTranscriptMatch._({
    required AcpThreadChild child,
    required this.source,
    required this.start,
    required this.length,
  }) : _child = child;

  final AcpThreadChild _child;

  /// Where the match was found.
  final AcpTranscriptMatchSource source;

  /// Offset of the match in its segment's searchable text.
  final int start;

  /// Length of the match in its segment's searchable text.
  final int length;

  /// Index of the top-level timeline entry containing the match.
  int get entryIndex => _child.entryIndex;

  /// Key of the rendered thread child containing the match.
  String get childKey => _child.keyValue;

  /// Identifier of the entry that renders the match. For a nested subagent
  /// entry this differs from the top-level entry at [entryIndex].
  String get entryId => _child.entry.id;

  /// Context around the match, built on first use.
  late final AcpTranscriptSnippet snippet = _buildSnippet(
    _searchableText(_child),
    start,
    length,
  );
}

/// Outcome of searching a loaded transcript.
@immutable
final class AcpTranscriptSearchResult {
  /// Creates a search result.
  const AcpTranscriptSearchResult({
    required this.matches,
    required this.capped,
  });

  /// An empty result.
  static const empty = AcpTranscriptSearchResult(
    matches: <AcpTranscriptMatch>[],
    capped: false,
  );

  /// Matches in transcript order, at most [kAcpTranscriptSearchMaxMatches].
  final List<AcpTranscriptMatch> matches;

  /// Whether more occurrences exist beyond [matches].
  final bool capped;
}

/// Finds every case-insensitive occurrence of [query] in [entries].
///
/// User prompts, agent replies, reasoning, tool titles, input, output, diffs
/// and locations, plan items and status lines are all searched. Inline image
/// and audio payloads are not. Matches are non-overlapping and ordered as the
/// thread renders them, including nested subagent transcripts.
AcpTranscriptSearchResult searchAcpTranscript(
  List<AcpTimelineEntry> entries,
  String query, {
  int maxMatches = kAcpTranscriptSearchMaxMatches,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || entries.isEmpty) return AcpTranscriptSearchResult.empty;
  final matches = <AcpTranscriptMatch>[];
  final children = buildAcpThreadChildren(entries, startEntryIndex: 0);
  for (final child in children) {
    final source = _sourceOf(child.entry);
    if (source == null) continue;
    final haystack = _lowerSearchableText(child);
    var from = 0;
    while (true) {
      final index = haystack.indexOf(needle, from);
      if (index < 0) break;
      if (matches.length >= maxMatches) {
        return AcpTranscriptSearchResult(
          matches: List<AcpTranscriptMatch>.unmodifiable(matches),
          capped: true,
        );
      }
      matches.add(
        AcpTranscriptMatch._(
          child: child,
          source: source,
          start: index,
          length: needle.length,
        ),
      );
      from = index + needle.length;
    }
  }
  return AcpTranscriptSearchResult(
    matches: List<AcpTranscriptMatch>.unmodifiable(matches),
    capped: false,
  );
}

AcpTranscriptMatchSource? _sourceOf(AcpTimelineEntry entry) => switch (entry) {
  AcpUserPromptEntry() => AcpTranscriptMatchSource.user,
  AcpAssistantMessageEntry() => AcpTranscriptMatchSource.agent,
  AcpThoughtEntry() => AcpTranscriptMatchSource.reasoning,
  AcpToolCallEntry() => AcpTranscriptMatchSource.tool,
  AcpPlanEntry() => AcpTranscriptMatchSource.plan,
  AcpStatusEntry() => AcpTranscriptMatchSource.status,
  // A subagent transcript's own row is only its header; its descendants are
  // separate children and are searched individually.
  AcpSubagentTranscriptEntry() || AcpUsageEntry() => null,
};

int _segmentIndex(AcpThreadChild child) =>
    child.markdownPartIndex ?? child.userPartIndex ?? 0;

/// Lower-cased searchable text, memoised per immutable entry and segment so
/// typing a query does not re-lower the whole transcript on every keystroke.
String _lowerSearchableText(AcpThreadChild child) {
  final segments = _searchTextCache[child.entry] ??= <int, String>{};
  return segments[_segmentIndex(child)] ??= _lowerPreservingOffsets(
    _searchableText(child),
  );
}

/// Lower-cases [text] while keeping every offset aligned with the original.
///
/// A few characters (such as `İ`) lower-case to more than one code unit. Those
/// are kept as-is so a match offset always points at the same original text.
String _lowerPreservingOffsets(String text) {
  final lower = text.toLowerCase();
  if (lower.length == text.length) return lower;
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final original = String.fromCharCode(rune);
    final lowered = original.toLowerCase();
    buffer.write(lowered.length == original.length ? lowered : original);
  }
  return buffer.toString();
}

String _searchableText(AcpThreadChild child) {
  final segment = child.userParts;
  if (segment != null) return _promptText(segment);
  final markdown = child.markdown;
  if (markdown != null) return _withoutDataUris(markdown);
  return switch (child.entry) {
    AcpUserPromptEntry(:final parts) => _promptText(parts),
    AcpAssistantMessageEntry(:final markdown) => _withoutDataUris(markdown),
    AcpThoughtEntry(:final title, :final markdown) => _joinNonEmpty([
      title,
      _withoutDataUris(markdown),
    ]),
    AcpToolCallEntry(:final toolCall) => _toolText(toolCall),
    AcpPlanEntry(:final plan) => _joinNonEmpty([
      for (final item in plan.items) item.title,
    ]),
    AcpStatusEntry(:final message, :final detail) => _joinNonEmpty([
      message,
      detail,
    ]),
    AcpSubagentTranscriptEntry() || AcpUsageEntry() => '',
  };
}

String _promptText(List<AcpPromptPart> parts) => _joinNonEmpty([
  for (final part in parts)
    switch (part) {
      AcpTextPart(:final text) => text,
      AcpImagePart(:final image) => image.label,
      AcpAudioPart(:final clip) => clip.label,
      AcpResourcePart(:final resource) => resource.displayName,
    },
]);

String _toolText(AcpToolCall call) => _joinNonEmpty([
  call.title,
  call.name,
  call.rawInput,
  call.rawOutput,
  for (final location in call.locations) location.path,
  for (final diff in call.diffs) ...[diff.path, diff.unifiedDiff],
  for (final resource in call.resources) ...[
    resource.displayName,
    resource.text,
  ],
]);

String _withoutDataUris(String text) =>
    text.contains('data:') ? text.replaceAll(_dataUriPattern, 'data:…') : text;

String _joinNonEmpty(Iterable<String?> values) =>
    values.whereType<String>().where((value) => value.isNotEmpty).join('\n');

AcpTranscriptSnippet _buildSnippet(String text, int start, int length) {
  final safeStart = start.clamp(0, text.length);
  final safeEnd = (start + length).clamp(safeStart, text.length);
  final beforeStart = (safeStart - _snippetLeadingChars).clamp(0, safeStart);
  final afterEnd = (safeEnd + _snippetTrailingChars).clamp(
    safeEnd,
    text.length,
  );
  var before = _collapse(text.substring(beforeStart, safeStart));
  var after = _collapse(text.substring(safeEnd, afterEnd));
  if (beforeStart > 0) before = '…${before.trimLeft()}';
  if (afterEnd < text.length) after = '${after.trimRight()}…';
  return AcpTranscriptSnippet(
    before: before.trimLeft(),
    match: _collapse(text.substring(safeStart, safeEnd)),
    after: after.trimRight(),
  );
}

String _collapse(String value) => value.replaceAll(_whitespaceRun, ' ');
