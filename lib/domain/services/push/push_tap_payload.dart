import 'dart:convert';

/// The payload a tapped push notification carries back to the app: the
/// encrypted payload, which the app opens as it opens an FCM tap.
String pushTapPayload(String encryptedPayload) =>
    jsonEncode({'type': 'monkeyssh-push', 'p': encryptedPayload});

/// The encrypted payload of a tapped push notification, or null when
/// [notificationPayload] belongs to another kind of notification.
String? decodePushTapPayload(String? notificationPayload) {
  if (notificationPayload == null || notificationPayload.isEmpty) return null;
  try {
    final decoded = jsonDecode(notificationPayload);
    if (decoded is Map<String, Object?> &&
        decoded['type'] == 'monkeyssh-push' &&
        decoded['p'] is String) {
      return decoded['p']! as String;
    }
  } on FormatException {
    return null;
  }
  return null;
}
