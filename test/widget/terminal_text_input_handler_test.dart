// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

import '../helpers/terminal_input_harness.dart';
import '../helpers/terminal_input_helpers.dart';

const _deleteDetectionMarker = '\u200B\u200B';
const _terminalShiftEnterNewlineInput = '\n';

typedef _LoggedEditingState = ({
  String text,
  int selectionBase,
  int selectionExtent,
  int composingBase,
  int composingExtent,
});

typedef _ComparisonResult = ({
  _LoggedEditingState finalState,
  List<_LoggedEditingState> echoedStates,
});

TextEditingValue _editingValue(
  String userText, {
  required int selectionOffset,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: '$_deleteDetectionMarker$userText',
  selection: TextSelection.collapsed(
    offset: _deleteDetectionMarker.length + selectionOffset,
  ),
  composing: composing == TextRange.empty
      ? TextRange.empty
      : TextRange(
          start: _deleteDetectionMarker.length + composing.start,
          end: _deleteDetectionMarker.length + composing.end,
        ),
);

String _terminalKeyOutput(
  TerminalKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final output = <String>[];
  Terminal(onOutput: output.add)
      .keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
  return output.join();
}

int _normalizeOffsetToUserSpace(int offset, int prefixLength, int maxLength) {
  if (offset < 0) {
    return offset;
  }
  final normalized = offset - prefixLength;
  if (normalized < 0) {
    return 0;
  }
  if (normalized > maxLength) {
    return maxLength;
  }
  return normalized;
}

_LoggedEditingState _loggedStateFromTextEditingValue(TextEditingValue value) =>
    (
      text: value.text,
      selectionBase: value.selection.baseOffset,
      selectionExtent: value.selection.extentOffset,
      composingBase: value.composing.start,
      composingExtent: value.composing.end,
    );

TextEditingValue _terminalEditingValueFromUserValue(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final selection = value.selection.isValid
      ? TextSelection(
          baseOffset: prefixLength + value.selection.baseOffset,
          extentOffset: prefixLength + value.selection.extentOffset,
          affinity: value.selection.affinity,
          isDirectional: value.selection.isDirectional,
        )
      : value.selection;
  final composing = value.composing.isValid && !value.composing.isCollapsed
      ? TextRange(
          start: prefixLength + value.composing.start,
          end: prefixLength + value.composing.end,
        )
      : value.composing;
  return TextEditingValue(
    text: '$_deleteDetectionMarker${value.text}',
    selection: selection,
    composing: composing,
  );
}

_LoggedEditingState _loggedStateFromSetEditingStateCall(
  MethodCall call, {
  bool stripTerminalMarker = false,
}) {
  final arguments = call.arguments as Map<dynamic, dynamic>;
  var text = arguments['text'] as String? ?? '';
  var selectionBase = arguments['selectionBase'] as int? ?? -1;
  var selectionExtent = arguments['selectionExtent'] as int? ?? -1;
  var composingBase = arguments['composingBase'] as int? ?? -1;
  var composingExtent = arguments['composingExtent'] as int? ?? -1;

  if (stripTerminalMarker && text.startsWith(_deleteDetectionMarker)) {
    const prefixLength = _deleteDetectionMarker.length;
    text = text.substring(prefixLength);
    selectionBase = _normalizeOffsetToUserSpace(
      selectionBase,
      prefixLength,
      text.length,
    );
    selectionExtent = _normalizeOffsetToUserSpace(
      selectionExtent,
      prefixLength,
      text.length,
    );
    if (composingBase >= 0) {
      composingBase = _normalizeOffsetToUserSpace(
        composingBase,
        prefixLength,
        text.length,
      );
      composingExtent = _normalizeOffsetToUserSpace(
        composingExtent,
        prefixLength,
        text.length,
      );
    }
  }

  return (
    text: text,
    selectionBase: selectionBase,
    selectionExtent: selectionExtent,
    composingBase: composingBase,
    composingExtent: composingExtent,
  );
}

List<_LoggedEditingState> _setEditingStateStates(
  Iterable<MethodCall> log, {
  bool stripTerminalMarker = false,
}) => log
    .where((call) => call.method == 'TextInput.setEditingState')
    .map(
      (call) => _loggedStateFromSetEditingStateCall(
        call,
        stripTerminalMarker: stripTerminalMarker,
      ),
    )
    .toList(growable: false);

_LoggedEditingState _loggedTerminalClientState(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final text = value.text.startsWith(_deleteDetectionMarker)
      ? value.text.substring(prefixLength)
      : value.text;
  return (
    text: text,
    selectionBase: _normalizeOffsetToUserSpace(
      value.selection.baseOffset,
      prefixLength,
      text.length,
    ),
    selectionExtent: _normalizeOffsetToUserSpace(
      value.selection.extentOffset,
      prefixLength,
      text.length,
    ),
    composingBase: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.start,
            prefixLength,
            text.length,
          )
        : -1,
    composingExtent: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.end,
            prefixLength,
            text.length,
          )
        : -1,
  );
}

