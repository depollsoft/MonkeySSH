# Astra code audit, 2026-09-07

## Scope and method

This audit started from `main` at `8bab2be1`. The main session, six subsystem implementers, and three independent review passes all used GPT-6 Astra. Reviews followed execution paths and failure cases, then added regression tests before accepting fixes. This was a risk-focused audit across the repository, not a claim that every file or platform is defect-free.

Areas traced included:

- SSH connection cancellation, shell replacement, exec queues, forwarding, tmux/MonkeyMux observation, and clipboard commands.
- ACP request framing, request registration, transport shutdown, replay retention, session updates, attachments, and SFTP ownership.
- Authentication writes, settings transactions, key migration, repository encryption, and local/remote file cleanup.
- Terminal metadata listeners, input approval and repeat ownership, IME state, OSC hyperlinks, and fragmented CSI parsing.
- Store-asset packaging/restoration, workflow routing, release version preparation, native service entry points, and signing/upload tooling.

## Fixes and reasons

### ACP and MonkeyMux

The helper version is bumped to `0.1.186`, keeping the compiled version and generated manifest aligned so the normal update path recognizes the patched helper.

- **Shutdown could wait forever for a blocked provider write.** `remote/monkeymux/acp_bridge.go` now protects stdin ownership separately from frame serialization. Closing the pipe can interrupt a blocked write rather than waiting for the writer's lock.
- **A fast provider response could arrive before request registration.** The bridge registers requests before writing, removes registrations on write failure, and does not overwrite the provider's returned session ID with stale request metadata. This prevents completed requests from remaining in flight and preserves session identity.
- **An oversized frame could leave the reader waiting for a newline.** The bridge now rejects immediately after the limit is exceeded. Its callers terminate that stream, so draining it served no recovery purpose.
- **Queued RPC writes could reach a closed transport.** `acp_json_rpc_connection.dart` checks connection state when each queued write actually executes. Encoding errors now reach the pending-request cleanup path. All termination paths share the same future, so explicit close waits for cleanup already started by a transport failure.
- **Attachment fallback could upload truncated data.** `acp_attachment_service.dart` derives the inline buffering limit from capabilities the provider actually advertises. It preserves bytes when switching to upload, supports embedded image fallback, and rejects cancellation received during the final read.
- **An in-flight SFTP open could repopulate a disconnected cache.** `acp_sftp_client_cache.dart` invalidates pending opens as well as cached references. The SSH session still owns and closes the shared channel.

### Persistence, authentication, and files

- **Concurrent host preference updates could overwrite each other.** `SettingsService.updateJson` performs read/modify/write inside a database transaction. Host launch preferences use it for both saves and deletions, including calls through separate service instances sharing the database.
- **Disabling authentication could race PIN setup.** `AuthService.disableAuth` now uses the existing PIN write queue. A pending setup finishes before its hash, salt, and enabled flags are removed.
- **Clipboard query failures escaped the intended catch.** `clipboard_sharing_service.dart` awaits the query inside its existing error boundary, preserving the best-effort clipboard behavior.
- **Local download failures could leak an SFTP handle.** `remote_file_service.dart` awaits local file opening and each chunk write, with nested cleanup for both handles. Awaiting writes also prevents the reader from accumulating an unbounded local sink backlog.
- **Public-only keys could not round-trip through migration.** `secure_transfer_service.dart` accepts the existing empty-private-key representation but still requires a string. Deduplication keeps public-only references separate from matching signing keys, preserving private material, passphrases, and host references in either import order. Independent review caught the mixed-record interaction before publication; both orderings failed before the final guard and pass with it.

### SSH and terminal state

