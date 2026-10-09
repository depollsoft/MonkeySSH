import 'package:collection/collection.dart';

import '../data/database/database.dart';
import '../data/repositories/host_repository.dart';
import '../domain/models/acp_recent_session.dart';
import '../domain/models/agent_launch_preset.dart';
import '../domain/models/app_link.dart';
import '../domain/services/acp_recent_sessions_service.dart';
import '../domain/services/agent_launch_preset_service.dart';
import '../domain/services/diagnostics_log_service.dart';
import '../domain/services/host_cli_launch_preferences_service.dart';
import '../domain/services/local_notification_service.dart';
import '../presentation/widgets/app_link_preset_sheet.dart';

/// Terminal route query key marking a terminal opened by an app link.
///
/// Its value is a per-tap id, so opening the same link twice builds a fresh
/// screen. A terminal opened this way shows its host's auto-connect command
/// for review instead of running it, and reports a missing target window.
const appLinkTapQueryKey = 'linkTap';

/// User-facing messages for links MonkeySSH cannot act on.
abstract final class AppLinkMessages {
  /// The link is malformed or names an action MonkeySSH does not know.
  static const invalid = "MonkeySSH can't open that link.";

  /// The link embeds a password.
  static const embeddedCredentials =
      "Links with a password in them aren't accepted. Add the host and "
      'enter credentials in MonkeySSH instead.';

  /// The link's host id is not saved on this device.
  static const hostMissing = "That link's host isn't saved on this device.";

  /// The link's agent chat is not known on this device.
  static const chatMissing =
      "That agent chat isn't available on this device anymore.";

  /// The link's launch preset is not saved, or cannot run, on this device.
  static const presetMissing =
      "That launch preset isn't saved on this device anymore.";
}

/// How a link was resolved. Names are safe to log.
enum AppLinkOutcome {
  /// The link was refused before any lookup.
  rejected,

  /// The link's host or terminal target was opened.
  opened,

  /// The link's host is not saved on this device.
  hostMissing,

  /// The link's chat is not known on this device.
  chatMissing,

  /// The link's preset is not saved or cannot run.
  presetMissing,

  /// The user cancelled the preset review.
  presetDeclined,

  /// The user confirmed the preset review and it was launched.
  presetLaunched,

  /// An `ssh://` link opened the reviewed add-host form.
  hostFormOpened,
}

/// Side effects the [AppLinkHandler] asks the app to perform.
abstract interface class AppLinkEffects {
  /// Opens terminal route [location] above Connections, matching the stack a
  /// manual open produces.
  void openTerminal(String location);

  /// Opens the add-host form prefilled from [sshUrl] for the user to review.
  void openNewHostForm(String sshUrl);

  /// Tells the user why a link did nothing.
  void showMessage(String message);

  /// Shows what a preset runs. Resolves to `true` only if the user chose Run.
  Future<bool> confirmPresetLaunch(AppLinkPresetReview review);

  /// Opens a new connection to [host] so its launch preset runs.
  Future<void> launchPreset(Host host);
}

/// Resolves a parsed [AppLink] against data saved on this device and
/// performs it through [AppLinkEffects].
///
/// A link never starts anything on its own: open and chat links only
/// navigate, a preset link always shows the preset's exact command first,
/// and an `ssh://` link for an unknown host opens the add-host form unsaved.
class AppLinkHandler {
  /// Creates a link handler.
  AppLinkHandler({
    required HostRepository hostRepository,
    required AcpRecentSessionsService recentSessions,
    required AgentLaunchPresetService presetService,
    required HostCliLaunchPreferencesService cliLaunchPreferences,
    required AppLinkEffects effects,
    String Function()? newTapId,
    DiagnosticsLogger? diagnostics,
  }) : _hosts = hostRepository,
       _recentSessions = recentSessions,
       _presets = presetService,
       _cliLaunchPreferences = cliLaunchPreferences,
       _effects = effects,
       _newTapId =
           newTapId ?? (() => '${DateTime.now().microsecondsSinceEpoch}'),
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final HostRepository _hosts;
  final AcpRecentSessionsService _recentSessions;
  final AgentLaunchPresetService _presets;
  final HostCliLaunchPreferencesService _cliLaunchPreferences;
  final AppLinkEffects _effects;
  final String Function() _newTapId;
  final DiagnosticsLogger _diagnostics;

  /// Performs [link] and returns how it was resolved.
  Future<AppLinkOutcome> handle(AppLink link) async {
    final outcome = switch (link) {
      RejectedAppLink(:final reason) => _reject(reason),
      OpenHostAppLink() => await _openHost(link),
      OpenChatAppLink() => await _openChat(link),
      LaunchPresetAppLink() => await _launchPreset(link),
      SshHostAppLink() => await _openSshHost(link),
    };
    _diagnostics.info(
      'app_link',
      'handled',
      fields: {'action': link.diagnosticsAction, 'outcome': outcome.name},
    );
    return outcome;
  }

  AppLinkOutcome _reject(AppLinkRejection reason) {
    _effects.showMessage(
      reason == AppLinkRejection.embeddedCredentials
          ? AppLinkMessages.embeddedCredentials
          : AppLinkMessages.invalid,
    );
    return AppLinkOutcome.rejected;
  }

