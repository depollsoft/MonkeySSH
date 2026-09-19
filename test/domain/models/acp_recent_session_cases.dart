// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';

void registerAcpRecentSessionTests() {
  group('acp_recent_session', () {
    final ref = AcpRecentSessionRef(
      hostId: 5,
      providerId: 'copilot',
      bridgeId: 'bridge-1',
      acpSessionId: 'session-1',
      title: 'Refactor auth',
      cwd: '/repo',
      createdAt: DateTime.utc(2024, 1, 1, 12),
      lastActivityAt: DateTime.utc(2024, 1, 1, 13),
    );

    test('round-trips through JSON', () {
      final json = jsonDecode(jsonEncode(ref.toJson()));
      final parsed = AcpRecentSessionRef.tryFromJson(json);
      expect(parsed, ref);
    });

    test('serialized JSON contains only bounded navigation metadata keys', () {
      final json = ref.toJson();
      expect(json.keys.toSet(), {
        'hostId',
        'providerId',
        'bridgeId',
        'acpSessionId',
        'title',
        'cwd',
        'createdAt',
        'lastActivityAt',
      });
    });

    group('defensive parsing', () {
      test('returns null for non-map input', () {
        expect(AcpRecentSessionRef.tryFromJson('nope'), isNull);
        expect(AcpRecentSessionRef.tryFromJson(42), isNull);
        expect(AcpRecentSessionRef.tryFromJson(null), isNull);
      });

      test('returns null when required identifiers are missing', () {
        expect(
          AcpRecentSessionRef.tryFromJson(<String, Object?>{
            'hostId': 1,
            'providerId': 'p',
            'createdAt': '2024-01-01T00:00:00Z',
          }),
          isNull,
        );
      });

      test('returns null when timestamps are missing', () {
        expect(
          AcpRecentSessionRef.tryFromJson(<String, Object?>{
            'hostId': 1,
            'providerId': 'p',
            'bridgeId': 'b',
            'acpSessionId': 's',
          }),
          isNull,
        );
      });

      test('defaults lastActivityAt to createdAt when absent', () {
        final parsed = AcpRecentSessionRef.tryFromJson(<String, Object?>{
          'hostId': 1,
          'providerId': 'p',
          'bridgeId': 'b',
          'acpSessionId': 's',
          'createdAt': '2024-01-01T00:00:00Z',
        });
        expect(parsed, isNotNull);
        expect(parsed!.lastActivityAt, parsed.createdAt);
      });

      test('rejects out-of-range epoch timestamps without throwing', () {
        final parsed = AcpRecentSessionRef.tryFromJson(<String, Object?>{
          'hostId': 1,
          'providerId': 'p',
          'bridgeId': 'b',
          'acpSessionId': 's',
          'createdAt': 0x7fffffffffffffff,
        });
        expect(parsed, isNull);
      });

      test('bounds persisted display metadata while parsing', () {
        final parsed = AcpRecentSessionRef.tryFromJson(<String, Object?>{
          'hostId': 1,
          'providerId': 'p',
          'bridgeId': 'b',
          'acpSessionId': 's',
          'createdAt': '2024-01-01T00:00:00Z',
          'title': List.filled(400, 't').join(),
          'cwd': List.filled(1200, 'c').join(),
        });

        expect(parsed?.title, hasLength(kAcpRecentTitleMaxCharacters));
        expect(parsed?.cwd, hasLength(kAcpRecentCwdMaxCharacters));
      });

      test('accepts epoch millisecond timestamps', () {
        final parsed = AcpRecentSessionRef.tryFromJson(<String, Object?>{
          'hostId': '9',
          'providerId': 'p',
          'bridgeId': 'b',
          'acpSessionId': 's',
          'createdAt': 1704067200000,
        });
        expect(parsed, isNotNull);
        expect(parsed!.hostId, 9);
        expect(parsed.createdAt, DateTime.utc(2024));
      });
    });
  });
}
