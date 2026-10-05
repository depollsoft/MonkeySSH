# HANDOFF: go-core package (branch refactor/sa5-go-core)

All work compiles and passes on this branch. The edits below land outside the
go-core line regions of `remote/monkeymux/main.go` (>= ~10300 and the agent
tables at ~16100-16400) but were unavoidable for the findings assigned to
go-core. Each is a mechanical, few-line change; if the owning branch conflicts,
re-apply these on top of its version.

| Finding | Location (post-edit line) | Change | Why |
|---|---|---|---|
| 1.2 | `muxServer.close`, ~17225 | `requestAcpBridgeStopAndWait(window.nativeAcpBridgeID)` -> `stopNativeAcpBridgeForWindow(...)` | fourth bridge-stop site must go through the test seam |
| 5.5 | `sendThemeHint`, ~12267 | `themeHintDataFromString(data)` -> `hintDataFromString(data, themeHintLimitBytes)` | caller of the merged hint helper |
| 5.5 | ~12300 | deleted `themeHintDataFromString` / `capabilityHintDataFromString` (replaced by `hintDataFromString(data, limit)` next to `decodeHintBase64` at ~1807) | one helper instead of four |
| 5.7 | `resumePausedAttachForwarding` ~10560/10582, `writeAttachOutputIfActive` ~11375/11409, `enqueuePrimaryAttachLocked` ~11543 | `enqueueTerminalQuery(a,b,c,d)` -> `enqueueWrite(a,b,c,d,nil)`; `enqueueConditionalTerminalQuery(...)` -> `enqueueWrite(...)` | the two forwarders were deleted |
| 5.8 | agent tables ~16219-16250 | `agentResumeCommandWithFreshFallback` renamed to `resumeCommandWithFreshFallback` and given the shared body; platform files now only provide `shellOrElseJoin(first, fallback)` (`platform_unix.go`, `platform_windows.go`); `piResumeCommandWithFreshFallback` is gone | one body for every agent, platform-specific join only |
| 5.9 | `socketIdentity` type ~18006 | added `func (id socketIdentity) valid() bool` next to the type; removed the two copies from `platform_unix.go` / `platform_windows.go`; `replacement_process_other_unix.go` + `replacement_process_windows.go` merged into `replacement_process_other.go` (`//go:build !darwin`) | identical platform code |

No other package needs to act unless a merge conflict surfaces on those hunks.
