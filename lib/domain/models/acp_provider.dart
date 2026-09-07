import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'agent_launch_preset.dart';

/// Reserved ID prefix for built-in ACP providers.
///
/// Custom provider IDs must never use this prefix so user-defined and
/// built-in providers can never collide.
const acpCustomProviderReservedIdPrefix = 'builtin:';

/// Maximum length allowed for a custom ACP provider ID.
const acpProviderIdMaxLength = 128;

/// Maximum length allowed for a custom ACP provider label.
const acpProviderLabelMaxLength = 120;

/// Maximum length allowed for an ACP launch command executable.
const acpLaunchCommandExecutableMaxLength = 1024;

/// Maximum length allowed for a single ACP launch command argument.
const acpLaunchCommandArgumentMaxLength = 4096;

/// Maximum number of arguments allowed in an ACP launch command.
const acpLaunchCommandMaxArgumentCount = 64;

final _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F]');
const _listEquality = ListEquality<String>();

// Immutable adapter build containing the extension-command completion fix.
// Return to an npm release after https://github.com/svkozak/pi-acp/pull/118 ships.
const _monkeySshPiAcpPackage =
    'https://github.com/depollsoft/pi-acp/archive/8e7889c39ac550d36c72e15e17f7bf7338bbfaac.tar.gz';

/// Stable identifiers for built-in ACP providers.
abstract final class AcpBuiltinProviderIds {
  /// GitHub Copilot CLI.
  static const copilotCli = '${acpCustomProviderReservedIdPrefix}copilot-cli';

  /// Claude Agent SDK ACP adapter.
  static const claudeAgent =
      '${acpCustomProviderReservedIdPrefix}claude-agent-acp';

  /// Codex ACP adapter.
  static const codex = '${acpCustomProviderReservedIdPrefix}codex-acp';

  /// OpenCode CLI.
  static const openCode = '${acpCustomProviderReservedIdPrefix}opencode';

  /// Cursor Agent's native ACP server.
  static const cursorAgent =
      '${acpCustomProviderReservedIdPrefix}cursor-agent-acp';

  /// Antigravity ACP adapter.
  static const antigravity =
      '${acpCustomProviderReservedIdPrefix}antigravity-acp';

  /// Pi's standalone ACP adapter.
  static const pi = '${acpCustomProviderReservedIdPrefix}pi-acp';

  /// xAI Grok Build's official ACP stdio server.
  static const grokBuild = '${acpCustomProviderReservedIdPrefix}grok-build';

  /// Nous Research Hermes ACP server.
  static const hermes = '${acpCustomProviderReservedIdPrefix}hermes-acp';

  /// OpenClaw ACP server.
  static const openClaw = '${acpCustomProviderReservedIdPrefix}openclaw-acp';
}

/// Resolves the terminal-agent identity sharing a built-in ACP provider.
AgentLaunchTool? agentLaunchToolForBuiltinAcpProviderId(String providerId) =>
    switch (providerId) {
      AcpBuiltinProviderIds.claudeAgent => AgentLaunchTool.claudeCode,
      AcpBuiltinProviderIds.copilotCli => AgentLaunchTool.copilotCli,
      AcpBuiltinProviderIds.codex => AgentLaunchTool.codex,
      AcpBuiltinProviderIds.openCode => AgentLaunchTool.openCode,
      AcpBuiltinProviderIds.cursorAgent => AgentLaunchTool.cursorAgent,
      AcpBuiltinProviderIds.antigravity => AgentLaunchTool.antigravity,
      AcpBuiltinProviderIds.pi => AgentLaunchTool.pi,
      AcpBuiltinProviderIds.hermes => AgentLaunchTool.hermes,
      AcpBuiltinProviderIds.openClaw => AgentLaunchTool.openclaw,
      AcpBuiltinProviderIds.grokBuild => AgentLaunchTool.grokBuild,
      _ => null,
    };

/// Validates and normalizes a custom ACP provider ID.
///
/// Throws a [FormatException] when [id] is blank, exceeds
/// [acpProviderIdMaxLength], contains control characters (including NUL), or
/// uses the reserved built-in prefix.
String validateAcpCustomProviderId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('ACP provider ID must not be blank');
  }
  if (trimmed.length > acpProviderIdMaxLength) {
    throw const FormatException(
      'ACP provider ID must not exceed $acpProviderIdMaxLength characters',
    );
  }
  if (_controlCharacterPattern.hasMatch(trimmed)) {
    throw const FormatException(
      'ACP provider ID must not contain control characters',
    );
  }
  if (trimmed.startsWith(acpCustomProviderReservedIdPrefix)) {
    throw const FormatException(
      'ACP provider ID must not use the reserved built-in prefix',
    );
  }
  return trimmed;
}

