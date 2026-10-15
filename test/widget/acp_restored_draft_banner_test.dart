// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_composer_draft.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_restored_draft_banner.dart';

import '../support/fake_acp_session_manager.dart';

AcpSessionKey _key() => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: 'session',
);

AcpComposerController _restoredController(
  RecordingAcpSessionManager manager, {
  int unavailable = 0,
}) {
  final now = DateTime(2026);
  return AcpComposerController(
    manager: manager,
    sessionKey: _key(),
    initialSession: AcpSessionState(
      key: _key(),
      providerLabel: 'Copilot',
      cwd: '/home',
      status: AcpConnectionStatus.ready,
      createdAt: now,
      lastActivityAt: now,
    ),
  )..restoreDraft(
    AcpComposerDraftSnapshot(text: 'Summarise the failing CI run'),
    notice: AcpRestoredDraftNotice(unavailableAttachmentCount: unavailable),
  );
}

Future<void> _pump(
  WidgetTester tester,
  AcpComposerController controller, {
  ThemeData? theme,
}) async {
  tester.view
    ..physicalSize = const Size(390, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? FluttyTheme.dark,
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            AcpComposer(controller: controller),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('a restored draft is labelled unsent above the composer', (
    tester,
  ) async {
    final manager = RecordingAcpSessionManager();
    final controller = _restoredController(manager);
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.text('unsent draft restored'), findsOneWidget);
    expect(find.text('Saved before MonkeySSH closed.'), findsOneWidget);
    expect(find.text('Summarise the failing CI run'), findsOneWidget);
    final banner = tester.getRect(find.byType(AcpRestoredDraftBanner));
    final field = tester.getRect(find.byType(TextField));
    expect(banner.bottom, lessThanOrEqualTo(field.top));
    await tester.pump(const Duration(seconds: 2));
    expect(manager.prompts, isEmpty);
  });

  testWidgets('dismissing the banner keeps the draft', (tester) async {
    final manager = RecordingAcpSessionManager();
    final controller = _restoredController(manager);
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final dismiss = find.byTooltip('Hide notice');
    final size = tester.getSize(dismiss);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    await tester.tap(dismiss);
    await tester.pump();

    expect(find.byType(AcpRestoredDraftBanner), findsNothing);
    expect(controller.text, 'Summarise the failing CI run');
    expect(manager.prompts, isEmpty);
  });

  testWidgets('sending with an explicit tap clears the banner', (tester) async {
    final manager = RecordingAcpSessionManager();
    final controller = _restoredController(manager);
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();

    expect(manager.prompts, hasLength(1));
    expect(find.byType(AcpRestoredDraftBanner), findsNothing);
  });

  test('the note counts attachments that could not be restored', () {
    expect(
      AcpRestoredDraftBanner.detailFor(
        const AcpRestoredDraftNotice(unavailableAttachmentCount: 1),
      ),
      'Saved before MonkeySSH closed. '
      '1 attachment couldn’t be restored and was removed.',
    );
    expect(
      AcpRestoredDraftBanner.detailFor(
        const AcpRestoredDraftNotice(unavailableAttachmentCount: 3),
      ),
      endsWith('3 attachments couldn’t be restored and were removed.'),
    );
  });

  test('the note names lost attachments, then counts the rest', () {
    String detail(int count, List<String> names) =>
        AcpRestoredDraftBanner.detailFor(
          AcpRestoredDraftNotice(
            unavailableAttachmentCount: count,
            unavailableAttachmentNames: names,
            fromEarlierRun: false,
          ),
        );

    expect(
      detail(1, ['ci-log.txt']),
      'ci-log.txt couldn’t be restored and was removed.',
    );
    expect(
      detail(2, ['ci-log.txt', 'Pasted image.png']),
      'ci-log.txt and Pasted image.png couldn’t be restored and were '
      'removed.',
    );
    expect(
      detail(4, ['a.txt', 'b.txt', 'c.txt']),
      'a.txt, b.txt and 2 more couldn’t be restored and were removed.',
    );
    expect(
      detail(3, ['a.txt']),
      'a.txt and 2 more couldn’t be restored and were removed.',
    );
    expect(
      detail(1, ['screenshot-2026-10-15-at-09.41.27-terminal.png']),
      'screenshot-2026-10-15-at-09….png couldn’t be restored and was '
      'removed.',
    );
  });

  test('a draft from this run does not claim the app closed', () {
    expect(
      AcpRestoredDraftBanner.detailFor(
        const AcpRestoredDraftNotice(
          unavailableAttachmentCount: 1,
          unavailableAttachmentNames: ['Pasted image.png'],
          fromEarlierRun: false,
        ),
      ),
      isNot(contains('closed')),
    );
  });

  testWidgets('a draft that lost everything is not called restored', (
    tester,
  ) async {
    final manager = RecordingAcpSessionManager();
    final now = DateTime(2026);
    final controller =
        AcpComposerController(
          manager: manager,
          sessionKey: _key(),
          initialSession: AcpSessionState(
            key: _key(),
            providerLabel: 'Copilot',
            cwd: '/home',
            status: AcpConnectionStatus.ready,
            createdAt: now,
            lastActivityAt: now,
          ),
        )..restoreDraft(
          AcpComposerDraftSnapshot(text: ''),
          notice: const AcpRestoredDraftNotice(
            unavailableAttachmentCount: 1,
            unavailableAttachmentNames: ['Pasted image.png'],
          ),
        );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.text('unsent draft not restored'), findsOneWidget);
    expect(find.text('unsent draft restored'), findsNothing);
    expect(
      find.text(
        'Saved before MonkeySSH closed. Pasted image.png couldn’t be '
        'restored and was removed.',
      ),
      findsOneWidget,
    );
  });

  for (final (name, theme) in [
    ('dark', FluttyTheme.dark),
    ('light', FluttyTheme.light),
  ]) {
    testWidgets('meets contrast and tap-target guidelines in $name theme', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final manager = RecordingAcpSessionManager();
      final controller = _restoredController(manager, unavailable: 2);
      addTearDown(controller.dispose);
      await _pump(tester, controller, theme: theme);

      expect(find.textContaining('2 attachments'), findsOneWidget);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }
}
