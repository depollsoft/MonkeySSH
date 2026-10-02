import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_json.dart';
import 'acp_mcp_server.dart';
import 'acp_protocol.dart';

/// Maximum additional workspace directories on one session.
const kAcpMaxAdditionalDirectories = 16;

/// Maximum MCP servers attached to one session.
const kAcpMaxSessionMcpServers = kAcpMcpServerMaxCount;

/// Per-session workspace choices made when launching a native agent session:
/// which configured MCP servers to attach and which extra directories to
/// expose alongside the working directory.
@immutable
final class AcpSessionWorkspaceOptions {
  /// Creates workspace options.
  ///
  /// A `null` [mcpServerIds] means "no explicit choice": the servers marked
  /// "use by default" are attached. An empty list attaches none.
  AcpSessionWorkspaceOptions({
    List<String>? mcpServerIds,
    List<String> additionalDirectories = const <String>[],
  }) : mcpServerIds = mcpServerIds == null
           ? null
           : List<String>.unmodifiable(mcpServerIds),
       additionalDirectories = List<String>.unmodifiable(additionalDirectories);

  /// Local ids of the configured MCP servers to attach, or `null` to attach
  /// the defaults.
  final List<String>? mcpServerIds;

  /// Remote directories (absolute, or `~`-relative for a new session) to add
  /// to the session's root set.
  final List<String> additionalDirectories;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionWorkspaceOptions &&
          const ListEquality<String>().equals(
            mcpServerIds,
            other.mcpServerIds,
          ) &&
          const ListEquality<String>().equals(
            additionalDirectories,
            other.additionalDirectories,
          );

  @override
  int get hashCode => Object.hash(
    mcpServerIds == null
        ? null
        : const ListEquality<String>().hash(mcpServerIds),
    const ListEquality<String>().hash(additionalDirectories),
  );

  // Paths are user data: never include them.
  @override
  String toString() =>
      'AcpSessionWorkspaceOptions(mcpServers: ${mcpServerIds?.length}, '
      'additionalDirectories: ${additionalDirectories.length})';
}

/// The session-setup parameters actually sent to one agent, after filtering
/// the requested workspace by the agent's advertised capabilities.
@immutable
final class AcpSessionWorkspaceSetup {
  /// Creates a setup plan.
  AcpSessionWorkspaceSetup({
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    List<String> additionalDirectories = const <String>[],
    this.unsupportedMcpServerCount = 0,
    this.unreadableMcpServerCount = 0,
    this.additionalDirectoriesUnsupported = false,
  }) : mcpServers = List<AcpJsonMap>.unmodifiable(mcpServers),
       additionalDirectories = List<String>.unmodifiable(additionalDirectories);

  /// ACP `McpServer` objects to send.
  final List<AcpJsonMap> mcpServers;

  /// Additional directories to send (empty when unsupported).
  final List<String> additionalDirectories;

  /// Selected servers skipped because the agent lacks their transport.
  final int unsupportedMcpServerCount;

  /// Selected servers skipped because their secrets could not be read.
  final int unreadableMcpServerCount;

  /// Whether directories were requested but the agent does not advertise
  /// `sessionCapabilities.additionalDirectories`.
  final bool additionalDirectoriesUnsupported;

  /// A short, content-free notice describing anything that was not sent, or
  /// `null` when everything requested was sent.
  String? get notice {
    final parts = <String>[];
    if (unsupportedMcpServerCount > 0) {
      final count = unsupportedMcpServerCount;
      parts.add(
        count == 1
            ? '1 MCP server was skipped because this agent does not support '
                  'its transport.'
            : '$count MCP servers were skipped because this agent does not '
                  'support their transport.',
      );
    }
    if (unreadableMcpServerCount > 0) {
      final count = unreadableMcpServerCount;
      parts.add(
        count == 1
            ? '1 MCP server was skipped because its saved secrets could not '
                  'be read. Re-enter them in Settings.'
            : '$count MCP servers were skipped because their saved secrets '
                  'could not be read. Re-enter them in Settings.',
      );
    }
    if (additionalDirectoriesUnsupported) {
      parts.add(
        'This agent does not support additional directories; only the '
        'working directory was shared.',
      );
    }
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// Filters [mcpServers] and [additionalDirectories] by what [capabilities]
/// advertises: stdio servers are always sent, HTTP only with `mcp.http`, SSE
/// only with `mcp.sse`, and directories only with
/// `sessionCapabilities.additionalDirectories`.
AcpSessionWorkspaceSetup planAcpSessionWorkspaceSetup({
  required List<AcpMcpServerConfig> mcpServers,
  required List<String> additionalDirectories,
  required AcpAgentCapabilities capabilities,
}) {
  final sent = <AcpJsonMap>[];
  var unsupported = 0;
  var unreadable = 0;
  for (final server in mcpServers) {
    if (server.hasUnreadableSecrets) {
      unreadable++;
      continue;
    }
    final supported = switch (server.transport) {
      AcpMcpServerTransport.stdio => true,
      AcpMcpServerTransport.http => capabilities.mcp.http,
      AcpMcpServerTransport.sse => capabilities.mcp.sse,
    };
    if (!supported) {
      unsupported++;
      continue;
    }
    sent.add(server.toAcpJson());
  }
  final directoriesSupported = capabilities.session.additionalDirectories;
  return AcpSessionWorkspaceSetup(
    mcpServers: sent,
    additionalDirectories: directoriesSupported
        ? additionalDirectories
        : const <String>[],
    unsupportedMcpServerCount: unsupported,
    unreadableMcpServerCount: unreadable,
    additionalDirectoriesUnsupported:
        !directoriesSupported && additionalDirectories.isNotEmpty,
  );
}
