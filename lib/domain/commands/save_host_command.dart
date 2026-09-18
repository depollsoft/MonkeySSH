import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../models/agent_launch_preset.dart';
import '../models/host_cli_launch_preferences.dart';
import '../models/remote_multiplexer.dart';
import '../services/agent_launch_preset_service.dart';
import '../services/host_cli_launch_preferences_service.dart';

/// Fully-resolved parameters for persisting a host.
///
/// All values are typed primitives—no Drift companions, no form controllers.
/// The caller (e.g. [HostEditScreen]) is responsible for resolving form state
/// into this struct before calling [SaveHostCommand.execute].
class SaveHostInput {
  /// Creates a new [SaveHostInput].
  const SaveHostInput({
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    required this.autoConnectRequiresConfirmation,
    required this.isFavorite,
    this.autoForwardPorts = false,
    this.password,
    this.tags,
    this.keyId,
    this.groupId,
    this.jumpHostId,
    this.skipJumpHostOnSsids,
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
    this.terminalFontFamily,
    this.autoConnectCommand,
    this.autoConnectSnippetId,
    this.tmuxSessionName,
    this.tmuxWorkingDirectory,
    this.tmuxExtraFlags,
    this.remoteMuxBackend,
    this.portProxyName,
  });

  /// Display label.
  final String label;

  /// Hostname or IP address.
  final String hostname;

  /// SSH port.
  final int port;

  /// SSH username.
  final String username;

  /// Optional plaintext password (repository handles encryption).
  final String? password;

  /// Optional comma-separated tags.
  final String? tags;

  /// Optional SSH key reference.
  final int? keyId;

  /// Optional group reference.
  final int? groupId;

  /// Optional jump-host reference.
  final int? jumpHostId;

  /// Newline-separated SSIDs on which the jump host should be skipped.
  final String? skipJumpHostOnSsids;

  /// Terminal theme ID override for light mode.
  final String? terminalThemeLightId;

  /// Terminal theme ID override for dark mode.
  final String? terminalThemeDarkId;

  /// Terminal font family override.
  final String? terminalFontFamily;

  /// Auto-connect shell command.
  final String? autoConnectCommand;

  /// Auto-connect snippet reference.
  final int? autoConnectSnippetId;

  /// Whether the auto-connect command requires user confirmation.
  final bool autoConnectRequiresConfirmation;

  /// tmux session name for the startup flow.
  final String? tmuxSessionName;

  /// Working directory for the tmux session.
  final String? tmuxWorkingDirectory;

  /// Extra flags for the `tmux new-session` invocation.
  final String? tmuxExtraFlags;

  /// Remote multiplexer backend to use with [tmuxSessionName].
  final RemoteMuxBackend? remoteMuxBackend;

  /// Whether remote TCP listeners should be forwarded automatically.
  final bool autoForwardPorts;

  /// Optional custom prefix for this host's `.localhost` proxy domain.
  final String? portProxyName;

  /// Whether this host is marked as a favourite.
  final bool isFavorite;
}

// ---------------------------------------------------------------------------
// Agent-preset action
// ---------------------------------------------------------------------------

/// Describes what [SaveHostCommand] should do with the stored agent preset.
sealed class AgentPresetAction {
  const AgentPresetAction();
}

/// Save [preset] for the host.
final class SaveAgentPreset extends AgentPresetAction {
  /// Creates a [SaveAgentPreset] action.
  const SaveAgentPreset(this.preset);

  /// The preset to persist.
  final AgentLaunchPreset preset;
}

/// Delete any previously-stored preset for the host.
final class DeleteAgentPreset extends AgentPresetAction {
  /// Creates a [DeleteAgentPreset] action.
  const DeleteAgentPreset();
}

/// Leave the stored preset unchanged (e.g. Pro is not active).
final class LeaveAgentPresetUnchanged extends AgentPresetAction {
  /// Creates a [LeaveAgentPresetUnchanged] action.
  const LeaveAgentPresetUnchanged();
}

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------

/// Orchestrates the transactional persistence of a host and its associated
/// settings (agent preset, CLI launch preferences).
///
/// All database writes—including the settings rows managed by
/// [AgentLaunchPresetService] and [HostCliLaunchPreferencesService]—execute
/// inside a single Drift transaction so that a failure at any step rolls back
/// the entire operation.
class SaveHostCommand {
  /// Creates a [SaveHostCommand].
  SaveHostCommand({
    required AppDatabase db,
    required HostRepository hostRepository,
    required AgentLaunchPresetService presetService,
    required HostCliLaunchPreferencesService cliPreferencesService,
  }) : _db = db,
       _hostRepository = hostRepository,
       _presetService = presetService,
       _cliPreferencesService = cliPreferencesService;

  final AppDatabase _db;
  final HostRepository _hostRepository;
  final AgentLaunchPresetService _presetService;
  final HostCliLaunchPreferencesService _cliPreferencesService;

