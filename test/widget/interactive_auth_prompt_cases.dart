// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/interactive_auth_prompt.dart';
import 'package:monkeyssh/domain/services/interactive_auth_prompt.dart';

void registerInteractiveAuthPromptTests() {
  group('interactive_auth_prompt', () {
    group('createInteractiveAuthPromptHandler', () {
      testWidgets('returns null when no navigator is available', (
        tester,
      ) async {
        final handler = createInteractiveAuthPromptHandler();

        final result = await handler(
          const SshAuthChallenge(
            hostLabel: 'tester@headless.example.com:22',
            username: 'tester',
            name: '',
            instruction: '',
            prompts: [SshAuthPrompt(prompt: 'Password:', echo: false)],
          ),
        );

        expect(result, isNull);
      });
    });
  });
}
