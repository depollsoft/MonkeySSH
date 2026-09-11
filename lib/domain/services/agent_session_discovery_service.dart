import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_protocol.dart';
import '../models/agent_launch_preset.dart';
import '../models/tmux_state.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_ssh_exec_transport.dart';
import 'command_output_marker_reader.dart';
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'terminal_connection_backend_service.dart';
import 'windows_remote_powershell.dart';

const _genericSessionSummaries = <String>{
  'untitled',
  'unnamed',
  'untitled session',
  'new session',
  'empty session',
  'session',
};

const _profileSourcingPrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; '
    '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } >/dev/null 2>&1; '
    r'case "${SHELL##*/}" in '
    'zsh) { . ~/.zshrc; } >/dev/null 2>&1;; '
    'bash) { . ~/.bashrc; } >/dev/null 2>&1;; '
    'esac; '
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';
const _remoteFileSnapshotBatchSize = 40;
const _grokSessionMetadataMaxBytes = 64 * 1024;
const _openCodeStorageSessionMetadataMaxBytes = 64 * 1024;
const _piSessionLabelExtractorScript = r'''
const fs = require("fs");
const readline = require("readline");

function normalizedText(value) {
  return typeof value === "string"
    ? value.replace(/\s+/g, " ").trim()
    : "";
}

function messageText(message) {
  if (!message || message.role !== "user") return "";
  if (typeof message.content === "string") {
    return normalizedText(message.content);
  }
  if (!Array.isArray(message.content)) return "";
  return normalizedText(
    message.content
      .filter((part) => part && part.type === "text")
      .map((part) => typeof part.text === "string" ? part.text : "")
      .join(" "),
  );
}

async function emitLabel(path) {
  let firstUserMessage = "";
  let sessionName;
  try {
    const lines = readline.createInterface({
      input: fs.createReadStream(path, { encoding: "utf8" }),
      crlfDelay: Infinity,
    });
    for await (const line of lines) {
      let entry;
      try {
        entry = JSON.parse(line);
      } catch (_) {
        continue;
      }
      if (entry && entry.type === "session_info") {
        sessionName = normalizedText(entry.name);
      } else if (
        !firstUserMessage &&
        entry &&
        entry.type === "message"
      ) {
        firstUserMessage = messageText(entry.message);
      }
    }
    const label = normalizedText(sessionName) || firstUserMessage;
    if (!label) return;
    const boundedLabel = label.slice(0, 512);
    process.stdout.write(
      path + "\x1f" + Buffer.from(boundedLabel).toString("base64") + "\n",
    );
  } catch (_) {
    // One unreadable session must not hide metadata from the others.
  }
}

(async () => {
  for (const path of process.argv.slice(2)) {
    await emitLabel(path);
  }
})();
''';
const _sessionDiscoveryCacheFreshTtl = Duration(seconds: 15);
const _sessionDiscoveryCacheRetentionTtl = Duration(minutes: 2);
const _relatedWorkingDirectoriesCacheTtl = Duration(minutes: 1);
const _acpResponseTimeout = Duration(seconds: 2);
const _execOutputTimeout = Duration(seconds: 10);
const _execDoneMarker = '__flutty_agent_discovery_exec_done__';
final RegExp _execDoneMarkerLinePattern = RegExp(
  '(?:^|\\n)${RegExp.escape(_execDoneMarker)}:([0-9]+)\\n',
);
const _windowsUserProfileRootEnvironmentVariables = <String>['USERPROFILE'];
const _windowsUserDataRootEnvironmentVariables = <String>[
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
];

/// Filters noisy discovered sessions and fills in a better display summary
/// when the tool only exposes a working directory.
@visibleForTesting
ToolSessionInfo? normalizeDiscoveredSessionInfo(
  ToolSessionInfo info, {
  String? activeWorkingDirectory,
}) {
  final normalizedSummary = _normalizeDiscoveredSessionSummary(
    info,
    activeWorkingDirectory: activeWorkingDirectory,
  );
  if (normalizedSummary == null) return null;
  return ToolSessionInfo(
    toolName: info.toolName,
    sessionId: info.sessionId,
    workingDirectory: info.workingDirectory,
    originWorkingDirectory: info.originWorkingDirectory,
    lastActive: info.lastActive,
    summary: normalizedSummary,
  );
}

/// Orders sessions from most to least recently updated, leaving untimestamped
/// items at the end.
@visibleForTesting
int compareDiscoveredSessionsByRecency(ToolSessionInfo a, ToolSessionInfo b) {
  final aTime = a.lastActive;
  final bTime = b.lastActive;
  if (aTime != null && bTime != null) {
    final compare = bTime.compareTo(aTime);
    if (compare != 0) return compare;
  } else if (aTime != null) {
    return -1;
  } else if (bTime != null) {
    return 1;
  }

  final toolCompare = a.toolName.compareTo(b.toolName);
  if (toolCompare != 0) return toolCompare;
  return (a.summary ?? '').compareTo(b.summary ?? '');
}

/// Known discovery provider labels derived from [AgentLaunchTool.uiDisplayOrder].
final List<String> _knownDiscoveredSessionTools = AgentLaunchTool.uiDisplayOrder
    .map((tool) => tool.discoveredSessionToolName)
    .whereType<String>()
    .toList(growable: false);

/// Orders discovered-session providers for UI rendering in a stable list.
///
/// The known provider rows stay visible in a fixed order so incremental
/// streaming updates do not insert or remove rows while the menu is open. Any
/// unexpected provider names are appended alphabetically after the known set.
List<String> orderedDiscoveredSessionTools(
  Map<String, List<ToolSessionInfo>> grouped,
  Iterable<String> attemptedTools, {
  String? preferredToolName,
}) {
  final knownTools = _knownDiscoveredSessionTools.toSet();
  final ordered = List<String>.of(_knownDiscoveredSessionTools);
  final extraTools = <String>{
    ...grouped.keys,
    ...attemptedTools,
  }.where((tool) => !knownTools.contains(tool)).toList()..sort();
  if (preferredToolName case final preferred? when preferred.isNotEmpty) {
    if (ordered.remove(preferred)) {
      ordered.insert(0, preferred);
    } else if (extraTools.remove(preferred)) {
      ordered.insert(0, preferred);
    }
  }
  ordered.addAll(extraTools);
  return ordered;
}

/// Discovered session results plus any tool histories that could not be read.
class DiscoveredSessionsResult {
  /// Creates a new [DiscoveredSessionsResult].
  factory DiscoveredSessionsResult({
    required Iterable<ToolSessionInfo> sessions,
    Iterable<String> failedTools = const <String>[],
    Iterable<String> attemptedTools = const <String>[],
  }) {
    final sessionList = List<ToolSessionInfo>.unmodifiable(sessions);
    return DiscoveredSessionsResult._(
      sessions: sessionList,
      sessionTools: sessionList.map((session) => session.toolName).toSet(),
      failedTools: Set<String>.unmodifiable(failedTools),
      attemptedTools: Set<String>.unmodifiable(attemptedTools),
    );
  }

  DiscoveredSessionsResult._({
    required this.sessions,
    required Set<String> sessionTools,
    required this.failedTools,
    required this.attemptedTools,
  }) : sessionTools = Set<String>.unmodifiable(sessionTools);

  /// The sessions that were discovered successfully.
  final List<ToolSessionInfo> sessions;

  /// Tool names represented by [sessions].
  final Set<String> sessionTools;

  /// Tool names whose session history could not be loaded.
  final Set<String> failedTools;

  /// Tool names that the discovery service attempted to query during this
  /// stream tick, regardless of whether any sessions were ultimately returned.
  ///
  /// The UI uses this to render a placeholder row for tools that completed
  /// without errors but produced no matching sessions, so users can see at a
  /// glance which providers were checked.
  final Set<String> attemptedTools;

  /// Whether any tool histories failed to load.
  bool get hasFailures => failedTools.isNotEmpty;

  /// A human-readable failure message for the UI.
  String? get failureMessage {
    if (failedTools.isEmpty) return null;
    final orderedTools = failedTools.toList()..sort();
    if (orderedTools.length == 1) {
      return 'Could not load ${orderedTools.first} sessions.';
    }
    final lastTool = orderedTools.removeLast();
    return 'Could not load ${orderedTools.join(', ')} and $lastTool sessions.';
  }
}

/// Whether a tool-level discovery issue should be surfaced to the UI.
///
/// Partial parse issues should stay silent when the tool still yielded usable
/// sessions, so users only see a failure banner when a tool's history could not
/// be loaded at all.
@visibleForTesting
bool shouldSurfaceDiscoveryFailure({
  required bool hadError,
  required int loadedSessionCount,
}) => hadError && loadedSessionCount == 0;

/// Builds the SQL predicate used to scope session directories to the active
/// project root or its descendants without relying on `LIKE` wildcards.
String? buildSqlWorkingDirectoryScopeClause(
  Iterable<String> directories, {
  required String columnName,
}) {
  final scopedDirectories = directories
      .map(_trimWorkingDirectory)
      .whereType<String>()
      .toSet()
      .toList(growable: false);
  if (scopedDirectories.isEmpty) {
    return null;
  }

  return scopedDirectories
      .map(
        (directory) => _buildSqlWorkingDirectoryPrefixPredicate(
          directory,
          columnName: columnName,
        ),
      )
      .join(' OR ');
}

String? _normalizeDiscoveredSessionSummary(
  ToolSessionInfo info, {
  String? activeWorkingDirectory,
}) {
  final normalizedSummary = _sanitizeSessionSummary(
    info.summary,
    sessionId: info.sessionId,
    workingDirectory: info.workingDirectory,
  );
  if (normalizedSummary != null) return normalizedSummary;
  return _directorySummaryFallback(
    info.workingDirectory,
    activeWorkingDirectory: activeWorkingDirectory,
  );
}

String? _sanitizeSessionSummary(
  String? value, {
  required String sessionId,
  String? workingDirectory,
}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  var unquoted = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Only remove enclosing pairs; a quote at one edge may belong to the title.
  while (unquoted.length >= 2 &&
      (unquoted[0] == '"' || unquoted[0] == "'" || unquoted[0] == '`') &&
      unquoted.endsWith(unquoted[0])) {
    unquoted = unquoted.substring(1, unquoted.length - 1).trim();
  }
  if (unquoted.isEmpty) return null;

  final lowered = unquoted.toLowerCase();
  if (_genericSessionSummaries.contains(lowered) ||
      lowered == sessionId.toLowerCase() ||
      lowered == _truncateSessionIdValue(sessionId).toLowerCase()) {
    return null;
  }

  final workingDirectorySummary = _directorySummaryFallback(workingDirectory);
  if (workingDirectorySummary != null &&
      lowered == workingDirectorySummary.toLowerCase()) {
    return null;
  }

  final strippedSeparators = unquoted.replaceAll(
    RegExp(r'''[\s\-_./\\[\](){}:;,*"'`~]+'''),
    '',
  );
  if (strippedSeparators.isEmpty) return null;
  return unquoted;
}

String? _directorySummaryFallback(
  String? workingDirectory, {
  String? activeWorkingDirectory,
}) {
  final trimmed = workingDirectory?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (activeWorkingDirectory != null &&
      activeWorkingDirectory.isNotEmpty &&
      AgentSessionDiscoveryService._matchesWorkingDirectory(
        activeWorkingDirectory,
        trimmed,
      )) {
    return null;
  }
  final segment = _pathLastSegment(trimmed);
  if (segment.isEmpty || segment == '.' || segment == '~') return null;
  return segment;
}

String _pathLastSegment(String path) =>
    path
        .split(RegExp(r'[/\\]'))
        .where((segment) => segment.isNotEmpty)
        .lastOrNull ??
    path;

AgentLaunchTool? _agentLaunchToolForSessionToolName(String toolName) {
  final normalizedToolName = toolName.trim();
  for (final tool in AgentLaunchTool.values) {
    if (tool.discoveredSessionToolName == normalizedToolName) {
      return tool;
    }
  }
  return null;
}

String _truncateSessionIdValue(String id) {
  if (id.length <= 12) return id;
  return '${id.substring(0, 8)}…';
}

bool _isLikelyToolStateWorkingDirectory(String directory) =>
    directory == '/tmp' ||
    directory.endsWith('/.copilot') ||
    directory.contains('/.copilot/') ||
    directory.endsWith('/.claude') ||
    directory.contains('/.claude/') ||
    directory.endsWith('/.codex') ||
    directory.contains('/.codex/') ||
    directory.endsWith('/.gemini') ||
    directory.contains('/.gemini/') ||
    directory.endsWith('/.local/share/opencode') ||
    directory.contains('/.local/share/opencode/') ||
    directory.endsWith('/.antigravity') ||
    directory.contains('/.antigravity/') ||
    directory.endsWith('/.antigravitycli') ||
    directory.contains('/.antigravitycli/') ||
    directory.endsWith('/.agy') ||
    directory.contains('/.agy/') ||
    directory.endsWith('/.agycli') ||
    directory.contains('/.agycli/') ||
    directory.startsWith('/tmp/') ||
    directory.startsWith('/private/tmp/') ||
    directory.startsWith('/var/folders/');

/// Chooses the best working directory to scope AI session discovery.
///
/// Tmux panes can temporarily report tool-state or temp directories while the
/// user is still effectively working in a project. Tmux window metadata can
/// also lag behind the active pane's live OSC 7 working directory, especially
/// after changing directories inside an existing tmux window. In those cases,
/// prefer the terminal session's working directory when it is more specific or
/// conflicts with the pane snapshot, or skip scoping entirely instead of
/// hiding project sessions behind a stale or transient tool path.
String? resolveAgentSessionScopeWorkingDirectory({
  String? activeWorkingDirectory,
  Uri? sessionWorkingDirectory,
}) {
  final trimmedActive = _trimWorkingDirectory(activeWorkingDirectory);
  final fallbackWorkingDirectory = _trimWorkingDirectory(
    resolveTerminalWorkingDirectoryPath(sessionWorkingDirectory),
  );
  if (trimmedActive == null) {
    return fallbackWorkingDirectory;
  }
  if (fallbackWorkingDirectory == null) {
    return _isLikelyToolStateWorkingDirectory(trimmedActive)
        ? null
        : trimmedActive;
  }
  if (_isLikelyToolStateWorkingDirectory(trimmedActive)) {
    return fallbackWorkingDirectory;
  }
  if (_isLikelyToolStateWorkingDirectory(fallbackWorkingDirectory)) {
    return trimmedActive;
  }

  final comparableActive = normalizeWorkingDirectoryForComparison(
    trimmedActive,
  );
  final comparableFallback = normalizeWorkingDirectoryForComparison(
    fallbackWorkingDirectory,
  );
  if (!_workingDirectoriesOverlap(comparableActive, comparableFallback)) {
    return fallbackWorkingDirectory;
  }
  if (comparableFallback.startsWith('$comparableActive/')) {
    return fallbackWorkingDirectory;
  }
  return trimmedActive;
}

/// Chooses the best tmux AI-session scope, preferring the live terminal cwd and
/// using tmux metadata only as a last resort when no live cwd is available.
String? resolveTmuxAiSessionScopeWorkingDirectory({
  String? liveTerminalWorkingDirectory,
  String? tmuxWorkingDirectory,
  Uri? sessionWorkingDirectory,
}) {
  final liveScope = resolveAgentSessionScopeWorkingDirectory(
    activeWorkingDirectory: liveTerminalWorkingDirectory,
    sessionWorkingDirectory: sessionWorkingDirectory,
  );
  if (liveScope != null) return liveScope;

  final trimmedTmuxWorkingDirectory = _trimWorkingDirectory(
    tmuxWorkingDirectory,
  );
  if (trimmedTmuxWorkingDirectory == null) return null;
  return resolveAgentSessionScopeWorkingDirectory(
    activeWorkingDirectory: trimmedTmuxWorkingDirectory,
    sessionWorkingDirectory: sessionWorkingDirectory,
  );
}

String _summarizeSessionText(String value, {int maxLength = 80}) {
  final firstMeaningfulLine = value
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => value.trim());
  final collapsed = firstMeaningfulLine.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxLength) return collapsed;
  return '${collapsed.substring(0, maxLength - 3)}...';
}

String? _extractPlanSummary(String raw) {
  for (final line in const LineSplitter().convert(raw)) {
    final cleaned = line.replaceAll(RegExp(r'^#+\s*'), '').trim();
    if (cleaned.isNotEmpty && cleaned.length > 3) {
      return _summarizeSessionText(cleaned);
    }
  }
  return null;
}

int _calculateDiscoveryScanLimit(
  int maxPerTool, {
  int multiplier = 5,
  int minimum = 60,
  int maximum = 180,
}) {
  final scaledLimit = maxPerTool * multiplier;
  if (scaledLimit < minimum) return minimum;
  if (scaledLimit > maximum) return maximum;
  return scaledLimit;
}

Iterable<String> _nonEmptyLines(String output) => output
    .trim()
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty);

int _sessionScanLimit(
  int max, {
  required bool previewOnly,
  int previewMultiplier = 8,
  int previewMinimum = 24,
  int previewMaximum = 40,
  int multiplier = 10,
  int minimum = 60,
  int maximum = 120,
}) => _calculateDiscoveryScanLimit(
  max,
  multiplier: previewOnly ? previewMultiplier : multiplier,
  minimum: previewOnly ? previewMinimum : minimum,
  maximum: previewOnly ? previewMaximum : maximum,
);

int _sessionMetadataReadLimit(int max, {required bool previewOnly}) =>
    previewOnly
    ? _calculateDiscoveryScanLimit(max, multiplier: 4, minimum: 6, maximum: 12)
    : calculateRecentSessionMetadataReadLimit(max);

