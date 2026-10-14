import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../data/repositories/host_repository.dart';
import 'push_crypto.dart';

/// What the phone needs to show a push while MonkeySSH is not running: the
/// device's private key, to open the payload, and each saved host's label by
/// the reference its payloads carry. It never leaves the device.
@immutable
class PushNotificationContext {
  /// Creates a context.
  const PushNotificationContext({required this.seed, required this.hosts});

  /// The device's 32-byte X25519 private key.
  final Uint8List seed;

  /// Saved host labels by host reference.
  final Map<String, String> hosts;

  /// The stored form, shared with the iOS notification service extension:
  /// `{"v":1,"seed":"<base64url>","hosts":{"<hostRef>":"<label>"}}`.
  String encode() =>
      jsonEncode({'v': 1, 'seed': encodePushBase64(seed), 'hosts': hosts});

  /// Parses [encoded], or returns null when it is missing or malformed.
  static PushNotificationContext? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?> || decoded['v'] != 1) return null;
      final seed = decodePushBase64(decoded['seed'] as String? ?? '');
      final hosts = decoded['hosts'];
      if (seed == null || seed.length != 32 || hosts is! Map) return null;
      return PushNotificationContext(
        seed: seed,
        hosts: {
          for (final MapEntry(:key, :value) in hosts.entries)
            if (key is String && value is String) key: value,
        },
      );
    } on Object {
      return null;
    }
  }
}

/// Where the [PushNotificationContext] lives.
abstract interface class PushNotificationContextStore {
  /// Stores [encoded] (see [PushNotificationContext.encode]).
  Future<void> write(String encoded);

  /// Reads the stored context, or null.
  Future<String?> read();

  /// Removes the stored context.
  Future<void> delete();
}

/// The platform store. Android keeps the context in secure storage, which the
/// background message handler reads. iOS hands it to the app's native code,
/// which keeps it in a keychain group the notification service extension
/// shares. Elsewhere nothing is stored.
class PlatformPushNotificationContextStore
    implements PushNotificationContextStore {
  /// Creates the store.
  const PlatformPushNotificationContextStore();

  /// Secure-storage key on Android.
  static const androidKey = 'monkeyssh_push_notify_v1';

  static const _storage = FlutterSecureStorage();
  static const _channel = MethodChannel(
    'xyz.depollsoft.monkeyssh/push_notification_context',
  );

  @override
  Future<void> write(String encoded) async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        await _storage.write(key: androidKey, value: encoded);
      case TargetPlatform.iOS:
        await _channel.invokeMethod<bool>('write', {'json': encoded});
      default:
        return;
    }
  }

  @override
  Future<String?> read() async =>
      defaultTargetPlatform == TargetPlatform.android
      ? _storage.read(key: androidKey)
      : null;

  @override
  Future<void> delete() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        await _storage.delete(key: androidKey);
      case TargetPlatform.iOS:
        await _channel.invokeMethod<void>('delete');
      default:
        return;
    }
  }
}

/// The store the push controller writes the notification context to.
final pushNotificationContextStoreProvider =
    Provider<PushNotificationContextStore>(
      (ref) => const PlatformPushNotificationContextStore(),
    );

/// Saved host labels by host id, read when the context is refreshed.
final pushHostLabelsProvider = Provider<Future<Map<int, String>> Function()>(
  (ref) =>
      () async => {
        for (final host in await ref.read(hostRepositoryProvider).getAll())
          host.id: host.label,
      },
);
