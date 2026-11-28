import 'monkey_terminal_gesture_handler_cases.dart';
import 'monkey_terminal_scroll_gesture_handler_cases.dart';
import 'monkey_terminal_view_touch_scroll_cases.dart';
import 'terminal_pinch_zoom_gesture_handler_cases.dart';
import 'xterm_infinite_scroll_view_cases.dart';

/// Registers tests from monkey_terminal_gestures_test.dart.
void registerWidgetMonkeyTerminalGesturesTests() {
  registerMonkeyTerminalGestureHandlerTests();
  registerMonkeyTerminalScrollGestureHandlerTests();
  registerMonkeyTerminalViewTouchScrollTests();
  registerTerminalPinchZoomGestureHandlerTests();
  registerXtermInfiniteScrollViewTests();
}
