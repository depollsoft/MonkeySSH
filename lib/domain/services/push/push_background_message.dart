import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../local_notification_service.dart';
import 'push_crypto.dart';
import 'push_event.dart';
import 'push_notification_context.dart';
import 'push_notification_service.dart';
import 'push_notification_text.dart';
import 'push_tap_payload.dart';

/// Android receives pushes as data only and shows them itself, so the
/// notification can name the host and agent (docs/push-notifications.md, "FCM
/// message"). Registered at startup; FlutterFire calls it in a background
/// isolate whenever a push arrives while the app is not in the foreground.
void registerPushBackgroundMessageHandler() {
  FirebaseMessaging.onBackgroundMessage(handlePushBackgroundMessage);
}

/// The FlutterFire background entry point. A message with a notification of
/// its own (from a push function that predates data-only Android messages) is
/// already shown by the system, so it is not posted again.
@pragma('vm:entry-point')
Future<void> handlePushBackgroundMessage(RemoteMessage message) async {
  if (message.notification != null) return;
  await showPushNotificationFromData(message.data);
}

/// A push notification ready to post.
@immutable
class PushNotificationPost {
  /// Creates a post.
  const PushNotificationPost({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.tapPayload,
    this.timestamp,
    this.replaces = const [],
  });

  /// The window's notification slot for the kind (its request slot for an
  /// approval or question, else the other), shared with the app's own
  /// notifications for that window, so a push replaces what the app raised
  /// there and a newer push replaces an older one. Without the host's id,
  /// stable per collapse key instead.
  final int id;

  /// Slots cleared before posting when they hold a notification the app
  /// raised: a request push clears the bell or notice the app put in the
  /// window's other slot before the program reported the request, but never
  /// a push there (which may be newer).
  final List<int> replaces;

  /// What happened; picks the channel.
  final PushEventKind kind;

  /// The title.
  final String title;

  /// The body.
  final String body;

  /// What a tap hands back to the app (see [pushTapPayload]).
  final String tapPayload;

  /// When the host saw the event.
  final DateTime? timestamp;
}

/// Posts a [PushNotificationPost].
typedef PushNotificationPoster = Future<void> Function(PushNotificationPost);

/// Builds and posts the notification for a data-only push: the decrypted text
/// when this phone's context opens the payload, otherwise the generic text
/// for the clear-text kind `k`. Data from anything but a MonkeySSH push is
/// ignored.
Future<void> showPushNotificationFromData(
  Map<String, dynamic> data, {
  PushNotificationContextStore store =
      const PlatformPushNotificationContextStore(),
  PushNotificationPoster? post,
}) async {
  final payload = data['p'];
  final clearKind = PushEventKind.tryParse(data['k']);
  if (data['v'] != '1' || payload is! String || payload.isEmpty) return;
  if (clearKind == null) return;
  final collapse = data['c'] is String ? data['c'] as String : payload;

  var kind = clearKind;
  var text = genericPushNotificationText(clearKind);
  var id = pushNotificationIdFor(collapse);
  var replaces = const <int>[];
  DateTime? timestamp;
  final event = await _openPayload(store, payload);
  if (event != null) {
    // A host's registration can still ask for a kind turned off while it
    // was out of reach; what the user turned off does not show.
    if (!event.allowed) return;
    kind = event.event.kind;
    text = pushNotificationText(event.event, hostLabel: event.hostLabel);
    timestamp = event.event.timestamp;
    final hostId = event.hostId;
    final session = event.event.sessionName;
    final window = event.event.windowId;
    if (hostId != null && session != null && window != null) {
      final request =
          kind == PushEventKind.permission || kind == PushEventKind.input;
      id = buildWindowNotificationId(hostId, session, window, request: request);
      // The bell the app raised for this request, before the program
      // reported it, is in the other slot.
      if (request) {
        replaces = [buildWindowNotificationId(hostId, session, window)];
      }
    }
  }
  await (post ?? _postWithPlugin)(
    PushNotificationPost(
      id: id,
      kind: kind,
      title: text.title,
      body: text.body,
      tapPayload: pushTapPayload(payload),
      timestamp: timestamp,
      replaces: replaces,
    ),
  );
}

Future<({PushEvent event, String? hostLabel, int? hostId, bool allowed})?>
_openPayload(PushNotificationContextStore store, String payload) async {
  try {
    final context = PushNotificationContext.decode(await store.read());
    if (context == null) return null;
    final device = await pushDeviceKeyPairFromSeed(context.seed);
    final plaintext = await openPushPayload(device: device, payload: payload);
    final event = plaintext == null ? null : PushEvent.tryParse(plaintext);
    if (event == null) return null;
    return (
      event: event,
      hostLabel: context.hosts[event.hostRef],
      hostId: context.hostIds[event.hostRef],
      allowed: context.allows(event),
    );
  } on Object {
    return null;
  }
}

/// A 31-bit notification id derived from [collapse] (FNV-1a), stable across
/// isolates and runs.
int pushNotificationIdFor(String collapse) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(collapse)) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

Future<void> _postWithPlugin(PushNotificationPost post) async {
  try {
    await installPushNotificationChannels();
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification_monkey'),
      ),
    );
    if (post.replaces.isNotEmpty) {
      try {
        final active = await plugin.getActiveNotifications();
        for (final id in localNotificationSlots(active, post.replaces)) {
          await plugin.cancel(id: id);
        }
      } on PlatformException {
        // Without the list, leave the other slot as it is.
      }
    }
    final attention = switch (post.kind) {
      PushEventKind.permission ||
      PushEventKind.input ||
      PushEventKind.test => true,
      PushEventKind.finished || PushEventKind.alert => false,
    };
    await plugin.show(
      id: post.id,
      title: post.title,
      body: post.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          attention ? pushAgentAttentionChannelId : pushAgentUpdatesChannelId,
          attention ? 'Agent attention' : 'Agent updates',
          importance: attention
              ? Importance.high
              : Importance.defaultImportance,
          priority: attention ? Priority.high : Priority.defaultPriority,
          icon: 'ic_notification_monkey',
          category: attention
              ? AndroidNotificationCategory.reminder
              : AndroidNotificationCategory.status,
          when: post.timestamp?.millisecondsSinceEpoch,
          showWhen: post.timestamp != null,
        ),
      ),
      payload: post.tapPayload,
    );
  } on MissingPluginException {
    // Tests run without platform plugins.
  }
}
