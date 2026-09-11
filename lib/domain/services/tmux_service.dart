import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'command_output_marker_reader.dart';
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'remote_multiplexer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _backslashCodeUnit = 0x5C;

enum _ShellQuoteMode { none, single, double }

/// Error thrown when a tmux command channel ends before confirming completion.
class TmuxCommandException implements Exception {
  /// Creates a [TmuxCommandException].
  const TmuxCommandException(this.message);

  /// Human-readable description of the command failure.
  final String message;

  @override
  String toString() => message;
}

class _TmuxExecChannelCoolingDownException implements Exception {
  _TmuxExecChannelCoolingDownException(this.cooldownRemaining);

  final Duration cooldownRemaining;

  @override
  String toString() =>
      'Tmux exec channel is cooling down for '
      '${cooldownRemaining.inMilliseconds}ms';
}

typedef _ActiveAgentSessionMetadata = ({
  AgentLaunchTool tool,
  String sessionId,
  String? title,
  AgentSessionConfidence confidence,
});

/// Introspects and controls tmux sessions on remote hosts via SSH exec
/// channels.
///
/// All queries use `SshSession.execute()` to avoid interfering with the
/// interactive shell. The results are parsed from tmux's `-F` format strings.
///
/// The tmux binary path is cached after first successful detection to
/// avoid redundant profile sourcing on subsequent calls.
class TmuxService implements RemoteMultiplexerService {
  /// Creates a new [TmuxService].
  const TmuxService({
    Duration execOpenTimeout = const Duration(seconds: 10),
    Duration execOutputTimeout = const Duration(seconds: 10),
    DateTime Function()? execChannelNow,
    Duration agentSessionMetadataRefreshDebounce = const Duration(
      milliseconds: 150,
    ),
    Duration agentSessionMetadataPeriodicRefreshInterval = const Duration(
      seconds: 10,
    ),
    Duration windowSwitchActivityGracePeriod = const Duration(seconds: 1),
  }) : _execOpenTimeout = execOpenTimeout,
       _execOutputTimeout = execOutputTimeout,
       _execChannelNow = execChannelNow,
       _agentSessionMetadataRefreshDebounce =
           agentSessionMetadataRefreshDebounce,
       _agentSessionMetadataPeriodicRefreshInterval =
           agentSessionMetadataPeriodicRefreshInterval,
       _windowSwitchActivityGracePeriod = windowSwitchActivityGracePeriod;

  final Duration _execOpenTimeout;
  final Duration _execOutputTimeout;
  final DateTime Function()? _execChannelNow;
  final Duration _agentSessionMetadataRefreshDebounce;
  final Duration _agentSessionMetadataPeriodicRefreshInterval;
  final Duration _windowSwitchActivityGracePeriod;

  static final _connectionStates = <int, _TmuxConnectionState>{};

  static _TmuxConnectionState _stateFor(int connectionId) =>
      _connectionStates.putIfAbsent(connectionId, _TmuxConnectionState.new);

  static bool _ownsState(int connectionId, _TmuxConnectionState state) =>
      identical(_connectionStates[connectionId], state);

  static void _requireState(int connectionId, _TmuxConnectionState state) {
    if (!_ownsState(connectionId, state)) {
      throw const TmuxCommandException('Tmux connection state was cleared');
    }
  }

  /// Whether a connection still owns any tmux state, including scheduled work.
  @visibleForTesting
  static bool hasConnectionStateForTesting(int connectionId) =>
      _connectionStates.containsKey(connectionId);

  // A failed transport cannot recover in place. Key this by session identity so
  // clearing caches cannot revive it or disable a replacement connection.
  static final _deadExecSessions = Expando<bool>();

  static const _execDoneMarker = '__flutty_tmux_exec_done__';
  static const _installedAgentToolsFreshTtl = Duration(minutes: 30);
  static const _activeAgentSessionMetadataFreshTtl = Duration(seconds: 5);

  static String _tmuxCommand(
    String command, {
    String? extraFlags,
    bool forceUtf8 = false,
  }) {
    final clientFlags = resolveTmuxClientFlagsFromExtraFlags(extraFlags);
    final options = <String>[if (forceUtf8) '-u', ?clientFlags];
    final optionText = options.isEmpty ? '' : '${options.join(' ')} ';
    return 'tmux $optionText$command';
  }

