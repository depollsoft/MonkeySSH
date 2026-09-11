import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';
import 'terminal_notification.dart';

/// Local notification channel used for tmux activity alerts.
const tmuxAlertNotificationChannelId = 'tmux-alerts';

/// Normal-priority, system-sound notification channel.
const terminalNotificationChannelId = 'terminal-notifications-normal-system-v3';

/// Low-priority, system-sound notification channel.
const terminalNotificationLowChannelId = 'terminal-notifications-low-system-v2';

/// Critical-priority, system-sound notification channel.
const terminalNotificationCriticalChannelId =
    'terminal-notifications-critical-system-v2';

/// Normal-priority notification channel with sound disabled at channel level.
const terminalNotificationSilentChannelId =
    'terminal-notifications-normal-silent-v2';

/// Low-priority notification channel with sound disabled at channel level.
const terminalNotificationLowSilentChannelId =
    'terminal-notifications-low-silent-v2';

/// Critical-priority notification channel with sound disabled at channel level.
const terminalNotificationCriticalSilentChannelId =
    'terminal-notifications-critical-silent-v2';

/// Local notification channel used for ACP agent completion/permission
/// alerts shown only while the app is backgrounded.
const acpNotificationChannelId = 'acp-notifications';
const _androidNotificationIcon = 'ic_notification_monkey';

/// Builds native details for a terminal notification's protocol metadata.
NotificationDetails buildTerminalNotificationDetails({
  required TerminalNotificationUrgency urgency,
  required TerminalNotificationSound sound,
  Duration? timeout,
}) {
  final (
    systemChannelId,
    silentChannelId,
    channelName,
    importance,
    priority,
    interruptionLevel,
  ) = switch (urgency) {
    TerminalNotificationUrgency.low => (
      terminalNotificationLowChannelId,
      terminalNotificationLowSilentChannelId,
      'Quiet terminal notifications',
      Importance.low,
      Priority.low,
      InterruptionLevel.passive,
    ),
    TerminalNotificationUrgency.normal => (
      terminalNotificationChannelId,
      terminalNotificationSilentChannelId,
      'Terminal notifications',
      Importance.defaultImportance,
      Priority.defaultPriority,
      InterruptionLevel.active,
    ),
    TerminalNotificationUrgency.critical => (
      terminalNotificationCriticalChannelId,
      terminalNotificationCriticalSilentChannelId,
      'Critical terminal notifications',
      Importance.max,
      Priority.max,
      // Critical Alerts require a restricted Apple entitlement. Active is the
      // highest portable level that does not silently expand app capabilities.
      InterruptionLevel.active,
    ),
  };
  final playsSound = sound == TerminalNotificationSound.system;
  final androidDetails = AndroidNotificationDetails(
    playsSound ? systemChannelId : silentChannelId,
    playsSound ? channelName : 'Silent $channelName',
    channelDescription: 'Notifications sent by the remote shell.',
    importance: importance,
    priority: priority,
    icon: _androidNotificationIcon,
    playSound: playsSound,
    silent: !playsSound,
    timeoutAfter: timeout?.inMilliseconds,
  );
  final darwinDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: false,
    presentSound: playsSound,
    interruptionLevel: interruptionLevel,
  );
  return NotificationDetails(
    android: androidDetails,
    iOS: darwinDetails,
    macOS: darwinDetails,
  );
}

const _disableNotificationsForStoreScreenshots = bool.fromEnvironment(
  'STORE_SCREENSHOT_DISABLE_NOTIFICATIONS',
);

/// Payload attached to a tmux alert notification.
@immutable
class TmuxAlertNotificationPayload {
  /// Creates a new [TmuxAlertNotificationPayload].
  const TmuxAlertNotificationPayload({
    required this.hostId,
    required this.connectionId,
    required this.tmuxSessionName,
    required this.windowIndex,
    this.windowId,
  });

  static const _type = 'tmux-alert';
  static const _version = 1;

  /// Host that owns the alerted connection.
  final int hostId;

  /// Existing SSH connection that produced the alert.
  final int connectionId;

  /// tmux session containing the alerted window.
  final String tmuxSessionName;

  /// tmux window index that needs attention.
  final int windowIndex;

