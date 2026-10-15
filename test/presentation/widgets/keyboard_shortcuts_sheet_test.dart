// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_shortcuts_sheet.dart';

/// The numbered windows row; a word joiner keeps the range on one line.
const _numberedLabel = 'Go to window numbered 0–\u20609';

void main() {
  test('lists iPadOS chords, grouping the numbered windows', () {
    final entries = keyboardShortcutListEntries(TargetPlatform.iOS);
    final byLabel = {for (final entry in entries) entry.label: entry};

    expect(byLabel['Next window']?.chord, '⇧⌘]');
    expect(byLabel['Previous window']?.chord, '⇧⌘[');
    expect(byLabel[_numberedLabel]?.chord, '⌘0–9');
    expect(byLabel[_numberedLabel]?.semanticChord, 'Command 0 to 9');
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
    expect(byLabel[_numberedLabel]?.chord, 'Ctrl+Shift+0–9');
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

  testWidgets('the window range never breaks across lines', (tester) async {
    final label = keyboardShortcutListEntries(TargetPlatform.iOS)
        .firstWhere((entry) => entry.label.startsWith('Go to window'))
        .label;
    final painter = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(painter.dispose);
    // One pixel too narrow for one line: the range must move as a whole.
    painter.layout(maxWidth: painter.width - 1);
    final line = painter.getLineBoundary(
      TextPosition(offset: label.indexOf('9')),
    );
    expect(line.start, label.indexOf('0'));
  });

  for (final size in const [Size(375, 667), Size(820, 1180)]) {
    testWidgets('peek panel fits ${size.width.toInt()} wide at 3.1x text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(3.1)),
            child: child!,
          ),
          home: const Scaffold(body: KeyboardShortcutsPeek()),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('keyboard shortcuts'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets(
    'settings row icon matches the platform modifier',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(children: [KeyboardShortcutsSettingsTile()]),
          ),
        ),
      );

      final isAndroid = defaultTargetPlatform == TargetPlatform.android;
      expect(
        find.byIcon(
          isAndroid ? Icons.keyboard_outlined : Icons.keyboard_command_key,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(isAndroid ? 'Ctrl+Shift+/' : '⌘/'),
        findsOneWidget,
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
