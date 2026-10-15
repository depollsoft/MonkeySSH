// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/controllers/acp_turn_recovery.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_turn_recovery_banner.dart';

import '../support/fake_acp_session_manager.dart';

Widget _app(
  Widget child, {
  Size size = const Size(400, 800),
  double textScale = 1,
}) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: MediaQueryData(
      size: size,
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(body: child),
  ),
);

AcpTurnRecovery _lostAnswer() => AcpTurnRecovery(
  kind: AcpTurnRecoveryKind.unconfirmed,
  drafts: const [
    (
      text: 'migrate the db',
      attachments: <AcpComposerAttachment>[],
      submission: 1,
    ),
  ],
  submission: 1,
);

void registerAcpTurnRecoveryTests() {
  group('turn recovery in the composer', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    Future<AcpComposerController> pumpComposer(
      WidgetTester tester,
      RecordingAcpSessionManager manager, {
      Size size = const Size(400, 800),
      double textScale = 1,
    }) async {
      final controller = AcpComposerController(
        manager: manager,
        sessionKey: fakeAcpKey(),
        initialSession: fakeAcpSession(
          capabilities: const AcpAgentCapabilities(),
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: AcpComposer(controller: controller),
          ),
          size: size,
          textScale: textScale,
        ),
      );
      return controller;
    }

    testWidgets('both banners fit an accessibility text size', (tester) async {
      tester.view
        ..physicalSize = const Size(375, 1400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpConnectionClosedException();
      final controller = await pumpComposer(
        tester,
        manager,
        size: const Size(375, 1400),
        textScale: 3.1,
      );
      controller.setText('migrate the db');
      await controller.send();
      await tester.pump();
      manager.throwOnPrompt = const AcpRemoteException(
        code: -32603,
        message: 'Internal error',
      );
      controller.setText('try this');
      await controller.send();
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The actions sit under each message instead of squeezing it.
      expect(
        find.byKey(const ValueKey('acp-notice-stacked')),
        findsNWidgets(2),
      );
      final message = find.textContaining('may have run this anyway');
      expect(tester.getSize(message).width, greaterThan(200));
      await tester.tap(find.byKey(const ValueKey('acp-turn-recovery-edit')));
      await tester.pump();
      expect(controller.text, contains('migrate the db'));
    });

    testWidgets('a confirmed failure offers Retry, which resends', (
      tester,
    ) async {
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpRemoteException(
          code: -32603,
          message: 'Internal error',
        );
      final controller = await pumpComposer(tester, manager);
      controller.setText('try this');
      await controller.send();
      await tester.pump();

      expect(find.byKey(const ValueKey('acp-error-retry')), findsOneWidget);
      expect(find.byType(AcpTurnRecoveryBanner), findsNothing);
      manager.throwOnPrompt = null;
      await tester.tap(find.byKey(const ValueKey('acp-error-retry')));
      await tester.pump();
      expect(manager.prompts, hasLength(2));
      expect(find.byKey(const ValueKey('acp-error-retry')), findsNothing);
    });

    testWidgets('a lost answer offers Edit prompt but no Retry', (
      tester,
    ) async {
      final manager = RecordingAcpSessionManager()
        ..throwOnPrompt = const AcpConnectionClosedException();
      final controller = await pumpComposer(tester, manager);
      controller.setText('migrate the db');
      await controller.send();
      await tester.pump();

      expect(find.byKey(const ValueKey('acp-error-retry')), findsNothing);
      expect(find.textContaining('may have run this anyway'), findsOneWidget);
      expect(controller.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('acp-turn-recovery-edit')));
      await tester.pump();
      expect(controller.text, 'migrate the db');
      expect(find.byType(AcpTurnRecoveryBanner), findsNothing);
      expect(manager.prompts, hasLength(1));
    });
  });

  group('AcpTurnRecoveryBanner', () {
    testWidgets('keeps its actions beside the message at the default size', (
      tester,
    ) async {
      // The test font is wider than Inter, so a phone width would leave the
      // message less room than it really gets.
      tester.view
        ..physicalSize = const Size(600, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          AcpTurnRecoveryBanner(
            recovery: _lostAnswer(),
            onEdit: () {},
            onDismiss: () {},
          ),
          size: const Size(600, 800),
        ),
      );
      expect(find.byKey(const ValueKey('acp-notice-stacked')), findsNothing);
      final message = tester.getRect(
        find.textContaining('may have run this anyway'),
      );
      final edit = tester.getRect(
        find.byKey(const ValueKey('acp-turn-recovery-edit')),
      );
      expect(edit.left, greaterThanOrEqualTo(message.right));
      expect(edit.center.dy, closeTo(message.center.dy, 1));
    });

    testWidgets('Edit prompt is not accent text on the raised surface', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AcpTurnRecoveryBanner(
            recovery: _lostAnswer(),
            onEdit: () {},
            onDismiss: () {},
          ),
        ),
      );
      final scheme = FluttyTheme.dark.colorScheme;
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('acp-turn-recovery-edit')),
          matching: find.byType(RichText),
        ),
      );
      // The teal accent measures about 3:1 on this surface in the dark
      // theme, short of AA for 14 px text.
      expect(label.text.style?.color, scheme.onSurface);
    });

    testWidgets('a stopped turn offers Edit prompt with 44 pt targets', (
      tester,
    ) async {
      var edited = false;
      var dismissed = false;
      await tester.pumpWidget(
        _app(
          AcpTurnRecoveryBanner(
            recovery: AcpTurnRecovery(
              kind: AcpTurnRecoveryKind.cancelled,
              drafts: const [
                (
                  text: 'retry me',
                  attachments: <AcpComposerAttachment>[],
                  submission: 1,
                ),
              ],
              submission: 1,
            ),
            onEdit: () => edited = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      );
      expect(find.text('Turn stopped.'), findsOneWidget);
      final edit = find.byKey(const ValueKey('acp-turn-recovery-edit'));
      expect(tester.getSize(edit).height, greaterThanOrEqualTo(44));
      await tester.tap(edit);
      expect(edited, isTrue);
      await tester.tap(find.byTooltip('Dismiss'));
      expect(dismissed, isTrue);
    });

    testWidgets('a mid-turn failure names the risk with shape and text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AcpTurnRecoveryBanner(
            recovery: AcpTurnRecovery(
              kind: AcpTurnRecoveryKind.failedMidTurn,
              drafts: const [
                (
                  text: 'migrate',
                  attachments: <AcpComposerAttachment>[],
                  submission: 1,
                ),
              ],
              submission: 1,
            ),
            onEdit: () {},
            onDismiss: () {},
          ),
        ),
      );
      expect(find.textContaining('failed partway through'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });
}
