import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/mouse/mode.dart';

abstract class EscapeHandler {
  void writeChar(int char);

  /* SBC */

  void bell();

  void backspaceReturn();

  void tab();

  /// `CSI Ps I` Cursor Horizontal Forward Tabulation (CHT): advance the cursor
  /// by [amount] tab stops.
  void cursorForwardTab(int amount);

  /// `CSI Ps Z` Cursor Backward Tabulation (CBT): move the cursor back by
  /// [amount] tab stops.
  void cursorBackwardTab(int amount);

  void lineFeed();

  void carriageReturn();

  void shiftOut();

  void shiftIn();

  void unknownSBC(int char);

  /* ANSI sequence */

  void saveCursor();

  void restoreCursor();

  void index();

  void nextLine();

  void setTapStop();

  void reverseIndex();

  void designateCharset(int charset, int name);

  /// `ESC c` Reset to Initial State (RIS).
  ///
  /// Returns the terminal to its power-up state: main screen, empty screen and
  /// scrollback, home cursor, default rendition, character sets, tab stops,
  /// margins and modes.
  void fullReset();

  /// `CSI ! p` Soft Terminal Reset (DECSTR).
  ///
  /// Resets the rendition, character sets, saved cursor, margins and the modes
  /// DECSTR owns. The screen contents, the cursor position and the tab stops
  /// are left alone.
  void softReset();

  void unkownEscape(int char);

  /* CSI */

  void repeatPreviousCharacter(int n);

  void setCursor(int x, int y);

  void setCursorX(int x);

  void setCursorY(int y);

  void sendPrimaryDeviceAttributes();

  void clearTabStopUnderCursor();

  void clearAllTabStops();

  void moveCursorX(int offset);

  void moveCursorY(int n);

  void sendSecondaryDeviceAttributes();

  void sendTertiaryDeviceAttributes();

  void sendTerminalVersion();

  /// Answers DECRQM for an ANSI mode (`CSI Ps $ p`).
  void sendModeReport(int mode);

  /// Answers XTGETTCAP (`DCS + q <hex> ST`) for the given hex-encoded
  /// terminfo/termcap capability names.
  void sendTermcapReport(List<String> capabilities);

  /// Answers DECRQSS (`DCS $ q <Pt> ST`) for the control function identified by
  /// [request] (the intermediate/final bytes, e.g. `r`, `m`, ` q`).
  void sendStatusStringReport(String request);

  void sendOperatingStatus();

  void sendCursorPosition();

  void setMargins(int i, [int? bottom]);

  void cursorNextLine(int amount);

  void cursorPrecedingLine(int amount);

  void eraseDisplayBelow();

  void eraseDisplayAbove();

  void eraseDisplay();

  void eraseScrollbackOnly();

  void eraseLineRight();

  void eraseLineLeft();

  void eraseLine();

  void insertLines(int amount);

  void deleteLines(int amount);

  void deleteChars(int amount);

  void scrollUp(int amount);

  void scrollDown(int amount);

  void eraseChars(int amount);

  void insertBlankChars(int amount);

  void unknownCSI(int finalByte);

  /* Modes */

  void setInsertMode(bool enabled);

  void setLineFeedMode(bool enabled);

  void setUnknownMode(int mode, bool enabled);

  /* DEC Private modes */

  void setCursorKeysMode(bool enabled);

  void setAnsiMode(bool enabled);

  void setReverseDisplayMode(bool enabled);

  void setOriginMode(bool enabled);

  void setColumnMode(bool enabled);

  void setAutoWrapMode(bool enabled);

  void setMouseMode(MouseMode mode);

  void setCursorBlinkMode(bool enabled);

  void setCursorVisibleMode(bool enabled);

  void useAltBuffer();

  void useMainBuffer();

  void clearAltBuffer();

  void setAppKeypadMode(bool enabled);

  void setReportFocusMode(bool enabled);

  void setMouseReportMode(MouseReportMode mode);

  void setAltBufferMouseScrollMode(bool enabled);

  void setBracketedPasteMode(bool enabled);

  void setUnknownDecMode(int mode, bool enabled);

  void setKittyKeyboardFlags(int flags, int mode);

  void pushKittyKeyboardFlags(int flags);

  void popKittyKeyboardFlags(int count);

  void sendKittyKeyboardFlags();

  void resize(int cols, int rows);

  void resizeFromHost(int cols, int rows);

  void sendSize();

  /* Select Graphic Rendition (SGR) */

  void resetCursorStyle();

  void setCursorBold();

  void setCursorFaint();

  void setCursorItalic();

  void setCursorUnderline();

  /// Sets a specific underline [style] (single, double, curly, dotted or
  /// dashed). [UnderlineStyle.none] removes the underline.
  void setCursorUnderlineStyle(UnderlineStyle style);

  void setCursorOverline();

  void setCursorBlink();

  void setCursorInverse();

  void setCursorInvisible();

  void setCursorStrikethrough();

  void unsetCursorBold();

  void unsetCursorFaint();

  void unsetCursorItalic();

  void unsetCursorUnderline();

  void unsetCursorOverline();

  void unsetCursorBlink();

  void unsetCursorInverse();

  void unsetCursorInvisible();

  void unsetCursorStrikethrough();

  void setForegroundColor16(int color);

  void setForegroundColor256(int index);

  void setForegroundColorRgb(int r, int g, int b);

  void resetForeground();

  void setBackgroundColor16(int color);

  void setBackgroundColor256(int index);

  void setBackgroundColorRgb(int r, int g, int b);

  void resetBackground();

  /* Underline color (SGR 58 / 59) */

  void setUnderlineColor256(int index);

  void setUnderlineColorRgb(int r, int g, int b);

  void resetUnderlineColor();

  void unsupportedStyle(int param);

  /* OSC */

  void setTitle(String name);

  void setIconName(String name);

  void unknownOSC(String code, List<String> args);

  /* Kitty graphics protocol (APC _G ... ST) */

  /// Start of a Kitty graphics command with its parsed key/value [args].
  void graphicsCommandStart(Map<String, String> args);

  /// A chunk of (base64-decoded) image payload for the current command.
  void graphicsDataChunk(List<int> data);

  /// End of the current Kitty graphics command (final chunk received).
  void graphicsCommandEnd();

  /// A Kitty graphics command was cut short by an ESC before its terminator.
  ///
  /// Any transmission still open from an earlier `m=1` chunk is unrecoverable
  /// at that point, so it must be discarded rather than left active for the
  /// next command to be appended to.
  void graphicsCommandAbort();
}
