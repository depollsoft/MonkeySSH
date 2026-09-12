import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

void main() {
  group('absorbed crash reporting', () {
    late Duration elapsed;
    late AbsorbedErrorRateLimiter limiter;
    late _FakeCrashReporter reporter;
    late TelemetryService service;

    setUp(() {
      elapsed = Duration.zero;
      limiter = AbsorbedErrorRateLimiter(elapsed: () => elapsed);
      reporter = _FakeCrashReporter();
      service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _FakeAnalyticsClient(),
        crashReporter: reporter,
        absorbedErrorRateLimiter: limiter,
      );
    });

    test('allows three per type, then one per ten minutes without a reset', () {
      expect(List.generate(4, (_) => limiter.shouldRecord(StateError)), [
        true,
        true,
        true,
        false,
      ]);
      expect(limiter.shouldRecord(SocketException), isTrue);
      elapsed = const Duration(minutes: 9, seconds: 59);
      expect(limiter.shouldRecord(StateError), isFalse);
      elapsed = const Duration(minutes: 10);
      expect(limiter.shouldRecord(StateError), isTrue);
      expect(limiter.shouldRecord(StateError), isFalse);
      elapsed = const Duration(hours: 1);
      expect(limiter.shouldRecord(StateError), isTrue);
      expect(limiter.shouldRecord(StateError), isFalse);
    });

    test(
      'retry storms retain stacks, stay non-fatal, and do not limit bugs',
      () async {
        final stack = StackTrace.fromString(
          '#0 SSHTransport.sendPacket (package:dartssh2/src/ssh_transport.dart:1:2)\n'
          '#1 SshSession.execute (package:monkeyssh/domain/services/ssh_service.dart:42:5)',
        );
        await Future.wait(
          List.generate(
            100,
            (_) => service.recordError(
              SSHStateError('Transport is closed'),
              stack,
              fatal: true,
              absorbed: true,
            ),
          ),
        );
        expect(reporter.recordedErrors, hasLength(3));
        for (final report in reporter.recordedErrors) {
          expect(report.fatal, isFalse);
          expect(report.stackTrace, same(stack));
          expect(report.keys['error_absorbed'], isTrue);
          expect(report.keys['error_type'], 'SSHStateError');
          expect(
            report.keys['top_app_frame'],
            'SshSession.execute (package:monkeyssh/domain/services/ssh_service.dart:42:5)',
          );
          expect(report.reason, 'SSHStateError: Transport is closed');
        }
        elapsed = const Duration(minutes: 10);
        await service.recordError(
          SSHStateError('Transport is closed'),
          stack,
          fatal: false,
          absorbed: true,
        );
        expect(reporter.recordedErrors, hasLength(4));
        await Future.wait(
          List.generate(
            5,
            (_) => service.recordError(StateError('bug'), stack, fatal: true),
          ),
        );
        expect(reporter.recordedErrors.skip(4).every((e) => e.fatal), isTrue);
        expect(reporter.recordedErrors, hasLength(9));
      },
    );

    test(
      'opt-out neither reports nor consumes the initial allowance',
      () async {
        await service.setCollectionEnabled(enabled: false);
        for (var i = 0; i < 5; i++) {
          await service.recordError(
            SSHStateError('Transport is closed'),
            StackTrace.empty,
            fatal: false,
            absorbed: true,
          );
        }
        expect(reporter.recordedErrors, isEmpty);
        expect(reporter.customKeys, isEmpty);
        await service.setCollectionEnabled(enabled: true);
        for (var i = 0; i < 4; i++) {
          await service.recordError(
            SSHStateError('Transport is closed'),
            StackTrace.empty,
            fatal: false,
            absorbed: true,
          );
        }
        expect(reporter.recordedErrors, hasLength(3));
        expect(reporter.customKeys, containsPair('flutter_mode', 'debug'));
        expect(reporter.customKeys, contains('platform'));
        expect(reporter.customKeys, contains('diagnostics_enabled'));
      },
    );

    test(
      'concurrent reports keep their own keys and reset missing frames',
      () async {
        await Future.wait([
          service.recordError(
            SSHStateError('Transport is closed'),
            StackTrace.fromString(
              '#0 SshSession.close (package:monkeyssh/domain/services/ssh_service.dart:20:3)',
            ),
            fatal: false,
            absorbed: true,
          ),
          service.recordError(
            ArgumentError('private'),
            StackTrace.empty,
            fatal: true,
          ),
        ]);
        expect(reporter.recordedErrors[0].keys['error_type'], 'SSHStateError');
        expect(reporter.recordedErrors[0].keys['error_absorbed'], isTrue);
        expect(reporter.recordedErrors[1].keys['error_type'], 'ArgumentError');
        expect(reporter.recordedErrors[1].keys['error_absorbed'], isFalse);
        expect(reporter.recordedErrors[1].keys['top_app_frame'], 'unknown');
      },
    );

    test('Flutter reports retain safe reason, stack, and exception key', () async {
      final stack = StackTrace.fromString(
        '#0 build (package:monkeyssh/presentation/screens/home_screen.dart:20:3)',
      );
      await service.recordFlutterError(
        FlutterErrorDetails(
          exception: StateError('Stream has already been listened to.\nsecret'),
          stack: stack,
          library: 'private library',
          context: ErrorDescription('password=hunter2'),
        ),
      );
      final report = reporter.recordedFlutterErrors.single;
      expect(report.stack, same(stack));
      expect(
        report.context.toString(),
        'StateError: Stream has already been listened to [redacted]',
      );
      expect(report.library, 'flutter');
      expect(reporter.customKeys['flutter_error_exception'], 'StateError');
      expect(reporter.customKeys['error_absorbed'], isFalse);
      expect(
        reporter.customKeys['top_app_frame'],
        'build (package:monkeyssh/presentation/screens/home_screen.dart:20:3)',
      );
    });

    test(
      'reason keeps known failure text but redacts all dynamic contents',
      () {
        const secrets =
            'alice@secret.example.com 192.0.2.4 [2001:db8::1] '
            '/home/alice/id_rsa key.pem password=hunter2 token=abcd '
            'ssh user@host clipboard-content -----BEGIN PRIVATE KEY-----';
        final error = SanitizedTelemetryError.from(
          const SocketException(
            'Connection reset by peer $secrets\nmore-private-data',
          ),
        );
        expect(
          error.reason,
          'SocketException: Connection reset by peer [redacted]',
        );
        expect(
          SanitizedTelemetryError.from(Exception(secrets)).reason,
          'Exception: [redacted]',
        );
        expect(
          SanitizedTelemetryError.from(
            Exception('secret\nPermission denied'),
          ).reason,
          'Exception: [redacted]',
        );
        expect(
          SanitizedTelemetryError.from(_ThrowingToStringError()).reason,
          'ThrowingToStringError: [unavailable]',
        );
        expect(
          SanitizedTelemetryError.from(SSHChannelOpenError(1, secrets)).reason,
          'SSHChannelOpenError: code 1: [redacted]',
        );
        expect(
          SanitizedTelemetryError.from(SSHChannelOpenError(4, secrets)).reason,
          'SSHChannelOpenError: code 4: [redacted]',
        );
        expect(
          SanitizedTelemetryError.from(
            SftpStatusError(
              SftpStatusCode.permissionDenied,
              'Permission denied $secrets',
            ),
          ).reason,
          'SftpStatusError: code 3: Permission denied [redacted]',
        );
      },
    );

    test('default rate limit is shared across service instances', () async {
      for (var i = 0; i < 5; i++) {
        final telemetry = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          crashReporter: reporter,
        );
        await telemetry.recordError(
          const _CustomTelemetryException(),
          StackTrace.empty,
          fatal: false,
          absorbed: true,
        );
      }
      expect(reporter.recordedErrors, hasLength(3));
    });

    test('top app frame ignores filesystem paths and reporter frames', () async {
      await service.recordError(
        StateError('bug'),
        StackTrace.fromString(
          '#0 privateFunction (file:///home/alice/private.dart:1:2)\n'
          '#1 TelemetryService.recordError (package:monkeyssh/domain/services/telemetry_service.dart:1:2)\n'
          '#2 installTelemetryErrorHandlers.<anonymous closure> (package:monkeyssh/main.dart:1:2)',
        ),
        fatal: true,
      );
      expect(reporter.recordedErrors.single.keys['top_app_frame'], 'unknown');
    });

    test('metadata failure does not prevent submitting the report', () async {
      final failingReporter = _FailingMetadataCrashReporter();
      final telemetry = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        crashReporter: failingReporter,
      );
      await telemetry.recordError(
        StateError('bug'),
        StackTrace.empty,
        fatal: true,
      );
      expect(failingReporter.recordedErrors, hasLength(1));
    });

    test(
      'opt-out during metadata cancels current and queued reports',
      () async {
        final delayed = _DelayedMetadataCrashReporter();
        final telemetry = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: _FakeAnalyticsClient(),
          crashReporter: delayed,
        );
        final first = telemetry.recordError(
          StateError('bug'),
          StackTrace.empty,
          fatal: true,
        );
        final second = telemetry.recordError(
          ArgumentError('bug'),
          StackTrace.empty,
          fatal: true,
        );
        await delayed.started.future;
        await telemetry.setCollectionEnabled(enabled: false);
        delayed.finish.complete();
        await Future.wait([first, second]);
        expect(delayed.recordedErrors, isEmpty);
        expect(delayed.deleteUnsentReportsCount, 1);
      },
    );
  });

  group('TelemetryService', () {
    test('does not send analytics until collection is enabled', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logFeatureOpened(feature: 'terminal');
      await service.setCollectionEnabled(enabled: true);
      await service.logFeatureOpened(feature: 'terminal');

      expect(analytics.events, hasLength(1));
      expect(analytics.events.single.name, 'feature_opened');
      expect(analytics.events.single.parameters, {'feature': 'terminal'});
    });

    test('disabling collection clears analytics data', () async {
      final analytics = _FakeAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: crashReporter,
      );

      await service.setCollectionEnabled(enabled: false);

      expect(analytics.collectionEnabled, isFalse);
      expect(analytics.resetCount, 1);
      expect(crashReporter.collectionEnabled, isFalse);
      expect(crashReporter.deleteUnsentReportsCount, 1);
    });

    test(
      'does not reset analytics when collection is already disabled',
      () async {
        final analytics = _FakeAnalyticsClient();
        final crashReporter = _FakeCrashReporter();
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: false,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: crashReporter,
        );

        await service.setCollectionEnabled(enabled: false);

        expect(analytics.collectionEnabled, isFalse);
        expect(analytics.resetCount, 0);
        expect(crashReporter.collectionEnabled, isFalse);
        expect(crashReporter.deleteUnsentReportsCount, 0);
      },
    );

    test('overlapping consent updates leave both SDKs opted out', () async {
      final analytics = _DelayedAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: crashReporter,
      );

      final enable = service.setCollectionEnabled(enabled: true);
      await analytics.enableStarted.future;
      final disable = service.setCollectionEnabled(enabled: false);
      await service.logFeatureOpened(feature: 'terminal');
      expect(service.collectionEnabled, isFalse);
      expect(analytics.events, isEmpty);

      // Let the disable call progress before the older enable finishes.
      await Future<void>.delayed(Duration.zero);
      analytics.finishEnable.complete();
      await Future.wait([enable, disable]);

      expect(analytics.collectionEnabled, isFalse);
      expect(crashReporter.collectionEnabled, isFalse);
      expect(analytics.resetCount, 1);
      expect(crashReporter.deleteUnsentReportsCount, 1);
    });

    test('swallows SDK failures while updating collection state', () async {
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _ThrowingAnalyticsClient(),
        crashReporter: crashReporter,
      );

      await service.setCollectionEnabled(enabled: false);

      expect(service.collectionEnabled, isFalse);
      expect(crashReporter.collectionEnabled, isFalse);
      expect(crashReporter.deleteUnsentReportsCount, 1);
    });

    test('swallows SDK failures while logging analytics events', () async {
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _ThrowingAnalyticsClient(),
        crashReporter: _FakeCrashReporter(),
      );

      await service.logFeatureOpened(feature: 'terminal');
    });

    test('sanitizes and allowlists event parameter values', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logFeatureOpened(feature: 'terminal');
      await service.logFeatureOpened(feature: 'Host: /secret.example.com');
      await service.logPaywallShown(
        feature: 'agentLaunchPresets',
        source: 'feature_gate',
      );

      expect(analytics.events[0].parameters, {'feature': 'terminal'});
      expect(analytics.events[1].parameters, {'feature': 'unknown'});
      expect(analytics.events[2].parameters, {
        'feature': 'agent_launch_presets',
        'source': 'feature_gate',
      });
      await service.logPaywallShown(
        feature: 'agentManagement',
        source: 'feature_gate',
      );
      expect(analytics.events[3].parameters, {
        'feature': 'agent_management',
        'source': 'feature_gate',
      });
      await service.logPaywallShown(
        feature: 'agentUsageRings',
        source: 'feature_gate',
      );
      expect(analytics.events[4].parameters, {
        'feature': 'agent_usage_rings',
        'source': 'feature_gate',
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.logAppStarted(
        appMetadata: const AppMetadata(
          appName: 'MonkeySSH',
          version: '1',
          buildNumber: '1',
        ),
      );
      expect(analytics.events.last.name, 'app_started');
      expect(analytics.events.last.parameters['platform'], 'i_os');
    });

    test('logs connection funnel with coarse buckets', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logConnectionAttempted(
        authMethod: 'key',
        usesJumpHost: true,
      );
      await service.logConnectionSucceeded(
        authMethod: 'key',
        usesJumpHost: true,
        duration: const Duration(seconds: 8),
      );
      await service.logConnectionFailed(
        authMethod: 'password',
        usesJumpHost: false,
        duration: const Duration(seconds: 61),
        failureCategory: 'timeout',
      );

      expect(analytics.events.map((event) => event.name), [
        'connection_attempted',
        'connection_succeeded',
        'connection_failed',
      ]);
      expect(analytics.events[1].parameters['duration_bucket'], '5_14s');
      expect(analytics.events[2].parameters['duration_bucket'], '1_4m');
      expect(analytics.events[2].parameters['failure_category'], 'timeout');
    });

    test('logs transfer and interaction events without raw content', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logSftpTransferCompleted(
        direction: 'upload',
        fileCount: 6,
        sizeBytes: 12 * 1024 * 1024,
        duration: const Duration(seconds: 42),
      );
      await service.logTerminalPasteUsed(
        source: 'clipboard_text',
        requiredReview: true,
      );
      await service.logKeyboardToolbarKeyPressed(hasModifier: true);

      expect(analytics.events[0].name, 'sftp_transfer_completed');
      expect(analytics.events[0].parameters['file_count_bucket'], '6_20');
      expect(analytics.events[0].parameters['size_bucket'], '10_99mb');
      expect(analytics.events[0].parameters['duration_bucket'], '15_59s');
      expect(analytics.events[1].parameters, {
        'source': 'clipboard_text',
        'required_review': 1,
      });
      expect(analytics.events[2].parameters, {'has_modifier': 1});
    });

    test(
      'logs mux agent and monetization events with allowlisted values',
      () async {
        final analytics = _FakeAnalyticsClient();
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: _FakeCrashReporter(),
        );

        await service.logMuxNavigatorOpened(backend: 'tmux', windowCount: 21);
        await service.logAgentSessionsDetected(
          tool: 'codex',
          sessionCount: 2,
          failed: false,
        );
        await service.logPurchaseFailed(
          productType: 'annual',
          failureCategory: 'cancelled',
        );

        expect(analytics.events[0].parameters['window_count_bucket'], 'gt_20');
        expect(analytics.events[1].parameters, {
          'tool': 'codex',
          'session_count_bucket': '2_5',
          'failed': 0,
        });
        expect(analytics.events[2].parameters, {
          'product_type': 'annual',
          'failure_category': 'cancelled',
        });
      },
    );

    test('records sanitized crash errors when collection is enabled', () async {
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _FakeAnalyticsClient(),
        crashReporter: crashReporter,
      );

      await service.recordError(
        ArgumentError('host secret.example.com'),
        StackTrace.current,
        fatal: true,
      );

      expect(crashReporter.recordedErrors, hasLength(1));
      expect(
        crashReporter.recordedErrors.single.error.toString(),
        'ArgumentError',
      );
      expect(
        crashReporter.recordedErrors.single.error.toString(),
        isNot(contains('secret.example.com')),
      );
      expect(crashReporter.recordedErrors.single.fatal, isTrue);
    });

    test(
      'preserves sanitized custom error type names for crash grouping',
      () async {
        final crashReporter = _FakeCrashReporter();
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: _FakeAnalyticsClient(),
          crashReporter: crashReporter,
        );

        await service.recordError(
          const _CustomTelemetryException(),
          StackTrace.current,
          fatal: false,
        );

        expect(
          crashReporter.recordedErrors.single.error.toString(),
          'CustomTelemetryException',
        );
      },
    );

    test('does not record crashes when unavailable', () async {
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.disabledByBuild,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        crashReporter: crashReporter,
      );

      await service.recordFlutterError(
        FlutterErrorDetails(exception: StateError('private details')),
      );

      expect(crashReporter.recordedFlutterErrors, isEmpty);
    });

    group('ACP telemetry allowlist', () {
      late _FakeAnalyticsClient analytics;
      late TelemetryService service;

      setUp(() {
        analytics = _FakeAnalyticsClient();
        service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: _FakeCrashReporter(),
        );
      });

      test('allowlists provider category and reconnect flags', () async {
        await service.logAcpSessionOpened(
          providerCategory: 'copilot_cli',
          isReconnect: true,
        );
        await service.logAcpSessionOpened(
          providerCategory: 'a-custom-user-typed-command',
          isReconnect: false,
        );

        expect(analytics.events[0].parameters, {
          'provider_category': 'copilot_cli',
          'is_reconnect': 1,
        });
        // Anything outside the fixed provider vocabulary collapses to
        // "unknown" rather than ever forwarding a user-authored value.
        expect(analytics.events[1].parameters, {
          'provider_category': 'unknown',
          'is_reconnect': 0,
        });
      });

      test('allowlists session-end reasons', () async {
        await service.logAcpSessionEnded(reason: 'providerExited');
        await service.logAcpSessionEnded(reason: 'some raw path/leak');

        expect(analytics.events[0].parameters, {'reason': 'provider_exited'});
        expect(analytics.events[1].parameters, {'reason': 'unknown'});
      });

      test(
        'reports reconnect outcome with an optional failure category',
        () async {
          await service.logAcpReconnectOutcome(succeeded: true);
          await service.logAcpReconnectOutcome(
            succeeded: false,
            failureCategory: 'transport',
          );

          expect(analytics.events[0].parameters, {'succeeded': 1});
          expect(analytics.events[1].parameters, {
            'succeeded': 0,
            'failure_category': 'transport',
          });
        },
      );

      test('buckets attachment counts instead of exact numbers', () async {
        await service.logAcpAttachmentSent(category: 'image', count: 37);

        expect(analytics.events.single.parameters, {
          'category': 'image',
          'count_bucket': 'gt_20',
        });
      });

      test('allowlists permission outcomes', () async {
        await service.logAcpPermissionOutcome(outcome: 'selected');
        await service.logAcpPermissionOutcome(outcome: 'approved-by-accident');

        expect(analytics.events[0].parameters, {'outcome': 'selected'});
        expect(analytics.events[1].parameters, {'outcome': 'unknown'});
      });

      test('allowlists failure categories', () async {
        await service.logAcpFailure(category: 'bridgeUnavailable');
        await service.logAcpFailure(category: '/etc/passwd');

        expect(analytics.events[0].parameters, {
          'category': 'bridge_unavailable',
        });
        expect(analytics.events[1].parameters, {'category': 'unknown'});
      });
    });
  });

  group('isFirebaseTelemetrySupportedPlatform', () {
    test('supports Android and iOS only', () {
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.android,
        ),
        isTrue,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.iOS,
        ),
        isTrue,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.macOS,
        ),
        isFalse,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: true,
          targetPlatform: TargetPlatform.android,
        ),
        isFalse,
      );
    });
  });

  group('TelemetryCollectionNotifier', () {
    test('a stale initialization read cannot undo opt-out', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = _DelayedTelemetryReadSettingsService(db);
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _FakeAnalyticsClient(),
        crashReporter: _FakeCrashReporter(),
      );
      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          telemetryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        telemetryCollectionNotifierProvider.notifier,
      );
      await settings.readStarted.future;

      await notifier.setEnabled(enabled: false);
      settings.finishRead.complete(true);
      await Future<void>.delayed(Duration.zero);

      expect(service.collectionEnabled, isFalse);
      expect(container.read(telemetryCollectionNotifierProvider), isFalse);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isFalse,
      );
    });

    for (final initiallyEnabled in [false, true]) {
      test(
        'opt-out gates events during queued persistence from '
        'enabled=$initiallyEnabled and skips the superseded enable',
        () async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final settings = _DelayedTelemetryWriteSettingsService(db);
          final analytics = _FakeAnalyticsClient();
          final crashReporter = _FakeCrashReporter();
          final service = TelemetryService(
            status: TelemetryServiceStatus.ready,
            collectionEnabled: initiallyEnabled,
            diagnosticsLogger: const NoopDiagnosticsLogger(),
            analyticsClient: analytics,
            crashReporter: crashReporter,
          );
          final container = ProviderContainer(
            overrides: [
              settingsServiceProvider.overrideWithValue(settings),
              telemetryServiceProvider.overrideWithValue(service),
            ],
          );
          addTearDown(container.dispose);
          final notifier = container.read(
            telemetryCollectionNotifierProvider.notifier,
          );

          final enable = notifier.setEnabled(enabled: true);
          await settings.writeStarted.future;
          final disable = notifier.setEnabled(enabled: false);
          expect(service.collectionEnabled, isFalse);
          await service.logFeatureOpened(feature: 'terminal');
          await service.recordError(
            StateError('test'),
            StackTrace.current,
            fatal: false,
          );
          expect(analytics.events, isEmpty);
          expect(crashReporter.recordedErrors, isEmpty);

          settings.finishWrite.complete();
          await Future.wait([enable, disable]);

          expect(analytics.collectionUpdates, [false]);
          expect(crashReporter.collectionEnabled, isFalse);
          expect(analytics.resetCount, initiallyEnabled ? 1 : 0);
          expect(
            crashReporter.deleteUnsentReportsCount,
            initiallyEnabled ? 1 : 0,
          );
          expect(container.read(telemetryCollectionNotifierProvider), isFalse);
          expect(
            await SettingsService(db).getBool(SettingKeys.telemetryCollection),
            isFalse,
          );
        },
      );
    }

    test('opt-out gates events while an older SDK enable is pending', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final analytics = _DelayedAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: crashReporter,
      );
      final container = _createTelemetryContainer(
        db: db,
        telemetryService: service,
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        telemetryCollectionNotifierProvider.notifier,
      );

      final enable = notifier.setEnabled(enabled: true);
      await analytics.enableStarted.future;
      final disable = notifier.setEnabled(enabled: false);
      expect(service.collectionEnabled, isFalse);
      await service.logFeatureOpened(feature: 'terminal');
      await service.recordError(
        StateError('test'),
        StackTrace.current,
        fatal: false,
      );
      expect(analytics.events, isEmpty);
      expect(crashReporter.recordedErrors, isEmpty);

      analytics.finishEnable.complete();
      await Future.wait([enable, disable]);
      expect(analytics.collectionUpdates, [true, false]);
      expect(crashReporter.collectionEnabled, isFalse);
      expect(analytics.resetCount, 1);
      expect(crashReporter.deleteUnsentReportsCount, 1);
      expect(container.read(telemetryCollectionNotifierProvider), isFalse);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isFalse,
      );
    });

    test(
      'failed opt-out persistence still disables and clears SDK data',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        await SettingsService(
          db,
        ).setBool(SettingKeys.telemetryCollection, value: true);
        final settings = _DelayedTelemetryWriteSettingsService(
          db,
          delayedValue: false,
          failWrite: true,
        );
        final analytics = _FakeAnalyticsClient();
        final crashReporter = _FakeCrashReporter();
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: crashReporter,
        );
        final container = ProviderContainer(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
            telemetryServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(
          telemetryCollectionNotifierProvider.notifier,
        );

        final failedDisable = expectLater(
          notifier.setEnabled(enabled: false),
          throwsStateError,
        );
        expect(service.collectionEnabled, isFalse);
        await settings.writeStarted.future;
        settings.finishWrite.complete();
        await failedDisable;

        expect(analytics.collectionUpdates, [false]);
        expect(crashReporter.collectionEnabled, isFalse);
        expect(analytics.resetCount, 1);
        expect(crashReporter.deleteUnsentReportsCount, 1);
        // The storage failure remains visible; it cannot reopen the live gate.
        expect(
          await SettingsService(db).getBool(SettingKeys.telemetryCollection),
          isTrue,
        );
      },
    );

    test('a newer enable does not skip queued opt-out cleanup', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = _DelayedTelemetryWriteSettingsService(
        db,
        delayedValue: false,
      );
      final analytics = _FakeAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: crashReporter,
      );
      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          telemetryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        telemetryCollectionNotifierProvider.notifier,
      );

      final disable = notifier.setEnabled(enabled: false);
      await settings.writeStarted.future;
      final enable = notifier.setEnabled(enabled: true);
      expect(service.collectionEnabled, isFalse);
      settings.finishWrite.complete();
      await Future.wait([disable, enable]);

      expect(analytics.collectionUpdates, [false, true]);
      expect(crashReporter.collectionEnabled, isTrue);
      expect(analytics.resetCount, 1);
      expect(crashReporter.deleteUnsentReportsCount, 1);
      expect(container.read(telemetryCollectionNotifierProvider), isTrue);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isTrue,
      );
    });

    test('persists overlapping choices in request order', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = _DelayedTelemetryWriteSettingsService(db);
      final service = TelemetryService(
        status: TelemetryServiceStatus.disabledByBuild,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
      );
      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          telemetryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        telemetryCollectionNotifierProvider.notifier,
      );

      final enable = notifier.setEnabled(enabled: true);
      await settings.writeStarted.future;
      final disable = notifier.setEnabled(enabled: false);
      await Future<void>.delayed(Duration.zero);
      settings.finishWrite.complete();
      await Future.wait([enable, disable]);

      expect(service.collectionEnabled, isFalse);
      expect(container.read(telemetryCollectionNotifierProvider), isFalse);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isFalse,
      );
    });

    test('a failed preference write does not block a queued opt-out', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = _DelayedTelemetryWriteSettingsService(
        db,
        failEnable: true,
      );
      final service = TelemetryService(
        status: TelemetryServiceStatus.disabledByBuild,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
      );
      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          telemetryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        telemetryCollectionNotifierProvider.notifier,
      );
      final failedEnable = expectLater(
        notifier.setEnabled(enabled: true),
        throwsStateError,
      );
      await settings.writeStarted.future;
      final disable = notifier.setEnabled(enabled: false);
      settings.finishWrite.complete();
      await Future.wait([failedEnable, disable]);

      expect(service.collectionEnabled, isFalse);
      expect(container.read(telemetryCollectionNotifierProvider), isFalse);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isFalse,
      );
    });

    test('finishes a pending preference write after disposal', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = _DelayedTelemetryWriteSettingsService(db);
      final container = ProviderContainer(
        overrides: [settingsServiceProvider.overrideWithValue(settings)],
      );
      final pending = container
          .read(telemetryCollectionNotifierProvider.notifier)
          .setEnabled(enabled: true);
      await settings.writeStarted.future;
      container.dispose();
      settings.finishWrite.complete();

      await expectLater(pending, completes);
      expect(
        await SettingsService(db).getBool(SettingKeys.telemetryCollection),
        isTrue,
      );
    });
  });

  group('TelemetryOptInPromptNotifier', () {
    test('records launch count for delayed prompt eligibility', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = _createTelemetryContainer(db: db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      final notifier = container.read(
        telemetryOptInPromptNotifierProvider.notifier,
      );
      await notifier.recordAppLaunch();
      await notifier.recordAppLaunch();
      await notifier.recordAppLaunch();

      final state = container.read(telemetryOptInPromptNotifierProvider);
      expect(
        state.appLaunchCount,
        TelemetryOptInPromptNotifier.minimumLaunchCountForPrompt,
      );
      expect(state.choice, TelemetryOptInPromptChoice.notShown);
      expect(
        await SettingsService(db).getInt(SettingKeys.telemetryAppLaunchCount),
        TelemetryOptInPromptNotifier.minimumLaunchCountForPrompt,
      );
    });

    test('accept enables collection and resolves prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final analytics = _FakeAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final container = _createTelemetryContainer(
        db: db,
        telemetryService: TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: false,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: crashReporter,
        ),
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(telemetryOptInPromptNotifierProvider.notifier)
          .accept();

      final settings = SettingsService(db);
      expect(
        container.read(telemetryOptInPromptNotifierProvider).choice,
        TelemetryOptInPromptChoice.accepted,
      );
      expect(await settings.getBool(SettingKeys.telemetryCollection), isTrue);
      expect(
        await settings.getString(SettingKeys.telemetryOptInPromptState),
        TelemetryOptInPromptChoice.accepted.name,
      );
      expect(analytics.collectionEnabled, isTrue);
      expect(crashReporter.collectionEnabled, isTrue);
    });

    test('dismiss resolves prompt without enabling collection', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = _createTelemetryContainer(db: db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(telemetryOptInPromptNotifierProvider.notifier)
          .dismiss();

      final settings = SettingsService(db);
      expect(
        container.read(telemetryOptInPromptNotifierProvider).choice,
        TelemetryOptInPromptChoice.dismissed,
      );
      expect(await settings.getBool(SettingKeys.telemetryCollection), isFalse);
      expect(
        await settings.getString(SettingKeys.telemetryOptInPromptState),
        TelemetryOptInPromptChoice.dismissed.name,
      );
    });
  });
}

