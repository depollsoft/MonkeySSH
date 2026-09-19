// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/commands/duplicate_host_command.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class _ThrowingPresetService extends AgentLaunchPresetService {
  _ThrowingPresetService(super.settings);

  @override
  Future<void> setPresetForHost(int hostId, AgentLaunchPreset preset) async =>
      throw Exception('simulated preset-write failure');
}

void registerDuplicateHostCommandTests() {
  group('duplicate_host_command', () {
    late AppDatabase db;
    late HostRepository hostRepository;
    late SettingsService settingsService;
    late AgentLaunchPresetService presetService;
    late HostCliLaunchPreferencesService cliPreferencesService;
    late DuplicateHostCommand command;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      hostRepository = HostRepository(db, SecretEncryptionService.forTesting());
      settingsService = SettingsService(db);
      presetService = AgentLaunchPresetService(settingsService);
      cliPreferencesService = HostCliLaunchPreferencesService(settingsService);
      command = DuplicateHostCommand(
        db: db,
        hostRepository: hostRepository,
        presetService: presetService,
        cliPreferencesService: cliPreferencesService,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('preserves a MonkeyMux coding-agent automatic action', () async {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.copilotCli,
        workingDirectory: '~/src/monkeyssh',
        tmuxSessionName: 'coding',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        additionalArguments: '--resume',
      );
      final sourceHostId = await hostRepository.insert(
        HostsCompanion.insert(
          label: 'Coding host',
          hostname: 'dev.example.com',
          username: 'developer',
          autoConnectCommand: Value(
            buildAgentLaunchCommand(preset, startInYoloMode: true),
          ),
        ),
      );
      await presetService.setPresetForHost(sourceHostId, preset);
      await cliPreferencesService.setPreferencesForHost(
        sourceHostId,
        const HostCliLaunchPreferences(startInYoloMode: true),
      );

      final sourceHost = await hostRepository.getById(sourceHostId);
      final duplicateHostId = await command.execute(sourceHost!);

      final duplicateHost = await hostRepository.getById(duplicateHostId);
      final duplicatePreset = await presetService.getPresetForHost(
        duplicateHostId,
      );
      final duplicatePreferences = await cliPreferencesService
          .getPreferencesForHost(duplicateHostId);

      expect(duplicateHost!.autoConnectCommand, sourceHost.autoConnectCommand);
      expect(duplicatePreset, isNotNull);
      expect(duplicatePreset!.tool, AgentLaunchTool.copilotCli);
      expect(duplicatePreset.workingDirectory, '~/src/monkeyssh');
      expect(duplicatePreset.tmuxSessionName, 'coding');
      expect(duplicatePreset.remoteMuxBackend, RemoteMuxBackend.monkeyMux);
      expect(duplicatePreset.additionalArguments, '--resume');
      expect(duplicatePreferences.startInYoloMode, isTrue);
    });

    test('rolls back the duplicated host when preset copying fails', () async {
      const preset = AgentLaunchPreset(tool: AgentLaunchTool.claudeCode);
      final sourceHostId = await hostRepository.insert(
        HostsCompanion.insert(
          label: 'Source host',
          hostname: 'source.example.com',
          username: 'developer',
        ),
      );
      await presetService.setPresetForHost(sourceHostId, preset);
      final throwingCommand = DuplicateHostCommand(
        db: db,
        hostRepository: hostRepository,
        presetService: _ThrowingPresetService(settingsService),
        cliPreferencesService: cliPreferencesService,
      );

      final sourceHost = await hostRepository.getById(sourceHostId);

      await expectLater(throwingCommand.execute(sourceHost!), throwsException);
      expect(await hostRepository.getAll(), hasLength(1));
    });
  });
}
