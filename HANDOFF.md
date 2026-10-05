# HANDOFF (package app1, branch refactor/sa5-app1)

## Additive edit in a non-owned file (already applied, please keep)

- `lib/domain/services/terminal_theme_service.dart`: added one line,
  `ref.watch(settingsGenerationProvider);`, at the top of both
  `allTerminalThemesProvider` and `customTerminalThemesProvider`.
  Why: finding #1 replaces `invalidate(settingsServiceProvider)` (a no-op in
  production, where `main.dart` pins the instance with `overrideWithValue`)
  with `invalidate(settingsGenerationProvider)`. These two FutureProviders
  cache custom themes read from settings, so they must watch the generation to
  reload after a migration import. All other `settingsServiceProvider`
  dependents outside this package (ACP services, launch presets, CLI prefs,
  shortcut service, app review) read settings on demand or via DB streams and
  need no change.

## For whoever adds a new settings-backed cache

Any provider that reads a setting once and caches it must
`ref.watch(settingsGenerationProvider)` (see the doc comment in
`lib/domain/services/settings_service.dart`); watching
`settingsServiceProvider` alone does not reload after an import.
