import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dartssh2/dartssh2.dart';

import '../models/acp_client_capabilities.dart';
import '../models/acp_json.dart';
import '../models/acp_protocol.dart';
import '../models/acp_updates.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

/// Limits applied to agent-initiated remote filesystem and terminal work.
final class AcpClientCapabilityLimits {
  /// Creates capability limits.
  const AcpClientCapabilityLimits({
    this.maxFileBytes = 1024 * 1024,
    this.maxWriteBytes = 1024 * 1024,
    this.fileTimeout = const Duration(seconds: 20),
    this.maxTerminals = 4,
    this.maxCommandCharacters = 8192,
    this.maxEnvironmentVariables = 64,
    this.maxTerminalOutputBytes = 1024 * 1024,
    this.terminalOpenTimeout = const Duration(seconds: 10),
    this.maxTerminalLifetime = const Duration(minutes: 10),
  });

  /// Maximum file bytes read from SFTP.
  final int maxFileBytes;

  /// Maximum UTF-8 bytes accepted for a write.
  final int maxWriteBytes;

  /// Timeout for one SFTP operation.
  final Duration fileTimeout;

  /// Maximum concurrently retained ACP terminals.
  final int maxTerminals;

  /// Maximum command plus argument character count.
  final int maxCommandCharacters;

  /// Maximum environment variables accepted for one terminal.
  final int maxEnvironmentVariables;

  /// Largest output ring buffer retained for one terminal.
  final int maxTerminalOutputBytes;

  /// Timeout for opening an SSH terminal command channel.
  final Duration terminalOpenTimeout;

  /// Maximum lifetime for an unreleased terminal.
  final Duration maxTerminalLifetime;
}

/// A remote filesystem used to satisfy ACP filesystem requests.
abstract interface class AcpRemoteFileSystem {
  /// Resolves an existing path to its canonical remote target.
  ///
  /// Implementations must resolve symbolic links and reject paths that cannot
  /// be safely canonicalized.
  Future<String> canonicalizeExistingPath(String path);

  /// Resolves a path intended for writing to its canonical remote target.
  ///
  /// Existing targets are resolved in full. New targets are resolved through
  /// their existing canonical parent before the final filename is appended.
  Future<String> canonicalizeWritePath(String path);

  /// Reads a complete UTF-8 file at [path], up to [maxBytes].
  Future<Uint8List> read(String path, {required int maxBytes});

  /// Writes [bytes] to [path], creating it when absent.
  Future<void> write(String path, Uint8List bytes);
}

/// SFTP implementation of [AcpRemoteFileSystem].
final class AcpSftpRemoteFileSystem implements AcpRemoteFileSystem {
  /// Creates an SFTP-backed filesystem.
  AcpSftpRemoteFileSystem(this._sftp);

  final Future<SftpClient> Function() _sftp;

  @override
  Future<String> canonicalizeExistingPath(String path) async {
    final resolved = await (await _sftp()).absolute(path);
    final normalized = normalizeSftpAbsolutePath(resolved);
    if (normalized == null) {
      throw const AcpClientCapabilityException('Path could not be resolved');
    }
    return normalized;
  }

  @override
  Future<String> canonicalizeWritePath(String path) async {
    final sftp = await _sftp();
    try {
      // `absolute` uses SFTP realpath and follows an existing final symlink.
      await sftp.stat(path);
      final resolved = await sftp.absolute(path);
      final normalized = normalizeSftpAbsolutePath(resolved);
      if (normalized == null) {
        throw const AcpClientCapabilityException('Path could not be resolved');
      }
      return normalized;
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) rethrow;
    }

    final separator = path.lastIndexOf('/');
    if (separator <= 0 || separator == path.length - 1) {
      throw const AcpClientCapabilityException('Path could not be resolved');
    }
    final parent = await sftp.absolute(path.substring(0, separator));
    final normalizedParent = normalizeSftpAbsolutePath(parent);
    if (normalizedParent == null) {
      throw const AcpClientCapabilityException('Path could not be resolved');
    }
    return joinRemotePath(normalizedParent, path.substring(separator + 1));
  }

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    final sftp = await _sftp();
    final stat = await sftp.stat(path, followLink: false);
    if (stat.isDirectory) {
      throw const AcpClientCapabilityException('Path is a directory');
    }
    if (stat.size != null && stat.size! > maxBytes) {
      throw const AcpLimitExceededException(
        'File exceeds the configured limit',
      );
    }
    final file = await sftp.open(path);
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.read()) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const AcpLimitExceededException(
            'File exceeds the configured limit',
          );
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final sftp = await _sftp();
    final separator = path.lastIndexOf('/');
    final parent = separator <= 0 ? '/' : path.substring(0, separator);
    final filename = separator == -1 ? path : path.substring(separator + 1);
    final temporaryPath =
        '$parent/.$filename.acp-${Random.secure().nextInt(1 << 32)}';
    var temporaryMayExist = false;
    SftpFileMode? existingMode;
    try {
      try {
        existingMode = (await sftp.stat(path, followLink: false)).mode;
      } on SftpStatusError catch (error) {
        if (error.code != SftpStatusCode.noSuchFile) rethrow;
      }
      // uploadBytes may create/truncate the temporary path before throwing.
      // Mark cleanup first; remove already tolerates a path that was never made.
      temporaryMayExist = true;
      await const RemoteFileService().uploadBytes(
        sftp: sftp,
        remotePath: temporaryPath,
        bytes: bytes,
      );
      if (existingMode != null) {
        await sftp.setStat(temporaryPath, SftpFileAttrs(mode: existingMode));
      }
      // SFTP rename keeps the original file untouched if upload fails. Servers
      // that decline replacing an existing destination fail safely instead.
      await sftp.rename(temporaryPath, path);
      if (existingMode != null) {
        await sftp.setStat(path, SftpFileAttrs(mode: existingMode));
      }
    } finally {
      if (temporaryMayExist) {
        try {
          await sftp.remove(temporaryPath);
        } on Object {
          // A successful rename removes the temporary path. Cleanup is best effort.
        }
      }
    }
  }
}

