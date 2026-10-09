/// Saves a previewed `ssh_config` import as hosts and port forwards.
library;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import 'diagnostics_log_service.dart';
import 'ssh_config_import_planner.dart';
import 'ssh_config_parser.dart';
import 'telemetry_service.dart';

/// Telemetry creation method for hosts imported from an OpenSSH config.
const sshConfigHostCreationMethod = 'ssh_config';

const _maxColumnLength = 255;

/// Why an entry cannot be imported yet, or null when it can.
String? sshConfigEntryBlockReason(
  SshConfigImportPlan plan,
  SshConfigImportEntry entry, {
  required String defaultUsername,
}) {
  final checked = <String>{};
  SshConfigImportEntry? current = entry;
  while (current != null && checked.add(current.id)) {
    final isSelf = identical(current, entry);
    final subject = isSelf ? 'This host' : 'Jump host ${current.label}';
    final hostname = current.hostname;
    if (hostname.isEmpty ||
        hostname.length > _maxColumnLength ||
        hostname.contains(RegExp(r'\s'))) {
      return '$subject has an invalid HostName.';
    }
    final username = current.username ?? defaultUsername.trim();
    if (username.isEmpty) {
      return '$subject has no User. Enter a default username above.';
    }
    if (username.length > _maxColumnLength) {
      return '$subject has a User longer than 255 characters.';
    }
    final jumpId = current.jumpEntryId;
    current = jumpId == null ? null : plan.entryById(jumpId);
  }
  return null;
}

/// Entries that would be saved for [selectedIds]: the selection plus every
/// jump host a selected entry connects through.
Set<String> sshConfigImportClosure(
  SshConfigImportPlan plan,
  Set<String> selectedIds,
) {
  final closure = <String>{};
  for (final id in selectedIds) {
    final entry = plan.entryById(id);
    if (entry == null || !closure.add(id)) continue;
    for (final hop in plan.jumpChain(entry)) {
      closure.add(hop.id);
    }
  }
  return closure;
}

/// Thrown when a selected entry cannot be imported yet.
class SshConfigImportBlockedException implements Exception {
  /// Creates the exception with the user-facing [reason].
  const SshConfigImportBlockedException(this.reason);

  /// Why the entry is blocked.
  final String reason;

  @override
  String toString() => reason;
}

/// Result of saving an import.
class SshConfigImportResult {
  /// Creates a result.
  const SshConfigImportResult({
    required this.createdHostIds,
    required this.reusedHostCount,
    required this.forwardCount,
  });

  /// IDs of hosts created, keyed by entry ID.
  final Map<String, int> createdHostIds;

  /// Entries that matched a host already saved, so nothing new was created.
  final int reusedHostCount;

  /// Port forwards created.
  final int forwardCount;
}

/// Persists `ssh_config` import plans.
class SshConfigImportService {
  /// Creates the service.
  SshConfigImportService({
    required AppDatabase db,
    required HostRepository hostRepository,
    required PortForwardRepository portForwardRepository,
    TelemetryService? telemetry,
    DiagnosticsLogger? diagnostics,
  }) : _db = db,
       _hostRepository = hostRepository,
       _portForwardRepository = portForwardRepository,
       _telemetry = telemetry,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final AppDatabase _db;
  final HostRepository _hostRepository;
  final PortForwardRepository _portForwardRepository;
  final TelemetryService? _telemetry;
  final DiagnosticsLogger _diagnostics;