  /// Returns the version reported by the active remote tmux server.
  @override
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    try {
      final output = await _execTmuxCommand(
        session,
        sessionName,
        'display-message -p -t ${shellEscapePosix('$sessionName:')} '
        '${shellEscapePosix('#{version}')}',
        extraFlags: extraFlags,
        priority: SshExecPriority.low,
      );
      return parseTmuxVersionOutput(output);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'version_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns whether a tmux binary path cache entry exists for [connectionId].
  @visibleForTesting
  static bool hasTmuxPathCacheEntry(int connectionId) =>
      _connectionStates[connectionId]?.tmuxPath != null;

  /// Returns whether an installed agent tools cache entry exists for
  /// [connectionId].
  @visibleForTesting
  static bool hasInstalledAgentToolsCacheEntry(int connectionId) =>
      _connectionStates[connectionId]?.installedAgentTools != null;

  /// Invalidates installed-agent detection for [connectionId].
  ///
  /// Any in-flight result from before this call is prevented from repopulating
  /// the cache. The next detection or prefetch starts a fresh remote probe.
  void invalidateInstalledAgentTools(int connectionId) {
    final state = _stateFor(connectionId);
    state.installedAgentToolsRequest?.ignore();
    state
      ..installedAgentTools = null
      ..installedAgentToolsRequest = null;
    DiagnosticsLogService.instance.info(
      'tmux.agent',
      'tool_detection_invalidated',
      fields: {'connectionId': connectionId},
    );
  }

  /// Returns whether a window snapshot cache entry exists for [connectionId].
  @visibleForTesting
  static bool hasWindowSnapshotCacheEntry(int connectionId) =>
      _connectionStates[connectionId]?.windowSnapshotCache.isNotEmpty ?? false;

  /// Returns whether an exec-channel backoff entry exists for [connectionId].
  @visibleForTesting
  static bool hasExecChannelBackoffEntry(int connectionId) =>
      _connectionStates[connectionId]?.execChannelBackoff != null;

  /// Returns the exec-channel failure count for [connectionId], if any.
  @visibleForTesting
  static int? execChannelBackoffFailureCountForTesting(int connectionId) =>
      _connectionStates[connectionId]?.execChannelBackoff?.failureCount;

  /// Clears tmux caches and disposes active watchers for a connection.
  Future<void> clearCache(int connectionId) async {
    final state = _connectionStates.remove(connectionId);
    DiagnosticsLogService.instance.info(
      'tmux.cache',
      'clear',
      fields: {
        'connectionId': connectionId,
        'observerCount': state?.windowObservers.length ?? 0,
      },
    );
    await state?.dispose();
  }

  /// Defers one-shot tmux exec channels for [duration].
  ///
  /// The persistent control-mode client can switch windows immediately, but the
  /// attached shell channel carries the actual redraw. Opening auxiliary SSH exec
  /// channels (foreground checks, command detection, theme refreshes) right after
  /// `select-window` can starve that redraw on high-latency hosts. This quiet
  /// period keeps those helpers off the critical path while leaving control-mode
  /// commands untouched.
  void deferExecsForRedraw(SshSession session, Duration duration) {
    final state = _stateFor(session.connectionId);
    if (duration <= Duration.zero) {
      return;
    }
    final until = DateTime.now().add(duration);
    final existing = state.execQuietUntil;
    if (existing == null || existing.isBefore(until)) {
      state.execQuietUntil = until;
    }
  }

  // ── Detection ──────────────────────────────────────────────────────────

  /// Returns `true` if the primary SSH terminal is attached to tmux.
  ///
  /// This deliberately ignores tmux servers and clients that belong to other
  /// SSH logins on the same host.
  Future<bool> isTmuxActive(SshSession session, {String? extraFlags}) async {
    try {
      return await isTmuxActiveOrThrow(session, extraFlags: extraFlags);
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.detect',
        'active_check_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Returns `true` if the primary SSH terminal is attached to tmux, and throws
  /// when the remote check could not complete.
  ///
  /// Unlike [isTmuxActive], this distinguishes "not attached to tmux" from
  /// infrastructure failures so callers can preserve existing UI on
  /// indeterminate detection results.
  Future<bool> isTmuxActiveOrThrow(
    SshSession session, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.detect',
      'active_check_start',
      fields: {'connectionId': session.connectionId},
    );
    final active =
        await foregroundSessionNameOrThrow(session, extraFlags: extraFlags) !=
        null;
    DiagnosticsLogService.instance.info(
      'tmux.detect',
      'active_check_complete',
      fields: {'connectionId': session.connectionId, 'active': active},
    );
    return active;
  }

  /// Returns the tmux session attached to the primary SSH terminal, if any.
  Future<String?> foregroundSessionName(
    SshSession session, {
    String? extraFlags,
  }) async {
    try {
      return await foregroundSessionNameOrThrow(
        session,
        extraFlags: extraFlags,
      );
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'foreground_session_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns the tmux session attached to the primary SSH terminal, and throws
  /// when the remote check could not complete.
  @override
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) => _foregroundSessionNameOrThrow(
    session,
    priority: SshExecPriority.low,
    extraFlags: extraFlags,
  );

  Future<String?> _foregroundSessionNameOrThrow(
    SshSession session, {
    required SshExecPriority priority,
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'foreground_session_start',
      fields: {'connectionId': session.connectionId},
    );
    final state = _stateFor(session.connectionId);
    await _cacheTmuxPath(session);
    _requireState(session.connectionId, state);
    final output = await _exec(
      session,
      _buildForegroundTmuxSessionCommand(extraFlags: extraFlags),
      priority: priority,
    );
    // Only the ancestry-scoped client lookup is authoritative. Any other probe
    // (for example `tmux display-message`) resolves tmux's most recently used
    // session on the whole host, which can belong to a different SSH login.
    final sessionName = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .firstOrNull;
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'foreground_session_complete',
      fields: {
        'connectionId': session.connectionId,
        'active': sessionName != null,
      },
    );
    return sessionName;
  }

  /// Detects which supported coding-agent CLIs are available on the
  /// remote host's `PATH`.
  ///
  /// POSIX remotes resolve binaries via `command -v` inside an interactive
  /// instance of the user's `$SHELL` (`zsh -ic` / `bash -ic` / …). This is
  /// necessary because many users add agent CLIs (Claude, npm-global bins, etc.)
  /// to `PATH` from their interactive rc file (`~/.zshrc`, `~/.bashrc`) rather
  /// than from a login profile, and SSH exec channels otherwise only see the
  /// minimal system `PATH` plus what we source from `~/.profile` /
  /// `~/.bash_profile` / `~/.zprofile`. The detection command is built
  /// per-binary so it also works on POSIX-strict `/bin/sh` (dash), where
  /// `command -v` rejects multiple operands.
  ///
  /// Windows remotes use a PowerShell `Get-Command` probe because OpenSSH starts
  /// exec channels under `cmd.exe`/PowerShell rather than a POSIX shell.
  ///
  /// Detection results, including empty sets, are cached per connection.
  /// Stale cached results are returned immediately while a refresh runs in
  /// the background.
  Future<Set<AgentLaunchTool>> detectInstalledAgentTools(
    SshSession session,
  ) async {
    final state = _stateFor(session.connectionId);
    final cached = state.installedAgentTools;
    if (cached != null) {
      final age = DateTime.now().difference(cached.cachedAt);
      DiagnosticsLogService.instance.info(
        'tmux.agent',
        'tool_detection_cached',
        fields: {
          'connectionId': session.connectionId,
          'toolCount': cached.tools.length,
          'ageMs': age.inMilliseconds,
        },
      );
      if (age >= _installedAgentToolsFreshTtl) {
        if (_isExecChannelCoolingDown(session)) {
          DiagnosticsLogService.instance.debug(
            'tmux.agent',
            'tool_detection_refresh_deferred',
            fields: {'connectionId': session.connectionId},
          );
        } else {
          unawaited(
            _refreshInstalledAgentTools(session, priority: SshExecPriority.low),
          );
        }
      }
      return cached.tools;
    }

    return _refreshInstalledAgentTools(session);
  }

  /// Warms the installed agent CLI cache in the background.
  Future<void> prefetchInstalledAgentTools(SshSession session) async {
    final state = _stateFor(session.connectionId);
    final cached = state.installedAgentTools;
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) <
            _installedAgentToolsFreshTtl) {
      return;
    }
    if (_isExecChannelCoolingDown(session)) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_prefetch_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }
    try {
      await _refreshInstalledAgentTools(session, priority: SshExecPriority.low);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_prefetch_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  Future<Set<AgentLaunchTool>> _refreshInstalledAgentTools(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.normal,
  }) {
    final state = _stateFor(session.connectionId);
    final existingRequest = state.installedAgentToolsRequest;
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_join',
        fields: {'connectionId': session.connectionId},
      );
      return existingRequest;
    }

    DiagnosticsLogService.instance.info(
      'tmux.agent',
      'tool_detection_start',
      fields: {'connectionId': session.connectionId},
    );
    late final Future<Set<AgentLaunchTool>> request;
    request = () async {
      final output = session.remoteIsWindows
          ? await _execWindowsPowerShell(
              session,
              buildWindowsAgentToolDetectionScript(),
              priority: priority,
            )
          : await _exec(
              session,
              buildAgentToolDetectionCommand(),
              priority: priority,
            );
      final installed = parseInstalledAgentTools(output);
      if (_ownsState(session.connectionId, state) &&
          identical(state.installedAgentToolsRequest, request)) {
        state.installedAgentTools = _CachedInstalledAgentTools(
          tools: Set<AgentLaunchTool>.unmodifiable(installed),
          cachedAt: DateTime.now(),
        );
      }
      DiagnosticsLogService.instance.info(
        'tmux.agent',
        'tool_detection_complete',
        fields: {
          'connectionId': session.connectionId,
          'toolCount': installed.length,
        },
      );
      return installed;
    }();
    state.installedAgentToolsRequest = request;
    request.whenComplete(() {
      if (_ownsState(session.connectionId, state) &&
          identical(state.installedAgentToolsRequest, request)) {
        state.installedAgentToolsRequest = null;
      }
    }).ignore();
    return request;
  }

  /// Returns the name of the tmux session attached to this terminal.
  ///
  /// This does not infer a session from arbitrary attached tmux clients on the
  /// host; those may belong to other SSH logins.
  Future<String?> currentSessionName(
    SshSession session, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_session_start',
      fields: {'connectionId': session.connectionId},
    );
    final foregroundName = await foregroundSessionName(
      session,
      extraFlags: extraFlags,
    );
    if (foregroundName != null) {
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'current_session_foreground',
        fields: {'connectionId': session.connectionId},
      );
      return foregroundName;
    }

    DiagnosticsLogService.instance.info(
      'tmux.query',
      'current_session_unavailable',
      fields: {'connectionId': session.connectionId},
    );
    return null;
  }

  /// Returns `true` if [sessionName] exists on the remote tmux server.
  Future<bool> hasSession(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    try {
      return await hasSessionOrThrow(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'has_session_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Returns `true` if [sessionName] exists, and throws when the remote check
  /// could not complete.
  ///
  /// Unlike [hasSession], this distinguishes a missing tmux session from
  /// transient SSH exec/channel failures.
  Future<bool> hasSessionOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final state = _stateFor(session.connectionId);
    final requestKey = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final existingRequest = state.hasSessionRequests[requestKey];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'has_session_join',
        fields: {
          'connectionId': session.connectionId,
          'sessionHash': sessionName.hashCode.abs(),
        },
      );
      return existingRequest;
    }

    final request = _hasSessionOrThrow(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    state.hasSessionRequests[requestKey] = request;
    request.whenComplete(() {
      if (identical(state.hasSessionRequests[requestKey], request)) {
        state.hasSessionRequests.remove(requestKey);
      }
    }).ignore();
    return request;
  }

  Future<bool> _hasSessionOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'has_session_start',
      fields: {'connectionId': session.connectionId},
    );
    final state = _stateFor(session.connectionId);
    await _cacheTmuxPath(session);
    _requireState(session.connectionId, state);
    final output = await _exec(
      session,
      '${_tmuxCommand('has-session -t ${shellEscapePosix(sessionName)}', extraFlags: extraFlags)} 2>/dev/null; '
      r'status=$?; '
      r'if [ "$status" -eq 0 ]; then printf 1; '
      r'elif [ "$status" -eq 1 ]; then printf 0; '
      'else false; fi',
      priority: SshExecPriority.low,
    );
    final exists = output.trim() == '1';
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'has_session_complete',
      fields: {'connectionId': session.connectionId, 'exists': exists},
    );
    return exists;
  }

  // ── Window queries ─────────────────────────────────────────────────────

  /// Lists all windows in the given tmux [sessionName].
  @override
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final state = _stateFor(session.connectionId);
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    if (_isExecChannelCoolingDown(session) &&
        _controlCommandObserver(
              session,
              sessionName,
              extraFlags: extraFlags,
            )?.canRunCommands !=
            true) {
      final cachedWindows = state.windowSnapshotCache[key];
      if (cachedWindows != null && cachedWindows.isNotEmpty) {
        DiagnosticsLogService.instance.warning(
          'tmux.query',
          'list_windows_cached_during_backoff',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': cachedWindows.length,
          },
        );
        return cachedWindows;
      }
    }
    final existingRequest = state.windowListRequests[key];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'list_windows_join',
        fields: {
          'connectionId': session.connectionId,
          'sessionHash': sessionName.hashCode.abs(),
        },
      );
      return existingRequest;
    }

    final request = _listWindows(session, sessionName, extraFlags: extraFlags);
    state.windowListRequests[key] = request;
    request.whenComplete(() {
      if (identical(state.windowListRequests[key], request)) {
        state.windowListRequests.remove(key);
      }
    }).ignore();
    return request;
  }

  /// Lists every pane process ID in the given tmux [sessionName].
  Future<Set<int>> listPanePids(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final quotedName = shellEscapePosix(sessionName);
    final output = await _execTmuxCommand(
      session,
      sessionName,
      'list-panes -s -t $quotedName -F ${shellEscapePosix('#{pane_pid}')}',
      extraFlags: extraFlags,
      forceUtf8: true,
    );
    return parseTmuxPanePids(output);
  }

  Future<List<TmuxWindow>> _listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final state = _stateFor(session.connectionId);
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'list_windows_start',
      fields: {'connectionId': session.connectionId},
    );
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final quotedName = shellEscapePosix(sessionName);
    try {
      final output = await _execTmuxCommand(
        session,
        sessionName,
        'list-windows -t $quotedName -F '
        '${shellEscapePosix(_tmuxWindowSubscriptionFormat)}',
        extraFlags: extraFlags,
        forceUtf8: true,
      );
      final parsedWindows = _parseLines(
        output,
        TmuxWindow.fromTmuxFormat,
      ).toList(growable: false);
      final activityFilteredWindows = _suppressWindowSwitchRedrawActivity(
        key,
        parsedWindows,
      );
      final windows = List<TmuxWindow>.unmodifiable(
        _enrichWindowsWithCachedAgentSessionMetadata(
          session.connectionId,
          activityFilteredWindows,
        ),
      );
      if (_ownsState(session.connectionId, state) && windows.isNotEmpty) {
        state.windowSnapshotCache[_TmuxWindowWatchKey(
              connectionId: session.connectionId,
              sessionName: sessionName,
              extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
            )] =
            windows;
        _scheduleAgentSessionMetadataRefresh(session, windows);
      }

      DiagnosticsLogService.instance.info(
        'tmux.query',
        'list_windows_complete',
        fields: {
          'connectionId': session.connectionId,
          'windowCount': windows.length,
          'activeWindowCount': windows
              .where((window) => window.isActive)
              .length,
          'alertWindowCount': windows.where((window) => window.hasAlert).length,
        },
      );
      return windows;
    } on Object catch (error) {
      final cachedWindows =
          state.windowSnapshotCache[_TmuxWindowWatchKey(
            connectionId: session.connectionId,
            sessionName: sessionName,
            extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
          )];
      if (cachedWindows != null &&
          cachedWindows.isNotEmpty &&
          shouldUseCachedTmuxWindowsAfterListFailure(error)) {
        DiagnosticsLogService.instance.warning(
          'tmux.query',
          'list_windows_cached_after_failure',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': cachedWindows.length,
            'errorType': error.runtimeType,
          },
        );
        return cachedWindows;
      }
      rethrow;
    }
  }

  List<TmuxWindow> _enrichWindowsWithCachedAgentSessionMetadata(
    int connectionId,
    List<TmuxWindow> windows,
  ) {
    final metadataByPanePid = _connectionStates[connectionId]?.metadataCache;
    if (metadataByPanePid == null || metadataByPanePid.isEmpty) {
      return windows;
    }
    return _applyAgentSessionMetadataToWindows(
      windows,
      metadataByPanePid,
    ).windows;
  }

  void _scheduleAgentSessionMetadataRefresh(
    SshSession session,
    List<TmuxWindow> windows, {
    bool force = false,
  }) {
    final agentPanePids = _agentPanePids(windows);
    if (agentPanePids.isEmpty) {
      if (_cachedAgentPanePidsForConnection(session.connectionId).isEmpty) {
        _cancelAgentSessionMetadataPeriodicRefresh(session.connectionId);
      }
      return;
    }
    if (_hasWindowObserverForConnection(session.connectionId)) {
      _ensureAgentSessionMetadataPeriodicRefresh(session);
    }
    _scheduleAgentSessionMetadataRefreshForPanePids(
      session,
      agentPanePids,
      force: force,
    );
  }

  void _ensureAgentSessionMetadataPeriodicRefresh(SshSession session) {
    if (_isExecSessionClosed(session) ||
        _agentSessionMetadataPeriodicRefreshInterval <= Duration.zero) {
      return;
    }
    final connectionId = session.connectionId;
    final state = _stateFor(connectionId)..metadataPeriodicSession = session;
    if (state.metadataPeriodicTimer != null) {
      return;
    }
    state.metadataPeriodicTimer = Timer(
      _agentSessionMetadataPeriodicRefreshInterval,
      () {
        if (!_ownsState(connectionId, state)) return;
        state.metadataPeriodicTimer = null;
        final queuedSession = state.metadataPeriodicSession;
        if (queuedSession == null) {
          return;
        }
        if (!_hasWindowObserverForConnection(connectionId)) {
          state.metadataPeriodicSession = null;
          return;
        }
        final panePids = _cachedAgentPanePidsForConnection(connectionId);
        if (panePids.isEmpty) {
          state.metadataPeriodicSession = null;
          return;
        }
        _scheduleAgentSessionMetadataRefreshForPanePids(
          queuedSession,
          panePids,
          force: true,
        );
        _ensureAgentSessionMetadataPeriodicRefresh(queuedSession);
      },
    );
  }

  void _cancelAgentSessionMetadataPeriodicRefresh(int connectionId) {
    final state = _stateFor(connectionId);
    state.metadataPeriodicTimer?.cancel();
    state
      ..metadataPeriodicTimer = null
      ..metadataPeriodicSession = null;
  }

  Set<int> _cachedAgentPanePidsForConnection(int connectionId) {
    final state = _stateFor(connectionId);
    final panePids = <int>{};
    for (final entry in state.windowSnapshotCache.entries) {
      panePids.addAll(_agentPanePids(entry.value));
    }
    return panePids;
  }

  bool _hasWindowObserverForConnection(int connectionId) =>
      _connectionStates[connectionId]?.windowObservers.isNotEmpty ?? false;

  void _scheduleAgentSessionMetadataRefreshForPanePids(
    SshSession session,
    Set<int> agentPanePids, {
    bool force = false,
  }) => _scheduleMetadataBatch(
    session,
    agentPanePids,
    force: force,
    delay: _agentSessionMetadataRefreshDebounce,
    kind: _MetadataDelay.debounce,
  );

  void _scheduleMetadataBatch(
    SshSession session,
    Set<int> panePids, {
    required bool force,
    required Duration delay,
    required _MetadataDelay kind,
  }) {
    if (_isExecSessionClosed(session)) return;
    final connectionId = session.connectionId;
    final state = _stateFor(connectionId);
    state.metadataBatches[kind] = _mergeMetadataBatch(
      state.metadataBatches[kind],
      session,
      panePids,
      force,
    );
    state.metadataTimers.putIfAbsent(
      kind,
      () => Timer(delay, () {
        if (!_ownsState(connectionId, state)) return;
        state.metadataTimers.remove(kind);
        final batch = state.metadataBatches.remove(kind);
        if (batch == null || batch.panePids.isEmpty) return;
        if (kind == _MetadataDelay.cooldown) {
          _scheduleAgentSessionMetadataRefreshForPanePids(
            batch.session,
            batch.panePids,
            force: batch.force,
          );
        } else {
          _startAgentSessionMetadataRefreshForPanePids(
            batch.session,
            batch.panePids,
            force: batch.force,
          );
        }
      }),
    );
  }

  void _startAgentSessionMetadataRefreshForPanePids(
    SshSession session,
    Set<int> agentPanePids, {
    bool force = false,
  }) {
    if (_isExecSessionClosed(session)) return;
    final connectionId = session.connectionId;
    final state = _stateFor(connectionId);
    if (state.metadataRequest != null) {
      final activePanePids = state.metadataRequestPanePids ?? const <int>{};
      final hasNewPanePids = agentPanePids.any(
        (panePid) => !activePanePids.contains(panePid),
      );
      if (force || hasNewPanePids) {
        state.metadataPending = _mergeMetadataBatch(
          state.metadataPending,
          session,
          agentPanePids,
          force || hasNewPanePids,
        );
      }
      return;
    }

    final lastRefresh = state.metadataRefreshedAt;
    if (!force &&
        lastRefresh != null &&
        DateTime.now().difference(lastRefresh) <
            _activeAgentSessionMetadataFreshTtl) {
      return;
    }

    final execCooldown = _execChannelCooldownRemaining(session);
    if (execCooldown != null) {
      _deferAgentSessionMetadataRefreshForExecCooldown(
        session,
        agentPanePids,
        force: force,
        cooldown: execCooldown,
      );
      return;
    }

    DiagnosticsLogService.instance.debug(
      'tmux.agent',
      'active_session_metadata_start',
      fields: {
        'connectionId': connectionId,
        'paneCount': agentPanePids.length,
        'forced': force,
      },
    );

    state.metadataRequestPanePids = agentPanePids;
    late final Future<void> request;
    request =
        _refreshActiveAgentSessionMetadata(
          session,
          agentPanePids,
          force: force,
        ).whenComplete(() {
          if (_ownsState(connectionId, state) &&
              identical(state.metadataRequest, request)) {
            state
              ..metadataRequest = null
              ..metadataRequestPanePids = null;
            final pending = state.metadataPending;
            state.metadataPending = null;
            if (pending != null && pending.panePids.isNotEmpty) {
              _startAgentSessionMetadataRefreshForPanePids(
                pending.session,
                pending.panePids,
                force: pending.force,
              );
            }
          }
        });
    state.metadataRequest = request;
    unawaited(request);
  }

  Future<void> _refreshActiveAgentSessionMetadata(
    SshSession session,
    Set<int> panePids, {
    required bool force,
  }) async {
    final connectionId = session.connectionId;
    final state = _stateFor(connectionId);
    try {
      final output = await _exec(
        session,
        buildAgentActiveSessionMetadataCommand(panePids),
        priority: SshExecPriority.low,
      );
      if (!_ownsState(connectionId, state)) {
        return;
      }
      state.metadataRefreshedAt = DateTime.now();
      final metadataByPanePid = parseAgentActiveSessionMetadataOutput(
        output,
        panePids,
      );
      final nextMetadataByPanePid = Map<int, _ActiveAgentSessionMetadata>.of(
        state.metadataCache ?? const {},
      );
      for (final panePid in panePids) {
        nextMetadataByPanePid.remove(panePid);
      }
      nextMetadataByPanePid.addAll(metadataByPanePid);
      state.metadataCache = nextMetadataByPanePid;
      DiagnosticsLogService.instance.info(
        'tmux.agent',
        'active_session_metadata_complete',
        fields: {
          'connectionId': connectionId,
          'paneCount': panePids.length,
          'matchCount': metadataByPanePid.length,
        },
      );
      _applyActiveAgentSessionMetadataToCachedWindows(
        connectionId,
        nextMetadataByPanePid,
        refreshedPanePids: panePids,
      );
    } on Object catch (error) {
      if (!_ownsState(connectionId, state)) return;
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'active_session_metadata_failed',
        fields: {'connectionId': connectionId, 'errorType': error.runtimeType},
      );
      final Duration? execCooldown;
      if (error is _TmuxExecChannelCoolingDownException) {
        execCooldown = error.cooldownRemaining;
      } else if (shouldBackOffTmuxExecChannelAfterFailure(error)) {
        execCooldown = _execChannelCooldownRemaining(session);
      } else {
        execCooldown = null;
      }
      if (execCooldown != null) {
        _deferAgentSessionMetadataRefreshForExecCooldown(
          session,
          panePids,
          force: force,
          cooldown: execCooldown,
        );
      }
    }
  }

  void _deferAgentSessionMetadataRefreshForExecCooldown(
    SshSession session,
    Set<int> panePids, {
    required bool force,
    required Duration cooldown,
  }) {
    if (_isExecSessionClosed(session)) return;
    final connectionId = session.connectionId;
    DiagnosticsLogService.instance.debug(
      'tmux.agent',
      'active_session_metadata_deferred',
      fields: {
        'connectionId': connectionId,
        'paneCount': panePids.length,
        'forced': force,
        'delayMs': cooldown.inMilliseconds,
      },
    );
    _scheduleMetadataBatch(
      session,
      panePids,
      force: force,
      delay: cooldown,
      kind: _MetadataDelay.cooldown,
    );
  }

  Set<int> _agentPanePids(Iterable<TmuxWindow> windows) => windows
      .where(
        (window) =>
            window.foregroundAgentTool != null && window.panePid != null,
      )
      .map((window) => window.panePid!)
      .toSet();

  ({List<TmuxWindow> windows, bool changed})
  _applyAgentSessionMetadataToWindows(
    List<TmuxWindow> windows,
    Map<int, _ActiveAgentSessionMetadata> metadataByPanePid, {
    Set<int>? refreshedPanePids,
  }) {
    var changed = false;
    final enriched = windows
        .map((window) {
          final panePid = window.panePid;
          final foregroundAgentTool = window.foregroundAgentTool;
          if (panePid != null && foregroundAgentTool == null) {
            if (window.activeAgentSessionId != null ||
                window.agentSessionTitle != null ||
                window.activeAgentSessionConfidence != null) {
              changed = true;
              return window.copyWith(clearActiveAgentSessionMetadata: true);
            }
            return window;
          }
          final metadata = panePid == null ? null : metadataByPanePid[panePid];
          if (metadata != null &&
              foregroundAgentTool != null &&
              metadata.tool != foregroundAgentTool) {
            if (window.activeAgentSessionId != null ||
                window.agentSessionTitle != null ||
                window.activeAgentSessionConfidence != null) {
              changed = true;
              return window.copyWith(clearActiveAgentSessionMetadata: true);
            }
            return window;
          }
          if (metadata == null) {
            if (panePid != null &&
                refreshedPanePids != null &&
                refreshedPanePids.contains(panePid) &&
                (window.activeAgentSessionId != null ||
                    window.agentSessionTitle != null ||
                    window.activeAgentSessionConfidence != null)) {
              if (window.activeAgentSessionConfidence ==
                  AgentSessionConfidence.high) {
                return window;
              }
              changed = true;
              return window.copyWith(clearActiveAgentSessionMetadata: true);
            }
            return window;
          }
          if (window.activeAgentSessionId == metadata.sessionId &&
              window.agentSessionTitle == metadata.title &&
              window.activeAgentSessionConfidence == metadata.confidence) {
            return window;
          }
          changed = true;
          return window.copyWith(
            activeAgentSessionId: metadata.sessionId,
            agentSessionTitle: metadata.title,
            activeAgentSessionConfidence: metadata.confidence,
          );
        })
        .toList(growable: false);
    return (windows: changed ? enriched : windows, changed: changed);
  }

  void _applyActiveAgentSessionMetadataToCachedWindows(
    int connectionId,
    Map<int, _ActiveAgentSessionMetadata> metadataByPanePid, {
    Set<int>? refreshedPanePids,
  }) {
    final state = _stateFor(connectionId);
    if (metadataByPanePid.isEmpty &&
        (refreshedPanePids == null || refreshedPanePids.isEmpty)) {
      return;
    }
    for (final entry in state.windowSnapshotCache.entries.toList(
      growable: false,
    )) {
      final key = entry.key;
      final currentWindows = entry.value;
      final result = _applyAgentSessionMetadataToWindows(
        currentWindows,
        metadataByPanePid,
        refreshedPanePids: refreshedPanePids,
      );
      if (!result.changed) {
        continue;
      }
      final enrichedWindows = List<TmuxWindow>.unmodifiable(result.windows);
      state.windowSnapshotCache[key] = enrichedWindows;

      final observer = state.windowObservers[key];
      if (observer == null) {
        continue;
      }
      for (var i = 0; i < enrichedWindows.length; i++) {
        final currentWindow = i < currentWindows.length
            ? currentWindows[i]
            : null;
        final enrichedWindow = enrichedWindows[i];
        if (currentWindow == enrichedWindow) {
          continue;
        }
        observer._emitEvent(TmuxWindowSnapshotEvent(enrichedWindow));
      }
    }
  }

  /// Returns the active pane working directory for [sessionName], if tmux
  /// reports one.
  @override
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async => (await currentPaneContext(
    session,
    sessionName,
    priority: priority,
    extraFlags: extraFlags,
  ))?.currentPath;

  /// Returns active pane metadata for [sessionName], if tmux reports it.
  @override
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async {
    final cachedContext = _cachedCurrentPaneContext(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    if (cachedContext != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'current_pane_context_cached',
        fields: {'connectionId': session.connectionId},
      );
      return cachedContext;
    }
    final execCooldown = _execChannelCooldownRemaining(session);
    if (execCooldown != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'current_pane_context_deferred',
        fields: {
          'connectionId': session.connectionId,
          'remainingMs': execCooldown.inMilliseconds,
        },
      );
      return null;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_pane_context_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _execTmuxCommand(
        session,
        sessionName,
        'display-message -p -t ${shellEscapePosix('$sessionName:')} '
        '${shellEscapePosix('#{pane_current_path}$tmuxWindowFieldSeparator#{pane_current_command}')}',
        extraFlags: extraFlags,
        priority: priority,
      );
      final context = parseTmuxCurrentPaneContext(output);
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'current_pane_context_complete',
        fields: {
          'connectionId': session.connectionId,
          'hasPath': context?.currentPath != null,
          'hasCommand': context?.currentCommand != null,
        },
      );
      return context;
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'current_pane_context_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  TmuxPaneContext? _cachedCurrentPaneContext(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final state = _stateFor(session.connectionId);
    final windows =
        state.windowSnapshotCache[_TmuxWindowWatchKey(
          connectionId: session.connectionId,
          sessionName: sessionName,
          extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
        )];
    if (windows == null || windows.isEmpty) {
      return null;
    }
    final activeWindow = windows.where((window) => window.isActive).firstOrNull;
    final currentPath = activeWindow?.currentPath;
    if (currentPath == null) {
      return null;
    }
    return TmuxPaneContext(
      currentPath: currentPath,
      currentCommand: activeWindow?.currentCommand,
    );
  }

  /// Returns whether [sessionName] is attached in the primary SSH terminal.
  ///
  /// Control-mode observers are excluded by the foreground-session probe
  /// because MonkeySSH uses one for live window updates even after the visible
  /// interactive shell has left tmux.
  Future<bool> hasForegroundClient(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    try {
      return await hasForegroundClientOrThrow(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'foreground_client_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Returns whether [sessionName] is attached in the primary SSH terminal, and
  /// throws when the remote check could not complete.
  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'foreground_client_start',
      fields: {'connectionId': session.connectionId},
    );
    final foregroundSessionName = await _foregroundSessionNameOrThrow(
      session,
      priority: SshExecPriority.normal,
      extraFlags: extraFlags,
    );
    final hasClient = foregroundSessionName == sessionName;
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'foreground_client_complete',
      fields: {
        'connectionId': session.connectionId,
        'hasForegroundClient': hasClient,
        'hasForegroundSession': foregroundSessionName != null,
      },
    );
    return hasClient;
  }

  /// Asks every foreground client attached to [sessionName] to redraw.
  Future<void> refreshForegroundClients(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final state = _stateFor(session.connectionId);
    DiagnosticsLogService.instance.debug(
      'tmux.action',
      'refresh_clients_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final usedControl = await _refreshForegroundClientsViaControl(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
      _requireState(session.connectionId, state);
      if (!usedControl) {
        await _exec(
          session,
          buildTmuxRefreshForegroundClientsCommand(
            sessionName,
            extraFlags: extraFlags,
          ),
        );
      }
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'refresh_clients_complete',
        fields: {
          'connectionId': session.connectionId,
          'usedControl': usedControl,
        },
      );
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.action',
        'refresh_clients_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  Future<bool> _refreshForegroundClientsViaControl(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final listOutput = await _tryControlCommand(
      session,
      sessionName,
      'list-clients -t ${shellEscapePosix(sessionName)} -F '
      '${shellEscapePosix('#{client_control_mode}$tmuxWindowFieldSeparator#{client_name}')}',
      extraFlags: extraFlags,
    );
    if (listOutput == null) {
      return false;
    }
    final clientNames = parseForegroundClientNamesForRefresh(listOutput);
    for (final clientName in clientNames) {
      final refreshOutput = await _tryControlCommand(
        session,
        sessionName,
        'refresh-client -t ${shellEscapePosix(clientName)}',
        extraFlags: extraFlags,
      );
      if (refreshOutput == null) {
        return false;
      }
    }
    return true;
  }

  /// Updates tmux's pane palette for [sessionName] and redraws foreground
  /// clients.
  ///
  /// [forceForegroundRedraw] is a no-op because classic tmux already redraws
  /// foreground clients via `refresh-client`.
  @override
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
    bool forceForegroundRedraw = false,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.action',
      'refresh_theme_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        buildTmuxRefreshTerminalThemeCommand(
          sessionName,
          theme,
          extraFlags: extraFlags,
        ),
      );
      final stats = _parseTmuxThemeRefreshStats(output);
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'refresh_theme_complete',
        fields: {
          'connectionId': session.connectionId,
          if (stats != null) ...{
            'paneCount': stats.paneCount,
            'activePaneCount': stats.activePaneCount,
            'alternatePaneCount': stats.alternatePaneCount,
            'injectedPaneCount': stats.injectedPaneCount,
          },
        },
      );
    } on Object catch (error) {
      if (!_isExpectedTmuxOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'tmux.action',
        'refresh_theme_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  /// Watches tmux control-mode notifications that indicate window state
  /// has changed for [sessionName].
  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final state = _stateFor(session.connectionId);
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    var observer = state.windowObservers[key];
    if (observer == null || observer._disposed) {
      late final _TmuxWindowChangeObserver replacement;
      replacement = _TmuxWindowChangeObserver(
        service: this,
        session: session,
        sessionName: sessionName,
        extraFlags: extraFlags,
        onDispose: () {
          if (!_ownsState(session.connectionId, state) ||
              !identical(state.windowObservers[key], replacement)) {
            return;
          }
          state.windowObservers.remove(key);
          if (!_hasWindowObserverForConnection(session.connectionId)) {
            _cancelAgentSessionMetadataPeriodicRefresh(session.connectionId);
          }
        },
      );
      state.windowObservers[key] = observer = replacement;
    }
    final cachedWindows = state.windowSnapshotCache[key];
    if (cachedWindows != null) {
      _scheduleAgentSessionMetadataRefresh(session, cachedWindows);
    }
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'watch_requested',
      fields: {
        'connectionId': session.connectionId,
        'observerCount': state.windowObservers.length,
      },
    );
    return observer.stream;
  }

  // ── Window mutations ───────────────────────────────────────────────────

  /// Creates a new window in [sessionName], optionally running [command],
  /// setting a window [name], and/or starting in [workingDirectory].
  @override
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  }) async {
    final state = _stateFor(session.connectionId);
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'create_window_start',
      fields: {
        'connectionId': session.connectionId,
        'hasCommand': command?.trim().isNotEmpty ?? false,
        'hasName': name?.trim().isNotEmpty ?? false,
        'hasWorkingDirectory': workingDirectory?.trim().isNotEmpty ?? false,
      },
    );
    // Don't pass -c unless an explicit workingDirectory was provided
    // (e.g. resuming an AI session in a specific project). Without -c,
    // tmux uses the session's default-directory — matching Ctrl+b,c.
    final parts = <String>[
      "new-window -P -F '#{window_index}' -t ${shellEscapePosix(sessionName)}",
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        '-c ${shellEscapePosix(workingDirectory.trim())}',
      if (name != null && name.trim().isNotEmpty)
        '-n ${shellEscapePosix(name.trim())}',
    ];
    final createdWindowIndex = _parseCreatedWindowIndex(
      await _execTmuxCommand(
        session,
        sessionName,
        parts.join(' '),
        extraFlags: extraFlags,
      ),
    );
    _requireState(session.connectionId, state);
    final target = createdWindowIndex == null
        ? sessionName
        : '$sessionName:$createdWindowIndex';
    final agentTool = _agentToolForCreatedWindow(command: command, name: name);
    if (agentTool != null) {
      final agentSessionId = agentSessionIdFromLaunchCommand(
        command,
        tool: agentTool,
      );
      final optionCommands = <String>[
        'set-option -w -t ${shellEscapePosix(target)} @flutty_agent_tool ${shellEscapePosix(agentTool.commandName)}',
        if (agentSessionId != null)
          'set-option -w -t ${shellEscapePosix(target)} @flutty_agent_session_id ${shellEscapePosix(agentSessionId)}',
        if (agentSessionId != null)
          'set-option -w -t ${shellEscapePosix(target)} @flutty_agent_session_confidence ${shellEscapePosix(AgentSessionConfidence.high.name)}',
        if (agentSessionId != null)
          'set-option -w -t ${shellEscapePosix(target)} @flutty_agent_session_updated_at ${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      ];
      await _execTmuxCommand(
        session,
        sessionName,
        optionCommands.join(r' \; '),
        extraFlags: extraFlags,
      );
      _requireState(session.connectionId, state);
    }
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'create_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'hasAgentTool': agentTool != null,
      },
    );

    // If a command was requested, type it into the new window's shell.
    // This ensures the command runs inside the login shell environment
    // where CLI tools installed via Homebrew/nvm/etc. are available.
    if (command != null && command.trim().isNotEmpty) {
      _execTmuxCommandFireAndForget(
        session,
        sessionName,
        'send-keys -t ${shellEscapePosix(target)} '
        '${shellEscapePosix(command.trim())} Enter',
        extraFlags: extraFlags,
      );
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'create_window_command_sent',
        fields: {'connectionId': session.connectionId},
      );
    }
  }

  /// Switches to window [windowIndex] in [sessionName] via exec channel.
  ///
  /// This is a tmux server operation — the server notifies all attached
  /// clients of the change, so it works correctly regardless of which
  /// channel sends the command.
  ///
  /// Waits for tmux to process the selection before returning so callers can
  /// safely perform follow-up work (like reattaching the visible PTY) without
  /// racing the server-side window change.
  ///
  /// [clientImageSignatures] and [suppressReplay] are no-ops for classic tmux.
  @override
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
    bool suppressReplay = false,
  }) async {
    final targetWindowId = windowId?.trim();
    final safeWindowId =
        targetWindowId != null && isValidTmuxWindowId(targetWindowId)
        ? targetWindowId
        : null;
    final hasTargetWindowId = safeWindowId != null;
    final target = safeWindowId == null
        ? '${shellEscapePosix(sessionName)}:$windowIndex'
        : shellEscapePosix(safeWindowId);
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
        'hasWindowId': hasTargetWindowId,
      },
    );
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final state = _stateFor(session.connectionId);
    final activitySuppression = _beginWindowSwitchActivitySuppression(
      key,
      windowIndex: windowIndex,
      windowId: safeWindowId,
    );
    try {
      await _execTmuxCommand(
        session,
        sessionName,
        'select-window -t $target',
        extraFlags: extraFlags,
      );
      // Keep capturing while SSH opens or queues the command. Completion starts
      // the grace period without forgetting a snapshot received in flight.
      activitySuppression?.captureUntil = DateTime.now().add(
        _windowSwitchActivityGracePeriod,
      );
    } on Object {
      if (identical(
        state.windowSwitchActivitySuppressions[key],
        activitySuppression,
      )) {
        state.windowSwitchActivitySuppressions.remove(key);
      }
      rethrow;
    }
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
        'hasWindowId': hasTargetWindowId,
      },
    );
  }

  /// Closes a window in [sessionName] via exec channel.
  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
  }) async {
    final targetWindowId = windowId?.trim();
    final target = targetWindowId != null && isValidTmuxWindowId(targetWindowId)
        ? shellEscapePosix(targetWindowId)
        : '${shellEscapePosix(sessionName)}:$windowIndex';
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'kill_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
    await _execTmuxCommand(
      session,
      sessionName,
      'kill-window -t $target',
      extraFlags: extraFlags,
    );
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'kill_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  bool _isExecSessionClosed(SshSession session) =>
      (_deadExecSessions[session] ?? false) || session.client.isClosed;

  Duration? _execChannelCooldownRemaining(SshSession session) {
    final state = _connectionStates[session.connectionId];
    final backoff = state?.execChannelBackoff;
    if (backoff == null) return null;
    final remaining = backoff.cooldownUntil.difference(
      _execChannelNow?.call() ?? DateTime.now(),
    );
    if (remaining > Duration.zero) {
      return remaining;
    }
    // Keep the failure count until an open succeeds. Expiry permits a probe;
    // it does not mean the server has recovered.
    return null;
  }

  bool _isExecChannelCoolingDown(SshSession session) =>
      _execChannelCooldownRemaining(session) != null;

  /// Returns whether optional SSH exec-channel work should be deferred.
  @override
  bool isExecChannelCoolingDown(SshSession session) =>
      _isExecSessionClosed(session) || _isExecChannelCoolingDown(session);

  void _recordExecChannelFailure(int connectionId, Object error) {
    final state = _stateFor(connectionId);
    final failureCount = (state.execChannelBackoff?.failureCount ?? 0) + 1;
    final delay = resolveTmuxExecChannelBackoffDelay(failureCount);
    state.execChannelBackoff = _TmuxExecChannelBackoff(
      failureCount: failureCount,
      cooldownUntil: (_execChannelNow?.call() ?? DateTime.now()).add(delay),
    );
    DiagnosticsLogService.instance.warning(
      'tmux.exec',
      'channel_backoff',
      fields: {
        'connectionId': connectionId,
        'failureCount': failureCount,
        'delayMs': delay.inMilliseconds,
        'errorType': error.runtimeType,
      },
    );
  }

  void _clearExecChannelBackoff(int connectionId) {
    final state = _stateFor(connectionId);
    if (state.execChannelBackoff != null) {
      state.execChannelBackoff = null;
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'channel_backoff_cleared',
        fields: {'connectionId': connectionId},
      );
    }
  }

  _TmuxWindowSwitchActivitySuppression? _beginWindowSwitchActivitySuppression(
    _TmuxWindowWatchKey key, {
    required int windowIndex,
    required String? windowId,
  }) {
    final state = _connectionStates[key.connectionId];
    if (state == null) return null;
    final windows = state.windowSnapshotCache[key];
    final targetWindow = windows
        ?.where(
          (window) => windowId != null
              ? window.id == windowId
              : window.index == windowIndex,
        )
        .firstOrNull;
    if (targetWindow == null) {
      state.windowSwitchActivitySuppressions.remove(key);
      return null;
    }
    final suppression = _TmuxWindowSwitchActivitySuppression(
      windowIndex: windowIndex,
      windowId: windowId,
      baselineActivityEpochSeconds: targetWindow.lastActivityEpochSeconds,
    );
    state.windowSwitchActivitySuppressions[key] = suppression;
    return suppression;
  }

  List<TmuxWindow> _suppressWindowSwitchRedrawActivity(
    _TmuxWindowWatchKey key,
    List<TmuxWindow> windows,
  ) {
    final suppression = _connectionStates[key.connectionId]
        ?.windowSwitchActivitySuppressions[key];
    if (suppression == null) return windows;
    final captureUntil = suppression.captureUntil;
    final captureSyntheticActivity =
        captureUntil == null || !DateTime.now().isAfter(captureUntil);
    return windows
        .map(
          (window) => suppression.preserveBaselineForSyntheticRedraw(
            window,
            captureSyntheticActivity: captureSyntheticActivity,
          ),
        )
        .toList(growable: false);
  }

  TmuxWindowSnapshotEvent _suppressWindowSwitchRedrawActivityEvent(
    _TmuxWindowWatchKey key,
    TmuxWindowSnapshotEvent event,
  ) => TmuxWindowSnapshotEvent(
    _suppressWindowSwitchRedrawActivity(key, [event.window]).single,
  );

  void _applyCachedWindowSnapshot(
    SshSession session,
    String sessionName,
    TmuxWindowSnapshotEvent event, {
    String? extraFlags,
  }) {
    final state = _stateFor(session.connectionId);
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final cachedWindows = state.windowSnapshotCache[key];
    final forceAgentMetadataRefresh =
        shouldForceAgentSessionMetadataRefreshForSnapshot(
          cachedWindows ?? const <TmuxWindow>[],
          event.window,
        );
    if (cachedWindows != null && cachedWindows.isNotEmpty) {
      final updatedWindows = applyTmuxWindowChangeEvent(cachedWindows, event);
      state.windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(
        _enrichWindowsWithCachedAgentSessionMetadata(
          session.connectionId,
          updatedWindows,
        ),
      );
    }
    _scheduleAgentSessionMetadataRefresh(session, [
      event.window,
    ], force: forceAgentMetadataRefresh);
  }

  /// Returns the profile source prefix for this session's login shell.
  ///
  /// Only sources the profile file appropriate for the user's shell:
  /// - zsh: `~/.zprofile`
  /// - bash: `~/.bash_profile` (falls back to `~/.profile`)
  /// - sh/other: `~/.profile`
  String _profilePrefix(int connectionId) {
    final cached = _connectionStates[connectionId]?.profileSource;
    if (cached != null) return cached;
    // Fallback — source all common profiles until shell is detected.
    // Redirect stdout to avoid profile greeting/MOTD output corrupting
    // our parsed command results.
    return '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } '
        '>/dev/null 2>&1; ';
  }

  /// Wraps [command] with profile sourcing or cached path substitution.
  String _wrapCommand(SshSession session, String command) {
    final utf8Command = _forceUtf8TmuxCommand(command);
    final cachedPath = _connectionStates[session.connectionId]?.tmuxPath;
    final prefixedCommand = cachedPath != null
        ? utf8Command.replaceFirst('tmux -u ', '$cachedPath -u ')
        : utf8Command;
    // Sourcing the login-shell profile can be slow (hundreds of ms when a
    // user's ~/.zprofile is heavy), and a single window switch issues several
    // exec commands. Once the tmux binary path is cached we only need the
    // profile for subcommands that spawn a shell/process and therefore want the
    // login PATH; pure server queries/controls (list-clients, select-window,
    // display-message, ...) run correctly with just the cached path and the
    // explicit locale below, so skip the profile for them to keep switches snappy.
    final needsProfile =
        cachedPath == null || tmuxCommandNeedsLoginProfile(utf8Command);
    final profilePrefix = needsProfile
        ? _profilePrefix(session.connectionId)
        : '';
    return '$profilePrefix'
        'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; '
        '$prefixedCommand';
  }

  String _forceUtf8TmuxCommand(String command) {
    final trimmed = command.trimLeft();
    if (!trimmed.startsWith('tmux ')) return command;
    if (trimmed == 'tmux -u' || trimmed.startsWith('tmux -u ')) {
      return command;
    }
    return command.replaceFirst('tmux ', 'tmux -u ');
  }

  /// Opens an SSH exec channel with a bounded wait for channel creation.
  Future<SSHSession> _openExec(
    SshSession session,
    String command, {
    SSHPtyConfig? pty,
    Future<void> Function(SSHSession)? closeStaleSession,
  }) async {
    if (_isExecSessionClosed(session)) {
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'open_skipped_closed',
        fields: {'connectionId': session.connectionId},
      );
      // dartssh2 errors do not implement Exception or Error.
      // ignore: only_throw_errors
      throw SSHStateError('SSH session is closed');
    }
    final state = _stateFor(session.connectionId);
    final execCooldown = _execChannelCooldownRemaining(session);
    if (execCooldown != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'open_deferred_during_backoff',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': _diagnosticTmuxCommandKind(command),
          'remainingMs': execCooldown.inMilliseconds,
          'pty': pty != null,
        },
      );
      throw _TmuxExecChannelCoolingDownException(execCooldown);
    }
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'open_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': _diagnosticTmuxCommandKind(command),
        'pty': pty != null,
      },
    );
    try {
      final exec = await openSshExec(
        session.execute(command, pty: pty),
        _execOpenTimeout,
        onLateError: (error, _) => _recordLateExecOpenFailure(session, error),
      );
      if (!_ownsState(session.connectionId, state)) {
        if (closeStaleSession != null) {
          await closeStaleSession(exec);
        } else {
          exec.close();
        }
        _requireState(session.connectionId, state);
      }
      _clearExecChannelBackoff(session.connectionId);
      return exec;
    } on Object catch (error) {
      if (error is SSHStateError) {
        _deadExecSessions[session] = true;
      }
      if (error is TimeoutException) {
        DiagnosticsLogService.instance.warning(
          'tmux.exec',
          'open_timeout',
          fields: {
            'connectionId': session.connectionId,
            'commandKind': _diagnosticTmuxCommandKind(command),
            'timeoutMs': _execOpenTimeout.inMilliseconds,
            'pty': pty != null,
          },
        );
      }
      if (_ownsState(session.connectionId, state) &&
          shouldBackOffTmuxExecChannelAfterFailure(error)) {
        _recordExecChannelFailure(session.connectionId, error);
      }
      rethrow;
    }
  }

  void _recordLateExecOpenFailure(SshSession session, Object error) {
    if (error is SSHStateError) {
      _deadExecSessions[session] = true;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'late_open_failed',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
  }

  /// Runs a command via SSH exec channel and returns stdout as a string.
  ///
  /// Uses the cached tmux binary path when available; otherwise sources
  /// the user's login shell profile to resolve the PATH.
  ///
  /// Appends a marker to the remote command and reads stdout only until that
  /// marker arrives. Some SSH servers leave exec streams open after the
  /// command exits, so waiting for stream completion can turn successful tmux
  /// actions into apparent hangs.
  Future<String> _exec(
    SshSession session,
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) {
    final state = _stateFor(session.connectionId);
    return session.runQueuedExec(() async {
      _requireState(session.connectionId, state);
      final quietUntil = state.execQuietUntil;
      if (quietUntil != null) {
        final delay = quietUntil.difference(DateTime.now());
        if (delay > Duration.zero) {
          DiagnosticsLogService.instance.debug(
            'tmux.exec',
            'deferred_for_redraw',
            fields: {
              'connectionId': session.connectionId,
              'commandKind': _diagnosticTmuxCommandKind(command),
              'delayMs': delay.inMilliseconds,
            },
          );
          await Future<void>.delayed(delay);
        }
        if (state.execQuietUntil == quietUntil) {
          state.execQuietUntil = null;
        }
      }
      _requireState(session.connectionId, state);
      return _execUnqueued(session, command);
    }, priority: priority);
  }

  Future<String> _execWindowsPowerShell(
    SshSession session,
    String script, {
    SshExecPriority priority = SshExecPriority.normal,
  }) {
    final state = _stateFor(session.connectionId);
    return session.runQueuedExec(() async {
      _requireState(session.connectionId, state);
      final execSession = await _openExec(
        session,
        buildWindowsPowerShellCommand(script),
      );
      try {
        execSession.stderr.drain<void>().ignore();
        return await _readStdoutUntilClose(
          execSession,
          connectionId: session.connectionId,
          commandKind: 'tool_detection',
        );
      } finally {
        execSession.close();
      }
    }, priority: priority);
  }

  Future<String> _execTmuxCommand(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
    bool forceUtf8 = false,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final state = _stateFor(session.connectionId);
    final controlOutput = await _tryControlCommand(
      session,
      sessionName,
      tmuxCommand,
      extraFlags: extraFlags,
    );
    if (controlOutput != null) {
      return controlOutput;
    }
    _requireState(session.connectionId, state);
    return _exec(
      session,
      _tmuxCommand(tmuxCommand, extraFlags: extraFlags, forceUtf8: forceUtf8),
      priority: priority,
    );
  }

  Future<String?> _tryControlCommand(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
  }) async {
    final observer = _controlCommandObserver(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    if (observer == null) {
      return null;
    }
    try {
      return await observer.runCommand(
        tmuxCommand,
        commandKind: _diagnosticTmuxCommandKind(tmuxCommand),
        timeout: _execOutputTimeout,
      );
    } on _TmuxControlCommandUnavailable {
      return null;
    }
  }

  _TmuxWindowChangeObserver? _controlCommandObserver(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) =>
      _connectionStates[session.connectionId]
          ?.windowObservers[_TmuxWindowWatchKey(
        connectionId: session.connectionId,
        sessionName: sessionName,
        extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
      )];

  Future<String> _execUnqueued(SshSession session, String command) async {
    final startedAt = DateTime.now();
    final wrappedCommand = _wrapCommand(session, command);
    final execSession = await _openExec(
      session,
      _markCommandDone(wrappedCommand),
    );
    try {
      execSession.stderr.drain<void>().ignore();
      final output = await _readStdoutUntilDoneMarker(
        execSession,
        connectionId: session.connectionId,
        commandKind: _diagnosticTmuxCommandKind(command),
      );
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'complete',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': _diagnosticTmuxCommandKind(command),
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'outputChars': output.length,
        },
      );
      return output;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.exec',
        'failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': _diagnosticTmuxCommandKind(command),
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'errorType': error.runtimeType,
        },
      );
      rethrow;
    } finally {
      execSession.close();
    }
  }

  String _markCommandDone(String command) =>
      '{ $command; __flutty_tmux_exec_status__=\$?; '
      'printf ${shellEscapePosix('\n$_execDoneMarker:%s\n')} '
      r'"$__flutty_tmux_exec_status__"; }';

  Future<String> _readStdoutUntilDoneMarker(
    SSHSession execSession, {
    required int connectionId,
    required String commandKind,
  }) async {
    ({String output, int? status}) result;
    try {
      result = await readCommandOutputUntilMarker(
        execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .timeout(_execOutputTimeout),
        _execDoneMarker,
        // Observe chunks without wrapping stdout in another stream whose
        // cancellation can delay EOF and keep the queued exec slot occupied.
        onChunk: (chunk) {
          DiagnosticsLogService.instance.debug(
            'tmux.exec',
            'stdout_chunk',
            fields: {
              'connectionId': connectionId,
              'commandKind': commandKind,
              'charCount': chunk.length,
            },
          );
        },
      );
    } on CommandOutputMarkerMissingException {
      result = (output: '', status: null);
    }
    final status = result.status;
    if (status == 0) return result.output.trimRight();
    DiagnosticsLogService.instance.warning(
      'tmux.exec',
      status == null ? 'closed_before_marker' : 'nonzero_status',
      fields: {
        'connectionId': connectionId,
        'commandKind': commandKind,
        'exitStatus': ?status,
      },
    );
    throw TmuxCommandException(
      status == null
          ? 'SSH exec channel closed before tmux command completed'
          : 'tmux command failed with exit status $status',
    );
  }

  Future<String> _readStdoutUntilClose(
    SSHSession execSession, {
    required int connectionId,
    required String commandKind,
  }) async {
    final output = StringBuffer();
    try {
      await for (final chunk
          in execSession.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .timeout(_execOutputTimeout)) {
        DiagnosticsLogService.instance.debug(
          'tmux.exec',
          'stdout_chunk',
          fields: {
            'connectionId': connectionId,
            'commandKind': commandKind,
            'charCount': chunk.length,
          },
        );
        output.write(chunk);
      }
    } on TimeoutException {
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'stdout_timeout_partial',
        fields: {
          'connectionId': connectionId,
          'commandKind': commandKind,
          'outputChars': output.length,
        },
      );
      return output.toString();
    }
    return output.toString();
  }

  /// Fire-and-forget: sends a tmux command without waiting for output.
  ///
  /// Used for follow-up operations where completion does not need to block the
  /// caller, but still closes the exec channel once the command marker returns.
  void _execTmuxCommandFireAndForget(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
  }) {
    final commandKind = _diagnosticTmuxCommandKind(tmuxCommand);
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'fire_and_forget_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': commandKind,
      },
    );
    final commandFuture = _execTmuxCommand(
      session,
      sessionName,
      tmuxCommand,
      extraFlags: extraFlags,
    );
    commandFuture.catchError((Object error) {
      DiagnosticsLogService.instance.warning(
        'tmux.exec',
        'fire_and_forget_failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': commandKind,
          'errorType': error.runtimeType,
        },
      );
      return '';
    }).ignore();
  }

  /// Detects the user's login shell and resolves the tmux binary path.
  ///
  /// Caches both the shell-specific profile source command and the
  /// full tmux path for subsequent calls.
  Future<void> _cacheTmuxPath(SshSession session) async {
    final state = _stateFor(session.connectionId);
    if (state.tmuxPath != null) return;
    final existingRequest = state.tmuxPathRequest;
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.cache',
        'tmux_path_join',
        fields: {'connectionId': session.connectionId},
      );
      try {
        await existingRequest;
      } on Object {
        // The owner logs probe failures; joiners keep the same fallback path.
      }
      return;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.cache',
      'tmux_path_start',
      fields: {'connectionId': session.connectionId},
    );
    final request = () async {
      // Detect login shell and resolve tmux path in a single exec.
      // Redirect stdout from profile scripts to /dev/null so greetings,
      // MOTD, or fortune output don't corrupt our parsed output.
      final output = await _exec(
        session,
        r'SHELL_NAME=$(basename "$SHELL" 2>/dev/null || echo sh); '
        r'case "$SHELL_NAME" in '
        'zsh) { . ~/.zprofile; } >/dev/null 2>&1;; '
        'bash) { . ~/.bash_profile; . ~/.profile; } >/dev/null 2>&1;; '
        '*) { . ~/.profile; } >/dev/null 2>&1;; '
        'esac; '
        r'echo "$SHELL_NAME"; '
        'command -v tmux',
        priority: SshExecPriority.low,
      );
      if (!_ownsState(session.connectionId, state)) return;
      final lines = output.trim().split('\n');
      if (lines.isNotEmpty) {
        final shellName = lines[0].trim();
        state.profileSource = switch (shellName) {
          'zsh' => '{ . ~/.zprofile; } >/dev/null 2>&1; ',
          'bash' => '{ . ~/.bash_profile; . ~/.profile; } >/dev/null 2>&1; ',
          _ => '{ . ~/.profile; } >/dev/null 2>&1; ',
        };
      }
      if (lines.length > 1) {
        final path = lines[1].trim();
        if (path.isNotEmpty && path.startsWith('/')) {
          state.tmuxPath = path;
        }
      }
      DiagnosticsLogService.instance.info(
        'tmux.cache',
        'tmux_path_complete',
        fields: {
          'connectionId': session.connectionId,
          'hasPath': (state.tmuxPath != null),
          'hasProfile': (state.profileSource != null),
        },
      );
    }();
    state.tmuxPathRequest = request;
    try {
      await request;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.cache',
        'tmux_path_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      // Ignore — we'll fall back to sourcing all profiles.
    } finally {
      if (identical(state.tmuxPathRequest, request)) {
        state.tmuxPathRequest?.ignore();
        state.tmuxPathRequest = null;
      }
    }
  }

  /// Parses non-empty lines from [output] using [parser].
  List<T> _parseLines<T>(String output, T Function(String) parser) {
    final lines = output.trim().split('\n');
    final results = <T>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        results.add(parser(line));
      } on FormatException {
        // Skip malformed lines.
      }
    }
    return results;
  }
}

