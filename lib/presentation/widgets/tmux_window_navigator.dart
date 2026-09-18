import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/host_cli_launch_preferences.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/terminal_progress.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/remote_multiplexer_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_error_policy.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/tmux_service.dart';
import 'acp_mux_window_status_badge.dart';
import 'acp_native_badge.dart';
import 'acp_new_session_sheet.dart';
import 'acp_session_presentation.dart';
import 'agent_tool_icon.dart';
import 'ai_session_picker.dart';
import 'premium_badge.dart';
import 'system_bottom_inset.dart';
import 'terminal_overlay_focus.dart';
import 'tmux_window_status_badge.dart';

const _tmuxNavigatorDenseVisualDensity = VisualDensity(vertical: -2);
const _tmuxNavigatorTilePadding = EdgeInsets.symmetric(horizontal: 16);
const _tmuxNavigatorGroupTilePadding = EdgeInsets.only(left: 16, right: 16);
const _tmuxNavigatorMaxHeightFactor = 0.48;
const _tmuxNavigatorMaxHeightCap = 440.0;
const _tmuxToolPickerMaxHeightFactor = 0.36;
const _tmuxToolPickerMaxHeightCap = 320.0;

/// Serializes window queries and owns snapshot invalidation and retry lifetime.
class TmuxWindowLoader {
  /// Creates a loader whose callbacks read the view's current session and state.
  TmuxWindowLoader({
    required Future<List<TmuxWindow>> Function() fetch,
    required List<TmuxWindow>? Function() currentWindows,
    required void Function(
      List<TmuxWindow>? windows,
      AsyncError? error, {
      required bool shouldRecover,
    })
    onChanged,
    required int Function() connectionId,
    bool Function()? acceptEmpty,
  }) : _fetch = fetch,
       _currentWindows = currentWindows,
       _onChanged = onChanged,
       _connectionId = connectionId,
       _acceptEmpty = acceptEmpty;

  final Future<List<TmuxWindow>> Function() _fetch;
  final List<TmuxWindow>? Function() _currentWindows;
  final void Function(
    List<TmuxWindow>?,
    AsyncError?, {
    required bool shouldRecover,
  })
  _onChanged;
  final int Function() _connectionId;
  final bool Function()? _acceptEmpty;
  bool _disposed = false;
  bool _loading = false;
  bool _pending = false;
  int _generation = 0;
  int _retryAttempts = 0;
  int _emptyReloads = 0;
  Timer? _retryTimer;

  void _resetRecovery() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempts = 0;
    _emptyReloads = 0;
  }

  /// Invalidates in-flight results when a snapshot or session changes.
  void invalidate() {
    _generation++;
    _resetRecovery();
  }

  /// Cancels retries and prevents queued or future queries from starting.
  void dispose() {
    _disposed = true;
    _pending = false;
    invalidate();
  }

  /// Reloads windows, coalescing concurrent requests into one follow-up query.
  Future<void> load() async {
    if (_disposed) return;
    if (_loading) {
      _pending = true;
      return;
    }
    _loading = true;
    final generation = ++_generation;
    try {
      List<TmuxWindow>? windows;
      AsyncError? error;
      try {
        windows = await _fetch();
      } on Object catch (caught, stackTrace) {
        error = AsyncError(caught, stackTrace);
      }
      if (_disposed || generation != _generation) return;
      final isEmpty = windows?.isEmpty ?? false;
      if (error == null) {
        if (isEmpty) {
          _emptyReloads++;
        } else {
          _resetRecovery();
        }
      }
      DiagnosticsLogService.instance.info(
        'tmux.windows',
        error == null ? 'reload_result' : 'reload_failed',
        fields: {
          'connectionId': _connectionId(),
          'generation': generation,
          'windowCount': windows?.length ?? 0,
          'consecutiveEmptyReloads': _emptyReloads,
          if (error != null) 'errorType': error.error.runtimeType,
        },
      );
      final acceptEmpty = isEmpty && (_acceptEmpty?.call() ?? false);
      if (isEmpty && !acceptEmpty) {
        final currentWindows = _currentWindows();
        windows = resolveTmuxReloadedWindows(
          shouldPreserveTmuxWindowSnapshotOnEmptyReload(
                currentWindows,
                consecutiveEmptyReloads: _emptyReloads,
              )
              ? currentWindows
              : null,
          windows!,
        );
      }
      final shouldRecover =
          !(_currentWindows()?.isNotEmpty ?? false) && _retryAttempts >= 1;
      _onChanged(windows, error, shouldRecover: shouldRecover);
      if (_disposed || generation != _generation || acceptEmpty) return;
      if ((isEmpty || error != null) && !(_retryTimer?.isActive ?? false)) {
        final delay = resolveTmuxWindowReloadRetryDelay(_retryAttempts++);
        DiagnosticsLogService.instance.warning(
          'tmux.windows',
          'retry_scheduled',
          fields: {
            'connectionId': _connectionId(),
            'attempt': _retryAttempts,
            'delayMs': delay.inMilliseconds,
          },
        );
        _retryTimer = Timer(delay, () {
          _retryTimer = null;
          unawaited(load());
        });
      }
    } finally {
      _loading = false;
      if (_pending && !_disposed) {
        _pending = false;
        unawaited(load());
      }
    }
  }
}

/// Confirms closing a tmux/MonkeyMux terminal window when enabled.
///
/// A confirmed "Don't ask me again" choice disables future prompts; cancelling
/// never changes the preference. The setting remains available in Settings.
Future<bool> confirmMuxWindowClose({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
}) async {
  final shouldConfirm = await ref
      .read(confirmMuxWindowCloseNotifierProvider.notifier)
      .initializedValue();
  if (!context.mounted) return false;
  if (!shouldConfirm) return true;
  var dontAskAgain = false;
  final result = await showDialog<({bool confirmed, bool dontAskAgain})>(
    context: context,
    requestFocus: terminalOverlayRouteRequestFocus(context),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Close window?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Close “$title”? Any running process will stop.'),
            const SizedBox(height: FluttyTheme.spacingSm),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Don’t ask me again'),
              value: dontAskAgain,
              onChanged: (value) =>
                  setDialogState(() => dontAskAgain = value ?? false),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, (
              confirmed: false,
              dontAskAgain: false,
            )),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, (
              confirmed: true,
              dontAskAgain: dontAskAgain,
            )),
            child: const Text('Close window'),
          ),
        ],
      ),
    ),
  );
  if (result?.confirmed != true) {
    return false;
  }
  if (result!.dontAskAgain) {
    await ref
        .read(confirmMuxWindowCloseNotifierProvider.notifier)
        .setEnabled(enabled: false);
  }
  return context.mounted;
}

List<AgentLaunchTool> _orderedAgentLaunchTools(
  Iterable<AgentLaunchTool> tools, {
  AgentLaunchTool? preferredTool,
}) {
  final ordered = tools.toList(growable: false);
  if (preferredTool == null) {
    return ordered;
  }

  final preferredIndex = ordered.indexOf(preferredTool);
  if (preferredIndex <= 0) {
    return ordered;
  }

  return <AgentLaunchTool>[
    ordered[preferredIndex],
    ...ordered.take(preferredIndex),
    ...ordered.skip(preferredIndex + 1),
  ];
}

String _telemetryMuxBackendName(RemoteMuxBackend backend) => switch (backend) {
  RemoteMuxBackend.auto => 'auto',
  RemoteMuxBackend.tmux => 'tmux',
  RemoteMuxBackend.monkeyMux => 'monkeymux',
};

String _telemetryAgentToolName(String toolName) {
  final tool = agentLaunchToolForCommandText(toolName);
  return tool?.name ?? toolName.toLowerCase().replaceAll(' ', '_');
}

/// Maps known terminal agent tools to their matching ACP providers.
Map<AgentLaunchTool, String> nativeAcpProvidersByTool(
  List<AcpProvider> providers,
) => <AgentLaunchTool, String>{
  for (final tool in AgentLaunchTool.uiDisplayOrder)
    tool: ?acpProviderIdForAgentLaunchTool(tool, providers),
};

/// Maps known terminal agent tools to built-in ACP providers without I/O.
Map<AgentLaunchTool, String> builtinNativeAcpProvidersByTool() =>
    nativeAcpProvidersByTool(<AcpProvider>[
      for (final provider in acpBuiltinProviders) provider,
    ]);