/// Validates and normalizes an ACP provider label.
///
/// Throws a [FormatException] when [label] is blank, exceeds
/// [acpProviderLabelMaxLength], or contains control characters.
String validateAcpProviderLabel(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('ACP provider label must not be blank');
  }
  if (trimmed.length > acpProviderLabelMaxLength) {
    throw const FormatException(
      'ACP provider label must not exceed $acpProviderLabelMaxLength characters',
    );
  }
  if (_controlCharacterPattern.hasMatch(trimmed)) {
    throw const FormatException(
      'ACP provider label must not contain control characters',
    );
  }
  return trimmed;
}

/// Validates an ACP launch command.
///
/// Throws a [FormatException] when the executable is blank, either the
/// executable or an argument contains control characters (including NUL), or
/// the command exceeds reasonable length/count limits.
void validateAcpLaunchCommand(AcpLaunchCommand command) {
  final executable = command.executable.trim();
  if (executable.isEmpty) {
    throw const FormatException(
      'ACP launch command executable must not be blank',
    );
  }
  if (executable.length > acpLaunchCommandExecutableMaxLength) {
    throw const FormatException(
      'ACP launch command executable must not exceed '
      '$acpLaunchCommandExecutableMaxLength characters',
    );
  }
  if (_controlCharacterPattern.hasMatch(command.executable)) {
    throw const FormatException(
      'ACP launch command executable must not contain control characters',
    );
  }
  if (command.arguments.length > acpLaunchCommandMaxArgumentCount) {
    throw const FormatException(
      'ACP launch command must not exceed $acpLaunchCommandMaxArgumentCount '
      'arguments',
    );
  }
  for (final argument in command.arguments) {
    if (argument.length > acpLaunchCommandArgumentMaxLength) {
      throw const FormatException(
        'ACP launch command argument must not exceed '
        '$acpLaunchCommandArgumentMaxLength characters',
      );
    }
    if (_controlCharacterPattern.hasMatch(argument)) {
      throw const FormatException(
        'ACP launch command argument must not contain control characters',
      );
    }
  }
}

