// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_workspace.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/acp_custom_provider_host_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/acp_new_session_sheet.dart';

import '../helpers/mocks.dart';
import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

class _FakeActiveSessions extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};
}

class _FakeHostService extends AcpCustomProviderHostService {
  _FakeHostService({this.unset = const <String>[], this.listing});

  final List<String> unset;
  final AcpCustomAgentSessionListing? listing;
  final List<String> checkedIds = [];
  int listCalls = 0;

  @override
  Future<List<String>?> findUnsetEnvironmentVariables(
    SshSession session,
    AcpCustomProviderDefinition definition,
  ) async {
    checkedIds.add(definition.id);
    return unset;
  }

  @override
  Future<AcpCustomAgentSessionListing> listSessions(
    SshSession session,
    AcpCustomProviderDefinition definition, {
    int max = 20,
  }) async {
    listCalls++;
    return listing ??
        const AcpCustomAgentSessionListing(
          AcpCustomAgentSessionListStatus.unsupportedAgent,
        );
  }
}

class _ResumingManager extends FakeAcpSessionManager {
  final List<({String providerId, String acpSessionId, String cwd})> resumes =
      [];

  @override
  Future<AcpSessionLaunchResult> resumeProviderSession({
    required int hostId,
    required String providerId,
    required String acpSessionId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    AcpAuthenticationChooser? chooseAuthentication,
    AcpLaunchCommand? launchCommandOverride,
    String? providerLabelOverride,
    bool autoApprovePermissions = false,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
    AcpSessionWorkspaceOptions? workspace,
  }) async {
    resumes.add((providerId: providerId, acpSessionId: acpSessionId, cwd: cwd));
    return AcpSessionLaunchStarted(
      fakeAcpKey(providerId: providerId, acpSessionId: acpSessionId),
    );
  }
}

Host _host() => Host(
  id: 1,
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
  tmuxWorkingDirectory: null,
  tmuxExtraFlags: null,
  remoteMuxBackend: null,
  autoForwardPorts: false,
  sortOrder: 0,
);

AcpCustomProviderDefinition _goose({
  AcpCustomProviderCwdPolicy cwdPolicy =
      AcpCustomProviderCwdPolicy.chosenDirectory,
  List<String> environment = const ['GOOSE_PROVIDER'],
}) => AcpCustomProviderDefinition.create(
  id: 'goose',
  label: 'Goose',
  launchCommand: AcpLaunchCommand(
    executable: 'goose',
    arguments: const ['acp'],
  ),
  environmentVariableNames: environment,
  cwdPolicy: cwdPolicy,
).approve();

