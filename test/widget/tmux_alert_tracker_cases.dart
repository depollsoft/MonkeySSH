import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/tmux_alert_tracker.dart';

void registerTmuxAlertTrackerTests() {
  group('tmux alert tracking', () {
    test(
      'tmux alert notifications clear only emitted stable IDs on activation',
      () {
        final tracker = TmuxAlertTracker();
        final shownNotificationIds = <int>[];
        final clearedNotificationIds = <int>[];
        const tmuxSessionName = 'work';
        const windowIndex = 1;
        const windowId = '@9';
        const indexOnlyWindowIndex = 2;
        const initialWindows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(
            index: windowIndex,
            id: windowId,
            name: 'agent',
            isActive: false,
          ),
          TmuxWindow(
            index: indexOnlyWindowIndex,
            name: 'logs',
            isActive: false,
          ),
        ];
        int notificationId(Object window) =>
            Object.hash(1, 7, tmuxSessionName, window) & 0x7fffffff;
        final stableNotificationId = notificationId(windowId);
        final indexOnlyNotificationId = notificationId(indexOnlyWindowIndex);
        var windows = initialWindows;
        void apply(TmuxWindow? changed) {
          if (changed != null) {
            windows = [
              for (final w in windows)
                if (w.index == changed.index) changed else w,
            ];
          }
          tracker.applyWindows(
            windows,
            hostId: 1,
            connectionId: 7,
            tmuxSessionName: tmuxSessionName,
            onAlert: (_, _, id, _) => shownNotificationIds.add(id),
            onClear: clearedNotificationIds.add,
          );
        }

        apply(null);
        expect(shownNotificationIds, isEmpty);
        expect(clearedNotificationIds, isEmpty);
        final shownIds = <int>[];
        for (final window in initialWindows.skip(1)) {
          apply(window.copyWith(flags: '!'));
          shownIds.add(
            window.id == null ? indexOnlyNotificationId : stableNotificationId,
          );
          expect(shownNotificationIds, shownIds);
          expect(clearedNotificationIds, isEmpty);
        }
        apply(initialWindows[1].copyWith(isActive: true, flags: '!'));
        expect(clearedNotificationIds, [stableNotificationId]);
      },
    );
  });
}
