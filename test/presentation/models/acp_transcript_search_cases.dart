// ignore_for_file: public_member_api_docs

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/acp_transcript_search_controller.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/models/acp_transcript_search.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_virtualization.dart';

List<AcpTimelineEntry> _transcript() => [
  AcpUserPromptEntry(
    id: 'user-1',
    parts: const [
      AcpTextPart('Why does the Widget fail?'),
      AcpResourcePart(AcpResourceRef(uri: '/repo/widget_spec.md')),
    ],
  ),
  const AcpThoughtEntry(id: 'thought-1', markdown: 'Check the widget tree'),
  AcpToolCallEntry(
    id: 'tool-1',
    toolCall: AcpToolCall(
      id: 't1',
      title: 'Run flutter test',
      status: AcpToolStatus.failed,
      rawInput: 'flutter test test/widget_test.dart',
      rawOutput: 'Expected: widget found',
      diffs: const [
        AcpDiff(
          path: 'lib/main.dart',
          unifiedDiff: '--- a/lib/main.dart\n+++ b/lib/main.dart\n+widget',
        ),
      ],
    ),
  ),
  const AcpAssistantMessageEntry(
    id: 'agent-1',
    markdown: 'The widget is missing. ![shot](data:image/png;base64,d2lkZ2V0d2lkZ2V0)',
  ),
  AcpPlanEntry(
    id: 'plan',
    plan: AcpPlan(items: const [AcpPlanItem(title: 'Fix the widget')]),
  ),
  const AcpStatusEntry(id: 'status-stop', message: 'Widget turn ended'),
];

