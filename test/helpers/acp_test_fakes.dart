import 'dart:async';
import 'dart:convert';

import 'package:monkeyssh/domain/models/acp_writer_lease.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';

/// Recorded parameters from [FakeAcpBridgeConnector.startBridge].
typedef RecordedAcpBridgeStart = ({
  String providerId,
  String providerLabel,
  List<String> launchArgv,
  String cwd,
});

/// Builds a [MonkeyMuxAcpBridgeMetadata] stub with sensible test defaults.
MonkeyMuxAcpBridgeMetadata fakeAcpBridgeMetadata(
  String bridgeId, {
  String provider = 'Copilot CLI',
  String commandHash = 'hash',
  MonkeyMuxAcpProviderState state = MonkeyMuxAcpProviderState.running,
  int clientCount = 0,
  int pendingRequestCount = 0,
  int inFlightTurnCount = 0,
  int nextSequence = 1,
  MonkeyMuxAcpLeaseHolder? writer,
}) => MonkeyMuxAcpBridgeMetadata(
  id: bridgeId,
  provider: provider,
  commandHash: commandHash,
  state: state,
  clientCount: clientCount,
  pendingRequestCount: pendingRequestCount,
  inFlightTurnCount: inFlightTurnCount,
  lastActivity: DateTime.now(),
  startedAt: DateTime.now(),
  nextSequence: nextSequence,
  writer: writer,
);

/// Yields briefly so async ACP message streams and listeners flush.
Future<void> pumpAcpEventLoop() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// Configurable in-memory [AcpTransport] for ACP client/manager tests.
class FakeAcpTransport implements AcpTransport {
  /// Creates an in-memory ACP JSON-RPC transport.
  FakeAcpTransport({
    bool sync = true,
    this.agentCapabilities = const <String, Object?>{'loadSession': true},
    this.sessionIdPrefix = 'session-',
    this.forkIdPrefix = 'fork-',
    this.autoReplyPrompt = false,
    this.failInitialize = false,
    this.throwWhenClosed = false,
    this.onRequest,
  }) : _incoming = StreamController<List<int>>(sync: sync);

  /// Capabilities returned in the default `initialize` response.
  Map<String, Object?> agentCapabilities;

  /// Prefix used for auto-generated `session/new` IDs.
  final String sessionIdPrefix;

  /// Prefix used for auto-generated `session/fork` IDs.
  final String forkIdPrefix;

  /// Whether `session/prompt` replies immediately with `end_turn`.
  final bool autoReplyPrompt;

  /// Whether `initialize` returns a JSON-RPC `-32602` error.
  bool failInitialize;

  /// Whether [write] throws a [StateError] after [close].
  final bool throwWhenClosed;

  /// Optional per-request hook; return `true` when already handled.
  final FutureOr<bool> Function(
    FakeAcpTransport transport,
    Object id,
    String method,
    Map<String, Object?> params,
  )?
  onRequest;

  final StreamController<List<int>> _incoming;

  /// Methods received in order.
  final List<String> methods = <String>[];

  /// Request params grouped by JSON-RPC method name.
  final Map<String, List<Map<String, Object?>>> params =
      <String, List<Map<String, Object?>>>{};

  /// Client responses to server-initiated requests, keyed by JSON-RPC `id`.
  final Map<Object, Map<String, Object?>> responses =
      <Object, Map<String, Object?>>{};

  /// Client capabilities observed in `initialize`.
  Map<String, Object?>? clientCapabilities;

  /// Completed when [close] is called.
  final Completer<void> closedSignal = Completer<void>();

  int _sessionCounter = 0;
  int _serverRequestCounter = 0;

  /// Whether [close] has been invoked.
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  /// Recorded parameter maps for [method].
  List<Map<String, Object?>> paramsFor(String method) =>
      params[method] ?? const <Map<String, Object?>>[];

