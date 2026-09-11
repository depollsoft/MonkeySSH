import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/presentation/screens/key_add_screen.dart';

class _MockKeyService extends Mock implements KeyService {}

void main() {
  for (final importing in [false, true]) {
    testWidgets(
      '${importing ? 'import' : 'generation'} completes after discarding the screen',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final service = _MockKeyService();
        final completion = Completer<SshKey?>();
        const privateKey =
            '-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----';
        when(
          () => importing
              ? service.importKey(
                  name: 'Test key',
                  privateKeyPem: privateKey,
                  passphrase: 'secret',
                )
              : service.generateKey(
                  name: 'Test key',
                  keyType: SshKeyType.ed25519,
                  passphrase: 'secret',
                ),
        ).thenAnswer((_) => completion.future);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              keyServiceProvider.overrideWithValue(service),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            KeyAddScreen(initialTabIndex: importing ? 1 : 0),
                      ),
                    ),
                    child: const Text('Add key'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Add key'));
        await tester.pumpAndSettle();
        for (final (label, value) in [
          ('Key Name', 'Test key'),
          if (importing) ('Private Key (PEM format)', privateKey),
          (
            importing ? 'Passphrase (if encrypted)' : 'Passphrase (optional)',
            'secret',
          ),
        ]) {
          final field = find.widgetWithText(TextFormField, label);
          await tester.ensureVisible(field);
          await tester.enterText(field, value);
        }
        final submit = find.text(importing ? 'Import Key' : 'Generate Key');
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pump();
        expect(
          find.text(importing ? 'Importing...' : 'Generating...'),
          findsOneWidget,
        );

        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.byType(KeyAddScreen), findsNothing);
        completion.complete(
          SshKey(
            id: 1,
            name: 'Test key',
            keyType: 'ed25519',
            publicKey: 'public key',
            privateKey: privateKey,
            createdAt: DateTime(2026),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
