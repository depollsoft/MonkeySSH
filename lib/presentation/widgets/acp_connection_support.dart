import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/command_names.dart';
import '../../domain/services/acp_launch_profile_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/monkeymux_acp_bridge_service.dart';
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/ssh_exec_queue.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/windows_remote_powershell.dart';
import 'connection_attempt_dialog.dart';

/// Reuses an active SSH session for [hostId], or connects through the standard
/// progress and error surface when the host is currently disconnected.
Future<SshConnectionResult> ensureAcpHostConnection(
  BuildContext context,
  WidgetRef ref,
  int hostId, {
  Host? knownHost,
}) async {
  final active = ref.read(sshServiceProvider).getSessionsForHost(hostId);
  if (active.isNotEmpty) {
    return SshConnectionResult(
      success: true,
      connectionId: active.first.connectionId,
      reusedConnection: true,
    );
  }

  final host =
      knownHost ?? await ref.read(hostRepositoryProvider).getById(hostId);
  if (host == null) {
    return const SshConnectionResult(
      success: false,
      error: 'This saved host is no longer available.',
    );
  }
  if (!context.mounted) {
    return const SshConnectionResult(
      success: false,
      error: 'The connection was canceled.',
    );
  }
  return connectToHostWithProgressDialog(context, ref, host, forceNew: false);
}

const _acpExecutableProbeCacheTtl = Duration(seconds: 30);
final _acpExecutableProbeCaches = Expando<_AcpExecutableProbeCache>(
  'acp-executable-probe',
);

class _AcpExecutableProbeCache {
  Map<String, String>? value;
  DateTime? loadedAt;
  Future<Map<String, String>>? pending;
}

Set<String> _allBuiltinAcpExecutableNames() => <String>{
  for (final provider in acpBuiltinProviders) ...[
    ...provider.executableProbe.candidateExecutableNames,
    ...provider.executableProbe.requiredExecutableNames,
    if (provider.adapterFallbackCommand case final fallback?)
      fallback.executable,
  ],
};

Map<String, String> _builtinAcpExecutableOverrideVariables() => {
  for (final provider in acpBuiltinProviders)
    ...provider.executableProbe.executableOverrideEnvironmentVariables,
};

Future<Map<String, String>> _loadAcpRemoteExecutables(
  SshSession session,
) async {
  final cache = _acpExecutableProbeCaches[session] ??=
      _AcpExecutableProbeCache();
  final now = DateTime.now();
  if (cache.value case final value?
      when cache.loadedAt != null &&
          now.difference(cache.loadedAt!) < _acpExecutableProbeCacheTtl) {
    DiagnosticsLogService.instance.debug(
      'acp.launch',
      'executable_probe_cache_hit',
      fields: {
        'connectionId': session.connectionId,
        'ageMs': now.difference(cache.loadedAt!).inMilliseconds,
      },
    );
    return value;
  }
  if (cache.pending case final pending?) return pending;
  final requested = _allBuiltinAcpExecutableNames();
  final overrideVariables = _builtinAcpExecutableOverrideVariables();
  final startedAt = DateTime.now();
  final future = session.runQueuedExec(() async {
    final command = session.remoteIsWindows
        ? buildWindowsPowerShellCommand(
            buildMonkeyMuxAcpWindowsExecutableProbeScript(
              requested,
              overrideVariables: overrideVariables,
            ),
          )
        : buildMonkeyMuxAcpExecutableProbeCommand(
            requested,
            overrideVariables: overrideVariables,
          );
    SSHSession? shell;
    try {
      shell = await session.execute(command);
      shell.stderr.drain<void>().ignore();
      final output = await utf8.decodeStream(shell.stdout);
      await shell.done;
      return parseMonkeyMuxAcpExecutableProbeOutput(
        output,
        requested,
        dependencyNames: {
          for (final provider in acpBuiltinProviders)
            ...provider.executableProbe.requiredExecutableNames,
        },
      );
    } finally {
      shell?.close();
    }
  }, priority: SshExecPriority.low);
  cache.pending = future;
  try {
    final value = await future;
    cache
      ..value = value
      ..loadedAt = DateTime.now();
    DiagnosticsLogService.instance.debug(
      'acp.launch',
      'executable_probe_complete',
      fields: {
        'connectionId': session.connectionId,
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        'matchCount': value.length,
      },
    );
    return value;
  } finally {
    cache.pending = null;
  }
}

