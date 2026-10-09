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
import 'acp_timeline.dart';
import 'acp_timeline_mapper.dart';

/// Characters of the last seen message kept to recognise it after a rebuild.
const int _markerTextPrefixChars = 48;

/// How far the user had got in a session's timeline when they left.
@immutable
final class AcpLastSeenMarker {
  const AcpLastSeenMarker._({
    required this.order,
    required this.source,
    this.toolCallId,
    this.role,
    this.messageId,
    this.textPrefix = '',
  });

  /// The newest entry of [timeline], or `null` when nothing is loaded.
  static AcpLastSeenMarker? of(d.AcpTimeline timeline) {
    final last = timeline.entries.lastOrNull;
    if (last == null) return null;
    return switch (last) {
      d.AcpToolCallEntry(:final order, :final toolCallId) =>
        AcpLastSeenMarker._(
          order: order,
          source: timeline.source,
          toolCallId: toolCallId,
        ),
      d.AcpMessageEntry(:final order, :final role, :final messageId) =>
        AcpLastSeenMarker._(
          order: order,
          source: timeline.source,
          role: role,
          messageId: messageId,
          textPrefix: _leadingText(last, _markerTextPrefixChars),
        ),
    };
  }

  /// Order of the last seen entry in the timeline it was taken from.
  final int order;

  /// The builder of that timeline; orders only compare within one source.
  final Object? source;

  /// The last seen tool call, when the last entry was one.
  final String? toolCallId;

  /// The last seen message's role, when the last entry was a message.
  final d.AcpMessageRole? role;

  /// The last seen message's identifier, when the agent sent one.
  final String? messageId;

  /// The start of the last seen message's text.
  final String textPrefix;

  /// Whether [entry] is the entry this marker was taken from, possibly grown
  /// by streaming since, as far as a rebuilt timeline can tell.
  bool matches(d.AcpTimelineEntry entry) => switch (entry) {
    d.AcpToolCallEntry(:final toolCallId) => this.toolCallId == toolCallId,
    d.AcpMessageEntry(:final role, :final messageId) =>
      toolCallId == null &&
          this.role == role &&
          // User prompts carry a local identifier until the agent echoes
          // them, so only agent and reasoning identifiers are compared.
          (role == d.AcpMessageRole.user ||
              this.messageId == null ||
              messageId == null ||
              this.messageId == messageId) &&
          _leadingText(entry, textPrefix.length) == textPrefix,
  };
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

  /// Agent replies.
  final int replies;

  /// Tool calls by kind.
  final Map<AcpToolKind, int> toolCalls;

  /// Distinct file paths that tool calls reported diffs for. Agents report
  /// changes voluntarily, so this is never a complete inventory.
  final int reportedFileChanges;

  /// Permission, write and input requests waiting for an answer now.
  final int pendingRequests;

  /// Failed tool calls, plus a current session error.
  final int errors;

  /// Whether earlier unread entries may be missing, so counts are minimums.
  final bool partial;

  /// Total tool calls.
  int get toolCallCount => toolCalls.values.fold(0, (sum, n) => sum + n);

  /// One line such as `1 error · 2 replies · 5 tool calls (3 edit, 2 run) ·
  /// 3 reported file changes`. What needs the user comes first, so it
  /// survives truncation.
  String get summary {
    final parts = <String>[
      if (pendingRequests > 0) '${_count(pendingRequests, 'request')} waiting',
      if (errors > 0) _count(errors, 'error'),
      if (replies > 0) _count(replies, 'reply', 'replies'),
      if (toolCallCount > 0) _toolSummary(),
      if (reportedFileChanges > 0)
        _count(reportedFileChanges, 'reported file change'),
    ];
    if (parts.isEmpty) return 'new activity';
    final line = parts.join(' · ');
    return partial ? 'at least $line' : line;
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
///   unread. If that entry has since been trimmed away, everything loaded is
///   unread, the divider says earlier history is not available, and the
///   digest counts are minimums.
/// - Rebuilt timeline (a reload replayed it afresh): the last seen entry is
///   looked up by tool call identifier, or by role and the start of its text.
///   If it is not there, the divider falls back to "earlier history not
///   available" at the top with no digest, because what changed is unknown.
///
/// Returns `null` when there is no marker, nothing is loaded, nothing new
/// arrived, or the user has sent a prompt since returning. [entries] is the
/// presentation mapping of [timeline].
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
    trimmed = domainEntries.first.order > marker.order;
  } else {
    for (var index = domainEntries.length - 1; index >= 0; index--) {
      if (marker.matches(domainEntries[index])) {
        anchor = domainEntries[index].order;
        break;
      }
    }
  }
  if (anchor == null) {
    return const AcpUnreadState(
      dividerEntryIndex: 0,
      earlierHistoryUnavailable: true,
      digest: null,
    );
  }

  final unread = [
    for (final entry in domainEntries)
      if (entry.order > anchor) entry,
  ];
  // A prompt sent from this device after the marker means the user is back
  // and working: what follows is their own turn, not news.
  if (unread.isEmpty ||
      unread.any(
        (entry) => entry is d.AcpMessageEntry && entry.isLocalPrompt,
      )) {
    return null;
  }
  final unreadIds = {for (final entry in unread) acpPresentationEntryId(entry)};

  int? dividerIndex;
  final counter = _DigestCounter(unreadIds);
  for (var index = 0; index < entries.length; index++) {
    if (counter.visit(entries[index]) && dividerIndex == null) {
      dividerIndex = index;
    }
  }
  if (dividerIndex == null) return null;
  return AcpUnreadState(
    dividerEntryIndex: dividerIndex,
    earlierHistoryUnavailable: trimmed,
    digest: AcpUnreadDigest(
      replies: counter.replies,
      toolCalls: Map<AcpToolKind, int>.unmodifiable(counter.toolCalls),
      reportedFileChanges: counter.changedPaths.length,
      pendingRequests: pendingRequests,
      errors: counter.failedTools + (hasSessionError ? 1 : 0),
      partial: trimmed,
    ),
  );
}

final class _DigestCounter {
  _DigestCounter(this.unreadIds);

  final Set<String> unreadIds;
  int replies = 0;
  final Map<AcpToolKind, int> toolCalls = <AcpToolKind, int>{};
  final Set<String> changedPaths = <String>{};
  int failedTools = 0;

  /// Counts [entry] and its nested entries; returns whether any is unread.
  bool visit(AcpTimelineEntry entry) {
    if (entry case AcpSubagentTranscriptEntry(:final entries)) {
      var any = false;
      for (final child in entries) {
        any = visit(child) || any;
      }
      return any;
    }
    if (!unreadIds.contains(entry.id)) return false;
    switch (entry) {
      case AcpAssistantMessageEntry(:final markdown, :final audio):
        if (markdown.trim().isNotEmpty || audio.isNotEmpty) replies++;
      case AcpToolCallEntry(:final toolCall):
        toolCalls.update(toolCall.kind, (n) => n + 1, ifAbsent: () => 1);
        for (final diff in toolCall.diffs) {
          changedPaths.add(diff.path);
        }
        if (toolCall.status == AcpToolStatus.failed) failedTools++;
      case AcpUserPromptEntry() ||
          AcpThoughtEntry() ||
          AcpPlanEntry() ||
          AcpUsageEntry() ||
          AcpStatusEntry() ||
          AcpSubagentTranscriptEntry():
        break;
    }
    return true;
  }
}

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