int? _parseCreatedWindowIndex(String output) {
  for (final rawLine in output.split('\n')) {
    final index = int.tryParse(rawLine.trim());
    if (index != null) return index;
  }
  return null;
}

AgentLaunchTool? _agentToolForCreatedWindow({
  required String? command,
  required String? name,
}) =>
    agentLaunchToolForCommandName(name) ??
    agentLaunchToolForCommandText(command);

enum _MetadataDelay { debounce, cooldown }

typedef _MetadataBatch = ({SshSession session, Set<int> panePids, bool force});

_MetadataBatch _mergeMetadataBatch(
  _MetadataBatch? previous,
  SshSession session,
  Set<int> panePids,
  bool force,
) => (
  session: session,
  panePids: {...?previous?.panePids, ...panePids},
  force: (previous?.force ?? false) || force,
);

class _TmuxConnectionState {
  final metadataBatches = <_MetadataDelay, _MetadataBatch>{};
  final metadataTimers = <_MetadataDelay, Timer>{};
  _MetadataBatch? metadataPending;
  String? tmuxPath;
  String? profileSource;
  Future<void>? tmuxPathRequest;
  DateTime? execQuietUntil;
  final hasSessionRequests = <_TmuxWindowWatchKey, Future<bool>>{};
  _CachedInstalledAgentTools? installedAgentTools;
  Future<Set<AgentLaunchTool>>? installedAgentToolsRequest;
  final windowObservers = <_TmuxWindowWatchKey, _TmuxWindowChangeObserver>{};
  final windowListRequests = <_TmuxWindowWatchKey, Future<List<TmuxWindow>>>{};
  final windowSnapshotCache = <_TmuxWindowWatchKey, List<TmuxWindow>>{};
  final windowSwitchActivitySuppressions =
      <_TmuxWindowWatchKey, _TmuxWindowSwitchActivitySuppression>{};
  Map<int, _ActiveAgentSessionMetadata>? metadataCache;
  Future<void>? metadataRequest;
  Set<int>? metadataRequestPanePids;
  Timer? metadataPeriodicTimer;
  SshSession? metadataPeriodicSession;
  DateTime? metadataRefreshedAt;
  _TmuxExecChannelBackoff? execChannelBackoff;

