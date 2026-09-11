/// Staged new-session flow for launching an ACP coding-agent session.
///
/// Walks the user through: choose a saved host → connect/reuse SSH → choose a
/// built-in provider → choose a working directory → start a new session or
/// reconnect a recent one. It handles helper-install confirmation,
/// missing/auth-required providers (with a safe Open Terminal escape hatch),
/// and the free-tier concurrency choice.
///
/// No prompts, transcripts, or command text are ever logged.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_recent_session.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_launch_profile_service.dart';
import '../../domain/services/acp_provider_service.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import 'acp_concurrency_choice.dart';
import 'acp_connection_support.dart';
import 'acp_session_presentation.dart';

/// Opens the staged new-session sheet, returning the launched session key when
/// a session starts (so the caller can open its chat), or `null` otherwise.
Future<AcpSessionKey?> showAcpNewSessionSheet(
  BuildContext context, {
  int? initialHostId,
  String? initialProviderId,
  String? initialWorkingDirectory,
  bool lockHost = false,
  bool lockProvider = false,
}) => showModalBottomSheet<AcpSessionKey>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _NewSessionSheet(
    initialHostId: initialHostId,
    initialProviderId: initialProviderId,
    initialWorkingDirectory: initialWorkingDirectory,
    lockHost: lockHost,
    lockProvider: lockProvider,
  ),
);

/// Returns the terminal-auth command for [providerId], if the provider is a
/// built-in that advertises one.
AcpLaunchCommand? acpTerminalAuthCommandFor(String providerId) {
  for (final provider in acpBuiltinProviders) {
    if (provider.id == providerId) {
      return provider.terminalAuthCommand;
    }
  }
  return null;
}

/// Defaults resolved for the ACP start-or-resume sheet.
@immutable
final class AcpSessionLaunchDefaults {
  /// Creates resolved launch defaults.
  const AcpSessionLaunchDefaults({
    required this.hostId,
    required this.providerId,
    required this.cwd,
  });

  /// Initially selected saved host.
  final int? hostId;

  /// Initially selected ACP provider.
  final String? providerId;

  /// Initially selected remote working directory.
  final String cwd;
}

/// Maps a saved terminal-agent tool to an available ACP provider.
String? acpProviderIdForAgentLaunchTool(
  AgentLaunchTool tool,
  List<AcpProvider> providers,
) {
  for (final provider in providers) {
    if ((provider.id == AcpBuiltinProviderIds.antigravity &&
            tool == AgentLaunchTool.antigravity) ||
        agentLaunchToolForCommandName(provider.launchCommand.executable) ==
            tool) {
      return provider.id;
    }
  }
  return null;
}