  @override
  Future<void> write(List<int> bytes) async {
    if (closed && throwWhenClosed) {
      throw StateError('agent closed');
    }
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    final message = (decoded! as Map).cast<String, Object?>();
    final id = message['id'];
    final method = message['method'];
    if (method == null && id != null) {
      responses[id] = message;
      return;
    }
    if (method is String) {
      methods.add(method);
    }
    if (method is! String || id == null) {
      return;
    }
    final requestParams =
        (message['params'] as Map?)?.cast<String, Object?>() ??
        <String, Object?>{};
    params
        .putIfAbsent(method, () => <Map<String, Object?>>[])
        .add(requestParams);
    if (onRequest != null) {
      final handled = await onRequest!(this, id, method, requestParams);
      if (handled || closed) {
        return;
      }
    }
    switch (method) {
      case 'initialize':
        final rawCaps = requestParams['clientCapabilities'];
        if (rawCaps is Map) {
          clientCapabilities = rawCaps.cast<String, Object?>();
        }
        if (failInitialize) {
          replyError(id, -32602, 'Invalid params');
          return;
        }
        reply(id, <String, Object?>{
          'protocolVersion': 1,
          'agentCapabilities': agentCapabilities,
        });
      case 'session/new':
        reply(id, <String, Object?>{
          'sessionId': '$sessionIdPrefix${++_sessionCounter}',
        });
      case 'session/fork':
        reply(id, <String, Object?>{
          'sessionId': '$forkIdPrefix${++_sessionCounter}',
        });
      case 'session/prompt':
        if (autoReplyPrompt) {
          reply(id, const <String, Object?>{'stopReason': 'end_turn'});
        }
      default:
        reply(id, const <String, Object?>{});
    }
  }

  /// Pushes a server-initiated JSON-RPC request with explicit [id].
  void request(Object id, String method, Map<String, Object?> requestParams) =>
      push(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': requestParams,
      });

  /// Pushes a server-initiated JSON-RPC request with an auto-generated ID.
  String sendServerRequest(String method, Map<String, Object?> requestParams) {
    final id = 'srv-${++_serverRequestCounter}';
    request(id, method, requestParams);
    return id;
  }

  /// Pushes a JSON-RPC notification to the client.
  void notify(String method, Map<String, Object?> notificationParams) =>
      push(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': notificationParams,
      });

  /// Pushes a `session/request_permission` request to the client.
  void requestPermission(
    String sessionId, {
    Object? id,
    String toolCallId = 't1',
  }) => request(
    id ?? 'srv-${++_serverRequestCounter}',
    'session/request_permission',
    <String, Object?>{
      'sessionId': sessionId,
      'toolCall': <String, Object?>{
        'toolCallId': toolCallId,
        'title': 'Write file',
      },
      'options': const <Map<String, Object?>>[
        <String, Object?>{
          'optionId': 'allow',
          'name': 'Allow',
          'kind': 'allow_once',
        },
      ],
    },
  );

  /// Sends a successful JSON-RPC result for [id].
  void reply(Object? id, Object? result) =>
      push(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result});

  /// Sends a JSON-RPC error response for [id].
  void replyError(Object? id, int code, String message) =>
      push(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      });

  /// Encodes and enqueues a newline-delimited JSON-RPC frame.
  void push(Map<String, Object?> message) {
    if (closed) return;
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!closedSignal.isCompleted) {
      closedSignal.complete();
    }
    await _incoming.close();
  }
}

/// Configurable in-memory [AcpBridgeConnector] for ACP manager/lifecycle tests.
class FakeAcpBridgeConnector implements AcpBridgeConnector {
  /// Creates an in-memory [AcpBridgeConnector].
  FakeAcpBridgeConnector({
    this.transportFactory,
    this.workingDirectoryResolver,
    this.metadataBuilder,
    this.capabilityBinding,
    this.promptDelivery,
    this.listAvailableBridges = true,
    this.syncTransportStates = false,
    this.defaultProviderLabel = 'Copilot CLI',
  });

  /// Creates the [FakeAcpTransport] for each [connect] call.
  final FakeAcpTransport Function(
    int hostId,
    String bridgeId,
    StreamController<MonkeyMuxAcpTransportState> states, {
    required bool takeOver,
  })?
  transportFactory;

  /// Optional working directory resolver; defaults to returning `cwd` verbatim.
  final Future<String> Function(
    int hostId,
    String cwd, {
    required bool trustAbsolute,
  })?
  workingDirectoryResolver;

