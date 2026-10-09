/// Creates, inspects and removes git worktrees for agent launches over SSH.
///
/// Every command is a fixed POSIX script. User-provided paths, branch names
/// and refs only ever appear as single-quoted words (a leading `~` becomes a
/// quoted `"$HOME"`), so the remote shell never evaluates them, and `git`
/// re-validates each one (`git check-ref-format --branch`, `git rev-parse
/// --verify`) before anything is created. Nothing here logs those values.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_worktree.dart';
import 'diagnostics_log_service.dart';
import 'ssh_error_policy.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Output of one remote worktree command.
@immutable
final class AgentWorktreeExecResult {
  /// Creates a command result.
  const AgentWorktreeExecResult({required this.stdout, required this.exitCode});

  /// Standard output.
  final String stdout;

  /// Exit status, when the server reported one.
  final int? exitCode;
}

/// Runs worktree scripts on a host.
abstract interface class AgentWorktreeShell {
  /// Runs [script] and returns its output.
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  });
}

/// Runs worktree scripts on an SSH connection's short-command exec queue.
final class SshAgentWorktreeShell implements AgentWorktreeShell {
  /// Creates a shell for [session].
  const SshAgentWorktreeShell(this.session);

  /// Connection the scripts run on.
  final SshSession session;

  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) => session.runQueuedExec(() async {
    final exec = await openSshExec(
      session.execute(script),
      const Duration(seconds: 10),
    );
    try {
      final stdout = StringBuffer();
      final stdoutDone = exec.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(stdout.write);
      final stderrDone = exec.stderr.drain<void>();
      await Future.wait<void>([stdoutDone, stderrDone, exec.done])
          .timeout(timeout);
      return AgentWorktreeExecResult(
        stdout: stdout.toString(),
        exitCode: exec.exitCode,
      );
    } on TimeoutException {
      exec.channel.destroy();
      rethrow;
    } finally {
      exec.close();
    }
  });
}

/// Why a worktree operation failed.
enum AgentWorktreeErrorKind {
  /// The host has no `git` on the command path.
  gitMissing,

  /// The repository directory does not exist.
  repositoryMissing,

  /// The repository path is not inside a git work tree.
  notRepository,

  /// `git check-ref-format` rejected the branch name.
  invalidBranch,

  /// The base ref does not name a commit.
  invalidBase,

  /// Every candidate branch name or path was already taken.
  collision,

  /// `git worktree add` failed.
  addFailed,

  /// `git status` could not read the worktree.
  statusFailed,

  /// `git worktree remove` failed.
  removeFailed,

  /// The worktree has uncommitted changes, so it was kept.
  dirty,

  /// The host is not a POSIX shell host.
  unsupportedHost,

  /// The command did not finish or returned output the app cannot read.
  unavailable,
}

/// A worktree operation that could not complete.
final class AgentWorktreeException implements Exception {
  /// Creates an exception.
  const AgentWorktreeException(this.kind, {this.detail});

  /// What went wrong.
  final AgentWorktreeErrorKind kind;

  /// First line of git's own message, shown to the user but never logged.
  final String? detail;

  /// User-facing explanation.
  String get message {
    final summary = switch (kind) {
      AgentWorktreeErrorKind.gitMissing => 'git is not installed on the host.',
      AgentWorktreeErrorKind.repositoryMissing =>
        'The repository folder does not exist on the host.',
      AgentWorktreeErrorKind.notRepository =>
        'The repository folder is not a git repository.',
      AgentWorktreeErrorKind.invalidBranch =>
        'git rejected the branch name. Check the branch template.',
      AgentWorktreeErrorKind.invalidBase =>
        'The base ref does not name a commit in the repository.',
      AgentWorktreeErrorKind.collision =>
        'Every candidate branch name or folder is already taken.',
      AgentWorktreeErrorKind.addFailed => 'git could not create the worktree.',
      AgentWorktreeErrorKind.statusFailed =>
        'git could not read the worktree status.',
      AgentWorktreeErrorKind.removeFailed =>
        'git could not remove the worktree.',
      AgentWorktreeErrorKind.dirty =>
        'The worktree has uncommitted changes, so it was kept.',
      AgentWorktreeErrorKind.unsupportedHost =>
        'Worktree launches need a macOS or Linux host.',
      AgentWorktreeErrorKind.unavailable =>
        'The host did not answer the worktree command.',
    };
    final extra = detail?.trim();
    return extra == null || extra.isEmpty ? summary : '$summary $extra';
  }

  @override
  String toString() => 'AgentWorktreeException(${kind.name})';
}

