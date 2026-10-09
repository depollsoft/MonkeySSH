/// Hardware-keyboard app shortcuts and the rule that splits chords between
/// the app and the terminal program.
///
/// ## Precedence rule
///
/// Only iPadOS and Android reserve chords. Desktop builds reserve none.
///
/// 1. A chord is an app shortcut when its key and modifiers exactly match an
///    entry in [appShortcutsFor]. On iPadOS the modifiers are ⌘ plus the
///    entry's own ⇧ or ⌃, and no ⌥. On Android every entry uses Ctrl+Shift
///    in place of ⌘, and no Alt or Meta.
/// 2. An app shortcut chord never reaches the terminal program, including its
///    key repeats and key release. That holds even when the action cannot run
///    on the current screen; the chord then does nothing.
/// 3. Every other key and chord goes to the terminal program exactly as
///    before: plain keys, Ctrl, Alt/Option, Ctrl+Alt, ⌘ chords that are not in
///    the table (⌘ with arrows, ⌘K, ⌘⇧T...), Ctrl+Shift chords that are not in
///    the table (Ctrl+Shift+C, Ctrl+Shift+Z, Ctrl+Shift+arrows...), and Meta
///    chords on Android. The terminal's own clipboard chords (⌘C, ⌘V and ⌘A
///    on iPadOS, Ctrl+V paste on Android) keep working as they did.
///
/// The cost to programs is small. In legacy key encoding a terminal sends
/// nothing for ⌘ chords or for Ctrl+Shift+letter, so only programs that turn
/// on the kitty keyboard protocol and bind those exact chords lose them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What an app keyboard shortcut does.
enum AppShortcutAction {
  /// Shows the list of keyboard shortcuts.
  showShortcuts,

  /// Switches to the next window in the window switcher.
  nextWindow,

  /// Switches to the previous window in the window switcher.
  previousWindow,

  /// Switches to the window in a numbered slot (see [AppShortcutIntent.slot]).
  goToWindow,

  /// Opens the new-window picker.
  newWindow,

  /// Closes the current window, honoring the confirm-before-close setting.
  closeWindow,

  /// Shows or hides the window switcher (the sidebar on wide layouts).
  toggleWindowList,

  /// Moves keyboard focus to the agent composer, or to the terminal.
  focusComposer,

  /// Opens the SFTP file browser for the current connection.
  openFiles,

  /// Finds text in the terminal scrollback (#937).
  findInScrollback,

  /// Opens the working tree Changes view (#925).
  openChanges,
}

/// Sections used to group shortcuts in the shortcuts list.
enum AppShortcutGroup {
  /// Window switching and management.
  windows('windows'),

  /// Actions on the current session.
  session('session'),

  /// Help.
  help('help');

  const AppShortcutGroup(this.title);

  /// Lowercase mono section title.
  final String title;
}

/// Keys used by app shortcuts.
///
/// A key matches by its logical key first, so letters follow the active
/// keyboard layout. When the logical key is not an ASCII letter or digit
/// (for example the AZERTY digit row, or a Cyrillic layout), it falls back to
/// the key's physical position.
enum AppShortcutKey {
  /// The slash key; ⇧/ produces a question mark on US layouts.
  slash('/', 'Slash', [
    LogicalKeyboardKey.slash,
    LogicalKeyboardKey.question,
  ], PhysicalKeyboardKey.slash),

  /// The left bracket key; ⇧[ produces a left brace on US layouts.
  bracketLeft('[', 'Left bracket', [
    LogicalKeyboardKey.bracketLeft,
    LogicalKeyboardKey.braceLeft,
  ], PhysicalKeyboardKey.bracketLeft),

  /// The right bracket key; ⇧] produces a right brace on US layouts.
  bracketRight(']', 'Right bracket', [
    LogicalKeyboardKey.bracketRight,
    LogicalKeyboardKey.braceRight,
  ], PhysicalKeyboardKey.bracketRight),

  /// Digit 1.
  digit1('1', '1', [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.exclamation,
  ], PhysicalKeyboardKey.digit1),

