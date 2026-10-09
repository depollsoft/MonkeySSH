// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart' as domain;
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/models/acp_transcript_markdown.dart';

import '../../support/fake_acp_session_manager.dart';

final _exportedAt = DateTime(2026, 10, 9, 14, 3);

AcpTranscriptExport _export(
  List<AcpTimelineEntry> entries, {
  Set<AcpTranscriptHistoryGap> gaps = const {},
  bool includeReasoning = false,
  String title = 'Fix the flaky test',
}) => buildAcpTranscriptMarkdown(
  AcpTranscriptExportSource(
    title: title,
    agentLabel: 'Claude Code',
    entries: entries,
    historyGaps: gaps,
  ),
  includeReasoning: includeReasoning,
  exportedAt: _exportedAt,
);

List<AcpTimelineEntry> _conversation() => [
  AcpUserPromptEntry(
    id: 'user-1',
    parts: [
      const AcpTextPart('Why does `widget_test` fail?'),
      AcpImagePart(AcpImageContent(uri: 'file:///tmp/s.png', label: 'shot')),
      const AcpResourcePart(AcpResourceRef(uri: '/repo/notes.txt')),
    ],
  ),
  const AcpThoughtEntry(id: 'thought-1', markdown: 'secret reasoning'),
  AcpToolCallEntry(
    id: 'tool-1',
    toolCall: AcpToolCall(
      id: 't1',
      title: 'Read pubspec.yaml',
      status: AcpToolStatus.completed,
      rawOutput: 'name: monkeyssh',
    ),
  ),
  AcpToolCallEntry(
    id: 'tool-2',
    toolCall: AcpToolCall(
      id: 't2',
      title: 'Edit lib/main.dart',
      status: AcpToolStatus.completed,
      diffs: const [
        AcpDiff(
          path: 'lib/main.dart',
          unifiedDiff:
              '--- a/lib/main.dart\n+++ b/lib/main.dart\n@@ -1 +1 @@\n'
              '-old ```\n+new',
        ),
      ],
    ),
  ),
  const AcpAssistantMessageEntry(
    id: 'agent-1',
    markdown:
        'Fixed it.\n\n![chart](data:image/png;base64,AAAA)\n\n'
        '![remote](https://example.com/a.png)\n\n```dart\nvoid main() {}',
  ),
  AcpPlanEntry(
    id: 'plan',
    plan: AcpPlan(
      items: const [
        AcpPlanItem(title: 'Find', status: AcpPlanItemStatus.completed),
        AcpPlanItem(title: 'Fix'),
      ],
    ),
  ),
  const AcpUsageEntry(id: 'usage', usage: AcpUsage(contextWindow: 100)),
  const AcpStatusEntry(
    id: 'status-connection',
    message: 'Detached from this session.',
  ),
  const AcpStatusEntry(
    id: 'status-error',
    message: 'The agent request timed out.',
    severity: AcpStatusSeverity.error,
  ),
  AcpUserPromptEntry(
    id: 'user-2',
    queued: true,
    parts: const [AcpTextPart('And the docs?')],
  ),
];

