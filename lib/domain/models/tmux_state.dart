import 'package:flutter/foundation.dart';

import 'agent_launch_preset.dart';
import 'terminal_progress.dart';

/// Field separator used for tmux format strings.
///
/// tmux's format engine does not expand `\t`, and titles/commands may contain
/// visible delimiters such as `|`. ASCII Unit Separator keeps parsed snapshots
/// stable without constraining user-controlled window names.
const tmuxWindowFieldSeparator = '\x1f';

/// Confidence level for a live AI session inferred for a tmux pane.
enum AgentSessionConfidence {
  /// Flutty explicitly launched or resumed this session in this pane.
  high,

  /// Process metadata or open files strongly matched this session.
  medium,

  /// Directory and recency heuristics weakly matched this session.
  low,
}

/// Current tmux pane metadata needed for side-channel terminal features.
@immutable
class TmuxPaneContext {
  /// Creates a tmux pane context snapshot.
  const TmuxPaneContext({this.currentPath, this.currentCommand});

  /// The working directory of the active pane, if available.
  final String? currentPath;

  /// The foreground command in the active pane, if available.
  final String? currentCommand;
}

/// Represents a single window within a tmux session.
@immutable
class TmuxWindow {
  /// Creates a new [TmuxWindow].
  const TmuxWindow({
    required this.index,
    required this.name,
    required this.isActive,
    this.id,
    this.panePid,
    this.currentCommand,
    this.currentPath,
    this.flags,
    this.paneTitle,
    this.paneStartCommand,
    this.agentTool,
    this.hasUnsupportedAgentTool = false,
    this.activeAgentSessionId,
    this.agentSessionTitle,
    this.activeAgentSessionConfidence,
    this.nativeAcpBridgeId,
    this.nativeAcpProviderId,
    this.terminalReportsMouseWheel,
    this.terminalMouseReportSgr,
    this.terminalBracketedPasteMode,
    this.terminalProgress,
    int? idleSeconds,
    this.lastActivityEpochSeconds,
  }) : _snapshotIdleSeconds = idleSeconds;

  /// Parses a [TmuxWindow] from a tmux format string.
  ///
  /// Expected format (from `tmux list-windows -F`) is Unit
  /// Separator-delimited:
  /// `index<US>name<US>active_flag<US>command<US>path<US>flags<US>`
  /// `pane_title<US>activity_epoch<US>pane_start_command<US>agent_tool<US>`
  /// `window_id<US>pane_pid<US>agent_session_id<US>agent_session_title<US>`
  /// `agent_session_confidence`
  factory TmuxWindow.fromTmuxFormat(String line) {
    final fields = line.split(tmuxWindowFieldSeparator);
    if (fields.length < 3) {
      throw FormatException('Invalid tmux window format: $line');
    }

    final activityEpoch = fields.length > 7 ? int.tryParse(fields[7]) : null;
    final storedTool = fields.length > 9 ? _nonEmpty(fields[9]) : null;
    final agentTool = _agentToolFromMetadata(storedTool);
    final unsupportedTool = storedTool != null && agentTool == null;

    return TmuxWindow(
      index: int.tryParse(fields[0]) ?? 0,
      name: fields[1],
      isActive: fields[2] == '1',
      id: fields.length > 10 && isValidTmuxWindowId(fields[10])
          ? fields[10]
          : null,
      panePid: fields.length > 11 ? int.tryParse(fields[11]) : null,
      currentCommand: fields.length > 3 ? _nonEmpty(fields[3]) : null,
      currentPath: fields.length > 4 ? _nonEmpty(fields[4]) : null,
      flags: fields.length > 5 ? _nonEmpty(fields[5]) : null,
      paneTitle: fields.length > 6 ? _nonEmpty(fields[6]) : null,
      lastActivityEpochSeconds: activityEpoch != null && activityEpoch > 0
          ? activityEpoch
          : null,
      paneStartCommand: fields.length > 8 ? _nonEmpty(fields[8]) : null,
      agentTool: agentTool,
      hasUnsupportedAgentTool: unsupportedTool,
      activeAgentSessionId: !unsupportedTool && fields.length > 12
          ? _nonEmpty(fields[12])
          : null,
      agentSessionTitle: !unsupportedTool && fields.length > 13
          ? _nonEmpty(fields[13])
          : null,
      activeAgentSessionConfidence: unsupportedTool
          ? null
          : _agentSessionConfidenceFromWindowFields(fields),
    );
  }

  /// The tmux-reported window index within the session.
  final int index;

  /// The stable tmux window ID (for example `@7`), when reported.
  final String? id;

  /// The tmux pane's root process ID, when reported.
  final int? panePid;

  /// The window name (often set by the running program or user).
  final String name;

  /// Whether this is the currently active window in the session.
  final bool isActive;

  /// The command currently running in the active pane, if available.
  final String? currentCommand;

  /// The working directory of the active pane, if available.
  final String? currentPath;

  /// tmux window flags (`*` active, `-` last, `#` alert/bell, etc.).
  final String? flags;

  /// The pane title set by the running application, if available.
  final String? paneTitle;

  /// The command tmux used when creating the pane, if available.
  final String? paneStartCommand;

  /// App-provided agent tool metadata stored on the tmux window, if available.
  final AgentLaunchTool? agentTool;