/// State of a recorded worktree, read before offering to remove it.
@immutable
final class AgentWorktreeStatus {
  /// Creates a status.
  const AgentWorktreeStatus({
    required this.exists,
    required this.changedFiles,
    required this.ignoredEntries,
    required this.branchHasNewCommits,
  });

  /// Whether the worktree folder still exists.
  final bool exists;

  /// Modified, staged or untracked files; any keeps the worktree.
  final int changedFiles;

  /// Ignored files or folders that removing the worktree would delete.
  final int ignoredEntries;

  /// Whether the branch moved past the commit it was created at, so it is
  /// kept after the worktree is removed.
  final bool branchHasNewCommits;

  /// Whether removing the worktree would discard uncommitted work.
  bool get isDirty => changedFiles > 0;
}

/// Result of removing a worktree.
@immutable
final class AgentWorktreeRemoval {
  /// Creates a removal result.
  const AgentWorktreeRemoval({required this.branchDeleted});

  /// Whether the branch was deleted because it had no new commits.
  final bool branchDeleted;
}

const _marker = 'MSSH_WT';
const _separator = '\x1f';
const _createTimeout = Duration(minutes: 3);
const _commandTimeout = Duration(seconds: 30);

/// Puts common git locations (Homebrew first, ahead of the macOS command-line
/// tools shim) on the minimal PATH that SSH exec channels start with.
const _pathPrefix =
    r'export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.nix-profile/bin:$HOME/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"';

const _scriptPrelude =
    '$_pathPrefix\n'
    r'''
mssh_emit() { printf 'MSSH_WT'; for mssh_f in "$@"; do printf '\037%s' "$mssh_f"; done; printf '\n'; }
mssh_fail() { mssh_emit error "$1" "$2"; exit 0; }
mssh_clean() { printf '%s' "$1" | tr -d '\037\r' | tr '\n' ' ' | cut -c1-240; }
command -v git >/dev/null 2>&1 || mssh_fail no_git ''
''';

