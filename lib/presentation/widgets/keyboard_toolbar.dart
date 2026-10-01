import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../app/theme.dart';
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

/// Ctrl chords offered by pressing and holding the toolbar's Ctrl key.
///
/// Declaration order is the column menu's top-to-bottom order, so the last
/// entry sits closest to the finger holding Ctrl. The single-row fallback
/// reverses it so that entry sits leftmost, directly above the key.
enum KeyboardToolbarCtrlShortcut {
  /// Ctrl+R, reverse history search in most shells.
  historySearch('R', TerminalKey.keyR, 'History search'),

  /// Ctrl+L, clear or redraw the screen.
  clearScreen('L', TerminalKey.keyL, 'Clear screen'),

  /// Ctrl+Z, suspend the foreground job.
  suspend('Z', TerminalKey.keyZ, 'Suspend'),

  /// Ctrl+D, end of input.
  endOfInput('D', TerminalKey.keyD, 'End of input'),

  /// Ctrl+C, interrupt the foreground job.
  interrupt('C', TerminalKey.keyC, 'Interrupt');

  const KeyboardToolbarCtrlShortcut(this.letter, this.key, this.description);

  /// Letter pressed together with Ctrl.
  final String letter;

  /// Key sent with Ctrl through the terminal key encoder.
  final TerminalKey key;

  /// Short description of the chord's usual shell meaning.
  final String description;

  /// Spoken chord name, such as `Ctrl+C`, for semantics.
  String get label => 'Ctrl+$letter';

  /// Displayed chord, such as `⌃C`, matching the Ctrl key's glyph.
  String get symbol => '\u2303$letter';
}

/// A character in a symbol key's menu and its spoken name.
typedef _MenuSymbol = (String symbol, String name);

