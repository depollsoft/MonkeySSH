// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/terminal_program_status.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

import '../../support/fake_acp_session_manager.dart';

MonkeyMuxAcpBridgeMetadata bridge({
  String id = 'bridge-1',
  String? sessionId,
  int pending = 0,
  int inFlight = 0,
  int clients = 0,
  int? permissions,
  int? questions,
  MonkeyMuxAcpProviderState state = MonkeyMuxAcpProviderState.running,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  sessionId: sessionId,
  pendingPermissionCount: permissions,
  pendingInputCount: questions,
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

    test('a host that names the request kind labels it', () {
      expect(
        bridgeWaitingReason(bridge(pending: 2, permissions: 1, questions: 1)),
        AttentionReason.permission,
      );
      expect(
        bridgeWaitingReason(bridge(pending: 1, permissions: 0, questions: 1)),
        AttentionReason.input,
      );
      expect(
        bridgeWaitingReason(bridge(pending: 1, permissions: 0, questions: 0)),
        AttentionReason.hostRequest,
        reason: 'A file or terminal call is still a request no one answers.',
      );
      expect(
        acpSessionWaitingReason(
          fakeAcpSession(status: AcpConnectionStatus.detached),
          bridge: bridge(
            pending: 1,
            sessionId: 'session-1',
            permissions: 0,
            questions: 1,
          ),
        ),
        AttentionReason.input,
      );
    });

    test('a retained request the host no longer holds is not claimed', () {
      final detached = fakeAcpSession(
        status: AcpConnectionStatus.detached,
        pendingPermissions: [permission(DateTime(2026))],
      );
      // Answered on another device; the bridge's pending request is a
      // sibling fork's file read.
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(
            pending: 1,
            sessionId: 'sibling',
            permissions: 0,
            questions: 0,
          ),
        ),
        isNull,
      );
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(pending: 1, sessionId: 'sibling', permissions: 1),
        ),
        AttentionReason.permission,
      );
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(pending: 1, sessionId: 'sibling'),
        ),
        AttentionReason.permission,
        reason: 'A helper that cannot name kinds leaves the retained one.',
      );
    });

    test('a failed transport reads the host like a detached session', () {
      final failed = fakeAcpSession(
        status: AcpConnectionStatus.failed,
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'The agent connection failed.',
        ),
      );
      expect(acpSessionWaitingReason(failed), isNull);
      expect(
        acpSessionWaitingReason(
          failed,
          bridge: bridge(pending: 1, sessionId: 'session-1'),
        ),
        AttentionReason.hostRequest,
        reason: 'The agent kept running and asked again after the failure.',
      );
    });

    test("this app's client on a fork does not answer a detached fork", () {
      final detached = fakeAcpSession(
        status: AcpConnectionStatus.detached,
        pendingPermissions: [permission(DateTime(2026))],
      );
      final shared = bridge(pending: 1, clients: 1, sessionId: 'sibling');
      expect(acpSessionWaitingReason(detached, bridge: shared), isNull);
      expect(
        acpSessionWaitingReason(detached, bridge: shared, attachedHere: true),
        AttentionReason.permission,
        reason: 'The only attached client is this app, for a live sibling.',
      );
      expect(
        acpSessionWaitingReason(
          detached,
          bridge: bridge(pending: 1, clients: 2),
          attachedHere: true,
        ),
        isNull,
        reason: 'Another device is attached and may be answering.',
      );
      expect(
        bridgeWaitingReason(
          bridge(pending: 1, clients: 1, permissions: 0, questions: 0),
          attachedHere: true,
        ),
        isNull,
        reason: "The live fork's own file read is answered in moments.",
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

    test('reads a program\'s OSC 7501 status', () {
      TmuxWindow reporting(
        TerminalProgramState state, {
        TerminalProgramBlockedKind? kind,
        String? flags,
        TerminalProgress? progress,
      }) => TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: false,
        flags: flags,
        terminalProgress: progress,
        programStatus: TerminalProgramStatus(state: state, kind: kind),
      );

      expect(
        terminalWindowAttentionReason(
          reporting(
            TerminalProgramState.blocked,
            kind: TerminalProgramBlockedKind.permission,
          ),
        ),
        AttentionReason.permission,
      );
      expect(
        terminalWindowAttentionReason(
          reporting(
            TerminalProgramState.blocked,
            kind: TerminalProgramBlockedKind.question,
          ),
        ),
        AttentionReason.input,
      );
      expect(
        terminalWindowAttentionReason(
          reporting(
            TerminalProgramState.blocked,
            kind: TerminalProgramBlockedKind.auth,
          ),
        ),
        AttentionReason.signIn,
      );
      expect(
        terminalWindowAttentionReason(
          reporting(TerminalProgramState.blocked, flags: '#'),
        ),
        AttentionReason.blocked,
        reason: 'A blocked program outranks the alert flag.',
      );
      expect(
        terminalWindowAttentionReason(reporting(TerminalProgramState.error)),
        AttentionReason.progressError,
      );
      expect(
        terminalWindowAttentionReason(
          reporting(TerminalProgramState.working, flags: '#'),
        ),
        AttentionReason.alert,
        reason: 'Other reported states yield to the alert flag.',
      );
      expect(
        terminalWindowAttentionReason(
          reporting(
            TerminalProgramState.idle,
            progress: const TerminalProgress(
              state: TerminalProgressState.error,
            ),
          ),
        ),
        isNull,
        reason: 'A reported status replaces stale OSC 9;4 progress.',
      );
      expect(
        terminalWindowAttentionReason(reporting(TerminalProgramState.done)),
        isNull,
      );
      for (final reason in [
        AttentionReason.permission,
        AttentionReason.input,
        AttentionReason.signIn,
        AttentionReason.blocked,
      ]) {
        expect(reason.isWaitingOnYou, isTrue);
        expect(reason.tier, 0);
      }
    });
  });

  group('terminalWindowWorking', () {
    final now = DateTime(2026, 1, 1, 12);
    final recent = now.subtract(const Duration(seconds: 2));

    test('a reported status overrides inferred activity', () {
      TmuxWindow reporting(TerminalProgramState state) => TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: false,
        lastActivityEpochSeconds: recent.millisecondsSinceEpoch ~/ 1000,
        programStatus: TerminalProgramStatus(state: state),
      );
      expect(
        terminalWindowWorking(
          reporting(TerminalProgramState.working),
          now: now,
        ),
        isTrue,
      );
      expect(
        terminalWindowWorking(reporting(TerminalProgramState.idle), now: now),
        isFalse,
        reason: 'The program said it is idle, however recent its output.',
      );
      expect(
        terminalWindowWorking(reporting(TerminalProgramState.done), now: now),
        isFalse,
      );
    });

    test('a program that speaks OSC 7501 is never guessed busy', () {
      final reporter = TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: false,
        lastActivityEpochSeconds: recent.millisecondsSinceEpoch ~/ 1000,
        terminalProgress: const TerminalProgress(
          state: TerminalProgressState.indeterminate,
        ),
        programStatusReporter: true,
      );
      expect(
        terminalWindowWorking(reporter, now: now),
        isFalse,
        reason: 'A redraw of a reporter with no status is not work.',
      );
      expect(terminalWindowReportsOwnStatus(reporter), isTrue);
    });

    test('falls back to progress, then output timing', () {
      expect(
        terminalWindowWorking(
          const TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.indeterminate,
            ),
          ),
          now: now,
        ),
        isTrue,
      );
      expect(
        terminalWindowWorking(
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            lastActivityEpochSeconds: recent.millisecondsSinceEpoch ~/ 1000,
          ),
          now: now,
        ),
        isTrue,
      );
      expect(
        terminalWindowWorking(
          const TmuxWindow(index: 0, name: 'build', isActive: false),
          now: now,
        ),
        isFalse,
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
