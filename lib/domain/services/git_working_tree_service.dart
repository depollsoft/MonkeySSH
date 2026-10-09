/// Read-only git status and diffs for a window's working tree, run on the
/// host over a short-lived SSH exec channel.
///
/// Every command here is read-only. `GIT_OPTIONAL_LOCKS=0` keeps
/// `git status` from refreshing the index (and taking `index.lock`) while an
/// agent works in the same tree. `git diff` ignores that variable and
/// rewrites the index when it finds stat-only changes, so every diff also
/// runs with `diff.autoRefreshIndex=false`. `GIT_LITERAL_PATHSPECS=1` keeps
/// file names with glob characters from matching other paths. Paths and diff text
/// are user content: callers must never log them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/git_working_tree.dart';
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Most status output read, in bytes. The numstat sections come first, so a
/// huge untracked list is what gets cut off.
const int kGitStatusMaxBytes = 2 * 1024 * 1024;

/// Most changed paths parsed from one status read.
const int kGitStatusMaxEntries = 5000;

/// Most bytes of one file's diff read from the host.
const int kGitDiffMaxBytes = 512 * 1024;

/// Most untracked files whose line counts are read per refresh.
const int kGitUntrackedCountLimit = 200;

/// Most characters of quoted paths in one untracked-count command, which
/// keeps the command well under per-argument limits on the host.
const int kGitUntrackedCountMaxCommandChars = 48 * 1024;

/// Most bytes read for untracked line counts.
const int kGitUntrackedCountMaxBytes = 256 * 1024;

/// How long one git command may run before the read gives up.
const Duration kGitCommandTimeout = Duration(seconds: 20);

/// Most hunk lines quoted into an "ask the agent" prompt.
const int kGitHunkPromptMaxLines = 200;

/// Most hunk characters quoted into an "ask the agent" prompt.
const int kGitHunkPromptMaxChars = 12 * 1024;

/// Capped stdout of one host command.
class GitCommandOutput {
  /// Creates command output.
  const GitCommandOutput({required this.stdout, required this.truncated});

  /// Decoded stdout, possibly cut off at the byte cap.
  final String stdout;

  /// Whether stdout hit the byte cap.
  final bool truncated;
}

/// Runs [command] on the host and returns at most [maxBytes] of stdout.
typedef GitCommandRunner = Future<GitCommandOutput> Function(
  String command, {
  required int maxBytes,
  required Duration timeout,
});

/// Thrown when the host did not answer a git read in time.
class GitWorkingTreeTimeoutException implements Exception {
  /// Creates a timeout error.
  const GitWorkingTreeTimeoutException();

  @override
  String toString() => 'GitWorkingTreeTimeoutException';
}

/// Creates the [GitWorkingTreeService] for an SSH session. Overridden in
/// tests to read canned git output.
final gitWorkingTreeServiceFactoryProvider =
    Provider<GitWorkingTreeService Function(SshSession session)>(
      (ref) => GitWorkingTreeService.ssh,
    );

/// Reads git status and per-file diffs through a [GitCommandRunner].
class GitWorkingTreeService {
  /// Creates a service that runs commands through [run].
  GitWorkingTreeService(
    GitCommandRunner run, {
    String Function()? markerFactory,
    DateTime Function()? clock,
  }) : _run = run,
       _markerFactory = markerFactory ?? _randomMarker,
       _clock = clock ?? DateTime.now;

  /// Creates a service that runs commands over [session]'s exec queue.
  factory GitWorkingTreeService.ssh(SshSession session) =>
      GitWorkingTreeService(
        (command, {required maxBytes, required timeout}) =>
            session.runQueuedExec(
              () async => collectCappedSshExecOutput(
                await openSshExec(session.execute(command), timeout),
                maxBytes: maxBytes,
                timeout: timeout,
              ),
            ),
      );

  final GitCommandRunner _run;
  final String Function() _markerFactory;
  final DateTime Function() _clock;

