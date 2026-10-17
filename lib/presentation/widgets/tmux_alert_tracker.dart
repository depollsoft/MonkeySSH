import '../../domain/models/terminal_program_status.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/local_notification_service.dart';

/// Tracks which tmux alerts were emitted and clears only their notification IDs.
class TmuxAlertTracker {
  final _seenAlertWindowKeys = <String>{};
  final Map<String, int> _alertNotificationIdsByWindowKey = {};

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
      );
      _alertNotificationIdsByWindowKey[windowKey] = notificationId;
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

/// A terminal program's status change that calls for a notification.
enum TmuxProgramStatusEvent {
  /// It newly waits for approval.
  permission,

  /// It newly waits for an answer (a question, or signing in).
  input,

  /// It stopped working: its turn finished.
  finished,
}

/// The notification a program's status change from [before] to [after] calls
/// for, or null. The same rules decide MonkeyMux's pushes
/// (`programStatusPushKind`), so a local notification stands in for exactly
/// the push it keeps back.
TmuxProgramStatusEvent? tmuxProgramStatusEvent(
  TerminalProgramStatus? before,
  TerminalProgramStatus? after,
) {
  if (after == null) return null;
  if (after.state == TerminalProgramState.blocked) {
    if (before?.state == TerminalProgramState.blocked &&
        before?.kind == after.kind) {
      return null;
    }
    return after.kind == TerminalProgramBlockedKind.permission
        ? TmuxProgramStatusEvent.permission
        : TmuxProgramStatusEvent.input;
  }
  if (before?.state == TerminalProgramState.working &&
      (after.state == TerminalProgramState.done ||
          after.state == TerminalProgramState.idle)) {
    return TmuxProgramStatusEvent.finished;
  }
  return null;
}

/// Follows each window's reported program status and yields the changes that
/// call for a notification. A window seen for the first time only sets its
/// baseline, so connecting never replays a status from before.
class TmuxProgramStatusTracker {
  final _statusByWindowKey = <String, TerminalProgramStatus?>{};

  /// Applies a snapshot and returns its windows' status events, in order.
  List<({TmuxWindow window, TmuxProgramStatusEvent event})> applyWindows(
    List<TmuxWindow> windows,
  ) {
    final events = <({TmuxWindow window, TmuxProgramStatusEvent event})>[];
    final keys = <String>{};
    for (final window in windows) {
      final key = tmuxWindowNotificationKey(window);
      keys.add(key);
      final status = window.programStatus;
      if (!_statusByWindowKey.containsKey(key)) {
        _statusByWindowKey[key] = status;
        continue;
      }
      final event = tmuxProgramStatusEvent(_statusByWindowKey[key], status);
      _statusByWindowKey[key] = status;
      if (event != null) events.add((window: window, event: event));
    }
    _statusByWindowKey.removeWhere((key, _) => !keys.contains(key));
    return events;
  }

  /// Forgets every window, as for a new session.
  void clear() => _statusByWindowKey.clear();
}

/// The key a window's notification slot is named by: its stable id, else its
/// index.
String tmuxWindowNotificationKey(TmuxWindow window) =>
    window.id != null && isValidTmuxWindowId(window.id!)
    ? window.id!
    : 'index:${window.index}';
