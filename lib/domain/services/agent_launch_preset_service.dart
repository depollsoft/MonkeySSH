import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import 'settings_service.dart';

/// Persists host-scoped coding-agent launch presets in app settings.
class AgentLaunchPresetService {
  /// Creates a new [AgentLaunchPresetService].
  AgentLaunchPresetService(this._settings);

  final SettingsService _settings;

  /// Loads the saved preset for [hostId], if one exists.
  ///
  /// Returns `null` when the stored payload is missing or references an
  /// unknown agent tool, so stale presets never silently become another CLI.
  Future<AgentLaunchPreset?> getPresetForHost(int hostId) async =>
      (await getPresetStateForHost(hostId)).preset;

  /// Loads a preset while distinguishing missing from unsupported saved data.
  ///
  /// Callers must not fall back to cached generated commands for an unsupported
  /// preset. Reading this state leaves the stored payload unchanged.
  Future<({AgentLaunchPreset? preset, bool isUnsupported})>
  getPresetStateForHost(int hostId) async {
    final presets =
        await _settings.getJson(SettingKeys.agentLaunchPresets) ?? {};
    final key = hostId.toString();
    final value = presets[key];
    final preset = value is Map<String, dynamic>
        ? AgentLaunchPreset.tryFromJson(value)
        : null;
    return (
      preset: preset,
      isUnsupported: presets.containsKey(key) && preset == null,
    );
  }

  /// Saves [preset] for [hostId].
  Future<void> setPresetForHost(int hostId, AgentLaunchPreset preset) =>
      _settings.updateJson(
        SettingKeys.agentLaunchPresets,
        (current) => (current ?? {})..[hostId.toString()] = preset.toJson(),
      );

  /// Removes any saved preset for [hostId].
  Future<void> deletePresetForHost(int hostId) =>
      _settings.updateJson(SettingKeys.agentLaunchPresets, (current) {
        final presets = (current ?? {})..remove(hostId.toString());
        return presets.isEmpty ? null : presets;
      });
}

/// Provider for [AgentLaunchPresetService].
final agentLaunchPresetServiceProvider = Provider<AgentLaunchPresetService>(
  (ref) => AgentLaunchPresetService(ref.watch(settingsServiceProvider)),
);
