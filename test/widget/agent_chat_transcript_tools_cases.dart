// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/controllers/acp_chat_actions_controller.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_transcript_search_bar.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockLaunchPreferences extends Mock
    implements HostCliLaunchPreferencesService {}

AcpSessionState _session() => fakeAcpSession(
  title: 'Flaky test hunt',
  timeline: AcpTimeline(
    entries: [
      AcpMessageEntry(
        order: 0,
        role: AcpMessageRole.user,
        content: const [AcpTextContent('Why does CI fail?')],
      ),
      AcpToolCallEntry(
        toolCallId: 'run-tests',
        order: 1,
        title: 'Run tests',
        status: AcpToolStatus.completed,
        content: const [
          AcpToolContentBlock(
            content: AcpTextContent('Expected: haystack-needle found'),
          ),
        ],
      ),
      AcpMessageEntry(
        order: 2,
        role: AcpMessageRole.agent,
        content: const [AcpTextContent('The widget test raced a timer.')],
      ),
    ],
  ),
);

Widget _chat(
  FakeAcpSessionManager manager, {
  bool embedded = false,
  AcpChatActionsController? chatActions,
}) {
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
          embedded: embedded,
          connectOnMount: false,
          chatActions: chatActions,
        ),
      ),
    ),
  );
}

void registerAgentChatTranscriptToolsTests() {
  group('native chat transcript tools', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    testWidgets('search finds tool output and reveals the tool call', (
      tester,
    ) async {
      await tester.pumpWidget(
        _chat(FakeAcpSessionManager(sessions: [_session()])),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('haystack-needle'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('acp-composer-field')),
        'half-written draft',
      );
      await tester.tap(find.byTooltip('Search chat'));
      await tester.pumpAndSettle();
      expect(find.byType(AcpTranscriptSearchBar), findsOneWidget);
      // The bar takes the composer's place at the bottom, in thumb reach.
      expect(find.byType(AcpComposer), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('acp-transcript-search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('tool'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('acp-search-match-highlight')),
        findsOneWidget,
      );
      expect(
        find.textContaining('haystack-needle', findRichText: true),
        findsWidgets,
      );

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.byType(AcpTranscriptSearchBar), findsNothing);
      expect(find.text('half-written draft'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('acp-search-match-highlight')),
        findsNothing,
      );
    });

    testWidgets('Ctrl+F opens search from the composer', (tester) async {
      await tester.pumpWidget(
        _chat(FakeAcpSessionManager(sessions: [_session()])),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('acp-composer-field')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(AcpTranscriptSearchBar), findsOneWidget);
    });

    testWidgets('the overflow menu exports the transcript as Markdown', (
      tester,
    ) async {
      await tester.pumpWidget(
        _chat(FakeAcpSessionManager(sessions: [_session()])),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export transcript'));
      await tester.pumpAndSettle();

      expect(find.text('Export transcript'), findsOneWidget);
      expect(find.textContaining('# Flaky test hunt'), findsOneWidget);
      expect(find.textContaining('**Run tests** · completed'), findsOneWidget);
      expect(find.textContaining('haystack-needle'), findsNothing);
    });

    testWidgets('an embedding shell opens search and export', (tester) async {
      final actions = AcpChatActionsController();
      await tester.pumpWidget(
        _chat(
          FakeAcpSessionManager(sessions: [_session()]),
          embedded: true,
          chatActions: actions,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Search chat'), findsNothing);
      expect(actions.isAttached, isTrue);

      actions.openSearch();
      await tester.pumpAndSettle();
      expect(find.byType(AcpTranscriptSearchBar), findsOneWidget);

      actions.exportTranscript();
      await tester.pumpAndSettle();
      expect(find.textContaining('# Flaky test hunt'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      expect(actions.isAttached, isFalse);
    });
  });
}
