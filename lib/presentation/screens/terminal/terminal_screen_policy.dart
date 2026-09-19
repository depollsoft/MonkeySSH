import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../../data/database/database.dart';
import '../../../domain/models/agent_launch_preset.dart';
import '../../../domain/models/remote_multiplexer.dart';
import '../../../domain/models/tmux_state.dart';
import '../../../domain/services/remote_file_service.dart';
import '../../../domain/services/shell_completion_service.dart';
import '../../../domain/services/ssh_service.dart';
import '../../models/app_platform_file.dart';
import '../../widgets/monkey_terminal_view.dart';
import '../../widgets/system_bottom_inset.dart';
import '../../widgets/terminal_selection_text.dart' as terminal_selection_text;

/// Minimum tmux handle touch target used by the collapsed window bar.
const double tmuxHandleMinTouchExtent = 44;

/// Returns a short, user-facing label for the terminal connection state.
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

/// Formats the remote host and session identity shown in the terminal title.
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
    final candidateTitle = _tmuxAlertNotificationLabel(candidate.displayTitle)
        .toLowerCase();
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

const _tmuxDetectionRetrySchedule = <Duration>[
  Duration.zero,
  Duration(milliseconds: 150),
  Duration(milliseconds: 350),
  Duration(milliseconds: 700),
  Duration(milliseconds: 1400),
  Duration(milliseconds: 2800),
  Duration(milliseconds: 5600),
];

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

/// Resolves the retry schedule used for tmux detection after connect.
List<Duration> resolveTmuxDetectionRetrySchedule({bool skipDelay = false}) =>
    skipDelay ? const <Duration>[Duration.zero] : _tmuxDetectionRetrySchedule;

/// Returns whether tmux detection should keep the terminal's current tmux UI.
///
/// A clean inactive result can clear the bar, but transient detection failures
/// should not hide a bar whose attached client was already confirmed to belong
/// to this SSH connection. State that was only primed from host settings has no
/// confirmed client yet, so it must never survive a failed probe.
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
bool shouldRetryTerminalThemeWhenViewMounts({
  required bool nativeAgentActive,
  required bool routeIsCurrent,
  required int attempt,
}) => !nativeAgentActive && routeIsCurrent && attempt < 3;

/// Returns whether tmux detection should keep the terminal's current tmux UI.
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
bool shouldPreserveTmuxBarSnapshotOnUpdate({
  required bool sessionChanged,
  required bool backendChanged,
  required bool recoveryChanged,
}) => recoveryChanged && !sessionChanged && !backendChanged;

/// Resolves a stored remote multiplexer backend for startup.
///
/// Missing values intentionally use automatic MonkeyMux-first behavior unless a
/// legacy tmux host has custom tmux flags that MonkeyMux cannot honor.
RemoteMuxBackend resolveRemoteMuxStartupBackend(
  String? storedBackend, {
  String? tmuxExtraFlags,
}) => resolveRemoteMuxBackendForStartup(
  storedBackend: storedBackend,
  tmuxExtraFlags: tmuxExtraFlags,
);

/// Resolves the working directory to use when creating a new tmux window.
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
double resolveShellCompletionPopupRowHeight(double terminalFontSize) =>
    max(28, terminalFontSize * 1.75).toDouble();

double _nonNegativeDouble(double value) => value < 0 ? 0 : value;

/// Resolves shell completion popup bounds without covering the cursor line.
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
          normalizeShellCompletionToken(suggestion.replacement)
              .startsWith(currentInvocation.token);
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

  return normalizeShellCompletionToken(suggestion.replacement)
      .startsWith(currentInvocation.token);
}

/// Filters visible shell completion suggestions against the current command.
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
const double tmuxSidebarCollapsedWidth = 56;

/// Width of the expanded large-screen tmux sidebar.
const double tmuxSidebarExpandedWidth = 320;

/// Minimum terminal width to preserve before switching to a sidebar.
const double tmuxSidebarMinTerminalWidth = 520;

/// Chooses whether tmux controls should sit below or beside the terminal.
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
bool resolveTerminalScreenCanPop({required bool isTmuxBarExpanded}) =>
    !isTmuxBarExpanded;

/// Whether the terminal shell should resize for the system keyboard.
///
/// Insets describe occupied geometry but can remain stale after the IME closes.
/// A native platform visibility report therefore wins for both terminal and
/// ACP inputs. Before that report arrives, require a live input owner rather
/// than treating native content itself as proof that a keyboard is open.
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
bool resolveShowTerminalViewportMenuActions({
  required bool nativeAgentActive,
}) => !nativeAgentActive;