/// Parses Copilot CLI workspace metadata from `workspace.yaml`.
({String? summary, String? workingDirectory, DateTime? updatedAt})
parseCopilotWorkspaceYamlMetadata(String raw) {
  final lines = const LineSplitter().convert(raw);
  String? summary;
  String? workingDirectory;
  DateTime? updatedAt;
  String? name;
  String? repository;
  String? branch;

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];

    if (workingDirectory == null) {
      final cwdMatch = RegExp(r'^cwd:\s*(.+)\s*$').firstMatch(line);
      if (cwdMatch != null) {
        workingDirectory = cwdMatch.group(1)!.trim();
      }
    }

    if (updatedAt == null) {
      final updatedAtMatch = RegExp(
        r'^updated_at:\s*(.+)\s*$',
      ).firstMatch(line);
      if (updatedAtMatch != null) {
        updatedAt = DateTime.tryParse(updatedAtMatch.group(1)!.trim());
      }
    }

    if (name == null) {
      final nameMatch = RegExp(r'^name:\s*(.+)\s*$').firstMatch(line);
      if (nameMatch != null) {
        name = nameMatch.group(1)!.trim();
      }
    }

    if (repository == null) {
      final repositoryMatch = RegExp(
        r'^repository:\s*(.+)\s*$',
      ).firstMatch(line);
      if (repositoryMatch != null) {
        repository = repositoryMatch.group(1)!.trim();
      }
    }

    if (branch == null) {
      final branchMatch = RegExp(r'^branch:\s*(.+)\s*$').firstMatch(line);
      if (branchMatch != null) {
        branch = branchMatch.group(1)!.trim();
      }
    }

    if (summary != null) continue;
    final summaryMatch = RegExp(r'^summary:\s*(.*)$').firstMatch(line);
    if (summaryMatch == null) continue;

    final inlineValue = summaryMatch.group(1)!.trimRight();
    if (inlineValue.isEmpty) continue;
    if (inlineValue == '|' ||
        inlineValue == '|-' ||
        inlineValue == '>' ||
        inlineValue == '>-') {
      final blockLines = <String>[];
      while (index + 1 < lines.length) {
        final nextLine = lines[index + 1];
        if (!nextLine.startsWith('  ')) break;
        index += 1;
        blockLines.add(nextLine.substring(2));
      }
      final blockValue = blockLines.join('\n').trim();
      if (blockValue.isNotEmpty) {
        summary = _summarizeSessionText(blockValue);
      }
      continue;
    }

    final normalizedInlineValue = inlineValue.trim();
    if (normalizedInlineValue.isNotEmpty) {
      summary = _summarizeSessionText(normalizedInlineValue);
    }
  }

  if (summary == null) {
    final nameSummary = name?.trim();
    final repositorySummary = repository?.trim();
    final branchSummary = branch?.trim();
    if (nameSummary != null && nameSummary.isNotEmpty) {
      summary = _summarizeSessionText(nameSummary);
    } else if (repositorySummary != null &&
        repositorySummary.isNotEmpty &&
        branchSummary != null &&
        branchSummary.isNotEmpty) {
      summary = _summarizeSessionText('$repositorySummary ($branchSummary)');
    } else if (repositorySummary != null && repositorySummary.isNotEmpty) {
      summary = _summarizeSessionText(repositorySummary);
    } else if (branchSummary != null && branchSummary.isNotEmpty) {
      summary = _summarizeSessionText(branchSummary);
    }
  }

  return (
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
  );
}

/// Parses Codex rollout metadata from the head of a rollout JSONL file.
@visibleForTesting
({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool parsedAny,
})
parseCodexRolloutMetadata(String raw) {
  String? sessionId;
  String? summary;
  String? workingDirectory;
  DateTime? updatedAt;
  var parsedAny = false;

  for (final line in const LineSplitter().convert(raw)) {
    final decoded = _tryDecodeJsonObject(line);
    if (decoded == null) continue;
    parsedAny = true;

    final payload = _readMapField(decoded, 'payload');
    sessionId ??=
        _readStringField(payload, 'id') ?? _readStringField(decoded, 'id');
    workingDirectory ??=
        _readStringField(payload, 'cwd') ?? _readStringField(decoded, 'cwd');
    updatedAt ??= _parseDateTimeValue(decoded['timestamp']);

    if (summary != null) continue;
    if (_readStringField(decoded, 'type') != 'event_msg' ||
        _readStringField(payload, 'type') != 'user_message') {
      continue;
    }

    final message = _readStringField(payload, 'message');
    if (message != null && message.trim().isNotEmpty) {
      summary = _summarizeSessionText(message);
    }
  }

  return (
    sessionId: sessionId,
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    parsedAny: parsedAny,
  );
}

/// Parses Claude session metadata from a saved JSONL transcript.
@visibleForTesting
({
  String? customTitle,
  String? agentName,
  String? lastPrompt,
  String? userSummary,
  bool parsedAny,
})
parseClaudeSessionMetadata(String raw) {
  String? customTitle;
  String? agentName;
  String? lastPrompt;
  String? userSummary;
  var parsedAny = false;

  for (final line in const LineSplitter().convert(raw)) {
    final decoded = _tryDecodeJsonObject(line);
    if (decoded == null) continue;
    parsedAny = true;

    customTitle = _readStringField(decoded, 'customTitle') ?? customTitle;
    agentName = _readStringField(decoded, 'agentName') ?? agentName;
    lastPrompt = _readStringField(decoded, 'lastPrompt') ?? lastPrompt;

    if (userSummary != null ||
        _readStringField(decoded, 'type') != 'user' ||
        decoded['isMeta'] == true) {
      continue;
    }

    final message = _readMapField(decoded, 'message');
    userSummary = _extractClaudeUserSummary(
      _readStringField(message, 'content'),
    );
  }

  return (
    customTitle: customTitle,
    agentName: agentName,
    lastPrompt: lastPrompt,
    userSummary: userSummary,
    parsedAny: parsedAny,
  );
}

/// Parses Grok Build session metadata from a saved `summary.json`.
///
/// Grok groups sessions by URL-encoded cwd and stores the authoritative id and
/// cwd again under `info`. Generated/manual titles take precedence over the
/// legacy session summary, matching Grok's own resume picker.
@visibleForTesting
({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool isHidden,
  bool parsedAny,
})
parseGrokSessionMetadata(String raw) {
  final decoded = _tryDecodeJsonObject(raw.trim());
  if (decoded == null) {
    return (
      sessionId: null,
      summary: null,
      workingDirectory: null,
      updatedAt: null,
      isHidden: false,
      parsedAny: false,
    );
  }

  final info = _readMapField(decoded, 'info');
  final generatedTitle = _readStringField(decoded, 'generated_title')?.trim();
  final sessionSummary = _readStringField(decoded, 'session_summary')?.trim();
  final sessionKind = _readStringField(decoded, 'session_kind');
  final hidden = decoded['hidden'];
  final summary = generatedTitle != null && generatedTitle.isNotEmpty
      ? generatedTitle
      : sessionSummary != null && sessionSummary.isNotEmpty
      ? sessionSummary
      : null;

  return (
    sessionId: _readStringField(info, 'id'),
    summary: summary,
    workingDirectory: _readStringField(info, 'cwd'),
    updatedAt:
        _parseDateTimeValue(decoded['last_active_at']) ??
        _parseDateTimeValue(decoded['updated_at']),
    isHidden: hidden is bool
        ? hidden
        : (sessionKind?.startsWith('subagent') ?? false),
    parsedAny: true,
  );
}

/// Parses the authoritative first record from a Pi session.
///
/// A valid Pi session file starts with a `type=session` JSON object containing
/// its id, cwd, and creation timestamp. Identifiable labels are extracted by a
/// separate bounded remote pass that never transfers full transcripts.
@visibleForTesting
({String? sessionId, String? workingDirectory, DateTime? createdAt, bool valid})
parsePiSessionHeader(String raw) {
  final firstLine = const LineSplitter().convert(raw.trimLeft()).firstOrNull;
  final decoded = firstLine == null ? null : _tryDecodeJsonObject(firstLine);
  if (decoded == null || _readStringField(decoded, 'type') != 'session') {
    return (
      sessionId: null,
      workingDirectory: null,
      createdAt: null,
      valid: false,
    );
  }
  final sessionId = _readStringField(decoded, 'id')?.trim();
  final workingDirectory = _readStringField(decoded, 'cwd')?.trim();
  return (
    sessionId: sessionId,
    workingDirectory: workingDirectory,
    createdAt: _parseDateTimeValue(decoded['timestamp']),
    valid:
        sessionId != null &&
        sessionId.isNotEmpty &&
        workingDirectory != null &&
        workingDirectory.isNotEmpty,
  );
}

/// Parses compact Pi label records emitted by the remote metadata extractor.
///
/// Each line is `<session-path><US><base64-label>`. Only an explicit Pi
/// `session_info` name or the first user text message is ever emitted; images,
/// tool results, assistant messages, and full transcripts stay remote.
@visibleForTesting
Map<String, String> parsePiSessionLabelOutput(String output) {
  final labels = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final separator = line.indexOf('\x1f');
    if (separator <= 0 || separator == line.length - 1) continue;
    final path = line.substring(0, separator).trim();
    if (path.isEmpty) continue;
    try {
      final label = utf8
          .decode(base64Decode(line.substring(separator + 1).trim()))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (label.isNotEmpty) labels[path] = _summarizeSessionText(label);
    } on Object {
      // Ignore one malformed record without hiding labels from other sessions.
    }
  }
  return labels;
}

/// Encodes a working directory the way Pi names the bucket it stores that
/// directory's sessions in: the path without its leading separator, with every
/// separator and drive colon replaced by `-`, wrapped in `--`.
@visibleForTesting
String? piEncodedSessionDirectoryName(String? workingDirectory) {
  final trimmed = _trimWorkingDirectory(workingDirectory);
  if (trimmed == null) return null;
  // Pi encodes its resolved cwd, which never carries a trailing separator, so
  // a scope directory that does must shed it or it gains a stray `-`.
  final withoutTrailingSeparator = trimmed.replaceFirst(RegExp(r'[/\\]+$'), '');
  final withoutLeadingSeparator = withoutTrailingSeparator.replaceFirst(
    RegExp(r'^[/\\]'),
    '',
  );
  if (withoutLeadingSeparator.isEmpty) return null;
  final encoded = withoutLeadingSeparator.replaceAll(RegExp(r'[/\\:]'), '-');
  return '--$encoded--';
}

/// Parses `sqlite3`-separated Hermes session rows into session metadata.
///
/// Columns are id, title, cwd, and the epoch-seconds last-activity time,
/// delimited by ASCII Unit Separator so titles may contain any printable text.
@visibleForTesting
List<ToolSessionInfo> parseHermesDbOutput(String output) {
  final sessions = <ToolSessionInfo>[];
  for (final line in output.trim().split('\n')) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('\x1f');
    if (parts.length < 3) continue;

    final id = parts[0].trim();
    if (id.isEmpty) continue;
    final title = parts[1].trim();
    final directory = parts[2].trim();
    DateTime? lastActive;
    if (parts.length >= 4) {
      final epoch = int.tryParse(parts[3].trim());
      if (epoch != null && epoch > 0) {
        lastActive = _dateTimeFromEpochValue(epoch);
      }
    }

    sessions.add(
      ToolSessionInfo(
        toolName: 'Hermes',
        sessionId: id,
        workingDirectory: directory.isNotEmpty ? directory : null,
        lastActive: lastActive,
        summary: title.isNotEmpty ? title : _truncateSessionIdValue(id),
      ),
    );
  }
  return sessions;
}

/// Parses Cursor Agent session metadata from a chat `meta.json` file.
@visibleForTesting
({
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool hasConversation,
  bool parsedAny,
})
parseCursorSessionMetadata(String raw) {
  final decoded = _tryDecodeJsonObject(raw.trim());
  if (decoded == null) {
    return (
      summary: null,
      workingDirectory: null,
      updatedAt: null,
      hasConversation: true,
      parsedAny: false,
    );
  }

  final summary = _readStringField(decoded, 'title');
  final workingDirectory = _readStringField(decoded, 'cwd');
  final updatedAt =
      _parseDateTimeValue(decoded['updatedAtMs']) ??
      _parseDateTimeValue(decoded['createdAtMs']);
  final hasConversationValue = decoded['hasConversation'];
  final hasConversation = hasConversationValue is! bool || hasConversationValue;
  final parsedAny =
      summary != null || workingDirectory != null || updatedAt != null;

  return (
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    hasConversation: hasConversation,
    parsedAny: parsedAny,
  );
}

/// Parses Antigravity session metadata from a saved session JSON file.
@visibleForTesting
({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool parsedAny,
})
parseAntigravitySessionMetadata(String raw) {
  final decoded = _tryDecodeJsonObject(raw);
  if (decoded == null) {
    return _parsePartialAntigravitySessionMetadata(raw);
  }

  final sessionId =
      _readStringField(decoded, 'id') ?? _readStringField(decoded, 'sessionId');
  final summary =
      _readStringField(decoded, 'display') ??
      _readStringField(decoded, 'summary') ??
      _readStringField(decoded, 'name');

  var workingDirectory =
      _readStringField(decoded, 'workingDirectory') ??
      _readStringField(decoded, 'cwd');

  if (workingDirectory == null) {
    final projectResources = _readMapField(decoded, 'projectResources');
    final resources = _readListField(projectResources, 'resources');
    if (resources != null) {
      for (final resource in resources) {
        if (resource is Map) {
          final resourceMap = resource.map((k, v) => MapEntry('$k', v));
          final gitFolder = _readMapField(resourceMap, 'gitFolder');
          final folderUriStr = _readStringField(gitFolder, 'folderUri');
          if (folderUriStr != null) {
            try {
              final uri = Uri.tryParse(folderUriStr);
              if (uri != null && uri.isScheme('file')) {
                workingDirectory = _uriToFilePath(uri);
                break;
              }
            } on Object {
              // Ignore uri parsing errors
            }
          }
        }
      }
    }
  }

  if (workingDirectory == null && summary != null && summary.startsWith('/')) {
    workingDirectory = summary;
  }

  final updatedAt =
      _parseDateTimeValue(decoded['updatedAt']) ??
      _parseDateTimeValue(decoded['lastActive']);

  final parsedAny =
      sessionId != null ||
      summary != null ||
      workingDirectory != null ||
      updatedAt != null;

  return (
    sessionId: sessionId,
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    parsedAny: parsedAny,
  );
}

({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  bool parsedAny,
})
_parsePartialAntigravitySessionMetadata(String raw) {
  final sessionId =
      _readJsonStringFromRaw(raw, 'id') ??
      _readJsonStringFromRaw(raw, 'sessionId');
  final summary =
      _readJsonStringFromRaw(raw, 'display') ??
      _readJsonStringFromRaw(raw, 'summary') ??
      _readJsonStringFromRaw(raw, 'name');

  var workingDirectory =
      _readJsonStringFromRaw(raw, 'workingDirectory') ??
      _readJsonStringFromRaw(raw, 'cwd');

  if (workingDirectory == null) {
    final folderUriStr = _readJsonStringFromRaw(raw, 'folderUri');
    if (folderUriStr != null) {
      try {
        final uri = Uri.tryParse(folderUriStr);
        if (uri != null && uri.isScheme('file')) {
          workingDirectory = _uriToFilePath(uri);
        }
      } on Object {
        // Ignore uri parsing errors
      }
    }
  }

  if (workingDirectory == null && summary != null && summary.startsWith('/')) {
    workingDirectory = summary;
  }

  final updatedAt =
      _parseDateTimeValue(_readJsonStringFromRaw(raw, 'updatedAt')) ??
      _parseDateTimeValue(_readJsonStringFromRaw(raw, 'lastActive'));

  final parsedAny =
      sessionId != null ||
      summary != null ||
      workingDirectory != null ||
      updatedAt != null;

  return (
    sessionId: sessionId,
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    parsedAny: parsedAny,
  );
}

String? _readJsonStringFromRaw(String raw, String key) {
  final pattern = RegExp(
    '"${RegExp.escape(key)}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"',
    multiLine: true,
  );
  final match = pattern.firstMatch(raw);
  if (match == null) return null;
  try {
    final decoded = jsonDecode('"${match.group(1)}"');
    return decoded is String ? decoded : null;
  } on FormatException {
    return null;
  }
}

int? _readJsonNumberFromRaw(String raw, String key) {
  final pattern = RegExp(
    '"${RegExp.escape(key)}"\\s*:\\s*(-?\\d+)',
    multiLine: true,
  );
  final match = pattern.firstMatch(raw);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Parses OpenCode's JSON storage session metadata from
/// `storage/session/<project>/<session>.json`.
@visibleForTesting
({
  String? sessionId,
  String? summary,
  String? workingDirectory,
  DateTime? updatedAt,
  String? parentId,
  bool isArchived,
  bool parsedAny,
})
parseOpenCodeStorageSessionMetadata(String raw) {
  final decoded = _tryDecodeJsonObject(raw);
  if (decoded == null) {
    final sessionId =
        _readJsonStringFromRaw(raw, 'id') ??
        _readJsonStringFromRaw(raw, 'sessionId') ??
        _readJsonStringFromRaw(raw, 'sessionID');
    final summary =
        _readJsonStringFromRaw(raw, 'title') ??
        _readJsonStringFromRaw(raw, 'summary') ??
        _readJsonStringFromRaw(raw, 'name');
    final workingDirectory =
        _readJsonStringFromRaw(raw, 'directory') ??
        _readJsonStringFromRaw(raw, 'cwd');
    final parentId =
        _readJsonStringFromRaw(raw, 'parentID') ??
        _readJsonStringFromRaw(raw, 'parent_id');
    final updatedAt =
        _parseDateTimeValue(_readJsonNumberFromRaw(raw, 'updated')) ??
        _parseDateTimeValue(_readJsonStringFromRaw(raw, 'updatedAt'));
    final isArchived =
        _readJsonNumberFromRaw(raw, 'archived') != null ||
        _readJsonNumberFromRaw(raw, 'time_archived') != null;

    return (
      sessionId: sessionId,
      summary: summary,
      workingDirectory: workingDirectory,
      updatedAt: updatedAt,
      parentId: parentId,
      isArchived: isArchived,
      parsedAny:
          sessionId != null ||
          summary != null ||
          workingDirectory != null ||
          parentId != null ||
          updatedAt != null ||
          isArchived,
    );
  }

  final time = _readMapField(decoded, 'time');
  final sessionId =
      _readStringField(decoded, 'id') ??
      _readStringField(decoded, 'sessionId') ??
      _readStringField(decoded, 'sessionID');
  final summary =
      _readStringField(decoded, 'title') ??
      _readStringField(decoded, 'summary') ??
      _readStringField(decoded, 'name');
  final workingDirectory =
      _readStringField(decoded, 'directory') ??
      _readStringField(decoded, 'cwd');
  final parentId =
      _readStringField(decoded, 'parentID') ??
      _readStringField(decoded, 'parent_id');
  final updatedAt =
      _parseDateTimeValue(time?['updated']) ??
      _parseDateTimeValue(decoded['updatedAt']) ??
      _parseDateTimeValue(decoded['updated']) ??
      _parseDateTimeValue(decoded['time_updated']);
  final isArchived =
      time?['archived'] != null || decoded['time_archived'] != null;

  return (
    sessionId: sessionId,
    summary: summary,
    workingDirectory: workingDirectory,
    updatedAt: updatedAt,
    parentId: parentId,
    isArchived: isArchived,
    parsedAny:
        sessionId != null ||
        summary != null ||
        workingDirectory != null ||
        parentId != null ||
        updatedAt != null ||
        isArchived,
  );
}

String? _trimWorkingDirectory(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final withoutTrailingSlash = trimmed.length > 1 && trimmed.endsWith('/')
      ? trimmed.replaceFirst(RegExp(r'/+$'), '')
      : trimmed;
  return withoutTrailingSlash.replaceAll(RegExp('/+'), '/');
}

/// Matches a Windows-style absolute path (`C:\...`, `C:/...`, or the OSC/file
/// URI `/C:/...` form).
final _windowsWorkingDirectoryPattern = RegExp(r'^/?[A-Za-z]:[\\/]');

/// Matches a single backslash.
final _backslashPattern = RegExp(r'\\');

/// Whether [path] looks like a Windows path (drive-letter root or containing a
/// backslash separator) rather than a POSIX path.
bool _looksLikeWindowsPath(String path) {
  final trimmed = path.trim();
  return _windowsWorkingDirectoryPattern.hasMatch(trimmed) ||
      _backslashPattern.hasMatch(trimmed);
}

/// Normalizes a Windows working directory to a canonical comparable form:
/// forward slashes, the `/C:/…` URI form reduced to `C:/…`, and lower-cased
/// (Windows paths are case-insensitive). POSIX paths pass through unchanged.
String _normalizeWindowsWorkingDirectory(String value) {
  var result = value.trim().replaceFirstMapped(
    RegExp('^/([A-Za-z]:)'),
    (match) => match[1]!,
  );
  if (_looksLikeWindowsPath(result)) {
    result = result.replaceAll(_backslashPattern, '/').toLowerCase();
  }
  return result;
}

/// Normalizes a working directory for cross-worktree comparisons.
///
/// Paths under `repo.worktrees/<branch>/...` are normalized to `repo/...` so
/// sessions from sibling checkouts can still match the active project scope.
/// Windows paths are canonicalized (forward slashes, lower-cased, `/C:/`→`C:/`)
/// so backslash/drive-case/URI variants of the same directory still match.
@visibleForTesting
String normalizeWorkingDirectoryForComparison(String value) {
  final windowsNormalized = _normalizeWindowsWorkingDirectory(value);
  final trimmed = _trimWorkingDirectory(windowsNormalized);
  if (trimmed == null) return windowsNormalized;

  final segments = trimmed.split('/');
  final normalizedSegments = <String>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment.endsWith('.worktrees') && index + 1 < segments.length) {
      normalizedSegments.add(
        segment.substring(0, segment.length - '.worktrees'.length),
      );
      index += 1;
      continue;
    }
    normalizedSegments.add(segment);
  }

  final normalized = normalizedSegments.join('/');
  return trimmed.startsWith('/') && !normalized.startsWith('/')
      ? '/$normalized'
      : normalized;
}

