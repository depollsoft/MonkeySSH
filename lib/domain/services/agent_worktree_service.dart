/// Creates, inspects and removes git worktrees for agent launches over SSH.
///
/// Every operation sends the same fixed command line ([agentWorktreeExecCommand])
/// and writes a POSIX script to `/bin/sh` on stdin, so the user's login shell
/// never parses user content. Inside the script, paths, branch names and refs
/// only appear as single-quoted words (a leading `~` becomes a quoted
/// `"$HOME"`), and `git` re-validates each one (`git check-ref-format
/// --branch`, `git rev-parse --verify`) before anything is created. Repository
/// hooks are skipped when the worktree is checked out: running repository
/// scripts is a separate trust decision. Nothing here logs those values.
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

/// The only command line a worktree operation sends to the host.
///
/// sshd hands the command line to the user's login shell, which may be fish,
/// csh or another shell whose quoting rules differ from POSIX. The command is
/// therefore fixed and shell-neutral, and every script, with the paths and
/// branch names it carries, travels on stdin to `/bin/sh` instead.
const agentWorktreeExecCommand = 'exec /bin/sh -s';

/// Wraps [script] for `/bin/sh -s`.
///
/// The shell parses the whole function before running it, and the function
/// runs with stdin from `/dev/null`, so no command inside it can read the
/// rest of the script as input.
@visibleForTesting
String buildAgentWorktreeStdinPayload(String script) =>
    'mssh_main() {\n$script\n}\nmssh_main </dev/null\n';

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
      session.execute(agentWorktreeExecCommand),
      const Duration(seconds: 10),
    );
    var finished = false;
    try {
      final stdout = StringBuffer();
      final stdoutDone = exec.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(stdout.write);
      final stderrDone = exec.stderr.drain<void>();
      exec.stdin.add(utf8.encode(buildAgentWorktreeStdinPayload(script)));
      await Future.wait<void>([
        stdoutDone,
        stderrDone,
        exec.done,
        exec.stdin.close(),
      ]).timeout(timeout);
      finished = true;
      return AgentWorktreeExecResult(
        stdout: stdout.toString(),
        exitCode: exec.exitCode,
      );
    } finally {
      if (finished) {
        exec.close();
      } else {
        // EOF alone does not release a channel whose process ignores stdin.
        exec.channel.destroy();
      }
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

  /// An existing branch is a parent folder of the new branch name, such as a
  /// branch `agent` blocking `agent/claude-1`.
  branchConflict,

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

  /// The worktree's detached HEAD holds commits no branch or tag contains,
  /// so it was kept.
  unsavedCommits,

  /// A rebase, merge, cherry-pick, revert or bisect is in progress in the
  /// worktree, so it was kept.
  operationInProgress,

  /// The folder is no longer the worktree MonkeySSH recorded, so it was left
  /// alone and the record forgotten.
  stale,

  /// The host is not a POSIX shell host.
  unsupportedHost,

  /// The preset's worktree settings do not render a usable branch or path.
  invalidOptions,

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
      AgentWorktreeErrorKind.branchConflict =>
        'An existing branch blocks the new branch name. Change the branch '
            'template so it does not start with that branch. Blocking branch:',
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
      AgentWorktreeErrorKind.unsavedCommits =>
        'The worktree has commits that are not on any branch, so it was kept.',
      AgentWorktreeErrorKind.operationInProgress =>
        'A rebase, merge or similar operation is in progress in the '
            'worktree, so it was kept.',
      AgentWorktreeErrorKind.stale =>
        'The folder is no longer the worktree MonkeySSH created, so it was '
            'left alone.',
      AgentWorktreeErrorKind.unsupportedHost =>
        'Worktree launches need a macOS or Linux host.',
      AgentWorktreeErrorKind.invalidOptions =>
        'Fix the worktree settings in this host’s preset.',
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
    this.unsavedCommits = false,
    this.operationInProgress,
    this.stale = false,
    this.currentBranch,
  });

  /// Whether the worktree folder still exists.
  final bool exists;

  /// Modified, staged or untracked files; any keeps the worktree.
  final int changedFiles;

  /// Ignored files or folders that removing the worktree would delete.
  final int ignoredEntries;

  /// Whether the worktree's branch is kept after removal: the recorded
  /// branch moved past the commit it was created at, or the worktree now has
  /// another branch checked out.
  final bool branchHasNewCommits;

  /// Whether HEAD is detached on commits no branch or tag contains, which
  /// removing the worktree would make unreachable.
  final bool unsavedCommits;

  /// The git operation stopped part-way in the worktree, such as
  /// `rebase-merge` or `MERGE_HEAD`, if any.
  final String? operationInProgress;

  /// Whether the folder is no longer the worktree MonkeySSH recorded, for
  /// example because someone made another worktree at the same path. A
  /// branch switch or rename inside the worktree keeps it recorded.
  final bool stale;

  /// The branch the worktree has checked out, when HEAD is on a branch. It
  /// differs from the recorded branch after a switch or rename.
  final String? currentBranch;

  /// Whether removing the worktree would discard uncommitted work.
  bool get isDirty => changedFiles > 0;

  /// Whether MonkeySSH refuses to remove the worktree.
  bool get blocksRemoval =>
      isDirty || unsavedCommits || operationInProgress != null;
}

