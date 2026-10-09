import '../services/windows_remote_powershell.dart';
import 'agent_worktree.dart';
import 'command_names.dart';
import 'remote_multiplexer.dart';
import 'tmux_state.dart';

/// Supported coding-agent CLIs for host-scoped launch presets.
enum AgentLaunchTool {
  /// Anthropic Claude Code.
  claudeCode,

  /// GitHub Copilot CLI.
  copilotCli,

  /// OpenAI Codex CLI.
  codex,

  /// OpenCode CLI.
  openCode,

  /// Antigravity CLI.
  antigravity,

  /// Cursor Agent CLI.
  cursorAgent,

  /// Pi coding agent CLI.
  pi,

  /// Nous Research Hermes agent CLI.
  hermes,

  /// OpenClaw terminal UI.
  openclaw,

  /// xAI Grok Build CLI.
  grokBuild,

  /// Meta Muse Code CLI.
  museCode;

  /// Stable UI order for launch pickers and discovery provider rows.
  ///
  /// Keep this explicit so adding an enum value does not silently reshuffle
  /// product UI. New tools should be appended here when they ship.
  static const List<AgentLaunchTool> uiDisplayOrder = [
    claudeCode,
    copilotCli,
    codex,
    openCode,
    antigravity,
    cursorAgent,
    pi,
    hermes,
    openclaw,
    grokBuild,
    museCode,
  ];
}

/// Presentation helpers for [AgentLaunchTool].
extension AgentLaunchToolPresentation on AgentLaunchTool {
  /// Human-readable label for this tool.
  String get label => switch (this) {
    AgentLaunchTool.claudeCode => 'Claude Code',
    AgentLaunchTool.copilotCli => 'Copilot CLI',
    AgentLaunchTool.codex => 'Codex',
    AgentLaunchTool.openCode => 'OpenCode',
    AgentLaunchTool.antigravity => 'Antigravity',
    AgentLaunchTool.cursorAgent => 'Cursor Agent',
    AgentLaunchTool.pi => 'Pi',
    AgentLaunchTool.hermes => 'Hermes',
    AgentLaunchTool.openclaw => 'OpenClaw',
    AgentLaunchTool.grokBuild => 'Grok Build',
    AgentLaunchTool.museCode => 'Muse Code',
  };

  /// Shell command used to launch this tool.
  String get commandName => switch (this) {
    AgentLaunchTool.claudeCode => 'claude',
    AgentLaunchTool.copilotCli => 'copilot',
    AgentLaunchTool.codex => 'codex',
    AgentLaunchTool.openCode => 'opencode',
    AgentLaunchTool.antigravity => 'agy',
    AgentLaunchTool.cursorAgent => 'cursor-agent',
    AgentLaunchTool.pi => 'pi',
    AgentLaunchTool.hermes => 'hermes',
    AgentLaunchTool.openclaw => 'openclaw',
    AgentLaunchTool.grokBuild => 'grok',
    AgentLaunchTool.museCode => 'muse',
  };

  /// Subcommand arguments required to open this tool's interactive terminal
  /// UI, inserted immediately after [commandName].
  ///
  /// Most agent CLIs start their TUI when invoked bare, so this is empty. It
  /// exists for tools whose interactive UI lives behind a subcommand.
  List<String> get launchArguments => switch (this) {
    AgentLaunchTool.openclaw => const ['tui'],
    _ => const <String>[],
  };

  /// All candidate command names that can refer to this tool.
  List<String> get candidateCommandNames => switch (this) {
    AgentLaunchTool.claudeCode => const ['claude', 'claude-code'],
    AgentLaunchTool.copilotCli => const ['copilot', 'github-copilot'],
    AgentLaunchTool.codex => const ['codex', 'codex-cli'],
    AgentLaunchTool.openCode => const ['opencode2', 'opencode', 'open-code'],
    AgentLaunchTool.antigravity => const [
      'agy',
      'antigravity',
      'antigravity-cli',
    ],
    AgentLaunchTool.cursorAgent => const ['cursor-agent'],
    AgentLaunchTool.pi => const ['pi'],
    AgentLaunchTool.hermes => const ['hermes', 'hermes-agent'],
    AgentLaunchTool.openclaw => const ['openclaw'],
    AgentLaunchTool.grokBuild => const ['grok'],
    AgentLaunchTool.museCode => const ['muse'],
  };

