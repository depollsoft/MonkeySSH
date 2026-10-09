// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart' as d;
import 'package:monkeyssh/domain/models/acp_updates.dart' as d;
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/controllers/acp_unread_tracker.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/models/acp_unread.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_unread_digest_bar.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockLaunchPreferences extends Mock
    implements HostCliLaunchPreferencesService {}

Widget _app(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(size: Size(400, 800), disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

Widget _chat(FakeAcpSessionManager manager, AcpLastSeenRegistry registry) {
  final ssh = _MockSshService();
  final launchPreferences = _MockLaunchPreferences();
  when(() => ssh.getSessionsForHost(any())).thenReturn(const <SshSession>[]);
  when(() => launchPreferences.getPreferencesForHost(any()))
      .thenAnswer((_) async => const HostCliLaunchPreferences());
  final key = fakeAcpKey();
  return ProviderScope(
    overrides: [
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
      hostCliLaunchPreferencesServiceProvider.overrideWithValue(
        launchPreferences,
      ),
      acpLastSeenRegistryProvider.overrideWithValue(registry),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 800)),
        child: AgentChatScreen(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          attachmentActionsBuilder: (_, _) =>
              const AcpComposerAttachmentActions(),
          connectOnMount: false,
        ),
      ),
    ),
  );
}

d.AcpMessageEntry _message(d.AcpMessageRole role, int order, String text) =>
    d.AcpMessageEntry(
      role: role,
      order: order,
      content: [AcpTextContent(text)],
    );

List<d.AcpTimelineEntry> _seenEntries() => [
  for (var i = 0; i < 30; i++)
    _message(
      i.isEven ? d.AcpMessageRole.user : d.AcpMessageRole.agent,
      i,
      i.isEven ? 'Prompt $i' : 'Reply $i\n\nwith a second paragraph',
    ),
];

