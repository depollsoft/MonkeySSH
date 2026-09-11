import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'system_bottom_inset.dart';
import 'terminal_key_input.dart';
import 'terminal_menu_style.dart';

/// Resolves the bottom inset the toolbar reserves below its last key row.
///
/// The toolbar is the bottom-most chrome in the terminal body, so it owns the
/// gesture handle / navigation bar inset. When the system keyboard lifts the
/// layout above that bar the inset resolves to zero, which avoids an extra gap
/// above the keyboard.
double resolveKeyboardToolbarBottomInset(MediaQueryData mediaQuery) =>
    resolveSystemBottomInset(mediaQuery);

/// Whether the extra-keys toolbar should collapse to a single row.
///
/// In landscape, vertical space is tighter and the toolbar behaves more like a
/// keyboard extension on compact screens, so it should stay to one
/// horizontally scrollable row.
bool shouldUseSingleRowKeyboardToolbar(MediaQueryData mediaQuery) =>
    mediaQuery.orientation == Orientation.landscape &&
    mediaQuery.size.shortestSide < 600;

/// Resolves the total rendered height of the keyboard toolbar.
double resolveKeyboardToolbarHeight(MediaQueryData mediaQuery) {
  final rowCount = shouldUseSingleRowKeyboardToolbar(mediaQuery) ? 1 : 2;
  return rowCount * _KeyRow.height +
      resolveKeyboardToolbarBottomInset(mediaQuery);
}

/// Resolves the terminal output sequence for a Tab action.
///
/// An explicit Shift modifier from the terminal toolbar turns Tab into the
/// reverse-tab escape sequence. Plain Tab remains a literal tab character.
String resolveTerminalTabInput({required bool shiftActive}) =>
    shiftActive ? '\x1b[Z' : '\t';

int? _ctrlCodeForCharacter(String text) {
  if (text.length != 1) {
    return null;
  }

  final codeUnit = text.codeUnitAt(0);
  if (codeUnit >= 0x61 && codeUnit <= 0x7A) {
    return codeUnit - 0x60;
  }
  if (codeUnit >= 0x40 && codeUnit <= 0x5F) {
    return codeUnit - 0x40;
  }
  if (codeUnit == 0x20) {
    return 0x00;
  }
  if (codeUnit == 0x3F) {
    return 0x7F;
  }
  return null;
}

/// Stores the toolbar modifier state independently of the widget lifecycle.
class KeyboardToolbarController extends ChangeNotifier {
  bool? _ctrlState;
  bool? _altState;
  bool? _shiftState;

  /// The current Ctrl modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get ctrlState => _ctrlState;

  /// The current Alt modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get altState => _altState;

  /// The current Shift modifier mode: off (`null`), one-shot (`false`), locked (`true`).
  bool? get shiftState => _shiftState;

  /// Whether Ctrl is currently active (one-shot or locked).
  bool get isCtrlActive => _ctrlState != null;

  /// Whether Alt is currently active (one-shot or locked).
  bool get isAltActive => _altState != null;

  /// Whether Shift is currently active (one-shot or locked).
  bool get isShiftActive => _shiftState != null;

  /// Toggles Ctrl between off and one-shot mode.
  void toggleCtrl() => _toggleModifier(_Modifier.ctrl);

  /// Toggles Alt between off and one-shot mode.
  void toggleAlt() => _toggleModifier(_Modifier.alt);

  /// Toggles Shift between off and one-shot mode.
  void toggleShift() => _toggleModifier(_Modifier.shift);

  /// Locks or unlocks Ctrl.
  void lockCtrl() => _lockModifier(_Modifier.ctrl);

  /// Locks or unlocks Alt.
  void lockAlt() => _lockModifier(_Modifier.alt);

  /// Locks or unlocks Shift.
  void lockShift() => _lockModifier(_Modifier.shift);

  /// Clears any one-shot modifiers while preserving locked modifiers.
  void consumeOneShot() {
    final changed = switch ((_ctrlState, _altState, _shiftState)) {
      (false, _, _) || (_, false, _) || (_, _, false) => true,
      _ => false,
    };
    if (!changed) {
      return;
    }

    if (_ctrlState case false) {
      _ctrlState = null;
    }
    if (_altState case false) {
      _altState = null;
    }
    if (_shiftState case false) {
      _shiftState = null;
    }
    notifyListeners();
  }

  /// Applies toolbar modifiers to a single system-keyboard text payload.
  ///
  /// This is used for soft-keyboard characters that reach the terminal through
  /// the regular text-input path instead of toolbar buttons or hardware keys.
  String applySystemKeyboardModifiers(String text) {
    if (text.length != 1) {
      return text;
    }

    var output = text;
    var shouldConsume = false;

    if (_ctrlState != null) {
      final ctrlCode = _ctrlCodeForCharacter(output);
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
      shouldConsume = true;
    }
    if (_altState != null) {
      output = '\x1b$output';
      shouldConsume = true;
    }

    if (shouldConsume) {
      consumeOneShot();
    }

    return output;
  }

  void _toggleModifier(_Modifier mod) {
    switch (mod) {
      case _Modifier.ctrl:
        _ctrlState = _ctrlState == null ? false : null;
      case _Modifier.alt:
        _altState = _altState == null ? false : null;
      case _Modifier.shift:
        _shiftState = _shiftState == null ? false : null;
    }
    notifyListeners();
  }

  void _lockModifier(_Modifier mod) {
    switch (mod) {
      case _Modifier.ctrl:
        _ctrlState = _ctrlState ?? false ? null : true;
      case _Modifier.alt:
        _altState = _altState ?? false ? null : true;
      case _Modifier.shift:
        _shiftState = _shiftState ?? false ? null : true;
    }
    notifyListeners();
  }
}