  /// Stable tmux window ID that needs attention, when available.
  final String? windowId;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'hostId': hostId,
    'connectionId': connectionId,
    'tmuxSessionName': tmuxSessionName,
    'windowIndex': windowIndex,
    'windowId': ?windowId,
  });

  /// Decodes a notification payload, returning `null` for other payload types.
  static TmuxAlertNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> ||
          decoded['type'] != _type ||
          decoded['version'] != _version) {
        return null;
      }
      final hostId = decoded['hostId'];
      final connectionId = decoded['connectionId'];
      final tmuxSessionName = decoded['tmuxSessionName'];
      final windowIndex = decoded['windowIndex'];
      final windowId = decoded['windowId'];
      final stableWindowId = windowId is String && isValidTmuxWindowId(windowId)
          ? windowId
          : null;
      if (hostId is! int ||
          connectionId is! int ||
          tmuxSessionName is! String ||
          tmuxSessionName.trim().isEmpty ||
          windowIndex is! int ||
          (windowId != null && stableWindowId == null)) {
        return null;
      }
      return TmuxAlertNotificationPayload(
        hostId: hostId,
        connectionId: connectionId,
        tmuxSessionName: tmuxSessionName,
        windowIndex: windowIndex,
        windowId: stableWindowId,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxAlertNotificationPayload &&
          hostId == other.hostId &&
          connectionId == other.connectionId &&
          tmuxSessionName == other.tmuxSessionName &&
          windowIndex == other.windowIndex &&
          windowId == other.windowId;

  @override
  int get hashCode =>
      Object.hash(hostId, connectionId, tmuxSessionName, windowIndex, windowId);
}

/// Builds the terminal route location for a tmux alert notification tap.
String buildTmuxAlertTerminalLocation(TmuxAlertNotificationPayload payload) =>
    Uri(
      path: '/terminal/${payload.hostId}',
      queryParameters: <String, String>{
        'connectionId': '${payload.connectionId}',
        'tmuxSession': payload.tmuxSessionName,
        'tmuxWindow': '${payload.windowIndex}',
        if (payload.windowId != null) 'tmuxWindowId': payload.windowId!,
      },
    ).toString();

/// Payload attached to a terminal desktop notification (OSC 9 / 777 / 99).
@immutable
class TerminalNotificationPayload {
  /// Creates a new [TerminalNotificationPayload].
  const TerminalNotificationPayload({
    required this.hostId,
    required this.connectionId,
    this.platformNotificationId,
    this.notificationIdentifier,
    this.reportsActivation = false,
    this.focusOnActivation = true,
  });

  static const _type = 'terminal-notification';
  static const _version = 3;

  /// Host that owns the connection that emitted the notification.
  final int hostId;

  /// Existing SSH connection that emitted the notification.
  final int connectionId;

  /// Exact local notification ID used for expiration and replacement.
  final int? platformNotificationId;

  /// Kitty identifier to echo when activation reporting was requested.
  final String? notificationIdentifier;

  /// Whether tapping this notification sends an OSC 99 activation report.
  final bool reportsActivation;

  /// Whether tapping should navigate to the originating terminal.
  final bool focusOnActivation;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'hostId': hostId,
    'connectionId': connectionId,
    'platformNotificationId': ?platformNotificationId,
    'notificationIdentifier': ?notificationIdentifier,
    'reportsActivation': reportsActivation,
    'focusOnActivation': focusOnActivation,
  });

  /// Decodes current payloads and navigation-only version 1 payloads.
  static TerminalNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> || decoded['type'] != _type) {
        return null;
      }
      final version = decoded['version'];
      if (version != 1 && version != 2 && version != _version) return null;
      final hostId = decoded['hostId'];
      final connectionId = decoded['connectionId'];
      final platformNotificationId = decoded['platformNotificationId'];
      final identifier = decoded['notificationIdentifier'];
      final reportsActivation = decoded['reportsActivation'];
      final focusOnActivation = decoded['focusOnActivation'];
      if (hostId is! int ||
          connectionId is! int ||
          (platformNotificationId != null && platformNotificationId is! int) ||
          (identifier != null && identifier is! String) ||
          (reportsActivation != null && reportsActivation is! bool) ||
          (focusOnActivation != null && focusOnActivation is! bool)) {
        return null;
      }
      return TerminalNotificationPayload(
        hostId: hostId,
        connectionId: connectionId,
        platformNotificationId: platformNotificationId as int?,
        notificationIdentifier: identifier as String?,
        reportsActivation: reportsActivation as bool? ?? false,
        focusOnActivation: focusOnActivation as bool? ?? true,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalNotificationPayload &&
          hostId == other.hostId &&
          connectionId == other.connectionId &&
          platformNotificationId == other.platformNotificationId &&
          notificationIdentifier == other.notificationIdentifier &&
          reportsActivation == other.reportsActivation &&
          focusOnActivation == other.focusOnActivation;

  @override
  int get hashCode => Object.hash(
    hostId,
    connectionId,
    platformNotificationId,
    notificationIdentifier,
    reportsActivation,
    focusOnActivation,
  );
}

