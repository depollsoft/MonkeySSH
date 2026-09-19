import 'terminal_port_forwards_sheet_cases.dart';
import 'tmux_alert_tracker_cases.dart';
import 'tmux_window_loader_cases.dart';
import 'tmux_window_navigator_cases.dart';

void main() {
  registerTmuxWindowLoaderTests();
  registerTmuxAlertTrackerTests();
  registerTmuxWindowNavigatorTests();
  registerTerminalPortForwardsSheetTests();
}
