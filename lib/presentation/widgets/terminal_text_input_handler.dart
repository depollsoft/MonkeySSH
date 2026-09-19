import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// xterm 4.0.0 does not expose keyToTerminalKey via a public API.
// Pinned to xterm 4.0.0.
// ignore: implementation_imports
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/xterm.dart';

import '../../domain/services/diagnostics_log_service.dart';
import 'terminal_ime_engine.dart';

export 'terminal_ime_engine.dart';

const _androidTerminalImeKeyChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/terminal_ime_keys',
);

/// Touch duration at which a terminal touch should be treated as selection
/// intent rather than a tap-to-focus keyboard request.
@visibleForTesting
const terminalKeyboardTapLongPressTimeout = kLongPressTimeout;

/// Delay before iOS hardware keys begin app-controlled repeat.
@visibleForTesting
const terminalIosHardwareKeyRepeatStartDelay = Duration(milliseconds: 250);

/// Repeat interval for iOS hardware terminal navigation/editing keys.
@visibleForTesting
const terminalIosHardwareKeyRepeatInterval = Duration(milliseconds: 35);

DateTime Function()? _modifierChordClockOverride;

DateTime _readModifierChordClock() =>
    (_modifierChordClockOverride ?? DateTime.now).call();

class _AndroidTerminalImeKeyBridge {
  static _TerminalTextInputHandlerState? _state;
  static bool _handlerInstalled = false;
  static final List<({TerminalKey key, TerminalKeyEventType type})>
  _pendingPhysicalEvents = <({TerminalKey key, TerminalKeyEventType type})>[];

  static void attach() {
    if (_handlerInstalled) {
      return;
    }
    _handlerInstalled = true;
    _androidTerminalImeKeyChannel.setMethodCallHandler(_handleMethodCall);
  }

  static void detach(_TerminalTextInputHandlerState state) {
    if (identical(_state, state)) {
      _state = null;
      _pendingPhysicalEvents.clear();
    }
  }

  static void setEnabled(
    _TerminalTextInputHandlerState state, {
    required bool enabled,
  }) {
    if (enabled) {
      _state = state;
    } else if (identical(_state, state)) {
      _state = null;
      _pendingPhysicalEvents.clear();
    } else {
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    unawaited(_setEnabled(enabled));
  }

  static Future<void> _setEnabled(bool enabled) async {
    try {
      await _androidTerminalImeKeyChannel.invokeMethod<void>(
        'setInterceptionEnabled',
        enabled,
      );
    } on MissingPluginException {
      DiagnosticsLogService.instance.warning(
        'terminal.keyboard',
        'android_ime_key_bridge_unavailable',
      );
    }
  }

  static Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'getInterceptionEnabled') {
      return _state != null;
    }
    if (call.method != 'onVirtualKeyEvent' &&
        call.method != 'onPhysicalKeyEvent') {
      throw MissingPluginException('Unsupported terminal IME key method');
    }
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) {
      return null;
    }
    final key = switch (arguments['key']) {
      'shiftLeft' => TerminalKey.shiftLeft,
      'shiftRight' => TerminalKey.shiftRight,
      'backspace' => TerminalKey.backspace,
      _ => null,
    };
    final type = switch (arguments['type']) {
      'press' => TerminalKeyEventType.press,
      'repeat' => TerminalKeyEventType.repeat,
      'release' => TerminalKeyEventType.release,
      _ => null,
    };
    if (key == null || type == null) {
      return null;
    }
    if (call.method == 'onPhysicalKeyEvent') {
      _recordPhysicalEvent(key, type);
      return null;
    }
    _state?._handleAndroidImeKey(key, type);
    return null;
  }

  static void _recordPhysicalEvent(TerminalKey key, TerminalKeyEventType type) {
    _pendingPhysicalEvents.add((key: key, type: type));
    if (_pendingPhysicalEvents.length > 32) {
      _pendingPhysicalEvents.removeAt(0);
    }
  }

  static bool consumePhysicalEvent(TerminalKey key, TerminalKeyEventType type) {
    final index = _pendingPhysicalEvents.indexWhere(
      (event) => event.key == key && event.type == type,
    );
    if (index < 0) {
      return false;
    }
    _pendingPhysicalEvents.removeAt(index);
    return true;
  }

  static void debugRecordPhysicalEvent(
    TerminalKey key,
    TerminalKeyEventType type,
  ) {
    _recordPhysicalEvent(key, type);
  }
}

