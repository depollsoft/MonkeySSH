// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/controllers/acp_turn_recovery.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_turn_recovery_banner.dart';

import '../support/fake_acp_session_manager.dart';

Widget _app(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(size: Size(400, 800), disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

void registerAcpTurnRecoveryTests() {
  group('turn recovery in the composer', () {
    setUp(() => FluttyTheme.debugUseSystemFonts = true);
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    Future<AcpComposerController> pumpComposer(
      WidgetTester tester,
      RecordingAcpSessionManager manager,
    ) async {
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
        ),
      );
      return controller;
    }

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
