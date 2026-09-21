import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('resolveTmuxAlertNotificationContent', () {
    test('titles the window and routes through host and session', () {
      const window = TmuxWindow(
        index: 2,
        name: 'agent',
        isActive: false,
        paneTitle: 'Build finished',
      );

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: ' work ',
        window: window,
        hostLabel: 'devbox',
      );

      expect(content.title, 'Build finished');
      expect(content.subtitle, 'devbox · work · agent');
      expect(content.body, 'Window #2 needs attention');
    });

    test('keeps the window number in the body so twins stay distinct', () {
      const window = TmuxWindow(
        index: 3,
        name: 'agent-b',
        isActive: false,
        paneTitle: 'Build   finished',
      );

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: 'work',
        window: window,
      );

      expect(content.title, 'Build finished');
      expect(content.subtitle, 'work · agent-b');
      expect(content.body, 'Window #3 needs attention');
    });

    test('falls back to the window number without a usable title', () {
      const window = TmuxWindow(index: 4, name: '   ', isActive: false);

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: '',
        window: window,
      );

      expect(content.title, 'Window #4');
      expect(content.subtitle, isNull);
      expect(content.body, 'Needs attention');
    });

    test(
      'a forwarded notification keeps its own text and names the window',
      () {
        const window = TmuxWindow(
          index: 1,
          name: 'agent',
          isActive: false,
          paneTitle: 'Fix login bug',
        );

        final content = resolveTmuxAlertNotificationContent(
          tmuxSessionName: 'work',
          window: window,
          hostLabel: 'devbox',
          title: ' Deploy done ',
          body: 'All green',
        );

        expect(content.title, 'Deploy done');
        expect(content.subtitle, 'devbox · work · Fix login bug · agent');
        expect(content.body, 'All green');
      },
    );

    test(
      'a forwarded notification without a title falls back to the window',
      () {
        const window = TmuxWindow(
          index: 1,
          name: 'shell',
          isActive: false,
          paneTitle: 'Deploy done',
        );

        final content = resolveTmuxAlertNotificationContent(
          tmuxSessionName: 'work',
          window: window,
          hostLabel: 'Deploy done',
          title: '',
          body: 'All green',
        );

        expect(content.title, 'Deploy done');
        // The host label repeats the title, so it is dropped from the route.
        expect(content.subtitle, 'work · shell');
        expect(content.body, 'All green');
      },
    );
  });
}
