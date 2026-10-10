// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_mcp_server.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_session_workspace.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_worktree_launcher.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/acp_new_session_sheet.dart';

import '../helpers/mocks.dart';
import '../support/fake_acp_session_manager.dart';
import '../support/fake_agent_worktree.dart';

class _FakeActiveSessions extends ActiveSessionsNotifier {
  _FakeActiveSessions({
    this.result = const SshConnectionResult(success: true, connectionId: 1),
  });

  final SshConnectionResult result;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    if (!result.success) {
      reportConnectionAttemptError(hostId, result.error ?? 'Connection failed');
    }
    return result;
  }
}

class _MockSshService extends Mock implements SshService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

/// A connected session whose provider probe resolves Cursor Agent.
SshSession _cursorSession() {
  final client = MockSshClient();
  final exec = MockSSHSession();
  when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
  when(() => exec.stdout).thenAnswer(
    (_) => Stream.value(
      Uint8List.fromList(
        utf8.encode('cursor-agent\u001f/Users/demo/.local/bin/cursor-agent\n'),
      ),
    ),
  );
  when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
  when(() => exec.done).thenAnswer((_) => Future<void>.value());
  when(exec.close).thenAnswer((_) {});
  when(() => client.execute(any(), pty: any(named: 'pty')))
      .thenAnswer((_) async => exec);
  return SshSession(
    connectionId: 7,
    hostId: 1,
    client: client,
    config: const SshConnectionConfig(
      hostname: 'alpha.example.com',
      port: 22,
      username: 'root',
    ),
  );
}

/// Records the prompts a launch sends, and can hold a start open.
class _PromptRecordingManager extends FakeAcpSessionManager {
  final prompts = <List<AcpContentBlock>>[];

  /// Holds [startNewSession] until completed.
  Completer<void>? startGate;

  /// Throws synchronously from [prompt], like an untracked session key.
  bool promptThrows = false;

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) {
    if (promptThrows) throw StateError('Session is not tracked.');
    prompts.add(content);
    return Future.value(
      const AcpPromptResult(stopReason: AcpStopReason.endTurn),
    );
  }

  @override
  Future<AcpSessionLaunchResult> startNewSession({
    required int hostId,
    required String providerId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpAuthenticationChooser? chooseAuthentication,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
    AcpSessionWorkspaceOptions? workspace,
  }) async {
    await startGate?.future;
    return super.startNewSession(
      hostId: hostId,
      providerId: providerId,
      cwd: cwd,
      confirmInstall: confirmInstall,
      chooseAuthentication: chooseAuthentication,
      launchCommandOverride: launchCommandOverride,
      providerLabelOverride: providerLabelOverride,
      autoApprovePermissions: autoApprovePermissions,
      replace: replace,
      workspace: workspace,
    );
  }
}

class _FailingRecentSessionsManager extends FakeAcpSessionManager {
  @override
  Future<List<AcpRecentSessionRef>> loadRecentSessions() async =>
      throw StateError('Recents unavailable');
}

Host _host({
  int id = 1,
  String? tmuxWorkingDirectory,
  String? remoteMuxBackend,
}) => Host(
  id: id,
  label: 'Alpha',
  hostname: 'alpha.example.com',
  port: 22,
  username: 'root',
  password: null,
  keyId: null,
  groupId: null,
  jumpHostId: null,
  isFavorite: false,
  color: null,
  notes: null,
  tags: null,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastConnectedAt: null,
  terminalThemeLightId: null,
  terminalThemeDarkId: null,
  terminalFontFamily: null,
  autoConnectCommand: null,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  tmuxSessionName: null,
  tmuxWorkingDirectory: tmuxWorkingDirectory,
  tmuxExtraFlags: null,
  remoteMuxBackend: remoteMuxBackend,
  autoForwardPorts: false,
  sortOrder: 0,
);