/// Characters behind the `|`, `/` and `~` keys, nearest the key first.
///
/// `-` sits behind `/` because command-line flags need it constantly and
/// phone keyboards keep it off the letter layout. `\` pairs with `|` and the
/// backtick with `~`, as they share a key on a physical keyboard.
const _pipeSymbols = <_MenuSymbol>[
  (r'\', 'Backslash'),
  ('&', 'Ampersand'),
  (';', 'Semicolon'),
  ('>', 'Greater than'),
  ('<', 'Less than'),
  ('!', 'Exclamation mark'),
];
const _slashSymbols = <_MenuSymbol>[
  ('-', 'Dash'),
  ('_', 'Underscore'),
  ('=', 'Equals'),
  (':', 'Colon'),
  ('*', 'Asterisk'),
  ('+', 'Plus'),
];
const _tildeSymbols = <_MenuSymbol>[
  ('`', 'Backtick'),
  (r'$', 'Dollar'),
  ('@', 'At sign'),
  ('#', 'Hash'),
  ('%', 'Percent'),
  ('^', 'Caret'),
];

/// Function keys behind Esc, which heads the function-key row on a physical
/// keyboard.
const _functionKeys = [
  TerminalKey.f1,
  TerminalKey.f2,
  TerminalKey.f3,
  TerminalKey.f4,
  TerminalKey.f5,
  TerminalKey.f6,
  TerminalKey.f7,
  TerminalKey.f8,
  TerminalKey.f9,
  TerminalKey.f10,
  TerminalKey.f11,
  TerminalKey.f12,
];

/// Compact keyboard toolbar for terminal input.
///
/// Features:
/// - Modifier keys (Ctrl, Alt, Shift) with toggle/lock functionality
/// - Navigation keys (arrows, Home, End, PgUp, PgDn)
/// - Special keys (Esc, Tab, Enter, pipe, etc.)
/// - Menus opened by holding or swiping up on a key: F1-F12 on Esc,
///   Shift+Tab on Tab, common Ctrl chords on Ctrl, more symbols on `|`, `/`
///   and `~`, and paste options on Paste
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
  static const _menuGap = TerminalMenuStyles.cascadeGap;
  static const _menuScreenMargin = TerminalMenuStyles.screenMargin;

  late final KeyboardToolbarController _fallbackController;
  final _pasteButtonKey = GlobalKey();
  final _menuKeyAnchors = <_MenuKey, GlobalKey>{
    for (final key in _MenuKey.values) key: GlobalKey(),
  };
  OverlayEntry? _pasteOptionsOverlay;
  _PasteToolbarAction? _highlightedPasteAction;
  KeyboardToolbarSnippetFolder? _highlightedSnippetFolder;
  KeyboardToolbarSnippet? _highlightedSnippet;
  OverlayEntry? _keyMenuOverlay;
  _MenuKey? _openKeyMenu;
  int? _highlightedKeyMenuItem;

  KeyboardToolbarController get _controller =>
      widget.controller ?? _fallbackController;

  /// Function keys, Shift+Tab and Ctrl chords are terminal key sequences, so
  /// their menus are only offered when the toolbar writes to
  /// [KeyboardToolbar.terminal] rather than a custom sink.
  bool get _sendsToTerminal =>
      widget.onTextInput == null && widget.onSpecialKey == null;

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
    if (_openKeyMenu case final key? when _keyMenuFor(key) == null) {
      _hideKeyMenu();
    }
  }

  @override
  void dispose() {
    _hidePasteOptionsMenu();
    _hideKeyMenu();
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

  Widget _buildModifierRow() =>
      _KeyRow(hasFlickLabels: true, children: _buildModifierButtons());

  Widget _buildNavigationRow() =>
      _KeyRow(children: [..._buildNavigationButtons(), _buildEnterButton()]);

  Widget _buildLandscapeRow() => _KeyRow(
    hasFlickLabels: true,
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

  List<Widget> _buildModifierButtons() {
    final ctrlMenu = _keyMenuFor(_MenuKey.ctrl);
    return [
      _menuKeyButton(
        _MenuKey.escape,
        icon: Icons.cancel_outlined,
        label: 'Esc',
        onTap: _sendEscape,
        tooltip: 'Escape',
        menuName: 'function keys',
      ),
      _menuKeyButton(
        _MenuKey.tab,
        icon: Icons.keyboard_tab_rounded,
        mirrorIcon: _controller.isShiftActive,
        label: 'Tab',
        onTap: _sendTab,
        tooltip: 'Tab',
        menuName: 'Shift+Tab',
      ),
      _ModifierButton(
        key: _menuKeyAnchors[_MenuKey.ctrl],
        icon: Icons.keyboard_control_key_rounded,
        label: 'Ctrl',
        state: _controller.ctrlState,
        onTap: _toggleCtrl,
        onDoubleTap: _lockCtrl,
        menuGesture: _keyMenuGesture(_MenuKey.ctrl),
        flickLabel: ctrlMenu?.flickLabel,
        semanticsHint: ctrlMenu == null
            ? null
            : 'Press and hold or swipe up for Ctrl shortcuts',
        customSemanticsActions: ctrlMenu == null
            ? null
            : _keyMenuSemanticsActions(ctrlMenu),
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
      for (final (menuKey, label, tooltip) in const [
        (_MenuKey.pipe, '|', 'Pipe'),
        (_MenuKey.slash, '/', 'Slash'),
        (_MenuKey.tilde, '~', 'Tilde'),
      ])
        _menuKeyButton(
          menuKey,
          label: label,
          onTap: () => _sendText(label),
          tooltip: tooltip,
          menuName: 'more symbols',
        ),
      _buildPasteButton(),
    ];
  }

  /// A key that opens [menuKey]'s menu on press-and-hold or an upward swipe.
  ///
  /// When the key has no menu (Esc and Tab with a custom input sink), holding
  /// it sends its tap once, so a slow press is not lost.
  Widget _menuKeyButton(
    _MenuKey menuKey, {
    required String label,
    required VoidCallback onTap,
    required String tooltip,
    required String menuName,
    IconData? icon,
    bool mirrorIcon = false,
  }) {
    final menu = _keyMenuFor(menuKey);
    return _ToolbarButton(
      key: _menuKeyAnchors[menuKey],
      icon: icon,
      mirrorIcon: mirrorIcon,
      label: label,
      onTap: onTap,
      onLongPressStart: menu == null ? onTap : null,
      menuGesture: _keyMenuGesture(menuKey),
      flickLabel: menu?.flickLabel,
      semanticsHint: menu == null
          ? null
          : 'Press and hold or swipe up for $menuName',
      customSemanticsActions: menu == null
          ? null
          : _keyMenuSemanticsActions(menu),
      tooltip: tooltip,
    );
  }

  Widget _buildPasteButton() => _ToolbarButton(
    key: _pasteButtonKey,
    icon: Icons.paste_rounded,
    label: 'Paste',
    onTap: _pasteClipboard,
    menuGesture: _KeyMenuGesture(
      onOpen: _showPasteOptions,
      onMove: _updatePasteOptionsHighlight,
      onRelease: _chooseHighlightedPasteOption,
      onCancel: _hidePasteOptionsMenu,
    ),
    // A list of unlike options, so no single item stands for it.
    flickLabel: '\u2026',
    semanticsHint: 'Press and hold or swipe up for paste options',
    tooltip: 'Paste',
  );

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

  void _showPasteOptions(Offset globalPosition) {
    _hideKeyMenu();
    HapticFeedback.mediumImpact();
    widget.onKeyPressed?.call();
    _consumeOneShot();
    _showPasteOptionsMenu(globalPosition);
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

    final topLeft = overlayBox.globalToLocal(buttonRect.topLeft);
    final bottomRight = overlayBox.globalToLocal(buttonRect.bottomRight);
    final origin = _pasteMainMenuOrigin(
      Rect.fromPoints(topLeft, bottomRight),
      overlayBox.size,
    );
    _hidePasteOptionsMenu();
    final hit = _pasteMenuHitAtGlobalPosition(
      globalPosition,
      menuOrigin: overlayBox.localToGlobal(origin),
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

  void _updatePasteOptionsHighlight(Offset globalPosition) {
    final hit = _pasteMenuHitAtGlobalPosition(globalPosition);
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
    if (hit != null) {
      // Tick each row the finger crosses, as the other key menus do.
      HapticFeedback.selectionClick();
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

  /// Top-left of the main Paste menu in overlay coordinates: above the key and
  /// right-aligned with it.
  ///
  /// Like the other key menus it never opens over the key. Without room above
  /// it (a landscape phone with the keyboard up), the menu sits beside the key
  /// instead of being clamped down over it, where the finger would start
  /// inside it and a plain release would choose an option.
  Offset _pasteMainMenuOrigin(Rect targetRect, Size overlaySize) {
    const margin = _menuScreenMargin;
    final height = _pasteOptionsMenuHeight;
    final maxLeft = overlaySize.width - _pasteOptionsWidth - margin;
    final top = targetRect.top - _menuGap - height;
    if (top >= margin) {
      return Offset(
        _clampDouble(targetRect.right - _pasteOptionsWidth, margin, maxLeft),
        top,
      );
    }
    final leftOfKey = targetRect.left - _menuGap - _pasteOptionsWidth;
    return Offset(
      _clampDouble(
        leftOfKey >= margin ? leftOfKey : targetRect.right + _menuGap,
        margin,
        maxLeft,
      ),
      _clampDouble(
        targetRect.bottom - height,
        margin,
        overlaySize.height - height - margin,
      ),
    );
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
    final mainRect =
        (mainMenuOrigin ?? _pasteMainMenuOrigin(targetRect, overlaySize)) &
        Size(_pasteOptionsWidth, _pasteOptionsMenuHeight);
    final entries = _expandedSnippetMenuEntries;
    Rect? snippetMenuRect;
    var snippetMenuOpensLeft = true;
    if (entries.isNotEmpty) {
      final snippetMenuHeight = entries.length * TerminalMenuStyles.itemHeight;
      final canOpenLeft =
          mainRect.left -
              _menuGap -
              _pasteSnippetMenuWidth -
              _menuScreenMargin >=
          0;
      snippetMenuOpensLeft =
          canOpenLeft ||
          mainRect.right + _menuGap + _pasteSnippetMenuWidth >
              overlaySize.width - _menuScreenMargin;
      final snippetLeft = snippetMenuOpensLeft
          ? mainRect.left - _menuGap - _pasteSnippetMenuWidth
          : mainRect.right + _menuGap;
      snippetMenuRect = Rect.fromLTWH(
        _clampDouble(
          snippetLeft,
          _menuScreenMargin,
          overlaySize.width - _pasteSnippetMenuWidth - _menuScreenMargin,
        ),
        _clampDouble(
          mainRect.top,
          _menuScreenMargin,
          overlaySize.height - snippetMenuHeight - _menuScreenMargin,
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
          _snippetsInFolder(folder.id)
              .map((snippet) => _SnippetMenuEntry.snippet(snippet, folder)),
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

  /// Chooses the option under the finger where it lifted. As in the other key
  /// menus there is no fallback to the last highlight: a swipe that lifts off
  /// the menu without a final move over it cancels.
  void _chooseHighlightedPasteOption(Offset globalPosition) {
    final hit = _pasteMenuHitAtGlobalPosition(globalPosition);
    _hidePasteOptionsMenu();
    if (hit?.snippet case final snippet?) {
      HapticFeedback.lightImpact();
      unawaited(_runSnippetPasteAction(snippet));
      return;
    }
    switch (hit?.action) {
      case _PasteToolbarAction.media:
        HapticFeedback.lightImpact();
        unawaited(_runToolbarAction(widget.onPasteMediaRequested));
      case _PasteToolbarAction.files:
        HapticFeedback.lightImpact();
        unawaited(_runToolbarAction(widget.onPasteFilesRequested));
      case _PasteToolbarAction.snippets || null:
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

  /// The menu [key] opens, or null when it has none.
  ///
  /// Symbols are plain text and go to any sink; the other menus send terminal
  /// key sequences (see [_sendsToTerminal]).
  _KeyMenu? _keyMenuFor(_MenuKey key) => switch (key) {
    _MenuKey.escape when _sendsToTerminal => _KeyMenu(
      items: [
        for (final (index, functionKey) in _functionKeys.indexed)
          _KeyMenuItem(
            symbol: 'F${index + 1}',
            semanticsLabel: 'F${index + 1}',
            onSelected: () => _dispatcher.sendFunctionKey(functionKey),
          ),
      ],
      // F1-F4, F5-F8 and F9-F12 rows, grouped as on a physical keyboard.
      gridColumns: 4,
      cellWidth: 56,
      flickLabel: 'F1\u201312',
    ),
    _MenuKey.tab when _sendsToTerminal => _KeyMenu(
      items: [
        _KeyMenuItem(
          symbol: '⇧Tab',
          semanticsLabel: 'Shift+Tab',
          onSelected: () => _dispatcher.sendBackTab(),
        ),
      ],
      gridColumns: 1,
      cellWidth: 72,
    ),
    _MenuKey.ctrl when _sendsToTerminal => _KeyMenu(
      items: [
        for (final shortcut in KeyboardToolbarCtrlShortcut.values.reversed)
          _KeyMenuItem(
            symbol: shortcut.symbol,
            description: shortcut.description,
            semanticsLabel: shortcut.label,
            onSelected: () => _dispatcher.sendCtrlShortcut(shortcut),
          ),
      ],
      listWidth: 200,
      gridColumns: KeyboardToolbarCtrlShortcut.values.length,
      cellWidth: 88,
    ),
    _MenuKey.pipe => _symbolMenu(_pipeSymbols),
    _MenuKey.slash => _symbolMenu(_slashSymbols),
    _MenuKey.tilde => _symbolMenu(_tildeSymbols),
    _ => null,
  };

  _KeyMenu _symbolMenu(List<_MenuSymbol> symbols) => _KeyMenu(
    items: [
      for (final (symbol, name) in symbols)
        _KeyMenuItem(
          symbol: symbol,
          semanticsLabel: name,
          onSelected: () => _sendText(symbol),
        ),
    ],
    gridColumns: symbols.length,
    cellWidth: 44,
    symbolFontSize: 20,
  );

  _KeyMenuGesture? _keyMenuGesture(_MenuKey key) => _keyMenuFor(key) == null
      ? null
      : _KeyMenuGesture(
          onOpen: (position) => _showKeyMenu(key, position),
          onMove: (position) => _updateKeyMenuHighlight(key, position),
          onRelease: (position) => _chooseKeyMenuItem(key, position),
          onCancel: () => _hideKeyMenu(key),
        );

  /// Lets screen readers send each menu item from the key itself, since the
  /// menu exists only while a finger holds it.
  Map<CustomSemanticsAction, VoidCallback> _keyMenuSemanticsActions(
    _KeyMenu menu,
  ) => {
    for (final item in menu.items)
      CustomSemanticsAction(label: 'Send ${item.semanticsLabel}'):
          item.onSelected,
  };

  void _showKeyMenu(_MenuKey key, Offset globalPosition) {
    _hideKeyMenu();
    _hidePasteOptionsMenu();
    if (_keyMenuFor(key) == null) {
      return;
    }
    HapticFeedback.mediumImpact();
    _openKeyMenu = key;
    // A fast swipe can already be over the nearest item when the menu opens.
    _highlightedKeyMenuItem = _keyMenuItemAtGlobalPosition(key, globalPosition);
    _keyMenuOverlay = OverlayEntry(builder: _buildKeyMenuOverlay);
    Overlay.of(context).insert(_keyMenuOverlay!);
  }

  Widget _buildKeyMenuOverlay(BuildContext context) {
    final key = _openKeyMenu;
    final menu = key == null ? null : _keyMenuFor(key);
    final layout = menu == null ? null : _keyMenuLayout(key!, menu);
    if (menu == null || layout == null) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        Positioned.fromRect(
          rect: layout.rect,
          child: _KeyMenuView(
            menu: menu,
            layout: layout,
            highlighted: _highlightedKeyMenuItem,
          ),
        ),
      ],
    );
  }

  /// The geometry of [key]'s menu in overlay coordinates, opening upward from
  /// the key.
  ///
  /// A menu with a list width is a column of described rows, left-aligned with
  /// the key, when it fits above it. Otherwise it is a grid that gives up rows,
  /// down to a single row, until it fits: a phone with the keyboard up can lack
  /// the room, and clamping the menu down over the key would start the finger
  /// inside it, so a plain release would choose an item.
  _KeyMenuLayout? _keyMenuLayout(_MenuKey key, _KeyMenu menu) {
    final button = _menuKeyAnchors[key]!.currentContext?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (button is! RenderBox || overlayBox is! RenderBox) {
      return null;
    }
    final buttonRect =
        overlayBox.globalToLocal(button.localToGlobal(Offset.zero)) &
        button.size;
    final overlaySize = overlayBox.size;
    const margin = _menuScreenMargin;
    const itemHeight = TerminalMenuStyles.itemHeight;
    final count = menu.items.length;
    final roomAbove = buttonRect.top - _menuGap - margin;

    if (menu.listWidth case final listWidth?
        when count * itemHeight <= roomAbove) {
      final height = count * itemHeight;
      return _KeyMenuLayout(
        rect: Rect.fromLTWH(
          _clampDouble(
            buttonRect.left,
            margin,
            overlaySize.width - listWidth - margin,
          ),
          buttonRect.top - _menuGap - height,
          listWidth,
          height,
        ),
        rows: count,
        columns: 1,
        itemCount: count,
        isList: true,
      );
    }

    var rows = (count / menu.gridColumns).ceil();
    while (rows > 1 && rows * itemHeight > roomAbove) {
      rows -= 1;
    }
    final columns = (count / rows).ceil();

    // The first item's cell is centered over the key so a straight swipe up
    // lands on it, and the grid grows toward the side that leaves wider cells.
    // When that side is short the cells shrink, rather than the grid sliding
    // over and putting the second item above the key.
    final center = buttonRect.center.dx;
    double cellWidthFor(double room) => [
      menu.cellWidth,
      room / (columns - 0.5),
      (overlaySize.width - 2 * margin) / columns,
    ].reduce(math.min);
    final rightCellWidth = cellWidthFor(overlaySize.width - margin - center);
    final leftCellWidth = cellWidthFor(center - margin);
    final isMirrored = leftCellWidth > rightCellWidth;
    final cellWidth = isMirrored ? leftCellWidth : rightCellWidth;
    final width = columns * cellWidth;
    final height = rows * itemHeight;
    return _KeyMenuLayout(
      rect: Rect.fromLTWH(
        _clampDouble(
          isMirrored ? center + cellWidth / 2 - width : center - cellWidth / 2,
          margin,
          overlaySize.width - width - margin,
        ),
        _clampDouble(
          buttonRect.top - _menuGap - height,
          margin,
          overlaySize.height - height - margin,
        ),
        width,
        height,
      ),
      rows: rows,
      columns: columns,
      itemCount: count,
      isMirrored: isMirrored,
    );
  }

  int? _keyMenuItemAtGlobalPosition(_MenuKey key, Offset globalPosition) {
    final menu = _keyMenuFor(key);
    final layout = menu == null ? null : _keyMenuLayout(key, menu);
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (layout == null || overlayBox is! RenderBox) {
      return null;
    }
    return layout.itemAt(overlayBox.globalToLocal(globalPosition));
  }

  void _updateKeyMenuHighlight(_MenuKey key, Offset globalPosition) {
    if (_openKeyMenu != key) {
      return;
    }
    final item = _keyMenuItemAtGlobalPosition(key, globalPosition);
    if (item == _highlightedKeyMenuItem) {
      return;
    }
    if (item != null) {
      // The finger covers the items nearest the key, so tick each one it
      // crosses.
      HapticFeedback.selectionClick();
    }
    _highlightedKeyMenuItem = item;
    _keyMenuOverlay?.markNeedsBuild();
  }

  /// Sends the item under the finger where it lifted. There is no fallback to
  /// the last highlight: releasing off the menu cancels, so a slow tap, an
  /// overshooting swipe or a slide away never sends an unintended key.
  void _chooseKeyMenuItem(_MenuKey key, Offset globalPosition) {
    if (_openKeyMenu != key) {
      return;
    }
    final menu = _keyMenuFor(key);
    final item = _keyMenuItemAtGlobalPosition(key, globalPosition);
    _hideKeyMenu();
    if (menu == null || item == null) {
      _refocusTerminal();
      return;
    }
    menu.items[item].onSelected();
  }

  /// Closes the open key menu, or only [key]'s when given, so a gesture on one
  /// key cannot close a menu another finger opened.
  void _hideKeyMenu([_MenuKey? key]) {
    if (key != null && key != _openKeyMenu) {
      return;
    }
    _keyMenuOverlay?.remove();
    _keyMenuOverlay = null;
    _openKeyMenu = null;
    _highlightedKeyMenuItem = null;
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

  TerminalToolbarDispatcher get _dispatcher => TerminalToolbarDispatcher(
    terminal: widget.terminal,
    controller: _controller,
    refocusTerminal: _refocusTerminal,
    onSpecialKey: widget.onSpecialKey,
    onTextInput: widget.onTextInput,
    onKeyPressed: widget.onKeyPressed,
  );
  void _consumeOneShot() {
    _controller.consumeOneShot();
    _refocusTerminal();
  }

  void _sendEscape() => _dispatcher.sendEscape();
  void _sendTab() => _dispatcher.sendTab();
  void _sendEnter() => _dispatcher.sendEnter();
  void _sendText(String text) => _dispatcher.sendText(text);
  void _sendNavigationKey(
    TerminalKey key,
    String legacySequence, {
    bool withHaptic = true,
    bool consumeOneShot = true,
  }) => _dispatcher.sendNavigationKey(
    key,
    legacySequence,
    withHaptic: withHaptic,
    consumeOneShot: consumeOneShot,
  );
}

/// Sends toolbar input and consumes modifiers in the same order as the widget.
class TerminalToolbarDispatcher {
  /// Creates an input dispatcher with injectable platform feedback and focus.
  TerminalToolbarDispatcher({
    required this.terminal,
    required this.controller,
    required this.refocusTerminal,
    this.onSpecialKey,
    this.onTextInput,
    this.onKeyPressed,
    this.lightImpact = HapticFeedback.lightImpact,
  });

  /// Terminal receiving encoded input when no custom sink is set.
  final Terminal terminal;

  /// Modifier state consumed by each dispatched key.
  final KeyboardToolbarController controller;

  /// Restores terminal focus after dispatch.
  final VoidCallback refocusTerminal;

  /// Optional custom sink for special keys.
  final void Function(TerminalKey)? onSpecialKey;

  /// Optional custom sink for text input.
  final ValueChanged<String>? onTextInput;

  /// Notifies the owner after input was dispatched.
  final VoidCallback? onKeyPressed;

  /// Produces the key press haptic feedback.
  final Future<void> Function() lightImpact;
  void _consumeOneShot() {
    controller.consumeOneShot();
    refocusTerminal();
  }

  /// Sends Escape and delays legacy-terminal refocus by 100 milliseconds.
  void sendEscape() {
    lightImpact();
    if (onSpecialKey case final sink?) {
      sink(TerminalKey.escape);
      onKeyPressed?.call();
      controller.consumeOneShot();
      refocusTerminal();
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      terminal.keyInput(TerminalKey.escape);
    } else {
      terminal.textInput('\x1b');
    }
    onKeyPressed?.call();
    // Clear one-shot modifiers without the immediate refocus that
    // _consumeOneShot() would do. Refocus after a short delay so the
    // remote terminal's escape-sequence parser times out the bare ESC
    // before the next keystroke can arrive and be misinterpreted as
    // Alt+<key>.
    controller.consumeOneShot();
    Future<void>.delayed(const Duration(milliseconds: 100), refocusTerminal);
  }

  /// Sends Tab with explicit toolbar modifiers.
  void sendTab() {
    lightImpact();
    if (onSpecialKey case final sink?) {
      sink(TerminalKey.tab);
      onKeyPressed?.call();
      _consumeOneShot();
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      terminal.keyInput(
        TerminalKey.tab,
        shift: controller.isShiftActive,
        alt: controller.isAltActive,
        ctrl: controller.isCtrlActive,
      );
    } else {
      terminal.textInput(
        resolveTerminalTabInput(shiftActive: controller.isShiftActive),
      );
    }
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends Enter using the terminal enter-encoding policy.
  void sendEnter() {
    lightImpact();
    if (onSpecialKey case final sink?) {
      sink(TerminalKey.enter);
      onKeyPressed?.call();
      _consumeOneShot();
      return;
    }
    sendTerminalEnterInput(
      terminal,
      shiftActive: controller.isShiftActive,
      altActive: controller.isAltActive,
      ctrlActive: controller.isCtrlActive,
    );
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends text through the custom sink or applies terminal modifiers.
  void sendText(String text) {
    lightImpact();
    final textSink = onTextInput;
    if (textSink != null) {
      textSink(controller.isShiftActive ? text.toUpperCase() : text);
      onKeyPressed?.call();
      _consumeOneShot();
      return;
    }

    var output = text;
    if (controller.isCtrlActive) {
      final ctrlCode = _ctrlCodeForCharacter(output);
      if (ctrlCode != null) {
        output = String.fromCharCode(ctrlCode);
      }
    }
    if (controller.isAltActive) {
      // Alt/Meta sends ESC prefix.
      output = '\x1b$output';
    }
    if (controller.isShiftActive) {
      output = output.toUpperCase();
    }

    terminal.textInput(output);
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends a Ctrl chord from the Ctrl key's menu.
  ///
  /// The menu names an exact chord, so armed Alt and Shift are not added to
  /// it; one-shot modifiers are still consumed like any other key press.
  /// Kitty keyboard mode gets the same CSI-u encoding as a hardware keyboard,
  /// otherwise the legacy control byte. Always writes to [terminal]; custom
  /// sinks cannot carry a control chord.
  void sendCtrlShortcut(KeyboardToolbarCtrlShortcut shortcut) {
    lightImpact();
    if (_shouldUseKittyKeyboardEncoding()) {
      terminal.keyInput(shortcut.key, ctrl: true);
    } else {
      terminal.textInput(
        String.fromCharCode(_ctrlCodeForCharacter(shortcut.letter)!),
      );
    }
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends a function key from the Esc key's menu with any armed modifiers,
  /// encoded as a hardware keyboard's function key would be. Always writes to
  /// [terminal]; custom sinks cannot carry a function key.
  void sendFunctionKey(TerminalKey key) {
    lightImpact();
    terminal.keyInput(
      key,
      shift: controller.isShiftActive,
      alt: controller.isAltActive,
      ctrl: controller.isCtrlActive,
    );
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends Shift+Tab from the Tab key's menu.
  ///
  /// Like a Ctrl chord the menu names an exact chord, so armed modifiers are
  /// consumed but not added. Always writes to [terminal].
  void sendBackTab() {
    lightImpact();
    if (_shouldUseKittyKeyboardEncoding()) {
      terminal.keyInput(TerminalKey.tab, shift: true);
    } else {
      terminal.textInput(resolveTerminalTabInput(shiftActive: true));
    }
    onKeyPressed?.call();
    _consumeOneShot();
  }

  /// Sends a navigation key with optional feedback and modifier consumption.
  void sendNavigationKey(
    TerminalKey key,
    String legacySequence, {
    bool withHaptic = true,
    bool consumeOneShot = true,
  }) {
    if (withHaptic) {
      lightImpact();
    }
    if (onSpecialKey case final sink?) {
      sink(key);
      onKeyPressed?.call();
      if (consumeOneShot) {
        _consumeOneShot();
      }
      return;
    }
    if (_shouldUseKittyKeyboardEncoding()) {
      final handled = terminal.keyInput(
        key,
        shift: controller.isShiftActive,
        alt: controller.isAltActive,
        ctrl: controller.isCtrlActive,
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
      terminal.textInput(
        isArrow && modifier.isNotEmpty
            ? '\x1b[1;$modifier${legacySequence[2]}'
            : legacySequence,
      );
    }
    onKeyPressed?.call();
    if (consumeOneShot) {
      _consumeOneShot();
    }
  }

  bool _shouldUseKittyKeyboardEncoding() =>
      terminal.kittyKeyboardMode &&
      (terminal.kittyKeyboardFlags &
              (KittyKeyboardFlags.disambiguateEscapeCodes |
                  KittyKeyboardFlags.reportAllKeysAsEscapeCodes)) !=
          0;

  String _getModifierPrefix() {
    var mod = 1;
    if (controller.isShiftActive) mod += 1;
    if (controller.isAltActive) mod += 2;
    if (controller.isCtrlActive) mod += 4;
    return mod > 1 ? '$mod' : '';
  }
}

enum _Modifier { ctrl, alt, shift }

/// Toolbar keys with a slide-to-select menu, apart from Paste, whose menu
/// cascades into snippet folders.
enum _MenuKey { escape, tab, ctrl, pipe, slash, tilde }

/// One choice in a key's slide-to-select menu.
class _KeyMenuItem {
  const _KeyMenuItem({
    required this.symbol,
    required this.semanticsLabel,
    required this.onSelected,
    this.description,
  });

  /// What the cell shows, such as `⌃C`, `-` or `F5`.
  final String symbol;

  /// The item's usual meaning, shown beside or below [symbol].
  final String? description;

  /// Spoken name, such as `Ctrl+C` or `Dash`.
  final String semanticsLabel;

  /// Sends the item.
  final VoidCallback onSelected;
}

/// The items a key offers by holding or swiping up from it, and the shapes
/// the menu may take.
class _KeyMenu {
  const _KeyMenu({
    required this.items,
    required this.gridColumns,
    required this.cellWidth,
    this.listWidth,
    this.symbolFontSize,
    String? flickLabel,
  }) : _flickLabel = flickLabel;

  /// Items nearest the key first, so a straight swipe up lands on the first.
  final List<_KeyMenuItem> items;

  /// Columns of the grid when all of its rows fit above the key.
  final int gridColumns;

  /// Widest a grid cell gets.
  final double cellWidth;

  /// Width of a one-column list with descriptions beside the symbols, used
  /// when it fits above the key. Null for a menu that is always a grid.
  final double? listWidth;

  /// Size of a grid symbol shown without a description; null keeps the menu
  /// text size.
  final double? symbolFontSize;

  final String? _flickLabel;

  /// The key's flick label: the first item, which a straight swipe up sends,
  /// unless the menu names its whole range instead.
  String get flickLabel => _flickLabel ?? items.first.symbol;
}

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

/// Where a key menu sits in overlay coordinates and which item each cell
/// holds.
class _KeyMenuLayout {
  const _KeyMenuLayout({
    required this.rect,
    required this.rows,
    required this.columns,
    required this.itemCount,
    this.isList = false,
    this.isMirrored = false,
  });

  final Rect rect;
  final int rows;
  final int columns;
  final int itemCount;

  /// One column of wide rows with each description beside its symbol.
  final bool isList;

  /// The grid grows leftward from the key, so the first item is bottom-right.
  final bool isMirrored;

  /// The item in a cell, counting rows from the top, or null for an empty
  /// cell of a partial row.
  ///
  /// Items fill rows upward from the key, each row starting on the key's
  /// side, so the first item is nearest the finger.
  int? itemAtCell(int row, int column) {
    final index =
        (rows - 1 - row) * columns +
        (isMirrored ? columns - 1 - column : column);
    return index < itemCount ? index : null;
  }

  int? itemAt(Offset localPosition) {
    if (!rect.contains(localPosition)) {
      return null;
    }
    final row = (localPosition.dy - rect.top) ~/ TerminalMenuStyles.itemHeight;
    final column = (localPosition.dx - rect.left) * columns ~/ rect.width;
    return itemAtCell(math.min(row, rows - 1), math.min(column, columns - 1));
  }
}

class _KeyMenuView extends StatelessWidget {
  const _KeyMenuView({
    required this.menu,
    required this.layout,
    required this.highlighted,
  });

  /// Menu cells keep a fixed 44 px height so layout and hit testing need no
  /// text metrics, so text scaling stops where the content still fits with a
  /// 1.2 line height. A list row holds one 14 px line (14 x 2.0 x 1.2 is about
  /// 34 px), and a lone grid symbol scales down to fit its cell. A grid cell
  /// with a description stacks two lines, and a described menu is only a grid
  /// when there is no vertical room for its list ((14 + 10) x 1.4 x 1.2 is
  /// about 40 px). Screen readers get the full names from the key's actions.
  static const _maxTextScale = 2.0;
  static const _stackedMaxTextScale = 1.4;

  final _KeyMenu menu;
  final _KeyMenuLayout layout;
  final int? highlighted;

  @override
  Widget build(BuildContext context) {
    final isStacked =
        !layout.isList && menu.items.any((item) => item.description != null);
    return TerminalMenuStyles.surface(
      context,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: isStacked ? _stackedMaxTextScale : _maxTextScale,
        child: Column(
          children: [
            for (var row = 0; row < layout.rows; row += 1)
              SizedBox(
                height: TerminalMenuStyles.itemHeight,
                child: Row(
                  children: [
                    for (var column = 0; column < layout.columns; column += 1)
                      Expanded(
                        child: switch (layout.itemAtCell(row, column)) {
                          final index? => _KeyMenuCell(
                            item: menu.items[index],
                            highlighted: index == highlighted,
                            isList: layout.isList,
                            symbolFontSize: menu.symbolFontSize,
                          ),
                          null => const SizedBox.shrink(),
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _KeyMenuCell extends StatelessWidget {
  const _KeyMenuCell({
    required this.item,
    required this.highlighted,
    required this.isList,
    this.symbolFontSize,
  });

  final _KeyMenuItem item;
  final bool highlighted;

  /// Puts the description beside the symbol rather than below it.
  final bool isList;
  final double? symbolFontSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = highlighted
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;
    // Symbols are what the terminal receives, so they are set in its voice;
    // descriptions explain them in the menu's.
    final textStyle = TerminalMenuStyles.itemTextStyle(
      context,
      emphasized: highlighted,
    ).copyWith(color: foregroundColor, height: 1.2);
    final symbolStyle = textStyle.copyWith(
      fontFamily: FluttyTheme.monoStyle.fontFamily,
    );
    final description = item.description;

    final Widget content;
    if (description == null) {
      content = Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            item.symbol,
            style: symbolStyle.copyWith(fontSize: symbolFontSize),
          ),
        ),
      );
    } else {
      final descriptionText = Text(
        description,
        textAlign: isList ? TextAlign.end : TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textStyle.copyWith(
          fontSize: isList ? 12 : 10,
          fontWeight: FontWeight.w400,
          // Muting on the highlight fill would drop below 4.5:1 contrast.
          color: highlighted ? foregroundColor : foregroundColor.withAlpha(170),
        ),
      );
      content = isList
          ? Row(
              children: [
                // The symbol leads because its meaning depends on the
                // program; the description is the usual shell meaning.
                Text(item.symbol, style: symbolStyle),
                const SizedBox(width: TerminalMenuStyles.iconLabelGap),
                Expanded(child: descriptionText),
              ],
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(item.symbol, style: symbolStyle),
                ),
                descriptionText,
              ],
            );
    }

    // A label, not a button: the menu exists only while a finger holds it,
    // and screen readers send items through the key's custom actions.
    return Semantics(
      selected: highlighted,
      label: description == null
          ? item.semanticsLabel
          : '${item.semanticsLabel}, $description',
      excludeSemantics: true,
      child: Container(
        color: highlighted ? colorScheme.primaryContainer : Colors.transparent,
        padding: EdgeInsets.symmetric(
          horizontal: isList ? TerminalMenuStyles.itemHorizontalPadding : 4,
        ),
        child: content,
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children, this.hasFlickLabels = false});

  static const height = 42.0;

  final List<Widget> children;

  /// Some keys in the row show a flick label, so every key leaves room for
  /// one and the labels stay aligned.
  final bool hasFlickLabels;

  @override
  Widget build(BuildContext context) => _FlickLabelRow(
    hasFlickLabels: hasFlickLabels,
    child: SizedBox(
      height: height,
      child: Row(
        children: children.map((c) {
          if (c is Expanded) return c;
          return Expanded(child: c);
        }).toList(),
      ),
    ),
  );
}

class _FlickLabelRow extends InheritedWidget {
  const _FlickLabelRow({required this.hasFlickLabels, required super.child});

  final bool hasFlickLabels;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FlickLabelRow>()
          ?.hasFlickLabels ??
      false;

  @override
  bool updateShouldNotify(_FlickLabelRow oldWidget) =>
      hasFlickLabels != oldWidget.hasFlickLabels;
}

/// A key's label, with the flick label above it on a key that has a menu.
///
/// As on an iPad flick key, the flick label names what a straight swipe up
/// sends, and it sits above the label because that is where the swipe goes.
/// It is muted so the key's own label still reads first.
class _KeyFace extends StatelessWidget {
  const _KeyFace({
    required this.label,
    required this.flickColor,
    this.flickLabel,
  });

  /// The band the flick label fits into, at the top of the key face. Its
  /// height is fixed, so large text scales the flick label down rather than
  /// pushing it into the label below.
  static const _flickTop = 4.0;
  static const _flickHeight = 10.0;

  /// How far a row with flick labels lowers every label, so labels stay
  /// aligned across keys with and without a menu.
  static const _labelTopInset = _flickTop + _flickHeight;

  final Widget label;
  final String? flickLabel;
  final Color flickColor;

  /// The secondary ink on a key, mixed from its fill and label colors the way
  /// the theme derives secondary text, so it holds 4.5:1 in every theme.
  static Color mutedInk(Color fill, Color label) =>
      Color.lerp(fill, label, 0.64)!;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(
          4,
          _FlickLabelRow.of(context) ? _labelTopInset : 0,
          4,
          0,
        ),
        child: Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: label),
        ),
      ),
      if (flickLabel case final flickLabel?)
        Positioned(
          top: _flickTop,
          height: _flickHeight,
          left: 2,
          right: 2,
          // Screen readers hear the menu from the key's hint and actions.
          child: ExcludeSemantics(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  flickLabel,
                  maxLines: 1,
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 10,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    color: flickColor,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Callbacks for a key whose menu is chosen by sliding and releasing.
class _KeyMenuGesture {
  const _KeyMenuGesture({
    required this.onOpen,
    required this.onMove,
    required this.onRelease,
    required this.onCancel,
  });

  /// Opens the menu with the finger at a global position.
  final ValueChanged<Offset> onOpen;

  /// Tracks the finger while the menu is open.
  final ValueChanged<Offset> onMove;

  /// Chooses from the menu where the finger lifted.
  final ValueChanged<Offset> onRelease;

  /// Closes the menu without choosing.
  final VoidCallback onCancel;
}

/// Opens a key's menu on press-and-hold, or as soon as the finger swipes up
/// past the touch slop, then tracks the finger until it lifts.
///
/// Both recognizers share the key's gesture arena with its tap: moving the
/// finger hands the pointer to the vertical drag, holding still hands it to
/// the long press, and a quick lift is still a tap.
class _KeyMenuGestureDetector extends StatefulWidget {
  const _KeyMenuGestureDetector({
    required this.gesture,
    required this.child,
    this.onOpened,
  });

  final _KeyMenuGesture gesture;
  final Widget child;

  /// Lets the key reset its own tap state once the gesture became a menu.
  final VoidCallback? onOpened;

  @override
  State<_KeyMenuGestureDetector> createState() =>
      _KeyMenuGestureDetectorState();
}

enum _KeyMenuOpenedBy { longPress, swipe }

class _KeyMenuGestureDetectorState extends State<_KeyMenuGestureDetector> {
  _KeyMenuOpenedBy? _openedBy;
  Offset? _swipeOrigin;
  Offset? _swipePosition;

  void _open(_KeyMenuOpenedBy source, Offset globalPosition) {
    _openedBy = source;
    widget.onOpened?.call();
    widget.gesture.onOpen(globalPosition);
  }

  void _release(_KeyMenuOpenedBy source, Offset globalPosition) {
    if (_openedBy != source) {
      return;
    }
    _openedBy = null;
    widget.gesture.onRelease(globalPosition);
  }

  /// Each recognizer also reports a cancel when it loses the arena to the
  /// other, so only the one that opened the menu may close it.
  void _cancel(_KeyMenuOpenedBy source) {
    if (_openedBy != source) {
      return;
    }
    _openedBy = null;
    widget.gesture.onCancel();
  }

  void _startSwipe(DragStartDetails details) {
    final origin = _swipeOrigin ?? details.globalPosition;
    final delta = details.globalPosition - origin;
    // Only a mostly upward swipe opens the menu.
    if (delta.dy >= 0 || -delta.dy < delta.dx.abs()) {
      return;
    }
    _swipePosition = details.globalPosition;
    _open(_KeyMenuOpenedBy.swipe, details.globalPosition);
  }

  void _updateSwipe(DragUpdateDetails details) {
    if (_openedBy != _KeyMenuOpenedBy.swipe) {
      return;
    }
    _swipePosition = details.globalPosition;
    widget.gesture.onMove(details.globalPosition);
  }

  @override
  Widget build(BuildContext context) => Listener(
    // The listener sees raw pointer events before the recognizers do. An
    // accepted drag reports a pointer cancel as a drag end, which would choose
    // the row under the finger, and a drag end reports the last move position
    // rather than where the finger lifted, so the lift point comes from here.
    onPointerUp: (event) {
      if (_openedBy == _KeyMenuOpenedBy.swipe) {
        _swipePosition = event.position;
      }
    },
    onPointerCancel: (_) {
      if (_openedBy case final source?) {
        _cancel(source);
      }
    },
    child: GestureDetector(
      onLongPressStart: (details) =>
          _open(_KeyMenuOpenedBy.longPress, details.globalPosition),
      onLongPressMoveUpdate: (details) {
        if (_openedBy == _KeyMenuOpenedBy.longPress) {
          widget.gesture.onMove(details.globalPosition);
        }
      },
      onLongPressEnd: (details) =>
          _release(_KeyMenuOpenedBy.longPress, details.globalPosition),
      onLongPressCancel: () => _cancel(_KeyMenuOpenedBy.longPress),
      onVerticalDragDown: (details) {
        _swipeOrigin = details.globalPosition;
        _swipePosition = null;
      },
      onVerticalDragStart: _startSwipe,
      onVerticalDragUpdate: _updateSwipe,
      onVerticalDragEnd: (_) {
        if (_swipePosition case final position?) {
          _release(_KeyMenuOpenedBy.swipe, position);
        }
      },
      onVerticalDragCancel: () => _cancel(_KeyMenuOpenedBy.swipe),
      child: widget.child,
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
    this.onLongPressRepeat,
    this.menuGesture,
    this.flickLabel,
    this.tooltip,
    this.semanticsHint,
    this.customSemanticsActions,
    super.key,
  }) : assert(
         menuGesture == null ||
             (onLongPressStart == null && onLongPressRepeat == null),
         'A menu key owns its long press.',
       );

  final String label;
  final IconData? icon;
  final bool mirrorIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressRepeat;

  /// Opens a menu on press-and-hold or an upward swipe.
  final _KeyMenuGesture? menuGesture;

  /// What a straight swipe up sends, shown above the label.
  final String? flickLabel;
  final String? tooltip;
  final String? semanticsHint;
  final Map<CustomSemanticsAction, VoidCallback>? customSemanticsActions;

  bool get hasLongPressHandler =>
      onLongPressStart != null || onLongPressRepeat != null;

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
    // A lone label is a literal character, set in the terminal's voice.
    return Text(
      widget.label,
      style: FluttyTheme.monoStyle.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: color,
      ),
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
          ? (_) {
              widget.onLongPressStart?.call();
              if (widget.onLongPressRepeat != null) {
                _startRepeat();
              }
            }
          : null,
      onLongPressEnd: widget.hasLongPressHandler ? (_) => _stopRepeat() : null,
      onLongPressCancel: widget.hasLongPressHandler ? _stopRepeat : null,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _isPressed
              ? colorScheme.primary.withAlpha(50)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          // A hairline keeps the key's edge visible where its fill matches
          // the toolbar (the light theme), so a flick label reads as part of
          // its key. It stays 1 px when pressed, so the face does not shift.
          border: Border.all(
            color: _isPressed
                ? colorScheme.primary
                : colorScheme.outlineVariant,
          ),
        ),
        child: _KeyFace(
          flickLabel: widget.flickLabel,
          // Muted against the resting fill, so a press does not wash it out.
          flickColor: _KeyFace.mutedInk(
            colorScheme.surfaceContainerHighest,
            foregroundColor,
          ),
          label: _buildContent(foregroundColor),
        ),
      ),
    );

    if (widget.menuGesture case final menuGesture?) {
      button = _KeyMenuGestureDetector(gesture: menuGesture, child: button);
    }

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      hint: widget.semanticsHint,
      customSemanticsActions: widget.customSemanticsActions,
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
    this.menuGesture,
    this.flickLabel,
    this.semanticsHint,
    this.customSemanticsActions,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool? state; // null = off, false = one-shot, true = locked
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final String? tooltip;

  /// Opens a menu on press-and-hold or an upward swipe.
  final _KeyMenuGesture? menuGesture;

  /// What a straight swipe up sends, shown above the label.
  final String? flickLabel;
  final String? semanticsHint;
  final Map<CustomSemanticsAction, VoidCallback>? customSemanticsActions;

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
          border: Border.all(
            color: widget.state == null ? colorScheme.outlineVariant : bgColor,
          ),
        ),
        child: _KeyFace(
          flickLabel: widget.flickLabel,
          // A muted label on the armed or locked fill would drop below 4.5:1
          // contrast, and the fill already sets the key apart.
          flickColor: widget.state == null
              ? _KeyFace.mutedInk(bgColor, textColor)
              : textColor,
          label: Row(
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
    );

    if (widget.menuGesture case final menuGesture?) {
      button = _KeyMenuGestureDetector(
        gesture: menuGesture,
        // A menu interrupts the tap sequence, so a tap right after choosing a
        // chord must not count as the second tap of a double-tap lock.
        onOpened: () => _lastTapTime = null,
        child: button,
      );
    }

    if (widget.tooltip case final tooltip?) {
      button = Tooltip(message: tooltip, child: button);
    }

    return Semantics(
      button: true,
      label: widget.tooltip ?? widget.label,
      hint: widget.semanticsHint,
      customSemanticsActions: widget.customSemanticsActions,
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
