import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';

void main() {
  const connections = <MuxSessionConnection>[
    (
      connectionId: 1,
      hostId: 4,
      muxBackend: RemoteMuxBackend.monkeyMux,
      muxSessionName: 'work',
      hasTerminal: true,
    ),
    (
      connectionId: 2,
      hostId: 4,
      muxBackend: RemoteMuxBackend.monkeyMux,
      muxSessionName: 'play',
      hasTerminal: true,
    ),
    (
      connectionId: 3,
      hostId: 9,
      muxBackend: RemoteMuxBackend.monkeyMux,
      muxSessionName: 'main',
      hasTerminal: true,
    ),
  ];

  test('a named session reuses the connection attached to it', () {
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'play',
        connections: connections,
      ),
      (connectionId: 2, forceNew: false),
    );
  });

  test('a named session never borrows another session\'s connection', () {
    // The host has a live connection, but on "work": reusing it would show
    // the wrong session's terminal, so a new connection attaches to "deploy".
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'deploy',
        connections: connections,
      ),
      (connectionId: null, forceNew: true),
    );
    // A same-named session on another host does not count either.
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'main',
        connections: connections,
      ),
      (connectionId: null, forceNew: true),
    );
  });

  test('a tmux session with the same name is not reused', () {
    // The window id in the route is a MonkeyMux id, which would select the
    // wrong window in tmux.
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'work',
        connections: const [
          (
            connectionId: 5,
            hostId: 4,
            muxBackend: RemoteMuxBackend.tmux,
            muxSessionName: 'work',
            hasTerminal: true,
          ),
        ],
      ),
      (connectionId: null, forceNew: true),
    );
  });

  test('a connection that has no terminal yet is adopted', () {
    // A second tap replaced the terminal that was still connecting: its
    // connection has no terminal and no session, and opening its first
    // terminal attaches it to the named session.
    const orphan = (
      connectionId: 7,
      hostId: 4,
      muxBackend: null,
      muxSessionName: null,
      hasTerminal: false,
    );
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'deploy',
        connections: [...connections, orphan],
      ),
      (connectionId: 7, forceNew: false),
    );
    // An exact match still wins.
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'play',
        connections: [orphan, ...connections],
      ),
      (connectionId: 2, forceNew: false),
    );
    // Another host's connection is never adopted.
    expect(
      resolveMuxSessionConnection(
        hostId: 9,
        sessionName: 'deploy',
        connections: [orphan],
      ),
      (connectionId: null, forceNew: true),
    );
  });

  test('a terminal whose session is not known yet is not reused', () {
    // It may already be attaching to another session.
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'work',
        connections: const [
          (
            connectionId: 7,
            hostId: 4,
            muxBackend: null,
            muxSessionName: null,
            hasTerminal: true,
          ),
        ],
      ),
      (connectionId: null, forceNew: true),
    );
  });

  test('a route without a session keeps the usual host reuse', () {
    for (final name in [null, '', '  ']) {
      expect(
        resolveMuxSessionConnection(
          hostId: 4,
          sessionName: name,
          connections: connections,
        ),
        (connectionId: null, forceNew: false),
      );
    }
  });
}