Future<_ComparisonResult> _runTextFieldSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextField(controller: controller, focusNode: focusNode),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
  }

  final result = (
    finalState: _loggedStateFromTextEditingValue(controller.value),
    echoedStates: _setEditingStateStates(tester.testTextInput.log),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  controller.dispose();
  focusNode.dispose();
  return result;
}

Future<_ComparisonResult> _runTerminalSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final terminal = Terminal();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          manageFocus: false,
          child: Focus(focusNode: focusNode, child: const SizedBox.expand()),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(
      _terminalEditingValueFromUserValue(value),
    );
    await tester.pump();
  }

  final client =
      tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
  final result = (
    finalState: _loggedTerminalClientState(client.currentTextEditingValue!),
    echoedStates: _setEditingStateStates(
      tester.testTextInput.log,
      stripTerminalMarker: true,
    ),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  focusNode.dispose();
  return result;
}

TextInputClient _terminalTextInputClient(WidgetTester tester) =>
    tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;

Map<dynamic, dynamic> _textInputConfigurationFromCall(MethodCall call) {
  final arguments = call.arguments;
  if (call.method == 'TextInput.setClient') {
    return (arguments as List<dynamic>)[1]! as Map<dynamic, dynamic>;
  }
  return arguments as Map<dynamic, dynamic>;
}

Map<dynamic, dynamic> _latestTextInputSetClientConfiguration(
  WidgetTester tester,
) {
  final call = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  return _textInputConfigurationFromCall(call);
}

