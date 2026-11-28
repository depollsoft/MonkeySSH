// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_writer_lease.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../helpers/acp_test_fakes.dart';

/// In-memory agent standing in for the provider behind one bridge attachment.
class _Agent extends FakeAcpTransport {
  _Agent({this.onFirstRequest})
    : super(
        throwWhenClosed: true,
        onRequest: (transport, id, method, _) async {
          final agent = transport as _Agent;
          if (method == 'session/prompt' && agent.stallPromptWrites) {
            await agent.closedSignal.future;
            throw const AcpTransportClosedException();
          }
          if (!agent._sawRequest) {
            agent._sawRequest = true;
            agent.onFirstRequest?.call(agent);
            if (agent.closed) return true;
          }
          if (method == 'session/prompt') {
            agent.heldPromptIds.add(id);
            return true;
          }
          return false;
        },
      );

  /// Runs when the first request is written, standing in for the bridge's
  /// reply to the attach hello.
  final void Function(_Agent agent)? onFirstRequest;
  final heldPromptIds = <Object>[];
  var _sawRequest = false;

  /// When set, a prompt's write waits until the agent closes and then fails
  /// as a closed transport, so the prompt never leaves this device.
  bool stallPromptWrites = false;
}

/// Connector whose attaches can find the input lease held by another device.
class _Connector extends FakeAcpBridgeConnector {
  _Connector() : super(syncTransportStates: true);

  final agents = <_Agent>[];

  /// When set, an attach that does not take over finds this writer.
  MonkeyMuxAcpRemoteWriter? heldBy;

  /// When set, even a take-over attach finds this writer, as when another
  /// device took the chat back in the meantime.
  MonkeyMuxAcpRemoteWriter? heldDespiteTakeOver;

  /// When set, the next attach drops before answering anything.
  bool failNextAttach = false;

  /// What each attach reports about prompts once the input moved.
  final promptDeliveries = <String, AcpInputDelivery>{};

  List<StreamController<MonkeyMuxAcpTransportState>> get states =>
      stateControllers;

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async => [_metadata('bridge-1')];

  MonkeyMuxAcpBridgeMetadata _metadata(String bridgeId) {
    final writer = heldBy;
    return fakeAcpBridgeMetadata(
      bridgeId,
      clientCount: 1,
      nextSequence: 4,
      writer: writer == null
          ? null
          : MonkeyMuxAcpLeaseHolder(
              label: writer.label,
              lastActiveAt: writer.lastActiveAt,
              stale: false,
            ),
    );
  }

  @override
  MonkeyMuxAcpBridgeMetadata Function(String bridgeId) get metadataBuilder =>
      _metadata;

  @override
  AcpInputDelivery Function(String sessionId) get promptDelivery =>
      (sessionId) => promptDeliveries[sessionId] ?? AcpInputDelivery.notSent;

  @override
  FakeAcpTransport Function(
    int hostId,
    String bridgeId,
    StreamController<MonkeyMuxAcpTransportState> states, {
    required bool takeOver,
  })
  get transportFactory => (_, bridgeId, stateController, {required takeOver}) {
    final writer = takeOver ? heldDespiteTakeOver : heldBy;
    final fail = failNextAttach;
    failNextAttach = false;
    final agent = _Agent(
      onFirstRequest: fail
          ? (agent) => unawaited(agent.close())
          : writer == null
          ? null
          : (agent) {
              // Like the real transport: report the writer, then end the
              // stream so the pending request fails at once.
              stateController.add(
                MonkeyMuxAcpTransportState(
                  status: MonkeyMuxAcpTransportStatus.heldElsewhere,
                  bridgeId: bridgeId,
                  lastDeliveredSequence: 0,
                  writer: writer,
                ),
              );
              unawaited(agent.close());
            },
    );
    agents.add(agent);
    return agent;
  };
}

Future<void> _pump() => pumpAcpEventLoop();

List<String> _timelineTexts(AcpSessionState state) => [
  for (final entry in state.timeline.entries)
    if (entry is AcpMessageEntry)
      for (final block in entry.content)
        if (block is AcpTextContent) block.text,
];

