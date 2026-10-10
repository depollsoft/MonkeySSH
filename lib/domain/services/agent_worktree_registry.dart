import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_worktree.dart';
import 'settings_service.dart';

/// Most records kept per host; the oldest are forgotten first. Forgetting a
/// record only stops the app offering to remove that worktree.
const _maxRecordsPerHost = 100;

/// Remembers the worktrees MonkeySSH created for agent launches.
///
/// The app only offers to remove worktrees it created itself, so it looks
/// closing windows up here. Records live in app settings; they hold paths and
/// branch names, which are user content and are never logged.
class AgentWorktreeRegistry {
  /// Creates a registry backed by [_settings].
  AgentWorktreeRegistry(this._settings);

  final SettingsService _settings;

  /// Records created on [hostId], newest first.
  Future<List<AgentWorktreeRecord>> recordsForHost(int hostId) async {
    final stored = await _settings.getJson(SettingKeys.agentWorktrees);
    return _decode(stored?[hostId.toString()], hostId);
  }

  /// The created worktree that contains [directory] on [hostId], if any.
  ///
  /// Pending records are skipped: git may not have finished creating them,
  /// and a later launch cleans them up.
  Future<AgentWorktreeRecord?> findContaining(
    int hostId,
    String? directory,
  ) async {
    for (final record in await recordsForHost(hostId)) {
      if (!record.pending && record.contains(directory)) {
        return record;
      }
    }
    return null;
  }

  /// Adds [record], replacing any record for the same worktree.
  Future<void> add(AgentWorktreeRecord record) =>
      _settings.updateJson(SettingKeys.agentWorktrees, (current) {
        final key = record.hostId.toString();
        final records = [
          record,
          ..._decode(
            current?[key],
            record.hostId,
          ).where((existing) => existing.path != record.path),
        ].take(_maxRecordsPerHost);
        return (current ?? <String, dynamic>{})
          ..[key] = [for (final entry in records) entry.toJson()];
      });

  /// Forgets [record].
  Future<void> remove(AgentWorktreeRecord record) =>
      _settings.updateJson(SettingKeys.agentWorktrees, (current) {
        if (current == null) {
          return null;
        }
        final key = record.hostId.toString();
        final remaining = _decode(
          current[key],
          record.hostId,
        ).where((existing) => existing != record).toList(growable: false);
        if (remaining.isEmpty) {
          current.remove(key);
        } else {
          current[key] = [for (final entry in remaining) entry.toJson()];
        }
        return current.isEmpty ? null : current;
      });

  static List<AgentWorktreeRecord> _decode(Object? value, int hostId) =>
      value is List
      ? value
            .map(
              (entry) => AgentWorktreeRecord.tryFromJson(entry, hostId: hostId),
            )
            .whereType<AgentWorktreeRecord>()
            .toList(growable: false)
      : const [];
}

/// Provider for [AgentWorktreeRegistry].
final agentWorktreeRegistryProvider = Provider<AgentWorktreeRegistry>(
  (ref) => AgentWorktreeRegistry(ref.watch(settingsServiceProvider)),
);