  /// Whether the preferred executable for this tool differs from
  /// [commandName], so a launch should probe the host for the binary that is
  /// actually installed (for example `opencode2` versus `opencode`) instead of
  /// assuming the canonical name.
  bool get needsExecutableProbe => candidateCommandNames.first != commandName;

  /// Matching discovered-session provider name, if this tool supports recent
  /// session discovery.
  ///
  /// OpenClaw persists sessions in a per-agent SQLite store that has no
  /// reliable working directory, so it cannot back the cwd-scoped picker.
  String? get discoveredSessionToolName =>
      this == AgentLaunchTool.openclaw ? null : label;

  /// Arguments that make a launch of this tool continue its most recent
  /// session in the working directory instead of starting a new one; null
  /// when the app only resumes this tool's sessions by id.
  List<String>? get continueArguments => switch (this) {
    AgentLaunchTool.antigravity ||
    AgentLaunchTool.openCode ||
    AgentLaunchTool.cursorAgent ||
    AgentLaunchTool.pi ||
    AgentLaunchTool.hermes => const ['--continue'],
    // OpenClaw reattaches to its default `main` session key on its own.
    AgentLaunchTool.openclaw => const [],
    AgentLaunchTool.grokBuild => const ['--resume'],
    AgentLaunchTool.claudeCode ||
    AgentLaunchTool.copilotCli ||
    AgentLaunchTool.codex ||
    AgentLaunchTool.museCode => null,
  };

  /// Whether this tool exposes isolated launch profiles.
  bool get supportsLaunchProfiles =>
      this == AgentLaunchTool.hermes || this == AgentLaunchTool.openclaw;

  /// Whether this tool supports launching directly into YOLO mode.
  bool get supportsYoloMode =>
      yoloArguments.isNotEmpty || yoloEnvironment.isNotEmpty;

  /// Command-line arguments that enable YOLO mode for this tool.
  List<String> get yoloArguments => switch (this) {
    AgentLaunchTool.claudeCode => const ['--dangerously-skip-permissions'],
    AgentLaunchTool.copilotCli => const ['--yolo'],
    AgentLaunchTool.codex => const ['--yolo'],
    AgentLaunchTool.openCode => const ['--auto'],
    AgentLaunchTool.antigravity => const ['--dangerously-skip-permissions'],
    AgentLaunchTool.cursorAgent => const ['--force'],
    // Pi has no approval layer to bypass: it acts with the permissions of the
    // invoking user, so there is no startup YOLO flag.
    AgentLaunchTool.pi => const [],
    AgentLaunchTool.hermes => const ['--yolo'],
    // OpenClaw's YOLO preset is a persisted `openclaw exec-policy` mutation,
    // not a per-launch flag, so there is nothing safe to pass here.
    AgentLaunchTool.openclaw => const [],
    AgentLaunchTool.grokBuild => const ['--yolo'],
    AgentLaunchTool.museCode => const ['--yolo'],
  };

  /// YOLO arguments accepted ahead of this tool's ACP entrypoint.
  ///
  /// OpenCode 2 defines `--auto` only on its interactive command, so
  /// `opencode --auto acp` prints help and exits. A native session still
  /// starts in YOLO mode: MonkeySSH auto-approves the agent's ACP permission
  /// requests.
  List<String> get acpYoloArguments => switch (this) {
    AgentLaunchTool.openCode => const [],
    _ => yoloArguments,
  };

  /// Environment variables that enable YOLO mode for this tool.
  Map<String, String> get yoloEnvironment => switch (this) {
    AgentLaunchTool.openCode => const {'OPENCODE_PERMISSION': '{"*":"allow"}'},
    _ => const <String, String>{},
  };
}

/// Resolves a supported agent CLI from its persisted enum [name].
AgentLaunchTool? agentLaunchToolFromStorageName(String? name) {
  final normalized = name?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  for (final tool in AgentLaunchTool.values) {
    if (tool.name == normalized) {
      return tool;
    }
  }
  return null;
}

/// Resolves a supported agent CLI from a command or binary name.
///
/// The input may be a bare executable (`claude`), a full path
/// (`/opt/homebrew/bin/codex`), or a command token with trailing arguments.
AgentLaunchTool? agentLaunchToolForCommandName(String? commandName) {
  final normalized = normalizeCommandBasename(commandName);
  if (normalized == null) {
    return null;
  }
  if (_museNativeBinaryPattern.hasMatch(normalized)) {
    return AgentLaunchTool.museCode;
  }
  return _agentLaunchToolsByCommandName[normalized];
}