  /// Reads the status of the work tree that contains [directory].
  Future<GitWorkingTreeSnapshot> loadStatus(String directory) async {
    final marker = _markerFactory();
    final output = await _runOrTimeout(
      buildGitWorkingTreeStatusCommand(directory, marker: marker),
      maxBytes: kGitStatusMaxBytes,
    );
    final snapshot = parseGitWorkingTreeOutput(
      output.stdout,
      marker: marker,
      outputTruncated: output.truncated,
      refreshedAt: _clock(),
    );
    DiagnosticsLogService.instance.info(
      'git_changes',
      'status_loaded',
      fields: {
        'state': snapshot.state.name,
        'fileCount': snapshot.files.length,
        'truncated': snapshot.truncated,
      },
    );
    return snapshot;
  }

  /// Reads line counts for up to [kGitUntrackedCountLimit] of [paths],
  /// relative to [repositoryRoot]. Paths missing from the result have no
  /// count (binary files map to [GitLineCounts.binary]).
  Future<Map<String, GitLineCounts>> loadUntrackedCounts(
    String repositoryRoot,
    List<String> paths,
  ) async {
    final command = buildGitUntrackedCountsCommand(
      repositoryRoot: repositoryRoot,
      paths: paths,
      marker: _markerFactory(),
    );
    if (command == null) {
      return const <String, GitLineCounts>{};
    }
    final output = await _runOrTimeout(
      command.command,
      maxBytes: kGitUntrackedCountMaxBytes,
    );
    final payload = _gitSections(output.stdout, command.marker)['counts'];
    if (payload == null) {
      return const <String, GitLineCounts>{};
    }
    return parseGitNumstatZ(payload);
  }

  /// Reads and parses the diff for [file] in [repositoryRoot].
  Future<GitFileDiff> loadDiff(
    String repositoryRoot,
    GitChangedFile file,
  ) async {
    final marker = _markerFactory();
    final output = await _runOrTimeout(
      buildGitFileDiffCommand(
        repositoryRoot: repositoryRoot,
        file: file,
        marker: marker,
      ),
      maxBytes: kGitDiffMaxBytes,
    );
    final sections = _gitSections(output.stdout, marker);
    final diff = sections['diff'];
    if (diff == null) {
      return GitFileDiff(
        headerLines: const <String>[],
        hunks: const <GitDiffHunk>[],
        binary: false,
        truncated: false,
        failed: true,
      );
    }
    final exitCode = _sectionExitCode(sections, 'exit');
    final finished = exitCode != null;
    // `git diff --no-index` exits 1 when the files differ.
    final okExit = file.group == GitChangeGroup.untracked ? 1 : 0;
    final parsed = parseGitUnifiedDiff(diff, truncated: !finished);
    if (finished && exitCode != 0 && exitCode != okExit) {
      return GitFileDiff(
        headerLines: parsed.headerLines,
        hunks: parsed.hunks,
        binary: parsed.binary,
        truncated: false,
        failed: true,
      );
    }
    DiagnosticsLogService.instance.debug(
      'git_changes',
      'diff_loaded',
      fields: {
        'group': file.group.name,
        'hunkCount': parsed.hunks.length,
        'binary': parsed.binary,
        'truncated': parsed.truncated,
      },
    );
    return parsed;
  }

  Future<GitCommandOutput> _runOrTimeout(
    String command, {
    required int maxBytes,
  }) async {
    try {
      return await _run(
        command,
        maxBytes: maxBytes,
        timeout: kGitCommandTimeout,
      );
    } on TimeoutException {
      DiagnosticsLogService.instance.warning(
        'git_changes',
        'command_timeout',
        fields: {'timeoutMs': kGitCommandTimeout.inMilliseconds},
      );
      throw const GitWorkingTreeTimeoutException();
    }
  }
}

String _randomMarker() {
  final random = math.Random();
  final suffix = List<String>.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  return '__MSSH_GIT_${suffix}__';
}