/// Returns the terminal sign-in command for [providerId], if the provider is
/// a built-in that advertises one.
AcpLaunchCommand? acpTerminalAuthCommandFor(String providerId) =>
    acpBuiltinProviders
        .firstWhereOrNull((provider) => provider.id == providerId)
        ?.terminalAuthCommand;

/// Resolves the terminal sign-in command using the same executable probe as
/// native launch.
///
/// When the command's executable is one of the provider's probe candidates
/// (for example `opencode` vs `opencode2`, `copilot` vs `github-copilot`), the
/// first candidate installed on the host is substituted so the copied command
/// runs there. Any other command is returned as declared.
Future<AcpLaunchCommand?> resolveAcpTerminalAuthCommand({
  required String providerId,
  SshSession? session,
}) async {
  final provider = acpBuiltinProviders.firstWhereOrNull(
    (candidate) => candidate.id == providerId,
  );
  final command = provider?.terminalAuthCommand;
  if (command == null || session == null) {
    return command;
  }
  final candidates = provider!.executableProbe.candidateExecutableNames;
  if (!candidates.contains(command.executable)) {
    return command;
  }
  try {
    final found = await _loadAcpRemoteExecutables(session);
    for (final candidate in candidates) {
      if (found.containsKey(candidate)) {
        return AcpLaunchCommand(
          executable: candidate,
          arguments: command.arguments,
        );
      }
    }
  } on Object {
    // Keep the normal recovery action available if the probe cannot complete.
  }
  return command;
}

/// Copies the provider's terminal sign-in command for [hostId] to the
/// clipboard and confirms with a snackbar. Returns the resolved command, or
/// `null` when the provider has none; callers then open the terminal.
Future<AcpLaunchCommand?> copyAcpTerminalAuthCommand(
  BuildContext context,
  WidgetRef ref, {
  required String providerId,
  required int hostId,
}) async {
  final session = ref
      .read(sshServiceProvider)
      .getSessionsForHost(hostId)
      .firstOrNull;
  final command = await resolveAcpTerminalAuthCommand(
    providerId: providerId,
    session: session,
  );
  if (command == null || !context.mounted) {
    return command;
  }
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: command.argv.join(' ')));
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Sign-in command copied — run it in the terminal.'),
    ),
  );
  return command;
}

/// Warms approved ACP executable paths while the terminal is already usable.
///
/// This is best-effort and never blocks shell startup. The launch path awaits
/// the same deduplicated probe if the user acts before it completes.
Future<void> prewarmAcpRemoteExecutables(SshSession session) async {
  try {
    await _loadAcpRemoteExecutables(session);
  } on Object {
    // Launch performs the normal checked probe and surfaces any real failure.
  }
}