void registerAcpTranscriptSearchTests() {
  group('searchAcpTranscript', () {
    test('finds every content type, case-insensitively, in order', () {
      final result = searchAcpTranscript(_transcript(), 'WIDGET');
      final sources = result.matches.map((match) => match.source).toList();
      expect(sources.first, AcpTranscriptMatchSource.user);
      expect(sources.toSet(), containsAll(AcpTranscriptMatchSource.values));
      expect(result.capped, isFalse);
      // Matches never come from the inline image payload.
      final agentMatches = result.matches.where(
        (match) => match.source == AcpTranscriptMatchSource.agent,
      );
      expect(agentMatches, hasLength(1));
    });

    test('names the entry and thread child holding each match', () {
      final result = searchAcpTranscript(_transcript(), 'flutter test');
      expect(result.matches, hasLength(2));
      for (final match in result.matches) {
        expect(match.entryIndex, 2);
        expect(match.entryId, 'tool-1');
        expect(match.childKey, 'tool-1');
      }
    });

    test('builds a snippet around the match', () {
      final match = searchAcpTranscript(
        _transcript(),
        'missing',
      ).matches.single;
      expect(match.snippet.match, 'missing');
      expect(match.snippet.before, 'The widget is ');
      expect(match.snippet.after, startsWith('. '));
    });

    test('targets the virtual segment of a long reply', () {
      final long = [
        for (var i = 0; i < 400; i++) 'Paragraph $i of filler text.\n\n',
        'needle at the end',
      ].join();
      final entries = [AcpAssistantMessageEntry(id: 'long', markdown: long)];
      final match = searchAcpTranscript(entries, 'needle').matches.single;
      final segments = splitAcpMarkdownForVirtualization(long);
      expect(segments.length, greaterThan(1));
      expect(match.childKey, 'long-markdown-part-${segments.length - 1}');
    });

    test('searches nested subagent output under its top-level entry', () {
      final entries = <AcpTimelineEntry>[
        AcpToolCallEntry(
          id: 'tool-launch',
          isSubagent: true,
          toolCall: AcpToolCall(id: 'launch', title: 'Launch helper'),
        ),
        AcpSubagentTranscriptEntry(
          id: 'subagent-launch',
          launchToolCallId: 'launch',
          entries: const [
            AcpAssistantMessageEntry(
              id: 'nested',
              markdown: 'nested answer',
              parentToolCallId: 'launch',
            ),
          ],
        ),
      ];
      final match = searchAcpTranscript(entries, 'answer').matches.single;
      expect(match.entryIndex, 1);
      expect(match.entryId, 'nested');
      expect(match.childKey, 'nested');
    });

    test('caps the number of matches', () {
      final entries = [
        AcpAssistantMessageEntry(id: 'many', markdown: 'a' * 50),
      ];
      final result = searchAcpTranscript(entries, 'a', maxMatches: 10);
      expect(result.matches, hasLength(10));
      expect(result.capped, isTrue);
    });

    test('finds a phrase split across virtual segments', () {
      final entries = [
        AcpUserPromptEntry(
          id: 'long-prompt',
          parts: [AcpTextPart('${'x' * 2043} foo bar')],
        ),
      ];
      final match = searchAcpTranscript(entries, 'foo bar').matches.single;
      expect(match.childKey, 'long-prompt');
      expect(match.snippet.match, 'foo bar');
    });

    test('keeps the newest matches when there are too many', () {
      final entries = [
        for (var i = 0; i < 1500; i++)
          AcpAssistantMessageEntry(id: 'reply-$i', markdown: 'error $i'),
      ];
      final result = searchAcpTranscript(entries, 'error');
      expect(result.capped, isTrue);
      expect(result.matches, hasLength(kAcpTranscriptSearchMaxMatches));
      expect(result.matches.last.entryId, 'reply-1499');
      expect(result.matches.first.entryIndex, 1500 - 999);
    });

    test('skips inline payloads in tool output', () {
      final entries = [
        AcpToolCallEntry(
          id: 'tool',
          toolCall: AcpToolCall(
            id: 'tool',
            title: 'Screenshot',
            rawOutput: 'saved data:image/png;base64,QUJDREVGR0hJSktMTU5P',
          ),
        ),
      ];
      expect(searchAcpTranscript(entries, 'hijk').matches, isEmpty);
      expect(searchAcpTranscript(entries, 'saved').matches, hasLength(1));
    });

    test('ignores blank queries', () {
      expect(searchAcpTranscript(_transcript(), '   ').matches, isEmpty);
    });
  });

  group('AcpTranscriptSearchController', () {
    test('debounces typing and starts at the newest match', () {
      fakeAsync((async) {
        final controller = AcpTranscriptSearchController()
          ..updateEntries(_transcript())
          ..open()
          ..setQuery('widget');
        expect(controller.result.matches, isEmpty);
        expect(controller.isSettled, isFalse);
        async.elapse(const Duration(milliseconds: 200));
        final count = controller.result.matches.length;
        expect(count, greaterThan(3));
        expect(controller.activeIndex, count - 1);
        expect(controller.focus?.entryId, 'status-stop');
        controller.dispose();
      });
    });

    test('steps older and newer, wrapping, with a new serial each time', () {
      fakeAsync((async) {
        final controller = AcpTranscriptSearchController()
          ..updateEntries(_transcript())
          ..open()
          ..setQuery('widget');
        async.elapse(const Duration(milliseconds: 200));
        final count = controller.result.matches.length;
        final serial = controller.focus!.serial;
        controller.previous();
        expect(controller.activeIndex, count - 2);
        expect(controller.focus!.serial, greaterThan(serial));
        controller
          ..next()
          ..next();
        expect(controller.activeIndex, 0);
        controller.dispose();
      });
    });

    test('keeps the active match without scrolling as output streams', () {
      fakeAsync((async) {
        final entries = _transcript();
        final controller = AcpTranscriptSearchController()
          ..updateEntries(entries)
          ..open()
          ..setQuery('flutter test');
        async.elapse(const Duration(milliseconds: 200));
        controller.previous();
        final focus = controller.focus!;
        controller.updateEntries([
          ...entries,
          const AcpAssistantMessageEntry(id: 'more', markdown: 'streamed'),
        ]);
        async.elapse(const Duration(seconds: 1));
        expect(controller.focus!.childKey, focus.childKey);
        expect(controller.focus!.serial, focus.serial);
        controller.dispose();
      });
    });

    test('Return steps while output streams in', () {
      fakeAsync((async) {
        final entries = _transcript();
        final controller = AcpTranscriptSearchController()
          ..updateEntries(entries)
          ..open()
          ..setQuery('widget');
        async.elapse(const Duration(milliseconds: 200));
        final newest = controller.activeIndex!;
        controller.updateEntries([
          ...entries,
          const AcpAssistantMessageEntry(id: 'more', markdown: 'streaming'),
        ]);
        expect(controller.isSettled, isTrue);
        controller.previous();
        expect(controller.activeIndex, newest - 1);
        async.elapse(const Duration(seconds: 1));
        controller.dispose();
      });
    });

    test('stepping right after typing lands on the newest match first', () {
      fakeAsync((async) {
        final controller = AcpTranscriptSearchController()
          ..updateEntries(_transcript())
          ..open()
          ..setQuery('widget');
        async.elapse(const Duration(milliseconds: 50));
        controller.previous();
        expect(controller.activeIndex, controller.result.matches.length - 1);
        controller.dispose();
      });
    });

    test('closing forgets the query and its matches', () {
      fakeAsync((async) {
        final controller = AcpTranscriptSearchController()
          ..updateEntries(_transcript())
          ..open()
          ..setQuery('widget');
        async.elapse(const Duration(milliseconds: 200));
        controller.close();
        expect(controller.isOpen, isFalse);
        expect(controller.query, isEmpty);
        expect(controller.result.matches, isEmpty);
        expect(controller.focus, isNull);
        controller.dispose();
      });
    });
  });
}