  Future<void> dispose() async {
    tmuxPathRequest?.ignore();
    installedAgentToolsRequest?.ignore();
    metadataRequest?.ignore();
    for (final timer in metadataTimers.values) {
      timer.cancel();
    }
    metadataPeriodicTimer?.cancel();
    await Future.wait(
      windowObservers.values.map((observer) => observer.dispose()),
    );
  }
}

class _CachedInstalledAgentTools {
  const _CachedInstalledAgentTools({
    required this.tools,
    required this.cachedAt,
  });

  final Set<AgentLaunchTool> tools;
  final DateTime cachedAt;
}

class _TmuxExecChannelBackoff {
  const _TmuxExecChannelBackoff({
    required this.failureCount,
    required this.cooldownUntil,
  });

  final int failureCount;
  final DateTime cooldownUntil;
}

/// Returns whether a failed tmux exec open should create or extend backoff.
@visibleForTesting
bool shouldBackOffTmuxExecChannelAfterFailure(Object error) =>
    error is SSHChannelOpenError || error is TimeoutException;

/// tmux read/control subcommands that need nothing beyond the cached tmux
/// binary and an explicit locale, so they can skip sourcing the login profile
/// once the path is cached.
const _profileFreeTmuxSubcommands = <String>{
  'list-clients',
  'list-windows',
  'list-sessions',
  'list-panes',
  'select-window',
  'select-pane',
  'display-message',
  'has-session',
  'refresh-client',
  'show-options',
  'show-option',
  'set-option',
  'kill-window',
  'kill-session',
  'kill-pane',
  'rename-window',
  'capture-pane',
};

/// Whether a tmux exec [command] needs the login-shell profile sourced.
///
/// Sourcing the profile (e.g. `~/.zprofile`) can cost hundreds of milliseconds,
/// so once the tmux binary path is cached we skip it — but only for a single,
/// simple tmux read/control invocation that needs nothing beyond the cached
/// binary and the explicit locale. Anything else keeps the profile because it
/// may rely on the login PATH:
///  - agent-tool detection runs `"$SHELL" -ic '... command -v <cli> ...'`; the
///    interactive shell sources `~/.zshrc` but not `~/.zprofile`, where Homebrew
///    typically puts the PATH the CLIs live on, so the outer profile is required;
///  - the foreground-client check and theme client-report use `$(...)` shell
///    substitution and external tools;
///  - window-spawning subcommands (new-window, run-shell, ...) want the login
///    PATH for the process they start.
@visibleForTesting
bool tmuxCommandNeedsLoginProfile(String command) {
  final match = RegExp(
    r'^(?:\S*/)?tmux(?:\s+-u)?\s+([a-z][a-z-]*)',
  ).firstMatch(command.trimLeft());
  if (match == null) {
    return true;
  }
  // Reject shell substitution / external-binary resolution that may need the
  // login PATH even when the leading token is tmux.
  if (command.contains(r'$(') ||
      command.contains('`') ||
      command.contains('command -v') ||
      command.contains('which ')) {
    return true;
  }
  return !_profileFreeTmuxSubcommands.contains(match.group(1));
}

/// Parses `list-clients` output for foreground (non-control) client names.
///
/// Each line is `${client_control_mode}<US>${client_name}`.
@visibleForTesting
List<String> parseForegroundClientNamesForRefresh(String output) {
  final clientNames = <String>[];
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final fields = line.split(tmuxWindowFieldSeparator);
    if (fields.length < 2 || fields[0] != '0') {
      continue;
    }
    final clientName = fields[1].trim();
    if (clientName.isNotEmpty) {
      clientNames.add(clientName);
    }
  }
  return clientNames;
}

// SSH errors are plain objects in dartssh2. Keep programming errors outside
// these operational fallbacks, including SSHInternalError.
bool _isExpectedTmuxOperationError(Object error) =>
    error is Exception ||
    error is SSHChannelOpenError ||
    error is SSHStateError;

bool _shouldTreatTmuxExecChannelAsUnavailable(Object error) =>
    shouldBackOffTmuxExecChannelAfterFailure(error) ||
    error is _TmuxExecChannelCoolingDownException;

/// Returns whether stale tmux windows are safer than failing a refresh.
@visibleForTesting
bool shouldUseCachedTmuxWindowsAfterListFailure(Object error) =>
    _shouldTreatTmuxExecChannelAsUnavailable(error);

/// Resolves the tmux exec channel cooldown after repeated open failures.
@visibleForTesting
Duration resolveTmuxExecChannelBackoffDelay(int failureCount) {
  final retryAttempt = failureCount <= 1 ? 0 : failureCount - 1;
  return resolveTmuxWindowReloadRetryDelay(retryAttempt);
}

/// Resolves how quickly the control-mode watcher should restart.
@visibleForTesting
Duration resolveTmuxControlRestartDelay(
  int restartAttempts, {
  required bool channelOpenFailure,
}) {
  if (channelOpenFailure) {
    return resolveTmuxWindowReloadRetryDelay(
      restartAttempts,
      initialDelay: const Duration(seconds: 5),
    );
  }
  final cappedAttempt = restartAttempts.clamp(0, 4);
  return Duration(seconds: 1 << cappedAttempt);
}

String _diagnosticTmuxCommandKind(String command) {
  if (command.contains('flutty_theme_refresh_pane')) {
    return 'refresh_theme';
  }
  if (command.contains('attach-session')) {
    return 'control_attach';
  }
  if (command.contains('refresh-client')) {
    return 'control_subscription';
  }
  if (command.contains('list-windows')) {
    return 'list_windows';
  }
  if (command.contains('list-sessions')) {
    return 'list_sessions';
  }
  if (command.contains('display-message')) {
    return 'display_message';
  }
  if (command.contains('has-session')) {
    return 'has_session';
  }
  if (command.contains('list-clients')) {
    return 'list_clients';
  }
  if (command.contains('.copilot/session-state')) {
    return 'active_session_metadata';
  }
  if (command.contains('select-window')) {
    return 'select_window';
  }
  if (command.contains('new-window')) {
    return 'new_window';
  }
  if (command.contains('kill-window')) {
    return 'kill_window';
  }
  if (command.contains('send-keys')) {
    return 'send_keys';
  }
  if (command.contains('command -v')) {
    return 'tool_detection';
  }
  if (command.contains('which tmux')) {
    return 'which_tmux';
  }
  return 'tmux_exec';
}

/// Parses a version returned by a tmux version probe.
@visibleForTesting
String? parseTmuxVersionOutput(String output) {
  for (final line in const LineSplitter().convert(output).reversed) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final match = RegExp(
      r'^tmux\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return match?.group(1)?.trim() ?? trimmed;
  }
  return null;
}

String _buildForegroundTmuxSessionCommand({String? extraFlags}) {
  final listClients = TmuxService._tmuxCommand(
    'list-clients -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  // BusyBox `ps` (Alpine and most busybox images) has no `-p`, which would make
  // the ancestry walk silently return "not attached" for our own tmux client.
  // `/proc/<pid>/status` is an equally exact PPID source, so the ownership
  // check stays strict rather than gaining a fuzzy fallback.
  return 'ppid_of() { __p=""; '
      r'if [ -r "/proc/$1/status" ]; then '
      r'__p=$(sed -n "s/^PPid:[[:space:]]*\([0-9][0-9]*\).*/\1/p" '
      r'"/proc/$1/status" 2>/dev/null); '
      'fi; '
      r'if [ -z "$__p" ]; then '
      r'__p=$(ps -p "$1" -o ppid= 2>/dev/null | tr -d " "); '
      'fi; '
      r'printf "%s" "$__p"; }; '
      r'sep=$(printf "\037"); '
      r'connection_pid=$(ppid_of "$$"); '
      r'if [ -n "$connection_pid" ]; then '
      '$listClients"#{client_pid}\$sep#{session_name}\$sep#{client_control_mode}" '
      '2>/dev/null | '
      r'while IFS="$sep" read -r client_pid session_name control_mode; do '
      r'[ "$control_mode" = 0 ] || continue; '
      r'[ -n "$client_pid" ] && [ -n "$session_name" ] || continue; '
      r'pid="$client_pid"; '
      r'while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do '
      r'if [ "$pid" = "$connection_pid" ]; then '
      r'printf "%s\n" "$session_name"; '
      'break 2; '
      'fi; '
      r'pid=$(ppid_of "$pid"); '
      'done; '
      'done; '
      'fi';
}

/// Parses current pane metadata reported by `tmux display-message`.
@visibleForTesting
TmuxPaneContext? parseTmuxCurrentPaneContext(String output) {
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isNotEmpty) {
      final fields = line.split(tmuxWindowFieldSeparator);
      final path = _nonEmptyTmuxPaneField(fields.first);
      final command = fields.length > 1
          ? _nonEmptyTmuxPaneField(fields[1])
          : null;
      if (path != null || command != null) {
        return TmuxPaneContext(currentPath: path, currentCommand: command);
      }
    }
  }
  return null;
}

