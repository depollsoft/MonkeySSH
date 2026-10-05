# HANDOFF (package ho-acp, branch refactor/sa5-ho-acp)

## Edits outside the listed files

- `lib/presentation/models/acp_timeline.dart`: removed `AcpUsage.inputTokens`,
  `outputTokens`, `totalTokens` (acp2 #1 asked for it; the model file was not
  in the ownership list).
- `lib/domain/services/telemetry_service.dart`: besides the provider-category
  allowlist, removed `'command_not_approved'` from
  `_allowedAcpFailureCategories`, because `AcpSessionErrorKind.commandNotApproved`
  no longer exists.
- Tests updated for removed APIs: `test/support/fake_acp_session_manager.dart`,
  `test/widget/acp_composer_test.dart`,
  `test/presentation/controllers/acp_composer_controller_test.dart` (dropped the
  `providerService:` argument and `_FakeProviderService`),
  `test/domain/services/muse_code_test.dart` (probe builders now take
  `overrideVariables`).

## Merge notes

- `lib/presentation/screens/terminal_screen.dart` changed only at the two
  concurrency sites (`_performNativeAcpSessionStart`, about line 9361, and
  `_performOpenServerOwnedNativeAcpWindow`, about line 9789). ho-term edits the
  same file.
- Behaviour changes: an unapproved built-in launch override now fails with
  `AcpSessionErrorKind.unknown` (same message); a non-built-in provider id
  reports telemetry category `unknown` instead of `custom`; every ACP provider
  command now carries the `TERM_PROGRAM` default (only set when absent).

## Still open (not ACP-package scope or optional)

- acp2 #2: rename `cap.AcpPendingPermission` to drop import prefixes (optional).
- acp2b #10: structured `keychain_locked` error code from the Go bridge (needs a
  MonkeyMux version bump).
- acp4: `agent_chat_screen.dart` `onCopyCode` tear-off (optional).
- mux1 #5: drop `TmuxWindow.copyWith(panePid:, currentCommand:)` once the two
  tests build windows directly.
- `_resolvedAcpExecutableName` in `lib/domain/models/acp_provider.dart` is one
  more copy of the basename logic (with per-call RegExps); it could use
  `normalizeCommandBasename` on the last path segment like the bridge parser.
