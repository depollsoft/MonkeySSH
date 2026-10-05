# HANDOFF (package acp5)

Edits needed outside this package's owned files. Everything on this side
compiles and passes without them; they remove the last two copies of the
concurrency flow and one sign-in copy flow.

## lib/presentation/screens/terminal_screen.dart (owned by another package)

### 1. Use `resolveAcpConcurrencyBlock` at the two `showAcpConcurrencyChoice(` sites

New helper (this package): `resolveAcpConcurrencyBlock(context, ref, decision,
{required Future<AcpSessionLaunchResult?> Function(List<AcpSessionKey> replace)
relaunch, bool allowStopAndContinue = true, Future<void>? cancellation})` in
`lib/presentation/widgets/acp_concurrency_choice.dart`. It shows the sheet,
maps `decision.blockingSessionKeys` through `manager.state.byKeyValue`, pushes
`/upgrade?feature=concurrentAcpSessions` and re-reads
`monetizationServiceProvider.currentState.isProUnlocked`, then calls
`relaunch(blocking)` or `relaunch(const [])`. It returns `null` when the user
backs out, stays locked, or the context unmounts.

- Site A (around line 9381, native window launch):

  ```dart
  var result = await launch();
  if (result is AcpSessionLaunchBlocked && mounted) {
    result = await resolveAcpConcurrencyBlock(
      context,
      ref,
      result.decision,
      relaunch: (replace) => launch(replace: replace),
    );
    if (!mounted || result == null) return;
  }
  ```

  `launch` must accept `List<AcpSessionKey> replace` (it already does).

- Site B (around line 9832, reconnect with transport retry): the same shape
  with `relaunch: (replace) => reconnectWithTransportRetry(replace: replace)`
  and `cancellation: cancellation`. The helper returns `null` for "choice ==
  null" and "upgrade not unlocked"; both currently call
  `restoreTerminalAfterFailedHandoff()`, so keep that on a `null` result. The
  `requestGeneration != _nativeAcpWindowRequestGeneration` check between the
  sheet and the relaunch has no slot in the helper; if that ordering matters,
  keep the generation check after the helper returns (the relaunch result is
  discarded by the existing guard anyway).

Why: Part 5 finding 11 (five copies of the free-tier concurrency resolution
flow). Three copies are gone; these are the remaining two.

### 2. Optional: `copyAcpTerminalAuthCommand` for the sign-in snackbar (around line 9436)

`copyAcpTerminalAuthCommand(context, ref, {providerId, hostId})` in
`acp_connection_support.dart` resolves (passing the host's live SSH session
unconditionally), copies to the clipboard, and shows the
"Sign-in command copied — run it in the terminal." snackbar. The terminal
screen's variant adds the Cursor keychain action to the error snackbar, so it
is a different surface; only `resolveAcpTerminalAuthCommand` is shared. No
change required: `resolveAcpTerminalAuthCommand` keeps its signature and now
substitutes the installed probe candidate for every provider whose sign-in
executable is among its probe candidates (Copilot, OpenCode, Cursor, Hermes,
OpenClaw, Grok), not only OpenCode.

## lib/domain/services/acp_session_manager.dart (additive edit made here)

`forkSession(AcpSessionKey key, {List<AcpSessionKey> replace = const []})`
gained the `replace` parameter (stops those sessions via `_stopAll` before the
concurrency evaluation, like `startNewSession`/`reconnectSession`). The test
fake `test/support/fake_acp_session_manager.dart` mirrors it
(`forkReplaceKeys`, and `stopped` receives the replaced keys).