/// Resolves and confirms the exact remote command used for a built-in ACP
/// provider, regardless of which launch surface initiated the session.
///
/// Only absolute external executable paths survive the probe. Shell aliases and
/// functions are ignored, and adapter fallbacks remain pinned to their bundled
/// arguments.
Future<({AcpLaunchCommand? override, bool terminal})?>
resolveAcpRemoteProviderLaunch({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
  required bool canUseTerminalCli,
  bool startInYoloMode = false,
  ValueChanged<AcpLaunchProfile>? onProfileSelected,
}) async {
  final found = await _loadAcpRemoteExecutables(session);

  if (!context.mounted) return null;
  final missing = provider.executableProbe.requiredExecutableNames
      .where((name) => !found.containsKey(name))
      .toList();
  if (missing.isNotEmpty) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${provider.label} unavailable'),
        content: Text(
          'Install ${missing.join(', ')} on this host before starting ${provider.label} native chat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return null;
  }
  for (final candidate in provider.executableProbe.candidateExecutableNames) {
    final executable = found[candidate];
    if (executable != null) {
      final status = await _checkAcpSupport(session, provider, executable);
      if (status == AcpSupportStatus.missing) {
        if (!context.mounted ||
            !await _confirmAcpSupportInstall(context, provider) ||
            !context.mounted ||
            !await _installAcpSupport(context, session, provider, executable)) {
          return null;
        }
      }
      if (!context.mounted) return null;
      final resolved = AcpLaunchCommand(
        executable: executable,
        arguments: provider.launchCommand.arguments,
      );
      final profiled = await resolveAcpLaunchProfile(
        context: context,
        session: session,
        provider: provider,
        resolvedCommand: resolved,
        onProfileSelected: onProfileSelected,
      );
      if (profiled == null) return null;
      return (
        override: applyAcpAgentLaunchSettings(
          provider: provider,
          command: profiled,
          startInYoloMode: startInYoloMode,
        ),
        terminal: false,
      );
    }
  }

  final fallback = provider.adapterFallbackCommand;
  final fallbackExecutable = fallback == null
      ? null
      : found[fallback.executable];
  final fallbackOverride = fallback == null || fallbackExecutable == null
      ? null
      : AcpLaunchCommand(
          executable: fallbackExecutable,
          arguments: fallback.arguments,
        );
  if (!context.mounted) return null;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        fallback == null
            ? '${provider.label} unavailable'
            : '${provider.label} adapter required',
      ),
      content: Text(
        fallbackOverride != null
            ? 'The ACP adapter is not installed. MonkeySSH can run the pinned adapter with npx:\n\n${fallback!.argv.join(' ')}'
            : fallback == null
            ? 'The native provider executable is not available in this host’s interactive shell.'
            : 'The ACP adapter is not installed and npx is unavailable on this host.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: const Text('Cancel'),
        ),
        if (canUseTerminalCli)
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'terminal'),
            child: const Text('Use terminal CLI'),
          ),
        if (fallbackOverride != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, 'adapter'),
            child: const Text('Run adapter'),
          ),
      ],
    ),
  );
  return switch (choice) {
    'adapter' => (override: fallbackOverride, terminal: false),
    'terminal' => (override: null, terminal: true),
    _ => null,
  };
}

const _acpSupportCheckTimeout = Duration(seconds: 30);
const _acpSupportInstallTimeout = Duration(minutes: 10);
final _acpSupportedExecutables = Expando<Set<String>>('acp-supported');

/// Runs [command] in the exec queue, bounded by one [timeout] from opening
/// the channel to its exit, and returns stdout, all output, and the exit
/// status.
Future<({String stdout, String output, int? exitCode})> _runAcpSupportCommand(
  SshSession session,
  String command,
  Duration timeout,
) => session.runQueuedExec(() async {
  // Opening is bounded too: a stalled connection must not hold the launch,
  // and a channel that opens after the deadline is destroyed.
  final deadline = DateTime.now().add(timeout);
  final shell = await openSshExec(session.execute(command), timeout);
  var finished = false;
  try {
    final stdout = StringBuffer();
    final output = StringBuffer();
    // Time out inside the queued exec so a hung command frees its channel
    // before the queue slot is released.
    await Future.wait<void>([
      shell.stdout.cast<List<int>>().transform(utf8.decoder).forEach((chunk) {
        stdout.write(chunk);
        output.write(chunk);
      }),
      shell.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(output.write),
      shell.done,
    ]).timeout(deadline.difference(DateTime.now()));
    finished = true;
    return (
      stdout: stdout.toString(),
      output: output.toString(),
      exitCode: shell.exitCode,
    );
  } finally {
    if (finished) {
      shell.close();
    } else {
      // close() only sends EOF, which a hung command can ignore.
      await closeAbandonedSshExec(shell);
    }
  }
});

/// Runs [provider]'s support check against [executable].
///
/// A passing check is remembered for the SSH session. A check that fails to
/// run or times out reports [AcpSupportStatus.unknown], which never blocks the
/// launch.
Future<AcpSupportStatus> _checkAcpSupport(
  SshSession session,
  AcpBuiltinProvider provider,
  String executable,
) async {
  final check = provider.supportCheck;
  if (check == null) return AcpSupportStatus.supported;
  final supported = _acpSupportedExecutables[session] ??= <String>{};
  if (supported.contains(executable)) return AcpSupportStatus.supported;
  final startedAt = DateTime.now();
  try {
    final result = await _runAcpSupportCommand(
      session,
      buildAcpSupportCheckCommand(
        check,
        executable,
        isWindows: session.remoteIsWindows,
      ),
      _acpSupportCheckTimeout,
    );
    final status = parseAcpSupportCheckOutput(result.stdout);
    if (status == AcpSupportStatus.supported) supported.add(executable);
    DiagnosticsLogService.instance.info(
      'acp.launch',
      'support_check_complete',
      fields: {
        'connectionId': session.connectionId,
        'provider': provider.telemetryCategory,
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        'status': status.name,
      },
    );
    return status;
  } on Object catch (error) {
    DiagnosticsLogService.instance.warning(
      'acp.launch',
      'support_check_failed',
      fields: {
        'connectionId': session.connectionId,
        'provider': provider.telemetryCategory,
        'errorType': error.runtimeType,
      },
    );
    return AcpSupportStatus.unknown;
  }
}

