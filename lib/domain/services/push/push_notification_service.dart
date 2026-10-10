import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/host_repository.dart';
import '../../models/acp_session_state.dart';
import '../../models/remote_multiplexer.dart';
import '../acp_session_manager.dart';
import '../diagnostics_log_service.dart';
import '../monkeymux_service.dart';
import '../serial_task_queue.dart';
import '../settings_service.dart';
import '../ssh_exec_queue.dart';
import '../ssh_service.dart';
import '../telemetry_service.dart';
import 'push_crypto.dart';
import 'push_device_store.dart';
import 'push_event.dart';
import 'push_local_alerts.dart';
import 'push_messaging_gateway.dart';

/// Android channel for closed-app events that wait on the user (approvals,
/// questions). The Firebase Function names the same id.
const pushAgentAttentionChannelId = 'agent-attention';

/// Quiet Android channel for routine closed-app events (finished turns,
/// window alerts). The Firebase Function names the same id.
const pushAgentUpdatesChannelId = 'agent-updates';

/// How often the app refreshes its presence with hosts. MonkeyMux treats a
/// report older than 45 seconds as stale.
const pushPresenceHeartbeatInterval = Duration(seconds: 20);

/// Tickets older than this are renewed. The Firebase Function refuses
/// tickets older than 90 days.
const pushTicketRefreshAge = Duration(days: 7);

/// First retry delay for a failed ticket renewal or token deletion; it doubles
/// on each failure up to [pushRegistrationRetryMax].
const pushRegistrationRetryInterval = Duration(minutes: 1);

/// Longest delay between retries of a failed ticket renewal. Each renewal
/// spends an App Check attestation, so a long outage must not burn quota.
const pushRegistrationRetryMax = Duration(hours: 1);

/// How long before a host that lacked push support is asked again, in case
/// its MonkeyMux was updated on the same connection.
const pushUnsupportedRetryInterval = Duration(minutes: 10);

const _enabledSettingKey = 'push_notifications_enabled';
const _disabledHostsSettingKey = 'push_notifications_disabled_hosts';
const _registeredHostsSettingKey = 'push_notifications_registered_hosts';
const _pendingUnregisterSettingKey = 'push_notifications_pending_unregister';
const _tokenDeletePendingKey = 'push_notifications_token_delete_pending';
const _optOutPendingKey = 'push_notifications_opt_out_pending';
const _autoInitDisablePendingKey =
    'push_notifications_auto_init_disable_pending';
const _diagnosticsCategory = 'push';

/// Whether this run can offer push notifications: a Firebase build on iOS or
/// Android whose Firebase app initialized.
final pushNotificationsAvailableProvider = Provider<bool>(
  (ref) =>
      ref.watch(telemetryServiceProvider).status ==
      TelemetryServiceStatus.ready,
);

/// Firebase Messaging, App Check and the registration callable.
final pushMessagingGatewayProvider = Provider<PushMessagingGateway>(
  (ref) => FirebasePushMessagingGateway(),
);

/// Secure storage for the device key and registration.
final pushDeviceStoreProvider = Provider<PushDeviceStore>(
  (ref) => PushDeviceStore(),
);

/// Creates the Android notification channel FCM posts into.
final pushNotificationChannelInstallerProvider =
    Provider<Future<void> Function()>((ref) => _installAgentAttentionChannel);

/// The clock push bookkeeping uses; replaced in tests.
final pushClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Whether a backgrounded app can keep raising its own notifications. Only
/// Android's background service keeps the app running; iOS suspends it.
final pushLocalPresenceSupportedProvider = Provider<bool>(
  (ref) => defaultTargetPlatform == TargetPlatform.android,
);

/// Whether a window bar, which raises local window alerts, is mounted for a
/// connection.
final pushLocalAlertListenerProvider = Provider<bool Function(int)>(
  (ref) => pushLocalAlertListeners.contains,
);

/// The native agent bridges on a host whose events the app is receiving, and
/// so raises local notifications for while backgrounded.
final pushLocalBridgesProvider = Provider<List<String> Function(int)>((ref) {
  final manager = ref.watch(acpSessionManagerProvider);
  return (hostId) => [
    for (final session in manager.state.sessions)
      if (session.key.hostId == hostId &&
          session.status == AcpConnectionStatus.ready)
        session.key.bridgeId,
  ];
});

/// Lists the saved host ids, used to resolve host references.
final pushHostIdsProvider = Provider<Future<List<int>> Function()>((ref) {
  final repository = ref.watch(hostRepositoryProvider);
  return () async => [for (final host in await repository.getAll()) host.id];
});

/// Lists the live MonkeyMux attachments push can reach right now.
final pushHostLinksProvider = Provider<List<PushHostLink> Function()>((ref) {
  final sshService = ref.watch(sshServiceProvider);
  final monkeyMux = ref.watch(monkeyMuxServiceProvider);
  return () => [
    for (final session in sshService.allSessions)
      if (session.remoteMuxBackend == RemoteMuxBackend.monkeyMux &&
          (session.remoteMuxSessionName?.trim().isNotEmpty ?? false) &&
          !isAppReviewDemoSession(session))
        _SshPushHostLink(session, monkeyMux),
  ];
});

