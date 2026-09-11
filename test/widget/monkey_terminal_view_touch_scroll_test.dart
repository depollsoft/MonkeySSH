// ignore_for_file: implementation_imports, public_member_api_docs

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_gesture_detector.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_wheel_scroll_calibrator.dart';
import 'package:xterm/xterm.dart';

int _countOccurrences(String text, String pattern) {
  var count = 0;
  var start = 0;

  while (true) {
    final index = text.indexOf(pattern, start);
    if (index == -1) {
      return count;
    }
    count += 1;
    start = index + pattern.length;
  }
}

void _renderAdaptiveScrollRows(Terminal terminal, int firstRow) {
  final output = StringBuffer('\x1b[H\x1b[2J');
  for (var row = 0; row < terminal.viewHeight; row++) {
    output.write('adaptive row ${firstRow + row}');
    if (row + 1 < terminal.viewHeight) {
      output.write('\r\n');
    }
  }
  terminal.write(output.toString());
}

class _RecordingScrollBehavior extends ScrollBehavior {
  const _RecordingScrollBehavior(this.ballisticVelocities);

  final List<double> ballisticVelocities;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _RecordingScrollPhysics(ballisticVelocities.add);
}

class _RecordingScrollPhysics extends ScrollPhysics {
  const _RecordingScrollPhysics(this.recordVelocity, {super.parent});

  final ValueChanged<double> recordVelocity;

  @override
  _RecordingScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _RecordingScrollPhysics(recordVelocity, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    recordVelocity(velocity);
    return super.createBallisticSimulation(position, velocity);
  }
}

