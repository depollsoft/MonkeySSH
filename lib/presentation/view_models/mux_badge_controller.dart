// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/remote_multiplexer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart' show isAppInForeground;

class MuxBadgeController extends ChangeNotifier {
  MuxBadgeController({
    required this.getSession,
    required this.resolveBackend,
    required this.resolveSessionName,
    required this.serviceForBackend,
    required this.extraFlags,
    required this.onWindowsChanged,
    required this.disconnect,
    this.isAppForeground = isAppInForeground,
    this.retryInitialDelay = const Duration(seconds: 2),
    this.retryMaxDelay = const Duration(seconds: 60),
  });
  final SshSession? Function() getSession;
  final RemoteMuxBackend Function(SshSession) resolveBackend;
  final Future<String?> Function(SshSession, RemoteMuxBackend)
  resolveSessionName;
  final RemoteMultiplexerService Function(RemoteMuxBackend) serviceForBackend;
  final String? Function() extraFlags;
  final void Function(List<TmuxWindow>?) onWindowsChanged;
  final Future<void> Function(SshSession) disconnect;

  /// Probes pause while this returns false; the retry timer keeps waiting.
  final bool Function() isAppForeground;

  /// First retry delay after a negative or failed query; later retries double
  /// up to [retryMaxDelay].
  final Duration retryInitialDelay;
  final Duration retryMaxDelay;
  bool _disposed = false;
  bool get mounted => !_disposed;

  Future<void>? _sessionEndHold;

  /// Makes an ended session's disconnect wait until the returned callback
  /// runs, so closing the last window can still use the connection, for
  /// example to offer removing the window's worktree. MonkeyMux announces the
  /// empty window list before it answers the close. The callback may run
  /// more than once.
  void Function() holdSessionEnd() {
    final hold = Completer<void>();
    _sessionEndHold = hold.future;
    return () {
      if (hold.isCompleted) return;
      hold.complete();
      if (identical(_sessionEndHold, hold.future)) {
        _sessionEndHold = null;
      }
    };
  }

  void _change(VoidCallback change) {
    change();
    notifyListeners();
  }

  bool _isCurrentTmuxQuery(int generation) =>
      mounted && generation == _tmuxQueryGeneration;