/// Overrides the modifier chord clock in tests.
@visibleForTesting
void debugSetModifierChordClock(DateTime Function()? clock) {
  _modifierChordClockOverride = clock;
}

/// Whether a pointer-up event should request the terminal soft keyboard.
///
/// Touch input should only open the keyboard after a tap-like gesture. Scrolls
/// and pinches must not reopen the IME after it has been dismissed.
@visibleForTesting
bool shouldRequestKeyboardForTerminalPointerUp({
  required PointerDeviceKind pointerKind,
  required int activeTouchPointers,
  required bool hadMultipleTouchPointers,
  required bool movedBeyondTapSlop,
  required bool readOnly,
  Duration? touchPressDuration,
}) {
  if (readOnly) {
    return false;
  }

  if (pointerKind != PointerDeviceKind.touch) {
    return true;
  }

  return activeTouchPointers == 1 &&
      !hadMultipleTouchPointers &&
      !movedBeyondTapSlop &&
      (touchPressDuration == null ||
          touchPressDuration < terminalKeyboardTapLongPressTimeout);
}

/// Controls a [TerminalTextInputHandler] from an ancestor widget.
///
/// Notifies listeners whenever the soft keyboard visibility ([isKeyboardVisible])
/// changes so UI that depends on it can rebuild even when the platform bottom
/// inset does not change.
class TerminalTextInputHandlerController extends ChangeNotifier {
  _TerminalTextInputHandlerState? _state;

  // ignore: use_setters_to_change_properties
  void _attach(_TerminalTextInputHandlerState state) {
    _state = state;
  }

