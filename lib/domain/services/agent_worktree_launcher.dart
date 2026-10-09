/// Coordinates the git worktree for one agent preset launch.
///
/// A launch creates the worktree, starts the agent in it, and then either
/// keeps the worktree (the agent is running there) or rolls it back (the
/// launch failed), so a failed launch never leaves an orphan worktree behind.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/agent_worktree.dart';
import 'agent_worktree_registry.dart';
import 'agent_worktree_service.dart';
import 'diagnostics_log_service.dart';

/// Default schedule for checking that a launched agent's window runs in its
/// worktree. The waits add up to about a minute, enough for a MonkeyMux
/// server to start and open its first window on a slow host.
const agentWorktreeLaunchCheckSchedule = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
  Duration(seconds: 13),
  Duration(seconds: 21),
];

/// How a launch's worktree was settled.
enum AgentWorktreeLaunchOutcome {
  /// A window runs in the worktree, so it stays.
  confirmed,

  /// The launch failed and the worktree and its branch were removed.
  rolledBack,

  /// The launch failed but the worktree could not be removed (for example it
  /// already had changes, or the connection dropped), so it stays recorded.
  kept,
}

/// Creates worktrees for launches and undoes them when a launch fails.
class AgentWorktreeLauncher {
  /// Creates a launcher.
  AgentWorktreeLauncher({
    required AgentWorktreeService service,
    required AgentWorktreeRegistry registry,
    DateTime Function()? clock,
    Random? random,
    Future<void> Function(Duration delay)? wait,
  }) : _service = service,
       _registry = registry,
       _clock = clock ?? DateTime.now,
       _random = random,
       _wait = wait ?? Future<void>.delayed;

  final AgentWorktreeService _service;
  final AgentWorktreeRegistry _registry;
  final DateTime Function() _clock;
  final Random? _random;
  final Future<void> Function(Duration delay) _wait;

  /// Creates the worktree a launch of [preset] on [hostId] starts in and
  /// records it.
  ///
  /// Throws an [AgentWorktreeException] when the options are invalid, the
  /// host cannot run the scripts, or git refuses.
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required AgentLaunchPreset preset,
    required bool windowsHost,
  }) async {
    final options = preset.worktree;
    if (options == null) {
      throw ArgumentError.value(preset, 'preset', 'has no worktree options');
    }
    try {
      if (windowsHost) {
        throw const AgentWorktreeException(
          AgentWorktreeErrorKind.unsupportedHost,
        );
      }
      final invalid = options.validate(
        workingDirectory: preset.workingDirectory,
      );
      if (invalid != null) {
        throw AgentWorktreeException(
          AgentWorktreeErrorKind.invalidOptions,
          detail: invalid,
        );
      }
      final now = _clock();
      final target = renderAgentWorktreeTarget(
        options,
        AgentWorktreeTemplateValues.forLaunch(
          tool: preset.tool.commandName,
          now: now,
          random: _random,
        ),
      );
      final record = await _service.create(
        shell,
        hostId: hostId,
        repository: options.resolveRepositoryPath(preset.workingDirectory)!,
        baseRef: options.effectiveBaseRef,
        target: target,
        now: now,
      );
      await _registry.add(record);
      DiagnosticsLogService.instance.info(
        'agent.worktree',
        'created',
        fields: {
          'hostId': hostId,
          'tool': preset.tool.name,
          'startsInSubdirectory': record.startDirectory != record.path,
        },
      );
      return record;
    } on AgentWorktreeException catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'create_failed',
        fields: {'hostId': hostId, 'errorKind': error.kind.name},
      );
      rethrow;
    }
  }

  /// Removes [record]'s worktree after its launch failed.
  ///
  /// Never throws. A worktree that already has changes is kept, and the
  /// branch is deleted only if it has no new commits.
  Future<AgentWorktreeLaunchOutcome> rollBack(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    try {
      final removal = await _service.remove(shell, record);
      await _registry.remove(record);
      DiagnosticsLogService.instance.info(
        'agent.worktree',
        'rolled_back',
        fields: {
          'hostId': record.hostId,
          'branchDeleted': removal.branchDeleted,
        },
      );
      return AgentWorktreeLaunchOutcome.rolledBack;
    } on AgentWorktreeException catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'rollback_failed',
        fields: {'hostId': record.hostId, 'errorKind': error.kind.name},
      );
      return AgentWorktreeLaunchOutcome.kept;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'rollback_failed',
        fields: {'hostId': record.hostId, 'errorType': error.runtimeType},
      );
      return AgentWorktreeLaunchOutcome.kept;
    }
  }

  /// Waits for a window to run in [record]'s worktree, and rolls the worktree
  /// back if none does.
  ///
  /// [windowDirectories] lists the current directory of each window in the
  /// session the agent was launched into. This covers launches that never
  /// reached the host, such as a connection dropped before the attach ran or
  /// an attach that joined an already-running session instead of starting
  /// the agent.
  Future<AgentWorktreeLaunchOutcome> confirm(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record, {
    required Future<Iterable<String?>> Function() windowDirectories,
    List<Duration> schedule = agentWorktreeLaunchCheckSchedule,
  }) async {
    for (final delay in schedule) {
      await _wait(delay);
      try {
        final directories = await windowDirectories();
        if (directories.any(record.contains)) {
          DiagnosticsLogService.instance.info(
            'agent.worktree',
            'launch_confirmed',
            fields: {'hostId': record.hostId},
          );
          return AgentWorktreeLaunchOutcome.confirmed;
        }
      } on Object catch (error) {
        DiagnosticsLogService.instance.debug(
          'agent.worktree',
          'launch_check_failed',
          fields: {'hostId': record.hostId, 'errorType': error.runtimeType},
        );
      }
    }
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'launch_not_observed',
      fields: {'hostId': record.hostId},
    );
    return rollBack(shell, record);
  }
}

/// Provider for [AgentWorktreeLauncher].
final agentWorktreeLauncherProvider = Provider<AgentWorktreeLauncher>(
  (ref) => AgentWorktreeLauncher(
    service: ref.watch(agentWorktreeServiceProvider),
    registry: ref.watch(agentWorktreeRegistryProvider),
  ),
);
