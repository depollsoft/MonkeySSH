/// Find-in-transcript for a native agent chat.
///
/// Matching runs over each rendered entry's whole text, so a phrase split by
/// a virtual segment boundary is still found, and every match names the exact
/// list child to scroll to. The query and the transcript are user content:
/// nothing here logs or persists either.
library;

import 'package:flutter/foundation.dart';

import '../widgets/acp_thread_projection.dart';
import 'acp_timeline.dart';

/// Most matches one search reports. When there are more, the newest ones are
/// kept, since a chat is read from the bottom.
const int kAcpTranscriptSearchMaxMatches = 999;

/// Characters of context kept before a match in its snippet.
const int _snippetLeadingChars = 32;

/// Characters of context kept after a match in its snippet.
const int _snippetTrailingChars = 96;

/// Inline base64 payloads are not searchable text: a short query would
/// otherwise match random image bytes.
final RegExp _dataUriPattern = RegExp(r'data:[^,\s)>"]*,[^\s)>"]*');

final RegExp _whitespaceRun = RegExp(r'\s+');

/// Where a transcript search match was found.
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
    required this.entryIndex,
    required _EntryText text,
    required this.start,
    required this.length,
  }) : _text = text,
       childKey = text.childKeyAt(start);

  final _EntryText _text;

  /// Index of the top-level timeline entry containing the match.
  final int entryIndex;

  /// Key of the rendered thread child where the match starts.
  final String childKey;

  /// Offset of the match in its entry's searchable text.
  final int start;

  /// Length of the match in its entry's searchable text.
  final int length;

  /// Where the match was found.
  AcpTranscriptMatchSource get source => _text.source;

  /// Identifier of the entry that renders the match. For a nested subagent
  /// entry this differs from the top-level entry at [entryIndex].
  String get entryId => _text.entryId;

  /// Context around the match, built on first use.
  late final AcpTranscriptSnippet snippet = _buildSnippet(
    _text.text,
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

  /// Matches in transcript order: the newest [kAcpTranscriptSearchMaxMatches]
  /// when there are more.
  final List<AcpTranscriptMatch> matches;

  /// Whether older occurrences exist beyond [matches].
  final bool capped;
}

/// Searchable text for a transcript, cached per immutable entry.
///
/// Holds lower-cased copies of searched text while it lives; the search
/// controller drops its index when search closes. Re-searching after new
/// output streams in only re-reads the entries that changed.
final class AcpTranscriptSearchIndex {
  final Expando<List<_EntryText>> _texts = Expando<List<_EntryText>>(
    'ACP transcript search text',
  );
  final Expando<_EntryMatches> _matches = Expando<_EntryMatches>(
    'ACP transcript search matches',
  );

  /// Finds every case-insensitive occurrence of [query] in [entries].
  ///
  /// User prompts, agent replies, reasoning, tool titles, input, output,
  /// diffs and locations, plan items and status lines are searched; inline
  /// image and audio payloads are not. Matches do not overlap and follow the
  /// thread's order, including nested subagent transcripts.
  AcpTranscriptSearchResult search(
    List<AcpTimelineEntry> entries,
    String query, {
    int maxMatches = kAcpTranscriptSearchMaxMatches,
  }) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || entries.isEmpty) {
      return AcpTranscriptSearchResult.empty;
    }
    final newestFirst = <AcpTranscriptMatch>[];
    var capped = false;
    outer:
    for (var entryIndex = entries.length - 1; entryIndex >= 0; entryIndex--) {
      final found = _matchesFor(entries, entryIndex, needle);
      for (var index = found.length - 1; index >= 0; index--) {
        if (newestFirst.length >= maxMatches) {
          capped = true;
          break outer;
        }
        final (text, foldedStart) = found[index];
        final (start, length) = text.originalRange(foldedStart, needle.length);
        newestFirst.add(
          AcpTranscriptMatch._(
            entryIndex: entryIndex,
            text: text,
            start: start,
            length: length,
          ),
        );
      }
    }
    return AcpTranscriptSearchResult(
      matches: List<AcpTranscriptMatch>.unmodifiable(newestFirst.reversed),
      capped: capped,
    );
  }

  List<(_EntryText, int)> _matchesFor(
    List<AcpTimelineEntry> entries,
    int entryIndex,
    String needle,
  ) {
    final entry = entries[entryIndex];
    final cached = _matches[entry];
    if (cached != null && cached.needle == needle) return cached.found;
    final found = <(_EntryText, int)>[];
    for (final text in _textsFor(entries, entryIndex)) {
      var from = 0;
      while (true) {
        final index = text.folded.indexOf(needle, from);
        if (index < 0) break;
        found.add((text, index));
        from = index + needle.length;
      }
    }
    _matches[entry] = _EntryMatches(needle, found);
    return found;
  }

  List<_EntryText> _textsFor(List<AcpTimelineEntry> entries, int entryIndex) {
    final entry = entries[entryIndex];
    return _texts[entry] ??= _buildEntryTexts(
      buildAcpThreadChildren(
        entries,
        startEntryIndex: entryIndex,
        endEntryIndex: entryIndex + 1,
      ),
    );
  }
}

