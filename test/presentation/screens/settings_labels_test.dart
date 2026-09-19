import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';
import 'package:monkeyssh/presentation/screens/settings_labels.dart';

void main() {
  test('subscription labels distinguish free, subscribed, and lifetime', () {
    MonetizationState state(
      MonetizationEntitlements entitlements, {
      String? productId,
    }) => MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: entitlements,
      activeProductId: productId,
      offers: const [],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );
    expect(
      settingsSubscriptionLabel(state(const MonetizationEntitlements.free())),
      'Unlock transfers, automation, and agent launch presets',
    );
    expect(
      settingsSubscriptionLabel(state(const MonetizationEntitlements.pro())),
      'Unlocked on this device',
    );
    expect(
      settingsSubscriptionLabel(
        state(
          const MonetizationEntitlements.pro(),
          productId: MonetizationProductIds.iosProLifetimeProd,
        ),
      ),
      'Lifetime — unlocked on this device',
    );
  });
  test('auto-lock labels prioritize setup and pluralize the timeout', () {
    String label(int minutes, {bool known = true, bool configured = true}) =>
        settingsAutoLockLabel(
          isAuthKnown: known,
          isAuthConfigured: configured,
          autoLockTimeout: minutes,
        );
    expect(label(0, known: false), 'Checking security status');
    expect(label(1, configured: false), 'Set up app lock first');
    expect(label(0), 'Disabled');
    expect(label(1), '1 minute');
    expect(label(5), '5 minutes');
  });

  test('theme and cursor labels preserve unknown cursor values', () {
    expect(ThemeMode.values.map(settingsThemeModeLabel), [
      'System default',
      'Light',
      'Dark',
    ]);
    expect(
      ['block', 'underline', 'bar', 'custom'].map(settingsCursorStyleLabel),
      ['Block', 'Underline', 'Bar', 'custom'],
    );
  });
  test('biometric guidance follows security, hardware, and enrollment priority', () {
    String label({
      bool known = true,
      bool configured = true,
      bool hardware = true,
      bool device = true,
      bool enrolled = false,
    }) => settingsBiometricSubtitle(
      isAuthKnown: known,
      isAuthConfigured: configured,
      availability: BiometricAvailability(
        isDeviceAuthSupported: device,
        isBiometricHardwareSupported: hardware,
        enrolledBiometrics: enrolled ? [BiometricType.fingerprint] : [],
      ),
    );
    expect(label(known: false, hardware: false), 'Checking security status');
    expect(
      label(hardware: false),
      'Device lock is available, but no biometric hardware was reported',
    );
    expect(
      label(hardware: false, device: false),
      'Biometric hardware not supported on this device',
    );
    expect(
      label(configured: false),
      'Enroll fingerprint or face in system settings before enabling',
    );
    expect(label(configured: false, enrolled: true), 'Set up app lock first');
    expect(label(enrolled: true), 'Use fingerprint or face to unlock');
    expect(
      label(),
      'Enroll fingerprint or face in system settings, then return and re-check',
    );
  });
  test('telemetry availability takes precedence over the saved preference', () {
    for (final enabled in [false, true]) {
      expect(
        settingsTelemetrySubtitle(
          status: TelemetryServiceStatus.disabledByBuild,
          enabled: enabled,
        ),
        'Not available in this build.',
      );
      expect(
        settingsTelemetrySubtitle(
          status: TelemetryServiceStatus.unsupportedPlatform,
          enabled: enabled,
        ),
        'Not available on this platform.',
      );
      expect(
        settingsTelemetrySubtitle(
          status: TelemetryServiceStatus.initializationFailed,
          enabled: enabled,
        ),
        'Unavailable because Firebase could not initialize.',
      );
    }
    expect(
      settingsTelemetrySubtitle(
        status: TelemetryServiceStatus.ready,
        enabled: false,
      ),
      'Off. When on, MonkeySSH shares anonymous feature usage and sanitized crash reports.',
    );
    expect(
      settingsTelemetrySubtitle(
        status: TelemetryServiceStatus.ready,
        enabled: true,
      ),
      'On. Never includes hostnames, usernames, commands, terminal output, paths, clipboard, or credentials.',
    );
  });
  test('version label handles loading, errors, and metadata', () {
    expect(settingsVersionLabel(const AsyncLoading()), 'Loading...');
    expect(
      settingsVersionLabel(AsyncError(Exception('metadata'), StackTrace.empty)),
      'Unavailable',
    );
    expect(
      settingsVersionLabel(
        const AsyncData(
          AppMetadata(appName: 'MonkeySSH', version: '2.0', buildNumber: '42'),
        ),
      ),
      '2.0 (42)',
    );
  });
}