  Future<AppLinkOutcome> _openHost(OpenHostAppLink link) async {
    final host = await _hosts.getById(link.hostId);
    if (host == null) {
      _effects.showMessage(AppLinkMessages.hostMissing);
      return AppLinkOutcome.hostMissing;
    }
    _effects.openTerminal(
      buildAppLinkTerminalLocation(
        hostId: host.id,
        windowIndex: link.windowIndex,
        linkTapId: _newTapId(),
      ),
    );
    return AppLinkOutcome.opened;
  }

  Future<AppLinkOutcome> _openChat(OpenChatAppLink link) async {
    final host = await _hosts.getById(link.hostId);
    if (host == null) {
      _effects.showMessage(AppLinkMessages.hostMissing);
      return AppLinkOutcome.hostMissing;
    }
    // Recent sessions are listed most recent first, so a session id reused
    // across providers resolves to the one used last.
    final sessions = await _recentSessions.list();
    final session = sessions.firstWhereOrNull(
      (ref) => ref.hostId == host.id && ref.acpSessionId == link.sessionId,
    );
    if (session == null) {
      _effects.showMessage(AppLinkMessages.chatMissing);
      return AppLinkOutcome.chatMissing;
    }
    _effects.openTerminal(
      buildAppLinkChatLocation(session, linkTapId: _newTapId()),
    );
    return AppLinkOutcome.opened;
  }

  Future<AppLinkOutcome> _launchPreset(LaunchPresetAppLink link) async {
    final host = await _hosts.getById(link.presetId);
    // A host whose auto-connect runs a snippet would not run its preset, so
    // the review could not show what actually runs.
    if (host == null || host.autoConnectSnippetId != null) {
      _effects.showMessage(AppLinkMessages.presetMissing);
      return AppLinkOutcome.presetMissing;
    }
    final preset = (await _presets.getPresetStateForHost(host.id)).preset;
    if (preset == null) {
      _effects.showMessage(AppLinkMessages.presetMissing);
      return AppLinkOutcome.presetMissing;
    }
    final preferences = await _cliLaunchPreferences.getPreferencesForHost(
      host.id,
    );
    final startInYoloMode = preferences.startInYoloMode;
    final String command;
    try {
      // The same builder the terminal uses for this preset's auto-connect.
      command = buildAgentLaunchCommand(
        preset,
        startInYoloMode: startInYoloMode,
      );
    } on FormatException {
      _effects.showMessage(AppLinkMessages.presetMissing);
      return AppLinkOutcome.presetMissing;
    }
    final muxSessionName = preset.usesMuxSession
        ? preset.tmuxSessionName!.trim()
        : null;
    final confirmed = await _effects.confirmPresetLaunch(
      AppLinkPresetReview(
        hostLabel: host.label,
        tool: preset.tool,
        command: command,
        yoloMode: startInYoloMode && preset.tool.supportsYoloMode,
        muxSessionName: muxSessionName,
        muxBackend: muxSessionName == null
            ? null
            : preset.effectiveRemoteMuxBackend,
      ),
    );
    if (!confirmed) {
      return AppLinkOutcome.presetDeclined;
    }
    await _effects.launchPreset(host);
    return AppLinkOutcome.presetLaunched;
  }

  Future<AppLinkOutcome> _openSshHost(SshHostAppLink link) async {
    final hostname = link.hostname.toLowerCase();
    final matches = (await _hosts.getAll())
        .where(
          (host) =>
              host.hostname.trim().toLowerCase() == hostname &&
              host.port == link.effectivePort &&
              (link.username == null || host.username == link.username),
        )
        .toList(growable: false);
    if (matches.length == 1) {
      _effects.openTerminal(
        buildAppLinkTerminalLocation(
          hostId: matches.single.id,
          linkTapId: _newTapId(),
        ),
      );
      return AppLinkOutcome.opened;
    }
    _effects.openNewHostForm(link.toSanitizedUrl());
    return AppLinkOutcome.hostFormOpened;
  }
}

/// Builds the terminal route for an open-host link.
String buildAppLinkTerminalLocation({
  required int hostId,
  required String linkTapId,
  int? windowIndex,
}) => Uri(
  path: '/terminal/$hostId',
  queryParameters: <String, String>{
    if (windowIndex != null) 'tmuxWindow': '$windowIndex',
    appLinkTapQueryKey: linkTapId,
  },
).toString();

/// Builds the terminal route that selects a native agent chat, the same
/// target an agent notification opens.
String buildAppLinkChatLocation(
  AcpRecentSessionRef session, {
  required String linkTapId,
}) => Uri(
  path: '/terminal/${session.hostId}',
  queryParameters: <String, String>{
    acpAgentChatProviderQueryKey: session.providerId,
    acpAgentChatBridgeQueryKey: session.bridgeId,
    acpAgentChatSessionQueryKey: session.acpSessionId,
    appLinkTapQueryKey: linkTapId,
  },
).toString();

/// Builds the add-host form route prefilled from a sanitized `ssh://` URL.
String buildAppLinkHostFormLocation(String sshUrl) => Uri(
  path: '/hosts/add',
  queryParameters: <String, String>{'sshUrl': sshUrl},
).toString();
