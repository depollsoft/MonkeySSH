# HANDOFF from package acp4

Edits made outside this package's owned files (all minimal; please keep them when merging):

1. `lib/presentation/widgets/tmux_window_navigator.dart` (around line 1992, G3): the
   `AcpMuxWindowStatusBadge` fallback is now an enum. Changed
   `fallbackLabel: orphan ? 'recent' : 'native'` to
   `fallback: orphan ? AcpMuxWindowFallback.recent : AcpMuxWindowFallback.native`.
   The matching test line in `test/widget/tmux_window_navigator_cases.dart:278` was
   updated the same way (`fallback: AcpMuxWindowFallback.native`).

2. `lib/presentation/widgets/acp_connection_support.dart` (B2): replaced the body of
   `_isResolvedTerminalExecutable` with the shared `normalizeCommandBasename` from
   `lib/domain/models/command_names.dart` (added that import). The old
   `replaceAll(r'\\', '/')` never matched a single backslash, so Windows paths such as
   `C:\Users\x\copilot.cmd` did not get YOLO/global launch arguments. Regression test:
   `test/domain/services/acp_launch_profile_picker_cases.dart`
   ("recognises a Windows executable path with backslashes").
   The duplicate basename logic in `monkeymux_acp_bridge_service.dart:255-262`
   (`parseMonkeyMuxAcpExecutableProbeOutput`) belongs to another package; it can use
   `normalizeCommandBasename(path)` the same way.

Optional follow-up for the owner of `lib/presentation/screens/agent_chat_screen.dart`
(P4): `onCopyCode: (code) => _copyToClipboard(code, 'Code')` can become a stable
tear-off. It is no longer required for correctness or performance because
`AcpMarkdown` now reads its callbacks through its State and only re-parses when the
data, `machineContent`, or a callback's presence changes.
