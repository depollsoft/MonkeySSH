// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_metadata.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/telemetry_service.dart';

String settingsThemeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
  ThemeMode.system => 'System default',
};

String settingsBiometricSubtitle({
  required bool isAuthKnown,
  required bool isAuthConfigured,
  required BiometricAvailability availability,
}) {
  if (!isAuthKnown) {
    return 'Checking security status';
  }
  if (!availability.isBiometricHardwareSupported) {
    return availability.isDeviceAuthSupported
        ? 'Device lock is available, but no biometric hardware was reported'
        : 'Biometric hardware not supported on this device';
  }
  if (!isAuthConfigured) {
    return availability.needsBiometricEnrollment
        ? 'Enroll fingerprint or face in system settings before enabling'
        : 'Set up app lock first';
  }
  if (availability.canAuthenticateWithBiometrics) {
    return 'Use fingerprint or face to unlock';
  }
  return 'Enroll fingerprint or face in system settings, then return and re-check';
}

String settingsTelemetrySubtitle({
  required TelemetryServiceStatus status,
  required bool enabled,
}) {
  if (status != TelemetryServiceStatus.ready) {
    return switch (status) {
      TelemetryServiceStatus.disabledByBuild => 'Not available in this build.',
      TelemetryServiceStatus.unsupportedPlatform =>
        'Not available on this platform.',
      TelemetryServiceStatus.initializationFailed =>
        'Unavailable because Firebase could not initialize.',
      TelemetryServiceStatus.ready => '',
    };
  }
  if (!enabled) {
    return 'Off. When on, MonkeySSH shares anonymous feature usage and sanitized crash reports.';
  }
  return 'On. Never includes hostnames, usernames, commands, terminal output, paths, clipboard, or credentials.';
}

String settingsCursorStyleLabel(String style) => switch (style) {
  'block' => 'Block',
  'underline' => 'Underline',
  'bar' => 'Bar',
  _ => style,
};

String settingsVersionLabel(AsyncValue<AppMetadata> appMetadata) =>
    appMetadata.when(
      data: (value) => value.versionLabel,
      loading: () => 'Loading...',
      error: (_, _) => 'Unavailable',
    );

String settingsSubscriptionLabel(MonetizationState state) => state.isProUnlocked
    ? state.isLifetimeUnlocked
          ? 'Lifetime — unlocked on this device'
          : 'Unlocked on this device'
    : 'Unlock transfers, automation, and agent launch presets';

String settingsAutoLockLabel({
  required bool isAuthKnown,
  required bool isAuthConfigured,
  required int autoLockTimeout,
}) => !isAuthKnown
    ? 'Checking security status'
    : isAuthConfigured
    ? autoLockTimeout == 0
          ? 'Disabled'
          : '$autoLockTimeout minute${autoLockTimeout == 1 ? '' : 's'}'
    : 'Set up app lock first';
