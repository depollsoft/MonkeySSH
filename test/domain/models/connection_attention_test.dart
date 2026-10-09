// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

import '../../support/fake_acp_session_manager.dart';

MonkeyMuxAcpBridgeMetadata bridge({
  String id = 'bridge-1',
  String? sessionId,
  int pending = 0,
  int inFlight = 0,
  int clients = 0,
  MonkeyMuxAcpProviderState state = MonkeyMuxAcpProviderState.running,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  sessionId: sessionId,
  provider: 'Copilot CLI',
  commandHash: 'hash',
  state: state,
  clientCount: clients,
  pendingRequestCount: pending,
  inFlightTurnCount: inFlight,
  lastActivity: DateTime(2026, 1, 1, 12),
  startedAt: DateTime(2026),
  nextSequence: 1,
);

AcpPendingPermission permission(DateTime requestedAt) => AcpPendingPermission(
  requestKey: 'r1',
  sessionId: 'session-1',
  toolCallId: 't1',
  options: const [],
  requestedAt: requestedAt,
);

void main() {
  group('acpSessionWaitingReason', () {
    test('reports permission, then input, then sign-in from local state', () {
      final elicitation = AcpSessionElicitation(
        requestKey: 'e1',
        requestedAt: DateTime(2026),
        request: AcpElicitationRequest.parse(
          const {
            'sessionId': 'session-1',
            'mode': 'form',
            'message': 'Pick one',
            'requestedSchema': {
              'type': 'object',
              'properties': <String, Object?>{},
            },
          },
          formSupported: true,
          urlSupported: true,
        ),
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(
            pendingPermissions: [permission(DateTime(2026))],
            pendingElicitations: [elicitation],
          ),
        ),
        AttentionReason.permission,
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(pendingElicitations: [elicitation]),
        ),
        AttentionReason.input,
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(status: AcpConnectionStatus.authenticationRequired),
        ),
        AttentionReason.signIn,
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(
            status: AcpConnectionStatus.failed,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.authenticationRequired,
              message: 'Sign in.',
            ),
          ),
        ),
        AttentionReason.signIn,
      );
      expect(acpSessionWaitingReason(fakeAcpSession()), isNull);
    });

    test('uses host-reported requests only while detached', () {
      final reported = bridge(pending: 1);
      expect(
        acpSessionWaitingReason(fakeAcpSession(), bridge: reported),
        isNull,
        reason: 'An attached client already sees every request.',
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(status: AcpConnectionStatus.detached),
          bridge: reported,
        ),
        AttentionReason.hostRequest,
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(status: AcpConnectionStatus.detached),
          bridge: bridge(pending: 1, state: MonkeyMuxAcpProviderState.exited),
        ),
        isNull,
      );
    });

    test('a detached fork does not echo its sibling or a busy client', () {
      final fork = fakeAcpSession(status: AcpConnectionStatus.detached);
      expect(
        acpSessionWaitingReason(
          fork,
          bridge: bridge(pending: 1, sessionId: 'sibling'),
        ),
        isNull,
        reason: "The bridge's own session is another fork.",
      );
      expect(
        acpSessionWaitingReason(
          fork,
          bridge: bridge(pending: 1, sessionId: 'session-1'),
        ),
        AttentionReason.hostRequest,
      );
      expect(
        acpSessionWaitingReason(fork, bridge: bridge(pending: 1, clients: 1)),
        isNull,
        reason: 'An attached client is answering its own request.',
      );
    });

    test('fresh host counts decide whether a detached session waits', () {
      final detached = fakeAcpSession(
        status: AcpConnectionStatus.detached,
        pendingPermissions: [permission(DateTime(2026))],
      );
      expect(
        acpSessionWaitingReason(detached),
        isNull,
        reason:
            'Without a fresh host report (not polled yet, or the bridge is '
            'gone because the agent was stopped) nothing is claimed.',
      );
      expect(
        acpSessionWaitingReason(detached, bridge: bridge(pending: 1)),
        AttentionReason.permission,
        reason: 'The retained request names the kind of wait.',
      );
      expect(
        acpSessionWaitingReason(detached, bridge: bridge()),
        isNull,
        reason: 'Answered on another device: the host has nothing pending.',
      );
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(pending: 1, state: MonkeyMuxAcpProviderState.stopped),
        ),
        isNull,
      );
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(pending: 1, clients: 1),
        ),
        isNull,
        reason: 'Another client is answering it.',
      );
    });

    test('host requests count only with no client attached to answer', () {
      expect(
        bridgeWaitingReason(bridge(pending: 1)),
        AttentionReason.hostRequest,
      );
      expect(bridgeWaitingReason(bridge(pending: 1, clients: 1)), isNull);
    });

    test('ignores ended sessions', () {
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(
            status: AcpConnectionStatus.closed,
            pendingPermissions: [permission(DateTime(2026))],
          ),
        ),
        isNull,
      );
    });

    test('waiting since is the oldest pending request', () {
      final session = fakeAcpSession(
        lastActivityAt: DateTime(2026, 1, 1, 12),
        pendingPermissions: [permission(DateTime(2026, 1, 1, 11))],
      );
      expect(acpSessionWaitingSince(session), DateTime(2026, 1, 1, 11));
    });
  });

  group('terminalWindowAttentionReason', () {
    test('uses only generic program-reported signals', () {
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(index: 0, name: 'a', isActive: false, flags: '#'),
        ),
        AttentionReason.alert,
      );
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(
            index: 0,
            name: 'a',
            isActive: false,
            pendingNotifications: [
              MuxWindowNotification(seq: 1, payload: '9;done'),
            ],
          ),
        ),
        AttentionReason.notification,
      );
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(
            index: 0,
            name: 'a',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.error,
            ),
          ),
        ),
        AttentionReason.progressError,
      );
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(
            index: 0,
            name: 'a',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.pausedOrWarning,
            ),
          ),
        ),
        AttentionReason.progressPaused,
      );
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(index: 0, name: 'claude', isActive: false),
          lowQuota: true,
        ),
        AttentionReason.lowQuota,
      );
      expect(
        terminalWindowAttentionReason(
          const TmuxWindow(
            index: 0,
            name: 'claude',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 40,
            ),
          ),
        ),
        isNull,
        reason: 'Normal progress is activity, not attention.',
      );
    });
  });

  group('nativeTurnState', () {
    test('prefers attached state, then bridge in-flight counts', () {
      expect(
        nativeTurnState(
          session: fakeAcpSession(promptStatus: AcpPromptStatus.streaming),
          bridge: bridge(),
        ),
        NativeTurnState.running,
      );
      expect(
        nativeTurnState(
          session: fakeAcpSession(status: AcpConnectionStatus.detached),
          bridge: bridge(inFlight: 1),
        ),
        NativeTurnState.running,
      );
      expect(nativeTurnState(bridge: bridge()), NativeTurnState.idle);
      expect(
        nativeTurnState(
          session: fakeAcpSession(status: AcpConnectionStatus.detached),
        ),
        NativeTurnState.unknown,
      );
    });
  });

  group('compareAttentionSortKeys', () {
    test('orders by tier, then working rows, then recency, then index', () {
      final now = DateTime(2026, 1, 1, 12);
      final keys = [
        AttentionSortKey(
          index: 0,
          lastActivity: now.subtract(const Duration(hours: 2)),
        ),
        AttentionSortKey(
          index: 1,
          lastActivity: now.subtract(const Duration(minutes: 5)),
        ),
        const AttentionSortKey(index: 2, active: true),
        const AttentionSortKey(index: 3, reason: AttentionReason.lowQuota),
        const AttentionSortKey(index: 4, reason: AttentionReason.alert),
        const AttentionSortKey(index: 5, reason: AttentionReason.permission),
        const AttentionSortKey(index: 6, active: true),
        const AttentionSortKey(index: 7),
      ]..sort(compareAttentionSortKeys);
      expect(keys.map((key) => key.index), [5, 4, 3, 2, 6, 1, 0, 7]);
    });

    test('busy rows keep window order however recent their output', () {
      final now = DateTime(2026, 1, 1, 12);
      final keys = [
        AttentionSortKey(index: 2, active: true, lastActivity: now),
        AttentionSortKey(
          index: 1,
          active: true,
          lastActivity: now.subtract(const Duration(seconds: 5)),
        ),
      ]..sort(compareAttentionSortKeys);
      expect(keys.map((key) => key.index), [1, 2]);
    });
  });

  test('an idle-only snapshot still reads as activity', () {
    final now = DateTime(2026, 1, 1, 12);
    const busy = TmuxWindow(
      index: 0,
      name: 'a',
      isActive: false,
      idleSeconds: 2,
    );
    const quiet = TmuxWindow(
      index: 1,
      name: 'b',
      isActive: false,
      idleSeconds: 600,
    );
    expect(terminalWindowRecentlyActive(busy, now: now), isTrue);
    expect(terminalWindowRecentlyActive(quiet, now: now), isFalse);
    expect(
      terminalWindowLastActivity(quiet, now: now),
      now.subtract(const Duration(minutes: 10)),
    );
  });

  test('terminal activity is recent within the quiet threshold', () {
    final now = DateTime(2026, 1, 1, 12);
    TmuxWindow window(int secondsAgo) => TmuxWindow(
      index: 0,
      name: 'a',
      isActive: false,
      lastActivityEpochSeconds:
          now.subtract(Duration(seconds: secondsAgo)).millisecondsSinceEpoch ~/
          1000,
    );
    expect(terminalWindowRecentlyActive(window(3), now: now), isTrue);
    expect(terminalWindowRecentlyActive(window(60), now: now), isFalse);
    expect(
      terminalWindowRecentlyActive(
        const TmuxWindow(index: 0, name: 'a', isActive: false),
        now: now,
      ),
      isFalse,
    );
  });
}
