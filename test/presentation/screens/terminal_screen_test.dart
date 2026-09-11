// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/routes.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/device_debug_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/remote_multiplexer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/controllers/system_keyboard_visibility_controller.dart';
import 'package:monkeyssh/presentation/screens/port_forward_browser_screen.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_native_badge.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:xterm/xterm.dart';

import '../../helpers/fake_wakelock_plus_platform.dart';
import '../../helpers/terminal_screen_mux_fixture.dart';
import '../../support/fake_acp_session_manager.dart';

const _deleteDetectionMarker = '\u200B\u200B';
String _trueColorLoginShellCommand(
  SshConnectionConfig config, {
  int hostId = 1,
}) =>
    'exec env COLORTERM=truecolor TERM_PROGRAM=kitty KITTY_WINDOW_ID=1 '
    'FORCE_HYPERLINK=1 '
    'MONKEYSSH_SHELL_TOKEN=${buildSshShellLineageToken(config, hostId: hostId)} '
    r"""/bin/sh -lc 'if [ -n "$SHELL" ]; then exec "$SHELL" -l; else exec /bin/sh; fi'""";

void _stubTrueColorLoginShell(
  SSHClient client,
  SSHSession shell, {
  SshConnectionConfig config = const SshConnectionConfig(
    hostname: 'terminal.example.com',
    port: 22,
    username: 'root',
  ),
  VoidCallback? onOpen,
}) {
  when(
    () => client.execute(
      _trueColorLoginShellCommand(config),
      pty: any(named: 'pty'),
    ),
  ).thenAnswer((_) async {
    onOpen?.call();
    return shell;
  });
}

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

class _MockShellChannel extends Mock implements SSHSession {}

class _ListenerTrackingTerminal extends Terminal {
  final listeners = <VoidCallback>{};
  int listenerRegistrations = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerRegistrations++;
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

class _LifecycleSshSession extends SshSession {
  _LifecycleSshSession(SshSession source)
    : super(
        connectionId: source.connectionId,
        hostId: source.hostId,
        client: source.client,
        config: source.config,
      );

  Future<void> completeAfterDisposal(
    WidgetTester tester,
    VoidCallback complete,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final registrations = trackedTerminal.listenerRegistrations;
    final reads = streamReads;
    final output = trackedTerminal.onOutput;
    final resize = trackedTerminal.onResize;
    complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(trackedTerminal.listeners, isEmpty);
    expect(trackedTerminal.listenerRegistrations, registrations);
    expect(streamReads, reads);
    expect(trackedTerminal.onOutput, same(output));
    expect(trackedTerminal.onResize, same(resize));
  }

  final trackedTerminal = _ListenerTrackingTerminal();
  bool hasTerminal = false;
  Future<void>? pendingClose;
  Future<void>? pendingOpen;
  int delayedOpenNumber = 1;
  int openCalls = 0;
  int closeCalls = 0;
  int streamReads = 0;
  TerminalShellStatus? forcedShellStatus;

  @override
  TerminalShellStatus? get shellStatus =>
      forcedShellStatus ?? super.shellStatus;

  @override
  Terminal? get terminal => hasTerminal ? trackedTerminal : null;

  @override
  Terminal getOrCreateTerminal({int maxLines = 10000}) {
    super.getOrCreateTerminal(maxLines: maxLines);
    hasTerminal = true;
    return trackedTerminal;
  }

  @override
  Stream<void> get shellDoneStream {
    streamReads++;
    return super.shellDoneStream;
  }

  @override
  Stream<void> get shellCommandCompletedStream {
    streamReads++;
    return super.shellCommandCompletedStream;
  }

  @override
  Stream<String> get shellStdoutStream {
    streamReads++;
    return super.shellStdoutStream;
  }

  @override
  Future<void> closeShell({bool waitForStreams = true}) async {
    closeCalls++;
    await pendingClose;
    await super.closeShell(waitForStreams: waitForStreams);
  }

  @override
  Future<SSHSession> getShell({
    SSHPtyConfig? pty,
    bool requestPty = true,
    bool forceNew = false,
    String? command,
    bool returnToLoginShell = false,
  }) async {
    openCalls++;
    if (openCalls == delayedOpenNumber) await pendingOpen;
    return super.getShell(
      pty: pty,
      requestPty: requestPty,
      forceNew: forceNew,
      command: command,
      returnToLoginShell: returnToLoginShell,
    );
  }
}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _MockAgentManagementService extends Mock
    implements AgentManagementService {}

Future<void> _completeSftpClose(Invocation _) async {}

class _MockRemoteFileService extends Mock implements RemoteFileService {}

class _MockSftpClient extends Mock implements SftpClient {
  _MockSftpClient() {
    when(close).thenAnswer(_completeSftpClose);
  }
}

class _FakeAndroidDeviceDebugPlatform implements AndroidDeviceDebugPlatform {
  @override
  bool get supported => true;

  @override
  Stream<String> get submittedPairingCodes => const Stream<String>.empty();

  @override
  Future<bool> showPairingCodePrompt({
    required String status,
    bool busy = false,
  }) async => true;

  @override
  Future<void> hidePairingCodePrompt() async {}

  @override
  Future<bool> returnToApp({required String status}) async => true;

  @override
  Future<void> hideReturnPrompt() async {}

  @override
  Future<bool> isWirelessDebuggingSupported() async => true;

  @override
  Future<AndroidAdbEndpoint?> discoverEndpoint(
    AndroidAdbServiceKind kind, {
    Duration timeout = const Duration(seconds: 6),
  }) async => null;

  @override
  Future<bool> openDeveloperOptions() async => true;
}

class _FakeRemoteAdbCommandRunner implements RemoteAdbCommandRunner {
  @override
  Future<RemoteAdbCommandResult> connect(
    SshSession session, {
    required String address,
  }) async => const RemoteAdbCommandResult(exitCode: 1, output: '');

  @override
  Future<RemoteAdbCommandResult> disconnect(
    SshSession session, {
    required String address,
  }) async => const RemoteAdbCommandResult(exitCode: 0, output: '');

  @override
  Future<bool> isAvailable(SshSession session) async => true;

  @override
  Future<RemoteListenerScope> listenerScope(
    SshSession session,
    int port,
  ) async => RemoteListenerScope.loopback;

  @override
  Future<bool> supportsPairing(SshSession session) async => true;

  @override
  Future<RemoteAdbCommandResult> pair(
    SshSession session, {
    required String address,
    required String pairingCode,
  }) async => const RemoteAdbCommandResult(exitCode: 1, output: '');
}

class _FakeSshSession extends Fake implements SshSession {}

class _MockTmuxService extends Mock implements TmuxService {
  String? detectedVersionValue;

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  @override
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async => detectedVersionValue;
}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {
  _MockMonkeyMuxService() {
    when(
      () => selectWindow(
        any(),
        any(),
        any(),
        windowId: any(named: 'windowId'),
        extraFlags: any(named: 'extraFlags'),
        clientImageSignatures: any(named: 'clientImageSignatures'),
        suppressReplay: any(named: 'suppressReplay'),
      ),
    ).thenAnswer((_) async {});
  }

  MonkeyMuxServerStatus? runningStatus;
  Future<MonkeyMuxServerStatus?>? runningStatusFuture;
  MonkeyMuxServerStatus? installedHelpersStatus;
  String? helperVersion;
  String? detectedVersionValue;
  int installedHelperVersionCalls = 0;
  int runningServerStatusCalls = 0;
  int runningServerStatusFromInstalledHelpersCalls = 0;
  bool hasLiveControlChannelValue = false;
  bool supportsBracketedPasteControlInputValue = false;
  bool focusClientChangedValue = true;
  MonkeyMuxImageReplayResult imageReplayResult = MonkeyMuxImageReplayResult(
    served: const <int>{},
    retryableFailure: false,
  );
  final imageReplayFutures = <Future<MonkeyMuxImageReplayResult>>[];
  final controlOperations = <String>[];
  final resizeTerminalCalls =
      <({String sessionName, int columns, int rows, bool redraw})>[];
  final focusClientCalls = <({String sessionName, int columns, int rows})>[];
  final imageReplayCalls = <({String sessionName, Set<int> imageIds})>[];

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  @override
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async => detectedVersionValue;

  @override
  bool hasLiveControlChannel(SshSession session, String sessionName) =>
      hasLiveControlChannelValue;

  @override
  bool supportsBracketedPasteControlInput(
    SshSession session,
    String sessionName,
  ) => supportsBracketedPasteControlInputValue;

  @override
  Future<MonkeyMuxServerStatus?> runningServerStatus(
    SshSession session,
    MonkeyMuxInstallation installation,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    runningServerStatusCalls++;
    final statusFuture = runningStatusFuture;
    if (statusFuture != null) {
      return statusFuture;
    }
    return runningStatus;
  }

  @override
  Future<MonkeyMuxServerStatus?> runningServerStatusFromInstalledHelpers(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    runningServerStatusFromInstalledHelpersCalls++;
    return installedHelpersStatus;
  }

  @override
  Future<String?> installedHelperVersion(
    SshSession session,
    MonkeyMuxInstallation installation, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    installedHelperVersionCalls++;
    return helperVersion ?? installation.version;
  }

  @override
  Future<void> resizeTerminal(
    SshSession session,
    String sessionName, {
    required int columns,
    required int rows,
    bool redraw = false,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    controlOperations.add(redraw ? 'resize:redraw' : 'resize');
    resizeTerminalCalls.add((
      sessionName: sessionName,
      columns: columns,
      rows: rows,
      redraw: redraw,
    ));
  }

  @override
  Future<bool> focusClient(
    SshSession session,
    String sessionName, {
    required int columns,
    required int rows,
  }) async {
    controlOperations.add('focus');
    focusClientCalls.add((
      sessionName: sessionName,
      columns: columns,
      rows: rows,
    ));
    return focusClientChangedValue;
  }

  @override
  Future<MonkeyMuxImageReplayResult> requestImages(
    SshSession session,
    String sessionName,
    Iterable<int> imageIds,
  ) async {
    imageReplayCalls.add((
      sessionName: sessionName,
      imageIds: imageIds.toSet(),
    ));
    if (imageReplayFutures.isNotEmpty) {
      return imageReplayFutures.removeAt(0);
    }
    return imageReplayResult;
  }
}

class _MockMonkeyMuxInstallerService extends Mock
    implements MonkeyMuxInstallerService {}

class _PromptingMonkeyMuxInstallerService implements MonkeyMuxInstallerService {
  _PromptingMonkeyMuxInstallerService({required this.request});

  final MonkeyMuxInstallRequest request;
  final acceptedConfirmations = <bool>[];
  int ensureInstalledCalls = 0;

  @override
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    ensureInstalledCalls++;
    if (confirmInstall == null) {
      throw const MonkeyMuxInstallConfirmationRequiredException();
    }
    final accepted = await confirmInstall(request);
    acceptedConfirmations.add(accepted);
    if (!accepted) {
      throw const MonkeyMuxInstallDeclinedException();
    }
    return MonkeyMuxInstallation(
      executablePath: '/tmp/monkeymux',
      platform: request.platform,
      version: request.version,
      installedDuringCall: true,
    );
  }

  @override
  void clearCache(int connectionId) {}

  @override
  Future<String> probePlatform(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
  }) async => request.platform;
}

class _MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

class _ActiveTunnelsSshSession extends SshSession {
  _ActiveTunnelsSshSession({
    required super.connectionId,
    required super.hostId,
    required super.client,
    required super.config,
    required List<ActiveTunnelInfo> activeTunnels,
  }) : _activeTunnels = activeTunnels;

  final List<ActiveTunnelInfo> _activeTunnels;

  @override
  List<ActiveTunnelInfo> get activeTunnels => _activeTunnels;
}

class _RecordingSftpPage extends StatefulWidget {
  const _RecordingSftpPage({required this.onOpened});

  final VoidCallback onOpened;

  @override
  State<_RecordingSftpPage> createState() => _RecordingSftpPageState();
}

class _RecordingSftpPageState extends State<_RecordingSftpPage> {
  @override
  void initState() {
    super.initState();
    widget.onOpened();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('SFTP opened'));
}

class _RecordingPortForwardBrowserPage extends StatefulWidget {
  const _RecordingPortForwardBrowserPage({
    required this.launch,
    required this.onOpened,
  });

  final PortForwardBrowserLaunch launch;
  final ValueChanged<PortForwardBrowserLaunch> onOpened;

  @override
  State<_RecordingPortForwardBrowserPage> createState() =>
      _RecordingPortForwardBrowserPageState();
}

class _RecordingPortForwardBrowserPageState
    extends State<_RecordingPortForwardBrowserPage> {
  @override
  void initState() {
    super.initState();
    widget.onOpened(widget.launch);
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Forward browser opened'));
}

class _RecordingLocalNotificationService extends LocalNotificationService {
  final shownNotificationIds = <int>[];
  final clearedNotificationIds = <int>[];

  @override
  Future<void> showTmuxAlert({
    required int notificationId,
    required String title,
    required String body,
    required TmuxAlertNotificationPayload payload,
  }) async {
    shownNotificationIds.add(notificationId);
  }

  @override
  Future<void> clearTmuxAlert(int notificationId) async {
    clearedNotificationIds.add(notificationId);
  }
}

class _TestShellCompletionService extends ShellCompletionService {
  _TestShellCompletionService({
    required this.cachedSuggestions,
    this.completionSuggestions =
        const <String, List<ShellCompletionSuggestion>>{},
  });

  final List<ShellCompletionSuggestion> cachedSuggestions;
  final Map<String, List<ShellCompletionSuggestion>> completionSuggestions;
  final cachedInvocations = <ShellCompletionInvocation>[];
  final completeInvocations = <ShellCompletionInvocation>[];

  @override
  void primeHistory(SshSession session, ShellCompletionInvocation invocation) {}

  @override
  List<ShellCompletionSuggestion> cachedHistorySuggestions(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) {
    cachedInvocations.add(invocation);
    return invocation.token == 'ch'
        ? cachedSuggestions
        : const <ShellCompletionSuggestion>[];
  }

  @override
  Future<List<ShellCompletionSuggestion>> complete(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    completeInvocations.add(invocation);
    return completionSuggestions[invocation.token] ??
        const <ShellCompletionSuggestion>[];
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(
    this.session, {
    SshSession? reconnectSession,
    this.connectCompleter,
  }) : reconnectSession = reconnectSession ?? session;

  SshSession session;
  final SshSession reconnectSession;
  final Completer<void>? connectCompleter;
  final disconnectedConnectionIds = <int>[];
  final connectForceNewValues = <bool>[];
  ConnectionAttemptStatus? _connectionAttempt;

  Iterable<SshSession> get _sessions sync* {
    yield session;
    if (!identical(reconnectSession, session)) {
      yield reconnectSession;
    }
  }

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    for (final testSession in _sessions)
      if (!disconnectedConnectionIds.contains(testSession.connectionId))
        testSession.connectionId: SshConnectionState.connected,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) =>
      _connectionAttempt?.hostId == hostId ? _connectionAttempt : null;

  @override
  void clearConnectionAttempt(int hostId) {
    if (_connectionAttempt?.hostId != hostId) {
      return;
    }
    _connectionAttempt = null;
    state = {...state};
  }

  @override
  List<int> getConnectionsForHost(int hostId) => _sessions
      .where(
        (testSession) =>
            testSession.hostId == hostId &&
            !disconnectedConnectionIds.contains(testSession.connectionId),
      )
      .map((testSession) => testSession.connectionId)
      .toList(growable: false);

  @override
  ActiveConnection? getActiveConnection(int connectionId) => null;

  @override
  SshSession? getSession(int connectionId) {
    for (final testSession in _sessions) {
      if (testSession.connectionId == connectionId &&
          !disconnectedConnectionIds.contains(connectionId)) {
        return testSession;
      }
    }
    return null;
  }

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    connectForceNewValues.add(forceNew);
    _updateConnectionAttempt(
      hostId,
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Preparing connection…',
      ),
      resetLog: true,
    );
    await connectCompleter?.future;
    disconnectedConnectionIds.remove(reconnectSession.connectionId);
    state = {
      ...state,
      reconnectSession.connectionId: SshConnectionState.connected,
    };
    _updateConnectionAttempt(
      hostId,
      const ConnectionProgressUpdate(
        state: SshConnectionState.connected,
        message: 'Connection established. Opening terminal…',
      ),
    );
    return SshConnectionResult(
      success: true,
      connectionId: reconnectSession.connectionId,
    );
  }

  void _updateConnectionAttempt(
    int hostId,
    ConnectionProgressUpdate update, {
    bool resetLog = false,
  }) {
    final existing = resetLog ? null : _connectionAttempt;
    final existingForHost = existing != null && existing.hostId == hostId
        ? existing
        : null;
    final logLines = <String>[...?existingForHost?.logLines];
    if (logLines.isEmpty || logLines.last != update.message) {
      logLines.add(update.message);
    }
    _connectionAttempt = ConnectionAttemptStatus(
      hostId: hostId,
      state: update.state,
      latestMessage: update.message,
      logLines: List.unmodifiable(logLines),
    );
    state = {...state};
  }

  @override
  Future<void> disconnect(int connectionId) async {
    if (!disconnectedConnectionIds.contains(connectionId)) {
      disconnectedConnectionIds.add(connectionId);
    }
    state = {...state}..remove(connectionId);
  }

  @override
  Future<void> handleUnexpectedDisconnect(
    int connectionId, {
    required String message,
  }) => disconnect(connectionId);

  void dropSessionButKeepConnectedState(int connectionId) {
    if (!disconnectedConnectionIds.contains(connectionId)) {
      disconnectedConnectionIds.add(connectionId);
    }
    state = {...state, connectionId: SshConnectionState.connected};
  }

  @override
  Future<void> syncBackgroundStatus() async {}
}

class _TestThemeModeNotifier extends ThemeModeNotifier {
  _TestThemeModeNotifier(this.mode);

  ThemeMode mode;

  @override
  ThemeMode build() => mode;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    this.mode = mode;
    state = mode;
  }
}

Host _buildHost({
  required int id,
  String? autoConnectCommand,
  String? tmuxSessionName,
  String? tmuxWorkingDirectory,
  String? tmuxExtraFlags,
  RemoteMuxBackend? remoteMuxBackend,
  bool autoConnectRequiresConfirmation = false,
}) => Host(
  id: id,
  label: 'Terminal test host',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  autoConnectCommand: autoConnectCommand,
  tmuxSessionName: tmuxSessionName,
  tmuxWorkingDirectory: tmuxWorkingDirectory,
  tmuxExtraFlags: tmuxExtraFlags,
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: autoConnectRequiresConfirmation,
  autoForwardPorts: false,
  remoteMuxBackend: remoteMuxBackend?.storageValue,
  sortOrder: 0,
);

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

