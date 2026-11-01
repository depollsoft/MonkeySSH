import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/mouse/mode.dart';

abstract class TerminalState {
  int get viewWidth;

  int get viewHeight;

  CursorStyle get cursor;

  bool get reflowEnabled;

  /* Modes */

  bool get insertMode;

  bool get lineFeedMode;

  /* DEC Private modes */

  bool get cursorKeysMode;

  /// Whether DECANM is enabled. When false, keytab input uses VT52 mappings.
  bool get ansiMode;

  bool get reverseDisplayMode;

  bool get originMode;

  bool get autoWrapMode;

  MouseMode get mouseMode;

  MouseReportMode get mouseReportMode;

  bool get cursorBlinkMode;

  bool get cursorVisibleMode;

  bool get appKeypadMode;

  bool get reportFocusMode;

  bool get altBufferMouseScrollMode;

  bool get bracketedPasteMode;

  /// Whether DEC private mode 2027 is set: a code point that continues the
  /// grapheme cluster in the cell before the cursor joins that cell, which
  /// may widen or narrow, as in Ghostty.
  bool get graphemeClusterMode;
}