/// A running remote terminal process.
abstract interface class AcpTerminalProcess {
  /// Standard-output bytes from the process.
  Stream<List<int>> get stdout;

  /// Standard-error bytes from the process.
  Stream<List<int>> get stderr;

  /// Completes when the SSH command channel closes.
  Future<void> get done;

  /// Waits for the process exit status.
  Future<AcpTerminalExitStatus> waitForExit();

  /// Terminates the process/channel.
  void kill();
}

/// Starts remote non-PTY terminal processes.
abstract interface class AcpTerminalExecutor {
  /// Starts [command] without a PTY.
  Future<AcpTerminalProcess> start(String command);
}

/// SSH implementation of [AcpTerminalExecutor].
final class AcpSshTerminalExecutor implements AcpTerminalExecutor {
  /// Creates a terminal executor that resolves the active same-host session.
  const AcpSshTerminalExecutor(
    this._session, {
    required this.remoteIsWindows,
    required this.openTimeout,
  });

  final Future<SshSession> Function() _session;

  /// Whether the remote host requires Windows command syntax.
  final bool remoteIsWindows;

  /// Deadline for opening a terminal command channel.
  final Duration openTimeout;

  @override
  Future<AcpTerminalProcess> start(String command) async {
    try {
      return _SshAcpTerminalProcess(
        await openSshExec((await _session()).execute(command), openTimeout),
      );
    } on TimeoutException {
      throw const AcpClientCapabilityException(
        'Terminal channel opening timed out',
      );
    }
  }
}

/// Terminal exit status returned by ACP terminal methods.
final class AcpTerminalExitStatus {
  /// Creates an exit status.
  const AcpTerminalExitStatus({this.exitCode, this.signal});

  /// Numeric exit code, if the command returned normally.
  final int? exitCode;

  /// Remote signal name, if the command was signalled.
  final String? signal;

  /// Encodes this status for ACP.
  AcpJsonMap toJson() => <String, Object?>{
    'exitCode': exitCode,
    'signal': signal,
  };
}

/// A configuration or remote-operation failure safe to return to ACP.
class AcpClientCapabilityException implements Exception {
  /// Creates a capability failure.
  const AcpClientCapabilityException(this.message);

  /// Safe error message.
  final String message;

  @override
  String toString() => message;
}

/// A configured resource limit was exceeded.
final class AcpLimitExceededException extends AcpClientCapabilityException {
  /// Creates a limit-exceeded failure.
  const AcpLimitExceededException(super.message);
}

/// A state registry for user decisions that survives a transport detach.
///
/// Bounded so a misbehaving or malicious agent that floods requests cannot
/// grow local memory without limit: once [maxPendingRequests] outstanding new
/// requests or [maxPendingContentBytes] of provider content are retained,
/// [register] refuses further brand-new requests (a rebind of an already
/// tracked request is accepted only when its method and parameters match).
final class AcpPendingRequestRegistry {
  /// Creates a pending-request registry.
  AcpPendingRequestRegistry({
    this.maxPendingRequests = 200,
    this.maxPendingContentBytes = 16 * 1024 * 1024,
  });

  /// Maximum distinct outstanding requests retained at once.
  final int maxPendingRequests;

  /// Maximum provider-controlled content retained across pending requests.
  final int maxPendingContentBytes;

  final _requests = <String, AcpPendingClientRequest>{};
  var _pendingContentBytes = 0;
  final _changes = StreamController<List<AcpPendingClientRequest>>.broadcast(
    sync: true,
  );

  /// Current pending requests.
  List<AcpPendingClientRequest> get requests =>
      List<AcpPendingClientRequest>.unmodifiable(_requests.values);

  /// Emits an immutable request snapshot after each change.
  Stream<List<AcpPendingClientRequest>> get changes => _changes.stream;