  /// Explicit tool metadata was rejected; weak labels must not substitute a tool.
  final bool hasUnsupportedAgentTool;

  /// Live coding-agent session id observed from process metadata, if available.
  final String? activeAgentSessionId;

  /// Live coding-agent session title observed from process metadata, if
  /// available.
  final String? agentSessionTitle;

  /// Confidence level for [activeAgentSessionId] and [agentSessionTitle].
  final AgentSessionConfidence? activeAgentSessionConfidence;

  /// Server-owned ACP bridge represented by this real MonkeyMux window.
  final String? nativeAcpBridgeId;

  /// Stable ACP provider id for [nativeAcpBridgeId].
  final String? nativeAcpProviderId;

  /// Whether this real MonkeyMux window uses the native ACP viewport.
  bool get isNativeAcp =>
      nativeAcpBridgeId != null && nativeAcpProviderId != null;

  /// Whether the foreground application requested terminal mouse-wheel input.
  final bool? terminalReportsMouseWheel;

  /// Whether the foreground application requested SGR mouse reporting.
  final bool? terminalMouseReportSgr;

  /// Whether the foreground application requested bracketed paste mode.
  final bool? terminalBracketedPasteMode;

  /// OSC 9;4 progress reported by this MonkeyMux window, when available.
  ///
  /// Plain tmux snapshots leave this unset.
  final TerminalProgress? terminalProgress;

  /// tmux's `window_activity` epoch seconds, if available.
  final int? lastActivityEpochSeconds;

  final int? _snapshotIdleSeconds;