String _workingDirectoryPrefix(String path) =>
    path.endsWith('/') ? path : '$path/';

String? _relativeWorkingDirectoryPath(String child, String root) {
  if (child == root) return '';
  final prefix = _workingDirectoryPrefix(root);
  if (!child.startsWith(prefix)) return null;
  return child.substring(prefix.length);
}

String _joinWorkingDirectoryPath(String root, String relativePath) =>
    relativePath.isEmpty
    ? root
    : '${_workingDirectoryPrefix(root)}$relativePath';

bool _workingDirectoriesOverlap(String a, String b) =>
    a == b ||
    a.startsWith(_workingDirectoryPrefix(b)) ||
    b.startsWith(_workingDirectoryPrefix(a));

/// Parses `git worktree list --porcelain` output into root paths.
@visibleForTesting
List<String> parseGitWorktreeRoots(String raw) {
  final roots = <String>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (!line.startsWith('worktree ')) continue;
    final root = _trimWorkingDirectory(line.substring('worktree '.length));
    if (root != null) roots.add(root);
  }
  return roots;
}

/// Builds all directories that should be treated as the active project scope.
///
/// This includes the active directory itself, the normalized `.worktrees`
/// equivalent, the git worktree roots when available, and corresponding
/// subdirectories across sibling worktrees.
@visibleForTesting
List<String> buildRelatedWorkingDirectories(
  String activeWorkingDirectory, {
  String? gitRoot,
  Iterable<String> gitWorktreeRoots = const <String>[],
}) {
  final trimmedActive = _trimWorkingDirectory(activeWorkingDirectory);
  if (trimmedActive == null) return const <String>[];

  final directories = <String>{};

  void addDirectory(String? directory) {
    final trimmed = _trimWorkingDirectory(directory);
    if (trimmed == null) return;
    directories
      ..add(trimmed)
      ..add(normalizeWorkingDirectoryForComparison(trimmed));
  }

  addDirectory(trimmedActive);

  final trimmedGitRoot = _trimWorkingDirectory(gitRoot);
  final relativePath = trimmedGitRoot == null
      ? null
      : _relativeWorkingDirectoryPath(trimmedActive, trimmedGitRoot);

  addDirectory(trimmedGitRoot);

  if (relativePath != null && relativePath.isNotEmpty) {
    for (final root in gitWorktreeRoots) {
      final trimmedRoot = _trimWorkingDirectory(root);
      if (trimmedRoot == null) continue;
      addDirectory(_joinWorkingDirectoryPath(trimmedRoot, relativePath));
    }
  }

  for (final root in gitWorktreeRoots) {
    addDirectory(root);
  }

  return directories.toList(growable: false);
}

/// Whether a discovered session belongs to the active project scope.
///
/// A session Pi relocated into another directory keeps the directory it started
/// in on [ToolSessionInfo.originWorkingDirectory], so both are checked. Every
/// scope filter must use this predicate: discovery scopes per provider, the
/// aggregate scopes again, and the incremental preview scopes a third time, so
/// a filter that only looks at the recorded directory silently drops the row.
@visibleForTesting
bool discoveredSessionMatchesScope(
  ToolSessionInfo info,
  String workingDirectory, {
  Iterable<String> relatedWorkingDirectories = const <String>[],
}) =>
    matchesDiscoveredSessionWorkingDirectory(
      workingDirectory,
      info.workingDirectory,
      relatedWorkingDirectories: relatedWorkingDirectories,
    ) ||
    matchesDiscoveredSessionWorkingDirectory(
      workingDirectory,
      info.originWorkingDirectory,
      relatedWorkingDirectories: relatedWorkingDirectories,
    );

/// Whether a discovered session directory belongs to the active project scope.
@visibleForTesting
bool matchesDiscoveredSessionWorkingDirectory(
  String expectedWorkingDirectory,
  String? sessionDirectory, {
  Iterable<String> relatedWorkingDirectories = const <String>[],
}) {
  final trimmedSessionDirectory = _trimWorkingDirectory(sessionDirectory);
  if (trimmedSessionDirectory == null) return false;
  final comparableSessionDirectory = normalizeWorkingDirectoryForComparison(
    trimmedSessionDirectory,
  );
  final candidates = relatedWorkingDirectories.isNotEmpty
      ? relatedWorkingDirectories
      : <String>[expectedWorkingDirectory];
  for (final candidate in candidates) {
    final trimmedCandidate = _trimWorkingDirectory(candidate);
    if (trimmedCandidate == null) continue;
    final comparableCandidate = normalizeWorkingDirectoryForComparison(
      trimmedCandidate,
    );
    if (_workingDirectoriesOverlap(
      comparableCandidate,
      comparableSessionDirectory,
    )) {
      return true;
    }
  }
  return false;
}

/// Reads the Claude history working directory using only string-typed fields.
@visibleForTesting
String? readClaudeHistoryWorkingDirectory(Map<String, dynamic> entry) =>
    _readStringField(entry, 'directory') ?? _readStringField(entry, 'project');

/// Limits how many Claude session files should be snapshot-read for metadata.
@visibleForTesting
int calculateClaudeMetadataSnapshotLimit(int maxPerTool) =>
    _calculateDiscoveryScanLimit(
      maxPerTool,
      multiplier: 4,
      minimum: 40,
      maximum: 80,
    );

/// Limits how many recent session files should be metadata-read after the
/// provider has already listed candidates in descending update order.
@visibleForTesting
int calculateRecentSessionMetadataReadLimit(int maxPerTool) =>
    _calculateDiscoveryScanLimit(
      maxPerTool,
      multiplier: 3,
      minimum: 24,
      maximum: 48,
    );

/// Sorts merged discovery sessions by recency before applying a scan cap.
@visibleForTesting
List<ToolSessionInfo> sortAndLimitDiscoveredSessions(
  Iterable<ToolSessionInfo> sessions,
  int limit,
) {
  final sortedSessions = sessions.toList(growable: false)
    ..sort(compareDiscoveredSessionsByRecency);
  return sortedSessions.take(limit).toList(growable: false);
}

/// Scopes discovered sessions to the active working directory on a per-tool
/// basis, preserving a tool's unscoped results when it lacks matching cwd
/// metadata instead of dropping that provider entirely.
@visibleForTesting
List<ToolSessionInfo> scopeDiscoveredSessionsToWorkingDirectory(
  Iterable<ToolSessionInfo> sessions,
  String workingDirectory, {
  Iterable<String> relatedWorkingDirectories = const <String>[],
}) {
  final sessionsByTool = <String, List<ToolSessionInfo>>{};
  for (final session in sessions) {
    sessionsByTool
        .putIfAbsent(session.toolName, () => <ToolSessionInfo>[])
        .add(session);
  }

  final scopedSessions = <ToolSessionInfo>[];
  for (final toolSessions in sessionsByTool.values) {
    final matchingSessions = toolSessions
        .where(
          (session) => discoveredSessionMatchesScope(
            session,
            workingDirectory,
            relatedWorkingDirectories: relatedWorkingDirectories,
          ),
        )
        .toList(growable: false);
    if (matchingSessions.isNotEmpty) {
      scopedSessions.addAll(matchingSessions);
      continue;
    }

    final sessionsWithoutWorkingDirectory = toolSessions
        .where(
          (session) =>
              session.workingDirectory == null ||
              session.workingDirectory!.isEmpty,
        )
        .toList(growable: false);
    scopedSessions.addAll(sessionsWithoutWorkingDirectory);
  }

  scopedSessions.sort(compareDiscoveredSessionsByRecency);
  return scopedSessions;
}

/// Discovers recent AI coding tool sessions on remote hosts by scanning
/// known session storage locations.
///
/// Each tool stores session history differently. This service encapsulates
/// the per-tool discovery logic and presents a unified list of
/// [ToolSessionInfo] entries.
class AgentSessionDiscoveryService {
  /// Creates a new [AgentSessionDiscoveryService].
  AgentSessionDiscoveryService({
    DateTime Function()? now,
    TerminalConnectionBackendService? terminalBackendService,
  }) : _now = now ?? DateTime.now,
       _terminalBackendService = terminalBackendService;

  final DateTime Function() _now;
  final TerminalConnectionBackendService? _terminalBackendService;
  final Map<_AgentSessionDiscoveryKey, _CachedDiscoveryResult> _discoveryCache =
      <_AgentSessionDiscoveryKey, _CachedDiscoveryResult>{};
  final Map<_AgentSessionDiscoveryKey, Stream<DiscoveredSessionsResult>>
  _inFlightDiscoveries =
      <_AgentSessionDiscoveryKey, Stream<DiscoveredSessionsResult>>{};
  final Map<_AgentSessionDiscoveryKey, DiscoveredSessionsResult>
  _inFlightDiscoverySnapshots =
      <_AgentSessionDiscoveryKey, DiscoveredSessionsResult>{};
  final Map<_AgentSessionDiscoveryScopeKey, _CachedRelatedWorkingDirectories>
  _relatedWorkingDirectoriesCache =
      <_AgentSessionDiscoveryScopeKey, _CachedRelatedWorkingDirectories>{};
  final Map<_AgentSessionDiscoveryScopeKey, Future<List<String>>>
  _inFlightRelatedWorkingDirectories =
      <_AgentSessionDiscoveryScopeKey, Future<List<String>>>{};

  /// Invalidates cached and in-flight discovery state for [session].
  ///
  /// The next picker load starts fresh without reconnecting the SSH session.
  void invalidateSession(SshSession session) {
    bool matches(_AgentSessionDiscoveryScopeKey key) =>
        key.hostId == session.hostId &&
        key.hostname == session.config.hostname &&
        key.port == session.config.port &&
        key.username == session.config.username;

    _discoveryCache.removeWhere((key, _) => matches(key.scopeKey));
    _inFlightDiscoveries.removeWhere((key, _) => matches(key.scopeKey));
    _inFlightDiscoverySnapshots.removeWhere((key, _) => matches(key.scopeKey));
    _relatedWorkingDirectoriesCache.removeWhere((key, _) => matches(key));
    _inFlightRelatedWorkingDirectories.removeWhere((key, _) => matches(key));
  }

