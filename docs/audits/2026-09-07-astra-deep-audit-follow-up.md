# Astra deep audit follow-up, 2026-09-07

## Later cleanup

The subsequent Astra/Fable audit removed the iOS sync-vault bridge, helper,
registrations, and dedicated test job after confirming that its Dart caller had
already been deleted. The vault entries below record historical work, not current
files or validation commands.

## Scope and method

This audit started from `main` at `550a5380`, after the earlier audit and resume fixes. Main, six subsystem agents, and three follow-up review/implementation agents all used GPT-6 Astra. This report covers new findings, not the fixes in `2026-09-07-astra-code-audit.md`.

Reviews traced resource ownership, asynchronous completion, failure handlers, and deployment paths across SSH/SFTP, ACP, MonkeyMux, persistence/settings, UI/rendering, native bridges, and release tooling. Storage migrations, authentication, forwarding, and several platform lifecycles were inspected without speculative rewrites. This was a risk-focused codebase audit, not an exhaustive proof that every file or platform is correct.

## Fixes and acceptance ledger

| Area and files | Bug, change, and acceptance check |
| --- | --- |
| `lib/domain/services/ssh_service.dart`; SFTP and terminal screens | Concurrent SFTP waiters could receive an uncached stale client, and late cleanup could invalidate its replacement. All waiters now share the ownership-checked future. `discardSftpOpen` accepts that exact future; client cleanup only closes the supplied client. Both timeout callers use the new operation. Tests cover both completion orders, cached/pending replacements, browser Retry, terminal timeout recovery, and shared/standalone opens completing after shutdown. |
| `lib/domain/services/acp_client_capability_service.dart` | Path validation and terminal creation could finish after teardown, resurrecting writes or orphaning processes. Active-request ownership is invalidated before cleanup. Late processes are killed; writes and reads recheck ownership after validation, and reads recheck before returning content. Tests cover whole-service and per-session closure, auto-approved writes, sibling isolation, and soft detach. Soft detach deliberately preserves requests. |
| ACP failure responses | Replying on a closed/already-answered channel could escape as an unhandled future. Failure replies now have a best-effort error boundary. Closed-channel regressions exercise the asynchronous route. |
| `lib/domain/services/telemetry_service.dart` | Overlapping SDK calls and stale settings initialization could restore old consent. SDK updates and preference writes run in request order; revision checks suppress stale initialization/state publication. Opt-out gates app events immediately, even behind blocked persistence or an older SDK enable. Superseded enables cannot reopen the gate. Tests verify disable/reset/delete-unsent work survives preference-write failure and precedes a newer opt-in. |
| `lib/domain/services/agent_session_discovery_service.dart` | Invalidated discovery streams could repopulate snapshots used by newer subscribers. Snapshot publication now requires ownership of the current in-flight stream. Original listeners can still receive their result; replacement subscribers do not inherit it. |
| `lib/domain/services/terminal_command_mark_tracker.dart` | Normal and alternate-screen anchors shared one navigation list without buffer identity. Marks now retain their buffer and navigation/deduplication only use active-buffer anchors. Tests preserve wrapping, detached-anchor cleanup, and one global retention cap. |
| `lib/presentation/view_models/host_edit_view_model.dart` | Host loading accessed provider state after disposal. Checks at all four asynchronous boundaries stop further loading/publication. Tests dispose during each stage and during a missing-host lookup. |
| `third_party/xterm/lib/src/ui/infinite_scroll_view.dart` | Replacing a viewport position removed/added the wrong callback, leaving an old subscription and losing scroll notifications. Replacement now uses the same `_onScroll` listener as attach/detach. A widget test swaps physics repeatedly and verifies subsequent scroll callbacks and disposal. |
| `third_party/xterm/lib/src/ui/painter.dart` | Underline and bar cursors ignored the supplied vertical offset. Both now translate from the complete cursor offset. Tests assert exact drawing coordinates at a nonzero position. |
| xterm paragraph/painter/render classes; `monkey_terminal_view.dart` | Cached paragraphs were dropped without explicit native disposal. Replacement, cache clearing, and painter teardown now release owned paragraphs; temporary composing paragraphs are released after drawing. Both renderers call painter disposal. Tests check disposal, cache reuse/LRU behavior, and pixel-identical replay of recorded pictures after cache clearing. |
| `remote/monkeymux/main.go` | PTY input inspected `window.closed` outside the server mutex. The check is now protected, while potentially blocking PTY writes remain outside the lock. Repeated race tests and a blocked-write probe verify both properties. |
| `remote/monkeymux/acp_bridge.go` | Socket setup errors could leave a started provider running. Cleanup is registered before setup begins. Real-process probes verify provider reaping and output-reader shutdown on three startup failures. |
| Go ACP attach | A hello accepted before shutdown could register a client afterward. Registration checks stopped state under the same mutex as shutdown. A delayed-hello pipe probe verifies EOF and zero registered clients. |
| `scripts/cache_sqlite3_native_assets.sh` | Concurrent prefetches shared a temporary filename. Each invocation now owns a unique download and cleanup trap; only verified bytes replace the cache. Offline tests cover concurrency, retry, corrupt bytes, and preserving existing cache data on failure. |
| `scripts/resolve_next_app_store_patch_version.rb` | An old editable patch could win over a newer used patch. Automatic reuse now requires the editable patch to be the latest patch in that version line. Tests cover store states, input ordering, and the base-version floor. Explicit requested-version behavior is unchanged. |
| `ios/Runner/SyncVaultFileIO.swift`; `AppDelegate.swift` | Export names could escape their temporary directory, failed writes could leave that directory behind, and the size check followed an unbounded read. A Foundation-only helper confines names, cleans failed exports, and reads in bounded chunks with one-byte overflow detection. Tests cover names, confinement, exact boundaries, oversized files, missing files, and failed-write cleanup. Existing error domain/code are preserved. |
| `windows/runner/utils.cpp` | A zero result from `WideCharToMultiByte` underflowed when the terminator was subtracted into an unsigned integer, potentially requesting roughly four GiB. The code checks failure/empty input first. An API-shim regression verifies failure, empty, and valid conversion behavior. |