/// Resolves the branded terminal-agent identity for a built-in ACP provider.
AgentLaunchTool? agentLaunchToolForAcpProviderId(String providerId) =>
    agentLaunchToolForBuiltinAcpProviderId(providerId);

/// Shows the tmux window navigator bottom sheet.
///
/// Returns the action the user selected, or `null` if dismissed.
Future<TmuxNavigatorAction?> showTmuxNavigator({
  required BuildContext context,
  required SshSession session,
  required String tmuxSessionName,
  required RemoteMuxBackend remoteMuxBackend,
  required RemoteMultiplexerService remoteMultiplexerService,
  required bool isProUser,
  required bool startClisInYoloMode,
  AgentWindowModePreference agentWindowModePreference =
      AgentWindowModePreference.askEveryTime,
  String? tmuxExtraFlags,
  String? scopeWorkingDirectory,
}) => showModalBottomSheet<TmuxNavigatorAction>(
  context: context,
  isScrollControlled: true,
  requestFocus: terminalOverlayRouteRequestFocus(context),
  builder: (context) => _TmuxNavigatorSheet(
    session: session,
    tmuxSessionName: tmuxSessionName,
    remoteMuxBackend: remoteMuxBackend,
    remoteMultiplexerService: remoteMultiplexerService,
    tmuxExtraFlags: tmuxExtraFlags,
    isProUser: isProUser,
    startClisInYoloMode: startClisInYoloMode,
    agentWindowModePreference: agentWindowModePreference,
    scopeWorkingDirectory: scopeWorkingDirectory,
  ),
);

/// Shows the tmux new-window picker bottom sheet.
Future<TmuxNavigatorAction?> showTmuxNewWindowPicker({
  required BuildContext context,
  required bool isProUser,
  required bool startClisInYoloMode,
  AgentWindowModePreference agentWindowModePreference =
      AgentWindowModePreference.askEveryTime,
  Future<Set<AgentLaunchTool>>? installedToolsFuture,
  AgentLaunchTool? preferredTool,
  Map<AgentLaunchTool, String> nativeAcpProviderIds = const {},
}) => showModalBottomSheet<TmuxNavigatorAction>(
  context: context,
  isScrollControlled: true,
  requestFocus: terminalOverlayRouteRequestFocus(context),
  builder: (context) => PlatformKeyboardInsetMediaQuery(
    child: TmuxToolPickerSheet(
      installedToolsFuture: installedToolsFuture,
      preferredTool: preferredTool,
      nativeAcpTools: nativeAcpProviderIds.keys.toSet(),
      onToolSelected: (tool) => _selectAgentLaunchMode(
        context: context,
        tool: tool,
        isProUser: isProUser,
        startClisInYoloMode: startClisInYoloMode,
        nativeAcpProviderIds: nativeAcpProviderIds,
        preference: agentWindowModePreference,
      ),
      onToolLongPressed: (tool) => _selectAgentLaunchMode(
        context: context,
        tool: tool,
        isProUser: isProUser,
        startClisInYoloMode: startClisInYoloMode,
        nativeAcpProviderIds: nativeAcpProviderIds,
        preference: agentWindowModePreference,
        forcePicker: true,
      ),
      onEmptyWindow: () {
        Navigator.pop(context, const TmuxNewWindowAction());
      },
    ),
  ),
);

Future<void> _selectAgentLaunchMode({
  required BuildContext context,
  required AgentLaunchTool tool,
  required bool isProUser,
  required bool startClisInYoloMode,
  required Map<AgentLaunchTool, String> nativeAcpProviderIds,
  required AgentWindowModePreference preference,
  bool forcePicker = false,
}) async {
  final providerId = nativeAcpProviderIds[tool];
  if (providerId == null) {
    Navigator.pop(
      context,
      TmuxNewWindowAction(
        command: buildAgentToolCommand(
          tool,
          startInYoloMode: startClisInYoloMode,
        ),
        windowName: tool.commandName,
        agentTool: tool,
      ),
    );
    return;
  }
  final mode = await resolveAgentWindowMode(
    context: context,
    tool: tool,
    isProUser: isProUser,
    preference: preference,
    forcePicker: forcePicker,
  );
  if (!context.mounted || mode == null) {
    return;
  }
  switch (mode) {
    case AgentWindowMode.terminal:
      Navigator.pop(
        context,
        TmuxNewWindowAction(
          command: buildAgentToolCommand(
            tool,
            startInYoloMode: startClisInYoloMode,
          ),
          windowName: tool.commandName,
          agentTool: tool,
        ),
      );
    case AgentWindowMode.nativeAcp:
      Navigator.pop(context, TmuxNewAcpSessionAction(providerId: providerId));
  }
}

/// Presentation mode for a supported coding-agent mux window.
enum AgentWindowMode {
  /// Run the agent's complete terminal CLI.
  terminal,

  /// Run the agent through its ACP-native conversation surface.
  nativeAcp,
}

/// Resolves the app-wide default or presents a one-off mode chooser.
///
/// Terminal and native modes are available on every tier. [isProUser] only
/// tailors the native-chat description to mention parallel-session access.
Future<AgentWindowMode?> resolveAgentWindowMode({
  required BuildContext context,
  required AgentLaunchTool tool,
  required bool isProUser,
  required AgentWindowModePreference preference,
  bool forcePicker = false,
}) {
  if (!forcePicker) {
    switch (preference) {
      case AgentWindowModePreference.preferNative:
        return Future.value(AgentWindowMode.nativeAcp);
      case AgentWindowModePreference.preferTerminal:
        return Future.value(AgentWindowMode.terminal);
      case AgentWindowModePreference.askEveryTime:
        break;
    }
  }
  return showAgentWindowModePicker(
    context: context,
    tool: tool,
    isProUser: isProUser,
  );
}

/// Lets the user choose Terminal CLI or Native for [tool].
Future<AgentWindowMode?> showAgentWindowModePicker({
  required BuildContext context,
  required AgentLaunchTool tool,
  required bool isProUser,
}) => showModalBottomSheet<AgentWindowMode>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  isScrollControlled: true,
  requestFocus: terminalOverlayRouteRequestFocus(context),
  builder: (context) => PlatformKeyboardInsetMediaQuery(
    child: _AgentWindowModePickerSheet(tool: tool, isProUser: isProUser),
  ),
);

class _AgentWindowModePickerSheet extends StatefulWidget {
  const _AgentWindowModePickerSheet({
    required this.tool,
    required this.isProUser,
  });

  final AgentLaunchTool tool;
  final bool isProUser;

  @override
  State<_AgentWindowModePickerSheet> createState() =>
      _AgentWindowModePickerSheetState();
}

