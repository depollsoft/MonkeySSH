// Generated POSIX and PowerShell fragments intentionally mix raw and interpolated strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings, use_raw_strings

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/agent_runtime_info.dart';
import '../models/agent_usage.dart';
import '../models/monetization.dart';
import 'agent_session_discovery_service.dart';
import 'agent_usage_parser.dart';
import 'agent_usage_windows_command.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _posixVersionRunner = r'''
__fl_agent_version() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$t=shift; alarm $t; exec @ARGV' 5 "$@"
  else
    return 124
  fi
}
''';
// Isolate native commands so a hung executable cannot block the remaining rows.
const _windowsVersionRunner = r'''
function ConvertTo-AgentLiteral([string]$Value) {
  return "'" + [regex]::Replace($Value, '[\u0027\u2018\u2019\u201a\u201b]', '$0$0') + "'";
}
function Invoke-AgentProbe([string]$Script) {
  $process = New-Object System.Diagnostics.Process;
  $process.StartInfo.FileName = 'powershell.exe';
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script));
  $process.StartInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded;
  $process.StartInfo.UseShellExecute = $false;
  $process.StartInfo.CreateNoWindow = $true;
  $process.StartInfo.RedirectStandardOutput = $true;
  $process.StartInfo.RedirectStandardError = $true;
  try {
    if (!$process.Start()) { return };
    $stdout = $process.StandardOutput.ReadToEndAsync();
    $stderr = $process.StandardError.ReadToEndAsync();
    if (!$process.WaitForExit(5000)) {
      # Kill descendants before their PowerShell parent so hung CLIs cannot
      # survive repeated probes. Kill(bool) is unavailable in PowerShell 5.1.
      try { & taskkill.exe /PID $process.Id /T /F *> $null } catch {};
      if (!$process.HasExited) {
        try { $process.Kill() } catch {};
      };
      return;
    };
    if ($process.ExitCode -eq 0) { $stdout.Result };
  } finally { $process.Dispose() };
}
''';

// ACP executables may start a protocol server even with --version. Read the
// package behind their launcher instead, including Bun and custom npm prefixes.
const _agentPackageVersionScript = '''
const fs = require('fs');
const path = require('path');
let dir = path.dirname(fs.realpathSync(process.argv[1]));
const name = process.argv[2];
while (true) {
  for (const root of [dir, path.join(dir, 'node_modules', name)]) {
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
      if (pkg.name === name && typeof pkg.version === 'string') {
        console.log(pkg.version);
        process.exit(0);
      }
    } catch {}
  }
  if (path.dirname(dir) === dir) break;
  dir = path.dirname(dir);
}
''';

// Read official release metadata as data. Never execute downloaded installers.
({String url, String pattern})? _officialVersionLookup(
  AgentRuntimeDefinition definition,
) => switch (definition.tool) {
  AgentLaunchTool.cursorAgent => (
    url: 'https://cursor.com/install',
    pattern: r'https://downloads\.cursor\.com/lab/[0-9][0-9A-Za-z.+-]*',
  ),
  AgentLaunchTool.antigravity when definition.kind == AgentRuntimeKind.cli => (
    url:
        'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/',
    pattern: '"version"[[:space:]]*:[[:space:]]*"[^"]+"',
  ),
  AgentLaunchTool.hermes => (
    url:
        'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/hermes_cli/__init__.py',
    pattern: '__version__[[:space:]]*=[[:space:]]*"[^"]+"',
  ),
  AgentLaunchTool.grokBuild => (
    url: 'https://x.ai/cli/stable',
    pattern: r'^[0-9]+\.[0-9]+\.[0-9]+[-+0-9A-Za-z.]*',
  ),
  _ => null,
};

({String url, String pattern})? _fallbackVersionLookup(
  AgentRuntimeDefinition definition,
) =>
    _officialVersionLookup(definition) ??
    (definition.registry == AgentPackageRegistry.npm &&
            definition.packageName != null
        ? (
            url:
                'https://registry.npmjs.org/${Uri.encodeComponent(definition.packageName!)}/latest',
            pattern: '"version"[[:space:]]*:[[:space:]]*"[^"]+"',
          )
        : null);

// Cursor's version command can fail while the login keychain is locked. Its
// official installer puts the release version in the launcher's symlink target.
const _posixCursorVersionFallback = r'''
if [ -z "$version_output" ]; then
  version_output=$(readlink "$resolved" 2>/dev/null | sed -nE 's@.*/cursor-agent/versions/([^/]+)/.*@\1@p')