  /// Adds a new request or rebinds its response channel after reconnect.
  ///
  /// Returns `null` instead of registering when the registry is already at
  /// [maxPendingRequests] or [maxPendingContentBytes] and [pending] is not a
  /// rebind of a tracked request; the caller must then answer the request with
  /// a safe decline so it never leaks unbounded state or leaves the agent's
  /// request unanswered.
  T? register<T extends AcpPendingClientRequest>(T pending) {
    final existing = _requests[pending.id];
    if (existing != null) {
      if (existing.runtimeType != pending.runtimeType ||
          existing.request.method != pending.request.method ||
          !const DeepCollectionEquality().equals(
            existing.request.params,
            pending.request.params,
          )) {
        throw const AcpClientCapabilityException(
          'Pending request ID was reused with different parameters',
        );
      }
      existing.request = pending.request;
      _emit();
      return existing as T;
    }
    if (_requests.length >= maxPendingRequests) return null;
    final nextContentBytes =
        _pendingContentBytes + pending.retainedContentBytes;
    if (nextContentBytes > maxPendingContentBytes) {
      return null;
    }
    _requests[pending.id] = pending;
    _pendingContentBytes = nextContentBytes;
    _emit();
    return pending;
  }

  /// Removes [id] after it has been answered.
  void remove(String id) {
    final removed = _requests.remove(id);
    if (removed == null) return;
    _pendingContentBytes -= removed.retainedContentBytes;
    _emit();
  }

  /// Cancels unresolved permissions during explicit ACP session destruction.
  Future<void> cancelAll() async {
    final pending = _requests.values.toList(growable: false);
    _requests.clear();
    _pendingContentBytes = 0;
    _emit();
    await _cancelPending(pending);
  }

  /// Cancels and removes only the pending requests belonging to
  /// [sessionId], leaving every other session's pending requests on a
  /// shared bridge attachment (for example a fork) untouched.
  ///
  /// Used when one session sharing a bridge is explicitly stopped/deleted
  /// while another live session keeps the attachment (and this registry)
  /// alive: without this, that session's own pending permission/write
  /// requests would otherwise never be answered or removed.
  Future<void> cancelForSession(String sessionId) async {
    final matching = _requests.values
        .where((request) => request.sessionId == sessionId)
        .toList(growable: false);
    if (matching.isEmpty) return;
    for (final request in matching) {
      _requests.remove(request.id);
      _pendingContentBytes -= request.retainedContentBytes;
    }
    _emit();
    await _cancelPending(matching);
  }

  Future<void> _cancelPending(List<AcpPendingClientRequest> pending) async {
    for (final request in pending) {
      try {
        if (request case AcpPendingPermission()) {
          await request.cancel();
        } else if (request case AcpPendingFileWrite()) {
          await request.reject();
        }
      } on Object {
        // A detached bridge can no longer accept a response; its replayed request
        // remains unresolved remotely until the explicit bridge/session teardown.
      }
    }
  }

  /// Closes the registry after explicit session destruction.
  Future<void> close() async {
    await cancelAll();
    await _changes.close();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(requests);
  }
}

/// Binds ACP server requests to same-host SSH filesystem and terminal services.
final class AcpClientCapabilityService {
  /// Creates a capability request handler.
  AcpClientCapabilityService({
    required this.fileSystem,
    required this.terminalExecutor,
    required this.allowedRoots,
    required this.registry,
    this.autoApprovePermissions = false,
    this.limits = const AcpClientCapabilityLimits(),
    DiagnosticsLogger? diagnostics,
  }) : _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  /// Filesystem implementation for the current remote host.
  final AcpRemoteFileSystem? fileSystem;

  /// Terminal implementation for the current remote host.
  final AcpTerminalExecutor? terminalExecutor;

  /// Roots that file and terminal working-directory requests may access.
  final List<String> allowedRoots;

  /// User-decision registry. It may be retained over bridge detach/reconnect.
  final AcpPendingRequestRegistry registry;

  /// Whether the user explicitly enabled YOLO behavior for this host launch.
  ///
  /// Permission requests choose only an agent-supplied allow-once option, and
  /// file writes still pass all normal path and size validation before writing.
  final bool autoApprovePermissions;

  final Map<String, bool> _sessionAutoApprovePermissions = <String, bool>{};

  /// Overrides Ask/YOLO behavior for one ACP session sharing this bridge.
  void setSessionAutoApprovePermissions(
    String sessionId, {
    required bool enabled,
  }) {
    if (sessionId.isEmpty) return;
    _sessionAutoApprovePermissions[sessionId] = enabled;
  }

  bool _autoApproveForSession(String sessionId) =>
      _sessionAutoApprovePermissions[sessionId] ?? autoApprovePermissions;

  /// Resource limits for this service.
  final AcpClientCapabilityLimits limits;

  final DiagnosticsLogger _diagnostics;
  final _terminals = <String, _ManagedAcpTerminal>{};
  var _terminalReservations = 0;
  // Routing outlives the stream callback. Permanent teardown invalidates these
  // continuations before awaiting cleanup; soft detach deliberately keeps them.
  final _activeRequests = <AcpJsonRpcServerRequest, String?>{};
  // Count overlapping teardowns so admission resumes only after all finish.
  final _closingSessions = <String, int>{};
  var _closed = false;
  StreamSubscription<AcpJsonRpcServerRequest>? _subscription;
  var _nextTerminalId = 0;

  /// Capabilities that are safe to advertise for this service instance.
  AcpClientCapabilities get capabilities => AcpClientCapabilities(
    meta: const <String, Object?>{
      'subagent-transcript': true,
      'terminal-auth': true,
    },
    fileSystem: fileSystem == null
        ? null
        : const AcpFileSystemCapabilities(
            readTextFile: true,
            writeTextFile: true,
          ),
    terminal: terminalExecutor != null,
  );