/// Result of removing a worktree.
@immutable
final class AgentWorktreeRemoval {
  /// Creates a removal result.
  const AgentWorktreeRemoval({required this.branchDeleted});

  /// Whether the branch was deleted because it had no new commits.
  final bool branchDeleted;
}

/// Branch, folder and base commit chosen for a new worktree before git
/// creates it, so the app can record the worktree first.
@immutable
final class AgentWorktreePlan {
  /// Creates a plan.
  const AgentWorktreePlan({
    required this.branch,
    required this.path,
    required this.baseCommit,
    required this.repository,
    required this.subdirectory,
  });

  /// Branch to create.
  final String branch;

  /// Absolute worktree folder to create.
  final String path;

  /// Commit the branch starts at.
  final String baseCommit;

  /// Top-level directory of the repository, without symlinks.
  final String repository;

  /// Path of the configured repository folder inside the repository, such
  /// as `packages/app/`, or empty for the top level.
  final String subdirectory;

  /// A record for this plan before git has created the worktree.
  AgentWorktreeRecord pendingRecord({
    required int hostId,
    required DateTime createdAt,
    String? launchId,
  }) => AgentWorktreeRecord(
    hostId: hostId,
    repository: repository,
    path: path,
    branch: branch,
    baseCommit: baseCommit,
    createdAt: createdAt.toUtc(),
    pending: true,
    launchId: launchId,
  );
}

const _marker = 'MSSH_WT';
const _separator = '\x1f';
const _createTimeout = Duration(minutes: 3);
const _commandTimeout = Duration(seconds: 30);

/// Builds the command path for worktree scripts and defines the output
/// helpers.
///
/// SSH exec channels start with a minimal PATH. The script adds common git
/// and tmux locations (Homebrew ahead of the macOS command-line tools shim,
/// Linuxbrew and MacPorts), then asks the user's POSIX login shell for the
/// PATH its profiles set, the way the terminal's own shell sees it. A marker
/// separates that PATH from anything the profiles print.
const _pathSetup = r'''
PATH="$HOME/.local/bin:$HOME/bin:$HOME/.nix-profile/bin:$HOME/homebrew/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/opt/local/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
mssh_login_env() {
  case "${SHELL##*/}" in bash|zsh|ksh|sh|dash) ;; *) return ;; esac
  mssh_envfile=$(mktemp 2>/dev/null) || return
  "$SHELL" -lc 'printf "%s\n%s\n" "$PATH" "${TMUX_TMPDIR-}" > "$1"' mssh "$mssh_envfile" </dev/null >/dev/null 2>&1
  mssh_login_path=
  mssh_login_tmux=
  { IFS= read -r mssh_login_path; IFS= read -r mssh_login_tmux; } < "$mssh_envfile"
  rm -f "$mssh_envfile"
  [ -z "$mssh_login_path" ] || PATH="$mssh_login_path:$PATH"
  if [ -n "$mssh_login_tmux" ]; then TMUX_TMPDIR=$mssh_login_tmux; export TMUX_TMPDIR; fi
}
mssh_login_env
export PATH
mssh_emit() { printf 'MSSH_WT'; for mssh_f in "$@"; do printf '\037%s' "$mssh_f"; done; printf '\n'; }
mssh_fail() { mssh_emit error "$1" "$2"; exit 0; }
mssh_clean() { printf '%s' "$1" | tr -d '\037\r' | tr '\n' ' ' | cut -c1-240; }
''';

const _gitPrelude =
    '$_pathSetup'
    '''
command -v git >/dev/null 2>&1 || mssh_fail no_git ''
''';