/// ACP adapter executables that identify a tool but are not launch commands.
const _acpAdapterCommandNames = <String, AgentLaunchTool>{
  'claude-agent-acp': AgentLaunchTool.claudeCode,
  'codex-acp': AgentLaunchTool.codex,
  'antigravity-acp': AgentLaunchTool.antigravity,
  'agy-acp': AgentLaunchTool.antigravity,
  'cursor-acp': AgentLaunchTool.cursorAgent,
  'cursor-agent-acp': AgentLaunchTool.cursorAgent,
  'pi-acp': AgentLaunchTool.pi,
  'muse-code-acp': AgentLaunchTool.museCode,
};

final _agentLaunchToolsByCommandName = <String, AgentLaunchTool>{
  for (final tool in AgentLaunchTool.values)
    for (final name in tool.candidateCommandNames) name: tool,
  ..._acpAdapterCommandNames,
};

final _museNativeBinaryPattern = RegExp(
  r'^muse-bin-\d+\.\d+\.\d+-r\d+(?:\.\d+)?$',
);

/// Resolves a supported agent CLI from a full shell command.
///
/// This accepts commands with environment assignments, paths, and arguments
/// because tmux can expose wrapper commands rather than a bare executable.
AgentLaunchTool? agentLaunchToolForCommandText(String? command) {
  var normalized = command?.trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }

  while (true) {
    final cdMatch = _leadingCdCommandPattern.firstMatch(normalized);
    if (cdMatch == null) break;
    normalized = normalized.substring(cdMatch.end).trimLeft();
  }

  while (true) {
    final assignmentMatch = _leadingEnvironmentAssignmentPattern.firstMatch(
      normalized,
    );
    if (assignmentMatch == null) break;
    normalized = normalized.substring(assignmentMatch.end).trimLeft();
  }

  return agentLaunchToolForCommandName(_readLeadingShellToken(normalized));
}

/// Host-scoped preset for launching a coding agent after connect.
class AgentLaunchPreset {
  /// Creates a new [AgentLaunchPreset].
  const AgentLaunchPreset({
    required this.tool,
    this.workingDirectory,
    this.tmuxSessionName,
    this.remoteMuxBackend,
    this.tmuxExtraFlags,
    this.tmuxDisableStatusBar = false,
    this.additionalArguments,
    this.worktree,
    this.initialPrompt,
  });

  /// Decodes an [AgentLaunchPreset] from JSON, or `null` when invalid.
  static AgentLaunchPreset? tryFromJson(Map<String, dynamic> json) {
    final tool = agentLaunchToolFromStorageName(
      _readTrimmedString(json['tool']),
    );
    if (tool == null) {
      return null;
    }
    return AgentLaunchPreset(
      tool: tool,
      workingDirectory: _readTrimmedString(json['workingDirectory']),
      tmuxSessionName: _readTrimmedString(json['tmuxSessionName']),
      remoteMuxBackend: RemoteMuxBackendPresentation.fromStorageValue(
        _readTrimmedString(json['remoteMuxBackend']),
      ),
      tmuxExtraFlags: _readTrimmedString(json['tmuxExtraFlags']),
      tmuxDisableStatusBar: json['tmuxDisableStatusBar'] == true,
      additionalArguments: _readTrimmedString(json['additionalArguments']),
      worktree: AgentWorktreeLaunchOptions.tryFromJson(json['worktree']),
      initialPrompt: _readTrimmedString(json['initialPrompt']),
    );
  }

  /// Selected coding-agent CLI.
  final AgentLaunchTool tool;

  /// Optional directory to `cd` into before launching the agent.
  final String? workingDirectory;

  /// Optional tmux session to create or attach before launching the agent.
  final String? tmuxSessionName;

  /// Optional remote window backend for [tmuxSessionName].
  ///
  /// A null value preserves legacy presets: a configured session means tmux.
  final RemoteMuxBackend? remoteMuxBackend;

  /// Optional `tmux new-session` flags passed before the agent command.
  final String? tmuxExtraFlags;

  /// Whether tmux's built-in status bar should be disabled for this session.
  final bool tmuxDisableStatusBar;

  /// Optional extra arguments passed to the CLI.
  final String? additionalArguments;

  /// Git worktree settings; when set, each launch starts the agent in a new
  /// worktree on a new branch instead of in [workingDirectory].
  final AgentWorktreeLaunchOptions? worktree;

