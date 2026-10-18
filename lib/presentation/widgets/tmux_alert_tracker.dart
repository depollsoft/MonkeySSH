import '../../domain/models/terminal_program_status.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/local_notification_service.dart';

/// Tracks which tmux alerts were emitted and clears only their notification IDs.
class TmuxAlertTracker {
  final _seenAlertWindowKeys = <String>{};
  final Map<String, int> _alertNotificationIdsByWindowKey = {};
  final Set<int> _requestNotificationIds = {};

  /// Applies a snapshot, clearing old notifications before emitting new alerts.
  bool applyWindows(
    List<TmuxWindow> windows, {
    required int hostId,
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
      final windowKey = _tmuxAlertWindowKey(window);
      // The window's one slot, whichever connection to the session sees it.
      final notificationId = buildWindowNotificationId(
        hostId,
        tmuxSessionName,
        windowKey,
        // Beside the request its program waits on, not in the other slot.
        request: window.programStatus?.state == TerminalProgramState.blocked,
      );
      _alertNotificationIdsByWindowKey[windowKey] = notificationId;
      if (window.programStatus?.state == TerminalProgramState.blocked) {
        _requestNotificationIds.add(notificationId);
      }
      onAlert(window, windows, notificationId, stableWindowId);
    }
    return hasNewAlert;
  }

  String _tmuxAlertIndexWindowKey(int windowIndex) => 'index:$windowIndex';

  String _tmuxAlertWindowKey(TmuxWindow window) =>
      window.id != null && isValidTmuxWindowId(window.id!)
      ? window.id!
      : _tmuxAlertIndexWindowKey(window.index);

  void _clearAlertNotification(String windowKey, void Function(int) onClear) {
    final notificationId = _alertNotificationIdsByWindowKey.remove(windowKey);
    if (notificationId == null) return;
    _requestNotificationIds.remove(notificationId);
    onClear(notificationId);
  }

  /// Forgets the old session and clears all notifications that it emitted.
  ///
  /// With [onKeep], a notification in a window's request slot is handed to
  /// it instead: unless the window was viewed, it may be standing in for the
  /// pending request's push it replaced there.
  void clear(void Function(int) onClear, {void Function(int)? onKeep}) {
    _seenAlertWindowKeys.clear();
    for (final key in _alertNotificationIdsByWindowKey.keys.toList()) {
      final id = _alertNotificationIdsByWindowKey[key]!;
      _clearAlertNotification(
        key,
        onKeep != null && _requestNotificationIds.contains(id)
            ? onKeep
            : onClear,
      );
    }
  }
}