/// Resolves launch defaults from explicit inputs, active/recent sessions, and
/// the host's saved agent/MonkeyMux configuration.
AcpSessionLaunchDefaults resolveAcpSessionLaunchDefaults({
  required List<Host> hosts,
  required List<AcpProvider> providers,
  required List<AcpRecentSessionRef> recents,
  required Set<int> activeHostIds,
  required Map<int, AgentLaunchPreset> presets,
  AcpSessionKey? lastSelected,
  int? initialHostId,
  String? initialProviderId,
  String? initialWorkingDirectory,
}) {
  Host? hostForId(int? id) =>
      id == null ? null : hosts.where((host) => host.id == id).firstOrNull;

  final lastSelectedHost = hostForId(lastSelected?.hostId);
  final activeHosts = hosts
      .where((host) => activeHostIds.contains(host.id))
      .toList(growable: false);
  final configuredHost = hosts.firstWhereOrNull((host) {
    if (presets.containsKey(host.id)) {
      return true;
    }
    return RemoteMuxBackendPresentation.fromStorageValue(
          host.remoteMuxBackend,
        ) ==
        RemoteMuxBackend.monkeyMux;
  });
  final recentHost = recents
      .map((recent) => hostForId(recent.hostId))
      .whereType<Host>()
      .firstOrNull;
  final host =
      hostForId(initialHostId) ??
      (lastSelectedHost != null && activeHostIds.contains(lastSelectedHost.id)
          ? lastSelectedHost
          : null) ??
      (activeHosts.length == 1 ? activeHosts.single : null) ??
      lastSelectedHost ??
      activeHosts.firstOrNull ??
      configuredHost ??
      recentHost ??
      hosts.firstOrNull;

  final availableProviderIds = providers.map((provider) => provider.id).toSet();
  final preset = host == null ? null : presets[host.id];
  final matchingRecents = host == null
      ? const <AcpRecentSessionRef>[]
      : recents.where((recent) => recent.hostId == host.id).toList();
  final recentProviderId = matchingRecents
      .map((recent) => recent.providerId)
      .firstWhereOrNull(availableProviderIds.contains);
  final lastSelectedProviderId =
      host != null &&
          lastSelected?.hostId == host.id &&
          availableProviderIds.contains(lastSelected?.providerId)
      ? lastSelected!.providerId
      : null;
  final providerId =
      (availableProviderIds.contains(initialProviderId)
          ? initialProviderId
          : null) ??
      (preset == null
          ? null
          : acpProviderIdForAgentLaunchTool(preset.tool, providers)) ??
      lastSelectedProviderId ??
      recentProviderId ??
      (availableProviderIds.contains(AcpBuiltinProviderIds.copilotCli)
          ? AcpBuiltinProviderIds.copilotCli
          : providers.firstOrNull?.id);

  String? nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final matchingRecent = matchingRecents.firstWhereOrNull(
    (recent) => recent.providerId == providerId,
  );
  final cwd =
      nonEmpty(initialWorkingDirectory) ??
      nonEmpty(preset?.workingDirectory) ??
      nonEmpty(host?.tmuxWorkingDirectory) ??
      nonEmpty(matchingRecent?.cwd) ??
      '~';
  return AcpSessionLaunchDefaults(
    hostId: host?.id,
    providerId: providerId,
    cwd: cwd,
  );
}

class _NewSessionSheet extends ConsumerStatefulWidget {
  const _NewSessionSheet({
    this.initialHostId,
    this.initialProviderId,
    this.initialWorkingDirectory,
    this.lockHost = false,
    this.lockProvider = false,
  });

  final int? initialHostId;
  final String? initialProviderId;
  final String? initialWorkingDirectory;
  final bool lockHost;
  final bool lockProvider;