  /// Starts routing server requests from [client].
  ///
  /// Detaching only cancels the stream subscription. It deliberately keeps
  /// [registry] and terminals alive for bridge replay after reconnect.
  void attach(AcpClient client) {
    if (_closed) throw StateError('ACP capability service is closed');
    _subscription?.cancel();
    _subscription = client.serverRequests.listen(_handle);
  }

  /// Attaches to [client] and initializes it with exactly these capabilities.
  Future<AcpInitializeResult> initialize(
    AcpClient client, {
    Duration? timeout,
  }) {
    attach(client);
    return client.initialize(capabilities: capabilities, timeout: timeout);
  }

  /// Stops receiving requests without cancelling retained user decisions.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Explicitly destroys session-owned terminal resources and pending requests.
  Future<void> close() async {
    _closed = true;
    _activeRequests.clear();
    await detach();
    await Future.wait<void>(
      _terminals.values.map((terminal) => terminal.release()),
    );
    _terminals.clear();
    _sessionAutoApprovePermissions.clear();
    await registry.close();
  }

  /// Cancels and removes only the pending permission/write requests that
  /// belong to [sessionId], leaving any other session sharing this bridge
  /// attachment (for example a fork) untouched.
  ///
  /// Use this when explicitly stopping/deleting one session on a bridge that
  /// other live sessions still use: closing the whole capability service
  /// with [close] would incorrectly cancel those other sessions' pending
  /// requests too and stop routing their `fs`/`terminal` requests.
  ///
  /// Rejects new requests for this session until all overlapping teardowns
  /// finish. The session may resume on this bridge afterward.
  Future<void> closeSession(String sessionId) async {
    _closingSessions.update(sessionId, (count) => count + 1, ifAbsent: () => 1);
    try {
      _activeRequests.removeWhere((_, owner) => owner == sessionId);
      _sessionAutoApprovePermissions.remove(sessionId);
      final owned = _terminals.entries
          .where((entry) => entry.value.sessionId == sessionId)
          .toList(growable: false);
      for (final entry in owned) {
        _terminals.remove(entry.key);
      }
      await Future.wait<void>(owned.map((entry) => entry.value.release()));
      await registry.cancelForSession(sessionId);
    } finally {
      final remaining = _closingSessions[sessionId]! - 1;
      if (remaining == 0) {
        _closingSessions.remove(sessionId);
      } else {
        _closingSessions[sessionId] = remaining;
      }
    }
  }

  /// Returns a pending write body for explicit in-memory review only.
  String? pendingWriteContent(String requestId) {
    final pending = registry._requests[requestId];
    return pending is AcpPendingFileWrite ? pending.content : null;
  }