/// Reads at most [maxBytes] of [exec]'s stdout, discarding stderr.
///
/// Once the cap is reached the channel is destroyed rather than drained, so a
/// huge diff stops streaming instead of tying up the connection. Throws
/// [TimeoutException] when the command does not finish within [timeout].
Future<GitCommandOutput> collectCappedSshExecOutput(
  SSHSession exec, {
  required int maxBytes,
  required Duration timeout,
}) async {
  final bytes = BytesBuilder(copy: false);
  var truncated = false;
  var finished = false;
  final capReached = Completer<void>();
  final stdoutDone = Completer<void>();
  final stdout = exec.stdout.listen(null, cancelOnError: true)
    ..onData((chunk) {
      if (truncated) {
        return;
      }
      final remaining = maxBytes - bytes.length;
      if (chunk.length <= remaining) {
        bytes.add(chunk);
        return;
      }
      if (remaining > 0) {
        bytes.add(Uint8List.sublistView(chunk, 0, remaining));
      }
      truncated = true;
      if (!capReached.isCompleted) {
        capReached.complete();
      }
    })
    ..onDone(() {
      if (!stdoutDone.isCompleted) {
        stdoutDone.complete();
      }
    })
    ..onError((Object error, StackTrace stackTrace) {
      if (!stdoutDone.isCompleted) {
        stdoutDone.completeError(error, stackTrace);
      }
    });
  final stderr = exec.stderr.listen(
    (_) {},
    onError: (Object _) {},
    cancelOnError: true,
  );
  try {
    await Future.any<void>([
      Future.wait<void>([stdoutDone.future, exec.done]),
      capReached.future,
    ]).timeout(timeout);
    finished = !truncated;
  } finally {
    await stdout.cancel();
    await stderr.cancel();
    if (finished) {
      exec.close();
    } else {
      await closeAbandonedSshExec(exec, grace: Duration.zero);
    }
  }
  return GitCommandOutput(
    stdout: const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes()),
    truncated: truncated,
  );
}

/// Quotes a host directory for a POSIX shell, expanding a leading `~` to
/// `$HOME` (quoted) the way an interactive shell would.
String gitShellPathArgument(String path) {
  if (path == '~') {
    return r'"$HOME"';
  }
  if (path.startsWith('~/')) {
    return r'"$HOME"' + shellEscapePosix(path.substring(1));
  }
  if (path.startsWith('-')) {
    return shellEscapePosix('./$path');
  }
  return shellEscapePosix(path);
}

const _gitPrelude = <String>[
  r'PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"',
  'GIT_OPTIONAL_LOCKS=0',
  'GIT_LITERAL_PATHSPECS=1',
  'export PATH GIT_OPTIONAL_LOCKS GIT_LITERAL_PATHSPECS',
];

/// `git diff` with index auto-refresh off, so it never writes the index.
const _gitDiff = 'git -c diff.autoRefreshIndex=false diff';

const _gitDiffFlags = '--no-color --no-ext-diff --no-textconv';

const _gitStatusCommand =
    'git -c status.renames=true -c diff.renames=true status '
    '--porcelain=v2 -z --branch --untracked-files=all';

const _reportNoDir = r'''{ printf '%s:no-dir\n' "$m"; exit 0; }''';

String _wrapGitScript(String marker, List<String> lines) {
  final script = [..._gitPrelude, 'm=${shellEscapePosix(marker)}', ...lines];
  return '/bin/sh -c ${shellEscapePosix(script.join('\n'))}';
}

/// Builds the read-only command that reports the work tree containing
/// [directory]: its root, per-side numstat, and porcelain v2 status, each in
/// a section introduced by `<marker>:<name>`.
String buildGitWorkingTreeStatusCommand(
  String directory, {
  required String marker,
}) => _wrapGitScript(marker, [
  r'''command -v git >/dev/null 2>&1 || { printf '%s:no-git\n' "$m"; exit 0; }''',
  'cd ${gitShellPathArgument(directory)} 2>/dev/null || $_reportNoDir',
  r'if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then',
  r'  case "$(git rev-parse --git-dir 2>&1)" in',
  r"""  *dubious*) printf '%s:unsafe\n' "$m" ;;""",
  r"""  *) printf '%s:not-repo\n' "$m" ;;""",
  '  esac',
  '  exit 0',
  'fi',
  r'top=$(git rev-parse --show-toplevel 2>/dev/null)',
  'cd "\$top" 2>/dev/null || $_reportNoDir',
  r"""printf '%s:root\n%s\n' "$m" "$top" """,
  r"""printf '%s:unstaged\n' "$m" """,
  '$_gitDiff $_gitDiffFlags -M --numstat -z 2>/dev/null',
  r"""printf '\n%s:staged\n' "$m" """,
  '$_gitDiff --cached $_gitDiffFlags -M --numstat -z 2>/dev/null',
  r"""printf '\n%s:status\n' "$m" """,
  '$_gitStatusCommand 2>/dev/null',
  r"""printf '\n%s:status-exit:%s\n' "$m" "$?" """,
]);

