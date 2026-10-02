import 'package:flutter/foundation.dart';

/// Most recent output characters kept for displaying one client terminal.
///
/// The agent can still read the full `outputByteLimit` buffer through
/// `terminal/output`; the chat only needs the live tail.
const kAcpTerminalDisplayMaxCharacters = 32 * 1024;

/// What the chat shows for a terminal the client runs for an agent.
///
/// Agents embed `{type: "terminal", terminalId}` in tool calls and expect the
/// client to display the live output, and to keep showing it after
/// `terminal/release`. Output and command text are user content: they are
/// rendered only and never logged.
@immutable
final class AcpTerminalDisplay {
  /// Creates a terminal display snapshot.
  const AcpTerminalDisplay({
    required this.terminalId,
    required this.command,
    required this.output,
    this.truncated = false,
    this.exited = false,
    this.exitCode,
    this.signal,
    this.released = false,
  });

  /// Client-assigned terminal identifier.
  final String terminalId;

  /// The command line the agent asked to run, for display.
  final String command;

  /// Most recent output, at most [kAcpTerminalDisplayMaxCharacters].
  final String output;

  /// Whether earlier output was dropped from [output].
  final bool truncated;

  /// Whether the command has exited.
  final bool exited;

  /// Exit code, when the command exited normally.
  final int? exitCode;

  /// Signal name, when the command was terminated by a signal.
  final String? signal;

  /// Whether the agent released the terminal. Output stays visible.
  final bool released;

  /// Returns a copy with the given fields replaced.
  AcpTerminalDisplay copyWith({
    String? output,
    bool? truncated,
    bool? exited,
    int? exitCode,
    String? signal,
    bool? released,
  }) => AcpTerminalDisplay(
    terminalId: terminalId,
    command: command,
    output: output ?? this.output,
    truncated: truncated ?? this.truncated,
    exited: exited ?? this.exited,
    exitCode: exitCode ?? this.exitCode,
    signal: signal ?? this.signal,
    released: released ?? this.released,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpTerminalDisplay &&
          terminalId == other.terminalId &&
          command == other.command &&
          output == other.output &&
          truncated == other.truncated &&
          exited == other.exited &&
          exitCode == other.exitCode &&
          signal == other.signal &&
          released == other.released;

  @override
  int get hashCode => Object.hash(
    terminalId,
    command,
    output,
    truncated,
    exited,
    exitCode,
    signal,
    released,
  );
}
