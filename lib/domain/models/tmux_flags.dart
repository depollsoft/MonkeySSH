/// Splits tmux flags into arguments, interpreting quotes and backslash escapes.
///
/// A standalone semicolon starts another tmux command. Launch presets reject
/// it, while client flag discovery uses it to find the end of the first command.
List<String> tokenizeTmuxFlags(
  String? value, {
  required bool allowCommandSeparators,
}) {
  final input = value?.trim();
  if (input == null || input.isEmpty) return const [];
  if (input.contains('\n') || input.contains('\r')) {
    throw const FormatException(
      'tmux new-session flags must stay on one line.',
    );
  }

  final tokens = <String>[];
  final token = StringBuffer();
  var started = false;
  String? quote;

  void finishToken() {
    if (!started) return;
    final word = token.toString();
    if (!allowCommandSeparators && word == ';') {
      throw const FormatException(
        r'tmux new-session flags cannot include tmux command separators like \;.',
      );
    }
    tokens.add(word);
    token.clear();
    started = false;
  }

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (quote == null && (char == ' ' || char == '\t')) {
      finishToken();
      continue;
    }

    // Opening quotes start an argument even if nothing is written between them.
    started = true;
    if (char == quote) {
      quote = null;
    } else if (quote == null && (char == "'" || char == '"')) {
      quote = char;
    } else if (char == r'\' && quote != "'") {
      if (i + 1 >= input.length) {
        throw const FormatException(
          'tmux new-session flags cannot end with an escape character.',
        );
      }
      final next = input[i + 1];
      if (quote == null || const {'"', r'\', r'$', '`'}.contains(next)) {
        token.write(next);
        i++;
      } else {
        token.write(char);
      }
    } else {
      token.write(char);
    }
  }
  if (quote != null) {
    throw const FormatException(
      'tmux new-session flags contain an unterminated quote.',
    );
  }

  finishToken();
  return tokens;
}
