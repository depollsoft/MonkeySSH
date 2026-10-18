import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
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
        int notificationId(String windowKey) =>
            buildWindowNotificationId(1, tmuxSessionName, windowKey);
        final stableNotificationId = notificationId(windowId);
        final indexOnlyNotificationId = notificationId(
          'index:$indexOnlyWindowIndex',
        );
        TmuxWindow withAlert(TmuxWindow window, {bool? isActive}) => TmuxWindow(
          index: window.index,
          id: window.id,
          name: window.name,
          isActive: isActive ?? window.isActive,
          flags: '!',
        );
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
          apply(withAlert(window));
          shownIds.add(
            window.id == null ? indexOnlyNotificationId : stableNotificationId,
          );
          expect(shownNotificationIds, shownIds);
          expect(clearedNotificationIds, isEmpty);
        }
        apply(withAlert(initialWindows[1], isActive: true));
        expect(clearedNotificationIds, [stableNotificationId]);
      },
    );

    test('two connections to a session alert into the same window slot', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
        TmuxWindow(index: 1, id: '@2', name: 'agent', isActive: false),
      ];
      const alerted = <TmuxWindow>[
        TmuxWindow(index: 0, id: '@1', name: 'shell', isActive: true),
        TmuxWindow(
          index: 1,
          id: '@2',
          name: 'agent',
          isActive: false,
          flags: '!',
        ),
      ];
      final ids = <int>[];
      for (final tracker in [TmuxAlertTracker(), TmuxAlertTracker()]) {
        for (final snapshot in [windows, alerted]) {
          tracker.applyWindows(
            snapshot,
            hostId: 3,
            tmuxSessionName: 'work',
            onAlert: (_, _, id, _) => ids.add(id),
            onClear: (_) {},
          );
        }
      }
      // Each connection's bar raises it, but both land in one notification.
      expect(ids, hasLength(2));
      expect(ids.toSet(), {buildWindowNotificationId(3, 'work', '@2')});
    });

    group('program status events', () {
      TmuxWindow agent(List<MuxWindowStatusEvent> events, {String id = '@2'}) =>
          TmuxWindow(
            index: 1,
            id: id,
            name: 'agent',
            isActive: false,
            statusEvents: events,
          );
      const approval = MuxWindowStatusEvent(
        seq: 1,
        kind: MuxWindowStatusKind.permission,
      );
      const finished = MuxWindowStatusEvent(
        seq: 2,
        kind: MuxWindowStatusKind.finished,
      );
      const question = MuxWindowStatusEvent(
        seq: 3,
        kind: MuxWindowStatusKind.input,
      );

      test('the first snapshot of a window only sets its baseline', () {
        final tracker = TmuxProgramStatusTracker();
        expect(
          tracker.applyWindows([
            agent(const [approval]),
          ]),
          isEmpty,
        );
        expect(
          tracker.applyWindows([
            agent(const [approval]),
          ]),
          isEmpty,
        );
        final next = tracker.applyWindows([
          agent(const [approval, finished]),
        ]);
        expect(next.single.kind, MuxWindowStatusKind.finished);
        // A window that closed and came back starts over.
        expect(tracker.applyWindows(const []), isEmpty);
        expect(
          tracker.applyWindows([
            agent(const [approval, finished]),
          ]),
          isEmpty,
        );
      });

      // Each numbered event is raised once, also when several arrive in one
      // snapshot because the window's status changed and changed back.
      test('every unseen event is yielded once, oldest first', () {
        final tracker = TmuxProgramStatusTracker()
          ..applyWindows([agent(const [])]);
        expect(
          tracker
              .applyWindows([
                agent(const [approval, finished]),
              ])
              .map((event) => event.kind),
          [MuxWindowStatusKind.permission, MuxWindowStatusKind.finished],
        );
        expect(
          tracker.applyWindows([
            agent(const [approval, finished]),
          ]),
          isEmpty,
        );
        expect(
          tracker
              .applyWindows([
                agent(const [approval, finished, question]),
              ])
              .single
              .kind,
          MuxWindowStatusKind.input,
        );
      });

      test('a restarted server sets the baseline again', () {
        final tracker = TmuxProgramStatusTracker()
          ..applyWindows([
            agent(const [approval, finished, question]),
          ]);
        expect(
          tracker.applyWindows([
            agent(const [approval]),
          ]),
          isEmpty,
        );
        expect(
          tracker
              .applyWindows([
                agent(const [approval, finished]),
              ])
              .single
              .kind,
          MuxWindowStatusKind.finished,
        );
      });
    });

    test(
      'window slots are stable and distinct per host, session and window',
      () {
        final slot = buildWindowNotificationId(3, 'work', '@2');
        expect(buildWindowNotificationId(3, 'work', '@2'), slot);
        for (final other in [
          buildWindowNotificationId(4, 'work', '@2'),
          buildWindowNotificationId(3, 'play', '@2'),
          buildWindowNotificationId(3, 'work', '@3'),
          buildWindowNotificationId(3, 'work', 'index:2'),
        ]) {
          expect(other, isNot(slot));
        }
        // A positive 31-bit id, as Android and the plugin require.
        expect(slot, inInclusiveRange(1, 0x7fffffff));
      },
    );
  });
}
