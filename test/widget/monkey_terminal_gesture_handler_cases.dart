import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_detector.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_handler.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void registerMonkeyTerminalGestureHandlerTests() {
  group('monkey_terminal_gesture_handler', () {
    testWidgets('tertiary taps invoke tertiary callbacks', (tester) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      var secondaryTapDowns = 0;
      var secondaryTapUps = 0;
      var tertiaryTapDowns = 0;
      var tertiaryTapUps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              onSecondaryTapDown: (_) => secondaryTapDowns += 1,
              onSecondaryTapUp: (_) => secondaryTapUps += 1,
              onTertiaryTapDown: (_) => tertiaryTapDowns += 1,
              onTertiaryTapUp: (_) => tertiaryTapUps += 1,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTertiaryTapDown!(
        TapDownDetails(localPosition: const Offset(10, 10)),
      );
      detector.onTertiaryTapUp!(
        TapUpDetails(
          kind: PointerDeviceKind.mouse,
          localPosition: const Offset(10, 10),
        ),
      );

      expect(secondaryTapDowns, 0);
      expect(secondaryTapUps, 0);
      expect(tertiaryTapDowns, 1);
      expect(tertiaryTapUps, 1);
    });

    testWidgets('link taps bypass terminal mouse callbacks', (tester) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      var tapDowns = 0;
      var tapUps = 0;
      var pendingLinkTaps = 0;
      TapDownDetails? pendingLinkTapDown;
      final openedLinks = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              resolveLinkTap: (_) => 'https://github.com/features/copilot',
              onLinkTapDown: (details) {
                pendingLinkTaps += 1;
                pendingLinkTapDown = details;
              },
              onLinkTap: openedLinks.add,
              onTapDown: (_) => tapDowns += 1,
              onSingleTapUp: (_) => tapUps += 1,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTapDown!(TapDownDetails(localPosition: const Offset(10, 10)));
      detector.onSingleTapUp!(
        TapUpDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(10, 10),
        ),
      );

      expect(openedLinks, ['https://github.com/features/copilot']);
      expect(pendingLinkTaps, 1);
      expect(pendingLinkTapDown, isNotNull);
      expect(pendingLinkTapDown!.localPosition, const Offset(10, 10));
      expect(tapDowns, 0);
      expect(tapUps, 0);
    });

    testWidgets('double taps invoke explicit callback when provided', (
      tester,
    ) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      var doubleTapDowns = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              onDoubleTapDown: (_) => doubleTapDowns += 1,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onDoubleTapDown!(
        TapDownDetails(localPosition: const Offset(10, 10)),
      );

      expect(doubleTapDowns, 1);
    });

    testWidgets(
      'double taps invoke explicit callback when selection gestures are disabled',
      (tester) async {
        final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 300,
              height: 200,
              child: MonkeyTerminalView(
                key: terminalViewKey,
                Terminal(),
                readOnly: true,
              ),
            ),
          ),
        );

        final terminalViewState = terminalViewKey.currentState!;
        var doubleTapDowns = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 300,
              height: 200,
              child: MonkeyTerminalGestureHandler(
                terminalView: terminalViewState,
                terminalController: TerminalController(),
                readOnly: true,
                enableTerminalSelectionGestures: false,
                onDoubleTapDown: (_) => doubleTapDowns += 1,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        final detector = tester.widget<MonkeyTerminalGestureDetector>(
          find.byType(MonkeyTerminalGestureDetector),
        );
        detector.onDoubleTapDown!(
          TapDownDetails(localPosition: const Offset(10, 10)),
        );

        expect(doubleTapDowns, 1);
      },
    );

    testWidgets('link taps work when selection gestures are disabled', (
      tester,
    ) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      final openedLinks = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              enableTerminalSelectionGestures: false,
              resolveLinkTap: (_) => 'https://github.com/features/copilot',
              onLinkTap: openedLinks.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTapDown!(TapDownDetails(localPosition: const Offset(10, 10)));
      detector.onSingleTapUp!(
        TapUpDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(10, 10),
        ),
      );

      expect(openedLinks, ['https://github.com/features/copilot']);
    });

    testWidgets('touch scroll clears any pending link tap', (tester) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      var tapUps = 0;
      final openedLinks = <String>[];
      var touchScrollStarts = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              resolveLinkTap: (localPosition) => localPosition.dx < 20
                  ? 'https://github.com/features/copilot'
                  : null,
              onLinkTap: openedLinks.add,
              onSingleTapUp: (_) => tapUps += 1,
              onTouchScrollStart: (_) => touchScrollStarts += 1,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTapDown!(TapDownDetails(localPosition: const Offset(10, 10)));
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(40, 10),
        ),
      );
      detector.onSingleTapUp!(
        TapUpDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(40, 10),
        ),
      );

      expect(openedLinks, isEmpty);
      expect(tapUps, 1);
      expect(touchScrollStarts, 1);
    });

    testWidgets('nearby consecutive link taps still open links', (
      tester,
    ) async {
      final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              key: terminalViewKey,
              Terminal(),
              readOnly: true,
            ),
          ),
        ),
      );

      final terminalViewState = terminalViewKey.currentState!;
      final openedLinks = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureHandler(
              terminalView: terminalViewState,
              terminalController: TerminalController(),
              readOnly: true,
              resolveLinkTap: (_) => 'sftp://link',
              onLinkTap: openedLinks.add,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        ),
      );

      final handlerFinder = find.byType(MonkeyTerminalGestureHandler);
      final topLeft = tester.getTopLeft(handlerFinder);
      await tester.tapAt(topLeft + const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(topLeft + const Offset(10, 20));
      await tester.pump(const Duration(milliseconds: 400));

      expect(openedLinks, ['sftp://link', 'sftp://link']);
    });

    testWidgets('bypassed taps clear stale double-tap timers', (tester) async {
      var shouldBypassDoubleTap = false;
      var doubleTapDowns = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalGestureDetector(
              shouldBypassDoubleTap: () => shouldBypassDoubleTap,
              onDoubleTapDown: (_) => doubleTapDowns += 1,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        ),
      );

      const firstTap = Offset(10, 10);
      const secondTap = Offset(20, 10);

      await tester.tapAt(firstTap);
      await tester.pump(const Duration(milliseconds: 100));

      shouldBypassDoubleTap = true;
      await tester.tapAt(secondTap);
      await tester.pump(kDoubleTapTimeout - const Duration(milliseconds: 50));

      shouldBypassDoubleTap = false;
      await tester.tapAt(secondTap);
      await tester.pump();

      expect(doubleTapDowns, 1);
    });
  });
}