class _AgentWindowModePickerSheetState
    extends State<_AgentWindowModePickerSheet> {
  var _rememberChoice = false;
  var _saving = false;

  Future<void> _choose(AgentWindowMode mode) async {
    if (_saving) return;
    if (_rememberChoice) {
      setState(() => _saving = true);
      final preference = switch (mode) {
        AgentWindowMode.terminal => AgentWindowModePreference.preferTerminal,
        AgentWindowMode.nativeAcp => AgentWindowModePreference.preferNative,
      };
      await ProviderScope.containerOf(context)
          .read(agentWindowModePreferenceNotifierProvider.notifier)
          .setPreference(preference);
    }
    if (mounted) Navigator.pop(context, mode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.max(0, mediaQuery.size.height - keyboardInset - 24),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      TmuxToolPickerSheet._iconForTool(widget.tool, theme),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.tool.label,
                          style: FluttyTheme.displayMono(
                            fontSize: 18,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  minTileHeight: 52,
                  leading: const Icon(Icons.terminal_outlined),
                  title: const Text('Terminal'),
                  subtitle: const Text('Run the full CLI in MonkeyMux'),
                  enabled: !_saving,
                  onTap: _saving
                      ? null
                      : () => unawaited(_choose(AgentWindowMode.terminal)),
                ),
                ListTile(
                  minTileHeight: 52,
                  leading: Icon(
                    Icons.chat_bubble_outline,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('Native chat'),
                  subtitle: Text(
                    widget.isProUser
                        ? 'Chat, tools, permissions, and parallel sessions'
                        : 'Chat, tools, and permissions · one connected chat on Free',
                  ),
                  enabled: !_saving,
                  onTap: _saving
                      ? null
                      : () => unawaited(_choose(AgentWindowMode.nativeAcp)),
                ),
                const Divider(height: 1),
                CheckboxListTile(
                  key: const ValueKey('remember-agent-window-mode'),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Remember this choice'),
                  subtitle: const Text('Use it for future agent windows'),
                  value: _rememberChoice,
                  onChanged: _saving
                      ? null
                      : (value) =>
                            setState(() => _rememberChoice = value ?? false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the tmux new-window picker as a menu next to [anchorContext].
Future<TmuxNewWindowAction?> showTmuxNewWindowContextMenu({
  required BuildContext context,
  required BuildContext anchorContext,
  required bool startClisInYoloMode,
  Future<Set<AgentLaunchTool>>? installedToolsFuture,
  AgentLaunchTool? preferredTool,
}) async {
  final overlay = Overlay.maybeOf(context);
  final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  if (overlayBox == null || anchorBox == null) {
    return null;
  }

  final anchorTopLeft = anchorBox.localToGlobal(
    Offset.zero,
    ancestor: overlayBox,
  );
  final menuPosition = RelativeRect.fromRect(
    anchorTopLeft & anchorBox.size,
    Offset.zero & overlayBox.size,
  );

  final tools = await _resolveTmuxNewWindowTools(
    installedToolsFuture,
    preferredTool: preferredTool,
  );
  if (!context.mounted || !anchorContext.mounted) {
    return null;
  }

  final selection = await showMenu<TmuxNewWindowAction>(
    context: context,
    position: menuPosition,
    requestFocus: terminalOverlayRouteRequestFocus(context),
    items: [
      const PopupMenuItem<TmuxNewWindowAction>(
        enabled: false,
        child: Text('New window'),
      ),
      if (tools.isEmpty)
        PopupMenuItem<TmuxNewWindowAction>(
          enabled: false,
          child: Text(
            'No supported CLIs found on PATH.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        )
      else
        for (final tool in tools)
          PopupMenuItem<TmuxNewWindowAction>(
            value: TmuxNewWindowAction(
              command: buildAgentToolCommand(
                tool,
                startInYoloMode: startClisInYoloMode,
              ),
              windowName: tool.commandName,
              agentTool: tool,
            ),
            child: _TmuxNewWindowMenuItem(
              icon: TmuxToolPickerSheet._iconForTool(tool, Theme.of(context)),
              label: tool.label,
            ),
          ),
      const PopupMenuDivider(),
      PopupMenuItem<TmuxNewWindowAction>(
        value: const TmuxNewWindowAction(),
        child: _TmuxNewWindowMenuItem(
          icon: Icon(
            Icons.terminal,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            size: 18,
          ),
          label: 'Empty terminal',
        ),
      ),
    ],
  );

  return selection;
}

Future<List<AgentLaunchTool>> _resolveTmuxNewWindowTools(
  Future<Set<AgentLaunchTool>>? installedToolsFuture, {
  AgentLaunchTool? preferredTool,
}) async {
  Iterable<AgentLaunchTool> availableTools;
  if (installedToolsFuture == null) {
    availableTools = TmuxToolPickerSheet._allTools;
  } else {
    try {
      final installed = await installedToolsFuture;
      availableTools = TmuxToolPickerSheet._allTools.where(installed.contains);
    } on Object {
      availableTools = const <AgentLaunchTool>[];
    }
  }
  return _orderedAgentLaunchTools(availableTools, preferredTool: preferredTool);
}

/// An action selected from the tmux navigator.
sealed class TmuxNavigatorAction {
  /// Creates a new [TmuxNavigatorAction].
  const TmuxNavigatorAction();
}

/// Switch the current terminal to a different tmux window.
class TmuxSwitchWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxSwitchWindowAction].
  const TmuxSwitchWindowAction(this.windowIndex, {this.windowId});

  /// The window index to switch to.
  final int windowIndex;

  /// The stable window ID, when available.
  final String? windowId;
}

/// Create a new tmux window, optionally running a command.
class TmuxNewWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxNewWindowAction].
  const TmuxNewWindowAction({this.command, this.windowName, this.agentTool});

  /// Optional command to run in the new window.
  final String? command;

  /// Optional name for the new window.
  final String? windowName;

  /// Agent identity when this is a generated terminal-agent launch.
  final AgentLaunchTool? agentTool;
}

/// Start a native ACP session in a new MonkeyMux window.
class TmuxNewAcpSessionAction extends TmuxNavigatorAction {
  /// Creates a native ACP session for a provider supported by MonkeyMux.
  const TmuxNewAcpSessionAction({this.providerId});

  /// Stable ACP provider identifier selected for launch, or null to choose one.
  final String? providerId;
}

/// Open an existing native ACP session from the MonkeyMux window navigator.
class TmuxOpenAcpSessionAction extends TmuxNavigatorAction {
  /// Creates an open-native-session action.
  const TmuxOpenAcpSessionAction(this.key);

  /// Stable session identity.
  final AcpSessionKey key;
}

/// Open a server-owned native ACP MonkeyMux window.
class TmuxOpenAcpWindowAction extends TmuxNavigatorAction {
  /// Creates an action that selects and reconnects a durable native window.
  const TmuxOpenAcpWindowAction({
    required this.windowIndex,
    required this.bridgeId,
    required this.providerId,
    this.workingDirectory,
  });

  /// Real MonkeyMux window index to select before opening the native viewport.
  final int windowIndex;

  /// Persistent remote bridge owned by the window.
  final String bridgeId;

  /// Stable ACP provider identifier.
  final String providerId;

  /// Remote working directory retained by the window.
  final String? workingDirectory;
}

/// Stop a tracked native ACP session from the MonkeyMux window navigator.
class TmuxCloseAcpSessionAction extends TmuxNavigatorAction {
  /// Creates a close-native-session action.
  const TmuxCloseAcpSessionAction(this.key);

  /// Stable session identity.
  final AcpSessionKey key;
}

/// Resume an agent-owned session through a fresh native ACP bridge.
class TmuxResumeAcpSessionAction extends TmuxNavigatorAction {
  /// Creates a native resume action.
  const TmuxResumeAcpSessionAction({
    required this.providerId,
    required this.acpSessionId,
    this.workingDirectory,
  });

  /// Stable built-in ACP provider identifier.
  final String providerId;

  /// Opaque session identifier discovered from the agent's own history.
  final String acpSessionId;

  /// Working directory in which the provider session was created.
  final String? workingDirectory;
}

/// Resume an AI tool session in a new tmux window.
class TmuxResumeSessionAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxResumeSessionAction].
  const TmuxResumeSessionAction(this.resumeCommand, {this.workingDirectory});

  /// The full resume command to run.
  final String resumeCommand;

  /// The working directory to start in.
  final String? workingDirectory;
}

/// Open a contextual MonkeySSH Pro paywall from the mux navigator.
class TmuxUpgradeAction extends TmuxNavigatorAction {
  /// Creates an upgrade action for [feature].
  const TmuxUpgradeAction({
    required this.feature,
    required this.blockedAction,
    required this.blockedOutcome,
  });

  /// Premium feature that owns the blocked workflow.
  final MonetizationFeature feature;

  /// Specific action the user attempted.
  final String blockedAction;

  /// Concrete benefit unlocked by Pro.
  final String blockedOutcome;
}

/// Close a tmux window.
class TmuxCloseWindowAction extends TmuxNavigatorAction {
  /// Creates a new [TmuxCloseWindowAction].
  const TmuxCloseWindowAction(this.windowIndex, {this.windowId});

  /// The window index to close.
  final int windowIndex;

  /// The stable window ID, when available.
  final String? windowId;
}

/// Returns a safe diagnostics category for a tmux navigator action.
String diagnosticTmuxNavigatorActionKind(TmuxNavigatorAction action) =>
    switch (action) {
      TmuxSwitchWindowAction() => 'switch_window',
      TmuxNewWindowAction() => 'new_window',
      TmuxNewAcpSessionAction() => 'new_acp_session',
      TmuxOpenAcpSessionAction() => 'open_acp_session',
      TmuxOpenAcpWindowAction() => 'open_acp_window',
      TmuxCloseAcpSessionAction() => 'close_acp_session',
      TmuxResumeAcpSessionAction() => 'resume_acp_session',
      TmuxResumeSessionAction() => 'resume_session',
      TmuxUpgradeAction() => 'upgrade',
      TmuxCloseWindowAction() => 'close_window',
    };

class _TmuxNavigatorSheet extends ConsumerStatefulWidget {
  const _TmuxNavigatorSheet({
    required this.session,
    required this.tmuxSessionName,
    required this.remoteMuxBackend,
    required this.remoteMultiplexerService,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.agentWindowModePreference,
    this.tmuxExtraFlags,
    this.scopeWorkingDirectory,
  });

  final SshSession session;
  final String tmuxSessionName;
  final RemoteMuxBackend remoteMuxBackend;
  final RemoteMultiplexerService remoteMultiplexerService;
  final String? tmuxExtraFlags;
  final bool isProUser;
  final bool startClisInYoloMode;
  final AgentWindowModePreference agentWindowModePreference;
  final String? scopeWorkingDirectory;

  @override
  ConsumerState<_TmuxNavigatorSheet> createState() =>
      _TmuxNavigatorSheetState();
}

class _TmuxNavigatorSheetState extends ConsumerState<_TmuxNavigatorSheet> {
  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  bool _isLoadingWindows = true;
  String? _error;
  int _windowEventGeneration = 0;

  late final _windowLoader = TmuxWindowLoader(
    fetch: () => _mux.listWindows(
      widget.session,
      widget.tmuxSessionName,
      extraFlags: widget.tmuxExtraFlags,
    ),
    currentWindows: () => _windows,
    connectionId: () => widget.session.connectionId,
    onChanged: _applyWindowReload,
  );

  RemoteMultiplexerService get _mux => widget.remoteMultiplexerService;

  String get _muxLabel => switch (widget.remoteMuxBackend) {
    RemoteMuxBackend.monkeyMux => 'MonkeyMux',
    RemoteMuxBackend.tmux => 'tmux',
    RemoteMuxBackend.auto => 'remote multiplexer',
  };

  late MuxWindowProjection _projection;

  AcpSessionManagerState get _watchedAcpManagerState {
    final manager = ref.watch(acpSessionManagerProvider);
    return ref.watch(acpSessionManagerStateProvider).asData?.value ??
        manager.state;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferredLaunchTool());
    _subscribeToWindowChanges();
    _windowLoader.load();
  }

  @override
  void didUpdateWidget(covariant _TmuxNavigatorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.hostId != widget.session.hostId) {
      _windowLoader.invalidate();
      unawaited(_loadPreferredLaunchTool());
    }
  }

  @override
  void dispose() {
    _windowLoader.dispose();
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  void _subscribeToWindowChanges() {
    final generation = ++_windowEventGeneration;
    DiagnosticsLogService.instance.info(
      'tmux.navigator',
      'subscribe',
      fields: {
        'connectionId': widget.session.connectionId,
        'generation': generation,
      },
    );
    _windowChangeSubscription = _mux
        .watchWindowChanges(
          widget.session,
          widget.tmuxSessionName,
          extraFlags: widget.tmuxExtraFlags,
        )
        .listen((event) => _handleWindowChangeEvent(event, generation));
  }

  Future<void> _loadPreferredLaunchTool() async {
    final hostId = widget.session.hostId;
    final preset = await ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(hostId);
    if (!mounted || widget.session.hostId != hostId) return;

    final preferredLaunchTool = preset?.tool;
    if (_preferredLaunchTool == preferredLaunchTool) return;
    setState(() => _preferredLaunchTool = preferredLaunchTool);
  }

  void _applyWindowReload(
    List<TmuxWindow>? windows,
    AsyncError? error, {
    required bool shouldRecover,
  }) {
    if (error != null &&
        error.error is! Exception &&
        !isExpectedSshOperationError(error.error)) {
      Error.throwWithStackTrace(error.error, error.stackTrace);
    }
    setState(() {
      if (error != null) {
        _error = _windows?.isEmpty ?? true
            ? shouldRecover
                  ? 'Could not refresh $_muxLabel windows yet. Retrying...'
                  : error.error.toString()
            : null;
        _isLoadingWindows = false;
      } else {
        _windows = windows;
        _error = windows == null && shouldRecover
            ? '$_muxLabel did not return any windows yet. Retrying...'
            : null;
        _isLoadingWindows = windows == null && !shouldRecover;
      }
    });
  }

  void _handleWindowChangeEvent(TmuxWindowChangeEvent event, int generation) {
    if (!mounted) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      DiagnosticsLogService.instance.debug(
        'tmux.navigator',
        'reload_event',
        fields: {
          'connectionId': widget.session.connectionId,
          'generation': generation,
        },
      );
      _windowLoader.load();
      return;
    }
    if (event is TmuxWindowListEvent) {
      _windowLoader.invalidate();
      final currentWindows = _windows;
      setState(() {
        _windows = currentWindows == null
            ? event.windows
            : applyTmuxWindowChangeEvent(currentWindows, event);
        _error = null;
        _isLoadingWindows = false;
      });
      return;
    }
    final currentWindows = _windows;
    if (currentWindows == null) {
      DiagnosticsLogService.instance.debug(
        'tmux.navigator',
        'snapshot_without_state',
        fields: {'connectionId': widget.session.connectionId},
      );
      _windowLoader.load();
      return;
    }
    _windowLoader.invalidate();
    setState(() {
      _windows = applyTmuxWindowChangeEvent(currentWindows, event);
      _error = null;
      _isLoadingWindows = false;
    });
    DiagnosticsLogService.instance.debug(
      'tmux.navigator',
      'snapshot_applied',
      fields: {
        'connectionId': widget.session.connectionId,
        'windowCount': _windows?.length ?? 0,
      },
    );
  }

  void _switchToWindow(TmuxWindow window) {
    unawaited(HapticFeedback.selectionClick());
    Navigator.pop(
      context,
      TmuxSwitchWindowAction(window.index, windowId: window.id),
    );
  }

  Future<void> _confirmCloseWindow(
    TmuxWindow window, {
    String? displayTitle,
  }) async {
    final confirmed = await confirmMuxWindowClose(
      context: context,
      ref: ref,
      title: displayTitle ?? window.displayTitle,
    );
    if (!mounted || !confirmed) {
      return;
    }
    Navigator.pop(
      context,
      TmuxCloseWindowAction(window.index, windowId: window.id),
    );
  }

  void _createNewWindow({
    String? command,
    String? name,
    AgentLaunchTool? agentTool,
  }) {
    Navigator.pop(
      context,
      TmuxNewWindowAction(
        command: command,
        windowName: name,
        agentTool: agentTool,
      ),
    );
  }

  Future<void> _showNewWindowPicker() async {
    final installedToolsFuture = ref
        .read(tmuxServiceProvider)
        .detectInstalledAgentTools(widget.session);
    unawaited(
      installedToolsFuture
          .then((tools) {
            for (final tool in tools) {
              unawaited(
                ref
                    .read(telemetryServiceProvider)
                    .logAgentToolDetected(tool: tool.name),
              );
            }
          })
          .catchError((Object _) {}),
    );
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logMuxNewWindowDialogOpened(
            backend: _telemetryMuxBackendName(widget.remoteMuxBackend),
          ),
    );
    final nativeAcpAvailable =
        widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
    final nativeAcpProviderIds = nativeAcpAvailable
        ? builtinNativeAcpProvidersByTool()
        : const <AgentLaunchTool, String>{};
    final action = await showTmuxNewWindowPicker(
      context: context,
      isProUser: widget.isProUser,
      startClisInYoloMode: widget.startClisInYoloMode,
      agentWindowModePreference: widget.agentWindowModePreference,
      installedToolsFuture: installedToolsFuture,
      preferredTool: _preferredLaunchTool,
      nativeAcpProviderIds: nativeAcpProviderIds,
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case TmuxNewWindowAction(
        :final command,
        :final windowName,
        :final agentTool,
      ):
        _createNewWindow(
          command: command,
          name: windowName,
          agentTool: agentTool,
        );
      case TmuxNewAcpSessionAction(:final providerId):
        Navigator.pop(context, TmuxNewAcpSessionAction(providerId: providerId));
      default:
        throw StateError('Unexpected new-window picker action');
    }
  }

  @override
  Widget build(BuildContext context) {
    _projection = MuxWindowProjection(
      _windows ?? const [],
      widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux
          ? _watchedAcpManagerState.sessions
                .where(
                  (session) =>
                      session.key.hostId == widget.session.hostId &&
                      session.isOpenMuxWindow,
                )
                .toList()
          : const [],
      liveOrphansOnly: true,
    );

    final theme = Theme.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxSheetHeight = math.min(
      screenHeight * _tmuxNavigatorMaxHeightFactor,
      _tmuxNavigatorMaxHeightCap,
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.window_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'windows',
                    style: FluttyTheme.displayMono(
                      fontSize: 18,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Close window navigator',
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // Scrollable popup content
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (_isLoadingWindows)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                    )
                  else if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(FluttyTheme.spacingMd),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Could not load $_muxLabel windows.',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          const SizedBox(height: FluttyTheme.spacingSm),
                          OutlinedButton.icon(
                            onPressed: () => unawaited(_windowLoader.load()),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  else if (_windows != null && _windows!.isNotEmpty)
                    ..._windows!.map(_buildWindowTile),
                  if (widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux &&
                      (_windows?.isNotEmpty ?? false))
                    _buildMonkeyMuxShortcutHint(theme),
                  if (widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux)
                    _buildNativeAcpSessionSection(theme),
                  const Divider(height: 1),
                  // New Window button
                  ListTile(
                    visualDensity: _tmuxNavigatorDenseVisualDensity,
                    minTileHeight: 42,
                    contentPadding: _tmuxNavigatorTilePadding,
                    horizontalTitleGap: 12,
                    minLeadingWidth: 20,
                    leading: Icon(
                      Icons.add_circle_outline,
                      color: theme.colorScheme.primary,
                      size: 18,
                    ),
                    title: const Text('New window'),
                    dense: true,
                    onTap: () => unawaited(_showNewWindowPicker()),
                  ),
                  const Divider(height: 1),
                  if (widget.isProUser)
                    _buildRecentSessionsSection(theme)
                  else
                    _buildRecentSessionsUpgrade(theme),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNativeAcpSessionSection(ThemeData theme) {
    final entries = _projection.orphanSessions;
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'agent windows',
            style: FluttyTheme.monoStyle.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (var index = 0; index < entries.length; index++)
          _buildNativeAcpSessionTile(entries[index]),
      ],
    );
  }

  Widget _buildNativeAcpSessionTile(AcpSessionState session) => MuxWindowRow(
    key: ValueKey(('native-session', session.key)),
    presentation: MuxWindowPresentation.session(
      session,
      index: _projection.nativeIndices[session.key]!,
      isActive: false,
      includeProvider: true,
    ),
    onClose: () => unawaited(
      _confirmStopNativeAcpSession(
        session.key,
        acpSessionDisplayTitle(session),
      ),
    ),
    onTap: () => Navigator.pop(context, TmuxOpenAcpSessionAction(session.key)),
  );

  Future<void> _confirmStopNativeAcpSession(
    AcpSessionKey key,
    String title,
  ) async {
    final confirmed = await confirmMuxWindowClose(
      context: context,
      ref: ref,
      title: title,
    );
    if (!mounted || !confirmed) {
      return;
    }
    Navigator.pop(context, TmuxCloseAcpSessionAction(key));
  }

  Widget _buildMonkeyMuxShortcutHint(ThemeData theme) => Padding(
    key: const ValueKey('monkeymux-shortcut-hint'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
    child: Row(
      children: [
        Icon(
          Icons.keyboard_alt_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Ctrl-B: c new / n,p switch / 0-9 select / & then y close / d detach',
            style: FluttyTheme.monoStyle.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildWindowTile(TmuxWindow window) {
    final isActive = window.isActive;
    final nativeSession = _projection.sessionForWindow(window);
    final presentation = MuxWindowPresentation.window(
      window,
      session: nativeSession,
      isActive: isActive,
      showProgress: widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux,
    );
    return MuxWindowRow(
      key: ValueKey(('server-window', window.index)),
      presentation: presentation,
      onClose: () => unawaited(
        _confirmCloseWindow(window, displayTitle: presentation.title),
      ),
      onTap: window.isNativeAcp
          ? () => Navigator.pop(
              context,
              TmuxOpenAcpWindowAction(
                windowIndex: window.index,
                bridgeId: window.nativeAcpBridgeId!,
                providerId: window.nativeAcpProviderId!,
                workingDirectory: nativeSession?.cwd ?? window.currentPath,
              ),
            )
          : isActive
          ? () => Navigator.pop(context)
          : () => _switchToWindow(window),
    );
  }

  Widget _buildRecentSessionsUpgrade(ThemeData theme) => ListTile(
    key: const ValueKey('recent-terminal-sessions-upgrade'),
    dense: true,
    visualDensity: _tmuxNavigatorDenseVisualDensity,
    minTileHeight: 52,
    contentPadding: _tmuxNavigatorTilePadding,
    horizontalTitleGap: 12,
    minLeadingWidth: 18,
    leading: Icon(
      Icons.smart_toy_outlined,
      size: 18,
      color: theme.colorScheme.onSurfaceVariant,
    ),
    title: const Row(
      children: [
        Expanded(
          child: Text(
            'Recent terminal sessions',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(width: 8),
        PremiumBadge(),
      ],
    ),
    subtitle: const Text('Discover and resume agent work across windows'),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: () => Navigator.pop(
      context,
      const TmuxUpgradeAction(
        feature: MonetizationFeature.agentLaunchPresets,
        blockedAction: 'Discover and resume terminal agent sessions',
        blockedOutcome:
            'Unlock Pro to find recent agent sessions and jump back into them.',
      ),
    ),
  );

  Widget _buildRecentSessionsSection(ThemeData theme) =>
      MuxRecentSessionsSection(
        session: widget.session,
        tmuxSessionName: widget.tmuxSessionName,
        remoteMuxBackend: widget.remoteMuxBackend,
        scopeWorkingDirectory:
            widget.scopeWorkingDirectory ??
            resolveAgentSessionScopeWorkingDirectory(
              activeWorkingDirectory: _windows
                  ?.where((window) => window.isActive)
                  .firstOrNull
                  ?.currentPath,
              sessionWorkingDirectory: widget.session.workingDirectory,
            ),
        liveWindows: _windows ?? const [],
        isProUser: widget.isProUser,
        startClisInYoloMode: widget.startClisInYoloMode,
        preferredTool: _preferredLaunchTool,
        loadModePreference: () async => widget.agentWindowModePreference,
        logTelemetry: true,
        onAction: (action) => Navigator.pop(context, action),
        headerBuilder: (context, toggle, {required expanded}) => ListTile(
          dense: true,
          visualDensity: _tmuxNavigatorDenseVisualDensity,
          minTileHeight: 42,
          contentPadding: _tmuxNavigatorTilePadding,
          horizontalTitleGap: 12,
          minLeadingWidth: 18,
          leading: Icon(
            Icons.smart_toy_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: const Row(
            children: [
              Expanded(
                child: Text(
                  'Recent terminal sessions',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: 8),
              PremiumBadge(),
            ],
          ),
          trailing: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          onTap: toggle,
        ),
      );
}

/// Bottom sheet for picking an AI coding tool to launch in a new tmux window.
class TmuxToolPickerSheet extends StatelessWidget {
  /// Creates a new [TmuxToolPickerSheet].
  const TmuxToolPickerSheet({
    required this.onToolSelected,
    required this.onEmptyWindow,
    this.onToolLongPressed,
    this.installedToolsFuture,
    this.preferredTool,
    this.nativeAcpTools = const <AgentLaunchTool>{},
    super.key,
  });

  /// Future that resolves to the set of agent CLIs detected on the remote
  /// host, or `null` if the caller could not initiate detection. While the
  /// future is pending the picker shows a loading indicator. Once it
  /// completes, only the detected tools are listed; if it resolves to an
  /// empty set (or fails), no CLI tools are shown but "Empty window"
  /// remains available.
  final Future<Set<AgentLaunchTool>>? installedToolsFuture;

  /// Host-configured preferred tool, if one exists.
  final AgentLaunchTool? preferredTool;

  /// Tools that can launch either a terminal window or a native ACP session.
  final Set<AgentLaunchTool> nativeAcpTools;

  /// Called when the user selects a tool.
  final void Function(AgentLaunchTool tool) onToolSelected;

  /// Called when the user holds an ACP-capable tool for a one-off choice.
  final void Function(AgentLaunchTool tool)? onToolLongPressed;

  /// Called when the user selects an empty window.
  final VoidCallback onEmptyWindow;

  /// All tools that can be shown in the picker, in display order.
  static const _allTools = AgentLaunchTool.uiDisplayOrder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final viewInsets = mediaQuery.viewInsets;
    final visibleHeight = screenHeight > viewInsets.bottom
        ? screenHeight - viewInsets.bottom
        : screenHeight;
    final preferredSheetHeight = math.min(
      screenHeight * _tmuxToolPickerMaxHeightFactor,
      _tmuxToolPickerMaxHeightCap,
    );
    final maxSheetHeight = math.min(visibleHeight, preferredSheetHeight);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('New window', style: theme.textTheme.titleMedium),
                ),
                FutureBuilder<Set<AgentLaunchTool>>(
                  future: installedToolsFuture,
                  builder: (context, snapshot) {
                    if (installedToolsFuture != null &&
                        snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Detecting installed CLIs…',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final Iterable<AgentLaunchTool> availableTools;
                    if (installedToolsFuture == null) {
                      availableTools = _allTools;
                    } else if (snapshot.hasError) {
                      availableTools = const <AgentLaunchTool>[];
                    } else {
                      final installed =
                          snapshot.data ?? const <AgentLaunchTool>{};
                      availableTools = _allTools.where(installed.contains);
                    }
                    final tools = _orderedAgentLaunchTools(
                      availableTools,
                      preferredTool: preferredTool,
                    );
                    if (tools.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Text(
                          'No supported CLIs found on PATH.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final tool in tools)
                          ListTile(
                            visualDensity: _tmuxNavigatorDenseVisualDensity,
                            minTileHeight: 42,
                            contentPadding: _tmuxNavigatorTilePadding,
                            horizontalTitleGap: 12,
                            minLeadingWidth: 20,
                            leading: TmuxToolPickerSheet._iconForTool(
                              tool,
                              theme,
                            ),
                            title: Text(tool.label),
                            trailing: nativeAcpTools.contains(tool)
                                ? IconButton(
                                    key: ValueKey(
                                      'agent-window-mode-options-${tool.name}',
                                    ),
                                    tooltip: 'Choose window mode',
                                    onPressed: onToolLongPressed == null
                                        ? null
                                        : () => onToolLongPressed!(tool),
                                    constraints: const BoxConstraints.tightFor(
                                      width: 36,
                                      height: 36,
                                    ),
                                    padding: EdgeInsets.zero,
                                    iconSize: 18,
                                    color: theme.colorScheme.primary,
                                    icon: const Icon(Icons.more_horiz_rounded),
                                  )
                                : null,
                            onTap: () => onToolSelected(tool),
                            onLongPress:
                                nativeAcpTools.contains(tool) &&
                                    onToolLongPressed != null
                                ? () => onToolLongPressed!(tool)
                                : null,
                          ),
                      ],
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  visualDensity: _tmuxNavigatorDenseVisualDensity,
                  minTileHeight: 42,
                  contentPadding: _tmuxNavigatorTilePadding,
                  horizontalTitleGap: 12,
                  minLeadingWidth: 20,
                  leading: Icon(
                    Icons.terminal,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 18,
                  ),
                  title: const Text('Empty terminal'),
                  onTap: onEmptyWindow,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _iconForTool(AgentLaunchTool tool, ThemeData theme) =>
      AgentToolIcon(tool: tool, color: theme.colorScheme.primary);
}

class _TmuxNewWindowMenuItem extends StatelessWidget {
  const _TmuxNewWindowMenuItem({required this.icon, required this.label});

  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(width: 24, child: Center(child: icon)),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );
}

/// Projects tracked sessions once, keeping synthetic window numbers stable.
class MuxWindowProjection {
  /// Creates the lookups and orders sessions by creation time and identity.
  MuxWindowProjection(
    List<TmuxWindow> windows,
    List<AcpSessionState> sessions, {
    bool liveOrphansOnly = false,
  }) {
    for (final session in sessions) {
      sessionsByBridge[(session.key.bridgeId, session.key.providerId)] =
          session;
    }
    final serverBridges = <String>{};
    var nextIndex = 0;
    for (final window in windows) {
      nextIndex = math.max(nextIndex, window.index + 1);
      final bridge = window.nativeAcpBridgeId;
      if (bridge != null) {
        serverBridges.add(bridge);
        final session = sessionForWindow(window);
        if (session != null) nativeIndices[session.key] = window.index;
      }
    }
    orphanSessions =
        sessions
            .where(
              (session) =>
                  !serverBridges.contains(session.key.bridgeId) &&
                  (!liveOrphansOnly || session.isLive),
            )
            .toList()
          ..sort((a, b) {
            final created = a.createdAt.compareTo(b.createdAt);
            return created != 0 ? created : a.key.value.compareTo(b.key.value);
          });
    for (final session in orphanSessions) {
      nativeIndices[session.key] = nextIndex++;
    }
  }

  /// Sessions keyed by the identity supplied by server windows.
  final sessionsByBridge = <(String, String), AcpSessionState>{};

  /// Native sessions without a server window, in stable display order.
  late final List<AcpSessionState> orphanSessions;

  /// Server or synthetic window index for each tracked session.
  final nativeIndices = <AcpSessionKey, int>{};

  /// Resolves native activity without scanning the session list per row.
  AcpSessionState? sessionForWindow(TmuxWindow window) =>
      sessionsByBridge[(window.nativeAcpBridgeId, window.nativeAcpProviderId)];
}

/// The identity, activity and text rendered by either expanded window list.
class MuxWindowPresentation {
  /// Projects a server window, optionally substituting store screenshot text.
  MuxWindowPresentation.window(
    TmuxWindow this.window, {
    required this.isActive,
    this.session,
    bool showProgress = true,
    String? displayTitle,
  }) : index = window.index,
       title =
           displayTitle ??
           (session == null
               ? window.displayTitle
               : acpSessionDisplayTitle(session)),
       subtitle = displayTitle != null
           ? null
           : session == null
           ? window.secondaryTitle
           : '${session.providerLabel} · ${acpCwdSummary(session.cwd)} · ${acpSessionActivityDisplay(session).label}',
       progress = !showProgress
           ? null
           : session == null
           ? window.terminalProgress
           : acpActivityTerminalProgress(acpSessionActivityDisplay(session));

  /// Projects a tracked native session that has no server window.
  MuxWindowPresentation.session(
    AcpSessionState this.session, {
    required this.index,
    required this.isActive,
    bool includeProvider = false,
  }) : window = null,
       title = acpSessionDisplayTitle(session),
       subtitle =
           '${includeProvider ? '${session.providerLabel} · ' : ''}${acpCwdSummary(session.cwd)} · ${acpSessionActivityDisplay(session).label}',
       progress = acpActivityTerminalProgress(
         acpSessionActivityDisplay(session),
       );

  /// Server window, when one exists.
  final TmuxWindow? window;

  /// Tracked native session, when available.
  final AcpSessionState? session;

  /// Displayed window number.
  final int index;

  /// Whether the parent currently selects this row.
  final bool isActive;

  /// Primary label.
  final String title;

  /// Optional secondary label.
  final String? subtitle;

  /// Progress reported by native activity or the terminal.
  final TerminalProgress? progress;

  /// Whether this is a native agent window.
  bool get isNative => session != null || (window?.isNativeAcp ?? false);

  /// Agent identity used for the icon.
  AgentLaunchTool? get tool => isNative
      ? agentLaunchToolForAcpProviderId(
          session?.key.providerId ?? window!.nativeAcpProviderId!,
        )
      : window?.foregroundAgentTool;
}

/// Shared expanded row, with the bar's smaller spacing and touch controls.
class MuxWindowRow extends StatelessWidget {
  /// Creates a window row; parents retain navigation and close ownership.
  const MuxWindowRow({
    required this.presentation,
    required this.onTap,
    required this.onClose,
    this.inBar = false,
    super.key,
  });

  /// Projected window content.
  final MuxWindowPresentation presentation;

  /// Selects or dismisses the row in its parent.
  final VoidCallback onTap;

  /// Runs the parent's confirmation and close action.
  final VoidCallback onClose;

  /// Uses the compact persistent-bar layout.
  final bool inBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = presentation;
    final orphan = p.window == null;
    final identity = orphan ? p.session!.key.value : '${p.index}';
    final prefix = orphan
        ? (inBar ? 'monkeymux-acp' : 'native-acp')
        : (inBar ? 'monkeymux-window' : 'tmux-window');
    final iconColor = agentWindowIdentityColor(
      theme.colorScheme,
      isActive: p.isActive,
    );
    final secondaryColor = theme.colorScheme.onSurfaceVariant;
    final surface = inBar
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surfaceContainerHighest;
    final numberSize = inBar ? 22.0 : 24.0;
    final iconSize = inBar && orphan ? 17.0 : 16.0;
    final icon = AgentToolIcon(
      key: ValueKey('$prefix-agent-icon-$identity'),
      tool: p.tool,
      size: iconSize,
      color: iconColor,
      fallbackIcon: p.isNative ? Icons.smart_toy_outlined : Icons.terminal,
    );
    final badgeKey = orphan
        ? '$prefix-${inBar ? 'native' : 'indicator'}-$identity'
        : '${inBar ? 'monkeymux-native-badge' : 'native-acp-window-indicator'}-$identity';
    final progressKey = orphan
        ? '$prefix-progress-$identity'
        : '${inBar ? 'monkeymux-window' : 'native-acp-window'}-progress-$identity';
    return ListTile(
      key: ValueKey(
        orphan && !inBar ? 'native-acp-session-$identity' : '$prefix-$identity',
      ),
      dense: true,
      visualDensity: inBar && orphan ? null : _tmuxNavigatorDenseVisualDensity,
      minVerticalPadding: inBar && orphan ? null : 2,
      minTileHeight: inBar && orphan ? 44 : null,
      selected: inBar && orphan && p.isActive,
      selectedTileColor: theme.colorScheme.primaryContainer.withAlpha(96),
      contentPadding: EdgeInsets.only(left: inBar ? 12 : 16, right: 4),
      horizontalTitleGap: 10,
      minLeadingWidth: inBar ? 24 : 28,
      tileColor: !orphan && p.isActive
          ? theme.colorScheme.primaryContainer.withAlpha(80)
          : null,
      shape: orphan
          ? null
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Container(
        key: orphan ? ValueKey('$prefix-number-slot-$identity') : null,
        width: numberSize,
        height: numberSize,
        decoration: BoxDecoration(
          color: !orphan && p.isActive ? theme.colorScheme.primary : surface,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(
          '${p.index}',
          style:
              (inBar && !orphan
                      ? theme.textTheme.labelSmall
                      : theme.textTheme.labelMedium)
                  ?.copyWith(
                    color: !orphan && p.isActive
                        ? theme.colorScheme.onPrimary
                        : inBar && orphan
                        ? iconColor
                        : secondaryColor,
                    fontWeight: FontWeight.bold,
                  ),
        ),
      ),
      title: Row(
        children: [
          if (p.isNative)
            AcpNativeBadgeOverlay(
              size: iconSize,
              color: iconColor,
              badgeKey: ValueKey(badgeKey),
              child: icon,
            )
          else
            icon,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              p.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.isActive
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    )
                  : null,
            ),
          ),
        ],
      ),
      subtitle: p.subtitle == null && p.progress == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.subtitle != null)
                  Text(
                    p.subtitle!,
                    key: !inBar ? ValueKey('$prefix-subtitle-$identity') : null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: secondaryColor,
                    ),
                  ),
                if (p.progress != null) ...[
                  if (p.subtitle != null) const SizedBox(height: 3),
                  MuxWindowProgressIndicator(
                    key: ValueKey(progressKey),
                    progress: p.progress!,
                    semanticsWindowLabel: orphan
                        ? 'Native agent window: ${p.title}'
                        : p.isActive
                        ? null
                        : '${inBar ? 'MonkeyMux' : 'Terminal'} window ${p.index}: ${p.title}',
                  ),
                ],
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: p.isNative
                ? AcpMuxWindowStatusBadge(
                    session: p.session,
                    fallbackLabel: orphan ? 'recent' : 'native',
                  )
                : TmuxWindowStatusBadge(window: p.window!),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(
              width: inBar ? 30 : 44,
              height: inBar ? 30 : 44,
            ),
            padding: EdgeInsets.zero,
            tooltip: 'Close window',
            onPressed: onClose,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Accessible progress shared by expanded rows and the compact rail.
class MuxWindowProgressIndicator extends StatelessWidget {
  /// Creates a progress indicator with optional window semantics.
  const MuxWindowProgressIndicator({
    required this.progress,
    required this.semanticsWindowLabel,
    this.compact = false,
    super.key,
  });

  /// Reported progress state and percentage.
  final TerminalProgress progress;

  /// Window label, omitted for the active window.
  final String? semanticsWindowLabel;

  /// Uses the thinner rail indicator.
  final bool compact;

  String get _progressLabel => switch (progress.state) {
    TerminalProgressState.normal => 'progress',
    TerminalProgressState.error => 'progress, error',
    TerminalProgressState.indeterminate => 'progress, indeterminate',
    TerminalProgressState.pausedOrWarning => 'progress, paused or warning',
  };

  Color _color(ColorScheme colorScheme) => switch (progress.state) {
    TerminalProgressState.normal ||
    TerminalProgressState.indeterminate => colorScheme.primary,
    TerminalProgressState.error => colorScheme.error,
    TerminalProgressState.pausedOrWarning => colorScheme.tertiary,
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final percentage = progress.percentage;
    final hasPercentage = percentage != null;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final indicatorValue = hasPercentage
        ? progress.fraction
        : (disableAnimations ? 0.5 : null);

    final indicator = ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: indicatorValue,
          minHeight: compact ? 2 : 3,
          color: _color(colorScheme),
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
      ),
    );
    final windowLabel = semanticsWindowLabel;
    if (windowLabel == null) {
      return indicator;
    }
    return Semantics(
      label: '$windowLabel, $_progressLabel',
      value: hasPercentage ? '$percentage' : null,
      minValue: hasPercentage ? '0' : null,
      maxValue: hasPercentage ? '100' : null,
      role: hasPercentage
          ? SemanticsRole.progressBar
          : SemanticsRole.loadingSpinner,
      child: indicator,
    );
  }
}

/// Retains lazy history discovery and resolves resume modes for both window lists.
class MuxRecentSessionsSection extends ConsumerStatefulWidget {
  /// Creates a history section whose header and dismissal belong to its parent.
  const MuxRecentSessionsSection({
    required this.session,
    required this.tmuxSessionName,
    required this.remoteMuxBackend,
    required this.scopeWorkingDirectory,
    required this.liveWindows,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.loadModePreference,
    required this.onAction,
    required this.headerBuilder,
    this.preferredTool,
    this.inBar = false,
    this.logTelemetry = false,
    super.key,
  });

  /// SSH connection used for discovery.
  final SshSession session;

  /// Multiplexer session identity.
  final String tmuxSessionName;

  /// Backend that supplies the live windows.
  final RemoteMuxBackend remoteMuxBackend;

  /// Effective directory after applying the parent's explicit scope.
  final String? scopeWorkingDirectory;

  /// Current server windows, including high-confidence agent identities.
  final List<TmuxWindow> liveWindows;

  /// Whether native resume is available to this user.
  final bool isProUser;

  /// Preserves the user's CLI launch preference.
  final bool startClisInYoloMode;

  /// Reads the current preferred mode when a session is selected.
  final Future<AgentWindowModePreference> Function() loadModePreference;

  /// Delivers a resolved resume action for parent-specific dismissal.
  final ValueChanged<TmuxNavigatorAction> onAction;

  /// Builds the parent's header around shared expansion state.
  final Widget Function(
    BuildContext,
    VoidCallback toggle, {
    required bool expanded,
  })
  headerBuilder;

  /// Preferred tool appears first in the provider list.
  final AgentLaunchTool? preferredTool;

  /// Uses the persistent bar's provider spacing.
  final bool inBar;

  /// Retains the navigator's existing history telemetry.
  final bool logTelemetry;

  @override
  ConsumerState<MuxRecentSessionsSection> createState() =>
      _MuxRecentSessionsSectionState();
}

class _MuxRecentSessionsSectionState
    extends ConsumerState<MuxRecentSessionsSection> {
  bool _expanded = false;
  bool _initialized = false;
  AgentSessionDiscoveryService get _discovery =>
      ref.read(agentSessionDiscoveryServiceProvider);

  @override
  void didUpdateWidget(covariant MuxRecentSessionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.connectionId != widget.session.connectionId ||
        oldWidget.tmuxSessionName != widget.tmuxSessionName) {
      _expanded = false;
      _initialized = false;
    }
  }

  List<ToolSessionInfo> _liveMonkeyMuxAgentSessions({String? toolName}) {
    if (widget.remoteMuxBackend != RemoteMuxBackend.monkeyMux) {
      return const <ToolSessionInfo>[];
    }

    final sessions = <ToolSessionInfo>[];
    for (final window in widget.liveWindows) {
      final tool = window.foregroundAgentTool;
      final discoveredToolName = tool?.discoveredSessionToolName;
      final sessionId = window.activeAgentSessionId?.trim();
      if (tool == null ||
          discoveredToolName == null ||
          window.activeAgentSessionConfidence != AgentSessionConfidence.high ||
          sessionId == null ||
          sessionId.isEmpty ||
          (toolName != null && discoveredToolName != toolName)) {
        continue;
      }
      final lastActivityEpochSeconds = window.lastActivityEpochSeconds;
      sessions.add(
        ToolSessionInfo(
          toolName: discoveredToolName,
          sessionId: sessionId,
          workingDirectory: window.currentPath,
          lastActive: lastActivityEpochSeconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  lastActivityEpochSeconds * 1000,
                ),
          summary:
              window.agentSessionDisplayTitle ?? 'Active ${tool.label} session',
        ),
      );
    }
    return sessions;
  }

  DiscoveredSessionsResult _includeLiveMonkeyMuxAgentSessions(
    DiscoveredSessionsResult result, {
    String? toolName,
  }) {
    final filteredResult = toolName == null
        ? result
        : DiscoveredSessionsResult(
            sessions: result.sessions.where(
              (session) => session.toolName == toolName,
            ),
            failedTools: result.failedTools.where((tool) => tool == toolName),
            attemptedTools: result.attemptedTools.where(
              (tool) => tool == toolName,
            ),
          );
    final liveSessions = _liveMonkeyMuxAgentSessions(toolName: toolName);
    if (liveSessions.isEmpty) return filteredResult;

    final sessionsByIdentity = <String, ToolSessionInfo>{
      for (final session in liveSessions)
        '${session.toolName}\u001f${session.sessionId}': session,
    };
    // Prefer file-discovered metadata when it exists because it usually has a
    // richer title. Live MonkeyMux identity fills the gap when history scanning
    // is empty or still in flight.
    for (final session in filteredResult.sessions) {
      sessionsByIdentity['${session.toolName}\u001f${session.sessionId}'] =
          session;
    }
    final sessions = sessionsByIdentity.values.toList(growable: false);
    final liveTools = liveSessions.map((session) => session.toolName).toSet();
    return DiscoveredSessionsResult(
      sessions: sessions,
      failedTools: filteredResult.failedTools.where(
        (tool) => !liveTools.contains(tool),
      ),
      attemptedTools: <String>{...filteredResult.attemptedTools, ...liveTools},
    );
  }

  Future<void> _resumeSession(
    ToolSessionInfo info, {
    bool forceModePicker = false,
  }) async {
    final tool = AgentLaunchTool.values
        .where((candidate) => candidate.label == info.toolName)
        .firstOrNull;
    final providerId = tool == null
        ? null
        : builtinNativeAcpProvidersByTool()[tool];
    if (tool != null &&
        providerId != null &&
        widget.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      final preference = await widget.loadModePreference();
      if (!mounted) return;
      final mode = await resolveAgentWindowMode(
        context: context,
        tool: tool,
        isProUser: widget.isProUser,
        preference: preference,
        forcePicker: forceModePicker,
      );
      if (!mounted || mode == null) {
        return;
      }
      if (mode == AgentWindowMode.nativeAcp) {
        widget.onAction(
          TmuxResumeAcpSessionAction(
            providerId: providerId,
            acpSessionId: info.sessionId,
            workingDirectory: info.workingDirectory,
          ),
        );
        return;
      }
    }
    final command = _discovery.buildResumeCommand(
      info,
      startInYoloMode: widget.startClisInYoloMode,
    );
    widget.onAction(
      TmuxResumeSessionAction(command, workingDirectory: info.workingDirectory),
    );
  }

  Future<void> _showSessionPickerForTool(
    AiSessionProviderEntry provider,
  ) async {
    if (widget.logTelemetry) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logSessionHistoryOpened(
              tool: _telemetryAgentToolName(provider.toolName),
              sessionCount: 0,
            ),
      );
    }
    ToolSessionInfo? heldSession;
    final selected = await showAiSessionPickerDialog(
      context: context,
      toolName: provider.toolName,
      initialMaxSessions: widget.inBar ? 12 : 16,
      sessionFetchStep: widget.inBar ? 12 : 16,
      loadSessions: (maxSessions) => _discovery
          .discoverSessionsStream(
            widget.session,
            workingDirectory: widget.scopeWorkingDirectory,
            maxPerTool: maxSessions,
            toolName: provider.toolName,
          )
          .map(
            (result) => _includeLiveMonkeyMuxAgentSessions(
              result,
              toolName: provider.toolName,
            ),
          ),
      onSessionLongPress: (session) => heldSession = session,
    );
    final session = heldSession ?? selected;
    if (!mounted || session == null) return;
    await _resumeSession(session, forceModePicker: heldSession != null);
  }

  Stream<DiscoveredSessionsResult> _loadSessions(int maxSessions) {
    final loggedTools = <String>{};
    return _discovery
        .discoverSessionsStream(
          widget.session,
          workingDirectory: widget.scopeWorkingDirectory,
          maxPerTool: maxSessions,
        )
        .map((result) {
          final merged = _includeLiveMonkeyMuxAgentSessions(result);
          if (widget.logTelemetry) {
            for (final toolName in merged.attemptedTools) {
              if (!loggedTools.add(toolName)) continue;
              unawaited(
                ref
                    .read(telemetryServiceProvider)
                    .logAgentSessionsDetected(
                      tool: _telemetryAgentToolName(toolName),
                      sessionCount: merged.sessions
                          .where((session) => session.toolName == toolName)
                          .length,
                      failed: merged.failedTools.contains(toolName),
                    ),
              );
            }
          }
          return merged;
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.headerBuilder(context, () {
          if (!_expanded && widget.logTelemetry) {
            unawaited(
              ref
                  .read(telemetryServiceProvider)
                  .logSessionHistoryOpened(tool: 'all', sessionCount: 0),
            );
          }
          setState(() {
            _expanded = !_expanded;
            _initialized = _initialized || _expanded;
          });
        }, expanded: _expanded),
        if (_initialized)
          Offstage(
            offstage: !_expanded,
            child: AiSessionProviderList(
              key: ValueKey((
                widget.session.connectionId,
                widget.tmuxSessionName,
                widget.scopeWorkingDirectory,
              )),
              orderedTools: orderedDiscoveredSessionTools(
                const <String, List<ToolSessionInfo>>{},
                const <String>{},
                preferredToolName:
                    widget.preferredTool?.discoveredSessionToolName,
              ),
              loadSessions: _loadSessions,
              itemBuilder: (context, provider) => AiSessionProviderTile(
                provider: provider,
                onTap: () => unawaited(_showSessionPickerForTool(provider)),
                visualDensity: _tmuxNavigatorDenseVisualDensity,
                contentPadding: widget.inBar
                    ? const EdgeInsets.only(left: 52, right: 12)
                    : _tmuxNavigatorGroupTilePadding,
                minLeadingWidth: widget.inBar ? 18 : 20,
                iconSize: widget.inBar ? 16 : 20,
                iconColor: widget.inBar && provider.hasFailure
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }
}