  /// Approves a pending write after explicit user confirmation.
  Future<void> approveWrite(String requestId) async {
    final pending = registry._requests[requestId];
    if (pending is! AcpPendingFileWrite || fileSystem == null) {
      throw StateError('No pending file write for request');
    }
    try {
      await pending.approve(() => _writeFile(pending.path, pending.content));
    } on TimeoutException {
      await _respondWriteFailure(pending, 'Remote operation timed out');
      rethrow;
    } on AcpClientCapabilityException catch (error) {
      await _respondWriteFailure(pending, error.message);
      rethrow;
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.capability',
        'write_failed',
        fields: {'errorType': error.runtimeType},
      );
      await _respondWriteFailure(pending, 'Remote operation failed');
      rethrow;
    } finally {
      registry.remove(requestId);
    }
  }

  /// Rejects an unapproved file write.
  Future<void> rejectWrite(String requestId) async {
    final pending = registry._requests[requestId];
    if (pending is! AcpPendingFileWrite) {
      throw StateError('No pending file write for request');
    }
    try {
      await pending.reject();
    } finally {
      registry.remove(requestId);
    }
  }

  /// Answers a permission request with an exact agent option ID.
  Future<void> selectPermission(String requestId, String optionId) async {
    final pending = registry._requests[requestId];
    if (pending is! AcpPendingPermission) {
      throw StateError('No pending permission for request');
    }
    // Validation is synchronous. Keep an unanswered request if it fails.
    final response = pending.select(optionId);
    try {
      await response;
    } finally {
      registry.remove(requestId);
    }
  }

  /// Cancels an outstanding permission request.
  Future<void> cancelPermission(String requestId) async {
    final pending = registry._requests[requestId];
    if (pending is! AcpPendingPermission) {
      throw StateError('No pending permission for request');
    }
    try {
      await pending.cancel();
    } finally {
      registry.remove(requestId);
    }
  }

  void _handle(AcpJsonRpcServerRequest request) {
    unawaited(_route(request));
  }

  Future<void> _route(AcpJsonRpcServerRequest request) async {
    final startedAt = DateTime.now();
    try {
      final sessionId = AcpJson.string(
        AcpJson.object(request.params) ?? const <String, Object?>{},
        'sessionId',
      );
      if (!_closed && !_closingSessions.containsKey(sessionId)) {
        _activeRequests[request] = sessionId;
      }
      _ensureRequestActive(request);
      switch (request.method) {
        case 'session/request_permission':
          await _permission(request);
        case 'fs/read_text_file':
          await _readTextFile(request);
        case 'fs/write_text_file':
          await _queueTextFileWrite(request);
        case 'terminal/create':
          await _createTerminal(request);
        case 'terminal/output':
          await _terminalOutput(request);
        case 'terminal/wait_for_exit':
          await _terminalWait(request);
        case 'terminal/kill':
          await _terminalKill(request);
        case 'terminal/release':
          await _terminalRelease(request);
        default:
          await request.respondError(-32601, 'Method not found');
      }
    } on AcpClientCapabilityException catch (error) {
      await _respondRequestError(request, error.message);
    } on TimeoutException {
      await _respondRequestError(request, 'Remote operation timed out');
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.capability',
        'request_failed',
        fields: {
          'methodCategory': _methodCategory(request.method),
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'errorType': error.runtimeType,
        },
      );
      await _respondRequestError(request, 'Remote operation failed');
    } finally {
      _activeRequests.remove(request);
    }
  }

  void _ensureRequestActive(AcpJsonRpcServerRequest request) {
    if (!_activeRequests.containsKey(request)) {
      throw const AcpClientCapabilityException('Request was cancelled');
    }
  }

  Future<void> _respondRequestError(
    AcpJsonRpcServerRequest request,
    String message,
  ) async {
    try {
      await request.respondError(-32000, message);
    } on Object {
      // Teardown may close the response channel or already answer the request.
    }
  }

  Future<void> _permission(AcpJsonRpcServerRequest request) async {
    final params = _objectParams(request);
    final permission = AcpPermissionRequest.fromJson(params);
    if (permission.sessionId.isEmpty || permission.options.isEmpty) {
      throw const AcpClientCapabilityException('Invalid permission request');
    }
    if (_autoApproveForSession(permission.sessionId)) {
      final option = permission.options
          .where(
            (candidate) => candidate.kind == AcpPermissionOptionKind.allowOnce,
          )
          .firstOrNull;
      if (option != null) {
        await request.respond(<String, Object?>{
          'outcome': AcpSelectedPermissionOutcome(option.id).toJson(),
        });
        _diagnostics.info(
          'acp.capability',
          'permission_auto_approved',
          fields: {'optionKind': AcpPermissionOptionKind.allowOnce.value},
        );
        return;
      }
    }
    final registered = registry.register(
      AcpPendingPermission(request, permission),
    );
    if (registered == null) {
      _diagnostics.warning(
        'acp.capability',
        'pending_request_overflow',
        fields: {'kind': 'permission'},
      );
      await request.respond(<String, Object?>{
        'outcome': const AcpCancelledPermissionOutcome().toJson(),
      });
      return;
    }
    _diagnostics.info(
      'acp.capability',
      'permission_pending',
      fields: {'optionCount': permission.options.length},
    );
  }

  Future<void> _readTextFile(AcpJsonRpcServerRequest request) async {
    final remoteFileSystem = fileSystem;
    if (remoteFileSystem == null) {
      throw const AcpClientCapabilityException(
        'Filesystem access is unavailable',
      );
    }
    final params = _objectParams(request);
    _requiredSessionId(params);
    final path = await _validatedPath(
      _requiredString(params, 'path'),
      forWrite: false,
    );
    _ensureRequestActive(request);
    final line = _optionalPositiveInteger(params, 'line');
    final limit = _optionalPositiveInteger(params, 'limit');
    final bytes = await remoteFileSystem
        .read(path, maxBytes: limits.maxFileBytes)
        .timeout(limits.fileTimeout);
    _ensureRequestActive(request);
    final content = _decodeUtf8(bytes);
    await request.respond(<String, Object?>{
      'content': _selectLines(content, line: line, limit: limit),
    });
  }

  Future<void> _queueTextFileWrite(AcpJsonRpcServerRequest request) async {
    if (fileSystem == null) {
      throw const AcpClientCapabilityException('File writes are unavailable');
    }
    final params = _objectParams(request);
    final sessionId = _requiredSessionId(params);
    final path = await _validatedPath(
      _requiredString(params, 'path'),
      forWrite: true,
    );
    _ensureRequestActive(request);
    final content = AcpJson.string(params, 'content');
    if (content == null) {
      throw const AcpClientCapabilityException('Invalid request parameters');
    }
    if (utf8.encode(content).length > limits.maxWriteBytes) {
      throw const AcpLimitExceededException(
        'Write exceeds the configured limit',
      );
    }
    if (_autoApproveForSession(sessionId)) {
      await _writeFile(path, content);
      _ensureRequestActive(request);
      await request.respond();
      _diagnostics.info('acp.capability', 'write_auto_approved');
      return;
    }
    final registered = registry.register(
      AcpPendingFileWrite(
        request: request,
        sessionId: sessionId,
        path: path,
        content: content,
      ),
    );
    if (registered == null) {
      _diagnostics.warning(
        'acp.capability',
        'pending_request_overflow',
        fields: {'kind': 'write'},
      );
      await request.respondError(-32000, 'Too many pending requests');
      return;
    }
    _diagnostics.info('acp.capability', 'write_pending');
  }

  Future<void> _writeFile(String path, String content) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    if (bytes.length > limits.maxWriteBytes) {
      throw const AcpLimitExceededException(
        'Write exceeds the configured limit',
      );
    }
    await fileSystem!.write(path, bytes).timeout(limits.fileTimeout);
  }

  Future<void> _createTerminal(AcpJsonRpcServerRequest request) async {
    final executor = terminalExecutor;
    if (executor == null) {
      throw const AcpClientCapabilityException(
        'Terminal access is unavailable',
      );
    }
    final params = _objectParams(request);
    final sessionId = _requiredSessionId(params);
    final command = _requiredString(params, 'command');
    final arguments = _stringList(params['args'], 'args');
    final environment = _environment(params['env']);
    if (environment.length > limits.maxEnvironmentVariables) {
      throw const AcpLimitExceededException('Too many environment variables');
    }
    final requestedCwd = params['cwd'] == null
        ? null
        : _requiredString(params, 'cwd');
    final inputCharacters =
        command.length +
        arguments.fold<int>(0, (total, value) => total + value.length) +
        environment.entries.fold<int>(
          0,
          (total, entry) => total + entry.key.length + entry.value.length,
        ) +
        (requestedCwd?.length ?? 0);
    if (inputCharacters > limits.maxCommandCharacters) {
      throw const AcpLimitExceededException(
        'Terminal command exceeds the limit',
      );
    }
    final cwd = requestedCwd == null
        ? null
        : await _validatedPath(requestedCwd, forWrite: false);
    final requestedOutputLimit = _optionalPositiveInteger(
      params,
      'outputByteLimit',
    );
    final outputLimit = requestedOutputLimit == null
        ? limits.maxTerminalOutputBytes
        : min(requestedOutputLimit, limits.maxTerminalOutputBytes);
    if (outputLimit <= 0) {
      throw const AcpLimitExceededException(
        'Terminal command exceeds the limit',
      );
    }
    final remoteCommand = buildAcpRemoteTerminalCommand(
      command: command,
      arguments: arguments,
      environment: environment,
      cwd: cwd,
      windows: executor is AcpSshTerminalExecutor && executor.remoteIsWindows,
    );
    if (remoteCommand.length > limits.maxCommandCharacters) {
      throw const AcpLimitExceededException(
        'Terminal command exceeds the limit',
      );
    }
    _ensureRequestActive(request);
    if (_terminals.length + _terminalReservations >= limits.maxTerminals) {
      throw const AcpLimitExceededException('Too many active terminals');
    }
    _terminalReservations++;
    final AcpTerminalProcess process;
    try {
      process = await executor.start(remoteCommand);
    } finally {
      _terminalReservations--;
    }
    if (!_activeRequests.containsKey(request)) {
      process.kill();
      _ensureRequestActive(request);
    }
    final id = 'acp-terminal-${++_nextTerminalId}';
    final terminal = _ManagedAcpTerminal(sessionId, process, outputLimit);
    _terminals[id] = terminal;
    terminal
      ..start(
        onExit: () {
          _diagnostics.info(
            'acp.capability',
            'terminal_exited',
            fields: {'terminalCount': _terminals.length},
          );
        },
      )
      ..lifetimeTimer = Timer(
        limits.maxTerminalLifetime,
        () => unawaited(terminal.kill()),
      );
    await request.respond(<String, Object?>{'terminalId': id});
  }

  Future<void> _terminalOutput(AcpJsonRpcServerRequest request) async {
    final terminal = _terminalFor(request);
    await request.respond(terminal.output());
  }

  Future<void> _terminalWait(AcpJsonRpcServerRequest request) async {
    final terminal = _terminalFor(request);
    await request.respond((await terminal.wait()).toJson());
  }

  Future<void> _terminalKill(AcpJsonRpcServerRequest request) async {
    final terminal = _terminalFor(request);
    await terminal.kill();
    await request.respond();
  }

  Future<void> _terminalRelease(AcpJsonRpcServerRequest request) async {
    final params = _objectParams(request);
    final sessionId = _requiredSessionId(params);
    final id = _requiredString(params, 'terminalId');
    final terminal = _terminals[id];
    if (terminal == null || terminal.sessionId != sessionId) {
      throw const AcpClientCapabilityException('Unknown terminal');
    }
    _terminals.remove(id);
    await terminal.release();
    await request.respond();
  }

  _ManagedAcpTerminal _terminalFor(AcpJsonRpcServerRequest request) {
    final params = _objectParams(request);
    final sessionId = _requiredSessionId(params);
    final terminal = _terminals[_requiredString(params, 'terminalId')];
    if (terminal == null || terminal.sessionId != sessionId) {
      throw const AcpClientCapabilityException('Unknown terminal');
    }
    return terminal;
  }

  Future<void> _respondWriteFailure(
    AcpPendingFileWrite pending,
    String message,
  ) async {
    try {
      await pending.request.respondError(-32000, message);
    } on Object {
      // The bridge/session teardown may have already answered this request.
    }
  }

  Future<String> _validatedPath(
    String candidate, {
    required bool forWrite,
  }) async {
    final normalized = normalizeSftpAbsolutePath(candidate);
    final includesTraversal = candidate
        .replaceAll(r'\', '/')
        .split('/')
        .any((segment) => segment == '..');
    if (normalized == null || includesTraversal || fileSystem == null) {
      throw const AcpClientCapabilityException('Path is not allowed');
    }
    try {
      final resolved = forWrite
          ? await fileSystem!.canonicalizeWritePath(normalized)
          : await fileSystem!.canonicalizeExistingPath(normalized);
      final canonicalRoots = await Future.wait(
        allowedRoots.map((root) async {
          final normalizedRoot = normalizeSftpAbsolutePath(root);
          if (normalizedRoot == null) {
            throw const AcpClientCapabilityException('Path is not allowed');
          }
          return fileSystem!.canonicalizeExistingPath(normalizedRoot);
        }),
      );
      if (!_isAllowedPath(resolved, canonicalRoots)) {
        throw const AcpClientCapabilityException('Path is not allowed');
      }
      return resolved;
    } on AcpClientCapabilityException {
      rethrow;
    } on Object {
      throw const AcpClientCapabilityException('Path is not allowed');
    }
  }

  bool _isAllowedPath(String candidate, Iterable<String> roots) {
    for (final root in roots) {
      final normalizedRoot = normalizeSftpAbsolutePath(root);
      if (normalizedRoot == null) continue;
      if (candidate == normalizedRoot ||
          candidate.startsWith(
            normalizedRoot.endsWith('/') ? normalizedRoot : '$normalizedRoot/',
          )) {
        return true;
      }
    }
    return false;
  }
}