  void _detach(_TerminalTextInputHandlerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  /// Prevents the next touch tap-up from reopening the soft keyboard.
  void suppressNextTouchKeyboardRequest() {
    _state?._suppressNextTouchKeyboardRequest();
  }

  /// Explicitly shows the soft keyboard.
  ///
  /// This always opens the keyboard regardless of the
  /// [TerminalTextInputHandler.tapToShowKeyboard] setting and is intended for
  /// toolbar buttons or programmatic triggers.
  void requestKeyboard() {
    _state?.requestKeyboard();
  }

  /// Whether the handler currently expects the soft keyboard to be visible.
  bool get isKeyboardVisible => _state?._isInputConnectionShown ?? false;

  void _notifyKeyboardVisibilityChanged() {
    notifyListeners();
  }

  /// Clears the transient IME buffer after external terminal actions.
  ///
  /// This is used for toolbar-driven keys like arrows, Home/End, Enter, Tab,
  /// and escape sequences that bypass the regular text-input pipeline but
  /// should still reset keyboard suggestions.
  void clearImeBuffer() {
    _state?._ime.clearImeBufferForFreshInput();
  }

  /// Resets platform IME completions after switching terminal contexts.
  void resetImeCompletions() {
    _state?._ime.resetImeCompletions();
  }

  /// Resets stale IME context after remote terminal output returns to a prompt.
  void handleExternalTerminalOutput() {
    _state?._handleExternalTerminalOutput();
  }

  /// Dispatches a native Android IME key event in tests.
  @visibleForTesting
  void debugHandleAndroidImeKey(TerminalKey key, TerminalKeyEventType type) {
    _state?._handleAndroidImeKey(key, type);
  }

  /// Records a native Android physical-key source marker in tests.
  @visibleForTesting
  void debugRecordAndroidPhysicalKey(
    TerminalKey key,
    TerminalKeyEventType type,
  ) {
    _AndroidTerminalImeKeyBridge.debugRecordPhysicalEvent(key, type);
  }
}

/// Wraps a [TerminalView] to provide soft keyboard input on mobile.
///
/// The xterm package's built-in [CustomTextEdit] hard-codes
/// `enableSuggestions: false`, which hides voice input on some system
/// keyboards and causes most IMEs to drop spaces between swiped words. This
/// widget keeps suggestions available, but disables automatic correction
/// because terminal commands are not prose and must not be rewritten by the
/// keyboard when the user accepts a space.
///
/// The child [TerminalView] should use `hardwareKeyboardOnly: true`.
class TerminalTextInputHandler extends StatefulWidget {
  /// Creates a new [TerminalTextInputHandler].
  const TerminalTextInputHandler({
    required this.terminal,
    required this.focusNode,
    required this.child,
    this.controller,
    this.deleteDetection = false,
    this.keyboardAppearance = Brightness.dark,
    this.onUserInput,
    this.onPasteText,
    this.onReviewInsertedText,
    this.buildReviewTextForInsertedText,
    this.resolveTextBeforeCursor,
    this.resolveTerminalKeyModifiers,
    this.consumeTerminalKeyModifiers,
    this.applyTerminalTextInputModifiers,
    this.hasActiveToolbarModifier,
    this.sensitiveInput = false,
    this.readOnly = false,
    this.tapToShowKeyboard = true,
    this.showKeyboardOnFocus,
    this.manageFocus = true,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Focus node that controls keyboard visibility.
  final FocusNode focusNode;

  /// The [TerminalView] child (should use `hardwareKeyboardOnly: true`).
  final Widget child;

  /// Optional controller for externally coordinating touch/keyboard behavior.
  final TerminalTextInputHandlerController? controller;

  /// Whether to use the delete-detection workaround for mobile.
  final bool deleteDetection;

  /// The appearance of the keyboard (iOS only).
  final Brightness keyboardAppearance;

  /// Called when user input has been accepted for sending to the terminal.
  final VoidCallback? onUserInput;

  /// Handles hardware-keyboard paste shortcuts before they reach the terminal.
  final FutureOr<void> Function()? onPasteText;

  /// Called before suspicious multi-character IME insertions are sent.
  final TerminalTextInputReviewCallback? onReviewInsertedText;

  /// Builds the command text that should be reviewed for suspicious IME input.
  final TerminalTextInputReviewTextBuilder? buildReviewTextForInsertedText;

  /// Resolves the current terminal text that appears before the cursor.
  ///
  /// This lets the IME handler distinguish a stray leading swipe space from the
  /// only separator needed between existing terminal text and the next word.
  final TerminalTextBeforeCursorResolver? resolveTextBeforeCursor;

  /// Resolves active toolbar modifiers for terminal key actions like Enter.
  final TerminalKeyModifierResolver? resolveTerminalKeyModifiers;

  /// Consumes one-shot toolbar modifiers after a terminal key action.
  final VoidCallback? consumeTerminalKeyModifiers;

  /// Applies toolbar modifiers before text reaches the terminal output stream.
  final TerminalTextInputModifierApplier? applyTerminalTextInputModifiers;

  /// Whether a toolbar modifier (Ctrl or Alt) is currently active.
  ///
  /// When a modifier is active, a typed character becomes a control code rather
  /// than visible text. In that case the IME buffer is cleared after sending
  /// the input so that stale suggestions don't accumulate from non-text input.
  final ValueGetter<bool>? hasActiveToolbarModifier;

  /// Whether the terminal appears to be accepting sensitive text.
  ///
  /// When true, the platform keyboard is configured like a password field so
  /// autocorrect, suggestions, dictation, and IME learning stay disabled while
  /// a remote password/passphrase prompt is active.
  final bool sensitiveInput;

  /// Whether input should be suppressed.
  final bool readOnly;

  /// Whether tapping the terminal should show the keyboard.
  ///
  /// When `false`, touch taps are ignored for keyboard purposes; the keyboard
  /// can still be opened via [requestKeyboard] (e.g. from a toolbar button).
  final bool tapToShowKeyboard;

  /// Whether focusing the terminal should show the keyboard.
  ///
  /// When omitted, focus follows [tapToShowKeyboard]. Set this to `false` when
  /// focus should attach an input connection without opening the keyboard until
  /// the user explicitly taps the terminal.
  final bool? showKeyboardOnFocus;

  /// Whether this widget should wrap [child] in a [Focus] using [focusNode].
  ///
  /// Set this to false when the child already owns the same [focusNode], for
  /// example a [SelectionArea] that must share focus with the input connection.
  final bool manageFocus;

  @override
  State<TerminalTextInputHandler> createState() =>
      _TerminalTextInputHandlerState();
}

class _TerminalTextInputHandlerState extends State<TerminalTextInputHandler>
    with TextInputClient {
  TerminalImeOptions get _imeOptions => TerminalImeOptions(
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
    readOnly: widget.readOnly,
    deleteDetection: widget.deleteDetection,
    sensitiveInput: widget.sensitiveInput,
    keyboardAppearance: widget.keyboardAppearance,
  );
  TerminalImeEffects get _imeEffects => TerminalImeEffects(
    onUserInput: widget.onUserInput,
    onReviewInsertedText: widget.onReviewInsertedText,
    buildReviewTextForInsertedText: widget.buildReviewTextForInsertedText,
    resolveTextBeforeCursor: widget.resolveTextBeforeCursor,
    resolveTerminalKeyModifiers: widget.resolveTerminalKeyModifiers,
    consumeTerminalKeyModifiers: widget.consumeTerminalKeyModifiers,
    applyTerminalTextInputModifiers: widget.applyTerminalTextInputModifiers,
    hasActiveToolbarModifier: widget.hasActiveToolbarModifier,
    canSyncEditingState: () => hasInputConnection,
    onEditingState: (value) => _connection!.setEditingState(value),
  );
  late final TerminalImeEngine _ime = TerminalImeEngine(
    terminal: widget.terminal,
    options: _imeOptions,
    effects: _imeEffects,
    now: _readModifierChordClock,
  );
  TextInputConnection? _connection;
  final Set<int> _activeTouchPointers = <int>{};
  final Map<int, Offset> _touchPointerDownPositions = <int, Offset>{};
  final Map<int, Duration> _touchPointerDownTimestamps = <int, Duration>{};
  final Set<int> _touchPointersMovedBeyondTapSlop = <int>{};
  bool _touchSequenceHadMultiplePointers = false;
  bool _skipNextTouchKeyboardRequest = false;
  Timer? _hardwareKeyRepeatStartTimer;
  Timer? _hardwareKeyRepeatTimer;
  LogicalKeyboardKey? _hardwareRepeatingLogicalKey;
  final Set<LogicalKeyboardKey> _textInputHandledHardwareKeys =
      <LogicalKeyboardKey>{};
  ({
    TerminalKey key,
    bool ctrl,
    bool alt,
    bool shift,
    bool meta,
    bool hasShortcutModifier,
  })?
  _hardwareRepeatInput;
  bool _isInputConnectionShown = false;

  @override
  void initState() {
    super.initState();
    _AndroidTerminalImeKeyBridge.attach();
    widget.focusNode.addListener(_onFocusChange);
    widget.controller?._attach(this);
    if (!widget.manageFocus) {
      HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    }
  }

  @override
  void didUpdateWidget(TerminalTextInputHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ime.options = _imeOptions;
    _ime.effects = _imeEffects;
    _ime.terminal = widget.terminal;
    if (!identical(widget.terminal, oldWidget.terminal)) {
      // Key repeats and IME deltas belong to the terminal that received the input.
      // Reset in place so switching sessions does not dismiss the keyboard.
      _stopHardwareKeyRepeat();
      _ime.clearImeBufferForFreshInput(flushPlatformContext: true);
    }
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
      _onFocusChange();
    }
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (widget.manageFocus != oldWidget.manageFocus) {
      if (widget.manageFocus) {
        HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
      } else {
        HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
      }
    }
    if (hasInputConnection &&
        widget.sensitiveInput != oldWidget.sensitiveInput) {
      _restartInputConnection();
    } else if (hasInputConnection &&
        widget.keyboardAppearance != oldWidget.keyboardAppearance) {
      _connection!.updateConfig(_ime.buildTextInputConfiguration());
    }
    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (oldWidget.readOnly && widget.focusNode.hasFocus) {
      _openInputConnection(
        show: widget.showKeyboardOnFocus ?? widget.tapToShowKeyboard,
      );
    }
    if (widget.readOnly) {
      _stopHardwareKeyRepeat();
      _ime.cancelDeferredTrailingBackspaceImeClear();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    if (!widget.manageFocus) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    }
    widget.focusNode.removeListener(_onFocusChange);
    _stopHardwareKeyRepeat();
    _ime.cancelDeferredTrailingBackspaceImeClear();
    _activeTouchPointers.clear();
    _touchPointerDownPositions.clear();
    _touchPointerDownTimestamps.clear();
    _touchPointersMovedBeyondTapSlop.clear();
    _closeInputConnectionIfNeeded();
    _AndroidTerminalImeKeyBridge.detach(this);
    _ime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Platform and read-only state are read live in HEAD; keep the engine's
    // snapshot current on every build, not only on didUpdateWidget.
    _ime.options = _imeOptions;
    final child = widget.manageFocus
        ? Focus(
            focusNode: widget.focusNode,
            autofocus: true,
            onKeyEvent: _onKeyEvent,
            child: widget.child,
          )
        : widget.child;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: child,
    );
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (widget.manageFocus || !widget.focusNode.hasFocus) {
      return false;
    }
    final result = _onKeyEvent(widget.focusNode, event);
    return result == KeyEventResult.handled ||
        result == KeyEventResult.skipRemainingHandlers;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouchPointers.add(event.pointer);
      _touchPointerDownPositions[event.pointer] = event.position;
      _touchPointerDownTimestamps[event.pointer] = event.timeStamp;
      if (_activeTouchPointers.length > 1) {
        _touchSequenceHadMultiplePointers = true;
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch ||
        _touchPointersMovedBeyondTapSlop.contains(event.pointer)) {
      return;
    }

    final startPosition = _touchPointerDownPositions[event.pointer];
    if (startPosition == null) {
      return;
    }

    final delta = event.position - startPosition;
    if (delta.distance > kTouchSlop) {
      _touchPointersMovedBeyondTapSlop.add(event.pointer);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final shouldRequestKeyboard = shouldRequestKeyboardForTerminalPointerUp(
      pointerKind: event.kind,
      activeTouchPointers: _activeTouchPointers.length,
      hadMultipleTouchPointers: _touchSequenceHadMultiplePointers,
      movedBeyondTapSlop: _touchPointersMovedBeyondTapSlop.contains(
        event.pointer,
      ),
      readOnly: widget.readOnly,
      touchPressDuration: event.kind == PointerDeviceKind.touch
          ? _touchPressDuration(event)
          : null,
    );
    if (event.kind == PointerDeviceKind.touch && shouldRequestKeyboard) {
      _ime.prepareForTouchCursorMove();
    }
    final shouldSkipKeyboardRequest =
        event.kind == PointerDeviceKind.touch && _skipNextTouchKeyboardRequest;
    final shouldSkipTapToShow =
        event.kind == PointerDeviceKind.touch && !widget.tapToShowKeyboard;
    if (event.kind == PointerDeviceKind.touch) {
      _skipNextTouchKeyboardRequest = false;
    }
    _clearPointerTracking(event);
    if (shouldRequestKeyboard &&
        !shouldSkipKeyboardRequest &&
        !shouldSkipTapToShow) {
      requestKeyboard();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _skipNextTouchKeyboardRequest = false;
    }
    _clearPointerTracking(event);
  }

  void _clearPointerTracking(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }

    _activeTouchPointers.remove(event.pointer);
    _touchPointerDownPositions.remove(event.pointer);
    _touchPointerDownTimestamps.remove(event.pointer);
    _touchPointersMovedBeyondTapSlop.remove(event.pointer);
    if (_activeTouchPointers.isEmpty) {
      _touchSequenceHadMultiplePointers = false;
    }
  }

