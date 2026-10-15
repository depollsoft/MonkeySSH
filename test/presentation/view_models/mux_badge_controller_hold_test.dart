// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/mux_session_end_holds.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/view_models/mux_badge_controller.dart';

class _MockSshClient extends Mock implements SSHClient {}

void main() {
  late List<int> disconnected;
  late MuxSessionEndHolds holds;
  late MuxBadgeController controller;
  late SshSession session;

  setUp(() {
    disconnected = <int>[];
    holds = MuxSessionEndHolds();
    controller = MuxBadgeController(
      getSession: () => null,
      resolveBackend: (_) => RemoteMuxBackend.monkeyMux,
      resolveSessionName: (_, _) async => null,
      serviceForBackend: (_) => throw UnimplementedError(),
      extraFlags: () => null,
      onWindowsChanged: (_) {},
      disconnect: (session) async => disconnected.add(session.connectionId),
      sessionEndHolds: holds,
    );
    session = SshSession(
      connectionId: 7,
      hostId: 1,
      client: _MockSshClient(),
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'dev',
      ),
    );
  });

  tearDown(() {
    controller.dispose();
  });

  test('an ended session waits for a held window close to finish', () async {
    final release = controller.holdSessionEnd(7);

    final ending = controller.disconnectEndedMonkeyMuxSession(session);
    await pumpEventQueue();
    expect(disconnected, isEmpty);

    release();
    release();
    await ending;
    expect(disconnected, [7]);
  });

  test(
    'waits for a close held elsewhere, such as the terminal above it',
    () async {
      // The terminal shares the holds; its last-window close must keep the
      // home badge beneath it from disconnecting.
      final release = holds.hold(7);

      final ending = controller.disconnectEndedMonkeyMuxSession(session);
      await pumpEventQueue();
      expect(disconnected, isEmpty);

      release();
      await ending;
      expect(disconnected, [7]);
    },
  );

  test('waits for every overlapping close, not only the newest', () async {
    final releaseFirst = controller.holdSessionEnd(7);
    final releaseSecond = controller.holdSessionEnd(7);

    final ending = controller.disconnectEndedMonkeyMuxSession(session);
    releaseSecond();
    await pumpEventQueue();
    expect(disconnected, isEmpty);

    releaseFirst();
    await ending;
    expect(disconnected, [7]);
  });

  test('a hold on another connection does not delay this one', () async {
    holds.hold(8);

    await controller.disconnectEndedMonkeyMuxSession(session);

    expect(disconnected, [7]);
    expect(holds.isHeld(8), isTrue);
  });

  test('disconnects at once when nothing holds the session', () async {
    await controller.disconnectEndedMonkeyMuxSession(session);

    expect(disconnected, [7]);
  });
}