  /// Prompt sent once when a native session started from this preset begins.
  ///
  /// Terminal launches ignore it, and resuming or reconnecting a session never
  /// sends it again.
  final String? initialPrompt;

  /// Whether each launch creates a new git worktree first.
  bool get launchesInNewWorktree => worktree != null;

  /// Whether a native session started from this preset sends a prompt.
  bool get hasInitialPrompt =>
      initialPrompt != null && initialPrompt!.trim().isNotEmpty;

  /// This preset launching in [directory] without creating a worktree, used
  /// once the worktree for a launch exists.
  AgentLaunchPreset launchingIn(String directory) => AgentLaunchPreset(
    tool: tool,
    workingDirectory: directory,
    tmuxSessionName: tmuxSessionName,
    remoteMuxBackend: remoteMuxBackend,
    tmuxExtraFlags: tmuxExtraFlags,
    tmuxDisableStatusBar: tmuxDisableStatusBar,
    additionalArguments: additionalArguments,
    initialPrompt: initialPrompt,
  );

  /// Whether this preset uses a remote window session.
  bool get usesMuxSession =>
      tmuxSessionName != null && tmuxSessionName!.trim().isNotEmpty;

  /// Backend used for the remote window session, if one is configured.
  RemoteMuxBackend get effectiveRemoteMuxBackend =>
      remoteMuxBackend ??
      (usesMuxSession ? RemoteMuxBackend.tmux : RemoteMuxBackend.monkeyMux);

  /// Whether this preset uses a MonkeyMux session.
  bool get usesMonkeyMuxSession =>
      usesMuxSession && effectiveRemoteMuxBackend == RemoteMuxBackend.monkeyMux;

  /// Whether this preset uses a tmux session.
  bool get usesTmuxSession =>
      usesMuxSession && effectiveRemoteMuxBackend == RemoteMuxBackend.tmux;

  /// Whether this preset changes to a working directory first.
  bool get hasWorkingDirectory =>
      workingDirectory != null && workingDirectory!.trim().isNotEmpty;

  /// Encodes this preset as JSON.
  Map<String, dynamic> toJson() => {
    'tool': tool.name,
    if (workingDirectory case final value? when value.trim().isNotEmpty)
      'workingDirectory': value.trim(),
    if (tmuxSessionName case final value? when value.trim().isNotEmpty)
      'tmuxSessionName': value.trim(),
    if (remoteMuxBackend case final value?)
      'remoteMuxBackend': value.storageValue,
    if (tmuxExtraFlags case final value? when value.trim().isNotEmpty)
      'tmuxExtraFlags': value.trim(),
    if (tmuxDisableStatusBar) 'tmuxDisableStatusBar': true,
    if (additionalArguments case final value? when value.trim().isNotEmpty)
      'additionalArguments': value.trim(),
    if (worktree case final value?) 'worktree': value.toJson(),
    if (initialPrompt case final value? when value.trim().isNotEmpty)
      'initialPrompt': value.trim(),
  };
}

enum _ShellQuoteMode { none, single, double }

const _backslashCodeUnit = 0x5C;

String? _readLeadingShellToken(String value) {
  final trimmed = value.trimLeft();
  if (trimmed.isEmpty) return null;
  final quote = trimmed.codeUnitAt(0);
  if (quote == 0x22 || quote == 0x27) {
    final end = trimmed.indexOf(String.fromCharCode(quote), 1);
    if (end > 1) {
      return trimmed.substring(1, end);
    }
  }
  return trimmed.split(_whitespacePattern).first;
}

final _whitespacePattern = RegExp(r'\s+');
final _unsafeWindowsShellArgumentPattern = RegExp(r'["%!$`\r\n\u201c-\u201e]');
final _unquotedTmuxFlagTokenPattern = RegExp(r'^[A-Za-z0-9_./~:=,+-]+$');
final _leadingCdCommandPattern = RegExp(
  r'''^cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*''',
);
final _leadingEnvironmentAssignmentPattern = RegExp(
  r'''^[A-Za-z_][A-Za-z0-9_]*=(?:"(?:[^"\\]|\\.)*"|'[^']*'|\S+)\s+''',
);

/// Matches the bare switch [name] as its own argument token.
RegExp _flag(String name) => RegExp('(?<!\\S)${RegExp.escape(name)}(?=\\s|\$)');

/// Matches the option [name] with its value, as `name=value` or `name value`.
RegExp _valued(String name) => RegExp(
  '(?<!\\S)${RegExp.escape(name)}(?:=|\\s+)'
  r"""(?:"[^"]*"|'[^']*'|\S+)""",
);

