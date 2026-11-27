// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/keys_screen.dart';

final _testKey = SshKey(
  id: 1,
  name: 'My Ed25519 Key',
  keyType: 'ed25519',
  publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5',
  privateKey: 'test-private-key-material',
  fingerprint: 'SHA256:AB:CD:EF:01',
  createdAt: DateTime(2026),
);

ProviderScope _buildKeyScreen() => ProviderScope(
  overrides: [
    allKeysProvider.overrideWith((ref) => Stream.value([_testKey])),
  ],
  child: const MaterialApp(home: KeysScreen()),
);

/// Registers tests from keys_screen_test.dart.
void registerWidgetKeysScreenTests() {
  group('keys_screen', () {
    group('KeysScreen', () {
      testWidgets('explains key choices in the empty state', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              allKeysProvider.overrideWith(
                (ref) => Stream.value(const <SshKey>[]),
              ),
            ],
            child: const MaterialApp(home: KeysScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('no keys yet'), findsOneWidget);
        expect(find.textContaining('saving server passwords'), findsOneWidget);
        expect(find.text('Generate Key'), findsOneWidget);
        expect(find.text('Import Key'), findsOneWidget);
      });
    });

    group('private key clipboard gating', () {
      testWidgets(
        'private key is hidden by default when the details sheet opens',
        (tester) async {
          await tester.pumpWidget(_buildKeyScreen());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          await tester.tap(find.text('My Ed25519 Key'));
          await tester.pumpAndSettle();

          expect(
            find.text('Private key hidden. Tap "Reveal Private Key" to view.'),
            findsOneWidget,
          );
          expect(find.text('Copy Private Key'), findsNothing);
        },
      );

      testWidgets(
        'Copy Private Key button only appears after the user explicitly '
        'reveals the private key',
        (tester) async {
          // Use a taller viewport so the bottom sheet content is fully visible.
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });
          tester.view.physicalSize = const Size(800, 1200);
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(_buildKeyScreen());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          await tester.tap(find.text('My Ed25519 Key'));
          await tester.pumpAndSettle();

          expect(find.text('Copy Private Key'), findsNothing);

          await tester.tap(find.text('Reveal Private Key'));
          await tester.pumpAndSettle();

          expect(find.text('Copy Private Key'), findsOneWidget);
        },
      );

      testWidgets('canceling the confirmation dialog does not copy the private key '
          'to the clipboard', (tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(_buildKeyScreen());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.text('My Ed25519 Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Reveal Private Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Copy Private Key'));
        await tester.pumpAndSettle();

        expect(find.text('Copy private key?'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // No copy happened: the "Copied to clipboard" snackbar must not appear.
        expect(find.text('Copied to clipboard'), findsNothing);
      });

      testWidgets(
        'confirming the dialog copies the private key to the clipboard',
        (tester) async {
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });
          tester.view.physicalSize = const Size(800, 1200);
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(_buildKeyScreen());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          await tester.tap(find.text('My Ed25519 Key'));
          await tester.pumpAndSettle();

          await tester.tap(find.text('Reveal Private Key'));
          await tester.pumpAndSettle();

          await tester.tap(find.text('Copy Private Key'));
          await tester.pumpAndSettle();

          expect(find.text('Copy private key?'), findsOneWidget);
          expect(
            find.textContaining('Private keys are sensitive'),
            findsOneWidget,
          );

          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();

          // Copy happened: the snackbar confirms the action.
          expect(find.text('Copied to clipboard'), findsOneWidget);
        },
      );
    });
  });
}
