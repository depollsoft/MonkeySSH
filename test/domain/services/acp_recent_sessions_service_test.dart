// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpRecentSessionsService service;

  AcpRecentSessionRef ref(int hostId, String sessionId, {String? title}) =>
      AcpRecentSessionRef(
        hostId: hostId,
        providerId: 'copilot',
        bridgeId: 'bridge-$hostId',
        acpSessionId: sessionId,
        title: title,
        cwd: '/repo',
        createdAt: DateTime.utc(2024),
        lastActivityAt: DateTime.utc(2024, 1, 1, hostId),
      );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    service = AcpRecentSessionsService(settings, maxEntries: 3);
  });

  tearDown(() async {
    await database.close();
  });

  test('records references most-recent-first', () async {
    await service.record(ref(1, 's1'));
    await service.record(ref(2, 's2'));
    final list = await service.list();
    expect(list.map((r) => r.acpSessionId), ['s2', 's1']);
  });

  test('deduplicates by session key and updates in place', () async {
    await service.record(ref(1, 's1', title: 'first'));
    await service.record(ref(2, 's2'));
    await service.record(ref(1, 's1', title: 'updated'));
    final list = await service.list();
    expect(list.map((r) => r.acpSessionId), ['s1', 's2']);
    expect(list.first.title, 'updated');
  });

  test('bounds the retained list', () async {
    for (var i = 1; i <= 5; i++) {
      await service.record(ref(i, 's$i'));
    }
    final list = await service.list();
    expect(list, hasLength(3));
    expect(list.map((r) => r.acpSessionId), ['s5', 's4', 's3']);
  });

  test('serializes overlapping mutations without dropping writes', () async {
    await Future.wait([
      service.record(ref(1, 's1')),
      service.record(ref(2, 's2')),
      service.record(ref(3, 's3')),
    ]);
    final list = await service.list();
    expect(list.map((r) => r.acpSessionId).toSet(), {'s1', 's2', 's3'});
  });

  test('remove deletes a single reference', () async {
    await service.record(ref(1, 's1'));
    await service.record(ref(2, 's2'));
    await service.remove(
      AcpSessionKey.of(
        hostId: 1,
        providerId: 'copilot',
        bridgeId: 'bridge-1',
        acpSessionId: 's1',
      ),
    );
    final list = await service.list();
    expect(list.map((r) => r.acpSessionId), ['s2']);
  });

  group('malformed storage', () {
    test('returns empty list for invalid JSON', () async {
      await settings.setString(SettingKeys.acpRecentSessions, '{bad');
      expect(await service.list(), isEmpty);
    });

    test('skips malformed entries but keeps valid ones', () async {
      await settings.setString(
        SettingKeys.acpRecentSessions,
        '[{"hostId":1},{"hostId":2,"providerId":"copilot",'
        '"bridgeId":"b","acpSessionId":"s",'
        '"createdAt":"2024-01-01T00:00:00Z"}]',
      );
      final list = await service.list();
      expect(list, hasLength(1));
      expect(list.single.hostId, 2);
    });
  });

  group('workspace choices', () {
    test('round-trips MCP server ids and additional directories', () async {
      await service.record(
        AcpRecentSessionRef(
          hostId: 1,
          providerId: 'copilot',
          bridgeId: 'bridge-1',
          acpSessionId: 's1',
          cwd: '/repo',
          mcpServerIds: const ['mcp-a', 'mcp-b', 'mcp-a', ''],
          additionalDirectories: const ['/shared', '/docs', '/shared'],
          createdAt: DateTime.utc(2024),
          lastActivityAt: DateTime.utc(2024),
        ),
      );
      final restored = (await service.list()).single;
      expect(restored.mcpServerIds, ['mcp-a', 'mcp-b']);
      expect(restored.additionalDirectories, ['/shared', '/docs']);
      expect(restored.workspace.mcpServerIds, ['mcp-a', 'mcp-b']);
      expect(restored.workspace.additionalDirectories, ['/shared', '/docs']);
    });

    test(
      'keeps an explicit empty server choice distinct from legacy',
      () async {
        await service.record(
          AcpRecentSessionRef(
            hostId: 1,
            providerId: 'copilot',
            bridgeId: 'bridge-1',
            acpSessionId: 's1',
            mcpServerIds: const <String>[],
            createdAt: DateTime.utc(2024),
            lastActivityAt: DateTime.utc(2024),
          ),
        );
        await service.record(ref(2, 's2'));
        final list = await service.list();
        final explicit = list.firstWhere((r) => r.acpSessionId == 's1');
        final legacy = list.firstWhere((r) => r.acpSessionId == 's2');
        expect(explicit.mcpServerIds, isEmpty);
        expect(legacy.mcpServerIds, isNull);
        expect(legacy.additionalDirectories, isEmpty);
      },
    );

    test('drops overlong directories instead of truncating them', () async {
      final overlong = '/${'a' * kAcpRecentCwdMaxCharacters}';
      await service.record(
        AcpRecentSessionRef(
          hostId: 1,
          providerId: 'copilot',
          bridgeId: 'bridge-1',
          acpSessionId: 's1',
          additionalDirectories: [overlong, '/ok'],
          createdAt: DateTime.utc(2024),
          lastActivityAt: DateTime.utc(2024),
        ),
      );
      expect((await service.list()).single.additionalDirectories, ['/ok']);
    });

    test('ignores malformed workspace fields on older entries', () async {
      await settings.setString(
        SettingKeys.acpRecentSessions,
        '[{"hostId":2,"providerId":"copilot","bridgeId":"b",'
        '"acpSessionId":"s","createdAt":"2024-01-01T00:00:00Z",'
        '"mcpServerIds":"oops","additionalDirectories":[1,"/x"]}]',
      );
      final restored = (await service.list()).single;
      expect(restored.mcpServerIds, isEmpty);
      expect(restored.additionalDirectories, ['/x']);
    });
  });

  group('last selected', () {
    test('persists and clears the last selected key', () async {
      final key = AcpSessionKey.of(
        hostId: 4,
        providerId: 'copilot',
        bridgeId: 'bridge-4',
        acpSessionId: 's4',
      );
      await service.setLastSelected(key);
      expect(await service.getLastSelected(), key);
      await service.setLastSelected(null);
      expect(await service.getLastSelected(), isNull);
    });

    test('returns null for malformed last-selected storage', () async {
      await settings.setString(SettingKeys.acpLastSelectedSession, 'not json');
      expect(await service.getLastSelected(), isNull);
    });
  });
}
