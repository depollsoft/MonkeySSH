import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';

void registerTerminalAutoConnectTests() {
  group('stored auto-connect command', () {
    for (final preset in ['none', 'unsupported', 'saved']) {
      test('auto-connect command with $preset preset', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final settingsService = SettingsService(db);
        final saved = preset == 'saved';
        final command = saved ? 'codex --approval-mode never' : 'gemini --yolo';
        const legacy = {'tool': 'geminiCli', 'workingDirectory': '~/legacy'};
        final host = Host(
          id: 1,
          label: 'Terminal test host',
          hostname: 'terminal.example.com',
          port: 22,
          username: 'root',
          autoConnectCommand: command,
          isFavorite: false,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          autoConnectRequiresConfirmation: false,
          autoForwardPorts: false,
          sortOrder: 0,
        );
        if (preset == 'unsupported') {
          await settingsService.setJson(SettingKeys.agentLaunchPresets, {
            '${host.id}': legacy,
          });
        } else if (saved) {
          await AgentLaunchPresetService(settingsService).setPresetForHost(
            host.id,
            const AgentLaunchPreset(tool: AgentLaunchTool.codex),
          );
          await HostCliLaunchPreferencesService(settingsService)
              .setPreferencesForHost(
                host.id,
                const HostCliLaunchPreferences(startInYoloMode: true),
              );
        }
        final state = await AgentLaunchPresetService(settingsService)
            .getPresetStateForHost(host.id);
        final preferences = await HostCliLaunchPreferencesService(
          settingsService,
        ).getPreferencesForHost(host.id);
        String? resolve() => resolveStoredAutoConnectCommand(
          host,
          hasUnsupportedAutoConnectAgentPreset: state.isUnsupported,
          autoConnectAgentPreset: state.preset,
          startClisInYoloMode: preferences.startInYoloMode,
        );
        expect(resolve, returnsNormally);
        final written = resolve() ?? '';
        if (saved) {
          expect(written, contains('codex --yolo'));
          expect(written, isNot(contains('--approval-mode never')));
        } else {
          expect(
            written,
            preset == 'unsupported'
                ? isNot(contains(command))
                : contains(command),
          );
          if (preset == 'unsupported') {
            expect(
              await settingsService.getJson(SettingKeys.agentLaunchPresets),
              containsPair('${host.id}', legacy),
            );
          }
        }
      });
    }
  });
}
