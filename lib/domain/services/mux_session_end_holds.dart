/// Holds a MonkeyMux session's end-of-session disconnect while a window
/// close still needs the connection.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the disconnect that follows a MonkeyMux session's end, per SSH
/// connection.
///
/// MonkeyMux announces the empty window list before it answers the close of
/// the last window, and every screen watching the session disconnects when it
/// sees that list: the terminal's window bar, and the home Connections badge,
/// which stays mounted under a terminal opened from it. A close that still
/// has work to do on the connection, such as offering to remove the window's
/// worktree, takes a hold here, and every one of those observers waits for
/// all holds on the connection before it disconnects.
class MuxSessionEndHolds {
  final _holds = <int, Set<Completer<void>>>{};

  /// Holds [connectionId]'s session-end disconnect until the returned
  /// callback runs. The callback may run more than once.
  void Function() hold(int connectionId) {
    final hold = Completer<void>();
    (_holds[connectionId] ??= <Completer<void>>{}).add(hold);
    return () {
      if (hold.isCompleted) return;
      final holds = _holds[connectionId];
      if (holds != null) {
        holds.remove(hold);
        if (holds.isEmpty) _holds.remove(connectionId);
      }
      hold.complete();
    };
  }

  /// Whether anything holds [connectionId]'s session-end disconnect.
  bool isHeld(int connectionId) => _holds[connectionId]?.isNotEmpty ?? false;

  /// Completes once nothing holds [connectionId]'s session-end disconnect,
  /// including holds taken while it waits.
  Future<void> released(int connectionId) async {
    while (true) {
      final holds = _holds[connectionId];
      if (holds == null || holds.isEmpty) return;
      await Future.wait([for (final hold in holds) hold.future]);
    }
  }
}

/// Provider for the app's [MuxSessionEndHolds].
final muxSessionEndHoldsProvider = Provider<MuxSessionEndHolds>(
  (ref) => MuxSessionEndHolds(),
);
