import 'dart:async';
import 'dart:isolate';

/// One agent-supplied `pattern` to test against a submitted value.
typedef AcpElicitationPatternCheck = ({
  String field,
  String pattern,
  bool unicode,
  String value,
});

/// Longest time pattern checks may run before they are abandoned.
const kAcpElicitationPatternBudget = Duration(milliseconds: 500);

/// Returns the fields whose value does not match its pattern.
///
/// Agent patterns can backtrack catastrophically (`^(a+)+$` on thirty-odd
/// characters runs for many seconds), and a Dart [RegExp] match cannot be
/// interrupted. The checks therefore run in their own isolate, which is
/// killed once [budget] elapses. Checks that overrun or fail report nothing:
/// the agent validates the content again, as the spec requires.
Future<Set<String>> acpElicitationPatternMismatches(
  List<AcpElicitationPatternCheck> checks, {
  Duration budget = kAcpElicitationPatternBudget,
}) async {
  if (checks.isEmpty) return const <String>{};
  final replies = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _matchAll,
      (replies.sendPort, checks),
      // A crashed worker exits with `null`, which reads as "nothing found".
      onExit: replies.sendPort,
    );
    final reply = await replies.first.timeout(budget);
    return reply is List ? reply.cast<String>().toSet() : const <String>{};
  } on Object {
    return const <String>{};
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

void _matchAll((SendPort, List<AcpElicitationPatternCheck>) message) {
  final (replies, checks) = message;
  final mismatched = <String>[
    for (final check in checks)
      if (!RegExp(check.pattern, unicode: check.unicode).hasMatch(check.value))
        check.field,
  ];
  Isolate.exit(replies, mismatched);
}
