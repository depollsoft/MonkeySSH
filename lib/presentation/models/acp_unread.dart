/// "Unread since you left" for a native agent chat.
///
/// Everything here is built from structured timeline data; no model reads the
/// transcript. A last-seen marker lives in memory for the app run and is never
/// logged or persisted. It keeps a short prefix of the last message only so it
/// can recognise that message again after the timeline is rebuilt.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_content.dart';
import '../../domain/models/acp_timeline.dart' as d;
import '../../domain/models/acp_updates.dart' as d;
import 'acp_timeline.dart';
import 'acp_timeline_mapper.dart';

/// Characters of the last seen message kept to recognise it after a rebuild.
const int _markerTextPrefixChars = 48;

/// A shorter remembered prefix is only trusted when exactly one message of
/// the same role carries it, since "Let me" starts many replies.
const int _unambiguousPrefixChars = 16;

/// Most still-running tool calls a marker remembers, to report the ones that
/// finished or failed while the user was away.
const int _maxRunningTools = 64;

/// How far the user had got in a session's timeline when they left.
@immutable
final class AcpLastSeenMarker {
  AcpLastSeenMarker._({
    required this.order,
    required this.source,
    required this.ordinal,
    required this.hadSessionError,
    required Set<String> runningToolIds,
    this.toolCallId,
    this.role,
    this.messageId,
    this.textPrefix = '',
  }) : runningToolIds = Set<String>.unmodifiable(runningToolIds);

  /// The entry of [timeline] the user had seen up to, or `null` when nothing
  /// is loaded.
  ///
  /// That is the newest entry, or the newest at or before [upToOrder] when
  /// the user had not scrolled to the end. [hadSessionError] records whether
  /// a session error was already showing, so it is not reported as news.
  static AcpLastSeenMarker? of(
    d.AcpTimeline timeline, {
    int? upToOrder,
    bool hadSessionError = false,
  }) {
    final entries = timeline.entries;
    var index = entries.length - 1;
    if (upToOrder != null) {
      while (index >= 0 && entries[index].order > upToOrder) {
        index--;
      }
    }
    if (index < 0) return null;
    final seen = entries[index];
    final kind = _kindOf(seen);
    var ordinal = 0;
    final running = <String>[];
    for (var i = 0; i < index; i++) {
      final entry = entries[i];
      if (_kindOf(entry) == kind) ordinal++;
      if (entry case d.AcpToolCallEntry(:final toolCallId, :final status)
          when !_isTerminal(status)) {
        running.add(toolCallId);
      }
    }
    if (seen case d.AcpToolCallEntry(:final toolCallId, :final status)
        when !_isTerminal(status)) {
      running.add(toolCallId);
    }
    final tracked = running.length <= _maxRunningTools
        ? running
        : running.sublist(running.length - _maxRunningTools);
    return switch (seen) {
      d.AcpToolCallEntry(:final order, :final toolCallId) =>
        AcpLastSeenMarker._(
          order: order,
          source: timeline.source,
          ordinal: ordinal,
          hadSessionError: hadSessionError,
          runningToolIds: tracked.toSet(),
          toolCallId: toolCallId,
        ),
      d.AcpMessageEntry(:final order, :final role, :final messageId) =>
        AcpLastSeenMarker._(
          order: order,
          source: timeline.source,
          ordinal: ordinal,
          hadSessionError: hadSessionError,
          runningToolIds: tracked.toSet(),
          role: role,
          // A user prompt carries a local identifier until the agent echoes
          // it, so only agent and reasoning identifiers identify a message.
          messageId: role == d.AcpMessageRole.user ? null : messageId,
          textPrefix: _leadingText(seen, _markerTextPrefixChars),
        ),
    };
  }

  /// Order of the last seen entry in the timeline it was taken from.
  final int order;

  /// The builder of that timeline; orders only compare within one source.
  final Object? source;

  /// How many entries of the same kind (tool call, or message of the same
  /// role) came before the last seen one. Picks the nearest of several
  /// candidates in a rebuilt timeline.
  final int ordinal;

  /// Whether a session error was already showing when the user left.
  final bool hadSessionError;

  /// Tool calls that were still running when the user left.
  final Set<String> runningToolIds;

  /// The last seen tool call, when the last entry was one.
  final String? toolCallId;

  /// The last seen message's role, when the last entry was a message.
  final d.AcpMessageRole? role;

  /// The last seen agent or reasoning message's identifier, when sent.
  final String? messageId;

  /// The start of the last seen message's text.
  final String textPrefix;

