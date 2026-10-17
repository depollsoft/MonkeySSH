import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_permission_service.dart';
import '../diagnostics_log_service.dart';

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

  /// FCM or APNs did not register this app instance.
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

  /// Turns FCM auto-init on or off. Off means no registration until asked
  /// for.
  Future<void> setAutoInitEnabled({required bool enabled});

  /// Registers this app instance with FCM and returns its Firebase
  /// Installation ID (FID), which the function sends to. Contacts FCM.
  Future<String?> registerInstallation();

  /// Unregisters this app instance from FCM, so sends to its FID fail until
  /// it registers again.
  Future<void> unregisterInstallation();

  /// Unregisters from FCM and deletes the Firebase installation, so the next
  /// registration gets a new FID and tickets that seal the old one never
  /// deliver again.
  Future<void> deleteInstallation();

  /// Emits the FID each time FCM registers this app instance, including
  /// after the FID rotates.
  Stream<String> get onRegistered;

  /// Emits messages received while the app is in the foreground.
  Stream<PushRemoteMessage> get onMessage;

  /// Emits messages whose notification the user tapped.
  Stream<PushRemoteMessage> get onMessageOpenedApp;

  /// Returns the message whose notification launched the app, once.
  Future<PushRemoteMessage?> getInitialMessage();

  /// Calls `registerPushDevice` with an App Check token. With
  /// [appNotifications] the ticket says this app posts its own notifications
  /// from data-only messages, which builds before that could not show.
  Future<PushRegistration> register({
    required String fid,
    required String platform,
    String? deviceId,
    bool appNotifications = false,
  });
}

/// [PushMessagingGateway] backed by Firebase.
class FirebasePushMessagingGateway implements PushMessagingGateway {
  /// Creates the gateway. Nothing touches Firebase until a method is called.
  FirebasePushMessagingGateway({
    http.Client? httpClient,
    DiagnosticsLogger? diagnosticsLog,
    AppPermissionService permissions = const AppPermissionService(),
  }) : _httpClient = httpClient ?? http.Client(),
       _log = diagnosticsLog ?? DiagnosticsLogService.instance,
       _permissions = permissions;

  final http.Client _httpClient;
  final DiagnosticsLogger _log;
  final AppPermissionService _permissions;
  bool _appCheckActivated = false;

  static const _apnsTokenAttempts = 20;
  static const _apnsTokenPollInterval = Duration(milliseconds: 500);
  static const _registrationTimeout = Duration(seconds: 30);

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  Future<bool> requestPermission() async {
    // Android and iOS share the app's permissions channel with local
    // notifications. It asks iOS for the alerts, sounds and badges Firebase
    // asks for by default.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final status = await _permissions.request(AppPermission.notifications);
      return status.isGranted;
    }
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<void> setAutoInitEnabled({required bool enabled}) =>
      _messaging.setAutoInitEnabled(enabled);

  @override
  Future<String?> registerInstallation() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // FCM needs the APNs token first, which arrives asynchronously after
      // remote notification registration.
      for (var attempt = 0; attempt < _apnsTokenAttempts; attempt++) {
        if (await _messaging.getAPNSToken() != null) break;
        await Future<void>.delayed(_apnsTokenPollInterval);
      }
    }
    return registerForFid(
      _messaging.onRegistered,
      _messaging.register,
      timeout: _registrationTimeout,
    );
  }

  @override
  Future<void> unregisterInstallation() => _messaging.unregister();

  @override
  Future<void> deleteInstallation() async {
    // Deleting the installation is what retires the FID; unregistering first
    // only stops FCM sooner, and fails harmlessly when nothing is registered.
    try {
      await _messaging.unregister();
    } on Object catch (error) {
      _log.debug(
        'push',
        'fcm_unregister_skipped',
        fields: {'errorType': error.runtimeType},
      );
    }
    await FirebaseInstallations.instance.delete();
  }

  @override
  Stream<String> get onRegistered => _messaging.onRegistered;

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
    } on FirebaseException catch (error) {
      _log.warning(
        'push',
        'app_check_failed',
        fields: appCheckFailureFields(error),
      );
      throw const PushSetupException(PushSetupFailure.appCheckFailed);
    }
  }

  @override
  Future<PushRegistration> register({
    required String fid,
    required String platform,
    String? deviceId,
    bool appNotifications = false,
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
                pushRegistrationField(fid): fid,
                'platform': platform,
                'deviceId': ?deviceId,
                if (appNotifications) 'appNotifications': true,
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

/// The `registerPushDevice` field that carries [registration].
///
/// With FID registration on, Android devices whose Google Play services
/// predate it (before 26.12) still get a legacy registration token through
/// onRegistered. FCM tokens contain ":" and FIDs never do.
@visibleForTesting
String pushRegistrationField(String registration) =>
    registration.contains(':') ? 'token' : 'fid';

/// Calls [register] and returns the first FID [onRegistered] emits.
///
/// FCM hands the FID only to onRegistered, which it fires on every register()
/// call. The event can arrive before or after register() completes, so this
/// listens before asking and waits up to [timeout] afterwards.
@visibleForTesting
Future<String> registerForFid(
  Stream<String> onRegistered,
  Future<void> Function() register, {
  required Duration timeout,
}) async {
  final fid = Completer<String>();
  final subscription = onRegistered.listen((value) {
    if (!fid.isCompleted) fid.complete(value);
  });
  try {
    await register();
    return await fid.future.timeout(timeout);
  } finally {
    await subscription.cancel();
  }
}

/// Diagnostics fields for an App Check failure. The message is free text, so
/// only the error code and the numbers in it that name the cause are kept: a
/// Play Integrity error code (for example -16 for an unlinked Cloud project)
/// and the HTTP status the App Check token exchange returned.
@visibleForTesting
Map<String, Object> appCheckFailureFields(FirebaseException error) {
  final message = error.message ?? '';
  final integrityError = RegExp(r'Integrity API error \((-?\d+)\)')
      .firstMatch(message)
      ?.group(1);
  final httpStatus = RegExp(r'\bcode: (\d{3})\b').firstMatch(message)?.group(1);
  final code = error.code.replaceAll(RegExp('[^A-Za-z0-9_-]'), '');
  return {
    'code': code.length > 40 ? code.substring(0, 40) : code,
    'integrityError': ?int.tryParse(integrityError ?? ''),
    'httpStatus': ?int.tryParse(httpStatus ?? ''),
  };
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
