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
- Authenticated live account verification, Android-native capture, and physical-device validation were not performed in this worktree. Parser/SSH command contracts and platform command regressions were exercised by the targeted suite.
