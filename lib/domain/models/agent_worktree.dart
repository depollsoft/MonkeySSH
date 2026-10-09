/// Git worktree options for coding-agent launch presets.
///
/// A preset can start its agent in a fresh git worktree on a new branch. The
/// app renders the branch name and worktree location from templates, validates
/// them locally, and then lets `git` validate them again on the host before it
/// creates anything. Paths, branch names and refs are user content: callers
/// must never log them.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

/// Branch template used when a preset does not set one.
const defaultAgentWorktreeBranchTemplate = 'agent/{tool}-{date}-{id}';

/// Worktree path template used when a preset does not set one.
///
/// `{repo}` is the repository's top-level directory on the host, so the
/// default keeps worktrees beside the repository rather than inside it.
const defaultAgentWorktreePathTemplate = '{repo}.worktrees/{name}';

/// Base ref used when a preset does not set one.
const defaultAgentWorktreeBaseRef = 'HEAD';

/// Placeholder for the repository's top-level directory in path templates.
const agentWorktreeRepositoryPlaceholder = '{repo}';

const _maxBranchLength = 200;
const _maxRefLength = 200;
const _maxPathLength = 1024;
const _idAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
const _idLength = 6;

final _placeholderPattern = RegExp(r'\{([A-Za-z]*)\}');
final _branchForbiddenPattern = RegExp(r'[\x00-\x20\x7f~^:?*\[\\]');
final _refForbiddenPattern = RegExp(r'[\x00-\x20\x7f]');
final _pathControlPattern = RegExp(r'[\x00-\x1f\x7f]');

const _branchPlaceholders = {'tool', 'date', 'time', 'id'};
const _pathPlaceholders = {'tool', 'date', 'time', 'id', 'name', 'branch'};

/// Git worktree settings saved on an agent launch preset.
///
/// Every field is optional: a null value falls back to the preset's working
/// directory or to the defaults above, so a preset only stores what the user
/// changed.
@immutable
final class AgentWorktreeLaunchOptions {
  /// Creates worktree launch options.
  const AgentWorktreeLaunchOptions({
    this.repositoryPath,
    this.baseRef,
    this.branchTemplate,
    this.pathTemplate,
  });

  /// Decodes options from JSON, or returns null when [json] is not a map.
  static AgentWorktreeLaunchOptions? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    return AgentWorktreeLaunchOptions(
      repositoryPath: _readTrimmed(json['repositoryPath']),
      baseRef: _readTrimmed(json['baseRef']),
      branchTemplate: _readTrimmed(json['branchTemplate']),
      pathTemplate: _readTrimmed(json['pathTemplate']),
    );
  }

  /// Repository to branch from; null uses the preset's working directory.
  final String? repositoryPath;

  /// Commit-ish the new branch starts from; null means `HEAD`.
  final String? baseRef;

  /// Branch name template; null uses [defaultAgentWorktreeBranchTemplate].
  final String? branchTemplate;

  /// Worktree path template; null uses [defaultAgentWorktreePathTemplate].
  final String? pathTemplate;

  /// The ref the new branch starts from.
  String get effectiveBaseRef =>
      _nonEmpty(baseRef) ?? defaultAgentWorktreeBaseRef;

  /// The branch template used for a launch.
  String get effectiveBranchTemplate =>
      _nonEmpty(branchTemplate) ?? defaultAgentWorktreeBranchTemplate;

  /// The path template used for a launch.
  String get effectivePathTemplate =>
      _nonEmpty(pathTemplate) ?? defaultAgentWorktreePathTemplate;

  /// The repository path for a preset whose working directory is
  /// [workingDirectory], or null when neither is set.
  String? resolveRepositoryPath(String? workingDirectory) =>
      _nonEmpty(repositoryPath) ?? _nonEmpty(workingDirectory);

  /// Returns the first problem with these options, or null when they can be
  /// used for a launch from [workingDirectory].
  String? validate({String? workingDirectory}) {
    final repository = resolveRepositoryPath(workingDirectory);
    if (repository == null) {
      return 'Set a repository or a working directory for the worktree.';
    }
    final repositoryError = validateAgentWorktreeRemotePath(
      repository,
      label: 'Repository',
    );
    if (repositoryError != null) {
      return repositoryError;
    }
    final baseError = validateAgentWorktreeBaseRef(effectiveBaseRef);
    if (baseError != null) {
      return baseError;
    }
    try {
      renderAgentWorktreeTarget(this, AgentWorktreeTemplateValues.sample);
    } on FormatException catch (error) {
      return error.message;
    }
    return null;
  }

  /// Encodes the options, omitting defaults.
  Map<String, dynamic> toJson() => {
    'repositoryPath': ?_nonEmpty(repositoryPath),
    'baseRef': ?_nonEmpty(baseRef),
    'branchTemplate': ?_nonEmpty(branchTemplate),
    'pathTemplate': ?_nonEmpty(pathTemplate),
  };

  @override
  bool operator ==(Object other) =>
      other is AgentWorktreeLaunchOptions &&
      _nonEmpty(other.repositoryPath) == _nonEmpty(repositoryPath) &&
      _nonEmpty(other.baseRef) == _nonEmpty(baseRef) &&
      _nonEmpty(other.branchTemplate) == _nonEmpty(branchTemplate) &&
      _nonEmpty(other.pathTemplate) == _nonEmpty(pathTemplate);

  @override
  int get hashCode => Object.hash(
    _nonEmpty(repositoryPath),
    _nonEmpty(baseRef),
    _nonEmpty(branchTemplate),
    _nonEmpty(pathTemplate),
  );
}