/// Registers tests from acp_session_manager_writer_lease_test.dart.
void registerDomainServicesAcpSessionManagerWriterLeaseTests() {
  group('acp_session_manager_writer_lease', () {
    late AppDatabase database;
    late _Connector connector;
    late AcpSessionManager manager;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      connector = _Connector();
      manager = AcpSessionManager(
        connector: connector,
        recentSessions: AcpRecentSessionsService(SettingsService(database)),
        isProUnlocked: () => true,
        diagnostics: const NoopDiagnosticsLogger(),
      );
    });

    tearDown(() async {
      await manager.dispose();
      await database.close();
    });

    final ipad = MonkeyMuxAcpRemoteWriter(
      label: 'iPad',
      lastActiveAt: DateTime(2026, 10, 9, 12),
      leaseLost: false,
    );

    Future<AcpSessionLaunchResult> open({bool takeOver = false}) =>
        manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: 'bridge-1',
          acpSessionId: 'session-1',
          cwd: '/repo',
          takeOver: takeOver,
        );

    AcpSessionState stateOf(AcpSessionKey key) =>
        manager.state.byKeyValue(key.value)!;

    test('opening a chat another device holds shows it read-only', () async {
      connector.heldBy = ipad;

      final result = await open();

      expect(result, isA<AcpSessionLaunchStarted>());
      final key = (result as AcpSessionLaunchStarted).key;
      final state = stateOf(key);
      expect(state.remoteWriter, ipad);
      expect(state.status, AcpConnectionStatus.detached);
      expect(state.isLive, isFalse);
      expect(manager.state.selectedKey, key.value);
      // Nothing past the first request was sent from the read-only attach.
      expect(connector.agents.single.methods, ['initialize']);
    });

    test('take over opens a writer attach and loads the history', () async {
      connector.heldBy = ipad;
      final held = (await open()) as AcpSessionLaunchStarted;

      final result = await open(takeOver: true);

      expect(result, isA<AcpSessionLaunchStarted>());
      final state = stateOf((result as AcpSessionLaunchStarted).key);
      expect(state.remoteWriter, isNull);
      expect(state.status, AcpConnectionStatus.ready);
      expect(state.key, held.key);
      expect(connector.takeOvers, [false, true]);
      expect(connector.agents.last.methods, contains('session/load'));
    });

    test(
      're-opening a held chat without take over refreshes the writer',
      () async {
        connector.heldBy = ipad;
        await open();
        final later = MonkeyMuxAcpRemoteWriter(
          label: 'iPad',
          lastActiveAt: DateTime(2026, 10, 9, 13),
          leaseLost: false,
        );
        connector.heldBy = later;

        final result = (await open()) as AcpSessionLaunchStarted;

        expect(stateOf(result.key).remoteWriter, later);
        // The frozen view stays; only who holds it is refreshed.
        expect(connector.takeOvers, [false]);
      },
    );

    test(
      'reopening a sibling chat reuses the input this device took',
      () async {
        connector.heldBy = ipad;
        Future<AcpSessionLaunchResult> openSession(
          String sessionId, {
          bool takeOver = false,
        }) => manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: 'bridge-1',
          acpSessionId: sessionId,
          cwd: '/repo',
          takeOver: takeOver,
        );
        final first =
            (await openSession('session-1')) as AcpSessionLaunchStarted;
        final sibling =
            (await openSession('session-2')) as AcpSessionLaunchStarted;
        expect(stateOf(sibling.key).remoteWriter, isNotNull);

        await openSession('session-1', takeOver: true);
        expect(stateOf(first.key).status, AcpConnectionStatus.ready);
        // The bridge now names this device as the holder.
        connector.heldBy = MonkeyMuxAcpRemoteWriter(
          label: 'iPhone',
          lastActiveAt: DateTime(2026, 10, 9, 12),
          leaseLost: false,
        );
        final attaches = connector.agents.length;

        await openSession('session-2');

        final state = stateOf(sibling.key);
        expect(state.remoteWriter, isNull);
        expect(state.status, AcpConnectionStatus.ready);
        // It shares the attachment that holds the lease instead of taking it
        // from itself.
        expect(connector.agents, hasLength(attaches));
      },
    );

    /// Starts a chat, sends one prompt the agent receives, then loses the
    /// input to an iPhone.
    Future<AcpSessionKey> loseLeaseAfterOnePrompt() async {
      final started = (await manager.startNewSession(
        hostId: 1,
        providerId: AcpBuiltinProviderIds.copilotCli,
        cwd: '/repo',
      )) as AcpSessionLaunchStarted;
      final key = started.key;
      connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.delivered;
      final sent = manager.prompt(key, const [AcpTextContent('kept')]);
      unawaited(sent.then<void>((_) {}, onError: (Object _) {}));
      await _pump();
      connector.states.single.add(
        MonkeyMuxAcpTransportState(
          status: MonkeyMuxAcpTransportStatus.heldElsewhere,
          bridgeId: key.bridgeId,
          lastDeliveredSequence: 0,
          writer: MonkeyMuxAcpRemoteWriter(
            label: 'iPhone',
            lastActiveAt: DateTime(2026, 10, 9, 12),
            leaseLost: true,
          ),
        ),
      );
      await _pump();
      return key;
    }

    Future<AcpSessionLaunchResult> takeBack(AcpSessionKey key) =>
        manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
          takeOver: true,
        );

    test(
      'a send that finishes after the lease moved is refused at once',
      () async {
        final key = await loseLeaseAfterOnePrompt();

        // An attachment upload finished after the lease frame; the composer
        // still hands over the prompt.
        await expectLater(
          manager.prompt(key, const [AcpTextContent('late')]),
          throwsA(
            isA<AcpInputHeldElsewhereException>().having(
              (error) => error.delivery,
              'delivery',
              AcpInputDelivery.notSent,
            ),
          ),
        );
        expect(_timelineTexts(stateOf(key)), ['kept']);
      },
    );

    test('a take over that fails keeps the read-only transcript', () async {
      final key = await loseLeaseAfterOnePrompt();
      connector.failNextAttach = true;

      final result = await takeBack(key);

      expect(result, isA<AcpSessionLaunchFailed>());
      final state = stateOf(key);
      expect(_timelineTexts(state), ['kept']);
      expect(state.remoteWriter!.label, 'iPhone');
      expect(state.remoteWriter!.leaseLost, isTrue);
      expect(manager.state.selectedKey, key.value);
    });

    test(
      'a take over that finds the chat taken again keeps the transcript',
      () async {
        final key = await loseLeaseAfterOnePrompt();
        connector.heldDespiteTakeOver = MonkeyMuxAcpRemoteWriter(
          label: 'iPad',
          lastActiveAt: DateTime(2026, 10, 9, 12, 30),
          leaseLost: false,
        );

        final result = await takeBack(key);

        expect(result, isA<AcpSessionLaunchStarted>());
        final state = stateOf(key);
        expect(_timelineTexts(state), ['kept']);
        expect(state.remoteWriter!.label, 'iPad');
        expect(state.remoteWriter!.lastActiveAt, DateTime(2026, 10, 9, 12, 30));
        expect(state.remoteWriter!.leaseLost, isTrue);
      },
    );

    test(
      'a device that lost the chat keeps its transcript on return',
      () async {
        final started = (await manager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        )) as AcpSessionLaunchStarted;
        final key = started.key;
        connector.promptDeliveries[key.acpSessionId] =
            AcpInputDelivery.delivered;
        final sent = manager.prompt(key, const [AcpTextContent('kept')]);
        unawaited(sent.then<void>((_) {}, onError: (Object _) {}));
        await _pump();
        final iphone = MonkeyMuxAcpRemoteWriter(
          label: 'iPhone',
          lastActiveAt: DateTime(2026, 10, 9, 12),
          leaseLost: true,
        );
        connector.states.single.add(
          MonkeyMuxAcpTransportState(
            status: MonkeyMuxAcpTransportStatus.heldElsewhere,
            bridgeId: key.bridgeId,
            lastDeliveredSequence: 0,
            writer: iphone,
          ),
        );
        await _pump();
        connector.heldBy = MonkeyMuxAcpRemoteWriter(
          label: 'iPhone',
          lastActiveAt: DateTime(2026, 10, 9, 12, 30),
          leaseLost: false,
        );

        final result = await manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(result, isA<AcpSessionLaunchStarted>());
        final state = stateOf(key);
        expect(_timelineTexts(state), ['kept']);
        expect(state.remoteWriter!.leaseLost, isTrue);
        expect(state.remoteWriter!.lastActiveAt, DateTime(2026, 10, 9, 12, 30));
        expect(connector.agents, hasLength(1));

        connector.heldBy = MonkeyMuxAcpRemoteWriter(
          label: 'iPhone',
          lastActiveAt: DateTime(2026, 10, 9, 12, 45),
          leaseLost: false,
        );
        await manager.refreshHeldSession(key);
        expect(
          stateOf(key).remoteWriter!.lastActiveAt,
          DateTime(2026, 10, 9, 12, 45),
        );
        expect(connector.statusCount, 1);
      },
    );

    test(
      'reopening a detached chat another device took stays read-only',
      () async {
        final started = (await manager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        )) as AcpSessionLaunchStarted;
        final key = started.key;
        await manager.detachSession(key);
        connector.heldBy = ipad;

        final reopened = await manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
        );

        expect(reopened, isA<AcpSessionLaunchStarted>());
        final held = stateOf(key);
        expect(held.remoteWriter, ipad);
        expect(held.status, AcpConnectionStatus.detached);
        expect(held.error, isNull);

        final back = await manager.reconnectSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          cwd: '/repo',
          takeOver: true,
        );
        expect(back, isA<AcpSessionLaunchStarted>());
        expect(stateOf(key).status, AcpConnectionStatus.ready);
        expect(connector.takeOvers, [false, false, true]);
      },
    );

    test(
      'a prompt the bridge dropped leaves the transcript and returns',
      () async {
        final started = (await manager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        )) as AcpSessionLaunchStarted;
        final key = started.key;
        // Sent during the takeover round trip: the bridge already dropped it.
        connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.notSent;
        final sent = manager.prompt(key, const [AcpTextContent('late')]);
        final sentError = expectLater(
          sent,
          throwsA(
            isA<AcpInputHeldElsewhereException>().having(
              (error) => error.delivery,
              'delivery',
              AcpInputDelivery.notSent,
            ),
          ),
        );
        await _pump();
        expect(_timelineTexts(stateOf(key)), ['late']);

        connector.states.single.add(
          MonkeyMuxAcpTransportState(
            status: MonkeyMuxAcpTransportStatus.heldElsewhere,
            bridgeId: key.bridgeId,
            lastDeliveredSequence: 0,
            writer: ipad,
          ),
        );
        await sentError;
        await _pump();

        expect(_timelineTexts(stateOf(key)), isEmpty);
      },
    );

    test(
      'a prompt whose write never started when the lease moved returns unsent',
      () async {
        final started = (await manager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        )) as AcpSessionLaunchStarted;
        final key = started.key;
        connector.agents.single.stallPromptWrites = true;
        // The transport cannot vouch for a prompt it was never handed.
        connector.promptDeliveries[key.acpSessionId] = AcpInputDelivery.unknown;
        final sent = manager.prompt(key, const [AcpTextContent('stalled')]);
        final sentError = expectLater(
          sent,
          throwsA(
            isA<AcpInputHeldElsewhereException>().having(
              (error) => error.delivery,
              'delivery',
              AcpInputDelivery.notSent,
            ),
          ),
        );
        await _pump();

        connector.states.single.add(
          MonkeyMuxAcpTransportState(
            status: MonkeyMuxAcpTransportStatus.heldElsewhere,
            bridgeId: key.bridgeId,
            lastDeliveredSequence: 0,
            writer: ipad,
          ),
        );
        await sentError;
        await _pump();

        final state = stateOf(key);
        expect(state.remoteWriter, ipad);
        // Losing the input is not a failure of this read-only view.
        expect(state.error, isNull);
        expect(_timelineTexts(state), isEmpty);
      },
    );

    test(
      'losing the lease makes the chat read-only and returns unsent prompts',
      () async {
        final started = (await manager.startNewSession(
          hostId: 1,
          providerId: AcpBuiltinProviderIds.copilotCli,
          cwd: '/repo',
        )) as AcpSessionLaunchStarted;
        final key = started.key;
        final agent = connector.agents.single;
        connector.promptDeliveries[key.acpSessionId] =
            AcpInputDelivery.delivered;
        final delivered = manager.prompt(key, const [AcpTextContent('first')]);
        final queued = manager.prompt(key, const [AcpTextContent('second')]);
        final deliveredError = expectLater(
          delivered,
          throwsA(
            isA<AcpInputHeldElsewhereException>().having(
              (error) => error.delivered,
              'delivered',
              isTrue,
            ),
          ),
        );
        final queuedError = expectLater(
          queued,
          throwsA(
            isA<AcpInputHeldElsewhereException>().having(
              (error) => error.delivered,
              'delivered',
              isFalse,
            ),
          ),
        );
        await _pump();
        expect(agent.heldPromptIds, hasLength(1));
        agent.requestPermission(
          key.acpSessionId,
          id: 'permission-1',
          toolCallId: 'tool-1',
        );
        await _pump();
        expect(stateOf(key).pendingPermissions, hasLength(1));
        final methodsBefore = List<String>.of(agent.methods);

        final iphone = MonkeyMuxAcpRemoteWriter(
          label: 'iPhone',
          lastActiveAt: DateTime(2026, 10, 9, 12),
          leaseLost: true,
        );
        connector.states.single.add(
          MonkeyMuxAcpTransportState(
            status: MonkeyMuxAcpTransportStatus.heldElsewhere,
            bridgeId: key.bridgeId,
            lastDeliveredSequence: 3,
            writer: iphone,
          ),
        );
        await deliveredError;
        await queuedError;
        await _pump();

        final state = stateOf(key);
        expect(state.remoteWriter, iphone);
        expect(state.isLive, isFalse);
        expect(state.promptStatus, AcpPromptStatus.idle);
        // The decision now belongs to the device that took the chat.
        expect(state.pendingPermissions, isEmpty);
        // The delivered prompt stays in the transcript; the unsent one is gone.
        expect(_timelineTexts(state), ['first']);
        // Nothing more, and in particular no permission answer, was sent.
        expect(agent.methods, methodsBefore);
        expect(agent.closed, isTrue);

        connector.heldBy = null;
        final back = await open(takeOver: true);
        expect(back, isA<AcpSessionLaunchStarted>());
        final resumed = stateOf((back as AcpSessionLaunchStarted).key);
        expect(resumed.status, AcpConnectionStatus.ready);
        expect(resumed.remoteWriter, isNull);
        expect(connector.takeOvers.last, isTrue);
      },
    );
  });
}