/// Approval and sandbox options that conflict with each tool's YOLO flags.
///
/// They are stripped, in order, from user-provided additional arguments when
/// launching in YOLO mode. Tools without an entry keep their arguments as is.
final _yoloConflictPatterns = <AgentLaunchTool, List<RegExp>>{
  AgentLaunchTool.claudeCode: [
    _flag('--dangerously-skip-permissions'),
    _valued('--permission-mode'),
  ],
  AgentLaunchTool.copilotCli: [
    _flag('--allow-all'),
    _flag('--yolo'),
    _flag('--allow-all-tools'),
    _flag('--allow-all-paths'),
    _flag('--allow-all-urls'),
  ],
  AgentLaunchTool.codex: [
    _valued('--approval-mode'),
    _valued('--ask-for-approval'),
    _valued('-a'),
    _valued('--sandbox'),
    _valued('-s'),
    _flag('--full-auto'),
    _flag('--yolo'),
    _flag('--dangerously-bypass-approvals-and-sandbox'),
  ],
  AgentLaunchTool.openCode: [
    _flag('--auto'),
    _flag('--yolo'),
    _flag('--dangerously-skip-permissions'),
  ],
  AgentLaunchTool.antigravity: [_flag('--dangerously-skip-permissions')],
  AgentLaunchTool.cursorAgent: [_flag('--force'), _flag('--yolo'), _flag('-f')],
  AgentLaunchTool.hermes: [_flag('--yolo')],
  AgentLaunchTool.museCode: [
    _flag('--yolo'),
    _valued('--approval-mode'),
    _valued('--permission-profile'),
    _valued('--approval-judge'),
    _valued('--sandbox-network'),
    _flag('--disable-approval'),
    _flag('--disable-sandbox'),
    _flag('--trust-workspace'),
  ],
  AgentLaunchTool.grokBuild: [
    _flag('--always-approve'),
    _flag('--yolo'),
    _flag('--dangerously-skip-permissions'),
    _valued('--permission-mode'),
  ],
};

/// Builds the shell command for a saved agent launch preset.
String buildAgentLaunchCommand(
  AgentLaunchPreset preset, {
  bool startInYoloMode = false,
  String? executable,
  bool windows = false,
}) {
  final baseCommand = buildAgentToolCommand(
    preset.tool,
    additionalArguments: preset.additionalArguments,
    startInYoloMode: startInYoloMode,
    executable: executable,
    windows: windows,
  );

  final tmuxSessionName = preset.tmuxSessionName?.trim();
  final workingDirectory = preset.workingDirectory?.trim();
  if (preset.usesTmuxSession &&
      tmuxSessionName != null &&
      tmuxSessionName.isNotEmpty) {
    final tmuxExtraFlags = _tokenizeTmuxNewSessionFlags(preset.tmuxExtraFlags);
    final commandParts = <String>[
      'tmux new-session -A -s ${_quoteShellArgument(tmuxSessionName)}',
      if (workingDirectory != null && workingDirectory.isNotEmpty)
        '-c ${_quoteShellPath(workingDirectory)}',
      ...tmuxExtraFlags.map(_quoteTmuxFlagToken),
      _quoteShellArgument(baseCommand),
      if (preset.tmuxDisableStatusBar) tmuxDisableStatusBarCommand,
      tmuxEnableFocusEventsCommand,
    ];
    return commandParts.join(' ');
  }

  if (workingDirectory != null && workingDirectory.isNotEmpty) {
    if (windows) {
      final directory = workingDirectory == '~'
          ? r'$env:USERPROFILE'
          : workingDirectory.startsWith('~/')
          ? '(Join-Path \$env:USERPROFILE ${powerShellSingleQuote(workingDirectory.substring(2))})'
          : powerShellSingleQuote(workingDirectory);
      return buildWindowsPowerShellCommand(
        'Set-Location -LiteralPath $directory -ErrorAction Stop; $baseCommand',
      );
    }
    return 'cd ${_quoteShellPath(workingDirectory)} && $baseCommand';
  }

  return baseCommand;
}

