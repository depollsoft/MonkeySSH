// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';

import '../../helpers/terminal_input_harness.dart';
import '../../helpers/terminal_input_helpers.dart';

const _deleteDetectionMarker = '\u200B\u200B';

void main() {
  group('TerminalTextInputHandler', () {
    testWidgets('controller resets platform IME completions', (tester) async {
      final harness = await pumpTerminalInputHarness(tester);
      final controller = harness.controller;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      tester.testTextInput.log.clear();

      controller.resetImeCompletions();
      await tester.pump();

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isNotEmpty,
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('clears composing IME state after a touch-driven caret move', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello world',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      await tester.pump();

      terminalOutput.clear();

      await tester.tap(find.byType(TerminalTextInputHandler));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello world',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 8, end: 13),
        ),
      );
      await tester.pump();

      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello world',
          initialCursorOffset: 'hello world'.length,
        ),
        (text: 'hello world', cursorOffset: 'hello '.length),
      );

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      terminalOutput.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      expect(terminalOutput, ['\x7f']);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'sends one backspace when stale IME selection deletes a chunk after touch',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello world',
            selection: TextSelection.collapsed(offset: 13),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello ',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello world',
            initialCursorOffset: 'hello world'.length,
          ),
          (text: 'hello worl', cursorOffset: 'hello worl'.length),
        );

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'does not move before backspacing a stale chunk deletion after touch',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello world',
            selection: TextSelection.collapsed(offset: 13),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello ',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(terminalOutput, ['\x7f']);
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello world',
            initialCursorOffset: 'hello '.length,
          ),
          (text: 'helloworld', cursorOffset: 'hello'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'sends repeated backspaces while Android IME keeps text composing',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}nano',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();
        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}nan',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 2, end: 5),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}na',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 2, end: 4),
          ),
        );
        await tester.pump();

        expect(terminalOutput, ['\x7f', '\x7f']);
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'nano',
            initialCursorOffset: 'nano'.length,
          ),
          (text: 'na', cursorOffset: 'na'.length),
        );

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}na',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        expect(terminalOutput, isEmpty);

        await disposeTerminalInputHarness(tester, harness);
      },
    );
  });
}