/// Builds a safely quoted command for a remote non-PTY SSH exec channel.
String buildAcpRemoteTerminalCommand({
  required String command,
  required List<String> arguments,
  required Map<String, String> environment,
  required String? cwd,
  required bool windows,
}) {
  if (windows) {
    final script = StringBuffer();
    for (final entry in environment.entries) {
      script
        ..write(r'$env:')
        ..write(entry.key)
        ..write('=')
        ..write(powerShellSingleQuote(entry.value))
        ..write(';');
    }
    if (cwd != null) {
      script
        ..write('Set-Location -LiteralPath ')
        ..write(powerShellSingleQuote(sftpPathToWindowsShellPath(cwd)))
        ..write(';');
    }
    script
      ..write('& ')
      ..write(powerShellSingleQuote(command));
    for (final argument in arguments) {
      script
        ..write(' ')
        ..write(powerShellSingleQuote(argument));
    }
    script.write(r';exit $LASTEXITCODE');
    return buildWindowsPowerShellCommand(script.toString());
  }
  final prefix = StringBuffer();
  if (cwd != null) {
    prefix
      ..write('cd -- ')
      ..write(shellEscapePosix(cwd))
      ..write(' && ');
  }
  for (final entry in environment.entries) {
    prefix
      ..write(entry.key)
      ..write('=')
      ..write(shellEscapePosix(entry.value))
      ..write(' ');
  }
  prefix.write(shellEscapePosix(command));
  for (final argument in arguments) {
    prefix
      ..write(' ')
      ..write(shellEscapePosix(argument));
  }
  return prefix.toString();
}

