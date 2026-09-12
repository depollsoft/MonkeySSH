# MonkeyMux current-window quota options

Status: split treatment selected and implemented behind MonkeySSH Pro, with the saved Options > Show usage rings toggle. Earlier comparisons below are design history. See `agent-usage.md` and `usage-rings-acceptance.md` for the production behavior and verification.
Base: origin/main at 839de1e1.
Mode: Operate. Scope: current MonkeyMux window, phone bar and tablet sidebar.

## Current direction

The production MonkeyMux handle wraps the existing agent mark with a Pro-gated
remaining-usage meter. One reported quota uses the full circle, two use halves,
and additional Antigravity groups use equal segments. Claude/Codex five-hour and
weekly quotas keep their established top/bottom order when both are present.

The bar's dimensions, window-switcher gestures, and native identity badges are
preserved. There is no new quota tap action, percentage label, or row. The empty
capacity track is a thin neutral line with at least 3:1 contrast against the
resolved surfaces; remaining allowance uses a heavier, distinctly colored line.

The comparison preview and options below record the design exploration, not an
unchanged production implementation. Captions under comparison samples are
preview annotations only. Current behavior and test evidence live in
`agent-usage.md` and `usage-rings-acceptance.md`.

## Intent

Know how much allowance remains without leaving the terminal or waiting for a limit error. The useful detail is the delight: a quiet gauge that stays honest and never competes with agent activity.

## Options

| Option | Treatment | Tradeoff |
| --- | --- | --- |
| A. Single quota ring, recommended | A thin, non-spinning ring around the existing agent icon. Filled arc means remaining allowance. Show the lowest remaining percentage among confirmed applicable limits. | Smallest footprint; exact quota category needs a label in the expanded view. |
| B. Two rings | Outer ring for short-term allowance, inner ring for weekly allowance. Fixed meanings, no cycling or changing ring order. | Both time horizons visible, but the existing 16dp icon needs a larger surround and two thin tracks may be difficult to distinguish. Not every provider has these two categories. |
| C. Short meter and number | Keep the icon unchanged; add a small horizontal meter and a monospace `28% left` alongside the title. | Most legible and explicit, but costs title width and is awkward in the collapsed tablet rail. |
| D. Icon underline | A short remaining-allowance track directly beneath the icon. | Quietest option and avoids a loading-spinner association; less glanceable and needs a clear zero/unknown distinction. |

## Initial behavior proposal for A, superseded by current direction

- Preserve the agent glyph and its identity. Start with a roughly 26dp surround around the current 16dp icon, subject to device review. Do not increase bar height or reduce touch targets.
- Keep the gauge static between reported updates. No pulse, rotation, glow, or fake continuous consumption.
- Use the resolved theme. A healthy gauge stays quiet; low allowance can use a warning treatment paired with a `12% left` label. Confirm thresholds during implementation rather than implying a provider guarantee.
- Keep existing activity, idle, and alert indicators separate. A quota is not an activity signal.
- Preserve tapping the bar to expand the window switcher. Add a compact account-usage row there with category, percentage remaining, reset time, and last checked age. Its explicit Usage action opens the full breakdown. Do not silently repurpose the existing icon tap or make long press the only route.
- Screen-reader value names both scope and category, for example `Claude account, five-hour allowance, 28 percent remaining`. Do not announce every background refresh.
- At zero, retain an empty track and an explicit exhausted label. If paid overage is available, say the included allowance is exhausted rather than claiming the agent is blocked.
- Unknown, unsupported, unlimited, restricted-without-amount, and stale data are distinct states. Never draw an invented percentage. An unknown account match gets no quota ring, with an explanation in the usage details.
- A passed reset time triggers a bounded refresh. It never automatically fills the ring.

## Data and live-update constraints

The merged account-usage feature already supplies normalized snapshots in `lib/domain/models/agent_usage.dart`, readers through `AgentManagementService.readUsage`, and detailed presentation in `lib/presentation/widgets/agent_usage_summary.dart`. See `docs/agent-usage.md` for provider coverage.

These are account allowances, not consumption attributed to one MonkeyMux window. Some readers inspect inactive saved accounts too. Agent identity alone is not enough to infer the active provider, account, executable, environment override, or model. The existing quota model mostly carries display labels rather than structured selection metadata. Resolve that association explicitly before promising a current-window quota. Do not take a minimum across unrelated saved accounts, model-specific limits, or paid balances.

Reuse the host-side readers and shared cache instead of scraping terminal output. Current successful/throttled snapshots are cached for two minutes. A first version can auto-refresh on that cadence while the terminal is visible and connected, and check freshness on window change or app resume. Stop timers on background/disconnect and discard responses for a previous active window. Respect provider backoff and deduplicate requests. This is live-updating snapshot data, not a real-time stream.