  /// Seconds since last output activity in this window, if available.
  int? get idleSeconds {
    final activityEpoch = lastActivityEpochSeconds;
    if (activityEpoch == null) {
      return _snapshotIdleSeconds;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final idleSeconds = now - activityEpoch;
    return idleSeconds < 0 ? 0 : idleSeconds;
  }

  /// Idle threshold (seconds) above which a window is considered "waiting".
  static const _idleThreshold = 15;

  /// Whether this window has a pending alert, bell, or activity notification.
  bool get hasAlert =>
      flags != null && (flags!.contains('#') || flags!.contains('!'));

  /// Whether the window appears to be idle (no output for a while).
  ///
  /// A CLI that has finished working and is waiting for the user to
  /// return will have a high idle time while still showing as the
  /// `currentCommand`, including when it is the currently selected window.
  bool get isIdle => idleSeconds != null && idleSeconds! > _idleThreshold;

  /// Whether the window's status can still change from running to waiting
  /// without tmux emitting a new control-mode notification.
  bool get needsLocalIdleRefresh =>
      !hasAlert && idleSeconds != null && idleSeconds! <= _idleThreshold;

  /// Returns a copy of this window with selectively overridden fields.
  TmuxWindow copyWith({
    String? id,
    int? panePid,
    bool? isActive,
    String? currentCommand,
    String? flags,
    AgentLaunchTool? agentTool,
    bool? hasUnsupportedAgentTool,
    String? activeAgentSessionId,
    String? agentSessionTitle,
    AgentSessionConfidence? activeAgentSessionConfidence,
    bool clearActiveAgentSessionMetadata = false,
  }) => TmuxWindow(
    index: index,
    id: id ?? this.id,
    panePid: panePid ?? this.panePid,
    name: name,
    isActive: isActive ?? this.isActive,
    currentCommand: currentCommand ?? this.currentCommand,
    currentPath: currentPath,
    flags: flags ?? this.flags,
    paneTitle: paneTitle,
    paneStartCommand: paneStartCommand,
    agentTool: agentTool ?? this.agentTool,
    hasUnsupportedAgentTool:
        hasUnsupportedAgentTool ??
        (agentTool == null && this.hasUnsupportedAgentTool),
    activeAgentSessionId: clearActiveAgentSessionMetadata
        ? null
        : activeAgentSessionId ?? this.activeAgentSessionId,
    agentSessionTitle: clearActiveAgentSessionMetadata
        ? null
        : agentSessionTitle ?? this.agentSessionTitle,
    activeAgentSessionConfidence: clearActiveAgentSessionMetadata
        ? null
        : activeAgentSessionConfidence ?? this.activeAgentSessionConfidence,
    nativeAcpBridgeId: nativeAcpBridgeId,
    nativeAcpProviderId: nativeAcpProviderId,
    terminalReportsMouseWheel: terminalReportsMouseWheel,
    terminalMouseReportSgr: terminalMouseReportSgr,
    terminalBracketedPasteMode: terminalBracketedPasteMode,
    terminalProgress: terminalProgress,
    idleSeconds: _snapshotIdleSeconds,
    lastActivityEpochSeconds: lastActivityEpochSeconds,
  );

  /// A best-effort coding-agent session identifier found in tmux metadata.
  String? get agentSessionId {
    final activeId = activeAgentSessionId;
    if (activeId != null && activeId.isNotEmpty) return activeId;
    if (hasUnsupportedAgentTool) return null;
    final tool = foregroundAgentTool;
    if (tool == null) return null;
    return _agentSessionIdFromCommand(paneStartCommand, tool: tool);
  }

  /// Short coding-agent session label suitable for secondary UI text.
  String? get agentSessionLabel {
    final title = _normalizedTmuxTitle(agentSessionTitle);
    if (title != null && title.isNotEmpty) {
      final tool = foregroundAgentTool;
      return tool == null ? title : '${tool.label} · $title';
    }
    final id = agentSessionId;
    if (id == null || id.isEmpty) return null;
    return 'active session';
  }

  /// Live coding-agent session title suitable for primary UI text.
  String? get agentSessionDisplayTitle {
    final title = _normalizedTmuxTitle(agentSessionTitle);
    if (title == null || title.isEmpty) return null;
    return title;
  }

  /// Agent-aware title, preferring live session metadata when available.
  String? get agentContextTitle {
    final sessionTitle = agentSessionDisplayTitle;
    if (sessionTitle != null) return sessionTitle;
    return _agentFallbackContextTitle;
  }

  String? get _agentFallbackContextTitle {
    final tool = foregroundAgentTool;
    if (tool == null) return null;
    final context = _windowContextLabelFromPath(currentPath);
    if (context != null) {
      return '${tool.label} · $context';
    }
    return tool.label;
  }

  /// A short display title — prefers live session metadata, then tmux titles.
  String get displayTitle {
    final sessionTitle = agentSessionDisplayTitle;
    if (sessionTitle != null) return sessionTitle;
    return _tmuxDisplayTitle;
  }

  String get _tmuxDisplayTitle {
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    final normalizedCommand = _normalizedTmuxTitle(
      currentCommand,
      stripPlaceholderPrefix: true,
    );
    final agentTitle = _agentFallbackContextTitle;
    final foregroundTool = foregroundAgentTool;
    if (agentTitle != null &&
        foregroundTool != null &&
        _isUnhelpfulAgentTitle(
          normalizedPaneTitle,
          tool: foregroundTool,
          contextLabel: _windowContextLabelFromPath(currentPath),
        )) {
      return agentTitle;
    }
    if (normalizedPaneTitle == null ||
        _isUnhelpfulTmuxTitle(
          normalizedPaneTitle,
          normalizedName: normalizedName,
          normalizedCommand: normalizedCommand,
        )) {
      return agentTitle ?? normalizedName ?? name;
    }
    if (normalizedName == null) return normalizedPaneTitle;
    if (_hasPlaceholderPrefix(name)) return normalizedPaneTitle;
    if (_isDecoratedVariantOfTitle(name, normalizedPaneTitle)) {
      return name.trim();
    }
    return normalizedPaneTitle;
  }

  /// A compact window label for surfaces that should track tmux window
  /// switches immediately.
  ///
  /// tmux updates `window_name` as part of the window-switch snapshot, while
  /// `pane_title` can lag slightly behind focus changes on some hosts. Prefer
  /// the normalized window name here so collapsed labels stay in sync with the
  /// active window selection. If the window name is just echoing the current
  /// command (for example `copilot` or `claude`), prefer the richer pane title
  /// instead so the collapsed handle still distinguishes agent sessions.
  String get handleTitle {
    final sessionTitle = agentSessionDisplayTitle;
    if (sessionTitle != null) return sessionTitle;
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    final normalizedCommand = _normalizedTmuxTitle(
      currentCommand,
      stripPlaceholderPrefix: true,
    );
    final agentTitle = _agentFallbackContextTitle;
    final foregroundTool = foregroundAgentTool;
    if (agentTitle != null &&
        foregroundTool != null &&
        _isUnhelpfulAgentTitle(
          normalizedPaneTitle,
          tool: foregroundTool,
          contextLabel: _windowContextLabelFromPath(currentPath),
        )) {
      return agentTitle;
    }
    if (_isUnhelpfulTmuxTitle(
      normalizedPaneTitle,
      normalizedName: normalizedName,
      normalizedCommand: normalizedCommand,
    )) {
      return agentTitle ?? normalizedName ?? displayTitle;
    }
    if (normalizedPaneTitle != null &&
        normalizedName != null &&
        foregroundTool != null &&
        _isAgentTitleAlias(normalizedName, foregroundTool)) {
      return normalizedPaneTitle;
    }
    if (normalizedPaneTitle != null &&
        normalizedName != null &&
        normalizedCommand != null &&
        normalizedName.toLowerCase() == normalizedCommand.toLowerCase() &&
        normalizedPaneTitle != normalizedName) {
      return normalizedPaneTitle;
    }
    return normalizedName ?? displayTitle;
  }

  /// Secondary context for the window title when both pane and window names
  /// are useful and distinct.
  String? get secondaryTitle {
    final display = displayTitle;
    final sessionTitle = _normalizedTmuxTitle(agentSessionTitle);
    if (sessionTitle != null) {
      final toolLabel = foregroundAgentTool?.label;
      final tmuxTitle = _tmuxSecondaryTitleForAgentSession;
      final secondaryParts = <String>[
        if (toolLabel != null && !_titlesMatch(toolLabel, display)) toolLabel,
        if (tmuxTitle != null &&
            !_titlesMatch(tmuxTitle, display) &&
            !_titlesMatch(tmuxTitle, sessionTitle) &&
            !_titlesMatch(tmuxTitle, toolLabel))
          tmuxTitle,
      ];
      if (secondaryParts.isNotEmpty) {
        return secondaryParts.join(' · ');
      }
      return null;
    }
    final normalizedPaneTitle = _normalizedTmuxTitle(
      paneTitle,
      stripPlaceholderPrefix: true,
    );
    final normalizedName = _normalizedTmuxTitle(
      name,
      stripPlaceholderPrefix: true,
    );
    final sessionLabel = agentSessionLabel;
    final agentTitle = agentContextTitle;
    if (agentTitle != null && display == agentTitle) {
      return sessionLabel == display ? null : sessionLabel;
    }
    if (sessionLabel != null && sessionLabel != display) {
      final toolLabel = foregroundAgentTool?.label;
      final secondaryParts = <String>[
        if (toolLabel != null && !_titlesMatch(toolLabel, display)) toolLabel,
        sessionLabel,
      ];
      return secondaryParts.join(' · ');
    }

    if (_isDecoratedVariantOfTitle(name, normalizedPaneTitle)) {
      return null;
    }
    if (normalizedPaneTitle == null ||
        normalizedName == null ||
        normalizedName == normalizedPaneTitle) {
      return null;
    }
    if (_titlesMatch(normalizedName, display)) {
      return null;
    }
    return normalizedName;
  }

  String? get _tmuxSecondaryTitleForAgentSession {
    final tmuxTitle = _tmuxDisplayTitle;
    final fallbackAgentTitle = _agentFallbackContextTitle;
    if (_titlesMatch(tmuxTitle, fallbackAgentTitle)) return null;

    final foregroundTool = foregroundAgentTool;
    if (foregroundTool != null &&
        _isUnhelpfulAgentTitle(
          tmuxTitle,
          tool: foregroundTool,
          contextLabel: _windowContextLabelFromPath(currentPath),
        )) {
      return null;
    }
    return tmuxTitle;
  }

  /// A human-readable status label for display.
  ///
  String get statusLabel {
    if (hasAlert) return 'alert';
    if (isIdle) return 'waiting';
    return 'running';
  }

  /// The supported agent CLI running in the foreground, if one can be inferred.
  AgentLaunchTool? get foregroundAgentTool {
    for (final candidate in [currentCommand]) {
      final tool = agentLaunchToolForCommandName(candidate);
      if (tool != null) {
        return tool;
      }
    }
    if (agentTool != null) return agentTool;
    if (hasUnsupportedAgentTool) return null;
    for (final candidate in [name, paneTitle]) {
      final tool =
          agentLaunchToolForCommandName(candidate) ??
          _agentToolFromTerminalTitle(candidate);
      if (tool != null) {
        return tool;
      }
    }
    return _agentToolFromCommandText(paneStartCommand);
  }

  @override
  String toString() =>
      'TmuxWindow(index: $index, id: $id, name: $name, active: $isActive, '
      'command: $currentCommand, title: $paneTitle)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxWindow &&
          index == other.index &&
          id == other.id &&
          panePid == other.panePid &&
          name == other.name &&
          isActive == other.isActive &&
          currentCommand == other.currentCommand &&
          currentPath == other.currentPath &&
          flags == other.flags &&
          paneTitle == other.paneTitle &&
          paneStartCommand == other.paneStartCommand &&
          agentTool == other.agentTool &&
          hasUnsupportedAgentTool == other.hasUnsupportedAgentTool &&
          activeAgentSessionId == other.activeAgentSessionId &&
          agentSessionTitle == other.agentSessionTitle &&
          activeAgentSessionConfidence == other.activeAgentSessionConfidence &&
          nativeAcpBridgeId == other.nativeAcpBridgeId &&
          nativeAcpProviderId == other.nativeAcpProviderId &&
          terminalReportsMouseWheel == other.terminalReportsMouseWheel &&
          terminalMouseReportSgr == other.terminalMouseReportSgr &&
          terminalBracketedPasteMode == other.terminalBracketedPasteMode &&
          terminalProgress == other.terminalProgress &&
          lastActivityEpochSeconds == other.lastActivityEpochSeconds &&
          _snapshotIdleSeconds == other._snapshotIdleSeconds;

  @override
  int get hashCode => Object.hashAll([
    index,
    id,
    panePid,
    name,
    isActive,
    currentCommand,
    currentPath,
    flags,
    paneTitle,
    paneStartCommand,
    agentTool,
    hasUnsupportedAgentTool,
    activeAgentSessionId,
    agentSessionTitle,
    activeAgentSessionConfidence,
    nativeAcpBridgeId,
    nativeAcpProviderId,
    terminalReportsMouseWheel,
    terminalMouseReportSgr,
    terminalBracketedPasteMode,
    terminalProgress,
    lastActivityEpochSeconds,
    _snapshotIdleSeconds,
  ]);
}

/// Live update emitted while watching a tmux session in control mode.
sealed class TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowChangeEvent].
  const TmuxWindowChangeEvent();
}