/// Values substituted into worktree templates for one launch.
@immutable
final class AgentWorktreeTemplateValues {
  /// Creates template values.
  const AgentWorktreeTemplateValues({
    required this.tool,
    required this.date,
    required this.time,
    required this.id,
  });

  /// Builds the values for a launch of [tool] at [now].
  factory AgentWorktreeTemplateValues.forLaunch({
    required String tool,
    DateTime? now,
    Random? random,
  }) {
    final timestamp = now ?? DateTime.now();
    final generator = random ?? Random.secure();
    String two(int value) => value.toString().padLeft(2, '0');
    return AgentWorktreeTemplateValues(
      tool: tool,
      date:
          '${timestamp.year.toString().padLeft(4, '0')}'
          '${two(timestamp.month)}${two(timestamp.day)}',
      time: '${two(timestamp.hour)}${two(timestamp.minute)}',
      id: String.fromCharCodes(
        List.generate(
          _idLength,
          (_) => _idAlphabet.codeUnitAt(generator.nextInt(_idAlphabet.length)),
        ),
      ),
    );
  }

  /// Representative values used to validate templates while editing.
  static const sample = AgentWorktreeTemplateValues(
    tool: 'claude',
    date: '20261009',
    time: '1430',
    id: 'k3x9q2',
  );

  /// The agent's command name, such as `claude` or `codex`.
  final String tool;

  /// These values for another [tool].
  AgentWorktreeTemplateValues withTool(String tool) =>
      AgentWorktreeTemplateValues(tool: tool, date: date, time: time, id: id);

  /// Launch date as `yyyymmdd`.
  final String date;

  /// Launch time as `hhmm`.
  final String time;

  /// Short random id that keeps names from colliding.
  final String id;
}

/// Branch name and location rendered for one worktree launch.
@immutable
final class AgentWorktreeTarget {
  /// Creates a rendered target.
  const AgentWorktreeTarget({
    required this.branch,
    required this.path,
    required this.pathIsRepositoryRelative,
  });

  /// New branch name.
  final String branch;

  /// Worktree location.
  ///
  /// When [pathIsRepositoryRelative] is true this is the text that follows
  /// the repository's top-level directory (for example `.worktrees/x`), which
  /// the host appends to the directory it resolves. Otherwise it is an
  /// absolute or `~/`-relative path.
  final String path;

  /// Whether [path] is appended to the repository's top-level directory.
  final bool pathIsRepositoryRelative;

  /// Human-readable location for previews.
  String get displayPath => pathIsRepositoryRelative
      ? '$agentWorktreeRepositoryPlaceholder$path'
      : path;
}

