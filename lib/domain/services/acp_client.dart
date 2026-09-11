import 'dart:async';
import 'dart:collection';

import '../models/acp_content.dart';
import '../models/acp_json.dart';
import '../models/acp_protocol.dart';
import '../models/acp_updates.dart';
import 'acp_json_rpc_connection.dart';

/// A requested operation is not advertised by the initialized ACP agent.
final class AcpUnsupportedCapabilityException implements Exception {
  /// Creates an unsupported-capability error.
  const AcpUnsupportedCapabilityException(this.capability);

  /// Missing capability.
  final String capability;

  @override
  String toString() => 'ACP capability is not available: $capability';
}

/// High-level typed ACP v1 client.
final class AcpClient {
  /// Creates a client over an active JSON-RPC connection.
  AcpClient(this.connection) {
    _serverRequests = StreamController<AcpJsonRpcServerRequest>.broadcast(
      sync: true,
      onListen: _schedulePendingServerRequestFlush,
    );
    _notificationSubscription = connection.notifications.listen(
      _handleNotification,
    );
    _serverRequestSubscription = connection.serverRequests.listen(
      _emitServerRequest,
    );
  }

  /// Underlying JSON-RPC connection.
  final AcpJsonRpcConnection connection;

  final _updates = StreamController<AcpSessionNotification>.broadcast(
    sync: true,
  );
  // Exactly one capability router answers provider-to-client requests. Keep a
  // small, bridge-bounded pre-listener queue because pending replay can arrive
  // as soon as the transport attaches, before that router has rebound.
  late final StreamController<AcpJsonRpcServerRequest> _serverRequests;
  final Queue<AcpJsonRpcServerRequest> _pendingServerRequests =
      Queue<AcpJsonRpcServerRequest>();
  var _pendingServerRequestFlushScheduled = false;
  late final StreamSubscription<AcpJsonRpcNotification>
  _notificationSubscription;
  late final StreamSubscription<AcpJsonRpcServerRequest>
  _serverRequestSubscription;
  AcpInitializeResult? _initialization;
  var _closed = false;

  /// Most recent successful initialization result.
  AcpInitializeResult? get initialization => _initialization;

  /// Typed `session/update` notifications.
  Stream<AcpSessionNotification> get updates => _updates.stream;

  /// Incoming server requests.
  Stream<AcpJsonRpcServerRequest> get serverRequests => _serverRequests.stream;

