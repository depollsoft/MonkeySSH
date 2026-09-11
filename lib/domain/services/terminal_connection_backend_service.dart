import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/remote_multiplexer.dart';
import '../models/terminal_backend.dart';
import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'monkeymux_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'remote_multiplexer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Provides backend adapters for active terminal sessions.
final terminalConnectionBackendServiceProvider =
    Provider<TerminalConnectionBackendService>(
      (ref) => TerminalConnectionBackendService(
        tmuxMultiplexer: ref.watch(tmuxRemoteMultiplexerServiceProvider),
        monkeyMuxService: ref.watch(monkeyMuxServiceProvider),
      ),
    );

/// Common control surface for direct, tmux, and MonkeyMux terminals.
abstract interface class TerminalConnectionBackend {
  /// Backend kind for diagnostics and behavior gates.
  TerminalBackendType get type;

  /// Backend capability set.
  TerminalBackendCapabilities get capabilities;

  /// Attached remote multiplexer backend, if any.
  RemoteMuxBackend? get remoteMuxBackend;

  /// Attached remote multiplexer session name, if any.
  String? get sessionName;

  /// Attached remote multiplexer service, if this backend supports windows.
  RemoteMultiplexerService? get remoteMultiplexer;

  /// Backend-specific tmux client flags, if any.
  String? get extraFlags;

  /// Returns the active pane/shell context, if available.
  Future<TmuxPaneContext?> currentPaneContext({
    SshExecPriority priority = SshExecPriority.normal,
  });

  /// Returns the active pane/shell path, if available.
  Future<String?> currentPanePath({
    SshExecPriority priority = SshExecPriority.normal,
  });

  /// Runs a short-lived client command using the best backend channel.
  Future<TerminalClientCommandResult> runClientCommand(
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
    String? workingDirectory,
  });

  /// Refreshes visible clients after a theme change.
  Future<void> refreshTerminalTheme(TerminalThemeData theme);

  /// Creates a new backend window.
  Future<void> createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  });

  /// Selects a backend window.
  ///
  /// [clientImageSignatures] optionally maps Kitty image ids the client already
  /// holds to their content signature so an image-replaying backend can skip
  /// re-transmitting them.
  Future<void> selectWindow(
    int windowIndex, {
    String? windowId,
    Map<int, int>? clientImageSignatures,
    bool suppressReplay = false,
  });

  /// Closes a backend window.
  Future<void> killWindow(int windowIndex, {String? windowId});

  /// Returns whether short-lived control operations are cooling down.
  bool isExecChannelCoolingDown();
}

/// Resolves backend adapters for active SSH sessions.
class TerminalConnectionBackendService {
  /// Creates a terminal backend resolver.
  const TerminalConnectionBackendService({
    required RemoteMultiplexerService tmuxMultiplexer,
    required MonkeyMuxService monkeyMuxService,
  }) : _tmuxMultiplexer = tmuxMultiplexer,
       _monkeyMuxService = monkeyMuxService;

  final RemoteMultiplexerService _tmuxMultiplexer;
  final MonkeyMuxService _monkeyMuxService;

  /// Resolves the active backend for [session].
  TerminalConnectionBackend resolve(
    SshSession session, {
    RemoteMuxBackend? activeMuxBackend,
    String? sessionName,
    String? tmuxExtraFlags,
  }) {
    final backend = activeMuxBackend ?? session.remoteMuxBackend;
    final muxSessionName =
        _nonEmpty(sessionName) ?? _nonEmpty(session.remoteMuxSessionName);

    if (backend == null || muxSessionName == null) {
      return _DirectTerminalConnectionBackend(session);
    }

    return switch (backend) {
      RemoteMuxBackend.monkeyMux => _MultiplexedTerminalConnectionBackend(
        session: session,
        type: TerminalBackendType.monkeyMux,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        sessionName: muxSessionName,
        remoteMultiplexer: _monkeyMuxService,
        monkeyMuxService: _monkeyMuxService,
      ),
      RemoteMuxBackend.tmux => _MultiplexedTerminalConnectionBackend(
        session: session,
        type: TerminalBackendType.tmux,
        remoteMuxBackend: RemoteMuxBackend.tmux,
        sessionName: muxSessionName,
        remoteMultiplexer: _tmuxMultiplexer,
        extraFlags: tmuxExtraFlags,
      ),
      RemoteMuxBackend.auto => _DirectTerminalConnectionBackend(session),
    };
  }
}

