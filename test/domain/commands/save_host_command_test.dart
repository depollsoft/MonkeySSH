// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/commands/save_host_command.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SaveHostInput _minimalInput({
  String label = 'Test Host',
  String hostname = 'example.com',
  int port = 22,
  String username = 'root',
}) => SaveHostInput(
  label: label,
  hostname: hostname,
  port: port,
  username: username,
  autoConnectRequiresConfirmation: false,
  isFavorite: false,
);

/// A [AgentLaunchPresetService] subclass whose [setPresetForHost] always
/// throws, used to trigger transaction rollback in tests.
class _ThrowingPresetService extends AgentLaunchPresetService {
  _ThrowingPresetService(super.settings);

  @override
  Future<void> setPresetForHost(int hostId, AgentLaunchPreset preset) async =>
      throw Exception('simulated preset-write failure');
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late HostRepository hostRepo;
  late AgentLaunchPresetService presetService;
  late HostCliLaunchPreferencesService cliPrefsService;
  late SettingsService settingsService;
  late SaveHostCommand command;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final encryption = SecretEncryptionService.forTesting();
    hostRepo = HostRepository(db, encryption);
    settingsService = SettingsService(db);
    presetService = AgentLaunchPresetService(settingsService);
    cliPrefsService = HostCliLaunchPreferencesService(settingsService);
    command = SaveHostCommand(
      db: db,
      hostRepository: hostRepo,
      presetService: presetService,
      cliPreferencesService: cliPrefsService,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('SaveHostCommand – insert', () {
    test('creates a host and returns its id', () async {
      final id = await command.execute(input: _minimalInput());

      expect(id, greaterThan(0));
      final hosts = await hostRepo.getAll();
      expect(hosts, hasLength(1));
      expect(hosts.first.id, id);
      expect(hosts.first.label, 'Test Host');
      expect(hosts.first.hostname, 'example.com');
      expect(hosts.first.port, 22);
      expect(hosts.first.username, 'root');
    });

    test('stores optional fields when provided', () async {
      const input = SaveHostInput(
        label: 'DB Server',
        hostname: 'db.internal',
        port: 2222,
        username: 'admin',
        password: 'secret',
        tags: 'prod, db',
        autoConnectCommand: 'htop',
        autoConnectRequiresConfirmation: true,
        isFavorite: true,
        tmuxSessionName: 'workspace',
        tmuxWorkingDirectory: '~/src',
        tmuxExtraFlags: '-f ~/.tmux.conf',
        autoForwardPorts: true,
        portProxyName: 'database',
      );
      final id = await command.execute(input: input);

      final host = await hostRepo.getById(id);
      expect(host, isNotNull);
      expect(host!.password, 'secret');
      expect(host.tags, 'prod, db');
      expect(host.autoConnectCommand, 'htop');
      expect(host.autoConnectRequiresConfirmation, isTrue);
      expect(host.isFavorite, isTrue);
      expect(host.tmuxSessionName, 'workspace');
      expect(host.tmuxWorkingDirectory, '~/src');
      expect(host.tmuxExtraFlags, '-f ~/.tmux.conf');
      expect(host.autoForwardPorts, isTrue);
      expect(host.portProxyName, 'database');
    });

    test('saves agent preset when action is SaveAgentPreset', () async {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        tmuxSessionName: 'code',
      );
      final id = await command.execute(
        input: _minimalInput(),
        presetAction: const SaveAgentPreset(preset),
      );

      final stored = await presetService.getPresetForHost(id);
      expect(stored, isNotNull);
      expect(stored!.tool, AgentLaunchTool.claudeCode);
      expect(stored.tmuxSessionName, 'code');
    });

    test(
      'does not write preset when action is LeaveAgentPresetUnchanged',
      () async {
        final id = await command.execute(
          input: _minimalInput(),
          // default is LeaveAgentPresetUnchanged
        );

        final stored = await presetService.getPresetForHost(id);
        expect(stored, isNull);
      },
    );

    test(
      'deletes previously-stored preset when action is DeleteAgentPreset',
      () async {
        // Pre-seed a preset directly.
        const preset = AgentLaunchPreset(tool: AgentLaunchTool.codex);
        final id = await command.execute(
          input: _minimalInput(),
          presetAction: const SaveAgentPreset(preset),
        );
        expect(await presetService.getPresetForHost(id), isNotNull);

        // Run the command again with DeleteAgentPreset.
        await command.execute(
          input: _minimalInput(),
          existingHostId: id,
          existingHost: await hostRepo.getById(id),
          presetAction: const DeleteAgentPreset(),
        );

        expect(await presetService.getPresetForHost(id), isNull);
      },
    );

    test('stores CLI preferences when provided', () async {
      final id = await command.execute(
        input: _minimalInput(),
        cliPreferences: const HostCliLaunchPreferences(startInYoloMode: true),
      );

      final stored = await cliPrefsService.getPreferencesForHost(id);
      expect(stored.startInYoloMode, isTrue);
    });

    test('leaves CLI preferences untouched when null', () async {
      // Insert host without CLI prefs first.
      final id = await command.execute(input: _minimalInput());

      // Manually set a CLI preference that the second execute should not touch.
      await cliPrefsService.setPreferencesForHost(
        id,
        const HostCliLaunchPreferences(startInYoloMode: true),
      );

      // Re-run with cliPreferences == null.
      await command.execute(
        input: _minimalInput(),
        existingHostId: id,
        existingHost: await hostRepo.getById(id),
      );

      final stored = await cliPrefsService.getPreferencesForHost(id);
      expect(stored.startInYoloMode, isTrue);
    });
  });

