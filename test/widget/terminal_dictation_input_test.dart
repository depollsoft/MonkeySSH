import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';

import '../helpers/terminal_input_harness.dart';
import '../helpers/terminal_input_helpers.dart';

const _marker = '\u200B\u200B';
const _mobilePlatforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});

TextEditingValue _dictationValue(String text, {bool composing = false}) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing
          ? TextRange(start: 0, end: text.length)
          : TextRange.empty,
    );

void main() {
  for (final prefix in ['', '\u200B', _marker]) {
    testWidgets(
      'commits dictation with ${prefix.length} delete markers exactly once',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);
        const phrase = 'Please explain this code.';

        for (final partial in ['Please', 'Please explain', phrase]) {
          tester.testTextInput.updateEditingValue(
            _dictationValue('$prefix$partial', composing: true),
          );
          await tester.pump();
          expect(harness.terminalOutput, isEmpty);
        }

        tester.testTextInput.updateEditingValue(
          _dictationValue('$prefix$phrase'),
        );
        await tester.pump();
        expect(harness.terminalOutput.join(), phrase);

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          _dictationValue('$_marker$phrase'),
        );

        // An IME may acknowledge the repaired buffer or repeat its final result.
        tester.testTextInput.updateEditingValue(
          _dictationValue('$prefix$phrase'),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _dictationValue('$_marker$phrase'),
        );
        await tester.pump();
        expect(harness.terminalOutput.join(), phrase);

        await disposeTerminalInputHarness(tester, harness);
      },
      variant: _mobilePlatforms,
    );
  }

  testWidgets(
    'replaces dictated text when the IME replaces the whole buffer',
    (tester) async {
      final harness = await pumpTerminalInputHarness(tester);
      for (final phrase in [
        'Explain the coat.',
        'Explain the code.',
        'Explain the code. 🐒',
      ]) {
        tester.testTextInput.updateEditingValue(_dictationValue(phrase));
        await tester.pump();
        expect(terminalStateFromEvents(harness.terminalOutput), (
          text: phrase,
          cursorOffset: phrase.characters.length,
        ));
      }

      await disposeTerminalInputHarness(tester, harness);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'Enter commits dictation that replaced the delete markers',
    (tester) async {
      final harness = await pumpTerminalInputHarness(tester);
      const phrase = 'Explain this code';
      tester.testTextInput.updateEditingValue(
        _dictationValue(phrase, composing: true),
      );
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(harness.terminalOutput.join(), '$phrase\r');

      await disposeTerminalInputHarness(tester, harness);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'reviews a marker-free dictation commit before sending it',
    (tester) async {
      var reviewCount = 0;
      const command = r'echo $(id)';
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (review) async {
          reviewCount++;
          expect(review.command, command);
          return false;
        },
      );
      tester.testTextInput.updateEditingValue(_dictationValue(command));
      await tester.pump();

      expect(reviewCount, 1);
      expect(harness.terminalOutput, isEmpty);
      await disposeTerminalInputHarness(tester, harness);
    },
    variant: _mobilePlatforms,
  );

  for (final preservesBackspaceBuffer in [false, true]) {
    testWidgets(
      'iOS dictation ${preservesBackspaceBuffer ? 'preserves' : 'replaces'} the backspace buffer',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);
        tester.testTextInput.updateEditingValue(_dictationValue('${_marker}x'));
        await tester.pump();
        tester.testTextInput.updateEditingValue(_dictationValue(_marker));
        await tester.pump();

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        final backspaceBuffer = client.currentTextEditingValue!.text;
        expect(
          backspaceBuffer.length,
          _marker.length + terminalIosBackspaceRepeatRunwayLength,
        );
        harness.terminalOutput.clear();

        const phrase = 'Explain this code.';
        final prefix = preservesBackspaceBuffer ? backspaceBuffer : '';
        tester.testTextInput.updateEditingValue(
          _dictationValue('$prefix$phrase', composing: true),
        );
        await tester.pump();
        expect(harness.terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          _dictationValue('$prefix$phrase'),
        );
        await tester.pump();
        expect(harness.terminalOutput.join(), phrase);
        expect(
          client.currentTextEditingValue,
          _dictationValue('$_marker$phrase'),
        );

        // Backspace must delete the final dictated character, with no hidden
        // buffer characters forwarded to the remote terminal.
        final shortened = phrase.substring(0, phrase.length - 1);
        tester.testTextInput.updateEditingValue(
          _dictationValue('$_marker$shortened'),
        );
        await tester.pump();
        expect(terminalTextFromEvents(harness.terminalOutput), shortened);

        await disposeTerminalInputHarness(tester, harness);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
