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
import 'package:monkeyssh/presentation/widgets/acp_transcript_search_bar.dart';
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
  bool failed = false,
  ThemeData? theme,
  DateTime Function()? clock,
  String localDeviceLabel = 'Mac',
}) => MaterialApp(
  theme: theme ?? FluttyTheme.light,
  home: Scaffold(
    body: AcpWriterLeaseBanner(
      writer: writer,
      busy: busy,
      failed: failed,
      clock: clock ?? () => _now,
      localDeviceLabel: localDeviceLabel,
      onTakeOver: onTakeOver ?? () {},
    ),
  ),
);

const _liveLabel = 'Controlled by iPad. Read-only on this device.';

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
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_banner(_writer(), onTakeOver: () => taps++));

    expect(find.text('controlled by iPad'), findsOneWidget);
    expect(find.text('active 3 min ago'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Take over'));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.bySemanticsLabel(_liveLabel)),
      matchesSemantics(label: _liveLabel, isLiveRegion: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Active 3 min ago')),
      matchesSemantics(label: 'Active 3 min ago'),
    );
    handle.dispose();
  });

  testWidgets('the live region stays put as the activity time moves on', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var now = _now;
    await tester.pumpWidget(_banner(_writer(), clock: () => now));

    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 31));

    // The time is visible and readable, but only the stable sentence is
    // announced, so a screen reader does not repeat the banner each minute.
    expect(find.text('active 5 min ago'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel(_liveLabel)),
      matchesSemantics(label: _liveLabel, isLiveRegion: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Active 5 min ago')),
      matchesSemantics(label: 'Active 5 min ago'),
    );
    handle.dispose();
  });

  testWidgets('a device of the same kind reads as another one', (tester) async {
    await tester.pumpWidget(_banner(_writer(), localDeviceLabel: 'iPad'));

    expect(find.text('controlled by another iPad'), findsOneWidget);
  });

  testWidgets('a failed take over says so and offers to try again', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _banner(_writer(), failed: true, onTakeOver: () => taps++),
    );

    expect(find.text("couldn't take over"), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      find.bySemanticsLabel('$_liveLabel Could not take over.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    expect(taps, 1);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });

  testWidgets('the button keeps its width while connecting', (tester) async {
    await tester.pumpWidget(_banner(_writer()));
    final idle = tester.getSize(find.byType(FilledButton));
    await tester.pumpWidget(_banner(_writer(), busy: true));
    final busy = tester.getSize(find.byType(FilledButton));

    expect(busy.width, idle.width);
  });

  testWidgets('offers take back after this device lost the chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      _banner(_writer(label: null, leaseLost: true, idle: Duration.zero)),
    );

    expect(find.text('controlled by another device'), findsOneWidget);
    expect(find.text('active just now'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Take back'), findsOneWidget);
  });

  Widget pollingBanner(Future<void> Function() onRefresh) => MaterialApp(
    home: Scaffold(
      body: AcpWriterLeaseBanner(
        writer: _writer(),
        clock: () => _now,
        localDeviceLabel: 'Mac',
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

  testWidgets('asks again when the app returns to the foreground', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(pollingBanner(() async => refreshes++));
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(refreshes, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(refreshes, 1);
  });

  testWidgets('asks again when the chat is shown again', (tester) async {
    var refreshes = 0;
    Widget build({required bool visible}) => TickerMode(
      enabled: visible,
      child: pollingBanner(() async => refreshes++),
    );
    await tester.pumpWidget(build(visible: true));
    await tester.pumpWidget(build(visible: false));
    expect(refreshes, 0);

    await tester.pumpWidget(build(visible: true));
    await tester.pump();
    expect(refreshes, 1);
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

    expect(find.text('connecting…'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Take over'));
    expect(taps, 0);
  });

  testWidgets('with large text on a phone the button moves under the text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: 2,
        maxScaleFactor: 2,
        child: _banner(_writer(label: 'Android tablet')),
      ),
    );

    final name = find.text('controlled by Android tablet');
    final button = find.widgetWithText(FilledButton, 'Take over');
    expect(
      tester.getTopLeft(button).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(name).dy),
    );
    // The device name keeps the full width instead of a sliver beside the
    // button.
    expect(tester.getSize(name).width, greaterThan(250));
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
    // Opened read-only from a native window, the chat is in no recent list;
    // the take over still attaches in the session's own directory.
    expect(manager.reconnects.single.cwd, '/home/dev/project');
  });

  testWidgets('the banner folds with the composer while search has focus', (
    tester,
  ) async {
    // A phone with its keyboard up.
    tester.view
      ..physicalSize = const Size(390, 800)
      ..devicePixelRatio = 1
      ..viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    final manager = FakeAcpSessionManager(
      sessions: [_heldSession(_writer(idle: Duration.zero))],
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(_chat(manager));
    await tester.pumpAndSettle();
    expect(find.byType(AcpWriterLeaseBanner), findsOneWidget);

    await tester.tap(find.byTooltip('Search chat'));
    await tester.pumpAndSettle();
    expect(find.byType(AcpTranscriptSearchBar), findsOneWidget);
    expect(find.byType(AcpComposer), findsNothing);
    expect(find.byType(AcpWriterLeaseBanner), findsNothing);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.byType(AcpWriterLeaseBanner), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(AcpWriterLeaseBanner)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AcpComposer)).dy),
    );
  });

  testWidgets('a failed take over keeps the read-only chat and says so', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [_heldSession(_writer(idle: Duration.zero))],
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(_chat(manager));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Take over'));
    await tester.pump();
    await tester.pump();

    // The manager kept the frozen view, so the chat stays on screen with an
    // inline failure instead of a full-screen error.
    expect(find.byType(AcpWriterLeaseBanner), findsOneWidget);
    expect(find.text("couldn't take over"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    expect(find.text('No resume.'), findsNothing);
  });

  testWidgets('an empty held chat says where its history is', (tester) async {
    final manager = FakeAcpSessionManager(
      sessions: [_heldSession(_writer(idle: Duration.zero))],
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(_chat(manager));
    await tester.pump();

    expect(
      find.text('Earlier messages load when you take over.'),
      findsOneWidget,
    );
    // The banner explains the state; "detached" would contradict it.
    expect(find.text('Detached from this session.'), findsNothing);
  });
}
