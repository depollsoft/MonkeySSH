// fake_async is supplied by flutter_test; dependency manifests are outside this job.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
// ignore_for_file: implementation_imports, public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_scroll_gesture_handler.dart';
import 'package:monkeyssh/presentation/widgets/terminal_scroll_mouse_input.dart';
import 'package:monkeyssh/presentation/widgets/terminal_wheel_scroll_calibrator.dart';
import 'package:xterm/xterm.dart';

void _renderTrackpadCalibrationRows(Terminal terminal, int firstRow) {
  final output = StringBuffer('\x1b[H\x1b[2J');
  for (var row = 0; row < terminal.viewHeight; row++) {
    output.write('trackpad row ${firstRow + row}');
    if (row + 1 < terminal.viewHeight) {
      output.write('\r\n');
    }
  }
  terminal.write(output.toString());
}

void registerMonkeyTerminalScrollGestureHandlerTests() {
  group('monkey_terminal_scroll_gesture_handler', () {
    test('trackpad cadence adapts to multi-row wheel responders', () {
      fakeAsync((async) {
        final terminal = Terminal()
          ..resize(40, 10)
          ..useAltBuffer()
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        _renderTrackpadCalibrationRows(terminal, 0);
        final output = <String>[];
        terminal.onOutput = output.add;

        final accumulator = TerminalScrollAccumulator(
          terminal: () => terminal,
          getLineHeight: () => 10,
          sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
            terminal: terminal,
            button: up
                ? TerminalMouseButton.wheelUp
                : TerminalMouseButton.wheelDown,
            position: const CellOffset(1, 1),
          ),
        );
        var mouseMode = terminal.mouseMode;
        var reportMode = terminal.mouseReportMode;
        void terminalChanged() {
          if (mouseMode != terminal.mouseMode ||
              reportMode != terminal.mouseReportMode) {
            mouseMode = terminal.mouseMode;
            reportMode = terminal.mouseReportMode;
            accumulator.resetRemainder();
          } else if (accumulator.calibrator.observingTerminalOutput) {
            accumulator.calibrator.terminalChanged(
              captureTerminalViewportLines(terminal),
            );
          }
        }

        terminal.addListener(terminalChanged);

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(30);
        expect(output, hasLength(1));

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(60);
        expect(output, hasLength(1));

        _renderTrackpadCalibrationRows(terminal, 3);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(milliseconds: 80));

        expect(output, hasLength(2));

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(120);

        expect(output, hasLength(4));

        terminal.removeListener(terminalChanged);
        accumulator.dispose();
      });
    });

    test('mouse wheel retries a timed-out calibration', () {
      fakeAsync((async) {
        final terminal = Terminal()
          ..resize(40, 10)
          ..useAltBuffer()
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        _renderTrackpadCalibrationRows(terminal, 0);
        final output = <String>[];
        terminal.onOutput = output.add;

        final accumulator = TerminalScrollAccumulator(
          terminal: () => terminal,
          getLineHeight: () => 10,
          sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
            terminal: terminal,
            button: up
                ? TerminalMouseButton.wheelUp
                : TerminalMouseButton.wheelDown,
            position: const CellOffset(1, 1),
          ),
        );
        var mouseMode = terminal.mouseMode;
        var reportMode = terminal.mouseReportMode;
        void terminalChanged() {
          if (mouseMode != terminal.mouseMode ||
              reportMode != terminal.mouseReportMode) {
            mouseMode = terminal.mouseMode;
            reportMode = terminal.mouseReportMode;
            accumulator.resetRemainder();
          } else if (accumulator.calibrator.observingTerminalOutput) {
            accumulator.calibrator.terminalChanged(
              captureTerminalViewportLines(terminal),
            );
          }
        }

        terminal.addListener(terminalChanged);

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(-30);
        async.flushMicrotasks();
        expect(output, hasLength(1));

        async.elapse(const Duration(milliseconds: 301));
        expect(output, hasLength(3));
        async.elapse(const Duration(milliseconds: 901));
        output.clear();

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(-60);
        async.flushMicrotasks();

        expect(output, hasLength(1));

        terminal.removeListener(terminalChanged);
        accumulator.dispose();
      });
    });

    testWidgets(
      'trackpad scrolling preserves the gesture location in alt buffer',
      (tester) async {
        final terminal = Terminal()
          ..useAltBuffer()
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        final output = <String>[];
        final reportedPositions = <Offset>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: MonkeyTerminalScrollGestureHandler(
                    terminal: terminal,
                    simulateScroll: false,
                    getCellOffset: (offset) {
                      reportedPositions.add(offset);
                      return CellOffset(offset.dx ~/ 10, offset.dy ~/ 10);
                    },
                    getLineHeight: () => 10,
                    child: const ColoredBox(
                      key: ValueKey('trackpad-target'),
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final center = tester.getCenter(
          find.byKey(const ValueKey('trackpad-target')),
        );
        final targetRect = tester.getRect(
          find.byKey(const ValueKey('trackpad-target')),
        );
        final localTargetRect = Offset.zero & targetRect.size;
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );

        await gesture.panZoomStart(center + const Offset(20, -10));
        await tester.pump();
        await gesture.panZoomUpdate(
          center + const Offset(20, -30),
          pan: const Offset(0, -20),
        );
        await tester.pump();
        await gesture.panZoomEnd();
        await tester.pump();

        expect(output, hasLength(2));
        expect(output, everyElement(startsWith('\x1b[<65;')));
        expect(reportedPositions, hasLength(2));
        for (final position in reportedPositions) {
          expect(position, isNot(Offset.zero));
          expect(localTargetRect.contains(position), isTrue);
        }
      },
    );

    test(
      'trackpad reversal waits for a full line before sending a reverse step',
      () {
        fakeAsync((async) {
          final terminal = Terminal()
            ..useAltBuffer()
            ..setMouseMode(MouseMode.upDownScroll)
            ..setMouseReportMode(MouseReportMode.sgr);
          final output = <String>[];
          terminal.onOutput = output.add;

          final accumulator = TerminalScrollAccumulator(
            terminal: () => terminal,
            getLineHeight: () => 10,
            sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
              terminal: terminal,
              button: up
                  ? TerminalMouseButton.wheelUp
                  : TerminalMouseButton.wheelDown,
              position: const CellOffset(1, 1),
            ),
          );
          var mouseMode = terminal.mouseMode;
          var reportMode = terminal.mouseReportMode;
          void terminalChanged() {
            if (mouseMode != terminal.mouseMode ||
                reportMode != terminal.mouseReportMode) {
              mouseMode = terminal.mouseMode;
              reportMode = terminal.mouseReportMode;
              accumulator.resetRemainder();
            } else if (accumulator.calibrator.observingTerminalOutput) {
              accumulator.calibrator.terminalChanged(
                captureTerminalViewportLines(terminal),
              );
            }
          }

          terminal.addListener(terminalChanged);

          accumulator.calibrator.beginGesture();
          async.flushMicrotasks();
          accumulator.onScroll(10);
          async.flushMicrotasks();

          expect(output, hasLength(1));

          accumulator.onScroll(4);
          async.flushMicrotasks();

          expect(output, hasLength(1));

          async.flushMicrotasks();

          terminal.removeListener(terminalChanged);
          accumulator.dispose();
        });
      },
    );

    testWidgets('trackpad scrolling reports SGR wheel up as button 64', (
      tester,
    ) async {
      final terminal = Terminal()
        ..useAltBuffer()
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: MonkeyTerminalScrollGestureHandler(
                  terminal: terminal,
                  simulateScroll: false,
                  getCellOffset: (_) => const CellOffset(1, 1),
                  getLineHeight: () => 10,
                  child: const ColoredBox(
                    key: ValueKey('sgr-wheel-up-target'),
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(
        find.byKey(const ValueKey('sgr-wheel-up-target')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );

      await gesture.panZoomStart(center);
      await tester.pump();
      await gesture.panZoomUpdate(
        center + const Offset(0, 10),
        pan: const Offset(0, 10),
      );
      await tester.pump();
      await gesture.panZoomEnd();
      await tester.pump();

      expect(output, hasLength(1));
      expect(output.single, startsWith('\x1b[<64;'));
    });

    // --- Line coalescing / remainder tests ---
    // The implementation accumulates scroll deltas in scrollRemainder and only
    // emits one wheel event per full line-height of movement.  These tests
    // document that behaviour so it is not accidentally regressed.

    test(
      'sub-line-height delta does not emit a scroll event (remainder held)',
      () {
        fakeAsync((async) {
          final terminal = Terminal()
            ..useAltBuffer()
            ..setMouseMode(MouseMode.upDownScroll)
            ..setMouseReportMode(MouseReportMode.sgr);
          final output = <String>[];
          terminal.onOutput = output.add;

          final accumulator = TerminalScrollAccumulator(
            terminal: () => terminal,
            getLineHeight: () => 20,
            sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
              terminal: terminal,
              button: up
                  ? TerminalMouseButton.wheelUp
                  : TerminalMouseButton.wheelDown,
              position: const CellOffset(1, 1),
            ),
          );
          var mouseMode = terminal.mouseMode;
          var reportMode = terminal.mouseReportMode;
          void terminalChanged() {
            if (mouseMode != terminal.mouseMode ||
                reportMode != terminal.mouseReportMode) {
              mouseMode = terminal.mouseMode;
              reportMode = terminal.mouseReportMode;
              accumulator.resetRemainder();
            } else if (accumulator.calibrator.observingTerminalOutput) {
              accumulator.calibrator.terminalChanged(
                captureTerminalViewportLines(terminal),
              );
            }
          }

          terminal.addListener(terminalChanged);

          accumulator.calibrator.beginGesture();
          async.flushMicrotasks();
          // Move 19 px — one shy of the 20 px line height.
          accumulator.onScroll(19);
          async.flushMicrotasks();

          // No full line reached yet; remainder is held.
          expect(output, isEmpty);

          async.flushMicrotasks();

          terminal.removeListener(terminalChanged);
          accumulator.dispose();
        });
      },
    );

    test('two partial deltas that together exceed one line height emit exactly one event', () {
      fakeAsync((async) {
        final terminal = Terminal()
          ..useAltBuffer()
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        final output = <String>[];
        terminal.onOutput = output.add;

        final accumulator = TerminalScrollAccumulator(
          terminal: () => terminal,
          getLineHeight: () => 20,
          sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
            terminal: terminal,
            button: up
                ? TerminalMouseButton.wheelUp
                : TerminalMouseButton.wheelDown,
            position: const CellOffset(1, 1),
          ),
        );
        var mouseMode = terminal.mouseMode;
        var reportMode = terminal.mouseReportMode;
        void terminalChanged() {
          if (mouseMode != terminal.mouseMode ||
              reportMode != terminal.mouseReportMode) {
            mouseMode = terminal.mouseMode;
            reportMode = terminal.mouseReportMode;
            accumulator.resetRemainder();
          } else if (accumulator.calibrator.observingTerminalOutput) {
            accumulator.calibrator.terminalChanged(
              captureTerminalViewportLines(terminal),
            );
          }
        }

        terminal.addListener(terminalChanged);

        accumulator.calibrator.beginGesture();
        async.flushMicrotasks();

        // First partial: 12 px — below the 20 px threshold.
        accumulator.onScroll(12);
        async.flushMicrotasks();
        expect(output, isEmpty);

        // Second partial: +10 px more (total 22 px) — crosses one line height.
        accumulator.onScroll(22);
        async.flushMicrotasks();
        expect(output, hasLength(1));

        async.flushMicrotasks();

        terminal.removeListener(terminalChanged);
        accumulator.dispose();
      });
    });

    test('mouse mode changes discard partial trackpad distance', () {
      fakeAsync((async) {
        final terminal = Terminal()..useAltBuffer();
        final output = <String>[];
        terminal.onOutput = output.add;

        final accumulator = TerminalScrollAccumulator(
          terminal: () => terminal,
          getLineHeight: () => 10,
          sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
            terminal: terminal,
            button: up
                ? TerminalMouseButton.wheelUp
                : TerminalMouseButton.wheelDown,
            position: const CellOffset(1, 1),
          ),
        );
        var mouseMode = terminal.mouseMode;
        var reportMode = terminal.mouseReportMode;
        void terminalChanged() {
          if (mouseMode != terminal.mouseMode ||
              reportMode != terminal.mouseReportMode) {
            mouseMode = terminal.mouseMode;
            reportMode = terminal.mouseReportMode;
            accumulator.resetRemainder();
          } else if (accumulator.calibrator.observingTerminalOutput) {
            accumulator.calibrator.terminalChanged(
              captureTerminalViewportLines(terminal),
            );
          }
        }

        terminal.addListener(terminalChanged);

        accumulator
          ..calibrator.beginGesture()
          ..onScroll(7);
        async.flushMicrotasks();
        expect(output, isEmpty);

        terminal.write('\x1b[?1003h\x1b[?1006h');
        async.flushMicrotasks();

        accumulator.onScroll(10);
        async.flushMicrotasks();
        expect(output, isEmpty);

        accumulator.onScroll(17);
        async.flushMicrotasks();
        expect(output, hasLength(1));
        expect(output.single, startsWith('\x1b[<65;'));

        terminal.removeListener(terminalChanged);
        accumulator.dispose();
      });
    });

    test('large single delta emits one event per full line height', () {
      fakeAsync((async) {
        final terminal = Terminal()
          ..useAltBuffer()
          ..setMouseMode(MouseMode.upDownScroll)
          ..setMouseReportMode(MouseReportMode.sgr);
        final output = <String>[];
        terminal.onOutput = output.add;

        final accumulator = TerminalScrollAccumulator(
          terminal: () => terminal,
          getLineHeight: () => 10,
          sendScrollEvent: ({required up}) => sendTerminalScrollMouseInput(
            terminal: terminal,
            button: up
                ? TerminalMouseButton.wheelUp
                : TerminalMouseButton.wheelDown,
            position: const CellOffset(1, 1),
          ),
        );
        var mouseMode = terminal.mouseMode;
        var reportMode = terminal.mouseReportMode;
        void terminalChanged() {
          if (mouseMode != terminal.mouseMode ||
              reportMode != terminal.mouseReportMode) {
            mouseMode = terminal.mouseMode;
            reportMode = terminal.mouseReportMode;
            accumulator.resetRemainder();
          } else if (accumulator.calibrator.observingTerminalOutput) {
            accumulator.calibrator.terminalChanged(
              captureTerminalViewportLines(terminal),
            );
          }
        }

        terminal.addListener(terminalChanged);

        accumulator.calibrator.beginGesture();
        async.flushMicrotasks();

        // 35 px with a 10 px line height → 3 full lines, 5 px remainder held.
        accumulator.onScroll(35);
        async.flushMicrotasks();

        expect(output, hasLength(3));
        // All events should be wheel-up (button 65 in SGR).
        expect(output, everyElement(startsWith('\x1b[<65;')));

        async.flushMicrotasks();

        // No extra event emitted at gesture end (remainder < line height).
        expect(output, hasLength(3));

        terminal.removeListener(terminalChanged);
        accumulator.dispose();
      });
    });
  });
}
