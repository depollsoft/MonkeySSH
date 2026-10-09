import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'app_permission_service.dart';
import 'diagnostics_log_service.dart';

/// Reads the current Wi-Fi SSID, where supported by the platform.
///
/// Returns `null` when the platform cannot report the SSID, when the device is
/// not on Wi-Fi, or when the necessary OS permissions have not been granted.
class WifiNetworkService {
  /// Creates a new [WifiNetworkService].
  WifiNetworkService({
    NetworkInfo? networkInfo,
    AppPermissionService permissions = const AppPermissionService(),
  }) : _networkInfo = networkInfo ?? NetworkInfo(),
       _permissions = permissions;

  final NetworkInfo _networkInfo;
  final AppPermissionService _permissions;

  /// Whether SSID detection is supported on the current platform at all.
  ///
  /// `network_info_plus` returns SSIDs on Android, iOS, macOS, Windows
  /// (via Win32 WLAN APIs), and Linux (via NetworkManager over D-Bus). Web
  /// is the only unsupported target and falls through to `null`.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  /// Whether SSID detection requires a runtime location-permission grant via
  /// [AppPermissionService] on the current platform.
  ///
  /// - **Android** requires `ACCESS_FINE_LOCATION` for `WifiManager` to
  ///   return the actual SSID.
  /// - **iOS** needs the location prompt to back the
  ///   `com.apple.developer.networking.wifi-info` entitlement.
  /// - **macOS** uses CoreLocation's first-use prompt natively, fired by
  ///   `network_info_plus` without an [AppPermissionService] round-trip.
  /// - **Windows** and **Linux** read from system services (Win32 WLAN /
  ///   NetworkManager) that don't require a per-app grant for read-only
  ///   SSID lookups.
  static bool get _requiresLocationPermission =>
      isSupported &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Result of a permission request, surfaced to the UI so it can guide the
  /// user to Settings when the OS has permanently denied access.
  ///
  /// A [PlatformException] reads as [WifiPermissionStatus.denied], so callers
  /// fall back to the jump host. A [MissingPluginException] propagates: it
  /// means the native channel was never registered, which is a build bug that
  /// would otherwise pass for a user's denial.
  Future<WifiPermissionStatus> requestPermission() async {
    if (!_requiresLocationPermission) {
      return WifiPermissionStatus.granted;
    }
    final AppPermissionStatus status;
    try {
      status = await _permissions.request(AppPermission.locationWhenInUse);
    } on PlatformException catch (error) {
      DiagnosticsLogService.instance.warning(
        'wifi.ssid',
        'permission_request_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      return WifiPermissionStatus.denied;
    }
    if (status == AppPermissionStatus.approximate) {
      return WifiPermissionStatus.approximate;
    }
    if (status.isGranted) {
      return WifiPermissionStatus.granted;
    }
    if (status.isPermanentlyDenied) {
      return WifiPermissionStatus.permanentlyDenied;
    }
    return WifiPermissionStatus.denied;
  }

  /// Returns the current Wi-Fi SSID, or `null` if unavailable.
  ///
  /// The raw value from the platform may be wrapped in quotes (`"my-ssid"`),
  /// which this method strips. Errors and missing permissions are swallowed
  /// and reported as `null` so callers can treat them as "not on a known
  /// network".
  Future<String?> getCurrentSsid() async {
    if (!isSupported) {
      return null;
    }
    try {
      final raw = await _networkInfo.getWifiName();
      return _normalizeSsid(raw);
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'wifi.ssid',
        'lookup_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  static String? _normalizeSsid(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    value = _stripInvisibleCharacters(value).trim();
    if (value.isEmpty) return null;
    // Some platforms return placeholder strings when permissions are missing.
    if (value == '<unknown ssid>' || value == '0x') return null;
    return value;
  }
}

/// Removes characters that render as nothing — ASCII control codes (0x00–0x1F,
/// 0x7F), C1 control codes (0x80–0x9F), zero-width and bidi format characters
/// (Unicode general category Cf in the BMP), variation selectors (FE00–FE0F),
/// the Mongolian vowel separator, the BOM, and the Unicode replacement
/// character. SSIDs containing only such characters would otherwise produce
/// blank chips in the editor and unmatchable storage values.
String _stripInvisibleCharacters(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune <= 0x1F || (rune >= 0x7F && rune <= 0x9F)) continue;
    if (rune == 0x00AD ||
        rune == 0x034F ||
        (rune >= 0x180B && rune <= 0x180E) ||
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x2028 && rune <= 0x202F) ||
        (rune >= 0x2060 && rune <= 0x206F) ||
        (rune >= 0xFE00 && rune <= 0xFE0F) ||
        rune == 0xFEFF ||
        rune == 0xFFFD ||
        (rune >= 0xE0000 && rune <= 0xE007F) ||
        (rune >= 0xE0100 && rune <= 0xE01EF)) {
      continue;
    }
    buffer.writeCharCode(rune);
  }
  final stripped = buffer.toString();
  // Final guard: require at least one Letter / Number / Punctuation / Symbol
  // rune. If everything left is whitespace or combining marks the chip would
  // still render blank, so treat the whole value as empty.
  if (!_visibleContent.hasMatch(stripped)) return '';
  return stripped;
}

