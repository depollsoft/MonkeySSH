# HANDOFF — package mux1 (branch `refactor/sa5-mux1`)

Edits made outside the owned files (all tiny, needed to keep the tree compiling
after the assigned deletions; please check for conflicts with parallel packages):

1. `test/domain/services/ssh_exec_queue_crashlytics_cases.dart`
   - `TmuxService(execChannelNow: () => now)` → `TmuxService(now: () => now)`
     (finding #9: the service now has one injectable clock, `now`).
   - Removed the `isTmuxActive`, `hasSession` and `hasForegroundClient` entries
     from the `queries` map; those non-throwing wrappers were deleted (finding
     #9) and the entries only exercised them. `foregroundSessionName` and
     `currentPaneContext` remain and cover the same error-swallowing path.
2. `test/presentation/screens/terminal_screen_test.dart`
   - The fake `LocalNotificationService` override `clearTmuxAlert` is now
     `clearTerminalNotification` (finding #10: the two identical methods were
     merged; the bar calls `clearTerminalNotification`).
   - Removed three dead `when(() => tmuxService.hasSessionOrThrow(...))` stubs
     (the method no longer exists; nothing in `lib/` called it).

Outside edits still needed (not done here, outside the package's files):

3. `lib/domain/services/monkeymux_service.dart` `_monkeyMuxAgentPanePids`
   (finding #7): filter by `agentSessionMetadataProbeTools` (exported from
   `tmux_service.dart`) instead of `foregroundAgentTool != null`, so pi /
   hermes / cursor / openclaw / grok / muse panes do not keep the probe alive.
4. `lib/domain/models/agent_launch_preset.dart` lines ~207 and ~367-372
   (finding #5): hoist the four per-call `RegExp(...)` in
   `agentLaunchToolForCommandName` / `_normalizeAgentCommandName` to top-level
   `final`s; `foregroundAgentTool` calls them per window per rebuild.
5. `TmuxWindow.copyWith` still accepts `panePid` and `currentCommand` (finding
   #9 listed six params). They are only passed from
   `test/domain/services/monkeymux_service_test.dart` and
   `test/widget/terminal_screen_selection_cases.dart`; drop the params once those
   tests build their windows directly.
