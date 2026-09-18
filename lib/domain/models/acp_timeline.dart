import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_attachment.dart';
import 'acp_content.dart';
import 'acp_json.dart';
import 'acp_updates.dart';

/// Bounds applied to a single session's in-memory [AcpTimeline].
///
/// These limits exist purely to cap memory: a long-running or replayed
/// session must never grow its in-memory timeline without bound. When a limit
/// is reached, the oldest entries are dropped and/or the largest payloads are
/// truncated; [AcpTimeline.overflowed] is set so the UI can show a safe,
/// content-free "earlier history was trimmed" state.
@immutable
final class AcpTimelineLimits {
  /// Creates timeline limits.
  const AcpTimelineLimits({
    this.maxEntries = 500,
    this.maxEntryBytes = 512 * 1024,
    this.maxRetainedImageBytes = kAcpAttachmentImageDisplayMaxBytes,
    this.maxTotalBytes = 16 * 1024 * 1024,
  }) : assert(maxRetainedImageBytes >= 0);

  /// Maximum retained timeline entries. Oldest entries are dropped first.
  final int maxEntries;

  /// Maximum approximate bytes retained for a single entry's content.
  ///
  /// Applies independently of [maxTotalBytes] so one oversized message or
  /// tool payload cannot be retained in full even when the timeline overall
  /// is otherwise small.
  final int maxEntryBytes;

  /// Maximum decoded bytes of inline images protected within one message.
  ///
  /// Image payloads are already bounded by the attachment and decoder safety
  /// ceiling. Keeping that separate budget prevents an ordinary pasted
  /// screenshot from being replaced by a text-only memory marker.
  final int maxRetainedImageBytes;

  /// Maximum approximate total bytes retained across the whole timeline.
  final int maxTotalBytes;
}

/// Role of a streamed ACP message in the domain timeline.
String? _claudeParentToolUseId(Map<String, Object?> meta) {
  final claude = meta['claudeCode'];
  if (claude is! Map) {
    return null;
  }
  final value = claude['parentToolUseId'];
  return value is String &&
          value.isNotEmpty &&
          value.length <= acpMaxIdentifierCharacters
      ? value
      : null;
}

bool _claudeSubagent(Map<String, Object?> meta) {
  final claude = meta['claudeCode'];
  return claude is Map && claude['subagent'] == true;
}

/// Role of a streamed ACP message in the domain timeline.
enum AcpMessageRole {
  /// A prompt authored by the user.
  user,

  /// A response authored by the agent.
  agent,

  /// The agent's reasoning or "thinking" output.
  thought,
}

/// One entry in the normalized domain timeline for a single ACP session.
///
/// Timeline entries are an in-memory, presentation-independent normalization
/// of streamed ACP updates. They deliberately expose raw content blocks and
/// tool data so a later presentation layer can map them, but they are never
/// persisted or written to diagnostics.
@immutable
sealed class AcpTimelineEntry {
  const AcpTimelineEntry();

  /// Monotonic index describing arrival order within the timeline.
  int get order;
}

/// A user, agent, or thought message assembled from one or more streamed
/// content chunks that share a message identifier.
@immutable
final class AcpMessageEntry extends AcpTimelineEntry {
  /// Creates a message entry.
  ///
  /// [content] is defensively copied into an unmodifiable list so a caller can
  /// never mutate this entry after construction.
  AcpMessageEntry({
    required this.role,
    required this.order,
    this.messageId,
    this.parentToolCallId,
    this.queued = false,
    List<AcpContentBlock> content = const <AcpContentBlock>[],
  }) : content = List<AcpContentBlock>.unmodifiable(content);

  /// Message role.
  final AcpMessageRole role;

  @override
  final int order;

  /// Identifier grouping streamed chunks into a single message, when present.
  final String? messageId;

  /// Launching tool call for a nested subagent transcript, when present.
  final String? parentToolCallId;

  /// Whether this local user prompt is waiting behind an active turn.
  final bool queued;

  /// Ordered content blocks accumulated for this message.
  final List<AcpContentBlock> content;

