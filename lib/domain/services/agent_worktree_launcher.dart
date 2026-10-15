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

/// The worktree created for one launch, settled exactly once.
///
/// Holding the launcher and shell lets a screen settle the worktree after it
/// has been disposed.
final class AgentWorktreeLaunch {
  AgentWorktreeLaunch._(this.record, this._launcher, this._shell);

  /// The created worktree.
  final AgentWorktreeRecord record;

  final AgentWorktreeLauncher _launcher;
  final AgentWorktreeShell _shell;
  var _settled = false;

  /// Whether [abandon] or [launched] has already run.
  bool get isSettled => _settled;

  /// Rolls the worktree back because the launch never started the agent.
  void abandon() {
    if (_settled) return;
    _settled = true;
    unawaited(_launcher.rollBack(_shell, record));
  }

  /// Records that the launch reached the host.
  ///
  /// When [windowDirectories] can list the session's windows, the worktree is
  /// rolled back if no window ever runs in it, which covers an attach that
  /// joined a running session or a session that failed to start.
  void launched({Future<Iterable<String?>> Function()? windowDirectories}) {
    if (_settled) return;
    _settled = true;
    if (windowDirectories != null) {
      unawaited(
        _launcher.confirm(_shell, record, windowDirectories: windowDirectories),
      );
    }
  }
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
  /// The worktree is recorded as pending before git creates it, so a create
  /// that times out (git keeps running on the host) is still known and gets
  /// cleaned up by a later launch on the same host. [tool] overrides the
  /// preset's agent in the branch name, for a native session started with
  /// another provider.
  ///
  /// Throws an [AgentWorktreeException] when the options are invalid, the
  /// host cannot run the scripts, or git refuses.
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required AgentLaunchPreset preset,
    required bool windowsHost,
    AgentLaunchTool? tool,
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
      await _sweepPending(shell, hostId);
      final now = _clock();
      final launchTool = tool ?? preset.tool;
      final plan = await _service.plan(
        shell,
        repository: options.resolveRepositoryPath(preset.workingDirectory)!,
        baseRef: options.effectiveBaseRef,
        target: renderAgentWorktreeTarget(
          options,
          AgentWorktreeTemplateValues.forLaunch(
            tool: launchTool.commandName,
            now: now,
            random: _random,
          ),
        ),
      );
      final launchId = _newLaunchId();
      final pending = plan.pendingRecord(
        hostId: hostId,
        createdAt: now,
        launchId: launchId,
      );
      try {
        await _registry.add(pending);
      } on Object catch (error) {
        _logPersistenceFailure(hostId, error);
        throw const AgentWorktreeException(AgentWorktreeErrorKind.unavailable);
      }
      final AgentWorktreeRecord record;
      try {
        record = await _service.add(
          shell,
          hostId: hostId,
          plan: plan,
          launchId: launchId,
          now: now,
        );
      } on AgentWorktreeException catch (error) {
        // Without an answer git may still be creating the worktree, so the
        // pending record stays for a later launch to clean up. Any other
        // failure means git created nothing.
        if (error.kind != AgentWorktreeErrorKind.unavailable) {
          await _forget(pending);
        }
        rethrow;
      }
      try {
        await _registry.remove(pending);
        await _registry.add(record);
      } on Object catch (error) {
        _logPersistenceFailure(hostId, error);
        await rollBack(shell, record);
        throw const AgentWorktreeException(AgentWorktreeErrorKind.unavailable);
      }
      DiagnosticsLogService.instance.info(
        'agent.worktree',
        'created',
        fields: {
          'hostId': hostId,
          'tool': launchTool.name,
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

  /// Creates the worktree for a launch of [preset], returning a handle the
  /// caller settles once it knows whether the launch started the agent.
  Future<AgentWorktreeLaunch> begin(
    AgentWorktreeShell shell, {
    required int hostId,
    required AgentLaunchPreset preset,
    required bool windowsHost,
    AgentLaunchTool? tool,
  }) async => AgentWorktreeLaunch._(
    await create(
      shell,
      hostId: hostId,
      preset: preset,
      windowsHost: windowsHost,
      tool: tool,
    ),
    this,
    shell,
  );

  /// Removes [record]'s worktree after its launch failed.
  ///
  /// Never throws. A worktree that holds work removal would lose is kept, a
  /// folder that is no longer the recorded worktree is left alone and its
  /// record forgotten, and the branch is deleted only if it has no new
  /// commits.
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
      if (error.kind == AgentWorktreeErrorKind.stale) {
        await _forget(record);
      }
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
  /// back once the session shows it does not.
  ///
  /// [windowDirectories] lists the current directory of each window in the
  /// session the agent was launched into, returning an empty list when the
  /// session is gone and throwing when the answer is unknown. This covers an
  /// attach that joined an already-running session, a session that never
  /// started, and an agent window that closed at once. The worktree is rolled
  /// back only after a listing succeeded without it; when every listing
  /// failed it is kept, because removing a clean worktree under a running
  /// agent would lose the agent's next edits.
  Future<AgentWorktreeLaunchOutcome> confirm(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record, {
    required Future<Iterable<String?>> Function() windowDirectories,
    List<Duration> schedule = agentWorktreeLaunchCheckSchedule,
  }) async {
    var observed = false;
    for (final delay in schedule) {
      await _wait(delay);
      try {
        final directories = await windowDirectories();
        observed = true;
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
    if (!observed) {
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'launch_unknown',
        fields: {'hostId': record.hostId},
      );
      return AgentWorktreeLaunchOutcome.kept;
    }
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'launch_not_observed',
      fields: {'hostId': record.hostId},
    );
    return rollBack(shell, record);
  }

  /// Cleans up worktrees whose create never reported back.
  ///
  /// Only records older than [_pendingSweepAge] are touched, so a create
  /// still running from another screen is left alone.
  Future<void> _sweepPending(AgentWorktreeShell shell, int hostId) async {
    final List<AgentWorktreeRecord> records;
    try {
      records = await _registry.recordsForHost(hostId);
    } on Object catch (error) {
      _logPersistenceFailure(hostId, error);
      return;
    }
    final cutoff = _clock().toUtc().subtract(_pendingSweepAge);
    for (final record in records) {
      if (record.pending && record.createdAt.isBefore(cutoff)) {
        await rollBack(shell, record);
      }
    }
  }

  String _newLaunchId() {
    final random = _random ?? Random.secure();
    return [
      for (var i = 0; i < 4; i++)
        random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
    ].join();
  }

  Future<void> _forget(AgentWorktreeRecord record) async {
    try {
      await _registry.remove(record);
    } on Object catch (error) {
      _logPersistenceFailure(record.hostId, error);
    }
  }

  void _logPersistenceFailure(int hostId, Object error) {
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'record_failed',
      fields: {'hostId': hostId, 'errorType': error.runtimeType},
    );
  }
}

/// How old a pending record must be before a launch cleans it up; well past
/// the create timeout, so git has finished by then.
const _pendingSweepAge = Duration(minutes: 10);

/// Provider for [AgentWorktreeLauncher].
final agentWorktreeLauncherProvider = Provider<AgentWorktreeLauncher>(
  (ref) => AgentWorktreeLauncher(
    service: ref.watch(agentWorktreeServiceProvider),
    registry: ref.watch(agentWorktreeRegistryProvider),
  ),
);