  void invalidateQuery() {
    _tmuxQueryGeneration++;
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final subscription = _windowChangeSubscription;
    _windowChangeSubscription = null;
    unawaited(subscription?.cancel());
    _muxSessionEnding = false;
    _retryAttempt = 0;
    _negativeMuxIdentity = null;
    windows = null;
    sessionName = null;
    queried = false;
    loadingWindows = false;
    _pendingWindowReload = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _tmuxRetryTimer?.cancel();
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  List<TmuxWindow>? windows;
  String? sessionName;
  RemoteMuxBackend muxBackend = RemoteMuxBackend.tmux;
  bool queried = false;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  Timer? _tmuxRetryTimer;
  bool loadingWindows = false;
  bool _pendingWindowReload = false;
  bool _muxSessionEnding = false;
  int _windowReloadGeneration = 0;
  List<TmuxWindowSnapshotEvent>? _snapshotsDuringReload;
  int _windowEventGeneration = 0;
  int _tmuxQueryGeneration = 0;
  int _retryAttempt = 0;

  /// The session's mux identity when the last negative answer was recorded.
  /// Once the retry delay has reached [retryMaxDelay] the answer is settled:
  /// no further remote probe runs until this identity changes.
  (RemoteMuxBackend?, String?)? _negativeMuxIdentity;

  Duration get _retryDelay => resolveTmuxWindowReloadRetryDelay(
    _retryAttempt,
    initialDelay: retryInitialDelay,
    maxDelay: retryMaxDelay,
  );

  bool get _isNegativeAnswerSettled {
    final identity = _negativeMuxIdentity;
    if (identity == null || _retryDelay < retryMaxDelay) return false;
    final session = getSession();
    return session != null && _muxIdentity(session) == identity;
  }

  static (RemoteMuxBackend?, String?) _muxIdentity(SshSession session) =>
      (session.remoteMuxBackend, session.remoteMuxSessionName);

  void _recordNegativeAnswer(int queryGeneration, SshSession? session) {
    if (!_isCurrentTmuxQuery(queryGeneration)) return;
    onWindowsChanged(null);
    _negativeMuxIdentity = session == null ? null : _muxIdentity(session);
    _change(() => queried = true);
    _scheduleTmuxRetry();
  }

  void _scheduleTmuxRetry() {
    if (_tmuxRetryTimer?.isActive ?? false) return;
    _tmuxRetryTimer = Timer(_retryDelay, () {
      _tmuxRetryTimer = null;
      if (!mounted) return;
      if (!isAppForeground() || _isNegativeAnswerSettled) {
        // Keep waiting without touching the host; a resumed app or a changed
        // mux identity is picked up on a later tick.
        _scheduleTmuxRetry();
        return;
      }
      _retryAttempt += 1;
      unawaited(queryTmux());
    });
  }

  Future<void> queryTmux() async {
    final queryGeneration = ++_tmuxQueryGeneration;
    final session = getSession();
    if (session == null) {
      // Session not available yet; retry so the badge still appears for
      // connections that finish establishing shortly.
      _recordNegativeAnswer(queryGeneration, null);
      return;
    }

    final muxBackend = resolveBackend(session);
    final mux = serviceForBackend(muxBackend);
    final sessionName = await resolveSessionName(session, muxBackend);
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    if (sessionName == null) {
      _recordNegativeAnswer(queryGeneration, session);
      return;
    }
    _negativeMuxIdentity = null;
    this.muxBackend = muxBackend;

    await _windowChangeSubscription?.cancel();
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    final generation = ++_windowEventGeneration;
    _windowChangeSubscription = mux
        .watchWindowChanges(
          session,
          sessionName,
          extraFlags: muxBackend == RemoteMuxBackend.tmux ? extraFlags() : null,
        )
        .listen((event) {
          if (!_isCurrentTmuxQuery(queryGeneration)) return;
          _handleWindowChangeEvent(
            session,
            sessionName,
            event,
            generation,
            muxBackend,
            queryGeneration,
          );
        });
    await _refreshTmuxWindows(
      session,
      sessionName,
      muxBackend: muxBackend,
      queryGeneration: queryGeneration,
    );
  }

  void _handleWindowChangeEvent(
    SshSession session,
    String sessionName,
    TmuxWindowChangeEvent event,
    int generation,
    RemoteMuxBackend muxBackend,
    int queryGeneration,
  ) {
    if (!mounted || !_isCurrentTmuxQuery(queryGeneration)) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      _refreshTmuxWindows(
        session,
        sessionName,
        muxBackend: muxBackend,
        queryGeneration: queryGeneration,
      );
      return;
    }
    if (event is TmuxWindowListEvent) {
      _windowReloadGeneration += 1;
      _tmuxRetryTimer?.cancel();
      _tmuxRetryTimer = null;
      if (event.windows.isEmpty && muxBackend == RemoteMuxBackend.monkeyMux) {
        _change(() {
          windows = const <TmuxWindow>[];
          this.sessionName = sessionName;
          this.muxBackend = muxBackend;
          queried = true;
        });
        onWindowsChanged(const <TmuxWindow>[]);
        unawaited(disconnectEndedMonkeyMuxSession(session));
        return;
      }
      final currentWindows = windows;
      final nextWindows = currentWindows == null
          ? event.windows
          : applyTmuxWindowChangeEvent(currentWindows, event);
      if (identical(nextWindows, currentWindows) &&
          this.sessionName == sessionName &&
          this.muxBackend == muxBackend) {
        return;
      }
      _change(() {
        windows = nextWindows;
        this.sessionName = sessionName;
        this.muxBackend = muxBackend;
        queried = true;
      });
      onWindowsChanged(nextWindows);
      return;
    }
    final currentWindows = windows;
    if (currentWindows == null) {
      _refreshTmuxWindows(
        session,
        sessionName,
        muxBackend: muxBackend,
        queryGeneration: queryGeneration,
      );
      return;
    }
    // A per-window snapshot cannot remove a closed window, so an in-flight
    // reload still decides membership; the snapshot is replayed onto it.
    _snapshotsDuringReload?.add(event as TmuxWindowSnapshotEvent);
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final nextWindows = applyTmuxWindowChangeEvent(currentWindows, event);
    if (identical(nextWindows, currentWindows) &&
        this.sessionName == sessionName &&
        this.muxBackend == muxBackend) {
      return;
    }
    _change(() {
      windows = nextWindows;
      this.sessionName = sessionName;
      this.muxBackend = muxBackend;
      queried = true;
    });
    onWindowsChanged(nextWindows);
  }

