import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Region the push functions are deployed to.
const pushFunctionsRegion = 'us-central1';

/// A push message reduced to what the app reads.
@immutable
class PushRemoteMessage {
  /// Creates a message.
  const PushRemoteMessage({required this.data});

  /// FCM data: `v` and the encrypted payload `p`.
  final Map<String, Object?> data;

  /// The encrypted payload, when this is a MonkeySSH push.
  String? get encryptedPayload {
    final payload = data['p'];
    return data['v'] == '1' && payload is String && payload.isNotEmpty
        ? payload
        : null;
  }
}

/// What `registerPushDevice` returned.
@immutable
class PushRegistration {
  /// Creates a registration.
  const PushRegistration({required this.deviceId, required this.ticket});

  /// Stable device id assigned by the function.
  final String deviceId;

  /// Sealed ticket that hosts send back to the function.
  final String ticket;
}

/// Why a push setup step failed. Carries no server or user text.
enum PushSetupFailure {
  /// The user declined notification permission.
  permissionDenied,

  /// FCM or APNs did not issue a token.
  tokenUnavailable,

  /// App Check could not attest this app.
  appCheckFailed,

  /// The registration function failed or rejected the request.
  registrationFailed,
}

/// Thrown by [PushMessagingGateway] with a coarse [failure].
class PushSetupException implements Exception {
  /// Creates an exception.
  const PushSetupException(this.failure);

  /// What went wrong.
  final PushSetupFailure failure;

  @override
  String toString() => 'PushSetupException(${failure.name})';
}

/// Seam over Firebase Messaging, App Check and the registration callable.
abstract interface class PushMessagingGateway {
  /// Asks the user for notification permission.
  Future<bool> requestPermission();

  /// Turns FCM auto-init on or off. Off means no token until asked for.
  Future<void> setAutoInitEnabled({required bool enabled});

  /// Returns the FCM token, contacting FCM.
  Future<String?> getToken();

  /// Deletes the FCM token.
  Future<void> deleteToken();

  /// Emits refreshed FCM tokens.
  Stream<String> get onTokenRefresh;

  /// Emits messages received while the app is in the foreground.
  Stream<PushRemoteMessage> get onMessage;

  /// Emits messages whose notification the user tapped.
  Stream<PushRemoteMessage> get onMessageOpenedApp;

  /// Returns the message whose notification launched the app, once.
  Future<PushRemoteMessage?> getInitialMessage();

  /// Calls `registerPushDevice` with an App Check token.
  Future<PushRegistration> register({
    required String token,
    required String platform,
    String? deviceId,
  });
}

/// [PushMessagingGateway] backed by Firebase.
class FirebasePushMessagingGateway implements PushMessagingGateway {
  /// Creates the gateway. Nothing touches Firebase until a method is called.
  FirebasePushMessagingGateway({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  bool _appCheckActivated = false;

  static const _apnsTokenAttempts = 20;
  static const _apnsTokenPollInterval = Duration(milliseconds: 500);

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<void> setAutoInitEnabled({required bool enabled}) =>
      _messaging.setAutoInitEnabled(enabled);

  @override
  Future<String?> getToken() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // FCM needs the APNs token first, which arrives asynchronously after
      // remote notification registration.
      for (var attempt = 0; attempt < _apnsTokenAttempts; attempt++) {
        if (await _messaging.getAPNSToken() != null) break;
        await Future<void>.delayed(_apnsTokenPollInterval);
      }
    }
    return _messaging.getToken();
  }

  @override
  Future<void> deleteToken() => _messaging.deleteToken();

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<PushRemoteMessage> get onMessage =>
      FirebaseMessaging.onMessage.map(_toMessage);

  @override
  Stream<PushRemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map(_toMessage);

  @override
  Future<PushRemoteMessage?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _toMessage(message);
  }

  static PushRemoteMessage _toMessage(RemoteMessage message) =>
      PushRemoteMessage(data: Map<String, Object?>.from(message.data));

  Future<String> _appCheckToken() async {
    try {
      if (!_appCheckActivated) {
        await FirebaseAppCheck.instance.activate(
          providerAndroid: kDebugMode
              ? const AndroidDebugProvider()
              : const AndroidPlayIntegrityProvider(),
          providerApple: kDebugMode
              ? const AppleDebugProvider()
              : const AppleAppAttestWithDeviceCheckFallbackProvider(),
        );
        // Only fetch tokens when registering, never in the background.
        await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(false);
        _appCheckActivated = true;
      }
      // A limited-use token is consumed by the function, so a captured one
      // cannot be replayed to mint more tickets.
      final token = await FirebaseAppCheck.instance.getLimitedUseToken();
      if (token.isEmpty) {
        throw const PushSetupException(PushSetupFailure.appCheckFailed);
      }
      return token;
    } on FirebaseException {
      throw const PushSetupException(PushSetupFailure.appCheckFailed);
    }
  }

  @override
  Future<PushRegistration> register({
    required String token,
    required String platform,
    String? deviceId,
  }) async {
    final appCheckToken = await _appCheckToken();
    final projectId = Firebase.app().options.projectId;
    final uri = Uri.https(
      '$pushFunctionsRegion-$projectId.cloudfunctions.net',
      '/registerPushDevice',
    );
    final http.Response response;
    try {
      response = await _httpClient
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'X-Firebase-AppCheck': appCheckToken,
            },
            body: jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'token': token,
                'platform': platform,
                'deviceId': ?deviceId,
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on Object {
      throw const PushSetupException(PushSetupFailure.registrationFailed);
    }
    return parsePushRegistrationResponse(response.statusCode, response.body);
  }
}

/// Parses the callable protocol response from `registerPushDevice`.
@visibleForTesting
PushRegistration parsePushRegistrationResponse(int statusCode, String body) {
  if (statusCode != 200) {
    throw const PushSetupException(PushSetupFailure.registrationFailed);
  }
  try {
    final decoded = jsonDecode(body);
    final result = decoded is Map<String, Object?> ? decoded['result'] : null;
    if (result is Map<String, Object?>) {
      final deviceId = result['deviceId'];
      final ticket = result['ticket'];
      if (deviceId is String &&
          deviceId.isNotEmpty &&
          ticket is String &&
          ticket.startsWith('v1.')) {
        return PushRegistration(deviceId: deviceId, ticket: ticket);
      }
    }
  } on FormatException {
    // Fall through.
  }
  throw const PushSetupException(PushSetupFailure.registrationFailed);
}
