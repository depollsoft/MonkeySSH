// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_virtualization.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_plan.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_status_entry.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';
import 'package:monkeyssh/presentation/widgets/acp_usage.dart';
import 'package:monkeyssh/presentation/widgets/acp_user_prompt.dart';

// A tiny valid 1x1 PNG.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget wrap(
  Widget child, {
  Brightness brightness = Brightness.dark,
  Size size = const Size(400, 800),
  bool disableAnimations = true,
}) => MaterialApp(
  theme: brightness == Brightness.dark ? FluttyTheme.dark : FluttyTheme.light,
  home: MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: disableAnimations),
    child: Scaffold(body: child),
  ),
);

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('uses a dense native transcript viewport', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          entries: [AcpAssistantMessageEntry(id: 'a1', markdown: 'hello')],
        ),
      ),
    );
    await tester.pump();

    final viewport = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final padding = tester.widget<SliverPadding>(find.byType(SliverPadding));
    expect(viewport.shrinkWrap, isFalse);
    expect(
      padding.padding,
      const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: FluttyTheme.spacingSm,
      ),
    );
  });

  test('user prompt summary normalizes text and attachment-only prompts', () {
    expect(
      acpUserPromptSummary(
        AcpUserPromptEntry(
          id: 'text',
          parts: const [AcpTextPart('  first\nline  '), AcpTextPart('second')],
        ),
      ),
      'first line second',
    );
    final hugeSummary = acpUserPromptSummary(
      AcpUserPromptEntry(
        id: 'huge-text',
        parts: [AcpTextPart(List.filled(50000, 'diagnostic').join(' '))],
      ),
    );
    expect(hugeSummary, hasLength(240));
    expect(hugeSummary, endsWith('…'));

    expect(
      acpUserPromptSummary(
        AcpUserPromptEntry(
          id: 'attachments',
          parts: [
            AcpImagePart(AcpImageContent(bytes: _pngBytes, label: 'diagram')),
            const AcpResourcePart(
              AcpResourceRef(uri: 'file:///repo/lib/main.dart'),
            ),
          ],
        ),
      ),
      'diagram · main.dart',
    );
  });

  testWidgets('pins and swaps the user prompt governing visible responses', (
    tester,
  ) async {
    final controller = ScrollController();
    String longResponse(String label) => List.generate(
      18,
      (index) => '$label response paragraph $index with enough text to wrap.',
    ).join('\n\n');
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 240,
          child: AcpMessageThread(
            controller: controller,
            entries: [
              AcpUserPromptEntry(
                id: 'u1',
                parts: const [AcpTextPart('first user request')],
              ),
              AcpAssistantMessageEntry(
                id: 'a1',
                markdown: longResponse('first'),
              ),
              AcpUserPromptEntry(
                id: 'u2',
                parts: const [AcpTextPart('second user request')],
              ),
              AcpAssistantMessageEntry(
                id: 'a2',
                markdown: longResponse('second'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('acp-sticky-user-prompt')), findsNothing);

    String? stickyText() => find
        .byKey(const ValueKey('acp-sticky-user-prompt-text'))
        .evaluate()
        .map((element) => (element.widget as Text).data)
        .firstOrNull;

    Future<void> scrollUntil(String expected, double delta) async {
      for (var attempt = 0; attempt < 30; attempt++) {
        if ((stickyText() ?? '').contains(expected)) return;
        await tester.drag(find.byType(CustomScrollView), Offset(0, delta));
        await tester.pump();
      }
      fail('Sticky prompt never became $expected; was ${stickyText()}');
    }

    await scrollUntil('first user request', -100);
    final sticky = tester.widget<Text>(
      find.byKey(const ValueKey('acp-sticky-user-prompt-text')),
    );
    expect(sticky.maxLines, 1);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('acp-sticky-user-prompt')))
          .height,
      44,
    );
    expect(
      find.bySemanticsLabel(
        'Current user prompt: first user request. Show original message.',
      ),
      findsOneWidget,
    );

    final offsetBeforeTap = controller.offset;
    await tester.tap(find.byKey(const ValueKey('acp-sticky-user-prompt')));
    await tester.pumpAndSettle();
    expect(controller.offset, lessThan(offsetBeforeTap));
    expect(find.text('first user request'), findsOneWidget);
    expect(find.byKey(const ValueKey('acp-sticky-user-prompt')), findsNothing);

    await scrollUntil('second user request', -120);
    await scrollUntil('first user request', 120);

    controller.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('acp-sticky-user-prompt')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'sticky prompt finds its disposed message above a long response',
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 240,
            child: AcpMessageThread(
              controller: controller,
              entries: [
                AcpUserPromptEntry(
                  id: 'far-prompt',
                  parts: const [AcpTextPart('take me back to the original')],
                ),
                AcpAssistantMessageEntry(
                  id: 'very-long-response',
                  markdown: List.generate(
                    300,
                    (index) =>
                        'Response paragraph $index with enough words to wrap.',
                  ).join('\n\n'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('acp-sticky-user-prompt')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('far-prompt')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('acp-sticky-user-prompt')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('far-prompt')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('acp-sticky-user-prompt')),
        findsNothing,
      );
      expect(controller.offset, lessThan(40));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('keeps the last prompt pinned when the footer reaches the top', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 120,
          child: AcpMessageThread(
            controller: controller,
            entries: [
              AcpUserPromptEntry(
                id: 'u1',
                parts: const [AcpTextPart('footer context')],
              ),
            ],
            footer: const SizedBox(height: 300),
          ),
        ),
      ),
    );
    await tester.pump();
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();

    expect(find.text('you · footer context'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('windows live-follow transcripts to the recent tail', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 200,
          child: AcpMessageThread(
            controller: controller,
            followTail: true,
            entries: [
              for (var index = 0; index < 200; index++)
                AcpStatusEntry(
                  id: 'tail-status-$index',
                  message: 'status $index',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.position.pixels, controller.position.maxScrollExtent);
    expect(find.byKey(const ValueKey('tail-status-199')), findsOneWidget);
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      48,
    );
    expect(find.byKey(const ValueKey('tail-status-0')), findsNothing);

    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('acp-earlier-transcript')),
      findsOneWidget,
    );

    await tester.tap(find.text('Earlier messages'));
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      56,
    );

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 200,
          child: AcpMessageThread(
            entries: [
              for (var index = 0; index < 10; index++)
                AcpStatusEntry(
                  id: 'short-status-$index',
                  message: 'short $index',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('preserves loaded history until new followed content arrives', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var followTail = false;
    var entries = <AcpTimelineEntry>[
      for (var index = 0; index < 200; index++)
        AcpStatusEntry(id: 'resume-$index', message: 'resume $index'),
    ];

    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              TextButton(
                onPressed: () => setState(() => followTail = true),
                child: const Text('Resume follow'),
              ),
              TextButton(
                onPressed: () => setState(
                  () => entries = [
                    ...entries,
                    const AcpStatusEntry(
                      id: 'resume-new',
                      message: 'new update',
                    ),
                  ],
                ),
                child: const Text('Append update'),
              ),
              Expanded(
                child: AcpMessageThread(
                  controller: controller,
                  entries: entries,
                  followTail: followTail,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      200,
    );

    await tester.tap(find.text('Resume follow'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      200,
    );
    expect(controller.position.pixels, controller.position.maxScrollExtent);

    await tester.tap(find.text('Append update'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      48,
    );
    expect(find.byKey(const ValueKey('resume-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('resume-0')), findsNothing);
  });

  testWidgets('anchors a maximum-size history without laying out older chunks', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final entries = <AcpTimelineEntry>[
      for (var index = 0; index < 120; index++)
        AcpAssistantMessageEntry(
          id: 'large-$index',
          markdown: 'entry $index\n\n${'x' * 32000} LATEST-END-$index',
        ),
    ];

    final tailLayout = Stopwatch()..start();
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 800,
          child: AcpMessageThread(
            controller: controller,
            entries: entries,
            followTail: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tailLayout.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason:
          'initial layout must mount the final virtual chunk directly instead '
          'of seeking through the preceding large Markdown window',
    );
    expect(controller.position.pixels, controller.position.maxScrollExtent);
    expect(find.textContaining('LATEST-END-119'), findsOneWidget);
    expect(find.byKey(const ValueKey('large-118')), findsNothing);
  });

  testWidgets('Earlier messages reveals oversized history immediately', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final markdown = List.generate(
      1600,
      (index) => 'large paragraph $index with enough words to wrap',
    ).join('\n\n');
    final chunks = splitAcpMarkdownForVirtualization(markdown);
    final finalChunkKey = ValueKey(
      'paged-large-markdown-part-${chunks.length - 1}',
    );

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 240,
          child: AcpMessageThread(
            controller: controller,
            followTail: true,
            entries: [
              const AcpStatusEntry(id: 'paged-older', message: 'older entry'),
              AcpAssistantMessageEntry(id: 'paged-large', markdown: markdown),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();

    expect(find.byKey(finalChunkKey), findsOneWidget);
    expect(find.byKey(const ValueKey('paged-large')), findsNothing);
    expect(find.byKey(const ValueKey('paged-older')), findsNothing);
    final childCountBefore = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .semanticChildCount!;

    await tester.tap(find.text('Earlier messages'));
    await tester.pumpAndSettle();

    expect(controller.offset, controller.position.minScrollExtent);
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      greaterThan(childCountBefore),
      reason: 'a button tap must visibly expose a new history page',
    );

    for (var page = 0; page < 8; page++) {
      controller.jumpTo(controller.position.minScrollExtent);
      await tester.pump();
      if (find.byKey(const ValueKey('paged-older')).evaluate().isNotEmpty) {
        break;
      }
      await tester.tap(find.text('Earlier messages'));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('paged-older')), findsOneWidget);
    expect(find.byKey(const ValueKey('paged-large')), findsOneWidget);
  });

  testWidgets('keeps long transcripts lazy', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 200,
          child: AcpMessageThread(
            entries: [
              for (var index = 0; index < 200; index++)
                AcpStatusEntry(id: 'status-$index', message: 'status $index'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('status-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('status-199')), findsNothing);
  });

  testWidgets('virtualizes one oversized assistant response', (tester) async {
    final markdown = List.generate(
      6000,
      (index) =>
          'Paragraph **$index** with enough content to resemble a long response.',
    ).join('\n\n');
    final chunks = splitAcpMarkdownForVirtualization(markdown);

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 240,
          child: AcpMessageThread(
            entries: [
              AcpAssistantMessageEntry(id: 'long-response', markdown: markdown),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('long-response')), findsOneWidget);
    expect(
      find.byKey(ValueKey('long-response-markdown-part-${chunks.length - 1}')),
      findsNothing,
    );
  });

  testWidgets('underfilled last-image tail remains scrollable', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final prose = List.generate(
      1200,
      (index) => 'Earlier paragraph $index with enough text to wrap.',
    ).join('\n\n');
    final payload = List.filled(30000, 'A').join();
    final markdown = '$prose\n\n![last image](data:image/png;base64,$payload)';
    var followTail = true;
    late StateSetter setThreadState;

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 700,
          child: StatefulBuilder(
            builder: (context, setState) {
              setThreadState = setState;
              return AcpMessageThread(
                controller: controller,
                followTail: followTail,
                entries: [
                  AcpAssistantMessageEntry(
                    id: 'image-tail',
                    markdown: markdown,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    for (
      var attempt = 0;
      attempt < 12 &&
          (!controller.hasClients || controller.position.maxScrollExtent <= 0);
      attempt++
    ) {
      await tester.pump();
    }

    expect(controller.position.maxScrollExtent, greaterThan(0));
    setThreadState(() => followTail = false);
    await tester.pump();
    final before = controller.offset;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump();
    expect(controller.offset, lessThan(before));

    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
    }
    expect(
      controller.offset,
      lessThan(before),
      reason:
          'late image layout must not snap a manual scroll back to the tail',
    );
  });

  testWidgets('virtualizes one full-screen user diagnostics prompt', (
    tester,
  ) async {
    final diagnostics = List.generate(
      9000,
      (index) => 'diagnostic line $index: state and timing details',
    ).join('\n');
    final chunks = splitAcpTextForVirtualization(diagnostics);

    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 320,
          height: 240,
          child: AcpMessageThread(
            entries: [
              AcpUserPromptEntry(
                id: 'long-user-prompt',
                parts: [AcpTextPart(diagnostics)],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('long-user-prompt')), findsOneWidget);
    expect(
      find.byKey(ValueKey('long-user-prompt-user-part-${chunks.length - 1}')),
      findsNothing,
    );
  });

  testWidgets('reveals fading chevrons that jump between user messages', (
    tester,
  ) async {
    final controller = ScrollController();
    final diagnostics = List.generate(
      600,
      (index) => 'diagnostic line $index: state and timing details',
    ).join('\n');
    String response(String label) => List.generate(
      50,
      (index) => '$label response paragraph $index with enough text to wrap.',
    ).join('\n\n');
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 320,
          height: 240,
          child: AcpMessageThread(
            controller: controller,
            entries: [
              AcpUserPromptEntry(
                id: 'prompt-1',
                parts: [AcpTextPart(diagnostics)],
              ),
              AcpAssistantMessageEntry(
                id: 'answer-1',
                markdown: response('first'),
              ),
              AcpUserPromptEntry(
                id: 'prompt-2',
                parts: const [AcpTextPart('second prompt')],
              ),
              AcpAssistantMessageEntry(
                id: 'answer-2',
                markdown: response('second'),
              ),
              AcpUserPromptEntry(
                id: 'prompt-3',
                parts: const [AcpTextPart('third prompt')],
              ),
              AcpAssistantMessageEntry(
                id: 'answer-3',
                markdown: response('third'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    AnimatedOpacity navigation() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('acp-user-prompt-navigation')),
    );
    expect(navigation().opacity, 0);
    final topSlot = find.byKey(const ValueKey('acp-scroll-to-top-slot'));
    final previousSlot = find.byKey(
      const ValueKey('acp-previous-user-message-slot'),
    );
    final nextSlot = find.byKey(const ValueKey('acp-next-user-message-slot'));
    final initialSlotPositions = [
      tester.getTopLeft(topSlot),
      tester.getTopLeft(previousSlot),
      tester.getTopLeft(nextSlot),
    ];
    expect(find.byKey(const ValueKey('acp-scroll-to-top')), findsNothing);
    expect(
      find.byKey(const ValueKey('acp-previous-user-message')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('acp-next-user-message')), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();
    await tester.pump();
    expect(navigation().opacity, 1);
    expect([
      tester.getTopLeft(topSlot),
      tester.getTopLeft(previousSlot),
      tester.getTopLeft(nextSlot),
    ], initialSlotPositions);
    expect(
      tester.getSize(find.byKey(const ValueKey('acp-next-user-message'))),
      const Size(48, 48),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('acp-next-user-message')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('acp-scroll-to-top'))),
      const Size(48, 48),
    );

    await tester.tap(find.byKey(const ValueKey('acp-scroll-to-top')));
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.minScrollExtent);
    expect(find.byKey(const ValueKey('prompt-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('acp-scroll-to-top')), findsNothing);
    expect(
      find.byKey(const ValueKey('acp-previous-user-message')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('acp-next-user-message')), findsOneWidget);
    expect([
      tester.getTopLeft(topSlot),
      tester.getTopLeft(previousSlot),
      tester.getTopLeft(nextSlot),
    ], initialSlotPositions);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('acp-next-user-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('acp-previous-user-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('acp-next-user-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('acp-next-user-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('acp-next-user-message')), findsNothing);
    expect([
      tester.getTopLeft(topSlot),
      tester.getTopLeft(previousSlot),
      tester.getTopLeft(nextSlot),
    ], initialSlotPositions);

    await tester.tap(find.byKey(const ValueKey('acp-previous-user-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-2')), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(navigation().opacity, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('animates prompt jumps in their scroll direction', (
    tester,
  ) async {
    final controller = ScrollController();
    final response = List.generate(
      90,
      (index) => 'Response paragraph $index with enough text to wrap.',
    ).join('\n\n');
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 320,
          height: 240,
          child: AcpMessageThread(
            controller: controller,
            entries: [
              AcpUserPromptEntry(
                id: 'motion-prompt-1',
                parts: const [AcpTextPart('first motion prompt')],
              ),
              AcpAssistantMessageEntry(id: 'motion-answer', markdown: response),
              AcpUserPromptEntry(
                id: 'motion-prompt-2',
                parts: const [AcpTextPart('second motion prompt')],
              ),
            ],
          ),
        ),
        disableAnimations: false,
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pump();
    await tester.pump();

    final downwardStart = controller.offset;
    await tester.tap(find.byKey(const ValueKey('acp-next-user-message')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.offset, greaterThan(downwardStart));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('motion-prompt-2')), findsOneWidget);

    final upwardStart = controller.offset;
    await tester.tap(find.byKey(const ValueKey('acp-previous-user-message')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.offset, lessThan(upwardStart));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('motion-prompt-1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('preserves user prompt part order', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpUserPromptEntry(
              id: 'u1',
              parts: [
                const AcpTextPart('first'),
                AcpImagePart(
                  AcpImageContent(bytes: _pngBytes, label: 'diagram'),
                ),
                const AcpTextPart('second'),
                const AcpResourcePart(
                  AcpResourceRef(uri: 'file:///a/main.dart'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // The column of parts must appear top-to-bottom in the given order.
    final firstText = tester.getTopLeft(find.text('first')).dy;
    final image = tester.getTopLeft(find.byType(AcpInlineImage)).dy;
    final secondText = tester.getTopLeft(find.text('second')).dy;
    final chip = tester.getTopLeft(find.byType(AcpResourceChip)).dy;
    expect(firstText, lessThan(image));
    expect(image, lessThan(secondText));
    expect(secondText, lessThan(chip));
    expect(find.text('main.dart'), findsOneWidget);
    final promptTextFinder = find.widgetWithText(SelectableText, 'first');
    final promptText = tester.widget<SelectableText>(promptTextFinder);
    final bodyFamily = Theme.of(
      tester.element(promptTextFinder),
    ).textTheme.bodyMedium?.fontFamily;
    expect(promptText.style?.fontFamily, bodyFamily);
    expect(
      promptText.style?.fontFamily,
      isNot(FluttyTheme.monoStyle.fontFamily),
    );
  });

  testWidgets('shows queued prompt status visibly and semantically', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpUserPromptEntry(
              id: 'queued',
              queued: true,
              parts: const [AcpTextPart('follow up')],
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('queued'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(AcpUserPromptView));
    expect(semantics.label, contains('Your message, queued'));
  });

  testWidgets('dispatches each entry type', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpUserPromptEntry(id: 'u1', parts: const [AcpTextPart('hello')]),
            const AcpAssistantMessageEntry(id: 'a1', markdown: 'world'),
            AcpPlanEntry(
              id: 'p1',
              plan: AcpPlan(items: const [AcpPlanItem(title: 'task')]),
            ),
            AcpToolCallEntry(
              id: 't1',
              toolCall: AcpToolCall(id: 't1', title: 'Read file'),
            ),
            const AcpUsageEntry(id: 'us1', usage: AcpUsage(totalTokens: 1200)),
            const AcpStatusEntry(id: 's1', message: 'Done'),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AcpUserPromptView), findsOneWidget);
    expect(find.byType(AcpPlanView), findsOneWidget);
    expect(find.byType(AcpToolCallView), findsOneWidget);
    expect(find.byType(AcpUsageView), findsOneWidget);
    expect(find.byType(AcpStatusEntryView), findsOneWidget);
    expect(find.text('Read file'), findsOneWidget);
  });

  testWidgets('renders Claude nested subagent transcripts', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpToolCallEntry(
              id: 'agent-launch',
              isSubagent: true,
              toolCall: AcpToolCall(id: 'agent-launch', title: 'Agent'),
            ),
            AcpSubagentTranscriptEntry(
              id: 'subagent-agent-launch',
              launchToolCallId: 'agent-launch',
              entries: const [
                AcpAssistantMessageEntry(
                  id: 'nested-message',
                  markdown: 'Nested response',
                  parentToolCallId: 'agent-launch',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Subagent'), findsOneWidget);
    expect(find.text('Subagent transcript'), findsOneWidget);
    expect(find.text('Nested response'), findsOneWidget);
    final rail = tester.widget<Container>(
      find.byKey(const ValueKey('acp-subagent-transcript-agent-launch')),
    );
    expect(rail.margin, const EdgeInsets.only(left: FluttyTheme.spacingSm));
    expect(rail.padding, const EdgeInsets.only(left: FluttyTheme.spacingMd));
    final decoration = rail.decoration! as BoxDecoration;
    final border = decoration.border! as Border;
    expect(border.left.width, 2);
  });

  testWidgets('renders a tool image inline without expansion', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpToolCallEntry(
              id: 'image-tool',
              toolCall: AcpToolCall(
                id: 'image-tool',
                title: 'Show image',
                status: AcpToolStatus.completed,
                images: [AcpImageContent(bytes: _pngBytes)],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AcpInlineImage), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('renders in light and dark themes', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        wrap(
          brightness: brightness,
          const AcpMessageThread(
            entries: [
              AcpStatusEntry(
                id: 's1',
                message: 'Warning',
                severity: AcpStatusSeverity.warning,
                detail: 'context',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Warning'), findsOneWidget);
    }
  });

  testWidgets('renders in narrow and wide constraints', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(280, 640), const Size(1100, 800)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        wrap(
          size: size,
          AcpMessageThread(
            entries: [
              AcpUserPromptEntry(
                id: 'u1',
                parts: const [
                  AcpTextPart(
                    'A fairly long prompt that should wrap on narrow '
                    'screens without overflowing its constraints.',
                  ),
                  AcpResourcePart(
                    AcpResourceRef(
                      uri:
                          'file:///very/long/path/to/some/deeply/nested/file'
                          '/that/keeps/going/component.tsx',
                      sizeBytes: 4096,
                      mimeType: 'text/tsx',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byType(AcpMessageThread)).width, size.width);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('plan shows progress fraction and items', (tester) async {
    await tester.pumpWidget(
      wrap(
        AcpPlanView(
          plan: AcpPlan(
            items: const [
              AcpPlanItem(title: 'Design', status: AcpPlanItemStatus.completed),
              AcpPlanItem(title: 'Build', status: AcpPlanItemStatus.inProgress),
              AcpPlanItem(title: 'Ship'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(1 / 3, 0.001));
  });

  testWidgets('usage hides when empty and shows when populated', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AcpUsageView(usage: AcpUsage())));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(
      wrap(
        const AcpUsageView(
          usage: AcpUsage(
            inputTokens: 1500,
            outputTokens: 300,
            contextWindow: 1000,
            contextUsedTokens: 400,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('exposes semantics for entries', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrap(
        AcpMessageThread(
          entries: [
            AcpUserPromptEntry(id: 'u1', parts: const [AcpTextPart('hi')]),
            const AcpStatusEntry(
              id: 's1',
              message: 'Failed',
              severity: AcpStatusSeverity.error,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Your message'), findsOneWidget);
    final statusSemantics = tester.getSemantics(
      find.byType(AcpStatusEntryView),
    );
    expect(statusSemantics.label, contains('Failed'));
    handle.dispose();
  });
}
