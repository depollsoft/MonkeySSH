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
import 'agent_usage_posix_command.dart';
import 'agent_usage_windows_command.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

String _posixVersionRunner({int versionTimeoutSeconds = 5}) =>
    r'''
__fl_agent_version() {
  if command -v timeout >/dev/null 2>&1; then
    timeout __VERSION_TIMEOUT__ "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout __VERSION_TIMEOUT__ "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$t=shift; alarm $t; exec @ARGV' __VERSION_TIMEOUT__ "$@"
  else
    return 124
  fi
}
'''
        .replaceAll('__VERSION_TIMEOUT__', '$versionTimeoutSeconds');
// Isolate native commands so a hung executable cannot block the remaining rows.
const _windowsVersionRunner = r'''
function ConvertTo-AgentLiteral([string]$Value) {
  return "'" + [regex]::Replace($Value, '[\u0027\u2018\u2019\u201a\u201b]', '$0$0') + "'";
}
function Invoke-AgentProbe([string]$Script) {
  $script:__flProbeFailure = $null;
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
    if ($process.ExitCode -eq 0) { $stdout.Result } else {
      # Bounded failure diagnostics, kept apart from successful version output.
      $failure = [string]$stdout.Result + [string]$stderr.Result;
      $script:__flProbeFailure = $failure.Substring(0, [Math]::Min($failure.Length, 4096));
    };
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

// Official release metadata is read as data. Never execute downloaded
// installers.
const _jsonVersionPattern = '"version"[[:space:]]*:[[:space:]]*"[^"]+"';
const _cursorVersionLookup = (
  url: 'https://cursor.com/install',
  pattern: r'https://downloads\.cursor\.com/lab/[0-9][0-9A-Za-z.+-]*',
);
// Hermes's own installer and `hermes update` follow the latest release.
// Since 0.21.6 its source no longer spells out the version.
const _hermesVersionLookup = (
  url: 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest',
  pattern: '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"',
);
const _grokVersionLookup = (
  url: 'https://x.ai/cli/stable',
  pattern: r'^[0-9]+\.[0-9]+\.[0-9]+[-+0-9A-Za-z.]*',
);
const _openCodeLegacyInstallation = (
  belowVersion: '2.0.0',
  message: 'OpenCode 2 uses a new package. Install it from https://opencode.ai/v2/docs, then re-check.',
);

({String url, String pattern})? _fallbackVersionLookup(
  AgentRuntimeDefinition definition,
) =>
    definition.officialVersionLookup ??
    (definition.registry == AgentPackageRegistry.npm &&
            definition.packageName != null
        ? (
            url:
                'https://registry.npmjs.org/${Uri.encodeComponent(definition.packageName!)}/latest',
            pattern: _jsonVersionPattern,
          )
        : null);

// Cursor's version command can fail while the login keychain is locked. Its
// official installer puts the release version in the launcher's symlink target.
const _posixCursorVersionFallback = r'''
if [ -z "$version_output" ]; then
  version_output=$(readlink "$resolved" 2>/dev/null | sed -nE 's@.*/cursor-agent/versions/([^/]+)/.*@\1@p')