  /// Digit 2.
  digit2('2', '2', [
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.at,
  ], PhysicalKeyboardKey.digit2),

  /// Digit 3.
  digit3('3', '3', [
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.numberSign,
  ], PhysicalKeyboardKey.digit3),

  /// Digit 4.
  digit4('4', '4', [
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.dollar,
  ], PhysicalKeyboardKey.digit4),

  /// Digit 5.
  digit5('5', '5', [
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.percent,
  ], PhysicalKeyboardKey.digit5),

  /// Digit 6.
  digit6('6', '6', [
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.caret,
  ], PhysicalKeyboardKey.digit6),

  /// Digit 7.
  digit7('7', '7', [
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.ampersand,
  ], PhysicalKeyboardKey.digit7),

  /// Digit 8.
  digit8('8', '8', [
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.asterisk,
  ], PhysicalKeyboardKey.digit8),

  /// Digit 9.
  digit9('9', '9', [
    LogicalKeyboardKey.digit9,
    LogicalKeyboardKey.parenthesisLeft,
  ], PhysicalKeyboardKey.digit9),

  /// Letter D.
  keyD('D', 'D', [LogicalKeyboardKey.keyD], PhysicalKeyboardKey.keyD),

  /// Letter F.
  keyF('F', 'F', [LogicalKeyboardKey.keyF], PhysicalKeyboardKey.keyF),

  /// Letter L.
  keyL('L', 'L', [LogicalKeyboardKey.keyL], PhysicalKeyboardKey.keyL),

  /// Letter O.
  keyO('O', 'O', [LogicalKeyboardKey.keyO], PhysicalKeyboardKey.keyO),

  /// Letter S.
  keyS('S', 'S', [LogicalKeyboardKey.keyS], PhysicalKeyboardKey.keyS),

  /// Letter T.
  keyT('T', 'T', [LogicalKeyboardKey.keyT], PhysicalKeyboardKey.keyT),

  /// Letter W.
  keyW('W', 'W', [LogicalKeyboardKey.keyW], PhysicalKeyboardKey.keyW);

  const AppShortcutKey(
    this.glyph,
    this.spokenName,
    this.logical,
    this.physical,
  );

  /// Character shown on the keycap.
  final String glyph;

  /// Name read by screen readers.
  final String spokenName;

  /// Logical keys that count as this key, unshifted and shifted.
  final List<LogicalKeyboardKey> logical;

  /// Physical key used when the layout produces no ASCII letter or digit.
  final PhysicalKeyboardKey physical;

  /// Whether [event] was produced by this key.
  bool matches(KeyEvent event) {
    if (logical.contains(event.logicalKey)) {
      return true;
    }
    return event.physicalKey == physical &&
        !_isAsciiLetterOrDigit(event.logicalKey);
  }

  static bool _isAsciiLetterOrDigit(LogicalKeyboardKey key) {
    final id = key.keyId;
    return (id >= 0x30 && id <= 0x39) || (id >= 0x61 && id <= 0x7a);
  }
}

/// How a platform spells app shortcut chords.
enum AppShortcutModifierScheme {
  /// iPadOS: ⌘ plus the entry's own ⇧ and ⌃.
  command,

  /// Android: Ctrl+Shift in place of ⌘.
  controlShift,
}

/// Returns the chord scheme for [platform], or null when the platform
/// reserves no app shortcuts.
AppShortcutModifierScheme? appShortcutSchemeFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS => AppShortcutModifierScheme.command,
      TargetPlatform.android => AppShortcutModifierScheme.controlShift,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => null,
    };

/// One app keyboard shortcut.
@immutable
class AppShortcut {
  /// Creates a shortcut definition.
  const AppShortcut({
    required this.action,
    required this.group,
    required this.label,
    required this.key,
    this.shift = false,
    this.control = false,
    this.slot,
    this.repeats = false,
    this.available = true,
  });

  /// What the shortcut does.
  final AppShortcutAction action;

  /// Section in the shortcuts list.
  final AppShortcutGroup group;

