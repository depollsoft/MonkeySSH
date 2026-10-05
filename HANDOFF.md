# HANDOFF (package acp2b)

## Edits outside owned files
- `test/domain/services/acp_session_manager_test.dart`: removed the 3-line `Future<void> get done` override from the `AcpTerminalProcess` fake (the interface member was deleted, finding 8). No other change.

## Needed in other packages
- Finding 8, `AcpMcpServerService(maxServers:)` (`lib/domain/services/acp_mcp_server_service.dart:37-44`): not owned by this package (finding 7 edits that file). Inline `kAcpMcpServerMaxCount` and drop the constructor parameter; `grep -rn "maxServers:" lib test` -> 0 callers.
- Finding 10, Go side (`remote/monkeymux/acp_bridge.go:534,584,613`): the Dart side now matches `monkeyMuxCursorKeychainLockedMessage` (`lib/domain/models/monkeymux_acp_bridge.dart`). To remove the sentence coupling entirely, have the helper emit a structured code (for example `errorCode: "keychain_locked"` in the NDJSON error frame) and switch the Dart match in `MonkeyMuxAcpBridgeService._startBridge` to that code; requires a MonkeyMux version bump and asset rebuild.
