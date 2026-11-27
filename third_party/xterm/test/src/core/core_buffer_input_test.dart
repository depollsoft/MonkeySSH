import '../base/observable_cases.dart';
import '../terminal_cases.dart';
import '../terminal_input_cases.dart';
import '../utils/byte_consumer_cases.dart';
import '../utils/circular_buffer_cases.dart';
import '../utils/grapheme_cases.dart';
import '../xterm_cases.dart';
import 'buffer/buffer_cases.dart';
import 'buffer/line_cases.dart';
import 'buffer/range_block_cases.dart';
import 'buffer/range_line_cases.dart';
import 'buffer/scroll_region_cases.dart';
import 'buffer/segment_cases.dart';
import 'input/handler_cases.dart';
import 'input/keytab/keytab_cases.dart';
import 'input/keytab/keytab_parse_cases.dart';
import 'input/kitty_keyboard_cases.dart';
import 'mouse/reporter_cases.dart';

void main() {
  registerXtermSmokeTests();
  registerObservableTests();
  registerBufferTests();
  registerBufferLineTests();
  registerRangeBlockTests();
  registerRangeLineTests();
  registerScrollRegionTests();
  registerSegmentTests();
  registerInputHandlerTests();
  registerKeytabParseTests();
  registerKeytabTests();
  registerKittyKeyboardTests();
  registerMouseReporterTests();
  registerTerminalInputTests();
  registerTerminalTests();
  registerByteConsumerTests();
  registerCircularBufferTests();
  registerGraphemeUtilsTests();
}
