/// Supported host auto-connect command sources.
enum AutoConnectCommandMode {
  /// Do not run a command automatically.
  none,

  /// Run the host's saved custom command.
  custom,

  /// Run the command from a selected snippet.
  snippet,
}

/// Suggested tmux command for automatic startup after connecting.
const defaultAutoConnectCommandSuggestion = 'tmux new -As MonkeySSH';

final _disallowedCommandControlCharacters = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',
);

/// Matches any control character that terminal text must not carry.
final terminalControlCharacterPattern = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// Matches a CR or LF line break.
final terminalNewlinePattern = RegExp(r'[\r\n]');

/// Reasons a terminal command should be reviewed before it is inserted or run.
enum TerminalCommandReviewReason {
  /// The command came from imported auto-connect configuration.
  importedAutoConnect,

  /// The command would run because a `monkeyssh://` or `ssh://` link opened
  /// the terminal, and links never run commands on their own.
  openedFromLink,

  /// The command spans multiple lines.
  multiline,

  /// The command contains control characters that are not normally visible.
  controlCharacters,

  /// The command chains multiple shell operations together.
  shellChaining,

  /// The command redirects input or output.
  redirection,

  /// The command uses shell command substitution.
  commandSubstitution,

  /// The command was rendered from snippet variables.
  variableSubstitution,
}

/// Review metadata for a terminal command before insertion or execution.
class TerminalCommandReview {
  /// Creates a [TerminalCommandReview].
  const TerminalCommandReview({
    required this.command,
    required this.reasons,
    this.bracketedPasteModeEnabled = false,
  });

  /// The fully rendered command text.
  final String command;

  /// Reasons why the command should be reviewed.
  final List<TerminalCommandReviewReason> reasons;

  /// Whether bracketed paste mode is active for the current terminal session.
  final bool bracketedPasteModeEnabled;

  /// Whether this command should be confirmed with the user before use.
  bool get requiresReview => reasons.isNotEmpty;
}

/// Resolves the effective auto-connect mode from persisted host fields.
AutoConnectCommandMode resolveAutoConnectCommandMode({
  required String? command,
  required int? snippetId,
}) {
  if (snippetId != null) {
    return AutoConnectCommandMode.snippet;
  }
  if (_hasVisibleContent(command)) {
    return AutoConnectCommandMode.custom;
  }
  return AutoConnectCommandMode.none;
}

/// Resolves the command text that should be sent to the shell.
String? resolveAutoConnectCommandText({
  required AutoConnectCommandMode mode,
  String? storedCommand,
  String? snippetCommand,
}) => switch (mode) {
  AutoConnectCommandMode.none => null,
  AutoConnectCommandMode.custom =>
    _hasVisibleContent(storedCommand) ? storedCommand : null,
  AutoConnectCommandMode.snippet =>
    _hasVisibleContent(snippetCommand)
        ? snippetCommand
        : _hasVisibleContent(storedCommand)
        ? storedCommand
        : null,
};

/// Ensures a shell command ends with an Enter key sequence before sending it.
String formatAutoConnectCommandForShell(String command) {
  if (command.endsWith('\r') || command.endsWith('\n')) {
    return command;
  }
  return '$command\r';
}

/// Rejects imported auto-connect text with hidden control characters.
void validateImportedAutoConnectCommandText(String command) {
  if (_disallowedCommandControlCharacters.hasMatch(command)) {
    throw const FormatException(
      'Imported auto-connect command contains unsupported control characters',
    );
  }
}

/// Normalizes an imported auto-connect command before it is stored locally.
String? normalizeImportedAutoConnectCommand(String? command) {
  if (!_hasVisibleContent(command)) {
    return null;
  }

  final normalized = command!.trim();
  validateImportedAutoConnectCommandText(normalized);
  return normalized;
}

/// Whether an imported host auto-connect command needs first-run review.
bool importedAutoConnectRequiresReview({
  required String? command,
  required int? snippetId,
}) =>
    resolveAutoConnectCommandMode(command: command, snippetId: snippetId) !=
    AutoConnectCommandMode.none;