  /// Where the last seen entry is in a rebuilt [entries], or `null` when it
  /// cannot be told apart from other entries.
  ///
  /// A tool call or an agent message with an identifier is found by that
  /// identifier. Otherwise a message is found by role and the start of its
  /// text: an empty start never matches, and a short one only when a single
  /// message carries it. Of several matches, the one nearest the remembered
  /// position wins, and the earlier on a tie, which errs towards showing more
  /// as unread rather than hiding it.
  int? relocateIn(List<d.AcpTimelineEntry> entries) {
    final kind = toolCallId != null ? _toolKind : role!.name;
    final byId = <(int, int)>[];
    final byPrefix = <(int, int)>[];
    final ordinals = <String, int>{};
    for (final entry in entries) {
      final entryKind = _kindOf(entry);
      final entryOrdinal = ordinals[entryKind] ?? 0;
      ordinals[entryKind] = entryOrdinal + 1;
      if (entryKind != kind) continue;
      switch (entry) {
        case d.AcpToolCallEntry(:final toolCallId):
          if (toolCallId == this.toolCallId) {
            byId.add((entry.order, entryOrdinal));
          }
        case d.AcpMessageEntry(:final messageId):
          final ownId = this.messageId;
          if (ownId != null && messageId != null) {
            if (ownId == messageId) byId.add((entry.order, entryOrdinal));
            continue;
          }
          if (textPrefix.isNotEmpty &&
              _leadingText(entry, textPrefix.length) == textPrefix) {
            byPrefix.add((entry.order, entryOrdinal));
          }
      }
    }
    final candidates = byId.isNotEmpty ? byId : byPrefix;
    if (candidates.isEmpty) return null;
    if (identical(candidates, byPrefix) &&
        candidates.length > 1 &&
        textPrefix.length < _unambiguousPrefixChars) {
      return null;
    }
    var best = candidates.first;
    for (final candidate in candidates.skip(1)) {
      if ((candidate.$2 - ordinal).abs() < (best.$2 - ordinal).abs()) {
        best = candidate;
      }
    }
    return best.$1;
  }
}

/// Whether a prompt was sent from this device since [marker] was taken from
/// a timeline: after it in the same timeline, or anywhere in a rebuilt one,
/// where every local prompt is newer than the rebuild.
bool acpPromptSentSince(AcpLastSeenMarker marker, d.AcpTimeline timeline) {
  final sameSource = identical(marker.source, timeline.source);
  return timeline.entries.any(
    (entry) =>
        entry is d.AcpMessageEntry &&
        entry.isLocalPrompt &&
        (!sameSource || entry.order > marker.order),
  );
}

/// What arrived since the user left, counted from structured data only.
@immutable
final class AcpUnreadDigest {
  /// Creates a digest.
  const AcpUnreadDigest({
    this.replies = 0,
    this.toolCalls = const <AcpToolKind, int>{},
    this.reportedFileChanges = 0,
    this.pendingRequests = 0,
    this.errors = 0,
    this.partial = false,
  });

  /// Agent turns that replied: one per run of agent replies between user
  /// prompts. Nested subagent messages are not counted.
  final int replies;

  /// Tool calls by kind, including ones that finished while the user was
  /// away.
  final Map<AcpToolKind, int> toolCalls;

  /// Distinct file paths that completed tool calls reported diffs for.
  /// Agents report changes voluntarily, so this is never a complete
  /// inventory.
  final int reportedFileChanges;

  /// Permission, write and input requests waiting for an answer now.
  final int pendingRequests;

  /// Failed tool calls, plus a session error that appeared while away.
  final int errors;

  /// Whether earlier unread entries may be missing, so the timeline counts
  /// are minimums.
  final bool partial;

  /// Total tool calls.
  int get toolCallCount => toolCalls.values.fold(0, (sum, n) => sum + n);

  /// One line such as `1 request waiting · 1 error · 2 replies · 5 tool calls
  /// (3 edit, 2 run) · 3 reported file changes`. What needs the user comes
  /// first, so it survives truncation. "at least" qualifies only the counts
  /// taken from the timeline.
  String get summary {
    final fromTimeline = <String>[
      if (errors > 0) _count(errors, 'error'),
      if (replies > 0) _count(replies, 'reply', 'replies'),
      if (toolCallCount > 0) _toolSummary(),
      if (reportedFileChanges > 0)
        _count(reportedFileChanges, 'reported file change'),
    ].join(' · ');
    final parts = <String>[
      if (pendingRequests > 0) '${_count(pendingRequests, 'request')} waiting',
      if (fromTimeline.isNotEmpty && partial)
        'at least $fromTimeline'
      else if (fromTimeline.isNotEmpty)
        fromTimeline,
    ];
    return parts.isEmpty ? 'new activity' : parts.join(' · ');
  }