Future<void> _pumpSheet(
  WidgetTester tester, {
  required FakeAcpSessionManager manager,
  required _FakeHostService hostService,
  required List<AcpProvider> providers,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final ssh = _MockSshService();
  final session = SshSession(
    connectionId: 7,
    hostId: 1,
    client: MockSshClient(),
    config: const SshConnectionConfig(
      hostname: 'alpha.example.com',
      port: 22,
      username: 'root',
    ),
  );
  when(() => ssh.allSessions).thenReturn(<SshSession>[session]);
  when(() => ssh.getSessionsForHost(any())).thenReturn(<SshSession>[session]);
  when(() => ssh.getSession(any())).thenReturn(session);
  final presets = _MockAgentLaunchPresetService();
  when(presets.getAllPresets).thenAnswer((_) async => {});
  final launchPreferences = _MockHostCliLaunchPreferencesService();
  when(() => launchPreferences.getPreferencesForHost(any()))
      .thenAnswer((_) async => const HostCliLaunchPreferences());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        acpSessionManagerProvider.overrideWithValue(manager),
        activeSessionsProvider.overrideWith(_FakeActiveSessions.new),
        sshServiceProvider.overrideWithValue(ssh),
        agentLaunchPresetServiceProvider.overrideWithValue(presets),
        hostCliLaunchPreferencesServiceProvider.overrideWithValue(
          launchPreferences,
        ),
        acpCustomProviderHostServiceProvider.overrideWithValue(hostService),
        allHostsProvider.overrideWith((ref) => Stream.value(<Host>[_host()])),
        acpProvidersProvider.overrideWith((ref) => Stream.value(providers)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAcpNewSessionSheet(
                context,
                initialHostId: 1,
                initialProviderId: 'goose',
                initialWorkingDirectory: '/repo',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _tapStart(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts an approved custom agent after checking its '
      'environment', (tester) async {
    final goose = _goose();
    final manager = FakeAcpSessionManager()
      ..startNewSessionResult = AcpSessionLaunchStarted(
        fakeAcpKey(providerId: goose.id),
      );
    final hostService = _FakeHostService();
    await _pumpSheet(
      tester,
      manager: manager,
      hostService: hostService,
      providers: [...acpBuiltinProviders, goose],
    );

    expect(find.widgetWithText(InputChip, 'Goose'), findsOneWidget);
    await _tapStart(tester, 'Start session');

    expect(hostService.checkedIds, ['goose']);
    expect(manager.starts, [(hostId: 1, providerId: 'goose', cwd: '/repo')]);
    expect(manager.startLaunchOverrides.single, isNull);
  });

  testWidgets('names unset environment variables instead of launching', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await _pumpSheet(
      tester,
      manager: manager,
      hostService: _FakeHostService(unset: const ['GOOSE_PROVIDER']),
      providers: [...acpBuiltinProviders, _goose()],
    );

    await _tapStart(tester, 'Start session');

    expect(manager.starts, isEmpty);
    expect(
      find.textContaining('GOOSE_PROVIDER is not set on this host'),
      findsOneWidget,
    );
  });

  testWidgets('a home-folder agent shows a fixed home directory', (
    tester,
  ) async {
    final goose = _goose(cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory);
    final manager = FakeAcpSessionManager()
      ..startNewSessionResult = AcpSessionLaunchStarted(
        fakeAcpKey(providerId: goose.id),
      );
    await _pumpSheet(
      tester,
      manager: manager,
      hostService: _FakeHostService(),
      providers: [...acpBuiltinProviders, goose],
    );

    expect(
      find.text('This agent always starts in the home folder.'),
      findsOneWidget,
    );
    // The manager applies the policy; the sheet passes the folder it shows.
    await _tapStart(tester, 'Start session');
    expect(manager.starts.single.providerId, 'goose');
  });

  testWidgets('resumes a session the agent lists through session/list', (
    tester,
  ) async {
    final goose = _goose(environment: const []);
    final manager = _ResumingManager();
    final hostService = _FakeHostService(
      listing: const AcpCustomAgentSessionListing(
        AcpCustomAgentSessionListStatus.listed,
        [
          AcpSessionInfo(
            sessionId: 'goose-session-1',
            cwd: '/work/project',
            title: 'Refactor the parser',
            updatedAt: '2026-10-08T12:00:00Z',
          ),
        ],
      ),
    );
    await _pumpSheet(
      tester,
      manager: manager,
      hostService: hostService,
      providers: [...acpBuiltinProviders, goose],
    );

    await tester.tap(find.byKey(const ValueKey('custom-agent-find-sessions')));
    await tester.pumpAndSettle();
    expect(hostService.listCalls, 1);
    await tester.tap(find.text('Refactor the parser'));
    await tester.pumpAndSettle();

    await _tapStart(tester, 'Resume session');

    expect(manager.resumes, [
      (
        providerId: 'goose',
        acpSessionId: 'goose-session-1',
        cwd: '/work/project',
      ),
    ]);
    expect(manager.starts, isEmpty);
  });

  testWidgets('says when an agent cannot list its sessions', (tester) async {
    await _pumpSheet(
      tester,
      manager: FakeAcpSessionManager(),
      hostService: _FakeHostService(),
      providers: [...acpBuiltinProviders, _goose()],
    );

    await tester.tap(find.byKey(const ValueKey('custom-agent-find-sessions')));
    await tester.pumpAndSettle();

    expect(find.text('This agent doesn’t list its sessions.'), findsOneWidget);
  });

  testWidgets('built-in providers show no custom agent session section', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      manager: FakeAcpSessionManager(),
      hostService: _FakeHostService(),
      providers: acpBuiltinProviders,
    );

    expect(find.text('Agent sessions on this host'), findsNothing);
  });
}
