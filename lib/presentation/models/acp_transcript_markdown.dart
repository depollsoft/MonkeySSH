/// Markdown export of a native agent chat's loaded transcript.
///
/// The export is built on demand from the presentation entries the thread
/// renders. It is never written to logs, diagnostics or telemetry. Sharing
/// writes it to a temporary file the share sheet can read, which the next
/// export deletes.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_session_state.dart' as d;
import 'acp_timeline.dart';

/// Most lines of one diff kept in an export. A larger diff is shortened and
/// says how many lines were left out.
const int kAcpExportMaxDiffLines = 400;

/// Why part of a conversation is missing from the loaded transcript.
enum AcpTranscriptHistoryGap {
  /// The app dropped old entries, or shortened large ones, to bound memory.
  trimmed,

  /// The host's replay buffer overflowed while reattaching.
  replayOverflow,

  /// The agent could not replay earlier messages into this view.
  unavailable,
}

/// The history gaps [session] reports for its loaded transcript.
Set<AcpTranscriptHistoryGap> acpTranscriptHistoryGaps(
  d.AcpSessionState session,
) => <AcpTranscriptHistoryGap>{
  if (session.timeline.overflowed) AcpTranscriptHistoryGap.trimmed,
  if (session.warning?.kind == d.AcpSessionErrorKind.replayOverflow)
    AcpTranscriptHistoryGap.replayOverflow,
  if (session.warning?.kind == d.AcpSessionErrorKind.historyUnavailable)
    AcpTranscriptHistoryGap.unavailable,
};

/// The conversation to export.
@immutable
final class AcpTranscriptExportSource {
  /// Creates an export source.
  const AcpTranscriptExportSource({
    required this.title,
    required this.agentLabel,
    required this.entries,
    this.historyGaps = const <AcpTranscriptHistoryGap>{},
  });

  /// The conversation title.
  final String title;

  /// The agent's display name, used for its reply headings.
  final String agentLabel;

  /// The loaded presentation timeline.
  final List<AcpTimelineEntry> entries;

  /// Reasons earlier history is missing from [entries].
  final Set<AcpTranscriptHistoryGap> historyGaps;

  /// Whether any reasoning block exists that the export could include.
  bool get hasReasoning => entries.any(_containsReasoning);

  static bool _containsReasoning(AcpTimelineEntry entry) => switch (entry) {
    AcpThoughtEntry() => true,
    AcpSubagentTranscriptEntry(:final entries) => entries.any(
      _containsReasoning,
    ),
    _ => false,
  };
}

/// A rendered Markdown export and what it contains.
@immutable
final class AcpTranscriptExport {
  /// Creates an export result.
  const AcpTranscriptExport({
    required this.markdown,
    required this.prompts,
    required this.replies,
    required this.toolCalls,
    required this.omittedAttachments,
    required this.omittedReasoning,
    required this.historyIncomplete,
  });

  /// The Markdown document.
  final String markdown;

  /// User prompts included.
  final int prompts;

  /// Agent replies included.
  final int replies;

  /// Tool calls summarised.
  final int toolCalls;

  /// Images, audio clips and attachments marked as not included.
  final int omittedAttachments;

  /// Reasoning blocks left out.
  final int omittedReasoning;

  /// Whether the export starts after the beginning of the conversation.
  final bool historyIncomplete;
}

