import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_terminal_display.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_terminal_output.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  test('plain terminal text strips escapes and resolves overwrites', () {
    expect(
      acpPlainTerminalText(
        '\x1B[32mPASS\x1B[0m a\r\n'
        '10%\r50%\r100%\n'
        '\x1B]0;title\x07done\r',
      ),
      'PASS a\n100%\ndone',
    );
  });

  testWidgets('shows live output and exit status for an embedded terminal', (
    tester,
  ) async {
    final display = ValueNotifier<AcpTerminalDisplay?>(
      const AcpTerminalDisplay(
        terminalId: 'term-1',
        command: 'npm test',
        output: 'running\n',
      ),
    );
    addTearDown(display.dispose);
    final resolved = <String>[];
    await tester.pumpWidget(
      _wrap(
        AcpTerminalOutputScope(
          resolver: (id) {
            resolved.add(id);
            return display;
          },
          child: AcpToolCallView(
            toolCall: AcpToolCall(
              id: 'tool-1',
              title: 'Run tests',
              kind: AcpToolKind.execute,
              status: AcpToolStatus.running,
              terminalIds: const ['term-1'],
            ),
          ),
        ),
      ),
    );

    expect(resolved, contains('term-1'));
    expect(find.text(r'$ npm test'), findsOneWidget);
    expect(find.text('running'), findsWidgets);
    // The terminal replaces the generic pending-result placeholder.
    expect(find.textContaining('result: …'), findsNothing);

    display.value = display.value!.copyWith(
      output: 'running\n\x1B[31mFAIL\x1B[0m one\n',
      exited: true,
      exitCode: 1,
    );
    await tester.pump();
    expect(find.text('running\nFAIL one'), findsOneWidget);
    expect(find.text('exit 1'), findsOneWidget);
  });

  testWidgets('renders nothing for a terminal this client does not know', (
    tester,
  ) async {
    final unknown = ValueNotifier<AcpTerminalDisplay?>(null);
    addTearDown(unknown.dispose);
    await tester.pumpWidget(_wrap(AcpTerminalOutputView(display: unknown)));
    expect(find.byType(SelectableText), findsNothing);
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('lists resources a tool produced with open actions', (
    tester,
  ) async {
    final opened = <AcpResourceRef>[];
    await tester.pumpWidget(
      _wrap(
        AcpResourceActions(
          onOpen: opened.add,
          child: AcpToolCallView(
            toolCall: AcpToolCall(
              id: 'tool-2',
              title: 'Generate report',
              status: AcpToolStatus.completed,
              resources: const [
                AcpResourceRef(uri: 'mem://report', text: 'report body'),
              ],
            ),
            initiallyExpanded: true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('report'));
    expect(opened.single.text, 'report body');
  });
}