  /// Returns a copy with [block] appended to [content].
  AcpMessageEntry appendContent(AcpContentBlock block) => AcpMessageEntry(
    role: role,
    order: order,
    messageId: messageId,
    parentToolCallId: parentToolCallId,
    queued: queued,
    content: [...content, block],
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpMessageEntry &&
          role == other.role &&
          order == other.order &&
          messageId == other.messageId &&
          parentToolCallId == other.parentToolCallId &&
          queued == other.queued &&
          const ListEquality<AcpContentBlock>().equals(content, other.content);

  @override
  int get hashCode => Object.hash(
    role,
    order,
    messageId,
    parentToolCallId,
    queued,
    const ListEquality<AcpContentBlock>().hash(content),
  );
}

/// A single tool call assembled by merging its initial `tool_call` update with
/// every later `tool_call_update` that shares the same tool-call identifier.
@immutable
final class AcpToolCallEntry extends AcpTimelineEntry {
  /// Creates a tool-call entry.
  AcpToolCallEntry({
    required this.toolCallId,
    required this.order,
    this.title,
    this.toolKind,
    this.status,
    List<AcpToolContent> content = const <AcpToolContent>[],
    List<AcpToolLocation> locations = const <AcpToolLocation>[],
    this.rawInput,
    this.rawOutput,
    this.parentToolCallId,
    this.isSubagent = false,
  }) : content = List<AcpToolContent>.unmodifiable(content),
       locations = List<AcpToolLocation>.unmodifiable(locations);

  /// Tool-call identifier.
  final String toolCallId;

  @override
  final int order;

  /// Latest known title.
  final String? title;

  /// Latest known tool kind.
  final AcpToolKind? toolKind;

  /// Latest known status.
  final AcpToolStatus? status;

  /// Latest known content payloads.
  final List<AcpToolContent> content;

  /// Latest known associated file locations.
  final List<AcpToolLocation> locations;

  /// Latest opaque raw input.
  final Object? rawInput;

  /// Latest opaque raw output.
  final Object? rawOutput;

  /// Launching tool call for a nested subagent update, when present.
  final String? parentToolCallId;

  /// Whether this tool launches a nested subagent transcript.
  final bool isSubagent;

  /// Returns a copy with the non-null fields of [update] merged in.
  ///
  /// Content, locations, input, and output are treated as complete
  /// replacements per the ACP tool-call-update semantics; unspecified fields
  /// retain their previous value.
  AcpToolCallEntry merge(AcpToolCallUpdate update) => AcpToolCallEntry(
    toolCallId: toolCallId,
    order: order,
    title: update.title ?? title,
    toolKind: update.toolKind ?? toolKind,
    status: update.status ?? status,
    content: update.content == null
        ? content
        : List<AcpToolContent>.unmodifiable(update.content!),
    locations: update.locations == null
        ? locations
        : List<AcpToolLocation>.unmodifiable(update.locations!),
    rawInput: update.rawInput ?? rawInput,
    rawOutput: update.rawOutput ?? rawOutput,
    parentToolCallId: _claudeParentToolUseId(update.meta) ?? parentToolCallId,
    isSubagent: isSubagent || _claudeSubagent(update.meta),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpToolCallEntry &&
          toolCallId == other.toolCallId &&
          order == other.order &&
          title == other.title &&
          toolKind == other.toolKind &&
          status == other.status &&
          rawInput == other.rawInput &&
          rawOutput == other.rawOutput &&
          parentToolCallId == other.parentToolCallId &&
          isSubagent == other.isSubagent &&
          const ListEquality<AcpToolContent>().equals(content, other.content) &&
          const ListEquality<AcpToolLocation>().equals(
            locations,
            other.locations,
          );

  @override
  int get hashCode => Object.hash(
    toolCallId,
    order,
    title,
    toolKind,
    status,
    rawInput,
    rawOutput,
    parentToolCallId,
    isSubagent,
    const ListEquality<AcpToolContent>().hash(content),
    const ListEquality<AcpToolLocation>().hash(locations),
  );
}

/// Immutable snapshot of a session's normalized in-memory timeline.
@immutable
final class AcpTimeline {
  /// Creates a timeline from [entries], defensively copied into an
  /// unmodifiable list.
  AcpTimeline({
    List<AcpTimelineEntry> entries = const <AcpTimelineEntry>[],
    this.overflowed = false,
    this.droppedEntryCount = 0,
  }) : entries = List<AcpTimelineEntry>.unmodifiable(entries);

  /// Creates the shared empty timeline.
  const AcpTimeline.empty()
    : entries = const <AcpTimelineEntry>[],
      overflowed = false,
      droppedEntryCount = 0;