  /// Warms the discovery cache for the given scope without changing UI state.
  ///
  /// This is useful for preloading likely session views ahead of user
  /// interaction so later visible loads can return from cache or join the
  /// in-flight discovery work.
  Future<void> prefetchSessions(
    SshSession session, {
    String? workingDirectory,
    int maxPerTool = 12,
    String? toolName,
  }) async {
    try {
      await discoverSessionsStream(
        session,
        workingDirectory: workingDirectory,
        maxPerTool: maxPerTool,
        toolName: toolName,
      ).drain<void>();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'agent_session_discovery_service',
          context: ErrorDescription('while prefetching recent AI sessions'),
        ),
      );
    }
  }

  /// Discovers recent sessions and emits incremental updates as each tool
  /// finishes loading.
  ///
  /// This lets the UI render providers as they complete instead of waiting for
  /// the slowest tool before showing anything. Repeated loads for the same
  /// connection and scope reuse a short-lived cached result, while concurrent
  /// loads share the same in-flight discovery work.
  Stream<DiscoveredSessionsResult> discoverSessionsStream(
    SshSession session, {
    String? workingDirectory,
    int maxPerTool = 12,
    String? toolName,
  }) async* {
    _pruneExpiredCacheEntries();
    final key = _AgentSessionDiscoveryKey.fromSession(
      session,
      workingDirectory: workingDirectory,
      maxPerTool: maxPerTool,
      toolName: toolName,
    );

    final freshCachedResult = _lookupCachedDiscoveryResult(key);
    if (freshCachedResult != null) {
      yield freshCachedResult;
      return;
    }

    final scopedFreshCachedResult = _lookupScopedCachedDiscoveryResult(
      key.scopeKey,
    );
    if (scopedFreshCachedResult != null) {
      yield scopedFreshCachedResult;
    }

    final inFlightStream = _inFlightDiscoveries[key];
    if (inFlightStream != null) {
      final inFlightSnapshot = _inFlightDiscoverySnapshots[key];
      if (inFlightSnapshot != null) {
        yield inFlightSnapshot;
      } else {
        final staleCachedResult =
            _lookupCachedDiscoveryResult(key, allowStale: true) ??
            _lookupScopedCachedDiscoveryResult(key.scopeKey, allowStale: true);
        if (staleCachedResult != null) {
          yield staleCachedResult;
        }
      }
      yield* inFlightStream;
      return;
    }

    final scopedInFlightSnapshot = _lookupScopedInFlightDiscoverySnapshot(
      key.scopeKey,
    );
    if (scopedInFlightSnapshot != null) {
      yield scopedInFlightSnapshot;
    }

    final staleCachedResult =
        _lookupCachedDiscoveryResult(key, allowStale: true) ??
        _lookupScopedCachedDiscoveryResult(key.scopeKey, allowStale: true);
    if (staleCachedResult != null) {
      yield staleCachedResult;
    }

    yield* _startSharedDiscovery(
      key,
      session,
      workingDirectory: workingDirectory,
      maxPerTool: maxPerTool,
      toolName: toolName,
    );
  }

  Stream<DiscoveredSessionsResult> _startSharedDiscovery(
    _AgentSessionDiscoveryKey key,
    SshSession session, {
    required String? workingDirectory,
    required int maxPerTool,
    required String? toolName,
  }) {
    final controller = StreamController<DiscoveredSessionsResult>.broadcast();
    final stream = controller.stream;
    _inFlightDiscoveries[key] = stream;

    unawaited(() async {
      try {
        final resolvedWorkingDirectory =
            await _resolveRemoteHomeWorkingDirectory(session, workingDirectory);
        final relatedWorkingDirectories =
            await _resolveRelatedWorkingDirectoriesCached(
              session,
              resolvedWorkingDirectory,
            );
        final discoveries = _startToolDiscoveries(
          session,
          workingDirectory: resolvedWorkingDirectory,
          relatedWorkingDirectories: relatedWorkingDirectories,
          maxPerTool: maxPerTool,
          toolName: toolName,
          previewOnly: toolName == null,
        );
        final pendingResults = <int, Future<_IndexedToolDiscoveryResult>>{
          for (var index = 0; index < discoveries.length; index++)
            index: discoveries[index].then(
              (result) => _IndexedToolDiscoveryResult(index, result),
            ),
        };
        final completedResults = List<_ToolDiscoveryResult?>.filled(
          discoveries.length,
          null,
        );
        DiscoveredSessionsResult? previewSnapshot;

        while (pendingResults.isNotEmpty) {
          final completed = await Future.any(pendingResults.values);
          pendingResults.remove(completed.index)?.ignore();
          completedResults[completed.index] = completed.result;
          if (toolName == null) {
            final previewResult = _buildToolDiscoveryPreviewResult(
              completed.result,
              workingDirectory: resolvedWorkingDirectory,
              relatedWorkingDirectories: relatedWorkingDirectories,
            );
            previewSnapshot = _mergeDiscoveryPreviewSnapshot(
              previewSnapshot,
              previewResult,
            );
            if (identical(_inFlightDiscoveries[key], stream)) {
              _inFlightDiscoverySnapshots[key] = previewSnapshot;
            }
            controller.add(previewResult);
            await Future<void>.delayed(Duration.zero);
          }
        }

        final latestResult = _buildDiscoveredSessionsResult(
          completedResults.whereType<_ToolDiscoveryResult>(),
          workingDirectory: resolvedWorkingDirectory,
          relatedWorkingDirectories: relatedWorkingDirectories,
          maxPerTool: maxPerTool,
        );
        // Invalidated work may finish for its original listeners, but must not
        // restore a stale snapshot or overwrite a replacement discovery's one.
        if (identical(_inFlightDiscoveries[key], stream)) {
          _inFlightDiscoverySnapshots[key] = latestResult;
        }
        controller.add(latestResult);

        if (identical(_inFlightDiscoveries[key], stream)) {
          _discoveryCache[key] = _CachedDiscoveryResult(
            result: latestResult,
            cachedAt: _now(),
          );
        }
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        if (identical(_inFlightDiscoveries[key], stream)) {
          _inFlightDiscoveries.remove(key);
          _inFlightDiscoverySnapshots.remove(key);
        }
        await controller.close();
      }
    }());

    return stream;
  }

  DiscoveredSessionsResult? _lookupCachedDiscoveryResult(
    _AgentSessionDiscoveryKey key, {
    bool allowStale = false,
  }) {
    final cached = _discoveryCache[key];
    if (cached == null) return null;
    final age = _now().difference(cached.cachedAt);
    if (age < _sessionDiscoveryCacheFreshTtl) {
      return cached.result;
    }
    if (allowStale && age < _sessionDiscoveryCacheRetentionTtl) {
      return cached.result;
    }
    return null;
  }

  DiscoveredSessionsResult? _lookupScopedCachedDiscoveryResult(
    _AgentSessionDiscoveryScopeKey scopeKey, {
    bool allowStale = false,
  }) {
    final now = _now();
    _AgentSessionDiscoveryKey? bestKey;
    _CachedDiscoveryResult? bestResult;
    for (final entry in _discoveryCache.entries) {
      if (entry.key.scopeKey != scopeKey) continue;
      final age = now.difference(entry.value.cachedAt);
      if (age >= _sessionDiscoveryCacheFreshTtl &&
          (!allowStale || age >= _sessionDiscoveryCacheRetentionTtl)) {
        continue;
      }
      if (bestKey == null ||
          entry.key.maxPerTool > bestKey.maxPerTool ||
          (entry.key.maxPerTool == bestKey.maxPerTool &&
              entry.value.cachedAt.isAfter(bestResult!.cachedAt))) {
        bestKey = entry.key;
        bestResult = entry.value;
      }
    }
    return bestResult?.result;
  }

  DiscoveredSessionsResult? _lookupScopedInFlightDiscoverySnapshot(
    _AgentSessionDiscoveryScopeKey scopeKey,
  ) {
    _AgentSessionDiscoveryKey? bestKey;
    DiscoveredSessionsResult? bestSnapshot;
    for (final entry in _inFlightDiscoverySnapshots.entries) {
      if (entry.key.scopeKey != scopeKey) continue;
      if (bestKey == null || entry.key.maxPerTool > bestKey.maxPerTool) {
        bestKey = entry.key;
        bestSnapshot = entry.value;
      }
    }
    return bestSnapshot;
  }

  void _pruneExpiredCacheEntries() {
    final now = _now();
    _discoveryCache.removeWhere(
      (_, entry) =>
          now.difference(entry.cachedAt) >= _sessionDiscoveryCacheRetentionTtl,
    );
    _relatedWorkingDirectoriesCache.removeWhere(
      (_, entry) =>
          now.difference(entry.cachedAt) >= _relatedWorkingDirectoriesCacheTtl,
    );
  }

  List<Future<_ToolDiscoveryResult>> _startToolDiscoveries(
    SshSession session, {
    required String? workingDirectory,
    required List<String> relatedWorkingDirectories,
    required int maxPerTool,
    required String? toolName,
    required bool previewOnly,
  }) {
    final handlers =
        <
          String,
          Future<_ToolDiscoveryResult> Function(
            SshSession,
            String?,
            List<String>,
            int, {
            bool previewOnly,
          })
        >{
          'OpenCode':
              (session, cwd, related, max, {bool previewOnly = false}) =>
                  _discoverOpenCodeSessions(
                    session,
                    cwd,
                    related,
                    max,
                    previewOnly: previewOnly,
                    useAcp: toolName != null,
                  ),
          'Codex': _discoverCodexSessions,
          'Copilot CLI':
              (session, cwd, related, max, {bool previewOnly = false}) =>
                  _discoverCopilotSessions(
                    session,
                    cwd,
                    related,
                    max,
                    previewOnly: previewOnly,
                    useAcp: toolName != null,
                  ),
          'Claude Code': _discoverClaudeSessions,
          'Antigravity': _discoverAntigravitySessions,
          'Cursor Agent': _discoverCursorSessions,
          'Pi': _discoverPiSessions,
          'Hermes': _discoverHermesSessions,
          'Grok Build': _discoverGrokSessions,
        };
    return [
      for (final name in toolName == null ? handlers.keys : [toolName])
        handlers[name]?.call(
              session,
              workingDirectory,
              relatedWorkingDirectories,
              previewOnly ? 1 : maxPerTool,
              previewOnly: toolName == null && previewOnly,
            ) ??
            Future.value(_ToolDiscoveryResult.success(name, const [])),
    ];
  }

  DiscoveredSessionsResult _buildToolDiscoveryPreviewResult(
    _ToolDiscoveryResult result, {
    required String? workingDirectory,
    required List<String> relatedWorkingDirectories,
  }) {
    final previewSession = _firstToolDiscoveryPreviewSession(
      result.sessions,
      workingDirectory: workingDirectory,
      relatedWorkingDirectories: relatedWorkingDirectories,
    );
    return DiscoveredSessionsResult(
      sessions: previewSession == null
          ? const <ToolSessionInfo>[]
          : <ToolSessionInfo>[previewSession],
      failedTools:
          shouldSurfaceDiscoveryFailure(
            hadError: result.hadError,
            loadedSessionCount: result.sessions.length,
          )
          ? <String>[result.toolName]
          : const <String>[],
      attemptedTools: <String>[result.toolName],
    );
  }

  ToolSessionInfo? _firstToolDiscoveryPreviewSession(
    Iterable<ToolSessionInfo> sessions, {
    required String? workingDirectory,
    required List<String> relatedWorkingDirectories,
  }) {
    ToolSessionInfo? unscopedFallback;
    for (final info in sessions) {
      final normalized = normalizeDiscoveredSessionInfo(
        info,
        activeWorkingDirectory: workingDirectory,
      );
      if (normalized == null) continue;

      if (workingDirectory == null || workingDirectory.isEmpty) {
        return normalized;
      }
      if (discoveredSessionMatchesScope(
        normalized,
        workingDirectory,
        relatedWorkingDirectories: relatedWorkingDirectories,
      )) {
        return normalized;
      }
      if (unscopedFallback == null &&
          (normalized.workingDirectory == null ||
              normalized.workingDirectory!.isEmpty)) {
        unscopedFallback = normalized;
      }
    }
    return unscopedFallback;
  }

  DiscoveredSessionsResult _mergeDiscoveryPreviewSnapshot(
    DiscoveredSessionsResult? current,
    DiscoveredSessionsResult next,
  ) {
    if (current == null) return next;
    final sessionsByTool = <String, ToolSessionInfo>{
      for (final session in current.sessions) session.toolName: session,
    };
    for (final session in next.sessions) {
      sessionsByTool.putIfAbsent(session.toolName, () => session);
    }
    return DiscoveredSessionsResult(
      sessions: sessionsByTool.values,
      failedTools: <String>{...current.failedTools, ...next.failedTools},
      attemptedTools: <String>{
        ...current.attemptedTools,
        ...next.attemptedTools,
      },
    );
  }

  DiscoveredSessionsResult _buildDiscoveredSessionsResult(
    Iterable<_ToolDiscoveryResult> results, {
    required String? workingDirectory,
    required List<String> relatedWorkingDirectories,
    required int maxPerTool,
  }) {
    final all = results
        .expand((result) => result.sessions)
        .map(
          (info) => normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: workingDirectory,
          ),
        )
        .whereType<ToolSessionInfo>()
        .toList(growable: false);
    final failedTools = results
        .where(
          (result) => shouldSurfaceDiscoveryFailure(
            hadError: result.hadError,
            loadedSessionCount: result.sessions.length,
          ),
        )
        .map((result) => result.toolName);
    final attemptedTools = results.map((result) => result.toolName);

    if (workingDirectory != null && workingDirectory.isNotEmpty) {
      return DiscoveredSessionsResult(
        sessions: _limitDiscoveredSessionsPerTool(
          scopeDiscoveredSessionsToWorkingDirectory(
            all,
            workingDirectory,
            relatedWorkingDirectories: relatedWorkingDirectories,
          ),
          maxPerTool,
        ),
        failedTools: failedTools,
        attemptedTools: attemptedTools,
      );
    }

    return DiscoveredSessionsResult(
      sessions: _limitDiscoveredSessionsPerTool(all, maxPerTool),
      failedTools: failedTools,
      attemptedTools: attemptedTools,
    );
  }

  /// Builds the shell command to resume a specific session.
  ///
  /// If the session has a POSIX [ToolSessionInfo.workingDirectory], the command
  /// `cd`s there first so the CLI finds its project context. Windows working
  /// directories are omitted from the command — `cd '<path>' && <resume>` fails
  /// on cmd.exe (single quotes are literal) and PowerShell 5.1 (no `&&`) — and
  /// are instead applied via the new window's working directory, which every
  /// caller passes separately.
  String buildResumeCommand(
    ToolSessionInfo info, {
    bool startInYoloMode = false,
  }) {
    final tool = _agentLaunchToolForSessionToolName(info.toolName);
    final resume = tool == null
        ? info.toolName.toLowerCase()
        : buildAgentResumeCommand(
            tool,
            info.sessionId,
            startInYoloMode: startInYoloMode,
          );

    final dir = info.workingDirectory;
    if (dir != null && dir.isNotEmpty && !_looksLikeWindowsPath(dir)) {
      return 'cd ${shellEscapePosix(dir)} && $resume';
    }
    return resume;
  }

  // ── Claude Code ────────────────────────────────────────────────────────
  // Sessions: ~/.claude/projects/<path-hash>/*.jsonl
  // Index:    ~/.claude/history.jsonl

  Future<_ToolDiscoveryResult> _discoverClaudeSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      // Read more lines than needed to account for duplicate sessionIds
      // (e.g. multiple history entries for the same active session).
      final tailCount = previewOnly
          ? _calculateDiscoveryScanLimit(
              max,
              multiplier: 10,
              minimum: 24,
              maximum: 80,
            )
          : _calculateDiscoveryScanLimit(
              max,
              multiplier: 20,
              minimum: 120,
              maximum: 400,
            );
      final output = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsTailFileScript(
                relativePath: '.claude/history.jsonl',
                lines: tailCount,
              ),
            )
          : await _exec(
              session,
              'tail -n $tailCount ~/.claude/history.jsonl 2>/dev/null',
            );
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Claude Code', []);
      }

      final historyEntries = <Map<String, dynamic>>[];
      final seenIds = <String>{};
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          final sessionId = decoded['sessionId'] as String? ?? '';
          if (sessionId.isEmpty || seenIds.contains(sessionId)) continue;
          seenIds.add(sessionId);
          historyEntries.add(decoded);
        } on Object {
          // Ignore malformed lines.
        }
      }

      final scopedHistoryEntries =
          workingDirectory != null && workingDirectory.isNotEmpty
          ? historyEntries
                .where(
                  (entry) => matchesDiscoveredSessionWorkingDirectory(
                    workingDirectory,
                    readClaudeHistoryWorkingDirectory(entry),
                    relatedWorkingDirectories: relatedWorkingDirectories,
                  ),
                )
                .toList(growable: false)
          : historyEntries;
      final relevantHistoryEntries = scopedHistoryEntries.isNotEmpty
          ? scopedHistoryEntries
          : historyEntries;
      final snapshotHistoryEntries = relevantHistoryEntries
          .take(
            previewOnly
                ? _calculateDiscoveryScanLimit(
                    max,
                    multiplier: 4,
                    minimum: 6,
                    maximum: 12,
                  )
                : calculateClaudeMetadataSnapshotLimit(max),
          )
          .toList(growable: false);
      final sessionFilesById = await _findClaudeSessionFiles(
        session,
        snapshotHistoryEntries.map(
          (entry) => _readStringField(entry, 'sessionId') ?? '',
        ),
      );
      final sessionFileHeadSnapshots = await _readRemoteFileSnapshots(
        session,
        sessionFilesById.values,
        maxLines: previewOnly ? 40 : 120,
      );
      final sessionFileTailSnapshots = await _readRemoteFileSnapshots(
        session,
        sessionFilesById.values,
        maxLines: previewOnly ? 40 : 120,
        tail: true,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = false;
      for (final decoded in relevantHistoryEntries) {
        try {
          final sessionId = _readStringField(decoded, 'sessionId') ?? '';
          if (sessionId.isEmpty) continue;

          // timestamp may be int (epoch ms) or String (ISO 8601).
          DateTime? lastActive;
          final rawTs = decoded['timestamp'];
          if (rawTs is int) {
            lastActive = DateTime.fromMillisecondsSinceEpoch(rawTs);
          } else if (rawTs is String) {
            lastActive = DateTime.tryParse(rawTs);
          }

          String? summary;
          final sessionFilePath = sessionFilesById[sessionId] ?? '';
          if (sessionFilePath.isNotEmpty) {
            final headSnapshot = sessionFileHeadSnapshots[sessionFilePath];
            final tailSnapshot = sessionFileTailSnapshots[sessionFilePath];
            final snapshot = tailSnapshot ?? headSnapshot;
            lastActive ??= snapshot?.modifiedAt;
            final combinedContent = switch ((headSnapshot, tailSnapshot)) {
              (null, null) => '',
              (final head?, null) => head.content,
              (null, final tail?) => tail.content,
              (final head?, final tail?) =>
                head.content == tail.content
                    ? head.content
                    : '${head.content}\n${tail.content}',
            };
            final metadata = parseClaudeSessionMetadata(combinedContent);
            if (combinedContent.trim().isNotEmpty && !metadata.parsedAny) {
              hadError = true;
            }
            summary = _firstNonEmpty([
              metadata.customTitle,
              metadata.agentName,
              metadata.lastPrompt,
              metadata.userSummary,
            ]);
          }

          // Fall back to history index fields.
          final display = _readStringField(decoded, 'display');
          summary ??=
              _readStringField(decoded, 'title') ??
              _readStringField(decoded, 'query') ??
              (display != null && !display.startsWith('/') ? display : null);

          sessions.add(
            ToolSessionInfo(
              toolName: 'Claude Code',
              sessionId: sessionId,
              workingDirectory: readClaudeHistoryWorkingDirectory(decoded),
              lastActive: lastActive,
              summary: summary,
            ),
          );
        } on Object {
          hadError = true;
          continue;
        }
      }
      return _ToolDiscoveryResult.success(
        'Claude Code',
        sortAndLimitDiscoveredSessions(sessions, max),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Claude Code');
    }
  }

  // ── Codex CLI ──────────────────────────────────────────────────────────
  // Sessions: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl

  Future<_ToolDiscoveryResult> _discoverCodexSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(max, previewOnly: previewOnly);
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      final output = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsListNewestFilesScript(
                relativeRoot: '.codex/sessions',
                includeGlobs: const ['rollout-*.jsonl'],
                limit: scanLimit,
              ),
            )
          : await _exec(
              session,
              posixListNewestFilesCommand(
                'find ~/.codex/sessions -name "rollout-*.jsonl" -type f',
                scanLimit,
              ),
            );
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Codex', []);
      }

      final rolloutPaths = _nonEmptyLines(output).toList(growable: false);
      final recentRolloutPaths = rolloutPaths
          .take(metadataReadLimit)
          .toList(growable: false);
      final sessionIndex = await _readCodexSessionIndex(
        session,
        metadataReadLimit,
      );
      final rolloutSnapshots = await _readRemoteFileSnapshots(
        session,
        recentRolloutPaths,
        maxLines: previewOnly ? 40 : 80,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = sessionIndex.hadError;

      for (final filePath in recentRolloutPaths) {
        final fileName = filePath.split('/').last.replaceAll('.jsonl', '');
        final threadId = _extractCodexThreadId(fileName);
        final threadInfo = threadId != null
            ? sessionIndex.entries[threadId]
            : null;

        var summary = threadInfo?.threadName;
        var sessionId = threadId;
        String? sessionWorkingDirectory;
        var lastActive = threadInfo?.updatedAt;

        final snapshot = rolloutSnapshots[filePath];
        if (snapshot == null) {
          hadError = true;
        } else {
          try {
            final metadata = parseCodexRolloutMetadata(snapshot.content);
            if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
              hadError = true;
            }
            sessionId ??= metadata.sessionId;
            summary ??= metadata.summary;
            sessionWorkingDirectory = metadata.workingDirectory;
            lastActive ??= metadata.updatedAt;
          } on Object {
            hadError = true;
          }
          lastActive ??= snapshot.modifiedAt;
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: sessionId ?? fileName,
            workingDirectory: sessionWorkingDirectory,
            lastActive: lastActive,
            summary: summary ?? _truncateId(fileName),
          ),
        );
      }
      return _ToolDiscoveryResult.success(
        'Codex',
        _scopeSessions(
          sessions,
          workingDirectory,
          relatedWorkingDirectories,
          max,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Codex');
    }
  }

  Future<_CodexSessionIndexResult> _readCodexSessionIndex(
    SshSession session,
    int scanLimit,
  ) async {
    try {
      final output = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsTailFileScript(
                relativePath: '.codex/session_index.jsonl',
                lines: scanLimit * 5,
              ),
            )
          : await _exec(
              session,
              'tail -n ${scanLimit * 5} ~/.codex/session_index.jsonl '
              '2>/dev/null',
            );
      if (output.trim().isEmpty) {
        return const _CodexSessionIndexResult(entries: {});
      }

      final entries = <String, _CodexSessionIndexEntry>{};
      var hadError = false;
      for (final line in output.trim().split('\n').reversed) {
        if (line.trim().isEmpty) continue;
        final decoded = _tryDecodeJsonObject(line);
        if (decoded == null) {
          hadError = true;
          continue;
        }
        final id = _readStringField(decoded, 'id');
        if (id == null || id.isEmpty || entries.containsKey(id)) continue;
        entries[id] = _CodexSessionIndexEntry(
          threadName: _readStringField(decoded, 'thread_name'),
          updatedAt: _parseDateTimeValue(decoded['updated_at']),
        );
      }
      return _CodexSessionIndexResult(entries: entries, hadError: hadError);
    } on Object {
      return const _CodexSessionIndexResult(entries: {}, hadError: true);
    }
  }

  // ── Copilot CLI ────────────────────────────────────────────────────────
  // Sessions: ~/.copilot/session-state/<session-id>/

  Future<_ToolDiscoveryResult> _discoverCopilotSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool useAcp = true,
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(
        max,
        previewOnly: previewOnly,
        multiplier: 20,
        minimum: 120,
        maximum: 240,
      );
      if (useAcp) {
        final acpSessions = await _discoverAcpSessions(
          session,
          provider: _AcpSessionProvider.copilot,
          toolName: 'Copilot CLI',
          workingDirectory: workingDirectory,
          relatedWorkingDirectories: relatedWorkingDirectories,
          max: max,
        );
        if (acpSessions != null && acpSessions.sessions.isNotEmpty) {
          return _ToolDiscoveryResult.success(
            'Copilot CLI',
            sortAndLimitDiscoveredSessions(acpSessions.sessions, max),
            hadError: acpSessions.hadError,
          );
        }
      }

      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      final workspacePaths = await _listCopilotWorkspacePaths(
        session,
        scanLimit,
        relatedWorkingDirectories,
      );
      if (workspacePaths.isEmpty) {
        return const _ToolDiscoveryResult.success('Copilot CLI', []);
      }
      final recentWorkspacePaths = workspacePaths
          .take(metadataReadLimit)
          .toList(growable: false);

      final workspaceSnapshots = await _readRemoteFileSnapshots(
        session,
        recentWorkspacePaths,
      );
      final planPathsNeedingFallback = <String>[];
      final metadataByWorkspacePath =
          <
            String,
            ({String? summary, String? workingDirectory, DateTime? updatedAt})
          >{};
      var hadError = false;

      for (final workspacePath in recentWorkspacePaths) {
        final dirPath = workspacePath.replaceFirst(
          RegExp(r'/workspace\.yaml$'),
          '/',
        );
        final snapshot = workspaceSnapshots[workspacePath];
        if (snapshot == null) {
          hadError = true;
          metadataByWorkspacePath[workspacePath] = (
            summary: null,
            workingDirectory: null,
            updatedAt: null,
          );
          planPathsNeedingFallback.add('${dirPath}plan.md');
          continue;
        }

        try {
          final metadata = parseCopilotWorkspaceYamlMetadata(snapshot.content);
          metadataByWorkspacePath[workspacePath] = metadata;
          if (metadata.summary?.isEmpty ?? true) {
            planPathsNeedingFallback.add('${dirPath}plan.md');
          }
        } on Object {
          hadError = true;
          metadataByWorkspacePath[workspacePath] = (
            summary: null,
            workingDirectory: null,
            updatedAt: snapshot.modifiedAt,
          );
          planPathsNeedingFallback.add('${dirPath}plan.md');
        }
      }

      final planSnapshots = await _readRemoteFileSnapshots(
        session,
        planPathsNeedingFallback,
        maxLines: 3,
      );
      final sessions = <ToolSessionInfo>[];

      for (final workspacePath in recentWorkspacePaths) {
        final metadata = metadataByWorkspacePath[workspacePath];
        final snapshot = workspaceSnapshots[workspacePath];
        if (metadata == null) {
          hadError = true;
          continue;
        }

        final dirPath = workspacePath.replaceFirst(
          RegExp(r'/workspace\.yaml$'),
          '/',
        );
        final dirName = dirPath.split('/').where((s) => s.isNotEmpty).last;
        final planSnapshot = planSnapshots['${dirPath}plan.md'];
        final fallbackSummary = planSnapshot == null
            ? null
            : _extractPlanSummary(planSnapshot.content);

        sessions.add(
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: dirName,
            workingDirectory: metadata.workingDirectory,
            lastActive: metadata.updatedAt ?? snapshot?.modifiedAt,
            summary:
                metadata.summary ?? fallbackSummary ?? _truncateId(dirName),
          ),
        );
      }

      return _ToolDiscoveryResult.success(
        'Copilot CLI',
        sessions..sort(compareDiscoveredSessionsByRecency),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Copilot CLI');
    }
  }

  // ── Antigravity CLI ────────────────────────────────────────────────────
  // Sessions: ~/.antigravity/sessions/*.json

  Future<_ToolDiscoveryResult> _discoverAntigravitySessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(max, previewOnly: previewOnly);
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      final sessions = <ToolSessionInfo>[];
      final seenSessionIds = <String>{};
      var hadError = false;

      final jsonPathOutput = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsListNewestFilesScript(
                relativeRoot: '.antigravity/sessions',
                additionalRelativeRoots: const [
                  '.agy/sessions',
                  '.antigravitycli',
                  '.agycli',
                ],
                includeGlobs: const ['*.json'],
                limit: scanLimit,
                rootEnvironmentVariables:
                    _windowsUserDataRootEnvironmentVariables,
              ),
            )
          : await _exec(
              session,
              posixListNewestFilesCommand(
                'find ~/.antigravity/sessions ~/.agy/sessions '
                "./.antigravitycli ./.agycli -maxdepth 1 -name '*.json' -type f",
                scanLimit,
              ),
            );
      final jsonPaths = _nonEmptyLines(
        jsonPathOutput,
      ).take(metadataReadLimit).toList(growable: false);
      final jsonSnapshots = await _readRemoteFileSnapshots(
        session,
        jsonPaths,
        maxBytes: _openCodeStorageSessionMetadataMaxBytes,
      );

      for (final path in jsonPaths) {
        final snapshot = jsonSnapshots[path];
        if (snapshot == null) {
          hadError = true;
          continue;
        }
        try {
          final metadata = parseAntigravitySessionMetadata(snapshot.content);
          if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
            hadError = true;
            continue;
          }
          final sessionId =
              metadata.sessionId ?? _fileNameWithoutExtension(path);
          if (sessionId.isEmpty || !seenSessionIds.add(sessionId)) continue;
          sessions.add(
            ToolSessionInfo(
              toolName: 'Antigravity',
              sessionId: sessionId,
              workingDirectory: metadata.workingDirectory,
              lastActive: metadata.updatedAt ?? snapshot.modifiedAt,
              summary: metadata.summary ?? _truncateId(sessionId),
            ),
          );
        } on Object {
          hadError = true;
        }
      }

      final conversationPathOutput = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsListNewestFilesScript(
                relativeRoot: '.gemini/antigravity-cli',
                includeGlobs: const ['*.pb'],
                limit: scanLimit,
                pathLikeFilters: const ['*/conversations/*', '*/implicit/*'],
              ),
            )
          : await _exec(
              session,
              posixListNewestFilesCommand(
                'find ~/.gemini/antigravity-cli/conversations '
                "~/.gemini/antigravity-cli/implicit -maxdepth 1 -name '*.pb' -type f",
                scanLimit,
              ),
            );
      final conversationPaths = _nonEmptyLines(
        conversationPathOutput,
      ).take(metadataReadLimit).toList(growable: false);
      if (conversationPaths.isNotEmpty) {
        final historyOutput = session.remoteIsWindows
            ? await _execWindowsPowerShell(
                session,
                windowsTailFileScript(
                  relativePath: '.gemini/antigravity-cli/history.jsonl',
                  lines: scanLimit * 5,
                ),
              )
            : await _exec(
                session,
                'tail -n ${scanLimit * 5} '
                '~/.gemini/antigravity-cli/history.jsonl 2>/dev/null',
              );
        final historyById = _parseAntigravityHistoryJsonl(historyOutput);
        final annotationPaths = conversationPaths
            .map(_antigravityAnnotationPathForConversationFile)
            .whereType<String>()
            .toList(growable: false);
        final annotationSnapshots = await _readRemoteFileSnapshots(
          session,
          annotationPaths,
          maxLines: 20,
        );
        final conversationSnapshots = await _readRemoteFileSnapshots(
          session,
          conversationPaths,
          maxBytes: 0,
        );

        for (final path in conversationPaths) {
          final sessionId = _fileNameWithoutExtension(path);
          if (sessionId.isEmpty || !seenSessionIds.add(sessionId)) continue;
          final history = historyById[sessionId];
          final annotationPath = _antigravityAnnotationPathForConversationFile(
            path,
          );
          final annotationTitle = annotationPath == null
              ? null
              : _extractAntigravityAnnotationTitle(
                  annotationSnapshots[annotationPath]?.content ?? '',
                );
          sessions.add(
            ToolSessionInfo(
              toolName: 'Antigravity',
              sessionId: sessionId,
              workingDirectory: history?.workingDirectory,
              lastActive:
                  history?.updatedAt ?? conversationSnapshots[path]?.modifiedAt,
              summary:
                  history?.summary ?? annotationTitle ?? _truncateId(sessionId),
            ),
          );
        }
      }

      return _ToolDiscoveryResult.success(
        'Antigravity',
        _scopeSessions(
          sessions,
          workingDirectory,
          relatedWorkingDirectories,
          max,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Antigravity');
    }
  }

  // ── Cursor Agent ─────────────────────────────────────────────────────────
  // Sessions: ~/.cursor/chats/<workspaceHash>/<chatId>/meta.json
  // meta.json: {title, createdAtMs, updatedAtMs, cwd, hasConversation}.
  // The chat id (used with `cursor-agent --resume <id>`) is the directory name
  // that contains meta.json.

  Future<_ToolDiscoveryResult> _discoverCursorSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(max, previewOnly: previewOnly);
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      final output = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              windowsListNewestFilesScript(
                relativeRoot: '.cursor/chats',
                includeGlobs: const ['meta.json'],
                limit: scanLimit,
              ),
            )
          : await _exec(
              session,
              posixListNewestFilesCommand(
                'find ~/.cursor/chats -name meta.json -type f',
                scanLimit,
              ),
            );
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Cursor Agent', []);
      }

      final metaPaths = _nonEmptyLines(output).toList(growable: false);
      final recentMetaPaths = metaPaths
          .take(metadataReadLimit)
          .toList(growable: false);
      final metaSnapshots = await _readRemoteFileSnapshots(
        session,
        recentMetaPaths,
        maxLines: 20,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = false;

      for (final filePath in recentMetaPaths) {
        final chatId = _cursorChatIdFromMetaPath(filePath);
        if (chatId == null) continue;

        String? summary;
        String? sessionWorkingDirectory;
        DateTime? lastActive;

        final snapshot = metaSnapshots[filePath];
        if (snapshot == null) {
          hadError = true;
        } else {
          try {
            final metadata = parseCursorSessionMetadata(snapshot.content);
            if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
              hadError = true;
            }
            // Current Cursor Agent persists the active resumable chat id with
            // hasConversation=false, including after the TUI has created its
            // workspace chat. The parent directory remains the authoritative
            // --resume id, so keep metadata-only records instead of returning
            // an empty picker.
            summary = metadata.summary;
            sessionWorkingDirectory = metadata.workingDirectory;
            lastActive = metadata.updatedAt;
          } on Object {
            hadError = true;
          }
          lastActive ??= snapshot.modifiedAt;
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Cursor Agent',
            sessionId: chatId,
            workingDirectory: sessionWorkingDirectory,
            lastActive: lastActive,
            summary: summary ?? 'Cursor session ${_truncateId(chatId)}',
          ),
        );
      }
      return _ToolDiscoveryResult.success(
        'Cursor Agent',
        _scopeSessions(
          sessions,
          workingDirectory,
          relatedWorkingDirectories,
          max,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Cursor Agent');
    }
  }

  /// Extracts the Cursor chat id (the resume identifier) from the path of a
  /// chat `meta.json` file, i.e. the name of the directory that contains it.
  String? _cursorChatIdFromMetaPath(String path) {
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) return null;
    return segments[segments.length - 2];
  }

  // ── Grok Build ─────────────────────────────────────────────────────────
  // Sessions: ${GROK_HOME:-$HOME/.grok}/sessions/<encoded-cwd>/<id>/summary.json
  // summary.json contains the authoritative id, cwd, display title, and
  // activity timestamps used by `grok --resume <id>`.

  Future<_ToolDiscoveryResult> _discoverGrokSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(max, previewOnly: previewOnly);
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );

      final scopedDirectoryNames = <String>{
        if (workingDirectory != null && workingDirectory.isNotEmpty)
          Uri.encodeComponent(workingDirectory),
        for (final directory in relatedWorkingDirectories)
          Uri.encodeComponent(directory),
      }.toList(growable: false);
      String output;
      if (session.remoteIsWindows) {
        output = await _execWindowsPowerShell(
          session,
          windowsListNewestFilesScript(
            relativeRoot: '.grok/sessions',
            includeGlobs: const ['summary.json'],
            limit: scanLimit,
            pathLikeFilters: scopedDirectoryNames
                .map((name) => '*/$name/*')
                .toList(growable: false),
            overrideRootEnvironmentVariable: 'GROK_HOME',
            overrideRelativeRoot: 'sessions',
          ),
        );
      } else {
        final roots = scopedDirectoryNames
            .map((name) => r'"$GROK_SESSIONS_ROOT"/' + shellEscapePosix(name))
            .join(' ');
        output = await _exec(
          session,
          r'GROK_SESSIONS_ROOT="${GROK_HOME:-$HOME/.grok}/sessions"; '
          '${posixListNewestFilesCommand('${roots.isEmpty ? r'find "$GROK_SESSIONS_ROOT"' : 'find $roots -maxdepth 2'} '
          '-name summary.json -type f', scanLimit)}',
        );
      }
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Grok Build', []);
      }

      final summaryPaths = _nonEmptyLines(
        output,
      ).toSet().take(metadataReadLimit).toList(growable: false);
      final snapshots = await _readRemoteFileSnapshots(
        session,
        summaryPaths,
        maxBytes: _grokSessionMetadataMaxBytes,
      );
      final sessions = <ToolSessionInfo>[];
      var hadError = false;

      for (final path in summaryPaths) {
        final snapshot = snapshots[path];
        if (snapshot == null) {
          hadError = true;
          continue;
        }
        final metadata = parseGrokSessionMetadata(snapshot.content);
        if (!metadata.parsedAny) {
          if (snapshot.content.trim().isNotEmpty) hadError = true;
          continue;
        }
        if (metadata.isHidden) continue;

        final segments = path
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .toList(growable: false);
        final fallbackSessionId = segments.length < 2
            ? null
            : segments[segments.length - 2];
        final sessionId = metadata.sessionId?.trim().isNotEmpty ?? false
            ? metadata.sessionId!.trim()
            : fallbackSessionId;
        if (sessionId == null || sessionId.isEmpty) {
          hadError = true;
          continue;
        }

        sessions.add(
          ToolSessionInfo(
            toolName: 'Grok Build',
            sessionId: sessionId,
            workingDirectory: metadata.workingDirectory,
            lastActive: metadata.updatedAt ?? snapshot.modifiedAt,
            summary: metadata.summary ?? _truncateId(sessionId),
          ),
        );
      }

      return _ToolDiscoveryResult.success(
        'Grok Build',
        _scopeSessions(
          sessions,
          workingDirectory,
          relatedWorkingDirectories,
          max,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Grok Build');
    }
  }

  // ── Pi ─────────────────────────────────────────────────────────────────
  // Sessions: ~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<id>.jsonl
  // The first record is a `{"type":"session"}` header with id, timestamp and
  // cwd, so the head of each file is enough to build a picker row.

  Future<_ToolDiscoveryResult> _discoverPiSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(max, previewOnly: previewOnly);
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      final sessionPaths = await _listPiSessionPaths(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        scanLimit: scanLimit,
      );
      if (sessionPaths.isEmpty) {
        DiagnosticsLogService.instance.debug(
          'agent.discovery',
          'pi_complete',
          fields: {
            'connectionId': session.connectionId,
            'candidateCount': 0,
            'snapshotCount': 0,
            'returnedCount': 0,
            'previewOnly': previewOnly,
            'hadError': false,
          },
        );
        return const _ToolDiscoveryResult.success('Pi', []);
      }
      final recentSessionPaths = sessionPaths
          .take(metadataReadLimit)
          .toList(growable: false);
      // Pi's first JSONL record is the complete session header. Reading exactly
      // that line avoids every image, tool result, and transcript-size concern.
      final snapshots = await _readRemoteFileSnapshots(
        session,
        recentSessionPaths,
        maxLines: 1,
      );
      final labels = await _readPiSessionLabels(session, recentSessionPaths);
      final sessions = <ToolSessionInfo>[];
      var hadError = false;

      for (final filePath in recentSessionPaths) {
        final snapshot = snapshots[filePath];
        if (snapshot == null) {
          hadError = true;
          continue;
        }
        try {
          final header = parsePiSessionHeader(snapshot.content);
          final sessionId = header.sessionId?.trim();
          final sessionWorkingDirectory = header.workingDirectory?.trim();
          if (sessionId == null ||
              sessionId.isEmpty ||
              sessionWorkingDirectory == null ||
              sessionWorkingDirectory.isEmpty) {
            hadError = true;
            continue;
          }
          sessions.add(
            ToolSessionInfo(
              toolName: 'Pi',
              sessionId: sessionId,
              workingDirectory: sessionWorkingDirectory,
              // The header timestamp is creation time. File mtime tracks the
              // latest turn and is therefore the picker ordering authority.
              lastActive: snapshot.modifiedAt ?? header.createdAt,
              summary:
                  labels[filePath] ?? 'Pi session ${_truncateId(sessionId)}',
            ),
          );
        } on Object {
          hadError = true;
        }
      }
      final returnedSessions = sortAndLimitDiscoveredSessions(sessions, max);
      DiagnosticsLogService.instance.debug(
        'agent.discovery',
        'pi_complete',
        fields: {
          'connectionId': session.connectionId,
          'candidateCount': sessionPaths.length,
          'snapshotCount': snapshots.length,
          'parsedCount': sessions.length,
          'labelCount': labels.length,
          'returnedCount': returnedSessions.length,
          'previewOnly': previewOnly,
          'hadError': hadError,
        },
      );
      return _ToolDiscoveryResult.success(
        'Pi',
        returnedSessions,
        hadError: hadError,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.discovery',
        'tool_failed',
        fields: {
          'connectionId': session.connectionId,
          'tool': 'pi',
          'errorType': error.runtimeType,
        },
      );
      return const _ToolDiscoveryResult.failure('Pi');
    }
  }

  Future<Map<String, String>> _readPiSessionLabels(
    SshSession session,
    List<String> sessionPaths,
  ) async {
    if (sessionPaths.isEmpty || session.remoteIsWindows) {
      return const <String, String>{};
    }
    try {
      final encodedScript = base64Encode(
        utf8.encode(_piSessionLabelExtractorScript),
      );
      final output = await _exec(
        session,
        r'NODE_BIN=$(command -v node 2>/dev/null); '
        r'[ -n "$NODE_BIN" ] || exit 0; '
        r'"$NODE_BIN" -e '
        '${shellEscapePosix('eval(Buffer.from(process.argv[1], "base64").toString("utf8"))')} '
        '${shellEscapePosix(encodedScript)} '
        '${sessionPaths.map(shellEscapePosix).join(' ')}',
      );
      return parsePiSessionLabelOutput(output);
    } on Object {
      // Session rows remain resumable with their id when label extraction is
      // unavailable, so metadata polish never breaks discovery itself.
      return const <String, String>{};
    }
  }

  /// Lists Pi sessions from buckets for the pane cwd and its Git worktrees.
  ///
  /// Every bucket comes from an explicit directory returned by the repository's
  /// `git worktree list`; there is no global session-store scan.
  Future<List<String>> _listPiSessionPaths(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories, {
    required int scanLimit,
  }) async {
    final buckets = <String>{
      ?piEncodedSessionDirectoryName(workingDirectory),
      ...relatedWorkingDirectories
          .map(piEncodedSessionDirectoryName)
          .whereType<String>(),
    }.toList(growable: false);
    if (buckets.isEmpty) return const <String>[];
    final output = session.remoteIsWindows
        ? await _execWindowsPowerShell(
            session,
            windowsListNewestFilesScript(
              relativeRoot: '.pi/agent/sessions/${buckets.first}',
              additionalRelativeRoots: buckets
                  .skip(1)
                  .map((bucket) => '.pi/agent/sessions/$bucket')
                  .toList(growable: false),
              includeGlobs: const ['*.jsonl'],
              limit: scanLimit,
            ),
          )
        : await _exec(
            session,
            posixListNewestFilesCommand(
              'find ${buckets.map((bucket) => '"\$HOME"/.pi/agent/sessions/${shellEscapePosix(bucket)}').join(' ')} '
              '-maxdepth 1 -name "*.jsonl" -type f',
              scanLimit,
            ),
          );
    return _nonEmptyLines(output).take(scanLimit).toList(growable: false);
  }

  // ── Hermes ─────────────────────────────────────────────────────────────
  // Sessions: SQLite at ~/.hermes/state.db (HERMES_HOME overrides the root).
  // Only `cli`/`tui` sourced roots are listed so gateway chats from Telegram,
  // Discord and friends never appear in a terminal picker.

  Future<_ToolDiscoveryResult> _discoverHermesSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    if (session.remoteIsWindows) {
      return const _ToolDiscoveryResult.success('Hermes', []);
    }
    try {
      final scanLimit = _sessionScanLimit(
        max,
        previewOnly: previewOnly,
        previewMultiplier: 4,
        previewMinimum: 6,
        previewMaximum: 24,
      );
      final scopedDirectories = <String>[
        if (workingDirectory != null && workingDirectory.isNotEmpty)
          workingDirectory,
        ...relatedWorkingDirectories,
      ];
      var output = await _queryHermesDb(
        session,
        scanLimit,
        scopedDirectories: scopedDirectories,
      );
      // Fall back to an unscoped query so a preset pointed at an unused
      // directory still surfaces recent work instead of an empty picker.
      if (output.trim().isEmpty && scopedDirectories.isNotEmpty) {
        output = await _queryHermesDb(session, scanLimit);
      }
      if (output.trim().isEmpty) {
        return const _ToolDiscoveryResult.success('Hermes', []);
      }

      return _ToolDiscoveryResult.success(
        'Hermes',
        sortAndLimitDiscoveredSessions(parseHermesDbOutput(output), max),
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('Hermes');
    }
  }

  Future<String> _queryHermesDb(
    SshSession session,
    int scanLimit, {
    Iterable<String> scopedDirectories = const <String>[],
  }) {
    final directoryScopeClause = buildSqlWorkingDirectoryScopeClause(
      scopedDirectories,
      columnName: 'cwd',
    );
    final sql = StringBuffer()
      ..write(
        "SELECT id, COALESCE(NULLIF(title, ''), display_name, ''), "
        "COALESCE(cwd, ''), "
        'CAST(COALESCE(ended_at, started_at) AS INTEGER) ',
      )
      ..write('FROM sessions ')
      ..write("WHERE source IN ('cli', 'tui') ")
      ..write('AND parent_session_id IS NULL ')
      ..write('AND COALESCE(archived, 0) = 0 ');
    if (directoryScopeClause != null) {
      sql.write('AND ($directoryScopeClause) ');
    }
    sql
      ..write('ORDER BY COALESCE(ended_at, started_at) DESC ')
      ..write('LIMIT $scanLimit;');

    return _exec(
      session,
      r'SEP=$(printf "\037"); sqlite3 -separator "$SEP" '
      r'"${HERMES_HOME:-$HOME/.hermes}/state.db" '
      '${shellEscapePosix(sql.toString())} 2>/dev/null',
    );
  }

  // ── OpenCode ───────────────────────────────────────────────────────────
  // `opencode session list --format json` is the cleanest source of truth.
  // It returns renamed titles, directory, and timestamps. Falls back to
  // the SQLite database or JSON files if the CLI is unavailable.

  Future<_ToolDiscoveryResult> _discoverOpenCodeSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool useAcp = true,
    bool previewOnly = false,
  }) async {
    if (session.remoteIsWindows) {
      return _discoverWindowsOpenCodeSessions(
        session,
        workingDirectory,
        relatedWorkingDirectories,
        max,
        previewOnly: previewOnly,
      );
    }
    try {
      final scanLimit = _sessionScanLimit(
        max,
        previewOnly: previewOnly,
        previewMinimum: 12,
        previewMaximum: 24,
      );
      var hadError = false;
      if (useAcp) {
        final acpSessions = await _discoverAcpSessions(
          session,
          provider: _AcpSessionProvider.openCode,
          toolName: 'OpenCode',
          workingDirectory: workingDirectory,
          relatedWorkingDirectories: relatedWorkingDirectories,
          max: max,
        );
        if (acpSessions != null && acpSessions.sessions.isNotEmpty) {
          return _ToolDiscoveryResult.success(
            'OpenCode',
            sortAndLimitDiscoveredSessions(acpSessions.sessions, max),
            hadError: acpSessions.hadError,
          );
        }
      }

      if (workingDirectory != null && workingDirectory.isNotEmpty) {
        final scopedDbOutput = await _queryOpenCodeDb(
          session,
          scanLimit,
          scopedDirectories: relatedWorkingDirectories,
        );
        if (scopedDbOutput.trim().isNotEmpty) {
          return _ToolDiscoveryResult.success(
            'OpenCode',
            sortAndLimitDiscoveredSessions(
              _parseOpenCodeDbOutput(scopedDbOutput),
              max,
            ),
          );
        }
      }

      // Preferred: use the CLI's own JSON output.
      final cliOutput = await _exec(
        session,
        'opencode session list --format json -n $scanLimit 2>/dev/null',
      );
      if (cliOutput.trim().startsWith('[')) {
        try {
          final sessions = _parseOpenCodeCliJson(cliOutput);
          return _ToolDiscoveryResult.success(
            'OpenCode',
            _scopeSessions(
              sessions,
              workingDirectory,
              relatedWorkingDirectories,
              max,
            ),
          );
        } on Object {
          hadError = true;
          // Fall through to the SQLite fallback.
        }
      }

      // Fallback: query the SQLite database directly.
      // Use ASCII Unit Separator (\x1f) to avoid collision with pipes
      // in session titles or directory paths.
      final dbOutput = await _queryOpenCodeDb(session, scanLimit);
      if (dbOutput.trim().isNotEmpty) {
        final sessions = _parseOpenCodeDbOutput(dbOutput);
        return _ToolDiscoveryResult.success(
          'OpenCode',
          _scopeSessions(
            sessions,
            workingDirectory,
            relatedWorkingDirectories,
            max,
          ),
          hadError: hadError,
        );
      }

      return _ToolDiscoveryResult.success('OpenCode', [], hadError: hadError);
    } on Object {
      return const _ToolDiscoveryResult.failure('OpenCode');
    }
  }

  Future<_ToolDiscoveryResult> _discoverWindowsOpenCodeSessions(
    SshSession session,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max, {
    bool previewOnly = false,
  }) async {
    try {
      final scanLimit = _sessionScanLimit(
        max,
        previewOnly: previewOnly,
        previewMinimum: 12,
        previewMaximum: 24,
      );
      final metadataReadLimit = _sessionMetadataReadLimit(
        max,
        previewOnly: previewOnly,
      );
      var hadError = false;

      final cliOutput = await _execWindowsPowerShell(
        session,
        windowsOpenCodeSessionListScript(scanLimit),
      );
      if (cliOutput.trim().startsWith('[')) {
        try {
          final sessions = _parseOpenCodeCliJson(cliOutput);
          return _ToolDiscoveryResult.success(
            'OpenCode',
            _scopeSessions(
              sessions,
              workingDirectory,
              relatedWorkingDirectories,
              max,
            ),
          );
        } on Object {
          hadError = true;
        }
      }

      final storagePathOutput = await _execWindowsPowerShell(
        session,
        windowsListNewestFilesScript(
          relativeRoot: '.local/share/opencode/storage/session',
          additionalRelativeRoots: const ['opencode/storage/session'],
          includeGlobs: const ['*.json'],
          limit: scanLimit,
          rootEnvironmentVariables: _windowsUserDataRootEnvironmentVariables,
        ),
      );
      if (storagePathOutput.trim().isEmpty) {
        return _ToolDiscoveryResult.success(
          'OpenCode',
          const <ToolSessionInfo>[],
          hadError: hadError,
        );
      }

      final storagePaths = _nonEmptyLines(
        storagePathOutput,
      ).take(metadataReadLimit).toList(growable: false);
      final snapshots = await _readRemoteFileSnapshots(
        session,
        storagePaths,
        maxBytes: _openCodeStorageSessionMetadataMaxBytes,
      );
      final sessions = <ToolSessionInfo>[];
      for (final path in storagePaths) {
        final snapshot = snapshots[path];
        if (snapshot == null) {
          hadError = true;
          continue;
        }
        try {
          final metadata = parseOpenCodeStorageSessionMetadata(
            snapshot.content,
          );
          if (snapshot.content.trim().isNotEmpty && !metadata.parsedAny) {
            hadError = true;
            continue;
          }
          if (metadata.isArchived ||
              (metadata.parentId != null && metadata.parentId!.isNotEmpty)) {
            continue;
          }
          final sessionId = metadata.sessionId;
          if (sessionId == null || sessionId.isEmpty) continue;
          sessions.add(
            ToolSessionInfo(
              toolName: 'OpenCode',
              sessionId: sessionId,
              workingDirectory: metadata.workingDirectory,
              lastActive: metadata.updatedAt ?? snapshot.modifiedAt,
              summary: metadata.summary ?? _truncateId(sessionId),
            ),
          );
        } on Object {
          hadError = true;
        }
      }

      return _ToolDiscoveryResult.success(
        'OpenCode',
        _scopeSessions(
          sessions,
          workingDirectory,
          relatedWorkingDirectories,
          max,
        ),
        hadError: hadError,
      );
    } on Object {
      return const _ToolDiscoveryResult.failure('OpenCode');
    }
  }

  List<ToolSessionInfo> _scopeSessions(
    List<ToolSessionInfo> sessions,
    String? workingDirectory,
    List<String> relatedWorkingDirectories,
    int max,
  ) {
    final scoped = workingDirectory != null && workingDirectory.isNotEmpty
        ? sessions
              .where(
                (info) => matchesDiscoveredSessionWorkingDirectory(
                  workingDirectory,
                  info.workingDirectory,
                  relatedWorkingDirectories: relatedWorkingDirectories,
                ),
              )
              .toList(growable: false)
        : sessions;
    return sortAndLimitDiscoveredSessions(
      scoped.isNotEmpty ? scoped : sessions,
      max,
    );
  }

  List<ToolSessionInfo> _parseOpenCodeCliJson(String raw) {
    final decoded = jsonDecode(raw.trim());
    if (decoded is! List) return const [];

    return decoded.whereType<Map<String, dynamic>>().map((entry) {
      final id = entry['id'] as String? ?? '';
      final title = entry['title'] as String? ?? '';
      final directory = entry['directory'] as String?;

      DateTime? lastActive;
      final updated = entry['updated'];
      if (updated is int) {
        lastActive = _dateTimeFromEpoch(updated);
      } else if (updated is String) {
        lastActive = DateTime.tryParse(updated);
      }

      return ToolSessionInfo(
        toolName: 'OpenCode',
        sessionId: id,
        workingDirectory: directory,
        lastActive: lastActive,
        summary: title.isNotEmpty ? title : _truncateId(id),
      );
    }).toList();
  }

  List<ToolSessionInfo> _parseOpenCodeDbOutput(String output) {
    final sessions = <ToolSessionInfo>[];
    for (final line in output.trim().split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\x1f');
      if (parts.length < 3) continue;

      final id = parts[0].trim();
      final title = parts[1].trim();
      final directory = parts[2].trim();
      DateTime? lastActive;
      if (parts.length >= 4) {
        final ts = int.tryParse(parts[3].trim());
        if (ts != null) {
          lastActive = _dateTimeFromEpoch(ts);
        }
      }

      sessions.add(
        ToolSessionInfo(
          toolName: 'OpenCode',
          sessionId: id,
          workingDirectory: directory.isNotEmpty ? directory : null,
          lastActive: lastActive,
          summary: title.isNotEmpty ? title : _truncateId(id),
        ),
      );
    }
    return sessions;
  }

  Future<String> _queryOpenCodeDb(
    SshSession session,
    int scanLimit, {
    Iterable<String> scopedDirectories = const <String>[],
  }) {
    final directoryScopeClause = buildSqlWorkingDirectoryScopeClause(
      scopedDirectories,
      columnName: 'directory',
    );
    final sql = StringBuffer()
      ..write('SELECT id, title, directory, time_updated ')
      ..write('FROM session ')
      ..write('WHERE parent_id IS NULL ')
      ..write('AND time_archived IS NULL ');
    if (directoryScopeClause != null) {
      sql.write('AND ($directoryScopeClause) ');
    }
    sql
      ..write('ORDER BY time_updated DESC ')
      ..write('LIMIT $scanLimit;');

    return _exec(
      session,
      r'SEP=$(printf "\037"); sqlite3 -separator "$SEP" '
      '~/.local/share/opencode/opencode.db '
      '${shellEscapePosix(sql.toString())} 2>/dev/null',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<String> _exec(SshSession session, String command) {
    final controlChannelBackend = _controlChannelCommandBackend(session);
    if (controlChannelBackend != null) {
      return _execThroughControlChannel(controlChannelBackend, command);
    }
    return session.runQueuedExec(() async {
      final execSession = await openSshExec(
        session.execute(_markCommandDone('$_profileSourcingPrefix$command')),
        _execOutputTimeout,
      );
      try {
        execSession.stderr.drain<void>().ignore();
        return await _readStdoutUntilDoneMarker(execSession);
      } finally {
        execSession.close();
      }
    }, priority: SshExecPriority.low);
  }

  Future<String> _execThroughControlChannel(
    TerminalConnectionBackend backend,
    String command,
  ) async {
    final result = await backend.runClientCommand(
      _markCommandDone('$_profileSourcingPrefix$command'),
      priority: SshExecPriority.low,
    );
    return _stripDoneMarker(result.output);
  }

  /// Runs a PowerShell [script] on a Windows remote and returns its stdout.
  ///
  /// Windows shells cannot evaluate the POSIX command layer, so Windows-specific
  /// discovery builds a PowerShell script (see [windows_remote_powershell]) that
  /// emits the same output format the POSIX parsers expect. The script is wrapped
  /// in a single `powershell -EncodedCommand` invocation, which is valid whether
  /// it runs through a plain SSH exec channel or the MonkeyMux control channel.
  /// No POSIX profile prefix or done marker is added: the plain-exec reader
  /// returns on stream EOF and the control channel returns on process exit.
  Future<String> _execWindowsPowerShell(SshSession session, String script) {
    final command = buildWindowsPowerShellCommand(script);
    final controlChannelBackend = _controlChannelCommandBackend(session);
    if (controlChannelBackend != null) {
      return controlChannelBackend
          .runClientCommand(command, priority: SshExecPriority.low)
          .then((result) => result.output);
    }
    return session.runQueuedExec(() async {
      final execSession = await openSshExec(
        session.execute(command),
        _execOutputTimeout,
      );
      try {
        execSession.stderr.drain<void>().ignore();
        return await _readStdoutUntilDoneMarker(execSession);
      } finally {
        execSession.close();
      }
    }, priority: SshExecPriority.low);
  }

  TerminalConnectionBackend? _controlChannelCommandBackend(SshSession session) {
    final terminalBackendService = _terminalBackendService;
    if (terminalBackendService == null) return null;
    final backend = terminalBackendService.resolve(session);
    return backend.capabilities.clientCommandsUseControlChannel
        ? backend
        : null;
  }

  static String _markCommandDone(String command) =>
      '{ $command; __flutty_agent_discovery_exec_status__=\$?; '
      'printf ${shellEscapePosix('\n$_execDoneMarker:%s\n')} '
      r'"$__flutty_agent_discovery_exec_status__"; }';

  static String _stripDoneMarker(String output) {
    final markerMatch = _execDoneMarkerLinePattern
        .allMatches(output)
        .lastOrNull;
    return markerMatch == null
        ? output
        : output.substring(0, markerMatch.start);
  }

  static Future<String> _readStdoutUntilDoneMarker(
    SSHSession execSession,
  ) async => (await readCommandOutputUntilMarker(
    execSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .timeout(_execOutputTimeout),
    _execDoneMarker,
    allowPartialOnTimeout: true,
  )).output;

  List<String?> _acpSessionListWorkingDirectories(
    String? workingDirectory,
    Iterable<String> relatedWorkingDirectories,
  ) {
    final directories = <String>{};
    for (final candidate in <String?>[
      workingDirectory,
      ...relatedWorkingDirectories,
    ]) {
      final trimmed = _trimWorkingDirectory(candidate);
      if (trimmed == null) continue;
      directories
        ..add(trimmed)
        ..add(normalizeWorkingDirectoryForComparison(trimmed));
    }
    return directories.isEmpty
        ? const <String?>[null]
        : directories.toList(growable: false);
  }

  String _buildAcpSessionListCommand(
    _AcpSessionProvider provider,
    String? workingDirectory,
  ) => switch (provider) {
    _AcpSessionProvider.copilot =>
      'copilot --acp --no-color --no-auto-update --log-level error',
    _AcpSessionProvider.openCode =>
      'opencode acp --log-level ERROR'
          '${workingDirectory == null || workingDirectory.isEmpty ? '' : ' --cwd ${shellEscapePosix(workingDirectory)}'}',
  };

  Future<_AcpSessionListResult?> _discoverAcpSessions(
    SshSession session, {
    required _AcpSessionProvider provider,
    required String toolName,
    required String? workingDirectory,
    required List<String> relatedWorkingDirectories,
    required int max,
  }) async {
    if (session.remoteIsWindows) {
      // ACP discovery spawns the provider CLI and speaks a stdio JSON-RPC
      // protocol through a POSIX profile-sourcing wrapper, which does not work
      // on Windows shells. File-based discovery covers these providers instead.
      return null;
    }
    if (_controlChannelCommandBackend(session) != null) {
      return null;
    }
    final scopedWorkingDirectories = _acpSessionListWorkingDirectories(
      workingDirectory,
      relatedWorkingDirectories,
    );
    try {
      return await _listAcpSessions(
        session,
        provider: provider,
        toolName: toolName,
        workingDirectory: workingDirectory,
        listWorkingDirectories: scopedWorkingDirectories,
        max: max,
      );
    } on Object {
      return null;
    }
  }

  Future<_AcpSessionListResult?> _listAcpSessions(
    SshSession session, {
    required _AcpSessionProvider provider,
    required String toolName,
    required String? workingDirectory,
    required List<String?> listWorkingDirectories,
    required int max,
  }) => session.runQueuedExec(() async {
    final execSession = await openSshExec(
      session.execute(
        '$_profileSourcingPrefix${_buildAcpSessionListCommand(provider, workingDirectory)}',
      ),
      _acpResponseTimeout,
    );
    var nextRequestId = 0;
    final connection = AcpJsonRpcConnection(
      transport: AcpSshExecTransport(execSession),
      defaultRequestTimeout: _acpResponseTimeout,
      requestIdFactory: () => nextRequestId++,
    );
    final client = AcpClient(connection);
    try {
      final initialization = await client.initialize(
        capabilities: const AcpClientCapabilities(
          fileSystem: AcpFileSystemCapabilities(),
          booleanConfigOptions: false,
        ),
        timeout: _acpResponseTimeout,
      );
      if (!initialization.agentCapabilities.session.list) {
        return null;
      }

      final sessionsById = <String, ToolSessionInfo>{};
      var hadError = false;
      for (final listWorkingDirectory in listWorkingDirectories) {
        String? cursor;
        final seenCursors = <String>{};
        do {
          late final AcpSessionListResult listResult;
          try {
            listResult = await client.listSessions(
              cwd: listWorkingDirectory,
              cursor: cursor,
              timeout: _acpResponseTimeout,
            );
          } on AcpProtocolException {
            hadError = true;
            break;
          } on AcpRemoteException {
            hadError = true;
            break;
          }
          for (final sessionInfo in listResult.sessions) {
            final info = ToolSessionInfo(
              toolName: toolName,
              sessionId: sessionInfo.sessionId,
              workingDirectory: sessionInfo.cwd.isEmpty
                  ? null
                  : sessionInfo.cwd,
              lastActive: _parseDateTimeValue(sessionInfo.updatedAt),
              summary:
                  sessionInfo.title ??
                  _truncateSessionIdValue(sessionInfo.sessionId),
            );
            sessionsById.putIfAbsent(info.sessionId, () => info);
          }
          cursor = listResult.nextCursor;
          if (cursor != null && !seenCursors.add(cursor)) {
            hadError = true;
            break;
          }
        } while (cursor != null && sessionsById.length < max);
      }

      return _AcpSessionListResult(
        sessions: sortAndLimitDiscoveredSessions(sessionsById.values, max),
        hadError: hadError,
      );
    } finally {
      await client.close();
    }
  }, priority: SshExecPriority.low);

  Future<List<String>> _listCopilotWorkspacePaths(
    SshSession session,
    int scanLimit,
    Iterable<String> relatedWorkingDirectories,
  ) async {
    if (session.remoteIsWindows) {
      // Windows shells can't run the POSIX find/grep scoping; fall back to the
      // newest workspace.yaml files across all session-state dirs. The
      // working-directory scoping is only a narrowing optimization, so this
      // still surfaces recent Copilot sessions correctly.
      final output = await _execWindowsPowerShell(
        session,
        windowsListNewestFilesScript(
          relativeRoot: '.copilot/session-state',
          includeGlobs: const ['workspace.yaml'],
          limit: scanLimit,
        ),
      );
      return _nonEmptyLines(output).toList(growable: false);
    }

    final scopedDirectories = relatedWorkingDirectories
        .map(_trimWorkingDirectory)
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final globalCommand = posixListNewestFilesCommand(
      'find ~/.copilot/session-state -mindepth 2 -maxdepth 2 '
      '-name workspace.yaml -type f',
      scanLimit,
    );
    if (scopedDirectories.isEmpty) {
      final output = await _exec(session, globalCommand);
      return _nonEmptyLines(output).toList(growable: false);
    }

    final scopedCommand = StringBuffer()
      ..write(r'pattern_file=$(mktemp); ')
      ..writeAll(
        scopedDirectories.map(
          (directory) =>
              'printf "%s\\n" ${shellEscapePosix('cwd: $directory')} '
              r'>> "$pattern_file"; ',
        ),
      )
      ..write(
        r'matching_paths=$(grep -l -x -F -f "$pattern_file" '
        '~/.copilot/session-state/*/workspace.yaml 2>/dev/null); '
        r'rm -f "$pattern_file"; '
        r'if [ -n "$matching_paths" ]; then '
        r'printf "%s\n" "$matching_paths" '
        '| while IFS= read -r path; do '
        r'[ -n "$path" ] && printf "%s\0" "$path"; '
        'done | xargs -0 sh -c ${shellEscapePosix(_posixFileTimestampsScript)} '
        'sh 2>/dev/null; fi',
      );

    final scopedOutput = await _exec(
      session,
      _newestFilePathsCommand('{ $scopedCommand; }', scanLimit),
    );
    final output = scopedOutput.trim().isNotEmpty
        ? scopedOutput
        : await _exec(session, globalCommand);
    return _nonEmptyLines(output).toList(growable: false);
  }

  Future<Map<String, _RemoteFileSnapshot>> _readRemoteFileSnapshots(
    SshSession session,
    Iterable<String> paths, {
    int? maxLines,
    int? maxBytes,
    bool tail = false,
  }) async {
    final uniquePaths = paths
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniquePaths.isEmpty) {
      return const <String, _RemoteFileSnapshot>{};
    }
    final snapshots = <String, _RemoteFileSnapshot>{};
    if (session.remoteIsWindows) {
      for (final batchPaths in windowsSnapshotPathBatches(uniquePaths)) {
        final output = await _execWindowsPowerShell(
          session,
          windowsFileSnapshotScript(
            batchPaths,
            maxLines: maxLines,
            maxBytes: maxBytes,
            tail: tail,
          ),
        );
        snapshots.addAll(await _parseRemoteFileSnapshotOutput(output));
      }
      return snapshots;
    }
    for (
      var start = 0;
      start < uniquePaths.length;
      start += _remoteFileSnapshotBatchSize
    ) {
      final batchPaths = uniquePaths
          .skip(start)
          .take(_remoteFileSnapshotBatchSize)
          .toList(growable: false);
      final command = StringBuffer()
        ..write(r'SEP=$(printf "\037"); ')
        ..write(
          r'STAT_BIN=/usr/bin/stat; [ -x "$STAT_BIN" ] || STAT_BIN=stat; ',
        )
        ..write(
          r'HEAD_BIN=/usr/bin/head; [ -x "$HEAD_BIN" ] || HEAD_BIN=head; ',
        )
        ..write(
          r'BASE64_BIN=/usr/bin/base64; [ -x "$BASE64_BIN" ] || BASE64_BIN=base64; ',
        )
        ..write(r'TR_BIN=/usr/bin/tr; [ -x "$TR_BIN" ] || TR_BIN=tr; ')
        ..write(r'CAT_BIN=/bin/cat; [ -x "$CAT_BIN" ] || CAT_BIN=cat; ')
        ..write(r'SED_BIN=/usr/bin/sed; [ -x "$SED_BIN" ] || SED_BIN=sed; ')
        ..write(
          r'TAIL_BIN=/usr/bin/tail; [ -x "$TAIL_BIN" ] || TAIL_BIN=tail; ',
        )
        ..write('for path in ')
        ..write(batchPaths.map(shellEscapePosix).join(' '))
        ..write(r'; do [ -f "$path" ] || continue; ')
        ..write(
          r'mtime=$( ($STAT_BIN -c %Y "$path" 2>/dev/null || '
          r'$STAT_BIN -f %m "$path" 2>/dev/null) | $HEAD_BIN -n 1); ',
        )
        ..write(r'printf "%s%s%s%s" "$path" "$SEP" "${mtime:-}" "$SEP"; ');

      if (maxBytes != null) {
        command.write(
          r'$HEAD_BIN -c '
          '$maxBytes'
          r' "$path" 2>/dev/null | $BASE64_BIN | $TR_BIN -d "\n"; ',
        );
      } else if (maxLines == null) {
        command.write(
          r'$CAT_BIN "$path" 2>/dev/null | $BASE64_BIN | $TR_BIN -d "\n"; ',
        );
      } else {
        command.write(
          tail
              ? r'$TAIL_BIN -n '
                    '$maxLines'
                    r' "$path" 2>/dev/null | $BASE64_BIN | $TR_BIN -d "\n"; '
              : r'''$SED_BIN -n '1,'''
                    '$maxLines'
                    r'''p' "$path" 2>/dev/null | $BASE64_BIN | $TR_BIN -d "\n"; ''',
        );
      }

      command.write(r'''printf "\n"; done''');

      final output = await _exec(session, command.toString());
      snapshots.addAll(await _parseRemoteFileSnapshotOutput(output));
    }
    return snapshots;
  }

  Future<Map<String, String>> _findClaudeSessionFiles(
    SshSession session,
    Iterable<String> sessionIds,
  ) async {
    final uniqueSessionIds = sessionIds
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueSessionIds.isEmpty) {
      return const <String, String>{};
    }

    final nameFilters = uniqueSessionIds
        .map((id) => '-name ${shellEscapePosix('$id.jsonl')}')
        .join(' -o ');
    final output = session.remoteIsWindows
        ? await _execWindowsPowerShell(
            session,
            windowsFindFilesByNameScript(
              relativeRoot: '.claude/projects',
              names: uniqueSessionIds
                  .map((id) => '$id.jsonl')
                  .toList(growable: false),
            ),
          )
        : await _exec(
            session,
            'find ~/.claude/projects -type f \\( $nameFilters \\) '
            '-print 2>/dev/null',
          );

    final filesById = <String, String>{};
    for (final rawLine in output.split('\n')) {
      final path = rawLine.trim();
      if (path.isEmpty) continue;
      final fileName = path.split('/').last;
      if (!fileName.endsWith('.jsonl')) continue;
      final sessionId = fileName.substring(
        0,
        fileName.length - '.jsonl'.length,
      );
      filesById.putIfAbsent(sessionId, () => path);
    }
    return filesById;
  }

  DateTime _dateTimeFromEpoch(int epoch) => _dateTimeFromEpochValue(epoch);

  /// Expands shell-home shorthand before exact session-store lookup.
  ///
  /// Agent stores such as Pi encode the absolute cwd in their directory name.
  /// Quoting a host preset like `~/Code/project` for a remote command preserves
  /// the tilde literally, producing a bucket that can never exist. Resolve only
  /// the current user's `~` form through the remote environment; all other
  /// paths remain untouched.
  Future<String?> _resolveRemoteHomeWorkingDirectory(
    SshSession session,
    String? workingDirectory,
  ) async {
    final trimmed = _trimWorkingDirectory(workingDirectory);
    if (trimmed == null || session.remoteIsWindows) return trimmed;
    if (trimmed != '~' && !trimmed.startsWith('~/')) return trimmed;

    const marker = '__monkeyssh_agent_discovery_home__:';
    try {
      final output = await _exec(
        session,
        r'''[ -n "${HOME:-}" ] && printf '__monkeyssh_agent_discovery_home__:%s\n' "$HOME"''',
      );
      final home = const LineSplitter()
          .convert(output)
          .where((line) => line.startsWith(marker))
          .map((line) => line.substring(marker.length).trim())
          .where((line) => line.isNotEmpty)
          .firstOrNull;
      if (home == null) return trimmed;
      return trimmed == '~' ? home : '$home/${trimmed.substring(2)}';
    } on Object {
      return trimmed;
    }
  }

  Future<List<String>> _resolveRelatedWorkingDirectoriesCached(
    SshSession session,
    String? workingDirectory,
  ) {
    final key = _AgentSessionDiscoveryScopeKey.fromSession(
      session,
      workingDirectory: workingDirectory,
    );
    if (key.workingDirectory == null) {
      return Future<List<String>>.value(const <String>[]);
    }

    _pruneExpiredCacheEntries();
    final cached = _relatedWorkingDirectoriesCache[key];
    if (cached != null) {
      return Future<List<String>>.value(cached.directories);
    }

    final inFlight = _inFlightRelatedWorkingDirectories[key];
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<List<String>> future;
    future = _resolveRelatedWorkingDirectories(session, key.workingDirectory)
        .then((directories) {
          if (identical(_inFlightRelatedWorkingDirectories[key], future)) {
            _relatedWorkingDirectoriesCache[key] =
                _CachedRelatedWorkingDirectories(
                  directories: directories,
                  cachedAt: _now(),
                );
          }
          return directories;
        })
        .whenComplete(() {
          if (identical(_inFlightRelatedWorkingDirectories[key], future)) {
            _inFlightRelatedWorkingDirectories.remove(key);
          }
        });
    _inFlightRelatedWorkingDirectories[key] = future;
    return future;
  }

  Future<List<String>> _resolveRelatedWorkingDirectories(
    SshSession session,
    String? workingDirectory,
  ) async {
    final trimmedWorkingDirectory = _trimWorkingDirectory(workingDirectory);
    if (trimmedWorkingDirectory == null) return const <String>[];

    if (session.remoteIsWindows) {
      // The related-directory probe uses a POSIX `git ... worktree list`
      // pipeline that Windows shells cannot run. Use the pure-Dart heuristic
      // expansion instead of firing a failing exec on every discovery.
      return buildRelatedWorkingDirectories(trimmedWorkingDirectory);
    }

    try {
      final gitOutput = await _exec(
        session,
        r'ROOT=$(git -C '
        '${shellEscapePosix(trimmedWorkingDirectory)}'
        ' rev-parse --show-toplevel 2>/dev/null) && '
        r'[ -n "$ROOT" ] && printf "root=%s\n" "$ROOT" && '
        'git -C '
        '${shellEscapePosix(trimmedWorkingDirectory)}'
        ' worktree list --porcelain 2>/dev/null',
      );
      if (gitOutput.trim().isEmpty) {
        return buildRelatedWorkingDirectories(trimmedWorkingDirectory);
      }

      String? gitRoot;
      final worktreeLines = StringBuffer();
      for (final line in const LineSplitter().convert(gitOutput)) {
        if (gitRoot == null && line.startsWith('root=')) {
          gitRoot = _trimWorkingDirectory(line.substring('root='.length));
          continue;
        }
        worktreeLines.writeln(line);
      }

      return buildRelatedWorkingDirectories(
        trimmedWorkingDirectory,
        gitRoot: gitRoot,
        gitWorktreeRoots: parseGitWorktreeRoots(worktreeLines.toString()),
      );
    } on Object {
      return buildRelatedWorkingDirectories(trimmedWorkingDirectory);
    }
  }

  List<ToolSessionInfo> _limitDiscoveredSessionsPerTool(
    List<ToolSessionInfo> sessions,
    int maxPerTool,
  ) {
    final groupedSessions = <String, List<ToolSessionInfo>>{};
    for (final session in sessions) {
      groupedSessions
          .putIfAbsent(session.toolName, () => <ToolSessionInfo>[])
          .add(session);
    }

    final limited = <ToolSessionInfo>[];
    for (final toolSessions in groupedSessions.values) {
      toolSessions.sort(compareDiscoveredSessionsByRecency);
      limited.addAll(toolSessions.take(maxPerTool));
    }
    limited.sort(compareDiscoveredSessionsByRecency);
    return limited;
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static bool _matchesWorkingDirectory(
    String expectedDirectory,
    String? sessionDirectory,
  ) {
    if (sessionDirectory == null || sessionDirectory.isEmpty) return false;
    return sessionDirectory == expectedDirectory ||
        _pathLastSegment(sessionDirectory) ==
            _pathLastSegment(expectedDirectory);
  }

  static String _truncateId(String id) => _truncateSessionIdValue(id);
}