TextEditingValue _editingValue(String text, {required int selectionOffset}) =>
    TextEditingValue(
      text: '$_deleteDetectionMarker$text',
      selection: TextSelection.collapsed(
        offset: _deleteDetectionMarker.length + selectionOffset,
      ),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(const HostsCompanion());
    registerFallbackValue(<int>[]);
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const Stream<List<int>>.empty());
    registerFallbackValue(_FakeSshSession());
    registerFallbackValue(<int, int>{});
    registerFallbackValue(MonetizationFeature.autoConnectAutomation);
    registerFallbackValue(monkey_themes.TerminalThemes.defaultDarkTheme);
    registerFallbackValue(SshExecPriority.normal);
  });

  test(
    'only falls back when an initial MonkeyMux attach never established',
    () {
      expect(
        shouldFallbackFromUnestablishedMonkeyMuxAttach(
          reconnectAttempt: false,
          attachEstablished: false,
        ),
        isTrue,
      );
      expect(
        shouldFallbackFromUnestablishedMonkeyMuxAttach(
          reconnectAttempt: false,
          attachEstablished: true,
        ),
        isFalse,
      );
      expect(
        shouldFallbackFromUnestablishedMonkeyMuxAttach(
          reconnectAttempt: true,
          attachEstablished: false,
        ),
        isFalse,
      );
    },
  );

  group('terminal native selection helpers', () {
    test('runs terminal selection menu action before hiding toolbar', () {
      String? selectedText = 'alpha';
      String? copiedText;

      final onPressed = buildTerminalSelectionContextMenuAction(
        action: () => copiedText = selectedText,
        hideToolbar: () => selectedText = null,
      );

      onPressed();

      expect(copiedText, 'alpha');
      expect(selectedText, isNull);
    });

    test(
      'limits mobile terminal overflow menu to the visible keyboard area',
      () {
        const mediaQuery = MediaQueryData(
          size: Size(390, 844),
          viewInsets: EdgeInsets.only(bottom: 320),
        );

        expect(
          resolveTerminalOverflowMenuMaxHeight(
            mediaQuery: mediaQuery,
            isMobilePlatform: true,
            anchorTop: 120,
          ),
          396,
        );
        expect(
          resolveTerminalOverflowMenuMaxHeight(
            mediaQuery: mediaQuery,
            isMobilePlatform: false,
            anchorTop: 120,
          ),
          isNull,
        );
        expect(
          resolveTerminalOverflowMenuMaxHeight(
            mediaQuery: const MediaQueryData(size: Size(390, 844)),
            isMobilePlatform: true,
            anchorTop: 120,
          ),
          isNull,
        );
      },
    );

    test('adds create snippet action after copy in terminal menu', () {
      var didCreateSnippet = false;

      final items = buildTerminalSelectionContextMenuButtonItems(
        defaultItems: const [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            onPressed: null,
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: null,
          ),
        ],
        onCopy: () {},
        onLookUp: () {},
        onSearchWeb: () {},
        onShare: () {},
        onCreateSnippet: () => didCreateSnippet = true,
        onPaste: () {},
      );

      final copyIndex = items.indexWhere(
        (item) => item.type == ContextMenuButtonType.copy,
      );
      final snippetIndex = items.indexWhere(
        (item) => item.label == 'Create Snippet',
      );

      expect(snippetIndex, copyIndex + 1);
      items[snippetIndex].onPressed!();
      expect(didCreateSnippet, isTrue);
    });

    test('omits create snippet action without selected text', () {
      final items = buildTerminalSelectionContextMenuButtonItems(
        defaultItems: const [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            onPressed: null,
          ),
        ],
        onCopy: () {},
        onLookUp: () {},
        onSearchWeb: () {},
        onShare: () {},
        onCreateSnippet: null,
        onPaste: () {},
      );

      expect(items.where((item) => item.label == 'Create Snippet'), isEmpty);
    });

    test('builds snippet name from selected terminal text', () {
      final longLine = List.filled(80, 'a').join();
      final truncatedLine = '${List.filled(57, 'a').join()}...';

      expect(
        buildSnippetNameFromTerminalSelection('\n  git status\n'),
        'git status',
      );
      expect(
        buildSnippetNameFromTerminalSelection('   \n'),
        'Terminal selection',
      );
      expect(
        buildSnippetNameFromTerminalSelection('$longLine\nsecond'),
        truncatedLine,
      );
    });

    test('prefers terminal controller selection over system selection', () {
      expect(
        resolveTerminalSelectionPlainText(
          terminalControllerSelectionText: 'controller text',
          systemSelectionPlainText: 'system text',
        ),
        'controller text',
      );
    });

    test('falls back to system selection text when controller is empty', () {
      expect(
        resolveTerminalSelectionPlainText(
          terminalControllerSelectionText: null,
          systemSelectionPlainText: 'system text',
        ),
        'system text',
      );
      expect(
        resolveTerminalSelectionPlainText(
          terminalControllerSelectionText: '',
          systemSelectionPlainText: 'system text',
        ),
        'system text',
      );
    });

    test('returns null when no selection text is available', () {
      expect(
        resolveTerminalSelectionPlainText(
          terminalControllerSelectionText: null,
          systemSelectionPlainText: null,
        ),
        isNull,
      );
      expect(
        resolveTerminalSelectionPlainText(
          terminalControllerSelectionText: '',
          systemSelectionPlainText: '',
        ),
        isNull,
      );
    });

    test('hides terminal selection toolbar when action throws', () {
      var didHideToolbar = false;

      final onPressed = buildTerminalSelectionContextMenuAction(
        action: () => throw StateError('copy failed'),
        hideToolbar: () => didHideToolbar = true,
      );

      expect(onPressed, throwsStateError);
      expect(didHideToolbar, isTrue);
    });

    test('does not apply empty remote clipboard text locally', () {
      expect(
        shouldApplyRemoteClipboardTextToLocal(
          remoteText: '',
          lastObservedRemoteText: null,
          lastObservedLocalText: 'alpha',
          lastAppliedRemoteText: null,
          recentLocalClipboardText: null,
          recentLocalClipboardAt: null,
          now: DateTime(2026),
        ),
        isFalse,
      );
    });

    test('does not overwrite a recent local clipboard write', () {
      final now = DateTime(2026);

      expect(
        shouldApplyRemoteClipboardTextToLocal(
          remoteText: 'stale remote',
          lastObservedRemoteText: 'older remote',
          lastObservedLocalText: 'older local',
          lastAppliedRemoteText: null,
          recentLocalClipboardText: 'fresh local',
          recentLocalClipboardAt: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test(
      'applies changed non-empty remote clipboard after local protection',
      () {
        final now = DateTime(2026);

        expect(
          shouldApplyRemoteClipboardTextToLocal(
            remoteText: 'fresh remote',
            lastObservedRemoteText: 'older remote',
            lastObservedLocalText: 'older local',
            lastAppliedRemoteText: null,
            recentLocalClipboardText: 'local',
            recentLocalClipboardAt: now.subtract(const Duration(seconds: 10)),
            now: now,
          ),
          isTrue,
        );
      },
    );
  });

  group('MonkeyTerminalView system selection geometry', () {
    Future<MonkeyRenderTerminal> pumpSelectableTerminal(
      WidgetTester tester, {
      required Terminal terminal,
      required TerminalController controller,
      required double height,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 390,
                height: height,
                child: MonkeyTerminalView(
                  terminal,
                  controller: controller,
                  hardwareKeyboardOnly: true,
                  useSystemSelection: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester
          .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
          .renderTerminal;
    }

    Offset cellCenter(MonkeyRenderTerminal renderTerminal, CellOffset offset) =>
        renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );

    String rowLabel(int row) => 'row ${row.toString().padLeft(2, '0')}';

    testWidgets('anchors selection handles at terminal line bottoms', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100)..write('alpha');
      final controller = TerminalController();
      final renderTerminal = await pumpSelectableTerminal(
        tester,
        terminal: terminal,
        controller: controller,
        height: 240,
      );

      renderTerminal.dispatchSelectionEvent(
        SelectWordSelectionEvent(
          globalPosition: cellCenter(renderTerminal, const CellOffset(2, 0)),
        ),
      );
      await tester.pump();

      final lineBottom =
          renderTerminal.getOffset(const CellOffset(0, 0)).dy +
          renderTerminal.cellSize.height;
      expect(
        renderTerminal.value.startSelectionPoint!.localPosition.dy,
        closeTo(lineBottom, 0.001),
      );
      expect(
        renderTerminal.value.endSelectionPoint!.localPosition.dy,
        closeTo(lineBottom, 0.001),
      );
    });

    testWidgets(
      'keeps updating selection when a handle is dragged above the viewport',
      (tester) async {
        final terminal = Terminal(maxLines: 120);
        for (var row = 0; row < 60; row += 1) {
          terminal.write('${rowLabel(row)}\r\n');
        }
        final controller = TerminalController();

        var renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 160,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );

        final topVisibleRow = renderTerminal.getCellOffset(Offset.zero).y;
        expect(topVisibleRow, greaterThan(3));
        final targetRow = topVisibleRow - 3;
        final endRow = topVisibleRow + 2;

        renderTerminal
          ..dispatchSelectionEvent(
            SelectionEdgeUpdateEvent.forStart(
              globalPosition: cellCenter(renderTerminal, CellOffset(0, endRow)),
            ),
          )
          ..dispatchSelectionEvent(
            SelectionEdgeUpdateEvent.forEnd(
              globalPosition: cellCenter(renderTerminal, CellOffset(6, endRow)),
            ),
          );
        await tester.pump();

        renderTerminal.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forStart(
            globalPosition: cellCenter(
              renderTerminal,
              CellOffset(0, targetRow),
            ),
          ),
        );
        await tester.pump();

        final selectedText = renderTerminal.getSelectedContent()!.plainText;
        expect(selectedText, contains(rowLabel(targetRow)));
        expect(selectedText, contains(rowLabel(endRow)));
      },
    );

    testWidgets(
      'repaints controller-driven selection after keyboard-sized resize',
      (tester) async {
        final terminal = Terminal(maxLines: 120);
        for (var row = 0; row < 60; row += 1) {
          terminal.write('${rowLabel(row)}\r\n');
        }
        final controller = TerminalController();

        var renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 160,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );

        expect(renderTerminal.debugNeedsPaint, isFalse);

        renderTerminal.dispatchSelectionEvent(
          SelectWordSelectionEvent(
            globalPosition: cellCenter(
              renderTerminal,
              CellOffset(4, renderTerminal.getCellOffset(Offset.zero).y + 1),
            ),
          ),
        );

        expect(renderTerminal.debugNeedsPaint, isTrue);
        await tester.pump();
        expect(renderTerminal.getSelectedContent()?.plainText, isNotNull);
      },
    );

    testWidgets('refreshTerminalDisplay reveals latest output', (tester) async {
      final terminal = Terminal(maxLines: 120);
      for (var row = 0; row < 60; row += 1) {
        terminal.write('${rowLabel(row)}\r\n');
      }
      final controller = TerminalController();

      await pumpSelectableTerminal(
        tester,
        terminal: terminal,
        controller: controller,
        height: 160,
      );
      final scrollableState = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(MonkeyTerminalView),
          matching: find.byType(Scrollable),
        ),
      );
      final position = scrollableState.position;
      expect(position.maxScrollExtent, greaterThan(0));

      position.jumpTo(0);
      await tester.pump();
      expect(position.pixels, 0);

      tester
          .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
          .refreshTerminalDisplay(revealLatestOutput: true);
      await tester.pump();
      await tester.pump();

      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('refreshTerminalDisplay relayouts without revealing output', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 120);
      for (var row = 0; row < 60; row += 1) {
        terminal.write('${rowLabel(row)}\r\n');
      }
      final controller = TerminalController();

      final renderTerminal = await pumpSelectableTerminal(
        tester,
        terminal: terminal,
        controller: controller,
        height: 160,
      );
      final scrollableState = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(MonkeyTerminalView),
          matching: find.byType(Scrollable),
        ),
      );
      final position = scrollableState.position..jumpTo(0);
      await tester.pump();
      expect(renderTerminal.debugNeedsLayout, isFalse);

      tester
          .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
          .refreshTerminalDisplay();

      expect(renderTerminal.debugNeedsLayout, isTrue);
      expect(position.pixels, 0);
    });

    testWidgets(
      'handle drag keeps updating after keyboard-sized resize',
      (tester) async {
        final terminal = Terminal(maxLines: 120);
        for (var row = 0; row < 60; row += 1) {
          terminal.write('${rowLabel(row)}\r\n');
        }
        final controller = TerminalController();

        var renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 160,
        );
        renderTerminal = await pumpSelectableTerminal(
          tester,
          terminal: terminal,
          controller: controller,
          height: 320,
        );

        final topVisibleRow = renderTerminal.getCellOffset(Offset.zero).y;
        final selectedRow = topVisibleRow + 10;
        final targetRow = topVisibleRow + 1;

        await tester.longPressAt(
          cellCenter(renderTerminal, CellOffset(5, selectedRow)),
        );
        await tester.pumpAndSettle();
        expect(controller.selection, isNotNull);

        final handleFinder = find.byWidgetPredicate(
          (widget) =>
              widget.runtimeType.toString() == '_SelectionHandleOverlay',
        );
        expect(handleFinder, findsWidgets);

        final startSelectionPoint = renderTerminal.value.startSelectionPoint!;
        final startHandlePosition = renderTerminal.localToGlobal(
          startSelectionPoint.localPosition,
        );
        await tester.dragFrom(
          startHandlePosition,
          cellCenter(renderTerminal, CellOffset(0, targetRow)) -
              startHandlePosition,
        );
        await tester.pumpAndSettle();

        final selectedText = renderTerminal.getSelectedContent()!.plainText;
        expect(selectedText, contains(rowLabel(targetRow)));
        expect(selectedText, contains(rowLabel(selectedRow)));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  });

  group('TerminalScreen mobile IME wiring', () {
    late AppDatabase db;
    late _MockHostRepository hostRepository;
    late _MockSshClient sshClient;
    late _MockShellChannel shellChannel;
    late _MockMonetizationService monetizationService;
    late SshSession session;
    late Host host;
    late Completer<void> shellDoneCompleter;
    late StreamController<Uint8List> shellStdoutController;
    late List<List<int>> shellWrites;
    late WakelockPlusPlatformInterface originalWakelockPlatform;
    late FakeWakelockPlusPlatform wakelockPlatform;

    test('uses terminal theme brightness for keyboard appearance', () {
      expect(
        resolveTerminalKeyboardAppearance(
          monkey_themes.TerminalThemes.defaultDarkTheme,
        ),
        Brightness.dark,
      );
      expect(
        resolveTerminalKeyboardAppearance(
          monkey_themes.TerminalThemes.githubLightDefault,
        ),
        Brightness.light,
      );
    });

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      hostRepository = _MockHostRepository();
      sshClient = _MockSshClient();
      shellChannel = _MockShellChannel();
      monetizationService = _MockMonetizationService();
      host = _buildHost(id: 1);
      shellDoneCompleter = Completer<void>();
      shellStdoutController = StreamController<Uint8List>.broadcast();
      shellWrites = <List<int>>[];
      originalWakelockPlatform = wakelockPlusPlatformInstance;
      wakelockPlatform = FakeWakelockPlusPlatform();
      wakelockPlusPlatformInstance = wakelockPlatform;

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(
        () => monetizationService.states,
      ).thenAnswer((_) => Stream.value(_proMonetizationState));
      when(() => monetizationService.initialize()).thenAnswer((_) async {});
      when(
        () => monetizationService.canUseFeature(any()),
      ).thenAnswer((_) async => true);

      when(() => hostRepository.getById(host.id)).thenAnswer((_) async => host);
      _stubTrueColorLoginShell(sshClient, shellChannel);
      when(
        () => shellChannel.stdout,
      ).thenAnswer((_) => shellStdoutController.stream);
      when(
        () => shellChannel.stderr,
      ).thenAnswer((_) => const Stream<Uint8List>.empty());
      when(
        () => shellChannel.done,
      ).thenAnswer((_) => shellDoneCompleter.future);
      when(() => shellChannel.write(any())).thenAnswer((invocation) {
        final value = invocation.positionalArguments.single;
        if (value is List<int>) {
          shellWrites.add(List<int>.from(value));
        }
      });

      session = SshSession(
        connectionId: 7,
        hostId: host.id,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'terminal.example.com',
          port: 22,
          username: 'root',
        ),
      )..getOrCreateTerminal();
    });

    tearDown(() async {
      wakelockPlusPlatformInstance = originalWakelockPlatform;
      await shellStdoutController.close();
      await db.close();
    });

    TerminalScreenMuxFixture createMuxFixture(
      TmuxService tmuxService,
      MonkeyMuxService monkeyMuxService,
      String sessionName,
    ) => TerminalScreenMuxFixture(
      database: db,
      hostRepository: hostRepository,
      monetizationService: monetizationService,
      monetizationState: _proMonetizationState,
      activeSessions: () => _TestActiveSessionsNotifier(session),
      host: host,
      session: session,
      sessionName: sessionName,
      tmuxService: tmuxService,
      monkeyMuxService: monkeyMuxService,
    );

    Widget buildScreen({
      Widget? child,
      String? initialTmuxSessionName,
      int? initialTmuxWindowIndex,
      String? initialTmuxWindowId,
      bool initialTmuxWindowRequiresVisibleSession = false,
      ActiveSessionsNotifier? activeSessions,
      Future<bool> Function()? loadSharedClipboard,
      MonetizationState monetizationState = _proMonetizationState,
      List<Override> overrides = const [],
    }) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        hostRepositoryProvider.overrideWithValue(hostRepository),
        monetizationServiceProvider.overrideWithValue(monetizationService),
        monetizationStateProvider.overrideWith(
          (ref) => Stream.value(monetizationState),
        ),
        sharedClipboardProvider.overrideWith(
          (ref) => loadSharedClipboard?.call() ?? Future.value(false),
        ),
        activeSessionsProvider.overrideWith(
          () => activeSessions ?? _TestActiveSessionsNotifier(session),
        ),
        ...overrides,
      ],
      child:
          child ??
          MaterialApp(
            home: TerminalScreen(
              hostId: host.id,
              connectionId: session.connectionId,
              initialTmuxSessionName: initialTmuxSessionName,
              initialTmuxWindowIndex: initialTmuxWindowIndex,
              initialTmuxWindowId: initialTmuxWindowId,
              initialTmuxWindowRequiresVisibleSession:
                  initialTmuxWindowRequiresVisibleSession,
            ),
          ),
    );

    void stubTmuxWindows(
      TmuxService tmuxService,
      String sessionName,
      List<TmuxWindow> windows, {
      String? extraFlags,
      Stream<TmuxWindowChangeEvent>? events,
    }) {
      when(
        () => tmuxService.prefetchInstalledAgentTools(session),
      ).thenAnswer((_) async {});
      when(
        () => tmuxService.listWindows(
          session,
          sessionName,
          extraFlags: extraFlags,
        ),
      ).thenAnswer((_) async => windows);
      when(
        () => tmuxService.watchWindowChanges(
          session,
          sessionName,
          extraFlags: extraFlags,
        ),
      ).thenAnswer(
        (_) => events ?? const Stream<TmuxWindowChangeEvent>.empty(),
      );
      when(
        () => tmuxService.refreshTerminalTheme(
          session,
          sessionName,
          any(),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});
    }

    Future<void> pumpScreen(
      WidgetTester tester, {
      ThemeMode themeMode = ThemeMode.light,
      ActiveSessionsNotifier? activeSessions,
      TmuxService? tmuxService,
      MonkeyMuxService? monkeyMuxService,
      AcpSessionManager? acpSessionManager,
      ShellCompletionService? shellCompletionService,
      AndroidDeviceDebugPlatform? deviceDebugPlatform,
      RemoteAdbCommandRunner? remoteAdbCommandRunner,
      AgentManagementService? agentManagementService,
      RemoteFileService? remoteFileService,
      MonetizationState monetizationState = _proMonetizationState,
      bool sharedClipboard = false,
      bool sharedClipboardLocalRead = false,
    }) async {
      await tester.pumpWidget(
        buildScreen(
          activeSessions: activeSessions,
          monetizationState: monetizationState,
          loadSharedClipboard: () async => sharedClipboard,
          overrides: [
            if (remoteFileService != null)
              remoteFileServiceProvider.overrideWithValue(remoteFileService),
            themeModeNotifierProvider.overrideWith(
              () => _TestThemeModeNotifier(themeMode),
            ),
            sharedClipboardLocalReadProvider.overrideWith(
              (ref) async => sharedClipboardLocalRead,
            ),
            if (tmuxService != null)
              tmuxServiceProvider.overrideWithValue(tmuxService),
            if (monkeyMuxService != null)
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            if (acpSessionManager != null)
              acpSessionManagerProvider.overrideWithValue(acpSessionManager),
            if (shellCompletionService != null)
              shellCompletionServiceProvider.overrideWithValue(
                shellCompletionService,
              ),
            if (agentManagementService != null)
              agentManagementServiceProvider.overrideWithValue(
                agentManagementService,
              ),
            androidDeviceDebugPlatformProvider.overrideWithValue(
              deviceDebugPlatform ?? _FakeAndroidDeviceDebugPlatform(),
            ),
            if (remoteAdbCommandRunner != null)
              remoteAdbCommandRunnerProvider.overrideWithValue(
                remoteAdbCommandRunner,
              ),
          ],
          child: MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: themeMode,
            home: TerminalScreen(
              hostId: host.id,
              connectionId: session.connectionId,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
    }

    for (final existingTerminal in [false, true]) {
      for (final phase in [
        'host lookup',
        'clipboard sharing',
        'clipboard read',
        'shell creation',
      ]) {
        testWidgets(
          'startup $phase after disposal with existing terminal $existingTerminal',
          (tester) async {
            final trackedSession = _LifecycleSshSession(session);
            session = trackedSession;
            if (existingTerminal) session.getOrCreateTerminal();
            final pendingHost = Completer<Host?>();
            final pendingClipboard = Completer<bool>();
            final pendingShell = Completer<void>();
            if (phase == 'host lookup') {
              when(
                () => hostRepository.getById(host.id),
              ).thenAnswer((_) => pendingHost.future);
            }
            if (phase == 'shell creation') {
              trackedSession.pendingOpen = pendingShell.future;
            }
            await tester.pumpWidget(
              buildScreen(
                loadSharedClipboard: () => phase == 'clipboard sharing'
                    ? pendingClipboard.future
                    : Future.value(false),
                overrides: [
                  sharedClipboardLocalReadProvider.overrideWith(
                    (ref) => phase == 'clipboard read'
                        ? pendingClipboard.future
                        : Future.value(false),
                  ),
                ],
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(tester.takeException(), isNull);
            expect(find.byType(TerminalScreen), findsOneWidget);
            if (phase == 'shell creation') {
              expect(trackedSession.openCalls, 1);
            }
            await trackedSession.completeAfterDisposal(tester, () {
              pendingHost.complete(host);
              pendingClipboard.complete(false);
              pendingShell.complete();
            });
          },
          variant: TargetPlatformVariant.only(TargetPlatform.android),
        );
      }
    }

    for (final phase in ['startup', 'poll']) {
      for (final stop in ['background', 'disable', 'replace']) {
        testWidgets(
          'clipboard $phase ignores delayed completion after $stop',
          (tester) async {
            final pendingRead = Completer<SSHSession>();
            var reads = 0;
            final writes = <String>[];
            final activeSessions = _TestActiveSessionsNotifier(session);
            SSHSession readResult(String text) {
              final channel = _MockShellChannel();
              when(() => channel.stdout).thenAnswer(
                (_) => Stream.value(
                  Uint8List.fromList(
                    utf8.encode(base64Encode(utf8.encode(text))),
                  ),
                ),
              );
              when(
                () => channel.stderr,
              ).thenAnswer((_) => const Stream<Uint8List>.empty());
              when(() => channel.done).thenAnswer((_) async {});
              return channel;
            }

            when(
              () => sshClient.execute(any(that: contains('pbpaste'))),
            ).thenAnswer((_) async {
              reads++;
              return reads == (phase == 'startup' ? 1 : 2)
                  ? pendingRead.future
                  : readResult('initial');
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async {
                if (call.method == 'Clipboard.setData') {
                  writes.add((call.arguments as Map)['text'] as String);
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
            );
            await pumpScreen(
              tester,
              activeSessions: activeSessions,
              sharedClipboard: true,
            );
            await tester.pumpAndSettle();
            if (phase == 'poll') {
              await tester.pump(const Duration(seconds: 1));
              await tester.pump();
            }
            expect(reads, phase == 'startup' ? 1 : 2);
            switch (stop) {
              case 'background':
                addTearDown(() {
                  for (final state in [
                    AppLifecycleState.hidden,
                    AppLifecycleState.inactive,
                    AppLifecycleState.resumed,
                  ]) {
                    tester.binding.handleAppLifecycleStateChanged(state);
                  }
                });
                for (final state in [
                  AppLifecycleState.inactive,
                  AppLifecycleState.hidden,
                  AppLifecycleState.paused,
                ]) {
                  tester.binding.handleAppLifecycleStateChanged(state);
                }
              case 'disable':
                session.clipboardSharingEnabled = false;
              case 'replace':
                activeSessions.session = SshSession(
                  connectionId: session.connectionId,
                  hostId: host.id,
                  client: sshClient,
                  config: session.config,
                )..getOrCreateTerminal();
            }
            await tester.pump();
            pendingRead.complete(readResult('stale clipboard'));
            await tester.pump();
            await tester.pump(const Duration(seconds: 2));
            expect(writes, isEmpty);
            expect(reads, phase == 'startup' ? 1 : 2);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        );
      }
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      for (final sharingEnabled in [false, true]) {
        testWidgets(
          'clipboard sync respects passive read policy on start and resume, '
          'sharing=$sharingEnabled',
          (tester) async {
            var localReads = 0;
            var remoteReads = 0;
            var remoteText = 'initial remote clipboard';
            final clipboardWrites = <String>[];
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async {
                if (call.method == 'Clipboard.getData') {
                  localReads++;
                  return {'text': 'local clipboard text'};
                }
                if (call.method == 'Clipboard.setData') {
                  clipboardWrites.add(
                    (call.arguments as Map<Object?, Object?>)['text']!
                        as String,
                  );
                }
                if (call.method == 'Clipboard.hasStrings') {
                  return {'value': true};
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
            );
            when(() => sshClient.execute(any())).thenAnswer((invocation) async {
              final command = invocation.positionalArguments.single as String;
              final isRead = command.contains('pbpaste');
              if (isRead) remoteReads++;
              final channel = _MockShellChannel();
              when(() => channel.stdout).thenAnswer(
                (_) => Stream.value(
                  Uint8List.fromList(
                    utf8.encode(
                      isRead ? base64Encode(utf8.encode(remoteText)) : '',
                    ),
                  ),
                ),
              );
              when(
                () => channel.stderr,
              ).thenAnswer((_) => const Stream<Uint8List>.empty());
              when(() => channel.done).thenAnswer((_) async {});
              return channel;
            });

            await pumpScreen(
              tester,
              sharedClipboard: sharingEnabled,
              sharedClipboardLocalRead: true,
            );
            await tester.pumpAndSettle();
            expect(session.clipboardSharingEnabled, sharingEnabled);
            expect(session.localClipboardReadEnabled, sharingEnabled);
            final shouldReadLocally =
                sharingEnabled && platform != TargetPlatform.iOS;
            expect(localReads, shouldReadLocally ? greaterThan(0) : 0);
            final readsBeforeResume = remoteReads;

            for (final lifecycle in [
              AppLifecycleState.inactive,
              AppLifecycleState.paused,
              AppLifecycleState.resumed,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(lifecycle);
              await tester.pump();
            }
            await tester.pump(const Duration(seconds: 2));
            await tester.pumpAndSettle();
            expect(localReads, shouldReadLocally ? greaterThan(0) : 0);
            expect(
              remoteReads,
              sharingEnabled ? greaterThan(readsBeforeResume) : 0,
            );

            if (sharingEnabled) {
              remoteText = 'updated by remote';
              await tester.pump(const Duration(seconds: 1));
              await tester.pumpAndSettle();
              expect(clipboardWrites, contains(remoteText));
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
          variant: TargetPlatformVariant.only(platform),
        );
      }
    }

    testWidgets(
      'explicit iOS paste still reads clipboard text',
      (tester) async {
        var localReads = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              localReads++;
              return {'text': 'pasted text'};
            }
            if (call.method == 'Clipboard.hasStrings') return {'value': true};
            return null;
          },
        );
        const pasteboard = MethodChannel('pasteboard');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pasteboard,
          (call) async => call.method == 'files' ? <String>[] : null,
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            pasteboard,
            null,
          );
        });
        await pumpScreen(tester);
        await tester.pumpAndSettle();
        expect(localReads, 0);
        shellWrites.clear();
        await tester.ensureVisible(find.byTooltip('Paste'));
        await tester.tap(find.byTooltip('Paste'));
        await tester.pumpAndSettle();
        expect(localReads, 1);
        expect(
          utf8.decode(shellWrites.expand((chunk) => chunk).toList()),
          contains('pasted text'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    Future<void> openTerminalOverflowMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    String? terminalMenuLabel(Widget? child) =>
        child is Text ? child.data : null;

    Finder terminalMenuItemButton(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is MenuItemButton && terminalMenuLabel(widget.child) == label,
    );

    Finder terminalSubmenuButton(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is SubmenuButton && terminalMenuLabel(widget.child) == label,
    );

    Finder terminalCheckboxMenuButton(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is CheckboxMenuButton &&
          terminalMenuLabel(widget.child) == label,
    );

    Future<void> openTerminalOverflowSubmenu(
      WidgetTester tester,
      String label,
    ) async {
      await openTerminalOverflowMenu(tester);
      await tester.tap(terminalSubmenuButton(label));
      await tester.pumpAndSettle();
    }

    for (final cancel in [false, true]) {
      testWidgets(
        'snippet sheet substitutes once and tracks usage, cancel=$cancel',
        (tester) async {
          final repository = SnippetRepository(db);
          final id = await repository.insert(
            SnippetsCompanion.insert(
              name: 'Literal variables',
              command: 'echo {{a}} {{b}} {{a}}',
            ),
          );
          await pumpScreen(tester);
          await tester.pumpAndSettle();
          shellWrites.clear();
          await openTerminalOverflowMenu(tester);
          await tester.tap(terminalMenuItemButton('Snippets'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Literal variables'));
          await tester.pumpAndSettle();
          expect(find.byType(TextFormField), findsNWidgets(2));
          await tester.enterText(find.byType(TextFormField).at(0), '{{b}}');
          await tester.enterText(find.byType(TextFormField).at(1), 'world');
          await tester.tap(
            find.widgetWithText(
              cancel ? TextButton : FilledButton,
              cancel ? 'Cancel' : 'Insert',
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          expect(find.byType(TextFormField), findsNothing);
          if (!cancel && find.text('Insert command').evaluate().isNotEmpty) {
            await tester.tap(find.text('Insert command'));
            await tester.pumpAndSettle();
          }
          final output = utf8.decode(
            shellWrites.expand((chunk) => chunk).toList(),
          );
          expect(
            output,
            cancel
                ? isNot(contains('echo'))
                : contains('echo {{b}} world {{b}}'),
          );
          expect((await repository.getById(id))!.usageCount, cancel ? 0 : 1);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    void enablePlainTuiSignals() {
      session.terminal!.write('\x1b[?1004h');
    }

    testWidgets('shows and clears OSC 9;4 progress under the app bar', (
      tester,
    ) async {
      await pumpScreen(tester);

      session.terminal!.write('\x1b]9;4;1;50\x07');
      await tester.pump(const Duration(milliseconds: 100));

      final progressFinder = find.byKey(
        const ValueKey<String>('terminal-osc-progress'),
      );
      expect(progressFinder, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(progressFinder).value, 0.5);

      session.terminal!.write('\x1b]9;4;2;75\x07');
      await tester.pump(const Duration(milliseconds: 100));

      final errorProgress = tester.widget<LinearProgressIndicator>(
        progressFinder,
      );
      expect(errorProgress.value, 0.75);
      expect(
        errorProgress.color,
        Theme.of(tester.element(progressFinder)).colorScheme.error,
      );
      final errorSemantics = tester.getSemantics(progressFinder);
      expect(errorSemantics.value, '75');
      expect(errorSemantics.role, SemanticsRole.progressBar);

      session.terminal!.write('\x1b]9;4;0\x07');
      await tester.pump(const Duration(milliseconds: 100));
      expect(progressFinder, findsNothing);

      session.terminal!.write('\x1b]9;4;4\x07');
      await tester.pump(const Duration(milliseconds: 100));

      final pausedProgress = tester.widget<LinearProgressIndicator>(
        progressFinder,
      );
      expect(pausedProgress.value, isNull);
      expect(
        pausedProgress.color,
        Theme.of(tester.element(progressFinder)).colorScheme.tertiary,
      );
      final pausedSemantics = tester.getSemantics(progressFinder);
      expect(
        pausedSemantics.label,
        'Terminal task progress, paused or warning',
      );
      expect(pausedSemantics.value, isEmpty);
      expect(pausedSemantics.role, SemanticsRole.loadingSpinner);

      session.terminal!.write('\x1b]9;4;3\x07');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.widget<LinearProgressIndicator>(progressFinder).value,
        isNull,
      );
      final indeterminateSemantics = tester.getSemantics(progressFinder);
      expect(
        indeterminateSemantics.label,
        'Terminal task progress, indeterminate',
      );
      expect(indeterminateSemantics.value, isEmpty);
      expect(indeterminateSemantics.role, SemanticsRole.loadingSpinner);

      session.terminal!.write('\x1b]9;4;0\x07');
      await tester.pump(const Duration(milliseconds: 100));
      expect(progressFinder, findsNothing);
    });

    testWidgets(
      'keeps percentage-null progress semantic values empty with reduced motion',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await pumpScreen(tester);

        session.terminal!.write('\x1b]9;4;3\x07');
        await tester.pump(const Duration(milliseconds: 100));

        final progressFinder = find.byKey(
          const ValueKey<String>('terminal-osc-progress'),
        );
        expect(
          tester.widget<LinearProgressIndicator>(progressFinder).value,
          0.5,
        );
        final semantics = tester.getSemantics(progressFinder);
        expect(semantics.label, 'Terminal task progress, indeterminate');
        expect(semantics.value, isEmpty);
        expect(semantics.role, SemanticsRole.loadingSpinner);
      },
    );

    testWidgets(
      'opens a Copilot-style underlined URL when tapped',
      (tester) async {
        const url = 'https://github.com/depollsoft/MonkeySSH/pull/590';
        const urlLauncherChannel = MethodChannel(
          'plugins.flutter.io/url_launcher',
        );
        final launchedUrls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          urlLauncherChannel,
          (call) async {
            if (call.method == 'launch') {
              final arguments = call.arguments! as Map<Object?, Object?>;
              launchedUrls.add(arguments['url']! as String);
              return true;
            }
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            urlLauncherChannel,
            null,
          ),
        );

        await pumpScreen(tester);
        // How Copilot CLI renders links: plain text with an SGR underline and
        // no OSC 8 hyperlink. A tap must still launch the visible URL.
        final term = session.terminal!..write('See \x1b[4m$url\x1b[24m ok\r\n');
        await tester.pumpAndSettle();

        final buffer = term.buffer;
        var urlRow = -1;
        var urlCol = -1;
        for (var r = 0; r < buffer.height; r++) {
          final idx = buffer.lines[r].getText().indexOf('https://');
          if (idx >= 0) {
            urlRow = r;
            urlCol = idx + (url.length ~/ 2);
            break;
          }
        }
        expect(urlRow, isNonNegative);

        final render = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        await tester.tapAt(
          render.localToGlobal(
            render.getOffset(CellOffset(urlCol, urlRow)) +
                render.cellSize.center(Offset.zero),
          ),
        );
        await tester.pumpAndSettle();

        expect(launchedUrls, [url]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'resolves a URL char-wrapped flush against TUI box borders',
      (tester) async {
        await pumpScreen(tester);
        // Copilot CLI on a narrow screen char-wraps a URL flush against its box
        // borders across two absolutely positioned (non-wrapped) rendered
        // lines. Tapping either fragment must resolve the whole URL, and the
        // U+2502 borders must not leak into it.
        session.terminal!
          ..write('\x1b[2J')
          ..write('\x1b[14;1H\u2502https://github.com/depollsoft/Mon\u2502')
          ..write('\x1b[15;1H\u2502keySSH/pull/592 ok\u2502');
        await tester.pumpAndSettle();

        final view = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        const expected = 'https://github.com/depollsoft/MonkeySSH/pull/592';
        // Tap the first fragment (row 13, after the leading border).
        final firstHalf = view.resolveLinkTap!(const CellOffset(3, 13));
        // Tap the second fragment (row 14, after the leading border).
        final secondHalf = view.resolveLinkTap!(const CellOffset(3, 14));

        expect(firstHalf, expected);
        expect(secondHalf, expected);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'tapping an OSC 8 hyperlink opens locally without forwarding a mouse '
      'click to the host',
      (tester) async {
        const url = 'https://github.com/depollsoft/MonkeySSH/issues/1';
        const urlLauncherChannel = MethodChannel(
          'plugins.flutter.io/url_launcher',
        );
        final launchedUrls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          urlLauncherChannel,
          (call) async {
            if (call.method == 'launch') {
              launchedUrls.add((call.arguments! as Map)['url']! as String);
              return true;
            }
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            urlLauncherChannel,
            null,
          ),
        );

        await pumpScreen(tester);
        // Copilot CLI emits an OSC 8 hyperlink, closes it at the end of the
        // label, and immediately erases the rest of that rendered TUI row. It
        // also enables SGR mouse tracking. Tapping the label must still open the
        // URL locally rather than forwarding an inert click to the host.
        session.terminal!
          ..write('\x1b[?1003h\x1b[?1006h')
          ..write(
            [
              '\x1b[4;2H',
              '\x1b[4m',
              '\x1b]8;id=md-link;$url\x07',
              'Issue #1',
              '\x1b[0m',
              '\x1b]8;;\x07',
              '\x1b[K',
            ].join(),
          );
        await tester.pumpAndSettle();

        final render = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        Offset cellCenter(CellOffset offset) => render.localToGlobal(
          render.getOffset(offset) + render.cellSize.center(Offset.zero),
        );

        // Control: tapping an empty cell forwards an SGR mouse report, proving
        // mouse tracking is genuinely active.
        shellWrites.clear();
        await tester.tapAt(cellCenter(const CellOffset(40, 5)));
        await tester.pumpAndSettle();
        final emptyForward = shellWrites.map(String.fromCharCodes).join();
        expect(emptyForward, contains('\x1b[<'));

        // Tapping the hyperlink label opens locally and forwards nothing.
        shellWrites.clear();
        await tester.tapAt(cellCenter(const CellOffset(3, 3)));
        await tester.pumpAndSettle();

        expect(launchedUrls, [url]);
        final linkForward = shellWrites.map(String.fromCharCodes).join();
        expect(linkForward, isNot(contains('\x1b[<')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'offers reconnect when the active session disappears unexpectedly',
      (tester) async {
        final reconnectClient = _MockSshClient();
        final reconnectShell = _MockShellChannel();
        final reconnectDoneCompleter = Completer<void>();
        final reconnectStdoutController =
            StreamController<Uint8List>.broadcast();
        final reconnectCompleter = Completer<void>();
        addTearDown(reconnectStdoutController.close);

        _stubTrueColorLoginShell(reconnectClient, reconnectShell);
        when(
          () => reconnectShell.stdout,
        ).thenAnswer((_) => reconnectStdoutController.stream);
        when(
          () => reconnectShell.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(
          () => reconnectShell.done,
        ).thenAnswer((_) => reconnectDoneCompleter.future);
        when(() => reconnectShell.write(any())).thenAnswer((_) {});

        final reconnectSession = SshSession(
          connectionId: 8,
          hostId: host.id,
          client: reconnectClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        final activeSessions = _TestActiveSessionsNotifier(
          session,
          reconnectSession: reconnectSession,
          connectCompleter: reconnectCompleter,
        )..disconnectedConnectionIds.add(reconnectSession.connectionId);

        await pumpScreen(tester, activeSessions: activeSessions);
        verify(
          () => sshClient.execute(
            _trueColorLoginShellCommand(session.config),
            pty: any(named: 'pty'),
          ),
        ).called(1);

        await activeSessions.disconnect(session.connectionId);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('Reconnect'), findsOneWidget);
        expect(activeSessions.connectForceNewValues, isEmpty);

        await tester.tap(find.text('Reconnect'));
        await tester.pump();

        expect(find.text('Connecting to Terminal test host'), findsOneWidget);
        expect(find.text('Preparing connection…'), findsWidgets);

        reconnectCompleter.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(activeSessions.connectForceNewValues, <bool>[true]);
        verify(
          () => reconnectClient.execute(
            _trueColorLoginShellCommand(reconnectSession.config),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        expect(activeSessions.disconnectedConnectionIds, <int>[
          session.connectionId,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'offers reconnect when the session lookup is stale',
      (tester) async {
        final reconnectClient = _MockSshClient();
        final reconnectShell = _MockShellChannel();
        final reconnectDoneCompleter = Completer<void>();
        final reconnectStdoutController =
            StreamController<Uint8List>.broadcast();
        final reconnectCompleter = Completer<void>();
        addTearDown(reconnectStdoutController.close);

        _stubTrueColorLoginShell(reconnectClient, reconnectShell);
        when(
          () => reconnectShell.stdout,
        ).thenAnswer((_) => reconnectStdoutController.stream);
        when(
          () => reconnectShell.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(
          () => reconnectShell.done,
        ).thenAnswer((_) => reconnectDoneCompleter.future);
        when(() => reconnectShell.write(any())).thenAnswer((_) {});

        final reconnectSession = SshSession(
          connectionId: 8,
          hostId: host.id,
          client: reconnectClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        final activeSessions = _TestActiveSessionsNotifier(
          session,
          reconnectSession: reconnectSession,
          connectCompleter: reconnectCompleter,
        )..disconnectedConnectionIds.add(reconnectSession.connectionId);

        await pumpScreen(tester, activeSessions: activeSessions);
        verify(
          () => sshClient.execute(
            _trueColorLoginShellCommand(session.config),
            pty: any(named: 'pty'),
          ),
        ).called(1);

        activeSessions.dropSessionButKeepConnectedState(session.connectionId);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('Reconnect'), findsOneWidget);
        expect(activeSessions.connectForceNewValues, isEmpty);

        await tester.tap(find.text('Reconnect'));
        await tester.pump();

        expect(find.text('Connecting to Terminal test host'), findsOneWidget);
        expect(find.text('Preparing connection…'), findsWidgets);

        reconnectCompleter.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(activeSessions.connectForceNewValues, <bool>[true]);
        verify(
          () => reconnectClient.execute(
            _trueColorLoginShellCommand(reconnectSession.config),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('holds wake lock while an opted-in terminal is active', (
      tester,
    ) async {
      await SettingsService(
        db,
      ).setBool(SettingKeys.terminalWakeLock, value: true);

      await pumpScreen(tester);
      await tester.pump();

      expect(wakelockPlatform.toggleCalls, contains(true));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(wakelockPlatform.toggleCalls.last, false);
    });

    testWidgets('stale terminal screens do not clear current input callbacks', (
      tester,
    ) async {
      final visibleScreens = ValueNotifier(<String>['first']);
      addTearDown(visibleScreens.dispose);

      await tester.pumpWidget(
        buildScreen(
          overrides: [
            themeModeNotifierProvider.overrideWith(
              () => _TestThemeModeNotifier(ThemeMode.light),
            ),
          ],
          child: MaterialApp(
            home: ValueListenableBuilder<List<String>>(
              valueListenable: visibleScreens,
              builder: (context, screenKeys, _) => Stack(
                children: [
                  for (final screenKey in screenKeys)
                    TerminalScreen(
                      key: ValueKey(screenKey),
                      hostId: host.id,
                      connectionId: session.connectionId,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final firstOutputHandler = session.terminal!.onOutput;
      expect(firstOutputHandler, isNotNull);

      visibleScreens.value = <String>['first', 'second'];
      await tester.pump();
      await tester.pump();

      final currentOutputHandler = session.terminal!.onOutput;
      expect(currentOutputHandler, isNotNull);
      expect(currentOutputHandler, isNot(same(firstOutputHandler)));

      visibleScreens.value = <String>['second'];
      await tester.pump();
      await tester.pump();

      expect(session.terminal!.onOutput, same(currentOutputHandler));

      shellWrites.clear();
      session.terminal!.onOutput?.call('x');

      expect(utf8.decode(shellWrites.expand((chunk) => chunk).toList()), 'x');
    });

    testWidgets('remote OSC palette changes repaint and reset the terminal', (
      tester,
    ) async {
      await pumpScreen(tester);
      final initialTheme = tester
          .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
          .theme;

      session.debugHandlePrivateOsc('11', const ['#102030']);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
            .theme
            .background,
        const Color(0xFF102030),
      );

      session.debugHandlePrivateOsc('111', const []);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
            .theme
            .background,
        initialTheme.background,
      );
    });

    testWidgets('previous command advances past a mark clamped at the bottom', (
      tester,
    ) async {
      final terminal = session.terminal!;
      for (var row = 0; row < 70; row += 1) {
        terminal.write('command output $row\r\n');
        if (row == 10 || row == 35 || row == 65) {
          session.debugHandlePrivateOsc('133', const ['C']);
        }
      }

      await pumpScreen(tester);
      final terminalView = tester.widget<MonkeyTerminalView>(
        find.byType(MonkeyTerminalView),
      );
      final scrollController = terminalView.scrollController!;
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();

      await openTerminalOverflowMenu(tester);
      await tester.tap(terminalMenuItemButton('Previous Command (3)'));
      await tester.pumpAndSettle();
      final firstOffset = scrollController.offset;

      await openTerminalOverflowMenu(tester);
      await tester.tap(terminalMenuItemButton('Previous Command (3)'));
      await tester.pumpAndSettle();
      final secondOffset = scrollController.offset;

      expect(firstOffset, scrollController.position.maxScrollExtent);
      expect(secondOffset, lessThan(firstOffset));
    });

    for (final (updateAgents, adapters) in [
      (false, false),
      (true, false),
      (true, true),
    ]) {
      testWidgets(
        'agent update dots route to manager and survive resume, updated=$updateAgents, adapters=$adapters',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          session = SshSession(
            connectionId: session.connectionId,
            hostId: session.hostId,
            client: sshClient,
            config: session.config,
          );
          final management = _MockAgentManagementService();
          final tmuxService = _MockTmuxService();
          when(
            () => tmuxService.invalidateInstalledAgentTools(any()),
          ).thenReturn(null);
          when(
            () => tmuxService.prefetchInstalledAgentTools(any()),
          ).thenAnswer((_) async {});
          var runtimes = [
            for (final definition
                in (adapters
                        ? agentStandaloneAcpRuntimeDefinitions
                        : agentCliRuntimeDefinitions)
                    .take(2))
              AgentRuntimeInfo(
                definition: definition,
                status: AgentRuntimeStatus.updateAvailable,
                installedVersion: '1.0.0',
                latestVersion: '1.1.0',
                managedByPackageManager: true,
              ),
          ];
          when(
            () => management.checkForUpdates(session),
          ).thenAnswer((_) async => runtimes);
          when(
            () => management.refreshAll(
              session,
              onDiscovered: any(named: 'onDiscovered'),
            ),
          ).thenAnswer((_) async => runtimes);
          for (final runtime in runtimes) {
            when(
              () => management.installOrUpdate(
                session,
                runtime.definition,
                update: true,
                current: runtime,
                onOutput: any(named: 'onOutput'),
              ),
            ).thenAnswer((_) async {
              runtimes = [
                for (final item in runtimes)
                  if (item.definition.id == runtime.definition.id)
                    AgentRuntimeInfo(
                      definition: item.definition,
                      status: AgentRuntimeStatus.installed,
                      installedVersion: '1.1.0',
                      managedByPackageManager: true,
                    )
                  else
                    item,
              ];
              return const AgentRuntimeActionResult(
                succeeded: true,
                output: '',
              );
            });
          }
          const dotKey = ValueKey('terminal-agent-updates-dot');
          bool dotVisible() =>
              tester.widget<Badge>(find.byKey(dotKey)).isLabelVisible;
          await pumpScreen(
            tester,
            agentManagementService: management,
            tmuxService: tmuxService,
          );
          expect(dotVisible(), isFalse);
          await tester.pump(const Duration(seconds: 10));
          await tester.pumpAndSettle();
          expect(dotVisible(), isTrue);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(TerminalScreen)),
          );
          unawaited(
            container
                .read(agentUpdateNotificationsNotifierProvider.notifier)
                .setEnabled(enabled: false),
          );
          await tester.pumpAndSettle();
          expect(dotVisible(), isFalse);
          unawaited(
            container
                .read(agentUpdateNotificationsNotifierProvider.notifier)
                .setEnabled(enabled: true),
          );
          await tester.pumpAndSettle();
          expect(dotVisible(), isTrue);
          expect(find.byType(MaterialBanner), findsNothing);
          expect(find.text('Update now'), findsNothing);
          await openTerminalOverflowMenu(tester);
          expect(
            tester
                .widget<Badge>(
                  find.byKey(const ValueKey('agent_management-updates-dot')),
                )
                .isLabelVisible,
            isTrue,
          );
          await tester.tap(terminalMenuItemButton('Agent Management'));
          await tester.pumpAndSettle();
          expect(find.text('2 updates available'), findsOneWidget);
          expect(find.byType(MaterialBanner), findsNothing);
          if (updateAgents) {
            await tester.tap(find.byKey(const ValueKey('agent-update-all')));
            await tester.pumpAndSettle();
            expect(find.text('2 updates available'), findsNothing);
            expect(find.text('Installed v1.1.0'), findsNWidgets(2));
          }
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(dotVisible(), !updateAgents);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await pumpScreen(
            tester,
            agentManagementService: management,
            tmuxService: tmuxService,
          );
          await tester.pump(const Duration(seconds: 12));
          await tester.pumpAndSettle();
          expect(dotVisible(), !updateAgents);
          verify(() => management.checkForUpdates(session)).called(1);
          expect(find.byType(MaterialBanner), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'resuming a live terminal does not start another update check',
      (tester) async {
        final management = _MockAgentManagementService();
        when(
          () => management.checkForUpdates(session),
        ).thenAnswer((_) async => const <AgentRuntimeInfo>[]);

        await pumpScreen(tester, agentManagementService: management);
        await tester.pump(const Duration(seconds: 12));
        await tester.pump();

        expect(find.text('Update now'), findsNothing);
        verifyNever(() => management.checkForUpdates(session));
      },
    );

    testWidgets(
      'agent update dot polls without overlap and pauses when hidden',
      (tester) async {
        final management = _MockAgentManagementService();
        final definition = agentCliRuntimeDefinitions.first;
        final update = AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.updateAvailable,
          installedVersion: '1.0.0',
          latestVersion: '1.1.0',
        );
        final first = Completer<List<AgentRuntimeInfo>>();
        var calls = 0;
        when(
          () => management.checkForUpdates(session, forceRefresh: true),
        ).thenAnswer((_) {
          calls++;
          if (calls == 1) return first.future;
          if (calls == 2) return Future.error(StateError('offline'));
          return Future.value(<AgentRuntimeInfo>[]);
        });
        bool dotVisible() => tester
            .widget<Badge>(
              find.byKey(const ValueKey('terminal-agent-updates-dot')),
            )
            .isLabelVisible;
        await pumpScreen(tester, agentManagementService: management);
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 1);
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 1);
        first.complete([update]);
        await tester.pumpAndSettle();
        expect(dotVisible(), isTrue);
        await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(dotVisible(), isTrue);
        final context = tester.element(find.byType(TerminalScreen));
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other screen')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 2);
        Navigator.of(tester.element(find.text('Other screen'))).pop();
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        unawaited(
          container
              .read(agentUpdateNotificationsNotifierProvider.notifier)
              .setEnabled(enabled: false),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 2);
        unawaited(
          container
              .read(agentUpdateNotificationsNotifierProvider.notifier)
              .setEnabled(enabled: true),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(calls, 3);
        expect(dotVisible(), isFalse);
        expect(find.byType(MaterialBanner), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(minutes: 5));
        expect(calls, 3);
      },
    );

    testWidgets(
      'free users get an Agent Management paywall and no update checks',
      (tester) async {
        final free = _proMonetizationState.copyWith(
          entitlements: const MonetizationEntitlements.free(),
        );
        when(() => monetizationService.currentState).thenReturn(free);
        when(
          () => monetizationService.canUseFeature(
            MonetizationFeature.agentManagement,
          ),
        ).thenAnswer((_) async => false);
        final management = _MockAgentManagementService();
        await pumpScreen(
          tester,
          agentManagementService: management,
          monetizationState: free,
        );
        await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Badge>(
                find.byKey(const ValueKey('terminal-agent-updates-dot')),
              )
              .isLabelVisible,
          isFalse,
        );
        verifyNever(() => management.checkForUpdates(session));
        verifyNever(
          () => management.checkForUpdates(session, forceRefresh: true),
        );
        await openTerminalOverflowMenu(tester);
        final item = tester.widget<MenuItemButton>(
          terminalMenuItemButton('Agent Management'),
        );
        expect(item.trailingIcon, isNotNull);
        await tester.tap(terminalMenuItemButton('Agent Management'));
        await tester.pumpAndSettle();
        expect(find.text('Manage remote coding agents'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('agent-management-refresh')),
          findsNothing,
        );
        verifyNever(
          () => management.refreshAll(
            session,
            onDiscovered: any(named: 'onDiscovered'),
          ),
        );
      },
    );

    testWidgets('terminal overflow lists agent management', (tester) async {
      await pumpScreen(tester);

      await openTerminalOverflowMenu(tester);

      expect(terminalMenuItemButton('Agent Management'), findsOneWidget);
    });

    testWidgets('terminal overflow menu folds out paste actions', (
      tester,
    ) async {
      await pumpScreen(tester);

      await openTerminalOverflowMenu(tester);

      expect(terminalMenuItemButton('Paste'), findsNothing);
      expect(terminalMenuItemButton('Paste Files'), findsNothing);
      expect(terminalSubmenuButton('Paste'), findsOneWidget);

      await tester.tap(terminalSubmenuButton('Paste'));
      await tester.pumpAndSettle();

      expect(terminalMenuItemButton('Snippets'), findsOneWidget);
      expect(terminalSubmenuButton('Paste'), findsOneWidget);
      expect(terminalMenuItemButton('Paste'), findsOneWidget);
      expect(terminalMenuItemButton('Paste Media'), findsOneWidget);
      expect(terminalMenuItemButton('Paste Files'), findsOneWidget);
    });

    testWidgets('terminal overflow opens live port forward controls', (
      tester,
    ) async {
      await pumpScreen(tester);

      await openTerminalOverflowMenu(tester);
      expect(terminalMenuItemButton('Port Forwards'), findsOneWidget);

      await tester.tap(terminalMenuItemButton('Port Forwards'));
      await tester.pumpAndSettle();

      expect(find.text('no forwards for this host'), findsOneWidget);
      expect(find.text('Add Forward'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets(
      'terminal overflow shows Android device debugging as a switch',
      (tester) async {
        await pumpScreen(tester);

        await openTerminalOverflowMenu(tester);

        final item = terminalMenuItemButton('Device debugging');
        expect(item, findsOneWidget);
        expect(
          find.descendant(of: item, matching: find.byType(Switch)),
          findsOneWidget,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'terminal overflow hides device debugging on iOS',
      (tester) async {
        await pumpScreen(tester);

        await openTerminalOverflowMenu(tester);

        expect(terminalMenuItemButton('Device debugging'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'device debugging switch opens Wireless debugging setup',
      (tester) async {
        await pumpScreen(
          tester,
          deviceDebugPlatform: _FakeAndroidDeviceDebugPlatform(),
          remoteAdbCommandRunner: _FakeRemoteAdbCommandRunner(),
        );

        await openTerminalOverflowMenu(tester);
        await tester.tap(terminalMenuItemButton('Device debugging'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Turn on Wireless debugging in Android Developer options, '
            'then search again.',
          ),
          findsOneWidget,
        );
        expect(find.text('Open Wireless debugging'), findsOneWidget);
        expect(find.text('Search again'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'terminal overflow opens active local forwards in browser tabs',
      (tester) async {
        session = _ActiveTunnelsSshSession(
          connectionId: session.connectionId,
          hostId: host.id,
          client: sshClient,
          config: session.config,
          activeTunnels: const [
            ActiveTunnelInfo(
              portForwardId: -1,
              localHost: '127.0.0.1',
              localPort: 49154,
              browserHost: 'dev-box.localhost',
              browserPort: 49154,
              remoteHost: '127.0.0.1',
              remotePort: 4000,
              isLocal: true,
              isAutomatic: true,
            ),
            ActiveTunnelInfo(
              portForwardId: -2,
              localHost: '127.0.0.1',
              localPort: 49153,
              browserHost: 'dev-box.localhost',
              browserPort: 49153,
              remoteHost: '127.0.0.1',
              remotePort: 4898,
              isLocal: true,
              isAutomatic: true,
              isShellRelated: true,
            ),
            ActiveTunnelInfo(
              portForwardId: 42,
              localHost: '127.0.0.1',
              localPort: 49152,
              browserHost: 'monkeyssh-16.localhost',
              browserPort: 49152,
              remoteHost: 'example.com',
              remotePort: 80,
              isLocal: true,
            ),
            ActiveTunnelInfo(
              portForwardId: 43,
              localHost: '0.0.0.0',
              localPort: 3000,
              browserHost: 'monkeyssh-17.localhost',
              browserPort: 3000,
              remoteHost: 'localhost',
              remotePort: 3000,
              isLocal: true,
            ),
            ActiveTunnelInfo(
              portForwardId: 44,
              localHost: '127.0.0.1',
              localPort: 15432,
              remoteHost: 'localhost',
              remotePort: 5432,
              isLocal: false,
            ),
          ],
        )..getOrCreateTerminal();
        final openedLaunches = <PortForwardBrowserLaunch>[];
        final router = GoRouter(
          initialLocation:
              '/terminal/${host.id}?connectionId=${session.connectionId}',
          routes: [
            GoRoute(
              path: '/terminal/:hostId',
              name: Routes.terminal,
              builder: (context, state) => TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
              ),
            ),
            GoRoute(
              path: '/port-forwards/browser',
              name: Routes.portForwardBrowser,
              builder: (context, state) {
                final launch = state.extra! as PortForwardBrowserLaunch;
                return _RecordingPortForwardBrowserPage(
                  launch: launch,
                  onOpened: openedLaunches.add,
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          buildScreen(child: MaterialApp.router(routerConfig: router)),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final browserItem = terminalMenuItemButton('Open Forwarded Browser');
        expect(browserItem, findsOneWidget);

        await tester.tap(find.text('Open Forwarded Browser'));
        await tester.pumpAndSettle();

        expect(find.text('Forward browser opened'), findsOneWidget);
        final launch = openedLaunches.last;
        expect(launch.selectedIndex, 0);
        expect(launch.tabs.map((tab) => tab.uri.toString()).toList(), [
          'http://dev-box.localhost:49153',
          'http://monkeyssh-17.localhost:3000',
          'http://monkeyssh-16.localhost:49152',
          'http://dev-box.localhost:49154',
        ]);
        expect(launch.tabs.map((tab) => tab.sourceUri.toString()).toList(), [
          'http://127.0.0.1:4898',
          'http://127.0.0.1:3000',
          'http://127.0.0.1:49152',
          'http://127.0.0.1:4000',
        ]);
        expect(launch.tabs.map((tab) => tab.title).toList(), [
          'Port 4898',
          '127.0.0.1:3000',
          '127.0.0.1:49152',
          'Port 4000',
        ]);
        expect(launch.tabs.map((tab) => tab.group).toList(), [
          PortForwardBrowserTabGroup.savedHost,
          PortForwardBrowserTabGroup.savedForward,
          PortForwardBrowserTabGroup.savedForward,
          PortForwardBrowserTabGroup.sharedHost,
        ]);

        router.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    testWidgets(
      'mobile terminal overflow menu omits sensitive keyboard action',
      (tester) async {
        await pumpScreen(tester);

        await openTerminalOverflowSubmenu(tester, 'Options');

        expect(
          terminalCheckboxMenuButton('Tap to Show Keyboard'),
          findsOneWidget,
        );
        expect(find.text('Sensitive Keyboard'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'desktop Native Selection selects and copies rendered text',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        session.terminal!.write('alpha beta\r\n');
        await pumpScreen(tester);
        await openTerminalOverflowMenu(tester);
        await tester.tap(terminalMenuItemButton('Native Selection'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .useSystemSelection,
          isTrue,
        );
        final render = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        final start = render.localToGlobal(
          render.getOffset(const CellOffset(0, 0)) +
              Offset(1, render.cellSize.height / 2),
        );
        final end = render.localToGlobal(
          render.getOffset(const CellOffset(5, 0)) +
              Offset(1, render.cellSize.height / 2),
        );
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(end);
        await mouse.up();
        await tester.pump();
        expect(render.getSelectedContent()?.plainText, 'alpha');
        final contextClick = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await contextClick.up();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy').last);
        await tester.pumpAndSettle();
        expect(copied, 'alpha');
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .useSystemSelection,
          isFalse,
        );
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'overflow menu shows Create Snippet when system selection has text',
      (tester) async {
        session.terminal!.write('echo hello\n');
        await pumpScreen(tester);
        await tester.pump();

        Finder createSnippetItem() => terminalMenuItemButton('Create Snippet');

        await openTerminalOverflowMenu(tester);
        expect(createSnippetItem(), findsNothing);

        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();

        final state = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = state.renderTerminal;
        renderTerminal.dispatchSelectionEvent(
          SelectWordSelectionEvent(
            globalPosition: renderTerminal.localToGlobal(
              renderTerminal.getOffset(const CellOffset(0, 0)) +
                  renderTerminal.cellSize.center(Offset.zero),
            ),
          ),
        );
        await tester.pump();

        await openTerminalOverflowMenu(tester);
        expect(createSnippetItem(), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('browse files ignores duplicate taps while SFTP is opening', (
      tester,
    ) async {
      var sftpOpenCount = 0;
      final router = GoRouter(
        initialLocation:
            '/terminal/${host.id}?connectionId=${session.connectionId}',
        routes: [
          GoRoute(
            path: '/terminal/:hostId',
            name: Routes.terminal,
            builder: (context, state) => TerminalScreen(
              hostId: host.id,
              connectionId: session.connectionId,
            ),
          ),
          GoRoute(
            path: '/sftp/:hostId',
            name: Routes.sftp,
            builder: (context, state) =>
                _RecordingSftpPage(onOpened: () => sftpOpenCount += 1),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        buildScreen(child: MaterialApp.router(routerConfig: router)),
      );
      await tester.pump();
      await tester.pump();

      final browseFilesButton = find.byTooltip('Browse files');
      expect(browseFilesButton, findsOneWidget);

      await tester.tap(browseFilesButton);
      await tester.tap(browseFilesButton);
      await tester.pumpAndSettle();

      expect(sftpOpenCount, 1);
      expect(find.text('SFTP opened'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Browse files'));
      await tester.pumpAndSettle();

      expect(sftpOpenCount, 2);
    });

    testWidgets('shows jump host indicator for tunneled sessions', (
      tester,
    ) async {
      session = SshSession(
        connectionId: 7,
        hostId: host.id,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'terminal.example.com',
          port: 22,
          username: 'root',
          jumpHost: SshConnectionConfig(
            hostname: 'bastion.example.com',
            port: 22,
            username: 'bastion',
          ),
        ),
      )..getOrCreateTerminal();

      await pumpScreen(tester);

      final jumpHostIcon = find.byIcon(Icons.alt_route);
      final connectedIcon = find.byIcon(Icons.check_circle_outline);
      expect(find.byTooltip('Connected through jump host'), findsOneWidget);
      expect(jumpHostIcon, findsOneWidget);
      expect(find.byTooltip('Connected'), findsOneWidget);
      expect(connectedIcon, findsOneWidget);

      final connectedRect = tester.getRect(connectedIcon);
      final jumpHostRect = tester.getRect(jumpHostIcon);
      expect(connectedRect.overlaps(jumpHostRect), isTrue);

      final jumpHostIconWidget = tester.widget<Icon>(jumpHostIcon);
      expect(
        jumpHostIconWidget.color,
        Theme.of(tester.element(jumpHostIcon)).colorScheme.surface,
      );

      final titleLeft = tester.getTopLeft(find.text('Terminal test host')).dx;
      expect(titleLeft - connectedRect.left, lessThan(40));
    });

    testWidgets(
      'does not send synthetic terminal reports to an idle shell prompt',
      (tester) async {
        await pumpScreen(tester);
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isEmpty);
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'refreshes the active TUI when theme mode changes',
      (tester) async {
        await pumpScreen(tester);
        enablePlainTuiSignals();
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\x1b[?997;1n')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;0;')));
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'does not push default colors into an idle Windows ConPTY shell',
      (tester) async {
        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b[?9001h\x1b[?1004h')),
        );
        await tester.pump(const Duration(milliseconds: 20));
        expect(session.terminalWin32InputMode, isTrue);
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        final decodedWin32Input = writtenShellText.replaceAllMapped(
          RegExp(r'\x1b\[0;0;(\d+);1;0;1_'),
          (match) => String.fromCharCode(int.parse(match.group(1)!)),
        );
        expect(decodedWin32Input, contains('\x1b[O\x1b[I'));
        expect(decodedWin32Input, isNot(contains('\x1b]10;')));
        expect(decodedWin32Input, isNot(contains('\x1b]11;')));
        expect(decodedWin32Input, isNot(contains('\x1b[?997;1n')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'pushes updated default colors through Windows ConPTY for a TUI',
      (tester) async {
        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b[?9001h\x1b[?1004h')),
        );
        await tester.pump(const Duration(milliseconds: 20));
        expect(session.terminalWin32InputMode, isTrue);
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();

        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b]4;0;?\x1b\\')),
        );
        await tester.pump(const Duration(milliseconds: 20));
        shellWrites.clear();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        final decodedWin32Input = writtenShellText.replaceAllMapped(
          RegExp(r'\x1b\[0;0;(\d+);1;0;1_'),
          (match) => String.fromCharCode(int.parse(match.group(1)!)),
        );
        expect(
          decodedWin32Input,
          contains(
            buildTerminalThemeDefaultColorReports(
              monkey_themes.TerminalThemes.defaultDarkTheme,
            ),
          ),
        );
        expect(decodedWin32Input, isNot(contains('\x1b[?997;1n')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'refreshes an active TUI when assigning the first session theme',
      (tester) async {
        await pumpScreen(tester);
        enablePlainTuiSignals();
        session.terminalTheme = null;
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'refreshes the active TUI when platform brightness changes',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpScreen(tester, themeMode: ThemeMode.system);
        enablePlainTuiSignals();
        shellWrites.clear();

        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        tester.binding.platformDispatcher.onPlatformBrightnessChanged?.call();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\x1b[?997;1n')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;0;')));
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'refreshes the active TUI when terminal theme settings change',
      (tester) async {
        await pumpScreen(tester);
        enablePlainTuiSignals();
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(terminalThemeSettingsProvider.notifier)
            .setLightTheme(monkey_themes.TerminalThemes.githubLightDefault.id);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\x1b[?997;2n')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;0;')));
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.githubLightDefault.id,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'reasserts the current theme when reopening an existing active TUI',
      (tester) async {
        session.terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;
        enablePlainTuiSignals();
        shellWrites.clear();

        await pumpScreen(tester);
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultLightThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'reasserts the current theme when an active TUI resumes from background',
      (tester) async {
        await pumpScreen(tester);
        enablePlainTuiSignals();
        shellWrites.clear();

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O\x1b[I'));
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultLightThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'build-path sets session.terminalTheme on initial build',
      (tester) async {
        await pumpScreen(tester);

        // After the initial build sequence the session must have a theme.
        expect(session.terminalTheme, isNotNull);
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultLightThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'build-path does not re-trigger TUI refresh on rebuild with unchanged '
      'effective theme (idempotency guard)',
      (tester) async {
        await pumpScreen(tester);
        // Enable plain-TUI signals so that a "first theme assigned to session"
        // event would cause focus-loss/focus-gain writes to the shell if the
        // theme were re-applied.
        enablePlainTuiSignals();

        // Manually clear the session theme to simulate the state that would
        // cause a spurious TUI refresh if the build-path guard were absent:
        // session.terminalTheme == null means _shouldRefreshFirstTheme == true.
        session.terminalTheme = null;
        shellWrites.clear();

        // Trigger a rebuild without any theme change by switching the terminal
        // into the alternate screen buffer, which causes _onTerminalStateChanged
        // to call setState.
        session.terminal!.write('\x1b[?1049h');
        await tester.pump();

        final writtenText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );

        // The build-path guard (_lastBuildAppliedTheme) must prevent
        // _applyTerminalThemeToSession from being called again — no TUI
        // refresh writes and the session theme should remain null.
        expect(writtenText, isEmpty);
        expect(session.terminalTheme, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'build-path re-applies theme after effective theme changes between '
      'rebuilds (guard does not suppress new theme)',
      (tester) async {
        await pumpScreen(tester);
        enablePlainTuiSignals();
        // Simulate the session theme being cleared (e.g. after a fresh
        // connection).
        session.terminalTheme = null;
        shellWrites.clear();

        // Change the effective theme — _lastBuildAppliedTheme is now stale.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // The new dark theme must have been applied to the session.
        expect(
          session.terminalTheme?.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    Future<void> pumpTmuxScreen(
      WidgetTester tester,
      _MockTmuxService tmuxService, {
      SettingsService? settingsServiceOverride,
      AgentSessionDiscoveryService? agentSessionDiscoveryServiceOverride,
      bool simulateAttachedTuiSignals = false,
      RemoteFileService? remoteFileServiceOverride,
      Stream<TmuxWindowChangeEvent>? windowEvents,
    }) async {
      const tmuxSessionName = 'work';
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: true),
        TmuxWindow(index: 1, name: 'agent', isActive: false),
      ];

      // Attached TUIs enable focus reporting before the screen starts.
      if (simulateAttachedTuiSignals) {
        session.terminal!.write('\x1b[?1004h');
      }

      stubTmuxWindows(
        tmuxService,
        tmuxSessionName,
        windows,
        events: windowEvents,
      );
      when(
        () => tmuxService.foregroundSessionNameOrThrow(session),
      ).thenAnswer((_) async => tmuxSessionName);

      when(
        () => tmuxService.selectWindow(
          session,
          tmuxSessionName,
          1,
          windowId: any(named: 'windowId'),
          extraFlags: any(named: 'extraFlags'),
          clientImageSignatures: any(named: 'clientImageSignatures'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => tmuxService.refreshForegroundClients(
          session,
          tmuxSessionName,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => tmuxService.hasForegroundClientOrThrow(
          session,
          tmuxSessionName,
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.currentPanePath(
          session,
          tmuxSessionName,
          priority: any(named: 'priority'),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.createWindow(
          session,
          tmuxSessionName,
          command: any(named: 'command'),
          name: any(named: 'name'),
          workingDirectory: any(named: 'workingDirectory'),
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      await tester.pumpWidget(
        buildScreen(
          overrides: [
            if (remoteFileServiceOverride != null)
              remoteFileServiceProvider.overrideWithValue(
                remoteFileServiceOverride,
              ),
            tmuxServiceProvider.overrideWithValue(tmuxService),
            if (settingsServiceOverride != null)
              settingsServiceProvider.overrideWithValue(
                settingsServiceOverride,
              ),
            if (agentSessionDiscoveryServiceOverride != null)
              agentSessionDiscoveryServiceProvider.overrideWithValue(
                agentSessionDiscoveryServiceOverride,
              ),
          ],
          initialTmuxSessionName: tmuxSessionName,
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (final interruption in ['none', 'typing', 'window', 'partial']) {
      testWidgets(
        'clipboard content URI upload handles $interruption',
        (tester) async {
          final files = _MockRemoteFileService();
          final sftp = _MockSftpClient();
          final uploaded = <List<int>>[];
          final upload = Completer<void>();
          final events = StreamController<TmuxWindowChangeEvent>.broadcast();
          addTearDown(events.close);
          when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
          when(
            () => files.resolveInitialDirectory(sftp),
          ).thenAnswer((_) async => '/home/test');
          when(
            () => files.ensureDirectoryExists(
              sftp,
              any(),
              mode: any(named: 'mode'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => files.uploadStream(
              sftp: sftp,
              remotePath: any(named: 'remotePath'),
              stream: any(named: 'stream'),
              applyPrivateMode: any(named: 'applyPrivateMode'),
            ),
          ).thenAnswer((invocation) async {
            final stream =
                invocation.namedArguments[#stream] as Stream<List<int>>;
            uploaded.add(await stream.expand((chunk) => chunk).toList());
            await upload.future;
          });
          const pasteboard = MethodChannel('pasteboard');
          const content = MethodChannel(
            'xyz.depollsoft.monkeyssh/clipboard_content',
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            pasteboard,
            (call) async => call.method == 'files'
                ? [
                    'content://clipboard/one',
                    if (interruption == 'partial') 'content://clipboard/two',
                  ]
                : null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            content,
            (call) async => {
              'name':
                  (call.arguments as Map)['uri'] == 'content://clipboard/one'
                  ? 'one.txt'
                  : 'two.txt',
              'bytes': Uint8List.fromList([1, 2, 3]),
            },
          );
          addTearDown(() {
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              pasteboard,
              null,
            );
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              content,
              null,
            );
          });
          if (interruption == 'window') {
            await pumpTmuxScreen(
              tester,
              _MockTmuxService(),
              remoteFileServiceOverride: files,
              windowEvents: events.stream,
            );
          } else {
            await pumpScreen(tester, remoteFileService: files);
          }
          await tester.pumpAndSettle();
          session.terminal!.write('\x1b[?2004h');
          shellWrites.clear();
          await tester.ensureVisible(find.byTooltip('Paste'));
          await tester.tap(find.byTooltip('Paste'));
          await tester.pumpAndSettle();
          expect(find.text('Upload clipboard files?'), findsOneWidget);
          await tester.tap(find.text('Upload and paste'));
          await tester.pumpAndSettle();
          expect(uploaded, [
            [1, 2, 3],
          ]);
          final toolbar = tester.widget<KeyboardToolbar>(
            find.byType(KeyboardToolbar),
          );
          if (interruption == 'typing') {
            toolbar.onKeyPressed!();
            session.terminal!.textInput('typed');
          } else if (interruption == 'window') {
            events.add(
              const TmuxWindowListEvent([
                TmuxWindow(index: 0, name: 'shell', isActive: false),
                TmuxWindow(index: 1, name: 'agent', isActive: true),
              ]),
            );
            await tester.pump();
          } else if (interruption == 'partial') {
            final originalOutput = session.terminal!.onOutput!;
            session.terminal!.onOutput = (text) {
              originalOutput(text);
              if (text.contains('one.txt')) {
                scheduleMicrotask(toolbar.onKeyPressed!);
              }
            };
          }
          upload.complete();
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          final output = utf8.decode(
            shellWrites.expand((chunk) => chunk).toList(),
          );
          expect(
            output,
            interruption == 'typing' || interruption == 'window'
                ? isNot(contains('one.txt'))
                : contains('one.txt'),
          );
          if (interruption == 'partial') {
            expect(uploaded, hasLength(2));
            expect(output, isNot(contains('two.txt')));
            expect(find.textContaining('pasted 1 of 2 paths'), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    for (final failOldLoad in [false, true]) {
      testWidgets(
        'bar recovery discards an old ${failOldLoad ? 'error' : 'result'}',
        (tester) async {
          final tmux = _MockTmuxService();
          final events = StreamController<TmuxWindowChangeEvent>.broadcast();
          addTearDown(events.close);
          await pumpTmuxScreen(tester, tmux, windowEvents: events.stream);
          await tester.pumpAndSettle();
          final oldLoad = Completer<List<TmuxWindow>>();
          final freshLoad = Completer<List<TmuxWindow>>();
          var calls = 0;
          when(() => tmux.listWindows(session, 'work')).thenAnswer((_) {
            calls++;
            if (calls == 1) return oldLoad.future;
            if (calls == 2) {
              return Future.value(const [
                TmuxWindow(index: 0, name: 'recovered', isActive: true),
              ]);
            }
            return freshLoad.future;
          });
          events.add(const TmuxWindowReloadEvent());
          await tester.pump();
          expect(calls, 1);
          final barFinder = find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_TmuxExpandableBar',
          );
          final dynamic bar = tester.widget(barFinder);
          final dynamic barState = tester.state(barFinder);
          final recovery =
              // ignore: avoid_dynamic_calls
              bar.onWindowLoadStalled(session, 'work') as Future<void>;
          await tester.pump(const Duration(milliseconds: 500));
          await recovery;
          await tester.pump();
          expect(calls, 2);
          if (failOldLoad) {
            oldLoad.completeError(StateError('old load'));
          } else {
            oldLoad.complete(const [
              TmuxWindow(index: 0, name: 'stale', isActive: true),
            ]);
          }
          await tester.pump();
          expect(calls, 3);
          expect(
            // ignore: avoid_dynamic_calls
            (barState.currentWindowsSnapshot as List<TmuxWindow>?)?.map(
              (window) => window.name,
            ),
            isNot(contains('stale')),
          );
          await tester.pump(const Duration(seconds: 1));
          freshLoad.complete(const [
            TmuxWindow(index: 0, name: 'fresh', isActive: true),
          ]);
          await tester.pumpAndSettle();
          expect(
            // ignore: avoid_dynamic_calls
            (barState.currentWindowsSnapshot as List<TmuxWindow>).single.name,
            'fresh',
          );
          expect(calls, 3);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    testWidgets(
      'shows the detected tmux version in terminal info',
      (tester) async {
        final tmuxService = _MockTmuxService()..detectedVersionValue = '3.4';
        await pumpTmuxScreen(tester, tmuxService);
        await tester.pump();

        await openTerminalOverflowSubmenu(tester, 'Options');
        final showTerminalInfo = terminalMenuItemButton('Show Terminal Info');
        expect(showTerminalInfo, findsOneWidget);

        await tester.tap(showTerminalInfo);
        await tester.pumpAndSettle();

        expect(find.text('tmux 3.4'), findsOneWidget);
        expect(
          find.byTooltip(
            'Detected tmux version for the active remote multiplexer.',
          ),
          findsOneWidget,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'keeps probing for tmux after an initial inactive result',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true),
        ];
        var foregroundSessionCalls = 0;
        var themeRefreshCount = 0;
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async {
          foregroundSessionCalls += 1;
          return foregroundSessionCalls == 1 ? null : tmuxSessionName;
        });
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {
          themeRefreshCount += 1;
        });

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
          ),
        );

        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsNothing);

        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();

        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        expect(foregroundSessionCalls, greaterThanOrEqualTo(2));
        expect(themeRefreshCount, greaterThanOrEqualTo(1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'primes tmux without outer OSC reports after attach',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(
          tester,
          tmuxService,
          simulateAttachedTuiSignals: true,
        );
        await tester.pump(const Duration(milliseconds: 400));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[I'));
        expect(writtenShellText, isNot(contains('\x1b[?997;')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'sends outer tmux focus without OSC reports after theme changes',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(
          tester,
          tmuxService,
          simulateAttachedTuiSignals: true,
        );
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O'));
        expect(writtenShellText, contains('\x1b[I'));
        expect(writtenShellText, isNot(contains('\x1b[?997;')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux attach opens as the shell startup command',
      (tester) async {
        const sessionName = 'work';
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final loginShell = _MockShellChannel();
        final loginStdout = StreamController<Uint8List>.broadcast();
        final loginDone = Completer<void>();
        final loginOpen = Completer<SSHSession>();
        final loginWrites = <List<int>>[];
        final executedCommands = <String>[];
        addTearDown(() async {
          await loginStdout.close();
          if (!loginDone.isCompleted) {
            loginDone.complete();
          }
        });

        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        )..terminalFontSize = 10;
        when(
          () => shellChannel.resizeTerminal(any(), any(), any(), any()),
        ).thenAnswer((_) {});
        when(() => sshClient.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (invocation) {
            final command = invocation.positionalArguments.single as String;
            executedCommands.add(command);
            return command.contains('COLORTERM=truecolor')
                ? loginOpen.future
                : Future.value(shellChannel);
          },
        );
        when(() => loginShell.stdout).thenAnswer((_) => loginStdout.stream);
        when(
          () => loginShell.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => loginShell.done).thenAnswer((_) => loginDone.future);
        when(() => loginShell.write(any())).thenAnswer((invocation) {
          loginWrites.add(
            List<int>.from(invocation.positionalArguments.single as List<int>),
          );
        });
        when(
          () => loginShell.resizeTerminal(any(), any(), any(), any()),
        ).thenAnswer((_) {});
        when(loginShell.close).thenAnswer((_) {});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: any(named: 'priority'),
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).thenAnswer(
          (_) async => const MonkeyMuxInstallation(
            executablePath: '/tmp/monkeymux',
            platform: 'darwin-arm64',
            version: '1.0.0',
          ),
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer(
          (_) async => const <TmuxWindow>[
            TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          ],
        );
        when(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => monkeyMuxService.currentPaneContext(
            session,
            sessionName,
            priority: any(named: 'priority'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((_) async {});

        final activeSessions = _TestActiveSessionsNotifier(session);
        await tester.pumpWidget(
          buildScreen(
            activeSessions: activeSessions,
            overrides: [
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
            ],
          ),
        );
        expect(session.terminal, isNotNull);
        session.terminal!.resize(59, 50);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        final attachCommands = executedCommands
            .where((command) => command.contains(' attach'))
            .toList(growable: false);
        expect(attachCommands, hasLength(1));
        final attachCommand = attachCommands.single;
        expect(attachCommand, contains('/tmp/monkeymux'));
        expect(attachCommand, contains('--update-policy never'));
        expect(attachCommand, contains(sessionName));
        final viewportSize = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .viewportCellSize!;
        expect(attachCommand, contains('--width ${viewportSize.columns}'));
        expect(attachCommand, contains('--height ${viewportSize.rows}'));
        expect(attachCommand, isNot(contains('--width 59')));
        expect(attachCommand, isNot(contains('--height 50')));
        expect(
          shellWrites.map(utf8.decode).join(),
          isNot(contains('/tmp/monkeymux')),
        );

        final terminalOutputHandler = session.terminal!.onOutput!;
        final terminalResizeHandler = session.terminal!.onResize!;
        await session.closeShell(waitForStreams: false);
        final replacementShellFuture = session.getShell();
        terminalOutputHandler('echo queued\r');
        terminalResizeHandler(100, 32, 800, 512);
        expect(loginWrites, isEmpty);
        loginOpen.complete(loginShell);
        final replacementShell = await replacementShellFuture;

        expect(
          executedCommands.where(
            (command) => command == _trueColorLoginShellCommand(session.config),
          ),
          hasLength(1),
        );
        expect(replacementShell, same(loginShell));
        verify(() => loginShell.resizeTerminal(100, 32, 800, 512)).called(1);
        terminalOutputHandler('echo ready\r');
        terminalResizeHandler(101, 33, 808, 528);
        expect(loginWrites.map(utf8.decode), contains('echo queued\r'));
        expect(loginWrites.map(utf8.decode), contains('echo ready\r'));
        verify(() => loginShell.resizeTerminal(101, 33, 808, 528)).called(1);
        expect(activeSessions.disconnectedConnectionIds, isEmpty);
        expect(find.text('Disconnected'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux attaches on Windows remotes via the ConPTY helper',
      (tester) async {
        const sessionName = 'work';
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final executedCommands = <String>[];
        final requestedPtys = <SSHPtyConfig?>[];

        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        // A Windows OpenSSH banner makes session.remoteIsWindows true; MonkeyMux
        // must still attach (via its ConPTY helper) rather than falling back to
        // a plain shell.
        when(
          () => sshClient.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        when(
          () => shellChannel.resizeTerminal(any(), any(), any(), any()),
        ).thenAnswer((_) {});
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          requestedPtys.add(invocation.namedArguments[#pty] as SSHPtyConfig?);
          return shellChannel;
        });
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: any(named: 'priority'),
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).thenAnswer(
          (_) async => const MonkeyMuxInstallation(
            executablePath: r'C:\Users\me\mm\monkeymux.exe',
            platform: 'windows-amd64',
            version: '1.0.0',
          ),
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer(
          (_) async => const <TmuxWindow>[
            TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          ],
        );
        when(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => monkeyMuxService.currentPaneContext(
            session,
            sessionName,
            priority: any(named: 'priority'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        // The MonkeyMux attach is exec'd (Windows OpenSSH runs it through
        // cmd.exe) with the native path and no POSIX single-quoting.
        expect(executedCommands, hasLength(1));
        expect(
          executedCommands.single,
          contains(r'C:\Users\me\mm\monkeymux.exe attach'),
        );
        expect(executedCommands.single, isNot(contains("'")));
        expect(executedCommands.single, endsWith(' $sessionName'));
        expect(
          requestedPtys,
          [isNull],
          reason:
              'the SSH channel must stay raw; a Windows OpenSSH PTY creates '
              'an outer system ConPTY that strips Kitty APC while preserving '
              'the placeholder cells',
        );
        verifyNever(
          () => shellChannel.resizeTerminal(any(), any(), any(), any()),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'uses MonkeyMux theme hints only for theme changes',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: false, id: '@1'),
        ];
        var themeRefreshCount = 0;
        final refreshedThemes = <TerminalThemeData>[];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        session.terminal!.write('\x1b[?1004h');
        muxFixture
          ..stubPrefetch()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents();
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((invocation) async {
          themeRefreshCount += 1;
          refreshedThemes.add(
            invocation.positionalArguments[2] as TerminalThemeData,
          );
        });

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        shellWrites.clear();
        themeRefreshCount = 0;
        refreshedThemes.clear();

        muxFixture.windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 0,
              id: '@0',
              name: 'Copilot CLI · flutty',
              isActive: true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(themeRefreshCount, 0);
        expect(writtenShellText, isNot(contains('\x1b[O')));
        expect(writtenShellText, isNot(contains('\x1b[I')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));

        shellWrites.clear();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final shellTextAfterThemeChange = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(themeRefreshCount, 1);
        expect(
          refreshedThemes.single.id,
          monkey_themes.TerminalThemes.defaultDarkThemeId,
        );
        expect(shellTextAfterThemeChange, isNot(contains('\x1b[O')));
        expect(shellTextAfterThemeChange, isNot(contains('\x1b[I')));
        expect(shellTextAfterThemeChange, isNot(contains('\x1b]10;')));
        expect(shellTextAfterThemeChange, isNot(contains('\x1b]11;')));
        expect(shellTextAfterThemeChange, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux theme change forces a foreground redraw resize',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        // A foreground agent enables focus reporting; this is the signal that
        // gates theme hints toward a real TUI.
        session.terminal!.write('\x1b[?1004h');
        muxFixture
          ..stubPrefetch()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents()
          ..stubPaneContext()
          ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);

        // Drain any resize/redraw follow-up timers scheduled while the screen
        // settled, then clear recorded interactions, so the verification below
        // only sees the refresh the theme change itself drives (forced re-syncs
        // during connection setup can also request a redraw).
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();
        clearInteractions(monkeyMuxService);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        // The theme actually changed (light -> dark), so the foreground TUI
        // must be forced to fully repaint: MonkeyMux is told to redraw via the
        // theme_changed `redraw` flag; otherwise Copilot CLI keeps its
        // explicitly-colored bars in the old theme.
        verify(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: true,
          ),
        ).called(greaterThanOrEqualTo(1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Windows MonkeyMux settles the redraw on resume after a backgrounded '
      'theme change',
      (tester) async {
        // Regression guard for the resume gap: a theme change that lands while
        // the app is backgrounded (or the connection is down) updates the
        // session theme before any repaint reaches the agent. On resume the
        // re-sync applies the same theme (didThemeChange == false) with
        // forceRemoteRefresh, so the redraw must still be forced from the
        // forced-refresh signal, otherwise Copilot CLI stays painted in the
        // previous theme.
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        session.terminal!.write('\x1b[?1004h');
        muxFixture
          ..stubPrefetch()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents()
          ..stubPaneContext()
          ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();

        // Ignore refreshes emitted while connecting; only the resume re-sync
        // below should matter.
        clearInteractions(monkeyMuxService);
        monkeyMuxService.resizeTerminalCalls.clear();
        when(
          () => sshClient.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

        // A redraw follow-up armed just before backgrounding must be cancelled
        // instead of replaying the hidden TUI after the app is paused.
        final initialWidth = session.terminal!.viewWidth;
        final initialRows = session.terminal!.viewHeight;
        session.terminal!.onResize?.call(
          initialWidth,
          initialRows > 2 ? initialRows - 2 : initialRows + 2,
          initialWidth * 10,
          initialRows * 20,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 300));
        expect(monkeyMuxService.resizeTerminalCalls, isNotEmpty);
        expect(
          monkeyMuxService.resizeTerminalCalls.every((call) => !call.redraw),
          isTrue,
        );
        clearInteractions(monkeyMuxService);
        monkeyMuxService.resizeTerminalCalls.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );

        // Defer a real theme change while backgrounded. It must not redraw the
        // hidden TUI immediately, but resume must deliver one forced refresh.
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        verifyNever(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        verify(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: true,
          ),
        ).called(1);
        expect(monkeyMuxService.resizeTerminalCalls, isEmpty);

        // A later same-theme resume performs only a local repaint. It must not
        // request another full ConPTY replay or arm a resize-redraw follow-up.
        clearInteractions(monkeyMuxService);
        monkeyMuxService.resizeTerminalCalls.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        final width = session.terminal!.viewWidth;
        final rows = session.terminal!.viewHeight;
        session.terminal!.onResize?.call(
          width,
          rows > 1 ? rows - 1 : rows + 1,
          width * 10,
          rows * 20,
        );
        await tester.pump(const Duration(milliseconds: 500));

        verifyNever(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        );
        expect(monkeyMuxService.resizeTerminalCalls, isNotEmpty);
        expect(
          monkeyMuxService.resizeTerminalCalls.every((call) => !call.redraw),
          isTrue,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux redraw obligation survives a refresh superseding it in flight',
      (tester) async {
        // Regression guard for the token-guarded latch clear: while a
        // theme-change refresh is awaiting the remote, a newer forced refresh
        // re-latches the redraw obligation and queues behind it. When the first
        // refresh returns it must NOT clear that newer obligation, so the queued
        // refresh still sends redraw:true (otherwise the newer theme repaints
        // stale).
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        session.terminal!.write('\x1b[?1004h');

        final refreshForceFlags = <bool>[];
        final firstRefresh = Completer<void>();
        var trapIndex = -1;
        muxFixture
          ..stubPrefetch()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents()
          ..stubPaneContext();
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((invocation) async {
          final index = refreshForceFlags.length;
          refreshForceFlags.add(
            invocation.namedArguments[#forceForegroundRedraw] as bool,
          );
          if (index == trapIndex) {
            await firstRefresh.future;
          }
        });

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();

        // Arm the trap so the next refresh (request A) blocks in flight.
        trapIndex = refreshForceFlags.length;

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );

        // A: a real light -> dark change latches the redraw obligation and
        // blocks awaiting the remote.
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        expect(refreshForceFlags.length, trapIndex + 1);
        expect(refreshForceFlags[trapIndex], isTrue);

        // B: a forced re-sync (brightness) re-latches the obligation while A is
        // still in flight and queues behind it.
        tester.binding.platformDispatcher.onPlatformBrightnessChanged?.call();
        await tester.pump();
        await tester.pump();

        // Release A. When it returns it must not clear B's newer obligation.
        firstRefresh.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        // The refresh queued while A was in flight must still carry the redraw.
        expect(
          refreshForceFlags.length,
          greaterThanOrEqualTo(trapIndex + 2),
          reason: 'expected the superseding refresh to run',
        );
        expect(
          refreshForceFlags[trapIndex + 1],
          isTrue,
          reason:
              'a refresh superseding an in-flight one must keep redraw:true',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux window switches wait for replay before following output',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: false, id: '@1'),
        ];
        const activeAgentWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: false, id: '@0'),
          TmuxWindow(
            index: 1,
            name: 'agent',
            isActive: true,
            id: '@1',
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 75,
            ),
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        session.debugHandlePrivateOsc('9', ['4', '1', '50']);
        expect(session.terminalProgress, isNotNull);
        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('row $row\r\n');
        }

        muxFixture
          ..stubPrefetch()
          ..stubPaneContext()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents();
        when(
          () => monkeyMuxService.selectWindow(
            session,
            sessionName,
            1,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).thenAnswer((_) async {
          monkeyMuxService.controlOperations.add('select');
          session.debugHandlePrivateOsc('9', ['4', '1', '65']);
        });
        muxFixture.stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        final scrollableState = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(MonkeyTerminalView),
            matching: find.byType(Scrollable),
          ),
        );
        final position = scrollableState.position;
        expect(position.maxScrollExtent, greaterThan(0));

        position.jumpTo(0);
        await tester.pump();
        expect(position.pixels, 0);

        tester.testTextInput.updateEditingValue(
          _editingValue('stale', selectionOffset: 5),
        );
        await tester.pump();
        tester.testTextInput.log.clear();
        position.jumpTo(0);
        await tester.pump();
        expect(position.pixels, 0);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(position.pixels, 0);
        final resizeCallsBeforeSwitch =
            monkeyMuxService.resizeTerminalCalls.length;
        monkeyMuxService.controlOperations.clear();
        await tester.tap(find.text('agent'));
        await tester.pump();
        await tester.pump();
        expect(position.pixels, 0);
        void expectProgress(int percentage) {
          final progress = find.byKey(const ValueKey('terminal-osc-progress'));
          expect(
            session.terminalProgress,
            TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: percentage,
            ),
          );
          expect(
            tester.widget<LinearProgressIndicator>(progress).value,
            percentage / 100,
          );
          expect(tester.getSemantics(progress).value, '$percentage');
        }

        expectProgress(65);
        expect(
          monkeyMuxService.resizeTerminalCalls.skip(resizeCallsBeforeSwitch),
          isEmpty,
        );
        final selectOperationIndex = monkeyMuxService.controlOperations.indexOf(
          'select',
        );
        expect(selectOperationIndex, isNonNegative);
        expect(
          monkeyMuxService.controlOperations.skip(selectOperationIndex + 1),
          isNot(contains('resize:redraw')),
        );

        muxFixture.windowEvents.add(
          const TmuxWindowListEvent(activeAgentWindows),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        expectProgress(75);
        verify(
          () => monkeyMuxService.selectWindow(
            session,
            sessionName,
            1,
            windowId: '@1',
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).called(1);
        expect(
          monkeyMuxService.resizeTerminalCalls.skip(resizeCallsBeforeSwitch),
          isEmpty,
        );
        expect(position.pixels, 0);
        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isNotEmpty,
        );

        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('agent row $row\r\n');
        }
        await tester.pump();
        await tester.pump();
        expect(position.pixels, position.maxScrollExtent);

        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        final switchResizeCalls = monkeyMuxService.resizeTerminalCalls
            .skip(resizeCallsBeforeSwitch)
            .toList(growable: false);
        expect(switchResizeCalls, isEmpty);
        final resizeCallsAfterWindowReplay =
            monkeyMuxService.resizeTerminalCalls.length;
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final paintCountBeforeSettledRefresh =
            terminalViewState.terminalPaintCount ?? 0;

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          terminalViewState.terminalPaintCount,
          greaterThan(paintCountBeforeSettledRefresh),
        );
        expect(
          monkeyMuxService.resizeTerminalCalls.length,
          resizeCallsAfterWindowReplay,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux close keeps its ID after reindexing during confirmation',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        final createWindowCompleter = Completer<void>();
        final closeWindowCompleter = Completer<void>();
        addTearDown(windowEvents.close);
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            name: 'shell',
            isActive: true,
            id: '@0',
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 40,
            ),
          ),
          TmuxWindow(index: 1, name: 'logs', isActive: false, id: '@1'),
        ];
        const createdWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: false, id: '@0'),
          TmuxWindow(index: 1, name: 'logs', isActive: false, id: '@1'),
          TmuxWindow(
            index: 2,
            name: 'new',
            isActive: true,
            id: '@2',
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 65,
            ),
          ),
        ];
        const remainingWindows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            name: 'new',
            isActive: true,
            id: '@2',
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 75,
            ),
          ),
        ];
        var currentWindows = initialWindows;
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          tmuxWorkingDirectory: '/home/demo',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );

        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => currentWindows);
        when(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => monkeyMuxService.createWindow(
            session,
            sessionName,
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: any(named: 'workingDirectory'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => createWindowCompleter.future);
        when(
          () => monkeyMuxService.killWindow(
            session,
            sessionName,
            1,
            windowId: '@1',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => closeWindowCompleter.future);
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final progressFinder = find.byKey(
          const ValueKey<String>('terminal-osc-progress'),
        );
        expect(
          session.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.normal,
            percentage: 40,
          ),
        );
        expect(
          tester.widget<LinearProgressIndicator>(progressFinder).value,
          0.4,
        );
        expect(tester.getSemantics(progressFinder).value, '40');

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('New window'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empty terminal'));
        await tester.pump();
        await tester.pump();

        verify(
          () => monkeyMuxService.createWindow(
            session,
            sessionName,
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: '/home/demo',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);
        currentWindows = createdWindows;
        windowEvents.add(const TmuxWindowListEvent(createdWindows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          session.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.normal,
            percentage: 65,
          ),
        );

        createWindowCompleter.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          session.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.normal,
            percentage: 65,
          ),
        );
        expect(
          tester.widget<LinearProgressIndicator>(progressFinder).value,
          0.65,
        );
        expect(tester.getSemantics(progressFinder).value, '65');

        if (find.byTooltip('Close window').evaluate().isEmpty) {
          await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
        }
        final closeWindowButtons = find.byTooltip('Close window');
        expect(closeWindowButtons, findsNWidgets(3));
        await tester.tap(closeWindowButtons.at(1));
        await tester.pumpAndSettle();
        expect(find.text('Close window?'), findsOneWidget);
        currentWindows = [
          const TmuxWindow(index: 0, name: 'logs', isActive: false, id: '@1'),
          TmuxWindow(
            index: 1,
            name: 'new',
            isActive: true,
            id: '@2',
            terminalProgress: createdWindows[2].terminalProgress,
          ),
        ];
        windowEvents.add(TmuxWindowListEvent(currentWindows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
        await tester.pump();
        await tester.pump();

        expect(
          find.text('logs'),
          findsNothing,
          reason: 'a confirmed close disappears before remote teardown settles',
        );
        verify(
          () => monkeyMuxService.killWindow(
            session,
            sessionName,
            1,
            windowId: '@1',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);
        currentWindows = remainingWindows;
        windowEvents.add(const TmuxWindowListEvent(remainingWindows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          session.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.normal,
            percentage: 75,
          ),
        );

        closeWindowCompleter.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          session.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.normal,
            percentage: 75,
          ),
        );
        expect(
          tester.widget<LinearProgressIndicator>(progressFinder).value,
          0.75,
        );
        expect(tester.getSemantics(progressFinder).value, '75');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux re-asserts the viewport when the shared grid is too small',
      (tester) async {
        // Regression for the long-standing Windows corruption: once viewport
        // clipping is on, the terminal buffer is sized only by the server. A
        // published grid smaller than the rendered viewport draws output into
        // too few cells and leaves the rest blank, and previously nothing
        // corrected it until the user opened or closed the keyboard.
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture =
            createMuxFixture(tmuxService, monkeyMuxService, sessionName)
              ..stubPrefetch()
              ..stubForegroundClient()
              ..stubWindows(() => initialWindows)
              ..stubWindowEvents()
              ..stubPaneContext()
              ..stubThemeRefresh();

        await muxFixture.pump(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        session
          ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
          ..remoteMuxSessionName = sessionName;
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final viewport = terminalViewState.viewportCellSize!;
        expect(viewport.columns, greaterThan(4));
        expect(viewport.rows, greaterThan(4));
        monkeyMuxService.resizeTerminalCalls.clear();

        final staleColumns = viewport.columns - 4;
        final staleRows = viewport.rows - 3;
        session.terminal!.write('\x1b[?8;$staleRows;${staleColumns}t');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();

        expect(session.terminal!.viewWidth, staleColumns);
        expect(
          monkeyMuxService.resizeTerminalCalls.any(
            (call) =>
                call.columns == viewport.columns && call.rows == viewport.rows,
          ),
          isTrue,
          reason:
              'a shared grid smaller than the viewport must be re-asserted '
              'instead of waiting for the user to resize',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux asks for a repaint when a window switch leaves the pane blank',
      (tester) async {
        // A pane whose foreground app owns its own pixels is cleared on a
        // window switch and refilled only when that app repaints. When the app
        // coalesces or ignores the resize that was supposed to provoke it, the
        // pane stays empty with a perfectly correct grid, so nothing on either
        // side has a reason to speak up and only opening the keyboard escapes.
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: false, id: '@1'),
        ];
        const activeAgentWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: false, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: true, id: '@1'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('row $row\r\n');
        }

        muxFixture.stubPrefetch();
        when(
          () => tmuxService.currentPaneContext(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => null);
        muxFixture
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents();
        when(
          () => monkeyMuxService.selectWindow(
            session,
            sessionName,
            1,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).thenAnswer((_) async {
          monkeyMuxService.controlOperations.add('select');
        });
        muxFixture
          ..stubPaneContext()
          ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        session
          ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
          ..remoteMuxSessionName = sessionName;

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('agent'));
        await tester.pump();
        await tester.pump();

        muxFixture.windowEvents.add(
          const TmuxWindowListEvent(activeAgentWindows),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();

        // The switch replay clears the screen and its scrollback; the frame
        // that should have replaced it never arrives.
        session.terminal!.write('\x1b[H\x1b[2J\x1b[3J');
        await tester.pump();
        monkeyMuxService.resizeTerminalCalls.clear();

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          monkeyMuxService.resizeTerminalCalls.any((call) => call.redraw),
          isTrue,
          reason:
              'an empty pane is the evidence the client needs to ask for the '
              'frame it never received, instead of waiting for the user to '
              'open the keyboard',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux terminal resizes schedule a settled redraw sync',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture =
            createMuxFixture(tmuxService, monkeyMuxService, sessionName)
              ..stubPrefetch()
              ..stubForegroundClient()
              ..stubWindows(() => initialWindows)
              ..stubWindowEvents()
              ..stubPaneContext()
              ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('row $row\r\n');
        }
        await tester.pump();
        await tester.pump();
        final scrollableState = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(MonkeyTerminalView),
            matching: find.byType(Scrollable),
          ),
        );
        final position = scrollableState.position;
        expect(position.maxScrollExtent, greaterThan(0));
        position.jumpTo(0);
        await tester.pump();
        monkeyMuxService.resizeTerminalCalls.clear();

        final width = session.terminal!.viewWidth;
        final height = session.terminal!.viewHeight;
        final nextHeight = height > 1 ? height - 1 : height + 1;
        session.terminal!.resize(
          width,
          nextHeight,
          width * 10,
          nextHeight * 20,
        );
        // The remote resize is throttled (not sent per frame), so let the
        // throttle window elapse; a single size sync should then go out.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));

        expect(monkeyMuxService.resizeTerminalCalls, isNotEmpty);
        expect(monkeyMuxService.resizeTerminalCalls.last.redraw, isFalse);
        final nonRedrawResizeCount = monkeyMuxService.resizeTerminalCalls
            .where((call) => !call.redraw)
            .length;
        session.terminal!.onResize?.call(
          width,
          nextHeight,
          width * 10,
          nextHeight * 20,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          monkeyMuxService.resizeTerminalCalls
              .where((call) => !call.redraw)
              .length,
          nonRedrawResizeCount,
        );

        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(
          monkeyMuxService.resizeTerminalCalls.any((call) => call.redraw),
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(position.pixels, 0);

        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('resized row $row\r\n');
        }
        await tester.pump();
        await tester.pump();
        expect(position.pixels, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'pinch-zoom resize storm is throttled to a few remote syncs',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'agent', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture =
            createMuxFixture(tmuxService, monkeyMuxService, sessionName)
              ..stubPrefetch()
              ..stubForegroundClient()
              ..stubWindows(() => initialWindows)
              ..stubWindowEvents()
              ..stubPaneContext()
              ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        monkeyMuxService.resizeTerminalCalls.clear();

        final width = session.terminal!.viewWidth;
        final baseHeight = session.terminal!.viewHeight;

        // Simulate a pinch sweep: many distinct sizes within one throttle
        // window (only microtasks pumped between them, no real time elapses).
        const steps = 12;
        for (var i = 0; i < steps; i++) {
          final rows = baseHeight > steps ? baseHeight - i : baseHeight + i;
          session.terminal!.onResize?.call(width, rows, width * 10, rows * 20);
          await tester.pump();
        }
        final finalRows = baseHeight > steps
            ? baseHeight - (steps - 1)
            : baseHeight + (steps - 1);

        // Let the throttle window and the settle redraw elapse.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        final nonRedrawSyncs = monkeyMuxService.resizeTerminalCalls
            .where((call) => !call.redraw)
            .toList();
        // The storm of 12 resizes must collapse into only a couple of remote
        // size syncs (leading edge + a trailing coalesced one), not one per
        // event — otherwise the SSH connection floods and wedges.
        expect(nonRedrawSyncs.length, lessThanOrEqualTo(4));
        expect(nonRedrawSyncs.length, greaterThanOrEqualTo(1));
        // The remote must end up at the final size of the gesture.
        expect(nonRedrawSyncs.last.rows, finalRows);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'MonkeyMux active-window events refresh despite paused touch follow',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: false, id: '@1'),
        ];
        const activeAgentWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: false, id: '@0'),
          TmuxWindow(index: 1, name: 'agent', isActive: true, id: '@1'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final muxFixture = createMuxFixture(
          tmuxService,
          monkeyMuxService,
          sessionName,
        );
        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('row $row\r\n');
        }

        muxFixture
          ..stubPrefetch()
          ..stubForegroundClient()
          ..stubWindows(() => initialWindows)
          ..stubWindowEvents()
          ..stubPaneContext()
          ..stubThemeRefresh();

        await muxFixture.pump(tester);

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        final scrollableState = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(MonkeyTerminalView),
            matching: find.byType(Scrollable),
          ),
        );
        final position = scrollableState.position..jumpTo(0);
        await tester.pump();
        expect(position.pixels, 0);
        final resizeCountBeforeWindowEvent =
            monkeyMuxService.resizeTerminalCalls.length;
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        monkeyMuxService.focusClientChangedValue = false;
        final paintCountBeforeLinkTap =
            terminalViewState.terminalPaintCount ?? 0;
        terminalView.onLinkTapDown?.call(
          TapDownDetails(),
          const CellOffset(0, 0),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(monkeyMuxService.focusClientCalls, hasLength(1));
        expect(monkeyMuxService.focusClientCalls.single, (
          sessionName: sessionName,
          columns: session.terminal!.viewWidth,
          rows: session.terminal!.viewHeight,
        ));
        expect(terminalViewState.terminalPaintCount, paintCountBeforeLinkTap);

        monkeyMuxService.focusClientChangedValue = true;
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(MonkeyTerminalView)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(monkeyMuxService.focusClientCalls, hasLength(2));
        expect(
          terminalViewState.terminalPaintCount,
          greaterThan(paintCountBeforeLinkTap),
        );
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .liveOutputAutoScroll,
          isFalse,
        );
        final paintCountBeforeWindowEvent =
            terminalViewState.terminalPaintCount ?? 0;

        muxFixture.windowEvents.add(
          const TmuxWindowListEvent(activeAgentWindows),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();

        expect(
          monkeyMuxService.resizeTerminalCalls.length,
          resizeCountBeforeWindowEvent,
        );
        expect(
          terminalViewState.terminalPaintCount,
          greaterThan(paintCountBeforeWindowEvent),
        );
        expect(position.pixels, 0);
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .liveOutputAutoScroll,
          isTrue,
        );
        for (var row = 0; row < 120; row += 1) {
          session.terminal!.write('active row $row\r\n');
        }
        await tester.pump();
        await tester.pump();
        expect(position.pixels, position.maxScrollExtent);
        final resizeCountAfterWindowRefresh =
            monkeyMuxService.resizeTerminalCalls.length;
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(
          monkeyMuxService.resizeTerminalCalls.length,
          resizeCountAfterWindowRefresh,
        );
        await gesture.up();

        final placeholder = String.fromCharCode(
          kittyGraphicsPlaceholderCodePoint,
        );
        monkeyMuxService.imageReplayFutures
          ..add(
            Future.value(
              MonkeyMuxImageReplayResult(
                served: const {55},
                retryableFailure: true,
              ),
            ),
          )
          ..add(
            Future.value(
              MonkeyMuxImageReplayResult(
                served: const <int>{},
                retryableFailure: false,
              ),
            ),
          );
        session.terminal!.write(
          '\x1b[2J\x1b[H'
          '\x1b[38;5;55m$placeholder'
          '\x1b[38;5;56m$placeholder'
          '\x1b[39m',
        );
        await tester.pump(const Duration(milliseconds: 351));
        await tester.pump();

        expect(monkeyMuxService.imageReplayCalls, hasLength(1));
        expect(
          monkeyMuxService.imageReplayCalls.first.sessionName,
          sessionName,
        );
        expect(
          monkeyMuxService.imageReplayCalls.first.imageIds,
          unorderedEquals(<int>{55, 56}),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(monkeyMuxService.imageReplayCalls, hasLength(1));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(monkeyMuxService.imageReplayCalls, hasLength(2));
        expect(
          monkeyMuxService.imageReplayCalls.last.imageIds,
          unorderedEquals(<int>{56}),
        );

        session.terminal!.write('ordinary output');
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          monkeyMuxService.imageReplayCalls,
          hasLength(2),
          reason: 'explicitly non-retryable misses stay suppressed',
        );

        monkeyMuxService.imageReplayFutures.addAll(
          List<Future<MonkeyMuxImageReplayResult>>.generate(
            4,
            (_) => Future.value(
              MonkeyMuxImageReplayResult(
                served: const <int>{},
                retryableFailure: true,
              ),
            ),
          ),
        );
        session.terminal!.write(
          '\x1b[2J\x1b[H\x1b[38;5;57m$placeholder\x1b[39m',
        );
        await tester.pump(const Duration(milliseconds: 351));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 751));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1501));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2251));
        await tester.pump();
        expect(
          monkeyMuxService.imageReplayCalls.where(
            (call) => call.imageIds.contains(57),
          ),
          hasLength(4),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(
          monkeyMuxService.imageReplayCalls.where(
            (call) => call.imageIds.contains(57),
          ),
          hasLength(4),
          reason: 'transient image retries stop after the bounded budget',
        );

        muxFixture.windowEvents.add(const TmuxWindowListEvent(initialWindows));
        await tester.pump();
        final staleResult = Completer<MonkeyMuxImageReplayResult>();
        monkeyMuxService.imageReplayFutures
          ..add(staleResult.future)
          ..add(
            Future.value(
              MonkeyMuxImageReplayResult(
                served: const <int>{},
                retryableFailure: false,
              ),
            ),
          );
        session.terminal!.write(
          '\x1b[2J\x1b[H\x1b[38;5;58m$placeholder\x1b[39m',
        );
        expect(session.terminal!.unresolvedPlaceholderImageIds(), contains(58));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(monkeyMuxService.imageReplayCalls.last.imageIds, <int>{58});

        muxFixture.windowEvents.add(
          const TmuxWindowListEvent(activeAgentWindows),
        );
        await tester.pump();
        session.terminal!.write(
          '\x1b[2J\x1b[H\x1b[38;5;59m$placeholder\x1b[39m',
        );
        staleResult.complete(
          MonkeyMuxImageReplayResult(
            served: const <int>{},
            retryableFailure: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 351));
        await tester.pump();
        expect(
          monkeyMuxService.imageReplayCalls.last.imageIds,
          <int>{59},
          reason: 'a stale window result cannot mutate the new visit',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'disconnects when MonkeyMux reports no remaining windows',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        final activeSessions = _TestActiveSessionsNotifier(session);
        addTearDown(windowEvents.close);
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.clearCache(session.connectionId),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.clearCache(session.connectionId),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => initialWindows);
        when(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => monkeyMuxService.currentPaneContext(
            session,
            sessionName,
            priority: any(named: 'priority'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => monkeyMuxService.refreshTerminalTheme(
            session,
            sessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
            forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
          ),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            activeSessions: activeSessions,
            overrides: [
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
            child: MaterialApp(
              initialRoute: '/terminal',
              routes: {
                '/': (_) => const SizedBox.shrink(),
                '/terminal': (_) => TerminalScreen(
                  hostId: host.id,
                  connectionId: session.connectionId,
                ),
              },
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('monkeymux-handle-icon')),
          findsOneWidget,
        );
        verify(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);

        windowEvents.add(const TmuxWindowListEvent(<TmuxWindow>[]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(activeSessions.disconnectedConnectionIds, [
          session.connectionId,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'disconnects when a reindexed final MonkeyMux close shuts control',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        final activeSessions = _TestActiveSessionsNotifier(session);
        addTearDown(windowEvents.close);
        const sessionName = 'work';
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true, id: '@0'),
          TmuxWindow(index: 1, name: 'logs', isActive: false, id: '@1'),
        ];
        var currentWindows = initialWindows;
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.clearCache(session.connectionId),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.clearCache(session.connectionId),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => currentWindows);
        when(
          () => monkeyMuxService.watchWindowChanges(
            session,
            sessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => monkeyMuxService.killWindow(
            session,
            sessionName,
            1,
            windowId: '@1',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenThrow(
          const MonkeyMuxInstallException('MonkeyMux control channel closed.'),
        );

        await tester.pumpWidget(
          buildScreen(
            activeSessions: activeSessions,
            overrides: [
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
            child: MaterialApp(
              initialRoute: '/terminal',
              routes: {
                '/': (_) => const SizedBox.shrink(),
                '/terminal': (_) => TerminalScreen(
                  hostId: host.id,
                  connectionId: session.connectionId,
                ),
              },
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final closeWindowButton = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Close window',
        );
        expect(closeWindowButton, findsNWidgets(2));
        await tester.tap(closeWindowButton.last);
        await tester.pumpAndSettle();
        expect(find.text('Close window?'), findsOneWidget);
        currentWindows = const [
          TmuxWindow(index: 0, name: 'logs', isActive: true, id: '@1'),
        ];
        windowEvents.add(TmuxWindowListEvent(currentWindows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(activeSessions.disconnectedConnectionIds, [
          session.connectionId,
        ]);
        expect(
          find.text('tmux action failed. Check the session and try again.'),
          findsNothing,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'does not leak outer tmux focus to a bare shell after detach',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // A detached shell must not receive synthetic TUI focus or theme reports.
        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\x1b[O')));
        expect(writtenShellText, isNot(contains('\x1b[I')));
        expect(writtenShellText, isNot(contains('\x1b[?997;1n')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'preserves outer focus after coalesced tmux window refreshes',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        final refreshCompleters = <Completer<void>>[];
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: false),
        ];

        addTearDown(windowEvents.close);
        // Real tmux clients enable focus tracking + alt buffer on attach;
        // the outer focus gate skips focus sends to a bare shell, so simulate
        // those signals on the session terminal before the screen pumps.
        session.terminal!.write('\x1b[?1004h');
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) {
          final completer = Completer<void>();
          refreshCompleters.add(completer);
          return completer.future;
        });

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        shellWrites.clear();

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: true),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(refreshCompleters, hasLength(1));

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();

        refreshCompleters.first.complete();
        await tester.pump();
        await tester.pump();
        expect(refreshCompleters, hasLength(2));

        refreshCompleters[1].complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O'));
        expect(writtenShellText, contains('\x1b[I'));
        expect(writtenShellText, isNot(contains('\x1b[?997;')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'does not send stale outer focus after superseded tmux theme refresh',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final refreshCompleters = <Completer<void>>[];
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: false),
        ];

        // Real tmux clients enable focus tracking + alt buffer on attach;
        // the outer focus gate skips focus sends to a bare shell, so simulate
        // those signals on the session terminal before the screen pumps.
        session.terminal!.write('\x1b[?1004h');
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) {
          final completer = Completer<void>();
          refreshCompleters.add(completer);
          return completer.future;
        });

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        shellWrites.clear();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(TerminalScreen)),
        );
        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();

        expect(refreshCompleters, hasLength(1));

        await container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(ThemeMode.light);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await tester.pump();

        refreshCompleters.first.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(refreshCompleters, hasLength(2));
        expect(
          utf8.decode(
            shellWrites.expand((chunk) => chunk).toList(growable: false),
          ),
          isEmpty,
        );

        refreshCompleters[1].complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(
          utf8.decode(
            shellWrites.expand((chunk) => chunk).toList(growable: false),
          ),
          contains('\x1b[O'),
        );
        expect(
          utf8.decode(
            shellWrites.expand((chunk) => chunk).toList(growable: false),
          ),
          contains('\x1b[I'),
        );
        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\x1b[?997;')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'mobile terminal paints cursor from the terminal input focus node',
      (tester) async {
        await pumpScreen(tester);

        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );

        expect(terminalView.cursorFocusNode, isNotNull);
        expect(terminalView.focusNode, same(terminalView.cursorFocusNode));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('overflow menu toggles shell completion popups', (
      tester,
    ) async {
      await pumpScreen(tester);

      await openTerminalOverflowSubmenu(tester, 'Options');

      final menuItem = terminalCheckboxMenuButton('Shell Completion Popups');
      expect(menuItem, findsOneWidget);
      expect(tester.widget<CheckboxMenuButton>(menuItem).value, isTrue);

      await tester.tap(menuItem);
      await tester.pumpAndSettle();

      expect(
        await SettingsService(
          db,
        ).getBool(SettingKeys.shellCompletions, defaultValue: true),
        isFalse,
      );
    });

    for (final (backend, refreshFails) in [
      (RemoteMuxBackend.tmux, false),
      (RemoteMuxBackend.monkeyMux, false),
      (RemoteMuxBackend.tmux, true),
    ]) {
      testWidgets(
        'shell completion uses the active $backend pane, refresh fails $refreshFails',
        (tester) async {
          const sessionName = 'work';
          final sftp = _MockSftpClient();
          when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
          when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/test');
          when(() => sftp.stat(any())).thenAnswer((_) async => SftpFileAttrs());
          final tmuxService = _MockTmuxService();
          final monkeyMuxService = _MockMonkeyMuxService();
          final completionService = _TestShellCompletionService(
            cachedSuggestions: [
              if (refreshFails)
                const ShellCompletionSuggestion(
                  label: 'checkout',
                  replacement: 'checkout',
                  replacementStart: 4,
                  replacementEnd: 6,
                  kind: ShellCompletionSuggestionKind.history,
                  commitSuffix: ' ',
                ),
            ],
          );
          final windows = [
            TmuxWindow(
              index: 0,
              id: '@8',
              name: 'shell',
              isActive: true,
              currentCommand: 'zsh',
              currentPath: refreshFails ? null : '/old',
            ),
          ];
          host = _buildHost(
            id: host.id,
            tmuxSessionName: sessionName,
            remoteMuxBackend: backend,
          );
          if (refreshFails) {
            session.terminal!
              ..write('\x1b[?1004h')
              ..write('root@host ~ % git c');
          } else {
            session
              ..remoteMuxBackend = backend
              ..remoteMuxSessionName = sessionName;
          }
          final fixture =
              createMuxFixture(tmuxService, monkeyMuxService, sessionName)
                ..stubPrefetch()
                ..stubForegroundClient()
                ..stubWindows(() => windows)
                ..stubWindowEvents()
                ..stubThemeRefresh();
          stubTmuxWindows(
            tmuxService,
            sessionName,
            windows,
            events: refreshFails ? fixture.windowEvents.stream : null,
          );
          when(
            () => tmuxService.hasSessionOrThrow(session, sessionName),
          ).thenAnswer((_) async => true);
          when(
            () => tmuxService.foregroundSessionNameOrThrow(session),
          ).thenAnswer((_) async => sessionName);
          when(
            () => tmuxService.detectInstalledAgentTools(session),
          ).thenAnswer((_) async => const <AgentLaunchTool>{});
          for (final (service, path, shell)
              in <(RemoteMultiplexerService, String, String)>[
                (tmuxService, '/tmux', 'zsh'),
                (monkeyMuxService, '/monkeymux', 'bash'),
              ]) {
            final stub = when(
              () => service.currentPaneContext(
                session,
                sessionName,
                priority: any(named: 'priority'),
                extraFlags: any(named: 'extraFlags'),
              ),
            );
            if (refreshFails) {
              stub.thenThrow(Exception('tmux context unavailable'));
            } else {
              stub.thenAnswer(
                (_) async =>
                    TmuxPaneContext(currentPath: path, currentCommand: shell),
              );
            }
          }
          await pumpScreen(
            tester,
            tmuxService: tmuxService,
            monkeyMuxService: monkeyMuxService,
            shellCompletionService: completionService,
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (!refreshFails) session.terminal!.write('root@host ~ % git c');
          session.terminal!.textInput('h');
          await tester.pump();
          if (refreshFails) {
            await tester.pump();
            expect(completionService.cachedInvocations, isNotEmpty);
            expect(
              completionService.cachedInvocations.map((call) => call.token),
              contains('ch'),
            );
            expect(find.text('checkout'), findsOneWidget);
          }
          await tester.pump(const Duration(milliseconds: 250));
          await tester.pump();
          if (refreshFails) {
            expect(find.text('checkout'), findsOneWidget);
            expect(completionService.completeInvocations, isEmpty);
          } else {
            expect(completionService.completeInvocations, isNotEmpty);
            expect(
              completionService.completeInvocations.map(
                (call) => (call.workingDirectory, call.shellCommand),
              ),
              everyElement(
                backend == RemoteMuxBackend.tmux
                    ? ('/tmux', 'zsh')
                    : ('/monkeymux', 'bash'),
              ),
            );
          }
          final inactive = <RemoteMultiplexerService>[
            tmuxService,
            monkeyMuxService,
          ][backend == RemoteMuxBackend.monkeyMux ? 0 : 1];
          verifyNever(
            () => inactive.currentPaneContext(
              any(),
              any(),
              priority: any(named: 'priority'),
              extraFlags: any(named: 'extraFlags'),
            ),
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    testWidgets(
      'keeps suggestions visible while refreshing the latest typed prefix',
      (tester) async {
        final completionService = _TestShellCompletionService(
          cachedSuggestions: const <ShellCompletionSuggestion>[
            ShellCompletionSuggestion(
              label: 'checkout',
              replacement: 'checkout',
              replacementStart: 4,
              replacementEnd: 6,
              kind: ShellCompletionSuggestionKind.history,
              commitSuffix: ' ',
            ),
          ],
          completionSuggestions:
              const <String, List<ShellCompletionSuggestion>>{
                'che': <ShellCompletionSuggestion>[
                  ShellCompletionSuggestion(
                    label: 'cherry-pick',
                    replacement: 'cherry-pick',
                    replacementStart: 4,
                    replacementEnd: 7,
                    kind: ShellCompletionSuggestionKind.history,
                    commitSuffix: ' ',
                  ),
                ],
              },
        );

        session.terminal!.write('root@host ~ % git c');
        await pumpScreen(tester, shellCompletionService: completionService);

        session.terminal!.textInput('h');
        await tester.pump();
        await tester.pump();

        expect(find.text('checkout'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        expect(
          completionService.completeInvocations.map(
            (invocation) => invocation.token,
          ),
          ['ch'],
        );
        expect(find.text('checkout'), findsOneWidget);

        session.terminal!.textInput('e');
        await tester.pump();

        // Keep the still-valid cached row visible while the latest prefix is
        // debounced and resolved instead of flashing the popup away.
        expect(find.text('checkout'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        expect(
          completionService.completeInvocations.map(
            (invocation) => invocation.token,
          ),
          ['ch', 'che'],
        );
        expect(find.text('checkout'), findsNothing);
        expect(find.text('cherry-pick'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'dismisses shell completion popup when Return/Enter is pressed',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            id: '@8',
            name: 'shell',
            isActive: true,
            currentCommand: 'zsh',
          ),
        ];
        final completionService = _TestShellCompletionService(
          cachedSuggestions: const <ShellCompletionSuggestion>[
            ShellCompletionSuggestion(
              label: 'checkout',
              replacement: 'checkout',
              replacementStart: 4,
              replacementEnd: 6,
              kind: ShellCompletionSuggestionKind.history,
              commitSuffix: ' ',
            ),
          ],
        );

        addTearDown(windowEvents.close);
        session.terminal!
          ..write('\x1b[?1004h')
          ..write('root@host ~ % git c');
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        when(
          () => tmuxService.hasSessionOrThrow(session, tmuxSessionName),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.currentPaneContext(
            session,
            tmuxSessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenThrow(Exception('tmux context unavailable'));

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          shellCompletionService: completionService,
        );
        await tester.pump(const Duration(milliseconds: 100));

        session.terminal!.textInput('h');
        await tester.pump();
        await tester.pump();

        expect(find.text('checkout'), findsOneWidget);

        // Hitting Return/Enter should dismiss the completion popup immediately
        session.terminal!.keyInput(TerminalKey.enter);
        await tester.pump();

        expect(find.text('checkout'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'tmux alert notifications clear only emitted stable IDs on activation',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final notificationService = _RecordingLocalNotificationService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        const tmuxSessionName = 'work';
        const windowIndex = 1;
        const windowId = '@9';
        const indexOnlyWindowIndex = 2;
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(
            index: windowIndex,
            id: windowId,
            name: 'agent',
            isActive: false,
          ),
          TmuxWindow(
            index: indexOnlyWindowIndex,
            name: 'logs',
            isActive: false,
          ),
        ];
        int notificationId(Object window) =>
            Object.hash(
              session.hostId,
              session.connectionId,
              tmuxSessionName,
              window,
            ) &
            0x7fffffff;
        final stableNotificationId = notificationId(windowId);
        final indexOnlyNotificationId = notificationId(indexOnlyWindowIndex);
        addTearDown(windowEvents.close);
        session.terminal!.write('\x1b[?1004h');
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        stubTmuxWindows(
          tmuxService,
          tmuxSessionName,
          initialWindows,
          events: windowEvents.stream,
        );
        when(
          () => tmuxService.hasSessionOrThrow(session, tmuxSessionName),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        await tester.pumpWidget(
          buildScreen(
            overrides: [
              tmuxServiceProvider.overrideWithValue(tmuxService),
              localNotificationServiceProvider.overrideWithValue(
                notificationService,
              ),
            ],
            initialTmuxSessionName: tmuxSessionName,
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(notificationService.shownNotificationIds, isEmpty);
        expect(notificationService.clearedNotificationIds, isEmpty);
        final shownIds = <int>[];
        for (final window in initialWindows.skip(1)) {
          windowEvents.add(
            TmuxWindowSnapshotEvent(window.copyWith(flags: '!')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          shownIds.add(
            window.id == null ? indexOnlyNotificationId : stableNotificationId,
          );
          expect(notificationService.shownNotificationIds, shownIds);
          expect(notificationService.clearedNotificationIds, isEmpty);
        }
        windowEvents.add(
          TmuxWindowSnapshotEvent(
            initialWindows[1].copyWith(isActive: true, flags: '!'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(notificationService.clearedNotificationIds, [
          stableNotificationId,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'refreshes tmux theme after window state changes',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: false),
        ];
        var refreshCount = 0;

        addTearDown(windowEvents.close);
        // Real tmux clients enable focus tracking + alt buffer on attach;
        // the outer focus gate skips focus sends to a bare shell, so simulate
        // those signals on the session terminal before the screen pumps.
        session.terminal!.write('\x1b[?1004h');
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {
          refreshCount += 1;
        });
        when(
          () => tmuxService.currentPaneContext(
            session,
            tmuxSessionName,
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => null);

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final refreshCountBeforeWindowEvent = refreshCount;
        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 0,
              id: '@8',
              name: 'shell',
              isActive: true,
              paneTitle: 'codex-notes',
              lastActivityEpochSeconds: 123,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();

        expect(refreshCount, refreshCountBeforeWindowEvent);

        shellWrites.clear();
        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 0,
              id: '@8',
              name: 'shell',
              isActive: true,
              paneTitle: 'Copilot',
              lastActivityEpochSeconds: 123,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1050));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(refreshCount, greaterThan(refreshCountBeforeWindowEvent));
        final refreshCountAfterTitleAgent = refreshCount;

        shellWrites.clear();
        tester.testTextInput.updateEditingValue(
          _editingValue('background', selectionOffset: 10),
        );
        await tester.pump();
        tester.testTextInput.log.clear();

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 1,
              id: '@9',
              name: 'agent-renamed',
              isActive: false,
              currentCommand: 'vim',
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1050));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(refreshCount, greaterThan(refreshCountAfterTitleAgent));
        final backgroundClient =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          backgroundClient.currentTextEditingValue,
          _editingValue('background', selectionOffset: 10),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );
        final refreshCountAfterBackgroundWindow = refreshCount;

        shellWrites.clear();
        tester.testTextInput.updateEditingValue(
          _editingValue('stale', selectionOffset: 5),
        );
        await tester.pump();
        shellWrites.clear();
        tester.testTextInput.log.clear();

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: true),
          ),
        );
        await tester.pump();
        // The tmux theme refresh is debounced by ~150ms plus the remaining
        // post-window-switch quiet period (up to 900ms). That quiet period is
        // measured against the real wall clock (DateTime.now), which does not
        // advance with tester.pump, so the effective fake-async timer lands a
        // few milliseconds short of 1050ms under load. Assert "not fired yet"
        // from well inside the window instead of 1ms before its exact edge, so
        // slow CI can't tip a knife-edge boundary.
        await tester.pump(const Duration(milliseconds: 500));

        expect(refreshCount, refreshCountAfterBackgroundWindow);

        // Pump comfortably past the full debounce window so the refresh fires.
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(refreshCount, greaterThan(refreshCountAfterBackgroundWindow));
        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1b[O'));
        expect(writtenShellText, contains('\x1b[I'));
        expect(writtenShellText, isNot(contains('\x1b[?997;')));
        expect(writtenShellText, isNot(contains('\x1b]10;')));
        expect(writtenShellText, isNot(contains('\x1b]11;')));
        expect(writtenShellText, isNot(contains('\x1b]4;')));
        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isNotEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'does not refresh tmux theme for inactive window activity snapshots',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(index: 1, id: '@9', name: 'agent', isActive: false),
        ];
        var refreshCount = 0;

        addTearDown(windowEvents.close);
        // Real tmux clients enable focus tracking + alt buffer on attach;
        // the outer focus gate skips focus sends to a bare shell, so simulate
        // those signals on the session terminal before the screen pumps.
        session.terminal!.write('\x1b[?1004h');
        host = _buildHost(id: host.id, tmuxSessionName: tmuxSessionName);
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {
          refreshCount += 1;
        });

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final refreshCountBeforeWindowEvent = refreshCount;
        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 1,
              id: '@9',
              name: 'agent',
              isActive: false,
              lastActivityEpochSeconds: 123,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(refreshCount, refreshCountBeforeWindowEvent);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'keeps a primed tmux bar visible after transient detection failure',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          TmuxWindow(index: 1, name: 'agent', isActive: false),
        ];
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        var foregroundSessionCalls = 0;
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async {
          foregroundSessionCalls += 1;
          if (foregroundSessionCalls == 1) {
            throw StateError('exec channel temporarily unavailable');
          }
          return tmuxSessionName;
        });
        stubTmuxWindows(tmuxService, tmuxSessionName, windows);

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        expect(find.textContaining(tmuxSessionName), findsOneWidget);
        expect(foregroundSessionCalls, greaterThanOrEqualTo(2));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'does not show a configured tmux bar before foreground confirmation',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          TmuxWindow(index: 1, name: 'agent', isActive: false),
        ];
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        var foregroundSessionCalls = 0;
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async {
          foregroundSessionCalls += 1;
          if (foregroundSessionCalls == 1) {
            throw StateError('exec channel temporarily unavailable');
          }
          return null;
        });
        stubTmuxWindows(tmuxService, tmuxSessionName, windows);

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
          ),
        );

        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsNothing);

        await tester.pump(const Duration(seconds: 12));

        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsNothing);
        expect(foregroundSessionCalls, greaterThanOrEqualTo(2));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'clears an active tmux bar after the foreground terminal detaches',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'work';
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          TmuxWindow(index: 1, name: 'agent', isActive: false),
        ];
        host = _buildHost(id: host.id, tmuxSessionName: tmuxSessionName);
        var foregroundSessionCalls = 0;
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async {
          foregroundSessionCalls += 1;
          return foregroundSessionCalls == 1 ? tmuxSessionName : null;
        });
        stubTmuxWindows(tmuxService, tmuxSessionName, windows);

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);

        await tester.pump(const Duration(seconds: 5));
        await tester.pump();

        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsNothing);
        expect(foregroundSessionCalls, 2);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'initial tmux target selects stable window ID and can start expanded',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'alerts';
        const staleTargetWindowIndex = 2;
        const targetWindowIndex = 3;
        const targetWindowId = '@9';
        final windows = <TmuxWindow>[
          const TmuxWindow(index: 1, id: '@8', name: 'shell', isActive: true),
          const TmuxWindow(
            index: targetWindowIndex,
            id: targetWindowId,
            name: 'agent',
            isActive: false,
          ),
        ];
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
            windowId: targetWindowId,
            clientImageSignatures: any(named: 'clientImageSignatures'),
          ),
        ).thenAnswer((_) async {});
        when(
          () =>
              tmuxService.hasForegroundClientOrThrow(session, tmuxSessionName),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
                initialTmuxWindowIndex: staleTargetWindowIndex,
                initialTmuxWindowId: targetWindowId,
                initiallyExpandTmuxWindows: true,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        verify(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
            windowId: targetWindowId,
            clientImageSignatures: any(named: 'clientImageSignatures'),
          ),
        ).called(1);
        expect(find.text('shell'), findsOneWidget);
        expect(find.text('agent'), findsOneWidget);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'does not type a tmux reattach command when foreground check fails',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'work';
        const targetWindowIndex = 1;
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          TmuxWindow(index: 1, name: 'agent', isActive: false),
        ];
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => tmuxSessionName);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
            clientImageSignatures: any(named: 'clientImageSignatures'),
          ),
        ).thenAnswer((_) async {});
        when(
          () =>
              tmuxService.hasForegroundClientOrThrow(session, tmuxSessionName),
        ).thenThrow(
          const TmuxCommandException(
            'SSH exec channel closed before tmux command completed',
          ),
        );
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.refreshTerminalTheme(
            session,
            tmuxSessionName,
            any(),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
                initialTmuxWindowIndex: targetWindowIndex,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        verify(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
            clientImageSignatures: any(named: 'clientImageSignatures'),
          ),
        ).called(1);
        verify(
          () =>
              tmuxService.hasForegroundClientOrThrow(session, tmuxSessionName),
        ).called(1);
        final writtenText = shellWrites.map(utf8.decode).join();
        expect(writtenText, isNot(contains('tmux ')));
        expect(writtenText, isNot(contains('new-session')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    for (final completion in [
      'mounted',
      'close',
      'open',
      'close error',
      'open error',
    ]) {
      testWidgets(
        'notification tmux target reopens a busy shell: $completion',
        (tester) async {
          final delayedCompletion = Completer<void>();
          _LifecycleSshSession? trackedSession;
          if (completion != 'mounted') {
            trackedSession = _LifecycleSshSession(session)
              ..forcedShellStatus = TerminalShellStatus.runningCommand;
            if (completion.startsWith('close')) {
              trackedSession.pendingClose = delayedCompletion.future;
            } else {
              trackedSession
                ..delayedOpenNumber = 2
                ..pendingOpen = delayedCompletion.future;
            }
            session = trackedSession..getOrCreateTerminal();
          }
          final tmuxService = _MockTmuxService();
          const tmuxSessionName = 'alerts';
          const tmuxExtraFlags = '-S /tmp/alerts.sock';
          const targetWindowIndex = 3;
          const targetWindowId = '@9';
          final windows = <TmuxWindow>[
            const TmuxWindow(index: 1, id: '@8', name: 'shell', isActive: true),
            const TmuxWindow(
              index: targetWindowIndex,
              id: targetWindowId,
              name: 'agent',
              isActive: false,
            ),
          ];
          final secondShellOpen = Completer<void>();
          var shellOpenCount = 0;
          _stubTrueColorLoginShell(
            sshClient,
            shellChannel,
            onOpen: () {
              shellOpenCount += 1;
              if (shellOpenCount == 2 && !secondShellOpen.isCompleted) {
                secondShellOpen.complete();
              }
            },
          );
          host = _buildHost(
            id: host.id,
            tmuxSessionName: tmuxSessionName,
            tmuxExtraFlags: tmuxExtraFlags,
          );
          stubTmuxWindows(
            tmuxService,
            tmuxSessionName,
            windows,
            extraFlags: tmuxExtraFlags,
          );
          Future<String?> foregroundSession() =>
              tmuxService.foregroundSessionNameOrThrow(
                session,
                extraFlags: tmuxExtraFlags,
              );
          when(foregroundSession).thenAnswer((_) async => tmuxSessionName);
          when(
            () => tmuxService.hasSessionOrThrow(
              session,
              tmuxSessionName,
              extraFlags: tmuxExtraFlags,
            ),
          ).thenAnswer((_) async => true);
          Future<void> selectTarget() => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
            windowId: targetWindowId,
            extraFlags: tmuxExtraFlags,
            clientImageSignatures: any(named: 'clientImageSignatures'),
          );
          when(selectTarget).thenAnswer((_) async {});
          Future<bool> hasForeground() =>
              tmuxService.hasForegroundClientOrThrow(
                session,
                tmuxSessionName,
                extraFlags: tmuxExtraFlags,
              );
          when(hasForeground).thenAnswer((_) async => false);
          session.terminal!.write('\u001b]133;C\u0007');
          expect(session.shellStatus, TerminalShellStatus.runningCommand);
          await tester.pumpWidget(
            buildScreen(
              overrides: [tmuxServiceProvider.overrideWithValue(tmuxService)],
              initialTmuxSessionName: tmuxSessionName,
              initialTmuxWindowIndex: targetWindowIndex,
              initialTmuxWindowId: targetWindowId,
              initialTmuxWindowRequiresVisibleSession: true,
            ),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          verify(selectTarget).called(1);
          verify(hasForeground).called(1);
          verify(foregroundSession).called(1);
          if (trackedSession != null) {
            // A layout resize during an intentional reopen must not treat the
            // temporary absence of a shell as a lost SSH connection.
            clearInteractions(shellChannel);
            session.terminal!.onResize!(101, 31, 808, 496);
            await tester.pump();
            verifyNever(
              () => shellChannel.resizeTerminal(any(), any(), any(), any()),
            );
            verifyNever(() => tmuxService.clearCache(session.connectionId));
            expect(trackedSession.closeCalls, 1);
            expect(
              trackedSession.openCalls,
              completion.startsWith('close') ? 1 : 2,
            );
            await trackedSession.completeAfterDisposal(tester, () {
              if (completion.endsWith('error')) {
                delayedCompletion.completeError(StateError('shell failed'));
              } else {
                delayedCompletion.complete();
              }
            });
            expect(
              trackedSession.openCalls,
              completion.startsWith('close') ? 1 : 2,
            );
            return;
          }
          await tester.runAsync(() async {
            await secondShellOpen.future.timeout(const Duration(seconds: 2));
          });
          await tester.pump();
          clearInteractions(shellChannel);
          session.terminal!.onResize!(101, 31, 808, 496);
          verify(
            () => shellChannel.resizeTerminal(101, 31, 808, 496),
          ).called(1);
          verifyNever(() => tmuxService.clearCache(session.connectionId));
          verify(
            () => tmuxService.listWindows(
              session,
              tmuxSessionName,
              extraFlags: tmuxExtraFlags,
            ),
          ).called(greaterThanOrEqualTo(1));
          expect(find.textContaining('tmux action failed'), findsNothing);
          expect(
            find.text(
              'Opening tmux alert interrupted the running shell command.',
            ),
            findsOneWidget,
          );
          expect(
            shellWrites.map(utf8.decode).join(),
            contains(tmuxSessionName),
          );
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }

    testWidgets(
      'new windows use the configured host directory without reading the active pane',
      (tester) async {
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          tmuxWorkingDirectory: '/home/demo/configured',
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('New window'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empty terminal'));
        await tester.pump();

        verify(
          () => tmuxService.createWindow(
            session,
            'work',
            workingDirectory: '/home/demo/configured',
          ),
        ).called(1);
        verifyNever(
          () => tmuxService.currentPanePath(
            session,
            'work',
            priority: any(named: 'priority'),
            extraFlags: any(named: 'extraFlags'),
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'new window completion after disposal does not read providers',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final createWindowCompleter = Completer<void>();
        await pumpTmuxScreen(tester, tmuxService);
        when(
          () => tmuxService.createWindow(
            session,
            'work',
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: any(named: 'workingDirectory'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => createWindowCompleter.future);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('New window'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empty terminal'));
        await tester.pump();

        verify(
          () => tmuxService.createWindow(
            session,
            'work',
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: any(named: 'workingDirectory'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);

        await tester.pumpWidget(const SizedBox.shrink());
        createWindowCompleter.complete();
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'shows per-window MonkeyMux progress in expanded and collapsed bars',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const windows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            id: '@1',
            name: 'build',
            isActive: true,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.error,
              percentage: 45,
            ),
          ),
          TmuxWindow(
            index: 1,
            id: '@2',
            name: 'tests',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.indeterminate,
            ),
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
        );
        session.terminal!.write('\x1b]9;4;2;45\x07');
        await tester.pump(const Duration(milliseconds: 100));

        final activeCollapsed = find.byKey(
          const ValueKey('monkeymux-sidebar-progress-0'),
        );
        final inactiveCollapsed = find.byKey(
          const ValueKey('monkeymux-sidebar-progress-1'),
        );
        expect(activeCollapsed, findsOneWidget);
        expect(inactiveCollapsed, findsOneWidget);
        final collapsedButtons = <Finder>[
          find.byKey(const ValueKey('tmux-sidebar-window-0')),
          find.byKey(const ValueKey('tmux-sidebar-window-1')),
        ];
        final collapsedIndicators = <Finder>[
          activeCollapsed,
          inactiveCollapsed,
        ];
        for (var index = 0; index < collapsedIndicators.length; index++) {
          final buttonRect = tester.getRect(collapsedButtons[index]);
          final indicatorRect = tester.getRect(collapsedIndicators[index]);
          expect(indicatorRect.left, greaterThanOrEqualTo(buttonRect.left));
          expect(indicatorRect.right, lessThanOrEqualTo(buttonRect.right));
          expect(indicatorRect.top, greaterThanOrEqualTo(buttonRect.top));
          expect(indicatorRect.bottom, lessThanOrEqualTo(buttonRect.bottom));
          final indexRect = tester.getRect(
            find.byKey(ValueKey('tmux-sidebar-window-index-$index')),
          );
          expect(indicatorRect.overlaps(indexRect), isFalse);
          for (var other = 0; other < collapsedButtons.length; other++) {
            if (other != index) {
              expect(
                indicatorRect.overlaps(tester.getRect(collapsedButtons[other])),
                isFalse,
              );
            }
          }
        }
        expect(
          find.bySemanticsLabel('Terminal task progress, error'),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(inactiveCollapsed).label,
          contains('MonkeyMux window 1: tests, progress, indeterminate'),
        );
        expect(
          tester.getSemantics(activeCollapsed).role,
          isNot(SemanticsRole.progressBar),
        );
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: activeCollapsed,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .color,
          Theme.of(tester.element(activeCollapsed)).colorScheme.error,
        );
        expect(
          tester.getSemantics(inactiveCollapsed).role,
          SemanticsRole.loadingSpinner,
        );

        await tester.drag(
          find.byKey(const ValueKey('tmux-sidebar-window-0')),
          const Offset(80, 0),
          kind: PointerDeviceKind.mouse,
          touchSlopX: 0,
        );
        await tester.pump();

        final activeExpanded = find.byKey(
          const ValueKey('monkeymux-window-progress-0'),
        );
        final inactiveExpanded = find.byKey(
          const ValueKey('monkeymux-window-progress-1'),
        );
        expect(activeExpanded, findsOneWidget);
        expect(inactiveExpanded, findsOneWidget);
        expect(
          find.bySemanticsLabel('Terminal task progress, error'),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(inactiveExpanded).label,
          contains('MonkeyMux window 1: tests, progress, indeterminate'),
        );
        expect(
          tester.getSemantics(activeExpanded).role,
          isNot(SemanticsRole.progressBar),
        );
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: activeExpanded,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          0.45,
        );
        expect(
          tester.getSemantics(inactiveExpanded).label,
          contains('MonkeyMux window 1: tests, progress, indeterminate'),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'shows live native-session progress in its real MonkeyMux pane',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const bridgeId = '0123456789abcdef0123456789abcdef';
        final key = fakeAcpKey(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.pi,
          bridgeId: bridgeId,
          acpSessionId: 'native-session',
        );
        final workingSession = fakeAcpSession(
          key: key,
          providerLabel: 'Pi',
          title: 'Live native task',
          promptStatus: AcpPromptStatus.streaming,
          plan: const [
            AcpPlanEntry(
              content: 'done',
              priority: AcpPlanPriority.high,
              status: AcpPlanStatus.completed,
            ),
            AcpPlanEntry(
              content: 'next',
              priority: AcpPlanPriority.medium,
              status: AcpPlanStatus.inProgress,
            ),
          ],
        );
        final acpManager = FakeAcpSessionManager(sessions: [workingSession]);
        final closeWindowCompleter = Completer<void>();
        addTearDown(acpManager.dispose);
        const windows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            id: '@1',
            name: 'shell',
            isActive: true,
            currentCommand: 'zsh',
          ),
          TmuxWindow(
            index: 1,
            id: '@2',
            name: 'Terminal Pi',
            isActive: false,
            currentCommand: 'pi',
            agentTool: AgentLaunchTool.pi,
          ),
          TmuxWindow(
            index: 2,
            id: '@3',
            name: 'Pi',
            isActive: false,
            currentPath: '/home/dev/project',
            nativeAcpBridgeId: bridgeId,
            nativeAcpProviderId: AcpBuiltinProviderIds.pi,
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => monkeyMuxService.selectWindow(
            session,
            'work',
            2,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.killWindow(
            session,
            'work',
            2,
            windowId: '@3',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) => closeWindowCompleter.future);
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
          acpSessionManager: acpManager,
        );
        await tester.pump();

        const collapsedKey = ValueKey('monkeymux-sidebar-progress-2');
        final collapsed = find.byKey(collapsedKey);
        expect(collapsed, findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: collapsed,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          0.5,
        );
        expect(find.byTooltip('Switch to Live native task'), findsOneWidget);
        const collapsedBadgeKey = ValueKey('monkeymux-sidebar-native-2');
        expect(find.byKey(collapsedBadgeKey), findsOneWidget);
        final collapsedBadgeSize = tester.getSize(
          find.byKey(collapsedBadgeKey),
        );

        await tester.drag(
          find.byKey(const ValueKey('tmux-sidebar-window-2')),
          const Offset(80, 0),
          kind: PointerDeviceKind.mouse,
          touchSlopX: 0,
        );
        await tester.pump();

        const expandedKey = ValueKey('monkeymux-window-progress-2');
        final expanded = find.byKey(expandedKey);
        expect(expanded, findsOneWidget);
        expect(find.text('Live native task'), findsOneWidget);
        const expandedBadgeKey = ValueKey('monkeymux-native-badge-2');
        expect(find.byKey(expandedBadgeKey), findsOneWidget);
        expect(
          collapsedBadgeSize,
          tester.getSize(find.byKey(expandedBadgeKey)),
        );
        final expandedIcon = find.ancestor(
          of: find.byKey(expandedBadgeKey),
          matching: find.byType(AcpNativeBadgeOverlay),
        );
        expect(expandedIcon, findsOneWidget);
        expect(
          tester
              .getRect(expandedIcon)
              .overlaps(tester.getRect(find.byKey(expandedBadgeKey))),
          isTrue,
          reason: 'the native badge overlays the agent icon',
        );
        final nativeRow = find.byKey(const ValueKey('monkeymux-window-2'));
        expect(
          find.descendant(of: nativeRow, matching: find.text('running')),
          findsOneWidget,
        );
        final nativeAgentIcon = tester.widget<AgentToolIcon>(
          find.byKey(const ValueKey('monkeymux-window-agent-icon-2')),
        );
        final terminalAgentIcon = tester.widget<AgentToolIcon>(
          find.byKey(const ValueKey('monkeymux-window-agent-icon-1')),
        );
        final scheme = Theme.of(tester.element(nativeRow)).colorScheme;
        expect(nativeAgentIcon.color, scheme.onSurfaceVariant);
        expect(terminalAgentIcon.color, nativeAgentIcon.color);
        expect(
          tester.widget<AcpNativeBadge>(find.byKey(expandedBadgeKey)).color,
          nativeAgentIcon.color,
        );
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: expanded,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          0.5,
        );

        acpManager.emit(
          AcpSessionManagerState(
            sessions: [
              fakeAcpSession(
                key: key,
                providerLabel: 'Pi',
                title: 'Renamed native task',
                promptStatus: AcpPromptStatus.streaming,
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Live native task'), findsNothing);
        expect(find.text('Renamed native task'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: expanded,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          isNull,
        );

        acpManager.emit(
          AcpSessionManagerState(
            sessions: [fakeAcpSession(key: key, providerLabel: 'Pi')],
          ),
        );
        await tester.pump();
        expect(find.byKey(expandedKey), findsNothing);

        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('monkeymux-window-2')),
            matching: find.byTooltip('Close window'),
          ),
        );
        await tester.pumpAndSettle();
        if (find.text('Close window?').evaluate().isNotEmpty) {
          await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
          await tester.pump();
        }
        await tester.pump();
        expect(find.text('Renamed native task'), findsNothing);

        acpManager.emit(
          AcpSessionManagerState(
            sessions: [
              fakeAcpSession(
                key: key,
                providerLabel: 'Pi',
                title: 'Closing native task',
                status: AcpConnectionStatus.reconnecting,
              ),
            ],
          ),
        );
        await tester.pump();
        expect(find.text('Closing native task'), findsNothing);
        expect(find.textContaining('reconnecting'), findsNothing);
        expect(find.byKey(ValueKey(('native-session', key))), findsNothing);
        expect(
          acpManager.releasedMuxBridges,
          isEmpty,
          reason: 'local ownership stays until remote close succeeds',
        );

        closeWindowCompleter.complete();
        await tester.pump();
        await tester.pump();
        expect(acpManager.releasedMuxBridges, [
          (hostId: host.id, bridgeId: bridgeId),
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'recreates an expired native bridge from recents and removes its stale mux window',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        addTearDown(windowEvents.close);
        const staleBridgeId = '0123456789abcdef0123456789abcdef';
        const replacementBridgeId = 'abcdef0123456789abcdef0123456789';
        final staleKey = fakeAcpKey(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.claudeAgent,
          bridgeId: staleBridgeId,
          acpSessionId: 'claude-session',
        );
        final replacementKey = fakeAcpKey(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.claudeAgent,
          bridgeId: replacementBridgeId,
          acpSessionId: staleKey.acpSessionId,
        );
        final acpManager =
            FakeAcpSessionManager(
                recents: [
                  AcpRecentSessionRef(
                    hostId: staleKey.hostId,
                    providerId: staleKey.providerId,
                    bridgeId: staleKey.bridgeId,
                    acpSessionId: staleKey.acpSessionId,
                    cwd: '/home/dev/project',
                    createdAt: DateTime(2025),
                    lastActivityAt: DateTime(2026),
                  ),
                ],
              )
              ..reconnectSessionResult = AcpSessionLaunchStarted(replacementKey)
              ..reconnectSessionState = fakeAcpSession(
                key: replacementKey,
                providerLabel: 'Claude Agent',
              );
        addTearDown(acpManager.dispose);

        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
          TmuxWindow(
            index: 2,
            id: '@3',
            name: 'Claude Agent',
            isActive: false,
            currentPath: '/home/dev/project',
            nativeAcpBridgeId: staleBridgeId,
            nativeAcpProviderId: AcpBuiltinProviderIds.claudeAgent,
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => monkeyMuxService.selectWindow(
            session,
            'work',
            2,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => monkeyMuxService.killWindow(
            session,
            'work',
            2,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        final activeSessions = _TestActiveSessionsNotifier(session);
        await pumpScreen(
          tester,
          activeSessions: activeSessions,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
          acpSessionManager: acpManager,
        );
        await tester.pump(const Duration(milliseconds: 100));
        windowEvents.add(TmuxWindowListEvent([windows.last]));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('tmux-sidebar-window-2')));
        for (
          var attempt = 0;
          attempt < 20 && acpManager.reconnects.isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(acpManager.reconnects, hasLength(1));
        expect(acpManager.reconnects.single.bridgeId, staleBridgeId);
        expect(
          acpManager.reconnects.single.acpSessionId,
          staleKey.acpSessionId,
        );
        expect(acpManager.reconnectKnownBridges.single, isNull);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        verify(
          () => monkeyMuxService.killWindow(
            session,
            'work',
            2,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);
        expect(session.activeNativeAcpSessionKey, replacementKey);
        expect(activeSessions.disconnectedConnectionIds, isEmpty);
        expect(
          find.text('The native agent window is no longer running.'),
          findsNothing,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'retries repeated immediate native transport closes without background preload',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        addTearDown(windowEvents.close);
        const bridgeId = '0123456789abcdef0123456789abcdef';
        const siblingBridgeId = 'abcdef0123456789abcdef0123456789';
        final key = fakeAcpKey(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.codex,
          bridgeId: bridgeId,
          acpSessionId: 'codex-session',
        );
        final blockingKey = fakeAcpKey(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.pi,
          bridgeId: siblingBridgeId,
          acpSessionId: 'pi-session',
        );
        final acpManager = FakeAcpSessionManager(
          sessions: [fakeAcpSession(key: blockingKey, providerLabel: 'Pi')],
        );
        // Keep construction separate so this large fixture stays readable.
        // ignore: cascade_invocations
        acpManager
          ..remoteBridges = [
            MonkeyMuxAcpBridgeMetadata(
              id: bridgeId,
              providerId: AcpBuiltinProviderIds.codex,
              sessionId: key.acpSessionId,
              cwd: '/home/dev/project',
              provider: 'Codex',
              commandHash: 'hash',
              state: MonkeyMuxAcpProviderState.running,
              clientCount: 0,
              pendingRequestCount: 0,
              inFlightTurnCount: 0,
              lastActivity: DateTime(2026),
              startedAt: DateTime(2026),
              nextSequence: 1,
            ),
            MonkeyMuxAcpBridgeMetadata(
              id: siblingBridgeId,
              providerId: AcpBuiltinProviderIds.pi,
              sessionId: 'pi-session',
              cwd: '/home/dev/project',
              provider: 'Pi',
              commandHash: 'hash',
              state: MonkeyMuxAcpProviderState.running,
              clientCount: 0,
              pendingRequestCount: 0,
              inFlightTurnCount: 0,
              lastActivity: DateTime(2026),
              startedAt: DateTime(2026),
              nextSequence: 1,
            ),
          ]
          ..reconnectSessionResults.addAll([
            AcpSessionLaunchBlocked(
              AcpConcurrencyRequiresChoice(
                blockingSessionKeys: [blockingKey.value],
              ),
            ),
            for (var attempt = 0; attempt < 3; attempt++)
              const AcpSessionLaunchFailed(
                null,
                AcpSessionError(
                  kind: AcpSessionErrorKind.transport,
                  message: 'The agent connection closed.',
                  retryable: true,
                ),
              ),
            AcpSessionLaunchStarted(key),
          ])
          ..reconnectSessionState = fakeAcpSession(
            key: key,
            providerLabel: 'Codex',
          );
        addTearDown(acpManager.dispose);
        var windows = const <TmuxWindow>[
          TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
          TmuxWindow(
            index: 2,
            id: '@3',
            name: 'Codex',
            isActive: false,
            currentPath: '/home/dev/project',
            nativeAcpBridgeId: bridgeId,
            nativeAcpProviderId: AcpBuiltinProviderIds.codex,
          ),
          TmuxWindow(
            index: 3,
            id: '@4',
            name: 'Pi',
            isActive: false,
            currentPath: '/home/dev/project',
            nativeAcpBridgeId: siblingBridgeId,
            nativeAcpProviderId: AcpBuiltinProviderIds.pi,
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => monkeyMuxService.selectWindow(
            session,
            'work',
            2,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
            suppressReplay: any(named: 'suppressReplay'),
          ),
        ).thenAnswer((_) async {
          windows = const <TmuxWindow>[
            TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: false),
            TmuxWindow(
              index: 2,
              id: '@3',
              name: 'Codex',
              isActive: true,
              currentPath: '/home/dev/project',
              nativeAcpBridgeId: bridgeId,
              nativeAcpProviderId: AcpBuiltinProviderIds.codex,
            ),
            TmuxWindow(
              index: 3,
              id: '@4',
              name: 'Pi',
              isActive: false,
              currentPath: '/home/dev/project',
              nativeAcpBridgeId: siblingBridgeId,
              nativeAcpProviderId: AcpBuiltinProviderIds.pi,
            ),
          ];
          for (final window in windows) {
            windowEvents.add(TmuxWindowSnapshotEvent(window));
          }
        });
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
          acpSessionManager: acpManager,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          acpManager.reconnects,
          isEmpty,
          reason: 'startup must not speculatively attach native bridges',
        );
        await tester.tap(find.byKey(const ValueKey('tmux-sidebar-window-2')));
        for (
          var attempt = 0;
          attempt < 10 &&
              find.text('Stop and continue free').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Stop and continue free'),
            )
            .onPressed!();
        await tester.pump();
        for (
          var attempt = 0;
          attempt < 40 && acpManager.reconnects.length < 5;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(acpManager.reconnects, hasLength(5));
        expect(acpManager.reconnectSelectOnSuccess, [
          true,
          true,
          true,
          true,
          true,
        ]);
        expect(acpManager.reconnectReplaceKeys, [
          isEmpty,
          [blockingKey],
          isEmpty,
          isEmpty,
          isEmpty,
        ]);
        expect(
          acpManager.reconnectKnownBridges,
          everyElement(same(acpManager.remoteBridges.first)),
        );
        expect(
          acpManager.state.sessions.single.status,
          AcpConnectionStatus.ready,
        );

        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('opening persistent agent session…'), findsNothing);
        expect(acpManager.reconnects, hasLength(5));
        expect(acpManager.reconnectSelectOnSuccess, [
          true,
          true,
          true,
          true,
          true,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'applies and clears active and inactive MonkeyMux progress from window events',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        addTearDown(windowEvents.close);
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
          TmuxWindow(index: 1, id: '@2', name: 'build', isActive: false),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => initialWindows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
        );
        const progressKey = ValueKey('monkeymux-sidebar-progress-1');
        expect(find.byKey(progressKey), findsNothing);

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 1,
              id: '@2',
              name: 'build',
              isActive: false,
              terminalProgress: TerminalProgress(
                state: TerminalProgressState.normal,
                percentage: 20,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.getSemantics(find.byKey(progressKey)).value, '20');

        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 1,
              id: '@2',
              name: 'build',
              isActive: false,
              terminalProgress: TerminalProgress(
                state: TerminalProgressState.error,
                percentage: 80,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.getSemantics(find.byKey(progressKey)).value, '80');
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: find.byKey(progressKey),
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .color,
          Theme.of(tester.element(find.byKey(progressKey))).colorScheme.error,
        );

        windowEvents.add(const TmuxWindowListEvent(initialWindows));
        await tester.pump();
        expect(find.byKey(progressKey), findsNothing);

        const taskProgressKey = ValueKey('terminal-osc-progress');
        windowEvents.add(
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 0,
              id: '@1',
              name: 'Pi',
              isActive: true,
              terminalProgress: TerminalProgress(
                state: TerminalProgressState.indeterminate,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(taskProgressKey), findsOneWidget);
        expect(
          session.terminalProgress?.state,
          TerminalProgressState.indeterminate,
        );

        // A helper restore that restarts Pi omits the previous process's
        // progress. The authoritative idle snapshot must clear the top bar.
        windowEvents.add(const TmuxWindowListEvent(initialWindows));
        await tester.pump(const Duration(milliseconds: 100));
        expect(session.terminalProgress, isNull);
        expect(find.byKey(taskProgressKey), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'keeps inactive mux progress semantics percentage-free with reduced motion',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tmuxService = _MockTmuxService();
        final monkeyMuxService = _MockMonkeyMuxService();
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
          TmuxWindow(
            index: 1,
            id: '@2',
            name: 'build',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.pausedOrWarning,
            ),
          ),
        ];
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        when(
          () => monkeyMuxService.hasForegroundClientOrThrow(session, 'work'),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => monkeyMuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await pumpScreen(
          tester,
          tmuxService: tmuxService,
          monkeyMuxService: monkeyMuxService,
        );
        final progress = find.byKey(
          const ValueKey('monkeymux-sidebar-progress-1'),
        );
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.descendant(
                  of: progress,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .value,
          0.5,
        );
        final semantics = tester.getSemantics(progress);
        expect(
          semantics.label,
          contains('MonkeyMux window 1: build, progress, paused or warning'),
        );
        expect(semantics.value, isEmpty);
        expect(semantics.role, SemanticsRole.loadingSpinner);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'plain tmux does not render MonkeyMux per-window progress',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final tmuxService = _MockTmuxService();
        const windows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: true,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 45,
            ),
          ),
        ];
        when(
          () => tmuxService.foregroundSessionNameOrThrow(session),
        ).thenAnswer((_) async => 'work');
        when(
          () => tmuxService.listWindows(session, 'work'),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.watchWindowChanges(session, 'work'),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});
        host = _buildHost(
          id: host.id,
          tmuxSessionName: 'work',
          remoteMuxBackend: RemoteMuxBackend.tmux,
        );

        await pumpScreen(tester, tmuxService: tmuxService);

        expect(
          find.byKey(const ValueKey('monkeymux-sidebar-progress-0')),
          findsNothing,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'uses a collapsible tmux sidebar on wide terminal layouts',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        final handleFinder = find.byKey(const ValueKey('tmux-handle-bar'));
        expect(handleFinder, findsOneWidget);
        expect(tester.getSize(handleFinder).width, tmuxSidebarCollapsedWidth);
        expect(tester.getRect(handleFinder).left, closeTo(0, 0.1));
        expect(
          find.byKey(const ValueKey('tmux-sidebar-window-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('tmux-sidebar-window-1')),
          findsOneWidget,
        );
        expect(find.text('shell'), findsNothing);
        expect(find.text('agent'), findsNothing);
        expect(
          find.byKey(const ValueKey('tmux-terminal-dismiss-region')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('tmux-sidebar-new-window')));
        await tester.pumpAndSettle();

        final emptyWindowFinder = find.text('Empty terminal');
        expect(emptyWindowFinder, findsOneWidget);
        expect(
          tester.getTopLeft(emptyWindowFinder).dx,
          greaterThanOrEqualTo(tmuxSidebarCollapsedWidth),
        );

        await tester.tap(emptyWindowFinder);
        await tester.pump();

        verify(
          () => tmuxService.createWindow(
            session,
            'work',
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: any(named: 'workingDirectory'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).called(1);
        await tester.pump(const Duration(seconds: 1));

        await tester.tap(find.byKey(const ValueKey('tmux-sidebar-window-1')));
        await tester.pump();

        verify(
          () => tmuxService.selectWindow(
            session,
            'work',
            1,
            windowId: any(named: 'windowId'),
            extraFlags: any(named: 'extraFlags'),
            clientImageSignatures: any(named: 'clientImageSignatures'),
          ),
        ).called(1);
        await tester.pump(const Duration(seconds: 1));

        await tester.drag(
          find.byKey(const ValueKey('tmux-sidebar-window-0')),
          const Offset(80, 0),
          kind: PointerDeviceKind.mouse,
          touchSlopX: 0,
        );
        await tester.pump();

        expect(tester.getSize(handleFinder).width, tmuxSidebarExpandedWidth);
        expect(tester.getRect(handleFinder).left, closeTo(0, 0.1));
        expect(find.text('shell'), findsOneWidget);
        expect(find.text('agent'), findsOneWidget);

        await tester.drag(
          find.text('shell'),
          const Offset(-80, 0),
          kind: PointerDeviceKind.mouse,
          touchSlopX: 0,
        );
        await tester.pump();

        expect(tester.getSize(handleFinder).width, tmuxSidebarCollapsedWidth);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'touching the terminal dismisses the expanded tmux bar',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);

        await tester.tapAt(const Offset(20, 120));
        await tester.pump();

        expect(dismissRegion, findsNothing);
        expect(find.byType(TerminalScreen), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Android back dismisses the expanded tmux bar before leaving the terminal',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pump();

        expect(dismissRegion, findsNothing);
        expect(find.byType(TerminalScreen), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'hiding the expanded tmux bar restores normal back handling',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final popScope = find.byWidgetPredicate((widget) => widget is PopScope);
        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);
        expect(tester.widget<PopScope<Object?>>(popScope).canPop, isFalse);

        await openTerminalOverflowSubmenu(tester, 'Options');
        await tester.tap(find.text('Hide tmux Bar'));
        await tester.pumpAndSettle();

        expect(dismissRegion, findsNothing);
        expect(tester.widget<PopScope<Object?>>(popScope).canPop, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'tmux bar passes host yolo mode when resuming an AI session',
      (tester) async {
        final tmuxService = _MockTmuxService();
        final discoveryService = _MockAgentSessionDiscoveryService();
        final settingsService = SettingsService(db);
        final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
          settingsService,
        );
        const codexSession = ToolSessionInfo(
          toolName: 'Codex',
          sessionId: 'codex-session',
          workingDirectory: '/home/demo/project',
          summary: 'Resume codex work',
        );

        await cliLaunchPreferencesService.setPreferencesForHost(
          host.id,
          const HostCliLaunchPreferences(startInYoloMode: true),
        );
        when(
          () => tmuxService.createWindow(
            session,
            'work',
            command: any(named: 'command'),
            name: any(named: 'name'),
            workingDirectory: any(named: 'workingDirectory'),
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.hasForegroundClientOrThrow(
            session,
            'work',
            extraFlags: any(named: 'extraFlags'),
          ),
        ).thenAnswer((_) async => true);
        when(
          () => discoveryService.discoverSessionsStream(
            session,
            workingDirectory: any(named: 'workingDirectory'),
            maxPerTool: any(named: 'maxPerTool'),
            toolName: any(named: 'toolName'),
          ),
        ).thenAnswer((invocation) {
          final toolName = invocation.namedArguments[#toolName] as String?;
          return Stream<DiscoveredSessionsResult>.value(
            DiscoveredSessionsResult(
              sessions: toolName == 'Codex'
                  ? const <ToolSessionInfo>[codexSession]
                  : const <ToolSessionInfo>[],
              attemptedTools: toolName == null ? const <String>[] : [toolName],
            ),
          );
        });
        when(
          () => discoveryService.buildResumeCommand(
            codexSession,
            startInYoloMode: true,
          ),
        ).thenReturn("codex --yolo resume 'codex-session'");

        await pumpTmuxScreen(
          tester,
          tmuxService,
          settingsServiceOverride: settingsService,
          agentSessionDiscoveryServiceOverride: discoveryService,
        );

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.ensureVisible(find.text('AI Sessions'));
        await tester.tap(find.text('AI Sessions'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.ensureVisible(find.text('Codex'));
        await tester.tap(find.text('Codex'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Resume codex work'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        verify(
          () => discoveryService.buildResumeCommand(
            codexSession,
            startInYoloMode: true,
          ),
        ).called(1);
        verify(
          () => tmuxService.createWindow(
            session,
            'work',
            command: "codex --yolo resume 'codex-session'",
            workingDirectory: '/home/demo/project',
          ),
        ).called(1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    for (final preset in ['none', 'unsupported', 'saved']) {
      testWidgets(
        'auto-connect command with $preset preset',
        (tester) async {
          final settingsService = SettingsService(db);
          final saved = preset == 'saved';
          final command = saved
              ? 'codex --approval-mode never'
              : 'gemini --yolo';
          const legacy = {'tool': 'geminiCli', 'workingDirectory': '~/legacy'};
          session = SshSession(
            connectionId: 7,
            hostId: host.id,
            client: sshClient,
            config: session.config,
          );
          host = _buildHost(id: host.id, autoConnectCommand: command);
          if (preset == 'unsupported') {
            await settingsService.setJson(SettingKeys.agentLaunchPresets, {
              '${host.id}': legacy,
            });
          } else if (saved) {
            await AgentLaunchPresetService(settingsService).setPresetForHost(
              host.id,
              const AgentLaunchPreset(tool: AgentLaunchTool.codex),
            );
            await HostCliLaunchPreferencesService(
              settingsService,
            ).setPreferencesForHost(
              host.id,
              const HostCliLaunchPreferences(startInYoloMode: true),
            );
          }
          await tester.pumpWidget(
            buildScreen(
              overrides: [
                settingsServiceProvider.overrideWithValue(settingsService),
              ],
            ),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          final written = shellWrites.map(utf8.decode).join();
          if (saved) {
            expect(written, contains('codex --yolo'));
            expect(written, isNot(contains('--approval-mode never')));
          } else {
            expect(
              written,
              preset == 'unsupported'
                  ? isNot(contains(command))
                  : contains(command),
            );
            if (preset == 'unsupported') {
              expect(
                await settingsService.getJson(SettingKeys.agentLaunchPresets),
                containsPair('${host.id}', legacy),
              );
            }
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }

    testWidgets(
      'reconnects a lost MonkeyMux session without launching a new agent',
      (tester) async {
        final settingsService = SettingsService(db);
        final presetService = AgentLaunchPresetService(settingsService);
        final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
          settingsService,
        );
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final tmuxService = _MockTmuxService();
        final reconnectClient = _MockSshClient();
        final reconnectShell = _MockShellChannel();
        final reconnectDone = Completer<void>();
        final reconnectStdout = StreamController<Uint8List>.broadcast();
        final reconnectCommands = <String>[];
        addTearDown(() async {
          await reconnectStdout.close();
          if (!reconnectDone.isCompleted) {
            reconnectDone.complete();
          }
        });
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: session.config,
        );
        final reconnectSession = SshSession(
          connectionId: 8,
          hostId: host.id,
          client: reconnectClient,
          config: session.config,
        );
        host = _buildHost(id: host.id, autoConnectCommand: 'copilot');
        await presetService.setPresetForHost(
          host.id,
          const AgentLaunchPreset(
            tool: AgentLaunchTool.copilotCli,
            workingDirectory: '/work/project',
            tmuxSessionName: 'agents',
            remoteMuxBackend: RemoteMuxBackend.monkeyMux,
          ),
        );
        await cliLaunchPreferencesService.setPreferencesForHost(
          host.id,
          const HostCliLaunchPreferences(startInYoloMode: true),
        );
        when(
          () => monetizationService.canUseFeature(any()),
        ).thenAnswer((_) async => false);
        when(() => tmuxService.clearCache(any())).thenAnswer((_) async {});
        when(() => monkeyMuxService.clearCache(any())).thenAnswer((_) async {});
        for (final testSession in <SshSession>[session, reconnectSession]) {
          when(
            () => monkeyMuxInstallerService.ensureInstalled(
              testSession,
              priority: any(named: 'priority'),
              confirmInstall: any(named: 'confirmInstall'),
            ),
          ).thenAnswer(
            (_) async => const MonkeyMuxInstallation(
              executablePath: '/tmp/monkeymux',
              platform: 'darwin-arm64',
              version: '0.1.10',
            ),
          );
          when(
            () => monkeyMuxService.hasForegroundClientOrThrow(
              testSession,
              'agents',
            ),
          ).thenAnswer((_) async => true);
          when(
            () => monkeyMuxService.listWindows(testSession, 'agents'),
          ).thenAnswer(
            (_) async => const <TmuxWindow>[
              TmuxWindow(index: 0, name: 'Copilot CLI', isActive: true),
            ],
          );
          when(
            () => monkeyMuxService.watchWindowChanges(testSession, 'agents'),
          ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
          when(
            () => tmuxService.detectInstalledAgentTools(testSession),
          ).thenAnswer((_) async => const <AgentLaunchTool>{});
          when(
            () => tmuxService.prefetchInstalledAgentTools(testSession),
          ).thenAnswer((_) async {});
        }
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () => reconnectClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          reconnectCommands.add(
            invocation.positionalArguments.single as String,
          );
          return reconnectShell;
        });
        when(
          () => reconnectShell.stdout,
        ).thenAnswer((_) => reconnectStdout.stream);
        when(
          () => reconnectShell.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => reconnectShell.done).thenAnswer((_) => reconnectDone.future);
        when(() => reconnectShell.write(any())).thenAnswer((_) {});
        when(
          () => reconnectShell.resizeTerminal(any(), any(), any(), any()),
        ).thenAnswer((_) {});
        when(reconnectShell.close).thenAnswer((_) {});
        final activeSessions = _TestActiveSessionsNotifier(
          session,
          reconnectSession: reconnectSession,
        )..disconnectedConnectionIds.add(reconnectSession.connectionId);

        await tester.pumpWidget(
          buildScreen(
            activeSessions: activeSessions,
            overrides: [
              settingsServiceProvider.overrideWithValue(settingsService),
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final startupCommands = executedCommands
            .where(
              (command) =>
                  command.contains(' attach') && command.contains('--command'),
            )
            .toList(growable: false);
        expect(startupCommands, hasLength(1));
        final startupCommand = startupCommands.single;
        expect(startupCommand, contains('/tmp/monkeymux'));
        expect(startupCommand, contains('--update-policy never'));
        expect(startupCommand, contains('--cwd'));
        expect(startupCommand, contains('/work/project'));
        expect(startupCommand, contains('--name'));
        expect(startupCommand, contains('Copilot CLI'));
        expect(startupCommand, contains('copilot --yolo'));
        expect(startupCommand, contains('agents'));
        expect(
          shellWrites.map(utf8.decode).join(),
          isNot(contains('/tmp/monkeymux')),
        );
        expect(session.remoteMuxBackend, RemoteMuxBackend.monkeyMux);
        expect(session.remoteMuxSessionName, 'agents');
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        expect(monkeyMuxService.resizeTerminalCalls, isNotEmpty);
        final resizeCall = monkeyMuxService.resizeTerminalCalls.last;
        expect(resizeCall.sessionName, 'agents');
        expect(resizeCall.columns, greaterThan(0));
        expect(resizeCall.rows, greaterThan(0));
        verifyNever(() => sshClient.shell(pty: any(named: 'pty')));
        verify(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: SshExecPriority.normal,
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).called(1);
        verifyNever(
          () => monetizationService.canUseFeature(
            MonetizationFeature.autoConnectAutomation,
          ),
        );

        await activeSessions.disconnect(session.connectionId);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          activeSessions.disconnectedConnectionIds,
          contains(session.connectionId),
        );
        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('Reconnect'), findsOneWidget);
        expect(
          executedCommands.where((command) => command.contains(' attach')),
          hasLength(1),
        );

        await tester.tap(find.text('Reconnect'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        final reconnectAttachCommands = reconnectCommands
            .where((command) => command.contains(' attach'))
            .toList(growable: false);
        expect(reconnectAttachCommands, hasLength(1));
        final reconnectCommand = reconnectAttachCommands.single;
        expect(reconnectCommand, contains('/tmp/monkeymux'));
        expect(reconnectCommand, contains('--existing'));
        expect(reconnectCommand, contains('--update-policy never'));
        expect(reconnectCommand, contains('agents'));
        expect(reconnectCommand, isNot(contains('--command')));
        expect(reconnectCommand, isNot(contains('--name')));
        expect(reconnectSession.remoteMuxBackend, RemoteMuxBackend.monkeyMux);
        expect(reconnectSession.remoteMuxSessionName, 'agents');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'still reviews an imported resume command before executing it',
      (tester) async {
        const resumeCommand = 'copilot --resume saved-session';
        host = _buildHost(
          id: host.id,
          autoConnectCommand: resumeCommand,
          autoConnectRequiresConfirmation: true,
        );
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: session.config,
        );

        await pumpScreen(tester);
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.text('Review imported auto-connect command'),
          findsOneWidget,
        );
        expect(find.text(resumeCommand), findsOneWidget);
        expect(shellWrites, isEmpty);

        await tester.tap(find.text('Run once'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          shellWrites.map(utf8.decode).join(),
          contains('$resumeCommand\r'),
        );
        expect(host.autoConnectRequiresConfirmation, isTrue);
        verifyNever(() => hostRepository.updateFields(any(), any()));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    for (final disposeWhileSaving in [false, true]) {
      testWidgets(
        'trust persistence completes before running, disposed: $disposeWhileSaving',
        (tester) async {
          const command = 'copilot --resume saved-session';
          final saved = Completer<bool>();
          host = _buildHost(
            id: host.id,
            autoConnectCommand: command,
            autoConnectRequiresConfirmation: true,
          );
          session = SshSession(
            connectionId: 7,
            hostId: host.id,
            client: sshClient,
            config: session.config,
          );
          when(
            () => hostRepository.updateFields(any(), any()),
          ).thenAnswer((_) => saved.future);

          await pumpScreen(tester);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Always run'));
          await tester.pump();

          final changes =
              verify(
                    () => hostRepository.updateFields(host.id, captureAny()),
                  ).captured.single
                  as HostsCompanion;
          expect(changes.autoConnectRequiresConfirmation.present, isTrue);
          expect(changes.autoConnectRequiresConfirmation.value, isFalse);
          expect(shellWrites, isEmpty);
          if (disposeWhileSaving) {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          saved.complete(true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          if (disposeWhileSaving) {
            expect(shellWrites, isEmpty);
          } else {
            expect(shellWrites.map(utf8.decode).join(), contains('$command\r'));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }

    testWidgets(
      'prompts before installing MonkeyMux for foreground attach',
      (tester) async {
        final monkeyMuxInstallerService = _PromptingMonkeyMuxInstallerService(
          request: const MonkeyMuxInstallRequest(
            platform: 'darwin-arm64',
            version: '0.1.14',
            size: 1536,
          ),
        );
        final monkeyMuxService = _MockMonkeyMuxService();
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () =>
              monkeyMuxService.hasForegroundClientOrThrow(session, sessionName),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, sessionName),
        ).thenAnswer(
          (_) async => const <TmuxWindow>[
            TmuxWindow(index: 0, name: 'shell', isActive: true),
          ],
        );
        when(
          () => monkeyMuxService.watchWindowChanges(session, sessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(find.text('Install MonkeyMux helper?'), findsOneWidget);
        expect(find.text('Bundled version: 0.1.14'), findsOneWidget);
        expect(find.text('Platform: darwin-arm64'), findsOneWidget);
        expect(find.text('Size: 1.5 KB'), findsOneWidget);
        expect(executedCommands, isEmpty);

        await tester.tap(find.widgetWithText(FilledButton, 'Install'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final attachCommands = executedCommands
            .where((command) => command.contains(' attach'))
            .toList(growable: false);
        expect(attachCommands, hasLength(1));
        final startupCommand = attachCommands.single;
        expect(startupCommand, contains('/tmp/monkeymux'));
        expect(startupCommand, contains(' attach'));
        expect(startupCommand, contains('--update-policy never'));
        expect(startupCommand, contains(sessionName));
        expect(shellWrites.map(utf8.decode).join(), isEmpty);
        expect(session.remoteMuxBackend, RemoteMuxBackend.monkeyMux);
        expect(session.remoteMuxSessionName, sessionName);
        expect(find.byKey(const ValueKey('tmux-handle-bar')), findsOneWidget);
        verifyNever(() => sshClient.shell(pty: any(named: 'pty')));
        expect(monkeyMuxInstallerService.ensureInstalledCalls, 1);
        expect(monkeyMuxInstallerService.acceptedConfirmations, <bool>[true]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    for (final testCase in const [
      (
        name: 'updates and restores an older MonkeyMux server',
        importedNeedsReview: false,
        runningVersion: '0.1.13',
        dialogTitle: 'Update running MonkeyMux?',
        confirmLabel: 'Update and restore',
        dialogMessage:
            'MonkeySSH will upload helper 0.1.14. It can then restart this '
            'workspace',
        capabilities: <String>{},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: true,
        warningMessage: 'The running helper cannot stop itself cleanly',
        updatePolicy: MonkeyMuxServerUpdatePolicy.always,
        notice: null,
      ),
      (
        name:
            'updates and restores without reviewing the generated attach command',
        importedNeedsReview: true,
        runningVersion: '0.1.13',
        dialogTitle: 'Update running MonkeyMux?',
        confirmLabel: 'Update and restore',
        dialogMessage:
            'MonkeySSH will upload helper 0.1.14. It can then restart this '
            'workspace',
        capabilities: <String>{},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: true,
        warningMessage: 'The running helper cannot stop itself cleanly',
        updatePolicy: MonkeyMuxServerUpdatePolicy.always,
        notice: null,
      ),
      (
        name:
            'defers an upgrade without reviewing the generated attach command',
        importedNeedsReview: true,
        runningVersion: '0.1.13',
        dialogTitle: 'Update running MonkeyMux?',
        confirmLabel: 'Use 0.1.13 for now',
        dialogMessage:
            'MonkeySSH will upload helper 0.1.14. It can then restart this '
            'workspace',
        capabilities: <String>{},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: true,
        warningMessage: 'The running helper cannot stop itself cleanly',
        updatePolicy: MonkeyMuxServerUpdatePolicy.never,
        notice: null,
      ),
      (
        name: 'connects to an older MonkeyMux server when update is deferred',
        importedNeedsReview: false,
        runningVersion: '0.1.13',
        dialogTitle: 'Update running MonkeyMux?',
        confirmLabel: 'Use 0.1.13 for now',
        dialogMessage:
            'MonkeySSH will upload helper 0.1.14. It can then restart this '
            'workspace',
        capabilities: {'shutdown'},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: true,
        warningMessage: 'Updating may briefly interrupt running programs',
        updatePolicy: MonkeyMuxServerUpdatePolicy.never,
        notice: null,
      ),
      (
        name: 'updates and restores while native agents are active',
        importedNeedsReview: false,
        runningVersion: '0.1.13',
        dialogTitle: 'Update running MonkeyMux?',
        confirmLabel: 'Update and restore',
        dialogMessage:
            'MonkeySSH will upload helper 0.1.14. It can then restart this '
            'workspace',
        capabilities: {'shutdown', 'acp-window-v1'},
        nativeAcpWindowCount: 2,
        showsUpgradeDecision: true,
        warningMessage:
            'Native agent windows stay connected to their running sessions',
        updatePolicy: MonkeyMuxServerUpdatePolicy.always,
        notice: null,
      ),
      (
        name: 'keeps a newer MonkeyMux server without downgrade guidance',
        importedNeedsReview: false,
        runningVersion: '0.1.15',
        dialogTitle: 'Install bundled MonkeyMux helper?',
        confirmLabel: 'Install',
        dialogMessage: 'newer than bundled 0.1.14',
        capabilities: {'shutdown'},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: false,
        warningMessage: null,
        updatePolicy: MonkeyMuxServerUpdatePolicy.never,
        notice:
            'This workspace is running MonkeyMux 0.1.15, newer than bundled '
            '0.1.14. Keeping the running server.',
      ),
      (
        name: 'keeps an unknown MonkeyMux server without upgrade guidance',
        importedNeedsReview: false,
        runningVersion: null,
        dialogTitle: 'Install bundled MonkeyMux helper?',
        confirmLabel: 'Install',
        dialogMessage: 'running a different MonkeyMux version',
        capabilities: {'shutdown'},
        nativeAcpWindowCount: 0,
        showsUpgradeDecision: false,
        warningMessage: null,
        updatePolicy: MonkeyMuxServerUpdatePolicy.never,
        notice:
            'This workspace is running a different MonkeyMux version. Keeping '
            'the running server to avoid interrupting its windows.',
      ),
    ]) {
      testWidgets(testCase.name, (tester) async {
        final monkeyMuxInstallerService = _PromptingMonkeyMuxInstallerService(
          request: const MonkeyMuxInstallRequest(
            platform: 'darwin-arm64',
            version: '0.1.14',
            size: 1536,
          ),
        );
        final monkeyMuxService = _MockMonkeyMuxService()
          ..installedHelpersStatus = MonkeyMuxServerStatus(
            version: testCase.runningVersion,
            capabilities: testCase.capabilities,
            nativeAcpWindowCount: testCase.nativeAcpWindowCount,
          )
          ..runningStatus = MonkeyMuxServerStatus(
            version: testCase.runningVersion,
            capabilities: testCase.capabilities,
            nativeAcpWindowCount: testCase.nativeAcpWindowCount,
          );
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
          autoConnectCommand: testCase.importedNeedsReview
              ? 'copilot --resume saved-session'
              : null,
          autoConnectRequiresConfirmation: testCase.importedNeedsReview,
        );
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () =>
              monkeyMuxService.hasForegroundClientOrThrow(session, sessionName),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, sessionName),
        ).thenAnswer(
          (_) async => const <TmuxWindow>[
            TmuxWindow(index: 0, name: 'shell', isActive: true),
          ],
        );
        when(
          () => monkeyMuxService.watchWindowChanges(session, sessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(find.text(testCase.dialogTitle), findsOneWidget);
        expect(
          find.text('Running version: ${testCase.runningVersion ?? 'unknown'}'),
          findsOneWidget,
        );
        expect(find.textContaining(testCase.dialogMessage), findsOneWidget);
        if (testCase.showsUpgradeDecision) {
          expect(
            find.textContaining('automatically restore its existing windows'),
            findsOneWidget,
          );
          expect(find.textContaining(testCase.warningMessage!), findsOneWidget);
          expect(find.text('Use 0.1.13 for now'), findsOneWidget);
          expect(find.text('Update and restore'), findsOneWidget);
          expect(
            find.textContaining('Close all MonkeyMux windows'),
            findsNothing,
          );
        }
        expect(executedCommands, isEmpty);

        await tester.tap(find.text(testCase.confirmLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text(testCase.dialogTitle), findsNothing);
        expect(find.text('Update running MonkeyMux?'), findsNothing);
        expect(find.text('Review imported auto-connect command'), findsNothing);
        expect(
          host.autoConnectRequiresConfirmation,
          testCase.importedNeedsReview,
        );
        verifyNever(() => hostRepository.updateFields(any(), any()));
        final attachCommands = executedCommands
            .where((command) => command.contains(' attach'))
            .toList(growable: false);
        expect(attachCommands, hasLength(1));
        final startupCommand = attachCommands.single;
        expect(startupCommand, contains('/tmp/monkeymux'));
        expect(
          startupCommand,
          contains('--update-policy ${testCase.updatePolicy.cliValue}'),
        );
        expect(shellWrites.map(utf8.decode).join(), isEmpty);
        expect(monkeyMuxInstallerService.acceptedConfirmations, <bool>[true]);
        expect(
          monkeyMuxService.runningServerStatusFromInstalledHelpersCalls,
          1,
        );
        expect(monkeyMuxService.runningServerStatusCalls, 1);
        if (testCase.notice case final notice?) {
          expect(find.text(notice), findsOneWidget);
        } else {
          expect(find.byType(SnackBar), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }

    // The bundled manifest version is only a packaging label. `attach` decides
    // whether to restart a running server by comparing it against the version
    // compiled into the helper binary, so when the two drift the update dialog
    // would be offered for an upgrade the helper then skips, and it would come
    // back on every connect without ever applying.
    testWidgets(
      'skips the update prompt when the helper binary matches the server',
      (tester) async {
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final monkeyMuxService = _MockMonkeyMuxService()
          ..helperVersion = '0.1.13'
          ..runningStatus = const MonkeyMuxServerStatus(
            version: '0.1.13',
            capabilities: {'shutdown'},
          );
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: any(named: 'priority'),
            confirmInstall: any(named: 'confirmInstall'),
          ),
          // The manifest labels this install 0.1.14 while the binary it
          // shipped still reports 0.1.13.
        ).thenAnswer(
          (_) async => const MonkeyMuxInstallation(
            executablePath: '/tmp/monkeymux',
            platform: 'darwin-arm64',
            version: '0.1.14',
          ),
        );
        when(
          () =>
              monkeyMuxService.hasForegroundClientOrThrow(session, sessionName),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, sessionName),
        ).thenAnswer(
          (_) async => const <TmuxWindow>[
            TmuxWindow(index: 0, name: 'shell', isActive: true),
          ],
        );
        when(
          () => monkeyMuxService.watchWindowChanges(session, sessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Update running MonkeyMux?'), findsNothing);
        expect(monkeyMuxService.installedHelperVersionCalls, 1);
        // ACP executable discovery can run on a second SSH channel once the
        // terminal opens. Assert the attach count independently of that probe.
        final attachCommands = executedCommands
            .where((command) => command.contains(' attach'))
            .toList(growable: false);
        expect(attachCommands, hasLength(1));
        expect(attachCommands.single, contains('--update-policy never'));
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'does not use the update UI after disposal during the status probe',
      (tester) async {
        final statusCompleter = Completer<MonkeyMuxServerStatus?>();
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final monkeyMuxService = _MockMonkeyMuxService()
          ..runningStatusFuture = statusCompleter.future;
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
          autoConnectRequiresConfirmation: true,
        );
        when(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: any(named: 'priority'),
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).thenAnswer(
          (_) async => const MonkeyMuxInstallation(
            executablePath: '/tmp/monkeymux',
            platform: 'darwin-arm64',
            version: '0.1.14',
          ),
        );
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => shellChannel);
        when(
          () =>
              monkeyMuxService.hasForegroundClientOrThrow(session, sessionName),
        ).thenAnswer((_) async => true);
        when(
          () => monkeyMuxService.listWindows(session, sessionName),
        ).thenAnswer((_) async => const <TmuxWindow>[]);
        when(
          () => monkeyMuxService.watchWindowChanges(session, sessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );
        await tester.pump();
        expect(monkeyMuxService.runningServerStatusCalls, 1);

        await tester.pumpWidget(const SizedBox.shrink());
        statusCompleter.complete(
          const MonkeyMuxServerStatus(
            version: '0.1.13',
            capabilities: {'shutdown'},
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text('Review imported auto-connect command'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'opens a regular terminal when MonkeyMux install prompt is declined',
      (tester) async {
        final monkeyMuxInstallerService = _PromptingMonkeyMuxInstallerService(
          request: const MonkeyMuxInstallRequest(
            platform: 'darwin-arm64',
            version: '0.1.14',
            size: 1536,
          ),
        );
        final monkeyMuxService = _MockMonkeyMuxService();
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(find.text('Install MonkeyMux helper?'), findsOneWidget);
        expect(executedCommands, isEmpty);

        await tester.tap(find.widgetWithText(TextButton, 'Open shell'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(executedCommands, <String>[
          _trueColorLoginShellCommand(session.config),
        ]);
        expect(shellWrites, isEmpty);
        expect(find.text('Install MonkeyMux helper?'), findsNothing);
        expect(session.remoteMuxBackend, isNull);
        expect(session.remoteMuxSessionName, isNull);
        expect(monkeyMuxInstallerService.ensureInstalledCalls, 1);
        expect(monkeyMuxInstallerService.acceptedConfirmations, <bool>[false]);
        verify(
          () => sshClient.execute(
            _trueColorLoginShellCommand(session.config),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verifyNever(() => sshClient.shell(pty: any(named: 'pty')));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'does not fall back to tmux when MonkeyMux startup preparation fails',
      (tester) async {
        final monkeyMuxInstallerService = _MockMonkeyMuxInstallerService();
        final monkeyMuxService = _MockMonkeyMuxService();
        final tmuxService = _MockTmuxService();
        const sessionName = 'work';
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          tmuxSessionName: sessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );
        final executedCommands = <String>[];
        when(
          () => sshClient.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((invocation) async {
          executedCommands.add(invocation.positionalArguments.single as String);
          return shellChannel;
        });
        when(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: any(named: 'priority'),
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).thenThrow(Exception('install failed'));
        when(
          () => tmuxService.prefetchInstalledAgentTools(session),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          buildScreen(
            overrides: [
              monkeyMuxInstallerServiceProvider.overrideWithValue(
                monkeyMuxInstallerService,
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
              monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
            ],
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(executedCommands, <String>[
          _trueColorLoginShellCommand(session.config),
        ]);
        expect(shellWrites.map(utf8.decode).join(), isEmpty);
        expect(find.text('MonkeyMux is unavailable.'), findsOneWidget);
        verify(
          () => monkeyMuxInstallerService.ensureInstalled(
            session,
            priority: SshExecPriority.normal,
            confirmInstall: any(named: 'confirmInstall'),
          ),
        ).called(1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'skips Pro auto-connect gate when the host has no auto-connect workflow',
      (tester) async {
        when(
          () => monetizationService.canUseFeature(any()),
        ).thenAnswer((_) async => false);

        await pumpScreen(tester);
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('This auto-connect workflow needs MonkeySSH Pro to run.'),
          findsNothing,
        );
        verifyNever(
          () => monetizationService.canUseFeature(
            MonetizationFeature.autoConnectAutomation,
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'terminal tap opens the mobile keyboard when tap-to-show is enabled',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.log.clear();
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isNotEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'app resume restores the mobile keyboard when it was visible',
      (tester) async {
        await pumpScreen(tester);

        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);
        tester.testTextInput.updateEditingValue(
          _editingValue('resume', selectionOffset: 6),
        );
        await tester.pump();

        tester.testTextInput.log.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.hide',
          ),
          isNotEmpty,
        );

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isNotEmpty,
        );
        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isNotEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Android app resume leaves a system-dismissed keyboard closed',
      (tester) async {
        // Android can retain the previous IME inset after app switching even
        // though the system keyboard itself has been dismissed.
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 500);
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });

        await pumpScreen(tester);
        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 344);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        tester.testTextInput.log.clear();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byTooltip('Hide system keyboard'), findsNothing);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 844);
        final inputHandler = tester.widget<TerminalTextInputHandler>(
          find.byType(TerminalTextInputHandler),
        );
        expect(inputHandler.focusNode.hasFocus, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Android app background invalidates a queued keyboard request',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 500);
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });

        await pumpScreen(tester);
        tester.testTextInput.log.clear();

        // Queue the post-frame keyboard request, then background the app before
        // Flutter can run it. It must not replay in the resumed window.
        await tester.tap(find.byTooltip('Show system keyboard'));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        expect(tester.testTextInput.isVisible, isFalse);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 844);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'terminal overflow menu preserves the visible mobile keyboard',
      (tester) async {
        await pumpScreen(tester);

        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);
        expect(find.byType(MenuAnchor), findsOneWidget);

        await openTerminalOverflowMenu(tester);

        expect(find.text('Snippets'), findsOneWidget);
        expect(tester.testTextInput.isVisible, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'extra keys toggle preserves the visible mobile keyboard',
      (tester) async {
        await pumpScreen(tester);

        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        Future<void> expectKeyboardReshownAfterToggle(String tooltip) async {
          tester.testTextInput.log.clear();

          await tester.tap(find.byTooltip(tooltip));
          await tester.pump();
          await tester.pump();

          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.show',
            ),
            isNotEmpty,
          );
          expect(tester.testTextInput.isVisible, isTrue);
        }

        await expectKeyboardReshownAfterToggle('Hide extra keys');
        await expectKeyboardReshownAfterToggle('Show extra keys');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'keyboard button shows the keyboard despite a stale bottom inset',
      (tester) async {
        // Simulate the broken state: the platform still reserves keyboard space
        // (a stale bottom inset) while the keyboard itself is not open.
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 500);
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });

        await pumpScreen(tester);

        // The keyboard is not actually shown, so the toggle must offer to show
        // it rather than treating the stale inset as a visible keyboard.
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byTooltip('Hide system keyboard'), findsNothing);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 844);

        tester.testTextInput.log.clear();
        await tester.tap(find.byTooltip('Show system keyboard'));
        await tester.pump();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isNotEmpty,
        );
        expect(tester.testTextInput.isVisible, isTrue);

        // The toggle must reactively flip to "hide" once the keyboard is shown,
        // even though the (stale) bottom inset never changed, so a second tap
        // hides the keyboard instead of re-showing it.
        await tester.pump();
        expect(find.byTooltip('Hide system keyboard'), findsOneWidget);
        expect(find.byTooltip('Show system keyboard'), findsNothing);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 344);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'terminal overflow menu stays above the visible mobile keyboard',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 500);
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });
        await pumpScreen(tester);
        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();
        await tester.pump();

        await openTerminalOverflowMenu(tester);

        const keyboardTop = 844 - 500;
        final menuScrollable = find.ancestor(
          of: find.text('Snippets'),
          matching: find.byType(SingleChildScrollView),
        );
        expect(menuScrollable, findsOneWidget);
        expect(
          tester.getBottomLeft(menuScrollable).dy,
          lessThanOrEqualTo(keyboardTop),
        );

        await tester.drag(menuScrollable, const Offset(0, -320));
        await tester.pumpAndSettle();

        expect(find.text('Disconnect'), findsOneWidget);
        expect(
          tester.getBottomLeft(find.text('Disconnect')).dy,
          lessThanOrEqualTo(keyboardTop),
        );
        expect(tester.testTextInput.isVisible, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'terminal overflow menu uses a cascading menu anchor on desktop',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byType(MenuAnchor), findsOneWidget);

        await openTerminalOverflowMenu(tester);

        expect(terminalSubmenuButton('Options'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    for (final restoreKeyboard in [true, false]) {
      testWidgets(
        'SFTP browser restores ${restoreKeyboard ? 'mobile keyboard' : 'MonkeyMux focus and mouse reporting'}',
        (tester) async {
          final openedPaths = <String>[];
          final tmuxService = _MockTmuxService();
          final monkeyMuxService = _MockMonkeyMuxService();
          if (!restoreKeyboard) {
            const sessionName = 'agents';
            final windows = <TmuxWindow>[
              const TmuxWindow(
                index: 0,
                name: 'copilot',
                isActive: true,
                id: '@0',
                currentCommand: 'copilot',
                currentPath: '/repo',
                agentTool: AgentLaunchTool.copilotCli,
                terminalReportsMouseWheel: true,
                terminalMouseReportSgr: true,
              ),
            ];

            host = _buildHost(
              id: host.id,
              tmuxSessionName: sessionName,
              remoteMuxBackend: RemoteMuxBackend.monkeyMux,
            );
            session
              ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
              ..remoteMuxSessionName = sessionName;
            createMuxFixture(tmuxService, monkeyMuxService, sessionName)
              ..stubForegroundClient()
              ..stubWindows(() => windows)
              ..stubWindowEvents()
              ..stubThemeRefresh()
              ..stubPrefetch();
            when(
              () => monkeyMuxService.currentPaneContext(
                session,
                sessionName,
                priority: any(named: 'priority'),
                extraFlags: any(named: 'extraFlags'),
              ),
            ).thenAnswer(
              (_) async => const TmuxPaneContext(
                currentPath: '/active-monkeymux',
                currentCommand: 'copilot',
              ),
            );
            when(
              () => tmuxService.detectInstalledAgentTools(session),
            ).thenAnswer((_) async => const <AgentLaunchTool>{});
          }
          final router = GoRouter(
            initialLocation:
                '/terminal/${host.id}?connectionId=${session.connectionId}',
            routes: [
              GoRoute(
                path: '/terminal/:hostId',
                name: Routes.terminal,
                builder: (context, state) => TerminalScreen(
                  hostId: host.id,
                  connectionId: session.connectionId,
                ),
              ),
              GoRoute(
                path: '/sftp/:hostId',
                name: Routes.sftp,
                builder: (context, state) {
                  openedPaths.add(
                    state.uri.queryParameters[restoreKeyboard
                            ? 'path'
                            : 'tmuxCwd'] ??
                        '',
                  );
                  return const Scaffold(body: Text('SFTP opened'));
                },
              ),
            ],
          );
          addTearDown(router.dispose);

          await tester.pumpWidget(
            buildScreen(
              overrides: [
                if (!restoreKeyboard)
                  tmuxServiceProvider.overrideWithValue(tmuxService),
                if (!restoreKeyboard)
                  monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pump();
          await tester.pump();
          if (!restoreKeyboard) {
            await tester.pump(const Duration(milliseconds: 250));
            await tester.pump();
          }

          if (restoreKeyboard) {
            await tester.tap(find.byType(MonkeyTerminalView));
            await tester.pump();

            expect(tester.testTextInput.isVisible, isTrue);
            tester.testTextInput.log.clear();

            await tester.tap(find.byTooltip('Browse files'));
            await tester.pumpAndSettle();

            expect(openedPaths, ['']);
            expect(find.text('SFTP opened'), findsOneWidget);
            expect(tester.testTextInput.isVisible, isFalse);
            expect(
              tester.testTextInput.log.where(
                (call) => call.method == 'TextInput.hide',
              ),
              isNotEmpty,
            );

            tester.testTextInput.log.clear();
            router.pop();
            await tester.pumpAndSettle();

            expect(tester.testTextInput.isVisible, isTrue);
            expect(
              tester.testTextInput.log.where(
                (call) => call.method == 'TextInput.show',
              ),
              isNotEmpty,
            );
          } else {
            final terminalView = tester.widget<MonkeyTerminalView>(
              find.byType(MonkeyTerminalView),
            );
            expect(terminalView.touchScrollToTerminal, isTrue);
            expect(terminalView.forceSgrTouchScroll, isTrue);

            session.terminal!.write('\x1b[?1004h');
            await tester.pump();
            expect(session.terminal!.reportFocusMode, isTrue);

            // Keep the keyboard hidden to isolate focus rearming on browser close.
            tester
                .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
                .requestKeyboard();
            await tester.pump();
            expect(tester.testTextInput.isVisible, isFalse);

            await tester.tap(find.byTooltip('Browse files'));
            await tester.pumpAndSettle();
            expect(openedPaths, ['/active-monkeymux']);
            verifyNever(
              () => tmuxService.currentPaneContext(
                any(),
                any(),
                priority: any(named: 'priority'),
                extraFlags: any(named: 'extraFlags'),
              ),
            );
            expect(find.text('SFTP opened'), findsOneWidget);
            expect(
              utf8.decode(shellWrites.expand((chunk) => chunk).toList()),
              contains('\x1b[O'),
            );

            shellWrites.clear();
            router.pop();
            await tester.pumpAndSettle();
            await tester.pump(const Duration(milliseconds: 60));

            expect(
              utf8.decode(shellWrites.expand((chunk) => chunk).toList()),
              contains('\x1b[I'),
            );
          }
        },
        variant: TargetPlatformVariant.only(
          restoreKeyboard ? TargetPlatform.iOS : TargetPlatform.android,
        ),
      );
    }

    testWidgets(
      'terminal double tap selects text without sending Tab',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('alpha beta');
        await tester.pumpAndSettle();

        expect(find.byType(SelectionArea), findsOneWidget);
        shellWrites.clear();

        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        final target = renderTerminal.localToGlobal(
          renderTerminal.getOffset(const CellOffset(2, 0)) +
              renderTerminal.cellSize.center(Offset.zero),
        );

        await tester.tapAt(target);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(target);
        await tester.pumpAndSettle();

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, isNot(contains('\t')));
        final selection = terminalViewState.renderTerminal.getSelectedContent();
        expect(selection?.plainText, 'alpha');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'system selection preserves an already visible mobile keyboard',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('alpha');
        await tester.pumpAndSettle();

        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        final target = renderTerminal.localToGlobal(
          renderTerminal.getOffset(const CellOffset(2, 0)) +
              renderTerminal.cellSize.center(Offset.zero),
        );

        await tester.longPressAt(target);
        await tester.pumpAndSettle();

        expect(tester.testTextInput.isVisible, isTrue);
        final selection = terminalViewState.renderTerminal.getSelectedContent();
        expect(selection?.plainText, 'alpha');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'terminal tap sends mouse input while system selection is enabled',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr)
          ..write('alpha beta');
        await tester.pumpAndSettle();

        shellWrites.clear();
        await tester.tap(find.byType(MonkeyTerminalView));
        await tester.pump();

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('\x1B[<0;'));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'terminal URL taps open links while system selection is enabled',
      (tester) async {
        const url = 'https://example.com/docs';
        const urlLauncherChannel = MethodChannel(
          'plugins.flutter.io/url_launcher',
        );
        final launchedUrls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          urlLauncherChannel,
          (call) async {
            if (call.method == 'launch') {
              final arguments = call.arguments! as Map<Object?, Object?>;
              launchedUrls.add(arguments['url']! as String);
              return true;
            }
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            urlLauncherChannel,
            null,
          ),
        );

        await pumpScreen(tester);

        session.terminal!.write('visit $url');
        await tester.pumpAndSettle();

        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        final lineText = trimTerminalLinePadding(
          session.terminal!.buffer.lines[0].getText(
            0,
            session.terminal!.buffer.viewWidth,
          ),
        );
        final startColumn = lineText.indexOf(url);
        expect(startColumn, isNonNegative);
        final cellOffset = CellOffset(startColumn + (url.length ~/ 2), 0);

        final tapPosition = renderTerminal.localToGlobal(
          renderTerminal.getOffset(cellOffset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
        final cancelledTap = await tester.startGesture(tapPosition);
        await cancelledTap.cancel();
        await tester.pumpAndSettle();
        expect(launchedUrls, isEmpty);

        await tester.tapAt(tapPosition);
        await tester.pumpAndSettle();

        expect(launchedUrls, [url]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'toolbar navigation keys clear the screen IME buffer',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byType(TerminalTextInputHandler), findsOneWidget);
        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('Left'));
        await tester.pump();

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'toolbar Ctrl state flows into the screen IME handler',
      (tester) async {
        await pumpScreen(tester);

        var handler = tester.widget<TerminalTextInputHandler>(
          find.byType(TerminalTextInputHandler),
        );
        expect(handler.hasActiveToolbarModifier?.call(), isFalse);

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        handler = tester.widget<TerminalTextInputHandler>(
          find.byType(TerminalTextInputHandler),
        );
        expect(handler.hasActiveToolbarModifier?.call(), isTrue);

        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();
        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'prompt-like shell output does not reconnect the IME input client before keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.log.clear();
        shellStdoutController.add(Uint8List.fromList(utf8.encode('> ')));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'prompt-like shell output reconnects the IME input client after keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('ls', selectionOffset: 2),
        );
        await tester.pump();

        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.log.clear();
        shellStdoutController.add(Uint8List.fromList(utf8.encode('> ')));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'ANSI-styled prompt-like shell output reconnects the IME input client after keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('ls', selectionOffset: 2),
        );
        await tester.pump();

        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.log.clear();
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\u001b[38;5;39m>\u001b[0m ')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'running shell commands bypass keyboard paste review',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('\u001b]133;C\u0007');
        await tester.pump();

        expect(session.shellStatus, TerminalShellStatus.runningCommand);

        shellWrites.clear();
        const suspiciousText = 'echo ready; rm -rf /';
        tester.testTextInput.updateEditingValue(
          _editingValue(suspiciousText, selectionOffset: suspiciousText.length),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Review keyboard paste'), findsNothing);
        expect(shellWrites.map(utf8.decode).join(), suspiciousText);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'running shell commands still review paste-like keyboard payloads',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('\u001b]133;C\u0007');
        await tester.pump();

        expect(session.shellStatus, TerminalShellStatus.runningCommand);

        shellWrites.clear();
        final insertedText = List.filled(
          terminalKeyboardPasteLikeInsertionThreshold + 1,
          'a',
        ).join();
        tester.testTextInput.updateEditingValue(
          _editingValue(insertedText, selectionOffset: insertedText.length),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Review keyboard paste'), findsOneWidget);
        expect(
          find.text('The keyboard inserted a paste-like amount of text.'),
          findsOneWidget,
        );
        expect(shellWrites, isEmpty);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'non-prompt shell output does not reconnect the IME input client',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.log.clear();
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('running task...\ncompleted 1/3')),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'shell stdout errors are handled without breaking the screen',
      (tester) async {
        await pumpScreen(tester);

        shellStdoutController.addError(StateError('stdout failed'));
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(TerminalTextInputHandler), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'system selectable selects terminal words and ignores later output',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('alpha');
        await tester.pumpAndSettle();

        Offset cellCenter(CellOffset offset) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          return renderTerminal.localToGlobal(
            renderTerminal.getOffset(offset) +
                renderTerminal.cellSize.center(Offset.zero),
          );
        }

        await tester.longPressAt(cellCenter(const CellOffset(2, 0)));
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsNothing);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        var terminalSelection = terminalView.controller!.selection;
        expect(terminalSelection, isNotNull);
        expect(
          trimTerminalSelectionText(
            session.terminal!.buffer.getText(terminalSelection),
          ),
          'alpha',
        );
        final renderTerminal = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        expect(
          trimTerminalSelectionText(
            renderTerminal.getSelectedContent()!.plainText,
          ),
          'alpha',
        );

        session.terminal!.write('\r\ncharlie');
        await tester.pumpAndSettle();
        terminalSelection = terminalView.controller!.selection;
        expect(terminalSelection, isNotNull);
        expect(
          session.terminal!.buffer.getText(terminalSelection),
          isNot(contains('charlie')),
        );

        var streamIndex = 0;
        final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (
          _,
        ) {
          session.terminal!.write('\r\nstream $streamIndex');
          streamIndex += 1;
        });
        addTearDown(streamTimer.cancel);

        renderTerminal.dispatchSelectionEvent(
          SelectWordSelectionEvent(
            globalPosition: cellCenter(const CellOffset(2, 1)),
          ),
        );
        await tester.pumpAndSettle();

        streamTimer.cancel();

        terminalSelection = terminalView.controller!.selection;
        expect(terminalSelection, isNotNull);
        expect(
          trimTerminalSelectionText(
            session.terminal!.buffer.getText(terminalSelection),
          ),
          'charlie',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'system selectable anchors drags that start in terminal whitespace',
      (tester) async {
        await pumpScreen(tester);

        const lineText = 'alpha bravo';
        session.terminal!.write(lineText);
        await tester.pumpAndSettle();

        Offset cellCenter(CellOffset offset) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          return renderTerminal.localToGlobal(
            renderTerminal.getOffset(offset) +
                renderTerminal.cellSize.center(Offset.zero),
          );
        }

        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        const whitespaceCell = CellOffset(lineText.length + 4, 0);
        expect(
          session.terminal!.buffer.getWordBoundary(whitespaceCell),
          isNull,
        );

        renderTerminal
          ..dispatchSelectionEvent(
            SelectWordSelectionEvent(
              globalPosition: cellCenter(whitespaceCell),
            ),
          )
          ..dispatchSelectionEvent(
            SelectionEdgeUpdateEvent.forEnd(
              globalPosition: cellCenter(const CellOffset(0, 0)),
              granularity: TextGranularity.word,
            ),
          );
        await tester.pumpAndSettle();

        expect(renderTerminal.getSelectedContent()?.plainText, lineText);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        expect(
          trimTerminalSelectionText(
            session.terminal!.buffer.getText(
              terminalView.controller!.selection,
            ),
          ),
          lineText,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'overlay scroll stays fixed while a native selection is active',
      (tester) async {
        await pumpScreen(tester);

        final initialLines = List<String>.generate(
          40,
          (index) => index == 39 ? 'alpha' : 'line $index',
        ).join('\r\n');
        session.terminal!.write(initialLines);
        await tester.pumpAndSettle();

        ({CellOffset cellOffset, Offset center})? tokenHit(String token) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          final firstVisibleRow =
              (session.terminal!.buffer.lines.length -
                      session.terminal!.viewHeight)
                  .clamp(0, session.terminal!.buffer.lines.length - 1);

          for (
            var row = firstVisibleRow;
            row < session.terminal!.buffer.lines.length;
            row += 1
          ) {
            final lineText = trimTerminalLinePadding(
              session.terminal!.buffer.lines[row].getText(
                0,
                session.terminal!.buffer.viewWidth,
              ),
            );
            final startColumn = lineText.indexOf(token);
            if (startColumn == -1) {
              continue;
            }

            final tapColumn = startColumn + (token.length ~/ 2);
            final cellOffset = CellOffset(tapColumn, row);
            return (
              cellOffset: cellOffset,
              center: renderTerminal.localToGlobal(
                renderTerminal.getOffset(cellOffset) +
                    renderTerminal.cellSize.center(Offset.zero),
              ),
            );
          }

          return null;
        }

        final alphaHit = tokenHit('alpha');
        expect(alphaHit, isNotNull);

        final renderTerminal = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        renderTerminal.selectWord(
          renderTerminal.getOffset(alphaHit!.cellOffset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsNothing);
        expect(find.byType(SelectionArea), findsOneWidget);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        var terminalSelection = terminalView.controller!.selection;
        expect(terminalSelection, isNotNull);
        final selectedText = trimTerminalSelectionText(
          session.terminal!.buffer.getText(terminalSelection),
        );
        expect(selectedText, 'alpha');

        session.terminal!.write('\r\ncharlie');
        await tester.pumpAndSettle();

        terminalSelection = terminalView.controller!.selection;
        expect(terminalSelection, isNotNull);
        expect(
          session.terminal!.buffer.getText(terminalSelection),
          isNot(contains('charlie')),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'touch press pauses live output auto-scroll before long press resolves',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(430, 932));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        session.terminal!
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        await pumpScreen(tester);

        session.terminal!.write(
          List<String>.generate(
            60,
            (index) => index == 59 ? 'alpha bravo' : 'line $index',
          ).join('\r\n'),
        );
        await tester.pumpAndSettle();

        final scrollableFinder = find.descendant(
          of: find.byType(MonkeyTerminalView),
          matching: find.byType(Scrollable),
        );
        expect(scrollableFinder, findsOneWidget);
        final scrollableState = tester.state<ScrollableState>(scrollableFinder);
        final initialOffset = scrollableState.position.pixels;
        expect(initialOffset, scrollableState.position.maxScrollExtent);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(MonkeyTerminalView)),
        );
        await tester.pump();
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .liveOutputAutoScroll,
          isFalse,
        );
        session.terminal!.write(
          '\r\n${List<String>.generate(20, (index) => 'stream $index').join('\r\n')}',
        );
        await tester.pump();

        expect(scrollableState.position.pixels, initialOffset);

        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          scrollableState.position.pixels,
          scrollableState.position.maxScrollExtent,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'link long press keeps the touched word selected while output streams during the hold',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('visit https://alpha.test');
        await tester.pumpAndSettle();

        ({CellOffset cellOffset, Offset center})? tokenHit(String token) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          final firstVisibleRow =
              (session.terminal!.buffer.lines.length -
                      session.terminal!.viewHeight)
                  .clamp(0, session.terminal!.buffer.lines.length - 1);

          for (
            var row = firstVisibleRow;
            row < session.terminal!.buffer.lines.length;
            row += 1
          ) {
            final lineText = trimTerminalLinePadding(
              session.terminal!.buffer.lines[row].getText(
                0,
                session.terminal!.buffer.viewWidth,
              ),
            );
            final startColumn = lineText.indexOf(token);
            if (startColumn == -1) {
              continue;
            }

            final tapColumn = startColumn + (token.length ~/ 2);
            final cellOffset = CellOffset(tapColumn, row);
            return (
              cellOffset: cellOffset,
              center: renderTerminal.localToGlobal(
                renderTerminal.getOffset(cellOffset) +
                    renderTerminal.cellSize.center(Offset.zero),
              ),
            );
          }

          return null;
        }

        final hit = tokenHit('alpha');
        expect(hit, isNotNull);
        final wordRange = session.terminal!.buffer.getWordBoundary(
          hit!.cellOffset,
        );
        expect(wordRange, isNotNull);
        final expectedWord = session.terminal!.buffer.lines[wordRange!.begin.y]
            .getText(wordRange.begin.x, wordRange.end.x);

        var streamIndex = 0;
        final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (
          _,
        ) {
          session.terminal!.write('\r\nstream $streamIndex');
          streamIndex += 1;
        });
        addTearDown(streamTimer.cancel);

        final renderTerminal = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal;
        renderTerminal.selectWord(
          renderTerminal.getOffset(hit.cellOffset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
        await tester.pumpAndSettle();

        streamTimer.cancel();

        expect(find.byType(TextField), findsNothing);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        expect(
          trimTerminalSelectionText(
            session.terminal!.buffer.getText(
              terminalView.controller!.selection,
            ),
          ),
          expectedWord,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'prompt path underline stays inline while scrolling',
      (tester) async {
        await pumpScreen(tester);

        final output = <String>[
          for (var index = 0; index < 80; index++) 'line $index',
          'metadata rows no longer get folded into the path',
          '~/Code/flutty [⇢main]',
        ].join('\r\n');
        session.terminal!.write(output);
        await tester.pumpAndSettle();

        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.inlineUnderlines, hasLength(1));
        final initialUnderline = terminalView.inlineUnderlines.single;
        final scrollController = terminalView.scrollController;
        final lineHeight = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal
            .lineHeight;
        expect(scrollController, isNotNull);
        expect(scrollController!.position.maxScrollExtent, greaterThan(0));
        scrollController.jumpTo(
          (scrollController.offset - (lineHeight / 2)).clamp(
            0.0,
            scrollController.position.maxScrollExtent,
          ),
        );
        await tester.pump();

        final scrolledTerminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(scrolledTerminalView.inlineUnderlines, [initialUnderline]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'verified relative paths gain an underline after verification completes',
      (tester) async {
        const relativePath = 'lib/presentation/screens/terminal_screen.dart';
        const workingDirectory = '/Users/tester/project';
        final sftp = _MockSftpClient();
        final statCompleter = Completer<SftpFileAttrs>();

        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(
          () => sftp.stat('$workingDirectory/$relativePath'),
        ).thenAnswer((_) => statCompleter.future);

        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(
            utf8.encode(
              '\u001b]7;file://remote.example.com$workingDirectory\u0007',
            ),
          ),
        );
        await tester.pumpAndSettle();

        session.terminal!.write('git add $relativePath');
        await tester.pump();

        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .inlineUnderlines,
          isEmpty,
        );

        statCompleter.complete(
          SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .inlineUnderlines,
          hasLength(1),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'links the longest existing directory when the file is missing',
      (tester) async {
        const missingPath = 'lib/presentation/screens/missing_screen.dart';
        const existingDir = 'lib/presentation/screens';
        const workingDirectory = '/Users/tester/project';
        final sftp = _MockSftpClient();

        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(() => sftp.stat('$workingDirectory/$missingPath')).thenAnswer(
          (_) => Future<SftpFileAttrs>.error(
            SftpStatusError(SftpStatusCode.noSuchFile, 'no such file'),
          ),
        );
        when(() => sftp.stat('$workingDirectory/$existingDir')).thenAnswer(
          (_) async => SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );

        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(
            utf8.encode(
              '\u001b]7;file://remote.example.com$workingDirectory\u0007',
            ),
          ),
        );
        await tester.pumpAndSettle();

        session.terminal!.write('cat $missingPath');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        // The missing file is probed first, then its parent directory, which
        // exists and becomes the linkified substring.
        verify(() => sftp.stat('$workingDirectory/$missingPath')).called(1);
        verify(() => sftp.stat('$workingDirectory/$existingDir')).called(1);
        expect(
          tester
              .widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView))
              .inlineUnderlines,
          hasLength(1),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'path cache evicts oldest stores and retains reinserted paths',
      (tester) async {
        final sftp = _MockSftpClient();
        final calls = <String, int>{};
        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(() => sftp.stat(any())).thenAnswer((invocation) async {
          final path = invocation.positionalArguments.single as String;
          calls.update(path, (count) => count + 1, ifAbsent: () => 1);
          return SftpFileAttrs();
        });
        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b]7;file://remote/project\x07')),
        );
        await tester.pumpAndSettle();
        Future<void> showPath(int index) async {
          session.terminal!.write('\x1b[2J\x1b[Hcat lib/file$index.txt');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump();
        }

        for (var index = 0; index <= 128; index++) {
          await showPath(index);
        }
        expect(calls['/project/lib/file0.txt'], 1);
        await showPath(0);
        expect(calls['/project/lib/file0.txt'], 2);
        await showPath(129);
        await showPath(0);
        expect(calls['/project/lib/file0.txt'], 2);
        await showPath(2);
        expect(calls['/project/lib/file2.txt'], 2);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'path batch stops using its SFTP client after session replacement',
      (tester) async {
        final sftp = _MockSftpClient();
        final stat = Completer<SftpFileAttrs>();
        final activeSessions = _TestActiveSessionsNotifier(session);
        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(
          () => sftp.stat('/project/lib/first.txt'),
        ).thenAnswer((_) => stat.future);
        when(
          () => sftp.stat('/project/lib/second.txt'),
        ).thenAnswer((_) async => SftpFileAttrs());
        await pumpScreen(tester, activeSessions: activeSessions);
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b]7;file://remote/project\x07')),
        );
        await tester.pumpAndSettle();
        session.terminal!.write('cat lib/first.txt lib/second.txt');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        verify(() => sftp.stat('/project/lib/first.txt')).called(1);
        activeSessions.session = SshSession(
          connectionId: session.connectionId,
          hostId: host.id,
          client: _MockSshClient(),
          config: session.config,
        )..getOrCreateTerminal();
        stat.complete(SftpFileAttrs());
        await tester.pump();
        verifyNever(() => sftp.stat('/project/lib/second.txt'));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    for (final pendingHome in [false, true]) {
      testWidgets(
        'path verification discards a directory change during ${pendingHome ? 'home lookup' : 'stat'}',
        (tester) async {
          final sftp = _MockSftpClient();
          final home = Completer<String>();
          final stat = Completer<SftpFileAttrs>();
          const oldDirectory = '/old/project';
          const newDirectory = '/new/project';
          final terminalPath = pendingHome ? '~/notes.txt' : 'lib/notes.txt';
          final statPaths = <String>[];
          var homeCalls = 0;
          when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
          when(() => sftp.absolute('.')).thenAnswer((_) {
            homeCalls++;
            return homeCalls == 1 ? home.future : Future.value('/new/home');
          });
          when(() => sftp.stat(any())).thenAnswer((invocation) {
            final path = invocation.positionalArguments.single as String;
            statPaths.add(path);
            return path.startsWith(oldDirectory)
                ? stat.future
                : Future.value(SftpFileAttrs());
          });
          await pumpScreen(tester);
          shellStdoutController.add(
            Uint8List.fromList(
              utf8.encode('\x1b]7;file://remote$oldDirectory\x07'),
            ),
          );
          await tester.pumpAndSettle();
          session.terminal!.write('cat $terminalPath');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 75));
          expect(pendingHome ? homeCalls : statPaths.length, 1);
          shellStdoutController.add(
            Uint8List.fromList(
              utf8.encode('\x1b]7;file://remote$newDirectory\x07'),
            ),
          );
          await tester.pump();
          if (pendingHome) {
            home.complete('/old/home');
          } else {
            stat.complete(SftpFileAttrs());
          }
          await tester.pumpAndSettle();
          expect(statPaths, isNot(contains('/old/home/notes.txt')));
          session.terminal!.write('\r\ncat $terminalPath');
          await tester.pumpAndSettle();
          expect(
            statPaths,
            contains(
              pendingHome
                  ? '/new/home/notes.txt'
                  : '$newDirectory/lib/notes.txt',
            ),
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    for (final overflow in [false, true]) {
      testWidgets(
        'background path verification batches relative path stats with overflow $overflow',
        (tester) async {
          const firstPath = 'lib/presentation/screens/terminal_screen.dart';
          const secondPath = 'lib/domain/services/tmux_service.dart';
          const workingDirectory = '/Users/tester/project';
          final sftp = _MockSftpClient();
          final firstStatStarted = Completer<void>();
          final firstStatCompleter = Completer<SftpFileAttrs>();
          var secondStatCalls = 0;
          final recentStats = <String>[];
          when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
          when(() => sftp.stat(any())).thenAnswer((call) {
            final path = call.positionalArguments.single as String;
            if (path == '$workingDirectory/$firstPath') {
              if (!firstStatStarted.isCompleted) firstStatStarted.complete();
              return firstStatCompleter.future;
            }
            if (path == '$workingDirectory/$secondPath') {
              secondStatCalls++;
            } else {
              recentStats.add(path);
            }
            return Future.value(SftpFileAttrs());
          });
          await pumpScreen(tester);
          shellStdoutController.add(
            Uint8List.fromList(
              utf8.encode(
                '\u001b]7;file://remote.example.com$workingDirectory\u0007',
              ),
            ),
          );
          await tester.pumpAndSettle();
          session.terminal!.write('git add $firstPath $secondPath');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 75));
          await firstStatStarted.future.timeout(const Duration(seconds: 1));
          expect(secondStatCalls, 0);
          if (overflow) {
            for (var index = 0; index < 160; index++) {
              session.terminal!.write('\x1b[2J\x1b[Hcat lib/recent$index.txt');
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(recentStats, isEmpty);
          }
          firstStatCompleter.complete(SftpFileAttrs());
          await tester.pumpAndSettle();
          verify(() => sftp.stat('$workingDirectory/$firstPath')).called(1);
          if (overflow) {
            expect(secondStatCalls, 0);
            expect(recentStats, hasLength(128));
            expect(recentStats.first, '$workingDirectory/lib/recent32.txt');
            expect(recentStats.last, '$workingDirectory/lib/recent159.txt');
            return;
          }
          verify(() => sshClient.sftp()).called(1);
          verify(() => sftp.stat('$workingDirectory/$secondPath')).called(1);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    for (final failure in [
      'synchronous open',
      'asynchronous open',
      'recoverable open',
      'recoverable stat',
    ]) {
      testWidgets(
        'background path verification stops retrying after $failure failure',
        (tester) async {
          final sftp = _MockSftpClient();
          var openCalls = 0;
          var statCalls = 0;
          when(() => sshClient.sftp()).thenAnswer((_) {
            openCalls++;
            if (failure == 'synchronous open') {
              throw StateError('SFTP unavailable');
            }
            if (failure != 'recoverable stat') {
              return Future.error(
                failure == 'asynchronous open'
                    ? StateError('SFTP unavailable')
                    : SSHStateError('SFTP unavailable'),
              );
            }
            return Future.value(sftp);
          });
          when(() => sftp.stat(any())).thenAnswer((_) {
            statCalls++;
            return Future.error(SSHStateError('SFTP unavailable'));
          });
          await pumpScreen(tester);
          shellStdoutController.add(
            Uint8List.fromList(utf8.encode('\x1b]7;file://remote/project\x07')),
          );
          await tester.pumpAndSettle();
          final timers = <Timer>[];
          await runZoned(
            () async {
              session.terminal!.write('cat lib/first.txt lib/second.txt');
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 75));
              expect(openCalls, 1);
              expect(statCalls, failure == 'recoverable stat' ? 1 : 0);
              for (var tick = 0; tick < 4; tick++) {
                await tester.pump(const Duration(seconds: 11));
              }
              expect(openCalls, 1);
              expect(statCalls, failure == 'recoverable stat' ? 1 : 0);
              expect(
                timers.where((timer) => timer.isActive),
                isEmpty,
                // Fake time does not advance DateTime.now-based backoff.
                reason: 'Idle verification must leave no retry timer pending',
              );
            },
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
                final timer = parent.createTimer(zone, duration, callback);
                timers.add(timer);
                return timer;
              },
            ),
          );
          if (!failure.startsWith('recoverable')) {
            // New output must retry paths whose batch failed.
            final recoveredPaths = <String>[];
            when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
            when(() => sftp.stat(any())).thenAnswer((invocation) async {
              recoveredPaths.add(
                invocation.positionalArguments.single as String,
              );
              return SftpFileAttrs();
            });
            // Separate commands so continuation detection cannot join the
            // previous path with the next command's name.
            session.terminal!.write('\r\n\r\ncat lib/first.txt lib/second.txt');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 75));
            expect(recoveredPaths, [
              '/project/lib/first.txt',
              '/project/lib/second.txt',
            ]);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    testWidgets(
      'background path verification preserves replacement after open timeout',
      (tester) async {
        const relativePath = 'lib/presentation/screens/terminal_screen.dart';
        const workingDirectory = '/Users/tester/project';
        final sftp = _MockSftpClient();
        final sftpOpenCompleter = Completer<SftpClient>();

        when(
          () => sshClient.sftp(),
        ).thenAnswer((_) => sftpOpenCompleter.future);

        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(
            utf8.encode(
              '\u001b]7;file://remote.example.com$workingDirectory\u0007',
            ),
          ),
        );
        await tester.pumpAndSettle();

        session.terminal!.write('git add $relativePath');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        verify(() => sshClient.sftp()).called(1);

        await tester.pump(const Duration(seconds: 5, milliseconds: 1));
        verifyNever(sftp.close);

        // The real terminal timeout handler must release the pending open
        // immediately, so another consumer can recover before it finishes.
        final replacement = _MockSftpClient();
        when(() => sshClient.sftp()).thenAnswer((_) async => replacement);
        final next = session.sftp();
        await tester.pump();
        verify(() => sshClient.sftp()).called(1);
        expect(await next, same(replacement));

        sftpOpenCompleter.complete(sftp);
        await tester.pump();

        verify(sftp.close).called(1);
        verifyNever(replacement.close);
        expect(await session.sftp(), same(replacement));
        verifyNever(() => sshClient.sftp());

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'background path verification discards cached SFTP clients after stat timeout',
      (tester) async {
        const relativePath = 'lib/presentation/screens/terminal_screen.dart';
        const workingDirectory = '/Users/tester/project';
        final sftp = _MockSftpClient();
        final statStarted = Completer<void>();
        final statCompleter = Completer<SftpFileAttrs>();

        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(() => sftp.stat('$workingDirectory/$relativePath')).thenAnswer((
          _,
        ) {
          if (!statStarted.isCompleted) {
            statStarted.complete();
          }
          return statCompleter.future;
        });

        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(
            utf8.encode(
              '\u001b]7;file://remote.example.com$workingDirectory\u0007',
            ),
          ),
        );
        await tester.pumpAndSettle();

        session.terminal!.write('git add $relativePath');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        await statStarted.future.timeout(const Duration(seconds: 1));

        await tester.pump(const Duration(seconds: 5, milliseconds: 1));

        verify(sftp.close).called(1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'mobile path underline taps open SFTP while system selection is enabled',
      (tester) async {
        const remotePath = '/var/log/app.log';
        final sftp = _MockSftpClient();
        final openedPaths = <String>[];

        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(
          () => sftp.stat(remotePath),
        ).thenAnswer((_) async => SftpFileAttrs());

        final router = GoRouter(
          initialLocation:
              '/terminal/${host.id}?connectionId=${session.connectionId}',
          routes: [
            GoRoute(
              path: '/terminal/:hostId',
              name: Routes.terminal,
              builder: (context, state) => TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
              ),
            ),
            GoRoute(
              path: '/sftp/:hostId',
              name: Routes.sftp,
              builder: (context, state) {
                openedPaths.add(state.uri.queryParameters['path'] ?? '');
                return const Scaffold(body: Text('SFTP opened'));
              },
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          buildScreen(child: MaterialApp.router(routerConfig: router)),
        );
        await tester.pump();
        await tester.pump();

        session.terminal!.write('open $remotePath');
        await tester.pumpAndSettle();

        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.inlineUnderlines, hasLength(1));
        expect(find.byType(SelectionArea), findsOneWidget);

        final terminalState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final underline = terminalView.inlineUnderlines.single;
        final tapPosition = terminalState.renderTerminal.localToGlobal(
          terminalState.renderTerminal.getOffset(
                CellOffset(underline.startColumn, underline.row),
              ) +
              terminalState.renderTerminal.cellSize.center(Offset.zero),
        );

        final cancelledTap = await tester.startGesture(tapPosition);
        await cancelledTap.cancel();
        await tester.pumpAndSettle();
        expect(openedPaths, isEmpty);

        await tester.tapAt(tapPosition);
        await tester.pumpAndSettle();

        expect(openedPaths, [remotePath]);
        verify(() => sftp.stat(remotePath)).called(1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'keyboard and extra-key controls remain visible in native mode',
      (tester) async {
        session.activeNativeAcpSessionKey = AcpSessionKey.of(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.pi,
          bridgeId: 'native-bridge',
          acpSessionId: 'native-session',
        );
        addTearDown(() => session.activeNativeAcpSessionKey = null);

        await pumpScreen(tester);

        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byTooltip('Hide extra keys'), findsOneWidget);
        expect(find.byType(KeyboardToolbar), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-active')),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byTooltip('Hide extra keys'));
        await tester.pump();
        expect(find.byTooltip('Show extra keys'), findsOneWidget);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byType(KeyboardToolbar), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'native mode ignores a stale inset when the platform IME is closed',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 500);
        final keyboard = SystemKeyboardVisibilityController.instance
          ..debugSetVisible(visible: false);
        final key = AcpSessionKey.of(
          hostId: host.id,
          providerId: AcpBuiltinProviderIds.pi,
          bridgeId: 'native-bridge',
          acpSessionId: 'native-session',
        );
        final acpManager = FakeAcpSessionManager(
          sessions: [fakeAcpSession(key: key, providerLabel: 'Pi')],
        );
        addTearDown(acpManager.dispose);
        session.activeNativeAcpSessionKey = key;
        addTearDown(() {
          keyboard.debugSetVisible(visible: null);
          session.activeNativeAcpSessionKey = null;
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });

        await pumpScreen(tester, acpSessionManager: acpManager);

        // Android may keep reporting the old inset after predictive/system Back.
        // Native WindowInsets visibility must still collapse the layout.
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byTooltip('Hide system keyboard'), findsNothing);
        expect(tester.getBottomLeft(find.byType(KeyboardToolbar)).dy, 844);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'extra keys toggle uses distinct copy',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byTooltip('Hide extra keys'), findsOneWidget);
        expect(find.byType(KeyboardToolbar), findsOneWidget);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-active')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.text('Fn'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-inactive')),
          ),
          findsNothing,
        );
        expect(find.byIcon(Icons.keyboard_alt_outlined), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_outlined), findsNothing);

        await tester.tap(find.byTooltip('Hide extra keys'));
        await tester.pump();

        expect(find.byTooltip('Show extra keys'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-inactive')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.text('Fn'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-active')),
          ),
          findsNothing,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}
