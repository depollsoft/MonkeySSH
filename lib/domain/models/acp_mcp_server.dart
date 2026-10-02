import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_json.dart';

/// Maximum characters in a user-defined MCP server name.
const kAcpMcpServerNameMaxCharacters = 64;

/// Maximum number of user-defined MCP servers.
const kAcpMcpServerMaxCount = 32;

/// Maximum arguments, environment variables, or headers on one MCP server.
const kAcpMcpServerMaxEntries = 64;

/// Transport used to reach an MCP server, as defined by ACP `McpServer`.
enum AcpMcpServerTransport {
  /// The agent launches the server as a local process on the remote host and
  /// talks to it over stdin/stdout. Every ACP agent supports this transport.
  stdio('stdio', 'stdio'),

  /// Streamable HTTP. Requires the agent's `mcpCapabilities.http`.
  http('http', 'HTTP'),

  /// Server-sent events (deprecated by MCP). Requires `mcpCapabilities.sse`.
  sse('sse', 'SSE');

  const AcpMcpServerTransport(this.storageValue, this.label);

  /// Stable value persisted in settings and used as the ACP `type`.
  final String storageValue;

  /// Short user-facing label.
  final String label;

  /// Whether this transport is reached by URL rather than a launched command.
  bool get isRemote => this != AcpMcpServerTransport.stdio;

  /// Parses a stored transport value.
  static AcpMcpServerTransport? fromStorageValue(Object? value) =>
      AcpMcpServerTransport.values.firstWhereOrNull(
        (transport) => transport.storageValue == value,
      );
}

/// One name/value pair: an MCP server environment variable or HTTP header.
///
/// [value] is frequently a secret (API keys, bearer tokens). It is encrypted
/// at rest and must never be logged.
@immutable
final class AcpMcpNameValue {
  /// Creates a name/value pair.
  const AcpMcpNameValue({required this.name, required this.value});

  /// Variable or header name.
  final String name;

  /// Variable or header value. Treated as a secret.
  final String value;

  /// ACP `EnvVariable` / `HttpHeader` JSON.
  AcpJsonMap toAcpJson() => <String, Object?>{'name': name, 'value': value};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpMcpNameValue && name == other.name && value == other.value;

  @override
  int get hashCode => Object.hash(name, value);

  // Never include the value: it is usually a credential.
  @override
  String toString() => 'AcpMcpNameValue(<redacted>)';
}

/// A user-defined MCP server that native agent sessions can be told to use.
///
/// Stdio servers are launched by the agent on the remote host, so [command]
/// must exist there. HTTP and SSE servers are reached by the agent at [url].
@immutable
final class AcpMcpServerConfig {
  /// Creates an MCP server definition.
  AcpMcpServerConfig({
    required this.id,
    required this.name,
    required this.transport,
    this.command = '',
    List<String> args = const <String>[],
    List<AcpMcpNameValue> env = const <AcpMcpNameValue>[],
    this.url = '',
    List<AcpMcpNameValue> headers = const <AcpMcpNameValue>[],
    this.useByDefault = false,
    this.hasUnreadableSecrets = false,
  }) : args = List<String>.unmodifiable(args),
       env = List<AcpMcpNameValue>.unmodifiable(env),
       headers = List<AcpMcpNameValue>.unmodifiable(headers);

  /// Stable local identifier. Never sent to the agent.
  final String id;

  /// Human-readable server name sent to the agent.
  final String name;

  /// Connection transport.
  final AcpMcpServerTransport transport;

  /// Executable for stdio servers (on the remote host).
  final String command;

  /// Command-line arguments for stdio servers.
  final List<String> args;

  /// Environment variables for stdio servers. Values are secrets.
  final List<AcpMcpNameValue> env;

  /// Endpoint URL for HTTP and SSE servers.
  final String url;

  /// HTTP headers for HTTP and SSE servers. Values are secrets.
  final List<AcpMcpNameValue> headers;

  /// Whether new sessions select this server unless the user opts out.
  final bool useByDefault;

  /// Whether a stored secret could not be decrypted on this device (for
  /// example after a migration). Such a server is never sent to an agent
  /// until its secrets are re-entered.
  final bool hasUnreadableSecrets;

  /// Number of secret values (env values or header values) on this server.
  int get secretCount => transport.isRemote ? headers.length : env.length;

  /// ACP `McpServer` JSON for `session/new`, `load`, `resume`, and `fork`.
  AcpJsonMap toAcpJson() => switch (transport) {
    AcpMcpServerTransport.stdio => <String, Object?>{
      'name': name,
      'command': command,
      'args': args,
      'env': [for (final variable in env) variable.toAcpJson()],
    },
    AcpMcpServerTransport.http ||
    AcpMcpServerTransport.sse => <String, Object?>{
      'type': transport.storageValue,
      'name': name,
      'url': url,
      'headers': [for (final header in headers) header.toAcpJson()],
    },
  };