  Duration? _touchPressDuration(PointerEvent event) {
    final startTimestamp = _touchPointerDownTimestamps[event.pointer];
    if (startTimestamp == null) {
      return null;
    }
    return event.timeStamp - startTimestamp;
  }

  bool get _shouldUseCustomHardwareKeyRepeat =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool _isRepeatableHardwareTerminalKey(TerminalKey key) => switch (key) {
    TerminalKey.backspace ||
    TerminalKey.delete ||
    TerminalKey.arrowLeft ||
    TerminalKey.arrowRight ||
    TerminalKey.arrowUp ||
    TerminalKey.arrowDown ||
    TerminalKey.home ||
    TerminalKey.end ||
    TerminalKey.pageUp ||
    TerminalKey.pageDown => true,
    _ => false,
  };

  void _startHardwareKeyRepeat({
    required LogicalKeyboardKey logicalKey,
    required TerminalKey key,
    required bool ctrl,
    required bool alt,
    required bool shift,
    required bool meta,
    required bool hasShortcutModifier,
  }) {
    _stopHardwareKeyRepeat();
    _hardwareRepeatingLogicalKey = logicalKey;
    _hardwareRepeatInput = (
      key: key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
      hasShortcutModifier: hasShortcutModifier,
    );
    bool dispatchRepeat() {
      if (!mounted) {
        _stopHardwareKeyRepeat();
        return false;
      }
      final repeatInput = _hardwareRepeatInput;
      if (repeatInput == null) {
        return false;
      }
      _ime.sendHardwareTerminalKey(
        repeatInput.key,
        ctrl: repeatInput.ctrl,
        alt: repeatInput.alt,
        shift: repeatInput.shift,
        meta: repeatInput.meta,
        hasShortcutModifier: repeatInput.hasShortcutModifier,
        type: TerminalKeyEventType.repeat,
      );
      return true;
    }

    _hardwareKeyRepeatStartTimer = Timer(
      terminalIosHardwareKeyRepeatStartDelay,
      () {
        if (dispatchRepeat()) {
          _hardwareKeyRepeatTimer = Timer.periodic(
            terminalIosHardwareKeyRepeatInterval,
            (_) => dispatchRepeat(),
          );
        }
      },
    );
  }

