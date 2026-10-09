// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/controllers/acp_transcript_search_controller.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/models/acp_transcript_markdown.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_thought.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';
import 'package:monkeyssh/presentation/widgets/acp_transcript_export_sheet.dart';
import 'package:monkeyssh/presentation/widgets/acp_transcript_search_bar.dart';

Widget _app(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

List<AcpTimelineEntry> _longTranscript() => [
  for (var i = 0; i < 60; i++)
    if (i.isEven)
      AcpUserPromptEntry(
        id: 'user-$i',
        parts: [AcpTextPart(i == 10 ? 'Prompt $i has a needle' : 'Prompt $i')],
      )
    else
      AcpAssistantMessageEntry(
        id: 'agent-$i',
        markdown: i == 3 ? 'The needle is here.' : 'Reply $i\n\nfiller',
      ),
];

AcpTranscriptExportSource _exportSource({bool reasoning = true}) =>
    AcpTranscriptExportSource(
      title: 'Debug session',
      agentLabel: 'Copilot CLI',
      historyGaps: const {AcpTranscriptHistoryGap.trimmed},
      entries: [
        AcpUserPromptEntry(
          id: 'user',
          parts: const [AcpTextPart('Find the bug')],
        ),
        if (reasoning)
          const AcpThoughtEntry(id: 'thought', markdown: 'private chain'),
        const AcpAssistantMessageEntry(id: 'agent', markdown: 'Found it.'),
      ],
    );

void registerAcpTranscriptToolsTests() {
  group('transcript search', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    testWidgets('bar shows the count, the match context and navigates', (
      tester,
    ) async {
      final search = AcpTranscriptSearchController()
        ..updateEntries(_longTranscript())
        ..open();
      addTearDown(search.dispose);
      await tester.pumpWidget(_app(AcpTranscriptSearchBar(controller: search)));
      await tester.enterText(
        find.byKey(const ValueKey('acp-transcript-search-field')),
        'NEEDLE',
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('2/2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('acp-transcript-search-snippet')),
        findsOneWidget,
      );
      expect(find.text('you'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('acp-transcript-search-older')),
      );
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('agent'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('acp-transcript-search-newer')),
      );
      await tester.pump();
      expect(find.text('2/2'), findsOneWidget);
      final newer = tester.getSize(
        find.byKey(const ValueKey('acp-transcript-search-newer')),
      );
      expect(newer.width, greaterThanOrEqualTo(44));
      expect(newer.height, greaterThanOrEqualTo(44));
    });

    testWidgets('bar says when nothing matches and Escape closes it', (
      tester,
    ) async {
      final search = AcpTranscriptSearchController()
        ..updateEntries(_longTranscript())
        ..open();
      addTearDown(search.dispose);
      await tester.pumpWidget(_app(AcpTranscriptSearchBar(controller: search)));
      await tester.enterText(
        find.byKey(const ValueKey('acp-transcript-search-field')),
        'zebra',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('0/0'), findsOneWidget);
      expect(find.text('No matches in the loaded transcript'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(search.isOpen, isFalse);
    });

    testWidgets('the thread scrolls to and outlines the focused match', (
      tester,
    ) async {
      final entries = _longTranscript();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget thread(AcpThreadSearchFocus? focus) => _app(
        AcpMessageThread(
          entries: entries,
          controller: controller,
          searchFocus: focus,
        ),
      );
      await tester.pumpWidget(thread(null));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('The needle is here.'), findsNothing);

      await tester.pumpWidget(
        thread(
          const AcpThreadSearchFocus(
            entryIndex: 3,
            childKey: 'agent-3',
            entryId: 'agent-3',
            serial: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The needle is here.'), findsOneWidget);
      final highlight = find.byKey(
        const ValueKey('acp-search-match-highlight'),
      );
      expect(highlight, findsOneWidget);
      final needleTop = tester.getTopLeft(find.text('The needle is here.')).dy;
      expect(needleTop, greaterThanOrEqualTo(0));
      expect(needleTop, lessThan(200));
    });

    testWidgets('a focused tool call or reasoning block expands', (
      tester,
    ) async {
      final entries = <AcpTimelineEntry>[
        AcpToolCallEntry(
          id: 'tool',
          toolCall: AcpToolCall(
            id: 'tool',
            title: 'Run tests',
            status: AcpToolStatus.completed,
            rawOutput: 'needle in the output',
          ),
        ),
        const AcpThoughtEntry(id: 'thought', markdown: 'needle in reasoning'),
      ];
      Widget thread(AcpThreadSearchFocus? focus) =>
          _app(AcpMessageThread(entries: entries, searchFocus: focus));
      await tester.pumpWidget(thread(null));
      await tester.pumpAndSettle();
      expect(find.textContaining('needle in the output'), findsNothing);
      expect(find.textContaining('needle in reasoning'), findsNothing);

      await tester.pumpWidget(
        thread(
          const AcpThreadSearchFocus(
            entryIndex: 0,
            childKey: 'tool',
            entryId: 'tool',
            serial: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('needle in the output', findRichText: true),
        findsWidgets,
      );
      expect(find.byType(AcpToolCallView), findsOneWidget);

      await tester.pumpWidget(
        thread(
          const AcpThreadSearchFocus(
            entryIndex: 1,
            childKey: 'thought',
            entryId: 'thought',
            serial: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AcpThoughtView), findsOneWidget);
      expect(
        find.textContaining('needle in reasoning', findRichText: true),
        findsWidgets,
      );
    });
  });

  group('transcript export sheet', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    Future<void> pumpSheet(
      WidgetTester tester, {
      required AcpTranscriptShare share,
      AcpTranscriptExportSource? source,
    }) async {
      await tester.pumpWidget(
        _app(
          AcpTranscriptExportSheet(
            source: source ?? _exportSource(),
            share: share,
            now: () => DateTime(2026, 10, 9, 14, 3),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('previews the export and shares it as a Markdown file', (
      tester,
    ) async {
      String? shared;
      String? sharedName;
      await pumpSheet(
        tester,
        share: (context, markdown, fileName) async {
          shared = markdown;
          sharedName = fileName;
        },
      );
      expect(find.text('Export transcript'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('acp-export-history-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('# Debug session'), findsOneWidget);
      expect(find.textContaining('private chain'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('acp-export-share')));
      await tester.pump();
      expect(shared, contains('Found it.'));
      expect(shared, isNot(contains('private chain')));
      expect(sharedName, 'monkeyssh-chat-20261009-1403.md');
    });

    testWidgets('includes reasoning only when switched on', (tester) async {
      String? shared;
      await pumpSheet(
        tester,
        share: (context, markdown, fileName) async => shared = markdown,
      );
      await tester.tap(
        find.byKey(const ValueKey('acp-export-include-reasoning')),
      );
      await tester.pump();
      expect(find.textContaining('private chain'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('acp-export-share')));
      await tester.pump();
      expect(shared, contains('private chain'));
    });

    testWidgets('hides the reasoning switch when there is none', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        source: _exportSource(reasoning: false),
        share: (context, markdown, fileName) async {},
      );
      expect(
        find.byKey(const ValueKey('acp-export-include-reasoning')),
        findsNothing,
      );
    });

    testWidgets('copies the Markdown and confirms in place', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpSheet(tester, share: (context, markdown, fileName) async {});
      await tester.tap(find.byKey(const ValueKey('acp-export-copy')));
      await tester.pump();
      expect(copied, startsWith('# Debug session'));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('explains a share failure', (tester) async {
      await pumpSheet(
        tester,
        share: (context, markdown, fileName) async =>
            throw PlatformException(code: 'unavailable'),
      );
      await tester.tap(find.byKey(const ValueKey('acp-export-share')));
      await tester.pump();
      expect(
        find.text('Couldn’t open the share sheet. Copy the Markdown instead.'),
        findsOneWidget,
      );
    });
  });
}