  /// Sentence-case label shown in the shortcuts list.
  final String label;

  /// Non-modifier key of the chord.
  final AppShortcutKey key;

  /// Whether the iPadOS chord includes ⇧. Android chords always do.
  final bool shift;

  /// Whether the iPadOS chord includes ⌃. Android chords always do.
  final bool control;

  /// Window slot for [AppShortcutAction.goToWindow], from 1 to 9.
  final int? slot;

  /// Whether holding the chord repeats the action.
  final bool repeats;

  /// False for a hook whose feature is not built yet. Unavailable shortcuts
  /// are not reserved and not listed, so their chords still reach the
  /// terminal until the feature lands.
  final bool available;

  /// Whether [event]'s key and the pressed modifiers in [keyboard] form this
  /// chord under [scheme]. The event type is not checked.
  bool matches(
    KeyEvent event,
    HardwareKeyboard keyboard,
    AppShortcutModifierScheme scheme,
  ) {
    if (!key.matches(event) || keyboard.isAltPressed) {
      return false;
    }
    final meta = keyboard.isMetaPressed;
    final ctrl = keyboard.isControlPressed;
    final shiftPressed = keyboard.isShiftPressed;
    return switch (scheme) {
      AppShortcutModifierScheme.command =>
        meta && ctrl == control && shiftPressed == shift,
      AppShortcutModifierScheme.controlShift => !meta && ctrl && shiftPressed,
    };
  }

  /// Intent dispatched when the chord is pressed.
  AppShortcutIntent get intent => AppShortcutIntent(action, slot: slot);
}

/// Every app shortcut, including hooks for features that are not built yet.
const List<AppShortcut> allAppShortcuts = [
  AppShortcut(
    action: AppShortcutAction.nextWindow,
    group: AppShortcutGroup.windows,
    label: 'Next window',
    key: AppShortcutKey.bracketRight,
    shift: true,
    repeats: true,
  ),
  AppShortcut(
    action: AppShortcutAction.previousWindow,
    group: AppShortcutGroup.windows,
    label: 'Previous window',
    key: AppShortcutKey.bracketLeft,
    shift: true,
    repeats: true,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 1',
    key: AppShortcutKey.digit1,
    slot: 1,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 2',
    key: AppShortcutKey.digit2,
    slot: 2,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 3',
    key: AppShortcutKey.digit3,
    slot: 3,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 4',
    key: AppShortcutKey.digit4,
    slot: 4,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 5',
    key: AppShortcutKey.digit5,
    slot: 5,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 6',
    key: AppShortcutKey.digit6,
    slot: 6,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 7',
    key: AppShortcutKey.digit7,
    slot: 7,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to window 8',
    key: AppShortcutKey.digit8,
    slot: 8,
  ),
  AppShortcut(
    action: AppShortcutAction.goToWindow,
    group: AppShortcutGroup.windows,
    label: 'Go to last window',
    key: AppShortcutKey.digit9,
    slot: 9,
  ),
  AppShortcut(
    action: AppShortcutAction.newWindow,
    group: AppShortcutGroup.windows,
    label: 'New window',
    key: AppShortcutKey.keyT,
  ),
  AppShortcut(
    action: AppShortcutAction.closeWindow,
    group: AppShortcutGroup.windows,
    label: 'Close window',
    key: AppShortcutKey.keyW,
  ),
  AppShortcut(
    action: AppShortcutAction.toggleWindowList,
    group: AppShortcutGroup.windows,
    label: 'Show or hide windows',
    key: AppShortcutKey.keyS,
    control: true,
  ),
  AppShortcut(
    action: AppShortcutAction.focusComposer,
    group: AppShortcutGroup.session,
    label: 'Focus composer or terminal',
    key: AppShortcutKey.keyL,
  ),
  AppShortcut(
    action: AppShortcutAction.openFiles,
    group: AppShortcutGroup.session,
    label: 'Browse files (SFTP)',
    key: AppShortcutKey.keyO,
  ),
  // Hook for #937. Flip `available` when find in scrollback lands.
  AppShortcut(
    action: AppShortcutAction.findInScrollback,
    group: AppShortcutGroup.session,
    label: 'Find in scrollback',
    key: AppShortcutKey.keyF,
    available: false,
  ),
  // Hook for #925. Flip `available` when the Changes view lands.
  AppShortcut(
    action: AppShortcutAction.openChanges,
    group: AppShortcutGroup.session,
    label: 'Working tree changes',
    key: AppShortcutKey.keyD,
    shift: true,
    available: false,
  ),
  AppShortcut(
    action: AppShortcutAction.showShortcuts,
    group: AppShortcutGroup.help,
    label: 'Keyboard shortcuts',
    key: AppShortcutKey.slash,
  ),
];

