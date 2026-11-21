import 'package:xterm/xterm.dart';

/// Record separator between capability hint entries.
const terminalCapabilityHintRecordSeparator = '\x1e';

/// Separator between a capability hint key and its reply.
const terminalCapabilityHintFieldSeparator = '\x1f';

/// Hint key for the primary device attributes reply (`CSI c`).
const terminalCapabilityHintPrimaryDeviceAttributesKey = 'da1';

/// Hint key for the secondary device attributes reply (`CSI > c`).
const terminalCapabilityHintSecondaryDeviceAttributesKey = 'da2';

/// Hint key for the tertiary device attributes reply (`CSI = c`).
const terminalCapabilityHintTertiaryDeviceAttributesKey = 'da3';

/// Hint key for the XTVERSION reply (`CSI > q`).
const terminalCapabilityHintTerminalVersionKey = 'xtversion';

/// Hint key for the device status report reply (`CSI 5 n`).
const terminalCapabilityHintDeviceStatusKey = 'dsr';

/// Hint key whose presence tells MonkeyMux this client answers the kitty
/// clipboard protocol (OSC 5522), so the server forwards its windows'
/// clipboard requests here instead of refusing them. The reply is the DECRQM
/// report for paste events mode 5522 (recognized, reset).
const terminalCapabilityHintKittyClipboardKey = 'osc5522';

/// Builds the terminal capability hint sent to MonkeyMux attach/control
/// channels.
///
/// MonkeyMux only forwards a window's terminal queries to the attached client
/// while that window is the one on screen. An agent relaunched by an upgrade
/// restore probes the terminal as it starts — before the client reattaches, or
/// while the window is still in the background — so its XTVERSION and device
/// attribute queries go unanswered and it settles on a plainer rendering mode
/// (for example the Copilot CLI composer without a full-width background).
/// Handing these replies to the server lets it answer those probes itself,
/// immediately, for every restored window.
///
/// Only replies that are constant for this terminal are included. Queries whose
/// answer depends on live state (cursor position, window/cell metrics, kitty
/// keyboard flags) must still be answered by the client.
String buildTerminalCapabilityHintReports() {
  const emitter = EscapeEmitter();
  return encodeTerminalCapabilityHintReports({
    terminalCapabilityHintPrimaryDeviceAttributesKey: emitter
        .primaryDeviceAttributes(),
    terminalCapabilityHintSecondaryDeviceAttributesKey: emitter
        .secondaryDeviceAttributes(),
    terminalCapabilityHintTertiaryDeviceAttributesKey: emitter
        .tertiaryDeviceAttributes(),
    terminalCapabilityHintTerminalVersionKey: emitter.terminalVersion(),
    terminalCapabilityHintDeviceStatusKey: emitter.operatingStatus(),
    terminalCapabilityHintKittyClipboardKey: '\x1b[?5522;2\$y',
  });
}

/// Encodes [reports] as the MonkeyMux capability hint wire format.
///
/// Each entry is `key US reply`, and entries are joined with RS. Both
/// separators are C0 controls that never appear in a terminal reply, so the
/// server can split the payload without escaping.
String encodeTerminalCapabilityHintReports(Map<String, String> reports) =>
    reports.entries
        .where((entry) => entry.key.isNotEmpty && entry.value.isNotEmpty)
        .map(
          (entry) =>
              '${entry.key}$terminalCapabilityHintFieldSeparator${entry.value}',
        )
        .join(terminalCapabilityHintRecordSeparator);
