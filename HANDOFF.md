# w2-app handoff

Optional follow-ups outside this package's files (the tree compiles and tests pass without them):

1. `lib/presentation/screens/terminal/terminal_screen_policy.dart`: `_minTerminalFontSize`,
   `_maxTerminalFontSize` and `clampTerminalFontSize` duplicate the shared range now in
   `lib/domain/services/settings_service.dart` (`minFontSize`, `maxFontSize`, `clampFontSize`).
   Change: make `clampTerminalFontSize(num size) => clampFontSize(size);` and delete the two
   private constants. Why: finding app #8 wants one range for terminal zoom, chat zoom,
   persistence and the Settings slider.
2. `lib/presentation/screens/remote_text_editor_screen.dart`: `_minRemoteEditorFontSize` /
   `_maxRemoteEditorFontSize` (8/32) are the same range; replace them with
   `minFontSize` / `maxFontSize`. Same reason.
3. Finding app #6 residue: host membership is still recomputed per host row on every
   sessions-map republish (inside `_hostConnectionIdsProvider`, which now only notifies on a
   real change). Removing that scan needs `ActiveSessionsNotifier` (`ssh_service.dart`, owned by
   w2-ssh) to keep a host-to-connections index updated on connect/disconnect, or to republish
   preview ticks through a separate per-connection revision. `getConnectionsForHost` is cheap
   (one pass over sessions), so this is low priority.
