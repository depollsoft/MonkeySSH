import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_telemetry_adapter.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

class _FakeAnalyticsClient implements TelemetryAnalyticsClient {
  final events = <MapEntry<String, Map<String, Object>>>[];

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}

  @override
  Future<void> resetAnalyticsData() async {}

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    events.add(MapEntry(name, parameters));
  }
}

class _FakeCrashReporter implements TelemetryCrashReporter {
  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}

  @override
  Future<void> deleteUnsentReports() async {}

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {}
}

void main() {
  group('AcpTelemetryAdapter', () {
    late _FakeAnalyticsClient analytics;
    late AcpTelemetryAdapter adapter;

    setUp(() {
      analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );
      adapter = AcpTelemetryAdapter(service);
    });

    test('maps built-in provider ids to their stable category', () {
      const expected = <String, String>{
        AcpBuiltinProviderIds.copilotCli: 'copilot_cli',
        AcpBuiltinProviderIds.claudeAgent: 'claude_agent',
        AcpBuiltinProviderIds.codex: 'codex',
        AcpBuiltinProviderIds.openCode: 'opencode',
        AcpBuiltinProviderIds.cursorAgent: 'cursor_agent',
        AcpBuiltinProviderIds.antigravity: 'antigravity',
        AcpBuiltinProviderIds.pi: 'pi',
        AcpBuiltinProviderIds.grokBuild: 'grok_build',
        AcpBuiltinProviderIds.museCode: 'muse_code',
      };
      for (final provider in expected.keys) {
        adapter.sessionOpened(providerCategory: provider, isReconnect: false);
      }

      expect(
        analytics.events.map((event) => event.value['provider_category']),
        expected.values,
      );
    });

    test(
      'collapses every custom provider id to "custom", never the raw id',
      () {
        adapter.sessionOpened(
          providerCategory: 'a-user-typed-uuid-like-id',
          isReconnect: true,
        );

        expect(analytics.events.single.value['provider_category'], 'custom');
      },
    );

    test('collapses a reserved builtin-prefixed id that is not a known '
        'provider to "unknown" rather than forwarding it raw', () {
      adapter.sessionOpened(
        providerCategory: 'builtin:future-provider',
        isReconnect: false,
      );

      expect(analytics.events.single.value['provider_category'], 'unknown');
    });

    test('forwards session-ended, reconnect, attachment, and permission '
        'events unchanged to the telemetry service allowlist', () {
      adapter
        ..sessionEnded(reason: 'stopped')
        ..reconnectOutcome(succeeded: true)
        ..attachmentSent(category: 'image', count: 2)
        ..permissionOutcome(outcome: 'selected')
        ..failure(category: 'transport');

      expect(
        analytics.events.map((e) => e.key),
        containsAll(<String>[
          'acp_session_ended',
          'acp_reconnect_outcome',
          'acp_attachment_sent',
          'acp_permission_outcome',
          'acp_failure',
        ]),
      );
    });
  });
}
