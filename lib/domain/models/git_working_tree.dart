import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// Which side of git's index a working tree change sits on.
///
/// A path can appear in more than one group: a file with staged edits and
/// further unstaged edits is listed once as [staged] and once as [unstaged],
/// each with its own counts and diff, exactly as git models it.
enum GitChangeGroup {
  /// Unmerged paths left by a merge, rebase, or cherry-pick.
  conflicted,

  /// Changes recorded in the index (HEAD vs index).
  staged,

  /// Changes not yet staged (index vs working tree).
  unstaged,

  /// Files git does not track yet.
  untracked,
}

/// What happened to a path, from git's status letter.
enum GitChangeKind {
  /// `M`: contents changed.
  modified,

  /// `A`: newly added to the index (or intent-to-add).
  added,

  /// `D`: removed.
  deleted,

  /// `R`: renamed, possibly with edits.
  renamed,

  /// `C`: copied from another path.
  copied,

  /// `T`: type changed, such as a file becoming a symlink.
  typeChanged,

  /// Not tracked by git.
  untracked,

  /// Unmerged: both sides changed the path.
  conflicted,
}

/// Maps a porcelain status letter to a [GitChangeKind].
GitChangeKind? gitChangeKindForStatusLetter(String letter) => switch (letter) {
  'M' => GitChangeKind.modified,
  'A' => GitChangeKind.added,
  'D' => GitChangeKind.deleted,
  'R' => GitChangeKind.renamed,
  'C' => GitChangeKind.copied,
  'T' => GitChangeKind.typeChanged,
  'U' => GitChangeKind.conflicted,
  _ => null,
};

/// Added and removed line counts for one side of a change.
@immutable
class GitLineCounts extends Equatable {
  /// Creates text line counts.
  const GitLineCounts({required this.added, required this.removed})
    : binary = false;

  /// Creates counts for a binary change, which has no line counts.
  const GitLineCounts.binary() : added = 0, removed = 0, binary = true;

  /// Lines added.
  final int added;

  /// Lines removed.
  final int removed;

  /// Whether git treats the change as binary.
  final bool binary;

  @override
  List<Object?> get props => [added, removed, binary];
}

/// One changed path in one [GitChangeGroup].
@immutable
class GitChangedFile extends Equatable {
  /// Creates a changed file entry.
  const GitChangedFile({
    required this.path,
    required this.group,
    required this.kind,
    this.originalPath,
    this.counts,
    this.statusCode,
    this.isSubmodule = false,
  });

  /// Path relative to the repository root, as git reports it.
  final String path;

  /// Source path of a rename or copy.
  final String? originalPath;

  /// The index side this entry describes.
  final GitChangeGroup group;

  /// What happened to the path.
  final GitChangeKind kind;

  /// Line counts, or null while unknown (for example an untracked file whose
  /// count has not loaded, or output that was cut off).
  final GitLineCounts? counts;

  /// The two-letter porcelain code (such as `UU` or `AA`) for conflicts.
  final String? statusCode;

  /// Whether the path is a submodule.
  final bool isSubmodule;

  /// Stable identity of this entry within a snapshot.
  String get id => '${group.name}\u0000$path';

  /// Returns a copy with [counts] replaced.
  GitChangedFile withCounts(GitLineCounts? counts) => GitChangedFile(
    path: path,
    group: group,
    kind: kind,
    originalPath: originalPath,
    counts: counts,
    statusCode: statusCode,
    isSubmodule: isSubmodule,
  );

  @override
  List<Object?> get props => [
    path,
    originalPath,
    group,
    kind,
    counts,
    statusCode,
    isSubmodule,
  ];
}

/// Outcome of reading a directory's git state.
enum GitWorkingTreeState {
  /// The directory is in a git work tree and [GitWorkingTreeSnapshot.files]
  /// lists its changes.
  ready,

  /// The directory is not inside a git work tree.
  notRepository,

  /// The directory does not exist or cannot be entered.
  missingDirectory,

  /// `git` is not on the host's PATH.
  gitUnavailable,

  /// git refused the repository because another user owns it
  /// (`safe.directory`).
  unsafeRepository,

  /// git ran but `git status` failed.
  failed,
}

/// A read of a working tree's status at one moment.
@immutable
class GitWorkingTreeSnapshot {
  /// Creates a snapshot.
  GitWorkingTreeSnapshot({
    required this.state,
    required this.refreshedAt,
    List<GitChangedFile> files = const <GitChangedFile>[],
    this.repositoryRoot,
    this.branch,
    this.detached = false,
    this.truncated = false,
    this.exitCode,
  }) : files = List<GitChangedFile>.unmodifiable(files);

  /// What the read found.
  final GitWorkingTreeState state;

  /// When the read finished.
  final DateTime refreshedAt;

  /// Changed paths, grouped and sorted.
  final List<GitChangedFile> files;

  /// Absolute repository root on the host.
  final String? repositoryRoot;

  /// Current branch name, when on a branch.
  final String? branch;

  /// Whether HEAD is detached.
  final bool detached;

  /// Whether output was cut off, so [files] may be incomplete.
  final bool truncated;

  /// Exit status of `git status` when [state] is [GitWorkingTreeState.failed].
  final int? exitCode;

  /// Files in [group], in display order.
  List<GitChangedFile> filesIn(GitChangeGroup group) =>
      files.where((file) => file.group == group).toList(growable: false);

  /// Returns a copy with [files] replaced.
  GitWorkingTreeSnapshot withFiles(List<GitChangedFile> files) =>
      GitWorkingTreeSnapshot(
        state: state,
        refreshedAt: refreshedAt,
        files: files,
        repositoryRoot: repositoryRoot,
        branch: branch,
        detached: detached,
        truncated: truncated,
        exitCode: exitCode,
      );
}

/// One `@@` hunk of a unified diff.
@immutable
class GitDiffHunk {
  /// Creates a hunk.
  GitDiffHunk({
    required this.header,
    required List<String> lines,
    this.oldStart,
    this.oldCount,
    this.newStart,
    this.newCount,
  }) : lines = List<String>.unmodifiable(lines);

  /// The `@@ -a,b +c,d @@ context` line.
  final String header;

  /// Body lines after [header], each starting with ` `, `+`, `-` or `\`.
  final List<String> lines;

  /// First line of the hunk in the old file.
  final int? oldStart;

  /// Number of old-file lines the hunk covers.
  final int? oldCount;

  /// First line of the hunk in the new file.
  final int? newStart;

  /// Number of new-file lines the hunk covers.
  final int? newCount;

  /// The hunk as unified diff text, header included.
  String get text => [header, ...lines].join('\n');

  /// Body lines as unified diff text, header excluded.
  String get body => lines.join('\n');
}

/// The parsed diff for one [GitChangedFile].
@immutable
class GitFileDiff {
  /// Creates a parsed file diff.
  GitFileDiff({
    required List<String> headerLines,
    required List<GitDiffHunk> hunks,
    required this.binary,
    required this.truncated,
    this.failed = false,
  }) : headerLines = List<String>.unmodifiable(headerLines),
       hunks = List<GitDiffHunk>.unmodifiable(hunks);

  /// Lines before the first hunk (`diff --git`, `index`, mode and rename
  /// lines), which describe the change rather than its content.
  final List<String> headerLines;

  /// Hunks in file order.
  final List<GitDiffHunk> hunks;

  /// Whether git reported a binary change, which has no text diff.
  final bool binary;

  /// Whether output stopped at the size cap, so the last hunk may be partial
  /// and later hunks are missing.
  final bool truncated;

  /// Whether git exited with an error rather than a diff.
  final bool failed;
}