String? _nonEmptyTmuxPaneField(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Parses pane process IDs emitted by `tmux list-panes`.
Set<int> parseTmuxPanePids(String output) => {
  for (final line in output.split('\n'))
    if (int.tryParse(line.trim()) case final panePid? when panePid > 0) panePid,
};

/// Builds a command that redraws all non-control tmux clients for a session.
@visibleForTesting
String buildTmuxRefreshForegroundClientsCommand(
  String sessionName, {
  String? extraFlags,
}) {
  const sep = r'${SEP}';
  final listClients = TmuxService._tmuxCommand(
    'list-clients -t ${shellEscapePosix(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final refreshClient = TmuxService._tmuxCommand(
    r'refresh-client -t "$client"',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return r'SEP=$(printf "\037"); '
      '$listClients"#{client_control_mode}$sep#{client_name}" '
      '2>/dev/null | '
      r'while IFS="$SEP" read -r control client; do '
      r'[ "$control" = 0 ] || continue; '
      r'[ -n "$client" ] || continue; '
      '$refreshClient 2>/dev/null || true; '
      'done';
}

/// Builds a command that updates tmux's pane palette, refreshes tmux's theme
/// report cache, nudges theme-aware TUI panes, and redraws foreground clients.
@visibleForTesting
String buildTmuxRefreshTerminalThemeCommand(
  String sessionName,
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  const sep = r'${SEP}';
  final listPanes = TmuxService._tmuxCommand(
    'list-panes -s -t ${shellEscapePosix(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final setPaneColours = _buildTmuxSetPaneColoursCommand(
    theme,
    extraFlags: extraFlags,
  );
  final loadThemeReportClients = _buildTmuxLoadThemeReportClientsCommand(
    sessionName,
    extraFlags: extraFlags,
  );
  final provideClientThemeReports = _buildTmuxProvideClientThemeReportsCommand(
    theme,
    extraFlags: extraFlags,
  );
  // Make sure tmux forwards focus events to inner panes — without this,
  // theme-aware TUIs like Codex/Copilot CLI never receive the FocusGained
  // signal we use as the trigger to re-query OSC 10/11 after a theme switch
  // and their cached default fg/bg stay stale (e.g. input composer "stuck
  // almost black"). Safe to re-apply on every refresh because the option is
  // global and idempotent.
  final enableFocusEvents = TmuxService._tmuxCommand(
    'set-option -g focus-events on',
    extraFlags: extraFlags,
    forceUtf8: true,
  );

  return r'SEP=$(printf "\037"); '
      '$enableFocusEvents 2>/dev/null || true; '
      '$loadThemeReportClients '
      'flutty_set_agent_tool_from_command_name() { '
      r'case "${1##*/}" in '
      'claude|claude-*) agent_tool=claude ;; '
      'copilot|copilot-*) agent_tool=copilot ;; '
      'codex|codex-*) agent_tool=codex ;; '
      'opencode|opencode-*) agent_tool=opencode ;; '
      'agy|agy-*|antigravity|antigravity-*) agent_tool=antigravity ;; '
      'esac; }; '
      'flutty_is_generic_runtime_command_name() { '
      r'case "${1##*/}" in '
      'node|nodejs|npm|npx|bun|deno|python|python3) return 0 ;; '
      '*) return 1 ;; '
      'esac; }; '
      'flutty_set_agent_tool_from_command_text() { '
      r'command_text=$1; '
      'while :; do '
      r'case "$command_text" in '
      r'cd\ *\&\&\ *) command_text=${command_text#*&& } ;; '
      r'[A-Za-z_]*=*\ *) command_text=${command_text#* } ;; '
      '*) break ;; '
      'esac; '
      'done; '
      r'first_token=${command_text%% *}; '
      r'flutty_set_agent_tool_from_command_name "$first_token"; '
      '}; '
      '$listPanes"#{pane_id}$sep#{pane_active}$sep#{alternate_on}$sep#{pane_current_command}$sep#{pane_start_command}" '
      '2>/dev/null | '
      r'{ while IFS="$SEP" read -r pane active alternate pane_command pane_start_command; do '
      r'[ -n "$pane" ] || continue; '
      '$setPaneColours '
      '$provideClientThemeReports '
      'agent_tool=; current_agent_tool=; injected=0; '
      r'flutty_set_agent_tool_from_command_name "$pane_command"; '
      r'current_agent_tool=$agent_tool; '
      r'if [ -z "$agent_tool" ] && flutty_is_generic_runtime_command_name "$pane_command"; then '
      r'flutty_set_agent_tool_from_command_text "$pane_start_command"; '
      r'current_agent_tool=$agent_tool; '
      'fi; '
      r'if [ -n "$current_agent_tool" ]; then '
      r'case "$agent_tool" in '
      'copilot|codex) '
      'injected=1; '
      '( ${_buildTmuxSendPaneFocusRefreshCommand(extraFlags: extraFlags)} '
      '2>/dev/null || true ) & ;; '
      'opencode|claude|antigravity) '
      'injected=1; '
      '( ${_buildTmuxSendPaneFocusTransitionCommand(extraFlags: extraFlags)} '
      '2>/dev/null || true ) & ;; '
      'esac; '
      'fi; '
      r'printf "flutty_theme_refresh_pane:%s,%s,%s\n" "$active" "$alternate" "$injected"; '
      'done; wait; }; '
      '${buildTmuxRefreshForegroundClientsCommand(sessionName, extraFlags: extraFlags)}';
}

class _TmuxThemeRefreshStats {
  const _TmuxThemeRefreshStats({
    required this.paneCount,
    required this.activePaneCount,
    required this.alternatePaneCount,
    required this.injectedPaneCount,
  });

  final int paneCount;
  final int activePaneCount;
  final int alternatePaneCount;
  final int injectedPaneCount;
}

_TmuxThemeRefreshStats? _parseTmuxThemeRefreshStats(String output) {
  var paneCount = 0;
  var activePaneCount = 0;
  var alternatePaneCount = 0;
  var injectedPaneCount = 0;
  for (final line in output.split('\n')) {
    if (!line.startsWith('flutty_theme_refresh_pane:')) {
      continue;
    }
    final fields = line
        .substring('flutty_theme_refresh_pane:'.length)
        .split(',');
    if (fields.length != 3) {
      continue;
    }
    paneCount += 1;
    if (fields[0] == '1') {
      activePaneCount += 1;
    }
    if (fields[1] == '1') {
      alternatePaneCount += 1;
    }
    if (fields[2] == '1') {
      injectedPaneCount += 1;
    }
  }
  if (paneCount == 0) {
    return null;
  }
  return _TmuxThemeRefreshStats(
    paneCount: paneCount,
    activePaneCount: activePaneCount,
    alternatePaneCount: alternatePaneCount,
    injectedPaneCount: injectedPaneCount,
  );
}

String _buildTmuxSetPaneColoursCommand(
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  final commands = <String>[
    for (var index = 0; index < 16; index += 1)
      _buildTmuxSetPaneColourSubcommand(index, theme),
  ];
  final command = TmuxService._tmuxCommand(
    commands.join(r' \; '),
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return '$command 2>/dev/null || true;';
}

String _buildTmuxSetPaneColourSubcommand(int index, TerminalThemeData theme) {
  final color = terminalThemePaletteColor(theme, index);
  if (color == null) {
    throw ArgumentError.value(index, 'index', 'Expected ANSI color index 0-15');
  }
  final hexColor = formatTerminalThemeRgbHex(color);
  final optionName = shellEscapePosix('pane-colours[$index]');
  return r'set-option -p -t "$pane" '
      '$optionName ${shellEscapePosix(hexColor)}';
}

String _buildTmuxLoadThemeReportClientsCommand(
  String sessionName, {
  String? extraFlags,
}) {
  const sep = r'${SEP}';
  final listClients = TmuxService._tmuxCommand(
    'list-clients -t ${shellEscapePosix(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return r'flutty_theme_report_clients=$( '
      '$listClients"#{client_control_mode}$sep#{client_name}" 2>/dev/null | '
      r'while IFS="$SEP" read -r control client; do '
      r'[ "$control" = 0 ] || continue; '
      r'[ -n "$client" ] || continue; '
      r'printf "%s\n" "$client"; '
      'done '
      ');';
}

String _buildTmuxProvideClientThemeReportsCommand(
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  final reports = [
    buildTerminalThemeModeReport(isDark: theme.isDark),
    buildTerminalThemeRefreshReports(theme),
  ].where((report) => report.isNotEmpty).toList(growable: false);
  if (reports.isEmpty) {
    return '';
  }

  final refreshReports = reports
      .map((report) {
        final reportCommand = TmuxService._tmuxCommand(
          '${r'refresh-client -t "$client" -r "$pane":'}'
          '${shellEscapePosix(report)}',
          extraFlags: extraFlags,
          forceUtf8: true,
        );
        return '$reportCommand 2>/dev/null || true;';
      })
      .join(' ');

  return r'printf "%s\n" "$flutty_theme_report_clients" | '
      'while IFS= read -r client; do '
      r'[ -n "$client" ] || continue; '
      '$refreshReports '
      'done;';
}

String _buildTmuxSendPaneFocusRefreshCommand({String? extraFlags}) =>
    _buildTmuxSendPaneFocusReportCommand('\x1b[I', extraFlags: extraFlags);

String _buildTmuxSendPaneFocusTransitionCommand({String? extraFlags}) =>
    '${_buildTmuxSendPaneFocusReportCommand('\x1b[O', extraFlags: extraFlags)} '
    '2>/dev/null || true; sleep 0.12; '
    '${_buildTmuxSendPaneFocusReportCommand('\x1b[I', extraFlags: extraFlags)}';

String _buildTmuxSendPaneFocusReportCommand(
  String report, {
  String? extraFlags,
}) => _buildTmuxSendPaneReportCommand(report, extraFlags: extraFlags);

String _buildTmuxSendPaneReportCommand(String report, {String? extraFlags}) =>
    TmuxService._tmuxCommand(
      r'send-keys -t "$pane" -H '
      '${_formatTmuxSendKeysHexArguments(report)}',
      extraFlags: extraFlags,
      forceUtf8: true,
    );

String _formatTmuxSendKeysHexArguments(String input) =>
    input.codeUnits.map(_formatTmuxSendKeysHexArgument).join(' ');

String _formatTmuxSendKeysHexArgument(int codeUnit) {
  if (codeUnit > 0x7F) {
    throw ArgumentError.value(
      codeUnit,
      'codeUnit',
      'Expected an ASCII terminal response byte',
    );
  }
  return codeUnit.toRadixString(16).padLeft(2, '0');
}

/// Extracts only tmux client/server flags that can be reused with commands
/// other than `new-session`.
@visibleForTesting
String? resolveTmuxClientFlagsFromExtraFlags(String? extraFlags) {
  final tokens = _tokenizeShellFragment(extraFlags);
  if (tokens == null || tokens.isEmpty) {
    return null;
  }

  final clientFlags = <String>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (_isTmuxCommandSeparatorToken(token)) {
      break;
    }
    if (!_isReusableTmuxClientFlag(token)) {
      continue;
    }
    if (token.length > 2) {
      clientFlags.add(_buildReusableTmuxClientFlag(token));
      continue;
    }
    if (index + 1 >= tokens.length ||
        _isTmuxCommandSeparatorToken(tokens[index + 1])) {
      continue;
    }
    clientFlags.add(
      '$token ${_shellQuoteReusableTmuxClientFlagValue(tokens[index + 1])}',
    );
    index++;
  }

  return clientFlags.isEmpty ? null : clientFlags.join(' ');
}

String _buildReusableTmuxClientFlag(String tokenValue) {
  final flag = tokenValue.substring(0, 2);
  final value = tokenValue.substring(2);
  return '$flag ${_shellQuoteReusableTmuxClientFlagValue(value)}';
}

String _shellQuoteReusableTmuxClientFlagValue(String value) {
  if (value == '~') {
    return r'"$HOME"';
  }
  if (value.startsWith('~/')) {
    return r'"$HOME"' + shellEscapePosix(value.substring(1));
  }
  return shellEscapePosix(value);
}

List<String>? _tokenizeShellFragment(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (normalized.contains('\n') || normalized.contains('\r')) {
    return null;
  }

  final tokens = <String>[];
  var currentToken = StringBuffer();
  var tokenStarted = false;
  var quoteMode = _ShellQuoteMode.none;

  void commitToken() {
    if (!tokenStarted) return;
    tokens.add(currentToken.toString());
    currentToken = StringBuffer();
    tokenStarted = false;
  }

  for (var index = 0; index < normalized.length; index++) {
    final character = normalized[index];

    if (quoteMode == _ShellQuoteMode.single) {
      if (character == "'") {
        quoteMode = _ShellQuoteMode.none;
      } else {
        currentToken.write(character);
      }
      continue;
    }

    if (quoteMode == _ShellQuoteMode.double) {
      if (character == '"') {
        quoteMode = _ShellQuoteMode.none;
        continue;
      }
      if (character.codeUnitAt(0) == _backslashCodeUnit) {
        if (index + 1 >= normalized.length) {
          return null;
        }
        final nextCharacter = normalized[index + 1];
        if (nextCharacter == '"' ||
            nextCharacter.codeUnitAt(0) == _backslashCodeUnit ||
            nextCharacter == r'$' ||
            nextCharacter == '`') {
          currentToken.write(nextCharacter);
          index++;
          continue;
        }
      }
      currentToken.write(character);
      continue;
    }

    if (character == ' ' || character == '\t') {
      commitToken();
      continue;
    }
    if (character == "'") {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.single;
      continue;
    }
    if (character == '"') {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.double;
      continue;
    }
    if (character.codeUnitAt(0) == _backslashCodeUnit) {
      if (index + 1 >= normalized.length) {
        return null;
      }
      tokenStarted = true;
      currentToken.write(normalized[index + 1]);
      index++;
      continue;
    }
    tokenStarted = true;
    currentToken.write(character);
  }

  if (quoteMode != _ShellQuoteMode.none) {
    return null;
  }

  commitToken();
  return tokens;
}

bool _isReusableTmuxClientFlag(String value) {
  if (value == '-S' || value == '-L' || value == '-f') {
    return true;
  }
  return value.length > 2 &&
      (value.startsWith('-S') ||
          value.startsWith('-L') ||
          value.startsWith('-f'));
}

bool _isTmuxCommandSeparatorToken(String value) => value == ';';

const _tmuxWindowSubscriptionFormat =
    '#{window_index}$tmuxWindowFieldSeparator'
    '#{window_name}$tmuxWindowFieldSeparator'
    '#{window_active}$tmuxWindowFieldSeparator'
    '#{pane_current_command}$tmuxWindowFieldSeparator'
    '#{pane_current_path}$tmuxWindowFieldSeparator'
    '#{window_flags}$tmuxWindowFieldSeparator'
    '#{pane_title}$tmuxWindowFieldSeparator'
    '#{window_activity}$tmuxWindowFieldSeparator'
    '#{pane_start_command}$tmuxWindowFieldSeparator'
    '#{@flutty_agent_tool}$tmuxWindowFieldSeparator'
    '#{window_id}$tmuxWindowFieldSeparator'
    '#{pane_pid}$tmuxWindowFieldSeparator'
    '#{@flutty_agent_session_id}$tmuxWindowFieldSeparator'
    '#{@flutty_agent_session_title}$tmuxWindowFieldSeparator'
    '#{@flutty_agent_session_confidence}';

const _tmuxControlModeClientFlags = 'ignore-size,no-output';
const _tmuxControlModeDetachInput = 'detach-client -P\n\n';
const _tmuxControlModeExitAcknowledgeInput = '\n';
const _tmuxControlModeShutdownTimeout = Duration(seconds: 1);

/// Builds the tmux control-mode attach command used for live window updates.
///
/// Intentionally omits tmux's `wait-exit` client flag. On an unexpected SSH
/// disconnect there is no client left to send the empty line `wait-exit`
/// requires, so the remote control-mode client can linger indefinitely.
@visibleForTesting
String buildTmuxControlModeAttachCommand(
  String sessionName, {
  String? extraFlags,
}) =>
    '${TmuxService._tmuxCommand('-CC attach-session -f $_tmuxControlModeClientFlags', extraFlags: extraFlags)} '
    '-t ${shellEscapePosix(sessionName)}';

/// Builds the tmux control-mode subscription command for window snapshots.
@visibleForTesting
String buildTmuxWindowSubscriptionCommand(String subscriptionName) =>
    "refresh-client -B '$subscriptionName:@*:$_tmuxWindowSubscriptionFormat'";

final _tmuxControlDcsStart = RegExp(r'^\u001bP\d+p');
final _tmuxControlDcsEnd = RegExp(r'\u001b\\$');

String _normalizeTmuxControlLine(String line) {
  var normalized = line.trim();
  normalized = normalized.replaceFirst(_tmuxControlDcsStart, '');
  normalized = normalized.replaceFirst(_tmuxControlDcsEnd, '');
  return normalized.trim();
}

/// Returns a safe category for a tmux control-mode line without exposing the
/// raw line contents.
@visibleForTesting
String diagnosticTmuxControlLineKind(String line) =>
    _diagnosticTmuxControlLineKind(_normalizeTmuxControlLine(line));

String _diagnosticTmuxControlLineKind(String trimmed) {
  if (trimmed.isEmpty) return 'empty';
  final separator = trimmed.indexOf(' ');
  final marker = separator == -1 ? trimmed : trimmed.substring(0, separator);
  if (marker.startsWith('%')) {
    return marker.substring(1).replaceAll('-', '_');
  }
  return 'other';
}

/// Returns whether [line] should trigger a debounced reload fallback when a
/// direct snapshot either does not arrive or cannot be parsed.
///
/// tmux normally follows window-change notifications like
/// `%session-window-changed` with `%subscription-changed` snapshots, but some
/// hosts intermittently stop delivering the snapshot while still emitting the
/// lifecycle notification. Treat those lines as a fallback reload trigger so
/// the UI does not get stuck on stale window metadata.
@visibleForTesting
bool shouldScheduleTmuxWindowReloadFallback(
  String line, {
  required String subscriptionName,
}) =>
    _classifyTmuxControlLine(
      _normalizeTmuxControlLine(line),
      subscriptionName,
    ) !=
    _TmuxControlNotification.other;

/// Returns whether a scheduled tmux reload should be preserved even if a later
/// snapshot arrives before the debounce fires.
///
/// Window add/remove lifecycle events need a full `list-windows` refresh so the
/// local list can drop removed windows and pick up newly created ones. A later
/// per-window snapshot is not enough to reconcile those structural changes.
@visibleForTesting
bool shouldPreserveTmuxWindowReloadThroughSnapshots(String line) =>
    _classifyTmuxControlLine(_normalizeTmuxControlLine(line), null) ==
    _TmuxControlNotification.structural;

enum _TmuxControlNotification {
  other,
  subscription,
  fallback,
  reload,
  structural,
}

_TmuxControlNotification _classifyTmuxControlLine(
  String line,
  String? subscriptionName,
) {
  if (subscriptionName != null &&
      line.startsWith('%subscription-changed $subscriptionName ')) {
    return _TmuxControlNotification.subscription;
  }
  const notifications = {
    '%pane-mode-changed ': _TmuxControlNotification.reload,
    '%session-window-changed ': _TmuxControlNotification.fallback,
    '%sessions-changed': _TmuxControlNotification.structural,
    '%unlinked-window-add ': _TmuxControlNotification.structural,
    '%unlinked-window-close ': _TmuxControlNotification.structural,
    '%unlinked-window-renamed ': _TmuxControlNotification.reload,
    '%window-add ': _TmuxControlNotification.structural,
    '%window-close ': _TmuxControlNotification.structural,
    '%window-renamed ': _TmuxControlNotification.fallback,
  };
  for (final entry in notifications.entries) {
    if (line.startsWith(entry.key)) return entry.value;
  }
  return _TmuxControlNotification.other;
}

/// Returns whether a live tmux window snapshot should bypass the normal active
/// session metadata refresh throttle.
bool shouldForceAgentSessionMetadataRefreshForSnapshot(
  Iterable<TmuxWindow> cachedWindows,
  TmuxWindow snapshot,
) {
  if (snapshot.foregroundAgentTool == null) {
    return false;
  }

  TmuxWindow? existingWindow;
  for (final cachedWindow in cachedWindows) {
    if (_isSameTmuxWindowSnapshot(cachedWindow, snapshot)) {
      existingWindow = cachedWindow;
      break;
    }
  }
  if (existingWindow == null) {
    return true;
  }

  return existingWindow.panePid != snapshot.panePid ||
      existingWindow.currentCommand != snapshot.currentCommand ||
      existingWindow.agentTool != snapshot.agentTool;
}

bool _isSameTmuxWindowSnapshot(TmuxWindow existing, TmuxWindow snapshot) {
  final snapshotId = snapshot.id;
  if (snapshotId != null) {
    return existing.id == snapshotId;
  }
  return existing.index == snapshot.index;
}

/// Parses a control-mode output [line] into a tmux window change event for
/// the observer using [subscriptionName].
@visibleForTesting
TmuxWindowChangeEvent? parseTmuxWindowChangeEventFromControlLine(
  String line, {
  required String subscriptionName,
}) {
  final trimmed = _normalizeTmuxControlLine(line);
  return _parseTmuxWindowChangeEvent(
    trimmed,
    _classifyTmuxControlLine(trimmed, subscriptionName),
  );
}

TmuxWindowChangeEvent? _parseTmuxWindowChangeEvent(
  String trimmed,
  _TmuxControlNotification notification,
) {
  if (notification == _TmuxControlNotification.subscription) {
    final valueSeparator = trimmed.indexOf(' : ');
    if (valueSeparator == -1 || valueSeparator + 3 >= trimmed.length) {
      return const TmuxWindowReloadEvent();
    }
    final value = trimmed.substring(valueSeparator + 3);
    try {
      return TmuxWindowSnapshotEvent(TmuxWindow.fromTmuxFormat(value));
    } on FormatException {
      return const TmuxWindowReloadEvent();
    }
  }

  if (notification == _TmuxControlNotification.reload ||
      notification == _TmuxControlNotification.structural) {
    return const TmuxWindowReloadEvent();
  }
  return null;
}

/// Action the tmux control-mode heartbeat decides to take based on how long
/// the channel has been silent.
@visibleForTesting
enum TmuxControlHeartbeatAction {
  /// No action — control-mode notifications have arrived recently.
  noop,

  /// Synthesize a refresh event so listeners refetch window state.
  refresh,
}

/// Pure decision function used by the control-mode observer's heartbeat
/// to keep the UI in sync when push notifications are dropped or the SSH
/// channel is quiet.
@visibleForTesting
TmuxControlHeartbeatAction decideTmuxHeartbeatAction({
  required Duration silence,
  required Duration heartbeatInterval,
}) {
  if (silence >= heartbeatInterval) {
    return TmuxControlHeartbeatAction.refresh;
  }
  return TmuxControlHeartbeatAction.noop;
}

@immutable
class _TmuxWindowWatchKey {
  const _TmuxWindowWatchKey({
    required this.connectionId,
    required this.sessionName,
    this.extraFlags,
  });

  final int connectionId;
  final String sessionName;
  final String? extraFlags;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TmuxWindowWatchKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName &&
          extraFlags == other.extraFlags;

  @override
  int get hashCode => Object.hash(connectionId, sessionName, extraFlags);
}

class _TmuxControlCommandUnavailable implements Exception {
  const _TmuxControlCommandUnavailable();
}

class _TmuxControlCommandRequest {
  _TmuxControlCommandRequest({
    required this.command,
    required this.commandKind,
    required this.timeout,
  });

  final String command;
  final String commandKind;
  final Duration timeout;
  final output = StringBuffer();
  final _completer = Completer<String>();
  Timer? _timeoutTimer;
  bool started = false;

  Future<String> get future => _completer.future;

  void startTimeout(void Function() onTimeout) {
    _timeoutTimer = Timer(timeout, onTimeout);
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void complete(String value) {
    cancelTimeout();
    if (!_completer.isCompleted) {
      _completer.complete(value);
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    cancelTimeout();
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

class _TmuxWindowChangeObserver {
  _TmuxWindowChangeObserver({
    required this.service,
    required this.session,
    required this.sessionName,
    required this.onDispose,
    this.extraFlags,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _controller = StreamController<TmuxWindowChangeEvent>.broadcast() {
    _controller
      ..onListen = _ensureStarted
      ..onCancel = () => unawaited(dispose());
  }

  static const _eventDebounce = Duration(milliseconds: 150);

  /// How often to check whether the control-mode session has gone quiet and
  /// synthesize a refresh event when it has. Keeps the UI in sync even if
  /// `%subscription-changed` notifications are dropped.
  static const _heartbeatInterval = Duration(seconds: 5);

  final TmuxService service;
  final SshSession session;
  final String sessionName;
  final String? extraFlags;
  final VoidCallback onDispose;
  final DateTime Function() _now;
  final StreamController<TmuxWindowChangeEvent> _controller;

  // Cancelled in _cleanupControlSession().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _stdoutSubscription;
  // Cancelled in _cleanupControlSession().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _stderrSubscription;
  // Cancelled in _cleanupControlSession().
  // ignore: cancel_subscriptions
  StreamSubscription<void>? _doneSubscription;
  Timer? _debounceTimer;
  Timer? _restartTimer;
  Timer? _heartbeatTimer;
  SSHSession? _controlSession;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  final _controlCommandQueue = Queue<_TmuxControlCommandRequest>();
  _TmuxControlCommandRequest? _activeControlCommand;
  bool _disposed = false;
  bool _preserveScheduledReloadThroughSnapshots = false;
  int _restartAttempts = 0;
  DateTime? _lastControlActivity;

  String get _subscriptionName =>
      'flutty-${session.connectionId}-${sessionName.hashCode.abs()}';

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  bool get canRunCommands => !_disposed && _controlSession != null;

  Future<String> runCommand(
    String command, {
    required String commandKind,
    required Duration timeout,
  }) {
    if (_disposed || _controlSession == null) {
      return Future<String>.error(const _TmuxControlCommandUnavailable());
    }
    final request = _TmuxControlCommandRequest(
      command: command,
      commandKind: commandKind,
      timeout: timeout,
    );
    _controlCommandQueue.add(request);
    _startNextControlCommand();
    return request.future;
  }

  void _startNextControlCommand() {
    if (_disposed ||
        _activeControlCommand != null ||
        _controlCommandQueue.isEmpty) {
      return;
    }
    final controlSession = _controlSession;
    if (controlSession == null) {
      _failControlCommands(
        const _TmuxControlCommandUnavailable(),
        StackTrace.current,
      );
      return;
    }
    final request = _controlCommandQueue.removeFirst();
    _activeControlCommand = request;
    request.startTimeout(() {
      if (!identical(_activeControlCommand, request)) {
        return;
      }
      final error = TimeoutException(
        'Timed out waiting for tmux control command',
        request.timeout,
      );
      DiagnosticsLogService.instance.warning(
        'tmux.control',
        'command_timeout',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': request.commandKind,
          'timeoutMs': request.timeout.inMilliseconds,
        },
      );
      _handleControlFailure(error, StackTrace.current);
    });
    DiagnosticsLogService.instance.debug(
      'tmux.control',
      'command_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'queuedCount': _controlCommandQueue.length,
      },
    );
    try {
      controlSession.write(utf8.encode('${request.command}\n'));
    } on Object catch (error, stackTrace) {
      _handleControlFailure(error, stackTrace);
    }
  }

  Future<void> _ensureStarted() {
    if (_disposed ||
        service._isExecSessionClosed(session) ||
        _controlSession != null) {
      return Future<void>.value();
    }
    final existingStart = _startFuture;
    if (existingStart != null) {
      return existingStart;
    }
    final startFuture = _startControlSession();
    _startFuture = startFuture;
    unawaited(
      startFuture.whenComplete(() {
        if (identical(_startFuture, startFuture)) {
          _startFuture = null;
        }
      }),
    );
    return startFuture;
  }

  Future<void> _startControlSession() async {
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'start',
      fields: {
        'connectionId': session.connectionId,
        'restartAttempts': _restartAttempts,
      },
    );
    try {
      await service._cacheTmuxPath(session);
      if (_disposed) {
        return;
      }
      final execSession = await service._openExec(
        session,
        service._wrapCommand(
          session,
          buildTmuxControlModeAttachCommand(
            sessionName,
            extraFlags: extraFlags,
          ),
        ),
        // tmux control mode stays silent over a plain exec channel on some SSH
        // servers. Request a dedicated PTY so `%subscription-changed` events
        // stream in real time instead of only catching up on fallback reloads.
        pty: const SSHPtyConfig(),
        // A clear during channel creation must still detach the tmux client
        // before the stale-channel guard closes its SSH channel.
        closeStaleSession: (execSession) => _shutdownControlSession(
          execSession,
          shutdownInput: _tmuxControlModeDetachInput,
        ),
      );
      if (_disposed) {
        await _shutdownControlSession(
          execSession,
          shutdownInput: _tmuxControlModeDetachInput,
        );
        return;
      }

      _controlSession = execSession;
      _stdoutSubscription = execSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine, onError: _handleControlFailure);
      _stderrSubscription = execSession.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStderrLine, onError: _handleControlFailure);
      _doneSubscription = execSession.done.asStream().listen(
        (_) => _handleControlClosed(),
        onError: _handleControlFailure,
      );
      _configureControlSession();
      _restartAttempts = 0;
      _lastControlActivity = _now();
      _startHeartbeat();
      DiagnosticsLogService.instance.info(
        'tmux.watch',
        'started',
        fields: {'connectionId': session.connectionId},
      );
    } on Object catch (error, stackTrace) {
      _handleControlFailure(error, stackTrace);
    }
  }

  void _configureControlSession() {
    if (_controlSession == null) return;
    DiagnosticsLogService.instance.debug(
      'tmux.watch',
      'subscribe',
      fields: {'connectionId': session.connectionId},
    );
    runCommand(
      buildTmuxWindowSubscriptionCommand(_subscriptionName),
      commandKind: 'control_subscription',
      timeout: service._execOutputTimeout,
    ).catchError((Object error) {
      if (_disposed) {
        return '';
      }
      DiagnosticsLogService.instance.warning(
        'tmux.watch',
        'subscribe_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return '';
    }).ignore();
  }

  void _handleStdoutLine(String line) {
    if (_disposed) return;
    _lastControlActivity = _now();
    final trimmed = _normalizeTmuxControlLine(line);
    if (_handleControlCommandLine(trimmed)) {
      return;
    }
    if (trimmed.startsWith('%exit')) {
      DiagnosticsLogService.instance.info(
        'tmux.watch',
        'control_exit',
        fields: {'connectionId': session.connectionId},
      );
      _handleControlClosed(shutdownInput: _tmuxControlModeExitAcknowledgeInput);
      return;
    }
    final notification = _classifyTmuxControlLine(trimmed, _subscriptionName);
    final event = _parseTmuxWindowChangeEvent(trimmed, notification);
    if (event is TmuxWindowSnapshotEvent) {
      if (!_preserveScheduledReloadThroughSnapshots) {
        _cancelScheduledReload();
      }
      final activityFilteredEvent = service
          ._suppressWindowSwitchRedrawActivityEvent(
            _TmuxWindowWatchKey(
              connectionId: session.connectionId,
              sessionName: sessionName,
              extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
            ),
            event,
          );
      service._applyCachedWindowSnapshot(
        session,
        sessionName,
        activityFilteredEvent,
        extraFlags: extraFlags,
      );
      DiagnosticsLogService.instance.debug(
        'tmux.watch',
        'snapshot_event',
        fields: {'connectionId': session.connectionId},
      );
      _emitEvent(activityFilteredEvent);
      return;
    }
    if (event == null && notification != _TmuxControlNotification.fallback) {
      return;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.watch',
      event == null ? 'fallback_reload_signal' : 'reload_event',
      fields: {
        'connectionId': session.connectionId,
        'lineKind': _diagnosticTmuxControlLineKind(trimmed),
      },
    );
    _scheduleReloadEvent(
      preserveThroughSnapshots:
          notification == _TmuxControlNotification.structural,
    );
  }

  bool _handleControlCommandLine(String trimmed) {
    final request = _activeControlCommand;
    if (request == null) {
      return false;
    }
    if (trimmed.startsWith('%begin ')) {
      request.started = true;
      return true;
    }
    if (!request.started) {
      return false;
    }
    if (trimmed.startsWith('%end ')) {
      _completeActiveControlCommand();
      return true;
    }
    if (trimmed.startsWith('%error ')) {
      _failActiveControlCommand(
        const TmuxCommandException('tmux control command failed'),
        StackTrace.current,
      );
      return true;
    }
    if (trimmed.startsWith('%')) {
      return false;
    }
    request.output.writeln(trimmed);
    return true;
  }

  void _completeActiveControlCommand() {
    final request = _activeControlCommand;
    if (request == null) {
      return;
    }
    _activeControlCommand = null;
    final output = request.output.toString().trimRight();
    DiagnosticsLogService.instance.debug(
      'tmux.control',
      'command_complete',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'outputChars': output.length,
      },
    );
    request.complete(output);
    _startNextControlCommand();
  }

  void _failActiveControlCommand(Object error, StackTrace stackTrace) {
    final request = _activeControlCommand;
    if (request == null) {
      return;
    }
    _activeControlCommand = null;
    DiagnosticsLogService.instance.warning(
      'tmux.control',
      'command_failed',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'errorType': error.runtimeType,
      },
    );
    request.completeError(error, stackTrace);
    _startNextControlCommand();
  }

  void _failControlCommands(Object error, StackTrace stackTrace) {
    final activeRequest = _activeControlCommand;
    _activeControlCommand = null;
    if (activeRequest != null) {
      DiagnosticsLogService.instance.warning(
        'tmux.control',
        'command_failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': activeRequest.commandKind,
          'errorType': error.runtimeType,
        },
      );
      activeRequest.completeError(error, stackTrace);
    }
    while (_controlCommandQueue.isNotEmpty) {
      _controlCommandQueue.removeFirst().completeError(error, stackTrace);
    }
  }

  void _handleStderrLine(String line) {
    if (_disposed || line.trim().isEmpty) return;
    _lastControlActivity = _now();
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'stderr_line',
      fields: {'connectionId': session.connectionId, 'charCount': line.length},
    );
    _scheduleRestart();
  }

  void _emitEvent(TmuxWindowChangeEvent event) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(event);
  }

  void _cancelScheduledReload() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _preserveScheduledReloadThroughSnapshots = false;
  }

  void _scheduleReloadEvent({bool preserveThroughSnapshots = false}) {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _preserveScheduledReloadThroughSnapshots =
        _preserveScheduledReloadThroughSnapshots || preserveThroughSnapshots;
    _debounceTimer = Timer(_eventDebounce, () {
      _debounceTimer = null;
      _preserveScheduledReloadThroughSnapshots = false;
      if (!_disposed && !_controller.isClosed) {
        DiagnosticsLogService.instance.debug(
          'tmux.watch',
          'emit_scheduled_reload',
          fields: {'connectionId': session.connectionId},
        );
        _controller.add(const TmuxWindowReloadEvent());
      }
    });
  }

  void _handleControlFailure(Object error, StackTrace stackTrace) {
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'control_failure',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
    unawaited(
      _cleanupControlSession(
        commandError: error,
        stackTrace: stackTrace,
        shutdownInput: _tmuxControlModeDetachInput,
      ),
    );
    _scheduleRestart(
      channelOpenFailure: _shouldTreatTmuxExecChannelAsUnavailable(error),
    );
  }

  void _handleControlClosed({String? shutdownInput}) {
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'control_closed',
      fields: {'connectionId': session.connectionId},
    );
    unawaited(
      _cleanupControlSession(
        commandError: const TmuxCommandException(
          'tmux control channel closed before command completed',
        ),
        stackTrace: StackTrace.current,
        shutdownInput: shutdownInput,
      ),
    );
    _scheduleRestart();
  }

  void _scheduleRestart({bool channelOpenFailure = false}) {
    _stopHeartbeat();
    _restartTimer?.cancel();
    if (_disposed ||
        service._isExecSessionClosed(session) ||
        !_controller.hasListener) {
      return;
    }
    final delay = resolveTmuxControlRestartDelay(
      _restartAttempts,
      channelOpenFailure: channelOpenFailure,
    );
    _restartAttempts += 1;
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'restart_scheduled',
      fields: {
        'connectionId': session.connectionId,
        'attempt': _restartAttempts,
        'delayMs': delay.inMilliseconds,
        'channelOpenFailure': channelOpenFailure,
      },
    );
    _restartTimer = Timer(delay, () => unawaited(_ensureStarted()));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _onHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Heartbeat tick:
  ///
  /// If the control session has been quiet for [_heartbeatInterval],
  /// synthesize a refresh event so listeners refetch window state. Do not
  /// restart a quiet control session; tmux can legitimately stay silent after
  /// its initial subscription snapshot, and frequent restarts consume SSH
  /// session channels on servers with low `MaxSessions` limits.
  void _onHeartbeat() {
    if (_disposed || service._isExecSessionClosed(session)) {
      _stopHeartbeat();
      return;
    }
    final lastActivity = _lastControlActivity;
    if (lastActivity == null) return;
    final action = decideTmuxHeartbeatAction(
      silence: _now().difference(lastActivity),
      heartbeatInterval: _heartbeatInterval,
    );
    switch (action) {
      case TmuxControlHeartbeatAction.noop:
        return;
      case TmuxControlHeartbeatAction.refresh:
        DiagnosticsLogService.instance.debug(
          'tmux.watch',
          'heartbeat_refresh',
          fields: {
            'connectionId': session.connectionId,
            'silenceMs': _now().difference(lastActivity).inMilliseconds,
          },
        );
        _scheduleReloadEvent();
        return;
    }
  }

  Future<void> _cleanupControlSession({
    Object? commandError,
    StackTrace? stackTrace,
    String? shutdownInput,
  }) {
    _stopHeartbeat();
    _cancelScheduledReload();
    _failControlCommands(
      commandError ?? const _TmuxControlCommandUnavailable(),
      stackTrace ?? StackTrace.current,
    );
    final stdoutSubscription = _stdoutSubscription;
    final stderrSubscription = _stderrSubscription;
    final doneSubscription = _doneSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    final controlSession = _controlSession;
    _controlSession = null;
    _lastControlActivity = null;
    return Future.wait([
      if (stdoutSubscription != null) stdoutSubscription.cancel(),
      if (stderrSubscription != null) stderrSubscription.cancel(),
      if (doneSubscription != null) doneSubscription.cancel(),
      if (controlSession != null)
        _shutdownControlSession(controlSession, shutdownInput: shutdownInput),
    ]).then((_) {});
  }

  Future<void> _shutdownControlSession(
    SSHSession controlSession, {
    String? shutdownInput,
  }) async {
    try {
      if (shutdownInput != null) {
        try {
          controlSession.write(utf8.encode(shutdownInput));
          await controlSession.stdin.close().timeout(
            _tmuxControlModeShutdownTimeout,
          );
        } on Object catch (error) {
          DiagnosticsLogService.instance.warning(
            'tmux.watch',
            'shutdown_input_failed',
            fields: {
              'connectionId': session.connectionId,
              'errorType': error.runtimeType,
            },
          );
        }
      }
    } finally {
      controlSession.close();
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'dispose',
      fields: {'connectionId': session.connectionId},
    );
    _disposed = true;
    _stopHeartbeat();
    _restartTimer?.cancel();
    _restartTimer = null;
    final startFuture = _startFuture;
    if (startFuture != null) {
      await startFuture;
    }
    await _cleanupControlSession(shutdownInput: _tmuxControlModeDetachInput);
    if (!_controller.isClosed) {
      await _controller.close();
    }
    onDispose();
  }
}

class _TmuxWindowSwitchActivitySuppression {
  _TmuxWindowSwitchActivitySuppression({
    required this.windowIndex,
    required this.windowId,
    required this.baselineActivityEpochSeconds,
  });

  final int windowIndex;
  final String? windowId;
  final int? baselineActivityEpochSeconds;
  DateTime? captureUntil;
  int? _syntheticActivityEpochSeconds;

  TmuxWindow preserveBaselineForSyntheticRedraw(
    TmuxWindow window, {
    required bool captureSyntheticActivity,
  }) {
    final matchesTarget = windowId != null
        ? window.id == windowId
        : window.index == windowIndex;
    if (!matchesTarget) return window;
    final activity = window.lastActivityEpochSeconds;
    if (activity == null ||
        (baselineActivityEpochSeconds != null &&
            activity <= baselineActivityEpochSeconds!)) {
      return window;
    }
    // tmux exposes second-resolution activity, not output provenance. Treat
    // only the first transition as the switch redraw; a newer timestamp must
    // remain visible even if it arrives before the grace period ends.
    if (_syntheticActivityEpochSeconds == null && captureSyntheticActivity) {
      _syntheticActivityEpochSeconds = activity;
    }
    final captured = _syntheticActivityEpochSeconds;
    if (captured == null || activity > captured) return window;
    return window.copyWith(
      lastActivityEpochSeconds: baselineActivityEpochSeconds,
      clearLastActivityEpochSeconds: baselineActivityEpochSeconds == null,
    );
  }
}

/// Provider for [TmuxService].
final tmuxServiceProvider = Provider<TmuxService>((ref) => const TmuxService());

/// Maps a binary's basename (e.g. `claude`) to the matching [AgentLaunchTool],
/// or `null` if it does not correspond to a supported CLI.
AgentLaunchTool? agentToolForBinaryName(String binaryName) {
  final basename = binaryName.trim().split(RegExp(r'[\\/]')).last;
  final normalized = basename.replaceFirst(
    _windowsExecutableExtensionPattern,
    '',
  );
  return agentLaunchToolForCommandName(normalized);
}

/// Builds the shell command used by [TmuxService.detectInstalledAgentTools]
/// to resolve agent CLI binaries on a remote host.
///
/// The command:
///
/// - Loops one binary at a time so it works on POSIX-strict shells like
///   `dash`, where `command -v a b c` rejects the extra operands and
///   prints nothing.
/// - Re-invokes the user's interactive `$SHELL` (`zsh -ic`, `bash -ic`,
///   …) so PATH additions made from `~/.zshrc` / `~/.bashrc` (where
///   tools like `claude` and other npm-global / asdf / mise / pyenv
///   installs are commonly added) are picked up. Login-only profile
///   sourcing — what SSH exec channels otherwise see — misses these.
/// - Falls back to `/bin/sh` if `$SHELL` is unset, and tolerates the
///   inner `command -v` exiting non-zero when a binary is missing.
@visibleForTesting
String buildAgentToolDetectionCommand() {
  final binaries =
      AgentLaunchTool.values
          .expand((t) => t.candidateCommandNames)
          .toSet()
          .toList()
        ..sort();
  final inner =
      'for c in ${binaries.join(' ')}; do '
      r'command -v "$c" 2>/dev/null; '
      'done';
  // Single-quote the inner snippet for the outer shell, then escape any
  // single quotes inside it. There are none today, but this keeps the
  // builder safe if someone adds a binary name containing a quote.
  final quotedInner = "'${inner.replaceAll("'", "'\"'\"'")}'";
  return r'SH="${SHELL:-/bin/sh}"; "$SH" -ic '
      '$quotedInner '
      '2>/dev/null || true';
}

