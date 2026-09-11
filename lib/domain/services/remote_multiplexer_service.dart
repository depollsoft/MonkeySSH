import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

/// Common app-side surface for remote terminal multiplexers.
abstract interface class RemoteMultiplexerService {
  /// Returns the detected backend version for the active remote multiplexer.
  ///
  /// The returned value excludes the backend name and is null when the version
  /// cannot be determined without disrupting the active terminal.
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Returns the current window list for [sessionName].
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Watches remote window state changes for [sessionName].
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Returns the active pane context, if the backend can report one.
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  });

  /// Returns the active pane path, if available.
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  });

  /// Creates a new remote window.
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  });

  /// Selects a remote window.
  ///
  /// [clientImageSignatures] maps Kitty image ids the client already holds to
  /// their content signature, so a backend that replays retained images (e.g.
  /// MonkeyMux) can skip re-transmitting ones the client can render from cache.
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
    bool suppressReplay = false,
  });

  /// Closes a remote window.
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
  });

  /// Returns whether short-lived exec control is cooling down.
  bool isExecChannelCoolingDown(SshSession session);

  /// Verifies whether the visible terminal is attached to [sessionName].
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Returns the foreground multiplexer session name, if any.
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  });

  /// Refreshes visible clients after a theme change.
  ///
  /// When [forceForegroundRedraw] is true, the multiplexer should force the
  /// active foreground TUI to fully repaint after delivering the theme hint,
  /// so agents that diff-repaint (e.g. Copilot CLI) re-emit explicitly-colored
  /// regions in the new theme instead of leaving stale "black bars".
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
    bool forceForegroundRedraw = false,
  });
}

/// tmux service provider for generic multiplexer consumers.
final tmuxRemoteMultiplexerServiceProvider = Provider<RemoteMultiplexerService>(
  (ref) => ref.watch(tmuxServiceProvider),
);
