// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

/// Registers tests from acp_session_state_test.dart.
void registerDomainModelsAcpSessionStateTests() {
  group('acp_session_state', () {
    AcpSessionState base({
      AcpConnectionStatus status = AcpConnectionStatus.ready,
      bool attached = true,
    }) => AcpSessionState(
      key: AcpSessionKey.of(
        hostId: 1,
        providerId: 'copilot',
        bridgeId: 'b',
        acpSessionId: 's',
      ),
      providerLabel: 'Copilot CLI',
      cwd: '/repo',
      status: status,
      attached: attached,
      createdAt: DateTime.utc(2024),
      lastActivityAt: DateTime.utc(2024),
    );

    group('isLive', () {
      test('ready and attached is live', () {
        expect(base().isLive, isTrue);
      });

      test('detached is not live even when the status is otherwise active', () {
        expect(
          base(
            status: AcpConnectionStatus.reconnecting,
            attached: false,
          ).isLive,
          isFalse,
        );
      });

      test('terminal statuses are never live', () {
        for (final status in [
          AcpConnectionStatus.detached,
          AcpConnectionStatus.bridgeExpired,
          AcpConnectionStatus.providerExited,
          AcpConnectionStatus.failed,
          AcpConnectionStatus.closed,
        ]) {
          expect(base(status: status).isLive, isFalse, reason: status.name);
        }
      });

      test('connecting/initializing/reconnecting are live while attached', () {
        for (final status in [
          AcpConnectionStatus.connecting,
          AcpConnectionStatus.initializing,
          AcpConnectionStatus.authenticationRequired,
          AcpConnectionStatus.reconnecting,
        ]) {
          expect(base(status: status).isLive, isTrue, reason: status.name);
        }
      });
    });

    group('isOpenMuxWindow', () {
      test(
        'keeps locally detached persistent bridges in the mux window list',
        () {
          expect(
            base(
              status: AcpConnectionStatus.detached,
              attached: false,
            ).isOpenMuxWindow,
            isTrue,
          );
        },
      );

      test('excludes terminal bridge and provider states', () {
        for (final status in [
          AcpConnectionStatus.bridgeExpired,
          AcpConnectionStatus.providerExited,
          AcpConnectionStatus.failed,
          AcpConnectionStatus.closed,
        ]) {
          expect(
            base(status: status, attached: false).isOpenMuxWindow,
            isFalse,
            reason: status.name,
          );
        }
      });
    });

    group('copyWith', () {
      test('clears nullable fields explicitly', () {
        final withTitle = base().copyWith(title: 'Hello');
        expect(withTitle.title, 'Hello');
        expect(withTitle.copyWith(clearTitle: true).title, isNull);
      });

      test('preserves identity fields', () {
        final next = base().copyWith(status: AcpConnectionStatus.failed);
        expect(next.key, base().key);
        expect(next.createdAt, base().createdAt);
        expect(next.status, AcpConnectionStatus.failed);
      });

      test('copies session-local permission mode', () {
        final ask = base();
        final yolo = ask.copyWith(autoApprovePermissions: true);

        expect(ask.autoApprovePermissions, isFalse);
        expect(yolo.autoApprovePermissions, isTrue);
        expect(yolo, isNot(ask));
      });

      test('distinguishes retryable transport failures', () {
        const terminal = AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'Connection failed.',
        );
        const transient = AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'Connection failed.',
          retryable: true,
        );

        expect(terminal.retryable, isFalse);
        expect(transient.retryable, isTrue);
        expect(transient, isNot(terminal));
      });

      test('tracks warning independently of error', () {
        const warning = AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'History was truncated.',
        );
        const error = AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'Connection failed.',
        );
        final state = base().copyWith(warning: warning, error: error);
        expect(state.warning, warning);
        expect(state.error, error);
        // Clearing the error leaves the warning intact.
        final cleared = state.copyWith(clearError: true);
        expect(cleared.error, isNull);
        expect(cleared.warning, warning);
        // And vice versa.
        expect(state.copyWith(clearWarning: true).warning, isNull);
        expect(state.copyWith(clearWarning: true).error, error);
      });
    });

    group('key rebuild', () {
      AcpPendingPermission permission(String requestKey, String toolCallId) =>
          AcpPendingPermission(
            requestKey: requestKey,
            sessionId: 's',
            toolCallId: toolCallId,
            options: const [],
            requestedAt: DateTime.utc(2024),
          );

      test('preserves pending state and its ordering under a new key', () {
        // A brand-new session is created under a provisional key and rebuilt once
        // its real remote id is known. That rebuild must carry over every field.
        final provisional = base(status: AcpConnectionStatus.initializing)
            .copyWith(
              availableCommands: const [
                AcpAvailableCommand(name: 'review', description: 'Review'),
              ],
              pendingPermissions: [
                permission('r1', 't1'),
                permission('r2', 't2'),
                permission('r3', 't3'),
              ],
              promptStatus: AcpPromptStatus.streaming,
              warning: const AcpSessionError(
                kind: AcpSessionErrorKind.replayOverflow,
                message: 'History truncated.',
              ),
            );

        final rebuilt = provisional.copyWith(
          key: AcpSessionKey.of(
            hostId: 1,
            providerId: 'copilot',
            bridgeId: 'b',
            acpSessionId: 'resolved-session',
          ),
          status: AcpConnectionStatus.ready,
        );

        expect(rebuilt.key.acpSessionId, 'resolved-session');
        expect(rebuilt.status, AcpConnectionStatus.ready);
        // Pending permissions survive the rebuild with order intact.
        expect(rebuilt.pendingPermissions.map((p) => p.requestKey), [
          'r1',
          'r2',
          'r3',
        ]);
        expect(rebuilt.availableCommands, provisional.availableCommands);
        expect(rebuilt.promptStatus, AcpPromptStatus.streaming);
        // The non-fatal warning also survives the identity rebuild.
        expect(rebuilt.warning?.kind, AcpSessionErrorKind.replayOverflow);
      });

      test('key defaults to the current key when omitted', () {
        final state = base();
        expect(
          state.copyWith(status: AcpConnectionStatus.detached).key,
          state.key,
        );
      });
    });

    group('defensive lists', () {
      test('copies the caller list and exposes an unmodifiable view', () {
        final commands = <AcpAvailableCommand>[
          const AcpAvailableCommand(name: 'review', description: 'Review'),
        ];
        final state = base().copyWith(availableCommands: commands);
        // Mutating the caller list must not affect the constructed state.
        commands.clear();
        expect(state.availableCommands, hasLength(1));
        // The exposed list itself is unmodifiable.
        expect(
          () => state.availableCommands.add(
            const AcpAvailableCommand(name: 'x', description: 'y'),
          ),
          throwsUnsupportedError,
        );
      });

      test('defends the pending permissions list', () {
        final pending = <AcpPendingPermission>[
          AcpPendingPermission(
            requestKey: 'r1',
            sessionId: 's',
            toolCallId: 't',
            options: const [],
            requestedAt: DateTime.utc(2024),
          ),
        ];
        final state = base().copyWith(pendingPermissions: pending);
        pending.clear();
        expect(state.pendingPermissions, hasLength(1));
        expect(state.pendingPermissions.clear, throwsUnsupportedError);
      });
    });
  });
}