/// Builds a local notification identifier scoped to one SSH connection.
///
/// Kitty's protocol identifier makes create/update/close actions address the
/// same local notification without exposing that user-controlled string.
int buildTerminalNotificationId(int connectionId, {String? identifier}) =>
    Object.hash('terminal-notification', connectionId, identifier) & 0x3fffffff;

/// Builds the terminal route location for a terminal notification tap.
String buildTerminalNotificationLocation(TerminalNotificationPayload payload) =>
    Uri(
      path: '/terminal/${payload.hostId}',
      queryParameters: <String, String>{
        'connectionId': '${payload.connectionId}',
      },
    ).toString();

/// Coarse category of an ACP notification. Never carries prompt, tool, path,
/// or content details.
enum AcpNotificationKind {
  /// A prompt turn finished while the app was backgrounded.
  completion,

  /// The agent requested a permission decision while the app was
  /// backgrounded.
  permission,

  /// The agent requested approval for a validated file write.
  writeApproval,
}

/// Stable, process-independent notification ID namespaced away from terminal
/// notifications. The same session/kind intentionally replaces itself while
/// different sessions and approval kinds remain separately actionable.
int acpNotificationIdFor(AcpNotificationPayload payload) {
  final value =
      '${payload.kind.name}|${payload.hostId}|${payload.providerId}|'
      '${payload.bridgeId}|${payload.acpSessionId}';
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 0x40000000 | (hash & 0x3fffffff);
}

/// Payload attached to an ACP agent notification.
///
/// Deliberately holds only stable identifiers: no prompt text, tool output,
/// paths, commands, or session titles are ever included.
@immutable
class AcpNotificationPayload {
  /// Creates a new [AcpNotificationPayload].
  const AcpNotificationPayload({
    required this.kind,
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
  });

  static const _type = 'acp-notification';
  static const _version = 1;

  /// Notification category.
  final AcpNotificationKind kind;

  /// Host that owns the ACP session.
  final int hostId;

  /// ACP provider identifier (built-in or custom), never a raw command.
  final String providerId;

  /// Remote MonkeyMux ACP bridge identifier.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Encodes this payload for the notification plugin.
  String encode() => jsonEncode(<String, Object>{
    'type': _type,
    'version': _version,
    'kind': kind.name,
    'hostId': hostId,
    'providerId': providerId,
    'bridgeId': bridgeId,
    'acpSessionId': acpSessionId,
  });

  /// Decodes a notification payload, returning `null` for other payload types.
  static AcpNotificationPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?> ||
          decoded['type'] != _type ||
          decoded['version'] != _version) {
        return null;
      }
      final kindName = decoded['kind'];
      final hostId = decoded['hostId'];
      final providerId = decoded['providerId'];
      final bridgeId = decoded['bridgeId'];
      final acpSessionId = decoded['acpSessionId'];
      AcpNotificationKind? kind;
      for (final value in AcpNotificationKind.values) {
        if (value.name == kindName) {
          kind = value;
          break;
        }
      }
      if (kind == null ||
          hostId is! int ||
          providerId is! String ||
          providerId.isEmpty ||
          bridgeId is! String ||
          bridgeId.isEmpty ||
          acpSessionId is! String ||
          acpSessionId.isEmpty) {
        return null;
      }
      return AcpNotificationPayload(
        kind: kind,
        hostId: hostId,
        providerId: providerId,
        bridgeId: bridgeId,
        acpSessionId: acpSessionId,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpNotificationPayload &&
          kind == other.kind &&
          hostId == other.hostId &&
          providerId == other.providerId &&
          bridgeId == other.bridgeId &&
          acpSessionId == other.acpSessionId;

  @override
  int get hashCode =>
      Object.hash(kind, hostId, providerId, bridgeId, acpSessionId);
}

/// Route path for the full-screen ACP agent chat.
const acpAgentChatRoutePath = '/agents/chat';