  group('SaveHostCommand – update', () {
    test('modifies an existing host', () async {
      final id = await command.execute(input: _minimalInput());
      final existingHost = await hostRepo.getById(id);

      await command.execute(
        input: _minimalInput(
          label: 'Renamed Host',
          hostname: 'new.example.com',
        ),
        existingHostId: id,
        existingHost: existingHost,
      );

      final updated = await hostRepo.getById(id);
      expect(updated!.label, 'Renamed Host');
      expect(updated.hostname, 'new.example.com');
    });

    test('does not create a second host when updating', () async {
      final id = await command.execute(input: _minimalInput());
      final existingHost = await hostRepo.getById(id);

      await command.execute(
        input: _minimalInput(label: 'Updated'),
        existingHostId: id,
        existingHost: existingHost,
      );

      expect(await hostRepo.getAll(), hasLength(1));
    });
  });

  group('SaveHostCommand – transaction rollback', () {
    test(
      'rolls back host insert when preset write fails inside the transaction',
      () async {
        final throwingCommand = SaveHostCommand(
          db: db,
          hostRepository: hostRepo,
          presetService: _ThrowingPresetService(settingsService),
          cliPreferencesService: cliPrefsService,
        );

        const preset = AgentLaunchPreset(tool: AgentLaunchTool.cursorAgent);
        await expectLater(
          throwingCommand.execute(
            input: _minimalInput(),
            presetAction: const SaveAgentPreset(preset),
          ),
          throwsException,
        );

        // The host insert was rolled back — DB must still be empty.
        expect(await hostRepo.getAll(), isEmpty);
      },
    );

    test('does not persist CLI preferences when preset write fails', () async {
      final throwingCommand = SaveHostCommand(
        db: db,
        hostRepository: hostRepo,
        presetService: _ThrowingPresetService(settingsService),
        cliPreferencesService: cliPrefsService,
      );

      const preset = AgentLaunchPreset(tool: AgentLaunchTool.claudeCode);
      await expectLater(
        throwingCommand.execute(
          input: _minimalInput(),
          presetAction: const SaveAgentPreset(preset),
          cliPreferences: const HostCliLaunchPreferences(startInYoloMode: true),
        ),
        throwsException,
      );

      // No host was created, so there is no host-id to look up. Confirm the
      // settings table also remains empty (i.e. the CLI prefs that come after
      // the throwing preset step were never written because the exception
      // short-circuited execution and the whole transaction rolled back).
      expect(await hostRepo.getAll(), isEmpty);

      // Insert a host manually and verify no orphaned CLI prefs exist.
      final manualId = await hostRepo.insert(
        HostsCompanion.insert(
          label: 'Manual',
          hostname: 'h.test',
          username: 'u',
        ),
      );
      final prefs = await cliPrefsService.getPreferencesForHost(manualId);
      expect(prefs.startInYoloMode, isFalse);
    });
  });
}