/// Builds the read-only command that prints [file]'s unified diff from
/// [repositoryRoot], in a `<marker>:diff` section followed by the exit code.
String buildGitFileDiffCommand({
  required String repositoryRoot,
  required GitChangedFile file,
  required String marker,
}) {
  final path = shellEscapePosix(file.path);
  final original = file.originalPath;
  final pathspec = original == null
      ? path
      : '$path ${shellEscapePosix(original)}';
  final diff = switch (file.group) {
    GitChangeGroup.untracked =>
      '$_gitDiff --no-index $_gitDiffFlags -- /dev/null $path',
    GitChangeGroup.staged =>
      '$_gitDiff --cached $_gitDiffFlags -M -- $pathspec',
    GitChangeGroup.unstaged => '$_gitDiff $_gitDiffFlags -M -- $pathspec',
    GitChangeGroup.conflicted => '$_gitDiff $_gitDiffFlags -- $path',
  };
  return _wrapGitScript(marker, [
    'cd ${gitShellPathArgument(repositoryRoot)} 2>/dev/null || $_reportNoDir',
    r"""printf '%s:diff\n' "$m" """,
    '$diff 2>/dev/null',
    r"""printf '\n%s:exit:%s\n' "$m" "$?" """,
  ]);
}

/// Builds the read-only command that prints numstat for each untracked path
/// against `/dev/null`, or null when [paths] is empty.
///
/// Reads at most [kGitUntrackedCountLimit] paths and stops adding paths once
/// the quoted list reaches [kGitUntrackedCountMaxCommandChars].
({String command, String marker})? buildGitUntrackedCountsCommand({
  required String repositoryRoot,
  required List<String> paths,
  required String marker,
}) {
  final quoted = <String>[];
  var length = 0;
  for (final path in paths) {
    if (quoted.length >= kGitUntrackedCountLimit) {
      break;
    }
    // Directories (nested repositories) have no line count.
    if (path.endsWith('/')) {
      continue;
    }
    final argument = shellEscapePosix(path);
    if (length + argument.length + 1 > kGitUntrackedCountMaxCommandChars) {
      break;
    }
    quoted.add(argument);
    length += argument.length + 1;
  }
  if (quoted.isEmpty) {
    return null;
  }
  return (
    command: _wrapGitScript(marker, [
      'cd ${gitShellPathArgument(repositoryRoot)} 2>/dev/null || exit 0',
      r"""printf '%s:counts\n' "$m" """,
      'for f in ${quoted.join(' ')}; do',
      '  $_gitDiff --no-index --numstat -z -- /dev/null "\$f" 2>/dev/null',
      'done',
      r"""printf '\n%s:end\n' "$m" """,
    ]),
    marker: marker,
  );
}

/// Splits [output] into `<marker>:<name>` sections. A section's payload runs
/// to the next marker, minus the newline that introduces it.
Map<String, String> _gitSections(String output, String marker) {
  final sections = <String, String>{};
  final parts = output.split('$marker:');
  for (final part in parts.skip(1)) {
    final newline = part.indexOf('\n');
    final name = newline < 0 ? part : part.substring(0, newline);
    var payload = newline < 0 ? '' : part.substring(newline + 1);
    if (payload.endsWith('\n')) {
      payload = payload.substring(0, payload.length - 1);
    }
    sections.putIfAbsent(name.trim(), () => payload);
  }
  return sections;
}

int? _sectionExitCode(Map<String, String> sections, String prefix) {
  for (final name in sections.keys) {
    if (name.startsWith('$prefix:')) {
      return int.tryParse(name.substring(prefix.length + 1));
    }
  }
  return null;
}

