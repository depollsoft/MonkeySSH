// ignore_for_file: implementation_imports, public_member_api_docs

import 'dart:async';
import 'dart:math' as math;

import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';

/// Maximum screen displacement attributed to one terminal wheel report.
const _maximumMeasuredWheelRows = 6;

/// Captures the visible terminal text used to measure an application's
/// response to one wheel report. Text, rather than styling, is compared so a
/// moving selection or cursor does not look like viewport movement.
List<String> captureTerminalViewportLines(Terminal terminal) {
  final lines = terminal.buffer.lines;
  final firstLine = math.max(0, lines.length - terminal.viewHeight);
  return <String>[
    for (var row = firstLine; row < lines.length; row++) _lineText(lines[row]),
  ];
}

String _lineText(BufferLine line) {
  final length = line.getTrimmedLength();
  if (length == 0) {
    return '';
  }
  return String.fromCharCodes(<int>[
    for (var column = 0; column < length; column++)
      _normalizedCodePoint(line, column),
  ]).trimRight();
}

int _normalizedCodePoint(BufferLine line, int column) {
  final codePoint = line.getCodePoint(column);
  return codePoint == 0 ? 0x20 : codePoint;
}

bool _isMeaningfulLine(String line) => line.trim().isNotEmpty;

/// Infers how many rows an application moved in response to one wheel report.
///
/// Terminal mouse protocols report only a direction, not a pixel or row
/// distance. Applications commonly choose either one or three rows. Matching
/// unique rows before and after the report lets the client normalize that
/// choice without identifying or special-casing the application.
int? resolveTerminalWheelRowsPerEvent({
  required List<String> before,
  required List<String> after,
  int maximumRows = _maximumMeasuredWheelRows,
}) {
  if (before.length < 2 || after.length != before.length || maximumRows < 1) {
    return null;
  }

  final beforeCounts = <String, int>{};
  final afterCounts = <String, int>{};
  for (final line in before.where(_isMeaningfulLine)) {
    beforeCounts.update(line, (count) => count + 1, ifAbsent: () => 1);
  }
  for (final line in after.where(_isMeaningfulLine)) {
    afterCounts.update(line, (count) => count + 1, ifAbsent: () => 1);
  }

  var bestRows = 0;
  var bestScore = 0;
  var tied = false;
  final maxShift = math.min(maximumRows, before.length - 1);
  for (var shift = -maxShift; shift <= maxShift; shift++) {
    if (shift == 0) {
      continue;
    }
    var score = 0;
    for (var beforeRow = 0; beforeRow < before.length; beforeRow++) {
      final afterRow = beforeRow + shift;
      if (afterRow < 0 || afterRow >= after.length) {
        continue;
      }
      final line = before[beforeRow];
      if (!_isMeaningfulLine(line) ||
          beforeCounts[line] != 1 ||
          afterCounts[line] != 1) {
        continue;
      }
      if (after[afterRow] == line) {
        score += 1;
      }
    }

    if (score > bestScore) {
      bestScore = score;
      bestRows = shift.abs();
      tied = false;
    } else if (score == bestScore && score > 0 && shift.abs() != bestRows) {
      tied = true;
    }
  }

  return bestScore >= 2 && !tied ? bestRows : null;
}

typedef TerminalWheelCalibrationSettled = void Function(
  int previousRowsPerEvent,
  int rowsPerEvent,
);

/// Learns wheel-report row granularity from the next terminal response.
class TerminalWheelScrollCalibrator {
  TerminalWheelScrollCalibrator({
    this.responseSettleDelay = const Duration(milliseconds: 60),
    this.responseTimeout = const Duration(milliseconds: 300),
  });

  final Duration responseSettleDelay;
  final Duration responseTimeout;

  int _rowsPerEvent = 1;
  bool _isCalibrated = false;
  bool _retryMeasurementOnNextGesture = true;
  bool _isQuarantined = false;
  List<String>? _before;
  List<String>? _latestAfter;
  TerminalWheelCalibrationSettled? _onSettled;
  Timer? _settleTimer;
  Timer? _timeoutTimer;
  Timer? _quarantineTimer;

  int get rowsPerEvent => _rowsPerEvent;

  bool get waitingForResponse => _before != null;

  bool get observingTerminalOutput => waitingForResponse || _isQuarantined;

  bool get needsMeasurement =>
      !_isCalibrated && !waitingForResponse && !_isQuarantined;