Future<void> _installAgentAttentionChannel() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        pushAgentAttentionChannelId,
        'Agent attention',
        description:
            'Agents waiting for you while MonkeySSH is closed: approvals and '
            'questions.',
        importance: Importance.high,
      ),
    );
    // Channels decide sound and heads-up display on Android 8 and later.
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        pushAgentUpdatesChannelId,
        'Agent updates',
        description:
            'Finished agent turns and terminal alerts while MonkeySSH is '
            'closed.',
        importance: Importance.low,
      ),
    );
  } on MissingPluginException {
    // Tests run without platform plugins.
  }
}

/// One live MonkeyMux attachment the app can send push operations to.
abstract interface class PushHostLink {
  /// The SSH connection.
  int get connectionId;

  /// The saved host.
  int get hostId;

  /// The attached MonkeyMux session.
  String get sessionName;

  /// The attach client id MonkeyMux knows this connection by.
  String get clientId;

  /// The window the terminal UI last published as active.
  String? get activeWindowId;

  /// Sends a push control operation.
  Future<MonkeyMuxPushControlResult> send(
    Map<String, Object?> command, {
    bool lowPriority = false,
  });
}

class _SshPushHostLink implements PushHostLink {
  _SshPushHostLink(this._session, this._monkeyMux);

  final SshSession _session;
  final MonkeyMuxService _monkeyMux;

  @override
  int get connectionId => _session.connectionId;

  @override
  int get hostId => _session.hostId;

  @override
  String get sessionName => _session.remoteMuxSessionName!.trim();

  @override
  String get clientId => _session.monkeyMuxClientId;

  @override
  String? get activeWindowId => _session.activeMuxWindowId;

  @override
  Future<MonkeyMuxPushControlResult> send(
    Map<String, Object?> command, {
    bool lowPriority = false,
  }) => _monkeyMux.runPushControl(
    _session,
    sessionName,
    command,
    priority: lowPriority ? SshExecPriority.low : SshExecPriority.normal,
  );
}

/// Outcome of "Send test notification".
enum PushTestOutcome {
  /// The function accepted the test; it should arrive shortly.
  sent,

  /// No host is connected through MonkeyMux.
  noConnectedHost,

  /// Hosts are connected, but push is off for each of them.
  noEnabledHost,

  /// The connected host's MonkeyMux predates push support.
  hostNeedsUpdate,

  /// The device is rate limited or over its hourly cap.
  rateLimited,

  /// The registration was rejected; turning push off and on fixes it.
  registrationRejected,

  /// Anything else.
  failed,
}

/// Push notification settings and status.
@immutable
class PushNotificationState {
  /// Creates the state.
  const PushNotificationState({
    this.available = false,
    this.loaded = false,
    this.enabled = false,
    this.busy = false,
    this.disabledHostIds = const <int>{},
    this.registeredHostIds = const <int>{},
    this.failure,
  });

  /// Whether this build and platform support the feature.
  final bool available;

  /// Whether persisted settings have been read.
  final bool loaded;

  /// Whether the user opted in and the device is registered.
  final bool enabled;

  /// Whether an opt-in, opt-out or host change is running.
  final bool busy;

  /// Hosts the user turned push off for.
  final Set<int> disabledHostIds;

  /// Hosts that have accepted this device's registration.
  final Set<int> registeredHostIds;

  /// Why the last opt-in failed, if it did.
  final PushSetupFailure? failure;

  /// Returns a copy with the given fields replaced.
  PushNotificationState copyWith({
    bool? loaded,
    bool? enabled,
    bool? busy,
    Set<int>? disabledHostIds,
    Set<int>? registeredHostIds,
    PushSetupFailure? failure,
    bool clearFailure = false,
  }) => PushNotificationState(
    available: available,
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    busy: busy ?? this.busy,
    disabledHostIds: disabledHostIds ?? this.disabledHostIds,
    registeredHostIds: registeredHostIds ?? this.registeredHostIds,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

typedef _LinkKey = ({int connectionId, String sessionName});

/// What a link last told its host about this device.
enum _Presence { idle, viewing, local }

/// Owns opt-in, registration with hosts, presence and message decoding.
class PushNotificationController extends Notifier<PushNotificationState> {
  late SettingsService _settings;
  late PushDeviceStore _store;
  late PushMessagingGateway _gateway;
  late DiagnosticsLogger _log;
  late TelemetryService _telemetry;
  late List<PushHostLink> Function() _links;
  late Future<List<int>> Function() _hostIds;
  late Future<void> Function() _installChannel;
  late DateTime Function() _now;
  late bool _localPresenceSupported;
  late bool Function(int) _hasAlertListener;
  late List<String> Function(int) _localBridges;

  PushDeviceSecrets? _secrets;
  final _registered = <_LinkKey, String>{};
  final _lastPresence = <_LinkKey, _Presence>{};
  final _unsupported = <_LinkKey, DateTime>{};
  Set<int> _registeredHostIds = <int>{};
  Map<int, Set<String>> _pendingUnregister = <int, Set<String>>{};
  final _operations = SerialTaskQueue();
  Future<void>? _syncFuture;
  bool _syncQueued = false;
  bool _optingOut = false;
  bool _foreground = true;
  int? _viewedHostId;
  int? _viewedConnectionId;
  Timer? _heartbeat;
  StreamSubscription<String>? _tokenRefresh;
  bool _disposed = false;
  bool _refreshNeeded = false;
  // A ticket a host reported as refused; it is not offered again.
  String? _refusedTicket;
  bool _refreshNeedsNewToken = false;
  bool _refreshRunning = false;
  DateTime? _lastRefreshAttempt;
  int _refreshFailures = 0;
  bool _tokenDeletePending = false;
  bool _autoInitDisablePending = false;
  DateTime? _lastTokenDeleteAttempt;
  // Whether FCM issued a token this run or a previous one; a deletion only
  // makes sense then (iOS cannot delete before its first check-in).
  bool _tokenIssued = false;

  @override
  PushNotificationState build() {
    final available = ref.watch(pushNotificationsAvailableProvider);
    _settings = ref.watch(settingsServiceProvider);
    _store = ref.watch(pushDeviceStoreProvider);
    _gateway = ref.watch(pushMessagingGatewayProvider);
    _log = ref.watch(diagnosticsLoggerProvider);
    _telemetry = ref.watch(telemetryServiceProvider);
    _links = ref.watch(pushHostLinksProvider);
    _hostIds = ref.watch(pushHostIdsProvider);
    _installChannel = ref.watch(pushNotificationChannelInstallerProvider);
    _now = ref.watch(pushClockProvider);
    _localPresenceSupported = ref.watch(pushLocalPresenceSupportedProvider);
    _hasAlertListener = ref.watch(pushLocalAlertListenerProvider);
    _localBridges = ref.watch(pushLocalBridgesProvider);
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _heartbeat?.cancel();
      unawaited(_tokenRefresh?.cancel());
    });
    if (available) {
      Future.microtask(_load);
    }
    return PushNotificationState(available: available);
  }

