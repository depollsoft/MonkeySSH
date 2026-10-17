import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'agent_launch_preset.dart';

part 'acp_custom_provider.dart';

/// ID prefix shared by every built-in ACP provider.
const acpBuiltinProviderIdPrefix = 'builtin:';

const _listEquality = ListEquality<String>();
const _mapEquality = MapEquality<String, String>();

/// Stable identifiers for built-in ACP providers.
abstract final class AcpBuiltinProviderIds {
  /// GitHub Copilot CLI.
  static const copilotCli = '${acpBuiltinProviderIdPrefix}copilot-cli';

  /// Claude Agent SDK ACP adapter.
  static const claudeAgent = '${acpBuiltinProviderIdPrefix}claude-agent-acp';

  /// Codex ACP adapter.
  static const codex = '${acpBuiltinProviderIdPrefix}codex-acp';

  /// OpenCode CLI.
  static const openCode = '${acpBuiltinProviderIdPrefix}opencode';

  /// Cursor Agent's native ACP server.
  static const cursorAgent = '${acpBuiltinProviderIdPrefix}cursor-agent-acp';

  /// Antigravity ACP adapter.
  static const antigravity = '${acpBuiltinProviderIdPrefix}antigravity-acp';

  /// Pi's standalone ACP adapter.
  static const pi = '${acpBuiltinProviderIdPrefix}pi-acp';

  /// Community ACP adapter for Meta Muse Code.
  static const museCode = '${acpBuiltinProviderIdPrefix}muse-code';

  /// xAI Grok Build's official ACP stdio server.
  static const grokBuild = '${acpBuiltinProviderIdPrefix}grok-build';

  /// Nous Research Hermes ACP server.
  static const hermes = '${acpBuiltinProviderIdPrefix}hermes-acp';

  /// OpenClaw ACP server.
  static const openClaw = '${acpBuiltinProviderIdPrefix}openclaw-acp';
}

/// Resolves the terminal-agent identity sharing a built-in ACP provider.
AgentLaunchTool? agentLaunchToolForBuiltinAcpProviderId(String providerId) =>
    acpBuiltinProviders
        .firstWhereOrNull((provider) => provider.id == providerId)
        ?.tool;

/// A single non-interactive process invocation: an executable plus its
/// arguments.
///
/// The working directory is deliberately not part of this model. The remote
/// bridge always controls the working directory a provider launches into.
@immutable
class AcpLaunchCommand {
  /// Creates a new [AcpLaunchCommand].
  ///
  /// [arguments] is defensively copied so later mutations to a caller-owned
  /// list can never change this command after construction.
  AcpLaunchCommand({
    required this.executable,
    List<String> arguments = const [],
  }) : arguments = List.unmodifiable(arguments);

  /// The executable name or path to launch.
  final String executable;

  /// Arguments passed to [executable], in order.
  final List<String> arguments;

  /// The full argument vector, with [executable] first.
  List<String> get argv => [executable, ...arguments];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpLaunchCommand &&
          executable == other.executable &&
          _listEquality.equals(arguments, other.arguments);

  @override
  int get hashCode => Object.hash(executable, _listEquality.hash(arguments));

  @override
  String toString() => 'AcpLaunchCommand(argumentCount: ${arguments.length})';
}

/// Metadata used to detect whether an ACP provider's executable is installed.
@immutable
class AcpExecutableProbe {
  /// Creates a new [AcpExecutableProbe].
  ///
  /// [candidateExecutableNames], [versionArguments],
  /// [requiredExecutableNames], and [executableOverrideEnvironmentVariables]
  /// are defensively copied so later mutations to a caller-owned collection
  /// can never change this probe after construction.
  AcpExecutableProbe({
    required List<String> candidateExecutableNames,
    List<String> versionArguments = const ['--version'],
    List<String> requiredExecutableNames = const [],
    Map<String, String> executableOverrideEnvironmentVariables = const {},
  }) : candidateExecutableNames = List.unmodifiable(candidateExecutableNames),
       versionArguments = List.unmodifiable(versionArguments),
       requiredExecutableNames = List.unmodifiable(requiredExecutableNames),
       executableOverrideEnvironmentVariables = Map.unmodifiable(
         executableOverrideEnvironmentVariables,
       );

  /// Executable names or aliases that may resolve to this provider on PATH.
  final List<String> candidateExecutableNames;