/// Finds every case-insensitive occurrence of [query] in [entries] without
/// keeping a cache; see [AcpTranscriptSearchIndex.search].
AcpTranscriptSearchResult searchAcpTranscript(
  List<AcpTimelineEntry> entries,
  String query, {
  int maxMatches = kAcpTranscriptSearchMaxMatches,
}) => AcpTranscriptSearchIndex().search(entries, query, maxMatches: maxMatches);

final class _EntryMatches {
  const _EntryMatches(this.needle, this.found);

  final String needle;
  final List<(_EntryText, int)> found;
}

/// The whole searchable text of one rendered entry, which the thread may
/// split across several virtual segments.
final class _EntryText {
  factory _EntryText({
    required String entryId,
    required AcpTranscriptMatchSource source,
    required String text,
    required List<int> segmentStarts,
    required List<String> segmentKeys,
  }) {
    final (folded, toOriginal) = _fold(text);
    return _EntryText._(
      entryId: entryId,
      source: source,
      text: text,
      folded: folded,
      toOriginal: toOriginal,
      segmentStarts: segmentStarts,
      segmentKeys: segmentKeys,
    );
  }

  _EntryText._({
    required this.entryId,
    required this.source,
    required this.text,
    required this.folded,
    required this.toOriginal,
    required this.segmentStarts,
    required this.segmentKeys,
  });

  final String entryId;
  final AcpTranscriptMatchSource source;
  final String text;

  /// [text] lower-cased for matching.
  final String folded;

  /// Maps each offset in [folded] (and its end) to [text], when lower-casing
  /// changed lengths; `null` when the offsets already line up.
  final List<int>? toOriginal;

  final List<int> segmentStarts;
  final List<String> segmentKeys;

  /// The original-text range of a match found at [foldedStart] in [folded].
  (int, int) originalRange(int foldedStart, int foldedLength) {
    final map = toOriginal;
    if (map == null) return (foldedStart, foldedLength);
    final start = map[foldedStart];
    return (start, map[foldedStart + foldedLength] - start);
  }

  /// The key of the segment holding [offset].
  String childKeyAt(int offset) {
    var segment = 0;
    while (segment + 1 < segmentStarts.length &&
        segmentStarts[segment + 1] <= offset) {
      segment++;
    }
    return segmentKeys[segment];
  }
}

List<_EntryText> _buildEntryTexts(List<AcpThreadChild> children) {
  final texts = <_EntryText>[];
  var index = 0;
  while (index < children.length) {
    final entry = children[index].entry;
    final buffer = StringBuffer();
    final starts = <int>[];
    final keys = <String>[];
    while (index < children.length && identical(children[index].entry, entry)) {
      starts.add(buffer.length);
      keys.add(children[index].keyValue);
      buffer.write(_withoutDataUris(_segmentText(children[index])));
      index++;
    }
    final source = _sourceOf(entry);
    if (source == null || buffer.isEmpty) continue;
    texts.add(
      _EntryText(
        entryId: entry.id,
        source: source,
        text: buffer.toString(),
        segmentStarts: starts,
        segmentKeys: keys,
      ),
    );
  }
  return texts;
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

/// Lower-cases [text] for matching against a lower-cased query.
///
/// A few characters (such as `İ`) lower-case to more than one code unit.
/// Then a map from every folded offset back to [text] comes with it, so a
/// match still points at the original characters.
(String, List<int>?) _fold(String text) {
  final lower = text.toLowerCase();
  if (lower.length == text.length) return (lower, null);
  final folded = StringBuffer();
  final toOriginal = <int>[];
  var offset = 0;
  for (final rune in text.runes) {
    final original = String.fromCharCode(rune);
    final lowered = original.toLowerCase();
    for (var unit = 0; unit < lowered.length; unit++) {
      toOriginal.add(offset);
    }
    folded.write(lowered);
    offset += original.length;
  }
  toOriginal.add(offset);
  return (folded.toString(), toOriginal);
}

/// The text one rendered segment contributes. Segments of a split entry
/// concatenate back to the entry's text, so phrases across a split match.
String _segmentText(AcpThreadChild child) {
  final segment = child.userParts;
  if (segment != null) return _promptText(segment);
  final markdown = child.markdown;
  if (markdown != null) return markdown;
  return switch (child.entry) {
    AcpUserPromptEntry(:final parts) => _promptText(parts),
    AcpAssistantMessageEntry(:final markdown) => markdown,
    AcpThoughtEntry(:final title, :final markdown) => _joinNonEmpty([
      title,
      markdown,
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

String _promptText(List<AcpPromptPart> parts) => [
  for (final part in parts)
    switch (part) {
      AcpTextPart(:final text) => text,
      AcpImagePart(:final image) => '\n${image.label ?? ''}\n',
      AcpAudioPart(:final clip) => '\n${clip.label ?? ''}\n',
      AcpResourcePart(:final resource) => '\n${resource.displayName}\n',
    },
].join();

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