final RegExp _visibleContent = RegExp(r'[\p{L}\p{N}\p{P}\p{S}]', unicode: true);

/// Provider for [WifiNetworkService].
final wifiNetworkServiceProvider = Provider<WifiNetworkService>(
  (ref) =>
      WifiNetworkService(permissions: ref.watch(appPermissionServiceProvider)),
);

/// Encodes a list of SSIDs to the storage format used in the Hosts table.
///
/// Newline-separated so SSIDs may legally contain commas, spaces, and most
/// other printable characters. Embedded `\n`/`\r` characters (which can sneak
/// in via paste) are stripped so they cannot corrupt the on-disk format.
String? encodeSkipJumpHostSsids(Iterable<String> ssids) {
  final cleaned = <String>[];
  final seen = <String>{};
  for (final ssid in ssids) {
    final sanitized = _sanitizeSsidForStorage(ssid);
    if (sanitized.isEmpty) continue;
    if (seen.add(sanitized)) {
      cleaned.add(sanitized);
    }
  }
  if (cleaned.isEmpty) return null;
  return cleaned.join('\n');
}

String _sanitizeSsidForStorage(String raw) =>
    _stripInvisibleCharacters(raw).trim();

/// Public helper used by UI code to normalize manual SSID entry to the same
/// rules the storage layer applies (strip invisibles + trim).
String sanitizeSsidInput(String raw) => _sanitizeSsidForStorage(raw);

/// Decodes the stored SSID list back into a list of unique entries.
///
/// Applies the same invisible-character stripping the encoder uses, so that
/// any pre-existing rows that contain control or zero-width characters
/// (e.g. SSIDs captured before the encoder hardening) come back clean.
List<String> decodeSkipJumpHostSsids(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final line in stored.split('\n')) {
    final sanitized = _sanitizeSsidForStorage(line);
    if (sanitized.isEmpty) continue;
    if (seen.add(sanitized)) {
      result.add(sanitized);
    }
  }
  return result;
}

/// Returns `true` if [currentSsid] is in the host's skip list.
///
/// The match is case-sensitive. Wi-Fi SSIDs are technically case-sensitive
/// at the 802.11 layer and the platform APIs return the exact bytes the
/// router advertises, so this preserves user intent (e.g. distinguishing
/// `home` from `Home` if a user really set up two networks).
bool shouldSkipJumpHostForSsid({
  required String? currentSsid,
  required String? skipJumpHostOnSsids,
}) {
  if (currentSsid == null) return false;
  final list = decodeSkipJumpHostSsids(skipJumpHostOnSsids);
  if (list.isEmpty) return false;
  return list.contains(currentSsid);
}

/// Outcome of a permission request, used by the UI to differentiate a
/// "tap again" denial from one that requires going to system Settings.
enum WifiPermissionStatus {
  /// Permission granted (or not required on this platform).
  granted,

  /// Permission was denied this time but can be re-requested.
  denied,

  /// Permission was permanently denied; user must change it in Settings.
  permanentlyDenied,

  /// Location is allowed only at approximate accuracy, which cannot read the
  /// SSID; the user must turn on precise location in Settings.
  approximate,
}
