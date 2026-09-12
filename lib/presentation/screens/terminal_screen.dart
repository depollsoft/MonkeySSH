import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show SemanticsRole;

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/app_metadata.dart';
import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/acp_native_preview.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_recent_session.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_runtime_info.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/host_cli_launch_preferences.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/terminal_capability_hint.dart';
import '../../domain/models/terminal_progress.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/acp_launch_profile_service.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/app_review_demo_service.dart';
import '../../domain/services/clipboard_content_service.dart';
import '../../domain/services/device_debug_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/monkeymux_service.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/remote_clipboard_sync_service.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/remote_multiplexer_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/shell_completion_service.dart';
import '../../domain/services/ssh_error_policy.dart';
import '../../domain/services/ssh_exec_queue.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/terminal_connection_backend_service.dart';
import '../../domain/services/terminal_hyperlink_tracker.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/terminal_wake_lock_service.dart';
import '../../domain/services/tmux_service.dart';
import '../controllers/system_keyboard_visibility_controller.dart';
import '../controllers/terminal_session_controller.dart';
import '../models/app_platform_file.dart';
import '../widgets/acp_composer.dart';
import '../widgets/acp_concurrency_choice.dart';
import '../widgets/acp_connection_support.dart';
import '../widgets/acp_native_badge.dart';
import '../widgets/acp_native_starting_view.dart';
import '../widgets/acp_new_session_sheet.dart';
import '../widgets/acp_session_presentation.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/agent_usage_rings.dart';
import '../widgets/agent_usage_rings_menu_item.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/connection_attempt_dialog.dart';
import '../widgets/cursor_block.dart';
import '../widgets/device_debug_sheet.dart';
import '../widgets/keyboard_toolbar.dart';
import '../widgets/monkey_terminal_view.dart';
import '../widgets/premium_access.dart';
import '../widgets/premium_badge.dart';
import '../widgets/system_bottom_inset.dart';
import '../widgets/terminal_menu_style.dart';
import '../widgets/terminal_overlay_focus.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_port_forwards_sheet.dart';
import '../widgets/terminal_selection_text.dart' as terminal_selection_text;
import '../widgets/terminal_text_input_handler.dart';
import '../widgets/terminal_text_style.dart';
import '../widgets/terminal_theme_picker.dart';
import '../widgets/tmux_window_navigator.dart';
import 'agent_chat_screen.dart';
import 'agent_management_screen.dart';
import 'port_forward_browser_screen.dart';
import 'sftp_screen.dart';
import 'snippet_edit_screen.dart';

part '../widgets/tmux_expandable_bar.dart';

bool _isPromptReturnWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);
const _hideStoreScreenshotKeyboardToolbar = bool.fromEnvironment(
  'STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR',
);
const _storeDemoImageB64 = String.fromEnvironment(
  'STORE_SCREENSHOT_DEMO_IMAGE_B64',
);
const _storeDemoImageFallbackB64 =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAUCAIAAABj86gYAAABL0lEQVR42mMUCZjGQEvAwsLCTA8LHi9PprrRspFzUXygGLuAiqbfX5wAMRlhAdlhdbvxGoShWq+FGjjUsOB67WVkmzSbdalpweXKC5j26bYbUNMH2JINioFMLCzMMKuYcaE7a1qxiuOyANlAwhbcWNHEwMBwY0UTppTlZEs00y0nW5JmwZUl9XDNV5bUYypQj3wBV2A73QbZczA27jg4M6cSTeTCghqTlHY499m+lQwMDOqRL6ScwhkYGFhYsEQGTh9gmg63lYWF+dm+lRDT4TY927cSLXrwBdGJGWV40smjXctwiRNlwZEpxbiMllIykFIywGP3vW2LCVhwYEIBHtOJyQe3Ni3AacGenlzyHI4Grq2bq26diG7Bjo4sShyOCS6tmsXCwswYM+PM0K7RANQPWfSOBI5gAAAAAElFTkSuQmCC';
final _storeDemoClipboardImageBytes = base64Decode(
  _storeDemoImageB64.isNotEmpty
      ? _storeDemoImageB64
      : _storeDemoImageFallbackB64,
);

/// Armed by the store video harness before a `pasteDemoImage=1` navigation.
///
/// Completed when the demo clipboard image has been uploaded and its remote
/// path inserted into the terminal, so the harness can wait instead of racing
/// a fixed delay.
Completer<void>? storeDemoImagePasteCompleter;

bool _isPromptReturnAsciiLetterOrDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

/// Minimum tmux handle touch target used by the collapsed window bar.
@visibleForTesting
const double tmuxHandleMinTouchExtent = 44;

/// Returns a short, user-facing label for the terminal connection state.
@visibleForTesting
String describeTerminalConnectionState(
  SshConnectionState state, {
  required bool isConnecting,
}) {
  if (isConnecting &&
      (state == SshConnectionState.disconnected ||
          state == SshConnectionState.connecting)) {
    return 'Connecting';
  }

  switch (state) {
    case SshConnectionState.connected:
      return 'Connected';
    case SshConnectionState.connecting:
      return 'Connecting';
    case SshConnectionState.authenticating:
      return 'Authenticating';
    case SshConnectionState.reconnecting:
      return 'Reconnecting';
    case SshConnectionState.error:
      return 'Connection error';
    case SshConnectionState.disconnected:
      return 'Disconnected';
  }
}

/// Whether a completed MonkeyMux startup should return to a usable login shell.
@visibleForTesting
bool shouldFallbackFromUnestablishedMonkeyMuxAttach({
  required bool reconnectAttempt,
  required bool attachEstablished,
}) => !reconnectAttempt && !attachEstablished;

/// Formats the remote host and session identity shown in the terminal title.
@visibleForTesting
String? formatTerminalConnectionIdentity({
  required String? username,
  required String? hostname,
  required int? port,
  required int? connectionId,
}) {
  final trimmedUsername = username?.trim();
  final trimmedHostname = hostname?.trim();
  final hasUsername = trimmedUsername != null && trimmedUsername.isNotEmpty;
  final hasHostname = trimmedHostname != null && trimmedHostname.isNotEmpty;
  final hostIdentity = hasHostname
      ? '${hasUsername ? '$trimmedUsername@' : ''}$trimmedHostname'
      : null;
  final hostWithPort = hostIdentity == null
      ? null
      : port == null || port == 22
      ? hostIdentity
      : '$hostIdentity:$port';
  final sessionLabel = connectionId == null ? null : 'session #$connectionId';

  if (hostWithPort == null) {
    return sessionLabel;
  }
  if (sessionLabel == null) {
    return hostWithPort;
  }
  return '$hostWithPort · $sessionLabel';
}

/// Resolves the user-visible text for a tmux alert notification.
@visibleForTesting
({String title, String body}) resolveTmuxAlertNotificationContent({
  required String tmuxSessionName,
  required TmuxWindow window,
  required Iterable<TmuxWindow> windows,
}) {
  final sessionName = _tmuxAlertNotificationLabel(tmuxSessionName);
  final title = sessionName.isEmpty
      ? 'tmux alert'
      : 'tmux alert · $sessionName';
  final windowTitle = _tmuxAlertNotificationLabel(window.displayTitle);
  if (windowTitle.isEmpty) {
    return (title: title, body: 'Window #${window.index} needs attention');
  }

  final normalizedWindowTitle = windowTitle.toLowerCase();
  var matchingTitleCount = 0;
  for (final candidate in windows) {
    final candidateTitle = _tmuxAlertNotificationLabel(
      candidate.displayTitle,
    ).toLowerCase();
    if (candidateTitle != normalizedWindowTitle) {
      continue;
    }
    matchingTitleCount += 1;
    if (matchingTitleCount > 1) {
      return (title: title, body: '$windowTitle (window #${window.index})');
    }
  }

  return (title: title, body: windowTitle);
}

String _tmuxAlertNotificationLabel(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Resolves how much vertical space the tmux bar can safely expand into.
@visibleForTesting
double resolveTmuxBarMaxContentHeight(
  double availableHeight, {
  double handleHeight = tmuxHandleMinTouchExtent,
  double reservedPadding = 8,
  double fallbackAvailableHeight = 0,
}) {
  const maxHeightFactor = 0.68;
  const maxHeightCap = 400.0;
  final minimumExpandableHeight = handleHeight + reservedPadding;
  final effectiveAvailableHeight = availableHeight > minimumExpandableHeight
      ? availableHeight
      : fallbackAvailableHeight;
  final rawHeight = max(
    0,
    effectiveAvailableHeight - handleHeight - reservedPadding,
  ).toDouble();
  return min(
    rawHeight,
    min(effectiveAvailableHeight * maxHeightFactor, maxHeightCap),
  );
}

const _tmuxBarRevealDuration = Duration(milliseconds: 300);
const _monkeyMuxResizeRedrawFollowUpDelay = Duration(milliseconds: 220);
// Bounds how often a mismatched shared grid is re-asserted, so a peer client
// that legitimately owns a different grid cannot start a resize tug-of-war.
const _monkeyMuxHostGridReconcileLimit = 3;
// Bounds how often an empty pane is escalated to a forced redraw, so a pane the
// user genuinely cleared cannot loop.
const _monkeyMuxBlankPaneRecoveryLimit = 2;
const _appResumeTerminalMetricsSettleDelay = Duration(milliseconds: 350);
const _monkeyMuxSettledRedrawDisplayRefreshDelays = <Duration>[
  Duration(milliseconds: 450),
  Duration(milliseconds: 850),
  Duration(milliseconds: 1300),
  Duration(milliseconds: 1900),
];
// Pinch-zoom emits a resize every frame. Keep the local zoom immediate, but
// limit remote MonkeyMux resize traffic to the rate each transport can tolerate:
// a live control channel can feel smooth at ~30fps, while one-shot SSH exec
// fallback needs a slower cadence to avoid flooding the connection.
const _monkeyMuxLiveResizeSyncMinGap = Duration(milliseconds: 32);
const _monkeyMuxFallbackResizeSyncMinGap = Duration(milliseconds: 70);
const _monkeyMuxPostRedrawDisplayRefreshDelay = Duration(milliseconds: 120);
// After the terminal settles, ask the MonkeyMux server to replay any Kitty
// images referenced by on-screen placeholder cells that the client never
// received. Debounced so an agent redrawing or scrolling many image cells sends
// at most one request per settle rather than one per output frame.
const _missingImageRecoveryDebounce = Duration(milliseconds: 350);
const _missingImageRecoveryRetryDelay = Duration(milliseconds: 750);
const _missingImageRecoveryRetryLimit = 3;
// After a multiplexer window switch, sample the live render object's paint/
// change counters once the redraw has had time to arrive, then force a repaint.
// A second, later force catches a redraw that lands after the first sample.
const _muxWindowRefreshProbeDelay = Duration(milliseconds: 250);
const _muxWindowRefreshSafetyNetDelay = Duration(milliseconds: 500);
const _terminalOverflowMenuScreenPadding = TerminalMenuStyles.screenMargin;
const _terminalOverflowMenuMinWidth = 2.0 * 56.0;
const _terminalOverflowMenuMaxWidth = 5.0 * 56.0;
const _tmuxDetectionRetrySchedule = <Duration>[
  Duration.zero,
  Duration(milliseconds: 150),
  Duration(milliseconds: 350),
  Duration(milliseconds: 700),
  Duration(milliseconds: 1400),
  Duration(milliseconds: 2800),
  Duration(milliseconds: 5600),
];
const _shellCompletionDebounce = Duration(milliseconds: 220);
const _shellCompletionMaxAnchorRetries = 2;
const _shellCompletionTmuxContextTtl = Duration(seconds: 5);
const _shellCompletionShellCommands = <String>{
  'ash',
  'bash',
  'cmd',
  'csh',
  'dash',
  'elvish',
  'fish',
  'ion',
  'ksh',
  'ksh93',
  'mksh',
  'nu',
  'oil',
  'osh',
  'powershell',
  'pwsh',
  'sh',
  'tcsh',
  'xonsh',
  'yash',
  'zsh',
};

class _ClipboardUploadTarget {
  const _ClipboardUploadTarget({
    required this.sftpDirectory,
    required this.windows,
  });

  final String sftpDirectory;
  final bool windows;

  SftpFileMode? get directoryMode => windows ? null : remoteUploadDirectoryMode;

  bool get applyPrivateFileMode => !windows;

  String terminalPathForSftpPath(String sftpPath) =>
      remoteShellPathForSftpPath(sftpPath, windows: windows);
}

typedef _TerminalPasteMode = ({
  String? activeWindowKey,
  bool bracketedPasteMode,
  bool bracketedPasteModeKnown,
  int? connectionId,
  bool isMuxActive,
  RemoteMuxBackend muxBackend,
  String? muxSessionName,
  bool refreshAttempted,
  bool refreshSucceeded,
  SshSession? session,
  Terminal terminal,
});

typedef _AttachmentPasteResult = ({int requestedCount, int sentCount});
typedef _PendingMonkeyMuxServerReplacement = ({
  int connectionId,
  String sessionName,
  String previousVersion,
  String targetVersion,
  DateTime expiresAt,
});

/// Resolves the retry schedule used for tmux detection after connect.
@visibleForTesting
List<Duration> resolveTmuxDetectionRetrySchedule({bool skipDelay = false}) =>
    skipDelay ? const <Duration>[Duration.zero] : _tmuxDetectionRetrySchedule;

/// Resolves the terminal overflow menu height when the mobile keyboard is up.
@visibleForTesting
double? resolveTerminalOverflowMenuMaxHeight({
  required MediaQueryData mediaQuery,
  required bool isMobilePlatform,
  double? anchorTop,
}) {
  final keyboardInset = mediaQuery.viewInsets.bottom;
  if (!isMobilePlatform || keyboardInset <= 0) {
    return null;
  }

  final visibleBottom = mediaQuery.size.height - keyboardInset;
  final effectiveAnchorTop =
      anchorTop ?? mediaQuery.padding.top + kToolbarHeight;
  final maxHeight =
      visibleBottom - effectiveAnchorTop - _terminalOverflowMenuScreenPadding;
  return maxHeight > 0 ? maxHeight : null;
}

/// Returns whether tmux detection should keep the terminal's current tmux UI.
///
/// A clean inactive result can clear the bar, but transient detection failures
/// should not hide a bar whose attached client was already confirmed to belong
/// to this SSH connection. State that was only primed from host settings has no
/// confirmed client yet, so it must never survive a failed probe.
@visibleForTesting
bool shouldPreserveMonkeyMuxChromeAfterAttachProbe({
  required RemoteMuxBackend backend,
  required bool serverReplacementPending,
  required bool nativeAgentActive,
  required bool attachEstablished,
  required int consecutiveFalseProbes,
}) =>
    backend == RemoteMuxBackend.monkeyMux &&
    (serverReplacementPending ||
        (nativeAgentActive &&
            attachEstablished &&
            consecutiveFalseProbes <= 3));

/// Returns whether a missing terminal view should be checked on another frame.
@visibleForTesting
bool shouldRetryTerminalThemeWhenViewMounts({
  required bool nativeAgentActive,
  required bool routeIsCurrent,
  required int attempt,
}) => !nativeAgentActive && routeIsCurrent && attempt < 3;

/// Returns whether tmux detection should keep the terminal's current tmux UI.
@visibleForTesting
bool shouldPreserveTerminalTmuxStateAfterDetectionFailure({
  required bool preserveExistingTmuxState,
  required bool hadConfirmedTmuxState,
  required bool confirmedTmuxActive,
  required bool hadDetectionFailure,
}) {
  if (preserveExistingTmuxState || confirmedTmuxActive) {
    return true;
  }
  return hadConfirmedTmuxState && hadDetectionFailure;
}

/// Returns whether detection should show the expected tmux UI before exec
/// probes complete.
///
/// Primed state is provisional: it must be confirmed by an ownership-scoped
/// probe on the very next attempt or it is cleared again.
@visibleForTesting
bool shouldPrimeTerminalTmuxStateWhileDetecting({
  required String? candidateSessionName,
  required bool hasExistingVisibleTmuxState,
  required bool mayPreserveExistingTmuxState,
  required bool isReopeningExistingTerminal,
}) =>
    candidateSessionName != null &&
    !hasExistingVisibleTmuxState &&
    !mayPreserveExistingTmuxState &&
    isReopeningExistingTerminal;

/// Chooses the tmux session name to verify during detection.
///
/// Prefer explicit route/host configuration, but keep verifying the existing
/// visible tmux session when no configured session name is available.
@visibleForTesting
String? resolveTmuxDetectionCandidateSessionName({
  String? preferredSessionName,
  String? existingSessionName,
}) {
  final preferred = preferredSessionName?.trim();
  if (preferred != null && preferred.isNotEmpty) {
    return preferred;
  }
  final existing = existingSessionName?.trim();
  if (existing != null && existing.isNotEmpty) {
    return existing;
  }
  return null;
}

/// Keeps an existing tmux session candidate scoped to the SSH connection that
/// created it.
@visibleForTesting
String? resolveOwnedTmuxDetectionExistingSessionName({
  required int sessionConnectionId,
  required int? tmuxStateConnectionId,
  String? existingSessionName,
}) {
  if (tmuxStateConnectionId != sessionConnectionId) {
    return null;
  }
  return resolveTmuxDetectionCandidateSessionName(
    existingSessionName: existingSessionName,
  );
}

/// Returns whether a tmux bar widget update should keep its last window list.
///
/// Recovery updates re-run subscriptions and queries after transient failures,
/// but should not throw away the last good snapshot for the same tmux session.
@visibleForTesting
bool shouldPreserveTmuxBarSnapshotOnUpdate({
  required bool sessionChanged,
  required bool backendChanged,
  required bool recoveryChanged,
}) => recoveryChanged && !sessionChanged && !backendChanged;

/// Visibility and availability of the preview-only helper reload action.
@visibleForTesting
({bool visible, bool enabled}) resolveForceMonkeyMuxReloadMenuState({
  required RemoteMuxBackend backend,
  required bool connected,
  required bool hasLiveControlChannel,
  bool previewBuild = isPreviewBuild,
}) => (
  visible: previewBuild,
  enabled:
      previewBuild &&
      connected &&
      backend == RemoteMuxBackend.monkeyMux &&
      hasLiveControlChannel,
);

/// A single reload scoped to the remote workspace across an SSH reconnect.
///
/// Reconnecting assigns a new connection ID. The owning reconnect attempt must
/// cancel this request when it completes or is cancelled.
@visibleForTesting
class MonkeyMuxForcedReloadRequest {
  /// Creates a request for the currently attached remote workspace.
  MonkeyMuxForcedReloadRequest(this.sessionName);

  /// Workspace to reload when the replacement SSH connection attaches.
  final String sessionName;
  bool _pending = true;

  /// Consumes the request once, only for its intended workspace.
  MonkeyMuxServerUpdatePolicy? consumePolicy(String attachingSessionName) {
    if (!_pending || attachingSessionName != sessionName) return null;
    _pending = false;
    return MonkeyMuxServerUpdatePolicy.force;
  }

  /// Prevents a failed or cancelled attempt from forcing a later attach.
  void cancel() => _pending = false;
}

/// Resolves a stored remote multiplexer backend for startup.
///
/// Missing values intentionally use automatic MonkeyMux-first behavior unless a
/// legacy tmux host has custom tmux flags that MonkeyMux cannot honor.
@visibleForTesting
RemoteMuxBackend resolveRemoteMuxStartupBackend(
  String? storedBackend, {
  String? tmuxExtraFlags,
}) => resolveRemoteMuxBackendForStartup(
  storedBackend: storedBackend,
  tmuxExtraFlags: tmuxExtraFlags,
);

/// Resolves the working directory to use when creating a new tmux window.
@visibleForTesting
String? resolveTmuxWindowWorkingDirectory({
  String? explicitWorkingDirectory,
  String? configuredWorkingDirectory,
  String? launchWorkingDirectory,
  String? currentPaneWorkingDirectory,
  String? observedWorkingDirectory,
}) => _firstNonEmptyWorkingDirectory([
  explicitWorkingDirectory,
  configuredWorkingDirectory,
  launchWorkingDirectory,
  currentPaneWorkingDirectory,
  observedWorkingDirectory,
]);

/// Resolves the stable host connection directory for a new native window.
///
/// Active-window context is intentionally absent: opening a native window is a
/// host-level action and must not inherit whichever MonkeyMux pane is selected.
@visibleForTesting
String resolveNativeAcpNewWindowWorkingDirectory({
  String? connectionWorkingDirectory,
  String? launchWorkingDirectory,
  String? hostWorkingDirectory,
}) =>
    _firstNonEmptyWorkingDirectory([
      connectionWorkingDirectory,
      launchWorkingDirectory,
      hostWorkingDirectory,
    ]) ??
    '~';

/// Resolves the host-configured directory for the active multiplexer session.
@visibleForTesting
String? resolveConfiguredMuxWorkingDirectory({
  required AgentLaunchPreset? agentPreset,
  required RemoteMuxBackend backend,
  required String sessionName,
  String? hostWorkingDirectory,
}) {
  final presetSessionName = agentPreset?.tmuxSessionName?.trim();
  final presetMatchesSession =
      agentPreset != null &&
      agentPreset.usesMuxSession &&
      agentPreset.effectiveRemoteMuxBackend == backend &&
      presetSessionName == sessionName;
  return _firstNonEmptyWorkingDirectory([
    if (presetMatchesSession) agentPreset.workingDirectory,
    hostWorkingDirectory,
  ]);
}

String? _firstNonEmptyWorkingDirectory(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final trimmed = candidate?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

/// Returns whether a tmux window action should reattach the visible terminal.
@visibleForTesting
bool shouldReattachTmuxAfterWindowAction({
  required bool hasForegroundClient,
  required TerminalShellStatus? shellStatus,
}) {
  if (hasForegroundClient) {
    return false;
  }
  return shellStatus == TerminalShellStatus.prompt;
}

/// Whether a previously established MonkeyMux attach should be replaced
/// directly after its foreground client disappears.
@visibleForTesting
bool shouldReopenLostMonkeyMuxAttach({
  required RemoteMuxBackend backend,
  required bool attachEstablished,
  required bool hasForegroundClient,
}) =>
    backend == RemoteMuxBackend.monkeyMux &&
    attachEstablished &&
    !hasForegroundClient;

/// Returns whether shell-command review warnings should be shown for text
/// inserted into the active terminal context.
///
/// These warnings are most useful when input is likely targeting a shell
/// prompt. When a full-screen app owns the alternate buffer, or shell
/// integration reports that a command is still running, the input is more
/// likely to be consumed by that program than by the shell itself.
@visibleForTesting
bool shouldReviewTerminalCommandInsertion({
  required TerminalShellStatus? shellStatus,
  required bool isUsingAltBuffer,
}) {
  if (isUsingAltBuffer) {
    return false;
  }
  return shellStatus != TerminalShellStatus.runningCommand;
}

/// Returns whether a tmux pane foreground command is shell-like enough for
/// shell completion popups.
@visibleForTesting
bool isShellCompletionTmuxShellCommand(String? command) {
  var normalized = command?.trim();
  if (normalized == null || normalized.isEmpty) {
    return false;
  }
  normalized = normalized.replaceAll(r'\', '/').split('/').last;
  if (normalized.startsWith('-')) {
    normalized = normalized.substring(1);
  }
  normalized = normalized.toLowerCase();
  if (normalized.endsWith('.exe')) {
    normalized = normalized.substring(0, normalized.length - 4);
  }
  return _shellCompletionShellCommands.contains(normalized);
}

/// Returns whether terminal input should start a shell completion refresh.
@visibleForTesting
bool canTerminalOutputTriggerShellCompletion({
  required String output,
  required bool isUsingAltBuffer,
  required bool isTmuxActive,
  required bool showsNativeSelectionOverlay,
}) {
  if (output.isEmpty || showsNativeSelectionOverlay) {
    return false;
  }
  if (isUsingAltBuffer && !isTmuxActive) {
    return false;
  }
  if (output == '\x7F' || output == '\b') {
    return true;
  }
  if (output.length > 32) {
    return false;
  }
  for (var index = 0; index < output.length; index++) {
    final codeUnit = output.codeUnitAt(index);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }
  }
  return true;
}

/// Returns whether completions should use the current terminal as a shell prompt.
@visibleForTesting
bool isShellCompletionPromptContext({
  required TerminalShellStatus? shellStatus,
  required bool isTmuxActive,
  required String? tmuxCurrentCommand,
}) {
  if (isTmuxActive) {
    final command = tmuxCurrentCommand?.trim();
    return command != null &&
        command.isNotEmpty &&
        isShellCompletionTmuxShellCommand(command);
  }
  return shellStatus != TerminalShellStatus.runningCommand;
}

/// Resolves the compact row height for shell completion popup entries.
@visibleForTesting
double resolveShellCompletionPopupRowHeight(double terminalFontSize) =>
    max(28, terminalFontSize * 1.75).toDouble();

double _nonNegativeDouble(double value) => value < 0 ? 0 : value;

/// Resolves shell completion popup bounds without covering the cursor line.
@visibleForTesting
({double left, double top, double width, double maxHeight})
resolveShellCompletionPopupLayout({
  required Size overlaySize,
  required Rect anchor,
  required int suggestionCount,
  required double rowHeight,
  double horizontalMargin = 12,
  double verticalMargin = 8,
  double anchorGap = 4,
  double popupVerticalPadding = 6,
  double minWidth = 220,
  double maxWidth = 340,
  int maxVisibleRows = 5,
}) {
  final availableWidth = _nonNegativeDouble(
    overlaySize.width - (horizontalMargin * 2),
  );
  final width = min(
    availableWidth,
    min(maxWidth, max(minWidth, availableWidth)),
  );
  final maxLeft = max(
    horizontalMargin,
    overlaySize.width - width - horizontalMargin,
  );
  final left = anchor.left.clamp(horizontalMargin, maxLeft);

  final visibleCount = max(1, min(suggestionCount, maxVisibleRows));
  final desiredHeight = (visibleCount * rowHeight) + popupVerticalPadding;
  final availableAbove = _nonNegativeDouble(
    anchor.top - anchorGap - verticalMargin,
  );
  final availableBelow = _nonNegativeDouble(
    overlaySize.height - anchor.bottom - anchorGap - verticalMargin,
  );
  final placeAbove =
      availableAbove >= desiredHeight ||
      (availableBelow < desiredHeight && availableAbove > availableBelow);
  final availableHeight = placeAbove ? availableAbove : availableBelow;
  final maxHeight = min(desiredHeight, availableHeight);
  final top = placeAbove
      ? anchor.top - anchorGap - maxHeight
      : anchor.bottom + anchorGap;

  return (left: left, top: top, width: width, maxHeight: maxHeight);
}

/// Wraps the terminal layer so pointer downs outside the completion popup can
/// dismiss the popup while popup taps remain handled by the overlay above it.
@visibleForTesting
Widget wrapShellCompletionDismissibleTerminal({
  required Widget child,
  required VoidCallback onDismiss,
}) => Listener(
  behavior: HitTestBehavior.translucent,
  onPointerDown: (_) => onDismiss(),
  child: child,
);

/// Returns whether a visible shell completion suggestion still matches the
/// current terminal command line closely enough to apply.
@visibleForTesting
bool shouldAcceptShellCompletionSuggestion({
  required ShellCompletionInvocation originalInvocation,
  required ShellCompletionInvocation? currentInvocation,
  required ShellCompletionSuggestion suggestion,
}) {
  if (currentInvocation == null) {
    return true;
  }
  if (suggestion.kind == ShellCompletionSuggestionKind.history) {
    if (currentInvocation.workingDirectory !=
            originalInvocation.workingDirectory ||
        currentInvocation.shellCommand != originalInvocation.shellCommand) {
      return false;
    }
    if (suggestion.replacementStart != 0) {
      final originalPatternPrefix = normalizeShellHistoryCommandPattern(
        originalInvocation.commandLine.substring(
          0,
          originalInvocation.tokenStart,
        ),
      );
      final currentPatternPrefix = normalizeShellHistoryCommandPattern(
        currentInvocation.commandLine.substring(
          0,
          currentInvocation.tokenStart,
        ),
      );
      return currentInvocation.commandName == originalInvocation.commandName &&
          currentPatternPrefix == originalPatternPrefix &&
          normalizeShellCompletionToken(
            suggestion.replacement,
          ).startsWith(currentInvocation.token);
    }
    if (currentInvocation.cursorOffset < suggestion.replacementStart) {
      return false;
    }
    final currentCommand = currentInvocation.commandLine.substring(
      0,
      currentInvocation.cursorOffset,
    );
    return suggestion.replacement.startsWith(currentCommand);
  }
  if (currentInvocation.mode != originalInvocation.mode ||
      currentInvocation.tokenStart != originalInvocation.tokenStart ||
      currentInvocation.workingDirectory !=
          originalInvocation.workingDirectory ||
      currentInvocation.shellCommand != originalInvocation.shellCommand ||
      currentInvocation.cursorOffset < suggestion.replacementStart ||
      originalInvocation.commandLine.length < originalInvocation.tokenStart ||
      currentInvocation.commandLine.length < currentInvocation.tokenStart) {
    return false;
  }

  final originalPrefix = originalInvocation.commandLine.substring(
    0,
    originalInvocation.tokenStart,
  );
  final currentPrefix = currentInvocation.commandLine.substring(
    0,
    currentInvocation.tokenStart,
  );
  if (currentPrefix != originalPrefix) {
    return false;
  }

  return normalizeShellCompletionToken(
    suggestion.replacement,
  ).startsWith(currentInvocation.token);
}

/// Filters visible shell completion suggestions against the current command.
@visibleForTesting
List<ShellCompletionSuggestion>
filterShellCompletionSuggestionsForCurrentInput({
  required ShellCompletionInvocation originalInvocation,
  required ShellCompletionInvocation? currentInvocation,
  required List<ShellCompletionSuggestion> suggestions,
}) {
  if (currentInvocation == null) {
    return const <ShellCompletionSuggestion>[];
  }

  return suggestions
      .where(
        (suggestion) => shouldAcceptShellCompletionSuggestion(
          originalInvocation: originalInvocation,
          currentInvocation: currentInvocation,
          suggestion: suggestion,
        ),
      )
      .toList(growable: false);
}

/// Resolves the safe-area insets the tmux bar should stay within.
@visibleForTesting
EdgeInsets resolveTmuxBarSafeInsets(MediaQueryData mediaQuery) {
  final horizontalInsets = resolveTerminalRenderPadding(mediaQuery);
  return EdgeInsets.only(
    left: horizontalInsets.left,
    right: horizontalInsets.right,
    bottom: resolveSystemBottomInset(mediaQuery),
  );
}

/// Placement used for the inline tmux window controls.
enum TmuxBarPlacement {
  /// A bottom bar over reserved terminal padding on narrow layouts.
  bottomOverlay,

  /// A left side panel next to the terminal on wide layouts.
  sidebar,
}

/// Width of the collapsed large-screen tmux sidebar.
@visibleForTesting
const double tmuxSidebarCollapsedWidth = 56;

/// Width of the expanded large-screen tmux sidebar.
@visibleForTesting
const double tmuxSidebarExpandedWidth = 320;

/// Minimum terminal width to preserve before switching to a sidebar.
@visibleForTesting
const double tmuxSidebarMinTerminalWidth = 520;

/// Horizontal drag distance that snaps the sidebar open or closed.
@visibleForTesting
const double tmuxSidebarDragThreshold = 60;

/// Chooses whether tmux controls should sit below or beside the terminal.
@visibleForTesting
TmuxBarPlacement resolveTmuxBarPlacement(double availableWidth) {
  if (!availableWidth.isFinite) {
    return TmuxBarPlacement.bottomOverlay;
  }
  return availableWidth >=
          tmuxSidebarExpandedWidth + tmuxSidebarMinTerminalWidth
      ? TmuxBarPlacement.sidebar
      : TmuxBarPlacement.bottomOverlay;
}

/// Whether Back should leave the connection screen.
///
/// Native ACP focus replaces the terminal viewport but does not create a new
/// navigation level. Only expanded mux chrome consumes the first Back action.
@visibleForTesting
bool resolveTerminalScreenCanPop({required bool isTmuxBarExpanded}) =>
    !isTmuxBarExpanded;

/// Whether the terminal shell should resize for the system keyboard.
///
/// Insets describe occupied geometry but can remain stale after the IME closes.
/// A native platform visibility report therefore wins for both terminal and
/// ACP inputs. Before that report arrives, require a live input owner rather
/// than treating native content itself as proof that a keyboard is open.
@visibleForTesting
bool resolveTerminalSystemKeyboardVisible({
  required double bottomInset,
  required bool? platformKeyboardVisible,
  required bool terminalInputConnectionVisible,
  required bool nativeComposerInputOwner,
}) {
  if (bottomInset <= 0) return false;
  if (platformKeyboardVisible case final visible?) return visible;
  return terminalInputConnectionVisible || nativeComposerInputOwner;
}

/// Whether actions that read or mutate terminal viewport state belong in the
/// overflow menu for the current content mode.
@visibleForTesting
bool resolveShowTerminalViewportMenuActions({
  required bool nativeAgentActive,
}) => !nativeAgentActive;

/// Resolves the wide-layout sidebar width while the user drags it.
@visibleForTesting
double resolveTmuxSidebarWidth({
  required bool isExpanded,
  required double dragOffset,
}) {
  const widthDelta = tmuxSidebarExpandedWidth - tmuxSidebarCollapsedWidth;
  final baseWidth = isExpanded
      ? tmuxSidebarExpandedWidth
      : tmuxSidebarCollapsedWidth;
  final clampedDragOffset = isExpanded
      ? dragOffset.clamp(-widthDelta, 0.0)
      : dragOffset.clamp(0.0, widthDelta);
  return (baseWidth + clampedDragOffset).clamp(
    tmuxSidebarCollapsedWidth,
    tmuxSidebarExpandedWidth,
  );
}

/// Resolves the tmux bar's vertical offset from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealBottomOffset(
  double terminalBottomPadding, {
  double handleHeight = tmuxHandleMinTouchExtent,
}) => terminalBottomPadding - handleHeight;

/// Resolves the tmux bar's reveal opacity from the animated bottom padding.
@visibleForTesting
double resolveTmuxBarRevealOpacity(
  double terminalBottomPadding, {
  double handleHeight = tmuxHandleMinTouchExtent,
}) {
  if (handleHeight <= 0) {
    return terminalBottomPadding > 0 ? 1 : 0;
  }

  return (terminalBottomPadding / handleHeight).clamp(0.0, 1.0);
}

/// Resolves the active tmux window title to show in the collapsed bar handle.
@visibleForTesting
String? resolveTmuxBarActiveWindowTitle(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  final title = activeWindow?.handleTitle.trim();
  if (title == null || title.isEmpty) {
    return null;
  }
  return title;
}

/// Resolves the supported foreground agent running in the active tmux window.
@visibleForTesting
AgentLaunchTool? resolveTmuxBarActiveWindowTool(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.foregroundAgentTool;

/// Resolves bracketed paste mode state tracked for the active mux window.
@visibleForTesting
bool? resolveTmuxBarActiveWindowBracketedPasteMode(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.terminalBracketedPasteMode;

/// Resolves a stable identity for the active mux window.
@visibleForTesting
String? resolveTmuxBarActiveWindowKey(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  if (activeWindow == null) {
    return null;
  }
  return activeWindow.id ?? '#${activeWindow.index}';
}

/// Whether attachment input still targets the same settled mux window.
@visibleForTesting
bool terminalAttachmentPasteTargetsCurrentMuxWindow({
  required bool hasPendingWindowSelection,
  required String? pasteWindowKey,
  required String? currentWindowKey,
}) =>
    !hasPendingWindowSelection &&
    (pasteWindowKey == null ||
        currentWindowKey == null ||
        currentWindowKey == pasteWindowKey);

/// Applies active mux-window bracketed-paste state to the local terminal.
@visibleForTesting
bool inheritTerminalBracketedPasteModeFromMuxWindow({
  required Terminal terminal,
  required bool? activeWindowBracketedPasteMode,
}) {
  if (activeWindowBracketedPasteMode == null ||
      terminal.bracketedPasteMode == activeWindowBracketedPasteMode) {
    return false;
  }
  terminal.setBracketedPasteMode(activeWindowBracketedPasteMode);
  return true;
}

/// Refreshes [terminal] from the active window in a fresh mux snapshot.
@visibleForTesting
Future<
  ({
    bool bracketedPasteMode,
    bool bracketedPasteModeKnown,
    String? activeWindowKey,
  })
>
refreshTerminalBracketedPasteModeFromMuxWindows({
  required Terminal terminal,
  required Future<Iterable<TmuxWindow>> Function() loadWindows,
}) async {
  final windows = await loadWindows();
  final activeWindowBracketedPasteMode =
      resolveTmuxBarActiveWindowBracketedPasteMode(windows);
  inheritTerminalBracketedPasteModeFromMuxWindow(
    terminal: terminal,
    activeWindowBracketedPasteMode: activeWindowBracketedPasteMode,
  );
  return (
    bracketedPasteMode: terminal.bracketedPasteMode,
    bracketedPasteModeKnown: activeWindowBracketedPasteMode != null,
    activeWindowKey: resolveTmuxBarActiveWindowKey(windows),
  );
}

/// Whether an attachment paste can bypass the ambiguous raw attach stream.
@visibleForTesting
bool shouldInjectTerminalAttachmentViaMonkeyMuxControl({
  required bool bracketedPasteMode,
  required bool isMuxActive,
  required RemoteMuxBackend muxBackend,
  required bool hasSession,
  required bool hasSessionName,
  required bool supportsBracketedPasteControlInput,
}) =>
    bracketedPasteMode &&
    isMuxActive &&
    muxBackend == RemoteMuxBackend.monkeyMux &&
    hasSession &&
    hasSessionName &&
    supportsBracketedPasteControlInput;

/// Why attachment segment delivery stopped before all segments were sent.
enum TerminalAttachmentPasteStopReason {
  /// The terminal screen was disposed before delivery completed.
  unavailable,

  /// The active SSH connection or multiplexer context changed.
  contextChanged,

  /// A different multiplexer window became active.
  windowChanged,

  /// User or terminal input arrived between attachment segments.
  interveningInput,
}

/// Delivers pre-built attachment [segments] through control input or fallback.
///
/// This owns the async boundary around control injection so user input arriving
/// while a segment is in flight prevents subsequent attachments from being
/// appended after that input.
@visibleForTesting
Future<
  ({int deliveredSegmentCount, TerminalAttachmentPasteStopReason? stopReason})
>
deliverTerminalAttachmentPasteSegments({
  required List<String> segments,
  required bool injectViaMonkeyMuxControl,
  required Future<bool> Function(String segment) injectInput,
  required void Function(String segment) writeTerminalOutput,
  required int initialInputGeneration,
  required int Function() currentInputGeneration,
  required void Function() recordDeliveredInput,
  required TerminalAttachmentPasteStopReason? Function() blockedReason,
  required Future<void> Function() waitBetweenSegments,
}) async {
  var expectedInputGeneration = initialInputGeneration;
  var deliveredSegmentCount = 0;
  for (var index = 0; index < segments.length; index++) {
    final reason = blockedReason();
    if (reason != null) {
      return (deliveredSegmentCount: deliveredSegmentCount, stopReason: reason);
    }
    if (currentInputGeneration() != expectedInputGeneration) {
      return (
        deliveredSegmentCount: deliveredSegmentCount,
        stopReason: TerminalAttachmentPasteStopReason.interveningInput,
      );
    }

    final injected =
        injectViaMonkeyMuxControl && await injectInput(segments[index]);
    if (!injected) {
      final fallbackReason = blockedReason();
      if (fallbackReason != null) {
        return (
          deliveredSegmentCount: deliveredSegmentCount,
          stopReason: fallbackReason,
        );
      }
      if (currentInputGeneration() != expectedInputGeneration) {
        return (
          deliveredSegmentCount: deliveredSegmentCount,
          stopReason: TerminalAttachmentPasteStopReason.interveningInput,
        );
      }
      writeTerminalOutput(segments[index]);
    }

    final hadInterveningInput =
        currentInputGeneration() != expectedInputGeneration;
    recordDeliveredInput();
    expectedInputGeneration = currentInputGeneration();
    deliveredSegmentCount++;
    if (hadInterveningInput && index < segments.length - 1) {
      return (
        deliveredSegmentCount: deliveredSegmentCount,
        stopReason: TerminalAttachmentPasteStopReason.interveningInput,
      );
    }
    if (index < segments.length - 1) {
      await waitBetweenSegments();
    }
  }
  return (deliveredSegmentCount: deliveredSegmentCount, stopReason: null);
}

/// Pastes [text] using an explicitly resolved bracketed-paste mode.
@visibleForTesting
void pasteTerminalTextWithBracketedPasteMode({
  required Terminal terminal,
  required String text,
  required bool bracketedPasteMode,
}) {
  final previousBracketedPasteMode = terminal.bracketedPasteMode;
  terminal.setBracketedPasteMode(bracketedPasteMode);
  try {
    terminal.paste(text);
  } finally {
    terminal.setBracketedPasteMode(previousBracketedPasteMode);
  }
}

/// Whether paste-mode settling should request another mux snapshot.
@visibleForTesting
bool shouldRetryTerminalPasteModeSettle({
  required bool refreshAttempted,
  required bool refreshSucceeded,
  required bool hasActiveWindow,
  required bool modeReliable,
  required bool targetsCurrentWindow,
}) {
  if (refreshAttempted) {
    return refreshSucceeded && (!hasActiveWindow || !targetsCurrentWindow);
  }
  return !modeReliable || !targetsCurrentWindow;
}

int? _compareMonkeyMuxVersions(String? left, String? right) {
  final leftVersion = _parseMonkeyMuxVersion(left);
  final rightVersion = _parseMonkeyMuxVersion(right);
  if (leftVersion == null || rightVersion == null) {
    return null;
  }
  final leftParts = [leftVersion.$1, leftVersion.$2, leftVersion.$3];
  final rightParts = [rightVersion.$1, rightVersion.$2, rightVersion.$3];
  for (var index = 0; index < leftParts.length; index++) {
    final comparison = leftParts[index].compareTo(rightParts[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

(int, int, int)? _parseMonkeyMuxVersion(String? value) {
  final match = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)$',
  ).firstMatch(value?.trim() ?? '');
  if (match == null) {
    return null;
  }
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

String _telemetryMuxBackendName(RemoteMuxBackend backend) => switch (backend) {
  RemoteMuxBackend.auto => 'auto',
  RemoteMuxBackend.tmux => 'tmux',
  RemoteMuxBackend.monkeyMux => 'monkeymux',
};

/// Formats a detected remote multiplexer version for terminal metadata.
@visibleForTesting
String? formatRemoteMuxVersionLabel(RemoteMuxBackend backend, String? version) {
  final trimmedVersion = version?.trim();
  if (trimmedVersion == null || trimmedVersion.isEmpty) {
    return null;
  }
  final backendLabel = backend.label;
  if (trimmedVersion.toLowerCase().startsWith(
    '${backendLabel.toLowerCase()} ',
  )) {
    return trimmedVersion;
  }
  return '$backendLabel $trimmedVersion';
}

/// Resolves whether the active tmux window requested mouse-wheel input.
@visibleForTesting
bool? resolveTmuxBarActiveWindowReportsMouseWheel(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.terminalReportsMouseWheel;

/// Resolves whether the active tmux window requested SGR mouse reporting.
@visibleForTesting
bool? resolveTmuxBarActiveWindowMouseReportSgr(Iterable<TmuxWindow>? windows) =>
    windows
        ?.where((window) => window.isActive)
        .firstOrNull
        ?.terminalMouseReportSgr;

/// Terminal mode signature for the active tmux window.
///
/// Used to detect when local terminal state must be updated after a window
/// metadata update that doesn't change the active window itself (for example a
/// foreground app toggling mouse or bracketed-paste mode). Returns `null` when
/// there is no active window so an appearing/disappearing active window is also
/// treated as a change.
@visibleForTesting
({bool? reportsMouseWheel, bool? mouseReportSgr, bool? bracketedPasteMode})?
activeTmuxWindowTerminalModeSignature(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  if (activeWindow == null) {
    return null;
  }
  return (
    reportsMouseWheel: activeWindow.terminalReportsMouseWheel,
    mouseReportSgr: activeWindow.terminalMouseReportSgr,
    bracketedPasteMode: activeWindow.terminalBracketedPasteMode,
  );
}

/// Resolves the tmux windows the bar should display, including any local
/// optimistic selection while the tmux snapshot is still catching up.
@visibleForTesting
List<TmuxWindow>? resolveTmuxBarDisplayedWindows(
  Iterable<TmuxWindow>? windows, {
  int? pendingSelectedWindowIndex,
}) {
  final windowList = windows?.toList(growable: false);
  if (windowList == null || pendingSelectedWindowIndex == null) {
    return windowList;
  }
  if (!windowList.any((window) => window.index == pendingSelectedWindowIndex)) {
    return windowList;
  }

  var didChangeActiveWindow = false;
  final displayedWindows = <TmuxWindow>[];
  for (final window in windowList) {
    final shouldBeActive = window.index == pendingSelectedWindowIndex;
    if (window.isActive != shouldBeActive) {
      didChangeActiveWindow = true;
      displayedWindows.add(window.copyWith(isActive: shouldBeActive));
      continue;
    }
    displayedWindows.add(window);
  }
  return didChangeActiveWindow ? displayedWindows : windowList;
}

/// Resolves whether the tmux bar should keep or clear its optimistic selection
/// after tmux reports a new window list.
@visibleForTesting
int? resolveTmuxBarPendingSelectedWindowIndex(
  Iterable<TmuxWindow>? windows, {
  int? pendingSelectedWindowIndex,
}) {
  if (pendingSelectedWindowIndex == null || windows == null) {
    return pendingSelectedWindowIndex;
  }
  final windowList = windows.toList(growable: false);
  if (!windowList.any((window) => window.index == pendingSelectedWindowIndex)) {
    return null;
  }
  final activeWindow = windowList
      .where((window) => window.isActive)
      .firstOrNull;
  if (activeWindow?.index == pendingSelectedWindowIndex) {
    return null;
  }
  return pendingSelectedWindowIndex;
}

/// Resolves the compact label shown in the tmux bar handle.
@visibleForTesting
String resolveTmuxBarHandleLabel(
  String tmuxSessionName, {
  String? activeWindowTitle,
}) {
  final sessionName = tmuxSessionName.trim();
  final title = activeWindowTitle?.trim();
  if (title == null || title.isEmpty || title == sessionName) {
    return sessionName;
  }
  if (sessionName.isEmpty) {
    return title;
  }
  return '$sessionName · $title';
}

final _oscEscapeSequencePattern = RegExp(
  '\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)',
  dotAll: true,
);
final _csiEscapeSequencePattern = RegExp('\x1B\\[[0-?]*[ -/]*[@-~]');
final _singleCharEscapeSequencePattern = RegExp('\x1B[@-_]');
final _terminalMouseReportOutputPattern = RegExp(
  '^(?:\x1B\\[<\\d+;\\d+;\\d+[mM])+\$',
);
final _terminalFocusReportOutputPattern = RegExp('^(?:\x1B\\[[IO])+\$');

String _stripTerminalPromptEscapeSequences(String text) => text
    .replaceAll(_oscEscapeSequencePattern, '')
    .replaceAll(_csiEscapeSequencePattern, '')
    .replaceAll(_singleCharEscapeSequencePattern, '');

bool _isShellCommandName(String? command) {
  final trimmed = command?.trim();
  if (trimmed == null || trimmed.isEmpty) return false;
  final token = trimmed.split(RegExp(r'\s+')).first;
  final basename = token.split(RegExp(r'[\\/]')).last.toLowerCase();
  switch (basename.replaceFirst(RegExp(r'\.exe$'), '')) {
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'fish':
    case 'dash':
    case 'ksh':
      return true;
    default:
      return false;
  }
}

/// Whether a MonkeyMux terminal mouse/focus control report should be dropped
/// before it reaches the remote shell.
///
/// The app synthesizes mouse-wheel reports for touch scroll and focus reports
/// when overlays open/close. Sending those escape bytes to a bare shell would
/// type garbage, but suppressing them for a foreground app that actually
/// enabled the matching mode (a mouse-reporting TUI, or a coding agent) breaks
/// touch scroll and focus re-arming.
///
/// The foreground command name alone is not reliable: opening the SFTP browser
/// probes the MonkeyMux pane context, which can report the login shell (e.g.
/// `zsh`) that a coding agent runs under and overwrite the tracked command.
/// Gate on the live input-mode state (and the active-window agent tool) so a
/// report is only suppressed for a genuine bare shell.
@visibleForTesting
bool shouldSuppressMonkeyMuxControlReport({
  required bool isMonkeyMux,
  required bool isMouseReport,
  required bool isFocusReport,
  required bool mouseReportingActive,
  required bool focusReportingActive,
  required bool isAgentToolActive,
  String? currentCommand,
}) {
  if (!isMonkeyMux) {
    return false;
  }
  if (!isMouseReport && !isFocusReport) {
    return false;
  }
  if (isMouseReport && mouseReportingActive) {
    return false;
  }
  if (isFocusReport && focusReportingActive) {
    return false;
  }
  if (isAgentToolActive) {
    return false;
  }
  final command = currentCommand?.trim();
  if (command != null && agentLaunchToolForCommandName(command) != null) {
    return false;
  }
  return _isShellCommandName(command);
}

final _terminalSensitivePromptPattern = RegExp(
  r'\b(?:password|passphrase|pin|otp|one[- ]time(?:\s+password)?|verification(?:\s+code)?|authentication(?:\s+code)?|auth(?:\s+code)?|security(?:\s+code)?)\b[^\r\n]{0,160}[:：]\s*$',
  caseSensitive: false,
);

final _terminalPasswordPolicyPromptPattern = RegExp(
  r'\b(?:password|passphrase)\s+(?:requirements?|policy|rules?|hint|incorrect|invalid|failed|failure|reset|changed|updated)\b',
  caseSensitive: false,
);

/// Returns whether the visible terminal text appears to be requesting a secret.
@visibleForTesting
bool terminalTextLooksLikeSensitiveInputPrompt(String? textBeforeCursor) {
  if (textBeforeCursor == null) {
    return false;
  }

  final sanitizedText = _stripTerminalPromptEscapeSequences(textBeforeCursor);
  if (sanitizedText.trimRight().isEmpty) {
    return false;
  }

  final lastLine = sanitizedText.split(RegExp(r'[\r\n]')).last.trimRight();
  if (lastLine.isEmpty || lastLine.length > 220) {
    return false;
  }

  final normalizedLine = lastLine.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (_terminalPasswordPolicyPromptPattern.hasMatch(normalizedLine)) {
    return false;
  }

  return _terminalSensitivePromptPattern.hasMatch(normalizedLine);
}

/// Reads a wrapped cursor prefix, returning null when its trimmed text is too long.
@visibleForTesting
String? terminalSensitivePromptTextBeforeCursor(Terminal terminal) {
  final buffer = terminal.buffer;
  var row = buffer.absoluteCursorY;
  if (row < 0 || row >= buffer.height) {
    return null;
  }
  var column = buffer.cursorX.clamp(0, buffer.viewWidth);
  final characters = <int>[];
  var length = 0;
  while (true) {
    final line = buffer.lines[row];
    while (column > 0) {
      column--;
      if (column > 0 && line.getWidth(column - 1) == 2) {
        column--;
      } else if (line.getWidth(column) == 2 && column + 1 < buffer.viewWidth) {
        // The cursor is inside this cell, before its text offset advances.
        continue;
      }
      final codePoint = line.getCodePoint(column);
      final character = codePoint == 0 ? 0x20 : codePoint;
      if (characters.isEmpty &&
          String.fromCharCode(character).trimRight().isEmpty) {
        continue;
      }
      length += character > 0xffff ? 2 : 1;
      if (length > 220) {
        return null;
      }
      characters.add(character);
    }
    if (row == 0 || !line.isWrapped) {
      return String.fromCharCodes(characters.reversed);
    }
    row--;
    column = buffer.viewWidth;
  }
}

const _minTerminalFontSize = 8.0;
const _maxTerminalFontSize = 32.0;
const _terminalFollowOutputTolerance = 1.0;
const _maxVerifiedTerminalPathCacheEntries = 128;
const _terminalPathTouchHorizontalPadding = 10.0;
const _terminalPathTouchVerticalPadding = 8.0;
const _recentLocalClipboardProtection = Duration(seconds: 5);
const _maxTerminalFilePathVerificationCandidates = 12;
const _terminalSelectionSnippetNameMaxLength = 60;
const _terminalFilePathVerificationExtensions = <String>[
  'properties',
  'gradle',
  'sqlite',
  'jpeg',
  'plist',
  'swift',
  'tar',
  'yaml',
  'dart',
  'html',
  'json',
  'lock',
  'scss',
  'toml',
  'tsx',
  'webp',
  'bash',
  'conf',
  'cpp',
  'css',
  'csv',
  'gif',
  'ini',
  'jpg',
  'log',
  'png',
  'sql',
  'svg',
  'txt',
  'xml',
  'yml',
  'zsh',
  'cc',
  'db',
  'go',
  'gz',
  'js',
  'kt',
  'md',
  'mm',
  'py',
  'rb',
  'rs',
  'sh',
  'ts',
  'c',
  'h',
  'm',
];

class _ExtraKeysToggleKeycap extends StatelessWidget {
  const _ExtraKeysToggleKeycap({required this.isActive, super.key});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor =
        IconTheme.of(context).color ?? theme.colorScheme.onSurface;

    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          width: 22,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? iconColor.withAlpha(56) : Colors.transparent,
            border: Border.all(
              color: isActive ? iconColor : iconColor.withAlpha(190),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Fn',
            style: theme.textTheme.labelSmall?.copyWith(
              color: iconColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

final _terminalFilePathVerificationExtensionSet =
    _terminalFilePathVerificationExtensions.toSet();
final _terminalLinkPattern = RegExp(
  r'''(?:(?:https?:\/\/)|(?:file:\/\/)|(?:mailto:)|(?:tel:)|(?:www\.))[^\s<>"'\u2500-\u259f]+''',
  caseSensitive: false,
);
final _terminalFilePathPattern = RegExp(
  r'''(?:[A-Za-z]:[\\/](?:[^\s<>"'$#&|;]+)?|~(?:/[^\s<>"'$#&|;]+)?|/(?:[^\s<>"'$#&|;]+)|\.\.?/(?:[^\s<>"'$#&|;]+)|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)''',
);
final _terminalFilePathLineSuffixPattern = RegExp(
  r'''(?:[A-Za-z]:[\\/](?:[^\s<>"'$#&|;]+)?|~(?:/[^\s<>"'$#&|;]+)?/?|/(?:[^\s<>"'$#&|;]+)?|\.\.?/(?:[^\s<>"'$#&|;]+)?|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+/?)$''',
);
final _terminalFilePathStackTraceSuffixPattern = RegExp(
  r'(?:L\d+(?::\d+)?|:\d+(?::\d+)?)$',
);
final _terminalFilePathShellOperatorSuffixPattern = RegExp(
  r'(?:&&|\|\||[&;|])+$',
);
final _terminalWrappedCountSuffixPattern = RegExp(r'\d+$');
final _terminalStandalonePathMetadataPattern = RegExp(
  r'^(?:L\d+(?::\d+)?|:\d+(?::\d+)?)(?:\s|\(|$)',
);
const _terminalSftpPathPrefix = 'monkeyssh-sftp-path:';
const _terminalPathVerificationTimeout = Duration(seconds: 5);
const _terminalPathVerificationChannelBackoff = Duration(seconds: 10);
const _terminalPathVerificationBatchDelay = Duration(milliseconds: 50);

typedef _TerminalPathMatch = ({
  String path,
  int start,
  int end,
  int hitTestEnd,
  int normalizedStart,
  int normalizedEnd,
});
typedef _NormalizedTerminalPathSnapshot = ({
  String text,
  List<int> originalToNormalizedOffsets,
  List<int> normalizedToOriginalStarts,
  List<int> normalizedToOriginalEnds,
});
typedef _TerminalPathTapSnapshot = ({
  String text,
  int startRow,
  List<int> rowStarts,
  List<List<int>> columnOffsets,
});
typedef _TerminalPathSnapshotAnalysis = ({
  List<_TerminalPathMatch> detectedPaths,
  _NormalizedTerminalPathSnapshot normalizedSnapshot,
});
typedef _VerifiedTerminalPath = ({
  String terminalPath,
  String resolvedPath,
  bool exists,
});
typedef _PreparedRemoteMuxCommand = ({
  RemoteMuxBackend backend,
  String command,
  String sessionName,
  AgentLaunchTool? tool,
});

class _MonkeyMuxReconnectException implements Exception {
  const _MonkeyMuxReconnectException();
}

enum _AutoConnectReviewDecision { skip, runOnce, trustAndRun }

/// Padding around the terminal viewport.
///
/// Keep the terminal flush with the viewport edges so status lines from tools
/// like tmux can use the full available width and height.
const terminalViewportPadding = EdgeInsets.zero;

/// Clamps a terminal font size into the supported zoom range.
@visibleForTesting
double clampTerminalFontSize(num size) {
  // `num.clamp` does not sanitize NaN consistently across Dart versions, so
  // guard non-finite inputs explicitly to avoid a NaN font size propagating
  // into the painter (which crashes layout/paint integer math).
  if (!size.isFinite) {
    return _minTerminalFontSize;
  }
  return size.clamp(_minTerminalFontSize, _maxTerminalFontSize).toDouble();
}

/// Scales a terminal font size while keeping it within the supported range.
@visibleForTesting
double scaleTerminalFontSize(double baseSize, double scale) =>
    clampTerminalFontSize(baseSize * scale);

/// Applies an incremental pinch delta to the currently displayed font size.
@visibleForTesting
double applyTerminalScaleDelta(
  double currentFontSize,
  double previousScale,
  double nextScale,
) {
  // Ignore degenerate gesture frames (e.g. coincident focal points producing a
  // zero or non-finite scale) so a bad frame can't drive the font size to NaN.
  if (!nextScale.isFinite || nextScale <= 0) {
    return clampTerminalFontSize(currentFontSize);
  }
  final safePreviousScale = (previousScale.isFinite && previousScale > 0)
      ? previousScale
      : 1.0;
  return scaleTerminalFontSize(currentFontSize, nextScale / safePreviousScale);
}

/// Resolves the currently displayed terminal font size.
@visibleForTesting
double resolveTerminalFontSize({
  required double globalFontSize,
  double? sessionFontSize,
  double? pinchFontSize,
}) => pinchFontSize ?? sessionFontSize ?? globalFontSize;

/// Trims terminal cell padding from the end of a rendered line.
@visibleForTesting
String trimTerminalLinePadding(String line) =>
    terminal_selection_text.trimTerminalLinePadding(line);

/// Trims per-line terminal padding from copied or overlaid terminal text.
@visibleForTesting
String trimTerminalSelectionText(String text) =>
    terminal_selection_text.trimTerminalSelectionText(text);

/// Keeps the Pro upsell snackbar tucked just above the visible bottom chrome.
///
/// Flutter's floating [SnackBar] already anchors itself above the keyboard
/// inset and the bottom safe area (see `Scaffold`'s snack bar layout, which
/// uses `min(contentBottom, size.height - viewPadding.bottom)`). The only
/// bottom chrome the scaffold does not know about is the in-body keyboard
/// toolbar that sits inside the body `Column`, so the margin only needs to
/// clear that toolbar with a small visual gap.
@visibleForTesting
double upgradeSnackBarBottomMargin(
  MediaQueryData mediaQuery, {
  bool showKeyboardToolbar = false,
  double keyboardToolbarHeight = 84,
  double baseSpacing = 16,
}) => (showKeyboardToolbar ? keyboardToolbarHeight : 0) + baseSpacing;

/// Resolves a readable display name for a picked upload file.
@visibleForTesting
String resolvePickedTerminalUploadFileName(PlatformFile file, {int index = 0}) {
  final name = file.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  final filePath = file.path;
  if (filePath != null && filePath.isNotEmpty) {
    return path.basename(filePath);
  }
  return 'selected-file-${index + 1}';
}

/// Resolves a readable stream for a picked upload file when available.
@visibleForTesting
Stream<List<int>> resolvePickedTerminalUploadReadStream(PlatformFile file) =>
    file.readAsByteStream().cast<List<int>>();

/// Resolves the picker request used for terminal uploads.
@visibleForTesting
({
  String dialogTitle,
  FileType pickerType,
  String itemLabelSingular,
  String itemLabelPlural,
  bool allowMultiple,
  String failureContext,
})
resolveTerminalUploadPickerRequest({required bool media}) => (
  dialogTitle: media
      ? 'Select images or videos to upload'
      : 'Select files to upload',
  pickerType: media ? FileType.media : FileType.any,
  itemLabelSingular: media ? 'image or video' : 'file',
  itemLabelPlural: media ? 'images or videos' : 'files',
  allowMultiple: true,
  failureContext: media ? 'Media picker upload' : 'File picker upload',
);

/// Whether terminal media paste should use a native photo-library picker.
@visibleForTesting
bool shouldUsePhotoLibraryPickerForTerminalMedia({
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

/// Returns an Android image picker implementation configured for Photo Picker.
@visibleForTesting
ImagePickerAndroid enableAndroidPhotoPickerForTerminalMedia(
  ImagePickerPlatform imagePickerImplementation,
) {
  final androidImagePicker = imagePickerImplementation is ImagePickerAndroid
      ? imagePickerImplementation
      : ImagePickerAndroid();
  return androidImagePicker..useAndroidPhotoPicker = true;
}

/// Builds a file-picker upload file from native photo-library media.
@visibleForTesting
Future<PlatformFile> platformFileFromPickedTerminalMedia(
  XFile file, {
  int index = 0,
}) async {
  final filePath = file.path;
  if (filePath.isEmpty) {
    throw FileSystemException('Unable to read selected media', file.name);
  }
  var name = file.name.trim().isNotEmpty
      ? file.name.trim()
      : path.basename(filePath);
  // Strip any directory prefix regardless of separator style: some platforms
  // return names with a temp-dir prefix using `/` (or `\` from web/Windows
  // sources), and `path.basename` only splits on the local platform's
  // separator, so split on both explicitly.
  name = name.split(RegExp(r'[/\\]')).last;
  return AppPlatformFile.fromXFile(
    file,
    name: name.isEmpty ? 'selected-media-${index + 1}' : name,
  );
}

/// Trims punctuation that terminals commonly render immediately after a link.
@visibleForTesting
String trimTerminalLinkCandidate(String text) {
  var result = text;
  while (result.isNotEmpty) {
    if (result.endsWith(')')) {
      final openCount = '('.allMatches(result).length;
      final closeCount = ')'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith(']')) {
      final openCount = '['.allMatches(result).length;
      final closeCount = ']'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    } else if (result.endsWith('}')) {
      final openCount = '{'.allMatches(result).length;
      final closeCount = '}'.allMatches(result).length;
      if (closeCount > openCount) {
        result = result.substring(0, result.length - 1);
        continue;
      }
    }

    final lastCharacter = result[result.length - 1];
    if ('.!,?:;'.contains(lastCharacter)) {
      result = result.substring(0, result.length - 1);
      continue;
    }

    break;
  }
  return result;
}

/// Normalizes terminal-rendered link text before URI parsing.
@visibleForTesting
String normalizeTerminalLinkCandidate(String text) {
  final candidate = trimTerminalLinkCandidate(text.trim());
  if (candidate.toLowerCase().startsWith('www.')) {
    return 'https://$candidate';
  }
  return candidate;
}

/// Trims terminal-rendered file paths before SFTP navigation.
@visibleForTesting
String trimTerminalFilePathCandidate(String text) {
  var candidate = trimTerminalLinkCandidate(text.trim());
  candidate = candidate.replaceFirst(
    _terminalFilePathStackTraceSuffixPattern,
    '',
  );
  candidate = candidate.replaceFirst(
    _terminalFilePathShellOperatorSuffixPattern,
    '',
  );
  candidate = _trimWrappedTerminalFilePathCountSuffix(candidate);
  candidate = trimTerminalLinkCandidate(candidate);
  if (RegExp(r'^/?[A-Za-z]:[\\/]').hasMatch(candidate)) {
    return candidate.replaceAll(r'\', '/');
  }
  return candidate;
}

String _trimWrappedTerminalFilePathCountSuffix(String text) {
  final match = _terminalWrappedCountSuffixPattern.firstMatch(text);
  if (match == null || match.start == 0) {
    return text;
  }

  final prefix = text.substring(0, match.start);
  if (!prefix.endsWith(')')) {
    return text;
  }

  final openParenCount = '('.allMatches(prefix).length;
  final closeParenCount = ')'.allMatches(prefix).length;
  if (closeParenCount <= openParenCount) {
    return text;
  }

  final trimmedPrefix = trimTerminalLinkCandidate(prefix);
  if (trimmedPrefix == prefix) {
    return text;
  }

  if (isSupportedTerminalFilePath(trimmedPrefix)) {
    return trimmedPrefix;
  }

  return text;
}

/// Whether a character can safely appear before a supported terminal path.
@visibleForTesting
bool isTerminalFilePathBoundary(String? character) =>
    character == null ||
    character.trim().isEmpty ||
    '([{"\'`=:,'.contains(character);

/// Whether a terminal path can be opened in the remote SFTP browser.
@visibleForTesting
bool isSupportedTerminalFilePath(String path) {
  if (path.isEmpty || path == '.' || path == '..' || path.startsWith('//')) {
    return false;
  }
  return isExplicitTerminalFilePath(path) ||
      isRelativeTerminalFilePathCandidate(path);
}

/// Whether a detected terminal path must be verified before becoming tappable.
@visibleForTesting
bool requiresTerminalFilePathVerification(String path) {
  if (isRelativeTerminalFilePathCandidate(path)) {
    return true;
  }

  if (hasAmbiguousTerminalFilePathParsing(path)) {
    return true;
  }

  if (!path.startsWith('/')) {
    return false;
  }

  final rootSegment = path.substring(1);
  return rootSegment.isNotEmpty &&
      !rootSegment.contains('/') &&
      !rootSegment.contains('.');
}

/// Whether a detected terminal path should currently behave like a link.
@visibleForTesting
bool shouldActivateTerminalFilePath(
  String path, {
  required bool hasVerifiedPath,
}) {
  if (requiresTerminalFilePathVerification(path)) {
    return hasVerifiedPath;
  }

  return isExplicitTerminalFilePath(path);
}

/// Whether a supported terminal path has multiple plausible parse boundaries.
@visibleForTesting
bool hasAmbiguousTerminalFilePathParsing(String path) {
  final lastSlashIndex = path.lastIndexOf('/');
  final basename = lastSlashIndex >= 0
      ? path.substring(lastSlashIndex + 1)
      : path;
  final lowercaseBasename = basename.toLowerCase();
  if (!lowercaseBasename.contains('.')) {
    return false;
  }

  final lastDotIndex = lowercaseBasename.lastIndexOf('.');
  if (lastDotIndex > 0 && lastDotIndex < lowercaseBasename.length - 1) {
    final extension = lowercaseBasename.substring(lastDotIndex + 1);
    if (_terminalFilePathVerificationExtensionSet.contains(extension)) {
      final marker = '.$extension';
      if (lowercaseBasename.indexOf(marker) == lastDotIndex &&
          lowercaseBasename.lastIndexOf(marker) == lastDotIndex) {
        return false;
      }
    }
  }

  return resolveTerminalFilePathVerificationCandidates(path).length > 1;
}

bool _isTerminalFilePathVerificationSuffixCharacter(String character) {
  if (character.isEmpty) {
    return false;
  }

  final codeUnit = character.codeUnitAt(0);
  return (codeUnit >= 48 && codeUnit <= 57) ||
      (codeUnit >= 65 && codeUnit <= 90) ||
      (codeUnit >= 97 && codeUnit <= 122) ||
      codeUnit == 45 ||
      codeUnit == 95;
}

bool _startsWithKnownTerminalFilePathExtensionAndMore(String suffix) {
  if (!suffix.startsWith('.')) {
    return false;
  }

  final lowercaseSuffix = suffix.toLowerCase();
  for (final extension in _terminalFilePathVerificationExtensions) {
    final extensionMarker = '.$extension';
    if (lowercaseSuffix.startsWith(extensionMarker) &&
        suffix.length > extensionMarker.length) {
      return true;
    }
  }
  return false;
}

bool _hasExcessClosingTerminalFilePathBrackets(String value) {
  var openParens = 0;
  var closeParens = 0;
  var openBrackets = 0;
  var closeBrackets = 0;
  var openBraces = 0;
  var closeBraces = 0;

  for (var index = 0; index < value.length; index++) {
    switch (value[index]) {
      case '(':
        openParens++;
        break;
      case ')':
        closeParens++;
        break;
      case '[':
        openBrackets++;
        break;
      case ']':
        closeBrackets++;
        break;
      case '{':
        openBraces++;
        break;
      case '}':
        closeBraces++;
        break;
      default:
        break;
    }
  }

  return closeParens > openParens ||
      closeBrackets > openBrackets ||
      closeBraces > openBraces;
}

/// Alternative terminal-path parses to check when a candidate looks ambiguous.
@visibleForTesting
List<String> resolveTerminalFilePathVerificationCandidates(String path) {
  final candidates = <String>[];
  final seen = <String>{};
  final seedCandidates = <String>[];

  void addCandidate(String candidate) {
    if (candidates.length >= _maxTerminalFilePathVerificationCandidates) {
      return;
    }
    final normalizedCandidate = trimTerminalFilePathCandidate(candidate);
    if (normalizedCandidate.isEmpty ||
        !isSupportedTerminalFilePath(normalizedCandidate) ||
        !seen.add(normalizedCandidate)) {
      return;
    }
    candidates.add(normalizedCandidate);
  }

  void addSeedCandidate(String candidate) {
    final beforeCount = candidates.length;
    addCandidate(candidate);
    if (candidates.length > beforeCount) {
      seedCandidates.add(candidates.last);
    }
  }

  addSeedCandidate(path);

  var trailingBracketCandidate = trimTerminalFilePathCandidate(path);
  if (_hasExcessClosingTerminalFilePathBrackets(trailingBracketCandidate)) {
    while (trailingBracketCandidate.isNotEmpty &&
        ')]}'.contains(
          trailingBracketCandidate[trailingBracketCandidate.length - 1],
        )) {
      trailingBracketCandidate = trailingBracketCandidate.substring(
        0,
        trailingBracketCandidate.length - 1,
      );
      addSeedCandidate(trailingBracketCandidate);
    }
  }

  for (final seed in seedCandidates) {
    final lastSlashIndex = seed.lastIndexOf('/');
    final basename = lastSlashIndex >= 0
        ? seed.substring(lastSlashIndex + 1)
        : seed;
    final basenamePrefix = lastSlashIndex >= 0
        ? seed.substring(0, lastSlashIndex + 1)
        : '';
    final lowercaseBasename = basename.toLowerCase();
    for (final extension in _terminalFilePathVerificationExtensions) {
      final extensionMarker = '.$extension';
      var markerIndex = lowercaseBasename.indexOf(extensionMarker);
      while (markerIndex >= 0) {
        final candidateEnd = markerIndex + extensionMarker.length;
        if (candidateEnd < basename.length) {
          final remainder = basename.substring(candidateEnd);
          if (_isTerminalFilePathVerificationSuffixCharacter(
                basename[candidateEnd],
              ) ||
              _startsWithKnownTerminalFilePathExtensionAndMore(remainder)) {
            addCandidate(
              '$basenamePrefix${basename.substring(0, candidateEnd)}',
            );
          }
        }
        markerIndex = lowercaseBasename.indexOf(
          extensionMarker,
          markerIndex + 1,
        );
      }
    }
  }

  if (candidates.length > 2) {
    final primaryCandidate = candidates.first;
    final alternativeCandidates = candidates.sublist(1)
      ..sort((left, right) => right.length.compareTo(left.length));
    return [primaryCandidate, ...alternativeCandidates];
  }

  return candidates;
}

/// Whether [candidate] is worth probing for existence on the remote host.
///
/// More permissive than [isSupportedTerminalFilePath] so directory prefixes
/// of a detected path (e.g. `lib/foo` from `lib/foo/bar.dart`) can be probed:
/// because every candidate is confirmed with a remote `stat`, the stricter
/// "looks like a file" heuristics used during detection are unnecessary here.
bool _isProbableTerminalPathExistenceCandidate(String candidate) {
  if (candidate.isEmpty ||
      candidate == '~' ||
      candidate == '.' ||
      candidate == '..' ||
      candidate.startsWith('//')) {
    return false;
  }
  if (isExplicitTerminalFilePath(candidate)) {
    return true;
  }
  final segments = candidate.split('/');
  return segments.length >= 2 &&
      segments.every((segment) => segment.isNotEmpty);
}

/// Substrings of [path] to probe for existence, ordered longest first.
///
/// Combines the alternative parses from
/// [resolveTerminalFilePathVerificationCandidates] with directory-prefix
/// walk-backs of each (`a/b/c/d` -> `a/b/c` -> `a/b`), so the verifier can
/// linkify only the longest substring of the path that actually exists on the
/// remote host. Candidates are de-duplicated, restricted to probable paths,
/// and capped so a single path cannot trigger an unbounded number of remote
/// `stat` probes.
@visibleForTesting
List<String> resolveTerminalFilePathExistenceCandidates(String path) {
  final ordered = <String>[];
  final seen = <String>{};

  void add(String candidate) {
    final normalized = trimTerminalFilePathCandidate(candidate);
    if (!_isProbableTerminalPathExistenceCandidate(normalized) ||
        !seen.add(normalized)) {
      return;
    }
    ordered.add(normalized);
  }

  for (final parse in resolveTerminalFilePathVerificationCandidates(path)) {
    add(parse);
    var prefix = parse;
    final root = sftpPathRoot(prefix);
    var slashIndex = prefix.lastIndexOf('/');
    while (slashIndex > 0) {
      if (root != null && slashIndex < root.length) {
        break;
      }
      prefix = prefix.substring(0, slashIndex);
      add(prefix);
      slashIndex = prefix.lastIndexOf('/');
    }
  }

  ordered.sort((left, right) => right.length.compareTo(left.length));
  if (ordered.length > _maxTerminalFilePathVerificationCandidates) {
    return ordered.sublist(0, _maxTerminalFilePathVerificationCandidates);
  }
  return ordered;
}

/// Candidate terminal cells to probe for a touch-friendly path hit test.
@visibleForTesting
List<CellOffset> resolveForgivingTerminalTapOffsets(CellOffset offset) {
  final offsets = <CellOffset>[];
  final seen = <String>{};

  void addOffset(int dx, int dy) {
    final candidate = CellOffset(offset.x + dx, offset.y + dy);
    final key = '${candidate.x}:${candidate.y}';
    if (seen.add(key)) {
      offsets.add(candidate);
    }
  }

  addOffset(0, 0);
  for (var dx = 1; dx <= 4; dx++) {
    addOffset(-dx, 0);
    addOffset(dx, 0);
  }
  for (final dy in const [-1, 1]) {
    addOffset(0, dy);
    for (var dx = 1; dx <= 2; dx++) {
      addOffset(-dx, dy);
      addOffset(dx, dy);
    }
  }

  return offsets;
}

/// Visible terminal rows for the current scroll offset and rendered viewport.
@visibleForTesting
({int topRow, int bottomRow})? resolveVisibleTerminalRowRange({
  required double scrollOffset,
  required double lineHeight,
  required double viewportHeight,
  required int bufferHeight,
}) {
  if (lineHeight <= 0 || viewportHeight <= 0 || bufferHeight <= 0) {
    return null;
  }

  final maxRow = bufferHeight - 1;
  final topRow = (scrollOffset / lineHeight).floor().clamp(0, maxRow);
  final visibleRows = (viewportHeight / lineHeight).ceil().clamp(
    1,
    bufferHeight,
  );
  final bottomRow = (topRow + visibleRows - 1).clamp(0, maxRow);
  return (topRow: topRow, bottomRow: bottomRow);
}

/// Builds a terminal cell range for inline path underline painting.
@visibleForTesting
TerminalTextUnderline? resolveTerminalPathInlineUnderline({
  required int row,
  required int startColumn,
  required int endColumn,
  required int rowCount,
  required int columnCount,
}) {
  if (row < 0 || row >= rowCount || columnCount <= 0) {
    return null;
  }

  final normalizedStart = startColumn.clamp(0, columnCount - 1);
  final normalizedEnd = endColumn.clamp(0, columnCount - 1);
  if (normalizedStart > normalizedEnd) {
    return null;
  }
  return (row: row, startColumn: normalizedStart, endColumn: normalizedEnd);
}

/// Builds a forgiving touch target around a terminal path segment.
@visibleForTesting
Rect? resolveTerminalPathTouchTargetRect({
  required Offset lineTopLeft,
  required Offset lineEndOffset,
  required double lineHeight,
  required double viewportHeight,
  double horizontalPadding = _terminalPathTouchHorizontalPadding,
  double verticalPadding = _terminalPathTouchVerticalPadding,
}) {
  final width = lineEndOffset.dx - lineTopLeft.dx;
  if (width <= 0 || lineHeight <= 0 || viewportHeight <= 0) {
    return null;
  }

  final left = (lineTopLeft.dx - horizontalPadding).clamp(0.0, double.infinity);
  final top = (lineTopLeft.dy - verticalPadding).clamp(0.0, viewportHeight);
  final right = lineEndOffset.dx + horizontalPadding;
  final bottom = (lineTopLeft.dy + lineHeight + verticalPadding).clamp(
    top,
    viewportHeight,
  );
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Resolves which visible terminal path touch target, if any, a tap landed on.
@visibleForTesting
String? resolveTerminalPathTouchTargetTap(
  Offset localPosition,
  List<({String path, Rect touchRect})> targets,
) {
  for (final target in targets.reversed) {
    if (target.touchRect.contains(localPosition)) {
      return target.path;
    }
  }
  return null;
}

/// Whether a terminal path is anchored to `/`, `~`, or a Windows drive root.
@visibleForTesting
bool isExplicitTerminalFilePath(String path) =>
    isSftpAbsolutePath(path) || path == '~' || path.startsWith('~/');

/// Whether a relative terminal path looks file-like enough to probe safely.
@visibleForTesting
bool isRelativeTerminalFilePathCandidate(String path) {
  if (isExplicitTerminalFilePath(path) ||
      path.isEmpty ||
      path == '.' ||
      path == '..' ||
      path.startsWith('//') ||
      !path.contains('/')) {
    return false;
  }

  if (path.startsWith('./') || path.startsWith('../')) {
    return true;
  }

  final basename = path.split('/').last;
  return basename.contains('.');
}

bool _isTerminalFilePathBodyCharacter(String character) =>
    character.isNotEmpty &&
    !RegExp(r'''[\s<>"'$#]''').hasMatch(character) &&
    !_isTerminalPathContinuationDecorationCharacter(character);

bool _isTerminalPathContinuationDecorationCharacter(String character) {
  if (character.isEmpty) {
    return false;
  }
  if (character == ' ' || character == '\t' || character == '|') {
    return true;
  }
  // The Unicode "Box Drawing" (U+2500–U+257F) and "Block Elements"
  // (U+2580–U+259F) ranges cover the borders, separators, gutters, and
  // scrollbar glyphs that terminal UIs paint around their content. None of
  // these characters appear inside a file path, so treating them as decoration
  // lets a path span a rendered line break even when a tool draws chrome (such
  // as a right-edge scrollbar) between the fragments.
  final codeUnit = character.codeUnitAt(0);
  return codeUnit >= 0x2500 && codeUnit <= 0x259F;
}

String _trimTerminalPathContinuationPrefix(String text) {
  var index = 0;
  while (index < text.length &&
      _isTerminalPathContinuationDecorationCharacter(text[index])) {
    index++;
  }
  return text.substring(index);
}

String _trimTerminalPathContinuationSuffix(String text) {
  var end = text.length;
  while (end > 0 &&
      _isTerminalPathContinuationDecorationCharacter(text[end - 1])) {
    end--;
  }
  return text.substring(0, end);
}

/// Whether [character] is gutter/border chrome (a box-drawing, block-element,
/// or pipe glyph) rather than plain whitespace padding.
///
/// A real URL wrap across a hard rendered-line break leaves such chrome (a
/// scrollbar thumb or box border) between the fragments; a plain prose newline
/// or trailing space padding does not.
bool _isTerminalGutterDecorationCharacter(String character) =>
    character != ' ' &&
    character != '\t' &&
    _isTerminalPathContinuationDecorationCharacter(character);

bool _terminalTextRangeHasGutterDecoration(String text, int start, int end) {
  for (var index = start; index < end; index++) {
    if (_isTerminalGutterDecorationCharacter(text[index])) {
      return true;
    }
  }
  return false;
}

bool _startsFreshTerminalFilePathLine(String text) =>
    text == '~' ||
    text.startsWith('~/') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(text) ||
    text.startsWith('/') ||
    text.startsWith('./') ||
    text.startsWith('../');

String? _leadingTerminalFilePathCandidate(String text) {
  final match = _terminalFilePathPattern.matchAsPrefix(text);
  if (match == null) {
    return null;
  }

  final candidate = trimTerminalFilePathCandidate(match.group(0)!);
  return isSupportedTerminalFilePath(candidate) ? candidate : null;
}

bool _hasMeaningfulTextBeforeTrailingTerminalPath(
  String text,
  Match trailingPathMatch,
) => _trimTerminalPathContinuationPrefix(
  text.substring(0, trailingPathMatch.start),
).trim().isNotEmpty;

bool _endsWithTerminalPathContinuationBoundary(String path) =>
    path == '~' || path.endsWith('/');

bool _hasLeadingTerminalPathFragment(String text) =>
    text.isNotEmpty && _isTerminalFilePathBodyCharacter(text[0]);

bool _looksLikeTerminalPathContinuationAcrossRenderedLines({
  required String previousText,
  required String nextText,
}) {
  final trimmedPreviousText = _trimTerminalPathContinuationSuffix(previousText);
  final trimmedNextText = trimTerminalLinePadding(nextText);
  if (trimmedPreviousText.isEmpty || trimmedNextText.isEmpty) {
    return false;
  }
  if (_terminalStandalonePathMetadataPattern.hasMatch(trimmedNextText)) {
    return false;
  }

  final previousPathMatch = _terminalFilePathLineSuffixPattern.firstMatch(
    trimmedPreviousText,
  );
  if (previousPathMatch == null) {
    return false;
  }

  final previousPath = trimTerminalFilePathCandidate(
    previousPathMatch.group(0)!,
  );
  final previousHasLeadingContext =
      _hasMeaningfulTextBeforeTrailingTerminalPath(
        trimmedPreviousText,
        previousPathMatch,
      );
  final previousEndsWithBoundary = _endsWithTerminalPathContinuationBoundary(
    previousPath,
  );
  final nextLeadingPath = _leadingTerminalFilePathCandidate(trimmedNextText);

  if (_startsFreshTerminalFilePathLine(trimmedNextText)) {
    return previousHasLeadingContext || previousEndsWithBoundary;
  }

  if (nextLeadingPath != null && !isExplicitTerminalFilePath(nextLeadingPath)) {
    if (!previousHasLeadingContext &&
        !previousEndsWithBoundary &&
        !isExplicitTerminalFilePath(previousPath)) {
      return false;
    }
    return true;
  }

  return _hasLeadingTerminalPathFragment(trimmedNextText);
}

/// Whether adjacent rendered lines should be treated as one file-path span.
@visibleForTesting
bool isTerminalPathContinuationAcrossLines({
  required String previousLineText,
  required String nextLineText,
}) => _looksLikeTerminalPathContinuationAcrossRenderedLines(
  previousText: previousLineText,
  nextText: _trimTerminalPathContinuationPrefix(nextLineText),
);

/// Whether a terminal buffer row may contain path-like content.
///
/// Performs a quick scan of raw codepoints to filter rows that are unlikely
/// to contain file paths, avoiding the more expensive snapshot-building work.
/// Returns `true` if any column contains `/` (0x2F), `\` (0x5C), or `~` (0x7E),
/// which are necessary for detectable POSIX, Windows drive-letter,
/// home-relative, or relative paths.
///
/// Only intended as a fast pre-filter; rows that return `true` are not
/// guaranteed to actually contain a valid path.
@visibleForTesting
bool terminalRowMayContainPath(BufferLine line, int viewWidth) {
  for (var col = 0; col < viewWidth; col++) {
    final cp = line.getCodePoint(col);
    if (cp == 0x2f /* / */ || cp == 0x5c /* \ */ || cp == 0x7e /* ~ */ ) {
      return true;
    }
  }
  return false;
}

_NormalizedTerminalPathSnapshot _normalizeTerminalFilePathDetectionText(
  String text, {
  bool Function({
    required String previousText,
    required String nextText,
    required bool hadGutterDecoration,
  })?
  continuationPredicate,
}) {
  bool isContinuation({
    required String previousText,
    required String nextText,
    required bool hadGutterDecoration,
  }) {
    if (continuationPredicate != null) {
      return continuationPredicate(
        previousText: previousText,
        nextText: nextText,
        hadGutterDecoration: hadGutterDecoration,
      );
    }
    return _looksLikeTerminalPathContinuationAcrossRenderedLines(
      previousText: previousText,
      nextText: nextText,
    );
  }

  final normalizedCharacters = <String>[];
  final originalToNormalizedOffsets = List<int>.filled(text.length + 1, 0);
  final normalizedToOriginalStarts = <int>[];
  final normalizedToOriginalEnds = <int>[];
  var index = 0;
  var lineStart = 0;

  while (index < text.length) {
    final character = text[index];
    if (character == '\r' || character == '\n') {
      var lineBreakEnd = index + 1;
      if (character == '\r' &&
          lineBreakEnd < text.length &&
          text[lineBreakEnd] == '\n') {
        lineBreakEnd++;
      }

      var continuationEnd = lineBreakEnd;
      while (continuationEnd < text.length &&
          _isTerminalPathContinuationDecorationCharacter(
            text[continuationEnd],
          )) {
        continuationEnd++;
      }

      var nextLineEnd = continuationEnd;
      while (nextLineEnd < text.length &&
          text[nextLineEnd] != '\r' &&
          text[nextLineEnd] != '\n') {
        nextLineEnd++;
      }

      // Walk back over trailing decoration on the previous line (padding plus
      // any gutter or scrollbar glyph painted in its rightmost columns) so a
      // fragment that ends before the chrome can still join its continuation.
      var trailingGapStart = index;
      while (trailingGapStart > lineStart &&
          _isTerminalPathContinuationDecorationCharacter(
            text[trailingGapStart - 1],
          )) {
        trailingGapStart--;
      }

      final hadGutterDecoration =
          _terminalTextRangeHasGutterDecoration(
            text,
            trailingGapStart,
            index,
          ) ||
          _terminalTextRangeHasGutterDecoration(
            text,
            lineBreakEnd,
            continuationEnd,
          );

      final isPathContinuation =
          continuationEnd < text.length &&
          isContinuation(
            previousText: text.substring(lineStart, trailingGapStart),
            nextText: text.substring(continuationEnd, nextLineEnd),
            hadGutterDecoration: hadGutterDecoration,
          );
      if (isPathContinuation) {
        // Drop the trailing gap characters already emitted for the previous
        // line so the joined path stays contiguous in the normalized text.
        final trailingGapLength = index - trailingGapStart;
        if (trailingGapLength > 0) {
          normalizedCharacters.removeRange(
            normalizedCharacters.length - trailingGapLength,
            normalizedCharacters.length,
          );
          normalizedToOriginalStarts.removeRange(
            normalizedToOriginalStarts.length - trailingGapLength,
            normalizedToOriginalStarts.length,
          );
          normalizedToOriginalEnds.removeRange(
            normalizedToOriginalEnds.length - trailingGapLength,
            normalizedToOriginalEnds.length,
          );
        }
        for (
          var skippedIndex = trailingGapStart;
          skippedIndex < continuationEnd;
          skippedIndex++
        ) {
          originalToNormalizedOffsets[skippedIndex] =
              normalizedCharacters.length;
        }
        lineStart = lineBreakEnd;
        index = continuationEnd;
        continue;
      }

      final normalizedIndex = normalizedCharacters.length;
      for (var sourceIndex = index; sourceIndex < lineBreakEnd; sourceIndex++) {
        originalToNormalizedOffsets[sourceIndex] = normalizedIndex;
      }
      normalizedCharacters.add('\n');
      normalizedToOriginalStarts.add(index);
      normalizedToOriginalEnds.add(lineBreakEnd);
      lineStart = lineBreakEnd;
      index = lineBreakEnd;
      continue;
    }

    final normalizedIndex = normalizedCharacters.length;
    originalToNormalizedOffsets[index] = normalizedIndex;
    normalizedCharacters.add(character);
    normalizedToOriginalStarts.add(index);
    normalizedToOriginalEnds.add(index + 1);
    index++;
  }

  originalToNormalizedOffsets[text.length] = normalizedCharacters.length;
  return (
    text: normalizedCharacters.join(),
    originalToNormalizedOffsets: originalToNormalizedOffsets,
    normalizedToOriginalStarts: normalizedToOriginalStarts,
    normalizedToOriginalEnds: normalizedToOriginalEnds,
  );
}

List<_TerminalPathMatch> _detectTerminalFilePathMatches(
  _NormalizedTerminalPathSnapshot normalizedText,
) {
  final detectedPaths = <_TerminalPathMatch>[];

  for (final match in _terminalFilePathPattern.allMatches(
    normalizedText.text,
  )) {
    final previousCharacter = match.start == 0
        ? null
        : normalizedText.text.substring(match.start - 1, match.start);
    if (!isTerminalFilePathBoundary(previousCharacter)) {
      continue;
    }

    final candidate = trimTerminalFilePathCandidate(match.group(0)!);
    if (!isSupportedTerminalFilePath(candidate)) {
      continue;
    }

    final visualEnd = match.start + candidate.length;
    final originalStart =
        normalizedText.normalizedToOriginalStarts[match.start];
    final originalEnd = normalizedText.normalizedToOriginalEnds[visualEnd - 1];
    final originalHitTestEnd =
        normalizedText.normalizedToOriginalEnds[match.end - 1];
    detectedPaths.add((
      path: candidate,
      start: originalStart,
      end: originalEnd,
      hitTestEnd: originalHitTestEnd,
      normalizedStart: match.start,
      normalizedEnd: visualEnd,
    ));
  }

  return detectedPaths;
}

/// Resolves the visible row segment for the first matching path on a row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRowForPath({
  required String snapshotText,
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required String path,
}) {
  final normalizedSnapshot = _normalizeTerminalFilePathDetectionText(
    snapshotText,
  );
  for (final match in _detectTerminalFilePathMatches(normalizedSnapshot)) {
    if (match.path != path) {
      continue;
    }
    final segment = resolveTerminalFilePathSegmentOnRow(
      rowText: rowText,
      rowStartOffset: rowStartOffset,
      rowColumnOffsets: rowColumnOffsets,
      originalToNormalizedOffsets:
          normalizedSnapshot.originalToNormalizedOffsets,
      normalizedPathStart: match.normalizedStart,
      normalizedPathEnd: match.normalizedEnd,
    );
    if (segment != null) {
      return segment;
    }
  }
  return null;
}

/// Resolves the visible path-only segment for a specific rendered row.
@visibleForTesting
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRow({
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required List<int> originalToNormalizedOffsets,
  required int normalizedPathStart,
  required int normalizedPathEnd,
}) {
  if (rowText.isEmpty || rowColumnOffsets.length < 2) {
    return null;
  }

  int? startColumn;
  int? endColumn;
  for (var column = 0; column < rowColumnOffsets.length - 1; column++) {
    final textStart = rowColumnOffsets[column];
    if (textStart < 0 || textStart >= rowText.length) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    final textEnd = rowColumnOffsets[column + 1].clamp(
      textStart + 1,
      rowText.length,
    );
    final character = rowText.substring(textStart, textEnd);
    if (!_isTerminalFilePathBodyCharacter(character)) {
      if (startColumn != null) {
        break;
      }
      continue;
    }

    final normalizedOffset =
        originalToNormalizedOffsets[rowStartOffset + textStart];
    if (normalizedOffset < normalizedPathStart ||
        normalizedOffset >= normalizedPathEnd) {
      if (startColumn != null) {
        break;
      }
      continue;
    }
    startColumn ??= column;
    endColumn = column;
  }

  if (startColumn == null || endColumn == null) {
    return null;
  }

  final segmentStart = rowColumnOffsets[startColumn];
  final segmentEnd = rowColumnOffsets[endColumn + 1].clamp(
    segmentStart + 1,
    rowText.length,
  );
  return (
    text: rowText.substring(segmentStart, segmentEnd),
    startColumn: startColumn,
    endColumn: endColumn,
  );
}

/// Resolves all tappable terminal file paths within the given text.
@visibleForTesting
List<({String path, int start, int end})> detectTerminalFilePaths(
  String text,
) => [
  for (final path in _detectTerminalFilePathMatches(
    _normalizeTerminalFilePathDetectionText(text),
  ))
    (path: path.path, start: path.start, end: path.end),
];

/// Resolves a tappable terminal file path at the given text offset, if present.
@visibleForTesting
({String path, int start, int end})? detectTerminalFilePathAtTextOffset(
  String text,
  int offset,
) {
  final clampedOffset = offset.clamp(0, text.length);
  for (final detectedPath in _detectTerminalFilePathMatches(
    _normalizeTerminalFilePathDetectionText(text),
  )) {
    if (clampedOffset >= detectedPath.start &&
        clampedOffset < detectedPath.hitTestEnd) {
      return (
        path: detectedPath.path,
        start: detectedPath.start,
        end: detectedPath.end,
      );
    }
  }

  return null;
}

/// Matches a terminal list-item marker (e.g. `- `, `* `, `+ `, `1. `) so a
/// wrapped URL is not joined to the next bullet.
final _terminalListMarkerPattern = RegExp(r'^(?:[-*+]\s|\d+[.)]\s)');

/// Whether [text] ends inside an unterminated terminal link token.
///
/// True when the last whitespace-delimited token carries a link scheme (so the
/// URL runs to the end of the rendered line and likely continues on the next).
bool _endsInsideTerminalLinkToken(String text) {
  final trimmed = _trimTerminalPathContinuationSuffix(text);
  if (trimmed.isEmpty) {
    return false;
  }
  // Strip any leading decoration (e.g. a box border flush against the URL with
  // no separating space, as a TUI char-wraps a URL against its right edge) so
  // the token is recognized as a link rather than starting with the border.
  final lastToken = _trimTerminalPathContinuationPrefix(
    trimmed.split(RegExp(r'\s')).last,
  );
  return _terminalLinkPattern.matchAsPrefix(lastToken) != null;
}

/// Continuation rule for terminal links: only rejoin a wrapped URL fragment,
/// never two separate links or a link and a following list item.
bool _looksLikeTerminalLinkContinuationAcrossRenderedLines({
  required String previousText,
  required String nextText,
  required bool hadGutterDecoration,
}) {
  // Only rejoin a URL across a hard rendered-line break when gutter/border
  // chrome (a scrollbar thumb or box border, e.g. the Copilot CLI box this
  // feature targets) was actually stripped at the boundary. A plain prose
  // newline such as `https://example.com` then `Done.` leaves no chrome, so the
  // next line must not be welded onto the URL. Soft-wrapped lines never reach
  // this path: the snapshot concatenates them without a newline.
  if (!hadGutterDecoration) {
    return false;
  }
  if (!_endsInsideTerminalLinkToken(previousText)) {
    return false;
  }
  final trimmedNext = _trimTerminalPathContinuationPrefix(nextText);
  if (trimmedNext.isEmpty ||
      _terminalListMarkerPattern.hasMatch(trimmedNext) ||
      _terminalLinkPattern.matchAsPrefix(trimmedNext) != null) {
    return false;
  }
  return _isTerminalFilePathBodyCharacter(trimmedNext[0]);
}

/// Resolves a tappable terminal link at the given text offset, if present.
///
/// The text is first normalized so a URL split across rendered lines (e.g. a
/// long URL wrapped inside a program's bordered TUI, with gutter/scrollbar
/// decoration between fragments) is rejoined before matching — mirroring the
/// cross-line reconstruction used for file paths.
@visibleForTesting
({Uri uri, int start, int end})? detectTerminalLinkAtTextOffset(
  String text,
  int offset,
) {
  final normalized = _normalizeTerminalFilePathDetectionText(
    text,
    continuationPredicate:
        _looksLikeTerminalLinkContinuationAcrossRenderedLines,
  );
  final clampedOffset = offset.clamp(0, text.length);
  final normalizedOffset =
      normalized.originalToNormalizedOffsets[clampedOffset];

  for (final match in _terminalLinkPattern.allMatches(normalized.text)) {
    final candidate = trimTerminalLinkCandidate(match.group(0)!);
    if (candidate.isEmpty) {
      continue;
    }

    final normalizedCandidate = normalizeTerminalLinkCandidate(candidate);
    final uri = Uri.tryParse(normalizedCandidate);
    if (uri == null || !isResolvableTerminalLinkUri(uri)) {
      continue;
    }

    final normalizedEnd = match.start + candidate.length;
    if (normalizedOffset >= match.start && normalizedOffset < normalizedEnd) {
      return (
        uri: uri,
        start: normalized.normalizedToOriginalStarts[match.start],
        end: normalized.normalizedToOriginalEnds[normalizedEnd - 1],
      );
    }
  }

  return null;
}

/// Whether a parsed terminal URI is safe to open externally.
@visibleForTesting
bool isLaunchableTerminalUri(Uri uri) =>
    uri.hasScheme &&
    <String>{
      'http',
      'https',
      'mailto',
      'tel',
    }.contains(uri.scheme.toLowerCase());

/// Whether a parsed terminal URI is a `file:` link with a usable path.
///
/// A `file:` link names a file on the connected host, so it opens in the SFTP
/// browser instead of being launched externally. A bare `file://host` (which
/// Dart normalizes to a `/` path) names no file and is rejected.
@visibleForTesting
bool isTerminalFileUri(Uri uri) =>
    uri.scheme.toLowerCase() == 'file' &&
    uri.path.isNotEmpty &&
    uri.path != '/';

/// Whether a parsed terminal URI resolves to a tappable target: either an
/// externally launchable link or a `file:` link routed to the SFTP browser.
@visibleForTesting
bool isResolvableTerminalLinkUri(Uri uri) =>
    isLaunchableTerminalUri(uri) || isTerminalFileUri(uri);

/// Resolves the remote path a terminal `file:` link should open in the SFTP
/// browser, or `null` when [link] is not a usable `file:` URI.
///
/// The URI host (if any) is ignored: the path is opened on the host the
/// terminal session is connected to. Percent-encoding is decoded so the SFTP
/// browser receives the literal path (e.g. `%20` becomes a space).
@visibleForTesting
String? resolveTerminalFileUriPath(String link) {
  final uri = Uri.tryParse(normalizeTerminalLinkCandidate(link));
  if (uri == null || !isTerminalFileUri(uri)) {
    return null;
  }
  return Uri.decodeComponent(uri.path);
}

/// Chooses the platform keyboard appearance that best matches a terminal theme.
@visibleForTesting
Brightness resolveTerminalKeyboardAppearance(TerminalThemeData theme) =>
    theme.isDark ? Brightness.dark : Brightness.light;

/// Applies pasted or rendered text at the terminal cursor within a wrapped line.
@visibleForTesting
String applyTerminalCursorInsertion({
  required String currentText,
  required int cursorOffset,
  required String insertedText,
}) => currentText.replaceRange(cursorOffset, cursorOffset, insertedText);

/// Applies terminal-style backspaces before inserting newly committed text.
@visibleForTesting
String applyTerminalInputDelta({
  required String currentText,
  required int cursorOffset,
  required int deletedCount,
  required String appendedText,
}) {
  final deleteStart = cursorOffset > deletedCount
      ? cursorOffset - deletedCount
      : 0;
  return currentText.replaceRange(deleteStart, cursorOffset, appendedText);
}

/// Applies shell-completion-triggering terminal output to a command snapshot.
@visibleForTesting
({String text, int cursorOffset}) applyShellCompletionOutputToSnapshot({
  required ({String text, int cursorOffset}) snapshot,
  required String output,
}) {
  final cursorOffset = min(max(snapshot.cursorOffset, 0), snapshot.text.length);
  if (output == '\x7F' || output == '\b') {
    final deleteStart = cursorOffset > 0 ? cursorOffset - 1 : 0;
    return (
      text: snapshot.text.replaceRange(deleteStart, cursorOffset, ''),
      cursorOffset: deleteStart,
    );
  }

  return (
    text: snapshot.text.replaceRange(cursorOffset, cursorOffset, output),
    cursorOffset: cursorOffset + output.length,
  );
}

@visibleForTesting
/// Resolves how much of a terminal row snapshot should remain after trimming.
int resolveTerminalLineSnapshotTextLength({
  required String text,
  required int preserveOffset,
  required bool preserveTrailingPadding,
}) {
  if (preserveTrailingPadding) {
    return text.length;
  }

  final trimmedLength = trimTerminalLinePadding(text).length;
  var clampedPreserveOffset = preserveOffset;
  if (clampedPreserveOffset < 0) {
    clampedPreserveOffset = 0;
  } else if (clampedPreserveOffset > text.length) {
    clampedPreserveOffset = text.length;
  }
  return trimmedLength >= clampedPreserveOffset
      ? trimmedLength
      : clampedPreserveOffset;
}

/// Whether to let xterm synthesize Up/Down keys for alt-buffer scroll.
///
/// We prefer explicit mouse-wheel reporting from terminal applications like
/// tmux, but still need the synthetic fallback whenever the active alt-buffer
/// app has not enabled wheel reporting yet.
@visibleForTesting
bool shouldUseSyntheticAltBufferScrollFallback({
  required bool isUsingAltBuffer,
  required bool preferExplicitMouseReporting,
  required bool terminalReportsMouseWheel,
  bool isAgentToolActive = false,
}) {
  if (!isUsingAltBuffer) {
    return false;
  }

  if (isAgentToolActive) {
    return false;
  }

  if (!preferExplicitMouseReporting) {
    return true;
  }

  return !terminalReportsMouseWheel;
}

/// Whether mobile touch drags should be routed into terminal scroll input.
///
/// Full-screen apps like tmux need direct wheel or synthetic arrow events
/// instead of letting the Flutter viewport absorb the gesture. Agent tools are
/// excluded because arrow events navigate prompt history.
@visibleForTesting
bool shouldRouteTouchScrollToTerminal({
  required bool isMobile,
  required bool isUsingAltBuffer,
  required bool terminalReportsMouseWheel,
  bool isAgentToolActive = false,
}) =>
    isMobile &&
    (terminalReportsMouseWheel || (isUsingAltBuffer && !isAgentToolActive));

/// Resolves the effective mouse-wheel state for scroll routing.
@visibleForTesting
bool terminalReportsMouseWheelForScroll({
  required bool localTerminalReportsMouseWheel,
  bool? activeWindowReportsMouseWheel,
}) =>
    localTerminalReportsMouseWheel || (activeWindowReportsMouseWheel ?? false);

/// Whether the active terminal context is a known agent tool for scroll policy.
@visibleForTesting
bool isAgentToolActiveForTerminalScroll({
  required AgentLaunchTool? activeWindowTool,
  required AgentLaunchTool? startupTool,
  required bool hasWindowSnapshot,
  String? currentCommand,
}) {
  if (activeWindowTool != null) {
    return true;
  }
  final command = currentCommand?.trim();
  if (command != null && agentLaunchToolForCommandName(command) != null) {
    return true;
  }
  return !hasWindowSnapshot && startupTool != null;
}

/// Whether touch scroll should send SGR wheel reports from mux metadata even
/// when local xterm mouse-mode state is stale.
@visibleForTesting
bool shouldForceSgrTouchScroll({
  bool? activeWindowReportsMouseWheel,
  bool? activeWindowMouseReportSgr,
}) =>
    (activeWindowReportsMouseWheel ?? false) &&
    (activeWindowMouseReportSgr ?? false);

/// Builds terminal selection context menu items with terminal-aware callbacks.
@visibleForTesting
List<ContextMenuButtonItem> buildTerminalSelectionContextMenuButtonItems({
  required List<ContextMenuButtonItem> defaultItems,
  required VoidCallback onCopy,
  required VoidCallback onLookUp,
  required VoidCallback onSearchWeb,
  required VoidCallback onShare,
  required VoidCallback? onCreateSnippet,
  required VoidCallback onPaste,
}) {
  var hasCopy = false;
  var addedCreateSnippet = false;
  final buttonItems = <ContextMenuButtonItem>[];

  void addCreateSnippet() {
    if (onCreateSnippet == null || addedCreateSnippet) {
      return;
    }
    addedCreateSnippet = true;
    buttonItems.add(
      ContextMenuButtonItem(
        label: 'Create Snippet',
        onPressed: onCreateSnippet,
      ),
    );
  }

  for (final item in defaultItems) {
    switch (item.type) {
      case ContextMenuButtonType.copy:
        hasCopy = true;
        buttonItems.add(item.copyWith(onPressed: onCopy));
        addCreateSnippet();
      case ContextMenuButtonType.lookUp:
        buttonItems.add(item.copyWith(onPressed: onLookUp));
      case ContextMenuButtonType.searchWeb:
        buttonItems.add(item.copyWith(onPressed: onSearchWeb));
      case ContextMenuButtonType.share:
        buttonItems.add(item.copyWith(onPressed: onShare));
      case ContextMenuButtonType.selectAll:
      case ContextMenuButtonType.cut:
      case ContextMenuButtonType.delete:
        continue;
      case ContextMenuButtonType.paste:
        continue;
      default:
        buttonItems.add(item);
    }
  }
  if (!hasCopy) {
    buttonItems.insert(
      0,
      ContextMenuButtonItem(
        onPressed: onCopy,
        type: ContextMenuButtonType.copy,
      ),
    );
    if (onCreateSnippet != null) {
      buttonItems.insert(
        1,
        ContextMenuButtonItem(
          label: 'Create Snippet',
          onPressed: onCreateSnippet,
        ),
      );
      addedCreateSnippet = true;
    }
  }
  if (!addedCreateSnippet) {
    addCreateSnippet();
  }
  buttonItems.add(
    ContextMenuButtonItem(
      onPressed: onPaste,
      type: ContextMenuButtonType.paste,
    ),
  );
  return buttonItems;
}

/// Builds a menu callback that lets the action read selection before hiding.
@visibleForTesting
VoidCallback buildTerminalSelectionContextMenuAction({
  required VoidCallback action,
  required VoidCallback hideToolbar,
}) => () {
  try {
    action();
  } finally {
    hideToolbar();
  }
};

/// Builds an editable snippet name from selected terminal text.
@visibleForTesting
String buildSnippetNameFromTerminalSelection(String text) {
  for (final line in text.split('\n')) {
    final candidate = line.trim();
    if (candidate.isEmpty) {
      continue;
    }
    if (candidate.length <= _terminalSelectionSnippetNameMaxLength) {
      return candidate;
    }
    return '${candidate.substring(0, _terminalSelectionSnippetNameMaxLength - 3)}...';
  }
  return 'Terminal selection';
}

/// Resolves the active terminal selection text, preferring the xterm
/// controller's selection but falling back to the SelectionArea's content
/// when system selection (mobile) owns the selection.
@visibleForTesting
String? resolveTerminalSelectionPlainText({
  required String? terminalControllerSelectionText,
  required String? systemSelectionPlainText,
}) {
  if (terminalControllerSelectionText != null &&
      terminalControllerSelectionText.isNotEmpty) {
    return terminalControllerSelectionText;
  }
  if (systemSelectionPlainText != null && systemSelectionPlainText.isNotEmpty) {
    return systemSelectionPlainText;
  }
  return null;
}

/// Whether a polled remote clipboard value should replace the local clipboard.
@visibleForTesting
bool shouldApplyRemoteClipboardTextToLocal({
  required String? remoteText,
  required String? lastObservedRemoteText,
  required String? lastObservedLocalText,
  required String? lastAppliedRemoteText,
  required String? recentLocalClipboardText,
  required DateTime? recentLocalClipboardAt,
  required DateTime now,
  Duration recentLocalClipboardProtection = _recentLocalClipboardProtection,
}) {
  if (remoteText == null || remoteText.isEmpty) {
    return false;
  }
  if (remoteText == lastObservedRemoteText ||
      remoteText == lastObservedLocalText ||
      remoteText == lastAppliedRemoteText) {
    return false;
  }
  if (recentLocalClipboardText != null && recentLocalClipboardAt != null) {
    final isProtectedRecentLocalWrite =
        now.difference(recentLocalClipboardAt) < recentLocalClipboardProtection;
    if (remoteText == recentLocalClipboardText || isProtectedRecentLocalWrite) {
      return false;
    }
  }
  return true;
}

/// Whether terminal tap links should be resolved for the current overlay state.
@visibleForTesting
bool shouldResolveTerminalTapLinks({
  required bool showsNativeSelectionOverlay,
}) => !showsNativeSelectionOverlay;

String? _describeMouseMode(
  MouseMode mouseMode,
  MouseReportMode mouseReportMode,
) => switch (mouseMode) {
  MouseMode.none => null,
  MouseMode.clickOnly => 'Mouse clicks',
  MouseMode.upDownScroll => 'Mouse scroll (${mouseReportMode.name})',
  MouseMode.upDownScrollDrag => 'Mouse drag (${mouseReportMode.name})',
  MouseMode.upDownScrollMove => 'Mouse motion (${mouseReportMode.name})',
};

/// Whether live terminal output should keep following the current viewport.
@visibleForTesting
bool shouldFollowTerminalOutput({
  required bool hasScrollClients,
  required double currentOffset,
  required double maxScrollExtent,
  double tolerance = _terminalFollowOutputTolerance,
}) {
  if (!hasScrollClients) {
    return true;
  }

  return currentOffset >= maxScrollExtent - tolerance;
}

/// Whether terminal scroll policy state changed enough to require a rebuild.
@visibleForTesting
bool didTerminalScrollPolicyChange({
  required bool previousIsUsingAltBuffer,
  required bool nextIsUsingAltBuffer,
  required bool previousReportsMouseWheel,
  required bool nextReportsMouseWheel,
}) =>
    previousIsUsingAltBuffer != nextIsUsingAltBuffer ||
    previousReportsMouseWheel != nextReportsMouseWheel;

enum _TerminalExclusiveAction { sftpBrowser, tmuxNavigator }

class _PortForwardBrowserOption {
  const _PortForwardBrowserOption({
    required this.uri,
    required this.sourceUri,
    required this.fallbackUri,
    required this.port,
    required this.title,
    required this.group,
  });

  final Uri uri;
  final Uri sourceUri;
  final Uri? fallbackUri;
  final int port;
  final String title;
  final PortForwardBrowserTabGroup group;
}

class _StoreDemoAutoConfirmDialogState {
  bool open = true;
}

enum _NativeAcpLaunchPhase { resolvingAdapter, startingSession }

@immutable
class _NativeAcpLaunchState {
  const _NativeAcpLaunchState({
    required this.generation,
    required this.providerId,
    required this.providerLabel,
    required this.phase,
    required this.resuming,
    required this.startedAt,
  });

  final int generation;
  final String providerId;
  final String providerLabel;
  final _NativeAcpLaunchPhase phase;
  final bool resuming;
  final DateTime startedAt;

  _NativeAcpLaunchState copyWith({required _NativeAcpLaunchPhase phase}) =>
      _NativeAcpLaunchState(
        generation: generation,
        providerId: providerId,
        providerLabel: providerLabel,
        phase: phase,
        resuming: resuming,
        startedAt: startedAt,
      );
}

final Expando<List<AgentRuntimeInfo>> _agentUpdateRuntimes =
    Expando<List<AgentRuntimeInfo>>('agentUpdateRuntimes');

/// Sanitized diagnostic category and user message for a picked-file failure.
@visibleForTesting
({String category, String message}) pickedFileFailure(
  Object error,
  String context,
) => (
  category: switch (error) {
    PlatformException() => 'picker_failed',
    FileSystemException() => 'picked_file_failed',
    SftpError() => 'picked_remote_upload_failed',
    _ => 'picked_upload_failed',
  },
  message: error is SftpError
      ? 'Remote upload failed. Check permissions and try again.'
      : '$context failed. Try again.',
);

/// Terminal screen for SSH sessions.
class TerminalScreen extends ConsumerStatefulWidget {
  /// Creates a new [TerminalScreen].
  const TerminalScreen({
    required this.hostId,
    this.connectionId,
    this.initialTmuxSessionName,
    this.initialTmuxWindowIndex,
    this.initialTmuxWindowId,
    this.initialTmuxWindowRequiresVisibleSession = false,
    this.initiallyExpandTmuxWindows = false,
    this.initiallyShowKeyboard = false,
    this.pasteDemoImage = false,
    super.key,
  });

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  /// Optional tmux session to focus after opening the terminal.
  final String? initialTmuxSessionName;

  /// Optional tmux window to focus after opening the terminal.
  final int? initialTmuxWindowIndex;

  /// Optional stable tmux window ID to focus after opening the terminal.
  final String? initialTmuxWindowId;

  /// Whether focusing the initial tmux window must also make tmux visible.
  final bool initialTmuxWindowRequiresVisibleSession;

  /// Whether the tmux window selector should start expanded.
  final bool initiallyExpandTmuxWindows;

  /// Whether the terminal should show the system keyboard after opening.
  final bool initiallyShowKeyboard;

  /// Whether to paste the store-demo image after opening the terminal.
  final bool pasteDemoImage;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _InitialTmuxWindowTarget {
  const _InitialTmuxWindowTarget({
    required this.sessionName,
    required this.windowIndex,
    required this.requiresVisibleSession,
    this.windowId,
  });

  final String sessionName;
  final int windowIndex;
  final String? windowId;
  final bool requiresVisibleSession;
}

class _TmuxTerminalThemeRefreshRequest {
  const _TmuxTerminalThemeRefreshRequest({
    required this.theme,
    required this.session,
    required this.sessionName,
    required this.refreshGeneration,
    required this.reason,
    required this.extraFlags,
    this.sendOuterFocusReport = false,
  });

  final TerminalThemeData theme;
  final SshSession session;
  final String sessionName;
  final int refreshGeneration;
  final String reason;
  final String? extraFlags;
  final bool sendOuterFocusReport;

  _TmuxTerminalThemeRefreshRequest copyWith({
    String? reason,
    bool? sendOuterFocusReport,
  }) => _TmuxTerminalThemeRefreshRequest(
    theme: theme,
    session: session,
    sessionName: sessionName,
    refreshGeneration: refreshGeneration,
    reason: reason ?? this.reason,
    extraFlags: extraFlags,
    sendOuterFocusReport: sendOuterFocusReport ?? this.sendOuterFocusReport,
  );
}

typedef _MonkeyMuxResizeSyncKey = ({
  int connectionId,
  String sessionName,
  int columns,
  int rows,
});

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  static const _localClipboardSyncInterval = Duration(milliseconds: 750);
  static const _remoteClipboardSyncInterval = Duration(seconds: 1);
  static const _promptOutputImeResetDebounce = Duration(milliseconds: 75);
  static const _tmuxForegroundVerificationInterval = Duration(seconds: 5);
  static const _tmuxWindowThemeRefreshDebounceDelay = Duration(
    milliseconds: 150,
  );
  static const _tmuxPostWindowSwitchExecQuietPeriod = Duration(
    milliseconds: 900,
  );
  final _terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
  final _tmuxBarKey = GlobalKey<_TmuxExpandableBarState>();

  late Terminal _terminal;
  late final TerminalController _terminalController;
  late final ScrollController _terminalScrollController;
  late FocusNode _terminalFocusNode;
  final _terminalTextInputController = TerminalTextInputHandlerController();
  final _systemKeyboardVisibilityController =
      SystemKeyboardVisibilityController.instance;
  final _nativeComposerFocusController = AcpComposerFocusController();
  bool _keyboardVisibilityRebuildScheduled = false;
  int _terminalFocusRestoreGeneration = 0;
  final _toolbarController = KeyboardToolbarController();
  SSHSession? _shell;
  bool _isReopeningShell = false;
  StreamSubscription<void>? _doneSubscription;
  StreamSubscription<void>? _shellCommandCompletedSubscription;
  StreamSubscription<String>? _shellStdoutSubscription;
  Terminal? _terminalWithOwnedCallbacks;
  void Function(String)? _terminalOutputHandler;
  void Function(int, int, int, int)? _terminalResizeHandler;
  void Function(int, int)? _terminalHostResizeHandler;
  bool _suppressMonkeyMuxResizeSyncFromTerminalRefresh = false;
  bool _suppressTerminalAutoScrollFromTerminalRefresh = false;
  bool _isConnecting = true;
  bool _connectionCancelled = false;
  String? _error;
  bool _showKeyboardToolbar = !_hideStoreScreenshotKeyboardToolbar;
  bool _detectedSensitiveKeyboardPrompt = false;
  bool _isUsingAltBuffer = false;
  bool _terminalReportsMouseWheel = false;
  List<KeyboardToolbarSnippet> _keyboardToolbarSnippets =
      const <KeyboardToolbarSnippet>[];
  List<KeyboardToolbarSnippetFolder> _keyboardToolbarSnippetFolders =
      const <KeyboardToolbarSnippetFolder>[];
  bool _isNativeSelectionMode = false;
  bool _shellCompletionsEnabled = false;
  int? _connectionId;
  double? _pinchFontSize;
  double? _lastPinchScale;
  double? _sessionFontSizeOverride;
  bool _isPinchZooming = false;
  bool _shouldFollowLiveOutput = true;
  bool _didPasteDemoImage = false;
  double _lastTerminalScrollOffset = 0;
  bool _isTerminalScrollToBottomQueued = false;
  bool _isNavigatingCommandMarks = false;
  int? _previousCommandNavigationRow;
  int? _previousCommandNavigationConnectionId;
  int? _previousCommandNavigationMarkCount;
  int _terminalScrollResetGeneration = 0;
  TerminalHyperlinkTracker? _terminalHyperlinkTracker;
  late final TerminalSessionController _sessionController;
  bool _showsTerminalMetadata = false;
  bool _isTmuxActive = false;
  bool _tmuxOwnershipConfirmed = false;
  String? _tmuxSessionName;
  String? _muxVersion;
  String? _monkeyMuxReconnectSessionName;
  bool _monkeyMuxReconnectAttachPending = false;
  bool _monkeyMuxAttachEstablished = false;
  _PendingMonkeyMuxServerReplacement? _pendingMonkeyMuxServerReplacement;
  MonkeyMuxForcedReloadRequest? _forcedMonkeyMuxReloadRequest;
  Future<void>? _monkeyMuxServerReplacementRecovery;
  Timer? _monkeyMuxServerReplacementRecoveryTimer;
  Completer<bool>? _monkeyMuxServerReplacementRecoveryDelay;
  int _monkeyMuxForegroundFalseProbeCount = 0;
  int _automaticPortForwardRootSyncGeneration = 0;
  int? _tmuxStateConnectionId;
  Size? _terminalViewportLayoutSize;
  double _terminalViewportReservedWidth = 0;
  double _terminalViewportReservedBottomPadding = 0;
  bool _reserveMuxChromeBeforeActivation = false;
  _InitialTmuxWindowTarget? _pendingInitialTmuxWindowTarget;
  bool _showTmuxBar = true;
  bool _isTmuxBarExpanded = false;
  double _tmuxSidebarDragOffset = 0;
  AcpSessionKey? _activeNativeAcpSessionKey;
  String? _autoOpenedNativeAcpBridgeId;
  String? _openingNativeAcpBridgeId;
  int? _openingNativeAcpRequestGeneration;
  String? _nativeAcpReconnectOwnedKeyValue;
  Future<void>? _openingNativeAcpWindow;
  _NativeAcpLaunchState? _nativeAcpLaunchState;
  var _nativeAcpLaunchGeneration = 0;
  var _nativeAcpWindowRequestGeneration = 0;
  Completer<void>? _nativeAcpWindowCancellation;
  final Map<String, AcpChatScrollState> _nativeAcpScrollStates = {};
  String? _connectionOpenedWorkingDirectory;
  String? _tmuxLaunchWorkingDirectory;
  String? _tmuxWorkingDirectory;
  String? _tmuxCurrentCommand;
  int _muxPaneContextRefreshGeneration = 0;
  DateTime? _muxPaneContextRefreshedAt;
  DateTime? _shellCompletionTmuxContextRefreshedAt;
  int? _shellCompletionTmuxContextConnectionId;
  String? _shellCompletionTmuxContextSessionName;
  int _tmuxDetectionGeneration = 0;
  int _tmuxBarRecoveryGeneration = 0;
  int _tmuxForegroundVerificationGeneration = 0;
  Timer? _tmuxForegroundVerificationTimer;
  bool _tmuxForegroundVerificationInFlight = false;
  final Map<String, _VerifiedTerminalPath> _verifiedTerminalPathCache =
      <String, _VerifiedTerminalPath>{};
  String? _activeTerminalPathVerificationKey;
  String? _terminalPathCacheScope;
  String? _pendingTerminalTargetTap;
  int? _pendingTerminalTargetTapPointer;
  Offset? _pendingTerminalTargetTapDownPosition;
  Duration? _pendingTerminalTargetTapDownTimestamp;
  String? _recentlyOpenedTerminalTargetTap;
  final Set<_TerminalExclusiveAction> _exclusiveTerminalActions =
      <_TerminalExclusiveAction>{};
  int? _pendingTerminalDoubleTapPointer;
  Offset? _pendingTerminalDoubleTapDownPosition;
  Duration? _pendingTerminalDoubleTapDownTimestamp;
  int? _terminalDoubleTapConsumedPointer;
  Offset? _lastTerminalTapPosition;
  Duration? _lastTerminalTapTimestamp;
  int? _pendingTerminalMouseTapPointer;
  Offset? _pendingTerminalMouseTapDownPosition;
  Duration? _pendingTerminalMouseTapDownTimestamp;
  final Set<int> _terminalOutputPauseTouchPointers = <int>{};
  TerminalTextUnderline? _hoveredTerminalPathUnderline;
  List<({String path, TerminalTextUnderline underline, Rect touchRect})>
  _visibleTerminalPathUnderlines =
      const <
        ({String path, TerminalTextUnderline underline, Rect touchRect})
      >[];
  bool _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
  bool? _lastShowsTerminalPathUnderlines;
  CellOffset? _lastHoveredTerminalPathOffset;
  String? _lastHoveredTerminalPath;
  bool _isTerminalPathUnderlineRefreshQueued = false;
  Timer? _terminalPathUnderlineScrollThrottleTimer;
  int _lastTerminalPathUnderlineRefreshMs = 0;
  int _terminalPathUnderlineRefreshLogAtMs = 0;

  /// Monotonically-increasing counter; incremented whenever the terminal
  /// buffer changes content. Used to invalidate per-row snapshot caches.
  int _terminalContentGeneration = 0;
  int _terminalUserInputGeneration = 0;

  /// Cache of [_TerminalPathTapSnapshot] objects keyed by the canonical start
  /// row of each wrapped-line group. Invalidated when
  /// [_terminalContentGeneration] changes.
  final Map<int, _TerminalPathTapSnapshot?> _terminalPathSnapshotCache = {};

  /// The terminal-content generation that [_terminalPathSnapshotCache] and
  /// [_terminalPathAnalysisCache] were last populated for.
  int _terminalPathSnapshotCacheGeneration = -1;

  /// Cache of [_TerminalPathSnapshotAnalysis] keyed by snapshot text. The
  /// regex-heavy analysis is deterministic on the snapshot text, so it can be
  /// shared across rows that produce the same text content. Cleared together
  /// with [_terminalPathSnapshotCache].
  final Map<String, _TerminalPathSnapshotAnalysis> _terminalPathAnalysisCache =
      {};

  SshSession? _terminalPathVerificationSession;
  Future<SftpClient?>? _terminalPathVerificationSftpFuture;
  SftpClient? _terminalPathVerificationSftp;
  String? _terminalPathVerificationHomeDirectory;
  DateTime? _terminalPathVerificationBackoffUntil;
  final Map<String, String> _pendingTerminalPathVerifications = {};
  bool _isTerminalPathVerificationBatchScheduled = false;
  Timer? _terminalPathVerificationBatchTimer;
  late final ProviderSubscription<bool> _sharedClipboardSubscription;
  late final ProviderSubscription<bool> _sharedClipboardLocalReadSubscription;
  late final ProviderSubscription<bool> _terminalWakeLockSubscription;
  late final ProviderSubscription<TerminalThemeSettings>
  _terminalThemeSettingsSubscription;
  late final ProviderSubscription<ThemeMode> _themeModeSubscription;
  late final ProviderSubscription<bool> _shellCompletionsSubscription;
  Timer? _localClipboardSyncTimer;
  Timer? _remoteClipboardSyncTimer;
  Timer? _promptOutputImeResetTimer;
  Timer? _shellCompletionDebounceTimer;
  bool _isPollingRemoteClipboard = false;
  int _clipboardSyncGeneration = 0;
  bool _isPushingLocalClipboard = false;
  bool _remoteClipboardUnsupported = false;
  String? _lastObservedLocalClipboardText;
  String? _lastObservedRemoteClipboardText;
  String? _lastAppliedLocalClipboardText;
  String? _lastAppliedRemoteClipboardText;
  String? _recentLocalClipboardText;
  DateTime? _recentLocalClipboardAt;
  bool _isTerminalSizeRefreshQueued = false;
  bool _pendingTerminalSizeRefreshForcesDisplayRefresh = false;
  bool _pendingTerminalSizeRefreshRevealsLatestOutput = false;
  bool _pendingTerminalSizeRefreshSuppressesMonkeyMuxResizeSync = false;
  bool _pendingTerminalSizeRefreshSuppressesAutoScroll = false;
  Timer? _monkeyMuxWindowRefreshFollowUpTimer;
  Timer? _monkeyMuxResizeRedrawFollowUpTimer;
  Timer? _appResumeTerminalMetricsSettleTimer;
  bool _isSettlingTerminalMetricsAfterAppResume = false;
  Timer? _monkeyMuxResizeSyncCooldownTimer;
  int _monkeyMuxHostGridReconcileAttempts = 0;
  int _monkeyMuxBlankPaneRecoveryAttempts = 0;
  bool _monkeyMuxResizeSyncInFlight = false;
  bool _monkeyMuxResizeSyncThrottled = false;
  bool _monkeyMuxResizeSyncPending = false;
  String? _lastMonkeyMuxUpgradeDeferredNotice;
  int? _monkeyMuxResizeSyncColumns;
  int? _monkeyMuxResizeSyncRows;
  Timer? _monkeyMuxPostRedrawDisplayRefreshTimer;
  final List<Timer> _monkeyMuxSettledRedrawDisplayRefreshTimers = <Timer>[];
  int _monkeyMuxSettledRedrawDisplayRefreshGeneration = 0;
  int _monkeyMuxRefreshAndResizeGeneration = 0;
  // Latched when a terminal theme *color* change (or a forced re-sync) needs
  // the MonkeyMux foreground TUI to be forced to fully repaint. Kept as instance
  // state rather than on a single refresh request so the obligation survives
  // that request being superseded/coalesced by a later same-theme refresh; it is
  // passed to MonkeyMux as the theme_changed `redraw` flag and cleared once that
  // flag has been delivered.
  bool _monkeyMuxForcedThemeRedrawPending = false;
  // Bumped every time a redraw obligation is (re)latched. The consumer captures
  // it before awaiting the refresh and only clears the latch if it is unchanged,
  // so a newer obligation latched during the await (e.g. a coalesced theme that
  // will be sent next) is not erased and still gets its redraw.
  int _monkeyMuxForcedThemeRedrawGeneration = 0;
  Timer? _muxWindowRefreshProbeTimer;
  Timer? _muxWindowRefreshSafetyNetTimer;
  DateTime? _lastMuxWindowChangeAt;
  // Debounced demand-driven Kitty image recovery. When the terminal redraws
  // placeholder cells for images the client never received (a bounded switch or
  // reconnect replay dropped them, and the app does not re-transmit), the ids
  // are collected here and re-requested from the MonkeyMux server. Ids already
  // asked for this window visit are tracked so a genuinely-gone image is not
  // requested on every output frame; the set resets on each window change.
  Timer? _missingImageRequestTimer;
  final Set<int> _requestedMissingImageIds = <int>{};
  DateTime? _missingImageRecoveryRetryNotBefore;
  int _missingImageRecoveryRetryCount = 0;
  int _missingImageRecoveryGeneration = 0;
  bool _missingImageRecoveryInFlight = false;
  bool _missingImageRecoveryRescanPending = false;
  _MonkeyMuxResizeSyncKey? _lastMonkeyMuxResizeSync;
  final Set<_MonkeyMuxResizeSyncKey> _pendingMonkeyMuxResizeSyncs =
      <_MonkeyMuxResizeSyncKey>{};
  bool _terminalWakeLockSetting = false;
  int _shellCompletionGeneration = 0;
  String? _shellCompletionPromptPrefix;
  ({String text, int cursorOffset})? _shellCompletionOptimisticSnapshot;
  ShellCompletionInvocation? _shellCompletionSourceInvocation;
  List<ShellCompletionSuggestion> _shellCompletionSourceSuggestions =
      const <ShellCompletionSuggestion>[];
  ShellCompletionInvocation? _shellCompletionInvocation;
  List<ShellCompletionSuggestion> _shellCompletionSuggestions =
      const <ShellCompletionSuggestion>[];
  Rect? _shellCompletionAnchorGlobalRect;
  String? _shellCompletionInFlightRequestKey;
  bool _shellCompletionRefreshAfterInFlight = false;
  int _shellCompletionAnchorRetryCount = 0;

  bool _isExclusiveTerminalActionRunning(_TerminalExclusiveAction action) =>
      _exclusiveTerminalActions.contains(action);

  Future<void> _runExclusiveTerminalAction(
    _TerminalExclusiveAction action,
    Future<void> Function() run,
  ) async {
    if (_isExclusiveTerminalActionRunning(action)) {
      return;
    }

    setState(() => _exclusiveTerminalActions.add(action));
    try {
      await run();
    } finally {
      if (mounted) {
        setState(() => _exclusiveTerminalActions.remove(action));
      } else {
        _exclusiveTerminalActions.remove(action);
      }
    }
  }

  // Theme state
  Host? _host;
  AgentLaunchPreset? _autoConnectAgentPreset;
  bool _hasUnsupportedAutoConnectAgentPreset = false;
  bool _startClisInYoloMode = false;
  TerminalThemeData? _currentTheme;
  TerminalThemeData? _sessionThemeOverride;
  final Object _terminalAppThemeOverrideOwner = Object();
  late final TerminalAppThemeOverrideNotifier _terminalAppThemeOverrideNotifier;
  Brightness? _lastThemeDependencyBrightness;
  int _terminalThemeRefreshGeneration = 0;
  final Set<Timer> _terminalThemeRefreshTimers = <Timer>{};
  bool _isTmuxThemeRefreshRunning = false;
  _TmuxTerminalThemeRefreshRequest? _pendingTmuxThemeRefreshRequest;
  Timer? _tmuxWindowThemeRefreshDebounceTimer;
  _TmuxTerminalThemeRefreshRequest? _pendingTmuxWindowThemeRefreshRequest;
  bool _terminalThemeDependencyReloadQueued = false;
  bool _pendingTerminalThemeDependencyReload = false;
  bool _pendingTerminalThemeDependencyForceRemoteRefresh = false;
  String _pendingTerminalThemeDependencyReason = 'unknown';
  bool _terminalThemeRefreshRequiredAfterResume = false;
  // Guards the build-path theme application so the same theme is not pushed
  // to the session on every rebuild.  Cleared at connect-time so the safety-
  // net call in build() still fires once for each new connection.
  TerminalThemeData? _lastBuildAppliedTheme;

  // Cache the notifier for use in dispose
  ActiveSessionsNotifier? _sessionsNotifier;
  late final TmuxService _tmuxService;
  late final RemoteMultiplexerService _tmuxMultiplexerService;
  late final MonkeyMuxService _monkeyMuxService;
  late final MonkeyMuxInstallerService _monkeyMuxInstallerService;
  late final TerminalConnectionBackendService _terminalBackendService;
  late final DeviceDebugSessionRegistry _deviceDebugSessionRegistry;
  DeviceDebugSessionController? _deviceDebugController;
  int? _deviceDebugConnectionId;
  RemoteMuxBackend _activeMuxBackend = RemoteMuxBackend.tmux;
  AgentLaunchTool? _remoteMuxStartupTool;
  Timer? _agentUpdateCheckTimer;

  // Track whether the app is in the background so we can auto-reconnect
  // when it resumes if the OS killed the socket.
  bool _wasBackgrounded = false;
  bool _connectionLostWhileBackgrounded = false;
  int? _suppressNextAutomaticReconnectConnectionId;
  int? _suppressRemoteMuxDetectionConnectionId;
  bool _restoreKeyboardAfterAppResume = false;
  final GlobalKey _terminalOverflowMenuButtonKey = GlobalKey();
  double? _terminalOverflowMenuAnchorTopCache;
  bool _terminalOverflowMenuAnchorTopUpdateScheduled = false;
  final Map<String, String> _lastAndroidPredictiveBackDiagnosticsKeys =
      <String, String>{};
  String? _lastAndroidTerminalContentDiagnosticsKey;
  bool _androidPredictiveBackPostFrameDiagnosticsQueued = false;

  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isAndroidPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _queueAndroidPredictiveBackPostFrameDiagnostics(BuildContext context) {
    if (!_isAndroidPlatform ||
        !DiagnosticsLogService.instance.enabled ||
        _androidPredictiveBackPostFrameDiagnosticsQueued) {
      return;
    }
    _androidPredictiveBackPostFrameDiagnosticsQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _androidPredictiveBackPostFrameDiagnosticsQueued = false;
      if (!mounted || !context.mounted) {
        return;
      }
      _logAndroidPredictiveBackDiagnostics(
        context,
        phase: 'post_frame',
        includeGestureEnabled: true,
      );
    });
  }

  void _logAndroidPredictiveBackDiagnostics(
    BuildContext context, {
    required String phase,
    bool? didPop,
    bool includeGestureEnabled = false,
  }) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!_isAndroidPlatform || !diagnostics.enabled) {
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    final animation = route?.animation;
    final animationValue = animation?.value;
    final fields = <String, Object?>{
      'phase': phase,
      'routePopGestureInProgress': route?.popGestureInProgress,
      if (includeGestureEnabled)
        'routePopGestureEnabled': route?.popGestureEnabled,
      'routeIsCurrent': route?.isCurrent,
      'routeCanPop': route?.canPop,
      'routePopDisposition': route?.popDisposition,
      'navigatorUserGestureInProgress': navigator?.userGestureInProgress,
      'navigatorCanPop': navigator?.canPop(),
      'animationStatus': animation?.status,
      if (animationValue case final animationValue?)
        'animationPermille': (animationValue * 1000).round(),
      if (animationValue case final animationValue?)
        'animationBucket': (animationValue * 20).round(),
      'tmuxBarExpanded': _isTmuxBarExpanded,
      'keyboardVisible': MediaQuery.viewInsetsOf(context).bottom > 0,
      'terminalViewMounted': _terminalViewKey.currentState != null,
    };
    if (didPop != null) {
      fields['didPop'] = didPop;
    }
    final key = fields.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join('|');
    if (key == _lastAndroidPredictiveBackDiagnosticsKeys[phase]) {
      return;
    }
    _lastAndroidPredictiveBackDiagnosticsKeys[phase] = key;
    diagnostics.debug('android.back', 'terminal_route_state', fields: fields);
  }

  void _logAndroidTerminalContentDiagnostics(
    BuildContext context, {
    required String branch,
    required SshConnectionState connectionState,
    required bool showsDisconnectedOverlay,
    required bool hasOverlayMessage,
    required bool isMobile,
  }) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!_isAndroidPlatform || !diagnostics.enabled) {
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    final animation = route?.animation;
    final animationValue = animation?.value;
    final fields = <String, Object?>{
      'branch': branch,
      'isConnecting': _isConnecting,
      'hasConnectionId': _connectionId != null,
      'connectionState': connectionState,
      'hasOverlayMessage': hasOverlayMessage,
      'showsDisconnectedOverlay': showsDisconnectedOverlay,
      'hasShell': _shell != null,
      'isTmuxActive': _isTmuxActive,
      'isMobile': isMobile,
      'routePopGestureInProgress': route?.popGestureInProgress,
      'routeIsCurrent': route?.isCurrent,
      'navigatorUserGestureInProgress': navigator?.userGestureInProgress,
      'animationStatus': animation?.status,
      if (animationValue case final animationValue?)
        'animationBucket': (animationValue * 20).round(),
      'terminalViewMounted': _terminalViewKey.currentState != null,
    };
    final key = fields.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join('|');
    if (key == _lastAndroidTerminalContentDiagnosticsKey) {
      return;
    }
    _lastAndroidTerminalContentDiagnosticsKey = key;
    diagnostics.debug('android.back', 'terminal_content_state', fields: fields);
  }

  bool get _hasActiveSystemSelection {
    final selection = _terminalController.selection;
    return selection != null && !selection.isCollapsed;
  }

  bool get _isTerminalOutputFollowPaused =>
      _terminalOutputPauseTouchPointers.isNotEmpty ||
      (_isNativeSelectionMode && _readSystemSelectionPlainText() != null) ||
      _hasActiveSystemSelection;

  bool get _terminalLiveOutputAutoScrollEnabled =>
      _shouldFollowLiveOutput && !_isTerminalOutputFollowPaused;

  Iterable<TmuxWindow>? get _currentTmuxWindowsSnapshot =>
      _tmuxBarKey.currentState?.currentWindowsSnapshot;

  bool? get _activeWindowReportsMouseWheel =>
      resolveTmuxBarActiveWindowReportsMouseWheel(_currentTmuxWindowsSnapshot);

  bool? get _activeWindowMouseReportSgr =>
      resolveTmuxBarActiveWindowMouseReportSgr(_currentTmuxWindowsSnapshot);

  bool get _terminalReportsMouseWheelForScroll =>
      terminalReportsMouseWheelForScroll(
        localTerminalReportsMouseWheel: _terminalReportsMouseWheel,
        activeWindowReportsMouseWheel: _activeWindowReportsMouseWheel,
      );

  bool get _routesTouchScrollToTerminal => shouldRouteTouchScrollToTerminal(
    isMobile: _isMobilePlatform,
    isUsingAltBuffer: _isUsingAltBuffer,
    terminalReportsMouseWheel: _terminalReportsMouseWheelForScroll,
    isAgentToolActive: _isAgentToolActive,
  );

  bool get _isAgentToolActive {
    final windows = _currentTmuxWindowsSnapshot;
    return isAgentToolActiveForTerminalScroll(
      activeWindowTool: resolveTmuxBarActiveWindowTool(windows),
      startupTool: _remoteMuxStartupTool,
      hasWindowSnapshot: windows != null,
      currentCommand: _tmuxCurrentCommand,
    );
  }

  bool get _forceSgrTouchScroll => shouldForceSgrTouchScroll(
    activeWindowReportsMouseWheel: _activeWindowReportsMouseWheel,
    activeWindowMouseReportSgr: _activeWindowMouseReportSgr,
  );

  MenuStyle _terminalOverflowMenuStyle({
    required BuildContext context,
    required bool isMobilePlatform,
  }) {
    final mediaQuery = MediaQuery.of(context);
    // Reading paint geometry (localToGlobal) during build throws while an
    // ancestor route transform has not been laid out yet, which happens during
    // the Android predictive-back transition. Use the value cached after the
    // previous frame's layout instead, and refresh it from a post-frame
    // callback when it is actually needed (mobile + keyboard visible).
    if (isMobilePlatform && mediaQuery.viewInsets.bottom > 0) {
      _scheduleTerminalOverflowMenuAnchorTopUpdate(context);
    }
    final anchorTop = _terminalOverflowMenuAnchorTopCache;
    final maxHeight = resolveTerminalOverflowMenuMaxHeight(
      mediaQuery: mediaQuery,
      isMobilePlatform: isMobilePlatform,
      anchorTop: anchorTop,
    );
    return TerminalMenuStyles.menuStyle(
      context,
      minimumSize: const Size(_terminalOverflowMenuMinWidth, 0),
      maximumSize: Size(
        _terminalOverflowMenuMaxWidth,
        maxHeight ?? double.infinity,
      ),
    );
  }

  EdgeInsetsGeometry _terminalOverflowMenuReservedPadding({
    required BuildContext context,
    required bool isMobilePlatform,
  }) {
    final mediaQuery = MediaQuery.of(context);
    return EdgeInsets.only(
      left: _terminalOverflowMenuScreenPadding,
      top: _terminalOverflowMenuScreenPadding,
      right: _terminalOverflowMenuScreenPadding,
      bottom:
          _terminalOverflowMenuScreenPadding +
          (isMobilePlatform ? mediaQuery.viewInsets.bottom : 0),
    );
  }

  void _scheduleTerminalOverflowMenuAnchorTopUpdate(BuildContext context) {
    if (_terminalOverflowMenuAnchorTopUpdateScheduled) {
      return;
    }
    _terminalOverflowMenuAnchorTopUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalOverflowMenuAnchorTopUpdateScheduled = false;
      if (!mounted) {
        return;
      }
      final next = _terminalOverflowMenuAnchorTop(context);
      if (next != _terminalOverflowMenuAnchorTopCache) {
        setState(() => _terminalOverflowMenuAnchorTopCache = next);
      }
    });
  }

  double? _terminalOverflowMenuAnchorTop(BuildContext context) {
    final anchorContext = _terminalOverflowMenuButtonKey.currentContext;
    if (anchorContext == null) {
      return null;
    }
    final anchorRenderObject = anchorContext.findRenderObject();
    final overlayRenderObject = Navigator.of(
      context,
    ).overlay?.context.findRenderObject();
    if (anchorRenderObject is! RenderBox ||
        overlayRenderObject is! RenderBox ||
        !anchorRenderObject.attached ||
        !overlayRenderObject.attached ||
        !anchorRenderObject.hasSize ||
        !overlayRenderObject.hasSize) {
      return null;
    }

    return anchorRenderObject
        .localToGlobal(Offset.zero, ancestor: overlayRenderObject)
        .dy;
  }

  Widget _terminalOverflowMenuLabel(String label) => Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
  );

  Widget _terminalOverflowMenuItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String action,
    bool enabled = true,
    bool showStatusDot = false,
    bool showProBadge = false,
  }) => MenuItemButton(
    style: TerminalMenuStyles.itemButtonStyle(context),
    leadingIcon: Semantics(
      label: showStatusDot ? 'Agent updates available' : null,
      child: Badge(
        key: ValueKey('$action-updates-dot'),
        isLabelVisible: showStatusDot,
        backgroundColor: Theme.of(context).colorScheme.primary,
        smallSize: 8,
        child: Icon(icon, size: TerminalMenuStyles.iconSize),
      ),
    ),
    trailingIcon: showProBadge ? const PremiumBadge() : null,
    onPressed: enabled ? () => unawaited(_handleMenuAction(action)) : null,
    child: _terminalOverflowMenuLabel(label),
  );

  Widget _terminalOverflowSwitchMenuItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required bool value,
    required bool loading,
    required String action,
    bool enabled = true,
  }) => Semantics(
    toggled: value,
    child: MenuItemButton(
      style: TerminalMenuStyles.itemButtonStyle(context),
      leadingIcon: Icon(icon, size: TerminalMenuStyles.iconSize),
      trailingIcon: loading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          // The switch is a visual affordance only; the menu item owns both the
          // activation and the toggled state exposed to assistive technology.
          : ExcludeSemantics(
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 0.78,
                  child: Switch(
                    value: value,
                    onChanged: enabled ? (_) {} : null,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
      onPressed: enabled && !loading
          ? () => unawaited(_handleMenuAction(action))
          : null,
      child: _terminalOverflowMenuLabel(label),
    ),
  );

  DeviceDebugSessionController? _deviceDebugControllerFor(SshSession? session) {
    if (session == null) {
      _deviceDebugController?.removeListener(_handleDeviceDebugStateChanged);
      _deviceDebugController = null;
      _deviceDebugConnectionId = null;
      return null;
    }
    if (_deviceDebugConnectionId == session.connectionId &&
        _deviceDebugController != null) {
      return _deviceDebugController;
    }
    _deviceDebugController?.removeListener(_handleDeviceDebugStateChanged);
    final controller = _deviceDebugSessionRegistry.controllerFor(session)
      ..addListener(_handleDeviceDebugStateChanged);
    _deviceDebugController = controller;
    _deviceDebugConnectionId = session.connectionId;
    return controller;
  }

  void _handleDeviceDebugStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleDeviceDebug() async {
    final session = _activeSession();
    final controller = _deviceDebugControllerFor(session);
    if (controller == null) {
      return;
    }
    if (controller.state.isActive) {
      await controller.stop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device debugging turned off')),
        );
      }
      return;
    }
    await showDeviceDebugSheet(context: context, controller: controller);
  }

  Widget _terminalOverflowCheckboxMenuItem({
    required BuildContext context,
    required String label,
    required bool checked,
    required String action,
  }) => CheckboxMenuButton(
    style: TerminalMenuStyles.itemButtonStyle(context),
    value: checked,
    onChanged: (_) => unawaited(_handleMenuAction(action)),
    child: _terminalOverflowMenuLabel(label),
  );

  Widget _terminalOverflowSubmenuButton({
    required BuildContext context,
    required bool isMobile,
    required IconData icon,
    required String label,
    required List<Widget> menuChildren,
  }) => SubmenuButton(
    style: TerminalMenuStyles.itemButtonStyle(context),
    leadingIcon: Icon(icon, size: TerminalMenuStyles.iconSize),
    menuStyle: _terminalOverflowMenuStyle(
      context: context,
      isMobilePlatform: isMobile,
    ),
    menuChildren: menuChildren,
    child: _terminalOverflowMenuLabel(label),
  );

  Widget _terminalOverflowMenuDivider(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    color: Theme.of(context).colorScheme.outlineVariant,
  );

  List<Widget> _terminalPastingMenuItems(BuildContext context) => [
    _terminalOverflowMenuItem(
      context: context,
      icon: Icons.paste_rounded,
      label: 'Paste',
      action: 'paste',
    ),
    _terminalOverflowMenuItem(
      context: context,
      icon: Icons.perm_media_outlined,
      label: 'Paste Media',
      action: 'paste_media',
    ),
    _terminalOverflowMenuItem(
      context: context,
      icon: Icons.attach_file_rounded,
      label: 'Paste Files',
      action: 'paste_file',
    ),
  ];

  List<Widget> _terminalOptionsMenuItems({
    required BuildContext context,
    required bool hasTerminalInfo,
    required bool isMobile,
    required bool nativeAgentActive,
  }) => [
    if (!nativeAgentActive && hasTerminalInfo)
      _terminalOverflowMenuItem(
        context: context,
        icon: _showsTerminalMetadata
            ? Icons.info_outlined
            : Icons.info_outline_rounded,
        label: _showsTerminalMetadata
            ? 'Hide Terminal Info'
            : 'Show Terminal Info',
        action: 'toggle_terminal_info',
      ),
    if (_isTmuxActive)
      _terminalOverflowMenuItem(
        context: context,
        icon: _showTmuxBar ? Icons.window_outlined : Icons.window_rounded,
        label: _showTmuxBar ? 'Hide tmux Bar' : 'Show tmux Bar',
        action: 'toggle_tmux_bar',
      ),
    if (_isTmuxActive && _activeMuxBackend == RemoteMuxBackend.monkeyMux)
      const AgentUsageRingsMenuItem(),
    if (!nativeAgentActive && isMobile)
      _terminalOverflowCheckboxMenuItem(
        context: context,
        label: 'Tap to Show Keyboard',
        checked: ref.read(tapToShowKeyboardNotifierProvider),
        action: 'toggle_tap_keyboard',
      ),
    if (!nativeAgentActive)
      _terminalOverflowCheckboxMenuItem(
        context: context,
        label: 'Shell Completion Popups',
        checked: ref.read(shellCompletionsNotifierProvider),
        action: 'toggle_shell_completions',
      ),
  ];

  String? get _windowTitle => _observedSession?.windowTitle;

  SshSession? get _observedSession => _sessionController.observedSession;

  String? get _iconName => _observedSession?.iconName;

  Uri? get _workingDirectory => _observedSession?.workingDirectory;

  String? get _liveWorkingDirectoryPath =>
      resolveTerminalWorkingDirectoryPath(_workingDirectory);

  String? get _workingDirectoryLabel =>
      formatTerminalWorkingDirectoryLabel(_workingDirectory);

  String? get _workingDirectoryPath =>
      _liveWorkingDirectoryPath ?? _tmuxWorkingDirectory;

  String get _clipboardUploadDirectoryDisplay =>
      remoteClipboardUploadDirectoryDisplayFor(
        windows: _activeSession()?.remoteIsWindows ?? false,
      );

  TerminalShellStatus? get _shellStatus => _observedSession?.shellStatus;

  int? get _lastExitCode => _observedSession?.lastExitCode;

  TerminalProgress? get _terminalProgress => _observedSession?.terminalProgress;

  bool get _shouldReviewTerminalCommandInsertion =>
      shouldReviewTerminalCommandInsertion(
        shellStatus: _shellStatus,
        isUsingAltBuffer: _isUsingAltBuffer,
      );

  String _terminalCommandAfterInsertion(String insertedText) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return insertedText;
    }
    return applyTerminalCursorInsertion(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      insertedText: insertedText,
    );
  }

  String _terminalCommandAfterInputDelta(
    ({int deletedCount, String appendedText}) delta,
    String fallbackText,
  ) {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return fallbackText;
    }

    return applyTerminalInputDelta(
      currentText: snapshot.text,
      cursorOffset: snapshot.cursorOffset,
      deletedCount: delta.deletedCount,
      appendedText: delta.appendedText,
    );
  }

  bool _sameTerminalCommandReview(
    TerminalCommandReview previous,
    TerminalCommandReview next,
  ) =>
      previous.command == next.command &&
      previous.bracketedPasteModeEnabled == next.bracketedPasteModeEnabled &&
      listEquals(previous.reasons, next.reasons);

  Future<bool> _confirmTerminalInsertionIfNeeded({
    required String insertedText,
    required TerminalCommandReview Function(String commandText) buildReview,
    required String title,
    required String Function(TerminalCommandReview review) messageBuilder,
    required String confirmLabel,
    VoidCallback? onReviewShown,
  }) async {
    while (mounted) {
      final review = buildReview(_terminalCommandAfterInsertion(insertedText));
      if (!review.requiresReview) {
        return true;
      }

      onReviewShown?.call();
      final shouldInsert = await _confirmCommandInsertion(
        title: title,
        message: messageBuilder(review),
        confirmLabel: confirmLabel,
        review: review,
      );
      if (!mounted || !shouldInsert) {
        return false;
      }

      final latestReview = buildReview(
        _terminalCommandAfterInsertion(insertedText),
      );
      if (_sameTerminalCommandReview(review, latestReview)) {
        return true;
      }
    }

    return false;
  }

  @override
  void initState() {
    super.initState();
    DiagnosticsLogService.instance.info(
      'terminal.screen',
      'init',
      fields: {
        'hostId': widget.hostId,
        'hasConnectionId': widget.connectionId != null,
        'hasInitialTmuxSession': widget.initialTmuxSessionName != null,
        'hasInitialTmuxWindow': widget.initialTmuxWindowIndex != null,
      },
    );
    _tmuxService = ref.read(tmuxServiceProvider);
    _tmuxMultiplexerService = _tmuxService;
    _monkeyMuxService = ref.read(monkeyMuxServiceProvider);
    _monkeyMuxInstallerService = ref.read(monkeyMuxInstallerServiceProvider);
    _terminalBackendService = ref.read(
      terminalConnectionBackendServiceProvider,
    );
    _deviceDebugSessionRegistry = ref.read(deviceDebugSessionServiceProvider);
    _isTmuxBarExpanded = widget.initiallyExpandTmuxWindows;
    _pendingInitialTmuxWindowTarget = _buildInitialTmuxWindowTarget(widget);
    WidgetsBinding.instance.addObserver(this);
    _sharedClipboardSubscription = ref.listenManual<bool>(
      sharedClipboardNotifierProvider,
      (previous, next) => unawaited(
        _applySharedClipboardSetting(
          enabled: next,
          allowLocalClipboardRead:
              next && ref.read(sharedClipboardLocalReadNotifierProvider),
        ),
      ),
    );
    _sharedClipboardLocalReadSubscription = ref.listenManual<bool>(
      sharedClipboardLocalReadNotifierProvider,
      (previous, next) => unawaited(
        _applySharedClipboardSetting(
          enabled: ref.read(sharedClipboardNotifierProvider),
          allowLocalClipboardRead: next,
        ),
      ),
    );
    _shellCompletionsSubscription = ref.listenManual<bool>(
      shellCompletionsNotifierProvider,
      (previous, next) {
        _shellCompletionsEnabled = next;
        if (!next) {
          _hideShellCompletionPopup();
        }
      },
    );
    _shellCompletionsEnabled = ref.read(shellCompletionsNotifierProvider);
    _terminalAppThemeOverrideNotifier = ref.read(
      terminalAppThemeOverrideProvider.notifier,
    );
    final terminalWakeLockService = ref.read(terminalWakeLockServiceProvider);
    _sessionController = TerminalSessionController(
      wakeLockService: terminalWakeLockService,
      wakeLockOwnerId: terminalWakeLockService.createOwner(),
      readCurrentConnectionState: _readCurrentConnectionState,
      getSession: (connectionId) => _sessionsNotifier?.getSession(connectionId),
      connectionId: () => _connectionId,
      hasActiveShell: () => _shell != null,
      hasError: () => _error != null,
      isBackgrounded: () => _wasBackgrounded,
      onSessionMetadataChanged: _handleSessionMetadataChanged,
    );
    _terminalWakeLockSetting = ref.read(terminalWakeLockNotifierProvider);
    _sessionController.wakeLockEnabled = _terminalWakeLockSetting;
    _terminalWakeLockSubscription = ref.listenManual<bool>(
      terminalWakeLockNotifierProvider,
      (previous, next) {
        _terminalWakeLockSetting = next;
        _sessionController.wakeLockEnabled = next;
        _syncTerminalWakeLock();
      },
    );
    _terminalThemeSettingsSubscription = ref
        .listenManual<TerminalThemeSettings>(terminalThemeSettingsProvider, (
          previous,
          next,
        ) {
          if (_sameTerminalThemeSettings(previous, next)) {
            return;
          }
          _handleTerminalThemeDependenciesChanged(
            forceRemoteRefresh: true,
            reason: 'settings_changed',
          );
        });
    _themeModeSubscription = ref.listenManual<ThemeMode>(
      themeModeNotifierProvider,
      (previous, next) {
        if (previous == next) {
          return;
        }
        _handleTerminalThemeDependenciesChanged(
          forceRemoteRefresh: true,
          reason: 'theme_mode_changed',
        );
      },
    );
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminalScrollController = ScrollController()
      ..addListener(_handleTerminalScroll);
    _isUsingAltBuffer = _terminal.isUsingAltBuffer;
    _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    _terminal.addListener(_onTerminalStateChanged);
    _terminalController.addListener(_onSelectionChanged);
    _terminalFocusNode = FocusNode();
    _terminalTextInputController.addListener(
      _handleTerminalKeyboardVisibilityChanged,
    );
    _systemKeyboardVisibilityController.addListener(
      _handleTerminalKeyboardVisibilityChanged,
    );
    unawaited(_systemKeyboardVisibilityController.initialize());
    unawaited(_refreshKeyboardToolbarSnippetMenu());
    // Defer connection to avoid modifying provider state during widget build
    Future.microtask(_loadHostAndConnect);
  }

  _InitialTmuxWindowTarget? _buildInitialTmuxWindowTarget(
    TerminalScreen widget,
  ) {
    final sessionName = widget.initialTmuxSessionName?.trim();
    final windowIndex = widget.initialTmuxWindowIndex;
    final windowId = widget.initialTmuxWindowId?.trim();
    if (sessionName == null ||
        sessionName.isEmpty ||
        windowIndex == null ||
        windowIndex < 0) {
      return null;
    }
    return _InitialTmuxWindowTarget(
      sessionName: sessionName,
      windowIndex: windowIndex,
      windowId: windowId != null && isValidTmuxWindowId(windowId)
          ? windowId
          : null,
      requiresVisibleSession: widget.initialTmuxWindowRequiresVisibleSession,
    );
  }

  void _onTerminalStateChanged() {
    if (!mounted) {
      return;
    }
    _terminalContentGeneration++;
    _syncShellCompletionOptimisticSnapshotWithTerminal();

    _queueVisibleTerminalPathUnderlineRefresh();
    _scheduleMissingImageRecoveryRequest();
    if (_shellCompletionsEnabled &&
        _shellCompletionPromptPrefix != null &&
        _shellCompletionDebounceTimer == null &&
        _shellCompletionSuggestions.isEmpty) {
      _queueShellCompletionRefresh();
    }

    if (_shouldFollowLiveOutput &&
        !_isTerminalOutputFollowPaused &&
        !_suppressTerminalAutoScrollFromTerminalRefresh) {
      _queueTerminalScrollToBottom();
    }

    final isUsingAltBuffer = _terminal.isUsingAltBuffer;
    final terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
    final scrollPolicyChanged = didTerminalScrollPolicyChange(
      previousIsUsingAltBuffer: _isUsingAltBuffer,
      nextIsUsingAltBuffer: isUsingAltBuffer,
      previousReportsMouseWheel: _terminalReportsMouseWheel,
      nextReportsMouseWheel: terminalReportsMouseWheel,
    );
    final detectedSensitiveKeyboardPrompt =
        _isMobilePlatform &&
        terminalTextLooksLikeSensitiveInputPrompt(
          terminalSensitivePromptTextBeforeCursor(_terminal),
        );
    final sensitiveKeyboardPromptChanged =
        detectedSensitiveKeyboardPrompt != _detectedSensitiveKeyboardPrompt;
    if (!scrollPolicyChanged && !sensitiveKeyboardPromptChanged) {
      return;
    }

    setState(() {
      if (scrollPolicyChanged) {
        _isUsingAltBuffer = isUsingAltBuffer;
        _terminalReportsMouseWheel = terminalReportsMouseWheel;
      }
      if (sensitiveKeyboardPromptChanged) {
        _detectedSensitiveKeyboardPrompt = detectedSensitiveKeyboardPrompt;
      }
    });
  }

  void _observeSessionMetadata(SshSession session) {
    if (_sessionController.isObservingSession(session)) {
      _captureConnectionOpenedWorkingDirectory();
      return;
    }

    if (!identical(_terminalPathVerificationSession, session)) {
      _disposeTerminalPathVerificationSftp();
    }
    _sessionController.observeSessionMetadata(session);
    _captureConnectionOpenedWorkingDirectory();
  }

  void _handleSessionMetadataChanged() {
    if (!mounted) {
      return;
    }
    _captureConnectionOpenedWorkingDirectory();
    _syncVerifiedTerminalPathCacheScope();
    setState(() {});
  }

  void _captureConnectionOpenedWorkingDirectory() {
    if (_connectionOpenedWorkingDirectory != null) {
      return;
    }

    _connectionOpenedWorkingDirectory = normalizeSftpAbsolutePath(
      _liveWorkingDirectoryPath ?? _tmuxLaunchWorkingDirectory,
    );
  }

  Future<void> _applySharedClipboardSetting({
    required bool enabled,
    required bool allowLocalClipboardRead,
    SshSession? session,
    bool waitForInitialSync = true,
  }) async {
    await _sessionController.applySharedClipboardSetting(
      enabled: enabled,
      allowLocalClipboardRead: allowLocalClipboardRead,
      startSync: _startSharedClipboardSync,
      stopSync: _stopSharedClipboardSync,
      session: session,
      waitForInitialSync: waitForInitialSync,
    );
  }

  void _applyTerminalThemeToSession(
    TerminalThemeData theme, {
    SshSession? session,
    bool forceRemoteRefresh = false,
    String reason = 'unspecified',
  }) {
    final targetSession = _sessionController.resolveTargetSession(
      session: session,
    );
    if (targetSession == null) {
      if (reason != 'build') {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'apply_no_session',
          fields: {
            'reason': reason,
            'connectionId': _connectionId,
            'allowRemoteRefresh': true,
            'forceRemoteRefresh': forceRemoteRefresh,
          },
        );
      }
      return;
    }
    final previousTheme = targetSession.terminalTheme;
    targetSession.setTerminalTheme(theme);
    if (targetSession.terminal != _terminal) {
      if (reason != 'build') {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'apply_foreign_terminal',
          fields: {
            'reason': reason,
            'connectionId': targetSession.connectionId,
            'allowRemoteRefresh': true,
            'forceRemoteRefresh': forceRemoteRefresh,
            'hasSessionTerminal': targetSession.terminal != null,
          },
        );
      }
      return;
    }
    final didThemeChange =
        previousTheme != null &&
        !_terminalThemesMatchForRemoteRefresh(previousTheme, theme);
    final plainTuiRefreshAllowed = _shouldRefreshPlainTerminalTui(
      targetSession,
    );
    final terminalViewReady = _isTerminalThemeRefreshViewReady;
    final shouldRefreshFirstTheme =
        previousTheme == null && (_isTmuxActive || plainTuiRefreshAllowed);
    final willRefresh =
        forceRemoteRefresh || didThemeChange || shouldRefreshFirstTheme;
    if (willRefresh || reason != 'build') {
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'apply_decision',
        fields: {
          'reason': reason,
          'connectionId': targetSession.connectionId,
          'allowRemoteRefresh': true,
          'forceRemoteRefresh': forceRemoteRefresh,
          'hasPreviousTheme': previousTheme != null,
          'didThemeChange': didThemeChange,
          'shouldRefreshFirstTheme': shouldRefreshFirstTheme,
          'willRefresh': willRefresh,
          'isTmuxActive': _isTmuxActive,
          'plainTuiRefreshAllowed': plainTuiRefreshAllowed,
          'colorSchemeUpdatesMode':
              targetSession.terminalColorSchemeUpdatesMode,
          'focusMode': _terminal.reportFocusMode,
          'altBuffer': _terminal.isUsingAltBuffer,
          'mouseMode': _terminal.mouseMode != MouseMode.none,
          'shellReady': _shell != null,
          'terminalViewReady': terminalViewReady,
        },
      );
    }
    if (willRefresh) {
      _refreshTerminalThemeForTui(
        theme,
        targetSession,
        reason: reason,
        // Force a foreground repaint when the colors actually changed, and also
        // on a forced re-sync (resume/reconnect/brightness), which is when a
        // theme change that happened while backgrounded or disconnected would
        // otherwise leave the agent painted in the previous theme.
        forceForegroundRedraw: didThemeChange || forceRemoteRefresh,
      );
      return;
    }
  }

  void _refreshTerminalThemeForTui(
    TerminalThemeData theme,
    SshSession session, {
    required String reason,
    bool forceForegroundRedraw = false,
    int viewReadyAttempt = 0,
  }) {
    _cancelTerminalThemeRefreshTimers();
    final refreshGeneration = ++_terminalThemeRefreshGeneration;
    final refreshStartedAt = DateTime.now();
    final plainTuiRefreshAllowed = _shouldRefreshPlainTerminalTui(session);
    final terminalViewReady = _isTerminalThemeRefreshViewReady;
    final tmuxStateBelongsToSession =
        _tmuxStateConnectionId == session.connectionId;
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'refresh_requested',
      fields: {
        'reason': reason,
        'connectionId': session.connectionId,
        'isTmuxActive': _isTmuxActive,
        'tmuxStateBelongsToSession': tmuxStateBelongsToSession,
        'plainTuiRefreshAllowed': plainTuiRefreshAllowed,
        'colorSchemeUpdatesMode': session.terminalColorSchemeUpdatesMode,
        'focusMode': _terminal.reportFocusMode,
        'altBuffer': _terminal.isUsingAltBuffer,
        'mouseMode': _terminal.mouseMode != MouseMode.none,
        'shellReady': _shell != null,
        'terminalViewReady': terminalViewReady,
      },
    );
    final nativeAgentActive =
        _activeNativeAcpSessionKey != null || _nativeAcpLaunchState != null;
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!terminalViewReady &&
        shouldRetryTerminalThemeWhenViewMounts(
          nativeAgentActive: nativeAgentActive,
          routeIsCurrent: routeIsCurrent,
          attempt: viewReadyAttempt,
        )) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrentTerminalThemeRefresh(
          theme: theme,
          session: session,
          refreshGeneration: refreshGeneration,
        )) {
          return;
        }
        _refreshTerminalThemeForTui(
          theme,
          session,
          reason: reason.endsWith('_view_ready')
              ? reason
              : '${reason}_view_ready',
          forceForegroundRedraw: forceForegroundRedraw,
          viewReadyAttempt: viewReadyAttempt + 1,
        );
      });
    }
    if (_isTmuxActive && tmuxStateBelongsToSession) {
      if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
        if (forceForegroundRedraw) {
          // Latch the repaint obligation so it survives this refresh request
          // being superseded/coalesced by a later same-theme refresh (brightness
          // changes fire several applies in quick succession, and preview ->
          // "Use Theme" re-applies the same colors). It is passed to MonkeyMux
          // as the theme_changed `redraw` flag and cleared once delivered.
          _monkeyMuxForcedThemeRedrawPending = true;
          _monkeyMuxForcedThemeRedrawGeneration += 1;
        }
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'monkeymux_refresh_requested',
          fields: {
            'reason': reason,
            'connectionId': session.connectionId,
            'plainTuiRefreshAllowed': plainTuiRefreshAllowed,
          },
        );
        _queueTmuxTerminalThemeRefresh(
          _TmuxTerminalThemeRefreshRequest(
            theme: theme,
            session: session,
            sessionName: _tmuxSessionName!,
            refreshGeneration: refreshGeneration,
            reason: reason,
            extraFlags: _activeTmuxExtraFlags,
          ),
        );
        return;
      }
      _refreshTmuxClientAfterTerminalThemeChange(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        reason: reason,
      );
      return;
    }

    if (!plainTuiRefreshAllowed) {
      // A bare shell prompt treats terminal reports as typed input. Only send
      // synthetic reports after a foreground app has enabled terminal-control
      // modes that identify it as a TUI.
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'plain_refresh_skipped',
        fields: {
          'reason': reason,
          'connectionId': session.connectionId,
          'colorSchemeUpdatesMode': session.terminalColorSchemeUpdatesMode,
          'focusMode': _terminal.reportFocusMode,
          'altBuffer': _terminal.isUsingAltBuffer,
          'mouseMode': _terminal.mouseMode != MouseMode.none,
          'shellReady': _shell != null,
          'terminalViewReady': _isTerminalThemeRefreshViewReady,
        },
      );
      return;
    }

    // Do not send unsolicited OSC palette replies directly to a plain
    // foreground TUI. Codex treats those bytes as user input, and its crossterm
    // color re-query can also be disrupted by unrelated terminal reports.
    // Always send a synthetic focus transition so focus-aware TUIs re-query OSC
    // 10/11 through the normal path. Apps that requested DEC 2031 updates can
    // receive default-color reports directly. Under Windows ConPTY, wait until
    // the foreground TUI responds by querying its palette. ConPTY enables focus
    // reporting for a bare command prompt too, where unsolicited color reports
    // are echoed as typed input.
    final includeThemeModeReport = session.terminalColorSchemeUpdatesMode;
    final includeDefaultColorReports =
        includeThemeModeReport || session.terminalWin32InputMode;
    _refreshTerminalThemeReportsForTui(
      theme,
      includeThemeModeReport: false,
      reason: '${reason}_plain_focus',
    );
    if (includeThemeModeReport) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        delay: const Duration(milliseconds: 250),
        includeFocusReport: false,
        reason: '${reason}_plain_theme_mode',
      );
    }
    if (includeDefaultColorReports) {
      for (final delay in const [
        Duration(milliseconds: 330),
        Duration(milliseconds: 410),
        Duration(milliseconds: 490),
      ]) {
        _scheduleTerminalThemeRefreshForTui(
          theme: theme,
          session: session,
          refreshGeneration: refreshGeneration,
          delay: delay,
          includeFocusReport: false,
          includeThemeModeReport: false,
          includeDefaultColorReports: true,
          requirePaletteQuerySince: includeThemeModeReport
              ? null
              : refreshStartedAt,
          reason: '${reason}_plain_defaults',
        );
      }
    }
    _scheduleTerminalThemeRefreshForTui(
      theme: theme,
      session: session,
      refreshGeneration: refreshGeneration,
      delay: const Duration(milliseconds: 550),
      includeThemeModeReport: false,
      reason: '${reason}_plain_focus_late',
    );
    if (includeThemeModeReport) {
      _scheduleTerminalThemeRefreshForTui(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
        delay: const Duration(milliseconds: 800),
        includeFocusReport: false,
        reason: '${reason}_plain_theme_mode_late',
      );
    }
  }

  void _refreshTerminalThemeReportsForTui(
    TerminalThemeData theme, {
    bool includeThemeModeReport = true,
    bool includeDefaultColorReports = false,
    bool includeFocusReport = true,
    String reason = 'unspecified',
  }) {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null || !_isTerminalThemeRefreshViewReady) {
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'reports_unavailable',
        fields: {
          'reason': reason,
          'includeThemeModeReport': includeThemeModeReport,
          'includeDefaultColorReports': includeDefaultColorReports,
          'includeFocusReport': includeFocusReport,
          'shellReady': _shell != null,
          'hasOutputCallback': _terminal.onOutput != null,
        },
      );
      return;
    }
    DiagnosticsLogService.instance.debug(
      'terminal.theme',
      'reports_sent',
      fields: {
        'reason': reason,
        'includeThemeModeReport': includeThemeModeReport,
        'includeDefaultColorReports': includeDefaultColorReports,
        'includeFocusReport': includeFocusReport,
        'shellReady': _shell != null,
        'hasOutputCallback': _terminal.onOutput != null,
      },
    );
    if (includeThemeModeReport) {
      terminalView.refreshThemeModeReport(isDark: theme.isDark);
    }
    if (includeDefaultColorReports) {
      terminalView.refreshThemeDefaultColorReports(theme);
    }
    if (includeFocusReport) {
      terminalView.refreshFocusReport(forceTransition: true, force: true);
    }
  }

  bool _shouldRefreshPlainTerminalTui(SshSession session) =>
      session.terminalColorSchemeUpdatesMode ||
      _terminal.reportFocusMode ||
      _terminal.isUsingAltBuffer ||
      _terminal.mouseMode != MouseMode.none;

  bool _shouldSuppressMonkeyMuxTerminalControlInput(String output) =>
      shouldSuppressMonkeyMuxControlReport(
        isMonkeyMux: _activeMuxBackend == RemoteMuxBackend.monkeyMux,
        isMouseReport: _terminalMouseReportOutputPattern.hasMatch(output),
        isFocusReport: _terminalFocusReportOutputPattern.hasMatch(output),
        mouseReportingActive: _terminalReportsMouseWheelForScroll,
        focusReportingActive: _terminal.reportFocusMode,
        isAgentToolActive: _isAgentToolActive,
        currentCommand: _tmuxCurrentCommand,
      );

  /// Whether outer-tmux focus reports are safe to push through the SSH stream.
  ///
  /// If the user has detached the tmux client (or tmux exited entirely) while
  /// the screen still believes [_isTmuxActive] is true, even synthetic focus
  /// bytes reach a bare shell as typed input. Reuses the same foreground TUI
  /// signals as [_shouldRefreshPlainTerminalTui]: if no app has enabled any of
  /// the modes a real TUI uses, the foreground is almost certainly a shell
  /// prompt.
  bool _isOuterTuiSignalingActive(SshSession session) =>
      _shouldRefreshPlainTerminalTui(session);

  bool get _isTerminalThemeRefreshViewReady {
    final terminalViewWidget = _terminalViewKey.currentWidget;
    return _terminalViewKey.currentState != null &&
        terminalViewWidget is MonkeyTerminalView &&
        identical(terminalViewWidget.terminal, _terminal);
  }

  /// Proactively pushes the active terminal theme into tmux's per-pane color
  /// cache.
  ///
  /// Called whenever tmux is freshly detected or re-detected, regardless of
  /// whether a theme switch just happened. tmux caches the outer terminal's
  /// default colors per-pane, so priming refreshes tmux's pane palette and
  /// client report cache through tmux control commands instead of writing
  /// unsolicited OSC responses into the interactive shell.
  void _primeTmuxTerminalTheme(SshSession session) {
    if (!_isTmuxActive || _tmuxStateConnectionId != session.connectionId) {
      return;
    }
    if (_activeMuxBackend != RemoteMuxBackend.tmux) {
      return;
    }
    _cancelTerminalThemeRefreshTimers();
    final theme = session.terminalTheme ?? _resolveEffectiveTerminalTheme();
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'tmux_prime_requested',
      fields: {
        'connectionId': session.connectionId,
        'hasTmuxSessionName': _tmuxSessionName != null,
        'shellReady': _shell != null,
        'terminalViewReady': _terminalViewKey.currentState != null,
      },
    );
    final tmuxSessionName = _tmuxSessionName;
    if (tmuxSessionName == null) {
      DiagnosticsLogService.instance.warning(
        'terminal.theme',
        'tmux_prime_skipped_no_session_name',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }
    final refreshGeneration = ++_terminalThemeRefreshGeneration;
    final extraFlags = _activeTmuxExtraFlags;
    _queueTmuxTerminalThemeRefresh(
      _TmuxTerminalThemeRefreshRequest(
        theme: theme,
        session: session,
        sessionName: tmuxSessionName,
        refreshGeneration: refreshGeneration,
        reason: 'tmux_prime',
        extraFlags: extraFlags,
        sendOuterFocusReport: true,
      ),
    );
    for (final (:delay, :reason) in const [
      (delay: Duration(milliseconds: 900), reason: 'tmux_prime_late_900ms'),
      (delay: Duration(milliseconds: 1800), reason: 'tmux_prime_late_1800ms'),
    ]) {
      _scheduleTmuxTerminalThemeRefresh(
        _TmuxTerminalThemeRefreshRequest(
          theme: theme,
          session: session,
          sessionName: tmuxSessionName,
          refreshGeneration: refreshGeneration,
          reason: reason,
          extraFlags: extraFlags,
          sendOuterFocusReport: true,
        ),
        delay: delay,
      );
    }
  }

  void _refreshTmuxClientAfterTerminalThemeChange({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
    required String reason,
  }) {
    final tmuxSessionName = _tmuxSessionName;
    if (tmuxSessionName == null) {
      DiagnosticsLogService.instance.warning(
        'terminal.theme',
        'tmux_refresh_skipped_no_session_name',
        fields: {'reason': reason, 'connectionId': session.connectionId},
      );
      return;
    }

    _scheduleTmuxTerminalThemeRefresh(
      _TmuxTerminalThemeRefreshRequest(
        theme: theme,
        session: session,
        sessionName: tmuxSessionName,
        refreshGeneration: refreshGeneration,
        reason: reason,
        extraFlags: _activeTmuxExtraFlags,
        sendOuterFocusReport: true,
      ),
      delay: const Duration(milliseconds: 75),
    );
  }

  void _handleTmuxWindowStateChanged(
    SshSession session,
    String sessionName, {
    required bool activeWindowChanged,
  }) {
    if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
      _markMonkeyMuxReconnectEstablished(session, sessionName);
      _syncTerminalModesFromActiveMuxWindow();
      if (activeWindowChanged) {
        _prepareTerminalForMuxWindowChange(clearTerminalProgress: false);
        _refreshTerminalAfterMonkeyMuxWindowChange(session);
        _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
          session: session,
          sessionName: sessionName,
          reason: 'monkeymux_active_window_changed',
        );
      }

      _refreshMuxPaneContextAfterWindowStateChange(
        session,
        sessionName,
        force: activeWindowChanged,
      );
      return;
    }
    if (activeWindowChanged) {
      _lastMuxWindowChangeAt = DateTime.now();
      _tmuxService.deferExecsForRedraw(
        session,
        _tmuxPostWindowSwitchExecQuietPeriod,
      );
      _terminalTextInputController.resetImeCompletions();
    }
    _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
      session: session,
      sessionName: sessionName,
      reason: 'tmux_window_state_changed',
    );
  }

  void _markMonkeyMuxReconnectEstablished(
    SshSession session,
    String sessionName,
  ) {
    if (!_monkeyMuxReconnectAttachPending ||
        _connectionId != session.connectionId ||
        _monkeyMuxReconnectSessionName != sessionName) {
      return;
    }
    _monkeyMuxReconnectAttachPending = false;
    _monkeyMuxReconnectSessionName = null;
    DiagnosticsLogService.instance.info(
      'terminal',
      'monkeymux_reconnect_established',
      fields: {'connectionId': session.connectionId},
    );
  }

  void _syncAutomaticPortForwardProcessRoots(
    SshSession session,
    Iterable<TmuxWindow>? windows, {
    String? sessionName,
    String? extraFlags,
    bool queryTmuxPanePids = false,
  }) {
    final rootSyncGeneration = ++_automaticPortForwardRootSyncGeneration;
    final processRoots = windows
        ?.map((window) => window.panePid)
        .whereType<int>()
        .where((pid) => pid > 0)
        .toSet();
    unawaited(
      session.updateAutomaticPortForwardProcessRoots(
        processRoots ?? const <int>{},
      ),
    );
    if (queryTmuxPanePids && sessionName != null) {
      unawaited(
        _syncAllAutomaticPortForwardProcessRoots(
          session,
          sessionName,
          generation: rootSyncGeneration,
          extraFlags: extraFlags,
        ),
      );
    }
  }

  Future<void> _syncAllAutomaticPortForwardProcessRoots(
    SshSession session,
    String sessionName, {
    required int generation,
    String? extraFlags,
  }) async {
    try {
      final panePids = await _tmuxService.listPanePids(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
      if (generation == _automaticPortForwardRootSyncGeneration &&
          _connectionId == session.connectionId &&
          _tmuxSessionName == sessionName) {
        await session.updateAutomaticPortForwardProcessRoots(panePids);
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'mux_pane_roots_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  /// Syncs local terminal mode state when the active mux window's terminal-mode
  /// metadata changes without a full active-window switch.
  void _handleActiveWindowTerminalModeChanged() {
    if (!mounted) {
      return;
    }
    _syncTerminalModesFromActiveMuxWindow();
    setState(() {});
  }

  void _syncTerminalModesFromActiveMuxWindow() {
    if (_activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    inheritTerminalBracketedPasteModeFromMuxWindow(
      terminal: _terminal,
      activeWindowBracketedPasteMode:
          resolveTmuxBarActiveWindowBracketedPasteMode(
            _currentTmuxWindowsSnapshot,
          ),
    );
  }

  static const _terminalPasteModeSettleAttempts = 3;
  static const _terminalPasteModeSettleDelay = Duration(milliseconds: 75);

  Future<_TerminalPasteMode?> _resolveTerminalPasteMode() async {
    _syncTerminalModesFromActiveMuxWindow();
    final terminal = _terminal;
    final connectionId = _connectionId;
    final muxBackend = _activeMuxBackend;
    final activeSession = _activeSession();
    final isMuxActive = _isTmuxActive && _tmuxStateConnectionId == connectionId;
    final currentActiveWindowBracketedPasteMode =
        resolveTmuxBarActiveWindowBracketedPasteMode(
          _currentTmuxWindowsSnapshot,
        );
    final currentActiveWindowKey = isMuxActive
        ? resolveTmuxBarActiveWindowKey(_currentTmuxWindowsSnapshot)
        : null;
    final currentMuxSessionName = isMuxActive ? _tmuxSessionName : null;
    if (!isMuxActive || muxBackend != RemoteMuxBackend.monkeyMux) {
      return (
        activeWindowKey: currentActiveWindowKey,
        bracketedPasteMode: terminal.bracketedPasteMode,
        bracketedPasteModeKnown: true,
        connectionId: connectionId,
        isMuxActive: isMuxActive,
        muxBackend: muxBackend,
        muxSessionName: currentMuxSessionName,
        refreshAttempted: false,
        refreshSucceeded: false,
        session: activeSession,
        terminal: terminal,
      );
    }

    final session = activeSession;
    final sessionName = session == null
        ? null
        : _activeMonkeyMuxSessionName(session);
    if (session == null || sessionName == null) {
      return (
        activeWindowKey: resolveTmuxBarActiveWindowKey(
          _currentTmuxWindowsSnapshot,
        ),
        bracketedPasteMode: terminal.bracketedPasteMode,
        bracketedPasteModeKnown: currentActiveWindowBracketedPasteMode != null,
        connectionId: connectionId,
        isMuxActive: isMuxActive,
        muxBackend: muxBackend,
        muxSessionName: currentMuxSessionName,
        refreshAttempted: false,
        refreshSucceeded: false,
        session: session,
        terminal: terminal,
      );
    }

    bool stillOwnsTerminalContext() =>
        mounted &&
        _connectionId == connectionId &&
        identical(_activeSession(), session) &&
        identical(_terminal, terminal) &&
        _isTmuxActive == isMuxActive &&
        _tmuxStateConnectionId == connectionId &&
        _activeMuxBackend == muxBackend &&
        _activeMonkeyMuxSessionName(session) == sessionName;

    try {
      final refreshedMode =
          await refreshTerminalBracketedPasteModeFromMuxWindows(
            terminal: terminal,
            loadWindows: () async {
              final windows = await _monkeyMuxService.refreshWindows(
                session,
                sessionName,
                extraFlags: _activeTmuxExtraFlags,
              );
              return stillOwnsTerminalContext()
                  ? windows
                  : const <TmuxWindow>[];
            },
          );
      if (!stillOwnsTerminalContext()) {
        return null;
      }
      return (
        activeWindowKey: refreshedMode.activeWindowKey,
        bracketedPasteMode: refreshedMode.bracketedPasteMode,
        bracketedPasteModeKnown: refreshedMode.bracketedPasteModeKnown,
        connectionId: connectionId,
        isMuxActive: isMuxActive,
        muxBackend: muxBackend,
        muxSessionName: sessionName,
        refreshAttempted: true,
        refreshSucceeded: true,
        session: session,
        terminal: terminal,
      );
    } on TimeoutException catch (error) {
      _logTerminalPasteModeRefreshFailure(session, error);
    } on MonkeyMuxInstallException catch (error) {
      _logTerminalPasteModeRefreshFailure(session, error);
    } on SSHError catch (error) {
      _logTerminalPasteModeRefreshFailure(session, error);
    } on IOException catch (error) {
      _logTerminalPasteModeRefreshFailure(session, error);
    }

    if (!stillOwnsTerminalContext()) {
      return null;
    }
    _syncTerminalModesFromActiveMuxWindow();
    final fallbackActiveWindowBracketedPasteMode =
        resolveTmuxBarActiveWindowBracketedPasteMode(
          _currentTmuxWindowsSnapshot,
        );
    return (
      activeWindowKey: resolveTmuxBarActiveWindowKey(
        _currentTmuxWindowsSnapshot,
      ),
      bracketedPasteMode: terminal.bracketedPasteMode,
      bracketedPasteModeKnown: fallbackActiveWindowBracketedPasteMode != null,
      connectionId: connectionId,
      isMuxActive: isMuxActive,
      muxBackend: muxBackend,
      muxSessionName: sessionName,
      refreshAttempted: true,
      refreshSucceeded: false,
      session: session,
      terminal: terminal,
    );
  }

  bool _terminalPasteModeIsReliable(_TerminalPasteMode pasteMode) {
    if (!pasteMode.isMuxActive ||
        pasteMode.muxBackend != RemoteMuxBackend.monkeyMux) {
      return true;
    }
    return pasteMode.refreshSucceeded && pasteMode.activeWindowKey != null;
  }

  bool _effectiveTerminalBracketedPasteMode(_TerminalPasteMode pasteMode) =>
      pasteMode.bracketedPasteModeKnown && pasteMode.bracketedPasteMode;

  bool _terminalPasteModeCanUseResolvedState(_TerminalPasteMode pasteMode) =>
      _terminalPasteModeIsReliable(pasteMode) ||
      (pasteMode.isMuxActive &&
          pasteMode.muxBackend == RemoteMuxBackend.monkeyMux &&
          pasteMode.bracketedPasteModeKnown &&
          pasteMode.activeWindowKey != null &&
          _terminalPasteModeTargetsCurrentWindow(pasteMode));

  Future<_TerminalPasteMode?> _resolveSettledTerminalPasteMode() async {
    _TerminalPasteMode? pasteMode;
    for (
      var attempt = 0;
      attempt < _terminalPasteModeSettleAttempts;
      attempt++
    ) {
      pasteMode = await _resolveTerminalPasteMode();
      if (pasteMode == null ||
          !mounted ||
          !_terminalPasteModeOwnsCurrentContext(pasteMode)) {
        return pasteMode;
      }
      final modeReliable = _terminalPasteModeIsReliable(pasteMode);
      final targetsCurrentWindow = _terminalPasteModeTargetsCurrentWindow(
        pasteMode,
      );
      if (!shouldRetryTerminalPasteModeSettle(
        refreshAttempted: pasteMode.refreshAttempted,
        refreshSucceeded: pasteMode.refreshSucceeded,
        hasActiveWindow: pasteMode.activeWindowKey != null,
        modeReliable: modeReliable,
        targetsCurrentWindow: targetsCurrentWindow,
      )) {
        return pasteMode;
      }
      if (attempt < _terminalPasteModeSettleAttempts - 1) {
        await Future<void>.delayed(_terminalPasteModeSettleDelay);
      }
    }
    return pasteMode;
  }

  bool _terminalPasteModeOwnsCurrentContext(_TerminalPasteMode pasteMode) {
    if (!mounted ||
        _connectionId != pasteMode.connectionId ||
        !identical(_activeSession(), pasteMode.session) ||
        !identical(_terminal, pasteMode.terminal) ||
        _isTmuxActive != pasteMode.isMuxActive ||
        _activeMuxBackend != pasteMode.muxBackend) {
      return false;
    }
    if (!pasteMode.isMuxActive) {
      return true;
    }
    if (_tmuxStateConnectionId != pasteMode.connectionId) {
      return false;
    }
    final session = _activeSession();
    if (session == null) {
      return false;
    }
    return pasteMode.muxBackend == RemoteMuxBackend.monkeyMux
        ? _activeMonkeyMuxSessionName(session) == pasteMode.muxSessionName
        : _tmuxSessionName == pasteMode.muxSessionName;
  }

  bool _sameTerminalPasteContext(
    _TerminalPasteMode previous,
    _TerminalPasteMode next,
  ) =>
      previous.connectionId == next.connectionId &&
      identical(previous.session, next.session) &&
      identical(previous.terminal, next.terminal) &&
      previous.isMuxActive == next.isMuxActive &&
      previous.muxBackend == next.muxBackend &&
      previous.muxSessionName == next.muxSessionName;

  bool _terminalPasteModeTargetsCurrentWindow(_TerminalPasteMode pasteMode) {
    final activeWindowKey = pasteMode.activeWindowKey;
    if (!pasteMode.isMuxActive) {
      return true;
    }
    return terminalAttachmentPasteTargetsCurrentMuxWindow(
      hasPendingWindowSelection:
          _tmuxBarKey.currentState?.hasPendingWindowSelection ?? false,
      pasteWindowKey: activeWindowKey,
      currentWindowKey: resolveTmuxBarActiveWindowKey(
        _currentTmuxWindowsSnapshot,
      ),
    );
  }

  void _logTerminalPasteModeRefreshFailure(SshSession session, Object error) {
    DiagnosticsLogService.instance.warning(
      'terminal.clipboard',
      'mode_refresh_failed',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
  }

  void _refreshMuxPaneContextAfterWindowStateChange(
    SshSession session,
    String sessionName, {
    bool force = false,
  }) {
    final quietPeriod = _remainingMuxWindowSwitchQuietPeriod();
    if (quietPeriod > Duration.zero) {
      unawaited(
        Future<void>.delayed(quietPeriod).then((_) {
          if (!mounted ||
              _tmuxStateConnectionId != session.connectionId ||
              _tmuxSessionName != sessionName) {
            return;
          }
          _refreshMuxPaneContextAfterWindowStateChange(
            session,
            sessionName,
            force: force,
          );
        }),
      );
      return;
    }
    final refreshedAt = _muxPaneContextRefreshedAt;
    if (!force &&
        refreshedAt != null &&
        DateTime.now().difference(refreshedAt) <
            const Duration(milliseconds: 300)) {
      return;
    }
    _muxPaneContextRefreshedAt = DateTime.now();
    final refreshGeneration = ++_muxPaneContextRefreshGeneration;
    unawaited(
      Future<TmuxPaneContext?>.sync(
            () => _activeTerminalConnectionBackend(
              session,
            ).currentPaneContext(priority: SshExecPriority.low),
          )
          .then((context) {
            if (!mounted ||
                refreshGeneration != _muxPaneContextRefreshGeneration ||
                _tmuxStateConnectionId != session.connectionId ||
                _tmuxSessionName != sessionName) {
              return;
            }
            final currentPath = context?.currentPath?.trim();
            final currentCommand = context?.currentCommand?.trim();
            if ((currentPath == null || currentPath == _tmuxWorkingDirectory) &&
                (currentCommand == null ||
                    currentCommand == _tmuxCurrentCommand)) {
              return;
            }
            setState(() {
              if (currentPath != null && currentPath.isNotEmpty) {
                _tmuxWorkingDirectory = currentPath;
              }
              if (currentCommand != null && currentCommand.isNotEmpty) {
                _tmuxCurrentCommand = currentCommand;
              }
            });
          })
          .catchError((Object error) {
            DiagnosticsLogService.instance.debug(
              'tmux.ui',
              'context_refresh_failed',
              fields: {
                'connectionId': session.connectionId,
                'errorType': error.runtimeType,
              },
            );
          }),
    );
  }

  void _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange({
    required SshSession session,
    required String sessionName,
    required String reason,
  }) {
    if (!_isTmuxActive ||
        _tmuxStateConnectionId != session.connectionId ||
        _tmuxSessionName != sessionName ||
        session.terminal != _terminal) {
      return;
    }
    final isMonkeyMux = _activeMuxBackend == RemoteMuxBackend.monkeyMux;
    if (isMonkeyMux) {
      DiagnosticsLogService.instance.debug(
        'terminal.theme',
        'monkeymux_window_refresh_requested',
        fields: {'reason': reason, 'connectionId': session.connectionId},
      );
    }

    final theme = session.terminalTheme ?? _resolveEffectiveTerminalTheme();
    if (!isMonkeyMux && session.terminalTheme == null) {
      _applyTerminalThemeToSession(
        theme,
        session: session,
        forceRemoteRefresh: true,
        reason: reason,
      );
      return;
    }

    _pendingTmuxWindowThemeRefreshRequest = _TmuxTerminalThemeRefreshRequest(
      theme: theme,
      session: session,
      sessionName: sessionName,
      refreshGeneration: _terminalThemeRefreshGeneration,
      reason: reason,
      extraFlags: _activeTmuxExtraFlags,
      sendOuterFocusReport: !isMonkeyMux,
    );
    if (_tmuxWindowThemeRefreshDebounceTimer?.isActive ?? false) {
      return;
    }

    late final Timer timer;
    timer = Timer(
      _tmuxWindowThemeRefreshDebounceDelay +
          (isMonkeyMux
              ? Duration.zero
              : _remainingMuxWindowSwitchQuietPeriod()),
      () {
        _terminalThemeRefreshTimers.remove(timer);
        if (identical(_tmuxWindowThemeRefreshDebounceTimer, timer)) {
          _tmuxWindowThemeRefreshDebounceTimer = null;
        }
        final pendingRequest = _pendingTmuxWindowThemeRefreshRequest;
        _pendingTmuxWindowThemeRefreshRequest = null;
        if (pendingRequest == null ||
            _tmuxSessionName != pendingRequest.sessionName ||
            !_isCurrentTerminalThemeRefresh(
              theme: pendingRequest.theme,
              session: pendingRequest.session,
              refreshGeneration: pendingRequest.refreshGeneration,
            )) {
          return;
        }
        _queueTmuxTerminalThemeRefresh(pendingRequest);
      },
    );
    _tmuxWindowThemeRefreshDebounceTimer = timer;
    _terminalThemeRefreshTimers.add(timer);
  }

  void _scheduleTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request, {
    required Duration delay,
  }) {
    late final Timer timer;
    timer = Timer(delay, () {
      _terminalThemeRefreshTimers.remove(timer);
      if (_tmuxSessionName != request.sessionName ||
          !_isCurrentTerminalThemeRefresh(
            theme: request.theme,
            session: request.session,
            refreshGeneration: request.refreshGeneration,
          )) {
        return;
      }
      _queueTmuxTerminalThemeRefresh(request);
    });
    _terminalThemeRefreshTimers.add(timer);
  }

  void _queueTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request,
  ) {
    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      return;
    }
    if (_isTmuxThemeRefreshRunning) {
      _pendingTmuxThemeRefreshRequest = _mergePendingTmuxThemeRefreshRequest(
        request,
      );
      DiagnosticsLogService.instance.debug(
        'terminal.theme',
        'tmux_refresh_queued',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'shellReady': _shell != null,
          'terminalViewReady': _terminalViewKey.currentState != null,
        },
      );
      return;
    }

    _isTmuxThemeRefreshRunning = true;
    unawaited(_runQueuedTmuxTerminalThemeRefresh(request));
  }

  _TmuxTerminalThemeRefreshRequest _mergePendingTmuxThemeRefreshRequest(
    _TmuxTerminalThemeRefreshRequest request,
  ) {
    final pendingRequest = _pendingTmuxThemeRefreshRequest;
    final preservePendingOuterFocus =
        pendingRequest != null &&
        pendingRequest.sendOuterFocusReport &&
        _isCurrentTerminalThemeRefresh(
          theme: pendingRequest.theme,
          session: pendingRequest.session,
          refreshGeneration: pendingRequest.refreshGeneration,
        );
    if (!preservePendingOuterFocus) {
      return request;
    }
    return request.copyWith(
      reason: request.sendOuterFocusReport
          ? request.reason
          : pendingRequest.reason,
      sendOuterFocusReport:
          request.sendOuterFocusReport || preservePendingOuterFocus,
    );
  }

  Future<void> _runQueuedTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest initialRequest,
  ) async {
    try {
      var request = initialRequest;
      while (true) {
        await _runTmuxTerminalThemeRefresh(request);
        final nextRequest = _pendingTmuxThemeRefreshRequest;
        _pendingTmuxThemeRefreshRequest = null;
        if (nextRequest == null ||
            !_isCurrentTerminalThemeRefresh(
              theme: nextRequest.theme,
              session: nextRequest.session,
              refreshGeneration: nextRequest.refreshGeneration,
            )) {
          return;
        }
        request = nextRequest;
      }
    } finally {
      _isTmuxThemeRefreshRunning = false;
    }
  }

  Future<void> _runTmuxTerminalThemeRefresh(
    _TmuxTerminalThemeRefreshRequest request,
  ) async {
    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      return;
    }

    var outerRefreshReason = request.reason;
    var tmuxCommandDeferred = false;
    try {
      final mux = _activeRemoteMultiplexerService;
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'tmux_refresh_start',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'shellReady': _shell != null,
          'terminalViewReady': _terminalViewKey.currentState != null,
        },
      );
      if (mux.isExecChannelCoolingDown(request.session)) {
        DiagnosticsLogService.instance.debug(
          'terminal.theme',
          'tmux_refresh_deferred',
          fields: {
            'reason': request.reason,
            'connectionId': request.session.connectionId,
          },
        );
        tmuxCommandDeferred = true;
        outerRefreshReason = '${request.reason}_tmux_deferred';
      } else {
        // Drive the server-side foreground repaint from the latched theme-change
        // obligation. Passing it with the theme hint makes the repaint atomic
        // and immune to this request being superseded/coalesced: MonkeyMux
        // performs the synthetic redraw right after delivering the hint.
        final forcedRedrawGeneration = _monkeyMuxForcedThemeRedrawGeneration;
        final forceForegroundRedraw =
            _monkeyMuxForcedThemeRedrawPending &&
            _activeMuxBackend == RemoteMuxBackend.monkeyMux;
        await mux.refreshTerminalTheme(
          request.session,
          request.sessionName,
          request.theme,
          extraFlags: request.extraFlags,
          forceForegroundRedraw: forceForegroundRedraw,
        );
        if (forceForegroundRedraw &&
            _monkeyMuxForcedThemeRedrawGeneration == forcedRedrawGeneration) {
          // Clear only if no newer obligation was latched while awaiting; a newer
          // one bumps the generation and its own refresh will carry the redraw.
          _monkeyMuxForcedThemeRedrawPending = false;
        }
        if (forceForegroundRedraw) {
          // The helper already performs the platform-appropriate synthetic
          // redraw atomically with the theme hint. A second resize-redraw can
          // replay a large agent transcript twice and temporarily erase the
          // composer, so discard any older viewport follow-up instead.
          _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
          _monkeyMuxResizeRedrawFollowUpTimer = null;
        }
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'tmux_refresh_complete',
          fields: {
            'reason': request.reason,
            'connectionId': request.session.connectionId,
            'sendOuterFocusReport': request.sendOuterFocusReport,
            'forceForegroundRedraw': forceForegroundRedraw,
            'shellReady': _shell != null,
            'terminalViewReady': _terminalViewKey.currentState != null,
          },
        );
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.theme',
        'tmux_refresh_failed',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      outerRefreshReason = '${request.reason}_tmux_failed';
    }

    if (!_isCurrentTerminalThemeRefresh(
      theme: request.theme,
      session: request.session,
      refreshGeneration: request.refreshGeneration,
    )) {
      DiagnosticsLogService.instance.debug(
        'terminal.theme',
        'tmux_refresh_stale',
        fields: {
          'reason': request.reason,
          'connectionId': request.session.connectionId,
          'sendOuterFocusReport': request.sendOuterFocusReport,
          'tmuxCommandDeferred': tmuxCommandDeferred,
        },
      );
      return;
    }
    if (request.sendOuterFocusReport) {
      if (!_isOuterTuiSignalingActive(request.session)) {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'tmux_outer_focus_skipped',
          fields: {
            'reason': '${outerRefreshReason}_no_foreground_tui',
            'connectionId': request.session.connectionId,
            'colorSchemeUpdatesMode':
                request.session.terminalColorSchemeUpdatesMode,
            'focusMode': _terminal.reportFocusMode,
            'altBuffer': _terminal.isUsingAltBuffer,
            'mouseMode': _terminal.mouseMode != MouseMode.none,
          },
        );
        return;
      }
      _refreshTerminalThemeReportsForTui(
        request.theme,
        includeThemeModeReport: false,
        reason: '${outerRefreshReason}_tmux_outer_focus',
      );
    }
  }

  void _scheduleTerminalThemeRefreshForTui({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
    required Duration delay,
    bool includeThemeModeReport = true,
    bool includeDefaultColorReports = false,
    bool includeFocusReport = true,
    DateTime? requirePaletteQuerySince,
    String reason = 'unspecified',
  }) {
    late final Timer timer;
    timer = Timer(delay, () {
      _terminalThemeRefreshTimers.remove(timer);
      if (!_isCurrentTerminalThemeRefresh(
        theme: theme,
        session: session,
        refreshGeneration: refreshGeneration,
      )) {
        return;
      }
      if (includeDefaultColorReports &&
          requirePaletteQuerySince != null &&
          !session.hasTerminalPaletteQuerySince(requirePaletteQuerySince)) {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'defaults_skipped_no_palette_query',
          fields: {'reason': reason, 'connectionId': session.connectionId},
        );
        return;
      }
      if (_isTmuxActive &&
          _tmuxStateConnectionId == session.connectionId &&
          !_isOuterTuiSignalingActive(session)) {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'tmux_outer_late_skipped',
          fields: {
            'reason': reason,
            'connectionId': session.connectionId,
            'colorSchemeUpdatesMode': session.terminalColorSchemeUpdatesMode,
            'focusMode': _terminal.reportFocusMode,
            'altBuffer': _terminal.isUsingAltBuffer,
            'mouseMode': _terminal.mouseMode != MouseMode.none,
          },
        );
        return;
      }
      _refreshTerminalThemeReportsForTui(
        theme,
        includeThemeModeReport: includeThemeModeReport,
        includeDefaultColorReports: includeDefaultColorReports,
        includeFocusReport: includeFocusReport,
        reason: reason,
      );
    });
    _terminalThemeRefreshTimers.add(timer);
  }

  void _cancelTerminalThemeRefreshTimers() {
    _cancelPendingTmuxWindowThemeRefresh();
    for (final timer in _terminalThemeRefreshTimers) {
      timer.cancel();
    }
    _terminalThemeRefreshTimers.clear();
  }

  void _cancelPendingTmuxWindowThemeRefresh() {
    final timer = _tmuxWindowThemeRefreshDebounceTimer;
    if (timer != null) {
      timer.cancel();
      _terminalThemeRefreshTimers.remove(timer);
    }
    _tmuxWindowThemeRefreshDebounceTimer = null;
    _pendingTmuxWindowThemeRefreshRequest = null;
  }

  bool _isCurrentTerminalThemeRefresh({
    required TerminalThemeData theme,
    required SshSession session,
    required int refreshGeneration,
  }) {
    final activeTheme = session.terminalTheme;
    return mounted &&
        refreshGeneration == _terminalThemeRefreshGeneration &&
        session.terminal == _terminal &&
        activeTheme != null &&
        _terminalThemesMatchForRemoteRefresh(activeTheme, theme);
  }

  bool _terminalThemesMatchForRemoteRefresh(
    TerminalThemeData previous,
    TerminalThemeData next,
  ) => terminalThemesMatchForColors(previous, next);

  bool _sameTerminalTheme(
    TerminalThemeData? previous,
    TerminalThemeData? next,
  ) {
    if (previous == null || next == null) {
      return previous == next;
    }
    return _terminalThemesMatchForRemoteRefresh(previous, next);
  }

  bool _sameTerminalThemeSettings(
    TerminalThemeSettings? previous,
    TerminalThemeSettings next,
  ) =>
      previous != null &&
      previous.lightThemeId == next.lightThemeId &&
      previous.darkThemeId == next.darkThemeId;

  void _handleTerminalThemeDependenciesChanged({
    bool forceRemoteRefresh = false,
    String reason = 'unknown',
  }) {
    if (!mounted) {
      return;
    }
    final session = _observedSession ?? _activeSession();
    if (forceRemoteRefresh &&
        _wasBackgrounded &&
        _isWindowsMonkeyMuxSession(session)) {
      _terminalThemeRefreshRequiredAfterResume = true;
      DiagnosticsLogService.instance.info(
        'terminal.theme',
        'dependency_deferred',
        fields: {
          'reason': reason,
          'connectionId': session?.connectionId ?? _connectionId,
          'until': 'app_resumed',
        },
      );
      return;
    }
    _pendingTerminalThemeDependencyReload = true;
    _pendingTerminalThemeDependencyForceRemoteRefresh =
        _pendingTerminalThemeDependencyForceRemoteRefresh || forceRemoteRefresh;
    _pendingTerminalThemeDependencyReason = reason;
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'dependency_changed',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'hasCurrentTheme': _currentTheme != null,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    _scheduleTerminalThemeDependencyReload();
  }

  void _scheduleTerminalThemeDependencyReload() {
    if (_terminalThemeDependencyReloadQueued) {
      return;
    }
    _terminalThemeDependencyReloadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalThemeDependencyReloadQueued = false;
      if (!mounted || !_pendingTerminalThemeDependencyReload) {
        return;
      }
      if (_currentTheme == null) {
        return;
      }
      final forceRemoteRefresh =
          _pendingTerminalThemeDependencyForceRemoteRefresh;
      final reason = _pendingTerminalThemeDependencyReason;
      _pendingTerminalThemeDependencyReload = false;
      _pendingTerminalThemeDependencyForceRemoteRefresh = false;
      _pendingTerminalThemeDependencyReason = 'unknown';
      unawaited(
        _reloadTerminalThemeForDependencies(
          forceRemoteRefresh: forceRemoteRefresh,
          reason: reason,
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _reloadTerminalThemeForDependencies({
    bool forceRemoteRefresh = false,
    String reason = 'unknown',
  }) async {
    final session = _connectionId == null
        ? null
        : _sessionsNotifier?.getSession(_connectionId!);
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'dependency_reload',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'hasSession': session != null,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    if (session != null) {
      final restored = await _restoreSessionThemeOverride(
        session,
        forceRemoteRefresh: forceRemoteRefresh,
        reason: reason,
      );
      if (restored) {
        return;
      }
    }

    if (_sessionThemeOverride == null) {
      await _loadTheme(forceRemoteRefresh: forceRemoteRefresh, reason: reason);
    }
  }

  void _syncAppThemeOverrideFromSession(SshSession session) {
    if (session.terminalThemeLightId == null &&
        session.terminalThemeDarkId == null) {
      _clearAppThemeOverride();
      return;
    }
    _terminalAppThemeOverrideNotifier.activeOverride = TerminalAppThemeOverride(
      owner: _terminalAppThemeOverrideOwner,
      lightThemeId: session.terminalThemeLightId,
      darkThemeId: session.terminalThemeDarkId,
    );
  }

  void _clearAppThemeOverride() => _terminalAppThemeOverrideNotifier
      .clearForOwner(_terminalAppThemeOverrideOwner);

  TerminalThemeData _resolveEffectiveTerminalTheme() {
    final isDark = _resolveTerminalThemeBrightness() == Brightness.dark;
    return _sessionThemeOverride ??
        _currentTheme ??
        (isDark
            ? TerminalThemes.defaultDarkTheme
            : TerminalThemes.defaultLightTheme);
  }

  Brightness _resolveTerminalThemeBrightness() {
    final themeMode = ref.read(themeModeNotifierProvider);
    return switch (themeMode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system =>
        MediaQuery.maybeOf(context)?.platformBrightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
  }

  SshConnectionState _selectTrackedConnectionState(
    Map<int, SshConnectionState> states,
  ) => _sessionController.selectTrackedConnectionState(states);

  // iOS can prompt for paste permission on any clipboard content read. Never
  // poll it on startup, resume, or a timer, even when remote reads are allowed.
  // Explicit paste and opted-in OSC 52 queries use their own read paths.
  bool _canPollLocalClipboard(SshSession session) =>
      session.clipboardSharingEnabled &&
      session.localClipboardReadEnabled &&
      (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS);

  bool _ownsClipboardSync(SshSession session, int generation) =>
      mounted &&
      generation == _clipboardSyncGeneration &&
      session.clipboardSharingEnabled &&
      identical(_activeSession(), session) &&
      _sessionController.isObservingSession(session);

  Future<void> _startSharedClipboardSync(SshSession session) async {
    _stopSharedClipboardSync();
    final generation = _clipboardSyncGeneration;
    _remoteClipboardUnsupported = false;
    final localText = _canPollLocalClipboard(session)
        ? await _readSystemClipboardText()
        : null;
    if (!_ownsClipboardSync(session, generation)) return;
    _lastObservedLocalClipboardText = localText;
    try {
      final remoteText = await _readRemoteClipboardText(session);
      if (!_ownsClipboardSync(session, generation)) return;
      _lastObservedRemoteClipboardText = remoteText;
    } on Object catch (error) {
      if (!_ownsClipboardSync(session, generation)) return;
      _handleSharedClipboardRemoteCommandFailure(
        session,
        error,
        operation: 'initial_read',
      );
      return;
    }

    if (_remoteClipboardUnsupported) return;
    if (_canPollLocalClipboard(session)) {
      _localClipboardSyncTimer = Timer.periodic(
        _localClipboardSyncInterval,
        (_) => unawaited(_syncLocalClipboardToRemote(session)),
      );
    }
    _remoteClipboardSyncTimer = Timer.periodic(
      _remoteClipboardSyncInterval,
      (_) => unawaited(_syncRemoteClipboardToLocal(session)),
    );
  }

  void _stopSharedClipboardSync() {
    _clipboardSyncGeneration++;
    _localClipboardSyncTimer?.cancel();
    _localClipboardSyncTimer = null;
    _remoteClipboardSyncTimer?.cancel();
    _remoteClipboardSyncTimer = null;
    _isPollingRemoteClipboard = false;
    _isPushingLocalClipboard = false;
  }

  Future<String?> _readSystemClipboardText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        return data!.text;
      }
    } on PlatformException {
      if (!_isAndroidPlatform) {
        return null;
      }
    }

    if (_isAndroidPlatform) {
      try {
        return await Pasteboard.text;
      } on PlatformException {
        return null;
      }
    }

    return null;
  }

  Future<void> _syncLocalClipboardToRemote(SshSession session) async {
    if (!_ownsClipboardSync(session, _clipboardSyncGeneration) ||
        !_canPollLocalClipboard(session) ||
        _remoteClipboardUnsupported ||
        _isPushingLocalClipboard) {
      return;
    }

    final generation = _clipboardSyncGeneration;
    _isPushingLocalClipboard = true;
    try {
      final localText = await _readSystemClipboardText();
      if (!_ownsClipboardSync(session, generation) ||
          !_canPollLocalClipboard(session)) {
        return;
      }
      if (localText == null ||
          localText == _lastObservedLocalClipboardText ||
          localText == _lastObservedRemoteClipboardText ||
          localText == _lastAppliedLocalClipboardText ||
          !RemoteClipboardSyncService.canSyncText(localText)) {
        _lastObservedLocalClipboardText = localText;
        return;
      }

      final output = await _runRemoteCommand(
        session,
        RemoteClipboardSyncService.buildWriteCommand(localText),
      );
      if (!_ownsClipboardSync(session, generation)) return;
      if (RemoteClipboardSyncService.outputIndicatesUnsupported(output)) {
        _remoteClipboardUnsupported = true;
        _remoteClipboardSyncTimer?.cancel();
        _remoteClipboardSyncTimer = null;
        return;
      }
      _lastObservedLocalClipboardText = localText;
      _lastObservedRemoteClipboardText = localText;
      _lastAppliedRemoteClipboardText = localText;
    } on Object catch (error) {
      if (!_ownsClipboardSync(session, generation)) return;
      _handleSharedClipboardRemoteCommandFailure(
        session,
        error,
        operation: 'write',
      );
    } finally {
      if (generation == _clipboardSyncGeneration) {
        _isPushingLocalClipboard = false;
      }
    }
  }

  Future<void> _syncRemoteClipboardToLocal(SshSession session) async {
    if (!_ownsClipboardSync(session, _clipboardSyncGeneration) ||
        _remoteClipboardUnsupported ||
        _isPollingRemoteClipboard) {
      return;
    }

    final generation = _clipboardSyncGeneration;
    _isPollingRemoteClipboard = true;
    try {
      final remoteText = await _readRemoteClipboardText(session);
      if (!_ownsClipboardSync(session, generation)) return;
      if (!shouldApplyRemoteClipboardTextToLocal(
        remoteText: remoteText,
        lastObservedRemoteText: _lastObservedRemoteClipboardText,
        lastObservedLocalText: _lastObservedLocalClipboardText,
        lastAppliedRemoteText: _lastAppliedRemoteClipboardText,
        recentLocalClipboardText: _recentLocalClipboardText,
        recentLocalClipboardAt: _recentLocalClipboardAt,
        now: DateTime.now(),
      )) {
        if (remoteText != null) {
          _lastObservedRemoteClipboardText = remoteText;
        }
        return;
      }

      final remoteClipboardText = remoteText;
      if (remoteClipboardText == null) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: remoteClipboardText));
      if (!_ownsClipboardSync(session, generation)) return;
      _lastObservedRemoteClipboardText = remoteClipboardText;
      _lastObservedLocalClipboardText = remoteClipboardText;
      _lastAppliedLocalClipboardText = remoteClipboardText;
    } on PlatformException {
      return;
    } on Object catch (error) {
      if (!_ownsClipboardSync(session, generation)) return;
      _handleSharedClipboardRemoteCommandFailure(
        session,
        error,
        operation: 'read',
      );
      return;
    } finally {
      if (generation == _clipboardSyncGeneration) {
        _isPollingRemoteClipboard = false;
      }
    }
  }

  Future<String?> _readRemoteClipboardText(SshSession session) async {
    final generation = _clipboardSyncGeneration;
    final output = await _runRemoteCommand(
      session,
      RemoteClipboardSyncService.buildReadCommand(),
    );
    if (!_ownsClipboardSync(session, generation)) return null;
    final parsed = RemoteClipboardSyncService.parseReadOutput(output);
    if (!parsed.supported) {
      _remoteClipboardUnsupported = true;
      return null;
    }
    return parsed.text;
  }

  void _handleSharedClipboardRemoteCommandFailure(
    SshSession session,
    Object error, {
    required String operation,
  }) {
    _remoteClipboardUnsupported = true;
    _stopSharedClipboardSync();
    DiagnosticsLogService.instance.warning(
      'terminal.clipboard',
      'remote_sync_failed',
      fields: {
        'connectionId': session.connectionId,
        'operation': operation,
        'errorType': error.runtimeType,
      },
    );
  }

  Future<String> _runRemoteCommand(SshSession session, String command) async =>
      (await _activeTerminalConnectionBackend(
        session,
      ).runClientCommand(command, priority: SshExecPriority.low)).output;

  void _handleTerminalScroll() {
    final currentOffset = _terminalScrollController.hasClients
        ? _terminalScrollController.offset
        : 0.0;
    final didScrollOffsetChange = currentOffset != _lastTerminalScrollOffset;
    _lastTerminalScrollOffset = currentOffset;
    if (didScrollOffsetChange && !_isNavigatingCommandMarks) {
      _previousCommandNavigationRow = null;
      _previousCommandNavigationConnectionId = null;
      _previousCommandNavigationMarkCount = null;
    }
    if (!_isTerminalOutputFollowPaused || didScrollOffsetChange) {
      _setShouldFollowLiveOutput(
        shouldFollowTerminalOutput(
          hasScrollClients: _terminalScrollController.hasClients,
          currentOffset: currentOffset,
          maxScrollExtent: _terminalScrollController.hasClients
              ? _terminalScrollController.position.maxScrollExtent
              : 0,
        ),
      );
    }
    _scheduleScrollTerminalPathUnderlineRefresh();
  }

  /// Throttles the visible-path underline refresh while scrolling.
  ///
  /// A scroll notification fires many times per fling, and each refresh scans
  /// the visible rows for file paths and — when the set changes — calls
  /// `setState`, rebuilding the whole terminal screen. Running that on every
  /// scroll frame is the dominant build-thread cost while scrolling an active
  /// window. The visible underlines themselves are row/column anchored, so they
  /// still track the scroll between refreshes; only new-path detection and the
  /// tap target rects lag by up to the throttle window, which is imperceptible
  /// mid-fling. Leading + trailing edges keep the settled position accurate.
  void _scheduleScrollTerminalPathUnderlineRefresh() {
    const throttleMs = 120;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sinceLast = nowMs - _lastTerminalPathUnderlineRefreshMs;
    if (sinceLast >= throttleMs) {
      _terminalPathUnderlineScrollThrottleTimer?.cancel();
      _terminalPathUnderlineScrollThrottleTimer = null;
      _lastTerminalPathUnderlineRefreshMs = nowMs;
      _refreshVisibleTerminalPathUnderlines();
      return;
    }
    if (_terminalPathUnderlineScrollThrottleTimer?.isActive ?? false) {
      return;
    }
    _terminalPathUnderlineScrollThrottleTimer = Timer(
      Duration(milliseconds: throttleMs - sinceLast),
      () {
        _terminalPathUnderlineScrollThrottleTimer = null;
        if (!mounted) {
          return;
        }
        _lastTerminalPathUnderlineRefreshMs =
            DateTime.now().millisecondsSinceEpoch;
        _refreshVisibleTerminalPathUnderlines();
      },
    );
  }

  void _setShouldFollowLiveOutput(bool value) {
    if (_shouldFollowLiveOutput == value) {
      return;
    }
    _shouldFollowLiveOutput = value;
    _syncTerminalLiveOutputAutoScroll();
  }

  void _followLiveOutput() {
    _setShouldFollowLiveOutput(true);
    _queueTerminalScrollToBottom();
  }

  void _handleTerminalUserInput() {
    _terminalUserInputGeneration++;
    _followLiveOutput();
  }

  void _followNextLiveOutputWithoutScrolling() {
    _setShouldFollowLiveOutput(true);
  }

  void _handleTerminalOutputForShellCompletion(String output) {
    if (output.contains('\r') || output.contains('\n')) {
      _hideShellCompletionPopup();
      return;
    }
    if (!ref.read(shellCompletionsNotifierProvider)) {
      _hideShellCompletionPopup();
      return;
    }
    if (!_terminalOutputCanTriggerShellCompletion(output)) {
      if (_filterVisibleShellCompletionsForCurrentInput()) {
        return;
      }
      _hideShellCompletionPopup();
      return;
    }
    if (_hasKnownNonShellCompletionContext()) {
      _hideShellCompletionPopup();
      return;
    }

    _trackShellCompletionOptimisticInput(output);
    // Keep matching rows visible, but still refresh for the narrower prefix.
    // Returning here leaves the capped source result stale for later input.
    final keptVisibleSuggestions =
        _filterVisibleShellCompletionsForCurrentInput();
    if (!keptVisibleSuggestions) {
      _showCachedShellCompletionsIfAvailable();
    }
    _primeShellCompletionHistory();
    _queueShellCompletionRefresh();
  }

  bool _terminalOutputCanTriggerShellCompletion(String output) =>
      canTerminalOutputTriggerShellCompletion(
        output: output,
        isUsingAltBuffer: _isUsingAltBuffer,
        isTmuxActive: _isTmuxActive,
        showsNativeSelectionOverlay: _isNativeSelectionMode,
      );

  bool _hasKnownNonShellCompletionContext() {
    if (_isTmuxActive) {
      final command = _tmuxCurrentCommand?.trim();
      return command != null &&
          command.isNotEmpty &&
          !isShellCompletionTmuxShellCommand(command);
    }
    return _shellStatus == TerminalShellStatus.runningCommand;
  }

  void _trackShellCompletionOptimisticInput(String output) {
    final terminalSnapshot = _buildWrappedTerminalCommandSnapshot();
    if (terminalSnapshot == null) {
      _shellCompletionOptimisticSnapshot = null;
      return;
    }

    _shellCompletionPromptPrefix ??= terminalSnapshot.text.substring(
      0,
      terminalSnapshot.cursorOffset,
    );
    final snapshot = _shellCompletionOptimisticSnapshot ?? terminalSnapshot;
    _shellCompletionOptimisticSnapshot = applyShellCompletionOutputToSnapshot(
      snapshot: snapshot,
      output: output,
    );
  }

  void _syncShellCompletionOptimisticSnapshotWithTerminal() {
    final optimisticSnapshot = _shellCompletionOptimisticSnapshot;
    if (optimisticSnapshot == null) {
      return;
    }
    final terminalSnapshot = _buildWrappedTerminalCommandSnapshot();
    if (terminalSnapshot == null) {
      return;
    }
    if (terminalSnapshot.text == optimisticSnapshot.text &&
        terminalSnapshot.cursorOffset == optimisticSnapshot.cursorOffset) {
      _shellCompletionOptimisticSnapshot = null;
    }
  }

  void _queueShellCompletionRefresh({bool resetAnchorRetries = true}) {
    if (!ref.read(shellCompletionsNotifierProvider)) {
      _hideShellCompletionPopup();
      return;
    }
    if (resetAnchorRetries) {
      _shellCompletionAnchorRetryCount = 0;
    }
    _shellCompletionDebounceTimer?.cancel();
    final generation = ++_shellCompletionGeneration;
    _shellCompletionDebounceTimer = Timer(_shellCompletionDebounce, () {
      if (generation == _shellCompletionGeneration) {
        _shellCompletionDebounceTimer = null;
      }
      unawaited(_refreshShellCompletions(generation));
    });
  }

  void _primeShellCompletionHistory() {
    final context = _buildImmediateShellCompletionContext();
    if (context == null) {
      return;
    }
    final staticSuggestions = buildShellCompletionStaticSuggestions(
      context.invocation,
    );
    if (staticSuggestions != null && context.invocation.token.isEmpty) {
      return;
    }

    ref
        .read(shellCompletionServiceProvider)
        .primeHistory(context.session, context.invocation);
  }

  void _showCachedShellCompletionsIfAvailable() {
    final context = _buildImmediateShellCompletionContext();
    if (context == null) {
      return;
    }
    final anchor = _resolveTerminalCursorGlobalRect();
    if (anchor == null) {
      return;
    }
    final suggestions = ref
        .read(shellCompletionServiceProvider)
        .cachedHistorySuggestions(context.session, context.invocation);
    if (suggestions.isEmpty) {
      return;
    }
    _showShellCompletions(
      invocation: context.invocation,
      suggestions: suggestions,
      anchor: anchor,
    );
  }

  ({SshSession session, ShellCompletionInvocation invocation})?
  _buildImmediateShellCompletionContext() {
    final session = _activeSession();
    if (session == null) {
      return null;
    }

    final cachedTmuxCommand = _tmuxCurrentCommand?.trim();
    final shellCommand =
        _isTmuxActive && isShellCompletionTmuxShellCommand(cachedTmuxCommand)
        ? cachedTmuxCommand
        : null;
    final invocation = _buildCurrentShellCompletionInvocation(
      workingDirectory: _workingDirectoryPath,
      shellCommand: shellCommand,
    );
    if (invocation == null) {
      return null;
    }
    return (session: session, invocation: invocation);
  }

  Future<void> _refreshShellCompletions(int generation) async {
    if (!mounted ||
        generation != _shellCompletionGeneration ||
        !ref.read(shellCompletionsNotifierProvider)) {
      return;
    }

    final session = _activeSession();
    if (session == null) {
      _hideShellCompletionPopup();
      return;
    }

    final cachedInvocation = _buildCurrentShellCompletionInvocation(
      workingDirectory: _workingDirectoryPath,
      requirePromptContext: false,
    );
    if (cachedInvocation == null) {
      if (_filterVisibleShellCompletionsForCurrentInput()) {
        return;
      }
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return;
    }

    final shellCompletionContext = await _resolveShellCompletionContext(
      session,
      generation,
    );
    if (!mounted ||
        generation != _shellCompletionGeneration ||
        !ref.read(shellCompletionsNotifierProvider)) {
      return;
    }
    if (!shellCompletionContext.canComplete) {
      if (_filterVisibleShellCompletionsForCurrentInput()) {
        return;
      }
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return;
    }

    final invocation = _buildCurrentShellCompletionInvocation(
      workingDirectory: shellCompletionContext.workingDirectory,
      shellCommand: shellCompletionContext.shellCommand,
    );
    final anchor = _resolveTerminalCursorGlobalRect();
    if (invocation == null) {
      if (_filterVisibleShellCompletionsForCurrentInput()) {
        return;
      }
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return;
    }
    if (anchor == null) {
      if (_shellCompletionAnchorRetryCount < _shellCompletionMaxAnchorRetries) {
        _shellCompletionAnchorRetryCount += 1;
        _queueShellCompletionRefreshAfterFrame(generation);
      } else if (_filterVisibleShellCompletionsForCurrentInput()) {
        return;
      } else {
        _hideShellCompletionPopup(resetPromptPrefix: false);
      }
      return;
    }

    if (_shellCompletionInFlightRequestKey != null) {
      _shellCompletionRefreshAfterInFlight = true;
      return;
    }
    final requestKey = _shellCompletionRequestKey(session, invocation);
    _shellCompletionInFlightRequestKey = requestKey;
    try {
      final suggestions = await ref
          .read(shellCompletionServiceProvider)
          .complete(session, invocation);
      if (!mounted ||
          generation != _shellCompletionGeneration ||
          !ref.read(shellCompletionsNotifierProvider)) {
        return;
      }
      final latestInvocation = _buildCurrentShellCompletionInvocation(
        workingDirectory: invocation.workingDirectory,
        shellCommand: invocation.shellCommand,
      );
      if (latestInvocation == null) {
        if (_filterVisibleShellCompletionsForCurrentInput()) {
          return;
        }
        _hideShellCompletionPopup(resetPromptPrefix: false);
        return;
      }
      final latestSuggestions = filterShellCompletionSuggestionsForCurrentInput(
        originalInvocation: invocation,
        currentInvocation: latestInvocation,
        suggestions: suggestions,
      );
      if (latestSuggestions.isEmpty) {
        if (_filterVisibleShellCompletionsForCurrentInput()) {
          return;
        }
        _hideShellCompletionPopup(resetPromptPrefix: false);
        return;
      }
      final latestAnchor = _resolveTerminalCursorGlobalRect() ?? anchor;
      _showShellCompletions(
        invocation: latestInvocation,
        suggestions: latestSuggestions,
        anchor: latestAnchor,
        sourceInvocation: invocation,
        sourceSuggestions: suggestions,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'ui_request_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      if (mounted &&
          generation == _shellCompletionGeneration &&
          !_filterVisibleShellCompletionsForCurrentInput()) {
        _hideShellCompletionPopup(resetPromptPrefix: false);
      }
    } finally {
      final shouldRefreshAfterInFlight =
          _shellCompletionRefreshAfterInFlight &&
          mounted &&
          generation != _shellCompletionGeneration &&
          ref.read(shellCompletionsNotifierProvider);
      _shellCompletionRefreshAfterInFlight = false;
      if (_shellCompletionInFlightRequestKey == requestKey) {
        _shellCompletionInFlightRequestKey = null;
      }
      if (shouldRefreshAfterInFlight) {
        _queueShellCompletionRefresh();
      }
    }
  }

  void _queueShellCompletionRefreshAfterFrame(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _shellCompletionGeneration ||
          !ref.read(shellCompletionsNotifierProvider)) {
        return;
      }
      _queueShellCompletionRefresh(resetAnchorRetries: false);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  String _shellCompletionRequestKey(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) => [
    session.connectionId,
    invocation.mode.name,
    invocation.workingDirectory ?? '',
    invocation.shellCommand ?? '',
    invocation.commandLine,
    invocation.cursorOffset,
    invocation.tokenStart,
    invocation.token,
  ].join('\u001f');

  Future<({bool canComplete, String? workingDirectory, String? shellCommand})>
  _resolveShellCompletionContext(SshSession session, int generation) async {
    var workingDirectory = _workingDirectoryPath;
    final tmuxSessionName = _isTmuxActive ? _tmuxSessionName : null;
    if (tmuxSessionName == null) {
      return (
        canComplete: isShellCompletionPromptContext(
          shellStatus: _shellStatus,
          isTmuxActive: false,
          tmuxCurrentCommand: null,
        ),
        workingDirectory: workingDirectory,
        shellCommand: null,
      );
    }

    final backend = _activeTerminalConnectionBackend(session);
    final windowKey = resolveTmuxBarActiveWindowKey(
      _currentTmuxWindowsSnapshot,
    );
    final cachedAt = _shellCompletionTmuxContextRefreshedAt;
    final hasCachedContext =
        cachedAt != null &&
        _shellCompletionTmuxContextConnectionId == session.connectionId &&
        _shellCompletionTmuxContextSessionName == tmuxSessionName &&
        DateTime.now().difference(cachedAt) <= _shellCompletionTmuxContextTtl &&
        (_tmuxCurrentCommand?.trim().isNotEmpty ?? false);
    if (!hasCachedContext) {
      TmuxPaneContext? paneContext;
      try {
        paneContext = await backend.currentPaneContext();
      } on Object catch (error) {
        if (error is! Exception && !isExpectedSshOperationError(error)) {
          rethrow;
        }
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'tmux_context_failed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
      if (!_ownsTerminalConnectionBackend(session, backend, windowKey) ||
          generation != _shellCompletionGeneration ||
          paneContext == null) {
        return (
          canComplete: false,
          workingDirectory: workingDirectory,
          shellCommand: null,
        );
      }
      final freshWorkingDirectory = paneContext.currentPath?.trim();
      final freshCommand = paneContext.currentCommand?.trim();
      _shellCompletionTmuxContextRefreshedAt = DateTime.now();
      _shellCompletionTmuxContextConnectionId = session.connectionId;
      _shellCompletionTmuxContextSessionName = tmuxSessionName;
      if (freshWorkingDirectory != null && freshWorkingDirectory.isNotEmpty) {
        _tmuxWorkingDirectory = freshWorkingDirectory;
      }
      if (freshCommand != null && freshCommand.isNotEmpty) {
        _tmuxCurrentCommand = freshCommand;
      }
    }

    final tmuxCommand = _tmuxCurrentCommand?.trim();
    final tmuxShellCommand =
        tmuxCommand != null && isShellCompletionTmuxShellCommand(tmuxCommand)
        ? tmuxCommand
        : null;
    final tmuxWorkingDirectory = _tmuxWorkingDirectory?.trim();
    if (tmuxWorkingDirectory != null && tmuxWorkingDirectory.isNotEmpty) {
      workingDirectory = tmuxWorkingDirectory;
    }
    return (
      canComplete: tmuxShellCommand != null,
      workingDirectory: workingDirectory,
      shellCommand: tmuxShellCommand,
    );
  }

  ShellCompletionInvocation? _buildCurrentShellCompletionInvocation({
    required String? workingDirectory,
    String? shellCommand,
    bool requirePromptContext = true,
  }) {
    if (!ref.read(shellCompletionsNotifierProvider) ||
        (_isUsingAltBuffer && !_isTmuxActive) ||
        _isNativeSelectionMode) {
      return null;
    }
    if (requirePromptContext &&
        !isShellCompletionPromptContext(
          shellStatus: _shellStatus,
          isTmuxActive: _isTmuxActive,
          tmuxCurrentCommand: shellCommand ?? _tmuxCurrentCommand,
        )) {
      return null;
    }
    final snapshot =
        _shellCompletionOptimisticSnapshot ??
        _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return null;
    }
    return buildShellCompletionInvocation(
      terminalText: snapshot.text,
      terminalCursorOffset: snapshot.cursorOffset,
      promptPrefix: _shellCompletionPromptPrefix,
      workingDirectory: workingDirectory,
      shellCommand: shellCommand,
    );
  }

  Rect? _resolveTerminalCursorGlobalRect() {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      return null;
    }
    return terminalViewState.globalCursorRect;
  }

  bool _filterVisibleShellCompletionsForCurrentInput() {
    final sourceInvocation =
        _shellCompletionSourceInvocation ?? _shellCompletionInvocation;
    if (sourceInvocation == null || _shellCompletionSuggestions.isEmpty) {
      return false;
    }

    final sourceSuggestions = _shellCompletionSourceSuggestions.isNotEmpty
        ? _shellCompletionSourceSuggestions
        : _shellCompletionSuggestions;
    final currentInvocation = _buildCurrentShellCompletionInvocation(
      workingDirectory: sourceInvocation.workingDirectory,
      shellCommand: sourceInvocation.shellCommand,
    );
    final filteredSuggestions = filterShellCompletionSuggestionsForCurrentInput(
      originalInvocation: sourceInvocation,
      currentInvocation: currentInvocation,
      suggestions: sourceSuggestions,
    );

    if (filteredSuggestions.isEmpty || currentInvocation == null) {
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return false;
    }

    final anchor = _resolveTerminalCursorGlobalRect();
    setState(() {
      _shellCompletionInvocation = currentInvocation;
      _shellCompletionSuggestions = filteredSuggestions;
      if (anchor != null) {
        _shellCompletionAnchorGlobalRect = anchor;
      }
    });
    return true;
  }

  void _showShellCompletions({
    required ShellCompletionInvocation invocation,
    required List<ShellCompletionSuggestion> suggestions,
    required Rect anchor,
    ShellCompletionInvocation? sourceInvocation,
    List<ShellCompletionSuggestion>? sourceSuggestions,
  }) {
    setState(() {
      _shellCompletionSourceInvocation = sourceInvocation ?? invocation;
      _shellCompletionSourceSuggestions = sourceSuggestions ?? suggestions;
      _shellCompletionInvocation = invocation;
      _shellCompletionSuggestions = suggestions;
      _shellCompletionAnchorGlobalRect = anchor;
      _shellCompletionAnchorRetryCount = 0;
    });
  }

  void _hideShellCompletionPopup({bool resetPromptPrefix = true}) {
    _shellCompletionDebounceTimer?.cancel();
    _shellCompletionDebounceTimer = null;
    _shellCompletionGeneration += 1;
    _shellCompletionInFlightRequestKey = null;
    _shellCompletionRefreshAfterInFlight = false;
    _shellCompletionAnchorRetryCount = 0;
    if (resetPromptPrefix) {
      _shellCompletionPromptPrefix = null;
      _shellCompletionOptimisticSnapshot = null;
    }
    if (_shellCompletionInvocation == null &&
        _shellCompletionSuggestions.isEmpty &&
        _shellCompletionAnchorGlobalRect == null) {
      return;
    }
    void clearState() {
      _shellCompletionSourceInvocation = null;
      _shellCompletionSourceSuggestions = const <ShellCompletionSuggestion>[];
      _shellCompletionInvocation = null;
      _shellCompletionSuggestions = const <ShellCompletionSuggestion>[];
      _shellCompletionAnchorGlobalRect = null;
    }

    if (mounted) {
      setState(clearState);
    } else {
      clearState();
    }
  }

  void _acceptShellCompletion(ShellCompletionSuggestion suggestion) {
    final invocation = _shellCompletionInvocation;
    if (invocation == null) {
      return;
    }
    final currentInvocation = _buildCurrentShellCompletionInvocation(
      workingDirectory: invocation.workingDirectory,
      shellCommand: invocation.shellCommand,
    );
    if (!shouldAcceptShellCompletionSuggestion(
      originalInvocation: invocation,
      currentInvocation: currentInvocation,
      suggestion: suggestion,
    )) {
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return;
    }

    var deleteCount = invocation.cursorOffset - suggestion.replacementStart;
    if (currentInvocation != null &&
        suggestion.kind == ShellCompletionSuggestionKind.history) {
      final replacementStart = suggestion.replacementStart == 0
          ? suggestion.replacementStart
          : currentInvocation.tokenStart;
      deleteCount = currentInvocation.cursorOffset - replacementStart;
    } else if (currentInvocation != null &&
        currentInvocation.mode == invocation.mode &&
        currentInvocation.tokenStart == invocation.tokenStart) {
      deleteCount =
          currentInvocation.cursorOffset - suggestion.replacementStart;
    }

    if (deleteCount < 0) {
      _hideShellCompletionPopup(resetPromptPrefix: false);
      return;
    }

    _hideShellCompletionPopup(resetPromptPrefix: false);
    for (var index = 0; index < deleteCount; index++) {
      _terminal.keyInput(TerminalKey.backspace);
    }
    final text = '${suggestion.replacement}${suggestion.commitSuffix}';
    if (text.isNotEmpty) {
      _terminal.textInput(text);
    }
    _handleTerminalUserInput();
    _terminalTextInputController.clearImeBuffer();
  }

  void _handleTerminalLinkTapDown(
    TapDownDetails tapDetails,
    CellOffset cellOffset,
  ) {
    _claimActiveMonkeyMuxClientFocus();
    _terminalTextInputController.suppressNextTouchKeyboardRequest();
  }

  void _queueTerminalScrollToBottom() {
    if (_isTerminalScrollToBottomQueued) {
      return;
    }

    _isTerminalScrollToBottomQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalScrollToBottomQueued = false;
      if (!mounted ||
          !_shouldFollowLiveOutput ||
          _isTerminalOutputFollowPaused ||
          !_terminalScrollController.hasClients) {
        return;
      }

      final position = _terminalScrollController.position;
      if (shouldFollowTerminalOutput(
        hasScrollClients: true,
        currentOffset: _terminalScrollController.offset,
        maxScrollExtent: position.maxScrollExtent,
      )) {
        return;
      }

      _terminalScrollController.jumpTo(position.maxScrollExtent);
    });
  }

  void _onSelectionChanged() {
    if (!mounted) {
      return;
    }

    final hasActiveSelection = _hasActiveSystemSelection;
    _syncTerminalLiveOutputAutoScroll();
    setState(() {});
    if (!hasActiveSelection &&
        _shouldFollowLiveOutput &&
        !_isTerminalOutputFollowPaused) {
      _queueTerminalScrollToBottom();
    }
  }

  Future<void> _loadHostAndConnect() async {
    if (!mounted) return;
    // Load host data first for theme
    final hostRepo = ref.read(hostRepositoryProvider);
    final presetService = ref.read(agentLaunchPresetServiceProvider);
    final cliPreferencesService = ref.read(
      hostCliLaunchPreferencesServiceProvider,
    );
    final host = await hostRepo.getById(widget.hostId);
    if (!mounted) return;
    _host = host;
    final presetState = await presetService.getPresetStateForHost(
      widget.hostId,
    );
    if (!mounted) return;
    _autoConnectAgentPreset = presetState.preset;
    _hasUnsupportedAutoConnectAgentPreset = presetState.isUnsupported;
    final cliLaunchPreferences = await cliPreferencesService
        .getPreferencesForHost(widget.hostId);
    if (!mounted) return;
    _startClisInYoloMode = cliLaunchPreferences.startInYoloMode;
    DiagnosticsLogService.instance.info(
      'terminal.screen',
      'host_loaded',
      fields: {
        'hostId': widget.hostId,
        'hasHost': _host != null,
        'hasAutoConnectCommand':
            _host?.autoConnectCommand?.trim().isNotEmpty ?? false,
        'hasTmuxAutoAttach': _host?.tmuxSessionName?.trim().isNotEmpty ?? false,
      },
    );
    await _loadTheme(reason: 'initial_load');
    if (!mounted) return;
    await _connect(preferredConnectionId: widget.connectionId);
  }

  Future<void> _loadTheme({
    bool forceRemoteRefresh = false,
    String reason = 'load_theme',
  }) async {
    if (!mounted) return;

    final brightness = _resolveTerminalThemeBrightness();
    _lastThemeDependencyBrightness = brightness;
    final themeService = ref.read(terminalThemeServiceProvider);
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final theme = await themeService.getThemeForHost(
      _host,
      brightness,
      allowHostOverride: monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      ),
    );

    if (!mounted) {
      return;
    }
    final didThemeChange = !_sameTerminalTheme(_currentTheme, theme);
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'loaded',
      fields: {
        'reason': reason,
        'connectionId': _connectionId,
        'forceRemoteRefresh': forceRemoteRefresh,
        'brightness': brightness.name,
        'didThemeChange': didThemeChange,
        'hasSessionOverride': _sessionThemeOverride != null,
      },
    );
    if (didThemeChange) {
      setState(() => _currentTheme = theme);
    } else {
      _currentTheme = theme;
    }
    _applyTerminalThemeToSession(
      theme,
      forceRemoteRefresh: forceRemoteRefresh,
      reason: reason,
    );
    if (_pendingTerminalThemeDependencyReload) {
      _scheduleTerminalThemeDependencyReload();
    }
  }

  Future<bool> _restoreSessionThemeOverride(
    SshSession session, {
    bool forceRemoteRefresh = false,
    String reason = 'restore_override',
  }) async {
    final brightness = _resolveTerminalThemeBrightness();
    final themeId = brightness == Brightness.dark
        ? session.terminalThemeDarkId
        : session.terminalThemeLightId;

    if (themeId == null) {
      if (mounted) {
        if (_sessionThemeOverride != null) {
          setState(() => _sessionThemeOverride = null);
        }
        _syncAppThemeOverrideFromSession(session);
      }
      if (forceRemoteRefresh) {
        await _loadTheme(
          forceRemoteRefresh: true,
          reason: '${reason}_fallback',
        );
        return true;
      }
      return false;
    }

    final themeService = ref.read(terminalThemeServiceProvider);
    final resolvedTheme = await themeService.getThemeById(themeId);
    if (!mounted) {
      return false;
    }
    if (resolvedTheme == null) {
      if (_sessionThemeOverride != null) {
        setState(() => _sessionThemeOverride = null);
      }
      return false;
    }
    if (!_sameTerminalTheme(_sessionThemeOverride, resolvedTheme)) {
      setState(() => _sessionThemeOverride = resolvedTheme);
    } else {
      _sessionThemeOverride = resolvedTheme;
    }
    _applyTerminalThemeToSession(
      resolvedTheme,
      session: session,
      forceRemoteRefresh: forceRemoteRefresh,
      reason: reason,
    );
    _syncAppThemeOverrideFromSession(session);
    return true;
  }

  Future<void> _connect({
    int? preferredConnectionId,
    bool forceNew = false,
    bool showProgressDialog = false,
  }) async {
    if (!mounted) return;

    // Clean up any previous connection state before reconnecting.
    await _doneSubscription?.cancel();
    _doneSubscription = null;
    await _shellCommandCompletedSubscription?.cancel();
    _shellCommandCompletedSubscription = null;
    await _shellStdoutSubscription?.cancel();
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;
    _hideShellCompletionPopup();
    _clearOwnedTerminalCallbacks();
    _shell = null;
    // Allow the build-path safety-net call to fire once for the new session.
    _lastBuildAppliedTheme = null;

    setState(() {
      _isConnecting = true;
      _connectionCancelled = false;
      _error = null;
      _connectionOpenedWorkingDirectory = null;
    });

    _sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    var shouldForceNew = forceNew;
    if (preferredConnectionId != null) {
      _connectionId = preferredConnectionId;
      final existingSession = _sessionsNotifier!.getSession(
        preferredConnectionId,
      );
      if (existingSession != null) {
        await _sessionsNotifier!.syncBackgroundStatus();
        await _openShell(existingSession);
        return;
      }
      shouldForceNew = true;
    }

    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;

    if (!mounted) return;
    final result = showProgressDialog && _host != null
        ? await connectToHostWithProgressDialog(
            context,
            ref,
            _host!,
            forceNew: shouldForceNew,
          )
        : await _sessionsNotifier!.connect(
            widget.hostId,
            forceNew: shouldForceNew,
            useHostThemeOverrides: monetizationState.allowsFeature(
              MonetizationFeature.hostSpecificThemes,
            ),
          );

    if (!mounted) return;

    if (!result.success || result.connectionId == null) {
      setState(() {
        _isConnecting = false;
        _connectionCancelled = result.cancelled;
        _error =
            result.error ??
            (result.cancelled ? 'Connection cancelled' : 'Connection failed');
      });
      return;
    }

    _connectionId = result.connectionId;
    final session = _sessionsNotifier!.getSession(_connectionId!);
    if (session == null) {
      setState(() {
        _isConnecting = false;
        _error = 'Session not found';
      });
      _syncTerminalWakeLock(SshConnectionState.disconnected);
      return;
    }

    if (_connectionCancelled) {
      // The user cancelled while the attempt was still warming up, before a
      // cancellation token existed. Drop the session instead of opening it.
      final establishedConnectionId = _connectionId;
      _connectionId = null;
      if (establishedConnectionId != null && !result.reusedConnection) {
        await _sessionsNotifier!.disconnect(establishedConnectionId);
      }
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _error = 'Connection cancelled';
      });
      _syncTerminalWakeLock(SshConnectionState.disconnected);
      return;
    }

    await _openShell(session);
  }

  Future<void> _openShell(SshSession session) async {
    bool stillOwnsSession() => mounted && identical(session, _activeSession());
    if (!stillOwnsSession()) return;

    _activeNativeAcpSessionKey = session.activeNativeAcpSessionKey;
    session.setTerminalParsingPaused(
      paused: _activeNativeAcpSessionKey != null,
    );

    try {
      // Reuse the session's persistent terminal if it exists (preserves
      // scrollback and screen buffer across screen navigations).
      final existingTerminal = session.terminal;
      final sessionTerminal = existingTerminal ?? session.getOrCreateTerminal();
      final sharedClipboardEnabled = await ref.read(
        sharedClipboardProvider.future,
      );
      if (!stillOwnsSession()) return;
      final sharedClipboardLocalReadEnabled = await ref.read(
        sharedClipboardLocalReadProvider.future,
      );
      if (!stillOwnsSession()) return;
      final existingMuxBackend = existingTerminal != null
          ? session.remoteMuxBackend
          : null;
      if (existingMuxBackend != null) {
        _activeMuxBackend = existingMuxBackend;
      }
      session
        ..clipboardSharingEnabled = sharedClipboardEnabled
        ..localClipboardReadEnabled =
            sharedClipboardEnabled && sharedClipboardLocalReadEnabled;
      _terminal.removeListener(_onTerminalStateChanged);
      _terminal = sessionTerminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _observeSessionMetadata(session);
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);
      if (existingTerminal != null) {
        final shell = await session.getShell();
        if (!stillOwnsSession()) return;
        _shell = shell;
        _wireTerminalCallbacks(session);
        _applyTerminalThemeToSession(
          _resolveEffectiveTerminalTheme(),
          session: session,
          reason: 'open_existing_terminal',
        );
        await _applySharedClipboardSetting(
          enabled: sharedClipboardEnabled,
          allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
          session: session,
          waitForInitialSync: false,
        );
        if (!stillOwnsSession()) return;
        await _restoreSessionThemeOverride(
          session,
          forceRemoteRefresh: true,
          reason: 'open_existing_restore_override',
        );
        if (!stillOwnsSession()) return;
        setState(() {
          _sessionFontSizeOverride = session.terminalFontSize;
          _isConnecting = false;
        });
        _syncTerminalWakeLock(SshConnectionState.connected);
        if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
          _refreshTerminalAfterMonkeyMuxWindowChange(session);
        } else {
          _scheduleTerminalSizeRefresh();
        }
        _restoreTerminalFocus(
          forceShowSystemKeyboard: widget.initiallyShowKeyboard,
        );
        _maybePasteStoreDemoImage();
        _scheduleAgentUpdateCheck(session, initialCheck: false);

        // Detect tmux on existing sessions too (may not have been detected
        // yet if the terminal was opened before tmux started).
        if (!_isTmuxActive) {
          unawaited(
            _detectTmux(
              session,
              skipDelay: true,
              isReopeningExistingTerminal: true,
            ),
          );
        }
        return;
      }

      _applyTerminalThemeToSession(
        _resolveEffectiveTerminalTheme(),
        session: session,
        reason: 'open_new_terminal',
      );
      final host = _host;
      final reserveMuxChromeBeforeActivation =
          host != null && _expectsPreparedMonkeyMuxOnInitialShell(host);
      final sessionFontSizeOverride = session.terminalFontSize;
      if (_reserveMuxChromeBeforeActivation !=
              reserveMuxChromeBeforeActivation ||
          _sessionFontSizeOverride != sessionFontSizeOverride) {
        setState(() {
          _reserveMuxChromeBeforeActivation = reserveMuxChromeBeforeActivation;
          _sessionFontSizeOverride = sessionFontSizeOverride;
        });
      }
      await _waitForInitialTerminalViewportLayout(
        refreshLayout: _reserveMuxChromeBeforeActivation,
      );
      if (!stillOwnsSession()) {
        return;
      }
      final initialAutoConnect = await _prepareNewShellInitialAutoConnect(
        session,
      );
      if (!stillOwnsSession()) return;
      final startupCommand =
          initialAutoConnect.command?.backend == RemoteMuxBackend.monkeyMux
          ? initialAutoConnect.command
          : null;
      if (startupCommand == null && _reserveMuxChromeBeforeActivation) {
        setState(() => _reserveMuxChromeBeforeActivation = false);
      }
      final handledInitialAutoConnect =
          initialAutoConnect.handled ||
          _suppressRemoteMuxDetectionConnectionId == session.connectionId;
      final viewportCellSize = _localTerminalViewportCellSize();

      final shell = await session.getShell(
        pty: SSHPtyConfig(
          width: viewportCellSize.columns,
          height: viewportCellSize.rows,
        ),
        requestPty:
            !(session.remoteIsWindows &&
                startupCommand?.backend == RemoteMuxBackend.monkeyMux),
        command: startupCommand?.command,
        returnToLoginShell: startupCommand != null,
      );
      if (!stillOwnsSession()) return;
      _shell = shell;
      DiagnosticsLogService.instance.info(
        'terminal',
        'shell_opened',
        fields: {
          'connectionId': session.connectionId,
          'reusedTerminal': false,
          'hasStartupCommand': startupCommand != null,
          if (startupCommand case final command?)
            'startupBackend': command.backend.storageValue,
        },
      );
      final pendingReplacement = _pendingMonkeyMuxServerReplacement;
      if (startupCommand?.backend == RemoteMuxBackend.monkeyMux &&
          pendingReplacement != null &&
          pendingReplacement.connectionId == session.connectionId &&
          pendingReplacement.sessionName == startupCommand?.sessionName) {
        _startMonkeyMuxServerReplacementRecovery(session, pendingReplacement);
      }

      _wireTerminalCallbacks(session);
      await _applySharedClipboardSetting(
        enabled: sharedClipboardEnabled,
        allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
        session: session,
        waitForInitialSync: false,
      );

      if (!stillOwnsSession()) return;

      await _restoreSessionThemeOverride(
        session,
        forceRemoteRefresh: true,
        reason: 'open_new_restore_override',
      );
      if (!stillOwnsSession()) return;
      setState(() {
        _sessionFontSizeOverride = session.terminalFontSize;
        _isConnecting = false;
      });
      _syncTerminalWakeLock(SshConnectionState.connected);
      if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
        _refreshTerminalAfterMonkeyMuxWindowChange(session);
        unawaited(prewarmAcpRemoteExecutables(session));
      } else {
        _scheduleTerminalSizeRefresh();
      }
      _restoreTerminalFocus(
        forceShowSystemKeyboard: widget.initiallyShowKeyboard,
      );
      _maybePasteStoreDemoImage();
      _scheduleAgentUpdateCheck(session);

      // Start port forwards
      await _startPortForwards(session);
      if (!stillOwnsSession()) return;
      if (!handledInitialAutoConnect) {
        await _runAutoConnectCommand(session);
        if (!stillOwnsSession()) return;
      }

      // Detect tmux after the auto-connect command has had time to start.
      // A small delay ensures tmux has initialized if the auto-connect
      // command launches a tmux session.
      final suppressRemoteMuxDetection =
          _suppressRemoteMuxDetectionConnectionId == session.connectionId;
      if (suppressRemoteMuxDetection) {
        _suppressRemoteMuxDetectionConnectionId = null;
      } else {
        unawaited(_detectTmux(session));
      }
    } on _MonkeyMuxReconnectException {
      _monkeyMuxReconnectSessionName = null;
      _monkeyMuxReconnectAttachPending = false;
      DiagnosticsLogService.instance.warning(
        'terminal',
        'monkeymux_reconnect_prepare_failed',
        fields: {'connectionId': session.connectionId},
      );
      if (!stillOwnsSession()) return;
      setState(() {
        _isConnecting = false;
        _error = 'Could not reconnect to the MonkeyMux session. Try again.';
      });
    } on Object catch (e) {
      DiagnosticsLogService.instance.error(
        'terminal',
        'shell_open_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': e.runtimeType,
        },
      );
      if (!stillOwnsSession()) return;
      setState(() {
        _isConnecting = false;
        _error = 'Failed to start shell. Try reconnecting.';
      });
    }
  }

  /// Wire terminal onOutput/onResize callbacks for this screen instance.
  void _wireTerminalCallbacks(SshSession session) {
    _clearOwnedTerminalCallbacks();

    // Listen for shell close events.
    _doneSubscription = session.shellDoneStream.listen((_) {
      DiagnosticsLogService.instance.warning(
        'terminal',
        'shell_done_stream',
        fields: {'connectionId': session.connectionId},
      );
      if (mounted) {
        _handleShellClosed();
      }
    });
    _shellCommandCompletedSubscription = session.shellCommandCompletedStream
        .listen((_) => unawaited(_handleShellCommandCompleted(session)));
    _shellStdoutSubscription = session.shellStdoutStream.listen(
      _schedulePromptOutputImeResetCheck,
      onError: (Object error, StackTrace stackTrace) {
        if (kDebugMode) {
          debugPrint('Terminal stdout stream error: $error');
          debugPrint('$stackTrace');
        }
        DiagnosticsLogService.instance.error(
          'terminal',
          'stdout_listener_error',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      },
    );

    void handleTerminalOutput(String data) {
      // Enter keystroke CRLF collapse lives in sendTerminalEnterInput so paste
      // and other producers of exact "\r\n" are not rewritten here.
      final output = normalizeTerminalOutputForRemoteShell(data);

      if (_shouldSuppressMonkeyMuxTerminalControlInput(output)) {
        DiagnosticsLogService.instance.debug(
          'terminal.input',
          'monkeymux_stale_control_input_suppressed',
          fields: {'connectionId': session.connectionId},
        );
        return;
      }
      _clearDetectedSensitiveKeyboardPromptAfterInput(output);
      _handleTerminalOutputForShellCompletion(output);
      try {
        session.writeToShell(output);
      } on Object catch (error) {
        DiagnosticsLogService.instance.warning(
          'terminal.input',
          'write_failed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        unawaited(
          _cleanupUnexpectedDisconnect(
            session.connectionId,
            message: 'Connection became unresponsive. Reconnect to continue.',
          ),
        );
      }
    }

    _terminalOutputHandler = handleTerminalOutput;
    _terminal.onOutput = handleTerminalOutput;

    void handleTerminalResize(
      int width,
      int height,
      int pixelWidth,
      int pixelHeight,
    ) {
      session.updateTerminalWindowMetrics(
        columns: width,
        rows: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );
      // Layout can change while the old shell is closed and its replacement
      // is still opening. Keep the metrics, but wait to resize the new shell.
      if (_isReopeningShell) {
        return;
      }
      try {
        session.resizeShell(width, height, pixelWidth, pixelHeight);
      } on Object catch (error) {
        DiagnosticsLogService.instance.warning(
          'terminal.resize',
          'resize_failed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        unawaited(
          _cleanupUnexpectedDisconnect(
            session.connectionId,
            message: 'Connection became unresponsive. Reconnect to continue.',
          ),
        );
        return;
      }
      if (!_suppressMonkeyMuxResizeSyncFromTerminalRefresh) {
        _monkeyMuxHostGridReconcileAttempts = 0;
        _monkeyMuxBlankPaneRecoveryAttempts = 0;
        if (session.monkeyMuxViewportClippingEnabled &&
            (_terminal.viewWidth != width || _terminal.viewHeight != height)) {
          // The shared grid disagrees with this viewport, so the duplicate-size
          // cache must not silence the correction.
          _lastMonkeyMuxResizeSync = null;
        }
        _scheduleMonkeyMuxResizeSync(session, columns: width, rows: height);
        if (!_isSettlingTerminalMetricsAfterAppResume) {
          _scheduleMonkeyMuxResizeRedrawFollowUp(session);
        }
      }
    }

    _terminalResizeHandler = handleTerminalResize;
    _terminal.onResize = handleTerminalResize;

    void handleTerminalHostResize(int width, int height) {
      if (session.remoteMuxBackend != RemoteMuxBackend.monkeyMux) {
        return;
      }
      if (!session.monkeyMuxViewportClippingEnabled) {
        session.monkeyMuxViewportClippingEnabled = true;
        DiagnosticsLogService.instance.debug(
          'monkeymux.viewport',
          'clipping_enabled',
          fields: {
            'connectionId': session.connectionId,
            'columns': width,
            'rows': height,
          },
        );
        if (mounted) {
          setState(() {});
        }
      }
      _reconcileMonkeyMuxHostGrid(session, columns: width, rows: height);
    }

    _terminalHostResizeHandler = handleTerminalHostResize;
    _terminal.onHostResize = handleTerminalHostResize;
    if (_terminal.hostResizeGeneration > 0) {
      handleTerminalHostResize(_terminal.viewWidth, _terminal.viewHeight);
    }
    _terminalWithOwnedCallbacks = _terminal;
  }

  Future<void> _handleShellCommandCompleted(SshSession session) async {
    if (!mounted ||
        _connectionId != session.connectionId ||
        !_isTmuxActive ||
        _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    final reconnectAttempt = _monkeyMuxReconnectAttachPending;
    final failedBeforeWindowState =
        shouldFallbackFromUnestablishedMonkeyMuxAttach(
          reconnectAttempt: reconnectAttempt,
          attachEstablished: _monkeyMuxAttachEstablished,
        );
    _monkeyMuxReconnectAttachPending = false;
    if (reconnectAttempt) {
      _monkeyMuxReconnectSessionName = null;
    } else if (failedBeforeWindowState) {
      _clearTmuxState();
    } else {
      _rememberMonkeyMuxReconnectTarget(session);
    }
    DiagnosticsLogService.instance.warning(
      'terminal',
      reconnectAttempt
          ? 'monkeymux_reconnect_attach_completed'
          : failedBeforeWindowState
          ? 'monkeymux_attach_failed_before_window_state'
          : 'monkeymux_attach_completed',
      fields: {'connectionId': session.connectionId},
    );
    setState(() {
      if (reconnectAttempt) {
        _clearTmuxState();
      }
      _isConnecting = false;
      _error = failedBeforeWindowState
          ? null
          : reconnectAttempt
          ? 'The MonkeyMux session is no longer available. Reconnect to start '
                'the configured session.'
          : 'MonkeyMux disconnected. Reconnect to continue.';
    });
    if (!failedBeforeWindowState) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    }

    try {
      final replacementShell = await session.getShell();
      if (mounted && _connectionId == session.connectionId) {
        _shell = replacementShell;
        if (failedBeforeWindowState) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'MonkeyMux could not start. Connected to a login shell instead.',
              ),
            ),
          );
          _restoreTerminalFocus(
            forceShowSystemKeyboard: widget.initiallyShowKeyboard,
          );
        }
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal',
        'monkeymux_login_fallback_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  void _clearOwnedTerminalCallbacks() {
    final terminal = _terminalWithOwnedCallbacks;
    final outputHandler = _terminalOutputHandler;
    if (terminal != null &&
        outputHandler != null &&
        identical(terminal.onOutput, outputHandler)) {
      terminal.onOutput = null;
    }
    _terminalOutputHandler = null;

    final resizeHandler = _terminalResizeHandler;
    if (terminal != null &&
        resizeHandler != null &&
        identical(terminal.onResize, resizeHandler)) {
      terminal.onResize = null;
    }
    _terminalResizeHandler = null;

    final hostResizeHandler = _terminalHostResizeHandler;
    if (terminal != null &&
        hostResizeHandler != null &&
        identical(terminal.onHostResize, hostResizeHandler)) {
      terminal.onHostResize = null;
    }
    _terminalHostResizeHandler = null;
    _terminalWithOwnedCallbacks = null;
  }

  void _scheduleTerminalSizeRefresh({
    bool forceDisplayRefresh = false,
    bool revealLatestOutput = false,
    bool suppressMonkeyMuxResizeSync = false,
    bool suppressAutoScroll = false,
  }) {
    _pendingTerminalSizeRefreshForcesDisplayRefresh =
        _pendingTerminalSizeRefreshForcesDisplayRefresh ||
        forceDisplayRefresh ||
        revealLatestOutput;
    _pendingTerminalSizeRefreshRevealsLatestOutput =
        _pendingTerminalSizeRefreshRevealsLatestOutput || revealLatestOutput;
    _pendingTerminalSizeRefreshSuppressesMonkeyMuxResizeSync =
        _pendingTerminalSizeRefreshSuppressesMonkeyMuxResizeSync ||
        suppressMonkeyMuxResizeSync;
    _pendingTerminalSizeRefreshSuppressesAutoScroll =
        _pendingTerminalSizeRefreshSuppressesAutoScroll || suppressAutoScroll;
    if (_isTerminalSizeRefreshQueued) {
      return;
    }
    _isTerminalSizeRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalSizeRefreshQueued = false;
      final forceDisplayRefresh =
          _pendingTerminalSizeRefreshForcesDisplayRefresh;
      final shouldRevealLatestOutput =
          _pendingTerminalSizeRefreshRevealsLatestOutput;
      final shouldSuppressMonkeyMuxResizeSync =
          _pendingTerminalSizeRefreshSuppressesMonkeyMuxResizeSync;
      final shouldSuppressAutoScroll =
          _pendingTerminalSizeRefreshSuppressesAutoScroll;
      _pendingTerminalSizeRefreshForcesDisplayRefresh = false;
      _pendingTerminalSizeRefreshRevealsLatestOutput = false;
      _pendingTerminalSizeRefreshSuppressesMonkeyMuxResizeSync = false;
      _pendingTerminalSizeRefreshSuppressesAutoScroll = false;
      if (!mounted) {
        return;
      }
      final revealLatestOutput =
          shouldRevealLatestOutput && !_isTerminalOutputFollowPaused;
      final terminalView = _terminalViewKey.currentState;
      _suppressMonkeyMuxResizeSyncFromTerminalRefresh =
          shouldSuppressMonkeyMuxResizeSync;
      _suppressTerminalAutoScrollFromTerminalRefresh = shouldSuppressAutoScroll;
      try {
        if (forceDisplayRefresh) {
          terminalView?.refreshTerminalDisplay(
            revealLatestOutput: revealLatestOutput,
          );
        } else {
          terminalView?.refreshTerminalSize();
        }
      } finally {
        _suppressMonkeyMuxResizeSyncFromTerminalRefresh = false;
        _suppressTerminalAutoScrollFromTerminalRefresh = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Re-asserts the local viewport when MonkeyMux publishes a smaller grid.
  ///
  /// Once viewport clipping is on, the terminal buffer is sized entirely by the
  /// server's private host-resize sequence while Flutter keeps painting its own
  /// viewport. If the published grid is smaller than the viewport, output is
  /// laid out into too few cells and the remainder renders blank, and nothing
  /// corrects it because the client never resizes its own buffer again. Rather
  /// than depending on every publish being perfectly ordered, push the real
  /// viewport back whenever the grid is short: the server answers with a
  /// matching grid, so the exchange settles instead of staying corrupted until
  /// the user happens to resize.
  ///
  /// A larger published grid is left alone; that is clipping doing its job for
  /// a bigger peer client.
  void _reconcileMonkeyMuxHostGrid(
    SshSession session, {
    required int columns,
    required int rows,
  }) {
    if (!mounted || _connectionId != session.connectionId) {
      return;
    }
    final viewport = _terminalViewKey.currentState?.viewportCellSize;
    if (viewport == null || viewport.columns <= 0 || viewport.rows <= 0) {
      return;
    }
    if (viewport.columns <= columns && viewport.rows <= rows) {
      _monkeyMuxHostGridReconcileAttempts = 0;
      return;
    }
    if (_monkeyMuxHostGridReconcileAttempts >=
        _monkeyMuxHostGridReconcileLimit) {
      return;
    }
    _monkeyMuxHostGridReconcileAttempts += 1;
    // The duplicate-size cache exists to suppress viewport spam, but here the
    // server has demonstrably diverged from this client, so the very same
    // dimensions must be allowed onto the wire again.
    _lastMonkeyMuxResizeSync = null;
    DiagnosticsLogService.instance.info(
      'monkeymux.viewport',
      'grid_reconcile',
      fields: {
        'connectionId': session.connectionId,
        'publishedColumns': columns,
        'publishedRows': rows,
        'viewportColumns': viewport.columns,
        'viewportRows': viewport.rows,
        'attempt': _monkeyMuxHostGridReconcileAttempts,
      },
    );
    _scheduleMonkeyMuxResizeSync(
      session,
      columns: viewport.columns,
      rows: viewport.rows,
    );
  }

  /// Whether the terminal is showing nothing at all.
  ///
  /// A MonkeyMux replay clears the screen and its scrollback before the pane's
  /// new content arrives, so an entirely empty buffer means that content never
  /// came.
  bool _monkeyMuxTerminalRendersNothing() {
    final lines = _terminal.buffer.lines;
    for (var row = 0; row < lines.length; row++) {
      if (lines[row].getTrimmedLength() != 0) {
        return false;
      }
    }
    return true;
  }

  /// Asks the server to repaint a pane that came up blank.
  ///
  /// For panes whose foreground app owns its own pixels, MonkeyMux clears the
  /// client and relies on that app repainting in response to a resize. When the
  /// app coalesces or ignores that resize the pane stays empty, and because the
  /// grid is already correct nothing else on either side has a reason to speak
  /// up: the blank screen is a stable state that only an unrelated real resize
  /// (opening the keyboard) escapes. Detecting emptiness gives the client the
  /// evidence it needs to ask for the frame it never received.
  void _recoverBlankMonkeyMuxPane(
    SshSession session, {
    required String reason,
  }) {
    if (!mounted || _connectionId != session.connectionId) {
      return;
    }
    if (_activeMuxBackend != RemoteMuxBackend.monkeyMux &&
        session.remoteMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    if (!_monkeyMuxTerminalRendersNothing()) {
      _monkeyMuxBlankPaneRecoveryAttempts = 0;
      return;
    }
    if (_monkeyMuxBlankPaneRecoveryAttempts >=
        _monkeyMuxBlankPaneRecoveryLimit) {
      return;
    }
    _monkeyMuxBlankPaneRecoveryAttempts += 1;
    DiagnosticsLogService.instance.info(
      'monkeymux.redraw',
      'blank_pane_recovery',
      fields: {
        'connectionId': session.connectionId,
        'reason': reason,
        'attempt': _monkeyMuxBlankPaneRecoveryAttempts,
      },
    );
    unawaited(
      _syncActiveMonkeyMuxTerminalSize(session, refreshVisibleTerminal: true),
    );
  }

  bool _isWindowsMonkeyMuxSession(SshSession? session) =>
      session != null &&
      session.remoteIsWindows &&
      (_activeMuxBackend == RemoteMuxBackend.monkeyMux ||
          session.remoteMuxBackend == RemoteMuxBackend.monkeyMux);

  void _refreshTerminalAfterWindowsMonkeyMuxResume() {
    _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
    _monkeyMuxResizeRedrawFollowUpTimer = null;
    _followNextLiveOutputWithoutScrolling();
    _scheduleTerminalSizeRefresh(
      forceDisplayRefresh: true,
      suppressMonkeyMuxResizeSync: true,
      suppressAutoScroll: true,
    );
  }

  void _beginAppResumeTerminalMetricsSettle() {
    _isSettlingTerminalMetricsAfterAppResume = true;
    _scheduleAppResumeTerminalMetricsSettleEnd();
  }

  void _scheduleAppResumeTerminalMetricsSettleEnd() {
    _appResumeTerminalMetricsSettleTimer?.cancel();
    _appResumeTerminalMetricsSettleTimer = Timer(
      _appResumeTerminalMetricsSettleDelay,
      () {
        _appResumeTerminalMetricsSettleTimer = null;
        _isSettlingTerminalMetricsAfterAppResume = false;
      },
    );
  }

  void _endAppResumeTerminalMetricsSettle() {
    _appResumeTerminalMetricsSettleTimer?.cancel();
    _appResumeTerminalMetricsSettleTimer = null;
    _isSettlingTerminalMetricsAfterAppResume = false;
  }

  void _refreshTerminalAfterMonkeyMuxWindowChange(SshSession session) {
    // A window switch, create, or reattach redraws the screen fresh, so any
    // image the client still lacks should be re-requested for the new view;
    // clear the per-visit request tracking (and cancel a pending debounce).
    _resetMissingImageRecoveryState();
    // The MonkeyMux helper owns the replay/redraw for attach, select, create,
    // and active-window close. A second app-triggered redraw here competes with
    // that replay and can expose old alternate-screen output as visible scroll.
    _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
    _monkeyMuxResizeRedrawFollowUpTimer = null;
    _followNextLiveOutputWithoutScrolling();
    _scheduleTerminalSizeRefresh(
      forceDisplayRefresh: true,
      suppressMonkeyMuxResizeSync: true,
      suppressAutoScroll: true,
    );
    // The helper owns the synthetic redraw for a window switch. Do not request
    // another remote redraw here: long agent transcripts can produce hundreds
    // of kilobytes per repaint. The settled callbacks below only relayout and
    // repaint the already-received local buffer.
    _scheduleMonkeyMuxSettledRedrawDisplayRefreshes(
      session,
      reason: 'window_change_replay',
    );
    final generation = _monkeyMuxRefreshAndResizeGeneration;
    _monkeyMuxWindowRefreshFollowUpTimer?.cancel();
    _monkeyMuxWindowRefreshFollowUpTimer = Timer(
      const Duration(milliseconds: 50),
      () {
        _monkeyMuxWindowRefreshFollowUpTimer = null;
        if (!mounted ||
            generation != _monkeyMuxRefreshAndResizeGeneration ||
            _isTerminalOutputFollowPaused ||
            _connectionId != session.connectionId) {
          return;
        }
        _followNextLiveOutputWithoutScrolling();
        _scheduleTerminalSizeRefresh(
          forceDisplayRefresh: true,
          suppressMonkeyMuxResizeSync: true,
          suppressAutoScroll: true,
        );
      },
    );
  }

  /// Debounces a demand-driven recovery of Kitty images the terminal references
  /// but does not hold.
  ///
  /// Fires from every terminal content change (window switch replay, reconnect
  /// replay, and an agent CLI scrolling its own view), coalescing bursts of
  /// output so the resolve scan and any control request run only once the screen
  /// settles.
  void _scheduleMissingImageRecoveryRequest() {
    if (_activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    if (_missingImageRecoveryInFlight) {
      _missingImageRecoveryRescanPending = true;
      return;
    }
    var delay = _missingImageRecoveryDebounce;
    final retryNotBefore = _missingImageRecoveryRetryNotBefore;
    if (retryNotBefore != null) {
      final remaining = retryNotBefore.difference(DateTime.now());
      if (remaining > delay) {
        delay = remaining;
      } else {
        _missingImageRecoveryRetryNotBefore = null;
      }
    }
    _missingImageRequestTimer?.cancel();
    _missingImageRequestTimer = Timer(delay, _requestMissingImagesNow);
  }

  void _requestMissingImagesNow() {
    _missingImageRequestTimer = null;
    if (!mounted || _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    if (_missingImageRecoveryInFlight) {
      _missingImageRecoveryRescanPending = true;
      return;
    }
    final unresolved = _terminal.unresolvedPlaceholderImageIds();
    if (unresolved.isEmpty) {
      _missingImageRecoveryRetryCount = 0;
      _missingImageRecoveryRetryNotBefore = null;
      return;
    }
    final toRequest = <int>[
      for (final id in unresolved)
        if (!_requestedMissingImageIds.contains(id)) id,
    ];
    if (toRequest.isEmpty) {
      return;
    }
    final session = _activeSession();
    if (session == null) {
      return;
    }
    final sessionName = _activeMonkeyMuxSessionName(session);
    if (sessionName == null) {
      return;
    }
    _requestedMissingImageIds.addAll(toRequest);
    final recoveryGeneration = _missingImageRecoveryGeneration;
    _missingImageRecoveryInFlight = true;
    _missingImageRecoveryRescanPending = false;
    DiagnosticsLogService.instance.debug(
      'terminal.graphics',
      'request_missing_images',
      fields: {
        'connectionId': session.connectionId,
        'requested': toRequest.length,
        'unresolved': unresolved.length,
      },
    );
    unawaited(
      _recoverMissingImages(
        session,
        sessionName,
        toRequest.toSet(),
        recoveryGeneration,
      ),
    );
  }

  Future<void> _recoverMissingImages(
    SshSession session,
    String sessionName,
    Set<int> requestedIds,
    int recoveryGeneration,
  ) async {
    try {
      final result = await _monkeyMuxService.requestImages(
        session,
        sessionName,
        requestedIds,
      );
      if (!mounted ||
          recoveryGeneration != _missingImageRecoveryGeneration ||
          _connectionId != session.connectionId ||
          _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
        return;
      }
      final retryIds = result.retryableUnserved(requestedIds);
      DiagnosticsLogService.instance.debug(
        'terminal.graphics',
        'request_missing_images_complete',
        fields: {
          'connectionId': session.connectionId,
          'requested': requestedIds.length,
          'served': result.served.length,
          'unserved': requestedIds.length - result.served.length,
          'retryable': result.retryableFailure,
        },
      );
      if (!result.retryableFailure || retryIds.isEmpty) {
        _missingImageRecoveryRetryCount = 0;
        _missingImageRecoveryRetryNotBefore = null;
        return;
      }
      if (_missingImageRecoveryRetryCount >= _missingImageRecoveryRetryLimit) {
        DiagnosticsLogService.instance.warning(
          'terminal.graphics',
          'request_missing_images_retry_exhausted',
          fields: {
            'connectionId': session.connectionId,
            'count': retryIds.length,
          },
        );
        return;
      }
      _missingImageRecoveryRetryCount++;
      _requestedMissingImageIds.removeAll(retryIds);
      _missingImageRecoveryRetryNotBefore = DateTime.now().add(
        _missingImageRecoveryRetryDelay * _missingImageRecoveryRetryCount,
      );
      DiagnosticsLogService.instance.debug(
        'terminal.graphics',
        'request_missing_images_retry_scheduled',
        fields: {
          'connectionId': session.connectionId,
          'count': retryIds.length,
          'attempt': _missingImageRecoveryRetryCount,
        },
      );
      _missingImageRecoveryRescanPending = true;
    } finally {
      _missingImageRecoveryInFlight = false;
      if (mounted && _missingImageRecoveryRescanPending) {
        _missingImageRecoveryRescanPending = false;
        _scheduleMissingImageRecoveryRequest();
      }
    }
  }

  void _resetMissingImageRecoveryState() {
    _missingImageRequestTimer?.cancel();
    _missingImageRequestTimer = null;
    _requestedMissingImageIds.clear();
    _missingImageRecoveryRetryNotBefore = null;
    _missingImageRecoveryRetryCount = 0;
    _missingImageRecoveryRescanPending = _missingImageRecoveryInFlight;
    _missingImageRecoveryGeneration++;
  }

  /// Throttles the remote MonkeyMux resize so pinch-zoom follows in real time
  /// without flooding the SSH connection.
  ///
  /// The local view scales every frame regardless; this only governs how often
  /// the remote is told the new size. The first change is sent immediately, then
  /// at most one resize is in flight at a time and no more than the cadence for
  /// the active transport. The latest requested [columns]/[rows] are remembered
  /// and sent as soon as the in-flight send and cooldown clear, so the remote
  /// always ends up matching the settled gesture.
  void _scheduleMonkeyMuxResizeSync(
    SshSession session, {
    required int columns,
    required int rows,
  }) {
    final isMonkeyMuxSession =
        _activeMuxBackend == RemoteMuxBackend.monkeyMux ||
        session.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
    if (!isMonkeyMuxSession) {
      return;
    }
    final sessionName = _activeMonkeyMuxSessionName(session);
    if (sessionName == null) {
      return;
    }
    _monkeyMuxResizeSyncColumns = columns;
    _monkeyMuxResizeSyncRows = rows;
    if (_monkeyMuxService.hasLiveControlChannel(session, sessionName)) {
      // The persistent MonkeyMux control channel is already up, so this update
      // does not allocate a short-lived SSH exec channel. Keep it smooth (~30fps)
      // but still coalesce to the latest size so remote TUIs don't receive a
      // stale backlog after the gesture has moved on.
      if (_monkeyMuxResizeSyncInFlight) {
        _monkeyMuxResizeSyncPending = true;
        return;
      }
      if (_monkeyMuxResizeSyncThrottled) {
        _monkeyMuxResizeSyncPending = true;
        return;
      }
      _sendMonkeyMuxResizeSyncNow(
        session,
        minGap: _monkeyMuxLiveResizeSyncMinGap,
      );
      return;
    }
    // A send is on the wire or we're inside the throttle window: just record
    // that a newer size is wanted; it goes out when the guards clear.
    if (_monkeyMuxResizeSyncInFlight || _monkeyMuxResizeSyncThrottled) {
      _monkeyMuxResizeSyncPending = true;
      return;
    }
    _sendMonkeyMuxResizeSyncNow(
      session,
      minGap: _monkeyMuxFallbackResizeSyncMinGap,
    );
  }

  String? _activeMonkeyMuxSessionName(SshSession session) {
    final sessionName = _tmuxSessionName ?? session.remoteMuxSessionName;
    return sessionName == null || sessionName.trim().isEmpty
        ? null
        : sessionName;
  }

  void _sendMonkeyMuxResizeSyncNow(
    SshSession session, {
    required Duration minGap,
  }) {
    final columns = _monkeyMuxResizeSyncColumns;
    final rows = _monkeyMuxResizeSyncRows;
    if (columns == null || rows == null) {
      return;
    }
    final connectionId = session.connectionId;
    final generation = _monkeyMuxRefreshAndResizeGeneration;
    _monkeyMuxResizeSyncInFlight = true;
    _monkeyMuxResizeSyncThrottled = true;
    _monkeyMuxResizeSyncCooldownTimer?.cancel();
    _monkeyMuxResizeSyncCooldownTimer = Timer(minGap, () {
      _monkeyMuxResizeSyncCooldownTimer = null;
      if (generation != _monkeyMuxRefreshAndResizeGeneration) {
        return;
      }
      _monkeyMuxResizeSyncThrottled = false;
      _maybeSendPendingMonkeyMuxResizeSync(session, connectionId);
    });
    unawaited(() async {
      try {
        await _syncActiveMonkeyMuxTerminalSize(
          session,
          columns: columns,
          rows: rows,
        );
      } finally {
        if (generation == _monkeyMuxRefreshAndResizeGeneration) {
          _monkeyMuxResizeSyncInFlight = false;
          _maybeSendPendingMonkeyMuxResizeSync(session, connectionId);
        }
      }
    }());
  }

  void _maybeSendPendingMonkeyMuxResizeSync(
    SshSession session,
    int connectionId,
  ) {
    if (!mounted ||
        _connectionId != connectionId ||
        !_monkeyMuxResizeSyncPending ||
        _monkeyMuxResizeSyncInFlight ||
        _monkeyMuxResizeSyncThrottled) {
      return;
    }
    _monkeyMuxResizeSyncPending = false;
    final columns = _monkeyMuxResizeSyncColumns;
    final rows = _monkeyMuxResizeSyncRows;
    if (columns == null || rows == null) {
      return;
    }
    _scheduleMonkeyMuxResizeSync(session, columns: columns, rows: rows);
  }

  void _scheduleMonkeyMuxResizeRedrawFollowUp(SshSession session) {
    final isMonkeyMuxSession =
        _activeMuxBackend == RemoteMuxBackend.monkeyMux ||
        session.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
    if (!isMonkeyMuxSession) {
      return;
    }
    if (_wasBackgrounded || _isSettlingTerminalMetricsAfterAppResume) {
      _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
      _monkeyMuxResizeRedrawFollowUpTimer = null;
      return;
    }
    final connectionId = session.connectionId;
    final generation = _monkeyMuxRefreshAndResizeGeneration;
    final outputSequence = session.shellOutputChunkSequence;
    _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
    _monkeyMuxResizeRedrawFollowUpTimer = Timer(
      _monkeyMuxResizeRedrawFollowUpDelay,
      () {
        _monkeyMuxResizeRedrawFollowUpTimer = null;
        if (!mounted ||
            generation != _monkeyMuxRefreshAndResizeGeneration ||
            _connectionId != connectionId) {
          return;
        }
        if (session.shellOutputChunkSequence != outputSequence) {
          // The resize reached the foreground app and it repainted. Forcing
          // another redraw would make it lay out and re-emit its whole frame a
          // second time for nothing, which on a long agent transcript is
          // hundreds of kilobytes over the wire.
          return;
        }
        unawaited(
          _syncActiveMonkeyMuxTerminalSize(
            session,
            refreshVisibleTerminal: true,
          ),
        );
      },
    );
  }

  void _scheduleMonkeyMuxPostRedrawDisplayRefresh(int connectionId) {
    final generation = _monkeyMuxRefreshAndResizeGeneration;
    _monkeyMuxPostRedrawDisplayRefreshTimer?.cancel();
    _monkeyMuxPostRedrawDisplayRefreshTimer = Timer(
      _monkeyMuxPostRedrawDisplayRefreshDelay,
      () {
        _monkeyMuxPostRedrawDisplayRefreshTimer = null;
        if (!mounted ||
            generation != _monkeyMuxRefreshAndResizeGeneration ||
            _connectionId != connectionId) {
          return;
        }
        _refreshTerminalDisplayAfterMonkeyMuxRedraw(
          connectionId: connectionId,
          reason: 'post_redraw',
        );
      },
    );
  }

  void _scheduleMonkeyMuxSettledRedrawDisplayRefreshes(
    SshSession session, {
    required String reason,
  }) {
    final isMonkeyMuxSession =
        _activeMuxBackend == RemoteMuxBackend.monkeyMux ||
        session.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
    if (!isMonkeyMuxSession) {
      return;
    }
    _cancelMonkeyMuxSettledRedrawDisplayRefreshes();
    final connectionId = session.connectionId;
    final generation = ++_monkeyMuxSettledRedrawDisplayRefreshGeneration;
    for (final delay in _monkeyMuxSettledRedrawDisplayRefreshDelays) {
      late final Timer timer;
      timer = Timer(delay, () {
        _monkeyMuxSettledRedrawDisplayRefreshTimers.remove(timer);
        if (!mounted ||
            _connectionId != connectionId ||
            generation != _monkeyMuxSettledRedrawDisplayRefreshGeneration) {
          return;
        }
        _refreshTerminalDisplayAfterMonkeyMuxRedraw(
          connectionId: connectionId,
          reason: reason,
          delay: delay,
        );
        _recoverBlankMonkeyMuxPane(session, reason: reason);
      });
      _monkeyMuxSettledRedrawDisplayRefreshTimers.add(timer);
    }
  }

  void _cancelMonkeyMuxSettledRedrawDisplayRefreshes() {
    _monkeyMuxSettledRedrawDisplayRefreshGeneration += 1;
    for (final timer in _monkeyMuxSettledRedrawDisplayRefreshTimers) {
      timer.cancel();
    }
    _monkeyMuxSettledRedrawDisplayRefreshTimers.clear();
  }

  void _cancelMonkeyMuxRefreshAndResizeState() {
    _monkeyMuxRefreshAndResizeGeneration += 1;
    _monkeyMuxWindowRefreshFollowUpTimer?.cancel();
    _monkeyMuxWindowRefreshFollowUpTimer = null;
    _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
    _monkeyMuxResizeRedrawFollowUpTimer = null;
    _endAppResumeTerminalMetricsSettle();
    _monkeyMuxResizeSyncCooldownTimer?.cancel();
    _monkeyMuxResizeSyncCooldownTimer = null;
    _monkeyMuxResizeSyncInFlight = false;
    _monkeyMuxResizeSyncThrottled = false;
    _monkeyMuxResizeSyncPending = false;
    _monkeyMuxResizeSyncColumns = null;
    _monkeyMuxResizeSyncRows = null;
    _monkeyMuxHostGridReconcileAttempts = 0;
    _monkeyMuxBlankPaneRecoveryAttempts = 0;
    _monkeyMuxPostRedrawDisplayRefreshTimer?.cancel();
    _monkeyMuxPostRedrawDisplayRefreshTimer = null;
    _cancelMonkeyMuxSettledRedrawDisplayRefreshes();
    _pendingMonkeyMuxResizeSyncs.clear();
    _lastMonkeyMuxResizeSync = null;
    _monkeyMuxForcedThemeRedrawPending = false;
  }

  void _refreshTerminalDisplayAfterMonkeyMuxRedraw({
    required int connectionId,
    required String reason,
    Duration? delay,
  }) {
    if (!mounted || _connectionId != connectionId) {
      return;
    }
    DiagnosticsLogService.instance.debug(
      'monkeymux.redraw',
      'display_refresh',
      fields: {
        'connectionId': connectionId,
        'reason': reason,
        if (delay != null) 'delayMs': delay.inMilliseconds,
        'revealLatestOutput': false,
      },
    );
    _suppressMonkeyMuxResizeSyncFromTerminalRefresh = true;
    _suppressTerminalAutoScrollFromTerminalRefresh = true;
    try {
      _terminalViewKey.currentState?.refreshTerminalDisplay();
    } finally {
      _suppressMonkeyMuxResizeSyncFromTerminalRefresh = false;
      _suppressTerminalAutoScrollFromTerminalRefresh = false;
    }
    _scheduleTerminalSizeRefresh(
      forceDisplayRefresh: true,
      suppressMonkeyMuxResizeSync: true,
      suppressAutoScroll: true,
    );
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _claimActiveMonkeyMuxClientFocus() {
    final session = _activeSession();
    if (session == null || _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return;
    }
    final sessionName = _activeMonkeyMuxSessionName(session);
    final viewportCellSize = _localTerminalViewportCellSize();
    final columns = viewportCellSize.columns;
    final rows = viewportCellSize.rows;
    if (sessionName == null || columns <= 0 || rows <= 0) {
      return;
    }
    final connectionId = session.connectionId;
    unawaited(
      _monkeyMuxService
          .focusClient(session, sessionName, columns: columns, rows: rows)
          .then((focusChanged) {
            if (!mounted ||
                !focusChanged ||
                _connectionId != connectionId ||
                _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
              return;
            }
            _refreshTerminalAfterMonkeyMuxWindowChange(session);
          }),
    );
  }

  ({int columns, int rows}) _localTerminalViewportCellSize() {
    final viewportCellSize = _terminalViewKey.currentState?.viewportCellSize;
    if (viewportCellSize != null &&
        viewportCellSize.columns > 0 &&
        viewportCellSize.rows > 0) {
      return viewportCellSize;
    }
    final layoutSize = _terminalViewportLayoutSize;
    if (layoutSize != null && mounted) {
      final mediaQuery = MediaQuery.of(context);
      final viewportPadding = resolveTerminalViewportPadding(mediaQuery);
      final globalFontSize = ref.read(fontSizeNotifierProvider);
      final fontSize = resolveTerminalFontSize(
        globalFontSize: globalFontSize,
        sessionFontSize: _sessionFontSizeOverride,
        pinchFontSize: _pinchFontSize,
      );
      final fontFamily =
          _host?.terminalFontFamily ??
          ref.read(fontFamilyNotifierProvider) ??
          'monospace';
      final painter = MonkeyTerminalPainter(
        theme: _resolveEffectiveTerminalTheme().toXtermTheme(),
        textStyle: TerminalStyle.fromTextStyle(
          _getTerminalFlutterTextStyle(fontFamily, fontSize),
        ),
        textScaler: mediaQuery.textScaler,
      );
      final availableWidth =
          layoutSize.width -
          viewportPadding.horizontal -
          _terminalViewportReservedWidth;
      final availableHeight =
          layoutSize.height -
          viewportPadding.vertical -
          _terminalViewportReservedBottomPadding;
      final columns = availableWidth ~/ painter.cellSize.width;
      final rows = availableHeight ~/ painter.cellSize.height;
      if (columns > 0 && rows > 0) {
        return (columns: columns, rows: rows);
      }
    }
    return (columns: _terminal.viewWidth, rows: _terminal.viewHeight);
  }

  Future<void> _waitForInitialTerminalViewportLayout({
    bool refreshLayout = false,
  }) async {
    if (!refreshLayout &&
        (_terminalViewKey.currentState?.viewportCellSize != null ||
            _terminalViewportLayoutSize != null)) {
      return;
    }
    for (var attempt = 0; attempt < 3 && mounted; attempt += 1) {
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
      if (_terminalViewKey.currentState?.viewportCellSize != null ||
          _terminalViewportLayoutSize != null) {
        return;
      }
    }
  }

  bool _expectsPreparedMonkeyMuxOnInitialShell(Host host) {
    if (_monkeyMuxReconnectSessionName != null) {
      return true;
    }
    final sessionName = _initialTmuxSessionName ?? host.tmuxSessionName;
    if (sessionName != null && sessionName.trim().isNotEmpty) {
      return _configuredRemoteMuxBackend(host) != RemoteMuxBackend.tmux;
    }
    return _autoConnectAgentPreset?.usesMonkeyMuxSession ?? false;
  }

  Future<void> _syncActiveMonkeyMuxTerminalSize(
    SshSession session, {
    int? columns,
    int? rows,
    bool refreshVisibleTerminal = false,
  }) async {
    final generation = _monkeyMuxRefreshAndResizeGeneration;
    final isMonkeyMuxSession =
        _activeMuxBackend == RemoteMuxBackend.monkeyMux ||
        session.remoteMuxBackend == RemoteMuxBackend.monkeyMux;
    if (!isMonkeyMuxSession) {
      return;
    }
    final sessionName = _tmuxSessionName ?? session.remoteMuxSessionName;
    if (sessionName == null || sessionName.trim().isEmpty) {
      return;
    }

    if (refreshVisibleTerminal) {
      _suppressMonkeyMuxResizeSyncFromTerminalRefresh = true;
      _suppressTerminalAutoScrollFromTerminalRefresh = true;
      try {
        _terminalViewKey.currentState?.refreshTerminalSize(
          flushKeyboardResize: true,
        );
      } finally {
        _suppressMonkeyMuxResizeSyncFromTerminalRefresh = false;
        _suppressTerminalAutoScrollFromTerminalRefresh = false;
      }
    }

    final viewportCellSize = _localTerminalViewportCellSize();
    final terminalColumns = columns ?? viewportCellSize.columns;
    final terminalRows = rows ?? viewportCellSize.rows;
    if (terminalColumns <= 0 || terminalRows <= 0) {
      return;
    }

    final resizeKey = (
      connectionId: session.connectionId,
      sessionName: sessionName,
      columns: terminalColumns,
      rows: terminalRows,
    );
    final isDuplicateSize =
        _lastMonkeyMuxResizeSync == resizeKey ||
        _pendingMonkeyMuxResizeSyncs.contains(resizeKey);
    if (!refreshVisibleTerminal && isDuplicateSize) {
      return;
    }
    if (!refreshVisibleTerminal) {
      _pendingMonkeyMuxResizeSyncs.add(resizeKey);
    }

    try {
      await _monkeyMuxService.resizeTerminal(
        session,
        sessionName,
        columns: terminalColumns,
        rows: terminalRows,
        redraw: refreshVisibleTerminal,
      );
      DiagnosticsLogService.instance.debug(
        'monkeymux.resize',
        'sync_complete',
        fields: {
          'connectionId': session.connectionId,
          'columns': terminalColumns,
          'rows': terminalRows,
          'redraw': refreshVisibleTerminal,
          'refreshedVisibleTerminal': refreshVisibleTerminal,
        },
      );
      if (generation == _monkeyMuxRefreshAndResizeGeneration) {
        _lastMonkeyMuxResizeSync = resizeKey;
      }
      if (refreshVisibleTerminal) {
        if (generation != _monkeyMuxRefreshAndResizeGeneration) {
          return;
        }
        _scheduleMonkeyMuxPostRedrawDisplayRefresh(session.connectionId);
        _scheduleMonkeyMuxSettledRedrawDisplayRefreshes(
          session,
          reason: 'resize_redraw',
        );
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'monkeymux.resize',
        'sync_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    } finally {
      if (!refreshVisibleTerminal) {
        _pendingMonkeyMuxResizeSyncs.remove(resizeKey);
      }
    }
  }

  SshConnectionState _readCurrentConnectionState() {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return SshConnectionState.disconnected;
    }
    if (ref.read(activeSessionsProvider.notifier).getSession(connectionId) ==
        null) {
      return SshConnectionState.disconnected;
    }
    return ref.read(activeSessionsProvider)[connectionId] ??
        SshConnectionState.disconnected;
  }

  void _syncTerminalWakeLock([SshConnectionState? connectionState]) {
    _sessionController.syncWakeLock(connectionState);
  }

  void _clearDetectedSensitiveKeyboardPromptAfterInput(String output) {
    if (!_detectedSensitiveKeyboardPrompt ||
        (!output.contains('\r') && !output.contains('\n'))) {
      return;
    }

    if (!mounted) {
      _detectedSensitiveKeyboardPrompt = false;
      return;
    }

    setState(() => _detectedSensitiveKeyboardPrompt = false);
  }

  void _schedulePromptOutputImeResetCheck(String data) {
    if (!_isMobilePlatform || !_shellOutputLooksLikePromptReturn(data)) {
      return;
    }
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = Timer(_promptOutputImeResetDebounce, () {
      _promptOutputImeResetTimer = null;
      if (!mounted) {
        return;
      }
      _terminalTextInputController.handleExternalTerminalOutput();
    });
  }

  bool _shellOutputLooksLikePromptReturn(String data) {
    final sanitizedData = _stripTerminalPromptEscapeSequences(data);
    if (sanitizedData.isEmpty) {
      return false;
    }

    var index = sanitizedData.length - 1;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return false;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        break;
      }
      index--;
    }

    if (index < 0) {
      return false;
    }

    var visibleCodeUnitCount = 0;
    while (index >= 0) {
      final codeUnit = sanitizedData.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        break;
      }
      if (!_isPromptReturnWhitespaceCodeUnit(codeUnit)) {
        visibleCodeUnitCount++;
        if (visibleCodeUnitCount > 4) {
          return false;
        }
        if (_isPromptReturnAsciiLetterOrDigit(codeUnit)) {
          return false;
        }
      }
      index--;
    }

    return visibleCodeUnitCount > 0;
  }

  /// Starts auto-start port forwards for this host.
  Future<void> _startPortForwards(SshSession session) async {
    final portForwardRepo = ref.read(portForwardRepositoryProvider);
    final forwards = await portForwardRepo.getByHostId(widget.hostId);

    final autoStartForwards = forwards.where((f) => f.autoStart).toList();
    if (autoStartForwards.isEmpty) return;

    var startedCount = 0;
    final failedNames = <String>[];
    for (final forward in autoStartForwards) {
      final result = await activatePortForwardOnConnectedSession(
        sessions: ref.read(activeSessionsProvider.notifier),
        portForward: forward,
        preferredConnectionId: session.connectionId,
      );
      switch (result.status) {
        case PortForwardActivationStatus.started:
          startedCount++;
        case PortForwardActivationStatus.failed:
          failedNames.add(forward.name);
        case PortForwardActivationStatus.alreadyActive:
        case PortForwardActivationStatus.noConnectedSession:
        case PortForwardActivationStatus.superseded:
          break;
      }
    }

    if (mounted) {
      if (failedNames.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Started $startedCount forward(s), '
              'failed: ${failedNames.join(', ')}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      } else if (startedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Started $startedCount port forward(s)'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<({_PreparedRemoteMuxCommand? command, bool handled})>
  _prepareNewShellInitialAutoConnect(SshSession session) async {
    final host = _host;
    if (host == null) {
      return (command: null, handled: false);
    }
    if (isAppReviewDemoHost(host)) {
      final sessionName =
          _initialTmuxSessionName ?? host.tmuxSessionName ?? 'review-workspace';
      _applyPreparedRemoteMuxCommand(session, (
        backend: RemoteMuxBackend.monkeyMux,
        command: 'app-review-demo-monkeymux',
        sessionName: sessionName,
        tool: null,
      ));
      _suppressRemoteMuxDetectionConnectionId = session.connectionId;
      return (command: null, handled: true);
    }

    final reconnectSessionName = _monkeyMuxReconnectSessionName;
    if (reconnectSessionName != null) {
      final attachCommand = await _prepareRemoteMuxAttachCommand(
        session,
        host,
        reconnectSessionName,
        preferredBackend: RemoteMuxBackend.monkeyMux,
        existingOnly: true,
      );
      if (attachCommand == null) {
        throw const _MonkeyMuxReconnectException();
      }
      _monkeyMuxReconnectAttachPending = true;
      DiagnosticsLogService.instance.info(
        'terminal',
        'monkeymux_reconnect_target_used',
        fields: {'connectionId': session.connectionId},
      );
      _applyPreparedRemoteMuxCommand(session, attachCommand);
      return (command: attachCommand, handled: true);
    }

    final tmuxSession = _initialTmuxSessionName ?? host.tmuxSessionName;
    if (tmuxSession != null && tmuxSession.isNotEmpty) {
      if (_configuredRemoteMuxBackend(host) == RemoteMuxBackend.tmux) {
        return (command: null, handled: false);
      }
      final attachCommand = await _prepareRemoteMuxAttachCommand(
        session,
        host,
        tmuxSession,
      );
      if (attachCommand == null) {
        _suppressRemoteMuxDetectionConnectionId = session.connectionId;
        return (command: null, handled: true);
      }
      _applyPreparedRemoteMuxCommand(session, attachCommand);
      return (command: attachCommand, handled: true);
    }

    final agentPreset = _autoConnectAgentPreset;
    if (agentPreset == null || !agentPreset.usesMonkeyMuxSession) {
      return (command: null, handled: false);
    }
    final command = await _prepareMonkeyMuxAgentLaunchCommand(
      session,
      host,
      agentPreset,
    );
    if (command == null) {
      _suppressRemoteMuxDetectionConnectionId = session.connectionId;
      return (command: null, handled: true);
    }
    _applyPreparedRemoteMuxCommand(session, command);
    return (command: command, handled: true);
  }

  Future<void> _runAutoConnectCommand(SshSession session) async {
    final host = _host;
    final shell = _shell;
    if (host == null || shell == null) {
      return;
    }

    // Structured tmux attach is a first-class connection mode, not a generic
    // automation command. Run it even when Pro-only auto-connect automation is
    // unavailable so tmux-native navigation remains accessible.
    final tmuxSession = _initialTmuxSessionName ?? host.tmuxSessionName;
    if (tmuxSession != null && tmuxSession.isNotEmpty) {
      final attachCommand = await _prepareRemoteMuxAttachCommand(
        session,
        host,
        tmuxSession,
      );
      if (attachCommand == null) return;
      _applyPreparedRemoteMuxCommand(session, attachCommand);
      if (!mounted ||
          _connectionId != session.connectionId ||
          !identical(_shell, shell)) {
        return;
      }
      shell.write(
        utf8.encode(formatAutoConnectCommandForShell(attachCommand.command)),
      );
      return;
    }

    final agentPreset = _autoConnectAgentPreset;
    if (agentPreset != null && agentPreset.usesMonkeyMuxSession) {
      await _runMonkeyMuxAgentLaunchCommand(session, host, agentPreset, shell);
      return;
    }

    final resolvedStoredCommand = _resolveStoredAutoConnectCommand(host);
    final mode = resolveAutoConnectCommandMode(
      command: resolvedStoredCommand,
      snippetId: host.autoConnectSnippetId,
    );
    if (mode == AutoConnectCommandMode.none) {
      return;
    }

    final hasAccess = await ref
        .read(monetizationServiceProvider)
        .canUseFeature(MonetizationFeature.autoConnectAutomation);
    if (!hasAccess) {
      if (mounted) {
        final bottomMargin = upgradeSnackBarBottomMargin(
          MediaQuery.of(context),
          showKeyboardToolbar: _showKeyboardToolbar,
          keyboardToolbarHeight: resolveKeyboardToolbarHeight(
            MediaQuery.of(context),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
            content: const Text(
              'This auto-connect workflow needs MonkeySSH Pro to run.',
            ),
            action: SnackBarAction(
              label: 'Upgrade',
              onPressed: () => context.pushNamed(
                Routes.upgrade,
                queryParameters: <String, String>{
                  'feature': MonetizationFeature.autoConnectAutomation.name,
                  'action': 'Run this auto-connect workflow',
                  'outcome':
                      'Unlock Pro to run saved commands or snippets '
                      'automatically when a terminal opens.',
                },
              ),
            ),
          ),
        );
      }
      return;
    }

    String? snippetCommand;
    int? resolvedSnippetId;
    final snippetId = host.autoConnectSnippetId;
    if (snippetId != null) {
      final snippetRepo = ref.read(snippetRepositoryProvider);
      final snippet = await snippetRepo.getById(snippetId);
      if (snippet == null) {
        if (kDebugMode) {
          debugPrint(
            'Auto-connect snippet $snippetId is unavailable; '
            'using cached command.',
          );
        }
      } else {
        snippetCommand = snippet.command;
        resolvedSnippetId = snippet.id;
      }
    }

    final command = resolveAutoConnectCommandText(
      mode: mode,
      storedCommand: resolvedStoredCommand,
      snippetCommand: snippetCommand,
    );
    if (command == null) {
      return;
    }

    final review = assessAutoConnectCommandExecution(
      command,
      importedNeedsReview: host.autoConnectRequiresConfirmation,
    );
    if (review.requiresReview &&
        !await _reviewImportedAutoConnectCommand(review, host)) {
      return;
    }

    shell.write(utf8.encode(formatAutoConnectCommandForShell(command)));
    if (resolvedSnippetId != null) {
      unawaited(
        ref.read(snippetRepositoryProvider).incrementUsage(resolvedSnippetId),
      );
    }
  }

  String? get _initialTmuxSessionName {
    final sessionName = widget.initialTmuxSessionName?.trim();
    return sessionName == null || sessionName.isEmpty ? null : sessionName;
  }

  Future<_PreparedRemoteMuxCommand?> _prepareRemoteMuxAttachCommand(
    SshSession session,
    Host host,
    String sessionName, {
    RemoteMuxBackend? preferredBackend,
    bool existingOnly = false,
  }) async {
    final attachCommand = await _buildRemoteMuxAttachCommand(
      session,
      host,
      sessionName,
      preferredBackend: preferredBackend,
      existingOnly: existingOnly,
    );
    if (!mounted || attachCommand == null) {
      return null;
    }
    // A generated MonkeyMux attach does not execute the host's saved
    // auto-connect command. Keep its review flag pending until it is used.
    // Reviewing the attach adds a second prompt after Update and restore;
    // choosing Always run would also trust a saved command we never showed.
    final review = assessAutoConnectCommandExecution(
      attachCommand.command,
      importedNeedsReview:
          attachCommand.backend != RemoteMuxBackend.monkeyMux &&
          host.autoConnectRequiresConfirmation,
    );
    if (review.requiresReview &&
        !await _reviewImportedAutoConnectCommand(review, host)) {
      return null;
    }
    return (
      backend: attachCommand.backend,
      command: attachCommand.command,
      sessionName: sessionName,
      tool: null,
    );
  }

  Future<({String command, RemoteMuxBackend backend})?>
  _buildRemoteMuxAttachCommand(
    SshSession session,
    Host host,
    String sessionName, {
    RemoteMuxBackend? preferredBackend,
    bool existingOnly = false,
  }) async {
    final telemetryService = ref.read(telemetryServiceProvider);
    final configuredBackend =
        preferredBackend ??
        _configuredRemoteMuxBackend(host) ??
        RemoteMuxBackend.auto;
    // Windows remotes run cmd.exe/PowerShell, which can't host tmux. MonkeyMux
    // does work there via its ConPTY helper, so only the tmux backend is
    // skipped; the monkeyMux/auto path proceeds and, if the helper can't
    // install or attach, still falls back to a plain shell via the null returns
    // below.
    if (session.remoteIsWindows && configuredBackend == RemoteMuxBackend.tmux) {
      _suppressRemoteMuxDetectionConnectionId = session.connectionId;
      return null;
    }
    if (configuredBackend == RemoteMuxBackend.monkeyMux ||
        configuredBackend == RemoteMuxBackend.auto) {
      try {
        MonkeyMuxServerUpdatePolicy? requestedUpdatePolicy;
        final installation = await _monkeyMuxInstallerService.ensureInstalled(
          session,
          priority: SshExecPriority.normal,
          confirmInstall: (request) async {
            final decision = await _confirmMonkeyMuxInstall(
              request,
              resolveRunningStatus: () =>
                  _monkeyMuxService.runningServerStatusFromInstalledHelpers(
                    session,
                    sessionName,
                  ),
            );
            requestedUpdatePolicy = decision.updatePolicy;
            return decision.install;
          },
        );
        final updatePolicy = await _resolveMonkeyMuxServerUpdatePolicy(
          session,
          installation,
          sessionName,
          preferredUpdatePolicy: requestedUpdatePolicy,
        );
        final terminalThemeReports = buildTerminalThemeHintReports(
          session.terminalTheme ?? _resolveEffectiveTerminalTheme(),
        );
        if (!mounted) {
          return null;
        }
        final viewportCellSize = _localTerminalViewportCellSize();
        return (
          command: buildMonkeyMuxAttachCommand(
            executablePath: installation.executablePath,
            sessionName: sessionName,
            clientId: session.monkeyMuxClientId,
            clipViewport: true,
            existingOnly: existingOnly,
            terminalColumns: viewportCellSize.columns,
            terminalRows: viewportCellSize.rows,
            workingDirectory: host.tmuxWorkingDirectory,
            terminalThemeReports: terminalThemeReports,
            terminalCapabilityReports: buildTerminalCapabilityHintReports(),
            serverUpdatePolicy: updatePolicy,
            startInYoloMode: _startClisInYoloMode,
            windows: installation.isWindows,
          ),
          backend: RemoteMuxBackend.monkeyMux,
        );
      } on MonkeyMuxInstallDeclinedException {
        _suppressRemoteMuxDetectionConnectionId = session.connectionId;
        unawaited(
          telemetryService.logMuxInstallFailed(
            backend: 'monkeymux',
            failureCategory: 'declined',
          ),
        );
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'attach_declined',
          fields: {
            'connectionId': session.connectionId,
            'configuredBackend': configuredBackend.storageValue,
          },
        );
        return null;
      } on Object catch (error) {
        if (error is! Exception && !isExpectedSshOperationError(error)) {
          rethrow;
        }
        _suppressRemoteMuxDetectionConnectionId = session.connectionId;
        unawaited(
          telemetryService.logMuxInstallFailed(
            backend: 'monkeymux',
            failureCategory: 'unavailable',
          ),
        );
        DiagnosticsLogService.instance.warning(
          'monkeymux.install',
          'attach_unavailable',
          fields: {
            'connectionId': session.connectionId,
            'configuredBackend': configuredBackend.storageValue,
            'errorType': error.runtimeType,
          },
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('MonkeyMux is unavailable.')),
          );
        }
        return null;
      }
    }
    return (
      command: buildTmuxCommand(
        sessionName: sessionName,
        workingDirectory: host.tmuxWorkingDirectory,
        extraFlags: host.tmuxExtraFlags,
      ),
      backend: RemoteMuxBackend.tmux,
    );
  }

  Future<MonkeyMuxServerUpdatePolicy> _resolveMonkeyMuxServerUpdatePolicy(
    SshSession session,
    MonkeyMuxInstallation installation,
    String sessionName, {
    MonkeyMuxServerUpdatePolicy? preferredUpdatePolicy,
  }) async {
    session.monkeyMuxViewportClippingEnabled = false;
    session.terminal?.resetHostResizeState();
    final status = await _monkeyMuxService.runningServerStatus(
      session,
      installation,
      sessionName,
    );
    if (!mounted ||
        _connectionCancelled ||
        _connectionId != session.connectionId) {
      return MonkeyMuxServerUpdatePolicy.never;
    }
    final forcedPolicy = _forcedMonkeyMuxReloadRequest?.consumePolicy(
      sessionName,
    );
    if (forcedPolicy != null) {
      _forcedMonkeyMuxReloadRequest = null;
      final runningVersion = status?.version?.trim();
      if (runningVersion != null && runningVersion.isNotEmpty) {
        _pendingMonkeyMuxServerReplacement = (
          connectionId: session.connectionId,
          sessionName: sessionName,
          previousVersion: runningVersion,
          targetVersion: runningVersion,
          expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        );
      }
      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        'forced_reload_requested',
        fields: {
          'connectionId': session.connectionId,
          'supportsShutdown': status?.supportsShutdown ?? false,
          'installedDuringCall': installation.installedDuringCall,
        },
      );
      return forcedPolicy;
    }
    if (status == null || !status.needsUpdate(installation.version)) {
      return MonkeyMuxServerUpdatePolicy.never;
    }
    // `installation.version` is only the packaging label from the bundled
    // manifest; `attach` decides whether to restart a running server by
    // comparing it against the version compiled into the helper binary. If the
    // two ever drift, offering the update would show a dialog that the helper
    // then treats as a no-op, so the prompt would reappear on every connect
    // and never apply. Ask the binary what it really is before prompting.
    final helperVersion = await _monkeyMuxService.installedHelperVersion(
      session,
      installation,
    );
    if (!mounted) {
      return MonkeyMuxServerUpdatePolicy.never;
    }
    final bundledVersion = helperVersion ?? installation.version;
    if (!status.needsUpdate(bundledVersion)) {
      DiagnosticsLogService.instance.warning(
        'monkeymux.install',
        'upgrade_restore_skipped_helper_matches_server',
        fields: {
          'connectionId': session.connectionId,
          'installedDuringCall': installation.installedDuringCall,
        },
      );
      return MonkeyMuxServerUpdatePolicy.never;
    }
    final versionComparison = _compareMonkeyMuxVersions(
      bundledVersion,
      status.version,
    );
    final bundledVersionIsNewer =
        versionComparison != null && versionComparison > 0;
    if (bundledVersionIsNewer) {
      final updatePolicy =
          preferredUpdatePolicy ??
          await _confirmMonkeyMuxRunningServerUpdate(
            status: status,
            bundledVersion: bundledVersion,
          );
      if (updatePolicy == MonkeyMuxServerUpdatePolicy.always) {
        final previousVersion = status.version?.trim();
        if (previousVersion != null && previousVersion.isNotEmpty) {
          _pendingMonkeyMuxServerReplacement = (
            connectionId: session.connectionId,
            sessionName: sessionName,
            previousVersion: previousVersion,
            targetVersion: bundledVersion.trim(),
            expiresAt: DateTime.now().add(const Duration(seconds: 30)),
          );
        }
      }
      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        updatePolicy == MonkeyMuxServerUpdatePolicy.always
            ? 'upgrade_restore_accepted'
            : 'upgrade_restore_deferred',
        fields: {
          'connectionId': session.connectionId,
          'supportsShutdown': status.supportsShutdown,
          'installedDuringCall': installation.installedDuringCall,
        },
      );
      return updatePolicy;
    }
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'version_mismatch_running_server_kept',
      fields: {
        'connectionId': session.connectionId,
        'supportsShutdown': status.supportsShutdown,
        'installedDuringCall': installation.installedDuringCall,
        'bundledVersionIsNewer': false,
      },
    );
    _showMonkeyMuxVersionMismatchNotice(
      connectionId: session.connectionId,
      sessionName: sessionName,
      runningVersion: status.version,
      bundledVersion: bundledVersion,
      versionComparison: versionComparison,
    );
    return MonkeyMuxServerUpdatePolicy.never;
  }

  void _startMonkeyMuxServerReplacementRecovery(
    SshSession session,
    _PendingMonkeyMuxServerReplacement pending,
  ) {
    if (!pending.expiresAt.isAfter(DateTime.now())) {
      if (_pendingMonkeyMuxServerReplacement == pending) {
        _pendingMonkeyMuxServerReplacement = null;
      }
      return;
    }
    if (_monkeyMuxServerReplacementRecovery != null) return;
    final operation = _recoverMonkeyMuxAfterServerReplacement(session, pending);
    _monkeyMuxServerReplacementRecovery = operation;
    unawaited(
      operation
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace _) {
              DiagnosticsLogService.instance.warning(
                'monkeymux.install',
                'upgrade_runtime_recovery_failed',
                fields: {
                  'connectionId': session.connectionId,
                  'errorType': error.runtimeType,
                },
              );
            },
          )
          .whenComplete(() {
            if (identical(_monkeyMuxServerReplacementRecovery, operation)) {
              _monkeyMuxServerReplacementRecovery = null;
            }
          }),
    );
  }

  Future<bool> _waitForMonkeyMuxRecoveryRetry() {
    _cancelMonkeyMuxServerReplacementRetry();
    final completer = Completer<bool>();
    _monkeyMuxServerReplacementRecoveryDelay = completer;
    _monkeyMuxServerReplacementRecoveryTimer = Timer(
      const Duration(milliseconds: 500),
      () {
        if (!completer.isCompleted) completer.complete(true);
        if (identical(_monkeyMuxServerReplacementRecoveryDelay, completer)) {
          _monkeyMuxServerReplacementRecoveryDelay = null;
          _monkeyMuxServerReplacementRecoveryTimer = null;
        }
      },
    );
    return completer.future;
  }

  void _cancelMonkeyMuxServerReplacementRetry() {
    _monkeyMuxServerReplacementRecoveryTimer?.cancel();
    _monkeyMuxServerReplacementRecoveryTimer = null;
    final completer = _monkeyMuxServerReplacementRecoveryDelay;
    _monkeyMuxServerReplacementRecoveryDelay = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
  }

  Future<void> _recoverMonkeyMuxAfterServerReplacement(
    SshSession session,
    _PendingMonkeyMuxServerReplacement pending,
  ) async {
    var replacementObserved = false;
    var foregroundAttached = false;
    var attempts = 0;
    for (; attempts < 30; attempts++) {
      if (!mounted ||
          _connectionId != pending.connectionId ||
          _pendingMonkeyMuxServerReplacement != pending) {
        return;
      }
      if (attempts > 0 && !await _waitForMonkeyMuxRecoveryRetry()) {
        return;
      }
      try {
        final version = (await _monkeyMuxService.detectedVersion(
          session,
          pending.sessionName,
        ))?.trim();
        replacementObserved =
            version != null &&
            version.isNotEmpty &&
            (version == pending.targetVersion ||
                version != pending.previousVersion);
        if (replacementObserved) {
          foregroundAttached = await _monkeyMuxService
              .hasForegroundClientAfterServerReplacement(
                session,
                pending.sessionName,
              );
          if (foregroundAttached) break;
        }
      } on Object {
        // Socket takeover and attach registration are transiently unavailable.
      }
    }
    if (!mounted ||
        _connectionId != pending.connectionId ||
        _pendingMonkeyMuxServerReplacement != pending) {
      return;
    }

    // A watch started before the replacement attach remains connected to the
    // outgoing native-bridge host even after the public socket moves.
    await _monkeyMuxService.resetServerRuntime(
      session.connectionId,
      pending.sessionName,
    );
    if (!mounted ||
        _connectionId != pending.connectionId ||
        _pendingMonkeyMuxServerReplacement != pending) {
      return;
    }
    setState(() {
      _pendingMonkeyMuxServerReplacement = null;
      _isTmuxActive = true;
      _tmuxOwnershipConfirmed = foregroundAttached;
      _tmuxSessionName = pending.sessionName;
      _activeMuxBackend = RemoteMuxBackend.monkeyMux;
      _tmuxStateConnectionId = session.connectionId;
      _monkeyMuxAttachEstablished =
          _monkeyMuxAttachEstablished || foregroundAttached;
      _monkeyMuxForegroundFalseProbeCount = 0;
      _tmuxBarRecoveryGeneration += 1;
    });
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'upgrade_runtime_recovered',
      fields: {
        'connectionId': session.connectionId,
        'replacementObserved': replacementObserved,
        'foregroundAttached': foregroundAttached,
        'attempts': (attempts + 1).clamp(1, 30),
      },
    );

    if (!foregroundAttached) {
      await _reattachTmuxIfNeeded(session, pending.sessionName);
      if (!mounted || _connectionId != session.connectionId) return;
    } else {
      _startTmuxForegroundVerification(session, pending.sessionName);
    }
    unawaited(
      _detectTmux(session, skipDelay: true, preserveExistingTmuxState: true),
    );
  }

  Future<MonkeyMuxServerUpdatePolicy> _confirmMonkeyMuxRunningServerUpdate({
    required MonkeyMuxServerStatus status,
    required String bundledVersion,
    MonkeyMuxInstallRequest? installRequest,
  }) async {
    if (!mounted) {
      return MonkeyMuxServerUpdatePolicy.never;
    }
    final runningVersion = status.version?.trim();
    final currentVersionLabel = runningVersion == null || runningVersion.isEmpty
        ? 'current version'
        : runningVersion;
    final warning = status.hasNativeAcpWindows
        ? 'Native agent windows stay connected to their running sessions while '
              'MonkeySSH recreates the terminal windows in the new helper.'
        : status.supportsShutdown
        ? 'Updating may briefly interrupt running programs. Some restored '
              'sessions may not resume exactly where they left off.'
        : 'The running helper cannot stop itself cleanly. Updating may '
              'interrupt sessions and can leave old processes running while '
              'MonkeySSH restores the windows.';
    final decision = await showDialog<MonkeyMuxServerUpdatePolicy>(
      context: context,
      barrierDismissible: false,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: Text(
            'Update running MonkeyMux?',
            style: FluttyTheme.displayMono(
              fontSize: 18,
              color: colorScheme.onSurface,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    installRequest == null
                        ? 'MonkeySSH can restart this workspace with helper '
                              '$bundledVersion and automatically restore its '
                              'existing windows.'
                        : 'MonkeySSH will upload helper $bundledVersion. It can '
                              'then restart this workspace and automatically '
                              'restore its existing windows.',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colorScheme.tertiary),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: colorScheme.tertiary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            warning,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Use $currentVersionLabel for now to connect without '
                    'changing the running workspace.',
                  ),
                  if (installRequest case final request?) ...[
                    const SizedBox(height: 16),
                    Text('Running version: $currentVersionLabel'),
                    Text('Bundled version: $bundledVersion'),
                    Text('Platform: ${request.platform}'),
                    Text('Size: ${_formatMonkeyMuxInstallSize(request.size)}'),
                    const SizedBox(height: 12),
                    const Text(
                      'The versioned helper is stored under '
                      '~/.monkeyssh/bin/monkeymux. A managed launcher is added '
                      'to ~/.local/bin so it can also be used from the host '
                      'terminal.',
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, MonkeyMuxServerUpdatePolicy.never),
              child: Text('Use $currentVersionLabel for now'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, MonkeyMuxServerUpdatePolicy.always),
              child: const Text('Update and restore'),
            ),
          ],
        );
      },
    );
    return decision ?? MonkeyMuxServerUpdatePolicy.never;
  }

  void _showMonkeyMuxVersionMismatchNotice({
    required int connectionId,
    required String sessionName,
    required String? runningVersion,
    required String bundledVersion,
    required int? versionComparison,
  }) {
    if (!mounted) return;
    final runningLabel = runningVersion?.trim();
    final noticeKey =
        '$connectionId:$sessionName:$runningLabel:$bundledVersion';
    if (_lastMonkeyMuxUpgradeDeferredNotice == noticeKey) return;
    _lastMonkeyMuxUpgradeDeferredNotice = noticeKey;
    late final String message;
    if (versionComparison != null && versionComparison < 0) {
      message =
          'This workspace is running MonkeyMux '
          '${runningLabel ?? 'a newer version'}, newer than bundled '
          '$bundledVersion. Keeping the running server.';
    } else {
      message =
          'This workspace is running a different MonkeyMux version. Keeping '
          'the running server to avoid interrupting its windows.';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 8), content: Text(message)),
    );
  }

  Future<({bool install, MonkeyMuxServerUpdatePolicy? updatePolicy})>
  _confirmMonkeyMuxInstall(
    MonkeyMuxInstallRequest request, {
    Future<MonkeyMuxServerStatus?> Function()? resolveRunningStatus,
  }) async {
    if (!mounted) {
      return (install: false, updatePolicy: null);
    }
    MonkeyMuxServerStatus? runningStatus;
    if (resolveRunningStatus != null) {
      runningStatus = await resolveRunningStatus();
      if (!mounted) {
        return (install: false, updatePolicy: null);
      }
    }
    final updateStatus =
        runningStatus != null && runningStatus.needsUpdate(request.version)
        ? runningStatus
        : null;
    final versionComparison = _compareMonkeyMuxVersions(
      request.version,
      updateStatus?.version,
    );
    final bundledVersionIsNewer =
        versionComparison != null && versionComparison > 0;
    if (updateStatus != null && bundledVersionIsNewer) {
      final updatePolicy = await _confirmMonkeyMuxRunningServerUpdate(
        status: updateStatus,
        bundledVersion: request.version,
        installRequest: request,
      );
      if (!mounted) {
        return (install: false, updatePolicy: null);
      }
      return (install: true, updatePolicy: updatePolicy);
    }
    final title = switch ((updateStatus, bundledVersionIsNewer)) {
      (null, _) => 'Install MonkeyMux helper?',
      _ => 'Install bundled MonkeyMux helper?',
    };
    final runningVersionLabel = updateStatus?.version?.trim();
    late final String explanation;
    if (updateStatus == null) {
      explanation =
          'MonkeySSH needs to upload its bundled MonkeyMux helper before using '
          'MonkeyMux on this connected host.';
    } else if (versionComparison != null && versionComparison < 0) {
      explanation =
          'This workspace is running helper ${runningVersionLabel ?? 'unknown'}, '
          'newer than bundled ${request.version}. MonkeySSH can install its '
          'bundled helper without replacing the running server.';
    } else {
      explanation =
          'This workspace is running a different MonkeyMux version. MonkeySSH '
          'can install its bundled helper without replacing the running server.';
    }
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(explanation),
              const SizedBox(height: 12),
              if (updateStatus != null)
                Text('Running version: ${updateStatus.version ?? 'unknown'}'),
              Text('Bundled version: ${request.version}'),
              Text('Platform: ${request.platform}'),
              Text('Size: ${_formatMonkeyMuxInstallSize(request.size)}'),
              const SizedBox(height: 12),
              const Text(
                'The versioned helper is stored under '
                '~/.monkeyssh/bin/monkeymux. A managed launcher is added to '
                '~/.local/bin so it can also be used from the host terminal.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Open shell'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    return (install: confirmed ?? false, updatePolicy: null);
  }

  String _formatMonkeyMuxInstallSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kibibytes = bytes / 1024;
    if (kibibytes < 1024) {
      return '${kibibytes.toStringAsFixed(kibibytes < 10 ? 1 : 0)} KB';
    }
    final mebibytes = kibibytes / 1024;
    return '${mebibytes.toStringAsFixed(mebibytes < 10 ? 1 : 0)} MB';
  }

  Future<void> _runMonkeyMuxAgentLaunchCommand(
    SshSession session,
    Host host,
    AgentLaunchPreset preset,
    SSHSession shell,
  ) async {
    final command = await _prepareMonkeyMuxAgentLaunchCommand(
      session,
      host,
      preset,
    );
    if (command == null) {
      return;
    }
    _applyPreparedRemoteMuxCommand(session, command);
    if (!mounted ||
        _connectionId != session.connectionId ||
        !identical(_shell, shell)) {
      return;
    }
    if (session.remoteIsWindows) {
      await _reopenShellForVisibleTmux(
        session,
        command: command.command,
        requestPty: false,
      );
      DiagnosticsLogService.instance.info(
        'terminal.agent_launch',
        'command_written',
        fields: {
          'connectionId': session.connectionId,
          'backend': command.backend.storageValue,
          'requestedPty': false,
          if (command.tool case final tool?) 'tool': tool.name,
        },
      );
      return;
    }
    shell.write(utf8.encode(formatAutoConnectCommandForShell(command.command)));
    DiagnosticsLogService.instance.info(
      'terminal.agent_launch',
      'command_written',
      fields: {
        'connectionId': session.connectionId,
        'backend': command.backend.storageValue,
        if (command.tool case final tool?) 'tool': tool.name,
      },
    );
  }

  Future<_PreparedRemoteMuxCommand?> _prepareMonkeyMuxAgentLaunchCommand(
    SshSession session,
    Host host,
    AgentLaunchPreset preset,
  ) async {
    final sessionName = preset.tmuxSessionName?.trim();
    if (sessionName == null || sessionName.isEmpty) {
      return null;
    }

    final launchCommand = buildAgentToolCommand(
      preset.tool,
      additionalArguments: preset.additionalArguments,
      startInYoloMode: _startClisInYoloMode,
    );
    DiagnosticsLogService.instance.info(
      'terminal.agent_launch',
      'monkeymux_start',
      fields: {
        'connectionId': session.connectionId,
        'tool': preset.tool.name,
        'hasWorkingDirectory': preset.hasWorkingDirectory,
      },
    );
    late String attachCommand;
    try {
      MonkeyMuxServerUpdatePolicy? requestedUpdatePolicy;
      final installation = await _monkeyMuxInstallerService.ensureInstalled(
        session,
        priority: SshExecPriority.normal,
        confirmInstall: (request) async {
          final decision = await _confirmMonkeyMuxInstall(
            request,
            resolveRunningStatus: () => _monkeyMuxService
                .runningServerStatusFromInstalledHelpers(session, sessionName),
          );
          requestedUpdatePolicy = decision.updatePolicy;
          return decision.install;
        },
      );
      DiagnosticsLogService.instance.info(
        'terminal.agent_launch',
        'monkeymux_ready',
        fields: {
          'connectionId': session.connectionId,
          'platform': installation.platform,
          'version': installation.version,
        },
      );
      final updatePolicy = await _resolveMonkeyMuxServerUpdatePolicy(
        session,
        installation,
        sessionName,
        preferredUpdatePolicy: requestedUpdatePolicy,
      );
      final terminalThemeReports = buildTerminalThemeHintReports(
        session.terminalTheme ?? _resolveEffectiveTerminalTheme(),
      );
      final viewportCellSize = _localTerminalViewportCellSize();
      attachCommand = buildMonkeyMuxAttachCommand(
        executablePath: installation.executablePath,
        sessionName: sessionName,
        clientId: session.monkeyMuxClientId,
        clipViewport: true,
        terminalColumns: viewportCellSize.columns,
        terminalRows: viewportCellSize.rows,
        workingDirectory: preset.workingDirectory,
        windowName: preset.tool.label,
        launchCommand: launchCommand,
        terminalThemeReports: terminalThemeReports,
        terminalCapabilityReports: buildTerminalCapabilityHintReports(),
        serverUpdatePolicy: updatePolicy,
        startInYoloMode: _startClisInYoloMode,
        windows: installation.isWindows,
      );
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      _suppressRemoteMuxDetectionConnectionId = session.connectionId;
      DiagnosticsLogService.instance.warning(
        'monkeymux.install',
        'agent_launch_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MonkeyMux is unavailable.')),
        );
      }
      return null;
    }

    if (!mounted) {
      return null;
    }
    final review = assessAutoConnectCommandExecution(
      attachCommand,
      importedNeedsReview: host.autoConnectRequiresConfirmation,
    );
    if (review.requiresReview &&
        !await _reviewImportedAutoConnectCommand(review, host)) {
      return null;
    }

    return (
      backend: RemoteMuxBackend.monkeyMux,
      command: attachCommand,
      sessionName: sessionName,
      tool: preset.tool,
    );
  }

  void _applyPreparedRemoteMuxCommand(
    SshSession session,
    _PreparedRemoteMuxCommand command,
  ) {
    void apply() {
      final muxContextChanged =
          _tmuxStateConnectionId != session.connectionId ||
          _activeMuxBackend != command.backend ||
          _tmuxSessionName != command.sessionName;
      _activeMuxBackend = command.backend;
      _remoteMuxStartupTool = command.tool;
      session
        ..remoteMuxBackend = command.backend
        ..remoteMuxSessionName = command.sessionName;
      if (muxContextChanged) {
        _muxVersion = null;
      }
      if (command.backend != RemoteMuxBackend.monkeyMux) {
        return;
      }
      _monkeyMuxAttachEstablished = false;
      _isTmuxActive = true;
      // The attach command is only just being issued on this connection's
      // shell, so no client is confirmed yet.
      _tmuxOwnershipConfirmed = false;
      _tmuxSessionName = command.sessionName;
      _tmuxStateConnectionId = session.connectionId;
      _showTmuxBar = true;
      final configuredWorkingDirectory = _configuredRemoteMuxWorkingDirectory(
        backend: command.backend,
        sessionName: command.sessionName,
      );
      _tmuxLaunchWorkingDirectory = configuredWorkingDirectory;
      _tmuxWorkingDirectory = configuredWorkingDirectory;
      _tmuxCurrentCommand = null;
      _shellCompletionTmuxContextRefreshedAt = null;
      _shellCompletionTmuxContextConnectionId = null;
      _shellCompletionTmuxContextSessionName = null;
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logMuxDetected(backend: _telemetryMuxBackendName(command.backend)),
      );
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  String? _preferredTmuxSessionName(Host? host) =>
      _initialTmuxSessionName ??
      resolvePreferredTmuxSessionName(
        structuredSessionName: host?.tmuxSessionName,
        autoConnectCommand: _resolveStoredAutoConnectCommand(host),
      );

  RemoteMultiplexerService get _activeRemoteMultiplexerService =>
      _activeMuxBackend == RemoteMuxBackend.monkeyMux
      ? _monkeyMuxService
      : _tmuxMultiplexerService;

  TerminalConnectionBackend _activeTerminalConnectionBackend(
    SshSession session,
  ) => _terminalBackendService.resolve(
    session,
    activeMuxBackend: _isTmuxActive ? _activeMuxBackend : RemoteMuxBackend.auto,
    sessionName: _isTmuxActive ? _tmuxSessionName : null,
    tmuxExtraFlags: _activeTmuxExtraFlags,
  );

  bool _ownsTerminalConnectionBackend(
    SshSession session,
    TerminalConnectionBackend backend,
    String? windowKey,
  ) =>
      mounted &&
      identical(session, _activeSession()) &&
      _isTmuxActive &&
      _activeMuxBackend == backend.remoteMuxBackend &&
      _tmuxSessionName == backend.sessionName &&
      _activeTmuxExtraFlags == backend.extraFlags &&
      windowKey == resolveTmuxBarActiveWindowKey(_currentTmuxWindowsSnapshot) &&
      !(_tmuxBarKey.currentState?.hasPendingWindowSelection ?? false);

  RemoteMultiplexerService _remoteMultiplexerServiceForBackend(
    RemoteMuxBackend backend,
  ) => backend == RemoteMuxBackend.monkeyMux
      ? _monkeyMuxService
      : _tmuxMultiplexerService;

  String? get _activeTmuxExtraFlags =>
      _activeMuxBackend == RemoteMuxBackend.tmux ? _host?.tmuxExtraFlags : null;

  RemoteMuxBackend? _configuredRemoteMuxBackend(Host? host) {
    final sessionName = _initialTmuxSessionName ?? host?.tmuxSessionName;
    if (sessionName == null || sessionName.trim().isEmpty) {
      return null;
    }
    return resolveRemoteMuxStartupBackend(
      host?.remoteMuxBackend,
      tmuxExtraFlags: host?.tmuxExtraFlags,
    );
  }

  String? _configuredRemoteMuxWorkingDirectory({
    required RemoteMuxBackend backend,
    required String sessionName,
  }) => resolveConfiguredMuxWorkingDirectory(
    agentPreset: _autoConnectAgentPreset,
    backend: backend,
    sessionName: sessionName,
    hostWorkingDirectory: _host?.tmuxWorkingDirectory,
  );

  void _clearTmuxState() {
    _automaticPortForwardRootSyncGeneration++;
    final session = _observedSession ?? _activeSession();
    if (session != null) {
      unawaited(session.updateAutomaticPortForwardProcessRoots(const {}));
    }
    if (_activeMuxBackend == RemoteMuxBackend.monkeyMux ||
        session?.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      _terminal.resetHostResizeState();
      if (session != null) {
        session
          ..monkeyMuxViewportClippingEnabled = false
          ..remoteMuxBackend = null
          ..remoteMuxSessionName = null;
      }
    }
    _stopTmuxForegroundVerification();
    _cancelMonkeyMuxRefreshAndResizeState();
    _cancelPendingTmuxWindowThemeRefresh();
    _tmuxDetectionGeneration += 1;
    _isTmuxActive = false;
    _tmuxOwnershipConfirmed = false;
    _tmuxSessionName = null;
    _monkeyMuxAttachEstablished = false;
    _pendingMonkeyMuxServerReplacement = null;
    _monkeyMuxForegroundFalseProbeCount = 0;
    _muxVersion = null;
    _activeMuxBackend = RemoteMuxBackend.tmux;
    _tmuxStateConnectionId = null;
    _isTmuxBarExpanded = false;
    _tmuxSidebarDragOffset = 0;
    _remoteMuxStartupTool = null;
    _tmuxLaunchWorkingDirectory = null;
    _tmuxWorkingDirectory = null;
    _tmuxCurrentCommand = null;
    _shellCompletionTmuxContextRefreshedAt = null;
    _shellCompletionTmuxContextConnectionId = null;
    _shellCompletionTmuxContextSessionName = null;
  }

  void _startTmuxForegroundVerification(
    SshSession session,
    String sessionName,
  ) {
    _tmuxForegroundVerificationTimer?.cancel();
    _tmuxForegroundVerificationInFlight = false;
    _monkeyMuxForegroundFalseProbeCount = 0;
    final generation = ++_tmuxForegroundVerificationGeneration;
    _tmuxForegroundVerificationTimer = Timer.periodic(
      _tmuxForegroundVerificationInterval,
      (_) => unawaited(
        _verifyTmuxForegroundSession(session, sessionName, generation),
      ),
    );
  }

  void _stopTmuxForegroundVerification() {
    _tmuxForegroundVerificationTimer?.cancel();
    _tmuxForegroundVerificationTimer = null;
    _tmuxForegroundVerificationGeneration += 1;
    _tmuxForegroundVerificationInFlight = false;
  }

  Future<void> _refreshMuxVersion({
    required SshSession session,
    required String sessionName,
    required RemoteMuxBackend backend,
    required int detectionGeneration,
  }) async {
    try {
      final version = await _remoteMultiplexerServiceForBackend(backend)
          .detectedVersion(
            session,
            sessionName,
            extraFlags: backend == RemoteMuxBackend.tmux
                ? _host?.tmuxExtraFlags
                : null,
          );
      final normalizedVersion = version?.trim();
      if (!mounted ||
          _connectionId != session.connectionId ||
          detectionGeneration != _tmuxDetectionGeneration ||
          !_isTmuxActive ||
          _activeMuxBackend != backend ||
          _tmuxSessionName != sessionName) {
        return;
      }
      final nextVersion = normalizedVersion == null || normalizedVersion.isEmpty
          ? null
          : normalizedVersion;
      if (_muxVersion != nextVersion) {
        setState(() => _muxVersion = nextVersion);
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'version_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'backend': backend.storageValue,
          'errorType': error.runtimeType,
        },
      );
      if (mounted &&
          _connectionId == session.connectionId &&
          detectionGeneration == _tmuxDetectionGeneration &&
          _isTmuxActive &&
          _activeMuxBackend == backend &&
          _tmuxSessionName == sessionName &&
          _muxVersion != null) {
        setState(() => _muxVersion = null);
      }
    }
  }

  Future<void> _verifyTmuxForegroundSession(
    SshSession session,
    String sessionName,
    int generation,
  ) async {
    if (_tmuxForegroundVerificationInFlight ||
        !mounted ||
        generation != _tmuxForegroundVerificationGeneration ||
        _connectionId != session.connectionId ||
        !_isTmuxActive ||
        _tmuxSessionName != sessionName) {
      return;
    }

    _tmuxForegroundVerificationInFlight = true;
    try {
      final mux = _activeRemoteMultiplexerService;
      if (mux.isExecChannelCoolingDown(session)) {
        DiagnosticsLogService.instance.debug(
          'tmux.ui',
          'foreground_verify_deferred',
          fields: {'connectionId': session.connectionId},
        );
        return;
      }
      final String? foregroundSessionName;
      final bool foregroundMatches;
      if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
        foregroundMatches = await mux.hasForegroundClientOrThrow(
          session,
          sessionName,
        );
        foregroundSessionName = foregroundMatches ? sessionName : null;
      } else {
        foregroundSessionName = await mux.foregroundSessionNameOrThrow(
          session,
          extraFlags: _activeTmuxExtraFlags,
        );
        foregroundMatches = foregroundSessionName == sessionName;
      }
      if (!mounted ||
          generation != _tmuxForegroundVerificationGeneration ||
          _connectionId != session.connectionId ||
          !_isTmuxActive ||
          _tmuxSessionName != sessionName) {
        return;
      }
      if (foregroundMatches) {
        _monkeyMuxForegroundFalseProbeCount = 0;
        DiagnosticsLogService.instance.debug(
          'tmux.ui',
          'foreground_verified',
          fields: {'connectionId': session.connectionId},
        );
        return;
      }

      _monkeyMuxForegroundFalseProbeCount += 1;
      final pendingReplacement = _pendingMonkeyMuxServerReplacement;
      final preserveChrome = shouldPreserveMonkeyMuxChromeAfterAttachProbe(
        backend: _activeMuxBackend,
        serverReplacementPending:
            pendingReplacement?.connectionId == session.connectionId &&
            pendingReplacement?.sessionName == sessionName &&
            pendingReplacement!.expiresAt.isAfter(DateTime.now()),
        nativeAgentActive:
            _activeNativeAcpSessionKey != null || _nativeAcpLaunchState != null,
        attachEstablished: _monkeyMuxAttachEstablished,
        consecutiveFalseProbes: _monkeyMuxForegroundFalseProbeCount,
      );
      if (preserveChrome) {
        DiagnosticsLogService.instance.info(
          'tmux.ui',
          'foreground_detach_deferred',
          fields: {
            'connectionId': session.connectionId,
            'replacementPending': pendingReplacement != null,
            'nativeAgentActive': _activeNativeAcpSessionKey != null,
            'attempt': _monkeyMuxForegroundFalseProbeCount,
          },
        );
        return;
      }

      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'foreground_detached',
        fields: {
          'connectionId': session.connectionId,
          'hasForegroundSession': foregroundSessionName != null,
        },
      );
      setState(_clearTmuxState);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'foreground_verify_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    } finally {
      if (generation == _tmuxForegroundVerificationGeneration) {
        _tmuxForegroundVerificationInFlight = false;
      }
    }
  }

  /// Detects whether the connected session is inside tmux.
  ///
  /// Starts with any structured tmux configuration immediately, then retries
  /// discovery until the shell-side attach command has settled.
  Future<bool> _detectTmux(
    SshSession session, {
    bool skipDelay = false,
    bool preserveExistingTmuxState = false,
    bool isReopeningExistingTerminal = false,
  }) async {
    // Capture the connection ID at the start so we can verify it hasn't
    // changed after async gaps (user may have switched connections).
    final capturedConnectionId = _connectionId;
    final detectionGeneration = ++_tmuxDetectionGeneration;
    final host = _host;
    final configuredBackend = _configuredRemoteMuxBackend(host);
    final preferredSessionName =
        _preferredTmuxSessionName(host) ?? session.remoteMuxSessionName;
    final persistedBackend = session.remoteMuxBackend;
    final muxBackend =
        persistedBackend ??
        (configuredBackend == RemoteMuxBackend.auto
            ? _activeMuxBackend
            : (configuredBackend ?? _activeMuxBackend));
    // Windows remotes (cmd.exe/PowerShell) can't run tmux; only MonkeyMux is
    // viable there. Skip detection when the resolved backend is tmux so we don't
    // fire failing POSIX tmux probes on every connect, but let MonkeyMux
    // detection proceed (its control channel works on Windows). A fresh MonkeyMux
    // session is still started/reattached by the attach command flow.
    if (session.remoteIsWindows && muxBackend == RemoteMuxBackend.tmux) {
      if (mounted) {
        setState(_clearTmuxState);
      } else {
        _clearTmuxState();
      }
      return false;
    }
    final mux = _remoteMultiplexerServiceForBackend(muxBackend);
    final tmuxStateBelongsToSession =
        _tmuxStateConnectionId == session.connectionId;
    // Window-list recovery may only keep a bar whose client ownership was
    // already proven for this connection. Preserving unconfirmed state here
    // would let a primed bar survive a definitive "not attached" answer.
    final mayPreserveExistingTmuxState =
        preserveExistingTmuxState &&
        tmuxStateBelongsToSession &&
        _tmuxOwnershipConfirmed;
    final existingCandidateSessionName =
        resolveOwnedTmuxDetectionExistingSessionName(
          sessionConnectionId: session.connectionId,
          tmuxStateConnectionId: _tmuxStateConnectionId,
          existingSessionName: _tmuxSessionName,
        );
    final candidateSessionName = resolveTmuxDetectionCandidateSessionName(
      preferredSessionName: preferredSessionName,
      existingSessionName: existingCandidateSessionName,
    );
    final hasExistingVisibleTmuxState =
        tmuxStateBelongsToSession && _isTmuxActive && _tmuxSessionName != null;
    final shouldKeepExistingTmuxStateWhileDetecting =
        mayPreserveExistingTmuxState ||
        (hasExistingVisibleTmuxState &&
            candidateSessionName != null &&
            candidateSessionName == existingCandidateSessionName);
    final shouldPrimeTmuxStateWhileDetecting =
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: candidateSessionName,
          hasExistingVisibleTmuxState: hasExistingVisibleTmuxState,
          mayPreserveExistingTmuxState: mayPreserveExistingTmuxState,
          isReopeningExistingTerminal: isReopeningExistingTerminal,
        );
    final hadConfirmedTmuxState =
        hasExistingVisibleTmuxState &&
        _tmuxOwnershipConfirmed &&
        // Only the session whose ownership was actually confirmed may be
        // preserved; a probe for a different session name proves nothing
        // about the bar currently on screen.
        candidateSessionName == existingCandidateSessionName;
    final preferredWorkingDirectory = candidateSessionName == null
        ? null
        : _configuredRemoteMuxWorkingDirectory(
            backend: muxBackend,
            sessionName: candidateSessionName,
          );
    var confirmedTmuxActive = false;
    String? confirmedOwnedSessionName;
    var hadDetectionFailure = false;

    if (mounted) {
      setState(() {
        if (shouldKeepExistingTmuxStateWhileDetecting) {
          if (preferredWorkingDirectory != null) {
            _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
            _tmuxWorkingDirectory = preferredWorkingDirectory;
          }
        } else if (shouldPrimeTmuxStateWhileDetecting) {
          _isTmuxActive = true;
          _tmuxOwnershipConfirmed = false;
          _tmuxSessionName = candidateSessionName;
          _activeMuxBackend = muxBackend;
          _muxVersion = null;
          _tmuxStateConnectionId = session.connectionId;
          _tmuxLaunchWorkingDirectory = preferredWorkingDirectory;
          _tmuxWorkingDirectory = preferredWorkingDirectory;
          _tmuxCurrentCommand = null;
          _shellCompletionTmuxContextRefreshedAt = null;
        } else if (!mayPreserveExistingTmuxState) {
          _stopTmuxForegroundVerification();
          _isTmuxActive = false;
          _tmuxOwnershipConfirmed = false;
          _tmuxSessionName = null;
          _muxVersion = null;
          _tmuxStateConnectionId = null;
          _tmuxLaunchWorkingDirectory = null;
          _tmuxWorkingDirectory = null;
          _tmuxCurrentCommand = null;
          _shellCompletionTmuxContextRefreshedAt = null;
        }
      });
    }

    try {
      final retrySchedule = resolveTmuxDetectionRetrySchedule(
        skipDelay: skipDelay,
      );

      for (final delay in retrySchedule) {
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
          if (!mounted ||
              _connectionId != capturedConnectionId ||
              detectionGeneration != _tmuxDetectionGeneration) {
            return false;
          }
        }

        final bool active;
        final String? foregroundSessionName;
        try {
          if (muxBackend == RemoteMuxBackend.monkeyMux &&
              candidateSessionName != null) {
            active = await mux.hasForegroundClientOrThrow(
              session,
              candidateSessionName,
            );
            foregroundSessionName = active ? candidateSessionName : null;
          } else {
            foregroundSessionName = await mux.foregroundSessionNameOrThrow(
              session,
              extraFlags: host?.tmuxExtraFlags,
            );
            active = candidateSessionName != null
                ? foregroundSessionName == candidateSessionName
                : foregroundSessionName != null;
          }
        } on Object catch (error) {
          hadDetectionFailure = true;
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_attempt_failed',
            fields: {
              'connectionId': session.connectionId,
              'hasCandidate': candidateSessionName != null,
              'errorType': error.runtimeType,
            },
          );
          if (candidateSessionName == null &&
              !hadConfirmedTmuxState &&
              !mayPreserveExistingTmuxState) {
            rethrow;
          }
          continue;
        }
        DiagnosticsLogService.instance.debug(
          'tmux.ui',
          'detection_attempt',
          fields: {
            'connectionId': session.connectionId,
            'active': active,
            'hasCandidate': candidateSessionName != null,
            'hasForegroundSession': foregroundSessionName != null,
          },
        );
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (!active) {
          confirmedTmuxActive = false;
          confirmedOwnedSessionName = null;
          hadDetectionFailure = false;
          continue;
        }
        confirmedTmuxActive = true;
        _monkeyMuxForegroundFalseProbeCount = 0;

        final sessionName = candidateSessionName ?? foregroundSessionName;
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (sessionName == null) {
          DiagnosticsLogService.instance.debug(
            'tmux.ui',
            'detection_no_session_name',
            fields: {'connectionId': session.connectionId},
          );
          continue;
        }
        confirmedOwnedSessionName = sessionName;

        final List<TmuxWindow> windows;
        try {
          windows = await mux.listWindows(
            session,
            sessionName,
            extraFlags: muxBackend == RemoteMuxBackend.tmux
                ? host?.tmuxExtraFlags
                : null,
          );
        } on Object catch (error) {
          hadDetectionFailure = true;
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_windows_failed',
            fields: {
              'connectionId': session.connectionId,
              'errorType': error.runtimeType,
            },
          );
          continue;
        }
        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }
        if (windows.isEmpty) {
          DiagnosticsLogService.instance.debug(
            'tmux.ui',
            'detection_empty_windows',
            fields: {'connectionId': session.connectionId},
          );
          continue;
        }
        _syncAutomaticPortForwardProcessRoots(
          session,
          windows,
          sessionName: sessionName,
          extraFlags: muxBackend == RemoteMuxBackend.tmux
              ? host?.tmuxExtraFlags
              : null,
          queryTmuxPanePids: muxBackend == RemoteMuxBackend.tmux,
        );

        // Get the active window's working directory for SFTP/path resolution.
        var tmuxLaunchCwd = preferredWorkingDirectory;
        var tmuxCwd = preferredWorkingDirectory;
        String? tmuxCurrentCommand;
        try {
          final activeWindow = windows.where((w) => w.isActive).firstOrNull;
          tmuxLaunchCwd ??= activeWindow?.currentPath;
          tmuxCwd ??= activeWindow?.currentPath;
          tmuxCurrentCommand = activeWindow?.currentCommand;
        } on Object {
          // Non-critical — path resolution will fall back to OSC 7.
        }

        if (!mounted ||
            _connectionId != capturedConnectionId ||
            detectionGeneration != _tmuxDetectionGeneration) {
          return false;
        }

        setState(() {
          _isTmuxActive = true;
          _tmuxOwnershipConfirmed = true;
          _tmuxSessionName = sessionName;
          _activeMuxBackend = muxBackend;
          _tmuxStateConnectionId = session.connectionId;
          _tmuxLaunchWorkingDirectory = tmuxLaunchCwd;
          _tmuxWorkingDirectory = tmuxCwd;
          _tmuxCurrentCommand = tmuxCurrentCommand;
          _connectionOpenedWorkingDirectory ??= normalizeSftpAbsolutePath(
            tmuxLaunchCwd,
          );
        });
        unawaited(
          _refreshMuxVersion(
            session: session,
            sessionName: sessionName,
            backend: muxBackend,
            detectionGeneration: detectionGeneration,
          ),
        );
        session
          ..remoteMuxBackend = muxBackend
          ..remoteMuxSessionName = sessionName;
        if (muxBackend == RemoteMuxBackend.monkeyMux) {
          _markMonkeyMuxReconnectEstablished(session, sessionName);
        }
        _startTmuxForegroundVerification(session, sessionName);
        DiagnosticsLogService.instance.info(
          'tmux.ui',
          'detection_success',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': windows.length,
          },
        );
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logMuxDetected(backend: _telemetryMuxBackendName(muxBackend)),
        );
        // Prime tmux's per-pane color cache with the active theme as soon
        // as we confirm tmux is running. Without this, an inner TUI like
        // Codex CLI that queries OSC 11 for theme detection would receive
        // whatever stale value tmux had cached (e.g., from a previous
        // attach to a different terminal), and bake the wrong composer
        // surface color into its rendered output.
        if (muxBackend == RemoteMuxBackend.tmux) {
          _primeTmuxTerminalTheme(session);
        }
        await _activateInitialTmuxWindowIfNeeded(session, sessionName, windows);
        return true;
      }

      if (!mounted ||
          _connectionId != capturedConnectionId ||
          detectionGeneration != _tmuxDetectionGeneration) {
        return false;
      }

      _monkeyMuxForegroundFalseProbeCount += 1;
      final pendingReplacement = _pendingMonkeyMuxServerReplacement;
      final replacementPending =
          pendingReplacement?.connectionId == session.connectionId &&
          pendingReplacement?.sessionName == candidateSessionName &&
          pendingReplacement!.expiresAt.isAfter(DateTime.now());
      if (shouldPreserveMonkeyMuxChromeAfterAttachProbe(
        backend: muxBackend,
        serverReplacementPending: replacementPending,
        nativeAgentActive:
            _activeNativeAcpSessionKey != null || _nativeAcpLaunchState != null,
        attachEstablished: _monkeyMuxAttachEstablished,
        consecutiveFalseProbes: _monkeyMuxForegroundFalseProbeCount,
      )) {
        DiagnosticsLogService.instance.info(
          'tmux.ui',
          'detection_preserved_during_handoff',
          fields: {
            'connectionId': session.connectionId,
            'replacementPending': replacementPending,
            'nativeAgentActive': _activeNativeAcpSessionKey != null,
            'attempt': _monkeyMuxForegroundFalseProbeCount,
          },
        );
        return false;
      }

      if (shouldPreserveTerminalTmuxStateAfterDetectionFailure(
        preserveExistingTmuxState: mayPreserveExistingTmuxState,
        hadConfirmedTmuxState: hadConfirmedTmuxState,
        confirmedTmuxActive: confirmedTmuxActive,
        hadDetectionFailure: hadDetectionFailure,
      )) {
        final logFields = {
          'connectionId': session.connectionId,
          'confirmedTmuxActive': confirmedTmuxActive,
          'hadDetectionFailure': hadDetectionFailure,
        };
        if (hadDetectionFailure) {
          DiagnosticsLogService.instance.warning(
            'tmux.ui',
            'detection_preserved_existing',
            fields: logFields,
          );
        } else {
          DiagnosticsLogService.instance.info(
            'tmux.ui',
            'detection_preserved_existing',
            fields: logFields,
          );
        }
        _latchConfirmedTmuxOwnership(session, confirmedOwnedSessionName);
        return false;
      }

      if (!mayPreserveExistingTmuxState) {
        // A run that only ever errored proves nothing either way, so hide the
        // unproven bar without tearing down a possibly-live attach.
        setState(
          hadDetectionFailure ? _hideUnconfirmedTmuxBar : _clearTmuxState,
        );
      }
      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'detection_inactive',
        fields: {
          'connectionId': session.connectionId,
          'inconclusive': hadDetectionFailure,
        },
      );
      return false;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'detection_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      if (!mounted ||
          _connectionId != capturedConnectionId ||
          detectionGeneration != _tmuxDetectionGeneration) {
        return false;
      }
      if (shouldPreserveTerminalTmuxStateAfterDetectionFailure(
        preserveExistingTmuxState: mayPreserveExistingTmuxState,
        hadConfirmedTmuxState: hadConfirmedTmuxState,
        confirmedTmuxActive: confirmedTmuxActive,
        hadDetectionFailure: true,
      )) {
        DiagnosticsLogService.instance.warning(
          'tmux.ui',
          'detection_preserved_existing',
          fields: {
            'connectionId': session.connectionId,
            'confirmedTmuxActive': confirmedTmuxActive,
            'hadDetectionFailure': true,
          },
        );
        _latchConfirmedTmuxOwnership(session, confirmedOwnedSessionName);
        return false;
      }
      if (!mayPreserveExistingTmuxState) {
        // This path is always inconclusive: the probe threw rather than
        // reporting that nothing is attached.
        setState(_hideUnconfirmedTmuxBar);
      }
      return false;
    }
  }

  /// Hides bar state whose client ownership was never proven for this SSH
  /// connection, without tearing down session-level mux plumbing.
  ///
  /// A detection run whose probes only ever errored is inconclusive: the bar
  /// must go because ownership is unproven, but a MonkeyMux attach may well be
  /// live, and [_clearTmuxState] would reset its viewport/host-resize state and
  /// forget the session name needed to re-detect it.
  void _hideUnconfirmedTmuxBar() {
    _stopTmuxForegroundVerification();
    _isTmuxActive = false;
    _tmuxOwnershipConfirmed = false;
    _isTmuxBarExpanded = false;
    _tmuxSidebarDragOffset = 0;
    _muxVersion = null;
  }

  /// Records that an ownership-scoped probe proved this SSH connection owns the
  /// mux client backing the visible bar, and resumes periodic verification.
  ///
  /// Detection can confirm ownership and still fail to list windows. Without
  /// this latch such a bar would stay visible with no periodic re-check, which
  /// is exactly the unverified state the bar must never be left in.
  void _latchConfirmedTmuxOwnership(SshSession session, String? sessionName) {
    if (sessionName == null ||
        !mounted ||
        !_isTmuxActive ||
        _tmuxStateConnectionId != session.connectionId ||
        _tmuxSessionName != sessionName) {
      return;
    }
    if (!_tmuxOwnershipConfirmed) {
      setState(() => _tmuxOwnershipConfirmed = true);
    }
    _startTmuxForegroundVerification(session, sessionName);
  }

  Future<void> _activateInitialTmuxWindowIfNeeded(
    SshSession session,
    String sessionName,
    List<TmuxWindow> windows,
  ) async {
    final target = _pendingInitialTmuxWindowTarget;
    if (target == null || target.sessionName != sessionName) {
      return;
    }
    final targetWindow = target.windowId == null
        ? windows
              .where((window) => window.index == target.windowIndex)
              .firstOrNull
        : windows.where((window) => window.id == target.windowId).firstOrNull;
    if (targetWindow == null) {
      return;
    }
    _pendingInitialTmuxWindowTarget = null;
    try {
      await _switchTmuxWindow(
        session,
        targetWindow.index,
        windowId: target.windowId,
        forceVisibleTmux: target.requiresVisibleSession,
        deferPostSwitchExec: false,
      );
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      _showTmuxActionFailure(error, TmuxSwitchWindowAction(targetWindow.index));
    }
  }

  String? _resolveStoredAutoConnectCommand(Host? host) {
    if (host == null) {
      return null;
    }
    if (host.autoConnectSnippetId != null) {
      return host.autoConnectCommand;
    }
    if (_hasUnsupportedAutoConnectAgentPreset) {
      return null;
    }
    final preset = _autoConnectAgentPreset;
    if (preset == null) {
      return host.autoConnectCommand;
    }
    try {
      return buildAgentLaunchCommand(
        preset,
        startInYoloMode: _startClisInYoloMode,
      );
    } on FormatException {
      return host.autoConnectCommand;
    }
  }

  /// Wraps the terminal view with the inline tmux window controls.
  ///
  /// Wide layouts use a collapsible left side panel. Narrow layouts keep the
  /// bottom bar: when tmux is active, the terminal gets bottom padding equal
  /// to the handle height so the collapsed handle sits over empty space; when
  /// expanded, the bar slides up over the terminal content. When tmux is not
  /// active, the terminal fills the entire space.
  Widget _buildTerminalWithTmuxBar(
    TerminalThemeData terminalTheme,
    bool isMobile,
    ThemeData theme,
    SshConnectionState connectionState,
  ) {
    final showTmux =
        _isTmuxActive &&
        _showTmuxBar &&
        connectionState == SshConnectionState.connected;
    final configuredMuxExpected = _reserveMuxChromeBeforeActivation;

    return LayoutBuilder(
      builder: (context, constraints) {
        _terminalViewportLayoutSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final tmuxBarSafeInsets = resolveTmuxBarSafeInsets(
          MediaQuery.of(context),
        );
        final tmuxBarAvailableWidth = max(
          0,
          constraints.maxWidth - tmuxBarSafeInsets.horizontal,
        ).toDouble();
        final expectedTmuxBarPlacement = showTmux || configuredMuxExpected
            ? resolveTmuxBarPlacement(tmuxBarAvailableWidth)
            : TmuxBarPlacement.bottomOverlay;
        final tmuxBarPlacement = showTmux
            ? expectedTmuxBarPlacement
            : TmuxBarPlacement.bottomOverlay;
        final availableHeight = max(
          0,
          constraints.maxHeight - tmuxBarSafeInsets.bottom,
        ).toDouble();
        _terminalViewportReservedWidth =
            expectedTmuxBarPlacement == TmuxBarPlacement.sidebar
            ? resolveTmuxSidebarWidth(
                isExpanded: _isTmuxBarExpanded,
                dragOffset: _tmuxSidebarDragOffset,
              )
            : 0.0;
        _terminalViewportReservedBottomPadding =
            expectedTmuxBarPlacement == TmuxBarPlacement.bottomOverlay &&
                (showTmux || configuredMuxExpected)
            ? _TmuxExpandableBar.handleHeight + tmuxBarSafeInsets.bottom
            : 0.0;

        if (tmuxBarPlacement == TmuxBarPlacement.sidebar) {
          return _buildTerminalWithTmuxSidebar(
            terminalTheme,
            isMobile,
            theme,
            connectionState,
            availableHeight: availableHeight,
            safeInsets: tmuxBarSafeInsets,
          );
        }

        final targetBottomPadding = showTmux
            ? _TmuxExpandableBar.handleHeight + tmuxBarSafeInsets.bottom
            : 0.0;

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetBottomPadding),
          duration: _tmuxBarRevealDuration,
          curve: Curves.easeOutCubic,
          child: _buildTmuxExpandableBar(
            theme,
            availableHeight,
            placement: TmuxBarPlacement.bottomOverlay,
          ),
          builder: (context, animatedBottomPadding, child) {
            final barOpacity = resolveTmuxBarRevealOpacity(
              animatedBottomPadding,
            );
            final reservedBottomPadding = showTmux
                ? targetBottomPadding
                : animatedBottomPadding;

            return Stack(
              children: [
                // Reserve actual layout space for the collapsed handle so the
                // terminal viewport ends exactly at the handle boundary.
                Positioned.fill(
                  child: ColoredBox(
                    color: terminalTheme.background,
                    child: Column(
                      children: [
                        Expanded(
                          child: _buildTerminalView(
                            terminalTheme,
                            isMobile,
                            connectionState,
                          ),
                        ),
                        SizedBox(height: reservedBottomPadding),
                      ],
                    ),
                  ),
                ),
                if (showTmux && _isTmuxBarExpanded)
                  Positioned.fill(
                    child: Listener(
                      key: const ValueKey('tmux-terminal-dismiss-region'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => _collapseTmuxBarIfExpanded(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                if (showTmux || animatedBottomPadding > 0)
                  Positioned(
                    left: tmuxBarSafeInsets.left,
                    right: tmuxBarSafeInsets.right,
                    bottom: resolveTmuxBarRevealBottomOffset(
                      animatedBottomPadding,
                    ),
                    child: IgnorePointer(
                      ignoring: barOpacity == 0,
                      child: Opacity(
                        opacity: barOpacity,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTerminalWithTmuxSidebar(
    TerminalThemeData terminalTheme,
    bool isMobile,
    ThemeData theme,
    SshConnectionState connectionState, {
    required double availableHeight,
    required EdgeInsets safeInsets,
  }) {
    final sidebarWidth = resolveTmuxSidebarWidth(
      isExpanded: _isTmuxBarExpanded,
      dragOffset: _tmuxSidebarDragOffset,
    );

    return ColoredBox(
      color: terminalTheme.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: safeInsets.left),
          SizedBox(
            width: sidebarWidth,
            child: _buildTmuxExpandableBar(
              theme,
              availableHeight,
              placement: TmuxBarPlacement.sidebar,
            ),
          ),
          Expanded(
            child: _buildTerminalViewWithConsumedLeftSafeInset(
              terminalTheme,
              isMobile,
              connectionState,
              consumedLeftSafeInset: safeInsets.left,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalViewWithConsumedLeftSafeInset(
    TerminalThemeData terminalTheme,
    bool isMobile,
    SshConnectionState connectionState, {
    required double consumedLeftSafeInset,
  }) {
    final terminalView = _buildTerminalView(
      terminalTheme,
      isMobile,
      connectionState,
    );
    if (consumedLeftSafeInset <= 0) {
      return terminalView;
    }

    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        padding: EdgeInsets.fromLTRB(
          0,
          mediaQuery.padding.top,
          mediaQuery.padding.right,
          mediaQuery.padding.bottom,
        ),
        viewPadding: EdgeInsets.fromLTRB(
          0,
          mediaQuery.viewPadding.top,
          mediaQuery.viewPadding.right,
          mediaQuery.viewPadding.bottom,
        ),
      ),
      child: terminalView,
    );
  }

  /// Builds the tmux expandable bar for the active terminal layout.
  Widget _buildTmuxExpandableBar(
    ThemeData theme,
    double availableHeight, {
    required TmuxBarPlacement placement,
  }) {
    final connectionId = _connectionId;
    if (connectionId == null || _tmuxSessionName == null) {
      return const SizedBox.shrink();
    }

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return const SizedBox.shrink();

    final monetizationState =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isProUser = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    return _TmuxExpandableBar(
      key: _tmuxBarKey,
      session: session,
      tmuxSessionName: _tmuxSessionName!,
      remoteMultiplexerService: _activeRemoteMultiplexerService,
      activeMuxBackend: _activeMuxBackend,
      tmuxExtraFlags: _activeTmuxExtraFlags,
      availableHeight: availableHeight,
      placement: placement,
      recoveryGeneration: _tmuxBarRecoveryGeneration,
      isProUser: isProUser,
      startClisInYoloMode: _startClisInYoloMode,
      initiallyExpanded: widget.initiallyExpandTmuxWindows,
      ref: ref,
      onAction: _handleTmuxAction,
      onExpandedChanged: _handleTmuxBarExpandedChanged,
      onSidebarDragOffsetChanged: _handleTmuxSidebarDragOffsetChanged,
      onWindowsChanged: (windows) {
        if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
          if (windows.isNotEmpty) {
            _monkeyMuxAttachEstablished = true;
          }
          _syncTerminalProgressFromActiveMonkeyMuxWindow(session, windows);
          _syncActiveNativeAcpMuxWindow(session, windows);
        }
        _syncAutomaticPortForwardProcessRoots(
          session,
          windows,
          sessionName: _tmuxSessionName,
          extraFlags: _activeTmuxExtraFlags,
          queryTmuxPanePids: _activeMuxBackend == RemoteMuxBackend.tmux,
        );
      },
      onWindowStateChanged: _handleTmuxWindowStateChanged,
      onActiveWindowTerminalModeChanged: _handleActiveWindowTerminalModeChanged,
      onWindowLoadStalled: _recoverTmuxWindowPanel,
      onSessionEnded: _handleMuxSessionEnded,
      activeNativeAcpSessionKey: _activeNativeAcpSessionKey,
      scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
        liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
        tmuxWorkingDirectory: _tmuxWorkingDirectory,
        sessionWorkingDirectory: session.workingDirectory,
      ),
    );
  }

  void _syncActiveNativeAcpMuxWindow(
    SshSession session,
    List<TmuxWindow> windows,
  ) {
    final active = windows.where((window) => window.isActive).firstOrNull;
    final bridgeId = active?.nativeAcpBridgeId;
    final providerId = active?.nativeAcpProviderId;
    if (active == null || bridgeId == null || providerId == null) {
      _autoOpenedNativeAcpBridgeId = null;
      return;
    }
    if (_nativeAcpLaunchState != null ||
        _activeNativeAcpSessionKey?.bridgeId == bridgeId ||
        _autoOpenedNativeAcpBridgeId == bridgeId) {
      return;
    }
    _autoOpenedNativeAcpBridgeId = bridgeId;
    unawaited(
      _openServerOwnedNativeAcpWindow(
        session,
        windowIndex: active.index,
        bridgeId: bridgeId,
        providerId: providerId,
        workingDirectory: active.currentPath,
      ),
    );
  }

  void _handleTmuxBarExpandedChanged(bool expanded) {
    if (!mounted) {
      return;
    }
    if (_isTmuxBarExpanded == expanded && _tmuxSidebarDragOffset == 0) {
      return;
    }
    setState(() {
      _isTmuxBarExpanded = expanded;
      _tmuxSidebarDragOffset = 0;
    });
  }

  void _handleTmuxSidebarDragOffsetChanged(double dragOffset) {
    if (!mounted || _tmuxSidebarDragOffset == dragOffset) {
      return;
    }
    setState(() => _tmuxSidebarDragOffset = dragOffset);
  }

  bool _collapseTmuxBarIfExpanded() {
    if (!_isTmuxBarExpanded) {
      return false;
    }
    final collapsed = _tmuxBarKey.currentState?.collapseIfExpanded() ?? false;
    if (!collapsed && mounted) {
      setState(() {
        _isTmuxBarExpanded = false;
        _tmuxSidebarDragOffset = 0;
      });
    }
    return true;
  }

  /// Handles an action from the draggable tmux panel.
  Future<void> _handleTmuxAction(TmuxNavigatorAction action) async {
    final connectionId = _connectionId;
    if (connectionId == null) return;
    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) return;

    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'navigator_action',
      fields: {
        'connectionId': connectionId,
        'action': diagnosticTmuxNavigatorActionKind(action),
      },
    );
    await _performTmuxNavigatorAction(session, action);
  }

  Future<void> _recoverTmuxWindowPanel(
    SshSession session,
    String sessionName,
  ) async {
    if (!mounted ||
        _connectionId != session.connectionId ||
        _tmuxSessionName != sessionName) {
      return;
    }

    final recovered = await _detectTmux(
      session,
      preserveExistingTmuxState: true,
    );
    if (!mounted ||
        _connectionId != session.connectionId ||
        !_isTmuxActive ||
        _tmuxSessionName != sessionName) {
      return;
    }
    if (!recovered) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_recovery_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }

    setState(() => _tmuxBarRecoveryGeneration += 1);
  }

  /// Opens the tmux window navigator bottom sheet and handles the
  /// selected action.
  Future<void> _openTmuxNavigator() => _runExclusiveTerminalAction(
    _TerminalExclusiveAction.tmuxNavigator,
    () async {
      final connectionId = _connectionId;
      if (connectionId == null || _tmuxSessionName == null) return;

      final session = _sessionsNotifier?.getSession(connectionId);
      if (session == null) return;

      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final isProUser = monetizationState.allowsFeature(
        MonetizationFeature.agentLaunchPresets,
      );
      final agentWindowModePreference = await ref
          .read(agentWindowModePreferenceNotifierProvider.notifier)
          .initializedValue();
      if (!mounted) return;
      final currentWindowCount = _currentTmuxWindowsSnapshot?.length ?? 0;
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logMuxNavigatorOpened(
              backend: _telemetryMuxBackendName(_activeMuxBackend),
              windowCount: currentWindowCount,
            ),
      );

      final action = await showTmuxNavigator(
        context: context,
        session: session,
        tmuxSessionName: _tmuxSessionName!,
        remoteMuxBackend: _activeMuxBackend,
        remoteMultiplexerService: _activeRemoteMultiplexerService,
        tmuxExtraFlags: _activeTmuxExtraFlags,
        isProUser: isProUser,
        startClisInYoloMode: _startClisInYoloMode,
        agentWindowModePreference: agentWindowModePreference,
        scopeWorkingDirectory: resolveTmuxAiSessionScopeWorkingDirectory(
          liveTerminalWorkingDirectory: _liveWorkingDirectoryPath,
          tmuxWorkingDirectory: _tmuxWorkingDirectory,
          sessionWorkingDirectory: session.workingDirectory,
        ),
      );

      if (!mounted || action == null) return;

      await _performTmuxNavigatorAction(session, action);
    },
  );

  Future<void> _performTmuxNavigatorAction(
    SshSession session,
    TmuxNavigatorAction action,
  ) async {
    try {
      switch (action) {
        case TmuxUpgradeAction(
          :final feature,
          :final blockedAction,
          :final blockedOutcome,
        ):
          await context.push<void>(
            Uri(
              path: Routes.upgrade,
              queryParameters: <String, String>{
                'feature': feature.name,
                'action': blockedAction,
                'outcome': blockedOutcome,
              },
            ).toString(),
          );
        case TmuxSwitchWindowAction(:final windowIndex, :final windowId):
          await _switchTmuxWindow(session, windowIndex, windowId: windowId);
          if (!mounted) return;
          _showTerminalViewport();
          unawaited(
            ref
                .read(telemetryServiceProvider)
                .logMuxWindowSwitched(
                  backend: _telemetryMuxBackendName(_activeMuxBackend),
                ),
          );
        case TmuxNewWindowAction(
          :final command,
          :final windowName,
          :final agentTool,
        ):
          var launchCommand = command;
          var launchWindowName = windowName;
          if (agentTool?.supportsLaunchProfiles ?? false) {
            final providerId = builtinNativeAcpProvidersByTool()[agentTool];
            final provider = acpBuiltinProviders
                .where((candidate) => candidate.id == providerId)
                .firstOrNull;
            if (provider != null) {
              final profile = await selectAcpLaunchProfile(
                context: context,
                session: session,
                provider: provider,
              );
              if (!mounted || profile == null) return;
              launchCommand = buildAgentToolCommand(
                agentTool!,
                startInYoloMode: _startClisInYoloMode,
                launchProfile: profile.argument,
                windows: session.remoteIsWindows,
              );
              if (profile.showInTitle) {
                launchWindowName = '${agentTool.label} · ${profile.label}';
              }
            }
          }
          await _createTmuxWindow(
            session,
            command: launchCommand,
            name: launchWindowName,
          );
          if (!mounted) return;
          _showTerminalViewport();
          unawaited(
            ref
                .read(telemetryServiceProvider)
                .logMuxWindowCreated(
                  backend: _telemetryMuxBackendName(_activeMuxBackend),
                  hasCommand: launchCommand?.trim().isNotEmpty ?? false,
                ),
          );
        case TmuxNewAcpSessionAction(:final providerId):
          await _startNativeAcpSession(
            session,
            providerId: providerId,
            workingDirectory: resolveNativeAcpNewWindowWorkingDirectory(
              connectionWorkingDirectory: _connectionOpenedWorkingDirectory,
              launchWorkingDirectory: _tmuxLaunchWorkingDirectory,
              hostWorkingDirectory: _host?.tmuxWorkingDirectory,
            ),
          );
        case TmuxOpenAcpSessionAction(:final key):
          _openNativeAcpSession(key);
        case TmuxOpenAcpWindowAction(
          :final windowIndex,
          :final bridgeId,
          :final providerId,
          :final workingDirectory,
        ):
          await _openServerOwnedNativeAcpWindow(
            session,
            windowIndex: windowIndex,
            bridgeId: bridgeId,
            providerId: providerId,
            workingDirectory: workingDirectory,
          );
        case TmuxCloseAcpSessionAction(:final key):
          await ref.read(acpSessionManagerProvider).stopSession(key);
          _nativeAcpScrollStates.remove(key.value);
          if (mounted && _activeNativeAcpSessionKey == key) {
            _showTerminalViewport();
          }
        case TmuxResumeAcpSessionAction(
          :final providerId,
          :final acpSessionId,
          :final workingDirectory,
        ):
          await _startNativeAcpSession(
            session,
            providerId: providerId,
            workingDirectory: workingDirectory,
            resumeSessionId: acpSessionId,
          );
        case TmuxResumeSessionAction(
          :final resumeCommand,
          :final workingDirectory,
        ):
          await _createTmuxWindow(
            session,
            command: resumeCommand,
            workingDirectory: workingDirectory,
          );
          if (!mounted) return;
          _showTerminalViewport();
          final tool = agentLaunchToolForCommandText(resumeCommand);
          unawaited(
            ref
                .read(telemetryServiceProvider)
                .logSessionHistorySelected(tool: tool?.name ?? 'unknown'),
          );
          unawaited(
            ref
                .read(telemetryServiceProvider)
                .logAgentLaunchUsed(
                  tool: tool?.name ?? 'unknown',
                  usedSessionHistory: true,
                  usesMux: true,
                ),
          );
        case TmuxCloseWindowAction(:final windowIndex, :final windowId):
          final closingWindow = _resolveTmuxWindowByTarget(
            windowIndex,
            windowId: windowId,
          );
          if (!(closingWindow?.isNativeAcp ?? false)) {
            await _closeTmuxWindow(session, windowIndex, windowId: windowId);
            break;
          }

          final bridgeId = closingWindow!.nativeAcpBridgeId!;
          final manager = ref.read(acpSessionManagerProvider);
          final closingKeys = manager.state.sessions
              .where(
                (nativeSession) =>
                    nativeSession.key.hostId == session.hostId &&
                    nativeSession.key.bridgeId == bridgeId,
              )
              .map((nativeSession) => nativeSession.key)
              .toList(growable: false);

          // The mux close owns remote bridge termination. Keep every local
          // controller and concurrency lease until that close is confirmed so
          // a transport/control failure leaves a retryable, still-accounted
          // native window instead of an untracked provider.
          await _closeTmuxWindow(session, windowIndex, windowId: windowId);
          if (_activeNativeAcpSessionKey?.bridgeId == bridgeId) {
            _showTerminalViewport();
          }
          await manager.releaseSessionsForClosingMuxWindow(
            hostId: session.hostId,
            bridgeId: bridgeId,
          );
          for (final key in closingKeys) {
            _nativeAcpScrollStates.remove(key.value);
          }
      }
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'navigator_action_failed',
        fields: {
          'connectionId': session.connectionId,
          'action': diagnosticTmuxNavigatorActionKind(action),
          'errorType': error.runtimeType,
        },
      );
      _showTmuxActionFailure(error, action);
      if (action is TmuxCloseWindowAction) {
        rethrow;
      }
    }
  }

  Future<
    ({AcpLaunchCommand? override, bool terminal, AcpLaunchProfile? profile})?
  >
  _resolveNativeAdapterLaunch(SshSession session, String providerId) async {
    final provider = acpBuiltinProviders
        .where((candidate) => candidate.id == providerId)
        .firstOrNull;
    if (provider == null) {
      return (override: null, terminal: false, profile: null);
    }
    AcpLaunchProfile? selectedProfile;
    final launch = await resolveAcpRemoteProviderLaunch(
      context: context,
      session: session,
      provider: provider,
      canUseTerminalCli: agentLaunchToolForAcpProviderId(providerId) != null,
      startInYoloMode: _startClisInYoloMode,
      onProfileSelected: (profile) => selectedProfile = profile,
    );
    if (launch == null) return null;
    return (
      override: launch.override,
      terminal: launch.terminal,
      profile: selectedProfile,
    );
  }

  String? _nativeProfileDisplayLabel(
    String providerId,
    AcpLaunchProfile? profile,
  ) {
    if (profile == null || !profile.showInTitle) return null;
    final provider = acpBuiltinProviders
        .where((candidate) => candidate.id == providerId)
        .firstOrNull;
    return '${provider?.label ?? 'Agent'} · ${profile.label}';
  }

  void _beginNativeAcpLaunch(SshSession session, _NativeAcpLaunchState launch) {
    session.setTerminalParsingPaused(paused: true);
    setState(() => _nativeAcpLaunchState = launch);
    _collapseTmuxBarIfExpanded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _nativeAcpLaunchState?.generation != launch.generation) {
        return;
      }
      DiagnosticsLogService.instance.info(
        'acp.launch',
        'visual_ready',
        fields: {
          'connectionId': session.connectionId,
          'durationMs': DateTime.now()
              .difference(launch.startedAt)
              .inMilliseconds,
        },
      );
    });
  }

  void _updateNativeAcpLaunchPhase(
    int generation,
    _NativeAcpLaunchPhase phase,
  ) {
    if (!mounted || _nativeAcpLaunchState?.generation != generation) return;
    setState(() {
      _nativeAcpLaunchState = _nativeAcpLaunchState!.copyWith(phase: phase);
    });
  }

  void _finishNativeAcpLaunch(SshSession session, int generation) {
    if (!mounted || _nativeAcpLaunchState?.generation != generation) return;
    final launch = _nativeAcpLaunchState!;
    final hasActiveNativeSession = _activeNativeAcpSessionKey != null;
    DiagnosticsLogService.instance.info(
      'acp.launch',
      'visual_finished',
      fields: {
        'connectionId': session.connectionId,
        'durationMs': DateTime.now()
            .difference(launch.startedAt)
            .inMilliseconds,
        'openedSession': false,
      },
    );
    setState(() => _nativeAcpLaunchState = null);
    if (hasActiveNativeSession) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _nativeAcpLaunchState != null ||
          _activeNativeAcpSessionKey != null) {
        return;
      }
      session.setTerminalParsingPaused(paused: false);
      _probeAndForceMuxWindowRefresh();
    });
  }

  Future<void> _startNativeAcpSession(
    SshSession session, {
    String? providerId,
    String? workingDirectory,
    String? resumeSessionId,
  }) async {
    if (providerId == null || _activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return _performNativeAcpSessionStart(
        session,
        providerId: providerId,
        workingDirectory: workingDirectory,
        resumeSessionId: resumeSessionId,
      );
    }
    if (_nativeAcpLaunchState != null) return;
    final provider = acpBuiltinProviders
        .where((candidate) => candidate.id == providerId)
        .firstOrNull;
    final generation = ++_nativeAcpLaunchGeneration;
    _beginNativeAcpLaunch(
      session,
      _NativeAcpLaunchState(
        generation: generation,
        providerId: providerId,
        providerLabel: provider?.label ?? 'Native agent',
        phase: _NativeAcpLaunchPhase.resolvingAdapter,
        resuming: resumeSessionId != null,
        startedAt: DateTime.now(),
      ),
    );
    try {
      await _performNativeAcpSessionStart(
        session,
        providerId: providerId,
        workingDirectory: workingDirectory,
        resumeSessionId: resumeSessionId,
        launchGeneration: generation,
      );
    } finally {
      _finishNativeAcpLaunch(session, generation);
    }
  }

  Future<void> _performNativeAcpSessionStart(
    SshSession session, {
    String? providerId,
    String? workingDirectory,
    String? resumeSessionId,
    int? launchGeneration,
  }) async {
    if (_activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Native agent sessions require MonkeyMux.'),
          ),
        );
      }
      return;
    }

    // The generic native-provider action still needs a picker. A tool chosen
    // from the MonkeyMux new-window menu already supplies its provider and
    // should launch immediately, exactly like a terminal mux window.
    if (providerId == null) {
      final key = await showAcpNewSessionSheet(
        context,
        initialHostId: session.hostId,
        initialWorkingDirectory: workingDirectory,
        lockHost: true,
      );
      if (mounted && key != null) {
        _openNativeAcpSession(key);
      }
      return;
    }

    final adapterLaunch = await _resolveNativeAdapterLaunch(
      session,
      providerId,
    );
    if (!mounted || adapterLaunch == null) return;
    if (launchGeneration != null) {
      _updateNativeAcpLaunchPhase(
        launchGeneration,
        _NativeAcpLaunchPhase.startingSession,
      );
    }
    if (adapterLaunch.terminal) {
      final tool = agentLaunchToolForAcpProviderId(providerId);
      if (tool != null) {
        await _createTmuxWindow(
          session,
          command: buildAgentToolCommand(tool),
          workingDirectory: workingDirectory,
          name: tool.commandName,
        );
      }
      return;
    }

    final manager = ref.read(acpSessionManagerProvider);
    final cwd = workingDirectory?.trim().isNotEmpty ?? false
        ? workingDirectory!.trim()
        : (_workingDirectoryPath ?? _host?.tmuxWorkingDirectory ?? '~');

    Future<AcpSessionLaunchResult> launch({
      List<AcpSessionKey> replace = const <AcpSessionKey>[],
    }) => resumeSessionId == null
        ? manager.startNewSession(
            hostId: session.hostId,
            providerId: providerId,
            cwd: cwd,
            confirmInstall: (request) =>
                confirmAcpMonkeyMuxInstall(context, request),
            launchCommandOverride: adapterLaunch.override,
            providerLabelOverride: _nativeProfileDisplayLabel(
              providerId,
              adapterLaunch.profile,
            ),
            autoApprovePermissions: _startClisInYoloMode,
            replace: replace,
          )
        : manager.resumeProviderSession(
            hostId: session.hostId,
            providerId: providerId,
            acpSessionId: resumeSessionId,
            cwd: cwd,
            confirmInstall: (request) =>
                confirmAcpMonkeyMuxInstall(context, request),
            launchCommandOverride: adapterLaunch.override,
            providerLabelOverride: _nativeProfileDisplayLabel(
              providerId,
              adapterLaunch.profile,
            ),
            autoApprovePermissions: _startClisInYoloMode,
            replace: replace,
          );

    var result = await launch();
    if (result is AcpSessionLaunchBlocked && mounted) {
      final choice = await showAcpConcurrencyChoice(
        context,
        decision: result.decision,
        managerState: manager.state,
      );
      if (!mounted || choice == null) {
        return;
      }
      switch (choice) {
        case AcpConcurrencyChoice.stopAndContinue:
          final blocking = [
            for (final value in result.decision.blockingSessionKeys)
              manager.state.byKeyValue(value)?.key,
          ].whereType<AcpSessionKey>().toList(growable: false);
          result = await launch(replace: blocking);
        case AcpConcurrencyChoice.upgrade:
          await context.push<void>(
            Uri(
              path: '/upgrade',
              queryParameters: {
                'feature': MonetizationFeature.concurrentAcpSessions.name,
              },
            ).toString(),
          );
          if (!mounted ||
              !ref
                  .read(monetizationServiceProvider)
                  .currentState
                  .isProUnlocked) {
            return;
          }
          result = await launch();
      }
    }
    if (!mounted) {
      return;
    }
    switch (result) {
      case AcpSessionLaunchStarted(:final key):
        _openNativeAcpSession(key);
      case AcpSessionLaunchFailed(:final error):
        final authCommand = acpTerminalAuthCommandFor(providerId);
        final unlocksCursorKeychain =
            providerId == AcpBuiltinProviderIds.cursorAgent &&
            error.kind == AcpSessionErrorKind.authenticationRequired;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message),
            action: authCommand == null
                ? null
                : SnackBarAction(
                    label: unlocksCursorKeychain
                        ? 'Unlock keychain'
                        : 'Copy sign-in',
                    onPressed: () {
                      if (unlocksCursorKeychain) {
                        unawaited(
                          _createTmuxWindow(
                            session,
                            command: authCommand.argv.join(' '),
                            name: 'Unlock keychain',
                            workingDirectory: workingDirectory,
                          ),
                        );
                        return;
                      }
                      unawaited(
                        Clipboard.setData(
                          ClipboardData(text: authCommand.argv.join(' ')),
                        ),
                      );
                    },
                  ),
          ),
        );
      case AcpSessionLaunchBlocked():
    }
  }

  Future<void> _openServerOwnedNativeAcpWindow(
    SshSession sshSession, {
    required int windowIndex,
    required String bridgeId,
    required String providerId,
    String? workingDirectory,
    int? requestGeneration,
  }) {
    final opening = _openingNativeAcpWindow;
    if (opening != null &&
        _openingNativeAcpBridgeId == bridgeId &&
        _openingNativeAcpRequestGeneration ==
            _nativeAcpWindowRequestGeneration) {
      return opening;
    }
    if (opening != null && requestGeneration == null) {
      final cancellation = _nativeAcpWindowCancellation;
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
    }
    final requestedGeneration =
        requestGeneration ?? ++_nativeAcpWindowRequestGeneration;
    if (requestGeneration != null &&
        requestGeneration != _nativeAcpWindowRequestGeneration) {
      return Future<void>.value();
    }
    if (opening != null) {
      final settledOpening = opening.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return settledOpening.then(
        (_) => _openServerOwnedNativeAcpWindow(
          sshSession,
          windowIndex: windowIndex,
          bridgeId: bridgeId,
          providerId: providerId,
          workingDirectory: workingDirectory,
          requestGeneration: requestedGeneration,
        ),
      );
    }

    final completer = Completer<void>();
    final cancellation = Completer<void>();
    _openingNativeAcpBridgeId = bridgeId;
    _openingNativeAcpRequestGeneration = requestedGeneration;
    _openingNativeAcpWindow = completer.future;
    _nativeAcpWindowCancellation = cancellation;
    _autoOpenedNativeAcpBridgeId = bridgeId;
    final provider = acpBuiltinProviders
        .where((candidate) => candidate.id == providerId)
        .firstOrNull;
    final generation = ++_nativeAcpLaunchGeneration;
    _beginNativeAcpLaunch(
      sshSession,
      _NativeAcpLaunchState(
        generation: generation,
        providerId: providerId,
        providerLabel: provider?.label ?? 'Native agent',
        phase: _NativeAcpLaunchPhase.startingSession,
        resuming: true,
        startedAt: DateTime.now(),
      ),
    );
    unawaited(() async {
      try {
        await _performOpenServerOwnedNativeAcpWindow(
          sshSession,
          windowIndex: windowIndex,
          bridgeId: bridgeId,
          providerId: providerId,
          workingDirectory: workingDirectory,
          requestGeneration: requestedGeneration,
          cancellation: cancellation.future,
        );
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_openingNativeAcpWindow, completer.future)) {
          _openingNativeAcpWindow = null;
          _openingNativeAcpBridgeId = null;
          _openingNativeAcpRequestGeneration = null;
        }
        if (identical(_nativeAcpWindowCancellation, cancellation)) {
          _nativeAcpWindowCancellation = null;
        }
        _finishNativeAcpLaunch(sshSession, generation);
      }
    }());
    return completer.future;
  }

  Future<void> _performOpenServerOwnedNativeAcpWindow(
    SshSession sshSession, {
    required int windowIndex,
    required String bridgeId,
    required String providerId,
    required int requestGeneration,
    required Future<void> cancellation,
    String? workingDirectory,
  }) async {
    bool requestIsCurrent() =>
        mounted && requestGeneration == _nativeAcpWindowRequestGeneration;
    if (!requestIsCurrent()) return;
    final manager = ref.read(acpSessionManagerProvider);
    final tracked = manager.state.sessions
        .where(
          (session) =>
              session.key.hostId == sshSession.hostId &&
              session.key.bridgeId == bridgeId &&
              session.key.providerId == providerId,
        )
        .firstOrNull;
    if (tracked != null && tracked.isLive) {
      await _switchTmuxWindow(
        sshSession,
        windowIndex,
        suppressTerminalReplay: true,
      );
      if (!mounted || requestGeneration != _nativeAcpWindowRequestGeneration) {
        return;
      }
      _openNativeAcpSession(tracked.key);
      return;
    }

    final List<MonkeyMuxAcpBridgeMetadata> bridges;
    try {
      bridges = await manager.listRemoteBridges(sshSession.hostId);
    } on Object catch (error) {
      if (!mounted || requestGeneration != _nativeAcpWindowRequestGeneration) {
        return;
      }
      DiagnosticsLogService.instance.warning(
        'acp.window',
        'remote_lookup_failed',
        fields: {'hostId': sshSession.hostId, 'errorType': error.runtimeType},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The native agent window is unavailable.'),
        ),
      );
      return;
    }
    if (!mounted || requestGeneration != _nativeAcpWindowRequestGeneration) {
      return;
    }
    final bridge = bridges
        .where((candidate) => candidate.id == bridgeId)
        .firstOrNull;
    final remoteSessionId = bridge?.sessionId?.trim();
    AcpRecentSessionRef? recent;
    if ((remoteSessionId == null || remoteSessionId.isEmpty) &&
        tracked == null) {
      final recents = await manager.loadRecentSessions();
      if (!requestIsCurrent()) return;
      recent = recents
          .where(
            (candidate) =>
                candidate.hostId == sshSession.hostId &&
                candidate.bridgeId == bridgeId &&
                candidate.providerId == providerId,
          )
          .firstOrNull;
    }
    if (!mounted || requestGeneration != _nativeAcpWindowRequestGeneration) {
      return;
    }
    final acpSessionId = remoteSessionId?.isNotEmpty ?? false
        ? remoteSessionId!
        : tracked?.key.acpSessionId ?? recent?.acpSessionId;
    if (acpSessionId == null || acpSessionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The native agent window is no longer running.'),
        ),
      );
      return;
    }

    final bridgeNeedsReplacement =
        bridge == null ||
        bridge.state == MonkeyMuxAcpProviderState.exited ||
        bridge.state == MonkeyMuxAcpProviderState.stopped ||
        bridge.state == MonkeyMuxAcpProviderState.protocolError;
    if (bridgeNeedsReplacement) {
      DiagnosticsLogService.instance.info(
        'acp.window',
        'stale_bridge_recovery_start',
        fields: {
          'hostId': sshSession.hostId,
          'hadRemoteBridge': bridge != null,
          'hadTrackedSession': tracked != null,
          'hadRecentSession': recent != null,
        },
      );
    }

    await _switchTmuxWindow(
      sshSession,
      windowIndex,
      suppressTerminalReplay: true,
    );
    if (!mounted || requestGeneration != _nativeAcpWindowRequestGeneration) {
      return;
    }

    final bridgeCwd = bridge?.cwd?.trim();
    final trackedCwd = tracked?.cwd.trim();
    final recentCwd = recent?.cwd?.trim();
    final cwd = bridgeCwd?.isNotEmpty ?? false
        ? bridgeCwd!
        : (trackedCwd?.isNotEmpty ?? false)
        ? trackedCwd!
        : (recentCwd?.isNotEmpty ?? false)
        ? recentCwd!
        : (workingDirectory?.trim().isNotEmpty ?? false)
        ? workingDirectory!.trim()
        : (_workingDirectoryPath ?? _host?.tmuxWorkingDirectory ?? '~');
    Future<AcpSessionLaunchResult> reconnect({
      List<AcpSessionKey> replace = const <AcpSessionKey>[],
    }) => manager.reconnectSession(
      hostId: sshSession.hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
      cwd: cwd,
      confirmInstall: (request) => confirmAcpMonkeyMuxInstall(context, request),
      autoApprovePermissions: _startClisInYoloMode,
      knownRemoteBridge: bridge,
      replace: replace,
    );

    final provisionalKey = AcpSessionKey.of(
      hostId: sshSession.hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );

    Future<AcpSessionLaunchResult> reconnectWithTransportRetry({
      List<AcpSessionKey> replace = const <AcpSessionKey>[],
    }) async {
      const retryDelays = <Duration>[
        Duration(milliseconds: 150),
        Duration(milliseconds: 350),
        Duration(milliseconds: 700),
      ];
      bool isTransportFailure(AcpSessionLaunchResult candidate) =>
          switch (candidate) {
            AcpSessionLaunchFailed(
              error: AcpSessionError(
                kind: AcpSessionErrorKind.transport,
                retryable: true,
              ),
            ) =>
              true,
            _ => false,
          };

      var result = await reconnect(replace: replace);
      for (
        var retryAttempt = 0;
        retryAttempt < retryDelays.length && isTransportFailure(result);
        retryAttempt++
      ) {
        DiagnosticsLogService.instance.info(
          'acp.window',
          'foreground_transport_retry',
          fields: {
            'hostId': sshSession.hostId,
            'bridgeId': bridgeId,
            'attempt': retryAttempt + 1,
          },
        );
        final canceled = await Future.any<bool>([
          Future<void>.delayed(retryDelays[retryAttempt]).then((_) => false),
          cancellation.then((_) => true),
        ]);
        if (canceled ||
            !requestIsCurrent() ||
            _activeNativeAcpSessionKey != provisionalKey) {
          return result;
        }
        // Replacement is a destructive concurrency resolution. Apply it once;
        // transport retries must not stop a session that reconnected meanwhile.
        result = await reconnect();
      }
      return result;
    }

    _nativeAcpReconnectOwnedKeyValue = provisionalKey.value;
    _openNativeAcpSession(provisionalKey);
    DiagnosticsLogService.instance.info(
      'acp.window',
      'native_shell_opened',
      fields: {'hostId': sshSession.hostId},
    );

    Future<bool> restoreTerminalAfterFailedHandoff({
      bool allowSuperseded = false,
    }) async {
      if (!mounted ||
          (!allowSuperseded &&
              requestGeneration != _nativeAcpWindowRequestGeneration) ||
          _activeNativeAcpSessionKey != provisionalKey) {
        return false;
      }
      try {
        // The native selection suppressed its hidden placeholder replay. Before
        // exposing the terminal again, select normally so MonkeyMux sends a
        // coherent frame instead of leaving the previous window frozen.
        await _switchTmuxWindow(sshSession, windowIndex);
      } on Object catch (error) {
        DiagnosticsLogService.instance.debug(
          'acp.window',
          'terminal_replay_restore_failed',
          fields: {'hostId': sshSession.hostId, 'errorType': error.runtimeType},
        );
      }
      if (mounted && _activeNativeAcpSessionKey == provisionalKey) {
        _showTerminalViewport();
        return true;
      }
      return false;
    }

    try {
      var result = await reconnectWithTransportRetry();
      if (!requestIsCurrent()) {
        await restoreTerminalAfterFailedHandoff(allowSuperseded: true);
        return;
      }
      if (result is AcpSessionLaunchBlocked && mounted) {
        final choice = await showAcpConcurrencyChoice(
          context,
          decision: result.decision,
          managerState: manager.state,
          cancellation: cancellation,
        );
        if (!mounted ||
            requestGeneration != _nativeAcpWindowRequestGeneration) {
          await restoreTerminalAfterFailedHandoff(allowSuperseded: true);
          return;
        }
        if (choice == null) {
          await restoreTerminalAfterFailedHandoff();
          return;
        }
        switch (choice) {
          case AcpConcurrencyChoice.stopAndContinue:
            final blocking = [
              for (final value in result.decision.blockingSessionKeys)
                manager.state.byKeyValue(value)?.key,
            ].whereType<AcpSessionKey>().toList(growable: false);
            result = await reconnectWithTransportRetry(replace: blocking);
          case AcpConcurrencyChoice.upgrade:
            await context.push<void>(
              Uri(
                path: '/upgrade',
                queryParameters: {
                  'feature': MonetizationFeature.concurrentAcpSessions.name,
                },
              ).toString(),
            );
            if (!mounted) return;
            if (!ref
                .read(monetizationServiceProvider)
                .currentState
                .isProUnlocked) {
              await restoreTerminalAfterFailedHandoff();
              return;
            }
            result = await reconnectWithTransportRetry();
        }
      }
      if (!mounted) return;
      if (requestGeneration != _nativeAcpWindowRequestGeneration) {
        await restoreTerminalAfterFailedHandoff(allowSuperseded: true);
        return;
      }
      switch (result) {
        case AcpSessionLaunchStarted(:final key):
          if (_activeNativeAcpSessionKey == provisionalKey &&
              key != provisionalKey) {
            _openNativeAcpSession(key);
          }
          if (key.bridgeId != bridgeId) {
            try {
              // A recreated bridge owns a new MonkeyMux window. Remove the
              // dead placeholder so selecting it cannot start another copy.
              await _closeTmuxWindow(
                sshSession,
                windowIndex,
                preserveMuxSession: true,
              );
              DiagnosticsLogService.instance.info(
                'acp.window',
                'stale_window_removed',
                fields: {'hostId': sshSession.hostId},
              );
            } on Object catch (error) {
              DiagnosticsLogService.instance.warning(
                'acp.window',
                'stale_window_remove_failed',
                fields: {
                  'hostId': sshSession.hostId,
                  'errorType': error.runtimeType,
                },
              );
            }
          }
        case AcpSessionLaunchFailed(:final error):
          final restored = await restoreTerminalAfterFailedHandoff();
          if (!mounted || !restored) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.message)));
        case AcpSessionLaunchBlocked():
          await restoreTerminalAfterFailedHandoff();
      }
    } finally {
      if (_nativeAcpReconnectOwnedKeyValue == provisionalKey.value) {
        _nativeAcpReconnectOwnedKeyValue = null;
      }
    }
  }

  void _openNativeAcpSession(AcpSessionKey key) {
    if (!mounted) {
      return;
    }
    if (key.hostId != widget.hostId) {
      unawaited(
        context.push<void>(
          buildAgentChatLocation(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
          ),
        ),
      );
      return;
    }
    (_observedSession ?? _activeSession())?.setTerminalParsingPaused(
      paused: true,
    );
    final launch = _nativeAcpLaunchState;
    if (launch != null) {
      DiagnosticsLogService.instance.info(
        'acp.launch',
        'visual_finished',
        fields: {
          'connectionId': ?_connectionId,
          'durationMs': DateTime.now()
              .difference(launch.startedAt)
              .inMilliseconds,
          'openedSession': true,
        },
      );
    }
    setState(() {
      _nativeAcpLaunchState = null;
      _activeNativeAcpSessionKey = key;
    });
    _persistNativeAcpFocus(key);
    _collapseTmuxBarIfExpanded();
  }

  void _showTerminalViewport() {
    if (!mounted || _activeNativeAcpSessionKey == null) {
      return;
    }
    final session = _observedSession ?? _activeSession();
    // Paint the frozen terminal immediately. Only after that first frame do we
    // resume parsing and request one frame-budgeted MonkeyMux replay, so the
    // viewport switch itself never waits on a large terminal backlog.
    setState(() => _activeNativeAcpSessionKey = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeNativeAcpSessionKey != null) {
        return;
      }
      session?.setTerminalParsingPaused(paused: false);
      _handleTerminalThemeDependenciesChanged(
        forceRemoteRefresh: true,
        reason: 'native_terminal_restored',
      );
      _probeAndForceMuxWindowRefresh();
    });
    final connectionId = _connectionId;
    if (connectionId != null) {
      ref
          .read(activeSessionsProvider.notifier)
          .updateSessionNativeAcpFocus(connectionId, key: null);
    }
    if (!_isMobilePlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _terminalFocusNode.requestFocus();
        }
      });
    }
  }

  void _persistNativeAcpFocus(AcpSessionKey key) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }
    final session = ref
        .read(acpSessionManagerProvider)
        .state
        .byKeyValue(key.value);
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionNativeAcpFocus(
          connectionId,
          key: key,
          displayTitle: session == null
              ? null
              : acpSessionDisplayTitle(session),
        );
  }

  void _updateNativeAcpPreview(AcpSessionKey sessionKey, String? preview) {
    final connectionId = _connectionId;
    if (connectionId == null ||
        _activeNativeAcpSessionKey?.value != sessionKey.value) {
      return;
    }
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionNativeAcpPreview(connectionId, preview);
  }

  void _updateNativeAcpPreviewSnapshot(
    AcpSessionKey sessionKey,
    AcpNativePreviewSnapshot? preview,
  ) {
    final connectionId = _connectionId;
    if (connectionId == null ||
        _activeNativeAcpSessionKey?.value != sessionKey.value) {
      return;
    }
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionNativeAcpPreviewSnapshot(connectionId, preview);
  }

  void _updateNativeAcpScroll(
    AcpSessionKey sessionKey,
    AcpChatScrollState state,
  ) {
    // Refresh insertion order so the bounded map retains recently visited
    // native windows without coupling UI scroll state to transcript/domain data.
    _nativeAcpScrollStates
      ..remove(sessionKey.value)
      ..[sessionKey.value] = state;
    while (_nativeAcpScrollStates.length > 32) {
      _nativeAcpScrollStates.remove(_nativeAcpScrollStates.keys.first);
    }
  }

  void _commitNativeAgentFontSize(double fontSize) {
    final connectionId = _connectionId;
    if (!mounted || connectionId == null) {
      return;
    }
    final next = clampTerminalFontSize(fontSize);
    setState(() => _sessionFontSizeOverride = next);
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionFontSize(connectionId, next);
  }

  Widget _buildNativeAgentStartingView(_NativeAcpLaunchState launch) {
    final detail = switch (launch.phase) {
      _NativeAcpLaunchPhase.resolvingAdapter => 'checking native adapter…',
      _NativeAcpLaunchPhase.startingSession =>
        'opening persistent agent session…',
    };
    return AcpNativeStartingView(
      key: ValueKey<_NativeAcpLaunchPhase>(launch.phase),
      providerLabel: launch.providerLabel,
      detail: detail,
      resuming: launch.resuming,
      tool: agentLaunchToolForAcpProviderId(launch.providerId),
    );
  }

  Widget _buildEmbeddedNativeAgentView(AcpSessionKey key) {
    final globalFontSize = ref.watch(fontSizeNotifierProvider);
    final fontSize = resolveTerminalFontSize(
      globalFontSize: globalFontSize,
      sessionFontSize: _sessionFontSizeOverride,
    );
    final fontFamily =
        _host?.terminalFontFamily ??
        ref.watch(fontFamilyNotifierProvider) ??
        'monospace';
    return AgentChatScreen(
      key: ValueKey<String>('native-agent-${key.value}'),
      hostId: key.hostId,
      providerId: key.providerId,
      bridgeId: key.bridgeId,
      acpSessionId: key.acpSessionId,
      embedded: true,
      connectOnMount: _nativeAcpReconnectOwnedKeyValue != key.value,
      composerFocusController: _nativeComposerFocusController,
      preferredFontSize: fontSize,
      preferredFontFamily: fontFamily,
      onFontSizeCommitted: _commitNativeAgentFontSize,
      onExitEmbedded: _showTerminalViewport,
      onSessionChanged: _openNativeAcpSession,
      onPreviewChanged: _updateNativeAcpPreview,
      onNativePreviewChanged: _updateNativeAcpPreviewSnapshot,
      initialScrollState: _nativeAcpScrollStates[key.value],
      onScrollChanged: _updateNativeAcpScroll,
    );
  }

  void _showTmuxActionFailure(Object error, TmuxNavigatorAction action) {
    if (!mounted) return;
    final isAcpAction =
        action is TmuxNewAcpSessionAction ||
        action is TmuxOpenAcpSessionAction ||
        action is TmuxCloseAcpSessionAction;
    final message = switch (error) {
      TimeoutException() when isAcpAction =>
        'Timed out waiting for the native agent. Reconnect and try again.',
      TimeoutException() =>
        'Timed out waiting for tmux. Reconnect if actions keep failing.',
      _ when isAcpAction =>
        'Native agent action failed. Check the session and try again.',
      _ => 'tmux action failed. Check the session and try again.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleMuxSessionEnded(
    SshSession session,
    String sessionName,
  ) async {
    if (!mounted ||
        _activeMuxBackend != RemoteMuxBackend.monkeyMux ||
        _connectionId != session.connectionId ||
        _tmuxSessionName != sessionName) {
      return;
    }
    _monkeyMuxReconnectSessionName = null;
    _monkeyMuxReconnectAttachPending = false;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'monkeymux_session_disconnect',
      fields: {'connectionId': session.connectionId},
    );
    await _disconnect();
  }

  Future<bool> _isClosingLastMonkeyMuxWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
  }) async {
    if (_activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return false;
    }
    try {
      final knownWindows = _tmuxBarKey.currentState?.currentWindowsSnapshot;
      final windows = knownWindows != null && knownWindows.isNotEmpty
          ? knownWindows
          : await _activeRemoteMultiplexerService.listWindows(
              session,
              sessionName,
              extraFlags: _activeTmuxExtraFlags,
            );
      return windows.length == 1 &&
          (windowId != null
              ? windows.single.id == windowId
              : windows.single.index == windowIndex);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'monkeymux_last_window_check_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  bool _isExpectedMonkeyMuxFinalCloseError(Object error) {
    if (error is! MonkeyMuxInstallException) {
      return false;
    }
    final message = error.message.toLowerCase();
    return message.contains('control channel closed') ||
        message.contains('control channel unavailable') ||
        message.contains('closed without a response');
  }

  /// Switches to a different tmux window via exec channel.
  ///
  /// Uses an exec channel (not the interactive shell) because
  /// `tmux select-window` is a server operation — the tmux server
  /// notifies all attached clients of the change. Writing to the PTY
  /// would inject the command as input to whatever program is running.
  Future<void> _switchTmuxWindow(
    SshSession session,
    int windowIndex, {
    String? windowId,
    bool forceVisibleTmux = false,
    bool deferPostSwitchExec = true,
    bool suppressTerminalReplay = false,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final backend = _activeTerminalConnectionBackend(session);
    final targetWindowId = windowId != null && isValidTmuxWindowId(windowId)
        ? windowId
        : null;
    final targetWindow = _resolveTmuxWindowByTarget(
      windowIndex,
      windowId: targetWindowId,
    );
    if (backend.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      session.clearTerminalProgress();
    }
    if (targetWindowId == null) {
      await backend.selectWindow(
        windowIndex,
        clientImageSignatures: _terminal.heldImageSignatures(),
        suppressReplay: suppressTerminalReplay,
      );
    } else {
      await backend.selectWindow(
        windowIndex,
        windowId: targetWindowId,
        clientImageSignatures: _terminal.heldImageSignatures(),
        suppressReplay: suppressTerminalReplay,
      );
    }
    final activeTool =
        targetWindow?.foregroundAgentTool ?? targetWindow?.agentTool;
    if (activeTool != null) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logAgentLaunchUsed(
              tool: activeTool.name,
              usedSessionHistory: false,
              usesMux: true,
            ),
      );
    }
    if (backend.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      _prepareTerminalForMuxWindowChange(clearTerminalProgress: false);
      _refreshTerminalAfterMonkeyMuxWindowChange(session);
      _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
        session: session,
        sessionName: sessionName,
        reason: 'monkeymux_window_switched',
      );
      _refreshMuxPaneContextAfterWindowStateChange(
        session,
        sessionName,
        force: true,
      );
      unawaited(
        _reattachTmuxAfterWindowChangeInBackground(
          session,
          sessionName,
          forceVisibleTmux: forceVisibleTmux,
          deferUntilAfterRedraw: deferPostSwitchExec,
        ),
      );
      return;
    }
    _prepareTerminalForMuxWindowChange();
    if (deferPostSwitchExec) {
      _lastMuxWindowChangeAt = DateTime.now();
      _tmuxService.deferExecsForRedraw(
        session,
        _tmuxPostWindowSwitchExecQuietPeriod,
      );
      unawaited(
        _tmuxService.refreshForegroundClients(
          session,
          sessionName,
          extraFlags: _activeTmuxExtraFlags,
        ),
      );
      if (_tmuxWindowLooksLikeAltBufferTarget(targetWindow)) {
        _refreshTerminalThemeReportsForTui(
          session.terminalTheme ?? _resolveEffectiveTerminalTheme(),
          includeThemeModeReport: false,
          reason: 'tmux_window_switched_immediate_focus',
        );
      }
    }
    // The foreground-client check is a heavy exec shell script that walks this
    // SSH session's process tree to correlate it with tmux's clients (to detect
    // a detached window); it can't run over the control channel and used to block
    // the switch for a few hundred milliseconds. Run it in the background and
    // only resync the size if it actually reattaches.
    _scheduleTerminalSizeRefresh();
    _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
      session: session,
      sessionName: sessionName,
      reason: 'tmux_window_switched',
    );
    unawaited(
      _reattachTmuxAfterWindowChangeInBackground(
        session,
        sessionName,
        forceVisibleTmux: forceVisibleTmux,
        deferUntilAfterRedraw: deferPostSwitchExec,
      ),
    );
  }

  TmuxWindow? _resolveTmuxWindowByTarget(int windowIndex, {String? windowId}) {
    final windows = _currentTmuxWindowsSnapshot;
    if (windows == null) {
      return null;
    }
    if (windowId != null) {
      return windows.where((window) => window.id == windowId).firstOrNull;
    }
    return windows.where((window) => window.index == windowIndex).firstOrNull;
  }

  bool _tmuxWindowLooksLikeAltBufferTarget(TmuxWindow? window) {
    if (window == null) {
      return false;
    }
    return window.foregroundAgentTool != null ||
        window.agentTool != null ||
        (window.terminalReportsMouseWheel ?? false);
  }

  /// Runs the post-window-change tmux reattach recovery without blocking the
  /// switch. tmux already redrew the selected window; this only matters for the
  /// uncommon case where the visible terminal has dropped out of tmux.
  Future<void> _reattachTmuxAfterWindowChangeInBackground(
    SshSession session,
    String sessionName, {
    bool forceVisibleTmux = false,
    bool deferUntilAfterRedraw = true,
  }) async {
    if (deferUntilAfterRedraw && !forceVisibleTmux) {
      final quietPeriod = _remainingMuxWindowSwitchQuietPeriod();
      if (quietPeriod > Duration.zero) {
        await Future<void>.delayed(quietPeriod);
      }
      if (!mounted ||
          _connectionId != session.connectionId ||
          _tmuxSessionName != sessionName) {
        return;
      }
    }
    await _reattachTmuxIfNeeded(
      session,
      sessionName,
      forceVisibleTmux: forceVisibleTmux,
    );
    if (!mounted || _connectionId != session.connectionId) {
      return;
    }
    _scheduleTerminalSizeRefresh();
  }

  /// Creates a new tmux window via exec channel, then reattaches the visible
  /// terminal if tmux is no longer in the foreground there.
  ///
  /// Uses explicit session-resume directories first, then the host's configured
  /// directory. The session launch directory and active pane are fallbacks for
  /// hosts without a configured directory.
  Future<void> _createTmuxWindow(
    SshSession session, {
    String? command,
    String? name,
    String? workingDirectory,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final backend = _activeTerminalConnectionBackend(session);
    final configuredWorkingDirectory = _configuredRemoteMuxWorkingDirectory(
      backend: backend.remoteMuxBackend ?? _activeMuxBackend,
      sessionName: sessionName,
    );
    var resolvedWorkingDirectory = resolveTmuxWindowWorkingDirectory(
      explicitWorkingDirectory: workingDirectory,
      configuredWorkingDirectory: configuredWorkingDirectory,
      launchWorkingDirectory: _tmuxLaunchWorkingDirectory,
    );
    String? currentPaneWorkingDirectory;
    if (resolvedWorkingDirectory == null) {
      currentPaneWorkingDirectory = await backend.currentPanePath();
    }
    if (!mounted) return;
    resolvedWorkingDirectory ??= resolveTmuxWindowWorkingDirectory(
      currentPaneWorkingDirectory: currentPaneWorkingDirectory,
      observedWorkingDirectory: _tmuxWorkingDirectory ?? _workingDirectoryPath,
    );
    if (backend.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      await _syncActiveMonkeyMuxTerminalSize(
        session,
        refreshVisibleTerminal: true,
      );
      if (!mounted) return;
    }
    final tool = agentLaunchToolForCommandText(command);
    await backend.createWindow(
      command: command,
      name: name,
      workingDirectory: resolvedWorkingDirectory,
    );
    if (!mounted) return;
    if (tool != null) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logAgentLaunchUsed(
              tool: tool.name,
              usedSessionHistory: false,
              usesMux: true,
            ),
      );
    }
    _prepareTerminalForMuxWindowChange(
      workingDirectory: resolvedWorkingDirectory,
      clearTerminalProgress:
          backend.remoteMuxBackend != RemoteMuxBackend.monkeyMux,
    );
    if (backend.remoteMuxBackend == RemoteMuxBackend.monkeyMux) {
      _refreshTerminalAfterMonkeyMuxWindowChange(session);
    } else {
      // tmux draws the new window on its own; resync the size and run the
      // foreground-client reattach check in the background instead of blocking
      // the create on its exec round-trip (see _switchTmuxWindow).
      _scheduleTerminalSizeRefresh();
      unawaited(
        _reattachTmuxAfterWindowChangeInBackground(
          session,
          sessionName,
          deferUntilAfterRedraw: false,
        ),
      );
    }
    _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
      session: session,
      sessionName: sessionName,
      reason: 'tmux_window_created',
    );
  }

  /// Closes a tmux window via exec channel.
  Future<void> _closeTmuxWindow(
    SshSession session,
    int windowIndex, {
    String? windowId,
    bool preserveMuxSession = false,
  }) async {
    final sessionName = _tmuxSessionName;
    if (sessionName == null) return;

    final closesLastMonkeyMuxWindow =
        !preserveMuxSession &&
        await _isClosingLastMonkeyMuxWindow(
          session,
          sessionName,
          windowIndex,
          windowId: windowId,
        );
    try {
      await _activeTerminalConnectionBackend(
        session,
      ).killWindow(windowIndex, windowId: windowId);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      if (closesLastMonkeyMuxWindow &&
          _activeMuxBackend == RemoteMuxBackend.monkeyMux &&
          _isExpectedMonkeyMuxFinalCloseError(error)) {
        DiagnosticsLogService.instance.info(
          'tmux.ui',
          'monkeymux_final_close_control_closed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        await _handleMuxSessionEnded(session, sessionName);
        return;
      }
      rethrow;
    }
    if (closesLastMonkeyMuxWindow) {
      await _handleMuxSessionEnded(session, sessionName);
      return;
    }
    final isMonkeyMux = _activeMuxBackend == RemoteMuxBackend.monkeyMux;
    _prepareTerminalForMuxWindowChange(clearTerminalProgress: !isMonkeyMux);
    if (isMonkeyMux) {
      _refreshTerminalAfterMonkeyMuxWindowChange(session);
    } else {
      _scheduleTerminalSizeRefresh();
    }
    _scheduleTmuxTerminalThemeRefreshAfterWindowStateChange(
      session: session,
      sessionName: sessionName,
      reason: 'tmux_window_closed',
    );
  }

  void _syncTerminalProgressFromActiveMonkeyMuxWindow(
    SshSession session,
    Iterable<TmuxWindow> windows,
  ) {
    final activeWindow = windows.where((window) => window.isActive).firstOrNull;
    session.synchronizeTerminalProgress(activeWindow?.terminalProgress);
  }

  void _prepareTerminalForMuxWindowChange({
    String? workingDirectory,
    bool clearTerminalProgress = true,
  }) {
    if (clearTerminalProgress) {
      _observedSession?.clearTerminalProgress();
    }
    _terminalTextInputController.resetImeCompletions();
    _clearTerminalFollowPauseForMuxWindowChange();
    _tmuxWorkingDirectory = workingDirectory;
    _tmuxCurrentCommand = null;
    _shellCompletionTmuxContextRefreshedAt = null;
    _probeAndForceMuxWindowRefresh();
  }

  Duration _remainingMuxWindowSwitchQuietPeriod() {
    final changedAt = _lastMuxWindowChangeAt;
    if (changedAt == null) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(changedAt);
    if (elapsed >= _tmuxPostWindowSwitchExecQuietPeriod) {
      return Duration.zero;
    }
    return _tmuxPostWindowSwitchExecQuietPeriod - elapsed;
  }

  /// Diagnoses and papers over a window-switch refresh that fails to repaint.
  ///
  /// A multiplexer window switch delivers the new window's redraw over the
  /// shell/control channel. In rare, timing-dependent cases the redraw lands in
  /// the terminal buffer but no frame is produced, so the view keeps showing the
  /// previous window until the next output or a resize forces a repaint.
  ///
  /// This captures a baseline of the live render object's paint/change counters,
  /// then a beat later logs the deltas (a frozen frame shows changes advancing
  /// while paints do not) and forces a full repaint as a safety net. A second,
  /// later force catches a redraw that arrives after the first check.
  void _probeAndForceMuxWindowRefresh() {
    final connectionId = _connectionId;
    if (connectionId == null) {
      return;
    }
    final viewState = _terminalViewKey.currentState;
    final baselinePaints = viewState?.terminalPaintCount;
    final baselineChanges = viewState?.terminalChangeCount;

    _muxWindowRefreshProbeTimer?.cancel();
    _muxWindowRefreshProbeTimer = Timer(_muxWindowRefreshProbeDelay, () {
      _muxWindowRefreshProbeTimer = null;
      if (!mounted || _connectionId != connectionId) {
        return;
      }
      final state = _terminalViewKey.currentState;
      DiagnosticsLogService.instance.debug(
        'terminal.refresh',
        'mux_window_refresh_probe',
        fields: {
          'connectionId': connectionId,
          'paintsDelta': _counterDelta(
            baselinePaints,
            state?.terminalPaintCount,
          ),
          'changesDelta': _counterDelta(
            baselineChanges,
            state?.terminalChangeCount,
          ),
        },
      );
      // Read the natural counters above before forcing a paint so the probe
      // reflects whether the switch repainted on its own.
      state?.forceFullRepaint();
      WidgetsBinding.instance.ensureVisualUpdate();
    });

    _muxWindowRefreshSafetyNetTimer?.cancel();
    _muxWindowRefreshSafetyNetTimer = Timer(
      _muxWindowRefreshSafetyNetDelay,
      () {
        _muxWindowRefreshSafetyNetTimer = null;
        if (!mounted || _connectionId != connectionId) {
          return;
        }
        _terminalViewKey.currentState?.forceFullRepaint();
        WidgetsBinding.instance.ensureVisualUpdate();
      },
    );
  }

  static int? _counterDelta(int? baseline, int? current) =>
      (baseline == null || current == null) ? null : current - baseline;

  void _clearTerminalFollowPauseForMuxWindowChange() {
    var shouldRefreshFollowState = false;
    if (_terminalOutputPauseTouchPointers.isNotEmpty) {
      _terminalOutputPauseTouchPointers.clear();
      shouldRefreshFollowState = true;
    }
    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
      shouldRefreshFollowState = true;
    } else if (_terminalController.selection != null) {
      _terminalController.clearSelection();
      shouldRefreshFollowState = true;
    }
    if (!shouldRefreshFollowState) {
      return;
    }
    _syncTerminalLiveOutputAutoScroll();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reattachTmuxIfNeeded(
    SshSession session,
    String sessionName, {
    bool forceVisibleTmux = false,
  }) async {
    final mux = _activeRemoteMultiplexerService;
    if (!forceVisibleTmux && mux.isExecChannelCoolingDown(session)) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'reattach_foreground_check_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }
    var hasForegroundClient = false;
    try {
      hasForegroundClient = await mux.hasForegroundClientOrThrow(
        session,
        sessionName,
        extraFlags: _activeTmuxExtraFlags,
      );
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      if (!forceVisibleTmux) {
        DiagnosticsLogService.instance.warning(
          'tmux.ui',
          'reattach_foreground_check_failed',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        return;
      }
      hasForegroundClient = false;
    }
    if (!mounted || hasForegroundClient) {
      DiagnosticsLogService.instance.info(
        'tmux.ui',
        'reattach_not_needed',
        fields: {
          'connectionId': session.connectionId,
          'hasForegroundClient': hasForegroundClient,
        },
      );
      return;
    }

    final canReattachInCurrentShell = shouldReattachTmuxAfterWindowAction(
      hasForegroundClient: hasForegroundClient,
      shellStatus: _shellStatus,
    );
    final shouldReopenLostMonkeyMux = shouldReopenLostMonkeyMuxAttach(
      backend: _activeMuxBackend,
      attachEstablished: _monkeyMuxAttachEstablished,
      hasForegroundClient: hasForegroundClient,
    );
    if (!canReattachInCurrentShell &&
        !forceVisibleTmux &&
        !shouldReopenLostMonkeyMux) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'tmux updated $sessionName, but this terminal is not safely at '
            'a shell prompt.',
          ),
        ),
      );
      DiagnosticsLogService.instance.warning(
        'tmux.ui',
        'reattach_skipped_shell_not_prompt',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }

    if (forceVisibleTmux && !canReattachInCurrentShell) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Opening tmux alert interrupted the running shell command.',
          ),
        ),
      );
    }

    final host = _host;
    late final String reattachCommand;
    var reattachBackend = RemoteMuxBackend.tmux;
    if (host == null) {
      reattachCommand = buildTmuxCommand(sessionName: sessionName);
    } else {
      final attachCommand = await _buildRemoteMuxAttachCommand(
        session,
        host,
        sessionName,
        preferredBackend: _activeMuxBackend,
        existingOnly: true,
      );
      if (attachCommand == null) {
        return;
      }
      _activeMuxBackend = attachCommand.backend;
      reattachBackend = attachCommand.backend;
      reattachCommand = attachCommand.command;
    }
    final shouldRunMonkeyMuxAttachDirectly =
        reattachBackend == RemoteMuxBackend.monkeyMux &&
        (session.remoteIsWindows || shouldReopenLostMonkeyMux);
    final mustReopenShell =
        shouldRunMonkeyMuxAttachDirectly ||
        (forceVisibleTmux && !canReattachInCurrentShell);
    final requestPty =
        !shouldRunMonkeyMuxAttachDirectly || !session.remoteIsWindows;
    final shell = mustReopenShell
        ? await _reopenShellForVisibleTmux(
            session,
            command: shouldRunMonkeyMuxAttachDirectly ? reattachCommand : null,
            requestPty: requestPty,
          )
        : _shell;
    if (shell == null) {
      return;
    }

    if (!shouldRunMonkeyMuxAttachDirectly) {
      session.writeToShell(formatAutoConnectCommandForShell(reattachCommand));
    }
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'reattach_command_sent',
      fields: {
        'connectionId': session.connectionId,
        'requestedPty': requestPty,
        'directMonkeyMuxAttach': shouldRunMonkeyMuxAttachDirectly,
      },
    );
    final pendingReplacement = _pendingMonkeyMuxServerReplacement;
    if (reattachBackend == RemoteMuxBackend.monkeyMux &&
        pendingReplacement != null &&
        pendingReplacement.connectionId == session.connectionId &&
        pendingReplacement.sessionName == sessionName) {
      _startMonkeyMuxServerReplacementRecovery(session, pendingReplacement);
    }
  }

  Future<SSHSession?> _reopenShellForVisibleTmux(
    SshSession session, {
    String? command,
    bool requestPty = true,
  }) async {
    bool stillOwnsSession() => mounted && identical(session, _activeSession());

    final previousShell = _shell;
    var removedTerminalListener = false;
    var closedExistingShell = false;

    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    unawaited(_shellCommandCompletedSubscription?.cancel());
    _shellCommandCompletedSubscription = null;
    unawaited(_shellStdoutSubscription?.cancel());
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;

    final viewportCellSize = _localTerminalViewportCellSize();
    final pty = SSHPtyConfig(
      width: viewportCellSize.columns,
      height: viewportCellSize.rows,
    );

    final SSHSession shell;
    _isReopeningShell = true;
    try {
      _terminal.removeListener(_onTerminalStateChanged);
      removedTerminalListener = true;
      _shell = null;

      await session.closeShell(waitForStreams: false);
      closedExistingShell = true;
      if (!stillOwnsSession()) {
        return null;
      }

      _applyTerminalThemeToSession(
        _resolveEffectiveTerminalTheme(),
        session: session,
        reason: 'reopen_shell',
      );
      shell = await session.getShell(
        pty: pty,
        requestPty: requestPty,
        command: command,
        returnToLoginShell: command != null,
      );
      if (!stillOwnsSession()) {
        return null;
      }
      final terminal = session.terminal;
      if (terminal == null) {
        return null;
      }

      _terminal = terminal;
      _terminalHyperlinkTracker = session.terminalHyperlinkTracker;
      _isUsingAltBuffer = _terminal.isUsingAltBuffer;
      _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      _terminal.addListener(_onTerminalStateChanged);
      removedTerminalListener = false;
      _shell = shell;
      _wireTerminalCallbacks(session);
    } on Object {
      // Reopen failures are stale after this screen releases the session.
      if (!stillOwnsSession()) {
        return null;
      }
      if (removedTerminalListener) {
        _terminal.addListener(_onTerminalStateChanged);
      }
      if (!closedExistingShell) {
        _shell = previousShell;
      }
      rethrow;
    } finally {
      _isReopeningShell = false;
    }

    if (!stillOwnsSession()) {
      return null;
    }
    final sharedClipboardEnabled = await ref.read(
      sharedClipboardProvider.future,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    final sharedClipboardLocalReadEnabled = await ref.read(
      sharedClipboardLocalReadProvider.future,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    await _applySharedClipboardSetting(
      enabled: sharedClipboardEnabled,
      allowLocalClipboardRead: sharedClipboardLocalReadEnabled,
      session: session,
      waitForInitialSync: false,
    );
    if (!stillOwnsSession()) {
      return null;
    }
    if (mounted) {
      setState(() {
        _isUsingAltBuffer = _terminal.isUsingAltBuffer;
        _terminalReportsMouseWheel = _terminal.mouseMode.reportScroll;
      });
      if (_activeMuxBackend == RemoteMuxBackend.monkeyMux) {
        _refreshTerminalAfterMonkeyMuxWindowChange(session);
      } else {
        _scheduleTerminalSizeRefresh();
      }
    }
    return shell;
  }

  void _handleTrackedConnectionStateChange(
    SshConnectionState? previous,
    SshConnectionState next,
  ) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      _syncTerminalWakeLock(SshConnectionState.disconnected);
      return;
    }

    final previousState = previous ?? SshConnectionState.disconnected;
    final nextState = next;
    _syncTerminalWakeLock(nextState);
    if (previousState == nextState ||
        nextState != SshConnectionState.disconnected) {
      return;
    }

    final suppressAutomaticReconnect =
        _suppressNextAutomaticReconnectConnectionId == connectionId;
    _suppressNextAutomaticReconnectConnectionId = null;
    _rememberMonkeyMuxReconnectTarget(_observedSession);
    _prepareTerminalForLostConnection(_observedSession);
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = !suppressAutomaticReconnect;
      return;
    }
    if (!mounted) {
      return;
    }

    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    _terminalFocusNode.unfocus();
    if (suppressAutomaticReconnect) {
      setState(() {
        _isConnecting = false;
        _error ??= 'Connection closed';
      });
      return;
    }

    DiagnosticsLogService.instance.info(
      'terminal',
      'disconnected_prompt_show',
      fields: {'connectionId': connectionId},
    );
    setState(() {
      _isConnecting = false;
      _error ??= 'Connection closed';
    });
  }

  void _prepareTerminalForLostConnection(SshSession? session) {
    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    unawaited(_shellCommandCompletedSubscription?.cancel());
    _shellCommandCompletedSubscription = null;
    unawaited(_shellStdoutSubscription?.cancel());
    _shellStdoutSubscription = null;
    _promptOutputImeResetTimer?.cancel();
    _promptOutputImeResetTimer = null;
    _stopSharedClipboardSync();
    _hideShellCompletionPopup();
    _clearOwnedTerminalCallbacks();
    _disposeTerminalPathVerificationSftp();
    _sessionController.clearObservedSession(session: session);
    _clearTmuxState();
    _detectedSensitiveKeyboardPrompt = false;
  }

  void _handleShellClosed() {
    final connectionId = _connectionId;
    _rememberMonkeyMuxReconnectTarget(_observedSession ?? _activeSession());
    _shell = null;
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    unawaited(_shellCommandCompletedSubscription?.cancel());
    _shellCommandCompletedSubscription = null;
    _syncTerminalWakeLock(SshConnectionState.disconnected);
    if (!mounted) {
      if (connectionId != null) {
        unawaited(
          _cleanupUnexpectedDisconnect(
            connectionId,
            message: 'Connection closed',
          ),
        );
      }
      return;
    }
    // If the app is in the background, don't show the error screen
    // immediately — defer it so we can auto-reconnect on resume.
    if (_wasBackgrounded) {
      _connectionLostWhileBackgrounded = true;
    } else {
      _suppressNextAutomaticReconnectConnectionId = connectionId;
      setState(() {
        _clearTmuxState();
        _detectedSensitiveKeyboardPrompt = false;
        _isConnecting = false;
        _error = 'Connection closed';
      });
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    }
    // Clean up the session state regardless of background/foreground.
    if (connectionId != null) {
      unawaited(
        _cleanupUnexpectedDisconnect(
          connectionId,
          message: 'Connection closed',
        ),
      );
    }
  }

  Future<void> _cleanupUnexpectedDisconnect(
    int connectionId, {
    required String message,
  }) async {
    await _tmuxService.clearCache(connectionId);
    await _monkeyMuxService.clearCache(connectionId);
    await _sessionsNotifier?.handleUnexpectedDisconnect(
      connectionId,
      message: message,
    );
  }

  Future<void> _disconnect() async {
    final connectionId = _connectionId;
    _connectionId = null;
    _clearAppThemeOverride();
    _cancelTerminalThemeRefreshTimers();
    _clearTmuxState();
    _sessionController.clearObservedSession();
    _disposeTerminalPathVerificationSftp();
    _suppressNextAutomaticReconnectConnectionId = null;
    _syncTerminalWakeLock(SshConnectionState.disconnected);
    unawaited(_doneSubscription?.cancel());
    _doneSubscription = null;
    unawaited(_shellCommandCompletedSubscription?.cancel());
    _shellCommandCompletedSubscription = null;
    _shell = null;
    if (connectionId != null) {
      await _tmuxService.clearCache(connectionId);
      await _monkeyMuxService.clearCache(connectionId);
      await _sessionsNotifier?.disconnect(connectionId);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Abandons the in-flight connection attempt for this terminal's host.
  void _cancelConnectionAttempt() {
    _forcedMonkeyMuxReloadRequest?.cancel();
    _forcedMonkeyMuxReloadRequest = null;
    final cancelled = ref
        .read(activeSessionsProvider.notifier)
        .cancelConnectionAttempt(widget.hostId);
    if (!cancelled && mounted) {
      setState(() {
        _isConnecting = false;
        _connectionCancelled = true;
        _error = 'Connection cancelled';
      });
    }
  }

  Future<void> _reconnect({bool showProgressDialog = true}) async {
    if (_isConnecting) {
      return;
    }
    _rememberMonkeyMuxReconnectTarget(_observedSession ?? _activeSession());
    if (mounted) {
      setState(() {
        _clearTmuxState();
        _isConnecting = true;
        _connectionCancelled = false;
        _error = null;
      });
    } else {
      _clearTmuxState();
      _isConnecting = true;
      _connectionCancelled = false;
      _error = null;
    }

    final previousConnectionId = _connectionId;
    _connectionId = null;
    _clearAppThemeOverride();
    _sessionController.clearObservedSession();
    _disposeTerminalPathVerificationSftp();
    _suppressNextAutomaticReconnectConnectionId = null;
    _syncTerminalWakeLock(SshConnectionState.disconnected);
    _connectionLostWhileBackgrounded = false;
    try {
      await _doneSubscription?.cancel();
      _doneSubscription = null;
      await _shellCommandCompletedSubscription?.cancel();
      _shellCommandCompletedSubscription = null;
      _shell = null;
      if (previousConnectionId != null) {
        await _tmuxService.clearCache(previousConnectionId);
        await _monkeyMuxService.clearCache(previousConnectionId);
        await _sessionsNotifier?.disconnect(previousConnectionId);
      }
      if (!mounted) {
        return;
      }
      await _connect(forceNew: true, showProgressDialog: showProgressDialog);
    } finally {
      if (!mounted) {
        _isConnecting = false;
      }
    }
  }

  void _rememberMonkeyMuxReconnectTarget(SshSession? session) {
    final backend = _isTmuxActive
        ? _activeMuxBackend
        : session?.remoteMuxBackend;
    if (backend != RemoteMuxBackend.monkeyMux) {
      if (session != null) {
        _monkeyMuxReconnectSessionName = null;
        _monkeyMuxReconnectAttachPending = false;
      }
      return;
    }
    final sessionName = (_tmuxSessionName ?? session?.remoteMuxSessionName)
        ?.trim();
    if (sessionName == null || sessionName.isEmpty) {
      return;
    }
    _monkeyMuxReconnectSessionName = sessionName;
    DiagnosticsLogService.instance.info(
      'terminal',
      'monkeymux_reconnect_target_saved',
      fields: {'connectionId': session?.connectionId ?? _connectionId},
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearAppThemeOverride();
    _sharedClipboardSubscription.close();
    _sharedClipboardLocalReadSubscription.close();
    _terminalWakeLockSubscription.close();
    _terminalThemeSettingsSubscription.close();
    _themeModeSubscription.close();
    _shellCompletionsSubscription.close();
    _agentUpdateCheckTimer?.cancel();

    _cancelTerminalThemeRefreshTimers();
    _sessionController.dispose();
    _stopSharedClipboardSync();
    _stopTmuxForegroundVerification();
    _promptOutputImeResetTimer?.cancel();
    _shellCompletionDebounceTimer?.cancel();
    _cancelMonkeyMuxServerReplacementRetry();
    _cancelMonkeyMuxRefreshAndResizeState();
    _muxWindowRefreshProbeTimer?.cancel();
    _muxWindowRefreshSafetyNetTimer?.cancel();
    _missingImageRequestTimer?.cancel();
    _terminalPathVerificationBatchTimer?.cancel();
    _terminalPathUnderlineScrollThrottleTimer?.cancel();
    _disposeTerminalPathVerificationSftp();
    _clearOwnedTerminalCallbacks();
    _terminal.removeListener(_onTerminalStateChanged);
    _terminalController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _doneSubscription?.cancel();
    _shellCommandCompletedSubscription?.cancel();
    _shellStdoutSubscription?.cancel();
    _terminalFocusNode.dispose();
    _systemKeyboardVisibilityController.removeListener(
      _handleTerminalKeyboardVisibilityChanged,
    );
    _terminalTextInputController
      ..removeListener(_handleTerminalKeyboardVisibilityChanged)
      ..dispose();
    _deviceDebugController?.removeListener(_handleDeviceDebugStateChanged);
    _toolbarController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _terminalFocusRestoreGeneration += 1;
      final shouldRestoreKeyboard = state == AppLifecycleState.paused
          ? _dismissTerminalKeyboardForAppBackground()
          : _shouldRestoreTerminalKeyboardAfterTemporaryDismissal;
      _restoreKeyboardAfterAppResume =
          _restoreKeyboardAfterAppResume || shouldRestoreKeyboard;
      _wasBackgrounded = true;
      _monkeyMuxResizeRedrawFollowUpTimer?.cancel();
      _monkeyMuxResizeRedrawFollowUpTimer = null;
      _stopSharedClipboardSync();
      _syncTerminalWakeLock();
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      // Android dismisses the IME when the app loses its window. Asking it
      // to show again from the first resumed callback can be ignored while the
      // old bottom inset remains, leaving a keyboard-sized blank region. Keep
      // the keyboard closed there while restoring terminal focus for hardware
      // input. iOS continues restoring both focus and the keyboard.
      final shouldRestoreTerminalFocus = _restoreKeyboardAfterAppResume;
      final shouldRestoreKeyboard =
          shouldRestoreTerminalFocus && !_isAndroidPlatform;
      _restoreKeyboardAfterAppResume = false;
      _wasBackgrounded = false;
      _syncTerminalWakeLock();
      final session = _observedSession;
      final isWindowsMonkeyMux = _isWindowsMonkeyMuxSession(session);
      final forceThemeRefresh =
          !isWindowsMonkeyMux || _terminalThemeRefreshRequiredAfterResume;
      _terminalThemeRefreshRequiredAfterResume = false;
      if (_isTmuxActive &&
          _activeMuxBackend == RemoteMuxBackend.monkeyMux &&
          session != null) {
        if (isWindowsMonkeyMux) {
          _beginAppResumeTerminalMetricsSettle();
          _refreshTerminalAfterWindowsMonkeyMuxResume();
        } else {
          _refreshTerminalAfterMonkeyMuxWindowChange(session);
        }
      } else {
        _scheduleTerminalSizeRefresh();
      }
      if (session != null && session.clipboardSharingEnabled) {
        unawaited(_startSharedClipboardSync(session));
      }
      if (_connectionLostWhileBackgrounded && mounted) {
        _connectionLostWhileBackgrounded = false;
        _terminal.write('\r\n[reconnecting...]\r\n');
        unawaited(_reconnect(showProgressDialog: false));
      } else if (session != null &&
          _activeNativeAcpSessionKey == null &&
          _nativeAcpLaunchState == null) {
        _handleTerminalThemeDependenciesChanged(
          forceRemoteRefresh: forceThemeRefresh,
          reason: 'app_resumed',
        );
      }
      if (shouldRestoreTerminalFocus) {
        _restoreTerminalFocus(forceShowSystemKeyboard: shouldRestoreKeyboard);
      }
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _handleTerminalThemeDependenciesChanged(
      forceRemoteRefresh: true,
      reason: 'platform_brightness_changed',
    );
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_isSettlingTerminalMetricsAfterAppResume) {
      _scheduleAppResumeTerminalMetricsSettleEnd();
    }
    _scheduleTerminalSizeRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload theme when system brightness changes
    final brightness = _resolveTerminalThemeBrightness();
    final didBrightnessChange = _lastThemeDependencyBrightness != brightness;
    _lastThemeDependencyBrightness = brightness;
    if (_currentTheme == null) {
      return;
    }
    if (!didBrightnessChange) {
      return;
    }
    _handleTerminalThemeDependenciesChanged(
      forceRemoteRefresh: true,
      reason: 'dependencies_brightness_changed',
    );
  }

  List<Widget> _buildTerminalStatusChips(ThemeData theme) {
    final chipLabels = <({IconData icon, String label, String tooltip})>[
      if (formatRemoteMuxVersionLabel(_activeMuxBackend, _muxVersion)
          case final muxVersionLabel? when _isTmuxActive)
        (
          icon: Icons.window_outlined,
          label: muxVersionLabel,
          tooltip:
              'Detected ${_activeMuxBackend.label} version for the active '
              'remote multiplexer.',
        ),
      if (_workingDirectoryLabel case final workingDirectory?
          when workingDirectory.isNotEmpty)
        (
          icon: Icons.folder_outlined,
          label: workingDirectory,
          tooltip: 'Current working directory reported by the shell session.',
        ),
      if (describeTerminalShellStatus(_shellStatus, lastExitCode: _lastExitCode)
          case final shellStatusLabel? when shellStatusLabel.isNotEmpty)
        (
          icon: Icons.play_circle_outline,
          label: shellStatusLabel,
          tooltip:
              'Shell integration status for the current prompt or command.',
        ),
      if (_isUsingAltBuffer)
        (
          icon: Icons.aspect_ratio,
          label: 'Alt buffer',
          tooltip:
              'A full-screen terminal app is using the alternate screen buffer.',
        ),
      if (_describeMouseMode(_terminal.mouseMode, _terminal.mouseReportMode)
          case final mouseModeLabel? when mouseModeLabel.isNotEmpty)
        (
          icon: Icons.mouse_outlined,
          label: mouseModeLabel,
          tooltip:
              'Terminal apps like tmux are actively receiving mouse input events.',
        ),
      if (_terminal.reportFocusMode)
        (
          icon: Icons.center_focus_strong,
          label: 'Focus reports',
          tooltip:
              'The terminal is reporting focus gained and lost events to the shell.',
        ),
      if (_terminal.bracketedPasteMode)
        (
          icon: Icons.content_paste,
          label: 'Bracketed paste',
          tooltip:
              'Paste operations are wrapped so terminal apps can handle them safely.',
        ),
    ];

    return chipLabels
        .map(
          (chip) => _TerminalStatusChip(
            icon: chip.icon,
            label: chip.label,
            tooltip: chip.tooltip,
            colorScheme: theme.colorScheme,
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SshConnectionState>(
      activeSessionsProvider.select(_selectTrackedConnectionState),
      _handleTrackedConnectionStateChange,
    );
    final theme = Theme.of(context);
    final connectionState = ref.watch(
      activeSessionsProvider.select(_selectTrackedConnectionState),
    );
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    // Insets are geometry, not authoritative visibility: some Android IMEs
    // leave a stale bottom inset after closing. Prefer native IME visibility
    // for every input owner, falling back to each owner's live connection/focus
    // only until the platform channel responds.
    final systemKeyboardVisible = resolveTerminalSystemKeyboardVisible(
      bottomInset: MediaQuery.viewInsetsOf(context).bottom,
      platformKeyboardVisible: _systemKeyboardVisibilityController.visible,
      terminalInputConnectionVisible:
          _terminalTextInputController.isKeyboardVisible,
      nativeComposerInputOwner:
          _activeNativeAcpSessionKey != null &&
          _nativeComposerFocusController.hasFocus,
    );
    if (_isAndroidPlatform) {
      _logAndroidPredictiveBackDiagnostics(context, phase: 'build');
      _queueAndroidPredictiveBackPostFrameDiagnostics(context);
    }
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;

    final activeSession = _connectionId == null
        ? null
        : ref.read(activeSessionsProvider.notifier).getSession(_connectionId!);
    final agentAccess =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final canManageAgents = agentAccess.allowsFeature(
      MonetizationFeature.agentManagement,
    );
    final agentUpdateIndicators = ref.watch(
      agentUpdateNotificationsNotifierProvider,
    );
    final hasAgentUpdates =
        canManageAgents &&
        agentUpdateIndicators &&
        connectionState == SshConnectionState.connected &&
        activeSession != null &&
        (_agentUpdateRuntimes[activeSession]?.any(
              (runtime) => runtime.hasUpdate,
            ) ??
            false);
    final showsNativeAgent =
        _activeNativeAcpSessionKey != null || _nativeAcpLaunchState != null;
    final showsTerminalViewportMenuActions =
        resolveShowTerminalViewportMenuActions(
          nativeAgentActive: showsNativeAgent,
        );
    // Keep the user-selected theme as the session base. Remote OSC color
    // setters are applied only to the session's effective terminal theme.
    final configuredTerminalTheme = _resolveEffectiveTerminalTheme();
    if (!_sameTerminalTheme(configuredTerminalTheme, _lastBuildAppliedTheme)) {
      _lastBuildAppliedTheme = configuredTerminalTheme;
      _applyTerminalThemeToSession(configuredTerminalTheme, reason: 'build');
    }
    final terminalTheme =
        (_sessionController.observedSession ?? activeSession)?.terminalTheme ??
        configuredTerminalTheme;
    final connectionLabel = describeTerminalConnectionState(
      connectionState,
      isConnecting: _isConnecting,
    );
    final deviceDebugController = _isAndroidPlatform
        ? _deviceDebugControllerFor(activeSession)
        : null;
    final showsDeviceDebugAction =
        _isAndroidPlatform &&
        (ref.watch(deviceDebugSupportedProvider).asData?.value ?? false);
    final isConnectedThroughJumpHost =
        connectionState == SshConnectionState.connected &&
        (_observedSession ?? activeSession)?.config.jumpHost != null;
    final connectionIdentity = formatTerminalConnectionIdentity(
      username: _redactStoreScreenshotIdentities ? 'store' : _host?.username,
      hostname: _redactStoreScreenshotIdentities
          ? 'local-demo'
          : _host?.hostname,
      port: _redactStoreScreenshotIdentities ? null : _host?.port,
      connectionId: _connectionId,
    );
    final titleSubtitleSegments = <String>[];
    if (connectionIdentity != null) {
      titleSubtitleSegments.add(connectionIdentity);
    }
    if (!showsNativeAgent && (_iconName ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_iconName!);
    }
    if (!showsNativeAgent && (_windowTitle ?? '').isNotEmpty) {
      titleSubtitleSegments.add(_windowTitle!);
    }
    final titleSubtitle = titleSubtitleSegments.join(' • ');
    final statusChips = _buildTerminalStatusChips(theme);
    final activeNativeKey = _activeNativeAcpSessionKey;
    final nativeActivitySnapshot = activeNativeKey == null
        ? null
        : ref.watch(
            acpSessionManagerStateProvider.select((state) {
              final session = state.asData?.value.byKeyValue(
                activeNativeKey.value,
              );
              return session == null
                  ? null
                  : AcpActivitySnapshot.fromSession(session);
            }),
          );
    final nativeActivity = nativeActivitySnapshot == null
        ? null
        : acpActivitySnapshotDisplay(nativeActivitySnapshot);
    final terminalProgress = activeNativeKey == null
        ? _terminalProgress
        : nativeActivity == null
        ? null
        : acpActivityTerminalProgress(nativeActivity);
    final commandMarkCount =
        (_sessionController.observedSession ?? activeSession)
            ?.terminalCommandMarkCount ??
        0;
    final isOpeningSftpBrowser = _isExclusiveTerminalActionRunning(
      _TerminalExclusiveAction.sftpBrowser,
    );
    final isOpeningTmuxNavigator = _isExclusiveTerminalActionRunning(
      _TerminalExclusiveAction.tmuxNavigator,
    );

    return PopScope(
      canPop: resolveTerminalScreenCanPop(
        isTmuxBarExpanded: _isTmuxBarExpanded,
      ),
      onPopInvokedWithResult: (didPop, _) {
        _logAndroidPredictiveBackDiagnostics(
          context,
          phase: 'pop_invoked',
          didPop: didPop,
        );
        if (didPop) {
          _clearAppThemeOverride();
          return;
        }
        _collapseTmuxBarIfExpanded();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: !isMobile || systemKeyboardVisible,
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          titleSpacing: 8,
          title: Row(
            children: [
              _TerminalConnectionStatusIcon(
                label: connectionLabel,
                state: connectionState,
                isConnecting: _isConnecting,
                connectedThroughJumpHost: isConnectedThroughJumpHost,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _host?.label ?? 'Terminal',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluttyTheme.displayMono(
                        fontSize: 16,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (titleSubtitle.isNotEmpty)
                      Text(
                        titleSubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          bottom:
              terminalProgress == null &&
                  (showsNativeAgent ||
                      !_showsTerminalMetadata ||
                      statusChips.isEmpty)
              ? null
              : PreferredSize(
                  preferredSize: Size.fromHeight(
                    (!showsNativeAgent &&
                                _showsTerminalMetadata &&
                                statusChips.isNotEmpty
                            ? 40
                            : 0) +
                        (terminalProgress == null ? 0 : 3),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!showsNativeAgent &&
                          _showsTerminalMetadata &&
                          statusChips.isNotEmpty)
                        Container(
                          alignment: Alignment.centerLeft,
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: statusChips
                                  .map(
                                    (chip) => Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: chip,
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ),
                        ),
                      if (terminalProgress != null)
                        _TerminalProgressBar(progress: terminalProgress),
                    ],
                  ),
                ),
          actions: [
            if (_isTmuxActive &&
                !_showTmuxBar &&
                connectionState == SshConnectionState.connected)
              IconButton(
                icon: const Icon(Icons.window_outlined),
                onPressed: _connectionId == null || isOpeningTmuxNavigator
                    ? null
                    : _openTmuxNavigator,
                tooltip: 'tmux windows',
              ),
            IconButton(
              icon: const Icon(Icons.folder_outlined),
              onPressed:
                  _connectionId == null ||
                      isOpeningSftpBrowser ||
                      connectionState != SshConnectionState.connected
                  ? null
                  : () => unawaited(_openConnectionFileBrowser()),
              tooltip: 'Browse files',
            ),
            if (isMobile)
              IconButton(
                icon: Icon(
                  systemKeyboardVisible
                      ? Icons.keyboard_hide
                      : Icons.keyboard_alt_outlined,
                ),
                onPressed: () => showsNativeAgent
                    ? _toggleNativeComposerKeyboard(systemKeyboardVisible)
                    : _toggleSystemKeyboard(systemKeyboardVisible),
                tooltip: systemKeyboardVisible
                    ? 'Hide system keyboard'
                    : 'Show system keyboard',
              ),
            IconButton(
              icon: _ExtraKeysToggleKeycap(
                key: ValueKey<String>(
                  _showKeyboardToolbar
                      ? 'extra-keys-toggle-active'
                      : 'extra-keys-toggle-inactive',
                ),
                isActive: _showKeyboardToolbar,
              ),
              onPressed: _toggleKeyboardToolbar,
              tooltip: _showKeyboardToolbar
                  ? 'Hide extra keys'
                  : 'Show extra keys',
            ),
            MenuAnchor(
              key: _terminalOverflowMenuButtonKey,
              style: _terminalOverflowMenuStyle(
                context: context,
                isMobilePlatform: isMobile,
              ),
              reservedPadding: _terminalOverflowMenuReservedPadding(
                context: context,
                isMobilePlatform: isMobile,
              ),
              menuChildren: [
                if (showsTerminalViewportMenuActions)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.code_rounded,
                    label: 'Snippets',
                    action: 'snippets',
                  ),
                _terminalOverflowMenuItem(
                  context: context,
                  icon: Icons.palette_outlined,
                  label: 'Change Theme',
                  action: 'change_theme',
                ),
                _terminalOverflowMenuItem(
                  context: context,
                  icon: Icons.smart_toy_outlined,
                  label: 'Agent Management',
                  action: 'agent_management',
                  showStatusDot: hasAgentUpdates,
                  showProBadge: !canManageAgents,
                  enabled:
                      _connectionId != null &&
                      connectionState == SshConnectionState.connected,
                ),
                _terminalOverflowMenuItem(
                  context: context,
                  icon: Icons.alt_route_rounded,
                  label: 'Port Forwards',
                  action: 'port_forwards',
                  enabled:
                      _connectionId != null &&
                      connectionState == SshConnectionState.connected,
                ),
                if (_forceMonkeyMuxReloadMenuState.visible)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.restart_alt_rounded,
                    label: 'Force MonkeyMux Reload',
                    action: 'force_monkeymux_reload',
                    enabled: _forceMonkeyMuxReloadMenuState.enabled,
                  ),
                if (showsDeviceDebugAction)
                  _terminalOverflowSwitchMenuItem(
                    context: context,
                    icon: Icons.bug_report_outlined,
                    label: 'Device debugging',
                    value: deviceDebugController?.state.isActive ?? false,
                    loading: deviceDebugController?.state.isBusy ?? false,
                    action: 'toggle_device_debug',
                    enabled:
                        deviceDebugController != null &&
                        connectionState == SshConnectionState.connected,
                  ),
                if (isPortForwardBrowserSupported())
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.open_in_browser_outlined,
                    label: 'Open Forwarded Browser',
                    action: 'open_port_forward_browser',
                  ),
                _terminalOverflowSubmenuButton(
                  context: context,
                  isMobile: isMobile,
                  icon: Icons.tune_rounded,
                  label: 'Options',
                  menuChildren: _terminalOptionsMenuItems(
                    context: context,
                    hasTerminalInfo: statusChips.isNotEmpty,
                    isMobile: isMobile,
                    nativeAgentActive: showsNativeAgent,
                  ),
                ),
                _terminalOverflowMenuDivider(context),
                if (showsTerminalViewportMenuActions && !isMobile)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: _isNativeSelectionMode
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                    label: _isNativeSelectionMode
                        ? 'Exit Native Selection'
                        : 'Native Selection',
                    action: 'native_select',
                  ),
                if (showsTerminalViewportMenuActions && commandMarkCount > 0)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.history_rounded,
                    label: commandMarkCount == 1
                        ? 'Previous Command'
                        : 'Previous Command ($commandMarkCount)',
                    action: 'previous_command',
                  ),
                if (showsTerminalViewportMenuActions &&
                    _workingDirectoryPath != null)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.folder_copy_outlined,
                    label: 'Copy Current Directory',
                    action: 'copy_working_directory',
                  ),
                if (showsTerminalViewportMenuActions &&
                    _currentTerminalSelectionText() != null)
                  _terminalOverflowMenuItem(
                    context: context,
                    icon: Icons.code_rounded,
                    label: 'Create Snippet',
                    action: 'create_snippet',
                  ),
                if (showsTerminalViewportMenuActions)
                  _terminalOverflowSubmenuButton(
                    context: context,
                    isMobile: isMobile,
                    icon: Icons.paste_rounded,
                    label: 'Paste',
                    menuChildren: _terminalPastingMenuItems(context),
                  ),
                if (showsTerminalViewportMenuActions)
                  _terminalOverflowMenuDivider(context),
                _terminalOverflowMenuItem(
                  context: context,
                  icon: Icons.link_off_rounded,
                  label: 'Disconnect',
                  action: 'disconnect',
                ),
              ],
              builder: (context, controller, _) => IconButton(
                icon: Semantics(
                  label: hasAgentUpdates ? 'Agent updates available' : null,
                  child: Badge(
                    key: const ValueKey('terminal-agent-updates-dot'),
                    isLabelVisible: hasAgentUpdates,
                    backgroundColor: theme.colorScheme.primary,
                    smallSize: 8,
                    child: const Icon(Icons.more_vert),
                  ),
                ),
                tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                onPressed: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              ),
            ),
          ],
        ),
        body: Builder(
          builder: (bodyContext) {
            final showsKeyboardToolbar =
                _showKeyboardToolbar &&
                !showsDisconnectedOverlay &&
                (!_isNativeSelectionMode || _isMobilePlatform);
            final terminalArea = _buildTerminalWithTmuxBar(
              terminalTheme,
              isMobile,
              theme,
              connectionState,
            );
            return Column(
              children: [
                Expanded(
                  // The KeyboardToolbar below already absorbs the bottom
                  // system inset, so strip it here to prevent the tmux bar
                  // from reserving that space a second time.
                  child: showsKeyboardToolbar
                      ? MediaQuery(
                          data: removeSystemBottomInset(
                            MediaQuery.of(bodyContext),
                          ),
                          child: terminalArea,
                        )
                      : terminalArea,
                ),
                if (showsKeyboardToolbar)
                  KeyboardToolbar(
                    controller: _toolbarController,
                    terminal: _terminal,
                    onKeyPressed: showsNativeAgent
                        ? null
                        : _handleKeyboardToolbarKeyPressed,
                    onTextInput: showsNativeAgent
                        ? _nativeComposerFocusController.insertText
                        : null,
                    onSpecialKey: showsNativeAgent
                        ? _nativeComposerFocusController.sendSpecialKey
                        : null,
                    onPasteRequested: showsNativeAgent
                        ? _pasteClipboardIntoNativeComposer
                        : _pasteClipboard,
                    onPasteMenuOpened: _refreshKeyboardToolbarSnippetMenu,
                    onSnippetPasteRequested: showsNativeAgent
                        ? _pasteSnippetIntoNativeComposer
                        : _pasteKeyboardToolbarSnippet,
                    onPasteMediaRequested: showsNativeAgent
                        ? _nativeComposerFocusController.pickPhotos
                        : _pastePickedMedia,
                    onPasteFilesRequested: showsNativeAgent
                        ? _nativeComposerFocusController.pickFiles
                        : _pastePickedFiles,
                    snippets: _keyboardToolbarSnippets,
                    snippetFolders: _keyboardToolbarSnippetFolders,
                    terminalFocusNode: showsNativeAgent
                        ? null
                        : _terminalFocusNode,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // Rebuilds so the keyboard toggle button reflects the current
  // input-connection state even when the platform bottom inset does not change
  // (e.g. a stale inset equal to the keyboard height). Deferred to a post-frame
  // callback so it is safe to trigger from focus/build-phase changes.
  void _handleTerminalKeyboardVisibilityChanged() {
    if (_keyboardVisibilityRebuildScheduled || !mounted) {
      return;
    }
    _keyboardVisibilityRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardVisibilityRebuildScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }

  /// Toggles the system keyboard visibility on mobile platforms.
  void _toggleSystemKeyboard(bool isVisible) {
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logSystemKeyboardToggled(visible: !isVisible),
    );
    if (isVisible) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      _terminalFocusNode.unfocus();
    } else {
      // Explicit user action — always show the keyboard regardless of the
      // tap-to-show setting.
      _restoreTerminalFocus(forceShowSystemKeyboard: true);
    }
  }

  void _toggleNativeComposerKeyboard(bool isVisible) {
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logSystemKeyboardToggled(visible: !isVisible),
    );
    if (isVisible) {
      _nativeComposerFocusController.dismissKeyboard();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    } else {
      _nativeComposerFocusController.requestFocus();
    }
  }

  void _toggleKeyboardToolbar() {
    final nextValue = !_showKeyboardToolbar;
    final shouldRestoreSystemKeyboard =
        _isMobilePlatform &&
        (_terminalTextInputController.isKeyboardVisible ||
            MediaQuery.viewInsetsOf(context).bottom > 0);
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logKeyboardToolbarToggled(enabled: nextValue),
    );
    setState(() => _showKeyboardToolbar = nextValue);
    if (shouldRestoreSystemKeyboard) {
      if (_activeNativeAcpSessionKey != null) {
        _nativeComposerFocusController.requestFocus();
      } else {
        _restoreTerminalFocus(forceShowSystemKeyboard: true);
      }
    }
  }

  /// Restores focus to the terminal after a UI interaction.
  ///
  /// When [showSystemKeyboard] is `true` the soft keyboard is shown only if
  /// the tap-to-show-keyboard setting permits it.  Use
  /// [forceShowSystemKeyboard] to bypass the setting (e.g. the explicit
  /// toolbar keyboard toggle).
  void _restoreTerminalFocus({
    bool showSystemKeyboard = false,
    bool forceShowSystemKeyboard = false,
  }) {
    if (!mounted) {
      return;
    }
    final restoreGeneration = _terminalFocusRestoreGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || restoreGeneration != _terminalFocusRestoreGeneration) {
        return;
      }
      _terminalTextInputController.resetImeCompletions();
      _terminalFocusNode.requestFocus();
      final shouldShowKeyboard =
          forceShowSystemKeyboard ||
          (showSystemKeyboard && ref.read(tapToShowKeyboardNotifierProvider));
      if (shouldShowKeyboard && _isMobilePlatform) {
        _terminalTextInputController.requestKeyboard();
      }
    });
  }

  bool _temporarilyDismissTerminalKeyboard() {
    if (!_isMobilePlatform) {
      return false;
    }
    final shouldRestore = _shouldRestoreTerminalKeyboardAfterTemporaryDismissal;
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    _terminalFocusNode.unfocus();
    return shouldRestore;
  }

  bool get _shouldRestoreTerminalKeyboardAfterTemporaryDismissal =>
      _isMobilePlatform &&
      _terminalFocusNode.hasFocus &&
      _terminalTextInputController.isKeyboardVisible;

  void _restoreTemporarilyDismissedTerminalKeyboard(bool shouldRestore) {
    if (!shouldRestore || !mounted) {
      return;
    }
    _restoreTerminalFocus(forceShowSystemKeyboard: true);
  }

  bool _dismissTerminalKeyboardForAppBackground() {
    if (!_isMobilePlatform) {
      return false;
    }
    final wasKeyboardVisible = _terminalTextInputController.isKeyboardVisible;
    final shouldRestore = wasKeyboardVisible && _terminalFocusNode.hasFocus;
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    if (wasKeyboardVisible) {
      _terminalFocusNode.unfocus();
    }
    return shouldRestore;
  }

  void _handleKeyboardToolbarKeyPressed() {
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logKeyboardToolbarKeyPressed(
            hasModifier:
                _toolbarController.isCtrlActive ||
                _toolbarController.isAltActive ||
                _toolbarController.isShiftActive,
          ),
    );
    _handleTerminalUserInput();
    _terminalTextInputController.clearImeBuffer();
  }

  void _handleTerminalScaleStart(double currentFontSize) {
    _pinchFontSize = currentFontSize;
    _lastPinchScale = 1;
    _isPinchZooming = false;
  }

  void _handleTerminalScaleUpdate(double scale, double currentFontSize) {
    final displayedFontSize = _pinchFontSize ?? currentFontSize;
    final previousScale = _lastPinchScale ?? 1;
    final nextFontSize = applyTerminalScaleDelta(
      displayedFontSize,
      previousScale,
      scale,
    );
    if (_isPinchZooming && _pinchFontSize == nextFontSize) {
      return;
    }

    setState(() {
      _isPinchZooming = true;
      _pinchFontSize = nextFontSize;
      _lastPinchScale = scale;
    });
  }

  void _handleTerminalScaleEnd() {
    final nextFontSize = _pinchFontSize;
    final connectionId = _connectionId;
    final shouldPersist =
        _isPinchZooming && nextFontSize != null && connectionId != null;
    setState(() {
      if (shouldPersist) {
        _sessionFontSizeOverride = nextFontSize;
      }
      _isPinchZooming = false;
      _lastPinchScale = null;
      _pinchFontSize = null;
    });

    if (!shouldPersist) {
      return;
    }

    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionFontSize(connectionId, nextFontSize);
  }

  Widget _buildTerminalTransientIndicator({
    required ThemeData theme,
    required String label,
  }) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );

  Widget _wrapTerminalShellCompletionOverlay(
    Widget child, {
    required ThemeData theme,
    required TerminalThemeData terminalTheme,
    required TextStyle terminalTextStyle,
  }) {
    final suggestions = _shellCompletionSuggestions;
    final anchorGlobalRect = _shellCompletionAnchorGlobalRect;
    if (suggestions.isEmpty || anchorGlobalRect == null) {
      return child;
    }

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        wrapShellCompletionDismissibleTerminal(
          onDismiss: () => _hideShellCompletionPopup(resetPromptPrefix: false),
          child: child,
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (overlayContext, constraints) {
              final overlayObject = overlayContext.findRenderObject();
              if (overlayObject is! RenderBox || !overlayObject.hasSize) {
                return const SizedBox.shrink();
              }

              final anchor = Rect.fromPoints(
                overlayObject.globalToLocal(anchorGlobalRect.topLeft),
                overlayObject.globalToLocal(anchorGlobalRect.bottomRight),
              );
              final rowHeight = resolveShellCompletionPopupRowHeight(
                terminalTextStyle.fontSize ?? 14,
              );
              final layout = resolveShellCompletionPopupLayout(
                overlaySize: Size(constraints.maxWidth, constraints.maxHeight),
                anchor: anchor,
                suggestionCount: suggestions.length,
                rowHeight: rowHeight,
              );

              if (layout.width <= 0 || layout.maxHeight <= 0) {
                return const SizedBox.shrink();
              }

              return Stack(
                children: [
                  Positioned(
                    left: layout.left,
                    top: layout.top,
                    width: layout.width,
                    child: _buildShellCompletionPopup(
                      theme: theme,
                      terminalTheme: terminalTheme,
                      suggestions: suggestions,
                      rowHeight: rowHeight,
                      maxHeight: layout.maxHeight,
                      textStyle: terminalTextStyle,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildShellCompletionPopup({
    required ThemeData theme,
    required TerminalThemeData terminalTheme,
    required List<ShellCompletionSuggestion> suggestions,
    required double rowHeight,
    required double maxHeight,
    required TextStyle textStyle,
  }) {
    final popupColor = Color.alphaBlend(
      theme.colorScheme.surfaceTint.withValues(alpha: 0.08),
      theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
    );
    final completionTextStyle = textStyle.copyWith(
      color: theme.colorScheme.onSurface,
    );

    return Material(
      color: popupColor,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: terminalTheme.foreground.withValues(alpha: 0.14),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 3),
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (context, index) => Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
          itemBuilder: (context, index) {
            final suggestion = suggestions[index];
            return InkWell(
              onTap: () => _acceptShellCompletion(suggestion),
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        _shellCompletionIcon(suggestion.kind),
                        size: min(
                          18,
                          max(14, (textStyle.fontSize ?? 14) + 1),
                        ).toDouble(),
                        color: terminalTheme.foreground.withValues(alpha: 0.76),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          suggestion.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: completionTextStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  IconData _shellCompletionIcon(ShellCompletionSuggestionKind kind) =>
      switch (kind) {
        ShellCompletionSuggestionKind.history => Icons.history_rounded,
        ShellCompletionSuggestionKind.command => Icons.terminal_rounded,
        ShellCompletionSuggestionKind.directory => Icons.folder_outlined,
        ShellCompletionSuggestionKind.file => Icons.insert_drive_file_outlined,
      };

  Future<void> _showThemePicker() async {
    final currentId = _sessionThemeOverride?.id ?? _currentTheme?.id;
    final previousSessionThemeOverride = _sessionThemeOverride;
    final previousTheme = _resolveEffectiveTerminalTheme();
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
      onThemePreviewed: _previewThemeFromPicker,
      requestFocus: terminalOverlayRouteRequestFocus(context),
    );

    if (!mounted) {
      return;
    }

    if (theme == null) {
      _restoreThemePickerPreview(
        previousTheme: previousTheme,
        previousSessionThemeOverride: previousSessionThemeOverride,
      );
      return;
    }

    final isDark = _resolveTerminalThemeBrightness() == Brightness.dark;
    await _ensureSelectedThemeCanBeRestored(theme);
    if (!mounted) {
      return;
    }
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final hasHostThemeAccess = monetizationState.allowsFeature(
      MonetizationFeature.hostSpecificThemes,
    );
    final connectionId = _connectionId;
    var hasSession = false;
    if (connectionId != null) {
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      final session =
          (sessionsNotifier
                ..updateSessionTheme(connectionId, theme.id, isDark: isDark))
              .getSession(connectionId);
      if (session != null) {
        hasSession = true;
        _syncAppThemeOverrideFromSession(session);
      }
    }
    setState(() => _sessionThemeOverride = theme);
    DiagnosticsLogService.instance.info(
      'terminal.theme',
      'picker_selected',
      fields: {
        'connectionId': connectionId,
        'isDark': isDark,
        'hasHostThemeAccess': hasHostThemeAccess,
        'hasSession': hasSession,
      },
    );
    _applyTerminalThemeToSession(
      theme,
      forceRemoteRefresh: true,
      reason: 'theme_picker',
    );

    // Show option to save to host
    if (_host != null) {
      final scaffoldMessenger = ScaffoldMessenger.of(context);

      // Clear any existing snackbar first to prevent stacking
      scaffoldMessenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Expanded(child: Text('Theme: ${theme.name}')),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () {
                    scaffoldMessenger.hideCurrentSnackBar();
                    _saveThemeToHost(theme, isDark: isDark);
                  },
                  child: Text(
                    hasHostThemeAccess ? 'Save to Host' : 'Save to Host (Pro)',
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 6),
          ),
        );
    }
  }

  Future<void> _ensureSelectedThemeCanBeRestored(
    TerminalThemeData theme,
  ) async {
    if (!theme.isCustom || TerminalThemes.getById(theme.id) != null) {
      return;
    }
    final themeService = ref.read(terminalThemeServiceProvider);
    final existingTheme = await themeService.getThemeById(theme.id);
    if (existingTheme != null) {
      return;
    }
    await themeService.saveCustomTheme(theme.copyWith(isCustom: true));
    ref
      ..invalidate(allTerminalThemesProvider)
      ..invalidate(customTerminalThemesProvider);
  }

  void _previewThemeFromPicker(TerminalThemeData theme) {
    if (!mounted) {
      return;
    }
    setState(() => _sessionThemeOverride = theme);
    _lastBuildAppliedTheme = theme;
    _applyTerminalThemeToSession(theme, reason: 'theme_picker_preview');
  }

  void _restoreThemePickerPreview({
    required TerminalThemeData previousTheme,
    required TerminalThemeData? previousSessionThemeOverride,
  }) {
    setState(() => _sessionThemeOverride = previousSessionThemeOverride);
    _lastBuildAppliedTheme = previousTheme;
    _applyTerminalThemeToSession(previousTheme, reason: 'theme_picker_cancel');
  }

  Future<void> _saveThemeToHost(
    TerminalThemeData theme, {
    required bool isDark,
  }) async {
    if (_host == null) return;
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.hostSpecificThemes,
      blockedAction: 'Save this theme to the host',
      blockedOutcome:
          'Unlock Pro to keep this host on the selected terminal theme.',
    );
    if (!hasAccess || !mounted) {
      return;
    }

    final hostRepo = ref.read(hostRepositoryProvider);
    final updatedHost = isDark
        ? _host!.copyWith(terminalThemeDarkId: drift.Value(theme.id))
        : _host!.copyWith(terminalThemeLightId: drift.Value(theme.id));

    await hostRepo.updateFields(
      updatedHost.id,
      isDark
          ? HostsCompanion(terminalThemeDarkId: drift.Value(theme.id))
          : HostsCompanion(terminalThemeLightId: drift.Value(theme.id)),
    );
    _host = updatedHost;

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Theme saved to ${_host!.label}')));
    }
  }

  Widget _buildConnectionIssueOverlay({
    required ThemeData theme,
    required Widget child,
    required String message,
    required bool showsDisconnectedOverlay,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      AbsorbPointer(child: child),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(FluttyTheme.radiusLg),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      showsDisconnectedOverlay
                          ? 'Disconnected'
                          : 'Connection Error',
                      style: FluttyTheme.displayMono(
                        fontSize: 18,
                        color: theme.colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _isConnecting ? null : _reconnect,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildTerminalView(
    TerminalThemeData terminalTheme,
    bool isMobile,
    SshConnectionState connectionState,
  ) {
    final theme = Theme.of(context);
    final connectionAttempt = ref.watch(
      connectionAttemptProvider(widget.hostId),
    );
    final showsDisconnectedOverlay =
        _connectionId != null &&
        !_isConnecting &&
        connectionState == SshConnectionState.disconnected;
    final overlayMessage = showsDisconnectedOverlay
        ? connectionAttempt?.latestMessage ?? _error ?? 'Connection closed'
        : _error;

    if (_isConnecting) {
      _logAndroidTerminalContentDiagnostics(
        context,
        branch: 'connecting',
        connectionState: connectionState,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
        hasOverlayMessage: overlayMessage != null,
        isMobile: isMobile,
      );
      final isCancellingConnection = connectionAttempt?.isCancelling ?? false;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CursorBlock(size: 32),
            const SizedBox(height: 16),
            Text(
              isCancellingConnection ? 'cancelling…' : 'connecting…',
              style: FluttyTheme.monoStyle.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: isCancellingConnection
                  ? null
                  : _cancelConnectionAttempt,
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ],
        ),
      );
    }

    if (overlayMessage != null && _connectionId == null) {
      _logAndroidTerminalContentDiagnostics(
        context,
        branch: 'initial_error',
        connectionState: connectionState,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
        hasOverlayMessage: true,
        isMobile: isMobile,
      );
      return BrandErrorState(
        title: _connectionCancelled
            ? 'Connection Cancelled'
            : 'Connection Error',
        message: overlayMessage,
        onRetry: _reconnect,
      );
    }

    final nativeAcpLaunchState = _nativeAcpLaunchState;
    if (nativeAcpLaunchState != null) {
      return _buildNativeAgentStartingView(nativeAcpLaunchState);
    }

    final activeNativeAcpSessionKey = _activeNativeAcpSessionKey;
    if (activeNativeAcpSessionKey != null) {
      return _buildEmbeddedNativeAgentView(activeNativeAcpSessionKey);
    }

    // Use a session override when pinch-zoom has customized this connection.
    final globalFontSize = ref.watch(fontSizeNotifierProvider);
    final storedFontSize = _sessionFontSizeOverride ?? globalFontSize;
    final fontSize = resolveTerminalFontSize(
      globalFontSize: globalFontSize,
      sessionFontSize: _sessionFontSizeOverride,
      pinchFontSize: _pinchFontSize,
    );

    // Get font family from host (if set) or global settings
    final hostFont = _host?.terminalFontFamily;
    final globalFont = ref.watch(fontFamilyNotifierProvider);
    final fontFamily = hostFont ?? globalFont;
    final terminalFlutterTextStyle = _getTerminalFlutterTextStyle(
      fontFamily,
      fontSize,
    );
    final terminalTextStyle = TerminalStyle.fromTextStyle(
      terminalFlutterTextStyle,
    );
    final routeTouchScrollToTerminal = _routesTouchScrollToTerminal;
    final terminalPathLinksEnabled = ref.watch(
      terminalPathLinksNotifierProvider,
    );
    final terminalPathLinkUnderlinesEnabled = ref.watch(
      terminalPathLinkUnderlinesNotifierProvider,
    );
    final showsTerminalPathUnderlines =
        terminalPathLinksEnabled && terminalPathLinkUnderlinesEnabled;
    final inlineUnderlines = showsTerminalPathUnderlines
        ? _isMobilePlatform
              ? [
                  for (final underline in _visibleTerminalPathUnderlines)
                    underline.underline,
                ]
              : <TerminalTextUnderline>[?_hoveredTerminalPathUnderline]
        : const <TerminalTextUnderline>[];
    final keyboardAppearance = resolveTerminalKeyboardAppearance(terminalTheme);
    final clipsMonkeyMuxSharedGrid =
        _activeMuxBackend == RemoteMuxBackend.monkeyMux &&
        ((_observedSession ?? _activeSession())
                ?.monkeyMuxViewportClippingEnabled ??
            false);
    Widget terminalView = MonkeyTerminalView(
      key: _terminalViewKey,
      _terminal,
      controller: _terminalController,
      scrollController: _terminalScrollController,
      scrollResetGeneration: _terminalScrollResetGeneration,
      resolveLinkTap: _resolveTerminalLinkTap,
      onLinkTapDown: _handleTerminalLinkTapDown,
      onLinkTap: _handleTerminalLinkTap,
      suppressLongPressDragSelection: isMobile,
      liveOutputAutoScroll: _terminalLiveOutputAutoScrollEnabled,
      useSystemSelection: isMobile || _isNativeSelectionMode,
      systemSelectionContextMenuBuilder: _buildTerminalSelectionContextMenu,
      onSystemSelectionChanged: _isNativeSelectionMode
          ? (_) => _onSelectionChanged()
          : null,
      focusNode: _terminalFocusNode,
      cursorFocusNode: isMobile ? _terminalFocusNode : null,
      theme: terminalTheme.toXtermTheme(),
      textStyle: terminalTextStyle,
      inlineUnderlines: inlineUnderlines,
      keyboardAppearance: keyboardAppearance,
      padding: terminalViewportPadding,
      resizeTerminalToViewport: !clipsMonkeyMuxSharedGrid,
      notifyPixelSizeChanges: !clipsMonkeyMuxSharedGrid,
      deleteDetection: !isMobile,
      autofocus: !isMobile,
      hardwareKeyboardOnly: isMobile,
      // Let alt-buffer apps keep raw wheel events when they explicitly enable
      // mouse reporting, but fall back to synthetic arrows when they do not.
      simulateScroll: shouldUseSyntheticAltBufferScrollFallback(
        isUsingAltBuffer: _isUsingAltBuffer,
        preferExplicitMouseReporting: true,
        terminalReportsMouseWheel: _terminalReportsMouseWheelForScroll,
        isAgentToolActive: _isAgentToolActive,
      ),
      touchScrollToTerminal: routeTouchScrollToTerminal,
      forceSgrTouchScroll: _forceSgrTouchScroll,
      onInsertText: isMobile ? null : _confirmDesktopInsertedText,
      onPasteText: _pasteClipboard,
      onUserInput: _handleTerminalUserInput,
      onTapDown: (_, _) => _claimActiveMonkeyMuxClientFocus(),
    );

    if (_lastShowsTerminalPathUnderlines != showsTerminalPathUnderlines) {
      _lastShowsTerminalPathUnderlines = showsTerminalPathUnderlines;
      _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild =
          showsTerminalPathUnderlines;
    }
    if (!showsTerminalPathUnderlines && _hoveredTerminalPathUnderline != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hoveredTerminalPathUnderline == null) {
          return;
        }
        setState(() => _hoveredTerminalPathUnderline = null);
      });
    }
    if (!showsTerminalPathUnderlines &&
        _isMobilePlatform &&
        _visibleTerminalPathUnderlines.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _visibleTerminalPathUnderlines.isEmpty) {
          return;
        }
        setState(
          () => _visibleTerminalPathUnderlines =
              const <
                ({String path, TerminalTextUnderline underline, Rect touchRect})
              >[],
        );
      });
    }
    if (isMobile || terminalPathLinksEnabled) {
      terminalView = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleTerminalPointerDown,
        onPointerMove: _handleTerminalPointerMove,
        onPointerUp: _handleTerminalPointerUp,
        onPointerCancel: _handleTerminalPointerCancel,
        child: terminalView,
      );
    }
    if (showsTerminalPathUnderlines) {
      if (_isMobilePlatform) {
        if (_shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild) {
          _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = false;
          _queueVisibleTerminalPathUnderlineRefresh();
        }
      } else {
        terminalView = MouseRegion(
          onHover: _handleTerminalPathHover,
          onExit: (_) => _clearHoveredTerminalPathUnderline(),
          child: terminalView,
        );
      }
    }

    if (isMobile) {
      terminalView = TextSelectionTheme(
        data: TextSelectionTheme.of(context).copyWith(
          selectionColor: terminalTheme.readableSelection,
          selectionHandleColor: terminalTheme.cursor,
        ),
        child: terminalView,
      );
    }

    terminalView = _wrapTerminalShellCompletionOverlay(
      terminalView,
      theme: theme,
      terminalTheme: terminalTheme,
      terminalTextStyle: terminalFlutterTextStyle,
    );

    if (!isMobile) {
      _logAndroidTerminalContentDiagnostics(
        context,
        branch: overlayMessage == null ? 'terminal' : 'terminal_with_overlay',
        connectionState: connectionState,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
        hasOverlayMessage: overlayMessage != null,
        isMobile: isMobile,
      );
      return overlayMessage == null
          ? terminalView
          : _buildConnectionIssueOverlay(
              theme: theme,
              child: terminalView,
              message: overlayMessage,
              showsDisconnectedOverlay: showsDisconnectedOverlay,
            );
    }

    var mobileTerminalView = terminalView;

    if (_isPinchZooming) {
      mobileTerminalView = Stack(
        fit: StackFit.expand,
        children: [
          mobileTerminalView,
          Positioned(
            top: 12,
            right: 12,
            child: _buildTerminalTransientIndicator(
              theme: theme,
              label: '${fontSize.toStringAsFixed(0)} pt',
            ),
          ),
        ],
      );
    }

    Widget terminalViewWithInput = TerminalTextInputHandler(
      terminal: _terminal,
      focusNode: _terminalFocusNode,
      controller: _terminalTextInputController,
      deleteDetection: true,
      keyboardAppearance: keyboardAppearance,
      onUserInput: _handleTerminalUserInput,
      onPasteText: _pasteClipboard,
      onReviewInsertedText: _confirmKeyboardInsertion,
      buildReviewTextForInsertedText: _terminalCommandAfterInputDelta,
      resolveTextBeforeCursor: _terminalTextBeforeCursor,
      resolveTerminalKeyModifiers: () => (
        ctrl: _toolbarController.isCtrlActive,
        alt: _toolbarController.isAltActive,
        shift: _toolbarController.isShiftActive,
      ),
      consumeTerminalKeyModifiers: _toolbarController.consumeOneShot,
      applyTerminalTextInputModifiers:
          _toolbarController.applySystemKeyboardModifiers,
      hasActiveToolbarModifier: () =>
          _toolbarController.isCtrlActive || _toolbarController.isAltActive,
      sensitiveInput: _detectedSensitiveKeyboardPrompt,
      readOnly: _isNativeSelectionMode || overlayMessage != null,
      tapToShowKeyboard:
          ref.watch(tapToShowKeyboardNotifierProvider) &&
          !_isNativeSelectionMode &&
          overlayMessage == null,
      showKeyboardOnFocus: false,
      manageFocus: false,
      child: TerminalPinchZoomGestureHandler(
        onPinchStart: () => _handleTerminalScaleStart(storedFontSize),
        onPinchUpdate: (scale) =>
            _handleTerminalScaleUpdate(scale, storedFontSize),
        onPinchEnd: _handleTerminalScaleEnd,
        child: mobileTerminalView,
      ),
    );

    if (overlayMessage != null) {
      terminalViewWithInput = _buildConnectionIssueOverlay(
        theme: theme,
        child: terminalViewWithInput,
        message: overlayMessage,
        showsDisconnectedOverlay: showsDisconnectedOverlay,
      );
    }

    _logAndroidTerminalContentDiagnostics(
      context,
      branch: overlayMessage == null
          ? 'mobile_terminal'
          : 'mobile_terminal_with_overlay',
      connectionState: connectionState,
      showsDisconnectedOverlay: showsDisconnectedOverlay,
      hasOverlayMessage: overlayMessage != null,
      isMobile: isMobile,
    );
    return terminalViewWithInput;
  }

  Widget _buildTerminalSelectionContextMenu(
    BuildContext _,
    SelectableRegionState selectableRegionState,
  ) {
    final selectionText = _currentTerminalSelectionText();
    VoidCallback selectionAction(void Function(String text) action) =>
        buildTerminalSelectionContextMenuAction(
          action: () {
            final text = selectionText;
            if (text == null) {
              return;
            }
            action(text);
          },
          hideToolbar: selectableRegionState.hideToolbar,
        );

    final buttonItems = buildTerminalSelectionContextMenuButtonItems(
      defaultItems: selectableRegionState.contextMenuButtonItems,
      onCopy: selectionAction((text) {
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logTerminalSelectionAction(action: 'copy'),
        );
        unawaited(
          _copySelectionText(
            text,
            clearTerminalSelection: true,
            restoreFocus: true,
          ),
        );
      }),
      onLookUp: selectionAction((text) {
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logTerminalSelectionAction(action: 'look_up'),
        );
        unawaited(_lookUpTerminalSelectionText(text));
      }),
      onSearchWeb: selectionAction((text) {
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logTerminalSelectionAction(action: 'search_web'),
        );
        unawaited(_searchWebForTerminalSelectionText(text));
      }),
      onShare: selectionAction((text) {
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logTerminalSelectionAction(action: 'share'),
        );
        unawaited(_shareTerminalSelectionText(text));
      }),
      onCreateSnippet: selectionText == null
          ? null
          : selectionAction((text) {
              unawaited(
                ref
                    .read(telemetryServiceProvider)
                    .logTerminalSelectionAction(action: 'create_snippet'),
              );
              unawaited(_createSnippetFromTerminalSelectionText(text));
            }),
      onPaste: () {
        selectableRegionState.hideToolbar();
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logTerminalSelectionAction(action: 'paste'),
        );
        unawaited(_pasteClipboard());
      },
    );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  /// Resolves the terminal text style for the given font family and size.
  TextStyle _getTerminalFlutterTextStyle(String fontFamily, double fontSize) =>
      resolveMonospaceTextStyle(
        fontFamily,
        platform: Theme.of(context).platform,
        fontSize: fontSize,
      );

  Future<void> _openConnectionFileBrowser() => _runExclusiveTerminalAction(
    _TerminalExclusiveAction.sftpBrowser,
    () async {
      final connectionId = _connectionId;
      if (connectionId == null) {
        return;
      }

      final tmuxPaneDirectory = await _resolveCurrentTmuxPaneDirectory();
      if (!mounted) {
        return;
      }
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logSftpOpenedFromTerminal(
              hasWorkingDirectory: _workingDirectoryPath != null,
              hasTmuxPaneDirectory: tmuxPaneDirectory != null,
            ),
      );

      // Prefer the last browser directory when opening from the toolbar. The
      // terminal cwd remains available for relative path resolution and as a
      // quick-jump inside the browser.
      final cwd = _workingDirectoryPath;
      final rememberedPath = ref.read(
        sftpBrowserLastPathsProvider,
      )[(hostId: widget.hostId, connectionId: connectionId)];
      final initialPath = rememberedPath ?? cwd;
      final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
      try {
        _disposeTerminalPathVerificationSftp();
        await context.pushNamed<String>(
          Routes.sftp,
          pathParameters: {'hostId': widget.hostId.toString()},
          queryParameters: _buildSftpBrowserQueryParameters(
            connectionId: connectionId,
            initialPath: initialPath,
            workingDirectory: cwd,
            tmuxPaneDirectory: tmuxPaneDirectory,
          ),
        );
      } finally {
        _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
        _resetTerminalScrollAfterSftpBrowserClosed(
          focusAlreadyRestored: shouldRestoreKeyboard,
        );
      }
    },
  );

  Map<String, String> _buildSftpBrowserQueryParameters({
    int? connectionId,
    String? initialPath,
    String? workingDirectory,
    String? tmuxPaneDirectory,
  }) {
    final queryParameters = <String, String>{};

    void addParameter(String key, String? value) {
      if (value == null) {
        return;
      }
      queryParameters[key] = value;
    }

    addParameter('connectionId', connectionId?.toString());
    addParameter('path', initialPath);
    addParameter('cwd', workingDirectory);
    addParameter('connectionCwd', _connectionOpenedWorkingDirectory);
    addParameter('tmuxCwd', tmuxPaneDirectory);

    return queryParameters;
  }

  Future<String?> _resolveCurrentTmuxPaneDirectory() async {
    final fallbackDirectory = normalizeSftpAbsolutePath(_tmuxWorkingDirectory);
    final connectionId = _connectionId;
    final sessionName = _tmuxSessionName;
    if (!_isTmuxActive || connectionId == null || sessionName == null) {
      return fallbackDirectory;
    }

    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null) {
      return fallbackDirectory;
    }

    final backend = _activeTerminalConnectionBackend(session);
    final windowKey = resolveTmuxBarActiveWindowKey(
      _currentTmuxWindowsSnapshot,
    );
    final paneContext = await backend.currentPaneContext();
    if (!_ownsTerminalConnectionBackend(session, backend, windowKey)) {
      return null;
    }
    final paneDirectory = normalizeSftpAbsolutePath(paneContext?.currentPath);
    if (paneDirectory == null) {
      return fallbackDirectory;
    }
    final paneCommand = paneContext?.currentCommand?.trim();
    if (mounted &&
        (paneDirectory != _tmuxWorkingDirectory ||
            paneCommand != _tmuxCurrentCommand)) {
      setState(() {
        _tmuxWorkingDirectory = paneDirectory;
        _tmuxCurrentCommand = paneCommand == null || paneCommand.isEmpty
            ? null
            : paneCommand;
      });
    }
    return paneDirectory;
  }

  Future<void> _jumpToPreviousCommandMark() async {
    final session = _sessionController.observedSession ?? _activeSession();
    final viewState = _terminalViewKey.currentState;
    if (session == null ||
        viewState == null ||
        !_terminalScrollController.hasClients) {
      return;
    }
    final lineHeight = viewState.renderTerminal.lineHeight;
    if (!lineHeight.isFinite || lineHeight <= 0) return;
    final position = _terminalScrollController.position;
    final currentTopRow = (position.pixels / lineHeight).floor();
    final commandMarkCount = session.terminalCommandMarkTracker.markCount;
    final continuesNavigation =
        _previousCommandNavigationConnectionId == session.connectionId &&
        _previousCommandNavigationMarkCount == commandMarkCount &&
        _previousCommandNavigationRow != null;
    final beforeRow = continuesNavigation
        ? _previousCommandNavigationRow!
        : position.pixels >= position.maxScrollExtent - 1
        ? _terminal.buffer.height
        : currentTopRow;
    final targetRow = session.terminalCommandMarkTracker.previousMarkRow(
      beforeRow,
    );
    if (targetRow == null) return;
    _previousCommandNavigationConnectionId = session.connectionId;
    _previousCommandNavigationRow = targetRow;
    _previousCommandNavigationMarkCount = commandMarkCount;
    final targetOffset = (targetRow * lineHeight).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _isNavigatingCommandMarks = true;
    try {
      await _terminalScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isNavigatingCommandMarks = false;
    }
  }

  Future<void> _openAgentManagement() async {
    if (!await requireMonetizationFeatureAccess(
          context: context,
          ref: ref,
          feature: MonetizationFeature.agentManagement,
        ) ||
        !mounted) {
      return;
    }

    final connectionId = _connectionId;
    if (connectionId == null) return;
    final session = _sessionsNotifier?.getSession(connectionId);
    if (session == null || !mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => AgentManagementScreen(
          session: session,
          onRuntimesRefreshed: (runtimes) =>
              _syncAgentUpdateStatus(session, runtimes),
          onProvidersRefreshed: () {
            _tmuxService.invalidateInstalledAgentTools(session.connectionId);
            unawaited(_tmuxService.prefetchInstalledAgentTools(session));
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  void _scheduleAgentUpdateCheck(
    SshSession session, {
    bool initialCheck = true,
  }) {
    _agentUpdateCheckTimer?.cancel();
    _agentUpdateCheckTimer = Timer(
      initialCheck ? const Duration(seconds: 10) : const Duration(minutes: 5),
      () async {
        if (!mounted || _connectionId != session.connectionId) return;
        if (!_wasBackgrounded &&
            (ModalRoute.of(context)?.isCurrent ?? false) &&
            _sessionsNotifier?.getState(session.connectionId) ==
                SshConnectionState.connected) {
          await _checkAgentUpdateStatus(session, forceRefresh: !initialCheck);
        }
        // Schedule after completion so slow SSH/registry calls cannot overlap.
        if (mounted && _connectionId == session.connectionId) {
          _scheduleAgentUpdateCheck(session, initialCheck: false);
        }
      },
    );
  }

  void _syncAgentUpdateStatus(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) {
    // Session-owned state survives reopening a live terminal without rechecking.
    _agentUpdateRuntimes[session] = List.unmodifiable(runtimes);
    if (mounted && _connectionId == session.connectionId) setState(() {});
  }

  Future<void> _checkAgentUpdateStatus(
    SshSession session, {
    bool forceRefresh = false,
  }) async {
    if ((!forceRefresh && _agentUpdateRuntimes[session] != null) ||
        !ref.read(agentUpdateNotificationsNotifierProvider)) {
      return;
    }
    if (!await ref
            .read(monetizationServiceProvider)
            .canUseFeature(MonetizationFeature.agentManagement) ||
        !mounted) {
      return;
    }
    final previous = _agentUpdateRuntimes[session];
    try {
      final service = ref.read(agentManagementServiceProvider);
      final runtimes = forceRefresh
          ? await service.checkForUpdates(session, forceRefresh: true)
          : await service.checkForUpdates(session);
      // Keep the existing dot while checking, or if the remote probe failed.
      // A manager refresh is newer than this background check.
      if (identical(_agentUpdateRuntimes[session], previous) &&
          (runtimes.isEmpty ||
              !runtimes.every(
                (runtime) => runtime.status == AgentRuntimeStatus.failed,
              ))) {
        _syncAgentUpdateStatus(session, runtimes);
      }
    } on Object {
      // Retry on the next interval without discarding the last known status.
    }
  }

  ({bool visible, bool enabled}) get _forceMonkeyMuxReloadMenuState {
    final session = _activeSession();
    final sessionName = _tmuxSessionName ?? session?.remoteMuxSessionName;
    return resolveForceMonkeyMuxReloadMenuState(
      backend: _activeMuxBackend,
      connected:
          !_isConnecting &&
          session != null &&
          _sessionsNotifier?.getState(session.connectionId) ==
              SshConnectionState.connected,
      hasLiveControlChannel:
          session != null &&
          sessionName != null &&
          _monkeyMuxService.hasLiveControlChannel(session, sessionName),
    );
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'snippets':
        await _showSnippetPicker();
        break;
      case 'change_theme':
        unawaited(_showThemePicker());
        break;
      case 'agent_management':
        await _openAgentManagement();
        break;
      case 'open_port_forward_browser':
        await _openPortForwardBrowserFromTerminal();
        break;
      case 'port_forwards':
        await _openPortForwardsFromTerminal();
        break;
      case 'force_monkeymux_reload':
        if (!_forceMonkeyMuxReloadMenuState.enabled) return;
        final sessionName =
            _tmuxSessionName ?? _activeSession()?.remoteMuxSessionName;
        if (sessionName == null || sessionName.trim().isEmpty) return;
        final request = MonkeyMuxForcedReloadRequest(sessionName.trim());
        _forcedMonkeyMuxReloadRequest = request;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Forcing MonkeyMux reload…')),
        );
        try {
          await _reconnect();
        } finally {
          request.cancel();
          if (identical(_forcedMonkeyMuxReloadRequest, request)) {
            _forcedMonkeyMuxReloadRequest = null;
          }
        }
        break;
      case 'toggle_device_debug':
        await _toggleDeviceDebug();
        break;
      case 'toggle_terminal_info':
        setState(() => _showsTerminalMetadata = !_showsTerminalMetadata);
        break;
      case 'toggle_tmux_bar':
        final shouldShowTmuxBar = !_showTmuxBar;
        if (!shouldShowTmuxBar) {
          _collapseTmuxBarIfExpanded();
        }
        setState(() => _showTmuxBar = shouldShowTmuxBar);
        break;
      case 'toggle_tap_keyboard':
        final notifier = ref.read(tapToShowKeyboardNotifierProvider.notifier);
        await notifier.setEnabled(
          enabled: !ref.read(tapToShowKeyboardNotifierProvider),
        );
        break;
      case 'toggle_shell_completions':
        final notifier = ref.read(shellCompletionsNotifierProvider.notifier);
        final enabled = !ref.read(shellCompletionsNotifierProvider);
        await notifier.setEnabled(enabled: enabled);
        if (!enabled) {
          _hideShellCompletionPopup();
        }
        break;
      case 'native_select':
        _toggleNativeSelectionMode();
        break;
      case 'previous_command':
        await _jumpToPreviousCommandMark();
        break;
      case 'copy_working_directory':
        await _copyWorkingDirectory();
        break;
      case 'create_snippet':
        await _createSnippetFromSelection();
        break;
      case 'paste':
        await _pasteClipboard();
        break;
      case 'paste_media':
        await _pastePickedMedia();
        break;
      case 'paste_file':
        await _pastePickedFiles();
        break;
      case 'disconnect':
        await _disconnect();
        break;
    }
  }

  void _toggleNativeSelectionMode() {
    if (_isMobilePlatform) return;
    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
    } else {
      _terminalController.clearSelection();
      _terminalFocusNode.unfocus();
      setState(() => _isNativeSelectionMode = true);
    }
  }

  void _exitNativeSelectionMode() {
    if (!mounted || !_isNativeSelectionMode) return;
    setState(() => _isNativeSelectionMode = false);
    _terminalController.clearSelection();
    _terminalFocusNode.requestFocus();
  }

  ({String text, List<int> columnOffsets}) _buildTerminalLineSnapshot(
    BufferLine line,
    int viewWidth, {
    required bool preserveTrailingPadding,
    int preserveOffset = 0,
  }) {
    final builder = StringBuffer();
    final columnOffsets = List<int>.filled(viewWidth + 1, 0);
    var col = 0;

    while (col < viewWidth) {
      final startOffset = builder.length;
      columnOffsets[col] = startOffset;
      final codePoint = line.getCodePoint(col);
      final width = line.getWidth(col);

      if (codePoint == 0) {
        builder.writeCharCode(0x20);
        columnOffsets[col + 1] = builder.length;
        col++;
        continue;
      }

      builder.writeCharCode(codePoint);
      final step = (width <= 0 ? 1 : width).clamp(1, viewWidth - col);
      for (var i = col + 1; i < col + step; i++) {
        columnOffsets[i] = startOffset;
      }
      columnOffsets[col + step] = builder.length;
      col += step;
    }

    final rawText = builder.toString();
    final resolvedLength = resolveTerminalLineSnapshotTextLength(
      text: rawText,
      preserveOffset: preserveOffset,
      preserveTrailingPadding: preserveTrailingPadding,
    );
    if (resolvedLength == rawText.length) {
      return (text: rawText, columnOffsets: columnOffsets);
    }

    for (var i = 0; i < columnOffsets.length; i++) {
      if (columnOffsets[i] > resolvedLength) {
        columnOffsets[i] = resolvedLength;
      }
    }
    return (
      text: rawText.substring(0, resolvedLength),
      columnOffsets: columnOffsets,
    );
  }

  ({String text, List<int> columnOffsets}) _buildNativeSelectionLineSnapshot(
    BufferLine line,
    int viewWidth,
  ) => _buildTerminalLineSnapshot(
    line,
    viewWidth,
    preserveTrailingPadding: false,
  );

  String? _resolveTerminalLinkTap(CellOffset offset) {
    var target = _resolveTerminalExternalLinkAtOffset(
      offset,
      forgiving: _isMobilePlatform,
    );
    if (target == null && ref.read(terminalPathLinksNotifierProvider)) {
      final detectedPath = _resolveTerminalFilePathAtOffset(
        offset,
        forgiving: _isMobilePlatform,
      );
      if (detectedPath != null) {
        target = '$_terminalSftpPathPrefix$detectedPath';
      } else {
        final pendingTarget = _pendingTerminalTargetTap;
        if (pendingTarget != null &&
            pendingTarget.startsWith(_terminalSftpPathPrefix) &&
            _isInteractiveTerminalFilePath(
              pendingTarget.substring(_terminalSftpPathPrefix.length),
            )) {
          target = pendingTarget;
        }
      }
    }
    _clearPendingTerminalTargetTap();
    if (_recentlyOpenedTerminalTargetTap == target) {
      _recentlyOpenedTerminalTargetTap = null;
      return null;
    }
    return target;
  }

  String? _resolveTerminalExternalLinkAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    if (!shouldResolveTerminalTapLinks(
      showsNativeSelectionOverlay: _isNativeSelectionMode,
    )) {
      return null;
    }

    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(offset)
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final trackedHyperlink = _terminalHyperlinkTracker?.resolveLinkAt(
        candidateOffset,
      );
      if (trackedHyperlink != null) {
        return trackedHyperlink;
      }

      final row = candidateOffset.y.clamp(0, _terminal.buffer.height - 1);
      final column = candidateOffset.x.clamp(0, _terminal.buffer.viewWidth - 1);
      final line = _terminal.buffer.lines[row];
      if (line.getCodePoint(column) == 0) {
        continue;
      }

      // Use the cross-rendered-line snapshot (the same one that reconstructs
      // wrapped file paths) so a URL split across a program's bordered TUI
      // lines is rejoined before detection.
      final linkSnapshot = _buildTerminalPathTapSnapshot(row);
      if (linkSnapshot == null) {
        continue;
      }

      final rowIndex = row - linkSnapshot.startRow;
      if (rowIndex < 0 || rowIndex >= linkSnapshot.columnOffsets.length) {
        continue;
      }
      final textOffset =
          linkSnapshot.rowStarts[rowIndex] +
          linkSnapshot.columnOffsets[rowIndex][column];
      final detectedLink = detectTerminalLinkAtTextOffset(
        linkSnapshot.text,
        textOffset,
      );
      if (detectedLink != null) {
        return detectedLink.uri.toString();
      }
    }

    // Forgiving touch fallback: a short OSC 8 label such as `#587` is easy to
    // miss with a finger, so open the link when the tapped row carries exactly
    // one tracked hyperlink.
    if (forgiving) {
      final rowLink = _terminalHyperlinkTracker?.resolveLinkOnRow(
        offset.y.clamp(0, _terminal.buffer.height - 1),
      );
      if (rowLink != null) {
        return rowLink;
      }
    }

    return null;
  }

  String? _resolveTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final detectedPath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: forgiving,
    );
    if (detectedPath == null) {
      return null;
    }

    // Prime verification even for optimistically active paths so the link can
    // shrink to (or drop below) the longest existing substring once resolved.
    _primeTerminalFilePathVerification(detectedPath);
    return _isInteractiveTerminalFilePath(detectedPath) ? detectedPath : null;
  }

  String? _detectTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(offset)
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final detectedPath = _detectTerminalFilePathAtCell(candidateOffset);
      if (detectedPath != null) {
        return detectedPath;
      }
    }
    if (forgiving) {
      final segments = _resolveInteractiveTerminalPathSegmentsOnRow(offset.y);
      return segments.length == 1 ? segments.single.path : null;
    }
    return null;
  }

  String? _detectTerminalFilePathAtCell(CellOffset offset) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    // OSC 8 hyperlinks are authoritative: only linkify text that is not already
    // a program-declared link.
    if (_terminalHyperlinkTracker?.resolveLinkAt(CellOffset(column, row)) !=
        null) {
      return null;
    }
    final pathSnapshot = _buildTerminalPathTapSnapshot(row);
    if (pathSnapshot == null) {
      return null;
    }

    return _detectTerminalFilePathInSnapshotAtCell(pathSnapshot, offset);
  }

  String? _detectTerminalFilePathInSnapshotAtCell(
    _TerminalPathTapSnapshot pathSnapshot,
    CellOffset offset,
  ) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) == 0) {
      return null;
    }

    final pathRowIndex = row - pathSnapshot.startRow;
    if (pathRowIndex < 0 || pathRowIndex >= pathSnapshot.columnOffsets.length) {
      return null;
    }

    final rowColumnOffsets = pathSnapshot.columnOffsets[pathRowIndex];
    if (column >= rowColumnOffsets.length) {
      return null;
    }

    final pathTextOffset =
        pathSnapshot.rowStarts[pathRowIndex] + rowColumnOffsets[column];
    final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      final activePath = _interactiveTerminalFilePathCandidate(
        detectedPath.path,
      );
      final activeEnd = activePath == null
          ? detectedPath.hitTestEnd
          : _resolveOriginalTerminalPathMatchEnd(
              normalizedSnapshot: snapshotAnalysis.normalizedSnapshot,
              normalizedStart: detectedPath.normalizedStart,
              normalizedLength: activePath.length,
            );
      if (activeEnd == null) {
        continue;
      }
      if (pathTextOffset >= detectedPath.start && pathTextOffset < activeEnd) {
        return detectedPath.path;
      }
    }
    return null;
  }

  _TerminalPathTapSnapshot? _buildTerminalPathTapSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    // Locate the canonical start of the wrapped-line group so that all rows
    // in the group share the same cache key.
    var cacheKey = row;
    while (cacheKey > 0 && buffer.lines[cacheKey].isWrapped) {
      cacheKey--;
    }

    // Invalidate snapshot and analysis caches when content has changed.
    if (_terminalPathSnapshotCacheGeneration != _terminalContentGeneration) {
      _terminalPathSnapshotCacheGeneration = _terminalContentGeneration;
      _terminalPathSnapshotCache.clear();
      _terminalPathAnalysisCache.clear();
    }

    if (_terminalPathSnapshotCache.containsKey(cacheKey)) {
      return _terminalPathSnapshotCache[cacheKey];
    }

    String lineTextAt(int lineIndex) => _buildNativeSelectionLineSnapshot(
      buffer.lines[lineIndex],
      buffer.viewWidth,
    ).text;

    var startRow = cacheKey;
    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    while (startRow > 0 &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(startRow - 1),
          nextLineText: lineTextAt(startRow),
        )) {
      startRow--;
    }

    while (endRow + 1 < buffer.height &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(endRow),
          nextLineText: lineTextAt(endRow + 1),
        )) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = _buildNativeSelectionLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
      );
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
      if (lineIndex < endRow && !buffer.lines[lineIndex + 1].isWrapped) {
        builder.write('\n');
      }
    }

    final snapshot = (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
    _terminalPathSnapshotCache[cacheKey] = snapshot;
    return snapshot;
  }

  void _handleTerminalPathHover(PointerHoverEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null ||
        !ref.read(terminalPathLinksNotifierProvider) ||
        !ref.read(terminalPathLinkUnderlinesNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final isSameHoveredCell =
        _lastHoveredTerminalPathOffset?.x == offset.x &&
        _lastHoveredTerminalPathOffset?.y == offset.y;
    final detectedPath = isSameHoveredCell
        ? _lastHoveredTerminalPath
        : _resolveTerminalFilePathAtOffset(offset);
    if (!isSameHoveredCell) {
      _lastHoveredTerminalPathOffset = offset;
      _lastHoveredTerminalPath = detectedPath;
    }
    if (detectedPath == null || !_shouldShowTerminalPathBadge(detectedPath)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final hoveredSegment = _resolveInteractiveTerminalPathSegmentAtOffset(
      offset,
      path: detectedPath,
    );
    if (hoveredSegment == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final underline = _buildTerminalPathInlineUnderline(
      row: offset.y,
      startColumn: hoveredSegment.startColumn,
      endColumn: hoveredSegment.endColumn,
    );
    if (underline == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    if (_hoveredTerminalPathUnderline == underline) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = underline);
  }

  void _clearPendingTerminalTargetTap() {
    _pendingTerminalTargetTap = null;
    _pendingTerminalTargetTapPointer = null;
    _pendingTerminalTargetTapDownPosition = null;
    _pendingTerminalTargetTapDownTimestamp = null;
  }

  void _clearPendingTerminalDoubleTap() {
    _pendingTerminalDoubleTapPointer = null;
    _pendingTerminalDoubleTapDownPosition = null;
    _pendingTerminalDoubleTapDownTimestamp = null;
  }

  void _clearLastTerminalTap() {
    _lastTerminalTapPosition = null;
    _lastTerminalTapTimestamp = null;
  }

  void _pauseTerminalOutputFollowForTouch(PointerDownEvent event) {
    if (!_isMobilePlatform || event.kind != PointerDeviceKind.touch) {
      return;
    }

    if (_terminalOutputPauseTouchPointers.add(event.pointer)) {
      if (_terminalScrollController.hasClients) {
        _lastTerminalScrollOffset = _terminalScrollController.offset;
        _setShouldFollowLiveOutput(
          shouldFollowTerminalOutput(
            hasScrollClients: true,
            currentOffset: _terminalScrollController.offset,
            maxScrollExtent: _terminalScrollController.position.maxScrollExtent,
          ),
        );
      }
      _syncTerminalLiveOutputAutoScroll();
      setState(() {});
    }
  }

  void _resumeTerminalOutputFollowForTouch(int pointer) {
    if (!_terminalOutputPauseTouchPointers.remove(pointer)) {
      return;
    }

    _syncTerminalLiveOutputAutoScroll();
    setState(() {});
    if (_terminalOutputPauseTouchPointers.isNotEmpty ||
        !_shouldFollowLiveOutput ||
        _isTerminalOutputFollowPaused) {
      return;
    }

    _queueTerminalScrollToBottom();
  }

  void _syncTerminalLiveOutputAutoScroll() {
    _terminalViewKey.currentState?.renderTerminal.liveOutputAutoScroll =
        _terminalLiveOutputAutoScrollEnabled;
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _pauseTerminalOutputFollowForTouch(event);
    _handleTerminalTargetPointerDown(event);
    _handleTerminalDoubleTapPointerDown(
      event,
      allowDoubleTap: _pendingTerminalTargetTap == null,
    );
    _handleTerminalMouseTapPointerDown(
      event,
      allowTap:
          _pendingTerminalTargetTap == null &&
          _terminalDoubleTapConsumedPointer != event.pointer,
    );
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    _handleTerminalTargetPointerMove(event);
    _handleTerminalDoubleTapPointerMove(event);
    _handleTerminalMouseTapPointerMove(event);
  }

  void _handleTerminalPointerUp(PointerUpEvent event) {
    if (!_handleTerminalTargetPointerUp(event)) {
      _handleTerminalDoubleTapPointerUp(event);
      _handleTerminalMouseTapPointerUp(event);
    } else {
      _clearPendingTerminalMouseTap(event.pointer);
      _clearLastTerminalTap();
    }
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalTargetTapPointer == event.pointer) {
      _clearPendingTerminalTargetTap();
    }
    _handleTerminalDoubleTapPointerCancel(event);
    _clearPendingTerminalMouseTap(event.pointer);
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalTargetPointerDown(PointerDownEvent event) {
    _clearPendingTerminalTargetTap();
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final localPosition = terminalViewState.renderTerminal.globalToLocal(
      event.position,
    );
    final offset = terminalViewState.renderTerminal.getCellOffset(
      localPosition,
    );
    final link = event.kind == PointerDeviceKind.touch
        ? _resolveTerminalExternalLinkAtOffset(offset, forgiving: true)
        : null;
    final path = link == null
        ? _resolveTerminalPointerPath(event, offset, localPosition)
        : null;
    final target =
        link ?? (path == null ? null : '$_terminalSftpPathPrefix$path');
    if (target == null) {
      return;
    }
    if (link != null) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    _pendingTerminalTargetTap = target;
    _pendingTerminalTargetTapPointer = event.pointer;
    _pendingTerminalTargetTapDownPosition = event.position;
    _pendingTerminalTargetTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalTargetPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalTargetTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalTargetTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalTargetTap();
    }
  }

  bool _handleTerminalTargetPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }

    final pendingTarget = _pendingTerminalTargetTap;
    final downPosition = _pendingTerminalTargetTapDownPosition;
    final downTimestamp = _pendingTerminalTargetTapDownTimestamp;
    if (pendingTarget == null ||
        _pendingTerminalTargetTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalTargetTap();
      return pendingTarget != null;
    }

    _clearPendingTerminalTargetTap();
    _recentlyOpenedTerminalTargetTap = pendingTarget;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_recentlyOpenedTerminalTargetTap == pendingTarget) {
        _recentlyOpenedTerminalTargetTap = null;
      }
    });
    _handleTerminalLinkTap(pendingTarget);
    return true;
  }

  void _handleTerminalMouseTapPointerDown(
    PointerDownEvent event, {
    required bool allowTap,
  }) {
    _clearPendingTerminalMouseTap();
    final terminalViewState = _terminalViewKey.currentState;
    if (event.kind != PointerDeviceKind.touch ||
        !allowTap ||
        terminalViewState == null ||
        !terminalViewState.shouldSendTerminalTapPointerInput) {
      return;
    }

    _pendingTerminalMouseTapPointer = event.pointer;
    _pendingTerminalMouseTapDownPosition = event.position;
    _pendingTerminalMouseTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalMouseTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalMouseTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalMouseTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
    }
  }

  void _handleTerminalMouseTapPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch ||
        _terminalDoubleTapConsumedPointer == event.pointer) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    final downPosition = _pendingTerminalMouseTapDownPosition;
    final downTimestamp = _pendingTerminalMouseTapDownTimestamp;
    if (_pendingTerminalMouseTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    _clearPendingTerminalMouseTap(event.pointer);
    _terminalViewKey.currentState?.sendTerminalPrimaryTap(event.position);
  }

  void _clearPendingTerminalMouseTap([int? pointer]) {
    if (pointer != null && _pendingTerminalMouseTapPointer != pointer) {
      return;
    }
    _pendingTerminalMouseTapPointer = null;
    _pendingTerminalMouseTapDownPosition = null;
    _pendingTerminalMouseTapDownTimestamp = null;
  }

  void _handleTerminalDoubleTapPointerDown(
    PointerDownEvent event, {
    required bool allowDoubleTap,
  }) {
    if (event.kind != PointerDeviceKind.touch || !allowDoubleTap) {
      _clearPendingTerminalDoubleTap();
      return;
    }

    final lastTapPosition = _lastTerminalTapPosition;
    final lastTapTimestamp = _lastTerminalTapTimestamp;
    final isDoubleTap =
        lastTapPosition != null &&
        lastTapTimestamp != null &&
        event.timeStamp - lastTapTimestamp <= kDoubleTapTimeout &&
        (event.position - lastTapPosition).distance <= kDoubleTapSlop;

    if (isDoubleTap) {
      // Let SelectionArea handle text selection without also forwarding the
      // second tap as terminal mouse input.
      _terminalDoubleTapConsumedPointer = event.pointer;
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _pendingTerminalDoubleTapPointer = event.pointer;
    _pendingTerminalDoubleTapDownPosition = event.position;
    _pendingTerminalDoubleTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalDoubleTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalDoubleTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalDoubleTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
    }
  }

  void _handleTerminalDoubleTapPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
      _clearPendingTerminalDoubleTap();
      return;
    }

    final downPosition = _pendingTerminalDoubleTapDownPosition;
    final downTimestamp = _pendingTerminalDoubleTapDownTimestamp;
    if (_pendingTerminalDoubleTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _lastTerminalTapPosition = event.position;
    _lastTerminalTapTimestamp = event.timeStamp;
    _clearPendingTerminalDoubleTap();
  }

  void _handleTerminalDoubleTapPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalDoubleTapPointer == event.pointer) {
      _clearPendingTerminalDoubleTap();
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
    }
  }

  String? _resolveTerminalPointerPath(
    PointerDownEvent event,
    CellOffset offset,
    Offset terminalLocalPosition,
  ) {
    if (!ref.read(terminalPathLinksNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return null;
    }
    final terminalViewObject = _terminalViewKey.currentState!.context
        .findRenderObject();
    final terminalViewLocalPosition = terminalViewObject is RenderBox
        ? terminalViewObject.globalToLocal(event.position)
        : terminalLocalPosition;
    final candidatePath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: event.kind == PointerDeviceKind.touch,
    );
    final underlinePath = event.kind == PointerDeviceKind.touch
        ? resolveTerminalPathTouchTargetTap(terminalViewLocalPosition, [
            for (final underline in _visibleTerminalPathUnderlines)
              (path: underline.path, touchRect: underline.touchRect),
          ])
        : null;
    final tappedPath = candidatePath ?? underlinePath;
    if (tappedPath != null && event.kind == PointerDeviceKind.touch) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    if (candidatePath != null &&
        !_isInteractiveTerminalFilePath(candidatePath)) {
      _primeTerminalFilePathVerification(candidatePath);
    }
    return tappedPath != null && _isInteractiveTerminalFilePath(tappedPath)
        ? tappedPath
        : null;
  }

  void _clearHoveredTerminalPathUnderline() {
    _lastHoveredTerminalPathOffset = null;
    _lastHoveredTerminalPath = null;
    if (_hoveredTerminalPathUnderline == null || !mounted) {
      return;
    }
    setState(() => _hoveredTerminalPathUnderline = null);
  }

  bool _shouldShowTerminalPathBadge(String path) =>
      _isInteractiveTerminalFilePath(path);

  void _queueVisibleTerminalPathUnderlineRefresh() {
    if (!_isMobilePlatform ||
        _isTerminalPathUnderlineRefreshQueued ||
        !mounted) {
      return;
    }

    _isTerminalPathUnderlineRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalPathUnderlineRefreshQueued = false;
      if (!mounted) {
        return;
      }
      _refreshVisibleTerminalPathUnderlines();
    });
  }

  void _refreshVisibleTerminalPathUnderlines() {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled) {
      _refreshVisibleTerminalPathUnderlinesImpl();
      return;
    }
    final stopwatch = Stopwatch()..start();
    _refreshVisibleTerminalPathUnderlinesImpl();
    final micros = stopwatch.elapsedMicroseconds;
    if (micros < 4000) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _terminalPathUnderlineRefreshLogAtMs < 1000) {
      return;
    }
    _terminalPathUnderlineRefreshLogAtMs = nowMs;
    diagnostics.debug(
      'terminal.paths',
      'underline_refresh',
      fields: {
        'durationMs': (micros / 1000).round(),
        'underlines': _visibleTerminalPathUnderlines.length,
      },
    );
  }

  void _refreshVisibleTerminalPathUnderlinesImpl() {
    final terminalViewState = _terminalViewKey.currentState;
    final showsUnderlines =
        ref.read(terminalPathLinksNotifierProvider) &&
        ref.read(terminalPathLinkUnderlinesNotifierProvider);
    if (!_isMobilePlatform || !showsUnderlines || terminalViewState == null) {
      if (_visibleTerminalPathUnderlines.isNotEmpty) {
        setState(
          () => _visibleTerminalPathUnderlines =
              const <
                ({String path, TerminalTextUnderline underline, Rect touchRect})
              >[],
        );
      }
      return;
    }

    final renderTerminal = terminalViewState.renderTerminal;
    final rowRange = resolveVisibleTerminalRowRange(
      scrollOffset: _terminalScrollController.hasClients
          ? _terminalScrollController.offset
          : 0,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: renderTerminal.size.height,
      bufferHeight: _terminal.buffer.height,
    );
    if (rowRange == null) {
      return;
    }

    final underlines =
        <({String path, TerminalTextUnderline underline, Rect touchRect})>[];
    final buffer = _terminal.buffer;
    var row = rowRange.topRow;
    while (row <= rowRange.bottomRow) {
      // Skip single, non-wrapped rows that contain no path-like characters.
      // This avoids the expensive snapshot-building step for the majority of
      // output lines that can never match a file path.
      final isSingleRow =
          !buffer.lines[row].isWrapped &&
          (row + 1 >= buffer.height || !buffer.lines[row + 1].isWrapped);
      if (isSingleRow &&
          !terminalRowMayContainPath(buffer.lines[row], buffer.viewWidth)) {
        row++;
        continue;
      }
      final pathSnapshot = _buildTerminalPathTapSnapshot(row);
      if (pathSnapshot == null) {
        row++;
        continue;
      }
      final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
      final snapshotEndRow =
          pathSnapshot.startRow + pathSnapshot.columnOffsets.length - 1;
      final visibleSnapshotBottom = min(rowRange.bottomRow, snapshotEndRow);
      for (
        var snapshotRow = max(row, pathSnapshot.startRow);
        snapshotRow <= visibleSnapshotBottom;
        snapshotRow++
      ) {
        final segments = _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
          snapshotRow,
          pathSnapshot: pathSnapshot,
          snapshotAnalysis: snapshotAnalysis,
        );
        for (final segment in segments) {
          if (!_shouldShowTerminalPathBadge(segment.path)) {
            continue;
          }
          final underline = _buildTerminalPathInlineUnderline(
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          final touchRect = _buildTerminalPathTouchTargetRect(
            terminalViewState,
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          if (underline != null && touchRect != null) {
            underlines.add((
              path: segment.path,
              underline: underline,
              touchRect: touchRect,
            ));
          }
        }
      }
      row = visibleSnapshotBottom + 1;
    }

    if (!listEquals(_visibleTerminalPathUnderlines, underlines)) {
      setState(() => _visibleTerminalPathUnderlines = underlines);
    }
  }

  TerminalTextUnderline? _buildTerminalPathInlineUnderline({
    required int row,
    required int startColumn,
    required int endColumn,
  }) => resolveTerminalPathInlineUnderline(
    row: row,
    startColumn: startColumn,
    endColumn: endColumn,
    rowCount: _terminal.buffer.height,
    columnCount: _terminal.buffer.viewWidth,
  );

  Rect? _buildTerminalPathTouchTargetRect(
    MonkeyTerminalViewState terminalViewState, {
    required int row,
    required int startColumn,
    required int endColumn,
  }) {
    final terminalViewObject = terminalViewState.context.findRenderObject();
    if (terminalViewObject is! RenderBox) {
      return null;
    }
    final renderTerminal = terminalViewState.renderTerminal;
    final lineTopLeft = renderTerminal.localToGlobal(
      renderTerminal.getOffset(CellOffset(startColumn, row)),
      ancestor: terminalViewObject,
    );
    final lineEndOffset = renderTerminal.localToGlobal(
      renderTerminal.getOffset(
        CellOffset((endColumn + 1).clamp(0, _terminal.buffer.viewWidth), row),
      ),
      ancestor: terminalViewObject,
    );
    return resolveTerminalPathTouchTargetRect(
      lineTopLeft: lineTopLeft,
      lineEndOffset: lineEndOffset,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: terminalViewObject.size.height,
    );
  }

  ({String path, String text, int startColumn, int endColumn})?
  _resolveInteractiveTerminalPathSegmentAtOffset(
    CellOffset offset, {
    String? path,
  }) {
    for (final segment in _resolveInteractiveTerminalPathSegmentsOnRow(
      offset.y,
    )) {
      if (offset.x >= segment.startColumn &&
          offset.x <= segment.endColumn &&
          (path == null || segment.path == path)) {
        return segment;
      }
    }
    return null;
  }

  _TerminalPathSnapshotAnalysis _analyzeTerminalPathSnapshot(
    _TerminalPathTapSnapshot pathSnapshot,
  ) {
    final cached = _terminalPathAnalysisCache[pathSnapshot.text];
    if (cached != null) return cached;
    final normalizedSnapshot = _normalizeTerminalFilePathDetectionText(
      pathSnapshot.text,
    );
    final analysis = (
      detectedPaths: _detectTerminalFilePathMatches(normalizedSnapshot),
      normalizedSnapshot: normalizedSnapshot,
    );
    _terminalPathAnalysisCache[pathSnapshot.text] = analysis;
    return analysis;
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsOnRow(int row) {
    final clampedRow = row.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(clampedRow);
    if (pathSnapshot == null) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    return _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
      clampedRow,
      pathSnapshot: pathSnapshot,
      snapshotAnalysis: _analyzeTerminalPathSnapshot(pathSnapshot),
    );
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
    int row, {
    required _TerminalPathTapSnapshot pathSnapshot,
    required _TerminalPathSnapshotAnalysis snapshotAnalysis,
  }) {
    final rowIndex = row - pathSnapshot.startRow;
    if (rowIndex < 0 || rowIndex >= pathSnapshot.columnOffsets.length) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }
    if (snapshotAnalysis.detectedPaths.isEmpty) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    final rowStart = pathSnapshot.rowStarts[rowIndex];
    final rowColumnOffsets = pathSnapshot.columnOffsets[rowIndex];
    final rowEnd = rowStart + rowColumnOffsets.last;
    final rowText = pathSnapshot.text.substring(rowStart, rowEnd);
    final rowNormalizedStart = snapshotAnalysis
        .normalizedSnapshot
        .originalToNormalizedOffsets[rowStart];
    final rowNormalizedEnd =
        snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets[rowEnd];
    final candidatesToPrime = <String>{};
    final segments =
        <({String path, String text, int startColumn, int endColumn})>[];
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      if (detectedPath.normalizedEnd <= rowNormalizedStart ||
          detectedPath.normalizedStart >= rowNormalizedEnd) {
        continue;
      }

      final path = detectedPath.path;
      // Verify every detected path so its link is trimmed to the longest
      // existing substring (and dropped if no substring exists remotely).
      candidatesToPrime.add(path);
      final activePath = _interactiveTerminalFilePathCandidate(path);
      if (activePath != null) {
        final visibleSegment = resolveTerminalFilePathSegmentOnRow(
          rowText: rowText,
          rowStartOffset: rowStart,
          rowColumnOffsets: rowColumnOffsets,
          originalToNormalizedOffsets:
              snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets,
          normalizedPathStart: detectedPath.normalizedStart,
          normalizedPathEnd: detectedPath.normalizedStart + activePath.length,
        );
        if (visibleSegment == null) {
          continue;
        }
        // Don't layer heuristic file-path linkification over a program-declared
        // OSC 8 hyperlink: only linkify text that is not already a link.
        if (_terminalHyperlinkTracker?.hasLinkInRowRange(
              row,
              visibleSegment.startColumn,
              visibleSegment.endColumn,
            ) ??
            false) {
          continue;
        }
        segments.add((
          path: path,
          text: visibleSegment.text,
          startColumn: visibleSegment.startColumn,
          endColumn: visibleSegment.endColumn,
        ));
      }
    }

    for (final path in candidatesToPrime) {
      _primeTerminalFilePathVerification(path);
    }

    return segments;
  }

  ({String text, int cursorOffset})? _buildWrappedTerminalCommandSnapshot() {
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final cursorColumn = buffer.cursorX.clamp(0, buffer.viewWidth);
    var cursorOffset = 0;
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      final lineSnapshot = _buildTerminalLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
        preserveTrailingPadding: lineIndex < endRow,
        preserveOffset: lineIndex == row ? cursorColumn : 0,
      );
      if (lineIndex == row) {
        cursorOffset =
            builder.length + lineSnapshot.columnOffsets[cursorColumn];
      }
      builder.write(lineSnapshot.text);
    }

    return (text: builder.toString(), cursorOffset: cursorOffset);
  }

  String? _terminalTextBeforeCursor() {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return null;
    }
    return snapshot.text.substring(0, snapshot.cursorOffset);
  }

  void _handleTerminalLinkTap(String link) {
    _clearHoveredTerminalPathUnderline();
    if (link.startsWith(_terminalSftpPathPrefix)) {
      unawaited(
        _openTerminalFilePath(link.substring(_terminalSftpPathPrefix.length)),
      );
      return;
    }

    // `file:` links name a file on the connected host, so open them in the
    // SFTP browser rather than launching them externally.
    final fileUriPath = resolveTerminalFileUriPath(link);
    if (fileUriPath != null) {
      unawaited(_openTerminalFilePath(fileUriPath));
      return;
    }

    unawaited(_openTerminalLink(link));
  }

  void _showTerminalLinkMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTerminalLink(String link) async {
    final normalizedLink = normalizeTerminalLinkCandidate(link);
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null) {
      _showTerminalLinkMessage('Could not open $link');
      return;
    }

    if (!isLaunchableTerminalUri(uri)) {
      _showTerminalLinkMessage('Blocked unsupported link scheme: $link');
      return;
    }

    if (isPortForwardBrowserSupported() &&
        ref.read(portForwardBrowserLinksNotifierProvider)) {
      final options = _activePortForwardBrowserOptions();
      _PortForwardBrowserOption? targetOption;
      Uri? browserUri;
      for (final option in options) {
        final rewritten = rewriteUriForPortForwardBrowser(
          uri,
          sourceUri: option.sourceUri,
          browserUri: option.uri,
        );
        if (rewritten != null) {
          targetOption = option;
          browserUri = rewritten;
          break;
        }
      }
      if (targetOption != null && browserUri != null) {
        await _openPortForwardBrowserOption(
          _PortForwardBrowserOption(
            uri: browserUri,
            sourceUri: targetOption.sourceUri,
            fallbackUri: targetOption.fallbackUri,
            port: targetOption.port,
            title: targetOption.title,
            group: targetOption.group,
          ),
        );
        return;
      }
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (launched || !mounted) {
      return;
    }

    _showTerminalLinkMessage('Could not open $link');
  }

  List<_PortForwardBrowserOption> _activePortForwardBrowserOptions() {
    final sessions = ref.read(activeSessionsProvider.notifier);
    final hostTunnels = sessions.getActiveTunnelsForHost(widget.hostId);
    final fallbackSession = _sessionController.observedSession;
    final tunnels = hostTunnels.isNotEmpty
        ? hostTunnels
        : fallbackSession?.activeTunnels ?? const <ActiveTunnelInfo>[];
    final options =
        tunnels
            .map(_portForwardBrowserOptionForTunnel)
            .whereType<_PortForwardBrowserOption>()
            .toList(growable: false)
          ..sort((left, right) {
            final groupComparison = left.group.index.compareTo(
              right.group.index,
            );
            return groupComparison != 0
                ? groupComparison
                : left.port.compareTo(right.port);
          });
    return options;
  }

  _PortForwardBrowserOption? _portForwardBrowserOptionForTunnel(
    ActiveTunnelInfo tunnel,
  ) {
    final browserHost = tunnel.browserHost;
    final browserPort = tunnel.browserPort;
    if (!tunnel.isLocal ||
        !isPortForwardBrowserHost(tunnel.localHost) ||
        tunnel.localPort < 1 ||
        tunnel.localPort > 65535 ||
        browserHost == null ||
        browserPort == null ||
        browserPort < 1 ||
        browserPort > 65535) {
      return null;
    }

    final sourcePort = tunnel.isAutomatic
        ? tunnel.remotePort
        : tunnel.localPort;
    final sourceUri = buildPortForwardBrowserUriForBind(
      localHost: tunnel.isAutomatic ? tunnel.remoteHost : tunnel.localHost,
      localPort: sourcePort,
    );
    final uri = buildPortForwardBrowserUriForBind(
      localHost: browserHost,
      localPort: browserPort,
    );
    final fallbackHost = tunnel.browserFallbackHost;
    final fallbackUri = fallbackHost == null
        ? null
        : buildPortForwardBrowserUriForBind(
            localHost: fallbackHost,
            localPort: tunnel.localPort,
          );
    return _PortForwardBrowserOption(
      uri: uri,
      sourceUri: sourceUri,
      fallbackUri: fallbackUri,
      port: sourcePort,
      title: tunnel.isAutomatic
          ? 'Port ${tunnel.remotePort}'
          : sourceUri.authority,
      group: tunnel.isAutomatic
          ? (tunnel.isShellRelated
                ? PortForwardBrowserTabGroup.savedHost
                : PortForwardBrowserTabGroup.sharedHost)
          : PortForwardBrowserTabGroup.savedForward,
    );
  }

  Future<void> _openPortForwardBrowserTunnel(ActiveTunnelInfo tunnel) async {
    final option = _portForwardBrowserOptionForTunnel(tunnel);
    if (option == null) {
      _showTerminalLinkMessage('This forward is not available in the browser');
      return;
    }
    await _openPortForwardBrowserOption(option);
  }

  Future<void> _openPortForwardBrowserFromTerminal() async {
    final options = _activePortForwardBrowserOptions();
    if (options.isEmpty) {
      _showTerminalLinkMessage('No active localhost port forwards to browse');
      return;
    }

    await _openPortForwardBrowserOptions(options);
  }

  Future<void> _openPortForwardsFromTerminal() async {
    final connectionId = _connectionId;
    final session = connectionId == null
        ? null
        : ref.read(activeSessionsProvider.notifier).getSession(connectionId);
    if (connectionId == null || session == null) {
      _showTerminalLinkMessage('Connect before managing live port forwards');
      return;
    }

    final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
    try {
      await showTerminalPortForwardsSheet(
        context: context,
        hostId: widget.hostId,
        connectionId: connectionId,
        session: session,
        onOpenInBrowser: _openPortForwardBrowserTunnel,
      );
    } finally {
      _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
    }
  }

  Future<void> _openPortForwardBrowserOption(
    _PortForwardBrowserOption option,
  ) => _openPortForwardBrowserOptions([option]);

  Future<void> _openPortForwardBrowserOptions(
    List<_PortForwardBrowserOption> options,
  ) async {
    await context.pushNamed<void>(
      Routes.portForwardBrowser,
      extra: PortForwardBrowserLaunch(
        tabs: [
          for (final option in options)
            PortForwardBrowserInitialTab(
              uri: option.uri,
              sourceUri: option.sourceUri,
              fallbackUri: option.fallbackUri,
              title: option.title,
              group: option.group,
            ),
        ],
      ),
    );
  }

  Future<void> _openTerminalFilePath(String path) =>
      _runExclusiveTerminalAction(
        _TerminalExclusiveAction.sftpBrowser,
        () async {
          final normalizedPath = trimTerminalFilePathCandidate(path);
          if (!isSupportedTerminalFilePath(normalizedPath)) {
            _showTerminalLinkMessage('Could not open $path');
            return;
          }

          final verifiedPath = await _resolveVerifiedTerminalFilePath(
            normalizedPath,
          );
          if (!mounted || verifiedPath == null) {
            return;
          }
          unawaited(
            ref.read(telemetryServiceProvider).logTerminalPathLinkOpened(),
          );

          final connectionId = _connectionId;
          final cwd = _workingDirectoryPath;
          final tmuxPaneDirectory = await _resolveCurrentTmuxPaneDirectory();
          if (!mounted) {
            return;
          }

          final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
          String? result;
          try {
            result = await context.pushNamed<String>(
              Routes.sftp,
              pathParameters: {'hostId': widget.hostId.toString()},
              queryParameters: _buildSftpBrowserQueryParameters(
                connectionId: connectionId,
                initialPath: verifiedPath,
                workingDirectory: cwd,
                tmuxPaneDirectory: tmuxPaneDirectory,
              ),
            );
          } finally {
            _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
            _resetTerminalScrollAfterSftpBrowserClosed(
              forceFullRepaint: true,
              focusAlreadyRestored: shouldRestoreKeyboard,
            );
          }

          if (mounted && result != null) {
            _showTerminalLinkMessage(result);
          }
        },
      );

  void _resetTerminalScrollAfterSftpBrowserClosed({
    bool forceFullRepaint = false,
    bool focusAlreadyRestored = false,
  }) {
    if (!mounted) {
      return;
    }

    // The terminal route stays mounted under SFTP, so reset accumulated gesture
    // deltas before the first scroll after the browser pops.
    _terminalOutputPauseTouchPointers.clear();
    setState(() {
      _terminalScrollResetGeneration += 1;
    });
    _syncTerminalLiveOutputAutoScroll();

    if (forceFullRepaint) {
      _terminalViewKey.currentState?.forceFullRepaint();
    }

    _rearmForegroundAppMouseReportingAfterOverlay(
      focusAlreadyRestored: focusAlreadyRestored,
    );
  }

  /// Re-emits a focus-in report after an overlay route (the SFTP browser)
  /// closes.
  ///
  /// Opening the browser calls [_temporarilyDismissTerminalKeyboard], which
  /// unfocuses the terminal and therefore emits a focus-out report. Focus-aware
  /// TUIs such as Copilot CLI in the alternate screen disable mouse-wheel
  /// reporting on focus-out, so touch scroll would stay frozen after the
  /// browser closes until the next window switch re-emits focus reports. The
  /// keyboard-restore path only refocuses when the soft keyboard was visible,
  /// so a plain scroll interaction never regained focus and never reported
  /// focus-in. Restore focus so the terminal emits the matching focus-in report
  /// (gated on the foreground app's own focus-report mode, so bare shells are
  /// unaffected) and the app re-enables mouse reporting.
  ///
  /// When [focusAlreadyRestored] is true the keyboard-restore path already
  /// requested focus (and emitted the focus-in report), so skip a second
  /// focus request to avoid scheduling a duplicate post-frame IME reset in the
  /// same frame, which can flicker or desync the soft keyboard on mobile.
  void _rearmForegroundAppMouseReportingAfterOverlay({
    bool focusAlreadyRestored = false,
  }) {
    if (!_isMobilePlatform || focusAlreadyRestored) {
      return;
    }
    _restoreTerminalFocus();
  }

  Future<void> _createSnippetFromSelection() async {
    final text = _currentTerminalSelectionText();
    if (text == null) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    await _createSnippetFromTerminalSelectionText(text);
  }

  Future<void> _createSnippetFromTerminalSelectionText(String text) async {
    final command = text.trimRight();
    if (command.isEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    if (_isNativeSelectionMode) {
      _exitNativeSelectionMode();
    } else {
      _terminalController.clearSelection();
    }

    await context.pushNamed<void>(
      Routes.snippetAdd,
      extra: SnippetEditPrefill(
        name: buildSnippetNameFromTerminalSelection(command),
        command: command,
      ),
    );
    if (mounted) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    }
  }

  Future<void> _copySelectionText(
    String text, {
    required bool clearTerminalSelection,
    required bool restoreFocus,
  }) async {
    if (text.isEmpty) {
      if (restoreFocus) {
        _restoreTerminalFocus();
      }
      return;
    }

    await _writeLocalClipboardText(text);
    if (clearTerminalSelection) {
      _terminalController.clearSelection();
      if (_isNativeSelectionMode) _exitNativeSelectionMode();
    }
    if (restoreFocus) {
      _restoreTerminalFocus();
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  String? _currentTerminalSelectionText() {
    if (_isNativeSelectionMode) {
      return _readSystemSelectionPlainText();
    }
    final selection = _terminalController.selection;
    final terminalControllerText = selection == null
        ? null
        : trimTerminalSelectionText(_terminal.buffer.getText(selection));
    return resolveTerminalSelectionPlainText(
      terminalControllerSelectionText: terminalControllerText,
      systemSelectionPlainText: _readSystemSelectionPlainText(),
    );
  }

  // Reads the live system selection from the terminal's render object. This is
  // the source of truth on mobile (`useSystemSelection: true`), where Flutter's
  // SelectionArea owns the selection rather than the xterm controller.
  String? _readSystemSelectionPlainText() {
    final state = _terminalViewKey.currentState;
    if (state == null) {
      return null;
    }
    try {
      return state.renderTerminal.getSelectedContent()?.plainText;
    } on Object {
      return null;
    }
  }

  Future<void> _lookUpTerminalSelectionText(String text) async {
    try {
      await SystemChannels.platform.invokeMethod<void>('LookUp.invoke', text);
    } on PlatformException {
      // Platform doesn't support LookUp; ignore.
    }
  }

  Future<void> _searchWebForTerminalSelectionText(String text) async {
    try {
      await SystemChannels.platform.invokeMethod<void>(
        'SearchWeb.invoke',
        text,
      );
    } on PlatformException {
      // Platform doesn't support SearchWeb; ignore.
    }
  }

  Future<void> _shareTerminalSelectionText(String text) async {
    try {
      await SystemChannels.platform.invokeMethod<void>('Share.invoke', text);
    } on PlatformException {
      // Platform doesn't support Share; ignore.
    }
  }

  Future<void> _writeLocalClipboardText(String text) async {
    _recentLocalClipboardText = text;
    _recentLocalClipboardAt = DateTime.now();
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _showClipboardMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyWorkingDirectory() async {
    final path = _workingDirectoryPath;
    if (path == null || path.isEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    await _writeLocalClipboardText(path);
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied current directory')));
  }

  SshSession? _activeSession() {
    final connectionId = _connectionId;
    final sessionsNotifier = _sessionsNotifier;
    if (connectionId == null || sessionsNotifier == null) {
      return null;
    }
    return sessionsNotifier.getSession(connectionId);
  }

  String _terminalPathCacheKey(String terminalPath) =>
      '${_currentTerminalPathCacheScope()}:$terminalPath';

  String _currentTerminalPathCacheScope() =>
      '${widget.hostId}:${_connectionId ?? 0}:${_workingDirectoryPath ?? ''}';

  void _syncVerifiedTerminalPathCacheScope() {
    final nextScope = _currentTerminalPathCacheScope();
    if (_terminalPathCacheScope == nextScope) {
      return;
    }
    _terminalPathCacheScope = nextScope;
    _resetVerifiedTerminalPathCache();
  }

  void _resetVerifiedTerminalPathCache() {
    _verifiedTerminalPathCache.clear();
    _activeTerminalPathVerificationKey = null;
    _pendingTerminalPathVerifications.clear();
  }

  void _cacheVerifiedTerminalPath(
    String cacheKey, {
    required String terminalPath,
    required String resolvedPath,
  }) => _storeVerifiedTerminalPath(cacheKey, (
    terminalPath: terminalPath,
    resolvedPath: resolvedPath,
    exists: true,
  ));

  /// Remembers that no substring of the path at [cacheKey] exists remotely, so
  /// the link is dropped and the dead path is not repeatedly re-probed.
  void _cacheNonexistentTerminalPath(
    String cacheKey, {
    required String terminalPath,
  }) => _storeVerifiedTerminalPath(cacheKey, (
    terminalPath: terminalPath,
    resolvedPath: '',
    exists: false,
  ));

  void _storeVerifiedTerminalPath(
    String cacheKey,
    _VerifiedTerminalPath verifiedPath,
  ) {
    _verifiedTerminalPathCache.remove(cacheKey);
    _verifiedTerminalPathCache[cacheKey] = verifiedPath;
    while (_verifiedTerminalPathCache.length >
        _maxVerifiedTerminalPathCacheEntries) {
      _verifiedTerminalPathCache.remove(_verifiedTerminalPathCache.keys.first);
    }
  }

  void _disposeTerminalPathVerificationSftp() {
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationSftpFuture = null;
    _terminalPathVerificationSession = null;
    _terminalPathVerificationHomeDirectory = null;
    _terminalPathVerificationBackoffUntil = null;
    _pendingTerminalPathVerifications.clear();
    _activeTerminalPathVerificationKey = null;
  }

  Future<SftpClient> _openTerminalPathVerificationSftp(
    SshSession session,
  ) async {
    final sftpOpenFuture = session.sftp();
    try {
      return await sftpOpenFuture.timeout(_terminalPathVerificationTimeout);
    } on TimeoutException {
      session.discardSftpOpen(sftpOpenFuture);
      rethrow;
    }
  }

  Future<SftpClient?> _resolveTerminalPathVerificationSftp(
    SshSession session, {
    required bool allowBackoff,
  }) async {
    if (!identical(_terminalPathVerificationSession, session)) {
      if (_terminalPathVerificationSession != null) {
        _disposeTerminalPathVerificationSftp();
      }
      _terminalPathVerificationSession = session;
    }

    final cachedSftp = _terminalPathVerificationSftp;
    if (cachedSftp != null) {
      return cachedSftp;
    }

    final inFlight = _terminalPathVerificationSftpFuture;
    if (inFlight != null) {
      return inFlight;
    }

    if (allowBackoff && _isTerminalPathVerificationBackedOff()) {
      DiagnosticsLogService.instance.debug(
        'terminal',
        'sftp_path_resolution_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return null;
    }

    final future = _openTerminalPathVerificationSftp(session).then<SftpClient?>(
      (sftp) {
        if (!identical(_terminalPathVerificationSession, session)) {
          return null;
        }
        _terminalPathVerificationBackoffUntil = null;
        _terminalPathVerificationSftp = sftp;
        return sftp;
      },
    );
    _terminalPathVerificationSftpFuture = future;
    try {
      return await future;
    } on Object catch (error) {
      _recordTerminalPathVerificationBackoff(session, error);
      rethrow;
    } finally {
      if (identical(_terminalPathVerificationSftpFuture, future)) {
        _terminalPathVerificationSftpFuture = null;
      }
    }
  }

  bool _isTerminalPathVerificationBackedOff() =>
      _terminalPathVerificationBackoffRemaining() != null;

  Duration? _terminalPathVerificationBackoffRemaining() {
    final backoffUntil = _terminalPathVerificationBackoffUntil;
    if (backoffUntil == null) {
      return null;
    }
    final remaining = backoffUntil.difference(DateTime.now());
    if (remaining > Duration.zero) {
      return remaining;
    }
    _terminalPathVerificationBackoffUntil = null;
    return null;
  }

  void _recordTerminalPathVerificationBackoff(
    SshSession session,
    Object error,
  ) {
    if (!_isRecoverableTerminalPathVerificationSftpError(error)) {
      return;
    }
    _terminalPathVerificationBackoffUntil = DateTime.now().add(
      _terminalPathVerificationChannelBackoff,
    );
    DiagnosticsLogService.instance.debug(
      'terminal',
      'sftp_path_resolution_backoff',
      fields: {
        'connectionId': session.connectionId,
        'delayMs': _terminalPathVerificationChannelBackoff.inMilliseconds,
        'errorType': error.runtimeType.toString(),
      },
    );
  }

  bool _isRecoverableTerminalPathVerificationSftpError(Object error) =>
      error is TimeoutException ||
      error is SSHError ||
      error is SftpError && error is! SftpStatusError;

  void _handleTerminalPathVerificationSftpFailure(
    SftpClient sftp,
    Object error,
  ) {
    if (!_isRecoverableTerminalPathVerificationSftpError(error)) {
      return;
    }
    final session = _terminalPathVerificationSession;
    if (session != null) {
      _recordTerminalPathVerificationBackoff(session, error);
    }
    if (!identical(_terminalPathVerificationSftp, sftp)) {
      return;
    }
    DiagnosticsLogService.instance.debug(
      'terminal',
      'sftp_path_resolution_client_discarded',
      fields: {
        if (session != null) 'connectionId': session.connectionId,
        'errorType': error.runtimeType.toString(),
      },
    );
    session?.discardSftpClient(sftp);
    _terminalPathVerificationSftp = null;
    _terminalPathVerificationHomeDirectory = null;
  }

  Future<String?> _resolveTerminalPathVerificationHomeDirectory(
    SftpClient sftp,
    String terminalPath,
    String scope,
  ) async {
    if (terminalPath != '~' && !terminalPath.startsWith('~/')) {
      return null;
    }
    final cachedHomeDirectory = _terminalPathVerificationHomeDirectory;
    if (cachedHomeDirectory != null) {
      return cachedHomeDirectory;
    }

    final homeDirectory = normalizeSftpAbsolutePath(
      await _resolveTerminalPathVerificationSftpOperation(
        sftp,
        () => sftp.absolute('.'),
        scope: scope,
      ),
    );
    if (!mounted ||
        scope != _currentTerminalPathCacheScope() ||
        !identical(sftp, _terminalPathVerificationSftp) ||
        !identical(_activeSession(), _terminalPathVerificationSession)) {
      return null;
    }
    _terminalPathVerificationHomeDirectory = homeDirectory;
    return homeDirectory;
  }

  Future<T> _resolveTerminalPathVerificationSftpOperation<T>(
    SftpClient sftp,
    Future<T> Function() operation, {
    required String scope,
  }) async {
    try {
      return await operation().timeout(_terminalPathVerificationTimeout);
    } on Object catch (error) {
      if (mounted &&
          scope == _currentTerminalPathCacheScope() &&
          identical(_activeSession(), _terminalPathVerificationSession) &&
          identical(sftp, _terminalPathVerificationSftp)) {
        _handleTerminalPathVerificationSftpFailure(sftp, error);
      }
      rethrow;
    }
  }

  _VerifiedTerminalPath? _verifiedTerminalPath(String terminalPath) {
    _syncVerifiedTerminalPathCacheScope();
    return _verifiedTerminalPathCache[_terminalPathCacheKey(terminalPath)];
  }

  String? _interactiveTerminalFilePathCandidate(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      // Verification has resolved: link the longest existing substring, or
      // nothing if no substring of the path exists remotely.
      return verifiedPath.exists ? verifiedPath.terminalPath : null;
    }
    // Verification is still pending: optimistically link explicit paths so the
    // link appears immediately, then it shrinks (or drops) once `stat` lands.
    return _isOptimisticTerminalFilePath(terminalPath) ? terminalPath : null;
  }

  bool _isInteractiveTerminalFilePath(String terminalPath) {
    final verifiedPath = _verifiedTerminalPath(terminalPath);
    if (verifiedPath != null) {
      return verifiedPath.exists;
    }
    return _isOptimisticTerminalFilePath(terminalPath);
  }

  /// Whether a not-yet-verified path should behave like a link in the meantime.
  bool _isOptimisticTerminalFilePath(String terminalPath) =>
      shouldActivateTerminalFilePath(terminalPath, hasVerifiedPath: false);

  void _primeTerminalFilePathVerification(String terminalPath) {
    if (!isSupportedTerminalFilePath(terminalPath)) {
      return;
    }

    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    if (_verifiedTerminalPathCache.containsKey(cacheKey) ||
        _activeTerminalPathVerificationKey == cacheKey ||
        _pendingTerminalPathVerifications.containsKey(cacheKey)) {
      return;
    }

    _enqueueTerminalPathVerification(cacheKey, terminalPath);
    _scheduleTerminalPathVerificationBatch();
  }

  void _enqueueTerminalPathVerification(String cacheKey, String terminalPath) {
    _pendingTerminalPathVerifications[cacheKey] = terminalPath;
    while (_pendingTerminalPathVerifications.length >
        _maxVerifiedTerminalPathCacheEntries) {
      _pendingTerminalPathVerifications.remove(
        _pendingTerminalPathVerifications.keys.first,
      );
    }
  }

  void _scheduleTerminalPathVerificationBatch([
    Duration delay = _terminalPathVerificationBatchDelay,
  ]) {
    if (_isTerminalPathVerificationBatchScheduled) {
      return;
    }
    _isTerminalPathVerificationBatchScheduled = true;
    // Use a cancelable timer (not Future.delayed) so the pending batch is torn
    // down in dispose() rather than lingering until it fires.
    _terminalPathVerificationBatchTimer = Timer(delay, () async {
      _terminalPathVerificationBatchTimer = null;
      Duration? nextDelay;
      try {
        if (!mounted) {
          _pendingTerminalPathVerifications.clear();
          _activeTerminalPathVerificationKey = null;
          return;
        }
        nextDelay = await _verifyPendingTerminalFilePaths();
      } finally {
        _isTerminalPathVerificationBatchScheduled = false;
        if (mounted && _pendingTerminalPathVerifications.isNotEmpty) {
          _scheduleTerminalPathVerificationBatch(
            nextDelay ?? _terminalPathVerificationBatchDelay,
          );
        }
      }
    });
  }

  Future<Duration?> _verifyPendingTerminalFilePaths() async {
    _syncVerifiedTerminalPathCacheScope();
    if (_pendingTerminalPathVerifications.isEmpty) {
      return null;
    }

    final backoffRemaining = _terminalPathVerificationBackoffRemaining();
    if (backoffRemaining != null) {
      DiagnosticsLogService.instance.debug(
        'terminal',
        'sftp_path_resolution_batch_deferred',
        fields: {'pendingCount': _pendingTerminalPathVerifications.length},
      );
      return backoffRemaining;
    }

    final session = _activeSession();
    if (session == null) {
      _pendingTerminalPathVerifications.clear();
      _activeTerminalPathVerificationKey = null;
      return null;
    }

    final scope = _currentTerminalPathCacheScope();
    final workingDirectory = _workingDirectoryPath;
    bool ownsScope() =>
        mounted &&
        scope == _currentTerminalPathCacheScope() &&
        identical(session, _activeSession());
    var cacheChanged = false;
    try {
      final sftp = await _resolveTerminalPathVerificationSftp(
        session,
        allowBackoff: true,
      );
      if (sftp == null || !ownsScope()) {
        return null;
      }

      while (_pendingTerminalPathVerifications.isNotEmpty) {
        if (!ownsScope()) return null;
        final entry = _pendingTerminalPathVerifications.entries.first;
        _pendingTerminalPathVerifications.remove(entry.key);
        _activeTerminalPathVerificationKey = entry.key;
        if (_verifiedTerminalPathCache.containsKey(entry.key)) {
          continue;
        }
        try {
          await _resolveVerifiedTerminalFilePathWithSftp(
            sftp,
            entry.value,
            showErrors: false,
            scope: scope,
            workingDirectory: workingDirectory,
          );
          // A positive or negative result was cached: refresh underlines so an
          // optimistic link shrinks to (or drops below) the verified extent.
          cacheChanged = true;
        } on TimeoutException {
          rethrow;
        } on SftpStatusError {
          // Background path verification is opportunistic.
        } on SSHError {
          rethrow;
        } on SftpError {
          rethrow;
        } on Object catch (error, stackTrace) {
          DiagnosticsLogService.instance.warning(
            'terminal',
            'sftp_path_resolution_failed',
            fields: {'errorType': error.runtimeType.toString()},
          );
          if (kDebugMode) {
            debugPrint('Failed to resolve terminal file path: $error');
            debugPrint('$stackTrace');
          }
        }
      }
    } on Object catch (error, stackTrace) {
      if (!ownsScope()) return null;
      // Background verification is opportunistic. Abandon this batch on a
      // client failure instead of retrying it indefinitely while output is
      // idle. New output can enqueue these paths again, respecting channel
      // backoff; failures must not be cached as nonexistent paths.
      _pendingTerminalPathVerifications.clear();
      if (_isTerminalPathVerificationBackedOff()) {
        return null;
      }
      DiagnosticsLogService.instance.warning(
        'terminal',
        'sftp_path_resolution_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      if (kDebugMode) {
        debugPrint('Failed to resolve terminal file paths: $error');
        debugPrint('$stackTrace');
      }
    } finally {
      _activeTerminalPathVerificationKey = null;
    }

    if (cacheChanged && ownsScope()) {
      setState(() {
        _shouldScheduleVisibleTerminalPathUnderlineRefreshFromBuild = true;
      });
    }
    return null;
  }

  Future<String?> _resolveVerifiedTerminalFilePathWithSftp(
    SftpClient sftp,
    String terminalPath, {
    required bool showErrors,
    required String scope,
    required String? workingDirectory,
  }) async {
    bool ownsScope() =>
        mounted &&
        scope == _currentTerminalPathCacheScope() &&
        identical(sftp, _terminalPathVerificationSftp) &&
        identical(_activeSession(), _terminalPathVerificationSession);
    if (!ownsScope()) return null;
    final cacheKey = '$scope:$terminalPath';
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.exists ? cachedPath.resolvedPath : null;
    }

    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    // Probe from the full path down through its directory prefixes so the
    // longest substring that actually exists wins (candidates are ordered
    // longest first).
    final verificationCandidates = resolveTerminalFilePathExistenceCandidates(
      terminalPath,
    );
    for (final candidate in verificationCandidates) {
      final homeDirectory = await _resolveTerminalPathVerificationHomeDirectory(
        sftp,
        candidate,
        scope,
      );
      if (!ownsScope()) return null;
      final resolvedPath = resolveRequestedSftpPath(
        candidate,
        workingDirectory: workingDirectory,
        homeDirectory: homeDirectory,
      );
      if (resolvedPath == null) {
        continue;
      }

      try {
        await _resolveTerminalPathVerificationSftpOperation(
          sftp,
          () => sftp.stat(resolvedPath),
          scope: scope,
        );
      } on SftpStatusError catch (error) {
        if (!ownsScope()) return null;
        if (error.code == SftpStatusCode.noSuchFile) {
          continue;
        }
        rethrow;
      }

      if (!ownsScope()) return null;
      _cacheVerifiedTerminalPath(
        cacheKey,
        terminalPath: candidate,
        resolvedPath: resolvedPath,
      );
      return resolvedPath;
    }

    if (!ownsScope()) return null;
    _cacheNonexistentTerminalPath(cacheKey, terminalPath: terminalPath);
    if (showErrors && isExplicitPath) {
      _showTerminalLinkMessage(
        'Could not open "$terminalPath" in SFTP: path does not exist',
      );
    }
    return null;
  }

  Future<String?> _resolveVerifiedTerminalFilePath(String terminalPath) async {
    _syncVerifiedTerminalPathCacheScope();
    final cacheKey = _terminalPathCacheKey(terminalPath);
    final cachedPath = _verifiedTerminalPathCache[cacheKey];
    if (cachedPath != null) {
      return cachedPath.exists ? cachedPath.resolvedPath : null;
    }

    final scope = _currentTerminalPathCacheScope();
    final workingDirectory = _workingDirectoryPath;
    final session = _activeSession();
    final isExplicitPath = isExplicitTerminalFilePath(terminalPath);
    if (session == null) {
      if (isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }

    try {
      final sftp = await _resolveTerminalPathVerificationSftp(
        session,
        allowBackoff: false,
      );
      if (sftp == null) {
        return null;
      }
      return await _resolveVerifiedTerminalFilePathWithSftp(
        sftp,
        terminalPath,
        showErrors: true,
        scope: scope,
        workingDirectory: workingDirectory,
      );
    } on TimeoutException {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      if (isExplicitPath) {
        _showTerminalLinkMessage('Timed out opening "$terminalPath" in SFTP');
      }
      return null;
    } on SftpStatusError catch (error) {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      if (isExplicitPath) {
        final message = error.code == SftpStatusCode.noSuchFile
            ? 'Could not open "$terminalPath" in SFTP: path does not exist'
            : 'Could not open "$terminalPath" in SFTP';
        _showTerminalLinkMessage(message);
      }
      return null;
    } on Object catch (error, stackTrace) {
      if (!mounted ||
          scope != _currentTerminalPathCacheScope() ||
          !identical(session, _activeSession())) {
        return null;
      }
      DiagnosticsLogService.instance.warning(
        'terminal',
        'sftp_path_resolution_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (kDebugMode) {
        debugPrint(
          'Failed to resolve terminal file path "$terminalPath": $error',
        );
        debugPrint('$stackTrace');
      }
      if (isExplicitPath) {
        _showTerminalLinkMessage('Could not open "$terminalPath" in SFTP');
      }
      return null;
    }
  }

  int? _resolveOriginalTerminalPathMatchEnd({
    required _NormalizedTerminalPathSnapshot normalizedSnapshot,
    required int normalizedStart,
    required int normalizedLength,
  }) {
    if (normalizedLength <= 0) {
      return null;
    }

    final normalizedEnd = normalizedStart + normalizedLength;
    if (normalizedEnd > normalizedSnapshot.normalizedToOriginalEnds.length) {
      return null;
    }

    return normalizedSnapshot.normalizedToOriginalEnds[normalizedEnd - 1];
  }

  Future<void> _pasteClipboard() async {
    final inputGeneration = _terminalUserInputGeneration;
    try {
      if (_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final clipboardFiles = await Pasteboard.files();
      if (clipboardFiles.isNotEmpty) {
        await _pasteClipboardFiles(clipboardFiles);
        return;
      }

      if (!_isAndroidPlatform) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes);
          return;
        }
      }

      final text = await _readSystemClipboardText();
      if (text == null || text.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage('Clipboard is empty');
        return;
      }

      final initialPasteMode = await _resolveSettledTerminalPasteMode();
      if (initialPasteMode == null || !mounted) {
        if (mounted) {
          _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        }
        return;
      }
      var pasteMode = initialPasteMode;
      if (!_terminalPasteModeOwnsCurrentContext(pasteMode)) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_context_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }
      if (!_terminalPasteModeTargetsCurrentWindow(pasteMode)) {
        _syncTerminalModesFromActiveMuxWindow();
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_window_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }
      if (!_terminalPasteModeCanUseResolvedState(pasteMode)) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_mode_unavailable',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage(
          'Could not verify bracketed paste mode. Try again.',
        );
        return;
      }

      final requiredReview = _shouldReviewTerminalCommandInsertion;
      var reviewedBracketedPasteMode = _effectiveTerminalBracketedPasteMode(
        pasteMode,
      );
      if (requiredReview) {
        var modeStableAfterReview = false;
        for (var reviewAttempt = 0; reviewAttempt < 2; reviewAttempt++) {
          var reviewShown = false;
          final shouldPaste = await _confirmTerminalInsertionIfNeeded(
            insertedText: text,
            buildReview: (commandText) => assessClipboardPasteCommand(
              commandText,
              bracketedPasteModeEnabled: reviewedBracketedPasteMode,
            ),
            title: 'Review clipboard paste',
            messageBuilder: (review) => review.bracketedPasteModeEnabled
                ? 'This clipboard content looks risky even with bracketed paste enabled.'
                : 'This clipboard content could execute multiple or reshaped commands.',
            confirmLabel: 'Paste anyway',
            onReviewShown: () => reviewShown = true,
          );
          if (!shouldPaste) {
            _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
            return;
          }
          if (!reviewShown) {
            modeStableAfterReview = true;
            break;
          }

          final refreshedPasteMode = await _resolveSettledTerminalPasteMode();
          if (refreshedPasteMode == null || !mounted) {
            if (mounted) {
              _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
            }
            return;
          }
          if (!_sameTerminalPasteContext(pasteMode, refreshedPasteMode) ||
              refreshedPasteMode.activeWindowKey != pasteMode.activeWindowKey ||
              !_terminalPasteModeOwnsCurrentContext(refreshedPasteMode)) {
            DiagnosticsLogService.instance.warning(
              'terminal.clipboard',
              'text_input_skipped_window_changed',
              fields: {'connectionId': _connectionId},
            );
            _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
            return;
          }
          pasteMode = refreshedPasteMode;
          if (!_terminalPasteModeCanUseResolvedState(pasteMode)) {
            DiagnosticsLogService.instance.warning(
              'terminal.clipboard',
              'text_input_skipped_mode_unavailable',
              fields: {'connectionId': _connectionId},
            );
            _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
            _showClipboardMessage(
              'Could not verify bracketed paste mode. Try again.',
            );
            return;
          }
          final refreshedBracketedPasteMode =
              _effectiveTerminalBracketedPasteMode(pasteMode);
          if (refreshedBracketedPasteMode == reviewedBracketedPasteMode) {
            modeStableAfterReview = true;
            break;
          }
          reviewedBracketedPasteMode = refreshedBracketedPasteMode;
        }
        if (!modeStableAfterReview) {
          DiagnosticsLogService.instance.warning(
            'terminal.clipboard',
            'text_input_skipped_mode_changed',
            fields: {'connectionId': _connectionId},
          );
          _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
          return;
        }
      }
      if (!_terminalPasteModeOwnsCurrentContext(pasteMode)) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_context_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }
      if (!_terminalPasteModeTargetsCurrentWindow(pasteMode)) {
        _syncTerminalModesFromActiveMuxWindow();
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_window_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      if (_terminalUserInputGeneration != inputGeneration) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_intervening_input',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        _showClipboardMessage('Paste canceled because terminal input changed.');
        return;
      }

      final modeReliable = _terminalPasteModeIsReliable(pasteMode);
      final modeUsable = _terminalPasteModeCanUseResolvedState(pasteMode);
      final usedBracketedPaste = _effectiveTerminalBracketedPasteMode(
        pasteMode,
      );
      _followLiveOutput();
      pasteTerminalTextWithBracketedPasteMode(
        terminal: pasteMode.terminal,
        text: text,
        bracketedPasteMode: usedBracketedPaste,
      );
      _terminalUserInputGeneration++;
      DiagnosticsLogService.instance.info(
        'terminal.clipboard',
        'text_input',
        fields: {
          'connectionId': pasteMode.connectionId,
          'bracketedPasteMode': pasteMode.bracketedPasteMode,
          'bracketedPasteModeKnown': pasteMode.bracketedPasteModeKnown,
          'modeReliable': modeReliable,
          'modeUsable': modeUsable,
          'usedBracketedPaste': usedBracketedPaste,
          'modeRefreshAttempted': pasteMode.refreshAttempted,
          'modeRefreshSucceeded': pasteMode.refreshSucceeded,
        },
      );
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalPasteUsed(
              source: 'clipboard_text',
              requiredReview: requiredReview,
            ),
      );
      _terminalController.clearSelection();
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    } on PlatformException catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'paste_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard access failed. Try again.');
    } on FileSystemException catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'file_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard file upload failed. Try again.');
    } on SftpError catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'remote_upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Remote upload failed. Check permissions and try again.',
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'upload_failed',
        fields: {'errorType': error.runtimeType},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard upload failed. Try again.');
    }
  }

  Future<void> _pastePickedMedia() async {
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logTerminalPasteUsed(source: 'picked_media', requiredReview: false),
    );
    final pickerRequest = resolveTerminalUploadPickerRequest(media: true);
    if (shouldUsePhotoLibraryPickerForTerminalMedia(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      await _pickAndPastePhotoLibraryMedia(
        itemLabelSingular: pickerRequest.itemLabelSingular,
        itemLabelPlural: pickerRequest.itemLabelPlural,
        failureContext: pickerRequest.failureContext,
      );
      return;
    }

    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
    );
  }

  Future<void> _pastePickedFiles() async {
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logTerminalPasteUsed(source: 'picked_files', requiredReview: false),
    );
    final pickerRequest = resolveTerminalUploadPickerRequest(media: false);
    await _pickAndPasteFiles(
      dialogTitle: pickerRequest.dialogTitle,
      pickerType: pickerRequest.pickerType,
      itemLabelSingular: pickerRequest.itemLabelSingular,
      itemLabelPlural: pickerRequest.itemLabelPlural,
      allowMultiple: pickerRequest.allowMultiple,
      failureContext: pickerRequest.failureContext,
    );
  }

  void _enableAndroidPhotoPickerIfAvailable() {
    if (!_isAndroidPlatform) {
      return;
    }
    final currentImagePicker = ImagePickerPlatform.instance;
    final androidImagePicker = enableAndroidPhotoPickerForTerminalMedia(
      currentImagePicker,
    );
    if (!identical(currentImagePicker, androidImagePicker)) {
      ImagePickerPlatform.instance = androidImagePicker;
    }
  }

  Future<void> _pickAndPastePhotoLibraryMedia({
    required String itemLabelSingular,
    required String itemLabelPlural,
    required String failureContext,
  }) async {
    try {
      _enableAndroidPhotoPickerIfAvailable();
      final selectedMedia = await ImagePicker().pickMultipleMedia(
        requestFullMetadata: false,
      );
      if (!mounted) {
        return;
      }
      if (selectedMedia.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      final selectedFiles = <PlatformFile>[];
      for (var index = 0; index < selectedMedia.length; index++) {
        selectedFiles.add(
          await platformFileFromPickedTerminalMedia(
            selectedMedia[index],
            index: index,
          ),
        );
      }
      if (!mounted) {
        return;
      }

      await _pasteSelectedFiles(
        selectedFiles,
        itemLabelSingular: itemLabelSingular,
        itemLabelPlural: itemLabelPlural,
      );
    } on Object catch (error) {
      _handlePickedFileFailure(error, failureContext);
    }
  }

  Future<void> _pickAndPasteFiles({
    required String dialogTitle,
    required FileType pickerType,
    required String itemLabelSingular,
    required String itemLabelPlural,
    required bool allowMultiple,
    required String failureContext,
  }) async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: pickerType,
      );
      if (!mounted) {
        return;
      }
      if (result.isEmpty) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return;
      }

      await _pasteSelectedFiles(
        result,
        itemLabelSingular: itemLabelSingular,
        itemLabelPlural: itemLabelPlural,
      );
    } on Object catch (error) {
      _handlePickedFileFailure(error, failureContext);
    }
  }

  void _handlePickedFileFailure(Object error, String failureContext) {
    final failure = pickedFileFailure(error, failureContext);
    DiagnosticsLogService.instance.warning(
      'terminal.clipboard',
      failure.category,
      fields: {'errorType': error.runtimeType},
    );
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    _showClipboardMessage(failure.message);
  }

  Future<T> _withClipboardSftp<T>(
    Future<T> Function(
      SftpClient sftp,
      RemoteFileService remoteFileService,
      _ClipboardUploadTarget uploadTarget,
    )
    action, {
    String? uploadBaseDirectory,
  }) async {
    final session = _activeSession();
    if (session == null) {
      throw StateError('Connection is not ready yet');
    }

    final remoteFileService = ref.read(remoteFileServiceProvider);
    _disposeTerminalPathVerificationSftp();
    final sftp = await session.sftp();
    try {
      final resolvedUploadBaseDirectory = uploadBaseDirectory?.trim();
      final homeDirectory = resolvedUploadBaseDirectory?.isNotEmpty ?? false
          ? resolvedUploadBaseDirectory!
          : await remoteFileService.resolveInitialDirectory(sftp);
      final appUploadParentDirectory =
          buildRemoteClipboardUploadParentDirectory(homeDirectory);
      final uploadDirectory = buildRemoteClipboardUploadDirectory(
        homeDirectory,
      );
      final uploadTarget = _ClipboardUploadTarget(
        sftpDirectory: uploadDirectory,
        windows: session.remoteIsWindows,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        appUploadParentDirectory,
        mode: uploadTarget.directoryMode,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        uploadDirectory,
        mode: uploadTarget.directoryMode,
      );
      return await action(sftp, remoteFileService, uploadTarget);
    } on TimeoutException {
      session.discardSftpClient(sftp);
      rethrow;
    } on SSHError {
      session.discardSftpClient(sftp);
      rethrow;
    } on SftpError catch (error) {
      if (error is! SftpStatusError) {
        session.discardSftpClient(sftp);
      }
      rethrow;
    }
  }

  Future<({String name, Uint8List bytes})> _readAndroidClipboardContentUri(
    String uri,
  ) => ref.read(clipboardContentServiceProvider).readContentUri(uri);

  Future<bool> _confirmClipboardUpload({
    required String title,
    required String message,
    required String confirmLabel,
    List<String> details = const [],
    Duration? autoConfirmAfter,
  }) async {
    if (!mounted) {
      return false;
    }
    final dialogState = _StoreDemoAutoConfirmDialogState();
    if (autoConfirmAfter != null) {
      unawaited(
        Future<void>.delayed(autoConfirmAfter, () {
          if (!mounted || !dialogState.open) {
            return;
          }
          final navigator = Navigator.of(context, rootNavigator: true);
          if (navigator.canPop()) {
            navigator.pop(true);
          }
        }),
      );
    }
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('\u2022 $detail'),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    dialogState.open = false;
    return confirmed ?? false;
  }

  /// Minimum delay between consecutive uploaded-file bracketed pastes.
  ///
  /// Agent CLIs such as Copilot CLI only register each pasted path as a separate
  /// attachment (one preview chip per file) when its bracketed pastes arrive as
  /// distinct input events; pastes delivered closer together are coalesced and
  /// shown as plain text. Empirically the coalescing window is ~200ms, so a
  /// single file is sent immediately and additional files are staggered by this
  /// margin above that threshold.
  static const _uploadedAttachmentPasteStagger = Duration(milliseconds: 300);

  /// Inserts references to just-uploaded [remotePaths] into the terminal.
  ///
  /// Each path is sent as its own bracketed paste so an agent CLI such as
  /// Copilot CLI shows a preview chip per file (and so plain shells receive the
  /// paths as distinct, space-separated arguments). Multiple files are staggered
  /// by [_uploadedAttachmentPasteStagger] so each registers as its own
  /// attachment. The pre-built segments are written straight to the session
  /// input via [Terminal.onOutput]; they must not go through [Terminal.paste],
  /// which would strip the bracketed-paste markers.
  Future<_AttachmentPasteResult> _insertUploadedFileReferences(
    List<String> remotePaths, {
    required bool windows,
    required int inputGeneration,
    required _TerminalPasteMode? pasteMode,
  }) async {
    final pathCount = remotePaths
        .where((remotePath) => remotePath.isNotEmpty)
        .length;
    _AttachmentPasteResult result(int sentCount) =>
        (requestedCount: pathCount, sentCount: sentCount);
    if (pathCount == 0) {
      return result(0);
    }
    var sentCount = 0;
    if (pasteMode == null || !mounted) {
      return result(sentCount);
    }
    if (!_terminalPasteModeOwnsCurrentContext(pasteMode)) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'attachment_input_skipped_context_changed',
        fields: {'connectionId': _connectionId, 'pathCount': pathCount},
      );
      return result(sentCount);
    }
    if (!_terminalPasteModeTargetsCurrentWindow(pasteMode)) {
      _syncTerminalModesFromActiveMuxWindow();
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'attachment_input_skipped_window_changed',
        fields: {'connectionId': _connectionId, 'pathCount': pathCount},
      );
      return result(sentCount);
    }
    final modeReliable = _terminalPasteModeIsReliable(pasteMode);
    final modeUsable = _terminalPasteModeCanUseResolvedState(pasteMode);
    if (!modeUsable) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'attachment_input_skipped_mode_unavailable',
        fields: {'connectionId': _connectionId, 'pathCount': pathCount},
      );
      return result(sentCount);
    }
    final usedBracketedPaste = _effectiveTerminalBracketedPasteMode(pasteMode);
    final injectViaMonkeyMuxControl =
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: usedBracketedPaste,
          isMuxActive: pasteMode.isMuxActive,
          muxBackend: pasteMode.muxBackend,
          hasSession: pasteMode.session != null,
          hasSessionName: pasteMode.muxSessionName != null,
          supportsBracketedPasteControlInput:
              pasteMode.session != null &&
              pasteMode.muxSessionName != null &&
              _monkeyMuxService.supportsBracketedPasteControlInput(
                pasteMode.session!,
                pasteMode.muxSessionName!,
              ),
        );
    final sendablePathCount = countTerminalAttachmentPastePaths(remotePaths);
    final segments = buildTerminalAttachmentPasteSegments(
      remotePaths,
      bracketedPasteMode: usedBracketedPaste,
      windows: windows,
      preferRawAgentPaths: _isAgentToolActive,
    );
    if (segments.isEmpty) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'attachment_input_skipped_unsafe_paths',
        fields: {'connectionId': _connectionId, 'pathCount': pathCount},
      );
      return result(sentCount);
    }
    DiagnosticsLogService.instance.debug(
      'terminal.clipboard',
      'attachment_input',
      fields: {
        'connectionId': _connectionId,
        'pathCount': pathCount,
        'segmentCount': segments.length,
        'bracketedPasteMode': pasteMode.bracketedPasteMode,
        'bracketedPasteModeKnown': pasteMode.bracketedPasteModeKnown,
        'modeReliable': modeReliable,
        'modeUsable': modeUsable,
        'usedBracketedPaste': usedBracketedPaste,
        'usedMuxControlInjection': injectViaMonkeyMuxControl,
        'modeRefreshAttempted': pasteMode.refreshAttempted,
        'modeRefreshSucceeded': pasteMode.refreshSucceeded,
      },
    );
    final delivery = await deliverTerminalAttachmentPasteSegments(
      segments: segments,
      injectViaMonkeyMuxControl: injectViaMonkeyMuxControl,
      injectInput: (segment) => _monkeyMuxService.injectInput(
        pasteMode.session!,
        pasteMode.muxSessionName!,
        segment,
        windowId: pasteMode.activeWindowKey,
        bracketedPaste: true,
      ),
      writeTerminalOutput: (segment) =>
          pasteMode.terminal.onOutput?.call(segment),
      initialInputGeneration: inputGeneration,
      currentInputGeneration: () => _terminalUserInputGeneration,
      recordDeliveredInput: () => _terminalUserInputGeneration++,
      blockedReason: () {
        if (!mounted) {
          return TerminalAttachmentPasteStopReason.unavailable;
        }
        if (!_terminalPasteModeOwnsCurrentContext(pasteMode)) {
          return TerminalAttachmentPasteStopReason.contextChanged;
        }
        if (!_terminalPasteModeTargetsCurrentWindow(pasteMode)) {
          _syncTerminalModesFromActiveMuxWindow();
          return TerminalAttachmentPasteStopReason.windowChanged;
        }
        return null;
      },
      waitBetweenSegments: () =>
          Future<void>.delayed(_uploadedAttachmentPasteStagger),
    );
    sentCount = usedBracketedPaste
        ? delivery.deliveredSegmentCount
        : delivery.deliveredSegmentCount == 0
        ? 0
        : sendablePathCount;
    final stopReason = delivery.stopReason;
    if (stopReason != null &&
        stopReason != TerminalAttachmentPasteStopReason.unavailable) {
      final event = switch (stopReason) {
        TerminalAttachmentPasteStopReason.contextChanged =>
          'attachment_input_stopped_context_changed',
        TerminalAttachmentPasteStopReason.windowChanged =>
          'attachment_input_stopped_window_changed',
        TerminalAttachmentPasteStopReason.interveningInput =>
          'attachment_input_stopped_intervening_input',
        TerminalAttachmentPasteStopReason.unavailable =>
          'attachment_input_stopped_unavailable',
      };
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        event,
        fields: {
          'connectionId': _connectionId,
          'pathCount': pathCount,
          'sentCount': sentCount,
        },
      );
    }
    return result(sentCount);
  }

  Future<void> _pasteClipboardFiles(List<String> clipboardFiles) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard files?',
      message:
          'This will upload ${clipboardFiles.length} clipboard file${clipboardFiles.length == 1 ? '' : 's'} to $_clipboardUploadDirectoryDisplay on the connected host and paste their remote paths into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < clipboardFiles.length; index++)
          clipboardFiles[index].startsWith('content://')
              ? 'Clipboard file ${index + 1}'
              : path.basename(clipboardFiles[index]),
      ],
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final files = <PlatformFile>[];
    for (final localPath in clipboardFiles) {
      if (localPath.startsWith('content://')) {
        if (!_isAndroidPlatform) {
          throw const FileSystemException(
            'Clipboard file URIs are not supported on this platform yet',
          );
        }
        final file = await _readAndroidClipboardContentUri(localPath);
        files.add(AppPlatformFile(name: file.name, bytes: file.bytes));
      } else {
        files.add(
          AppPlatformFile(name: path.basename(localPath), path: localPath),
        );
      }
    }
    await _pasteSelectedFiles(
      files,
      itemLabelSingular: 'file',
      itemLabelPlural: 'files',
      confirm: false,
      telemetrySource: 'clipboard_files',
    );
  }

  void _maybePasteStoreDemoImage() {
    if (!widget.pasteDemoImage || _didPasteDemoImage || !mounted) {
      return;
    }
    _didPasteDemoImage = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_pasteStoreDemoImage());
    });
  }

  Future<void> _pasteStoreDemoImage() async {
    final pasteCompleter = storeDemoImagePasteCompleter;
    try {
      final pathInserted = await _pasteClipboardImage(
        _storeDemoClipboardImageBytes,
        autoConfirmAfter: const Duration(milliseconds: 4200),
        showKeyboardAfterPaste: false,
        uploadBaseDirectory: _workingDirectoryPath,
      );
      if (!pathInserted) {
        throw StateError('Demo image path was not inserted into the terminal');
      }
      if (!mounted) {
        return;
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      // Signal the store video harness that the image path is in the terminal
      // so Beat 5 does not type the Copilot prompt before the paste lands.
      debugPrintSynchronously('STORE_SCREENSHOT_DEMO_IMAGE_PASTED');
      if (pasteCompleter != null && !pasteCompleter.isCompleted) {
        pasteCompleter.complete();
      }
    } on Object catch (error, stackTrace) {
      debugPrintSynchronously(
        'STORE_SCREENSHOT_ERROR demo image paste failed: $error',
      );
      if (pasteCompleter != null && !pasteCompleter.isCompleted) {
        pasteCompleter.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<bool> _pasteClipboardImage(
    Uint8List imageBytes, {
    Duration? autoConfirmAfter,
    bool showKeyboardAfterPaste = true,
    String? uploadBaseDirectory,
  }) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard image?',
      message:
          'This will upload the clipboard image to $_clipboardUploadDirectoryDisplay on the connected host and paste its remote path into the terminal.',
      confirmLabel: 'Upload and paste',
      details: const ['monkeyssh-light-mode.png'],
      autoConfirmAfter: autoConfirmAfter,
    );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return false;
    }

    final inputGeneration = _terminalUserInputGeneration;
    final pasteMode = await _resolveSettledTerminalPasteMode();
    final remotePath = await _withClipboardSftp((
      sftp,
      remoteFileService,
      uploadTarget,
    ) async {
      final remotePath = joinRemotePath(
        uploadTarget.sftpDirectory,
        buildClipboardImageFileName(DateTime.now()),
      );
      await remoteFileService.uploadBytes(
        sftp: sftp,
        remotePath: remotePath,
        bytes: imageBytes,
        applyPrivateMode: uploadTarget.applyPrivateFileMode,
      );
      return (
        path: uploadTarget.terminalPathForSftpPath(remotePath),
        windows: uploadTarget.windows,
      );
    }, uploadBaseDirectory: uploadBaseDirectory);
    _followLiveOutput();
    final pasteResult = await _insertUploadedFileReferences(
      [remotePath.path],
      windows: remotePath.windows,
      inputGeneration: inputGeneration,
      pasteMode: pasteMode,
    );
    if (!mounted) {
      return false;
    }
    final pathInserted = pasteResult.sentCount == 1;
    if (pathInserted) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalPasteUsed(
              source: 'clipboard_image',
              requiredReview: true,
            ),
      );
    }
    _terminalController.clearSelection();
    _restoreTerminalFocus(
      showSystemKeyboard: showKeyboardAfterPaste && _isMobilePlatform,
    );
    _showClipboardMessage(
      pathInserted
          ? 'Uploaded clipboard image to ${remotePath.path}'
          : 'Uploaded clipboard image, but could not paste its path',
    );
    return pathInserted;
  }

  Future<void> _pasteSelectedFiles(
    List<PlatformFile> selectedFiles, {
    required String itemLabelSingular,
    required String itemLabelPlural,
    bool confirm = true,
    String telemetrySource = 'picked_files',
  }) async {
    if (!mounted) {
      return;
    }
    final itemLabel = selectedFiles.length == 1
        ? itemLabelSingular
        : itemLabelPlural;
    final shouldUpload =
        !confirm ||
        await _confirmClipboardUpload(
          title: 'Upload selected $itemLabel?',
          message:
              'This will upload ${selectedFiles.length == 1 ? 'the selected $itemLabelSingular' : '${selectedFiles.length} selected $itemLabelPlural'} to $_clipboardUploadDirectoryDisplay on the connected host and paste ${selectedFiles.length == 1 ? 'its remote path' : 'their remote paths'} into the terminal.',
          confirmLabel: 'Upload and paste',
          details: [
            for (var index = 0; index < selectedFiles.length; index++)
              resolvePickedTerminalUploadFileName(
                selectedFiles[index],
                index: index,
              ),
          ],
        );
    if (!shouldUpload) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    final inputGeneration = _terminalUserInputGeneration;
    final pasteMode = await _resolveSettledTerminalPasteMode();
    final timestamp = DateTime.now();
    final remotePaths = await _withClipboardSftp((
      sftp,
      remoteFileService,
      uploadTarget,
    ) async {
      final remotePaths = <String>[];
      for (var index = 0; index < selectedFiles.length; index++) {
        final file = selectedFiles[index];
        final sourceName = resolvePickedTerminalUploadFileName(
          file,
          index: index,
        );
        final remotePath = joinRemotePath(
          uploadTarget.sftpDirectory,
          buildClipboardUploadFileName(sourceName, timestamp, sequence: index),
        );
        await remoteFileService.uploadStream(
          sftp: sftp,
          remotePath: remotePath,
          stream: resolvePickedTerminalUploadReadStream(file),
          applyPrivateMode: uploadTarget.applyPrivateFileMode,
        );
        remotePaths.add(uploadTarget.terminalPathForSftpPath(remotePath));
      }
      return (paths: remotePaths, windows: uploadTarget.windows);
    });

    _followLiveOutput();
    final pasteResult = await _insertUploadedFileReferences(
      remotePaths.paths,
      windows: remotePaths.windows,
      inputGeneration: inputGeneration,
      pasteMode: pasteMode,
    );
    if (!mounted) {
      return;
    }
    if (pasteResult.sentCount > 0) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalPasteUsed(
              source: telemetrySource,
              requiredReview: true,
            ),
      );
    }
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    final pathsInserted = pasteResult.sentCount == pasteResult.requestedCount;
    _showClipboardMessage(
      pathsInserted
          ? 'Uploaded ${selectedFiles.length == 1 ? 'selected $itemLabelSingular' : '${remotePaths.paths.length} $itemLabelPlural'} to $_clipboardUploadDirectoryDisplay'
          : pasteResult.sentCount > 0
          ? 'Uploaded ${remotePaths.paths.length} $itemLabelPlural and pasted ${pasteResult.sentCount} of ${pasteResult.requestedCount} paths'
          : 'Uploaded ${selectedFiles.length == 1 ? 'selected $itemLabelSingular' : '${remotePaths.paths.length} $itemLabelPlural'}, but could not paste ${remotePaths.paths.length == 1 ? 'its path' : 'their paths'}',
    );
  }

  Future<bool> _confirmKeyboardInsertion(TerminalCommandReview review) async {
    final requiresReviewEvenInRunningShell = review.reasons.contains(
      TerminalCommandReviewReason.largeKeyboardInsertion,
    );
    if (!_shouldReviewTerminalCommandInsertion &&
        !requiresReviewEvenInRunningShell) {
      return true;
    }
    final shouldInsert = await _confirmCommandInsertion(
      title: 'Review keyboard paste',
      message:
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
      review: review,
    );
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    return shouldInsert;
  }

  Future<bool> _confirmDesktopInsertedText(String text) async {
    if (text.length <= 1) {
      return true;
    }
    if (!_shouldReviewTerminalCommandInsertion) {
      return true;
    }

    return _confirmTerminalInsertionIfNeeded(
      insertedText: text,
      buildReview: (commandText) => assessClipboardPasteCommand(
        commandText,
        bracketedPasteModeEnabled: false,
      ),
      title: 'Review keyboard paste',
      messageBuilder: (_) =>
          'This text inserted from your keyboard could execute multiple or reshaped commands.',
      confirmLabel: 'Insert anyway',
    );
  }

  Future<void> _refreshKeyboardToolbarSnippetMenu() async {
    final snippetRepo = ref.read(snippetRepositoryProvider);
    final snippets = await snippetRepo.getAll();
    final folders = await snippetRepo.getAllFolders();
    if (!mounted) {
      return;
    }

    setState(() {
      _keyboardToolbarSnippets = [
        for (final snippet in snippets)
          KeyboardToolbarSnippet(
            id: snippet.id,
            name: snippet.name,
            command: snippet.command,
            folderId: snippet.folderId,
          ),
      ];
      _keyboardToolbarSnippetFolders = [
        for (final folder in folders)
          KeyboardToolbarSnippetFolder(id: folder.id, name: folder.name),
      ];
    });
  }

  Future<void> _pasteClipboardIntoNativeComposer() async {
    try {
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        if (!mounted) return;
        _nativeComposerFocusController.pasteImage(imageBytes);
        return;
      }
    } on PlatformException {
      // Fall through to plain text when this platform cannot read image data.
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) {
      return;
    }
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _showClipboardMessage('Clipboard has no text or image to paste.');
      return;
    }
    _nativeComposerFocusController.pasteText(text);
  }

  Future<void> _pasteSnippetIntoNativeComposer(
    KeyboardToolbarSnippet selectedSnippet,
  ) async {
    final repository = ref.read(snippetRepositoryProvider);
    final snippet = await repository.getById(selectedSnippet.id);
    if (!mounted) {
      return;
    }
    if (snippet == null) {
      _showClipboardMessage('Snippet is no longer available.');
      return;
    }
    final substitution = await _substituteVariables(context, snippet);
    if (!mounted || substitution == null || substitution.command.isEmpty) {
      return;
    }
    _nativeComposerFocusController.insertText(substitution.command);
    unawaited(repository.incrementUsage(snippet.id));
  }

  Future<void> _pasteKeyboardToolbarSnippet(
    KeyboardToolbarSnippet selectedSnippet,
  ) async {
    final snippetRepo = ref.read(snippetRepositoryProvider);
    final snippet = await snippetRepo.getById(selectedSnippet.id);
    if (!mounted) {
      return;
    }
    if (snippet == null) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Snippet is no longer available.');
      return;
    }

    final substitution = await _substituteVariables(context, snippet);
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (substitution == null || substitution.command.isEmpty) {
      return;
    }

    final shouldInsert = await _confirmTerminalInsertionIfNeeded(
      insertedText: substitution.command,
      buildReview: (commandText) => assessSnippetCommandInsertion(
        commandText,
        hadVariableSubstitution: substitution.hadVariableSubstitution,
      ),
      title: 'Review snippet command',
      messageBuilder: (_) =>
          'Confirm the rendered command before inserting it.',
      confirmLabel: 'Insert command',
    );
    if (!shouldInsert) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return;
    }

    _handleTerminalUserInput();
    _terminal.paste(substitution.command);
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    unawaited(snippetRepo.incrementUsage(snippet.id));
  }

  /// Shows snippet picker and inserts selected snippet into terminal.
  Future<void> _showSnippetPicker() async {
    final snippetRepo = ref.read(snippetRepositoryProvider);
    final snippets = await snippetRepo.getAll();

    if (!mounted) return;

    if (snippets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No snippets available. Add some first!')),
      );
      return;
    }

    final variablePattern = RegExp(r'\{\{(\w+)\}\}');

    final result = await showModalBottomSheet<KeyboardToolbarSnippet>(
      context: context,
      isScrollControlled: true,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => DraggableScrollableSheet(
        maxChildSize: 0.8,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    'Snippets',
                    style: FluttyTheme.displayMono(
                      fontSize: 18,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: snippets.length,
                itemBuilder: (context, index) {
                  final snippet = snippets[index];
                  final hasVariables = variablePattern.hasMatch(
                    snippet.command,
                  );
                  return ListTile(
                    leading: Icon(
                      hasVariables ? Icons.tune : Icons.code,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(
                      snippet.name,
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      snippet.command.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: hasVariables
                        ? const Chip(label: Text('Has variables'))
                        : null,
                    onTap: () => Navigator.pop(
                      context,
                      KeyboardToolbarSnippet(
                        id: snippet.id,
                        name: snippet.name,
                        command: snippet.command,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (result != null && mounted) {
      await _pasteKeyboardToolbarSnippet(result);
    }
  }

  /// Shows dialog for variable substitution if snippet has variables.
  Future<({String command, bool hadVariableSubstitution})?>
  _substituteVariables(BuildContext context, Snippet snippet) async {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(snippet.command);
    final variables = matches.map((m) => m.group(1)!).toSet().toList();

    if (variables.isEmpty) {
      return (command: snippet.command, hadVariableSubstitution: false);
    }

    final values = <String, String>{};
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Variables for "${snippet.name}"'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final variable in variables) ...[
                  TextFormField(
                    onChanged: (value) => values[variable] = value,
                    decoration: InputDecoration(
                      labelText: variable,
                      hintText: 'Enter value for $variable',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a value';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Insert'),
          ),
        ],
      ),
    );

    if (result != true) return null;
    return (
      command: snippet.command.replaceAllMapped(
        regex,
        (match) => values[match.group(1)]!,
      ),
      hadVariableSubstitution: true,
    );
  }

  Future<bool> _reviewImportedAutoConnectCommand(
    TerminalCommandReview review,
    Host host,
  ) async {
    final decision = await showDialog<_AutoConnectReviewDecision>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: const Text('Review imported auto-connect command'),
        content: _buildCommandReviewContent(
          review: review,
          message:
              'Imported auto-connect commands never run silently. Review this one before letting it execute.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.skip),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.runOnce),
            child: const Text('Run once'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.trustAndRun),
            child: const Text('Always run'),
          ),
        ],
      ),
    );
    if (!mounted ||
        decision == null ||
        decision == _AutoConnectReviewDecision.skip) {
      return false;
    }
    if (decision == _AutoConnectReviewDecision.trustAndRun) {
      await ref
          .read(hostRepositoryProvider)
          .updateFields(
            host.id,
            const HostsCompanion(
              autoConnectRequiresConfirmation: drift.Value(false),
            ),
          );
      _host = host.copyWith(autoConnectRequiresConfirmation: false);
    }
    return mounted;
  }

  Future<bool> _confirmCommandInsertion({
    required String title,
    required String message,
    required String confirmLabel,
    required TerminalCommandReview review,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: _buildCommandReviewContent(review: review, message: message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Widget _buildCommandReviewContent({
    required TerminalCommandReview review,
    required String message,
  }) {
    final reasons = describeTerminalCommandReview(review);
    const maxPreviewLength = 2000;
    final command = review.command;
    final commandPreview = command.length <= maxPreviewLength
        ? command
        : '${command.substring(0, maxPreviewLength)}\n'
              '... truncated ${command.length - maxPreviewLength} characters ...';
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(reason)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              commandPreview,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalConnectionStatusIcon extends StatelessWidget {
  const _TerminalConnectionStatusIcon({
    required this.label,
    required this.state,
    required this.isConnecting,
    required this.connectedThroughJumpHost,
  });

  final String label;
  final SshConnectionState state;
  final bool isConnecting;
  final bool connectedThroughJumpHost;

  IconData get _icon {
    if (isConnecting &&
        (state == SshConnectionState.disconnected ||
            state == SshConnectionState.connecting)) {
      return Icons.sync;
    }

    switch (state) {
      case SshConnectionState.connected:
        return Icons.check_circle_outline;
      case SshConnectionState.connecting:
      case SshConnectionState.authenticating:
        return Icons.sync;
      case SshConnectionState.reconnecting:
        return Icons.sync_problem_outlined;
      case SshConnectionState.error:
        return Icons.error_outline;
      case SshConnectionState.disconnected:
        return Icons.link_off;
    }
  }

  Color _color(ColorScheme colorScheme) {
    if (isConnecting &&
        (state == SshConnectionState.disconnected ||
            state == SshConnectionState.connecting)) {
      return colorScheme.tertiary;
    }

    switch (state) {
      case SshConnectionState.connected:
        return colorScheme.primary;
      case SshConnectionState.connecting:
      case SshConnectionState.authenticating:
      case SshConnectionState.reconnecting:
        return colorScheme.tertiary;
      case SshConnectionState.error:
      case SshConnectionState.disconnected:
        return colorScheme.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = _color(colorScheme);

    final statusIcon = Icon(_icon, size: 20, color: statusColor);

    return Semantics(
      label: 'Terminal connection status: $label',
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: connectedThroughJumpHost
            ? SizedBox.square(
                dimension: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    statusIcon,
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: _TerminalJumpHostIndicator(),
                    ),
                  ],
                ),
              )
            : statusIcon,
      ),
    );
  }
}

class _TerminalJumpHostIndicator extends StatelessWidget {
  const _TerminalJumpHostIndicator();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Connected through jump host',
      child: Tooltip(
        message: 'Connected through jump host',
        excludeFromSemantics: true,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: colorScheme.onSurface,
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.alt_route, size: 9, color: colorScheme.surface),
        ),
      ),
    );
  }
}

class _TerminalProgressBar extends StatelessWidget {
  const _TerminalProgressBar({required this.progress});

  final TerminalProgress progress;

  String get _label => switch (progress.state) {
    TerminalProgressState.normal => 'Terminal task progress',
    TerminalProgressState.error => 'Terminal task progress, error',
    TerminalProgressState.indeterminate =>
      'Terminal task progress, indeterminate',
    TerminalProgressState.pausedOrWarning =>
      'Terminal task progress, paused or warning',
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
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final hasPercentage = percentage != null;
    final indicatorValue = hasPercentage
        ? progress.fraction
        : (disableAnimations ? 0.5 : null);

    return Semantics(
      label: _label,
      value: hasPercentage ? '$percentage' : null,
      minValue: hasPercentage ? '0' : null,
      maxValue: hasPercentage ? '100' : null,
      role: hasPercentage
          ? SemanticsRole.progressBar
          : SemanticsRole.loadingSpinner,
      child: ExcludeSemantics(
        child: LinearProgressIndicator(
          key: const ValueKey<String>('terminal-osc-progress'),
          value: indicatorValue,
          minHeight: 3,
          color: _color(colorScheme),
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _TerminalStatusChip extends StatelessWidget {
  const _TerminalStatusChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.colorScheme,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
