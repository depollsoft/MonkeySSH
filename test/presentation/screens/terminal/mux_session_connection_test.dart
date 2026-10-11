import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';

void main() {
  const connections = <MuxSessionConnection>[
    (connectionId: 1, hostId: 4, muxSessionName: 'work'),
    (connectionId: 2, hostId: 4, muxSessionName: 'play'),
    (connectionId: 3, hostId: 9, muxSessionName: 'main'),
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

  test('a connection whose session is not known yet is not reused', () {
    expect(
      resolveMuxSessionConnection(
        hostId: 4,
        sessionName: 'work',
        connections: const [(connectionId: 7, hostId: 4, muxSessionName: null)],
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
