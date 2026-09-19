// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/remote_multiplexer_service.dart';
import '../../domain/services/ssh_service.dart';

class MuxBadgeController extends ChangeNotifier {
  MuxBadgeController({
    required this.getSession,
    required this.resolveBackend,
    required this.resolveSessionName,
    required this.serviceForBackend,
    required this.extraFlags,
    required this.onWindowsChanged,
    required this.disconnect,
  });
  final SshSession? Function() getSession;
  final RemoteMuxBackend Function(SshSession) resolveBackend;
  final Future<String?> Function(SshSession, RemoteMuxBackend)
  resolveSessionName;
  final RemoteMultiplexerService Function(RemoteMuxBackend) serviceForBackend;
  final String? Function() extraFlags;
  final void Function(List<TmuxWindow>?) onWindowsChanged;
  final Future<void> Function(SshSession) disconnect;
  static const _tmuxQueryRetryDelay = Duration(seconds: 2);
  bool _disposed = false;
  bool get mounted => !_disposed;
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
  int _windowEventGeneration = 0;
  int _tmuxQueryGeneration = 0;

  Future<void> _retryTmuxQuery(
    int retries, {
    required int expectedGeneration,
  }) async {
    if (!_isCurrentTmuxQuery(expectedGeneration)) {
      return;
    }
    if (retries <= 0) {
      _change(() => queried = true);
      _scheduleTmuxRetry();
      return;
    }
    await Future<void>.delayed(_tmuxQueryRetryDelay);
    if (_isCurrentTmuxQuery(expectedGeneration)) {
      await queryTmux(retries: retries - 1);
    }
  }

  void _scheduleTmuxRetry() {
    if (_tmuxRetryTimer?.isActive ?? false) return;
    _tmuxRetryTimer = Timer(const Duration(seconds: 10), () {
      _tmuxRetryTimer = null;
      if (mounted) {
        unawaited(queryTmux());
      }
    });
  }

  Future<void> queryTmux({int retries = 3}) async {
    final queryGeneration = ++_tmuxQueryGeneration;
    final session = getSession();
    if (session == null) {
      onWindowsChanged(null);
      // Session not available yet — retry after a delay so the badge
      // still appears for connections that finish establishing shortly.
      await _retryTmuxQuery(retries, expectedGeneration: queryGeneration);
      return;
    }

    final muxBackend = resolveBackend(session);
    final mux = serviceForBackend(muxBackend);
    final sessionName = await resolveSessionName(session, muxBackend);
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    if (sessionName == null) {
      onWindowsChanged(null);
      await _retryTmuxQuery(retries, expectedGeneration: queryGeneration);
      return;
    }
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
    _windowReloadGeneration += 1;
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final nextWindows = applyTmuxWindowChangeEvent(currentWindows, event);
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
    try {
      final mux = serviceForBackend(muxBackend);
      final windows = await mux.listWindows(
        session,
        sessionName,
        extraFlags: muxBackend == RemoteMuxBackend.tmux ? extraFlags() : null,
      );
      if (!_isCurrentTmuxQuery(queryGeneration)) {
        return;
      }
      if (reloadGeneration < _windowReloadGeneration) return;
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
        _tmuxRetryTimer?.cancel();
        _tmuxRetryTimer = null;
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