/// Resolves the wide-layout sidebar width while the user drags it.
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
double resolveTmuxBarRevealBottomOffset(
  double terminalBottomPadding, {
  double handleHeight = tmuxHandleMinTouchExtent,
}) => terminalBottomPadding - handleHeight;

/// Resolves the tmux bar's reveal opacity from the animated bottom padding.
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
String? resolveTmuxBarActiveWindowTitle(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  final title = activeWindow?.handleTitle.trim();
  if (title == null || title.isEmpty) {
    return null;
  }
  return title;
}

/// Resolves the supported foreground agent running in the active tmux window.
AgentLaunchTool? resolveTmuxBarActiveWindowTool(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.foregroundAgentTool;

/// Resolves bracketed paste mode state tracked for the active mux window.
bool? resolveTmuxBarActiveWindowBracketedPasteMode(
  Iterable<TmuxWindow>? windows,
) => windows
    ?.where((window) => window.isActive)
    .firstOrNull
    ?.terminalBracketedPasteMode;

/// Resolves a stable identity for the active mux window.
String? resolveTmuxBarActiveWindowKey(Iterable<TmuxWindow>? windows) {
  final activeWindow = windows?.where((window) => window.isActive).firstOrNull;
  if (activeWindow == null) {
    return null;
  }
  return activeWindow.id ?? '#${activeWindow.index}';
}

/// Whether attachment input still targets the same settled mux window.
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

/// Formats a detected remote multiplexer version for terminal metadata.
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

/// Terminal mode signature for the active tmux window.
///
/// Used to detect when local terminal state must be updated after a window
/// metadata update that doesn't change the active window itself (for example a
/// foreground app toggling mouse or bracketed-paste mode). Returns `null` when
/// there is no active window so an appearing/disappearing active window is also
/// treated as a change.
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

/// Removes terminal escape sequences from a prompt snapshot.
String stripTerminalPromptEscapeSequences(String text) => text
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
bool terminalTextLooksLikeSensitiveInputPrompt(String? textBeforeCursor) {
  if (textBeforeCursor == null) {
    return false;
  }

  final sanitizedText = stripTerminalPromptEscapeSequences(textBeforeCursor);
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

const _terminalPathTouchHorizontalPadding = 10.0;

const _terminalPathTouchVerticalPadding = 8.0;

const _maxTerminalFilePathVerificationCandidates = 12;

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

/// A normalized path match and its original terminal-text range.
typedef TerminalPathMatch = ({
  String path,
  int start,
  int end,
  int hitTestEnd,
  int normalizedStart,
  int normalizedEnd,
});

/// Normalized detection text with mappings back to original character offsets.
typedef NormalizedTerminalPathSnapshot = ({
  String text,
  List<int> originalToNormalizedOffsets,
  List<int> normalizedToOriginalStarts,
  List<int> normalizedToOriginalEnds,
});

/// Padding around the terminal viewport.
///
/// Keep the terminal flush with the viewport edges so status lines from tools
/// like tmux can use the full available width and height.
const terminalViewportPadding = EdgeInsets.zero;

/// Clamps a terminal font size into the supported zoom range.
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
double scaleTerminalFontSize(double baseSize, double scale) =>
    clampTerminalFontSize(baseSize * scale);

/// Applies an incremental pinch delta to the currently displayed font size.
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
double resolveTerminalFontSize({
  required double globalFontSize,
  double? sessionFontSize,
  double? pinchFontSize,
}) => pinchFontSize ?? sessionFontSize ?? globalFontSize;

/// Trims terminal cell padding from the end of a rendered line.
String trimTerminalLinePadding(String line) =>
    terminal_selection_text.trimTerminalLinePadding(line);

/// Trims per-line terminal padding from copied or overlaid terminal text.
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
double upgradeSnackBarBottomMargin(
  MediaQueryData mediaQuery, {
  bool showKeyboardToolbar = false,
  double keyboardToolbarHeight = 84,
  double baseSpacing = 16,
}) => (showKeyboardToolbar ? keyboardToolbarHeight : 0) + baseSpacing;

/// Resolves a readable display name for a picked upload file.
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
Stream<List<int>> resolvePickedTerminalUploadReadStream(PlatformFile file) =>
    file.readAsByteStream().cast<List<int>>();

/// Resolves the picker request used for terminal uploads.
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
bool shouldUsePhotoLibraryPickerForTerminalMedia({
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

/// Returns an Android image picker implementation configured for Photo Picker.
ImagePickerAndroid enableAndroidPhotoPickerForTerminalMedia(
  ImagePickerPlatform imagePickerImplementation,
) {
  final androidImagePicker = imagePickerImplementation is ImagePickerAndroid
      ? imagePickerImplementation
      : ImagePickerAndroid();
  return androidImagePicker..useAndroidPhotoPicker = true;
}

/// Builds a file-picker upload file from native photo-library media.
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
String normalizeTerminalLinkCandidate(String text) {
  final candidate = trimTerminalLinkCandidate(text.trim());
  if (candidate.toLowerCase().startsWith('www.')) {
    return 'https://$candidate';
  }
  return candidate;
}

/// Trims terminal-rendered file paths before SFTP navigation.
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
bool isTerminalFilePathBoundary(String? character) =>
    character == null ||
    character.trim().isEmpty ||
    '([{"\'`=:,'.contains(character);

/// Whether a terminal path can be opened in the remote SFTP browser.
bool isSupportedTerminalFilePath(String path) {
  if (path.isEmpty || path == '.' || path == '..' || path.startsWith('//')) {
    return false;
  }
  return isExplicitTerminalFilePath(path) ||
      isRelativeTerminalFilePathCandidate(path);
}

/// Whether a detected terminal path must be verified before becoming tappable.
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
bool isExplicitTerminalFilePath(String path) =>
    isSftpAbsolutePath(path) || path == '~' || path.startsWith('~/');

/// Whether a relative terminal path looks file-like enough to probe safely.
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
bool terminalRowMayContainPath(BufferLine line, int viewWidth) {
  for (var col = 0; col < viewWidth; col++) {
    final cp = line.getCodePoint(col);
    if (cp == 0x2f /* / */ || cp == 0x5c /* \ */ || cp == 0x7e /* ~ */ ) {
      return true;
    }
  }
  return false;
}

/// Normalizes rendered line continuations while retaining original offsets.
NormalizedTerminalPathSnapshot normalizeTerminalFilePathDetectionText(
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

/// Detects path candidates with their original terminal-text ranges.
List<TerminalPathMatch> detectTerminalFilePathMatches(
  NormalizedTerminalPathSnapshot normalizedText,
) {
  final detectedPaths = <TerminalPathMatch>[];

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
({String text, int startColumn, int endColumn})?
resolveTerminalFilePathSegmentOnRowForPath({
  required String snapshotText,
  required String rowText,
  required int rowStartOffset,
  required List<int> rowColumnOffsets,
  required String path,
}) {
  final normalizedSnapshot = normalizeTerminalFilePathDetectionText(
    snapshotText,
  );
  for (final match in detectTerminalFilePathMatches(normalizedSnapshot)) {
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
List<({String path, int start, int end})> detectTerminalFilePaths(
  String text,
) => [
  for (final path in detectTerminalFilePathMatches(
    normalizeTerminalFilePathDetectionText(text),
  ))
    (path: path.path, start: path.start, end: path.end),
];

/// Resolves a tappable terminal file path at the given text offset, if present.
({String path, int start, int end})? detectTerminalFilePathAtTextOffset(
  String text,
  int offset,
) {
  final clampedOffset = offset.clamp(0, text.length);
  for (final detectedPath in detectTerminalFilePathMatches(
    normalizeTerminalFilePathDetectionText(text),
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
({Uri uri, int start, int end})? detectTerminalLinkAtTextOffset(
  String text,
  int offset,
) {
  final normalized = normalizeTerminalFilePathDetectionText(
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
bool isTerminalFileUri(Uri uri) =>
    uri.scheme.toLowerCase() == 'file' &&
    uri.path.isNotEmpty &&
    uri.path != '/';

/// Whether a parsed terminal URI resolves to a tappable target: either an
/// externally launchable link or a `file:` link routed to the SFTP browser.
bool isResolvableTerminalLinkUri(Uri uri) =>
    isLaunchableTerminalUri(uri) || isTerminalFileUri(uri);

/// Resolves the remote path a terminal `file:` link should open in the SFTP
/// browser, or `null` when [link] is not a usable `file:` URI.
///
/// The URI host (if any) is ignored: the path is opened on the host the
/// terminal session is connected to. Percent-encoding is decoded so the SFTP
/// browser receives the literal path (e.g. `%20` becomes a space).
String? resolveTerminalFileUriPath(String link) {
  final uri = Uri.tryParse(normalizeTerminalLinkCandidate(link));
  if (uri == null || !isTerminalFileUri(uri)) {
    return null;
  }
  return Uri.decodeComponent(uri.path);
}

/// Applies pasted or rendered text at the terminal cursor within a wrapped line.
String applyTerminalCursorInsertion({
  required String currentText,
  required int cursorOffset,
  required String insertedText,
}) => currentText.replaceRange(cursorOffset, cursorOffset, insertedText);

/// Applies terminal-style backspaces before inserting newly committed text.
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
bool shouldRouteTouchScrollToTerminal({
  required bool isMobile,
  required bool isUsingAltBuffer,
  required bool terminalReportsMouseWheel,
  bool isAgentToolActive = false,
}) =>
    isMobile &&
    (terminalReportsMouseWheel || (isUsingAltBuffer && !isAgentToolActive));

/// Resolves the effective mouse-wheel state for scroll routing.
bool terminalReportsMouseWheelForScroll({
  required bool localTerminalReportsMouseWheel,
  bool? activeWindowReportsMouseWheel,
}) =>
    localTerminalReportsMouseWheel || (activeWindowReportsMouseWheel ?? false);

/// Whether the active terminal context is a known agent tool for scroll policy.
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
bool shouldForceSgrTouchScroll({
  bool? activeWindowReportsMouseWheel,
  bool? activeWindowMouseReportSgr,
}) =>
    (activeWindowReportsMouseWheel ?? false) &&
    (activeWindowMouseReportSgr ?? false);

/// Whether terminal tap links should be resolved for the current overlay state.
bool shouldResolveTerminalTapLinks({
  required bool showsNativeSelectionOverlay,
}) => !showsNativeSelectionOverlay;

/// Whether live terminal output should keep following the current viewport.
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
bool didTerminalScrollPolicyChange({
  required bool previousIsUsingAltBuffer,
  required bool nextIsUsingAltBuffer,
  required bool previousReportsMouseWheel,
  required bool nextReportsMouseWheel,
}) =>
    previousIsUsingAltBuffer != nextIsUsingAltBuffer ||
    previousReportsMouseWheel != nextReportsMouseWheel;

/// Resolves a saved auto-connect command and its agent preset overrides.
String? resolveStoredAutoConnectCommand(
  Host? host, {
  required bool hasUnsupportedAutoConnectAgentPreset,
  required AgentLaunchPreset? autoConnectAgentPreset,
  required bool startClisInYoloMode,
}) {
  if (host == null) {
    return null;
  }
  if (host.autoConnectSnippetId != null) {
    return host.autoConnectCommand;
  }
  if (hasUnsupportedAutoConnectAgentPreset) {
    return null;
  }
  final preset = autoConnectAgentPreset;
  if (preset == null) {
    return host.autoConnectCommand;
  }
  try {
    return buildAgentLaunchCommand(
      preset,
      startInYoloMode: startClisInYoloMode,
    );
  } on FormatException {
    return host.autoConnectCommand;
  }
}

/// Sanitized diagnostic category and user message for a picked-file failure.
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

/// Whether a window snapshot changed terminal identity or theme context.
bool shouldRefreshTmuxThemeAfterWindowChange(
  List<TmuxWindow> previousWindows,
  List<TmuxWindow> nextWindows,
) {
  if (previousWindows.length != nextWindows.length) {
    return true;
  }
  final byId = <String, TmuxWindow>{};
  final byIndex = <int, TmuxWindow>{};
  for (final window in previousWindows) {
    if (window.id case final id?) byId.putIfAbsent(id, () => window);
    byIndex.putIfAbsent(window.index, () => window);
  }
  for (final nextWindow in nextWindows) {
    final previousWindow = nextWindow.id == null
        ? byIndex[nextWindow.index]
        : byId[nextWindow.id];
    if (previousWindow == null ||
        _tmuxWindowRefreshIdentity(previousWindow) !=
            _tmuxWindowRefreshIdentity(nextWindow)) {
      return true;
    }
  }
  return false;
}

({
  String? currentCommand,
  AgentLaunchTool? foregroundAgentTool,
  String? id,
  int index,
  bool isActive,
  int? panePid,
  String? paneStartCommand,
})
_tmuxWindowRefreshIdentity(TmuxWindow window) => (
  currentCommand: window.currentCommand,
  foregroundAgentTool: window.foregroundAgentTool,
  id: window.id,
  index: window.index,
  isActive: window.isActive,
  panePid: window.panePid,
  paneStartCommand: window.paneStartCommand,
);
