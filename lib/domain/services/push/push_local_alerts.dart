/// Connections whose terminal screen has its window bar mounted.
///
/// The window bar is what raises local notifications for bells and desktop
/// notifications in other windows, so only these connections can tell their
/// host that the backgrounded app covers window alerts itself.
class PushLocalAlertListeners {
  final _counts = <int, int>{};

  /// Records a mounted window bar for [connectionId].
  void add(int connectionId) =>
      _counts[connectionId] = (_counts[connectionId] ?? 0) + 1;

  /// Records that a window bar for [connectionId] was disposed.
  void remove(int connectionId) {
    final count = (_counts[connectionId] ?? 0) - 1;
    if (count <= 0) {
      _counts.remove(connectionId);
    } else {
      _counts[connectionId] = count;
    }
  }

  /// Whether a window bar is mounted for [connectionId].
  bool contains(int connectionId) => _counts.containsKey(connectionId);
}

/// The app-wide registry the window bar reports to.
final pushLocalAlertListeners = PushLocalAlertListeners();

/// Connections whose host keeps terminal programs' status pushes (approvals,
/// questions, finished turns) back because this backgrounded app said it
/// raises them itself and the host acknowledged the claim.
///
/// The window bar raises them only for these connections: anywhere else the
/// host pushes them, and raising them too would show each one twice.
class PushLocalStatusCoverage {
  final _covered = <int>{};

  /// Records whether the host of [connectionId] honors the claim.
  void set(int connectionId, {required bool covered}) {
    if (covered) {
      _covered.add(connectionId);
    } else {
      _covered.remove(connectionId);
    }
  }

  /// Whether the window bar of [connectionId] raises program status itself.
  bool covers(int connectionId) => _covered.contains(connectionId);

  /// Forgets every connection.
  void clear() => _covered.clear();
}

/// The app-wide registry the push service writes and the window bar reads.
final pushLocalStatusCoverage = PushLocalStatusCoverage();