void registerAcpTranscriptMarkdownTests() {
  group('buildAcpTranscriptMarkdown', () {
    test('renders a readable header, turns and summaries', () {
      final export = _export(_conversation());
      final markdown = export.markdown;
      expect(
        markdown,
        startsWith('# Fix the flaky test\n\n- Agent: Claude Code'),
      );
      expect(markdown, contains('- Exported from MonkeySSH: 2026-10-09 14:03'));
      expect(markdown, contains('- 2 prompts · 1 reply · 2 tool calls'));
      expect(markdown, contains('### You\n\nWhy does `widget_test` fail?'));
      expect(markdown, contains('### Claude Code'));
      expect(markdown, contains('- **Read pubspec.yaml** · completed'));
      expect(
        _export([
          AcpToolCallEntry(
            id: 'tool',
            toolCall: AcpToolCall(id: 't', title: 'Run widget_test *_x_*'),
          ),
        ]).markdown,
        contains(r'- **Run widget_test \*\_x\_\*** · pending'),
      );
      // Tool output is summarised away.
      expect(markdown, isNot(contains('name: monkeyssh')));
      expect(
        markdown,
        contains('**Plan** · 1 of 2 done\n\n- [x] Find\n- [ ] Fix'),
      );
      expect(markdown, contains('_**Error:** The agent request timed out._'));
      expect(markdown, contains('_Queued; not yet sent when exported._'));
      // The live connection state and context usage are not conversation.
      expect(markdown, isNot(contains('Detached')));
      expect(export.prompts, 2);
      expect(export.toolCalls, 2);
    });

    test('fences diffs with a fence longer than any backtick run', () {
      final markdown = _export(_conversation()).markdown;
      expect(
        markdown,
        contains(
          '  ````diff\n  --- a/lib/main.dart\n  +++ b/lib/main.dart\n'
          '  @@ -1 +1 @@\n  -old ```\n  +new\n  ````',
        ),
      );
    });

    test('closes a fence a reply left open', () {
      final markdown = _export(_conversation()).markdown;
      expect(markdown, contains('```dart\nvoid main() {}\n```'));
    });

    test('does not mistake inline code at a line start for a fence', () {
      final markdown = _export([
        const AcpAssistantMessageEntry(
          id: 'a',
          markdown: '```npm test``` is the command.\n\nThen push.',
        ),
        AcpUserPromptEntry(id: 'u', parts: const [AcpTextPart('Thanks')]),
      ]).markdown;
      expect('```'.allMatches(markdown), hasLength(2));
      expect(markdown, contains('Then push.\n\n---\n\n### You'));
    });

    test('closes a fence a reply with Windows line endings left open', () {
      final markdown = _export([
        const AcpAssistantMessageEntry(
          id: 'a',
          markdown: 'Run this:\r\n```dart\r\nvoid main() {}',
        ),
      ]).markdown;
      expect(markdown, contains('void main() {}\n```'));
    });

    test(
      'omits local images with spaces or parentheses in the destination',
      () {
        final export = _export([
          const AcpAssistantMessageEntry(
            id: 'a',
            markdown:
                '![shot](<file:///tmp/ci failure.png>) '
                '![plot](/tmp/plot(1).png "Plot") '
                '![remote](<https://example.com/a.png>)',
          ),
        ]);
        expect(export.markdown, isNot(contains('file:///tmp')));
        expect(export.markdown, isNot(contains('/tmp/plot')));
        expect(export.markdown, contains('_[image not included: shot]_'));
        expect(export.markdown, contains('_[image not included: plot]_'));
        expect(export.markdown, contains('<https://example.com/a.png>'));
        expect(export.omittedAttachments, 2);
      },
    );

    test('marks omitted attachments and never embeds image data', () {
      final export = _export(_conversation());
      final markdown = export.markdown;
      expect(markdown, contains('_[image not included: shot]_'));
      expect(markdown, contains('_[attachment not included: notes.txt]_'));
      expect(markdown, contains('_[image not included: chart]_'));
      expect(markdown, contains('![remote](https://example.com/a.png)'));
      expect(markdown, isNot(contains('base64')));
      expect(markdown, isNot(contains('file:///tmp')));
      expect(export.omittedAttachments, 3);
      expect(
        markdown,
        contains('> **Not included:** agent reasoning (1 block)'),
      );
    });

    test('never embeds image data or local images pasted into a prompt', () {
      final payload = 'A' * 80;
      final export = _export([
        AcpUserPromptEntry(
          id: 'u',
          parts: [
            AcpTextPart(
              'See ![log](data:image/png;base64,$payload)\n'
              '![local](file:///Users/me/shot.png) and '
              'data:text/plain;base64,$payload\n'
              '![remote](https://example.com/a.png)',
            ),
          ],
        ),
      ]);
      final markdown = export.markdown;
      expect(markdown, isNot(contains('base64')));
      expect(markdown, isNot(contains('file:///Users')));
      expect(markdown, contains('_[image not included: log]_'));
      expect(markdown, contains('_[image not included: local]_'));
      expect(markdown, contains('![remote](https://example.com/a.png)'));
      expect(export.omittedAttachments, 3);
    });

    test('marks resources a tool returned as not included', () {
      final export = _export([
        AcpToolCallEntry(
          id: 'tool',
          toolCall: AcpToolCall(
            id: 't',
            title: 'Fetch notes',
            status: AcpToolStatus.completed,
            resources: const [
              AcpResourceRef(uri: '/repo/notes.txt', text: 'secret notes'),
            ],
          ),
        ),
      ]);
      expect(
        export.markdown,
        contains('**Fetch notes** · completed · 1 attachment not included'),
      );
      expect(export.markdown, isNot(contains('secret notes')));
      expect(export.omittedAttachments, 1);
    });

    test('excludes reasoning unless asked', () {
      expect(_export(_conversation()).markdown, isNot(contains('secret')));
      final included = _export(_conversation(), includeReasoning: true);
      expect(
        included.markdown,
        contains('> **Reasoning**\n>\n> secret reasoning'),
      );
      expect(included.omittedReasoning, 0);
      expect(included.markdown, isNot(contains('agent reasoning (')));
    });

    test('marks missing earlier history at the top', () {
      final export = _export(
        _conversation(),
        gaps: {
          AcpTranscriptHistoryGap.trimmed,
          AcpTranscriptHistoryGap.replayOverflow,
        },
      );
      expect(export.historyIncomplete, isTrue);
      final header = export.markdown.split('\n---\n').first;
      expect(header, contains('> **Earlier history is missing.**'));
      expect(header, contains('replay buffer overflowed'));
      expect(header, contains('memory limit'));
      expect(header, contains('starts at the oldest message still loaded'));
    });

    test('quotes nested subagent transcripts', () {
      final markdown = _export([
        AcpToolCallEntry(
          id: 'tool-launch',
          isSubagent: true,
          toolCall: AcpToolCall(id: 'launch', title: 'Launch helper'),
        ),
        AcpSubagentTranscriptEntry(
          id: 'subagent-launch',
          launchToolCallId: 'launch',
          entries: [
            const AcpAssistantMessageEntry(id: 'n1', markdown: 'nested reply'),
            AcpToolCallEntry(
              id: 'n2',
              toolCall: AcpToolCall(id: 'n2', title: 'Grep'),
            ),
          ],
        ),
      ]).markdown;
      expect(markdown, contains('- Subagent: **Launch helper** · pending'));
      expect(
        markdown,
        contains(
          '> **Subagent transcript**\n>\n> nested reply\n>\n'
          '> - **Grep** · pending',
        ),
      );
    });

    test('falls back to the agent name and says when nothing is loaded', () {
      final markdown = _export(const [], title: 'Claude Code').markdown;
      expect(markdown, startsWith('# Claude Code chat'));
      expect(markdown, contains('_No messages loaded._'));
    });
  });

  group('acpTranscriptHistoryGaps', () {
    test('reads trimming and replay warnings from the session', () {
      expect(acpTranscriptHistoryGaps(fakeAcpSession()), isEmpty);
      final overflowed = fakeAcpSession(
        timeline: domain.AcpTimeline(overflowed: true),
      );
      expect(acpTranscriptHistoryGaps(overflowed), {
        AcpTranscriptHistoryGap.trimmed,
      });
      final replay = fakeAcpSession().copyWith(
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'overflow',
        ),
      );
      expect(acpTranscriptHistoryGaps(replay), {
        AcpTranscriptHistoryGap.replayOverflow,
      });
      final unavailable = fakeAcpSession().copyWith(
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.historyUnavailable,
          message: 'unavailable',
        ),
      );
      expect(acpTranscriptHistoryGaps(unavailable), {
        AcpTranscriptHistoryGap.unavailable,
      });
    });
  });
}
