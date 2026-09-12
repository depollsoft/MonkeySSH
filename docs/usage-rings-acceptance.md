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
- [x] Foreground/connected/visible-only reads share requests, respect the two-minute cache and provider backoff, refresh relevant reset categories, and discard stale-window responses.
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

## History and limits

The branch includes the requested merge of `origin/main` through `d9eb3f04`.
The first weekly-only fix used dashed missing halves. That treatment is now
superseded by the full-circle fallback, so a high remaining allowance no longer
looks like a partly empty two-quota gauge.

Physical-device validation was not performed. Two earlier Windows execution
regressions require PowerShell and were skipped on this Mac. Multi-provider
saved-account stores and pane-local credential overrides remain outside this
feature's account-selection scope.