/// Shell helpers shared by the scripts that act on a recorded worktree.
///
/// `mssh_identity` sets `stale=yes` unless `$wt` is still a worktree of
/// `$repo` that this launch created: its git admin dir holds the launch id
/// written at creation, so a branch switch or rename keeps it. Records from
/// before launch ids fall back to HEAD being on the recorded branch or
/// detached. `mssh_safety` sets `count` (changed files), `unsaved`
/// (detached commits no branch, tag, remote-tracking ref or stash contains;
/// per-worktree refs go with the worktree, so they do not count) and
/// `operation` (a rebase, merge, cherry-pick, revert or bisect in progress).
/// `mssh_delete_branch` deletes the branch only while it points at `$base`
/// and no worktree has it checked out.
const _recordHelpers = r'''
mssh_identity() {
  stale=no
  head_ref=
  mssh_here=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || { stale=yes; return; }
  mssh_here=$(cd -P -- "$mssh_here" >/dev/null 2>&1 && pwd -P) || { stale=yes; return; }
  mssh_phys=$(cd -P -- "$wt" >/dev/null 2>&1 && pwd -P) || { stale=yes; return; }
  [ "$mssh_here" = "$mssh_phys" ] || { stale=yes; return; }
  mssh_mine=$(cd -- "$wt" >/dev/null 2>&1 && cd -P -- "$(git rev-parse --git-common-dir 2>/dev/null)" >/dev/null 2>&1 && pwd -P) || { stale=yes; return; }
  mssh_theirs=$(cd -- "$repo" >/dev/null 2>&1 && cd -P -- "$(git rev-parse --git-common-dir 2>/dev/null)" >/dev/null 2>&1 && pwd -P) || { stale=yes; return; }
  [ "$mssh_mine" = "$mssh_theirs" ] || { stale=yes; return; }
  head_ref=$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null)
  if [ -n "$launch" ]; then
    mssh_admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || { stale=yes; return; }
    mssh_mark=
    [ ! -f "$mssh_admin/monkeyssh-launch" ] || IFS= read -r mssh_mark < "$mssh_admin/monkeyssh-launch"
    [ "$mssh_mark" = "$launch" ] || stale=yes
  elif [ -n "$head_ref" ] && [ "$head_ref" != "refs/heads/$branch" ]; then
    stale=yes
  fi
}
mssh_safety() {
  changes=$(git -C "$wt" status --porcelain=v1 --untracked-files=normal 2>/dev/null) || mssh_fail status_failed ''
  count=0
  [ -z "$changes" ] || count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  unsaved=no
  if [ -z "$head_ref" ]; then
    mssh_head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)
    if [ -n "$mssh_head" ] && [ -z "$(git -C "$wt" for-each-ref --contains "$mssh_head" --count=1 --format=x refs/heads refs/tags refs/remotes refs/stash 2>/dev/null)" ]; then
      unsaved=yes
    fi
  fi
  operation=
  for mssh_p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    mssh_g=$(cd -- "$wt" >/dev/null 2>&1 && git rev-parse --git-path "$mssh_p" 2>/dev/null) || continue
    case "$mssh_g" in /*) ;; *) mssh_g="$wt/$mssh_g" ;; esac
    if [ -e "$mssh_g" ]; then operation=$mssh_p; break; fi
  done
}
mssh_delete_branch() {
  deleted=no
  if git -C "$repo" worktree list --porcelain 2>/dev/null | grep -F -x -q -e "branch refs/heads/$branch"; then
    return
  fi
  git -C "$repo" update-ref -d "refs/heads/$branch" "$base" >/dev/null 2>&1 && deleted=yes
}
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

/// Shell condition that is true while `$cand_branch` or `$cand_wt` is taken:
/// an existing branch, a branch nested under it, a file or folder, or a
/// registered (possibly missing) worktree.
const _candidateTaken = r'''

git -C "$top" show-ref --verify --quiet "refs/heads/$cand_branch" ||
  [ -n "$(git -C "$top" for-each-ref --count=1 --format=x "refs/heads/$cand_branch/" 2>/dev/null)" ] ||
  [ -e "$cand_wt" ] || [ -L "$cand_wt" ] ||
  git -C "$top" worktree list --porcelain 2>/dev/null | grep -F -x -q -e "worktree $cand_wt"''';

/// Builds the script that picks the branch and folder for [target] in
/// [repository] without creating anything.
@visibleForTesting
String buildAgentWorktreePlanScript({
  required String repository,
  required String baseRef,
  required AgentWorktreeTarget target,
}) {
  final worktree = target.pathIsRepositoryRelative
      ? '"\$toplevel"${quoteAgentWorktreeShellWord(target.path)}'
      : quoteAgentWorktreeRemotePath(target.path);
  return '$_gitPrelude'
      'repo=${quoteAgentWorktreeRemotePath(repository)}\n'
      'branch=${quoteAgentWorktreeShellWord(target.branch)}\n'
      'base=${quoteAgentWorktreeShellWord(baseRef)}\n'
      r'''
