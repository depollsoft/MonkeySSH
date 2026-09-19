import '../../domain/models/tmux_state.dart';

/// Tracks which tmux alerts were emitted and clears only their notification IDs.
class TmuxAlertTracker {
  final _seenAlertWindowKeys = <String>{};
  final Map<String, int> _alertNotificationIdsByWindowKey = {};

  /// Applies a snapshot, clearing old notifications before emitting new alerts.
  bool applyWindows(
    List<TmuxWindow> windows, {
    required int hostId,
    required int connectionId,
    required String tmuxSessionName,
    required void Function(TmuxWindow, List<TmuxWindow>, int, String?) onAlert,
    required void Function(int) onClear,
  }) {
    final currentAlerts = <String, TmuxWindow>{
      for (final window in windows)
        if (window.hasAlert) _tmuxAlertWindowKey(window): window,
    };
    _seenAlertWindowKeys.retainAll(currentAlerts.keys);
    for (final key in _alertNotificationIdsByWindowKey.keys.toList()) {
      final window = currentAlerts[key];
      if (window == null || window.isActive) {
        _clearAlertNotification(key, onClear);
      }
    }
    var hasNewAlert = false;
    for (final entry in currentAlerts.entries) {
      if (entry.value.isActive || !_seenAlertWindowKeys.add(entry.key)) {
        continue;
      }
      hasNewAlert = true;
      final window = entry.value;
      final windowId = window.id;
      final stableWindowId = windowId != null && isValidTmuxWindowId(windowId)
          ? windowId
          : null;
      final windowIndex = window.index;
      final notificationId = stableWindowId != null
          ? _tmuxAlertNotificationId(
              hostId,
              connectionId,
              tmuxSessionName,
              stableWindowId,
            )
          : _legacyTmuxAlertNotificationId(
              hostId,
              connectionId,
              tmuxSessionName,
              windowIndex,
            );
      _alertNotificationIdsByWindowKey[_tmuxAlertWindowKey(window)] =
          notificationId;
      onAlert(window, windows, notificationId, stableWindowId);
    }
    return hasNewAlert;
  }

  int _tmuxAlertNotificationId(
    int hostId,
    int connectionId,
    String tmuxSessionName,
    String windowKey,
  ) =>
      Object.hash(hostId, connectionId, tmuxSessionName, windowKey) &
      0x7fffffff;

  int _legacyTmuxAlertNotificationId(
    int hostId,
    int connectionId,
    String tmuxSessionName,
    int windowIndex,
  ) =>
      Object.hash(hostId, connectionId, tmuxSessionName, windowIndex) &
      0x7fffffff;

  String _tmuxAlertIndexWindowKey(int windowIndex) => 'index:$windowIndex';

  String _tmuxAlertWindowKey(TmuxWindow window) =>
      window.id != null && isValidTmuxWindowId(window.id!)
      ? window.id!
      : _tmuxAlertIndexWindowKey(window.index);

  void _clearAlertNotification(String windowKey, void Function(int) onClear) {
    final notificationId = _alertNotificationIdsByWindowKey.remove(windowKey);
    if (notificationId != null) onClear(notificationId);
  }

  /// Forgets the old session and clears all notifications that it emitted.
  void clear(void Function(int) onClear) {
    _seenAlertWindowKeys.clear();
    for (final key in _alertNotificationIdsByWindowKey.keys.toList()) {
      _clearAlertNotification(key, onClear);
    }
  }
}
