import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A single prompt shown to the user during interactive SSH authentication.
///
/// Mirrors one entry of a `keyboard-interactive` info request (or a synthetic
/// password prompt for the `password` authentication method).
@immutable
class SshAuthPrompt {
  /// Creates an [SshAuthPrompt].
  const SshAuthPrompt({required this.prompt, required this.echo});

  /// The prompt label supplied by the server, for example `Password:`.
  final String prompt;

  /// Whether the typed response should be echoed on screen.
  ///
  /// This is `false` for secrets such as passwords and `true` for
  /// non-sensitive values such as one-time-token labels.
  final bool echo;
}

/// A challenge the SSH server issued that requires responses from the user.
///
/// Used to collect a password (or other credentials) interactively when a
/// host has no stored password but the server still requests one.
@immutable
class SshAuthChallenge {
  /// Creates an [SshAuthChallenge].
  const SshAuthChallenge({
    required this.hostLabel,
    required this.username,
    required this.name,
    required this.instruction,
    required this.prompts,
  });

  /// Human-readable destination label, for example `user@host:port`.
  final String hostLabel;

  /// The username being authenticated.
  final String username;

  /// Optional challenge name provided by the server (may be empty).
  final String name;

  /// Optional instruction text provided by the server (may be empty).
  final String instruction;

  /// The prompts to collect responses for, in order.
  final List<SshAuthPrompt> prompts;
}

/// Collects interactive authentication responses from the user.
///
/// Implementations return one response per entry in
/// [SshAuthChallenge.prompts], in the same order, or `null` when the user
/// cancels (which skips the current authentication method).
typedef InteractiveAuthPromptHandler = Future<List<String>?> Function(
  SshAuthChallenge challenge,
);

/// Provider for the optional UI-backed interactive auth prompt handler.
///
/// Defaults to `null` (no interactive prompting). The app overrides this in
/// `main.dart` with a handler that shows a dialog.
final interactiveAuthPromptHandlerProvider =
    Provider<InteractiveAuthPromptHandler?>((_) => null);
