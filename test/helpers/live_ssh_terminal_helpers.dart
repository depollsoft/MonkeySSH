// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

Future<void> pumpUntilConnected(
  WidgetTester tester, {
  required String description,
}) async {
  await pumpUntil(
    tester,
    () => find.text('Connecting...').evaluate().isEmpty,
    description: description,
    timeout: const Duration(seconds: 60),
  );
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Terminal terminalFromView(WidgetTester tester) =>
    tester.widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView)).terminal;

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  await pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    description: 'finder $finder',
    timeout: timeout,
  );
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (predicate()) {
      return;
    }
  }
  fail('Timed out waiting for $description');
}

Future<void> waitForTerminalText(
  WidgetTester tester,
  Terminal Function() terminal,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
}) async {
  await pumpUntil(
    tester,
    () => terminalBufferText(terminal()).contains(expected),
    description: '$description\n${terminalBufferText(terminal())}',
    timeout: timeout,
  );
}

String terminalBufferText(Terminal terminal) {
  final lines = <String>[];
  for (var index = 0; index < terminal.buffer.lines.length; index += 1) {
    lines.add(
      terminal.buffer.lines[index]
          .getText(0, terminal.buffer.viewWidth)
          .trimRight(),
    );
  }
  return lines.join('\n');
}
