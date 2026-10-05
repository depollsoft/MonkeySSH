// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

typedef TerminalInputHarness = ({
  List<String> terminalOutput,
  Terminal terminal,
  FocusNode focusNode,
  TerminalTextInputHandlerController controller,
});

Future<TerminalInputHarness> pumpTerminalInputHarness(
  WidgetTester tester, {
  bool attachController = true,
  TextEditingValue? initialEditingValue,
  String? initialTerminalOutput,
  bool readOnly = false,
  bool tapToShowKeyboard = true,
  bool sensitiveInput = false,
  FutureOr<void> Function()? onPasteText,
  TerminalTextInputReviewCallback? onReviewInsertedText,
  String Function()? resolveTextBeforeCursor,
  TerminalKeyModifierResolver? resolveTerminalKeyModifiers,
  VoidCallback? consumeTerminalKeyModifiers,
  TerminalTextInputModifierApplier? applyTerminalTextInputModifiers,
  ValueGetter<bool>? hasActiveToolbarModifier,
  TerminalTextInputHandlerController? controller,
}) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(onOutput: terminalOutput.add);
  if (initialTerminalOutput != null) {
    terminal.write(initialTerminalOutput);
  }
  final focusNode = FocusNode();
  final effectiveController =
      controller ?? TerminalTextInputHandlerController();

  // Production wraps the handler in an external Focus (the terminal view).
  final body = Focus(
    focusNode: focusNode,
    child: TerminalTextInputHandler(
      terminal: terminal,
      focusNode: focusNode,
      controller: attachController ? effectiveController : null,
      readOnly: readOnly,
      tapToShowKeyboard: tapToShowKeyboard,
      sensitiveInput: sensitiveInput,
      onPasteText: onPasteText,
      onReviewInsertedText: onReviewInsertedText,
      resolveTextBeforeCursor: resolveTextBeforeCursor,
      resolveTerminalKeyModifiers: resolveTerminalKeyModifiers,
      consumeTerminalKeyModifiers: consumeTerminalKeyModifiers,
      applyTerminalTextInputModifiers: applyTerminalTextInputModifiers,
      hasActiveToolbarModifier: hasActiveToolbarModifier,
      child: const SizedBox.expand(),
    ),
  );

  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

  focusNode.requestFocus();
  await tester.pump();

  if (initialEditingValue != null) {
    tester.testTextInput.updateEditingValue(initialEditingValue);
    await tester.pump();
  }

  return (
    terminalOutput: terminalOutput,
    terminal: terminal,
    focusNode: focusNode,
    controller: effectiveController,
  );
}

Future<void> disposeTerminalInputHarness(
  WidgetTester tester,
  TerminalInputHarness harness,
) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  harness.focusNode.dispose();
}
