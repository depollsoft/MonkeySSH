// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';

void registerAcpNotificationLocationTests() {
  group('acp_notification_location', () {
    group('ACP navigation locations', () {
      test('agent chat location carries only opaque identifiers', () {
        final location = buildAgentChatLocation(
          hostId: 7,
          providerId: 'builtin:copilot-cli',
          bridgeId: 'bridge-9',
          acpSessionId: 'session-42',
        );
        final uri = Uri.parse(location);

        expect(uri.path, acpAgentChatRoutePath);
        expect(uri.queryParameters[acpAgentChatHostQueryKey], '7');
        expect(
          uri.queryParameters[acpAgentChatProviderQueryKey],
          'builtin:copilot-cli',
        );
        expect(uri.queryParameters[acpAgentChatBridgeQueryKey], 'bridge-9');
        expect(uri.queryParameters[acpAgentChatSessionQueryKey], 'session-42');
        // No cwd/title/command/path leakage.
        expect(location.contains('cwd'), isFalse);
        expect(location.contains('/home/'), isFalse);
      });

      test('fallback location returns to active connections', () {
        final location = buildAcpSessionFallbackLocation();
        final uri = Uri.parse(location);

        expect(uri.path, '/');
        expect(uri.queryParameters['tab'], 'connections');
        expect(location.startsWith('/home'), isFalse);
      });

      test('notification tap deep-links to the native terminal', () {
        const payload = AcpNotificationPayload(
          kind: AcpNotificationKind.permission,
          hostId: 3,
          providerId: 'builtin:opencode',
          bridgeId: 'bridge-2',
          acpSessionId: 'session-2',
        );

        final location = buildAcpNotificationLocation(payload);
        final uri = Uri.parse(location);

        expect(uri.path, '/terminal/3');
        expect(uri.queryParameters[acpAgentChatSessionQueryKey], 'session-2');
        expect(location.startsWith('/home'), isFalse);
      });
    });
  });
}