- **Late shell negotiation could replace a newer shell.** `ssh_session_runtime.dart` checks the captured shell generation and closing state before installing a negotiated channel. Superseded channels are closed without clearing newer transition state.
- **Shell command substitution removed clipboard trailing newlines.** `remote_clipboard_sync_service.dart` uses a sentinel that is removed before encoding or delivery. Tests execute the generated commands through `/bin/sh` with empty, multiline, quoted, and Unicode text.
- **Hyperlinks could leak between normal and alternate buffers.** `terminal_hyperlink_tracker.dart` retains buffer identity with its anchors and only resolves links in the active buffer. Closing a pending link uses its own buffer's cursor. Empty pending links and the cursor-only row after a newline no longer trigger row fallback.
- **Cleared metadata observation could still deliver a debounced callback.** `terminal_session_controller.dart` cancels the timer and pending flag when observation is cleared, while preserving a different currently observed session.
- **Input state could cross a terminal replacement.** `terminal_text_input_handler.dart` cancels held-key repeats and resets IME/review state when the terminal changes. A pending command approval cannot write into the replacement terminal. Focus and the platform keyboard connection remain intact.
- **CAN/SUB did not cancel a CSI command.** The vendored xterm parser now consumes these cancellation bytes and returns to ground state instead of executing the canceled sequence. Twelve tests cover every split boundary, ordinary text afterward, and subsequent valid CSI. They live under `test/unit` so normal CI runs them.

### Store assets and CI

- **Incomplete manifests could pass validation and replace good media.** `scripts/store_assets.sh` rejects missing and duplicate manifest entries before clearing any destination root. Existing hash, size, allowlist, and archive-link checks remain in place.
- **Destination ancestors could redirect deletion outside the restore directory.** Restore preflights every managed root for symlink or non-directory ancestors, and rejects a manifest-directory collision before deleting media. A managed root that is itself a symlink is safely unlinked without traversing its target.
- **Conditional callers could swallow extraction/download failures.** Explicit error propagation protects the restore paths when Bash disables `errexit` inside a conditional call. Failed workflow downloads cannot install partial artifacts.
- **Python test-only edits did not trigger the check job.** `.github/workflows/ci.yml` includes `test/scripts/**` in change detection and runs the new offline archive suite.

## Behavior-preserving simplifications and optimizations

- Go replay trimming returns immediately when history is already within budget. `testing.AllocsPerRun` verifies zero allocations on this path; the original implementation allocated a history-sized bitmap.
- Hyperlink row fallback tracks one destination and stops at the first distinct destination instead of allocating a set. Repeated links to the same destination still resolve, and ambiguous rows still do not.
- Archive cleanup derives managed roots from its existing allowlist rather than maintaining a second list.
- Host preference saves and deletes share the transactional JSON update operation instead of duplicating read/write logic.

These changes do not alter valid protocol formats or intended UI behavior. Bug fixes deliberately change the failure cases described above. No throughput improvement is claimed without a benchmark.

## Validation

