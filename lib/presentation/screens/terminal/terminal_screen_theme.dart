part of '../terminal_screen.dart';

/// Terminal theme application, TUI color refresh, and tmux theme synchronization.
extension _TerminalScreenTheme on _TerminalScreenState {
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
    final didThemeChange = previousTheme != null && previousTheme != theme;
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

  /// Whether a foreground TUI has enabled any mode a real TUI uses. When none
  /// is set the foreground is almost certainly a shell prompt, so neither a
  /// plain-terminal theme refresh nor an outer-tmux focus report is safe: if
  /// the user detached tmux while [_isTmuxActive] still reads true, synthetic
  /// focus bytes would reach the bare shell as typed input.
  bool _shouldRefreshPlainTerminalTui(SshSession session) =>
      session.terminalColorSchemeUpdatesMode ||
      _terminal.reportFocusMode ||
      _terminal.isUsingAltBuffer ||
      _terminal.mouseMode != MouseMode.none;

  bool _shouldSuppressMonkeyMuxTerminalControlInput(String output) =>
      shouldSuppressMonkeyMuxControlReport(
        isMonkeyMux: _activeMuxBackend == RemoteMuxBackend.monkeyMux,
        // A prompt click is a report the shell asked for (OSC 133
        // click_events), sent with mouse tracking off on purpose.
        isMouseReport:
            !isWritingPromptClick &&
            _terminalMouseReportOutputPattern.hasMatch(output),
        isFocusReport: _terminalFocusReportOutputPattern.hasMatch(output),
        mouseReportingActive: _terminalReportsMouseWheelForScroll,
        focusReportingActive: _terminal.reportFocusMode,
        isAgentToolActive: _isAgentToolActive,
        currentCommand: _tmuxCurrentCommand,
      );

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
      _TerminalScreenState._tmuxWindowThemeRefreshDebounceDelay +
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
      if (!_shouldRefreshPlainTerminalTui(request.session)) {
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
      // The TUI that justified these reports may have exited during the
      // delay; a bare shell would read them as typed input.
      if (!_shouldRefreshPlainTerminalTui(session)) {
        DiagnosticsLogService.instance.info(
          'terminal.theme',
          'late_refresh_skipped',
          fields: {
            'reason': reason,
            'connectionId': session.connectionId,
            'isTmuxActive': _isTmuxActive,
            'focusMode': _terminal.reportFocusMode,
            'altBuffer': _terminal.isUsingAltBuffer,
            'mouseMode': _terminal.mouseMode != MouseMode.none,
          },
        );
        return;
      }
      // DEC 2031 reports are only solicited while the mode is still on. The
      // Windows default-color path is gated by the palette query above.
      final colorSchemeUpdates = session.terminalColorSchemeUpdatesMode;
      final sendThemeMode = includeThemeModeReport && colorSchemeUpdates;
      final sendDefaults =
          includeDefaultColorReports &&
          (colorSchemeUpdates || requirePaletteQuerySince != null);
      if (!sendThemeMode && !sendDefaults && !includeFocusReport) {
        return;
      }
      _refreshTerminalThemeReportsForTui(
        theme,
        includeThemeModeReport: sendThemeMode,
        includeDefaultColorReports: sendDefaults,
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
        activeTheme == theme;
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
}
