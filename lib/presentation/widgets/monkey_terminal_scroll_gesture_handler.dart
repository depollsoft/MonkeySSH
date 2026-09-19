// ignore_for_file: implementation_imports, public_member_api_docs, always_put_required_named_parameters_first, type_annotate_public_apis, use_setters_to_change_properties

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

import 'terminal_scroll_mouse_input.dart';
import 'terminal_wheel_scroll_calibrator.dart';

/// Handles alt-buffer scrolling while preserving trackpad gesture position.
class MonkeyTerminalScrollGestureHandler extends StatefulWidget {
  const MonkeyTerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    this.forceSgr = false,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  /// Whether to send SGR wheel reports even if xterm has not observed mouse
  /// reporting mode yet.
  final bool forceSgr;

  final Widget child;

  @override
  State<MonkeyTerminalScrollGestureHandler> createState() =>
      _MonkeyTerminalScrollGestureHandlerState();
}

class _MonkeyTerminalScrollGestureHandlerState
    extends State<MonkeyTerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  late MouseMode mouseMode;
  late MouseReportMode mouseReportMode;

  late final _accumulator = TerminalScrollAccumulator(
    terminal: () => widget.terminal,
    getLineHeight: () => widget.getLineHeight(),
    sendScrollEvent: ({required up}) => _sendScrollEvent(up),
  );
  TerminalWheelScrollCalibrator get _wheelCalibrator => _accumulator.calibrator;

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event.
  var lastPointerPosition = Offset.zero;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    mouseMode = widget.terminal.mouseMode;
    mouseReportMode = widget.terminal.mouseReportMode;
    super.initState();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalUpdated);
    _accumulator.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MonkeyTerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      mouseMode = widget.terminal.mouseMode;
      mouseReportMode = widget.terminal.mouseReportMode;
      _resetScrollTracking(forgetEstimate: true);
    } else if (oldWidget.simulateScroll != widget.simulateScroll ||
        oldWidget.forceSgr != widget.forceSgr) {
      _accumulator.resetRemainder();
    }
    super.didUpdateWidget(oldWidget);
  }

  void _onTerminalUpdated() {
    final nextIsAltBuffer = widget.terminal.isUsingAltBuffer;
    final nextMouseMode = widget.terminal.mouseMode;
    final nextMouseReportMode = widget.terminal.mouseReportMode;
    final bufferChanged = isAltBuffer != nextIsAltBuffer;
    final mouseTransportChanged =
        mouseMode != nextMouseMode || mouseReportMode != nextMouseReportMode;

    isAltBuffer = nextIsAltBuffer;
    mouseMode = nextMouseMode;
    mouseReportMode = nextMouseReportMode;

    if (bufferChanged) {
      _resetScrollTracking();
      setState(() {});
    } else if (mouseTransportChanged) {
      _accumulator.resetRemainder();
    } else if (_wheelCalibrator.observingTerminalOutput) {
      _wheelCalibrator.terminalChanged(
        captureTerminalViewportLines(widget.terminal),
      );
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  bool _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);
    final button = up
        ? TerminalMouseButton.wheelUp
        : TerminalMouseButton.wheelDown;

    final handled = sendTerminalScrollMouseInput(
      terminal: widget.terminal,
      button: button,
      position: position,
      forceSgr: widget.forceSgr,
    );

    if (!handled && widget.simulateScroll) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
    return handled;
  }

  void _resetScrollTracking({bool forgetEstimate = false}) {
    _accumulator.reset(forgetEstimate: forgetEstimate);
  }

  void _onScroll(double offset) => _accumulator.onScroll(offset);

  void _rememberPointerPosition(Offset position) {
    lastPointerPosition = position;
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer) {
      return widget.child;
    }

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _wheelCalibrator.beginGesture();
        }
        _rememberPointerPosition(event.localPosition);
      },
      onPointerHover: (event) => _rememberPointerPosition(event.localPosition),
      onPointerMove: (event) => _rememberPointerPosition(event.localPosition),
      onPointerDown: (event) => _rememberPointerPosition(event.localPosition),
      onPointerPanZoomStart: (event) {
        _wheelCalibrator.beginGesture();
        _rememberPointerPosition(event.localPosition);
      },
      onPointerPanZoomUpdate: (event) =>
          _rememberPointerPosition(event.localPosition + event.pan),
      child: InfiniteScrollView(onScroll: _onScroll, child: widget.child),
    );
  }
}

/// Accumulates scroll distance and calibrates terminal wheel row granularity.
class TerminalScrollAccumulator {
  TerminalScrollAccumulator({
    required this.terminal,
    required this.getLineHeight,
    required this.sendScrollEvent,
  });
  final Terminal Function() terminal;
  final double Function() getLineHeight;
  final bool Function({required bool up}) sendScrollEvent;
  final _wheelCalibrator = TerminalWheelScrollCalibrator();
  TerminalWheelScrollCalibrator get calibrator => _wheelCalibrator;

  /// Tracks the last offset reported by InfiniteScrollView.
  double lastScrollOffset = 0;

  /// Partial distance, including reversals, awaiting a full calibrated step.
  double scrollRemainder = 0;
  bool _disposed = false;

  void reset({bool forgetEstimate = false}) {
    lastScrollOffset = 0;
    resetRemainder(forgetEstimate: forgetEstimate);
  }

  void resetRemainder({bool forgetEstimate = false}) {
    scrollRemainder = 0;
    _wheelCalibrator.reset(forgetEstimate: forgetEstimate);
  }

  void dispose() {
    _disposed = true;
    _wheelCalibrator.dispose();
  }

  void onScroll(double offset) {
    final lineHeight = getLineHeight();
    if (lineHeight <= 0) {
      return;
    }

    scrollRemainder += offset - lastScrollOffset;
    lastScrollOffset = offset;
    _drain(lineHeight);
  }

  void _drain(double lineHeight) {
    if (_wheelCalibrator.waitingForResponse) {
      return;
    }
    var stepHeight = lineHeight * _wheelCalibrator.rowsPerEvent;
    while (scrollRemainder.abs() >= stepHeight) {
      final scrollUp = scrollRemainder < 0;
      final scrollDirection = scrollUp ? -1 : 1;
      final calibrationStarted =
          _wheelCalibrator.needsMeasurement &&
          _wheelCalibrator.begin(
            before: captureTerminalViewportLines(terminal()),
            onSettled: (previousRows, rows) {
              if (_disposed) {
                return;
              }
              scrollRemainder -=
                  scrollDirection * lineHeight * (rows - previousRows);
              _drain(lineHeight);
            },
          );
      final handled = sendScrollEvent(up: scrollUp);
      if (!handled && calibrationStarted) {
        _wheelCalibrator.cancelPending();
      }
      scrollRemainder -= scrollDirection * stepHeight;
      if (calibrationStarted && handled) {
        break;
      }
      stepHeight = lineHeight * _wheelCalibrator.rowsPerEvent;
    }
  }
}