  /// Ordered timeline entries.
  final List<AcpTimelineEntry> entries;

  /// Whether bounded-memory limits ever dropped or truncated content for this
  /// session. Once set, this stays `true` for the life of the session: the
  /// dropped history can never be safely reconstructed.
  final bool overflowed;

  /// Cumulative number of oldest entries dropped to stay within limits.
  final int droppedEntryCount;

  /// Whether the timeline currently holds no entries.
  bool get isEmpty => entries.isEmpty;

  /// Number of entries.
  int get length => entries.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpTimeline &&
          overflowed == other.overflowed &&
          droppedEntryCount == other.droppedEntryCount &&
          const ListEquality<AcpTimelineEntry>().equals(entries, other.entries);

  @override
  int get hashCode => Object.hash(
    overflowed,
    droppedEntryCount,
    const ListEquality<AcpTimelineEntry>().hash(entries),
  );
}

/// A content block was too large to retain in full; a small marker replaces
/// the truncated portion so the timeline stays within its byte budget.
const _truncationMarkerText = '\n… (truncated to stay within memory limits)';

final Expando<int> _contentBlockByteCache = Expando<int>(
  'ACP content block approximate bytes',
);

/// Approximates the retained byte footprint of [block].
///
/// This is only used to bound memory, not for wire transfer. Large image
/// payloads are measured directly; other blocks use their JSON encoding. Since
/// immutable blocks are shared by every successive streaming-message copy, the
/// weak identity cache prevents re-encoding all prior chunks on every append.
int approximateContentBlockBytes(AcpContentBlock block) {
  final cached = _contentBlockByteCache[block];
  if (cached != null) return cached;
  final bytes = switch (block) {
    // Base64 image data is ASCII. Avoid materializing another multi-megabyte
    // JSON string solely to estimate images this timeline already retains.
    AcpImageContent() =>
      block.data.length +
          utf8.encode(block.mimeType).length +
          utf8.encode(block.uri ?? '').length +
          _approximateJsonBytes(block.annotations?.toJson()) +
          _approximateJsonBytes(block.meta) +
          _approximateJsonBytes(block.extensions) +
          256,
    _ => _encodedContentBlockBytes(block),
  };
  _contentBlockByteCache[block] = bytes;
  return bytes;
}

int _encodedContentBlockBytes(AcpContentBlock block) {
  try {
    return utf8.encode(jsonEncode(block.toJson())).length;
  } on Object {
    return 256;
  }
}

int _approximateToolContentBytes(AcpToolContent content) =>
    _approximateJsonBytes(content.meta) +
    _approximateJsonBytes(content.extensions) +
    switch (content) {
      AcpToolContentBlock(:final content) => approximateContentBlockBytes(
        content,
      ),
      AcpToolDiff(:final path, :final oldText, :final newText) =>
        utf8.encode(path).length +
            utf8.encode(oldText ?? '').length +
            utf8.encode(newText).length,
      AcpToolTerminal(:final terminalId) => terminalId.length + 16,
      AcpUnknownToolContent(:final raw) => _approximateJsonBytes(raw),
    };

int _approximateJsonBytes(Object? value) {
  try {
    return utf8.encode(jsonEncode(value)).length;
  } on Object {
    return 256;
  }
}

int _approximateMessageBytes(AcpMessageEntry entry) =>
    (entry.messageId?.length ?? 0) +
    (entry.parentToolCallId?.length ?? 0) +
    entry.content.fold<int>(
      0,
      (total, block) => total + approximateContentBlockBytes(block),
    );

int _approximateToolLocationBytes(AcpToolLocation location) =>
    utf8.encode(location.path).length +
    32 +
    _approximateJsonBytes(location.meta) +
    _approximateJsonBytes(location.extensions);

int _approximateToolCallBytes(AcpToolCallEntry entry) =>
    entry.toolCallId.length +
    (entry.parentToolCallId?.length ?? 0) +
    utf8.encode(entry.title ?? '').length +
    entry.content.fold<int>(
      0,
      (total, content) => total + _approximateToolContentBytes(content),
    ) +
    entry.locations.fold<int>(
      0,
      (total, location) => total + _approximateToolLocationBytes(location),
    ) +
    _approximateJsonBytes(entry.rawInput) +
    _approximateJsonBytes(entry.rawOutput);

/// Approximates the retained byte footprint of one timeline entry.
int approximateTimelineEntryBytes(AcpTimelineEntry entry) => switch (entry) {
  AcpMessageEntry() => _approximateMessageBytes(entry),
  AcpToolCallEntry() => _approximateToolCallBytes(entry),
};

/// Truncates the text of [block] to at most [maxBytes] UTF-8 bytes, appending
/// a safe marker. Non-text blocks are replaced by a small placeholder because
/// their binary payload cannot be partially truncated safely.
AcpContentBlock _truncatedContentBlock(AcpContentBlock block, int maxBytes) {
  if (block is AcpTextContent) {
    final bytes = utf8.encode(block.text);
    final minimal = AcpTextContent(block.text);
    if (approximateContentBlockBytes(minimal) <= maxBytes) return minimal;
    final markerBytes = approximateContentBlockBytes(
      const AcpTextContent(_truncationMarkerText),
    );
    var keep = math.min(bytes.length, math.max(0, maxBytes - markerBytes));
    while (true) {
      final truncated = AcpTextContent(
        utf8.decode(bytes.sublist(0, keep), allowMalformed: true) +
            _truncationMarkerText,
      );
      final excess = approximateContentBlockBytes(truncated) - maxBytes;
      if (excess <= 0 || keep == 0) return truncated;
      keep = math.max(0, keep - excess);
    }
  }
  return const AcpTextContent('[content omitted to stay within memory limits]');
}

/// Incrementally builds an [AcpTimeline] from streamed ACP session updates.
///
/// The builder groups user/agent/thought content chunks by message identifier
/// and merges tool calls by tool-call identifier while preserving first-seen
/// ordering. It only handles the content-bearing updates; session-scoped
/// updates such as plans, usage, commands, and configuration are tracked on
/// [AcpSessionState] instead. Unknown updates are ignored so forward-compatible
/// protocol data never corrupts the timeline.
class AcpTimelineBuilder {
  /// Creates a timeline builder bounded by [limits].
  AcpTimelineBuilder({AcpTimelineLimits limits = const AcpTimelineLimits()})
    : _limits = limits;