  void _stopHardwareKeyRepeat({LogicalKeyboardKey? logicalKey}) {
    if (logicalKey != null && _hardwareRepeatingLogicalKey != logicalKey) {
      return;
    }
    _hardwareKeyRepeatStartTimer?.cancel();
    _hardwareKeyRepeatTimer?.cancel();
    _hardwareKeyRepeatStartTimer = null;
    _hardwareKeyRepeatTimer = null;
    _hardwareRepeatingLogicalKey = null;
    _hardwareRepeatInput = null;
    if (logicalKey == null) {
      _ime.cancelAndroidBackspace();
      _textInputHandledHardwareKeys.clear();
    }
  }

  bool _shouldLetTextInputHandleHardwareKey(
    KeyEvent event,
    TerminalKey key, {
    required bool hasShortcutModifier,
  }) {
    if (!_isInputConnectionShown || hasShortcutModifier) {
      return false;
    }

    if (!_isVirtualTextInputKeyEvent(event)) {
      return false;
    }

    if (event is KeyUpEvent) {
      return _textInputHandledHardwareKeys.remove(event.logicalKey);
    }

    if (event is KeyRepeatEvent &&
        _textInputHandledHardwareKeys.contains(event.logicalKey)) {
      return true;
    }

    if (event is! KeyDownEvent || !_isTextInputManagedTerminalKey(key)) {
      return false;
    }

    _textInputHandledHardwareKeys.add(event.logicalKey);
    _stopHardwareKeyRepeat(logicalKey: event.logicalKey);
    return true;
  }

