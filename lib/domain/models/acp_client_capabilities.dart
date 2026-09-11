import 'dart:convert';

import '../services/acp_json_rpc_connection.dart';
import 'acp_updates.dart';

/// A user-decision request retained until it is explicitly answered.
sealed class AcpPendingClientRequest {
  /// Creates a retained client request.
  AcpPendingClientRequest(this.request, {DateTime? requestedAt})
    : retainedContentBytes = utf8.encode(jsonEncode(request.params)).length,
      requestedAt = requestedAt ?? DateTime.now();

  /// Current transport-bound request responder.
  AcpJsonRpcServerRequest request;

  /// Type-preserving JSON-RPC request identifier, stable across reconnect.
  ///
  /// JSON-RPC numeric `1` and string `"1"` are distinct IDs and may be
  /// outstanding simultaneously. The tag prevents registry collisions while
  /// retaining a compact UI-safe key.
  String get id {
    final value = request.id;
    return value is int ? 'n:$value' : 's:$value';
  }

  /// ACP session that owns this request, if supplied by the agent.
  String get sessionId;

  /// UTF-8 JSON size of all retained provider parameters, including metadata.
  ///
  /// Counted once for every request kind, so permissions cannot bypass the
  /// shared content budget and removal releases exactly the reserved amount.
  final int retainedContentBytes;

  /// When this request was first observed locally.
  ///
  /// Stable across a reconnect rebind: [AcpPendingRequestRegistry.register]
  /// only updates [request] on an existing entry, never replacing the object,
  /// so this always reflects the original arrival time.
  final DateTime requestedAt;
}

/// A pending `session/request_permission` request.
final class AcpPendingPermission extends AcpPendingClientRequest {
  /// Creates a pending permission request.
  AcpPendingPermission(super.request, this.permission, {super.requestedAt});

  /// Agent-provided permission details and exact selectable option IDs.
  final AcpPermissionRequest permission;

  @override
  String get sessionId => permission.sessionId;

  /// Answers with an exact option ID supplied by the agent.
  Future<void> select(String optionId) {
    if (!permission.options.any((option) => option.id == optionId)) {
      throw ArgumentError.value(
        optionId,
        'optionId',
        'Unknown permission option',
      );
    }
    return request.respond(<String, Object?>{
      'outcome': AcpSelectedPermissionOutcome(optionId).toJson(),
    });
  }

  /// Tells the agent that the pending request was cancelled.
  Future<void> cancel() => request.respond(<String, Object?>{
    'outcome': const AcpCancelledPermissionOutcome().toJson(),
  });
}

/// A write request waiting for an explicit local approval.
final class AcpPendingFileWrite extends AcpPendingClientRequest {
  /// Creates a pending file write.
  AcpPendingFileWrite({
    required AcpJsonRpcServerRequest request,
    required this.sessionId,
    required this.path,
    required this.content,
    DateTime? requestedAt,
  }) : super(request, requestedAt: requestedAt);

  @override
  final String sessionId;

  /// Normalized remote target path. This is intentionally never logged.
  final String path;

  /// UTF-8 text to write. This is intentionally never logged.
  final String content;

  /// Completes this write after user approval.
  Future<void> approve(Future<void> Function() write) async {
    await write();
    await request.respond();
  }

  /// Refuses this write without exposing the target path or content.
  Future<void> reject() =>
      request.respondError(-32001, 'File write was not approved');
}
