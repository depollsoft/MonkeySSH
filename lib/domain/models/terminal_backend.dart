import 'package:flutter/foundation.dart';

import 'remote_multiplexer.dart';

/// Terminal transport currently serving an interactive SSH session.
enum TerminalBackendType {
  /// Plain SSH shell without a remote multiplexer.
  direct,

  /// Remote host tmux backend.
  tmux,

  /// Bundled MonkeyMux helper backend.
  monkeyMux,
}

/// Presentation helpers for [TerminalBackendType].
extension TerminalBackendTypePresentation on TerminalBackendType {
  /// The corresponding remote multiplexer backend, when this is multiplexed.
  RemoteMuxBackend? get remoteMuxBackend => switch (this) {
    TerminalBackendType.direct => null,
    TerminalBackendType.tmux => RemoteMuxBackend.tmux,
    TerminalBackendType.monkeyMux => RemoteMuxBackend.monkeyMux,
  };
}

/// Capabilities exposed by a terminal backend.
@immutable
class TerminalBackendCapabilities {
  /// Creates a terminal backend capability set.
  const TerminalBackendCapabilities({
    required this.supportsWindows,
    required this.supportsClientCommands,
    required this.clientCommandsUseControlChannel,
  });

  /// Whether the backend can list, create, select, and close windows.
  final bool supportsWindows;

  /// Whether the backend can run short-lived client command probes.
  final bool supportsClientCommands;

  /// Whether client commands run through the backend control channel.
  final bool clientCommandsUseControlChannel;
}

/// Output from a backend-scoped client command.
@immutable
class TerminalClientCommandResult {
  /// Creates a client command result.
  const TerminalClientCommandResult({required this.output, this.exitCode});

  /// Combined output returned by the backend.
  final String output;

  /// Remote process exit code when the backend can report one.
  final int? exitCode;

  /// Whether the command reported a successful exit.
  bool get succeeded => exitCode == null || exitCode == 0;
}
