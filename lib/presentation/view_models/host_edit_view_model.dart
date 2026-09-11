import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/commands/save_host_command.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/host_cli_launch_preferences.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../providers/entity_list_providers.dart';

/// Host startup behavior selected in the edit form.
enum HostStartupMode {
  /// Do nothing after the SSH connection opens.
  none,

  /// Legacy automatic remote-window backend selection.
  muxAuto,

  /// Open or attach to a MonkeyMux session after connecting.
  monkeyMux,

  /// Open or attach to a tmux session after connecting.
  tmux,

  /// Launch a supported coding agent after connecting.
  agent,

  /// Run a custom shell command after connecting.
  customCommand,

  /// Run a saved snippet after connecting.
  snippet,
}

/// Presentation helpers for [HostStartupMode].
extension HostStartupModePresentation on HostStartupMode {
  /// Human-readable label used in the startup mode dropdown.
  String get label => switch (this) {
    HostStartupMode.none => 'Do nothing',
    HostStartupMode.muxAuto => 'Automatic windows',
    HostStartupMode.monkeyMux => 'MonkeyMux',
    HostStartupMode.tmux => 'tmux',
    HostStartupMode.agent => 'Launch coding agent',
    HostStartupMode.customCommand => 'Run custom command',
    HostStartupMode.snippet => 'Run saved snippet',
  };

  /// Whether this mode opens a persistent remote window session.
  bool get usesRemoteMultiplexer => switch (this) {
    HostStartupMode.muxAuto ||
    HostStartupMode.monkeyMux ||
    HostStartupMode.tmux => true,
    _ => false,
  };

  /// Backend value persisted for remote-window startup modes.
  RemoteMuxBackend? get remoteMuxBackend => switch (this) {
    HostStartupMode.muxAuto => RemoteMuxBackend.auto,
    HostStartupMode.monkeyMux => RemoteMuxBackend.monkeyMux,
    HostStartupMode.tmux => RemoteMuxBackend.tmux,
    _ => null,
  };
}

final _tmuxDisableStatusBarPattern = RegExp(
  r'(^|\s)\\;\s*set\s+status\s+off(?=\s|$)',
);

/// Whether [extraFlags] already includes MonkeySSH's tmux status-bar toggle.
bool hasTmuxDisableStatusBarCommand(String? extraFlags) {
  final normalized = extraFlags?.trim();
  if (normalized == null || normalized.isEmpty) {
    return false;
  }
  return _tmuxDisableStatusBarPattern.hasMatch(normalized);
}

