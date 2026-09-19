import 'terminal_auto_connect_cases.dart';
import 'terminal_path_verifier_cases.dart';
import 'terminal_screen_layout_cases.dart';
import 'terminal_screen_scroll_policy_cases.dart';
import 'terminal_screen_selection_cases.dart';
import 'terminal_screen_zoom_cases.dart';

void main() {
  registerTerminalAutoConnectTests();
  registerTerminalPathVerifierTests();
  registerTerminalScreenSelectionTests();
  registerTerminalScreenLayoutTests();
  registerTerminalScreenScrollPolicyTests();
  registerTerminalScreenZoomTests();
}