  /// Saves [selectedIds] (and the jump hosts they need) from [plan].
  ///
  /// An entry that matches a saved host (same hostname, port, user, and jump
  /// host) reuses it instead of creating a duplicate. Everything is written in
  /// one transaction. Throws [SshConfigImportBlockedException] when a
  /// selected entry (or a jump host it needs) is blocked.
  Future<SshConfigImportResult> importEntries(
    SshConfigImportPlan plan, {
    required Set<String> selectedIds,
    required String defaultUsername,
  }) async {
    final closure = sshConfigImportClosure(plan, selectedIds);
    for (final id in closure) {
      final reason = sshConfigEntryBlockReason(
        plan,
        plan.entryById(id)!,
        defaultUsername: defaultUsername,
      );
      if (reason != null) throw SshConfigImportBlockedException(reason);
    }

    final created = <String, int>{};
    var reused = 0;
    var forwardCount = 0;
    await _db.transaction(() async {
      final existingHosts = await _hostRepository.getAll();
      final resolved = <String, int>{};

      Future<int> save(SshConfigImportEntry entry) async {
        final known = resolved[entry.id];
        if (known != null) return known;
        final jumpId = entry.jumpEntryId == null
            ? null
            : await save(plan.entryById(entry.jumpEntryId!)!);
        final username = entry.username ?? defaultUsername.trim();
        final match = existingHosts.where(
          (host) =>
              host.hostname.toLowerCase() == entry.hostname.toLowerCase() &&
              host.port == entry.port &&
              host.username == username &&
              host.jumpHostId == jumpId,
        );
        if (match.isNotEmpty) {
          reused++;
          return resolved[entry.id] = match.first.id;
        }
        final hostId = await _hostRepository.insert(
          HostsCompanion.insert(
            label: _truncate(entry.label),
            hostname: entry.hostname,
            port: Value(entry.port),
            username: username,
            jumpHostId: Value(jumpId),
            notes: Value(_notesFor(entry)),
          ),
        );
        created[entry.id] = hostId;
        for (final forward in entry.forwards) {
          await _portForwardRepository.insert(
            _forwardCompanion(hostId, forward),
          );
          forwardCount++;
        }
        return resolved[entry.id] = hostId;
      }

      for (final entry in plan.entries) {
        if (closure.contains(entry.id)) await save(entry);
      }
    });

    _diagnostics.info(
      'hosts.import',
      'ssh_config_imported',
      fields: {
        'createdCount': created.length,
        'reusedCount': reused,
        'forwardCount': forwardCount,
        'skippedDirectiveCount': plan.skipped.length,
      },
    );
    final telemetry = _telemetry;
    if (telemetry != null) {
      for (final entry in plan.entries) {
        if (!created.containsKey(entry.id)) continue;
        await telemetry.logHostCreated(
          method: sshConfigHostCreationMethod,
          hasKey: false,
          hasJumpHost: entry.jumpEntryId != null,
          hasAutoConnect: false,
          hasAgentPreset: false,
        );
      }
    }
    return SshConfigImportResult(
      createdHostIds: Map.unmodifiable(created),
      reusedHostCount: reused,
      forwardCount: forwardCount,
    );
  }

  static String _truncate(String value) => value.length <= _maxColumnLength
      ? value
      : value.substring(0, _maxColumnLength);

  static String? _notesFor(SshConfigImportEntry entry) {
    if (!entry.keyNeeded) return null;
    return 'Imported from ssh_config. Key needed: '
        '${entry.identityFiles.join(', ')}';
  }

  static PortForwardsCompanion _forwardCompanion(
    int hostId,
    SshConfigForward forward,
  ) {
    final bindHost = sshConfigForwardBindHost(forward);
    final autoStart = !sshConfigForwardIsExposed(forward);
    return switch (forward.type) {
      SshConfigForwardType.local => PortForwardsCompanion.insert(
        name: _truncate(
          'Local ${forward.bindPort} → '
          '${forward.targetHost}:${forward.targetPort}',
        ),
        hostId: hostId,
        forwardType: 'local',
        localHost: Value(bindHost),
        localPort: forward.bindPort,
        remoteHost: forward.targetHost,
        remotePort: forward.targetPort,
        autoStart: Value(autoStart),
      ),
      SshConfigForwardType.remote => PortForwardsCompanion.insert(
        name: _truncate(
          'Remote ${forward.bindPort} → '
          '${forward.targetHost}:${forward.targetPort}',
        ),
        hostId: hostId,
        forwardType: 'remote',
        localHost: Value(forward.targetHost),
        localPort: forward.targetPort,
        remoteHost: bindHost,
        remotePort: forward.bindPort,
        autoStart: Value(autoStart),
      ),
    };
  }
}

/// Provider for [SshConfigImportService].
final sshConfigImportServiceProvider = Provider<SshConfigImportService>(
  (ref) => SshConfigImportService(
    db: ref.watch(databaseProvider),
    hostRepository: ref.watch(hostRepositoryProvider),
    portForwardRepository: ref.watch(portForwardRepositoryProvider),
    telemetry: ref.watch(telemetryServiceProvider),
  ),
);