/// Snippet option shown in the keyboard toolbar paste menu.
@immutable
class KeyboardToolbarSnippet {
  /// Creates a [KeyboardToolbarSnippet].
  const KeyboardToolbarSnippet({
    required this.id,
    required this.name,
    required this.command,
    this.folderId,
  });

  /// Persistent snippet ID.
  final int id;

  /// User-visible snippet name.
  final String name;

  /// Command text inserted when the snippet is selected.
  final String command;

  /// Folder containing this snippet, or null for a top-level snippet.
  final int? folderId;
}

/// Snippet folder option shown in the keyboard toolbar paste menu.
@immutable
class KeyboardToolbarSnippetFolder {
  /// Creates a [KeyboardToolbarSnippetFolder].
  const KeyboardToolbarSnippetFolder({required this.id, required this.name});

  /// Persistent folder ID.
  final int id;

  /// User-visible folder name.
  final String name;
}

/// Compact keyboard toolbar for terminal input.
///
/// Features:
/// - Modifier keys (Ctrl, Alt, Shift) with toggle/lock functionality
/// - Navigation keys (arrows, Home, End, PgUp, PgDn)
/// - Special keys (Esc, Tab, Enter, pipe, etc.)
/// - Haptic feedback
class KeyboardToolbar extends StatefulWidget {
  /// Creates a new [KeyboardToolbar].
  const KeyboardToolbar({
    required this.terminal,
    this.controller,
    this.onKeyPressed,
    this.onTextInput,
    this.onSpecialKey,
    this.onPasteRequested,
    this.onPasteMenuOpened,
    this.onSnippetPasteRequested,
    this.onPasteMediaRequested,
    this.onPasteFilesRequested,
    this.snippets = const <KeyboardToolbarSnippet>[],
    this.snippetFolders = const <KeyboardToolbarSnippetFolder>[],
    this.terminalFocusNode,
    super.key,
  });

  /// The terminal to send input to.
  final Terminal terminal;

  /// Optional controller that keeps modifier state stable across rebuilds.
  final KeyboardToolbarController? controller;

  /// Optional callback when any key is pressed.
  final VoidCallback? onKeyPressed;

  /// Overrides literal text delivery instead of writing to [terminal].
  final ValueChanged<String>? onTextInput;

  /// Overrides special-key delivery instead of writing to [terminal].
  final ValueChanged<TerminalKey>? onSpecialKey;

  /// Optional callback when the Paste key is tapped.
  final FutureOr<void> Function()? onPasteRequested;

  /// Optional callback when the Paste key's long-press menu opens.
  final FutureOr<void> Function()? onPasteMenuOpened;

  /// Optional callback when a snippet is selected from the Paste menu.
  final FutureOr<void> Function(KeyboardToolbarSnippet snippet)?
  onSnippetPasteRequested;

  /// Optional callback when the Paste key's long-press media option is tapped.
  final FutureOr<void> Function()? onPasteMediaRequested;

  /// Optional callback when the Paste key's long-press file option is tapped.
  final FutureOr<void> Function()? onPasteFilesRequested;

  /// Snippets available in the Paste menu.
  final List<KeyboardToolbarSnippet> snippets;

  /// Snippet folders available in the Paste menu.
  final List<KeyboardToolbarSnippetFolder> snippetFolders;

  /// Optional focus node for the terminal. When provided, the toolbar
  /// re-requests focus after interactions so the soft keyboard stays visible.
  final FocusNode? terminalFocusNode;

  @override
  State<KeyboardToolbar> createState() => KeyboardToolbarState();
}

/// State for [KeyboardToolbar].
class KeyboardToolbarState extends State<KeyboardToolbar> {
  static const _pasteOptionsWidth = 200.0;
  static const _pasteSnippetMenuWidth = 180.0;
  static const _pasteOptionsGap = TerminalMenuStyles.cascadeGap;
  static const _pasteOptionsScreenMargin = TerminalMenuStyles.screenMargin;

  late final KeyboardToolbarController _fallbackController;
  final _pasteButtonKey = GlobalKey();
  OverlayEntry? _pasteOptionsOverlay;
  _PasteToolbarAction? _highlightedPasteAction;
  KeyboardToolbarSnippetFolder? _highlightedSnippetFolder;
  KeyboardToolbarSnippet? _highlightedSnippet;

  KeyboardToolbarController get _controller =>
      widget.controller ?? _fallbackController;