/// Computes a deterministic fingerprint for [command].
///
/// The fingerprint changes whenever the executable or any argument changes,
/// so it can be compared against a previously approved fingerprint to detect
/// when a user must re-approve a custom provider's command.
String computeAcpLaunchCommandFingerprint(AcpLaunchCommand command) {
  final canonical = jsonEncode({
    'executable': command.executable,
    'arguments': command.arguments,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// A single non-interactive process invocation: an executable plus its
/// arguments.
///
/// The working directory is deliberately not part of this model. The remote
/// bridge always controls the working directory a provider launches into, so
/// it must never be smuggled inside an approved command.
@immutable
class AcpLaunchCommand {
  /// Creates a new [AcpLaunchCommand].
  ///
  /// [arguments] is defensively copied so later mutations to a caller-owned
  /// list can never change this command after construction (which would
  /// otherwise let an already-approved command's fingerprint go stale
  /// without detection).
  AcpLaunchCommand({
    required this.executable,
    List<String> arguments = const [],
  }) : arguments = List.unmodifiable(arguments);

  /// Decodes an [AcpLaunchCommand] from JSON.
  ///
  /// This assumes [json] was already produced by [toJson] or validated with
  /// [tryFromJson]; malformed input should use [tryFromJson] instead.
  factory AcpLaunchCommand.fromJson(Map<String, dynamic> json) {
    final rawArguments = json['arguments'];
    return AcpLaunchCommand(
      executable: json['executable'] as String? ?? '',
      arguments: rawArguments is List
          ? List.unmodifiable(rawArguments.map((value) => value.toString()))
          : const [],
    );
  }

  /// Decodes an [AcpLaunchCommand] from untrusted JSON, returning `null`
  /// instead of throwing when [json] is malformed or fails validation.
  static AcpLaunchCommand? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }
    final executable = json['executable'];
    if (executable is! String) {
      return null;
    }
    final rawArguments = json['arguments'];
    if (rawArguments != null && rawArguments is! List) {
      return null;
    }
    final arguments = <String>[];
    if (rawArguments is List) {
      for (final value in rawArguments) {
        if (value is! String) {
          return null;
        }
        arguments.add(value);
      }
    }
    final command = AcpLaunchCommand(
      executable: executable,
      arguments: List.unmodifiable(arguments),
    );
    try {
      validateAcpLaunchCommand(command);
    } on FormatException {
      return null;
    }
    return command;
  }

  /// The executable name or path to launch.
  final String executable;

  /// Arguments passed to [executable], in order.
  final List<String> arguments;

  /// The full argument vector, with [executable] first.
  List<String> get argv => [executable, ...arguments];

  /// Encodes this command as JSON.
  Map<String, dynamic> toJson() => {
    'executable': executable,
    'arguments': arguments,
  };

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
  /// [candidateExecutableNames] and [versionArguments] are defensively
  /// copied so later mutations to a caller-owned list can never change this
  /// probe after construction.
  AcpExecutableProbe({
    required List<String> candidateExecutableNames,
    List<String> versionArguments = const ['--version'],
  }) : candidateExecutableNames = List.unmodifiable(candidateExecutableNames),
       versionArguments = List.unmodifiable(versionArguments);

  /// Executable names or aliases that may resolve to this provider on PATH.
  final List<String> candidateExecutableNames;

  /// Arguments used to probe the resolved executable's version.
  final List<String> versionArguments;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpExecutableProbe &&
          _listEquality.equals(
            candidateExecutableNames,
            other.candidateExecutableNames,
          ) &&
          _listEquality.equals(versionArguments, other.versionArguments);

  @override
  int get hashCode => Object.hash(
    _listEquality.hash(candidateExecutableNames),
    _listEquality.hash(versionArguments),
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

/// Immutable, app-bundled definition of an ACP-compatible coding-agent
/// provider.
///
/// Built-in providers ship with the app and never require user approval;
/// only [AcpCustomProviderDefinition] tracks command approval state.
@immutable
class AcpBuiltinProvider {
  /// Creates a new [AcpBuiltinProvider].
  const AcpBuiltinProvider({
    required this.id,
    required this.label,
    required this.launchCommand,
    required this.executableProbe,
    this.terminalAuthCommand,
    this.adapterFallbackCommand,
    this.launchProfileSupport,
  });

  /// Stable identifier for this provider.
  final String id;

  /// Human-readable label shown in provider pickers.
  final String label;

  /// Default stdio ACP launch command for this provider.
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpBuiltinProvider &&
          id == other.id &&
          label == other.label &&
          launchCommand == other.launchCommand &&
          executableProbe == other.executableProbe &&
          terminalAuthCommand == other.terminalAuthCommand &&
          adapterFallbackCommand == other.adapterFallbackCommand &&
          launchProfileSupport == other.launchProfileSupport;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    launchCommand,
    executableProbe,
    terminalAuthCommand,
    adapterFallbackCommand,
    launchProfileSupport,
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
  final tool = agentLaunchToolForBuiltinAcpProviderId(provider.id);
  final usesTerminalExecutable =
      tool != null &&
      tool.candidateCommandNames.any(
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
  label: 'OpenCode',
  launchCommand: AcpLaunchCommand(
    executable: 'opencode',
    arguments: const ['acp', '--log-level', 'ERROR'],
  ),
  executableProbe: AcpExecutableProbe(
    candidateExecutableNames: const ['opencode', 'open-code'],
  ),
  terminalAuthCommand: AcpLaunchCommand(
    executable: 'opencode',
    arguments: const ['auth', 'login'],
  ),
);

/// Built-in Cursor Agent native ACP provider.
final acpCursorAgentProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.cursorAgent,
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
);

/// Built-in OpenClaw ACP provider.
final acpOpenClawProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.openClaw,
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

final _monkeySshPiAcpCommand = AcpLaunchCommand(
  executable: 'npx',
  arguments: const [
    '--yes',
    '--prefer-offline',
    '--allow-remote=all',
    _monkeySshPiAcpPackage,
  ],
);

/// Built-in Pi ACP provider.
final acpPiProvider = AcpBuiltinProvider(
  id: AcpBuiltinProviderIds.pi,
  label: 'Pi',
  launchCommand: _monkeySshPiAcpCommand,
  executableProbe: AcpExecutableProbe(candidateExecutableNames: const ['npx']),
  adapterFallbackCommand: _monkeySshPiAcpCommand,
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
]);

/// Approval record for a custom ACP provider's exact launch command.
///
/// The UI must require re-approval whenever the provider's launch command no
/// longer matches [commandFingerprint].
@immutable
class AcpCommandApproval {
  /// Creates a new [AcpCommandApproval].
  const AcpCommandApproval({
    required this.commandFingerprint,
    required this.approvedAt,
  });

  /// Approves [command] as of [now] (defaulting to the current UTC time).
  factory AcpCommandApproval.approve(
    AcpLaunchCommand command, {
    DateTime? now,
  }) => AcpCommandApproval(
    commandFingerprint: computeAcpLaunchCommandFingerprint(command),
    approvedAt: (now ?? DateTime.now()).toUtc(),
  );

  /// Decodes an [AcpCommandApproval] from untrusted JSON, returning `null`
  /// instead of throwing when [json] is malformed.
  static AcpCommandApproval? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }
    final fingerprint = json['commandFingerprint'];
    if (fingerprint is! String || fingerprint.isEmpty) {
      return null;
    }
    final rawApprovedAt = json['approvedAt'];
    if (rawApprovedAt is! String) {
      return null;
    }
    final approvedAt = DateTime.tryParse(rawApprovedAt);
    if (approvedAt == null) {
      return null;
    }
    return AcpCommandApproval(
      commandFingerprint: fingerprint,
      approvedAt: approvedAt,
    );
  }

  /// SHA-256 fingerprint of the exact command that was approved.
  final String commandFingerprint;

  /// When this command was approved.
  final DateTime approvedAt;

  /// Encodes this approval as JSON.
  Map<String, dynamic> toJson() => {
    'commandFingerprint': commandFingerprint,
    'approvedAt': approvedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpCommandApproval &&
          commandFingerprint == other.commandFingerprint &&
          approvedAt.isAtSameMomentAs(other.approvedAt);

  @override
  int get hashCode => Object.hash(commandFingerprint, approvedAt);

  @override
  String toString() => 'AcpCommandApproval(fingerprint: $commandFingerprint)';
}

/// User-defined ACP provider with an explicitly approved launch command.
///
/// Only the exact approved command may ever be launched automatically; if
/// [launchCommand] changes without a matching new approval,
/// [isCommandApproved] becomes `false` and the UI must require the user to
/// review and re-approve the command again before it can launch.
@immutable
class AcpCustomProviderDefinition {
  const AcpCustomProviderDefinition._({
    required this.id,
    required this.label,
    required this.launchCommand,
    required this.approval,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates a new, validated custom provider definition, approving
  /// [launchCommand] as of [now] (defaulting to the current UTC time).
  ///
  /// Throws a [FormatException] if [id], [label], or [launchCommand] fail
  /// validation.
  factory AcpCustomProviderDefinition.create({
    required String id,
    required String label,
    required AcpLaunchCommand launchCommand,
    DateTime? now,
  }) {
    final normalizedId = validateAcpCustomProviderId(id);
    final normalizedLabel = validateAcpProviderLabel(label);
    validateAcpLaunchCommand(launchCommand);
    final timestamp = (now ?? DateTime.now()).toUtc();
    return AcpCustomProviderDefinition._(
      id: normalizedId,
      label: normalizedLabel,
      launchCommand: launchCommand,
      approval: AcpCommandApproval.approve(launchCommand, now: timestamp),
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  /// Decodes an [AcpCustomProviderDefinition] from untrusted JSON, returning
  /// `null` instead of throwing when [json] is malformed or fails
  /// validation.
  ///
  /// Unknown fields are ignored so future schema additions stay
  /// forward-compatible with older persisted data.
  static AcpCustomProviderDefinition? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }
    final rawId = json['id'];
    final rawLabel = json['label'];
    if (rawId is! String || rawLabel is! String) {
      return null;
    }
    final launchCommand = AcpLaunchCommand.tryFromJson(json['launchCommand']);
    if (launchCommand == null) {
      return null;
    }
    final approval = AcpCommandApproval.tryFromJson(json['approval']);
    if (approval == null) {
      return null;
    }
    final rawCreatedAt = json['createdAt'];
    final rawUpdatedAt = json['updatedAt'];
    if (rawCreatedAt is! String || rawUpdatedAt is! String) {
      return null;
    }
    final createdAt = DateTime.tryParse(rawCreatedAt);
    final updatedAt = DateTime.tryParse(rawUpdatedAt);
    if (createdAt == null || updatedAt == null) {
      return null;
    }

    try {
      final id = validateAcpCustomProviderId(rawId);
      final label = validateAcpProviderLabel(rawLabel);
      validateAcpLaunchCommand(launchCommand);
      return AcpCustomProviderDefinition._(
        id: id,
        label: label,
        launchCommand: launchCommand,
        approval: approval,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } on FormatException {
      return null;
    }
  }

  /// Stable identifier for this custom provider.
  final String id;

  /// User-provided display label.
  final String label;

  /// The exact launch command the user reviewed and approved.
  final AcpLaunchCommand launchCommand;

  /// Approval record for [launchCommand].
  final AcpCommandApproval approval;

  /// When this custom provider was first created.
  final DateTime createdAt;

  /// When this custom provider was last saved.
  final DateTime updatedAt;

  /// Whether [approval] still matches the exact current [launchCommand].
  ///
  /// The UI must require re-approval whenever this is `false`.
  bool get isCommandApproved =>
      approval.commandFingerprint ==
      computeAcpLaunchCommandFingerprint(launchCommand);

  /// Returns a copy of this definition with [label] and/or [launchCommand]
  /// replaced.
  ///
  /// This never silently re-approves a changed command: [approval] is
  /// always preserved as-is, so changing [launchCommand] to a different
  /// value makes [isCommandApproved] become `false` until the UI explicitly
  /// calls [approveCurrentCommand] after the user reviews and confirms the
  /// new exact command text. Throws a [FormatException] if the new [label]
  /// or [launchCommand] fail validation.
  AcpCustomProviderDefinition update({
    String? label,
    AcpLaunchCommand? launchCommand,
    DateTime? now,
  }) {
    final normalizedLabel = label == null
        ? this.label
        : validateAcpProviderLabel(label);
    final nextCommand = launchCommand ?? this.launchCommand;
    if (launchCommand != null) {
      validateAcpLaunchCommand(launchCommand);
    }
    final timestamp = (now ?? DateTime.now()).toUtc();
    return AcpCustomProviderDefinition._(
      id: id,
      label: normalizedLabel,
      launchCommand: nextCommand,
      approval: approval,
      createdAt: createdAt,
      updatedAt: timestamp,
    );
  }

  /// Approves the current [launchCommand] as of [now] (defaulting to the
  /// current UTC time), making [isCommandApproved] become `true`.
  ///
  /// The UI must call this only after the user has reviewed and explicitly
  /// confirmed the exact current command text; it must never be called
  /// automatically as a side effect of [update].
  AcpCustomProviderDefinition approveCurrentCommand({DateTime? now}) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return AcpCustomProviderDefinition._(
      id: id,
      label: label,
      launchCommand: launchCommand,
      approval: AcpCommandApproval.approve(launchCommand, now: timestamp),
      createdAt: createdAt,
      updatedAt: timestamp,
    );
  }

  /// Encodes this definition as JSON.
  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'label': label,
    'launchCommand': launchCommand.toJson(),
    'approval': approval.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpCustomProviderDefinition &&
          id == other.id &&
          label == other.label &&
          launchCommand == other.launchCommand &&
          approval == other.approval &&
          createdAt.isAtSameMomentAs(other.createdAt) &&
          updatedAt.isAtSameMomentAs(other.updatedAt);

  @override
  int get hashCode =>
      Object.hash(id, label, launchCommand, approval, createdAt, updatedAt);

  @override
  String toString() =>
      'AcpCustomProviderDefinition(id: $id, label: $label, '
      'approved: $isCommandApproved)';
}

/// Read-only view over any ACP provider available to launch, whether it is
/// built into the app or defined by the user.
sealed class AcpProvider {
  const AcpProvider();

  /// Stable identifier for this provider.
  String get id;

  /// Human-readable display label.
  String get label;

  /// The launch command that would be used to start this provider.
  AcpLaunchCommand get launchCommand;

  /// Whether this provider was defined by the user rather than bundled with
  /// the app.
  bool get isCustom;
}

/// An [AcpProvider] view over a bundled [AcpBuiltinProvider].
@immutable
final class AcpBuiltinProviderView extends AcpProvider {
  /// Creates a view over [provider].
  const AcpBuiltinProviderView(this.provider);

  /// The underlying built-in provider definition.
  final AcpBuiltinProvider provider;

  @override
  String get id => provider.id;

  @override
  String get label => provider.label;

  @override
  AcpLaunchCommand get launchCommand => provider.launchCommand;

  @override
  bool get isCustom => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpBuiltinProviderView && provider == other.provider;

  @override
  int get hashCode => provider.hashCode;
}

/// An [AcpProvider] view over a persisted [AcpCustomProviderDefinition].
@immutable
final class AcpCustomProviderView extends AcpProvider {
  /// Creates a view over [definition].
  const AcpCustomProviderView(this.definition);

  /// The underlying custom provider definition.
  final AcpCustomProviderDefinition definition;

  @override
  String get id => definition.id;

  @override
  String get label => definition.label;

  @override
  AcpLaunchCommand get launchCommand => definition.launchCommand;

  @override
  bool get isCustom => true;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpCustomProviderView && definition == other.definition;

  @override
  int get hashCode => definition.hashCode;
}