/// Parses the output of [buildGitWorkingTreeStatusCommand].
GitWorkingTreeSnapshot parseGitWorkingTreeOutput(
  String output, {
  required String marker,
  required bool outputTruncated,
  required DateTime refreshedAt,
  int maxEntries = kGitStatusMaxEntries,
}) {
  final sections = _gitSections(output, marker);
  GitWorkingTreeSnapshot early(GitWorkingTreeState state) =>
      GitWorkingTreeSnapshot(state: state, refreshedAt: refreshedAt);
  if (sections.containsKey('no-git')) {
    return early(GitWorkingTreeState.gitUnavailable);
  }
  if (sections.containsKey('no-dir')) {
    return early(GitWorkingTreeState.missingDirectory);
  }
  if (sections.containsKey('unsafe')) {
    return early(GitWorkingTreeState.unsafeRepository);
  }
  if (sections.containsKey('not-repo')) {
    return early(GitWorkingTreeState.notRepository);
  }
  final status = sections['status'];
  if (status == null) {
    return early(GitWorkingTreeState.failed);
  }
  final exitCode = _sectionExitCode(sections, 'status-exit');
  if (exitCode != null && exitCode != 0) {
    return GitWorkingTreeSnapshot(
      state: GitWorkingTreeState.failed,
      refreshedAt: refreshedAt,
      repositoryRoot: sections['root'],
      exitCode: exitCode,
    );
  }
  final statusFinished = exitCode != null;
  final parsed = parseGitStatusPorcelainV2Z(
    status,
    // A cut-off read ends mid-entry; drop the partial tail.
    complete: statusFinished,
    maxEntries: maxEntries,
  );
  final unstaged = parseGitNumstatZ(sections['unstaged'] ?? '');
  final staged = parseGitNumstatZ(sections['staged'] ?? '');
  final files = [
    for (final file in parsed.files)
      file.withCounts(switch (file.group) {
        GitChangeGroup.staged => staged[file.path],
        GitChangeGroup.unstaged ||
        GitChangeGroup.conflicted => unstaged[file.path],
        GitChangeGroup.untracked => null,
      }),
  ];
  return GitWorkingTreeSnapshot(
    state: GitWorkingTreeState.ready,
    refreshedAt: refreshedAt,
    files: files,
    repositoryRoot: sections['root'],
    branch: parsed.branch,
    detached: parsed.detached,
    truncated: outputTruncated || !statusFinished || parsed.truncated,
  );
}

/// Parses `git diff --numstat -z` output into counts keyed by path (the new
/// path for renames). A later entry for the same path wins, which for an
/// unmerged path is its working-tree side.
Map<String, GitLineCounts> parseGitNumstatZ(String payload) {
  final counts = <String, GitLineCounts>{};
  final tokens = payload.split('\u0000');
  var index = 0;
  while (index < tokens.length) {
    final token = tokens[index++];
    final firstTab = token.indexOf('\t');
    final secondTab = firstTab < 0 ? -1 : token.indexOf('\t', firstTab + 1);
    if (secondTab < 0) {
      continue;
    }
    final added = token.substring(0, firstTab);
    final removed = token.substring(firstTab + 1, secondTab);
    var path = token.substring(secondTab + 1);
    if (path.isEmpty) {
      // Rename or copy: the old and new paths follow as their own fields.
      if (index + 1 >= tokens.length) {
        break;
      }
      index++;
      path = tokens[index++];
    }
    if (path.isEmpty) {
      continue;
    }
    if (added == '-' && removed == '-') {
      counts[path] = const GitLineCounts.binary();
      continue;
    }
    final addedCount = int.tryParse(added);
    final removedCount = int.tryParse(removed);
    if (addedCount == null || removedCount == null) {
      continue;
    }
    counts[path] = GitLineCounts(added: addedCount, removed: removedCount);
  }
  return counts;
}

