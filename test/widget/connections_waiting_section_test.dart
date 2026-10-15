// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/connection_attention_provider.dart';
import 'package:monkeyssh/presentation/widgets/connections_waiting_section.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

final _workspaceSession =
    SshSession(
        connectionId: 20,
        hostId: 2,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'beta.example.com',
          port: 22,
          username: 'dev',
        ),
      )
      ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
      ..remoteMuxSessionName = 'mmux';

class _Sessions extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => {20: SshConnectionState.connected};

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == 20 ? _workspaceSession : null;
}

WaitingOnYouItem _item({
  AttentionReason reason = AttentionReason.permission,
  String bridgeId = 'bridge-1',
  String title = 'Fix the flaky test',
  bool tracked = true,
}) => WaitingOnYouItem(
  reason: reason,
  key: AcpSessionKey.of(
    hostId: 2,
    providerId: 'builtin:claude-code',
    bridgeId: bridgeId,
    acpSessionId: 'session-$bridgeId',
  ),
  hostLabel: 'Beta',
  title: title,
  providerLabel: 'Claude Code',
  cwdSummary: '…/api',
  since: DateTime(2026, 1, 1, 11, 55),
  tracked: tracked,
);

Widget _harness({
  required List<WaitingOnYouItem> items,
  required List<String> opened,
  ThemeData? theme,
  MonkeyMuxService? monkeyMux,
}) => ProviderScope(
  overrides: [
    waitingOnYouProvider.overrideWithValue(WaitingOnYouSnapshot(items)),
    if (monkeyMux != null) ...[
      monkeyMuxServiceProvider.overrideWithValue(monkeyMux),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ],
  ],
  child: MaterialApp(
    theme: theme ?? FluttyTheme.dark,
    home: Scaffold(
      body: ListView(
        children: [
          ConnectionsWaitingSection(
            now: () => DateTime(2026, 1, 1, 12),
            onOpen: (context, location) => opened.add(location),
          ),
        ],
      ),
    ),
  ),
);

final _chevron = find.byKey(const ValueKey('waiting-on-you-chevron'));