  @override
  ConsumerState<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<_NewSessionSheet> {
  int? _hostId;
  String? _providerId;
  final TextEditingController _cwd = TextEditingController();
  bool _cwdEdited = false;
  AcpRecentSessionRef? _selectedRecent;
  var _busy = false;
  var _loadingDefaults = true;
  var _defaultsScheduled = false;
  var _hostDefaultsGeneration = 0;
  String? _error;
  late final Future<List<AcpRecentSessionRef>> _recents;

  @override
  void initState() {
    super.initState();
    _hostId = widget.initialHostId;
    _providerId = widget.initialProviderId;
    final initialWorkingDirectory = widget.initialWorkingDirectory?.trim();
    if (initialWorkingDirectory != null && initialWorkingDirectory.isNotEmpty) {
      _cwd.text = initialWorkingDirectory;
      _cwdEdited = true;
    }
    _recents = ref.read(acpSessionManagerProvider).loadRecentSessions();
    _recents.ignore();
  }

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  void _scheduleDefaults(List<Host> hosts, List<AcpProvider> providers) {
    if (_defaultsScheduled) {
      return;
    }
    _defaultsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadDefaults(hosts, providers));
      }
    });
  }

  Future<void> _loadDefaults(
    List<Host> hosts,
    List<AcpProvider> providers,
  ) async {
    var recents = const <AcpRecentSessionRef>[];
    AcpSessionKey? lastSelected;
    var presets = const <int, AgentLaunchPreset>{};
    var activeHostIds = const <int>{};
    try {
      final manager = ref.read(acpSessionManagerProvider);
      final presetService = ref.read(agentLaunchPresetServiceProvider);
      recents = await _recents;
      lastSelected = await manager.loadLastSelected();
      final presetEntries = await Future.wait(
        hosts.map(
          (host) async =>
              MapEntry(host.id, await presetService.getPresetForHost(host.id)),
        ),
      );
      presets = <int, AgentLaunchPreset>{
        for (final entry in presetEntries)
          if (entry.value != null) entry.key: entry.value!,
      };
      activeHostIds = ref
          .read(sshServiceProvider)
          .allSessions
          .map((session) => session.hostId)
          .toSet();
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.launch',
        'defaults_failed',
        fields: {'errorType': error.runtimeType},
      );
      recents = const [];
      lastSelected = null;
      presets = const {};
      activeHostIds = const {};
    }
    final defaults = resolveAcpSessionLaunchDefaults(
      hosts: hosts,
      providers: providers,
      recents: recents,
      activeHostIds: activeHostIds,
      presets: presets,
      lastSelected: lastSelected,
      initialHostId: widget.initialHostId,
      initialProviderId: widget.initialProviderId,
      initialWorkingDirectory: widget.initialWorkingDirectory,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _hostId = widget.lockHost ? widget.initialHostId : defaults.hostId;
      _providerId = widget.lockProvider
          ? widget.initialProviderId
          : defaults.providerId;
      if (!_cwdEdited) {
        _cwd.text = defaults.cwd;
      }
      _loadingDefaults = false;
    });
  }

  Future<void> _selectHost(
    int? hostId,
    List<Host> hosts,
    List<AcpProvider> providers,
  ) async {
    final generation = ++_hostDefaultsGeneration;
    setState(() {
      _hostId = hostId;
      _cwdEdited = false;
      _selectedRecent = null;
      _loadingDefaults = hostId != null;
    });
    final host = hosts.where((candidate) => candidate.id == hostId).firstOrNull;
    if (host == null) {
      setState(() => _loadingDefaults = false);
      return;
    }
    try {
      final preset = await ref
          .read(agentLaunchPresetServiceProvider)
          .getPresetForHost(host.id);
      final defaults = resolveAcpSessionLaunchDefaults(
        hosts: [host],
        providers: providers,
        recents: await _recents,
        activeHostIds: const {},
        presets: preset == null ? const {} : {host.id: preset},
        initialHostId: host.id,
      );
      if (!mounted ||
          generation != _hostDefaultsGeneration ||
          _hostId != host.id) {
        return;
      }
      setState(() {
        _providerId = defaults.providerId;
        if (!_cwdEdited) {
          _cwd.text = defaults.cwd;
        }
        _loadingDefaults = false;
      });
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.launch',
        'host_defaults_failed',
        fields: {'hostId': host.id, 'errorType': error.runtimeType},
      );
      if (mounted &&
          generation == _hostDefaultsGeneration &&
          _hostId == host.id) {
        final configuredCwd = host.tmuxWorkingDirectory?.trim();
        setState(() {
          if (!_cwdEdited) {
            _cwd.text = configuredCwd != null && configuredCwd.isNotEmpty
                ? configuredCwd
                : '~';
          }
          _loadingDefaults = false;
        });
      }
    }
  }

  Future<bool> _confirmInstall(MonkeyMuxInstallRequest request) =>
      confirmAcpMonkeyMuxInstall(context, request);

  Future<void> _openTerminalForAuth(String providerId) async {
    final hostId = _hostId;
    if (hostId == null) {
      return;
    }
    final authCommand = acpTerminalAuthCommandFor(providerId);
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (authCommand != null) {
      await Clipboard.setData(ClipboardData(text: authCommand.argv.join(' ')));
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Sign-in command copied — run it in the terminal.'),
        ),
      );
    }
    navigator.pop();
    router.go(buildTmuxAlertHomeLocationSafe());
    unawaited(router.push<void>('/terminal/$hostId'));
  }

  Future<AcpSessionLaunchResult?> _launch({
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    final hostId = _hostId;
    final providerId = _providerId;
    if (hostId == null || providerId == null) {
      return null;
    }
    final manager = ref.read(acpSessionManagerProvider);
    final cwd = _cwd.text.trim().isEmpty ? '~' : _cwd.text.trim();
    final launchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(hostId);
    if (!mounted) return null;

    final knownHost = ref
        .read(allHostsProvider)
        .asData
        ?.value
        .where((host) => host.id == hostId)
        .firstOrNull;
    final connection = await ensureAcpHostConnection(
      context,
      ref,
      hostId,
      knownHost: knownHost,
    );
    if (!mounted) {
      return null;
    }
    if (!connection.success) {
      setState(
        () => _error =
            connection.error ?? 'Could not establish the SSH connection.',
      );
      return null;
    }

    AcpLaunchCommand? launchCommandOverride;
    AcpLaunchProfile? selectedProfile;
    final sshSession = connection.connectionId == null
        ? null
        : ref.read(sshServiceProvider).getSession(connection.connectionId!);
    final builtinProvider = acpBuiltinProviders
        .where((provider) => provider.id == providerId)
        .firstOrNull;
    if (sshSession != null && builtinProvider != null) {
      final launch = await resolveAcpRemoteProviderLaunch(
        context: context,
        session: sshSession,
        provider: builtinProvider,
        canUseTerminalCli: builtinProvider.terminalAuthCommand != null,
        startInYoloMode: launchPreferences.startInYoloMode,
        onProfileSelected: (profile) => selectedProfile = profile,
      );
      if (!mounted || launch == null) return null;
      if (launch.terminal) {
        await _openTerminalForAuth(providerId);
        return null;
      }
      launchCommandOverride = launch.override;
    }

    final recent = _selectedRecent;
    if (recent != null) {
      return manager.reconnectSession(
        hostId: recent.hostId,
        providerId: recent.providerId,
        bridgeId: recent.bridgeId,
        acpSessionId: recent.acpSessionId,
        cwd: recent.cwd ?? cwd,
        confirmInstall: _confirmInstall,
        launchCommandOverride: launchCommandOverride,
        providerLabelOverride: selectedProfile?.showInTitle ?? false
            ? '${builtinProvider?.label ?? 'Agent'} · ${selectedProfile!.label}'
            : null,
        autoApprovePermissions: launchPreferences.startInYoloMode,
        replace: replace,
      );
    }
    return manager.startNewSession(
      hostId: hostId,
      providerId: providerId,
      cwd: cwd,
      confirmInstall: _confirmInstall,
      launchCommandOverride: launchCommandOverride,
      providerLabelOverride: selectedProfile?.showInTitle ?? false
          ? '${builtinProvider?.label ?? 'Agent'} · ${selectedProfile!.label}'
          : null,
      autoApprovePermissions: launchPreferences.startInYoloMode,
      replace: replace,
    );
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var result = await _launch();
      // Resolve a free-tier concurrency block, then retry once.
      if (result is AcpSessionLaunchBlocked && mounted) {
        final resolved = await _resolveConcurrency(result.decision);
        // Null also covers the sheet being dismissed while the choice dialog
        // or upgrade route was open, so re-check mounted before touching state.
        if (!mounted) {
          return;
        }
        if (resolved == null) {
          setState(() => _busy = false);
          return;
        }
        result = resolved;
      }
      if (!mounted) {
        return;
      }
      switch (result) {
        case AcpSessionLaunchStarted(:final key):
          Navigator.of(context).pop(key);
        case AcpSessionLaunchFailed(:final error):
          await _handleFailure(error);
          if (mounted) {
            setState(() => _busy = false);
          }
        case AcpSessionLaunchBlocked():
        case null:
          setState(() => _busy = false);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not start the session. Try again.';
        });
      }
    }
  }

  Future<AcpSessionLaunchResult?> _resolveConcurrency(
    AcpConcurrencyRequiresChoice decision,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    final choice = await showAcpConcurrencyChoice(
      context,
      decision: decision,
      managerState: manager.state,
    );
    if (choice == null || !mounted) {
      return null;
    }
    switch (choice) {
      case AcpConcurrencyChoice.stopAndContinue:
        final blocking = [
          for (final value in decision.blockingSessionKeys)
            manager.state.byKeyValue(value)?.key,
        ].whereType<AcpSessionKey>().toList(growable: false);
        return _launch(replace: blocking);
      case AcpConcurrencyChoice.upgrade:
        await context.push<void>(
          Uri(
            path: '/upgrade',
            queryParameters: {
              'feature': MonetizationFeature.concurrentAcpSessions.name,
            },
          ).toString(),
        );
        if (!mounted) {
          return null;
        }
        final unlocked = ref
            .read(monetizationServiceProvider)
            .currentState
            .isProUnlocked;
        if (!unlocked) {
          return null;
        }
        return _launch();
    }
  }

  Future<void> _handleFailure(AcpSessionError error) async {
    final providerId = _providerId;
    switch (error.kind) {
      case AcpSessionErrorKind.authenticationRequired:
        if (providerId != null) {
          await _showAuthRequired(providerId);
        }
      case AcpSessionErrorKind.commandNotApproved:
        setState(
          () => _error =
              'This provider needs its command reviewed again before it '
              'can launch. Edit it to re-approve.',
        );
      default:
        setState(() => _error = error.message);
    }
  }

  Future<void> _showAuthRequired(String providerId) async {
    final unlocksCursorKeychain =
        providerId == AcpBuiltinProviderIds.cursorAgent;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          unlocksCursorKeychain ? 'Unlock Mac keychain' : 'Sign in required',
        ),
        content: Text(
          unlocksCursorKeychain
              ? 'Cursor Agent credentials are in the locked Mac login '
                    'keychain. Open a terminal and enter the Mac password '
                    'there, then start the session again. MonkeySSH never '
                    'reads or stores the password.'
              : 'This agent needs you to sign in first. Open a terminal to '
                    'complete its sign-in flow, then start the session again. '
                    'MonkeySSH never stores third-party credentials.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open Terminal'),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) && mounted) {
      await _openTerminalForAuth(providerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hostsAsync = ref.watch(allHostsProvider);
    final providersAsync = ref.watch(acpProvidersProvider);
    final hosts = hostsAsync.asData?.value;
    final providers = providersAsync.asData?.value
        .where((provider) => !provider.isCustom)
        .toList(growable: false);
    if (hosts != null && providers != null) {
      _scheduleDefaults(hosts, providers);
    } else if (!_defaultsScheduled &&
        !hostsAsync.isLoading &&
        !providersAsync.isLoading) {
      _scheduleDefaults(
        hosts ?? const <Host>[],
        providers ?? const <AcpProvider>[],
      );
    }
    final controlsDisabled = _busy || _loadingDefaults;
    final lockedHostUnavailable =
        widget.lockHost &&
        (hosts == null ||
            !hosts.any((host) => host.id == widget.initialHostId));
    final lockedProviderUnavailable =
        widget.lockProvider &&
        (providers == null ||
            !providers.any(
              (provider) => provider.id == widget.initialProviderId,
            ));
    final lockedContextUnavailable =
        lockedHostUnavailable || lockedProviderUnavailable;

    return PopScope(
      // Block dismissal (back gesture / predictive pop) while a launch is in
      // flight so an in-progress connect/start can't be interrupted or leave
      // the sheet updating state after it is gone.
      canPop: !_busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: FluttyTheme.spacingLg,
          right: FluttyTheme.spacingLg,
          bottom:
              MediaQuery.viewInsetsOf(context).bottom + FluttyTheme.spacingLg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'new agent session',
                style: FluttyTheme.displayMono(
                  fontSize: 18,
                  color: colorScheme.onSurface,
                ),
              ),
              if (_loadingDefaults) ...[
                const SizedBox(height: FluttyTheme.spacingSm),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Host'),
              hostsAsync.when(
                data: (hosts) {
                  if (hosts.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: FluttyTheme.spacingSm,
                      ),
                      child: Text('Add a host first to launch an agent.'),
                    );
                  }
                  if (widget.lockHost) {
                    final host = hosts.firstWhereOrNull(
                      (candidate) => candidate.id == _hostId,
                    );
                    return InputDecorator(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      child: Text(
                        host?.label ?? 'Current MonkeyMux host',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }
                  return DropdownButtonFormField<int>(
                    initialValue: _hostId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      hintText: 'Choose a host',
                    ),
                    items: [
                      for (final host in hosts)
                        DropdownMenuItem<int>(
                          value: host.id,
                          child: Text(
                            host.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: controlsDisabled
                        ? null
                        : (value) => unawaited(
                            _selectHost(
                              value,
                              hosts,
                              providers ?? const <AcpProvider>[],
                            ),
                          ),
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.all(FluttyTheme.spacingMd),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const Text('Could not load hosts.'),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Provider'),
              providersAsync.when(
                data: (allProviders) {
                  final builtins = allProviders
                      .where((provider) => !provider.isCustom)
                      .toList(growable: false);
                  return widget.lockProvider
                      ? _buildLockedProvider(builtins)
                      : _buildProviderPicker(builtins);
                },
                loading: () => const Padding(
                  padding: EdgeInsets.all(FluttyTheme.spacingMd),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const Text('Could not load providers.'),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Working directory'),
              TextField(
                controller: _cwd,
                enabled: !controlsDisabled,
                autocorrect: false,
                enableSuggestions: false,
                style: FluttyTheme.monoStyle,
                onChanged: (_) => _cwdEdited = true,
                decoration: const InputDecoration(hintText: '~'),
              ),
              _buildRecentSessions(),
              if (_error != null) ...[
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: Text(
                        _error!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingLg),
              FilledButton.icon(
                onPressed:
                    (controlsDisabled ||
                        lockedContextUnavailable ||
                        _hostId == null ||
                        _providerId == null)
                    ? null
                    : _start,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _selectedRecent != null ? 'Resume session' : 'Start session',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockedProvider(List<AcpProvider> providers) {
    final provider = providers.firstWhereOrNull(
      (candidate) => candidate.id == _providerId,
    );
    return InputDecorator(
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.smart_toy_outlined),
      ),
      child: Text(
        provider?.label ?? 'Agent provider unavailable',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildProviderPicker(List<AcpProvider> providers) => Wrap(
    spacing: FluttyTheme.spacingSm,
    runSpacing: FluttyTheme.spacingSm,
    children: [
      for (final provider in providers)
        _ProviderChip(
          key: ValueKey('provider-${provider.id}'),
          provider: provider,
          selected: provider.id == _providerId,
          onSelected: (_busy || _loadingDefaults)
              ? null
              : () => setState(() {
                  _providerId = provider.id;
                  _selectedRecent = null;
                }),
        ),
    ],
  );

  Widget _buildRecentSessions() {
    final hostId = _hostId;
    final providerId = _providerId;
    if (hostId == null || providerId == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<AcpRecentSessionRef>>(
      future: _recents,
      builder: (context, snapshot) {
        final recents = (snapshot.data ?? const <AcpRecentSessionRef>[])
            .where((r) => r.hostId == hostId && r.providerId == providerId)
            .toList(growable: false);
        if (recents.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: FluttyTheme.spacingMd),
            _sectionLabel(context, 'Resume a recent session'),
            RadioGroup<AcpRecentSessionRef?>(
              groupValue: _selectedRecent,
              onChanged: (value) {
                if (_busy) {
                  return;
                }
                setState(() => _selectedRecent = value);
              },
              child: Column(
                children: [
                  const RadioListTile<AcpRecentSessionRef?>(
                    value: null,
                    title: Text('Start a new session'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  for (final recent in recents)
                    RadioListTile<AcpRecentSessionRef?>(
                      value: recent,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        recent.title?.trim().isNotEmpty ?? false
                            ? recent.title!
                            : 'Resume ${acpCwdSummary(recent.cwd)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'last active ${acpRelativeTime(recent.lastActivityAt)}',
                        style: FluttyTheme.monoStyle,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: FluttyTheme.spacingXs),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({
    required this.provider,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final AcpProvider provider;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) => InputChip(
    label: Text(provider.label),
    selected: selected,
    onSelected: onSelected == null ? null : (_) => onSelected!(),
    avatar: const Icon(Icons.smart_toy_outlined, size: 18),
  );
}

// Re-exported so this sheet does not depend on the notification-navigation
// layer just for the home fallback location.
/// Builds the Connections-tab home location used as the base of the
/// Open Terminal stack.
String buildTmuxAlertHomeLocationSafe() =>
    Uri(path: '/', queryParameters: const {'tab': 'connections'}).toString();
