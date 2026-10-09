// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_shortcuts_sheet.dart';

void main() {
  test('lists iPadOS chords, grouping the numbered windows', () {
    final entries = keyboardShortcutListEntries(TargetPlatform.iOS);
    final byLabel = {for (final entry in entries) entry.label: entry};

    expect(byLabel['Next window']?.chord, '⇧⌘]');
    expect(byLabel['Previous window']?.chord, '⇧⌘[');
    expect(byLabel['Go to window numbered 0–9']?.chord, '⌘0–9');
    expect(
      byLabel['Go to window numbered 0–9']?.semanticChord,
      'Command 0 to 9',
    );
    expect(byLabel['New window']?.chord, '⌘T');
    expect(byLabel['Close window']?.chord, '⌘W');
    expect(byLabel['Show or hide windows']?.chord, '⌃⌘S');
    expect(byLabel['Focus composer or terminal']?.chord, '⌘L');
    expect(byLabel['Browse files (SFTP)']?.chord, '⌘O');
    expect(byLabel['Keyboard shortcuts']?.chord, '⌘/');
    // Hooks for unbuilt features are not listed.
    expect(byLabel.containsKey('Find in scrollback'), isFalse);
    expect(byLabel.containsKey('Working tree changes'), isFalse);
    expect(entries.where((entry) => entry.label.startsWith('Go to window')), [
      isA<KeyboardShortcutListEntry>(),
    ]);
  });

  test('lists Android chords with Ctrl+Shift', () {
    final entries = keyboardShortcutListEntries(TargetPlatform.android);
    final byLabel = {for (final entry in entries) entry.label: entry};

    expect(byLabel['New window']?.chord, 'Ctrl+Shift+T');
    expect(byLabel['Go to window numbered 0–9']?.chord, 'Ctrl+Shift+0–9');
    expect(byLabel['Show or hide windows']?.chord, 'Ctrl+Shift+S');
  });

  test('desktop platforms list nothing', () {
    expect(keyboardShortcutListEntries(TargetPlatform.macOS), isEmpty);
    expect(keyboardShortcutPrecedenceNote(TargetPlatform.macOS), isEmpty);
  });

  testWidgets('settings row opens the shortcuts sheet', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [KeyboardShortcutsSettingsTile()]),
        ),
      ),
    );

    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();

    expect(find.text('keyboard shortcuts'), findsOneWidget);
    expect(find.text('⌘W'), findsOneWidget);
    expect(find.bySemanticsLabel('Close window: Command W'), findsOneWidget);
    expect(KeyboardShortcutsSheet.isOpen, isTrue);
    expect(KeyboardShortcutsSheet.closeIfOpen(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('keyboard shortcuts'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('settings row is hidden where there are no shortcuts', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [KeyboardShortcutsSettingsTile()]),
        ),
      ),
    );

    expect(find.text('Keyboard shortcuts'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('peek panel fits a phone-width screen', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KeyboardShortcutsPeek())),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Next window'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('keyboard-shortcuts-peek')))
          .width,
      lessThanOrEqualTo(375 - 32),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