/// Renders [source] as Markdown that reads cleanly in a GitHub issue.
///
/// Prompts and replies keep their text. Tool calls become one-line summaries
/// with any diffs as fenced patches. Reasoning is left out unless
/// [includeReasoning] is set. Images, audio and attachments are never
/// embedded; each is marked where it appeared. Missing earlier history and
/// anything else left out are stated at the top.
AcpTranscriptExport buildAcpTranscriptMarkdown(
  AcpTranscriptExportSource source, {
  bool includeReasoning = false,
  DateTime? exportedAt,
}) {
  final writer = _ExportWriter(includeReasoning: includeReasoning)
    ..writeEntries(source.entries, agentLabel: source.agentLabel);
  final header = StringBuffer();
  final agentLabel = _oneLine(source.agentLabel);
  final title = _oneLine(source.title);
  header
    ..writeln(
      '# ${title.isEmpty || title == agentLabel ? '$agentLabel chat' : title}',
    )
    ..writeln()
    ..writeln('- Agent: $agentLabel')
    ..writeln(
      '- Exported from MonkeySSH: '
      '${_formatTimestamp(exportedAt ?? DateTime.now())}',
    )
    ..writeln(
      '- ${_count(writer.prompts, 'prompt')} · '
      '${_count(writer.replies, 'reply', 'replies')} · '
      '${_count(writer.toolCalls, 'tool call')}',
    );

  final gaps = source.historyGaps;
  if (gaps.isNotEmpty) {
    header
      ..writeln()
      ..writeln(
        '> **Earlier history is missing.** ${_gapExplanation(gaps)} '
        'This export starts at the oldest message still loaded.',
      );
  }
  final reasoning = _count(writer.omittedReasoning, 'block');
  final attachments = writer.omittedAttachments == 1
      ? '1 attachment, marked where it appeared'
      : '${writer.omittedAttachments} attachments, each marked where it '
            'appeared';
  final omitted = <String>[
    if (writer.omittedReasoning > 0) 'agent reasoning ($reasoning)',
    if (writer.omittedAttachments > 0) attachments,
  ];
  if (omitted.isNotEmpty) {
    header
      ..writeln()
      ..writeln('> **Not included:** ${omitted.join('; ')}.');
  }

  final body = writer.output.toString().trim();
  final markdown = body.isEmpty
      ? '${header.toString().trimRight()}\n\n_No messages loaded._\n'
      : '${header.toString().trimRight()}\n\n---\n\n$body\n';
  return AcpTranscriptExport(
    markdown: markdown,
    prompts: writer.prompts,
    replies: writer.replies,
    toolCalls: writer.toolCalls,
    omittedAttachments: writer.omittedAttachments,
    omittedReasoning: writer.omittedReasoning,
    historyIncomplete: gaps.isNotEmpty,
  );
}

const _unavailableNote =
    'The agent couldn’t replay earlier messages into this view.';
const _replayOverflowNote =
    'The host’s replay buffer overflowed, so some earlier history never '
    'reached this device.';
const _trimmedNote =
    'Older messages were dropped, or long ones shortened, to stay within the '
    'app’s memory limit.';

String _gapExplanation(Set<AcpTranscriptHistoryGap> gaps) => [
  if (gaps.contains(AcpTranscriptHistoryGap.unavailable)) _unavailableNote,
  if (gaps.contains(AcpTranscriptHistoryGap.replayOverflow))
    _replayOverflowNote,
  if (gaps.contains(AcpTranscriptHistoryGap.trimmed)) _trimmedNote,
].join(' ');

enum _Section { none, user, agent }

final class _ExportWriter {
  _ExportWriter({required this.includeReasoning});

  final bool includeReasoning;
  final StringBuffer output = StringBuffer();
  int prompts = 0;
  int replies = 0;
  int toolCalls = 0;
  int omittedAttachments = 0;
  int omittedReasoning = 0;

  var _section = _Section.none;
  final List<String> _toolItems = <String>[];

  void writeEntries(
    List<AcpTimelineEntry> entries, {
    required String agentLabel,
  }) {
    for (final entry in entries) {
      if (entry is AcpUserPromptEntry) {
        _flushTools();
        if (_section != _Section.none) _block('---');
        _block('### You');
        _section = _Section.user;
        prompts++;
        _writePrompt(entry);
        continue;
      }
      if (entry is AcpUsageEntry ||
          (entry is AcpStatusEntry && entry.id == 'status-connection')) {
        // Context-window usage and the live connection state describe the
        // app at export time, not the conversation.
        continue;
      }
      if (entry is AcpThoughtEntry && !includeReasoning) {
        omittedReasoning++;
        continue;
      }
      if (_section != _Section.agent) {
        _flushTools();
        _block('### ${_oneLine(agentLabel)}');
        _section = _Section.agent;
      }
      _writeAgentEntry(entry, topLevel: true);
    }
    _flushTools();
  }