  String _toolSummary() {
    final kinds = toolCalls.entries.where((entry) => entry.value > 0).toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.index.compareTo(b.key.index);
      });
    final shown = kinds
        .take(3)
        .map((entry) => '${entry.value} ${_kindLabel(entry.key)}');
    final more = kinds.length > 3 ? ', …' : '';
    return '${_count(toolCallCount, 'tool call')} (${shown.join(', ')}$more)';
  }

  @override
  bool operator ==(Object other) =>
      other is AcpUnreadDigest &&
      replies == other.replies &&
      mapEquals(toolCalls, other.toolCalls) &&
      reportedFileChanges == other.reportedFileChanges &&
      pendingRequests == other.pendingRequests &&
      errors == other.errors &&
      partial == other.partial;

  @override
  int get hashCode => Object.hash(
    replies,
    Object.hashAllUnordered(
      toolCalls.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    reportedFileChanges,
    pendingRequests,
    errors,
    partial,
  );
}

/// Where to draw the unread divider, and what to say about what is below it.
@immutable
final class AcpUnreadState {
  /// Creates an unread state.
  const AcpUnreadState({
    required this.dividerEntryIndex,
    required this.earlierHistoryUnavailable,
    required this.digest,
  });

  /// Index of the top-level presentation entry the divider sits above.
  final int dividerEntryIndex;

  /// Whether the last seen entry is no longer loaded, so the divider marks
  /// the start of the loaded history rather than where the user left off.
  final bool earlierHistoryUnavailable;

  /// What arrived since the user left, or `null` when a rebuilt timeline
  /// cannot tell.
  final AcpUnreadDigest? digest;

  @override
  bool operator ==(Object other) =>
      other is AcpUnreadState &&
      dividerEntryIndex == other.dividerEntryIndex &&
      earlierHistoryUnavailable == other.earlierHistoryUnavailable &&
      digest == other.digest;

  @override
  int get hashCode =>
      Object.hash(dividerEntryIndex, earlierHistoryUnavailable, digest);
}

/// Compares [timeline] with where the user left it.
///
/// - Same timeline as the marker: everything after the last seen entry is
///   unread. If entries after it have since been trimmed away, everything
///   loaded is unread, the divider says earlier history is not available,
///   and the timeline counts are minimums.
/// - Rebuilt timeline (a reload replayed it afresh): the last seen entry is
///   looked up with [AcpLastSeenMarker.relocateIn]. If it cannot be found,
///   the divider falls back to "earlier history not available" at the top
///   with no digest, because what changed is unknown.
///
/// Tool calls that were running when the user left and have since finished
/// or failed count too, even though they sit above the divider.
///
/// Returns `null` when there is no marker, nothing is loaded, or nothing
/// changed. [entries] is the presentation mapping of [timeline].
AcpUnreadState? computeAcpUnreadState({
  required AcpLastSeenMarker? marker,
  required d.AcpTimeline timeline,
  required List<AcpTimelineEntry> entries,
  int pendingRequests = 0,
  bool hasSessionError = false,
}) {
  final domainEntries = timeline.entries;
  if (marker == null || domainEntries.isEmpty || entries.isEmpty) return null;

  int? anchor;
  var trimmed = false;
  if (identical(marker.source, timeline.source)) {
    anchor = marker.order;
    // Losing only the last seen entry itself loses nothing unread.
    trimmed = domainEntries.first.order > marker.order + 1;
  } else {
    anchor = marker.relocateIn(domainEntries);
  }
  if (anchor == null) {
    return const AcpUnreadState(
      dividerEntryIndex: 0,
      earlierHistoryUnavailable: true,
      digest: null,
    );
  }

  final newIds = <String>{};
  final finishedIds = <String>{};
  for (final entry in domainEntries) {
    if (entry.order > anchor) {
      newIds.add(acpPresentationEntryId(entry));
    } else if (entry case d.AcpToolCallEntry(:final toolCallId, :final status)
        when _isTerminal(status) &&
            marker.runningToolIds.contains(toolCallId)) {
      finishedIds.add(acpPresentationEntryId(entry));
    }
  }
  if (newIds.isEmpty && finishedIds.isEmpty) return null;

  final counter = _DigestCounter(newIds: newIds, finishedIds: finishedIds);
  int? firstNew;
  int? firstFinished;
  for (var index = 0; index < entries.length; index++) {
    final (isNew, isFinished) = counter.visitTopLevel(entries[index]);
    if (isNew) firstNew ??= index;
    if (isFinished) firstFinished ??= index;
  }
  final dividerIndex = firstNew ?? firstFinished;
  if (dividerIndex == null) return null;
  return AcpUnreadState(
    dividerEntryIndex: dividerIndex,
    earlierHistoryUnavailable: trimmed,
    digest: AcpUnreadDigest(
      replies: counter.replies,
      toolCalls: Map<AcpToolKind, int>.unmodifiable(counter.toolCalls),
      reportedFileChanges: counter.changedPaths.length,
      pendingRequests: pendingRequests,
      errors:
          counter.failedTools +
          (hasSessionError && !marker.hadSessionError ? 1 : 0),
      partial: trimmed,
    ),
  );
}