  /// Whether a soft-keyboard virtual key should be owned by the IME path.
  ///
  /// Enter is included so soft Return is delivered via [performAction] /
  /// newline text (where toolbar modifiers apply) instead of as a bare
  /// hardware key that only sees [HardwareKeyboard] state.
  bool _isTextInputManagedTerminalKey(TerminalKey key) {
    if (key == TerminalKey.enter || key == TerminalKey.numpadEnter) {
      return true;
    }
    return _isTextInputManagedCharacterKey(key);
  }

  bool _isTextInputManagedCharacterKey(TerminalKey key) {
    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      return true;
    }
    if (key.index >= TerminalKey.digit1.index &&
        key.index <= TerminalKey.digit0.index) {
      return true;
    }

    switch (key) {
      case TerminalKey.space:
      case TerminalKey.minus:
      case TerminalKey.equal:
      case TerminalKey.bracketLeft:
      case TerminalKey.bracketRight:
      case TerminalKey.backslash:
      case TerminalKey.semicolon:
      case TerminalKey.quote:
      case TerminalKey.backquote:
      case TerminalKey.comma:
      case TerminalKey.period:
      case TerminalKey.slash:
      case TerminalKey.numpad0:
      case TerminalKey.numpad1:
      case TerminalKey.numpad2:
      case TerminalKey.numpad3:
      case TerminalKey.numpad4:
      case TerminalKey.numpad5:
      case TerminalKey.numpad6:
      case TerminalKey.numpad7:
      case TerminalKey.numpad8:
      case TerminalKey.numpad9:
      case TerminalKey.numpadDecimal:
      case TerminalKey.numpadDivide:
      case TerminalKey.numpadMultiply:
      case TerminalKey.numpadSubtract:
      case TerminalKey.numpadAdd:
      case TerminalKey.numpadEqual:
      case TerminalKey.numpadComma:
      case TerminalKey.intlBackslash:
      case TerminalKey.shiftLeft:
      case TerminalKey.shiftRight:
      case TerminalKey.shift:
        return true;
      default:
        return false;
    }
  }

  bool _isTerminalModifierKey(TerminalKey key) => switch (key) {
    TerminalKey.controlLeft ||
    TerminalKey.controlRight ||
    TerminalKey.control ||
    TerminalKey.shiftLeft ||
    TerminalKey.shiftRight ||
    TerminalKey.shift ||
    TerminalKey.altLeft ||
    TerminalKey.altRight ||
    TerminalKey.alt ||
    TerminalKey.metaLeft ||
    TerminalKey.metaRight ||
    TerminalKey.meta => true,
    _ => false,
  };

  bool _isVirtualTextInputKeyEvent(KeyEvent event) =>
      event.physicalKey.usbHidUsage >= LogicalKeyboardKey.startOfPlatformPlanes;