  /// Commands needed by both the installed adapter and its fallback.
  final List<String> requiredExecutableNames;

  /// Arguments used to probe the resolved executable's version.
  final List<String> versionArguments;

  /// Environment variables that, when set on the host, name the absolute path
  /// to use for an executable instead of the PATH lookup, keyed by executable
  /// name.
  final Map<String, String> executableOverrideEnvironmentVariables;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpExecutableProbe &&
          _listEquality.equals(
            candidateExecutableNames,
            other.candidateExecutableNames,
          ) &&
          _listEquality.equals(versionArguments, other.versionArguments) &&
          _listEquality.equals(
            requiredExecutableNames,
            other.requiredExecutableNames,
          ) &&
          _mapEquality.equals(
            executableOverrideEnvironmentVariables,
            other.executableOverrideEnvironmentVariables,
          );

  @override
  int get hashCode => Object.hash(
    _listEquality.hash(candidateExecutableNames),
    _listEquality.hash(versionArguments),
    _listEquality.hash(requiredExecutableNames),
    _mapEquality.hash(executableOverrideEnvironmentVariables),
  );

  @override
  String toString() =>
      'AcpExecutableProbe(candidates: $candidateExecutableNames)';
}

/// How a built-in provider stores launch profiles on the remote host.
enum AcpLaunchProfileDiscoveryKind {
  /// Named profiles are child directories below a provider state root.
  nestedProfileDirectories,

  /// Named profiles are sibling home directories with a stable basename prefix.
  homeDirectoryPrefix,
}

/// Profile-selection metadata for a built-in ACP provider.
@immutable
class AcpLaunchProfileSupport {
  /// Creates immutable profile capability metadata.
  const AcpLaunchProfileSupport({
    required this.discoveryKind,
    this.homeDirectoryPrefix,
    this.profileHomeEnvironmentVariable,
    this.defaultProfileHomeDirectory,
    this.nestedProfilesDirectory,
    this.activeProfileFile,
    this.profileOption = '--profile',
    this.defaultProfileArgument,
  });

  /// Strategy used to enumerate profiles.
  final AcpLaunchProfileDiscoveryKind discoveryKind;

  /// Directory basename prefix used by
  /// [AcpLaunchProfileDiscoveryKind.homeDirectoryPrefix].
  final String? homeDirectoryPrefix;

  /// Optional environment variable overriding the provider state root.
  final String? profileHomeEnvironmentVariable;

  /// State-root directory below the user's home when no override is set.
  final String? defaultProfileHomeDirectory;

  /// Child directory containing named profiles.
  final String? nestedProfilesDirectory;

  /// Optional state-root file containing the active profile name.
  final String? activeProfileFile;

  /// Global CLI option placed before the provider subcommand.
  final String profileOption;

  /// Explicit argument selecting the base profile, or `null` when omitting the
  /// option is the only way to select it.
  final String? defaultProfileArgument;

  /// Adds an explicit profile selection before the provider subcommand.
  AcpLaunchCommand apply(AcpLaunchCommand command, String? profile) {
    if (profile == null) return command;
    if (!isValidAcpLaunchProfileName(profile)) {
      throw const FormatException('Invalid ACP launch profile name');
    }
    return AcpLaunchCommand(
      executable: command.executable,
      arguments: [profileOption, profile, ...command.arguments],
    );
  }