/// Explains that [provider] cannot serve ACP on this host and asks whether to
/// install what it is missing.
Future<bool> _confirmAcpSupportInstall(
  BuildContext context,
  AcpBuiltinProvider provider,
) async {
  final install = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${provider.label} needs ACP support'),
      content: Text(
        '${provider.supportCheck!.missingMessage} MonkeySSH can install them '
        'into the Python environment ${provider.label} runs from, then start '
        'the chat.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Install and start'),
        ),
      ],
    ),
  );
  return install ?? false;
}

/// Installs [provider]'s ACP support for [executable] behind a progress
/// dialog, returning whether the support check passes afterwards.
///
/// A failure shows the end of the install output, which stays on screen and
/// out of diagnostics.
Future<bool> _installAcpSupport(
  BuildContext context,
  SshSession session,
  AcpBuiltinProvider provider,
  String executable,
) async {
  final navigator = Navigator.of(context);
  // Track the route itself: the install can finish before the dialog builds,
  // and an app lock can remove the dialog while the install runs.
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text('Installing ${provider.label} ACP support…')),
          ],
        ),
      ),
    ),
  );
  unawaited(navigator.push(progress));
  final startedAt = DateTime.now();
  String? failure;
  try {
    final result = await _runAcpSupportCommand(
      session,
      buildAcpSupportRepairCommand(
        provider.supportCheck!,
        executable,
        isWindows: session.remoteIsWindows,
      ),
      _acpSupportInstallTimeout,
    );
    DiagnosticsLogService.instance.info(
      'acp.launch',
      'support_install_complete',
      fields: {
        'connectionId': session.connectionId,
        'provider': provider.telemetryCategory,
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        'exitCode': result.exitCode,
      },
    );
    if (result.exitCode == 0) {
      (_acpSupportedExecutables[session] ??= <String>{}).add(executable);
    } else {
      final lines = const LineSplitter().convert(result.output.trim());
      failure = lines
          .skip(lines.length > 12 ? lines.length - 12 : 0)
          .join('\n');
      if (failure.isEmpty) {
        failure = 'The install exited with ${result.exitCode}.';
      }
    }
  } on Object catch (error) {
    DiagnosticsLogService.instance.warning(
      'acp.launch',
      'support_install_failed',
      fields: {
        'connectionId': session.connectionId,
        'provider': provider.telemetryCategory,
        'errorType': error.runtimeType,
      },
    );
    failure = error is TimeoutException
        ? 'The install did not finish in time.'
        : 'The install could not run on this host.';
  } finally {
    // Popping blindly could remove whatever replaced the dialog.
    if (progress.isActive) navigator.removeRoute(progress);
  }
  if (failure == null) return true;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Could not install ${provider.label} ACP support'),
      content: SingleChildScrollView(
        child: SelectableText(
          failure!,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  return false;
}

/// Applies global terminal-agent settings before a provider's ACP entrypoint.
///
/// Direct ACP implementations use the same profile/YOLO argument plan as their
/// terminal CLI. Adapter executables keep their pinned argv; native YOLO still
/// applies generically when MonkeySSH answers ACP permission requests.
AcpLaunchCommand applyAcpAgentLaunchSettings({
  required AcpBuiltinProvider provider,
  required AcpLaunchCommand command,
  required bool startInYoloMode,
}) {
  if (!startInYoloMode) return command;
  final tool = agentLaunchToolForBuiltinAcpProviderId(provider.id);
  if (tool == null ||
      !_isResolvedTerminalExecutable(tool, command.executable)) {
    return command;
  }
  final profileSupport = provider.launchProfileSupport;
  String? profile;
  if (profileSupport != null &&
      command.arguments.length >= 2 &&
      command.arguments.first == profileSupport.profileOption) {
    profile = command.arguments[1];
  }
  return AcpLaunchCommand(
    executable: command.executable,
    arguments: <String>[
      ...buildAgentGlobalLaunchArguments(
        tool,
        startInYoloMode: true,
        launchProfile: profile,
        quoteProfileForShell: false,
        acpEntrypoint: true,
      ),
      ...provider.launchCommand.arguments,
    ],
  );
}

bool _isResolvedTerminalExecutable(AgentLaunchTool tool, String executable) {
  final name = normalizeCommandBasename(
    executable.replaceAll(r'\', '/').split('/').last,
  );
  return tool.candidateCommandNames.any(
    (candidate) => candidate.toLowerCase() == name,
  );
}

/// Discovers and, when necessary, asks which isolated provider profile to use.
///
/// The returned profile is shared by terminal and native launches. Discovery
/// failures and a single profile preserve one-tap launch; `null` means the user
/// explicitly cancelled a picker containing multiple profiles.
Future<AcpLaunchProfile?> selectAcpLaunchProfile({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
}) async {
  final support = provider.launchProfileSupport;
  if (support == null) {
    return const AcpLaunchProfile(argument: null, label: 'Default');
  }

  List<AcpLaunchProfile> profiles;
  try {
    final discoveryCommand = buildAcpLaunchProfileDiscoveryCommand(
      support: support,
      isWindows: session.remoteIsWindows,
    );
    final output = await session.runQueuedExec(() async {
      SSHSession? shell;
      try {
        shell = await session.execute(discoveryCommand);
        shell.stderr.drain<void>().ignore();
        final stdout = await utf8.decodeStream(shell.stdout);
        await shell.done;
        return stdout;
      } finally {
        shell?.close();
      }
    });
    profiles = parseAcpLaunchProfiles(output, support);
  } on Object {
    profiles = parseAcpLaunchProfiles('', support);
  }

  if (profiles.length <= 1) return profiles.single;
  if (!context.mounted) return null;
  final selected = await showAcpLaunchProfilePicker(
    context: context,
    providerLabel: provider.label,
    profiles: profiles,
  );
  if (selected == null) return null;
  return AcpLaunchProfile(
    argument: selected.argument,
    label: selected.label,
    isActive: selected.isActive,
    showInTitle: true,
  );
}

/// Applies the shared launch-profile choice to a resolved ACP executable.
Future<AcpLaunchCommand?> resolveAcpLaunchProfile({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
  required AcpLaunchCommand resolvedCommand,
  ValueChanged<AcpLaunchProfile>? onProfileSelected,
}) async {
  final support = provider.launchProfileSupport;
  if (support == null) return resolvedCommand;
  final selected = await selectAcpLaunchProfile(
    context: context,
    session: session,
    provider: provider,
  );
  if (selected == null) return null;
  onProfileSelected?.call(selected);
  return support.apply(resolvedCommand, selected.argument);
}

/// Shows the one-handed launch-profile chooser used by profile-aware agents.
Future<AcpLaunchProfile?> showAcpLaunchProfilePicker({
  required BuildContext context,
  required String providerLabel,
  required List<AcpLaunchProfile> profiles,
}) => showModalBottomSheet<AcpLaunchProfile>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) {
    final theme = Theme.of(sheetContext);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose $providerLabel profile',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Select the isolated profile for this native session.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: profiles.length,
              itemBuilder: (context, index) {
                final profile = profiles[index];
                return ListTile(
                  leading: Icon(
                    profile.argument == null || profile.label == 'Default'
                        ? Icons.settings_outlined
                        : Icons.account_tree_outlined,
                  ),
                  title: Text(
                    profile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: profile.isActive
                      ? Text(
                          'Current',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                  onTap: () => Navigator.pop(sheetContext, profile),
                );
              },
            ),
          ),
        ],
      ),
    );
  },
);

/// Requests permission to install or update the bundled MonkeyMux helper used
/// by persistent ACP sessions.
Future<bool> confirmAcpMonkeyMuxInstall(
  BuildContext context,
  MonkeyMuxInstallRequest request,
) async {
  if (!context.mounted) {
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Install or update MonkeyMux?'),
      content: Text(
        'Agent sessions use MonkeyMux ${request.version} on this host so work '
        'can survive reconnects. The bundled ${request.platform} helper will '
        'be installed in your user account.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