/// A direct per-window snapshot from tmux's `%subscription-changed` output.
class TmuxWindowSnapshotEvent extends TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowSnapshotEvent].
  const TmuxWindowSnapshotEvent(this.window);

  /// The latest window snapshot from tmux.
  final TmuxWindow window;
}

/// A signal that callers should refetch the full window list.
class TmuxWindowReloadEvent extends TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowReloadEvent].
  const TmuxWindowReloadEvent();
}

/// A full live window-list snapshot.
class TmuxWindowListEvent extends TmuxWindowChangeEvent {
  /// Creates a new [TmuxWindowListEvent].
  const TmuxWindowListEvent(this.windows);

  /// The latest windows reported by the multiplexer.
  final List<TmuxWindow> windows;
}

/// Applies a live tmux window update to an existing window list.
List<TmuxWindow> applyTmuxWindowChangeEvent(
  List<TmuxWindow> windows,
  TmuxWindowChangeEvent event,
) {
  switch (event) {
    case TmuxWindowReloadEvent():
      return windows;
    case TmuxWindowListEvent(windows: final nextWindows):
      final byId = <String, TmuxWindow>{};
      final byIndex = <int, TmuxWindow>{};
      for (final window in windows) {
        if (window.id != null) byId.putIfAbsent(window.id!, () => window);
        byIndex.putIfAbsent(window.index, () => window);
      }
      return List<TmuxWindow>.unmodifiable(
        nextWindows.map((nextWindow) {
          final existingWindow = nextWindow.id == null
              ? byIndex[nextWindow.index]
              : byId[nextWindow.id];
          return existingWindow == null
              ? nextWindow
              : _preserveActiveAgentSessionMetadata(existingWindow, nextWindow);
        }),
      );
    case TmuxWindowSnapshotEvent(window: final window):
      final updated = <TmuxWindow>[];
      var existingIndex = -1;
      var needsSort = false;
      for (final existing in windows) {
        final matches = window.id == null
            ? existing.index == window.index
            : existing.id == window.id;
        if (matches && existingIndex == -1) existingIndex = updated.length;
        if (updated.isNotEmpty && updated.last.index > existing.index) {
          needsSort = true;
        }
        updated.add(
          window.isActive && existing.isActive && !matches
              ? existing.copyWith(isActive: false)
              : existing,
        );
      }
      if (existingIndex == -1) {
        updated.add(window);
        needsSort = true;
      } else {
        needsSort |= updated[existingIndex].index != window.index;
        updated[existingIndex] = _preserveActiveAgentSessionMetadata(
          updated[existingIndex],
          window,
        );
      }
      if (needsSort) updated.sort((a, b) => a.index.compareTo(b.index));
      return List<TmuxWindow>.unmodifiable(updated);
  }
}