void main() {
  group('terminalTextLooksLikeSensitiveInputPrompt', () {
    test('detects common password-like prompts', () {
      const prompts = [
        'Password:',
        '[sudo] password for depoll:',
        'root@example.com\'s password: ',
        'Enter passphrase for key \'/Users/depoll/.ssh/id_ed25519\':',
        'PIN:',
        'Verification code:',
        'One-time password:',
        'Authentication code:',
      ];

      for (final prompt in prompts) {
        expect(
          terminalTextLooksLikeSensitiveInputPrompt(prompt),
          isTrue,
          reason: prompt,
        );
      }
    });

    test('only checks the prompt-like text before the cursor', () {
      expect(
        terminalTextLooksLikeSensitiveInputPrompt(
          'Last login: Sun May 3\n\x1B[31mPassword:\x1B[0m ',
        ),
        isTrue,
      );
      expect(
        terminalTextLooksLikeSensitiveInputPrompt('Password:\n\$ '),
        isFalse,
      );
    });

    test('ignores non-secret password-related output', () {
      const lines = [
        'Password requirements:',
        'Password policy:',
        'Password incorrect:',
        'Password reset:',
        'passwordless login enabled:',
        'Last login:',
        'Enter a username:',
        null,
      ];

      for (final line in lines) {
        expect(
          terminalTextLooksLikeSensitiveInputPrompt(line),
          isFalse,
          reason: '$line',
        );
      }
    });
  });

  group('TerminalTextInputHandler', () {
    testWidgets('restarts the active IME connection for sensitive input', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      Widget buildHarness({required bool sensitiveInput}) => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            deleteDetection: true,
            sensitiveInput: sensitiveInput,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(buildHarness(sensitiveInput: false));
      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.log.clear();
      await tester.pumpWidget(buildHarness(sensitiveInput: true));
      await tester.pump();

      final configuration = _latestTextInputSetClientConfiguration(tester);
      final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.clearClient',
        ),
        hasLength(1),
      );
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.updateConfig',
        ),
        isEmpty,
      );
      expect(inputType['name'], 'TextInputType.text');
      expect(configuration['obscureText'], isTrue);
      expect(configuration['enableSuggestions'], isFalse);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      focusNode.dispose();
    });

    testWidgets(
      'external prompt output does not reconnect the IME client before keyboard input',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
        );
        final controller = harness.controller;

        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'external prompt output resets IME context for the next fresh swipe '
      'after keyboard input',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        tester.testTextInput.updateEditingValue(
          _editingValue('echo ready', selectionOffset: 'echo ready'.length),
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );

        await commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'accelerates iOS hardware backspace repeat and suppresses native repeats',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);
          final backspaceOutput = _terminalKeyOutput(TerminalKey.backspace);
          int backspaceCount() => harness.terminalOutput
              .where((value) => value == backspaceOutput)
              .length;

          await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
          await tester.pump();

          expect(backspaceCount(), 1);

          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
          await tester.pump();

          expect(backspaceCount(), 1);

          await tester.pump(terminalIosHardwareKeyRepeatStartDelay);

          expect(backspaceCount(), 2);

          await tester.pump(terminalIosHardwareKeyRepeatInterval);

          expect(backspaceCount(), 3);

          await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
          await tester.pump();
          final countAfterKeyUp = backspaceCount();

          await tester.pump(
            Duration(
              milliseconds:
                  terminalIosHardwareKeyRepeatInterval.inMilliseconds * 3,
            ),
          );

          expect(backspaceCount(), countAfterKeyUp);

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('touch-driven caret moves clear the IME buffer', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      await tester.tap(find.byType(TerminalTextInputHandler));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
      );
      await tester.pump();

      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'echo teh world',
          initialCursorOffset: 'echo teh world'.length,
        ),
        (text: 'echo teh world', cursorOffset: 'echo teh '.length),
      );
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'typing after a touch-driven caret move inserts from a fresh IME buffer',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput..clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('X', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo Xteh world', cursorOffset: 'echo X'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'touch-driven caret moves clear the IME buffer after a replacement selection collapses elsewhere',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo the world',
            initialCursorOffset: 'echo the'.length,
          ),
          (text: 'echo the world', cursorOffset: 'echo '.length),
        );
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('hardware Shift+Enter sends legacy LF newline', (tester) async {
      final harness = await pumpTerminalInputHarness(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('hardware Alt+Enter sends meta-sends-escape CR', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), '\x1b\r');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'virtual Enter ignores stale soft-keyboard Shift and submits via IME',
      (tester) async {
        const virtualShiftKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 59,
        );
        const virtualEnterKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 66,
        );

        // Production terminal screen uses manageFocus: false and routes keys
        // through the global HardwareKeyboard handler.
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
        );
        expect(tester.testTextInput.isVisible, isTrue);

        // Soft keyboards often leave Shift pressed after capitalization while
        // also emitting a synthetic Enter key event. That used to encode as
        // alternate-enter (newline) in Codex/Cursor instead of submit.
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: virtualShiftKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, isEmpty);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          _terminalKeyOutput(TerminalKey.enter),
        );

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: virtualShiftKey,
            timeStamp: Duration.zero,
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'virtual Enter with toolbar Shift still sends LF newline via IME',
      (tester) async {
        const virtualEnterKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 66,
        );
        var shiftActive = true;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue('C', selectionOffset: 1),
        );
        await tester.pump();
        harness.terminalOutput.clear();

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, isEmpty);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'toolbar Shift applies to non-virtual Enter on the hardware path',
      (tester) async {
        var shiftActive = true;
        final harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );

        // Standard HID Enter (not platform-plane / virtual). Soft and external
        // keyboards both use this on some devices; toolbar Shift must still
        // apply because HardwareKeyboard does not mirror toolbar modifiers.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'toolbar Alt applies to non-virtual Enter on the hardware path',
      (tester) async {
        var altActive = true;
        final harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: altActive, shift: false),
          consumeTerminalKeyModifiers: () => altActive = false,
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(harness.terminalOutput.join(), '\x1b\r');
        expect(altActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('virtual shifted text bypasses Kitty hardware key encoding', (
      tester,
    ) async {
      const virtualShiftKey = PhysicalKeyboardKey(
        LogicalKeyboardKey.androidPlane + 59,
      );
      const virtualCommaKey = PhysicalKeyboardKey(
        LogicalKeyboardKey.androidPlane + 55,
      );

      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        initialTerminalOutput: '\x1b[>9u',
      );

      expect(tester.testTextInput.isVisible, isTrue);

      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: virtualShiftKey,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: virtualCommaKey,
          character: '<',
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: virtualCommaKey,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: virtualShiftKey,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump();

      expect(harness.terminalOutput, isEmpty);

      tester.testTextInput.updateEditingValue(
        _editingValue('<', selectionOffset: 1),
      );
      await tester.pump();

      expect(harness.terminalOutput, <String>['<']);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('Android IME HID controls bypass Kitty hardware key encoding', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);

      TerminalInputHarness? harness;
      try {
        harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
        );

        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        harness.terminalOutput.clear();

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyRepeatEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, <String>['\x7f', '\x7f']);

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '${_terminalKeyOutput(TerminalKey.backspace)}'
          '${_terminalKeyOutput(TerminalKey.backspace)}',
        );

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            timeStamp: Duration.zero,
          ),
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        tester.view.resetViewInsets();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'Android external HID Backspace keeps Kitty encoding with visible IME',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>9u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.view.viewInsets.bottom, greaterThan(0));

          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.shiftLeft,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.shiftLeft,
              physicalKey: PhysicalKeyboardKey.shiftLeft,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.shiftLeft,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.shiftLeft,
              physicalKey: PhysicalKeyboardKey.shiftLeft,
              timeStamp: Duration.zero,
            ),
          );
          await tester.pump();

          expect(terminalOutput.join(), contains('\x1b[127;2u'));
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          tester.view.resetViewInsets();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'physical Backspace consumes a toolbar modifier with visible IME',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        var ctrlActive = true;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>1u',
            resolveTerminalKeyModifiers: () =>
                (ctrl: ctrlActive, alt: false, shift: false),
            consumeTerminalKeyModifiers: () => ctrlActive = false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x1b[127;5u']);
          expect(ctrlActive, isFalse);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          tester.view.resetViewInsets();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('replacing focus node closes an unfocused input connection', (
      tester,
    ) async {
      final terminal = Terminal();
      final firstFocusNode = FocusNode();
      final replacementFocusNode = FocusNode();

      Widget buildHandler(FocusNode focusNode) => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            deleteDetection: true,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(buildHandler(firstFocusNode));
      firstFocusNode.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.pumpWidget(buildHandler(replacementFocusNode));
      await tester.pump();

      expect(replacementFocusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);

      firstFocusNode.dispose();
      replacementFocusNode.dispose();
    });

    testWidgets('Android composing IME Backspace sends raw DEL immediately', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = TerminalTextInputHandlerController();
      TerminalInputHarness? harness;

      try {
        harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
          controller: controller,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue(
            'CC',
            selectionOffset: 2,
            composing: const TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        terminalOutput.clear();

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.press,
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x7f']);

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'C',
            selectionOffset: 1,
            composing: const TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x7f']);

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.release,
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('toolbar modifier applies to composing Android IME Backspace', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var ctrlActive = true;
      final controller = TerminalTextInputHandlerController();
      TerminalInputHarness? harness;

      try {
        harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
          resolveTerminalKeyModifiers: () =>
              (ctrl: ctrlActive, alt: false, shift: false),
          consumeTerminalKeyModifiers: () => ctrlActive = false,
          controller: controller,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue(
            'CC',
            selectionOffset: 2,
            composing: const TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        terminalOutput.clear();

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.press,
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x1b[127;5u']);
        expect(ctrlActive, isFalse);

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'C',
            selectionOffset: 1,
            composing: const TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x1b[127;5u']);

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.release,
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'toolbar modifier keeps Android IME Backspace on hardware path',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        var ctrlActive = true;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>11u',
            resolveTerminalKeyModifiers: () =>
                (ctrl: ctrlActive, alt: false, shift: false),
            consumeTerminalKeyModifiers: () => ctrlActive = false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          tester.testTextInput.updateEditingValue(
            _editingValue('CC', selectionOffset: 2),
          );
          await tester.pump();
          terminalOutput.clear();

          controller
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.press,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.repeat,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.release,
            );
          await tester.pump();

          expect(terminalOutput, <String>[
            '\x1b[127;5u',
            '\x1b[127;5:2u',
            '\x1b[127;5:3u',
          ]);
          expect(ctrlActive, isFalse);

          tester.testTextInput.updateEditingValue(
            _editingValue('', selectionOffset: 0),
          );
          await tester.pump();

          expect(terminalOutput, <String>[
            '\x1b[127;5u',
            '\x1b[127;5:2u',
            '\x1b[127;5:3u',
          ]);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('physical shifted text keeps Kitty hardware key encoding', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add)
        ..write('\x1b[>9u');
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              manageFocus: false,
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: PhysicalKeyboardKey.comma,
          character: '<',
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: PhysicalKeyboardKey.comma,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), contains('\x1b[44;2u'));

      focusNode.dispose();
    });

    testWidgets('keeps ctrl combos working while IME composition is active', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Ba',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), '\u0003');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('opens the keyboard after a touch tap', (tester) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'opens the keyboard after a touch tap when focus keyboard is disabled',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                showKeyboardOnFocus: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not reopen the keyboard when the platform closes it while focused',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.log.clear();
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .connectionClosed();
        await tester.pump();

        expect(harness.focusNode.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('does not open the keyboard after a touch long press', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      final gesture = await tester.createGesture();
      await gesture.down(target, timeStamp: const Duration(seconds: 1));
      await tester.pump(terminalKeyboardTapLongPressTimeout);
      await gesture.up(
        timeStamp:
            const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
      );
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'keeps the keyboard visible when touch becomes selection intent',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final gesture = await tester.createGesture();
        await gesture.down(target, timeStamp: const Duration(seconds: 1));
        await tester.pump(terminalKeyboardTapLongPressTimeout);

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await gesture.up(
          timeStamp:
              const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
        );
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'keeps the keyboard visible when a held touch starts scrolling',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final gesture = await tester.createGesture();
        await gesture.down(target, timeStamp: const Duration(seconds: 1));
        await tester.pump();
        await gesture.moveBy(
          const Offset(0, 80),
          timeStamp: const Duration(milliseconds: 1100),
        );
        await tester.pump(terminalKeyboardTapLongPressTimeout);

        expect(tester.testTextInput.isVisible, isTrue);

        await gesture.up(
          timeStamp:
              const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
        );
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('keeps the keyboard visible during held multitouch', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      final firstGesture = await tester.createGesture();
      final secondGesture = await tester.createGesture();
      await firstGesture.down(target, timeStamp: const Duration(seconds: 1));
      await tester.pump();
      await secondGesture.down(
        target + const Offset(60, 0),
        timeStamp: const Duration(milliseconds: 1010),
      );
      await tester.pump(terminalKeyboardTapLongPressTimeout);

      expect(tester.testTextInput.isVisible, isTrue);

      await secondGesture.up(timeStamp: const Duration(milliseconds: 1510));
      await firstGesture.up(timeStamp: const Duration(milliseconds: 1520));
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('does not open the keyboard after a touch drag', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('does not open the keyboard after a touch tap when read only', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        readOnly: true,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not open the keyboard after a touch tap when tapToShowKeyboard '
      'is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        // The handler uses autofocus: true, which triggers _onFocusChange.
        // With tapToShowKeyboard off, the connection is attached but not shown.
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('does not reopen the keyboard on focus restoration when '
        'tapToShowKeyboard is false', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final outerFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outerFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    tapToShowKeyboard: false,
                    child: const SizedBox.expand(
                      key: ValueKey('terminal-child'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      // Move focus away from the terminal.
      outerFocusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Restore focus to the terminal (simulates popup menu close or
      // programmatic focus restore).  Keyboard must stay hidden.
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
      outerFocusNode.dispose();
    });

    testWidgets(
      'requestKeyboard still shows keyboard when tapToShowKeyboard is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();
        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        // Explicit requestKeyboard (the toolbar button path) must always work.
        controller.requestKeyboard();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets('routes hardware keys when the child owns focus', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final otherFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: otherFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other-focus-target'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    manageFocus: false,
                    child: Focus(
                      focusNode: focusNode,
                      child: const SizedBox.expand(
                        key: ValueKey('terminal-focus-owner'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.arrowLeft));

      terminalOutput.clear();
      otherFocusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(terminalOutput, isEmpty);

      focusNode.dispose();
      otherFocusNode.dispose();
    });

    testWidgets('routes hardware paste shortcuts through the paste callback', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      var pasteCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onPasteText: () => pasteCount++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(pasteCount, 1);
      expect(terminalOutput, isEmpty);

      focusNode.dispose();
    });

    testWidgets('consumes composing hardware keys when the child owns focus', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              manageFocus: false,
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(
                  key: ValueKey('terminal-focus-owner'),
                ),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue(
          'hello',
          selectionOffset: 'hello'.length,
          composing: const TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();

      final handledKeyDown = await tester.sendKeyDownEvent(
        LogicalKeyboardKey.arrowLeft,
      );
      final handledKeyUp = await tester.sendKeyUpEvent(
        LogicalKeyboardKey.arrowLeft,
      );
      await tester.pump();

      expect(terminalOutput, isEmpty);
      expect(handledKeyDown, isTrue);
      expect(handledKeyUp, isTrue);

      focusNode.dispose();
    });

    testWidgets('does not open the keyboard after a suppressed touch tap', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      harness.controller.suppressNextTouchKeyboardRequest();
      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tapAt(target);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not open the keyboard after a multitouch gesture when the last finger stays still',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.hide();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        final origin =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final firstGesture = await tester.createGesture(pointer: 1);
        await firstGesture.down(origin);
        await tester.pump();

        final secondGesture = await tester.createGesture(pointer: 2);
        await secondGesture.down(origin + const Offset(20, 0));
        await tester.pump();
        await secondGesture.moveBy(const Offset(0, 80));
        await tester.pump();
        await secondGesture.up();
        await tester.pump();
        await firstGesture.up();
        await tester.pump();

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );
  });

  group('shouldRequestKeyboardForTerminalPointerUp', () {
    test('requests the keyboard for a tap-like first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard after touch movement beyond tap slop', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: true,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard for additional touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 2,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard after a multitouch gesture sequence', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('still requests the keyboard for non-touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.mouse,
          activeTouchPointers: 0,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('never requests the keyboard when input is read only', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: true,
        ),
        isFalse,
      );
    });

    test('requests the keyboard just before touch reaches long press', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
          touchPressDuration:
              terminalKeyboardTapLongPressTimeout -
              const Duration(microseconds: 1),
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard when touch duration reaches long press', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
          touchPressDuration: terminalKeyboardTapLongPressTimeout,
        ),
        isFalse,
      );
    });
  });

  group('TerminalTextInputHandler compared with TextField', () {
    testWidgets(
      'matches TextField user state for collapsed caret moves while issuing one terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state when a replacement selection collapses elsewhere',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection(baseOffset: 5, extentOffset: 8),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state after deleting newer text, replacing earlier text, and moving again',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        // The deletion-triggered buffer reset in step 2 first echoes the
        // cleared IME state, then the later collapsed-caret move resyncs the
        // current user state.
        expect(terminalResult.echoedStates, [
          (
            text: '',
            selectionBase: 0,
            selectionExtent: 0,
            composingBase: -1,
            composingExtent: -1,
          ),
          textFieldResult.finalState,
        ]);
      },
    );

    testWidgets(
      'matches TextField replacement finalization without an extra terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, isEmpty);
      },
    );
  });
}
