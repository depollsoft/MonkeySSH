import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../domain/services/ssh_service.dart';

/// Keeps what a terminal screen shows in step with [Terminal.visible], which
/// drives visibility reports (DEC private mode 2033), and tells the session's
/// multiplexer through [onSessionVisibilityChanged].
///
/// A terminal may be visible while the app is in the foreground and the screen
/// is on stage: no opaque route covers it (`TickerMode` is enabled). Visibility
/// reports may say "hidden" only with positive knowledge, so an inactive app,
/// which can still be on screen (split screen, a system sheet over it), counts
/// as visible.
///
/// Several screens can show the same session, one over another, so each
/// controller holds a claim on the terminal and the session it shows, and a
/// terminal or session is visible while any claim on it is.
class TerminalVisibilityController {
  /// Creates a controller for one terminal screen.
  TerminalVisibilityController({required this.onSessionVisibilityChanged});

  /// Called with whether any screen may show [SshSession]'s terminal, each
  /// time a claim on it changes.
  final void Function(SshSession session, {required bool visible})
  onSessionVisibilityChanged;

  static final _terminalClaims =
      Expando<Map<TerminalVisibilityController, bool>>();
  static final _sessionClaims =
      Expando<Map<TerminalVisibilityController, bool>>();

  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _onstage = true;
  Terminal? _terminal;
  SshSession? _session;

  /// Whether this screen may be visible to the user.
  bool get visible =>
      _onstage &&
      switch (_lifecycleState) {
        AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        AppLifecycleState.hidden ||
        AppLifecycleState.paused ||
        AppLifecycleState.detached => false,
      };

  /// The app lifecycle state this screen last heard.
  AppLifecycleState get lifecycleState => _lifecycleState;

  /// Applies an app lifecycle change.
  set lifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _apply();
  }

  /// Whether the screen's route is on stage: no opaque route covers it.
  bool get onstage => _onstage;

  /// Applies whether the screen's route is on stage
  /// (`TickerMode.valuesOf(context).enabled`).
  set onstage(bool value) {
    _onstage = value;
    _apply();
  }

  /// Shows [terminal], which belongs to [session] once one is attached. The
  /// terminal or session shown before loses this screen's claim.
  void show(Terminal terminal, SshSession? session) {
    final previousTerminal = _terminal;
    final previousSession = _session;
    _terminal = terminal;
    _session = session;
    if (previousTerminal != null && !identical(previousTerminal, terminal)) {
      _releaseTerminal(previousTerminal);
    }
    if (previousSession != null && !identical(previousSession, session)) {
      _releaseSession(previousSession);
    }
    _apply();
  }

  /// Releases this screen's claims, as when the screen goes away.
  void dispose() {
    final terminal = _terminal;
    final session = _session;
    _terminal = null;
    _session = null;
    if (terminal != null) {
      _releaseTerminal(terminal);
    }
    if (session != null) {
      _releaseSession(session);
    }
  }

  void _apply() {
    final terminal = _terminal;
    final session = _session;
    if (terminal != null) {
      (_terminalClaims[terminal] ??= {})[this] = visible;
      terminal.visible = _anyVisible(_terminalClaims[terminal]);
    }
    if (session != null) {
      (_sessionClaims[session] ??= {})[this] = visible;
      onSessionVisibilityChanged(
        session,
        visible: _anyVisible(_sessionClaims[session]),
      );
    }
  }

  void _releaseTerminal(Terminal terminal) {
    final claims = _terminalClaims[terminal]?..remove(this);
    terminal.visible = _anyVisible(claims);
  }

  void _releaseSession(SshSession session) {
    final claims = _sessionClaims[session]?..remove(this);
    onSessionVisibilityChanged(session, visible: _anyVisible(claims));
  }

  static bool _anyVisible(Map<TerminalVisibilityController, bool>? claims) =>
      claims != null && claims.values.any((visible) => visible);
}