ProviderContainer _createTelemetryContainer({
  required AppDatabase db,
  TelemetryService? telemetryService,
}) => ProviderContainer(
  overrides: [
    databaseProvider.overrideWithValue(db),
    telemetryServiceProvider.overrideWithValue(
      telemetryService ??
          TelemetryService(
            status: TelemetryServiceStatus.disabledByBuild,
            collectionEnabled: false,
            diagnosticsLogger: const NoopDiagnosticsLogger(),
          ),
    ),
  ],
);

class _CustomTelemetryException implements Exception {
  const _CustomTelemetryException();
}

class _FakeAnalyticsClient implements TelemetryAnalyticsClient {
  final List<_AnalyticsEvent> events = <_AnalyticsEvent>[];
  final collectionUpdates = <bool>[];
  bool? collectionEnabled;
  int resetCount = 0;

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    events.add(_AnalyticsEvent(name: name, parameters: parameters));
  }

  @override
  Future<void> resetAnalyticsData() async {
    resetCount += 1;
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionUpdates.add(enabled);
    collectionEnabled = enabled;
  }
}

class _DelayedAnalyticsClient extends _FakeAnalyticsClient {
  final enableStarted = Completer<void>();
  final finishEnable = Completer<void>();

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    if (enabled) {
      enableStarted.complete();
      await finishEnable.future;
    }
    await super.setCollectionEnabled(enabled: enabled);
  }
}

