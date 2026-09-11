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
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/acp_new_session_sheet.dart';

import '../support/fake_acp_session_manager.dart';

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

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

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
}) async {
  AcpSessionKey? returned;
  var completed = false;
  final ssh = _MockSshService();
  final presetService = _MockAgentLaunchPresetService();
  final launchPreferencesService = _MockHostCliLaunchPreferencesService();
  when(() => ssh.allSessions).thenReturn(<SshSession>[?activeSession]);
  when(
    () => ssh.getSessionsForHost(any()),
  ).thenReturn(<SshSession>[?activeSession]);
  when(() => ssh.getSession(any())).thenReturn(activeSession);
  when(() => presetService.getPresetForHost(any())).thenAnswer((_) async {
    if (presetError != null) {
      throw presetError;
    }
    return preset;
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

  testWidgets('provider picker excludes custom ACP definitions', (
    tester,
  ) async {
    final custom = AcpCustomProviderDefinition.create(
      id: 'custom-provider',
      label: 'Custom provider',
      launchCommand: AcpLaunchCommand(executable: '/opt/custom-acp'),
      now: DateTime.utc(2026),
    );

    await _pumpAndLaunch(
      tester,
      FakeAcpSessionManager(),
      startSession: false,
      providers: <AcpProvider>[acpCopilotCliProvider, custom],
    );

    expect(find.text('Copilot CLI'), findsOneWidget);
    expect(find.text('Custom provider'), findsNothing);
    expect(find.text('Add custom provider'), findsNothing);
  });

  testWidgets('generic sheet launches Cursor through its resolved binary', (
    tester,
  ) async {
    final client = _MockSshClient();
    final exec = _MockExecSession();
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
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => exec);
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
      when(
        () => ssh.getSessionsForHost(any()),
      ).thenReturn(const <SshSession>[]);
      when(() => presetService.getPresetForHost(host.id)).thenAnswer(
        (_) async => const AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '/saved-agent-worktree',
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
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
}
