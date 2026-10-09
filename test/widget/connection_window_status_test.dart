// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/connection_window_status.dart';
import 'package:monkeyssh/presentation/widgets/mux_window_status_badge.dart';

import '../support/fake_acp_session_manager.dart';

final _now = DateTime(2026, 1, 1, 12);

int _epochSecondsAgo(int seconds) =>
    _now.subtract(Duration(seconds: seconds)).millisecondsSinceEpoch ~/ 1000;

MonkeyMuxAcpBridgeMetadata _bridge(
  String id, {
  int pending = 0,
  int inFlight = 0,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  providerId: 'builtin:copilot-cli',
  sessionId: 'session-$id',
  provider: 'Copilot CLI',
  commandHash: 'hash',
  state: MonkeyMuxAcpProviderState.running,
  clientCount: 0,
  pendingRequestCount: pending,
  inFlightTurnCount: inFlight,
  lastActivity: _now,
  startedAt: DateTime(2026),
  nextSequence: 1,
);

Future<void> _pumpChip(WidgetTester tester, ConnectionWindowEntry entry) =>
    tester.pumpWidget(
      MaterialApp(
        theme: FluttyTheme.dark,
        home: Scaffold(
          body: Center(
            child: ConnectionWindowStatusChip(entry: entry, now: () => _now),
          ),
        ),
      ),
    );

ConnectionWindowEntry _single(
  TmuxWindow window, {
  List<AcpSessionState> sessions = const [],
  Map<String, MonkeyMuxAcpBridgeMetadata> bridges = const {},
}) => buildConnectionWindowEntries(
  windows: [window],
  sessions: sessions,
  bridges: bridges,
  now: _now,
).single;

void main() {
  group('buildConnectionWindowEntries', () {
    test('shows a tracked native session once, as its server window', () {
      final bound = fakeAcpSession(key: fakeAcpKey(bridgeId: 'bound'));
      final orphan = fakeAcpSession(key: fakeAcpKey(bridgeId: 'orphan'));
      final entries = buildConnectionWindowEntries(
        windows: const [
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          TmuxWindow(
            index: 3,
            name: 'copilot',
            isActive: false,
            nativeAcpBridgeId: 'bound',
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
        ],
        sessions: [bound, orphan],
        now: _now,
      );

      expect(entries, hasLength(3));
      final native = entries.where((entry) => entry.isNative).toList();
      expect(native.map((entry) => entry.session?.key.bridgeId), {
        'bound',
        'orphan',
      });
      expect(
        native.firstWhere((entry) => entry.session == bound).index,
        3,
        reason: 'A bound session keeps its server window number.',
      );
      expect(
        native.firstWhere((entry) => entry.session == orphan).index,
        4,
        reason: 'An orphan session numbers after the last server window.',
      );
    });

    test('orders by attention, then working rows, then recency', () {
      final entries = buildConnectionWindowEntries(
        windows: [
          TmuxWindow(
            index: 0,
            name: 'old',
            isActive: true,
            lastActivityEpochSeconds: _epochSecondsAgo(7200),
          ),
          TmuxWindow(
            index: 1,
            name: 'recent',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(300),
          ),
          TmuxWindow(
            index: 2,
            name: 'busy',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(2),
          ),
          const TmuxWindow(index: 3, name: 'bell', isActive: false, flags: '#'),
          const TmuxWindow(
            index: 4,
            name: 'claude',
            isActive: false,
            currentCommand: 'claude',
          ),
        ],
        sessions: [
          fakeAcpSession(
            key: fakeAcpKey(bridgeId: 'ask'),
            pendingPermissions: [
              AcpPendingPermission(
                requestKey: 'r',
                sessionId: 'session-1',
                toolCallId: 't',
                options: const [],
                requestedAt: _now,
              ),
            ],
          ),
        ],
        lowQuota: const {(AgentLaunchTool.claudeCode, null)},
        now: _now,
      );

      expect(entries.map((entry) => entry.reason), [
        AttentionReason.permission,
        AttentionReason.alert,
        AttentionReason.lowQuota,
        null,
        null,
        null,
      ]);
      expect(entries.map((entry) => entry.index), [5, 3, 4, 2, 1, 0]);
    });

    test('detached native rows read host-reported requests', () {
      final detached = fakeAcpSession(
        key: fakeAcpKey(bridgeId: 'b1'),
        status: AcpConnectionStatus.detached,
      );
      final entries = buildConnectionWindowEntries(
        windows: const [
          TmuxWindow(
            index: 1,
            name: 'agent',
            isActive: false,
            nativeAcpBridgeId: 'untracked',
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
        ],
        sessions: [detached],
        bridges: {
          'b1': _bridge('b1', pending: 1),
          'untracked': _bridge('untracked', inFlight: 1),
        },
        now: _now,
      );
      expect(entries.first.session, detached);
      expect(entries.first.reason, AttentionReason.hostRequest);
      expect(entries.last.window?.nativeAcpBridgeId, 'untracked');
      expect(entries.last.sortKey.active, isTrue);
    });
  });

  group('ConnectionWindowStatusChip', () {
    testWidgets('outlines activity inferred from terminal output', (
      tester,
    ) async {
      await _pumpChip(
        tester,
        _single(
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(2),
          ),
        ),
      );
      expect(find.byType(InferredActivityChip), findsOneWidget);
      expect(find.byType(MuxWindowStatusBadge), findsNothing);
      expect(find.text('active'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'terminal window active, inferred from recent output',
        ),
        findsOneWidget,
      );

      await _pumpChip(
        tester,
        _single(
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(300),
          ),
        ),
      );
      expect(find.text('quiet 5m'), findsOneWidget);
    });

    testWidgets('fills states the program or agent reported', (tester) async {
      await _pumpChip(
        tester,
        _single(
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(2),
            terminalProgress: const TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 40,
            ),
          ),
        ),
      );
      expect(find.byType(MuxWindowStatusBadge), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);

      await _pumpChip(
        tester,
        _single(
          const TmuxWindow(
            index: 0,
            name: 'agent',
            isActive: false,
            nativeAcpBridgeId: 'b1',
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
          bridges: {'b1': _bridge('b1', inFlight: 1)},
        ),
      );
      expect(find.byType(MuxWindowStatusBadge), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await _pumpChip(
        tester,
        _single(
          const TmuxWindow(
            index: 0,
            name: 'agent',
            isActive: false,
            nativeAcpBridgeId: 'b1',
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
          bridges: {'b1': _bridge('b1')},
        ),
      );
      expect(find.text('idle'), findsOneWidget);

      await _pumpChip(
        tester,
        _single(
          const TmuxWindow(
            index: 0,
            name: 'agent',
            isActive: false,
            flags: '#',
          ),
        ),
      );
      expect(find.text('alert'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
    });

    testWidgets('a quiet label turns over without new output', (tester) async {
      var now = _now;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionWindowStatusChip(
              entry: _single(
                TmuxWindow(
                  index: 0,
                  name: 'build',
                  isActive: false,
                  lastActivityEpochSeconds: _epochSecondsAgo(10),
                ),
              ),
              now: () => now,
            ),
          ),
        ),
      );
      expect(find.text('active'), findsOneWidget);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('quiet'), findsOneWidget);
    });
  });
}
