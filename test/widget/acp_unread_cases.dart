// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
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
          unreadDivider: AcpThreadUnreadDivider(
            entryIndex: 5,
            earlierHistoryUnavailable: false,
            jumpSerial: jumpSerial,
          ),
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
      expect(tester.getSize(jump).height, greaterThanOrEqualTo(44));
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
        'Since you left: 19 replies · 1 tool call (1 edit) · '
        '1 reported file change',
      );
      expect(find.text('unread since you left'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('acp-unread-jump')));
      await tester.pumpAndSettle();
      expect(find.byType(AcpUnreadDigestBar), findsNothing);
      final divider = find.text('unread since you left');
      expect(divider, findsOneWidget);
      final dividerTop = tester.getTopLeft(divider).dy;
      final transcriptTop = tester.getTopLeft(find.byType(AcpMessageThread)).dy;
      expect(dividerTop, greaterThanOrEqualTo(transcriptTop));
      expect(dividerTop, lessThan(transcriptTop + 140));
      expect(find.text('Edit main.dart'), findsOneWidget);
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
  });
}