/// Query key carrying the opaque host identifier for the agent chat route.
const acpAgentChatHostQueryKey = 'h';

/// Query key carrying the opaque provider identifier for the agent chat route.
const acpAgentChatProviderQueryKey = 'p';

/// Query key carrying the opaque bridge identifier for the agent chat route.
const acpAgentChatBridgeQueryKey = 'b';

/// Query key carrying the opaque remote ACP session identifier for the agent
/// chat route.
const acpAgentChatSessionQueryKey = 's';

/// Safe fallback used when an ACP chat has no route beneath it.
///
/// Native ACP sessions live in the MonkeyMux window navigator, so the fallback
/// returns to active connections rather than a separate top-level workspace.
String buildAcpSessionFallbackLocation() =>
    Uri(path: '/', queryParameters: const {'tab': 'connections'}).toString();

/// Builds the deep-link location for a specific ACP chat session, carrying
/// only opaque identifiers. No working directory, title, command, prompt, or
/// path is ever placed in the URL.
String buildAgentChatLocation({
  required int hostId,
  required String providerId,
  required String bridgeId,
  required String acpSessionId,
}) => Uri(
  path: acpAgentChatRoutePath,
  queryParameters: <String, String>{
    acpAgentChatHostQueryKey: '$hostId',
    acpAgentChatProviderQueryKey: providerId,
    acpAgentChatBridgeQueryKey: bridgeId,
    acpAgentChatSessionQueryKey: acpSessionId,
  },
).toString();

/// Builds the safe navigation location for an ACP notification tap.
///
/// The redacted payload carries the full set of opaque session identifiers, so
/// the tap lands directly on the matching native chat.
String buildAcpNotificationLocation(AcpNotificationPayload payload) =>
    buildAgentChatLocation(
      hostId: payload.hostId,
      providerId: payload.providerId,
      bridgeId: payload.bridgeId,
      acpSessionId: payload.acpSessionId,
    );

/// Service for showing local notifications inside the app.
class LocalNotificationService {
  /// Creates a new [LocalNotificationService].
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _tmuxAlertNotificationChannel = AndroidNotificationChannel(
    tmuxAlertNotificationChannelId,
    'tmux alerts',
    description: 'Window activity alerts for tmux sessions.',
    importance: Importance.high,
  );

  static const _terminalNotificationChannels = <AndroidNotificationChannel>[
    AndroidNotificationChannel(
      terminalNotificationLowChannelId,
      'Quiet terminal notifications',
      description: 'Low-priority notifications sent by the remote shell.',
      importance: Importance.low,
    ),
    AndroidNotificationChannel(
      terminalNotificationChannelId,
      'Terminal notifications',
      description: 'Notifications sent by the remote shell.',
    ),
    AndroidNotificationChannel(
      terminalNotificationCriticalChannelId,
      'Critical terminal notifications',
      description: 'Critical notifications sent by the remote shell.',
      importance: Importance.max,
    ),
    AndroidNotificationChannel(
      terminalNotificationLowSilentChannelId,
      'Silent quiet terminal notifications',
      description:
          'Silent low-priority notifications sent by the remote shell.',
      importance: Importance.low,
      playSound: false,
    ),
    AndroidNotificationChannel(
      terminalNotificationSilentChannelId,
      'Silent terminal notifications',
      description: 'Silent notifications sent by the remote shell.',
      playSound: false,
    ),
    AndroidNotificationChannel(
      terminalNotificationCriticalSilentChannelId,
      'Silent critical terminal notifications',
      description: 'Silent critical notifications sent by the remote shell.',
      importance: Importance.max,
      playSound: false,
    ),
  ];

  /// Android terminal channels exposed for focused channel-policy tests.
  @visibleForTesting
  static List<AndroidNotificationChannel>
  get debugTerminalNotificationChannels => _terminalNotificationChannels;