@immutable
class _AgentSessionDiscoveryKey {
  const _AgentSessionDiscoveryKey({
    required this.scopeKey,
    required this.maxPerTool,
  });

  factory _AgentSessionDiscoveryKey.fromSession(
    SshSession session, {
    required String? workingDirectory,
    required int maxPerTool,
    String? toolName,
  }) => _AgentSessionDiscoveryKey(
    scopeKey: _AgentSessionDiscoveryScopeKey.fromSession(
      session,
      workingDirectory: workingDirectory,
      toolName: toolName,
    ),
    maxPerTool: maxPerTool,
  );

  final _AgentSessionDiscoveryScopeKey scopeKey;
  final int maxPerTool;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AgentSessionDiscoveryKey &&
          scopeKey == other.scopeKey &&
          maxPerTool == other.maxPerTool;

  @override
  int get hashCode => Object.hash(scopeKey, maxPerTool);
}

@immutable
class _AgentSessionDiscoveryScopeKey {
  const _AgentSessionDiscoveryScopeKey({
    required this.hostId,
    required this.hostname,
    required this.port,
    required this.username,
    required this.workingDirectory,
    required this.toolName,
  });

  factory _AgentSessionDiscoveryScopeKey.fromSession(
    SshSession session, {
    required String? workingDirectory,
    String? toolName,
  }) => _AgentSessionDiscoveryScopeKey(
    hostId: session.hostId,
    hostname: session.config.hostname,
    port: session.config.port,
    username: session.config.username,
    workingDirectory: _trimWorkingDirectory(workingDirectory),
    toolName: toolName,
  );

