// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcut_scope.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcuts.dart';

const _peekDelay = Duration(milliseconds: 300);

Widget _app({required Widget home}) => MaterialApp(
  builder: (context, child) =>
      AppShortcutsHost(holdToPeekDelay: _peekDelay, child: child!),
  home: home,
);

Future<bool> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool control = false,
  bool shift = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final handled = await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  return handled;
}

void main() {
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('runs the focused scope handler inside a keyboard flow', (
    tester,
  ) async {
    final calls = <AppShortcutIntent>[];
    var ranInKeyboardFlow = false;
    await tester.pumpWidget(
      _app(
        home: AppShortcutScope(
          handlers: {
            AppShortcutAction.newWindow: (intent) {
              calls.add(intent);
              ranInKeyboardFlow = isHardwareKeyboardFlow;
            },
            AppShortcutAction.goToWindow: calls.add,
          },
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    expect(await _press(tester, LogicalKeyboardKey.keyT, meta: true), isTrue);
    expect(await _press(tester, LogicalKeyboardKey.digit3, meta: true), isTrue);

    expect(calls, const [
      AppShortcutIntent(AppShortcutAction.newWindow),
      AppShortcutIntent(AppShortcutAction.goToWindow, windowNumber: 3),
    ]);
    expect(ranInKeyboardFlow, isTrue);
  }, variant: ios);

  testWidgets('inner scopes win and outer scopes fill in', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _app(
        home: AppShortcutScope(
          handlers: {
            AppShortcutAction.newWindow: (_) => calls.add('outer new'),
            AppShortcutAction.closeWindow: (_) => calls.add('outer close'),
          },
          child: AppShortcutScope(
            handlers: {
              AppShortcutAction.newWindow: (_) => calls.add('inner new'),
              AppShortcutAction.closeWindow: null,
            },
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.keyT, meta: true);
    await _press(tester, LogicalKeyboardKey.keyW, meta: true);

    expect(calls, ['inner new', 'outer close']);
  }, variant: ios);

  testWidgets('an unavailable action leaves the chord unhandled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        home: const AppShortcutScope(
          handlers: {AppShortcutAction.newWindow: null},
          child: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    expect(await _press(tester, LogicalKeyboardKey.keyT, meta: true), isFalse);
  }, variant: ios);

  testWidgets('scopes of the current route answer when nothing is focused', (
    tester,
  ) async {
    final calls = <String>[];
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => AppShortcutsHost(child: child!),
        home: AppShortcutScope(
          handlers: {AppShortcutAction.newWindow: (_) => calls.add('home')},
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(await _press(tester, LogicalKeyboardKey.keyT, meta: true), isTrue);
    expect(calls, ['home']);

    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();

    expect(await _press(tester, LogicalKeyboardKey.keyT, meta: true), isFalse);
    expect(calls, ['home']);
  }, variant: ios);

  testWidgets('chords do nothing while another route covers the scope', (
    tester,
  ) async {
    // Touch-opened terminal sheets leave focus on the terminal underneath.
    final calls = <String>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: AppShortcutScope(
            handlers: {
              AppShortcutAction.newWindow: (_) => calls.add('new'),
              AppShortcutAction.closeWindow: (_) => calls.add('close'),
            },
            child: Builder(
              builder: (context) => Focus(
                focusNode: focusNode,
                autofocus: true,
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    requestFocus: false,
                    builder: (_) => const SizedBox(height: 200),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue);

    expect(await _press(tester, LogicalKeyboardKey.keyT, meta: true), isFalse);
    expect(await _press(tester, LogicalKeyboardKey.keyW, meta: true), isFalse);
    expect(calls, isEmpty);

    // The shortcuts list stays reachable everywhere.
    await _press(tester, LogicalKeyboardKey.slash, meta: true);
    await tester.pumpAndSettle();
    expect(find.text('keyboard shortcuts'), findsOneWidget);
  }, variant: ios);

  testWidgets('⌘/ opens and closes the shortcuts sheet', (tester) async {
    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.slash, meta: true);
    await tester.pumpAndSettle();

    expect(find.text('keyboard shortcuts'), findsOneWidget);
    expect(find.text('⌘T'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.slash, meta: true);
    await tester.pumpAndSettle();

    expect(find.text('keyboard shortcuts'), findsNothing);
  }, variant: ios);

  testWidgets('Ctrl+Shift+/ opens the shortcuts sheet on Android', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.slash, control: true, shift: true);
    await tester.pumpAndSettle();

    expect(find.text('keyboard shortcuts'), findsOneWidget);
    expect(find.text('Ctrl+Shift+T'), findsOneWidget);
  }, variant: android);

  testWidgets('holding ⌘ alone peeks at the shortcuts until release', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    final peek = find.byKey(const ValueKey('keyboard-shortcuts-peek'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(_peekDelay ~/ 2);
    expect(peek, findsNothing);
    await tester.pump(_peekDelay);
    expect(peek, findsOneWidget);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // It fades out rather than vanishing.
    expect(peek, findsOneWidget);
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: peek, matching: find.byType(AnimatedOpacity)),
    );
    expect(opacity.opacity, 0);
    await tester.pump(const Duration(milliseconds: 200));
    // The fade's end removes the panel on the next frame.
    await tester.pump();
    expect(peek, findsNothing);

    // A chord typed before the delay never shows the peek.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(_peekDelay ~/ 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump(_peekDelay * 2);
    expect(peek, findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }, variant: ios);

  testWidgets('with Reduce Motion the peek hides at once, cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: AppShortcutsHost(holdToPeekDelay: _peekDelay, child: child!),
        ),
        home: const Scaffold(
          body: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    final peek = find.byKey(const ValueKey('keyboard-shortcuts-peek'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(_peekDelay * 2);
    expect(peek, findsOneWidget);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(peek, findsNothing);
  }, variant: ios);

  testWidgets('Android has no hold-to-peek', (tester) async {
    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(_peekDelay * 2);
    expect(find.byKey(const ValueKey('keyboard-shortcuts-peek')), findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }, variant: android);
}