/// Assesses pasted text for shell content that still deserves review.
TerminalCommandReview assessClipboardPasteCommand(
  String command, {
  required bool bracketedPasteModeEnabled,
}) => TerminalCommandReview(
  command: command,
  reasons: _collectPasteCommandReviewReasons(
    command,
    bracketedPasteModeEnabled: bracketedPasteModeEnabled,
  ),
  bracketedPasteModeEnabled: bracketedPasteModeEnabled,
);

/// Assesses text inserted through the system keyboard, including dictation
/// and keyboard suggestions.
///
/// Keyboard text lands on the command line for the user to read before they
/// press Return, so its length and shell syntax need no review. It only acts
/// on its own when a line break in it is sent as Return ([sendsReturn]),
/// running the line before it, or when it carries control characters.
TerminalCommandReview assessKeyboardInsertedCommand(
  String command, {
  required String insertedText,
  required bool sendsReturn,
  bool bracketedPasteModeEnabled = false,
}) {
  final reasons = sendsReturn
      ? _collectPasteCommandReviewReasons(
          command,
          bracketedPasteModeEnabled: false,
        )
      : [
          if (_disallowedCommandControlCharacters.hasMatch(insertedText))
            TerminalCommandReviewReason.controlCharacters,
        ];
  return TerminalCommandReview(
    command: command,
    reasons: reasons,
    bracketedPasteModeEnabled: bracketedPasteModeEnabled,
  );
}

/// Assesses a rendered snippet command before terminal insertion.
TerminalCommandReview assessSnippetCommandInsertion(
  String command, {
  required bool hadVariableSubstitution,
}) {
  final reasons = <TerminalCommandReviewReason>[
    ..._collectSuspiciousCommandReasons(command),
  ];
  if (hadVariableSubstitution) {
    reasons.add(TerminalCommandReviewReason.variableSubstitution);
  }
  return TerminalCommandReview(command: command, reasons: reasons);
}

/// Assesses an auto-connect command before it is executed automatically.
///
/// [openedFromLink] marks a terminal opened by an app link, which must show
/// the command for review instead of running it.
TerminalCommandReview assessAutoConnectCommandExecution(
  String command, {
  required bool importedNeedsReview,
  bool openedFromLink = false,
}) {
  final reasons = <TerminalCommandReviewReason>[
    if (importedNeedsReview) TerminalCommandReviewReason.importedAutoConnect,
    if (openedFromLink) TerminalCommandReviewReason.openedFromLink,
  ];
  if (reasons.isNotEmpty) {
    reasons.addAll(_collectSuspiciousCommandReasons(command));
  }
  return TerminalCommandReview(command: command, reasons: reasons);
}

/// Human-readable descriptions for [TerminalCommandReview.reasons].
List<String> describeTerminalCommandReview(TerminalCommandReview review) =>
    review.reasons.map(_describeReviewReason).toList(growable: false);

List<TerminalCommandReviewReason> _collectSuspiciousCommandReasons(
  String command,
) {
  final reasons = <TerminalCommandReviewReason>[];
  final shellTokens = _collectSuspiciousShellTokens(command);
  if (terminalNewlinePattern.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.multiline);
  }
  if (_disallowedCommandControlCharacters.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.controlCharacters);
  }
  if (shellTokens.shellChaining) {
    reasons.add(TerminalCommandReviewReason.shellChaining);
  }
  if (shellTokens.redirection) {
    reasons.add(TerminalCommandReviewReason.redirection);
  }
  if (shellTokens.commandSubstitution) {
    reasons.add(TerminalCommandReviewReason.commandSubstitution);
  }
  return reasons;
}