/// Renders the branch and worktree path for [options] with [values].
///
/// Throws a [FormatException] with a user-facing message when a template is
/// invalid or renders an unusable branch or path.
AgentWorktreeTarget renderAgentWorktreeTarget(
  AgentWorktreeLaunchOptions options,
  AgentWorktreeTemplateValues values,
) {
  final branch = _renderTemplate(
    options.effectiveBranchTemplate,
    allowed: _branchPlaceholders,
    values: {
      'tool': values.tool,
      'date': values.date,
      'time': values.time,
      'id': values.id,
    },
    label: 'Branch template',
  );
  final branchError = validateAgentWorktreeBranchName(branch);
  if (branchError != null) {
    throw FormatException(branchError);
  }

  var pathTemplate = options.effectivePathTemplate;
  final repositoryRelative = pathTemplate.startsWith(
    agentWorktreeRepositoryPlaceholder,
  );
  if (repositoryRelative) {
    pathTemplate = pathTemplate.substring(
      agentWorktreeRepositoryPlaceholder.length,
    );
  }
  if (pathTemplate.contains(agentWorktreeRepositoryPlaceholder)) {
    throw const FormatException(
      'Worktree path template can use {repo} only at the start.',
    );
  }
  final path = _renderTemplate(
    pathTemplate,
    allowed: _pathPlaceholders,
    values: {
      'tool': values.tool,
      'date': values.date,
      'time': values.time,
      'id': values.id,
      'branch': branch,
      'name': branch.replaceAll('/', '-'),
    },
    label: 'Worktree path template',
  );
  if (repositoryRelative) {
    if (path.isEmpty || path == '/') {
      throw const FormatException(
        'Worktree path template must add a folder name after {repo}.',
      );
    }
    if (_pathControlPattern.hasMatch(path) || path.length > _maxPathLength) {
      throw const FormatException(
        'Worktree path template renders an invalid path.',
      );
    }
  } else {
    final pathError = validateAgentWorktreeRemotePath(
      path,
      label: 'Worktree path',
    );
    if (pathError != null) {
      throw FormatException(pathError);
    }
  }
  return AgentWorktreeTarget(
    branch: branch,
    path: path,
    pathIsRepositoryRelative: repositoryRelative,
  );
}

String _renderTemplate(
  String template, {
  required Set<String> allowed,
  required Map<String, String> values,
  required String label,
}) {
  final unknown = _placeholderPattern
      .allMatches(template)
      .map((match) => match.group(1)!)
      .where((name) => !allowed.contains(name))
      .toSet();
  if (unknown.isNotEmpty) {
    throw FormatException(
      '$label has an unknown placeholder: {${unknown.first}}. '
      'Use ${allowed.map((name) => '{$name}').join(', ')}.',
    );
  }
  final rendered = template.replaceAllMapped(
    _placeholderPattern,
    (match) => values[match.group(1)!]!,
  );
  if (rendered.contains('{') || rendered.contains('}')) {
    throw FormatException('$label has an unclosed placeholder.');
  }
  return rendered;
}

/// Returns why [name] cannot be a new git branch, or null when it can.
///
/// Mirrors `git check-ref-format --branch`, which the host runs again before
/// creating the branch, plus a length cap.
String? validateAgentWorktreeBranchName(String name) {
  if (name.isEmpty) {
    return 'Branch name is empty.';
  }
  if (name.length > _maxBranchLength) {
    return 'Branch name is longer than $_maxBranchLength characters.';
  }
  if (name.startsWith('-')) {
    return 'Branch name cannot start with "-".';
  }
  if (name == '@') {
    return 'Branch name cannot be "@".';
  }
  if (_branchForbiddenPattern.hasMatch(name)) {
    return r'Branch name cannot contain spaces or any of ~ ^ : ? * [ \.';
  }
  if (name.contains('..') || name.contains('@{') || name.contains('//')) {
    return 'Branch name cannot contain "..", "@{" or "//".';
  }
  if (name.startsWith('/') || name.endsWith('/') || name.endsWith('.')) {
    return 'Branch name cannot start or end with "/" or end with ".".';
  }
  for (final component in name.split('/')) {
    if (component.startsWith('.') || component.endsWith('.lock')) {
      return 'Branch name parts cannot start with "." or end with ".lock".';
    }
  }
  return null;
}

/// Returns why [ref] cannot be used as a worktree base, or null when it can.
///
/// The host resolves the ref with `git rev-parse --verify`; this only rejects
/// text that could be mistaken for an option or split into several words.
String? validateAgentWorktreeBaseRef(String ref) {
  if (ref.isEmpty) {
    return 'Base ref is empty.';
  }
  if (ref.length > _maxRefLength) {
    return 'Base ref is longer than $_maxRefLength characters.';
  }
  if (ref.startsWith('-')) {
    return 'Base ref cannot start with "-".';
  }
  if (_refForbiddenPattern.hasMatch(ref)) {
    return 'Base ref cannot contain spaces or control characters.';
  }
  return null;
}