/// Builds global agent arguments shared by terminal and native ACP launches.
///
/// These arguments always precede the mode-specific TUI/ACP entrypoint.
List<String> buildAgentGlobalLaunchArguments(
  AgentLaunchTool tool, {
  bool startInYoloMode = false,
  String? launchProfile,
  bool quoteProfileForShell = true,
  bool windows = false,
  bool acpEntrypoint = false,
}) {
  final profile = launchProfile?.trim();
  if (profile != null && profile.isNotEmpty && !tool.supportsLaunchProfiles) {
    throw FormatException('${tool.label} does not support launch profiles.');
  }
  final profileArgument = profile == null || !quoteProfileForShell
      ? profile
      : windows
      ? _quoteWindowsShellArgument(profile)
      : _quoteShellArgument(profile);
  return <String>[
    if (profileArgument != null && profileArgument.isNotEmpty) ...[
      '--profile',
      profileArgument,
    ],
    if (startInYoloMode)
      ...(acpEntrypoint ? tool.acpYoloArguments : tool.yoloArguments),
  ];
}

/// Builds the base shell command for launching [tool].
String buildAgentToolCommand(
  AgentLaunchTool tool, {
  String? additionalArguments,
  bool startInYoloMode = false,
  String? launchProfile,
  bool windows = false,
  String? executable,
}) {
  final commandParts = <String>[
    if (!(windows && tool == AgentLaunchTool.openCode))
      ..._buildAgentToolEnvironmentAssignments(
        tool,
        startInYoloMode: startInYoloMode,
      ),
    if (windows && tool == AgentLaunchTool.openCode)
      '& ${powerShellSingleQuote(executable ?? tool.commandName)}'
    else if (executable == null)
      tool.commandName
    else if (windows)
      _quoteWindowsShellArgument(executable)
    else
      _quoteShellArgument(executable),
    ...buildAgentGlobalLaunchArguments(
      tool,
      startInYoloMode: startInYoloMode,
      launchProfile: launchProfile,
      windows: windows,
    ),
    ...tool.launchArguments,
  ];
  final normalizedArguments = _normalizeAgentToolArguments(
    tool: tool,
    additionalArguments: additionalArguments,
    startInYoloMode: startInYoloMode,
  );
  if (normalizedArguments != null && normalizedArguments.isNotEmpty) {
    commandParts.add(normalizedArguments);
  }
  final command = commandParts.join(' ');
  if (windows && tool == AgentLaunchTool.openCode) {
    final environment = startInYoloMode
        ? tool.yoloEnvironment.entries
              .map(
                (entry) =>
                    '\$env:${entry.key}=${powerShellSingleQuote(entry.value)}; ',
              )
              .join()
        : '';
    return buildWindowsPowerShellCommand('$environment$command');
  }
  return command;
}

/// Substitutes a detected executable in a generated agent command.
///
/// An explicitly chosen executable or path is left intact.
String replaceDefaultAgentExecutable(
  String command,
  AgentLaunchTool tool,
  String executable,
) {
  var offset = 0;
  while (true) {
    final rest = command.substring(offset);
    final trimmed = rest.trimLeft();
    offset += rest.length - trimmed.length;
    final prefix =
        _leadingCdCommandPattern.firstMatch(trimmed) ??
        _leadingEnvironmentAssignmentPattern.firstMatch(trimmed);
    if (prefix == null) break;
    offset += prefix.end;
  }
  final name = RegExp.escape(tool.commandName);
  final token = RegExp('^(?:$name|\'$name\'|"$name")(?=\\s|\$)')
      .firstMatch(command.substring(offset));
  if (token == null || executable == tool.commandName) return command;
  return command.substring(0, offset) +
      _quoteShellArgument(executable) +
      command.substring(offset + token.end);
}

/// Builds the command MonkeyMux runs to start the agent [command] launches
/// again when an update restores its window: the same command, continuing
/// the agent's most recent session in the window's directory. A command that
/// already resumes or continues a session is kept as it is. Returns null when
/// [command] does not plainly launch an agent that can continue a session,
/// including when it chains other commands after the agent's arguments.
String? buildAgentRestoreCommand(String? command) {
  final trimmed = command?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final tool = agentLaunchToolForCommandText(trimmed);
  final continueArguments = tool?.continueArguments;
  if (tool == null || continueArguments == null) return null;
  var agentCommand = trimmed;
  while (true) {
    final prefix =
        _leadingCdCommandPattern.firstMatch(agentCommand) ??
        _leadingEnvironmentAssignmentPattern.firstMatch(agentCommand);
    if (prefix == null) break;
    agentCommand = agentCommand.substring(prefix.end);
  }
  if (_chainsOutsideQuotes(agentCommand)) return null;
  final sessionFlags = {
    ...continueArguments,
    _buildAgentResumeArguments(tool, 'id').first,
  };
  final resumes = agentCommand
      .split(RegExp(r'\s+'))
      .any(
        (token) => sessionFlags.any(
          (flag) => token == flag || token.startsWith('$flag='),
        ),
      );
  if (resumes || continueArguments.isEmpty) return trimmed;
  return '$trimmed ${continueArguments.join(' ')}';
}

