part of '../terminal_screen.dart';

/// Hardware keyboard shortcuts for the terminal screen (#931).
///
/// Window shortcuts drive the persistent window switcher (the bottom bar, or
/// the sidebar on wide layouts). With the bar hidden from the Options menu,
/// only "show or hide windows" works; it opens the window navigator sheet,
/// which is keyboard navigable. Find in scrollback (#937) and Changes (#925)
/// have no handler yet, so their chords stay with the terminal (they are not
/// reserved until `available` is set in `app_shortcuts.dart`).
extension _TerminalScreenShortcuts on _TerminalScreenState {
  Map<AppShortcutAction, AppShortcutHandler?> _appShortcutHandlers(
    SshConnectionState connectionState,
  ) {
    final connected =
        _connectionId != null &&
        connectionState == SshConnectionState.connected;
    final muxActive = connected && _isTmuxActive && _tmuxSessionName != null;
    final barShown = muxActive && _showTmuxBar;
    _TmuxExpandableBarState? bar() => _tmuxBarKey.currentState;
    return {
      AppShortcutAction.nextWindow: barShown
          ? (_) => _afterKeyboardWindowSwitch(
              bar()?.selectAdjacentWindowFromKeyboard(1),
            )
          : null,
      AppShortcutAction.previousWindow: barShown
          ? (_) => _afterKeyboardWindowSwitch(
              bar()?.selectAdjacentWindowFromKeyboard(-1),
            )
          : null,
      AppShortcutAction.goToWindow: barShown
          ? (intent) => _afterKeyboardWindowSwitch(
              bar()?.selectWindowNumberFromKeyboard(intent.windowNumber ?? 0),
            )
          : null,
      AppShortcutAction.newWindow: barShown
          ? (_) => unawaited(bar()?.showNewWindowPickerFromKeyboard())
          : null,
      AppShortcutAction.closeWindow: barShown
          ? (_) => unawaited(bar()?.closeActiveWindowFromKeyboard())
          : null,
      AppShortcutAction.toggleWindowList: barShown
          ? (_) => bar()?.toggleFromKeyboard()
          : muxActive
          ? (_) => unawaited(_openTmuxNavigator())
          : null,
      AppShortcutAction.focusComposer: (_) {
        _collapseTmuxBarIfExpanded();
        _focusKeyboardInput();
      },
      AppShortcutAction.openFiles: connected
          ? (_) => unawaited(_openConnectionFileBrowser())
          : null,
    };
  }

  /// After a keyboard window switch lands, puts focus back on the input of
  /// whatever the viewport now shows, unless something else took it.
  void _afterKeyboardWindowSwitch(Future<void>? switched) {
    if (switched == null) {
      return;
    }
    unawaited(
      switched.whenComplete(() {
        if (mounted) {
          _restoreKeyboardInputFocusIfLost();
        }
      }),
    );
  }

  /// Focuses the native agent composer when an agent chat fills the viewport,
  /// otherwise the terminal. Never opens the soft keyboard by itself.
  void _focusKeyboardInput() {
    if (_activeNativeAcpSessionKey != null) {
      _nativeComposerFocusController.requestFocus();
    } else {
      _restoreTerminalFocus();
    }
  }

  /// Called when the window switcher collapses. Keyboard focus that was on a
  /// switcher row would otherwise stay on a hidden row or be dropped.
  void _handleTmuxBarCollapsedForKeyboard() {
    if (_isFocusWithinTmuxBar()) {
      _restoreKeyboardInputFocusIfLost();
    }
  }

  void _restoreKeyboardInputFocusIfLost() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final primary = FocusManager.instance.primaryFocus;
      final routeScope = FocusScope.of(context);
      final lost =
          primary == null ||
          identical(primary, routeScope) ||
          _isFocusWithinTmuxBar();
      if (lost) {
        _focusKeyboardInput();
      }
    });
  }

  bool _isFocusWithinTmuxBar() {
    final barContext = _tmuxBarKey.currentContext;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (barContext == null || focusContext == null || !focusContext.mounted) {
      return false;
    }
    var inside = identical(focusContext, barContext);
    if (!inside) {
      focusContext.visitAncestorElements((element) {
        if (identical(element, barContext)) {
          inside = true;
          return false;
        }
        return true;
      });
    }
    return inside;
  }
}