## Behavior-preserving simplifications and optimizations

- `MonkeyTerminalPainter` uses one cache-clearing helper instead of repeating the same four invalidations in each setter and font callback.
- Painter/cache teardown explicitly releases native paragraphs rather than waiting for garbage collection. Production cache capacities and LRU hit/eviction order are unchanged.
- Vault reads stop at the existing 10 MiB limit rather than materializing an arbitrarily large input before rejecting it.
- SFTP pending opens share one future and one ownership/cleanup path, including concurrent waiters.

These preserve valid-path behavior. Bug fixes intentionally change the failure cases above. No frame-rate or throughput improvement is claimed without a benchmark.

## Integration and deployment checks

- MonkeyMux is bumped to `0.1.187`, so installed older helpers take the update path. All six macOS/Linux/Windows architecture bundles were rebuilt with the pinned Go 1.26.5 toolchain. The ignored manifest and binaries are not committed.
- The source version, version script, manifest, checksums, and embedded binary versions pass the existing consistency tests.
- `SyncVaultFileIO.swift` is registered in the Runner file group and Sources build phase.
- New xterm regressions live under root `test/unit` and `test/widget`, so normal Flutter CI discovers them.
- CI runs SQLite-prefetch, Windows-conversion, and App Store version regressions. A macOS job compiles/runs the Foundation-only tests, and its result feeds the required aggregate CI job.
- `.github/actionlint.yaml` declares the repository's existing custom runner label; it does not change runner selection.

## Validation

| Check | Result |
| --- | --- |
| `flutter analyze --no-pub` | No issues after fixing one relocated-test style lint |
| `flutter test --no-pub --reporter expanded` | 4,115 passed after PR feedback; one opt-in localhost SSH integration test skipped |
| `flutter test --no-pub --reporter expanded`, from `third_party/xterm` | 346 passed; new audit regressions run in the root suite |
| `GOTOOLCHAIN=go1.26.5 go test -race ./...`, from `remote/monkeymux` | Passed on macOS arm64 |
| Pinned `go vet ./...` | Passed |
| Pinned Linux amd64 and Windows amd64 test-binary compilation | Passed; not runtime execution |
| `scripts/ensure_monkeymux_assets.sh` | Six helper targets built at 0.1.187 |
| `python3 -m unittest discover -s test/scripts -p '*_test.py'` | 37 passed |
| `bash test/scripts/run_swift_native_tests.sh` | All filename, confinement, read-boundary, rejection, and cleanup probes passed |
| `ruby scripts/resolve_next_app_store_patch_version_test.rb` | 23 tests, 49 assertions passed |
| `ruby test/scripts/preview_release_notes_test.rb` | Four tests, 15 assertions passed |
| Actionlint, shell checks, Swift helper checks, both store metadata validators | Passed |
| Changed-file diagnostics/formatting and `git diff --check` | Passed; existing spelling suggestions were not treated as compiler errors |

