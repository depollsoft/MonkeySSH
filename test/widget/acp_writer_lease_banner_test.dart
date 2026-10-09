// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_writer_lease_banner.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockSshSession extends Mock implements SshSession {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

final _now = DateTime(2026, 10, 9, 12);

MonkeyMuxAcpRemoteWriter _writer({
  String? label = 'iPad',
  Duration idle = const Duration(minutes: 3),
  bool leaseLost = false,
}) => MonkeyMuxAcpRemoteWriter(
  label: label,
  lastActiveAt: _now.subtract(idle),
  leaseLost: leaseLost,
);

Widget _banner(
  MonkeyMuxAcpRemoteWriter writer, {
  VoidCallback? onTakeOver,
  bool busy = false,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? FluttyTheme.light,
  home: Scaffold(
    body: AcpWriterLeaseBanner(
      writer: writer,
      busy: busy,
      clock: () => _now,
      onTakeOver: onTakeOver ?? () {},
    ),
  ),
);

AcpSessionState _heldSession(MonkeyMuxAcpRemoteWriter writer) {
  final session = fakeAcpSession(status: AcpConnectionStatus.detached);
  return session.copyWith(
    attached: false,
    transportState: MonkeyMuxAcpTransportState(
      status: MonkeyMuxAcpTransportStatus.heldElsewhere,
      bridgeId: session.key.bridgeId,
      lastDeliveredSequence: 0,
      writer: writer,
    ),
  );
}

Widget _chat(FakeAcpSessionManager manager) {
  final ssh = _MockSshService();
  final sshSession = _MockSshSession();
  when(() => sshSession.connectionId).thenReturn(7);
  when(() => ssh.getSessionsForHost(any())).thenReturn([sshSession]);
  final launchPreferences = _MockHostCliLaunchPreferencesService();
  when(() => launchPreferences.getPreferencesForHost(any()))
      .thenAnswer((_) async => const HostCliLaunchPreferences());
  final key = fakeAcpKey();
  return ProviderScope(
    overrides: [
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
      hostCliLaunchPreferencesServiceProvider.overrideWithValue(
        launchPreferences,
      ),
    ],
    child: MaterialApp(
      home: AgentChatScreen(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
        attachmentActionsBuilder: (_, _) =>
            const AcpComposerAttachmentActions(),
        connectOnMount: false,
      ),
    ),
  );
}

void main() {
  setUpAll(() => FluttyTheme.debugUseSystemFonts = true);
  tearDownAll(() => FluttyTheme.debugUseSystemFonts = false);

  test('activity reads as a coarse relative time', () {
    String format(Duration idle) =>
        formatAcpWriterActivity(_now.subtract(idle), _now);
    expect(format(const Duration(seconds: 40)), 'active just now');
    expect(format(const Duration(minutes: 3)), 'active 3 min ago');
    expect(format(const Duration(minutes: 125)), 'active 2 h ago');
    expect(format(const Duration(days: 3)), 'active 3 d ago');
    // A host clock slightly ahead never reads as a future time.
    expect(format(const Duration(seconds: -5)), 'active just now');
  });

  testWidgets('names the device holding the chat and takes over in one tap', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_banner(_writer(), onTakeOver: () => taps++));

    expect(find.text('controlled by iPad'), findsOneWidget);
    expect(find.text('active 3 min ago · read-only here'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Take over'));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.byType(AcpWriterLeaseBanner)),
      matchesSemantics(
        label:
            'Controlled by iPad, active 3 min ago. Read-only on this device.',
        isLiveRegion: true,
      ),
    );
  });

  testWidgets('offers take back after this device lost the chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      _banner(_writer(label: null, leaseLost: true, idle: Duration.zero)),
    );

    expect(find.text('controlled by another device'), findsOneWidget);
    expect(find.text('active just now · read-only here'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Take back'), findsOneWidget);
  });

  Widget pollingBanner(Future<void> Function() onRefresh) => MaterialApp(
    home: Scaffold(
      body: AcpWriterLeaseBanner(
        writer: _writer(),
        clock: () => _now,
        onTakeOver: () {},
        onRefresh: onRefresh,
      ),
    ),
  );

  testWidgets('asks who holds the chat about once a minute', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(pollingBanner(() async => refreshes++));

    await tester.pump(const Duration(seconds: 59));
    expect(refreshes, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(refreshes, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 2);
  });

  testWidgets('does not ask while the app is in the background', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(pollingBanner(() async => refreshes++));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pump(const Duration(minutes: 3));
    expect(refreshes, 0);
  });

  testWidgets('does not ask while another route covers the chat', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      TickerMode(enabled: false, child: pollingBanner(() async => refreshes++)),
    );

    await tester.pump(const Duration(minutes: 3));
    expect(refreshes, 0);
  });

  testWidgets('does not start a second ask while one is running', (
    tester,
  ) async {
    var refreshes = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(
      pollingBanner(() {
        refreshes++;
        return pending.future;
      }),
    );

    await tester.pump(const Duration(minutes: 3));
    expect(refreshes, 1);
    pending.complete();
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 2);
  });

  testWidgets('a take-over in progress cannot be tapped again', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _banner(_writer(), busy: true, onTakeOver: () => taps++),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Connecting'));
    expect(taps, 0);
  });

  for (final (name, theme) in [
    ('light', FluttyTheme.light),
    ('dark', FluttyTheme.dark),
  ]) {
    testWidgets('meets tap target and contrast guidelines in $name theme', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_banner(_writer(), theme: theme));

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }

  testWidgets('a held chat is read-only and takes over from its banner', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [_heldSession(_writer(idle: Duration.zero))],
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(_chat(manager));
    await tester.pump();

    expect(find.byType(AcpWriterLeaseBanner), findsOneWidget);
    expect(find.text('controlled by iPad'), findsOneWidget);
    expect(find.textContaining('read-only'), findsWidgets);
    expect(find.text('Reconnect'), findsNothing);
    // The take-over sits on the composer it unlocks, within thumb reach.
    expect(
      tester.getBottomLeft(find.byType(AcpWriterLeaseBanner)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AcpComposer)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(AcpWriterLeaseBanner)).dy,
      greaterThan(400),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Take over'));
    await tester.pump();
    await tester.pump();

    expect(manager.reconnectTakeOvers, [true]);
    expect(manager.reconnects.single.bridgeId, fakeAcpKey().bridgeId);
  });
}