  /// Reuses a measured estimate, but retries a timeout fallback on this
  /// gesture once delayed output is no longer quarantined.
  void beginGesture() {
    if (!waitingForResponse &&
        !_isQuarantined &&
        _retryMeasurementOnNextGesture) {
      _isCalibrated = false;
      _retryMeasurementOnNextGesture = false;
    }
  }

  /// Keeps the current estimate but forces the next wheel event to measure it.
  void invalidate() {
    _cancelPending(notify: false);
    if (!_isQuarantined) {
      _isCalibrated = false;
    }
  }

  /// Revalidates the current estimate after the input transport changes. A
  /// measured gain is retained as the safe fallback unless the terminal
  /// instance itself was replaced.
  void reset({bool forgetEstimate = false}) {
    _endQuarantine();
    if (forgetEstimate) {
      _rowsPerEvent = 1;
    }
    _isCalibrated = false;
    _retryMeasurementOnNextGesture = true;
    _cancelPending(notify: false);
  }

  /// Starts measuring one wheel report. Returns true when the caller should
  /// wait for the response before emitting another report.
  bool begin({
    required List<String> before,
    required TerminalWheelCalibrationSettled onSettled,
  }) {
    if (_isCalibrated ||
        waitingForResponse ||
        _isQuarantined ||
        !_canMeasure(before)) {
      return false;
    }
    _before = before;
    _onSettled = onSettled;
    _timeoutTimer = Timer(responseTimeout, _finishAtDeadline);
    return true;
  }

  /// Supplies the latest parsed screen after terminal output arrives.
  void terminalChanged(List<String> after) {
    if (_isQuarantined) {
      _quarantineTimer?.cancel();
      _quarantineTimer = Timer(responseSettleDelay, _endQuarantine);
      return;
    }
    if (!waitingForResponse) {
      return;
    }
    _latestAfter = after;
    _settleTimer?.cancel();
    _settleTimer = Timer(responseSettleDelay, _finishObservedResponse);
  }

  /// Cancels a measurement when the input fell back to keyboard scrolling.
  void cancelPending() {
    _isCalibrated = true;
    _retryMeasurementOnNextGesture = false;
    _cancelPending(notify: false);
  }

  void dispose() {
    _endQuarantine();
    _cancelPending(notify: false);
  }

  bool _canMeasure(List<String> lines) =>
      lines.where(_isMeaningfulLine).toSet().length >= 2;

  void _finishObservedResponse() {
    _settleTimer = null;
    if (!waitingForResponse || _latestAfter == null) {
      return;
    }
    final measuredRows = resolveTerminalWheelRowsPerEvent(
      before: _before!,
      after: _latestAfter!,
    );
    if (measuredRows == null) {
      return;
    }
    _settle(rowsPerEvent: measuredRows);
  }

  void _finishAtDeadline() {
    if (!waitingForResponse) {
      return;
    }
    final latestAfter = _latestAfter;
    final measuredRows = latestAfter == null
        ? null
        : resolveTerminalWheelRowsPerEvent(
            before: _before!,
            after: latestAfter,
          );
    if (measuredRows == null) {
      _startQuarantine();
    }
    _settle(rowsPerEvent: measuredRows);
  }

  void _settle({required int? rowsPerEvent}) {
    final previousRows = _rowsPerEvent;
    if (rowsPerEvent != null) {
      _rowsPerEvent = rowsPerEvent;
    }
    _isCalibrated = true;
    _retryMeasurementOnNextGesture = rowsPerEvent == null;
    final onSettled = _onSettled;
    _cancelPending(notify: false);
    onSettled?.call(previousRows, _rowsPerEvent);
  }

  void _startQuarantine() {
    _isCalibrated = true;
    _isQuarantined = true;
    _quarantineTimer?.cancel();
    _quarantineTimer = Timer(
      Duration(microseconds: responseTimeout.inMicroseconds * 3),
      _endQuarantine,
    );
  }

  void _endQuarantine() {
    _quarantineTimer?.cancel();
    _quarantineTimer = null;
    _isQuarantined = false;
  }

  void _cancelPending({required bool notify}) {
    _settleTimer?.cancel();
    _timeoutTimer?.cancel();
    _settleTimer = null;
    _timeoutTimer = null;
    _before = null;
    _latestAfter = null;
    final onSettled = _onSettled;
    _onSettled = null;
    if (notify) {
      onSettled?.call(_rowsPerEvent, _rowsPerEvent);
    }
  }
}
