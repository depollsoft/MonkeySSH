import 'monkey_terminal_demo_replay_cases.dart';
import 'monkey_terminal_graphics_cases.dart';
import 'monkey_terminal_painter_lifetime_cases.dart';

/// Registers tests from monkey_terminal_graphics_test.dart.
void registerWidgetMonkeyTerminalGraphicsTests() {
  registerMonkeyTerminalGraphicsTests();
  registerMonkeyTerminalDemoReplayTests();
  registerMonkeyTerminalPainterLifetimeTests();
}