void main() {
  group('terminal wheel row displacement', () {
    const before = <String>[
      'header',
      'row one',
      'row two',
      'row three',
      'row four',
      'row five',
      'footer',
    ];

    test('detects one-row application scrolling', () {
      expect(
        resolveTerminalWheelRowsPerEvent(
          before: before,
          after: const <String>[
            'header',
            'row two',
            'row three',
            'row four',
            'row five',
            'row six',
            'footer',
          ],
        ),
        1,
      );
    });

    test('detects three-row application scrolling', () {
      expect(
        resolveTerminalWheelRowsPerEvent(
          before: before,
          after: const <String>[
            'header',
            'row four',
            'row five',
            'row six',
            'row seven',
            'row eight',
            'footer',
          ],
        ),
        3,
      );
    });

    test('does not infer a distance from an unrelated redraw', () {
      expect(
        resolveTerminalWheelRowsPerEvent(
          before: before,
          after: const <String>[
            'header',
            'alpha',
            'beta',
            'gamma',
            'delta',
            'epsilon',
            'footer',
          ],
        ),
        isNull,
      );
    });

    test('settles a canceled mouse probe until the next gesture', () {
      final calibrator = TerminalWheelScrollCalibrator();
      addTearDown(calibrator.dispose);
      expect(calibrator.begin(before: before, onSettled: (_, _) {}), isTrue);

      calibrator.cancelPending();

      expect(calibrator.needsMeasurement, isFalse);
      calibrator.invalidate();
      expect(calibrator.needsMeasurement, isTrue);
    });

    testWidgets('quarantines output that arrives after a timeout', (
      tester,
    ) async {
      final calibrator = TerminalWheelScrollCalibrator();
      addTearDown(calibrator.dispose);
      expect(calibrator.begin(before: before, onSettled: (_, _) {}), isTrue);

      await tester.pump(const Duration(milliseconds: 301));
      expect(calibrator.observingTerminalOutput, isTrue);
      expect(calibrator.needsMeasurement, isFalse);

      calibrator.beginGesture();
      expect(calibrator.needsMeasurement, isFalse);
      calibrator.terminalChanged(const <String>[
        'header',
        'row seven',
        'row eight',
        'row nine',
        'row ten',
        'row eleven',
        'footer',
      ]);
      await tester.pump(const Duration(milliseconds: 61));

      expect(calibrator.rowsPerEvent, 1);
      expect(calibrator.observingTerminalOutput, isFalse);
      expect(calibrator.needsMeasurement, isFalse);
      calibrator.beginGesture();
      expect(calibrator.needsMeasurement, isTrue);
    });

    testWidgets('no-output quarantine expiry keeps fallback settled', (
      tester,
    ) async {
      final calibrator = TerminalWheelScrollCalibrator();
      addTearDown(calibrator.dispose);
      expect(calibrator.begin(before: before, onSettled: (_, _) {}), isTrue);

      await tester.pump(const Duration(milliseconds: 301));
      expect(calibrator.observingTerminalOutput, isTrue);
      await tester.pump(const Duration(milliseconds: 901));

      expect(calibrator.observingTerminalOutput, isFalse);
      expect(calibrator.needsMeasurement, isFalse);
      calibrator.beginGesture();
      expect(calibrator.needsMeasurement, isTrue);
    });

    testWidgets('keeps observing after an unrelated redraw', (tester) async {
      final calibrator = TerminalWheelScrollCalibrator();
      addTearDown(calibrator.dispose);
      ({int previous, int current})? settled;
      expect(
        calibrator.begin(
          before: before,
          onSettled: (previous, current) {
            settled = (previous: previous, current: current);
          },
        ),
        isTrue,
      );

      calibrator.terminalChanged(const <String>[
        'header',
        'alpha',
        'beta',
        'gamma',
        'delta',
        'epsilon',
        'footer',
      ]);
      await tester.pump(const Duration(milliseconds: 61));

      expect(settled, isNull);
      expect(calibrator.waitingForResponse, isTrue);

      calibrator.terminalChanged(const <String>[
        'header',
        'row four',
        'row five',
        'row six',
        'row seven',
        'row eight',
        'footer',
      ]);
      await tester.pump(const Duration(milliseconds: 61));

      expect(settled, (previous: 1, current: 3));
      expect(calibrator.waitingForResponse, isFalse);
      calibrator.beginGesture();
      expect(calibrator.needsMeasurement, isFalse);
    });

    testWidgets('uses a late response when the hard timeout settles', (
      tester,
    ) async {
      final calibrator = TerminalWheelScrollCalibrator();
      addTearDown(calibrator.dispose);
      ({int previous, int current})? settled;
      expect(
        calibrator.begin(
          before: before,
          onSettled: (previous, current) {
            settled = (previous: previous, current: current);
          },
        ),
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 250));
      calibrator.terminalChanged(const <String>[
        'header',
        'row four',
        'row five',
        'row six',
        'row seven',
        'row eight',
        'footer',
      ]);
      await tester.pump(const Duration(milliseconds: 51));

      expect(settled, (previous: 1, current: 3));
      expect(calibrator.waitingForResponse, isFalse);
      calibrator.beginGesture();
      expect(calibrator.needsMeasurement, isFalse);

      calibrator.reset();
      expect(calibrator.rowsPerEvent, 3);
      expect(calibrator.needsMeasurement, isTrue);

      calibrator.reset(forgetEstimate: true);
      expect(calibrator.rowsPerEvent, 1);
    });
  });

  testWidgets('touch cadence adapts to application wheel row granularity', (
    tester,
  ) async {
    for (final rowsPerWheelEvent in <int>[1, 3]) {
      final terminal = Terminal()
        ..resize(40, 10)
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              autoResize: false,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
            ),
          ),
        ),
      );
      await tester.pump();
      _renderAdaptiveScrollRows(terminal, 0);
      await tester.pump();

      final output = <String>[];
      terminal.onOutput = (data) {
        output.add(data);
        if (output.length == 1) {
          scheduleMicrotask(
            () => _renderAdaptiveScrollRows(terminal, rowsPerWheelEvent),
          );
        }
      };

      final terminalState = tester.state<MonkeyTerminalViewState>(
        find.byType(MonkeyTerminalView),
      );
      final lineHeight = terminalState.renderTerminal.lineHeight;
      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * 3),
          localPosition: Offset(150, 100 - lineHeight * 3),
          delta: Offset(0, -lineHeight * 3),
        ),
      );
      expect(output, hasLength(1));

      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: Offset(150, 100 - lineHeight * 3),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * 6),
          localPosition: Offset(150, 100 - lineHeight * 6),
          delta: Offset(0, -lineHeight * 3),
        ),
      );
      expect(output, hasLength(1));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();

      expect(
        _countOccurrences(output.join(), '\x1b[<65;'),
        6 ~/ rowsPerWheelEvent,
      );

      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: Offset(150, 100 - lineHeight * 6),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * 12),
          localPosition: Offset(150, 100 - lineHeight * 12),
          delta: Offset(0, -lineHeight * 6),
        ),
      );

      // Once measured, a later gesture emits without another response probe.
      // Every responder starts with one report; only persistent queued movement
      // increases the frame budget.
      final reportsBeforeGesture = 6 ~/ rowsPerWheelEvent;
      final reportsInGesture = 6 ~/ rowsPerWheelEvent;
      expect(
        _countOccurrences(output.join(), '\x1b[<65;'),
        reportsBeforeGesture + 1,
      );
      await tester.pumpAndSettle();
      expect(
        _countOccurrences(output.join(), '\x1b[<65;'),
        reportsBeforeGesture + reportsInGesture,
      );

      final reportsAfterLearnedGesture = 12 ~/ rowsPerWheelEvent;
      terminal.write('\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l');
      await tester.pump();
      terminal.write('\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: Offset(150, 100 - lineHeight * 12),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * 15),
          localPosition: Offset(150, 100 - lineHeight * 15),
          delta: Offset(0, -lineHeight * 3),
        ),
      );
      expect(
        _countOccurrences(output.join(), '\x1b[<65;'),
        reportsAfterLearnedGesture + 1,
      );

      // If the transport re-probe receives no measurable redraw, keep the
      // previous safe gain instead of falling back to a fast one-row estimate.
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(
        _countOccurrences(output.join(), '\x1b[<65;'),
        reportsAfterLearnedGesture + 3 ~/ rowsPerWheelEvent,
      );
      detector.onTouchScrollCancel!();
    }
  });

  testWidgets('cancel keeps an emitted calibration probe in flight', (
    tester,
  ) async {
    final terminal = Terminal()
      ..resize(40, 10)
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            autoResize: false,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );
    _renderAdaptiveScrollRows(terminal, 0);
    await tester.pump();

    final output = <String>[];
    terminal.onOutput = output.add;
    final state = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = state.renderTerminal.lineHeight;
    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );

    void startAndDrag(double rows) {
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * rows),
          localPosition: Offset(150, 100 - lineHeight * rows),
          delta: Offset(0, -lineHeight * rows),
        ),
      );
    }

    startAndDrag(1);
    expect(_countOccurrences(output.join(), '\x1b[<65;'), 1);
    detector.onTouchScrollCancel!();

    startAndDrag(1);
    expect(_countOccurrences(output.join(), '\x1b[<65;'), 1);

    _renderAdaptiveScrollRows(terminal, 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - lineHeight * 5),
        localPosition: Offset(150, 100 - lineHeight * 5),
        delta: Offset(0, -lineHeight * 4),
      ),
    );
    expect(_countOccurrences(output.join(), '\x1b[<65;'), 2);
    detector.onTouchScrollCancel!();
  });

  testWidgets('calibrated sub-step distance accumulates across gestures', (
    tester,
  ) async {
    final terminal = Terminal()
      ..resize(40, 10)
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            autoResize: false,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );
    _renderAdaptiveScrollRows(terminal, 0);
    await tester.pump();

    final output = <String>[];
    terminal.onOutput = (data) {
      output.add(data);
      if (_countOccurrences(output.join(), '\x1b[<65;') == 1) {
        scheduleMicrotask(() => _renderAdaptiveScrollRows(terminal, 3));
      }
    };
    final state = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = state.renderTerminal.lineHeight;
    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );

    void dragOneRow() {
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight),
          localPosition: Offset(150, 100 - lineHeight),
          delta: Offset(0, -lineHeight),
        ),
      );
      detector.onTouchScrollEnd!(DragEndDetails(primaryVelocity: 0));
    }

    dragOneRow();
    expect(_countOccurrences(output.join(), '\x1b[<65;'), 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    for (var gesture = 0; gesture < 5; gesture++) {
      dragOneRow();
    }

    expect(_countOccurrences(output.join(), '\x1b[<65;'), 2);
    detector.onTouchScrollCancel!();
  });

  testWidgets(
    'alt buffer direct owner routes an actual touch drag to wheel input',
    (tester) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              hardwareKeyboardOnly: true,
              simulateScroll: false,
            ),
          ),
        ),
      );

      await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
      await tester.pump();

      expect(output.join(), contains('\x1b[<65;'));
    },
  );

  testWidgets('wheel calibration timeout drains queued touch distance', (
    tester,
  ) async {
    final terminal = Terminal()
      ..resize(40, 10)
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            autoResize: false,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );
    _renderAdaptiveScrollRows(terminal, 0);
    await tester.pump();

    final output = <String>[];
    terminal.onOutput = output.add;
    final terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - lineHeight * 3),
        localPosition: Offset(150, 100 - lineHeight * 3),
        delta: Offset(0, -lineHeight * 3),
      ),
    );

    expect(output, hasLength(1));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(_countOccurrences(output.join(), '\x1b[<65;'), 3);
    detector.onTouchScrollCancel!();
  });

  testWidgets('touch scroll falls back to arrow keys in alt buffer', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    final output = <String>[];
    terminal.onOutput = output.add;

    final expectedOutput = <String>[];
    Terminal()
      ..onOutput = expectedOutput.add
      ..keyInput(TerminalKey.arrowDown);
    final expectedArrowDown = expectedOutput.join();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
    await tester.pump();

    expect(output.join(), contains(expectedArrowDown));
  });

  testWidgets('touch scroll sends wheel input for mouse-reporting apps', (
    tester,
  ) async {
    final terminal = Terminal()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
    await tester.pump();

    expect(output.join(), contains('\u001b[<65;'));
    expect(output.join(), isNot(contains('\u001b[B')));
  });

  testWidgets(
    'forced touch scroll sends SGR wheel before mouse mode is known',
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;

      final arrowOutput = <String>[];
      Terminal()
        ..onOutput = arrowOutput.add
        ..keyInput(TerminalKey.arrowDown);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
              simulateScroll: false,
              forceSgrTouchScroll: true,
            ),
          ),
        ),
      );

      await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
      await tester.pump();

      expect(output.join(), contains('\u001b[<65;'));
      expect(output.join(), isNot(contains(arrowOutput.join())));
    },
  );

  testWidgets('forced SGR touch scroll emits one event per dragged row', (
    tester,
  ) async {
    final terminal = Terminal();
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
            simulateScroll: false,
            forceSgrTouchScroll: true,
          ),
        ),
      ),
    );

    final terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - lineHeight * 0.75),
        localPosition: Offset(150, 100 - lineHeight * 0.75),
        delta: Offset(0, -lineHeight * 0.75),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);

    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - lineHeight),
        localPosition: Offset(150, 100 - lineHeight),
        delta: Offset(0, -lineHeight * 0.25),
      ),
    );
    await tester.pump();

    expect(output, hasLength(1));
    expect(_countOccurrences(output.single, '\u001b[<65;'), 1);
  });

  testWidgets(
    'reported wheel scrolling increases batching only for persistent backlog',
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
              simulateScroll: false,
              forceSgrTouchScroll: true,
            ),
          ),
        ),
      );

      final state = tester.state<MonkeyTerminalViewState>(
        find.byType(MonkeyTerminalView),
      );
      final detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      final lineHeight = state.renderTerminal.lineHeight;
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: Offset(150, 100 - lineHeight * 10),
          localPosition: Offset(150, 100 - lineHeight * 10),
          delta: Offset(0, -lineHeight * 10),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: const Offset(150, 180),
          localPosition: const Offset(150, 180),
          delta: Offset(0, lineHeight * 4),
        ),
      );

      // Start linewise, then increase the budget only while the backlog
      // survives across frames. Direction order remains exact.
      expect(output, hasLength(1));
      expect(_countOccurrences(output.single, '\u001b[<65;'), 1);
      await tester.pump();
      expect(output, hasLength(2));
      expect(_countOccurrences(output[1], '\u001b[<65;'), 2);
      await tester.pump();
      expect(output, hasLength(3));
      expect(_countOccurrences(output[2], '\u001b[<65;'), 3);
      await tester.pump();
      expect(output, hasLength(4));
      expect(_countOccurrences(output[3], '\u001b[<65;'), 4);
      await tester.pump();
      expect(output, hasLength(5));
      expect(_countOccurrences(output[4], '\u001b[<64;'), 4);
      final joined = output.join();
      expect(_countOccurrences(joined, '\u001b[<65;'), 10);
      expect(_countOccurrences(joined, '\u001b[<64;'), 4);
      final down = RegExp(r'\x1b\[<65;\d+;(\d+)M').firstMatch(joined);
      final up = RegExp(r'\x1b\[<64;\d+;(\d+)M').firstMatch(joined);
      expect(down, isNotNull);
      expect(up, isNotNull);
      expect(down!.group(1), isNot(up!.group(1)));
    },
  );

  testWidgets(
    'mouse reporting and arrow fallback use the same touch scroll steps',
    (tester) async {
      final expectedOutput = <String>[];
      Terminal()
        ..onOutput = expectedOutput.add
        ..keyInput(TerminalKey.arrowDown);
      final expectedArrowDown = expectedOutput.join();

      final arrowTerminal = Terminal()..useAltBuffer();
      final arrowOutput = <String>[];
      arrowTerminal.onOutput = arrowOutput.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              arrowTerminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
            ),
          ),
        ),
      );

      var detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: const Offset(150, 10),
          localPosition: const Offset(150, 10),
          delta: const Offset(0, -240),
        ),
      );
      await tester.pump();

      final arrowCount = _countOccurrences(
        arrowOutput.join(),
        expectedArrowDown,
      );
      expect(arrowCount, greaterThan(0));

      final wheelTerminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final wheelOutput = <String>[];
      wheelTerminal.onOutput = wheelOutput.add;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              wheelTerminal,
              hardwareKeyboardOnly: true,
              touchScrollToTerminal: true,
            ),
          ),
        ),
      );

      detector = tester.widget<MonkeyTerminalGestureDetector>(
        find.byType(MonkeyTerminalGestureDetector),
      );
      detector.onTouchScrollStart!(
        DragStartDetails(
          kind: PointerDeviceKind.touch,
          localPosition: const Offset(150, 100),
        ),
      );
      detector.onTouchScrollUpdate!(
        DragUpdateDetails(
          kind: PointerDeviceKind.touch,
          globalPosition: const Offset(150, 10),
          localPosition: const Offset(150, 10),
          delta: const Offset(0, -240),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final wheelCount = _countOccurrences(wheelOutput.join(), '\u001b[<65;');
      expect(wheelCount, greaterThan(0));
      expect(wheelCount, arrowCount);
    },
  );

  testWidgets('direct terminal scrollback follows touch drags at 1x', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(scrollController.offset, greaterThan(100));
    final gesture = await tester.createGesture();
    await gesture.down(tester.getCenter(find.byType(MonkeyTerminalView)));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    final offsetAfterDragStart = scrollController.offset;
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    expect(offsetAfterDragStart - scrollController.offset, closeTo(20, 0.01));
    await gesture.up();
  });

  testWidgets('direct touch fling preserves platform velocity', (tester) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    final ballisticVelocities = <double>[];
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ScrollConfiguration(
          behavior: _RecordingScrollBehavior(ballisticVelocities),
          child: SizedBox(
            width: 300,
            height: 200,
            child: MonkeyTerminalView(
              terminal,
              scrollController: scrollController,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MonkeyTerminalView),
      const Offset(0, 80),
      1000,
    );
    await tester.pump();

    expect(ballisticVelocities, isNotEmpty);
    expect(
      ballisticVelocities.any(
        (velocity) => velocity.abs() >= 800 && velocity.abs() <= 1200,
      ),
      isTrue,
    );
  });

  testWidgets('touch down holds an active direct scrollback fling', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 300)
      ..write(List.filled(200, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MonkeyTerminalView),
      const Offset(0, 120),
      3000,
    );
    await tester.pump(const Duration(milliseconds: 16));

    final gesture = await tester.createGesture();
    await gesture.down(tester.getCenter(find.byType(MonkeyTerminalView)));
    await tester.pump();
    final heldOffset = scrollController.offset;
    await tester.pump(const Duration(milliseconds: 250));

    expect(scrollController.offset, closeTo(heldOffset, 0.01));
    await gesture.up();
  });

  testWidgets('alt buffer assigns touch to a dedicated recognizer', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
        ),
      ),
    );

    final scrollables = find.byType(Scrollable);
    expect(scrollables, findsNWidgets(2));
    for (final element in scrollables.evaluate()) {
      final behavior = ScrollConfiguration.of(element);
      expect(behavior.dragDevices, isNot(contains(PointerDeviceKind.touch)));
      expect(behavior.dragDevices, contains(PointerDeviceKind.trackpad));
    }

    final gestureDetector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    expect(gestureDetector.onTouchScrollDown, isNotNull);
    expect(gestureDetector.onTouchScrollStart, isNotNull);
    expect(gestureDetector.onTouchScrollUpdate, isNotNull);
    expect(gestureDetector.onTouchScrollEnd, isNotNull);
    expect(gestureDetector.onTouchScrollCancel, isNotNull);
    expect(gestureDetector.touchScrollVelocityTrackerBuilder, isNotNull);
    final terminalContext = tester.element(find.byType(MonkeyTerminalView));
    final inheritedBehavior = ScrollConfiguration.of(terminalContext);
    expect(
      gestureDetector.touchScrollMultitouchDragStrategy,
      inheritedBehavior.getMultitouchDragStrategy(terminalContext),
    );
  });

  testWidgets('canceling direct touch scroll releases its drag activity', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        globalPosition: const Offset(150, 100),
        localPosition: const Offset(150, 100),
        kind: PointerDeviceKind.touch,
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        globalPosition: const Offset(150, 120),
        localPosition: const Offset(150, 120),
        delta: const Offset(0, 20),
        primaryDelta: 20,
        kind: PointerDeviceKind.touch,
      ),
    );
    await tester.pump();
    final offsetAfterUpdate = scrollController.offset;

    detector.onTouchScrollCancel!();
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        globalPosition: const Offset(150, 140),
        localPosition: const Offset(150, 140),
        delta: const Offset(0, 20),
        primaryDelta: 20,
        kind: PointerDeviceKind.touch,
      ),
    );
    await tester.pump();

    expect(scrollController.offset, offsetAfterUpdate);
  });

  testWidgets('direct terminal scrollback keeps trackpad drags at 1x', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(MonkeyTerminalView));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(center);
    await gesture.panZoomUpdate(
      center + const Offset(0, 20),
      pan: const Offset(0, 20),
    );
    await tester.pump();

    final offsetAfterFirstUpdate = scrollController.offset;
    await gesture.panZoomUpdate(
      center + const Offset(0, 40),
      pan: const Offset(0, 40),
    );
    await tester.pump();

    expect(offsetAfterFirstUpdate - scrollController.offset, closeTo(20, 0.01));
    await gesture.panZoomEnd();
  });

  testWidgets('direct terminal scrollback keeps mouse wheels at 1x', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200)
      ..write(List.filled(100, 'line\r\n').join());
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final offsetBeforeWheel = scrollController.offset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(MonkeyTerminalView)),
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.pump();

    expect(offsetBeforeWheel - scrollController.offset, closeTo(20, 0.01));
  });

  testWidgets('direct scrollback leaves ambient physics to Scrollable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(Terminal(), hardwareKeyboardOnly: true),
        ),
      ),
    );

    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable));
    expect(scrollable.physics, isNull);
  });

  testWidgets('scroll reset clears pending touch scroll distance', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    final output = <String>[];
    terminal.onOutput = output.add;

    Widget buildTerminal(int scrollResetGeneration) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 200,
        child: MonkeyTerminalView(
          terminal,
          hardwareKeyboardOnly: true,
          touchScrollToTerminal: true,
          scrollResetGeneration: scrollResetGeneration,
        ),
      ),
    );

    await tester.pumpWidget(buildTerminal(0));
    var terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));
    final partialDelta = lineHeight * 0.75;

    var detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - partialDelta),
        localPosition: Offset(150, 100 - partialDelta),
        delta: Offset(0, -partialDelta),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);

    await tester.pumpWidget(buildTerminal(1));
    terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    expect(terminalState.renderTerminal.lineHeight, lineHeight);

    detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: Offset(150, 100 - partialDelta),
        localPosition: Offset(150, 100 - partialDelta),
        delta: Offset(0, -partialDelta),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('scroll reset clears pending trackpad scroll distance', (
    tester,
  ) async {
    final terminal = Terminal()
      ..useAltBuffer()
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = <String>[];
    terminal.onOutput = output.add;

    Widget buildTerminal(int scrollResetGeneration) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 200,
        child: MonkeyTerminalView(
          terminal,
          hardwareKeyboardOnly: true,
          simulateScroll: false,
          scrollResetGeneration: scrollResetGeneration,
        ),
      ),
    );

    await tester.pumpWidget(buildTerminal(0));
    final terminalState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final lineHeight = terminalState.renderTerminal.lineHeight;
    expect(lineHeight, greaterThan(0));
    final partialDelta = lineHeight * 0.75;

    final terminalFinder = find.byType(MonkeyTerminalView);
    final center = tester.getCenter(terminalFinder);
    var gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(
      center + Offset(0, -partialDelta),
      pan: Offset(0, -partialDelta),
    );
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(output, isEmpty);

    await tester.pumpWidget(buildTerminal(1));

    gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(
      center + Offset(0, -partialDelta),
      pan: Offset(0, -partialDelta),
    );
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('touch scroll keeps moving with inertia after lift-off', (
    tester,
  ) async {
    final terminal = Terminal()..useAltBuffer();
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: true,
          ),
        ),
      ),
    );

    final detector = tester.widget<MonkeyTerminalGestureDetector>(
      find.byType(MonkeyTerminalGestureDetector),
    );
    detector.onTouchScrollStart!(
      DragStartDetails(
        kind: PointerDeviceKind.touch,
        localPosition: const Offset(150, 100),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(150, 40),
        localPosition: const Offset(150, 40),
        delta: const Offset(0, -60),
      ),
    );
    detector.onTouchScrollUpdate!(
      DragUpdateDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(150, 10),
        localPosition: const Offset(150, 10),
        delta: const Offset(0, -60),
      ),
    );

    final beforeLiftOutputCount = output.length;
    expect(beforeLiftOutputCount, greaterThan(0));

    detector.onTouchScrollEnd!(
      DragEndDetails(
        primaryVelocity: -2000,
        velocity: const Velocity(pixelsPerSecond: Offset(0, -2000)),
      ),
    );
    await tester.pump();

    final afterLiftOutputCount = output.length;
    await tester.pump(const Duration(milliseconds: 200));

    expect(output.length, greaterThan(afterLiftOutputCount));
  });

  testWidgets('double taps invoke the terminal view callback', (tester) async {
    final terminal = Terminal();
    var doubleTapDowns = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            onDoubleTapDown: (tapDetails, cellOffset) => doubleTapDowns += 1,
          ),
        ),
      ),
    );

    final terminalFinder = find.byType(MonkeyTerminalView);
    final tapPosition = tester.getCenter(terminalFinder);
    await tester.tapAt(tapPosition);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(tapPosition);
    await tester.pump();

    expect(doubleTapDowns, 1);
  });

  testWidgets('desktop text insertion can be blocked by review callback', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(terminal, onInsertText: (_) async => false),
        ),
      ),
    );

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .requestKeyboard();
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'echo done',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('paste intent can be rerouted through reviewed callback', (
    tester,
  ) async {
    final terminal = Terminal()..write('selected text');
    final controller = TerminalController();
    final pendingReview = Completer<void>();
    final output = <String>[];
    terminal.onOutput = output.add;
    var pasteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: MonkeyTerminalView(
            terminal,
            controller: controller,
            hardwareKeyboardOnly: true,
            onPasteText: () async {
              pasteCalls += 1;
              if (pasteCalls == 2) {
                await pendingReview.future;
              }
            },
          ),
        ),
      ),
    );

    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(8, 0),
    );
    expect(terminal.buffer.getText(controller.selection), 'selected');

    final actionsWidget = tester
        .widgetList<Actions>(find.byType(Actions))
        .firstWhere((widget) => widget.actions.containsKey(PasteTextIntent));
    final pasteAction = actionsWidget.actions[PasteTextIntent];
    expect(pasteAction, isA<CallbackAction<PasteTextIntent>>());
    final context = tester.element(find.byWidget(actionsWidget.child));
    Actions.invoke(
      context,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();

    expect(pasteCalls, 1);
    expect(output, isEmpty);
    expect(terminal.buffer.getText(controller.selection), 'selected');

    final pendingPaste =
        Actions.invoke(
              context,
              const PasteTextIntent(SelectionChangedCause.keyboard),
            )
            as Future<Object?>?;
    expect(pasteCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    pendingReview.complete();
    await pendingPaste;
    expect(tester.takeException(), isNull);
    expect(output, isEmpty);
  });
}
