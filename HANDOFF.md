# HANDOFF (package term1)

No edits outside the owned files were required. Two notes for owners of other packages:

1. `lib/presentation/providers/connection_actions.dart` — `disconnectConnectionAndClearMuxCaches(WidgetRef ref, int id)` cannot be called once a
   `ConsumerState` is unmounted (`ref.read` asserts "Using ref when a widget is about to or has been unmounted"). All three terminal_screen
   disconnect sites can run after the screen is popped (they `await` first), so `terminal_screen.dart` now routes them through a small
   `_disconnectConnection` wrapper that uses the helper while mounted and the cached `TmuxService`/`MonkeyMuxService`/`ActiveSessionsNotifier`
   otherwise. If the helper is changed to accept those three services (or a `Ref` that outlives the widget) the wrapper can collapse to one call.

2. `lib/presentation/widgets/monkey_terminal_view.dart` — `MonkeyRenderTerminal` exposes `paintCount` but not the painter's
   `runParagraphCacheLength`. The A1 regression test therefore pins the observable contract (the screen hands the view one `TerminalStyle`
   instance across an unrelated `setState`, and equal styles compare equal, so the render object's `textStyle` setter short-circuits before
   `_clearCaches`). A one-line `@visibleForTesting int get runParagraphCacheLength => _painter.runParagraphCacheLength;` on the render object
   would let the test assert the cache length directly.

Skipped on purpose (not in owned files): the inline `RegExp` constructions in `lib/domain/services/shell_completion_service.dart`
(`_findLikelyPromptEnd`, `escapeWindowsCompletionToken`, E4) and A10.8 (`AcpBuiltinProvider` keychain-unlock decision).