final class _DigestCounter {
  _DigestCounter({required this.newIds, required this.finishedIds});

  final Set<String> newIds;
  final Set<String> finishedIds;
  int replies = 0;
  final Map<AcpToolKind, int> toolCalls = <AcpToolKind, int>{};
  final Set<String> changedPaths = <String>{};
  int failedTools = 0;
  var _repliedThisTurn = false;

  /// Counts top-level [entry]; returns whether it, or anything nested in it,
  /// is new or a tool call that finished while the user was away.
  (bool, bool) visitTopLevel(AcpTimelineEntry entry) {
    switch (entry) {
      case AcpUserPromptEntry():
        _repliedThisTurn = false;
        return (newIds.contains(entry.id), false);
      case AcpAssistantMessageEntry(:final markdown, :final audio):
        final isNew = newIds.contains(entry.id);
        if (isNew &&
            !_repliedThisTurn &&
            (markdown.trim().isNotEmpty || audio.isNotEmpty)) {
          replies++;
          _repliedThisTurn = true;
        }
        return (isNew, false);
      case AcpSubagentTranscriptEntry(:final entries):
        var anyNew = false;
        var anyFinished = false;
        for (final child in entries) {
          final (isNew, isFinished) = _visitNested(child);
          anyNew = anyNew || isNew;
          anyFinished = anyFinished || isFinished;
        }
        return (anyNew, anyFinished);
      case AcpToolCallEntry() ||
          AcpThoughtEntry() ||
          AcpPlanEntry() ||
          AcpUsageEntry() ||
          AcpStatusEntry():
        return _visitNested(entry);
    }
  }

  /// Counts a tool call or reasoning entry, top-level or nested in a
  /// subagent transcript; nested messages are not turns.
  (bool, bool) _visitNested(AcpTimelineEntry entry) {
    if (entry case AcpSubagentTranscriptEntry()) return visitTopLevel(entry);
    final isNew = newIds.contains(entry.id);
    final isFinished = finishedIds.contains(entry.id);
    if (entry case AcpToolCallEntry(:final toolCall) when isNew || isFinished) {
      toolCalls.update(toolCall.kind, (n) => n + 1, ifAbsent: () => 1);
      switch (toolCall.status) {
        case AcpToolStatus.failed:
          failedTools++;
        case AcpToolStatus.completed:
          for (final diff in toolCall.diffs) {
            changedPaths.add(diff.path);
          }
        case AcpToolStatus.pending ||
            AcpToolStatus.running ||
            AcpToolStatus.cancelled:
          break;
      }
    }
    return (isNew, isFinished);
  }
}

const String _toolKind = 'tool';

String _kindOf(d.AcpTimelineEntry entry) => switch (entry) {
  d.AcpToolCallEntry() => _toolKind,
  d.AcpMessageEntry(:final role) => role.name,
};

bool _isTerminal(d.AcpToolStatus? status) =>
    status == d.AcpToolStatus.completed || status == d.AcpToolStatus.failed;

String _leadingText(d.AcpTimelineEntry entry, int maxChars) {
  if (entry is! d.AcpMessageEntry || maxChars <= 0) return '';
  final buffer = StringBuffer();
  for (final block in entry.content) {
    if (block is! AcpTextContent) continue;
    buffer.write(block.text);
    if (buffer.length >= maxChars) break;
  }
  final text = buffer.toString();
  return text.length <= maxChars ? text : text.substring(0, maxChars);
}

String _kindLabel(AcpToolKind kind) => switch (kind) {
  AcpToolKind.read => 'read',
  AcpToolKind.edit => 'edit',
  AcpToolKind.delete => 'delete',
  AcpToolKind.move => 'move',
  AcpToolKind.search => 'search',
  AcpToolKind.execute => 'run',
  AcpToolKind.fetch => 'fetch',
  AcpToolKind.think => 'think',
  AcpToolKind.switchMode => 'mode',
  AcpToolKind.other => 'other',
};

String _count(int value, String singular, [String? plural]) =>
    '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';
