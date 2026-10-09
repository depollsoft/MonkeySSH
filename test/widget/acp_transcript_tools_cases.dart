// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter/foundation.dart';
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

Widget _app(
  Widget child, {
  Size size = const Size(400, 800),
  bool disableAnimations = true,
  EdgeInsets padding = EdgeInsets.zero,
}) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: MediaQueryData(
      size: size,
      disableAnimations: disableAnimations,
      padding: padding,
      viewPadding: padding,
    ),
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

    testWidgets('streamed output does not re-announce the result', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final entries = _longTranscript();
      final search = AcpTranscriptSearchController()
        ..updateEntries(entries)
        ..open();
      addTearDown(search.dispose);
      await tester.pumpWidget(_app(AcpTranscriptSearchBar(controller: search)));
      await tester.enterText(
        find.byKey(const ValueKey('acp-transcript-search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 200));
      final count = find.byKey(const ValueKey('acp-transcript-search-count'));
      String liveLabel() => tester.getSemantics(count).label;
      final announced = liveLabel();
      expect(announced, startsWith('Match 2 of 2'));

      search.updateEntries([
        ...entries,
        const AcpAssistantMessageEntry(id: 'more', markdown: 'another needle'),
      ]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2/3'), findsOneWidget);
      expect(liveLabel(), announced);

      // Stepping is announced.
      await tester.tap(
        find.byKey(const ValueKey('acp-transcript-search-older')),
      );
      await tester.pump();
      expect(liveLabel(), startsWith('Match 1 of 3'));
      semantics.dispose();
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

    testWidgets('a running tool holding the match stays open when it ends', (
      tester,
    ) async {
      AcpToolCallEntry tool(AcpToolStatus status) => AcpToolCallEntry(
        id: 'tool',
        toolCall: AcpToolCall(
          id: 'tool',
          title: 'Run tests',
          status: status,
          rawOutput: 'needle in the output',
        ),
      );
      const focus = AcpThreadSearchFocus(
        entryIndex: 0,
        childKey: 'tool',
        entryId: 'tool',
        serial: 1,
      );
      await tester.pumpWidget(
        _app(
          AcpMessageThread(
            entries: [tool(AcpToolStatus.running)],
            searchFocus: focus,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _app(
          AcpMessageThread(
            entries: [tool(AcpToolStatus.completed)],
            searchFocus: focus,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('needle in the output', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('stepping quickly ends on the latest match', (tester) async {
      final entries = _longTranscript();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget thread(AcpThreadSearchFocus focus) => _app(
        AcpMessageThread(
          entries: entries,
          controller: controller,
          searchFocus: focus,
        ),
        disableAnimations: false,
      );
      await tester.pumpWidget(
        _app(AcpMessageThread(entries: entries, controller: controller)),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();

      // A far, older target starts seeking; a nearer one supersedes it.
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(
        thread(
          const AcpThreadSearchFocus(
            entryIndex: 55,
            childKey: 'agent-55',
            entryId: 'agent-55',
            serial: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reply 55'), findsOneWidget);
      expect(find.text('The needle is here.'), findsNothing);
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

    testWidgets('keeps Copy and Share above the system navigation bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AcpTranscriptExportSheet(
            source: _exportSource(),
            share: (context, markdown, fileName) async {},
          ),
          padding: const EdgeInsets.only(bottom: 48),
        ),
      );
      await tester.pump();
      final share = tester.getRect(
        find.byKey(const ValueKey('acp-export-share')),
      );
      expect(share.bottom, lessThanOrEqualTo(800 - 48));
    });

    testWidgets('says so when copying fails', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.setData'
            ? throw PlatformException(code: 'TransactionTooLarge')
            : null,
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
      expect(
        find.text('Couldn’t copy the transcript. Use Share instead.'),
        findsOneWidget,
      );
      expect(find.text('Copied'), findsNothing);
    });

    testWidgets(
      'does not copy an export too large for the Android clipboard',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        var copies = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') copies++;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pumpSheet(
          tester,
          share: (context, markdown, fileName) async {},
          source: AcpTranscriptExportSource(
            title: 'Huge',
            agentLabel: 'Agent',
            entries: [
              AcpAssistantMessageEntry(
                id: 'big',
                markdown: 'y' * (kAcpExportMaxAndroidCopyBytes + 1),
              ),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('acp-export-copy')));
        await tester.pump();
        expect(copies, 0);
        expect(
          find.text('This transcript is too large to copy. Use Share instead.'),
          findsOneWidget,
        );
      },
    );

    test('saves to a file only where sharing a file falls short', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final (platform, saves) in [
        (TargetPlatform.android, false),
        (TargetPlatform.iOS, false),
        // The sandboxed macOS app has no Save-panel entitlement; its share
        // sheet reads a file private to the app container.
        (TargetPlatform.macOS, false),
        (TargetPlatform.linux, true),
        (TargetPlatform.windows, true),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(acpExportSavesToFile, saves, reason: '$platform');
      }
    });

    test('a new export file replaces what earlier exports left', () async {
      final temp = Directory.systemTemp.createTempSync('acp-export-test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final first = await writeAcpTranscriptExportFile(
        [1, 2, 3],
        'first.md',
        temporaryDirectory: temp,
      );
      expect(first.existsSync(), isTrue);
      final second = await writeAcpTranscriptExportFile(
        [4],
        'second.md',
        temporaryDirectory: temp,
      );
      expect(first.existsSync(), isFalse);
      expect(second.readAsBytesSync(), [4]);
      expect(second.parent.path, endsWith(kAcpExportFolderName));
    });

    testWidgets('fits a short screen with large text without overflow', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(640, 300)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: FluttyTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(640, 300),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: AcpTranscriptExportSheet(
                source: _exportSource(),
                share: (context, markdown, fileName) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final share = tester.getRect(
        find.byKey(const ValueKey('acp-export-share')),
      );
      expect(share.bottom, lessThanOrEqualTo(300));
    });

    testWidgets('announces a copy or share failure', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpSheet(
        tester,
        share: (context, markdown, fileName) async =>
            throw PlatformException(code: 'unavailable'),
      );
      await tester.tap(find.byKey(const ValueKey('acp-export-share')));
      await tester.pump();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('acp-export-error'))),
        matchesSemantics(
          isLiveRegion: true,
          label: 'Couldn’t open the share sheet. Copy the Markdown instead.',
        ),
      );
      semantics.dispose();
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