void registerAcpUnreadWidgetTests() {
  group('unread since you left', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    testWidgets('the thread draws the divider above its entry and jumps', (
      tester,
    ) async {
      final entries = <AcpTimelineEntry>[
        for (var i = 0; i < 40; i++)
          AcpAssistantMessageEntry(
            id: 'agent-$i',
            markdown: 'Reply $i\n\nfiller paragraph',
          ),
      ];
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget thread(int jumpSerial) => _app(
        AcpMessageThread(
          entries: entries,
          controller: controller,
          unreadDivider: const AcpThreadUnreadDivider(
            entryIndex: 5,
            earlierHistoryUnavailable: false,
          ),
          unreadJumpSerial: jumpSerial,
        ),
      );
      await tester.pumpWidget(thread(0));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('unread since you left'), findsNothing);

      await tester.pumpWidget(thread(1));
      await tester.pumpAndSettle();
      final divider = find.text('unread since you left');
      expect(divider, findsOneWidget);
      final top = tester.getTopLeft(divider).dy;
      expect(top, greaterThanOrEqualTo(0));
      expect(top, lessThan(120));
      // The divider sits directly above the first unread entry.
      expect(tester.getTopLeft(find.text('Reply 5')).dy, greaterThan(top));
    });

    testWidgets('the fallback divider says history is not available', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const AcpMessageThread(
            entries: [AcpAssistantMessageEntry(id: 'a', markdown: 'x')],
            unreadDivider: AcpThreadUnreadDivider(
              entryIndex: 0,
              earlierHistoryUnavailable: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('earlier history not available'), findsOneWidget);
    });

    testWidgets('the digest bar reads out the digest with 44 pt targets', (
      tester,
    ) async {
      var jumped = false;
      var dismissed = false;
      await tester.pumpWidget(
        _app(
          AcpUnreadDigestBar(
            state: const AcpUnreadState(
              dividerEntryIndex: 3,
              earlierHistoryUnavailable: false,
              digest: AcpUnreadDigest(
                replies: 2,
                toolCalls: {AcpToolKind.edit: 1},
                reportedFileChanges: 1,
              ),
            ),
            onJump: () => jumped = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      );
      expect(
        find.text(
          'Since you left: 2 replies · 1 tool call (1 edit) · '
          '1 reported file change',
        ),
        findsOneWidget,
      );
      final jump = find.byKey(const ValueKey('acp-unread-jump'));
      expect(tester.getSize(jump).height, greaterThanOrEqualTo(48));
      await tester.tap(jump);
      await tester.tap(find.byTooltip('Dismiss'));
      expect(jumped, isTrue);
      expect(dismissed, isTrue);
    });

    testWidgets('the digest bar explains an unknown gap', (tester) async {
      await tester.pumpWidget(
        _app(
          AcpUnreadDigestBar(
            state: const AcpUnreadState(
              dividerEntryIndex: 0,
              earlierHistoryUnavailable: true,
              digest: null,
            ),
            onJump: () {},
            onDismiss: () {},
          ),
        ),
      );
      expect(find.textContaining('Earlier history isn’t available'), findsOne);
    });

    testWidgets('returning to a chat shows the divider and digest; jumping '
        'lands on the first unread item', (tester) async {
      final registry = AcpLastSeenRegistry();
      final source = Object();
      final before = fakeAcpSession(
        timeline: d.AcpTimeline(entries: _seenEntries(), source: source),
      );
      final first = FakeAcpSessionManager(sessions: [before]);
      await tester.pumpWidget(_chat(first, registry));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);
      // Leaving the chat records where the user got to.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      final after = before.copyWith(
        timeline: d.AcpTimeline(
          source: source,
          entries: [
            ..._seenEntries(),
            d.AcpToolCallEntry(
              toolCallId: 'edit-1',
              order: 30,
              title: 'Edit main.dart',
              toolKind: d.AcpToolKind.edit,
              status: d.AcpToolStatus.completed,
              content: const [
                d.AcpToolDiff(path: 'lib/main.dart', newText: 'x'),
              ],
            ),
            _message(d.AcpMessageRole.agent, 31, 'First unread reply'),
            for (var i = 32; i < 50; i++)
              _message(d.AcpMessageRole.agent, i, 'Later $i\n\nmore text'),
          ],
        ),
      );
      final second = FakeAcpSessionManager(sessions: [after]);
      await tester.pumpWidget(_chat(second, registry));
      await tester.pumpAndSettle();

      final digest = find.byKey(const ValueKey('acp-unread-digest-text'));
      expect(digest, findsOneWidget);
      expect(
        tester.widget<Text>(digest).data,
        'Since you left: 1 reply · 1 tool call (1 edit) · '
        '1 reported file change',
      );
      expect(find.text('unread since you left'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('acp-unread-jump')));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);
      final divider = find.text('unread since you left');
      expect(divider, findsOneWidget);
      final transcript = tester.getRect(find.byType(AcpMessageThread));
      final dividerRect = tester.getRect(divider);
      final firstUnread = tester.getRect(find.text('Edit main.dart'));
      // The divider and the first unread row sit on screen, below the
      // pinned prompt summary (44 pt) at the top of the transcript.
      expect(dividerRect.top, greaterThanOrEqualTo(transcript.top + 44));
      expect(firstUnread.top, greaterThan(dividerRect.top));
      expect(firstUnread.bottom, lessThan(transcript.top + 200));
    });

    testWidgets('dismissing hides the digest but keeps the divider', (
      tester,
    ) async {
      final registry = AcpLastSeenRegistry();
      final source = Object();
      final before = fakeAcpSession(
        timeline: d.AcpTimeline(
          entries: [_message(d.AcpMessageRole.user, 0, 'Go')],
          source: source,
        ),
      );
      registry.record(fakeAcpKey(), before.timeline);
      final after = before.copyWith(
        timeline: d.AcpTimeline(
          source: source,
          entries: [
            _message(d.AcpMessageRole.user, 0, 'Go'),
            _message(d.AcpMessageRole.agent, 1, 'Went'),
          ],
        ),
      );
      await tester.pumpWidget(
        _chat(FakeAcpSessionManager(sessions: [after]), registry),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsOneWidget);
      expect(find.text('unread since you left'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);
      expect(find.text('unread since you left'), findsOneWidget);
    });

    testWidgets('a divider that comes back does not replay an old Jump', (
      tester,
    ) async {
      final entries = <AcpTimelineEntry>[
        for (var i = 0; i < 40; i++)
          AcpAssistantMessageEntry(
            id: 'agent-$i',
            markdown: 'Reply $i\n\nfiller paragraph',
          ),
      ];
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget thread(AcpThreadUnreadDivider? divider, int serial, {Key? key}) =>
          _app(
            AcpMessageThread(
              key: key,
              entries: entries,
              controller: controller,
              unreadDivider: divider,
              unreadJumpSerial: serial,
            ),
          );
      const divider = AcpThreadUnreadDivider(
        entryIndex: 5,
        earlierHistoryUnavailable: false,
      );
      await tester.pumpWidget(thread(null, 0));
      await tester.pumpAndSettle();
      await tester.pumpWidget(thread(divider, 1));
      await tester.pumpAndSettle();
      // The divider goes away (the user sent a prompt), they scroll to the
      // end, and a later visit brings a divider back.
      await tester.pumpWidget(thread(null, 1));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final bottom = controller.offset;
      await tester.pumpWidget(thread(divider, 1));
      await tester.pumpAndSettle();
      expect(controller.offset, bottom);

      // A transcript rebuilt from scratch without a divider (a rotation
      // across the wide breakpoint, Reconnect) does not replay it either.
      await tester.pumpWidget(thread(null, 1, key: const ValueKey('remount')));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final remountedBottom = controller.offset;
      await tester.pumpWidget(
        thread(divider, 1, key: const ValueKey('remount')),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, remountedBottom);
    });

    testWidgets('the digest live region keeps one label as counts grow', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      Widget bar(int replies) => _app(
        AcpUnreadDigestBar(
          state: AcpUnreadState(
            dividerEntryIndex: 2,
            earlierHistoryUnavailable: false,
            digest: AcpUnreadDigest(replies: replies),
          ),
          onJump: () {},
          onDismiss: () {},
        ),
      );
      await tester.pumpWidget(bar(1));
      final live = find.byKey(const ValueKey('acp-unread-digest'));
      final first = tester.getSemantics(live);
      expect(first.label, 'Unread since you left');
      expect(first.flagsCollection.isLiveRegion, isTrue);
      await tester.pumpWidget(bar(2));
      expect(tester.getSemantics(live).label, 'Unread since you left');
      // The counts are still readable, in their own node.
      expect(
        find.bySemanticsLabel('Since you left: 2 replies'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('a request with no row to jump to offers no Jump', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AcpUnreadDigestBar(
            state: const AcpUnreadState(
              dividerEntryIndex: null,
              earlierHistoryUnavailable: false,
              digest: AcpUnreadDigest(pendingRequests: 1),
            ),
            onJump: () {},
            onDismiss: () {},
          ),
        ),
      );
      expect(find.text('Since you left: 1 request waiting'), findsOneWidget);
      expect(find.byKey(const ValueKey('acp-unread-jump')), findsNothing);
      final dismiss = tester.getSize(find.byTooltip('Dismiss'));
      expect(dismiss.width, greaterThanOrEqualTo(48));
      expect(dismiss.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the divider arriving keeps an expanded tool card open', (
      tester,
    ) async {
      final entries = <AcpTimelineEntry>[
        AcpToolCallEntry(
          id: 'tool',
          toolCall: AcpToolCall(
            id: 'tool',
            title: 'Run build',
            status: AcpToolStatus.completed,
            rawOutput: 'build output line',
          ),
        ),
      ];
      Widget thread(AcpThreadUnreadDivider? divider) =>
          _app(AcpMessageThread(entries: entries, unreadDivider: divider));
      await tester.pumpWidget(thread(null));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run build'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('build output line', findRichText: true),
        findsWidgets,
      );
      await tester.pumpWidget(
        thread(
          const AcpThreadUnreadDivider(
            entryIndex: 0,
            earlierHistoryUnavailable: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('unread since you left'), findsOneWidget);
      expect(
        find.textContaining('build output line', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('the thread reports the last entry on screen', (tester) async {
      final entries = <AcpTimelineEntry>[
        for (var i = 0; i < 40; i++)
          AcpAssistantMessageEntry(
            id: 'agent-$i',
            markdown: 'Reply $i\n\nfiller paragraph',
          ),
      ];
      final controller = ScrollController();
      addTearDown(controller.dispose);
      int? lastVisible;
      await tester.pumpWidget(
        _app(
          AcpMessageThread(
            entries: entries,
            controller: controller,
            onLastVisibleEntryChanged: (index) => lastVisible = index,
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(lastVisible, isNotNull);
      expect(lastVisible, lessThan(20));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(lastVisible, 39);
    });

    group('presence', () {
      var now = DateTime(2026, 10, 9, 12);
      setUp(() {
        now = DateTime(2026, 10, 9, 12);
        acpChatPresenceClock = () => now;
      });
      tearDown(() => acpChatPresenceClock = DateTime.now);

      Future<List<String>> pumpPresence(WidgetTester tester) async {
        final events = <String>[];
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: AcpChatPresence(
              onAway: () => events.add('away'),
              onBack: ({required left}) => events.add(left ? 'left' : 'back'),
              child: const Text('chat'),
            ),
          ),
        );
        return events;
      }

      testWidgets('a page pushed over the chat for long enough is leaving', (
        tester,
      ) async {
        final events = await pumpPresence(tester);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const Text('files')),
          ),
        );
        await tester.pumpAndSettle();
        expect(events, ['away']);
        now = now.add(kAcpChatMinimumAbsence);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(events, ['away', 'left']);
      });

      testWidgets('a quick menu or sheet over the chat is not leaving', (
        tester,
      ) async {
        final events = await pumpPresence(tester);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const Text('menu')),
          ),
        );
        await tester.pumpAndSettle();
        now = now.add(const Duration(seconds: 3));
        navigator.pop();
        await tester.pumpAndSettle();
        expect(events, ['away', 'back']);
      });

      testWidgets('hiding the app counts once it lasts long enough', (
        tester,
      ) async {
        final events = await pumpPresence(tester);
        void lifecycle(List<AppLifecycleState> states) {
          for (final state in states) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }

        lifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden]);
        // A system file picker returns within seconds.
        now = now.add(const Duration(seconds: 8));
        lifecycle([AppLifecycleState.inactive, AppLifecycleState.resumed]);
        expect(events, ['away', 'back']);

        lifecycle([
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]);
        now = now.add(const Duration(minutes: 5));
        lifecycle([
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]);
        expect(events, ['away', 'back', 'away', 'left']);
      });
    });

    testWidgets('sending a prompt from the chat clears the divider', (
      tester,
    ) async {
      final registry = AcpLastSeenRegistry();
      final builder = d.AcpTimelineBuilder()
        ..appendLocalUserPrompt(const [AcpTextContent('Go')]);
      final before = fakeAcpSession(timeline: builder.snapshot());
      registry.record(fakeAcpKey(), before.timeline);
      builder.apply(
        const d.AcpContentChunkUpdate(
          kind: 'agent_message_chunk',
          content: AcpTextContent('Went'),
        ),
      );
      final manager = FakeAcpSessionManager(
        sessions: [before.copyWith(timeline: builder.snapshot())],
      );
      await tester.pumpWidget(_chat(manager, registry));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsOneWidget);

      builder.appendLocalUserPrompt(const [AcpTextContent('And now?')]);
      manager.emit(
        AcpSessionManagerState(
          sessions: [before.copyWith(timeline: builder.snapshot())],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);
      expect(find.text('unread since you left'), findsNothing);
    });

    testWidgets('coming back to the app after a while shows what arrived', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 9, 12);
      acpChatPresenceClock = () => now;
      addTearDown(() => acpChatPresenceClock = DateTime.now);
      final source = Object();
      AcpSessionState session(int replies) => fakeAcpSession(
        timeline: d.AcpTimeline(
          source: source,
          entries: [
            _message(d.AcpMessageRole.user, 0, 'Go'),
            for (var i = 1; i <= replies; i++)
              _message(d.AcpMessageRole.agent, i, 'Reply $i'),
          ],
        ),
      );
      final manager = FakeAcpSessionManager(sessions: [session(1)]);
      await tester.pumpWidget(_chat(manager, AcpLastSeenRegistry()));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      manager.emit(AcpSessionManagerState(sessions: [session(3)]));
      await tester.pump();
      now = now.add(const Duration(minutes: 2));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('acp-unread-digest-text')))
            .data,
        'Since you left: 1 reply',
      );
    });
  });
}