List<TerminalCommandReviewReason> _collectPasteCommandReviewReasons(
  String command, {
  required bool bracketedPasteModeEnabled,
}) {
  final suspiciousReasons = _collectSuspiciousCommandReasons(command);
  final hasMultiline = suspiciousReasons.contains(
    TerminalCommandReviewReason.multiline,
  );
  final hasShellChaining = suspiciousReasons.contains(
    TerminalCommandReviewReason.shellChaining,
  );
  final hasRedirection = suspiciousReasons.contains(
    TerminalCommandReviewReason.redirection,
  );
  final hasControlCharacters = suspiciousReasons.contains(
    TerminalCommandReviewReason.controlCharacters,
  );
  final hasCommandSubstitution = suspiciousReasons.contains(
    TerminalCommandReviewReason.commandSubstitution,
  );

  final shouldReviewUnbracketedMultilineText =
      !bracketedPasteModeEnabled && hasMultiline;

  if (!shouldReviewUnbracketedMultilineText &&
      !hasControlCharacters &&
      !hasCommandSubstitution) {
    return const <TerminalCommandReviewReason>[];
  }

  return [
    if (shouldReviewUnbracketedMultilineText)
      TerminalCommandReviewReason.multiline,
    if (hasControlCharacters) TerminalCommandReviewReason.controlCharacters,
    if (shouldReviewUnbracketedMultilineText && hasShellChaining)
      TerminalCommandReviewReason.shellChaining,
    if (shouldReviewUnbracketedMultilineText && hasRedirection)
      TerminalCommandReviewReason.redirection,
    if (hasCommandSubstitution) TerminalCommandReviewReason.commandSubstitution,
  ];
}

({bool shellChaining, bool redirection, bool commandSubstitution})
_collectSuspiciousShellTokens(String command) {
  var shellChaining = false;
  var redirection = false;
  var commandSubstitution = false;
  var escapeNext = false;
  var inSingleQuote = false;
  var inDoubleQuote = false;

  for (var index = 0; index < command.length; index++) {
    final character = command[index];

    if (escapeNext) {
      escapeNext = false;
      continue;
    }

    if (inSingleQuote) {
      if (character == '\'') {
        inSingleQuote = false;
      }
      continue;
    }

    if (inDoubleQuote) {
      if (character == r'\') {
        escapeNext = true;
        continue;
      }
      if (character == '"') {
        inDoubleQuote = false;
        continue;
      }
      if (character == '`') {
        commandSubstitution = true;
        continue;
      }
      if (character == r'$' &&
          index + 1 < command.length &&
          command[index + 1] == '(') {
        commandSubstitution = true;
      }
      continue;
    }

    if (character == r'\') {
      escapeNext = true;
      continue;
    }
    if (character == '\'') {
      inSingleQuote = true;
      continue;
    }
    if (character == '"') {
      inDoubleQuote = true;
      continue;
    }
    if (character == '`') {
      commandSubstitution = true;
      continue;
    }
    if (character == r'$' &&
        index + 1 < command.length &&
        command[index + 1] == '(') {
      commandSubstitution = true;
      continue;
    }
    if (character == ';' || character == '&' || character == '|') {
      shellChaining = true;
    } else if (character == '<' || character == '>') {
      redirection = true;
    }

    if (shellChaining && redirection && commandSubstitution) {
      break;
    }
  }

  return (
    shellChaining: shellChaining,
    redirection: redirection,
    commandSubstitution: commandSubstitution,
  );
}

String _describeReviewReason(TerminalCommandReviewReason reason) =>
    switch (reason) {
      TerminalCommandReviewReason.importedAutoConnect =>
        'Imported auto-connect commands need review before they can run.',
      TerminalCommandReviewReason.openedFromLink =>
        'A link opened this terminal, so its auto-connect command waits for '
            'you.',
      TerminalCommandReviewReason.multiline =>
        'This command spans multiple lines.',
      TerminalCommandReviewReason.controlCharacters =>
        'This command contains hidden control characters.',
      TerminalCommandReviewReason.shellChaining =>
        'This command chains multiple shell operations.',
      TerminalCommandReviewReason.redirection =>
        'This command redirects input or output.',
      TerminalCommandReviewReason.commandSubstitution =>
        'This command uses shell command substitution.',
      TerminalCommandReviewReason.variableSubstitution =>
        'Snippet variables were substituted into the final command.',
    };

bool _hasVisibleContent(String? value) =>
    value != null && value.trim().isNotEmpty;
