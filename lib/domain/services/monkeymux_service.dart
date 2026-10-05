import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/terminal_backend.dart';
import '../models/terminal_progress.dart';
import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_installer_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'remote_multiplexer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

typedef _MonkeyMuxAgentSessionMetadata = ({
  AgentLaunchTool tool,
  String sessionId,
  String? title,
  AgentSessionConfidence confidence,
});

const _oneShotControlResponseTimeout = Duration(seconds: 10);
const _oneShotRunCommandResponseTimeout = Duration(seconds: 25);
const _monkeyMuxSessionStdinCloseTimeout = Duration(milliseconds: 250);

/// Last-resort deadline for a shared window-list query.
///
/// The in-flight request is handed to every later caller, so a query that never
/// settles would pin the window switcher on a spinner for the rest of the
/// connection instead of retrying.
const _windowListWatchdogTimeout = Duration(seconds: 30);

/// Deadline for opening the shared control channel.
///
/// An SSH channel open carries no deadline of its own, so a wedged open would
/// otherwise leave every later command awaiting the same dead start attempt.
const _controlChannelOpenTimeout = Duration(seconds: 20);

var _controlRequestSequence = 0;

/// Returns a process-unique id for a MonkeyMux control request.
///
/// Raw microsecond timestamps are not unique: two commands created in the same
/// microsecond collided in the pending-request map, so the overwritten request
/// never received a response and stalled its caller forever.
String _nextControlRequestId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_controlRequestSequence++}';

/// MonkeyMux-backed implementation of [RemoteMultiplexerService].
final monkeyMuxServiceProvider = Provider<MonkeyMuxService>(
  (ref) =>
      MonkeyMuxService(installer: ref.watch(monkeyMuxInstallerServiceProvider)),
);

/// How the helper should handle an already-running MonkeyMux server on attach.
enum MonkeyMuxServerUpdatePolicy {
  /// Keep the current server and suppress terminal prompts.
  never('never'),

  /// Update without a terminal prompt.
  always('always'),

  /// Reload without a terminal prompt, even when the version matches.
  force('force');

  const MonkeyMuxServerUpdatePolicy(this.cliValue);

  /// CLI flag value passed to the MonkeyMux helper.
  final String cliValue;
}

/// Version metadata for an already-running MonkeyMux server.
@immutable
class MonkeyMuxServerStatus {
  /// Creates a running server status snapshot.
  const MonkeyMuxServerStatus({
    required this.version,
    required this.capabilities,
    this.nativeAcpWindowCount = 0,
    this.installation,
  });

  /// Already-installed helper whose binary version matches the running server.
  ///
  /// Available on the pre-install probe so a deferred update can reuse it.
  final MonkeyMuxInstallation? installation;

  /// Whether a reusable helper matches the version reported by the server.
  bool get hasMatchingInstallation {
    final installedVersion = installation?.version.trim();
    return installedVersion != null &&
        installedVersion.isNotEmpty &&
        installedVersion == version?.trim();
  }

  /// Running helper version reported by the server.
  final String? version;

  /// Capability strings reported by the server.
  final Set<String> capabilities;

  /// Number of live native ACP windows reported by the initial window list.
  final int nativeAcpWindowCount;

  /// Whether replacing this server would interrupt a native agent session.
  bool get hasNativeAcpWindows => nativeAcpWindowCount > 0;

  /// Whether the server can be shut down through the control channel.
  bool get supportsShutdown => capabilities.contains('shutdown');

  /// Whether control input can preserve explicit bracketed-paste semantics.
  bool get supportsBracketedPasteControlInput =>
      capabilities.contains('inject-input-bracketed-paste');

  /// Whether this server differs from the app-bundled helper version.
  bool needsUpdate(String bundledVersion) {
    final runningVersion = version?.trim();
    return runningVersion == null ||
        runningVersion.isEmpty ||
        runningVersion != bundledVersion.trim();
  }
}

/// Builds the foreground attach command for an installed MonkeyMux helper.
String buildMonkeyMuxAttachCommand({
  required String executablePath,
  required String sessionName,
  String? clientId,
  String? workingDirectory,
  String? launchCommand,
  String? windowName,
  String? terminalThemeReports,
  String? terminalCapabilityReports,
  int? terminalColumns,
  int? terminalRows,
  MonkeyMuxServerUpdatePolicy? serverUpdatePolicy,
  bool startInYoloMode = false,
  bool clipViewport = false,
  bool existingOnly = false,
  bool windows = false,
}) {
  final themeHint = terminalThemeReports?.trim();
  final capabilityHint = terminalCapabilityReports?.trim();
  final parts = <String>[
    _monkeyMuxQuoteArg(executablePath, windows: windows),
    'attach',
    '--quiet',
    if (clientId != null && clientId.trim().isNotEmpty) ...[
      '--client-id',
      _monkeyMuxQuoteArg(clientId.trim(), windows: windows),
    ],
    if (clipViewport) '--clip-viewport',
    if (existingOnly) '--existing',
    if (terminalColumns != null && terminalColumns > 0)
      '--width $terminalColumns',
    if (terminalRows != null && terminalRows > 0) '--height $terminalRows',
    if (serverUpdatePolicy != null) ...[
      '--update-policy',
      serverUpdatePolicy.cliValue,
    ],
    if (startInYoloMode) '--restore-yolo',
    if (themeHint != null && themeHint.isNotEmpty) ...[
      '--theme-hint-base64',
      base64Encode(utf8.encode(themeHint)),
    ],
    if (capabilityHint != null && capabilityHint.isNotEmpty) ...[
      '--capability-hint-base64',
      base64Encode(utf8.encode(capabilityHint)),
    ],
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) ...[
      '--cwd',
      _monkeyMuxQuoteArg(workingDirectory.trim(), windows: windows),
    ],
    if (windowName != null && windowName.trim().isNotEmpty) ...[
      '--name',
      _monkeyMuxQuoteArg(windowName.trim(), windows: windows),
    ],
    if (launchCommand != null && launchCommand.trim().isNotEmpty) ...[
      '--command',
      _monkeyMuxQuoteArg(launchCommand.trim(), windows: windows),
    ],
    _monkeyMuxQuoteArg(sessionName, windows: windows),
  ];
  return parts.join(' ');
}

/// Outcome of a retained-image recovery request.
@immutable
class MonkeyMuxImageReplayResult {
  /// Creates an image recovery outcome.
  MonkeyMuxImageReplayResult({
    required Set<int> served,
    required this.retryableFailure,
  }) : served = Set<int>.unmodifiable(served);

  /// Image IDs whose retained transmissions reached the attach client.
  final Set<int> served;

  /// Whether unserved IDs may be retried after a transient transport or
  /// availability gap.
  ///
  /// A server can acknowledge `request_images` but return no IDs when the
  /// active-window switch or a multipart transmission is still settling.
  /// Treating that first empty acknowledgment as final permanently suppresses
  /// repair for the rest of the window visit.
  final bool retryableFailure;

  /// Returns requested IDs that remain eligible for a bounded retry.
  Set<int> retryableUnserved(Iterable<int> requested) {
    if (!retryableFailure) {
      return const <int>{};
    }
    return requested.where((id) => !served.contains(id)).toSet();
  }
}

/// Builds the recovery outcome for one acknowledged replay response.
///
/// Exposed for tests so the service-level contract around acknowledged empty
/// and partially served batches cannot regress independently of the widget
/// retry tests.
@visibleForTesting
MonkeyMuxImageReplayResult resolveMonkeyMuxImageReplayBatchForTesting({
  required Set<int> requested,
  required Set<int> alreadyServed,
  required bool acknowledged,
  required Iterable<String> responseImageIds,
}) {
  final pending = requested.difference(alreadyServed);
  final batch = responseImageIds
      .map(int.tryParse)
      .whereType<int>()
      .where(pending.contains)
      .toSet();
  final served = {...alreadyServed, ...batch};
  return MonkeyMuxImageReplayResult(
    served: served,
    retryableFailure: acknowledged && requested.difference(served).isNotEmpty,
  );
}

/// Controls a remote MonkeyMux session through its JSON backchannel.
class MonkeyMuxService implements RemoteMultiplexerService {
  /// Creates a MonkeyMux service.
  const MonkeyMuxService({
    required MonkeyMuxInstallerService installer,
    Duration agentSessionMetadataPeriodicRefreshInterval = const Duration(
      seconds: 10,
    ),
    @visibleForTesting Duration? controlResponseTimeout,
    bool Function() isAppBackgrounded = _appIsBackgrounded,
  }) : _installer = installer,
       _agentSessionMetadataPeriodicRefreshInterval =
           agentSessionMetadataPeriodicRefreshInterval,
       _controlResponseTimeout = controlResponseTimeout,
       _isAppBackgrounded = isAppBackgrounded;

  final MonkeyMuxInstallerService _installer;
  final Duration _agentSessionMetadataPeriodicRefreshInterval;

  /// Reports whether the app is backgrounded, which pauses periodic probes.
  final bool Function() _isAppBackgrounded;

  /// Overrides the per-command control-response timeout in tests. When null,
  /// production timeouts based on the command type are used.
  final Duration? _controlResponseTimeout;

  static final _states = <_MonkeyMuxWatchKey, _MonkeyMuxSessionState>{};
  static const _agentSessionMetadataFreshTtl = Duration(seconds: 5);

  static _MonkeyMuxSessionState _stateFor(_MonkeyMuxWatchKey key) =>
      _states.putIfAbsent(key, _MonkeyMuxSessionState.new);