Faster refresh needs an explicit cache/polling policy and provider cost review; it cannot be achieved by adding a one-second UI timer. Prefer provider events only where an existing session genuinely exposes them. Do not send prompts, launch interactive sessions, install tools, or change authentication to obtain usage.

The existing reader is gated through Agent Management. Decide entitlement behavior explicitly before reusing it from the terminal; do not accidentally remove or add a Pro gate.

Keep credentials/raw responses on the host. Do not add usage figures or account identifiers to diagnostics or telemetry.

## Acceptance ledger

Planning checks completed:
- Isolated worktree created from main and fast-forwarded to current origin/main.
- Four alternatives compared against the compact bar and sidebar implementation.
- Existing tap-to-expand behavior traced in `tmux_expandable_bar.dart`.
- Account-wide semantics, provider ambiguity, refresh cache, and entitlement gate identified.

Implementation checks required after direction approval:
- Select only applicable quotas; cover multiple accounts/models, unknown matching, percentages above 100, missing percentages, balances, unlimited categories, restriction-only status, overage, and elapsed resets.
- Verify foreground-only polling, shared requests, backoff, switching during requests, reconnect, disposal, and late-response isolation.
- Widget tests preserve navigation and cover readable semantics, zero versus unknown, narrow widths, large text, dark/light/terminal-driven themes, and reduced motion.
- Inspect actual phone and tablet captures together, fix the resulting defects in one batch, then confirm once.
- Probe a real supported host, including consumption and refresh, without logging private data. Mark unsupported or unverified providers honestly.

## Native comparison evidence

The development-only entry point is `tool/monkeymux_quota_preview.dart`, with registered phone and tablet `@Preview` functions. It uses the real app theme and agent marks with a prototype of the current 44dp bottom handle and 56dp sidebar. The terminal excerpt and quotas are illustrative. No production terminal code, provider registration, entitlement, or polling policy changed.

Single ring has a 28dp outside diameter; two rings use 36dp. Both preserve the 16dp agent mark. The single ring follows the limiting quota; double rings retain fixed short-term/weekly positions. Low quota uses a contrast-adjusted theme warning color, with percentage text on the phone. Tapping either handle reveals sample usage details. The preview supports healthy, short-term-low, weekly-low, exhausted, and unknown states, plus dark/light theme switching.

Validation completed:
- Seven unit/widget checks passed, including contrast, limiting-category selection, controls, details, semantics, and 320/402/1194dp layouts with 150% text scaling.
- Rechecked the three layout cases after correcting the bundled font family.
- Native integration capture and tap-to-expand checks passed on iPhone 17 Pro and iPad Pro 11-inch M5 simulators.
- Inspected both treatments together in healthy-dark, low-dark, and low-light states. One correction/confirmation round fixed the preview font family.

Native PNGs and display contact sheets are in `/tmp/monkeymux-quota-comparison/`. They are not committed. Names use `phone-` or `tablet-` followed by `rings-healthy-dark`, `rings-low-dark`, or `rings-low-light`. Contact sheets are `phone-comparison.png` and `tablet-comparison.png`; the latter crops unused blank space below the comparison. Original captures remain intact.

Reproduce with:

```bash
MONKEYSSH_THEME_PROOF_DIR=/tmp/monkeymux-quota-comparison \
  flutter drive --no-pub --driver=test_driver/theme_proof_driver.dart \
  --target=integration_test/monkeymux_quota_preview_test.dart \
  --flavor private --dart-define=QUOTA_PREVIEW_DEVICE=phone -d <simulator-id>
```

Use `QUOTA_PREVIEW_DEVICE=tablet` for iPad. New worktrees need the usual local MonkeyMux asset bundle before Flutter builds.

## Split-ring comparison evidence

Nine targeted tests pass, adding explicit coverage for top/bottom arc boundaries, independent values, persistent empty tracks, unknown data, and window-only tap behavior. The existing layout, contrast, and accessibility checks remain covered. Native capture tests pass on both iPhone and iPad simulators.

Updated screenshots are in `/tmp/monkeymux-quota-split/`, separate from the original comparison. Each device has `split-healthy-dark`, `split-shortLow-dark`, `split-weekLow-dark`, and `split-weekLow-light` captures. The contact sheets are `phone-comparison.png` and `tablet-comparison.png`. These show the actual Flutter prototypes with illustrative data, not a live account or the production terminal.

Live quota integration and Android/physical-device validation remain out of scope for this visual comparison.
