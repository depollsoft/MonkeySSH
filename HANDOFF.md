# HANDOFF from package term1b (branch refactor/sa5-term1b)

Edits needed outside this package's files. Everything on the term1b side is done
and compiles without them.

## F7: single `contrastRatio` (now exported from `lib/domain/models/terminal_theme.dart`)

- `lib/presentation/widgets/monkey_terminal_view.dart:122-128` — delete the
  private `_contrastRatio` and replace its ~20 call sites with `contrastRatio`
  (the file already imports `terminal_theme.dart`, or add the import). Same body,
  so behaviour is unchanged.
- `lib/app/theme.dart:614-620` — delete `AppTheme._contrastRatio`, import
  `../domain/models/terminal_theme.dart`, replace the 4 call sites with
  `contrastRatio`. Same body.

Why: three byte-identical WCAG helpers; the model file now owns the one copy.

## F2 follow-up: `_sameTerminalTheme` wrappers

`TerminalThemeData.==` is now full value equality and
`terminalThemesMatchForColors(a, b)` is `a == b`. The wrappers at
`lib/domain/services/ssh_service.dart:4914-4922` and
`lib/presentation/screens/terminal_screen.dart:3316-3326` can be deleted and their
call sites written as `previous == next`. Optional; nothing breaks if they stay.