  @override
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return null;
    }
    try {
      final installation = await _installer.ensureInstalled(session);
      final status = await runningServerStatus(
        session,
        installation,
        sessionName,
        priority: SshExecPriority.low,
      );
      final version = status?.version?.trim();
      return version == null || version.isEmpty ? null : version;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'version_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Reconnects one workspace's stable watcher stream after the public
  /// MonkeyMux socket moves to a replacement helper. Other session names and
  /// the uploaded-helper cache remain untouched.
  Future<void> resetServerRuntime(int connectionId, String sessionName) async {
    final key = _MonkeyMuxWatchKey(connectionId, sessionName);
    DiagnosticsLogService.instance.info(
      'monkeymux.cache',
      'server_runtime_reset',
      fields: {'connectionId': connectionId},
    );
    final state = _states[key];
    if (state == null) return;
    state.runtimeToken = null;
    final observer = state.observer;
    if (observer == null || observer.isDisposed) {
      state.resetServerRuntime();
      return;
    }
    await observer.recycleForServerReplacement(state.resetServerRuntime);
  }

  /// Clears MonkeyMux caches and watchers for a connection.
  Future<void> clearCache(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'monkeymux.cache',
      'clear',
      fields: {'connectionId': connectionId},
    );
    _installer.clearCache(connectionId);
    final states = <_MonkeyMuxSessionState>[];
    _states.removeWhere((key, state) {
      if (key.connectionId != connectionId) return false;
      states.add(state);
      return true;
    });
    for (final state in states) {
      await state.dispose();
    }
  }

  @override
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    if (isAppReviewDemoSession(session)) {
      final state = _appReviewDemoMuxState(key);
      final windows = state.windows;
      _replaceCachedWindows(key, windows);
      if (state.consumeInitialRender()) {
        _renderAppReviewDemoWindow(session, state.activeWindow);
      }
      return Future<List<TmuxWindow>>.value(windows);
    }
    final existingRequest = _states[key]?.windowListRequest;
    if (existingRequest != null) {
      return existingRequest;
    }
    return _startWindowListRequest(session, sessionName, key);
  }

  /// Fetches a new window snapshot without reusing an older in-flight request.
  ///
  /// If another list request is running, this waits for it to finish and then
  /// starts a second query so callers receive state captured after they asked
  /// for a refresh.
  Future<List<TmuxWindow>> refreshWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    if (isAppReviewDemoSession(session)) {
      return listWindows(session, sessionName, extraFlags: extraFlags);
    }
    final existingRequest = _states[key]?.windowListRequest;
    if (existingRequest != null) {
      final requestSettled = Completer<void>();
      existingRequest.whenComplete(requestSettled.complete).ignore();
      await requestSettled.future;
    }
    return _startWindowListRequest(session, sessionName, key);
  }

  Future<List<TmuxWindow>> _startWindowListRequest(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
  ) {
    final request = _listWindows(session, sessionName, key).timeout(
      _controlResponseTimeout == null
          ? _windowListWatchdogTimeout
          : _controlResponseTimeout * 3,
      onTimeout: () {
        DiagnosticsLogService.instance.warning(
          'monkeymux.watch',
          'window_list_watchdog',
          fields: {'connectionId': session.connectionId},
        );
        throw TimeoutException('MonkeyMux window list timed out.');
      },
    );
    final state = _stateFor(key)..windowListRequest = request;
    request.whenComplete(() {
      if (identical(state.windowListRequest, request)) {
        state.windowListRequest = null;
      }
    }).ignore();
    return request;
  }

  Future<List<TmuxWindow>> _listWindows(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
  ) async {
    final state = _stateFor(key);
    final runtimeToken = state.runtimeToken ??= Object();
    final response = await _runControlCommand(session, sessionName, {
      'type': 'list_windows',
    });
    if (!identical(_states[key]?.runtimeToken, runtimeToken)) {
      return response.windows;
    }
    _cacheWindows(key, response.windows);
    _scheduleAgentMetadataRefresh(session, sessionName, key, response.windows);
    return state.windows ?? response.windows;
  }

  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    if (isAppReviewDemoSession(session)) {
      final state = _appReviewDemoMuxState(key);
      scheduleMicrotask(state.emitWindowList);
      return state.stream;
    }
    final observer = _resolveObserver(session, sessionName, key);
    final cachedWindows = _states[key]?.windows;
    if (cachedWindows != null) {
      _scheduleAgentMetadataRefresh(session, sessionName, key, cachedWindows);
    }
    DiagnosticsLogService.instance.info(
      'monkeymux.watch',
      'watch_requested',
      fields: {
        'connectionId': session.connectionId,
        'observerCount': _states.values
            .where((state) => state.observer != null)
            .length,
      },
    );
    return observer.stream;
  }

  /// Returns the live observer for [key], replacing a disposed one.
  ///
  /// Disposal finishes asynchronously, so a disposed observer keeps its map
  /// entry for a moment. Reusing it would hand the caller a closed stream and a
  /// control channel that can never run another command.
  _MonkeyMuxWindowChangeObserver _resolveObserver(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
  ) {
    final state = _stateFor(key);
    final existing = state.observer;
    if (existing != null && !existing.isDisposed) {
      return existing;
    }
    late final _MonkeyMuxWindowChangeObserver observer;
    observer = _MonkeyMuxWindowChangeObserver(
      session: session,
      sessionName: sessionName,
      installer: _installer,
      onWindowList: (windows) {
        _cacheWindows(key, windows);
        _scheduleAgentMetadataRefresh(session, sessionName, key, windows);
      },
      onServerStatus: (status) => state.serverStatus = status,
      onWindowSnapshot: (window) {
        final cachedWindows = state.windows;
        final forceAgentMetadataRefresh =
            shouldForceAgentSessionMetadataRefreshForSnapshot(
              cachedWindows ?? const <TmuxWindow>[],
              window,
            );
        _cacheWindowSnapshot(key, window);
        final windows = state.windows;
        if (windows != null) {
          _scheduleAgentMetadataRefresh(
            session,
            sessionName,
            key,
            windows,
            force: forceAgentMetadataRefresh,
          );
        }
      },
      onDispose: () {
        // A newer observer may already own this key, and dropping its entry
        // would orphan a live control channel.
        if (!identical(_states[key]?.observer, observer)) return;
        state
          ..observer = null
          ..serverStatus = null
          ..cancelAgentMetadataPeriodicRefresh();
      },
      controlResponseTimeoutOverride: _controlResponseTimeout,
    );
    state.observer = observer;
    return observer;
  }

  @override
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final active = _appReviewDemoMuxState(
        _MonkeyMuxWatchKey(session.connectionId, sessionName),
      ).activeWindow;
      return TmuxPaneContext(
        currentPath: active.currentPath,
        currentCommand: active.currentCommand,
      );
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'query_active_context',
    }, priority: priority);
    return TmuxPaneContext(
      currentPath: trimmedOrNull(response.currentPath),
      currentCommand: trimmedOrNull(response.currentCommand),
    );
  }

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

  @override
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final window = state.createWindow(
        command: command,
        name: name,
        workingDirectory: workingDirectory,
      );
      _replaceCachedWindows(key, state.windows);
      _renderAppReviewDemoWindow(session, window);
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'create_window',
      'clientId': session.monkeyMuxClientId,
      if (command != null && command.trim().isNotEmpty)
        'command': command.trim(),
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        'cwd': workingDirectory.trim(),
    });
  }

  /// Whether the active server explicitly supports bracketed control input.
  bool supportsBracketedPasteControlInput(
    SshSession session,
    String sessionName,
  ) =>
      _states[_MonkeyMuxWatchKey(session.connectionId, sessionName)]
          ?.serverStatus
          ?.supportsBracketedPasteControlInput ??
      false;

  /// Atomically writes [data] to a MonkeyMux window through the framed control
  /// channel.
  ///
  /// Unlike the raw attach stream, a control request cannot split a bracketed-
  /// paste marker across network reads and lose its paste semantics. Returns
  /// false only for the in-process App Review demo, whose terminal input must
  /// continue through the simulated shell.
  Future<bool> injectInput(
    SshSession session,
    String sessionName,
    String data, {
    String? windowId,
    bool bracketedPaste = false,
  }) async {
    if (data.isEmpty) {
      return true;
    }
    if (isAppReviewDemoSession(session)) {
      return false;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'inject_input',
      'clientId': session.monkeyMuxClientId,
      if (windowId != null && windowId.trim().isNotEmpty)
        'windowId': windowId.trim(),
      'data': data,
      if (bracketedPaste) 'bracketedPaste': true,
    });
    return true;
  }

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
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final window = state.selectWindow(windowIndex, windowId: windowId);
      _replaceCachedWindows(key, state.windows);
      _renderAppReviewDemoWindow(session, window);
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'select_window',
      'clientId': session.monkeyMuxClientId,
      if (windowId != null && windowId.trim().isNotEmpty)
        'windowId': windowId.trim()
      else
        'windowIndex': windowIndex,
      if (suppressReplay) 'suppressReplay': true,
      if (clientImageSignatures != null && clientImageSignatures.isNotEmpty)
        'haveImageSignatures': {
          for (final entry in clientImageSignatures.entries)
            entry.key.toString(): entry.value,
        },
    });
  }

  /// Asks the server to replay specific retained Kitty image transmissions the
  /// client is missing for the active window.
  ///
  /// After a window switch or reconnect, the bounded image replay can omit
  /// images the foreground app still shows (it draws placeholder cells that
  /// reference them but never re-transmits the bytes). The client detects those
  /// unresolved ids and calls this so the server replays exactly them from its
  /// per-window retained cache. Best-effort: a failure (e.g. an older server
  /// without this command) is logged and swallowed so image gaps never break
  /// the session.
  Future<MonkeyMuxImageReplayResult> requestImages(
    SshSession session,
    String sessionName,
    Iterable<int> imageIds,
  ) async {
    final requestedIds = {
      for (final id in imageIds)
        if (id > 0) id,
    };
    if (isAppReviewDemoSession(session)) {
      return MonkeyMuxImageReplayResult(
        served: requestedIds,
        retryableFailure: false,
      );
    }
    if (requestedIds.isEmpty) {
      return MonkeyMuxImageReplayResult(
        served: const <int>{},
        retryableFailure: false,
      );
    }
    final pending = {for (final id in requestedIds) id.toString()};
    final served = <int>{};
    try {
      while (pending.isNotEmpty) {
        final response = await _runControlCommand(session, sessionName, {
          'type': 'request_images',
          'clientId': session.monkeyMuxClientId,
          'imageIds': pending.toList(growable: false),
        }, priority: SshExecPriority.low);
        final outcome = resolveMonkeyMuxImageReplayBatchForTesting(
          requested: requestedIds,
          alreadyServed: served,
          acknowledged: response.imagesAcknowledged,
          responseImageIds: response.imageIds,
        );
        if (!response.imagesAcknowledged) {
          return outcome;
        }
        final batch = outcome.served
            .where((id) => !served.contains(id))
            .map((id) => id.toString())
            .toSet();
        if (batch.isEmpty) {
          return outcome;
        }
        pending.removeAll(batch);
        served.addAll(outcome.served);
      }
    } on _MonkeyMuxControlCommandException catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.graphics',
        'request_images_unsupported',
        fields: {
          'connectionId': session.connectionId,
          'count': requestedIds.length,
          'served': served.length,
          'errorType': error.runtimeType.toString(),
        },
      );
      return MonkeyMuxImageReplayResult(
        served: served,
        retryableFailure: false,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.graphics',
        'request_images_failed',
        fields: {
          'connectionId': session.connectionId,
          'count': requestedIds.length,
          'served': served.length,
          'errorType': error.runtimeType.toString(),
        },
      );
      return MonkeyMuxImageReplayResult(served: served, retryableFailure: true);
    }
    return MonkeyMuxImageReplayResult(
      served: served,
      retryableFailure: pending.isNotEmpty,
    );
  }

  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final closed = state.killWindow(windowIndex, windowId: windowId);
      _replaceCachedWindows(key, state.windows);
      if (closed != null) {
        _renderAppReviewDemoWindow(session, state.activeWindow);
      }
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'close_window',
      'clientId': session.monkeyMuxClientId,
      if (windowId != null && windowId.trim().isNotEmpty)
        'windowId': windowId.trim()
      else
        'windowIndex': windowIndex,
    });
  }

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  /// Whether commands for [sessionName] can be sent over an already-open
  /// MonkeyMux control channel.
  ///
  /// When this is true, high-frequency resize updates do not open a new SSH exec
  /// channel per event and can follow pinch-zoom in real time. When false, the
  /// UI should throttle resize syncs to avoid flooding the SSH connection with
  /// one-shot exec channels.
  bool hasLiveControlChannel(SshSession session, String sessionName) =>
      isAppReviewDemoSession(session) ||
      (_states[_MonkeyMuxWatchKey(session.connectionId, sessionName)]
              ?.observer
              ?.isControlChannelReady ??
          false);

  /// Makes this app terminal the active MonkeyMux client and applies its size.
  Future<bool> focusClient(
    SshSession session,
    String sessionName, {
    required int columns,
    required int rows,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return false;
    }
    try {
      final response = await _runControlCommand(session, sessionName, {
        'type': 'focus_client',
        'clientId': session.monkeyMuxClientId,
        'width': columns,
        'height': rows,
        'redraw': true,
      });
      return response.focusChanged;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.focus',
        'claim_failed',
        fields: {
          'connectionId': session.connectionId,
          'columns': columns,
          'rows': rows,
          'errorType': error.runtimeType.toString(),
        },
      );
      return false;
    }
  }

  /// Queries attach ownership through a fresh control process after a server
  /// replacement, bypassing any watcher still connected to the outgoing host.
  Future<bool> hasForegroundClientAfterServerReplacement(
    SshSession session,
    String sessionName,
  ) async {
    if (isAppReviewDemoSession(session)) return true;
    final response = await _runControlCommand(session, sessionName, {
      'type': 'query_attach_state',
      'clientId': session.monkeyMuxClientId,
    }, forceOneShot: true);
    return response.hasForegroundClient;
  }

  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return true;
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'query_attach_state',
      'clientId': session.monkeyMuxClientId,
    });
    return response.hasForegroundClient;
  }

  @override
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) async => null;

  @override
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
    bool forceForegroundRedraw = false,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'theme_changed',
      'data': buildTerminalThemeHintReports(theme),
      if (forceForegroundRedraw) 'redraw': true,
    }, priority: SshExecPriority.low);
  }

  /// Resizes the active MonkeyMux PTY to match the visible terminal.
  Future<void> resizeTerminal(
    SshSession session,
    String sessionName, {
    required int columns,
    required int rows,
    bool redraw = false,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'resize',
      'clientId': session.monkeyMuxClientId,
      'width': columns,
      'height': rows,
      if (redraw) 'redraw': true,
    }, priority: priority);
  }

  @override
  bool get clientCommandsUseControlChannel => true;

  /// Runs a short-lived command through the MonkeyMux control client.
  @override
  Future<TerminalClientCommandResult> runClientCommand(
    SshSession session,
    String sessionName,
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return TerminalClientCommandResult(
        output: 'demo command completed: $command\n',
        exitCode: 0,
      );
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'run_command',
      'command': command,
    }, priority: priority);
    return TerminalClientCommandResult(
      output: response.data ?? '',
      exitCode: response.exitCode,
    );
  }

  /// Starts an ACP bridge directly inside the existing MonkeyMux server.
  ///
  /// This preserves the server's inherited login/security environment without
  /// spawning a second detached helper process.
  Future<TerminalClientCommandResult> startAcpBridge(
    SshSession session,
    String sessionName, {
    required String providerId,
    required String provider,
    required String command,
    required String cwd,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return const TerminalClientCommandResult(
        output: '{"version":1,"type":"started","bridgeId":"00000000000000000000000000000000"}',
        exitCode: 0,
      );
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'start_acp_bridge',
      'providerId': providerId,
      'provider': provider,
      'command': command,
      'cwd': cwd,
    }, priority: priority);
    return TerminalClientCommandResult(
      output: response.data ?? '',
      exitCode: response.exitCode,
    );
  }

  /// Returns metadata for an already-running MonkeyMux server, if any.
  Future<MonkeyMuxServerStatus?> runningServerStatus(
    SshSession session,
    MonkeyMuxInstallation installation,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final controlCommand = _buildMonkeyMuxControlCommand(
      installation,
      sessionName,
    );
    try {
      final status = await session.runQueuedExec(
        () => _readRunningServerStatus(session, controlCommand),
        priority: priority,
      );
      if (status != null) {
        _stateFor(_MonkeyMuxWatchKey(session.connectionId, sessionName))
                .serverStatus =
            status;
      }
      return status;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns the version the installed helper binary reports for itself.
  ///
  /// [MonkeyMuxInstallation.version] is only the packaging label taken from the
  /// bundled manifest, while `attach` decides whether to restart a running
  /// server by comparing it against the version compiled into the binary. The
  /// binary's own answer is therefore the authority on whether an update would
  /// actually happen. Returns null when the probe fails.
  Future<String?> installedHelperVersion(
    SshSession session,
    MonkeyMuxInstallation installation, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final command =
        '${_monkeyMuxQuoteArg(installation.executablePath, windows: installation.isWindows)} '
        'version';
    try {
      final version = await session.runQueuedExec(
        () => _readHelperOutput(session, command),
        priority: priority,
      );
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'helper_version_probed',
        fields: {
          'connectionId': session.connectionId,
          'matchesManifest': version == installation.version.trim(),
        },
      );
      return version;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'helper_version_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns running server status using any already-installed helper version.
  Future<MonkeyMuxServerStatus?> runningServerStatusFromInstalledHelpers(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (session.remoteIsWindows) {
      // This best-effort pre-install probe relies on a POSIX shell glob loop
      // that Windows shells cannot evaluate. Skip it; the version-specific
      // status probe (runningServerStatus) runs after install with the correct
      // Windows quoting, and `attach` still negotiates version mismatches.
      return null;
    }
    final command =
        r'for helper in "$HOME"/.monkeyssh/bin/monkeymux/*/*/monkeymux; do '
        r'[ -x "$helper" ] || continue; '
        r'"$helper" control --json '
        '${shellEscapePosix(sessionName)}'
        ' 2>/dev/null && exit 0; done; exit 1';
    try {
      final status = await session.runQueuedExec(
        () => _readRunningServerStatus(session, command),
        priority: priority,
      );
      if (status == null) {
        return null;
      }
      // Any old helper can dial the workspace socket. Its hello reports the
      // server's version, not the client's, so do not reuse the first helper
      // in glob order. Match the binary's version, not its packaging directory.
      final installation = await _findInstalledHelperForVersion(
        session,
        status.version,
        priority: priority,
      );
      final discoveredStatus = MonkeyMuxServerStatus(
        version: status.version,
        capabilities: status.capabilities,
        nativeAcpWindowCount: status.nativeAcpWindowCount,
        installation: installation,
      );
      _stateFor(_MonkeyMuxWatchKey(session.connectionId, sessionName))
              .serverStatus =
          discoveredStatus;
      return discoveredStatus;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'installed_helper_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  Future<MonkeyMuxInstallation?> _findInstalledHelperForVersion(
    SshSession session,
    String? version, {
    required SshExecPriority priority,
  }) async {
    final runningVersion = version?.trim();
    if (runningVersion == null || runningVersion.isEmpty) {
      return null;
    }
    const helperMarker = '__monkeymux_helper__:';
    final command =
        r'for helper in "$HOME"/.monkeyssh/bin/monkeymux/*/*/monkeymux; do '
        r'[ -x "$helper" ] || continue; '
        r'[ "$("$helper" version 2>/dev/null)" = '
        '${shellEscapePosix(runningVersion)} ] || continue; '
        r'''printf '__monkeymux_helper__:%s\n' "$helper"; '''
        'exit 0; done; exit 1';
    try {
      final executablePath = await session.runQueuedExec(
        () => _readHelperOutput(session, command, outputMarker: helperMarker),
        priority: priority,
      );
      if (executablePath == null) {
        return null;
      }
      final parts = executablePath.split('/');
      if (!executablePath.startsWith('/') ||
          parts.length < 4 ||
          parts.last != 'monkeymux') {
        return null;
      }
      return MonkeyMuxInstallation(
        executablePath: executablePath,
        platform: parts[parts.length - 2],
        version: runningVersion,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'matching_helper_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  Future<_MonkeyMuxControlResponse> _runControlCommand(
    SshSession session,
    String sessionName,
    Map<String, Object?> command, {
    SshExecPriority priority = SshExecPriority.normal,
    bool forceOneShot = false,
  }) async {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    final observer = _states[key]?.observer;
    if (!forceOneShot && observer != null && !observer.isDisposed) {
      return observer.runCommand(command, priority: priority);
    }
    final installation = await _installer.ensureInstalled(
      session,
      priority: priority,
    );
    final controlCommand = _buildMonkeyMuxControlCommand(
      installation,
      sessionName,
    );
    final commandId = _nextControlRequestId();
    final request = <String, Object?>{'id': commandId, ...command};
    return session.runQueuedExec(
      () => _runOneShotControlCommand(
        session,
        controlCommand,
        request,
        onServerStatus: (status) => _stateFor(key).serverStatus = status,
      ),
      priority: priority,
    );
  }

  Future<Map<int, _MonkeyMuxAgentSessionMetadata>?> _loadAgentMetadata(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
    Set<int> panePids,
  ) async {
    if (panePids.isEmpty) {
      return null;
    }

    try {
      DiagnosticsLogService.instance.debug(
        'monkeymux.agent',
        'active_session_metadata_start',
        fields: {
          'connectionId': session.connectionId,
          'paneCount': panePids.length,
        },
      );
      final response = await _runControlCommand(session, sessionName, {
        'type': 'run_command',
        'command': buildAgentActiveSessionMetadataCommand(panePids),
      }, priority: SshExecPriority.low);
      final metadataByPanePid = parseAgentActiveSessionMetadataOutput(
        response.data ?? '',
        panePids,
      );
      _stateFor(key).agentMetadataRefreshedAt = DateTime.now();
      DiagnosticsLogService.instance.info(
        'monkeymux.agent',
        'active_session_metadata_complete',
        fields: {
          'connectionId': session.connectionId,
          'paneCount': panePids.length,
          'matchCount': metadataByPanePid.length,
        },
      );
      return metadataByPanePid;
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.agent',
        'active_session_metadata_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  void _scheduleAgentMetadataRefresh(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
    List<TmuxWindow> windows, {
    bool force = false,
  }) {
    final panePids = _monkeyMuxAgentPanePids(windows);
    if (panePids.isEmpty) {
      _states[key]?.cancelAgentMetadataPeriodicRefresh();
      return;
    }
    final state = _stateFor(key);
    final observer = state.observer;
    if (observer != null) {
      if (!observer.isControlChannelReady) {
        return;
      }
      _ensureAgentMetadataPeriodicRefresh(session, sessionName, key);
    }
    if (state.agentMetadataRequest != null) {
      final activePanePids =
          state.agentMetadataRequestPanePids ?? const <int>{};
      final hasNewPanePids = panePids.any(
        (panePid) => !activePanePids.contains(panePid),
      );
      if (force || hasNewPanePids) {
        state
          ..agentMetadataPendingWindows = windows
          ..agentMetadataPendingForced = true;
      }
      return;
    }
    final lastRefresh = state.agentMetadataRefreshedAt;
    if (!force &&
        lastRefresh != null &&
        DateTime.now().difference(lastRefresh) <
            _agentSessionMetadataFreshTtl) {
      return;
    }
    state.agentMetadataRequestPanePids = panePids;
    late final Future<void> request;
    request = _loadAgentMetadata(session, sessionName, key, panePids).then((
      metadataByPanePid,
    ) {
      if (!identical(state.agentMetadataRequest, request)) {
        return;
      }
      if (metadataByPanePid == null) {
        return;
      }
      final previousWindows = state.windows ?? windows;
      final result = _applyMonkeyMuxAgentSessionMetadata(
        previousWindows,
        metadataByPanePid,
      );
      if (!result.changed) return;
      _replaceCachedWindows(key, result.windows);
      state.observer?.emitWindowList(state.windows ?? result.windows);
    });
    state.agentMetadataRequest = request;
    request.whenComplete(() {
      if (!identical(state.agentMetadataRequest, request)) {
        return;
      }
      final pendingWindows = state.agentMetadataPendingWindows;
      final pendingForced = state.agentMetadataPendingForced;
      state
        ..agentMetadataRequest = null
        ..agentMetadataRequestPanePids = null
        ..agentMetadataPendingWindows = null
        ..agentMetadataPendingForced = false;
      if (pendingWindows != null && pendingWindows.isNotEmpty) {
        _scheduleAgentMetadataRefresh(
          session,
          sessionName,
          key,
          pendingWindows,
          force: pendingForced,
        );
      }
    }).ignore();
  }

  void _ensureAgentMetadataPeriodicRefresh(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
  ) {
    if (_agentSessionMetadataPeriodicRefreshInterval <= Duration.zero) {
      return;
    }
    final state = _stateFor(key)
      ..agentMetadataPeriodicContext = (
        session: session,
        sessionName: sessionName,
      );
    if (state.agentMetadataPeriodicTimer != null) {
      return;
    }
    state.agentMetadataPeriodicTimer = Timer(
      _agentSessionMetadataPeriodicRefreshInterval,
      () {
        state.agentMetadataPeriodicTimer = null;
        final refreshContext = state.agentMetadataPeriodicContext;
        if (refreshContext == null) {
          return;
        }
        final windows = state.windows;
        if (state.observer == null ||
            windows == null ||
            _monkeyMuxAgentPanePids(windows).isEmpty) {
          state.agentMetadataPeriodicContext = null;
          return;
        }
        // Nobody sees the window bar while the app is backgrounded, so keep
        // the host from running ps/lsof probes until it comes back.
        if (_isAppBackgrounded()) {
          _ensureAgentMetadataPeriodicRefresh(
            refreshContext.session,
            refreshContext.sessionName,
            key,
          );
          return;
        }
        _scheduleAgentMetadataRefresh(
          refreshContext.session,
          refreshContext.sessionName,
          key,
          windows,
          force: true,
        );
      },
    );
  }

  static void _cacheWindows(_MonkeyMuxWatchKey key, List<TmuxWindow> windows) {
    final state = _stateFor(key);
    state.windows = windows.isEmpty
        ? const <TmuxWindow>[]
        : applyTmuxWindowChangeEvent(
            state.windows ?? const [],
            TmuxWindowListEvent(windows),
          );
  }

  static void _cacheWindowSnapshot(_MonkeyMuxWatchKey key, TmuxWindow window) {
    final state = _stateFor(key);
    state.windows = applyTmuxWindowChangeEvent(
      state.windows ?? const [],
      TmuxWindowSnapshotEvent(window),
    );
  }

  static void _replaceCachedWindows(
    _MonkeyMuxWatchKey key,
    List<TmuxWindow> windows,
  ) {
    _stateFor(key).windows = List<TmuxWindow>.unmodifiable(windows);
  }
}

/// Everything the service tracks for one (connection, session) pair, so a
/// cache clear or server replacement resets a single object instead of a
/// dozen parallel maps.
class _MonkeyMuxSessionState {
  _MonkeyMuxWindowChangeObserver? observer;
  List<TmuxWindow>? windows;
  MonkeyMuxServerStatus? serverStatus;
  Future<List<TmuxWindow>>? windowListRequest;
  Future<void>? agentMetadataRequest;
  Set<int>? agentMetadataRequestPanePids;
  List<TmuxWindow>? agentMetadataPendingWindows;
  bool agentMetadataPendingForced = false;
  DateTime? agentMetadataRefreshedAt;
  Timer? agentMetadataPeriodicTimer;
  ({SshSession session, String sessionName})? agentMetadataPeriodicContext;
  Object? runtimeToken;
  _AppReviewDemoMonkeyMuxState? appReviewDemo;

  void cancelAgentMetadataPeriodicRefresh() {
    agentMetadataPeriodicTimer?.cancel();
    agentMetadataPeriodicTimer = null;
    agentMetadataPeriodicContext = null;
  }

  /// Forgets everything learned from the current server. The observer, the
  /// runtime token and the demo state outlive a server replacement.
  void resetServerRuntime() {
    cancelAgentMetadataPeriodicRefresh();
    windowListRequest?.ignore();
    agentMetadataRequest?.ignore();
    windows = null;
    serverStatus = null;
    windowListRequest = null;
    agentMetadataRequest = null;
    agentMetadataRequestPanePids = null;
    agentMetadataPendingWindows = null;
    agentMetadataPendingForced = false;
    agentMetadataRefreshedAt = null;
  }

  Future<void> dispose() async {
    appReviewDemo?.dispose();
    appReviewDemo = null;
    runtimeToken = null;
    resetServerRuntime();
    final observer = this.observer;
    this.observer = null;
    await observer?.dispose();
  }
}

({List<TmuxWindow> windows, bool changed}) _applyMonkeyMuxAgentSessionMetadata(
  List<TmuxWindow> windows,
  Map<int, _MonkeyMuxAgentSessionMetadata> metadataByPanePid,
) {
  var changed = false;
  final enriched = windows
      .map((window) {
        final panePid = window.panePid;
        final metadata = panePid == null ? null : metadataByPanePid[panePid];
        if (metadata == null || metadata.tool != window.foregroundAgentTool) {
          return window;
        }
        // The server bound this pane to an exact session file; a ps/lsof or
        // cwd guess from the probe must not displace that identity.
        if (window.activeAgentSessionConfidence ==
                AgentSessionConfidence.high &&
            metadata.confidence != AgentSessionConfidence.high) {
          return window;
        }
        if (window.activeAgentSessionId == metadata.sessionId &&
            window.agentSessionTitle == metadata.title &&
            window.activeAgentSessionConfidence == metadata.confidence) {
          return window;
        }
        changed = true;
        return window
            .copyWith(clearActiveAgentSessionMetadata: true)
            .copyWith(
              activeAgentSessionId: metadata.sessionId,
              agentSessionTitle: metadata.title,
              activeAgentSessionConfidence: metadata.confidence,
            );
      })
      .toList(growable: false);
  return (windows: changed ? enriched : windows, changed: changed);
}

Future<_MonkeyMuxControlResponse> _runOneShotControlCommand(
  SshSession session,
  String command,
  Map<String, Object?> request, {
  ValueChanged<MonkeyMuxServerStatus>? onServerStatus,
}) async {
  final execSession = await openSshExec(
    session.execute(command),
    _controlChannelOpenTimeout,
  );
  final lines = StreamIterator(
    execSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  try {
    execSession.stderr.drain<void>().ignore();
    final requestId = request['id'] as String?;
    execSession.write(utf8.encode('${jsonEncode(request)}\n'));
    return await (() async {
      while (await lines.moveNext()) {
        final line = lines.current;
        final response = _MonkeyMuxControlResponse.tryParse(line);
        if (response == null) {
          continue;
        }
        if (response.type == 'hello') {
          onServerStatus?.call(
            MonkeyMuxServerStatus(
              version: response.version,
              capabilities: response.capabilities.toSet(),
            ),
          );
          continue;
        }
        if (response.id != requestId) {
          continue;
        }
        if (response.isError) {
          throw _MonkeyMuxControlCommandException(
            response.error ?? 'MonkeyMux failed.',
          );
        }
        return response;
      }
      throw const MonkeyMuxInstallException(
        'MonkeyMux control command closed without a response.',
      );
    })().timeout(_oneShotResponseTimeout(request));
  } finally {
    lines.cancel().ignore();
    await _closeMonkeyMuxExecSession(
      execSession,
      ownerSession: session,
      operation: 'one_shot_control',
    );
  }
}

Duration _oneShotResponseTimeout(Map<String, Object?> request) =>
    request['type'] == 'run_command' || request['type'] == 'start_acp_bridge'
    ? _oneShotRunCommandResponseTimeout
    : _oneShotControlResponseTimeout;

Future<MonkeyMuxServerStatus?> _readRunningServerStatus(
  SshSession session,
  String command,
) async {
  final execSession = await openSshExec(
    session.execute(command),
    const Duration(seconds: 5),
  );
  final lines = StreamIterator(
    execSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  MonkeyMuxServerStatus? status;
  try {
    execSession.stderr.drain<void>().ignore();
    return await (() async {
      while (await lines.moveNext()) {
        final line = lines.current;
        final response = _MonkeyMuxControlResponse.tryParse(line);
        if (response == null) {
          continue;
        }
        if (response.type == 'hello') {
          final helloStatus = MonkeyMuxServerStatus(
            version: response.version,
            capabilities: response.capabilities.toSet(),
          );
          status = helloStatus;
          // Helpers without native ACP window support cannot own an in-process
          // bridge, so their hello is already a complete update-safety answer.
          if (!helloStatus.capabilities.contains('acp-window-v1')) {
            return status;
          }
          continue;
        }
        final currentStatus = status;
        if (response.type == 'window_list' && currentStatus != null) {
          return MonkeyMuxServerStatus(
            version: currentStatus.version,
            capabilities: currentStatus.capabilities,
            nativeAcpWindowCount: response.windows
                .where(
                  (window) => window.nativeAcpBridgeId?.isNotEmpty ?? false,
                )
                .length,
          );
        }
      }
      return status;
    })().timeout(const Duration(seconds: 5));
  } on TimeoutException {
    // A transitional helper may advertise ACP support but omit its initial
    // window list. Keep the version answer without claiming an unsafe update
    // is blocked; the helper's own replacement guard remains authoritative.
    return status;
  } finally {
    lines.cancel().ignore();
    await _closeMonkeyMuxExecSession(
      execSession,
      ownerSession: session,
      operation: 'server_status',
    );
  }
}

/// Matches the `major.minor.patch` line `monkeymux version` prints, allowing an
/// optional pre-release or build suffix.
final _monkeyMuxHelperVersionPattern = RegExp(
  r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$',
);

Future<String?> _readHelperOutput(
  SshSession session,
  String command, {
  String? outputMarker,
}) async {
  final execSession = await openSshExec(
    session.execute(command),
    const Duration(seconds: 5),
  );
  final lines = StreamIterator(
    execSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  try {
    execSession.stderr.drain<void>().ignore();
    return await (() async {
      while (await lines.moveNext()) {
        final line = lines.current;
        if (outputMarker != null) {
          if (line.startsWith(outputMarker)) {
            return line.substring(outputMarker.length);
          }
          continue;
        }
        // Login shells can print profile/banner text on stdout before the command
        // output. Treating that as the version would make the comparison
        // unparsable and silently suppress a legitimate update, so only accept
        // lines that actually look like a version and otherwise fall through to
        // the null result, which keeps the bundled manifest label as the answer.
        final version = line.trim();
        if (_monkeyMuxHelperVersionPattern.hasMatch(version)) {
          return version;
        }
      }
      return null;
    })().timeout(const Duration(seconds: 5));
  } on TimeoutException {
    return null;
  } finally {
    lines.cancel().ignore();
    await _closeMonkeyMuxExecSession(
      execSession,
      ownerSession: session,
      operation: outputMarker == null ? 'helper_version' : 'helper_selection',
    );
  }
}

Future<void> _closeMonkeyMuxExecSession(
  SSHSession execSession, {
  required SshSession ownerSession,
  required String operation,
}) => _closeMonkeyMuxSession(
  execSession,
  connectionId: ownerSession.connectionId,
  category: 'monkeymux.control',
  operation: operation,
);

Future<void> _closeMonkeyMuxSession(
  SSHSession session, {
  required int connectionId,
  required String category,
  required String operation,
}) async {
  try {
    await session.stdin.close().timeout(_monkeyMuxSessionStdinCloseTimeout);
  } on TimeoutException {
    DiagnosticsLogService.instance.warning(
      category,
      'stdin_close_timed_out',
      fields: {'connectionId': connectionId, 'operation': operation},
    );
  } on Object catch (error) {
    DiagnosticsLogService.instance.warning(
      category,
      'stdin_close_failed',
      fields: {
        'connectionId': connectionId,
        'operation': operation,
        'errorType': error.runtimeType,
      },
    );
  }

  _closeSshSessionBestEffort(
    session,
    connectionId: connectionId,
    category: category,
    operation: operation,
  );
}

class _MonkeyMuxControlCommandException extends MonkeyMuxInstallException {
  const _MonkeyMuxControlCommandException(super.message);
}

void _closeSshSessionBestEffort(
  SSHSession session, {
  required int connectionId,
  required String category,
  required String operation,
}) {
  void logFailure(Object error) {
    DiagnosticsLogService.instance.warning(
      category,
      'session_close_failed',
      fields: {
        'connectionId': connectionId,
        'operation': operation,
        'errorType': error.runtimeType,
      },
    );
  }

  runZonedGuarded(session.close, (error, _) => logFailure(error));
}

class _MonkeyMuxWindowChangeObserver {
  _MonkeyMuxWindowChangeObserver({
    required this.session,
    required this.sessionName,
    required this.installer,
    required this.onWindowList,
    required this.onServerStatus,
    required this.onWindowSnapshot,
    required this.onDispose,
    this.controlResponseTimeoutOverride,
  }) : _controller = StreamController<TmuxWindowChangeEvent>.broadcast() {
    _controller
      ..onListen = _ensureStarted
      ..onCancel = () => unawaited(dispose());
  }

  final SshSession session;
  final String sessionName;
  final MonkeyMuxInstallerService installer;
  final ValueChanged<List<TmuxWindow>> onWindowList;
  final ValueChanged<MonkeyMuxServerStatus> onServerStatus;
  final ValueChanged<TmuxWindow> onWindowSnapshot;
  final VoidCallback onDispose;

  /// Overrides the per-command control-response timeout in tests. When null,
  /// production timeouts based on the command type are used.
  final Duration? controlResponseTimeoutOverride;
  final StreamController<TmuxWindowChangeEvent> _controller;
  final _normalCommandQueue = Queue<_MonkeyMuxControlRequest>();
  final _lowCommandQueue = Queue<_MonkeyMuxControlRequest>();
  final _pendingCommands = <String, _MonkeyMuxControlRequest>{};

  SSHSession? _controlSession;
  Timer? _reconnectTimer;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _stdoutSubscription;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<void>? _doneSubscription;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  MonkeyMuxInstallation? _installation;
  bool _disposed = false;
  int _reconnectAttempts = 0;
  int _startGeneration = 0;
  DateTime? _lastLineAt;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  /// Deadline for negotiating the control channel, scaled down under the test
  /// override so recovery after a wedged open stays observable.
  Duration get _channelOpenTimeout {
    final override = controlResponseTimeoutOverride;
    return override == null ? _controlChannelOpenTimeout : override * 2;
  }

  bool get isControlChannelReady =>
      !_disposed && !_controller.isClosed && _controlSession != null;

  /// Whether this observer has been torn down and can no longer run commands.
  bool get isDisposed => _disposed;

  /// Reconnects the remote watch process after a helper socket takeover while
  /// keeping this broadcast stream alive for every existing UI consumer.
  Future<void> recycleForServerReplacement(VoidCallback afterCleanup) async {
    if (_disposed) {
      afterCleanup();
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _abandonStartAttempt();
    _failPending(
      const MonkeyMuxInstallException('MonkeyMux server was replaced.'),
      StackTrace.current,
    );
    await _cleanup();
    afterCleanup();
    if (_disposed) return;
    _reconnectAttempts = 0;
    if (_controller.hasListener) {
      await _ensureStarted();
    }
  }

  void emitWindowList(List<TmuxWindow> windows) {
    if (_disposed || _controller.isClosed || windows.isEmpty) {
      return;
    }
    onWindowList(windows);
    _controller.add(TmuxWindowListEvent(windows));
  }

  Future<_MonkeyMuxControlResponse> runCommand(
    Map<String, Object?> command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (_disposed) {
      throw const MonkeyMuxInstallException(
        'MonkeyMux control channel unavailable.',
      );
    }
    final request = _MonkeyMuxControlRequest(command, priority: priority);
    // Arm the deadline before the channel is negotiated. Opening the control
    // session is unbounded, and a request that is disposed or dropped while
    // still queued never reaches the write path, so a timeout armed only when
    // the command is written would leave the caller awaiting forever.
    request.scheduleTimeout(
      controlResponseTimeoutOverride ??
          _oneShotResponseTimeout(request.payload),
      () => _handleRequestTimeout(request),
    );
    switch (priority) {
      case SshExecPriority.normal:
        _normalCommandQueue.add(request);
      case SshExecPriority.low:
        _lowCommandQueue.add(request);
    }
    unawaited(_flushQueuedCommands(request));
    return request.future;
  }

  Future<void> _flushQueuedCommands(_MonkeyMuxControlRequest request) async {
    await _ensureStarted();
    if (request.isCompleted) return;
    if (_disposed || _controlSession == null) {
      _failPending(
        const MonkeyMuxInstallException(
          'MonkeyMux control channel unavailable.',
        ),
        StackTrace.current,
      );
      return;
    }
    _drainCommands();
  }

  Future<void> _ensureStarted() {
    if (_disposed || _controlSession != null) return Future<void>.value();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final existingStart = _startFuture;
    if (existingStart != null) return existingStart;
    final start = _start(++_startGeneration);
    _startFuture = start;
    unawaited(
      start.whenComplete(() {
        if (identical(_startFuture, start)) {
          _startFuture = null;
        }
      }),
    );
    return start;
  }

  /// Drops the in-flight start attempt so the next command opens a new channel.
  ///
  /// Bumping the generation makes the abandoned attempt discard whatever it
  /// eventually produces, so a channel that opens late is closed instead of
  /// being installed over a newer one.
  void _abandonStartAttempt() {
    if (_startFuture == null) return;
    _startGeneration += 1;
    _startFuture = null;
  }

  Future<void> _start(int generation) async {
    try {
      final installation = _installation ??= await installer.ensureInstalled(
        session,
      );
      if (_disposed || generation != _startGeneration) return;
      final command = _buildMonkeyMuxControlCommand(installation, sessionName);
      final controlSession = await openSshExec(
        session.execute(command),
        _channelOpenTimeout,
      );
      if (_disposed || generation != _startGeneration) {
        await _closeControlSession(controlSession, operation: 'start_disposed');
        return;
      }
      _controlSession = controlSession;
      controlSession.stderr.drain<void>().ignore();
      _stdoutSubscription = controlSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onError: _handleError);
      _doneSubscription = controlSession.done.asStream().listen(
        (_) => _handleClosed(),
        onError: _handleError,
      );
      _reconnectAttempts = 0;
      _drainCommands();
      DiagnosticsLogService.instance.info(
        'monkeymux.watch',
        'started',
        fields: {'connectionId': session.connectionId},
      );
    } on Object catch (error, stackTrace) {
      if (generation != _startGeneration) return;
      _handleError(error, stackTrace);
    }
  }

  void _drainCommands() {
    final controlSession = _controlSession;
    if (controlSession == null) return;
    while (_normalCommandQueue.isNotEmpty || _lowCommandQueue.isNotEmpty) {
      final request = _normalCommandQueue.isNotEmpty
          ? _normalCommandQueue.removeFirst()
          : _lowCommandQueue.removeFirst();
      _pendingCommands[request.id] = request;
      try {
        controlSession.write(utf8.encode('${jsonEncode(request.payload)}\n'));
      } on Object catch (error, stackTrace) {
        _pendingCommands.remove(request.id);
        request.completeError(error, stackTrace);
        // Recycling the channel also fails everything still queued behind this
        // command, so there is nothing left to drain.
        _handleError(error, stackTrace);
        return;
      }
    }
  }

  void _handleRequestTimeout(_MonkeyMuxControlRequest request) {
    if (request.isCompleted) return;
    final sent = _pendingCommands.containsKey(request.id);
    final armedAt = request.armedAt;
    final lastLineAt = _lastLineAt;
    final channelSilent =
        armedAt == null || lastLineAt == null || lastLineAt.isBefore(armedAt);
    // The server runs `run_command` asynchronously, so a slow low-priority
    // probe proves nothing about the channel while other lines keep arriving.
    // A normal-priority stall, an unsent request, or a channel that stayed
    // silent for the whole window means it is wedged: fail the in-flight
    // requests and recycle it so the next command runs on a fresh session
    // instead of leaving the UI stuck on a perpetual spinner.
    final recycle =
        request.priority == SshExecPriority.normal || !sent || channelSilent;
    DiagnosticsLogService.instance.warning(
      'monkeymux.watch',
      'request_timeout',
      fields: {
        'connectionId': session.connectionId,
        'sent': sent,
        'disposed': _disposed,
        'recycle': recycle,
      },
    );
    final error = TimeoutException('MonkeyMux control command timed out.');
    final stackTrace = StackTrace.current;
    if (recycle && !_disposed) {
      _handleError(error, stackTrace);
    } else {
      _pendingCommands.remove(request.id);
    }
    // Nothing else completes a request that is still queued or that outlived
    // its observer, so always settle it here.
    request.completeError(error, stackTrace);
  }

  void _handleLine(String line) {
    if (_disposed) return;
    _lastLineAt = DateTime.now();
    final response = _MonkeyMuxControlResponse.tryParse(line);
    if (response == null) return;
    final pendingCommand = _pendingCommands.remove(response.id);
    if (pendingCommand != null) {
      if (response.isError) {
        pendingCommand.completeError(
          _MonkeyMuxControlCommandException(
            response.error ?? 'MonkeyMux failed.',
          ),
          StackTrace.current,
        );
      } else {
        pendingCommand.complete(response);
      }
      return;
    }
    switch (response.type) {
      case 'hello':
        onServerStatus(
          MonkeyMuxServerStatus(
            version: response.version,
            capabilities: response.capabilities.toSet(),
          ),
        );
      case 'window_updated':
      case 'window_added':
        final window = response.window;
        if (window != null && !_controller.isClosed) {
          onWindowSnapshot(window);
          _controller.add(TmuxWindowSnapshotEvent(window));
        }
      case 'window_list':
      case 'active_window_changed':
        onWindowList(response.windows);
        if (!_controller.isClosed) {
          _controller.add(TmuxWindowListEvent(response.windows));
        }
      case 'window_removed':
        if (!_controller.isClosed) {
          _controller.add(const TmuxWindowReloadEvent());
        }
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    DiagnosticsLogService.instance.warning(
      'monkeymux.watch',
      'failed',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
    _failPending(error, stackTrace);
    // A start attempt still in flight may never finish, and every later command
    // would await that same dead future. Abandoning it lets the reconnect below
    // — and the next command — negotiate a fresh channel.
    _abandonStartAttempt();
    unawaited(_cleanup().whenComplete(_scheduleReconnect));
  }

  void _handleClosed() {
    if (_disposed) return;
    _failPending(
      const MonkeyMuxInstallException('MonkeyMux control channel closed.'),
      StackTrace.current,
    );
    unawaited(_cleanup().whenComplete(_scheduleReconnect));
  }

  void _failPending(Object error, StackTrace stackTrace) {
    while (_normalCommandQueue.isNotEmpty) {
      _normalCommandQueue.removeFirst().completeError(error, stackTrace);
    }
    while (_lowCommandQueue.isNotEmpty) {
      _lowCommandQueue.removeFirst().completeError(error, stackTrace);
    }
    for (final request in _pendingCommands.values) {
      request.completeError(error, stackTrace);
    }
    _pendingCommands.clear();
  }

  Future<void> _cleanup() async {
    final stdoutSubscription = _stdoutSubscription;
    final doneSubscription = _doneSubscription;
    final controlSession = _controlSession;
    _stdoutSubscription = null;
    _doneSubscription = null;
    _controlSession = null;
    await Future.wait([
      if (stdoutSubscription != null) stdoutSubscription.cancel(),
      if (doneSubscription != null) doneSubscription.cancel(),
    ]);
    if (controlSession != null) {
      await _closeControlSession(controlSession, operation: 'observer_cleanup');
    }
  }

  Future<void> _closeControlSession(
    SSHSession controlSession, {
    required String operation,
  }) => _closeMonkeyMuxSession(
    controlSession,
    connectionId: session.connectionId,
    category: 'monkeymux.watch',
    operation: operation,
  );

  void _scheduleReconnect() {
    if (_disposed ||
        _controller.isClosed ||
        !_controller.hasListener ||
        _controlSession != null ||
        _startFuture != null ||
        _reconnectTimer != null) {
      return;
    }
    final delay = _nextReconnectDelay();
    _reconnectAttempts += 1;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || _controller.isClosed || !_controller.hasListener) {
        return;
      }
      unawaited(_ensureStarted());
    });
  }

  /// Exponential backoff: 250ms doubling per attempt, capped at 4s.
  Duration _nextReconnectDelay() => Duration(
    milliseconds: 250 << (_reconnectAttempts < 4 ? _reconnectAttempts : 4),
  );

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // Queued and in-flight commands can never receive a response once the
    // channel is gone. Leaving them pending strands their callers — including
    // the window switcher, which then spins forever on a dead reload future.
    _failPending(
      const MonkeyMuxInstallException('MonkeyMux control channel closed.'),
      StackTrace.current,
    );
    await _cleanup();
    if (!_controller.isClosed) {
      await _controller.close();
    }
    onDispose();
  }
}

class _MonkeyMuxControlRequest {
  _MonkeyMuxControlRequest(
    Map<String, Object?> command, {
    required SshExecPriority priority,
  }) : this._(_nextControlRequestId(), command, priority);

  _MonkeyMuxControlRequest._(
    this.id,
    Map<String, Object?> command,
    this.priority,
  ) : payload = {'id': id, ...command};

  final String id;
  final SshExecPriority priority;
  final Map<String, Object?> payload;
  final _completer = Completer<_MonkeyMuxControlResponse>();
  Timer? _timeoutTimer;

  /// When the response deadline was armed; lines received after this point
  /// prove the channel is alive even if this request never completes.
  DateTime? armedAt;

  Future<_MonkeyMuxControlResponse> get future => _completer.future;

  /// Whether this request already resolved with a response or an error.
  bool get isCompleted => _completer.isCompleted;

  /// Arms a one-shot timer that fires when no response arrives in time.
  ///
  /// The control channel is shared across commands, so a lost, dropped, or
  /// unparseable response would otherwise leave this request pending forever
  /// and stall the window switcher on a perpetual spinner.
  void scheduleTimeout(Duration timeout, void Function() onTimeout) {
    if (_timeoutTimer != null) return;
    armedAt = DateTime.now();
    _timeoutTimer = Timer(timeout, onTimeout);
  }

  void complete(_MonkeyMuxControlResponse response) {
    if (!_completer.isCompleted) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      _completer.complete(response);
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      _completer.completeError(error, stackTrace);
    }
  }
}

class _MonkeyMuxControlResponse {
  const _MonkeyMuxControlResponse({
    required this.type,
    required this.status,
    this.id,
    this.error,
    this.window,
    this.windows = const [],
    this.currentPath,
    this.currentCommand,
    this.data,
    this.exitCode,
    this.version,
    this.capabilities = const [],
    this.hasForegroundClient = false,
    this.imageIds = const [],
    this.imagesAcknowledged = false,
    this.focusChanged = false,
  });

  factory _MonkeyMuxControlResponse.fromJson(Map<String, Object?> json) =>
      _MonkeyMuxControlResponse(
        id: json['id'] as String?,
        type: json['type'] as String? ?? '',
        status: json['status'] as String? ?? '',
        error: json['error'] as String?,
        window: _windowFromJson(json['window']),
        windows: switch (json['windows']) {
          final List<Object?> windows =>
            windows
                .map(_windowFromJson)
                .whereType<TmuxWindow>()
                .toList(growable: false),
          _ => const <TmuxWindow>[],
        },
        currentPath: json['currentPath'] as String?,
        currentCommand: json['currentCommand'] as String?,
        data: json['data'] as String?,
        exitCode: json['exitCode'] as int?,
        version: json['version'] as String?,
        capabilities: switch (json['capabilities']) {
          final List<Object?> capabilities =>
            capabilities.whereType<String>().toList(growable: false),
          _ => const <String>[],
        },
        hasForegroundClient: json['hasForegroundClient'] == true,
        imageIds: switch (json['imageIds']) {
          final List<Object?> ids => ids.whereType<String>().toList(
            growable: false,
          ),
          _ => const <String>[],
        },
        imagesAcknowledged: json['imagesAcknowledged'] == true,
        focusChanged: json['focusChanged'] == true,
      );

  static _MonkeyMuxControlResponse? tryParse(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return _MonkeyMuxControlResponse.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  final String? id;
  final String type;
  final String status;
  final String? error;
  final TmuxWindow? window;
  final List<TmuxWindow> windows;
  final String? currentPath;
  final String? currentCommand;
  final String? data;
  final int? exitCode;
  final String? version;
  final List<String> capabilities;
  final bool hasForegroundClient;
  final List<String> imageIds;
  final bool imagesAcknowledged;
  final bool focusChanged;

  bool get isError => status == 'error' || type == 'error';
}

@immutable
class _MonkeyMuxWatchKey {
  const _MonkeyMuxWatchKey(this.connectionId, this.sessionName);

  final int connectionId;
  final String sessionName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _MonkeyMuxWatchKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName;

  @override
  int get hashCode => Object.hash(connectionId, sessionName);
}

_AppReviewDemoMonkeyMuxState _appReviewDemoMuxState(_MonkeyMuxWatchKey key) =>
    MonkeyMuxService._stateFor(key).appReviewDemo ??=
        _AppReviewDemoMonkeyMuxState();

class _AppReviewDemoMonkeyMuxState {
  _AppReviewDemoMonkeyMuxState()
    : _windows = List<_AppReviewDemoWindowSpec>.of(_initialWindows());

  static const _workspace = '/home/reviewer/work/monkeyssh-demo';

  final _controller = StreamController<TmuxWindowChangeEvent>.broadcast();
  final List<_AppReviewDemoWindowSpec> _windows;
  int _activeIndex = 0;
  int _nextId = 10;
  bool _renderedInitial = false;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  TmuxWindow get activeWindow => windows.firstWhere(
    (window) => window.isActive,
    orElse: () => windows.first,
  );

  List<TmuxWindow> get windows => [
    for (var index = 0; index < _windows.length; index += 1)
      _windows[index].toWindow(index: index, isActive: index == _activeIndex),
  ];

  bool consumeInitialRender() {
    if (_renderedInitial) {
      return false;
    }
    _renderedInitial = true;
    return true;
  }

  TmuxWindow createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  }) {
    final tool =
        agentLaunchToolForCommandText(command) ??
        agentLaunchToolForCommandText(name);
    final id = _nextId++;
    final windowName =
        trimmedOrNull(name) ??
        tool?.label ??
        trimmedOrNull(command)?.split(RegExp(r'\s+')).first ??
        'shell $id';
    final spec = _AppReviewDemoWindowSpec(
      id: '@$id',
      panePid: 7300 + id,
      name: windowName,
      currentCommand: tool?.commandName ?? trimmedOrNull(command) ?? 'zsh',
      currentPath: trimmedOrNull(workingDirectory) ?? _workspace,
      paneTitle: tool == null ? windowName : '${tool.label} · demo window',
      agentTool: tool,
      agentSessionTitle: tool == null ? null : 'Demo ${tool.label} session',
    );
    _windows.add(spec);
    _activeIndex = _windows.length - 1;
    emitWindowList();
    return spec.toWindow(index: _activeIndex, isActive: true);
  }

  TmuxWindow selectWindow(int windowIndex, {String? windowId}) {
    final targetIndex = windowId == null
        ? windowIndex
        : _windows.indexWhere((window) => window.id == windowId);
    if (targetIndex >= 0 && targetIndex < _windows.length) {
      _activeIndex = targetIndex;
    }
    emitWindowList();
    return activeWindow;
  }

  TmuxWindow? killWindow(int windowIndex, {String? windowId}) {
    final targetIndex = windowId == null
        ? windowIndex
        : _windows.indexWhere((window) => window.id == windowId);
    if (_windows.length <= 1 ||
        targetIndex < 0 ||
        targetIndex >= _windows.length) {
      return null;
    }
    final closed = _windows.removeAt(targetIndex);
    if (_activeIndex >= _windows.length) {
      _activeIndex = _windows.length - 1;
    } else if (targetIndex < _activeIndex) {
      _activeIndex -= 1;
    }
    emitWindowList();
    return closed.toWindow(index: targetIndex, isActive: false);
  }

  void emitWindowList() {
    if (!_controller.isClosed) {
      _controller.add(TmuxWindowListEvent(windows));
    }
  }

  void dispose() {
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  static List<_AppReviewDemoWindowSpec> _initialWindows() => const [
    _AppReviewDemoWindowSpec(
      id: '@0',
      panePid: 7300,
      name: 'Copilot CLI',
      currentCommand: 'copilot',
      currentPath: _workspace,
      paneTitle: 'Copilot CLI · planning review notes',
      agentTool: AgentLaunchTool.copilotCli,
      agentSessionTitle: 'Planning review notes',
    ),
    _AppReviewDemoWindowSpec(
      id: '@1',
      panePid: 7301,
      name: 'Claude Code',
      currentCommand: 'claude',
      currentPath: _workspace,
      paneTitle: 'Claude Code · running tests',
      agentTool: AgentLaunchTool.claudeCode,
      agentSessionTitle: 'Running focused tests',
    ),
    _AppReviewDemoWindowSpec(
      id: '@2',
      panePid: 7302,
      name: 'OpenCode',
      currentCommand: 'opencode',
      currentPath: '$_workspace/src',
      paneTitle: 'OpenCode · editing README.md',
      agentTool: AgentLaunchTool.openCode,
      agentSessionTitle: 'Editing README.md',
    ),
    _AppReviewDemoWindowSpec(
      id: '@3',
      panePid: 7303,
      name: 'SFTP',
      currentCommand: 'zsh',
      currentPath: _workspace,
      paneTitle: 'SFTP · sample workspace',
    ),
  ];
}

class _AppReviewDemoWindowSpec {
  const _AppReviewDemoWindowSpec({
    required this.id,
    required this.panePid,
    required this.name,
    required this.currentCommand,
    required this.currentPath,
    required this.paneTitle,
    this.agentTool,
    this.agentSessionTitle,
  });

  final String id;
  final int panePid;
  final String name;
  final String currentCommand;
  final String currentPath;
  final String paneTitle;
  final AgentLaunchTool? agentTool;
  final String? agentSessionTitle;

  TmuxWindow toWindow({required int index, required bool isActive}) =>
      TmuxWindow(
        index: index,
        id: id,
        panePid: panePid,
        name: name,
        isActive: isActive,
        currentCommand: currentCommand,
        currentPath: currentPath,
        flags: isActive ? '*' : null,
        paneTitle: paneTitle,
        paneStartCommand: currentCommand,
        agentTool: agentTool,
        activeAgentSessionId: agentTool == null ? null : 'demo-$panePid',
        agentSessionTitle: agentSessionTitle,
        activeAgentSessionConfidence: agentTool == null
            ? null
            : AgentSessionConfidence.medium,
        idleSeconds: isActive ? 2 : 30,
      );
}

void _renderAppReviewDemoWindow(SshSession session, TmuxWindow window) {
  writeAppReviewDemoTerminalOutput(
    session,
    _appReviewDemoWindowScreen(window),
    replaceScreen: true,
    showPrompt: false,
  );
}

String _ansi(String code, String text) => '\x1b[${code}m$text\x1b[0m';

String _appReviewDemoWindowScreen(TmuxWindow window) {
  final title = window.displayTitle;
  final path = window.currentPath ?? '/home/reviewer/work/monkeyssh-demo';
  final tool = window.foregroundAgentTool;
  if (tool == AgentLaunchTool.copilotCli ||
      window.name.toLowerCase().contains('copilot')) {
    return '''
${_ansi('48;5;24;38;5;231;1', ' GitHub Copilot CLI ')} ${_ansi('38;5;245', 'Build · gpt-5.5')}

${_ansi('38;5;39', '┃')} ${_ansi('48;5;235;38;5;231', ' Ask Copilot to build or review code         ')}
${_ansi('38;5;39', '┃')} Review PR #643
${_ansi('38;5;39', '╹')} ${_ansi('38;5;238', '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀')}

${_ansi('38;5;75', '●')} ${_ansi('38;5;252;1', 'Reading workspace')}
  ${_ansi('38;5;70', '✓')} monkeymux_service.dart
  ${_ansi('38;5;70', '✓')} ssh_service.dart

${_ansi('38;5;75', '●')} ${_ansi('38;5;252;1', 'Plan')}
  ${_ansi('38;5;70', '✓')} local MonkeyMux state
  ${_ansi('38;5;70', '✓')} repaint terminal on switch
  ${_ansi('38;5;70', '✓')} deterministic App Review data

${_ansi('48;5;25;38;5;231', ' /deploy ')} ${_ansi('38;5;245', 'ready')}

${_ansi('38;5;245', 'tab agents   ctrl+p commands')}
''';
  }
  if (tool == AgentLaunchTool.claudeCode ||
      window.name.toLowerCase().contains('claude')) {
    return '''
${_ansi('38;5;208;1', '✻ Claude Code v2.1.201')}

${_ansi('38;5;245', 'Welcome back')}
${_ansi('38;5;245', 'Opus 4.8 · /fast')}

${_ansi('38;5;208', '▌')} ${_ansi('38;5;252;1', 'Working directory')}
  ${_ansi('38;5;110', path.replaceFirst('/home/reviewer/', '~/'))}

${_ansi('38;5;208', '●')} Plan
 ${_ansi('38;5;70', '✓')} App Review demo flow
 ${_ansi('38;5;70', '✓')} MonkeyMux windows
 ${_ansi('38;5;70', '✓')} flutter analyze

${_ansi('38;5;245', '──────────── ↯ /fast ─')}
${_ansi('38;5;208', '❯')} Try "make the demo panes feel real"
''';
  }
  if (tool == AgentLaunchTool.openCode ||
      window.name.toLowerCase().contains('opencode')) {
    return '''
${_ansi('48;2;10;10;10;38;2;238;238;238;1', '      OPEN CODE      ')}

${_ansi('38;2;92;156;245', '┃')} ${_ansi('48;2;30;30;30;38;2;128;128;128', 'Ask anything...')}
${_ansi('38;2;92;156;245', '╹')} ${_ansi('38;2;30;30;30', '▀▀▀▀▀▀▀▀▀▀▀▀')}

${_ansi('38;2;92;156;245', 'Build')} ${_ansi('38;5;245', '· Claude Opus 4.8 Fast')}
${_ansi('38;5;245', 'GitHub Copilot provider')}

${_ansi('38;5;36', 'files')}
  README.md
  src/main.dart
  logs/app.log

${_ansi('38;5;36', 'editor  README.md')}
 1 # App Review Demo
 2 Local MonkeyMux panes
 3 switch like real CLIs

${_ansi('38;5;252', 'tab')} ${_ansi('38;5;245', 'agents')}   ${_ansi('38;5;252', 'ctrl+p')} ${_ansi('38;5;245', 'commands')}
''';
  }
  if (tool == AgentLaunchTool.codex ||
      window.name.toLowerCase().contains('codex')) {
    return '''
${_ansi('38;5;51;1', 'Codex CLI (demo)')} ${_ansi('38;5;245', 'gpt-5.3-codex')}

${_ansi('38;5;51', '✨')} ${_ansi('38;5;252;1', 'Task')}
  render local MonkeyMux panes

${_ansi('38;5;51', 'thinking')} inspect live TUI references
${_ansi('38;5;51', 'thinking')} build compact ANSI mock screens

${_ansi('38;5;70', '✓')} service branch added
${_ansi('38;5;70', '✓')} tests cover create/select
${_ansi('38;5;70', '✓')} analyzer clean

${_ansi('48;5;23;38;5;231', ' Patch ready ')}
${_ansi('38;5;245', '› Ask Codex for a follow-up')}
''';
  }
  if (tool == AgentLaunchTool.antigravity ||
      window.name.toLowerCase().contains('antigravity')) {
    return '''
${_ansi('48;5;54;38;5;231;1', ' Antigravity (demo) ')}

${_ansi('38;5;141', 'objective')}
  Verify mobile SSH agents

Workspace
  ${_ansi('38;5;111', '~/work/monkeyssh-demo')}

Status
  ${_ansi('38;5;70', '●')} local demo transport online
  ${_ansi('38;5;70', '●')} MonkeyMux navigator online
  ${_ansi('38;5;70', '●')} pane rendering follows window focus

${_ansi('38;5;245', 'Actions: plan · inspect · patch · verify')}
''';
  }
  return '''
${_ansi('48;5;236;38;5;231;1', ' MonkeySSH SFTP / Shell (demo) ')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}

$path

${_ansi('38;5;33', 'drwxr-xr-x')}  logs
${_ansi('38;5;33', 'drwxr-xr-x')}  screenshots
${_ansi('38;5;33', 'drwxr-xr-x')}  src
${_ansi('38;5;245', '-rw-r--r--')}  144  README.md
${_ansi('38;5;245', '-rw-r--r--')}   68  package.json
${_ansi('38;5;245', '-rwxr-xr-x')}   39  deploy-demo.sh

Tip:
  Tap the folder button to browse the same sample files in SFTP.
''';
}

TmuxWindow? _windowFromJson(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final index = value['index'];
  final active = value['active'];
  final privateModes = _privateModesFromJson(value['privateModes']);
  final terminalReportsMouseWheel =
      (value['terminalReportsMouseWheel'] as bool? ?? false) ||
      _privateModeEnabled(privateModes, '1000') ||
      _privateModeEnabled(privateModes, '1002') ||
      _privateModeEnabled(privateModes, '1003');
  final terminalMouseReportSgr =
      (value['terminalMouseReportSgr'] as bool? ?? false) ||
      _privateModeEnabled(privateModes, '1006');
  final explicitTerminalBracketedPasteMode =
      value['terminalBracketedPasteMode'];
  final terminalBracketedPasteMode = explicitTerminalBracketedPasteMode is bool
      ? explicitTerminalBracketedPasteMode
      : _privateModeValue(privateModes, '2004');
  final storedTool = trimmedOrNull(value['agentTool'] as String?);
  final agentTool = _agentToolFromMonkeyMuxMetadata(storedTool);
  final unsupportedTool =
      agentTool == null &&
      (storedTool != null || value['agentToolConfirmed'] == true);
  final agentSessionId = unsupportedTool
      ? null
      : trimmedOrNull(value['agentSessionId'] as String?);
  // The MonkeyMux server only raises the `#` alert flag when a background
  // window emits a terminal bell (agents ring the bell when they need input),
  // and clears it as soon as the window is selected. Parsing it restores the
  // alert badge and the push notification for prompts/alerts without turning
  // ordinary background output into noisy notifications.
  return TmuxWindow(
    index: index is int ? index : 0,
    id: value['id'] as String?,
    name: value['name'] as String? ?? 'shell',
    isActive: active is bool && active,
    currentCommand: trimmedOrNull(value['currentCommand'] as String?),
    currentPath: trimmedOrNull(value['currentPath'] as String?),
    panePid: value['panePid'] as int?,
    flags: trimmedOrNull(value['flags'] as String?),
    paneTitle: trimmedOrNull(value['paneTitle'] as String?),
    agentTool: agentTool,
    hasUnsupportedAgentTool: unsupportedTool,
    activeAgentSessionId: agentSessionId,
    agentSessionTitle: unsupportedTool
        ? null
        : trimmedOrNull(value['agentSessionTitle'] as String?),
    agentModelProvider: agentTool == AgentLaunchTool.pi
        ? trimmedOrNull(value['agentModelProvider'] as String?)
        : null,
    activeAgentSessionConfidence:
        agentSessionId != null && value['agentSessionIdentityExact'] == true
        ? AgentSessionConfidence.high
        : null,
    nativeAcpBridgeId: trimmedOrNull(value['nativeAcpBridgeId'] as String?),
    nativeAcpProviderId: trimmedOrNull(value['nativeAcpProviderId'] as String?),
    terminalReportsMouseWheel: terminalReportsMouseWheel,
    terminalMouseReportSgr: terminalMouseReportSgr,
    terminalBracketedPasteMode: terminalBracketedPasteMode,
    terminalProgress: _terminalProgressFromJson(value['terminalProgress']),
    lastActivityEpochSeconds: value['lastActivityEpochSeconds'] as int?,
    pendingNotifications: _muxWindowNotificationsFromJson(
      value['notifications'],
    ),
  );
}

/// Parses server-forwarded background notification escapes, tolerating
/// malformed entries so one corrupt record never drops the window.
List<MuxWindowNotification> _muxWindowNotificationsFromJson(Object? value) {
  if (value is! List) return const [];
  final notifications = <MuxWindowNotification>[];
  for (final entry in value) {
    if (entry is! Map<String, Object?>) continue;
    final seq = entry['seq'];
    final payload = entry['payload'];
    if (seq is! int || seq <= 0) continue;
    if (payload is! String || payload.isEmpty) continue;
    late final String text;
    try {
      text = utf8.decode(base64Decode(payload), allowMalformed: true);
    } on FormatException {
      continue;
    }
    notifications.add(MuxWindowNotification(seq: seq, payload: text));
  }
  return notifications;
}

TerminalProgress? _terminalProgressFromJson(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
  final state = switch (value['state']) {
    1 => TerminalProgressState.normal,
    2 => TerminalProgressState.error,
    3 => TerminalProgressState.indeterminate,
    4 => TerminalProgressState.pausedOrWarning,
    _ => null,
  };
  if (state == null) {
    return null;
  }
  final rawPercentage = value['percentage'];
  if (rawPercentage != null &&
      (rawPercentage is! int || rawPercentage < 0 || rawPercentage > 100)) {
    return null;
  }
  final percentage = rawPercentage as int?;
  if (state == TerminalProgressState.normal && percentage == null) {
    return null;
  }
  return TerminalProgress(state: state, percentage: percentage);
}

Map<String, bool> _privateModesFromJson(Object? value) {
  if (value is! Map<String, Object?>) {
    return const <String, bool>{};
  }
  final privateModes = <String, bool>{};
  for (final entry in value.entries) {
    final modeValue = entry.value;
    if (modeValue is bool) {
      privateModes[entry.key] = modeValue;
    }
  }
  return privateModes;
}

bool _privateModeEnabled(Map<String, bool> privateModes, String mode) =>
    privateModes[mode] ?? false;

bool? _privateModeValue(Map<String, bool> privateModes, String mode) =>
    privateModes.containsKey(mode) ? privateModes[mode] : null;

/// Agent panes worth probing: the server already names the exact session for
/// windows reported with high confidence, so the probe adds nothing there.
Set<int> _monkeyMuxAgentPanePids(Iterable<TmuxWindow> windows) => windows
    .where(
      (window) =>
          window.foregroundAgentTool != null &&
          window.panePid != null &&
          window.activeAgentSessionConfidence != AgentSessionConfidence.high,
    )
    .map((window) => window.panePid!)
    .toSet();

/// Whether the app is backgrounded. A missing binding (plain unit tests)
/// counts as foreground.
bool _appIsBackgrounded() {
  try {
    return switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => false,
      _ => true,
    };
  } on Object {
    return false;
  }
}

/// Parses a MonkeyMux window snapshot for protocol regression tests.
@visibleForTesting
TmuxWindow? parseMonkeyMuxWindowSnapshotForTesting(Object? value) =>
    _windowFromJson(value);

/// Returns whether a MonkeyMux window list contains panes needing agent probes.
@visibleForTesting
bool shouldRefreshMonkeyMuxAgentMetadataForTesting(
  Iterable<TmuxWindow> windows,
) => _monkeyMuxAgentPanePids(windows).isNotEmpty;

/// Applies live agent metadata to MonkeyMux windows for regression tests.
@visibleForTesting
List<TmuxWindow> applyMonkeyMuxAgentMetadataForTesting(
  List<TmuxWindow> windows,
  String output,
) {
  final panePids = windows.map((window) => window.panePid).nonNulls.toSet();
  return _applyMonkeyMuxAgentSessionMetadata(
    windows,
    parseAgentActiveSessionMetadataOutput(output, panePids),
  ).windows;
}

/// Parses a MonkeyMux attach-state response for protocol regression tests.
@visibleForTesting
bool? parseMonkeyMuxHasForegroundClientForTesting(String line) =>
    _MonkeyMuxControlResponse.tryParse(line)?.hasForegroundClient;

/// Parses a MonkeyMux image-replay acknowledgement for protocol tests.
@visibleForTesting
({bool acknowledged, List<String> imageIds})?
parseMonkeyMuxImageReplayAckForTesting(String line) {
  final response = _MonkeyMuxControlResponse.tryParse(line);
  if (response == null) {
    return null;
  }
  return (
    acknowledged: response.imagesAcknowledged,
    imageIds: response.imageIds,
  );
}

/// Parses whether a MonkeyMux focus response changed the primary client.
@visibleForTesting
bool? parseMonkeyMuxFocusChangedForTesting(String line) =>
    _MonkeyMuxControlResponse.tryParse(line)?.focusChanged;

/// Returns the one-shot control response timeout for protocol regression tests.
@visibleForTesting
Duration monkeyMuxOneShotResponseTimeoutForTesting(
  Map<String, Object?> request,
) => _oneShotResponseTimeout(request);

AgentLaunchTool? _agentToolFromMonkeyMuxMetadata(String? value) =>
    agentLaunchToolForCommandName(value);

/// Quotes a single MonkeyMux command argument for the remote shell. POSIX hosts
/// use single-quote escaping; Windows hosts use [_windowsQuoteArg], which
/// follows the CommandLineToArgvW parsing rules so embedded quotes and trailing
/// backslashes survive (helper path, session name, working directory, launch
/// command).
String _monkeyMuxQuoteArg(String value, {required bool windows}) =>
    windows ? _windowsQuoteArg(value) : shellEscapePosix(value);

/// Quotes [value] as a single Windows argument following the
/// CommandLineToArgvW / C runtime rules (the same algorithm as Go's
/// `syscall.EscapeArg`). Backslashes are only significant immediately before a
/// double quote, and a run of backslashes preceding a quote (or the closing
/// quote) is doubled. This correctly handles values containing spaces, embedded
/// double quotes (for example `python -c "print(1)"`) and trailing backslashes
/// (for example `C:\src\`), which naive `"$value"` wrapping would corrupt.
String _windowsQuoteArg(String value) {
  if (value.isEmpty) {
    return '""';
  }
  var needsQuotes = false;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0x20 || unit == 0x09) {
      needsQuotes = true;
      break;
    }
  }
  final buffer = StringBuffer();
  if (needsQuotes) {
    buffer.write('"');
  }
  var backslashes = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    switch (unit) {
      case 0x5c: // backslash
        backslashes++;
        buffer.writeCharCode(unit);
      case 0x22: // double quote
        buffer
          ..write(r'\' * (backslashes + 1))
          ..writeCharCode(unit);
        backslashes = 0;
      default:
        backslashes = 0;
        buffer.writeCharCode(unit);
    }
  }
  if (needsQuotes) {
    buffer
      ..write(r'\' * backslashes)
      ..write('"');
  }
  return buffer.toString();
}

/// Builds the `<helper> control --json <session>` command for an installation,
/// quoting for the installed platform's shell.
String _buildMonkeyMuxControlCommand(
  MonkeyMuxInstallation installation,
  String sessionName,
) {
  final windows = installation.isWindows;
  return '${_monkeyMuxQuoteArg(installation.executablePath, windows: windows)} '
      'control --json '
      '${_monkeyMuxQuoteArg(sessionName, windows: windows)}';
}
