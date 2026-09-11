import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
// SSHUserInfoRequest/SSHUserInfoPrompt are not exported from the public API,
// but are needed to exercise the keyboard-interactive auth handler.
// ignore: implementation_imports
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/domain/services/background_ssh_service.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/interactive_auth_prompt.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/openssh_key_generator.dart';
import 'package:monkeyssh/domain/services/port_forward_browser_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';
import 'package:monkeyssh/domain/services/wifi_network_service.dart';
import 'package:xterm/xterm.dart';

import '../../helpers/powershell_test_helpers.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);
const _automaticPortWatcherSnapshotBeginMarker =
    '__monkeyssh_port_snapshot_begin__';
const _automaticPortWatcherSnapshotEndMarker =
    '__monkeyssh_port_snapshot_end__';
const _automaticPortDiscoveryUnavailableMarker =
    '__monkeyssh_port_discovery_unavailable__';

class _CapturingSshService extends SshService {
  _CapturingSshService({
    required super.hostRepository,
    required super.keyRepository,
    super.wifiNetworkService,
  });

  SshConnectionConfig? capturedConfig;
  SshConnectionResult result = const SshConnectionResult(
    success: false,
    error: 'stubbed',
  );

  @override
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    capturedConfig = config;
    return result;
  }
}

class _StubWifiNetworkService extends WifiNetworkService {
  _StubWifiNetworkService(
    this.ssid, {
    this.permissionStatus = WifiPermissionStatus.granted,
  });

  final String? ssid;
  final WifiPermissionStatus permissionStatus;
  int requestPermissionCallCount = 0;
  int getCurrentSsidCallCount = 0;

  @override
  Future<WifiPermissionStatus> requestPermission() async {
    requestPermissionCallCount++;
    return permissionStatus;
  }

  @override
  Future<String?> getCurrentSsid() async {
    getCurrentSsidCallCount++;
    return ssid;
  }
}

class _CountingKeyRepository extends KeyRepository {
  _CountingKeyRepository(
    super.db,
    super.secretEncryptionService, {
    this.returnNullOnGetById = false,
  });

  final bool returnNullOnGetById;
  int getAllCallCount = 0;

  @override
  Future<List<SshKey>> getAll() async {
    getAllCallCount++;
    return super.getAll();
  }

  @override
  Future<SshKeyLoadResult> getAllDecryptable() async {
    getAllCallCount++;
    return super.getAllDecryptable();
  }

  @override
  Future<SshKey?> getById(int id) async {
    if (returnNullOnGetById) {
      return null;
    }
    return super.getById(id);
  }
}

class _MockSshClient extends Mock implements SSHClient {}

class _AuthenticationFixture {
  final client = _MockSshClient();
  late final SshService service;
  SSHPasswordRequestHandler? capturedPassword;
  SSHUserInfoRequestHandler? capturedUserInfo;
  List<SSHKeyPair>? capturedIdentities;

  static Future<_AuthenticationFixture> create({
    required String hostname,
    required List<int> keyBytes,
    InteractiveAuthPromptHandler? promptHandler,
    HostRepository? hostRepository,
  }) async {
    final fixture = _AuthenticationFixture();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final knownHostsRepository = KnownHostsRepository(db);
    final hostKeyBytes = _ed25519HostKeyBlob(keyBytes);
    await _seedTrustedHost(
      knownHostsRepository,
      hostname: hostname,
      hostKeyBytes: hostKeyBytes,
    );
    final sockets = [_FakeHostKeySocket(hostKeyBytes)];
    var socketIndex = 0;
    when(fixture.client.close).thenAnswer((_) async {});
    fixture.service = SshService(
      hostRepository: hostRepository,
      knownHostsRepository: knownHostsRepository,
      interactiveAuthPromptHandler: promptHandler,
      socketConnector: (host, port, {timeout}) async => sockets[socketIndex++],
      clientFactory:
          (
            socket, {
            required username,
            onVerifyHostKey,
            onPasswordRequest,
            onUserInfoRequest,
            identities,
            keepAliveInterval,
          }) {
            fixture
              ..capturedIdentities = identities
              ..capturedPassword = onPasswordRequest
              ..capturedUserInfo = onUserInfoRequest;
            when(() => fixture.client.authenticated).thenAnswer((_) async {
              final bytes = await (socket as HostKeySource).hostKeyBytes;
              await onVerifyHostKey!(
                'ssh-ed25519',
                _hostKeyCallbackFingerprint(bytes),
              );
            });
            return fixture.client;
          },
    );
    return fixture;
  }
}

class _MockExecSession extends Mock implements SSHSession {}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockTelemetryService extends Mock implements TelemetryService {}

class _RecordingSessionTelemetry extends TelemetryService {
  _RecordingSessionTelemetry()
    : super(
        status: TelemetryServiceStatus.disabledByBuild,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
      );

  final disconnectReasons = <String>[];

  @override
  Future<void> logTerminalSessionEnded({
    required Duration duration,
    required String disconnectCategory,
    required bool usedBackgroundService,
  }) async {
    disconnectReasons.add(disconnectCategory);
  }
}

class _MockSshService extends Mock implements SshService {}

class _MockRemoteForward extends Mock implements SSHRemoteForward {}

class _MockHostRepository extends Mock implements HostRepository {}

class _MockPortForwardRepository extends Mock
    implements PortForwardRepository {}

_MockPortForwardRepository _emptyPortForwardRepository() {
  final repository = _MockPortForwardRepository();
  when(() => repository.getByHostId(any())).thenAnswer((_) async => []);
  return repository;
}

class _AutomaticForwardTestSession extends SshSession {
  _AutomaticForwardTestSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    required super.config,
    required this.discoveries,
  });

  final List<Map<RemoteTcpListenerKey, RemoteTcpListener>?> discoveries;
  final List<
    ({String remoteHost, int remotePort, String proxyHost, bool isShellRelated})
  >
  starts = [];

  @override
  Duration get automaticPortForwardDiscoveryInterval => const Duration(days: 1);

  @override
  Future<bool> startAutomaticPortForwardWatcher({
    required int generation,
  }) async => false;

  @override
  Future<Map<RemoteTcpListenerKey, RemoteTcpListener>?>
  discoverRemoteListeningTcpListeners() async => discoveries.removeAt(0);

  @override
  Future<bool> startAutomaticLocalForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String proxyHost,
    required bool isShellRelated,
  }) async {
    starts.add((
      remoteHost: remoteHost,
      remotePort: remotePort,
      proxyHost: proxyHost,
      isShellRelated: isShellRelated,
    ));
    return true;
  }
}

class _ConcurrentAutomaticForwardTestSession extends SshSession {
  _ConcurrentAutomaticForwardTestSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    required super.config,
    required this.snapshot,
  });

  final Map<RemoteTcpListenerKey, RemoteTcpListener> snapshot;
  final firstStartGate = Completer<void>();
  int startCount = 0;
  int discoveryCount = 0;

  @override
  Duration get automaticPortForwardDiscoveryInterval => const Duration(days: 1);

  @override
  Future<Map<RemoteTcpListenerKey, RemoteTcpListener>?>
  discoverRemoteListeningTcpListeners() async {
    discoveryCount++;
    return snapshot;
  }

  @override
  Future<bool> startAutomaticLocalForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String proxyHost,
    required bool isShellRelated,
  }) async {
    startCount++;
    if (startCount == 1) {
      await firstStartGate.future;
    }
    return true;
  }
}

class _PendingBindAutomaticForwardSession extends SshSession {
  _PendingBindAutomaticForwardSession({required super.client})
    : super(
        connectionId: 7,
        hostId: 42,
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
      );

  final bindStarted = Completer<void>();
  final pendingBind = Completer<ServerSocket>();

  @override
  Future<bool> startAutomaticPortForwardWatcher({
    required int generation,
  }) async => false;

  @override
  Future<Map<RemoteTcpListenerKey, RemoteTcpListener>?>
  discoverRemoteListeningTcpListeners() async =>
      _listenerSnapshot([_remoteListener(3000)]);

  @override
  Future<ServerSocket> bindPortForwardServerSocket(
    Object host,
    int port, {
    bool v6Only = false,
  }) {
    bindStarted.complete();
    return pendingBind.future;
  }
}

RemoteTcpListener _remoteListener(
  int port, {
  String host = 'localhost',
  bool isShellRelated = false,
}) => (host: host, port: port, isShellRelated: isShellRelated);

Map<RemoteTcpListenerKey, RemoteTcpListener> _listenerSnapshot(
  Iterable<RemoteTcpListener> listeners,
) => {
  for (final listener in listeners)
    remoteTcpListenerKey(listener.host, listener.port): listener,
};

String _expectedLoginShellCommand(SshSession session) =>
    'exec env COLORTERM=truecolor TERM_PROGRAM=kitty KITTY_WINDOW_ID=1 '
    'FORCE_HYPERLINK=1 MONKEYSSH_SHELL_TOKEN=${session.shellLineageToken} '
    r"""/bin/sh -lc 'if [ -n "$SHELL" ]; then exec "$SHELL" -l; else exec /bin/sh; fi'""";

String _expectedMarkedCommand(SshSession session, String command) =>
    'env MONKEYSSH_SHELL_TOKEN=${session.shellLineageToken} '
    '/bin/sh -c '
    '${_quoteTestPosixShellArgument(r'if [ -n "$SHELL" ]; then exec "$SHELL" -c "$1"; else exec /bin/sh -c "$1"; fi')} '
    'sh ${_quoteTestPosixShellArgument(command)}';

String _quoteTestPosixShellArgument(String value) =>
    "'${value.replaceAll("'", "'\"'\"'")}'";

Host _automaticForwardHost({
  required bool enabled,
  int id = 42,
  String label = 'Dev Box',
  String? portProxyName,
}) => Host(
  id: id,
  label: label,
  hostname: 'dev.example.com',
  port: 22,
  username: 'tester',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: enabled,
  portProxyName: portProxyName,
  sortOrder: 0,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition');
}

void _stubSessionStreams(_MockExecSession session, {String stdout = ''}) {
  when(() => session.stdout).thenAnswer(
    (_) => Stream<Uint8List>.fromIterable([
      Uint8List.fromList(utf8.encode(stdout)),
    ]),
  );
  when(() => session.stderr).thenAnswer((_) => const Stream.empty());
  when(() => session.done).thenAnswer((_) => Future<void>.value());
  when(session.close).thenAnswer((_) {});
}

class _FakeHostKeySocket implements SSHSocket, HostKeySource {
  _FakeHostKeySocket(this._hostKeyBytes);

  final Uint8List _hostKeyBytes;
  bool destroyed = false;
  int closeCalls = 0;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();

  @override
  Future<Uint8List> get hostKeyBytes async => _hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() async {
    closeCalls++;
    unawaited(_streamController.close());
    unawaited(_sinkController.close());
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done async {}

  @override
  void destroy() {
    destroyed = true;
  }
}

class _DestroyTrackingSocket implements SSHSocket {
  _DestroyTrackingSocket(this._delegate);

  final SSHSocket _delegate;
  bool destroyed = false;

  @override
  Stream<Uint8List> get stream => _delegate.stream;

  @override
  StreamSink<List<int>> get sink => _delegate.sink;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> flush() => _delegate.flush();

  @override
  Future<void> get done => _delegate.done;

  @override
  void destroy() {
    destroyed = true;
    _delegate.destroy();
  }
}

class _FakeForwardHostKeySocket extends _FakeHostKeySocket
    implements SSHForwardChannel {
  _FakeForwardHostKeySocket(super.hostKeyBytes);
}

class _RecordingAutomaticForwardSession extends SshSession {
  _RecordingAutomaticForwardSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    required super.config,
    this.name = 'session',
    this.configurationLog,
    this.useRecordedTunnels = false,
    this.tunnelChanges,
  });

  final String name;
  final List<String>? configurationLog;
  final bool useRecordedTunnels;
  final Map<int, ActiveTunnelInfo> tunnels = {};
  final StreamController<void>? tunnelChanges;

  @override
  Stream<void> get portForwardChanges =>
      tunnelChanges?.stream ?? super.portForwardChanges;
  final List<
    ({
      bool enabled,
      String? proxyHost,
      Set<RemoteTcpListenerKey> excludedRemoteListeners,
      bool includeHostLevelListeners,
    })
  >
  automaticConfigurations = [];

  @override
  List<ActiveTunnelInfo> get activeTunnels =>
      useRecordedTunnels ? tunnels.values.toList() : super.activeTunnels;

  @override
  Future<void> configureAutomaticPortForwarding({
    required bool enabled,
    String? proxyHost,
    Set<RemoteTcpListenerKey> excludedRemoteListeners = const {},
    Set<String> shellLineageTokens = const {},
    bool includeHostLevelListeners = true,
  }) async {
    configurationLog?.add('$name:$enabled');
    automaticConfigurations.add((
      enabled: enabled,
      proxyHost: proxyHost,
      excludedRemoteListeners: Set.unmodifiable(excludedRemoteListeners),
      includeHostLevelListeners: includeHostLevelListeners,
    ));
  }
}

class _OwnershipActiveSessionsNotifier extends ActiveSessionsNotifier {
  _OwnershipActiveSessionsNotifier({
    required this.sessions,
    required this.connectionStates,
  });

  final List<SshSession> sessions;
  final Map<int, SshConnectionState> connectionStates;

  @override
  Map<int, SshConnectionState> build() => connectionStates;

  @override
  List<int> getConnectionsForHost(int hostId) => sessions
      .where((session) => session.hostId == hostId)
      .map((session) => session.connectionId)
      .toList(growable: false);

  @override
  SshSession? getSession(int connectionId) {
    for (final session in sessions) {
      if (session.connectionId == connectionId) {
        return session;
      }
    }
    return null;
  }

  @override
  SshConnectionState getState(int connectionId) =>
      connectionStates[connectionId] ?? SshConnectionState.disconnected;
}

/// Polls [condition] until it holds or [timeout] elapses.
Future<void> _waitForCondition(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _ThrowOnRepeatedCloseSink implements StreamSink<List<int>> {
  _ThrowOnRepeatedCloseSink(this._delegate);

  final StreamSink<List<int>> _delegate;
  int addAttempts = 0;
  int addStreamAttempts = 0;
  int closeAttempts = 0;

  @override
  void add(List<int> data) {
    addAttempts++;
    _delegate.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    addStreamAttempts++;
    return _delegate.addStream(stream);
  }

  @override
  Future<void> close() {
    closeAttempts++;
    if (closeAttempts > 1) {
      throw StateError('Sink already closed');
    }
    return _delegate.close();
  }

  @override
  Future<void> get done => _delegate.done;
}

class _SingleCloseForwardChannel implements SSHForwardChannel {
  _SingleCloseForwardChannel() {
    sink = _ThrowOnRepeatedCloseSink(_sinkController.sink);
  }

  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>.broadcast();
  int destroyCalls = 0;
  Future<void> Function()? onFlush;

  @override
  // ignore: close_sinks
  late final _ThrowOnRepeatedCloseSink sink;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  Future<void> closeIncoming() => _streamController.close();

  @override
  Future<void> close() async {
    if (!_streamController.isClosed) {
      await _streamController.close();
    }
    if (!_sinkController.isClosed) {
      await _sinkController.close();
    }
  }

  @override
  Future<void> flush() async => onFlush?.call();

  @override
  Future<void> get done async {}

  @override
  void destroy() {
    destroyCalls++;
    if (!_streamController.isClosed) {
      unawaited(_streamController.close());
    }
  }
}

class _CancellableConnectSshService extends SshService {
  _CancellableConnectSshService({this.expectedAttempts = 1});

  final int expectedAttempts;
  final Completer<void> connectStarted = Completer<void>();
  final Completer<void> allAttemptsStarted = Completer<void>();
  final List<SshConnectionCancellationToken> receivedTokens = [];

  SshConnectionCancellationToken? get receivedToken =>
      receivedTokens.isEmpty ? null : receivedTokens.last;

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    receivedTokens.add(cancellationToken!);
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    if (receivedTokens.length >= expectedAttempts &&
        !allAttemptsStarted.isCompleted) {
      allAttemptsStarted.complete();
    }
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Opening network connection…',
      ),
    );
    await cancellationToken.cancelled;
    return const SshConnectionResult.userCancelled();
  }
}

class _EnabledTerminalNotificationsNotifier
    extends TerminalNotificationsNotifier {
  @override
  bool build() => true;

  bool get debugEnabled => state;

  set debugEnabled(bool enabled) => state = enabled;
}

class _DelayedTerminalNotificationService extends LocalNotificationService {
  final showStarted = Completer<void>();
  final releaseShow = Completer<void>();
  final calls = <String>[];
  TerminalNotificationPayload? lastPayload;
  bool throwOnShow = false;
  bool throwOnClear = false;

  @override
  Future<bool> showTerminalNotification({
    required int notificationId,
    required String title,
    required String body,
    required TerminalNotificationPayload payload,
    TerminalNotificationUrgency urgency = TerminalNotificationUrgency.normal,
    TerminalNotificationSound sound = TerminalNotificationSound.silent,
    Duration? timeout,
  }) async {
    lastPayload = payload;
    calls.add('show-start:$notificationId');
    if (!showStarted.isCompleted) showStarted.complete();
    if (throwOnShow) throw StateError('show failed');
    await releaseShow.future;
    calls.add('show-finish:$notificationId');
    return true;
  }

  @override
  Future<void> clearTerminalNotification(int notificationId) async {
    calls.add('clear:$notificationId');
    if (throwOnClear) throw StateError('clear failed');
  }
}

class _FakeActiveSessionsSshService extends SshService {
  _FakeActiveSessionsSshService({
    this.connectGate,
    this.useRecordedTunnels = false,
    this.tunnelChanges,
  });

  final bool useRecordedTunnels;
  final StreamController<void>? tunnelChanges;

  final Map<int, SshSession> _sessions = {};
  final Map<int, Completer<void>> _clientDoneCompleters = {};
  final Completer<void> connectStarted = Completer<void>();
  final Completer<void>? connectGate;
  int _nextConnectionId = 1;
  Completer<void>? disconnectGate;