/// Parses `git status --porcelain=v2 -z --branch` output.
///
/// When [complete] is false the payload was cut off, so the final field is
/// treated as partial and dropped.
({List<GitChangedFile> files, String? branch, bool detached, bool truncated})
parseGitStatusPorcelainV2Z(
  String payload, {
  bool complete = true,
  int maxEntries = kGitStatusMaxEntries,
}) {
  final tokens = payload.split('\u0000');
  // A complete payload ends with a NUL, leaving one empty trailing field; a
  // cut-off one ends mid-field. Either way the last field is not an entry.
  if (tokens.isNotEmpty) {
    tokens.removeLast();
  }
  final files = <GitChangedFile>[];
  String? branch;
  var detached = false;
  var truncated = !complete;
  var index = 0;
  while (index < tokens.length) {
    final token = tokens[index++];
    if (token.startsWith('# ')) {
      if (token.startsWith('# branch.head ')) {
        final head = token.substring('# branch.head '.length);
        if (head == '(detached)') {
          detached = true;
        } else {
          branch = head;
        }
      }
      continue;
    }
    if (files.length >= maxEntries) {
      truncated = true;
      break;
    }
    if (token.startsWith('? ')) {
      files.add(
        GitChangedFile(
          path: token.substring(2),
          group: GitChangeGroup.untracked,
          kind: GitChangeKind.untracked,
        ),
      );
      continue;
    }
    if (token.startsWith('1 ')) {
      final fields = _splitStatusFields(token, 8);
      if (fields == null) {
        continue;
      }
      _addTrackedEntries(
        files,
        code: fields.code,
        path: fields.path,
        submodule: fields.submodule,
      );
      continue;
    }
    if (token.startsWith('2 ')) {
      final fields = _splitStatusFields(token, 9);
      if (fields == null) {
        continue;
      }
      if (index >= tokens.length) {
        truncated = true;
        break;
      }
      final originalPath = tokens[index++];
      _addTrackedEntries(
        files,
        code: fields.code,
        path: fields.path,
        submodule: fields.submodule,
        originalPath: originalPath,
      );
      continue;
    }
    if (token.startsWith('u ')) {
      final fields = _splitStatusFields(token, 10);
      if (fields == null) {
        continue;
      }
      files.add(
        GitChangedFile(
          path: fields.path,
          group: GitChangeGroup.conflicted,
          kind: GitChangeKind.conflicted,
          statusCode: fields.code,
          isSubmodule: fields.submodule,
        ),
      );
    }
    // `!` (ignored) entries are not requested and are skipped if present.
  }
  files.sort(_compareChangedFiles);
  return (
    files: files,
    branch: branch,
    detached: detached,
    truncated: truncated,
  );
}

({String code, bool submodule, String path})? _splitStatusFields(
  String token,
  int fieldsBeforePath,
) {
  var start = 0;
  final fields = <String>[];
  for (var i = 0; i < fieldsBeforePath; i++) {
    final space = token.indexOf(' ', start);
    if (space < 0) {
      return null;
    }
    fields.add(token.substring(start, space));
    start = space + 1;
  }
  final path = token.substring(start);
  if (fields.length < 3 || fields[1].length != 2 || path.isEmpty) {
    return null;
  }
  return (code: fields[1], submodule: fields[2].startsWith('S'), path: path);
}

void _addTrackedEntries(
  List<GitChangedFile> files, {
  required String code,
  required String path,
  required bool submodule,
  String? originalPath,
}) {
  final indexKind = gitChangeKindForStatusLetter(code[0]);
  final worktreeKind = gitChangeKindForStatusLetter(code[1]);
  bool movesPath(GitChangeKind kind) =>
      kind == GitChangeKind.renamed || kind == GitChangeKind.copied;
  if (indexKind != null) {
    files.add(
      GitChangedFile(
        path: path,
        group: GitChangeGroup.staged,
        kind: indexKind,
        originalPath: movesPath(indexKind) ? originalPath : null,
        isSubmodule: submodule,
      ),
    );
  }
  if (worktreeKind != null) {
    files.add(
      GitChangedFile(
        path: path,
        group: GitChangeGroup.unstaged,
        kind: worktreeKind,
        originalPath: movesPath(worktreeKind) ? originalPath : null,
        isSubmodule: submodule,
      ),
    );
  }
}

int _compareChangedFiles(GitChangedFile a, GitChangedFile b) {
  final group = a.group.index.compareTo(b.group.index);
  return group != 0 ? group : a.path.compareTo(b.path);
}

final _hunkHeaderPattern = RegExp(
  r'^@@+ -(\d+)(?:,(\d+))?(?: -\d+(?:,\d+)?)* \+(\d+)(?:,(\d+))? @@+',
);

