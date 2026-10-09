// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcuts.dart';

class _Keyboard extends HardwareKeyboard {
  _Keyboard({
    this.meta = false,
    this.control = false,
    this.shift = false,
    this.alt = false,
  });

  final bool meta;
  final bool control;
  final bool shift;
  final bool alt;

  @override
  bool get isMetaPressed => meta;

  @override
  bool get isControlPressed => control;

  @override
  bool get isShiftPressed => shift;

  @override
  bool get isAltPressed => alt;
}

KeyDownEvent _down(
  LogicalKeyboardKey logical, {
  PhysicalKeyboardKey? physical,
}) => KeyDownEvent(
  physicalKey: physical ?? _physicalFor(logical),
  logicalKey: logical,
  timeStamp: Duration.zero,
);

PhysicalKeyboardKey _physicalFor(LogicalKeyboardKey logical) {
  for (final key in AppShortcutKey.values) {
    if (key.unshifted == logical || key.shifted == logical) {
      return key.physical;
    }
  }
  return {
        LogicalKeyboardKey.keyA: PhysicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyC: PhysicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyK: PhysicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyV: PhysicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyZ: PhysicalKeyboardKey.keyZ,
        LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
      }[logical] ??
      PhysicalKeyboardKey.usbReserved;
}

AppShortcut? _match(
  LogicalKeyboardKey logical, {
  required TargetPlatform platform,
  PhysicalKeyboardKey? physical,
  bool meta = false,
  bool control = false,
  bool shift = false,
  bool alt = false,
}) => matchAppShortcut(
  _down(logical, physical: physical),
  keyboard: _Keyboard(meta: meta, control: control, shift: shift, alt: alt),
  platform: platform,
);

