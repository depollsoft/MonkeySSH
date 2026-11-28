part of '../terminal_screen.dart';

/// Shared clipboard sync, selection actions, paste/upload flows, and snippet insertion.
extension _TerminalScreenClipboard on _TerminalScreenState {
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
      _setLastObservedRemoteClipboardText(remoteText);
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
        _TerminalScreenState._localClipboardSyncInterval,
        (_) => unawaited(_syncLocalClipboardToRemote(session)),
      );
    }
    _remoteClipboardSyncTimer = Timer.periodic(
      _TerminalScreenState._remoteClipboardSyncInterval,
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
        _stopSharedClipboardSync();
        return;
      }
      _lastObservedLocalClipboardText = localText;
      _setLastObservedRemoteClipboardText(localText);
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
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
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
          _setLastObservedRemoteClipboardText(remoteText);
        }
        return;
      }

      final remoteClipboardText = remoteText;
      if (remoteClipboardText == null) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: remoteClipboardText));
      if (!_ownsClipboardSync(session, generation)) return;
      _setLastObservedRemoteClipboardText(remoteClipboardText);
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
      RemoteClipboardSyncService.buildReadCommand(
        expectedSha256: _lastObservedRemoteClipboardSha256,
      ),
    );
    if (!_ownsClipboardSync(session, generation)) return null;
    final parsed = RemoteClipboardSyncService.parseReadOutput(output);
    if (!parsed.supported) {
      _remoteClipboardUnsupported = true;
      _stopSharedClipboardSync();
      return null;
    }
    if (parsed.unchanged) {
      return _lastObservedRemoteClipboardText;
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
      extra: buildSnippetPrefillFromTerminalSelection(command),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied')));
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  int? _resolveOriginalTerminalPathMatchEnd({
    required NormalizedTerminalPathSnapshot normalizedSnapshot,
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

  /// Verifies that [pasteMode] still owns the active terminal context, targets
  /// [inputTarget] (and optionally matches [previousMode]), and has a usable
  /// bracketed-paste state. Logs, restores focus, and returns `false` on any
  /// mismatch.
  bool _validateTerminalPasteMode(
    _TerminalPasteMode pasteMode, {
    required Object inputTarget,
    _TerminalPasteMode? previousMode,
    bool checkUsable = true,
  }) {
    if (previousMode != null) {
      if (!_sameTerminalPasteContext(previousMode, pasteMode) ||
          pasteMode.activeWindowKey != previousMode.activeWindowKey ||
          !_terminalPasteModeOwnsCurrentContext(pasteMode)) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_window_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return false;
      }
    } else {
      if (!_terminalPasteModeOwnsCurrentContext(pasteMode)) {
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_context_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return false;
      }
      if (!_terminalPasteModeTargetsCurrentWindow(pasteMode) ||
          _terminalInputTarget != inputTarget) {
        _syncTerminalModesFromActiveMuxWindow();
        DiagnosticsLogService.instance.warning(
          'terminal.clipboard',
          'text_input_skipped_window_changed',
          fields: {'connectionId': _connectionId},
        );
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
        return false;
      }
    }
    if (checkUsable && !_terminalPasteModeCanUseResolvedState(pasteMode)) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'text_input_skipped_mode_unavailable',
        fields: {'connectionId': _connectionId},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(
        'Could not verify bracketed paste mode. Try again.',
      );
      return false;
    }
    return true;
  }

  /// Pastes the clipboard into the terminal. [promptText], when given, is
  /// pasted instead of the clipboard, through the same review.
  Future<void> _pasteClipboard({String? promptText}) async {
    var inputGeneration = _terminalUserInputGeneration;
    // Whatever path the paste takes, it goes only where it was asked for.
    final inputTarget = _terminalInputTarget;
    try {
      if (promptText == null && _mayPasteAsKittyPasteEvent()) {
        final usualPathGeneration = await _pasteClipboardAsKittyPasteEvent(
          inputGeneration,
          inputTarget,
        );
        if (usualPathGeneration == null) {
          return;
        }
        inputGeneration = usualPathGeneration;
      }
      if (_isAndroidPlatform && promptText == null) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes, inputTarget: inputTarget);
          return;
        }
      }

      final clipboardFiles = promptText == null
          ? await Pasteboard.files()
          : const <String>[];
      if (clipboardFiles.isNotEmpty) {
        await _pasteClipboardFiles(clipboardFiles, inputTarget: inputTarget);
        return;
      }

      if (!_isAndroidPlatform && promptText == null) {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          await _pasteClipboardImage(imageBytes, inputTarget: inputTarget);
          return;
        }
      }

      final text = promptText ?? await _readSystemClipboardText();
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
      if (!_validateTerminalPasteMode(pasteMode, inputTarget: inputTarget)) {
        return;
      }

      // A shell prompt always reviews. A hunk prompt is also reviewed in any
      // other program that is not a known agent (psql, a REPL, a nested
      // shell), where a line break without bracketed paste runs a line.
      final requiredReview =
          _shouldReviewTerminalCommandInsertion ||
          (promptText != null && !_isAgentToolActive);
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
            title: promptText == null
                ? 'Review clipboard paste'
                : 'Review prompt paste',
            messageBuilder: (review) => review.bracketedPasteModeEnabled
                ? 'This ${promptText == null ? 'clipboard content' : 'prompt'} looks risky even with bracketed paste enabled.'
                : 'This ${promptText == null ? 'clipboard content' : 'prompt'} could execute multiple or reshaped commands.',
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
          if (!_validateTerminalPasteMode(
            refreshedPasteMode,
            inputTarget: inputTarget,
            previousMode: pasteMode,
          )) {
            return;
          }
          pasteMode = refreshedPasteMode;
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
      if (!_validateTerminalPasteMode(
        pasteMode,
        inputTarget: inputTarget,
        checkUsable: false,
      )) {
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
              source: promptText == null
                  ? 'clipboard_text'
                  : 'working_tree_hunk',
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

  /// A cheap first check for [_pasteClipboardAsKittyPasteEvent], so a paste
  /// into a program that never set mode 5522 takes the usual path without an
  /// extra MonkeyMux round trip. The settled paste mode decides.
  bool _mayPasteAsKittyPasteEvent() {
    final isMuxActive =
        _isTmuxActive && _tmuxStateConnectionId == _connectionId;
    if (isMuxActive && _activeMuxBackend == RemoteMuxBackend.monkeyMux) {
      return _terminal.kittyPasteEventsMode ||
          resolveTmuxBarActiveWindowKittyPasteEventsMode(
                _currentTmuxWindowsSnapshot,
              ) ==
              true;
    }
    return shouldSendTerminalKittyPasteEvent(
      isMuxActive: isMuxActive,
      muxBackend: _activeMuxBackend,
      terminalKittyPasteEventsMode: _terminal.kittyPasteEventsMode,
      activeWindowKittyPasteEventsMode: null,
    );
  }

  /// Announces the clipboard to a program that set kitty paste events (mode
  /// 5522): it gets the clipboard's MIME types and reads the one it wants,
  /// and an image travels in-band instead of being uploaded over SFTP.
  ///
  /// Returns null when the paste was dealt with here. Otherwise it should
  /// take the usual text or attachment path, which checks for intervening
  /// input against the returned input generation: the mode is off once
  /// settled or was turned off before the event went out, or the clipboard
  /// holds files or an image too large for the protocol.
  Future<int?> _pasteClipboardAsKittyPasteEvent(
    int inputGeneration,
    Object inputTarget,
  ) async {
    final pasteMode = await _resolveSettledTerminalPasteMode();
    if (pasteMode == null || !mounted) {
      if (mounted) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      }
      return null;
    }
    final session = pasteMode.session;
    if (session == null ||
        !pasteMode.sendsKittyPasteEvents ||
        !_terminalPasteModeOwnsCurrentContext(pasteMode) ||
        !_terminalPasteModeCanUseResolvedState(pasteMode)) {
      return inputGeneration;
    }
    // The program can turn paste events off (`CSI ? 5522 l`) while the
    // clipboard is read or the event waits its turn. The terminal sees that
    // first. MonkeyMux decides by the window's mode, which the terminal
    // follows for the active window (unless it never had it) and the window
    // list reports once it refreshes.
    final terminal = pasteMode.terminal;
    final terminalHadMode = terminal.kittyPasteEventsMode;
    bool stillEnabled() {
      if (!pasteMode.isMuxActive) {
        return terminal.kittyPasteEventsMode;
      }
      return (!terminalHadMode || terminal.kittyPasteEventsMode) &&
          resolveTmuxBarActiveWindowKittyPasteEventsMode(
                _currentTmuxWindowsSnapshot,
              ) !=
              false;
    }

    final clipboard = await session.kittyClipboard.platform.readPasteSnapshot();
    final snapshot = clipboard.snapshot;
    if (clipboard.useAttachmentFlow || snapshot == null) {
      return inputGeneration;
    }
    if (!mounted) {
      return null;
    }
    if (snapshot.isEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Clipboard is empty');
      return null;
    }
    if (!_terminalPasteModeOwnsCurrentContext(pasteMode) ||
        !_terminalPasteModeTargetsCurrentWindow(pasteMode) ||
        _terminalInputTarget != inputTarget) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'paste_event_skipped_window_changed',
        fields: {'connectionId': _connectionId},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      return null;
    }
    if (_terminalUserInputGeneration != inputGeneration) {
      DiagnosticsLogService.instance.warning(
        'terminal.clipboard',
        'paste_event_skipped_intervening_input',
        fields: {'connectionId': _connectionId},
      );
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Paste canceled because terminal input changed.');
      return null;
    }
    if (!stillEnabled()) {
      return inputGeneration;
    }
    _followLiveOutput();
    final pasteGeneration = ++_terminalUserInputGeneration;
    final result = await session.kittyClipboard.sendPasteEvent(
      snapshot,
      // The event can wait behind a clipboard request still being answered;
      // by then the user may have moved to another window or typed, or the
      // program turned paste events off.
      stillTargeted: () =>
          mounted &&
          _terminalUserInputGeneration == pasteGeneration &&
          _terminalPasteModeOwnsCurrentContext(pasteMode) &&
          _terminalPasteModeTargetsCurrentWindow(pasteMode) &&
          _terminalInputTarget == inputTarget,
      stillEnabled: stillEnabled,
    );
    if (result == KittyClipboardPasteEventResult.skipped) {
      if (mounted) {
        _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      }
      return null;
    }
    if (result == KittyClipboardPasteEventResult.disabled) {
      // Nothing was sent, and no other input came since the event was due.
      return pasteGeneration;
    }
    unawaited(
      ref
          .read(telemetryServiceProvider)
          .logTerminalPasteUsed(
            source: 'clipboard_event',
            requiredReview: false,
          ),
    );
    if (!mounted) {
      return null;
    }
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (result == KittyClipboardPasteEventResult.failed) {
      _showClipboardMessage('Paste failed because the connection is closed.');
    }
    return null;
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
    _pathVerifier.disposeTerminalPathVerificationSftp();
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
    required Object inputTarget,
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
    if (!_terminalPasteModeTargetsCurrentWindow(pasteMode) ||
        _terminalInputTarget != inputTarget) {
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
        if (!_terminalPasteModeTargetsCurrentWindow(pasteMode) ||
            _terminalInputTarget != inputTarget) {
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

  /// Uploads [clipboardFiles] and pastes their remote paths into
  /// [inputTarget], the input target the paste was asked for in.
  Future<void> _pasteClipboardFiles(
    List<String> clipboardFiles, {
    required Object inputTarget,
  }) async {
    final shouldUpload = await _confirmClipboardUpload(
      title: 'Upload clipboard files?',
      message:
          'This will upload ${clipboardFiles.length} clipboard file${clipboardFiles.length == 1 ? '' : 's'} to $_clipboardUploadDirectoryDisplay on the connected host and paste their remote paths into the terminal.',
      confirmLabel: 'Upload and paste',
      details: [
        for (var index = 0; index < clipboardFiles.length; index++)
          if (clipboardFiles[index].startsWith('content://'))
            'Clipboard file ${index + 1}'
          else
            path.basename(clipboardFiles[index]),
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
      inputTarget: inputTarget,
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

  /// Uploads [imageBytes] and pastes its remote path into [inputTarget], the
  /// input target the paste was asked for in, or by default the one current
  /// once the upload is confirmed.
  Future<bool> _pasteClipboardImage(
    Uint8List imageBytes, {
    Duration? autoConfirmAfter,
    bool showKeyboardAfterPaste = true,
    String? uploadBaseDirectory,
    Object? inputTarget,
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
    final target = inputTarget ?? _terminalInputTarget;
    final pasteMode = await _resolveSettledTerminalPasteMode();
    final uploadGeneration = _beginPasteUpload(
      TerminalPasteUploadProgress(
        uploadedBytes: 0,
        totalBytes: imageBytes.length,
      ),
    );
    final ({String path, bool windows}) remotePath;
    try {
      remotePath = await _withClipboardSftp((
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
          onProgress: (uploadedBytes) => _updatePasteUpload(
            uploadGeneration,
            (current) => current.copyWith(uploadedBytes: uploadedBytes),
          ),
        );
        return (
          path: uploadTarget.terminalPathForSftpPath(remotePath),
          windows: uploadTarget.windows,
        );
      }, uploadBaseDirectory: uploadBaseDirectory);
    } finally {
      _endPasteUpload(uploadGeneration);
    }
    _followLiveOutput();
    final pasteResult = await _insertUploadedFileReferences(
      [remotePath.path],
      windows: remotePath.windows,
      inputGeneration: inputGeneration,
      inputTarget: target,
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

  /// Uploads [selectedFiles] and pastes their remote paths into
  /// [inputTarget] when given, otherwise into the input target current once
  /// the upload is confirmed.
  Future<void> _pasteSelectedFiles(
    List<PlatformFile> selectedFiles, {
    required String itemLabelSingular,
    required String itemLabelPlural,
    bool confirm = true,
    String telemetrySource = 'picked_files',
    Object? inputTarget,
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
    final target = inputTarget ?? _terminalInputTarget;
    final pasteMode = await _resolveSettledTerminalPasteMode();
    final timestamp = DateTime.now();
    // Size the whole batch up front so the line reads as one upload rather
    // than restarting per file; any unknown size makes it indeterminate.
    final fileLengths = [
      for (final file in selectedFiles)
        await resolvePickedTerminalUploadLength(file),
    ];
    final batchTotalBytes = fileLengths.contains(null)
        ? null
        : fileLengths.fold<int>(0, (sum, length) => sum + length!);
    final uploadGeneration = _beginPasteUpload(
      TerminalPasteUploadProgress(
        uploadedBytes: 0,
        totalBytes: batchTotalBytes,
      ),
    );
    var completedBytes = 0;
    final ({List<String> paths, bool windows}) remotePaths;
    try {
      remotePaths = await _withClipboardSftp((
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
            buildClipboardUploadFileName(
              sourceName,
              timestamp,
              sequence: index,
            ),
          );
          await remoteFileService.uploadStream(
            sftp: sftp,
            remotePath: remotePath,
            stream: resolvePickedTerminalUploadReadStream(file),
            applyPrivateMode: uploadTarget.applyPrivateFileMode,
            onProgress: (uploadedBytes) => _updatePasteUpload(
              uploadGeneration,
              (current) => current.copyWith(
                uploadedBytes: completedBytes + uploadedBytes,
              ),
            ),
          );
          completedBytes += fileLengths[index] ?? 0;
          remotePaths.add(uploadTarget.terminalPathForSftpPath(remotePath));
        }
        return (paths: remotePaths, windows: uploadTarget.windows);
      });
    } finally {
      _endPasteUpload(uploadGeneration);
    }

    _followLiveOutput();
    final pasteResult = await _insertUploadedFileReferences(
      remotePaths.paths,
      windows: remotePaths.windows,
      inputGeneration: inputGeneration,
      inputTarget: target,
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
    if (!_shouldReviewTerminalCommandInsertion) {
      return true;
    }
    final shouldInsert = await _confirmCommandInsertion(
      title: 'Review keyboard paste',
      message: 'This text inserted from your keyboard could execute multiple or reshaped commands.',
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
      messageBuilder: (_) => 'This text inserted from your keyboard could execute multiple or reshaped commands.',
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

    _updateState(() {
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

  Future<void> _pasteClipboardIntoFind(TerminalSearchFieldInput field) async {
    final text = await _readSystemClipboardText();
    if (!mounted) {
      return;
    }
    if (text == null || text.isEmpty) {
      _showClipboardMessage('Clipboard has no text to paste.');
      return;
    }
    field.pasteText(text);
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

  /// Inserts [selectedSnippet]'s command, with its variables filled in,
  /// through [insert]: the native chat's composer or the find field. Neither
  /// can hold a key press, so a snippet with key tokens is refused.
  Future<void> _insertKeyboardToolbarSnippet(
    KeyboardToolbarSnippet selectedSnippet,
    ValueChanged<String> insert,
  ) async {
    final repository = ref.read(snippetRepositoryProvider);
    final tokensReady = await repository.keyTokensReady();
    final snippet = await repository.getById(selectedSnippet.id);
    if (!mounted) {
      return;
    }
    if (snippet == null) {
      _showClipboardMessage('Snippet is no longer available.');
      return;
    }
    final sequence = tokensReady
        ? parseSnippetKeySequence(snippet.command)
        : SnippetKeySequence.literal(snippet.command);
    if (sequence.needsTerminal) {
      _showClipboardMessage(
        'This snippet presses keys, so it only works when typing into the '
        'terminal.',
      );
      return;
    }
    final substitution = await _substituteVariables(context, snippet);
    if (!mounted || substitution == null || substitution.command.isEmpty) {
      return;
    }
    insert(sequence.withVariables(substitution.values).plainText);
    unawaited(repository.incrementUsage(snippet.id));
  }

  Future<void> _pasteKeyboardToolbarSnippet(
    KeyboardToolbarSnippet selectedSnippet,
  ) async {
    final snippetRepo = ref.read(snippetRepositoryProvider);
    // Until stored snippets are upgraded for key tokens, an old `{key:esc}`
    // is text and must be pasted as text.
    final tokensReady = await snippetRepo.keyTokensReady();
    final snippet = await snippetRepo.getById(selectedSnippet.id);
    if (!mounted) {
      return;
    }
    if (snippet == null) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage('Snippet is no longer available.');
      return;
    }
    final parsedSequence = tokensReady
        ? parseSnippetKeySequence(snippet.command)
        : SnippetKeySequence.literal(snippet.command);
    if (parsedSequence.errors.isNotEmpty) {
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      _showClipboardMessage(parsedSequence.errors.first);
      return;
    }

    final substitution = await _substituteVariables(context, snippet);
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    if (substitution == null || substitution.command.isEmpty) {
      return;
    }
    final sequence = parsedSequence.withVariables(substitution.values);
    final reviewMode = sequence.hasActions
        ? snippetKeySequenceReviewMode(
            shellStatus: _shellStatus,
            isUsingAltBuffer: _isUsingAltBuffer,
            isAgentToolActive: _isAgentToolActive,
          )
        : SnippetReviewMode.full;

    final shouldInsert =
        reviewMode == SnippetReviewMode.none ||
        await _confirmTerminalInsertionIfNeeded(
          insertedText: sequence.hasActions
              ? sequence.reviewText
              : sequence.plainText,
          buildReview: (commandText) =>
              sequence.hasActions && commandText.trim().isEmpty
              // Only Enter on an empty line: there is no command to review.
              ? TerminalCommandReview(command: commandText, reasons: const [])
              : reviewForSnippetMode(
                  assessSnippetCommandInsertion(
                    commandText,
                    hadVariableSubstitution:
                        substitution.hadVariableSubstitution,
                  ),
                  reviewMode,
                  typesAfterSubmit: sequence.typesAfterSubmit,
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
    if (sequence.hasActions) {
      unawaited(snippetRepo.incrementUsage(snippet.id));
      _terminalController.clearSelection();
      _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
      await _sendSnippetKeySequence(sequence);
      return;
    }
    _terminal.paste(sequence.plainText);
    _terminalController.clearSelection();
    _restoreTerminalFocus(showSystemKeyboard: _isMobilePlatform);
    unawaited(snippetRepo.incrementUsage(snippet.id));
  }

  /// Sends a snippet with key tokens, stopping as soon as the connection,
  /// shell, window or visible view it started in changes, or another
  /// sequence starts.
  Future<void> _sendSnippetKeySequence(SnippetKeySequence sequence) async {
    final run = ++_snippetSequenceRun;
    final target = _terminalInputTarget;
    // Typing, a toolbar key or a paste takes over the input line.
    final inputGeneration = _terminalUserInputGeneration;
    final windowKey = resolveTmuxBarActiveWindowKey(
      _currentTmuxWindowsSnapshot,
    );
    // A drop that recovers between two steps still ends the sequence.
    var connectionDropped = false;
    final connectionSubscription = ref
        .listenManual<Map<int, SshConnectionState>>(activeSessionsProvider, (
          previous,
          next,
        ) {
          final connectionId = _connectionId;
          if (connectionId == null ||
              next[connectionId] != SshConnectionState.connected) {
            connectionDropped = true;
          }
        });
    try {
      final outcome = await sendSnippetKeySequence(
        _terminal,
        sequence,
        outputIdle: () => _terminalEnterPacer?.idle,
        canContinue: () =>
            !connectionDropped &&
            inputGeneration == _terminalUserInputGeneration &&
            mounted &&
            run == _snippetSequenceRun &&
            terminalAttachmentPasteTargetsCurrentMuxWindow(
              hasPendingWindowSelection:
                  _tmuxBarKey.currentState?.hasPendingWindowSelection ?? false,
              pasteWindowKey: windowKey,
              currentWindowKey: resolveTmuxBarActiveWindowKey(
                _currentTmuxWindowsSnapshot,
              ),
            ) &&
            _terminalInputTarget == target,
      );
      if (outcome == SnippetSendOutcome.stopped &&
          mounted &&
          run == _snippetSequenceRun) {
        _showClipboardMessage(
          inputGeneration == _terminalUserInputGeneration
              ? 'Snippet stopped: the connection or window changed.'
              : 'Snippet stopped: other input went to the terminal.',
        );
      }
    } finally {
      connectionSubscription.close();
    }
  }

  /// Where input started now would go: the connection, shell, terminal,
  /// mux window and native session. Snippet key sequences and pastes that
  /// outlast a change of it stop rather than reach the new target.
  Object get _terminalInputTarget => (
    terminal: _terminal,
    shell: _shell,
    connectionId: _connectionId,
    connected: _readCurrentConnectionState() == SshConnectionState.connected,
    windowChanges: _muxWindowChangeGeneration,
    nativeAgent: _activeNativeAcpSessionKey,
  );

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
                  final hasVariables = snippetVariablePattern.hasMatch(
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
                      snippetLiteralText(snippet.command).replaceAll('\n', ' '),
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
  Future<
    ({
      String command,
      bool hadVariableSubstitution,
      Map<String, String> values,
    })?
  >
  _substituteVariables(BuildContext context, Snippet snippet) async {
    final variables = extractSnippetVariables(snippet.command);

    if (variables.isEmpty) {
      return (
        command: snippet.command,
        hadVariableSubstitution: false,
        values: const <String, String>{},
      );
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
        snippetVariablePattern,
        (match) => values[match.group(1)]!,
      ),
      hadVariableSubstitution: true,
      values: values,
    );
  }

  Future<bool> _reviewImportedAutoConnectCommand(
    TerminalCommandReview review,
    Host host,
  ) async {
    // Trusting an imported host is persistent; a link review is one-off, so
    // it never offers to trust the host even when the host was imported.
    final imported =
        review.reasons.contains(
          TerminalCommandReviewReason.importedAutoConnect,
        ) &&
        !review.reasons.contains(TerminalCommandReviewReason.openedFromLink);
    final decision = await showDialog<_AutoConnectReviewDecision>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: Text(
          imported
              ? 'Review imported auto-connect command'
              : 'Review auto-connect command',
        ),
        content: _buildCommandReviewContent(
          review: review,
          message: imported
              ? 'Imported auto-connect commands never run silently. Review this one before letting it execute.'
              : 'Links never run commands on their own. Review this one before letting it execute.',
        ),
        actions: [
          TextButton(
            // Neutral, so the dialog's one filled action carries the teal.
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
            ),
            onPressed: () =>
                Navigator.pop(context, _AutoConnectReviewDecision.skip),
            child: const Text('Skip'),
          ),
          if (imported)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _AutoConnectReviewDecision.runOnce),
              child: const Text('Run once'),
            )
          else
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _AutoConnectReviewDecision.runOnce),
              child: const Text('Run once'),
            ),
          if (imported)
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _AutoConnectReviewDecision.trustAndRun,
              ),
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
          // The same command panel the launch preset review uses.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(FluttyTheme.spacingSm + 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: SelectableText(
              commandPreview,
              style: FluttyTheme.monoStyle.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