| Check | Result |
| --- | --- |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub --reporter expanded` | 4,046 passed; one opt-in localhost SSH test skipped |
| Full vendored xterm suite, run from `third_party/xterm` with its own dependencies | 358 passed before the 12 new CSI cases were moved into the root suite |
| `GOTOOLCHAIN=go1.26.5 go test -race ./...`, in `remote/monkeymux` | Passed on macOS arm64 |
| Go 1.26.5 Linux amd64 and Windows amd64 test-binary compilation | Passed; not runtime execution |
| Bundled MonkeyMux `0.1.186` assets | Built all six OS/architecture targets; generated assets remain untracked |
| `GOTOOLCHAIN=go1.26.5 go vet ./...` and changed Go formatting | Passed |
| `python3 -m unittest discover -s test/scripts -p 'store_assets_test.py'` | 20 passed |
| Release version resolver and release-note metadata tests | 21 tests / 42 assertions and 4 tests / 15 assertions passed |
| Both store metadata validators | Passed |
| Shell syntax, ShellCheck, and shfmt | Passed |
| Changed Dart formatting and `git diff --check` | Passed |

Regression probes also demonstrated failures on the original implementations for the bridge races/limits, attachment/RPC/cache cases, clipboard newlines, late shell replacement, hyperlink cases, terminal input/metadata/CSI behavior, and archive restore failures. The independent reviews found no remaining blocking issue after the mixed-key preservation fix and CSI test-discovery correction.

The agent's LSP integration produced inconclusive checks and stale partial-file syntax reports. Fresh Dart analysis and executable tests were used for validation; invalid automatic edits were removed rather than accepted as fixes.

## PR review follow-up

A further Astra subagent reviewed all 37 changed files in [PR #808](https://github.com/depollsoft/MonkeySSH/pull/808). The following corrections address both that review and the [manifest count feedback](https://github.com/depollsoft/MonkeySSH/pull/808#discussion_r3946648901):

- Require manifest `file_count` to be an integer equal to the number of entries before clearing media. Ten malformed-count scenarios failed before the correction; the full 20-test archive suite now passes, including legacy archives without a manifest.
- Share pending SSH shell negotiation and teardown. Concurrent ordinary getters receive the same usable shell, failed opens can be retried, and a getter arriving during explicit replacement cannot overtake the requested command. Stale opening cleanup cannot clear a newer future. PTY metadata is committed only for an accepted channel.
- Commit a Go ACP bridge's durable session identity only after a successful setup response. Fast and delayed errors preserve the previous identity. Successful responses without an ID use the requested ID; returned IDs retain precedence.
- Bind RPC timeout, cancellation, and deferred write/encoding cleanup to the original pending record rather than its reusable ID. Old callbacks and cancellation handles cannot remove a newer request.

These runtime regressions were reproduced before fixing them. A separate Astra follow-up review found no remaining blocking issue, with 33 targeted Dart tests/probes, 20 archive tests, and repeated Go race probes passing independently. The final integrated checks passed 4,039 app tests, the complete Go 1.26.5 race suite, analysis, and Linux/Windows test-binary cross-compilation. The helper was bumped to `0.1.185` and all six bundles rebuilt. The earlier PR commit also passed hosted CI, including Linux/Windows Go execution and all five native build targets; those results do not substitute for CI on the follow-up commits.

## User-reported resume bugs

- **iOS requested clipboard access immediately on app resume.** With local clipboard sharing enabled, terminal startup/resume took an initial local clipboard snapshot and started a 750 ms polling timer. Native iOS now skips both automatic read paths, including the callback guard. Explicit Paste still reads text/images/files; permitted OSC 52 queries, remote-to-local updates, and Android opt-in polling remain supported. Settings explain the iOS behavior. A platform-channel regression reproduced the unsolicited read before the change. Seven new widget cases cover iOS/Android startup and resume with sharing on/off, explicit iOS paste, and settings copy at phone width. The affected suites passed 277 tests.
- **The progress bar above a resumed Pi terminal kept spinning after a helper update.** The old process's OSC 9;4 busy marker was saved before shutdown, copied into the new window, and never cleared when Pi resumed idle. Ordinary CLI/shell restore options now discard process-owned progress. Restore-only shell history also strips OSC 9;4 markers so late scrollback replay cannot resurrect the bar after an idle control snapshot. The filter reuses existing terminal-aware parsing and preserves unrelated OSC, links, UTF-8 text, and opaque DCS payloads. Four framing regressions failed before this additional correction and pass afterward. Resume identity and commands are unchanged; normal reconnects and native ACP handoffs that retain the running agent keep their progress. Sixteen portable regression cases failed before the correction and now pass, covering four CLI/shell types and all four progress states. Fresh busy/clear updates still work. The app's control-stream widget test confirms that an idle authoritative snapshot clears the top progress bar.

Independent Astra review caught the history-replay edge case, and a follow-up review found no remaining blocking issue after it was addressed. MonkeyMux `0.1.186` includes the restore correction. All six helper targets were rebuilt. Combined validation passed 4,046 app tests, the complete Go 1.26.5 race suite, analysis, and Linux/Windows test-binary compilation. One opt-in localhost SSH test remains skipped; the native iOS permission popup itself was not exercised on a physical device.

## Limits and follow-up areas

- The skipped `test/integration/acp_ssh_bridge_e2e_test.dart` requires the opt-in localhost SSH environment. No physical-device IME timing, live provider, store API, signing, or publication workflow was exercised.
- Go runtime coverage here is macOS. Linux and Windows were cross-compiled; CI must provide their runtime coverage.
- Archive installation is prevalidated but is not a filesystem transaction. Disk failures and concurrent filesystem changes can still leave a partial installation.
- Overlapping ACP setup responses/writer handover, channel-negotiation deadlines, forwarding-client cleanup, and key-change concurrency deserve further targeted tests.
- The MonkeyMux asset fingerprint still includes Go test files. Removing unnecessary rebuilds was deferred in favor of data-integrity fixes.