fi;
''';

const _defaultPathExport =
    r'export PATH="$HOME/.opencode/bin:$HOME/.grok/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';

/// Startup files whose PATH the host scripts take, in login order. The
/// last is the interactive file of the user's shell, if bash or zsh.
const _profileFiles = [
  r'"$HOME/.profile"',
  r'"$HOME/.bash_profile"',
  r'"$HOME/.zprofile"',
  r'"$__fl_rc"',
];

/// Sources [_profileFiles] from [index] on, each inside the subshell of the
/// one before, so a later file still sees what an earlier one exported (a
/// `.zshrc` that builds on `$HOMEBREW_PREFIX` from `.zprofile`), and prints
/// the resulting PATH.
///
/// A missing file is skipped. A file that ends its subshell early (POSIX sh
/// leaves on a syntax error, such as zsh syntax in `.zshrc`, and a file may
/// `exit` or `exec` another shell) prints nothing, and the files after it
/// then run without it, so one bad file never drops the others. Startup
/// files read `/dev/null`, so one that waits for input cannot stall.
String _profileSourcing([int index = 0]) {
  const printPath = r'printf "%s" "$PATH"';
  if (index == _profileFiles.length) return printPath;
  final file = _profileFiles[index];
  final rest = _profileSourcing(index + 1);
  return '__fl_p=\$( [ -n $file ] && [ -r $file ] && '
      '. $file >/dev/null 2>&1 </dev/null; $rest ); '
      r'if [ -n "$__fl_p" ]; then printf "%s" "$__fl_p"; '
      'else $rest; fi';
}

final String _profilePrefix = [
  _defaultPathExport,
  r'__fl_rc=; case "${SHELL##*/}" in zsh) __fl_rc="$HOME/.zshrc";; ',
  r'bash) __fl_rc="$HOME/.bashrc";; esac; ',
  // The result starts from the current PATH, so it already holds every
  // earlier entry and is exported as is.
  '__fl_profile_path=\$( set +e; ${_profileSourcing()} ); ',
  r'[ -n "$__fl_profile_path" ] && export PATH="$__fl_profile_path"; ',
  'unset __fl_rc __fl_p __fl_profile_path; ',
  _defaultPathExport,
].join();

/// The login PATH setup above, for other host scripts that must find tools
/// installed through profile files (Homebrew, `~/.local/bin`, nix).
final String remoteProfilePathPrefix = _profilePrefix;
const _pathMarker = '__monkeyssh_agent_path__=';
const _versionMarker = '__monkeyssh_agent_version__=';
const _repairMarker = '__monkeyssh_agent_repair__';
// Version-probe failure output of a package installed with skipped scripts.
const _skippedPostinstallPattern =
    'postinstall (script )?(was )?not run|--ignore-scripts';
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
    executableNames: ['opencode2', 'opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: '@opencode/cli',
    homebrewFormula: 'opencode-v2',
    selfUpdateArguments: ['upgrade'],
    repairScript: _openCodeRepairScript,
    legacyInstallation: _openCodeLegacyInstallation,
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
    officialVersionLookup: (
      url: 'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/',
      pattern: _jsonVersionPattern,
    ),
    latestVersionUrlPlatformSuffix: true,
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
    officialVersionLookup: _cursorVersionLookup,
    // Cursor checks the macOS keychain before dispatching even `update`.
    // Updating needs no credentials. Use its in-memory store for this process
    // only, avoiding keychain access without moving saved credentials to disk.
    updateEnvironment: {
      'AGENT_CLI_CREDENTIAL_STORE': 'memory',
      'NO_COLOR': '1',
    },
    posixVersionFallback: _posixCursorVersionFallback,
  ),
  AgentRuntimeDefinition(
    id: 'cli:pi',
    label: 'Pi',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi'],
    // npm installations are still detected and updated in place. New
    // installations use the pi.dev installer, which pins every dependency
    // and migrates an npm installation it finds.
    registry: AgentPackageRegistry.npm,
    packageName: '@earendil-works/pi-coding-agent',
    posixInstallerUrl: 'https://pi.dev/install.sh',
    windowsInstallerUrl: 'https://pi.dev/install.ps1',
    // `pi update` updates both kinds of installation to the release pi.dev
    // reports, which can trail npm's latest tag.
    selfUpdateArguments: ['update', '--self'],
    officialVersionLookup: (
      url: 'https://pi.dev/api/latest-version',
      pattern: _jsonVersionPattern,
    ),
    // The installer's launcher, `~/.pi/agent/bin/pi`, runs a pinned release
    // from `~/.pi/agent/install/releases/<version>`.
    installerLayout: (
      marker: 'install/managed-install.json',
      source: 'Pi installer',
    ),
  ),
  AgentRuntimeDefinition(
    id: 'cli:hermes',
    label: 'Hermes',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    // pipx installations are still detected. New installations use the
    // official installer: a git checkout that `hermes update` keeps current,
    // with every extra native chat needs (`hermes acp` needs `acp`).
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
    packageExtras: ['acp'],
    posixInstallerUrl: 'https://hermes-agent.nousresearch.com/install.sh',
    windowsInstallerUrl: 'https://hermes-agent.nousresearch.com/install.ps1',
    // Homebrew core packages Hermes too; `hermes update` refuses that copy.
    homebrewFormula: 'hermes-agent',
    selfUpdateArguments: ['update', '--yes'],
    officialVersionLookup: _hermesVersionLookup,
    // PyPI stopped at 0.19.0 and `hermes update` refuses a pip install. Its
    // `--version` reports `Install method: pip` or `git`.
    retiredRegistry: (lastVersion: '0.19.0', installMethod: 'pip'),
  ),
  AgentRuntimeDefinition(
    id: 'cli:openclaw',
    label: 'OpenClaw',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    // npm installations are still detected and repaired. New installations
    // use the official installer, which also brings in a Node.js new enough
    // for OpenClaw (24.22.1+ or 26.12.1+ since 2026.10.9) where npm would
    // install a CLI the host's Node cannot start.
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
    posixInstallerUrl: 'https://openclaw.ai/install.sh',
    windowsInstallerUrl: 'https://openclaw.ai/install.ps1',
    installerEnvironment: {
      'OPENCLAW_NO_ONBOARD': '1',
      'OPENCLAW_NO_PROMPT': '1',
    },
    selfUpdateArguments: ['update', '--yes'],
    // Since 2026.9.5, an update handed to a managed Gateway's background
    // helper exits 75: accepted and still running.
    backgroundUpdateExitCode: 75,
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
    officialVersionLookup: _grokVersionLookup,
  ),
  AgentRuntimeDefinition(
    id: 'cli:muse',
    label: 'Muse Code',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.museCode,
    executableNames: ['muse'],
    posixInstallerUrl: 'https://dev.meta.ai/install.sh',
    windowsInstallerUrl: 'https://dev.meta.ai/install.ps1',
    homebrewFormula: 'muse-code',
    officialVersionLookup: (
      url: 'https://api.meta.ai/muse-code/channels/muse-stable',
      pattern: _jsonVersionPattern,
    ),
    versionEnvironment: {'MUSE_NO_AUTO_UPDATE': '1'},
    // Muse's launcher owns updates. Force its documented synchronous update
    // path against the resolved installation rather than installing a second
    // copy.
    syncUpdateEnvironment: {
      'MUSE_SYNC_UPDATE': '1',
      'MUSE_NO_AUTO_UPDATE': '0',
    },
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
    executableNames: ['opencode2', 'opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: '@opencode/cli',
    homebrewFormula: 'opencode-v2',
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
    packageExtras: ['acp'],
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
  AgentRuntimeDefinition(
    id: 'acp:muse',
    label: 'Muse Code ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.museCode,
    executableNames: ['muse-code-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: '@bex-co/muse-code-acp',
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
  // Muse prints the marketing version first and its actual release in brackets.
  final muse = RegExp(r'Muse Code [^\r\n]*\((\d+\.\d+\.\d+-R\d+(?:\.\d+)?)\)')
      .firstMatch(output);
  if (muse != null) return muse.group(1);
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
  // Muse release revisions use R-prefixed integers, not lexical prereleases.
  if (RegExp(r'^R\d+(?:\.\d+)?$').hasMatch(a.pre!) &&
      RegExp(r'^R\d+(?:\.\d+)?$').hasMatch(b.pre!)) {
    return compareAgentVersions(a.pre!.substring(1), b.pre!.substring(1));
  }
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
  if (process.platform === 'win32') {
    for (const name of ['@opencode/cli', '@opencode-ai/cli', 'opencode-ai']) {
      candidates.push(path.join(dir, 'node_modules', name));
    }
  }
  for (const candidate of candidates) {
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(candidate, 'package.json'), 'utf8'));
      if (['@opencode/cli', '@opencode-ai/cli', 'opencode-ai'].includes(pkg.name) && fs.existsSync(path.join(candidate, 'postinstall.mjs'))) {
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
  String? installedVersion,
}) {
  // A legacy installation's updater targets the old package (OpenCode V1 ->
  // opencode-ai). Keep it intact until the user installs the new package.
  final legacy = definition.legacyInstallation;
  if (update &&
      installedVersion != null &&
      legacy != null &&
      compareAgentVersions(installedVersion, legacy.belowVersion) < 0) {
    return null;
  }
  // Neither the retired registry nor the agent's own updater can move an
  // installation the registry owns forward; the user replaces it instead.
  if (update &&
      definition.retiredRegistry != null &&
      _retiredRegistrySources(definition).contains(detectionSource)) {
    return null;
  }
  final repairScript = definition.repairScript;
  if (repair && repairScript != null && executablePath != null) {
    if (windows) {
      return buildCompactWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble& node -e '
        '${powerShellSingleQuote(repairScript)} '
        '${powerShellSingleQuote(executablePath)}; exit \u0024LASTEXITCODE',
        plainTextOutput: true,
      );
    }
    return '${_profilePrefix}node -e ${_shellQuote(repairScript)} '
        '${_shellQuote(executablePath)}';
  }
  if (update &&
      definition.launcherOwnsUpdates &&
      detectionSource != 'Homebrew') {
    if (executablePath == null) return null;
    final arguments = definition.versionArguments;
    if (windows) {
      return buildCompactWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble'
        '${_powerShellEnvironment(definition.syncUpdateEnvironment)}'
        '& ${powerShellSingleQuote(executablePath)} ${arguments.join(' ')}; '
        r'exit $LASTEXITCODE',
        plainTextOutput: true,
      );
    }
    return '$_profilePrefix${_posixEnvironment(definition.syncUpdateEnvironment)}'
        '${_shellQuote(executablePath)} ${arguments.join(' ')}';
  }
  // Homebrew owns the files of a copy it installed, and some updaters refuse
  // one (`hermes update`).
  final formula = definition.homebrewFormula;
  final homebrewCopy = detectionSource == 'Homebrew' && formula != null;
  if (update &&
      executablePath != null &&
      definition.supportsSelfUpdate &&
      !homebrewCopy) {
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
    final environment = definition.updateEnvironment.isEmpty
        ? ''
        : 'env ${_posixEnvironment(definition.updateEnvironment)}';
    return '$_profilePrefix$environment${_shellQuote(executablePath)} '
        '${definition.selfUpdateArguments.map(_shellQuote).join(' ')}';
  }
  if (update && detectionSource == 'PATH') return null;
  if (update && homebrewCopy) {
    return windows
        ? null
        : '$_profilePrefix brew upgrade ${_shellQuote(formula)}';
  }
  final installerUrl = windows
      ? definition.windowsInstallerUrl
      : definition.posixInstallerUrl;
  // A repair finishes the package that is there; it never switches an
  // installation to the official installer.
  if (installerUrl != null && !(repair && definition.registry != null)) {
    return _buildOfficialAgentInstallerCommand(
      installerUrl,
      windows: windows,
      environment: definition.installerEnvironment,
    );
  }
  final package = definition.packageName;
  if (package == null) return null;
  // pipx upgrade and reinstall take the installed name; install commands take
  // the spec so a package's extras come with it.
  final spec = definition.installPackageSpec!;
  // pipx reinstall keeps the spec an installation was made with, so it cannot
  // add extras an older install left out. Repair those by reinstalling from
  // the spec instead.
  final pipxRepairsFromSpec = definition.packageExtras.isNotEmpty;
  if (windows) {
    final quotedPackage = powerShellSingleQuote(package);
    final quotedSpec = powerShellSingleQuote(spec);
    final quotedLatest = powerShellSingleQuote('$package@latest');
    // npm 12 skips a global package's own install scripts unless
    // --allow-scripts names it; --ignore-scripts=false no longer covers them.
    // Older npm runs them anyway and at most warns about the unknown option.
    final allowScripts = powerShellSingleQuote('--allow-scripts=$package');
    final script = switch (definition.registry) {
      AgentPackageRegistry.npm => [
        powerShellProfilePathPreamble,
        if (repair) ...[
          '& npm uninstall -g $quotedPackage;',
          r'if($LASTEXITCODE -ne 0){exit $LASTEXITCODE};',
        ],
        '& npm install -g --foreground-scripts --ignore-scripts=false $allowScripts $quotedLatest;',
        r'exit $LASTEXITCODE',
      ].join(),
      AgentPackageRegistry.pipx => [
        powerShellProfilePathPreamble,
        'if(Get-Command pipx -ErrorAction SilentlyContinue){',
        if (repair && pipxRepairsFromSpec)
          '& pipx install --force $quotedSpec;'
        else if (repair)
          '& pipx reinstall $quotedPackage;'
        else if (update)
          '& pipx upgrade $quotedPackage;'
        else
          '& pipx install $quotedSpec;',
        r'if($LASTEXITCODE -eq 0){exit 0}};',
        if (repair)
          '& py -m pip install --user --upgrade --force-reinstall $quotedSpec;'
        else if (update)
          '& py -m pip install --user --upgrade $quotedSpec;'
        else
          '& py -m pip install --user $quotedSpec;',
        r'exit $LASTEXITCODE',
      ].join(),
      null => null,
    };
    return script == null
        ? null
        : buildCompactWindowsPowerShellCommand(script, plainTextOutput: true);
  }
  final npmInstall =
      'npm install -g --foreground-scripts --ignore-scripts=false '
      '${_shellQuote('--allow-scripts=$package')} ${_shellQuote(package)}@latest';
  return switch (definition.registry) {
    AgentPackageRegistry.npm =>
      repair
          ? '$_profilePrefix npm uninstall -g ${_shellQuote(package)} && $npmInstall'
          : '$_profilePrefix $npmInstall',
    AgentPackageRegistry.pipx =>
      repair
          ? '$_profilePrefix ${pipxRepairsFromSpec ? 'pipx install --force ${_shellQuote(spec)}' : 'pipx reinstall ${_shellQuote(package)}'} || python3 -m pip install --user --upgrade --force-reinstall ${_shellQuote(spec)}'
          : update
          ? '$_profilePrefix pipx upgrade ${_shellQuote(package)} || python3 -m pip install --user --upgrade ${_shellQuote(spec)}'
          : '$_profilePrefix pipx install ${_shellQuote(spec)} || python3 -m pip install --user ${_shellQuote(spec)}',
    null => null,
  };
}

/// Time limits for remote agent probes and commands.
@immutable
class AgentProbeTimeouts {
  /// Creates time limits with the production defaults.
  const AgentProbeTimeouts({
    this.batchProbe = const Duration(seconds: 8),
    this.metadataProbe = const Duration(seconds: 30),
    this.metadataProbeBase = const Duration(seconds: 20),
    this.usageProbe = const Duration(seconds: 14),
    this.install = const Duration(seconds: 18),
    this.defaultRun = const Duration(seconds: 15),
  });

  /// Base timeout for a batch of runtime probes.
  final Duration batchProbe;

  /// Timeout for one group of registry metadata probes.
  final Duration metadataProbe;

  /// Base of the batched registry-metadata timeout, which grows by 10 seconds
  /// for every four installed runtimes.
  final Duration metadataProbeBase;

  /// Timeout for a usage probe.
  final Duration usageProbe;

  /// Timeout for an install-related probe.
  final Duration install;

  /// Default command and exec-channel opening timeout.
  final Duration defaultRun;
}

/// Inspects and manages coding-agent runtimes over non-interactive SSH exec.
class AgentManagementService {
  /// Creates the service.
  AgentManagementService(
    this._discovery, {
    required Future<bool> Function() canManageAgents,
    DateTime Function()? now,
    AgentProbeTimeouts timeouts = const AgentProbeTimeouts(),
  }) : _timeouts = timeouts,
       _canManageAgents = canManageAgents,
       _now = now ?? DateTime.now;

  final AgentProbeTimeouts _timeouts;
  final Future<bool> Function() _canManageAgents;
  final DateTime Function() _now;
  final _runningInstallations = Expando<Set<String>>();

  static const _updateCheckTtl = Duration(minutes: 15);
  static const _maxRuntimeCacheEntries = 32;
  static const _usageSnapshotTtl = Duration(hours: 1);

  final AgentSessionDiscoveryService _discovery;
  final Map<int, ({DateTime checkedAt, List<AgentRuntimeInfo> runtimes})>
  _runtimeCache = {};
  final Map<int, Future<List<AgentRuntimeInfo>>> _inFlightUpdateChecks = {};
  final Map<
    int,
    ({
      SshSession session,
      String selection,
      List<bool Function()> observers,
      Future<Map<String, AgentUsage>> future,
    })
  >
  _inFlightUsageChecks = {};
  final Map<
    int,
    ({
      SshSession session,
      DateTime at,
      Map<String, String> paths,
      Map<String, AgentUsage> values,
      Map<String, Set<DateTime>> refreshedResets,
    })
  >
  _usageCache = {};

  // Cooldowns contain no quota values or account identifiers. They survive a
  // reconnect to the same saved host; quota snapshots themselves stay session-bound.
  final _usageCooldowns =
      <(int, String), ({DateTime checkedAt, DateTime retryAt, int attempts})>{};

  AgentUsage? _activeUsageCooldown(SshSession session, String id) {
    _usageCooldowns.removeWhere(
      (_, entry) =>
          _now().difference(entry.retryAt) >= const Duration(hours: 1),
    );
    final held = _usageCooldowns[(session.hostId, id)];
    if (held == null || !held.retryAt.isAfter(_now())) return null;
    return AgentUsage(
      status: AgentUsageStatus.rateLimited,
      checkedAt: held.checkedAt,
      retryAt: held.retryAt,
    );
  }

  AgentUsage _rememberUsageCooldown(
    SshSession session,
    String id,
    AgentUsage usage,
  ) {
    final key = (session.hostId, id);
    if (!usage.isRateLimited) {
      if (usage.status == AgentUsageStatus.available &&
          !usage.notices.any(
            (notice) => notice.status != AgentUsageStatus.notReported,
          )) {
        _usageCooldowns.remove(key);
      }
      return usage;
    }
    final previous = _usageCooldowns[key];
    final attempts = (previous?.attempts ?? 0) >= 4
        ? 4
        : (previous?.attempts ?? 0) + 1;
    var retryAt = _now().add(agentUsageThrottleBackoff(attempts));
    if (usage.retryAt?.isAfter(retryAt) ?? false) retryAt = usage.retryAt!;
    if (previous?.retryAt.isAfter(retryAt) ?? false) {
      retryAt = previous!.retryAt;
    }
    _usageCooldowns.remove(key);
    if (_usageCooldowns.length >=
        _maxRuntimeCacheEntries * agentCliRuntimeDefinitions.length) {
      _usageCooldowns.remove(_usageCooldowns.keys.first);
    }
    _usageCooldowns[key] = (
      checkedAt: usage.checkedAt ?? _now(),
      retryAt: retryAt,
      attempts: attempts,
    );
    return usage.withRetryAt(retryAt);
  }

  /// Number of retained connection snapshots.
  @visibleForTesting
  int get cachedConnectionCount => _runtimeCache.length;

  /// The last full probe of [session] and any quotas read for it, while both
  /// are fresh enough to show. The manager opens on this and re-checks in
  /// place instead of rebuilding from placeholders.
  ({List<AgentRuntimeInfo> runtimes, Map<String, AgentUsage> usage})?
  cachedState(SshSession session) {
    _pruneRuntimeCache();
    final cached = _runtimeCache[session.connectionId];
    if (cached == null) return null;
    final snapshot = _usageCache[session.connectionId];
    final sameSession =
        snapshot != null && identical(snapshot.session, session);
    // Any agent's read moves the entry's timestamp and carries the others
    // forward, so judge each quota by its own read time. A cooldown that is
    // still running stays worth showing, as it does in the cache prune.
    bool current(AgentUsage usage) {
      final checkedAt = usage.checkedAt;
      return (checkedAt != null &&
              _now().difference(checkedAt) < _usageSnapshotTtl) ||
          (usage.retryAt?.isAfter(_now()) ?? false);
    }

    return (
      runtimes: List.unmodifiable(
        _holdBackgroundUpdates(session, cached.runtimes),
      ),
      usage: {
        if (sameSession)
          for (final runtime in cached.runtimes)
            if (runtime.definition.usageId case final id?
                when runtime.executablePath != null &&
                    snapshot.paths[id] == runtime.executablePath)
              if (snapshot.values[id] case final usage? when current(usage))
                runtime.definition.id: usage,
      },
    );
  }

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
      return _holdBackgroundUpdates(session, cached.runtimes);
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
    _invalidateUsageRuntime(session);
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
        timeout:
            _timeouts.batchProbe +
            Duration(
              seconds: session.remoteIsWindows
                  ? ((definitions.length + 3) ~/ 4) * 6
                  : 0,
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
    onDiscovered?.call(
      _holdBackgroundUpdates(session, [
        for (final definition in definitions)
          _resolveRuntimeInfo(
            definition,
            snapshots[definition.id] ?? const AgentProbeSnapshot(),
          ),
      ]),
    );
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
          timeout:
              _timeouts.metadataProbeBase +
              Duration(seconds: ((installedDefinitions.length + 3) ~/ 4) * 10),
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
    return _holdBackgroundUpdates(session, _cacheRuntimes(session, runtimes));
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
    if (definition.kind == AgentRuntimeKind.cli && definition.tool != null) {
      _invalidateUsageRuntime(session, tool: definition.tool);
    }
    try {
      final probeOutput = await _run(
        session,
        buildAgentBatchProbeCommand([
          definition,
        ], windows: session.remoteIsWindows),
        priority: priority,
        timeout: _timeouts.batchProbe,
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
            timeout: _timeouts.metadataProbe,
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
        message: 'Required setup scripts did not run. Repair the installation before launching this agent.',
      );
    }
    var source = metadata?.detectionSource;
    source ??= _executableBasename(path) == 'npx'
        ? 'npx on demand'
        : _detectionSourceFromPath(path);
    installed ??= parseAgentVersion(metadata?.installedVersionOutput ?? '');
    // The source names the running copy, not whatever a retired registry
    // still lists.
    final retiredSource = _retiredRegistrySource(
      definition,
      source: source,
      installed: installed,
      versionOutput: snapshot.versionOutput,
    );
    if (retiredSource != null) {
      source = retiredSource;
    } else if (definition.retiredRegistry != null &&
        source == _registrySource(definition.registry)) {
      source = _detectionSourceFromPath(path);
    } else if (source == 'Homebrew' &&
        _installMethodPattern
                .firstMatch(snapshot.versionOutput ?? '')
                ?.group(1) ==
            'git') {
      // Hermes names the running copy's install method. A git checkout
      // updates itself, whatever formula Homebrew also lists.
      source = _detectionSourceFromPath(path);
    }
    final latest = parseAgentVersion(metadata?.latestVersionOutput ?? '');
    final hasUpdate =
        installed != null &&
        latest != null &&
        compareAgentVersions(installed, latest) < 0;
    final legacy = definition.legacyInstallation;
    final isLegacyInstallation =
        legacy != null &&
        installed != null &&
        compareAgentVersions(installed, legacy.belowVersion) < 0;
    final retired = retiredSource != null;
    final managed =
        !isLegacyInstallation &&
        !retired &&
        (definition.supportsSelfUpdate ||
            definition.launcherOwnsUpdates ||
            source == 'Homebrew' ||
            source == 'npm global' ||
            source == 'pipx');
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
          ? isLegacyInstallation
                ? legacy.message
                : retired
                ? _retiredRegistryMessage(definition, retiredSource, path)
                : 'Update this PATH installation with its original installer, then re-check.'
          : null,
    );
  }

  final _usageRuntimeCache =
      Expando<
        Map<AgentLaunchTool, ({DateTime at, AgentRuntimeInfo runtime})>
      >();

  final _usageRuntimeRevisions = Expando<Map<AgentLaunchTool, Object>>();

  void _invalidateUsageRuntime(SshSession session, {AgentLaunchTool? tool}) {
    if (tool == null) {
      _usageRuntimeCache[session] = null;
      _usageRuntimeRevisions[session] = null;
    } else {
      _usageRuntimeCache[session]?.remove(tool);
      final revisions = _usageRuntimeRevisions[session] ??= {};
      revisions[tool] = Object();
    }
  }

  /// Reads one installed CLI's account allowances without update/registry checks.
  /// [shouldContinue] prevents a quota read after an abandoned path probe.
  Future<AgentUsage?> readUsageForTool(
    SshSession session,
    AgentLaunchTool tool, {
    bool Function()? shouldContinue,
  }) async {
    bool current() => shouldContinue?.call() ?? true;
    if (!current() || !await _canManageAgents() || !current()) return null;
    final definition = agentCliRuntimeDefinitions
        .where((item) => item.tool == tool)
        .firstOrNull;
    final usageId = definition?.usageId;
    if (definition == null || usageId == null) return null;
    final cooldown = _activeUsageCooldown(session, usageId);
    if (cooldown != null) {
      // A multi-provider response can contain usable quotas alongside a
      // throttled account. Retain that same-session snapshot without probing;
      // ring projection still enforces its original age and reset deadlines.
      final snapshot = _usageCache[session.connectionId];
      final usage = identical(snapshot?.session, session)
          ? snapshot?.values[usageId]
          : null;
      return (usage?.isRateLimited ?? false)
          ? usage!.withRetryAt(cooldown.retryAt!)
          : cooldown;
    }
    final cache = _usageRuntimeCache[session] ??= {};
    final revisions = _usageRuntimeRevisions[session] ??= {};
    final revision = revisions.putIfAbsent(tool, Object.new);
    bool runtimeCurrent() =>
        current() &&
        identical(_usageRuntimeRevisions[session], revisions) &&
        identical(revisions[tool], revision);
    var runtime = cache[tool];
    if (runtime == null || _now().difference(runtime.at) >= _updateCheckTtl) {
      final AgentRuntimeActionResult result;
      try {
        result = await _run(
          session,
          buildAgentBatchProbeCommand([
            definition,
          ], windows: session.remoteIsWindows),
          priority: SshExecPriority.low,
          timeout: _timeouts.usageProbe,
          shouldContinue: runtimeCurrent,
        );
      } on _UsageReadCancelled {
        return null;
      }
      if (!runtimeCurrent()) return null;
      final snapshot = parseAgentBatchProbeOutput(result.output)[definition.id];
      // A failed/incomplete probe is not proof that the CLI is absent.
      if (!result.succeeded || snapshot == null) return null;
      final path = snapshot.executablePath;
      final installed = AgentRuntimeInfo(
        definition: definition,
        status: path == null
            ? AgentRuntimeStatus.notInstalled
            : AgentRuntimeStatus.installed,
        executablePath: path,
      );
      runtime = (at: _now(), runtime: installed);
      cache[tool] = runtime;
    }
    if (!runtimeCurrent()) return null;
    final usage = await _readUsageWhenCurrent(session, [
      runtime.runtime,
    ], shouldContinue: runtimeCurrent);
    return runtimeCurrent() ? usage[definition.id] : null;
  }

  /// Reads quotas requested by the manager or a visible Pro usage-ring icon.
  /// Never runs as part of version checks. Credentials remain on the host.
  Future<Map<String, AgentUsage>> readUsage(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) => _readUsageWhenCurrent(session, runtimes);

  Future<Map<String, AgentUsage>> _readUsageWhenCurrent(
    SshSession session,
    List<AgentRuntimeInfo> runtimes, {
    bool Function()? shouldContinue,
  }) async {
    bool current() => shouldContinue?.call() ?? true;
    if (!current() || !await _canManageAgents() || !current()) return const {};
    final snapshot = runtimes
        .where((runtime) => runtime.definition.kind == AgentRuntimeKind.cli)
        .toList();
    final selectedRows = [
      for (final runtime in snapshot)
        if (runtime.status == AgentRuntimeStatus.installed ||
            runtime.status == AgentRuntimeStatus.updateAvailable)
          jsonEncode([runtime.definition.id, runtime.executablePath]),
    ]..sort();
    final selection = jsonEncode(selectedRows);
    while (true) {
      if (!current() || !await _canManageAgents() || !current()) {
        return const {};
      }
      final existing = _inFlightUsageChecks[session.connectionId];
      if (existing == null) break;
      if (identical(existing.session, session) &&
          existing.selection == selection) {
        // A dismissed ring must not cancel another visible consumer's request.
        existing.observers.add(current);
        final result = await existing.future;
        return current() && await _canManageAgents() && current()
            ? result
            : const {};
      }
      await existing.future;
      if (!current()) return const {};
    }
    final observers = <bool Function()>[current];
    bool requested() => observers.any((observer) => observer());
    late final Future<Map<String, AgentUsage>> check;
    check = _readUsage(session, snapshot, shouldContinue: requested)
        .whenComplete(() {
          if (identical(
            _inFlightUsageChecks[session.connectionId]?.future,
            check,
          )) {
            _inFlightUsageChecks.remove(session.connectionId);
          }
        });
    _inFlightUsageChecks[session.connectionId] = (
      session: session,
      selection: selection,
      observers: observers,
      future: check,
    );
    final result = await check;
    // Dispatched reads still cache useful responses and cooldowns, but cancelled
    // callers receive no result and cannot publish it into a different window.
    return current() && await _canManageAgents() && current()
        ? result
        : const {};
  }

  Future<Map<String, AgentUsage>> _readUsage(
    SshSession session,
    List<AgentRuntimeInfo> runtimes, {
    required bool Function() shouldContinue,
  }) async {
    final selected = <String, String>{};
    final refreshIntervals = <String, Duration>{};
    final result = <String, AgentUsage>{};
    for (final runtime in runtimes) {
      if (runtime.status != AgentRuntimeStatus.installed &&
          runtime.status != AgentRuntimeStatus.updateAvailable) {
        continue;
      }
      final id = runtime.definition.usageId;
      if (id != null && runtime.executablePath != null) {
        selected[id] = runtime.executablePath!;
        refreshIntervals[id] = agentUsageRefreshInterval(
          runtime.definition.tool,
        );
      }
      result[runtime.definition.id] = AgentUsage(
        status: id == null
            ? AgentUsageStatus.unsupported
            : AgentUsageStatus.unavailable,
      );
    }
    if (selected.isEmpty) return result;
    _usageCache.removeWhere(
      (_, entry) =>
          _now().difference(entry.at) >= _usageSnapshotTtl &&
          !entry.values.values.any(
            (usage) => usage.retryAt?.isAfter(_now()) ?? false,
          ),
    );
    final snapshot = _usageCache[session.connectionId];
    final cached = identical(snapshot?.session, session) ? snapshot : null;
    final parsed = <String, AgentUsage>{};
    final pending = <String, String>{};
    final refreshedResets = <String, Set<DateTime>>{};
    for (final entry in selected.entries) {
      final usage = cached?.paths[entry.key] == entry.value
          ? cached?.values[entry.key]
          : null;
      final checkedAt = usage?.checkedAt;
      final cooldown = _activeUsageCooldown(session, entry.key);
      if (cooldown != null) {
        parsed[entry.key] = (usage?.isRateLimited ?? false)
            ? usage!.withRetryAt(cooldown.retryAt!)
            : cooldown;
        continue;
      }
      final refreshed = refreshedResets[entry.key] = {
        if (usage != null) ...?cached?.refreshedResets[entry.key],
      };
      final passedResets = {
        for (final window in usage?.windows ?? <AgentUsageWindow>[])
          if (window.resetsAt != null && !window.resetsAt!.isAfter(_now()))
            window.resetsAt!,
      };
      // Retaining other agents must not retain an unbounded history of resets.
      refreshed.removeWhere((reset) => !passedResets.contains(reset));
      final resetPassed = passedResets.difference(refreshed).isNotEmpty;
      final reusable =
          usage != null &&
          checkedAt != null &&
          ((usage.isRateLimited && (usage.retryAt?.isAfter(_now()) ?? false)) ||
              (usage.status == AgentUsageStatus.available &&
                  !usage.isRateLimited &&
                  !usage.notices.any(
                    (notice) => notice.status != AgentUsageStatus.notReported,
                  ) &&
                  _now().difference(checkedAt) < refreshIntervals[entry.key]! &&
                  !resetPassed));
      if (reusable) {
        parsed[entry.key] = usage;
      } else {
        pending[entry.key] = entry.value;
        // Recheck each elapsed reset once, even if it was already stale when
        // first reported. Repeated stale responses must not cause a retry loop.
        refreshed.addAll(passedResets);
      }
    }
    if (pending.isEmpty) {
      return _mapUsageToRuntimes(runtimes, result, selected, parsed);
    }
    try {
      if (!shouldContinue()) throw const _UsageReadCancelled();
      final script = await rootBundle.loadString(
        'assets/scripts/agent_usage_probe.cjs',
      );
      if (!shouldContinue()) throw const _UsageReadCancelled();
      final source = base64.encode(utf8.encode(script));
      final bootstrap =
          "process.env.MONKEYSSH_USAGE_PROBE='1';"
          "eval(Buffer.from('$source','base64').toString())";
      final command = session.remoteIsWindows
          ? buildWindowsAgentUsageCommand(pending)
          : '$_profilePrefix ${buildPosixAgentUsageCommand(bootstrap, pending)}';
      final response = await _run(
        session,
        command,
        input: session.remoteIsWindows
            ? Uint8List.fromList(utf8.encode('$source\n'))
            : null,
        timeout: _timeouts.install,
        keepPartialOutputOnTimeout: true,
        shouldContinue: shouldContinue,
      );
      final rawValues = parseAgentUsageOutput(
        response.output,
        checkedAt: _now(),
      );
      final values = <String, AgentUsage>{
        for (final entry in rawValues.entries)
          if (pending.containsKey(entry.key))
            entry.key: _rememberUsageCooldown(session, entry.key, entry.value),
      };
      parsed.addAll(values);
      for (final entry in values.entries) {
        DiagnosticsLogService.instance.debug(
          'agent.usage',
          'agent_result',
          fields: {
            'connectionId': session.connectionId,
            // The parser accepts only built-in agent IDs and status enums.
            'agentId': entry.key,
            'status': entry.value.status.name,
            'windowCount': entry.value.windows.length,
            'noticeCount': entry.value.notices.length,
          },
        );
      }
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
    } on _UsageReadCancelled {
      return const {};
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
    _usageCache[session.connectionId] = (
      session: session,
      at: _now(),
      // A ring reads one agent; the manager reads many. Preserve unrelated
      // snapshots and their reset markers instead of erasing their cooldowns.
      paths: {...?cached?.paths, ...selected},
      values: {...?cached?.values, ...parsed},
      refreshedResets: {...?cached?.refreshedResets, ...refreshedResets},
    );
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
      final id = runtime.definition.usageId;
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
    // A reopened manager has its own view model. Protect the complete action,
    // including verification and automatic repair, from a second mutation of
    // the same installation through that new screen.
    final running = _runningInstallations[session] ??= <String>{};
    if (_pendingBackgroundUpdates(session).containsKey(definition.id)) {
      return AgentRuntimeActionResult(
        succeeded: false,
        output:
            '${definition.label} is still finishing its last update in the background. Tap Re-check to see it.',
      );
    }
    if (!running.add(definition.id)) {
      return AgentRuntimeActionResult(
        succeeded: false,
        output:
            'An installation or update for ${definition.label} is already running. Wait for it to finish, then tap Re-check.',
      );
    }
    try {
      final result = await _installOrUpdate(
        session,
        definition,
        update: update,
        current: current,
        onOutput: onOutput,
      );
      if (result.finishingInBackground && current != null) {
        (_backgroundUpdates[session] ??= {})[definition.id] = (
          at: _now(),
          runtime: AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            installedVersion: current.installedVersion,
            executablePath: current.executablePath,
            detectionSource: current.detectionSource,
            managedByPackageManager: current.managedByPackageManager,
            message:
                '${definition.label} is finishing its update in the '
                'background. Re-check in a minute to see the new version.',
          ),
        );
      }
      return result;
    } finally {
      running.remove(definition.id);
    }
  }

  // Updates an agent accepted and is finishing in the background (OpenClaw
  // exit 75). A probe meanwhile can find the installation half replaced and
  // offer Install, so probes keep the row as it was, with a note, until
  // Re-check, until a probe shows a different installed version, or for
  // [_backgroundUpdateHold] at most. The service keeps them per session, not
  // the screen, so a reopened Agent Management screen holds them too.
  final _backgroundUpdates =
      Expando<Map<String, ({DateTime at, AgentRuntimeInfo runtime})>>();
  static const _backgroundUpdateHold = Duration(minutes: 10);

  Map<String, ({DateTime at, AgentRuntimeInfo runtime})>
  _pendingBackgroundUpdates(SshSession session) {
    final pending = _backgroundUpdates[session];
    if (pending == null) return const {};
    pending.removeWhere(
      (_, entry) => _now().difference(entry.at) >= _backgroundUpdateHold,
    );
    return pending;
  }

  /// Stops holding [definition]'s row for an update finishing in the
  /// background, so the next probe shows the installation as it is.
  void releaseBackgroundUpdate(
    SshSession session,
    AgentRuntimeDefinition definition,
  ) {
    _backgroundUpdates[session]?.remove(definition.id);
  }

  List<AgentRuntimeInfo> _holdBackgroundUpdates(
    SshSession session,
    List<AgentRuntimeInfo> fresh,
  ) {
    final pending = _pendingBackgroundUpdates(session);
    if (pending.isEmpty) return fresh;
    for (final runtime in fresh) {
      final held = pending[runtime.definition.id]?.runtime;
      if (held != null &&
          (runtime.status == AgentRuntimeStatus.installed ||
              runtime.status == AgentRuntimeStatus.updateAvailable) &&
          runtime.installedVersion != null &&
          runtime.installedVersion != held.installedVersion) {
        pending.remove(runtime.definition.id);
      }
    }
    return [
      for (final runtime in fresh)
        pending[runtime.definition.id]?.runtime ?? runtime,
    ];
  }

  Future<AgentRuntimeActionResult> _installOrUpdate(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required bool update,
    AgentRuntimeInfo? current,
    ValueChanged<String>? onOutput,
  }) async {
    final command = buildAgentInstallCommand(
      definition,
      windows: session.remoteIsWindows,
      update: update,
      repair: current?.status == AgentRuntimeStatus.needsRepair,
      detectionSource: current?.detectionSource,
      executablePath: current?.executablePath,
      installedVersion: current?.installedVersion,
    );
    if (command == null) {
      return const AgentRuntimeActionResult(
        succeeded: false,
        output: 'No safe automatic installer is available for this tool. Use its official installation instructions, then tap Re-check.',
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
      result = await _run(
        session,
        command,
        onOutput: onOutput,
        unlimitedTimeout: true,
      );
      // An accepted background update may be replacing the installation
      // right now, so a check at this point proves nothing either way.
      final acceptedInBackground =
          update &&
          result.exitCode != null &&
          result.exitCode == definition.backgroundUpdateExitCode;
      if (acceptedInBackground) {
        final message =
            '\n${definition.label} accepted the update and is finishing it '
            'in the background. Tap Re-check in a minute to see the new '
            'version. Running the update again will not speed it up.\n';
        onOutput?.call(message);
        result = AgentRuntimeActionResult(
          succeeded: true,
          exitCode: result.exitCode,
          output: '${result.output}$message',
          finishingInBackground: true,
        );
      }
      if (result.succeeded &&
          !acceptedInBackground &&
          definition.kind == AgentRuntimeKind.cli) {
        var verified = await inspect(session, definition);
        // An updater can leave its package's postinstall scripts pending.
        // Finish setup on the newly detected launcher, not the old path or a
        // different global package installation.
        if (update &&
            !repairing &&
            definition.repairScript != null &&
            verified.status == AgentRuntimeStatus.needsRepair) {
          final repairCommand = buildAgentInstallCommand(
            definition,
            windows: session.remoteIsWindows,
            update: false,
            repair: true,
            executablePath: verified.executablePath,
          );
          if (repairCommand != null) {
            DiagnosticsLogService.instance.info(
              'agent.management',
              'action_auto_repair',
              fields: {
                'connectionId': session.connectionId,
                'agentId': definition.id,
              },
            );
            const message =
                '\nRequired setup scripts did not run. Repairing OpenCode automatically.\n';
            onOutput?.call(message);
            late final AgentRuntimeActionResult repairResult;
            try {
              repairResult = await _run(
                session,
                repairCommand,
                onOutput: onOutput,
                unlimitedTimeout: true,
              );
            } on Object catch (error) {
              repairResult = AgentRuntimeActionResult(
                succeeded: false,
                output: 'Required setup could not be completed. $error',
              );
            }
            result = AgentRuntimeActionResult(
              succeeded: repairResult.succeeded,
              exitCode: repairResult.exitCode,
              output: '${result.output}$message${repairResult.output}',
            );
            if (repairResult.succeeded) {
              verified = await inspect(session, definition);
            }
          }
        }
        final healthy =
            result.succeeded &&
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

      // The result dialog is plain text. Strip terminal colors and cursor
      // controls after assembling update and repair output, since escapes can
      // cross SSH packets.
      result = AgentRuntimeActionResult(
        succeeded: result.succeeded,
        exitCode: result.exitCode,
        output: result.output
            .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
            .trim(),
        finishingInBackground: result.finishingInBackground,
      );
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
    } finally {
      if (definition.kind == AgentRuntimeKind.cli && definition.tool != null) {
        _invalidateUsageRuntime(session, tool: definition.tool);
      }
    }
    _runtimeCache.remove(session.connectionId);
    _discovery.invalidateSession(session);
    return result;
  }

  Future<AgentRuntimeActionResult> _run(
    SshSession session,
    String command, {
    ValueChanged<String>? onOutput,
    Duration? timeout,
    bool unlimitedTimeout = false,
    bool keepPartialOutputOnTimeout = false,
    Uint8List? input,
    SshExecPriority priority = SshExecPriority.normal,
    bool Function()? shouldContinue,
  }) => session.runQueuedExec(() async {
    if (shouldContinue != null &&
        (!shouldContinue() || !await _canManageAgents() || !shouldContinue())) {
      throw const _UsageReadCancelled();
    }
    final runTimeout = unlimitedTimeout
        ? null
        : timeout ?? _timeouts.defaultRun;
    final exec = await openSshExec(
      session.execute(command),
      runTimeout ?? _timeouts.defaultRun,
    );
    var finished = false;
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
      if (runTimeout == null) {
        await completion;
        finished = true;
      } else {
        try {
          await completion.timeout(runTimeout);
          finished = true;
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
      if (finished) {
        exec.close();
      } else {
        // EOF alone does not release a channel whose process ignores stdin.
        // Send CHANNEL_CLOSE when abandoning a failed or timed-out probe.
        exec.channel.destroy();
      }
    }
  }, priority: priority);
}

class _UsageReadCancelled implements Exception {
  const _UsageReadCancelled();
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
  int versionTimeoutSeconds = 5,
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

  final command =
      StringBuffer(
          _posixVersionRunner(versionTimeoutSeconds: versionTimeoutSeconds),
        )
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
      final layout = definition.installerLayout;
      if (layout != null) {
        body.write(_windowsInstallerLayoutSource(definition, layout));
      }
      if (package != null && definition.registry == AgentPackageRegistry.npm) {
        final needle = powerShellSingleQuote('$package@');
        body.write(
          '\$__flNeedle=$needle;'
          r'$__flLine=($__flNpmGlobal -split "`n" | Where-Object { $_.Contains($__flNeedle) } | Select-Object -First 1);'
          // The installer's launcher, not a leftover npm package, runs.
          '${layout == null ? '' : r'if($__flManaged){$__flLine=$null};'}'
          r'if($null -ne $__flLine){'
          '[void]\$__flOut.AppendLine(${powerShellSingleQuote('$_sourceMarker npm global')});'
          r'$__flInstalled=$__flLine.Substring($__flLine.IndexOf($__flNeedle)+$__flNeedle.Length).Split(" ")[0]};',
        );
        if (definition.officialVersionLookup == null) {
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
        if (definition.officialVersionLookup == null) {
          body.write(
            '\$__flLatest=Invoke-AgentProbe ${powerShellSingleQuote('& py -m pip index versions ${powerShellSingleQuote(package)} --retries 0 --timeout 3 2>\$null; exit \$LASTEXITCODE')};',
          );
        }
      }
      final official = _fallbackVersionLookup(definition);
      if (official != null) {
        final pattern = official.pattern.replaceAll('[[:space:]]', r'\s');
        var uri = powerShellSingleQuote(official.url);
        if (definition.latestVersionUrlPlatformSuffix) {
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

  final command = StringBuffer('$_profilePrefix\n${_posixVersionRunner()}')
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
    if (definition.installerLayout case final layout?) {
      command.write(_posixInstallerLayoutSource(definition, layout));
    }
    if (formula != null) {
      // A listed formula or cask counts only when the executable that runs
      // resolves into its keg or Caskroom (Muse ships as a cask). Another
      // copy ahead on PATH updates its own way.
      command.write(
        'if [ -z "\$__fl_source" ]; then '
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_brew_global" | '
        'grep -E ${_shellQuote('^$formula([[:space:]]|\$)')} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '${_posixResolvedLauncher(definition)}'
        'case "\$__fl_launcher" in */Cellar/${_shellQuote(formula)}/*|*/Caskroom/${_shellQuote(formula)}/*) '
        '__fl_source=${_shellQuote('Homebrew')}; '
        '__fl_installed=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_line" | awk ${_shellQuote('{print \u00242}')});; '
        'esac; fi; fi; ',
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
      if (definition.officialVersionLookup == null) {
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
      if (definition.officialVersionLookup == null) {
        command.write(
          '__fl_latest=\$(__fl_agent_version python3 -m pip index versions ${_shellQuote(package)} 2>/dev/null | head -n 1); ',
        );
      }
    }
    final official = _fallbackVersionLookup(definition);
    if (official != null) {
      var uri = _shellQuote(official.url);
      if (definition.latestVersionUrlPlatformSuffix) {
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
      if (definition.versionEnvironment.isNotEmpty)
        '\$__flScript = ${powerShellSingleQuote(_powerShellEnvironment(definition.versionEnvironment))} + \$__flScript;',
      r'$__flVersion = Invoke-AgentProbe $__flScript;',
      'if(\$__flVersion){[void]\$__flOut.AppendLine(${powerShellSingleQuote(_versionMarker)} + ((\$__flVersion -split "`r?`n" | Select-Object -First 4) -join " "))}',
      'elseif(\$__flProbeFailure -match ${powerShellSingleQuote(_skippedPostinstallPattern)}){[void]\$__flOut.AppendLine(${powerShellSingleQuote(_repairMarker)})};',
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
  final versionEnvironment = definition.versionEnvironment.isEmpty
      ? ''
      : 'env ${_posixEnvironment(definition.versionEnvironment)}';
  final versionProbe = definition.kind == AgentRuntimeKind.cli
      ? '__fl_version_file=\$(mktemp "\u0024{TMPDIR:-/tmp}/monkeyssh-version.XXXXXX" 2>/dev/null || true); '
            'if [ -n "\$__fl_version_file" ]; then '
            'version_output=; '
            'if __fl_agent_version $versionEnvironment"\$resolved" $versionArguments >"\$__fl_version_file" 2>&1; then '
            'version_output=\$(head -n 4 "\$__fl_version_file" | tr ${_shellQuote(r'\r\n')} ${_shellQuote('  ')}); '
            'elif grep -Eiq ${_shellQuote(_skippedPostinstallPattern)} "\$__fl_version_file"; then '
            'printf ${_shellQuote('$_repairMarker\n')}; '
            'fi; '
            'rm -f "\$__fl_version_file"; '
            '${definition.posixVersionFallback ?? ''}'
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

// The line Hermes's `--version` prints for the running copy.
final _installMethodPattern = RegExp(r'Install method: (\S+)');

/// Sources of a copy installed from [definition]'s retired registry: its
/// package manager, or plain pip, which pipx installs through.
Set<String> _retiredRegistrySources(AgentRuntimeDefinition definition) => {
  ?_registrySource(definition.registry),
  if (definition.registry == AgentPackageRegistry.pipx) 'pip',
};

/// The install source of the running copy when [definition]'s retired
/// registry installed it, or null (see
/// [AgentRuntimeDefinition.retiredRegistry]).
String? _retiredRegistrySource(
  AgentRuntimeDefinition definition, {
  required String source,
  required String? installed,
  required String? versionOutput,
}) {
  final retired = definition.retiredRegistry;
  final registrySource = _registrySource(definition.registry);
  if (retired == null || registrySource == null) return null;
  final method = _installMethodPattern
      .firstMatch(versionOutput ?? '')
      ?.group(1);
  if (method != null) {
    if (method != retired.installMethod) return null;
    // Without a pipx listing, a pip-installed copy came from pip itself.
    return source == registrySource ||
            definition.registry != AgentPackageRegistry.pipx
        ? registrySource
        : 'pip';
  }
  return source == registrySource &&
          installed != null &&
          compareAgentVersions(installed, retired.lastVersion) <= 0
      ? registrySource
      : null;
}

String _retiredRegistryMessage(
  AgentRuntimeDefinition definition,
  String source,
  String path,
) {
  final package = definition.packageName;
  final python = path.contains(r'\') ? 'py' : 'python3';
  final uninstall = source == 'pip'
      ? '$python -m pip uninstall $package'
      : 'pipx uninstall $package';
  return '${definition.label} stopped publishing to PyPI at '
      '${definition.retiredRegistry!.lastVersion}, so this $source '
      'installation cannot update. Run `$uninstall` on the host (settings '
      'stay), then re-check and install ${definition.label} again.';
}

/// Install source the metadata probe reports for [registry]'s installations.
String? _registrySource(AgentPackageRegistry? registry) => switch (registry) {
  AgentPackageRegistry.npm => 'npm global',
  AgentPackageRegistry.pipx => 'pipx',
  null => null,
};

String _detectionSourceFromPath(String path) {
  final normalized = path.toLowerCase();
  if (normalized.contains('/.cargo/')) return 'Cargo';
  return 'PATH';
}

/// Sets `__fl_source` when the first of [definition]'s executables on PATH is
/// an installer-managed launcher (see
/// [AgentRuntimeDefinition.installerLayout]).
String _posixInstallerLayoutSource(
  AgentRuntimeDefinition definition,
  ({String marker, String source}) layout,
) =>
    '${_posixResolvedLauncher(definition)}'
    r'case "$__fl_launcher" in */bin/*) '
    'if [ -f "\${__fl_launcher%/bin/*}"${_shellQuote('/${layout.marker}')} ]; then '
    '__fl_source=${_shellQuote(layout.source)}; fi;; esac; ';

/// Sets `__fl_launcher` to the physical path of the first of [definition]'s
/// executables on PATH. Symlinks are followed by hand, as the launchers do,
/// because `readlink -f` is not portable; each hop takes the physical
/// directory, so a symlinked `bin` directory resolves too.
String _posixResolvedLauncher(AgentRuntimeDefinition definition) =>
    '__fl_launcher=; for __fl_name in '
    '${definition.executableNames.map(_shellQuote).join(' ')}; do '
    r'__fl_launcher=$(command -v "$__fl_name" 2>/dev/null) && break; done; '
    r'__fl_hops=0; while [ -n "$__fl_launcher" ] && [ "$__fl_hops" -lt 16 ]; do '
    r'__fl_dir=$(CDPATH= cd -P "${__fl_launcher%/*}" 2>/dev/null && pwd -P) || break; '
    r'__fl_launcher=$__fl_dir/${__fl_launcher##*/}; '
    r'[ -L "$__fl_launcher" ] || break; '
    r'__fl_link=$(readlink "$__fl_launcher") || break; '
    r'case "$__fl_link" in /*) __fl_launcher=$__fl_link;; '
    r'*) __fl_launcher=$__fl_dir/$__fl_link;; esac; '
    r'__fl_hops=$((__fl_hops + 1)); done; ';

/// PowerShell form of [_posixInstallerLayoutSource]: sets `$__flManaged` when
/// the first executable found, after following file symlinks, is
/// `<root>\bin\<name>` beside the marker.
String _windowsInstallerLayoutSource(
  AgentRuntimeDefinition definition,
  ({String marker, String source}) layout,
) =>
    '\$__flManaged=\$false;'
    'foreach(\$__flName in @(${definition.executableNames.map(powerShellSingleQuote).join(',')})){'
    r'$__flCommand=Get-Command $__flName -ErrorAction SilentlyContinue | Select-Object -First 1;'
    r'if($null -eq $__flCommand){continue};'
    r'try{$__flPath=[IO.Path]::GetFullPath($__flCommand.Source);'
    // PowerShell 5.1 returns Target as an array, 7 as a string.
    r'for($__flHop=0;$__flHop -lt 16;$__flHop++){'
    r'$__flItem=Get-Item -LiteralPath $__flPath -Force;'
    r"if($__flItem.LinkType -ne 'SymbolicLink'){break};"
    r'$__flTarget=@($__flItem.Target)[0];if(-not $__flTarget){break};'
    r'$__flPath=[IO.Path]::GetFullPath([IO.Path]::Combine((Split-Path $__flPath -Parent),$__flTarget))};'
    r'$__flBin=Split-Path $__flPath -Parent;'
    r"if((Split-Path $__flBin -Leaf) -eq 'bin'){"
    '\$__flManaged=Test-Path -LiteralPath (Join-Path (Split-Path \$__flBin -Parent) '
    '${powerShellSingleQuote(layout.marker.replaceAll('/', r'\'))})}}catch{};break};'
    'if(\$__flManaged){[void]\$__flOut.AppendLine('
    '${powerShellSingleQuote('$_sourceMarker${layout.source}')})};';

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// `K=V K2=V2 ` assignments for a POSIX command prefix. Keys are identifiers
/// and values plain tokens, so no quoting is needed.
String _posixEnvironment(Map<String, String> environment) =>
    environment.entries.map((entry) => '${entry.key}=${entry.value} ').join();

String _powerShellEnvironment(Map<String, String> environment) => environment
    .entries
    .map((entry) => '\$env:${entry.key}=${powerShellSingleQuote(entry.value)};')
    .join();

// Download completely before execution: a failed download must never run a
// partial installer or look successful because the receiving shell exited zero.
String _buildOfficialAgentInstallerCommand(
  String url, {
  required bool windows,
  Map<String, String> environment = const {},
}) {
  if (windows) {
    return buildCompactWindowsPowerShellCommand(
      '$powerShellProfilePathPreamble'
      '${_powerShellEnvironment(environment)}'
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
  return '$_profilePrefix${_posixEnvironment(environment)}sh -c ${_shellQuote(script)}';
}

/// Provider for [AgentManagementService].
final agentManagementServiceProvider = Provider<AgentManagementService>(
  (ref) => AgentManagementService(
    ref.watch(agentSessionDiscoveryServiceProvider),
    canManageAgents: () => ref.mounted
        ? ref
              .read(monetizationServiceProvider)
              .canUseFeature(MonetizationFeature.agentManagement)
        : Future.value(false),
  ),
);