  /// Renders an agent-side entry: a reply, reasoning, tool call, plan,
  /// status or nested subagent transcript.
  void _writeAgentEntry(AcpTimelineEntry entry, {required bool topLevel}) {
    switch (entry) {
      case AcpToolCallEntry(:final toolCall, :final isSubagent):
        toolCalls++;
        _toolItems.add(_toolItem(toolCall, isSubagent: isSubagent));
        return;
      case AcpSubagentTranscriptEntry(:final entries):
        _flushTools();
        final nested = _ExportWriter(includeReasoning: includeReasoning);
        for (final child in entries) {
          if (child is AcpThoughtEntry && !includeReasoning) {
            nested.omittedReasoning++;
            continue;
          }
          nested._writeAgentEntry(child, topLevel: false);
        }
        nested._flushTools();
        replies += nested.replies;
        toolCalls += nested.toolCalls;
        omittedAttachments += nested.omittedAttachments;
        omittedReasoning += nested.omittedReasoning;
        final body = nested.output.toString().trim();
        _block(
          _quote(
            body.isEmpty
                ? '**Subagent transcript**'
                : '**Subagent transcript**\n\n$body',
          ),
        );
        return;
      case AcpUserPromptEntry():
        // Nested transcripts carry no user prompts.
        return;
      case AcpUsageEntry():
        return;
      case AcpAssistantMessageEntry():
      case AcpThoughtEntry():
      case AcpPlanEntry():
      case AcpStatusEntry():
        break;
    }
    _flushTools();
    switch (entry) {
      case AcpAssistantMessageEntry(
        :final markdown,
        :final audio,
        :final status,
      ):
        if (topLevel || markdown.trim().isNotEmpty) replies++;
        final text = _sanitizeMarkdown(markdown);
        if (text.isNotEmpty) _block(text);
        if (audio.isNotEmpty) {
          omittedAttachments += audio.length;
          _block(_omission(_count(audio.length, 'audio clip')));
        }
        if (status == AcpStreamStatus.streaming) {
          _block('_Still streaming when exported._');
        }
      case AcpThoughtEntry(:final markdown, :final title):
        final text = _sanitizeMarkdown(markdown);
        final label = _oneLine(title ?? '');
        _block(
          _quote(
            '**Reasoning${label.isEmpty ? '' : ': $label'}**'
            '${text.isEmpty ? '' : '\n\n$text'}',
          ),
        );
      case AcpPlanEntry(:final plan):
        final items = [for (final item in plan.items) _planItem(item)];
        _block(
          '**Plan** · ${plan.completedCount} of ${plan.totalCount} done'
          '${items.isEmpty ? '' : '\n\n${items.join('\n')}'}',
        );
      case AcpStatusEntry(:final message, :final severity, :final detail):
        final label = switch (severity) {
          AcpStatusSeverity.error => '**Error:** ',
          AcpStatusSeverity.warning => '**Note:** ',
          AcpStatusSeverity.info => '',
        };
        final extra = _oneLine(detail ?? '');
        final line = _escapeInline(
          '${_oneLine(message)}${extra.isEmpty ? '' : ' $extra'}',
        );
        _block('_$label${line}_');
      case AcpToolCallEntry():
      case AcpSubagentTranscriptEntry():
      case AcpUserPromptEntry():
      case AcpUsageEntry():
        break;
    }
  }

  void _writePrompt(AcpUserPromptEntry entry) {
    final lines = <String>[];
    for (final part in entry.parts) {
      switch (part) {
        case AcpTextPart(:final text):
          final value = _closeOpenFences(text.trimRight());
          if (value.trim().isNotEmpty) lines.add(value);
        case AcpImagePart(:final image):
          omittedAttachments++;
          lines.add(_omission('image', image.label));
        case AcpAudioPart(:final clip):
          omittedAttachments++;
          lines.add(_omission('audio clip', clip.label));
        case AcpResourcePart(:final resource):
          omittedAttachments++;
          lines.add(_omission('attachment', resource.displayName));
      }
    }
    if (lines.isEmpty) lines.add('_Empty prompt._');
    _block(lines.join('\n\n'));
    if (entry.queued) _block('_Queued; not yet sent when exported._');
  }

  String _toolItem(AcpToolCall call, {required bool isSubagent}) {
    final title = _oneLine(call.title, maxChars: 200);
    final status = switch (call.status) {
      AcpToolStatus.pending => 'pending',
      AcpToolStatus.running => 'running',
      AcpToolStatus.completed => 'completed',
      AcpToolStatus.failed => 'failed',
      AcpToolStatus.cancelled => 'cancelled',
    };
    final media = call.images.length + call.audio.length;
    final buffer = StringBuffer(
      '- ${isSubagent ? 'Subagent: ' : ''}**${_escapeInline(title)}** · $status',
    );
    if (media > 0) {
      omittedAttachments += media;
      buffer.write(
        ' · ${_count(media, 'image or audio clip', 'images and audio clips')} '
        'not included',
      );
    }
    for (final diff in call.diffs) {
      buffer
        ..write('\n\n')
        ..write(_indent(_fencedDiff(diff), '  '));
    }
    return buffer.toString();
  }

  void _flushTools() {
    if (_toolItems.isEmpty) return;
    final separated = _toolItems.any((item) => item.contains('\n'));
    _block(_toolItems.join(separated ? '\n\n' : '\n'));
    _toolItems.clear();
  }