  /// Whether [arguments] is the bundled argv plus one valid profile selector.
  bool matches(List<String> arguments, List<String> baseArguments) {
    if (_listEquality.equals(arguments, baseArguments)) return true;
    return arguments.length == baseArguments.length + 2 &&
        arguments[0] == profileOption &&
        isValidAcpLaunchProfileName(arguments[1]) &&
        _listEquality.equals(arguments.sublist(2), baseArguments);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpLaunchProfileSupport &&
          discoveryKind == other.discoveryKind &&
          homeDirectoryPrefix == other.homeDirectoryPrefix &&
          profileHomeEnvironmentVariable ==
              other.profileHomeEnvironmentVariable &&
          defaultProfileHomeDirectory == other.defaultProfileHomeDirectory &&
          nestedProfilesDirectory == other.nestedProfilesDirectory &&
          activeProfileFile == other.activeProfileFile &&
          profileOption == other.profileOption &&
          defaultProfileArgument == other.defaultProfileArgument;

  @override
  int get hashCode => Object.hash(
    discoveryKind,
    homeDirectoryPrefix,
    profileHomeEnvironmentVariable,
    defaultProfileHomeDirectory,
    nestedProfilesDirectory,
    activeProfileFile,
    profileOption,
    defaultProfileArgument,
  );
}

/// Returns whether [name] can safely be passed as one exact profile argument.
bool isValidAcpLaunchProfileName(String name) =>
    name.isNotEmpty &&
    name.length <= 128 &&
    !name.contains(RegExp(r'[\x00-\x1f\x7f/\\]'));

/// Confirms that an installed CLI can start its ACP server before a native
/// launch, for CLIs that ship that server as an optional Python extra, and
/// describes how MonkeySSH installs that extra.
@immutable
class AcpSupportCheck {
  /// Creates an immutable support check.
  const AcpSupportCheck({
    required this.arguments,
    required this.missingMessage,
    required this.distribution,
    required this.extra,
    this.selfInstallArguments = const [],
  });

  /// Arguments passed to the resolved executable. Exit status 1 means the
  /// installation cannot serve ACP. Any other result lets the launch proceed,
  /// so a CLI too old to know these arguments still launches.
  final List<String> arguments;

  /// Explains what the installation is missing.
  final String missingMessage;

  /// Python distribution that declares [extra].
  final String distribution;

  /// Optional extra whose requirements provide the ACP server.
  final String extra;

  /// Arguments for the CLI's own installer, used when the executable does not
  /// run from a Python environment MonkeySSH can find.
  final List<String> selfInstallArguments;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSupportCheck &&
          _listEquality.equals(arguments, other.arguments) &&
          missingMessage == other.missingMessage &&
          distribution == other.distribution &&
          extra == other.extra &&
          _listEquality.equals(
            selfInstallArguments,
            other.selfInstallArguments,
          );

  @override
  int get hashCode => Object.hash(
    _listEquality.hash(arguments),
    missingMessage,
    distribution,
    extra,
    _listEquality.hash(selfInstallArguments),
  );
}

/// Immutable, app-bundled definition of an ACP-compatible coding-agent
/// provider.
@immutable
class AcpBuiltinProvider implements AcpProvider {
  /// Creates a new [AcpBuiltinProvider].
  const AcpBuiltinProvider({
    required this.id,
    required this.label,
    required this.tool,
    required this.telemetryCategory,
    required this.launchCommand,
    required this.executableProbe,
    this.terminalAuthCommand,
    this.adapterFallbackCommand,
    this.launchProfileSupport,
    this.windowsLaunchPreamble,
    this.supportCheck,
  });

  /// Stable identifier for this provider.
  @override
  final String id;

  /// Human-readable label shown in provider pickers.
  @override
  final String label;

  /// Terminal-agent identity sharing this provider's icon, sessions and
  /// launch arguments.
  final AgentLaunchTool tool;

  /// Coarse snake_case category reported to telemetry instead of the id.
  final String telemetryCategory;

  /// Default stdio ACP launch command for this provider.
  @override
  final AcpLaunchCommand launchCommand;

  /// Executable probe metadata used to detect whether this provider is
  /// installed on a remote host.
  final AcpExecutableProbe executableProbe;

  /// Optional interactive command that opens a real terminal so the user can
  /// complete this provider's own authentication flow.
  ///
  /// This is intentionally a plain terminal command rather than an
  /// automated login: MonkeySSH never captures or stores third-party
  /// credentials.
  final AcpLaunchCommand? terminalAuthCommand;

  /// Pinned npx command offered when the adapter executable is missing.
  final AcpLaunchCommand? adapterFallbackCommand;

  /// Optional capability for discovering and selecting isolated CLI profiles.
  final AcpLaunchProfileSupport? launchProfileSupport;

  /// Optional PowerShell statements run before this provider's argv on a
  /// Windows host.
  final String? windowsLaunchPreamble;

  /// Optional check, run before a native launch, that the installed CLI
  /// includes its ACP server.
  final AcpSupportCheck? supportCheck;