/// Builds the PowerShell script used by [TmuxService.detectInstalledAgentTools]
/// to resolve agent CLI binaries on Windows remotes.
///
/// It first applies the user's profile `PATH` (see
/// [powerShellProfilePathPreamble]) because agent CLIs are usually installed
/// through npm/bun or a Node version manager, which put their shims on `PATH`
/// from a PowerShell profile rather than the persistent environment an SSH exec
/// channel inherits.
///
/// It only accepts external commands (`Application` or `ExternalScript`) so
/// aliases, functions, and cmdlets are not mistaken for installed CLIs.
@visibleForTesting
String buildWindowsAgentToolDetectionScript() {
  final names =
      AgentLaunchTool.values
          .expand((t) => t.candidateCommandNames)
          .toSet()
          .toList()
        ..sort();
  final quotedNames = names.map(powerShellSingleQuote).join(',');
  final body = [
    powerShellProfilePathPreamble,
    '\$__flNames=@($quotedNames);',
    r'foreach($__flName in $__flNames){',
    r'$__flCmd=Get-Command -Name $__flName -CommandType Application,ExternalScript -ErrorAction SilentlyContinue|Select-Object -First 1;',
    r'if($__flCmd -eq $null){continue};',
    r'$__flPath=$__flCmd.Path;',
    r'if([string]::IsNullOrWhiteSpace($__flPath)){$__flPath=$__flCmd.Source};',
    r'if([string]::IsNullOrWhiteSpace($__flPath)){$__flPath=$__flCmd.Name};',
    r'if([string]::IsNullOrWhiteSpace($__flPath)){continue};',
    r"$__flPath=$__flPath -replace '\\','/';",
    r'[void]$__flOut.Append($__flPath).Append("`n");',
    '}',
  ].join();
  return powerShellUtf8OutputScript(body);
}

