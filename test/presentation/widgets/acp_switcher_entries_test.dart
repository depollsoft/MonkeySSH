// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/presentation/widgets/acp_session_switcher.dart';

import '../../support/fake_acp_session_manager.dart';

void main() {
  group('buildAcpSwitcherEntries', () {
    test('merges tracked sessions and dedupes recents by key', () {
      final trackedKey = fakeAcpKey(acpSessionId: 'live');
      final session = fakeAcpSession(
        key: trackedKey,
        lastActivityAt: DateTime(2026, 1, 2),
      );
      final trackedRecent = AcpRecentSessionRef(
        hostId: trackedKey.hostId,
        providerId: trackedKey.providerId,
        bridgeId: trackedKey.bridgeId,
        acpSessionId: trackedKey.acpSessionId,
        createdAt: DateTime(2026),
        lastActivityAt: DateTime(2026),
      );
      final otherRecent = AcpRecentSessionRef(
        hostId: 1,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'archived',
        createdAt: DateTime(2025),
        lastActivityAt: DateTime(2025, 12, 31),
      );

      final entries = buildAcpSwitcherEntries(
        sessions: [session],
        recents: [trackedRecent, otherRecent],
      );

      // The tracked recent is deduped; only the live session + the distinct
      // recent survive.
      expect(entries.length, 2);
      expect(entries.first.session, isNotNull);
      expect(entries.first.keyValue, trackedKey.value);
      expect(entries.last.recent, isNotNull);
      expect(entries.last.keyValue, otherRecent.key.value);
    });

    test('recent entries get a provider label instead of a bare separator', () {
      final recent = AcpSwitcherEntry.recent(
        AcpRecentSessionRef(
          hostId: 1,
          providerId: 'builtin:copilot-cli',
          bridgeId: 'bridge-1',
          acpSessionId: 'archived',
          createdAt: DateTime(2026),
          lastActivityAt: DateTime(2026, 1, 1, 11),
          cwd: '/home/demo/proj',
        ),
      );
      final subtitle = acpSwitcherEntrySubtitle(
        recent,
        now: DateTime(2026, 1, 1, 12),
      );
      expect(subtitle, startsWith('Copilot CLI · '));
      expect(subtitle, isNot(startsWith(' · ')));
    });

    test('orders entries by most recent activity first', () {
      final older = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'a'),
        lastActivityAt: DateTime(2025, 12),
      );
      final newer = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'b'),
        lastActivityAt: DateTime(2026, 1, 5),
      );

      final entries = buildAcpSwitcherEntries(
        sessions: [older, newer],
        recents: const [],
      );

      expect(entries.first.keyValue, newer.key.value);
      expect(entries.last.keyValue, older.key.value);
    });
  });

  group('buildAcpMuxWindowEntries', () {
    test('ignores activity changes when assigning native window order', () {
      final first = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'a'),
        lastActivityAt: DateTime(2025),
      );
      final recentlyActive = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'b'),
        lastActivityAt: DateTime(2027),
      );

      final entries = buildAcpMuxWindowEntries([recentlyActive, first]);

      expect(entries.map((entry) => entry.keyValue), [
        first.key.value,
        recentlyActive.key.value,
      ]);
    });
  });
}
