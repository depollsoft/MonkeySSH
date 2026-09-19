// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/models/acp_slash_command.dart';

AcpAvailableCommand cmd(String name, String description, {String? hint}) =>
    AcpAvailableCommand(
      name: name,
      description: description,
      input: hint == null ? null : AcpCommandInput(hint: hint),
    );

void registerAcpSlashCommandTests() {
  group('acp_slash_command', () {
    group('parseSlashQuery', () {
      test('activates on a leading slash token', () {
        expect(parseSlashQuery('/dep'), const AcpSlashQuery('dep'));
        expect(parseSlashQuery('/'), const AcpSlashQuery(''));
      });

      test('does not trigger for a non-leading slash in prose', () {
        expect(parseSlashQuery('open lib/main.dart'), isNull);
        expect(parseSlashQuery('1/2 done'), isNull);
      });

      test('stops once arguments (whitespace) begin', () {
        expect(parseSlashQuery('/deploy '), isNull);
        expect(parseSlashQuery('/deploy prod'), isNull);
        expect(parseSlashQuery('/deploy\n'), isNull);
      });

      test('ignores a doubled slash', () {
        expect(parseSlashQuery('//comment'), isNull);
      });
    });

    group('matchSlashCommands', () {
      final commands = [
        cmd('deploy', 'Deploy the current build'),
        cmd('debug', 'Attach a debugger'),
        cmd('help', 'Show deploy and debug help'),
      ];

      test('empty query returns all commands in order', () {
        expect(matchSlashCommands('', commands).map((c) => c.name), [
          'deploy',
          'debug',
          'help',
        ]);
      });

      test('matches by name prefix and ranks before description matches', () {
        final result = matchSlashCommands('dep', commands);
        expect(result.first.name, 'deploy');
        // "help" matches on description ("deploy") and comes last.
        expect(result.map((c) => c.name), ['deploy', 'help']);
      });

      test('matches on description when the name does not match', () {
        final result = matchSlashCommands('debugger', commands);
        expect(result.map((c) => c.name), ['debug']);
      });

      test('is case-insensitive', () {
        expect(matchSlashCommands('DEP', commands).first.name, 'deploy');
      });
    });

    group('applySlashCommand', () {
      test('replaces the leading token with a spaced command', () {
        final insertion = applySlashCommand(
          fullText: '/dep',
          command: cmd('deploy', 'Deploy'),
        );
        expect(insertion.text, '/deploy ');
        expect(insertion.caret, '/deploy '.length);
      });

      test('preserves trailing text with a single separating space', () {
        final insertion = applySlashCommand(
          fullText: '/dep leftover',
          command: cmd('deploy', 'Deploy'),
        );
        expect(insertion.text, '/deploy leftover');
        expect(insertion.caret, '/deploy '.length);
      });
    });
  });
}
