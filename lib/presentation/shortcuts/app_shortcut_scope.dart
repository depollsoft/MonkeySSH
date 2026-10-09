import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/keyboard_shortcuts_sheet.dart';
import 'app_shortcuts.dart';

/// Runs an app shortcut. The intent carries the window slot, if any.
typedef AppShortcutHandler = void Function(AppShortcutIntent intent);

/// Provides app shortcut handlers for its subtree.
///
/// A chord's handler is looked up from the focused widget outward, so the
/// innermost scope with a handler for the action wins. When nothing is
/// focused, the scopes of the current route answer instead. Scopes under a
/// route that is not the current one never answer: touch-opened terminal
/// sheets leave focus on the terminal below them, and a chord must not act
/// behind the sheet. A null handler
/// means the action cannot run here; its chord then does nothing (it is still
/// withheld from the terminal, see `app_shortcuts.dart`).
///
/// Scopes only work below an [AppShortcutsHost].
class AppShortcutScope extends StatefulWidget {
  /// Creates a scope with [handlers] for [child].
  const AppShortcutScope({
    required this.handlers,
    required this.child,
    super.key,
  });

  /// Handlers by action. Missing or null entries are unavailable here.
  final Map<AppShortcutAction, AppShortcutHandler?> handlers;

  /// The subtree.
  final Widget child;

  @override
  State<AppShortcutScope> createState() => _AppShortcutScopeState();
}

class _AppShortcutScopeState extends State<AppShortcutScope> {
  _AppShortcutsHostState? _host;
  ModalRoute<Object?>? _route;

  AppShortcutHandler? handlerFor(AppShortcutAction action) =>
      widget.handlers[action];