  Future<PushDeviceSecrets?> _loadSecrets() async {
    try {
      return await _store.load();
    } on Object catch (error) {
      // A keychain or keystore failure reads as "not registered" rather than
      // leaving settings stuck loading.
      _log.warning(
        _diagnosticsCategory,
        'secrets_unreadable',
        fields: {'errorType': error.runtimeType},
      );
      return null;
    }
  }

  Future<void> _load() async {
    if (_disposed) return;
    final enabled = await _settings.getBool(_enabledSettingKey);
    final disabledHosts = _decodeIds(
      await _settings.getString(_disabledHostsSettingKey),
    );
    _registeredHostIds = _decodeIds(
      await _settings.getString(_registeredHostsSettingKey),
    );
    _pendingUnregister = _decodePending(
      await _settings.getString(_pendingUnregisterSettingKey),
    );
    _tokenDeletePending = await _settings.getBool(_tokenDeletePendingKey);
    _autoInitDisablePending = await _settings.getBool(
      _autoInitDisablePendingKey,
    );
    final prunedHosts = await _pruneDeletedHosts(disabledHosts);
    if (!enabled && await _settings.getBool(_optOutPendingKey)) {
      await _finishInterruptedOptOut();
    }
    var registered = false;
    if (enabled) {
      _secrets = await _loadSecrets();
      registered = _secrets?.isRegistered ?? false;
      if (registered) {
        _tokenIssued = true;
        _listenForTokenRefresh();
        // Recreates the channel if the user cleared it in system settings.
        unawaited(_installChannel());
      }
    }
    if (_disposed) return;
    state = state.copyWith(
      loaded: true,
      enabled: registered,
      disabledHostIds: prunedHosts,
      registeredHostIds: Set.unmodifiable(_registeredHostIds),
    );
    if (registered) {
      // A token that rotated while the app was not running never reaches
      // onTokenRefresh, so compare the current token at every start.
      unawaited(_reconcileRegistration());
    }
    _restartHeartbeat();
    scheduleSync();
  }

