/// Host-side checks for user-defined ACP agents: whether the environment
/// variables a definition names are set, and the agent's own session list.
///
/// Neither path logs commands, arguments, variable values, session titles or
/// directories. The environment probe reports only which requested names are
/// unset; values never leave the host.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_protocol.dart';
import '../models/acp_provider.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_ssh_exec_transport.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _environmentProbeMarker = 'monkeyssh-env-unset:';
const _environmentProbeTimeout = Duration(seconds: 20);
const _sessionListTimeout = Duration(seconds: 30);
const _maxSessionListPages = 10;
final _environmentNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Builds the command that reports which of [names] are unset or empty in
/// the environment an agent launched on the host would see.
///
/// POSIX hosts source the same login profile as a bridge launch, then let a
/// child `/bin/sh` inherit the exported environment, so only exported
/// variables count, as for the agent. Only names are printed.
String buildAcpEnvironmentProbeCommand(
  List<String> names, {
  required bool isWindows,
}) {
  if (names.isEmpty || names.any((n) => !_environmentNamePattern.hasMatch(n))) {
    throw ArgumentError.value(names, 'names');
  }
  if (isWindows) {
    final checks = names
        .map(
          (name) =>
              'if([string]::IsNullOrEmpty(\$env:$name)){'
              '[void]\$__flOut.Append(${powerShellSingleQuote('$_environmentProbeMarker$name')}).Append("`n")};',
        )
        .join();
    return buildWindowsPowerShellCommand(
      powerShellUtf8OutputScript('$powerShellProfilePathPreamble$checks'),
    );
  }
  final checks = names
      .map(
        (name) =>
            '[ -n "\${$name-}" ] || '
            "printf '%s\\n' '$_environmentProbeMarker$name';",
      )
      .join(' ');
  return buildMonkeyMuxAcpPosixShellCommand(
    buildMonkeyMuxAcpProviderCommand([
      '/bin/sh',
      '-c',
      checks,
    ], isWindows: false),
    scriptName: 'monkeyssh-env-check',
  );
}

/// Parses the probe output into the subset of [requested] names reported
/// unset, in [requested] order. Anything else in [output] is ignored.
List<String> parseAcpEnvironmentProbeOutput(
  String output,
  List<String> requested,
) {
  final unset = <String>{};
  for (final line in const LineSplitter().convert(output)) {
    final trimmed = line.trim();
    if (trimmed.startsWith(_environmentProbeMarker)) {
      unset.add(trimmed.substring(_environmentProbeMarker.length));
    }
  }
  return [
    for (final name in requested)
      if (unset.contains(name)) name,
  ];
}

/// Why a custom agent's session list is or is not available.
enum AcpCustomAgentSessionListStatus {
  /// The agent listed its sessions (possibly none).
  listed,

  /// The agent does not advertise `session/list`.
  unsupportedAgent,

  /// Listing over SSH exec is not available on this host (Windows).
  unsupportedHost,

  /// The definition's current command is not approved.
  notApproved,

  /// The agent could not be started or did not answer.
  failed,
}

/// Sessions an agent reported through ACP `session/list`.
final class AcpCustomAgentSessionListing {
  /// Creates a listing.
  const AcpCustomAgentSessionListing(
    this.status, [
    this.sessions = const <AcpSessionInfo>[],
  ]);

  /// Whether the list is available.
  final AcpCustomAgentSessionListStatus status;

  /// Sessions, most recently updated first.
  final List<AcpSessionInfo> sessions;
}

/// Runs host-side checks for user-defined ACP agents over SSH exec.
class AcpCustomProviderHostService {
  /// Creates the service.
  AcpCustomProviderHostService({DiagnosticsLogger? diagnostics})
    : _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final DiagnosticsLogger _diagnostics;