/// Quotes [value] as one literal POSIX shell word.
@visibleForTesting
String quoteAgentWorktreeShellWord(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// Quotes a remote path, expanding only a leading `~` to `$HOME`.
@visibleForTesting
String quoteAgentWorktreeRemotePath(String path) {
  if (path == '~' || path == '~/') {
    return r'"$HOME"';
  }
  if (path.startsWith('~/')) {
    return '"\$HOME"/${quoteAgentWorktreeShellWord(path.substring(2))}';
  }
  return quoteAgentWorktreeShellWord(path);
}

/// Builds the script that creates a worktree for [target] in [repository].
@visibleForTesting
String buildAgentWorktreeCreateScript({
  required String repository,
  required String baseRef,
  required AgentWorktreeTarget target,
}) {
  final worktree = target.pathIsRepositoryRelative
      ? '"\$top"${quoteAgentWorktreeShellWord(target.path)}'
      : quoteAgentWorktreeRemotePath(target.path);
  return '$_scriptPrelude'
      'repo=${quoteAgentWorktreeRemotePath(repository)}\n'
      'branch=${quoteAgentWorktreeShellWord(target.branch)}\n'
      'base=${quoteAgentWorktreeShellWord(baseRef)}\n'
      r'''
[ -d "$repo" ] || mssh_fail missing_repository ''
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || mssh_fail not_repository ''
[ -n "$top" ] || mssh_fail not_repository ''
prefix=$(git -C "$repo" rev-parse --show-prefix 2>/dev/null)
checked=$(git check-ref-format --branch "$branch" 2>/dev/null) || mssh_fail invalid_branch ''
[ "$checked" = "$branch" ] || mssh_fail invalid_branch ''
commit=$(git -C "$top" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) || mssh_fail invalid_base ''
[ -n "$commit" ] || mssh_fail invalid_base ''
'''
      'wt=$worktree\n'
      r'''
cand_branch=$branch
cand_wt=$wt
n=1
while git -C "$top" show-ref --verify --quiet "refs/heads/$cand_branch" ||
  [ -e "$cand_wt" ] || [ -L "$cand_wt" ] ||
  git -C "$top" worktree list --porcelain 2>/dev/null | grep -F -x -q -e "worktree $cand_wt"; do
  n=$((n + 1))
  [ "$n" -le 50 ] || mssh_fail collision ''
  cand_branch="$branch-$n"
  cand_wt="$wt-$n"
done
git check-ref-format --branch "$cand_branch" >/dev/null 2>&1 || mssh_fail invalid_branch ''
if ! err=$(git -C "$top" worktree add -b "$cand_branch" -- "$cand_wt" "$commit" 2>&1 >/dev/null); then
  mssh_fail add_failed "$(mssh_clean "$err")"
fi
phys=$(cd -P -- "$cand_wt" >/dev/null 2>&1 && pwd -P) || phys=$cand_wt
logical=$(cd -- "$cand_wt" >/dev/null 2>&1 && pwd) || logical=$cand_wt
toplevel=$(cd -P -- "$top" >/dev/null 2>&1 && pwd -P) || toplevel=$top
start=$phys
if [ -n "$prefix" ] && [ -d "$phys/${prefix%/}" ]; then start=$phys/${prefix%/}; fi
mssh_emit ok "$cand_branch" "$phys" "$logical" "$commit" "$toplevel" "$start"
''';
}

String _recordAssignments(AgentWorktreeRecord record) =>
    'repo=${quoteAgentWorktreeShellWord(record.repository)}\n'
    'wt=${quoteAgentWorktreeShellWord(record.path)}\n'
    'branch=${quoteAgentWorktreeShellWord(record.branch)}\n'
    'base=${quoteAgentWorktreeShellWord(record.baseCommit)}\n';

/// Builds the script that reports a recorded worktree's state.
@visibleForTesting
String buildAgentWorktreeStatusScript(AgentWorktreeRecord record) =>
    '$_scriptPrelude${_recordAssignments(record)}'
    r'''
[ -e "$wt" ] || { mssh_emit missing; exit 0; }
changes=$(git -C "$wt" status --porcelain=v1 --untracked-files=normal 2>/dev/null) || mssh_fail status_failed ''
count=0
[ -z "$changes" ] || count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
ignored=$(git -C "$wt" status --porcelain=v1 --ignored 2>/dev/null | grep -c '^!! ')
tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)
moved=no
[ -z "$tip" ] || [ "$tip" = "$base" ] || moved=yes
mssh_emit status "$count" "${ignored:-0}" "$moved"
''';

/// Builds the script that removes a recorded worktree.
///
/// It refuses a worktree with uncommitted changes and never forces git, and
/// it deletes the branch only while the branch still points at the commit it
/// was created at, so no commit is ever lost.
@visibleForTesting
String buildAgentWorktreeRemoveScript(AgentWorktreeRecord record) =>
    '$_scriptPrelude${_recordAssignments(record)}'
    r'''
if [ ! -e "$wt" ] && [ ! -L "$wt" ]; then
  git -C "$repo" worktree prune >/dev/null 2>&1
  deleted=no
  git -C "$repo" update-ref -d "refs/heads/$branch" "$base" >/dev/null 2>&1 && deleted=yes
  mssh_emit removed "$deleted"
  exit 0
fi
changes=$(git -C "$wt" status --porcelain=v1 --untracked-files=normal 2>/dev/null) || mssh_fail status_failed ''
if [ -n "$changes" ]; then
  mssh_emit dirty "$(printf '%s\n' "$changes" | wc -l | tr -d ' ')"
  exit 0
fi
if ! err=$(git -C "$repo" worktree remove -- "$wt" 2>&1 >/dev/null); then
  mssh_fail remove_failed "$(mssh_clean "$err")"
fi
deleted=no
git -C "$repo" update-ref -d "refs/heads/$branch" "$base" >/dev/null 2>&1 && deleted=yes
mssh_emit removed "$deleted"
''';

/// Builds the script that reports whether tmux session [name] exists.
@visibleForTesting
String buildAgentWorktreeTmuxSessionProbeScript(String name) =>
    '$_pathPrefix\n'
    'target=${quoteAgentWorktreeShellWord('=$name')}\n'
    r'''
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$target" 2>/dev/null; then
  printf 'MSSH_WT\037present\n'
else
  printf 'MSSH_WT\037absent\n'
fi
''';

/// Creates and removes agent worktrees on a host.
class AgentWorktreeService {
  /// Creates the service.
  const AgentWorktreeService();

  /// Creates a worktree on a new branch for a launch.
  ///
  /// [repository] is the configured repository path; when it points inside
  /// the repository, the agent starts in the matching subdirectory of the new
  /// worktree. Collisions with an existing branch, folder or registered
  /// worktree get a numeric suffix rather than touching what is there.
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
    DateTime? now,
  }) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeCreateScript(
        repository: repository,
        baseRef: baseRef,
        target: target,
      ),
      timeout: _createTimeout,
      operation: 'create',
    );
    if (fields.first != 'ok' || fields.length < 7) {
      throw _errorFrom(fields);
    }
    final path = fields[2];
    final logicalPath = fields[3];
    return AgentWorktreeRecord(
      hostId: hostId,
      branch: fields[1],
      path: path,
      alternatePath: logicalPath == path ? null : logicalPath,
      baseCommit: fields[4],
      repository: fields[5],
      startDirectory: fields[6],
      createdAt: (now ?? DateTime.now()).toUtc(),
    );
  }

  /// Reads whether [record]'s worktree has uncommitted work.
  Future<AgentWorktreeStatus> status(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeStatusScript(record),
      timeout: _commandTimeout,
      operation: 'status',
    );
    switch (fields) {
      case ['missing', ...]:
        return const AgentWorktreeStatus(
          exists: false,
          changedFiles: 0,
          ignoredEntries: 0,
          branchHasNewCommits: false,
        );
      case ['status', final changed, final ignored, final moved, ...]:
        return AgentWorktreeStatus(
          exists: true,
          changedFiles: int.tryParse(changed.trim()) ?? 0,
          ignoredEntries: int.tryParse(ignored.trim()) ?? 0,
          branchHasNewCommits: moved == 'yes',
        );
      default:
        throw _errorFrom(fields);
    }
  }

  /// Removes [record]'s worktree, refusing when it has uncommitted changes.
  ///
  /// Throws an [AgentWorktreeException] of kind
  /// [AgentWorktreeErrorKind.dirty] instead of removing a dirty worktree.
  Future<AgentWorktreeRemoval> remove(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeRemoveScript(record),
      timeout: _commandTimeout,
      operation: 'remove',
    );
    switch (fields) {
      case ['removed', final deleted, ...]:
        return AgentWorktreeRemoval(branchDeleted: deleted == 'yes');
      case ['dirty', ...]:
        throw const AgentWorktreeException(AgentWorktreeErrorKind.dirty);
      default:
        throw _errorFrom(fields);
    }
  }

  /// Whether tmux session [name] already exists on the host.
  Future<bool> tmuxSessionExists(AgentWorktreeShell shell, String name) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeTmuxSessionProbeScript(name),
      timeout: _commandTimeout,
      operation: 'tmux_probe',
    );
    return fields.first == 'present';
  }

  Future<List<String>> _runScript(
    AgentWorktreeShell shell,
    String script, {
    required Duration timeout,
    required String operation,
  }) async {
    final AgentWorktreeExecResult result;
    try {
      result = await shell.run(script, timeout: timeout);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'command_failed',
        fields: {'operation': operation, 'errorType': error.runtimeType},
      );
      throw const AgentWorktreeException(AgentWorktreeErrorKind.unavailable);
    }
    final fields = parseAgentWorktreeOutput(result.stdout);
    if (fields == null) {
      DiagnosticsLogService.instance.warning(
        'agent.worktree',
        'unreadable_output',
        fields: {'operation': operation, 'exitCode': result.exitCode},
      );
      throw const AgentWorktreeException(AgentWorktreeErrorKind.unavailable);
    }
    return fields;
  }
}