/// Pumps a launcher button that opens the new-session sheet, capturing the
/// returned key. Returns a getter for the captured key.
Future<AcpSessionKey? Function()> _pumpAndLaunch(
  WidgetTester tester,
  FakeAcpSessionManager manager, {
  AgentLaunchPreset? preset,
  Error? presetError,
  int? initialHostId = 1,
  String? initialProviderId = AcpBuiltinProviderIds.copilotCli,
  String? initialWorkingDirectory,
  bool lockHost = false,
  bool lockProvider = false,
  bool startSession = true,
  bool startInYoloMode = false,
  SshConnectionResult connectionResult = const SshConnectionResult(
    success: true,
    connectionId: 1,
  ),
  SshSession? activeSession,
  List<AcpProvider>? providers,
  AgentWorktreeLauncher? worktreeLauncher,
}) async {
  AcpSessionKey? returned;
  var completed = false;
  final ssh = _MockSshService();
  final presetService = _MockAgentLaunchPresetService();
  final launchPreferencesService = _MockHostCliLaunchPreferencesService();
  when(() => ssh.allSessions).thenReturn(<SshSession>[?activeSession]);
  when(() => ssh.getSessionsForHost(any()))
      .thenReturn(<SshSession>[?activeSession]);
  when(() => ssh.getSession(any())).thenReturn(activeSession);
  when(presetService.getAllPresets).thenAnswer((_) async {
    if (presetError != null) {
      throw presetError;
    }
    return {1: ?preset};
  });
  when(() => launchPreferencesService.getPreferencesForHost(any())).thenAnswer(
    (_) async => HostCliLaunchPreferences(startInYoloMode: startInYoloMode),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        acpSessionManagerProvider.overrideWithValue(manager),
        activeSessionsProvider.overrideWith(
          () => _FakeActiveSessions(result: connectionResult),
        ),
        sshServiceProvider.overrideWithValue(ssh),
        agentLaunchPresetServiceProvider.overrideWithValue(presetService),
        hostCliLaunchPreferencesServiceProvider.overrideWithValue(
          launchPreferencesService,
        ),
        allHostsProvider.overrideWith((ref) => Stream.value(<Host>[_host()])),
        if (worktreeLauncher != null)
          agentWorktreeLauncherProvider.overrideWithValue(worktreeLauncher),
        acpProvidersProvider.overrideWith(
          (ref) => Stream.value(
            providers ??
                <AcpProvider>[
                  for (final builtin in acpBuiltinProviders) builtin,
                ],
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                returned = await showAcpNewSessionSheet(
                  context,
                  initialHostId: initialHostId,
                  initialProviderId: initialProviderId,
                  initialWorkingDirectory: initialWorkingDirectory,
                  lockHost: lockHost,
                  lockProvider: lockProvider,
                );
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (startSession) {
    final startButton = find.widgetWithText(FilledButton, 'Start session');
    await tester.ensureVisible(startButton);
    await tester.pumpAndSettle();
    await tester.tap(startButton);
    await tester.pumpAndSettle();
  }
  return () => completed ? returned : null;
}

void main() {
  final key = fakeAcpKey();

  group('host preset worktree and initial prompt', () {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.cursorAgent,
      workingDirectory: '~/src/app',
      worktree: AgentWorktreeLaunchOptions(baseRef: 'origin/main'),
      initialPrompt: 'Read AGENTS.md and list the open tasks.',
    );
    final cursorKey = fakeAcpKey(providerId: AcpBuiltinProviderIds.cursorAgent);
    late FakeAgentWorktreeService worktrees;
    late MemoryAgentWorktreeRegistry registry;
    late AgentWorktreeLauncher launcher;

    setUp(() {
      worktrees = FakeAgentWorktreeService();
      registry = MemoryAgentWorktreeRegistry();
      launcher = AgentWorktreeLauncher(
        service: worktrees,
        registry: registry,
        wait: (_) async {},
      );
    });

    testWidgets('starts in a new worktree and sends the prompt exactly once', (
      tester,
    ) async {
      final manager = _PromptRecordingManager()
        ..startNewSessionResult = AcpSessionLaunchStarted(cursorKey);

      final result = await _pumpAndLaunch(
        tester,
        manager,
        preset: preset,
        initialProviderId: AcpBuiltinProviderIds.cursorAgent,
        activeSession: _cursorSession(),
        worktreeLauncher: launcher,
      );

      expect(result(), cursorKey);
      final record = worktrees.created.single;
      expect(record.branch, startsWith('agent/cursor-agent-'));
      expect(manager.starts.single.cwd, record.startDirectory);
      expect(manager.prompts, hasLength(1));
      expect(
        (manager.prompts.single.single as AcpTextContent).text,
        'Read AGENTS.md and list the open tasks.',
      );
      expect(worktrees.removed, isEmpty);
      expect(registry.records, [record]);
    });

    testWidgets(
      'swiping the sheet away mid-launch keeps the worktree of a session that '
      'starts',
      (tester) async {
        final manager = _PromptRecordingManager()
          ..startGate = Completer<void>()
          ..startNewSessionResult = AcpSessionLaunchStarted(cursorKey);

        final result = await _pumpAndLaunch(
          tester,
          manager,
          preset: preset,
          initialProviderId: AcpBuiltinProviderIds.cursorAgent,
          activeSession: _cursorSession(),
          worktreeLauncher: launcher,
          startSession: false,
        );
        final startButton = find.widgetWithText(FilledButton, 'Start session');
        await tester.ensureVisible(startButton);
        await tester.pumpAndSettle();
        await tester.tap(startButton);
        // The Start button spins while the launch is held, so pump by time.
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(worktrees.created, hasLength(1));
        // The drag handle pops the route directly, past the PopScope guard.
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        expect(find.text('new agent session'), findsNothing);

        manager.startGate!.complete();
        await tester.pumpAndSettle();

        expect(result(), isNull);
        expect(worktrees.removed, isEmpty);
        expect(registry.records, worktrees.created);
        expect(manager.prompts, hasLength(1));
      },
    );

    testWidgets(
      'a prompt that cannot be sent still reports the session started',
      (tester) async {
        final manager = _PromptRecordingManager()
          ..promptThrows = true
          ..startNewSessionResult = AcpSessionLaunchStarted(cursorKey);

        final result = await _pumpAndLaunch(
          tester,
          manager,
          preset: preset,
          initialProviderId: AcpBuiltinProviderIds.cursorAgent,
          activeSession: _cursorSession(),
          worktreeLauncher: launcher,
        );

        expect(result(), cursorKey);
        expect(
          find.text('Could not start the session. Try again.'),
          findsNothing,
        );
        expect(worktrees.removed, isEmpty);
      },
    );

    testWidgets('rolls the worktree back when the session fails to start', (
      tester,
    ) async {
      final manager = _PromptRecordingManager()
        ..startNewSessionResult = const AcpSessionLaunchFailed(
          null,
          AcpSessionError(
            kind: AcpSessionErrorKind.unknown,
            message: 'The agent exited.',
          ),
        );

      await _pumpAndLaunch(
        tester,
        manager,
        preset: preset,
        initialProviderId: AcpBuiltinProviderIds.cursorAgent,
        activeSession: _cursorSession(),
        worktreeLauncher: launcher,
      );

      expect(find.text('The agent exited.'), findsOneWidget);
      expect(worktrees.removed, worktrees.created);
      expect(worktrees.created, hasLength(1));
      expect(registry.records, isEmpty);
      expect(manager.prompts, isEmpty);
    });

    testWidgets('both preset options can be turned off for one start', (
      tester,
    ) async {
      final manager = _PromptRecordingManager()
        ..startNewSessionResult = AcpSessionLaunchStarted(cursorKey);

      final result = await _pumpAndLaunch(
        tester,
        manager,
        preset: preset,
        initialProviderId: AcpBuiltinProviderIds.cursorAgent,
        activeSession: _cursorSession(),
        worktreeLauncher: launcher,
        startSession: false,
      );
      final worktreeSwitch = find.byKey(
        const Key('acp-new-session-worktree-switch'),
      );
      final promptSwitch = find.byKey(
        const Key('acp-new-session-initial-prompt-switch'),
      );
      expect(find.text('origin/main · ~/src/app'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('acp-new-session-cwd-field')),
            )
            .enabled,
        isFalse,
      );
      await tester.ensureVisible(worktreeSwitch);
      await tester.tap(worktreeSwitch);
      await tester.ensureVisible(promptSwitch);
      await tester.tap(promptSwitch);
      await tester.pumpAndSettle();
      final startButton = find.widgetWithText(FilledButton, 'Start session');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pumpAndSettle();

      expect(result(), cursorKey);
      expect(worktrees.created, isEmpty);
      expect(manager.starts.single.cwd, '~/src/app');
      expect(manager.prompts, isEmpty);
    });
  });

  testWidgets('generic sheet launches Cursor through its resolved binary', (
    tester,
  ) async {
    final client = MockSshClient();
    final exec = MockSSHSession();
    when(() => exec.stdout).thenAnswer(
      (_) => Stream.value(
        Uint8List.fromList(
          utf8.encode(
            'cursor-agent\u001f/Users/demo/.local/bin/cursor-agent\n',
          ),
        ),
      ),
    );
    when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
    when(() => exec.done).thenAnswer((_) => Future<void>.value());
    when(exec.close).thenAnswer((_) {});
    when(() => client.execute(any(), pty: any(named: 'pty')))
        .thenAnswer((_) async => exec);
    final activeSession = SshSession(
      connectionId: 7,
      hostId: 1,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'alpha.example.com',
        port: 22,
        username: 'root',
      ),
    );
    final cursorKey = fakeAcpKey(providerId: AcpBuiltinProviderIds.cursorAgent);
    final manager = FakeAcpSessionManager()
      ..startNewSessionResult = AcpSessionLaunchStarted(cursorKey);

    final result = await _pumpAndLaunch(
      tester,
      manager,
      initialProviderId: AcpBuiltinProviderIds.cursorAgent,
      activeSession: activeSession,
    );

    expect(result(), cursorKey);
    expect(manager.startLaunchOverrides, hasLength(1));
    expect(
      manager.startLaunchOverrides.single?.executable,
      '/Users/demo/.local/bin/cursor-agent',
    );
    expect(manager.startLaunchOverrides.single?.arguments, ['acp']);
  });

  testWidgets('MonkeyMux launch locks host/provider and inherits window cwd', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await _pumpAndLaunch(
      tester,
      manager,
      initialWorkingDirectory: '/home/dev/current-worktree',
      lockHost: true,
      lockProvider: true,
      startSession: false,
    );

    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Copilot CLI'), findsOneWidget);
    expect(find.text('OpenCode'), findsNothing);
    final cwd = tester.widget<TextField>(find.byType(TextField));
    expect(cwd.controller?.text, '/home/dev/current-worktree');

    await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
    await tester.pumpAndSettle();

    expect(manager.starts, [
      (
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/home/dev/current-worktree',
      ),
    ]);
  });

  testWidgets('locked missing provider cannot silently fall back', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await _pumpAndLaunch(
      tester,
      manager,
      initialProviderId: 'removed-provider',
      lockHost: true,
      lockProvider: true,
      startSession: false,
    );

    expect(find.text('Agent provider unavailable'), findsOneWidget);
    final startButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start session'),
    );
    expect(startButton.onPressed, isNull);
    expect(manager.starts, isEmpty);
  });

  test('launch defaults prefer a host saved agent and MonkeyMux setup', () {
    final plainHost = _host(id: 1);
    final configuredHost = _host(
      id: 2,
      tmuxWorkingDirectory: '/mux-default',
      remoteMuxBackend: RemoteMuxBackend.monkeyMux.storageValue,
    );
    final defaults = resolveAcpSessionLaunchDefaults(
      hosts: [plainHost, configuredHost],
      providers: [for (final builtin in acpBuiltinProviders) builtin],
      recents: const [],
      activeHostIds: const {},
      presets: const {
        2: AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '/saved-agent-worktree',
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
      },
    );

    expect(defaults.hostId, 2);
    expect(defaults.providerId, AcpBuiltinProviderIds.openCode);
    expect(defaults.cwd, '/saved-agent-worktree');
  });

  testWidgets('successful launch returns its key without a config page', (
    tester,
  ) async {
    final session = fakeAcpSession(
      key: key,
      configOptions: const [
        AcpSelectConfigOption(
          id: 'style',
          name: 'Style',
          currentValue: 'a',
          options: [
            AcpConfigValue(value: 'a', name: 'Alpha'),
            AcpConfigValue(value: 'b', name: 'Beta'),
          ],
        ),
      ],
    );
    final manager = FakeAcpSessionManager(sessions: [session])
      ..startNewSessionResult = AcpSessionLaunchStarted(key);

    final result = await _pumpAndLaunch(tester, manager, startInYoloMode: true);
    await tester.pumpAndSettle();

    expect(result(), key);
    expect(find.text('configure session'), findsNothing);
    expect(find.text('Style'), findsNothing);
    expect(manager.configOptionSets, isEmpty);
    expect(manager.startAutoApprovePermissions, [true]);
  });

  testWidgets(
    'defaults to the host saved agent provider and working directory',
    (tester) async {
      final manager = FakeAcpSessionManager();
      final ssh = _MockSshService();
      final presetService = _MockAgentLaunchPresetService();
      final host = _host(
        tmuxWorkingDirectory: '/mux-default',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux.storageValue,
      );
      when(() => ssh.allSessions).thenReturn(const <SshSession>[]);
      when(() => ssh.getSessionsForHost(any()))
          .thenReturn(const <SshSession>[]);
      when(presetService.getAllPresets).thenAnswer(
        (_) async => {
          host.id: const AgentLaunchPreset(
            tool: AgentLaunchTool.openCode,
            workingDirectory: '/saved-agent-worktree',
            tmuxSessionName: 'agents',
            remoteMuxBackend: RemoteMuxBackend.monkeyMux,
          ),
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            acpSessionManagerProvider.overrideWithValue(manager),
            activeSessionsProvider.overrideWith(_FakeActiveSessions.new),
            sshServiceProvider.overrideWithValue(ssh),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            allHostsProvider.overrideWith((ref) => Stream.value(<Host>[host])),
            acpProvidersProvider.overrideWith(
              (ref) => Stream.value(<AcpProvider>[
                for (final builtin in acpBuiltinProviders) builtin,
              ]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showAcpNewSessionSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final openCodeChip = tester.widget<InputChip>(
        find.descendant(
          of: find.byKey(
            const ValueKey('provider-${AcpBuiltinProviderIds.openCode}'),
          ),
          matching: find.byType(InputChip),
        ),
      );
      expect(openCodeChip.selected, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/saved-agent-worktree',
      );
    },
  );

  for (final failedRead in ['recents', 'preset']) {
    for (final locked in [false, true]) {
      testWidgets(
        '$failedRead failure uses fallback defaults, locked=$locked',
        (tester) async {
          final manager = failedRead == 'recents'
              ? _FailingRecentSessionsManager()
              : FakeAcpSessionManager(
                  recents: [
                    AcpRecentSessionRef(
                      hostId: 1,
                      providerId: AcpBuiltinProviderIds.openCode,
                      bridgeId: 'bridge-1',
                      acpSessionId: 'session-1',
                      cwd: '/recent',
                      createdAt: DateTime(2026),
                      lastActivityAt: DateTime(2026),
                    ),
                  ],
                  lastSelected: fakeAcpKey(
                    providerId: AcpBuiltinProviderIds.openCode,
                  ),
                );
          addTearDown(manager.dispose);
          await _pumpAndLaunch(
            tester,
            manager,
            presetError: failedRead == 'preset'
                ? StateError('No preset')
                : null,
            initialHostId: locked ? 1 : null,
            initialProviderId: locked ? AcpBuiltinProviderIds.openCode : null,
            initialWorkingDirectory: locked ? '/explicit' : null,
            lockHost: locked,
            lockProvider: locked,
          );

          expect(manager.starts, [
            (
              hostId: 1,
              providerId: locked
                  ? AcpBuiltinProviderIds.openCode
                  : AcpBuiltinProviderIds.copilotCli,
              cwd: locked ? '/explicit' : '~',
            ),
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('selecting a recent session exposes a Resume session button', (
    tester,
  ) async {
    final now = DateTime(2026);
    final recent = AcpRecentSessionRef(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      bridgeId: 'bridge-1',
      acpSessionId: 'session-1',
      cwd: '/home/repo',
      createdAt: now,
      lastActivityAt: now,
    );
    final manager = FakeAcpSessionManager(recents: [recent]);
    await _pumpAndLaunch(
      tester,
      manager,
      initialHostId: 1,
      initialProviderId: AcpBuiltinProviderIds.copilotCli,
      startSession: false,
    );

    await tester.ensureVisible(find.text('Resume …/repo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume …/repo'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Resume session'), findsOneWidget);
  });

  testWidgets('surfaces the saved-host SSH failure before starting an agent', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await _pumpAndLaunch(
      tester,
      manager,
      startSession: false,
      connectionResult: const SshConnectionResult(
        success: false,
        error: 'Authentication failed. Check this host’s credentials.',
      ),
    );

    final startButton = find.widgetWithText(FilledButton, 'Start session');
    await tester.ensureVisible(startButton);
    await tester.pumpAndSettle();
    await tester.tap(startButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Connection failed'), findsOneWidget);
    expect(
      find.text('Authentication failed. Check this host’s credentials.'),
      findsWidgets,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();

    expect(
      find.text('Authentication failed. Check this host’s credentials.'),
      findsOneWidget,
    );
  });

  group('agent sign-in', () {
    const agentLogin = AcpAuthMethod(
      id: 'agent-login',
      name: 'Agent login',
      description: 'Sign in with the agent.',
    );
    const terminalLogin = AcpAuthMethod(
      id: 'terminal-login',
      name: 'Terminal login',
      type: AcpAuthMethod.terminalType,
      args: ['--login'],
    );
    const authRequired = AcpSessionLaunchFailed(
      null,
      AcpSessionError(
        kind: AcpSessionErrorKind.authenticationRequired,
        message: 'The agent requires authentication.',
      ),
    );

    AcpAuthenticationRequest requestFor(List<AcpAuthMethod> methods) =>
        AcpAuthenticationRequest(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          providerLabel: 'Copilot CLI',
          methods: methods,
          authenticate: (_, {cancellation}) async => null,
        );

    testWidgets('offers the agent methods and skips the legacy prompt when '
        'declined', (tester) async {
      final manager = FakeAcpSessionManager()
        ..authenticationRequest = requestFor(const [agentLogin, terminalLogin])
        ..startNewSessionResult = authRequired;
      await _pumpAndLaunch(tester, manager, startSession: false);
      final startButton = find.widgetWithText(FilledButton, 'Start session');
      await tester.ensureVisible(startButton);
      await tester.pumpAndSettle();
      await tester.tap(startButton);
      // The Start button spins while the chooser is open, so pump by time.
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(manager.startChoosers.single, isNotNull);
      expect(find.text('sign in to Copilot CLI'), findsOneWidget);
      expect(find.text('Agent login'), findsOneWidget);
      expect(find.text('Sign in with the agent.'), findsOneWidget);
      expect(find.text('Terminal login'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      expect(find.text('agent'), findsOneWidget);
      expect(find.text('Copy CLI sign-in command'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(manager.authenticationChoices, [null]);
      expect(find.text('Sign in required'), findsNothing);
      expect(
        find.text('Sign in to the agent to start this session.'),
        findsOneWidget,
      );
    });

    /// An SSH session whose every command, including the sign-in terminal,
    /// exits with status zero. Records each command and its PTY request.
    SshSession signInSession({
      List<String>? commands,
      List<SSHPtyConfig?>? ptys,
    }) {
      registerFallbackValue(const SSHPtyConfig());
      final client = MockSshClient();
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands?.add(invocation.positionalArguments.single as String);
        ptys?.add(invocation.namedArguments[#pty] as SSHPtyConfig?);
        final exec = MockSSHSession();
        when(() => exec.stdout).thenAnswer(
          (_) => Stream.value(
            Uint8List.fromList(utf8.encode('copilot\u001f/usr/bin/copilot\n')),
          ),
        );
        when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
        when(() => exec.done).thenAnswer((_) => Future<void>.value());
        when(() => exec.exitCode).thenReturn(0);
        when(exec.close).thenAnswer((_) {});
        return exec;
      });
      return SshSession(
        connectionId: 7,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'alpha.example.com',
          port: 22,
          username: 'root',
        ),
      );
    }

    testWidgets('a sign-in retry reuses the worktree and prompts once', (
      tester,
    ) async {
      final worktrees = FakeAgentWorktreeService();
      final registry = MemoryAgentWorktreeRegistry();
      final manager = _PromptRecordingManager()
        ..startNewSessionResults.add(
          AcpSessionLaunchFailed(
            null,
            authRequired.error,
            terminalAuthentication: AcpTerminalAuthLaunch.forMethod(
              hostId: 1,
              providerId: AcpBuiltinProviderIds.copilotCli,
              providerLabel: 'Copilot CLI',
              method: terminalLogin,
              launchArgv: const ['/usr/bin/copilot', '--acp'],
              workingDirectory: '/repo',
            ),
          ),
        )
        ..startNewSessionResult = AcpSessionLaunchStarted(key);

      final result = await _pumpAndLaunch(
        tester,
        manager,
        preset: const AgentLaunchPreset(
          tool: AgentLaunchTool.copilotCli,
          workingDirectory: '~/src/app',
          worktree: AgentWorktreeLaunchOptions(),
          initialPrompt: 'Summarise the open tasks.',
        ),
        activeSession: signInSession(),
        worktreeLauncher: AgentWorktreeLauncher(
          service: worktrees,
          registry: registry,
          wait: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(result(), key);
      expect(manager.starts, hasLength(2));
      expect(worktrees.created, hasLength(1));
      expect(manager.starts.map((start) => start.cwd).toSet(), {
        worktrees.created.single.startDirectory,
      });
      expect(worktrees.removed, isEmpty);
      expect(manager.prompts, hasLength(1));
    });

    testWidgets('a terminal method runs in the sign-in terminal and relaunches '
        'after a zero exit status', (tester) async {
      final commands = <String>[];
      final ptys = <SSHPtyConfig?>[];
      final activeSession = signInSession(commands: commands, ptys: ptys);
      final terminalLaunch = AcpTerminalAuthLaunch.forMethod(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        providerLabel: 'Copilot CLI',
        method: terminalLogin,
        launchArgv: const ['/usr/bin/copilot', '--acp'],
        workingDirectory: '/repo',
      );
      final manager = FakeAcpSessionManager()
        ..startNewSessionResults.add(
          AcpSessionLaunchFailed(
            null,
            authRequired.error,
            terminalAuthentication: terminalLaunch,
          ),
        )
        ..startNewSessionResult = AcpSessionLaunchStarted(key);

      final result = await _pumpAndLaunch(
        tester,
        manager,
        activeSession: activeSession,
      );
      await tester.pumpAndSettle();

      expect(result(), key);
      expect(manager.starts, hasLength(2));
      // The retry reuses the resolved launch instead of probing again.
      expect(
        manager.startLaunchOverrides.map((command) => command?.executable),
        ['/usr/bin/copilot', '/usr/bin/copilot'],
      );
      final signIn = commands.last;
      expect(signIn, contains(r"'\''/usr/bin/copilot'\'' '\''--acp'\'' "));
      expect(signIn, contains(r"'\''--login'\''"));
      expect(ptys.last, isNotNull);
    });

    testWidgets('signing in to resume a recent session stops its old agent '
        'first', (tester) async {
      final now = DateTime(2026);
      final recent = AcpRecentSessionRef(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: 'bridge-old',
        acpSessionId: 'session-1',
        cwd: '/home/repo',
        createdAt: now,
        lastActivityAt: now,
      );
      final recentKey = fakeAcpKey(bridgeId: 'bridge-old');
      final manager = FakeAcpSessionManager(recents: [recent])
        ..reconnectSessionResults.add(
          AcpSessionLaunchFailed(
            recentKey,
            authRequired.error,
            terminalAuthentication: AcpTerminalAuthLaunch.forMethod(
              hostId: 1,
              providerId: AcpBuiltinProviderIds.copilotCli,
              providerLabel: 'Copilot CLI',
              method: terminalLogin,
              launchArgv: const ['/usr/bin/copilot', '--acp'],
              workingDirectory: '/home/repo',
            ),
          ),
        )
        ..reconnectSessionResult = AcpSessionLaunchStarted(key);

      final result = await _pumpAndLaunch(
        tester,
        manager,
        activeSession: signInSession(),
        startSession: false,
      );
      await tester.ensureVisible(find.text('Resume …/repo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume …/repo'));
      await tester.pumpAndSettle();
      final resume = find.widgetWithText(FilledButton, 'Resume session');
      await tester.ensureVisible(resume);
      await tester.pumpAndSettle();
      await tester.tap(resume);
      await tester.pumpAndSettle();

      // The agent that refused the session may keep its old credentials, so
      // its bridge is stopped and the retry resumes into a fresh agent.
      expect(manager.stoppedUnusedBridges, [recentKey.value]);
      expect(manager.reconnects, hasLength(2));
      expect(result(), key);
    });
  });

  group('workspace options', () {
    final defaultServer = AcpMcpServerConfig(
      id: 'mcp-a',
      name: 'filesystem',
      transport: AcpMcpServerTransport.stdio,
      command: '/usr/local/bin/mcp-fs',
      useByDefault: true,
    );
    final optionalServer = AcpMcpServerConfig(
      id: 'mcp-b',
      name: 'github',
      transport: AcpMcpServerTransport.http,
      url: 'https://mcp.example.com/mcp',
    );

    Future<void> tapVisible(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    FilterChip chip(WidgetTester tester, String id) => tester
        .widget<FilterChip>(find.byKey(ValueKey('acp-workspace-mcp-$id')));

    testWidgets('preselects default MCP servers and launches with the '
        'adjusted set and additional directories', (tester) async {
      final manager = FakeAcpSessionManager()
        ..mcpServers = [defaultServer, optionalServer]
        ..startNewSessionResult = AcpSessionLaunchStarted(key);
      await _pumpAndLaunch(tester, manager, startSession: false);

      expect(chip(tester, 'mcp-a').selected, isTrue);
      expect(chip(tester, 'mcp-b').selected, isFalse);
      expect(find.text('1 of 2'), findsOneWidget);
      // No directory fields until the user asks for one.
      expect(find.byType(TextField), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('acp-workspace-mcp-mcp-b')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('acp-workspace-mcp-mcp-a')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('acp-workspace-add-directory')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('acp-workspace-directory-0')),
        '  ~/shared-lib  ',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('acp-workspace-add-directory')),
      );
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Start session'),
      );

      final workspace = manager.startWorkspaces.single!;
      expect(workspace.mcpServerIds, ['mcp-b']);
      // The blank second draft is ignored.
      expect(workspace.additionalDirectories, ['~/shared-lib']);
    });

    testWidgets('collapses to one row with a setup shortcut when no MCP '
        'servers are configured', (tester) async {
      final manager = FakeAcpSessionManager()
        ..startNewSessionResult = AcpSessionLaunchStarted(key);
      await _pumpAndLaunch(tester, manager, startSession: false);

      expect(find.text('none'), findsOneWidget);
      expect(find.text('Set up'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Start session'),
      );
      final workspace = manager.startWorkspaces.single!;
      expect(workspace.mcpServerIds, isEmpty);
      expect(workspace.additionalDirectories, isEmpty);
    });

    testWidgets('selecting a recent session applies its saved workspace', (
      tester,
    ) async {
      final now = DateTime(2026);
      final recent = AcpRecentSessionRef(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
        cwd: '/home/repo',
        mcpServerIds: const ['mcp-b'],
        additionalDirectories: const ['/home/docs'],
        createdAt: now,
        lastActivityAt: now,
      );
      final manager = FakeAcpSessionManager(recents: [recent])
        ..mcpServers = [defaultServer, optionalServer]
        ..reconnectSessionResult = AcpSessionLaunchStarted(key);
      await _pumpAndLaunch(tester, manager, startSession: false);

      await tapVisible(tester, find.text('Resume …/repo'));
      expect(chip(tester, 'mcp-a').selected, isFalse);
      expect(chip(tester, 'mcp-b').selected, isTrue);
      expect(find.text('/home/docs'), findsOneWidget);

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Resume session'),
      );
      final workspace = manager.reconnectWorkspaces.single!;
      expect(workspace.mcpServerIds, ['mcp-b']);
      expect(workspace.additionalDirectories, ['/home/docs']);
    });

    testWidgets('returning to a new session restores the defaults', (
      tester,
    ) async {
      final now = DateTime(2026);
      final recent = AcpRecentSessionRef(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
        cwd: '/home/repo',
        mcpServerIds: const <String>[],
        additionalDirectories: const ['/home/docs'],
        createdAt: now,
        lastActivityAt: now,
      );
      final manager = FakeAcpSessionManager(recents: [recent])
        ..mcpServers = [defaultServer, optionalServer];
      await _pumpAndLaunch(tester, manager, startSession: false);

      await tapVisible(tester, find.text('Resume …/repo'));
      expect(chip(tester, 'mcp-a').selected, isFalse);
      await tapVisible(tester, find.text('Start a new session'));
      expect(chip(tester, 'mcp-a').selected, isTrue);
      expect(find.text('/home/docs'), findsNothing);
    });
  });
}