void main() {
  const ios = TargetPlatform.iOS;
  const android = TargetPlatform.android;

  group('iPadOS chords', () {
    test('reserve the listed command chords', () {
      expect(
        _match(LogicalKeyboardKey.keyT, platform: ios, meta: true)?.action,
        AppShortcutAction.newWindow,
      );
      expect(
        _match(LogicalKeyboardKey.keyW, platform: ios, meta: true)?.action,
        AppShortcutAction.closeWindow,
      );
      expect(
        _match(
          LogicalKeyboardKey.keyS,
          platform: ios,
          meta: true,
          control: true,
        )?.action,
        AppShortcutAction.toggleWindowList,
      );
      expect(
        _match(LogicalKeyboardKey.keyL, platform: ios, meta: true)?.action,
        AppShortcutAction.focusComposer,
      );
      expect(
        _match(LogicalKeyboardKey.keyO, platform: ios, meta: true)?.action,
        AppShortcutAction.openFiles,
      );
      expect(
        _match(LogicalKeyboardKey.slash, platform: ios, meta: true)?.action,
        AppShortcutAction.showShortcuts,
      );
    });

    test('match shifted brackets by their shifted logical key', () {
      // iOS reports ⌘⇧] as a right brace on US layouts.
      expect(
        _match(
          LogicalKeyboardKey.braceRight,
          platform: ios,
          meta: true,
          shift: true,
        )?.action,
        AppShortcutAction.nextWindow,
      );
      expect(
        _match(
          LogicalKeyboardKey.bracketLeft,
          platform: ios,
          meta: true,
          shift: true,
        )?.action,
        AppShortcutAction.previousWindow,
      );
    });

    test('map digits to window numbers, including layouts without digits', () {
      for (var number = 0; number <= 9; number++) {
        final key = AppShortcutKey.values.firstWhere(
          (key) => key.name == 'digit$number',
        );
        final shortcut = _match(key.unshifted, platform: ios, meta: true);
        expect(shortcut?.action, AppShortcutAction.goToWindow);
        expect(shortcut?.windowNumber, number);
      }
      // AZERTY: the 1 key types "&" and the 0 key types "à" without Shift.
      final azerty = _match(
        LogicalKeyboardKey.ampersand,
        physical: PhysicalKeyboardKey.digit1,
        platform: ios,
        meta: true,
      );
      expect(azerty?.windowNumber, 1);
      final azertyZero = _match(
        const LogicalKeyboardKey(0x00e0),
        physical: PhysicalKeyboardKey.digit0,
        platform: ios,
        meta: true,
      );
      expect(azertyZero?.windowNumber, 0);
    });

    test('follow the layout for letters', () {
      // AZERTY: the physical W key types "z", which is not a shortcut.
      expect(
        _match(
          LogicalKeyboardKey.keyZ,
          physical: PhysicalKeyboardKey.keyW,
          platform: ios,
          meta: true,
        ),
        isNull,
      );
      // Cyrillic: the physical T key types "е"; fall back to position.
      expect(
        _match(
          const LogicalKeyboardKey(0x0435),
          physical: PhysicalKeyboardKey.keyT,
          platform: ios,
          meta: true,
        )?.action,
        AppShortcutAction.newWindow,
      );
    });

    test('leave every other chord to the terminal', () {
      final passthrough = <({LogicalKeyboardKey key, bool shift, bool ctrl})>[
        (key: LogicalKeyboardKey.keyT, shift: true, ctrl: false),
        (key: LogicalKeyboardKey.keyS, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.keyK, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.keyC, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.keyV, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.keyA, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.arrowUp, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.bracketRight, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.digit1, shift: true, ctrl: false),
        // Hooks for features that are not built yet stay with the terminal.
        (key: LogicalKeyboardKey.keyF, shift: false, ctrl: false),
        (key: LogicalKeyboardKey.keyD, shift: true, ctrl: false),
      ];
      for (final chord in passthrough) {
        expect(
          _match(
            chord.key,
            platform: ios,
            meta: true,
            shift: chord.shift,
            control: chord.ctrl,
          ),
          isNull,
          reason: '⌘ ${chord.key.debugName} shift=${chord.shift}',
        );
      }
      // Without ⌘, or with ⌥, nothing is reserved.
      expect(
        _match(LogicalKeyboardKey.keyT, platform: ios, control: true),
        isNull,
      );
      expect(
        _match(LogicalKeyboardKey.keyT, platform: ios, meta: true, alt: true),
        isNull,
      );
      expect(
        _match(
          LogicalKeyboardKey.keyT,
          platform: ios,
          control: true,
          shift: true,
        ),
        isNull,
      );
    });
  });

  group('layout handling (review round 1)', () {
    test('shifted digit aliases need Shift', () {
      // AZERTY types "!" on the US slash key without Shift: not ⌘1.
      expect(
        _match(
          LogicalKeyboardKey.exclamation,
          physical: PhysicalKeyboardKey.slash,
          platform: ios,
          meta: true,
        )?.action,
        isNot(AppShortcutAction.goToWindow),
      );
      // UK and German ISO keyboards type "#" without Shift.
      expect(
        _match(
          LogicalKeyboardKey.numberSign,
          physical: PhysicalKeyboardKey.backslash,
          platform: ios,
          meta: true,
        ),
        isNull,
      );
    });

    test('logical matches win over physical fallbacks', () {
      // Dvorak puts "/" and "?" on the US left-bracket key.
      expect(
        _match(
          LogicalKeyboardKey.question,
          physical: PhysicalKeyboardKey.bracketLeft,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.showShortcuts,
      );
      expect(
        _match(
          LogicalKeyboardKey.slash,
          physical: PhysicalKeyboardKey.bracketLeft,
          platform: ios,
          meta: true,
        )?.action,
        AppShortcutAction.showShortcuts,
      );
    });

    test('brackets and slash keep a key on European layouts', () {
      // German, Italian and Spanish type "+" and "*" on the US "]" key.
      expect(
        _match(
          LogicalKeyboardKey.asterisk,
          physical: PhysicalKeyboardKey.bracketRight,
          platform: ios,
          meta: true,
          shift: true,
        )?.action,
        AppShortcutAction.nextWindow,
      );
      expect(
        _match(
          LogicalKeyboardKey.add,
          physical: PhysicalKeyboardKey.bracketRight,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.nextWindow,
      );
      // German types "ü" on the US "[" key.
      expect(
        _match(
          const LogicalKeyboardKey(0x00fc),
          physical: PhysicalKeyboardKey.bracketLeft,
          platform: ios,
          meta: true,
          shift: true,
        )?.action,
        AppShortcutAction.previousWindow,
      );
      // German types "-" and AZERTY types "!" on the US "/" key.
      expect(
        _match(
          LogicalKeyboardKey.minus,
          physical: PhysicalKeyboardKey.slash,
          platform: ios,
          meta: true,
        )?.action,
        AppShortcutAction.showShortcuts,
      );
      expect(
        _match(
          LogicalKeyboardKey.exclamation,
          physical: PhysicalKeyboardKey.slash,
          platform: ios,
          meta: true,
        )?.action,
        AppShortcutAction.showShortcuts,
      );
    });

    test('letters fall back to position only on non-Latin layouts', () {
      // Dvorak types "," on the US W key: ⌘, is not ⌘W.
      expect(
        _match(
          LogicalKeyboardKey.comma,
          physical: PhysicalKeyboardKey.keyW,
          platform: ios,
          meta: true,
        ),
        isNull,
      );
    });
  });

  group('Android chords', () {
    test('use Ctrl+Shift in place of ⌘', () {
      expect(
        _match(
          LogicalKeyboardKey.keyT,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.newWindow,
      );
      expect(
        _match(
          LogicalKeyboardKey.keyS,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.toggleWindowList,
      );
      expect(
        _match(
          LogicalKeyboardKey.braceRight,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.nextWindow,
      );
      expect(
        _match(
          LogicalKeyboardKey.question,
          platform: android,
          control: true,
          shift: true,
        )?.action,
        AppShortcutAction.showShortcuts,
      );
      final number = _match(
        LogicalKeyboardKey.exclamation,
        physical: PhysicalKeyboardKey.digit1,
        platform: android,
        control: true,
        shift: true,
      );
      expect(number?.windowNumber, 1);
    });

    test('leave Ctrl, Meta and other Ctrl+Shift chords to the terminal', () {
      expect(
        _match(LogicalKeyboardKey.keyT, platform: android, control: true),
        isNull,
      );
      expect(
        _match(LogicalKeyboardKey.keyT, platform: android, meta: true),
        isNull,
      );
      expect(
        _match(
          LogicalKeyboardKey.keyT,
          platform: android,
          control: true,
          shift: true,
          alt: true,
        ),
        isNull,
      );
      for (final key in [
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.keyF,
      ]) {
        expect(
          _match(key, platform: android, control: true, shift: true),
          isNull,
          reason: key.debugName,
        );
      }
    });

    test('never map two shortcuts to one chord', () {
      final keys = appShortcutsFor(android).map((shortcut) => shortcut.key);
      expect(keys.toSet().length, keys.length);
      final iosChords = appShortcutsFor(ios)
          .map((shortcut) => (shortcut.key, shortcut.shift, shortcut.control));
      expect(iosChords.toSet().length, iosChords.length);
    });
  });

  test('desktop platforms reserve nothing', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      expect(appShortcutsFor(platform), isEmpty);
      expect(appShortcutBindings(platform), isEmpty);
      expect(
        _match(LogicalKeyboardKey.keyT, platform: platform, meta: true),
        isNull,
      );
    }
  });

  test('every action has a chord; unbuilt features are hooks only', () {
    final available = appShortcutsFor(ios).map((s) => s.action).toSet();
    expect(
      available,
      AppShortcutAction.values.toSet()..removeAll({
        AppShortcutAction.findInScrollback,
        AppShortcutAction.openChanges,
      }),
    );
    final hooks = allAppShortcuts.where((s) => !s.available);
    expect(hooks.map((s) => s.action).toSet(), {
      AppShortcutAction.findInScrollback,
      AppShortcutAction.openChanges,
    });
  });

  test('describes chords for each platform', () {
    AppShortcut find(AppShortcutAction action) =>
        allAppShortcuts.firstWhere((shortcut) => shortcut.action == action);
    expect(
      describeAppShortcutChord(find(AppShortcutAction.toggleWindowList), ios),
      '⌃⌘S',
    );
    expect(
      describeAppShortcutChord(find(AppShortcutAction.nextWindow), ios),
      '⇧⌘]',
    );
    expect(
      describeAppShortcutChord(find(AppShortcutAction.newWindow), android),
      'Ctrl+Shift+T',
    );
    expect(
      describeAppShortcutChordForSemantics(
        find(AppShortcutAction.nextWindow),
        ios,
      ),
      'Shift Command Right bracket',
    );
  });

  group('AppShortcutKeyFilter', () {
    test('withholds a reserved chord through repeat and release', () {
      final filter = AppShortcutKeyFilter();
      final held = _Keyboard(meta: true);
      const physical = PhysicalKeyboardKey.keyW;
      expect(
        filter.withhold(
          _down(LogicalKeyboardKey.keyW),
          keyboard: held,
          platform: ios,
        ),
        isTrue,
      );
      expect(
        filter.withhold(
          const KeyRepeatEvent(
            physicalKey: physical,
            logicalKey: LogicalKeyboardKey.keyW,
            timeStamp: Duration.zero,
          ),
          keyboard: held,
          platform: ios,
        ),
        isTrue,
      );
      // ⌘ released before W: the release still belongs to the chord.
      expect(
        filter.withhold(
          const KeyUpEvent(
            physicalKey: physical,
            logicalKey: LogicalKeyboardKey.keyW,
            timeStamp: Duration.zero,
          ),
          keyboard: _Keyboard(),
          platform: ios,
        ),
        isTrue,
      );
      // The next plain W goes to the terminal.
      expect(
        filter.withhold(
          _down(LogicalKeyboardKey.keyW),
          keyboard: _Keyboard(),
          platform: ios,
        ),
        isFalse,
      );
      expect(
        filter.withhold(
          const KeyUpEvent(
            physicalKey: physical,
            logicalKey: LogicalKeyboardKey.keyW,
            timeStamp: Duration.zero,
          ),
          keyboard: _Keyboard(),
          platform: ios,
        ),
        isFalse,
      );
    });
  });

  test('activators fire on key down, and on repeat only when repeating', () {
    final next = allAppShortcuts.firstWhere(
      (s) => s.action == AppShortcutAction.nextWindow,
    );
    final close = allAppShortcuts.firstWhere(
      (s) => s.action == AppShortcutAction.closeWindow,
    );
    final nextActivator = AppShortcutActivator(next, ios);
    final closeActivator = AppShortcutActivator(close, ios);
    final shifted = _Keyboard(meta: true, shift: true);
    final plain = _Keyboard(meta: true);
    const repeatNext = KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.bracketRight,
      logicalKey: LogicalKeyboardKey.braceRight,
      timeStamp: Duration.zero,
    );
    const repeatClose = KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyW,
      logicalKey: LogicalKeyboardKey.keyW,
      timeStamp: Duration.zero,
    );
    expect(
      nextActivator.accepts(_down(LogicalKeyboardKey.braceRight), shifted),
      isTrue,
    );
    expect(nextActivator.accepts(repeatNext, shifted), isTrue);
    expect(
      closeActivator.accepts(_down(LogicalKeyboardKey.keyW), plain),
      isTrue,
    );
    expect(closeActivator.accepts(repeatClose, plain), isFalse);
    expect(
      closeActivator.accepts(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyW,
          logicalKey: LogicalKeyboardKey.keyW,
          timeStamp: Duration.zero,
        ),
        plain,
      ),
      isFalse,
    );
  });

  test('resolves window numbers and wraps adjacent windows', () {
    expect(resolveAppShortcutWindowNumber(1, [0, 1, 2]), 1);
    expect(resolveAppShortcutWindowNumber(0, [0, 1, 2]), 0);
    // Gaps after a closed window: numbers follow the badges.
    expect(resolveAppShortcutWindowNumber(3, [1, 3, 4]), 1);
    expect(resolveAppShortcutWindowNumber(2, [1, 3, 4]), isNull);
    expect(resolveAppShortcutWindowNumber(1, []), isNull);

    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: 0, delta: 1, count: 3),
      1,
    );
    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: 2, delta: 1, count: 3),
      0,
    );
    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: 0, delta: -1, count: 3),
      2,
    );
    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: null, delta: 1, count: 3),
      0,
    );
    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: null, delta: -1, count: 3),
      2,
    );
    expect(
      resolveAppShortcutAdjacentWindow(activeIndex: 0, delta: 1, count: 0),
      isNull,
    );
  });

  testWidgets(
    'overlays take focus only inside a keyboard flow in keyboard mode',
    (tester) async {
      expect(isHardwareKeyboardFlow, isFalse);
      expect(hardwareKeyboardOverlaysTakeFocus, isFalse);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      expect(hardwareKeyboardOverlaysTakeFocus, isFalse);
      runHardwareKeyboardFlow(() {
        expect(isHardwareKeyboardFlow, isTrue);
        expect(hardwareKeyboardOverlaysTakeFocus, isTrue);
      });
      await runHardwareKeyboardFlow(() async {
        await Future<void>.microtask(() {});
        expect(hardwareKeyboardOverlaysTakeFocus, isTrue);
      });

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      runHardwareKeyboardFlow(() {
        expect(hardwareKeyboardOverlaysTakeFocus, isFalse);
      });
    },
  );
}
