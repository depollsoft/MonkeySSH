// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';

void registerAcpSessionKeysTests() {
  group('acp_session_keys', () {
    group('AcpSessionKey', () {
      test('canonical value is injective across components', () {
        final a = AcpSessionKey.of(
          hostId: 1,
          providerId: 'p|x',
          bridgeId: 'b',
          acpSessionId: 's',
        );
        final b = AcpSessionKey.of(
          hostId: 1,
          providerId: 'p',
          bridgeId: 'x|b',
          acpSessionId: 's',
        );
        expect(a.value, isNot(b.value));
        expect(a, isNot(b));
      });

      test('equal components produce equal keys and values', () {
        final a = AcpSessionKey.of(
          hostId: 7,
          providerId: 'copilot',
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
        );
        final b = AcpSessionKey.of(
          hostId: 7,
          providerId: 'copilot',
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
        );
        expect(a, b);
        expect(a.value, b.value);
        expect(a.hashCode, b.hashCode);
      });

      test('exposes derived bridge and host keys', () {
        final key = AcpSessionKey.of(
          hostId: 3,
          providerId: 'p',
          bridgeId: 'bridge-9',
          acpSessionId: 's',
        );
        expect(key.host, const AcpHostKey(3));
        expect(
          key.bridge,
          const AcpBridgeKey(host: AcpHostKey(3), bridgeId: 'bridge-9'),
        );
        expect(key.hostId, 3);
        expect(key.providerId, 'p');
      });

      test('value contains no transcript content, only identifiers', () {
        final key = AcpSessionKey.of(
          hostId: 42,
          providerId: 'prov',
          bridgeId: 'brg',
          acpSessionId: 'ses',
        );
        expect(key.value, contains('42'));
        expect(key.value, contains('prov'));
        expect(key.value, contains('brg'));
        expect(key.value, contains('ses'));
      });
    });

    group('AcpBridgeKey', () {
      test('distinguishes bridges on the same host', () {
        const a = AcpBridgeKey(host: AcpHostKey(1), bridgeId: 'a');
        const b = AcpBridgeKey(host: AcpHostKey(1), bridgeId: 'b');
        expect(a, isNot(b));
        expect(a.value, isNot(b.value));
      });
    });
  });
}