  @override
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    await connectGate?.future;
    final connectionId = _nextConnectionId++;
    final client = _MockSshClient();
    final clientDoneCompleter = Completer<void>();
    _clientDoneCompleters[connectionId] = clientDoneCompleter;
    when(() => client.done).thenAnswer((_) => clientDoneCompleter.future);
    final session = _RecordingAutomaticForwardSession(
      connectionId: connectionId,
      hostId: hostId,
      useRecordedTunnels: useRecordedTunnels,
      tunnelChanges: tunnelChanges,
      client: client,
      config: SshConnectionConfig(
        hostname: 'host-$hostId.example.com',
        port: 22,
        username: 'tester',
      ),
    );
    _sessions[connectionId] = session;
    return SshConnectionResult(success: true, connectionId: connectionId);
  }

  @override
  Future<void> disconnect(int connectionId) async {
    _sessions.remove(connectionId);
    _clientDoneCompleters.remove(connectionId);
    await disconnectGate?.future;
  }

  @override
  Future<void> disconnectAll() async {
    _sessions.clear();
    _clientDoneCompleters.clear();
    await disconnectGate?.future;
  }

  @override
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  _MockSshClient clientFor(int connectionId) =>
      _sessions[connectionId]!.client as _MockSshClient;

  void completeConnection(int connectionId) {
    final completer = _clientDoneCompleters[connectionId];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

String _structurallyValidInvalidEncryptedSecret() {
  final envelope = {
    'n': base64Url.encode(List<int>.filled(12, 1)),
    'c': base64Url.encode([1, 2, 3]),
    'm': base64Url.encode(List<int>.filled(16, 2)),
  };
  return 'ENCv1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
}

SshSession _testSession(
  SSHClient client, {
  int connectionId = 1,
  int hostId = 42,
  String hostname = 'host.example.com',
  String username = 'tester',
}) => SshSession(
  connectionId: connectionId,
  hostId: hostId,
  client: client,
  config: SshConnectionConfig(hostname: hostname, port: 22, username: username),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const SSHPtyConfig());
  registerFallbackValue(Uint8List(0));
  registerFallbackValue(Duration.zero);

  group('SshConnectionState', () {
    test('has expected values', () {
      expect(SshConnectionState.values, hasLength(6));
      expect(SshConnectionState.disconnected, isNotNull);
      expect(SshConnectionState.connecting, isNotNull);
      expect(SshConnectionState.authenticating, isNotNull);
      expect(SshConnectionState.connected, isNotNull);
      expect(SshConnectionState.error, isNotNull);
      expect(SshConnectionState.reconnecting, isNotNull);
    });
  });

  group('automatic port forwarding', () {
    test('close cancels a pending automatic-forward bind', () async {
      final client = _MockSshClient();
      when(client.close).thenAnswer((_) async {});
      final session = _PendingBindAutomaticForwardSession(client: client);
      final configured = session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      await session.bindStarted.future;

      await session.close().timeout(const Duration(seconds: 1));
      await configured;
      expect(session.pendingBind.isCompleted, isFalse);
      expect(session.activeTunnels, isEmpty);
      expect(session.automaticForwardedRemoteListeners, isEmpty);
      session.pendingBind.completeError(
        const SocketException('Bind cancelled'),
      );
      await pumpEventQueue();
      verify(client.close).called(1);
    });

    test('parses listener output from supported remote tools', () {
      const output = '''
__monkeyssh_shell_descendant_pids__:42,43
LISTEN 0 4096 127.0.0.2:3000 0.0.0.0:* users:(("node",pid=42,fd=9))
LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:* users:(("vite",pid=43,fd=10))
tcp4 0 0 127.0.0.1.8080 *.* LISTEN
LISTEN 0 4096 192.168.1.20:9090 0.0.0.0:*
LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*
tcp6 0 0 *.4300 *.* LISTEN
p43
tIPv6
n*:5173
4200
LISTEN ::1:4201
''';

      expect(parseRemoteListeningTcpListeners(output), {
        remoteTcpListenerKey('127.0.0.2', 3000): (
          host: '127.0.0.2',
          port: 3000,
          isShellRelated: true,
        ),
        remoteTcpListenerKey('127.0.0.1', 3000): (
          host: '127.0.0.1',
          port: 3000,
          isShellRelated: true,
        ),
        remoteTcpListenerKey('127.0.0.1', 8080): (
          host: '127.0.0.1',
          port: 8080,
          isShellRelated: false,
        ),
        remoteTcpListenerKey('::1', 5173): (
          host: '::1',
          port: 5173,
          isShellRelated: true,
        ),
        remoteTcpListenerKey('localhost', 4200): (
          host: 'localhost',
          port: 4200,
          isShellRelated: false,
        ),
        remoteTcpListenerKey('::1', 4201): (
          host: '::1',
          port: 4201,
          isShellRelated: false,
        ),
        remoteTcpListenerKey('::1', 4300): (
          host: '::1',
          port: 4300,
          isShellRelated: false,
        ),
        remoteTcpListenerKey('127.0.0.53', 53): (
          host: '127.0.0.53',
          port: 53,
          isShellRelated: false,
        ),
      });
    });

    test('localhost saved targets exclude both loopback families', () {
      expect(remoteTcpListenerExclusionKeys('localhost', 3000), {
        remoteTcpListenerKey('127.0.0.1', 3000),
        remoteTcpListenerKey('::1', 3000),
      });
      expect(remoteTcpListenerExclusionKeys('127.0.0.2', 3000), {
        remoteTcpListenerKey('127.0.0.2', 3000),
      });
    });

    test('builds a valid persistent POSIX watcher command', () async {
      final session = _testSession(
        _MockSshClient(),
        connectionId: 7,
        hostname: 'dev.example.com',
      );

      final command = session.buildAutomaticPortForwardWatcherCommand();
      final syntaxCheck = await Process.run('/bin/sh', ['-n', '-c', command]);

      expect(syntaxCheck.exitCode, 0, reason: '${syntaxCheck.stderr}');
      expect(command, startsWith('/bin/sh -c '));
      expect(command, contains('sleep 0.5'));
      expect(command, contains('cat >/dev/null'));
      expect(command, contains(r'kill -TERM "$$"'));
      expect(command, contains('watcher_guard'));
      expect(command, contains(_automaticPortWatcherSnapshotBeginMarker));
      expect(command, contains(_automaticPortWatcherSnapshotEndMarker));
      expect(command, contains('*$_automaticPortDiscoveryUnavailableMarker*)'));
    });

    test('builds a streaming Windows watcher command', () {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      final session = _testSession(
        client,
        connectionId: 7,
        hostname: 'dev.example.com',
      );

      final script = decodeEncodedPowerShell(
        session.buildAutomaticPortForwardWatcherCommand(),
      );

      expect(script, contains('Start-Sleep -Milliseconds 500'));
      expect(script, contains(_automaticPortWatcherSnapshotBeginMarker));
      expect(script, contains(_automaticPortWatcherSnapshotEndMarker));
      expect(script, contains(r'$__flStream.Flush()'));
    });

    test('keeps shell lineage stable across reconnect connection IDs', () {
      const config = SshConnectionConfig(
        hostname: 'dev.example.com',
        port: 22,
        username: 'tester',
      );
      final first = SshSession(
        connectionId: 1,
        hostId: 42,
        client: _MockSshClient(),
        config: config,
      );
      final reconnected = SshSession(
        connectionId: 99,
        hostId: 42,
        client: _MockSshClient(),
        config: config,
      );
      final differentHost = _testSession(
        _MockSshClient(),
        hostId: 43,
        hostname: 'other.example.com',
      );

      expect(reconnected.shellLineageToken, first.shellLineageToken);
      expect(differentHost.shellLineageToken, isNot(first.shellLineageToken));
    });

    test('rejects listener scans that end without a completion marker', () {
      final client = _MockSshClient();
      final execSession = _MockExecSession();
      _stubSessionStreams(
        execSession,
        stdout: 'LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:*\n',
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);
      final session = _testSession(
        client,
        hostId: 7,
        hostname: 'dev.example.com',
      );

      expect(
        session.discoverRemoteListeningTcpListeners(),
        throwsA(isA<StateError>()),
      );
    });

    test('probes listener PIDs for connected-shell lineage', () async {
      final client = _MockSshClient();
      final execSession = _MockExecSession();
      _stubSessionStreams(
        execSession,
        stdout: '__monkeyssh_port_discovery_done__\n',
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);
      final session = _testSession(
        client,
        connectionId: 7,
        hostname: 'dev.example.com',
      );
      await session.updateAutomaticPortForwardProcessRoots({7300});

      await session.discoverRemoteListeningTcpListeners();

      final command =
          verify(
                () => client.execute(captureAny(), pty: any(named: 'pty')),
              ).captured.single
              as String;
      expect(command, startsWith('/bin/sh -c '));
      expect(command, contains('MONKEYSSH_SHELL_TOKEN'));
      expect(command, contains(session.shellLineageToken));
      expect(command, contains('root_pids='));
      expect(command, contains('7300'));
      expect(command, contains('ps eww -axo pid=,command='));
      expect(command, contains('ps -eo pid=,ppid='));
      expect(command, contains(r'*",$ppid,"*'));
      expect(command, contains('ss -H -ltnp'));
      expect(command, contains('lsof -nP -iTCP -sTCP:LISTEN -Fpfnt'));
      expect(
        command.indexOf('lsof -nP'),
        lessThan(command.indexOf('netstat -an')),
      );
      expect(command, contains(r'if [ "$lsof_status" -gt 1 ]'));
    });

    test(
      'keeps mux process roots while automatic forwarding is disabled',
      () async {
        final session = _testSession(
          _MockSshClient(),
          connectionId: 7,
          hostname: 'dev.example.com',
        );

        await session.updateAutomaticPortForwardProcessRoots({7300});
        await session.configureAutomaticPortForwarding(enabled: false);

        expect(
          session.buildAutomaticPortForwardWatcherCommand(),
          contains('7300'),
        );
      },
    );

    test(
      'adds new listeners and removes ports after two missed scans',
      () async {
        final session = _AutomaticForwardTestSession(
          connectionId: 1,
          hostId: 7,
          client: _MockSshClient(),
          config: const SshConnectionConfig(
            hostname: 'dev.example.com',
            port: 2222,
            username: 'tester',
          ),
          discoveries: [
            _listenerSnapshot([
              _remoteListener(22),
              _remoteListener(2222),
              _remoteListener(3000, host: '127.0.0.2', isShellRelated: true),
            ]),
            _listenerSnapshot([_remoteListener(3000), _remoteListener(4000)]),
            _listenerSnapshot([_remoteListener(4000)]),
            _listenerSnapshot([_remoteListener(4000)]),
            _listenerSnapshot([_remoteListener(3000), _remoteListener(4000)]),
          ],
        );

        await session.configureAutomaticPortForwarding(
          enabled: true,
          proxyHost: 'dev-box.localhost',
        );
        expect(session.automaticForwardedRemotePorts, {3000});
        expect(session.starts, [
          (
            remoteHost: '127.0.0.2',
            remotePort: 3000,
            proxyHost: 'dev-box.localhost',
            isShellRelated: true,
          ),
        ]);

        await session.refreshAutomaticPortForwards();
        expect(session.automaticForwardedRemotePorts, {3000, 4000});
        await session.refreshAutomaticPortForwards();
        expect(session.automaticForwardedRemotePorts, {3000, 4000});
        await session.refreshAutomaticPortForwards();
        expect(session.automaticForwardedRemotePorts, {4000});

        await session.configureAutomaticPortForwarding(
          enabled: true,
          proxyHost: 'dev-box.localhost',
          excludedRemoteListeners: {remoteTcpListenerKey('localhost', 4000)},
        );
        expect(session.automaticForwardedRemotePorts, {3000});

        await session.configureAutomaticPortForwarding(enabled: false);
        expect(session.automaticForwardedRemotePorts, isEmpty);
      },
    );

    test('does not automatically forward an active reverse listener', () async {
      final client = _MockSshClient();
      final remoteForward = _MockRemoteForward();
      when(() => remoteForward.host).thenReturn('127.0.0.1');
      when(() => remoteForward.port).thenReturn(41002);
      when(
        () => remoteForward.connections,
      ).thenAnswer((_) => const Stream<SSHForwardChannel>.empty());
      when(remoteForward.close).thenReturn(null);
      when(
        () => client.forwardRemote(host: '127.0.0.1', port: 0),
      ).thenAnswer((_) async => remoteForward);

      final session = _AutomaticForwardTestSession(
        connectionId: 1,
        hostId: 7,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        discoveries: [
          _listenerSnapshot([
            _remoteListener(41002),
            _remoteListener(3000, host: '127.0.0.2'),
          ]),
        ],
      );
      addTearDown(session.stopAllForwards);

      expect(
        await session.startRemoteForward(
          portForwardId: -2147483002,
          remoteHost: '127.0.0.1',
          remotePort: 0,
          localHost: '192.0.2.10',
          localPort: 37123,
        ),
        isTrue,
      );

      await session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );

      // The reverse forward's own listener lives on the SSH host; forwarding it
      // back to this device would loop the tunnel onto itself.
      expect(session.automaticForwardedRemotePorts, {3000});
      expect(
        session.starts.map((start) => start.remotePort),
        isNot(contains(41002)),
      );
    });

    test('binds detected ports under the host proxy domain', () async {
      final session = _testSession(
        _MockSshClient(),
        hostId: 7,
        hostname: 'dev.example.com',
      );
      addTearDown(session.stopAllForwards);

      expect(
        await session.startAutomaticLocalForward(
          portForwardId: -3000,
          remoteHost: '127.0.0.2',
          remotePort: 3000,
          proxyHost: 'dev-box.localhost',
          isShellRelated: true,
        ),
        isTrue,
      );

      final tunnel = session.activeTunnels.single;
      expect(tunnel.isAutomatic, isTrue);
      expect(tunnel.localHost, InternetAddress.loopbackIPv4.address);
      expect(tunnel.localPort, greaterThan(0));
      expect(tunnel.browserHost, 'dev-box.localhost');
      expect(tunnel.browserPort, tunnel.localPort);
      final expectedFallbackHost = portForwardBrowserFallbackHostForHostId(7);
      expect(tunnel.browserFallbackHost, anyOf(isNull, expectedFallbackHost));
      if (Platform.isLinux) {
        expect(tunnel.browserFallbackHost, expectedFallbackHost);
      }
      expect(tunnel.remoteHost, '127.0.0.2');
      expect(tunnel.remotePort, 3000);
      expect(tunnel.isShellRelated, isTrue);
    });

    test(
      'keeps an automatic tunnel when a saved replacement cannot bind',
      () async {
        final session = _testSession(
          _MockSshClient(),
          hostId: 7,
          hostname: 'dev.example.com',
        );
        final occupiedSocket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() async {
          await occupiedSocket.close();
          await session.stopAllForwards();
        });

        expect(
          await session.startAutomaticLocalForward(
            portForwardId: -3000,
            remoteHost: '127.0.0.1',
            remotePort: 3000,
            proxyHost: 'dev-box.localhost',
            isShellRelated: true,
          ),
          isTrue,
        );

        expect(
          await session.startLocalForward(
            portForwardId: 1,
            localHost: InternetAddress.loopbackIPv4.address,
            localPort: occupiedSocket.port,
            remoteHost: '127.0.0.1',
            remotePort: 3000,
          ),
          isFalse,
        );
        expect(session.activeTunnels, hasLength(1));
        expect(session.activeTunnels.single.isAutomatic, isTrue);
        expect(session.activeTunnels.single.remotePort, 3000);
      },
    );

    test('stops polling when the remote has no discovery tool', () async {
      final session = _AutomaticForwardTestSession(
        connectionId: 1,
        hostId: 7,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        discoveries: [null],
      );

      await session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );

      expect(session.automaticPortForwardDiscoveryActive, isFalse);
      expect(session.automaticForwardedRemotePorts, isEmpty);
    });

    test('clears stale tunnels when discovery becomes unsupported', () async {
      final session = _AutomaticForwardTestSession(
        connectionId: 1,
        hostId: 7,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        discoveries: [
          _listenerSnapshot([_remoteListener(3000)]),
          null,
        ],
      );

      await session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      expect(session.automaticForwardedRemotePorts, {3000});

      await session.refreshAutomaticPortForwards();

      expect(session.automaticForwardedRemotePorts, isEmpty);
      expect(session.automaticPortForwardDiscoveryActive, isFalse);
    });

    test('keeps shared Docker-style listeners on the endpoint owner', () async {
      final snapshot = _listenerSnapshot([
        _remoteListener(3000, isShellRelated: true),
        _remoteListener(5432),
      ]);
      final session = _AutomaticForwardTestSession(
        connectionId: 1,
        hostId: 7,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        discoveries: [snapshot, snapshot],
      );

      await session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
        includeHostLevelListeners: false,
      );
      expect(session.automaticForwardedRemotePorts, {3000});

      await session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      expect(session.automaticForwardedRemotePorts, {3000, 5432});
    });

    test(
      'streams changed listener snapshots over one watcher channel',
      () async {
        final client = _MockSshClient();
        final watcher = _MockExecSession();
        final stdout = StreamController<Uint8List>();
        final done = Completer<void>();
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => watcher);
        when(() => watcher.stdout).thenAnswer((_) => stdout.stream);
        when(() => watcher.stderr).thenAnswer((_) => const Stream.empty());
        when(() => watcher.done).thenAnswer((_) => done.future);
        when(watcher.close).thenAnswer((_) {});
        final session = _testSession(
          client,
          connectionId: 7,
          hostname: 'dev.example.com',
        );
        addTearDown(() async {
          await session.configureAutomaticPortForwarding(enabled: false);
          if (!stdout.isClosed) {
            await stdout.close();
          }
          if (!done.isCompleted) {
            done.complete();
          }
        });

        final configured = session.configureAutomaticPortForwarding(
          enabled: true,
          proxyHost: 'dev-box.localhost',
        );
        await untilCalled(() => client.execute(any(), pty: any(named: 'pty')));
        final watcherCommand =
            verify(
                  () => client.execute(captureAny(), pty: any(named: 'pty')),
                ).captured.single
                as String;
        expect(watcherCommand, contains('while :; do'));
        expect(watcherCommand, contains('sleep 0.5'));
        expect(watcherCommand, contains('previous_set'));

        stdout.add(
          Uint8List.fromList(
            utf8.encode(
              '$_automaticPortWatcherSnapshotBeginMarker\n'
              'LISTEN 127.0.0.1:3000\n'
              'LISTEN 127.0.0.2:3000\n'
              '$_automaticPortWatcherSnapshotEndMarker\n',
            ),
          ),
        );
        await configured;
        await _waitUntil(
          () => session.automaticForwardedRemoteListeners.length == 2,
        );

        expect(session.automaticPortForwardWatcherActive, isTrue);
        expect(session.automaticPortForwardDiscoveryActive, isFalse);
        expect(session.automaticForwardedRemotePorts, {3000});
        expect(session.automaticForwardedRemoteListeners, {
          remoteTcpListenerKey('127.0.0.1', 3000),
          remoteTcpListenerKey('127.0.0.2', 3000),
        });
        expect(
          session.activeTunnels
              .where((tunnel) => tunnel.isAutomatic)
              .map((tunnel) => tunnel.browserHost)
              .toSet(),
          {'dev-box.localhost'},
        );

        stdout.add(
          Uint8List.fromList(
            utf8.encode(
              '$_automaticPortWatcherSnapshotBeginMarker\n'
              'LISTEN 127.0.0.1:4000\n'
              '$_automaticPortWatcherSnapshotEndMarker\n',
            ),
          ),
        );
        await _waitUntil(
          () =>
              session.automaticForwardedRemotePorts.length == 1 &&
              session.automaticForwardedRemotePorts.contains(4000),
        );

        expect(session.automaticForwardedRemotePorts, {4000});
        verifyNever(() => client.execute(any(), pty: any(named: 'pty')));
      },
    );

    test('serializes watcher and fallback polling reconciliation', () async {
      final client = _MockSshClient();
      final watcher = _MockExecSession();
      final stdout = StreamController<Uint8List>();
      final done = Completer<void>();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => watcher);
      when(() => watcher.stdout).thenAnswer((_) => stdout.stream);
      when(() => watcher.stderr).thenAnswer((_) => const Stream.empty());
      when(() => watcher.done).thenAnswer((_) => done.future);
      when(watcher.close).thenAnswer((_) {});
      final snapshot = _listenerSnapshot([_remoteListener(3000)]);
      final session = _ConcurrentAutomaticForwardTestSession(
        connectionId: 7,
        hostId: 42,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        snapshot: snapshot,
      );
      addTearDown(() async {
        if (!session.firstStartGate.isCompleted) {
          session.firstStartGate.complete();
        }
        await session.configureAutomaticPortForwarding(enabled: false);
        if (!stdout.isClosed) {
          await stdout.close();
        }
        if (!done.isCompleted) {
          done.complete();
        }
      });

      final configured = session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      await untilCalled(() => client.execute(any(), pty: any(named: 'pty')));
      stdout.add(
        Uint8List.fromList(
          utf8.encode(
            '$_automaticPortWatcherSnapshotBeginMarker\n'
            'LISTEN 127.0.0.1:3000\n'
            '$_automaticPortWatcherSnapshotEndMarker\n',
          ),
        ),
      );
      await _waitUntil(() => session.startCount == 1);

      await stdout.close();
      done.complete();
      await _waitUntil(() => session.discoveryCount > 0);
      await pumpEventQueue();

      expect(session.startCount, 1);
      session.firstStartGate.complete();
      await configured;
      await pumpEventQueue();
      expect(session.startCount, 1);
      expect(session.automaticForwardedRemotePorts, {3000});
    });

    test('reclassifies listeners after mux process roots arrive', () async {
      final client = _MockSshClient();
      final watchers = [_MockExecSession(), _MockExecSession()];
      final stdoutControllers = [
        StreamController<Uint8List>(),
        StreamController<Uint8List>(),
      ];
      final doneCompleters = [Completer<void>(), Completer<void>()];
      var watcherIndex = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        final index = watcherIndex++;
        return watchers[index];
      });
      for (var index = 0; index < watchers.length; index++) {
        when(
          () => watchers[index].stdout,
        ).thenAnswer((_) => stdoutControllers[index].stream);
        when(
          () => watchers[index].stderr,
        ).thenAnswer((_) => const Stream.empty());
        when(
          () => watchers[index].done,
        ).thenAnswer((_) => doneCompleters[index].future);
        when(watchers[index].close).thenAnswer((_) {});
      }
      final session = _testSession(
        client,
        connectionId: 7,
        hostname: 'dev.example.com',
      );
      addTearDown(() async {
        for (final completer in doneCompleters) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
        await session.configureAutomaticPortForwarding(enabled: false);
        for (final controller in stdoutControllers) {
          if (!controller.isClosed) {
            await controller.close();
          }
        }
      });

      final configured = session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      await _waitUntil(() => watcherIndex == 1);
      stdoutControllers[0].add(
        Uint8List.fromList(
          utf8.encode(
            '$_automaticPortWatcherSnapshotBeginMarker\n'
            'LISTEN 0 4096 127.0.0.1:4898 0.0.0.0:* '
            'users:(("node",pid=42,fd=9))\n'
            '$_automaticPortWatcherSnapshotEndMarker\n',
          ),
        ),
      );
      await configured;
      await _waitUntil(() => session.activeTunnels.isNotEmpty);
      expect(session.activeTunnels.single.isShellRelated, isFalse);

      final rootsUpdated = session.updateAutomaticPortForwardProcessRoots({
        7300,
      });
      await pumpEventQueue();
      expect(
        watcherIndex,
        1,
        reason: 'a replacement must wait for the old SSH channel to close',
      );
      doneCompleters[0].complete();
      await _waitUntil(() => watcherIndex == 2);
      stdoutControllers[1].add(
        Uint8List.fromList(
          utf8.encode(
            '$_automaticPortWatcherSnapshotBeginMarker\n'
            '__monkeyssh_shell_descendant_pids__:42\n'
            'LISTEN 0 4096 127.0.0.1:4898 0.0.0.0:* '
            'users:(("node",pid=42,fd=9))\n'
            '$_automaticPortWatcherSnapshotEndMarker\n',
          ),
        ),
      );
      await rootsUpdated;
      await _waitUntil(() => session.activeTunnels.single.isShellRelated);

      expect(session.activeTunnels.single.remotePort, 4898);
      expect(session.activeTunnels.single.isShellRelated, isTrue);
    });

    test('does not poll after watcher reports discovery unsupported', () async {
      final client = _MockSshClient();
      final watcher = _MockExecSession();
      final stdout = StreamController<Uint8List>();
      final done = Completer<void>();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => watcher);
      when(() => watcher.stdout).thenAnswer((_) => stdout.stream);
      when(() => watcher.stderr).thenAnswer((_) => const Stream.empty());
      when(() => watcher.done).thenAnswer((_) => done.future);
      when(watcher.close).thenAnswer((_) {});
      final session = _testSession(
        client,
        connectionId: 7,
        hostname: 'dev.example.com',
      );
      addTearDown(() async {
        await session.configureAutomaticPortForwarding(enabled: false);
        if (!stdout.isClosed) {
          await stdout.close();
        }
        if (!done.isCompleted) {
          done.complete();
        }
      });

      final configured = session.configureAutomaticPortForwarding(
        enabled: true,
        proxyHost: 'dev-box.localhost',
      );
      await untilCalled(() => client.execute(any(), pty: any(named: 'pty')));
      stdout.add(
        Uint8List.fromList(
          utf8.encode(
            '$_automaticPortWatcherSnapshotBeginMarker\n'
            'LISTEN 127.0.0.1:3000\n'
            '$_automaticPortWatcherSnapshotEndMarker\n',
          ),
        ),
      );
      await configured;
      await _waitUntil(
        () => session.automaticForwardedRemotePorts.contains(3000),
      );

      stdout.add(
        Uint8List.fromList(
          utf8.encode(
            '$_automaticPortWatcherSnapshotBeginMarker\n'
            '$_automaticPortDiscoveryUnavailableMarker\n'
            '$_automaticPortWatcherSnapshotEndMarker\n',
          ),
        ),
      );
      await _waitUntil(() => session.automaticForwardedRemotePorts.isEmpty);
      await stdout.close();
      done.complete();
      await pumpEventQueue();

      expect(session.automaticPortForwardWatcherActive, isFalse);
      expect(session.automaticPortForwardDiscoveryActive, isFalse);
      expect(session.automaticForwardedRemotePorts, isEmpty);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
    });

    test(
      'falls back to periodic scans if the watcher channel closes',
      () async {
        final client = _MockSshClient();
        final watcher = _MockExecSession();
        final watcherStdout = StreamController<Uint8List>();
        final watcherDone = Completer<void>();
        final scan = _MockExecSession();
        _stubSessionStreams(
          scan,
          stdout:
              'LISTEN 127.0.0.1:3000\n'
              '__monkeyssh_port_discovery_done__\n',
        );
        var executeCount = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          executeCount++;
          return executeCount == 1 ? watcher : scan;
        });
        when(() => watcher.stdout).thenAnswer((_) => watcherStdout.stream);
        when(() => watcher.stderr).thenAnswer((_) => const Stream.empty());
        when(() => watcher.done).thenAnswer((_) => watcherDone.future);
        when(watcher.close).thenAnswer((_) {});
        final session = _testSession(
          client,
          connectionId: 7,
          hostname: 'dev.example.com',
        );
        addTearDown(() async {
          await session.configureAutomaticPortForwarding(enabled: false);
          if (!watcherStdout.isClosed) {
            await watcherStdout.close();
          }
          if (!watcherDone.isCompleted) {
            watcherDone.complete();
          }
        });

        final configured = session.configureAutomaticPortForwarding(
          enabled: true,
          proxyHost: 'dev-box.localhost',
        );
        await untilCalled(() => client.execute(any(), pty: any(named: 'pty')));
        watcherStdout.add(
          Uint8List.fromList(
            utf8.encode(
              '$_automaticPortWatcherSnapshotBeginMarker\n'
              'LISTEN 127.0.0.1:3000\n'
              '$_automaticPortWatcherSnapshotEndMarker\n',
            ),
          ),
        );
        await configured;
        await _waitUntil(
          () => session.automaticForwardedRemotePorts.contains(3000),
        );

        await watcherStdout.close();
        watcherDone.complete();
        await _waitUntil(
          () =>
              session.automaticPortForwardDiscoveryActive && executeCount >= 2,
        );

        expect(session.automaticPortForwardWatcherActive, isFalse);
        expect(session.automaticPortForwardDiscoveryActive, isTrue);
        expect(executeCount, 2);
      },
    );
  });

  test('session keeps MonkeyMux host resize gating for terminal lifetime', () {
    final session = _testSession(
      _MockSshClient(),
      hostId: 1,
      hostname: 'example.com',
    );
    final terminal = session.getOrCreateTerminal()
      ..resize(80, 24)
      ..write('\x1b[?8;30;100t');
    expect(terminal.viewWidth, 80);
    expect(terminal.hostResizeGeneration, 0);

    session.remoteMuxBackend = RemoteMuxBackend.monkeyMux;
    terminal.write('\x1b[?8;30;100t');
    expect(terminal.viewWidth, 100);
    expect(terminal.viewHeight, 30);
    expect(terminal.hostResizeGeneration, 1);

    session.remoteMuxBackend = RemoteMuxBackend.tmux;
    terminal.write('\x1b[?8;40;120t');
    expect(terminal.viewWidth, 100);
    expect(terminal.viewHeight, 30);
    expect(terminal.hostResizeGeneration, 1);
  });

  group('remoteVersionIndicatesWindows', () {
    test('detects Windows OpenSSH identification strings', () {
      expect(
        remoteVersionIndicatesWindows('SSH-2.0-OpenSSH_for_Windows_9.5'),
        isTrue,
      );
      expect(
        remoteVersionIndicatesWindows('SSH-2.0-OpenSSH_for_Windows_8.1'),
        isTrue,
      );
    });

    test('is case-insensitive', () {
      expect(
        remoteVersionIndicatesWindows('SSH-2.0-someserver_WINDOWS_1.0'),
        isTrue,
      );
    });

    test('returns false for POSIX servers', () {
      expect(remoteVersionIndicatesWindows('SSH-2.0-OpenSSH_9.6'), isFalse);
      expect(
        remoteVersionIndicatesWindows('SSH-2.0-OpenSSH_8.9p1 Ubuntu-3'),
        isFalse,
      );
      expect(
        remoteVersionIndicatesWindows('SSH-2.0-dropbear_2022.83'),
        isFalse,
      );
    });

    test('returns false for unknown or empty identification strings', () {
      expect(remoteVersionIndicatesWindows(null), isFalse);
      expect(remoteVersionIndicatesWindows(''), isFalse);
    });
  });

  group('terminal metadata helpers', () {
    test('parses and formats working directory metadata', () {
      final uri = parseTerminalWorkingDirectoryUri([
        'file://remote.example.com/Users/tester/project%20name',
      ]);

      expect(uri, isNotNull);
      expect(
        resolveTerminalWorkingDirectoryPath(uri),
        '/Users/tester/project name',
      );
      expect(
        formatTerminalWorkingDirectoryLabel(uri),
        'remote.example.com:/Users/tester/project name',
      );
    });

    test('parses OSC 633, OSC 9;9, and iTerm2 working directories', () {
      final vscode = parseTerminalShellWorkingDirectoryOsc('633', const [
        'P',
        'Cwd=/home/demo/project',
      ]);
      final conEmu = parseTerminalShellWorkingDirectoryOsc('9', const [
        '9',
        r'C:\Users\demo\project',
      ]);
      final remoteHost = parseTerminalReportedRemoteHost(const [
        'RemoteHost=demo@build.example.com',
      ]);
      final iterm = parseTerminalShellWorkingDirectoryOsc('1337', const [
        'CurrentDir=/srv/project',
      ], remoteHost: remoteHost);

      expect(resolveTerminalWorkingDirectoryPath(vscode), '/home/demo/project');
      expect(
        resolveTerminalWorkingDirectoryPath(
          parseTerminalShellWorkingDirectoryOsc('633', const [
            'P',
            'Cwd=/home/demo/project',
            '',
          ]),
        ),
        '/home/demo/project',
      );
      expect(
        resolveTerminalWorkingDirectoryPath(conEmu),
        '/C:/Users/demo/project',
      );
      expect(iterm?.host, 'build.example.com');
      expect(resolveTerminalWorkingDirectoryPath(iterm), '/srv/project');
      expect(parseTerminalWorkingDirectoryValue('relative/path'), isNull);
    });

    test('falls back to the raw working-directory path on bad encoding', () {
      final uri = Uri.parse('file://remote.example.com/Users/tester/100%');

      expect(resolveTerminalWorkingDirectoryPath(uri), '/Users/tester/100%');
      expect(
        formatTerminalWorkingDirectoryLabel(uri),
        'remote.example.com:/Users/tester/100%',
      );
    });

    test('preserves shell state transitions and exit codes', () {
      final promptState = applyTerminalShellIntegrationOsc(
        const ['A'],
        previousStatus: null,
        previousExitCode: null,
      );
      expect(promptState.status, TerminalShellStatus.prompt);
      expect(promptState.lastExitCode, isNull);

      final runningState = applyTerminalShellIntegrationOsc(
        const ['C'],
        previousStatus: promptState.status,
        previousExitCode: promptState.lastExitCode,
      );
      expect(runningState.status, TerminalShellStatus.runningCommand);
      expect(runningState.lastExitCode, isNull);

      final exitState = applyTerminalShellIntegrationOsc(
        const ['D', '17'],
        previousStatus: runningState.status,
        previousExitCode: runningState.lastExitCode,
      );
      expect(exitState.status, TerminalShellStatus.prompt);
      expect(exitState.lastExitCode, 17);
      expect(
        describeTerminalShellStatus(
          exitState.status,
          lastExitCode: exitState.lastExitCode,
        ),
        'Exit 17',
      );
    });

    test(
      'preserves the previous exit code when OSC 133 exit code is invalid',
      () {
        final exitState = applyTerminalShellIntegrationOsc(
          const ['D', 'bad'],
          previousStatus: TerminalShellStatus.runningCommand,
          previousExitCode: 17,
        );

        expect(exitState.status, TerminalShellStatus.prompt);
        expect(exitState.lastExitCode, 17);
      },
    );

    test(
      'normalizes cursor position reports to terminal protocol coordinates',
      () {
        expect(
          normalizeTerminalOutputForRemoteShell('before\x1b[0;0Rafter'),
          'before\x1b[1;1Rafter',
        );
        expect(normalizeTerminalOutputForRemoteShell('\x1b[4;7R'), '\x1b[5;8R');
      },
    );

    test('adapts insert mode output so xterm shifts existing cells', () {
      final terminal = Terminal(maxLines: 100);
      final decoder = TerminalXtermOutputDecoder();
      final result = decoder.add(input: 'abcdef\r\x1b[3C\x1b[4hXY');

      terminal.write(result.output);

      expect(decoder.pendingCodeUnits, 0);
      expect(result.insertMode, isTrue);
      expect(terminal.lines[0].getText(0, 8), 'abcXYdef');
    });

    test('adapts split insert mode sequences across chunks', () {
      final terminal = Terminal(maxLines: 100);
      final decoder = TerminalXtermOutputDecoder();
      final first = decoder.add(input: 'abcdef\r\x1b[3C\x1b[');
      terminal.write(first.output);

      expect(decoder.pendingCodeUnits, '\x1b['.length);
      final second = decoder.add(input: '4hZ\x1b[4lQ');
      terminal.write(second.output);

      expect(decoder.pendingCodeUnits, 0);
      expect(second.insertMode, isFalse);
      expect(second.output, '\x1b[4h\x1b[@Z\x1b[4lQ');
      expect(terminal.lines[0].getText(0, 7), 'abcZQef');
    });

    test('accumulates fragmented multi-megabyte APC only once', () {
      final body = 'QUJDREVGR0g=' * 350000;
      final apc = '\x1b_Gf=100,a=T;$body\x1b\\';
      for (final sliceSize in [1023, 65536]) {
        final decoder = TerminalXtermOutputDecoder();
        // Leave the final backslash for a separate call to split ST.
        for (var offset = 0; offset < apc.length - 1; offset += sliceSize) {
          final end = (offset + sliceSize).clamp(0, apc.length - 1);
          expect(
            decoder.add(input: apc.substring(offset, end)).output,
            isEmpty,
          );
          expect(decoder.pendingCodeUnits, end);
          expect(decoder.materializedSequenceCodeUnits, 0);
        }
        expect(decoder.add(input: r'\').output, apc);
        expect(decoder.pendingCodeUnits, 0);
        expect(decoder.materializedSequenceCodeUnits, apc.length);
      }
    });

    test('retains a surrogate split across input chunks', () {
      final decoder = TerminalXtermOutputDecoder();
      expect(decoder.add(input: '\x1b[4h\uD83D').output, '\x1b[4h');
      expect(decoder.pendingCodeUnits, 1);
      expect(decoder.add(input: '\uDC4DZ').output, '\x1b[@\x1b[@👍\x1b[@Z');
      expect(decoder.pendingCodeUnits, 0);
    });

    test(
      'a multi-chunk image survives the adapt+xterm pipeline without leaking '
      'base64 as text',
      () {
        // Split both Kitty continuation APC payloads and their terminators.
        final rgba = base64.encode(
          Uint8List.fromList(
            List<int>.generate(40 * 40 * 4, (i) => (i * 37 + 11) & 0xFF),
          ),
        );
        final chunks = <String>[];
        for (var offset = 0; offset < rgba.length; offset += 4096) {
          final end = offset + 4096 > rgba.length ? rgba.length : offset + 4096;
          final isLast = end >= rgba.length;
          final more = isLast ? '0' : '1';
          if (offset == 0) {
            chunks.add(
              '\x1b_Ga=t,i=93,f=32,s=40,v=40,m=$more;'
              '${rgba.substring(offset, end)}\x1b\\',
            );
          } else {
            chunks.add('\x1b_Gm=$more;${rgba.substring(offset, end)}\x1b\\');
          }
        }
        final stream = 'BEGIN${chunks.join()}END';
        expect(chunks.length, greaterThan(1), reason: 'must be multi-chunk');

        for (final sliceSize in <int>[1, 13, 200, 4096]) {
          final terminal = Terminal(maxLines: 100);
          final decoder = TerminalXtermOutputDecoder();
          for (var offset = 0; offset < stream.length; offset += sliceSize) {
            final end = offset + sliceSize > stream.length
                ? stream.length
                : offset + sliceSize;
            final result = decoder.add(input: stream.substring(offset, end));
            terminal.write(result.output);
          }

          expect(
            decoder.pendingCodeUnits,
            0,
            reason: 'slice $sliceSize left a partial',
          );
          expect(
            terminal.buffer.getText().replaceAll('\n', ''),
            'BEGINEND',
            reason: 'slice $sliceSize leaked image payload into the buffer',
          );
          expect(
            terminal.heldImageSignatures().keys,
            <int>[93],
            reason: 'slice $sliceSize must reassemble exactly one image',
          );
        }
      },
    );

    for (final (name, input, output) in [
      (
        'OSC payload',
        '\x1b[4h\x1b]0;nano title\x07Z',
        '\x1b[4h\x1b]0;nano title\x07\x1b[@Z',
      ),
      (
        'emoji modifier',
        '\x1b[4h\u{1F44D}\u{1F3FD}Z',
        '\x1b[4h\x1b[@\x1b[@\u{1F44D}\u{1F3FD}\x1b[@Z',
      ),
    ]) {
      test('insert mode preserves $name', () {
        final decoder = TerminalXtermOutputDecoder();
        final result = decoder.add(input: input);
        expect(decoder.pendingCodeUnits, 0);
        expect(result.insertMode, isTrue);
        expect(result.output, output);
      });
    }

    test('strips private CSI modifier controls that xterm treats as SGR', () {
      final decoder = TerminalXtermOutputDecoder();
      final first = decoder.add(input: 'before\x1b[>4;');
      expect(decoder.pendingCodeUnits, '\x1b[>4;'.length);
      final second = decoder.add(input: '1mafter');

      expect(first.output, 'before');
      expect(second.output, 'after');
      expect(decoder.pendingCodeUnits, 0);
      expect(second.insertMode, isFalse);
    });

    test('clears tracked insert mode on terminal reset sequences', () {
      final decoder = TerminalXtermOutputDecoder();
      for (final reset in ['\x1bc', '\x1b[!p']) {
        final result = decoder.add(input: '\x1b[4hA${reset}B');
        expect(decoder.pendingCodeUnits, 0);
        expect(result.insertMode, isFalse);
        expect(result.output, '\x1b[4h\x1b[@A${reset}B');
      }
    });

    test('does not inject insert blanks into DCS payloads', () {
      final decoder = TerminalXtermOutputDecoder();
      final first = decoder.add(input: '\x1b[4h\x1bP1+r');

      expect(decoder.pendingCodeUnits, '\x1bP1+r'.length);
      final second = decoder.add(input: 'abc\x1b\\Z');

      expect(first.output, '\x1b[4h');
      expect(first.insertMode, isTrue);
      expect(decoder.pendingCodeUnits, 0);
      expect(second.insertMode, isTrue);
      expect(second.output, '\x1bP1+rabc\x1b\\\x1b[@Z');
    });

    test(
      'adapts reverse index at top margin to keep xterm buffer attached',
      () {
        final terminal = Terminal(maxLines: 100)..resize(61, 37);
        final reverseIndexes = List.filled(9, '\x1bM').join();
        final insertLines = List.filled(9, '\x1b[L').join();
        final decoder = TerminalXtermOutputDecoder();
        final result = decoder.add(
          input: '\x1b[1;37r\x1b[1;1H$reverseIndexes',

          terminalColumns: terminal.viewWidth,
          terminalRows: terminal.viewHeight,
          cursorColumn: terminal.buffer.cursorX,
          cursorRow: terminal.buffer.cursorY,
          marginTop: terminal.buffer.marginTop,
          marginBottom: terminal.buffer.marginBottom,
        );

        terminal.write(result.output);

        expect(decoder.pendingCodeUnits, 0);
        expect(result.insertMode, isFalse);
        expect(result.output, '\x1b[1;37r\x1b[1;1H$insertLines');
        expect(
          List.generate(
            terminal.buffer.height,
            (index) => terminal.buffer.lines[index].attached,
          ),
          everyElement(isTrue),
        );
      },
    );

    test('preserves reverse index when cursor is below the top margin', () {
      final decoder = TerminalXtermOutputDecoder();
      final result = decoder.add(
        input: '\x1b[5;4H\x1bM',

        terminalColumns: 61,
        terminalRows: 37,
        cursorColumn: 0,
        cursorRow: 0,
        marginTop: 0,
        marginBottom: 36,
      );

      expect(result.output, '\x1b[5;4H\x1bM');
    });

    test('restores cursor column after adapted reverse index', () {
      final decoder = TerminalXtermOutputDecoder();
      final result = decoder.add(
        input: '\x1b[1;4H\x1bM',

        terminalColumns: 61,
        terminalRows: 37,
        cursorColumn: 0,
        cursorRow: 0,
        marginTop: 0,
        marginBottom: 36,
      );

      expect(result.output, '\x1b[1;4H\x1b[L\x1b[4G');
    });

    test('adapts origin-mode reverse index at the top margin', () {
      final terminal = Terminal(maxLines: 100)..resize(61, 37);
      final decoder = TerminalXtermOutputDecoder();
      final result = decoder.add(
        input: '\x1b[2;10r\x1b[?6h\x1b[1;1H\x1bM',

        terminalColumns: terminal.viewWidth,
        terminalRows: terminal.viewHeight,
        cursorColumn: terminal.buffer.cursorX,
        cursorRow: terminal.buffer.cursorY,
        marginTop: terminal.buffer.marginTop,
        marginBottom: terminal.buffer.marginBottom,
        originMode: terminal.originMode,
      );

      terminal.write(result.output);

      expect(result.output, '\x1b[2;10r\x1b[?6h\x1b[1;1H\x1b[L');
      expect(
        List.generate(
          terminal.buffer.height,
          (index) => terminal.buffer.lines[index].attached,
        ),
        everyElement(isTrue),
      );
    });

    test('unwraps complete tmux passthrough sequences', () {
      final decoder = TerminalTmuxPassthroughDecoder();
      final result = decoder.add(
        'before\x1bPtmux;\x1b\x1b]11;?\x07\x1b\\after',
      );

      expect(result, 'before\x1b]11;?\x07after');
      expect(decoder.add(''), isEmpty);
    });

    test('unwraps ST-terminated tmux passthrough OSC sequences', () {
      final decoder = TerminalTmuxPassthroughDecoder();
      final result = decoder.add(
        'before\x1bPtmux;\x1b\x1b]11;?\x1b\x1b\\\x1b\\after',
      );

      expect(result, 'before\x1b]11;?\x1b\\after');
      expect(decoder.add(''), isEmpty);
    });

    test('preserves split tmux passthrough sequences across chunks', () {
      final decoder = TerminalTmuxPassthroughDecoder();
      final first = decoder.add('before\x1bPtmux;\x1b');

      expect(first, 'before');
      expect(decoder.add(''), isEmpty);

      final second = decoder.add('\x1b[?1004\$p\x1b\\after');

      expect(second, '\x1b[?1004\$pafter');
      expect(decoder.add(''), isEmpty);
    });

    test('preserves split tmux passthrough sequence starts', () {
      final decoder = TerminalTmuxPassthroughDecoder();
      final first = decoder.add('before\x1bPtm');

      expect(first, 'before');
      expect(decoder.add(''), isEmpty);

      final second = decoder.add('ux;\x1b\x1b[14t\x1b\\after');

      expect(second, '\x1b[14tafter');
      expect(decoder.add(''), isEmpty);
    });

    test(
      'decodes a long fragmented passthrough without emitting a partial payload',
      () {
        final decoder = TerminalTmuxPassthroughDecoder();
        final chunk = 'x' * 4096;
        expect(decoder.add('before\x1bPtmux;'), 'before');
        for (var index = 0; index < 256; index++) {
          expect(decoder.add(chunk), isEmpty);
        }
        expect(decoder.add('\x1b'), isEmpty);
        expect(decoder.add(r'\after'), '${chunk * 256}after');
      },
    );

    test('preserves every split boundary and ordinary escape sequence', () {
      const input = 'plain\x1b[31m\x1bPtm\x1bPtmux;A\x1b\x1b\\B\x1bX\x1b\\tail';
      const expected = 'plain\x1b[31m\x1bPtmA\x1b\\B\x1bXtail';
      for (var split = 0; split <= input.length; split++) {
        final decoder = TerminalTmuxPassthroughDecoder();
        expect(
          decoder.add(input.substring(0, split)) +
              decoder.add(input.substring(split)),
          expected,
        );
      }
      final decoder = TerminalTmuxPassthroughDecoder();
      expect(input.split('').map(decoder.add).join(), expected);
    });

    test('reset discards partial prefixes, payloads and escape bytes', () {
      final decoder = TerminalTmuxPassthroughDecoder();
      for (final partial in [
        '\x1bPtm',
        '\x1bPtmux;discard',
        '\x1bPtmux;discard\x1b',
      ]) {
        expect(decoder.add(partial), isEmpty);
        decoder.reset();
        expect(decoder.add('fresh\x1bPtmux;ok\x1b\\'), 'freshok');
      }
    });

    test('answers terminal window and cell size reports', () {
      final result = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[14tmiddle\x1b[16tafter',
        pendingInput: '',
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(result.response, '\x1b[4;480;960t\x1b[6;20;12t');
      expect(result.pendingInput, isEmpty);
    });

    test('preserves split terminal size report queries across chunks', () {
      final first = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[1',
        pendingInput: '',
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(first.response, isNull);
      expect(first.pendingInput, '\x1b[1');

      final second = buildTerminalWindowControlQueryResponses(
        input: '6tafter',
        pendingInput: first.pendingInput,
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(second.response, '\x1b[6;20;12t');
      expect(second.pendingInput, isEmpty);
    });

    test('answers terminal theme mode report queries', () {
      final dark = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?996nafter',
        pendingInput: '',
        metrics: null,
        theme: monkey_themes.TerminalThemes.defaultDarkTheme,
      );

      expect(dark.response, '\x1b[?997;1n');
      expect(dark.pendingInput, isEmpty);

      final light = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?996nafter',
        pendingInput: '',
        metrics: null,
        theme: monkey_themes.TerminalThemes.defaultLightTheme,
      );

      expect(light.response, '\x1b[?997;2n');
      expect(light.pendingInput, isEmpty);
    });

    test('answers DEC private mode report queries', () {
      final result = buildTerminalWindowControlQueryResponses(
        input:
            'before\x1b[?1004\$p\x1b[?2004\$p\x1b[?1006\$p'
            '\x1b[?2026\$pafter',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: true,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: true,
        ),
      );

      expect(
        result.response,
        '\x1b[?1004;1\$y'
        '\x1b[?2004;2\$y'
        '\x1b[?1006;1\$y'
        '\x1b[?2026;0\$y',
      );
      expect(result.pendingInput, isEmpty);

      final colorSchemeReset = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?2031\$pafter',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: false,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(colorSchemeReset.response, '\x1b[?2031;2\$y');
    });

    test('preserves split DEC private mode report queries across chunks', () {
      final first = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?1004\$',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(first.response, isNull);
      expect(first.pendingInput, '\x1b[?1004\$');

      final second = buildTerminalWindowControlQueryResponses(
        input: 'pafter',
        pendingInput: first.pendingInput,
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(second.response, '\x1b[?1004;1\$y');
      expect(second.pendingInput, isEmpty);
    });

    test('extracts color scheme update mode changes', () {
      final enabled = extractTerminalControlModeUpdates(
        input: 'before\x1b[?2031hafter',
        pendingInput: '',
      );

      expect(enabled.colorSchemeUpdatesMode, isTrue);
      expect(enabled.pendingInput, isEmpty);

      final first = extractTerminalControlModeUpdates(
        input: 'before\x1b[?203',
        pendingInput: '',
      );

      expect(first.colorSchemeUpdatesMode, isNull);
      expect(first.pendingInput, '\x1b[?203');

      final disabled = extractTerminalControlModeUpdates(
        input: '1lafter',
        pendingInput: first.pendingInput,
      );

      expect(disabled.colorSchemeUpdatesMode, isFalse);
      expect(disabled.pendingInput, isEmpty);
    });

    test('extracts win32-input-mode changes', () {
      final enabled = extractTerminalControlModeUpdates(
        input: 'before\x1b[?9001hafter',
        pendingInput: '',
      );

      expect(enabled.win32InputMode, isTrue);
      expect(enabled.colorSchemeUpdatesMode, isNull);
      expect(enabled.pendingInput, isEmpty);

      final first = extractTerminalControlModeUpdates(
        input: 'before\x1b[?900',
        pendingInput: '',
      );

      expect(first.win32InputMode, isNull);
      expect(first.pendingInput, '\x1b[?900');

      final disabled = extractTerminalControlModeUpdates(
        input: '1lafter',
        pendingInput: first.pendingInput,
      );

      expect(disabled.win32InputMode, isFalse);
      expect(disabled.pendingInput, isEmpty);
    });

    test('encodes OSC responses as win32-input-mode key events', () {
      const response = '\x1b]11;rgb:ffff/ffff/ffff\x1b\\';

      final encoded = encodeTerminalResponsesForWin32InputMode(response);

      expect(
        encoded,
        response.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join(),
      );
    });

    test('encodes BEL-terminated OSC and DCS responses', () {
      const osc = '\x1b]11;rgb:0000/0000/0000\x07';
      const dcs = '\x1bP>|MonkeySSH\x1b\\';

      expect(
        encodeTerminalResponsesForWin32InputMode(osc),
        osc.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join(),
      );
      expect(
        encodeTerminalResponsesForWin32InputMode(dcs),
        dcs.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join(),
      );
    });

    test(
      'leaves plain text and CSI responses unchanged for win32 input mode',
      () {
        const data = 'hello\x1b[?997;2n\x1b[5;7R';

        expect(encodeTerminalResponsesForWin32InputMode(data), data);
      },
    );

    test('encodes only embedded OSC sequences within mixed output', () {
      const osc = '\x1b]10;rgb:1111/2222/3333\x1b\\';
      const data = 'a\x1b[1m$osc\x1b[?1004h';

      expect(
        encodeTerminalResponsesForWin32InputMode(data),
        'a\x1b[1m'
        '${osc.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join()}'
        '\x1b[?1004h',
      );
    });

    test('encodes a standalone Escape keystroke as win32 key events', () {
      expect(
        encodeTerminalInputForWin32InputMode('\x1b'),
        '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_',
      );
    });

    test('leaves unambiguous escape sequences and text unchanged', () {
      // Arrow keys, Alt+key, query replies and typed text already survive
      // ConPTY's input parser; only a bare ESC is ambiguous.
      for (final data in const [
        '',
        '\x1b[A',
        '\x1b[1;5C',
        '\x1bb',
        '\x1b\x1b',
        '\x1b[5;7R',
        '\x03',
        'esc',
      ]) {
        expect(encodeTerminalInputForWin32InputMode(data), data);
      }
    });

    test(
      'preserves split terminal theme mode report queries across chunks',
      () {
        final first = buildTerminalWindowControlQueryResponses(
          input: 'before\x1b[?99',
          pendingInput: '',
          metrics: null,
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
        );

        expect(first.response, isNull);
        expect(first.pendingInput, '\x1b[?99');

        final second = buildTerminalWindowControlQueryResponses(
          input: '6nafter',
          pendingInput: first.pendingInput,
          metrics: null,
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
        );

        expect(second.response, '\x1b[?997;2n');
        expect(second.pendingInput, isEmpty);
      },
    );
  });

  group('host key capture', () {
    test(
      'captures host key bytes from fragmented SSH identification and kex packets',
      () async {
        final expectedHostKey = _ed25519HostKeyBlob([1, 2, 3, 4]);
        final kexReplyPacket = _sshBinaryPacket(
          _sshMessageWithHostKey(31, expectedHostKey),
        );

        await expectLater(
          captureHostKeyFromHandshakeChunksForTesting(<Uint8List>[
            Uint8List.fromList(utf8.encode('SSH-2.0-test-server\r')),
            Uint8List.fromList(utf8.encode('\n')),
            Uint8List.sublistView(kexReplyPacket, 0, 3),
            Uint8List.sublistView(kexReplyPacket, 3, 9),
            Uint8List.sublistView(kexReplyPacket, 9),
          ]),
          completion(expectedHostKey),
        );
      },
    );

    test(
      'fails host key capture when the handshake packet is too large',
      () async {
        await expectLater(
          captureHostKeyFromHandshakeChunksForTesting(<Uint8List>[
            Uint8List.fromList(utf8.encode('SSH-2.0-test-server\r\n')),
            _oversizedPacketHeader(),
          ]),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              contains('host-key capture limit'),
            ),
          ),
        );
      },
    );
  });

  group('SshConnectionConfig', () {
    test('creates with required fields', () {
      const config = SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      );

      expect(config.hostname, 'example.com');
      expect(config.port, 22);
      expect(config.username, 'user');
      expect(config.password, isNull);
      expect(config.privateKey, isNull);
      expect(config.passphrase, isNull);
      expect(config.identityKeys, isNull);
      expect(config.jumpHost, isNull);
      expect(config.keepAliveInterval, const Duration(seconds: 30));
      expect(config.connectionTimeout, const Duration(seconds: 30));
    });

    test('creates with all fields', () {
      const jumpConfig = SshConnectionConfig(
        hostname: 'jump.example.com',
        port: 2222,
        username: 'jumpuser',
      );
      const config = SshConnectionConfig(
        hostname: 'target.example.com',
        port: 22,
        username: 'user',
        password: 'pass123',
        privateKey: '-----BEGIN KEY-----',
        passphrase: 'secret',
        jumpHost: jumpConfig,
        keepAliveInterval: Duration(seconds: 60),
        connectionTimeout: Duration(seconds: 15),
      );

      expect(config.hostname, 'target.example.com');
      expect(config.port, 22);
      expect(config.username, 'user');
      expect(config.password, 'pass123');
      expect(config.privateKey, '-----BEGIN KEY-----');
      expect(config.passphrase, 'secret');
      expect(config.identityKeys, isNull);
      expect(config.jumpHost, isNotNull);
      expect(config.jumpHost!.hostname, 'jump.example.com');
      expect(config.jumpHost!.port, 2222);
      expect(config.jumpHost!.username, 'jumpuser');
      expect(config.keepAliveInterval, const Duration(seconds: 60));
      expect(config.connectionTimeout, const Duration(seconds: 15));
    });

    group('fromHost', () {
      late AppDatabase db;

      setUp(() {
        db = AppDatabase.forTesting(NativeDatabase.memory());
      });

      tearDown(() async {
        await db.close();
      });

      test('creates config from host without key', () async {
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Test Host',
                hostname: '10.0.0.1',
                username: 'root',
                port: const Value(2222),
                password: const Value('pass'),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        final config = SshConnectionConfig.fromHost(host);

        expect(config.hostname, '10.0.0.1');
        expect(config.port, 2222);
        expect(config.username, 'root');
        expect(config.password, 'pass');
        expect(config.privateKey, isNull);
        expect(config.identityKeys, isNull);
        expect(config.jumpHost, isNull);
      });

      test('creates config from host with key', () async {
        final keyId = await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Test Key',
                keyType: 'ed25519',
                publicKey: 'ssh-ed25519 AAAA...',
                privateKey:
                    'test-open-ssh-key-material\ntest\ntest-open-ssh-key-material-end',
                passphrase: const Value('keypass'),
              ),
            );
        final key = await (db.select(
          db.sshKeys,
        )..where((t) => t.id.equals(keyId))).getSingle();
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Key Host',
                hostname: '10.0.0.2',
                username: 'admin',
                keyId: Value(keyId),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        final config = SshConnectionConfig.fromHost(host, key: key);

        expect(config.hostname, '10.0.0.2');
        expect(config.username, 'admin');
        expect(config.privateKey, contains('test-open-ssh-key-material'));
        expect(config.passphrase, 'keypass');
        expect(config.identityKeys, isNull);
      });

      test('creates config with jump host', () async {
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.3',
                username: 'deploy',
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        const jumpConfig = SshConnectionConfig(
          hostname: 'bastion.example.com',
          port: 22,
          username: 'jumpuser',
        );

        final config = SshConnectionConfig.fromHost(
          host,
          jumpHostConfig: jumpConfig,
        );

        expect(config.hostname, '10.0.0.3');
        expect(config.identityKeys, isNull);
        expect(config.jumpHost, isNotNull);
        expect(config.jumpHost!.hostname, 'bastion.example.com');
      });
    });
  });

  group('SshConnectionResult', () {
    test('creates success result', () {
      const result = SshConnectionResult(success: true);

      expect(result.success, isTrue);
      expect(result.error, isNull);
      expect(result.client, isNull);
    });

    test('creates failure result with error', () {
      const result = SshConnectionResult(
        success: false,
        error: 'Connection refused',
      );

      expect(result.success, isFalse);
      expect(result.error, 'Connection refused');
      expect(result.client, isNull);
    });
  });

  group('ActiveTunnelInfo', () {
    test('creates with required fields', () {
      const info = ActiveTunnelInfo(
        portForwardId: 1,
        localHost: '127.0.0.1',
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        isLocal: true,
      );

      expect(info.portForwardId, 1);
      expect(info.localHost, '127.0.0.1');
      expect(info.localPort, 3306);
      expect(info.browserHost, isNull);
      expect(info.browserPort, isNull);
      expect(info.remoteHost, 'db.internal');
      expect(info.remotePort, 3306);
      expect(info.isLocal, isTrue);
    });

    test('supports remote forward info', () {
      const info = ActiveTunnelInfo(
        portForwardId: 2,
        localHost: 'localhost',
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: false,
      );

      expect(info.isLocal, isFalse);
    });
  });

  group('SshSession terminal previews', () {
    tearDown(resetQueuedSshExecsForTesting);

    test('notifies preview listeners when the terminal theme changes', () {
      final session = _testSession(
        _MockSshClient(),
        hostId: 2,
        hostname: 'example.com',
      );
      var notificationCount = 0;

      session
        ..addPreviewListener(() => notificationCount++)
        ..terminalTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        ..terminalTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        ..terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme
        ..terminalTheme = null;

      expect(notificationCount, 3);
    });

    test('forwards execute requests with an optional PTY config', () async {
      final client = _MockSshClient();
      final execSession = _MockExecSession();
      final session = _testSession(client, hostId: 2, hostname: 'example.com');

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      final result = await session.execute(
        'tmux -CC attach-session -t test',
        pty: const SSHPtyConfig(width: 120, height: 30),
      );

      expect(result, same(execSession));
      verify(
        () => client.execute(
          'tmux -CC attach-session -t test',
          pty: const SSHPtyConfig(width: 120, height: 30),
        ),
      ).called(1);
    });

    test('opens interactive shells with a truecolor login bootstrap', () async {
      final client = _MockSshClient();
      final shell = _MockExecSession();
      final session = _testSession(client, hostId: 2, hostname: 'example.com');
      const pty = SSHPtyConfig(width: 120, height: 30);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
      when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
      when(() => shell.done).thenAnswer((_) => Future<void>.value());

      final result = await session.getShell(pty: pty);

      expect(result, same(shell));
      verify(
        () => client.execute(_expectedLoginShellCommand(session), pty: pty),
      ).called(1);
      verifyNever(() => client.shell(pty: any(named: 'pty')));
      await session.closeShell(waitForStreams: false);
    });

    test('opens commands without an outer PTY when requested', () async {
      final client = _MockSshClient();
      final shell = _MockExecSession();
      final session = _testSession(client, hostId: 2, hostname: 'example.com');
      const pty = SSHPtyConfig(width: 120, height: 30);

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
      when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
      when(() => shell.done).thenAnswer((_) => Completer<void>().future);

      final result = await session.getShell(
        pty: pty,
        requestPty: false,
        command: 'monkeymux attach test',
      );

      expect(result, same(shell));
      verify(
        () => client.execute(
          _expectedMarkedCommand(session, 'monkeymux attach test'),
        ),
      ).called(1);

      session.resizeShell(80, 24, 0, 0);
      verifyNever(() => shell.resizeTerminal(any(), any(), any(), any()));
      await session.closeShell(waitForStreams: false);
    });

    test(
      'emits shell done when a completed startup command has no login fallback',
      () async {
        final client = _MockSshClient();
        final shell = _MockExecSession();
        final shellDone = Completer<void>();
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => shell);
        when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
        when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => shell.done).thenAnswer((_) => shellDone.future);
        when(shell.close).thenAnswer((_) {});

        await session.getShell(
          requestPty: false,
          command: 'monkeymux attach work',
        );
        final emittedShellDone = session.shellDoneStream.first;

        shellDone.complete();

        await emittedShellDone;
        verify(
          () => client.execute(
            _expectedMarkedCommand(session, 'monkeymux attach work'),
          ),
        ).called(1);
        verifyNever(
          () => client.execute(
            _expectedLoginShellCommand(session),
            pty: any(named: 'pty'),
          ),
        );
        await session.closeShell(waitForStreams: false);
      },
    );

    test(
      'gates Kitty graphics by the actual Windows channel transport',
      () async {
        final client = _MockSshClient();
        final shell = _MockExecSession();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => shell);
        when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
        when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => shell.done).thenAnswer((_) => Completer<void>().future);
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );

        final terminal = session.getOrCreateTerminal();
        expect(terminal.kittyGraphicsEnabled, isFalse);

        await session.getShell(
          requestPty: false,
          command: 'monkeymux attach test',
        );
        expect(terminal.kittyGraphicsEnabled, isTrue);

        await session.closeShell(waitForStreams: false);
        expect(terminal.kittyGraphicsEnabled, isFalse);
      },
    );

    test(
      'returns completed startup commands to a login shell without disconnecting',
      () async {
        final client = _MockSshClient();
        final startupShell = _MockExecSession();
        final loginShell = _MockExecSession();
        final startupStdout = StreamController<Uint8List>();
        final loginStdout = StreamController<Uint8List>();
        final startupDone = Completer<void>();
        final loginDone = Completer<void>();
        final loginOpen = Completer<SSHSession>();
        final executedCommands = <String>[];
        final startupWrites = <List<int>>[];
        final loginWrites = <List<int>>[];
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );
        const pty = SSHPtyConfig(width: 120, height: 30);

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) {
          executedCommands.add(invocation.positionalArguments.single as String);
          return executedCommands.length == 1
              ? Future.value(startupShell)
              : loginOpen.future;
        });
        when(() => startupShell.stdout).thenAnswer((_) => startupStdout.stream);
        when(() => startupShell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => startupShell.done).thenAnswer((_) => startupDone.future);
        when(() => startupShell.write(any())).thenAnswer((invocation) {
          startupWrites.add(
            List<int>.from(invocation.positionalArguments.single as List<int>),
          );
        });
        when(startupShell.close).thenAnswer((_) {});
        when(() => loginShell.stdout).thenAnswer((_) => loginStdout.stream);
        when(() => loginShell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => loginShell.done).thenAnswer((_) => loginDone.future);
        when(() => loginShell.write(any())).thenAnswer((invocation) {
          loginWrites.add(
            List<int>.from(invocation.positionalArguments.single as List<int>),
          );
        });
        when(loginShell.close).thenAnswer((_) {});

        addTearDown(() async {
          await session.closeShell(waitForStreams: false);
          await startupStdout.close();
          await loginStdout.close();
          if (!startupDone.isCompleted) {
            startupDone.complete();
          }
          if (!loginDone.isCompleted) {
            loginDone.complete();
          }
        });

        final openedShell = await session.getShell(
          pty: pty,
          command: 'monkeymux attach work',
          returnToLoginShell: true,
        );
        expect(openedShell, same(startupShell));
        final shellDoneEvents = <void>[];
        final shellDoneSubscription = session.shellDoneStream.listen(
          shellDoneEvents.add,
        );
        addTearDown(shellDoneSubscription.cancel);
        var commandCompletedCount = 0;
        final commandCompletedSubscription = session.shellCommandCompletedStream
            .listen((_) => commandCompletedCount += 1);
        addTearDown(commandCompletedSubscription.cancel);

        startupStdout.add(Uint8List.fromList(utf8.encode('\x1b[?9001h')));
        await pumpEventQueue();
        session.debugFlushPendingTerminalOutput();
        startupDone.complete();
        await untilCalled(
          () => client.execute(
            any(that: contains('COLORTERM=truecolor')),
            pty: pty,
          ),
        );
        session.writeToShell('queued input');
        loginOpen.complete(loginShell);
        final replacementShell = await session.getShell();

        expect(replacementShell, same(loginShell));
        expect(commandCompletedCount, 1);
        expect(shellDoneEvents, isEmpty);
        expect(startupWrites, isEmpty);
        expect(loginWrites.map(utf8.decode), contains('queued input'));
        expect(executedCommands, [
          _expectedMarkedCommand(session, 'monkeymux attach work'),
          _expectedLoginShellCommand(session),
        ]);
        session.writeToShell('live input');
        expect(loginWrites.map(utf8.decode), contains('live input'));

        final loginOutput = Completer<String>();
        final stdoutSubscription = session.shellStdoutStream.listen(
          loginOutput.complete,
        );
        addTearDown(stdoutSubscription.cancel);
        loginStdout.add(Uint8List.fromList(utf8.encode('login prompt')));
        await pumpEventQueue();
        session.debugFlushPendingTerminalOutput();
        expect(await loginOutput.future, 'login prompt');

        loginDone.complete();
        await pumpEventQueue();
        expect(shellDoneEvents, hasLength(1));
      },
    );

    test(
      'falls back to shell request when truecolor bootstrap is rejected',
      () async {
        final client = _MockSshClient();
        final shell = _MockExecSession();
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );
        const pty = SSHPtyConfig(width: 120, height: 30);

        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenThrow(SSHChannelRequestError('exec request rejected'));
        when(
          () => client.shell(pty: any(named: 'pty')),
        ).thenAnswer((_) async => shell);
        when(() => shell.stdout).thenAnswer((_) => const Stream.empty());
        when(() => shell.stderr).thenAnswer((_) => const Stream.empty());
        when(() => shell.done).thenAnswer((_) => Future<void>.value());

        final result = await session.getShell(pty: pty);

        expect(result, same(shell));
        verify(
          () => client.execute(_expectedLoginShellCommand(session), pty: pty),
        ).called(1);
        verify(() => client.shell(pty: pty)).called(1);
        await session.closeShell(waitForStreams: false);
      },
    );

    test('requests terminal capability env on Windows remotes', () async {
      final client = _MockSshClient();
      final shell = _MockExecSession();
      final session = _testSession(client, hostId: 2, hostname: 'example.com');
      const pty = SSHPtyConfig(width: 120, height: 30);
      final terminalCapabilityEnvironment = {
        'COLORTERM': 'truecolor',
        'TERM_PROGRAM': 'kitty',
        'KITTY_WINDOW_ID': '1',
        'FORCE_HYPERLINK': '1',
        'MONKEYSSH_SHELL_TOKEN': session.shellLineageToken,
      };

      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      when(
        () => client.shell(
          pty: any(named: 'pty'),
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => shell);
      _stubSessionStreams(shell);

      expect(session.remoteIsWindows, isTrue);

      final result = await session.getShell(pty: pty);

      expect(result, same(shell));
      final capturedShellArgs = verify(
        () => client.shell(
          pty: captureAny(named: 'pty'),
          environment: captureAny(named: 'environment'),
        ),
      ).captured;
      expect(capturedShellArgs, [pty, terminalCapabilityEnvironment]);
      verifyNever(() => client.execute(any(), pty: any(named: 'pty')));
      await session.closeShell(waitForStreams: false);
    });

    test(
      'falls back to a cmd capability prefix when Windows env is rejected',
      () async {
        final client = _MockSshClient();
        final detection = _MockExecSession();
        final shell = _MockExecSession();
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );
        const pty = SSHPtyConfig(width: 120, height: 30);

        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        when(
          () => client.shell(
            pty: any(named: 'pty'),
            environment: any(named: 'environment'),
          ),
        ).thenThrow(SSHChannelRequestError('env rejected'));
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          if (invocation.namedArguments[#pty] == null) {
            return detection;
          }
          return shell;
        });
        _stubSessionStreams(detection, stdout: 'cmd');
        _stubSessionStreams(shell);

        final result = await session.getShell(pty: pty);

        expect(result, same(shell));
        final commands = verify(
          () => client.execute(captureAny(), pty: any(named: 'pty')),
        ).captured.cast<String>();
        expect(
          commands.last,
          'cmd.exe /d /k "set COLORTERM=truecolor&& '
          'set TERM_PROGRAM=kitty&& '
          'set KITTY_WINDOW_ID=1&& '
          'set FORCE_HYPERLINK=1&& '
          'set MONKEYSSH_SHELL_TOKEN=${session.shellLineageToken}"',
        );
        await session.closeShell(waitForStreams: false);
      },
    );

    test(
      'falls back to a PowerShell capability prefix for PowerShell remotes',
      () async {
        final client = _MockSshClient();
        final detection = _MockExecSession();
        final shell = _MockExecSession();
        final session = _testSession(
          client,
          hostId: 2,
          hostname: 'example.com',
        );
        const pty = SSHPtyConfig(width: 120, height: 30);

        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        when(
          () => client.shell(
            pty: any(named: 'pty'),
            environment: any(named: 'environment'),
          ),
        ).thenThrow(SSHChannelRequestError('env rejected'));
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          if (invocation.namedArguments[#pty] == null) {
            return detection;
          }
          return shell;
        });
        _stubSessionStreams(detection, stdout: 'powershell');
        _stubSessionStreams(shell);

        final result = await session.getShell(pty: pty);

        expect(result, same(shell));
        final commands = verify(
          () => client.execute(captureAny(), pty: any(named: 'pty')),
        ).captured.cast<String>();
        expect(
          commands.last,
          startsWith('powershell.exe -NoLogo -NoExit -EncodedCommand '),
        );
        expect(
          decodeEncodedPowerShell(commands.last),
          contains(
            r"$env:COLORTERM='truecolor';$env:TERM_PROGRAM='kitty';"
            r"$env:KITTY_WINDOW_ID='1';$env:FORCE_HYPERLINK='1';"
            "\$env:MONKEYSSH_SHELL_TOKEN='${session.shellLineageToken}'",
          ),
        );
        await session.closeShell(waitForStreams: false);
      },
    );

    test('retries transient SFTP channel open failures', () async {
      final client = _MockSshClient();
      final sftp = _MockSftpClient();
      final session = _testSession(
        client,
        connectionId: 11,
        hostId: 2,
        hostname: 'example.com',
      );
      var openAttempts = 0;

      when(client.sftp).thenAnswer((_) {
        openAttempts++;
        if (openAttempts == 1) {
          return Future<SftpClient>.error(
            SSHChannelOpenError(2, 'open failed'),
          );
        }
        return Future.value(sftp);
      });

      await expectLater(session.sftp(), completion(same(sftp)));
      expect(openAttempts, 2);
    });

    test('discarding SFTP consumes close errors after disconnect', () async {
      final client = _MockSshClient();
      final sftp = _MockSftpClient();
      final session = _testSession(
        client,
        connectionId: 11,
        hostId: 2,
        hostname: 'example.com',
      );

      when(client.sftp).thenAnswer((_) async => sftp);
      when(sftp.close).thenAnswer(
        (_) => Future<void>.error(SSHStateError('Transport is closed')),
      );

      final opened = await session.sftp();
      session.discardSftpClient(opened);
      await pumpEventQueue();

      verify(sftp.close).called(1);
    });

    test('does not retry non-transient SFTP channel open failures', () async {
      final client = _MockSshClient();
      final session = _testSession(
        client,
        connectionId: 11,
        hostId: 2,
        hostname: 'example.com',
      );
      var openAttempts = 0;

      when(client.sftp).thenAnswer((_) {
        openAttempts++;
        return Future<SftpClient>.error(
          SSHChannelOpenError(1, 'administratively prohibited'),
        );
      });

      await expectLater(session.sftp(), throwsA(isA<SSHChannelOpenError>()));
      expect(openAttempts, 1);
    });

    test('runs queued exec work against the session connection', () async {
      final client = _MockSshClient();
      final session = _testSession(
        client,
        connectionId: 9,
        hostId: 2,
        hostname: 'example.com',
      );
      final completers = List.generate(3, (_) => Completer<int>());
      final started = <int>[];
      final futures = [
        for (var index = 0; index < completers.length; index++)
          session.runQueuedExec(() {
            started.add(index);
            return completers[index].future;
          }),
      ];

      await pumpEventQueue();

      expect(started, [0, 1]);
      expect(activeQueuedSshExecCountForTesting(9), 2);
      expect(pendingQueuedSshExecCountForTesting(9), 1);

      for (var index = 0; index < completers.length; index++) {
        completers[index].complete(index);
      }

      expect(await Future.wait(futures), [0, 1, 2]);
    });

    test('builds preview from the latest non-empty lines', () {
      final terminal = Terminal(maxLines: 100)
        ..write('first line\r\nsecond line\r\n\r\nthird line');

      final preview = SshSession.buildTerminalPreview(terminal, maxLines: 2);

      expect(preview, 'second line\nthird line');
    });

    test('builds extra preview lines by default', () {
      final terminal = Terminal(maxLines: 100)
        ..write(List.generate(19, (index) => 'line ${index + 1}').join('\r\n'));

      final preview = SshSession.buildTerminalPreview(terminal);

      expect(
        preview,
        List.generate(17, (index) => 'line ${index + 3}').join('\n'),
      );
    });

    test('preserves wrapped terminal display rows', () {
      final terminal = Terminal(maxLines: 100)
        ..resize(8, 10)
        ..write('alpha beta gamma delta epsilon');

      final preview = SshSession.buildTerminalPreview(terminal, maxLines: 3);

      expect(preview?.split('\n'), hasLength(3));
    });

    test('builds styled preview cell colors', () {
      final terminal = Terminal(maxLines: 100)
        ..write('\x1b[31mred\x1b[0m normal');

      final preview = SshSession.buildTerminalPreviewSnapshot(terminal);

      expect(preview, isNotNull);
      expect(preview!.plainText, contains('red normal'));
      expect(
        preview.lines.single.cells.getForeground(0) & CellColor.typeMask,
        CellColor.named,
      );
    });

    test('styled preview keeps a contiguous viewport slice', () {
      final terminal = Terminal(maxLines: 100)
        ..resize(80, 20)
        ..write('CLAUDE STALE HEADER')
        ..write('\x1b[15;1Hopencode')
        ..write('\x1b[16;1HAsk anything...')
        ..write('\x1b[17;1HBuild · Big Pickle');

      final preview = SshSession.buildTerminalPreviewSnapshot(
        terminal,
        maxLines: 6,
      );

      expect(preview, isNotNull);
      expect(preview!.plainText, contains('opencode'));
      expect(preview.plainText, contains('Build · Big Pickle'));
      expect(preview.plainText, isNot(contains('CLAUDE STALE HEADER')));
    });

    test('sanitizes control characters and truncates long previews', () {
      final terminal = Terminal(maxLines: 100)
        ..write('prompt> \u0007hello world\r\n')
        ..write(List<String>.filled(80, 'x').join());

      final preview = SshSession.buildTerminalPreview(terminal, maxChars: 40);

      expect(preview, isNotNull);
      expect(preview, isNot(contains('\u0007')));
      expect(preview, startsWith('…'));
      expect(preview, contains('xxxxxxxx'));
    });

    test('clamps invalid preview limits to safe minimums', () {
      final terminal = Terminal(maxLines: 100)..write('alpha\r\nbeta');

      expect(
        SshSession.buildTerminalPreview(terminal, maxLines: 0, maxChars: 4),
        'beta',
      );
      expect(SshSession.buildTerminalPreview(terminal, maxChars: 0), '…');
    });
  });

  group('SshSession terminal output batching', () {
    const monkeyMuxReplayMarker = '\x1b\\\x1b[?1000l\x1b[?1002l\x1b[?1003l';

    Future<
      ({
        Completer<void> done,
        _MockExecSession shell,
        SshSession session,
        StreamController<Uint8List> stderr,
        StreamController<Uint8List> stdout,
        List<List<int>> shellWrites,
      })
    >
    openShell() async {
      final client = _MockSshClient();
      final shell = _MockExecSession();
      final stdout = StreamController<Uint8List>();
      final stderr = StreamController<Uint8List>();
      final done = Completer<void>();
      final shellWrites = <List<int>>[];
      final session = _testSession(
        client,
        connectionId: 91,
        hostId: 2,
        hostname: 'example.com',
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => stdout.stream);
      when(() => shell.stderr).thenAnswer((_) => stderr.stream);
      when(() => shell.done).thenAnswer((_) => done.future);
      when(() => shell.write(any())).thenAnswer((invocation) {
        final bytes = invocation.positionalArguments.single as List<int>;
        shellWrites.add(List<int>.from(bytes));
      });

      await session.getShell();
      addTearDown(() async {
        await session.closeShell(waitForStreams: false);
        await stdout.close();
        await stderr.close();
        if (!done.isCompleted) {
          done.complete();
        }
      });
      return (
        done: done,
        shell: shell,
        session: session,
        stderr: stderr,
        stdout: stdout,
        shellWrites: shellWrites,
      );
    }

    String firstLineText(Terminal terminal) => terminal.buffer.lines[0]
        .getText(0, terminal.buffer.viewWidth)
        .trimRight();

    test('answers Kitty capabilities and iTerm2 cell-size reports', () async {
      final opened = await openShell();
      opened.session
        ..updateTerminalWindowMetrics(
          columns: 80,
          rows: 24,
          pixelWidth: 640,
          pixelHeight: 408,
        )
        ..debugHandlePrivateOsc('99', const ['i=query:p=?'])
        ..debugHandlePrivateOsc('1337', const ['ReportCellSize']);

      expect(
        utf8.decode(opened.shellWrites[0]),
        '\x1b]99;i=query:p=?;a=focus,report:o=always:p=title,body:'
        's=system,silent:u=0,1,2:w=1\x1b\\',
      );
      expect(
        utf8.decode(opened.shellWrites[1]),
        '\x1b]1337;ReportCellSize=17.00;8.00\x1b\\',
      );
    });

    test('applies mixed OSC 4 setters before answering queries', () async {
      final opened = await openShell();
      opened.session
        ..terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme
        ..debugHandlePrivateOsc('4', const ['1', '#123456', '1', '?']);

      expect(opened.session.terminalTheme?.red, const Color(0xFF123456));
      expect(
        utf8.decode(opened.shellWrites.single),
        '\x1b]4;1;rgb:1212/3434/5656\x1b\\',
      );
    });

    test(
      'tracks Kitty alive state and keeps activation separate from close',
      () async {
        final opened = await openShell();
        const request = TerminalNotificationRequest(
          body: 'Ready',
          identifier: 'build',
          reportsActivation: true,
          reportsClose: true,
        );

        opened.session
          ..markTerminalNotificationPresented(request)
          ..debugHandlePrivateOsc('99', const ['i=query:p=alive']);
        expect(
          utf8.decode(opened.shellWrites[0]),
          '\x1b]99;i=build:p=close;untracked\x1b\\',
        );
        expect(
          utf8.decode(opened.shellWrites[1]),
          '\x1b]99;i=query:p=alive;build\x1b\\',
        );

        opened.session
          ..handleTerminalNotificationActivated(
            'build',
            reportsActivation: true,
          )
          ..debugHandlePrivateOsc('99', const ['i=after:p=alive']);
        expect(utf8.decode(opened.shellWrites[2]), '\x1b]99;i=build;\x1b\\');
        expect(
          utf8.decode(opened.shellWrites[3]),
          '\x1b]99;i=after:p=alive;\x1b\\',
        );
      },
    );

    test(
      'shell reset clears active progress and notifies metadata once',
      () async {
        final shell = await openShell();
        final session = shell.session;
        var metadataChanges = 0;
        session
          ..addMetadataListener(() => metadataChanges += 1)
          ..debugHandlePrivateOsc('9', ['4', '1', '50']);
        expect(metadataChanges, 1);

        await session.closeShell(waitForStreams: false);

        expect(session.terminalProgress, isNull);
        expect(metadataChanges, 2);
      },
    );

    test('coalesces burst stdout into one terminal write per frame', () async {
      final shell = await openShell();
      // Hold coalesced output deterministically: with a long flush interval the
      // auto-flush timer cannot fire while we assert the burst is still
      // buffered, so this no longer races the 8ms production interval against a
      // slow `pumpEventQueue` on a loaded machine.
      final session = shell.session
        ..debugTerminalOutputFlushInterval = const Duration(minutes: 5);
      final terminal = session.terminal!;
      final stdoutEvents = <String>[];
      final stdoutSubscription = session.shellStdoutStream.listen(
        stdoutEvents.add,
      );
      addTearDown(stdoutSubscription.cancel);

      var terminalNotifications = 0;
      terminal.addListener(() => terminalNotifications += 1);

      shell.stdout
        ..add(Uint8List.fromList(utf8.encode('hello ')))
        ..add(Uint8List.fromList(utf8.encode('world')));
      await pumpEventQueue();

      // Both chunks are buffered but not yet written to the terminal.
      expect(firstLineText(terminal), isNot(contains('hello')));
      expect(stdoutEvents, isEmpty);
      expect(terminalNotifications, 0);

      // Flush deterministically instead of waiting on the real coalesce timer;
      // the burst must coalesce into a single terminal write and stdout event.
      session.debugFlushPendingTerminalOutput();
      await pumpEventQueue();

      expect(firstLineText(terminal), 'hello world');
      expect(stdoutEvents, ['hello world']);
      expect(terminalNotifications, 1);
    });

    test(
      'native viewport drops hidden terminal replay until restored',
      () async {
        final shell = await openShell();
        final session = shell.session
          ..debugTerminalOutputFlushInterval = const Duration(minutes: 5)
          ..setTerminalParsingPaused(paused: true);
        final terminal = session.terminal!;

        shell.stdout.add(
          Uint8List.fromList(utf8.encode('hidden terminal replay')),
        );
        await pumpEventQueue();
        session.debugFlushPendingTerminalOutput();
        await pumpEventQueue();
        expect(firstLineText(terminal), isEmpty);

        session.setTerminalParsingPaused(paused: false);
        shell.stdout.add(
          Uint8List.fromList(utf8.encode('visible after restore')),
        );
        await pumpEventQueue();
        session.debugFlushPendingTerminalOutput();
        await pumpEventQueue();

        expect(firstLineText(terminal), 'visible after restore');
      },
    );

    test('coalesces split MonkeyMux active-window replay chunks', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;
      final stdoutEvents = <String>[];
      final stdoutSubscription = session.shellStdoutStream.listen(
        stdoutEvents.add,
      );
      addTearDown(stdoutSubscription.cancel);

      var terminalNotifications = 0;
      terminal.addListener(() => terminalNotifications += 1);

      // Writing only a partial replay marker must start coalescing and hold the
      // output. pumpEventQueue drains the stream event without advancing real
      // time, so the 24ms coalesce timer cannot fire here (avoids racing a real
      // wall-clock delay against the quiet period on a loaded CI machine).
      shell.stdout.add(
        Uint8List.fromList(utf8.encode(monkeyMuxReplayMarker.substring(0, 12))),
      );
      await pumpEventQueue();

      expect(firstLineText(terminal), isEmpty);
      expect(stdoutEvents, isEmpty);
      expect(terminalNotifications, 0);

      shell.stdout
        ..add(
          Uint8List.fromList(utf8.encode(monkeyMuxReplayMarker.substring(12))),
        )
        ..add(Uint8List.fromList(utf8.encode('coalesced replay')));
      await pumpEventQueue();

      expect(firstLineText(terminal), isEmpty);
      expect(stdoutEvents, isEmpty);
      expect(terminalNotifications, 0);

      // Wait comfortably past the coalesce quiet period (24ms) so the buffered
      // chunks flush as a single coalesced write.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await pumpEventQueue();

      expect(firstLineText(terminal), 'coalesced replay');
      expect(stdoutEvents.join(), contains('coalesced replay'));
      expect(terminalNotifications, 1);
    });

    test('spreads a large active-window replay across frames instead of one '
        'blocking write', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;

      var terminalWrites = 0;
      terminal.addListener(() => terminalWrites += 1);

      // A Copilot window full of content replays far more than one frame's
      // parse budget at once. The adapt/parse/control-query pipeline must run
      // on bounded slices so no single synchronous turn blocks the UI thread.
      final builder = StringBuffer(monkeyMuxReplayMarker);
      for (var i = 0; i < 20000; i++) {
        builder.write('line $i is part of a very large replay payload\r\n');
      }
      const finalMarker = 'REPLAY_COMPLETE_20000';
      builder.write(finalMarker);
      final replay = builder.toString();
      expect(replay.length, greaterThan(512 * 1024));

      shell.stdout.add(Uint8List.fromList(utf8.encode(replay)));
      await pumpEventQueue();

      // Past the coalesce quiet period the replay is drained over several
      // bounded writes rather than one blocking call, but completes quickly.
      await _waitUntil(() {
        for (
          var row = terminal.buffer.height - terminal.viewHeight;
          row < terminal.buffer.height;
          row++
        ) {
          if (terminal.buffer.lines[row].getText().contains(finalMarker)) {
            return true;
          }
        }
        return false;
      });
      expect(terminalWrites, greaterThan(1));
      expect(firstLineText(terminal), startsWith('line '));
      expect(firstLineText(terminal), endsWith('large replay payload'));
    });

    test('flushes a continuously-streaming window within the coalesce '
        'deadline instead of starving', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;

      final sw = Stopwatch()..start();
      var firstChangeAtMs = -1;
      terminal.addListener(() {
        if (firstChangeAtMs < 0) {
          firstChangeAtMs = sw.elapsedMilliseconds;
        }
      });

      // Begin the active-window replay, then keep streaming chunks with gaps
      // shorter than the 24ms quiet period — exactly how a large image/content
      // replay arrives over the network. The debounce keeps resetting, so
      // without a hard deadline the content would never render until the whole
      // replay finishes downloading (the window stays blank). The max-hold must
      // flush it mid-stream so content appears promptly.
      shell.stdout.add(
        Uint8List.fromList(utf8.encode('${monkeyMuxReplayMarker}busy 0 ')),
      );
      for (var i = 1; i <= 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        shell.stdout.add(Uint8List.fromList(utf8.encode('busy $i ')));
        await pumpEventQueue();
      }

      // Streaming ran ~400ms; the batch must have flushed near the 64ms
      // deadline, well before output stopped.
      expect(firstChangeAtMs, greaterThanOrEqualTo(0));
      expect(firstChangeAtMs, lessThan(250));
      expect(firstLineText(terminal), startsWith('busy 0'));
    });

    test('flushes terminal theme OSC queries without frame delay', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;
      session.terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;

      shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b]11;?\x1b\\')));
      await pumpEventQueue();

      expect(firstLineText(terminal), isEmpty);
      expect(
        utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
        buildTerminalThemeOscResponse(
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
          code: '11',
          args: const ['?'],
        ),
      );
    });

    test(
      'win32-encodes theme OSC answers while ConPTY win32-input-mode is on',
      () async {
        final shell = await openShell();
        shell.session.terminalTheme =
            monkey_themes.TerminalThemes.defaultLightTheme;

        shell.stdout.add(
          Uint8List.fromList(utf8.encode('\x1b[?9001h\x1b]11;?\x1b\\')),
        );
        await pumpEventQueue();

        final response = buildTerminalThemeOscResponse(
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
          code: '11',
          args: const ['?'],
        )!;
        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          response.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join(),
        );
      },
    );

    test(
      'answers theme OSC queries raw again after win32-input-mode is reset',
      () async {
        final shell = await openShell();
        shell.session.terminalTheme =
            monkey_themes.TerminalThemes.defaultLightTheme;

        shell.stdout.add(
          Uint8List.fromList(
            utf8.encode('\x1b[?9001h\x1b[?9001l\x1b]11;?\x1b\\'),
          ),
        );
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          buildTerminalThemeOscResponse(
            theme: monkey_themes.TerminalThemes.defaultLightTheme,
            code: '11',
            args: const ['?'],
          ),
        );
      },
    );

    test('volunteers default color reports once per palette interrogation '
        'under win32-input-mode', () async {
      final shell = await openShell();
      final session = shell.session;
      const theme = monkey_themes.TerminalThemes.defaultLightTheme;
      session.terminalTheme = theme;

      // ConPTY forwards OSC 4 palette queries but consumes the OSC 10/11
      // default-color queries that TUIs send alongside them, so the app
      // must volunteer the defaults with the palette answers.
      shell.stdout.add(
        Uint8List.fromList(
          utf8.encode('\x1b[?9001h\x1b]4;0;?\x1b\\\x1b]4;1;?\x1b\\'),
        ),
      );
      await pumpEventQueue();

      String decodeWin32KeyEvents(String data) => data.replaceAllMapped(
        RegExp(r'\x1b\[0;0;(\d+);1;0;1_'),
        (match) => String.fromCharCode(int.parse(match.group(1)!)),
      );

      final written = decodeWin32KeyEvents(
        utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
      );
      final defaults = buildTerminalThemeDefaultColorReports(theme);
      expect(
        written,
        contains(
          buildTerminalThemeOscResponse(
            theme: theme,
            code: '4',
            args: const ['0', '?'],
          ),
        ),
      );
      expect(
        written,
        contains(
          buildTerminalThemeOscResponse(
            theme: theme,
            code: '4',
            args: const ['1', '?'],
          ),
        ),
      );
      expect(
        RegExp(RegExp.escape(defaults)).allMatches(written).length,
        1,
        reason: 'defaults volunteered once per interrogation burst',
      );
    });

    test(
      'does not volunteer default color reports without win32-input-mode',
      () async {
        final shell = await openShell();
        final session = shell.session;
        const theme = monkey_themes.TerminalThemes.defaultLightTheme;
        session.terminalTheme = theme;

        shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b]4;0;?\x1b\\')));
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          buildTerminalThemeOscResponse(
            theme: theme,
            code: '4',
            args: const ['0', '?'],
          ),
        );
      },
    );

    test(
      'win32-encodes synthetic OSC reports sent through terminal output',
      () async {
        final shell = await openShell();
        final session = shell.session;
        const theme = monkey_themes.TerminalThemes.defaultLightTheme;
        session.terminalTheme = theme;
        final terminal = session.terminal!;

        shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b[?9001h')));
        await pumpEventQueue();
        shell.shellWrites.clear();

        final report = buildTerminalThemeOscResponse(
          theme: theme,
          code: '11',
          args: const ['?'],
        )!;
        terminal.onOutput!.call('${report}typed');
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          '${report.codeUnits.map((unit) => '\x1b[0;0;$unit;1;0;1_').join()}'
          'typed',
        );
      },
    );

    test(
      'win32-encodes a bare Escape keystroke while ConPTY requested the mode',
      () async {
        final shell = await openShell();
        final terminal = shell.session.terminal!;

        shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b[?9001h')));
        await pumpEventQueue();
        shell.shellWrites.clear();

        terminal.keyInput(TerminalKey.escape);
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_',
        );
      },
    );

    test(
      'sends a bare Escape keystroke raw without win32-input-mode',
      () async {
        final shell = await openShell();
        final terminal = shell.session.terminal!;
        shell.shellWrites.clear();

        terminal.keyInput(TerminalKey.escape);
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          '\x1b',
        );
      },
    );

    test(
      'leaves Escape-prefixed sequences raw under win32-input-mode',
      () async {
        final shell = await openShell();
        final terminal = shell.session.terminal!;

        shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b[?9001h')));
        await pumpEventQueue();
        shell.shellWrites.clear();

        terminal.keyInput(TerminalKey.arrowUp);
        await pumpEventQueue();

        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          '\x1b[A',
        );
      },
    );

    test(
      'flushes tmux-wrapped terminal theme OSC queries without frame delay',
      () async {
        final shell = await openShell();
        final session = shell.session;
        final terminal = session.terminal!;
        session.terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;

        shell.stdout.add(
          Uint8List.fromList(
            utf8.encode('\x1bPtmux;\x1b\x1b]11;?\x1b\x1b\\\x1b\\'),
          ),
        );
        await pumpEventQueue();

        expect(firstLineText(terminal), isEmpty);
        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          buildTerminalThemeOscResponse(
            theme: monkey_themes.TerminalThemes.defaultLightTheme,
            code: '11',
            args: const ['?'],
          ),
        );
      },
    );

    test('flushes pending terminal output before shell done event', () async {
      final shell = await openShell();
      final done = shell.done;
      final session = shell.session;
      final terminal = session.terminal!;
      final lineWhenDone = Completer<String>();
      final doneSubscription = session.shellDoneStream.listen((_) {
        lineWhenDone.complete(firstLineText(terminal));
      });
      addTearDown(doneSubscription.cancel);

      shell.stdout.add(Uint8List.fromList(utf8.encode('final prompt')));
      done.complete();

      expect(await lineWhenDone.future, 'final prompt');
    });

    test(
      'tolerates malformed UTF-8 mid-chunk without dropping subsequent output',
      () async {
        final shell = await openShell();
        final session = shell.session;
        final terminal = session.terminal!;
        final stdoutEvents = <String>[];
        final stdoutErrors = <Object>[];
        final stdoutSubscription = session.shellStdoutStream.listen(
          stdoutEvents.add,
          onError: stdoutErrors.add,
        );
        addTearDown(stdoutSubscription.cancel);

        // Simulate a MonkeyMux replay history that was cut mid-character:
        // the chunk begins with the trailing continuation bytes of "│"
        // (U+2502, 0xE2 0x94 0x82) and is followed by a valid composer
        // border draw. A strict UTF-8 decoder would throw and drop the
        // entire chunk, leaving the border missing until the next resize.
        shell.stdout.add(
          Uint8List.fromList([0x94, 0x82, ...utf8.encode('border')]),
        );
        // Subsequent chunk should still be delivered even after the
        // malformed bytes above.
        shell.stdout.add(Uint8List.fromList(utf8.encode(' ok')));

        await Future<void>.delayed(const Duration(milliseconds: 25));

        expect(stdoutErrors, isEmpty);
        final joined = stdoutEvents.join();
        expect(joined, contains('border'));
        expect(joined, contains(' ok'));
        expect(firstLineText(terminal), contains('border'));
        expect(firstLineText(terminal), contains(' ok'));
      },
    );
  });

  group('ActiveSessionsNotifier', () {
    late ProviderContainer container;
    late _FakeActiveSessionsSshService fakeSshService;
    late _RecordingSessionTelemetry telemetry;
    late _DelayedTerminalNotificationService notificationService;
    late List<MethodCall> methodCalls;

    setUp(() {
      fakeSshService = _FakeActiveSessionsSshService();
      telemetry = _RecordingSessionTelemetry();
      notificationService = _DelayedTerminalNotificationService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      methodCalls = <MethodCall>[];
      BackgroundSshService.debugIsSupportedPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            methodCalls.add(call);
            return null;
          });
      container = ProviderContainer(
        overrides: [
          sshServiceProvider.overrideWithValue(fakeSshService),
          telemetryServiceProvider.overrideWithValue(telemetry),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
          localNotificationServiceProvider.overrideWithValue(
            notificationService,
          ),
          terminalNotificationsNotifierProvider.overrideWith(
            _EnabledTerminalNotificationsNotifier.new,
          ),
        ],
      );
    });

    tearDown(() async {
      BackgroundSshService.debugIsSupportedPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, null);
      container.dispose();
    });

    test(
      'reports host-key connection failures separately from authentication',
      () async {
        final sshService = _MockSshService();
        final telemetry = _MockTelemetryService();
        when(() => sshService.sessions).thenReturn({});
        when(
          () => sshService.connectToHost(
            any(),
            onProgress: any(named: 'onProgress'),
            useHostThemeOverrides: any(named: 'useHostThemeOverrides'),
            cancellationToken: any(named: 'cancellationToken'),
          ),
        ).thenAnswer(
          (_) async => const SshConnectionResult(
            success: false,
            error: 'Host key verification failed',
          ),
        );
        when(
          () => telemetry.logConnectionAttempted(
            authMethod: any(named: 'authMethod'),
            usesJumpHost: any(named: 'usesJumpHost'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => telemetry.logConnectionFailed(
            authMethod: any(named: 'authMethod'),
            usesJumpHost: any(named: 'usesJumpHost'),
            duration: any(named: 'duration'),
            failureCategory: any(named: 'failureCategory'),
          ),
        ).thenAnswer((_) async {});
        final failureContainer = ProviderContainer(
          overrides: [
            sshServiceProvider.overrideWithValue(sshService),
            telemetryServiceProvider.overrideWithValue(telemetry),
            hostRepositoryProvider.overrideWithValue(
              container.read(hostRepositoryProvider),
            ),
          ],
        );
        addTearDown(failureContainer.dispose);

        final result = await failureContainer
            .read(activeSessionsProvider.notifier)
            .connect(42);

        expect(result.success, isFalse);
        verify(
          () => telemetry.logConnectionFailed(
            authMethod: 'unknown',
            usesJumpHost: false,
            duration: any(named: 'duration'),
            failureCategory: 'host_key',
          ),
        ).called(1);
      },
    );

    for (final laterChange in [false, true]) {
      testWidgets(
        laterChange
            ? 'publishes a later preview change after a burst'
            : 'publishes a preview burst only once',
        (tester) async {
          final notifier = container.read(activeSessionsProvider.notifier);
          final result = await tester.runAsync(() async {
            final result = await notifier.connect(42);
            await pumpEventQueue();
            return result;
          });
          final session = notifier.getSession(result!.connectionId!)!;
          await tester.pump(const Duration(milliseconds: 300));
          var publications = 0;
          final subscription = container.listen(
            activeSessionsProvider,
            (_, _) => publications++,
          );
          addTearDown(subscription.close);

          session
            ..terminalTheme = monkey_themes.TerminalThemes.defaultDarkTheme
            ..terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;
          await tester.pump(const Duration(milliseconds: 150));
          expect(publications, 1);
          await tester.pump(const Duration(milliseconds: 150));
          expect(publications, 1);
          if (laterChange) {
            session.terminalTheme = null;
            await tester.pump(const Duration(milliseconds: 150));
            expect(publications, 2);
          }
        },
      );
    }

    test(
      'syncBackgroundStatus stops the background service when empty',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        await notifier.syncBackgroundStatus();

        expect(methodCalls, hasLength(1));
        expect(methodCalls.single.method, 'stopService');
      },
    );

    test('serializes terminal notification create before close', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final session = notifier.getSession(result.connectionId!)!;
      final notificationId = buildTerminalNotificationId(
        session.connectionId,
        identifier: 'kitty:ordered',
      );

      session.debugHandlePrivateOsc('99', const ['i=ordered', 'Started']);
      await notificationService.showStarted.future;
      session.debugHandlePrivateOsc('99', const ['i=ordered:p=close']);
      await pumpEventQueue();
      expect(notificationService.calls, ['show-start:$notificationId']);

      notificationService.releaseShow.complete();
      for (
        var attempt = 0;
        attempt < 20 && notificationService.calls.length < 3;
        attempt += 1
      ) {
        await pumpEventQueue();
      }
      expect(notificationService.calls, [
        'show-start:$notificationId',
        'show-finish:$notificationId',
        'clear:$notificationId',
      ]);
    });

    test(
      'coalesces superseded notification operations without reordering',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);
        final result = await notifier.connect(42, forceNew: true);
        final session = notifier.getSession(result.connectionId!)!;
        final gateId = buildTerminalNotificationId(
          session.connectionId,
          identifier: 'kitty:gate',
        );
        final otherId = buildTerminalNotificationId(
          session.connectionId,
          identifier: 'kitty:other',
        );
        final jobId = buildTerminalNotificationId(
          session.connectionId,
          identifier: 'kitty:job',
        );

        session.debugHandlePrivateOsc('99', const ['i=gate', 'Gate']);
        await notificationService.showStarted.future;
        session
          ..debugHandlePrivateOsc('99', const ['i=job', 'Started'])
          ..debugHandlePrivateOsc('99', const ['i=other', 'Other'])
          ..debugHandlePrivateOsc('99', const ['i=job', 'Updated'])
          ..debugHandlePrivateOsc('99', const ['i=job:p=close']);
        await pumpEventQueue();

        expect(
          notifier.debugTerminalNotificationQueueLength(session.connectionId),
          2,
        );
        notificationService.releaseShow.complete();
        for (
          var attempt = 0;
          attempt < 20 && notificationService.calls.length < 5;
          attempt += 1
        ) {
          await pumpEventQueue();
        }
        expect(notificationService.calls, [
          'show-start:$gateId',
          'show-finish:$gateId',
          'show-start:$otherId',
          'show-finish:$otherId',
          'clear:$jobId',
        ]);
      },
    );

    test('bounds uncoalesced terminal notification backlog', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final session = notifier.getSession(result.connectionId!)!;
      final sendOsc = session.debugHandlePrivateOsc;

      sendOsc('99', const ['i=gate', 'Gate']);
      await notificationService.showStarted.future;
      for (var index = 0; index < 512; index += 1) {
        sendOsc('99', ['', 'Message $index']);
      }
      await pumpEventQueue();

      expect(
        notifier.debugTerminalNotificationQueueLength(session.connectionId),
        notifier.debugTerminalNotificationQueueLimit,
      );
      notificationService.releaseShow.complete();
      await pumpEventQueue();
    });

    test(
      'disconnect drops queued notification work after in-flight show',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);
        final result = await notifier.connect(42, forceNew: true);
        final connectionId = result.connectionId!;
        final session = notifier.getSession(connectionId)!;
        final gateId = buildTerminalNotificationId(
          connectionId,
          identifier: 'kitty:gate',
        );
        final staleId = buildTerminalNotificationId(
          connectionId,
          identifier: 'kitty:stale',
        );

        session.debugHandlePrivateOsc('99', const ['i=gate', 'Gate']);
        await notificationService.showStarted.future;
        session.debugHandlePrivateOsc('99', const ['i=stale', 'Stale']);
        await pumpEventQueue();
        await notifier.disconnect(connectionId);
        notificationService.releaseShow.complete();
        for (
          var attempt = 0;
          attempt < 20 && notificationService.calls.length < 3;
          attempt += 1
        ) {
          await pumpEventQueue();
        }

        expect(notificationService.calls, [
          'show-start:$gateId',
          'show-finish:$gateId',
          'clear:$gateId',
        ]);
        expect(
          notificationService.calls,
          isNot(contains('show-start:$staleId')),
        );
        expect(notifier.debugTerminalNotificationQueueLength(connectionId), 0);
      },
    );

    test('disconnect clears native timed notifications', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final connectionId = result.connectionId!;
      final session = notifier.getSession(connectionId)!;
      final notificationId = buildTerminalNotificationId(
        connectionId,
        identifier: 'kitty:timed',
      );
      notificationService.releaseShow.complete();

      session.debugHandlePrivateOsc('99', const ['i=timed:w=60000', 'Timed']);
      for (
        var attempt = 0;
        attempt < 20 && notifier.debugTerminalNotificationExpiryTimerCount < 1;
        attempt += 1
      ) {
        await pumpEventQueue();
      }
      expect(notifier.debugTerminalNotificationExpiryTimerCount, 1);

      await notifier.disconnect(connectionId);
      await pumpEventQueue();

      expect(notifier.debugTerminalNotificationExpiryTimerCount, 0);
      expect(notificationService.calls, contains('clear:$notificationId'));
    });

    test('expiry cap clears the oldest native notification', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final connectionId = result.connectionId!;
      final session = notifier.getSession(connectionId)!;
      final limit = notifier.debugTerminalNotificationExpiryLimit;
      notificationService.releaseShow.complete();

      for (var index = 0; index <= limit; index += 1) {
        session.debugHandlePrivateOsc('99', [
          'i=expiry-$index:w=60000',
          'Timed',
        ]);
        final expectedShows = index + 1;
        for (var attempt = 0; attempt < 20; attempt += 1) {
          final completedShows = notificationService.calls
              .where((call) => call.startsWith('show-finish:'))
              .length;
          if (completedShows >= expectedShows) break;
          await pumpEventQueue();
        }
      }

      final oldestId = buildTerminalNotificationId(
        connectionId,
        identifier: 'kitty:expiry-0',
      );
      expect(notifier.debugTerminalNotificationExpiryTimerCount, limit);
      expect(notificationService.calls, contains('clear:$oldestId'));
    });

    test('disabled updates preserve an existing native expiry', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final session = notifier.getSession(result.connectionId!)!;
      final sendOsc = session.debugHandlePrivateOsc;
      notificationService.releaseShow.complete();

      sendOsc('99', const ['i=timed:w=60000', 'Initial']);
      for (
        var attempt = 0;
        attempt < 20 && notifier.debugTerminalNotificationExpiryTimerCount < 1;
        attempt += 1
      ) {
        await pumpEventQueue();
      }
      final callsBeforeUpdate = List<String>.of(notificationService.calls);
      (container.read(terminalNotificationsNotifierProvider.notifier)
                  as _EnabledTerminalNotificationsNotifier)
              .debugEnabled =
          false;

      sendOsc('99', const ['i=timed', 'Ignored']);
      await pumpEventQueue();

      expect(notifier.debugTerminalNotificationExpiryTimerCount, 1);
      expect(notificationService.calls, callsBeforeUpdate);
    });

    test('native show and close failures release their generations', () async {
      final reportedErrors = <FlutterErrorDetails>[];
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousErrorHandler);
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      final session = notifier.getSession(result.connectionId!)!;
      notificationService.releaseShow.complete();

      notificationService.throwOnShow = true;
      session.debugHandlePrivateOsc('99', const ['i=show-failure', 'Fail']);
      for (
        var attempt = 0;
        attempt < 20 && reportedErrors.isEmpty;
        attempt += 1
      ) {
        await pumpEventQueue();
      }
      expect(reportedErrors, hasLength(1));
      expect(notifier.debugTerminalNotificationGenerationCount, 0);

      notificationService.throwOnShow = false;
      session.debugHandlePrivateOsc('99', const [
        'i=close-failure:w=60000',
        'Timed',
      ]);
      for (
        var attempt = 0;
        attempt < 20 && notifier.debugTerminalNotificationExpiryTimerCount < 1;
        attempt += 1
      ) {
        await pumpEventQueue();
      }
      notificationService.throwOnClear = true;
      session.debugHandlePrivateOsc('99', const ['i=close-failure:p=close']);
      for (
        var attempt = 0;
        attempt < 20 && reportedErrors.length < 2;
        attempt += 1
      ) {
        await pumpEventQueue();
      }

      expect(reportedErrors, hasLength(2));
      expect(notifier.debugTerminalNotificationGenerationCount, 0);
      expect(notifier.debugTerminalNotificationExpiryTimerCount, 0);
      notificationService.throwOnClear = false;
    });

    test(
      'unidentified notification tap cancels its exact expiry timer',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);
        final result = await notifier.connect(42, forceNew: true);
        final session = notifier.getSession(result.connectionId!)!;
        notificationService.releaseShow.complete();

        session.debugHandlePrivateOsc('99', const ['w=60000', 'Unidentified']);
        for (
          var attempt = 0;
          attempt < 20 && notificationService.lastPayload == null;
          attempt += 1
        ) {
          await pumpEventQueue();
        }
        final payload = notificationService.lastPayload!;
        expect(payload.notificationIdentifier, isNull);
        expect(payload.platformNotificationId, isNotNull);
        expect(notifier.debugTerminalNotificationExpiryTimerCount, 1);

        notifier.handleTerminalNotificationTap(payload);

        expect(notifier.debugTerminalNotificationExpiryTimerCount, 0);
      },
    );

    test('cancelConnectionAttempt aborts an in-flight connect', () async {
      final cancellableService = _CancellableConnectSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final localContainer = ProviderContainer(
        overrides: [
          sshServiceProvider.overrideWithValue(cancellableService),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
        ],
      );
      addTearDown(localContainer.dispose);
      final notifier = localContainer.read(activeSessionsProvider.notifier);

      final pending = notifier.connect(42, forceNew: true);
      await cancellableService.connectStarted.future;

      expect(notifier.cancelConnectionAttempt(42), isTrue);
      expect(notifier.getConnectionAttempt(42)?.cancelRequested, isTrue);
      expect(notifier.getConnectionAttempt(42)?.isCancelling, isTrue);

      final result = await pending;

      expect(result.cancelled, isTrue);
      expect(result.success, isFalse);
      expect(notifier.getConnectionAttempt(42)?.cancelled, isTrue);
      expect(notifier.getConnectionAttempt(42)?.isCancelling, isFalse);
      expect(cancellableService.receivedToken?.isCancelled, isTrue);
    });

    test('cancelConnectionAttempt is a no-op without an attempt', () async {
      final notifier = container.read(activeSessionsProvider.notifier);

      expect(notifier.cancelConnectionAttempt(99), isFalse);
      expect(notifier.getConnectionAttempt(99), isNull);
    });

    test(
      'cancelConnectionAttempt aborts every concurrent same-host attempt',
      () async {
        final cancellableService = _CancellableConnectSshService(
          expectedAttempts: 2,
        );
        final hostRepository = _MockHostRepository();
        when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
        final localContainer = ProviderContainer(
          overrides: [
            sshServiceProvider.overrideWithValue(cancellableService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            portForwardRepositoryProvider.overrideWithValue(
              _emptyPortForwardRepository(),
            ),
          ],
        );
        addTearDown(localContainer.dispose);
        final notifier = localContainer.read(activeSessionsProvider.notifier);

        final first = notifier.connect(42, forceNew: true);
        final second = notifier.connect(42, forceNew: true);
        await cancellableService.allAttemptsStarted.future;

        expect(cancellableService.receivedTokens, hasLength(2));
        expect(notifier.cancelConnectionAttempt(42), isTrue);

        final results = await Future.wait([first, second]);

        expect(results.every((result) => result.cancelled), isTrue);
        expect(
          cancellableService.receivedTokens.every((token) => token.isCancelled),
          isTrue,
          reason: 'both concurrent attempts must observe cancellation',
        );
      },
    );

    test('honors cancellation that races a reused connection', () async {
      final localSshService = _FakeActiveSessionsSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final localContainer = ProviderContainer(
        overrides: [
          sshServiceProvider.overrideWithValue(localSshService),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
        ],
      );
      addTearDown(localContainer.dispose);
      final notifier = localContainer.read(activeSessionsProvider.notifier);

      final established = await notifier.connect(42, forceNew: true);
      expect(established.success, isTrue);

      // A reusing attempt cancelled before it settles must not hand back the
      // live session, but must also leave that shared session connected.
      final reusing = notifier.connect(42);
      notifier.cancelConnectionAttempt(42);
      final result = await reusing;

      expect(result.cancelled, isTrue);
      expect(result.connectionId, isNull);
      expect(
        localSshService.getSession(established.connectionId!),
        isNotNull,
        reason: 'a reused session belongs to the earlier caller',
      );
    });

    test('keeps ownership on a connected sibling during reconnect', () async {
      final configurationLog = <String>[];
      final older = _RecordingAutomaticForwardSession(
        connectionId: 1,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        name: 'older',
        configurationLog: configurationLog,
      );
      final newer = _RecordingAutomaticForwardSession(
        connectionId: 2,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        name: 'newer',
        configurationLog: configurationLog,
      );
      await older.updateAutomaticPortForwardProcessRoots({7300});
      final hostRepository = _MockHostRepository();
      when(
        () => hostRepository.getById(42),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
      final localContainer = ProviderContainer(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
          activeSessionsProvider.overrideWith(
            () => _OwnershipActiveSessionsNotifier(
              sessions: [older, newer],
              connectionStates: {
                older.connectionId: SshConnectionState.connected,
                newer.connectionId: SshConnectionState.reconnecting,
              },
            ),
          ),
        ],
      );
      addTearDown(localContainer.dispose);

      await localContainer
          .read(activeSessionsProvider.notifier)
          .reconfigureAutomaticPortForwardingForHost(42);

      expect(configurationLog, ['newer:false', 'older:true']);
      expect(older.automaticConfigurations.last.enabled, isTrue);
      expect(newer.automaticConfigurations.last.enabled, isFalse);
    });

    test('disables the old owner before enabling a newer sibling', () async {
      final configurationLog = <String>[];
      final older = _RecordingAutomaticForwardSession(
        connectionId: 1,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        name: 'older',
        configurationLog: configurationLog,
      );
      final newer = _RecordingAutomaticForwardSession(
        connectionId: 2,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        name: 'newer',
        configurationLog: configurationLog,
      );
      await older.updateAutomaticPortForwardProcessRoots({7300});
      final hostRepository = _MockHostRepository();
      when(
        () => hostRepository.getById(42),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
      final localContainer = ProviderContainer(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
          activeSessionsProvider.overrideWith(
            () => _OwnershipActiveSessionsNotifier(
              sessions: [older, newer],
              connectionStates: {
                older.connectionId: SshConnectionState.connected,
                newer.connectionId: SshConnectionState.connected,
              },
            ),
          ),
        ],
      );
      addTearDown(localContainer.dispose);

      await localContainer
          .read(activeSessionsProvider.notifier)
          .reconfigureAutomaticPortForwardingForHost(42);

      expect(configurationLog, ['older:false', 'newer:true']);
      expect(newer.automaticPortForwardProcessRoots, contains(7300));
    });

    test('assigns shared host services to one duplicate saved host', () async {
      final primary = _RecordingAutomaticForwardSession(
        connectionId: 1,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
      );
      final secondary = _RecordingAutomaticForwardSession(
        connectionId: 2,
        hostId: 43,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
        useRecordedTunnels: true,
      );
      secondary.tunnels[-1] = const ActiveTunnelInfo(
        portForwardId: -1,
        localHost: '127.0.0.1',
        localPort: 49152,
        browserHost: 'secondary.localhost',
        browserPort: 49152,
        remoteHost: '127.0.0.1',
        remotePort: 3000,
        isLocal: true,
        isAutomatic: true,
        isShellRelated: true,
      );
      final hostRepository = _MockHostRepository();
      when(
        () => hostRepository.getById(42),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
      when(
        () => hostRepository.getById(43),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: true, id: 43));
      when(
        () => hostRepository.resolveProxyName(
          hostId: any(named: 'hostId'),
          label: any(named: 'label'),
          customName: any(named: 'customName'),
        ),
      ).thenAnswer((invocation) async {
        final hostId = invocation.namedArguments[#hostId]! as int;
        return 'dev-box-$hostId';
      });
      final localContainer = ProviderContainer(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
          activeSessionsProvider.overrideWith(
            () => _OwnershipActiveSessionsNotifier(
              sessions: [primary, secondary],
              connectionStates: {
                primary.connectionId: SshConnectionState.connected,
                secondary.connectionId: SshConnectionState.connected,
              },
            ),
          ),
        ],
      );
      addTearDown(localContainer.dispose);

      await localContainer
          .read(activeSessionsProvider.notifier)
          .reconfigureAutomaticPortForwardingForHost(43);

      expect(
        primary.automaticConfigurations.last.includeHostLevelListeners,
        isTrue,
      );
      expect(
        primary.automaticConfigurations.last.excludedRemoteListeners,
        contains(remoteTcpListenerKey('127.0.0.1', 3000)),
      );
      expect(
        secondary.automaticConfigurations.last.includeHostLevelListeners,
        isFalse,
      );
      expect(
        primary.automaticConfigurations.last.proxyHost,
        'dev-box-42.localhost',
      );
      expect(
        secondary.automaticConfigurations.last.proxyHost,
        'dev-box-43.localhost',
      );
      expect(primary.shellLineageToken, isNot(secondary.shellLineageToken));
    });

    for (final (
          name,
          hostname,
          otherHostname,
          username,
          otherUsername,
          jumpHostname,
          otherJumpHostname,
        )
        in const [
          (
            'does not exclude shell ports from a different SSH endpoint',
            'dev.example.com',
            'other.example.com',
            'tester',
            'tester',
            null,
            null,
          ),
          (
            'keeps case-sensitive usernames on separate automatic endpoints',
            'dev.example.com',
            'dev.example.com',
            'Build',
            'build',
            null,
            null,
          ),
          (
            'keeps distinct jump routes on separate automatic endpoints',
            'internal.example.com',
            'internal.example.com',
            'tester',
            'tester',
            'east-bastion.example.com',
            'west-bastion.example.com',
          ),
        ]) {
      test(name, () async {
        final primary = _RecordingAutomaticForwardSession(
          connectionId: 1,
          hostId: 42,
          client: _MockSshClient(),
          config: SshConnectionConfig(
            hostname: hostname,
            port: 22,
            username: username,
            jumpHost: jumpHostname == null
                ? null
                : SshConnectionConfig(
                    hostname: jumpHostname,
                    port: 22,
                    username: 'jump',
                  ),
          ),
        );
        final unrelated = _RecordingAutomaticForwardSession(
          connectionId: 2,
          hostId: 43,
          client: _MockSshClient(),
          config: SshConnectionConfig(
            hostname: otherHostname,
            port: 22,
            username: otherUsername,
            jumpHost: otherJumpHostname == null
                ? null
                : SshConnectionConfig(
                    hostname: otherJumpHostname,
                    port: 22,
                    username: 'jump',
                  ),
          ),
          useRecordedTunnels: true,
        );
        unrelated.tunnels[-1] = const ActiveTunnelInfo(
          portForwardId: -1,
          localHost: '127.0.0.1',
          localPort: 49152,
          browserHost: 'other.localhost',
          browserPort: 49152,
          remoteHost: '127.0.0.1',
          remotePort: 3000,
          isLocal: true,
          isAutomatic: true,
          isShellRelated: true,
        );
        final hostRepository = _MockHostRepository();
        when(
          () => hostRepository.getById(42),
        ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
        final localContainer = ProviderContainer(
          overrides: [
            hostRepositoryProvider.overrideWithValue(hostRepository),
            portForwardRepositoryProvider.overrideWithValue(
              _emptyPortForwardRepository(),
            ),
            activeSessionsProvider.overrideWith(
              () => _OwnershipActiveSessionsNotifier(
                sessions: [primary, unrelated],
                connectionStates: {
                  primary.connectionId: SshConnectionState.connected,
                  unrelated.connectionId: SshConnectionState.connected,
                },
              ),
            ),
          ],
        );
        addTearDown(localContainer.dispose);

        await localContainer
            .read(activeSessionsProvider.notifier)
            .reconfigureAutomaticPortForwardingForHost(42);

        expect(
          primary.automaticConfigurations.last.excludedRemoteListeners,
          isNot(contains(remoteTcpListenerKey('127.0.0.1', 3000))),
        );
      });
    }

    test(
      'manual exclusions stay stable on automatic events and track reverse listeners',
      () async {
        final changes = StreamController<void>.broadcast(sync: true);
        addTearDown(changes.close);
        final service = _FakeActiveSessionsSshService(
          useRecordedTunnels: true,
          tunnelChanges: changes,
        );
        final hosts = _MockHostRepository();
        when(
          () => hosts.getById(42),
        ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
        final localContainer = ProviderContainer(
          overrides: [
            sshServiceProvider.overrideWithValue(service),
            hostRepositoryProvider.overrideWithValue(hosts),
            portForwardRepositoryProvider.overrideWithValue(
              _emptyPortForwardRepository(),
            ),
          ],
        );
        addTearDown(localContainer.dispose);
        final notifier = localContainer.read(activeSessionsProvider.notifier);
        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        final session =
            service.getSession(result.connectionId!)!
                as _RecordingAutomaticForwardSession;
        var configured = session.automaticConfigurations.length;
        for (final (id, port, remoteHost, isLocal, automatic) in [
          (1, 3000, 'localhost', true, false),
          (-1, 3001, '127.0.0.1', true, true),
          (2, 3002, 'localhost', false, false),
        ]) {
          session.tunnels[id] = ActiveTunnelInfo(
            portForwardId: id,
            localHost: '127.0.0.1',
            localPort: port + 1000,
            remoteHost: remoteHost,
            remotePort: port,
            isLocal: isLocal,
            isAutomatic: automatic,
          );
          changes.add(null);
          await pumpEventQueue();
          if (automatic) {
            expect(session.automaticConfigurations, hasLength(configured));
          } else {
            expect(
              session.automaticConfigurations.last.excludedRemoteListeners,
              {
                ...remoteTcpListenerExclusionKeys('localhost', 3000),
                if (!isLocal)
                  ...remoteTcpListenerExclusionKeys('localhost', 3002),
              },
            );
            configured = session.automaticConfigurations.length;
          }
        }
        session.tunnels.remove(2);
        changes.add(null);
        await pumpEventQueue();
        expect(
          session.automaticConfigurations.last.excludedRemoteListeners,
          remoteTcpListenerExclusionKeys('localhost', 3000),
        );
      },
    );

    test('excludes stopped saved local forwards from discovery', () async {
      final primary = _RecordingAutomaticForwardSession(
        connectionId: 1,
        hostId: 42,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'dev.example.com',
          port: 22,
          username: 'tester',
        ),
      );
      final hostRepository = _MockHostRepository();
      when(
        () => hostRepository.getById(42),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: true));
      final portForwardRepository = _MockPortForwardRepository();
      when(() => portForwardRepository.getByHostId(42)).thenAnswer(
        (_) async => [
          PortForward(
            id: 1,
            name: 'Saved web',
            hostId: 42,
            forwardType: 'local',
            localHost: '127.0.0.1',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 3000,
            autoStart: false,
            createdAt: DateTime(2026),
          ),
        ],
      );
      final localContainer = ProviderContainer(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            portForwardRepository,
          ),
          activeSessionsProvider.overrideWith(
            () => _OwnershipActiveSessionsNotifier(
              sessions: [primary],
              connectionStates: {
                primary.connectionId: SshConnectionState.connected,
              },
            ),
          ),
        ],
      );
      addTearDown(localContainer.dispose);

      await localContainer
          .read(activeSessionsProvider.notifier)
          .reconfigureAutomaticPortForwardingForHost(42);

      expect(
        primary.automaticConfigurations.last.excludedRemoteListeners,
        contains(remoteTcpListenerKey('localhost', 3000)),
      );
      expect(
        primary.automaticConfigurations.last.excludedRemoteListeners,
        contains(remoteTcpListenerKey('::1', 3000)),
      );
    });

    test(
      'reloads automatic forwarding settings after a slow connect',
      () async {
        final connectGate = Completer<void>();
        final slowSshService = _FakeActiveSessionsSshService(
          connectGate: connectGate,
        );
        final hostRepository = _MockHostRepository();
        var currentHost = _automaticForwardHost(enabled: true);
        when(
          () => hostRepository.getById(42),
        ).thenAnswer((_) async => currentHost);
        final localContainer = ProviderContainer(
          overrides: [
            sshServiceProvider.overrideWithValue(slowSshService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            portForwardRepositoryProvider.overrideWithValue(
              _emptyPortForwardRepository(),
            ),
          ],
        );
        addTearDown(localContainer.dispose);
        final notifier = localContainer.read(activeSessionsProvider.notifier);

        final connection = notifier.connect(42, forceNew: true);
        await slowSshService.connectStarted.future;
        currentHost = _automaticForwardHost(enabled: false);
        connectGate.complete();
        final result = await connection;
        await pumpEventQueue();

        final session =
            slowSshService.getSession(result.connectionId!)!
                as _RecordingAutomaticForwardSession;
        expect(session.automaticConfigurations, isNotEmpty);
        expect(session.automaticConfigurations.last.enabled, isFalse);
      },
    );

    test('serializes automatic forwarding reconfiguration per host', () async {
      final localSshService = _FakeActiveSessionsSshService();
      final hostRepository = _MockHostRepository();
      when(
        () => hostRepository.getById(42),
      ).thenAnswer((_) async => _automaticForwardHost(enabled: false));
      when(
        () => hostRepository.resolveProxyName(
          hostId: any(named: 'hostId'),
          label: any(named: 'label'),
          customName: any(named: 'customName'),
        ),
      ).thenAnswer((invocation) async {
        final customName = invocation.namedArguments[#customName] as String?;
        return customName ?? 'dev-box-42';
      });
      final localContainer = ProviderContainer(
        overrides: [
          sshServiceProvider.overrideWithValue(localSshService),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          portForwardRepositoryProvider.overrideWithValue(
            _emptyPortForwardRepository(),
          ),
        ],
      );
      addTearDown(localContainer.dispose);
      final notifier = localContainer.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      await pumpEventQueue();
      final session =
          localSshService.getSession(result.connectionId!)!
              as _RecordingAutomaticForwardSession;
      session.automaticConfigurations.clear();

      final firstLoad = Completer<Host?>();
      final secondLoad = Completer<Host?>();
      var loadCount = 0;
      when(() => hostRepository.getById(42)).thenAnswer((_) {
        loadCount++;
        return loadCount <= 2 ? firstLoad.future : secondLoad.future;
      });

      final first = notifier.reconfigureAutomaticPortForwardingForHost(42);
      final second = notifier.reconfigureAutomaticPortForwardingForHost(42);
      await pumpEventQueue();
      expect(loadCount, 1);

      firstLoad.complete(_automaticForwardHost(enabled: false));
      await pumpEventQueue(times: 10);
      expect(loadCount, 3);
      secondLoad.complete(
        _automaticForwardHost(enabled: true, portProxyName: 'api'),
      );
      await Future.wait([first, second]);

      expect(session.automaticConfigurations.map((config) => config.enabled), [
        false,
        true,
      ]);
      expect(session.automaticConfigurations.last.proxyHost, 'api.localhost');
    });

    test('syncBackgroundStatus publishes counts for active sessions', () async {
      final notifier = container.read(activeSessionsProvider.notifier);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);

      await Future<void>.delayed(Duration.zero);
      methodCalls.clear();
      await notifier.syncBackgroundStatus();

      expect(methodCalls, hasLength(1));
      expect(methodCalls.single.method, 'updateStatus');
      final arguments = Map<String, Object?>.from(
        methodCalls.single.arguments as Map<Object?, Object?>,
      );
      expect(arguments, <String, Object?>{
        'connectionCount': 1,
        'connectedCount': 1,
      });
    });

    test(
      'publishes active connection metadata when terminal theme changes',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);
        final providerUpdates = <Map<int, SshConnectionState>>[];
        final subscription = container.listen<Map<int, SshConnectionState>>(
          activeSessionsProvider,
          (_, next) => providerUpdates.add(next),
        );
        addTearDown(subscription.close);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        final connectionId = result.connectionId!;
        providerUpdates.clear();

        fakeSshService.getSession(connectionId)!.terminalTheme =
            monkey_themes.TerminalThemes.defaultDarkTheme;
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(providerUpdates, isNotEmpty);
        expect(
          notifier.getActiveConnections().single.terminalTheme,
          monkey_themes.TerminalThemes.defaultDarkTheme,
        );
      },
    );

    test('persists native focus in active connection metadata', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);
      final connectionId = result.connectionId!;
      final key = AcpSessionKey.of(
        hostId: 42,
        providerId: 'pi',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );

      notifier
        ..updateSessionNativeAcpFocus(
          connectionId,
          key: key,
          displayTitle: 'Pi',
        )
        ..updateSessionNativeAcpPreview(
          connectionId,
          'You: inspect this\nAgent: working on it',
        );

      final focused = notifier.getActiveConnection(connectionId)!;
      expect(
        fakeSshService.getSession(connectionId)!.activeNativeAcpSessionKey,
        key,
      );
      expect(focused.sessionTitle, 'Pi · native');
      expect(focused.preview, 'You: inspect this\nAgent: working on it');
      expect(focused.windowTitle, isNull);
      expect(focused.workingDirectory, isNull);

      notifier.updateSessionNativeAcpFocus(connectionId, key: null);
      expect(
        fakeSshService.getSession(connectionId)!.activeNativeAcpSessionKey,
        isNull,
      );
      final cleared = notifier.getActiveConnection(connectionId)!;
      expect(cleared.sessionTitle, isNot('Pi · native'));
      expect(cleared.preview, isNot('You: inspect this\nAgent: working on it'));
    });

    test('syncBackgroundStatus serializes queued updates', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final firstCallStarted = Completer<void>();
      final releaseFirstCall = Completer<void>();
      var activeCalls = 0;
      var maxConcurrentCalls = 0;
      var updateCallCount = 0;

      await notifier.connect(7, forceNew: true);
      await Future<void>.delayed(Duration.zero);
      methodCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            if (call.method != 'updateStatus') {
              return null;
            }
            updateCallCount++;
            activeCalls++;
            if (activeCalls > maxConcurrentCalls) {
              maxConcurrentCalls = activeCalls;
            }
            if (updateCallCount == 1) {
              firstCallStarted.complete();
              await releaseFirstCall.future;
            }
            activeCalls--;
            return null;
          });

      final firstSync = notifier.syncBackgroundStatus();
      await firstCallStarted.future;
      final secondSync = notifier.syncBackgroundStatus();
      await Future<void>.delayed(Duration.zero);

      expect(updateCallCount, 1);

      releaseFirstCall.complete();
      await Future.wait<void>([firstSync, secondSync]);

      expect(updateCallCount, 2);
      expect(maxConcurrentCalls, 1);
    });

    test('removes sessions that close unexpectedly', () async {
      final notifier = container.read(activeSessionsProvider.notifier);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);
      expect(result.connectionId, isNotNull);

      final connectionId = result.connectionId!;
      fakeSshService.completeConnection(connectionId);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.getSession(connectionId), isNull);
      expect(container.read(activeSessionsProvider)[connectionId], isNull);
      expect(
        notifier.getConnectionAttempt(42)?.latestMessage,
        'Connection closed',
      );
    });

    test(
      'removes stale sessions when channel opens report a closed transport',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        expect(result.connectionId, isNotNull);

        final connectionId = result.connectionId!;
        final session = fakeSshService.getSession(connectionId)!;
        when(
          () => fakeSshService
              .clientFor(connectionId)
              .execute(any(), pty: any(named: 'pty')),
        ).thenThrow(SSHStateError('Transport is closed'));

        await expectLater(
          session.execute('true'),
          throwsA(isA<SSHStateError>()),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.getSession(connectionId), isNull);
        expect(container.read(activeSessionsProvider)[connectionId], isNull);
        expect(
          notifier.getConnectionAttempt(42)?.latestMessage,
          'Connection became unresponsive. Reconnect to continue.',
        );
      },
    );

    test(
      'removes stale sessions when IPv6 browser forwards report a closed transport',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        expect(result.connectionId, isNotNull);

        final connectionId = result.connectionId!;
        final session = fakeSshService.getSession(connectionId)!;
        await pumpEventQueue();
        when(
          () => fakeSshService
              .clientFor(connectionId)
              .forwardLocal('remote.example.com', 80),
        ).thenThrow(SSHStateError('Transport is closed'));

        addTearDown(session.stopAllForwards);

        expect(
          await session.startLocalForward(
            portForwardId: 1,
            localHost: InternetAddress.loopbackIPv4.address,
            localPort: 0,
            remoteHost: 'remote.example.com',
            remotePort: 80,
          ),
          isTrue,
        );

        final activeTunnel = session.activeTunnels.single;
        expect(
          activeTunnel.browserHost,
          portForwardBrowserHostForPortForwardId(activeTunnel.portForwardId),
        );
        expect(activeTunnel.browserPort, activeTunnel.localPort);
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv6,
          activeTunnel.browserPort!,
        );
        socket.destroy();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.getSession(connectionId), isNull);
        expect(container.read(activeSessionsProvider)[connectionId], isNull);
        expect(
          notifier.getConnectionAttempt(42)?.latestMessage,
          'Connection became unresponsive. Reconnect to continue.',
        );
      },
    );

    for (final isLocal in [true, false]) {
      for (final ending in ['socket EOF', 'channel EOF', 'channel error']) {
        test(
          '${isLocal ? 'local' : 'reverse'} relay handles $ending',
          () async {
            final client = _MockSshClient();
            final forward = _SingleCloseForwardChannel();
            final session = _testSession(client);
            final channelBytes = <int>[];
            final channelDone = Completer<void>();
            final channelSubscription = forward._sinkController.stream.listen(
              channelBytes.addAll,
              onDone: channelDone.complete,
            );
            late final Socket socket;
            if (isLocal) {
              when(
                () => client.forwardLocal('remote.example.com', 80),
              ).thenAnswer((_) async => forward);
              expect(
                await session.startLocalForward(
                  portForwardId: 1,
                  localHost: '127.0.0.1',
                  localPort: 0,
                  remoteHost: 'remote.example.com',
                  remotePort: 80,
                ),
                isTrue,
              );
              socket = await Socket.connect(
                '127.0.0.1',
                session.activeTunnels.single.localPort,
              );
            } else {
              final remoteForward = _MockRemoteForward();
              final connections = StreamController<SSHForwardChannel>();
              final targetServer = await ServerSocket.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
              final accepted = Completer<Socket>();
              final subscription = targetServer.listen(accepted.complete);
              when(() => remoteForward.host).thenReturn('127.0.0.1');
              when(() => remoteForward.port).thenReturn(8022);
              when(
                () => remoteForward.connections,
              ).thenAnswer((_) => connections.stream);
              when(remoteForward.close).thenReturn(null);
              when(
                () => client.forwardRemote(host: '127.0.0.1', port: 8022),
              ).thenAnswer((_) async => remoteForward);
              expect(
                await session.startRemoteForward(
                  portForwardId: 1,
                  remoteHost: '127.0.0.1',
                  remotePort: 8022,
                  localHost: '127.0.0.1',
                  localPort: targetServer.port,
                ),
                isTrue,
              );
              connections.add(forward);
              socket = await accepted.future;
              addTearDown(() async {
                await connections.close();
                await subscription.cancel();
                await targetServer.close();
              });
            }
            addTearDown(() async {
              socket.destroy();
              await session.stopAllForwards();
              await forward.close();
              await channelSubscription.cancel();
            });
            final socketBytes = <int>[];
            final socketDone = Completer<void>();
            socket.listen(socketBytes.addAll, onDone: socketDone.complete);
            final request = List<int>.generate(128 * 1024, (i) => i % 251);
            final response = request.reversed.toList();
            if (ending == 'socket EOF') {
              socket.add(request);
              await socket.close();
              await channelDone.future.timeout(const Duration(seconds: 5));
              expect(channelBytes, request);
              expect(forward.destroyCalls, 0);
              await Future<void>.delayed(const Duration(milliseconds: 10));
              forward._streamController.add(Uint8List.fromList(response));
              await forward.closeIncoming();
              await socketDone.future.timeout(const Duration(seconds: 5));
              expect(socketBytes, response);
              expect(forward.sink.closeAttempts, 1);
            } else if (ending == 'channel EOF') {
              forward._streamController.add(Uint8List.fromList(request));
              await forward.closeIncoming();
              await socketDone.future.timeout(const Duration(seconds: 5));
              expect(socketBytes, request);
              expect(forward.destroyCalls, 0);
              await Future<void>.delayed(const Duration(milliseconds: 10));
              socket.add(response);
              await socket.close();
              await channelDone.future.timeout(const Duration(seconds: 5));
              expect(channelBytes, response);
              expect(forward.sink.closeAttempts, 1);
            } else {
              forward._streamController.addError(
                const SocketException('relay failed'),
              );
              await socketDone.future.timeout(const Duration(seconds: 5));
            }
            await _waitForCondition(() => forward.destroyCalls > 0);
            expect(forward.destroyCalls, 1);
            if (ending == 'channel error') {
              expect(forward.sink.closeAttempts, 0);
            }
          },
        );
      }
    }

    for (final scenario in [
      'closed sink',
      'sink closes during flush',
      'remote EOF',
      'socket EOF',
      'stop',
      'refused',
      'late open',
      'late refusal',
      'peer closes before open',
    ]) {
      test('Crashlytics local forward handles $scenario', () async {
        final client = _MockSshClient();
        final forward = _SingleCloseForwardChannel();
        final opening = Completer<SSHForwardChannel>();
        final requested = Completer<void>();
        final flushing = Completer<void>();
        final releaseFlush = Completer<void>();
        if (scenario == 'sink closes during flush') {
          forward.onFlush = () {
            flushing.complete();
            return releaseFlush.future;
          };
        }
        final session = _testSession(client);
        when(() => client.forwardLocal('remote.example.com', 80)).thenAnswer((
          _,
        ) {
          requested.complete();
          return opening.future;
        });
        addTearDown(() async {
          if (!releaseFlush.isCompleted) releaseFlush.complete();
          await session.stopAllForwards();
          if (scenario == 'refused' ||
              scenario == 'late refusal' ||
              scenario == 'late open' ||
              scenario == 'peer closes before open') {
            await forward._streamController.stream.listen((_) {}).cancel();
          }
          await forward.close();
        });
        expect(
          await session.startLocalForward(
            portForwardId: 1,
            localHost: InternetAddress.loopbackIPv4.address,
            localPort: 0,
            remoteHost: 'remote.example.com',
            remotePort: 80,
          ),
          isTrue,
        );
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          session.activeTunnels.single.localPort,
        );
        addTearDown(socket.destroy);
        final socketErrors = <Object>[];
        // Own both socket error paths immediately, including errors that
        // arrive while the test is coordinating channel closure.
        final socketDone = socket.done.then<void>(
          (_) {},
          onError: socketErrors.add,
        );
        final received = socket
            .handleError(socketErrors.add)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        await requested.future;
        if (scenario == 'peer closes before open') {
          await socket.close();
          await received.timeout(const Duration(seconds: 1));
          opening.complete(forward);
        } else if (scenario == 'late open' || scenario == 'late refusal') {
          await session.stopForward(1).timeout(const Duration(seconds: 1));
          if (scenario == 'late open') {
            opening.complete(forward);
          } else {
            opening.completeError(SSHChannelOpenError(1, 'refused'));
          }
        } else if (scenario == 'refused') {
          opening.completeError(SSHChannelOpenError(1, 'refused'));
        } else {
          if (scenario == 'closed sink') {
            // Queue a real socket write while opening is pending. The pump
            // must discard it when the delivered channel's sink is closed.
            socket.add([1, 2, 3]);
            await socket.flush();
            await forward._sinkController.close();
          }
          opening.complete(forward);
          await Future<void>.delayed(Duration.zero);
          if (scenario == 'remote EOF') {
            forward._streamController.add(Uint8List.fromList([4, 5, 6]));
            await forward.closeIncoming();
          } else if (scenario == 'socket EOF') {
            await socket.close();
            await forward.closeIncoming();
          } else if (scenario == 'stop') {
            await session.stopForward(1).timeout(const Duration(seconds: 1));
          } else if (scenario != 'closed sink') {
            socket.add([1, 2, 3]);
            await socket.flush();
            if (scenario == 'sink closes during flush') {
              await flushing.future.timeout(const Duration(seconds: 1));
              socket.add([4, 5, 6]);
              await socket.flush();
              await forward._sinkController.close();
              releaseFlush.complete();
            }
          }
        }
        final bytes = await received.timeout(const Duration(seconds: 1));
        await socket.close().then<void>((_) {}, onError: socketErrors.add);
        await socketDone;
        if (scenario == 'closed sink' ||
            scenario == 'sink closes during flush') {
          // All writes precede remote closure. The server may still have
          // unread request bytes when it closes, which can produce a reset
          // (macOS) or a broken pipe (Linux) even after its write side has
          // closed gracefully.
          expect(
            socketErrors,
            everyElement(
              isA<SocketException>().having(
                (error) => error.osError?.errorCode,
                'connection reset or broken pipe error code',
                isIn(
                  Platform.isWindows
                      ? const [10053, 10054]
                      : (Platform.isMacOS ? const [32, 54] : const [32, 104]),
                ),
              ),
            ),
          );
        } else {
          expect(socketErrors, isEmpty);
        }
        if (scenario == 'remote EOF') expect(bytes, [4, 5, 6]);
        if (scenario == 'closed sink') expect(forward.sink.addAttempts, 0);
        if (scenario == 'sink closes during flush') {
          expect(forward.sink.addAttempts, 1);
        }
        expect(forward.sink.addStreamAttempts, 0);
        if (scenario == 'stop' ||
            scenario == 'closed sink' ||
            scenario == 'sink closes during flush') {
          expect(forward.sink.closeAttempts, 0);
        }
        await _waitForCondition(
          () => scenario.contains('refus') || forward.destroyCalls == 1,
        );
        expect(forward.destroyCalls, scenario.contains('refus') ? 0 : 1);
      });
    }

    test(
      'removes stale sessions when remote forwards report a closed transport',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        expect(result.connectionId, isNotNull);

        final connectionId = result.connectionId!;
        final session = fakeSshService.getSession(connectionId)!;
        when(
          () => fakeSshService
              .clientFor(connectionId)
              .forwardRemote(host: '127.0.0.1', port: 8022),
        ).thenThrow(
          SSHStateError('Connection closed while waiting for channel open'),
        );

        expect(
          await session.startRemoteForward(
            portForwardId: 1,
            remoteHost: '127.0.0.1',
            remotePort: 8022,
            localHost: '127.0.0.1',
            localPort: 22,
          ),
          isFalse,
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.getSession(connectionId), isNull);
        expect(container.read(activeSessionsProvider)[connectionId], isNull);
        expect(
          notifier.getConnectionAttempt(42)?.latestMessage,
          'Connection became unresponsive. Reconnect to continue.',
        );
      },
    );

    test('updateSessionTheme skips unchanged theme IDs', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final notifications = <Map<int, SshConnectionState>>[];
      final subscription = container.listen<Map<int, SshConnectionState>>(
        activeSessionsProvider,
        (_, next) => notifications.add(next),
      );
      addTearDown(subscription.close);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);
      final connectionId = result.connectionId!;
      notifications.clear();

      notifier.updateSessionTheme(
        connectionId,
        monkey_themes.TerminalThemes.dracula.id,
        isDark: true,
      );
      expect(notifications, hasLength(1));
      notifications.clear();

      notifier.updateSessionTheme(
        connectionId,
        monkey_themes.TerminalThemes.dracula.id,
        isDark: true,
      );
      expect(notifications, isEmpty);
    });

    for (final reason in ['user', 'unexpected', 'disconnect_all']) {
      test(
        '$reason cleanup preserves a concurrent connection and logs once',
        () async {
          final notifier = container.read(activeSessionsProvider.notifier);
          final first = await notifier.connect(42, forceNew: true);
          final connectionId = first.connectionId!;
          final gate = Completer<void>();
          fakeSshService.disconnectGate = gate;
          final closing = switch (reason) {
            'user' => notifier.disconnect(connectionId),
            'unexpected' => notifier.handleUnexpectedDisconnect(
              connectionId,
              message: 'Connection lost',
            ),
            _ => notifier.disconnectAll(),
          };
          expect(container.read(activeSessionsProvider), isEmpty);
          final newest = await notifier.connect(42, forceNew: true);
          final attempt = notifier.getConnectionAttempt(42);
          await notifier.handleUnexpectedDisconnect(
            connectionId,
            message: 'Late duplicate',
          );
          gate.complete();
          await closing;

          expect(container.read(activeSessionsProvider), {
            newest.connectionId!: SshConnectionState.connected,
          });
          expect(
            notifier.getActiveConnections().single.connectionId,
            newest.connectionId,
          );
          expect(notifier.getConnectionAttempt(42), same(attempt));
          expect(telemetry.disconnectReasons, [reason]);
        },
      );
    }

    test(
      'disconnectAll clears active sessions and connection attempts',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        expect(notifier.getConnectionAttempt(42), isNotNull);

        await notifier.disconnectAll();

        expect(notifier.getActiveConnections(), isEmpty);
        expect(notifier.getConnectionAttempt(42), isNull);
        expect(container.read(activeSessionsProvider), isEmpty);
      },
    );
  });

  group('SshService', () {
    late SshService sshService;

    setUp(() {
      sshService = SshService();
    });

    test('starts with no sessions', () {
      expect(sshService.sessions, isEmpty);
    });

    test('isConnected returns false for unknown host', () {
      expect(sshService.isConnected(999), isFalse);
    });

    test('getSession returns null for unknown host', () {
      expect(sshService.getSession(999), isNull);
    });

    test('connectToHost fails without host repository', () async {
      final result = await sshService.connectToHost(1);

      expect(result.success, isFalse);
      expect(result.error, 'Host repository not available');
    });

    test('disconnect is safe for unknown host', () async {
      // Should not throw
      await sshService.disconnect(999);
    });

    test('disconnectAll is safe with no sessions', () async {
      // Should not throw
      await sshService.disconnectAll();
    });

    for (final demo in [false, true]) {
      test(
        'timestamp failure preserves ${demo ? 'demo' : 'authenticated'} session',
        () async {
          final host = _automaticForwardHost(enabled: false).copyWith(
            label: demo ? 'App Review Demo · Timestamp' : 'Timestamp',
            tags: const Value('app-review,demo'),
          );
          final repository = _MockHostRepository();
          final timestamp = Completer<bool>();
          when(() => repository.getById(host.id)).thenAnswer((_) async => host);
          when(
            () => repository.updateLastConnected(host.id),
          ).thenAnswer((_) => timestamp.future);
          final service = demo
              ? SshService(hostRepository: repository)
              : (await _AuthenticationFixture.create(
                  hostname: host.hostname,
                  keyBytes: [1, 3, 5],
                  hostRepository: repository,
                )).service;
          addTearDown(service.disconnectAll);

          final result = await service.connectToHost(host.id);
          expect(result.success, isTrue);
          expect(timestamp.isCompleted, isFalse);
          expect(result.connectionId, isNotNull);
          expect(
            service.getSession(result.connectionId!)?.client,
            same(result.client),
          );
          timestamp.completeError(Exception('timestamp write failed'));
          await pumpEventQueue();
          expect(service.isConnected(result.connectionId!), isTrue);
          verify(() => repository.updateLastConnected(host.id)).called(1);
        },
      );
    }

    for (final failClose in [false, true]) {
      test(
        'bulk shutdown preserves new sessions when close fails: $failClose',
        () async {
          final repository = _MockHostRepository();
          when(
            () => repository.getById(any()),
          ).thenAnswer((_) async => _automaticForwardHost(enabled: false));
          when(
            () => repository.updateLastConnected(any()),
          ).thenAnswer((_) async => true);
          final service = _CapturingSshService(
            hostRepository: repository,
            keyRepository: null,
          );
          addTearDown(service.disconnectAll);
          final clients = List.generate(3, (_) => _MockSshClient());
          final closing = Completer<void>();
          final started = Completer<void>();
          when(clients[0].close).thenAnswer((_) {
            started.complete();
            return closing.future;
          });
          for (final client in clients.skip(1)) {
            when(client.close).thenAnswer((_) async {});
          }
          service.result = SshConnectionResult(
            success: true,
            client: clients[0],
          );
          final first = await service.connectToHost(42);
          service.result = SshConnectionResult(
            success: true,
            client: clients[1],
          );
          final second = await service.connectToHost(42);
          final failure = StateError('close failed');
          final stopped = expectLater(
            service.disconnectAll(),
            failClose ? throwsA(same(failure)) : completes,
          );
          await started.future;
          expect(service.sessions, isEmpty);
          await service.disconnect(second.connectionId!);
          service.result = SshConnectionResult(
            success: true,
            client: clients[2],
          );
          final newest = await service.connectToHost(42);
          if (failClose) {
            closing.completeError(failure);
          } else {
            closing.complete();
          }
          await stopped;

          expect(service.isConnected(first.connectionId!), isFalse);
          expect(service.isConnected(second.connectionId!), isFalse);
          expect(service.sessions.keys, [newest.connectionId]);
          verify(clients[0].close).called(1);
          verify(clients[1].close).called(1);
          verifyNever(clients[2].close);
        },
      );
    }

    for (final asynchronous in [false, true]) {
      test(
        'session close handles ${asynchronous ? 'async' : 'sync'} disconnected transport EOF',
        () async {
          final client = _MockSshClient();
          final dependent = _MockSshClient();
          final error = SSHStateError('Transport is closed');
          final stack = StackTrace.fromString(
            '#0 SSHTransport.sendPacket\n#1 SSHChannelController._sendEOFIfNeeded\n#2 SSHClient._closeChannels',
          );
          when(client.close).thenAnswer((_) {
            if (asynchronous) return Future<void>.error(error, stack);
            Error.throwWithStackTrace(error, stack);
          });
          when(dependent.close).thenAnswer((_) async {});
          final session = SshSession(
            connectionId: 1,
            hostId: 42,
            client: client,
            dependentClients: [dependent],
            config: const SshConnectionConfig(
              hostname: 'host',
              port: 22,
              username: 'tester',
            ),
          );
          await session.close();
          verify(client.close).called(1);
          verify(dependent.close).called(1);
        },
      );
    }

    test('session close still reports unrelated SSH state failures', () async {
      final client = _MockSshClient();
      final error = SSHStateError('Unexpected state');
      when(client.close).thenAnswer((_) => Future<void>.error(error));
      final session = SshSession(
        connectionId: 1,
        hostId: 42,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'host',
          port: 22,
          username: 'tester',
        ),
      );
      await expectLater(session.close(), throwsA(same(error)));
    });

    for (final failureIndex in [0, 1]) {
      test(
        'closeAll closes every client when client $failureIndex fails',
        () async {
          final clients = List.generate(3, (_) => _MockSshClient());
          final failure = StateError('client close failed');
          for (final client in clients) {
            when(client.close).thenAnswer((_) async {});
          }
          when(clients[failureIndex].close).thenThrow(failure);
          final result = SshConnectionResult(
            success: true,
            client: clients[0],
            dependentClients: clients.sublist(1),
          );
          await expectLater(result.closeAll(), throwsA(same(failure)));
          for (final client in clients) {
            verify(client.close).called(1);
          }
        },
      );
    }

    test('connectToHost fails when host not found', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = SshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      final result = await service.connectToHost(999);

      expect(result.success, isFalse);
      expect(result.error, 'Host not found');

      await db.close();
    });

    test('connectToHost uses Auto keys when host has no password', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Auto Key 1',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'key-material-1',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Auto Key 2',
          keyType: 'rsa',
          publicKey: 'ssh-rsa BBBB...',
          privateKey: 'key-material-2',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.10',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.privateKey, isNull);
      expect(config.identityKeys, hasLength(2));
    });

    test('connectToHost migrates legacy plaintext Auto keys', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      const privateKey = 'legacy-key-material';
      final keyId = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Legacy Auto Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAA...',
              privateKey: privateKey,
            ),
          );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.12',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.identityKeys, hasLength(1));
      expect(config.identityKeys!.single.privateKey, privateKey);

      final rawKey = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(keyId))).getSingle();
      expect(rawKey.privateKey, startsWith('ENCv1:'));
      expect(rawKey.privateKey, isNot(privateKey));
    });

    test('connectToHost skips unreadable Auto keys', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Unreadable Auto Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 BAD',
              privateKey: _structurallyValidInvalidEncryptedSecret(),
            ),
          );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Readable Auto Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 GOOD',
          privateKey: 'readable-key-material',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.14',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.identityKeys, hasLength(1));
      expect(config.identityKeys!.single.name, 'Readable Auto Key');
    });

    test(
      'connectToHost fails during preflight for unreadable explicit key',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = KeyRepository(db, encryptionService);
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final keyId = await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Unreadable Explicit Key',
                keyType: 'ed25519',
                publicKey: 'ssh-ed25519 BAD',
                privateKey: _structurallyValidInvalidEncryptedSecret(),
              ),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Explicit Key Host',
                hostname: '10.0.0.15',
                username: 'admin',
                keyId: Value(keyId),
              ),
            );

        final result = await service.connectToHost(hostId);

        expect(result.success, isFalse);
        expect(
          result.error,
          'Connection setup failed. Check saved credentials and try again.',
        );
        expect(service.capturedConfig, isNull);
      },
    );

    test('connectToHost caps Auto keys to avoid auth lockout', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      for (var i = 0; i < 7; i++) {
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key $i',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 KEY$i',
            privateKey: 'key-material-$i',
          ),
        );
      }
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.13',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.identityKeys, hasLength(5));
      expect(config.identityKeys!.map((key) => key.name).toList(), [
        'Auto Key 0',
        'Auto Key 1',
        'Auto Key 2',
        'Auto Key 3',
        'Auto Key 4',
      ]);
    });

    test(
      'connectToHost fetches Auto keys once for host and jump host',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(db, encryptionService);
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final jumpHostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Jump Host',
                hostname: '10.0.0.20',
                username: 'jump',
              ),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.21',
                username: 'target',
                jumpHostId: Value(jumpHostId),
              ),
            );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key 1',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: 'key-material-1',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key 2',
            keyType: 'rsa',
            publicKey: 'ssh-rsa BBBB...',
            privateKey: 'key-material-2',
          ),
        );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.identityKeys, hasLength(2));
        expect(config.jumpHost, isNotNull);
        expect(config.jumpHost!.identityKeys, hasLength(2));
        expect(keyRepo.getAllCallCount, 1);
      },
    );

    test('connectToHost keeps explicit key override', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      final selectedKeyId = await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Selected Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 CCCC...',
          privateKey: 'selected-key-material',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Other Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa DDDD...',
          privateKey: 'other-key-material',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Pinned Key Host',
              hostname: '10.0.0.11',
              username: 'root',
              keyId: Value(selectedKeyId),
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.privateKey, 'selected-key-material');
      expect(config.identityKeys, isNull);
    });

    test(
      'connectToHost falls back to Auto keys when selected key is missing',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(
          db,
          encryptionService,
          returnNullOnGetById: true,
        );
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final selectedKeyId = await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Selected Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 CCCC...',
            privateKey: 'selected-key-material',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa DDDD...',
            privateKey: 'auto-key-material',
          ),
        );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Pinned Key Host',
                hostname: '10.0.0.30',
                username: 'root',
                keyId: Value(selectedKeyId),
              ),
            );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.privateKey, isNull);
        expect(config.identityKeys, hasLength(2));
      },
    );

    test(
      'connectToHost falls back to Auto keys for jump host when selected key is missing',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(
          db,
          encryptionService,
          returnNullOnGetById: true,
        );
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final selectedJumpKeyId = await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Selected Jump Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 EEEE...',
            privateKey: 'selected-jump-key-material',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa FFFF...',
            privateKey: 'auto-key-material',
          ),
        );
        final jumpHostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Jump Host',
                hostname: '10.0.0.31',
                username: 'jump',
                keyId: Value(selectedJumpKeyId),
              ),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.32',
                username: 'target',
                jumpHostId: Value(jumpHostId),
              ),
            );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.jumpHost, isNotNull);
        expect(config.jumpHost!.privateKey, isNull);
        expect(config.jumpHost!.identityKeys, hasLength(2));
      },
    );

    test('connectToHost skips Auto keys when host has a password', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Unused Auto Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 EEEE...',
          privateKey: 'unused-key-material',
        ),
      );
      final hostId = await hostRepo.insert(
        HostsCompanion.insert(
          label: 'Password Host',
          hostname: '10.0.0.12',
          username: 'admin',
          password: const Value('secret'),
        ),
      );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.password, 'secret');
      expect(config.identityKeys, isNull);
    });

    test('connect fails with invalid hostname', () async {
      const config = SshConnectionConfig(
        hostname: 'nonexistent.invalid.host.test',
        port: 22,
        username: 'user',
        connectionTimeout: Duration(seconds: 2),
      );

      final result = await sshService.connect(config);

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });

    for (final passphrase in <String?>[null, 'incorrect']) {
      test(
        'unusable encrypted identity ($passphrase) opens no sockets',
        () async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final generated = await generateOpenSshKey(
            keyType: SshKeyType.ed25519,
            comment: 'test',
            passphrase: 'correct',
          );
          var socketCalls = 0;
          final service = SshService(
            knownHostsRepository: KnownHostsRepository(db),
            socketConnector: (host, port, {timeout}) async {
              socketCalls++;
              throw StateError('must parse before opening sockets');
            },
          );
          final result = await service.connect(
            SshConnectionConfig(
              hostname: 'destination',
              port: 22,
              username: 'test',
              privateKey: generated.privateKeyPem,
              passphrase: passphrase,
              jumpHost: const SshConnectionConfig(
                hostname: 'jump',
                port: 22,
                username: 'test',
              ),
            ),
          );
          expect(result.success, isFalse);
          expect(result.error, contains('passphrase'));
          expect(socketCalls, 0);
        },
      );
    }

    test(
      'skips unusable auto identities and authenticates with a usable key',
      () async {
        final fixture = await _AuthenticationFixture.create(
          hostname: 'destination',
          keyBytes: [1, 2, 3],
        );
        final generated = await generateOpenSshKey(
          keyType: SshKeyType.ed25519,
          comment: 'test',
          passphrase: 'correct',
        );
        SshKey identity(int id, String pem, String? passphrase) => SshKey(
          id: id,
          name: 'test',
          keyType: 'ssh-ed25519',
          publicKey: '',
          privateKey: pem,
          passphrase: passphrase,
          createdAt: DateTime(2026),
        );
        final result = await fixture.service.connect(
          SshConnectionConfig(
            hostname: 'destination',
            port: 22,
            username: 'test',
            identityKeys: [
              identity(1, 'invalid PEM', null),
              identity(2, generated.privateKeyPem, null),
              identity(3, generated.privateKeyPem, 'incorrect'),
              identity(4, generated.privateKeyPem, 'correct'),
            ],
          ),
        );
        expect(result.success, isTrue);
        expect(fixture.capturedIdentities, hasLength(1));
        expect(
          fixture.capturedIdentities!.single.toPublicKey().encode(),
          generated.publicKeyBlob,
        );
        await result.closeAll();
      },
    );

    for (final phase in ['trusted', 'untrusted', 'probe', 'jump']) {
      test(
        'client factory failure cleans acquired resources during $phase',
        () async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final repository = KnownHostsRepository(db);
          final hostKey = _ed25519HostKeyBlob([1, 2, 3]);
          if (phase == 'trusted' || phase == 'jump') {
            await _seedTrustedHost(
              repository,
              hostname: 'destination',
              hostKeyBytes: hostKey,
            );
          }
          if (phase == 'jump') {
            await _seedTrustedHost(
              repository,
              hostname: 'jump',
              hostKeyBytes: hostKey,
            );
          }
          final endpoint = _FakeForwardHostKeySocket(hostKey);
          final jump = _MockSshClient();
          when(() => jump.authenticated).thenAnswer((_) async {});
          when(jump.close).thenAnswer((_) async {});
          when(
            () => jump.forwardLocal('destination', 22),
          ).thenAnswer((_) async => endpoint);
          final failure = StateError('client construction failed');
          final service = SshService(
            knownHostsRepository: repository,
            hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
            socketConnector: (host, port, {timeout}) async => host == 'jump'
                ? _FakeHostKeySocket(hostKey)
                : phase == 'probe'
                ? _DestroyTrackingSocket(endpoint)
                : endpoint,
            clientFactory:
                (
                  socket, {
                  required username,
                  onVerifyHostKey,
                  onPasswordRequest,
                  onUserInfoRequest,
                  identities,
                  keepAliveInterval,
                }) {
                  if (phase == 'jump' && !identical(socket, endpoint)) {
                    return jump;
                  }
                  throw failure;
                },
          );
          await expectLater(
            service.connect(
              SshConnectionConfig(
                hostname: 'destination',
                port: 22,
                username: 'test',
                jumpHost: phase == 'jump'
                    ? const SshConnectionConfig(
                        hostname: 'jump',
                        port: 22,
                        username: 'test',
                      )
                    : null,
              ),
            ),
            throwsA(same(failure)),
          );
          if (phase == 'probe') {
            expect(endpoint.closeCalls, 1);
          } else {
            expect(endpoint.destroyed, isTrue);
          }
          if (phase == 'jump') verify(jump.close).called(1);
        },
      );
    }

    test(
      'connect prompts for unknown host before auth client creation',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final hostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
        final sockets = [
          _FakeHostKeySocket(hostKeyBytes),
          _FakeHostKeySocket(hostKeyBytes),
        ];
        final client = _MockSshClient();
        var socketIndex = 0;
        var promptCount = 0;
        var clientFactoryCalls = 0;

        when(client.close).thenAnswer((_) async {});

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (request) async {
            promptCount++;
            expect(request.isReplacement, isFalse);
            expect(clientFactoryCalls, 0);
            return HostKeyTrustDecision.trust;
          },
          socketConnector: (host, port, {timeout}) async {
            expect(host, 'new.example.com');
            expect(port, 22);
            return sockets[socketIndex++];
          },
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                onUserInfoRequest,
                identities,
                keepAliveInterval,
              }) {
                clientFactoryCalls++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                  expect(trusted, isTrue);
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'new.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isTrue);
        expect(socketIndex, 2);
        expect(promptCount, 1);
        expect(clientFactoryCalls, 1);
        expect(
          await knownHostsRepository.getByHost('new.example.com', 22),
          isNotNull,
        );
      },
    );

    test('connect rejects unknown host without starting auth', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final socket = _FakeHostKeySocket(_ed25519HostKeyBlob([1, 2, 3]));
      var clientFactoryCalls = 0;

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.reject,
        socketConnector: (host, port, {timeout}) async => socket,
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              clientFactoryCalls++;
              return _MockSshClient();
            },
      );

      const config = SshConnectionConfig(
        hostname: 'reject.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isFalse);
      expect(result.error, contains('not trusted yet'));
      expect(clientFactoryCalls, 0);
      expect(
        await knownHostsRepository.getByHost('reject.example.com', 22),
        isNull,
      );
    });

    test('connect accepts pretrusted host without prompting', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final hostKeyBytes = _ed25519HostKeyBlob([4, 5, 6]);
      final trustedHostKey = VerifiedHostKey(
        hostname: 'trusted.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: hostKeyBytes,
      );
      await knownHostsRepository.upsertTrustedHost(
        hostname: trustedHostKey.hostname,
        port: trustedHostKey.port,
        keyType: trustedHostKey.trustedKeyType,
        fingerprint: trustedHostKey.fingerprint,
        encodedHostKey: trustedHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final sockets = [_FakeHostKeySocket(hostKeyBytes)];
      final client = _MockSshClient();
      var socketIndex = 0;
      var promptCount = 0;
      var clientFactoryCalls = 0;

      when(client.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async {
          promptCount++;
          return HostKeyTrustDecision.reject;
        },
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              clientFactoryCalls++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await (socket as HostKeySource).hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  _hostKeyCallbackFingerprint(bytes),
                );
                expect(trusted, isTrue);
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'trusted.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketIndex, 1);
      expect(clientFactoryCalls, 1);
      expect(promptCount, 0);
    });

    test('connect prompts interactively when host has no password', () async {
      SshAuthChallenge? seenChallenge;

      final fixture = await _AuthenticationFixture.create(
        hostname: 'prompt.example.com',
        keyBytes: [9, 9, 9],
        promptHandler: (challenge) async {
          seenChallenge = challenge;
          return ['typed-secret'];
        },
      );

      const config = SshConnectionConfig(
        hostname: 'prompt.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await fixture.service.connect(config);

      expect(result.success, isTrue);
      // Password auth is enabled and answered by the interactive prompt.
      expect(fixture.capturedPassword, isNotNull);
      expect(await fixture.capturedPassword!(), 'typed-secret');
      expect(seenChallenge, isNotNull);
      expect(seenChallenge!.hostLabel, 'tester@prompt.example.com:22');
      expect(seenChallenge!.prompts, hasLength(1));
      expect(seenChallenge!.prompts.single.echo, isFalse);
      // Keyboard-interactive is also enabled so PAM logins can be answered.
      expect(fixture.capturedUserInfo, isNotNull);
    });

    test('connect uses stored password without prompting', () async {
      var promptCalls = 0;

      final fixture = await _AuthenticationFixture.create(
        hostname: 'stored.example.com',
        keyBytes: [8, 8, 8],
        promptHandler: (challenge) async {
          promptCalls++;
          return null;
        },
      );

      const config = SshConnectionConfig(
        hostname: 'stored.example.com',
        port: 22,
        username: 'tester',
        password: 'stored-pass',
      );

      final result = await fixture.service.connect(config);

      expect(result.success, isTrue);
      expect(fixture.capturedPassword, isNotNull);
      expect(await fixture.capturedPassword!(), 'stored-pass');
      // A single hidden keyboard-interactive prompt reuses the stored
      // password instead of prompting the user.
      expect(fixture.capturedUserInfo, isNotNull);
      expect(
        await fixture.capturedUserInfo!(
          SSHUserInfoRequest('', '', [SSHUserInfoPrompt('Password:', false)]),
        ),
        ['stored-pass'],
      );
      expect(promptCalls, 0);
    });

    test(
      'connect leaves password auth disabled without a prompt handler',
      () async {
        final fixture = await _AuthenticationFixture.create(
          hostname: 'nohandler.example.com',
          keyBytes: [7, 7, 7],
        );

        const config = SshConnectionConfig(
          hostname: 'nohandler.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await fixture.service.connect(config);

        expect(result.success, isTrue);
        expect(fixture.capturedPassword, isNull);
        expect(fixture.capturedUserInfo, isNull);
      },
    );

    test(
      'connect maps keyboard-interactive prompts to the interactive handler',
      () async {
        SshAuthChallenge? seenChallenge;

        final fixture = await _AuthenticationFixture.create(
          hostname: 'kbi.example.com',
          keyBytes: [6, 6, 6],
          promptHandler: (challenge) async {
            seenChallenge = challenge;
            return ['otp-123', 'kbi-pass'];
          },
        );

        const config = SshConnectionConfig(
          hostname: 'kbi.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await fixture.service.connect(config);

        expect(result.success, isTrue);
        expect(fixture.capturedUserInfo, isNotNull);
        final responses = await fixture.capturedUserInfo!(
          SSHUserInfoRequest('Two-factor', 'Enter your codes', [
            SSHUserInfoPrompt('Token:', true),
            SSHUserInfoPrompt('Password:', false),
          ]),
        );
        expect(responses, ['otp-123', 'kbi-pass']);
        expect(seenChallenge, isNotNull);
        expect(seenChallenge!.name, 'Two-factor');
        expect(seenChallenge!.instruction, 'Enter your codes');
        expect(seenChallenge!.prompts, hasLength(2));
        expect(seenChallenge!.prompts[0].prompt, 'Token:');
        expect(seenChallenge!.prompts[0].echo, isTrue);
        expect(seenChallenge!.prompts[1].prompt, 'Password:');
        expect(seenChallenge!.prompts[1].echo, isFalse);
      },
    );

    test(
      'connect only reuses the stored password for a real password prompt',
      () async {
        var promptCalls = 0;

        final fixture = await _AuthenticationFixture.create(
          hostname: 'pam.example.com',
          keyBytes: [5, 5, 5],
          promptHandler: (challenge) async {
            promptCalls++;
            return ['user-entered'];
          },
        );

        const config = SshConnectionConfig(
          hostname: 'pam.example.com',
          port: 22,
          username: 'tester',
          password: 'stored-pass',
        );

        final result = await fixture.service.connect(config);
        expect(result.success, isTrue);
        expect(fixture.capturedUserInfo, isNotNull);

        // A plain password prompt reuses the stored password without prompting.
        expect(
          await fixture.capturedUserInfo!(
            SSHUserInfoRequest('', '', [SSHUserInfoPrompt('Password:', false)]),
          ),
          ['stored-pass'],
        );
        expect(promptCalls, 0);

        // A one-time-code prompt must reach the user, not receive the password.
        expect(
          await fixture.capturedUserInfo!(
            SSHUserInfoRequest('', '', [
              SSHUserInfoPrompt('Verification code:', false),
            ]),
          ),
          ['user-entered'],
        );
        expect(promptCalls, 1);

        // A forced password-change prompt must also reach the user.
        expect(
          await fixture.capturedUserInfo!(
            SSHUserInfoRequest('', 'You are required to change your password', [
              SSHUserInfoPrompt('New password:', false),
            ]),
          ),
          ['user-entered'],
        );
        expect(promptCalls, 2);
      },
    );

    test(
      'connect answers a zero-prompt keyboard-interactive request emptily',
      () async {
        var promptCalls = 0;

        final fixture = await _AuthenticationFixture.create(
          hostname: 'banner.example.com',
          keyBytes: [4, 4, 4],
          promptHandler: (challenge) async {
            promptCalls++;
            return null;
          },
        );

        const config = SshConnectionConfig(
          hostname: 'banner.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await fixture.service.connect(config);
        expect(result.success, isTrue);
        expect(fixture.capturedUserInfo, isNotNull);

        // An informational (zero-prompt) request is answered with no responses
        // and must not surface an empty credential dialog.
        expect(
          await fixture.capturedUserInfo!(
            SSHUserInfoRequest('Notice', 'Welcome to the server', const []),
          ),
          isEmpty,
        );
        expect(promptCalls, 0);
      },
    );

    test('connect replaces a changed trusted host key after prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final originalHostKey = VerifiedHostKey(
        hostname: 'replace-success.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
      );
      final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
      final changedHostKey = VerifiedHostKey(
        hostname: 'replace-success.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: changedHostKeyBytes,
      );
      await knownHostsRepository.upsertTrustedHost(
        hostname: originalHostKey.hostname,
        port: originalHostKey.port,
        keyType: originalHostKey.trustedKeyType,
        fingerprint: originalHostKey.fingerprint,
        encodedHostKey: originalHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final sockets = [
        _FakeHostKeySocket(changedHostKeyBytes),
        _FakeHostKeySocket(changedHostKeyBytes),
      ];
      final firstClient = _MockSshClient();
      final retryClient = _MockSshClient();
      var socketIndex = 0;
      var clientIndex = 0;
      var promptCount = 0;

      when(firstClient.close).thenAnswer((_) async {});
      when(retryClient.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (request) async {
          promptCount++;
          expect(request.isReplacement, isTrue);
          expect(request.existingKnownHost, isNotNull);
          return HostKeyTrustDecision.replace;
        },
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              final client = clientIndex == 0 ? firstClient : retryClient;
              clientIndex++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await (socket as HostKeySource).hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  _hostKeyCallbackFingerprint(bytes),
                );
                if (!trusted) {
                  return Future<void>.error(
                    SSHHostkeyError('Hostkey verification failed'),
                  );
                }
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'replace-success.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketIndex, 2);
      expect(clientIndex, 2);
      expect(promptCount, 1);
      final storedHost = await knownHostsRepository.getByHost(
        'replace-success.example.com',
        22,
      );
      expect(storedHost, isNotNull);
      expect(storedHost!.hostKey, changedHostKey.encodedHostKey);
      expect(storedHost.fingerprint, changedHostKey.fingerprint);
    });

    test(
      'connect rejects a changed trusted host key without retrying',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final originalHostKey = VerifiedHostKey(
          hostname: 'replace-reject.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
        );
        final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
        await knownHostsRepository.upsertTrustedHost(
          hostname: originalHostKey.hostname,
          port: originalHostKey.port,
          keyType: originalHostKey.trustedKeyType,
          fingerprint: originalHostKey.fingerprint,
          encodedHostKey: originalHostKey.encodedHostKey,
          resetFirstSeen: true,
        );
        final socket = _FakeHostKeySocket(changedHostKeyBytes);
        final client = _MockSshClient();
        var socketCount = 0;
        var clientFactoryCalls = 0;
        var promptCount = 0;

        when(client.close).thenAnswer((_) async {});

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (request) async {
            promptCount++;
            expect(request.isReplacement, isTrue);
            return HostKeyTrustDecision.reject;
          },
          socketConnector: (host, port, {timeout}) async {
            socketCount++;
            return socket;
          },
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                onUserInfoRequest,
                identities,
                keepAliveInterval,
              }) {
                clientFactoryCalls++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                  if (!trusted) {
                    return Future<void>.error(
                      SSHHostkeyError('Hostkey verification failed'),
                    );
                  }
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'replace-reject.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(result.error, contains('changed'));
        expect(socketCount, 1);
        expect(clientFactoryCalls, 1);
        expect(promptCount, 1);
        final storedHost = await knownHostsRepository.getByHost(
          'replace-reject.example.com',
          22,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
      },
    );

    test('connect fails if host key changes after trust prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final probeHostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
      final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
      final sockets = [
        _FakeHostKeySocket(probeHostKeyBytes),
        _FakeHostKeySocket(changedHostKeyBytes),
      ];
      final client = _MockSshClient();
      var socketIndex = 0;

      when(client.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await (socket as HostKeySource).hostKeyBytes;
                await onVerifyHostKey!(
                  'ssh-ed25519',
                  _hostKeyCallbackFingerprint(bytes),
                );
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'race.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isFalse);
      expect(result.error, contains('changed between verification'));
    });

    test(
      'refused jump-host forward returns a failed connection through cancellation guard',
      () async {
        final fixture = await _AuthenticationFixture.create(
          hostname: 'jump.example.com',
          keyBytes: [1, 2, 3],
        );
        when(
          () => fixture.client.forwardLocal('target.example.com', 22),
        ).thenAnswer(
          (_) => Future<SSHForwardChannel>.error(
            SSHChannelOpenError(1, 'administratively prohibited'),
          ),
        );
        final result = await fixture.service.connect(
          const SshConnectionConfig(
            hostname: 'target.example.com',
            port: 22,
            username: 'tester',
            jumpHost: SshConnectionConfig(
              hostname: 'jump.example.com',
              port: 22,
              username: 'tester',
            ),
          ),
          cancellationToken: SshConnectionCancellationToken(),
        );
        expect(result.success, isFalse);
        expect(result.error, contains('refused the tunnel'));
        verify(fixture.client.close).called(1);
      },
    );

    test(
      'cancelled channel open consumes late refusal and teardown failure',
      () async {
        final token = SshConnectionCancellationToken();
        final opening = Completer<SSHForwardChannel>();
        final guarded = token.guard(opening.future);
        final checked = expectLater(
          guarded,
          throwsA(isA<SshConnectionCancelledException>()),
        );
        token.cancel();
        await checked;
        opening.completeError(SSHChannelOpenError(1, 'refused'));
        await Future<void>.delayed(Duration.zero);

        final lateChannel = Completer<SSHForwardChannel>();
        final cleanup = token.guard(
          lateChannel.future,
          onAbandonedValue: (_) {
            // ignore: only_throw_errors
            throw SSHStateError('Transport is closed');
          },
        );
        await expectLater(
          cleanup,
          throwsA(isA<SshConnectionCancelledException>()),
        );
        lateChannel.complete(_SingleCloseForwardChannel());
        await Future<void>.delayed(Duration.zero);
      },
    );

    test('connect verifies jump-host and destination host keys', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final jumpSocket = _FakeHostKeySocket(_ed25519HostKeyBlob([1, 2, 3]));
      final targetSocket = _FakeForwardHostKeySocket(
        _ed25519HostKeyBlob([4, 5, 6]),
      );
      final jumpClient = _MockSshClient();
      final targetClient = _MockSshClient();
      var clientIndex = 0;

      when(
        () => jumpClient.forwardLocal('target.example.com', 22),
      ).thenAnswer(_returnTargetSocket(targetSocket));
      when(jumpClient.close).thenAnswer((_) async {});
      when(targetClient.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
        socketConnector: (host, port, {timeout}) async {
          expect(host, 'jump.example.com');
          expect(port, 2222);
          return jumpSocket;
        },
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              final client = clientIndex == 0 ? jumpClient : targetClient;
              final hostKeyBytes = socket is HostKeySource
                  ? (socket as HostKeySource).hostKeyBytes
                  : Future<Uint8List>.value(Uint8List(0));
              if (clientIndex == 0) {
                when(() => jumpClient.authenticated).thenAnswer((_) async {
                  final bytes = await hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                });
              } else {
                when(() => targetClient.authenticated).thenAnswer((_) async {
                  final bytes = await hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                });
              }
              clientIndex++;
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'target.example.com',
        port: 22,
        username: 'target',
        jumpHost: SshConnectionConfig(
          hostname: 'jump.example.com',
          port: 2222,
          username: 'jump',
        ),
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(
        await knownHostsRepository.getByHost('jump.example.com', 2222),
        isNotNull,
      );
      expect(
        await knownHostsRepository.getByHost('target.example.com', 22),
        isNotNull,
      );
    });

    test('connect uses one connection per pretrusted jump-host hop', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final jumpHostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
      final targetHostKeyBytes = _ed25519HostKeyBlob([4, 5, 6]);
      final jumpHostKey = VerifiedHostKey(
        hostname: 'jump-trusted.example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        hostKeyBytes: jumpHostKeyBytes,
      );
      final targetHostKey = VerifiedHostKey(
        hostname: 'target-trusted.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: targetHostKeyBytes,
      );
      for (final hostKey in [jumpHostKey, targetHostKey]) {
        await knownHostsRepository.upsertTrustedHost(
          hostname: hostKey.hostname,
          port: hostKey.port,
          keyType: hostKey.trustedKeyType,
          fingerprint: hostKey.fingerprint,
          encodedHostKey: hostKey.encodedHostKey,
          resetFirstSeen: true,
        );
      }

      final jumpSocket = _FakeHostKeySocket(jumpHostKeyBytes);
      final targetSocket = _FakeForwardHostKeySocket(targetHostKeyBytes);
      final jumpClient = _MockSshClient();
      final targetClient = _MockSshClient();
      var socketConnectCount = 0;
      var forwardCount = 0;
      var clientIndex = 0;
      var promptCount = 0;

      when(
        () => jumpClient.forwardLocal('target-trusted.example.com', 22),
      ).thenAnswer((_) async {
        forwardCount++;
        return targetSocket;
      });
      when(jumpClient.close).thenAnswer((_) async {});
      when(targetClient.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async {
          promptCount++;
          return HostKeyTrustDecision.reject;
        },
        socketConnector: (host, port, {timeout}) async {
          expect(host, 'jump-trusted.example.com');
          expect(port, 2222);
          socketConnectCount++;
          return jumpSocket;
        },
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              final client = clientIndex == 0 ? jumpClient : targetClient;
              final hostKeyBytes = (socket as HostKeySource).hostKeyBytes;
              clientIndex++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  _hostKeyCallbackFingerprint(bytes),
                );
                expect(trusted, isTrue);
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'target-trusted.example.com',
        port: 22,
        username: 'target',
        jumpHost: SshConnectionConfig(
          hostname: 'jump-trusted.example.com',
          port: 2222,
          username: 'jump',
        ),
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketConnectCount, 1);
      expect(forwardCount, 1);
      expect(clientIndex, 2);
      expect(promptCount, 0);
    });

    test(
      'connect persists accepted TOFU trust before authentication succeeds',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final socket = _FakeHostKeySocket(_ed25519HostKeyBlob([7, 8, 9]));
        final client = _MockSshClient();

        when(client.close).thenAnswer((_) async {});

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
          socketConnector: (host, port, {timeout}) async => socket,
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                onUserInfoRequest,
                identities,
                keepAliveInterval,
              }) {
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                  return Future<void>.error(
                    SSHAuthFailError('Authentication failed'),
                  );
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'persist.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(
          await knownHostsRepository.getByHost('persist.example.com', 22),
          isNotNull,
        );
      },
    );

    test(
      'connect preserves an existing host key when replacement auth fails',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final originalHostKey = VerifiedHostKey(
          hostname: 'replace.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
        );
        await knownHostsRepository.upsertTrustedHost(
          hostname: originalHostKey.hostname,
          port: originalHostKey.port,
          keyType: originalHostKey.trustedKeyType,
          fingerprint: originalHostKey.fingerprint,
          encodedHostKey: originalHostKey.encodedHostKey,
          resetFirstSeen: true,
        );

        final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
        final sockets = [
          _FakeHostKeySocket(changedHostKeyBytes),
          _FakeHostKeySocket(changedHostKeyBytes),
        ];
        final firstClient = _MockSshClient();
        final retryClient = _MockSshClient();
        var socketIndex = 0;
        var clientIndex = 0;

        when(firstClient.close).thenAnswer((_) async {});
        when(retryClient.close).thenAnswer((_) async {});

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (_) async => HostKeyTrustDecision.replace,
          socketConnector: (host, port, {timeout}) async =>
              sockets[socketIndex++],
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                onUserInfoRequest,
                identities,
                keepAliveInterval,
              }) {
                final client = clientIndex == 0 ? firstClient : retryClient;
                final shouldFailAuth = clientIndex == 1;
                clientIndex++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    _hostKeyCallbackFingerprint(bytes),
                  );
                  if (!trusted) {
                    return Future<void>.error(
                      SSHHostkeyError('Hostkey verification failed'),
                    );
                  }
                  if (shouldFailAuth) {
                    return Future<void>.error(
                      SSHAuthFailError('Authentication failed'),
                    );
                  }
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'replace.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(socketIndex, 2);
        expect(clientIndex, 2);
        final storedHost = await knownHostsRepository.getByHost(
          'replace.example.com',
          22,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
        expect(storedHost.fingerprint, originalHostKey.fingerprint);
      },
    );

    test('sessions map is unmodifiable', () {
      expect(() => sshService.sessions.clear(), throwsUnsupportedError);
    });
  });

  group('connectToHost SSID-based jump host bypass', () {
    Future<int> seedHostWithJump(
      AppDatabase db, {
      String? skipJumpHostOnSsids,
    }) async {
      final jumpHostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Bastion',
              hostname: 'bastion.example.com',
              username: 'bastion',
            ),
          );
      return db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Target',
              hostname: 'target.example.com',
              username: 'target',
              jumpHostId: Value(jumpHostId),
              skipJumpHostOnSsids: Value(skipJumpHostOnSsids),
            ),
          );
    }

    test('uses jump host when no SSIDs are configured', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('home');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db);
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 0);
      expect(wifiNetworkService.getCurrentSsidCallCount, 0);
    });

    test('uses jump host when current SSID is not in skip list', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('cafe');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(
        db,
        skipJumpHostOnSsids: 'home\noffice',
      );
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(service.capturedConfig?.hostname, 'target.example.com');
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
    });

    test('skips jump host when current SSID is in skip list', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('home');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(
        db,
        skipJumpHostOnSsids: 'home\noffice',
      );
      await service.connectToHost(hostId);

      expect(service.capturedConfig, isNotNull);
      expect(service.capturedConfig!.jumpHost, isNull);
      expect(service.capturedConfig!.hostname, 'target.example.com');
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
    });

    test('uses jump host when Wi-Fi permission is denied', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService(
        'home',
        permissionStatus: WifiPermissionStatus.denied,
      );
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db, skipJumpHostOnSsids: 'home');
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 0);
    });

    test('uses jump host when SSID detection returns null', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService(null);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db, skipJumpHostOnSsids: 'home');
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
    });
  });

  group('connection cancellation', () {
    test('cancels a stalled socket connection without waiting', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final socketRequested = Completer<void>();
      final stalledSocket = Completer<SSHSocket>();
      addTearDown(() {
        if (!stalledSocket.isCompleted) {
          stalledSocket.complete(_FakeHostKeySocket(_ed25519HostKeyBlob([9])));
        }
      });
      var clientFactoryCalls = 0;

      final service = SshService(
        knownHostsRepository: KnownHostsRepository(db),
        socketConnector: (host, port, {timeout}) {
          if (!socketRequested.isCompleted) {
            socketRequested.complete();
          }
          return stalledSocket.future;
        },
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              clientFactoryCalls++;
              return _MockSshClient();
            },
      );

      final token = SshConnectionCancellationToken();
      const config = SshConnectionConfig(
        hostname: 'stalled.example.com',
        port: 22,
        username: 'tester',
        connectionTimeout: Duration(minutes: 10),
      );

      final pending = service.connect(config, cancellationToken: token);
      await socketRequested.future;
      token.cancel();
      final result = await pending;

      expect(result.cancelled, isTrue);
      expect(result.success, isFalse);
      expect(result.error, 'Connection cancelled');
      expect(clientFactoryCalls, 0);
    });

    test('destroys a socket that arrives after cancellation', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final socketRequested = Completer<void>();
      final stalledSocket = Completer<SSHSocket>();
      final lateSocket = _DestroyTrackingSocket(
        _FakeHostKeySocket(_ed25519HostKeyBlob([3, 2, 1])),
      );

      final service = SshService(
        knownHostsRepository: KnownHostsRepository(db),
        socketConnector: (host, port, {timeout}) {
          if (!socketRequested.isCompleted) {
            socketRequested.complete();
          }
          return stalledSocket.future;
        },
      );

      final token = SshConnectionCancellationToken();
      const config = SshConnectionConfig(
        hostname: 'late-socket.example.com',
        port: 22,
        username: 'tester',
      );

      final pending = service.connect(config, cancellationToken: token);
      await socketRequested.future;
      token.cancel();
      final result = await pending;
      stalledSocket.complete(lateSocket);
      await pumpEventQueue();

      expect(result.cancelled, isTrue);
      expect(lateSocket.destroyed, isTrue);
    });

    test('cancels a stalled authentication and closes the client', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final hostKeyBytes = _ed25519HostKeyBlob([7, 7, 7]);
      await _seedTrustedHost(
        knownHostsRepository,
        hostname: 'slow-auth.example.com',
        hostKeyBytes: hostKeyBytes,
      );
      final client = _MockSshClient();
      final authenticationStarted = Completer<void>();
      when(() => client.authenticated).thenAnswer((_) {
        if (!authenticationStarted.isCompleted) {
          authenticationStarted.complete();
        }
        return Completer<void>().future;
      });
      when(client.close).thenAnswer((_) async {});

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        socketConnector: (host, port, {timeout}) async =>
            _FakeHostKeySocket(hostKeyBytes),
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) => client,
      );

      final token = SshConnectionCancellationToken();
      const config = SshConnectionConfig(
        hostname: 'slow-auth.example.com',
        port: 22,
        username: 'tester',
        connectionTimeout: Duration(minutes: 10),
      );

      final pending = service.connect(config, cancellationToken: token);
      await authenticationStarted.future;
      token.cancel();
      final result = await pending;

      expect(result.cancelled, isTrue);
      expect(result.client, isNull);
      verify(client.close).called(1);
    });

    test(
      'returns cancelled before connecting when already cancelled',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        var socketConnectorCalls = 0;

        final service = SshService(
          knownHostsRepository: KnownHostsRepository(db),
          socketConnector: (host, port, {timeout}) async {
            socketConnectorCalls++;
            return _FakeHostKeySocket(_ed25519HostKeyBlob([1]));
          },
        );

        final token = SshConnectionCancellationToken()..cancel();
        const config = SshConnectionConfig(
          hostname: 'precancelled.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config, cancellationToken: token);

        expect(result.cancelled, isTrue);
        expect(socketConnectorCalls, 0);
      },
    );

    test('connectToHost does not register a cancelled session', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final hostId = await hostRepo.insert(
        HostsCompanion.insert(
          label: 'stalled',
          hostname: 'stalled.example.com',
          username: 'tester',
        ),
      );
      final socketRequested = Completer<void>();
      final stalledSocket = Completer<SSHSocket>();
      addTearDown(() {
        if (!stalledSocket.isCompleted) {
          stalledSocket.complete(_FakeHostKeySocket(_ed25519HostKeyBlob([5])));
        }
      });

      final service = SshService(
        hostRepository: hostRepo,
        keyRepository: KeyRepository(db, encryption),
        knownHostsRepository: KnownHostsRepository(db),
        socketConnector: (host, port, {timeout}) {
          if (!socketRequested.isCompleted) {
            socketRequested.complete();
          }
          return stalledSocket.future;
        },
      );

      final token = SshConnectionCancellationToken();
      final pending = service.connectToHost(hostId, cancellationToken: token);
      await socketRequested.future;
      token.cancel();
      final result = await pending;

      expect(result.cancelled, isTrue);
      expect(result.connectionId, isNull);
      expect(service.sessions, isEmpty);
    });
  });
}

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final typeBytes = utf8.encode('ssh-ed25519');
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32(keyData.length))
    ..add(keyData);
  return writer.takeBytes();
}