  @override
  bool get isCustom => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpBuiltinProvider &&
          id == other.id &&
          label == other.label &&
          tool == other.tool &&
          telemetryCategory == other.telemetryCategory &&
          launchCommand == other.launchCommand &&
          executableProbe == other.executableProbe &&
          terminalAuthCommand == other.terminalAuthCommand &&
          adapterFallbackCommand == other.adapterFallbackCommand &&
          launchProfileSupport == other.launchProfileSupport &&
          windowsLaunchPreamble == other.windowsLaunchPreamble &&
          supportCheck == other.supportCheck;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    tool,
    telemetryCategory,
    launchCommand,
    executableProbe,
    terminalAuthCommand,
    adapterFallbackCommand,
    launchProfileSupport,
    windowsLaunchPreamble,
    supportCheck,
  );

  @override
  String toString() => 'AcpBuiltinProvider(id: $id, label: $label)';
}

/// Returns whether [command] is an app-approved launch for [provider].
///
/// Besides the exact pinned fallback, this accepts only an absolute executable
/// path resolved from the remote host whose basename matches a declared probe
/// alias and whose arguments exactly match the corresponding bundled command.
/// Shell aliases, functions, relative paths, and changed arguments are rejected.
bool isApprovedAcpBuiltinLaunchOverride(
  AcpBuiltinProvider provider,
  AcpLaunchCommand command,
) {
  if (command == provider.adapterFallbackCommand) return true;
  final executableName = _resolvedAcpExecutableName(command.executable);
  if (executableName == null) return false;

  final baseArguments = provider.launchCommand.arguments;
  var launchArgumentsApproved =
      provider.launchProfileSupport?.matches(
        command.arguments,
        baseArguments,
      ) ??
      _listEquality.equals(command.arguments, baseArguments);
  final tool = provider.tool;
  final usesTerminalExecutable = tool.candidateCommandNames.any(
    (candidate) => candidate.toLowerCase() == executableName,
  );
  if (!launchArgumentsApproved && usesTerminalExecutable) {
    String? profile;
    final profileSupport = provider.launchProfileSupport;
    if (profileSupport != null &&
        command.arguments.length >= 2 &&
        command.arguments.first == profileSupport.profileOption &&
        isValidAcpLaunchProfileName(command.arguments[1])) {
      profile = command.arguments[1];
    }
    final expected = <String>[
      ...buildAgentGlobalLaunchArguments(
        tool,
        startInYoloMode: true,
        launchProfile: profile,
        quoteProfileForShell: false,
        acpEntrypoint: true,
      ),
      ...baseArguments,
    ];
    launchArgumentsApproved = _listEquality.equals(command.arguments, expected);
  }
  if (launchArgumentsApproved &&
      provider.executableProbe.candidateExecutableNames.any(
        (candidate) => candidate.toLowerCase() == executableName,
      )) {
    return true;
  }

  final fallback = provider.adapterFallbackCommand;
  return fallback != null &&
      _listEquality.equals(command.arguments, fallback.arguments) &&
      fallback.executable.toLowerCase() == executableName;
}

String? _resolvedAcpExecutableName(String executable) {
  final normalized = executable.replaceAll(r'\', '/');
  final isAbsolute =
      normalized.startsWith('/') ||
      RegExp('^[A-Za-z]:/').hasMatch(normalized) ||
      normalized.startsWith('//');
  if (!isAbsolute) return null;
  var name = normalized.split('/').last.toLowerCase();
  name = name.replaceFirst(RegExp(r'\.(?:exe|cmd|bat|ps1|com)$'), '');
  return name.isEmpty ? null : name;
}

/// Built-in Copilot CLI ACP provider.
final acpCopilotCliProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.copilotCli,
  tool: AgentLaunchTool.copilotCli,
  telemetryCategory: 'copilot_cli',
  label: 'Copilot CLI',
  launchCommand: AcpLaunchCommand(
    executable: 'copilot',
    arguments: const [
      '--acp',
      '--no-color',
      '--no-auto-update',
      '--log-level',
      'error',
    ],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['copilot', 'github-copilot'],
  ),
  // Explicitly runs Copilot CLI's own sign-in flow rather than an ambiguous
  // bare interactive session.
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'copilot',
    arguments: const ['login'],
  ),
);

/// Built-in Claude Agent SDK ACP provider.
final acpClaudeAgentProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.claudeAgent,
  tool: AgentLaunchTool.claudeCode,
  telemetryCategory: 'claude_agent',
  label: 'Claude Agent',
  launchCommand: AcpLaunchCommand(executable: 'claude-agent-acp'),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['claude-agent-acp'],
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'claude',
    arguments: const ['/login'],
  ),
  adapterFallbackCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', '@agentclientprotocol/claude-agent-acp@0.70.0'],
  ),
);

