# HANDOFF: term4 (terminal IME engine / text input handler)

Edits made outside the owned files (all needed to keep the tree compiling after
removing `manageFocus`, `deleteDetection` and the private regex copies):

- `lib/presentation/screens/terminal_screen.dart` (~12795): deleted the two
  argument lines `deleteDetection: true,` and `manageFocus: false,` from the
  `TerminalTextInputHandler(...)` construction. Both parameters no longer exist;
  production behaviour is unchanged (they were the only values ever passed).
- `lib/presentation/widgets/acp_sign_in_terminal.dart` (~388): deleted the
  same two argument lines plus the orphaned comment
  `// The terminal view already owns this focus node.`.
- `lib/domain/models/auto_connect_command.dart`: renamed the private
  `_multilinePattern` to the exported `terminalNewlinePattern` (one
  declaration, one use) and added the exported
  `terminalControlCharacterPattern` (`[\x00-\x1f\x7f-\x9f]`). The IME engine
  imports both instead of keeping private copies.
- `integration_test/terminal_text_input_handler_validation_test.dart` and
  `integration_test/terminal_system_selection_test.dart`: removed the
  `deleteDetection: true` argument and wrapped the handler's child in
  `Focus(focusNode: focusNode, ...)` with an explicit `focusNode.requestFocus()`
  (the handler no longer installs its own `Focus(autofocus: true)`; production
  always owned the focus node externally). These integration tests were not run
  here.

Follow-ups for other packages:

- `lib/domain/services/remote_file_service.dart:13`
  `_terminalControlCharacterPattern` is byte-identical to the new
  `terminalControlCharacterPattern` in `auto_connect_command.dart`; delete the
  private copy and import the shared one.
- `lib/presentation/screens/terminal_screen.dart`
  `_shellOutputLooksLikePromptReturn` (~6170) and its helpers
  `_isPromptReturnWhitespaceCodeUnit` (~127) / `_isPromptReturnAsciiLetterOrDigit`
  (~175) duplicate the scan now in
  `lib/presentation/widgets/terminal_prompt_tail.dart`. Replace the body with:

  ```dart
  final tail = scanPromptTail(stripTerminalPromptEscapeSequences(data));
  return !tail.endsAtLineStart && (tail.promptMarkerLength ?? 0) > 0;
  ```

  and delete the two private helpers (`terminal_screen_policy.dart` was not
  touched because another package owns it).
