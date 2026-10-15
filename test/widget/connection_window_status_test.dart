// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/terminal_program_status.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/acp_mux_window_status_badge.dart';
import 'package:monkeyssh/presentation/widgets/acp_session_presentation.dart';
import 'package:monkeyssh/presentation/widgets/attention_presentation.dart';
import 'package:monkeyssh/presentation/widgets/connection_window_status.dart';
import 'package:monkeyssh/presentation/widgets/mux_window_status_badge.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_status_badge.dart';

import '../support/fake_acp_session_manager.dart';

final _now = DateTime(2026, 1, 1, 12);

int _epochSecondsAgo(int seconds) =>
    _now.subtract(Duration(seconds: seconds)).millisecondsSinceEpoch ~/ 1000;

MonkeyMuxAcpBridgeMetadata _bridge(
  String id, {
  String? sessionId,
  int pending = 0,
  int inFlight = 0,
}) => MonkeyMuxAcpBridgeMetadata(
  id: id,
  providerId: 'builtin:copilot-cli',
  sessionId: sessionId ?? 'session-$id',
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

    test('keeps forked sessions that share a server-owned bridge', () {
      final first = fakeAcpSession(key: fakeAcpKey(acpSessionId: 'first'));
      final fork = fakeAcpSession(key: fakeAcpKey(acpSessionId: 'fork'));
      final orphan = fakeAcpSession(key: fakeAcpKey(bridgeId: 'orphan'));
      final entries = buildConnectionWindowEntries(
        windows: const [
          TmuxWindow(
            index: 2,
            name: 'agent',
            isActive: false,
            nativeAcpBridgeId: 'bridge-1',
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
        ],
        sessions: [first, fork, orphan],
        now: _now,
      );
      final byIndex = {
        for (final entry in entries) entry.index: entry.session?.key,
      };
      expect(
        byIndex,
        {2: fork.key, 3: orphan.key, 4: first.key},
        reason:
            'The navigator binds the window to the last session; the '
            'orphan keeps its navigator number and the other fork follows.',
      );
    });

    test('untracked native windows count toward quota warnings', () {
      const window = TmuxWindow(
        index: 1,
        name: 'agent',
        isActive: false,
        nativeAcpBridgeId: 'b1',
        nativeAcpProviderId: AcpBuiltinProviderIds.claudeAgent,
      );
      final identities = connectionWindowQuotaIdentities(
        windows: const [window],
        sessions: const [],
      ).toSet();
      expect(identities, {(AgentLaunchTool.claudeCode, null)});
      final entry = buildConnectionWindowEntries(
        windows: const [window],
        sessions: const [],
        lowQuota: identities,
        now: _now,
      ).single;
      expect(entry.reason, AttentionReason.lowQuota);
    });

    test('schedules a re-sort when an active row will go quiet', () {
      final entries = buildConnectionWindowEntries(
        windows: [
          TmuxWindow(
            index: 0,
            name: 'build',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(10),
          ),
          TmuxWindow(
            index: 1,
            name: 'old',
            isActive: false,
            lastActivityEpochSeconds: _epochSecondsAgo(600),
          ),
        ],
        sessions: const [],
        now: _now,
      );
      expect(
        connectionWindowsNextResort(entries, now: _now),
        const Duration(seconds: 6),
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
          'b1': _bridge('b1', sessionId: 'session-1', pending: 1),
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

    testWidgets('a program\'s OSC 7501 status replaces inferred activity', (
      tester,
    ) async {
      TmuxWindow reporting(
        TerminalProgramState state, {
        TerminalProgramBlockedKind? kind,
        int? progress,
      }) => TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: false,
        lastActivityEpochSeconds: _epochSecondsAgo(2),
        programStatus: TerminalProgramStatus(
          state: state,
          kind: kind,
          progress: progress,
        ),
      );

      final idle = _single(reporting(TerminalProgramState.idle));
      expect(idle.sortKey.active, isFalse);
      expect(connectionWindowsNextResort([idle], now: _now), isNull);
      await _pumpChip(tester, idle);
      expect(find.text('idle'), findsOneWidget);
      expect(find.text('active'), findsNothing);
      expect(
        find.bySemanticsLabel(
          RegExp('terminal window idle, reported by the program'),
        ),
        findsOneWidget,
      );

      final working = _single(
        reporting(TerminalProgramState.working, progress: 40),
      );
      expect(working.sortKey.active, isTrue);
      await _pumpChip(tester, working);
      expect(find.text('40%'), findsOneWidget);

      await _pumpChip(tester, _single(reporting(TerminalProgramState.done)));
      expect(find.text('done'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

      final blocked = _single(
        reporting(
          TerminalProgramState.blocked,
          kind: TerminalProgramBlockedKind.permission,
        ),
      );
      expect(blocked.reason, AttentionReason.permission);
      await _pumpChip(tester, blocked);
      expect(find.text('permission'), findsOneWidget);

      await _pumpChip(tester, _single(reporting(TerminalProgramState.blocked)));
      expect(find.text('blocked'), findsOneWidget);
      expect(find.byIcon(Icons.front_hand_outlined), findsOneWidget);

      await _pumpChip(tester, _single(reporting(TerminalProgramState.error)));
      expect(find.text('error'), findsOneWidget);
    });

    testWidgets('an OSC 7501 reporter with no status is not guessed', (
      tester,
    ) async {
      final entry = _single(
        TmuxWindow(
          index: 0,
          name: 'claude',
          isActive: false,
          lastActivityEpochSeconds: _epochSecondsAgo(2),
          programStatusReporter: true,
        ),
      );
      expect(entry.sortKey.active, isFalse);
      expect(connectionWindowsNextResort([entry], now: _now), isNull);
      await _pumpChip(tester, entry);
      expect(find.text('no status'), findsOneWidget);
      expect(find.text('active'), findsNothing);
      expect(find.byType(InferredActivityChip), findsNothing);
      expect(
        find.bySemanticsLabel(
          RegExp('^terminal window has not reported a status'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('day-old labels keep advancing', (tester) async {
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
                  lastActivityEpochSeconds: _epochSecondsAgo(
                    const Duration(days: 1, hours: 23).inSeconds,
                  ),
                ),
              ),
              now: () => now,
            ),
          ),
        ),
      );
      expect(find.text('quiet 1d'), findsOneWidget);
      now = now.add(const Duration(hours: 1));
      await tester.pump(const Duration(hours: 1));
      expect(find.text('quiet 2d'), findsOneWidget);
    });

    testWidgets('a session that has not attached reads starting, not idle', (
      tester,
    ) async {
      await _pumpChip(
        tester,
        buildConnectionWindowEntries(
          windows: const [],
          sessions: [fakeAcpSession(status: AcpConnectionStatus.idle)],
          now: _now,
        ).single,
      );
      expect(find.text('starting'), findsOneWidget);
      expect(find.text('idle'), findsNothing);
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

  group('one colour rule', () {
    Color fill(WidgetTester tester, Finder badge) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(of: badge, matching: find.byType(DecoratedBox)).first,
      );
      return (box.decoration as BoxDecoration).color!;
    }

    Future<void> pumpPair(WidgetTester tester, Widget a, Widget b) =>
        tester.pumpWidget(
          MaterialApp(
            theme: FluttyTheme.dark,
            home: Scaffold(
              body: Column(
                children: [
                  KeyedSubtree(key: const ValueKey('navigator'), child: a),
                  KeyedSubtree(key: const ValueKey('connections'), child: b),
                ],
              ),
            ),
          ),
        );

    testWidgets('a blocked agent reads the same here and in the navigator', (
      tester,
    ) async {
      for (final kind in [...TerminalProgramBlockedKind.values, null]) {
        final window = TmuxWindow(
          index: 1,
          name: 'claude',
          isActive: false,
          programStatus: TerminalProgramStatus(
            state: TerminalProgramState.blocked,
            kind: kind,
          ),
        );
        await pumpPair(
          tester,
          TmuxWindowStatusBadge(window: window),
          ConnectionWindowStatusChip(entry: _single(window), now: () => _now),
        );
        final navigator = find.byKey(const ValueKey('navigator'));
        final connections = find.byKey(const ValueKey('connections'));
        expect(fill(tester, connections), fill(tester, navigator));
        final icon = tester
            .widget<Icon>(
              find.descendant(of: navigator, matching: find.byType(Icon)),
            )
            .icon;
        expect(
          find.descendant(of: connections, matching: find.byIcon(icon!)),
          findsOneWidget,
          reason: 'Blocked kind $kind uses one icon on both screens.',
        );
      }

      final waiting = fakeAcpSession(
        pendingPermissions: [
          AcpPendingPermission(
            requestKey: 'r1',
            sessionId: 'session-1',
            toolCallId: 't1',
            options: const [],
            requestedAt: _now,
          ),
        ],
      );
      await pumpPair(
        tester,
        AcpMuxWindowStatusBadge(session: waiting),
        ConnectionWindowStatusChip(
          entry: buildConnectionWindowEntries(
            windows: const [],
            sessions: [waiting],
            now: _now,
          ).single,
          now: () => _now,
        ),
      );
      expect(
        fill(tester, find.byKey(const ValueKey('connections'))),
        fill(tester, find.byKey(const ValueKey('navigator'))),
        reason: 'A native agent blocked on a permission is red on both.',
      );
    });

    test('no reason is louder than one that sorts above it', () {
      int loudness(AcpStatusTone tone) => switch (tone) {
        AcpStatusTone.error => 3,
        AcpStatusTone.warning => 2,
        AcpStatusTone.active => 1,
        AcpStatusTone.neutral => 0,
      };
      for (final upper in AttentionReason.values) {
        for (final lower in AttentionReason.values) {
          if (upper.tier >= lower.tier) continue;
          expect(
            loudness(upper.tone),
            greaterThanOrEqualTo(loudness(lower.tone)),
            reason: '${upper.name} sorts above ${lower.name}.',
          );
        }
      }
    });

    test('pill labels clear 4.5:1 on every app and terminal theme', () {
      final themes = <String, ThemeData>{
        'light': FluttyTheme.light,
        'dark': FluttyTheme.dark,
        for (final terminal in TerminalThemes.all)
          for (final brightness in Brightness.values)
            '${terminal.name} ${brightness.name}':
                FluttyTheme.fromTerminalTheme(terminal, brightness: brightness),
      };
      for (final MapEntry(key: name, value: theme) in themes.entries) {
        for (final tone in AcpStatusTone.values) {
          final (foreground, background) = attentionToneColors(
            theme.colorScheme,
            tone,
          );
          expect(
            statusPillContrast(foreground, background),
            greaterThanOrEqualTo(statusPillMinContrast),
            reason: '${tone.name} on $name',
          );
        }
      }
    });

    testWidgets('a pill shades a fill its label cannot be read on', (
      tester,
    ) async {
      const red = Color(0xFFFF4757);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MuxWindowStatusBadge(
              semanticsLabel: 'terminal window rang the bell',
              label: 'alert',
              icon: Icons.notifications_active,
              foregroundColor: Colors.white,
              backgroundColor: red,
            ),
          ),
        ),
      );
      final background = fill(tester, find.byType(MuxWindowStatusBadge));
      expect(statusPillContrast(Colors.white, red), lessThan(4.5));
      expect(
        statusPillContrast(Colors.white, background),
        greaterThanOrEqualTo(statusPillMinContrast),
      );
      expect(legiblePillColors(Colors.black, red), (
        Colors.black,
        red,
      ), reason: 'A legible pair is left as the theme made it.');
    });
  });

  group('row order under a finger', () {
    testWidgets('rows hold still while touched, then re-sort', (tester) async {
      TmuxWindow window(
        String name,
        int index,
        int quietFor, {
        String? flags,
      }) => TmuxWindow(
        index: index,
        name: name,
        isActive: false,
        flags: flags,
        lastActivityEpochSeconds: _epochSecondsAgo(quietFor),
      );
      final quietA = window('a', 0, 60);
      final quietB = window('b', 1, 600);
      Future<void> pump(List<TmuxWindow> windows) => tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: _OrderHarness(windows: windows)),
          ),
        ),
      );
      double top(String name) => tester.getTopLeft(find.text(name)).dy;

      await pump([quietA, quietB]);
      expect(top('a'), lessThan(top('b')));

      final finger = await tester.startGesture(
        tester.getCenter(find.text('a')),
      );
      await pump([quietA, window('b', 1, 600, flags: '#')]);
      expect(
        top('a'),
        lessThan(top('b')),
        reason: 'The bell must not move b under the finger.',
      );
      await finger.up();
      await tester.pump(connectionWindowOrderHold ~/ 2);
      expect(top('a'), lessThan(top('b')), reason: 'Still settling.');

      await tester.pump(connectionWindowOrderHold);
      expect(top('b'), lessThan(top('a')), reason: 'Free again: re-sorted.');

      await pump([window('a', 0, 60, flags: '#'), quietB]);
      expect(
        top('a'),
        lessThan(top('b')),
        reason: 'Untouched, the list follows attention at once.',
      );
    });
  });
}

class _OrderHarness extends ConsumerStatefulWidget {
  const _OrderHarness({required this.windows});

  final List<TmuxWindow> windows;

  @override
  ConsumerState<_OrderHarness> createState() => _OrderHarnessState();
}

class _OrderHarnessState extends ConsumerState<_OrderHarness> {
  late final _inputs = ConnectionAttentionInputs(
    onResort: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void dispose() {
    _inputs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _inputs.entries(
      context,
      ref,
      windows: widget.windows,
      sessions: const [],
      hostId: null,
      usesMonkeyMux: false,
      session: null,
      now: _now,
    );
    return _inputs.holdOrderWhileTouched(
      child: Column(
        children: [
          for (final entry in entries)
            SizedBox(height: 48, child: Text(entry.window!.name)),
        ],
      ),
    );
  }
}