  @override
  void initState() {
    super.initState();
    _fallbackController = KeyboardToolbarController();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant KeyboardToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousController = oldWidget.controller ?? _fallbackController;
    final nextController = _controller;
    if (!identical(previousController, nextController)) {
      previousController.removeListener(_handleControllerChanged);
      nextController.addListener(_handleControllerChanged);
    }
    if (!identical(oldWidget.snippets, widget.snippets) ||
        !identical(oldWidget.snippetFolders, widget.snippetFolders)) {
      _pasteOptionsOverlay?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _hidePasteOptionsMenu();
    _controller.removeListener(_handleControllerChanged);
    _fallbackController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Re-requests focus on the terminal so the soft keyboard stays visible.
  void _refocusTerminal() {
    widget.terminalFocusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bottomInset = resolveKeyboardToolbarBottomInset(mediaQuery);
    final useSingleRow = shouldUseSingleRowKeyboardToolbar(mediaQuery);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: useSingleRow
              ? _buildLandscapeRow()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_buildModifierRow(), _buildNavigationRow()],
                ),
        ),
      ),
    );
  }

  Widget _buildModifierRow() => _KeyRow(children: _buildModifierButtons());

  Widget _buildNavigationRow() =>
      _KeyRow(children: [..._buildNavigationButtons(), _buildEnterButton()]);

  Widget _buildLandscapeRow() => _KeyRow(
    children: [
      ..._buildModifierButtons(),
      ..._buildNavigationButtons(),
      _buildEnterButton(),
    ],
  );

  Widget _buildEnterButton() => _ToolbarButton(
    icon: Icons.keyboard_return_rounded,
    label: '',
    onTap: _sendEnter,
    tooltip: 'Enter',
  );

  List<Widget> _buildModifierButtons() => [
    _ToolbarButton(
      icon: Icons.cancel_outlined,
      label: 'Esc',
      onTap: _sendEscape,
      onLongPressStart: _sendEscape,
      tooltip: 'Escape',
    ),
    _ToolbarButton(
      icon: Icons.keyboard_tab_rounded,
      mirrorIcon: _controller.isShiftActive,
      label: 'Tab',
      onTap: _sendTab,
      onLongPressStart: _sendTab,
      tooltip: 'Tab',
    ),
    _ModifierButton(
      icon: Icons.keyboard_control_key_rounded,
      label: 'Ctrl',
      state: _controller.ctrlState,
      onTap: _toggleCtrl,
      onDoubleTap: _lockCtrl,
      tooltip: 'Ctrl',
    ),
    _ModifierButton(
      icon: Icons.keyboard_option_key_rounded,
      label: 'Alt',
      state: _controller.altState,
      onTap: _toggleAlt,
      onDoubleTap: _lockAlt,
      tooltip: 'Alt',
    ),
    _ModifierButton(
      icon: Icons.north_rounded,
      label: 'Shift',
      state: _controller.shiftState,
      onTap: _toggleShift,
      onDoubleTap: _lockShift,
      tooltip: 'Shift',
    ),
    _ToolbarButton(label: '|', onTap: () => _sendText('|'), tooltip: 'Pipe'),
    _ToolbarButton(label: '/', onTap: () => _sendText('/'), tooltip: 'Slash'),
    _ToolbarButton(label: '~', onTap: () => _sendText('~'), tooltip: 'Tilde'),
    _ToolbarButton(
      key: _pasteButtonKey,
      icon: Icons.paste_rounded,
      label: 'Paste',
      longPressIndicatorIcon: Icons.more_horiz_rounded,
      onTap: _pasteClipboard,
      onLongPressStartWithDetails: _showPasteOptions,
      onLongPressMoveUpdate: _updatePasteOptionsHighlight,
      onLongPressEnd: _chooseHighlightedPasteOption,
      onLongPressCancel: _hidePasteOptionsMenu,
      semanticsHint: 'Press and hold for paste options',
      tooltip: 'Paste',
    ),
  ];

  List<Widget> _buildNavigationButtons() => [
    for (final (key, icon, label, tooltip, sequence) in const [
      (TerminalKey.arrowLeft, Icons.arrow_back_rounded, '', 'Left', '\x1b[D'),
      (
        TerminalKey.arrowRight,
        Icons.arrow_forward_rounded,
        '',
        'Right',
        '\x1b[C',
      ),
      (TerminalKey.arrowUp, Icons.arrow_upward_rounded, '', 'Up', '\x1b[A'),
      (
        TerminalKey.arrowDown,
        Icons.arrow_downward_rounded,
        '',
        'Down',
        '\x1b[B',
      ),
      (
        TerminalKey.pageUp,
        Icons.expand_less_rounded,
        'PgUp',
        'Page Up',
        '\x1b[5~',
      ),
      (
        TerminalKey.pageDown,
        Icons.expand_more_rounded,
        'PgDn',
        'Page Down',
        '\x1b[6~',
      ),
      (TerminalKey.home, Icons.first_page_rounded, 'Home', 'Home', '\x1b[H'),
      (TerminalKey.end, Icons.last_page_rounded, 'End', 'End', '\x1b[F'),
    ])
      _ToolbarButton(
        icon: icon,
        label: label,
        tooltip: tooltip,
        onTap: () => _sendNavigationKey(key, sequence),
        onLongPressStart: () => _sendNavigationKey(key, sequence),
        onLongPressRepeat: () => _sendNavigationKey(
          key,
          sequence,
          withHaptic: false,
          consumeOneShot: false,
        ),
      ),
  ];

  void _toggleCtrl() {
    HapticFeedback.selectionClick();
    _controller.toggleCtrl();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _toggleAlt() {
    HapticFeedback.selectionClick();
    _controller.toggleAlt();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _toggleShift() {
    HapticFeedback.selectionClick();
    _controller.toggleShift();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _lockCtrl() {
    HapticFeedback.mediumImpact();
    _controller.lockCtrl();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _lockAlt() {
    HapticFeedback.mediumImpact();
    _controller.lockAlt();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _lockShift() {
    HapticFeedback.mediumImpact();
    _controller.lockShift();
    widget.onKeyPressed?.call();
    _refocusTerminal();
  }

  void _pasteClipboard() {
    HapticFeedback.lightImpact();
    widget.onKeyPressed?.call();
    _consumeOneShot();
    unawaited(_runToolbarAction(widget.onPasteRequested));
  }

  void _showPasteOptions(LongPressStartDetails details) {
    HapticFeedback.mediumImpact();
    widget.onKeyPressed?.call();
    _consumeOneShot();
    _showPasteOptionsMenu(details.globalPosition);
    final onPasteMenuOpened = widget.onPasteMenuOpened;
    if (onPasteMenuOpened != null) {
      unawaited(Future<void>.sync(onPasteMenuOpened));
    }
  }

  void _showPasteOptionsMenu(Offset globalPosition) {
    final overlay = Overlay.of(context);
    final buttonRect = _pasteButtonGlobalRect();
    if (buttonRect == null) {
      return;
    }
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return;
    }

    final overlaySize = overlayBox.size;
    final topLeft = overlayBox.globalToLocal(buttonRect.topLeft);
    final bottomRight = overlayBox.globalToLocal(buttonRect.bottomRight);
    final targetRect = Rect.fromPoints(topLeft, bottomRight);
    final menuHeight = _pasteOptionsMenuHeight;
    final left = _clampDouble(
      targetRect.right - _pasteOptionsWidth,
      _pasteOptionsScreenMargin,
      overlaySize.width - _pasteOptionsWidth - _pasteOptionsScreenMargin,
    );
    final top = _clampDouble(
      targetRect.top - menuHeight - _pasteOptionsGap,
      _pasteOptionsScreenMargin,
      overlaySize.height - menuHeight - _pasteOptionsScreenMargin,
    );
    _hidePasteOptionsMenu();
    final hit = _pasteMenuHitAtGlobalPosition(
      globalPosition,
      menuOrigin: overlayBox.localToGlobal(Offset(left, top)),
    );
    _applyPasteMenuHit(hit);
    _pasteOptionsOverlay = OverlayEntry(builder: _buildPasteOptionsOverlay);
    overlay.insert(_pasteOptionsOverlay!);
  }

  Widget _buildPasteOptionsOverlay(BuildContext context) {
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return const SizedBox.shrink();
    }
    final layout = _pasteMenuLayout(overlayBox.size);
    if (layout == null) {
      return const SizedBox.shrink();
    }

    final snippetEntries = _expandedSnippetMenuEntries;
    final showSnippetMenu =
        _highlightedPasteAction == _PasteToolbarAction.snippets &&
        _snippetMenuEntries.isNotEmpty;

    return Stack(
      children: [
        Positioned.fromRect(
          rect: layout.mainMenuRect,
          child: _PasteOptionsMenu(
            highlightedAction: _highlightedPasteAction,
            snippetsEnabled: _areSnippetsEnabled,
            mediaEnabled: widget.onPasteMediaRequested != null,
            filesEnabled: widget.onPasteFilesRequested != null,
            snippetsTrailingIcon: layout.snippetMenuOpensLeft
                ? Icons.chevron_left_rounded
                : Icons.chevron_right_rounded,
          ),
        ),
        if (showSnippetMenu && layout.snippetMenuRect != null)
          Positioned.fromRect(
            rect: layout.snippetMenuRect!,
            child: _SnippetCascadeMenu(
              entries: snippetEntries,
              highlightedFolder: _highlightedSnippetFolder,
              highlightedSnippet: _highlightedSnippet,
            ),
          ),
      ],
    );
  }

  Rect? _pasteButtonGlobalRect() {
    final renderObject = _pasteButtonKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _updatePasteOptionsHighlight(LongPressMoveUpdateDetails details) {
    final hit = _pasteMenuHitAtGlobalPosition(details.globalPosition);
    if (hit == null &&
        _highlightedPasteAction == _PasteToolbarAction.snippets) {
      if (_highlightedSnippet == null) {
        return;
      }
      _highlightedSnippet = null;
      _pasteOptionsOverlay?.markNeedsBuild();
      return;
    }
    if (_isSamePasteMenuHit(hit, _currentPasteMenuHit)) {
      return;
    }
    _applyPasteMenuHit(hit);
    _pasteOptionsOverlay?.markNeedsBuild();
  }

  _PasteMenuHit? get _currentPasteMenuHit => _highlightedPasteAction == null
      ? null
      : _PasteMenuHit(
          action: _highlightedPasteAction!,
          folder: _highlightedSnippetFolder,
          snippet: _highlightedSnippet,
        );

  _PasteMenuHit? _pasteMenuHitAtGlobalPosition(
    Offset globalPosition, {
    Offset? menuOrigin,
  }) {
    final overlay = _pasteOptionsOverlay;
    if (overlay == null && menuOrigin == null) {
      return null;
    }
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return null;
    }
    final layout = _pasteMenuLayout(
      overlayBox.size,
      mainMenuOrigin: menuOrigin == null
          ? null
          : overlayBox.globalToLocal(menuOrigin),
    );
    if (layout == null) {
      return null;
    }

    final globalMainRect = _localRectToGlobal(overlayBox, layout.mainMenuRect);
    final globalSnippetRect = layout.snippetMenuRect == null
        ? null
        : _localRectToGlobal(overlayBox, layout.snippetMenuRect!);

    if (globalSnippetRect != null &&
        globalSnippetRect.contains(globalPosition)) {
      final entries = _expandedSnippetMenuEntries;
      final index =
          (globalPosition.dy - globalSnippetRect.top) ~/
          TerminalMenuStyles.itemHeight;
      if (index >= 0 && index < entries.length) {
        final entry = entries[index];
        return _PasteMenuHit(
          action: _PasteToolbarAction.snippets,
          folder: entry.folder ?? entry.parentFolder,
          snippet: entry.snippet,
        );
      }
    }

    if (!globalMainRect.contains(globalPosition)) {
      return null;
    }
    final index = _pasteMainActionIndexAt(
      globalPosition.dy - globalMainRect.top,
    );
    if (index < 0 || index >= _PasteToolbarAction.values.length) {
      return null;
    }
    final action = _PasteToolbarAction.values[index];
    return _isPasteActionEnabled(action) ? _PasteMenuHit(action: action) : null;
  }

  _PasteMenuLayout? _pasteMenuLayout(
    Size overlaySize, {
    Offset? mainMenuOrigin,
  }) {
    final buttonRect = _pasteButtonGlobalRect();
    if (buttonRect == null) {
      return null;
    }
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) {
      return null;
    }
    final topLeft = overlayBox.globalToLocal(buttonRect.topLeft);
    final bottomRight = overlayBox.globalToLocal(buttonRect.bottomRight);
    final targetRect = Rect.fromPoints(topLeft, bottomRight);
    final mainLeft =
        mainMenuOrigin?.dx ??
        _clampDouble(
          targetRect.right - _pasteOptionsWidth,
          _pasteOptionsScreenMargin,
          overlaySize.width - _pasteOptionsWidth - _pasteOptionsScreenMargin,
        );
    final mainTop =
        mainMenuOrigin?.dy ??
        _clampDouble(
          targetRect.top - _pasteOptionsMenuHeight - _pasteOptionsGap,
          _pasteOptionsScreenMargin,
          overlaySize.height -
              _pasteOptionsMenuHeight -
              _pasteOptionsScreenMargin,
        );
    final mainRect = Rect.fromLTWH(
      mainLeft,
      mainTop,
      _pasteOptionsWidth,
      _pasteOptionsMenuHeight,
    );
    final entries = _expandedSnippetMenuEntries;
    Rect? snippetMenuRect;
    var snippetMenuOpensLeft = true;
    if (entries.isNotEmpty) {
      final snippetMenuHeight = entries.length * TerminalMenuStyles.itemHeight;
      final canOpenLeft =
          mainRect.left -
              _pasteOptionsGap -
              _pasteSnippetMenuWidth -
              _pasteOptionsScreenMargin >=
          0;
      snippetMenuOpensLeft =
          canOpenLeft ||
          mainRect.right + _pasteOptionsGap + _pasteSnippetMenuWidth >
              overlaySize.width - _pasteOptionsScreenMargin;
      final snippetLeft = snippetMenuOpensLeft
          ? mainRect.left - _pasteOptionsGap - _pasteSnippetMenuWidth
          : mainRect.right + _pasteOptionsGap;
      snippetMenuRect = Rect.fromLTWH(
        _clampDouble(
          snippetLeft,
          _pasteOptionsScreenMargin,
          overlaySize.width -
              _pasteSnippetMenuWidth -
              _pasteOptionsScreenMargin,
        ),
        _clampDouble(
          mainRect.top,
          _pasteOptionsScreenMargin,
          overlaySize.height - snippetMenuHeight - _pasteOptionsScreenMargin,
        ),
        _pasteSnippetMenuWidth,
        snippetMenuHeight,
      );
    }

    return _PasteMenuLayout(
      mainMenuRect: mainRect,
      snippetMenuRect: snippetMenuRect,
      snippetMenuOpensLeft: snippetMenuOpensLeft,
    );
  }

  bool _isPasteActionEnabled(_PasteToolbarAction action) => switch (action) {
    _PasteToolbarAction.snippets => _areSnippetsEnabled,
    _PasteToolbarAction.media => widget.onPasteMediaRequested != null,
    _PasteToolbarAction.files => widget.onPasteFilesRequested != null,
  };

  bool get _areSnippetsEnabled =>
      widget.onSnippetPasteRequested != null && _snippetMenuEntries.isNotEmpty;

  double get _pasteOptionsMenuHeight =>
      _PasteToolbarAction.values.length * TerminalMenuStyles.itemHeight;

  int _pasteMainActionIndexAt(double localDy) {
    if (localDy < 0) {
      return -1;
    }
    for (var index = 0; index < _PasteToolbarAction.values.length; index += 1) {
      final top = index * TerminalMenuStyles.itemHeight;
      if (localDy >= top && localDy < top + TerminalMenuStyles.itemHeight) {
        return index;
      }
    }
    return -1;
  }

  List<_SnippetMenuEntry> get _snippetMenuEntries {
    final folderIds = widget.snippetFolders.map((folder) => folder.id).toSet();
    final entries = <_SnippetMenuEntry>[
      for (final folder in widget.snippetFolders)
        if (_snippetsInFolder(folder.id).isNotEmpty)
          _SnippetMenuEntry.folder(folder),
      for (final snippet in widget.snippets)
        if (snippet.folderId == null || !folderIds.contains(snippet.folderId))
          _SnippetMenuEntry.snippet(snippet),
    ];
    return entries;
  }

  List<_SnippetMenuEntry> get _expandedSnippetMenuEntries {
    final entries = _snippetMenuEntries;
    final folder = _highlightedSnippetFolder;
    if (folder == null) {
      return entries;
    }

    final expandedEntries = <_SnippetMenuEntry>[];
    for (final entry in entries) {
      expandedEntries.add(entry);
      if (entry.folder?.id == folder.id) {
        expandedEntries.addAll(
          _snippetsInFolder(
            folder.id,
          ).map((snippet) => _SnippetMenuEntry.snippet(snippet, folder)),
        );
      }
    }
    return expandedEntries;
  }

  List<KeyboardToolbarSnippet> _snippetsInFolder(int folderId) => widget
      .snippets
      .where((snippet) => snippet.folderId == folderId)
      .toList(growable: false);

  Rect _localRectToGlobal(RenderBox overlayBox, Rect rect) {
    final topLeft = overlayBox.localToGlobal(rect.topLeft);
    return topLeft & rect.size;
  }

  void _applyPasteMenuHit(_PasteMenuHit? hit) {
    _highlightedPasteAction = hit?.action;
    _highlightedSnippetFolder = hit?.folder;
    _highlightedSnippet = hit?.snippet;
  }

  bool _isSamePasteMenuHit(_PasteMenuHit? a, _PasteMenuHit? b) =>
      a?.action == b?.action &&
      a?.folder?.id == b?.folder?.id &&
      a?.snippet?.id == b?.snippet?.id;

  void _chooseHighlightedPasteOption(LongPressEndDetails details) {
    final hit = _pasteMenuHitAtGlobalPosition(details.globalPosition);
    final action = hit?.action ?? _highlightedPasteAction;
    final snippet = hit?.snippet;
    _hidePasteOptionsMenu();
    if (snippet != null) {
      unawaited(_runSnippetPasteAction(snippet));
      return;
    }
    switch (action) {
      case _PasteToolbarAction.snippets:
        _refocusTerminal();
      case _PasteToolbarAction.media:
        unawaited(_runToolbarAction(widget.onPasteMediaRequested));
      case _PasteToolbarAction.files:
        unawaited(_runToolbarAction(widget.onPasteFilesRequested));
      case null:
        _refocusTerminal();
    }
  }

  void _hidePasteOptionsMenu() {
    _pasteOptionsOverlay?.remove();
    _pasteOptionsOverlay = null;
    _highlightedPasteAction = null;
    _highlightedSnippetFolder = null;
    _highlightedSnippet = null;
  }

  Future<void> _runToolbarAction(FutureOr<void> Function()? action) async {
    if (action == null) {
      _refocusTerminal();
      return;
    }
    await action();
  }

  Future<void> _runSnippetPasteAction(KeyboardToolbarSnippet snippet) async {
    final action = widget.onSnippetPasteRequested;
    if (action == null) {
      _refocusTerminal();
      return;
    }
    await action(snippet);
  }

  void _consumeOneShot() {
    _controller.consumeOneShot();
    _refocusTerminal();
  }

  void _sendEscape() {
    HapticFeedback.lightImpact();
    if (widget.onSpecialKey case final sink?) {
      sink(TerminalKey.escape);
      widget.onKeyPressed?.call();
      _controller.consumeOneShot();
      _refocusTerminal();
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      widget.terminal.keyInput(TerminalKey.escape);
    } else {
      widget.terminal.textInput('\x1b');
    }
    widget.onKeyPressed?.call();
    // Clear one-shot modifiers without the immediate refocus that
    // _consumeOneShot() would do. Refocus after a short delay so the
    // remote terminal's escape-sequence parser times out the bare ESC
    // before the next keystroke can arrive and be misinterpreted as
    // Alt+<key>.
    _controller.consumeOneShot();
    Future<void>.delayed(const Duration(milliseconds: 100), _refocusTerminal);
  }

  void _sendTab() {
    HapticFeedback.lightImpact();
    if (widget.onSpecialKey case final sink?) {
      sink(TerminalKey.tab);
      widget.onKeyPressed?.call();
      _consumeOneShot();
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      widget.terminal.keyInput(
        TerminalKey.tab,
        shift: _controller.isShiftActive,
        alt: _controller.isAltActive,
        ctrl: _controller.isCtrlActive,
      );
    } else {
      widget.terminal.textInput(
        resolveTerminalTabInput(shiftActive: _controller.isShiftActive),
      );
    }
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendEnter() {
    HapticFeedback.lightImpact();
    if (widget.onSpecialKey case final sink?) {
      sink(TerminalKey.enter);
      widget.onKeyPressed?.call();
      _consumeOneShot();
      return;
    }
    sendTerminalEnterInput(
      widget.terminal,
      shiftActive: _controller.isShiftActive,
      altActive: _controller.isAltActive,
      ctrlActive: _controller.isCtrlActive,
    );
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendText(String text) {
    HapticFeedback.lightImpact();
    final textSink = widget.onTextInput;
    if (textSink != null) {
      textSink(_controller.isShiftActive ? text.toUpperCase() : text);
      widget.onKeyPressed?.call();
      _consumeOneShot();
      return;
    }

    var output = text;
    if (_controller.isCtrlActive) {
      final ctrlCode = _ctrlCodeForCharacter(output);
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
    }
    if (_controller.isAltActive) {
      // Alt/Meta sends ESC prefix.
      output = '\x1b$output';
    }
    if (_controller.isShiftActive) {
      output = output.toUpperCase();
    }

    widget.terminal.textInput(output);
    widget.onKeyPressed?.call();
    _consumeOneShot();
  }

  void _sendNavigationKey(
    TerminalKey key,
    String legacySequence, {
    bool withHaptic = true,
    bool consumeOneShot = true,
  }) {
    if (withHaptic) {
      HapticFeedback.lightImpact();
    }
    if (widget.onSpecialKey case final sink?) {
      sink(key);
      widget.onKeyPressed?.call();
      if (consumeOneShot) {
        _consumeOneShot();
      }
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      final handled = widget.terminal.keyInput(
        key,
        shift: _controller.isShiftActive,
        alt: _controller.isAltActive,
        ctrl: _controller.isCtrlActive,
      );
      if (!handled) {
        return;
      }
    } else {
      final modifier = _getModifierPrefix();
      final isArrow = switch (key) {
        TerminalKey.arrowUp ||
        TerminalKey.arrowDown ||
        TerminalKey.arrowLeft ||
        TerminalKey.arrowRight => true,
        _ => false,
      };
      widget.terminal.textInput(
        isArrow && modifier.isNotEmpty
            ? '\x1b[1;$modifier${legacySequence[2]}'
            : legacySequence,
      );
    }
    widget.onKeyPressed?.call();
    if (consumeOneShot) {
      _consumeOneShot();
    }
  }

  bool _shouldUseKittyKeyboardEncoding() =>
      widget.terminal.kittyKeyboardMode &&
      (widget.terminal.kittyKeyboardFlags &
              (KittyKeyboardFlags.disambiguateEscapeCodes |
                  KittyKeyboardFlags.reportAllKeysAsEscapeCodes)) !=
          0;

  String _getModifierPrefix() {
    var mod = 1;
    if (_controller.isShiftActive) mod += 1;
    if (_controller.isAltActive) mod += 2;
    if (_controller.isCtrlActive) mod += 4;
    return mod > 1 ? '$mod' : '';
  }
}

enum _Modifier { ctrl, alt, shift }

enum _PasteToolbarAction { snippets, media, files }

class _PasteMenuHit {
  const _PasteMenuHit({required this.action, this.folder, this.snippet});

  final _PasteToolbarAction action;
  final KeyboardToolbarSnippetFolder? folder;
  final KeyboardToolbarSnippet? snippet;
}

class _PasteMenuLayout {
  const _PasteMenuLayout({
    required this.mainMenuRect,
    required this.snippetMenuRect,
    required this.snippetMenuOpensLeft,
  });

  final Rect mainMenuRect;
  final Rect? snippetMenuRect;
  final bool snippetMenuOpensLeft;
}

class _SnippetMenuEntry {
  const _SnippetMenuEntry.folder(KeyboardToolbarSnippetFolder this.folder)
    : snippet = null,
      parentFolder = null;

  const _SnippetMenuEntry.snippet(this.snippet, [this.parentFolder])
    : folder = null;

  final KeyboardToolbarSnippetFolder? folder;
  final KeyboardToolbarSnippet? snippet;
  final KeyboardToolbarSnippetFolder? parentFolder;
}

double _clampDouble(double value, double min, double max) {
  final effectiveMax = max < min ? min : max;
  return value.clamp(min, effectiveMax);
}

class _PasteOptionsMenu extends StatelessWidget {
  const _PasteOptionsMenu({
    required this.highlightedAction,
    required this.snippetsEnabled,
    required this.mediaEnabled,
    required this.filesEnabled,
    required this.snippetsTrailingIcon,
  });

  final _PasteToolbarAction? highlightedAction;
  final bool snippetsEnabled;
  final bool mediaEnabled;
  final bool filesEnabled;
  final IconData snippetsTrailingIcon;

  @override
  Widget build(BuildContext context) => TerminalMenuStyles.surface(
    context,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PasteOptionsMenuItem(
          icon: Icons.code_rounded,
          label: 'Snippets',
          enabled: snippetsEnabled,
          highlighted: highlightedAction == _PasteToolbarAction.snippets,
          trailingIcon: snippetsTrailingIcon,
        ),
        _PasteOptionsMenuItem(
          icon: Icons.perm_media_outlined,
          label: 'Paste Media',
          enabled: mediaEnabled,
          highlighted: highlightedAction == _PasteToolbarAction.media,
        ),
        _PasteOptionsMenuItem(
          icon: Icons.attach_file_rounded,
          label: 'Paste Files',
          enabled: filesEnabled,
          highlighted: highlightedAction == _PasteToolbarAction.files,
        ),
      ],
    ),
  );
}

class _SnippetCascadeMenu extends StatelessWidget {
  const _SnippetCascadeMenu({
    required this.entries,
    required this.highlightedFolder,
    required this.highlightedSnippet,
  });

  final List<_SnippetMenuEntry> entries;
  final KeyboardToolbarSnippetFolder? highlightedFolder;
  final KeyboardToolbarSnippet? highlightedSnippet;

  @override
  Widget build(BuildContext context) => _CascadeMenuFrame(
    children: [
      for (final entry in entries)
        if (entry.folder case final folder?)
          _PasteOptionsMenuItem(
            icon: Icons.folder_outlined,
            label: folder.name,
            enabled: true,
            highlighted: highlightedFolder?.id == folder.id,
            trailingIcon: Icons.expand_more_rounded,
          )
        else if (entry.snippet case final snippet?)
          _PasteOptionsMenuItem(
            icon: Icons.code_rounded,
            label: snippet.name,
            enabled: true,
            highlighted: highlightedSnippet?.id == snippet.id,
            leadingIndent: entry.parentFolder == null ? 0 : 18,
          ),
    ],
  );
}

class _CascadeMenuFrame extends StatelessWidget {
  const _CascadeMenuFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => TerminalMenuStyles.surface(
    context,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _PasteOptionsMenuItem extends StatelessWidget {
  const _PasteOptionsMenuItem({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.highlighted,
    this.leadingIndent = 0,
    this.trailingIcon,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool highlighted;
  final double leadingIndent;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final contentColor = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurfaceVariant.withAlpha(96);
    final backgroundColor = highlighted && enabled
        ? colorScheme.primaryContainer
        : Colors.transparent;
    final foregroundColor = highlighted && enabled
        ? colorScheme.onPrimaryContainer
        : contentColor;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: highlighted,
      label: label,
      child: Container(
        height: TerminalMenuStyles.itemHeight,
        color: backgroundColor,
        padding: const EdgeInsets.symmetric(
          horizontal: TerminalMenuStyles.itemHorizontalPadding,
        ),
        child: Row(
          children: [
            if (leadingIndent > 0) SizedBox(width: leadingIndent),
            Icon(
              icon,
              size: TerminalMenuStyles.iconSize,
              color: foregroundColor,
            ),
            const SizedBox(width: TerminalMenuStyles.iconLabelGap),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TerminalMenuStyles.itemTextStyle(
                  context,
                  emphasized: highlighted,
                ).copyWith(color: foregroundColor),
              ),
            ),
            if (trailingIcon case final trailingIcon?) ...[
              const SizedBox(width: 8),
              Icon(
                trailingIcon,
                size: TerminalMenuStyles.iconSize,
                color: foregroundColor,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});

  static const height = 42.0;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: children.map((c) {
        if (c is Expanded) return c;
        return Expanded(child: c);
      }).toList(),
    ),
  );
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.mirrorIcon = false,
    this.onLongPressStart,
    this.onLongPressStartWithDetails,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.onLongPressRepeat,
    this.tooltip,
    this.semanticsHint,
    this.longPressIndicatorIcon,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool mirrorIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final GestureLongPressStartCallback? onLongPressStartWithDetails;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;
  final VoidCallback? onLongPressRepeat;
  final String? tooltip;
  final String? semanticsHint;
  final IconData? longPressIndicatorIcon;

  bool get hasLongPressHandler =>
      onLongPressStart != null ||
      onLongPressStartWithDetails != null ||
      onLongPressMoveUpdate != null ||
      onLongPressEnd != null ||
      onLongPressCancel != null ||
      onLongPressRepeat != null;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  static const _repeatInterval = Duration(milliseconds: 50);

  bool _isPressed = false;
  Timer? _repeatTimer;

  void _setPressed(bool isPressed) {
    if (_isPressed == isPressed || !mounted) {
      return;
    }
    setState(() => _isPressed = isPressed);
  }

  void _startRepeat() {
    final repeatAction = widget.onLongPressRepeat;
    if (repeatAction == null) {
      return;
    }

    _repeatTimer?.cancel();
    _setPressed(true);
    _repeatTimer = Timer.periodic(_repeatInterval, (_) {
      if (!mounted) {
        return;
      }
      repeatAction();
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _setPressed(false);
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  Widget _buildIcon(double size, Color color) {
    final icon = Icon(widget.icon, size: size, color: color);
    if (!widget.mirrorIcon) {
      return icon;
    }
    return Transform.flip(flipX: true, child: icon);
  }

  Widget _buildContent(Color color) {
    if (widget.icon != null && widget.label.isNotEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(14, color),
          const SizedBox(width: 3),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      );
    }
    if (widget.icon != null) {
      return _buildIcon(18, color);
    }
    return Text(
      widget.label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = colorScheme.onSurfaceVariant;

    Widget button = GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: _stopRepeat,
      onTap: widget.onTap,
      onLongPressStart: widget.hasLongPressHandler
          ? (details) {
              widget.onLongPressStart?.call();
              widget.onLongPressStartWithDetails?.call(details);
              if (widget.onLongPressRepeat != null) {
                _startRepeat();
              }
            }
          : null,
      onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
      onLongPressEnd: widget.hasLongPressHandler
          ? (details) {
              widget.onLongPressEnd?.call(details);
              _stopRepeat();
            }
          : null,
      onLongPressCancel: widget.hasLongPressHandler
          ? () {
              widget.onLongPressCancel?.call();
              _stopRepeat();
            }
          : null,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _isPressed
              ? colorScheme.primary.withAlpha(50)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: _isPressed ? Border.all(color: colorScheme.primary) : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _buildContent(foregroundColor),
                ),
              ),
            ),
            if (widget.longPressIndicatorIcon case final indicatorIcon?)
              Positioned(
                top: 2,
                right: 2,
                child: Icon(
                  indicatorIcon,
                  size: 11,
                  color: colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      hint: widget.semanticsHint,
      child: button,
    );
  }
}

class _ModifierButton extends StatefulWidget {
  const _ModifierButton({
    required this.label,
    required this.state,
    required this.onTap,
    required this.onDoubleTap,
    this.icon,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final bool? state; // null = off, false = one-shot, true = locked
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final String? tooltip;

  @override
  State<_ModifierButton> createState() => _ModifierButtonState();
}

class _ModifierButtonState extends State<_ModifierButton> {
  static const _doubleTapTimeout = Duration(milliseconds: 300);
  DateTime? _lastTapTime;

  void _handleTap() {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < _doubleTapTimeout) {
      _lastTapTime = null;
      // Undo the single-tap toggle before applying double-tap lock,
      // so the lock/unlock sees the original state.
      widget.onTap();
      widget.onDoubleTap();
    } else {
      _lastTapTime = now;
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final Color bgColor;
    final Color textColor;
    final IconData? lockIcon;

    if (widget.state == null) {
      bgColor = colorScheme.surfaceContainerHighest;
      textColor = colorScheme.onSurfaceVariant;
      lockIcon = null;
    } else if (widget.state == false) {
      bgColor = colorScheme.primaryContainer;
      textColor = colorScheme.onPrimaryContainer;
      lockIcon = null;
    } else {
      bgColor = colorScheme.primary;
      textColor = colorScheme.onPrimary;
      lockIcon = Icons.lock;
    }

    Widget button = GestureDetector(
      onTap: _handleTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 14, color: textColor),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                  if (lockIcon != null) ...[
                    const SizedBox(width: 2),
                    Icon(lockIcon, size: 10, color: textColor),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      toggled: widget.state != null,
      value: switch (widget.state) {
        null => 'off',
        false => 'one-shot',
        true => 'locked',
      },
      child: button,
    );
  }
}