class _DirectTerminalConnectionBackend implements TerminalConnectionBackend {
  const _DirectTerminalConnectionBackend(this._session);

  static const _capabilities = TerminalBackendCapabilities(
    supportsWindows: false,
    supportsClientCommands: true,
    clientCommandsUseControlChannel: false,
  );

  final SshSession _session;

  @override
  TerminalBackendType get type => TerminalBackendType.direct;

  @override
  TerminalBackendCapabilities get capabilities => _capabilities;

  @override
  RemoteMuxBackend? get remoteMuxBackend => null;

  @override
  String? get sessionName => null;

  @override
  RemoteMultiplexerService? get remoteMultiplexer => null;

  @override
  String? get extraFlags => null;

  @override
  Future<TmuxPaneContext?> currentPaneContext({
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final currentPath = resolveTerminalWorkingDirectoryPath(
      _session.workingDirectory,
    );
    if (currentPath == null || currentPath.isEmpty) {
      return null;
    }
    return TmuxPaneContext(currentPath: currentPath);
  }

  @override
  Future<String?> currentPanePath({
    SshExecPriority priority = SshExecPriority.normal,
  }) async => (await currentPaneContext(priority: priority))?.currentPath;

  @override
  Future<TerminalClientCommandResult> runClientCommand(
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
    String? workingDirectory,
  }) => _runSshClientCommand(
    _session,
    _wrapClientCommandWorkingDirectory(command, workingDirectory),
    priority: priority,
  );

  @override
  Future<void> refreshTerminalTheme(TerminalThemeData theme) async {
    // Direct terminals receive app theme responses through the foreground PTY.
  }

  @override
  Future<void> createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  }) => Future<void>.error(
    UnsupportedError('Direct terminal sessions do not support windows.'),
  );

  @override
  Future<void> selectWindow(
    int windowIndex, {
    String? windowId,
    Map<int, int>? clientImageSignatures,
    bool suppressReplay = false,
  }) => Future<void>.error(
    UnsupportedError('Direct terminal sessions do not support windows.'),
  );

  @override
  Future<void> killWindow(int windowIndex, {String? windowId}) =>
      Future<void>.error(
        UnsupportedError('Direct terminal sessions do not support windows.'),
      );

  @override
  bool isExecChannelCoolingDown() => false;
}