  final AcpTimelineLimits _limits;
  final List<AcpTimelineEntry> _entries = <AcpTimelineEntry>[];
  final Map<String, int> _toolCallIndex = <String, int>{};
  int _nextOrder = 0;
  int? _openMessageIndex;
  int _totalBytes = 0;
  bool _overflowed = false;
  int _droppedEntryCount = 0;
  int _nextLocalUserMessageId = 0;
  String? _pendingLocalUserMessageId;
  bool _suppressingUserEcho = false;
  String? _suppressedUserEchoMessageId;

  /// Appends a locally submitted user prompt so it is visible immediately even
  /// when the ACP provider does not echo user messages.
  ///
  /// Returns the local message identifier used by [removeLocalUserPrompt] if
  /// submission fails.
  String appendLocalUserPrompt(
    List<AcpContentBlock> content, {
    bool queued = false,
  }) {
    final messageId = 'monkeyssh-user-${_nextLocalUserMessageId++}';
    final entry = _boundedMessageEntry(
      AcpMessageEntry(
        role: AcpMessageRole.user,
        order: _nextOrder++,
        messageId: messageId,
        queued: queued,
        content: content,
      ),
    );
    _totalBytes += approximateTimelineEntryBytes(entry);
    _entries.add(entry);
    _openMessageIndex = null;
    if (!queued) {
      _clearPendingUserEcho();
      _pendingLocalUserMessageId = messageId;
    }
    _enforceLimits();
    return messageId;
  }

  /// Marks a queued local prompt as dispatched to the agent.
  AcpTimeline markLocalUserPromptDispatched(String messageId) {
    _clearPendingUserEcho();
    _pendingLocalUserMessageId = messageId;
    final index = _entries.indexWhere(
      (entry) =>
          entry is AcpMessageEntry &&
          entry.messageId == messageId &&
          entry.role == AcpMessageRole.user,
    );
    if (index >= 0) {
      final entry = _entries[index] as AcpMessageEntry;
      _replaceEntry(
        index,
        AcpMessageEntry(
          role: entry.role,
          order: entry.order,
          messageId: entry.messageId,
          parentToolCallId: entry.parentToolCallId,
          content: entry.content,
        ),
      );
    }
    return snapshot();
  }