/// Shortcuts reserved on [platform]: the available entries of
/// [allAppShortcuts], or none where the platform has no scheme.
List<AppShortcut> appShortcutsFor(TargetPlatform platform) {
  if (appShortcutSchemeFor(platform) == null) {
    return const [];
  }
  return [
    for (final shortcut in allAppShortcuts)
      if (shortcut.available) shortcut,
  ];
}

/// Returns the app shortcut that [event] forms with the currently pressed
/// modifiers, or null when the chord belongs to the terminal.
AppShortcut? matchAppShortcut(
  KeyEvent event, {
  HardwareKeyboard? keyboard,
  TargetPlatform? platform,
}) {
  final effectivePlatform = platform ?? defaultTargetPlatform;
  final scheme = appShortcutSchemeFor(effectivePlatform);
  if (scheme == null) {
    return null;
  }
  final state = keyboard ?? HardwareKeyboard.instance;
  for (final shortcut in appShortcutsFor(effectivePlatform)) {
    if (shortcut.matches(event, state, scheme)) {
      return shortcut;
    }
  }
  return null;
}

/// Tracks which keys a terminal input path must withhold from the program.
///
/// A reserved chord's key down, its repeats, and its release are all
/// withheld, so a kitty-protocol program never sees half of a chord even when
/// the modifiers are released before the key.
class AppShortcutKeyFilter {
  final Set<PhysicalKeyboardKey> _withheld = <PhysicalKeyboardKey>{};

  /// Whether [event] belongs to an app shortcut and must not be sent to the
  /// terminal.
  bool withhold(
    KeyEvent event, {
    HardwareKeyboard? keyboard,
    TargetPlatform? platform,
  }) {
    if (event is KeyUpEvent) {
      return _withheld.remove(event.physicalKey);
    }
    final reserved =
        matchAppShortcut(event, keyboard: keyboard, platform: platform) != null;
    if (reserved) {
      _withheld.add(event.physicalKey);
      return true;
    }
    if (event is KeyRepeatEvent) {
      return _withheld.contains(event.physicalKey);
    }
    _withheld.remove(event.physicalKey);
    return false;
  }

  /// Forgets withheld keys, for example after focus moves away.
  void reset() => _withheld.clear();
}

/// Intent dispatched by an app shortcut chord.
@immutable
class AppShortcutIntent extends Intent {
  /// Creates an intent for [action].
  const AppShortcutIntent(this.action, {this.slot});

  /// What to do.
  final AppShortcutAction action;

  /// Window slot for [AppShortcutAction.goToWindow].
  final int? slot;

  @override
  bool operator ==(Object other) =>
      other is AppShortcutIntent &&
      other.action == action &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(action, slot);
}

/// Activator for one [AppShortcut]. Fires on key down, and on key repeat
/// only for shortcuts that repeat.
class AppShortcutActivator extends ShortcutActivator {
  /// Creates an activator for [shortcut] under [scheme].
  const AppShortcutActivator(this.shortcut, this.scheme);

  /// Shortcut to match.
  final AppShortcut shortcut;

  /// Chord scheme of the current platform.
  final AppShortcutModifierScheme scheme;

