import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_notification_target.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

void main() {
  final target = AcpSessionKey.of(
    hostId: 7,
    providerId: 'builtin:pi',
    bridgeId: 'bridge-1',
    acpSessionId: 'session-1',
  );
  SshSession connection(int id, {int hostId = 7}) =>
      SshSession(
          client: _MockSshClient(),
          connectionId: id,
          hostId: hostId,
          config: const SshConnectionConfig(
            hostname: 'example.com',
            port: 22,
            username: 'test',
          ),
        )
        ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
        ..remoteMuxSessionName = 'workspace-$id';
  final window = TmuxWindow(
    index: 2,
    id: '@3',
    name: 'Pi',
    isActive: false,
    nativeAcpBridgeId: target.bridgeId,
    nativeAcpProviderId: target.providerId,
  );

  test('finds owning connection after focus moved to another window', () async {
    final queried = <int>[];
    final result = await resolveAcpNotificationConnection(
      target: target,
      sessions: [connection(1, hostId: 8), connection(2), connection(3)],
      listWindows: (session, workspace) async {
        queried.add(session.connectionId);
        expect(workspace, 'workspace-${session.connectionId}');
        return session.connectionId == 3 ? [window] : [];
      },
    );
    expect(result, 3);
    expect(queried, [2, 3]);
  });

  test(
    'prefers the focused connection when several share the workspace',
    () async {
      final result = await resolveAcpNotificationConnection(
        target: target,
        sessions: [
          connection(1),
          connection(2)..activeNativeAcpSessionKey = target,
        ],
        listWindows: (_, _) async => [window],
      );
      expect(result, 2);
    },
  );

  test('window membership takes precedence over stale saved focus', () async {
    final result = await resolveAcpNotificationConnection(
      target: target,
      sessions: [
        connection(1)..activeNativeAcpSessionKey = target,
        connection(2),
      ],
      listWindows: (session, _) async =>
          session.connectionId == 2 ? [window] : [],
    );
    expect(result, 2);
  });

  test('continues looking when another connection lookup fails', () async {
    final result = await resolveAcpNotificationConnection(
      target: target,
      sessions: [connection(1), connection(2)],
      listWindows: (session, _) async {
        if (session.connectionId == 1) throw StateError('Disconnected');
        return [window];
      },
    );
    expect(result, 2);
  });

  test('falls back to exact saved focus when window lookup fails', () async {
    final result = await resolveAcpNotificationConnection(
      target: target,
      sessions: [
        connection(1),
        connection(2)..activeNativeAcpSessionKey = target,
      ],
      listWindows: (_, _) async => throw StateError('Disconnected'),
    );
    expect(result, 2);
  });

  test('no open connections leaves the terminal free to reconnect', () async {
    expect(
      await resolveAcpNotificationConnection(
        target: target,
        sessions: [],
        listWindows: (_, _) async => fail('No open connection'),
      ),
      isNull,
    );
  });

  test('does not select a window belonging to a different provider', () async {
    expect(
      await resolveAcpNotificationConnection(
        target: target,
        sessions: [connection(1)],
        listWindows: (_, _) async => [
          TmuxWindow(
            index: 2,
            name: 'Other',
            isActive: true,
            nativeAcpBridgeId: target.bridgeId,
            nativeAcpProviderId: 'builtin:copilot-cli',
          ),
        ],
      ),
      isNull,
    );
  });
}
