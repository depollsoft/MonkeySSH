import 'package:xterm/core.dart';

/// Sends terminal scroll mouse input with corrected SGR wheel button IDs.
///
/// SGR reports from a touch drag ([fromTouch]) write the column with a
/// leading zero. Every SGR parser reads the same column, but the MonkeyMux Pi
/// extension uses it to tell touch drags, whose distance the client already
/// calibrates, from mouse wheel notches that Pi may accelerate.
bool sendTerminalScrollMouseInput({
  required Terminal terminal,
  required TerminalMouseButton button,
  required CellOffset position,
  bool forceSgr = false,
  bool fromTouch = false,
  int repeatCount = 1,
}) {
  if (forceSgr ||
      (terminal.mouseMode.reportScroll &&
          terminal.mouseReportMode == MouseReportMode.sgr)) {
    final sgrButtonId = switch (button) {
      TerminalMouseButton.wheelUp => 64,
      TerminalMouseButton.wheelDown => 65,
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => button.id,
    };
    final column = '${fromTouch ? '0' : ''}${position.x + 1}';
    final report = '\x1b[<$sgrButtonId;$column;${position.y + 1}M';
    terminal.onOutput?.call(report * repeatCount.clamp(1, 32));
    return true;
  }

  return terminal.mouseInput(button, TerminalMouseButtonState.down, position);
}
