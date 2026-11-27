import 'cursor_cases.dart';
import 'escape/parser_cases.dart';
import 'escape/reset_cases.dart';
import 'grapheme_cluster_cases.dart';
import 'grapheme_cluster_parity_cases.dart';
import 'graphics_viewport_index_cases.dart';
import 'mode_report_cases.dart';
import 'rect_checksum_cases.dart';
import 'reflow_cases.dart';
import 'semantic_prompt_cases.dart';
import 'semantic_prompt_parity_cases.dart';
import 'tabs_cases.dart';
import 'terminal_state_regression_cases.dart';

void main() {
  registerCursorTests();
  registerEscapeParserTests();
  registerEscapeResetTests();
  registerGraphemeClusterTests();
  registerGraphemeClusterParityTests();
  registerGraphicsViewportIndexTests();
  registerModeReportTests();
  registerRectChecksumTests();
  registerReflowTests();
  registerSemanticPromptTests();
  registerSemanticPromptParityTests();
  registerTabsTests();
  registerTerminalStateRegressionTests();
}