TmuxWindow _preserveActiveAgentSessionMetadata(
  TmuxWindow existing,
  TmuxWindow updated,
) {
  if (updated.hasUnsupportedAgentTool || updated.agentSessionTitle != null) {
    return updated;
  }
  // MonkeyMux snapshots report the live session ID but omit its title, which
  // arrives in a separate metadata probe. Keep that title for the same session
  // so each snapshot does not switch the UI back to the terminal title.
  if (updated.activeAgentSessionId != null &&
      updated.activeAgentSessionId != existing.activeAgentSessionId) {
    return updated;
  }
  if (existing.activeAgentSessionId == null &&
      existing.agentSessionTitle == null) {
    return updated;
  }
  if (existing.panePid != updated.panePid ||
      existing.foregroundAgentTool != updated.foregroundAgentTool) {
    return updated;
  }
  return updated.copyWith(
    activeAgentSessionId: existing.activeAgentSessionId,
    agentSessionTitle: existing.agentSessionTitle,
    activeAgentSessionConfidence:
        updated.activeAgentSessionConfidence ??
        existing.activeAgentSessionConfidence,
  );
}

/// Resolves the tmux window list after a full reload query.
///
/// A live tmux session should always report at least one window. Treat an
/// empty reload as transient: preserve the prior non-empty snapshot when
/// possible so the UI does not collapse into a broken-looking empty state
/// while a follow-up refresh retries in the background.
List<TmuxWindow>? resolveTmuxReloadedWindows(
  Iterable<TmuxWindow>? currentWindows,
  Iterable<TmuxWindow> reloadedWindows,
) {
  final nextWindows = reloadedWindows.toList(growable: false);
  if (nextWindows.isNotEmpty) {
    return nextWindows;
  }

  final previousWindows = currentWindows?.toList(growable: false);
  if (previousWindows != null && previousWindows.isNotEmpty) {
    return previousWindows;
  }

  return null;
}

/// Returns whether a transient empty tmux reload should keep showing the last
/// known non-empty window snapshot.
bool shouldPreserveTmuxWindowSnapshotOnEmptyReload(
  Iterable<TmuxWindow>? currentWindows, {
  required int consecutiveEmptyReloads,
  int maxConsecutiveEmptyReloads = 3,
}) {
  if (consecutiveEmptyReloads > maxConsecutiveEmptyReloads) {
    return false;
  }
  return currentWindows?.any((_) => true) ?? false;
}

/// Resolves the retry delay for tmux window reload recovery.
///
/// Uses exponential backoff so dead sessions do not get polled aggressively
/// forever while still continuing to self-heal if tmux comes back later.
Duration resolveTmuxWindowReloadRetryDelay(
  int retryAttempt, {
  Duration initialDelay = const Duration(seconds: 2),
  Duration maxDelay = const Duration(seconds: 30),
}) {
  if (retryAttempt <= 0) {
    return initialDelay;
  }

  var delay = initialDelay;
  for (var attempt = 0; attempt < retryAttempt; attempt++) {
    final doubledDelay = Duration(milliseconds: delay.inMilliseconds * 2);
    if (doubledDelay >= maxDelay) {
      return maxDelay;
    }
    delay = doubledDelay;
  }
  return delay;
}

