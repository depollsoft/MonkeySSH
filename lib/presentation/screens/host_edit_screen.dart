import 'dart:async';

import 'package:drift/drift.dart' show InvalidDataException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/host_cli_launch_preferences.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/port_proxy_name.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/wifi_network_service.dart';
import '../providers/entity_list_providers.dart';
import '../view_models/host_edit_view_model.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/font_family_picker.dart';
import '../widgets/host_port_forward_editor_sheet.dart';
import '../widgets/premium_access.dart';
import '../widgets/premium_badge.dart';
import '../widgets/terminal_theme_picker.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'transfer_screen.dart';

const _hostFieldHelperMaxLines = 4;
const _hostStartupModeOptions = <HostStartupMode>[
  HostStartupMode.none,
  HostStartupMode.monkeyMux,
  HostStartupMode.tmux,
  HostStartupMode.agent,
  HostStartupMode.customCommand,
  HostStartupMode.snippet,
];

/// Screen for adding or editing a host.
class HostEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [HostEditScreen].
  const HostEditScreen({this.hostId, this.initialSshUrl, super.key});

  /// The host ID to edit, or null for a new host.
  final int? hostId;

  /// SSH URL used to prefill a new host.
  final String? initialSshUrl;

  @override
  ConsumerState<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends ConsumerState<HostEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _labelFieldLocationKey = GlobalKey();
  final _hostnameFieldLocationKey = GlobalKey();
  final _portFieldLocationKey = GlobalKey();
  final _usernameFieldLocationKey = GlobalKey();
  final _tmuxSessionFieldLocationKey = GlobalKey();
  final _agentTmuxFlagsFieldLocationKey = GlobalKey();
  final _customCommandFieldLocationKey = GlobalKey();
  final _snippetFieldLocationKey = GlobalKey();
  final _portProxyNameFieldLocationKey = GlobalKey();

  late TextEditingController _labelController;
  late TextEditingController _hostnameController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _tagsController;
  late TextEditingController _autoConnectCommandController;
  late TextEditingController _tmuxSessionController;
  late TextEditingController _tmuxWorkingDirectoryController;
  late TextEditingController _tmuxExtraFlagsController;
  late TextEditingController _agentWorkingDirectoryController;
  late TextEditingController _agentTmuxSessionController;
  late TextEditingController _agentTmuxExtraFlagsController;
  late TextEditingController _agentArgumentsController;
  late TextEditingController _portProxyNameController;
  late FocusNode _labelFocusNode;
  late FocusNode _hostnameFocusNode;
  late FocusNode _portFocusNode;
  late FocusNode _usernameFocusNode;
  late FocusNode _tmuxSessionFocusNode;
  late FocusNode _agentTmuxFlagsFocusNode;
  late FocusNode _customCommandFocusNode;
  late FocusNode _snippetFocusNode;
  late FocusNode _portProxyNameFocusNode;

  int? _selectedKeyId;
  int? _selectedGroupId;
  int? _selectedJumpHostId;
  List<String> _skipJumpHostOnSsids = const [];
  int? _selectedAutoConnectSnippetId;
  String? _selectedLightThemeId;
  String? _selectedDarkThemeId;
  String? _selectedFontFamily;
  HostStartupMode _selectedStartupMode = HostStartupMode.none;
  AutoConnectCommandMode _selectedAutoConnectMode = AutoConnectCommandMode.none;
  AgentLaunchTool _selectedAgentLaunchTool = AgentLaunchTool.claudeCode;
  RemoteMuxBackend _selectedAgentMuxBackend = RemoteMuxBackend.monkeyMux;
  bool _isFavorite = false;
  bool _isBusy = false;
  bool _showPassword = false;
  bool _disableTmuxStatusBar = false;
  bool _disableAgentTmuxStatusBar = false;
  bool _startClisInYoloMode = false;
  bool _autoForwardPorts = false;

  List<PortForward> _portForwards = [];

  /// Tracks whether the form has unsaved changes without requiring a full
  /// widget tree rebuild on every keystroke. Updated by text-controller
  /// listeners and by every non-text setState that touches draft state.
  late final ValueNotifier<bool> _isDirtyNotifier;

  @override
  void initState() {
    super.initState();
    _isDirtyNotifier = ValueNotifier(false);
    _labelController = TextEditingController();
    _hostnameController = TextEditingController();
    _portController = TextEditingController(text: '22');
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _tagsController = TextEditingController();
    _autoConnectCommandController = TextEditingController();
    _tmuxSessionController = TextEditingController();
    _tmuxWorkingDirectoryController = TextEditingController();
    _tmuxExtraFlagsController = TextEditingController();
    _agentWorkingDirectoryController = TextEditingController();
    _agentTmuxSessionController = TextEditingController();
    _agentTmuxExtraFlagsController = TextEditingController();
    _agentArgumentsController = TextEditingController();
    _portProxyNameController = TextEditingController();
    _labelFocusNode = FocusNode();
    _hostnameFocusNode = FocusNode();
    _portFocusNode = FocusNode();
    _usernameFocusNode = FocusNode();
    _tmuxSessionFocusNode = FocusNode();
    _agentTmuxFlagsFocusNode = FocusNode();
    _customCommandFocusNode = FocusNode();
    _snippetFocusNode = FocusNode();
    _portProxyNameFocusNode = FocusNode();

    for (final c in [
      _labelController,
      _hostnameController,
      _portController,
      _usernameController,
      _passwordController,
      _tagsController,
      _autoConnectCommandController,
      _tmuxSessionController,
      _tmuxWorkingDirectoryController,
      _tmuxExtraFlagsController,
      _agentWorkingDirectoryController,
      _agentTmuxSessionController,
      _agentTmuxExtraFlagsController,
      _agentArgumentsController,
      _portProxyNameController,
    ]) {
      c.addListener(_updateDirtyState);
    }

    if (widget.hostId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadHost());
        }
      });
    } else {
      if (widget.initialSshUrl?.trim().isNotEmpty ?? false) {
        _applySshUrl(widget.initialSshUrl!.trim());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ref
            .read(hostEditViewModelProvider(widget.hostId).notifier)
            .markInitialDraft(_currentDraft());
      });
    }
  }

  void _applySshUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.scheme != 'ssh' || uri.host.isEmpty) {
      return;
    }

    _labelController.text = uri.host;
    _hostnameController.text = uri.host;
    if (uri.hasPort) {
      _portController.text = uri.port.toString();
    }
    if (uri.userInfo.isNotEmpty) {
      final userInfoParts = uri.userInfo.split(':');
      _usernameController.text = Uri.decodeComponent(userInfoParts.first);
    }
  }

  Future<void> _loadHost() async {
    final result = await ref
        .read(hostEditViewModelProvider(widget.hostId).notifier)
        .loadHost();
    if (!mounted) return;
    if (result == null) {
      ref
          .read(hostEditViewModelProvider(widget.hostId).notifier)
          .markInitialDraft(_currentDraft());
      _updateDirtyState();
      return;
    }
    final host = result.host;
    final preset = result.preset;
    final cliLaunchPreferences = result.cliLaunchPreferences;
    final tmuxExtraFlags = host.tmuxExtraFlags ?? '';
    setState(() {
      _labelController.text = host.label;
      _hostnameController.text = host.hostname;
      _portController.text = host.port.toString();
      _usernameController.text = host.username;
      _passwordController.text = host.password ?? '';
      _tagsController.text = host.tags ?? '';
      _selectedKeyId = host.keyId;
      _selectedGroupId = host.groupId;
      _selectedJumpHostId = host.jumpHostId;
      _skipJumpHostOnSsids = decodeSkipJumpHostSsids(host.skipJumpHostOnSsids);
      _selectedAutoConnectSnippetId = host.autoConnectSnippetId;
      _selectedLightThemeId = host.terminalThemeLightId;
      _selectedDarkThemeId = host.terminalThemeDarkId;
      _selectedFontFamily = host.terminalFontFamily;
      _tmuxSessionController.text = host.tmuxSessionName ?? '';
      _tmuxWorkingDirectoryController.text = host.tmuxWorkingDirectory ?? '';
      _tmuxExtraFlagsController.text = stripTmuxDisableStatusBarCommand(
        tmuxExtraFlags,
      );
      _autoConnectCommandController.text = host.autoConnectCommand ?? '';
      _disableTmuxStatusBar = hasTmuxDisableStatusBarCommand(tmuxExtraFlags);
      _disableAgentTmuxStatusBar = preset?.tmuxDisableStatusBar ?? false;
      _startClisInYoloMode = cliLaunchPreferences.startInYoloMode;
      _autoForwardPorts = host.autoForwardPorts;
      _portProxyNameController.text = host.portProxyName ?? '';
      _selectedAutoConnectMode = resolveAutoConnectCommandMode(
        command: host.autoConnectCommand,
        snippetId: host.autoConnectSnippetId,
      );
      _selectedStartupMode = _resolveStartupMode(
        host: host,
        preset: preset,
        autoConnectMode: _selectedAutoConnectMode,
      );
      if (preset != null) {
        final presetCommand = _tryBuildAgentLaunchCommand(
          preset,
          startInYoloMode: cliLaunchPreferences.startInYoloMode,
        );
        _selectedAgentLaunchTool = preset.tool;
        _selectedAgentMuxBackend = preset.effectiveRemoteMuxBackend;
        _agentWorkingDirectoryController.text = preset.workingDirectory ?? '';
        _agentTmuxSessionController.text = preset.tmuxSessionName ?? '';
        _agentTmuxExtraFlagsController.text = preset.tmuxExtraFlags ?? '';
        _agentArgumentsController.text = preset.additionalArguments ?? '';
        if (presetCommand != null &&
            (_selectedAutoConnectMode == AutoConnectCommandMode.custom ||
                host.autoConnectCommand == presetCommand)) {
          _autoConnectCommandController.text = presetCommand;
        }
      }
      _isFavorite = host.isFavorite;
      _portForwards = result.portForwards;
    });
    ref
        .read(hostEditViewModelProvider(widget.hostId).notifier)
        .markInitialDraft(_currentDraft());
    _updateDirtyState();
  }

  @override
  void dispose() {
    _isDirtyNotifier.dispose();
    _labelController.dispose();
    _hostnameController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _tagsController.dispose();
    _autoConnectCommandController.dispose();
    _tmuxSessionController.dispose();
    _tmuxWorkingDirectoryController.dispose();
    _tmuxExtraFlagsController.dispose();
    _agentWorkingDirectoryController.dispose();
    _agentTmuxSessionController.dispose();
    _agentTmuxExtraFlagsController.dispose();
    _agentArgumentsController.dispose();
    _portProxyNameController.dispose();
    _labelFocusNode.dispose();
    _hostnameFocusNode.dispose();
    _portFocusNode.dispose();
    _usernameFocusNode.dispose();
    _tmuxSessionFocusNode.dispose();
    _agentTmuxFlagsFocusNode.dispose();
    _customCommandFocusNode.dispose();
    _snippetFocusNode.dispose();
    _portProxyNameFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Synchronizes [_isDirtyNotifier] with the current unsaved-changes state.
  ///
  /// Call this after any mutation that could change the current draft
  /// without going through a text-controller listener (e.g. dropdown/checkbox
  /// setStates, or after resetting the initial draft on save/load).
  void _updateDirtyState() {
    _isDirtyNotifier.value = ref
        .read(hostEditViewModelProvider(widget.hostId).notifier)
        .updateDraft(_currentDraft());
  }

  HostEditDraft _currentDraft() => (
    label: _labelController.text,
    hostname: _hostnameController.text,
    port: _portController.text,
    username: _usernameController.text,
    password: _passwordController.text,
    tags: _tagsController.text,
    autoConnectCommand: _autoConnectCommandController.text,
    tmuxSession: _tmuxSessionController.text,
    tmuxWorkingDirectory: _tmuxWorkingDirectoryController.text,
    tmuxExtraFlags: _tmuxExtraFlagsController.text,
    agentWorkingDirectory: _agentWorkingDirectoryController.text,
    agentTmuxSession: _agentTmuxSessionController.text,
    agentTmuxExtraFlags: _agentTmuxExtraFlagsController.text,
    agentArguments: _agentArgumentsController.text,
    portProxyName: _portProxyNameController.text,
    selectedAgentMuxBackend: _selectedAgentMuxBackend,
    selectedKeyId: _selectedKeyId,
    selectedGroupId: _selectedGroupId,
    selectedJumpHostId: _selectedJumpHostId,
    skipJumpHostOnSsids: encodeSkipJumpHostSsids(_skipJumpHostOnSsids),
    selectedAutoConnectSnippetId: _selectedAutoConnectSnippetId,
    selectedLightThemeId: _selectedLightThemeId,
    selectedDarkThemeId: _selectedDarkThemeId,
    selectedFontFamily: _selectedFontFamily,
    selectedStartupMode: _selectedStartupMode,
    selectedAutoConnectMode: _selectedAutoConnectMode,
    selectedAgentLaunchTool: _selectedAgentLaunchTool,
    isFavorite: _isFavorite,
    disableTmuxStatusBar: _disableTmuxStatusBar,
    disableAgentTmuxStatusBar: _disableAgentTmuxStatusBar,
    startClisInYoloMode: _startClisInYoloMode,
    agentWindowModePreference: AgentWindowModePreference.askEveryTime,
    autoForwardPorts: _autoForwardPorts,
  );

  void _closeWithoutUnsavedPrompt(SnackBar snackBar) {
    final messenger = ScaffoldMessenger.of(context);
    ref
        .read(hostEditViewModelProvider(widget.hostId).notifier)
        .markInitialDraft(_currentDraft());
    _updateDirtyState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.pop();
      messenger.showSnackBar(snackBar);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.hostId != null;
    final isLoading = ref.watch(
      hostEditViewModelProvider(
        widget.hostId,
      ).select((state) => state.isLoading),
    );
    final keysAsync = ref.watch(allKeysProvider);
    final hostsAsync = ref.watch(allHostsProvider);
    final snippetsAsync = ref.watch(allSnippetsProvider);
    final monetizationState =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final hasAutomationAccess = monetizationState.allowsFeature(
      MonetizationFeature.autoConnectAutomation,
    );
    final hasAgentPresetAccess = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );
    final hasHostThemeAccess = monetizationState.allowsFeature(
      MonetizationFeature.hostSpecificThemes,
    );
    final terminalThemes =
        ref.watch(allTerminalThemesProvider).asData?.value ??
        TerminalThemes.all;

    // ValueListenableBuilder keeps UnsavedChangesGuard (and its PopScope) in
    // sync with dirty state without rebuilding the whole tree on every
    // keystroke. Rebuilds happen only when dirty state actually transitions
    // (clean → dirty on first edit, dirty → clean after save).
    return ValueListenableBuilder<bool>(
      valueListenable: _isDirtyNotifier,
      builder: (context, isDirty, _) => UnsavedChangesGuard(
        hasUnsavedChanges: isDirty,
        child: Scaffold(
          appBar: AppBar(
            title: Text(isEditing ? 'Edit Host' : 'Add Host'),
            actions: [
              if (!isEditing)
                IconButton(
                  icon: const Icon(Icons.download_for_offline_outlined),
                  tooltip: 'Import transfer payload',
                  onPressed: () => unawaited(_handleImportTransferTap()),
                ),
              IconButton(
                icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
                onPressed: () {
                  setState(() => _isFavorite = !_isFavorite);
                  _updateDirtyState();
                },
                tooltip: _isFavorite
                    ? 'Remove from favorites'
                    : 'Add to favorites',
              ),
            ],
          ),
          body: isLoading
              ? const Center(child: CircularProgressIndicator())
              : Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Label
                        KeyedSubtree(
                          key: _labelFieldLocationKey,
                          child: TextFormField(
                            key: const Key('host-label-field'),
                            controller: _labelController,
                            focusNode: _labelFocusNode,
                            decoration: const InputDecoration(
                              labelText: 'Label',
                              hintText: 'My Server',
                              prefixIcon: Icon(Icons.label),
                            ),
                            textInputAction: TextInputAction.next,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter a label';
                              }
                              if (value.length > 255) {
                                return 'Label must be 255 characters or fewer';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Hostname
                        KeyedSubtree(
                          key: _hostnameFieldLocationKey,
                          child: TextFormField(
                            key: const Key('host-hostname-field'),
                            controller: _hostnameController,
                            focusNode: _hostnameFocusNode,
                            decoration: const InputDecoration(
                              labelText: 'Hostname',
                              hintText: 'example.com or 192.168.1.1',
                              prefixIcon: Icon(Icons.dns),
                            ),
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter a hostname';
                              }
                              if (value.length > 255) {
                                return 'Hostname must be 255 characters or fewer';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Port
                        KeyedSubtree(
                          key: _portFieldLocationKey,
                          child: TextFormField(
                            key: const Key('host-port-field'),
                            controller: _portController,
                            focusNode: _portFocusNode,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              hintText: '22',
                              prefixIcon: Icon(Icons.numbers),
                            ),
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter a port';
                              }
                              final port = int.tryParse(value);
                              if (port == null || port < 1 || port > 65535) {
                                return 'Port must be between 1 and 65535';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Username
                        KeyedSubtree(
                          key: _usernameFieldLocationKey,
                          child: TextFormField(
                            key: const Key('host-username-field'),
                            controller: _usernameController,
                            focusNode: _usernameFocusNode,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              hintText: 'root',
                              prefixIcon: Icon(Icons.person),
                            ),
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter a username';
                              }
                              if (value.length > 255) {
                                return 'Username must be 255 characters or fewer';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextFormField(
                          controller: _tagsController,
                          decoration: const InputDecoration(
                            labelText: 'Tags (optional)',
                            hintText: 'prod, db, eu-west',
                            prefixIcon: Icon(Icons.sell_outlined),
                            helperText:
                                'Comma-separated tags for search/organization',
                            helperMaxLines: _hostFieldHelperMaxLines,
                          ),
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 24),

                        // Authentication section
                        Text(
                          'authentication',
                          style: FluttyTheme.displayMono(
                            fontSize: 15,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Password
                        TextFormField(
                          controller: _passwordController,
                          decoration: InputDecoration(
                            labelText: 'Password (optional)',
                            hintText: 'Leave empty for key-only auth',
                            helperText:
                                widget.hostId != null &&
                                    ref
                                        .read(hostRepositoryProvider)
                                        .hasUnreadablePassword(widget.hostId!)
                                ? 'Saved password could not be read. Re-enter it to connect.'
                                : null,
                            helperMaxLines: _hostFieldHelperMaxLines,
                            prefixIcon: const Icon(Icons.lock),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                            ),
                          ),
                          obscureText: !_showPassword,
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 16),

                        // SSH Key dropdown
                        keysAsync.when(
                          loading: () => const LinearProgressIndicator(),
                          error: (_, _) => const Text('Error loading keys'),
                          data: (keys) {
                            // Validate selected key still exists
                            final validKeyId =
                                _selectedKeyId != null &&
                                    keys.any((k) => k.id == _selectedKeyId)
                                ? _selectedKeyId
                                : null;
                            if (validKeyId != _selectedKeyId) {
                              // Schedule state update for next frame
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  setState(() => _selectedKeyId = null);
                                  _updateDirtyState();
                                }
                              });
                            }
                            return DropdownButtonFormField<int?>(
                              // ignore: deprecated_member_use
                              value: validKeyId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'SSH Key (optional)',
                                prefixIcon: Icon(Icons.key),
                                helperText:
                                    'Auto tries up to 5 installed keys when password is empty',
                                helperMaxLines: _hostFieldHelperMaxLines,
                              ),
                              items: [
                                const DropdownMenuItem<int?>(
                                  child: Text('Auto'),
                                ),
                                ...keys.map(
                                  (key) => DropdownMenuItem(
                                    value: key.id,
                                    child: Text(
                                      key.name,
                                      style: FluttyTheme.monoStyle,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                setState(() => _selectedKeyId = value);
                                _updateDirtyState();
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 24),

                        _buildStartupSection(
                          context: context,
                          hasAutomationAccess: hasAutomationAccess,
                          hasAgentPresetAccess: hasAgentPresetAccess,
                          snippetsAsync: snippetsAsync,
                        ),
                        const SizedBox(height: 24),

                        // Advanced section
                        ExpansionTile(
                          key: const Key('host-advanced-tile'),
                          title: const Text('Advanced'),
                          initiallyExpanded: _selectedJumpHostId != null,
                          children: [
                            const SizedBox(height: 8),
                            // Jump host dropdown
                            hostsAsync.when(
                              loading: () => const LinearProgressIndicator(),
                              error: (_, _) =>
                                  const Text('Error loading hosts'),
                              data: (hosts) {
                                // Filter out current host from jump host options
                                final availableHosts = hosts
                                    .where((h) => h.id != widget.hostId)
                                    .toList();
                                // Validate selected jump host still exists
                                final validJumpHostId =
                                    _selectedJumpHostId != null &&
                                        availableHosts.any(
                                          (h) => h.id == _selectedJumpHostId,
                                        )
                                    ? _selectedJumpHostId
                                    : null;
                                if (validJumpHostId != _selectedJumpHostId) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted) {
                                      setState(
                                        () => _selectedJumpHostId = null,
                                      );
                                      _updateDirtyState();
                                    }
                                  });
                                }
                                return DropdownButtonFormField<int?>(
                                  // ignore: deprecated_member_use
                                  value: validJumpHostId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Jump Host (optional)',
                                    prefixIcon: Icon(Icons.hub),
                                    helperText:
                                        'Connect through another host (bastion)',
                                    helperMaxLines: _hostFieldHelperMaxLines,
                                  ),
                                  items: [
                                    const DropdownMenuItem(child: Text('None')),
                                    ...availableHosts.map(
                                      (host) => DropdownMenuItem(
                                        value: host.id,
                                        child: Text(
                                          host.label,
                                          style: FluttyTheme.monoStyle,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    setState(() => _selectedJumpHostId = value);
                                    _updateDirtyState();
                                  },
                                );
                              },
                            ),
                            if (_selectedJumpHostId != null) ...[
                              const SizedBox(height: 16),
                              _SkipJumpHostOnWifiSection(
                                ssids: _skipJumpHostOnSsids,
                                onChanged: (next) {
                                  setState(() => _skipJumpHostOnSsids = next);
                                  _updateDirtyState();
                                },
                              ),
                            ],
                            const SizedBox(height: 24),
                            // Terminal theme section
                            Row(
                              children: [
                                Text(
                                  'terminal theme',
                                  style: FluttyTheme.displayMono(
                                    fontSize: 14,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const PremiumBadge(),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (!hasHostThemeAccess) ...[
                              Text(
                                'MonkeySSH Pro unlocks per-host theme overrides. App-wide default themes stay free in Settings.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 12),
                            ],
                            // Light mode theme
                            _ThemeSelectionTile(
                              label: 'Light Mode Theme',
                              themeId: _selectedLightThemeId,
                              themes: terminalThemes,
                              defaultLabel: 'Use default',
                              onTap: () =>
                                  _handleThemeSelectionTap(isLight: true),
                              onClear: () {
                                setState(() {
                                  _selectedLightThemeId = null;
                                });
                                _updateDirtyState();
                              },
                            ),
                            const SizedBox(height: 8),
                            // Dark mode theme
                            _ThemeSelectionTile(
                              label: 'Dark Mode Theme',
                              themeId: _selectedDarkThemeId,
                              themes: terminalThemes,
                              defaultLabel: 'Use default',
                              onTap: () =>
                                  _handleThemeSelectionTap(isLight: false),
                              onClear: () {
                                setState(() {
                                  _selectedDarkThemeId = null;
                                });
                                _updateDirtyState();
                              },
                            ),
                            const SizedBox(height: 16),
                            // Terminal font section
                            _FontSelectionTile(
                              fontFamily: _selectedFontFamily,
                              defaultLabel: 'Use default',
                              onTap: _selectFont,
                              onClear: () {
                                setState(() => _selectedFontFamily = null);
                                _updateDirtyState();
                              },
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                        const SizedBox(height: 32),

                        // Port Forwards section
                        _buildPortForwardsSection(context, isEditing),
                        const SizedBox(height: 32),

                        // Save button
                        FilledButton.icon(
                          key: const Key('host-save-button'),
                          onPressed: _isBusy ? null : _saveHost,
                          icon: _isBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save),
                          label: Text(isEditing ? 'Save Changes' : 'Add Host'),
                        ),
                        const SizedBox(height: 16),

                        // Test connection button
                        OutlinedButton.icon(
                          onPressed: _isBusy ? null : _testConnection,
                          icon: const Icon(Icons.network_check),
                          label: const Text('Test Connection'),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _applySavedAutomaticPortForwarding() async {
    final sessions = ref.read(activeSessionsProvider.notifier);
    try {
      await sessions.reconfigureAutomaticPortForwardingForConnectedHosts();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'host editor',
          context: ErrorDescription(
            'while applying automatic port forwarding live',
          ),
        ),
      );
    }
  }

  HostStartupMode _resolveStartupMode({
    required Host host,
    required AgentLaunchPreset? preset,
    required AutoConnectCommandMode autoConnectMode,
  }) {
    if (preset != null) {
      return HostStartupMode.agent;
    }
    if (host.tmuxSessionName case final value? when value.trim().isNotEmpty) {
      return switch (resolveRemoteMuxBackendForStartup(
        storedBackend: host.remoteMuxBackend,
        tmuxExtraFlags: host.tmuxExtraFlags,
      )) {
        RemoteMuxBackend.auto => HostStartupMode.monkeyMux,
        RemoteMuxBackend.monkeyMux => HostStartupMode.monkeyMux,
        RemoteMuxBackend.tmux => HostStartupMode.tmux,
      };
    }
    return switch (autoConnectMode) {
      AutoConnectCommandMode.none => HostStartupMode.none,
      AutoConnectCommandMode.custom => HostStartupMode.customCommand,
      AutoConnectCommandMode.snippet => HostStartupMode.snippet,
    };
  }

  Widget _buildStartupSection({
    required BuildContext context,
    required bool hasAutomationAccess,
    required bool hasAgentPresetAccess,
    required AsyncValue<List<Snippet>> snippetsAsync,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Launch After Connect', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Choose what MonkeySSH starts after SSH connects. MonkeyMux and tmux keep remote shells alive across reconnects and add the window switcher; agent, command, and snippet options start a workflow automatically.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          key: const Key('host-cli-yolo-mode-checkbox'),
          value: _startClisInYoloMode,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Start supported coding CLIs in YOLO mode'),
          subtitle: Text(
            hasAgentPresetAccess
                ? 'Applies to coding CLI launches on this host. Supported agents use their startup permission settings.'
                : 'MonkeySSH Pro unlocks host-specific coding CLI defaults like YOLO mode.',
          ),
          onChanged: hasAgentPresetAccess
              ? (value) {
                  setState(() => _startClisInYoloMode = value ?? false);
                  _updateDirtyState();
                  _syncAutoConnectCommandFromPreset();
                }
              : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<HostStartupMode>(
          key: const Key('host-startup-mode-field'),
          // ignore: deprecated_member_use
          value: _selectedStartupMode,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Startup behavior',
            prefixIcon: Icon(Icons.play_circle_outline),
            helperText:
                'Pick the startup flow for this host. Choose MonkeyMux for the bundled window manager, or tmux for an existing remote tmux setup.',
            helperMaxLines: _hostFieldHelperMaxLines,
          ),
          items: _hostStartupModeOptions
              .map(
                (mode) => DropdownMenuItem<HostStartupMode>(
                  value: mode,
                  child: Text(mode.label),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            unawaited(_handleStartupModeSelection(value));
          },
        ),
        switch (_selectedStartupMode) {
          HostStartupMode.none => const SizedBox.shrink(),
          HostStartupMode.muxAuto ||
          HostStartupMode.monkeyMux ||
          HostStartupMode.tmux => _buildMuxStartupFields(context),
          HostStartupMode.agent => _buildAgentStartupFields(
            context,
            hasAgentPresetAccess: hasAgentPresetAccess,
          ),
          HostStartupMode.customCommand => _buildCustomCommandFields(
            hasAutomationAccess: hasAutomationAccess,
          ),
          HostStartupMode.snippet => _buildSnippetFields(
            context,
            snippetsAsync: snippetsAsync,
            hasAutomationAccess: hasAutomationAccess,
          ),
        },
      ],
    );
  }

  Widget _buildMuxStartupFields(BuildContext context) {
    final isTmuxMode = _selectedStartupMode == HostStartupMode.tmux;
    final isMonkeyMuxMode =
        _selectedStartupMode == HostStartupMode.monkeyMux ||
        _selectedStartupMode == HostStartupMode.muxAuto;
    final sessionLabel = isTmuxMode
        ? 'tmux session name'
        : 'MonkeyMux session name';
    final sessionHelperText = switch (_selectedStartupMode) {
      HostStartupMode.muxAuto =>
        'Legacy automatic mode. New edits use MonkeyMux or tmux explicitly.',
      HostStartupMode.monkeyMux =>
        'Uses MonkeySSH\'s bundled helper to keep windows alive across reconnects and report window changes over a backchannel.',
      HostStartupMode.tmux =>
        'Uses tmux already installed on the remote host. Choose this when you want tmux-compatible sessions or shared tmux clients.',
      _ => '',
    };
    final effectiveTmuxExtraFlags = resolveTmuxExtraFlags(
      extraFlags: _tmuxExtraFlagsController.text,
      disableStatusBar: _disableTmuxStatusBar,
    );
    final preview = !isTmuxMode || _tmuxSessionController.text.trim().isEmpty
        ? null
        : buildTmuxCommand(
            sessionName: _tmuxSessionController.text.trim(),
            workingDirectory: _tmuxWorkingDirectoryController.text.trim(),
            extraFlags: effectiveTmuxExtraFlags,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        KeyedSubtree(
          key: _tmuxSessionFieldLocationKey,
          child: TextFormField(
            key: const Key('host-tmux-session-field'),
            controller: _tmuxSessionController,
            focusNode: _tmuxSessionFocusNode,
            decoration: InputDecoration(
              labelText: sessionLabel,
              hintText: 'workspace',
              prefixIcon: const Icon(Icons.view_carousel_outlined),
              helperText: sessionHelperText,
              helperMaxLines: _hostFieldHelperMaxLines,
            ),
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            validator: (value) {
              if (!_selectedStartupMode.usesRemoteMultiplexer) {
                return null;
              }
              if (value == null || value.trim().isEmpty) {
                return _selectedStartupMode == HostStartupMode.tmux
                    ? 'Enter a tmux session name'
                    : 'Enter a MonkeyMux session name';
              }
              return null;
            },
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('host-tmux-working-directory-field'),
          controller: _tmuxWorkingDirectoryController,
          decoration: const InputDecoration(
            labelText: 'Working directory (optional)',
            hintText: '~/src/app',
            prefixIcon: Icon(Icons.folder_outlined),
          ),
          autocorrect: false,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (isTmuxMode) ...[
          TextFormField(
            key: const Key('host-tmux-extra-flags-field'),
            controller: _tmuxExtraFlagsController,
            decoration: const InputDecoration(
              labelText: 'Extra tmux flags (optional)',
              hintText: '-f ~/.tmux.conf',
              prefixIcon: Icon(Icons.tune_outlined),
            ),
            autocorrect: false,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            key: const Key('host-tmux-disable-status-bar-checkbox'),
            value: _disableTmuxStatusBar,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Hide tmux status bar'),
            subtitle: const Text(
              'Append `\\; set status off` so MonkeySSH\'s tmux bar is the only one shown.',
            ),
            onChanged: (value) {
              setState(() => _disableTmuxStatusBar = value ?? false);
              _updateDirtyState();
            },
          ),
        ] else if (isMonkeyMuxMode) ...[
          const SizedBox(height: 4),
          Text(
            'MonkeyMux passes the terminal stream through directly. Window names, activity, switching, and close events use the backchannel instead of extra SSH sessions.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (preview != null) ...[
          const SizedBox(height: 12),
          Text(
            'Generated command',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SelectableText(
            preview,
            style: FluttyTheme.monoStyle.copyWith(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAgentStartupFields(
    BuildContext context, {
    required bool hasAgentPresetAccess,
  }) {
    final currentPreset = _buildCurrentAgentLaunchPreset()!;
    String? generatedCommand;
    String? generatedCommandError;
    final isAgentTmuxBackend =
        _selectedAgentMuxBackend == RemoteMuxBackend.tmux;
    try {
      generatedCommand = buildAgentLaunchCommand(
        currentPreset,
        startInYoloMode: _startClisInYoloMode,
      );
    } on FormatException catch (error) {
      generatedCommandError = error.message;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        DropdownButtonFormField<AgentLaunchTool>(
          key: const Key('host-agent-tool-field'),
          // ignore: deprecated_member_use
          value: _selectedAgentLaunchTool,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Coding agent',
            prefixIcon: Padding(
              padding: const EdgeInsets.all(12),
              child: AgentToolIcon(tool: _selectedAgentLaunchTool),
            ),
            helperText:
                'Launch an agent directly, or pair it with MonkeyMux or tmux so MonkeySSH can show window navigation.',
            helperMaxLines: _hostFieldHelperMaxLines,
          ),
          items: AgentLaunchTool.uiDisplayOrder
              .map(
                (tool) => DropdownMenuItem<AgentLaunchTool>(
                  value: tool,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AgentToolIcon(tool: tool, size: 18),
                      const SizedBox(width: 10),
                      Text(tool.label),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
          selectedItemBuilder: (context) => AgentLaunchTool.uiDisplayOrder
              .map((tool) => Text(tool.label))
              .toList(growable: false),
          onChanged: hasAgentPresetAccess
              ? (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() => _selectedAgentLaunchTool = value);
                  _updateDirtyState();
                  _syncAutoConnectCommandFromPreset();
                }
              : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<RemoteMuxBackend>(
          key: const Key('host-agent-mux-backend-field'),
          // ignore: deprecated_member_use
          value: _selectedAgentMuxBackend,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Terminal window backend',
            prefixIcon: Icon(Icons.view_carousel_outlined),
            helperText:
                'Choose how the agent terminal is kept in the window switcher: MonkeyMux uses the bundled helper; tmux uses a remote tmux session.',
            helperMaxLines: _hostFieldHelperMaxLines,
          ),
          items: const [
            DropdownMenuItem<RemoteMuxBackend>(
              value: RemoteMuxBackend.monkeyMux,
              child: Text('MonkeyMux'),
            ),
            DropdownMenuItem<RemoteMuxBackend>(
              value: RemoteMuxBackend.tmux,
              child: Text('tmux'),
            ),
          ],
          onChanged: hasAgentPresetAccess
              ? (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() => _selectedAgentMuxBackend = value);
                  _updateDirtyState();
                  _syncAutoConnectCommandFromPreset();
                }
              : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('host-agent-working-directory-field'),
          controller: _agentWorkingDirectoryController,
          readOnly: !hasAgentPresetAccess,
          decoration: const InputDecoration(
            labelText: 'Working directory (optional)',
            hintText: '~/src/app',
            prefixIcon: Icon(Icons.folder_outlined),
          ),
          autocorrect: false,
          onChanged: hasAgentPresetAccess
              ? (_) => _handleAgentPresetFieldChanged()
              : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('host-agent-tmux-session-field'),
          controller: _agentTmuxSessionController,
          readOnly: !hasAgentPresetAccess,
          decoration: InputDecoration(
            labelText: isAgentTmuxBackend
                ? 'tmux session (optional)'
                : 'MonkeyMux session (optional)',
            hintText: 'app-agent',
            prefixIcon: const Icon(Icons.view_carousel_outlined),
            helperText: isAgentTmuxBackend
                ? 'Add a tmux session to keep agent workspaces visible in the window bar.'
                : 'Add a MonkeyMux session to keep agent workspaces visible in the window bar.',
            helperMaxLines: _hostFieldHelperMaxLines,
          ),
          autocorrect: false,
          onChanged: hasAgentPresetAccess
              ? (_) => _handleAgentPresetFieldChanged()
              : null,
        ),
        if (isAgentTmuxBackend) ...[
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const Key('host-agent-disable-status-bar-checkbox'),
            value: _disableAgentTmuxStatusBar,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Hide tmux status bar'),
            subtitle: const Text(
              'When a tmux session is set, append `\\; set status off` so MonkeySSH\'s tmux bar is the only one shown.',
            ),
            onChanged: hasAgentPresetAccess
                ? (value) {
                    setState(() => _disableAgentTmuxStatusBar = value ?? false);
                    _updateDirtyState();
                    _syncAutoConnectCommandFromPreset();
                  }
                : null,
          ),
          const SizedBox(height: 12),
          KeyedSubtree(
            key: _agentTmuxFlagsFieldLocationKey,
            child: TextFormField(
              key: const Key('host-agent-tmux-extra-flags-field'),
              controller: _agentTmuxExtraFlagsController,
              focusNode: _agentTmuxFlagsFocusNode,
              readOnly: !hasAgentPresetAccess,
              decoration: const InputDecoration(
                labelText: 'Extra tmux new-session flags (optional)',
                hintText: '-x 160 -y 48',
                prefixIcon: Icon(Icons.tune_outlined),
                helperText:
                    'Passed directly to `tmux new-session`. Used only when a tmux session is set for the coding agent launch.',
                helperMaxLines: _hostFieldHelperMaxLines,
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              autocorrect: false,
              validator: _validateAgentTmuxExtraFlags,
              onChanged: hasAgentPresetAccess
                  ? (_) => _handleAgentPresetFieldChanged()
                  : null,
            ),
          ),
        ] else ...[
          const SizedBox(height: 12),
          Text(
            'MonkeyMux is managed by MonkeySSH, so there are no tmux flags or tmux status-bar settings.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('host-agent-arguments-field'),
          controller: _agentArgumentsController,
          readOnly: !hasAgentPresetAccess,
          decoration: const InputDecoration(
            labelText: 'Extra arguments (optional)',
            hintText: '--resume',
            prefixIcon: Icon(Icons.tune_outlined),
          ),
          autocorrect: false,
          onChanged: hasAgentPresetAccess
              ? (_) => _handleAgentPresetFieldChanged()
              : null,
        ),
        if (_startClisInYoloMode &&
            !_selectedAgentLaunchTool.supportsYoloMode) ...[
          const SizedBox(height: 12),
          Text(
            '${_selectedAgentLaunchTool.label} does not expose a startup YOLO flag, so this host setting only affects other supported CLIs.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          currentPreset.usesMonkeyMuxSession
              ? 'Agent command'
              : 'Generated command',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        if (generatedCommand case final command?)
          SelectableText(
            command,
            style: FluttyTheme.monoStyle.copyWith(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          )
        else if (generatedCommandError case final error?)
          Text(
            error,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  Widget _buildCustomCommandFields({
    required bool hasAutomationAccess,
  }) => Column(
    children: [
      const SizedBox(height: 16),
      KeyedSubtree(
        key: _customCommandFieldLocationKey,
        child: TextFormField(
          key: const Key('host-auto-connect-command-field'),
          controller: _autoConnectCommandController,
          focusNode: _customCommandFocusNode,
          decoration: const InputDecoration(
            labelText: 'Custom command',
            hintText: defaultAutoConnectCommandSuggestion,
            helperText:
                'Run any shell command after connect. Choose the tmux or agent modes above for extra window-aware behavior.',
            prefixIcon: Icon(Icons.terminal),
            helperMaxLines: _hostFieldHelperMaxLines,
          ),
          minLines: 1,
          maxLines: 3,
          readOnly: !hasAutomationAccess,
          autocorrect: false,
          validator: (value) {
            if (_selectedStartupMode != HostStartupMode.customCommand) {
              return null;
            }
            if (value == null || value.trim().isEmpty) {
              return 'Enter a command or choose "Do nothing"';
            }
            return null;
          },
        ),
      ),
    ],
  );

  Widget _buildSnippetFields(
    BuildContext context, {
    required AsyncValue<List<Snippet>> snippetsAsync,
    required bool hasAutomationAccess,
  }) => Column(
    children: [
      const SizedBox(height: 16),
      snippetsAsync.when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => const Text('Error loading snippets'),
        data: (snippets) {
          final selectedSnippetStillExists = snippets.any(
            (snippet) => snippet.id == _selectedAutoConnectSnippetId,
          );
          final effectiveSnippetId = selectedSnippetStillExists
              ? _selectedAutoConnectSnippetId
              : null;
          final selectedSnippet = effectiveSnippetId == null
              ? null
              : snippets.firstWhere(
                  (snippet) => snippet.id == effectiveSnippetId,
                );
          return Column(
            children: [
              KeyedSubtree(
                key: _snippetFieldLocationKey,
                child: DropdownButtonFormField<int?>(
                  key: const Key('host-auto-connect-snippet-field'),
                  focusNode: _snippetFocusNode,
                  // ignore: deprecated_member_use
                  value: effectiveSnippetId,
                  decoration: const InputDecoration(
                    labelText: 'Snippet',
                    prefixIcon: Icon(Icons.code),
                    helperText:
                        'Variable prompts are not shown when a snippet runs automatically.',
                    helperMaxLines: _hostFieldHelperMaxLines,
                  ),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<int?>(
                      child: Text('Choose a snippet'),
                    ),
                    ...snippets.map(
                      (snippet) => DropdownMenuItem<int?>(
                        value: snippet.id,
                        child: Text(snippet.name, style: FluttyTheme.monoStyle),
                      ),
                    ),
                  ],
                  onChanged: hasAutomationAccess
                      ? (value) {
                          setState(() => _selectedAutoConnectSnippetId = value);
                          _updateDirtyState();
                        }
                      : null,
                  validator: (value) {
                    if (_selectedStartupMode != HostStartupMode.snippet) {
                      return null;
                    }
                    if (value == null) {
                      return 'Choose a snippet or select "Do nothing"';
                    }
                    return null;
                  },
                ),
              ),
              if (selectedSnippet != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    selectedSnippet.command,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    ],
  );

  Future<void> _saveHost() async {
    if (_isBusy) {
      return;
    }
    final formIsValid = _formKey.currentState!.validate();
    final invalidTarget = _firstInvalidHostField();
    if (!formIsValid || invalidTarget != null) {
      await _showValidationFailure(invalidTarget);
      return;
    }

    setState(() => _isBusy = true);
    try {
      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasAutomationAccess = monetizationState.allowsFeature(
        MonetizationFeature.autoConnectAutomation,
      );
      final hasAgentPresetAccess = monetizationState.allowsFeature(
        MonetizationFeature.agentLaunchPresets,
      );

      final draft = _currentDraft();
      await ref
          .read(hostEditViewModelProvider(widget.hostId).notifier)
          .save(
            HostEditSaveRequest(
              draft: draft,
              hasAutomationAccess: hasAutomationAccess,
              hasAgentPresetAccess: hasAgentPresetAccess,
            ),
          );
      unawaited(_applySavedAutomaticPortForwarding());
      if (widget.hostId == null) {
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logHostCreated(
                method: widget.initialSshUrl == null ? 'manual' : 'import',
                hasKey: draft.selectedKeyId != null,
                hasJumpHost: draft.selectedJumpHostId != null,
                hasAutoConnect:
                    draft.selectedStartupMode != HostStartupMode.none,
                hasAgentPreset:
                    draft.selectedStartupMode == HostStartupMode.agent,
              ),
        );
        if (draft.selectedStartupMode == HostStartupMode.agent) {
          unawaited(
            ref
                .read(telemetryServiceProvider)
                .logAgentLaunchUsed(
                  tool: draft.selectedAgentLaunchTool.name,
                  usedSessionHistory: false,
                  usesMux: draft.agentTmuxSession.trim().isNotEmpty,
                ),
          );
        }
      }

      if (mounted) {
        _closeWithoutUnsavedPrompt(
          SnackBar(
            content: Text(
              widget.hostId != null ? 'Host updated' : 'Host added',
            ),
          ),
        );
      }
    } on PortProxyNameConflictException catch (e) {
      if (mounted) {
        await _showValidationFailure((
          locationKey: _portProxyNameFieldLocationKey,
          focusNode: _portProxyNameFocusNode,
          message: '${e.message}. Choose a different proxy domain.',
        ));
      }
    } on InvalidDataException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t save this host. Check the field values and try again.',
            ),
          ),
        );
      }
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t read the saved credentials. Re-enter the password or import the SSH key again.',
            ),
          ),
        );
      }
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'hosts',
          context: ErrorDescription('while saving a host'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t save this host. Check the required fields and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _showValidationFailure(
    ({GlobalKey locationKey, FocusNode focusNode, String message})? target,
  ) async {
    final message =
        target?.message ?? 'Fix highlighted fields to save this host';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

    final contextToShow = target?.locationKey.currentContext;
    if (contextToShow == null) {
      target?.focusNode.requestFocus();
      return;
    }

    target?.focusNode.requestFocus();
    await Scrollable.ensureVisible(
      contextToShow,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.1,
    );
    if (!mounted) {
      return;
    }
    _formKey.currentState?.validate();
    target?.focusNode.requestFocus();
  }

  ({GlobalKey locationKey, FocusNode focusNode, String message})?
  _firstInvalidHostField() {
    for (final field in [
      (
        controller: _labelController,
        locationKey: _labelFieldLocationKey,
        focusNode: _labelFocusNode,
        label: 'Label',
      ),
      (
        controller: _hostnameController,
        locationKey: _hostnameFieldLocationKey,
        focusNode: _hostnameFocusNode,
        label: 'Hostname',
      ),
      (
        controller: _usernameController,
        locationKey: _usernameFieldLocationKey,
        focusNode: _usernameFocusNode,
        label: 'Username',
      ),
    ]) {
      if (field.controller.text.length > 255) {
        return (
          locationKey: field.locationKey,
          focusNode: field.focusNode,
          message: '${field.label} must be 255 characters or fewer',
        );
      }
    }
    final issue = ref
        .read(hostEditViewModelProvider(widget.hostId).notifier)
        .validateDraft(_currentDraft());
    if (issue == null) {
      return null;
    }

    final target = switch (issue.target) {
      HostEditValidationTarget.label => (
        locationKey: _labelFieldLocationKey,
        focusNode: _labelFocusNode,
      ),
      HostEditValidationTarget.hostname => (
        locationKey: _hostnameFieldLocationKey,
        focusNode: _hostnameFocusNode,
      ),
      HostEditValidationTarget.port => (
        locationKey: _portFieldLocationKey,
        focusNode: _portFocusNode,
      ),
      HostEditValidationTarget.username => (
        locationKey: _usernameFieldLocationKey,
        focusNode: _usernameFocusNode,
      ),
      HostEditValidationTarget.portProxyName => (
        locationKey: _portProxyNameFieldLocationKey,
        focusNode: _portProxyNameFocusNode,
      ),
      HostEditValidationTarget.tmuxSession => (
        locationKey: _tmuxSessionFieldLocationKey,
        focusNode: _tmuxSessionFocusNode,
      ),
      HostEditValidationTarget.agentTmuxFlags => (
        locationKey: _agentTmuxFlagsFieldLocationKey,
        focusNode: _agentTmuxFlagsFocusNode,
      ),
      HostEditValidationTarget.customCommand => (
        locationKey: _customCommandFieldLocationKey,
        focusNode: _customCommandFocusNode,
      ),
      HostEditValidationTarget.snippet => (
        locationKey: _snippetFieldLocationKey,
        focusNode: _snippetFocusNode,
      ),
    };

    return (
      locationKey: target.locationKey,
      focusNode: target.focusNode,
      message: issue.message,
    );
  }

  Future<void> _handleStartupModeSelection(HostStartupMode value) async {
    final previousMode = _selectedStartupMode;
    if (value == HostStartupMode.agent) {
      final hasAccess = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.agentLaunchPresets,
        blockedAction: 'Save coding-agent startup for this host',
        blockedOutcome:
            'Unlock Pro to launch your preferred agent workflow every time you '
            'connect.',
      );
      if (!hasAccess || !mounted) {
        return;
      }
    } else if (value == HostStartupMode.customCommand ||
        value == HostStartupMode.snippet) {
      final hasAccess = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.autoConnectAutomation,
        blockedAction: 'Save auto-connect automation for this host',
        blockedOutcome:
            'Unlock Pro to run this command or saved snippet automatically '
            'after connecting.',
      );
      if (!hasAccess || !mounted) {
        return;
      }
    }

    setState(() {
      _selectedStartupMode = value;
      _carryWindowConfigAcrossModeChange(previousMode, value);
      switch (value) {
        case HostStartupMode.none:
        case HostStartupMode.muxAuto:
        case HostStartupMode.monkeyMux:
        case HostStartupMode.tmux:
          _selectedAutoConnectMode = AutoConnectCommandMode.none;
        case HostStartupMode.agent:
          _selectedAutoConnectMode = AutoConnectCommandMode.custom;
        case HostStartupMode.customCommand:
          _selectedAutoConnectMode = AutoConnectCommandMode.custom;
        case HostStartupMode.snippet:
          _selectedAutoConnectMode = AutoConnectCommandMode.snippet;
      }
    });
    _updateDirtyState();
    if (value == HostStartupMode.agent) {
      _syncAutoConnectCommandFromPreset();
    }
  }

  /// Carries shared remote-window configuration across a startup-mode change so
  /// the session name, working directory, and tmux options a user enters for a
  /// MonkeyMux/tmux startup are retained when switching to (or from) a coding
  /// agent that reuses the same window backend. Only blank destination fields
  /// are seeded, so text already entered in the target mode is never
  /// overwritten.
  void _carryWindowConfigAcrossModeChange(
    HostStartupMode from,
    HostStartupMode to,
  ) {
    if (from.usesRemoteMultiplexer && to == HostStartupMode.agent) {
      final agentUnconfigured = _agentTmuxSessionController.text.trim().isEmpty;
      _seedControllerIfEmpty(
        _agentTmuxSessionController,
        _tmuxSessionController.text,
      );
      _seedControllerIfEmpty(
        _agentWorkingDirectoryController,
        _tmuxWorkingDirectoryController.text,
      );
      _seedControllerIfEmpty(
        _agentTmuxExtraFlagsController,
        _tmuxExtraFlagsController.text,
      );
      if (agentUnconfigured) {
        _selectedAgentMuxBackend =
            from.remoteMuxBackend == RemoteMuxBackend.tmux
            ? RemoteMuxBackend.tmux
            : RemoteMuxBackend.monkeyMux;
        _disableAgentTmuxStatusBar = _disableTmuxStatusBar;
      }
    } else if (from == HostStartupMode.agent && to.usesRemoteMultiplexer) {
      final muxUnconfigured = _tmuxSessionController.text.trim().isEmpty;
      _seedControllerIfEmpty(
        _tmuxSessionController,
        _agentTmuxSessionController.text,
      );
      _seedControllerIfEmpty(
        _tmuxWorkingDirectoryController,
        _agentWorkingDirectoryController.text,
      );
      _seedControllerIfEmpty(
        _tmuxExtraFlagsController,
        _agentTmuxExtraFlagsController.text,
      );
      if (muxUnconfigured) {
        _disableTmuxStatusBar = _disableAgentTmuxStatusBar;
      }
    }
  }

  /// Copies [value] into [controller] only when the controller is currently
  /// blank, preserving any text the user already entered in the destination.
  void _seedControllerIfEmpty(TextEditingController controller, String value) {
    if (controller.text.trim().isEmpty && value.trim().isNotEmpty) {
      controller.text = value;
    }
  }

  Future<void> _testConnection() async {
    if (_isBusy) {
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isBusy = true);
    final cancellationToken = SshConnectionCancellationToken();
    final messenger = ScaffoldMessenger.of(context);
    final testingSnackBar = messenger.showSnackBar(
      SnackBar(
        content: const Text('Testing connection...'),
        duration: const Duration(minutes: 2),
        action: SnackBarAction(
          label: 'Cancel',
          onPressed: cancellationToken.cancel,
        ),
      ),
    );

    try {
      final keyRepo = ref.read(keyRepositoryProvider);
      final sshService = ref.read(sshServiceProvider);

      SshKey? key;
      if (_selectedKeyId != null) {
        key = await keyRepo.getById(_selectedKeyId!);
      }

      SshConnectionConfig? jumpHostConfig;
      if (_selectedJumpHostId != null) {
        final jumpHost = await ref
            .read(hostRepositoryProvider)
            .getById(_selectedJumpHostId!);
        if (jumpHost != null) {
          SshKey? jumpKey;
          if (jumpHost.keyId != null) {
            jumpKey = await keyRepo.getById(jumpHost.keyId!);
          }
          jumpHostConfig = SshConnectionConfig.fromHost(jumpHost, key: jumpKey);
        }
      }

      final config = SshConnectionConfig(
        hostname: _hostnameController.text.trim(),
        port: int.parse(_portController.text),
        username: _usernameController.text.trim(),
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
        privateKey: key?.privateKey,
        passphrase: key?.passphrase,
        jumpHost: jumpHostConfig,
      );

      final SshConnectionResult result;
      try {
        result = await sshService.connect(
          config,
          cancellationToken: cancellationToken,
        );
      } finally {
        testingSnackBar.close();
      }
      if (!mounted) {
        // The screen went away mid-test; don't leak the established client.
        unawaited(result.closeAll());
        return;
      }

      if (result.cancelled) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Connection test cancelled')),
        );
        return;
      }

      if (!result.success || result.client == null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.error ??
                  'Connection test failed. Check the host, port, and credentials, then test again.',
            ),
          ),
        );
        return;
      }

      await result.closeAll();
      messenger.showSnackBar(
        const SnackBar(content: Text('Connection successful')),
      );
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'hosts',
          context: ErrorDescription('while testing a host connection'),
        ),
      );
      testingSnackBar.close();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Connection failed. Check the host settings and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _handleImportTransferTap() async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
      blockedAction: 'Import encrypted host file',
      blockedOutcome:
          'Unlock Pro to decrypt this host transfer and prefill the host form.',
    );
    if (!hasAccess) {
      return;
    }
    await _importFromTransfer();
  }

  Future<void> _importFromTransfer() async {
    final encodedPayload = await pickTransferPayloadFromFile(context);
    if (!mounted || encodedPayload == null) {
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Host transfer passphrase',
    );
    if (!mounted || transferPassphrase == null) {
      return;
    }

    try {
      final transferService = ref.read(secureTransferServiceProvider);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );
      if (payload.type != TransferPayloadType.host) {
        throw const FormatException(
          'This transfer payload does not contain a host',
        );
      }

      if (!mounted) {
        return;
      }
      final confirmed = await showTransferPayloadImportConfirmationDialog(
        context: context,
        payload: payload,
      );
      if (!mounted || !confirmed) {
        return;
      }
      final importedHost = await transferService.importHostPayload(payload);
      ref.invalidate(allHostsProvider);
      if (!mounted) {
        return;
      }
      _closeWithoutUnsavedPrompt(
        SnackBar(content: Text('Imported host: ${importedHost.label}')),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'hosts',
          context: ErrorDescription('while importing a host transfer'),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Import failed. Check the file and try again.'),
        ),
      );
    }
  }

  AgentLaunchPreset? _buildCurrentAgentLaunchPreset() =>
      buildCurrentAgentLaunchPreset(_currentDraft());

  void _handleAgentPresetFieldChanged() {
    setState(() {});
    _syncAutoConnectCommandFromPreset();
  }

  String? _validateAgentTmuxExtraFlags(String? value) =>
      validateAgentTmuxExtraFlags(value, _currentDraft());

  String? _tryBuildAgentLaunchCommand(
    AgentLaunchPreset? preset, {
    bool? startInYoloMode,
  }) {
    if (preset == null) {
      return null;
    }
    try {
      return buildAgentLaunchCommand(
        preset,
        startInYoloMode: startInYoloMode ?? _startClisInYoloMode,
      );
    } on FormatException {
      return null;
    }
  }

  void _syncAutoConnectCommandFromPreset() {
    final preset = _buildCurrentAgentLaunchPreset();
    if (preset == null) {
      return;
    }
    final command = _tryBuildAgentLaunchCommand(preset);
    if (command == null) {
      _autoConnectCommandController.clear();
      return;
    }
    _autoConnectCommandController.text = command;
  }

  Future<void> _selectTheme({required bool isLight}) async {
    final currentId = isLight ? _selectedLightThemeId : _selectedDarkThemeId;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );
    if (theme != null && mounted) {
      setState(() {
        if (isLight) {
          _selectedLightThemeId = theme.id;
        } else {
          _selectedDarkThemeId = theme.id;
        }
      });
      _updateDirtyState();
    }
  }

  Future<void> _handleThemeSelectionTap({required bool isLight}) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.hostSpecificThemes,
      blockedAction: 'Save theme overrides on this host',
      blockedOutcome: 'Unlock Pro to keep this host on its own terminal theme.',
    );
    if (!hasAccess || !mounted) {
      return;
    }
    await _selectTheme(isLight: isLight);
  }

  Future<void> _selectFont() async {
    final selected = await showFontPickerDialog(
      context: context,
      currentFontFamily: _selectedFontFamily,
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedFontFamily = selected;
      });
      _updateDirtyState();
    }
  }

  Widget _buildPortForwardsSection(BuildContext context, bool isEditing) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'Port Forwards',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (isEditing)
              TextButton.icon(
                onPressed: () => _showAddEditPortForwardDialog(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          key: const Key('host-auto-forward-ports-switch'),
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.radar_rounded),
          title: const Text('Detect open ports'),
          subtitle: const Text(
            'Automatically proxy new remote TCP listeners while connected',
          ),
          value: _autoForwardPorts,
          onChanged: (value) {
            setState(() => _autoForwardPorts = value);
            _updateDirtyState();
          },
        ),
        if (_autoForwardPorts) ...[
          const SizedBox(height: 8),
          KeyedSubtree(
            key: _portProxyNameFieldLocationKey,
            child: TextFormField(
              key: const Key('host-port-proxy-name-field'),
              controller: _portProxyNameController,
              focusNode: _portProxyNameFocusNode,
              decoration: const InputDecoration(
                labelText: 'Proxy domain (optional)',
                suffixText: '.localhost',
                prefixIcon: Icon(Icons.language_rounded),
                helperText:
                    'Leave blank to generate a unique name from the host label.',
                helperMaxLines: _hostFieldHelperMaxLines,
              ),
              autocorrect: false,
              style: FluttyTheme.monoStyle,
              validator: validatePortProxyName,
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (!isEditing)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Save the host first to add port forwards.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (_portForwards.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.swap_horiz,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No port forwards configured.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outline.withAlpha(80)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: _portForwards.asMap().entries.map((entry) {
                final index = entry.key;
                final pf = entry.value;
                final isLast = index == _portForwards.length - 1;

                return Column(
                  children: [
                    _PortForwardTile(
                      portForward: pf,
                      onEdit: () => _showAddEditPortForwardDialog(pf),
                      onDelete: () => _deletePortForward(pf),
                    ),
                    if (!isLast)
                      Divider(
                        height: 1,
                        color: colorScheme.outline.withAlpha(40),
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Future<void> _showAddEditPortForwardDialog(PortForward? existing) async {
    final result = await showHostPortForwardEditorSheet(
      context: context,
      hostId: widget.hostId!,
      existing: existing,
    );
    if (result == null || !mounted) {
      return;
    }

    final updated = await ref
        .read(portForwardRepositoryProvider)
        .getByHostId(widget.hostId!);
    if (mounted) {
      setState(() => _portForwards = updated);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    }
  }

  Future<void> _deletePortForward(PortForward pf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Port Forward'),
        content: Text('Are you sure you want to delete "${pf.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && mounted) {
      final repo = ref.read(portForwardRepositoryProvider);
      try {
        await stopPortForwardOnConnectedSessions(
          sessions: ref.read(activeSessionsProvider.notifier),
          portForward: pf,
        );
        await repo.delete(pf.id);
      } on Exception catch (error, stackTrace) {
        restorePortForwardAfterFailedDeletion(pf);
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'port forwards',
            context: ErrorDescription('while deleting a host port forward'),
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not delete port forward. Try again.'),
            ),
          );
        }
        return;
      }

      // Reload port forwards
      final updated = await repo.getByHostId(widget.hostId!);
      if (mounted) {
        setState(() => _portForwards = updated);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${pf.name}"')));
      }
    }
  }
}

class _ThemeSelectionTile extends StatelessWidget {
  const _ThemeSelectionTile({
    required this.label,
    required this.themeId,
    required this.themes,
    required this.defaultLabel,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final String? themeId;
  final Iterable<TerminalThemeData> themes;
  final String defaultLabel;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = themeId != null ? _findTheme(themes, themeId!) : null;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme?.background ?? colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outline),
        ),
        child: theme != null
            ? Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _colorDot(theme.red),
                    _colorDot(theme.green),
                    _colorDot(theme.blue),
                  ],
                ),
              )
            : Icon(
                Icons.palette_outlined,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
      ),
      title: Text(label),
      subtitle: Text(theme?.name ?? defaultLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (themeId != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: onClear,
              tooltip: 'Reset to default',
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _colorDot(Color color) => Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  TerminalThemeData? _findTheme(Iterable<TerminalThemeData> themes, String id) {
    for (final theme in themes) {
      if (theme.id == id) {
        return theme;
      }
    }
    return TerminalThemes.getById(id);
  }
}

class _FontSelectionTile extends StatelessWidget {
  const _FontSelectionTile({
    required this.fontFamily,
    required this.defaultLabel,
    required this.onTap,
    required this.onClear,
  });

  final String? fontFamily;
  final String defaultLabel;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayName = fontFamily ?? defaultLabel;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outline),
        ),
        child: Icon(
          Icons.font_download_outlined,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      title: const Text('Terminal Font'),
      subtitle: Text(displayName),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fontFamily != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: onClear,
              tooltip: 'Reset to default',
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A tile displaying a single port forward with edit/delete actions.
class _PortForwardTile extends StatelessWidget {
  const _PortForwardTile({
    required this.portForward,
    required this.onEdit,
    required this.onDelete,
  });

  /// The port forward to display.
  final PortForward portForward;

  /// Called when the edit button is tapped.
  final VoidCallback onEdit;

  /// Called when the delete button is tapped.
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.swap_horiz,
          color: colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        portForward.name,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${portForward.localPort} → '
        '${portForward.remoteHost}:${portForward.remotePort}',
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: onEdit,
            tooltip: 'Edit',
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 20,
              color: colorScheme.error,
            ),
            onPressed: onDelete,
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

class _SkipJumpHostOnWifiSection extends ConsumerStatefulWidget {
  const _SkipJumpHostOnWifiSection({
    required this.ssids,
    required this.onChanged,
  });

  final List<String> ssids;
  final ValueChanged<List<String>> onChanged;

  @override
  ConsumerState<_SkipJumpHostOnWifiSection> createState() =>
      _SkipJumpHostOnWifiSectionState();
}

class _SkipJumpHostOnWifiSectionState
    extends ConsumerState<_SkipJumpHostOnWifiSection> {
  bool _detecting = false;

  Future<void> _addCurrentSsid() async {
    setState(() => _detecting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final wifiService = ref.read(wifiNetworkServiceProvider);
      final permission = await wifiService.requestPermission();
      if (!mounted) return;
      if (permission != WifiPermissionStatus.granted) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Location permission is required to read the current Wi-Fi '
              'network name. You can also add the SSID manually.',
            ),
            action: permission == WifiPermissionStatus.permanentlyDenied
                ? SnackBarAction(
                    label: 'Settings',
                    onPressed: () => unawaited(openAppSettings()),
                  )
                : null,
          ),
        );
        return;
      }
      final ssid = await wifiService.getCurrentSsid();
      if (!mounted) return;
      if (ssid == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Could not detect the current Wi-Fi network. Make sure you '
              'are connected to Wi-Fi and try again, or add the SSID '
              'manually.',
            ),
          ),
        );
        return;
      }
      _addSsid(ssid);
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _promptForSsid() async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Wi-Fi network'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'SSID',
            hintText: 'Network name',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (entered != null && entered.isNotEmpty) {
      _addSsid(entered);
    }
  }

  void _addSsid(String ssid) {
    final sanitized = sanitizeSsidInput(ssid);
    if (sanitized.isEmpty) return;
    if (widget.ssids.contains(sanitized)) return;
    widget.onChanged([...widget.ssids, sanitized]);
  }

  void _removeSsid(String ssid) {
    widget.onChanged(widget.ssids.where((s) => s != ssid).toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.wifi_off, size: 20, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Skip jump host on Wi-Fi',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Connect directly (no jump host) when on these Wi-Fi networks. '
          'Applies on connect and reconnect.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.ssids.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'No networks added. The jump host will always be used.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final ssid in widget.ssids)
                InputChip(
                  key: ValueKey('skip-jump-ssid-$ssid'),
                  label: Text(ssid.isEmpty ? '(unnamed)' : ssid),
                  avatar: const Icon(Icons.wifi, size: 18),
                  onDeleted: () => _removeSsid(ssid),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (WifiNetworkService.isSupported)
              OutlinedButton.icon(
                key: const Key('skip-jump-add-current-ssid'),
                onPressed: _detecting ? null : _addCurrentSsid,
                icon: _detecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location, size: 18),
                label: const Text('Add current Wi-Fi'),
              ),
            OutlinedButton.icon(
              key: const Key('skip-jump-add-manual-ssid'),
              onPressed: _promptForSsid,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add manually'),
            ),
          ],
        ),
      ],
    );
  }
}
