import 'agent_launch_preset.dart';

/// Type of remote coding-agent runtime managed by MonkeySSH.
enum AgentRuntimeKind {
  /// Interactive coding-agent command-line tool.
  cli,

  /// Agent Control Protocol provider adapter.
  acpAdapter,
}

/// Current installation and update state of a remote runtime.
enum AgentRuntimeStatus {
  /// A remote probe is running.
  checking,

  /// The runtime is installed and no newer version is known.
  installed,

  /// The registry reports a newer version.
  updateAvailable,

  /// No candidate executable was found.
  notInstalled,

  /// An executable exists, but its required installation setup is incomplete.
  needsRepair,

  /// The runtime cannot run on the remote platform.
  unavailable,

  /// The remote probe failed.
  failed,
}

/// Package registry used to install and check a runtime.
enum AgentPackageRegistry {
  /// npm global package registry.
  npm,

  /// Isolated Python application installed through pipx.
  pipx,
}

/// Static metadata for a supported coding-agent CLI or ACP adapter.
class AgentRuntimeDefinition {
  /// Creates runtime metadata.
  const AgentRuntimeDefinition({
    required this.id,
    required this.label,
    required this.kind,
    required this.executableNames,
    this.tool,
    this.versionArguments = const ['--version'],
    this.registry,
    this.packageName,
    this.homebrewFormula,
    this.posixInstallerUrl,
    this.windowsInstallerUrl,
    this.selfUpdateArguments = const [],
    this.sharesCliInstallation = false,
  });

  /// Stable runtime identifier.
  final String id;

  /// User-facing runtime label.
  final String label;

  /// Whether this is a CLI or an ACP adapter.
  final AgentRuntimeKind kind;

  /// Agent identity used for the shared icon.
  final AgentLaunchTool? tool;

  /// Executable names checked on the remote PATH, in priority order.
  final List<String> executableNames;

  /// Arguments used to read the installed version.
  final List<String> versionArguments;

  /// Registry used for latest-version checks and installation.
  final AgentPackageRegistry? registry;

  /// Registry package name.
  final String? packageName;

  /// Homebrew formula used when an existing installation resolves to Homebrew.
  final String? homebrewFormula;

  /// Official bootstrap script for macOS and Linux hosts (run with Bash).
  final String? posixInstallerUrl;

  /// Official PowerShell bootstrap script for native Windows hosts.
  final String? windowsInstallerUrl;

  /// Arguments for the CLI's own non-interactive updater.
  final List<String> selfUpdateArguments;

  /// Whether this runtime has a built-in updater.
  bool get supportsSelfUpdate => selfUpdateArguments.isNotEmpty;

  /// Whether this adapter ships as part of its agent CLI.
  final bool sharesCliInstallation;

  /// Whether MonkeySSH can install or update this runtime automatically.
  bool get supportsManagedInstall =>
      (registry != null && packageName != null) ||
      posixInstallerUrl != null ||
      windowsInstallerUrl != null;
}

/// Probe result for one runtime on the active remote host.
class AgentRuntimeInfo {
  /// Creates a runtime probe result.
  const AgentRuntimeInfo({
    required this.definition,
    required this.status,
    this.installedVersion,
    this.latestVersion,
    this.executablePath,
    this.detectionSource,
    this.managedByPackageManager = false,
    this.message,
  });

  /// Runtime metadata.
  final AgentRuntimeDefinition definition;

  /// Current state.
  final AgentRuntimeStatus status;

  /// Installed version, when detected.
  final String? installedVersion;

  /// Latest registry version, when available.
  final String? latestVersion;

  /// Resolved executable path.
  final String? executablePath;

  /// Human-readable detection source.
  final String? detectionSource;

  /// Whether install or update can preserve the detected package manager.
  final bool managedByPackageManager;

  /// Probe or action detail safe to show to the user.
  final String? message;

  /// Whether a newer version is available.
  bool get hasUpdate => status == AgentRuntimeStatus.updateAvailable;
}

/// Result of an install or update command.
class AgentRuntimeActionResult {
  /// Creates an action result.
  const AgentRuntimeActionResult({
    required this.succeeded,
    required this.output,
    this.exitCode,
  });

  /// Whether the remote command exited successfully.
  final bool succeeded;

  /// Combined stdout and stderr.
  final String output;

  /// Remote process exit code, when reported.
  final int? exitCode;
}
