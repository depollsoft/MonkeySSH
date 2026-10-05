# Handoff from package mux2 (branch refactor/sa5-mux2)

## Needs an edit in `lib/domain/services/tmux_service.dart` (not owned by mux2)

Finding #10, "client commands behind the backend abstraction": the
`_type == TerminalBackendType.monkeyMux && monkeyMuxService != null` branch in
`_MultiplexedTerminalConnectionBackend.runClientCommand` and the `capabilities`
type switch in `lib/domain/services/terminal_connection_backend_service.dart`
were left in place because removing them requires `TmuxService` to implement a
new interface member. `TmuxService implements RemoteMultiplexerService`, so any
member added to the interface must be implemented there.

Exact change once `tmux_service.dart` is editable:

1. In `lib/domain/services/remote_multiplexer_service.dart` add to
   `RemoteMultiplexerService`:

   ```dart
   /// Whether client commands run through the backend control channel.
   bool get clientCommandsUseControlChannel;

   /// Runs a short-lived client command on the backend's best channel.
   Future<TerminalClientCommandResult> runClientCommand(
     SshSession session,
     String sessionName,
     String command, {
     SshExecPriority priority = SshExecPriority.normal,
   });
   ```
2. In `tmux_service.dart`, implement `clientCommandsUseControlChannel => false`
   and `runClientCommand` by moving `_runSshClientCommand` (and the two
   `_clientCommand*Timeout` constants) from
   `terminal_connection_backend_service.dart` next to it.
3. `MonkeyMuxService` already has `runClientCommand`; add
   `clientCommandsUseControlChannel => true`.
4. In `terminal_connection_backend_service.dart` delete the `monkeyMuxService`
   field/parameter of `_MultiplexedTerminalConnectionBackend`, the
   `_tmuxCapabilities`/`_monkeyMuxCapabilities` constants and the type switch;
   build `TerminalBackendCapabilities(clientCommandsUseControlChannel:
   _remoteMultiplexer.clientCommandsUseControlChannel)` and delegate
   `runClientCommand` to `_remoteMultiplexer`. `_DirectTerminalConnectionBackend`
   keeps calling the moved SSH helper directly.
5. Update `_FakeRemoteMultiplexerService` in
   `test/domain/services/terminal_connection_backend_service_test.dart` (and
   the fake in `test/presentation/...` if any) to implement the two members.

## Optional follow-ups for the tmux_state / tmux_service owners

- `lib/domain/models/terminal_backend.dart` now exports
  `String? trimmedOrNull(String? value)`. `tmux_state.dart:_nonEmpty` and
  `tmux_service.dart:_nonEmptyTmuxPaneField` are the same helper and can be
  replaced by it (it accepts a nullable argument).

## Small additive edit outside mux2 ownership

- `test/domain/services/agent_session_discovery_service_test.dart`: removed the
  `supportsWindows: true, supportsClientCommands: true,` arguments from two
  `const TerminalBackendCapabilities(...)` literals, because those fields were
  deleted (finding #9). No other change in that file.