final class _SshAcpTerminalProcess implements AcpTerminalProcess {
  _SshAcpTerminalProcess(this._session);

  final SSHSession _session;

  @override
  Stream<List<int>> get stderr => _session.stderr.cast<List<int>>();

  @override
  Stream<List<int>> get stdout => _session.stdout.cast<List<int>>();

  @override
  Future<void> get done => _session.done;

  @override
  void kill() => _session.close();

  @override
  Future<AcpTerminalExitStatus> waitForExit() async => AcpTerminalExitStatus(
    exitCode: await _session.waitForExit(),
    signal: _session.exitSignal?.signalName,
  );
}

final class _ManagedAcpTerminal {
  _ManagedAcpTerminal(this.sessionId, this._process, this._limit);

  final String sessionId;
  final AcpTerminalProcess _process;
  final int _limit;
  final Queue<Uint8List> _outputChunks = Queue<Uint8List>();
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  Completer<AcpTerminalExitStatus>? _exit;
  AcpTerminalExitStatus? _exitStatus;
  Timer? lifetimeTimer;
  var _truncated = false;
  var _outputLength = 0;
  var _headOffset = 0;
  var _started = false;
  var _released = false;

  void start({required void Function() onExit}) {
    if (_started) return;
    _started = true;
    _stdoutSubscription = _process.stdout.listen(_append, onError: (_) {});
    _stderrSubscription = _process.stderr.listen(_append, onError: (_) {});
    _exit = Completer<AcpTerminalExitStatus>();
    unawaited(() async {
      try {
        final status = await _process.waitForExit();
        _exitStatus = status;
        if (!_exit!.isCompleted) _exit!.complete(status);
      } on Object {
        _exitStatus = const AcpTerminalExitStatus();
        if (!_exit!.isCompleted) _exit!.complete(_exitStatus);
      } finally {
        onExit();
      }
    }());
  }