void main() {
  testWidgets('renders nothing when no session is waiting', (tester) async {
    await tester.pumpWidget(_harness(items: const [], opened: []));
    expect(find.text('waiting on you'), findsNothing);
    expect(
      find.byKey(const ValueKey('connections-waiting-section')),
      findsNothing,
    );
  });

  testWidgets('lists waiting sessions with a labelled reason, each opening', (
    tester,
  ) async {
    final opened = <String>[];
    final permission = _item();
    final signIn = _item(
      reason: AttentionReason.signIn,
      bridgeId: 'bridge-2',
      title: 'Claude Code',
    );
    await tester.pumpWidget(
      _harness(items: [permission, signIn], opened: opened),
    );

    expect(find.text('waiting on you'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Fix the flaky test'), findsOneWidget);
    // Reasons carry an icon and a word, never color alone.
    expect(find.text('permission'), findsOneWidget);
    expect(find.byIcon(Icons.pending_actions), findsOneWidget);
    expect(find.text('sign-in'), findsOneWidget);
    expect(find.byIcon(Icons.key), findsOneWidget);
    expect(find.text('Beta · 5m ago · Claude Code · …/api'), findsOneWidget);
    // The provider is not repeated when it is already the title.
    expect(find.text('Beta · 5m ago · …/api'), findsOneWidget);
    expect(_chevron, findsNWidgets(2));

    await tester.tap(find.text('Fix the flaky test'));
    expect(opened, [permission.chatLocation]);
    await tester.tap(_chevron.last);
    expect(opened, [permission.chatLocation, signIn.chatLocation]);
  });

  testWidgets('each row is one accessible Open button at least 44pt tall', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_harness(items: [_item()], opened: []));

    final row = find.byKey(ValueKey('waiting-on-you-${_item().key.value}'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
    expect(
      tester.getSemantics(row),
      matchesSemantics(
        label:
            'Open Fix the flaky test. Claude Code on Beta needs permission, '
            '5m ago.',
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('meets text contrast guidelines in light and dark themes', (
    tester,
  ) async {
    for (final theme in [FluttyTheme.light, FluttyTheme.dark]) {
      await tester.pumpWidget(
        _harness(
          items: [
            _item(),
            _item(reason: AttentionReason.hostRequest, bridgeId: 'b2'),
          ],
          opened: [],
          theme: theme,
        ),
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }
  });

  testWidgets('large text wraps the details instead of eliding them', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320 * 3, 900 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 900),
          textScaler: TextScaler.linear(2),
        ),
        child: _harness(
          items: [_item(title: 'A long session title that will not fit')],
          opened: [],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_chevron, findsOneWidget);
  });

  testWidgets('a host-reported row keeps its working directory in view', (
    tester,
  ) async {
    // A host-reported session is titled by its agent, so the working
    // directory is what tells two of them apart; it must not be elided on
    // a phone, even with larger text.
    for (final scale in [1.0, 1.3]) {
      tester.view
        ..physicalSize = const Size(390 * 3, 900 * 3)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final item = WaitingOnYouItem(
        reason: AttentionReason.permission,
        key: AcpSessionKey.of(
          hostId: 2,
          providerId: 'builtin:codex',
          bridgeId: 'bridge-9',
          acpSessionId: 'remote-session',
        ),
        hostLabel: 'Beta',
        title: 'Codex',
        providerLabel: 'Codex',
        cwdSummary: '…/billing-service',
        since: DateTime(2026, 1, 1, 11, 56),
        tracked: false,
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 900),
            textScaler: TextScaler.linear(scale),
          ),
          child: _harness(items: [item], opened: []),
        ),
      );
      final details = tester.renderObject<RenderParagraph>(
        find.text('Beta · 4m ago · …/billing-service'),
      );
      expect(
        details.didExceedMaxLines,
        isFalse,
        reason: 'At ${scale}x the working directory is cut off.',
      );
    }
  });

  group('opening an untracked session', () {
    late _MockMonkeyMuxService monkeyMux;
    late Completer<List<TmuxWindow>> windows;
    final item = _item(tracked: false, reason: AttentionReason.hostRequest);

    // Created inside each test body so the completion runs in the test's
    // fake-async zone.
    void stubWindows() {
      monkeyMux = _MockMonkeyMuxService();
      windows = Completer<List<TmuxWindow>>();
      when(
        () => monkeyMux.listWindows(
          _workspaceSession,
          'mmux',
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) => windows.future);
    }

    testWidgets('shows progress, then lands in the hosting workspace', (
      tester,
    ) async {
      stubWindows();
      final opened = <String>[];
      await tester.pumpWidget(
        _harness(items: [item], opened: opened, monkeyMux: monkeyMux),
      );
      await tester.tap(_chevron);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('waiting-on-you-opening')),
        findsOneWidget,
      );
      expect(opened, isEmpty);

      windows.complete([
        TmuxWindow(
          index: 2,
          name: 'agent',
          isActive: false,
          nativeAcpBridgeId: item.key.bridgeId,
          nativeAcpProviderId: item.key.providerId,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(opened, [item.terminalLocation(20)]);
      expect(
        find.byKey(const ValueKey('waiting-on-you-opening')),
        findsNothing,
      );
    });

    testWidgets('does not open after the user navigated away', (tester) async {
      stubWindows();
      final opened = <String>[];
      await tester.pumpWidget(
        _harness(items: [item], opened: opened, monkeyMux: monkeyMux),
      );
      await tester.tap(_chevron);
      await tester.pump();
      unawaited(
        Navigator.of(tester.element(find.text('waiting on you'))).push(
          MaterialPageRoute<void>(
            builder: (context) => const Scaffold(body: Text('elsewhere')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      windows.complete(const []);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });
  });
}