  /// Returns a copy with selected fields replaced.
  AcpMcpServerConfig copyWith({
    String? name,
    AcpMcpServerTransport? transport,
    String? command,
    List<String>? args,
    List<AcpMcpNameValue>? env,
    String? url,
    List<AcpMcpNameValue>? headers,
    bool? useByDefault,
    bool? hasUnreadableSecrets,
  }) => AcpMcpServerConfig(
    id: id,
    name: name ?? this.name,
    transport: transport ?? this.transport,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    useByDefault: useByDefault ?? this.useByDefault,
    hasUnreadableSecrets: hasUnreadableSecrets ?? this.hasUnreadableSecrets,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpMcpServerConfig &&
          id == other.id &&
          name == other.name &&
          transport == other.transport &&
          command == other.command &&
          url == other.url &&
          useByDefault == other.useByDefault &&
          hasUnreadableSecrets == other.hasUnreadableSecrets &&
          const ListEquality<String>().equals(args, other.args) &&
          const ListEquality<AcpMcpNameValue>().equals(env, other.env) &&
          const ListEquality<AcpMcpNameValue>().equals(headers, other.headers);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    transport,
    command,
    url,
    useByDefault,
    hasUnreadableSecrets,
    const ListEquality<String>().hash(args),
    const ListEquality<AcpMcpNameValue>().hash(env),
    const ListEquality<AcpMcpNameValue>().hash(headers),
  );

  // Never include names, commands, URLs, or secrets.
  @override
  String toString() => 'AcpMcpServerConfig(transport: ${transport.name})';
}

/// Validation rules for user-defined MCP servers.
///
/// Each method returns a short user-facing error, or `null` when valid.
abstract final class AcpMcpServerValidation {
  static final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final _headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static final _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

  /// Validates a server name against the other configured names.
  ///
  /// Names are compared case-insensitively because agents commonly key MCP
  /// servers (and their tool namespaces) by name.
  static String? name(String value, {Iterable<String> otherNames = const []}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (trimmed.length > kAcpMcpServerNameMaxCharacters) {
      return 'Use $kAcpMcpServerNameMaxCharacters characters or fewer.';
    }
    if (_controlCharacters.hasMatch(trimmed)) {
      return 'Remove control characters.';
    }
    final normalized = trimmed.toLowerCase();
    if (otherNames.any((other) => other.trim().toLowerCase() == normalized)) {
      return 'Another MCP server already uses this name.';
    }
    return null;
  }

  /// Validates a stdio server command.
  static String? command(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter the command to launch.';
    if (_controlCharacters.hasMatch(trimmed)) {
      return 'The command must be a single line.';
    }
    return null;
  }

  /// Validates an HTTP or SSE endpoint URL.
  static String? url(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter the server URL.';
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return 'Enter an http:// or https:// URL.';
    }
    return null;
  }

  /// Validates an environment variable name.
  static String? envName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (!_envName.hasMatch(trimmed)) {
      return 'Use letters, digits, and underscores.';
    }
    return null;
  }

  /// Validates an HTTP header name.
  static String? headerName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter a header name.';
    if (!_headerName.hasMatch(trimmed)) return 'Invalid header name.';
    return null;
  }

  /// Validates an environment variable or header value.
  static String? secretValue(String value, {required bool header}) {
    if (header && RegExp('[\r\n]').hasMatch(value)) {
      return 'Header values must be a single line.';
    }
    if (value.contains('\u0000')) return 'Remove null characters.';
    return null;
  }

  /// Validates a complete server definition against [otherNames].
  static String? server(
    AcpMcpServerConfig server, {
    Iterable<String> otherNames = const [],
  }) {
    final nameError = name(server.name, otherNames: otherNames);
    if (nameError != null) return nameError;
    switch (server.transport) {
      case AcpMcpServerTransport.stdio:
        final commandError = command(server.command);
        if (commandError != null) return commandError;
        if (server.args.length > kAcpMcpServerMaxEntries ||
            server.env.length > kAcpMcpServerMaxEntries) {
          return 'Too many arguments or variables.';
        }
        for (final variable in server.env) {
          final error =
              envName(variable.name) ??
              secretValue(variable.value, header: false);
          if (error != null) return error;
        }
      case AcpMcpServerTransport.http:
      case AcpMcpServerTransport.sse:
        final urlError = url(server.url);
        if (urlError != null) return urlError;
        if (server.headers.length > kAcpMcpServerMaxEntries) {
          return 'Too many headers.';
        }
        for (final header in server.headers) {
          final error =
              headerName(header.name) ??
              secretValue(header.value, header: true);
          if (error != null) return error;
        }
    }
    return null;
  }
}
