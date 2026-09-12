# Usage rings implementation acceptance

- [x] Split arcs wrap the current MonkeyMux agent mark on phone and sidebar; no new gesture, label, row, or bar height. Native badges retain extra clearance.
- [x] Options has exactly `Show usage rings`, persisted app-wide and on by default for Pro. Free accounts get a Pro badge and the correct upgrade feature.
- [x] Pro entitlement and the initialized preference gate display and remote reads. Revocation hides rings and cancels refreshes without overwriting opt-out.
- [x] Only foreground, connected, visible active-agent readers run. No upstream version metadata or installations. Shared requests, two-minute cache cadence, reset refresh, late-response isolation.
- [x] The account-wide five-hour/weekly projection rejects ambiguous, model-specific, stale, expired-reset, unlimited, and unreported percentages. No inferred zero or replenishment.
- [x] Feature enum, paywall copy, setting key, providers, Options registration, and widget wrapper verified in production source.
- [x] Focused model, service, settings, widget, lifecycle, menu and entitlement tests pass. Direct provider refresh probes and native screenshots use production components.
- [x] No credentials, quota values, paths, or user content added to diagnostics/telemetry. Only the paywall feature token was added to its existing allowlist.

## Verification evidence

- 150 domain/model/settings/management-service checks passed. Two existing Windows execution cases skip without PowerShell on this Mac.
- 171 existing navigator, terminal-layout, and upgrade-screen regression checks passed.
- 14 production feature widget tests passed, including shared readers, stale-window response isolation, reset/backoff behavior, covered routes, backgrounding, Pro revocation, opt-out, checkbox persistence interaction, and upgrade routing.
- The updated telemetry allowlist test passed.
- Native integration checks passed on iPhone 17 Pro and iPad Pro 11-inch M5 simulators. The native pass caught a dismissed-menu WidgetRef lifetime bug; the fix captures stable owners before menu dismissal, with a widget regression test and native confirmation.
- Native PNGs are in `/tmp/monkeymux-usage-rings-feature/`. They show production ring/provider/menu components in a labeled fixture with sample quotas, not authenticated live account readings. The fixture entry point is `tool/usage_rings_feature_preview.dart`; capture test is `integration_test/usage_rings_feature_test.dart`.

## Deliberate limits

- Rings currently use Claude Code and Codex account-wide `5 hours`/`Weekly` buckets. Multi-provider agents and scoped model caps remain unprojected rather than guessing an active account/model.
- The reader uses the host CLI credential context, not pane-local credential overrides. These are account allowances, not per-window consumption.
- Already-started remote requests are bounded and their results are discarded after cancellation; the feature does not forcibly kill unrelated shared Agent Management reads.
- Authenticated live account verification and physical-device validation were not performed. Parser/SSH command contracts and platform command regressions were exercised by the targeted suite.

## Reported Codex mismatch follow-up

- [x] Merged `origin/main` at `d9eb3f04` into the PR branch before applying the correction.
- [x] Reproduced the supplied screenshot's account-wide weekly bucket with 23% used, plus separate model-specific five-hour/weekly buckets with 0% used.
- [x] Confirmed both the account summary and the ring use 77% remaining, not 23%. Model-specific 100% allowances are not substituted for a missing account-wide five-hour allowance.
- [x] Corrected the misleading presentation: an unreported half now uses six short dashes, while zero is an empty continuous track. Both missing still means no ring.
- [x] Added exact painter assertions for 0%, 77%, and 100% remaining, the dashed state, and accessible unreported/remaining labels.
- [x] 179 targeted Dart model/widget/summary/navigator/layout cases passed across the post-merge regression run and the corrected Canvas-float-tolerance assertion. All 27 Node usage-probe tests passed.
- [x] Native integration passed on an Android phone emulator with JDK 17 and the iPad simulator. Both exercise the screenshot-shaped data and Pro/on/off menu behavior.

Updated native PNGs are in `/tmp/monkeymux-usage-rings-correction/`; the screenshot-case filenames end in `codex-weekly-77-unreported-short-term.png`. They are labeled fixtures using the production provider and painter, not authenticated live readings.
