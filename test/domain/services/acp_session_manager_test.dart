// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_telemetry.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// In-memory ACP agent that responds to a real [AcpClient] over NDJSON bytes
/// and can push server-initiated notifications and permission requests.
class _FakeAcpServer implements AcpTransport {
  _FakeAcpServer({
    this.supportsResume = true,
    this.supportsLoad = true,
    this.authMethods = const <Map<String, Object?>>[],
    this.failNewSession = false,
    this.rejectInitialize = false,
    this.rejectResume = false,
    this.rejectLoadAlreadyLoaded = false,
    this.alreadyLoadedSessionId,
    this.newSessionErrorCode = -32000,
    this.promptErrorMessage,
    this.replayTextOnLoad,
    this.replayTextOnResume,
    this.replayUpdateCountOnLoad = 0,
    this.replayUpdatesOnLoad = const <Map<String, Object?>>[],
    this.loadResponseGate,
    this.permissionIdOnLoad,
    this.permissionIdOnResume,
  });

  final bool supportsResume;
  final bool supportsLoad;
  final List<Map<String, Object?>> authMethods;

  /// When true, `session/new` replies with a JSON-RPC error.
  final bool failNewSession;

  /// When true, `initialize` rejects the client metadata.
  final bool rejectInitialize;

  /// When true, `session/resume` rejects reconnect setup.
  final bool rejectResume;

  /// When true, `session/load` reports that the live session is already loaded.
  final bool rejectLoadAlreadyLoaded;

  /// Optional session id named by the already-loaded error response.
  final String? alreadyLoadedSessionId;

  /// When true, `session/delete` returns a provider error.
  bool failDelete = false;

  /// JSON-RPC error code returned when session creation is rejected.
  final int newSessionErrorCode;

  /// When set, session/prompt returns this remote error message.
  String? promptErrorMessage;

  /// When set, a `session/load` pushes an agent message chunk with this text
  /// BEFORE replying, simulating synchronous history replay during the load.
  final String? replayTextOnLoad;

  /// Optional history text synchronously replayed by `session/resume`.
  final String? replayTextOnResume;

  /// Number of same-message content chunks synchronously replayed on load.
  final int replayUpdateCountOnLoad;

  /// Exact typed updates synchronously replayed after the generated burst.
  final List<Map<String, Object?>> replayUpdatesOnLoad;

  /// Holds the session/load response so reconnecting-state publication can be
  /// observed independently from provider history latency.
  final Future<void>? loadResponseGate;

  /// When set, a `session/load` pushes a permission request with this stable
  /// JSON-RPC id before replying, simulating a replayed pending permission.
  final String? permissionIdOnLoad;

  /// Stable permission request delivered during the first resumed setup call.
  final String? permissionIdOnResume;