  /// Removes the optimistic prompt identified by [messageId] after submission
  /// fails, preserving any unrelated streamed entries.
  AcpTimeline removeLocalUserPrompt(String messageId) {
    final index = _entries.indexWhere(
      (entry) =>
          entry is AcpMessageEntry &&
          entry.role == AcpMessageRole.user &&
          entry.messageId == messageId,
    );
    if (index >= 0) {
      _totalBytes -= approximateTimelineEntryBytes(_entries.removeAt(index));
      _rebuildIndexes();
    }
    if (_pendingLocalUserMessageId == messageId) {
      _clearPendingUserEcho();
    }
    return snapshot();
  }

  /// Applies [update], returning an immutable snapshot when the timeline
  /// changed, or `null` when [update] does not affect the timeline.
  ///
  /// A caller accumulating an unpublished replay can set [createSnapshot] to
  /// false and call [snapshot] once at its publication boundary. This avoids
  /// copying the growing bounded entry list for every historical wire chunk.
  AcpTimeline? apply(AcpSessionUpdate update, {bool createSnapshot = true}) {
    switch (update) {
      case AcpContentChunkUpdate():
        _applyContentChunk(update);
        _enforceLimits();
        return createSnapshot ? snapshot() : null;
      case AcpToolCallUpdate():
        _applyToolCall(update);
        _enforceLimits();
        return createSnapshot ? snapshot() : null;
      // Session-scoped updates are normalized on the session state, not here.
      case AcpPlanUpdate():
      case AcpAvailableCommandsUpdate():
      case AcpCurrentModeUpdate():
      case AcpCurrentModelUpdate():
      case AcpConfigOptionsUpdate():
      case AcpSessionInfoUpdate():
      case AcpUsageUpdate():
      case AcpUnknownSessionUpdate():
        return null;
    }
  }

  /// Returns an immutable snapshot of the current timeline.
  AcpTimeline snapshot() => AcpTimeline(
    entries: _entries,
    overflowed: _overflowed,
    droppedEntryCount: _droppedEntryCount,
  );

  void _applyContentChunk(AcpContentChunkUpdate update) {
    final role = _roleFor(update.kind);
    if (role == null) return;
    final messageId = update.messageId;
    final parentToolCallId = _claudeParentToolUseId(update.meta);
    final block = update.content;
    if (role == AcpMessageRole.user && _shouldSuppressUserEcho(messageId)) {
      return;
    }
    if (role != AcpMessageRole.user) {
      _clearPendingUserEcho();
    }

    // Append to the currently open message when the role matches and either
    // both message IDs are absent (a single unlabeled streaming message) or
    // the IDs are identical.
    final openIndex = _openMessageIndex;
    if (openIndex != null && openIndex < _entries.length) {
      final open = _entries[openIndex];
      if (open is AcpMessageEntry &&
          open.role == role &&
          open.messageId == messageId &&
          ((messageId != null && parentToolCallId == null) ||
              open.parentToolCallId == parentToolCallId)) {
        _replaceEntry(openIndex, open.appendContent(block));
        return;
      }
    }

    // Otherwise reuse the most recent same-role entry that shares a non-null
    // message ID, even if other entries have been appended since.
    if (messageId != null) {
      for (var i = _entries.length - 1; i >= 0; i--) {
        final entry = _entries[i];
        if (entry is AcpMessageEntry &&
            entry.role == role &&
            entry.messageId == messageId &&
            (parentToolCallId == null ||
                entry.parentToolCallId == parentToolCallId)) {
          _replaceEntry(i, entry.appendContent(block));
          _openMessageIndex = i;
          return;
        }
      }
    }

    final entry = _boundedMessageEntry(
      AcpMessageEntry(
        role: role,
        order: _nextOrder++,
        messageId: messageId,
        parentToolCallId: parentToolCallId,
        content: [block],
      ),
    );
    _totalBytes += approximateTimelineEntryBytes(entry);
    _entries.add(entry);
    _openMessageIndex = _entries.length - 1;
  }

