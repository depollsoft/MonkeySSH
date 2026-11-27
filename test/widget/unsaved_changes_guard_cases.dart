// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/unsaved_changes_guard.dart';

/// Registers tests from unsaved_changes_guard_test.dart.
void registerWidgetUnsavedChangesGuardTests() {
  group('unsaved_changes_guard', () {
    group('UnsavedChangesGuard', () {
      testWidgets('pops without a prompt when there are no changes', (
        tester,
      ) async {
        await _pumpGuardHost(tester, hasUnsavedChanges: false);

        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.text('Open editor'), findsOneWidget);
      });

      testWidgets('asks before discarding unsaved changes', (tester) async {
        await _pumpGuardHost(tester, hasUnsavedChanges: true);

        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsOneWidget);

        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();

        expect(find.text('Editor body'), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();

        expect(find.text('Editor body'), findsNothing);
        expect(find.text('Open editor'), findsOneWidget);
      });
    });
  });
}

Future<void> _pumpGuardHost(
  WidgetTester tester, {
  required bool hasUnsavedChanges,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => UnsavedChangesGuard(
                      hasUnsavedChanges: hasUnsavedChanges,
                      child: Scaffold(
                        appBar: AppBar(title: const Text('Editor')),
                        body: const Text('Editor body'),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
}