/// Metadata for a recent AI coding tool session found on a remote host.
@immutable
class ToolSessionInfo {
  /// Creates a new [ToolSessionInfo].
  const ToolSessionInfo({
    required this.toolName,
    required this.sessionId,
    this.workingDirectory,
    this.originWorkingDirectory,
    this.lastActive,
    this.summary,
  });

  /// Human-readable tool name (e.g., "Claude Code", "Codex").
  final String toolName;

  /// Tool-specific session identifier used for resume commands.
  final String sessionId;

  /// The working directory this session was used in.
  final String? workingDirectory;

  /// The directory this session started in, when it since moved elsewhere.
  ///
  /// Pi rewrites a session into a new directory when work moves to a worktree,
  /// which leaves [workingDirectory] pointing away from where the user began
  /// the conversation. Keeping the original directory lets project-scoped
  /// pickers still offer the session where it started.
  final String? originWorkingDirectory;

  /// When this session was last active.
  final DateTime? lastActive;

  /// A brief summary or title for the session, if available.
  final String? summary;

  /// How long ago this session was active, as a human-readable string.
  String get timeAgoLabel {
    if (lastActive == null) return '';
    final diff = DateTime.now().difference(lastActive!);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${diff.inDays ~/ 7}w ago';
  }

  /// A compact absolute + relative timestamp label for session lists.
  String get lastUpdatedLabel {
    if (lastActive == null) return '';
    final localTime = lastActive!.toLocal();
    final now = DateTime.now();
    final month = _monthAbbreviations[localTime.month - 1];
    final dateLabel = localTime.year == now.year
        ? '$month ${localTime.day}'
        : '$month ${localTime.day}, ${localTime.year}';
    return '$dateLabel | $timeAgoLabel';
  }

  @override
  String toString() =>
      'ToolSessionInfo(tool: $toolName, id: $sessionId, '
      'lastActive: $lastActive)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolSessionInfo &&
          toolName == other.toolName &&
          sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(toolName, sessionId);
}

const _monthAbbreviations = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Returns whether [value] is a stable tmux window ID such as `@7`.
bool isValidTmuxWindowId(String value) => RegExp(r'^@\d+$').hasMatch(value);

