// ignore_for_file: public_member_api_docs

import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';

/// Records worktree requests instead of running git on a host.
class FakeAgentWorktreeService extends AgentWorktreeService {
  FakeAgentWorktreeService({
    this.path = '/srv/app.worktrees/agent',
    this.startDirectory,
    this.planError,
    this.addError,
    this.removeError,
    this.statusResult = const AgentWorktreeStatus(
      exists: true,
      changedFiles: 0,
      ignoredEntries: 0,
      branchHasNewCommits: false,
    ),
  });

  /// Folder every planned worktree uses.
  final String path;

  /// Directory the agent starts in, when not the worktree root.
  final String? startDirectory;

  /// Thrown by [plan] when set.
  AgentWorktreeException? planError;

  /// Thrown by [add] when set.
  AgentWorktreeException? addError;

  /// Thrown by [remove] when set.
  AgentWorktreeException? removeError;

  /// Returned by [status].
  AgentWorktreeStatus statusResult;

  /// Answers [tmuxSessionDirectories]: the pane directories, or null for no
  /// session. Each call takes the next answer, repeating the last one.
  List<List<String>?> tmuxAnswers = [null];

  /// Session names [tmuxSessionDirectories] was asked about.
  final tmuxProbes = <String>[];

  final targets = <AgentWorktreeTarget>[];
  final created = <AgentWorktreeRecord>[];
  final removed = <AgentWorktreeRecord>[];

  @override
  Future<AgentWorktreePlan> plan(
    AgentWorktreeShell shell, {
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
  }) async {
    if (planError case final error?) throw error;
    targets.add(target);
    return AgentWorktreePlan(
      branch: target.branch,
      path: path,
      baseCommit: 'abc',
      repository: '/srv/app',
      subdirectory: '',
    );
  }

  @override
  Future<AgentWorktreeRecord> add(
    AgentWorktreeShell shell, {
    required int hostId,
    required AgentWorktreePlan plan,
    DateTime? now,
  }) async {
    if (addError case final error?) throw error;
    final record = AgentWorktreeRecord(
      hostId: hostId,
      repository: plan.repository,
      path: plan.path,
      branch: plan.branch,
      baseCommit: plan.baseCommit,
      startDirectory: startDirectory,
      createdAt: (now ?? DateTime.utc(2026)).toUtc(),
    );
    created.add(record);
    return record;
  }

  @override
  Future<List<String>?> tmuxSessionDirectories(
    AgentWorktreeShell shell,
    String name,
  ) async {
    tmuxProbes.add(name);
    return tmuxAnswers.length > 1 ? tmuxAnswers.removeAt(0) : tmuxAnswers.first;
  }

  @override
  Future<AgentWorktreeStatus> status(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async => statusResult;

  @override
  Future<AgentWorktreeRemoval> remove(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    if (removeError case final error?) throw error;
    removed.add(record);
    return const AgentWorktreeRemoval(branchDeleted: true);
  }
}

/// Keeps worktree records in memory.
class MemoryAgentWorktreeRegistry implements AgentWorktreeRegistry {
  final records = <AgentWorktreeRecord>[];

  /// Makes [add] throw for the records it returns true for.
  bool Function(AgentWorktreeRecord record)? failAdd;

  @override
  Future<void> add(AgentWorktreeRecord record) async {
    if (failAdd?.call(record) ?? false) {
      throw StateError('settings write failed');
    }
    records
      ..removeWhere((existing) => existing.path == record.path)
      ..insert(0, record);
  }

  @override
  Future<void> remove(AgentWorktreeRecord record) async =>
      records.remove(record);

  @override
  Future<AgentWorktreeRecord?> findContaining(
    int hostId,
    String? directory,
  ) async => records
      .where(
        (record) =>
            record.hostId == hostId &&
            !record.pending &&
            record.contains(directory),
      )
      .firstOrNull;

  @override
  Future<List<AgentWorktreeRecord>> recordsForHost(int hostId) async =>
      records.where((record) => record.hostId == hostId).toList();
}
