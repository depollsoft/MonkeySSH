import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runtime permissions the app asks for through its own platform channel.
///
/// The native handlers live in `AppPermissionsPlugin.swift` (iOS) and
/// `AppPermissionsPlugin.kt` (Android). Only these three are implemented;
/// adding one means adding it on both sides and declaring it in the Android
/// manifest and the iOS `Info.plist`.
enum AppPermission {
  /// Camera capture (`AVMediaType.video` / `android.permission.CAMERA`).
  camera,

  /// Microphone capture (`AVMediaType.audio` /
  /// `android.permission.RECORD_AUDIO`).
  microphone,

  /// Foreground location (`requestWhenInUseAuthorization` /
  /// `ACCESS_COARSE_LOCATION` plus `ACCESS_FINE_LOCATION`).
  locationWhenInUse,
}

/// The outcome of a permission request.
enum AppPermissionStatus {
  /// The app holds the permission.
  granted,

  /// [AppPermission.locationWhenInUse] only: the app holds location at
  /// approximate accuracy (Android "Approximate", iOS Precise Location off).
  /// That serves a web page asking for location but cannot read the Wi-Fi
  /// SSID, and only the app's system settings can turn on precise location.
  approximate,

  /// The user declined or dismissed the prompt; asking again can show it.
  denied,

  /// The OS will not prompt again; only the app's system settings can grant
  /// it.
  permanentlyDenied,

  /// A device policy (parental controls, MDM) blocks the permission, so
  /// neither a prompt nor the app's settings can grant it.
  restricted;

  /// Whether the app holds the permission at any accuracy.
  bool get isGranted =>
      this == AppPermissionStatus.granted ||
      this == AppPermissionStatus.approximate;

  /// Whether only the app's system settings can grant the permission.
  bool get isPermanentlyDenied => this == AppPermissionStatus.permanentlyDenied;
}

/// Requests runtime permissions over the `xyz.depollsoft.monkeyssh/permissions`
/// channel and opens the app's system settings page.
///
/// Implemented on iOS and Android. On other platforms the channel has no
/// handler and calls throw [MissingPluginException].
class AppPermissionService {
  /// Creates an [AppPermissionService] backed by [channel].
  const AppPermissionService({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  /// Name of the platform channel the native handlers listen on.
  static const channelName = 'xyz.depollsoft.monkeyssh/permissions';

  final MethodChannel _channel;

  /// Returns the status of [permission], prompting the user first when the OS
  /// still allows a prompt.
  ///
  /// A status the native side does not recognise reads as
  /// [AppPermissionStatus.denied], so a malformed reply never grants access.
  Future<AppPermissionStatus> request(AppPermission permission) async {
    final status = await _channel.invokeMethod<Object?>(
      'request',
      permission.name,
    );
    return AppPermissionStatus.values.asNameMap()[status] ??
        AppPermissionStatus.denied;
  }

  /// Opens this app's page in the system settings, returning whether the OS
  /// accepted the request.
  Future<bool> openAppSettings() async =>
      await _channel.invokeMethod<Object?>('openAppSettings') == true;
}

/// Provider for [AppPermissionService].
final appPermissionServiceProvider = Provider<AppPermissionService>(
  (ref) => const AppPermissionService(),
);