  /// Completes an opt-out the app was killed in the middle of: every host
  /// that held the registration is unregistered on its next attach, the
  /// token is retired and the device key deleted.
  Future<void> _finishInterruptedOptOut() async {
    final deviceId = (await _loadSecrets())?.deviceId;
    if (deviceId != null) {
      for (final hostId in _registeredHostIds) {
        _pendingUnregister.putIfAbsent(hostId, () => <String>{}).add(deviceId);
      }
    }
    _registeredHostIds = <int>{};
    await _persistHostBookkeeping();
    // The interrupted opt-out had a registered token.
    _tokenIssued = true;
    await _retireToken();
    try {
      await _store.clear();
    } on Object catch (error) {
      _log.warning(
        _diagnosticsCategory,
        'secrets_clear_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    await _settings.setBool(_optOutPendingKey, value: false);
    _log.info(
      _diagnosticsCategory,
      'opt_out_resumed',
      fields: {'pendingHosts': _pendingUnregister.length},
    );
  }

  /// Turns closed-app notifications on: permission, FCM token, device key,
  /// registration with the function, then registration with live hosts.
  Future<PushSetupFailure?> enable() => _operations.run(() async {
    if (!state.available || state.enabled) return null;
    state = state.copyWith(busy: true, clearFailure: true);
    // A deletion left over from an earlier opt-out must not remove the token
    // this opt-in is about to register.
    if (_tokenDeletePending || _autoInitDisablePending) {
      _tokenDeletePending = false;
      _autoInitDisablePending = false;
      await _settings.setBool(_tokenDeletePendingKey, value: false);
      await _settings.setBool(_autoInitDisablePendingKey, value: false);
    }
    // An opt-out finished at start; nothing left to resume.
    await _settings.setBool(_optOutPendingKey, value: false);
    try {
      if (!await _gateway.requestPermission()) {
        throw const PushSetupException(PushSetupFailure.permissionDenied);
      }
      await _gateway.setAutoInitEnabled(enabled: true);
      final token = await _currentToken();
      await _registerToken(token);
      await _installChannel();
      await _settings.setBool(_enabledSettingKey, value: true);
      _listenForTokenRefresh();
      state = state.copyWith(enabled: true, busy: false);
      _log.info(_diagnosticsCategory, 'opt_in');
      unawaited(_telemetry.logPushNotificationsToggled(enabled: true));
      _restartHeartbeat();
      scheduleSync();
      return null;
    } on PushSetupException catch (error) {
      await _discardLocalRegistration();
      _log.warning(
        _diagnosticsCategory,
        'opt_in_failed',
        fields: {'failure': error.failure.name},
      );
      state = state.copyWith(busy: false, failure: error.failure);
      return error.failure;
    } on Object catch (error) {
      await _discardLocalRegistration();
      _log.warning(
        _diagnosticsCategory,
        'opt_in_failed',
        fields: {'errorType': error.runtimeType},
      );
      state = state.copyWith(
        busy: false,
        failure: PushSetupFailure.registrationFailed,
      );
      return PushSetupFailure.registrationFailed;
    }
  });

  Future<String> _currentToken() async {
    final String? token;
    try {
      token = await _gateway.getToken();
    } on PushSetupException {
      rethrow;
    } on Object {
      // APNs registration failures surface here on iOS.
      throw const PushSetupException(PushSetupFailure.tokenUnavailable);
    }
    if (token == null || token.isEmpty) {
      throw const PushSetupException(PushSetupFailure.tokenUnavailable);
    }
    _tokenIssued = true;
    return token;
  }

  Future<void> _registerToken(String token) async {
    final secrets = await _store.loadOrCreate();
    final registration = await _gateway.register(
      token: token,
      platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      deviceId: secrets.deviceId,
    );
    final next = secrets.withRegistration(
      deviceId: registration.deviceId,
      ticket: registration.ticket,
      tokenFingerprint: _fingerprint(token),
      ticketIssuedAt: _now(),
    );
    await _store.save(next);
    _secrets = next;
  }

  /// Turns FCM auto-init off and deletes the token. Each step runs on its
  /// own; a deletion that fails (offline, say) is retried later.
  /// Turns FCM auto-init off and deletes the token. Each step that fails is
  /// persisted and retried on its own, because auto-init left on would mint
  /// a replacement token.
  Future<void> _retireToken() async {
    _lastTokenDeleteAttempt = _now();
    var autoInitOff = true;
    try {
      await _gateway.setAutoInitEnabled(enabled: false);
    } on Object catch (error) {
      autoInitOff = false;
      _log.warning(
        _diagnosticsCategory,
        'auto_init_disable_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    // Without a token there is nothing to delete, and on iOS the call fails
    // until FCM has checked in, so it would be retried forever. A pending
    // deletion means a token existed when it was scheduled.
    var tokenGone = true;
    if (_tokenIssued || _tokenDeletePending) {
      try {
        await _gateway.deleteToken();
        _tokenIssued = false;
      } on Object catch (error) {
        tokenGone = false;
        _log.warning(
          _diagnosticsCategory,
          'token_delete_failed',
          fields: {'errorType': error.runtimeType},
        );
      }
    }
    if (_autoInitDisablePending == autoInitOff) {
      _autoInitDisablePending = !autoInitOff;
      await _settings.setBool(
        _autoInitDisablePendingKey,
        value: _autoInitDisablePending,
      );
    }
    if (_tokenDeletePending == tokenGone) {
      _tokenDeletePending = !tokenGone;
      await _settings.setBool(
        _tokenDeletePendingKey,
        value: _tokenDeletePending,
      );
    }
  }

  Future<void> _discardLocalRegistration() async {
    await _retireToken();
    try {
      await _store.clear();
    } on Object catch (error) {
      _log.warning(
        _diagnosticsCategory,
        'secrets_clear_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    _secrets = null;
  }

  /// Waits for a sync in progress, so nothing it was about to send to a host
  /// can arrive after an unregister.
  Future<void> _quiesceSync() async {
    for (var running = _syncFuture; running != null; running = _syncFuture) {
      await running;
    }
  }

  /// Turns closed-app notifications off: unregisters from reachable hosts,
  /// deletes the FCM token and deletes the device key.
  Future<void> disable() => _operations.run(() async {
    if (!state.enabled) return;
    state = state.copyWith(busy: true);
    _optingOut = true;
    // Saved before any remote work, so an app killed mid-way finishes the
    // opt-out at its next start instead of resuming push.
    await _settings.setBool(_optOutPendingKey, value: true);
    await _settings.setBool(_enabledSettingKey, value: false);
    try {
      await _quiesceSync();
      await _pruneDeletedHosts(state.disabledHostIds);
      final deviceId = _secrets?.deviceId;
      _heartbeat?.cancel();
      _heartbeat = null;
      await _tokenRefresh?.cancel();
      _tokenRefresh = null;
      if (deviceId != null) {
        // Every saved host's registration for this device goes.
        final reached = await _unregisterFromLiveHosts(
          hostIds: null,
          entryFor: (_) => deviceId,
        );
        for (final hostId in _registeredHostIds.difference(reached)) {
          _pendingUnregister
              .putIfAbsent(hostId, () => <String>{})
              .add(deviceId);
        }
      }
      _registeredHostIds = <int>{};
      _registered.clear();
      _lastPresence.clear();
      await _persistHostBookkeeping();
      await _retireToken();
      try {
        await _store.clear();
      } on Object catch (error) {
        _log.warning(
          _diagnosticsCategory,
          'secrets_clear_failed',
          fields: {'errorType': error.runtimeType},
        );
      }
      _secrets = null;
      _refreshNeeded = false;
      await _settings.setBool(_optOutPendingKey, value: false);
      _log.info(
        _diagnosticsCategory,
        'opt_out',
        fields: {
          'pendingHosts': _pendingUnregister.length,
          'tokenDeletePending': _tokenDeletePending,
        },
      );
      unawaited(_telemetry.logPushNotificationsToggled(enabled: false));
      state = state.copyWith(enabled: false, busy: false, clearFailure: true);
    } finally {
      _optingOut = false;
      _restartHeartbeat();
    }
  });

  /// Turns push on or off for one saved host.
  Future<void> setHostEnabled(
    int hostId, {
    required bool enabled,
  }) => _operations.run(() async {
    final disabled = {...state.disabledHostIds};
    if (enabled) {
      disabled.remove(hostId);
      state = state.copyWith(disabledHostIds: disabled);
    } else {
      disabled.add(hostId);
      // Visible to a running sync before it reaches this host's links.
      state = state.copyWith(disabledHostIds: disabled);
      await _quiesceSync();
      final secrets = _secrets;
      final deviceId = secrets?.deviceId;
      if (secrets != null && deviceId != null) {
        final entry = _pendingEntry(
          deviceId,
          await derivePushHostRef(
            hostRefKey: secrets.hostRefKey,
            hostId: hostId,
          ),
        );
        final reached = await _unregisterFromLiveHosts(
          hostIds: {hostId},
          entryFor: (_) => entry,
        );
        if (!reached.contains(hostId) && _registeredHostIds.contains(hostId)) {
          _pendingUnregister.putIfAbsent(hostId, () => <String>{}).add(entry);
        }
      }
      _registeredHostIds.remove(hostId);
      final hostConnections = {
        for (final link in _links())
          if (link.hostId == hostId) link.connectionId,
      };
      _registered.removeWhere(
        (key, _) => hostConnections.contains(key.connectionId),
      );
      _lastPresence.removeWhere(
        (key, _) => hostConnections.contains(key.connectionId),
      );
      await _persistHostBookkeeping();
    }
    await _settings.setString(
      _disabledHostsSettingKey,
      jsonEncode(disabled.toList()..sort()),
    );
    _restartHeartbeat();
    if (enabled) scheduleSync();
  });

  /// A pending unregister entry: a device id, optionally with the host
  /// reference of the one saved host to remove.
  static String _pendingEntry(String deviceId, String? hostRef) =>
      hostRef == null ? deviceId : '$deviceId:$hostRef';

  static Map<String, Object?> _unregisterCommand(String entry) {
    final (deviceId, hostRef) = switch (entry.split(':')) {
      [final id, final ref] => (id, ref),
      _ => (entry, null),
    };
    return <String, Object?>{
      'type': 'push_unregister',
      'push': {'deviceId': deviceId, 'hostRef': ?hostRef},
    };
  }

  Future<Set<int>> _unregisterFromLiveHosts({
    required Set<int>? hostIds,
    required String Function(PushHostLink link) entryFor,
  }) async {
    final reached = <int>{};
    for (final link in _links()) {
      if (hostIds != null && !hostIds.contains(link.hostId)) continue;
      try {
        final result = await link
            .send(_unregisterCommand(entryFor(link)))
            .timeout(const Duration(seconds: 8));
        if (result.ok || result.unsupported) reached.add(link.hostId);
      } on Object catch (error) {
        _log.debug(
          _diagnosticsCategory,
          'unregister_failed',
          fields: {
            'connectionId': link.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
    }
    return reached;
  }

  /// Sends a test notification through the first connected host.
  Future<PushTestOutcome> sendTest() async {
    final secrets = _secrets;
    if (!state.enabled || secrets == null || !secrets.isRegistered) {
      return PushTestOutcome.failed;
    }
    await syncNow();
    final all = _links();
    if (all.isEmpty) return PushTestOutcome.noConnectedHost;
    final links = all
        .where((link) => !state.disabledHostIds.contains(link.hostId))
        .toList();
    if (links.isEmpty) return PushTestOutcome.noEnabledHost;
    final link = links.firstWhere(
      (candidate) => _registered.containsKey(_keyOf(candidate)),
      orElse: () => links.first,
    );
    if (_unsupported.containsKey(_keyOf(link))) {
      return PushTestOutcome.hostNeedsUpdate;
    }
    try {
      final result = await link.send(<String, Object?>{
        'type': 'push_test',
        'push': {'deviceId': secrets.deviceId},
      });
      if (result.unsupported) return PushTestOutcome.hostNeedsUpdate;
      final outcome = switch (result.result) {
        'sent' => PushTestOutcome.sent,
        'rate_limited' || 'capped' => PushTestOutcome.rateLimited,
        'bad_ticket' ||
        'unregistered' ||
        'not_registered' => PushTestOutcome.registrationRejected,
        _ => PushTestOutcome.failed,
      };
      _log.info(
        _diagnosticsCategory,
        'test_sent',
        fields: {'connectionId': link.connectionId, 'outcome': outcome.name},
      );
      if (outcome == PushTestOutcome.registrationRejected) {
        // The host dropped the ticket; fetch a new one and register again.
        _registered.remove(_keyOf(link));
        _requestRefresh(newToken: result.result == 'unregistered');
      }
      return outcome;
    } on Object catch (error) {
      _log.warning(
        _diagnosticsCategory,
        'test_failed',
        fields: {'errorType': error.runtimeType},
      );
      return PushTestOutcome.failed;
    }
  }

  /// Records app lifecycle and which terminal is on screen. The route names
  /// the connection when it can; otherwise a host with a single MonkeyMux
  /// connection is unambiguous.
  void reportVisibility({
    required bool foreground,
    int? viewedHostId,
    int? viewedConnectionId,
  }) {
    final resumed = foreground && !_foreground;
    final changed =
        foreground != _foreground ||
        viewedHostId != _viewedHostId ||
        viewedConnectionId != _viewedConnectionId;
    _foreground = foreground;
    _viewedHostId = viewedHostId;
    _viewedConnectionId = viewedConnectionId;
    if (resumed && state.enabled) {
      unawaited(_reconcileRegistration());
    }
    _restartHeartbeat();
    if (changed) scheduleSync();
  }

  bool _isViewed(PushHostLink link, List<PushHostLink> links) {
    if (!_foreground) return false;
    final connectionId = _viewedConnectionId;
    // A route's connection id goes stale when the terminal reconnects; then
    // the host rule below applies.
    if (connectionId != null &&
        links.any((other) => other.connectionId == connectionId)) {
      return link.connectionId == connectionId;
    }
    if (_viewedHostId != link.hostId) return false;
    return links.where((other) => other.hostId == link.hostId).length == 1;
  }

  void _restartHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_disposed) return;
    final needed =
        state.enabled ||
        _pendingUnregister.isNotEmpty ||
        _tokenDeletePending ||
        _autoInitDisablePending;
    if (!needed) return;
    // Runs in the background too: a backgrounded app that keeps its
    // connection (Android's background service) tells hosts it raises its own
    // notifications, and stops doing so the moment it is suspended or killed.
    _heartbeat = Timer.periodic(
      pushPresenceHeartbeatInterval,
      (_) => scheduleSync(),
    );
  }

  void _listenForTokenRefresh() {
    unawaited(_tokenRefresh?.cancel());
    _tokenRefresh = _gateway.onTokenRefresh.listen((token) {
      if (_secrets?.tokenFingerprint == _fingerprint(token)) return;
      _requestRefresh();
    });
  }

  /// Fetches the current token and re-registers when it changed or the
  /// ticket is due for renewal.
  Future<void> _reconcileRegistration() async {
    final secrets = _secrets;
    if (!state.enabled || secrets == null || !secrets.isRegistered) return;
    final issuedAt = secrets.ticketIssuedAt;
    if (issuedAt == null ||
        _now().difference(issuedAt) >= pushTicketRefreshAge) {
      _requestRefresh();
      return;
    }
    try {
      final token = await _gateway.getToken();
      if (token != null &&
          token.isNotEmpty &&
          _fingerprint(token) != secrets.tokenFingerprint) {
        _requestRefresh();
      }
    } on Object catch (error) {
      _log.debug(
        _diagnosticsCategory,
        'token_check_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  /// Marks the registration for renewal and tries now. A failure is retried
  /// from later syncs, at most once per [pushRegistrationRetryInterval].
  void _requestRefresh({bool newToken = false}) {
    _refreshNeeded = true;
    _refreshNeedsNewToken |= newToken;
    unawaited(_maybeRefresh(force: true));
  }

  Future<void> _maybeRefresh({bool force = false}) async {
    if (!_refreshNeeded || _refreshRunning || _disposed) return;
    final last = _lastRefreshAttempt;
    if (!force && last != null && _now().difference(last) < _refreshDelay()) {
      return;
    }
    _refreshRunning = true;
    _lastRefreshAttempt = _now();
    try {
      await _operations.run(() async {
        if (!state.enabled || _optingOut) return;
        final newToken = _refreshNeedsNewToken;
        if (newToken) {
          // FCM says the token is gone; make it issue another. If that fails,
          // getToken would hand back the dead token, so retry later instead.
          await _gateway.deleteToken();
        }
        await _registerToken(await _currentToken());
        _refreshNeeded = false;
        _refreshNeedsNewToken = false;
        _refreshFailures = 0;
        _log.info(
          _diagnosticsCategory,
          'ticket_refreshed',
          fields: {'newToken': newToken},
        );
      });
      if (!_refreshNeeded) scheduleSync();
    } on Object catch (error) {
      _refreshFailures++;
      _log.warning(
        _diagnosticsCategory,
        'ticket_refresh_failed',
        fields: {'errorType': error.runtimeType, 'failures': _refreshFailures},
      );
    } finally {
      _refreshRunning = false;
    }
  }

  /// Delay before the next renewal attempt: doubles per failure, capped.
  Duration _refreshDelay() {
    if (_refreshFailures <= 1) return pushRegistrationRetryInterval;
    final doubled =
        pushRegistrationRetryInterval *
        (1 << (_refreshFailures - 1).clamp(0, 10));
    return doubled > pushRegistrationRetryMax
        ? pushRegistrationRetryMax
        : doubled;
  }

  /// Registers with new attachments and reports presence, soon.
  void scheduleSync() {
    if (_disposed || !state.loaded) return;
    unawaited(syncNow());
  }

  /// Registers with new attachments and reports presence now.
  ///
  /// A call while a sync runs queues one more pass and completes with it.
  @visibleForTesting
  Future<void> syncNow() {
    if (_disposed) return Future<void>.value();
    final running = _syncFuture;
    if (running != null) {
      _syncQueued = true;
      return running;
    }
    return _syncFuture = _runSyncs();
  }

  Future<void> _runSyncs() async {
    try {
      do {
        _syncQueued = false;
        try {
          await _sync();
        } on Object catch (error) {
          _log.warning(
            _diagnosticsCategory,
            'sync_failed',
            fields: {'errorType': error.runtimeType},
          );
        }
      } while (_syncQueued && !_disposed);
    } finally {
      _syncFuture = null;
    }
  }

  Future<void> _sync() async {
    final links = _links();
    final liveKeys = {for (final link in links) _keyOf(link)};
    _registered.removeWhere((key, _) => !liveKeys.contains(key));
    _lastPresence.removeWhere((key, _) => !liveKeys.contains(key));
    final now = _now();
    _unsupported.removeWhere(
      (key, at) =>
          !liveKeys.contains(key) ||
          now.difference(at) >= pushUnsupportedRetryInterval,
    );
    var bookkeepingChanged = false;

    if ((_tokenDeletePending || _autoInitDisablePending) &&
        !state.enabled &&
        !state.busy) {
      final last = _lastTokenDeleteAttempt;
      if (last == null ||
          now.difference(last) >= pushRegistrationRetryInterval) {
        // Serialized with enable(), so it can never delete a token that an
        // opt-in in progress is registering.
        unawaited(
          _operations.run(() async {
            if ((_tokenDeletePending || _autoInitDisablePending) &&
                !state.enabled) {
              await _retireToken();
            }
          }),
        );
      }
    }
    if (_refreshNeeded) unawaited(_maybeRefresh());

    for (final link in links) {
      final pending = _pendingUnregister[link.hostId];
      if (pending == null) continue;
      for (final entry in pending.toList()) {
        try {
          final result = await link.send(_unregisterCommand(entry));
          if (result.ok || result.unsupported) {
            pending.remove(entry);
            bookkeepingChanged = true;
          }
        } on Object {
          // Retried on the next sync.
        }
      }
      if (pending.isEmpty) _pendingUnregister.remove(link.hostId);
    }

    for (final link in links) {
      final secrets = _secrets;
      if (!state.enabled ||
          _optingOut ||
          secrets == null ||
          !secrets.isRegistered) {
        break;
      }
      // Re-read per link: a host turned off mid-sync is skipped from here on.
      if (state.disabledHostIds.contains(link.hostId)) continue;
      final key = _keyOf(link);
      if (_unsupported.containsKey(key)) continue;
      if (_registered[key] != secrets.ticket) {
        if (secrets.ticket == _refusedTicket) continue;
        if (!await _registerLink(link, secrets)) continue;
        if (_optingOut || state.disabledHostIds.contains(link.hostId)) {
          continue;
        }
        _registered[key] = secrets.ticket!;
        if (_registeredHostIds.add(link.hostId)) bookkeepingChanged = true;
      }
      await _sendPresence(link, links, secrets);
    }
    if (bookkeepingChanged) await _persistHostBookkeeping();
    if (_pendingUnregister.isEmpty &&
        !state.enabled &&
        !_tokenDeletePending &&
        !_autoInitDisablePending) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  Future<bool> _registerLink(
    PushHostLink link,
    PushDeviceSecrets secrets,
  ) async {
    try {
      final result = await link.send(<String, Object?>{
        'type': 'push_register',
        'push': {
          'deviceId': secrets.deviceId,
          'ticket': secrets.ticket,
          'publicKey': secrets.keyPair.encodedPublicKey,
          'hostRef': await derivePushHostRef(
            hostRefKey: secrets.hostRefKey,
            hostId: link.hostId,
          ),
        },
      });
      if (result.unsupported) {
        _unsupported[_keyOf(link)] = _now();
      }
      final stale = switch (result.result) {
        'stale_ticket' => true,
        'token_unregistered' => true,
        _ => false,
      };
      _log.info(
        _diagnosticsCategory,
        'host_register',
        fields: {
          'connectionId': link.connectionId,
          'ok': result.ok && !stale,
          'unsupported': result.unsupported,
          'stale': stale,
        },
      );
      if (stale) {
        // The host remembers that the function refused this ticket.
        _refusedTicket = secrets.ticket;
        _requestRefresh(newToken: result.result == 'token_unregistered');
        return false;
      }
      return result.ok;
    } on Object catch (error) {
      _log.debug(
        _diagnosticsCategory,
        'host_register_failed',
        fields: {
          'connectionId': link.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Tells the host whether this device is watching its terminal, alive in
  /// the background with this attach (and so raising its own
  /// notifications), or neither. Watching and background states repeat as a
  /// heartbeat; idle is said once.
  Future<void> _sendPresence(
    PushHostLink link,
    List<PushHostLink> links,
    PushDeviceSecrets secrets,
  ) async {
    final key = _keyOf(link);
    final localBridges = !_foreground && _localPresenceSupported
        ? _localBridges(link.hostId)
        : const <String>[];
    final localAlerts =
        !_foreground &&
        _localPresenceSupported &&
        _hasAlertListener(link.connectionId);
    final presence = _foreground
        ? (_isViewed(link, links) ? _Presence.viewing : _Presence.idle)
        : (localAlerts || localBridges.isNotEmpty)
        ? _Presence.local
        : _Presence.idle;
    if (presence == _Presence.idle && _lastPresence[key] == _Presence.idle) {
      return;
    }
    try {
      final result = await link.send(<String, Object?>{
        'type': 'push_presence',
        'clientId': link.clientId,
        'push': {
          'deviceId': secrets.deviceId,
          'foreground': presence == _Presence.viewing,
          'local': presence == _Presence.local,
          if (presence == _Presence.local) 'alerts': localAlerts,
          if (presence == _Presence.local) 'bridges': localBridges,
        },
      }, lowPriority: true);
      if (result.ok) _lastPresence[key] = presence;
    } on Object {
      // Presence is advisory; the next heartbeat retries.
    }
  }

  /// Drops bookkeeping for saved hosts that were deleted: a deleted host can
  /// never be attached again, so its pending unregister would never flush.
  /// Returns [disabledHosts] without deleted hosts.
  Future<Set<int>> _pruneDeletedHosts(Set<int> disabledHosts) async {
    final Set<int> saved;
    try {
      saved = (await _hostIds()).toSet();
    } on Object catch (error) {
      _log.debug(
        _diagnosticsCategory,
        'hosts_unreadable',
        fields: {'errorType': error.runtimeType},
      );
      return disabledHosts;
    }
    final registeredBefore = _registeredHostIds.length;
    final pendingBefore = _pendingUnregister.length;
    _registeredHostIds = _registeredHostIds.intersection(saved);
    _pendingUnregister.removeWhere((hostId, _) => !saved.contains(hostId));
    final pruned = disabledHosts.intersection(saved);
    if (_registeredHostIds.length != registeredBefore ||
        _pendingUnregister.length != pendingBefore) {
      await _persistHostBookkeeping();
    }
    if (pruned.length != disabledHosts.length) {
      await _settings.setString(
        _disabledHostsSettingKey,
        jsonEncode(pruned.toList()..sort()),
      );
    }
    return pruned;
  }

  Future<void> _persistHostBookkeeping() async {
    if (!_disposed) {
      state = state.copyWith(
        registeredHostIds: Set.unmodifiable(_registeredHostIds),
      );
    }
    await _settings.setString(
      _registeredHostsSettingKey,
      jsonEncode(_registeredHostIds.toList()..sort()),
    );
    await _settings.setString(
      _pendingUnregisterSettingKey,
      jsonEncode({
        for (final entry in _pendingUnregister.entries)
          '${entry.key}': entry.value.toList()..sort(),
      }),
    );
  }

  /// Decrypts a message and works out where its tap should go. Returns null
  /// when the message is not ours, cannot be decrypted, or names no saved
  /// host.
  Future<PushNavigationTarget?> resolve(PushRemoteMessage message) async {
    final payload = message.encryptedPayload;
    if (payload == null) return null;
    final secrets = _secrets ?? await _loadSecrets();
    if (secrets == null) return null;
    final plaintext = await openPushPayload(
      device: secrets.keyPair,
      payload: payload,
    );
    final event = plaintext == null ? null : PushEvent.tryParse(plaintext);
    if (event == null) {
      _log.info(_diagnosticsCategory, 'message_unreadable');
      return null;
    }
    int? hostId;
    final List<int> hostIds;
    try {
      hostIds = await _hostIds();
    } on Object catch (error) {
      _log.warning(
        _diagnosticsCategory,
        'hosts_unreadable',
        fields: {'errorType': error.runtimeType},
      );
      return null;
    }
    for (final candidate in hostIds) {
      final hostRef = await derivePushHostRef(
        hostRefKey: secrets.hostRefKey,
        hostId: candidate,
      );
      if (hostRef == event.hostRef) {
        hostId = candidate;
        break;
      }
    }
    if (hostId == null) {
      _log.info(_diagnosticsCategory, 'message_host_unknown');
      return null;
    }
    int? connectionId;
    for (final link in _links()) {
      if (link.hostId == hostId && link.sessionName == event.sessionName) {
        connectionId = link.connectionId;
        break;
      }
    }
    return PushNavigationTarget(
      hostId: hostId,
      kind: event.kind,
      sessionName: event.sessionName,
      windowId: event.windowId,
      connectionId: connectionId,
    );
  }

  /// Whether a message that arrived in the foreground adds nothing to the
  /// terminal on screen: the event's window is the one showing, or it is a
  /// window alert from the session on screen, whose window bar already
  /// raised it.
  bool shouldSuppressInForeground(PushNavigationTarget target) {
    if (target.kind == PushEventKind.test) return false;
    final links = _links();
    for (final link in links) {
      if (link.hostId != target.hostId || !_isViewed(link, links)) continue;
      if (!target.hasWindow) return true;
      if (link.sessionName != target.sessionName) continue;
      if (link.activeWindowId == target.windowId ||
          target.kind == PushEventKind.alert) {
        return true;
      }
    }
    return false;
  }

  _LinkKey _keyOf(PushHostLink link) =>
      (connectionId: link.connectionId, sessionName: link.sessionName);

  static String _fingerprint(String token) =>
      crypto.sha256.convert(utf8.encode(token)).toString();

  static Set<int> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<int>().toSet();
    } on FormatException {
      // Treated as empty.
    }
    return <int>{};
  }

  static Map<int, Set<String>> _decodePending(String? raw) {
    if (raw == null || raw.isEmpty) return <int, Set<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return {
          for (final entry in decoded.entries)
            if (int.tryParse(entry.key) case final int hostId)
              if (entry.value case final List<Object?> ids)
                hostId: ids.whereType<String>().toSet(),
        };
      }
    } on FormatException {
      // Treated as empty.
    }
    return <int, Set<String>>{};
  }
}

/// Push notification settings, registration and message decoding.
final pushNotificationControllerProvider =
    NotifierProvider<PushNotificationController, PushNotificationState>(
      PushNotificationController.new,
    );