  Future<void> _refreshTmuxWindows(
    SshSession session,
    String sessionName, {
    required RemoteMuxBackend muxBackend,
    required int queryGeneration,
  }) async {
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    if (loadingWindows) {
      _pendingWindowReload = true;
      return;
    }
    loadingWindows = true;
    final reloadGeneration = ++_windowReloadGeneration;
    final snapshots = _snapshotsDuringReload = <TmuxWindowSnapshotEvent>[];
    try {
      final mux = serviceForBackend(muxBackend);
      final listed = await mux.listWindows(
        session,
        sessionName,
        extraFlags: muxBackend == RemoteMuxBackend.tmux ? extraFlags() : null,
      );
      if (!_isCurrentTmuxQuery(queryGeneration)) {
        return;
      }
      if (reloadGeneration < _windowReloadGeneration) return;
      final windows = snapshots.fold(listed, applyTmuxWindowChangeEvent);
      if (windows.isEmpty && muxBackend == RemoteMuxBackend.monkeyMux) {
        _tmuxRetryTimer?.cancel();
        _tmuxRetryTimer = null;
        _change(() {
          this.windows = const <TmuxWindow>[];
          this.sessionName = sessionName;
          this.muxBackend = muxBackend;
          queried = true;
        });
        onWindowsChanged(const <TmuxWindow>[]);
        await disconnectEndedMonkeyMuxSession(session);
        return;
      }
      if (windows.isEmpty) {
        _scheduleTmuxRetry();
      } else {
        _retryAttempt = 0;
        _tmuxRetryTimer?.cancel();
        _tmuxRetryTimer = null;
      }
      if (identical(windows, this.windows) &&
          this.sessionName == sessionName &&
          this.muxBackend == muxBackend) {
        return;
      }
      _change(() {
        this.windows = windows;
        this.sessionName = sessionName;
        this.muxBackend = muxBackend;
        queried = true;
      });
      onWindowsChanged(windows);
    } on Object {
      if (!_isCurrentTmuxQuery(queryGeneration)) {
        return;
      }
      _scheduleTmuxRetry();
      _change(() {
        queried = true;
      });
    } finally {
      loadingWindows = false;
      if (identical(_snapshotsDuringReload, snapshots)) {
        _snapshotsDuringReload = null;
      }
      if (_pendingWindowReload && mounted) {
        _pendingWindowReload = false;
        unawaited(
          _isCurrentTmuxQuery(queryGeneration)
              ? _refreshTmuxWindows(
                  session,
                  sessionName,
                  muxBackend: muxBackend,
                  queryGeneration: queryGeneration,
                )
              : queryTmux(),
        );
      }
    }
  }

  Future<void> disconnectEndedMonkeyMuxSession(SshSession session) async {
    if (_muxSessionEnding) {
      return;
    }
    _muxSessionEnding = true;
    final hold = _sessionEndHold;
    if (hold != null) {
      await hold;
    }
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'monkeymux_badge_disconnect',
      fields: {'connectionId': session.connectionId},
    );
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final subscription = _windowChangeSubscription;
    _windowChangeSubscription = null;
    await subscription?.cancel();
    await disconnect(session);
  }
}
