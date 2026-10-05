/// `{{name}}` placeholders in a snippet command.
final snippetVariablePattern = RegExp(r'\{\{(\w+)\}\}');

/// Distinct variable names in [command], in first-occurrence order.
List<String> extractSnippetVariables(String command) => snippetVariablePattern
    .allMatches(command)
    .map((match) => match.group(1)!)
    .toSet()
    .toList();
