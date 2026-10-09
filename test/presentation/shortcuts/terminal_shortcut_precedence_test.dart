// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcut_scope.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcuts.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

/// Kitty keyboard protocol: disambiguate escape codes and report releases,
/// so any chord the terminal forwards shows up in its output.
const _kittyDisambiguateAndReleases = '\x1b[>3u';

typedef _Harness = ({
  List<String> output,
  List<AppShortcutIntent> appCalls,
  FocusNode focusNode,
  Terminal terminal,
});

Future<_Harness> _pump(WidgetTester tester, {bool kitty = false}) async {
  final output = <String>[];
  final appCalls = <AppShortcutIntent>[];
  final terminal = Terminal(onOutput: output.add);
  if (kitty) {
    terminal.write(_kittyDisambiguateAndReleases);
  }
  final focusNode = FocusNode();
  addTearDown(focusNode.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => AppShortcutsHost(child: child!),
      home: Scaffold(
        body: AppShortcutScope(
          handlers: {
            AppShortcutAction.newWindow: appCalls.add,
            AppShortcutAction.closeWindow: appCalls.add,
            AppShortcutAction.goToWindow: appCalls.add,
          },
          child: Focus(
            focusNode: focusNode,
            child: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  output.clear();
  return (
    output: output,
    appCalls: appCalls,
    focusNode: focusNode,
    terminal: terminal,
  );
}

/// What the terminal would send for [key] with these modifiers.
String _expectedTerminalOutput(
  TerminalKey key, {
  bool kitty = false,
  bool ctrl = false,
  bool shift = false,
  bool meta = false,
}) {
  final output = <String>[];
  final terminal = Terminal(onOutput: output.add);
  if (kitty) {
    terminal.write(_kittyDisambiguateAndReleases);
  }
  output.clear();
  terminal.keyInput(key, ctrl: ctrl, shift: shift, meta: meta);
  return output.join();
}

Future<void> _chord(
  WidgetTester tester,
  List<LogicalKeyboardKey> modifiers,
  LogicalKeyboardKey key, {
  bool releaseModifiersFirst = false,
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyDownEvent(key);
  if (releaseModifiersFirst) {
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.sendKeyUpEvent(key);
  } else {
    await tester.sendKeyUpEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
  }
  await tester.pump();
}

/// Output with the modifier-only key reports a kitty terminal may emit
/// removed, leaving what the chord's main key produced.
String _withoutModifierReports(List<String> output) =>
    output.where((chunk) => !RegExp(r'^\x1b\[57\d{3}').hasMatch(chunk)).join();

void main() {
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  group('iPadOS', () {
    testWidgets('reserved ⌘ chords run the app action, never the program', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);

      await _chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.keyT);
      await _chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.digit2);
      // Releasing ⌘ before W still keeps W's release from the program.
      await _chord(
        tester,
        [LogicalKeyboardKey.metaLeft],
        LogicalKeyboardKey.keyW,
        releaseModifiersFirst: true,
      );

      expect(harness.appCalls, const [
        AppShortcutIntent(AppShortcutAction.newWindow),
        AppShortcutIntent(AppShortcutAction.goToWindow, windowNumber: 2),
        AppShortcutIntent(AppShortcutAction.closeWindow),
      ]);
      expect(_withoutModifierReports(harness.output), isEmpty);
    }, variant: ios);

    testWidgets('other ⌘ chords still reach a kitty-protocol program', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);

      await _chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.keyK);

      expect(harness.appCalls, isEmpty);
      final expected = _expectedTerminalOutput(
        TerminalKey.keyK,
        kitty: true,
        meta: true,
      );
      expect(expected, isNotEmpty);
      expect(_withoutModifierReports(harness.output), startsWith(expected));
    }, variant: ios);

    testWidgets('⌘ with arrows and plain Ctrl chords are unchanged', (
      tester,
    ) async {
      final harness = await _pump(tester);

      await _chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.arrowUp);
      await _chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyC);
      // Ctrl+Shift+T is an app chord on Android only.
      await _chord(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.arrowLeft);

      expect(harness.appCalls, isEmpty);
      expect(
        harness.output.join(),
        _expectedTerminalOutput(TerminalKey.arrowUp, meta: true) +
            _expectedTerminalOutput(TerminalKey.keyC, ctrl: true) +
            _expectedTerminalOutput(
              TerminalKey.arrowLeft,
              ctrl: true,
              shift: true,
            ),
      );
    }, variant: ios);
  });

  group('keys pressed outside the terminal (review round 1)', () {
    testWidgets('never send repeats or releases into the program', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);
      final elsewhere = FocusNode();
      addTearDown(elsewhere.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(focusNode: elsewhere, child: const SizedBox(height: 10)),
                Expanded(
                  child: Focus(
                    focusNode: harness.focusNode,
                    child: TerminalTextInputHandler(
                      terminal: harness.terminal,
                      focusNode: harness.focusNode,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      elsewhere.requestFocus();
      await tester.pump();
      harness.output.clear();

      // Esc closes a switcher row; focus lands on the terminal while held.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      harness.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(harness.output.join(), isEmpty);

      // The next press goes through as usual.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(harness.output.join(), isNotEmpty);
    }, variant: android);

    testWidgets('a key pressed in the terminal still gets its release', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);
      final elsewhere = FocusNode();
      addTearDown(elsewhere.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(focusNode: elsewhere, child: const SizedBox(height: 10)),
                Expanded(
                  child: Focus(
                    focusNode: harness.focusNode,
                    child: TerminalTextInputHandler(
                      terminal: harness.terminal,
                      focusNode: harness.focusNode,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      harness.focusNode.requestFocus();
      await tester.pump();
      harness.output.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      expect(harness.output, hasLength(1));
      elsewhere.requestFocus();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);

      // Kitty event types: the release ends in ":3A".
      expect(harness.output, hasLength(2));
      expect(harness.output.last, endsWith(':3A'));
    }, variant: android);
  });

  group('Android', () {
    testWidgets('reserved Ctrl+Shift chords run the app action only', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);

      await _chord(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.keyT);

      expect(harness.appCalls, const [
        AppShortcutIntent(AppShortcutAction.newWindow),
      ]);
      expect(_withoutModifierReports(harness.output), isEmpty);
    }, variant: android);

    testWidgets('Ctrl, Meta and other Ctrl+Shift chords reach the program', (
      tester,
    ) async {
      final harness = await _pump(tester, kitty: true);

      await _chord(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.keyT);
      await _chord(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.keyC);
      await _chord(tester, [
        LogicalKeyboardKey.metaLeft,
      ], LogicalKeyboardKey.keyT);

      expect(harness.appCalls, isEmpty);
      final sent = _withoutModifierReports(harness.output);
      for (final expected in [
        _expectedTerminalOutput(TerminalKey.keyT, kitty: true, ctrl: true),
        _expectedTerminalOutput(
          TerminalKey.keyC,
          kitty: true,
          ctrl: true,
          shift: true,
        ),
        _expectedTerminalOutput(TerminalKey.keyT, kitty: true, meta: true),
      ]) {
        expect(expected, isNotEmpty);
        expect(sent, contains(expected));
      }
    }, variant: android);
  });
}
