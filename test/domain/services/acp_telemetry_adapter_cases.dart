import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_telemetry_adapter.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

import '../../helpers/telemetry_test_fakes.dart';

/// Registers tests from acp_telemetry_adapter_test.dart.
void registerDomainServicesAcpTelemetryAdapterTests() {
  group('acp_telemetry_adapter', () {
    group('AcpTelemetryAdapter', () {
      late FakeTelemetryAnalyticsClient analytics;
      late AcpTelemetryAdapter adapter;

      setUp(() {
        analytics = FakeTelemetryAnalyticsClient();
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: FakeTelemetryCrashReporter(),
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
          analytics.events.map(
            (event) => event.parameters['provider_category'],
          ),
          expected.values,
        );
      });

      test('collapses any id that is not a built-in provider to "unknown" '
          'rather than forwarding it raw', () {
        adapter
          ..sessionOpened(
            providerCategory: 'a-user-typed-uuid-like-id',
            isReconnect: true,
          )
          ..sessionOpened(
            providerCategory: 'builtin:future-provider',
            isReconnect: false,
          );

        expect(
          analytics.events.map(
            (event) => event.parameters['provider_category'],
          ),
          ['unknown', 'unknown'],
        );
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
          analytics.events.map((e) => e.name),
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
  });
}
