class EscapeEmitter {
  const EscapeEmitter();

  String primaryDeviceAttributes() {
    // DA1: VT220 service class (62) advertising ANSI colour (feature 22). This
    // replaces the old VT100 identity (`?1;2c`) now that the terminal also
    // reports a kitty identity via XTVERSION; it is a more accurate, widely
    // compatible reply and lets apps that branch on DA1 see colour support.
    // Only flags the terminal genuinely implements are claimed (colour);
    // 132-column, selective-erase, etc. are intentionally omitted.
    return '\x1b[?62;22c';
  }

  String secondaryDeviceAttributes() {
    // DA2: VT220-class terminal (model 1) to stay consistent with the VT220
    // DA1 service level. The firmware version is left at 0 so terminal-
    // detection heuristics that key off specific patch levels do not apply a
    // device-specific quirk — the precise identity is carried by XTVERSION.
    const model = 1;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  /// Response to XTVERSION (`CSI > q`): the terminal name and version.
  ///
  /// MonkeySSH implements the kitty graphics and keyboard protocols (plus
  /// truecolor and styled underlines), so it reports a kitty-family identity.
  /// Besides being accurate about the supported protocol family, this unlocks
  /// the richer rendering path in CLIs (for example the GitHub Copilot CLI)
  /// that gate full-width prompt/composer backgrounds on a recognized
  /// XTVERSION name. The version predates the kitty text-sizing protocol, which
  /// this terminal does not implement.
  String terminalVersion() {
    return '\x1bP>|kitty(0.32.0)\x1b\\';
  }

  /// Response to DECRQM for an ANSI mode (`CSI Ps $ p` -> `CSI Ps ; Pm $ y`).
  ///
  /// [value] follows the DECRPM convention: 0 not recognized, 1 set, 2 reset,
  /// 3 permanently set, 4 permanently reset.
  String modeReport(int mode, int value) {
    return '\x1b[$mode;$value\$y';
  }

  /// Response to DECRQM for a DEC private mode (`CSI ? Ps $ p` ->
  /// `CSI ? Ps ; Pm $ y`), with [value] as in [modeReport].
  String decModeReport(int mode, int value) {
    return '\x1b[?$mode;$value\$y';
  }

  /// Response to XTGETTCAP for a single capability
  /// (`DCS 1 + r <name>=<value> ST` when known, `DCS 0 + r <name> ST` when not).
  ///
  /// [hexName] is echoed back exactly as requested so the querying program can
  /// match it; [hexValue] is the hex-encoded capability value, or null when the
  /// capability is unknown/unsupported.
  String termcapReport(String hexName, String? hexValue) {
    if (hexValue == null) {
      return '\x1bP0+r$hexName\x1b\\';
    }
    return '\x1bP1+r$hexName=$hexValue\x1b\\';
  }

  /// Response to DECRQSS (`DCS 1 $ r <Pt> ST` when the request is recognized,
  /// `DCS 0 $ r ST` when it is not).
  ///
  /// [value] is the full status string including the control function's
  /// trailing intermediate/final (for example `1;24r` or `0;1m`), or null when
  /// the request is not recognized.
  String statusStringReport(String? value) {
    if (value == null) {
      return '\x1bP0\$r\x1b\\';
    }
    return '\x1bP1\$r$value\x1b\\';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  /// Cursor position report (CPR) for the 1-based column [x] and row [y].
  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  /// Extended cursor position report (DECXCPR) for the 1-based column [x] and
  /// row [y]. xterm adds the page only at VT level 4 and above; this terminal
  /// identifies as a VT220 (see [secondaryDeviceAttributes]), so it leaves the
  /// page out, as xterm does at that level.
  String extendedCursorPosition(int x, int y) {
    return '\x1b[?$y;${x}R';
  }

  /// Visibility report: `CSI ? 999 ; 1 n` while the view may be visible,
  /// `CSI ? 999 ; 2 n` when it is known to be hidden.
  String visibilityReport(bool visible) {
    return visible ? '\x1b[?999;1n' : '\x1b[?999;2n';
  }

  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }
}
