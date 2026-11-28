// Shared UI/presentation test fixtures and lightweight fakes.

import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';
import 'package:monkeyssh/presentation/screens/sftp_browser_view.dart';

import 'mocks.dart';

/// Default free-tier [MonetizationState] for widget/presentation tests.
const freeMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

/// Default Pro-tier [MonetizationState] for widget/presentation tests.
const proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

/// Creates a [MockMonetizationService] stubbed with [state].
MockMonetizationService createMockMonetizationService({
  MonetizationState state = freeMonetizationState,
}) {
  final service = MockMonetizationService();
  when(() => service.currentState).thenReturn(state);
  return service;
}

/// [MockSshClient] with a no-op [close] override so `SshSession.close()` works
/// without explicit stubbing.
class ClosableMockSshClient extends MockSshClient {
  @override
  Future<void> close() async {}
}

/// Configurable [ActiveSessionsNotifier] for widget tests that need zero, one,
/// or more active sessions without touching real SSH sockets.
class TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  /// Creates a notifier pre-populated with [sessions] (or empty by default).
  TestActiveSessionsNotifier({
    List<SshSession> sessions = const <SshSession>[],
    Map<int, SshConnectionState>? states,
  }) : _sessions = {
         for (final session in sessions) session.connectionId: session,
       },
       _initialStates = states;

  final Map<int, SshSession> _sessions;
  final Map<int, SshConnectionState>? _initialStates;

  @override
  Map<int, SshConnectionState> build() =>
      _initialStates ??
      <int, SshConnectionState>{
        for (final id in _sessions.keys) id: SshConnectionState.connected,
      };

  @override
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  @override
  Future<void> syncBackgroundStatus() async {}
}

/// In-memory [SftpBrowserViewStore] for SFTP widget tests, with an optional
/// [filterReadGate] to pause filter restoration.
class MemorySftpBrowserViewStore implements SftpBrowserViewStore {
  /// Saved per-host browser view settings.
  final saved = <int, SftpBrowserViewSettings>{};

  /// Saved per-host filter states.
  final filters = <int, SftpBrowserFilter>{};

  /// Optional gate pausing [loadFilter] until completed.
  Completer<void>? filterReadGate;

  @override
  Future<SftpBrowserViewSettings> load(int hostId) async =>
      saved[hostId] ?? const SftpBrowserViewSettings();

  @override
  Future<void> save(int hostId, SftpBrowserViewSettings settings) async {
    saved[hostId] = settings;
  }

  @override
  Future<SftpBrowserFilter?> loadFilter(int hostId) async {
    final savedFilter = filters[hostId];
    await filterReadGate?.future;
    return savedFilter;
  }

  @override
  Future<void> saveFilter(int hostId, SftpBrowserFilter? filter) async {
    if (filter == null) {
      filters.remove(hostId);
    } else {
      filters[hostId] = filter;
    }
  }
}

/// No-op [TransferIntentService] for home screen widget tests.
class NoopTransferIntentService extends TransferIntentService {
  @override
  Stream<String> get incomingPayloads => const Stream<String>.empty();

  @override
  Future<String?> consumeIncomingTransferPayload() async => null;

  @override
  Future<void> dispose() async {}
}

/// No-op [HomeScreenShortcutService] for home screen widget tests.
class NoopHomeScreenShortcutService extends HomeScreenShortcutService {
  @override
  Stream<int> get hostLaunches => const Stream<int>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> updateShortcuts({
    required List<Host> hosts,
    required Set<int> pinnedHostIds,
  }) async {}

  @override
  Future<void> dispose() async {}
}

/// Builds a [Host] fixture with sensible defaults for all required columns.
Host testHost({
  int id = 1,
  String label = 'Alpha',
  String hostname = 'alpha.example.com',
  int port = 22,
  String username = 'root',
  String? password,
  int? keyId,
  int? groupId,
  int? jumpHostId,
  String? skipJumpHostOnSsids,
  bool isFavorite = false,
  String? color,
  String? notes,
  String? tags,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? lastConnectedAt,
  String? terminalThemeLightId,
  String? terminalThemeDarkId,
  String? terminalFontFamily,
  String? autoConnectCommand,
  int? autoConnectSnippetId,
  bool autoConnectRequiresConfirmation = false,
  String? tmuxSessionName,
  String? tmuxWorkingDirectory,
  String? tmuxExtraFlags,
  String? remoteMuxBackend,
  bool autoForwardPorts = false,
  String? portProxyName,
  int sortOrder = 0,
  bool notifyAgentAttention = true,
  bool notifyAgentFinished = true,
  bool notifyWindowAlerts = true,
  bool notifyShellNotifications = true,
  bool pushWhenClosed = true,
}) {
  final timestamp = createdAt ?? DateTime(2026);
  return Host(
    id: id,
    label: label,
    hostname: hostname,
    port: port,
    username: username,
    password: password,
    keyId: keyId,
    groupId: groupId,
    jumpHostId: jumpHostId,
    skipJumpHostOnSsids: skipJumpHostOnSsids,
    isFavorite: isFavorite,
    color: color,
    notes: notes,
    tags: tags,
    createdAt: timestamp,
    updatedAt: updatedAt ?? timestamp,
    lastConnectedAt: lastConnectedAt,
    terminalThemeLightId: terminalThemeLightId,
    terminalThemeDarkId: terminalThemeDarkId,
    terminalFontFamily: terminalFontFamily,
    autoConnectCommand: autoConnectCommand,
    autoConnectSnippetId: autoConnectSnippetId,
    autoConnectRequiresConfirmation: autoConnectRequiresConfirmation,
    tmuxSessionName: tmuxSessionName,
    tmuxWorkingDirectory: tmuxWorkingDirectory,
    tmuxExtraFlags: tmuxExtraFlags,
    remoteMuxBackend: remoteMuxBackend,
    autoForwardPorts: autoForwardPorts,
    portProxyName: portProxyName,
    sortOrder: sortOrder,
    notifyAgentAttention: notifyAgentAttention,
    notifyAgentFinished: notifyAgentFinished,
    notifyWindowAlerts: notifyWindowAlerts,
    notifyShellNotifications: notifyShellNotifications,
    pushWhenClosed: pushWhenClosed,
  );
}
