// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/widgets/acp_session_presentation.dart';

import '../../support/fake_acp_session_manager.dart';

/// Registers tests from acp_session_presentation_test.dart.
void registerPresentationWidgetsAcpSessionPresentationTests() {
  group('acp_session_presentation', () {
    group('acpCwdSummary', () {
      test('renders home as tilde', () {
        expect(acpCwdSummary('~'), '~');
        expect(acpCwdSummary('~/'), '~');
        expect(acpCwdSummary(''), '~');
        expect(acpCwdSummary(null), '~');
      });

      test('shortens nested paths to their final segment', () {
        expect(acpCwdSummary('/home/dev/project'), '…/project');
        expect(acpCwdSummary('/home/dev/project/'), '…/project');
      });

      test('keeps a single absolute segment', () {
        expect(acpCwdSummary('/srv'), '/srv');
      });
    });

    group('acpRelativeTime', () {
      final now = DateTime(2026, 1, 1, 12);

      test('reports just now within a minute', () {
        expect(
          acpRelativeTime(now.subtract(const Duration(seconds: 10)), now: now),
          'just now',
        );
      });

      test('reports minutes, hours, and days', () {
        expect(
          acpRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
          '5m ago',
        );
        expect(
          acpRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
          '3h ago',
        );
        expect(
          acpRelativeTime(now.subtract(const Duration(days: 2)), now: now),
          '2d ago',
        );
      });
    });

    group('acpStatusDisplay', () {
      test('every status has a mono label and an icon (never color alone)', () {
        for (final status in AcpConnectionStatus.values) {
          final display = acpStatusDisplay(status);
          expect(display.label, isNotEmpty);
          expect(display.icon, isA<IconData>());
        }
      });

      test('ready is active-toned and failure is error-toned', () {
        expect(
          acpStatusDisplay(AcpConnectionStatus.ready).tone,
          AcpStatusTone.active,
        );
        expect(
          acpStatusDisplay(AcpConnectionStatus.failed).tone,
          AcpStatusTone.error,
        );
        expect(acpStatusDisplay(AcpConnectionStatus.ready).isReady, isTrue);
        expect(acpStatusDisplay(AcpConnectionStatus.failed).isReady, isFalse);
      });

      test('status colors resolve from the color scheme', () {
        const scheme = ColorScheme.dark();
        expect(acpStatusColor(scheme, AcpStatusTone.active), scheme.primary);
        expect(acpStatusColor(scheme, AcpStatusTone.error), scheme.error);
      });
    });

    group('acpSessionActivityDisplay', () {
      test('streaming without a plan reports indeterminate working state', () {
        final display = acpSessionActivityDisplay(
          fakeAcpSession(promptStatus: AcpPromptStatus.streaming),
        );

        expect(display.label, 'working');
        expect(display.indeterminate, isTrue);
        expect(display.progressFraction, isNull);
      });

      test('streaming plan reports determinate completion', () {
        final display = acpSessionActivityDisplay(
          fakeAcpSession(
            promptStatus: AcpPromptStatus.streaming,
            plan: const [
              AcpPlanEntry(
                content: 'done',
                priority: AcpPlanPriority.high,
                status: AcpPlanStatus.completed,
              ),
              AcpPlanEntry(
                content: 'next',
                priority: AcpPlanPriority.medium,
                status: AcpPlanStatus.inProgress,
              ),
            ],
          ),
        );

        expect(display.label, 'working');
        expect(display.indeterminate, isFalse);
        expect(display.progressFraction, 0.5);
      });

      test('pending user decision takes priority over working state', () {
        final display = acpSessionActivityDisplay(
          fakeAcpSession(
            promptStatus: AcpPromptStatus.streaming,
            pendingWrites: [
              AcpPendingWrite(
                requestKey: 'write-1',
                sessionId: 'session-1',
                path: '/repo/file.dart',
                contentByteLength: 12,
                requestedAt: DateTime(2026),
              ),
            ],
          ),
        );

        expect(display.label, 'waiting for input');
        expect(display.needsInput, isTrue);
        expect(display.indeterminate, isFalse);
      });

      test('sending and cancelling expose distinct active states', () {
        expect(
          acpSessionActivityDisplay(
            fakeAcpSession(promptStatus: AcpPromptStatus.sending),
          ).label,
          'sending',
        );
        expect(
          acpSessionActivityDisplay(
            fakeAcpSession(promptStatus: AcpPromptStatus.cancelling),
          ).label,
          'cancelling',
        );
      });
    });

    test('activity snapshots ignore transcript-only changes', () {
      final first = fakeAcpSession(
        timeline: fakeAcpTimeline('first transcript'),
        promptStatus: AcpPromptStatus.streaming,
      );
      final second = fakeAcpSession(
        timeline: fakeAcpTimeline('different transcript'),
        promptStatus: AcpPromptStatus.streaming,
      );

      expect(
        AcpActivitySnapshot.fromSession(first),
        AcpActivitySnapshot.fromSession(second),
      );
    });

    group('native mux window parity', () {
      test('idle and active turns use waiting/running vocabulary', () {
        expect(acpSessionMuxStatusDisplay(fakeAcpSession()).label, 'waiting');
        expect(
          acpSessionMuxStatusDisplay(
            fakeAcpSession(promptStatus: AcpPromptStatus.streaming),
          ).label,
          'running',
        );
      });

      test('projects indeterminate and determinate terminal progress', () {
        final indeterminate = acpActivityTerminalProgress(
          acpSessionActivityDisplay(
            fakeAcpSession(promptStatus: AcpPromptStatus.streaming),
          ),
        );
        expect(indeterminate?.percentage, isNull);

        final determinate = acpActivityTerminalProgress(
          acpSessionActivityDisplay(
            fakeAcpSession(
              promptStatus: AcpPromptStatus.streaming,
              plan: const [
                AcpPlanEntry(
                  content: 'done',
                  priority: AcpPlanPriority.high,
                  status: AcpPlanStatus.completed,
                ),
                AcpPlanEntry(
                  content: 'next',
                  priority: AcpPlanPriority.medium,
                  status: AcpPlanStatus.inProgress,
                ),
              ],
            ),
          ),
        );
        expect(determinate?.percentage, 50);
        expect(determinate?.fraction, 0.5);
      });
    });
  });
}
