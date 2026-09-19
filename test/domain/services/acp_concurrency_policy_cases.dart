// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';

void registerAcpConcurrencyPolicyTests() {
  group('acp_concurrency_policy', () {
    const policy = AcpConcurrencyPolicy();

    group('AcpConcurrencyPolicy.evaluate', () {
      test('allows the first live session for a free user', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {},
          candidateSessionKey: 'session-a',
          isProUnlocked: false,
        );
        expect(decision, const AcpConcurrencyAllowed());
      });

      test('allows reopening the same session without counting it twice', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {'session-a'},
          candidateSessionKey: 'session-a',
          isProUnlocked: false,
        );
        expect(decision, const AcpConcurrencyAllowed());
      });

      test(
        'allows reopening one of several existing sessions after downgrade',
        () {
          final decision = policy.evaluate(
            currentLiveSessionKeys: const {'session-a', 'session-b'},
            candidateSessionKey: 'session-a',
            isProUnlocked: false,
          );
          expect(decision, const AcpConcurrencyAllowed());
        },
      );

      test('requires a choice when moving from one live session to two', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {'session-a'},
          candidateSessionKey: 'session-b',
          isProUnlocked: false,
        );
        expect(decision, isA<AcpConcurrencyRequiresChoice>());
        final requiresChoice = decision as AcpConcurrencyRequiresChoice;
        expect(requiresChoice.blockingSessionKeys, ['session-a']);
        expect(
          requiresChoice.requiredFeature,
          MonetizationFeature.concurrentAcpSessions,
        );
      });

      test('lists every other live session as blocking', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {'session-a', 'session-b'},
          candidateSessionKey: 'session-c',
          isProUnlocked: false,
        );
        expect(decision, isA<AcpConcurrencyRequiresChoice>());
        final requiresChoice = decision as AcpConcurrencyRequiresChoice;
        expect(requiresChoice.blockingSessionKeys, ['session-a', 'session-b']);
      });

      test('always allows additional sessions for a Pro user', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {'session-a', 'session-b', 'session-c'},
          candidateSessionKey: 'session-d',
          isProUnlocked: true,
        );
        expect(decision, const AcpConcurrencyAllowed());
      });

      test('allows a Pro user to reopen a session that is already live', () {
        final decision = policy.evaluate(
          currentLiveSessionKeys: const {'session-a'},
          candidateSessionKey: 'session-a',
          isProUnlocked: true,
        );
        expect(decision, const AcpConcurrencyAllowed());
      });

      test('AcpConcurrencyRequiresChoice has value equality', () {
        final a = AcpConcurrencyRequiresChoice(
          blockingSessionKeys: const ['session-a'],
        );
        final b = AcpConcurrencyRequiresChoice(
          blockingSessionKeys: const ['session-a'],
        );
        final c = AcpConcurrencyRequiresChoice(
          blockingSessionKeys: const ['session-b'],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a == c, isFalse);
      });

      test(
        'AcpConcurrencyRequiresChoice defensively copies blockingSessionKeys '
        'so later mutation of the source list does not change the decision',
        () {
          final mutableKeys = ['session-a'];
          final decision = AcpConcurrencyRequiresChoice(
            blockingSessionKeys: mutableKeys,
          );

          mutableKeys.add('session-b');

          expect(decision.blockingSessionKeys, ['session-a']);
        },
      );
    });
  });
}