  final int hostId;
  final String hostname;
  final int port;
  final String username;
  final String? workingDirectory;
  final String? toolName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AgentSessionDiscoveryScopeKey &&
          hostId == other.hostId &&
          hostname == other.hostname &&
          port == other.port &&
          username == other.username &&
          workingDirectory == other.workingDirectory &&
          toolName == other.toolName;

  @override
  int get hashCode =>
      Object.hash(hostId, hostname, port, username, workingDirectory, toolName);
}

class _CachedDiscoveryResult {
  const _CachedDiscoveryResult({required this.result, required this.cachedAt});

  final DiscoveredSessionsResult result;
  final DateTime cachedAt;
}

class _CachedRelatedWorkingDirectories {
  const _CachedRelatedWorkingDirectories({
    required this.directories,
    required this.cachedAt,
  });

  final List<String> directories;
  final DateTime cachedAt;
}

class _ToolDiscoveryResult {
  const _ToolDiscoveryResult.success(
    this.toolName,
    this.sessions, {
    this.hadError = false,
  });

  const _ToolDiscoveryResult.failure(this.toolName)
    : sessions = const <ToolSessionInfo>[],
      hadError = true;

  final String toolName;
  final List<ToolSessionInfo> sessions;
  final bool hadError;
}

class _IndexedToolDiscoveryResult {
  const _IndexedToolDiscoveryResult(this.index, this.result);