fi;
''';

const _profilePrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.grok/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; '
    r'__fl_profile_path=$( set +e; . ~/.profile >/dev/null 2>&1 || true; . ~/.bash_profile >/dev/null 2>&1 || true; . ~/.zprofile >/dev/null 2>&1 || true; if [ "${SHELL##*/}" = zsh ]; then . ~/.zshrc >/dev/null 2>&1 || true; elif [ "${SHELL##*/}" = bash ]; then . ~/.bashrc >/dev/null 2>&1 || true; fi; printf "%s" "$PATH" ) || true; '
    r'[ -n "$__fl_profile_path" ] && export PATH="$__fl_profile_path:$PATH"; unset __fl_profile_path; '
    r'export PATH="$HOME/.opencode/bin:$HOME/.grok/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';
const _pathMarker = '__monkeyssh_agent_path__=';
const _versionMarker = '__monkeyssh_agent_version__=';
const _repairMarker = '__monkeyssh_agent_repair__';
const _runtimeMarker = '__monkeyssh_agent_runtime__=';
const _runtimeEndMarker = '__monkeyssh_agent_runtime_end__';
const _sourceMarker = '__monkeyssh_agent_source__=';
const _latestMarker = '__monkeyssh_agent_latest__=';
const _installedMarker = '__monkeyssh_agent_installed__=';

/// Supported remote coding-agent CLIs.
const agentCliRuntimeDefinitions = <AgentRuntimeDefinition>[
  AgentRuntimeDefinition(
    id: 'cli:claude',
    label: 'Claude Code',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.claudeCode,
    executableNames: ['claude', 'claude-code'],
    registry: AgentPackageRegistry.npm,
    packageName: '@anthropic-ai/claude-code',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:copilot',
    label: 'Copilot CLI',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.copilotCli,
    executableNames: ['copilot', 'github-copilot'],
    registry: AgentPackageRegistry.npm,
    packageName: '@github/copilot',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:codex',
    label: 'Codex',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.codex,
    executableNames: ['codex', 'codex-cli'],
    registry: AgentPackageRegistry.npm,
    packageName: '@openai/codex',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:opencode',
    label: 'OpenCode',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openCode,
    executableNames: ['opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: 'opencode-ai',
    homebrewFormula: 'opencode',
    selfUpdateArguments: ['upgrade'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:antigravity',
    label: 'Antigravity',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.antigravity,
    executableNames: ['agy', 'antigravity', 'antigravity-cli'],
    posixInstallerUrl: 'https://antigravity.google/cli',
    windowsInstallerUrl: 'https://antigravity.google/cli/install.ps1',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:cursor',
    label: 'Cursor Agent',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.cursorAgent,
    executableNames: ['cursor-agent'],
    posixInstallerUrl: 'https://cursor.com/install',
    windowsInstallerUrl: 'https://cursor.com/install?win32=true',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:pi',
    label: 'Pi',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi'],
    registry: AgentPackageRegistry.npm,
    packageName: '@earendil-works/pi-coding-agent',
    selfUpdateArguments: ['update', '--self'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:hermes',
    label: 'Hermes',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
    selfUpdateArguments: ['update', '--yes'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:openclaw',
    label: 'OpenClaw',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
    selfUpdateArguments: ['update', '--yes'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:grok',
    label: 'Grok Build',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.grokBuild,
    executableNames: ['grok'],
    posixInstallerUrl: 'https://x.ai/cli/install.sh',
    windowsInstallerUrl: 'https://x.ai/cli/install.ps1',
    selfUpdateArguments: ['update'],
  ),
];

/// Supported built-in ACP adapters.
const agentAcpRuntimeDefinitions = <AgentRuntimeDefinition>[
  AgentRuntimeDefinition(
    id: 'acp:copilot',
    label: 'Copilot CLI ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.copilotCli,
    executableNames: ['copilot', 'github-copilot'],
    registry: AgentPackageRegistry.npm,
    packageName: '@github/copilot',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:claude',
    label: 'Claude Agent ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.claudeCode,
    executableNames: ['claude-agent-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: '@agentclientprotocol/claude-agent-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:codex',
    label: 'Codex ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.codex,
    executableNames: ['codex-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: '@agentclientprotocol/codex-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:opencode',
    label: 'OpenCode ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.openCode,
    executableNames: ['opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: 'opencode-ai',
    homebrewFormula: 'opencode',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:cursor',
    label: 'Cursor Agent ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.cursorAgent,
    executableNames: ['cursor-agent'],
    posixInstallerUrl: 'https://cursor.com/install',
    windowsInstallerUrl: 'https://cursor.com/install?win32=true',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:antigravity',
    label: 'Antigravity ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.antigravity,
    executableNames: ['agy-acp', 'antigravity-acp', 'npx'],
    registry: AgentPackageRegistry.npm,
    packageName: 'agy-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:pi',
    label: 'Pi ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: 'pi-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:hermes',
    label: 'Hermes ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:openclaw',
    label: 'OpenClaw ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:grok',
    label: 'Grok Build ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.grokBuild,
    executableNames: ['grok'],
    posixInstallerUrl: 'https://x.ai/cli/install.sh',
    windowsInstallerUrl: 'https://x.ai/cli/install.ps1',
    sharesCliInstallation: true,
  ),
];

/// ACP adapters that require an installation separate from their agent CLI.
final agentStandaloneAcpRuntimeDefinitions =
    List<AgentRuntimeDefinition>.unmodifiable(
      agentAcpRuntimeDefinitions.where(
        (definition) => !definition.sharesCliInstallation,
      ),
    );

/// All runtimes that need a distinct management row.
final agentRuntimeDefinitions = List<AgentRuntimeDefinition>.unmodifiable([
  ...agentCliRuntimeDefinitions,
  ...agentStandaloneAcpRuntimeDefinitions,
]);

/// Extracts a normalized version from common CLI output.
String? parseAgentVersion(String output) {
  final match = RegExp(
    r'(?<![A-Za-z0-9.])[vV]?(\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)',
  ).firstMatch(output.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), ''));
  return match?.group(1);
}

/// Compares two semantic-style versions.
///
/// Returns a negative value when [left] is older than [right].
int compareAgentVersions(String left, String right) {
  ({List<int> numbers, String? pre}) split(String value) {
    final coreAndPre = value.replaceFirst(RegExp('^[vV]'), '').split('+').first;
    final dash = coreAndPre.indexOf('-');
    final core = dash < 0 ? coreAndPre : coreAndPre.substring(0, dash);
    return (
      numbers: core.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
      pre: dash < 0 ? null : coreAndPre.substring(dash + 1),
    );
  }

  final a = split(left);
  final b = split(right);
  final count = a.numbers.length > b.numbers.length
      ? a.numbers.length
      : b.numbers.length;
  for (var index = 0; index < count; index++) {
    final av = index < a.numbers.length ? a.numbers[index] : 0;
    final bv = index < b.numbers.length ? b.numbers[index] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  if (a.pre == b.pre) return 0;
  if (a.pre == null) return 1;
  if (b.pre == null) return -1;
  final aParts = a.pre!.split('.');
  final bParts = b.pre!.split('.');
  for (var index = 0; index < aParts.length && index < bParts.length; index++) {
    final av = aParts[index];
    final bv = bParts[index];
    if (av == bv) continue;
    final an = int.tryParse(av);
    final bn = int.tryParse(bv);
    if (an != null && bn != null) return an.compareTo(bn);
    if (an != null) return -1;
    if (bn != null) return 1;
    return av.compareTo(bv);
  }
  return aParts.length.compareTo(bParts.length);
}

// Repair the package behind the detected launcher, not a different npm prefix.
// Bun and npm installations can coexist, with Bun's broken shim first on PATH.
const _openCodeRepairScript = '''
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const launcher = fs.realpathSync(process.argv[1]);
let dir = path.dirname(launcher);
let root;
while (true) {
  const candidates = [dir];
  if (process.platform === 'win32') candidates.push(path.join(dir, 'node_modules', 'opencode-ai'));
  for (const candidate of candidates) {
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(candidate, 'package.json'), 'utf8'));
      if (pkg.name === 'opencode-ai' && fs.existsSync(path.join(candidate, 'postinstall.mjs'))) {
        root = candidate;
        break;
      }
    } catch {}
  }
  if (root || path.dirname(dir) === dir) break;
  dir = path.dirname(dir);
}
if (!root) {
  console.error('Cannot locate the OpenCode package behind the detected launcher. Reinstall it with its original package manager.');
  process.exit(1);
}
const result = cp.spawnSync(process.execPath, [path.join(root, 'postinstall.mjs')], {
  cwd: root, stdio: 'inherit', windowsHide: true,
});
process.exit(result.status === null ? 1 : result.status);
''';

/// Builds the remote install or update command for [definition].
String? buildAgentInstallCommand(
  AgentRuntimeDefinition definition, {
  required bool windows,
  required bool update,
  bool repair = false,
  String? detectionSource,
  String? executablePath,
}) {
  if (repair && definition.id == 'cli:opencode' && executablePath != null) {
    if (windows) {
      return buildCompactWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble& node -e '
        '${powerShellSingleQuote(_openCodeRepairScript)} '
        '${powerShellSingleQuote(executablePath)}; exit \u0024LASTEXITCODE',
        plainTextOutput: true,
      );
    }
    return '${_profilePrefix}node -e ${_shellQuote(_openCodeRepairScript)} '
        '${_shellQuote(executablePath)}';
  }
  if (update && executablePath != null && definition.supportsSelfUpdate) {
    if (windows) {
      final executable = powerShellSingleQuote(executablePath);
      final arguments = definition.selfUpdateArguments
          .map(powerShellSingleQuote)
          .join(' ');
      return buildCompactWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble& $executable $arguments; exit \u0024LASTEXITCODE',
        plainTextOutput: true,
      );
    }
    return '$_profilePrefix${_shellQuote(executablePath)} '
        '${definition.selfUpdateArguments.map(_shellQuote).join(' ')}';
  }
  if (update && detectionSource == 'PATH') return null;
  final formula = definition.homebrewFormula;
  if (update && detectionSource == 'Homebrew' && formula != null) {
    return windows
        ? null
        : '$_profilePrefix brew upgrade ${_shellQuote(formula)}';
  }
  final installerUrl = windows
      ? definition.windowsInstallerUrl
      : definition.posixInstallerUrl;
  if (installerUrl != null) {
    return _buildOfficialAgentInstallerCommand(installerUrl, windows: windows);
  }
  final package = definition.packageName;
  if (package == null) return null;
  if (windows) {
    final quotedPackage = powerShellSingleQuote(package);
    final quotedLatest = powerShellSingleQuote('$package@latest');
    final script = switch (definition.registry) {
      AgentPackageRegistry.npm => [
        powerShellProfilePathPreamble,
        if (repair) ...[
          '& npm uninstall -g $quotedPackage;',
          r'if($LASTEXITCODE -ne 0){exit $LASTEXITCODE};',
        ],
        '& npm install -g --foreground-scripts --ignore-scripts=false $quotedLatest;',
        r'exit $LASTEXITCODE',
      ].join(),
      AgentPackageRegistry.pipx => [
        powerShellProfilePathPreamble,
        'if(Get-Command pipx -ErrorAction SilentlyContinue){',
        if (repair)
          '& pipx reinstall $quotedPackage;'
        else if (update)
          '& pipx upgrade $quotedPackage;'
        else
          '& pipx install $quotedPackage;',
        r'if($LASTEXITCODE -eq 0){exit 0}};',
        if (repair)
          '& py -m pip install --user --upgrade --force-reinstall $quotedPackage;'
        else if (update)
          '& py -m pip install --user --upgrade $quotedPackage;'
        else
          '& py -m pip install --user $quotedPackage;',
        r'exit $LASTEXITCODE',
      ].join(),
      null => null,
    };
    return script == null
        ? null
        : buildCompactWindowsPowerShellCommand(script, plainTextOutput: true);
  }
  return switch (definition.registry) {
    AgentPackageRegistry.npm =>
      repair
          ? '$_profilePrefix npm uninstall -g ${_shellQuote(package)} && npm install -g --foreground-scripts --ignore-scripts=false ${_shellQuote(package)}@latest'
          : '$_profilePrefix npm install -g --foreground-scripts --ignore-scripts=false ${_shellQuote(package)}@latest',
    AgentPackageRegistry.pipx =>
      repair
          ? '$_profilePrefix pipx reinstall ${_shellQuote(package)} || python3 -m pip install --user --upgrade --force-reinstall ${_shellQuote(package)}'
          : update
          ? '$_profilePrefix pipx upgrade ${_shellQuote(package)} || python3 -m pip install --user --upgrade ${_shellQuote(package)}'
          : '$_profilePrefix pipx install ${_shellQuote(package)} || python3 -m pip install --user ${_shellQuote(package)}',
    null => null,
  };
}

/// Inspects and manages coding-agent runtimes over non-interactive SSH exec.
class AgentManagementService {
  /// Creates the service.
  AgentManagementService(
    this._discovery, {
    required Future<bool> Function() canManageAgents,
    DateTime Function()? now,
  }) : _canManageAgents = canManageAgents,
       _now = now ?? DateTime.now;

  final Future<bool> Function() _canManageAgents;
  final DateTime Function() _now;

  static const _updateCheckTtl = Duration(minutes: 15);
  static const _maxRuntimeCacheEntries = 32;

  final AgentSessionDiscoveryService _discovery;
  final Map<int, ({DateTime checkedAt, List<AgentRuntimeInfo> runtimes})>
  _runtimeCache = {};
  final Map<int, Future<List<AgentRuntimeInfo>>> _inFlightUpdateChecks = {};
  final Map<int, Future<Map<String, AgentUsage>>> _inFlightUsageChecks = {};
  final Map<int, ({DateTime at, Map<String, AgentUsage> values})> _usageCache =
      {};

  /// Number of retained connection snapshots.
  @visibleForTesting
  int get cachedConnectionCount => _runtimeCache.length;

  /// Returns cached update information or probes the active host.
  /// Periodic checks bypass the cache with [forceRefresh], but share in-flight work.
  Future<List<AgentRuntimeInfo>> checkForUpdates(
    SshSession session, {
    bool forceRefresh = false,
  }) async {
    if (!await _canManageAgents()) return const [];
    _pruneRuntimeCache();
    final cached = _runtimeCache[session.connectionId];
    if (!forceRefresh && cached != null) {
      return Future.value(cached.runtimes);
    }
    final existing = _inFlightUpdateChecks[session.connectionId];
    if (existing != null) return existing;

    late final Future<List<AgentRuntimeInfo>> check;
    check = _inspectAll(session, priority: SshExecPriority.low).whenComplete(
      () {
        if (identical(_inFlightUpdateChecks[session.connectionId], check)) {
          _inFlightUpdateChecks.remove(session.connectionId);
        }
      },
    );
    _inFlightUpdateChecks[session.connectionId] = check;
    return check;
  }

  /// Invalidates session discovery and probes every supported runtime.
  Future<List<AgentRuntimeInfo>> refreshAll(
    SshSession session, {
    void Function(List<AgentRuntimeInfo>)? onDiscovered,
  }) async {
    if (!await _canManageAgents()) return const [];
    final inFlight = _inFlightUpdateChecks[session.connectionId];
    if (inFlight != null) {
      try {
        await inFlight;
      } on Object {
        // A stale background failure must not abort an explicit refresh.
      }
    }
    _discovery.invalidateSession(session);
    return _inspectAll(session, onDiscovered: onDiscovered);
  }

  Future<List<AgentRuntimeInfo>> _inspectAll(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.normal,
    void Function(List<AgentRuntimeInfo>)? onDiscovered,
  }) async {
    final definitions = agentRuntimeDefinitions;
    final AgentRuntimeActionResult batch;
    try {
      batch = await _run(
        session,
        buildAgentBatchProbeCommand(
          definitions,
          windows: session.remoteIsWindows,
        ),
        priority: priority,
        timeout: Duration(
          seconds: session.remoteIsWindows
              ? 8 + ((definitions.length + 3) ~/ 4) * 6
              : 8,
        ),
      );
    } on Object catch (error) {
      final failed = [
        for (final definition in definitions)
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.failed,
            message: error.toString(),
          ),
      ];
      return _cacheRuntimes(session, failed);
    }
    final snapshots = parseAgentBatchProbeOutput(batch.output);
    final installedDefinitions = definitions
        .where((definition) => snapshots[definition.id]?.executablePath != null)
        .toList(growable: false);
    onDiscovered?.call([
      for (final definition in definitions)
        _resolveRuntimeInfo(
          definition,
          snapshots[definition.id] ?? const AgentProbeSnapshot(),
        ),
    ]);
    var metadata = <String, AgentMetadataSnapshot>{};
    if (installedDefinitions.isNotEmpty) {
      try {
        final metadataOutput = await _run(
          session,
          buildAgentMetadataProbeCommand(
            installedDefinitions,
            windows: session.remoteIsWindows,
          ),
          priority: priority,
          timeout: Duration(
            seconds: 20 + ((installedDefinitions.length + 3) ~/ 4) * 10,
          ),
          keepPartialOutputOnTimeout: true,
        );
        metadata = parseAgentMetadataProbeOutput(metadataOutput.output);
      } on Object {
        // Registry metadata is best-effort; installed tools remain visible.
      }
    }
    final runtimes = [
      for (final definition in definitions)
        _resolveRuntimeInfo(
          definition,
          snapshots[definition.id] ?? const AgentProbeSnapshot(),
          metadata: metadata[definition.id],
        ),
    ];
    return _cacheRuntimes(session, runtimes);
  }

  void _pruneRuntimeCache() {
    final now = _now();
    _runtimeCache.removeWhere(
      (_, entry) => now.difference(entry.checkedAt) >= _updateCheckTtl,
    );
  }

  List<AgentRuntimeInfo> _cacheRuntimes(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) {
    _pruneRuntimeCache();
    _runtimeCache.remove(session.connectionId);
    if (_runtimeCache.length >= _maxRuntimeCacheEntries) {
      _runtimeCache.remove(_runtimeCache.keys.first);
    }
    _runtimeCache[session.connectionId] = (
      checkedAt: _now(),
      runtimes: runtimes,
    );
    return runtimes;
  }

  /// Probes one runtime and checks its package registry for a newer version.
  Future<AgentRuntimeInfo> inspect(
    SshSession session,
    AgentRuntimeDefinition definition, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (!await _canManageAgents()) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.unavailable,
        message: 'Agent Management requires MonkeySSH Pro.',
      );
    }
    try {
      final probeOutput = await _run(
        session,
        buildAgentBatchProbeCommand([
          definition,
        ], windows: session.remoteIsWindows),
        priority: priority,
        timeout: const Duration(seconds: 8),
      );
      final snapshot =
          parseAgentBatchProbeOutput(probeOutput.output)[definition.id] ??
          const AgentProbeSnapshot();
      AgentMetadataSnapshot? metadata;
      if (snapshot.executablePath != null) {
        try {
          final metadataOutput = await _run(
            session,
            buildAgentMetadataProbeCommand([
              definition,
            ], windows: session.remoteIsWindows),
            priority: priority,
            timeout: const Duration(seconds: 30),
            keepPartialOutputOnTimeout: true,
          );
          metadata = parseAgentMetadataProbeOutput(
            metadataOutput.output,
          )[definition.id];
        } on Object {
          // Registry failures must not erase a working executable's version.
        }
      }
      return _resolveRuntimeInfo(definition, snapshot, metadata: metadata);
    } on Object catch (error) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.failed,
        message: error.toString(),
      );
    }
  }

  AgentRuntimeInfo _resolveRuntimeInfo(
    AgentRuntimeDefinition definition,
    AgentProbeSnapshot snapshot, {
    AgentMetadataSnapshot? metadata,
  }) {
    final path = snapshot.executablePath;
    var installed = parseAgentVersion(snapshot.versionOutput ?? '');
    if (path == null) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.notInstalled,
        message: definition.supportsManagedInstall
            ? null
            : 'Install this tool using its official installer.',
      );
    }
    if (snapshot.needsRepair) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.needsRepair,
        executablePath: path,
        detectionSource: _detectionSourceFromPath(path),
        managedByPackageManager: definition.supportsManagedInstall,
        message:
            'Required setup scripts did not run. Repair the installation before launching this agent.',
      );
    }
    var source = metadata?.detectionSource;
    source ??=
        definition.id == 'acp:antigravity' && _executableBasename(path) == 'npx'
        ? 'npx on demand'
        : _detectionSourceFromPath(path);
    installed ??= parseAgentVersion(metadata?.installedVersionOutput ?? '');
    final latest = parseAgentVersion(metadata?.latestVersionOutput ?? '');
    final hasUpdate =
        installed != null &&
        latest != null &&
        compareAgentVersions(installed, latest) < 0;
    final managed =
        definition.supportsSelfUpdate ||
        source == 'Homebrew' ||
        source == 'npm global' ||
        source == 'pipx';
    return AgentRuntimeInfo(
      definition: definition,
      status: hasUpdate
          ? AgentRuntimeStatus.updateAvailable
          : AgentRuntimeStatus.installed,
      installedVersion: installed,
      latestVersion: latest,
      executablePath: path,
      detectionSource: source,
      managedByPackageManager: managed,
      message: hasUpdate && !managed
          ? 'Update this PATH installation with its original installer, then re-check.'
          : null,
    );
  }

  /// Reads quotas only when the manager requests them, never during background
  /// version checks. Credentials and provider responses remain on the host.
  Future<Map<String, AgentUsage>> readUsage(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) async {
    if (!await _canManageAgents()) return const {};
    final existing = _inFlightUsageChecks[session.connectionId];
    if (existing != null) await existing;
    late final Future<Map<String, AgentUsage>> check;
    check = _readUsage(session, runtimes).whenComplete(() {
      if (identical(_inFlightUsageChecks[session.connectionId], check)) {
        _inFlightUsageChecks.remove(session.connectionId);
      }
    });
    _inFlightUsageChecks[session.connectionId] = check;
    return check;
  }

  Future<Map<String, AgentUsage>> _readUsage(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) async {
    final selected = <String, String>{};
    final result = <String, AgentUsage>{};
    for (final runtime in runtimes) {
      if (runtime.status != AgentRuntimeStatus.installed &&
          runtime.status != AgentRuntimeStatus.updateAvailable) {
        continue;
      }
      final tool = runtime.definition.tool;
      final id = switch (tool) {
        AgentLaunchTool.claudeCode => 'claude',
        AgentLaunchTool.codex => 'codex',
        AgentLaunchTool.copilotCli => 'copilot',
        AgentLaunchTool.openCode => 'opencode',
        AgentLaunchTool.antigravity => 'antigravity',
        AgentLaunchTool.cursorAgent => 'cursor',
        AgentLaunchTool.pi => 'pi',
        AgentLaunchTool.hermes => 'hermes',
        AgentLaunchTool.openclaw => 'openclaw',
        AgentLaunchTool.grokBuild => 'grok',
        null => null,
      };
      if (id != null &&
          (runtime.definition.kind == AgentRuntimeKind.cli ||
              runtime.definition.sharesCliInstallation ||
              id == 'claude') &&
          runtime.executablePath != null) {
        selected[id] = runtime.executablePath!;
      }
      result[runtime.definition.id] = AgentUsage(
        status: id == null
            ? AgentUsageStatus.unsupported
            : AgentUsageStatus.unavailable,
      );
    }
    if (selected.isEmpty) return result;
    _usageCache.removeWhere(
      (_, entry) => _now().difference(entry.at) >= const Duration(minutes: 2),
    );
    final cached = _usageCache[session.connectionId];
    final parsed = <String, AgentUsage>{};
    final pending = <String, String>{};
    for (final entry in selected.entries) {
      final usage = cached?.values[entry.key];
      final checkedAt = usage?.checkedAt;
      final resetPassed =
          usage?.windows.any(
            (window) =>
                window.resetsAt != null &&
                checkedAt != null &&
                window.resetsAt!.isAfter(checkedAt) &&
                !window.resetsAt!.isAfter(_now()),
          ) ??
          false;
      final throttled =
          usage?.status == AgentUsageStatus.rateLimited ||
          (usage?.notices.any(
                (notice) => notice.status == AgentUsageStatus.rateLimited,
              ) ??
              false);
      final reusable =
          usage != null &&
          checkedAt != null &&
          (throttled ||
              (usage.status == AgentUsageStatus.available &&
                  !usage.notices.any(
                    (notice) => notice.status != AgentUsageStatus.notReported,
                  ))) &&
          _now().difference(checkedAt) < const Duration(minutes: 2) &&
          (throttled || !resetPassed);
      if (reusable) {
        parsed[entry.key] = usage;
      } else {
        pending[entry.key] = entry.value;
      }
    }
    if (pending.isEmpty) {
      return _mapUsageToRuntimes(runtimes, result, selected, parsed);
    }
    try {
      final script = await rootBundle.loadString(
        'assets/scripts/agent_usage_probe.cjs',
      );
      final source = base64.encode(utf8.encode(script));
      final input = base64.encode(utf8.encode(jsonEncode(pending)));
      final bootstrap =
          "process.env.MONKEYSSH_USAGE_PROBE='1';"
          "eval(Buffer.from('$source','base64').toString())";
      final command = session.remoteIsWindows
          ? buildWindowsAgentUsageCommand(pending)
          : "$_profilePrefix node -e ${_shellQuote(bootstrap)} '$input' 2>/dev/null";
      final response = await _run(
        session,
        command,
        input: session.remoteIsWindows
            ? Uint8List.fromList(utf8.encode('$source\n'))
            : null,
        timeout: const Duration(seconds: 18),
        keepPartialOutputOnTimeout: true,
      );
      final values = parseAgentUsageOutput(response.output, checkedAt: _now());
      parsed.addAll(values);
      DiagnosticsLogService.instance.debug(
        'agent.usage',
        'check_complete',
        fields: {
          'connectionId': session.connectionId,
          'windows': session.remoteIsWindows,
          'requestedCount': pending.length,
          'resultCount': values.length,
          'exitCode': response.exitCode,
          for (final status in AgentUsageStatus.values)
            '${status.name}Count': values.values
                .where((value) => value.status == status)
                .length,
        },
      );
    } on Object {
      DiagnosticsLogService.instance.debug(
        'agent.usage',
        'check_failed',
        fields: {
          'connectionId': session.connectionId,
          'windows': session.remoteIsWindows,
          'requestedCount': pending.length,
        },
      );
      // No raw provider or authentication errors enter diagnostics or UI.
    }
    for (final id in selected.keys) {
      parsed.putIfAbsent(
        id,
        () =>
            AgentUsage(status: AgentUsageStatus.unavailable, checkedAt: _now()),
      );
    }
    if (_usageCache.length >= _maxRuntimeCacheEntries) {
      _usageCache.remove(_usageCache.keys.first);
    }
    _usageCache[session.connectionId] = (at: _now(), values: parsed);
    return _mapUsageToRuntimes(runtimes, result, selected, parsed);
  }

  Map<String, AgentUsage> _mapUsageToRuntimes(
    List<AgentRuntimeInfo> runtimes,
    Map<String, AgentUsage> result,
    Map<String, String> selected,
    Map<String, AgentUsage> parsed,
  ) {
    for (final runtime in runtimes) {
      if (!result.containsKey(runtime.definition.id)) continue;
      final id = switch (runtime.definition.tool) {
        AgentLaunchTool.claudeCode => 'claude',
        AgentLaunchTool.codex => 'codex',
        AgentLaunchTool.copilotCli => 'copilot',
        AgentLaunchTool.openCode => 'opencode',
        AgentLaunchTool.antigravity => 'antigravity',
        AgentLaunchTool.cursorAgent => 'cursor',
        AgentLaunchTool.pi => 'pi',
        AgentLaunchTool.hermes => 'hermes',
        AgentLaunchTool.openclaw => 'openclaw',
        AgentLaunchTool.grokBuild => 'grok',
        null => null,
      };
      if (selected.containsKey(id)) {
        result[runtime.definition.id] =
            parsed[id] ??
            AgentUsage(status: AgentUsageStatus.unavailable, checkedAt: _now());
      }
    }
    return result;
  }

  /// Installs or updates [definition], forwarding command output as it arrives.
  Future<AgentRuntimeActionResult> installOrUpdate(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required bool update,
    AgentRuntimeInfo? current,
    ValueChanged<String>? onOutput,
  }) async {
    if (!await _canManageAgents()) {
      return const AgentRuntimeActionResult(
        succeeded: false,
        output: 'Agent Management requires MonkeySSH Pro.',
      );
    }
    final command = buildAgentInstallCommand(
      definition,
      windows: session.remoteIsWindows,
      update: update,
      repair: current?.status == AgentRuntimeStatus.needsRepair,
      detectionSource: current?.detectionSource,
      executablePath: current?.executablePath,
    );
    if (command == null) {
      return const AgentRuntimeActionResult(
        succeeded: false,
        output:
            'No safe automatic installer is available for this tool. Use its official installation instructions, then tap Re-check.',
      );
    }
    final repairing = current?.status == AgentRuntimeStatus.needsRepair;
    DiagnosticsLogService.instance.info(
      'agent.management',
      'action_start',
      fields: {
        'connectionId': session.connectionId,
        'agentId': definition.id,
        'update': update,
        'repair': repairing,
        'registry': definition.registry?.name ?? 'none',
      },
    );
    late AgentRuntimeActionResult result;
    try {
      result = await _run(session, command, onOutput: onOutput, timeout: null);
      if (result.succeeded && definition.kind == AgentRuntimeKind.cli) {
        final verified = await inspect(session, definition);
        final healthy =
            (verified.status == AgentRuntimeStatus.installed ||
                verified.status == AgentRuntimeStatus.updateAvailable) &&
            verified.installedVersion != null;
        DiagnosticsLogService.instance.info(
          'agent.management',
          'action_verification',
          fields: {
            'connectionId': session.connectionId,
            'agentId': definition.id,
            'status': verified.status.name,
            'hasVersion': verified.installedVersion != null,
            'success': healthy,
          },
        );
        if (!healthy) {
          result = AgentRuntimeActionResult(
            succeeded: false,
            exitCode: result.exitCode,
            output:
                '${result.output}\nThe command finished, but '
                '${definition.label} could not be verified. '
                '${verified.message ?? 'Re-check the detected installation before launching it.'}',
          );
        }
      }

      DiagnosticsLogService.instance.info(
        'agent.management',
        'action_complete',
        fields: {
          'connectionId': session.connectionId,
          'agentId': definition.id,
          'update': update,
          'repair': repairing,
          'success': result.succeeded,
          'exitCode': result.exitCode ?? -1,
        },
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.management',
        'action_failed',
        fields: {
          'connectionId': session.connectionId,
          'agentId': definition.id,
          'update': update,
          'repair': repairing,
          'errorType': error.runtimeType,
        },
      );
      rethrow;
    }
    _runtimeCache.remove(session.connectionId);
    _discovery.invalidateSession(session);
    return result;
  }

  Future<AgentRuntimeActionResult> _run(
    SshSession session,
    String command, {
    ValueChanged<String>? onOutput,
    Duration? timeout = const Duration(seconds: 15),
    bool keepPartialOutputOnTimeout = false,
    Uint8List? input,
    SshExecPriority priority = SshExecPriority.normal,
  }) => session.runQueuedExec(() async {
    final exec = await openSshExec(
      session.execute(command),
      timeout ?? const Duration(seconds: 15),
    );
    try {
      final output = StringBuffer();
      void add(String chunk) {
        output.write(chunk);
        onOutput?.call(chunk);
      }

      final stdout = exec.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(add);
      final stderr = exec.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(add);
      if (input != null) exec.stdin.add(input);
      final completion = Future.wait<void>([
        stdout,
        stderr,
        exec.done,
        if (input != null) exec.stdin.close(),
      ]);
      if (timeout == null) {
        await completion;
      } else {
        try {
          await completion.timeout(timeout);
        } on TimeoutException {
          if (!keepPartialOutputOnTimeout) rethrow;
        }
      }
      final exitCode = exec.exitCode;
      return AgentRuntimeActionResult(
        succeeded: exitCode == null || exitCode == 0,
        output: output.toString().trim(),
        exitCode: exitCode,
      );
    } finally {
      exec.close();
    }
  }, priority: priority);
}

/// Parsed executable and version output for one runtime probe.
class AgentProbeSnapshot {
  /// Creates a probe snapshot.
  const AgentProbeSnapshot({
    this.executablePath,
    this.versionOutput,
    this.needsRepair = false,
  });

  /// Resolved remote executable path.
  final String? executablePath;

  /// Raw normalized output from the runtime's version command.
  final String? versionOutput;

  /// Whether the executable reports that required install scripts were skipped.
  final bool needsRepair;
}

/// Package ownership and latest-version output for one runtime.
class AgentMetadataSnapshot {
  /// Creates a metadata snapshot.
  const AgentMetadataSnapshot({
    this.detectionSource,
    this.installedVersionOutput,
    this.latestVersionOutput,
  });

  /// Package manager that owns the installed executable.
  final String? detectionSource;

  /// Installed package version reported by the owning package manager.
  final String? installedVersionOutput;

  /// Raw output from the upstream version lookup.
  final String? latestVersionOutput;
}

/// Parses marker-delimited package ownership and latest-version output.
Map<String, AgentMetadataSnapshot> parseAgentMetadataProbeOutput(
  String output,
) {
  final snapshots = <String, AgentMetadataSnapshot>{};
  String? id;
  String? source;
  String? installed;
  String? latest;
  void save() {
    if (id == null) return;
    snapshots[id] = AgentMetadataSnapshot(
      detectionSource: source == null || source.isEmpty ? null : source,
      installedVersionOutput: installed == null || installed.isEmpty
          ? null
          : installed,
      latestVersionOutput: latest == null || latest.isEmpty ? null : latest,
    );
  }

  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith(_runtimeMarker)) {
      save();
      id = line.substring(_runtimeMarker.length);
      source = null;
      installed = null;
      latest = null;
    } else if (id != null && line.startsWith(_sourceMarker)) {
      source = line.substring(_sourceMarker.length).trim();
    } else if (id != null && line.startsWith(_installedMarker)) {
      installed = line.substring(_installedMarker.length).trim();
    } else if (id != null && line.startsWith(_latestMarker)) {
      latest = line.substring(_latestMarker.length).trim();
    } else if (id != null && line == _runtimeEndMarker) {
      save();
      id = null;
    }
  }
  save();
  return snapshots;
}

/// Parses the marker-delimited output from [buildAgentBatchProbeCommand].
Map<String, AgentProbeSnapshot> parseAgentBatchProbeOutput(String output) {
  final snapshots = <String, AgentProbeSnapshot>{};
  String? id;
  String? path;
  String? version;
  var needsRepair = false;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith(_runtimeMarker)) {
      if (id != null) {
        snapshots[id] = AgentProbeSnapshot(
          executablePath: path == null || path.isEmpty ? null : path,
          versionOutput: version == null || version.isEmpty ? null : version,
          needsRepair: needsRepair,
        );
      }
      id = line.substring(_runtimeMarker.length);
      path = null;
      version = null;
      needsRepair = false;
    } else if (id != null && line.startsWith(_pathMarker)) {
      path = line.substring(_pathMarker.length).trim();
    } else if (id != null && line.startsWith(_versionMarker)) {
      version = line.substring(_versionMarker.length).trim();
    } else if (id != null && line == _repairMarker) {
      needsRepair = true;
    } else if (id != null && line == _runtimeEndMarker) {
      snapshots[id] = AgentProbeSnapshot(
        executablePath: path == null || path.isEmpty ? null : path,
        versionOutput: version == null || version.isEmpty ? null : version,
        needsRepair: needsRepair,
      );
      id = null;
    }
  }
  return snapshots;
}

// Runspaces work on Windows PowerShell 5.1 without extra modules. Each worker
// returns a complete record so markers from different agents never interleave.
String _windowsParallelRecords(List<String> records) {
  final scripts = records
      .map(
        (record) => powerShellSingleQuote(
          r'param($__flNpmGlobal, $__flPipxGlobal); '
          r"$ErrorActionPreference='SilentlyContinue'; $ProgressPreference='SilentlyContinue';"
          '$_windowsVersionRunner'
          r'$__flOut=New-Object System.Text.StringBuilder; '
          '$record'
          r'$__flOut.ToString();',
        ),
      )
      .join(',');
  return r'$__flPool=[RunspaceFactory]::CreateRunspacePool(1,4); $__flPool.Open(); '
      r'$__flJobs=@(); try { '
      'foreach (\$__flScript in @($scripts)) { '
      r'$__flWorker=[PowerShell]::Create(); $__flWorker.RunspacePool=$__flPool; '
      r'[void]$__flWorker.AddScript($__flScript).AddArgument($__flNpmGlobal).AddArgument($__flPipxGlobal); '
      r'$__flJobs+=@{Worker=$__flWorker; Handle=$__flWorker.BeginInvoke()} }; '
      r'foreach ($__flJob in $__flJobs) { '
      r'try { foreach ($__flRecord in $__flJob.Worker.EndInvoke($__flJob.Handle)) { '
      r'$__flBytes=[Text.Encoding]::UTF8.GetBytes([string]$__flRecord); '
      r'[Console]::OpenStandardOutput().Write($__flBytes,0,$__flBytes.Length) } } catch {} } '
      r'} finally { foreach ($__flJob in $__flJobs) { $__flJob.Worker.Dispose() }; $__flPool.Dispose() };';
}

String _windowsRecordStart(AgentRuntimeDefinition definition) =>
    r'[void]$__flOut.AppendLine('
    '${powerShellSingleQuote('$_runtimeMarker${definition.id}')});';

final _windowsRecordEnd =
    r'[void]$__flOut.AppendLine('
    '${powerShellSingleQuote(_runtimeEndMarker)});';

/// Builds one remote command that probes every [definition].
String buildAgentBatchProbeCommand(
  List<AgentRuntimeDefinition> definitions, {
  required bool windows,
}) {
  if (windows) {
    final records = [
      for (final definition in definitions)
        _windowsRecordStart(definition) +
            _buildWindowsProbeBody(definition) +
            _windowsRecordEnd,
    ];
    return buildCompactWindowsPowerShellCommand(
      '$powerShellProfilePathPreamble${_windowsParallelRecords(records)}',
    );
  }

  final command = StringBuffer(_posixVersionRunner)
    ..write(
      r'__fl_probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/monkeyssh-agent.XXXXXX") || exit 1; ',
    )
    ..write('__fl_probe_pids=; ');
  for (var index = 0; index < definitions.length; index += 1) {
    final definition = definitions[index];
    command
      ..write('( printf ${_shellQuote('$_runtimeMarker%s\\n')} ')
      ..write('${_shellQuote(definition.id)}; ')
      ..write(_buildPosixProbeBody(definition))
      ..write('; printf ${_shellQuote('$_runtimeEndMarker\\n')} ) ')
      ..write('> "\$__fl_probe_dir/$index" 2>&1 & ')
      ..write('__fl_probe_pids="\$__fl_probe_pids \$!"; ');
  }
  command.write(
    r'for __fl_pid in $__fl_probe_pids; do wait "$__fl_pid" 2>/dev/null || true; done; ',
  );
  for (var index = 0; index < definitions.length; index += 1) {
    command.write('cat "\$__fl_probe_dir/$index"; ');
  }
  command.write(r'rm -rf "$__fl_probe_dir"; ');
  return '${_profilePrefix}sh -c ${_shellQuote(command.toString())}';
}

/// Builds one remote command for package ownership and upstream versions.
String buildAgentMetadataProbeCommand(
  List<AgentRuntimeDefinition> definitions, {
  required bool windows,
}) {
  if (windows) {
    final body =
        StringBuffer('$powerShellProfilePathPreamble$_windowsVersionRunner')
          ..write(
            r"$__flNpmGlobal = Invoke-AgentProbe '& npm list -g --depth=0 2>$null';",
          )
          ..write(
            r"$__flPipxGlobal = Invoke-AgentProbe '& pipx list --short 2>$null';",
          );
    final records = <String>[];
    final preamble = body.toString();
    for (final definition in definitions) {
      body.clear();
      final package = definition.packageName;
      body
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote('$_runtimeMarker${definition.id}')});',
        )
        ..write(r'$__flLatest=$null;$__flInstalled=$null;');
      if (package != null && definition.registry == AgentPackageRegistry.npm) {
        final needle = powerShellSingleQuote('$package@');
        body.write(
          '\$__flNeedle=$needle;'
          r'$__flLine=($__flNpmGlobal -split "`n" | Where-Object { $_.Contains($__flNeedle) } | Select-Object -First 1);'
          r'if($null -ne $__flLine){'
          '[void]\$__flOut.AppendLine(${powerShellSingleQuote('$_sourceMarker npm global')});'
          r'$__flInstalled=$__flLine.Substring($__flLine.IndexOf($__flNeedle)+$__flNeedle.Length).Split(" ")[0]};',
        );
        if (_officialVersionLookup(definition) == null) {
          body.write(
            '\$__flLatest=Invoke-AgentProbe ${powerShellSingleQuote('& npm view ${powerShellSingleQuote(package)} version --fetch-retries=0 --fetch-timeout=2500 2>\$null; exit \$LASTEXITCODE')};',
          );
        }
      } else if (package != null &&
          definition.registry == AgentPackageRegistry.pipx) {
        final needle = powerShellSingleQuote(package);
        body.write(
          '\$__flNeedle=$needle;'
          r'$__flLine=($__flPipxGlobal -split "`n" | Where-Object { $_.Contains($__flNeedle) } | Select-Object -First 1);'
          r'if($null -ne $__flLine){'
          '[void]\$__flOut.AppendLine(${powerShellSingleQuote('$_sourceMarker pipx')});'
          r'$__flInstalled=($__flLine.Trim() -split "\s+")[1]};',
        );
        if (_officialVersionLookup(definition) == null) {
          body.write(
            '\$__flLatest=Invoke-AgentProbe ${powerShellSingleQuote('& py -m pip index versions ${powerShellSingleQuote(package)} --retries 0 --timeout 3 2>\$null; exit \$LASTEXITCODE')};',
          );
        }
      }
      final official = _fallbackVersionLookup(definition);
      if (official != null) {
        final pattern = official.pattern.replaceAll('[[:space:]]', r'\s');
        var uri = powerShellSingleQuote(official.url);
        if (definition.tool == AgentLaunchTool.antigravity &&
            definition.kind == AgentRuntimeKind.cli) {
          body.write(
            r'$__flArch = $env:PROCESSOR_ARCHITECTURE.ToLower();'
            r'if($env:PROCESSOR_ARCHITEW6432){$__flArch = $env:PROCESSOR_ARCHITEW6432.ToLower()};',
          );
          uri = "($uri + 'windows_' + \$__flArch + '.json')";
        }
        body.write(
          'if([string]::IsNullOrWhiteSpace(\$__flLatest)){try{'
          '\$__flRelease=(Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri $uri -ErrorAction Stop).Content;'
          'if(\$__flRelease -match ${powerShellSingleQuote(pattern)}){\$__flLatest=\$Matches[0]}'
          '}catch{}};',
        );
      }
      body
        ..write(
          'if(\$null -ne \$__flInstalled){[void]\$__flOut.AppendLine('
          '${powerShellSingleQuote(_installedMarker)} + \$__flInstalled)};',
        )
        ..write(
          'if(\$null -ne \$__flLatest){[void]\$__flOut.AppendLine('
          '${powerShellSingleQuote(_latestMarker)} + \$__flLatest)};',
        )
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote(_runtimeEndMarker)});',
        );
      records.add(body.toString());
    }
    return buildCompactWindowsPowerShellCommand(
      '$preamble${_windowsParallelRecords(records)}',
    );
  }

  final command = StringBuffer('$_profilePrefix\n$_posixVersionRunner')
    ..write(
      r'__fl_meta_dir=$(mktemp -d "${TMPDIR:-/tmp}/monkeyssh-meta.XXXXXX") || exit 1; ',
    )
    ..write(
      r'__fl_agent_version npm list -g --depth=0 > "$__fl_meta_dir/npm" 2>/dev/null & ',
    )
    ..write(
      r'__fl_agent_version pipx list --short > "$__fl_meta_dir/pipx" 2>/dev/null & ',
    )
    ..write(
      r'__fl_agent_version brew list --versions > "$__fl_meta_dir/brew" 2>/dev/null & wait; ',
    )
    ..write(r'__fl_npm_global=$(cat "$__fl_meta_dir/npm"); ')
    ..write(r'__fl_pipx_global=$(cat "$__fl_meta_dir/pipx"); ')
    ..write(r'__fl_brew_global=$(cat "$__fl_meta_dir/brew"); ');
  for (final (index, definition) in definitions.indexed) {
    command.write('( ');
    final package = definition.packageName;
    final formula = definition.homebrewFormula;
    command
      ..write('printf ${_shellQuote('$_runtimeMarker%s\\n')} ')
      ..write('${_shellQuote(definition.id)}; ')
      ..write('__fl_source=; __fl_installed=; __fl_latest=; __fl_line=; ');
    if (formula != null) {
      command.write(
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_brew_global" | '
        'grep -E ${_shellQuote('^$formula([[:space:]]|\$)')} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('Homebrew')}; '
        '__fl_installed=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_line" | awk ${_shellQuote('{print \u00242}')}); '
        'fi; ',
      );
    }
    if (package != null && definition.registry == AgentPackageRegistry.npm) {
      command.write(
        'if [ -z "\$__fl_source" ]; then '
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_npm_global" | '
        'grep -F -- ${_shellQuote('$package@')} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('npm global')}; '
        '__fl_prefix=${_shellQuote('$package@')}; '
        '__fl_installed=\u0024{__fl_line##*"\$__fl_prefix"}; '
        '__fl_installed=\u0024{__fl_installed%% *}; '
        'fi; fi; ',
      );
      if (_officialVersionLookup(definition) == null) {
        command.write(
          '__fl_latest=\$(__fl_agent_version npm view ${_shellQuote(package)} version '
          '--fetch-retries=0 --fetch-timeout=2500 2>/dev/null | head -n 1); ',
        );
      }
    } else if (package != null &&
        definition.registry == AgentPackageRegistry.pipx) {
      command.write(
        'if [ -z "\$__fl_source" ]; then '
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_pipx_global" | '
        'grep -F -- ${_shellQuote(package)} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('pipx')}; '
        '__fl_installed=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_line" | awk ${_shellQuote('{print \u00242}')}); '
        'fi; fi; ',
      );
      if (_officialVersionLookup(definition) == null) {
        command.write(
          '__fl_latest=\$(__fl_agent_version python3 -m pip index versions ${_shellQuote(package)} 2>/dev/null | head -n 1); ',
        );
      }
    }
    final official = _fallbackVersionLookup(definition);
    if (official != null) {
      var uri = _shellQuote(official.url);
      if (definition.tool == AgentLaunchTool.antigravity &&
          definition.kind == AgentRuntimeKind.cli) {
        command.write(
          r'__fl_os=$(uname -s | tr "[:upper:]" "[:lower:]"); '
          r'__fl_arch=$(uname -m); '
          r'case "$__fl_arch" in x86_64) __fl_arch=amd64;; aarch64) __fl_arch=arm64;; esac; '
          r'__fl_platform="$__fl_os"_"$__fl_arch"; '
          r'if [ "$__fl_os" = linux ] && ldd --version 2>&1 | grep -qi musl; then __fl_platform="${__fl_platform}_musl"; fi; ',
        );
        uri = '$uri"\$__fl_platform.json"';
      }
      command.write(
        'if [ -z "\$__fl_latest" ]; then __fl_latest=\$(curl -fsSL --max-time 5 $uri 2>/dev/null | '
        'grep -Eo ${_shellQuote(official.pattern)} | head -n 1); fi; ',
      );
    }
    command
      ..write(
        '[ -n "\$__fl_source" ] && printf ${_shellQuote('$_sourceMarker%s\\n')} "\$__fl_source"; ',
      )
      ..write(
        '[ -n "\$__fl_installed" ] && printf ${_shellQuote('$_installedMarker%s\\n')} "\$__fl_installed"; ',
      )
      ..write(
        '[ -n "\$__fl_latest" ] && printf ${_shellQuote('$_latestMarker%s\\n')} "\$__fl_latest"; ',
      )
      ..write('printf ${_shellQuote('$_runtimeEndMarker\\n')}; ')
      ..write(') > "\$__fl_meta_dir/$index" 2>/dev/null & ');
    if ((index + 1) % 4 == 0) command.write('wait; ');
  }
  command.write('wait; ');
  for (var index = 0; index < definitions.length; index++) {
    command.write('cat "\$__fl_meta_dir/$index"; ');
  }
  command.write(r'rm -rf "$__fl_meta_dir"; ');
  return command.toString();
}

String _buildWindowsProbeBody(AgentRuntimeDefinition definition) {
  final quotedNames = definition.executableNames
      .map(powerShellSingleQuote)
      .join(',');
  return [
    '\$__flNames=@($quotedNames);',
    r'foreach($__flName in $__flNames){',
    r'$__flCommand=Get-Command $__flName -ErrorAction SilentlyContinue | Select-Object -First 1;',
    r'if($null -eq $__flCommand){continue};',
    '[void]\$__flOut.AppendLine(${powerShellSingleQuote(_pathMarker)} + \$__flCommand.Source);',
    if (definition.kind == AgentRuntimeKind.cli) ...[
      r'''$__flScript = '& ' + (ConvertTo-AgentLiteral $__flCommand.Source) + ' ' ''',
      '+ ${powerShellSingleQuote(definition.versionArguments.map(powerShellSingleQuote).join(' '))} + ${powerShellSingleQuote(r'; exit $LASTEXITCODE')};',
      r'$__flVersion = Invoke-AgentProbe $__flScript;',
      'if(\$__flVersion){[void]\$__flOut.AppendLine(${powerShellSingleQuote(_versionMarker)} + ((\$__flVersion -split "`r?`n" | Select-Object -First 4) -join " "))};',
    ] else if (definition.packageName != null &&
        definition.registry == AgentPackageRegistry.npm) ...[
      '''\$__flScript = ${powerShellSingleQuote('& node -e ${powerShellSingleQuote(_agentPackageVersionScript)} ')} + (ConvertTo-AgentLiteral \$__flCommand.Source) + ${powerShellSingleQuote(' ${powerShellSingleQuote(definition.packageName!)}; exit \$LASTEXITCODE')};''',
      r'$__flVersion = Invoke-AgentProbe $__flScript;',
      'if(\$__flVersion){[void]\$__flOut.AppendLine(${powerShellSingleQuote(_versionMarker)} + \$__flVersion.Trim())};',
    ],
    'break}',
  ].join();
}

String _buildPosixProbeBody(AgentRuntimeDefinition definition) {
  final candidates = definition.executableNames.map(_shellQuote).join(' ');
  final versionArguments = definition.versionArguments
      .map(_shellQuote)
      .join(' ');
  final versionProbe = definition.kind == AgentRuntimeKind.cli
      ? '__fl_version_file=\$(mktemp "\u0024{TMPDIR:-/tmp}/monkeyssh-version.XXXXXX" 2>/dev/null || true); '
            'if [ -n "\$__fl_version_file" ]; then '
            'version_output=; '
            'if __fl_agent_version "\$resolved" $versionArguments >"\$__fl_version_file" 2>&1; then '
            'version_output=\$(head -n 4 "\$__fl_version_file" | tr ${_shellQuote(r'\r\n')} ${_shellQuote('  ')}); '
            'elif grep -Eiq ${_shellQuote('postinstall (script )?(was )?not run|--ignore-scripts')} "\$__fl_version_file"; then '
            'printf ${_shellQuote('$_repairMarker\n')}; '
            'fi; '
            'rm -f "\$__fl_version_file"; '
            '${definition.tool == AgentLaunchTool.cursorAgent ? _posixCursorVersionFallback : ''}'
            'printf ${_shellQuote('$_versionMarker%s\\n')} "\$version_output"; '
            'fi; '
      : definition.packageName != null &&
            definition.registry == AgentPackageRegistry.npm
      ? 'version_output=\$(__fl_agent_version node -e ${_shellQuote(_agentPackageVersionScript)} "\$resolved" ${_shellQuote(definition.packageName!)} 2>/dev/null); '
            'printf ${_shellQuote('$_versionMarker%s\\n')} "\$version_output"; '
      : '';
  return 'for candidate in $candidates; do '
      r'resolved=$(command -v "$candidate" 2>/dev/null || true); '
      r'[ -z "$resolved" ] && continue; '
      'printf ${_shellQuote('$_pathMarker%s\\n')} "\$resolved"; '
      '$versionProbe'
      'break; done';
}

String _executableBasename(String path) =>
    path.replaceAll('\\', '/').split('/').last.toLowerCase();

String _detectionSourceFromPath(String path) {
  final normalized = path.toLowerCase();
  if (normalized.contains('/.cargo/')) return 'Cargo';
  return 'PATH';
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

// Download completely before execution: a failed download must never run a
// partial installer or look successful because the receiving shell exited zero.
String _buildOfficialAgentInstallerCommand(
  String url, {
  required bool windows,
}) {
  if (windows) {
    return buildCompactWindowsPowerShellCommand(
      '$powerShellProfilePathPreamble'
      r"$ErrorActionPreference='Stop';"
      r"$__flFile=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()+'.ps1');"
      r'$__flCode=1;try {'
      'Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri ${powerShellSingleQuote(url)} -OutFile \$__flFile;'
      // Isolate installer exit/strict-mode changes and provide a real script path.
      r'& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -File $__flFile;'
      r'$__flCode=$LASTEXITCODE;'
      r'} catch {[Console]::Error.WriteLine($_.Exception.Message)} '
      r'finally {Remove-Item -LiteralPath $__flFile -Force -ErrorAction SilentlyContinue};'
      r'exit $__flCode',
      plainTextOutput: true,
    );
  }
  final script =
      r'__fl_file=$(mktemp "${TMPDIR:-/tmp}/monkeyssh-install.XXXXXX") || exit 1; '
      'if curl -fLsS --connect-timeout 15 --max-time 60 ${_shellQuote(url)} -o "\$__fl_file"; then '
      r'bash "$__fl_file"; __fl_code=$?; else __fl_code=$?; fi; '
      r'rm -f "$__fl_file"; exit "$__fl_code"';
  return '${_profilePrefix}sh -c ${_shellQuote(script)}';
}

/// Provider for [AgentManagementService].
final agentManagementServiceProvider = Provider<AgentManagementService>(
  (ref) => AgentManagementService(
    ref.watch(agentSessionDiscoveryServiceProvider),
    canManageAgents: () => ref
        .read(monetizationServiceProvider)
        .canUseFeature(MonetizationFeature.agentManagement),
  ),
);
