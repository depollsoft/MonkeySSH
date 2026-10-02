import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_terminal_display.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_code_block.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_text_sheet.dart';
import 'package:monkeyssh/presentation/widgets/acp_terminal_output.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';

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
    // A carriage return moves the cursor; it does not erase the line.
    expect(acpPlainTerminalText('abc\rX'), 'Xbc');
    expect(acpPlainTerminalText('loading 50%\rdone\x1B[K'), 'done');
    expect(acpPlainTerminalText('old line\r\x1B[2Knew'), 'new');
    expect(acpPlainTerminalText('ab\x08c'), 'ac');
    expect(acpPlainTerminalText('12345\x1B[3Gx'), '12x45');
    expect(acpPlainTerminalText('😀😀\rA'), 'A😀');
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
    // A live command shows the terminal cursor rather than a status label.
    expect(find.byType(CursorBlock), findsOneWidget);
    expect(find.textContaining('exit'), findsNothing);
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
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CursorBlock), findsNothing);
  });

  testWidgets('says how many terminals a tool call did not render', (
    tester,
  ) async {
    final unknown = ValueNotifier<AcpTerminalDisplay?>(null);
    addTearDown(unknown.dispose);
    await tester.pumpWidget(
      _wrap(
        AcpTerminalOutputScope(
          resolver: (_) => unknown,
          child: AcpToolCallView(
            toolCall: AcpToolCall(
              id: 'tool-1',
              title: 'Fan out',
              kind: AcpToolKind.execute,
              status: AcpToolStatus.completed,
              terminalIds: const ['term-1'],
              omittedTerminalCount: 12,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fan out'));
    await tester.pumpAndSettle();
    expect(find.text('12 more terminals not shown'), findsOneWidget);
  });

  testWidgets('renders nothing for a terminal this client does not know', (
    tester,
  ) async {
    final unknown = ValueNotifier<AcpTerminalDisplay?>(null);
    addTearDown(unknown.dispose);
    await tester.pumpWidget(_wrap(AcpTerminalOutputView(display: unknown)));
    expect(find.byType(SelectableText), findsNothing);
    expect(find.textContaining(r'$'), findsNothing);
    expect(find.text('Terminal output is no longer available'), findsOneWidget);
  });

  testWidgets('reads embedded resource text and opens its remote path', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _wrap(
        AcpResourceTextSheet(
          resource: const AcpResourceRef(uri: 'file:///work/lib/main.dart'),
          text: 'void main() {}',
          onOpenPath: opened.add,
        ),
      ),
    );
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.byType(AcpCodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    await tester.tap(find.text('Open in files'));
    expect(opened, ['/work/lib/main.dart']);

    await tester.pumpWidget(
      _wrap(
        AcpResourceTextSheet(
          resource: const AcpResourceRef(uri: 'mem://scratch'),
          text: 'notes',
          onOpenPath: opened.add,
        ),
      ),
    );
    expect(find.text('Open in files'), findsNothing);
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