/// Removes MonkeySSH's tmux status-bar toggle from [extraFlags] for editing.
String stripTmuxDisableStatusBarCommand(String? extraFlags) {
  final normalized = extraFlags?.trim();
  if (normalized == null || normalized.isEmpty) {
    return '';
  }
  return normalized
      .replaceAll(_tmuxDisableStatusBarPattern, ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}

/// Resolves tmux flags to persist from the visible text field and checkbox.
String? resolveTmuxExtraFlags({
  required String extraFlags,
  required bool disableStatusBar,
}) {
  final normalized = extraFlags.trim();
  if (!disableStatusBar) {
    return normalized.isEmpty ? null : normalized;
  }
  if (normalized.isEmpty) {
    return tmuxDisableStatusBarCommand;
  }
  if (hasTmuxDisableStatusBarCommand(normalized)) {
    return normalized;
  }
  return '$normalized $tmuxDisableStatusBarCommand';
}

/// Snapshot of all draft values owned by the host edit form.
typedef HostEditDraft = ({
  String label,
  String hostname,
  String port,
  String username,
  String password,
  String tags,
  String autoConnectCommand,
  String tmuxSession,
  String tmuxWorkingDirectory,
  String tmuxExtraFlags,
  String agentWorkingDirectory,
  String agentTmuxSession,
  String agentTmuxExtraFlags,
  String agentArguments,
  String portProxyName,
  RemoteMuxBackend selectedAgentMuxBackend,
  int? selectedKeyId,
  int? selectedGroupId,
  int? selectedJumpHostId,
  String? skipJumpHostOnSsids,
  int? selectedAutoConnectSnippetId,
  String? selectedLightThemeId,
  String? selectedDarkThemeId,
  String? selectedFontFamily,
  HostStartupMode selectedStartupMode,
  AutoConnectCommandMode selectedAutoConnectMode,
  AgentLaunchTool selectedAgentLaunchTool,
  bool isFavorite,
  bool disableTmuxStatusBar,
  bool disableAgentTmuxStatusBar,
  bool startClisInYoloMode,
  AgentWindowModePreference agentWindowModePreference,
  bool autoForwardPorts,
});

/// Logical validation targets the UI can scroll to and focus.
enum HostEditValidationTarget {
  /// Host label field.
  label,

  /// Hostname field.
  hostname,

  /// Port field.
  port,

  /// Username field.
  username,

  /// Optional automatic-forwarding proxy name field.
  portProxyName,

  /// tmux session field.
  tmuxSession,

  /// Agent tmux flags field.
  agentTmuxFlags,

  /// Custom startup command field.
  customCommand,

  /// Saved snippet selector.
  snippet,
}

/// Validation issue for a host edit draft.
class HostEditValidationIssue {
  /// Creates a [HostEditValidationIssue].
  const HostEditValidationIssue({required this.target, required this.message});

  /// UI field that should receive focus.
  final HostEditValidationTarget target;

  /// Snackbar summary for the validation issue.
  final String message;
}

/// Loaded host edit data from repositories and host-scoped services.
class HostEditLoadResult {
  /// Creates a [HostEditLoadResult].
  const HostEditLoadResult({
    required this.host,
    required this.portForwards,
    required this.preset,
    required this.cliLaunchPreferences,
  });

  /// Host being edited.
  final Host host;

  /// Existing port forwards for the host.
  final List<PortForward> portForwards;

  /// Saved coding-agent launch preset, if any.
  final AgentLaunchPreset? preset;

  /// Saved coding CLI launch preferences.
  final HostCliLaunchPreferences cliLaunchPreferences;
}

/// Immutable state owned by [HostEditViewModel].
class HostEditState {
  /// Creates a [HostEditState].
  const HostEditState({
    this.isLoading = false,
    this.existingHost,
    this.portForwards = const [],
    this.cliLaunchPreferences = const HostCliLaunchPreferences(),
    this.initialDraft,
    this.isDirty = false,
  });

  /// Whether the screen is loading or saving.
  final bool isLoading;

  /// Host being edited, or null for create mode.
  final Host? existingHost;

  /// Existing port forwards for the host.
  final List<PortForward> portForwards;

  /// Saved host-scoped coding CLI launch preferences.
  final HostCliLaunchPreferences cliLaunchPreferences;

  /// Baseline draft used by the unsaved-changes guard.
  final HostEditDraft? initialDraft;

  /// Whether the current draft differs from [initialDraft].
  final bool isDirty;

  /// Returns a copy with selected fields replaced.
  HostEditState copyWith({
    bool? isLoading,
    Object? existingHost = _sentinel,
    List<PortForward>? portForwards,
    HostCliLaunchPreferences? cliLaunchPreferences,
    Object? initialDraft = _sentinel,
    bool? isDirty,
  }) => HostEditState(
    isLoading: isLoading ?? this.isLoading,
    existingHost: identical(existingHost, _sentinel)
        ? this.existingHost
        : existingHost as Host?,
    portForwards: portForwards ?? this.portForwards,
    cliLaunchPreferences: cliLaunchPreferences ?? this.cliLaunchPreferences,
    initialDraft: identical(initialDraft, _sentinel)
        ? this.initialDraft
        : initialDraft as HostEditDraft?,
    isDirty: isDirty ?? this.isDirty,
  );
}

const _sentinel = Object();

/// Parameters for saving a host edit draft.
class HostEditSaveRequest {
  /// Creates a [HostEditSaveRequest].
  const HostEditSaveRequest({
    required this.draft,
    required this.hasAutomationAccess,
    required this.hasAgentPresetAccess,
  });

  /// Current form draft.
  final HostEditDraft draft;

  /// Whether the user can save auto-connect automation fields.
  final bool hasAutomationAccess;

  /// Whether the user can save coding-agent preset fields.
  final bool hasAgentPresetAccess;
}

/// View-model boundary for host edit load, validation, dirty state, and saving.
class HostEditViewModel extends Notifier<HostEditState> {
  /// Creates a [HostEditViewModel] for [hostId].
  HostEditViewModel(this.hostId);

  /// The host ID being edited, or null for create mode.
  final int? hostId;

  @override
  HostEditState build() => HostEditState(isLoading: hostId != null);

  /// Loads the host edit dependencies for [arg].
  Future<HostEditLoadResult?> loadHost() async {
    final editingHostId = hostId;
    if (editingHostId == null) {
      return null;
    }

    state = state.copyWith(isLoading: true);
    final host = await ref.read(hostRepositoryProvider).getById(editingHostId);
    if (!ref.mounted) return null;
    if (host == null) {
      state = state.copyWith(isLoading: false, existingHost: null);
      return null;
    }

    final portForwards = await ref
        .read(portForwardRepositoryProvider)
        .getByHostId(host.id);
    if (!ref.mounted) return null;
    final preset = await ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(host.id);
    if (!ref.mounted) return null;
    final cliLaunchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(host.id);
    if (!ref.mounted) return null;

    state = state.copyWith(
      isLoading: false,
      existingHost: host,
      portForwards: portForwards,
      cliLaunchPreferences: cliLaunchPreferences,
    );
    return HostEditLoadResult(
      host: host,
      portForwards: portForwards,
      preset: preset,
      cliLaunchPreferences: cliLaunchPreferences,
    );
  }

  /// Resets dirty tracking to [draft].
  void markInitialDraft(HostEditDraft draft) {
    state = state.copyWith(initialDraft: draft, isDirty: false);
  }

  /// Updates dirty tracking from [draft] and returns the new dirty value.
  bool updateDraft(HostEditDraft draft) {
    final initialDraft = state.initialDraft;
    final isDirty = initialDraft != null && draft != initialDraft;
    if (state.isDirty != isDirty) {
      state = state.copyWith(isDirty: isDirty);
    }
    return isDirty;
  }

  /// Returns the first validation issue for [draft], if any.
  HostEditValidationIssue? validateDraft(HostEditDraft draft) {
    if (draft.label.isEmpty) {
      return const HostEditValidationIssue(
        target: HostEditValidationTarget.label,
        message: 'Fix label to save this host',
      );
    }
    if (draft.hostname.isEmpty) {
      return const HostEditValidationIssue(
        target: HostEditValidationTarget.hostname,
        message: 'Fix hostname to save this host',
      );
    }

    final port = int.tryParse(draft.port);
    if (draft.port.isEmpty || port == null || port < 1 || port > 65535) {
      return const HostEditValidationIssue(
        target: HostEditValidationTarget.port,
        message: 'Fix port to save this host',
      );
    }
    if (draft.username.isEmpty) {
      return const HostEditValidationIssue(
        target: HostEditValidationTarget.username,
        message: 'Fix username to save this host',
      );
    }
    if (draft.autoForwardPorts &&
        validatePortProxyName(draft.portProxyName) != null) {
      return const HostEditValidationIssue(
        target: HostEditValidationTarget.portProxyName,
        message: 'Fix proxy domain to save this host',
      );
    }

    switch (draft.selectedStartupMode) {
      case HostStartupMode.none:
        return null;
      case HostStartupMode.muxAuto:
      case HostStartupMode.monkeyMux:
      case HostStartupMode.tmux:
        if (draft.tmuxSession.trim().isEmpty) {
          return HostEditValidationIssue(
            target: HostEditValidationTarget.tmuxSession,
            message: draft.selectedStartupMode == HostStartupMode.tmux
                ? 'Fix tmux session name to save this host'
                : 'Fix MonkeyMux session name to save this host',
          );
        }
        return null;
      case HostStartupMode.agent:
        if (validateAgentTmuxExtraFlags(draft.agentTmuxExtraFlags, draft) !=
            null) {
          return const HostEditValidationIssue(
            target: HostEditValidationTarget.agentTmuxFlags,
            message: 'Fix agent tmux flags to save this host',
          );
        }
        return null;
      case HostStartupMode.customCommand:
        if (draft.autoConnectCommand.trim().isEmpty) {
          return const HostEditValidationIssue(
            target: HostEditValidationTarget.customCommand,
            message: 'Fix custom command to save this host',
          );
        }
        return null;
      case HostStartupMode.snippet:
        if (draft.selectedAutoConnectSnippetId == null) {
          return const HostEditValidationIssue(
            target: HostEditValidationTarget.snippet,
            message: 'Choose a startup snippet to save this host',
          );
        }
        return null;
    }
  }

  /// Persists [request] using [SaveHostCommand].
  Future<int> save(HostEditSaveRequest request) async {
    state = state.copyWith(isLoading: true);
    try {
      final input = await _buildSaveInput(
        draft: request.draft,
        hasAutomationAccess: request.hasAutomationAccess,
      );

      final savedHostId = await ref
          .read(saveHostCommandProvider)
          .execute(
            input: input,
            existingHostId: hostId,
            existingHost: state.existingHost,
            presetAction: _buildPresetAction(
              draft: request.draft,
              hasAutomationAccess: request.hasAutomationAccess,
              hasAgentPresetAccess: request.hasAgentPresetAccess,
            ),
            cliPreferences: HostCliLaunchPreferences(
              startInYoloMode: request.hasAgentPresetAccess
                  ? request.draft.startClisInYoloMode
                  : state.cliLaunchPreferences.startInYoloMode,
            ),
          );

      ref.invalidate(allHostsProvider);
      state = state.copyWith(
        isLoading: false,
        initialDraft: request.draft,
        isDirty: false,
      );
      return savedHostId;
    } on Exception {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<SaveHostInput> _buildSaveInput({
    required HostEditDraft draft,
    required bool hasAutomationAccess,
  }) async {
    final existingHost = state.existingHost;
    final port = int.parse(draft.port);
    final password = draft.password.isEmpty ? null : draft.password;
    final tags = draft.tags.trim().isEmpty ? null : draft.tags.trim();
    final portProxyName =
        !draft.autoForwardPorts || draft.portProxyName.trim().isEmpty
        ? null
        : normalizePortProxyName(draft.portProxyName);

    final autoConnectSnippetId =
        draft.selectedAutoConnectMode == AutoConnectCommandMode.snippet
        ? draft.selectedAutoConnectSnippetId
        : null;
    final selectedSnippet = autoConnectSnippetId == null
        ? null
        : await ref
              .read(snippetRepositoryProvider)
              .getById(autoConnectSnippetId);

    final currentPreset = buildCurrentAgentLaunchPreset(draft);
    final presetCommand = currentPreset == null
        ? null
        : buildAgentLaunchCommand(
            currentPreset,
            startInYoloMode: draft.startClisInYoloMode,
          );

    final tmuxSessionName = draft.tmuxSession.trim();
    final tmuxWorkingDirectory = draft.tmuxWorkingDirectory.trim();
    final tmuxExtraFlags = draft.tmuxExtraFlags.trim();

    final startupMode = draft.selectedStartupMode;
    final usesRemoteMultiplexer = startupMode.usesRemoteMultiplexer;
    // Without automation access, an automation startup mode (agent, custom
    // command, or snippet) cannot be edited, so the stored automation and
    // legacy remote-window fields are carried over unchanged rather than
    // cleared or rebuilt from the read-only form.
    final preservesExistingAutomation =
        !hasAutomationAccess &&
        !usesRemoteMultiplexer &&
        startupMode != HostStartupMode.none;
    final preservedHost = preservesExistingAutomation ? existingHost : null;

    final normalizedTmuxSessionName = usesRemoteMultiplexer
        ? (tmuxSessionName.isEmpty ? null : tmuxSessionName)
        : preservedHost?.tmuxSessionName;
    final normalizedRemoteMuxBackend = usesRemoteMultiplexer
        ? startupMode.remoteMuxBackend
        : RemoteMuxBackendPresentation.fromStorageValue(
            preservedHost?.remoteMuxBackend,
          );
    final normalizedTmuxWorkingDirectory = usesRemoteMultiplexer
        ? (tmuxWorkingDirectory.isEmpty ? null : tmuxWorkingDirectory)
        : preservedHost?.tmuxWorkingDirectory;
    final normalizedTmuxExtraFlags = startupMode == HostStartupMode.tmux
        ? resolveTmuxExtraFlags(
            extraFlags: tmuxExtraFlags,
            disableStatusBar: draft.disableTmuxStatusBar,
          )
        : preservedHost?.tmuxExtraFlags;

    final String? normalizedAutoConnectCommand;
    final int? normalizedAutoConnectSnippetId;
    if (preservesExistingAutomation) {
      normalizedAutoConnectCommand = existingHost?.autoConnectCommand;
      normalizedAutoConnectSnippetId = existingHost?.autoConnectSnippetId;
    } else {
      final customCommand = draft.autoConnectCommand.trim();
      (
        normalizedAutoConnectCommand,
        normalizedAutoConnectSnippetId,
      ) = switch (startupMode) {
        HostStartupMode.agent => (
          presetCommand == null || presetCommand.trim().isEmpty
              ? null
              : presetCommand,
          null,
        ),
        HostStartupMode.customCommand => (
          customCommand.isEmpty ? null : customCommand,
          null,
        ),
        HostStartupMode.snippet => (
          selectedSnippet?.command ?? draft.autoConnectCommand,
          selectedSnippet?.id,
        ),
        _ => (null, null),
      };
    }
    final autoConnectRequiresConfirmation = _resolveAutoConnectConfirmation(
      command: normalizedAutoConnectCommand,
      snippetId: normalizedAutoConnectSnippetId,
    );

    return SaveHostInput(
      label: draft.label,
      hostname: draft.hostname,
      port: port,
      username: draft.username,
      password: password,
      tags: tags,
      keyId: draft.selectedKeyId,
      groupId: draft.selectedGroupId,
      jumpHostId: draft.selectedJumpHostId,
      skipJumpHostOnSsids: draft.selectedJumpHostId == null
          ? null
          : draft.skipJumpHostOnSsids,
      terminalThemeLightId: draft.selectedLightThemeId,
      terminalThemeDarkId: draft.selectedDarkThemeId,
      terminalFontFamily: draft.selectedFontFamily,
      autoConnectCommand: normalizedAutoConnectCommand,
      autoConnectSnippetId: normalizedAutoConnectSnippetId,
      autoConnectRequiresConfirmation: autoConnectRequiresConfirmation,
      tmuxSessionName: normalizedTmuxSessionName,
      tmuxWorkingDirectory: normalizedTmuxWorkingDirectory,
      tmuxExtraFlags: normalizedTmuxExtraFlags,
      remoteMuxBackend: normalizedRemoteMuxBackend,
      autoForwardPorts: draft.autoForwardPorts,
      portProxyName: portProxyName,
      isFavorite: draft.isFavorite,
    );
  }

  AgentPresetAction _buildPresetAction({
    required HostEditDraft draft,
    required bool hasAutomationAccess,
    required bool hasAgentPresetAccess,
  }) {
    // A non-agent startup form may hide an unsupported saved preset. Do not
    // delete persisted data when the user only edits host metadata.
    final initial = state.initialDraft;
    if (initial != null &&
        initial.selectedStartupMode != HostStartupMode.agent &&
        (
              initial.selectedStartupMode,
              initial.selectedAutoConnectMode,
              initial.autoConnectCommand,
              initial.selectedAutoConnectSnippetId,
              initial.tmuxSession,
              initial.tmuxWorkingDirectory,
              initial.tmuxExtraFlags,
              initial.disableTmuxStatusBar,
            ) ==
            (
              draft.selectedStartupMode,
              draft.selectedAutoConnectMode,
              draft.autoConnectCommand,
              draft.selectedAutoConnectSnippetId,
              draft.tmuxSession,
              draft.tmuxWorkingDirectory,
              draft.tmuxExtraFlags,
              draft.disableTmuxStatusBar,
            )) {
      return const LeaveAgentPresetUnchanged();
    }
    final canEditPreset = hasAutomationAccess && hasAgentPresetAccess;
    // Non-null only in agent mode.
    final preset = buildCurrentAgentLaunchPreset(draft);
    if (preset != null) {
      return canEditPreset
          ? SaveAgentPreset(preset)
          : const LeaveAgentPresetUnchanged();
    }
    final startupMode = draft.selectedStartupMode;
    if (startupMode == HostStartupMode.none ||
        startupMode.usesRemoteMultiplexer ||
        canEditPreset) {
      return const DeleteAgentPreset();
    }
    return const LeaveAgentPresetUnchanged();
  }

  bool _resolveAutoConnectConfirmation({
    required String? command,
    required int? snippetId,
  }) {
    final existingHost = state.existingHost;
    if (existingHost == null || !existingHost.autoConnectRequiresConfirmation) {
      return false;
    }

    final previousMode = resolveAutoConnectCommandMode(
      command: existingHost.autoConnectCommand,
      snippetId: existingHost.autoConnectSnippetId,
    );
    final nextMode = resolveAutoConnectCommandMode(
      command: command,
      snippetId: snippetId,
    );
    if (nextMode != previousMode) {
      return false;
    }

    return switch (nextMode) {
      AutoConnectCommandMode.none => false,
      AutoConnectCommandMode.custom =>
        existingHost.autoConnectCommand == command,
      AutoConnectCommandMode.snippet =>
        existingHost.autoConnectSnippetId == snippetId,
    };
  }
}

/// Builds the current agent-launch preset from [draft], if agent mode is active.
AgentLaunchPreset? buildCurrentAgentLaunchPreset(HostEditDraft draft) {
  if (draft.selectedStartupMode != HostStartupMode.agent) {
    return null;
  }
  return AgentLaunchPreset(
    tool: draft.selectedAgentLaunchTool,
    workingDirectory: draft.agentWorkingDirectory.trim(),
    tmuxSessionName: draft.agentTmuxSession.trim(),
    remoteMuxBackend: draft.selectedAgentMuxBackend,
    tmuxExtraFlags: draft.agentTmuxExtraFlags.trim(),
    tmuxDisableStatusBar: draft.disableAgentTmuxStatusBar,
    additionalArguments: draft.agentArguments.trim(),
  );
}

/// Validates agent tmux flags for [draft].
String? validateAgentTmuxExtraFlags(String? value, HostEditDraft draft) {
  if (draft.selectedAgentMuxBackend != RemoteMuxBackend.tmux) {
    return null;
  }
  if (draft.agentTmuxSession.trim().isEmpty) {
    return null;
  }
  try {
    buildAgentLaunchCommand(
      AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        tmuxSessionName: 'preview',
        tmuxExtraFlags: value,
      ),
    );
    return null;
  } on FormatException catch (error) {
    return error.message;
  }
}

/// Provider for [HostEditViewModel].
final hostEditViewModelProvider = NotifierProvider.autoDispose
    .family<HostEditViewModel, HostEditState, int?>(HostEditViewModel.new);