/// Parses agent CLI detection output, returning supported CLIs that resolved to
/// an absolute path.
///
/// Lines that do not look like POSIX or Windows absolute paths are ignored, so
/// shell function names, builtins, aliases, cmdlets, or PowerShell functions are
/// not treated as installed CLIs.
Set<AgentLaunchTool> parseInstalledAgentTools(String output) {
  final installed = <AgentLaunchTool>{};
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (!_looksLikeResolvedAgentToolPath(line)) continue;
    final binary = line.replaceAll(r'\', '/').split('/').last;
    final tool = agentToolForBinaryName(binary);
    if (tool != null) installed.add(tool);
  }
  return installed;
}

final _windowsAbsolutePathPattern = RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)');
final _windowsExecutableExtensionPattern = RegExp(
  r'\.(?:exe|cmd|bat|ps1|com)$',
  caseSensitive: false,
);

bool _looksLikeResolvedAgentToolPath(String line) =>
    line.startsWith('/') || _windowsAbsolutePathPattern.hasMatch(line);

/// Builds a shell command that maps live AI CLI processes to session metadata.
///
/// The command starts from known tmux pane PIDs, takes one process-tree
/// snapshot, finds descendant AI CLI processes, and uses lightweight lock-file,
/// command-line, and open-file probes to infer the active session.
///
/// The output is Unit Separator-delimited:
/// `tool<US>session_id<US>process_pid<US>matched_pane_pid<US>confidence<US>title`.
String buildAgentActiveSessionMetadataCommand(Set<int> panePids) {
  final normalizedPanePids =
      panePids.where((panePid) => panePid > 0).toSet().toList()..sort();
  if (normalizedPanePids.isEmpty) {
    return ':';
  }
  final panePidText = normalizedPanePids.join(' ');
  return '''
sep=\$(printf "\\037")
unsetopt nomatch 2>/dev/null || true
pane_pids=${shellEscapePosix(panePidText)}
home=\${HOME:-}
if [ -z "\$home" ]; then
  home=~
fi
ps_output=\$(ps -eo pid=,ppid=,comm=,args= 2>/dev/null || true)
state_dir=\$home/.copilot/session-state
flutty_arg_value() {
  option=\$1
  command_text=\$2
  printf '%s\\n' "\$command_text" | awk -v opt="\$option" '
{
  for (i = 1; i <= NF; i++) {
    if (\$i == opt && i < NF) {
      print \$(i + 1)
      exit
    }
    prefix = opt "="
    if (index(\$i, prefix) == 1) {
      print substr(\$i, length(prefix) + 1)
      exit
    }
  }
}'
}
flutty_codex_resume_id() {
  command_text=\$1
  printf '%s\\n' "\$command_text" | awk '
{
  for (i = 1; i < NF; i++) {
    if (\$i == "resume") {
      value = \$(i + 1)
      if (value !~ /^-/ && value ~ /^[A-Za-z0-9._-]+\$/) print value
      exit
    }
  }
}'
}
flutty_json_string_field_from_stdin() {
  field=\$1
  awk -v field="\$field" '
BEGIN {
  quote = sprintf("%c", 34)
  slash = sprintf("%c", 92)
  key = quote field quote
}
index(\$0, key) {
  line = \$0
  sub(".*" key "[[:space:]]*:[[:space:]]*" quote, "", line)
  out = ""
  escaped = 0
  for (i = 1; i <= length(line); i++) {
    ch = substr(line, i, 1)
    if (escaped) {
      out = out "\\\\" ch
      escaped = 0
      continue
    }
    if (ch == slash) {
      escaped = 1
      continue
    }
    if (ch == quote) {
      print out
      exit
    }
    out = out ch
  }
}'
}
flutty_json_string_field_from_file() {
  file=\$1
  field=\$2
  [ -r "\$file" ] || return 0
  flutty_json_string_field_from_stdin "\$field" < "\$file" 2>/dev/null
}
flutty_clean_session_title() {
  printf '%s' "\$1" |
    sed 's/\\\\"/"/g; s/\\\\\\\\/\\\\/g; s/\\\\n/ /g; s/\\\\r/ /g; s/\\\\t/ /g' |
    tr "\\037\\r\\n" "   " |
    awk '{ \$1=\$1; print }' |
    cut -c 1-80
}
flutty_copilot_workspace_title() {
  workspace=\$1
  [ -r "\$workspace" ] || return 0
  title=\$(awk '
/^[[:space:]]*summary:[[:space:]]*/ {
  sub(/^[[:space:]]*summary:[[:space:]]*/, "")
  print
  exit
}
/^[[:space:]]*name:[[:space:]]*/ {
  sub(/^[[:space:]]*name:[[:space:]]*/, "")
  print
  exit
}
' "\$workspace" 2>/dev/null)
  flutty_clean_session_title "\$title"
}
flutty_claude_session_title() {
  file=\$1
  [ -r "\$file" ] || return 0
  title=\$(grep '"customTitle"' "\$file" 2>/dev/null | tail -n 1 | flutty_json_string_field_from_stdin customTitle)
  if [ -z "\$title" ]; then
    title=\$(grep '"lastPrompt"' "\$file" 2>/dev/null | tail -n 1 | flutty_json_string_field_from_stdin lastPrompt)
  fi
  if [ -z "\$title" ]; then
    title=\$(grep '"type"[[:space:]]*:[[:space:]]*"user"' "\$file" 2>/dev/null |
      grep -v '"isMeta"[[:space:]]*:[[:space:]]*true' |
      grep '"content"' |
      grep -v '"content"[[:space:]]*:[[:space:]]*"/' |
      head -n 1 |
      flutty_json_string_field_from_stdin content)
  fi
  flutty_clean_session_title "\$title"
}
flutty_codex_session_title() {
  file=\$1
  session_id=\$2
  title=
  index_file=\$home/.codex/session_index.jsonl
  if [ -r "\$index_file" ] && [ -n "\$session_id" ]; then
    title=\$(grep -F "\$session_id" "\$index_file" 2>/dev/null |
      grep '"thread_name"' |
      tail -n 1 |
      flutty_json_string_field_from_stdin thread_name)
  fi
  if [ -z "\$title" ] && [ -r "\$file" ]; then
    title=\$(grep '"user_message"' "\$file" 2>/dev/null |
      grep '"message"' |
      head -n 1 |
      flutty_json_string_field_from_stdin message)
  fi
  flutty_clean_session_title "\$title"
}
flutty_process_cwd() {
  pid=\$1
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -a -p "\$pid" -d cwd -Fn 2>/dev/null | awk '
substr(\$0, 1, 1) == "n" {
  print substr(\$0, 2)
  exit
}'
}
flutty_process_start_epoch() {
  pid=\$1
  etime=\$(ps -p "\$pid" -o etime= 2>/dev/null | awk 'NR == 1 { gsub(/^[[:space:]]+|[[:space:]]+\$/, ""); print; exit }')
  [ -n "\$etime" ] || return 0
  elapsed=\$(printf '%s\\n' "\$etime" | awk '
{
  days = 0
  rest = \$0
  if (index(rest, "-") > 0) {
    split(rest, day_parts, "-")
    days = day_parts[1] + 0
    rest = day_parts[2]
  }
  count = split(rest, parts, ":")
  if (count == 3) {
    hours = parts[1] + 0
    minutes = parts[2] + 0
    seconds = parts[3] + 0
  } else if (count == 2) {
    hours = 0
    minutes = parts[1] + 0
    seconds = parts[2] + 0
  } else {
    hours = 0
    minutes = 0
    seconds = parts[1] + 0
  }
  print days * 86400 + hours * 3600 + minutes * 60 + seconds
}')
  case "\$elapsed" in ''|*[!0-9]*) return 0 ;; esac
  now=\$(date +%s 2>/dev/null || true)
  case "\$now" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "\$((now - elapsed))"
}
flutty_file_mtime_epoch() {
  file=\$1
  value=\$(stat -f %m "\$file" 2>/dev/null)
  case "\$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "\$value"; return 0 ;;
  esac
  value=\$(stat -c %Y "\$file" 2>/dev/null)
  case "\$value" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "\$value" ;;
  esac
}
flutty_file_is_newer_than_process() {
  file=\$1
  process_start_epoch=\$2
  case "\$process_start_epoch" in ''|*[!0-9]*) return 1 ;; esac
  mtime=\$(flutty_file_mtime_epoch "\$file")
  case "\$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "\$mtime" -ge "\$((process_start_epoch - 2))" ]
}
flutty_copilot_lock_match() {
  pid=\$1
  process_start_epoch=\$2
  [ -d "\$state_dir" ] || return 0
  freshest_lock=
  freshest_mtime=
  for lock in "\$state_dir"/*/inuse."\$pid".lock; do
    [ -e "\$lock" ] || continue
    if [ -n "\$process_start_epoch" ]; then
      flutty_file_is_newer_than_process "\$lock" "\$process_start_epoch" || continue
    fi
    lock_mtime=\$(flutty_file_mtime_epoch "\$lock")
    case "\$lock_mtime" in ''|*[!0-9]*) continue ;; esac
    if [ -z "\$freshest_lock" ] || [ "\$lock_mtime" -gt "\$freshest_mtime" ]; then
      freshest_lock=\$lock
      freshest_mtime=\$lock_mtime
    fi
  done
  [ -n "\$freshest_lock" ] || return 0
  dir=\${freshest_lock%/*}
  session_id=\${dir##*/}
  workspace=\$dir/workspace.yaml
  title=
  if [ -r "\$workspace" ]; then
    title=\$(flutty_copilot_workspace_title "\$workspace")
  fi
  flutty_emit_lsof_match "\$session_id" "\$title"
}
flutty_iso8601_epoch() {
  value=\$1
  [ -n "\$value" ] || return 0
  normalized=\$(printf '%s' "\$value" | sed 's/Z\$//; s/\\.[0-9][0-9]*//')
  date -u -j -f '%Y-%m-%dT%H:%M:%S' "\$normalized" +%s 2>/dev/null ||
    date -u -d "\$value" +%s 2>/dev/null ||
    return 0
}
flutty_codex_rollout_id() {
  file=\$1
  name=\${file##*/}
  name=\${name%.jsonl}
  session_id=\$(printf '%s\\n' "\$name" | sed -nE 's/^.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\$/\\1/p')
  if [ -z "\$session_id" ]; then
    session_id=\$(flutty_json_string_field_from_file "\$file" id)
  fi
  if [ -z "\$session_id" ]; then
    session_id=\$name
  fi
  printf '%s' "\$session_id"
}
flutty_codex_rollout_cwd() {
  file=\$1
  grep '"cwd"' "\$file" 2>/dev/null |
    head -n 1 |
    flutty_json_string_field_from_stdin cwd
}
flutty_codex_rollout_line() {
  file=\$1
  [ -r "\$file" ] || return 0
  session_id=\$(flutty_codex_rollout_id "\$file")
  [ -n "\$session_id" ] || return 0
  flutty_emit_lsof_match "\$session_id" "\$(flutty_codex_session_title "\$file" "\$session_id")"
}
flutty_codex_index_resume_match() {
  process_cwd=\$1
  process_start_epoch=\$2
  [ -n "\$process_cwd" ] || return 0
  case "\$process_start_epoch" in ''|*[!0-9]*) return 0 ;; esac
  index_file=\$home/.codex/session_index.jsonl
  [ -r "\$index_file" ] || return 0
  tail -n 80 "\$index_file" 2>/dev/null | awk '{ lines[NR] = \$0 } END { for (i = NR; i > 0; i--) print lines[i] }' |
    while IFS= read -r line; do
      session_id=\$(printf '%s\\n' "\$line" | flutty_json_string_field_from_stdin id)
      case "\$session_id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      updated_at=\$(printf '%s\\n' "\$line" | flutty_json_string_field_from_stdin updated_at)
      updated_epoch=\$(flutty_iso8601_epoch "\$updated_at")
      case "\$updated_epoch" in ''|*[!0-9]*) continue ;; esac
      [ "\$updated_epoch" -ge "\$((process_start_epoch - 2))" ] || continue
      rollout_file=\$(find "\$home/.codex/sessions" -name "*\$session_id*.jsonl" -type f -print -quit 2>/dev/null)
      [ -r "\$rollout_file" ] || continue
      file_cwd=\$(flutty_codex_rollout_cwd "\$rollout_file")
      [ "\$file_cwd" = "\$process_cwd" ] || continue
      title=\$(printf '%s\\n' "\$line" | flutty_json_string_field_from_stdin thread_name)
      if [ -z "\$title" ]; then
        title=\$(flutty_codex_session_title "\$rollout_file" "\$session_id")
      fi
      flutty_emit_lsof_match "\$session_id" "\$title"
      break
    done
}
flutty_codex_logs_resume_match() {
  process_cwd=\$1
  process_start_epoch=\$2
  pid=\$3
  [ -n "\$process_cwd" ] || return 0
  case "\$process_start_epoch" in ''|*[!0-9]*) return 0 ;; esac
  case "\$pid" in ''|*[!0-9]*) return 0 ;; esac
  logs_db=\$home/.codex/logs_2.sqlite
  [ -r "\$logs_db" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  cutoff=\$((process_start_epoch - 2))
  sqlite3 "\$logs_db" "select thread_id from logs where process_uuid like 'pid:\$pid:%' and thread_id is not null and thread_id != '' and ts >= \$cutoff order by ts desc, ts_nanos desc, id desc limit 80;" 2>/dev/null |
    awk '!seen[\$0]++' |
    while IFS= read -r session_id; do
      case "\$session_id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      rollout_file=\$(find "\$home/.codex/sessions" -name "*\$session_id*.jsonl" -type f -print -quit 2>/dev/null)
      [ -r "\$rollout_file" ] || continue
      file_cwd=\$(flutty_codex_rollout_cwd "\$rollout_file")
      [ "\$file_cwd" = "\$process_cwd" ] || continue
      title=\$(flutty_codex_session_title "\$rollout_file" "\$session_id")
      flutty_emit_lsof_match "\$session_id" "\$title"
      break
    done
}
flutty_codex_recent_session_match() {
  process_cwd=\$1
  process_start_epoch=\$2
  [ -n "\$process_cwd" ] || return 0
  case "\$process_start_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "\$home/.codex/sessions" ] || return 0
  # Never assign one cwd-based guess to multiple live Codex panes.
  cwd_pane_count=\$(printf '%s\\n' "\$codex_pane_cwds" | awk -F "\$sep" -v cwd="\$process_cwd" '\$2 == cwd && !seen[\$1]++ { count++ } END { print count + 0 }')
  [ "\$cwd_pane_count" -eq 1 ] || return 0
  index_match=\$(flutty_codex_index_resume_match "\$process_cwd" "\$process_start_epoch")
  if [ -n "\$index_match" ]; then
    printf '%s\\n' "\$index_match"
    return 0
  fi
  files=\$(find "\$home/.codex/sessions" -name 'rollout-*.jsonl' -type f -exec ls -1t {} + 2>/dev/null | head -n 30)
  [ -n "\$files" ] || return 0
  printf '%s\\n' "\$files" | while IFS= read -r file; do
    [ -r "\$file" ] || continue
    flutty_file_is_newer_than_process "\$file" "\$process_start_epoch" || continue
    file_cwd=\$(flutty_codex_rollout_cwd "\$file")
    [ "\$file_cwd" = "\$process_cwd" ] || continue
    flutty_codex_rollout_line "\$file"
    break
  done
}
flutty_antigravity_session_title() {
  session_id=\$1
  [ -n "\$session_id" ] || return 0
  title=
  if [ -r "\$home/.gemini/antigravity-cli/history.jsonl" ]; then
    title=\$(grep -F "\$session_id" "\$home/.gemini/antigravity-cli/history.jsonl" 2>/dev/null |
      grep '"display"' | tail -n 1 | flutty_json_string_field_from_stdin display)
  fi
  annotation_file="\$home/.gemini/antigravity-cli/annotations/\${session_id}.pbtxt"
  if [ -z "\$title" ] && [ -r "\$annotation_file" ]; then
    title=\$(grep -E '^[[:space:]]*title[[:space:]]*:[[:space:]]*' "\$annotation_file" 2>/dev/null |
      sed -E 's/^[[:space:]]*title[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/' | head -n 1)
  fi
  if [ -z "\$title" ]; then
    title="\$session_id"
  fi
  flutty_clean_session_title "\$title"
}
flutty_antigravity_recent_session_match() {
  process_cwd=\$1
  process_start_epoch=\$2
  [ -n "\$process_cwd" ] || return 0
  case "\$process_start_epoch" in ''|*[!0-9]*) return 0 ;; esac
  history_file="\$home/.gemini/antigravity-cli/history.jsonl"
  [ -r "\$history_file" ] || return 0
  session_id=\$(tail -n 100 "\$history_file" 2>/dev/null |
    grep -F "\$process_cwd" |
    tail -n 1 |
    flutty_json_string_field_from_stdin conversationId)
  if [ -z "\$session_id" ]; then
    session_id=\$(tail -n 1 "\$history_file" 2>/dev/null |
      flutty_json_string_field_from_stdin conversationId)
  fi
  if [ -n "\$session_id" ]; then
    title=\$(flutty_antigravity_session_title "\$session_id")
    flutty_emit_lsof_match "\$session_id" "\$title"
  fi
}
flutty_emit_lsof_match() {
  value=\$(printf '%s' "\$1" | tr "\\037\\r\\n" "   ")
  title=\$(flutty_clean_session_title "\$2")
  [ -n "\$value" ] || return 0
  printf '%s%s%s\\n' "\$value" "\$sep" "\$title"
}
flutty_lsof_session_match() {
  pid=\$1
  tool=\$2
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -p "\$pid" -Fn 2>/dev/null | while IFS= read -r line; do
    case "\$line" in
      n*) path=\${line#n} ;;
      *) continue ;;
    esac
    case "\$tool:\$path" in
      claude:*/.claude/projects/*/*.jsonl)
        file=\${path##*/}
        session_id=\${file%.jsonl}
        flutty_emit_lsof_match "\$session_id" "\$(flutty_claude_session_title "\$path")"
        break
        ;;
      codex:*/.codex/sessions/*/rollout-*.jsonl)
        file=\${path##*/}
        file=\${file%.jsonl}
        session_id=\$(printf '%s\\n' "\$file" | sed -nE 's/^.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\$/\\1/p')
        if [ -z "\$session_id" ]; then
          session_id=\$file
        fi
        flutty_emit_lsof_match "\$session_id" "\$(flutty_codex_session_title "\$path" "\$session_id")"
        break
        ;;
      copilot:*/.copilot/session-state/*/workspace.yaml)
        session_id=\${path#*/.copilot/session-state/}
        session_id=\${session_id%/workspace.yaml}
        flutty_emit_lsof_match "\$session_id" "\$(flutty_copilot_workspace_title "\$path")"
        break
        ;;
    esac
  done
}
if [ -n "\${ps_output:-}" ]; then
  agent_rows=\$(printf '%s\\n' "\$ps_output" | awk -v panes="\$pane_pids" -v sep="\$sep" '
# Match executable names, not shell commands, install directories, or prompts.
function basename(value) {
  sub(/^.*\\//, "", value)
  return tolower(value)
}
function is_codex(args,    argv, count, executable, i) {
  count = split(args, argv, /[[:space:]]+/)
  executable = basename(argv[1])
  if (executable == "node" || executable == "bun") {
    i = 2
    while (i <= count && argv[i] ~ /^-/) i++
    executable = basename(argv[i])
    if (executable != "codex.js") return 0
  } else if (executable != "codex" && executable != "codex-cli" && executable != "codex.js") {
    return 0
  }
  for (i = 2; i <= count; i++) {
    if (argv[i] == "app-server") return 0
  }
  return 1
}
BEGIN {
  split(panes, pane_values, " ")
  for (i in pane_values) {
    if (pane_values[i] ~ /^[0-9]+\$/) target[pane_values[i]] = 1
  }
}
{
  pid = \$1
  ppid = \$2
  comm = \$3
  if (pid !~ /^[0-9]+\$/ || ppid !~ /^[0-9]+\$/) next
  args = \$0
  sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
  parent[pid] = ppid
  command[pid] = tolower(comm " " args)
  raw_command[pid] = args
}
END {
  for (pid in parent) {
    tool = ""
    if (is_codex(raw_command[pid])) tool = "codex"
    else if (command[pid] ~ /(^|[\\/@[:space:]])claude([\\/._[:space:]-]|\$)/) tool = "claude"
    else if (command[pid] ~ /(^|[\\/@[:space:]])copilot([\\/._[:space:]-]|\$)/) tool = "copilot"
    else if (command[pid] ~ /(^|[\\/@[:space:]])opencode([\\/._[:space:]-]|\$)/) tool = "opencode"
    else if (command[pid] ~ /(^|[\\/@[:space:]])(agy|antigravity|antigravity-cli)([\\/._[:space:]-]|\$)/) tool = "antigravity"
    if (tool == "") continue
    current = pid
    seen = 0
    while (current != "" && current != "0" && seen < 128) {
      if (current in target) {
        command_text = raw_command[pid]
        gsub(sep, " ", command_text)
        print current sep pid sep tool sep command_text
        break
      }
      current = parent[current]
      seen++
    }
  }
}')
  codex_pane_cwds=\$(printf '%s\\n' "\$agent_rows" | while IFS="\$sep" read -r pane_pid pid tool command_text; do
    [ "\$tool" = codex ] || continue
    cwd=\$(flutty_process_cwd "\$pid")
    [ -n "\$cwd" ] && printf '%s%s%s\\n' "\$pane_pid" "\$sep" "\$cwd"
  done)
  printf '%s\\n' "\$agent_rows" | while IFS="\$sep" read -r pane_pid pid tool command_text; do
      case "\$pane_pid" in ''|*[!0-9]*) continue ;; esac
      case "\$pid" in ''|*[!0-9]*) continue ;; esac
      session_id=
      title=
      confidence=medium
      process_start_epoch=
      if [ "\$tool" = copilot ] && [ -d "\$state_dir" ]; then
        process_start_epoch=\$(flutty_process_start_epoch "\$pid")
        lock_match=\$(flutty_copilot_lock_match "\$pid" "\$process_start_epoch")
        if [ -n "\$lock_match" ]; then
          session_id=\$(printf '%s' "\$lock_match" | awk -F "\$sep" '{ print \$1; exit }')
          title=\$(printf '%s' "\$lock_match" | awk -F "\$sep" '{ print \$2; exit }')
        fi
      fi
      if [ -z "\$session_id" ]; then
        lsof_match=\$(flutty_lsof_session_match "\$pid" "\$tool" || true)
        if [ -n "\$lsof_match" ]; then
          session_id=\$(printf '%s' "\$lsof_match" | awk -F "\$sep" '{ print \$1; exit }')
          title=\$(printf '%s' "\$lsof_match" | awk -F "\$sep" '{ print \$2; exit }')
          if [ "\$tool" = codex ]; then confidence=high; fi
        fi
      fi
      if [ -z "\$session_id" ]; then
        process_cwd=\$(flutty_process_cwd "\$pid")
        if [ -z "\$process_start_epoch" ]; then
          process_start_epoch=\$(flutty_process_start_epoch "\$pid")
        fi
        case "\$tool" in
          codex)
            recent_match=\$(flutty_codex_logs_resume_match "\$process_cwd" "\$process_start_epoch" "\$pid" || true)
            confidence=high
            if [ -z "\$recent_match" ]; then
              # Resume arguments beat cwd guesses, but may be stale after /resume.
              session_id=\$(flutty_codex_resume_id "\$command_text")
              if [ -n "\$session_id" ]; then
                confidence=medium
                rollout_file=\$(find "\$home/.codex/sessions" -name "*\$session_id*.jsonl" -type f -print -quit 2>/dev/null)
                recent_match=\$(flutty_emit_lsof_match "\$session_id" "\$(flutty_codex_session_title "\$rollout_file" "\$session_id")")
              else
                recent_match=\$(flutty_codex_recent_session_match "\$process_cwd" "\$process_start_epoch" || true)
                confidence=low
              fi
            fi
            ;;
          antigravity) recent_match=\$(flutty_antigravity_recent_session_match "\$process_cwd" "\$process_start_epoch" || true) ;;
          *) recent_match= ;;
        esac
        if [ -n "\$recent_match" ]; then
          session_id=\$(printf '%s' "\$recent_match" | awk -F "\$sep" '{ print \$1; exit }')
          title=\$(printf '%s' "\$recent_match" | awk -F "\$sep" '{ print \$2; exit }')
        fi
      fi
      if [ -z "\$session_id" ]; then
        case "\$tool" in
          claude|copilot) session_id=\$(flutty_arg_value --resume "\$command_text") ;;
          antigravity) session_id=\$(flutty_arg_value --conversation "\$command_text") ;;
          codex) session_id=\$(flutty_codex_resume_id "\$command_text") ;;
          opencode) session_id=\$(flutty_arg_value --session "\$command_text") ;;
        esac
      fi
      if [ -n "\$session_id" ] && [ -z "\$title" ]; then
        case "\$tool" in
          antigravity) title=\$(flutty_antigravity_session_title "\$session_id") ;;
        esac
      fi
      [ -n "\$session_id" ] || continue
      session_id=\$(printf '%s' "\$session_id" | tr "\\037\\r" "  ")
      title=\$(printf '%s' "\$title" | tr "\\037\\r" "  ")
      printf '%s%s%s%s%s%s%s%s%s%s%s\\n' "\$tool" "\$sep" "\$session_id" "\$sep" "\$pid" "\$sep" "\$pane_pid" "\$sep" "\$confidence" "\$sep" "\$title"
  done
fi
''';
}

