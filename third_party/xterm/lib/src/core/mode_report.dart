import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal.dart';

/// The mode states a DECRPM reply (`CSI Ps ; Pm $ y`) carries.
///
/// https://vt100.net/docs/vt510-rm/DECRPM.html
abstract final class ModeReportState {
  /// The terminal does not know the mode.
  static const notRecognized = 0;

  /// The mode is set and can be reset.
  static const set = 1;

  /// The mode is reset and can be set.
  static const reset = 2;

  /// The mode is set and cannot be reset.
  static const permanentlySet = 3;

  /// The mode is reset and cannot be set.
  static const permanentlyReset = 4;

  /// [set] when [enabled], [reset] otherwise.
  static int of(bool enabled) => enabled ? set : reset;
}

/// The DECRQM state of ANSI mode [mode] (`CSI Ps $ p`).
///
/// ANSI modes the terminal does not implement but xterm and Ghostty name
/// report permanently reset, so a program hears "unsupported" rather than
/// "unknown".
int ansiModeReportState(Terminal terminal, int mode) => switch (mode) {
      4 => ModeReportState.of(terminal.insertMode), // IRM
      20 => ModeReportState.of(terminal.lineFeedMode), // LNM
      // The terminal never echoes input locally (SRM set).
      12 => ModeReportState.permanentlySet,
      // GATM, KAM, CRM, SRTM, VEM, HEM, PUM, FEAM, FETM, MATM, TTM, SATM,
      // TSM, EBM.
      1 ||
      2 ||
      3 ||
      5 ||
      7 ||
      10 ||
      11 ||
      13 ||
      14 ||
      15 ||
      16 ||
      17 ||
      18 ||
      19 =>
        ModeReportState.permanentlyReset,
      _ => ModeReportState.notRecognized,
    };

/// The DECRQM state of DEC private mode [mode] (`CSI ? Ps $ p`), or null when
/// the terminal does not track the mode itself.
///
/// Supporting one more mode for DECRQM is one entry here. Values follow xterm
/// and Ghostty: modes the terminal can never change report permanently set or
/// reset, and a mode it does not implement is left out (not recognized).
int? decModeReportState(Terminal terminal, int mode) => switch (mode) {
      1 => ModeReportState.of(terminal.cursorKeysMode), // DECCKM
      2 => ModeReportState.of(terminal.ansiMode), // DECANM
      // DECCOLM: the column count only ever follows the view.
      3 => ModeReportState.permanentlyReset,
      5 => ModeReportState.of(terminal.reverseDisplayMode), // DECSCNM
      6 => ModeReportState.of(terminal.originMode), // DECOM
      7 => ModeReportState.of(terminal.autoWrapMode), // DECAWM
      // DECARM: key repeat belongs to the platform, as in xterm.
      8 => ModeReportState.permanentlyReset,
      9 => ModeReportState.of(terminal.mouseMode == MouseMode.clickOnly),
      12 => ModeReportState.of(terminal.cursorBlinkMode),
      25 => ModeReportState.of(terminal.cursorVisibleMode), // DECTCEM
      47 || 1047 || 1049 => ModeReportState.of(terminal.isUsingAltBuffer),
      66 => ModeReportState.of(terminal.appKeypadMode), // DECNKM
      67 => ModeReportState.of(terminal.backarrowKeyMode), // DECBKM
      // DECECM: erasing always uses the current background, as with DECECM
      // reset; Ghostty reports the same.
      117 => ModeReportState.permanentlyReset,
      1000 => ModeReportState.of(terminal.mouseMode == MouseMode.upDownScroll),
      1002 => ModeReportState.of(
          terminal.mouseMode == MouseMode.upDownScrollDrag,
        ),
      1003 => ModeReportState.of(
          terminal.mouseMode == MouseMode.upDownScrollMove,
        ),
      1004 => ModeReportState.of(terminal.reportFocusMode),
      1005 => ModeReportState.of(
          terminal.mouseReportMode == MouseReportMode.utf,
        ),
      1006 => ModeReportState.of(
          terminal.mouseReportMode == MouseReportMode.sgr,
        ),
      1007 => ModeReportState.of(terminal.altBufferMouseScrollMode),
      1015 => ModeReportState.of(
          terminal.mouseReportMode == MouseReportMode.urxvt,
        ),
      1048 => ModeReportState.of(terminal.saveCursorMode),
      2004 => ModeReportState.of(terminal.bracketedPasteMode),
      2026 => ModeReportState.of(terminal.synchronizedOutputMode),
      2033 => ModeReportState.of(terminal.reportVisibilityMode),
      _ => null,
    };