/// Reads the fields of the last marker line in [stdout], or null when the
/// script never reached one.
@visibleForTesting
List<String>? parseAgentWorktreeOutput(String stdout) {
  for (final line in const LineSplitter().convert(stdout).reversed) {
    final start = line.indexOf('$_marker$_separator');
    if (start < 0) continue;
    final fields = line
        .substring(start + _marker.length + _separator.length)
        .split(_separator);
    if (fields.isEmpty || fields.first.isEmpty) return null;
    return fields;
  }
  return null;
}

AgentWorktreeException _errorFrom(List<String> fields) {
  final code = fields.first == 'error' && fields.length > 1 ? fields[1] : '';
  final detail = fields.first == 'error' && fields.length > 2
      ? fields[2].trim()
      : null;
  final kind = switch (code) {
    'no_git' => AgentWorktreeErrorKind.gitMissing,
    'missing_repository' => AgentWorktreeErrorKind.repositoryMissing,
    'not_repository' => AgentWorktreeErrorKind.notRepository,
    'invalid_branch' => AgentWorktreeErrorKind.invalidBranch,
    'invalid_base' => AgentWorktreeErrorKind.invalidBase,
    'collision' => AgentWorktreeErrorKind.collision,
    'add_failed' => AgentWorktreeErrorKind.addFailed,
    'status_failed' => AgentWorktreeErrorKind.statusFailed,
    'remove_failed' => AgentWorktreeErrorKind.removeFailed,
    _ => AgentWorktreeErrorKind.unavailable,
  };
  return AgentWorktreeException(
    kind,
    detail: detail == null || detail.isEmpty ? null : detail,
  );
}

/// Provider for [AgentWorktreeService].
final agentWorktreeServiceProvider = Provider<AgentWorktreeService>(
  (ref) => const AgentWorktreeService(),
);