  // Null triggers make the shortcut manager test every event, which keeps
  // shifted and physical-key fallbacks working.
  @override
  Iterable<LogicalKeyboardKey>? get triggers => null;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is KeyUpEvent) {
      return false;
    }
    if (event is KeyRepeatEvent && !shortcut.repeats) {
      return false;
    }
    return shortcut.matches(event, state, scheme);
  }

  @override
  String debugDescribeKeys() => describeAppShortcutChord(
    shortcut,
    scheme == AppShortcutModifierScheme.command
        ? TargetPlatform.iOS
        : TargetPlatform.android,
  );
}

/// Shortcut bindings for [platform], for a [Shortcuts] widget.
Map<ShortcutActivator, Intent> appShortcutBindings(TargetPlatform platform) {
  final scheme = appShortcutSchemeFor(platform);
  if (scheme == null) {
    return const {};
  }
  return {
    for (final shortcut in appShortcutsFor(platform))
      AppShortcutActivator(shortcut, scheme): shortcut.intent,
  };
}

/// Visible chord text, such as `⌃⌘S` on iPadOS or `Ctrl+Shift+S` on Android.
String describeAppShortcutChord(AppShortcut shortcut, TargetPlatform platform) {
  switch (appShortcutSchemeFor(platform)) {
    case AppShortcutModifierScheme.command:
      // Apple's modifier order: Control, Option, Shift, Command.
      return '${shortcut.control ? '⌃' : ''}'
          '${shortcut.shift ? '⇧' : ''}'
          '⌘${shortcut.key.glyph}';
    case AppShortcutModifierScheme.controlShift:
      return 'Ctrl+Shift+${shortcut.key.glyph}';
    case null:
      return '';
  }
}

/// Chord text for screen readers, such as `Control Command S`.
String describeAppShortcutChordForSemantics(
  AppShortcut shortcut,
  TargetPlatform platform,
) {
  switch (appShortcutSchemeFor(platform)) {
    case AppShortcutModifierScheme.command:
      return [
        if (shortcut.control) 'Control',
        if (shortcut.shift) 'Shift',
        'Command',
        shortcut.key.spokenName,
      ].join(' ');
    case AppShortcutModifierScheme.controlShift:
      return 'Control Shift ${shortcut.key.spokenName}';
    case null:
      return '';
  }
}

/// Index into a window list of [count] entries for numbered [slot]: slots 1
/// to 8 are positions, slot 9 is the last window. Null when out of range.
int? resolveAppShortcutWindowSlot(int slot, int count) {
  if (count <= 0 || slot < 1 || slot > 9) {
    return null;
  }
  if (slot == 9) {
    return count - 1;
  }
  return slot <= count ? slot - 1 : null;
}

/// Index [delta] steps from [activeIndex] in a list of [count] entries,
/// wrapping at both ends. With no active entry, forward starts at the first
/// entry and backward at the last.
int? resolveAppShortcutAdjacentWindow({
  required int? activeIndex,
  required int delta,
  required int count,
}) {
  if (count <= 0) {
    return null;
  }
  if (activeIndex == null || activeIndex < 0 || activeIndex >= count) {
    return delta >= 0 ? 0 : count - 1;
  }
  return (activeIndex + delta) % count;
}

final Object _hardwareKeyboardFlowZoneKey = Object();

/// Runs [body] on behalf of a hardware key press: an app shortcut, or Return
/// on a keyboard-focused row. Overlays opened by [body], even after awaits,
/// then take keyboard focus. See [hardwareKeyboardOverlaysTakeFocus].
R runHardwareKeyboardFlow<R>(R Function() body) =>
    runZoned(body, zoneValues: {_hardwareKeyboardFlowZoneKey: true});

/// Whether the current code runs on behalf of a hardware key press.
bool get isHardwareKeyboardFlow =>
    Zone.current[_hardwareKeyboardFlowZoneKey] == true;

/// Whether an overlay opened now should take keyboard focus: a hardware key
/// press opened it and no touch has happened since. Touch-driven overlays on
/// mobile leave focus on the terminal so the soft keyboard stays up.
bool get hardwareKeyboardOverlaysTakeFocus =>
    isHardwareKeyboardFlow &&
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