  bool _isAndroidImeFallbackControlKey(
    TerminalKey key, {
    required bool isNativePhysicalEvent,
    required bool hasShortcutModifier,
  }) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        isNativePhysicalEvent ||
        hasShortcutModifier ||
        !_isInputConnectionShown ||
        View.of(context).viewInsets.bottom <= 0) {
      return false;
    }
    return key == TerminalKey.shiftLeft ||
        key == TerminalKey.shiftRight ||
        key == TerminalKey.backspace;
  }

  void _handleAndroidImeKey(TerminalKey key, TerminalKeyEventType type) {
    if (widget.readOnly ||
        !widget.focusNode.hasFocus ||
        !_isInputConnectionShown) {
      _ime.cancelAndroidBackspace();
      return;
    }
    if (key == TerminalKey.shiftLeft || key == TerminalKey.shiftRight) {
      return;
    }
    if (key != TerminalKey.backspace) {
      return;
    }
    _ime.handleAndroidImeBackspace(
      type,
      toolbarModifiers: widget.resolveTerminalKeyModifiers?.call(),
    );
  }

  // -- Hardware key event handling --

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (widget.readOnly) {
      _stopHardwareKeyRepeat();
      return KeyEventResult.ignored;
    }

    final hardwareKeyboard = HardwareKeyboard.instance;
    final isPasteShortcut =
        widget.onPasteText != null &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !hardwareKeyboard.isAltPressed &&
        (hardwareKeyboard.isControlPressed || hardwareKeyboard.isMetaPressed);
    if (isPasteShortcut) {
      _ime.endFraming();
      _stopHardwareKeyRepeat();
      if (event is KeyDownEvent) {
        unawaited(Future<void>.sync(widget.onPasteText!));
      }
      return KeyEventResult.handled;
    }

    final hasShortcutModifier =
        hardwareKeyboard.isControlPressed ||
        hardwareKeyboard.isAltPressed ||
        hardwareKeyboard.isMetaPressed;

    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) {
      return KeyEventResult.ignored;
    }
    final type = _terminalKeyEventType(event);
    final isNativePhysicalEvent =
        _AndroidTerminalImeKeyBridge.consumePhysicalEvent(key, type);
    if (_isAndroidImeFallbackControlKey(
      key,
      isNativePhysicalEvent: isNativePhysicalEvent,
      hasShortcutModifier: hasShortcutModifier,
    )) {
      _handleAndroidImeKey(key, type);
      return KeyEventResult.skipRemainingHandlers;
    }
    if (!_ime.editingValue.composing.isCollapsed && !hasShortcutModifier) {
      return KeyEventResult.skipRemainingHandlers;
    }

    if (event is KeyUpEvent) {
      _stopHardwareKeyRepeat(logicalKey: event.logicalKey);
      if (!widget.terminal.kittyKeyboardMode) {
        return KeyEventResult.ignored;
      }
    }

    if (_shouldLetTextInputHandleHardwareKey(
      event,
      key,
      hasShortcutModifier: hasShortcutModifier,
    )) {
      return KeyEventResult.skipRemainingHandlers;
    }

    final toolbarModifiers = widget.resolveTerminalKeyModifiers?.call();
    final hasToolbarModifier =
        toolbarModifiers != null &&
        (toolbarModifiers.ctrl ||
            toolbarModifiers.alt ||
            toolbarModifiers.shift);
    final isEnter = key == TerminalKey.enter || key == TerminalKey.numpadEnter;
    final isVirtual = _isVirtualTextInputKeyEvent(event);
    // Toolbar modifiers are not mirrored into HardwareKeyboard. Merge them so
    // extended-keyboard Shift/Alt/Ctrl apply on this path.
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        (toolbarModifiers?.ctrl ?? false);
    final alt =
        HardwareKeyboard.instance.isAltPressed ||
        (toolbarModifiers?.alt ?? false);
    final physicalShift = HardwareKeyboard.instance.isShiftPressed;
    // Enter + live IME: trust toolbar Shift always, and physical Shift only on
    // non-virtual keys (external keyboard). Virtual soft-keyboard Enter must
    // not inherit capitalization Shift (that becomes LF / "newline" in Codex).
    final shift = isEnter
        ? ((toolbarModifiers?.shift ?? false) || (physicalShift && !isVirtual))
        : (physicalShift || (toolbarModifiers?.shift ?? false));
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final useCustomRepeat =
        _shouldUseCustomHardwareKeyRepeat &&
        _isRepeatableHardwareTerminalKey(key);

    if (event is KeyRepeatEvent && useCustomRepeat) {
      return KeyEventResult.handled;
    }

    final handled = _ime.sendHardwareTerminalKey(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
      hasShortcutModifier: hasShortcutModifier,
      type: type,
    );

    if (handled &&
        type == TerminalKeyEventType.press &&
        hasToolbarModifier &&
        !_isTerminalModifierKey(key)) {
      widget.consumeTerminalKeyModifiers?.call();
      if (isEnter) {
        // Soft keyboards often also deliver newline via IME after the key event.
        _ime.recordHardwareEnter();
      }
    }

    if (handled && event is KeyDownEvent && useCustomRepeat) {
      _startHardwareKeyRepeat(
        logicalKey: event.logicalKey,
        key: key,
        ctrl: ctrl,
        alt: alt,
        shift: shift,
        meta: meta,
        hasShortcutModifier: hasShortcutModifier,
      );
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  TerminalKeyEventType _terminalKeyEventType(KeyEvent event) {
    if (event is KeyRepeatEvent) {
      return TerminalKeyEventType.repeat;
    }
    if (event is KeyUpEvent) {
      return TerminalKeyEventType.release;
    }
    return TerminalKeyEventType.press;
  }

  @override
  TextEditingValue? get currentTextEditingValue => _ime.editingValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) =>
      _ime.updateEditingValue(value);

  @override
  void performAction(TextInputAction action) => _ime.performAction(action);

  void _handleExternalTerminalOutput() {
    if (!widget.focusNode.hasFocus || !hasInputConnection) return;
    _ime.handleExternalTerminalOutput();
  }

  // -- Public API --

  /// Whether a text input connection is currently active.
  bool get hasInputConnection => _connection != null && _connection!.attached;

  /// Shows the soft keyboard.
  void requestKeyboard() {
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    // Always show — this is an explicit request (e.g. from a toolbar button).
    _openInputConnection();
  }

  /// Hides the soft keyboard.
  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
    _setInputConnectionShown(shown: false);
  }

  void _suppressNextTouchKeyboardRequest() {
    _skipNextTouchKeyboardRequest = true;
  }

  // -- Focus handling --

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      final consumedKeyboardToken = widget.focusNode.consumeKeyboardToken();
      if (!hasInputConnection || consumedKeyboardToken) {
        // Attach the input connection but only show the soft keyboard when
        // tap-to-show is enabled.  Explicit keyboard requests go through
        // requestKeyboard() which always passes show: true.
        _openInputConnection(
          show: widget.showKeyboardOnFocus ?? widget.tapToShowKeyboard,
        );
      }
    } else if (!widget.focusNode.hasFocus) {
      _stopHardwareKeyRepeat();
      _closeInputConnectionIfNeeded();
    }
    _reconcileAndroidImeKeyBridge();
  }

  // -- Input connection management --

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _setInputConnectionShown({required bool shown}) {
    if (_isInputConnectionShown == shown) {
      return;
    }
    _isInputConnectionShown = shown;
    _reconcileAndroidImeKeyBridge();
    widget.controller?._notifyKeyboardVisibilityChanged();
  }

  void _reconcileAndroidImeKeyBridge() {
    _AndroidTerminalImeKeyBridge.setEnabled(
      this,
      enabled:
          _isInputConnectionShown &&
          widget.focusNode.hasFocus &&
          !widget.readOnly,
    );
  }

  void _openInputConnection({bool show = true}) {
    if (!_shouldCreateInputConnection) return;

    if (hasInputConnection) {
      if (show) {
        _connection!.show();
        _setInputConnectionShown(shown: true);
      }
    } else {
      _connection = TextInput.attach(this, _ime.buildTextInputConfiguration());
      _setInputConnectionShown(shown: false);
      if (show) {
        _connection!.show();
        _setInputConnectionShown(shown: true);
      }
      _ime.resetConnectionEditingState();
      _connection!.setEditingState(_ime.initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    _stopHardwareKeyRepeat();
    _ime.cancelDeferredTrailingBackspaceImeClear();
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
    _setInputConnectionShown(shown: false);
    _ime.resetConnectionEditingState();
  }

  void _restartInputConnection() {
    final shouldShow = _isInputConnectionShown;
    _closeInputConnectionIfNeeded();
    _openInputConnection(show: shouldShow);
  }

  // -- Editing state --

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {
    _connection = null;
    _isInputConnectionShown = false;
    _AndroidTerminalImeKeyBridge.setEnabled(this, enabled: false);
    _stopHardwareKeyRepeat();
    _ime
      ..cancelDeferredTrailingBackspaceImeClear()
      ..resetConnectionEditingState();
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}
}