  /// Returns the names in [definition] that are unset or empty on the host,
  /// or `null` when the check could not run. A failed check never blocks a
  /// launch on its own.
  Future<List<String>?> findUnsetEnvironmentVariables(
    SshSession session,
    AcpCustomProviderDefinition definition,
  ) async {
    final names = definition.environmentVariableNames;
    if (names.isEmpty) return const <String>[];
    final startedAt = DateTime.now();
    try {
      final output = await session.runQueuedExec(() async {
        final exec = await openSshExec(
          session.execute(
            buildAcpEnvironmentProbeCommand(
              names,
              isWindows: session.remoteIsWindows,
            ),
          ),
          _environmentProbeTimeout,
        );
        var finished = false;
        try {
          exec.stderr.drain<void>().ignore();
          final text = await utf8
              .decodeStream(exec.stdout)
              .timeout(_environmentProbeTimeout);
          finished = true;
          return text;
        } finally {
          if (finished) {
            exec.close();
          } else {
            await closeAbandonedSshExec(exec);
          }
        }
      });
      final unset = parseAcpEnvironmentProbeOutput(output, names);
      _diagnostics.info(
        'acp.custom',
        'env_probe_complete',
        fields: {
          'connectionId': session.connectionId,
          'requestedCount': names.length,
          'unsetCount': unset.length,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        },
      );
      return unset;
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.custom',
        'env_probe_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Starts the approved agent briefly over SSH exec and asks it for its
  /// sessions through ACP `session/list`, newest first, up to [max].
  Future<AcpCustomAgentSessionListing> listSessions(
    SshSession session,
    AcpCustomProviderDefinition definition, {
    int max = 20,
  }) async {
    if (!definition.isCommandApproved) {
      return const AcpCustomAgentSessionListing(
        AcpCustomAgentSessionListStatus.notApproved,
      );
    }
    if (session.remoteIsWindows) {
      return const AcpCustomAgentSessionListing(
        AcpCustomAgentSessionListStatus.unsupportedHost,
      );
    }
    final startedAt = DateTime.now();
    try {
      final listing = await session.runQueuedExec(
        () => _listSessions(session, definition, max),
        priority: SshExecPriority.low,
      );
      _diagnostics.info(
        'acp.custom',
        'session_list_complete',
        fields: {
          'connectionId': session.connectionId,
          'status': listing.status.name,
          'count': listing.sessions.length,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        },
      );
      return listing;
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.custom',
        'session_list_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return const AcpCustomAgentSessionListing(
        AcpCustomAgentSessionListStatus.failed,
      );
    }
  }

  Future<AcpCustomAgentSessionListing> _listSessions(
    SshSession session,
    AcpCustomProviderDefinition definition,
    int max,
  ) async {
    final command = buildMonkeyMuxAcpPosixShellCommand(
      buildMonkeyMuxAcpProviderCommand(
        definition.launchCommand.argv,
        isWindows: false,
        providerId: definition.id,
      ),
      scriptName: 'monkeyssh-session-list',
    );
    final exec = await openSshExec(
      session.execute(command),
      _sessionListTimeout,
    );
    final client = AcpClient(
      AcpJsonRpcConnection(transport: AcpSshExecTransport(exec)),
    );
    try {
      final initialization = await client.initialize(
        capabilities: const AcpClientCapabilities(
          fileSystem: AcpFileSystemCapabilities(),
          booleanConfigOptions: false,
        ),
        timeout: _sessionListTimeout,
      );
      if (!initialization.agentCapabilities.session.list) {
        return const AcpCustomAgentSessionListing(
          AcpCustomAgentSessionListStatus.unsupportedAgent,
        );
      }
      final sessions = <String, AcpSessionInfo>{};
      final seenCursors = <String>{};
      String? cursor;
      for (var page = 0; page < _maxSessionListPages; page++) {
        final result = await client.listSessions(
          cursor: cursor,
          timeout: _sessionListTimeout,
        );
        for (final info in result.sessions) {
          sessions.putIfAbsent(info.sessionId, () => info);
        }
        cursor = result.nextCursor;
        if (cursor == null ||
            sessions.length >= max ||
            !seenCursors.add(cursor)) {
          break;
        }
      }
      final ordered = sessions.values.toList()
        ..sort(
          (a, b) =>
              acpSessionInfoUpdatedAt(b).compareTo(acpSessionInfoUpdatedAt(a)),
        );
      return AcpCustomAgentSessionListing(
        AcpCustomAgentSessionListStatus.listed,
        List<AcpSessionInfo>.unmodifiable(ordered.take(max)),
      );
    } finally {
      try {
        await client.close();
      } finally {
        // Closing the client only sends EOF; an agent that ignores it would
        // keep the channel and its process. Destroy it after a short grace.
        await closeAbandonedSshExec(exec);
      }
    }
  }
}

/// When [info] was last updated, for ordering; unknown sorts last.
DateTime acpSessionInfoUpdatedAt(AcpSessionInfo info) =>
    switch (info.updatedAt) {
      final String value => DateTime.tryParse(value),
      final int value => DateTime.fromMillisecondsSinceEpoch(value),
      _ => null,
    } ??
    DateTime.fromMillisecondsSinceEpoch(0);

/// Provider for [AcpCustomProviderHostService].
final acpCustomProviderHostServiceProvider =
    Provider<AcpCustomProviderHostService>(
      (ref) => AcpCustomProviderHostService(),
    );
