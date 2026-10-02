/// Domain types for completing an ACP agent's advertised sign-in methods.
///
/// Only identifiers, coarse kinds, and the agent-provided method descriptors
/// live here. Nothing in this file is logged or persisted: method names and
/// descriptions come from the agent and are shown to the user only.
library;

import 'package:flutter/foundation.dart';

import '../services/acp_json_rpc_connection.dart';
import 'acp_protocol.dart';
import 'acp_session_state.dart';

/// ACP's `auth_required` JSON-RPC error code.
const acpAuthRequiredErrorCode = -32000;

/// Generous deadline for an `agent` method's `authenticate` request.
///
/// Agent-run login flows can wait on a browser OAuth round-trip or a device
/// code typed on another device, so the normal short control-request deadline
/// would be a false failure. The user can still abandon the wait sooner.
const acpAgentAuthenticationTimeout = Duration(minutes: 10);

final _environmentNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Maximum number of environment overrides accepted from one terminal method.
const acpTerminalAuthMaxEnvironmentEntries = 64;

/// Maximum number of extra arguments accepted from one terminal method.
const acpTerminalAuthMaxArguments = 64;

/// Whether [name] is a portable environment variable name that can be applied
/// verbatim in both POSIX shells and PowerShell without quoting.
bool isValidAcpAuthEnvironmentName(String name) =>
    _environmentNamePattern.hasMatch(name);

/// Whether MonkeySSH can complete [method] itself.
///
/// `agent` methods are completed over the ACP connection with `authenticate`.
/// `terminal` methods are completed by rerunning the configured agent program
/// in an interactive terminal; they are usable only when every argument and
/// environment override can be passed through literally. Unknown method types
/// (including the retired `env_var` draft) are never usable.
bool isUsableAcpAuthMethod(AcpAuthMethod method) {
  if (method.id.isEmpty) return false;
  if (method.isAgent) return true;
  if (!method.isTerminal) return false;
  if (method.args.length > acpTerminalAuthMaxArguments ||
      method.env.length > acpTerminalAuthMaxEnvironmentEntries) {
    return false;
  }
  if (method.args.any((value) => value.contains('\u0000'))) return false;
  for (final entry in method.env.entries) {
    if (!isValidAcpAuthEnvironmentName(entry.key) ||
        entry.value.contains('\u0000')) {
      return false;
    }
  }
  return true;
}

/// Returns the advertised methods MonkeySSH can complete, in agent order.
List<AcpAuthMethod> usableAcpAuthMethods(Iterable<AcpAuthMethod> methods) =>
    List<AcpAuthMethod>.unmodifiable(methods.where(isUsableAcpAuthMethod));

/// Runs an `agent` method's `authenticate` request on the live connection.
///
/// Completes with `null` on success or a safe, displayable error. It never
/// throws, so a caller may stop waiting (cancel) without leaving an unhandled
/// asynchronous error behind. Cancelling [cancellation] also tells the agent,
/// with `$/cancel_request`, to stop its login flow.
typedef AcpAgentAuthenticator = Future<AcpSessionError?> Function(
  AcpAuthMethod method, {
  AcpRequestCancellation? cancellation,
});

/// Asks the UI how to satisfy an agent's authentication requirement while a
/// launch or reconnect is in progress.
///
/// Returning `null` declines: the launch fails with
/// [AcpSessionErrorKind.authenticationRequired] exactly as it would without a
/// chooser.
typedef AcpAuthenticationChooser = Future<AcpAuthenticationChoice?> Function(
  AcpAuthenticationRequest request,
);

/// Everything the UI needs to let the user pick an advertised sign-in method.
@immutable
final class AcpAuthenticationRequest {
  /// Creates an authentication request.
  AcpAuthenticationRequest({
    required this.hostId,
    required this.providerId,
    required this.providerLabel,
    required List<AcpAuthMethod> methods,
    required this.authenticate,
  }) : methods = List<AcpAuthMethod>.unmodifiable(methods);

  /// Saved host the agent runs on.
  final int hostId;

  /// Provider whose agent requires sign-in.
  final String providerId;

  /// Provider display label.
  final String providerLabel;

  /// Advertised methods MonkeySSH can complete, in agent order.
  final List<AcpAuthMethod> methods;

  /// Completes an `agent` method on the live connection.
  ///
  /// Must only be called with an `agent` method from [methods]; terminal
  /// methods are never sent to `authenticate`.
  final AcpAgentAuthenticator authenticate;
}

/// The user's resolution of an [AcpAuthenticationRequest].
@immutable
sealed class AcpAuthenticationChoice {
  const AcpAuthenticationChoice();
}

/// An `agent` method's `authenticate` already succeeded; the session setup
/// that required sign-in should be retried once on the same connection.
@immutable
final class AcpAuthenticationCompleted extends AcpAuthenticationChoice {
  /// Creates a completed choice.
  const AcpAuthenticationCompleted();
}

/// The user picked a `terminal` method.
///
/// The launch fails and carries an [AcpTerminalAuthLaunch]; after that
/// terminal exits successfully the caller starts a fresh launch, which
/// reconnects and reinitializes the agent.
@immutable
final class AcpAuthenticationInTerminal extends AcpAuthenticationChoice {
  /// Creates a terminal choice.
  const AcpAuthenticationInTerminal(this.method);

  /// The selected `terminal` method.
  final AcpAuthMethod method;
}

/// A ready-to-run interactive login for a `terminal` method.
///
/// [argv] is the provider's configured launch argv followed by the method's
/// `args`; [environment] holds the method's overrides. It is never logged.
@immutable
final class AcpTerminalAuthLaunch {
  /// Creates a terminal login launch.
  AcpTerminalAuthLaunch({
    required this.hostId,
    required this.providerId,
    required this.providerLabel,
    required this.method,
    required List<String> argv,
    required Map<String, String> environment,
    required this.workingDirectory,
  }) : argv = List<String>.unmodifiable(argv),
       environment = Map<String, String>.unmodifiable(environment);

  /// Builds the launch for [method] from the provider's base [launchArgv].
  factory AcpTerminalAuthLaunch.forMethod({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required AcpAuthMethod method,
    required List<String> launchArgv,
    required String workingDirectory,
  }) => AcpTerminalAuthLaunch(
    hostId: hostId,
    providerId: providerId,
    providerLabel: providerLabel,
    method: method,
    argv: <String>[...launchArgv, ...method.args],
    environment: method.env,
    workingDirectory: workingDirectory,
  );

  /// Saved host to run the login on.
  final int hostId;

  /// Provider whose agent program is rerun.
  final String providerId;

  /// Provider display label.
  final String providerLabel;

  /// The `terminal` method being completed.
  final AcpAuthMethod method;

  /// Agent program argv: base launch argv plus the method's arguments.
  final List<String> argv;

  /// Environment overrides applied over the base launch environment.
  final Map<String, String> environment;

  /// Working directory of the base launch configuration.
  final String workingDirectory;
}
