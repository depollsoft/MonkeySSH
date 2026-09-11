import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';

import '../helpers/terminal_input_harness.dart';

const _marker = '\u200B\u200B';

TextEditingValue _editingValue(String text, {bool composing = false}) =>
    TextEditingValue(
      text: '$_marker$text',
      selection: TextSelection.collapsed(offset: _marker.length + text.length),
      composing: composing
          ? TextRange(start: _marker.length, end: _marker.length + text.length)
          : TextRange.empty,
    );

void main() {
  for (final enter in ['\n', '\r', '\r\n']) {
    testWidgets('frames IME batch before Return ${enter.codeUnits}', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        initialTerminalOutput: '\x1b[?2004h',
      );

      tester.testTextInput.updateEditingValue(_editingValue('hello$enter'));
      await tester.pump();
      (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
          .performAction(TextInputAction.newline);
      await tester.pump();

      expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\r']);
      await disposeTerminalInputHarness(tester, harness);
    });
  }

  for (final text in ['hello', 'y', '你好', '👩🏽‍💻']) {
    for (final composing in [false, true]) {
      testWidgets('frames $text before Return, composing: $composing', (
        tester,
      ) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          initialTerminalOutput: '\x1b[?2004h',
        );
        tester.testTextInput.updateEditingValue(
          _editingValue(composing ? text : '$text\n', composing: composing),
        );
        await tester.pump();
        if (composing) {
          expect(harness.terminalOutput, isEmpty);
          (tester.state(find.byType(TerminalTextInputHandler))
                  as TextInputClient)
              .performAction(TextInputAction.newline);
          await tester.pump();
        }

        expect(harness.terminalOutput, ['\x1b[200~$text\x1b[201~', '\r']);
        await disposeTerminalInputHarness(tester, harness);
      });
    }
  }

  testWidgets('frames a batch committed before a later Return action', (
    tester,
  ) async {
    final harness = await pumpTerminalInputHarness(
      tester,
      initialTerminalOutput: '\x1b[?2004h',
    );
    tester.testTextInput.updateEditingValue(_editingValue('hello'));
    await tester.pump();
    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~']);

    (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
        .performAction(TextInputAction.newline);
    await tester.pump();
    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\r']);
    await disposeTerminalInputHarness(tester, harness);
  });

  testWidgets('preserves control characters in IME input', (tester) async {
    final harness = await pumpTerminalInputHarness(
      tester,
      initialTerminalOutput: '\x1b[?2004h',
    );
    tester.testTextInput.updateEditingValue(_editingValue('a\tb'));
    await tester.pump();

    expect(harness.terminalOutput, ['a\tb']);
    await disposeTerminalInputHarness(tester, harness);
  });

  testWidgets('keeps ordinary typing and unsupported batch input unchanged', (
    tester,
  ) async {
    final harness = await pumpTerminalInputHarness(
      tester,
      initialTerminalOutput: '\x1b[?2004h',
    );
    tester.testTextInput.updateEditingValue(_editingValue('h'));
    await tester.pump();
    harness.terminal.write('\x1b[?2004l');
    tester.testTextInput.updateEditingValue(_editingValue('hello\n'));
    await tester.pump();

    expect(harness.terminalOutput, ['h', 'ello', '\r']);
    await disposeTerminalInputHarness(tester, harness);
  });

  testWidgets('keeps modified text out of bracketed paste', (tester) async {
    final harness = await pumpTerminalInputHarness(
      tester,
      initialTerminalOutput: '\x1b[?2004h',
      applyTerminalTextInputModifiers: (text) => '\x1b$text',
    );
    tester.testTextInput.updateEditingValue(_editingValue('hello'));
    await tester.pump();

    expect(harness.terminalOutput, ['\x1bhello']);
    await disposeTerminalInputHarness(tester, harness);
  });

  testWidgets('keeps Shift Return separate from a committed batch', (
    tester,
  ) async {
    var shift = true;
    final harness = await pumpTerminalInputHarness(
      tester,
      initialTerminalOutput: '\x1b[?2004h\x1b[>1u',
      resolveTerminalKeyModifiers: () =>
          (ctrl: false, alt: false, shift: shift),
      consumeTerminalKeyModifiers: () => shift = false,
    );
    tester.testTextInput.updateEditingValue(_editingValue('hello\n'));
    await tester.pump();

    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\x1b[13;2u']);
    expect(shift, isFalse);
    await disposeTerminalInputHarness(tester, harness);
  });
}
