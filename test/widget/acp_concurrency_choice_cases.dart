// ignore_for_file: public_member_api_docs

import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/presentation/widgets/acp_concurrency_choice.dart';

import '../support/fake_acp_session_manager.dart';

void registerAcpConcurrencyChoiceTests() {
  group('acp_concurrency_choice', () {
    Future<AcpConcurrencyChoice?> showAndTap(
      WidgetTester tester,
      String buttonText,
    ) async {
      final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
      final blockingSession = fakeAcpSession(
        key: blockingKey,
        title: 'Busy session',
      );
      final managerState = AcpSessionManagerState(sessions: [blockingSession]);
      AcpConcurrencyChoice? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showAcpConcurrencyChoice(
                    context,
                    decision: AcpConcurrencyRequiresChoice(
                      blockingSessionKeys: [blockingKey.value],
                    ),
                    managerState: managerState,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('one native chat on free'), findsOneWidget);
      expect(find.text('Busy session'), findsOneWidget);

      await tester.tap(find.text(buttonText));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('returns stopAndContinue when the user stops the session', (
      tester,
    ) async {
      final choice = await showAndTap(tester, 'Stop and continue free');
      expect(choice, AcpConcurrencyChoice.stopAndContinue);
    });

    testWidgets('cancellation dismisses the stale choice sheet', (
      tester,
    ) async {
      final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
      final managerState = AcpSessionManagerState(
        sessions: [fakeAcpSession(key: blockingKey)],
      );
      final cancellation = Completer<void>();
      AcpConcurrencyChoice? result;
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showAcpConcurrencyChoice(
                    context,
                    decision: AcpConcurrencyRequiresChoice(
                      blockingSessionKeys: [blockingKey.value],
                    ),
                    managerState: managerState,
                    cancellation: cancellation.future,
                  );
                  completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('one native chat on free'), findsOneWidget);

      cancellation.complete();
      await tester.pumpAndSettle();
      expect(find.text('one native chat on free'), findsNothing);
      expect(completed, isTrue);
      expect(result, isNull);
    });

    testWidgets('offers both the stop and upgrade choices', (tester) async {
      final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
      final managerState = AcpSessionManagerState(
        sessions: [fakeAcpSession(key: blockingKey)],
      );
      AcpConcurrencyChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showAcpConcurrencyChoice(
                    context,
                    decision: AcpConcurrencyRequiresChoice(
                      blockingSessionKeys: [blockingKey.value],
                    ),
                    managerState: managerState,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Stop and continue free'), findsOneWidget);
      expect(find.text('Unlock parallel native chats'), findsOneWidget);

      await tester.tap(find.text('Unlock parallel native chats'));
      await tester.pumpAndSettle();
      expect(result, AcpConcurrencyChoice.upgrade);
    });
  });
}