  bool get isInCurrentRoute => _route?.isCurrent ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final host = context
        .getInheritedWidgetOfExactType<_AppShortcutsHostScope>()
        ?.host;
    if (!identical(host, _host)) {
      _host?._unregister(this);
      _host = host?.._register(this);
    }
  }

  @override
  void dispose() {
    _host?._unregister(this);
    _host = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Installs the app's keyboard shortcuts above the navigator.
///
/// It binds the reserved chords from `app_shortcuts.dart`, routes each one to
/// the nearest [AppShortcutScope] handler, owns the "keyboard shortcuts"
/// sheet (⌘/ or Ctrl+Shift+/), and on iPadOS shows the same list while ⌘ is
/// held on its own, mirroring the system's hold-⌘ overlay that Flutter
/// cannot populate.
class AppShortcutsHost extends StatefulWidget {
  /// Creates the host for [child], normally the app's navigator.
  const AppShortcutsHost({
    required this.child,
    this.holdToPeekDelay = const Duration(milliseconds: 900),
    super.key,
  });

  /// The app content.
  final Widget child;

  /// How long ⌘ must be held alone before the shortcut list appears.
  final Duration holdToPeekDelay;

  @override
  State<AppShortcutsHost> createState() => _AppShortcutsHostState();
}

class _AppShortcutsHostState extends State<AppShortcutsHost>
    with WidgetsBindingObserver {
  final List<_AppShortcutScopeState> _scopes = <_AppShortcutScopeState>[];
  Timer? _peekTimer;
  bool _peekVisible = false;
  // Stays true while the peek fades out.
  bool _peekBuilt = false;
  late final _HostAction _action = _HostAction(this);

  TargetPlatform get _platform => defaultTargetPlatform;

  bool get _supportsHoldToPeek => !kIsWeb && _platform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handlePeekKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handlePeekKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _peekTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _hidePeek();
    }
  }

  void _register(_AppShortcutScopeState scope) {
    if (!_scopes.contains(scope)) {
      _scopes.add(scope);
    }
  }

  void _unregister(_AppShortcutScopeState scope) => _scopes.remove(scope);

  AppShortcutHandler? _resolve(
    AppShortcutIntent intent,
    BuildContext? focusContext,
  ) {
    if (intent.action == AppShortcutAction.showShortcuts) {
      return _toggleShortcutsSheet;
    }
    final context = focusContext ?? FocusManager.instance.primaryFocus?.context;
    if (context != null && context.mounted) {
      var scope = context.findAncestorStateOfType<_AppShortcutScopeState>();
      while (scope != null) {
        final handler = scope.isInCurrentRoute
            ? scope.handlerFor(intent.action)
            : null;
        if (handler != null) {
          return handler;
        }
        scope = scope.context.findAncestorStateOfType<_AppShortcutScopeState>();
      }
    }
    // Nothing focused inside a scope, for example after the composer lost
    // focus: let the current route's scopes answer, innermost first.
    for (final scope in _scopes.reversed) {
      if (!scope.mounted || !scope.isInCurrentRoute) {
        continue;
      }
      final handler = scope.handlerFor(intent.action);
      if (handler != null) {
        return handler;
      }
    }
    return null;
  }

  void _toggleShortcutsSheet(AppShortcutIntent _) {
    _hidePeek();
    if (KeyboardShortcutsSheet.closeIfOpen()) {
      return;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) {
      return;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator != null) {
      unawaited(showKeyboardShortcutsSheet(navigator.context));
    }
  }

  bool _handlePeekKeyEvent(KeyEvent event) {
    if (!_supportsHoldToPeek) {
      return false;
    }
    final isMeta = _isMetaKey(event.logicalKey);
    if (event is KeyDownEvent && isMeta) {
      _peekTimer?.cancel();
      _peekTimer = _onlyMetaPressed()
          ? Timer(widget.holdToPeekDelay, _showPeekIfStillHeld)
          : null;
    } else if (event is KeyDownEvent || (event is KeyUpEvent && isMeta)) {
      _hidePeek();
    }
    return false;
  }

  static bool _isMetaKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.meta;

  static bool _onlyMetaPressed() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.isNotEmpty && pressed.every(_isMetaKey);
  }

  void _showPeekIfStillHeld() {
    _peekTimer = null;
    if (!mounted || !_onlyMetaPressed() || KeyboardShortcutsSheet.isOpen) {
      return;
    }
    setState(() {
      _peekVisible = true;
      _peekBuilt = true;
    });
  }

  void _hidePeek() {
    _peekTimer?.cancel();
    _peekTimer = null;
    if (_peekVisible && mounted) {
      setState(() => _peekVisible = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bindings = appShortcutBindings(_platform);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return _AppShortcutsHostScope(
      host: this,
      child: Shortcuts(
        debugLabel: 'AppShortcutsHost',
        shortcuts: bindings,
        child: Actions(
          actions: <Type, Action<Intent>>{AppShortcutIntent: _action},
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _hidePeek(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                widget.child,
                if (_supportsHoldToPeek)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _peekVisible ? 1 : 0,
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        onEnd: () {
                          if (!_peekVisible && _peekBuilt && mounted) {
                            setState(() => _peekBuilt = false);
                          }
                        },
                        child: _peekBuilt
                            ? const KeyboardShortcutsPeek()
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppShortcutsHostScope extends InheritedWidget {
  const _AppShortcutsHostScope({required this.host, required super.child});

  final _AppShortcutsHostState host;

  @override
  bool updateShouldNotify(_AppShortcutsHostScope oldWidget) =>
      !identical(host, oldWidget.host);
}

class _HostAction extends ContextAction<AppShortcutIntent> {
  _HostAction(this._host);

  final _AppShortcutsHostState _host;

  @override
  bool isEnabled(AppShortcutIntent intent, [BuildContext? context]) =>
      _host._resolve(intent, context) != null;

  @override
  Object? invoke(AppShortcutIntent intent, [BuildContext? context]) {
    final handler = _host._resolve(intent, context);
    if (handler != null) {
      _host._hidePeek();
      runHardwareKeyboardFlow(() => handler(intent));
    }
    return null;
  }
}
