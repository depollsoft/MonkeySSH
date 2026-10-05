# HANDOFF (package acp2)

Edits needed outside the files this package owns.

## 1. `lib/presentation/widgets/acp_usage.dart` (widget owner) — Part 3 finding 3

`AcpUsage.inputTokens` / `outputTokens` / `totalTokens` in
`lib/presentation/models/acp_timeline.dart` are never produced: the only
production constructor call is `_mapUsage` in `acp_timeline_mapper.dart`, which
passes `contextWindow` and `contextUsedTokens` only. The three fields are kept
solely because `acp_usage.dart:40-48` reads them (the `↑`/`↓`/`Σ` stats).

Change: delete those three branches in `acp_usage.dart`, drop the matching
cases in `test/widget/acp_message_thread_test.dart:1014` and `:1274-1276`, then
remove the three fields from `AcpUsage` (model owner can do this last step; it
is a four-line deletion plus `props`). Left in place here so the tree compiles.

## 2. `lib/domain/models/acp_client_capabilities.dart` — Part 3 finding 8 (optional)

Rename the capability-side `AcpPendingPermission` to
`AcpPendingPermissionRequest` so `acp_session_manager.dart` (`import ... as cap`)
and `acp_permission_surface.dart` (`as session`) can drop their prefixes. Low
value; skipped because the file is not owned by this package.
