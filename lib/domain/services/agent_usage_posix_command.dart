import 'dart:convert';

/// Runs the usage reader or reports its missing runtime for each selected agent.
String buildPosixAgentUsageCommand(
  String bootstrap,
  Map<String, String> agents,
) {
  String quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
  final input = base64.encode(utf8.encode(jsonEncode(agents)));
  final missing = agents.keys.map(
    (id) => quote(
      '__monkeyssh_usage__=${jsonEncode({'id': id, 'status': 'runtimeUnavailable'})}',
    ),
  );
  return 'if command -v node >/dev/null 2>&1; then '
      'node -e ${quote(bootstrap)} ${quote(input)} 2>/dev/null; '
      "else printf '%s\\n' ${missing.join(' ')}; fi";
}
