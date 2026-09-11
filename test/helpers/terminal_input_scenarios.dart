// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';

import 'terminal_input_harness.dart';
import 'terminal_input_helpers.dart';

const _deleteDetectionMarker = '\u200B\u200B';

Future<void> swipeSeparatorAfterPromptReset(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    resolveTextBeforeCursor: () => '>',
  );

  harness.controller.clearImeBuffer();
  await tester.pump();

  await commitSwipeText(tester, '$_deleteDetectionMarker world');

  expect(terminalTextFromEvents(harness.terminalOutput), 'world');

  await disposeTerminalInputHarness(tester, harness);
}

Future<void> suggestionReplacingShortenedFirstWord(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    attachController: false,
  );

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  harness.terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await disposeTerminalInputHarness(tester, harness);
}

Future<void> imeSeparatorDuringDeleteReset(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    attachController: false,
    resolveTextBeforeCursor: () => 'te',
  );

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  harness.terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await disposeTerminalInputHarness(tester, harness);
}

Future<void> manualSeparatorAfterSwipeBackspace(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    attachController: false,
  );

  await commitSwipeText(tester, '$_deleteDetectionMarker teh');

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}teh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  harness.terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await disposeTerminalInputHarness(tester, harness);
}

Future<void> imeSeparatorAfterSwipeBackspace(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    attachController: false,
  );

  await commitSwipeText(tester, '${_deleteDetectionMarker}teh ');

  harness.terminalOutput.clear();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await disposeTerminalInputHarness(tester, harness);
}

Future<void> replacementAfterDeletingLaterWord(WidgetTester tester) async {
  final harness = await pumpTerminalInputHarness(
    tester,
    attachController: false,
  );

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh world ',
      selection: TextSelection.collapsed(offset: 12),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.log.clear();

  (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
      .updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: -1, extentOffset: 0),
        ),
      );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bthe ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  expect(terminalTextFromEvents(harness.terminalOutput), 'the ');
  expect(
    tester.testTextInput.log.where(
      (call) => call.method == 'TextInput.setEditingState',
    ),
    isEmpty,
  );

  await disposeTerminalInputHarness(tester, harness);
}