/// Returns why [path] cannot be used as a remote repository or worktree path,
/// or null when it can.
///
/// Paths must be absolute or start with `~/` so they do not depend on the
/// directory an SSH command happens to start in.
String? validateAgentWorktreeRemotePath(String path, {required String label}) {
  if (path.isEmpty) {
    return '$label is empty.';
  }
  if (path.length > _maxPathLength) {
    return '$label is longer than $_maxPathLength characters.';
  }
  if (_pathControlPattern.hasMatch(path)) {
    return '$label cannot contain line breaks or control characters.';
  }
  if (!(path.startsWith('/') || path == '~' || path.startsWith('~/'))) {
    return '$label must be absolute or start with ~/.';
  }
  return null;
}

/// A worktree MonkeySSH created for an agent launch.
///
/// Records let the app offer to remove the worktree when its window closes.
/// They never cause anything to be created again: restoring a window after a
/// MonkeyMux update reuses the directory the window recorded.
@immutable
final class AgentWorktreeRecord {
  /// Creates a worktree record.
  const AgentWorktreeRecord({
    required this.hostId,
    required this.repository,
    required this.path,
    required this.branch,
    required this.baseCommit,
    required this.createdAt,
    String? startDirectory,
    this.alternatePath,
  }) : startDirectory = startDirectory ?? path;

  /// Decodes a record stored under [hostId], or returns null when it is
  /// incomplete.
  static AgentWorktreeRecord? tryFromJson(Object? json, {required int hostId}) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final repository = _readTrimmed(json['repository']);
    final path = _readTrimmed(json['path']);
    final branch = _readTrimmed(json['branch']);
    final baseCommit = _readTrimmed(json['baseCommit']);
    final createdAt = DateTime.tryParse(_readTrimmed(json['createdAt']) ?? '');
    if (repository == null ||
        path == null ||
        branch == null ||
        baseCommit == null ||
        createdAt == null) {
      return null;
    }
    return AgentWorktreeRecord(
      hostId: hostId,
      repository: repository,
      path: path,
      branch: branch,
      baseCommit: baseCommit,
      createdAt: createdAt,
      startDirectory: _readTrimmed(json['startDirectory']),
      alternatePath: _readTrimmed(json['alternatePath']),
    );
  }

  /// Saved host the worktree belongs to.
  final int hostId;

  /// Top-level directory of the repository the worktree was added to.
  final String repository;

  /// Worktree root as the host resolved it, without symlinks.
  final String path;

  /// The same root as spelled through symlinks, when that differs.
  final String? alternatePath;

  /// Branch created for the worktree.
  final String branch;

  /// Commit the branch was created at, used to tell whether it has new work.
  final String baseCommit;

  /// When the worktree was created.
  final DateTime createdAt;

  /// Directory the agent started in: [path] or the subdirectory that matches
  /// the preset's working directory.
  final String startDirectory;

  /// Whether [directory] is the worktree root or inside it.
  bool contains(String? directory) {
    final trimmed = directory?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return false;
    }
    final normalized = _withoutTrailingSlash(trimmed);
    bool within(String? root) {
      if (root == null) return false;
      final base = _withoutTrailingSlash(root);
      return normalized == base || normalized.startsWith('$base/');
    }

    return within(path) || within(alternatePath);
  }

  /// Encodes the record; the host id is the key it is stored under.
  Map<String, dynamic> toJson() => {
    'repository': repository,
    'path': path,
    'branch': branch,
    'baseCommit': baseCommit,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (startDirectory != path) 'startDirectory': startDirectory,
    'alternatePath': ?alternatePath,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentWorktreeRecord &&
      other.hostId == hostId &&
      other.path == path &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(hostId, path, branch);
}

String _withoutTrailingSlash(String value) =>
    value.length > 1 && value.endsWith('/')
    ? value.substring(0, value.length - 1)
    : value;

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String? _readTrimmed(Object? value) =>
    value is String ? _nonEmpty(value) : null;
