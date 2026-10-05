import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'live_ssh_terminal_helpers.dart';

void main() {
  testWidgets('waitForTerminalText reports the buffer at the timeout', (
    tester,
  ) async {
    final terminal = Terminal()..write('before');
    Timer(const Duration(milliseconds: 50), () => terminal.write(' after'));
    String? message;
    try {
      await waitForTerminalText(
        tester,
        () => terminal,
        'never',
        description: 'missing text',
        timeout: const Duration(milliseconds: 300),
      );
    } on TestFailure catch (failure) {
      message = failure.message;
    }
    expect(message, contains('missing text'));
    expect(message, contains('before after'));
  });
}