  /// Persists the host described by [input].
  ///
  /// Pass [existingHostId] and [existingHost] when updating an existing record;
  /// leave both null to insert a new host.
  ///
  /// [presetAction] controls whether the agent preset is saved, deleted, or
  /// left as-is.  [cliPreferences] non-null overwrites the stored CLI
  /// preferences; null leaves them unchanged.
  ///
  /// Returns the saved host ID.
  ///
  /// Throws on any persistence error; the caller should catch and show an
  /// appropriate error UI.
  Future<int> execute({
    required SaveHostInput input,
    int? existingHostId,
    Host? existingHost,
    AgentPresetAction presetAction = const LeaveAgentPresetUnchanged(),
    HostCliLaunchPreferences? cliPreferences,
  }) => _db.transaction(() async {
    final int savedHostId;

    if (existingHostId != null && existingHost != null) {
      await _hostRepository.validateProxyName(
        hostId: existingHostId,
        label: input.label,
        customName: input.portProxyName,
      );
      await _hostRepository.update(
        existingHost.copyWith(
          label: input.label,
          hostname: input.hostname,
          port: input.port,
          username: input.username,
          password: drift.Value(input.password),
          tags: drift.Value(input.tags),
          keyId: drift.Value(input.keyId),
          groupId: drift.Value(input.groupId),
          jumpHostId: drift.Value(input.jumpHostId),
          skipJumpHostOnSsids: drift.Value(input.skipJumpHostOnSsids),
          terminalThemeLightId: drift.Value(input.terminalThemeLightId),
          terminalThemeDarkId: drift.Value(input.terminalThemeDarkId),
          terminalFontFamily: drift.Value(input.terminalFontFamily),
          autoConnectCommand: drift.Value(input.autoConnectCommand),
          autoConnectSnippetId: drift.Value(input.autoConnectSnippetId),
          autoConnectRequiresConfirmation:
              input.autoConnectRequiresConfirmation,
          tmuxSessionName: drift.Value(input.tmuxSessionName),
          tmuxWorkingDirectory: drift.Value(input.tmuxWorkingDirectory),
          tmuxExtraFlags: drift.Value(input.tmuxExtraFlags),
          remoteMuxBackend: drift.Value(input.remoteMuxBackend?.storageValue),
          autoForwardPorts: input.autoForwardPorts,
          portProxyName: drift.Value(input.portProxyName),
          isFavorite: input.isFavorite,
        ),
      );
      savedHostId = existingHostId;
    } else {
      savedHostId = await _hostRepository.insert(
        HostsCompanion.insert(
          label: input.label,
          hostname: input.hostname,
          port: drift.Value(input.port),
          username: input.username,
          password: drift.Value(input.password),
          tags: drift.Value(input.tags),
          keyId: drift.Value(input.keyId),
          groupId: drift.Value(input.groupId),
          jumpHostId: drift.Value(input.jumpHostId),
          skipJumpHostOnSsids: drift.Value(input.skipJumpHostOnSsids),
          terminalThemeLightId: drift.Value(input.terminalThemeLightId),
          terminalThemeDarkId: drift.Value(input.terminalThemeDarkId),
          terminalFontFamily: drift.Value(input.terminalFontFamily),
          autoConnectCommand: drift.Value(input.autoConnectCommand),
          autoConnectSnippetId: drift.Value(input.autoConnectSnippetId),
          autoConnectRequiresConfirmation: drift.Value(
            input.autoConnectRequiresConfirmation,
          ),
          tmuxSessionName: drift.Value(input.tmuxSessionName),
          tmuxWorkingDirectory: drift.Value(input.tmuxWorkingDirectory),
          tmuxExtraFlags: drift.Value(input.tmuxExtraFlags),
          remoteMuxBackend: drift.Value(input.remoteMuxBackend?.storageValue),
          autoForwardPorts: drift.Value(input.autoForwardPorts),
          portProxyName: drift.Value(input.portProxyName),
          isFavorite: drift.Value(input.isFavorite),
        ),
      );
    }

    // Handle agent preset.
    switch (presetAction) {
      case SaveAgentPreset(:final preset):
        await _presetService.setPresetForHost(savedHostId, preset);
      case DeleteAgentPreset():
        await _presetService.deletePresetForHost(savedHostId);
      case LeaveAgentPresetUnchanged():
        break;
    }

    // Handle CLI preferences.
    if (cliPreferences != null) {
      await _cliPreferencesService.setPreferencesForHost(
        savedHostId,
        cliPreferences,
      );
    }

    return savedHostId;
  });
}

/// Provider for [SaveHostCommand].
final saveHostCommandProvider = Provider<SaveHostCommand>(
  (ref) => SaveHostCommand(
    db: ref.watch(databaseProvider),
    hostRepository: ref.watch(hostRepositoryProvider),
    presetService: ref.watch(agentLaunchPresetServiceProvider),
    cliPreferencesService: ref.watch(hostCliLaunchPreferencesServiceProvider),
  ),
);