class _DelayedTelemetryReadSettingsService extends SettingsService {
  _DelayedTelemetryReadSettingsService(super.db);

  final readStarted = Completer<void>();
  final finishRead = Completer<bool>();

  @override
  Future<bool> getBool(String key, {bool defaultValue = false}) async {
    if (key == SettingKeys.telemetryCollection && !readStarted.isCompleted) {
      readStarted.complete();
      return finishRead.future;
    }
    return super.getBool(key, defaultValue: defaultValue);
  }
}

class _DelayedTelemetryWriteSettingsService extends SettingsService {
  _DelayedTelemetryWriteSettingsService(
    super.db, {
    this.failEnable = false,
    this.delayedValue = true,
    this.failWrite = false,
  });

  final bool failEnable;
  final bool delayedValue;
  final bool failWrite;

  final writeStarted = Completer<void>();
  final finishWrite = Completer<void>();

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == SettingKeys.telemetryCollection &&
        value == delayedValue &&
        !writeStarted.isCompleted) {
      writeStarted.complete();
      await finishWrite.future;
      if (failWrite || (value && failEnable)) {
        throw StateError('preference write failed');
      }
    }
    await super.setBool(key, value: value);
  }
}

class _ThrowingAnalyticsClient implements TelemetryAnalyticsClient {
  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    throw StateError('analytics unavailable');
  }

  @override
  Future<void> resetAnalyticsData() async {
    throw StateError('analytics unavailable');
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    throw StateError('analytics unavailable');
  }
}