String? _nonEmpty(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _normalizedTmuxTitle(
  String? value, {
  bool stripPlaceholderPrefix = false,
}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  var normalized = trimmed;
  if (stripPlaceholderPrefix) {
    normalized = normalized.replaceFirst(RegExp(r'^_+\s*'), '').trimLeft();
    normalized = normalized.replaceAll(RegExp(r'\s_+\s'), ' ').trim();
  }

  return normalized.isEmpty ? null : normalized;
}

bool _hasPlaceholderPrefix(String value) => value.trimLeft().startsWith('_');

const _genericTmuxTitles = <String>{
  'bash',
  'fish',
  'login',
  'sh',
  'shell',
  'terminal',
  'tmux',
  'zsh',
};

bool _isUnhelpfulTmuxTitle(
  String? value, {
  String? normalizedName,
  String? normalizedCommand,
}) {
  if (value == null || value.isEmpty) return true;
  if (_isDecorativeShellTitle(value)) return true;
  final lowered = value.toLowerCase();
  if (_genericTmuxTitles.contains(lowered)) return true;
  if (normalizedName != null && lowered == normalizedName.toLowerCase()) {
    return true;
  }
  if (normalizedCommand != null && lowered == normalizedCommand.toLowerCase()) {
    return true;
  }
  return _isLikelyDefaultHostTitle(value);
}

bool _isLikelyDefaultHostTitle(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return false;
  final lowered = trimmed.toLowerCase();
  if (lowered == 'localhost') return true;
  return RegExp(
    r'^[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+$',
    caseSensitive: false,
  ).hasMatch(trimmed);
}

bool _isUnhelpfulAgentTitle(
  String? value, {
  required AgentLaunchTool tool,
  required String? contextLabel,
}) {
  if (value == null || value.isEmpty) return true;
  if (_isDecorativeShellTitle(value)) return true;
  final lowered = _normalizeAgentTitleForComparison(value);
  if (lowered.isEmpty) return true;
  if (_isAgentTitleAlias(value, tool)) return true;
  if (_isLikelyDefaultHostTitle(value)) return true;

  final loweredContext = contextLabel?.trim().toLowerCase();
  if (loweredContext != null &&
      loweredContext.isNotEmpty &&
      lowered == loweredContext) {
    return true;
  }

  final statusMatch = RegExp(
    r'^(?:idle|ready|running|thinking|waiting|working)(?:\s+\(([^)]+)\))?$',
  ).firstMatch(lowered);
  if (statusMatch == null) return false;
  final statusContext = statusMatch.group(1)?.trim();
  return statusContext == null ||
      statusContext.isEmpty ||
      statusContext == loweredContext;
}

bool _isAgentTitleAlias(String value, AgentLaunchTool tool) =>
    _agentTitleAliases(tool).contains(_normalizeAgentTitleForComparison(value));

bool _isDecorativeShellTitle(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return true;
  if (trimmed == '~' || trimmed.endsWith('|~')) return true;
  return !trimmed.runes.any(_isAsciiLetterOrDigit);
}

String _normalizeAgentTitleForComparison(String value) =>
    _stripLeadingDecorativePrefix(
      value,
    ).replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

Set<String> _agentTitleAliases(AgentLaunchTool tool) => switch (tool) {
  AgentLaunchTool.claudeCode => const {'claude', 'claude code'},
  AgentLaunchTool.copilotCli => const {
    'copilot',
    'copilot cli',
    'github copilot',
  },
  AgentLaunchTool.codex => const {'codex'},
  AgentLaunchTool.openCode => const {'opencode', 'open code'},
  AgentLaunchTool.antigravity => const {'agy', 'antigravity'},
  AgentLaunchTool.cursorAgent => const {
    'cursor agent',
    'cursor-agent',
    'cursor cli',
  },
  AgentLaunchTool.pi => const {'pi'},
  AgentLaunchTool.hermes => const {'hermes', 'hermes agent'},
  AgentLaunchTool.openclaw => const {'openclaw', 'openclaw tui'},
  AgentLaunchTool.grokBuild => const {'grok', 'grok build'},
};

AgentLaunchTool? _agentToolFromTerminalTitle(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final normalized = _normalizeAgentTitleForComparison(value);
  if (normalized.isEmpty) return null;
  for (final tool in AgentLaunchTool.values) {
    for (final alias in _agentTitleAliases(tool)) {
      if (normalized == alias ||
          normalized.startsWith('$alias ') ||
          normalized.startsWith('$alias:')) {
        return tool;
      }
    }
  }
  return null;
}

bool _isDecoratedVariantOfTitle(String rawTitle, String? plainTitle) {
  if (plainTitle == null || plainTitle.isEmpty) return false;
  final trimmed = rawTitle.trim();
  if (trimmed.isEmpty || _hasPlaceholderPrefix(trimmed)) return false;
  final stripped = _stripLeadingDecorativePrefix(trimmed);
  return stripped.isNotEmpty && stripped == plainTitle && trimmed != plainTitle;
}

bool _titlesMatch(String? left, String? right) {
  final normalizedLeft = _normalizeTitleForComparison(left);
  final normalizedRight = _normalizeTitleForComparison(right);
  return normalizedLeft != null &&
      normalizedRight != null &&
      normalizedLeft == normalizedRight;
}

String? _normalizeTitleForComparison(String? value) {
  final normalized = _normalizedTmuxTitle(value, stripPlaceholderPrefix: true);
  if (normalized == null) return null;
  final comparable = _stripLeadingDecorativePrefix(
    normalized,
  ).replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  return comparable.isEmpty ? null : comparable;
}

String _stripLeadingDecorativePrefix(String value) {
  final characters = value.runes.toList(growable: false);
  var startIndex = 0;
  while (startIndex < characters.length &&
      !_isAsciiLetterOrDigit(characters[startIndex])) {
    startIndex++;
  }
  if (startIndex == 0 || startIndex >= characters.length) return value;
  return String.fromCharCodes(characters.sublist(startIndex)).trimLeft();
}

bool _isAsciiLetterOrDigit(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5A) ||
    (rune >= 0x61 && rune <= 0x7A);

AgentLaunchTool? _agentToolFromCommandText(String? value) =>
    agentLaunchToolForCommandText(value);

AgentLaunchTool? _agentToolFromMetadata(String? value) =>
    agentLaunchToolForCommandName(value) ??
    agentLaunchToolForCommandText(value);

AgentSessionConfidence? _agentSessionConfidenceFromWindowFields(
  List<String> fields,
) {
  final confidence = fields.length > 14
      ? _agentSessionConfidenceFromMetadata(fields[14])
      : null;
  if (confidence != null) return confidence;
  final sessionId = fields.length > 12 ? _nonEmpty(fields[12]) : null;
  final title = fields.length > 13 ? _nonEmpty(fields[13]) : null;
  if (sessionId != null || title != null) return AgentSessionConfidence.high;
  return null;
}

AgentSessionConfidence? _agentSessionConfidenceFromMetadata(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  return switch (normalized) {
    'high' => AgentSessionConfidence.high,
    'medium' => AgentSessionConfidence.medium,
    'low' => AgentSessionConfidence.low,
    _ => null,
  };
}

final _agentResumeFlagPattern = RegExp(
  r'''(?<!\S)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentResumeCommandPattern = RegExp(
  r'''(?<!\S)resume\s+(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentSessionFlagPattern = RegExp(
  r'''(?<!\S)--session(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentConversationFlagPattern = RegExp(
  r'''(?<!\S)--conversation(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentSessionIdFlagPattern = RegExp(
  r'''(?<!\S)--session-id(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentShortResumeFlagPattern = RegExp(
  r'''(?<!\S)-r\s+(?:"([^"]+)"|'([^']+)'|(\S+))''',
);
final _agentResumeOrLoadFlagPattern = RegExp(
  r'''(?<!\S)--(?:resume|load)(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))''',
);

/// Extracts a tool-specific session ID from a launch/resume command.
String? agentSessionIdFromLaunchCommand(
  String? value, {
  required AgentLaunchTool tool,
}) {
  final command = value?.trim();
  if (command == null || command.isEmpty) return null;
  final patterns = switch (tool) {
    AgentLaunchTool.claudeCode => [_agentResumeFlagPattern],
    AgentLaunchTool.copilotCli => [_agentResumeFlagPattern],
    AgentLaunchTool.codex => [_agentResumeCommandPattern],
    AgentLaunchTool.openCode => [_agentSessionFlagPattern],
    AgentLaunchTool.antigravity => [_agentConversationFlagPattern],
    AgentLaunchTool.cursorAgent => [_agentResumeFlagPattern],
    AgentLaunchTool.pi => [
      _agentSessionFlagPattern,
      _agentSessionIdFlagPattern,
    ],
    AgentLaunchTool.hermes => [
      _agentResumeFlagPattern,
      _agentShortResumeFlagPattern,
    ],
    AgentLaunchTool.openclaw => [_agentSessionFlagPattern],
    AgentLaunchTool.grokBuild => [
      _agentResumeOrLoadFlagPattern,
      _agentShortResumeFlagPattern,
    ],
  };

  for (final pattern in patterns) {
    final match = pattern.firstMatch(command);
    if (match == null) continue;
    for (var index = 1; index <= match.groupCount; index++) {
      final value = match.group(index)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
  }
  return null;
}

String? _agentSessionIdFromCommand(
  String? value, {
  required AgentLaunchTool tool,
}) => agentSessionIdFromLaunchCommand(value, tool: tool);

String? _windowContextLabelFromPath(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final parts = trimmed
      .split('/')
      .where((part) => part.isNotEmpty && part != '.' && part != '~')
      .toList(growable: false);
  if (parts.isEmpty) return null;
  for (var index = 0; index < parts.length - 1; index++) {
    final segment = parts[index];
    if (segment.endsWith('.worktrees')) {
      return parts[index + 1];
    }
  }
  return parts.last;
}

// ── tmux command helpers ──────────────────────────────────────────────────

/// tmux command fragment that disables tmux's built-in status bar.
const tmuxDisableStatusBarCommand = r'\; set status off';

/// tmux command fragment that lets focus-aware TUIs receive focus events.
const tmuxEnableFocusEventsCommand = r'\; set-option -g focus-events on';

/// Builds a `tmux new-session` command from structured configuration.
///
/// Always uses `-A` (attach-or-create) so reconnecting reuses the session.
String buildTmuxCommand({
  required String sessionName,
  String? workingDirectory,
  String? extraFlags,
}) {
  final parts = <String>[
    'tmux new-session -A',
    "-s '${sessionName.replaceAll("'", "'\"'\"'")}'",
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
      "-c '${workingDirectory.trim().replaceAll("'", "'\"'\"'")}'",
    // Extra flags are intentionally raw user input; never populate from imports.
    if (extraFlags != null && extraFlags.trim().isNotEmpty) extraFlags.trim(),
    tmuxEnableFocusEventsCommand,
  ];
  return parts.join(' ');
}

/// Attempts to extract the tmux session name from a command string.
///
/// Handles common patterns:
/// - `tmux new-session -A -s myproject`
/// - `tmux new -As myproject`
/// - `tmux a -t myproject`
/// - `tmux attach -t myproject`
///
/// Returns `null` if the command doesn't appear to be a tmux invocation
/// or the session name can't be parsed.
String? parseTmuxSessionName(String? command) {
  if (command == null || command.isEmpty) return null;

  // Normalize: strip leading cd/env/path prefixes to find 'tmux ...'
  final tmuxIdx = command.indexOf('tmux ');
  if (tmuxIdx < 0) return null;
  final tmuxPart = command.substring(tmuxIdx);

  // Match a shell argument: 'quoted', "quoted", or unquoted-word.
  const argPattern = r"""(?:'([^']*)'|"([^"]*)"|(\S+))""";

  // Try -s <name> (new-session / new).
  // Use a whitespace lookbehind so we match standalone flags like `-s`
  // or combined flags like `-As`, but not subcommand suffixes like
  // `list-sessions`.
  final sFlag = RegExp(
    '(?<=\\s)-[A-Za-z]*s\\s+$argPattern',
  ).firstMatch(tmuxPart);
  if (sFlag != null) {
    return sFlag.group(1) ?? sFlag.group(2) ?? sFlag.group(3);
  }

  // Try -t <name> (attach / attach-session)
  final tFlag = RegExp(
    '(?<=\\s)-[A-Za-z]*t\\s+$argPattern',
  ).firstMatch(tmuxPart);
  if (tFlag != null) {
    return tFlag.group(1) ?? tFlag.group(2) ?? tFlag.group(3);
  }

  return null;
}

/// Resolves the preferred tmux session name before running remote queries.
///
/// Structured host settings win over parsed auto-connect commands because they
/// are explicit and avoid ambiguous tmux inference when multiple sessions exist.
String? resolvePreferredTmuxSessionName({
  String? structuredSessionName,
  String? autoConnectCommand,
}) {
  final structured = structuredSessionName?.trim();
  if (structured != null && structured.isNotEmpty) {
    return structured;
  }
  return parseTmuxSessionName(autoConnectCommand);
}
