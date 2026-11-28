import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/xterm.dart';

import 'monkey_terminal_view_layout_cases.dart';
import 'monkey_terminal_view_resize_cases.dart';
import 'monkey_terminal_view_selection_cases.dart';
import 'terminal_text_style_cases.dart';

/// Registers tests from monkey_terminal_view_test.dart.
void registerWidgetMonkeyTerminalViewTests() {
  registerMonkeyTerminalViewLayoutTests();
  registerMonkeyTerminalViewResizeTests();
  registerMonkeyTerminalViewSelectionTests();
  registerTerminalTextStyleTests();

  group('monkey_terminal_view_focus', () {
    testWidgets('key handling tolerates a detached focus node', (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      final detachedNode = FocusNode();
      addTearDown(detachedNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
        ),
      );
      final listener = tester.widget<CustomKeyboardListener>(
        find.byType(CustomKeyboardListener),
      );

      expect(detachedNode.context, isNull);
      expect(
        listener.onKeyEvent(
          detachedNode,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.handled,
      );
      expect(output, ['\r']);
    });

    testWidgets('attached focus still handles shortcuts before Kitty input', (
      tester,
    ) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[=11uhello');
      final controller = TerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MonkeyTerminalView(
            terminal,
            controller: controller,
            autofocus: true,
            hardwareKeyboardOnly: true,
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.f6): SelectAllTextIntent(
                SelectionChangedCause.keyboard,
              ),
            },
          ),
        ),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.f6);
      expect(controller.selection, isNotNull);
      expect(output, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f6);
    });
  });
}