/// Built-in Codex ACP provider.
final acpCodexProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.codex,
  tool: AgentLaunchTool.codex,
  telemetryCategory: 'codex',
  label: 'Codex',
  launchCommand: AcpLaunchCommand(executable: 'codex-acp'),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['codex-acp'],
  ),
  adapterFallbackCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', '@agentclientprotocol/codex-acp@1.4.0'],
  ),
);

/// Built-in OpenCode ACP provider.
final acpOpenCodeProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.openCode,
  tool: AgentLaunchTool.openCode,
  telemetryCategory: 'opencode',
  label: 'OpenCode',
  launchCommand: AcpLaunchCommand(
    executable: 'opencode',
    arguments: const ['acp'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['opencode2', 'opencode', 'open-code'],
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'opencode',
    arguments: const ['auth', 'login'],
  ),
);

/// Built-in Cursor Agent native ACP provider.
final acpCursorAgentProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.cursorAgent,
  tool: AgentLaunchTool.cursorAgent,
  telemetryCategory: 'cursor_agent',
  label: 'Cursor Agent',
  launchCommand: AcpLaunchCommand(
    executable: 'cursor-agent',
    arguments: const ['acp'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['cursor-agent', 'agent'],
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'monkeymux',
    arguments: const ['cursor-agent-auth'],
  ),
);

/// Built-in Antigravity ACP provider.
final acpAntigravityProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.antigravity,
  tool: AgentLaunchTool.antigravity,
  telemetryCategory: 'antigravity',
  label: 'Antigravity',
  launchCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', '--prefer-offline', 'agy-acp@0.5.2'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['agy-acp', 'antigravity-acp', 'npx'],
  ),
  terminalAuthCommand: AcpLaunchCommand(executable: 'agy'),
  adapterFallbackCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', '--prefer-offline', 'agy-acp@0.5.2'],
  ),
);

/// Built-in Hermes ACP provider.
final acpHermesProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.hermes,
  tool: AgentLaunchTool.hermes,
  telemetryCategory: 'hermes',
  label: 'Hermes',
  launchCommand: AcpLaunchCommand(
    executable: 'hermes',
    arguments: const ['acp'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['hermes', 'hermes-agent'],
  ),
  terminalAuthCommand: AcpLaunchCommand(executable: 'hermes'),
  launchProfileSupport: const AcpLaunchProfileSupport(
    discoveryKind: AcpLaunchProfileDiscoveryKind.nestedProfileDirectories,
    profileHomeEnvironmentVariable: 'HERMES_HOME',
    defaultProfileHomeDirectory: '.hermes',
    nestedProfilesDirectory: 'profiles',
    activeProfileFile: 'active_profile',
    defaultProfileArgument: 'default',
  ),
  // `hermes acp` needs the optional `acp` extra, which a plain pip, pipx or
  // uv install of hermes-agent leaves out; Hermes's own installer includes it.
  supportCheck: const AcpSupportCheck(
    arguments: ['acp', '--check'],
    missingMessage:
        'Hermes on this host was installed without its ACP packages, so '
        'native chat cannot start.',
    distribution: 'hermes-agent',
    extra: 'acp',
    selfInstallArguments: ['pm', 'install', '--extra', 'acp'],
  ),
);

/// Built-in OpenClaw ACP provider.
final acpOpenClawProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.openClaw,
  tool: AgentLaunchTool.openclaw,
  telemetryCategory: 'openclaw',
  label: 'OpenClaw',
  launchCommand: AcpLaunchCommand(
    executable: 'openclaw',
    arguments: const ['acp'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['openclaw'],
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'openclaw',
    arguments: const ['tui'],
  ),
  launchProfileSupport: const AcpLaunchProfileSupport(
    discoveryKind: AcpLaunchProfileDiscoveryKind.homeDirectoryPrefix,
    homeDirectoryPrefix: '.openclaw-',
  ),
);