  /// Optional metadata builder for [listBridges] and [bridgeStatus].
  final MonkeyMuxAcpBridgeMetadata Function(String bridgeId)? metadataBuilder;

  /// Optional host capability binding returned by [resolveCapabilityBinding].
  final AcpHostCapabilityBinding? capabilityBinding;

  /// Optional prompt delivery resolver forwarded to [AcpBridgeSession].
  final AcpInputDelivery Function(String sessionId)? promptDelivery;

  /// Whether [listBridges] emits entries for [availableBridges].
  final bool listAvailableBridges;

  /// Whether transport state controllers use synchronous delivery.
  final bool syncTransportStates;

  /// Fallback provider name used when building default metadata.
  final String defaultProviderLabel;

  /// Recorded [startBridge] calls.
  final List<RecordedAcpBridgeStart> started = <RecordedAcpBridgeStart>[];

  /// Running bridge IDs in creation order.
  final Set<String> availableBridges = <String>{};

  /// Bridge IDs mapped to their recorded `providerLabel`.
  final Map<String, String> runningLabels = <String, String>{};

  /// Bridge IDs passed to [stopBridge].
  final List<String> stoppedBridges = <String>[];

  /// Latest transport per bridge ID.
  final Map<String, FakeAcpTransport> transports = <String, FakeAcpTransport>{};

  /// All transports created across [connect] calls in order.
  final List<FakeAcpTransport> transportList = <FakeAcpTransport>[];

  /// Transport state controllers created across [connect] calls in order.
  final List<StreamController<MonkeyMuxAcpTransportState>> stateControllers =
      <StreamController<MonkeyMuxAcpTransportState>>[];

  /// `takeOver` flags passed to [connect] in order.
  final List<bool> takeOvers = <bool>[];

  /// Optional completers gating [AcpBridgeSession.close] per bridge ID.
  final Map<String, Completer<void>> closeGates = <String, Completer<void>>{};

  /// Number of [bridgeStatus] calls.
  int statusCount = 0;

  int _bridgeCounter = 0;

  MonkeyMuxAcpBridgeMetadata _metadataFor(String bridgeId) =>
      metadataBuilder?.call(bridgeId) ??
      fakeAcpBridgeMetadata(
        bridgeId,
        provider: runningLabels[bridgeId] ?? defaultProviderLabel,
      );

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    started.add((
      providerId: providerId,
      providerLabel: providerLabel,
      launchArgv: launchArgv,
      cwd: cwd,
    ));
    final bridgeId = 'bridge-${++_bridgeCounter}';
    availableBridges.add(bridgeId);
    runningLabels[bridgeId] = providerLabel;
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => listAvailableBridges
      ? <MonkeyMuxAcpBridgeMetadata>[
          for (final bridgeId in availableBridges) _metadataFor(bridgeId),
        ]
      : const <MonkeyMuxAcpBridgeMetadata>[];

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async =>
      workingDirectoryResolver?.call(
        hostId,
        cwd,
        trustAbsolute: trustAbsolute,
      ) ??
      cwd;

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async {
    statusCount += 1;
    return _metadataFor(bridgeId);
  }

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    stoppedBridges.add(bridgeId);
    availableBridges.remove(bridgeId);
    runningLabels.remove(bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
    bool takeOver = false,
  }) {
    takeOvers.add(takeOver);
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast(
      sync: syncTransportStates,
    );
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    final transport =
        transportFactory?.call(hostId, bridgeId, states, takeOver: takeOver) ??
        FakeAcpTransport();
    transports[bridgeId] = transport;
    transportList.add(transport);
    stateControllers.add(states);
    final client = AcpClient(AcpJsonRpcConnection(transport: transport));
    return AcpBridgeSession(
      client: client,
      transportStates: states.stream,
      transportErrors: errors.stream,
      promptDelivery: promptDelivery,
      onClose: () async {
        final gate = closeGates[bridgeId];
        if (gate != null) await gate.future;
        await client.close();
        await states.close();
        await errors.close();
      },
    );
  }

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => capabilityBinding;
}
