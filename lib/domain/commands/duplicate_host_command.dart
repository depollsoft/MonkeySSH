import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../services/agent_launch_preset_service.dart';
import '../services/host_cli_launch_preferences_service.dart';

/// Duplicates a host and its host-scoped startup settings.
class DuplicateHostCommand {
  /// Creates a [DuplicateHostCommand].
  DuplicateHostCommand({
    required AppDatabase db,
    required HostRepository hostRepository,
    required AgentLaunchPresetService presetService,
    required HostCliLaunchPreferencesService cliPreferencesService,
  }) : _db = db,
       _hostRepository = hostRepository,
       _presetService = presetService,
       _cliPreferencesService = cliPreferencesService;

  final AppDatabase _db;
  final HostRepository _hostRepository;
  final AgentLaunchPresetService _presetService;
  final HostCliLaunchPreferencesService _cliPreferencesService;

  /// Duplicates [host], including its coding-agent preset and CLI preferences.
  Future<int> execute(Host host) => _db.transaction(() async {
    final preset = await _presetService.getPresetForHost(host.id);
    final cliPreferences = await _cliPreferencesService.getPreferencesForHost(
      host.id,
    );
    final duplicateHostId = await _hostRepository.duplicate(host);

    if (preset != null) {
      await _presetService.setPresetForHost(duplicateHostId, preset);
    }
    if (!cliPreferences.isEmpty) {
      await _cliPreferencesService.setPreferencesForHost(
        duplicateHostId,
        cliPreferences,
      );
    }

    return duplicateHostId;
  });
}

/// Provider for [DuplicateHostCommand].
final duplicateHostCommandProvider = Provider<DuplicateHostCommand>(
  (ref) => DuplicateHostCommand(
    db: ref.watch(databaseProvider),
    hostRepository: ref.watch(hostRepositoryProvider),
    presetService: ref.watch(agentLaunchPresetServiceProvider),
    cliPreferencesService: ref.watch(hostCliLaunchPreferencesServiceProvider),
  ),
);
