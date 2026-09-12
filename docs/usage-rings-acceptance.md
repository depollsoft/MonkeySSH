# Usage rings implementation acceptance

## Current behavior

- [x] Zero used starts full; the colored arc represents remaining quota and drains to empty as usage increases.
- [x] One reported quota uses a full circle, two use top/bottom halves, and additional Antigravity groups use separate segments. There are no dashed placeholders or unused empty halves.
- [x] Claude Code and Codex use account-wide five-hour/weekly quotas without substituting scoped model limits. Codex weekly-only responses use a full-circle weekly meter.
- [x] Grok Build uses included-credit percentage, excluding paid spending caps and prepaid balances without a comparable allowance.
- [x] Antigravity uses reported numerical groups in stable label order, without inventing an active model. Live reader returned four distinct numerical buckets.
- [x] The existing MonkeyMux bar height, gestures, agent marks, and native badges remain intact. No quota-specific tap action or extra row.
- [x] Options has exactly `Show usage rings`, saved app-wide and on by default for Pro. Free accounts get a Pro badge and upgrade flow; no quota checks run without Pro.
- [x] Persisted opt-out loads before any reads. Losing Pro hides meters and cancels refreshes without overwriting the preference.
- [x] Foreground/connected/visible-only reads share requests, respect the per-agent cache and provider backoff, refresh relevant reset categories, and discard stale-window responses.
- [x] Missing, unlimited, duplicate, unreported, or expired percentages are never inferred as zero or 100%. If no usable allowance remains, the original icon is shown.
- [x] No quota values, account identifiers, credentials, or user content added to application diagnostics or telemetry.

## Verification

- 41 current projection, ring-widget, provider/lifecycle, Options, and Agent Management summary checks passed.
- Exact painter assertions cover 100%, 77%, 25%, and 0% remaining for whole-circle and split modes, plus independent labeled group segments.
- Grok and Antigravity provider tests verify initial full meters and reset refreshes for their own category names.
- Native integration passed on the Android phone emulator with JDK 17 and on the iPad simulator. Captures show Codex full-to-empty progression, four Antigravity groups, Grok included credits, and Pro/on/off Options states.
- Read-only live quota probes succeeded for Codex, Antigravity, and Grok. Codex reported only the normal account's weekly limit; Antigravity returned four numerical buckets; Grok returned one included-credit percentage. No prompts, installs, resets, or account modifications were performed.
- Prior service/settings/Pro registration, telemetry allowlist, and navigation/layout regression coverage remains in the branch. The post-change navigator/layout checks were rerun for the expanded agent support.

Native fixture entry point: `tool/usage_rings_feature_preview.dart`.
Capture test: `integration_test/usage_rings_feature_test.dart`.
Current PNGs: `/tmp/monkeymux-usage-rings-expanded/`, including `android-meter-states.png` and `ipad-extra-agent-states.png`. These are labeled sample-data fixtures using production components, not screenshots of authenticated account readings.

## Claude usage throttling follow-up

- [x] Reproduced the bug with fake SSH: checking Codex after a Claude 429 erased the old per-selection cache, so returning to Claude made a third request instead of reusing its cooldown.
- [x] Preserve unrelated successful and throttled snapshots when a single-agent ring updates the shared cache. Retained reset markers are bounded to currently relevant reset times.
- [x] Preserve sanitized HTTP Retry-After seconds/date hints through direct and multi-provider readers. HTTP-date parsing uses the server Date header when available to avoid host clock skew.
- [x] Keep bounded cooldown metadata per saved host/agent across SSH reconnects and path changes, without sharing quota values across sessions.
- [x] Back off repeated throttles for 5, 10, 20, then 30 minutes, or longer when the provider requires it. Partial failures and unrelated reads do not reset or extend that deadline spuriously.
- [x] Poll Claude normally at five minutes and other agents at two. Ring timers honor longer cooldowns, and a short freshness grace avoids hiding a valid meter during the scheduled request.
- [x] Show the next allowed check time in Agent Management without a countdown timer or any additional provider request.

Validation: 114 combined parser/service/ring/summary checks passed, plus targeted
success-cache, partial-backoff, and reset-marker regressions; two existing
PowerShell-dependent cases skipped on this Mac. All 30 Node usage-probe tests
passed, including a local HTTP 429 server. The projection/ring suite also passed
34 checks after the polling freshness adjustment. The native simulated-throttle
fixture passed on Android with JDK 17 and on iPad; images are under
`/tmp/monkeymux-usage-cooldown/`. The normal Agent Management screen suite was
rerun for the new summary line and preview helper.

**No live Claude request was made while investigating this rate-limit report.**
The API must still allow the cooldown to expire; the fix prevents premature
retries rather than attempting to bypass provider throttling.

## PR review corrections

- [x] Explicit runtime re-check, full refresh, and install/update completion invalidate the corresponding usage-path cache without clearing provider cooldowns. Generation guards prevent late path probes from restoring stale negative entries, and failed/incomplete probes are not cached as missing installations.
- [x] Ring cancellation is checked after service-queue waits, after asset loading, and at actual SSH-queue dispatch. Coalesced live consumers keep their request; already-dispatched responses still record provider cooldowns without publishing to cancelled callers.
- [x] The Options checkbox persists the selected callback value, including when the persisted setting is still loading.
- [x] Empty capacity tracks use opaque, alpha-composited theme colors with at least 3:1 contrast in light and dark themes. The track is thinner than remaining-quota strokes, so the two states differ by both color and weight.
- [x] Current-direction wording describes preserved bar invariants rather than claiming production code is untouched. The PR summary explicitly states five-minute Claude polling, two minutes for other agents, and successful Android/iPad fixture validation.

- [x] An independent presentation timer expires stale snapshots and elapsed quota windows even while SSH refresh work is queued. Fresh responses reschedule expiry; disposal/backgrounding cancel it. Expiry never starts an extra provider request. Two additional regressions cover a blocked refresh beyond the freshness deadline and replacement of the old expiry timer.

The focused review suite covers ten runtime/queue race cases, plus loading-state
checkbox and actual painted-track contrast regressions. The existing service and
widget suites were exercised as well. No live provider requests were made for
these review fixes.

## History and limits

The branch includes the requested merge of `origin/main` through `d9eb3f04`.
The first weekly-only fix used dashed missing halves. That treatment is now
superseded by the full-circle fallback, so a high remaining allowance no longer
looks like a partly empty two-quota gauge.

Physical-device validation was not performed. Two earlier Windows execution
regressions require PowerShell and were skipped on this Mac. Multi-provider
saved-account stores and pane-local credential overrides remain outside this
feature's account-selection scope.