/// Parses one file's unified diff into header lines and hunks.
///
/// [truncated] marks output that stopped at the size cap.
GitFileDiff parseGitUnifiedDiff(String text, {required bool truncated}) {
  final headerLines = <String>[];
  final hunks = <GitDiffHunk>[];
  var binary = false;
  String? header;
  var body = <String>[];
  RegExpMatch? match;

  void flush() {
    final current = header;
    if (current == null) {
      return;
    }
    hunks.add(
      GitDiffHunk(
        header: current,
        lines: body,
        oldStart: int.tryParse(match?.group(1) ?? ''),
        oldCount: _hunkCount(match?.group(2)),
        newStart: int.tryParse(match?.group(3) ?? ''),
        newCount: _hunkCount(match?.group(4)),
      ),
    );
    header = null;
    body = <String>[];
  }

  final lines = text.isEmpty ? const <String>[] : text.split('\n');
  for (final line in lines) {
    if (line.startsWith('@@')) {
      flush();
      header = line;
      match = _hunkHeaderPattern.firstMatch(line);
      continue;
    }
    if (header == null) {
      if (line.startsWith('Binary files ') ||
          line.startsWith('GIT binary patch')) {
        binary = true;
      }
      if (line.isNotEmpty) {
        headerLines.add(line);
      }
      continue;
    }
    if (line.startsWith('diff --git ') || line.startsWith('diff --cc ')) {
      // A second file section (not expected for one path): keep it as
      // header text rather than folding it into the previous hunk.
      flush();
      headerLines.add(line);
      continue;
    }
    body.add(line);
  }
  // Drop the empty field left by a trailing newline.
  if (body.isNotEmpty && body.last.isEmpty) {
    body.removeLast();
  }
  flush();
  return GitFileDiff(
    headerLines: headerLines,
    hunks: hunks,
    binary: binary,
    truncated: truncated,
  );
}

int? _hunkCount(String? value) => value == null ? 1 : int.tryParse(value);

/// Number of unchanged new-file lines between [previous] and [next], or
/// before [next] when [previous] is null. Null when the headers carry no
/// line numbers.
int? gitUnchangedLinesBetween(GitDiffHunk? previous, GitDiffHunk next) {
  final nextStart = next.newStart;
  if (nextStart == null) {
    return null;
  }
  if (previous == null) {
    return math.max(0, nextStart - 1);
  }
  final previousStart = previous.newStart;
  final previousCount = previous.newCount;
  if (previousStart == null || previousCount == null) {
    return null;
  }
  return math.max(0, nextStart - (previousStart + previousCount));
}

/// Short label for a change group, as used in prompts and headers.
String gitChangeGroupLabel(GitChangeGroup group) => switch (group) {
  GitChangeGroup.conflicted => 'conflicts',
  GitChangeGroup.staged => 'staged',
  GitChangeGroup.unstaged => 'unstaged',
  GitChangeGroup.untracked => 'untracked',
};

/// Builds a prompt that quotes [hunk] of [file] for the agent, leaving the
/// caret after it for the user's question.
///
/// Long hunks are cut to [kGitHunkPromptMaxLines] lines and
/// [kGitHunkPromptMaxChars] characters, with a note saying so.
String buildGitHunkPrompt({
  required GitChangedFile file,
  required GitDiffHunk hunk,
}) {
  final quoted = <String>[hunk.header];
  var chars = hunk.header.length;
  var omitted = 0;
  for (var i = 0; i < hunk.lines.length; i++) {
    final line = hunk.lines[i];
    if (quoted.length > kGitHunkPromptMaxLines ||
        chars + line.length + 1 > kGitHunkPromptMaxChars) {
      omitted = hunk.lines.length - i;
      break;
    }
    quoted.add(line);
    chars += line.length + 1;
  }
  var longestRun = 0;
  for (final line in quoted) {
    final run = RegExp('`+')
        .allMatches(line)
        .fold<int>(
          0,
          (longest, match) => math.max(longest, match.end - match.start),
        );
    longestRun = math.max(longestRun, run);
  }
  final fence = '`' * math.max(3, longestRun + 1);
  final where = switch (file.group) {
    GitChangeGroup.staged => 'a staged change',
    GitChangeGroup.unstaged => 'an unstaged change',
    GitChangeGroup.untracked => 'an untracked file',
    GitChangeGroup.conflicted => 'a merge conflict',
  };
  final buffer = StringBuffer()
    ..writeln('About this hunk in ${file.path} ($where in the working tree):')
    ..writeln()
    ..writeln('${fence}diff')
    ..writeln(quoted.join('\n'))
    ..writeln(fence);
  if (omitted > 0) {
    buffer.writeln('($omitted more lines of this hunk not shown)');
  }
  buffer.writeln();
  return buffer.toString();
}
