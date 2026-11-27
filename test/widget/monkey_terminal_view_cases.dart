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
}