  void _applyToolCall(AcpToolCallUpdate update) {
    if (update.toolCallId.isEmpty) return;
    _clearPendingUserEcho();
    final existingIndex = _toolCallIndex[update.toolCallId];
    if (existingIndex != null && existingIndex < _entries.length) {
      final existing = _entries[existingIndex];
      if (existing is AcpToolCallEntry) {
        _replaceEntry(existingIndex, existing.merge(update));
        return;
      }
    }
    final order = _nextOrder++;
    final entry = _boundedToolCall(
      AcpToolCallEntry(
        toolCallId: update.toolCallId,
        order: order,
      ).merge(update),
    );
    _toolCallIndex[update.toolCallId] = _entries.length;
    _totalBytes += approximateTimelineEntryBytes(entry);
    _entries.add(entry);
    // A tool call interrupts any open streaming message.
    _openMessageIndex = null;
  }

  void _replaceEntry(int index, AcpTimelineEntry updated) {
    _totalBytes -= approximateTimelineEntryBytes(_entries[index]);
    final bounded = switch (updated) {
      AcpToolCallEntry() => _boundedToolCall(updated),
      AcpMessageEntry() => _boundedMessageEntry(updated),
    };
    _totalBytes += approximateTimelineEntryBytes(bounded);
    _entries[index] = bounded;
  }

  /// Bounds a single message entry's own accumulated size to
  /// [AcpTimelineLimits.maxEntryBytes], regardless of how many streamed
  /// chunks (potentially thousands, all sharing one message id) were merged
  /// into it.
  ///
  /// A per-chunk check alone is not enough: many small chunks that each stay
  /// under the cap can still accumulate without bound onto the same open
  /// message. This drops the oldest content blocks within the message first
  /// (preserving the most recent, most useful context, mirroring how the
  /// whole timeline drops its oldest entries), then truncates a single
  /// remaining oversized block as a last resort.
  AcpMessageEntry _boundedMessageEntry(AcpMessageEntry entry) {
    final protectedImages = _protectedTimelineImages(
      entry.content,
      _limits.maxRetainedImageBytes,
    );
    int byteLimit(Iterable<AcpContentBlock> content) => math.min(
      _limits.maxTotalBytes,
      _limits.maxEntryBytes +
          content.whereType<AcpImageContent>().fold<int>(
            0,
            (sum, block) =>
                sum + (protectedImages.contains(block) ? block.data.length : 0),
          ),
    );
    if (_approximateMessageBytes(entry) <= byteLimit(entry.content)) {
      return entry;
    }
    _overflowed = true;
    final content = List<AcpContentBlock>.of(entry.content);
    var total = _approximateMessageBytes(entry);
    while (content.isNotEmpty && total > byteLimit(content)) {
      final unprotected = <int>[
        for (var index = 0; index < content.length; index++)
          if (!protectedImages.contains(content[index])) index,
      ];
      if (content.length > 1 && unprotected.length != 1) {
        final index = unprotected.isEmpty ? 0 : unprotected.first;
        total -= approximateContentBlockBytes(content.removeAt(index));
        continue;
      }
      final index = unprotected.isEmpty ? 0 : unprotected.single;
      final block = content[index];
      final otherBytes = total - approximateContentBlockBytes(block);
      final replacement = _truncatedContentBlock(
        block,
        math.max(0, byteLimit(content) - otherBytes),
      );
      content[index] = replacement;
      total = otherBytes + approximateContentBlockBytes(replacement);
      // Keep a bounded explanation even when a synthetic limit cannot fit
      // the marker itself. Otherwise continue if image metadata still exceeds
      // the ordinary budget after the unprotected content was trimmed.
      if (content.length == 1 || total <= byteLimit(content)) break;
      if (approximateContentBlockBytes(replacement) >=
          approximateContentBlockBytes(block)) {
        total -= approximateContentBlockBytes(content.removeAt(index));
      }
    }
    return AcpMessageEntry(
      role: entry.role,
      order: entry.order,
      messageId: entry.messageId,
      parentToolCallId: entry.parentToolCallId,
      queued: entry.queued,
      content: content,
    );
  }

  Set<AcpImageContent> _protectedTimelineImages(
    List<AcpContentBlock> content,
    int decodedByteBudget,
  ) {
    var remaining = decodedByteBudget;
    final protected = <AcpImageContent>{};
    for (final block in content.reversed) {
      if (block is! AcpImageContent || block.data.isEmpty) continue;
      final decodedBytes = _approximateBase64DecodedBytes(block.data);
      if (decodedBytes <= 0 || decodedBytes > remaining) continue;
      protected.add(block);
      remaining -= decodedBytes;
    }
    return protected;
  }