[ -d "$repo" ] || mssh_fail missing_repository ''
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || mssh_fail not_repository ''
[ -n "$top" ] || mssh_fail not_repository ''
toplevel=$(cd -P -- "$top" >/dev/null 2>&1 && pwd -P) || toplevel=$top
prefix=$(git -C "$repo" rev-parse --show-prefix 2>/dev/null)
checked=$(git check-ref-format --branch "$branch" 2>/dev/null) || mssh_fail invalid_branch ''
[ "$checked" = "$branch" ] || mssh_fail invalid_branch ''
mssh_parent=$branch
while :; do
  case "$mssh_parent" in */*) mssh_parent=${mssh_parent%/*} ;; *) break ;; esac
  if git -C "$top" show-ref --verify --quiet "refs/heads/$mssh_parent"; then
    mssh_fail branch_conflict "$(mssh_clean "$mssh_parent")"
  fi
done
commit=$(git -C "$top" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) || mssh_fail invalid_base ''
[ -n "$commit" ] || mssh_fail invalid_base ''
'''
      'wt=$worktree\n'
      r'''
cand_branch=$branch
cand_wt=$wt
n=1
while '''
      '$_candidateTaken'
      '; do\n'
      r'''
  n=$((n + 1))
  [ "$n" -le 50 ] || mssh_fail collision ''
  cand_branch="$branch-$n"
  cand_wt="$wt-$n"
done
git check-ref-format --branch "$cand_branch" >/dev/null 2>&1 || mssh_fail invalid_branch ''
mssh_emit plan "$cand_branch" "$cand_wt" "$commit" "$toplevel" "$prefix"
''';
}

/// Builds the script that creates the worktree [plan] chose.
@visibleForTesting
String buildAgentWorktreeAddScript(
  AgentWorktreePlan plan, {
  String? launchId,
}) =>
    '$_gitPrelude'
    'top=${quoteAgentWorktreeShellWord(plan.repository)}\n'
    'cand_branch=${quoteAgentWorktreeShellWord(plan.branch)}\n'
    'cand_wt=${quoteAgentWorktreeShellWord(plan.path)}\n'
    'commit=${quoteAgentWorktreeShellWord(plan.baseCommit)}\n'
    'prefix=${quoteAgentWorktreeShellWord(plan.subdirectory)}\n'
    'launch=${quoteAgentWorktreeShellWord(launchId ?? '')}\n'
    r'''
[ -d "$top" ] || mssh_fail missing_repository ''
if '''
    '$_candidateTaken'
    '; then\n'
    r'''
  mssh_fail collision ''
fi
git check-ref-format --branch "$cand_branch" >/dev/null 2>&1 || mssh_fail invalid_branch ''
if ! err=$(git -C "$top" -c core.hooksPath=/dev/null worktree add -b "$cand_branch" -- "$cand_wt" "$commit" 2>&1 >/dev/null); then
  mssh_fail add_failed "$(mssh_clean "$err")"
fi
phys=$(cd -P -- "$cand_wt" >/dev/null 2>&1 && pwd -P) || phys=$cand_wt
logical=$(cd -- "$cand_wt" >/dev/null 2>&1 && pwd) || logical=$cand_wt
start=$phys
if [ -n "$prefix" ] && [ -d "$phys/${prefix%/}" ]; then start=$phys/${prefix%/}; fi
if [ -n "$launch" ]; then
  mssh_admin=$(git -C "$cand_wt" rev-parse --absolute-git-dir 2>/dev/null) &&
    printf '%s\n' "$launch" > "$mssh_admin/monkeyssh-launch" 2>/dev/null
fi
mssh_emit ok "$phys" "$logical" "$start"
''';

String _recordAssignments(AgentWorktreeRecord record) =>
    'repo=${quoteAgentWorktreeShellWord(record.repository)}\n'
    'wt=${quoteAgentWorktreeShellWord(record.path)}\n'
    'branch=${quoteAgentWorktreeShellWord(record.branch)}\n'
    'base=${quoteAgentWorktreeShellWord(record.baseCommit)}\n'
    'launch=${quoteAgentWorktreeShellWord(record.launchId ?? '')}\n';

/// Builds the script that reports a recorded worktree's state.
@visibleForTesting
String buildAgentWorktreeStatusScript(AgentWorktreeRecord record) =>
    '$_gitPrelude$_recordHelpers${_recordAssignments(record)}'
    r'''
[ -e "$wt" ] || [ -L "$wt" ] || { mssh_emit missing; exit 0; }
mssh_identity
[ "$stale" = no ] || { mssh_emit stale; exit 0; }
mssh_safety
ignored=$(git -C "$wt" status --porcelain=v1 --ignored --untracked-files=normal 2>/dev/null | grep -c '^!! ')
tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)
moved=no
[ -z "$tip" ] || [ "$tip" = "$base" ] || moved=yes
current=${head_ref#refs/heads/}
[ -z "$current" ] || [ "$current" = "$branch" ] || moved=yes
mssh_emit status "$count" "${ignored:-0}" "$moved" "$unsaved" "$operation" "$current"
''';

/// Builds the script that removes a recorded worktree.
///
/// It checks that the folder is still the recorded worktree, refuses one with
/// uncommitted changes, detached commits no ref contains, or a rebase, merge,
/// cherry-pick, revert or bisect in progress, and never forces git. It
/// deletes the branch only while the branch still points at the commit it
/// was created at and no worktree has it checked out, so no commit is lost.
@visibleForTesting
String buildAgentWorktreeRemoveScript(AgentWorktreeRecord record) =>
    '$_gitPrelude$_recordHelpers${_recordAssignments(record)}'
    r'''
if [ ! -e "$wt" ] && [ ! -L "$wt" ]; then
  git -C "$repo" worktree prune >/dev/null 2>&1
  mssh_delete_branch
  mssh_emit removed "$deleted"
  exit 0
fi
mssh_identity
[ "$stale" = no ] || { mssh_emit stale; exit 0; }
mssh_safety
[ "$count" = 0 ] || { mssh_emit dirty "$count"; exit 0; }
[ "$unsaved" = no ] || { mssh_emit blocked unsaved_commits; exit 0; }
[ -z "$operation" ] || { mssh_emit blocked "$operation"; exit 0; }
if ! err=$(git -C "$repo" worktree remove -- "$wt" 2>&1 >/dev/null); then
  mssh_fail remove_failed "$(mssh_clean "$err")"
fi
mssh_delete_branch
mssh_emit removed "$deleted"
''';

/// Builds the script that lists the pane directories of tmux session [name].
///
/// It reports `absent` only when tmux says the server or session does not
/// exist, `unknown` when tmux cannot be found or fails any other way, and
/// otherwise `present` with each pane's directory. It looks for the server
/// where the user's login shell would, honouring a `TMUX_TMPDIR` set in
/// their profile.
@visibleForTesting
String buildAgentWorktreeTmuxSessionScript(String name) =>
    '$_pathSetup'
    'target=${quoteAgentWorktreeShellWord('=$name')}\n'
    r'''
command -v tmux >/dev/null 2>&1 || { mssh_emit unknown; exit 0; }
if ! mssh_err=$(tmux has-session -t "$target" 2>&1 >/dev/null); then
  case "$mssh_err" in
    *"can't find session"*|*"no server running"*|*"error connecting to"*"No such file or directory"*) mssh_emit absent ;;
    *) mssh_emit unknown ;;
  esac
  exit 0
fi
dirs=$(tmux list-panes -s -t "$target" -F '#{pane_current_path}' 2>/dev/null) || { mssh_emit unknown; exit 0; }
printf '%s\n' "$dirs" | {
  set --
  while IFS= read -r mssh_d; do [ -z "$mssh_d" ] || set -- "$@" "$mssh_d"; done
  mssh_emit present "$@"
}
''';

/// Creates and removes agent worktrees on a host.
class AgentWorktreeService {
  /// Creates the service.
  const AgentWorktreeService();

  /// Picks the branch and folder for a launch without creating anything.
  ///
  /// [repository] is the configured repository path; when it points inside
  /// the repository, the agent starts in the matching subdirectory of the new
  /// worktree. Collisions with an existing branch, folder or registered
  /// worktree get a numeric suffix rather than touching what is there.
  Future<AgentWorktreePlan> plan(
    AgentWorktreeShell shell, {
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
  }) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreePlanScript(
        repository: repository,
        baseRef: baseRef,
        target: target,
      ),
      timeout: _commandTimeout,
      operation: 'plan',
    );
    if (fields case [
      'plan',
      final branch,
      final path,
      final commit,
      final top,
      final prefix,
      ...,
    ]) {
      return AgentWorktreePlan(
        branch: branch,
        path: path,
        baseCommit: commit,
        repository: top,
        subdirectory: prefix,
      );
    }
    throw _errorFrom(fields);
  }

  /// Creates the worktree [plan] chose.
  ///
  /// Throws an [AgentWorktreeException] of kind
  /// [AgentWorktreeErrorKind.collision] when something took the branch or
  /// folder after it was planned.
  Future<AgentWorktreeRecord> add(
    AgentWorktreeShell shell, {
    required int hostId,
    required AgentWorktreePlan plan,
    String? launchId,
    DateTime? now,
  }) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeAddScript(plan, launchId: launchId),
      timeout: _createTimeout,
      operation: 'add',
    );
    if (fields case ['ok', final path, final logicalPath, final start, ...]) {
      return AgentWorktreeRecord(
        hostId: hostId,
        branch: plan.branch,
        path: path,
        alternatePath: logicalPath == path ? null : logicalPath,
        baseCommit: plan.baseCommit,
        repository: plan.repository,
        startDirectory: start,
        createdAt: (now ?? DateTime.now()).toUtc(),
        launchId: launchId,
      );
    }
    throw _errorFrom(fields);
  }

  /// Plans and creates a worktree in one step.
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
    String? launchId,
    DateTime? now,
  }) async => add(
    shell,
    hostId: hostId,
    plan: await plan(
      shell,
      repository: repository,
      baseRef: baseRef,
      target: target,
    ),
    launchId: launchId,
    now: now,
  );

  /// Reads whether [record]'s worktree holds work removal would lose.
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
      case ['stale', ...]:
        return const AgentWorktreeStatus(
          exists: true,
          changedFiles: 0,
          ignoredEntries: 0,
          branchHasNewCommits: false,
          stale: true,
        );
      case [
        'status',
        final changed,
        final ignored,
        final moved,
        final unsaved,
        final operation,
        ...final rest,
      ]:
        final current = rest.isEmpty ? '' : rest.first;
        return AgentWorktreeStatus(
          exists: true,
          changedFiles: int.tryParse(changed.trim()) ?? 0,
          ignoredEntries: int.tryParse(ignored.trim()) ?? 0,
          branchHasNewCommits: moved == 'yes',
          unsavedCommits: unsaved == 'yes',
          operationInProgress: operation.isEmpty ? null : operation,
          currentBranch: current.isEmpty ? null : current,
        );
      default:
        throw _errorFrom(fields);
    }
  }

  /// Removes [record]'s worktree, refusing when it holds work removal would
  /// lose or is no longer the recorded worktree.
  ///
  /// Throws an [AgentWorktreeException] of kind
  /// [AgentWorktreeErrorKind.dirty], [AgentWorktreeErrorKind.unsavedCommits],
  /// [AgentWorktreeErrorKind.operationInProgress] or
  /// [AgentWorktreeErrorKind.stale] instead of removing it.
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
      case ['blocked', 'unsaved_commits', ...]:
        throw const AgentWorktreeException(
          AgentWorktreeErrorKind.unsavedCommits,
        );
      case ['blocked', ...]:
        throw const AgentWorktreeException(
          AgentWorktreeErrorKind.operationInProgress,
        );
      case ['stale', ...]:
        throw const AgentWorktreeException(AgentWorktreeErrorKind.stale);
      default:
        throw _errorFrom(fields);
    }
  }

  /// The pane directories of tmux session [name], or null when the session
  /// does not exist.
  ///
  /// Throws an [AgentWorktreeException] when tmux cannot be found or the
  /// answer is unknown, so callers never mistake that for "no session".
  Future<List<String>?> tmuxSessionDirectories(
    AgentWorktreeShell shell,
    String name,
  ) async {
    final fields = await _runScript(
      shell,
      buildAgentWorktreeTmuxSessionScript(name),
      timeout: _commandTimeout,
      operation: 'tmux_probe',
    );
    return switch (fields) {
      ['present', ...] => fields.sublist(1),
      ['absent', ...] => null,
      _ => throw const AgentWorktreeException(
        AgentWorktreeErrorKind.unavailable,
      ),
    };
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
    'branch_conflict' => AgentWorktreeErrorKind.branchConflict,
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
