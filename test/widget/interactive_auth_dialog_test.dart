// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/interactive_auth_prompt.dart';
import 'package:monkeyssh/presentation/widgets/interactive_auth_dialog.dart';

import 'interactive_auth_prompt_cases.dart';

class _ResultHolder {
  List<String>? value;
  bool resolved = false;
}

void main() {
  group('interactive_auth_dialog', () {
    group('showInteractiveAuthDialog', () {
      Future<_ResultHolder> openDialog(
        WidgetTester tester,
        SshAuthChallenge challenge,
      ) async {
        final holder = _ResultHolder();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    final value = await showInteractiveAuthDialog(
                      context: context,
                      challenge: challenge,
                    );
                    holder
                      ..value = value
                      ..resolved = true;
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        return holder;
      }

      const passwordChallenge = SshAuthChallenge(
        hostLabel: 'tester@host.example.com:22',
        username: 'tester',
        name: '',
        instruction: '',
        prompts: [SshAuthPrompt(prompt: 'Password:', echo: false)],
      );

      testWidgets('returns the entered password on continue', (tester) async {
        final holder = await openDialog(tester, passwordChallenge);

        expect(find.text('Password required'), findsOneWidget);
        expect(find.text('tester@host.example.com:22'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'hunter2');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(holder.resolved, isTrue);
        expect(holder.value, ['hunter2']);
      });

      testWidgets('returns null when cancelled', (tester) async {
        final holder = await openDialog(tester, passwordChallenge);

        await tester.enterText(find.byType(TextField), 'ignored');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(holder.resolved, isTrue);
        expect(holder.value, isNull);
      });

      testWidgets('obscures hidden prompts and reveals on toggle', (
        tester,
      ) async {
        await openDialog(tester, passwordChallenge);

        TextField field() => tester.widget<TextField>(find.byType(TextField));
        expect(field().obscureText, isTrue);

        await tester.tap(find.byIcon(Icons.visibility_outlined));
        await tester.pump();
        expect(field().obscureText, isFalse);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });

      testWidgets('collects multiple keyboard-interactive responses', (
        tester,
      ) async {
        const challenge = SshAuthChallenge(
          hostLabel: 'tester@host.example.com:22',
          username: 'tester',
          name: 'Two-factor',
          instruction: 'Enter your codes',
          prompts: [
            SshAuthPrompt(prompt: 'Token:', echo: true),
            SshAuthPrompt(prompt: 'Password:', echo: false),
          ],
        );
        final holder = await openDialog(tester, challenge);

        expect(find.text('Two-factor'), findsOneWidget);
        expect(find.text('Enter your codes'), findsOneWidget);

        final fields = find.byType(TextField);
        expect(fields, findsNWidgets(2));
        expect(tester.widget<TextField>(fields.at(0)).obscureText, isFalse);
        expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);

        await tester.enterText(fields.at(0), '123456');
        await tester.enterText(fields.at(1), 'secret');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(holder.resolved, isTrue);
        expect(holder.value, ['123456', 'secret']);
      });
    });
  });
  registerInteractiveAuthPromptTests();
}