/// Whether [command] chains, pipes or redirects outside its quoted
/// arguments, so arguments appended to its end would not reach its first
/// command. Quotes as the launch builders write them for POSIX shells,
/// PowerShell and cmd keep `work & review` inside a profile argument.
/// Unbalanced quotes count as chaining, since the command cannot be read.
bool _chainsOutsideQuotes(String command) {
  String? quote;
  for (var i = 0; i < command.length; i++) {
    final char = command[i];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else if (quote == '"' && char == r'\') {
        i++;
      }
    } else if (char == "'" || char == '"') {
      quote = char;
    } else if (char == r'\') {
      i++;
    } else if (';&|<>`'.contains(char) ||
        (char == r'$' && command.startsWith('(', i + 1))) {
      return true;
    }
  }
  return quote != null;
}

/// Builds the base shell command for resuming a saved [tool] session.
String buildAgentResumeCommand(
  AgentLaunchTool tool,
  String sessionId, {
  bool startInYoloMode = false,
}) {
  final commandParts = <String>[
    ..._buildAgentToolEnvironmentAssignments(
      tool,
      startInYoloMode: startInYoloMode,
    ),
    tool.commandName,
    ...tool.launchArguments,
    if (startInYoloMode) ...tool.yoloArguments,
    ..._buildAgentResumeArguments(tool, sessionId),
  ];
  return commandParts.join(' ');
}

List<String> _buildAgentResumeArguments(
  AgentLaunchTool tool,
  String sessionId,
) => switch (tool) {
  AgentLaunchTool.claudeCode => ['--resume', _quoteShellArgument(sessionId)],
  AgentLaunchTool.copilotCli => ['--resume', _quoteShellArgument(sessionId)],
  AgentLaunchTool.museCode =>
    sessionId == '_continue'
        ? const ['resume', '--last']
        : ['resume', _quoteShellArgument(sessionId)],
  AgentLaunchTool.codex => ['resume', _quoteShellArgument(sessionId)],
  AgentLaunchTool.antigravity =>
    sessionId == '_continue'
        ? const ['--continue']
        : ['--conversation', _quoteShellArgument(sessionId)],
  AgentLaunchTool.openCode =>
    sessionId == '_continue'
        ? const ['--continue']
        : ['--session', _quoteShellArgument(sessionId)],
  AgentLaunchTool.cursorAgent =>
    sessionId == '_continue'
        ? const ['--continue']
        : ['--resume', _quoteShellArgument(sessionId)],
  AgentLaunchTool.pi =>
    sessionId == '_continue'
        ? const ['--continue']
        : ['--session', _quoteShellArgument(sessionId)],
  AgentLaunchTool.hermes =>
    sessionId == '_continue'
        ? const ['--continue']
        : ['--resume', _quoteShellArgument(sessionId)],
  // OpenClaw reattaches by session key; omitting it resumes the default
  // `main` key, which is the closest equivalent to continuing.
  AgentLaunchTool.openclaw =>
    sessionId == '_continue'
        ? const <String>[]
        : ['--session', _quoteShellArgument(sessionId)],
  AgentLaunchTool.grokBuild =>
    sessionId == '_continue'
        ? const ['--resume']
        : ['--resume', _quoteShellArgument(sessionId)],
};

String? _normalizeAgentToolArguments({
  required AgentLaunchTool tool,
  required String? additionalArguments,
  required bool startInYoloMode,
}) {
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (!startInYoloMode) {
    return trimmedAdditionalArguments;
  }

  final patterns = _yoloConflictPatterns[tool];
  if (patterns == null) {
    return trimmedAdditionalArguments;
  }
  return _stripArgumentPatterns(trimmedAdditionalArguments, patterns);
}

List<String> _buildAgentToolEnvironmentAssignments(
  AgentLaunchTool tool, {
  required bool startInYoloMode,
}) => !startInYoloMode
    ? const []
    : tool.yoloEnvironment.entries
          .map(
            (entry) => _quoteShellEnvironmentAssignment(entry.key, entry.value),
          )
          .toList(growable: false);