Initial probes reproduced failures for SFTP ownership, ACP teardown, telemetry ordering, command-buffer isolation, Go races/startup cleanup, download concurrency, version selection, and Windows conversion. An independent review found that service-only SFTP tests missed caller cleanup; actual browser/terminal regressions now cover it. Review also caught delayed opt-out gating and late ACP read responses; both received further fixes and tests.

A final read-only Astra review found no remaining blockers. It checked SFTP caller ownership, ACP reads, consent ordering, renderer disposal, Xcode registration, and CI gating without treating reported test results as independently rerun evidence.

Flutter tests ran serially across invocations after concurrent startup generated a native-asset filesystem collision. The final full-suite run did not encounter that build collision.

## PR feedback follow-up

Review findings in [PR #809](https://github.com/depollsoft/MonkeySSH/pull/809) are addressed:

- [ACP teardown admission](https://github.com/depollsoft/MonkeySSH/pull/809#discussion_r3951388859): a reference-counted closing-session guard rejects new terminal, write, permission, and read requests until every overlapping cleanup finishes. A `finally` block restores admission after success or failure. Six gated tests exercise terminal release, registry cancellation, failure paths, both overlap completion orders, sibling requests, and later resume. This is a transient guard, not a permanent session denylist.
- [Paragraph capacity eviction](https://github.com/depollsoft/MonkeySSH/pull/809#discussion_r3951388886): insertion-ordered map storage promotes hits by remove/reinsert and disposes the oldest entry before inserting into a full cache. This preserves LRU order without scanning Quiver's MRU-to-LRU iterable for its final entry. The two eviction regressions failed before the correction. Tests now assert disposal directly, cover sustained capacity-one churn, replacement promotion, and misses without manual paragraph disposal. Nonpositive capacity is rejected so a returned paragraph always has a cache owner; every production caller already uses positive capacity.

- [Late auto-approved write response](https://github.com/depollsoft/MonkeySSH/pull/809#discussion_r3951500794): recheck request activity after the awaited remote write, before returning success. Two regressions failed before the guard when the service or owning session closed during the write. Soft-detach and sibling-close controls continue to succeed. An already issued remote write cannot be undone; the change prevents a stale success response. After this final guard, all 134 affected capability/session-manager/lifecycle tests and fresh Flutter analysis passed.

Before that final single-guard correction, follow-up validation passed clean Flutter analysis, all 4,115 app tests with the same one opt-in SSH skip, and all 346 vendored xterm tests. An independent Astra review found no blockers in these corrections. Earlier hosted CI also passed all five native build targets and Linux/Windows Go execution on the original PR commit; the follow-up commit must pass its own required checks before merge.

## Limits and follow-up areas

- The skipped SSH integration test requires `scripts/setup_acp_test_env.sh`. No physical-device permission/IME timing, real store APIs, signing, or publication was exercised. Go process probes used local test providers, not installed production coding agents.
- Linux/Windows Go tests were cross-compiled, not executed locally. The Windows conversion test uses API shims. Hosted platform CI remains necessary.
- Native cloud file-provider reads have bounded memory, not bounded latency. The helper's byte limit is an internal positive constant.
- Future ACP requests for an individually closed session on a still-shared bridge need an explicit session-reactivation policy. This patch invalidates requests already in progress and rejects new admissions while cleanup is pending; it does not add a permanent session-ID denylist that could break later resume.
- ACP manager queued launches, stalled attachment source reads, forwarding-client teardown, key-decryption cache invalidation, keychain replacement failure, ActivityKit ordering, and Android NSD lifecycle callbacks warrant separate fault-injection work. Those were review leads, not accepted fixes without adequate probes.
- Media generation scripts, every platform branch, and all app save/reload lifecycles were not exhaustively audited.