class _MultiplexedTerminalConnectionBackend
    implements TerminalConnectionBackend {
  const _MultiplexedTerminalConnectionBackend({
    required SshSession session,
    required TerminalBackendType type,
    required RemoteMuxBackend remoteMuxBackend,
    required String sessionName,
    required RemoteMultiplexerService remoteMultiplexer,
    MonkeyMuxService? monkeyMuxService,
    String? extraFlags,
  }) : _session = session,
       _type = type,
       _remoteMuxBackend = remoteMuxBackend,
       _sessionName = sessionName,
       _remoteMultiplexer = remoteMultiplexer,
       _monkeyMuxService = monkeyMuxService,
       _extraFlags = extraFlags;

  static const _tmuxCapabilities = TerminalBackendCapabilities(
    supportsWindows: true,
    supportsClientCommands: true,
    clientCommandsUseControlChannel: false,
  );

  static const _monkeyMuxCapabilities = TerminalBackendCapabilities(
    supportsWindows: true,
    supportsClientCommands: true,
    clientCommandsUseControlChannel: true,
  );

  final SshSession _session;
  final TerminalBackendType _type;
  final RemoteMuxBackend _remoteMuxBackend;
  final String _sessionName;
  final RemoteMultiplexerService _remoteMultiplexer;
  final MonkeyMuxService? _monkeyMuxService;
  final String? _extraFlags;

  @override
  TerminalBackendType get type => _type;

  @override
  TerminalBackendCapabilities get capabilities =>
      _type == TerminalBackendType.monkeyMux
      ? _monkeyMuxCapabilities
      : _tmuxCapabilities;

  @override
  RemoteMuxBackend get remoteMuxBackend => _remoteMuxBackend;

  @override
  String get sessionName => _sessionName;

  @override
  RemoteMultiplexerService get remoteMultiplexer => _remoteMultiplexer;

  @override
  String? get extraFlags => _extraFlags;

  @override
  Future<TmuxPaneContext?> currentPaneContext({
    SshExecPriority priority = SshExecPriority.normal,
  }) => _remoteMultiplexer.currentPaneContext(
    _session,
    _sessionName,
    priority: priority,
    extraFlags: _extraFlags,
  );

  @override
  Future<String?> currentPanePath({
    SshExecPriority priority = SshExecPriority.normal,
  }) => _remoteMultiplexer.currentPanePath(
    _session,
    _sessionName,
    priority: priority,
    extraFlags: _extraFlags,
  );

  @override
  Future<TerminalClientCommandResult> runClientCommand(
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
    String? workingDirectory,
  }) {
    final commandToRun = _wrapClientCommandWorkingDirectory(
      command,
      workingDirectory,
    );
    final monkeyMuxService = _monkeyMuxService;
    if (_type == TerminalBackendType.monkeyMux && monkeyMuxService != null) {
      return monkeyMuxService.runClientCommand(
        _session,
        _sessionName,
        commandToRun,
        priority: priority,
      );
    }
    return _runSshClientCommand(_session, commandToRun, priority: priority);
  }

  @override
  Future<void> refreshTerminalTheme(TerminalThemeData theme) =>
      _remoteMultiplexer.refreshTerminalTheme(
        _session,
        _sessionName,
        theme,
        extraFlags: _extraFlags,
      );

  @override
  Future<void> createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  }) => _remoteMultiplexer.createWindow(
    _session,
    _sessionName,
    command: command,
    name: name,
    workingDirectory: workingDirectory,
    extraFlags: _extraFlags,
  );

  @override
  Future<void> selectWindow(
    int windowIndex, {
    String? windowId,
    Map<int, int>? clientImageSignatures,
    bool suppressReplay = false,
  }) => _remoteMultiplexer.selectWindow(
    _session,
    _sessionName,
    windowIndex,
    windowId: windowId,
    extraFlags: _extraFlags,
    clientImageSignatures: clientImageSignatures,
    suppressReplay: suppressReplay,
  );

  @override
  Future<void> killWindow(int windowIndex, {String? windowId}) =>
      _remoteMultiplexer.killWindow(
        _session,
        _sessionName,
        windowIndex,
        windowId: windowId,
        extraFlags: _extraFlags,
      );

  @override
  bool isExecChannelCoolingDown() =>
      _remoteMultiplexer.isExecChannelCoolingDown(_session);
}

/// Runs [command] on a short-lived exec channel and collects its output.
///
/// [command] must already carry any working-directory wrapping.
Future<TerminalClientCommandResult> _runSshClientCommand(
  SshSession session,
  String command, {
  required SshExecPriority priority,
}) => session.runQueuedExec(() async {
  final exec = await openSshExec(
    session.execute(command),
    const Duration(seconds: 10),
  );
  try {
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutFuture = exec.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .forEach(stdout.write);
    final stderrFuture = exec.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .forEach(stderr.write);
    await Future.wait<void>([stdoutFuture, stderrFuture, exec.done]);
    final stdoutText = stdout.toString();
    return TerminalClientCommandResult(
      output: stdoutText.isNotEmpty ? stdoutText : stderr.toString(),
    );
  } finally {
    exec.close();
  }
}, priority: priority);

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _wrapClientCommandWorkingDirectory(String command, String? directory) {
  final cwd = _nonEmpty(directory);
  if (cwd == null) {
    return command;
  }
  return 'cd ${shellEscapePosix(cwd)} && ( $command )';
}