/// Parses [buildAgentActiveSessionMetadataCommand] output and returns live
/// session metadata keyed by tmux pane PID.
Map<
  int,
  ({
    AgentLaunchTool tool,
    String sessionId,
    String? title,
    AgentSessionConfidence confidence,
  })
>
parseAgentActiveSessionMetadataOutput(String output, Set<int> panePids) {
  if (output.trim().isEmpty || panePids.isEmpty) {
    return const <
      int,
      ({
        AgentLaunchTool tool,
        String sessionId,
        String? title,
        AgentSessionConfidence confidence,
      })
    >{};
  }

  final metadataByPanePid =
      <
        int,
        ({
          AgentLaunchTool tool,
          String sessionId,
          String? title,
          AgentSessionConfidence confidence,
        })
      >{};
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trimRight();
    if (line.isEmpty) continue;
    final fields = line.split(tmuxWindowFieldSeparator);
    if (fields.length < 5) continue;

    final tool = agentToolForBinaryName(fields[0].trim());
    if (tool == null) continue;
    final sessionId = _activeSessionMetadataField(fields[1]);
    if (sessionId.isEmpty) continue;

    final panePid = int.tryParse(fields[3].trim());
    if (panePid == null || !panePids.contains(panePid)) continue;

    final confidence = _activeSessionConfidenceFromMetadataField(fields[4]);
    final title = fields.length > 5
        ? _activeSessionTitleFromMetadataField(fields[5])
        : null;
    final metadata = (
      tool: tool,
      sessionId: sessionId,
      title: title,
      confidence: confidence,
    );
    final existingMetadata = metadataByPanePid[panePid];
    if (existingMetadata == null ||
        _activeSessionConfidenceRank(confidence) >
            _activeSessionConfidenceRank(existingMetadata.confidence)) {
      metadataByPanePid[panePid] = metadata;
    }
  }
  return metadataByPanePid;
}

String _activeSessionMetadataField(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 2) return trimmed;
  final first = trimmed.codeUnitAt(0);
  final last = trimmed.codeUnitAt(trimmed.length - 1);
  if ((first == 0x22 && last == 0x22) || (first == 0x27 && last == 0x27)) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

String? _activeSessionTitleFromMetadataField(String value) {
  final trimmed = _activeSessionMetadataField(value);
  if (trimmed.isEmpty) return null;
  return trimmed;
}

AgentSessionConfidence _activeSessionConfidenceFromMetadataField(
  String value,
) => switch (value.trim().toLowerCase()) {
  'high' => AgentSessionConfidence.high,
  'low' => AgentSessionConfidence.low,
  _ => AgentSessionConfidence.medium,
};

int _activeSessionConfidenceRank(AgentSessionConfidence confidence) =>
    switch (confidence) {
      AgentSessionConfidence.high => 3,
      AgentSessionConfidence.medium => 2,
      AgentSessionConfidence.low => 1,
    };