  void _append(List<int> bytes) {
    if (bytes.isEmpty) return;
    final chunk = Uint8List.fromList(bytes);
    _outputChunks.addLast(chunk);
    _outputLength += chunk.length;
    if (_outputLength <= _limit) return;

    _truncated = true;
    var bytesToDiscard = _outputLength - _limit;
    while (bytesToDiscard > 0 && _outputChunks.isNotEmpty) {
      final first = _outputChunks.first;
      final available = first.length - _headOffset;
      if (bytesToDiscard < available) {
        _headOffset += bytesToDiscard;
        _outputLength -= bytesToDiscard;
        return;
      }
      _outputChunks.removeFirst();
      _outputLength -= available;
      bytesToDiscard -= available;
      _headOffset = 0;
    }
  }

  AcpJsonMap output() => <String, Object?>{
    'output': _outputText(),
    'truncated': _truncated,
    if (_exit?.isCompleted ?? false) 'exitStatus': _exitStatusJson(),
  };

  AcpJsonMap _exitStatusJson() => _exitStatus!.toJson();

  String _outputText() {
    if (_outputLength == 0) return '';
    final bytes = BytesBuilder(copy: false);
    var isFirst = true;
    for (final chunk in _outputChunks) {
      bytes.add(
        isFirst && _headOffset > 0 ? chunk.sublist(_headOffset) : chunk,
      );
      isFirst = false;
    }
    final flattened = bytes.takeBytes();
    final start = _utf8SuffixStart(flattened);
    final end = _utf8SuffixEnd(flattened, start);
    return utf8.decode(
      Uint8List.sublistView(flattened, start, end),
      allowMalformed: true,
    );
  }

  int _utf8SuffixStart(Uint8List bytes) {
    var start = 0;
    while (start < bytes.length && (bytes[start] & 0xc0) == 0x80) {
      start += 1;
    }
    return start;
  }

  int _utf8SuffixEnd(Uint8List bytes, int start) {
    var leadingIndex = bytes.length - 1;
    while (leadingIndex >= start && (bytes[leadingIndex] & 0xc0) == 0x80) {
      leadingIndex -= 1;
    }
    if (leadingIndex < start) return start;
    final leadingByte = bytes[leadingIndex];
    final expectedLength = switch (leadingByte) {
      >= 0xf0 && <= 0xf4 => 4,
      >= 0xe0 && <= 0xef => 3,
      >= 0xc2 && <= 0xdf => 2,
      _ => 1,
    };
    return bytes.length - leadingIndex < expectedLength
        ? leadingIndex
        : bytes.length;
  }

  Future<AcpTerminalExitStatus> wait() => _exit!.future;

  Future<void> kill() async {
    if (!_exit!.isCompleted) _process.kill();
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    lifetimeTimer?.cancel();
    await kill();
    await Future.wait<void>([
      _stdoutSubscription.cancel(),
      _stderrSubscription.cancel(),
    ]);
  }
}

AcpJsonMap _objectParams(AcpJsonRpcServerRequest request) {
  final params = AcpJson.object(request.params);
  if (params == null) {
    throw const AcpClientCapabilityException('Invalid request parameters');
  }
  return params;
}

String _requiredString(AcpJsonMap params, String name) {
  final value = AcpJson.string(params, name);
  if (value == null || value.isEmpty) {
    throw const AcpClientCapabilityException('Invalid request parameters');
  }
  return value;
}

String _requiredSessionId(AcpJsonMap params) =>
    _requiredString(params, 'sessionId');

int? _optionalPositiveInteger(AcpJsonMap params, String name) {
  if (!params.containsKey(name)) return null;
  final value = AcpJson.integer(params, name);
  if (value == null || value < 1) {
    throw const AcpClientCapabilityException('Invalid request parameters');
  }
  return value;
}

List<String> _stringList(Object? raw, String name) {
  if (raw == null) return const <String>[];
  if (raw is! List || raw.any((item) => item is! String)) {
    throw AcpClientCapabilityException('Invalid $name');
  }
  return List<String>.unmodifiable(raw.cast<String>());
}

Map<String, String> _environment(Object? raw) {
  if (raw == null) return const <String, String>{};
  if (raw is! List) {
    throw const AcpClientCapabilityException('Invalid env');
  }
  final environment = <String, String>{};
  for (final item in raw) {
    final value = AcpJson.object(item);
    final name = value == null ? null : AcpJson.string(value, 'name');
    final content = value == null ? null : AcpJson.string(value, 'value');
    if (name == null ||
        content == null ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw const AcpClientCapabilityException('Invalid env');
    }
    environment[name] = content;
  }
  return Map<String, String>.unmodifiable(environment);
}

String _decodeUtf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const AcpClientCapabilityException('File is not valid UTF-8 text');
  }
}

String _selectLines(String content, {int? line, int? limit}) {
  if (line == null && limit == null) return content;
  final lines = const LineSplitter().convert(content);
  final start = (line ?? 1) - 1;
  if (start >= lines.length) return '';
  final end = limit == null ? lines.length : min(lines.length, start + limit);
  final selected = lines.sublist(start, end).join('\n');
  return selected.isEmpty ? selected : '$selected\n';
}

String _methodCategory(String method) => method.split('/').first;