Uint8List _hostKeyCallbackFingerprint(List<int> hostKeyBytes) =>
    Uint8List.fromList(utf8.encode(formatSshHostKeyFingerprint(hostKeyBytes)));

Future<void> _seedTrustedHost(
  KnownHostsRepository repository, {
  required String hostname,
  required Uint8List hostKeyBytes,
  int port = 22,
}) async {
  final trusted = VerifiedHostKey(
    hostname: hostname,
    port: port,
    keyType: 'ssh-ed25519',
    hostKeyBytes: hostKeyBytes,
  );
  await repository.upsertTrustedHost(
    hostname: trusted.hostname,
    port: trusted.port,
    keyType: trusted.trustedKeyType,
    fingerprint: trusted.fingerprint,
    encodedHostKey: trusted.encodedHostKey,
    resetFirstSeen: true,
  );
}

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

Uint8List _sshString(List<int> value) {
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(value.length))
    ..add(value);
  return writer.takeBytes();
}

Uint8List _sshMessageWithHostKey(int messageId, Uint8List hostKey) {
  final writer = BytesBuilder(copy: false)
    ..add([messageId])
    ..add(_sshString(hostKey))
    ..add(_sshString(const <int>[0, 1, 2, 3]))
    ..add(_sshString(const <int>[4, 5, 6, 7]));
  return writer.takeBytes();
}

Uint8List _sshBinaryPacket(Uint8List payload) {
  const paddingLength = 4;
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(payload.length + paddingLength + 1))
    ..add([paddingLength])
    ..add(payload)
    ..add(const <int>[0, 0, 0, 0]);
  return writer.takeBytes();
}

Uint8List _oversizedPacketHeader() =>
    Uint8List.fromList([0x00, 0x04, 0x00, 0x01, 0x04]);

Answer<Future<SSHForwardChannel>> _returnTargetSocket(
  SSHForwardChannel socket,
) =>
    (_) async => socket;
