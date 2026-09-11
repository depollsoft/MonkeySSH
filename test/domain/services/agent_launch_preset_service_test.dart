// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late AgentLaunchPresetService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = AgentLaunchPresetService(SettingsService(database));
  });

  tearDown(() async {
    await database.close();
  });

  test('stores and loads a host preset', () async {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.claudeCode,
      workingDirectory: '~/src/flutty',
      tmuxSessionName: 'claude',
      tmuxExtraFlags: '-x 160 -y 48',
      additionalArguments: '--resume',
    );

    await service.setPresetForHost(42, preset);
    final loaded = await service.getPresetForHost(42);

    expect(loaded, isNotNull);
    expect(loaded!.tool, preset.tool);
    expect(loaded.workingDirectory, preset.workingDirectory);
    expect(loaded.tmuxSessionName, preset.tmuxSessionName);
    expect(loaded.tmuxExtraFlags, preset.tmuxExtraFlags);
    expect(loaded.additionalArguments, preset.additionalArguments);
  });

  test('deletes a stored host preset', () async {
    const preset = AgentLaunchPreset(tool: AgentLaunchTool.codex);

    await service.setPresetForHost(7, preset);
    await service.deletePresetForHost(7);

    expect(await service.getPresetForHost(7), isNull);
    expect(
      await SettingsService(database).getJson(SettingKeys.agentLaunchPresets),
      isNull,
    );
  });

  for (final delete in [false, true]) {
    test(
      'concurrent preset mutations preserve other hosts (delete=$delete)',
      () async {
        final settings = SettingsService(database);
        final otherService = AgentLaunchPresetService(
          SettingsService(database),
        );
        const legacy = {'tool': 'unknownFutureAgent'};
        const preset = AgentLaunchPreset(tool: AgentLaunchTool.codex);
        await settings.setJson(SettingKeys.agentLaunchPresets, {
          '9': legacy,
          if (delete) '7': preset.toJson(),
        });
        await Future.wait([
          service.setPresetForHost(42, preset),
          if (delete)
            otherService.deletePresetForHost(7)
          else
            otherService.setPresetForHost(7, preset),
        ]);
        expect(await settings.getJson(SettingKeys.agentLaunchPresets), {
          '9': legacy,
          '42': preset.toJson(),
          if (!delete) '7': preset.toJson(),
        });
      },
    );
  }

  test(
    'ignores a retired Gemini preset without rewriting saved settings',
    () async {
      final settings = SettingsService(database);
      const legacy = {'tool': 'geminiCli', 'workingDirectory': '~/legacy'};
      await settings.setJson(SettingKeys.agentLaunchPresets, {'9': legacy});
      expect(await service.getPresetForHost(9), isNull);
      expect((await service.getPresetStateForHost(9)).isUnsupported, isTrue);
      expect((await service.getPresetStateForHost(11)).isUnsupported, isFalse);
      await service.setPresetForHost(
        10,
        const AgentLaunchPreset(tool: AgentLaunchTool.antigravity),
      );
      expect(
        (await settings.getJson(SettingKeys.agentLaunchPresets))!['9'],
        legacy,
      );
      expect(
        (await service.getPresetForHost(10))!.tool,
        AgentLaunchTool.antigravity,
      );
      expect((await service.getPresetStateForHost(10)).isUnsupported, isFalse);
      await service.deletePresetForHost(9);
      expect((await service.getPresetStateForHost(9)).isUnsupported, isFalse);
    },
  );

  test('returns null for stored presets with unknown tool names', () async {
    final settings = SettingsService(database);
    await settings.setJson(SettingKeys.agentLaunchPresets, {
      '9': {'tool': 'unknownFutureAgent'},
    });

    expect(await service.getPresetForHost(9), isNull);
  });
}
