// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/presentation/providers/connection_attention_provider.dart';
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

    test('puts sessions waiting on the user first, like Connections', () {
      final newerIdle = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'idle'),
        lastActivityAt: DateTime(2026, 2),
      );
      final olderAsking = fakeAcpSession(
        key: fakeAcpKey(acpSessionId: 'asking'),
        lastActivityAt: DateTime(2025),
        pendingPermissions: [
          AcpPendingPermission(
            requestKey: 'r',
            sessionId: 'asking',
            toolCallId: 't',
            options: const [],
            requestedAt: DateTime(2025),
          ),
        ],
      );
      final recentWithRequest = AcpRecentSessionRef(
        hostId: 1,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'parked',
        acpSessionId: 'parked-session',
        createdAt: DateTime(2024),
        lastActivityAt: DateTime(2024),
      );
      final bridges = HostBridgeMetadata(const {}).withHost(
        1,
        HostBridges(
          connectionId: 7,
          bridges: [
            MonkeyMuxAcpBridgeMetadata(
              id: 'parked',
              sessionId: 'parked-session',
              provider: 'Copilot CLI',
              commandHash: 'hash',
              state: MonkeyMuxAcpProviderState.running,
              clientCount: 0,
              pendingRequestCount: 1,
              inFlightTurnCount: 0,
              lastActivity: DateTime(2024),
              startedAt: DateTime(2024),
              nextSequence: 1,
            ),
          ],
        ),
      );

      final entries = buildAcpSwitcherEntries(
        sessions: [newerIdle, olderAsking],
        recents: [recentWithRequest],
        bridges: bridges,
      );

      expect(entries.map((entry) => entry.keyValue), [
        olderAsking.key.value,
        recentWithRequest.key.value,
        newerIdle.key.value,
      ]);
      expect(
        acpSwitcherEntryWaitingReason(entries[1], bridges: bridges),
        AttentionReason.hostRequest,
      );
    });
  });
}