  int _approximateBase64DecodedBytes(String encoded) {
    var padding = 0;
    if (encoded.endsWith('==')) {
      padding = 2;
    } else if (encoded.endsWith('=')) {
      padding = 1;
    }
    return ((encoded.length * 3) ~/ 4) - padding;
  }

  /// Truncates a merged tool-call entry so its retained payload stays under
  /// [AcpTimelineLimits.maxEntryBytes].
  AcpToolCallEntry _boundedToolCall(AcpToolCallEntry entry) {
    final budget = math.min(_limits.maxEntryBytes, _limits.maxTotalBytes);
    if (_approximateToolCallBytes(entry) <= budget) {
      return entry;
    }
    _overflowed = true;
    final rawInput = entry.rawInput == null ? null : const {'_truncated': true};
    final rawOutput = entry.rawOutput == null
        ? null
        : const {'_truncated': true};
    var remaining = math.max(
      0,
      budget -
          entry.toolCallId.length -
          (entry.parentToolCallId?.length ?? 0) -
          _approximateJsonBytes(rawInput) -
          _approximateJsonBytes(rawOutput),
    );
    var title = entry.title;
    if (title != null) {
      final titleBudget = math.min(remaining, 256);
      if (utf8.encode(title).length > titleBudget) {
        title = String.fromCharCodes(title.runes.take(titleBudget ~/ 4));
      }
      remaining -= utf8.encode(title).length;
    }
    final locations = <AcpToolLocation>[];
    for (final location in entry.locations) {
      final bytes = _approximateToolLocationBytes(location);
      if (bytes > remaining) continue;
      locations.add(location);
      remaining -= bytes;
    }
    return AcpToolCallEntry(
      toolCallId: entry.toolCallId,
      order: entry.order,
      title: title,
      toolKind: entry.toolKind,
      status: entry.status,
      locations: locations,
      rawInput: rawInput,
      rawOutput: rawOutput,
      parentToolCallId: entry.parentToolCallId,
      isSubagent: entry.isSubagent,
    );
  }

  /// Drops the oldest entries so the timeline stays within its entry-count
  /// and total-byte budgets, preserving the most recent context.
  void _enforceLimits() {
    var droppedThisCall = false;
    while (_entries.length > _limits.maxEntries ||
        (_totalBytes > _limits.maxTotalBytes && _entries.length > 1)) {
      final dropped = _entries.removeAt(0);
      _totalBytes -= approximateTimelineEntryBytes(dropped);
      _droppedEntryCount++;
      _overflowed = true;
      droppedThisCall = true;
    }
    if (droppedThisCall) {
      _rebuildIndexes();
    }
  }

  void _rebuildIndexes() {
    _toolCallIndex.clear();
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry is AcpToolCallEntry) {
        _toolCallIndex[entry.toolCallId] = i;
      }
    }
    _openMessageIndex = _entries.isEmpty || _entries.last is! AcpMessageEntry
        ? null
        : _entries.length - 1;
    final pendingId = _pendingLocalUserMessageId;
    if (pendingId != null &&
        !_entries.whereType<AcpMessageEntry>().any(
          (entry) => entry.messageId == pendingId,
        )) {
      _clearPendingUserEcho();
    }
  }

  bool _shouldSuppressUserEcho(String? remoteMessageId) {
    if (_pendingLocalUserMessageId == null) {
      return false;
    }
    if (!_suppressingUserEcho) {
      _suppressingUserEcho = true;
      _suppressedUserEchoMessageId = remoteMessageId;
      return true;
    }
    if (_suppressedUserEchoMessageId == remoteMessageId) {
      return true;
    }
    _clearPendingUserEcho();
    return false;
  }

  void _clearPendingUserEcho() {
    _pendingLocalUserMessageId = null;
    _suppressingUserEcho = false;
    _suppressedUserEchoMessageId = null;
  }

  static AcpMessageRole? _roleFor(String kind) => switch (kind) {
    'user_message_chunk' => AcpMessageRole.user,
    'agent_message_chunk' => AcpMessageRole.agent,
    'agent_thought_chunk' => AcpMessageRole.thought,
    _ => null,
  };
}