  static const _acpNotificationChannel = AndroidNotificationChannel(
    acpNotificationChannelId,
    'Agent notifications',
    description:
        'Agent completion and permission alerts shown only while the app '
        'is in the background.',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<TmuxAlertNotificationPayload> _tmuxAlertTapController =
      StreamController<TmuxAlertNotificationPayload>.broadcast();
  final StreamController<TerminalNotificationPayload>
  _terminalNotificationTapController =
      StreamController<TerminalNotificationPayload>.broadcast();
  final StreamController<AcpNotificationPayload> _acpNotificationTapController =
      StreamController<AcpNotificationPayload>.broadcast();
  Future<bool>? _initializeFuture;
  TmuxAlertNotificationPayload? _launchTmuxAlert;
  TerminalNotificationPayload? _launchTerminalNotification;
  AcpNotificationPayload? _launchAcpNotification;
  bool _didConsumeLaunchTmuxAlert = false;
  bool _didConsumeLaunchTerminalNotification = false;
  bool _didConsumeLaunchAcpNotification = false;

  /// Emits whenever the user taps a tmux alert notification.
  Stream<TmuxAlertNotificationPayload> get tmuxAlertTaps =>
      _tmuxAlertTapController.stream;

  /// Emits whenever the user taps a terminal desktop notification.
  Stream<TerminalNotificationPayload> get terminalNotificationTaps =>
      _terminalNotificationTapController.stream;

  /// Emits whenever the user taps an ACP agent notification.
  Stream<AcpNotificationPayload> get acpNotificationTaps =>
      _acpNotificationTapController.stream;

  /// Ensures the underlying notification plugin is initialized.
  Future<bool> initialize() => _initializeFuture ??= _initializeInternal();

  /// Releases notification routing resources.
  void dispose() {
    unawaited(_tmuxAlertTapController.close());
    unawaited(_terminalNotificationTapController.close());
    unawaited(_acpNotificationTapController.close());
  }

  /// Returns the tmux alert that launched the app, if one has not been consumed.
  Future<TmuxAlertNotificationPayload?> consumeLaunchTmuxAlert() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchTmuxAlert) {
      return null;
    }
    _didConsumeLaunchTmuxAlert = true;
    return _launchTmuxAlert;
  }

  /// Returns the terminal notification that launched the app, if one has not
  /// been consumed.
  Future<TerminalNotificationPayload?>
  consumeLaunchTerminalNotification() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchTerminalNotification) {
      return null;
    }
    _didConsumeLaunchTerminalNotification = true;
    return _launchTerminalNotification;
  }

  /// Returns the ACP notification that launched the app, if one has not been
  /// consumed.
  Future<AcpNotificationPayload?> consumeLaunchAcpNotification() async {
    final didInitialize = await initialize();
    if (!didInitialize || _didConsumeLaunchAcpNotification) {
      return null;
    }
    _didConsumeLaunchAcpNotification = true;
    return _launchAcpNotification;
  }

  /// Shows or refreshes a tmux alert notification.
  Future<void> showTmuxAlert({
    required int notificationId,
    required String title,
    required String body,
    required TmuxAlertNotificationPayload payload,
  }) => _showNotification(
    notificationId: notificationId,
    title: title,
    body: body,
    payload: payload.encode(),
    details: _alertDetails(_tmuxAlertNotificationChannel),
  );

  /// Clears a previously shown tmux alert notification.
  Future<void> clearTmuxAlert(int notificationId) =>
      _clearNotification(notificationId);

  /// Shows a terminal desktop notification emitted by the remote shell.
  ///
  /// Returns whether the notification was handed to the platform plugin.
  Future<bool> showTerminalNotification({
    required int notificationId,
    required String title,
    required String body,
    required TerminalNotificationPayload payload,
    TerminalNotificationUrgency urgency = TerminalNotificationUrgency.normal,
    TerminalNotificationSound sound = TerminalNotificationSound.silent,
    Duration? timeout,
  }) => _showNotification(
    notificationId: notificationId,
    title: title,
    body: body,
    payload: payload.encode(),
    allowSound: sound == TerminalNotificationSound.system,
    details: buildTerminalNotificationDetails(
      urgency: urgency,
      sound: sound,
      timeout: timeout,
    ),
  );

  /// Clears a terminal desktop notification by its local identifier.
  Future<void> clearTerminalNotification(int notificationId) =>
      _clearNotification(notificationId);

  final _notificationOperations = <int, Future<void>>{};

  /// Number of notification IDs with unfinished platform operations.
  @visibleForTesting
  int get pendingNotificationOperationCount => _notificationOperations.length;

  Future<T> _enqueueNotification<T>(
    int notificationId,
    Future<T> Function() operation,
  ) {
    final previous =
        _notificationOperations[notificationId] ?? Future<void>.value();
    late final Future<void> completed;
    final result = previous.then((_) async {
      try {
        return await operation();
      } finally {
        if (identical(_notificationOperations[notificationId], completed)) {
          unawaited(_notificationOperations.remove(notificationId));
        }
      }
    });
    // Keep failures visible to the caller without blocking later cancellation.
    completed = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _notificationOperations[notificationId] = completed;
    return result;
  }

  Future<void> _clearNotification(int notificationId) =>
      _enqueueNotification(notificationId, () async {
        if (!await initialize()) return;
        try {
          await _plugin.cancel(id: notificationId);
        } on MissingPluginException {
          // Widget and unit tests don't register platform notification plugins.
        }
      });

  /// Shows an ACP agent notification (completion or permission-needed).
  ///
  /// Callers must only invoke this while the app is backgrounded and a
  /// network/SSH path to the host still exists: there is no push path when
  /// disconnected, so no notification can ever be delivered in that case.
  /// [title] and [body] must never include prompt text, tool arguments or
  /// output, paths, or commands.
  Future<void> showAcpNotification({
    required int notificationId,
    required String title,
    required String body,
    required AcpNotificationPayload payload,
  }) => _showNotification(
    notificationId: notificationId,
    title: title,
    body: body,
    payload: payload.encode(),
    details: _alertDetails(_acpNotificationChannel),
  );

  NotificationDetails _alertDetails(AndroidNotificationChannel channel) {
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: channel.importance,
        priority: Priority.high,
        icon: _androidNotificationIcon,
        onlyAlertOnce: true,
      ),
      iOS: darwinDetails,
      macOS: darwinDetails,
    );
  }

  Future<bool> _showNotification({
    required int notificationId,
    required String title,
    required String body,
    required String payload,
    required NotificationDetails details,
    bool allowSound = false,
  }) => _enqueueNotification(notificationId, () async {
    if (!await initialize()) return false;
    if (!await _requestNotificationPermission(allowSound: allowSound)) {
      return false;
    }
    try {
      await _plugin.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
      return true;
    } on MissingPluginException {
      // Widget and unit tests don't register platform notification plugins.
      return false;
    }
  });

  Future<bool> _initializeInternal() async {
    if (kIsWeb) return false;
    if (_disableNotificationsForStoreScreenshots) return false;

    try {
      const initializationSettings = InitializationSettings(
        android: AndroidInitializationSettings(_androidNotificationIcon),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchPayload = (launchDetails?.didNotificationLaunchApp ?? false)
          ? launchDetails?.notificationResponse?.payload
          : null;
      _launchTmuxAlert = TmuxAlertNotificationPayload.decode(launchPayload);
      _launchTerminalNotification = TerminalNotificationPayload.decode(
        launchPayload,
      );
      _launchAcpNotification = AcpNotificationPayload.decode(launchPayload);

      await _plugin.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );

      final androidImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImplementation?.createNotificationChannel(
        _tmuxAlertNotificationChannel,
      );
      for (final channel in _terminalNotificationChannels) {
        await androidImplementation?.createNotificationChannel(channel);
      }
      await androidImplementation?.createNotificationChannel(
        _acpNotificationChannel,
      );

      return true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _requestNotificationPermission({bool allowSound = false}) async {
    try {
      final androidImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImplementation != null) {
        return await androidImplementation.requestNotificationsPermission() ??
            false;
      }

      final iOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iOSImplementation != null) {
        return await iOSImplementation.requestPermissions(
              alert: true,
              sound: allowSound,
            ) ??
            false;
      }

      final macOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (macOSImplementation != null) {
        return await macOSImplementation.requestPermissions(
              alert: true,
              sound: allowSound,
            ) ??
            false;
      }

      return true;
    } on MissingPluginException {
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final tmuxPayload = TmuxAlertNotificationPayload.decode(response.payload);
    if (tmuxPayload != null) {
      _tmuxAlertTapController.add(tmuxPayload);
      return;
    }
    final terminalPayload = TerminalNotificationPayload.decode(
      response.payload,
    );
    if (terminalPayload != null) {
      _terminalNotificationTapController.add(terminalPayload);
      return;
    }
    final acpPayload = AcpNotificationPayload.decode(response.payload);
    if (acpPayload != null) {
      _acpNotificationTapController.add(acpPayload);
    }
  }
}

/// Provides access to local notifications.
final Provider<LocalNotificationService> localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) {
      final service = LocalNotificationService();
      ref.onDispose(service.dispose);
      return service;
    });