/// Built-in Grok Build ACP provider.
final acpGrokBuildProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.grokBuild,
  tool: AgentLaunchTool.grokBuild,
  telemetryCategory: 'grok_build',
  label: 'Grok Build',
  launchCommand: AcpLaunchCommand(
    executable: 'grok',
    arguments: const ['agent', 'stdio'],
  ),
  executableProbe: AcpExecutableProbe(candidateExecutableNames: const ['grok']),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'grok',
    arguments: const ['login', '--device-auth'],
  ),
);

/// Muse Code uses a separate community adapter; `muse serve` speaks MSP.
final acpMuseCodeProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.museCode,
  tool: AgentLaunchTool.museCode,
  telemetryCategory: 'muse_code',
  label: 'Muse Code',
  launchCommand: AcpLaunchCommand(executable: 'muse-code-acp'),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['muse-code-acp'],
    requiredExecutableNames: const ['muse'],
    executableOverrideEnvironmentVariables: const {
      'muse': _museExecutableVariable,
    },
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'muse',
    arguments: const ['login'],
  ),
  adapterFallbackCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', '@bex-co/muse-code-acp@0.6.0'],
  ),
  windowsLaunchPreamble: _museWindowsExecutablePreamble,
);

const _museExecutableVariable = 'MUSE_CODE_EXECUTABLE';

// Node's spawn cannot execute the official muse.cmd shim without a shell.
// Resolve the launcher's selected native binary for the adapter's subprocess.
// Preserve explicit overrides and never run the updater while opening chat.
const _museWindowsExecutablePreamble =
    r'if([string]::IsNullOrWhiteSpace($env:MUSE_CODE_EXECUTABLE)){ '
    r'$__flMuse=Get-Command muse -CommandType Application,ExternalScript -ErrorAction SilentlyContinue|Select-Object -First 1; '
    r'if($null -ne $__flMuse){ '
    r'$__flMusePath=$__flMuse.Source; '
    r"if([IO.Path]::GetExtension($__flMusePath) -eq '.exe'){ "
    r'$env:MUSE_CODE_EXECUTABLE=$__flMusePath '
    '}else{ '
    r'$__flMuseDir=Split-Path -Parent $__flMusePath; '
    r"$__flMuseVersionFile=Join-Path $__flMuseDir '.muse-version'; "
    r'if(Test-Path -LiteralPath $__flMuseVersionFile -PathType Leaf){ '
    r'$__flMuseVersion=[IO.File]::ReadAllText($__flMuseVersionFile).Trim(); '
    r"if($__flMuseVersion -match '^\d+\.\d+\.\d+-R\d+(\.\d+)?$'){ "
    r'$__flMuseBinary=Join-Path $__flMuseDir ("muse-bin-"+$__flMuseVersion+".exe"); '
    r'if(Test-Path -LiteralPath $__flMuseBinary -PathType Leaf){ '
    r'$env:MUSE_CODE_EXECUTABLE=$__flMuseBinary '
    '}}}}}; '
    r'if([string]::IsNullOrWhiteSpace($env:MUSE_CODE_EXECUTABLE)){ '
    "throw 'Muse native executable was not found. Install or update Muse Code in Agent Management.' "
    '}};';

/// Built-in Pi ACP provider.
final acpPiProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.pi,
  tool: AgentLaunchTool.pi,
  telemetryCategory: 'pi',
  label: 'Pi',
  launchCommand: AcpLaunchCommand(executable: 'pi-acp'),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['pi-acp'],
  ),
  adapterFallbackCommand: AcpLaunchCommand(
    executable: 'npx',
    arguments: const ['--yes', 'pi-acp@0.0.33'],
  ),
);

/// All built-in ACP providers bundled with the app, in display order.
final acpBuiltinProviders = List<AcpBuiltinProvider>.unmodifiable([
  acpCopilotCliProvider,
  acpClaudeAgentProvider,
  acpCodexProvider,
  acpOpenCodeProvider,
  acpCursorAgentProvider,
  acpAntigravityProvider,
  acpPiProvider,
  acpHermesProvider,
  acpOpenClawProvider,
  acpGrokBuildProvider,
  acpMuseCodeProvider,
]);

/// An ACP provider available to launch: one bundled with the app or one the
/// user defined.
sealed class AcpProvider {
  /// Stable identifier for this provider.
  String get id;

  /// Human-readable display label.
  String get label;

  /// The launch command that would be used to start this provider.
  AcpLaunchCommand get launchCommand;

  /// Whether the user defined this provider rather than the app bundling it.
  bool get isCustom;
}