String? _stripArgumentPatterns(
  String? additionalArguments,
  List<RegExp> patterns,
) {
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (trimmedAdditionalArguments == null ||
      trimmedAdditionalArguments.isEmpty) {
    return null;
  }

  final normalizedArguments = patterns
      .fold<String>(
        trimmedAdditionalArguments,
        (value, pattern) => value.replaceAll(pattern, ' '),
      )
      .replaceAll(_whitespacePattern, ' ')
      .trim();
  return normalizedArguments.isEmpty ? null : normalizedArguments;
}

List<String> _tokenizeTmuxNewSessionFlags(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (normalized.contains('\n') || normalized.contains('\r')) {
    throw const FormatException(
      'tmux new-session flags must stay on one line.',
    );
  }

  final tokens = <String>[];
  var currentToken = StringBuffer();
  var tokenStarted = false;
  var quoteMode = _ShellQuoteMode.none;

  void commitToken() {
    if (!tokenStarted) {
      return;
    }
    final token = currentToken.toString();
    if (_isTmuxCommandSeparatorToken(token)) {
      throw const FormatException(
        r'tmux new-session flags cannot include tmux command separators like \;.',
      );
    }
    tokens.add(token);
    currentToken = StringBuffer();
    tokenStarted = false;
  }

  for (var index = 0; index < normalized.length; index++) {
    final character = normalized[index];

    if (quoteMode == _ShellQuoteMode.single) {
      if (character == "'") {
        quoteMode = _ShellQuoteMode.none;
      } else {
        tokenStarted = true;
        currentToken.write(character);
      }
      continue;
    }

    if (quoteMode == _ShellQuoteMode.double) {
      if (character == '"') {
        quoteMode = _ShellQuoteMode.none;
        continue;
      }
      if (character.codeUnitAt(0) == _backslashCodeUnit) {
        if (index + 1 >= normalized.length) {
          throw const FormatException(
            'tmux new-session flags cannot end with an escape character.',
          );
        }
        final nextCharacter = normalized[index + 1];
        if (nextCharacter == '"' ||
            nextCharacter.codeUnitAt(0) == _backslashCodeUnit ||
            nextCharacter == r'$' ||
            nextCharacter == '`') {
          tokenStarted = true;
          currentToken.write(nextCharacter);
          index++;
          continue;
        }
      }
      tokenStarted = true;
      currentToken.write(character);
      continue;
    }

    if (character == ' ' || character == '\t') {
      commitToken();
      continue;
    }
    if (character == "'") {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.single;
      continue;
    }
    if (character == '"') {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.double;
      continue;
    }
    if (character.codeUnitAt(0) == _backslashCodeUnit) {
      if (index + 1 >= normalized.length) {
        throw const FormatException(
          'tmux new-session flags cannot end with an escape character.',
        );
      }
      tokenStarted = true;
      currentToken.write(normalized[index + 1]);
      index++;
      continue;
    }
    tokenStarted = true;
    currentToken.write(character);
  }

  if (quoteMode != _ShellQuoteMode.none) {
    throw const FormatException(
      'tmux new-session flags contain an unterminated quote.',
    );
  }

  commitToken();
  return tokens;
}

bool _isTmuxCommandSeparatorToken(String value) => value == ';';

String _quoteTmuxFlagToken(String value) =>
    _unquotedTmuxFlagTokenPattern.hasMatch(value)
    ? value
    : _quoteShellArgument(value);

String _quoteShellPath(String value) {
  if (value == '~') {
    return r'$HOME';
  }
  if (value.startsWith('~/')) {
    final relativePath = value.substring(2);
    if (relativePath.isEmpty) {
      return r'$HOME';
    }
    return '"\$HOME/${_escapeForDoubleQuotedShellContent(relativePath)}"';
  }
  return _quoteShellArgument(value);
}

String _quoteShellArgument(String value) =>
    '\'${value.replaceAll('\'', '\'"\'"\'')}\'';

String _quoteWindowsShellArgument(String value) {
  if (value.contains(_unsafeWindowsShellArgumentPattern)) {
    throw const FormatException(
      'Profile name is unsafe for the Windows shell.',
    );
  }
  return '"$value"';
}

String _quoteShellEnvironmentAssignment(String key, String value) =>
    '$key="${_escapeForDoubleQuotedShellContent(value)}"';

String _escapeForDoubleQuotedShellContent(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll(r'$', r'\$')
    .replaceAll('`', r'\`');

String? _readTrimmedString(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
