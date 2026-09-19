// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/group_repository.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/app_review_demo_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import 'app_review_demo_ssh_service_cases.dart';

void main() {
  group('app_review_demo_service', () {
    late AppDatabase database;
    late AppReviewDemoService service;
    late HostRepository hostRepository;
    late KeyRepository keyRepository;
    late SnippetRepository snippetRepository;
    late PortForwardRepository portForwardRepository;
    late AgentLaunchPresetService agentLaunchPresetService;
    late HostCliLaunchPreferencesService cliLaunchPreferencesService;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      final settingsService = SettingsService(database);
      hostRepository = HostRepository(database, encryptionService);
      keyRepository = KeyRepository(database, encryptionService);
      snippetRepository = SnippetRepository(database);
      portForwardRepository = PortForwardRepository(database);
      agentLaunchPresetService = AgentLaunchPresetService(settingsService);
      cliLaunchPreferencesService = HostCliLaunchPreferencesService(
        settingsService,
      );
      service = AppReviewDemoService(
        groupRepository: GroupRepository(database),
        hostRepository: hostRepository,
        keyRepository: keyRepository,
        snippetRepository: snippetRepository,
        portForwardRepository: portForwardRepository,
        agentLaunchPresetService: agentLaunchPresetService,
        hostCliLaunchPreferencesService: cliLaunchPreferencesService,
        settingsService: settingsService,
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('prepare seeds deterministic review data', () async {
      final result = await service.prepare();

      expect(result.createdHosts, 4);
      expect(result.createdKeys, 1);
      expect(result.createdSnippets, 3);
      expect(result.createdPortForwards, 2);
      expect(await service.isPrepared(), isTrue);

      final hosts = await hostRepository.getAll();
      expect(
        hosts.map((host) => host.label),
        containsAll([
          'App Review Demo · MonkeyMux workspace',
          'App Review Demo · MonkeyMux agents',
          'App Review Demo · SFTP and tunnels',
          'App Review Demo · bastion jump host',
        ]),
      );

      final workspaceHost = hosts.singleWhere(
        (host) => host.label == 'App Review Demo · MonkeyMux workspace',
      );
      expect(
        workspaceHost.remoteMuxBackend,
        RemoteMuxBackend.monkeyMux.storageValue,
      );
      expect(workspaceHost.tmuxSessionName, 'review-workspace');
      expect(workspaceHost.terminalThemeDarkId, TerminalThemes.dracula.id);
      expect(workspaceHost.autoConnectRequiresConfirmation, isTrue);

      final agentHost = hosts.singleWhere(
        (host) => host.label == 'App Review Demo · MonkeyMux agents',
      );
      expect(
        agentHost.remoteMuxBackend,
        RemoteMuxBackend.monkeyMux.storageValue,
      );
      expect(agentHost.tmuxSessionName, 'review-agents');
      expect(agentHost.tmuxExtraFlags, isNull);

      final preset = await agentLaunchPresetService.getPresetForHost(
        workspaceHost.id,
      );
      expect(preset, isNotNull);
      expect(preset!.tool, AgentLaunchTool.copilotCli);
      expect(preset.remoteMuxBackend, RemoteMuxBackend.monkeyMux);

      final preferences = await cliLaunchPreferencesService
          .getPreferencesForHost(workspaceHost.id);
      expect(preferences.startInYoloMode, isTrue);

      final portForwards = await portForwardRepository.getAll();
      expect(portForwards.map((forward) => forward.name), [
        'Review web preview',
        'Review API tunnel',
      ]);
    });

    test('prepare is idempotent', () async {
      await service.prepare();
      final secondResult = await service.prepare();

      expect(secondResult.createdHosts, 0);
      expect(secondResult.createdKeys, 0);
      expect(secondResult.createdSnippets, 0);
      expect(secondResult.createdPortForwards, 0);
      expect(await hostRepository.getAll(), hasLength(4));
      expect(await keyRepository.getAll(), hasLength(1));
      expect(await snippetRepository.getAll(), hasLength(3));
      expect(await portForwardRepository.getAll(), hasLength(2));
    });
  });
  registerAppReviewDemoSshServiceTests();
}