  final int index;
  final _ToolDiscoveryResult result;
}

enum _AcpSessionProvider { copilot, openCode }

class _AcpSessionListResult {
  const _AcpSessionListResult({required this.sessions, required this.hadError});

  final List<ToolSessionInfo> sessions;
  final bool hadError;
}

class _CodexSessionIndexResult {
  const _CodexSessionIndexResult({
    required this.entries,
    this.hadError = false,
  });

  final Map<String, _CodexSessionIndexEntry> entries;
  final bool hadError;
}

class _CodexSessionIndexEntry {
  const _CodexSessionIndexEntry({this.threadName, this.updatedAt});

  final String? threadName;
  final DateTime? updatedAt;
}

class _AntigravityHistoryEntry {
  const _AntigravityHistoryEntry({
    this.summary,
    this.workingDirectory,
    this.updatedAt,
  });

  final String? summary;
  final String? workingDirectory;
  final DateTime? updatedAt;
}

class _RemoteFileSnapshot {
  const _RemoteFileSnapshot({required this.content, this.modifiedAt});

  final String content;
  final DateTime? modifiedAt;
}

Future<Map<String, _RemoteFileSnapshot>> _parseRemoteFileSnapshotOutput(
  String output,
) {
  if (output.length < 8192) {
    return Future<Map<String, _RemoteFileSnapshot>>.value(
      _parseRemoteFileSnapshotOutputSync(output),
    );
  }
  return compute(_parseRemoteFileSnapshotOutputSync, output);
}