  final _incoming = StreamController<List<int>>(sync: true);
  final List<String> methods = <String>[];
  final List<String> newSessionCwds = <String>[];
  final List<String> cancelledSessions = <String>[];
  final Map<Object, Object?> permissionResponses = <Object, Object?>{};
  final Queue<Object> _heldPromptIds = Queue<Object>();
  bool holdPrompts = false;
  int _sessionCounter = 0;
  int _serverRequestId = 0;
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    final message = (decoded! as Map).cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];

    if (method == null && id != null) {
      // A client response to one of our server requests.
      permissionResponses[id] = message['result'] ?? message['error'];
      return;
    }
    if (method is String) methods.add(method);

    if (id == null) {
      if (method == 'session/cancel') {
        final params = (message['params']! as Map).cast<String, Object?>();
        cancelledSessions.add(params['sessionId']! as String);
      }
      return;
    }

    switch (method) {
      case 'initialize':
        if (rejectInitialize) {
          _replyError(id, -32602, 'Invalid params');
          break;
        }
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': supportsLoad,
            'sessionCapabilities': {
              if (supportsResume) 'resume': <String, Object?>{},
              'fork': <String, Object?>{},
              'close': <String, Object?>{},
              'delete': <String, Object?>{},
            },
          },
          if (authMethods.isNotEmpty) 'authMethods': authMethods,
        });
      case 'session/new':
        final params = (message['params']! as Map).cast<String, Object?>();
        newSessionCwds.add(params['cwd']! as String);
        if (authMethods.isNotEmpty || failNewSession) {
          _replyError(id, newSessionErrorCode, 'Session creation failed');
        } else {
          _reply(id, {'sessionId': 'session-${++_sessionCounter}'});
        }
      case 'session/fork':
        final sessionId = 'fork-${++_sessionCounter}';
        _reply(id, {'sessionId': sessionId});
      case 'session/resume':
        final params = (message['params']! as Map).cast<String, Object?>();
        final sessionId = params['sessionId'] as String? ?? '';
        if (replayTextOnResume != null) {
          pushUpdate(sessionId, {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'resume-replay',
            'content': {'type': 'text', 'text': replayTextOnResume},
          });
        }
        if (permissionIdOnResume != null) {
          _pushPermission(permissionIdOnResume!, sessionId, 'replayed-tool');
        }
        if (rejectResume) {
          _replyError(id, -32603, 'Resume failed');
          break;
        }
        _reply(id, {
          'configOptions': [
            {
              'type': 'boolean',
              'id': 'reasoning',
              'name': 'Reasoning',
              'value': true,
            },
          ],
        });
      case 'session/load':
        final params = (message['params']! as Map).cast<String, Object?>();
        final sessionId = params['sessionId'] as String? ?? '';
        if (rejectLoadAlreadyLoaded) {
          final loadedId = alreadyLoadedSessionId ?? sessionId;
          _replyError(id, -32602, 'Session $loadedId is already loaded');
          break;
        }
        // Emit synchronous replay BEFORE replying to the load request.
        if (replayTextOnLoad != null) {
          pushUpdate(sessionId, {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'replay',
            'content': {'type': 'text', 'text': replayTextOnLoad},
          });
        }
        for (var index = 0; index < replayUpdateCountOnLoad; index++) {
          pushUpdate(sessionId, {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'replay-burst',
            'content': {'type': 'text', 'text': 'chunk-$index '},
          });
        }
        for (final update in replayUpdatesOnLoad) {
          pushUpdate(sessionId, update);
        }
        if (permissionIdOnLoad != null) {
          _pushPermission(permissionIdOnLoad!, sessionId, 'replay-tool');
        }
        if (loadResponseGate != null) await loadResponseGate;
        _reply(id, <String, Object?>{});
      case 'session/prompt':
        if (promptErrorMessage != null) {
          _replyError(id, -32000, promptErrorMessage!);
        } else if (holdPrompts) {
          _heldPromptIds.addLast(id);
        } else {
          _reply(id, {'stopReason': 'end_turn'});
        }
      case 'session/set_config_option':
        _reply(id, {
          'configOptions': [
            {
              'type': 'boolean',
              'id': 'reasoning',
              'name': 'Reasoning',
              'value': true,
            },
          ],
        });
      case 'session/close':
        _reply(id, <String, Object?>{});
      case 'session/delete':
        if (failDelete) {
          _replyError(id, -32603, 'Delete failed');
        } else {
          _reply(id, <String, Object?>{});
        }
      default:
        _reply(id, <String, Object?>{});
    }
  }

  void completeNextPrompt() {
    final id = _heldPromptIds.removeFirst();
    _reply(id, {'stopReason': 'end_turn'});
  }

  int get heldPromptCount => _heldPromptIds.length;

  void pushUpdate(String sessionId, Map<String, Object?> update) {
    _push({
      'jsonrpc': '2.0',
      'method': 'session/update',
      'params': {'sessionId': sessionId, 'update': update},
    });
  }

  /// Sends a permission request with an auto-allocated id and returns it.
  Object requestPermission(String sessionId, String toolCallId) {
    final id = 'srv-${++_serverRequestId}';
    _pushPermission(id, sessionId, toolCallId);
    return id;
  }

  void _pushPermission(String id, String sessionId, String toolCallId) {
    _push({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/request_permission',
      'params': {
        'sessionId': sessionId,
        'toolCall': {'toolCallId': toolCallId, 'title': 'Write file'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
        ],
      },
    });
  }

  /// Sends a server-to-client request with an auto-allocated id and returns
  /// that id. The client's eventual response lands in [permissionResponses].
  Object pushServerRequest(String method, Map<String, Object?> params) {
    final id = 'srv-${++_serverRequestId}';
    _push({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return id;
  }

  void _reply(Object? id, Object? result) =>
      _push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _replyError(Object? id, int code, String message) => _push({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });

  void _push(Map<String, Object?> message) {
    if (closed) return;
    _incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

/// Records every telemetry call for assertions without needing Firebase.
class _RecordingTelemetrySink implements AcpTelemetrySink {
  final events = <String>[];

  @override
  void featureOpened() => events.add('featureOpened');

  @override
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) => events.add('sessionOpened:$providerCategory:$isReconnect');

  @override
  void sessionEnded({required String reason}) =>
      events.add('sessionEnded:$reason');

  @override
  void reconnectOutcome({required bool succeeded, String? failureCategory}) =>
      events.add('reconnectOutcome:$succeeded:${failureCategory ?? ''}');

  @override
  void attachmentSent({required String category, required int count}) =>
      events.add('attachmentSent:$category:$count');

  @override
  void permissionOutcome({required String outcome}) =>
      events.add('permissionOutcome:$outcome');

  @override
  void failure({required String category}) => events.add('failure:$category');
}

/// Minimal in-memory filesystem used to test capability-service wiring.
class _FakeCapabilityFileSystem implements AcpRemoteFileSystem {
  final files = <String, Uint8List>{};
  final writes = <String, String>{};

  @override
  Future<String> canonicalizeExistingPath(String path) async => path;

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    final bytes = files[path];
    if (bytes == null) {
      throw const AcpClientCapabilityException('Missing file');
    }
    return bytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    writes[path] = utf8.decode(bytes);
  }
}

/// Minimal terminal executor used only to satisfy [AcpHostCapabilityBinding]
/// in capability-wiring tests that do not exercise `terminal/*` methods.
class _FakeCapabilityTerminalExecutor implements AcpTerminalExecutor {
  @override
  Future<AcpTerminalProcess> start(String command) =>
      throw UnimplementedError();
}

/// Fake connector that records bridge lifecycle calls and wires each bridge to
/// a controllable [_FakeAcpServer].
class _FakeConnector implements AcpBridgeConnector {
  _FakeConnector({this.serverFactory, this.capabilityBinding});

  final _FakeAcpServer Function(int hostId, String bridgeId)? serverFactory;

  /// When set, returned for every [resolveCapabilityBinding] call, mirroring
  /// production wiring where the bridge attachment gets one same-host
  /// filesystem/terminal binding.
  final AcpHostCapabilityBinding? capabilityBinding;

  final List<String> startedBridges = <String>[];
  final List<String> stoppedBridges = <String>[];
  final Set<String> availableBridges = <String>{};
  final Map<String, _FakeAcpServer> servers = <String, _FakeAcpServer>{};
  List<MonkeyMuxAcpBridgeMetadata> remoteMetadata =
      const <MonkeyMuxAcpBridgeMetadata>[];
  final Map<String, StreamController<MonkeyMuxAcpTransportState>>
  transportStateControllers =
      <String, StreamController<MonkeyMuxAcpTransportState>>{};
  final Map<String, StreamController<MonkeyMuxAcpBridgeException>>
  transportErrorControllers =
      <String, StreamController<MonkeyMuxAcpBridgeException>>{};
  MonkeyMuxInstallConfirmation? lastListConfirmInstall;
  Exception? startError;
  Exception? stopError;
  int _bridgeCounter = 0;
  int bridgeStatusInFlightTurnCount = 0;
  bool skippedHistoricalReplay = false;
  final Map<String, int> lastDeliveredSequences = <String, int>{};
  final Map<String, List<int>> connectionAcknowledgements =
      <String, List<int>>{};

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    if (startError case final error?) throw error;
    final bridgeId = 'bridge-${++_bridgeCounter}';
    startedBridges.add(bridgeId);
    availableBridges.add(bridgeId);
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    lastListConfirmInstall = confirmInstall;
    if (remoteMetadata.isNotEmpty) {
      return remoteMetadata;
    }
    return [
      for (final bridgeId in availableBridges)
        MonkeyMuxAcpBridgeMetadata(
          id: bridgeId,
          provider: 'Copilot CLI',
          commandHash: 'hash',
          state: MonkeyMuxAcpProviderState.running,
          clientCount: 0,
          pendingRequestCount: 0,
          inFlightTurnCount: bridgeStatusInFlightTurnCount,
          lastActivity: DateTime.now(),
          startedAt: DateTime.now(),
          nextSequence: 1,
        ),
    ];
  }

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async {
    if (cwd == '~') {
      return '/home/test';
    }
    if (cwd.startsWith('~/')) {
      return '/home/test/${cwd.substring(2)}';
    }
    return cwd.startsWith('/') ? cwd : '/home/test/$cwd';
  }

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async => MonkeyMuxAcpBridgeMetadata(
    id: bridgeId,
    provider: 'Copilot CLI',
    commandHash: 'hash',
    state: MonkeyMuxAcpProviderState.running,
    clientCount: 0,
    pendingRequestCount: 0,
    inFlightTurnCount: bridgeStatusInFlightTurnCount,
    lastActivity: DateTime.now(),
    startedAt: DateTime.now(),
    nextSequence: 1,
  );

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    stoppedBridges.add(bridgeId);
    if (stopError case final error?) throw error;
    availableBridges.remove(bridgeId);
  }

  StreamController<MonkeyMuxAcpTransportState> statesFor(String bridgeId) =>
      transportStateControllers[bridgeId]!;

  StreamController<MonkeyMuxAcpBridgeException> errorsFor(String bridgeId) =>
      transportErrorControllers[bridgeId]!;

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    connectionAcknowledgements
        .putIfAbsent(bridgeId, () => <int>[])
        .add(lastAcknowledgedSequence);
    final server = serverFactory?.call(hostId, bridgeId) ?? _FakeAcpServer();
    servers[bridgeId] = server;
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast();
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    transportStateControllers[bridgeId] = states;
    transportErrorControllers[bridgeId] = errors;
    final connection = AcpJsonRpcConnection(transport: server);
    final client = AcpClient(connection);
    return AcpBridgeSession(
      client: client,
      transportStates: states.stream,
      transportErrors: errors.stream,
      skippedHistoricalReplay: () => skippedHistoricalReplay,
      lastDeliveredSequence: () => lastDeliveredSequences[bridgeId] ?? 0,
      onClose: () async {
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

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpProviderService providerService;
  late AcpRecentSessionsService recentSessions;
  late _FakeConnector connector;
  late AcpSessionManager manager;
  var isPro = false;

  AcpSessionManager buildManager() => AcpSessionManager(
    connector: connector,
    providerService: providerService,
    recentSessions: recentSessions,
    isProUnlocked: () => isPro,
    diagnostics: const NoopDiagnosticsLogger(),
    detachedTurnPollInterval: const Duration(milliseconds: 10),
  );

  AcpSessionManager buildManagerWith(
    _FakeConnector custom, {
    AcpTelemetrySink telemetry = const NoopAcpTelemetrySink(),
  }) {
    final built = AcpSessionManager(
      connector: custom,
      providerService: providerService,
      recentSessions: recentSessions,
      isProUnlocked: () => isPro,
      diagnostics: const NoopDiagnosticsLogger(),
      telemetry: telemetry,
      detachedTurnPollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(built.dispose);
    return built;
  }

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    providerService = AcpProviderService(settings);
    recentSessions = AcpRecentSessionsService(settings);
    connector = _FakeConnector();
    isPro = false;
    manager = buildManager();
  });

  tearDown(() async {
    await manager.dispose();
    await database.close();
  });

  Future<AcpSessionKey> startCopilot({int hostId = 1}) async {
    final result = await manager.startNewSession(
      hostId: hostId,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    );
    expect(result, isA<AcpSessionLaunchStarted>());
    return (result as AcpSessionLaunchStarted).key;
  }

  test('starts a new session and reaches ready', () async {
    final key = await startCopilot();
    final state = manager.state.byKeyValue(key.value)!;
    expect(state.status, AcpConnectionStatus.ready);
    expect(state.isLive, isTrue);
    expect(connector.startedBridges, hasLength(1));
    expect(manager.state.selectedKey, key.value);
  });

  test('toggles native YOLO for one live session at runtime', () async {
    final key = await startCopilot();
    final server = connector.servers[key.bridgeId]!;

    expect(
      manager.state.byKeyValue(key.value)!.autoApprovePermissions,
      isFalse,
    );
    await manager.setAutoApprovePermissions(key, enabled: true);
    expect(manager.state.byKeyValue(key.value)!.autoApprovePermissions, isTrue);

    final approvedId = server.requestPermission(
      key.acpSessionId,
      'auto-approved-tool',
    );
    await _pump();
    expect(server.permissionResponses[approvedId], isNotNull);
    expect(manager.state.byKeyValue(key.value)!.pendingPermissions, isEmpty);

    await manager.setAutoApprovePermissions(key, enabled: false);
    expect(
      manager.state.byKeyValue(key.value)!.autoApprovePermissions,
      isFalse,
    );
    server.requestPermission(key.acpSessionId, 'ask-first-tool');
    await _pump();
    expect(
      manager.state.byKeyValue(key.value)!.pendingPermissions,
      hasLength(1),
    );
  });

  test('uses selected profile in the native session title', () async {
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.copilotCli,
      providerLabelOverride: 'Hermes · work',
      cwd: '/repo',
    );

    expect(result, isA<AcpSessionLaunchStarted>());
    final key = (result as AcpSessionLaunchStarted).key;
    expect(manager.state.byKeyValue(key.value)!.providerLabel, 'Hermes · work');
  });

  test('maps locked Cursor keychain to authentication required', () async {
    connector.startError = const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.keychainLocked,
      'Cursor Agent needs the Mac login keychain unlocked.',
    );

    final result = await manager.startNewSession(
      hostId: 1,
      providerId: AcpBuiltinProviderIds.cursorAgent,
      cwd: '/repo',
    );

    expect(result, isA<AcpSessionLaunchFailed>());
    final error = (result as AcpSessionLaunchFailed).error;
    expect(error.kind, AcpSessionErrorKind.authenticationRequired);
    expect(
      error.message,
      'Unlock the Mac login keychain to start Cursor Agent.',
    );
  });

  test(
    'resolves a tilde cwd before launching the bridge and ACP session',
    () async {
      final result = await manager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '~/Code/project',
      );

      expect(result, isA<AcpSessionLaunchStarted>());
      final key = (result as AcpSessionLaunchStarted).key;
      expect(
        manager.state.byKeyValue(key.value)!.cwd,
        '/home/test/Code/project',
      );
      expect(connector.servers[key.bridgeId]!.newSessionCwds, [
        '/home/test/Code/project',
      ]);
    },
  );

  test(
    'maps an initialize rejection to an actionable protocol error',
    () async {
      final rejectingConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(rejectInitialize: true),
      );
      final rejectingManager = buildManagerWith(rejectingConnector);

      final result = await rejectingManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchFailed>());
      final failure = result as AcpSessionLaunchFailed;
      expect(failure.error.kind, AcpSessionErrorKind.protocol);
      expect(failure.error.message, contains('-32602'));
    },
  );

  test('marks only transient bridge failures retryable', () async {
    for (final testCase in <(MonkeyMuxAcpBridgeErrorKind, bool)>[
      (MonkeyMuxAcpBridgeErrorKind.sshChannel, true),
      (MonkeyMuxAcpBridgeErrorKind.closed, true),
      (MonkeyMuxAcpBridgeErrorKind.nonWriter, false),
      (MonkeyMuxAcpBridgeErrorKind.invalidFrame, false),
    ]) {
      final failingConnector = _FakeConnector()
        ..startError = MonkeyMuxAcpBridgeException(
          testCase.$1,
          'Bridge failed.',
        );
      final failingManager = buildManagerWith(failingConnector);

      final result = await failingManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchFailed>());
      expect(
        (result as AcpSessionLaunchFailed).error.retryable,
        testCase.$2,
        reason: testCase.$1.name,
      );
    }
  });

  test(
    'does not mistake a non-auth session error for required login',
    () async {
      final connector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(
          authMethods: const [
            {'id': 'copilot-login', 'name': 'Sign in'},
          ],
          newSessionErrorCode: -32603,
        ),
      );
      final localManager = buildManagerWith(connector);

      final result = await localManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchFailed>());
      final failure = result as AcpSessionLaunchFailed;
      expect(failure.error.kind, AcpSessionErrorKind.protocol);
      expect(failure.error.message, contains('-32603'));
    },
  );

  test('records a non-content recent-session reference', () async {
    final key = await startCopilot();
    final recents = await recentSessions.list();
    expect(recents, hasLength(1));
    final ref = recents.single;
    expect(ref.acpSessionId, key.acpSessionId);
    expect(ref.hostId, 1);
    expect(ref.cwd, '/repo');
    // No content keys are ever stored.
    expect(ref.toJson().containsKey('messages'), isFalse);
  });

  test('refuses an unapproved custom provider command', () async {
    final definition = AcpCustomProviderDefinition.create(
      id: 'custom-1',
      label: 'My Agent',
      launchCommand: AcpLaunchCommand(executable: 'agent'),
    );
    await providerService.saveCustomProvider(
      definition.update(
        launchCommand: AcpLaunchCommand(
          executable: 'agent',
          arguments: const ['--changed'],
        ),
      ),
    );
    final result = await manager.startNewSession(
      hostId: 1,
      providerId: 'custom-1',
      cwd: '/repo',
    );
    expect(result, isA<AcpSessionLaunchFailed>());
    expect(
      (result as AcpSessionLaunchFailed).error.kind,
      AcpSessionErrorKind.commandNotApproved,
    );
    expect(connector.startedBridges, isEmpty);
  });

  group('concurrency', () {
    test('free tier blocks a second live session across hosts', () async {
      final first = await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchBlocked>());
      final blocked = result as AcpSessionLaunchBlocked;
      expect(blocked.decision.blockingSessionKeys, [first.value]);
      // No second bridge is started when blocked.
      expect(connector.startedBridges, hasLength(1));
    });

    test('detached remote window still blocks a second free session', () async {
      final first = await startCopilot();
      await manager.detachSession(first);

      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchBlocked>());
      expect(manager.liveSessionKeyValues, contains(first.value));
      expect(connector.availableBridges, contains(first.bridgeId));
    });

    test('pro tier allows multiple live sessions', () async {
      isPro = true;
      await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      expect(manager.liveSessionKeyValues, hasLength(2));
    });

    test('replace stops the blocking session and continues for free', () async {
      final first = await startCopilot();
      final result = await manager.startNewSession(
        hostId: 2,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
        replace: [first],
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      expect(connector.stoppedBridges, [first.bridgeId]);
      expect(manager.state.byKeyValue(first.value), isNull);
      expect(manager.liveSessionKeyValues, hasLength(1));
    });
  });

  group('streaming normalization', () {
    test('merges message chunks and tool calls into the timeline', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final id = key.acpSessionId;
      server
        ..pushUpdate(id, {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'm1',
          'content': {'type': 'text', 'text': 'Hel'},
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'm1',
          'content': {'type': 'text', 'text': 'lo'},
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't1',
          'title': 'Read',
          'status': 'pending',
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 't1',
          'status': 'completed',
        });
      await _pump();
      final timeline = manager.state.byKeyValue(key.value)!.timeline;
      expect(timeline.entries, hasLength(2));
      final message = timeline.entries.whereType<AcpMessageEntry>().single;
      expect(message.content, hasLength(2));
      final tool = timeline.entries.whereType<AcpToolCallEntry>().single;
      expect(tool.status, isNotNull);
      expect(tool.status!.value, 'completed');
    });

    test('debounces and bounds later session metadata in recents', () async {
      final key = await startCopilot();
      final title = List.filled(400, 'x').join();
      connector.servers[key.bridgeId]!.pushUpdate(key.acpSessionId, {
        'sessionUpdate': 'session_info_update',
        'title': title,
      });
      await _pump();
      await Future<void>.delayed(const Duration(milliseconds: 550));

      final recent = (await recentSessions.list()).firstWhere(
        (candidate) => candidate.key == key,
      );
      expect(recent.title, title.substring(0, 256));
      expect(
        recent.lastActivityAt.millisecondsSinceEpoch,
        manager.state
            .byKeyValue(key.value)!
            .lastActivityAt
            .millisecondsSinceEpoch,
      );
    });

    test('applies available-commands and config updates to state', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final id = key.acpSessionId;
      server
        ..pushUpdate(id, {
          'sessionUpdate': 'available_commands_update',
          'availableCommands': [
            {'name': 'review', 'description': 'Review code'},
          ],
        })
        ..pushUpdate(id, {
          'sessionUpdate': 'usage_update',
          'used': 100,
          'size': 1000,
        });
      await _pump();
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.availableCommands.single.name, 'review');
      expect(state.usage?.used, 100);
    });

    test('ignores updates addressed to other sessions', () async {
      final key = await startCopilot();
      connector.servers[key.bridgeId]!.pushUpdate('some-other-session', {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'nope'},
      });
      await _pump();
      expect(manager.state.byKeyValue(key.value)!.timeline.isEmpty, isTrue);
    });
  });

  group('permissions', () {
    test('surfaces and resolves a pending permission', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();
      final pending = manager.state.byKeyValue(key.value)!.pendingPermissions;
      expect(pending, hasLength(1));
      expect(pending.single.toolCallId, 't1');
      expect(pending.single.toolTitle, 'Write file');

      await manager.respondToPermission(
        key,
        pending.single.requestKey,
        'allow',
      );
      await _pump();
      expect(manager.state.byKeyValue(key.value)!.pendingPermissions, isEmpty);
      expect(server.permissionResponses[requestId], isNotNull);
    });
  });

  group('capability wiring', () {
    test('routes fs/read_text_file through the resolved binding instead of '
        'leaving it unanswered', () async {
      final fileSystem = _FakeCapabilityFileSystem()
        ..files['/repo/a.txt'] = Uint8List.fromList(utf8.encode('hello'));
      final capableConnector = _FakeConnector(
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _FakeCapabilityTerminalExecutor(),
        ),
      );
      final capableManager = buildManagerWith(capableConnector);
      final result = await capableManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      final server = capableConnector.servers[key.bridgeId]!;

      final requestId = server.pushServerRequest('fs/read_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/repo/a.txt',
      });
      await _pump();

      final response = server.permissionResponses[requestId];
      expect(response, isNotNull);
      expect((response! as Map)['content'], 'hello');
    });

    test(
      'declines fs/terminal requests safely when no binding is available',
      () async {
        final key = await startCopilot();
        final server = connector.servers[key.bridgeId]!;
        final requestId = server.pushServerRequest('fs/read_text_file', {
          'sessionId': key.acpSessionId,
          'path': '/repo/a.txt',
        });
        await _pump();
        final response = server.permissionResponses[requestId];
        expect(response, isNotNull);
        expect((response! as Map).containsKey('code'), isTrue);
      },
    );

    test('queues a pending write, surfaces it on session state, and '
        'approveWrite completes it', () async {
      final fileSystem = _FakeCapabilityFileSystem();
      final capableConnector = _FakeConnector(
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _FakeCapabilityTerminalExecutor(),
        ),
      );
      final capableManager = buildManagerWith(capableConnector);
      final result = await capableManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      final server = capableConnector.servers[key.bridgeId]!;

      final requestId = server.pushServerRequest('fs/write_text_file', {
        'sessionId': key.acpSessionId,
        'path': '/repo/new.txt',
        'content': 'written content',
      });
      await _pump();

      final pendingWrites = capableManager.state
          .byKeyValue(key.value)!
          .pendingWrites;
      expect(pendingWrites, hasLength(1));
      expect(pendingWrites.single.path, '/repo/new.txt');

      await capableManager.approveWrite(key, pendingWrites.single.requestKey);
      await _pump();

      expect(fileSystem.writes['/repo/new.txt'], 'written content');
      expect(
        capableManager.state.byKeyValue(key.value)!.pendingWrites,
        isEmpty,
      );
      // A successful write responds with a null JSON-RPC result, so check
      // presence rather than non-null.
      expect(server.permissionResponses.containsKey(requestId), isTrue);
    });

    test(
      'rejectWrite declines without writing and clears the pending state',
      () async {
        final fileSystem = _FakeCapabilityFileSystem();
        final capableConnector = _FakeConnector(
          capabilityBinding: AcpHostCapabilityBinding(
            fileSystem: fileSystem,
            terminalExecutor: _FakeCapabilityTerminalExecutor(),
          ),
        );
        final capableManager = buildManagerWith(capableConnector);
        final result = await capableManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (result as AcpSessionLaunchStarted).key;

        capableConnector.servers[key.bridgeId]!.pushServerRequest(
          'fs/write_text_file',
          {
            'sessionId': key.acpSessionId,
            'path': '/repo/new.txt',
            'content': 'nope',
          },
        );
        await _pump();
        final requestKey = capableManager.state
            .byKeyValue(key.value)!
            .pendingWrites
            .single
            .requestKey;

        await capableManager.rejectWrite(key, requestKey);
        await _pump();

        expect(fileSystem.writes, isEmpty);
        expect(
          capableManager.state.byKeyValue(key.value)!.pendingWrites,
          isEmpty,
        );
      },
    );

    test('detaching locally leaves a pending permission unanswered so it can '
        'be replayed and answered after reconnect', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();

      await manager.detachSession(key);
      await _pump();

      // A soft/local detach must never answer the request on the agent's
      // behalf: the remote bridge keeps it pending until a real decision.
      expect(server.permissionResponses[requestId], isNull);
    });

    test(
      'live attach mirrors a permission replayed after capability rebind',
      () async {
        var connectionCount = 0;

        final replayConnector = _FakeConnector(
          serverFactory: (_, _) {
            connectionCount++;
            return _FakeAcpServer(
              permissionIdOnResume: connectionCount > 1
                  ? 'replayed-on-attach'
                  : null,
            );
          },
        );
        final replayManager = buildManagerWith(replayConnector);
        final started = await replayManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;
        await replayManager.detachSession(key);
        final result = await replayManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );
        expect(result, isA<AcpSessionLaunchStarted>());
        await _pump();

        final pending = replayManager.state
            .byKeyValue(key.value)!
            .pendingPermissions;
        expect(pending, hasLength(1));
        expect(pending.single.toolCallId, 'replayed-tool');
      },
    );

    test('explicit stop cancels an unanswered pending permission because no '
        'one will ever answer it', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!;
      final requestId = server.requestPermission(key.acpSessionId, 't1');
      await _pump();

      await manager.stopSession(key);
      await _pump();

      expect(server.permissionResponses[requestId], isNotNull);
    });

    test('detach then reconnect keeps a pending permission visible without '
        'requiring the agent to replay it (the registry is carried over, not '
        'recreated empty)', () async {
      final key = await startCopilot();
      connector.servers[key.bridgeId]!.requestPermission(
        key.acpSessionId,
        't1',
      );
      await _pump();
      final pendingBefore = manager.state
          .byKeyValue(key.value)!
          .pendingPermissions;
      expect(pendingBefore, hasLength(1));
      final requestKey = pendingBefore.single.requestKey;

      await manager.detachSession(key);
      await _pump();
      // Detaching alone must never drop a still-pending decision.
      expect(
        manager.state.byKeyValue(key.value)!.pendingPermissions,
        hasLength(1),
      );

      final reconnectResult = await manager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(reconnectResult, isA<AcpSessionLaunchStarted>());
      await _pump();

      // A live bridge reattach intentionally calls neither session/resume nor
      // session/load. The pending permission is still visible here purely
      // because the capability registry was
      // carried over into the new attachment, not recreated empty.
      final pendingAfter = manager.state
          .byKeyValue(key.value)!
          .pendingPermissions;
      expect(pendingAfter, hasLength(1));
      expect(pendingAfter.single.requestKey, requestKey);
      expect(pendingAfter.single.toolCallId, 't1');
    });

    test('detach then reconnect keeps a pending write visible without '
        'requiring the agent to replay it', () async {
      final fileSystem = _FakeCapabilityFileSystem();
      final capableConnector = _FakeConnector(
        capabilityBinding: AcpHostCapabilityBinding(
          fileSystem: fileSystem,
          terminalExecutor: _FakeCapabilityTerminalExecutor(),
        ),
      );
      final capableManager = buildManagerWith(capableConnector);
      final result = await capableManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      capableConnector.servers[key.bridgeId]!
          .pushServerRequest('fs/write_text_file', {
            'sessionId': key.acpSessionId,
            'path': '/repo/new.txt',
            'content': 'pending content',
          });
      await _pump();
      expect(
        capableManager.state.byKeyValue(key.value)!.pendingWrites,
        hasLength(1),
      );

      await capableManager.detachSession(key);
      await capableManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      await _pump();

      final pendingWrites = capableManager.state
          .byKeyValue(key.value)!
          .pendingWrites;
      expect(pendingWrites, hasLength(1));
      expect(pendingWrites.single.path, '/repo/new.txt');
    });

    test(
      'stopping one forked session cancels only that session\'s pending '
      'permission, leaving the sibling fork and the shared bridge untouched',
      () async {
        isPro = true;
        final key = await startCopilot();
        final forkResult = await manager.forkSession(key);
        final forkKey = (forkResult as AcpSessionLaunchStarted).key;
        expect(forkKey.bridgeId, key.bridgeId);

        final server = connector.servers[key.bridgeId]!;
        final originalRequestId = server.requestPermission(
          key.acpSessionId,
          't-original',
        );
        server.requestPermission(forkKey.acpSessionId, 't-fork');
        await _pump();
        expect(
          manager.state.byKeyValue(key.value)!.pendingPermissions,
          hasLength(1),
        );
        expect(
          manager.state.byKeyValue(forkKey.value)!.pendingPermissions,
          hasLength(1),
        );

        await manager.stopSession(key);
        await _pump();

        // The original session is gone and its pending permission was
        // cancelled (answered) even though the fork keeps the bridge alive.
        expect(manager.state.byKeyValue(key.value), isNull);
        expect(server.permissionResponses[originalRequestId], isNotNull);
        // The fork's own pending permission and the shared bridge are both
        // untouched.
        expect(
          manager.state.byKeyValue(forkKey.value)!.pendingPermissions,
          hasLength(1),
        );
        expect(connector.stoppedBridges, isEmpty);
      },
    );
  });

  test(
    'remote bridge metadata preserves local title while refreshing',
    () async {
      final now = DateTime(2026);
      await recentSessions.record(
        AcpRecentSessionRef(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: '0123456789abcdef0123456789abcdef',
          acpSessionId: 'remote-session',
          title: 'Preserved title',
          cwd: '/old',
          createdAt: DateTime(2025),
          lastActivityAt: DateTime(2025),
        ),
      );
      connector.remoteMetadata = [
        MonkeyMuxAcpBridgeMetadata(
          id: '0123456789abcdef0123456789abcdef',
          providerId: AcpBuiltinProviderIds.copilotCli,
          sessionId: 'remote-session',
          cwd: '/repo',
          provider: 'Copilot CLI',
          commandHash: 'hash',
          state: MonkeyMuxAcpProviderState.running,
          clientCount: 0,
          pendingRequestCount: 0,
          inFlightTurnCount: 0,
          lastActivity: now,
          startedAt: now,
          nextSequence: 1,
        ),
      ];

      final sessions = await manager.loadNavigableSessions(1);

      expect(sessions, hasLength(1));
      expect(sessions.single.acpSessionId, 'remote-session');
      expect(sessions.single.title, 'Preserved title');
      expect(sessions.single.cwd, '/repo');
      expect(
        (await manager.loadRecentSessions()).map((recent) => recent.key.value),
        contains(sessions.single.key.value),
      );
    },
  );

  group('prompt lifecycle', () {
    test('prompt returns a stop reason and clears streaming', () async {
      final key = await startCopilot();
      final result = await manager.prompt(key, [
        const AcpTextContent('Hi there'),
      ]);
      expect(result.stopReason.value, 'end_turn');
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.promptStatus, AcpPromptStatus.idle);
      expect(state.lastStopReason?.value, 'end_turn');
      final userMessage = state.timeline.entries
          .whereType<AcpMessageEntry>()
          .singleWhere((entry) => entry.role == AcpMessageRole.user);
      expect((userMessage.content.single as AcpTextContent).text, 'Hi there');
    });

    test('clears a stale prompt error when the next prompt starts', () async {
      final transientConnector = _FakeConnector(
        serverFactory: (_, _) =>
            _FakeAcpServer(promptErrorMessage: 'Session limit reached'),
      );
      final transientManager = buildManagerWith(transientConnector);
      final started = await transientManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      final server = transientConnector.servers[key.bridgeId]!;

      await expectLater(
        transientManager.prompt(key, const [AcpTextContent('first')]),
        throwsA(isA<AcpRemoteException>()),
      );
      expect(transientManager.state.byKeyValue(key.value)!.error, isNotNull);

      server
        ..promptErrorMessage = null
        ..holdPrompts = true;
      final retry = transientManager.prompt(key, const [
        AcpTextContent('retry'),
      ]);
      await _pump();

      final retrying = transientManager.state.byKeyValue(key.value)!;
      expect(retrying.promptStatus, AcpPromptStatus.streaming);
      expect(retrying.error, isNull);

      server.completeNextPrompt();
      await retry;
    });

    test('queues follow-up prompts and dispatches them sequentially', () async {
      final key = await startCopilot();
      final server = connector.servers[key.bridgeId]!..holdPrompts = true;

      final first = manager.prompt(key, const [AcpTextContent('first')]);
      await _pump();
      expect(server.heldPromptCount, 1);

      final second = manager.prompt(key, const [AcpTextContent('second')]);
      await _pump();
      expect(server.heldPromptCount, 1);
      final userMessages = manager.state
          .byKeyValue(key.value)!
          .timeline
          .entries
          .whereType<AcpMessageEntry>()
          .where((entry) => entry.role == AcpMessageRole.user)
          .toList();
      expect(userMessages, hasLength(2));
      expect(userMessages.first.queued, isFalse);
      expect(userMessages.last.queued, isTrue);

      server.completeNextPrompt();
      await first;
      await _pump();
      expect(server.heldPromptCount, 1);
      final dispatchedMessages = manager.state
          .byKeyValue(key.value)!
          .timeline
          .entries
          .whereType<AcpMessageEntry>()
          .where((entry) => entry.role == AcpMessageRole.user)
          .toList();
      expect(dispatchedMessages.last.queued, isFalse);

      server.completeNextPrompt();
      await second;
      expect(
        manager.state.byKeyValue(key.value)!.promptStatus,
        AcpPromptStatus.idle,
      );
    });

    test('cancel notifies the agent', () async {
      final key = await startCopilot();
      await manager.cancelPrompt(key);
      final server = connector.servers[key.bridgeId]!;
      await _pump();
      expect(server.cancelledSessions, [key.acpSessionId]);
    });
  });

  group('lifecycle', () {
    test('detach keeps the remote bridge running', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.status, AcpConnectionStatus.detached);
      expect(state.isLive, isFalse);
      expect(connector.stoppedBridges, isEmpty);
    });

    test('background reconnect keeps same-host selection stable', () async {
      isPro = true;
      final first = await startCopilot();
      final firstTransport = connector.servers[first.bridgeId]!;
      final second = await startCopilot();
      expect(manager.state.selectedKey, second.value);
      final secondTransport = connector.servers[second.bridgeId]!;

      expect(manager.state.byKeyValue(first.value)!.isLive, isTrue);
      expect(manager.state.byKeyValue(second.value)!.isLive, isTrue);
      expect(firstTransport.closed, isFalse);
      expect(secondTransport.closed, isFalse);
      expect(manager.liveSessionKeyValues, {first.value, second.value});

      final reopened = await manager.reconnectSession(
        hostId: first.hostId,
        providerId: first.providerId,
        bridgeId: first.bridgeId,
        acpSessionId: first.acpSessionId,
        cwd: '/repo',
        selectOnSuccess: false,
      );

      expect(reopened, isA<AcpSessionLaunchStarted>());
      expect(manager.state.selectedKey, second.value);
      expect(manager.state.byKeyValue(first.value)!.isLive, isTrue);
      expect(manager.state.byKeyValue(second.value)!.isLive, isTrue);
      expect(firstTransport.closed, isFalse);
      expect(secondTransport.closed, isFalse);
      expect(connector.stoppedBridges, isEmpty);
      expect(connector.availableBridges, {first.bridgeId, second.bridgeId});
    });

    test(
      'background attachment publishes without changing selection',
      () async {
        isPro = true;
        final first = await startCopilot();
        await manager.dispose();

        final restored = buildManagerWith(connector);
        final secondResult = await restored.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final second = (secondResult as AcpSessionLaunchStarted).key;
        final bridge = (await restored.listRemoteBridges(
          1,
        )).where((candidate) => candidate.id == first.bridgeId).single;

        final result = await restored.reconnectSession(
          hostId: first.hostId,
          providerId: first.providerId,
          bridgeId: first.bridgeId,
          acpSessionId: first.acpSessionId,
          cwd: '/repo',
          selectOnSuccess: false,
          knownRemoteBridge: bridge,
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(restored.state.selectedKey, second.value);
        expect(restored.liveSessionKeyValues, {first.value, second.value});
      },
    );

    test('keeps attachments on separate SSH hosts live', () async {
      isPro = true;
      final first = await startCopilot();
      final second = await startCopilot(hostId: 2);

      expect(manager.liveSessionKeyValues, {first.value, second.value});
      expect(connector.servers[first.bridgeId]!.closed, isFalse);
      expect(connector.servers[second.bridgeId]!.closed, isFalse);
    });

    test(
      'provider exit marks the session exited without stopping others',
      () async {
        isPro = true;
        final first = await startCopilot();
        final second = await startCopilot(hostId: 2);
        connector
            .statesFor(first.bridgeId)
            .add(
              MonkeyMuxAcpTransportState(
                status: MonkeyMuxAcpTransportStatus.providerExited,
                bridgeId: first.bridgeId,
                lastDeliveredSequence: 0,
              ),
            );
        await _pump();
        expect(
          manager.state.byKeyValue(first.value)!.status,
          AcpConnectionStatus.providerExited,
        );
        // The unrelated second session is untouched.
        expect(
          manager.state.byKeyValue(second.value)!.status,
          AcpConnectionStatus.ready,
        );
        expect(manager.state.byKeyValue(second.value)!.isLive, isTrue);
      },
    );

    test('stop stops the remote bridge and drops the session', () async {
      final key = await startCopilot();
      await manager.stopSession(key);
      expect(connector.stoppedBridges, [key.bridgeId]);
      expect(manager.state.byKeyValue(key.value), isNull);
    });

    test(
      'remote stop failure keeps the live session and recent retry handle',
      () async {
        final key = await startCopilot();
        connector.stopError = Exception('SSH unavailable');

        await expectLater(manager.stopSession(key), throwsA(isA<Exception>()));

        expect(manager.state.byKeyValue(key.value)?.isLive, isTrue);
        expect(
          (await recentSessions.list()).map((recent) => recent.key),
          contains(key),
        );
        expect(connector.availableBridges, contains(key.bridgeId));
      },
    );

    test(
      'remote delete failure keeps the session and recent retry handle',
      () async {
        final key = await startCopilot();
        connector.servers[key.bridgeId]!.failDelete = true;

        await expectLater(manager.deleteSession(key), throwsA(isA<Object>()));

        expect(manager.state.byKeyValue(key.value)?.isLive, isTrue);
        expect(connector.stoppedBridges, isEmpty);
        expect(
          (await recentSessions.list()).map((recent) => recent.key),
          contains(key),
        );
      },
    );

    test('idle reconnect refreshes session setup safely', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      final result = await manager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      final state = manager.state.byKeyValue(key.value)!;
      expect(state.status, AcpConnectionStatus.ready);
      expect(state.isLive, isTrue);
      final attachedServer = connector.servers[key.bridgeId]!;
      expect(attachedServer.methods, contains('session/resume'));
      expect(attachedServer.methods, isNot(contains('session/load')));
    });

    test('compact-baseline reconnect loads durable history', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      connector.skippedHistoricalReplay = true;

      final result = await manager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchStarted>());
      final attachedServer = connector.servers[key.bridgeId]!;
      expect(attachedServer.methods, contains('session/load'));
      expect(attachedServer.methods, isNot(contains('session/resume')));
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.ready,
      );
    });

    test(
      'already-loaded history reconnect stays live and warns after app restart',
      () async {
        var rejectLoad = false;
        final liveConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            rejectLoadAlreadyLoaded: rejectLoad,
            rejectResume: rejectLoad,
          ),
        );
        final firstManager = buildManagerWith(liveConnector);
        final started = await firstManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;
        await firstManager.detachSession(key);
        rejectLoad = true;
        liveConnector.skippedHistoricalReplay = true;

        // A fresh manager has no in-memory timeline from the prior app process.
        final reconnectedManager = buildManagerWith(liveConnector);
        final result = await reconnectedManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        final attachedServer = liveConnector.servers[key.bridgeId]!;
        expect(attachedServer.methods, contains('session/load'));
        expect(attachedServer.methods, contains('session/resume'));
        final state = reconnectedManager.state.byKeyValue(key.value)!;
        expect(state.status, AcpConnectionStatus.ready);
        expect(state.timeline.entries, isEmpty);
        expect(state.warning?.kind, AcpSessionErrorKind.historyUnavailable);
        expect(
          state.warning?.message,
          'Earlier messages could not be restored in this view.',
        );

        await reconnectedManager.detachSession(key);
        rejectLoad = false;
        final refreshed = await reconnectedManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );
        expect(refreshed, isA<AcpSessionLaunchStarted>());
        expect(reconnectedManager.state.byKeyValue(key.value)!.warning, isNull);
      },
    );

    test('resume replay avoids a degraded-history warning', () async {
      var reconnecting = false;
      final liveConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(
          rejectLoadAlreadyLoaded: reconnecting,
          replayTextOnResume: reconnecting ? 'restored history' : null,
        ),
      );
      final firstManager = buildManagerWith(liveConnector);
      final started = await firstManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      await firstManager.detachSession(key);
      reconnecting = true;
      liveConnector.skippedHistoricalReplay = true;

      final reconnectedManager = buildManagerWith(liveConnector);
      final result = await reconnectedManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchStarted>());
      final state = reconnectedManager.state.byKeyValue(key.value)!;
      expect(state.timeline.entries, isNotEmpty);
      expect(state.warning, isNull);
    });

    test(
      'already-loaded response with whitespace-different id still fails',
      () async {
        var rejectLoad = false;
        final liveConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            rejectLoadAlreadyLoaded: rejectLoad,
            alreadyLoadedSessionId: 'SESSION-1',
          ),
        );
        final firstManager = buildManagerWith(liveConnector);
        final started = await firstManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;
        await firstManager.detachSession(key);
        rejectLoad = true;
        liveConnector.skippedHistoricalReplay = true;

        final reconnectedManager = buildManagerWith(liveConnector);
        final result = await reconnectedManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: ' SESSION-1',
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchFailed>());
        final error = (result as AcpSessionLaunchFailed).error;
        expect(error.kind, AcpSessionErrorKind.protocol);
        expect(reconnectedManager.state.byKeyValue(key.value), isNull);
      },
    );

    test(
      'detach during a turn reattaches without resume and keeps progress live',
      () async {
        final key = await startCopilot();
        final originalServer = connector.servers[key.bridgeId]!
          ..holdPrompts = true;
        Object? detachedPromptError;
        unawaited(
          manager
              .prompt(key, const [AcpTextContent('keep working')])
              .then<void>(
                (_) {},
                onError: (error) => detachedPromptError = error,
              ),
        );
        await _pump();
        originalServer.pushUpdate(key.acpSessionId, {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'live-tool',
          'title': 'Search',
          'status': 'in_progress',
          'rawInput': {'query': 'needle'},
        });
        await _pump();
        connector.bridgeStatusInFlightTurnCount = 1;

        await manager.detachSession(key);
        await _pump();
        final detached = manager.state.byKeyValue(key.value)!;
        expect(detached.promptStatus, AcpPromptStatus.streaming);
        expect(detached.error, isNull);
        expect(
          detached.timeline.entries.whereType<AcpMessageEntry>(),
          isNotEmpty,
        );
        expect(detachedPromptError, isNotNull);

        final result = await manager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );
        expect(result, isA<AcpSessionLaunchStarted>());
        final attachedServer = connector.servers[key.bridgeId]!;
        expect(attachedServer.methods, isNot(contains('initialize')));
        expect(attachedServer.methods, isNot(contains('session/resume')));
        expect(attachedServer.methods, isNot(contains('session/load')));
        expect(
          manager.state.byKeyValue(key.value)!.promptStatus,
          AcpPromptStatus.streaming,
        );

        attachedServer.holdPrompts = true;
        final followUp = manager.prompt(key, const [
          AcpTextContent('follow up'),
        ]);
        await _pump();
        expect(attachedServer.heldPromptCount, 0);
        final queuedUser = manager.state
            .byKeyValue(key.value)!
            .timeline
            .entries
            .whereType<AcpMessageEntry>()
            .last;
        expect(queuedUser.queued, isTrue);

        attachedServer.pushUpdate(key.acpSessionId, {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'live-tool',
          'status': 'completed',
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': '3 matches'},
            },
          ],
        });
        await _pump();
        final progressed = manager.state.byKeyValue(key.value)!;
        expect(
          progressed.timeline.entries
              .whereType<AcpToolCallEntry>()
              .single
              .status
              ?.value,
          'completed',
        );
        expect(progressed.promptStatus, AcpPromptStatus.streaming);

        connector.bridgeStatusInFlightTurnCount = 0;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(attachedServer.methods, contains('session/resume'));
        expect(manager.state.byKeyValue(key.value)!.configOptions, isNotEmpty);
        expect(attachedServer.heldPromptCount, 1);
        attachedServer.completeNextPrompt();
        await followUp;
        expect(
          manager.state.byKeyValue(key.value)!.promptStatus,
          AcpPromptStatus.idle,
        );
      },
    );

    test(
      'app teardown leaves a live remote turn attachable without resume',
      () async {
        final key = await startCopilot();
        connector.bridgeStatusInFlightTurnCount = 1;
        final now = DateTime.now();
        connector.remoteMetadata = [
          MonkeyMuxAcpBridgeMetadata(
            id: key.bridgeId,
            providerId: key.providerId,
            sessionId: key.acpSessionId,
            cwd: '/repo',
            provider: 'Copilot CLI',
            commandHash: 'hash',
            state: MonkeyMuxAcpProviderState.running,
            clientCount: 0,
            pendingRequestCount: 0,
            inFlightTurnCount: 1,
            lastActivity: now,
            startedAt: now,
            nextSequence: 5,
          ),
        ];

        await manager.dispose();
        expect(connector.stoppedBridges, isEmpty);
        expect(connector.availableBridges, contains(key.bridgeId));

        final restoredManager = buildManagerWith(connector);
        final recents = await restoredManager.loadRecentSessions();
        expect(recents.map((recent) => recent.key), contains(key));
        final result = await restoredManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        final attachedServer = connector.servers[key.bridgeId]!;
        expect(attachedServer.methods, contains('initialize'));
        expect(attachedServer.methods, isNot(contains('session/resume')));
        expect(attachedServer.methods, isNot(contains('session/load')));
        expect(
          restoredManager.state.byKeyValue(key.value)!.promptStatus,
          AcpPromptStatus.streaming,
        );
      },
    );

    test(
      'resume after helper upgrade recreates an expired bridge and keeps the ACP session id',
      () async {
        final key = await startCopilot();
        await manager.detachSession(key);
        connector.availableBridges.remove(key.bridgeId);
        Future<bool> confirmInstall(MonkeyMuxInstallRequest _) async => true;

        final result = await manager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
          confirmInstall: confirmInstall,
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        final resumedKey = (result as AcpSessionLaunchStarted).key;
        expect(resumedKey.bridgeId, isNot(key.bridgeId));
        expect(resumedKey.acpSessionId, key.acpSessionId);
        expect(connector.startedBridges, hasLength(2));
        expect(connector.lastListConfirmInstall, same(confirmInstall));
        expect(
          connector.servers[resumedKey.bridgeId]!.methods,
          contains('session/load'),
        );
        expect(manager.state.byKeyValue(key.value), isNull);
        expect(manager.state.byKeyValue(resumedKey.value)!.isLive, isTrue);
        final recents = await manager.loadRecentSessions();
        expect(recents.map((recent) => recent.key), contains(resumedKey));
        expect(recents.map((recent) => recent.key), isNot(contains(key)));
      },
    );

    test(
      'discovered native session starts a fresh bridge and resumes',
      () async {
        const nativeSessionId = 'provider-history-session';

        final result = await manager.resumeProviderSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          acpSessionId: nativeSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        final key = (result as AcpSessionLaunchStarted).key;
        expect(key.acpSessionId, nativeSessionId);
        expect(connector.startedBridges, hasLength(1));
        final methods = connector.servers[key.bridgeId]!.methods;
        expect(methods, contains('session/load'));
        expect(methods, isNot(contains('session/resume')));
        expect(manager.state.byKeyValue(key.value)!.isLive, isTrue);
      },
    );

    test('fork creates a sibling session on the same bridge', () async {
      isPro = true;
      final key = await startCopilot();
      final result = await manager.forkSession(key);
      expect(result, isA<AcpSessionLaunchStarted>());
      final forkKey = (result as AcpSessionLaunchStarted).key;
      expect(forkKey.acpSessionId, isNot(key.acpSessionId));
      expect(forkKey.bridgeId, key.bridgeId);
      // The original remains tracked and live.
      expect(manager.state.byKeyValue(key.value)!.isLive, isTrue);
      expect(manager.state.byKeyValue(forkKey.value)!.isLive, isTrue);
      expect(
        (await recentSessions.list()).map((recent) => recent.key),
        contains(forkKey),
      );
    });
  });

  group('replay overflow', () {
    test('surfaces a non-fatal warning without failing the session', () async {
      final key = await startCopilot();
      connector
          .errorsFor(key.bridgeId)
          .add(
            const MonkeyMuxAcpBridgeException(
              MonkeyMuxAcpBridgeErrorKind.replayOverflow,
              'overflow',
            ),
          );
      await _pump();
      final state = manager.state.byKeyValue(key.value)!;
      // Surfaced as a distinct warning, not a fatal error.
      expect(state.warning, isNotNull);
      expect(state.warning!.kind, AcpSessionErrorKind.replayOverflow);
      expect(state.error, isNull);
      // The session keeps running and stays live.
      expect(state.status, AcpConnectionStatus.ready);
      expect(state.isLive, isTrue);
      // The message is content-free.
      expect(state.warning!.message, isNot(contains('overflow')));
    });

    test(
      'is preserved separately from a later fatal transport failure',
      () async {
        final key = await startCopilot();
        connector
            .errorsFor(key.bridgeId)
            .add(
              const MonkeyMuxAcpBridgeException(
                MonkeyMuxAcpBridgeErrorKind.replayOverflow,
                'overflow',
              ),
            );
        await _pump();
        connector
            .statesFor(key.bridgeId)
            .add(
              MonkeyMuxAcpTransportState(
                status: MonkeyMuxAcpTransportStatus.failed,
                bridgeId: key.bridgeId,
                lastDeliveredSequence: 0,
              ),
            );
        await _pump();
        final state = manager.state.byKeyValue(key.value)!;
        // The fatal failure is recorded in `error`; the replay-overflow warning
        // is retained separately rather than being clobbered.
        expect(state.status, AcpConnectionStatus.failed);
        expect(state.error!.kind, AcpSessionErrorKind.transport);
        expect(state.warning!.kind, AcpSessionErrorKind.replayOverflow);
      },
    );
  });

  group('capability adaptation', () {
    AcpSessionManager managerFor(_FakeConnector custom) =>
        buildManagerWith(custom);

    test(
      'authentication-required stops the fresh bridge and leaves no session',
      () async {
        final authConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            authMethods: const [
              {'id': 'oauth', 'name': 'Sign in'},
            ],
          ),
        );
        final authManager = managerFor(authConnector);
        final result = await authManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        expect(result, isA<AcpSessionLaunchFailed>());
        expect(
          (result as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.authenticationRequired,
        );
        // There is no authenticate/retry-on-existing-bridge path, so the
        // orphaned bridge is stopped just like any other failed creation. The
        // UI offers the provider's terminal-auth command and the user retries
        // cleanly.
        expect(authConnector.startedBridges, hasLength(1));
        expect(authConnector.stoppedBridges, authConnector.startedBridges);
        // No session or attachment is left tracked.
        expect(authManager.state.sessions, isEmpty);
        expect(authManager.liveSessionKeyValues, isEmpty);
      },
    );

    test(
      'soft reattach resumes from the last rendered bridge sequence',
      () async {
        final key = await startCopilot();
        connector.lastDeliveredSequences[key.bridgeId] = 23;

        await manager.detachSession(key);
        final result = await manager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        expect(connector.connectionAcknowledgements[key.bridgeId], [0, 23]);
        expect(
          connector.servers[key.bridgeId]!.methods,
          isNot(contains('initialize')),
        );
      },
    );

    test('reconnects without resume/load by reusing the session id', () async {
      final plainConnector = _FakeConnector(
        serverFactory: (_, _) =>
            _FakeAcpServer(supportsResume: false, supportsLoad: false),
      );
      final plainManager = managerFor(plainConnector);
      final started = await plainManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      await plainManager.detachSession(key);
      final result = await plainManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      final server = plainConnector.servers[key.bridgeId]!;
      expect(server.methods, isNot(contains('session/resume')));
      expect(server.methods, isNot(contains('session/load')));
    });
  });

  group('attachment lease', () {
    test(
      'window close releases local sessions without a duplicate stop',
      () async {
        final key = await startCopilot();

        await manager.releaseSessionsForClosingMuxWindow(
          hostId: key.hostId,
          bridgeId: key.bridgeId,
        );

        expect(manager.state.byKeyValue(key.value), isNull);
        expect(connector.stoppedBridges, isEmpty);
      },
    );

    test('detach is idempotent and never double-releases', () async {
      final key = await startCopilot();
      await manager.detachSession(key);
      // A second detach must be a no-op and must not stop the bridge.
      await manager.detachSession(key);
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.detached,
      );
      expect(connector.stoppedBridges, isEmpty);
    });

    test(
      'detaching the original never stops a bridge still used by a fork',
      () async {
        isPro = true;
        final key = await startCopilot();
        final fork = await manager.forkSession(key);
        final forkKey = (fork as AcpSessionLaunchStarted).key;
        expect(forkKey.bridgeId, key.bridgeId);

        // Detach the original twice, then explicitly stop it.
        await manager.detachSession(key);
        await manager.detachSession(key);
        await manager.stopSession(key);

        // The shared bridge must not be stopped while the fork still uses it.
        expect(connector.stoppedBridges, isEmpty);
        expect(manager.state.byKeyValue(forkKey.value)!.isLive, isTrue);

        // Stopping the fork (the last user) finally stops the bridge once.
        await manager.stopSession(forkKey);
        expect(connector.stoppedBridges, [key.bridgeId]);
      },
    );
  });

  group('reconnect hardening', () {
    test(
      'repeated reconnect failures return typed errors and then recover',
      () async {
        var rejectReconnectResume = false;
        final flakyConnector = _FakeConnector(
          serverFactory: (_, _) =>
              _FakeAcpServer(rejectResume: rejectReconnectResume),
        );
        final flakyManager = buildManagerWith(flakyConnector);
        final started = await flakyManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;
        rejectReconnectResume = true;

        Future<AcpSessionLaunchResult> reconnect() async {
          await flakyManager.detachSession(key);
          return flakyManager.reconnectSession(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
            cwd: '/repo',
          );
        }

        final first = await reconnect();
        expect(first, isA<AcpSessionLaunchFailed>());
        expect(
          (first as AcpSessionLaunchFailed).error.kind,
          AcpSessionErrorKind.protocol,
        );
        expect(
          flakyManager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.failed,
        );

        final second = await reconnect();
        expect(second, isA<AcpSessionLaunchFailed>());

        // Leases stayed balanced across repeated failures: once the agent
        // recovers, a fresh reconnect succeeds and the session is live again.
        rejectReconnectResume = false;
        final third = await reconnect();
        expect(third, isA<AcpSessionLaunchStarted>());
        final state = flakyManager.state.byKeyValue(key.value)!;
        expect(state.status, AcpConnectionStatus.ready);
        expect(state.isLive, isTrue);
      },
    );
  });

  group('history replay on load', () {
    test('retains replay emitted synchronously during session/load', () async {
      final replayConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(
          supportsResume: false,
          replayTextOnLoad: 'Replayed history',
        ),
      );
      final replayManager = buildManagerWith(replayConnector);
      final started = await replayManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      await replayManager.detachSession(key);
      replayConnector.availableBridges.remove(key.bridgeId);
      final result = await replayManager.reconnectSession(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchStarted>());
      final reloadedKey = (result as AcpSessionLaunchStarted).key;
      await _pump();
      final timeline = replayManager.state
          .byKeyValue(reloadedKey.value)!
          .timeline;
      final message = timeline.entries.whereType<AcpMessageEntry>().firstWhere(
        (e) => e.messageId == 'replay',
      );
      expect(
        (message.content.single as AcpTextContent).text,
        'Replayed history',
      );
    });

    test(
      'keeps replay chunks separate across metadata and tool boundaries',
      () async {
        Map<String, Object?> textUpdate(
          String text, {
          Map<String, Object?> updateFields = const {},
          Map<String, Object?> contentFields = const {},
        }) => <String, Object?>{
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'boundary-message',
          ...updateFields,
          'content': <String, Object?>{
            'type': 'text',
            'text': text,
            ...contentFields,
          },
        };
        final replayConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            supportsResume: false,
            replayUpdatesOnLoad: <Map<String, Object?>>[
              textUpdate('a'),
              textUpdate(
                'b',
                updateFields: {
                  '_meta': {'variant': 'update'},
                },
              ),
              textUpdate('c', updateFields: {'x-update': true}),
              textUpdate(
                'd',
                contentFields: {
                  '_meta': {'variant': 'content'},
                },
              ),
              textUpdate('e', contentFields: {'x-content': true}),
              textUpdate(
                'f',
                contentFields: {
                  'annotations': {
                    'audience': ['assistant'],
                  },
                },
              ),
              const <String, Object?>{
                'sessionUpdate': 'tool_call',
                'toolCallId': 'boundary-tool',
                'title': 'Boundary',
                'status': 'completed',
              },
              textUpdate('g'),
            ],
          ),
        );
        final replayManager = buildManagerWith(replayConnector);
        final started = await replayManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;
        await replayManager.detachSession(key);
        replayConnector.availableBridges.remove(key.bridgeId);

        final result = await replayManager.reconnectSession(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );
        final reloadedKey = (result as AcpSessionLaunchStarted).key;
        await _pump();
        final timeline = replayManager.state
            .byKeyValue(reloadedKey.value)!
            .timeline;
        final message = timeline.entries
            .whereType<AcpMessageEntry>()
            .singleWhere((entry) => entry.messageId == 'boundary-message');

        expect(
          message.content.whereType<AcpTextContent>().map(
            (block) => block.text,
          ),
          ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        );
        expect(
          timeline.entries.whereType<AcpToolCallEntry>().single.toolCallId,
          'boundary-tool',
        );
      },
    );

    test('failed provisional reconnect restores prior selection', () async {
      isPro = true;
      final selectionConnector = _FakeConnector(
        serverFactory: (_, bridgeId) =>
            _FakeAcpServer(rejectInitialize: bridgeId == 'failing-bridge'),
      );
      final selectionManager = buildManagerWith(selectionConnector);
      final started = await selectionManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final selectedKey = (started as AcpSessionLaunchStarted).key;
      expect(selectionManager.state.selectedKey, selectedKey.value);
      selectionConnector.availableBridges.add('failing-bridge');

      final result = await selectionManager.reconnectSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        bridgeId: 'failing-bridge',
        acpSessionId: 'failing-session',
        cwd: '/repo',
      );

      expect(result, isA<AcpSessionLaunchFailed>());
      expect(selectionManager.state.selectedKey, selectedKey.value);
      expect(selectionManager.state.sessions.map((session) => session.key), [
        selectedKey,
      ]);
    });

    test('publishes reconnecting state before a slow load completes', () async {
      isPro = true;
      final loadGate = Completer<void>();
      final replayConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(
          supportsResume: false,
          replayUpdateCountOnLoad: 4000,
          loadResponseGate: loadGate.future,
        ),
      );
      final replayManager = buildManagerWith(replayConnector);
      final started = await replayManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (started as AcpSessionLaunchStarted).key;
      final sibling = await replayManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final siblingKey = (sibling as AcpSessionLaunchStarted).key;
      await replayManager.detachSession(key);
      replayConnector.availableBridges.remove(key.bridgeId);

      final completeReplayText = List.generate(
        4000,
        (index) => 'chunk-$index ',
      ).join();
      final publishedReplayTextLengths = <int>[];
      final statesSubscription = replayManager.states.listen((managerState) {
        final replay = managerState.sessions
            .expand((session) => session.timeline.entries)
            .whereType<AcpMessageEntry>()
            .where((entry) => entry.messageId == 'replay-burst')
            .firstOrNull;
        if (replay != null && replay.content.isNotEmpty) {
          publishedReplayTextLengths.add(
            replay.content.whereType<AcpTextContent>().fold(
              0,
              (length, block) => length + block.text.length,
            ),
          );
        }
      });
      addTearDown(statesSubscription.cancel);

      var reconnectCompleted = false;
      final reconnect = replayManager
          .reconnectSession(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
            cwd: '/repo',
          )
          .then((value) {
            reconnectCompleted = true;
            return value;
          });

      AcpSessionState? provisional;
      for (var turn = 0; turn < 100 && provisional == null; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        provisional = replayManager.state.sessions
            .where(
              (session) => session.status == AcpConnectionStatus.initializing,
            )
            .firstOrNull;
      }
      expect(provisional, isNotNull);
      expect(provisional!.status, AcpConnectionStatus.initializing);
      expect(reconnectCompleted, isFalse);

      // An unrelated live session may emit while this replay's working state
      // already contains hundreds of chunks. Aggregate state must still use
      // the replaying controller's last committed (empty) snapshot.
      replayConnector.servers[siblingKey.bridgeId]!.pushUpdate(
        siblingKey.acpSessionId,
        {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'sibling-live',
          'content': {'type': 'text', 'text': 'live'},
        },
      );
      await _pump();
      expect(publishedReplayTextLengths, isEmpty);

      loadGate.complete();
      final result = await reconnect;
      expect(result, isA<AcpSessionLaunchStarted>());
      final reloadedKey = (result as AcpSessionLaunchStarted).key;
      AcpMessageEntry? message;
      for (var turn = 0; turn < 400; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        message = replayManager.state
            .byKeyValue(reloadedKey.value)!
            .timeline
            .entries
            .whereType<AcpMessageEntry>()
            .where((entry) => entry.messageId == 'replay-burst')
            .firstOrNull;
        final replayText = message?.content
            .whereType<AcpTextContent>()
            .map((block) => block.text)
            .join();
        if (replayText == completeReplayText) break;
      }
      expect(message, isNotNull);
      expect(message!.content, isNotEmpty);
      expect(
        message.content
            .whereType<AcpTextContent>()
            .map((block) => block.text)
            .join(),
        completeReplayText,
      );
      expect(publishedReplayTextLengths, contains(completeReplayText.length));
      expect(
        publishedReplayTextLengths.where(
          (length) => length < completeReplayText.length,
        ),
        isEmpty,
        reason:
            'the native UI should first receive the complete replay so its '
            'bounded window mounts from the final tail',
      );
    });

    test(
      'deduplicates a replayed permission by request id across reconnect',
      () async {
        final permConnector = _FakeConnector(
          serverFactory: (_, _) => _FakeAcpServer(
            supportsResume: false,
            permissionIdOnLoad: 'perm-stable-1',
          ),
        );
        final permManager = buildManagerWith(permConnector);
        final started = await permManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        );
        var key = (started as AcpSessionLaunchStarted).key;

        Future<void> reloadExpiredBridge() async {
          await permManager.detachSession(key);
          permConnector.availableBridges.remove(key.bridgeId);
          final result = await permManager.reconnectSession(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
            cwd: '/repo',
          );
          key = (result as AcpSessionLaunchStarted).key;
          await _pump();
        }

        await reloadExpiredBridge();
        expect(
          permManager.state.byKeyValue(key.value)!.pendingPermissions,
          hasLength(1),
        );

        // Reconnect again: the same JSON-RPC id is replayed and must rebind the
        // responder without appending a second pending UI entry.
        await reloadExpiredBridge();
        final pending = permManager.state
            .byKeyValue(key.value)!
            .pendingPermissions;
        expect(pending, hasLength(1));

        await permManager.respondToPermission(
          key,
          pending.single.requestKey,
          'allow',
        );
        await _pump();
        expect(
          permManager.state.byKeyValue(key.value)!.pendingPermissions,
          isEmpty,
        );
        // The responder was rebound to the latest connection, which received
        // the response.
        final latestServer = permConnector.servers[key.bridgeId]!;
        expect(latestServer.permissionResponses['perm-stable-1'], isNotNull);
      },
    );
  });

  group('orphan bridge cleanup', () {
    test(
      'prompt authentication failure transitions to sign-in required',
      () async {
        final authConnector = _FakeConnector(
          serverFactory: (_, _) =>
              _FakeAcpServer(promptErrorMessage: 'Authentication required'),
        );
        final authManager = buildManagerWith(authConnector);
        final started = await authManager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.claudeAgent,
          cwd: '/repo',
        );
        final key = (started as AcpSessionLaunchStarted).key;

        await expectLater(
          authManager.prompt(key, const [AcpTextContent('hello')]),
          throwsA(isA<AcpRemoteException>()),
        );
        await _pump();

        final state = authManager.state.byKeyValue(key.value)!;
        expect(state.status, AcpConnectionStatus.authenticationRequired);
        expect(state.pendingAuthentication, isTrue);
        expect(state.error?.kind, AcpSessionErrorKind.authenticationRequired);
        expect(state.error?.message, 'The agent requires authentication.');
      },
    );

    test('stops a fresh bridge when session creation fails', () async {
      final failConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(failNewSession: true),
      );
      final failManager = buildManagerWith(failConnector);
      final result = await failManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(result, isA<AcpSessionLaunchFailed>());
      final failure = result as AcpSessionLaunchFailed;
      expect(failure.error.message, contains('Session creation failed'));
      expect(failure.error.message, isNot(contains('connection setup')));
      expect(failure.error.message.length, lessThanOrEqualTo(240));
      // The orphaned bridge was best-effort stopped.
      expect(failConnector.startedBridges, hasLength(1));
      expect(failConnector.stoppedBridges, failConnector.startedBridges);
    });
  });

  group('telemetry allowlist', () {
    test('reports open, permission, attachment, and stop events', () async {
      final telemetry = _RecordingTelemetrySink();
      final telemetryConnector = _FakeConnector();
      final telemetryManager = buildManagerWith(
        telemetryConnector,
        telemetry: telemetry,
      );
      final result = await telemetryManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      final key = (result as AcpSessionLaunchStarted).key;
      expect(
        telemetry.events,
        contains('sessionOpened:${AcpBuiltinProviderIds.copilotCli}:false'),
      );

      await telemetryManager.prompt(key, const [
        AcpTextContent('hi'),
        AcpImageContent(data: 'aGk=', mimeType: 'image/png'),
      ]);
      expect(telemetry.events, contains('attachmentSent:image:1'));
      // Never a text/content count, and never anything content-bearing.
      expect(telemetry.events.every((event) => !event.contains('hi')), isTrue);

      telemetryConnector.servers[key.bridgeId]!.requestPermission(
        key.acpSessionId,
        't1',
      );
      await _pump();
      final pending = telemetryManager.state
          .byKeyValue(key.value)!
          .pendingPermissions
          .single;
      await telemetryManager.respondToPermission(
        key,
        pending.requestKey,
        'allow',
      );
      expect(telemetry.events, contains('permissionOutcome:selected'));

      await telemetryManager.stopSession(key);
      expect(telemetry.events, contains('sessionEnded:stopped'));
    });

    test('reports a failure category without any session content', () async {
      final telemetry = _RecordingTelemetrySink();
      final failConnector = _FakeConnector(
        serverFactory: (_, _) => _FakeAcpServer(failNewSession: true),
      );
      final failManager = buildManagerWith(failConnector, telemetry: telemetry);
      await failManager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      expect(
        telemetry.events.any((event) => event.startsWith('failure:')),
        isTrue,
      );
    });
  });
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));