  /// Initializes the ACP connection.
  Future<AcpInitializeResult> initialize({
    int protocolVersion = 1,
    AcpClientCapabilities capabilities = const AcpClientCapabilities(
      meta: <String, Object?>{'subagent-transcript': true},
    ),
    AcpImplementation clientInfo = const AcpImplementation(
      name: 'monkeyssh',
      title: 'MonkeySSH',
      version: '1',
    ),
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final result = await connection.request(
      'initialize',
      params: <String, Object?>{
        'protocolVersion': protocolVersion,
        'clientCapabilities': capabilities.toJson(),
        'clientInfo': clientInfo.toJson(),
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
    final parsed = AcpInitializeResult.fromJson(_requireObject(result));
    if (parsed.protocolVersion != protocolVersion) {
      throw AcpProtocolException(
        'Unsupported ACP protocol version ${parsed.protocolVersion}',
      );
    }
    _initialization = parsed;
    return parsed;
  }

  /// Authenticates using an advertised method.
  Future<void> authenticate(
    String methodId, {
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    await connection.request(
      'authenticate',
      params: <String, Object?>{
        'methodId': methodId,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
  }

  /// Creates a new ACP session.
  Future<AcpSessionSetupResult> newSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) => _sessionSetupRequest('session/new', <String, Object?>{
    'cwd': cwd,
    'mcpServers': mcpServers,
    if (additionalDirectories.isNotEmpty)
      'additionalDirectories': additionalDirectories,
    if (meta.isNotEmpty) '_meta': meta,
  }, timeout);

  /// Lists one page of known sessions.
  Future<AcpSessionListResult> listSessions({
    String? cwd,
    String? cursor,
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    _requireCapability(
      'session/list',
      _initialization?.agentCapabilities.session.list ?? true,
    );
    final result = await connection.request(
      'session/list',
      params: <String, Object?>{
        'cwd': ?cwd,
        'cursor': ?cursor,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
    );
    return AcpSessionListResult.fromJson(_requireObject(result));
  }

  /// Loads a stored ACP session and requests history replay.
  Future<AcpSessionSetupResult> loadSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/load',
      _initialization?.agentCapabilities.loadSession ?? true,
    );
    return _sessionSetupRequest(
      'session/load',
      <String, Object?>{
        'sessionId': sessionId,
        'cwd': cwd,
        'mcpServers': mcpServers,
        if (additionalDirectories.isNotEmpty)
          'additionalDirectories': additionalDirectories,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout,
      noTimeout: timeout == null,
    );
  }

  /// Resumes a stored ACP session without requiring history replay.
  Future<AcpSessionSetupResult> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/resume',
      _initialization?.agentCapabilities.session.resume ?? true,
    );
    return _sessionSetupRequest(
      'session/resume',
      <String, Object?>{
        'sessionId': sessionId,
        'cwd': cwd,
        'mcpServers': mcpServers,
        if (additionalDirectories.isNotEmpty)
          'additionalDirectories': additionalDirectories,
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout,
      noTimeout: timeout == null,
    );
  }

  /// Forks a session using the unstable ACP v1 extension.
  Future<AcpSessionSetupResult> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    List<AcpJsonMap> mcpServers = const <AcpJsonMap>[],
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) {
    _requireCapability(
      'session/fork',
      _initialization?.agentCapabilities.session.fork ?? true,
    );
    return _sessionSetupRequest('session/fork', <String, Object?>{
      'sessionId': sessionId,
      'cwd': cwd,
      if (mcpServers.isNotEmpty) 'mcpServers': mcpServers,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
      if (meta.isNotEmpty) '_meta': meta,
    }, timeout);
  }

  /// Closes an active session when supported.
  Future<void> closeSession(String sessionId, {Duration? timeout}) async {
    _requireCapability(
      'session/close',
      _initialization?.agentCapabilities.session.close ?? true,
    );
    await connection.request(
      'session/close',
      params: <String, Object?>{'sessionId': sessionId},
      timeout: timeout,
    );
  }

  /// Deletes a stored session when supported.
  Future<void> deleteSession(String sessionId, {Duration? timeout}) async {
    _requireCapability(
      'session/delete',
      _initialization?.agentCapabilities.session.delete ?? true,
    );
    await connection.request(
      'session/delete',
      params: <String, Object?>{'sessionId': sessionId},
      timeout: timeout,
    );
  }

  /// Sends a prompt turn.
  Future<AcpPromptResult> prompt({
    required String sessionId,
    required List<AcpContentBlock> content,
    AcpJsonMap meta = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final result = await connection.request(
      'session/prompt',
      params: <String, Object?>{
        'sessionId': sessionId,
        'prompt': content.map((block) => block.toJson()).toList(),
        if (meta.isNotEmpty) '_meta': meta,
      },
      timeout: timeout,
      // A prompt response completes only after the streamed turn settles.
      // Provider/transport shutdown and explicit cancel already terminate it,
      // so the generic short control-request deadline is a false timeout here.
      noTimeout: timeout == null,
    );
    return AcpPromptResult.fromJson(_requireObject(result));
  }

  /// Cancels the active prompt turn for [sessionId].
  Future<void> cancel(String sessionId) => connection.notify(
    'session/cancel',
    params: <String, Object?>{'sessionId': sessionId},
  );

  /// Sets a generic session configuration option.
  Future<List<AcpSessionConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
    Duration? timeout,
  }) async {
    if (value is! String && value is! bool) {
      throw ArgumentError.value(value, 'value', 'Must be a string or boolean');
    }
    final result = await connection.request(
      'session/set_config_option',
      params: <String, Object?>{
        'sessionId': sessionId,
        'configId': configId,
        if (value is bool) 'type': 'boolean',
        'value': value,
      },
      timeout: timeout,
    );
    return AcpSessionSetupResult.fromJson(_requireObject(result)).configOptions;
  }

  /// Sets the legacy ACP session mode.
  Future<void> setMode({
    required String sessionId,
    required String modeId,
    Duration? timeout,
  }) async {
    await connection.request(
      'session/set_mode',
      params: <String, Object?>{'sessionId': sessionId, 'modeId': modeId},
      timeout: timeout,
    );
  }

  /// Sets a provider's legacy ACP model extension.
  Future<void> setModel({
    required String sessionId,
    required String modelId,
    Duration? timeout,
  }) async {
    await connection.request(
      'session/set_model',
      params: <String, Object?>{'sessionId': sessionId, 'modelId': modelId},
      timeout: timeout,
    );
  }

  /// Closes the client and its underlying connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _notificationSubscription.cancel();
    await _serverRequestSubscription.cancel();
    await connection.close();
    _pendingServerRequests.clear();
    await _updates.close();
    await _serverRequests.close();
  }

  Future<AcpSessionSetupResult> _sessionSetupRequest(
    String method,
    AcpJsonMap params,
    Duration? timeout, {
    bool noTimeout = false,
  }) async {
    final result = await connection.request(
      method,
      params: params,
      timeout: timeout,
      noTimeout: noTimeout,
    );
    return AcpSessionSetupResult.fromJson(_requireObject(result));
  }

  void _handleNotification(AcpJsonRpcNotification notification) {
    if (notification.method != 'session/update') {
      return;
    }
    final params = AcpJson.object(notification.params);
    if (params == null) {
      return;
    }
    _updates.add(AcpSessionNotification.fromJson(params));
  }

  void _emitServerRequest(AcpJsonRpcServerRequest request) {
    if (!_serverRequests.hasListener ||
        _pendingServerRequestFlushScheduled ||
        _pendingServerRequests.isNotEmpty) {
      _pendingServerRequests.addLast(request);
      if (_serverRequests.hasListener) {
        _schedulePendingServerRequestFlush();
      }
      return;
    }
    _serverRequests.add(request);
  }

  void _schedulePendingServerRequestFlush() {
    if (_pendingServerRequestFlushScheduled || _closed) return;
    _pendingServerRequestFlushScheduled = true;
    scheduleMicrotask(_flushPendingServerRequests);
  }

  void _flushPendingServerRequests() {
    _pendingServerRequestFlushScheduled = false;
    if (_closed || !_serverRequests.hasListener) return;
    while (_pendingServerRequests.isNotEmpty) {
      _serverRequests.add(_pendingServerRequests.removeFirst());
    }
  }

  void _requireCapability(String capability, bool supported) {
    if (!supported) throw AcpUnsupportedCapabilityException(capability);
  }
}

AcpJsonMap _requireObject(Object? value) {
  final object = AcpJson.object(value);
  if (object == null) {
    throw const AcpProtocolException('ACP response result must be an object');
  }
  return object;
}