  /// Replaces images that would embed or point at device-local data with a
  /// marker, closes any fence a truncated reply left open, and trims.
  String _sanitizeMarkdown(String markdown) {
    var text = markdown.replaceAllMapped(_markdownImage, (match) {
      var target = (match[2] ?? '').trim();
      if (target.startsWith('<') && target.endsWith('>')) {
        target = target.substring(1, target.length - 1).trim();
      }
      final scheme = Uri.tryParse(target)?.scheme.toLowerCase();
      if ((scheme == 'https' || scheme == 'http') && !target.contains(' ')) {
        return match[0]!;
      }
      omittedAttachments++;
      return _omission('image', match[1]);
    });
    if (text.contains('data:')) {
      text = text.replaceAllMapped(_inlineDataUri, (_) {
        omittedAttachments++;
        return _omission('inline data');
      });
    }
    return _closeOpenFences(text.trim());
  }

  void _block(String text) {
    if (output.isNotEmpty) output.write('\n\n');
    output.write(text.trimRight());
  }
}

String _planItem(AcpPlanItem item) {
  final mark = item.status == AcpPlanItemStatus.completed ? 'x' : ' ';
  return '- [$mark] ${_oneLine(item.title)}';
}

String _fencedDiff(AcpDiff diff) {
  final lines = diff.unifiedDiff.trimRight().split('\n');
  final kept = lines.length > kAcpExportMaxDiffLines
      ? lines.sublist(0, kAcpExportMaxDiffLines)
      : lines;
  final body = kept.join('\n');
  final fence = _backtickFence(body);
  final buffer = StringBuffer('${fence}diff\n$body\n$fence');
  if (kept.length < lines.length) {
    buffer.write(
      '\n\n_Diff shortened: ${_count(lines.length - kept.length, 'more line')} '
      'not included._',
    );
  }
  return buffer.toString();
}

/// A backtick fence longer than any backtick run in [text].
String _backtickFence(String text) {
  var longest = 0;
  var run = 0;
  for (final unit in text.codeUnits) {
    run = unit == 0x60 ? run + 1 : 0;
    if (run > longest) longest = run;
  }
  return '`' * (longest >= 3 ? longest + 1 : 3);
}

/// An inline Markdown image. The destination is either `<...>`, which may
/// hold spaces, or a run without spaces that may nest one level of balanced
/// parentheses; an optional title follows.
final RegExp _markdownImage = RegExp(
  r'!\[([^\]\n]*)\]\(\s*(<[^>\n]*>|(?:[^()\s]|\([^()\s]*\))+)'
  r'''(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)''',
);

final RegExp _inlineDataUri = RegExp(
  'data:[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]{64,}',
);

final RegExp _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// Appends a closing fence when [text] ends inside a fenced code block, so
/// a reply cut off mid-block cannot swallow the rest of the export.
///
/// Follows CommonMark: a backtick fence's info string may not contain a
/// backtick, so a line such as "```npm test``` runs it" is inline code, not
/// a fence. A closing fence has only the fence characters.
String _closeOpenFences(String text) {
  String? open;
  for (final line in text.split('\n')) {
    final match = _fenceLine.firstMatch(line);
    if (match == null) continue;
    final marker = match.group(1)!;
    final rest = match.group(2)!;
    if (open == null) {
      if (marker.startsWith('`') && rest.contains('`')) continue;
      open = marker;
    } else if (marker[0] == open[0] &&
        marker.length >= open.length &&
        rest.trim().isEmpty) {
      open = null;
    }
  }
  return open == null ? text : '$text\n$open';
}

String _omission(String kind, [String? label]) {
  final name = _oneLine(label ?? '', maxChars: 120);
  return name.isEmpty
      ? '_[$kind not included]_'
      : '_[$kind not included: ${_escapeInline(name)}]_';
}

String _quote(String text) =>
    text.split('\n').map((line) => line.isEmpty ? '>' : '> $line').join('\n');

String _indent(String text, String prefix) => text
    .split('\n')
    .map((line) => line.isEmpty ? line : '$prefix$line')
    .join('\n');

/// Escapes characters that would otherwise end emphasis or open a link in
/// short inline labels. Underscores inside words, as in `widget_test`, cannot
/// start emphasis and stay as they are.
String _escapeInline(String text) =>
    text.replaceAllMapped(_inlineSyntax, (m) => '\\${m[0]}');

final RegExp _inlineSyntax = RegExp(
  r'[\\*\[\]]|(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])',
);

String _oneLine(String value, {int maxChars = 160}) {
  final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= maxChars
      ? collapsed
      : '${collapsed.substring(0, maxChars - 1)}…';
}

String _count(int value, String singular, [String? plural]) =>
    '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';

String _formatTimestamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final local = time.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