class _FakeCrashReporter implements TelemetryCrashReporter {
  final List<_RecordedError> recordedErrors = <_RecordedError>[];
  final List<FlutterErrorDetails> recordedFlutterErrors =
      <FlutterErrorDetails>[];
  final Map<String, Object> customKeys = <String, Object>{};
  bool? collectionEnabled;
  int deleteUnsentReportsCount = 0;

  @override
  Future<void> deleteUnsentReports() async {
    deleteUnsentReportsCount += 1;
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {
    recordedErrors.add(
      _RecordedError(
        error: error,
        stackTrace: stackTrace,
        fatal: fatal,
        keys: Map.of(customKeys),
      ),
    );
  }

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    recordedFlutterErrors.add(details);
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionEnabled = enabled;
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    customKeys[key] = value;
  }
}

class _AnalyticsEvent {
  const _AnalyticsEvent({required this.name, required this.parameters});

  final String name;
  final Map<String, Object> parameters;
}

class _RecordedError {
  const _RecordedError({
    required this.error,
    required this.stackTrace,
    required this.fatal,
    required this.keys,
  });

  final Object error;
  final StackTrace stackTrace;
  final bool fatal;
  final Map<String, Object> keys;
  String get reason => (error as SanitizedTelemetryError).reason;
}

class _ThrowingToStringError {
  @override
  String toString() => throw StateError('cannot stringify');
}

class _FailingMetadataCrashReporter extends _FakeCrashReporter {
  @override
  Future<void> setCustomKey(String key, Object value) async {
    throw StateError('metadata unavailable');
  }
}

class _DelayedMetadataCrashReporter extends _FakeCrashReporter {
  final started = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<void> setCustomKey(String key, Object value) async {
    if (!started.isCompleted) {
      started.complete();
      await finish.future;
    }
    await super.setCustomKey(key, value);
  }
}