Map<String, _RemoteFileSnapshot> _parseRemoteFileSnapshotOutputSync(
  String output,
) {
  final snapshots = <String, _RemoteFileSnapshot>{};
  for (final line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('\x1f');
    if (parts.length < 3) continue;

    final path = parts[0].trim();
    if (path.isEmpty) continue;

    DateTime? modifiedAt;
    final epoch = int.tryParse(parts[1].trim());
    if (epoch != null && epoch > 0) {
      modifiedAt = _dateTimeFromEpochValue(epoch);
    }

    try {
      final content = utf8.decode(base64Decode(parts[2].trim()));
      snapshots[path] = _RemoteFileSnapshot(
        content: content,
        modifiedAt: modifiedAt,
      );
    } on FormatException {
      continue;
    }
  }
  return snapshots;
}

Map<String, _AntigravityHistoryEntry> _parseAntigravityHistoryJsonl(
  String output,
) {
  final entries = <String, _AntigravityHistoryEntry>{};
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final decoded = _tryDecodeJsonObject(line);
    if (decoded == null) continue;
    final conversationId = _readStringField(decoded, 'conversationId');
    if (conversationId == null || conversationId.isEmpty) continue;
    entries[conversationId] = _AntigravityHistoryEntry(
      summary: _readStringField(decoded, 'display'),
      workingDirectory: _readStringField(decoded, 'workspace'),
      updatedAt: _parseDateTimeValue(decoded['timestamp']),
    );
  }
  return entries;
}

String _fileNameWithoutExtension(String path) {
  final fileName = path
      .split(RegExp(r'[/\\]'))
      .where((segment) => segment.isNotEmpty)
      .lastOrNull;
  if (fileName == null || fileName.isEmpty) return '';
  final dotIndex = fileName.lastIndexOf('.');
  return dotIndex <= 0 ? fileName : fileName.substring(0, dotIndex);
}

String? _antigravityAnnotationPathForConversationFile(String path) {
  final normalizedPath = path.replaceAll(_backslashPattern, '/');
  final match = RegExp(
    r'^(.*)/(?:conversations|implicit)/([^/]+)\.pb$',
  ).firstMatch(normalizedPath);
  if (match == null) return null;
  return '${match.group(1)!}/annotations/${match.group(2)!}.pbtxt';
}

String? _extractAntigravityAnnotationTitle(String raw) {
  final match = RegExp(r'title\s*:\s*"((?:\\.|[^"\\])*)"').firstMatch(raw);
  if (match == null) return null;
  try {
    final decoded = jsonDecode('"${match.group(1)}"');
    if (decoded is String && decoded.trim().isNotEmpty) {
      return _summarizeSessionText(decoded);
    }
  } on FormatException {
    return null;
  }
  return null;
}

// ── Windows PowerShell discovery command builders ──────────────────────────
// Windows remotes run cmd.exe/PowerShell, which cannot evaluate the POSIX
// find/tail/stat command layer. These builders emit PowerShell scripts (run via
// `powershell -EncodedCommand`; see windows_remote_powershell.dart) that produce
// the exact output formats the existing POSIX parsers expect: newest-first
// forward-slash paths, and `path\x1f mtime \x1f base64` snapshot lines. Most
// provider state lives below `%USERPROFILE%`, while app-data based tools may use
// `%LOCALAPPDATA%` or `%APPDATA%`; the list helpers support all three roots.

String _windowsPowerShellArrayLiteral(Iterable<String> values) =>
    values.map(powerShellSingleQuote).join(',');

String _windowsEnvironmentVariableArrayLiteral(Iterable<String> names) {
  final references = <String>[];
  for (final name in names) {
    final normalized = name.trim().toUpperCase();
    if (!RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(normalized)) {
      throw ArgumentError.value(name, 'names', 'Invalid environment variable');
    }
    references.add('\$env:$normalized');
  }
  return references.join(',');
}

/// Builds a PowerShell boolean expression that is true when `$__flN` (a file
/// leaf name) matches any of [globs] via `-like`. Used instead of
/// `Get-ChildItem -Include`, which is silently ignored with `-LiteralPath` on
/// Windows PowerShell 5.1 and would return every file.
String _windowsNameLikeCondition(List<String> globs) => globs
    .map(
      (glob) =>
          r'($__flN -like '
          '${powerShellSingleQuote(glob)})',
    )
    .join(' -or ');

const _posixFileTimestampsScript =
    'if stat -c %Y / >/dev/null 2>&1; then '
    "stat -c '%Y\t%n' \"\$@\"; "
    "else stat -f '%m\t%N' \"\$@\"; fi";

String _newestFilePathsCommand(String timestampsCommand, int limit) =>
    '$timestampsCommand | LC_ALL=C sort -t "\t" -k1,1nr | '
    'head -n $limit | cut -f2-';

/// Globally sorts timestamp/path records from every batch of [findCommand].
@visibleForTesting
String posixListNewestFilesCommand(
  String findCommand,
  int limit,
) => _newestFilePathsCommand(
  '{ $findCommand -exec sh -c ${shellEscapePosix(_posixFileTimestampsScript)} '
  'sh {} + 2>/dev/null || true; }',
  limit,
);

/// Builds a PowerShell script listing files under [relativeRoot] below one or
/// more Windows user roots that match any of [includeGlobs], newest first,
/// limited to [limit].
///
/// Emits one forward-slash path per line, mirroring
/// [posixListNewestFilesCommand]. When
/// [pathLikeFilters] is non-empty only files whose forward-slash path matches at
/// least one `-like` pattern are emitted (mirroring `find ... -path <pattern>`).
/// [additionalRelativeRoots] and [rootEnvironmentVariables] let callers include
/// `%LOCALAPPDATA%` / `%APPDATA%` layouts without duplicating script builders.
/// When [overrideRootEnvironmentVariable] is non-empty on the remote, its
/// [overrideRelativeRoot] replaces all fallback roots instead of supplementing
/// them. This mirrors `${VAR:-fallback}` semantics on POSIX.
@visibleForTesting
String windowsListNewestFilesScript({
  required String relativeRoot,
  required List<String> includeGlobs,
  required int limit,
  List<String> additionalRelativeRoots = const <String>[],
  List<String> pathLikeFilters = const <String>[],
  List<String> rootEnvironmentVariables =
      _windowsUserProfileRootEnvironmentVariables,
  String? overrideRootEnvironmentVariable,
  String? overrideRelativeRoot,
}) {
  if ((overrideRootEnvironmentVariable == null) !=
      (overrideRelativeRoot == null)) {
    throw ArgumentError(
      'overrideRootEnvironmentVariable and overrideRelativeRoot must be set together',
    );
  }
  final relativeRootsLiteral = _windowsPowerShellArrayLiteral([
    relativeRoot,
    ...additionalRelativeRoots,
  ]);
  final rootEnvironmentVariablesLiteral =
      _windowsEnvironmentVariableArrayLiteral(rootEnvironmentVariables);
  final body = StringBuffer()
    ..write('\$__flRelRoots=@($relativeRootsLiteral);')
    ..write('\$__flRootBases=@($rootEnvironmentVariablesLiteral);');
  if (overrideRootEnvironmentVariable != null) {
    final overrideRootLiteral = _windowsEnvironmentVariableArrayLiteral([
      overrideRootEnvironmentVariable,
    ]);
    body
      ..write('\$__flOverrideBase=$overrideRootLiteral;')
      ..write(r'if(![string]::IsNullOrWhiteSpace([string]$__flOverrideBase)){')
      ..write(
        '\$__flRelRoots=@(${powerShellSingleQuote(overrideRelativeRoot!)});',
      )
      ..write(r'$__flRootBases=@($__flOverrideBase)}');
  }
  body
    ..write(r'$__flRoots=@();')
    ..write(r'foreach($__flBase in $__flRootBases){')
    ..write(r'if([string]::IsNullOrWhiteSpace([string]$__flBase)){continue}')
    ..write(r'foreach($__flRelRoot in $__flRelRoots){')
    ..write(r'$__flRoots+=(Join-Path $__flBase $__flRelRoot)}}')
    ..write(r'$__flItems=@();foreach($__flRoot in $__flRoots){')
    ..write(
      r'$__flItems+=@(Get-ChildItem -LiteralPath $__flRoot -Recurse -File ',
    )
    ..write(
      r'2>$null|Where-Object {$__flN=$_.Name;$__flFn=($_.FullName -replace ',
    )
    ..write(r"'\\','/');(")
    ..write(_windowsNameLikeCondition(includeGlobs));
  if (pathLikeFilters.isNotEmpty) {
    body
      ..write(' -and (')
      ..write(
        pathLikeFilters
            .map(
              (f) =>
                  r'($__flFn -like '
                  '${powerShellSingleQuote(f)})',
            )
            .join(' -or '),
      )
      ..write(')');
  }
  body
    ..write(')})};')
    ..write(r'$__flItems=@($__flItems|Sort-Object LastWriteTimeUtc -Descending')
    ..write('|Select-Object -First ')
    ..write('$limit')
    ..write(');')
    ..write(r'$__flSeen=@{};')
    ..write(r'foreach($__flF in $__flItems){')
    ..write(r"$__flPath=($__flF.FullName -replace '\\','/');")
    ..write(r'if($__flSeen.ContainsKey($__flPath)){continue}')
    ..write(r'$__flSeen[$__flPath]=$true;')
    ..write(r'[void]$__flOut.Append($__flPath);')
    ..write(r'[void]$__flOut.Append([char]10)}');
  return powerShellUtf8OutputScript(body.toString());
}

/// Builds a PowerShell script listing files under `%USERPROFILE%\<relativeRoot>`
/// whose leaf name exactly matches any of [names]. Emits one forward-slash path
/// per line, mirroring `find <root> -type f \( -name a -o -name b \) -print`.
@visibleForTesting
String windowsFindFilesByNameScript({
  required String relativeRoot,
  required List<String> names,
}) {
  final body = StringBuffer()
    ..write(r'$__flRoot=Join-Path $env:USERPROFILE ')
    ..write(powerShellSingleQuote(relativeRoot))
    ..write(';')
    ..write(
      r'$__flItems=@(Get-ChildItem -LiteralPath $__flRoot -Recurse -File '
      r'2>$null|Where-Object {$__flN=$_.Name;(',
    )
    ..write(_windowsNameLikeCondition(names))
    ..write(')});')
    ..write(r'foreach($__flF in $__flItems){')
    ..write(r"[void]$__flOut.Append(($__flF.FullName -replace '\\','/'));")
    ..write(r'[void]$__flOut.Append([char]10)}');
  return powerShellUtf8OutputScript(body.toString());
}

/// Builds a PowerShell script that emits the last [lines] lines of
/// `%USERPROFILE%\<relativePath>`, mirroring `tail -n <lines> <file>`.
@visibleForTesting
String windowsTailFileScript({
  required String relativePath,
  required int lines,
}) {
  final body = StringBuffer()
    ..write(r'$__flPath=Join-Path $env:USERPROFILE ')
    ..write(powerShellSingleQuote(relativePath))
    ..write(';')
    ..write(r'if(Test-Path -LiteralPath $__flPath -PathType Leaf){')
    ..write(r'$__flLines=@(Get-Content -LiteralPath $__flPath -Tail ')
    ..write('$lines')
    ..write(r' -Encoding UTF8 2>$null);')
    ..write(r'foreach($__flL in $__flLines){[void]$__flOut.Append($__flL);')
    ..write(r'[void]$__flOut.Append([char]10)}}');
  return powerShellUtf8OutputScript(body.toString());
}

/// Builds a PowerShell script that invokes OpenCode's native session-list
/// command when the CLI is available on a Windows remote.
@visibleForTesting
String windowsOpenCodeSessionListScript(int limit) {
  final body = StringBuffer()
    ..write('if(Get-Command opencode -ErrorAction SilentlyContinue){')
    ..write(r'$__flLines=@(& opencode session list --format json -n ')
    ..write('$limit')
    ..write(r' 2>$null);')
    ..write(r'if($LASTEXITCODE -eq 0 -or $__flLines.Count -gt 0){')
    ..write(r'foreach($__flL in $__flLines){')
    ..write(r'[void]$__flOut.Append([string]$__flL);')
    ..write(r'[void]$__flOut.Append([char]10)}}}');
  return powerShellUtf8OutputScript(body.toString());
}

/// Splits [paths] into snapshot batches whose generated PowerShell stays well
/// under cmd.exe's ~8191-character command-line limit once wrapped as
/// `powershell -EncodedCommand` (base64 of the UTF-16LE script roughly triples
/// its length, and Windows OpenSSH runs exec commands via `cmd.exe /c`). Each
/// batch also respects [_remoteFileSnapshotBatchSize].
@visibleForTesting
List<List<String>> windowsSnapshotPathBatches(List<String> paths) {
  // Keep the summed quoted-path length per batch small enough that the
  // fixed-overhead script (~700 chars) plus paths stays under ~2600 chars, so
  // its base64 payload stays well below 8191.
  const maxBatchPathChars = 1800;
  final batches = <List<String>>[];
  var current = <String>[];
  var currentChars = 0;
  for (final path in paths) {
    final pathChars = path.length + 4;
    if (current.isNotEmpty &&
        (current.length >= _remoteFileSnapshotBatchSize ||
            currentChars + pathChars > maxBatchPathChars)) {
      batches.add(current);
      current = <String>[];
      currentChars = 0;
    }
    current.add(path);
    currentChars += pathChars;
  }
  if (current.isNotEmpty) {
    batches.add(current);
  }
  return batches;
}

/// Builds a PowerShell script that emits `path\x1f mtime \x1f base64` snapshot
/// lines for [paths], matching [_parseRemoteFileSnapshotOutputSync].
///
/// The content selection mirrors the POSIX reader: [maxBytes] reads the first N
/// bytes, a null [maxLines]/[maxBytes] reads the whole file, otherwise the first
/// (or, when [tail] is set, last) [maxLines] lines are read. `mtime` is Unix
/// epoch seconds; paths are echoed verbatim so they match the map keys the
/// callers pass in.
@visibleForTesting
String windowsFileSnapshotScript(
  List<String> paths, {
  int? maxLines,
  int? maxBytes,
  bool tail = false,
}) {
  final pathsLiteral = paths.map(powerShellSingleQuote).join(',');
  final body = StringBuffer()
    ..write(r'$SEP=[char]0x1f;')
    ..write(r'$__flEpoch=New-Object DateTime(1970,1,1,0,0,0,')
    ..write('([DateTimeKind]::Utc));')
    ..write('\$__flPaths=@($pathsLiteral);')
    ..write(r'foreach($p in $__flPaths){try{')
    ..write(r'if(-not (Test-Path -LiteralPath $p -PathType Leaf)){continue}')
    ..write(r'$fi=Get-Item -LiteralPath $p 2>$null;if($null -eq $fi){continue}')
    ..write(r'$__flMtime=[int64]((($fi.LastWriteTimeUtc)-$__flEpoch)')
    ..write('.TotalSeconds);');
  if (maxBytes != null) {
    body
      ..write(r'$fs=[System.IO.File]::OpenRead($p);')
      ..write('\$buf=New-Object byte[] $maxBytes;')
      ..write(r'$read=$fs.Read($buf,0,$buf.Length);$fs.Dispose();')
      ..write(r'if($read -lt 0){$read=0};')
      ..write(r'$__flB64=[Convert]::ToBase64String($buf,0,$read);');
  } else if (maxLines == null) {
    body
      ..write(r'$bytes=[System.IO.File]::ReadAllBytes($p);')
      ..write(r'$__flB64=[Convert]::ToBase64String($bytes);');
  } else {
    body
      ..write(
        tail
            ? '\$__flLines=@(Get-Content -LiteralPath \$p -Tail $maxLines -Encoding UTF8 2>\$null);'
            : '\$__flLines=@(Get-Content -LiteralPath \$p -TotalCount $maxLines -Encoding UTF8 2>\$null);',
      )
      ..write(r'$__flText=[string]::Join([char]10,$__flLines);')
      ..write(r'$__flB64=[Convert]::ToBase64String(')
      ..write(r'[System.Text.Encoding]::UTF8.GetBytes($__flText));');
  }
  body
    ..write(r'[void]$__flOut.Append($p);[void]$__flOut.Append($SEP);')
    ..write(r'[void]$__flOut.Append([string]$__flMtime);')
    ..write(r'[void]$__flOut.Append($SEP);')
    ..write(r'[void]$__flOut.Append($__flB64);[void]$__flOut.Append([char]10);')
    ..write('}catch{}}');
  return powerShellUtf8OutputScript(body.toString());
}

DateTime _dateTimeFromEpochValue(int epoch) =>
    DateTime.fromMillisecondsSinceEpoch(
      epoch > 9999999999 ? epoch : epoch * 1000,
    );

Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    return null;
  }
  return null;
}

String _buildSqlWorkingDirectoryPrefixPredicate(
  String directory, {
  required String columnName,
}) {
  final quotedDirectory = _sqliteQuote(directory);
  final quotedDirectoryPrefix = _sqliteQuote(
    _workingDirectoryPrefix(directory),
  );
  return '($columnName = $quotedDirectory OR '
      'substr($columnName, 1, length($quotedDirectoryPrefix)) = '
      '$quotedDirectoryPrefix)';
}

String _sqliteQuote(String value) => "'${value.replaceAll("'", "''")}'";

Map<String, dynamic>? _readMapField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (innerKey, innerValue) => MapEntry('$innerKey', innerValue),
    );
  }
  return null;
}

List<dynamic>? _readListField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  return value is List ? value : null;
}

String? _readStringField(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  return value is String ? value : null;
}

/// Converts a `file:` [uri] to a filesystem path without letting the local
/// platform rewrite separators for remote hosts.
///
/// Remote session `folderUri`s are usually POSIX (`file:///Users/...`), so the
/// default `Uri.toFilePath()` is wrong on a Windows client because it would
/// flip the separators to backslashes. Drive-letter URIs (`file:///C:/...`) are
/// treated as Windows paths; everything else is treated as POSIX. Delegating to
/// `Uri.toFilePath(windows:)` keeps the percent-decoding behavior these paths
/// previously relied on (e.g. `%20` -> space). Authority-bearing URIs throw and
/// are handled by the callers.
String _uriToFilePath(Uri uri) {
  final path = uri.path;
  final hasDriveLetter =
      path.length >= 3 &&
      path[0] == '/' &&
      path[2] == ':' &&
      _isAsciiLetter(path.codeUnitAt(1));
  return uri.toFilePath(windows: hasDriveLetter);
}

/// Whether [codeUnit] is an ASCII letter (`A`-`Z` or `a`-`z`).
bool _isAsciiLetter(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

DateTime? _parseDateTimeValue(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}

String? _extractCodexThreadId(String fileName) {
  final match = RegExp(
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
  ).firstMatch(fileName);
  return match?.group(1);
}

String? _extractClaudeUserSummary(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.startsWith('/') || trimmed.startsWith('<')) return null;
  return _summarizeSessionText(trimmed);
}

/// Provider for [AgentSessionDiscoveryService].
final agentSessionDiscoveryServiceProvider =
    Provider<AgentSessionDiscoveryService>(
      (ref) => AgentSessionDiscoveryService(
        terminalBackendService: ref.watch(
          terminalConnectionBackendServiceProvider,
        ),
      ),
    );
