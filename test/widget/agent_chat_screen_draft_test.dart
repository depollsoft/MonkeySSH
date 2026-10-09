// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';

import '../support/fake_acp_session_manager.dart';
import '../support/memory_settings_service.dart';

class _MockSshService extends Mock implements SshService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

class _PromptRecordingManager extends FakeAcpSessionManager {
  _PromptRecordingManager({super.sessions});

  final List<List<AcpContentBlock>> prompts = <List<AcpContentBlock>>[];

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) async {
    prompts.add(List<AcpContentBlock>.of(content));
    return const AcpPromptResult(stopReason: AcpStopReason.endTurn);
  }
}

ProviderContainer _container(
  SettingsService settings,
  AcpSessionManager manager,
) {
  final ssh = _MockSshService();
  when(() => ssh.getSessionsForHost(any())).thenReturn(const <SshSession>[]);
  final launchPreferences = _MockHostCliLaunchPreferencesService();
  when(() => launchPreferences.getPreferencesForHost(any()))
      .thenAnswer((_) async => const HostCliLaunchPreferences());
  final container = ProviderContainer(
    overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
      hostCliLaunchPreferencesServiceProvider.overrideWithValue(
        launchPreferences,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _app(ProviderContainer container, {bool showChat = true}) {
  final key = fakeAcpKey();
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: showChat
          ? AgentChatScreen(
              hostId: key.hostId,
              providerId: key.providerId,
              bridgeId: key.bridgeId,
              acpSessionId: key.acpSessionId,
              connectOnMount: false,
              attachmentActionsBuilder: (_, _) =>
                  const AcpComposerAttachmentActions(),
            )
          : const SizedBox(),
    ),
  );
}

Iterable<String> _savedDraftKeys(MemorySettingsService settings) =>
    settings.values.keys.where(SettingKeys.isAcpComposerDraft);

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('a draft typed before the OS evicts the app comes back on the '
      'next launch, unsent until Send is tapped', (tester) async {
    final settings = MemorySettingsService();
    final firstRun = _PromptRecordingManager(sessions: [fakeAcpSession()]);
    addTearDown(firstRun.dispose);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pumpWidget(_app(_container(settings, firstRun)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Check why the deploy failed',
    );
    // Switching to another app saves at once; no typing pause is needed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_savedDraftKeys(settings), hasLength(1));

    // Eviction: the process and everything in memory is gone.
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final nextRun = _PromptRecordingManager(sessions: [fakeAcpSession()]);
    addTearDown(nextRun.dispose);
    await tester.pumpWidget(_app(_container(settings, nextRun)));
    await tester.pumpAndSettle();

    expect(find.text('Check why the deploy failed'), findsOneWidget);
    expect(find.text('unsent draft restored'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(firstRun.prompts, isEmpty);
    expect(nextRun.prompts, isEmpty);

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();

    expect(nextRun.prompts, hasLength(1));
    final text = nextRun.prompts.single.single as AcpTextContent;
    expect(text.text, 'Check why the deploy failed');
    expect(_savedDraftKeys(settings), isEmpty);
    expect(find.text('unsent draft restored'), findsNothing);
  });

  testWidgets('switching away and back in the same run keeps the draft '
      'without the restored banner', (tester) async {
    final settings = MemorySettingsService();
    final manager = _PromptRecordingManager(sessions: [fakeAcpSession()]);
    addTearDown(manager.dispose);
    final container = _container(settings, manager);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Half a thought');
    await tester.pump();

    await tester.pumpWidget(_app(container, showChat: false));
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Half a thought'), findsOneWidget);
    expect(find.text('unsent draft restored'), findsNothing);
    expect(manager.prompts, isEmpty);
  });
}
