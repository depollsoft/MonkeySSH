import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/known_hosts_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../models/acp_native_preview.dart';
import '../models/acp_session_keys.dart';
import '../models/port_proxy_name.dart';
import '../models/remote_multiplexer.dart';
import '../models/terminal_preview.dart';
import '../models/terminal_progress.dart';
import '../models/terminal_theme.dart';
import 'app_review_demo_service.dart';
import 'background_ssh_service.dart';
import 'clipboard_sharing_service.dart';
import 'diagnostics_log_service.dart';
import 'host_key_prompt_handler_provider.dart';
import 'host_key_verification.dart';
import 'interactive_auth_prompt.dart';
import 'local_notification_service.dart';
import 'openssh_key_generator.dart';
import 'port_forward_browser_service.dart';
import 'settings_service.dart';
import 'ssh_error_policy.dart';
import 'ssh_exec_queue.dart';
import 'telemetry_service.dart';
import 'terminal_command_mark_tracker.dart';
import 'terminal_hyperlink_tracker.dart';
import 'terminal_iterm2_control.dart';
import 'terminal_iterm2_image.dart';
import 'terminal_notification.dart';
import 'terminal_osc_color_overrides.dart';
import 'terminal_preview_graphics.dart';
import 'wifi_network_service.dart';
import 'windows_remote_powershell.dart';

part 'ssh_session_runtime.dart';

/// Current terminal dimensions used to answer terminal size queries.
typedef TerminalWindowMetrics = ({
  int columns,
  int rows,
  int pixelWidth,
  int pixelHeight,
});

/// Terminal mode state used to answer DECRQM mode-status queries.
typedef TerminalControlModeState = ({
  bool reportFocusMode,
  bool bracketedPasteMode,
  bool colorSchemeUpdatesMode,
  bool isUsingAltBuffer,
  bool mouseTrackingMode,
  bool mouseDragTrackingMode,
  bool mouseMoveTrackingMode,
  bool sgrMouseReportMode,
});

/// Incrementally unwraps tmux DCS passthroughs, including doubled ESC bytes.
class TerminalTmuxPassthroughDecoder {
  int _prefixLength = 0;
  StringBuffer? _payload;
  bool _escaped = false;

  /// Discards an incomplete sequence when the shell is reset.
  void reset() {
    _prefixLength = 0;
    _payload = null;
    _escaped = false;
  }

  /// Decodes a chunk, retaining incomplete passthroughs until their terminator.
  String add(String input) {
    final output = StringBuffer();
    var cursor = 0;
    while (cursor < input.length) {
      final payload = _payload;
      if (payload != null) {
        if (_escaped) {
          final code = input.codeUnitAt(cursor++);
          _escaped = false;
          if (code == _terminalStringTerminatorCodeUnit) {
            output.write(payload);
            _payload = null;
          } else {
            payload.write(_terminalEscape);
            if (code != _terminalEscapeCodeUnit) payload.writeCharCode(code);
          }
        } else {
          final escape = input.indexOf(_terminalEscape, cursor);
          final end = escape < 0 ? input.length : escape;
          payload.write(input.substring(cursor, end));
          _escaped = escape >= 0;
          cursor = end + (_escaped ? 1 : 0);
        }
      } else if (_prefixLength > 0) {
        if (input.codeUnitAt(cursor) ==
            _terminalTmuxPassthroughStart.codeUnitAt(_prefixLength)) {
          cursor++;
          if (++_prefixLength == _terminalTmuxPassthroughStart.length) {
            _prefixLength = 0;
            _payload = StringBuffer();
          }
        } else {
          output.write(
            _terminalTmuxPassthroughStart.substring(0, _prefixLength),
          );
          _prefixLength = 0;
        }
      } else {
        final escape = input.indexOf(_terminalEscape, cursor);
        final end = escape < 0 ? input.length : escape;
        output.write(input.substring(cursor, end));
        _prefixLength = escape < 0 ? 0 : 1;
        cursor = end + _prefixLength;
      }
    }
    return output.toString();
  }
}

/// Builds responses for terminal window/cell size and theme reports in shell
/// output.
///
/// [pendingInput] should be the pending suffix returned by the previous call,
/// so split CSI sequences can be recognized across UTF-8 stream chunks.
({String? response, String pendingInput})
buildTerminalWindowControlQueryResponses({
  required String input,
  required String pendingInput,
  required TerminalWindowMetrics? metrics,
  TerminalControlModeState? modeState,
  TerminalThemeData? theme,
}) {
  final combinedInput = pendingInput + input;
  final responses = StringBuffer();

  for (final match in _terminalWindowQueryPattern.allMatches(combinedInput)) {
    final params = match.group(1) ?? '';
    final primaryParam = params.split(';').first;
    final response = _buildTerminalWindowQueryResponse(primaryParam, metrics);
    if (response != null) {
      responses.write(response);
    }
  }

  for (final match in _terminalModeReportQueryPattern.allMatches(
    combinedInput,
  )) {
    final params = match.group(1)?.split(';') ?? const <String>[];
    for (final param in params) {
      final mode = int.tryParse(param);
      if (mode == null) {
        continue;
      }
      final response = _buildTerminalModeReportResponse(mode, modeState);
      if (response != null) {
        responses.write(response);
      }
    }
  }

  if (theme != null && _terminalThemeModeQueryPattern.hasMatch(combinedInput)) {
    responses.write(buildTerminalThemeModeReport(isDark: theme.isDark));
  }

  final response = responses.isEmpty ? null : responses.toString();
  return (
    response: response,
    pendingInput: _terminalControlQueryPendingSuffix(combinedInput),
  );
}

/// Extracts terminal control mode changes from shell output.
///
/// Some TUIs enable DEC private mode 2031 to request a report when the
/// terminal switches between light and dark color schemes. Windows ConPTY
/// requests DEC private mode 9001 (win32-input-mode) when a session starts.
/// xterm.dart does not currently model either mode, so MonkeySSH tracks them
/// while scanning the same shell output used for other terminal control
/// queries.
({bool? colorSchemeUpdatesMode, bool? win32InputMode, String pendingInput})
extractTerminalControlModeUpdates({
  required String input,
  required String pendingInput,
}) {
  final combinedInput = pendingInput + input;
  bool? colorSchemeUpdatesMode;
  bool? win32InputMode;

  for (final match in _terminalPrivateModeSetResetPattern.allMatches(
    combinedInput,
  )) {
    final params = match.group(1)?.split(';') ?? const <String>[];
    final isSet = match.group(2) == 'h';
    if (params.contains('2031')) {
      colorSchemeUpdatesMode = isSet;
    }
    if (params.contains('9001')) {
      win32InputMode = isSet;
    }
  }

  return (
    colorSchemeUpdatesMode: colorSchemeUpdatesMode,
    win32InputMode: win32InputMode,
    pendingInput: _terminalControlQueryPendingSuffix(combinedInput),
  );
}

/// Re-encodes OSC and DCS responses so they survive a Windows ConPTY.
///
/// Windows ConPTY (conhost, used by Win32-OpenSSH) requests win32-input-mode
/// (`CSI ? 9001 h`) when a session starts. Its input-side parser strips raw
/// OSC and DCS sequences arriving on the input stream, so replies to terminal
/// color queries never reach the remote app. Wrapping each code unit of those
/// sequences as a win32-input-mode key event (`CSI Vk;Sc;Uc;Kd;Cs;Rc _`) makes
/// ConPTY decode them back to the original bytes for the foreground app. CSI
/// responses and regular keyboard input already pass through unmodified, so
/// only OSC/DCS sequences are re-encoded.
String encodeTerminalResponsesForWin32InputMode(String data) {
  if (!data.contains('\x1b]') && !data.contains('\x1bP')) {
    return data;
  }
  final output = StringBuffer();
  var cursor = 0;
  for (final match in _terminalOscOrDcsSequencePattern.allMatches(data)) {
    output.write(data.substring(cursor, match.start));
    _writeWin32InputModeKeyEvents(output, match.group(0)!);
    cursor = match.end;
  }
  output.write(data.substring(cursor));
  return output.toString();
}

void _writeWin32InputModeKeyEvents(StringBuffer output, String sequence) {
  for (final codeUnit in sequence.codeUnits) {
    // CSI Vk;Sc;Uc;Kd;Cs;Rc _ with only the Unicode char, key-down, and
    // repeat-count fields set, mirroring how Windows Terminal forwards
    // characters that have no associated virtual key.
    output
      ..write('\x1b[0;0;')
      ..write(codeUnit)
      ..write(';1;0;1_');
  }
}

/// Win32-input-mode key-down and key-up events for the Escape key.
///
/// `CSI Vk;Sc;Uc;Kd;Cs;Rc _` with `VK_ESCAPE` (27), the Escape scan code (1)
/// and U+001B, matching what Windows Terminal sends for a physical Escape.
const terminalWin32InputModeEscapeKeyEvents =
    '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_';

/// Re-encodes a standalone Escape keystroke so a Windows ConPTY delivers it.
///
/// ConPTY's input-side parser cannot tell a bare `ESC` from the first byte of
/// an escape sequence, so it holds the byte back until enough input arrives to
/// disambiguate it. A lone Escape keypress therefore reaches the foreground app
/// only once the *next* key is pressed, which reads as "Escape stopped
/// working": TUIs never leave their mode, and Ctrl+C (an unambiguous control
/// byte) is the only way out.
///
/// Sending Escape as an explicit win32-input-mode key event instead of the raw
/// byte removes the ambiguity, so conhost dispatches it immediately. Only a
/// payload that is exactly `ESC` is rewritten; escape sequences (arrow keys,
/// `Alt`+key, query replies) are already unambiguous and pass through
/// unmodified.
String encodeTerminalInputForWin32InputMode(String data) =>
    data == '\x1b' ? terminalWin32InputModeEscapeKeyEvents : data;

/// Normalizes terminal-generated output before it is sent to the remote shell.
///
/// xterm.dart currently emits cursor-position reports using its internal
/// zero-based cursor coordinates. The terminal DSR wire protocol is one-based,
/// and TUIs such as Codex can stall or mis-detect terminal state after receiving
/// `CSI 0;0 R`.
String normalizeTerminalOutputForRemoteShell(String data) =>
    data.replaceAllMapped(_terminalCursorPositionReportPattern, (match) {
      final row = int.parse(match.group(1)!);
      final column = int.parse(match.group(2)!);
      return '\x1b[${row + 1};${column + 1}R';
    });

/// Adapts remote terminal output so xterm.dart renders it correctly.
///
/// xterm.dart 4.0.0 tracks IRM (`CSI 4 h/l`) but does not shift existing cells
/// when printable characters arrive while the mode is active. Injecting ICH
/// before each printable cell preserves behavior from editors such as nano,
/// while the decoder retains split escape sequences until complete.
///
/// xterm.dart 4.0.0 also corrupts its line buffer when RI (`ESC M`) scrolls a
/// vertical margin region down. When cursor state is provided, that RI is
/// rewritten to IL (`CSI L`), which has the same effect at the top margin
/// without reusing detached buffer lines internally.
///
/// xterm.dart also treats private `CSI > ... m` keyboard modifier controls as
/// SGR attributes. Dropping those controls prevents TUIs such as OpenCode from
/// accidentally enabling underline/bold while painting spaces.
class TerminalXtermOutputDecoder {
  final _sequence = StringBuffer();
  _TerminalSequenceState? _state;
  bool _previousEscape = false;
  String _pendingSurrogate = '';
  bool _insertMode = false;

  /// Number of code units retained until a sequence or surrogate completes.
  int get pendingCodeUnits => _sequence.length + _pendingSurrogate.length;

  /// Counts sequence code units materialized for the renderer.
  @visibleForTesting
  int materializedSequenceCodeUnits = 0;

  /// Discards partial output and resets insert mode for a new shell.
  void reset() {
    _sequence.clear();
    _state = null;
    _previousEscape = false;
    _pendingSurrogate = '';
    _insertMode = false;
    materializedSequenceCodeUnits = 0;
  }

  /// Adapts the next chunk using the renderer's current cursor state.
  ({String output, bool insertMode}) add({
    required String input,
    int? terminalColumns,
    int? terminalRows,
    int? cursorColumn,
    int? cursorRow,
    int? marginTop,
    int? marginBottom,
    bool originMode = false,
  }) {
    final combinedInput = _pendingSurrogate.isEmpty
        ? input
        : _pendingSurrogate + input;
    _pendingSurrogate = '';
    final output = StringBuffer();
    var cursor = 0;
    final cursorTracker = _TerminalOutputCursorTracker(
      columns: terminalColumns,
      rows: terminalRows,
      cursorColumn: cursorColumn,
      cursorRow: cursorRow,
      marginTop: marginTop,
      marginBottom: marginBottom,
      originMode: originMode,
    );
    while (cursor < combinedInput.length) {
      if (_state != null) {
        final start = cursor;
        while (cursor < combinedInput.length && _state != null) {
          _scanSequenceCodeUnit(combinedInput.codeUnitAt(cursor++));
        }
        _sequence.write(combinedInput.substring(start, cursor));
        if (_state != null) break;
        final sequence = _sequence.toString();
        materializedSequenceCodeUnits += sequence.length;
        _sequence.clear();
        if (!_shouldDropTerminalOutputSequenceForXterm(sequence)) {
          output.write(cursorTracker.adaptEscapeSequence(sequence));
          _insertMode = _terminalInsertModeUpdate(sequence) ?? _insertMode;
        }
        continue;
      }
      final codeUnit = combinedInput.codeUnitAt(cursor);
      if (codeUnit == _terminalEscapeCodeUnit) {
        _sequence.write(_terminalEscape);
        _state = _TerminalSequenceState.escape;
        cursor++;
        continue;
      }
      if (cursor == combinedInput.length - 1 &&
          codeUnit >= 0xD800 &&
          codeUnit <= 0xDBFF) {
        _pendingSurrogate = combinedInput.substring(cursor);
        break;
      }
      final rune = _terminalRuneAt(combinedInput, cursor);
      final runeLength = _terminalRuneLength(rune);
      if (_insertMode && _isTerminalGraphicRune(rune)) {
        for (var cell = 0; cell < _terminalCellWidth(rune); cell++) {
          output.write(_terminalInsertBlankCharacterSequence);
        }
      }
      output.write(combinedInput.substring(cursor, cursor + runeLength));
      cursorTracker.writeRune(rune);
      cursor += runeLength;
    }
    return (output: output.toString(), insertMode: _insertMode);
  }

  void _scanSequenceCodeUnit(int codeUnit) {
    switch (_state!) {
      case _TerminalSequenceState.escape:
        switch (codeUnit) {
          case _terminalCsiIntroducerCodeUnit:
            _state = _TerminalSequenceState.csi;
          case _terminalDcsIntroducerCodeUnit:
          case _terminalOscIntroducerCodeUnit:
          case _terminalSosIntroducerCodeUnit:
          case _terminalPmIntroducerCodeUnit:
          case _terminalApcIntroducerCodeUnit:
            _state = _TerminalSequenceState.string;
            _previousEscape = false;
          default:
            _state = _isTerminalEscapeIntermediate(codeUnit)
                ? _TerminalSequenceState.intermediate
                : null;
        }
      case _TerminalSequenceState.csi:
        if (codeUnit >= 0x40 && codeUnit <= 0x7E) _state = null;
      case _TerminalSequenceState.string:
        if (codeUnit == _terminalBellCodeUnit ||
            (_previousEscape &&
                codeUnit == _terminalStringTerminatorCodeUnit)) {
          _state = null;
        }
        _previousEscape = codeUnit == _terminalEscapeCodeUnit;
      case _TerminalSequenceState.intermediate:
        if (!_isTerminalEscapeIntermediate(codeUnit)) _state = null;
    }
  }
}

enum _TerminalSequenceState { escape, csi, string, intermediate }

class _TerminalOutputCursorTracker {
  _TerminalOutputCursorTracker({
    required int? columns,
    required int? rows,
    required int? cursorColumn,
    required int? cursorRow,
    required int? marginTop,
    required int? marginBottom,
    required bool originMode,
  }) : _columns = columns != null && columns > 0 ? columns : null,
       _rows = rows != null && rows > 0 ? rows : null,
       _originMode = originMode {
    final validRows = _rows;
    final validColumns = _columns;
    if (validRows == null ||
        validColumns == null ||
        cursorColumn == null ||
        cursorRow == null) {
      return;
    }

    _cursorColumn = cursorColumn.clamp(0, validColumns);
    _cursorRow = cursorRow.clamp(0, validRows - 1);
    _marginTop = (marginTop ?? 0).clamp(0, validRows - 1);
    _marginBottom = (marginBottom ?? validRows - 1).clamp(0, validRows - 1);
    if (_marginTop! > _marginBottom!) {
      final top = _marginTop!;
      _marginTop = _marginBottom;
      _marginBottom = top;
    }
  }

  final int? _columns;
  final int? _rows;
  int? _cursorColumn;
  int? _cursorRow;
  int? _marginTop;
  int? _marginBottom;
  bool _originMode;

  bool get _hasPosition =>
      _columns != null &&
      _rows != null &&
      _cursorColumn != null &&
      _cursorRow != null &&
      _marginTop != null &&
      _marginBottom != null;

  String adaptEscapeSequence(String sequence) {
    if (sequence == _terminalReverseIndexSequence) {
      return _adaptReverseIndex();
    }

    _applyEscapeSequence(sequence);
    return sequence;
  }

  void writeRune(int rune) {
    if (!_hasPosition) {
      return;
    }

    switch (rune) {
      case _terminalBackspaceCodeUnit:
        _cursorColumn = math.max(_cursorColumn! - 1, 0);
      case _terminalHorizontalTabCodeUnit:
        _cursorColumn = math.min(((_cursorColumn! ~/ 8) + 1) * 8, _columns!);
      case _terminalLineFeedCodeUnit:
      case _terminalVerticalTabCodeUnit:
      case _terminalFormFeedCodeUnit:
        _lineFeed();
      case _terminalCarriageReturnCodeUnit:
        _cursorColumn = 0;
      default:
        final width = _terminalCellWidth(rune);
        if (width <= 0) {
          return;
        }
        final columns = _columns!;
        if (_cursorColumn! >= columns) {
          _lineFeed();
          _cursorColumn = 0;
        }
        _cursorColumn = math.min(_cursorColumn! + width, columns);
    }
  }

  String _adaptReverseIndex() {
    if (!_hasPosition) {
      return _terminalReverseIndexSequence;
    }

    if (_cursorRow == _marginTop) {
      final restoreColumn = _cursorColumn!;
      return restoreColumn == 0
          ? _terminalInsertLineSequence
          : '$_terminalInsertLineSequence\x1b[${restoreColumn + 1}G';
    }

    _cursorRow = math.max(_cursorRow! - 1, 0);
    return _terminalReverseIndexSequence;
  }

  void _applyEscapeSequence(String sequence) {
    if (!_hasPosition || sequence.length < 2) {
      return;
    }

    if (sequence.length == 2 &&
        sequence.codeUnitAt(1) == _terminalFullResetFinalCodeUnit) {
      _resetCursorState();
      return;
    }

    if (sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
      return;
    }

    final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
    final params = _terminalCsiNumericParams(sequence);
    final originModeUpdate = _terminalDecOriginModeUpdate(sequence);
    if (originModeUpdate != null) {
      _originMode = originModeUpdate;
      return;
    }

    switch (finalCodeUnit) {
      case _terminalCursorUpFinalCodeUnit:
        _moveCursorRows(-_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorDownFinalCodeUnit:
        _moveCursorRows(_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorForwardFinalCodeUnit:
        _moveCursorColumns(_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorBackFinalCodeUnit:
        _moveCursorColumns(-_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorNextLineFinalCodeUnit:
        _moveCursorRows(_terminalCsiParam(params, 0, defaultValue: 1));
        _cursorColumn = 0;
      case _terminalCursorPreviousLineFinalCodeUnit:
        _moveCursorRows(-_terminalCsiParam(params, 0, defaultValue: 1));
        _cursorColumn = 0;
      case _terminalCursorHorizontalAbsoluteFinalCodeUnit:
        _setCursorColumn(_terminalCsiParam(params, 0, defaultValue: 1) - 1);
      case _terminalCursorPositionFinalCodeUnit:
      case _terminalHorizontalVerticalPositionFinalCodeUnit:
        _setCursor(
          row: _terminalCsiParam(params, 0, defaultValue: 1) - 1,
          column: _terminalCsiParam(params, 1, defaultValue: 1) - 1,
        );
      case _terminalLinePositionAbsoluteFinalCodeUnit:
        _setCursorRow(_terminalCsiParam(params, 0, defaultValue: 1) - 1);
      case _terminalSetMarginsFinalCodeUnit:
        _setMargins(params);
      case _terminalInsertLinesFinalCodeUnit:
      case _terminalDeleteLinesFinalCodeUnit:
        _cursorColumn = 0;
    }
  }

  void _lineFeed() {
    final row = _cursorRow!;
    final marginTop = _marginTop!;
    final marginBottom = _marginBottom!;
    final inMargins = row >= marginTop && row <= marginBottom;
    if (inMargins && row == marginBottom) {
      return;
    }
    if (!inMargins && row >= _rows! - 1) {
      return;
    }
    _cursorRow = math.min(row + 1, _rows! - 1);
  }

  void _moveCursorRows(int offset) {
    _setCursorRow(_cursorRow! + offset);
  }

  void _moveCursorColumns(int offset) {
    _setCursorColumn(_cursorColumn! + offset);
  }

  void _setCursor({required int row, required int column}) {
    if (_originMode) {
      _cursorRow = (row + _marginTop!).clamp(0, _marginBottom!);
    } else {
      _setCursorRow(row);
    }
    _setCursorColumn(column);
  }

  void _setCursorRow(int row) {
    _cursorRow = row.clamp(0, _rows! - 1);
  }

  void _setCursorColumn(int column) {
    _cursorColumn = column.clamp(0, _columns! - 1);
  }

  void _setMargins(List<int?> params) {
    if (params.length > 2) {
      return;
    }

    final rows = _rows!;
    final top = _terminalCsiParam(params, 0, defaultValue: 1) - 1;
    final bottom = params.length >= 2 && params[1] != null && params[1] != 0
        ? params[1]! - 1
        : rows - 1;
    _marginTop = top.clamp(0, rows - 1);
    _marginBottom = bottom.clamp(0, rows - 1);
    if (_marginTop! > _marginBottom!) {
      final topMargin = _marginTop!;
      _marginTop = _marginBottom;
      _marginBottom = topMargin;
    }
  }

  void _resetCursorState() {
    _cursorColumn = 0;
    _cursorRow = 0;
    _marginTop = 0;
    _marginBottom = _rows! - 1;
    _originMode = false;
  }
}

final _terminalWindowQueryPattern = RegExp(r'\x1b\[([0-9;?]*)t');
final _terminalModeReportQueryPattern = RegExp(r'\x1b\[\?([0-9;]+)\$p');
final _terminalThemeModeQueryPattern = RegExp(r'\x1b\[\?996n');
final _terminalControlQueryPrefixPattern = RegExp(r'^\x1b(?:$|\[[0-9;?\$]*)$');
final _terminalPrivateModeSetResetPattern = RegExp(r'\x1b\[\?([0-9;]+)([hl])');
final _terminalOscOrDcsSequencePattern = RegExp(
  r'\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|P[^\x1b]*\x1b\\)',
);
final _terminalCursorPositionReportPattern = RegExp(
  r'\x1b\[([0-9]+);([0-9]+)R',
);
final _terminalCsiNumericParamsPattern = RegExp(r'^[0-9;]*$');

String? _buildTerminalWindowQueryResponse(
  String primaryParam,
  TerminalWindowMetrics? metrics,
) {
  if (!_hasValidTerminalWindowMetrics(metrics)) {
    return null;
  }

  final validMetrics = metrics!;
  switch (primaryParam) {
    case '14':
      return '\x1b[4;${validMetrics.pixelHeight};${validMetrics.pixelWidth}t';
    case '16':
      final cellWidth = (validMetrics.pixelWidth / validMetrics.columns)
          .round();
      final cellHeight = (validMetrics.pixelHeight / validMetrics.rows).round();
      if (cellWidth < 1 || cellHeight < 1) {
        return null;
      }
      return '\x1b[6;$cellHeight;${cellWidth}t';
    default:
      return null;
  }
}

String? _buildTerminalModeReportResponse(
  int mode,
  TerminalControlModeState? modeState,
) {
  if (modeState == null) {
    return switch (mode) {
      1016 ||
      2026 ||
      2027 ||
      2031 => _formatTerminalModeReport(mode, _terminalModeNotRecognized),
      _ => null,
    };
  }

  return switch (mode) {
    1000 => _formatTerminalModeReport(
      mode,
      modeState.mouseTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1002 => _formatTerminalModeReport(
      mode,
      modeState.mouseDragTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1003 => _formatTerminalModeReport(
      mode,
      modeState.mouseMoveTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1004 => _formatTerminalModeReport(
      mode,
      modeState.reportFocusMode ? _terminalModeSet : _terminalModeReset,
    ),
    1006 => _formatTerminalModeReport(
      mode,
      modeState.sgrMouseReportMode ? _terminalModeSet : _terminalModeReset,
    ),
    1049 => _formatTerminalModeReport(
      mode,
      modeState.isUsingAltBuffer ? _terminalModeSet : _terminalModeReset,
    ),
    2004 => _formatTerminalModeReport(
      mode,
      modeState.bracketedPasteMode ? _terminalModeSet : _terminalModeReset,
    ),
    2031 => _formatTerminalModeReport(
      mode,
      modeState.colorSchemeUpdatesMode ? _terminalModeSet : _terminalModeReset,
    ),
    1016 ||
    2026 ||
    2027 => _formatTerminalModeReport(mode, _terminalModeNotRecognized),
    _ => null,
  };
}

const _terminalModeNotRecognized = 0;
const _terminalModeSet = 1;
const _terminalModeReset = 2;

const _terminalEscape = '\x1b';
const _terminalEscapeCodeUnit = 0x1B;
const _terminalBellCodeUnit = 0x07;
const _terminalBackspaceCodeUnit = 0x08;
const _terminalHorizontalTabCodeUnit = 0x09;
const _terminalLineFeedCodeUnit = 0x0A;
const _terminalVerticalTabCodeUnit = 0x0B;
const _terminalFormFeedCodeUnit = 0x0C;
const _terminalCarriageReturnCodeUnit = 0x0D;
const _terminalCsiIntroducerCodeUnit = 0x5B;
const _terminalDcsIntroducerCodeUnit = 0x50;
const _terminalOscIntroducerCodeUnit = 0x5D;
const _terminalSosIntroducerCodeUnit = 0x58;
const _terminalPmIntroducerCodeUnit = 0x5E;
const _terminalApcIntroducerCodeUnit = 0x5F;
const _terminalStringTerminatorCodeUnit = 0x5C;
const _terminalDeleteCodeUnit = 0x7F;
const _terminalCursorUpFinalCodeUnit = 0x41;
const _terminalCursorDownFinalCodeUnit = 0x42;
const _terminalCursorForwardFinalCodeUnit = 0x43;
const _terminalCursorBackFinalCodeUnit = 0x44;
const _terminalCursorNextLineFinalCodeUnit = 0x45;
const _terminalCursorPreviousLineFinalCodeUnit = 0x46;
const _terminalCursorHorizontalAbsoluteFinalCodeUnit = 0x47;
const _terminalCursorPositionFinalCodeUnit = 0x48;
const _terminalInsertLinesFinalCodeUnit = 0x4C;
const _terminalDeleteLinesFinalCodeUnit = 0x4D;
const _terminalHorizontalVerticalPositionFinalCodeUnit = 0x66;
const _terminalLinePositionAbsoluteFinalCodeUnit = 0x64;
const _terminalSetMarginsFinalCodeUnit = 0x72;
const _terminalInsertMode = 4;
const _terminalOriginMode = 6;
const _terminalSetModeFinalCodeUnit = 0x68;
const _terminalResetModeFinalCodeUnit = 0x6C;
const _terminalSoftResetFinalCodeUnit = 0x70;
const _terminalFullResetFinalCodeUnit = 0x63;
const _terminalPrivateMarkerCodeUnit = 0x3E;
const _terminalSelectGraphicRenditionFinalCodeUnit = 0x6D;
const _terminalInsertBlankCharacterSequence = '\x1b[@';
const _terminalReverseIndexSequence = '\x1bM';
const _terminalInsertLineSequence = '\x1b[L';
const _terminalTmuxPassthroughStart = '${_terminalEscape}Ptmux;';

String _formatTerminalModeReport(int mode, int status) =>
    '\x1b[?$mode;$status\$y';

bool _isTerminalEscapeIntermediate(int codeUnit) =>
    codeUnit >= 0x20 && codeUnit <= 0x2F;

bool? _terminalInsertModeUpdate(String sequence) {
  if (sequence.length < 2 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit) {
    return null;
  }
  if (sequence.length == 2 &&
      sequence.codeUnitAt(1) == _terminalFullResetFinalCodeUnit) {
    return false;
  }
  if (sequence.length < 4 ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return null;
  }

  final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
  final params = sequence.substring(2, sequence.length - 1);
  if (finalCodeUnit == _terminalSoftResetFinalCodeUnit &&
      (params == '!' || params.endsWith('"'))) {
    return false;
  }
  if (finalCodeUnit != _terminalSetModeFinalCodeUnit &&
      finalCodeUnit != _terminalResetModeFinalCodeUnit) {
    return null;
  }

  if (params.startsWith('?')) {
    return null;
  }
  for (final param in params.split(';')) {
    if (int.tryParse(param) == _terminalInsertMode) {
      return finalCodeUnit == _terminalSetModeFinalCodeUnit;
    }
  }
  return null;
}

bool? _terminalDecOriginModeUpdate(String sequence) {
  if (sequence.length < 5 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return null;
  }

  final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
  if (finalCodeUnit != _terminalSetModeFinalCodeUnit &&
      finalCodeUnit != _terminalResetModeFinalCodeUnit) {
    return null;
  }

  final params = sequence.substring(2, sequence.length - 1);
  if (!params.startsWith('?')) {
    return null;
  }

  for (final param in params.substring(1).split(';')) {
    if (int.tryParse(param) == _terminalOriginMode) {
      return finalCodeUnit == _terminalSetModeFinalCodeUnit;
    }
  }
  return null;
}

bool _shouldDropTerminalOutputSequenceForXterm(String sequence) {
  if (sequence.length < 4 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit ||
      sequence.codeUnitAt(2) != _terminalPrivateMarkerCodeUnit ||
      sequence.codeUnitAt(sequence.length - 1) !=
          _terminalSelectGraphicRenditionFinalCodeUnit) {
    return false;
  }

  final params = sequence.substring(3, sequence.length - 1);
  return _terminalCsiNumericParamsPattern.hasMatch(params);
}

List<int?> _terminalCsiNumericParams(String sequence) {
  if (sequence.length < 3 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return const [];
  }

  final params = sequence.substring(2, sequence.length - 1);
  if (params.isEmpty) {
    return const [];
  }
  if (!_terminalCsiNumericParamsPattern.hasMatch(params)) {
    return const [];
  }
  return params
      .split(';')
      .map((param) => param.isEmpty ? null : int.tryParse(param))
      .toList();
}

int _terminalCsiParam(
  List<int?> params,
  int index, {
  required int defaultValue,
}) {
  if (index >= params.length || params[index] == null || params[index] == 0) {
    return defaultValue;
  }
  return params[index]!;
}

int _terminalRuneAt(String input, int index) {
  final first = input.codeUnitAt(index);
  if (_isTerminalHighSurrogate(first) && index + 1 < input.length) {
    final second = input.codeUnitAt(index + 1);
    if (_isTerminalLowSurrogate(second)) {
      return 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00;
    }
  }
  return first;
}

int _terminalRuneLength(int rune) => rune > 0xFFFF ? 2 : 1;

bool _isTerminalHighSurrogate(int codeUnit) =>
    codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isTerminalLowSurrogate(int codeUnit) =>
    codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

bool _isTerminalGraphicRune(int rune) =>
    rune >= 0x20 &&
    rune != _terminalDeleteCodeUnit &&
    !(rune >= 0x80 && rune <= 0x9F);

int _terminalCellWidth(int rune) {
  if (!_isTerminalGraphicRune(rune) || _isTerminalZeroWidthRune(rune)) {
    return 0;
  }
  if (_isTerminalWideRune(rune)) {
    return 2;
  }
  return 1;
}

bool _isTerminalZeroWidthRune(int rune) =>
    rune == 0x200D ||
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0xFE20 && rune <= 0xFE2F) ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0100 && rune <= 0xE01EF);

bool _isTerminalWideRune(int rune) =>
    rune >= 0x1100 &&
    (rune <= 0x115F ||
        rune == 0x2329 ||
        rune == 0x232A ||
        (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE10 && rune <= 0xFE19) ||
        (rune >= 0xFE30 && rune <= 0xFE6F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6) ||
        (rune >= 0x1F300 && rune <= 0x1FAFF) ||
        (rune >= 0x20000 && rune <= 0x3FFFD));

bool _hasValidTerminalWindowMetrics(TerminalWindowMetrics? metrics) =>
    metrics != null &&
    metrics.columns > 0 &&
    metrics.rows > 0 &&
    metrics.pixelWidth > 0 &&
    metrics.pixelHeight > 0;

String _terminalControlQueryPendingSuffix(String input) {
  // Retain a trailing partial control query so it can be completed by the next
  // slice. Scan back far enough to cover the longest supported query (a
  // multi-parameter mode report can exceed a short window); slicing terminal
  // output more finely makes such a split more reachable.
  const maxPendingQueryLength = 64;
  final windowStart = input.length > maxPendingQueryLength
      ? input.length - maxPendingQueryLength
      : 0;
  for (var index = input.length - 1; index >= windowStart; index -= 1) {
    if (input.codeUnitAt(index) != _terminalEscapeCodeUnit) {
      continue;
    }
    final suffix = input.substring(index);
    return _terminalControlQueryPrefixPattern.hasMatch(suffix) ? suffix : '';
  }
  return '';
}

/// Connection state for an SSH session.
enum SshConnectionState {
  /// Not connected.
  disconnected,

  /// Connecting to host.
  connecting,

  /// Authenticating with host.
  authenticating,

  /// Connected and authenticated.
  connected,

  /// Connection error occurred.
  error,

  /// Reconnecting after disconnect.
  reconnecting,
}

/// Shell integration state reported through terminal metadata sequences.
enum TerminalShellStatus {
  /// The shell is displaying a prompt and ready for the next command.
  prompt,

  /// The user is composing or editing the current command line.
  editingCommand,

  /// A submitted command is currently running.
  runningCommand,
}

/// Parses an OSC 7 working-directory URI from private terminal metadata.
Uri? parseTerminalWorkingDirectoryUri(List<String> args) {
  if (args.isEmpty) {
    return null;
  }

  final candidate = args.join(';').trim();
  if (candidate.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme) {
    return null;
  }

  return uri;
}

/// Parses working-directory metadata used by OSC 9;9, OSC 633, and OSC 1337.
///
/// These protocols commonly send a native path instead of OSC 7's file URI.
/// Absolute POSIX and Windows paths are normalized to file URIs so downstream
/// session discovery can use one representation on every platform.
Uri? parseTerminalWorkingDirectoryValue(String value, {String? remoteHost}) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 4096) {
    return null;
  }

  final uri = Uri.tryParse(candidate);
  if (uri != null && uri.hasScheme && uri.scheme.toLowerCase() == 'file') {
    return uri;
  }

  final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(candidate);
  if (!candidate.startsWith('/') && !isWindowsPath) {
    return null;
  }
  final pathUri = Uri.file(candidate, windows: isWindowsPath);
  final host = remoteHost?.trim() ?? '';
  if (host.isEmpty) {
    return pathUri;
  }
  return pathUri.replace(host: host);
}

/// Extracts working-directory metadata from supported shell OSC extensions.
Uri? parseTerminalShellWorkingDirectoryOsc(
  String code,
  List<String> args, {
  String? remoteHost,
}) {
  String? value;
  if (code == '9' && args.firstOrNull?.trim() == '9' && args.length > 1) {
    value = args.skip(1).join(';');
  } else if (code == '633' && args.firstOrNull == 'P') {
    final propertyIndex = args.indexWhere((arg) => arg.startsWith('Cwd='));
    if (propertyIndex >= 0) {
      value = args[propertyIndex].substring('Cwd='.length);
    }
  } else if (code == '1337' &&
      (args.firstOrNull?.startsWith('CurrentDir=') ?? false)) {
    value = [
      args.first.substring('CurrentDir='.length),
      ...args.skip(1),
    ].join(';');
  }
  return value == null
      ? null
      : parseTerminalWorkingDirectoryValue(value, remoteHost: remoteHost);
}

/// Extracts the hostname from iTerm2's `OSC 1337;RemoteHost=user@host`.
String? parseTerminalReportedRemoteHost(List<String> args) {
  if (args.isEmpty || !args.first.startsWith('RemoteHost=')) {
    return null;
  }
  final candidate = [
    args.first.substring('RemoteHost='.length),
    ...args.skip(1),
  ].join(';').trim();
  if (candidate.isEmpty || candidate.length > 1024) {
    return null;
  }
  final uri = Uri.tryParse('ssh://$candidate');
  final host = uri?.host.trim() ?? '';
  return host.isEmpty ? null : host;
}

/// Resolves the decoded directory path from a terminal working-directory URI.
String? resolveTerminalWorkingDirectoryPath(Uri? workingDirectory) {
  if (workingDirectory == null) {
    return null;
  }

  final decodedPath = () {
    try {
      return Uri.decodeComponent(workingDirectory.path).trim();
    } on FormatException {
      return workingDirectory.path.trim();
    }
  }();
  if (decodedPath.isNotEmpty) {
    return decodedPath;
  }

  final fallback = workingDirectory.toString().trim();
  return fallback.isEmpty ? null : fallback;
}

/// Formats a terminal working-directory URI for compact UI display.
String? formatTerminalWorkingDirectoryLabel(Uri? workingDirectory) {
  final path = resolveTerminalWorkingDirectoryPath(workingDirectory);
  if (path == null) {
    return null;
  }

  final host = workingDirectory?.host.trim() ?? '';
  return host.isEmpty ? path : '$host:$path';
}

/// Applies an OSC 133 shell integration update to the current shell state.
({TerminalShellStatus? status, int? lastExitCode})
applyTerminalShellIntegrationOsc(
  List<String> args, {
  required TerminalShellStatus? previousStatus,
  required int? previousExitCode,
}) {
  if (args.isEmpty) {
    return (status: previousStatus, lastExitCode: previousExitCode);
  }

  switch (args.first) {
    case 'A':
      return (
        status: TerminalShellStatus.prompt,
        lastExitCode: previousExitCode,
      );
    case 'B':
      return (status: TerminalShellStatus.editingCommand, lastExitCode: null);
    case 'C':
      return (status: TerminalShellStatus.runningCommand, lastExitCode: null);
    case 'D':
      return (
        status: TerminalShellStatus.prompt,
        lastExitCode: args.length > 1
            ? int.tryParse(args[1]) ?? previousExitCode
            : previousExitCode,
      );
    default:
      return (status: previousStatus, lastExitCode: previousExitCode);
  }
}

/// Formats a shell integration state for compact UI display.
String? describeTerminalShellStatus(
  TerminalShellStatus? status, {
  int? lastExitCode,
}) {
  final exitLabel = lastExitCode != null && lastExitCode != 0
      ? 'Exit $lastExitCode'
      : null;

  switch (status) {
    case TerminalShellStatus.prompt:
      return exitLabel ?? 'Prompt';
    case TerminalShellStatus.editingCommand:
      return 'Editing command';
    case TerminalShellStatus.runningCommand:
      return 'Running command';
    case null:
      return exitLabel;
  }
}

/// Configuration for an SSH connection.
class SshConnectionConfig {
  /// Creates a new [SshConnectionConfig].
  const SshConnectionConfig({
    required this.hostname,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
    this.identityKeys,
    this.jumpHost,
    this.keepAliveInterval = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 30),
  });

  /// Creates config from a Host entity.
  factory SshConnectionConfig.fromHost(
    Host host, {
    SshKey? key,
    List<SshKey>? identityKeys,
    SshConnectionConfig? jumpHostConfig,
  }) => SshConnectionConfig(
    hostname: host.hostname,
    port: host.port,
    username: host.username,
    password: host.password,
    privateKey: key?.privateKey,
    passphrase: key?.passphrase,
    identityKeys: identityKeys,
    jumpHost: jumpHostConfig,
  );

  /// Hostname or IP address.
  final String hostname;

  /// SSH port.
  final int port;

  /// Username for authentication.
  final String username;

  /// Password for authentication (if using password auth).
  final String? password;

  /// Private key content (if using key auth).
  final String? privateKey;

  /// Passphrase for private key (if encrypted).
  final String? passphrase;

  /// Candidate keys to try automatically, ordered by key ID.
  final List<SshKey>? identityKeys;

  /// Jump host configuration for proxy connections.
  final SshConnectionConfig? jumpHost;

  /// Keep-alive interval.
  final Duration keepAliveInterval;

  /// Connection timeout.
  final Duration connectionTimeout;
}

/// Result of an SSH connection attempt.
class SshConnectionResult {
  /// Creates a new [SshConnectionResult].
  const SshConnectionResult({
    required this.success,
    this.error,
    this.client,
    this.connectionId,
    this.reusedConnection = false,
    this.cancelled = false,
    this.dependentClients = const <SSHClient>[],
  });

  /// A result describing a connection attempt the user cancelled.
  const SshConnectionResult.userCancelled({this.error = 'Connection cancelled'})
    : success = false,
      client = null,
      connectionId = null,
      reusedConnection = false,
      cancelled = true,
      dependentClients = const <SSHClient>[];

  /// Whether connection was successful.
  final bool success;

  /// Whether the attempt stopped because the user cancelled it.
  final bool cancelled;

  /// Error message if connection failed.
  final String? error;

  /// The SSH client if connected.
  final SSHClient? client;

  /// The active connection ID when a session is available.
  final int? connectionId;

  /// Whether an existing connection was reused.
  final bool reusedConnection;

  /// Additional SSH clients that must be closed with [client].
  final List<SSHClient> dependentClients;

  /// Closes [client] and any dependent jump-host clients.
  Future<void> closeAll() => _closeSshClients(client, dependentClients);
}

Future<void> _closeSshClients(
  SSHClient? client,
  List<SSHClient> dependentClients,
) async {
  Future<void> closeClient(SSHClient client) async {
    try {
      await client.close();
    } on SSHStateError catch (error, stackTrace) {
      if (!isExpectedSshChannelTeardownError(error, stackTrace)) rethrow;
      DiagnosticsLogService.instance.debug(
        'ssh.session',
        'client_already_disconnected',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  try {
    if (client != null) await closeClient(client);
  } finally {
    await Future.wait(dependentClients.map(closeClient));
  }
}

/// Thrown when an in-flight SSH connection attempt is cancelled by the user.
class SshConnectionCancelledException implements Exception {
  /// Creates an [SshConnectionCancelledException].
  const SshConnectionCancelledException([
    this.message = 'Connection cancelled',
  ]);

  /// Human-readable description of the cancellation.
  final String message;

  @override
  String toString() => message;
}

/// Cooperative cancellation signal for a single SSH connection attempt.
///
/// A token is single-use: once [cancel] is called it stays cancelled. Long
/// waits inside [SshService.connect] race against [cancelled] so a stalled
/// attempt can be abandoned immediately instead of waiting for its timeout.
class SshConnectionCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes as soon as cancellation is requested.
  Future<void> get cancelled => _cancelled.future;

  /// Requests cancellation of the associated connection attempt.
  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  /// Throws [SshConnectionCancelledException] when already cancelled.
  void throwIfCancelled() {
    if (isCancelled) {
      throw const SshConnectionCancelledException();
    }
  }

  /// Completes with [operation] unless cancellation happens first.
  ///
  /// When cancellation wins the race the returned future fails with
  /// [SshConnectionCancelledException] and [onAbandonedValue] is invoked with
  /// the late result (if any) so orphaned sockets and clients can be closed.
  Future<T> guard<T>(
    Future<T> operation, {
    void Function(T value)? onAbandonedValue,
  }) {
    void abandon(T value) {
      if (onAbandonedValue == null) {
        return;
      }
      try {
        onAbandonedValue(value);
      } on Object catch (error) {
        if (error is! Exception && error is! SSHError) rethrow;
        DiagnosticsLogService.instance.debug(
          'ssh.connect',
          'cancel_cleanup_failed',
          fields: {'errorType': error.runtimeType},
        );
      }
    }

    if (isCancelled) {
      unawaited(operation.then(abandon, onError: (Object _, StackTrace _) {}));
      return Future<T>.error(
        const SshConnectionCancelledException(),
        StackTrace.current,
      );
    }

    final completer = Completer<T>();
    operation.then(
      (value) {
        if (completer.isCompleted) {
          abandon(value);
          return;
        }
        completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    unawaited(
      cancelled.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const SshConnectionCancelledException(),
            StackTrace.current,
          );
        }
      }),
    );
    return completer.future;
  }
}

/// Progress callback for long-running SSH connection attempts.
typedef ConnectionProgressCallback =
    void Function(ConnectionProgressUpdate update);

/// Connects a raw SSH socket for the requested host.
typedef SshSocketConnector =
    Future<SSHSocket> Function(String host, int port, {Duration? timeout});

/// Creates an [SSHClient] for a prepared socket.
typedef SshClientFactory =
    SSHClient Function(
      SSHSocket socket, {
      required String username,
      SSHHostkeyVerifyHandler? onVerifyHostKey,
      SSHPasswordRequestHandler? onPasswordRequest,
      SSHUserInfoRequestHandler? onUserInfoRequest,
      List<SSHKeyPair>? identities,
      Duration? keepAliveInterval,
    });

/// Exposes the raw SSH host key bytes observed during the handshake.
abstract interface class HostKeySource {
  /// Completes with the raw SSH wire-format host key.
  Future<Uint8List> get hostKeyBytes;
}

/// Captures a host key from fragmented SSH handshake chunks using the real
/// socket wrapper and parser path.
@visibleForTesting
Future<Uint8List> captureHostKeyFromHandshakeChunksForTesting(
  Iterable<Uint8List> chunks,
) async {
  final capturingSocket = _HostKeyCapturingSocket(
    _FiniteChunkSshSocket(chunks),
  );
  unawaited(capturingSocket.stream.drain<void>());
  return capturingSocket.hostKeyBytes;
}

/// A single progress update emitted while an SSH connection is being created.
class ConnectionProgressUpdate {
  /// Creates a [ConnectionProgressUpdate].
  const ConnectionProgressUpdate({required this.state, required this.message});

  /// The current connection phase.
  final SshConnectionState state;

  /// Human-readable status text for the current phase.
  final String message;
}

/// Host-level connection attempt state for live progress UI.
class ConnectionAttemptStatus {
  /// Creates a [ConnectionAttemptStatus].
  const ConnectionAttemptStatus({
    required this.hostId,
    required this.state,
    required this.latestMessage,
    required this.logLines,
    this.cancelRequested = false,
    this.cancelled = false,
  });

  /// The host currently being connected.
  final int hostId;

  /// The latest known connection state.
  final SshConnectionState state;

  /// The newest status message shown to the user.
  final String latestMessage;

  /// Rolling log of recent connection progress messages.
  final List<String> logLines;

  /// Whether the user asked to abandon this attempt.
  final bool cancelRequested;

  /// Whether the attempt finished because the user cancelled it.
  final bool cancelled;

  /// Whether a cancellation request is still being wound down.
  bool get isCancelling => cancelRequested && !cancelled && isInProgress;

  /// Whether the connection attempt is still actively progressing.
  bool get isInProgress =>
      state == SshConnectionState.connecting ||
      state == SshConnectionState.authenticating ||
      state == SshConnectionState.reconnecting;
}

/// Resolved password / keyboard-interactive handlers for a connection.
class _InteractiveAuthHandlers {
  const _InteractiveAuthHandlers({
    this.onPasswordRequest,
    this.onUserInfoRequest,
  });

  final SSHPasswordRequestHandler? onPasswordRequest;
  final SSHUserInfoRequestHandler? onUserInfoRequest;
}

/// Tracks whether an interactive authentication prompt is currently open so
/// the authentication timeout can pause while the user types.
class _InteractiveAuthGate {
  int _activePrompts = 0;

  /// Invoked whenever a prompt opens or closes.
  void Function()? onActivityChanged;

  /// Whether at least one interactive prompt is currently awaiting input.
  bool get isPrompting => _activePrompts > 0;

  /// Runs [action] while marking a prompt as active for its duration.
  Future<T> guard<T>(Future<T> Function() action) async {
    _activePrompts++;
    onActivityChanged?.call();
    try {
      return await action();
    } finally {
      _activePrompts--;
      onActivityChanged?.call();
    }
  }
}

/// Service for managing SSH connections.
class SshService {
  /// Creates a new [SshService].
  SshService({
    this.hostRepository,
    this.keyRepository,
    this.knownHostsRepository,
    this.hostKeyPromptHandler,
    this.interactiveAuthPromptHandler,
    WifiNetworkService? wifiNetworkService,
    SshSocketConnector? socketConnector,
    SshClientFactory? clientFactory,
  }) : wifiNetworkService = wifiNetworkService ?? WifiNetworkService(),
       _socketConnector = socketConnector ?? _connectWithKeepAlive,
       _clientFactory = clientFactory ?? _defaultClientFactory;

  /// Number of key identities to try per SSH authentication attempt.
  ///
  /// Keeping this below common server `MaxAuthTries` defaults avoids
  /// "too many authentication failures" disconnects in Auto mode.
  static const _maxAutoKeysPerAttempt = 5;
  static const _hostKeyProbeSettleTimeout = Duration(seconds: 1);

  /// Host repository for looking up hosts.
  final HostRepository? hostRepository;

  /// Key repository for looking up keys.
  final KeyRepository? keyRepository;

  /// Repository for trusted SSH host keys.
  final KnownHostsRepository? knownHostsRepository;

  /// UI callback used for TOFU and changed-key prompts.
  final HostKeyPromptHandler? hostKeyPromptHandler;

  /// UI callback used to collect passwords / keyboard-interactive responses
  /// when the server issues a challenge and no stored credential answers it.
  final InteractiveAuthPromptHandler? interactiveAuthPromptHandler;

  /// Service used to read the current Wi-Fi SSID for jump host bypass.
  final WifiNetworkService wifiNetworkService;

  final SshSocketConnector _socketConnector;
  final SshClientFactory _clientFactory;

  final Map<int, SshSession> _sessions = {};
  int _nextConnectionId = 1;

  /// Get all active sessions.
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  /// All active session instances.
  Iterable<SshSession> get allSessions => _sessions.values;

  /// Connect to a host by ID.
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    var preflightPhase = 'start';
    DiagnosticsLogService.instance.info(
      'ssh.connect',
      'connect_to_host_start',
      fields: {'hostId': hostId},
    );
    try {
      cancellationToken?.throwIfCancelled();
      if (hostRepository == null) {
        DiagnosticsLogService.instance.warning(
          'ssh.connect',
          'connect_to_host_unavailable',
          fields: {'hostId': hostId, 'reason': 'missing_host_repository'},
        );
        return const SshConnectionResult(
          success: false,
          error: 'Host repository not available',
        );
      }

      preflightPhase = 'load_host';
      final host = await hostRepository!.getById(hostId);
      if (host == null) {
        DiagnosticsLogService.instance.warning(
          'ssh.connect',
          'connect_to_host_missing_host',
          fields: {'hostId': hostId},
        );
        return const SshConnectionResult(
          success: false,
          error: 'Host not found',
        );
      }
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_to_host_loaded_host',
        fields: {
          'hostId': hostId,
          'hasPassword': host.password != null,
          'hasKeyId': host.keyId != null,
          'hasJumpHost': host.jumpHostId != null,
        },
      );

      if (isAppReviewDemoHost(host)) {
        return _connectToAppReviewDemoHost(
          host,
          useHostThemeOverrides: useHostThemeOverrides,
          onProgress: onProgress,
          cancellationToken: cancellationToken,
        );
      }

      List<SshKey>? cachedAutoKeys;
      var didLoadAutoKeys = false;
      Future<List<SshKey>?> loadAutoKeys() async {
        if (didLoadAutoKeys) {
          return cachedAutoKeys;
        }
        didLoadAutoKeys = true;
        if (keyRepository == null) {
          return null;
        }
        preflightPhase = 'load_auto_keys';
        final keyLoadResult = await keyRepository!.getAllDecryptable();
        if (keyLoadResult.unreadableCount > 0) {
          DiagnosticsLogService.instance.warning(
            'ssh.connect',
            'auto_key_load_skipped_unreadable',
            fields: {
              'hostId': hostId,
              'unreadableCount': keyLoadResult.unreadableCount,
              'loadedCount': keyLoadResult.keys.length,
              'errorType': keyLoadResult.firstUnreadableErrorType,
            },
          );
        }
        final keys = keyLoadResult.keys
            .where(
              (key) =>
                  !keyRepository!.hasUnreadablePrivateKey(key.id) &&
                  !keyRepository!.hasUnreadablePassphrase(key.id),
            )
            .toList();
        if (keys.isEmpty) {
          return null;
        }
        final sortedKeys = [...keys]..sort((a, b) => a.id.compareTo(b.id));
        final autoKeys = sortedKeys.length > _maxAutoKeysPerAttempt
            ? sortedKeys.take(_maxAutoKeysPerAttempt).toList(growable: false)
            : sortedKeys;
        return cachedAutoKeys = autoKeys;
      }

      // Get SSH key if explicitly selected, otherwise use auto keys.
      SshKey? key;
      List<SshKey>? identityKeys;
      if (host.keyId != null && keyRepository != null) {
        preflightPhase = 'load_host_key';
        key = await keyRepository!.getById(host.keyId!);
        if (keyRepository!.hasUnreadablePrivateKey(host.keyId!) ||
            keyRepository!.hasUnreadablePassphrase(host.keyId!)) {
          throw const FormatException('Unreadable SSH key secret');
        }
        if (key == null && host.password == null) {
          identityKeys = await loadAutoKeys();
        }
      } else if (host.password == null) {
        identityKeys = await loadAutoKeys();
      }

      // Get jump host config if specified, unless the device is currently
      // connected to a Wi-Fi network on the host's skip list (in which case
      // the host is reachable directly).
      SshConnectionConfig? jumpHostConfig;
      if (host.jumpHostId != null) {
        var skipJumpHost = false;
        if (host.skipJumpHostOnSsids != null &&
            host.skipJumpHostOnSsids!.isNotEmpty) {
          onProgress?.call(
            const ConnectionProgressUpdate(
              state: SshConnectionState.connecting,
              message: 'Checking Wi-Fi network for jump host bypass…',
            ),
          );
          preflightPhase = 'check_wifi_bypass';
          final permission = await wifiNetworkService.requestPermission();
          String? currentSsid;
          if (permission == WifiPermissionStatus.granted) {
            currentSsid = await wifiNetworkService.getCurrentSsid();
            skipJumpHost = shouldSkipJumpHostForSsid(
              currentSsid: currentSsid,
              skipJumpHostOnSsids: host.skipJumpHostOnSsids,
            );
          } else {
            onProgress?.call(
              const ConnectionProgressUpdate(
                state: SshConnectionState.connecting,
                message: 'Wi-Fi permission denied. Using jump host…',
              ),
            );
          }
          DiagnosticsLogService.instance.info(
            'ssh.connect',
            'jump_host_ssid_check',
            fields: {
              'hostId': hostId,
              'permissionStatus': permission.name,
              'hasCurrentSsid': currentSsid != null,
              'skipJumpHost': skipJumpHost,
            },
          );
        }
        if (!skipJumpHost) {
          preflightPhase = 'load_jump_host';
          final jumpHost = await hostRepository!.getById(host.jumpHostId!);
          if (jumpHost != null) {
            SshKey? jumpKey;
            List<SshKey>? jumpIdentityKeys;
            if (jumpHost.keyId != null && keyRepository != null) {
              preflightPhase = 'load_jump_host_key';
              jumpKey = await keyRepository!.getById(jumpHost.keyId!);
              if (keyRepository!.hasUnreadablePrivateKey(jumpHost.keyId!) ||
                  keyRepository!.hasUnreadablePassphrase(jumpHost.keyId!)) {
                throw const FormatException('Unreadable SSH key secret');
              }
              if (jumpKey == null && jumpHost.password == null) {
                jumpIdentityKeys = await loadAutoKeys();
              }
            } else if (jumpHost.password == null) {
              jumpIdentityKeys = await loadAutoKeys();
            }
            jumpHostConfig = SshConnectionConfig.fromHost(
              jumpHost,
              key: jumpKey,
              identityKeys: jumpIdentityKeys,
            );
          }
        }
      }

      preflightPhase = 'build_config';
      final config = SshConnectionConfig.fromHost(
        host,
        key: key,
        identityKeys: identityKeys,
        jumpHostConfig: jumpHostConfig,
      );

      preflightPhase = 'connect';
      cancellationToken?.throwIfCancelled();
      final result = await connect(
        config,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );

      if (result.success && result.client != null) {
        if (cancellationToken?.isCancelled ?? false) {
          // The user cancelled while the handshake was completing; drop the
          // freshly established clients instead of registering a session.
          await result.closeAll();
          DiagnosticsLogService.instance.info(
            'ssh.connect',
            'connect_to_host_cancelled',
            fields: {'hostId': hostId, 'phase': 'post_connect'},
          );
          return const SshConnectionResult.userCancelled();
        }
        final connectionId = _nextConnectionId++;
        _sessions[connectionId] = SshSession(
          connectionId: connectionId,
          hostId: hostId,
          client: result.client!,
          config: config,
          dependentClients: result.dependentClients,
          terminalThemeLightId: useHostThemeOverrides
              ? host.terminalThemeLightId
              : null,
          terminalThemeDarkId: useHostThemeOverrides
              ? host.terminalThemeDarkId
              : null,
        );

        unawaited(_updateLastConnected(hostId));
        DiagnosticsLogService.instance.info(
          'ssh.connect',
          'connect_to_host_success',
          fields: {
            'hostId': hostId,
            'connectionId': connectionId,
            'usesJumpHost': config.jumpHost != null,
            'usesPassword': config.password != null,
            'identityCount': config.identityKeys?.length ?? 0,
          },
        );
        return SshConnectionResult(
          success: true,
          client: result.client,
          connectionId: connectionId,
          dependentClients: result.dependentClients,
        );
      }

      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_to_host_failed',
        fields: {
          'hostId': hostId,
          'errorType': _diagnosticSshResultErrorKind(result.error),
        },
      );
      return result;
    } on SshConnectionCancelledException {
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_to_host_cancelled',
        fields: {'hostId': hostId, 'phase': preflightPhase},
      );
      return const SshConnectionResult.userCancelled();
    } on Exception catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_to_host_preflight_failed',
        fields: {
          'hostId': hostId,
          'phase': preflightPhase,
          'errorType': e.runtimeType,
        },
      );
      return const SshConnectionResult(
        success: false,
        error:
            'Connection setup failed. Check saved credentials and try again.',
      );
    }
  }

  Future<void> _updateLastConnected(int hostId) async {
    try {
      await hostRepository?.updateLastConnected(hostId);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'last_connected_update_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
    }
  }

  Future<SshConnectionResult> _connectToAppReviewDemoHost(
    Host host, {
    required bool useHostThemeOverrides,
    ConnectionProgressCallback? onProgress,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Starting local App Review demo session…',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (cancellationToken?.isCancelled ?? false) {
      return const SshConnectionResult.userCancelled();
    }
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.authenticating,
        message: 'Preparing in-app demo shell…',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (cancellationToken?.isCancelled ?? false) {
      return const SshConnectionResult.userCancelled();
    }

    final config = SshConnectionConfig.fromHost(host);
    final client = _AppReviewDemoSshClient(host);
    final connectionId = _nextConnectionId++;
    _sessions[connectionId] = SshSession(
      connectionId: connectionId,
      hostId: host.id,
      client: client,
      config: config,
      terminalThemeLightId: useHostThemeOverrides
          ? host.terminalThemeLightId
          : null,
      terminalThemeDarkId: useHostThemeOverrides
          ? host.terminalThemeDarkId
          : null,
    );
    unawaited(_updateLastConnected(host.id));
    DiagnosticsLogService.instance.info(
      'ssh.connect',
      'app_review_demo_connected',
      fields: {'hostId': host.id, 'connectionId': connectionId},
    );
    return SshConnectionResult(
      success: true,
      client: client,
      connectionId: connectionId,
    );
  }

  /// Connect with a configuration.
  ///
  /// Pass a [cancellationToken] to allow the caller to abandon a stalled
  /// attempt; every long wait races the token so cancellation takes effect
  /// immediately instead of after [SshConnectionConfig.connectionTimeout].
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    SSHClient? client;
    SSHSocket? unownedSocket;
    var connected = false;
    final dependentClients = <SSHClient>[];
    SSHClient? jumpClient;
    void report(SshConnectionState state, String message) {
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'progress',
        fields: {'state': state, 'isJumpHost': isJumpHost},
      );
      onProgress?.call(
        ConnectionProgressUpdate(state: state, message: message),
      );
    }

    Future<T> guard<T>(
      Future<T> operation, {
      void Function(T value)? onAbandonedValue,
    }) =>
        cancellationToken?.guard(
          operation,
          onAbandonedValue: onAbandonedValue,
        ) ??
        operation;

    try {
      cancellationToken?.throwIfCancelled();
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_start',
        fields: {
          'isJumpHost': isJumpHost,
          'hasJumpHost': config.jumpHost != null,
          'usesPassword': config.password != null,
          'identityCount': config.identityKeys?.length ?? 0,
          'hasExplicitKey': config.privateKey != null,
          'keepAliveSeconds': config.keepAliveInterval.inSeconds,
          'timeoutSeconds': config.connectionTimeout.inSeconds,
        },
      );
      final verificationService = _createHostKeyVerificationService(config);
      final authGate = _InteractiveAuthGate();
      final authHandlers = _buildInteractiveAuthHandlers(config, authGate);

      final identities = await guard(_parseIdentities(config));
      cancellationToken?.throwIfCancelled();

      Future<void> authenticate(
        SSHSocket socket,
        SSHHostkeyVerifyHandler verify,
      ) async {
        unownedSocket = socket;
        report(
          SshConnectionState.authenticating,
          isJumpHost ? 'Authenticating with jump host…' : 'Authenticating…',
        );
        final createdClient = _clientFactory(
          socket,
          username: config.username,
          onVerifyHostKey: verify,
          onPasswordRequest: authHandlers.onPasswordRequest,
          onUserInfoRequest: authHandlers.onUserInfoRequest,
          identities: identities,
          keepAliveInterval: config.keepAliveInterval,
        );
        client = createdClient;
        unownedSocket = null;
        await _awaitAuthentication(
          createdClient,
          authGate,
          timeout: config.connectionTimeout,
          isJumpHost: isJumpHost,
          cancellationToken: cancellationToken,
        );
      }

      SSHHostkeyVerifyHandler verifyProbedKey(VerifiedHostKey key) =>
          (_, fingerprint) {
            if (!_probedHostKeyMatchesCallback(key, fingerprint)) {
              throw HostKeyVerificationException(
                'The host key for ${config.hostname}:${config.port} changed '
                'between verification and authentication.',
              );
            }
            return true;
          };

      // Handle jump host
      if (config.jumpHost != null) {
        report(SshConnectionState.connecting, 'Connecting to jump host…');
        final jumpResult = await connect(
          config.jumpHost!,
          onProgress: onProgress,
          isJumpHost: true,
          cancellationToken: cancellationToken,
        );
        if (!jumpResult.success || jumpResult.client == null) {
          if (jumpResult.cancelled) {
            throw const SshConnectionCancelledException();
          }
          return SshConnectionResult(
            success: false,
            error: 'Failed to connect to jump host: ${jumpResult.error}',
          );
        }
        dependentClients
          ..add(jumpResult.client!)
          ..addAll(jumpResult.dependentClients);
        jumpClient = jumpResult.client;
      }

      Future<SSHSocket> openEndpointSocket() {
        if (jumpClient != null) {
          // Create forwarded connection through jump host.
          // SSHForwardChannel implements SSHSocket.
          report(
            SshConnectionState.connecting,
            'Opening tunnel to destination…',
          );
          return guard(
            jumpClient.forwardLocal(config.hostname, config.port),
            onAbandonedValue: _closeAbandonedSocket,
          );
        }

        report(
          SshConnectionState.connecting,
          isJumpHost
              ? 'Opening jump host connection…'
              : 'Opening network connection…',
        );
        return guard(
          _socketConnector(
            config.hostname,
            config.port,
            timeout: config.connectionTimeout,
          ),
          onAbandonedValue: _closeAbandonedSocket,
        );
      }

      final knownHosts = knownHostsRepository!;
      final trustedHost = await guard(
        knownHosts.getByHost(config.hostname, config.port),
      );

      PendingHostTrustUpdate? pendingHostTrustUpdate;
      if (trustedHost == null) {
        report(
          SshConnectionState.connecting,
          isJumpHost ? 'Verifying jump host key…' : 'Verifying host key…',
        );
        final presentedHostKey = await _probeHostKey(
          await openEndpointSocket(),
          config: config,
          cancellationToken: cancellationToken,
        );
        pendingHostTrustUpdate = await guard(
          verificationService.verify(presentedHostKey),
        );
        await pendingHostTrustUpdate!.persistTrustDecision(knownHosts);
        await authenticate(
          await openEndpointSocket(),
          verifyProbedKey(presentedHostKey),
        );
      } else {
        unownedSocket = await openEndpointSocket();
        final preparedSocket = _prepareHostKeyCapture(unownedSocket!);
        String? callbackKeyType;
        String? rejectedCallbackFingerprint;
        var rejectedTrustedHostKey = false;
        try {
          await authenticate(preparedSocket.socket, (type, fingerprint) {
            callbackKeyType = type;
            final trusted = _trustedHostMatchesCallback(
              trustedHost,
              fingerprint,
            );
            rejectedTrustedHostKey = !trusted;
            if (!trusted) {
              rejectedCallbackFingerprint = _formatCallbackHostKeyFingerprint(
                fingerprint,
              );
            }
            return trusted;
          });
        } on SSHHostkeyError {
          if (!rejectedTrustedHostKey) rethrow;
          await client!.close();
          client = null;
          report(
            SshConnectionState.connecting,
            isJumpHost ? 'Verifying jump host key…' : 'Verifying host key…',
          );
          final changedHostKey = await _readPresentedHostKey(
            preparedSocket.hostKeySource,
            config: config,
            keyType: callbackKeyType,
            cancellationToken: cancellationToken,
          );
          _confirmCapturedHostKeyMatchesCallback(
            changedHostKey,
            rejectedCallbackFingerprint,
            config: config,
          );
          pendingHostTrustUpdate = await guard(
            verificationService.verify(changedHostKey),
          );
          await authenticate(
            await openEndpointSocket(),
            verifyProbedKey(changedHostKey),
          );
        }
      }

      report(
        SshConnectionState.connected,
        isJumpHost ? 'Jump host connected.' : 'SSH connection established.',
      );
      if (pendingHostTrustUpdate != null) {
        await pendingHostTrustUpdate.commitAfterAuthentication(knownHosts);
      } else {
        await knownHosts.markTrustedHostSeen(
          hostname: trustedHost!.hostname,
          port: trustedHost.port,
          keyType: trustedHost.keyType,
          fingerprint: trustedHost.fingerprint,
          encodedHostKey: trustedHost.hostKey,
        );
      }
      connected = true;

      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_success',
        fields: {
          'isJumpHost': isJumpHost,
          'trustedHostKnown': trustedHost != null,
        },
      );
      return SshConnectionResult(
        success: true,
        client: client,
        dependentClients: dependentClients,
      );
    } on SshConnectionCancelledException {
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_cancelled',
        fields: {'isJumpHost': isJumpHost},
      );
      return const SshConnectionResult.userCancelled();
    } on Object catch (e) {
      final error = switch (e) {
        HostKeyVerificationException(:final message) => message,
        FormatException(:final message) => message,
        SSHHostkeyError(:final message) =>
          'Host key verification failed: $message',
        SSHAuthFailError(:final message) => 'Authentication failed: $message',
        SSHChannelOpenError() =>
          'The SSH server refused the tunnel to the destination. Check forwarding permissions and the destination address.',
        SSHError() => 'The SSH connection failed. Reconnect to try again.',
        SocketException(:final message) => 'Connection failed: $message',
        TimeoutException(:final message) => message ?? 'Connection timed out',
        Exception() =>
          'Connection failed. Check the host settings and try again.',
        _ => null,
      };
      if (error == null) rethrow;
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      return SshConnectionResult(success: false, error: error);
    } finally {
      if (!connected) {
        try {
          unownedSocket?.destroy();
        } finally {
          await _closeSshClients(client, dependentClients);
        }
      }
    }
  }

  /// Builds the password / keyboard-interactive handlers for a connection.
  ///
  /// When the host has a stored password it is used directly (and also
  /// answers a simple keyboard-interactive password prompt). Otherwise, if an
  /// [interactiveAuthPromptHandler] is available, the user is prompted so a
  /// server-issued password challenge can be answered from the UI.
  _InteractiveAuthHandlers _buildInteractiveAuthHandlers(
    SshConnectionConfig config,
    _InteractiveAuthGate gate,
  ) {
    final staticPassword = config.password;
    final promptHandler = interactiveAuthPromptHandler;
    final hostLabel = '${config.username}@${config.hostname}:${config.port}';

    SSHPasswordRequestHandler? onPasswordRequest;
    if (staticPassword != null) {
      onPasswordRequest = () => staticPassword;
    } else if (promptHandler != null) {
      onPasswordRequest = () => gate.guard(() async {
        final responses = await promptHandler(
          SshAuthChallenge(
            hostLabel: hostLabel,
            username: config.username,
            name: '',
            instruction: '',
            prompts: const [SshAuthPrompt(prompt: 'Password:', echo: false)],
          ),
        );
        if (responses == null || responses.isEmpty) {
          return null;
        }
        return responses.first;
      });
    }

    SSHUserInfoRequestHandler? onUserInfoRequest;
    if (staticPassword != null || promptHandler != null) {
      onUserInfoRequest = (request) async {
        final prompts = request.prompts;
        // A keyboard-interactive info request may legitimately carry zero
        // prompts (e.g. an informational banner, RFC 4256). It must be
        // answered with an empty response list rather than prompting the user.
        if (prompts.isEmpty) {
          return const <String>[];
        }
        // Reuse the stored password only for a single hidden prompt that
        // clearly asks for a password, so OTP/2FA/password-change challenges
        // still reach the user instead of silently receiving the saved
        // password (which the server would reject, breaking the login).
        if (staticPassword != null &&
            prompts.length == 1 &&
            !prompts.first.echo &&
            _isPlainPasswordPrompt(
              request.name,
              request.instruction,
              prompts.first.promptText,
            )) {
          return <String>[staticPassword];
        }
        if (promptHandler == null) {
          return null;
        }
        return gate.guard(
          () => promptHandler(
            SshAuthChallenge(
              hostLabel: hostLabel,
              username: config.username,
              name: request.name,
              instruction: request.instruction,
              prompts: prompts
                  .map(
                    (prompt) => SshAuthPrompt(
                      prompt: prompt.promptText,
                      echo: prompt.echo,
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
      };
    }

    return _InteractiveAuthHandlers(
      onPasswordRequest: onPasswordRequest,
      onUserInfoRequest: onUserInfoRequest,
    );
  }

  /// Whether a single keyboard-interactive prompt is unambiguously asking for
  /// an account password (rather than an OTP/2FA code or a new password during
  /// a password change), so a stored password can be safely reused to answer
  /// it. Errs toward `false`: unknown prompts fall through to the user.
  static bool _isPlainPasswordPrompt(
    String name,
    String instruction,
    String promptText,
  ) {
    final prompt = promptText.toLowerCase();
    if (!prompt.contains('password') && !prompt.contains('passphrase')) {
      return false;
    }
    final haystack = '$name\n$instruction\n$promptText'.toLowerCase();
    const nonPasswordMarkers = <String>[
      'one-time',
      'one time',
      'otp',
      'passcode',
      'verification',
      'authenticator',
      'token',
      '2fa',
      'mfa',
      'second factor',
      'two-factor',
      'two factor',
      'duo',
      'yubikey',
      'totp',
      'hotp',
      'security key',
      'new password',
      'new passphrase',
      'retype',
      're-enter',
      'reenter',
      'confirm',
      'change',
    ];
    return !nonPasswordMarkers.any(haystack.contains);
  }

  /// Awaits SSH authentication with a timeout that pauses while the user is
  /// answering an interactive prompt, so slow password entry does not abort
  /// the connection. Each time a prompt closes the timeout is refreshed to
  /// allow the following network round-trip to complete.
  Future<void> _awaitAuthentication(
    SSHClient client,
    _InteractiveAuthGate gate, {
    required Duration timeout,
    required bool isJumpHost,
    SshConnectionCancellationToken? cancellationToken,
  }) {
    final completer = Completer<void>();
    Timer? timer;

    void arm() {
      timer?.cancel();
      timer = Timer(timeout, () {
        if (gate.isPrompting) {
          arm();
          return;
        }
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              isJumpHost
                  ? 'Jump host authentication timed out'
                  : 'Authentication timed out',
            ),
          );
        }
      });
    }

    client.authenticated.then<void>(
      (_) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    if (cancellationToken != null) {
      unawaited(
        cancellationToken.cancelled.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(
              const SshConnectionCancelledException(),
              StackTrace.current,
            );
          }
        }),
      );
    }

    gate.onActivityChanged = arm;
    arm();

    return completer.future.whenComplete(() {
      timer?.cancel();
      if (identical(gate.onActivityChanged, arm)) {
        gate.onActivityChanged = null;
      }
    });
  }

  static void _closeAbandonedSocket(SSHSocket socket) {
    socket.destroy();
  }

  HostKeyVerificationService _createHostKeyVerificationService(
    SshConnectionConfig config,
  ) {
    final repository = knownHostsRepository;
    if (repository == null) {
      throw HostKeyVerificationException(
        'SSH host key verification is unavailable for '
        '${config.hostname}:${config.port}.',
      );
    }

    return HostKeyVerificationService(
      knownHostsRepository: repository,
      promptHandler: hostKeyPromptHandler,
    );
  }

  Future<VerifiedHostKey> _probeHostKey(
    SSHSocket socket, {
    required SshConnectionConfig config,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    final verificationSocket = _prepareHostKeyCapture(socket);
    SSHClient? probeClient;
    Future<void>? probeAuthentication;
    String? callbackKeyType;
    String? callbackFingerprint;

    try {
      if (socket is! HostKeySource) {
        probeClient = _clientFactory(
          verificationSocket.socket,
          username: config.username,
          onVerifyHostKey: (type, fingerprint) {
            callbackKeyType = type;
            callbackFingerprint = _formatCallbackHostKeyFingerprint(
              fingerprint,
            );
            return true;
          },
        );
        probeAuthentication = _drainHostKeyProbeAuthentication(probeClient);
      }

      final presentedHostKey = await _readPresentedHostKey(
        verificationSocket.hostKeySource,
        config: config,
        keyType: callbackKeyType,
        cancellationToken: cancellationToken,
      );
      _confirmCapturedHostKeyMatchesCallback(
        presentedHostKey,
        callbackFingerprint,
        config: config,
      );
      return presentedHostKey;
    } finally {
      if (probeAuthentication != null) {
        await probeAuthentication;
      }
      await probeClient?.close();
      await verificationSocket.socket.close();
    }
  }

  Future<void> _drainHostKeyProbeAuthentication(SSHClient probeClient) async {
    final authentication = probeClient.authenticated.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        DiagnosticsLogService.instance.info(
          'ssh.host_key',
          'probe_authentication_ended',
          fields: {'errorType': error.runtimeType},
        );
      },
    );
    await authentication.timeout(_hostKeyProbeSettleTimeout, onTimeout: () {});
  }

  _PreparedHostKeySocket _prepareHostKeyCapture(SSHSocket socket) {
    final verificationSocket = socket is HostKeySource
        ? socket
        : _HostKeyCapturingSocket(socket);
    return _PreparedHostKeySocket(
      socket: verificationSocket,
      hostKeySource: verificationSocket as HostKeySource,
    );
  }

  Future<VerifiedHostKey> _readPresentedHostKey(
    HostKeySource hostKeySource, {
    required SshConnectionConfig config,
    required String? keyType,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    final readHostKeyBytes = hostKeySource.hostKeyBytes.timeout(
      config.connectionTimeout,
      onTimeout: () => throw HostKeyVerificationException(
        'Timed out while reading the host key for '
        '${config.hostname}:${config.port}.',
      ),
    );
    final hostKeyBytes =
        await (cancellationToken?.guard(readHostKeyBytes) ?? readHostKeyBytes);
    return VerifiedHostKey(
      hostname: config.hostname,
      port: config.port,
      keyType:
          keyType ?? canonicalizeSshHostKeyType('', hostKeyBytes: hostKeyBytes),
      hostKeyBytes: hostKeyBytes,
    );
  }

  void _confirmCapturedHostKeyMatchesCallback(
    VerifiedHostKey presentedHostKey,
    String? callbackFingerprint, {
    required SshConnectionConfig config,
  }) {
    if (callbackFingerprint != null &&
        !_hostKeyFingerprintMatchesPresentedKey(
          presentedHostKey,
          callbackFingerprint,
        )) {
      throw HostKeyVerificationException(
        'Failed to confirm the presented host key for '
        '${config.hostname}:${config.port}.',
      );
    }
  }

  bool _trustedHostMatchesCallback(
    KnownHost trustedHost,
    Uint8List fingerprint,
  ) => sshHostTrustMatches(
    firstFingerprint: trustedHost.fingerprint,
    firstEncodedHostKey: trustedHost.hostKey,
    secondFingerprint: _formatCallbackHostKeyFingerprint(fingerprint),
    secondEncodedHostKey: '',
  );

  bool _probedHostKeyMatchesCallback(
    VerifiedHostKey presentedHostKey,
    Uint8List fingerprint,
  ) => _hostKeyFingerprintMatchesPresentedKey(
    presentedHostKey,
    _formatCallbackHostKeyFingerprint(fingerprint),
  );

  bool _hostKeyFingerprintMatchesPresentedKey(
    VerifiedHostKey presentedHostKey,
    String callbackFingerprint,
  ) => sshHostTrustMatches(
    firstFingerprint: presentedHostKey.fingerprint,
    firstEncodedHostKey: presentedHostKey.encodedHostKey,
    secondFingerprint: callbackFingerprint,
    secondEncodedHostKey: '',
  );

  String _formatCallbackHostKeyFingerprint(Uint8List fingerprint) {
    final openSshFingerprint = _tryDecodeOpenSshHostKeyFingerprint(fingerprint);
    if (openSshFingerprint != null) {
      return openSshFingerprint;
    }
    return _formatLegacyFingerprintBytes(fingerprint);
  }

  String? _tryDecodeOpenSshHostKeyFingerprint(Uint8List fingerprint) {
    try {
      final text = utf8.decode(fingerprint);
      if (text.startsWith('SHA256:')) {
        return text;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String _formatLegacyFingerprintBytes(Uint8List fingerprint) => fingerprint
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join(':');

  /// Disconnect a session by connection ID.
  Future<void> disconnect(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'ssh.session',
      'disconnect',
      fields: {'connectionId': connectionId},
    );
    final session = _sessions.remove(connectionId);
    await session?.close();
  }

  /// Disconnect all sessions.
  Future<void> disconnectAll() async {
    DiagnosticsLogService.instance.info(
      'ssh.session',
      'disconnect_all',
      fields: {'connectionCount': _sessions.length},
    );
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    await Future.wait(sessions.map((session) async => session.close()));
  }

  /// Get a session by connection ID.
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  /// Get all sessions for a host.
  List<SshSession> getSessionsForHost(int hostId) => _sessions.values
      .where((session) => session.hostId == hostId)
      .toList(growable: false);

  /// Check if a connection ID is active.
  bool isConnected(int connectionId) => _sessions.containsKey(connectionId);

  Future<List<SSHKeyPair>?> _parseIdentities(SshConnectionConfig config) async {
    final identities = <SSHKeyPair>[];
    for (final key in config.identityKeys ?? const <SshKey>[]) {
      try {
        identities.addAll(
          await parseOpenSshPrivateKey(key.privateKey, key.passphrase),
        );
      } on FormatException {
        continue;
      } on SSHError {
        continue;
      }
    }
    if (identities.isNotEmpty) return identities;
    if (config.privateKey == null) return null;
    try {
      final parsed = await parseOpenSshPrivateKey(
        config.privateKey!,
        config.passphrase,
      );
      if (parsed.isNotEmpty) return parsed;
    } on FormatException {
      // Report an unusable explicitly selected key below.
    } on SSHError {
      // Includes missing or incorrect passphrases.
    }
    throw const FormatException(
      'The selected SSH key is invalid or its passphrase is incorrect.',
    );
  }

  static SSHClient _defaultClientFactory(
    SSHSocket socket, {
    required String username,
    SSHHostkeyVerifyHandler? onVerifyHostKey,
    SSHPasswordRequestHandler? onPasswordRequest,
    SSHUserInfoRequestHandler? onUserInfoRequest,
    List<SSHKeyPair>? identities,
    Duration? keepAliveInterval,
  }) => SSHClient(
    socket,
    username: username,
    onVerifyHostKey: onVerifyHostKey,
    onPasswordRequest: onPasswordRequest,
    onUserInfoRequest: onUserInfoRequest,
    identities: identities,
    keepAliveInterval: keepAliveInterval,
  );

  /// Connects a TCP socket with OS-level keepalive enabled so the connection
  /// survives brief periods in the background without the OS tearing it down.
  static Future<SSHSocket> _connectWithKeepAlive(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    // ignore: close_sinks — socket is closed via _KeepAliveSSHSocket.close()
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      _enableTcpKeepAlive(socket);
    } on Exception {
      // Fallback: not all platforms support raw socket options.
    }
    return _KeepAliveSSHSocket(socket);
  }

  /// Enables aggressive TCP keepalive so the OS sends probes every 15s
  /// instead of the default ~2 hours, keeping the socket alive while
  /// the app is briefly backgrounded.
  static void _enableTcpKeepAlive(Socket socket) {
    const ipprotoTcp = 6;
    const keepAliveSeconds = 15;

    if (Platform.isIOS || Platform.isMacOS) {
      socket
        // SO_KEEPALIVE
        ..setRawOption(RawSocketOption.fromBool(0xFFFF, 0x0008, true))
        // TCP_KEEPALIVE (idle time before first probe)
        ..setRawOption(
          RawSocketOption.fromInt(ipprotoTcp, 0x10, keepAliveSeconds),
        )
        // TCP_KEEPINTVL (interval between probes)
        ..setRawOption(
          RawSocketOption.fromInt(ipprotoTcp, 0x101, keepAliveSeconds),
        )
        // TCP_KEEPCNT (number of failed probes before giving up)
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 0x102, 3));
    } else if (Platform.isAndroid || Platform.isLinux) {
      socket
        // SO_KEEPALIVE
        ..setRawOption(RawSocketOption.fromBool(1, 9, true))
        // TCP_KEEPIDLE
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 4, keepAliveSeconds))
        // TCP_KEEPINTVL
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 5, keepAliveSeconds))
        // TCP_KEEPCNT
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 6, 3));
    }
  }
}

/// SSHSocket wrapper that enables TCP keepalive on the underlying socket.
class _KeepAliveSSHSocket implements SSHSocket {
  _KeepAliveSSHSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async => _socket.close();

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();
}

class _FiniteChunkSshSocket implements SSHSocket {
  _FiniteChunkSshSocket(Iterable<Uint8List> chunks)
    : _stream = Stream<Uint8List>.fromIterable(chunks);

  final Stream<Uint8List> _stream;
  final _sinkController = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() => _sinkController.close();

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _PreparedHostKeySocket {
  const _PreparedHostKeySocket({
    required this.socket,
    required this.hostKeySource,
  });

  final SSHSocket socket;
  final HostKeySource hostKeySource;
}

Future<void> _relayForward(
  Socket socket,
  FutureOr<SSHForwardChannel?> Function() openChannel, {
  Future<void>? stopped,
  Duration? openTimeout,
  void Function(SSHForwardChannel)? destroyChannel,
}) async {
  SSHForwardChannel? forward;
  StreamIterator<Uint8List>? incoming;
  StreamIterator<Uint8List>? outgoing;
  Future<void>? socketFlush;
  var finished = false;
  var forwardSinkClosed = false;
  var closingForwardSink = false;
  var socketClosed = false;
  var closingSocket = false;
  final unexpectedClose = Completer<void>();
  void closed() {
    if (!unexpectedClose.isCompleted) unexpectedClose.complete();
  }

  void failed(Object error, StackTrace stackTrace) {
    if (!unexpectedClose.isCompleted) {
      unexpectedClose.completeError(error, stackTrace);
    }
  }

  void destroy(SSHForwardChannel channel) {
    if (destroyChannel != null) {
      destroyChannel(channel);
    } else {
      channel.destroy();
    }
  }

  // Observe write-side errors before awaiting channel creation.
  unawaited(
    socket.done.then<void>((_) {
      socketClosed = true;
      if (!closingSocket) closed();
    }, onError: failed),
  );
  try {
    final opening = Future<SSHForwardChannel?>.sync(openChannel).then((
      channel,
    ) {
      if (channel == null) return null;
      if (finished) {
        destroy(channel);
        return null;
      }
      unawaited(
        channel.sink.done.then<void>(
          (_) {
            forwardSinkClosed = true;
            if (!closingForwardSink) closed();
          },
          onError: (Object error, StackTrace stackTrace) {
            forwardSinkClosed = true;
            failed(error, stackTrace);
          },
        ),
      );
      return forward = channel;
    });
    outgoing = StreamIterator(socket);
    final source = outgoing;
    final socketToForward = () async {
      while (await source.moveNext()) {
        final channel = await opening;
        // A delivered channel may already have a completed sink.done future.
        // Let its observer run before writing queued socket bytes.
        await Future<void>.value();
        if (channel == null || finished || forwardSinkClosed) return;
        channel.sink.add(source.current);
        await channel.flush();
      }
      final channel = forward;
      if (channel != null && !finished && !forwardSinkClosed) {
        // EOF closes only this direction. The peer can still send a response.
        closingForwardSink = true;
        await channel.sink.close();
      }
    }();
    final pending = Future.any<SSHForwardChannel?>([
      opening,
      socketToForward.then((_) => null),
      unexpectedClose.future.then((_) => null),
      if (stopped != null) stopped.then((_) => null),
    ]);
    final channel = await (openTimeout == null
        ? pending
        : pending.timeout(openTimeout));
    if (channel == null) return;
    incoming = StreamIterator(channel.stream);
    final response = incoming;
    final forwardToSocket = () async {
      while (await response.moveNext()) {
        if (finished || socketClosed) return;
        socket.add(response.current);
        await (socketFlush = socket.flush());
      }
      closingSocket = true;
      await socket.close();
    }();
    // Normal EOF preserves the opposite direction; errors, external sink
    // closure, and tunnel cancellation terminate both pumps.
    await Future.any<void>([
      Future.wait([forwardToSocket, socketToForward], eagerError: true),
      unexpectedClose.future,
      ?stopped,
    ]);
  } finally {
    finished = true;
    try {
      try {
        if (socketFlush != null) await socketFlush;
        if (!closingSocket) {
          closingSocket = true;
          await socket.close();
        }
      } finally {
        await Future.wait([
          if (incoming != null) incoming.cancel(),
          if (outgoing != null) outgoing.cancel(),
        ]);
      }
    } on SocketException {
      socket.destroy();
      rethrow;
    } finally {
      if (forward != null) destroy(forward!);
    }
  }
}

bool _isClosedForwardSinkError(Object error) =>
    error is StateError &&
    (error.message == 'Cannot add event after closing' ||
        error.message == 'StreamSink is closed');

Map<String, Object?> _diagnosticSshExecErrorFields(Object error) => {
  'errorType': error.runtimeType,
  if (error is SSHChannelOpenError) ...{
    'channelOpenCode': error.code,
    'reason': _diagnosticSshChannelOpenReason(error.description),
  },
};

String? _diagnosticClosedSshConnectionErrorReason(Object error) {
  if (error is! SSHStateError) {
    return null;
  }
  final normalized = error.message.toLowerCase();
  if (normalized.contains('transport is closed')) {
    return 'transport_closed';
  }
  if (normalized.contains('connection closed')) {
    return 'connection_closed';
  }
  return null;
}

String _diagnosticSshChannelOpenReason(String description) {
  final normalized = description.toLowerCase();
  if (normalized.contains('administratively prohibited')) {
    return 'administratively_prohibited';
  }
  if (normalized.contains('resource shortage')) {
    return 'resource_shortage';
  }
  if (normalized.contains('connect failed')) {
    return 'connect_failed';
  }
  if (normalized.contains('unknown channel type')) {
    return 'unknown_channel_type';
  }
  if (normalized.contains('open failed')) {
    return 'open_failed';
  }
  return 'channel_open_failed';
}

String _diagnosticSshResultErrorKind(String? error) {
  if (error == null || error.isEmpty) {
    return 'unknown';
  }
  if (error.startsWith('Authentication failed')) {
    return 'authentication_failed';
  }
  if (error.startsWith('Host key verification failed')) {
    return 'host_key_verification_failed';
  }
  if (error.startsWith('Connection failed')) {
    return 'connection_failed';
  }
  if (error.contains('timed out')) {
    return 'timeout';
  }
  return 'connection_error';
}

String _diagnosticSshCommandKind(String command) {
  final trimmed = command.trimLeft();
  if (trimmed.contains('FLUTTY_MODE=') ||
      trimmed.contains('__FLUTTY_COMPLETION__') ||
      trimmed.contains('__FLUTTY_ZSH_NATIVE_DONE__') ||
      trimmed.contains('__FLUTTY_HISTORY_DONE__')) {
    return 'shell_completion';
  }
  if (trimmed.startsWith('tmux ') ||
      trimmed.startsWith('tmux -u ') ||
      trimmed.contains(' tmux ') ||
      trimmed.contains('/tmux ')) {
    return 'tmux';
  }
  if (trimmed.contains('__flutty_agent_discovery_exec_done__')) {
    return 'agent_session_discovery';
  }
  if (trimmed.contains('.copilot/session-state')) {
    return 'active_session_metadata';
  }
  if (trimmed.contains(_automaticPortWatcherSnapshotBeginMarker)) {
    return 'automatic_port_watcher';
  }
  if (trimmed.contains(_automaticPortDiscoveryDoneMarker)) {
    return 'automatic_port_discovery';
  }
  if (trimmed.contains('command -v')) {
    return 'command_detection';
  }
  if (trimmed.contains('__flutty_tmux_exec_done__')) {
    return 'tmux_marked_exec';
  }
  return 'ssh_exec';
}

/// Whether [remoteVersion] — the SSH server identification string, e.g.
/// `SSH-2.0-OpenSSH_for_Windows_9.5` — indicates a Windows remote host.
///
/// Windows OpenSSH launches `cmd.exe` or PowerShell (not a POSIX shell) for
/// interactive sessions and exec channels, so POSIX-only behaviour (the
/// truecolor login-shell bootstrap, tmux/MonkeyMux, `~/.profile` sourcing,
/// shell completion, agent-session discovery) must be skipped when this is
/// true. Returns `false` when the identification string is unknown so hosts
/// default to the POSIX path.
bool remoteVersionIndicatesWindows(String? remoteVersion) {
  if (remoteVersion == null || remoteVersion.isEmpty) {
    return false;
  }
  return remoteVersion.toLowerCase().contains('windows');
}

class _HostKeyCapturingSocket implements SSHSocket, HostKeySource {
  _HostKeyCapturingSocket(this._delegate)
    : _hostKeyParser = _SshHostKeyParser() {
    _stream = _delegate.stream.map((chunk) {
      _hostKeyParser.addChunk(chunk);
      return chunk;
    });
  }

  final SSHSocket _delegate;
  final _SshHostKeyParser _hostKeyParser;
  late final Stream<Uint8List> _stream;

  @override
  Future<Uint8List> get hostKeyBytes => _hostKeyParser.hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _delegate.sink;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> flush() => _delegate.flush();

  @override
  Future<void> get done => _delegate.done;

  @override
  void destroy() => _delegate.destroy();
}

class _SshHostKeyParser {
  static const _maxBufferedBytes = 256 * 1024;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<Uint8List> _hostKeyBytes = Completer<Uint8List>();
  final BytesBuilder _versionBuffer = BytesBuilder(copy: false);
  bool _versionSeen = false;

  Future<Uint8List> get hostKeyBytes => _hostKeyBytes.future;

  void addChunk(Uint8List chunk) {
    if (_hostKeyBytes.isCompleted) {
      return;
    }

    if (!_versionSeen) {
      _consumeVersionBytes(chunk);
      return;
    }

    _buffer.add(chunk);
    _failIfBufferLimitExceeded(
      _buffer.length,
      context:
          'SSH handshake packet buffer exceeded '
          '$_maxBufferedBytes bytes before the host key was parsed.',
    );
    _parsePackets();
  }

  void _consumeVersionBytes(Uint8List chunk) {
    _versionBuffer.add(chunk);
    _failIfBufferLimitExceeded(
      _versionBuffer.length,
      context:
          'SSH identification exchange exceeded $_maxBufferedBytes bytes '
          'before a protocol version line was received.',
    );
    final bytes = _versionBuffer.takeBytes();
    var searchStart = 0;
    while (true) {
      final newlineIndex = bytes.indexOf(0x0A, searchStart);
      if (newlineIndex == -1) {
        _versionBuffer.add(bytes.sublist(searchStart));
        return;
      }

      final lineBytes = bytes.sublist(searchStart, newlineIndex + 1);
      final line = utf8.decode(lineBytes, allowMalformed: true).trim();
      searchStart = newlineIndex + 1;
      if (!line.startsWith('SSH-')) {
        continue;
      }

      _versionSeen = true;
      if (searchStart < bytes.length) {
        _buffer.add(bytes.sublist(searchStart));
        _parsePackets();
      }
      return;
    }
  }

  void _parsePackets() {
    final data = _buffer.takeBytes();
    var offset = 0;
    while (!_hostKeyBytes.isCompleted && data.length - offset >= 5) {
      final packetLength = _readUint32(data, offset);
      if (packetLength + 4 > _maxBufferedBytes) {
        _fail(
          'SSH handshake packet length $packetLength exceeds the '
          '$_maxBufferedBytes-byte host-key capture limit.',
        );
        return;
      }
      if (packetLength < 1 || data.length - offset < packetLength + 4) {
        break;
      }

      final paddingLength = data[offset + 4];
      final payloadLength = packetLength - paddingLength - 1;
      if (payloadLength > 0) {
        final payloadStart = offset + 5;
        final payloadEnd = payloadStart + payloadLength;
        final payload = Uint8List.sublistView(data, payloadStart, payloadEnd);
        _tryCaptureHostKey(payload);
      }

      offset += packetLength + 4;
    }

    if (offset < data.length) {
      _buffer.add(data.sublist(offset));
    }
  }

  void _failIfBufferLimitExceeded(int length, {required String context}) {
    if (length > _maxBufferedBytes) {
      _fail(context);
    }
  }

  void _fail(String message) {
    if (_hostKeyBytes.isCompleted) {
      return;
    }
    _hostKeyBytes.completeError(HostKeyVerificationException(message));
  }

  void _tryCaptureHostKey(Uint8List payload) {
    if (payload.isEmpty) {
      return;
    }

    final messageId = payload[0];
    if (messageId != 31 && messageId != 33) {
      return;
    }

    final hostKey = _readSshString(payload, 1);
    if (hostKey == null || !_looksLikeHostKeyBlob(hostKey)) {
      return;
    }

    _hostKeyBytes.complete(Uint8List.fromList(hostKey));
  }

  bool _looksLikeHostKeyBlob(Uint8List hostKey) {
    final typeBytes = _readSshString(hostKey, 0);
    if (typeBytes == null) {
      return false;
    }

    final type = utf8.decode(typeBytes, allowMalformed: true);
    return type == 'ssh-rsa' ||
        type == 'ssh-ed25519' ||
        type.startsWith('ecdsa-sha2-');
  }

  static int _readUint32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static Uint8List? _readSshString(Uint8List bytes, int offset) {
    if (bytes.length - offset < 4) {
      return null;
    }

    final length = _readUint32(bytes, offset);
    final start = offset + 4;
    final end = start + length;
    if (length < 0 || end > bytes.length) {
      return null;
    }

    return Uint8List.sublistView(bytes, start, end);
  }
}

enum _PortForwardOperationKind { start, replace, stop }

const _automaticPortDiscoveryDoneMarker = '__monkeyssh_port_discovery_done__';
const _automaticPortDiscoveryUnavailableMarker =
    '__monkeyssh_port_discovery_unavailable__';
const _automaticPortDiscoveryShellPidsMarker =
    '__monkeyssh_shell_descendant_pids__:';
const _automaticPortWatcherSnapshotBeginMarker =
    '__monkeyssh_port_snapshot_begin__';
const _automaticPortWatcherSnapshotEndMarker =
    '__monkeyssh_port_snapshot_end__';

/// A reachable remote TCP listener discovered during automatic forwarding.
typedef RemoteTcpListener = ({String host, int port, bool isShellRelated});

/// Stable identity for one remote listener.
typedef RemoteTcpListenerKey = ({String host, int port});

/// Extracts listening TCP ports and reachable loopback targets from remote
/// `ss`, `netstat`, `lsof`, or PowerShell output.
Map<RemoteTcpListenerKey, RemoteTcpListener> parseRemoteListeningTcpListeners(
  String output,
) {
  final listeners = <RemoteTcpListenerKey, RemoteTcpListener>{};
  final priorities = <RemoteTcpListenerKey, int>{};
  final shellDescendantPids = <int>{};
  final endpointPattern = RegExp(r'(\S+)(?::|\.)(\d+)(?=\s|$)');
  final ssPidPattern = RegExp(r'pid=(\d+)');
  int? lsofPid;
  bool? lsofIsIpv6;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith(_automaticPortDiscoveryShellPidsMarker)) {
      shellDescendantPids.addAll(
        line
            .substring(_automaticPortDiscoveryShellPidsMarker.length)
            .split(',')
            .map(int.tryParse)
            .whereType<int>(),
      );
      continue;
    }
    final lsofPidMatch = RegExp(r'^p(\d+)$').firstMatch(line);
    if (lsofPidMatch != null) {
      lsofPid = int.parse(lsofPidMatch.group(1)!);
      lsofIsIpv6 = null;
      continue;
    }
    if (line == 'tIPv4' || line == 'tIPv6') {
      lsofIsIpv6 = line == 'tIPv6';
      continue;
    }
    final directPort = int.tryParse(line);
    if (directPort != null) {
      if (directPort >= 1 && directPort <= 65535) {
        final key = remoteTcpListenerKey('localhost', directPort);
        listeners[key] = (
          host: 'localhost',
          port: directPort,
          isShellRelated: false,
        );
        priorities[key] = 0;
      }
      continue;
    }
    if (!line.toUpperCase().contains('LISTEN') && !line.startsWith('n')) {
      continue;
    }
    final endpointMatch = endpointPattern.firstMatch(
      line.startsWith('n') ? line.substring(1) : line,
    );
    if (endpointMatch == null) {
      continue;
    }
    final port = int.tryParse(endpointMatch.group(2)!);
    final target = _automaticPortForwardTarget(
      endpointMatch.group(1)!,
      listenerLine: line,
      lsofIsIpv6: lsofIsIpv6,
    );
    if (port == null || port < 1 || port > 65535 || target == null) {
      continue;
    }
    final listenerPids = {
      if (line.startsWith('n')) ?lsofPid,
      ...ssPidPattern
          .allMatches(line)
          .map((match) => int.tryParse(match.group(1)!))
          .whereType<int>(),
    };
    final isShellRelated = listenerPids.any(shellDescendantPids.contains);
    final key = remoteTcpListenerKey(target.host, port);
    final currentPriority = priorities[key];
    final currentListener = listeners[key];
    if (currentPriority == null ||
        target.priority < currentPriority ||
        (target.priority == currentPriority &&
            isShellRelated &&
            !(currentListener?.isShellRelated ?? false))) {
      listeners[key] = (
        host: key.host,
        port: port,
        isShellRelated: isShellRelated,
      );
      priorities[key] = target.priority;
    }
  }
  return listeners;
}

/// Canonical listener identity used by discovery and manual-forward exclusions.
RemoteTcpListenerKey remoteTcpListenerKey(String host, int port) =>
    (host: _canonicalRemoteTcpListenerHost(host), port: port);

/// Listener identities excluded by a saved loopback target.
///
/// `localhost` is ambiguous across platforms, so saved rules using it reserve
/// both loopback families while concrete discovered addresses remain distinct.
Set<RemoteTcpListenerKey> remoteTcpListenerExclusionKeys(
  String host,
  int port,
) {
  final normalized = host
      .trim()
      .replaceFirst(RegExp(r'^\['), '')
      .replaceFirst(RegExp(r'\]$'), '')
      .toLowerCase();
  if (normalized == 'localhost') {
    return {
      remoteTcpListenerKey(InternetAddress.loopbackIPv4.address, port),
      remoteTcpListenerKey(InternetAddress.loopbackIPv6.address, port),
    };
  }
  return {remoteTcpListenerKey(host, port)};
}

Set<RemoteTcpListenerKey> _manualListenerExclusions(
  Iterable<ActiveTunnelInfo> tunnels,
) => tunnels
    .where(
      (tunnel) =>
          !tunnel.isAutomatic && isPortForwardLoopbackHost(tunnel.remoteHost),
    )
    .expand(
      (tunnel) =>
          remoteTcpListenerExclusionKeys(tunnel.remoteHost, tunnel.remotePort),
    )
    .toSet();

String _canonicalRemoteTcpListenerHost(String host) {
  final normalized = host
      .trim()
      .replaceFirst(RegExp(r'^\['), '')
      .replaceFirst(RegExp(r'\]$'), '')
      .toLowerCase();
  final zoneIndex = normalized.indexOf('%');
  final unscoped = zoneIndex < 0
      ? normalized
      : normalized.substring(0, zoneIndex);
  if (unscoped.isEmpty ||
      unscoped == 'localhost' ||
      unscoped == '0.0.0.0' ||
      unscoped == '127.0.0.1') {
    return InternetAddress.loopbackIPv4.address;
  }
  if (unscoped == '::' || unscoped == '::1') {
    return InternetAddress.loopbackIPv6.address;
  }
  return unscoped;
}

({String host, int priority})? _automaticPortForwardTarget(
  String value, {
  required String listenerLine,
  bool? lsofIsIpv6,
}) {
  final address = value
      .replaceFirst(RegExp(r'^\['), '')
      .replaceFirst(RegExp(r'\]$'), '')
      .toLowerCase();
  if (address == '*') {
    final isIpv6 =
        (lsofIsIpv6 ?? false) ||
        RegExp(
          r'(^|\s)tcp6(?:\s|$)',
          caseSensitive: false,
        ).hasMatch(listenerLine);
    return (
      host: isIpv6
          ? InternetAddress.loopbackIPv6.address
          : InternetAddress.loopbackIPv4.address,
      priority: 1,
    );
  }
  if (address == '0.0.0.0') {
    return (host: InternetAddress.loopbackIPv4.address, priority: 1);
  }
  if (address == '::') {
    return (host: InternetAddress.loopbackIPv6.address, priority: 1);
  }
  if (address == '::1' ||
      address == 'localhost' ||
      address.startsWith('127.')) {
    return (host: address, priority: 0);
  }
  return null;
}

/// Builds a stable remote shell-lineage marker for one SSH endpoint.
String buildSshShellLineageToken(SshConnectionConfig config, {int? hostId}) =>
    sha256
        .convert(
          utf8.encode(
            '${hostId ?? 0}:${config.username}@'
            '${config.hostname.toLowerCase()}:${config.port}',
          ),
        )
        .toString()
        .substring(0, 24);

String _sshEndpointKey(SshConnectionConfig config) {
  final endpoint =
      '${config.username}@${config.hostname.toLowerCase()}:${config.port}';
  final jumpHost = config.jumpHost;
  return jumpHost == null
      ? endpoint
      : '${_sshEndpointKey(jumpHost)}->$endpoint';
}

/// An active SSH session.
class SshSession {
  /// Creates a new [SshSession].
  SshSession({
    required this.connectionId,
    required this.hostId,
    required this.client,
    required this.config,
    this.dependentClients = const <SSHClient>[],
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
    this.terminalFontSize,
    this.clipboardSharingEnabled = false,
    this.localClipboardReadEnabled = false,
    String? monkeyMuxClientId,
  }) : monkeyMuxClientId =
           monkeyMuxClientId ?? _createMonkeyMuxClientId(connectionId),
       createdAt = DateTime.now();

  static const _previewRefreshInterval = Duration(milliseconds: 150);
  static const _shellIoDiagnosticsInterval = Duration(seconds: 1);
  static const _defaultPortForwardStartTimeout = Duration(seconds: 10);
  static const _automaticPortDiscoveryTimeout = Duration(seconds: 8);
  static const _automaticPortWatcherStartTimeout = Duration(seconds: 10);
  static const _automaticPortWatcherCloseTimeout = Duration(seconds: 2);
  static const _sftpOpenRetryDelays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ];
  static const _previewLineCount = 17;
  static const _previewMaxChars = 1700;
  static final _monkeyMuxClientIdRandom = math.Random.secure();
  static final _previewSanitizerPattern = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');
  static final _windowTitleSanitizerPattern = RegExp(r'[\x00-\x1F\x7F]');

  static String _createMonkeyMuxClientId(int connectionId) {
    final random = List<String>.generate(
      4,
      (_) => _monkeyMuxClientIdRandom
          .nextInt(1 << 32)
          .toRadixString(16)
          .padLeft(8, '0'),
      growable: false,
    ).join();
    return 'monkeyssh-$connectionId-$random';
  }

  /// The connection ID for this active session.
  final int connectionId;

  /// Unique foreground-client identity shared by MonkeyMux attach and control
  /// channels for this SSH session.
  final String monkeyMuxClientId;

  /// The host ID this session is connected to.
  final int hostId;

  /// The SSH client.
  final SSHClient client;

  /// The SSH server identification string reported during the handshake, e.g.
  /// `SSH-2.0-OpenSSH_for_Windows_9.5`. Null until the handshake completes.
  String? get remoteSoftwareVersion => client.remoteVersion;

  /// Whether the remote host is Windows (its default shell is `cmd.exe` or
  /// PowerShell rather than a POSIX shell), detected from
  /// [remoteSoftwareVersion].
  ///
  /// When true, POSIX-only session behaviour — the truecolor login-shell
  /// bootstrap, tmux detection and `~/.profile` sourcing — is skipped because
  /// those commands fail on `cmd.exe`/PowerShell (e.g.
  /// `'exec' is not recognized...`). MonkeyMux, agent-session discovery and
  /// shell completion instead take Windows-aware paths (a ConPTY helper and
  /// PowerShell `-EncodedCommand` probes respectively).
  bool get remoteIsWindows =>
      remoteVersionIndicatesWindows(remoteSoftwareVersion);

  /// The connection configuration.
  final SshConnectionConfig config;

  /// Stable marker inherited by remote descendants from this host endpoint.
  late final String shellLineageToken = buildSshShellLineageToken(
    config,
    hostId: hostId,
  );

  /// Additional clients that should be closed with the session client.
  final List<SSHClient> dependentClients;

  /// Session-specific light theme override.
  String? terminalThemeLightId;

  /// Session-specific dark theme override.
  String? terminalThemeDarkId;

  /// Session-specific terminal font size override.
  double? terminalFontSize;

  /// Native ACP session currently focused instead of the terminal viewport.
  AcpSessionKey? activeNativeAcpSessionKey;

  /// In-memory display title for the focused native ACP session.
  String? activeNativeAcpDisplayTitle;

  /// Bounded in-memory conversation preview for the focused native session.
  String? activeNativeAcpPreview;

  /// Role-aware live preview for the focused native session.
  AcpNativePreviewSnapshot? activeNativeAcpPreviewSnapshot;

  /// The terminal multiplexer backend currently attached in this session.
  RemoteMuxBackend? remoteMuxBackend;

  bool _canTerminalResizeFromHost() =>
      remoteMuxBackend == RemoteMuxBackend.monkeyMux;

  /// The terminal multiplexer session name currently attached in this session.
  String? remoteMuxSessionName;

  /// Whether the attached MonkeyMux server publishes its shared PTY grid size.
  bool monkeyMuxViewportClippingEnabled = false;

  /// Whether OSC 52 clipboard sharing is enabled for this session.
  bool clipboardSharingEnabled;

  /// Whether the remote side may read the local clipboard.
  bool localClipboardReadEnabled;

  /// When the session was created.
  final DateTime createdAt;

  final ClipboardSharingService _clipboardSharingService =
      const ClipboardSharingService();

  late final _SshSessionRuntime _runtime = _SshSessionRuntime(this);

  TerminalThemeData? _configuredTerminalTheme;
  TerminalThemeData? _terminalTheme;
  final _terminalColorOverrides = TerminalOscColorOverrides();

  /// The active terminal theme used to answer remote OSC color queries.
  TerminalThemeData? get terminalTheme => _terminalTheme;

  /// Updates the active terminal theme and notifies preview listeners.
  set terminalTheme(TerminalThemeData? theme) {
    setTerminalTheme(theme);
  }

  /// Whether the foreground app requested xterm color-scheme update reports.
  bool get terminalColorSchemeUpdatesMode =>
      _runtime.terminalColorSchemeUpdatesMode;

  /// Whether the remote requested win32-input-mode (DEC private mode 9001).
  ///
  /// Only Windows ConPTY (conhost) requests this mode, so it doubles as a
  /// protocol-level signal that a ConPTY sits between MonkeySSH and the
  /// foreground app.
  bool get terminalWin32InputMode => _runtime.terminalWin32InputMode;

  /// Whether the current shell queried its ANSI palette at or after [instant].
  ///
  /// ConPTY forwards OSC 4 palette queries from foreground TUIs even when it
  /// consumes their OSC 10/11 default-color queries. A bare Windows shell does
  /// not interrogate the palette, so this is safe evidence that a delayed
  /// default-color report belongs to a TUI rather than the command prompt.
  bool hasTerminalPaletteQuerySince(DateTime instant) {
    final lastQueryAt = _lastTerminalPaletteQueryAt;
    return lastQueryAt != null && !lastQueryAt.isBefore(instant);
  }

  /// Tracks OSC 8 hyperlinks rendered in the persistent terminal.
  final terminalHyperlinkTracker = TerminalHyperlinkTracker();

  /// Tracks semantic command locations for previous-command navigation.
  final terminalCommandMarkTracker = TerminalCommandMarkTracker();

  /// Number of semantic command marks retained in terminal scrollback.
  int get terminalCommandMarkCount => terminalCommandMarkTracker.markCount;

  final _previewListeners = <VoidCallback>{};
  final _metadataListeners = <VoidCallback>{};
  final _connectionHealthFailures =
      StreamController<_SshConnectionHealthFailure>.broadcast();
  final _terminalNotificationParser = TerminalNotificationParser();
  final _terminalNotifications =
      StreamController<TerminalNotificationRequest>.broadcast();
  bool _connectionHealthFailureReported = false;
  String? _terminalPreview;
  TerminalPreviewSnapshot? _terminalPreviewSnapshot;
  String? _windowTitle;
  String? _iconName;
  Uri? _workingDirectory;
  String? _terminalReportedRemoteHost;
  TerminalShellStatus? _shellStatus;
  int? _lastExitCode;
  TerminalProgress? _terminalProgress;
  SftpClient? _sftpClient;
  Future<SftpClient>? _sftpClientFuture;

  /// The persistent terminal for this session. Created on first shell open.
  Terminal? get terminal => _runtime.terminal;

  /// Monotonic count of shell output chunks received from the remote.
  ///
  /// Callers use it as evidence that the remote actually sent something, so a
  /// repaint can be demanded only when one demonstrably never arrived.
  int get shellOutputChunkSequence => _runtime.shellOutputChunkSequence;

  /// A plain-text preview of the latest terminal content.
  String? get terminalPreview => _terminalPreview;

  /// A styled preview of the latest terminal content.
  TerminalPreviewSnapshot? get terminalPreviewSnapshot =>
      _terminalPreviewSnapshot;

  Stream<_SshConnectionHealthFailure> get _connectionHealthFailureStream =>
      _connectionHealthFailures.stream;

  /// Desktop-notification requests emitted by the remote shell via OSC 9 / 777
  /// / 99 escape sequences.
  Stream<TerminalNotificationRequest> get terminalNotifications =>
      _terminalNotifications.stream;

  /// Routes a private OSC sequence exactly as the live terminal does. Exposed so
  /// tests can exercise the OSC dispatch without a real shell channel.
  @visibleForTesting
  void debugHandlePrivateOsc(String code, List<String> args) =>
      _handlePrivateOsc(code, args);

  /// The terminal-output coalescing interval. Exposed so tests can hold
  /// buffered output deterministically instead of racing the real timer.
  @visibleForTesting
  Duration get debugTerminalOutputFlushInterval =>
      _runtime.debugTerminalOutputFlushInterval;

  @visibleForTesting
  set debugTerminalOutputFlushInterval(Duration value) =>
      _runtime.debugTerminalOutputFlushInterval = value;

  /// Synchronously flushes buffered terminal/stdout output. Exposed so tests can
  /// trigger a coalesced flush without waiting on the real coalescing timer.
  @visibleForTesting
  void debugFlushPendingTerminalOutput() =>
      _runtime.debugFlushPendingTerminalOutput();

  /// Pauses hidden terminal parsing while a native ACP viewport is active.
  void setTerminalParsingPaused({required bool paused}) =>
      _runtime.setTerminalParsingPaused(paused: paused);

  /// The latest terminal window title emitted by the remote session.
  String? get windowTitle => _windowTitle;

  /// The latest terminal icon name emitted by the remote session.
  String? get iconName => _iconName;

  /// The latest working-directory URI emitted through OSC 7, OSC 9;9,
  /// OSC 633, or OSC 1337.
  Uri? get workingDirectory => _workingDirectory;

  /// The latest shell integration status emitted through OSC 133 or OSC 633.
  TerminalShellStatus? get shellStatus => _shellStatus;

  /// The latest command exit code emitted through shell integration.
  int? get lastExitCode => _lastExitCode;

  /// The latest progress update emitted through OSC 9;4.
  TerminalProgress? get terminalProgress => _terminalProgress;

  /// Synchronizes OSC 9;4 progress metadata from an authoritative source.
  ///
  /// Returns whether progress changed. Metadata listeners are notified only
  /// when this call changes the session state.
  bool synchronizeTerminalProgress(TerminalProgress? progress) {
    if (_terminalProgress == progress) {
      return false;
    }
    _terminalProgress = progress;
    _notifyMetadataChanged();
    return true;
  }

  /// Clears active OSC 9;4 progress metadata.
  bool clearTerminalProgress() => synchronizeTerminalProgress(null);

  /// Records visible terminal dimensions used to answer size report queries.
  void updateTerminalWindowMetrics({
    required int columns,
    required int rows,
    required int pixelWidth,
    required int pixelHeight,
  }) => _runtime.updateTerminalWindowMetrics(
    columns: columns,
    rows: rows,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  /// Adds a listener for terminal preview and preview-adjacent metadata changes.
  void addPreviewListener(VoidCallback listener) {
    _previewListeners.add(listener);
  }

  /// Removes a preview listener previously added with [addPreviewListener].
  void removePreviewListener(VoidCallback listener) {
    _previewListeners.remove(listener);
  }

  /// Adds a listener for metadata changes used by the live terminal screen.
  void addMetadataListener(VoidCallback listener) {
    _metadataListeners.add(listener);
  }

  /// Removes a metadata listener previously added with [addMetadataListener].
  void removeMetadataListener(VoidCallback listener) {
    _metadataListeners.remove(listener);
  }

  /// Persist a per-session terminal theme override.
  ///
  /// Returns `true` when the stored theme ID changed.
  bool setTerminalThemeId(String themeId, {required bool isDark}) {
    if (isDark) {
      if (terminalThemeDarkId == themeId) {
        return false;
      }
      terminalThemeDarkId = themeId;
      return true;
    }
    if (terminalThemeLightId == themeId) {
      return false;
    }
    terminalThemeLightId = themeId;
    return true;
  }

  /// Updates the active terminal theme.
  ///
  /// Returns `true` when the theme changed enough to repaint previews.
  bool setTerminalTheme(TerminalThemeData? theme) {
    _configuredTerminalTheme = theme;
    final effectiveTheme = theme == null
        ? null
        : _terminalColorOverrides.applyTo(theme);
    if (_sameTerminalTheme(_terminalTheme, effectiveTheme)) {
      _terminalTheme = effectiveTheme;
      return false;
    }
    _terminalTheme = effectiveTheme;
    _notifyPreviewChanged();
    return true;
  }

  void _recomputeTerminalThemeAfterRemoteColorChange() {
    final configuredTheme = _configuredTerminalTheme;
    _terminalTheme = configuredTheme == null
        ? null
        : _terminalColorOverrides.applyTo(configuredTheme);
  }

  /// Ensure a [Terminal] exists and is wired to the shell streams.
  Terminal getOrCreateTerminal({int maxLines = 10000}) =>
      _runtime.getOrCreateTerminal(maxLines: maxLines);

  /// Active port forward tunnels.
  final Map<int, _ActiveTunnel> _activeTunnels = {};

  final Map<int, ({Future<void> done, _PortForwardOperationKind kind})>
  _portForwardOperations = {};
  final _portForwardChanges = StreamController<void>.broadcast(sync: true);
  final _closeStarted = Completer<void>();
  bool _isClosing = false;
  Timer? _automaticPortForwardTimer;
  SSHSession? _automaticPortForwardWatcherSession;
  // Cancelled in _stopAutomaticPortForwardWatcher().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _automaticPortForwardWatcherStdoutSubscription;
  StringBuffer? _automaticPortForwardWatcherSnapshot;
  Completer<bool>? _automaticPortForwardWatcherReady;
  bool _automaticPortForwardWatcherSnapshotUnavailable = false;
  bool _automaticPortDiscoveryUnavailable = false;
  String? _automaticPortProxyHost;
  int _automaticPortForwardGeneration = 0;
  Future<void>? _automaticPortForwardRefresh;
  Future<void>? _automaticPortForwardSnapshotQueue;
  Future<void> _automaticPortForwardConfiguration = Future<void>.value();
  final Map<RemoteTcpListenerKey, int>
  _automaticPortForwardIdsByRemoteListener = {};
  final Map<RemoteTcpListenerKey, int> _automaticPortForwardMisses = {};
  Set<RemoteTcpListenerKey> _automaticPortForwardExcludedListeners = const {};
  Set<String> _automaticPortForwardShellTokens = const {};
  Set<int> _automaticPortForwardProcessRoots = const {};
  bool _automaticPortForwardIncludeHostLevelListeners = true;
  int _nextAutomaticPortForwardId = -1;

  /// Completes when this SSH session begins closing.
  Future<void> get closed => _closeStarted.future;

  /// Get active tunnel info for display.
  List<ActiveTunnelInfo> get activeTunnels => _activeTunnels.entries
      .map(
        (e) => ActiveTunnelInfo(
          portForwardId: e.key,
          localHost: e.value.localHost,
          localPort: e.value.localPort,
          browserHost: e.value.browserHost,
          browserPort: e.value.browserPort,
          browserFallbackHost: e.value.browserFallbackHost,
          remoteHost: e.value.remoteHost,
          remotePort: e.value.remotePort,
          isLocal: e.value.isLocal,
          isAutomatic: e.value.isAutomatic,
          isShellRelated: e.value.isShellRelated,
        ),
      )
      .toList();

  /// Emits whenever this session starts or stops a port forward.
  Stream<void> get portForwardChanges => _portForwardChanges.stream;

  /// Timeout used while opening local and remote forwarding listeners.
  @visibleForTesting
  Duration get portForwardStartTimeout => _defaultPortForwardStartTimeout;

  /// Interval between automatic remote-listener scans.
  @visibleForTesting
  Duration get automaticPortForwardDiscoveryInterval =>
      const Duration(seconds: 5);

  /// Remote ports currently owned by automatic forwarding.
  @visibleForTesting
  Set<int> get automaticForwardedRemotePorts => Set.unmodifiable(
    _automaticPortForwardIdsByRemoteListener.keys.map((key) => key.port),
  );

  /// Remote listener identities currently owned by automatic forwarding.
  @visibleForTesting
  Set<RemoteTcpListenerKey> get automaticForwardedRemoteListeners =>
      Set.unmodifiable(_automaticPortForwardIdsByRemoteListener.keys);

  /// Whether periodic automatic listener discovery is still scheduled.
  @visibleForTesting
  bool get automaticPortForwardDiscoveryActive =>
      _automaticPortForwardTimer != null;

  /// Whether a persistent automatic listener watcher is active.
  @visibleForTesting
  bool get automaticPortForwardWatcherActive =>
      _automaticPortForwardWatcherSession != null;

  /// Persistent mux pane roots used for shell-owned listener classification.
  Set<int> get automaticPortForwardProcessRoots =>
      Set.unmodifiable(_automaticPortForwardProcessRoots);

  /// Opens a local forwarding listener.
  @visibleForTesting
  Future<ServerSocket> bindPortForwardServerSocket(
    Object host,
    int port, {
    bool v6Only = false,
  }) => ServerSocket.bind(host, port, v6Only: v6Only);

  /// Whether this session owns an active tunnel for [portForwardId].
  bool isPortForwardActive(int portForwardId) =>
      activeTunnels.any((tunnel) => tunnel.portForwardId == portForwardId);

  /// Whether this session is currently starting or replacing [portForwardId].
  bool isPortForwardStarting(int portForwardId) {
    final operation = _portForwardOperations[portForwardId];
    return operation != null &&
        operation.kind != _PortForwardOperationKind.stop &&
        !isPortForwardActive(portForwardId);
  }

  /// Starts a saved [portForward] on this SSH session.
  ///
  /// Dispatches through the public per-type methods so subclasses (including
  /// test fakes) can intercept each forward kind.
  Future<bool> startPortForward(PortForward portForward) {
    switch (portForward.forwardType) {
      case 'local':
        return startLocalForward(
          portForwardId: portForward.id,
          localHost: portForward.localHost,
          localPort: portForward.localPort,
          remoteHost: portForward.remoteHost,
          remotePort: portForward.remotePort,
        );
      case 'remote':
        return startRemoteForward(
          portForwardId: portForward.id,
          remoteHost: portForward.remoteHost,
          remotePort: portForward.remotePort,
          localHost: portForward.localHost,
          localPort: portForward.localPort,
        );
      default:
        return Future<bool>.value(false);
    }
  }

  /// Atomically replaces any active or starting tunnel with [portForward].
  Future<bool> replacePortForward(PortForward portForward) {
    if (_isClosing) {
      return Future<bool>.value(false);
    }
    return _runPortForwardOperation(portForward.id, () async {
      await _stopForward(portForward.id);
      if (_isClosing) {
        return false;
      }
      return _startPortForwardUnlocked(portForward);
    }, kind: _PortForwardOperationKind.replace);
  }

  Future<bool> _startPortForwardUnlocked(PortForward portForward) {
    switch (portForward.forwardType) {
      case 'local':
        return _startLocalForward(
          portForwardId: portForward.id,
          localHost: portForward.localHost,
          localPort: portForward.localPort,
          remoteHost: portForward.remoteHost,
          remotePort: portForward.remotePort,
        );
      case 'remote':
        return _startRemoteForward(
          portForwardId: portForward.id,
          remoteHost: portForward.remoteHost,
          remotePort: portForward.remotePort,
          localHost: portForward.localHost,
          localPort: portForward.localPort,
        );
      default:
        return Future<bool>.value(false);
    }
  }

  /// Get or create a shell session.
  ///
  /// When [command] is provided for a new shell, the foreground PTY runs that
  /// command directly instead of opening an interactive login shell first. If
  /// [returnToLoginShell] is true, completing that command replaces its channel
  /// with an interactive login shell without closing the SSH connection.
  ///
  /// Set [requestPty] to false for commands that already implement their own
  /// terminal protocol and PTY, such as MonkeyMux attach on native Windows.
  /// Avoiding the redundant OpenSSH ConPTY also preserves Kitty APC/DCS bytes.
  Future<SSHSession> getShell({
    SSHPtyConfig? pty,
    bool requestPty = true,
    bool forceNew = false,
    String? command,
    bool returnToLoginShell = false,
  }) => _runtime.getShell(
    pty: pty,
    requestPty: requestPty,
    forceNew: forceNew,
    command: command,
    returnToLoginShell: returnToLoginShell,
  );

  /// Shell stdout as a broadcast stream for screen re-attachment.
  Stream<String> get shellStdoutStream => _runtime.shellStdoutStream;

  /// Shell stderr as a broadcast stream for screen re-attachment.
  Stream<String> get shellStderrStream => _runtime.shellStderrStream;

  /// Shell done event stream for screen re-attachment.
  Stream<void> get shellDoneStream => _runtime.shellDoneStream;

  /// Completion events for startup commands that return to a login shell.
  Stream<void> get shellCommandCompletedStream =>
      _runtime.shellCommandCompletedStream;

  /// Writes text to the currently active shell channel.
  void writeToShell(String data) => _runtime.writeToShell(data);

  /// Records a successfully displayed Kitty notification.
  void markTerminalNotificationPresented(TerminalNotificationRequest request) {
    _terminalNotificationParser.markPresented(request.identifier);
    if (request.reportsClose && _runtime.hasShell) {
      _runtime.writeToShell(
        buildKittyNotificationCloseReport(request.identifier, untracked: true),
      );
    }
  }

  /// Records an identified notification as closed without a protocol report.
  void markTerminalNotificationClosed(String? identifier) =>
      _terminalNotificationParser.markClosed(identifier);

  /// Records a local notification tap and emits the requested activation report.
  ///
  /// A requested close report is already emitted as `untracked` when native
  /// presentation succeeds because platform dismissal callbacks are not
  /// portable. A tap must not later claim that same close was tracked.
  void handleTerminalNotificationActivated(
    String? identifier, {
    required bool reportsActivation,
  }) {
    _terminalNotificationParser.markClosed(identifier);
    if (!reportsActivation || !_runtime.hasShell) return;
    _runtime.writeToShell(buildKittyNotificationActivationReport(identifier));
  }

  /// Resizes the currently active shell channel.
  void resizeShell(int width, int height, int pixelWidth, int pixelHeight) =>
      _runtime.resizeShell(width, height, pixelWidth, pixelHeight);

  /// Close only the interactive shell channel while keeping the SSH client.
  Future<void> closeShell({bool waitForStreams = true}) =>
      _runtime.closeShell(waitForStreams: waitForStreams);

  void _resetShellRuntimeMetadata() {
    final hadMetadata =
        _iconName != null ||
        _workingDirectory != null ||
        _shellStatus != null ||
        _lastExitCode != null ||
        _terminalProgress != null ||
        terminalCommandMarkTracker.markCount > 0 ||
        _windowTitle != null ||
        _terminalColorOverrides.isNotEmpty;
    final hadPreview =
        _terminalPreview != null || _terminalPreviewSnapshot != null;
    terminalHyperlinkTracker.reset(keepTerminalReference: false);
    terminalCommandMarkTracker.reset(keepTerminalReference: false);
    _terminalNotificationParser.reset();
    final hadRemoteColors = _terminalColorOverrides.clear();
    _recomputeTerminalThemeAfterRemoteColorChange();
    _iconName = null;
    _workingDirectory = null;
    _terminalReportedRemoteHost = null;
    _shellStatus = null;
    _lastExitCode = null;
    _terminalProgress = null;
    _terminalPreview = null;
    _terminalPreviewSnapshot = null;
    _windowTitle = null;
    _lastTerminalPaletteQueryAt = null;
    _lastVolunteeredThemeDefaultsAt = null;
    if (hadMetadata || hadRemoteColors) {
      _notifyMetadataChanged();
    } else if (hadPreview) {
      _notifyPreviewChanged();
    }
  }

  DateTime? _lastTerminalPaletteQueryAt;
  DateTime? _lastVolunteeredThemeDefaultsAt;

  /// A color interrogation arrives as a burst of palette queries; volunteer
  /// the default foreground/background reports once per burst rather than
  /// once per query.
  static const _volunteeredThemeDefaultsWindow = Duration(seconds: 1);

  bool _shouldVolunteerThemeDefaults() {
    final now = DateTime.now();
    final last = _lastVolunteeredThemeDefaultsAt;
    if (last != null &&
        now.difference(last) < _volunteeredThemeDefaultsWindow) {
      return false;
    }
    _lastVolunteeredThemeDefaultsAt = now;
    return true;
  }

  void _handleWindowTitleChange(String title) {
    final sanitizedTitle = _sanitizeWindowTitle(title);
    if (sanitizedTitle == _windowTitle) {
      return;
    }
    _windowTitle = sanitizedTitle;
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'window_title_changed',
      fields: {
        'connectionId': connectionId,
        'hasTitle': sanitizedTitle != null,
      },
    );
    _notifyMetadataChanged();
  }

  void _handleIconNameChange(String iconName) {
    final sanitizedIconName = _sanitizeWindowTitle(iconName);
    if (sanitizedIconName == _iconName) {
      return;
    }
    _iconName = sanitizedIconName;
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'icon_name_changed',
      fields: {
        'connectionId': connectionId,
        'hasIcon': sanitizedIconName != null,
      },
    );
    _notifyMetadataChanged();
  }

  void _handlePrivateOsc(String code, List<String> args) {
    final hasThemeQuery = args.any((arg) => arg.trim() == '?');
    if (hasThemeQuery && code == '4') {
      _lastTerminalPaletteQueryAt = DateTime.now();
    }
    if (hasThemeQuery &&
        (code == '4' ||
            code == '10' ||
            code == '11' ||
            code == '12' ||
            code == '17' ||
            code == '19')) {
      DiagnosticsLogService.instance.debug(
        'terminal.osc',
        'theme_query',
        fields: {
          'connectionId': connectionId,
          'code': code,
          'themeId': terminalTheme?.id,
          'hasShell': _runtime.hasShell,
        },
      );
    }

    final colorMutation = _terminalColorOverrides.handle(code, args);
    if (colorMutation.changed) {
      _recomputeTerminalThemeAfterRemoteColorChange();
      DiagnosticsLogService.instance.debug(
        'terminal.osc',
        'palette_changed',
        fields: {'connectionId': connectionId, 'code': code},
      );
      _notifyMetadataChanged();
    }

    final effectiveTheme = terminalTheme;
    final themeOscResponse = effectiveTheme == null
        ? null
        : buildTerminalThemeOscResponse(
            theme: effectiveTheme,
            code: code,
            args: args,
          );
    if (themeOscResponse != null) {
      final shell = _runtime.shell;
      if (shell == null) {
        DiagnosticsLogService.instance.warning(
          'terminal.osc',
          'theme_query_dropped_no_shell',
          fields: {
            'connectionId': connectionId,
            'code': code,
            'themeId': effectiveTheme?.id,
          },
        );
      } else {
        final win32InputMode = _runtime.terminalWin32InputMode;
        var payload = themeOscResponse;
        final volunteersThemeDefaults =
            win32InputMode && code == '4' && _shouldVolunteerThemeDefaults();
        if (volunteersThemeDefaults) {
          payload += buildTerminalThemeDefaultColorReports(effectiveTheme!);
        }
        if (win32InputMode) {
          payload = encodeTerminalResponsesForWin32InputMode(payload);
        }
        shell.write(utf8.encode(payload));
        DiagnosticsLogService.instance.debug(
          'terminal.osc',
          'theme_query_answered',
          fields: {
            'connectionId': connectionId,
            'code': code,
            'themeId': effectiveTheme!.id,
            'responseBytes': payload.length,
            'win32InputMode': win32InputMode,
            'volunteeredThemeDefaults': volunteersThemeDefaults,
          },
        );
      }
    }
    if (themeOscResponse != null || colorMutation.handled) return;

    terminalHyperlinkTracker.handlePrivateOsc(code, args);
    final commandMarkAdded = terminalCommandMarkTracker.handlePrivateOsc(
      code,
      args,
    );
    if (code == '8') {
      return;
    }

    if (code == '7') {
      _setWorkingDirectory(
        parseTerminalWorkingDirectoryUri(args),
        allowClear: true,
      );
      return;
    }

    if (code == '1337') {
      final metrics = _runtime.terminalWindowMetrics;
      final cellPixelWidth = metrics == null || metrics.columns <= 0
          ? null
          : metrics.pixelWidth / metrics.columns;
      final cellPixelHeight = metrics == null || metrics.rows <= 0
          ? null
          : metrics.pixelHeight / metrics.rows;
      final cellSizeResponse = buildIterm2ReportCellSizeResponse(
        args,
        cellWidth: cellPixelWidth,
        cellHeight: cellPixelHeight,
      );
      if (cellSizeResponse != null) {
        if (_runtime.hasShell) _runtime.writeToShell(cellSizeResponse);
        return;
      }
      final attentionRequest = parseIterm2AttentionRequest(args);
      if (attentionRequest != null) {
        if (!_terminalNotifications.isClosed) {
          _terminalNotifications.add(attentionRequest);
        }
        return;
      }
      if (args.firstOrNull == 'SetMark') {
        if (commandMarkAdded) _notifyMetadataChanged();
        return;
      }
      final terminal = _runtime.terminal;
      if (terminal != null &&
          handleIterm2InlineImageOsc(
            terminal,
            args,
            cellPixelWidth: cellPixelWidth,
            cellPixelHeight: cellPixelHeight,
          )) {
        return;
      }
      final nextRemoteHost = parseTerminalReportedRemoteHost(args);
      if (nextRemoteHost != null) {
        _terminalReportedRemoteHost = nextRemoteHost;
        return;
      }
      final nextWorkingDirectory = parseTerminalShellWorkingDirectoryOsc(
        code,
        args,
        remoteHost: _terminalReportedRemoteHost,
      );
      if (nextWorkingDirectory != null) {
        _setWorkingDirectory(nextWorkingDirectory);
        return;
      }
    }

    if (code == ClipboardSharingService.oscCode) {
      _handleOsc52(args);
      return;
    }

    if (code == '133' || code == '633') {
      _handleShellIntegrationOsc(
        code,
        args,
        commandMarkAdded: commandMarkAdded,
      );
      return;
    }

    if (code == '9') {
      if (args.firstOrNull?.trim() == '4') {
        final previousProgress = _terminalProgress;
        final nextProgress = applyTerminalProgressOsc(
          args,
          previousProgress: previousProgress,
        );
        if (nextProgress != previousProgress) {
          _terminalProgress = nextProgress;
          DiagnosticsLogService.instance.debug(
            'terminal.osc',
            'progress_changed',
            fields: {
              'connectionId': connectionId,
              'active': nextProgress != null,
              'state': nextProgress?.state.name,
              'hasPercentage': nextProgress?.percentage != null,
            },
          );
          _notifyMetadataChanged();
        }
        return;
      }
      if (args.firstOrNull?.trim() == '9') {
        _setWorkingDirectory(
          parseTerminalShellWorkingDirectoryOsc(
            code,
            args,
            remoteHost: _terminalReportedRemoteHost,
          ),
        );
        return;
      }
      _handleTerminalNotificationOsc(code, args);
      return;
    }

    if (code == '99') {
      final capabilityResponse = buildKittyNotificationCapabilityResponse(args);
      if (capabilityResponse != null) {
        if (_runtime.hasShell) _runtime.writeToShell(capabilityResponse);
        return;
      }
      final aliveResponse = buildKittyNotificationAliveResponse(
        args,
        _terminalNotificationParser.activeIdentifiers,
      );
      if (aliveResponse != null) {
        if (_runtime.hasShell) _runtime.writeToShell(aliveResponse);
        return;
      }
      _handleTerminalNotificationOsc(code, args);
      return;
    }

    if (code == '777') {
      _handleTerminalNotificationOsc(code, args);
      return;
    }

    _logUnhandledPrivateOsc(code, args);
  }

  void _handleShellIntegrationOsc(
    String code,
    List<String> args, {
    required bool commandMarkAdded,
  }) {
    final nextShellState = applyTerminalShellIntegrationOsc(
      args,
      previousStatus: _shellStatus,
      previousExitCode: _lastExitCode,
    );
    final nextWorkingDirectory = parseTerminalShellWorkingDirectoryOsc(
      code,
      args,
      remoteHost: _terminalReportedRemoteHost,
    );
    final shellStateChanged =
        nextShellState.status != _shellStatus ||
        nextShellState.lastExitCode != _lastExitCode;
    final workingDirectoryChanged =
        nextWorkingDirectory != null &&
        nextWorkingDirectory.toString() != _workingDirectory?.toString();
    if (!shellStateChanged && !workingDirectoryChanged && !commandMarkAdded) {
      return;
    }
    _shellStatus = nextShellState.status;
    _lastExitCode = nextShellState.lastExitCode;
    if (workingDirectoryChanged) {
      _workingDirectory = nextWorkingDirectory;
    }
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'shell_integration_changed',
      fields: {
        'connectionId': connectionId,
        'protocol': code == '633' ? 'vscode' : 'finalterm',
        'shellStatus': nextShellState.status,
        'lastExitCode': nextShellState.lastExitCode,
        'workingDirectoryChanged': workingDirectoryChanged,
      },
    );
    _notifyMetadataChanged();
  }

  bool _setWorkingDirectory(
    Uri? nextWorkingDirectory, {
    bool allowClear = false,
  }) {
    if ((nextWorkingDirectory == null && !allowClear) ||
        nextWorkingDirectory?.toString() == _workingDirectory?.toString()) {
      return false;
    }
    _workingDirectory = nextWorkingDirectory;
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'working_directory_changed',
      fields: {
        'connectionId': connectionId,
        'hasWorkingDirectory': nextWorkingDirectory != null,
      },
    );
    _notifyMetadataChanged();
    return true;
  }

  void _handleTerminalNotificationOsc(String code, List<String> args) {
    final request = _terminalNotificationParser.handleOsc(code, args);
    if (request == null || _terminalNotifications.isClosed) {
      return;
    }
    _terminalNotifications.add(request);
  }

  void _logUnhandledPrivateOsc(String code, List<String> args) {
    DiagnosticsLogService.instance.debug(
      'terminal.osc',
      'unhandled',
      fields: {
        'connectionId': connectionId,
        'oscCode': int.tryParse(code) ?? -1,
        'argCount': args.length,
      },
    );
  }

  void _handleOsc52(List<String> args) {
    if (!clipboardSharingEnabled) return;

    unawaited(
      _clipboardSharingService
          .handleOsc52(args, allowLocalClipboardRead: localClipboardReadEnabled)
          .then((response) {
            if (response != null) {
              _runtime.writeToShell(response);
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            DiagnosticsLogService.instance.warning(
              'ssh.clipboard',
              'osc52_failed',
              fields: {'errorType': error.runtimeType},
            );
            if (kDebugMode) {
              debugPrint('Error handling OSC 52 sequence: $error');
              debugPrint('$stackTrace');
            }
          }),
    );
  }

  /// Builds a plain-text preview from the latest terminal display rows.
  static String? buildTerminalPreview(
    Terminal terminal, {
    int maxLines = _previewLineCount,
    int maxChars = _previewMaxChars,
  }) {
    final effectiveMaxLines = maxLines < 1 ? 1 : maxLines;
    final effectiveMaxChars = maxChars < 1 ? 1 : maxChars;
    final previewLines = <String>[];

    for (
      var index = terminal.lines.length - 1;
      index >= 0 && previewLines.length < effectiveMaxLines;
      index--
    ) {
      final rawLine = terminal.lines[index].getText();
      final cleanedLine = _sanitizePreviewFragment(rawLine);

      if (cleanedLine.isEmpty) {
        continue;
      }

      previewLines.insert(0, cleanedLine);
    }

    if (previewLines.isEmpty) {
      return null;
    }

    var preview = previewLines.join('\n');
    if (preview.length > effectiveMaxChars) {
      preview = '…${preview.substring(preview.length - effectiveMaxChars + 1)}';
    }
    return preview;
  }

  /// Builds a styled preview from the latest terminal display rows.
  static TerminalPreviewSnapshot? buildTerminalPreviewSnapshot(
    Terminal terminal, {
    int maxLines = _previewLineCount,
  }) {
    final effectiveMaxLines = maxLines < 1 ? 1 : maxLines;
    final previewLines = <TerminalPreviewLine>[];
    final visibleRange = _terminalVisiblePreviewRange(
      terminal,
      effectiveMaxLines,
    );
    if (visibleRange == null) {
      return null;
    }

    for (var index = visibleRange.start; index <= visibleRange.end; index++) {
      final sourceLine = terminal.lines[index];
      final rawLine = sourceLine.getText();
      final cleanedLine = _sanitizePreviewFragment(rawLine);

      final cells = BufferLine(
        sourceLine.length,
        isWrapped: sourceLine.isWrapped,
      )..copyFrom(sourceLine, 0, 0, sourceLine.length);
      previewLines.add(TerminalPreviewLine(text: cleanedLine, cells: cells));
    }

    if (previewLines.isEmpty) {
      return null;
    }

    return TerminalPreviewSnapshot(
      lines: List.unmodifiable(previewLines),
      plainText: previewLines.map((line) => line.text).join('\n'),
      images: buildTerminalPreviewImages(
        terminal,
        startRow: visibleRange.start,
        endRow: visibleRange.end,
      ),
    );
  }

  static ({int start, int end})? _terminalVisiblePreviewRange(
    Terminal terminal,
    int maxLines,
  ) {
    final lineCount = terminal.lines.length;
    if (lineCount == 0) {
      return null;
    }
    final visibleStart = math.max(
      0,
      terminal.buffer.height - terminal.viewHeight,
    );
    final visibleEnd = terminal.buffer.height - 1;
    var lastNonEmpty = -1;
    for (var index = visibleEnd; index >= visibleStart; index--) {
      final cleanedLine = _sanitizePreviewFragment(
        terminal.lines[index].getText(),
      );
      if (cleanedLine.isNotEmpty) {
        lastNonEmpty = index;
        break;
      }
    }

    if (lastNonEmpty < 0) {
      return null;
    }
    return (
      start: math.max(visibleStart, lastNonEmpty - maxLines + 1),
      end: lastNonEmpty,
    );
  }

  static String _sanitizePreviewFragment(String text) =>
      text.replaceAll(_previewSanitizerPattern, '').trimRight();

  static String? _sanitizeWindowTitle(String text) {
    final sanitized = text.replaceAll(_windowTitleSanitizerPattern, '').trim();
    return sanitized.isEmpty ? null : sanitized;
  }

  static bool _sameTerminalTheme(
    TerminalThemeData? previous,
    TerminalThemeData? next,
  ) {
    if (previous == null || next == null) {
      return previous == next;
    }
    return terminalThemesMatchForColors(previous, next);
  }

  void _notifyPreviewChanged() {
    for (final listener in _previewListeners.toList(growable: false)) {
      listener();
    }
  }

  void _notifyMetadataChanged() {
    for (final listener in _metadataListeners.toList(growable: false)) {
      listener();
    }
    _notifyPreviewChanged();
  }

  /// Execute a command.
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty}) async {
    DiagnosticsLogService.instance.debug(
      'ssh.exec',
      'open_start',
      fields: {
        'connectionId': connectionId,
        'commandKind': _diagnosticSshCommandKind(command),
        'pty': pty != null,
      },
    );
    try {
      final execSession = await client.execute(command, pty: pty);
      DiagnosticsLogService.instance.debug(
        'ssh.exec',
        'open_success',
        fields: {
          'connectionId': connectionId,
          'commandKind': _diagnosticSshCommandKind(command),
          'pty': pty != null,
        },
      );
      return execSession;
    } on Object catch (error) {
      DiagnosticsLogService.instance.error(
        'ssh.exec',
        'open_failed',
        fields: {
          'connectionId': connectionId,
          'commandKind': _diagnosticSshCommandKind(command),
          'pty': pty != null,
          ..._diagnosticSshExecErrorFields(error),
        },
      );
      _reportConnectionHealthFailureIfClosed(error, operation: 'exec');
      rethrow;
    }
  }

  /// Runs short-lived exec work through this connection's bounded exec queue.
  ///
  /// The callback should open, consume, and close any SSH exec channel it uses.
  /// Long-lived channels such as the interactive shell and tmux control-mode
  /// watcher should not use this queue because they would permanently occupy a
  /// short-command slot.
  Future<T> runQueuedExec<T>(
    Future<T> Function() operation, {
    SshExecPriority priority = SshExecPriority.normal,
  }) => runQueuedSshExec(connectionId, operation, priority: priority);

  /// Enables or disables automatic forwarding for this SSH session.
  Future<void> configureAutomaticPortForwarding({
    required bool enabled,
    String? proxyHost,
    Set<RemoteTcpListenerKey> excludedRemoteListeners = const {},
    Set<String> shellLineageTokens = const {},
    bool includeHostLevelListeners = true,
  }) {
    final operation = _automaticPortForwardConfiguration.then(
      (_) => enabled
          ? _startAutomaticPortForwarding(
              proxyHost,
              excludedRemoteListeners,
              shellLineageTokens,
              includeHostLevelListeners,
            )
          : _stopAutomaticPortForwarding(),
    );
    _automaticPortForwardConfiguration = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Updates persistent mux pane/process roots used for shell-owned detection.
  Future<void> updateAutomaticPortForwardProcessRoots(Set<int> processRoots) {
    final normalizedRoots = Set<int>.unmodifiable(
      processRoots.where((pid) => pid > 0),
    );
    if (setEquals(_automaticPortForwardProcessRoots, normalizedRoots)) {
      return Future<void>.value();
    }
    _automaticPortForwardProcessRoots = normalizedRoots;
    if (_automaticPortProxyHost == null ||
        (_automaticPortForwardWatcherSession == null &&
            _automaticPortForwardTimer == null)) {
      return Future<void>.value();
    }

    final operation = _automaticPortForwardConfiguration.then((_) async {
      if (_isClosing || _automaticPortProxyHost == null) {
        return;
      }
      final generation = ++_automaticPortForwardGeneration;
      _automaticPortForwardTimer?.cancel();
      _automaticPortForwardTimer = null;
      await _stopAutomaticPortForwardWatcher(waitForClose: true);
      await _startAutomaticPortDiscovery(generation);
    });
    _automaticPortForwardConfiguration = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _startAutomaticPortForwarding(
    String? proxyHost,
    Set<RemoteTcpListenerKey> excludedRemoteListeners,
    Set<String> shellLineageTokens,
    bool includeHostLevelListeners,
  ) async {
    if (_isClosing) {
      return;
    }
    final normalizedProxyHost = proxyHost?.trim().toLowerCase();
    if (normalizedProxyHost == null ||
        !normalizedProxyHost.endsWith('.localhost') ||
        validatePortProxyName(normalizedProxyHost) != null) {
      throw ArgumentError.value(
        proxyHost,
        'proxyHost',
        'Must be a valid .localhost domain',
      );
    }
    final normalizedShellTokens = Set<String>.unmodifiable(
      shellLineageTokens.isEmpty ? {shellLineageToken} : shellLineageTokens,
    );
    final sameProxyHost = _automaticPortProxyHost == normalizedProxyHost;
    final shellTokensChanged = !setEquals(
      _automaticPortForwardShellTokens,
      normalizedShellTokens,
    );
    final hostLevelScopeChanged =
        _automaticPortForwardIncludeHostLevelListeners !=
        includeHostLevelListeners;
    final hasActiveDiscovery =
        _automaticPortForwardWatcherSession != null ||
        _automaticPortForwardTimer != null;
    if (_automaticPortProxyHost == normalizedProxyHost &&
        hasActiveDiscovery &&
        !shellTokensChanged &&
        !hostLevelScopeChanged) {
      _automaticPortForwardExcludedListeners = Set.unmodifiable(
        excludedRemoteListeners,
      );
      await refreshAutomaticPortForwards();
      return;
    }

    if (sameProxyHost &&
        hasActiveDiscovery &&
        (shellTokensChanged || hostLevelScopeChanged)) {
      _automaticPortForwardExcludedListeners = Set.unmodifiable(
        excludedRemoteListeners,
      );
      _automaticPortForwardShellTokens = normalizedShellTokens;
      _automaticPortForwardIncludeHostLevelListeners =
          includeHostLevelListeners;
      final generation = ++_automaticPortForwardGeneration;
      _automaticPortForwardTimer?.cancel();
      _automaticPortForwardTimer = null;
      await _stopAutomaticPortForwardWatcher(waitForClose: true);
      await _startAutomaticPortDiscovery(generation);
      return;
    }

    await _stopAutomaticPortForwarding(waitForWatcherClose: true);
    if (_isClosing) {
      return;
    }
    final generation = ++_automaticPortForwardGeneration;
    _automaticPortProxyHost = normalizedProxyHost;
    _automaticPortForwardExcludedListeners = Set.unmodifiable(
      excludedRemoteListeners,
    );
    _automaticPortForwardShellTokens = normalizedShellTokens;
    _automaticPortForwardIncludeHostLevelListeners = includeHostLevelListeners;
    await _startAutomaticPortDiscovery(generation);
  }

  Future<void> _stopAutomaticPortForwarding({
    bool waitForWatcherClose = false,
  }) async {
    _automaticPortForwardGeneration++;
    _automaticPortForwardTimer?.cancel();
    _automaticPortForwardTimer = null;
    await _stopAutomaticPortForwardWatcher(waitForClose: waitForWatcherClose);
    _automaticPortProxyHost = null;
    _automaticPortForwardExcludedListeners = const {};
    _automaticPortForwardShellTokens = const {};
    _automaticPortForwardIncludeHostLevelListeners = true;
    final runningRefresh = _automaticPortForwardRefresh;
    if (runningRefresh != null) {
      await runningRefresh;
    }
    final pendingSnapshot = _automaticPortForwardSnapshotQueue;
    if (pendingSnapshot != null) {
      await pendingSnapshot;
    }
    await _stopAutomaticPortForwards();
  }

  Future<void> _stopAutomaticPortForwards() async {
    final automaticIds = _automaticPortForwardIdsByRemoteListener.values.toList(
      growable: false,
    );
    for (final id in automaticIds) {
      await stopForward(id);
    }
    _automaticPortForwardIdsByRemoteListener.clear();
    _automaticPortForwardMisses.clear();
  }

  Future<void> _startAutomaticPortDiscovery(int generation) async {
    _automaticPortDiscoveryUnavailable = false;
    if (await startAutomaticPortForwardWatcher(generation: generation)) {
      return;
    }
    if (_automaticPortDiscoveryUnavailable ||
        _isClosing ||
        generation != _automaticPortForwardGeneration) {
      return;
    }
    await refreshAutomaticPortForwards();
    if (!_automaticPortDiscoveryUnavailable &&
        !_isClosing &&
        generation == _automaticPortForwardGeneration) {
      _startAutomaticPortForwardPolling(generation);
    }
  }

  void _startAutomaticPortForwardPolling(int generation) {
    if (_automaticPortForwardTimer != null ||
        _automaticPortForwardWatcherSession != null ||
        _isClosing ||
        generation != _automaticPortForwardGeneration) {
      return;
    }
    _automaticPortForwardTimer = Timer.periodic(
      automaticPortForwardDiscoveryInterval,
      (_) => unawaited(refreshAutomaticPortForwards()),
    );
  }

  /// Immediately reconciles detected remote listeners with active forwards.
  @visibleForTesting
  Future<void> refreshAutomaticPortForwards() {
    if (_isClosing || _automaticPortProxyHost == null) {
      return Future<void>.value();
    }
    final runningRefresh = _automaticPortForwardRefresh;
    if (runningRefresh != null) {
      return runningRefresh;
    }

    final generation = _automaticPortForwardGeneration;
    late final Future<void> refresh;
    refresh = _guardAutomaticPortForwardRefresh(generation).whenComplete(() {
      if (identical(_automaticPortForwardRefresh, refresh)) {
        _automaticPortForwardRefresh = null;
      }
    });
    _automaticPortForwardRefresh = refresh;
    return refresh;
  }

  Future<void> _guardAutomaticPortForwardRefresh(int generation) async {
    try {
      await _refreshAutomaticPortForwards(generation);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'automatic_reconcile_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  Future<void> _refreshAutomaticPortForwards(int generation) async {
    Map<RemoteTcpListenerKey, RemoteTcpListener>? detectedListeners;
    try {
      detectedListeners = await discoverRemoteListeningTcpListeners();
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'automatic_discovery_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'errorType': error.runtimeType,
        },
      );
      return;
    }
    if (_isClosing || generation != _automaticPortForwardGeneration) {
      return;
    }
    if (detectedListeners == null) {
      _automaticPortDiscoveryUnavailable = true;
      _automaticPortForwardTimer?.cancel();
      _automaticPortForwardTimer = null;
      await _stopAutomaticPortForwards();
      DiagnosticsLogService.instance.info(
        'ssh.forward',
        'automatic_discovery_unsupported',
        fields: {'connectionId': connectionId, 'hostId': hostId},
      );
      return;
    }
    _automaticPortDiscoveryUnavailable = false;
    await _queueAutomaticPortForwardSnapshot(
      detectedListeners,
      generation: generation,
      removeMissingImmediately: false,
    );
  }

  Future<void> _reconcileAutomaticPortForwards(
    Map<RemoteTcpListenerKey, RemoteTcpListener> detectedListeners, {
    required int generation,
    required bool removeMissingImmediately,
  }) async {
    if (_isClosing || generation != _automaticPortForwardGeneration) {
      return;
    }

    final manualRemoteListeners = _manualListenerExclusions(activeTunnels);
    final blockedListeners = {
      ...manualRemoteListeners,
      ..._automaticPortForwardExcludedListeners,
    };
    final targetListeners =
        Map<RemoteTcpListenerKey, RemoteTcpListener>.fromEntries(
          detectedListeners.entries.where(
            (entry) =>
                entry.value.port != 22 &&
                entry.value.port != config.port &&
                (entry.value.isShellRelated ||
                    _automaticPortForwardIncludeHostLevelListeners) &&
                !blockedListeners.contains(entry.key),
          ),
        );

    for (final entry in _automaticPortForwardIdsByRemoteListener.entries.toList(
      growable: false,
    )) {
      if (blockedListeners.contains(entry.key)) {
        _automaticPortForwardMisses.remove(entry.key);
        await stopForward(entry.value);
        continue;
      }
      final targetListener = targetListeners[entry.key];
      if (targetListener != null) {
        _automaticPortForwardMisses.remove(entry.key);
        final tunnel = _activeTunnels[entry.value];
        if (tunnel != null &&
            tunnel.isShellRelated != targetListener.isShellRelated) {
          tunnel.isShellRelated = targetListener.isShellRelated;
          _notifyPortForwardsChanged();
        }
        continue;
      }
      if (removeMissingImmediately) {
        _automaticPortForwardMisses.remove(entry.key);
        await stopForward(entry.value);
        continue;
      }
      final misses = (_automaticPortForwardMisses[entry.key] ?? 0) + 1;
      if (misses < 2) {
        _automaticPortForwardMisses[entry.key] = misses;
        continue;
      }
      _automaticPortForwardMisses.remove(entry.key);
      await stopForward(entry.value);
    }

    final proxyHost = _automaticPortProxyHost;
    if (proxyHost == null ||
        _isClosing ||
        generation != _automaticPortForwardGeneration) {
      return;
    }
    final sortedTargetEntries = targetListeners.entries.toList()
      ..sort((left, right) {
        final portComparison = left.value.port.compareTo(right.value.port);
        return portComparison != 0
            ? portComparison
            : left.value.host.compareTo(right.value.host);
      });
    for (final targetEntry in sortedTargetEntries) {
      final listenerKey = targetEntry.key;
      if (_automaticPortForwardIdsByRemoteListener.containsKey(listenerKey)) {
        continue;
      }
      final portForwardId = _nextAutomaticPortForwardId--;
      final listener = targetEntry.value;
      final started = await startAutomaticLocalForward(
        portForwardId: portForwardId,
        remoteHost: listener.host,
        remotePort: listener.port,
        proxyHost: proxyHost,
        isShellRelated: listener.isShellRelated,
      );
      if (_isClosing || generation != _automaticPortForwardGeneration) {
        if (started) {
          await stopForward(portForwardId);
        }
        return;
      }
      if (started) {
        _automaticPortForwardIdsByRemoteListener[listenerKey] = portForwardId;
      }
    }
  }

  /// Opens one long-lived remote watcher that emits changed listener snapshots.
  @visibleForTesting
  Future<bool> startAutomaticPortForwardWatcher({
    required int generation,
  }) async {
    final command = buildAutomaticPortForwardWatcherCommand();
    SSHSession watcher;
    try {
      watcher = await execute(command);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'automatic_watcher_open_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
    if (_isClosing || generation != _automaticPortForwardGeneration) {
      await _closeAutomaticPortForwardWatcherSession(watcher);
      return false;
    }

    final ready = Completer<bool>();
    _automaticPortForwardWatcherSession = watcher;
    _automaticPortForwardWatcherReady = ready;
    _automaticPortForwardWatcherSnapshot = null;
    _automaticPortForwardWatcherSnapshotUnavailable = false;
    watcher.stderr.drain<void>().ignore();
    _automaticPortForwardWatcherStdoutSubscription = watcher.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _handleAutomaticPortWatcherLine(
            watcher,
            line,
            generation: generation,
          ),
          onError: (Object error, StackTrace _) =>
              _handleAutomaticPortWatcherEnded(
                watcher,
                generation: generation,
                error: error,
              ),
          onDone: () =>
              _handleAutomaticPortWatcherEnded(watcher, generation: generation),
          cancelOnError: true,
        );
    try {
      final started = await ready.future.timeout(
        _automaticPortWatcherStartTimeout,
      );
      if (started) {
        DiagnosticsLogService.instance.info(
          'ssh.forward',
          'automatic_watcher_started',
          fields: {'connectionId': connectionId, 'hostId': hostId},
        );
        return true;
      }
    } on TimeoutException {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'automatic_watcher_timed_out',
        fields: {'connectionId': connectionId, 'hostId': hostId},
      );
    }
    if (identical(_automaticPortForwardWatcherSession, watcher)) {
      await _stopAutomaticPortForwardWatcher();
    }
    return false;
  }

  /// Builds the persistent remote listener-watcher command for this platform.
  @visibleForTesting
  String buildAutomaticPortForwardWatcherCommand() => remoteIsWindows
      ? _windowsAutomaticPortWatcherCommand()
      : _posixAutomaticPortWatcherCommand();

  void _handleAutomaticPortWatcherLine(
    SSHSession watcher,
    String line, {
    required int generation,
  }) {
    if (!identical(_automaticPortForwardWatcherSession, watcher) ||
        generation != _automaticPortForwardGeneration) {
      return;
    }
    if (line == _automaticPortWatcherSnapshotBeginMarker) {
      _automaticPortForwardWatcherSnapshot = StringBuffer();
      _automaticPortForwardWatcherSnapshotUnavailable = false;
      return;
    }
    if (line == _automaticPortWatcherSnapshotEndMarker) {
      final snapshot = _automaticPortForwardWatcherSnapshot?.toString() ?? '';
      _automaticPortForwardWatcherSnapshot = null;
      if (_automaticPortForwardWatcherSnapshotUnavailable) {
        _automaticPortDiscoveryUnavailable = true;
        _queueAutomaticPortForwardSnapshot(
          const {},
          generation: generation,
          removeMissingImmediately: true,
        );
        final ready = _automaticPortForwardWatcherReady;
        if (ready != null && !ready.isCompleted) {
          ready.complete(false);
        }
        return;
      }
      _automaticPortDiscoveryUnavailable = false;
      final ready = _automaticPortForwardWatcherReady;
      final applied = _queueAutomaticPortForwardSnapshot(
        parseRemoteListeningTcpListeners(snapshot),
        generation: generation,
        removeMissingImmediately: true,
      );
      if (ready != null && !ready.isCompleted) {
        unawaited(
          applied.then<void>(
            (_) {
              if (!ready.isCompleted) {
                ready.complete(true);
              }
            },
            onError: (Object _, StackTrace _) {
              if (!ready.isCompleted) {
                ready.complete(false);
              }
            },
          ),
        );
      }
      return;
    }

    final snapshot = _automaticPortForwardWatcherSnapshot;
    if (snapshot == null) {
      return;
    }
    if (line == _automaticPortDiscoveryUnavailableMarker) {
      _automaticPortForwardWatcherSnapshotUnavailable = true;
    }
    snapshot.writeln(line);
  }

  Future<void> _queueAutomaticPortForwardSnapshot(
    Map<RemoteTcpListenerKey, RemoteTcpListener> listeners, {
    required int generation,
    required bool removeMissingImmediately,
  }) {
    final previous = _automaticPortForwardSnapshotQueue ?? Future<void>.value();
    final operation = previous.then(
      (_) => _reconcileAutomaticPortForwards(
        listeners,
        generation: generation,
        removeMissingImmediately: removeMissingImmediately,
      ),
    );
    late final Future<void> trackedOperation;
    trackedOperation = operation
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            DiagnosticsLogService.instance.warning(
              'ssh.forward',
              'automatic_snapshot_reconcile_failed',
              fields: {
                'connectionId': connectionId,
                'hostId': hostId,
                'errorType': error.runtimeType,
              },
            );
          },
        )
        .whenComplete(() {
          if (identical(_automaticPortForwardSnapshotQueue, trackedOperation)) {
            _automaticPortForwardSnapshotQueue = null;
          }
        });
    _automaticPortForwardSnapshotQueue = trackedOperation;
    return operation;
  }

  void _handleAutomaticPortWatcherEnded(
    SSHSession watcher, {
    required int generation,
    Object? error,
  }) {
    if (!identical(_automaticPortForwardWatcherSession, watcher)) {
      return;
    }
    _automaticPortForwardWatcherSession = null;
    _automaticPortForwardWatcherStdoutSubscription = null;
    _automaticPortForwardWatcherSnapshot = null;
    watcher.close();
    final ready = _automaticPortForwardWatcherReady;
    _automaticPortForwardWatcherReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete(false);
    }
    if (_isClosing ||
        _automaticPortDiscoveryUnavailable ||
        _automaticPortProxyHost == null ||
        generation != _automaticPortForwardGeneration) {
      return;
    }
    DiagnosticsLogService.instance.warning(
      'ssh.forward',
      'automatic_watcher_closed',
      fields: {
        'connectionId': connectionId,
        'hostId': hostId,
        if (error != null) 'errorType': error.runtimeType,
      },
    );
    _startAutomaticPortForwardPolling(generation);
    unawaited(refreshAutomaticPortForwards());
  }

  Future<void> _stopAutomaticPortForwardWatcher({
    bool waitForClose = false,
  }) async {
    final watcher = _automaticPortForwardWatcherSession;
    _automaticPortForwardWatcherSession = null;
    final ready = _automaticPortForwardWatcherReady;
    _automaticPortForwardWatcherReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete(false);
    }
    final subscription = _automaticPortForwardWatcherStdoutSubscription;
    _automaticPortForwardWatcherStdoutSubscription = null;
    _automaticPortForwardWatcherSnapshot = null;
    _automaticPortForwardWatcherSnapshotUnavailable = false;
    await subscription?.cancel();
    if (watcher != null) {
      if (waitForClose) {
        await _closeAutomaticPortForwardWatcherSession(watcher);
      } else {
        watcher.close();
      }
    }
  }

  Future<void> _closeAutomaticPortForwardWatcherSession(
    SSHSession watcher,
  ) async {
    watcher.close();
    try {
      await watcher.done.timeout(_automaticPortWatcherCloseTimeout);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'automatic_watcher_close_wait_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  /// Discovers listening TCP ports and their loopback targets on the remote host.
  ///
  /// Returns null when the remote platform has no supported discovery command.
  @visibleForTesting
  Future<Map<RemoteTcpListenerKey, RemoteTcpListener>?>
  discoverRemoteListeningTcpListeners() async {
    final command = remoteIsWindows
        ? _windowsAutomaticPortDiscoveryCommand()
        : _posixAutomaticPortDiscoveryCommand();
    final output = await runQueuedExec(() async {
      final execSession = await openSshExec(
        execute(command),
        _automaticPortDiscoveryTimeout,
      );
      try {
        execSession.stderr.drain<void>().ignore();
        return await _readAutomaticPortDiscoveryOutput(execSession);
      } finally {
        execSession.close();
      }
    }, priority: SshExecPriority.low);
    if (output.contains(_automaticPortDiscoveryUnavailableMarker)) {
      return null;
    }
    return parseRemoteListeningTcpListeners(output);
  }

  /// Opens an ephemeral loopback tunnel for an automatically detected port.
  @visibleForTesting
  Future<bool> startAutomaticLocalForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String proxyHost,
    required bool isShellRelated,
  }) {
    if (_isClosing) {
      return Future<bool>.value(false);
    }
    return _runPortForwardOperation(
      portForwardId,
      () => _startLocalForward(
        portForwardId: portForwardId,
        localHost: InternetAddress.loopbackIPv4.address,
        localPort: 0,
        remoteHost: remoteHost,
        remotePort: remotePort,
        browserHost: proxyHost,
        isAutomatic: true,
        isShellRelated: isShellRelated,
      ),
      kind: _PortForwardOperationKind.start,
    );
  }

  String _posixAutomaticPortDiscoveryCommand() {
    final script =
        '${_posixAutomaticPortShellPidsCommand()} '
        '${_posixAutomaticPortListenerCommand()} '
        'printf "$_automaticPortDiscoveryDoneMarker\\n"';
    return _wrapPosixShellScript(script);
  }

  String _posixAutomaticPortWatcherCommand() {
    final shellPidsCommand = _posixAutomaticPortShellPidsCommand();
    final listenerCommand = _posixAutomaticPortListenerCommand();
    final script =
        r'''(cat >/dev/null 2>&1; kill -TERM "$$" 2>/dev/null || true) & watcher_guard=$!; trap 'kill "$watcher_guard" 2>/dev/null || true' EXIT; trap 'exit 0' HUP INT TERM; '''
        "previous_set=0; previous=''; "
        'while :; do '
        'snapshot=\$({ $listenerCommand }); '
        r'if [ "$previous_set" -eq 0 ] || [ "$snapshot" != "$previous" ]; then '
        "printf '%s\\n' '$_automaticPortWatcherSnapshotBeginMarker'; "
        '$shellPidsCommand '
        r'if [ -n "$snapshot" ]; then printf "%s\n" "$snapshot"; fi; '
        "printf '%s\\n' '$_automaticPortWatcherSnapshotEndMarker'; "
        r'previous=$snapshot; previous_set=1; '
        'fi; '
        r'case "$snapshot" in '
        '*$_automaticPortDiscoveryUnavailableMarker*) exit 0 ;; '
        'esac; '
        'sleep 0.5 || exit 0; '
        'done';
    return _wrapPosixShellScript(script);
  }

  String _wrapPosixShellScript(String script) =>
      "/bin/sh -c '${script.replaceAll("'", "'\"'\"'")}'";

  String _posixAutomaticPortShellPidsCommand() {
    final shellTokens =
        (_automaticPortForwardShellTokens.isEmpty
                ? {shellLineageToken}
                : _automaticPortForwardShellTokens)
            .toList()
          ..sort();
    final markerPattern = 'MONKEYSSH_SHELL_TOKEN=(${shellTokens.join('|')})';
    final processRoots = _automaticPortForwardProcessRoots.toList()..sort();
    return "marker_pattern='$markerPattern'; "
        "root_pids='${processRoots.join(',')}'; "
        'if [ -d /proc ]; then '
        'for env_path in /proc/[0-9]*/environ; do '
        r'[ -r "$env_path" ] || continue; '
        r'if tr "\000" "\n" < "$env_path" 2>/dev/null | '
        r'grep -Eq "^${marker_pattern}\$"; then '
        r'pid=${env_path#/proc/}; pid=${pid%/environ}; '
        r'root_pids="${root_pids}${root_pids:+,}${pid}"; '
        'fi; done; '
        'else '
        r'for pid in $(ps eww -axo pid=,command= 2>/dev/null | '
        r'''awk -v pattern="$marker_pattern" '$0 ~ ("(^|[[:space:]])" pattern "([[:space:]]|$)") { print $1 }'); do '''
        r'root_pids="${root_pids}${root_pids:+,}${pid}"; '
        'done; fi; '
        r'shell_pids=$root_pids; '
        r'ps_output=$(ps -eo pid=,ppid= 2>/dev/null || true); '
        'changed=1; '
        r'while [ "$changed" -eq 1 ]; do '
        r'changed=0; set -- $ps_output; '
        r'while [ "$#" -ge 2 ]; do '
        r'pid=$1; ppid=$2; shift 2; '
        r'case ",$shell_pids," in '
        r'*",$pid,"*) ;; '
        r'*",$ppid,"*) '
        r'shell_pids="${shell_pids}${shell_pids:+,}${pid}"; changed=1 ;; '
        'esac; '
        'done; '
        'done; '
        'printf "$_automaticPortDiscoveryShellPidsMarker%s\\n" '
        r'"$shell_pids";';
  }

  String _posixAutomaticPortListenerCommand() =>
      'LC_ALL=C; export LC_ALL; '
      'if command -v ss >/dev/null 2>&1 && '
      'ss -H -ltnp 2>/dev/null; then :; '
      'elif command -v lsof >/dev/null 2>&1; then '
      'lsof -nP -iTCP -sTCP:LISTEN -Fpfnt 2>/dev/null; '
      r'lsof_status=$?; '
      r'if [ "$lsof_status" -gt 1 ]; then '
      'printf "$_automaticPortDiscoveryUnavailableMarker\\n"; fi; '
      'elif command -v netstat >/dev/null 2>&1 && '
      '{ netstat -an -p tcp 2>/dev/null || netstat -an 2>/dev/null; }; '
      'then :; '
      'else printf "$_automaticPortDiscoveryUnavailableMarker\\n"; fi;';

  String _windowsAutomaticPortDiscoveryCommand() {
    const body =
        'try{Get-NetTCPConnection -State Listen -ErrorAction Stop | '
        r"Where-Object { $_.LocalAddress -eq '0.0.0.0' -or "
        r"$_.LocalAddress -eq '::' -or $_.LocalAddress -eq '::1' -or "
        r"$_.LocalAddress -like '127.*' } | "
        'Sort-Object LocalPort,LocalAddress -Unique | ForEach-Object { '
        r"[void]$__flOut.AppendLine(('LISTEN ' + $_.LocalAddress + ':' + "
        r'[string]$_.LocalPort)) }} catch { '
        r"[void]$__flOut.AppendLine('__monkeyssh_port_discovery_unavailable__')};"
        r"[void]$__flOut.AppendLine('__monkeyssh_port_discovery_done__');";
    return buildWindowsPowerShellCommand(powerShellUtf8OutputScript(body));
  }

  String _windowsAutomaticPortWatcherCommand() {
    // Windows socket APIs expose owning PIDs but not the inherited environment
    // marker needed to associate descendants with this SSH shell. Keep Windows
    // detections host-level rather than guessing shell ancestry.
    const script = r'''
$ErrorActionPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
$__flUtf8=New-Object System.Text.UTF8Encoding($false)
$__flStream=[System.Console]::OpenStandardOutput()
function __flWrite([string]$value){
  $bytes=$__flUtf8.GetBytes($value+"`n")
  $__flStream.Write($bytes,0,$bytes.Length)
  $__flStream.Flush()
}
$previous=$null
while($true){
  try{
    $lines=@(
      Get-NetTCPConnection -State Listen -ErrorAction Stop |
      Where-Object {
        $_.LocalAddress -eq '0.0.0.0' -or
        $_.LocalAddress -eq '::' -or
        $_.LocalAddress -eq '::1' -or
        $_.LocalAddress -like '127.*'
      } |
      Sort-Object LocalPort,LocalAddress -Unique |
      ForEach-Object { 'LISTEN ' + $_.LocalAddress + ':' + [string]$_.LocalPort }
    )
    $snapshot=[string]::Join("`n",$lines)
  }catch{
    $snapshot='__monkeyssh_port_discovery_unavailable__'
  }
  if($snapshot -ne $previous){
    __flWrite '__monkeyssh_port_snapshot_begin__'
    if($snapshot){__flWrite $snapshot}
    __flWrite '__monkeyssh_port_snapshot_end__'
    $previous=$snapshot
  }
  if($snapshot -eq '__monkeyssh_port_discovery_unavailable__'){break}
  Start-Sleep -Milliseconds 500
}
''';
    return buildWindowsPowerShellCommand(script);
  }

  Future<String> _readAutomaticPortDiscoveryOutput(
    SSHSession execSession,
  ) async {
    final output = StringBuffer();
    await for (final chunk
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .timeout(_automaticPortDiscoveryTimeout)) {
      output.write(chunk);
      final text = output.toString();
      final markerIndex = text.indexOf(_automaticPortDiscoveryDoneMarker);
      if (markerIndex >= 0) {
        return text.substring(0, markerIndex);
      }
    }
    throw StateError('Remote listener scan ended before its completion marker');
  }

  /// Start an SFTP session, sharing the same future while an open is pending.
  Future<SftpClient> sftp() {
    if (_isClosing) {
      return Future<SftpClient>.error(SSHStateError('SSH session is closing'));
    }
    final cachedSftp = _sftpClient;
    if (cachedSftp != null) {
      DiagnosticsLogService.instance.debug(
        'ssh.sftp',
        'reuse_client',
        fields: {'connectionId': connectionId, 'hostId': hostId},
      );
      return Future.value(cachedSftp);
    }

    final inFlight = _sftpClientFuture;
    if (inFlight != null) {
      return inFlight;
    }

    // Share the ownership check with every waiter, not just the caller that
    // initiated the open. A timed-out open may finish after its replacement.
    late final Future<SftpClient> future;
    future = _openSftpClient()
        .then((sftpClient) {
          if (_isClosing || !identical(_sftpClientFuture, future)) {
            _closeSftpClientBestEffort(sftpClient);
            // dartssh2 errors do not implement Exception or Error.
            // ignore: only_throw_errors
            throw SSHStateError('SFTP open was superseded');
          }
          _sftpClient = sftpClient;
          return sftpClient;
        })
        .whenComplete(() {
          if (identical(_sftpClientFuture, future)) {
            _sftpClientFuture = null;
          }
        });
    _sftpClientFuture = future;
    return future;
  }

  /// Open a one-off SFTP client without using the session cache.
  ///
  /// Prefer [sftp] for normal app SFTP work. This exists for flows that must
  /// bypass an in-flight shared SFTP open, such as a prompt-capable MonkeyMux
  /// install superseding a probe-only install.
  Future<SftpClient> openStandaloneSftp() => _openSftpClient();

  /// Abandon a timed-out [sftp] open without invalidating a replacement.
  ///
  /// Pass the original future returned by [sftp], not a timeout wrapper.
  void discardSftpOpen(Future<SftpClient> open) {
    if (identical(_sftpClientFuture, open)) {
      _sftpClientFuture = null;
    }
    // Also release a client that finished opening just before timeout cleanup.
    // Superseded opens close their own late client and reject this callback.
    open.then(discardSftpClient).ignore();
  }

  /// Discard only the supplied SFTP client. A null client is a no-op.
  ///
  /// Use this only when an SFTP operation timed out or failed in a way that may
  /// have left pending requests behind. For an open that timed out before
  /// returning a client, use [discardSftpOpen]. Normal consumers should leave
  /// the session-owned client open so future SFTP work can reuse the channel.
  void discardSftpClient(SftpClient? sftpClient) {
    if (sftpClient == null) {
      return;
    }
    final cachedSftp = _sftpClient;
    if (!identical(sftpClient, cachedSftp)) {
      // A late timeout callback must release its client without invalidating
      // a newer cached client or an in-flight replacement.
      _closeSftpClientBestEffort(sftpClient);
      return;
    }
    _sftpClient = null;
    _sftpClientFuture = null;
    if (cachedSftp != null) {
      _closeSftpClientBestEffort(cachedSftp);
    }
  }

  void _closeSftpClientBestEffort(SftpClient sftpClient) {
    unawaited(
      sftpClient.close().then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          DiagnosticsLogService.instance.warning(
            'ssh.sftp',
            'close_failed',
            fields: {
              'connectionId': connectionId,
              'hostId': hostId,
              'errorType': error.runtimeType,
            },
          );
          if (error is SSHError) {
            _reportConnectionHealthFailureIfClosed(
              error,
              operation: 'sftp_close',
            );
          }
        },
      ),
    );
  }

  Future<SftpClient> _openSftpClient() async {
    DiagnosticsLogService.instance.info(
      'ssh.sftp',
      'open_start',
      fields: {'connectionId': connectionId, 'hostId': hostId},
    );

    for (var attempt = 0; ; attempt += 1) {
      if (_isClosing) {
        // dartssh2 errors do not implement Exception or Error.
        // ignore: only_throw_errors
        throw SSHStateError('SSH session is closing');
      }
      try {
        final sftpClient = await client.sftp();
        if (_isClosing) {
          _closeSftpClientBestEffort(sftpClient);
          // dartssh2 errors do not implement Exception or Error.
          // ignore: only_throw_errors
          throw SSHStateError('SSH session is closing');
        }
        DiagnosticsLogService.instance.info(
          'ssh.sftp',
          'open_success',
          fields: {
            'connectionId': connectionId,
            'hostId': hostId,
            'attempt': attempt + 1,
          },
        );
        return sftpClient;
      } on Object catch (error) {
        final retryDelay = _sftpOpenRetryDelay(error, attempt);
        if (retryDelay != null) {
          DiagnosticsLogService.instance.warning(
            'ssh.sftp',
            'open_retry',
            fields: {
              'connectionId': connectionId,
              'hostId': hostId,
              'attempt': attempt + 1,
              'delayMs': retryDelay.inMilliseconds,
              ..._diagnosticSshExecErrorFields(error),
            },
          );
          await Future<void>.delayed(retryDelay);
          continue;
        }

        DiagnosticsLogService.instance.error(
          'ssh.sftp',
          'open_failed',
          fields: {
            'connectionId': connectionId,
            'hostId': hostId,
            'attempt': attempt + 1,
            ..._diagnosticSshExecErrorFields(error),
          },
        );
        _reportConnectionHealthFailureIfClosed(error, operation: 'sftp');
        rethrow;
      }
    }
  }

  Duration? _sftpOpenRetryDelay(Object error, int attempt) {
    if (attempt >= _sftpOpenRetryDelays.length ||
        !_isTransientSftpOpenError(error)) {
      return null;
    }
    return _sftpOpenRetryDelays[attempt];
  }

  bool _isTransientSftpOpenError(Object error) {
    if (error is! SSHChannelOpenError) {
      return false;
    }
    return error.code == 2 || error.code == 4;
  }

  /// Start a local port forward tunnel.
  ///
  /// Binds to [localHost]:[localPort] and forwards connections to
  /// [remoteHost]:[remotePort] via the SSH connection.
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) {
    if (_isClosing) {
      return Future<bool>.value(false);
    }
    return _runPortForwardOperation(
      portForwardId,
      () => _startLocalForward(
        portForwardId: portForwardId,
        localHost: localHost,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
      ),
      kind: _PortForwardOperationKind.start,
    );
  }

  Future<bool> _startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    String? browserHost,
    bool isAutomatic = false,
    bool isShellRelated = false,
  }) async {
    if (_activeTunnels.containsKey(portForwardId)) {
      return true; // Already running
    }
    final automaticPortForwardId =
        !isAutomatic && isPortForwardLoopbackHost(remoteHost)
        ? _automaticPortForwardIdsByRemoteListener[remoteTcpListenerKey(
            remoteHost,
            remotePort,
          )]
        : null;

    ServerSocket? serverSocket;
    final browserServerSockets = <ServerSocket>[];
    try {
      final primaryServerSocket =
          await _bindPortForwardServerSocketWithCancellation(
            host: localHost,
            port: localPort,
          );
      if (primaryServerSocket == null) {
        return false;
      }
      serverSocket = primaryServerSocket;
      final resolvedBrowserHost =
          browserHost ?? portForwardBrowserHostForPortForwardId(portForwardId);
      final friendlyBrowserAddresses = [
        InternetAddress.loopbackIPv4,
        InternetAddress.loopbackIPv6,
      ];
      final fallbackBrowserAddress = InternetAddress(
        portForwardBrowserFallbackHostForHostId(hostId),
      );
      final browserAddresses = [
        ...friendlyBrowserAddresses,
        fallbackBrowserAddress,
      ];
      for (final address in browserAddresses) {
        if (_listenerSupportsPortForwardBrowserAddress(
          primaryServerSocket,
          address,
        )) {
          continue;
        }
        final browserServerSocket = await _bindPortForwardBrowserListener(
          address: address,
          port: primaryServerSocket.port,
          portForwardId: portForwardId,
        );
        if (browserServerSocket != null) {
          browserServerSockets.add(browserServerSocket);
        }
      }
      final hasBrowserEndpoint =
          friendlyBrowserAddresses.any(
            (address) => _listenerSupportsPortForwardBrowserAddress(
              primaryServerSocket,
              address,
            ),
          ) ||
          browserServerSockets.any(
            (serverSocket) => friendlyBrowserAddresses.any(
              (address) => _listenerSupportsPortForwardBrowserAddress(
                serverSocket,
                address,
              ),
            ),
          );
      final hasBrowserFallbackEndpoint =
          _listenerSupportsPortForwardBrowserAddress(
            primaryServerSocket,
            fallbackBrowserAddress,
          ) ||
          browserServerSockets.any(
            (serverSocket) => _listenerSupportsPortForwardBrowserAddress(
              serverSocket,
              fallbackBrowserAddress,
            ),
          );
      if (_isClosing) {
        for (final browserServerSocket in browserServerSockets) {
          await browserServerSocket.close();
        }
        await primaryServerSocket.close();
        return false;
      }
      final tunnel = _ActiveTunnel.local(
        serverSocket: primaryServerSocket,
        browserServerSockets: browserServerSockets,
        browserHost: hasBrowserEndpoint ? resolvedBrowserHost : null,
        browserPort: hasBrowserEndpoint ? primaryServerSocket.port : null,
        browserFallbackHost: hasBrowserFallbackEndpoint
            ? fallbackBrowserAddress.address
            : null,
        localHost: localHost,
        localPort: primaryServerSocket.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
        isAutomatic: isAutomatic,
        isShellRelated: isShellRelated,
      );

      _activeTunnels[portForwardId] = tunnel;

      tunnel.subscription = _listenToLocalForwardConnections(
        primaryServerSocket,
        tunnel: tunnel,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
      for (final browserServerSocket in browserServerSockets) {
        tunnel.browserSubscriptions.add(
          _listenToLocalForwardConnections(
            browserServerSocket,
            tunnel: tunnel,
            remoteHost: remoteHost,
            remotePort: remotePort,
          ),
        );
      }

      if (automaticPortForwardId != null) {
        try {
          await _stopForward(automaticPortForwardId);
        } on Exception catch (error) {
          DiagnosticsLogService.instance.warning(
            'ssh.forward',
            'automatic_replacement_cleanup_failed',
            fields: {
              'connectionId': connectionId,
              'hostId': hostId,
              'errorType': error.runtimeType,
            },
          );
        }
      }
      _notifyPortForwardsChanged();
      return true;
    } on Exception catch (e) {
      final removedActiveTunnel = _activeTunnels.remove(portForwardId) != null;
      for (final browserServerSocket in browserServerSockets) {
        await browserServerSocket.close();
      }
      await serverSocket?.close();
      if (removedActiveTunnel) {
        _notifyPortForwardsChanged();
      }
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'local_start_failed',
        fields: {'errorType': e.runtimeType},
      );
      if (kDebugMode) {
        debugPrint('Failed to start local forward: $e');
      }
      return false;
    }
  }

  bool _listenerSupportsPortForwardBrowserAddress(
    ServerSocket serverSocket,
    InternetAddress browserAddress,
  ) {
    final address = serverSocket.address;
    final wildcardAddress = switch (browserAddress.type) {
      InternetAddressType.IPv4 => InternetAddress.anyIPv4,
      InternetAddressType.IPv6 => InternetAddress.anyIPv6,
      _ => null,
    };
    return address.type == browserAddress.type &&
        (address.address == browserAddress.address ||
            address.address == wildcardAddress?.address);
  }

  Future<ServerSocket?> _bindPortForwardBrowserListener({
    required InternetAddress address,
    required int port,
    required int portForwardId,
  }) async {
    try {
      return await _bindPortForwardServerSocketWithCancellation(
        host: address,
        port: port,
        v6Only: address.type == InternetAddressType.IPv6,
      );
    } on SocketException catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'browser_listener_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'portForwardId': portForwardId,
          'addressFamily': address.type.name,
          'errorType': error.runtimeType,
        },
      );
      return null;
    } on TimeoutException catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'browser_listener_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'portForwardId': portForwardId,
          'addressFamily': address.type.name,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  Future<ServerSocket?> _bindPortForwardServerSocketWithCancellation({
    required Object host,
    required int port,
    bool v6Only = false,
  }) async {
    final request = bindPortForwardServerSocket(host, port, v6Only: v6Only);
    late final ({bool cancelled, ServerSocket? serverSocket}) outcome;
    try {
      outcome =
          await Future.any<({bool cancelled, ServerSocket? serverSocket})>([
            request.then(
              (serverSocket) => (cancelled: false, serverSocket: serverSocket),
            ),
            _closeStarted.future.then(
              (_) => (cancelled: true, serverSocket: null),
            ),
          ]).timeout(portForwardStartTimeout);
    } on TimeoutException {
      _closeLateServerSocket(request);
      rethrow;
    }
    if (outcome.cancelled) {
      _closeLateServerSocket(request);
      return null;
    }
    return outcome.serverSocket;
  }

  void _closeLateServerSocket(Future<ServerSocket> request) {
    unawaited(
      request.then<void>(
        (serverSocket) => serverSocket.close(),
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  StreamSubscription<Socket> _listenToLocalForwardConnections(
    ServerSocket serverSocket, {
    required _ActiveTunnel tunnel,
    required String remoteHost,
    required int remotePort,
  }) => serverSocket.listen(
    (socket) {
      final connection = _handleLocalForwardConnection(
        socket,
        tunnel: tunnel,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
      tunnel.localConnections.add(connection);
      unawaited(
        connection.whenComplete(() {
          tunnel.localConnections.remove(connection);
        }),
      );
    },
    onError: (Object error, StackTrace stackTrace) {
      _logLocalForwardFailure(error);
    },
  );

  void _logLocalForwardFailure(Object error) {
    DiagnosticsLogService.instance.warning(
      'ssh.forward',
      'local_connection_failed',
      fields: {
        'connectionId': connectionId,
        'hostId': hostId,
        ..._diagnosticSshExecErrorFields(error),
      },
    );
    _reportConnectionHealthFailureIfClosed(error, operation: 'forward_local');
  }

  void _destroyLocalForwardChannel(SSHForwardChannel channel) {
    try {
      channel.destroy();
    } on SSHError catch (error) {
      _logLocalForwardFailure(error);
    }
  }

  Future<void> _handleLocalForwardConnection(
    Socket socket, {
    required _ActiveTunnel tunnel,
    required String remoteHost,
    required int remotePort,
  }) async {
    try {
      await _relayForward(
        socket,
        () => _isClosing || tunnel.stopped.isCompleted
            ? null
            : client.forwardLocal(remoteHost, remotePort),
        stopped: tunnel.stopped.future,
        openTimeout: portForwardStartTimeout,
        destroyChannel: _destroyLocalForwardChannel,
      );
    } on Object catch (error) {
      if (error is! SSHError &&
          error is! Exception &&
          !_isClosedForwardSinkError(error)) {
        rethrow;
      }
      _logLocalForwardFailure(error);
    }
  }

  /// Start a remote port forward tunnel.
  ///
  /// Binds to [remoteHost]:[remotePort] on the SSH server and forwards
  /// incoming connections to [localHost]:[localPort] on this device.
  Future<bool> startRemoteForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String localHost,
    required int localPort,
  }) {
    if (_isClosing) {
      return Future<bool>.value(false);
    }
    return _runPortForwardOperation(
      portForwardId,
      () => _startRemoteForward(
        portForwardId: portForwardId,
        remoteHost: remoteHost,
        remotePort: remotePort,
        localHost: localHost,
        localPort: localPort,
      ),
      kind: _PortForwardOperationKind.start,
    );
  }

  Future<bool> _startRemoteForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String localHost,
    required int localPort,
  }) async {
    if (_activeTunnels.containsKey(portForwardId)) {
      return true;
    }

    SSHRemoteForward? remoteForward;
    try {
      final request = client.forwardRemote(host: remoteHost, port: remotePort);
      late final ({bool cancelled, SSHRemoteForward? remoteForward}) outcome;
      try {
        outcome =
            await Future.any<
                  ({bool cancelled, SSHRemoteForward? remoteForward})
                >([
                  request.then(
                    (forward) => (cancelled: false, remoteForward: forward),
                  ),
                  _closeStarted.future.then(
                    (_) => (cancelled: true, remoteForward: null),
                  ),
                ])
                .timeout(portForwardStartTimeout);
      } on TimeoutException {
        _closeLateRemoteForward(request);
        rethrow;
      }
      if (outcome.cancelled) {
        _closeLateRemoteForward(request);
        return false;
      }
      remoteForward = outcome.remoteForward;
      if (remoteForward == null) {
        return false;
      }
      if (_isClosing) {
        remoteForward.close();
        return false;
      }

      final tunnel = _ActiveTunnel.remote(
        remoteForward: remoteForward,
        localHost: localHost,
        localPort: localPort,
        remoteHost: remoteForward.host,
        remotePort: remoteForward.port,
      );

      _activeTunnels[portForwardId] = tunnel;
      tunnel.subscription = remoteForward.connections.listen((channel) async {
        Socket? socket;
        try {
          socket = await Socket.connect(localHost, localPort);
          await _relayForward(socket, () => channel);
        } on Object catch (e) {
          if (e is! Exception &&
              e is! SSHError &&
              !_isClosedForwardSinkError(e)) {
            rethrow;
          }
          DiagnosticsLogService.instance.warning(
            'ssh.forward',
            'remote_connection_failed',
            fields: {'errorType': e.runtimeType},
          );
          if (kDebugMode) {
            debugPrint('Remote forward connection error: $e');
          }
        } finally {
          if (socket == null) {
            try {
              channel.destroy();
            } on SSHError catch (_) {
              // The transport may already be closed during channel teardown.
            }
          }
          try {
            socket?.destroy();
          } on Exception catch (_) {
            // Ignore cleanup errors.
          }
        }
      });

      _notifyPortForwardsChanged();
      return true;
    } on SSHError catch (e) {
      final removedActiveTunnel = _activeTunnels.remove(portForwardId) != null;
      remoteForward?.close();
      if (removedActiveTunnel) {
        _notifyPortForwardsChanged();
      }
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'remote_start_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          ..._diagnosticSshExecErrorFields(e),
        },
      );
      _reportConnectionHealthFailureIfClosed(e, operation: 'forward_remote');
      if (kDebugMode) {
        debugPrint('Failed to start remote forward: $e');
      }
      return false;
    } on Exception catch (e) {
      final removedActiveTunnel = _activeTunnels.remove(portForwardId) != null;
      remoteForward?.close();
      if (removedActiveTunnel) {
        _notifyPortForwardsChanged();
      }
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'remote_start_failed',
        fields: {'errorType': e.runtimeType},
      );
      if (kDebugMode) {
        debugPrint('Failed to start remote forward: $e');
      }
      return false;
    }
  }

  void _closeLateRemoteForward(Future<SSHRemoteForward?> request) {
    unawaited(
      request.then<void>(
        (remoteForward) => remoteForward?.close(),
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  /// Stop a specific port forward tunnel.
  Future<void> stopForward(int portForwardId) => _runPortForwardOperation(
    portForwardId,
    () => _stopForward(portForwardId),
    kind: _PortForwardOperationKind.stop,
  );

  Future<void> _stopForward(int portForwardId) async {
    for (final entry in _automaticPortForwardIdsByRemoteListener.entries.toList(
      growable: false,
    )) {
      if (entry.value == portForwardId) {
        _automaticPortForwardIdsByRemoteListener.remove(entry.key);
        _automaticPortForwardMisses.remove(entry.key);
      }
    }
    final tunnel = _activeTunnels.remove(portForwardId);
    if (tunnel != null) {
      tunnel.stopped.complete();
      await tunnel.subscription?.cancel();
      for (final browserSubscription in tunnel.browserSubscriptions) {
        await browserSubscription.cancel();
      }
      await tunnel.serverSocket?.close();
      for (final browserServerSocket in tunnel.browserServerSockets) {
        await browserServerSocket.close();
      }
      tunnel.remoteForward?.close();
      await Future.wait(tunnel.localConnections);
      _notifyPortForwardsChanged();
    }
  }

  /// Stop all port forward tunnels.
  Future<void> stopAllForwards() async {
    final portForwardIds = {
      ..._activeTunnels.keys,
      ..._portForwardOperations.keys,
    };
    for (final id in portForwardIds) {
      await stopForward(id);
    }
  }

  Future<T> _runPortForwardOperation<T>(
    int portForwardId,
    Future<T> Function() operation, {
    required _PortForwardOperationKind kind,
  }) async {
    while (true) {
      final pendingOperation = _portForwardOperations[portForwardId];
      if (pendingOperation == null) {
        break;
      }
      await pendingOperation.done;
    }

    final gate = Completer<void>();
    final gateFuture = gate.future;
    _portForwardOperations[portForwardId] = (done: gateFuture, kind: kind);
    try {
      return await operation();
    } finally {
      if (identical(_portForwardOperations[portForwardId]?.done, gateFuture)) {
        final removedOperation = _portForwardOperations.remove(portForwardId);
        unawaited(removedOperation?.done);
      }
      gate.complete();
    }
  }

  void _notifyPortForwardsChanged() {
    if (!_portForwardChanges.isClosed) {
      _portForwardChanges.add(null);
    }
  }

  /// Close the session.
  Future<void> close() async {
    _isClosing = true;
    if (!_closeStarted.isCompleted) {
      _closeStarted.complete();
    }
    _automaticPortForwardGeneration++;
    _automaticPortForwardTimer?.cancel();
    _automaticPortForwardTimer = null;
    _automaticPortProxyHost = null;
    _automaticPortForwardExcludedListeners = const {};
    _automaticPortForwardShellTokens = const {};
    _automaticPortForwardProcessRoots = const {};
    _automaticPortForwardIncludeHostLevelListeners = true;
    await _stopAutomaticPortForwardWatcher();
    final pendingSnapshot = _automaticPortForwardSnapshotQueue;
    if (pendingSnapshot != null) {
      await pendingSnapshot;
    }
    await stopAllForwards();
    await closeShell();
    _sftpClientFuture = null;
    discardSftpClient(_sftpClient);
    await _portForwardChanges.close();
    await _connectionHealthFailures.close();
    await _terminalNotifications.close();
    await _closeSshClients(client, dependentClients);
  }

  void _reportConnectionHealthFailureIfClosed(
    Object error, {
    required String operation,
  }) {
    final reason = _diagnosticClosedSshConnectionErrorReason(error);
    if (reason == null ||
        _connectionHealthFailureReported ||
        _connectionHealthFailures.isClosed) {
      return;
    }
    _connectionHealthFailureReported = true;
    DiagnosticsLogService.instance.warning(
      'ssh.session',
      'stale_connection_detected',
      fields: {
        'connectionId': connectionId,
        'hostId': hostId,
        'operation': operation,
        'reason': reason,
        'errorType': error.runtimeType,
      },
    );
    _connectionHealthFailures.add(
      _SshConnectionHealthFailure(
        connectionId: connectionId,
        message: 'Connection became unresponsive. Reconnect to continue.',
      ),
    );
  }
}

/// Whether [session] is backed by MonkeySSH's in-app App Review demo transport.
bool isAppReviewDemoSession(SshSession session) =>
    session.client is _AppReviewDemoSshClient;

/// Writes synthetic remote output into the App Review demo terminal, if active.
void writeAppReviewDemoTerminalOutput(
  SshSession session,
  String text, {
  bool replaceScreen = false,
  bool showPrompt = true,
}) {
  if (!isAppReviewDemoSession(session)) {
    return;
  }
  final shell = session._runtime.shell;
  if (shell is _AppReviewDemoSshSession) {
    shell.writeDemoOutput(
      text,
      replaceScreen: replaceScreen,
      showPrompt: showPrompt,
    );
  }
}

String? _activeNativeAcpConnectionTitle(SshSession session) {
  if (session.activeNativeAcpSessionKey == null) {
    return null;
  }
  final title = session.activeNativeAcpDisplayTitle?.trim();
  return [
    if (title != null && title.isNotEmpty) title else 'Native agent',
    'native',
  ].join(' · ');
}

class _SshConnectionHealthFailure {
  const _SshConnectionHealthFailure({
    required this.connectionId,
    required this.message,
  });

  final int connectionId;
  final String message;
}

/// Lightweight active connection metadata for UI.
class ActiveConnection {
  /// Creates a new [ActiveConnection].
  const ActiveConnection({
    required this.connectionId,
    required this.hostId,
    required this.state,
    required this.createdAt,
    required this.config,
    this.preview,
    this.previewSnapshot,
    this.nativeAcpPreviewSnapshot,
    this.terminalTheme,
    this.sessionTitle,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.remoteMuxBackend,
    this.remoteMuxSessionName,
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
  });

  /// Connection identifier.
  final int connectionId;

  /// Host identifier.
  final int hostId;

  /// Current connection state.
  final SshConnectionState state;

  /// When this connection was opened.
  final DateTime createdAt;

  /// SSH endpoint details.
  final SshConnectionConfig config;

  /// The latest terminal preview snippet, when available.
  final String? preview;

  /// The latest styled terminal preview snippet, when available.
  final TerminalPreviewSnapshot? previewSnapshot;

  /// Role-aware native-agent preview, when a native window is focused.
  final AcpNativePreviewSnapshot? nativeAcpPreviewSnapshot;

  /// The active terminal theme resolved for this connection.
  final TerminalThemeData? terminalTheme;

  /// The active coding-agent session title, when available.
  final String? sessionTitle;

  /// The latest remote window title, when available.
  final String? windowTitle;

  /// The latest remote icon name, when available.
  final String? iconName;

  /// The latest terminal working-directory URI, when available.
  final Uri? workingDirectory;

  /// The latest shell integration status, when available.
  final TerminalShellStatus? shellStatus;

  /// The latest command exit code emitted through shell integration.
  final int? lastExitCode;

  /// The terminal multiplexer backend attached in this connection, if known.
  final RemoteMuxBackend? remoteMuxBackend;

  /// The terminal multiplexer session attached in this connection, if known.
  final String? remoteMuxSessionName;

  /// Session-specific light theme override.
  final String? terminalThemeLightId;

  /// Session-specific dark theme override.
  final String? terminalThemeDarkId;
}

/// Info about an active tunnel for UI display.
class ActiveTunnelInfo {
  /// Creates tunnel info.
  const ActiveTunnelInfo({
    required this.portForwardId,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.isLocal,
    this.isAutomatic = false,
    this.isShellRelated = false,
    this.browserHost,
    this.browserPort,
    this.browserFallbackHost,
  });

  /// The saved or internal runtime identifier for this port forward.
  final int portForwardId;

  /// The local host configured for the tunnel.
  final String localHost;

  /// The local port being listened on.
  final int localPort;

  /// Browser-only loopback host that isolates this tunnel's cookies.
  final String? browserHost;

  /// Port exposed through the browser-only loopback host.
  final int? browserPort;

  /// DNS-independent, saved-host-scoped loopback fallback.
  final String? browserFallbackHost;

  /// The remote host being forwarded to.
  final String remoteHost;

  /// The remote port being forwarded to.
  final int remotePort;

  /// Whether this is a local (true) or remote (false) forward.
  final bool isLocal;

  /// Whether this tunnel was created by remote-listener discovery.
  final bool isAutomatic;

  /// Whether the listener process inherited this connection's shell marker.
  final bool isShellRelated;
}

class _ActiveTunnel {
  _ActiveTunnel.local({
    required this.serverSocket,
    required this.browserServerSockets,
    required this.browserHost,
    required this.browserPort,
    required this.browserFallbackHost,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.isAutomatic,
    required this.isShellRelated,
  }) : remoteForward = null,
       isLocal = true;

  _ActiveTunnel.remote({
    required this.remoteForward,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  }) : serverSocket = null,
       browserServerSockets = const [],
       browserHost = null,
       browserPort = null,
       browserFallbackHost = null,
       isAutomatic = false,
       isShellRelated = false,
       isLocal = false;

  final stopped = Completer<void>();
  final localConnections = <Future<void>>{};
  final ServerSocket? serverSocket;
  final List<ServerSocket> browserServerSockets;
  final SSHRemoteForward? remoteForward;
  final String localHost;
  final int localPort;
  final String? browserHost;
  final int? browserPort;
  final String? browserFallbackHost;
  final String remoteHost;
  final int remotePort;
  final bool isLocal;
  final bool isAutomatic;
  bool isShellRelated;
  // Cancelled in SshSession.stopForward().
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? subscription;
  final List<StreamSubscription<dynamic>> browserSubscriptions = [];
}

class _AppReviewDemoSshClient implements SSHClient {
  _AppReviewDemoSshClient(this.host);

  final Host host;
  final _done = Completer<void>();
  bool _isClosed = false;
  _AppReviewDemoSftpClient? _sftp;

  @override
  String? get remoteVersion => 'SSH-2.0-MonkeySSH_App_Review_Demo';

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  String get username => host.username;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => _AppReviewDemoSshSession.interactive(host);

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    if (pty != null && _looksLikeLoginShellCommand(command)) {
      return _AppReviewDemoSshSession.interactive(host);
    }
    return _AppReviewDemoSshSession.completed(_demoExecOutput(command));
  }

  @override
  Future<SftpClient> sftp() async => _sftp ??= _AppReviewDemoSftpClient();

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async => _AppReviewDemoForwardChannel(
    remoteHost: remoteHost,
    remotePort: remotePort,
  );

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async => null;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async => Uint8List.fromList(utf8.encode(_demoExecOutput(command)));

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final output = Uint8List.fromList(utf8.encode(_demoExecOutput(command)));
    return SSHRunResult(
      output: output,
      stdout: stdout ? output : Uint8List(0),
      stderr: Uint8List(0),
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    await _sftp?.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  static bool _looksLikeLoginShellCommand(String command) =>
      command.contains('COLORTERM=truecolor') ||
      command.contains('TERM_PROGRAM=kitty') ||
      command.contains('/bin/sh -lc');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSshSession implements SSHSession {
  _AppReviewDemoSshSession._({required this.exitCode})
    : _stdinController = StreamController<Uint8List>(),
      _stdoutController = StreamController<Uint8List>(),
      _stderrController = StreamController<Uint8List>() {
    _stdinSubscription = _stdinController.stream.listen(_handleInput);
  }

  factory _AppReviewDemoSshSession.interactive(Host host) {
    final session = _AppReviewDemoSshSession._(exitCode: null);
    scheduleMicrotask(() {
      session
        .._writeText(_demoInteractiveBanner(host))
        .._writePrompt();
    });
    return session;
  }

  factory _AppReviewDemoSshSession.completed(String stdout) {
    final session = _AppReviewDemoSshSession._(exitCode: 0);
    scheduleMicrotask(() async {
      if (stdout.isNotEmpty) {
        session._writeText(stdout);
      }
      await session._finish(exitCode: 0);
    });
    return session;
  }

  @override
  final int? exitCode;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  late final StreamSubscription<Uint8List> _stdinSubscription;
  final StreamController<Uint8List> _stdinController;
  final StreamController<Uint8List> _stdoutController;
  final StreamController<Uint8List> _stderrController;
  final _done = Completer<void>();
  final _exitCompleter = Completer<int?>();
  final _input = StringBuffer();
  bool _closed = false;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (!_closed) {
      _handleInput(data);
    }
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  void close() {
    unawaited(_finish(exitCode: exitCode));
  }

  @override
  Future<int?> waitForExit({Duration? timeout}) {
    final future = _exitCompleter.future;
    return timeout == null
        ? future
        : future.timeout(timeout, onTimeout: () => null);
  }

  @override
  void kill(SSHSignal signal) {
    _writeText('^C\r\n');
    close();
  }

  void _handleInput(Uint8List data) {
    if (_closed) {
      return;
    }
    final text = utf8.decode(data, allowMalformed: true);
    for (var i = 0; i < text.length; i += 1) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 0x03) {
        _input.clear();
        _writeText('^C\r\n');
        _writePrompt();
        continue;
      }
      if (codeUnit == 0x04) {
        close();
        continue;
      }
      if (codeUnit == 0x7F || codeUnit == 0x08) {
        final current = _input.toString();
        if (current.isNotEmpty) {
          _input
            ..clear()
            ..write(current.substring(0, current.length - 1));
          _writeText('\b \b');
        }
        continue;
      }
      if (codeUnit == 0x0D || codeUnit == 0x0A) {
        final command = _input.toString().trim();
        _input.clear();
        _writeText('\r\n');
        _runInteractiveCommand(command);
        if (!_closed) {
          _writePrompt();
        }
        continue;
      }
      if (codeUnit == 0x1B) {
        continue;
      }
      final char = String.fromCharCode(codeUnit);
      _input.write(char);
      _writeText(char);
    }
  }

  void _runInteractiveCommand(String command) {
    if (command.isEmpty) {
      return;
    }
    final normalized = command.toLowerCase();
    if (normalized == 'clear') {
      _writeText('\x1b[2J\x1b[H');
      return;
    }
    if (normalized == 'exit' || normalized == 'logout') {
      _writeText('logout\r\n');
      close();
      return;
    }
    _writeText(_demoInteractiveCommandOutput(command));
  }

  void _writePrompt() {
    _writeText(r'reviewer@demo:~/demo$ ');
  }

  void _writeText(String text) {
    if (_closed || _stdoutController.isClosed) {
      return;
    }
    _stdoutController.add(
      Uint8List.fromList(utf8.encode(_normalizeDemoTerminalOutput(text))),
    );
  }

  void writeDemoOutput(
    String text, {
    bool replaceScreen = false,
    bool showPrompt = true,
  }) {
    if (_closed) {
      return;
    }
    if (replaceScreen) {
      _writeText('\x1b[2J\x1b[H$text');
    } else {
      _writeText('\r\n$text');
    }
    if (showPrompt && !text.endsWith('\n') && !text.endsWith('\r')) {
      _writeText('\r\n');
    }
    if (showPrompt) {
      _writePrompt();
    }
  }

  Future<void> _finish({int? exitCode}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stdinSubscription.cancel();
    await _stdinController.close();
    await _stdoutController.close();
    await _stderrController.close();
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(exitCode);
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSftpClient implements SftpClient {
  _AppReviewDemoSftpClient();

  static const _home = '/home/reviewer';
  static const _workspace = '/home/reviewer/work/monkeyssh-demo';
  final _files = <String, Uint8List>{
    for (final entry in _demoSftpFiles.entries)
      entry.key: Uint8List.fromList(utf8.encode(entry.value)),
  };
  bool _closed = false;

  @override
  Future<SftpHandsake> get handshake =>
      Future<SftpHandsake>.value(SftpHandsake(3, const {}));

  @override
  Future<String> absolute(String path) async => _normalizeDemoSftpPath(path);

  @override
  Future<List<SftpName>> listdir(String path) async {
    final directory = _normalizeDemoSftpPath(path);
    final entries = <SftpName>[];
    for (final child in _demoSftpDirectoryChildren(directory, _files.keys)) {
      final childPath = _joinDemoSftpPath(directory, child);
      final isDirectory = _demoSftpDirectories.contains(childPath);
      entries.add(
        SftpName(
          filename: child,
          longname: child,
          attr: isDirectory
              ? _demoDirectoryAttrs()
              : _demoFileAttrs(_files[childPath]?.length ?? 0),
        ),
      );
    }
    return entries;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final normalized = _normalizeDemoSftpPath(path);
    if (_demoSftpDirectories.contains(normalized)) {
      return _demoDirectoryAttrs();
    }
    final content = _files[normalized];
    if (content != null) {
      return _demoFileAttrs(content.length);
    }
    throw StateError('No such file: $path');
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    final normalized = _normalizeDemoSftpPath(path);
    if ((mode.flag & SftpFileOpenMode.truncate.flag) != 0) {
      _files[normalized] = Uint8List(0);
    } else {
      _files.putIfAbsent(normalized, () => Uint8List(0));
    }
    return _AppReviewDemoSftpFile(
      attrs: _demoFileAttrs(_files[normalized]!.length),
      readContent: () => _files[normalized] ?? Uint8List(0),
      writeContent: (value) => _files[normalized] = Uint8List.fromList(value),
    );
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {}

  @override
  Future<void> rmdir(String dirname) async {}

  @override
  Future<void> remove(String filename) async {
    _files.remove(_normalizeDemoSftpPath(filename));
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final oldNormalized = _normalizeDemoSftpPath(oldPath);
    final content = _files.remove(oldNormalized);
    if (content != null) {
      _files[_normalizeDemoSftpPath(newPath)] = content;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (_closed) {
      throw StateError('Connection closed');
    }
    return super.noSuchMethod(invocation);
  }
}

class _AppReviewDemoSftpFile implements SftpFile {
  _AppReviewDemoSftpFile({
    required SftpFileAttrs attrs,
    required Uint8List Function() readContent,
    required void Function(Uint8List value) writeContent,
  }) : _attrs = attrs,
       _readContent = readContent,
       _writeContent = writeContent;

  final Uint8List Function() _readContent;
  final void Function(Uint8List value) _writeContent;
  SftpFileAttrs _attrs;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<SftpFileAttrs> stat() async {
    _ensureOpen();
    return _attrs;
  }

  void _ensureOpen() {
    if (_isClosed) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpError('File is closed');
    }
  }

  @override
  Future<void> setStat(SftpFileAttrs attrs) async {
    _ensureOpen();
    final size = attrs.size;
    if (size != null) {
      if (size < 0) {
        // ignore: only_throw_errors
        throw SftpError('File size must not be negative');
      }
      final previous = _readContent();
      _writeContent(
        Uint8List(size)..setRange(0, math.min(size, previous.length), previous),
      );
    }
    _attrs = SftpFileAttrs(
      size: size ?? _readContent().length,
      mode: attrs.mode ?? _attrs.mode,
      userID: attrs.userID ?? _attrs.userID,
      groupID: attrs.groupID ?? _attrs.groupID,
      accessTime: attrs.accessTime ?? _attrs.accessTime,
      modifyTime: attrs.modifyTime ?? _attrs.modifyTime,
    );
  }

  @override
  Future<Never> statvfs() async {
    _ensureOpen();
    // ignore: only_throw_errors
    throw SftpExtensionUnsupportedError('fstatvfs@openssh.com');
  }

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) async* {
    _ensureOpen();
    if (offset < 0 || (length != null && length < 0)) {
      // ignore: only_throw_errors
      throw SftpError('Read offset and length must not be negative');
    }
    if (chunkSize <= 0 || maxPendingRequests <= 0) {
      // ignore: only_throw_errors
      throw SftpError('Read chunk size and request count must be positive');
    }
    final bytes = Uint8List.fromList(_readContent());
    final start = offset.clamp(0, bytes.length);
    final requestedLength = length ?? bytes.length - start;
    final end = (start + requestedLength).clamp(start, bytes.length);
    for (var position = start; position < end; position += chunkSize) {
      _ensureOpen();
      final chunkEnd = math.min(position + chunkSize, end);
      onProgress?.call(chunkEnd - start);
      yield Uint8List.sublistView(bytes, position, chunkEnd);
    }
  }

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in read(length: length, offset: offset)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  SftpFileWriter write(
    Stream<Uint8List> stream, {
    int offset = 0,
    void Function(int total)? onProgress,
  }) {
    _ensureOpen();
    if (offset < 0) {
      // ignore: only_throw_errors
      throw SftpError('Write offset must not be negative');
    }
    return _AppReviewDemoSftpFileWriter(this, stream, offset, onProgress);
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    _ensureOpen();
    if (offset < 0) {
      // ignore: only_throw_errors
      throw SftpError('Write offset must not be negative');
    }
    final previousBytes = _readContent();
    final requiredLength = offset + data.length;
    final bytes = Uint8List(math.max(previousBytes.length, requiredLength))
      ..setRange(0, previousBytes.length, previousBytes)
      ..setRange(offset, requiredLength, data);
    _writeContent(bytes);
    await setStat(SftpFileAttrs(size: bytes.length));
  }

  @override
  Future<void> close() async {
    _isClosed = true;
  }

  @override
  Future<int> downloadTo(
    StreamSink<List<int>> destination, {
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
    bool closeDestination = false,
  }) async {
    var total = 0;
    try {
      await destination.addStream(
        read(
          length: length,
          offset: offset,
          chunkSize: chunkSize,
          maxPendingRequests: maxPendingRequests,
          onProgress: (count) {
            total = count;
            onProgress?.call(count);
          },
        ),
      );
      return total;
    } finally {
      if (closeDestination) await destination.close();
    }
  }

  @override
  Future<int> downloadToRandomAccess(
    RandomAccessFile destination, {
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) async {
    var total = 0;
    await for (final chunk in read(
      length: length,
      offset: offset,
      chunkSize: chunkSize,
      maxPendingRequests: maxPendingRequests,
    )) {
      await destination.setPosition(offset + total);
      await destination.writeFrom(chunk);
      total += chunk.length;
      onProgress?.call(total);
    }
    return total;
  }
}

// dartssh2's writer does not route source/write errors to done. Keep the demo
// writer's asynchronous work owned by the upload caller, including cancellation.
class _AppReviewDemoSftpFileWriter implements SftpFileWriter {
  _AppReviewDemoSftpFileWriter(
    this.file,
    this.stream,
    this.offset,
    this.onProgress,
  ) {
    _source = StreamIterator(stream);
    done = _write();
  }

  @override
  final SftpFile file;
  @override
  final Stream<Uint8List> stream;
  @override
  final int offset;
  @override
  final void Function(int)? onProgress;
  late final StreamIterator<Uint8List> _source;
  Completer<void>? _resume;
  var _progress = 0;
  var _aborted = false;

  Future<void> _write() async {
    try {
      while (!_aborted && await _source.moveNext()) {
        await _resume?.future;
        if (_aborted) break;
        final chunk = _source.current;
        await file.writeBytes(chunk, offset: offset + _progress);
        _progress += chunk.length;
        onProgress?.call(_progress);
      }
    } finally {
      await _source.cancel();
    }
  }

  @override
  late final Future<void> done;
  @override
  int get progress => _progress;
  @override
  void pause() {
    _resume ??= Completer<void>();
  }

  @override
  void resume() {
    _resume?.complete();
    _resume = null;
  }

  @override
  Future<void> abort() async {
    _aborted = true;
    resume();
    await _source.cancel();
    await done;
  }

  @override
  Stream<void> asStream() => done.asStream();
  @override
  Future<void> catchError(Function onError, {bool Function(Object)? test}) =>
      done.catchError(onError, test: test);
  @override
  Future<T> then<T>(
    FutureOr<T> Function(dynamic) onValue, {
    Function? onError,
  }) => done.then(onValue, onError: onError);
  @override
  Future<void> whenComplete(FutureOr<void> Function() action) =>
      done.whenComplete(action);
  @override
  Future<void> timeout(
    Duration timeLimit, {
    FutureOr<void> Function()? onTimeout,
  }) => done.timeout(timeLimit, onTimeout: onTimeout);
}

class _AppReviewDemoForwardChannel implements SSHForwardChannel {
  _AppReviewDemoForwardChannel({
    required String remoteHost,
    required int remotePort,
  }) : _response = _demoForwardHttpResponse(remoteHost, remotePort) {
    _sinkController.stream.drain<void>().ignore();
    scheduleMicrotask(() async {
      _streamController.add(Uint8List.fromList(utf8.encode(_response)));
      await close();
    });
  }

  final String _response;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();
  final _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    // Keep accepting request bytes while the response drains to the socket.
    await _streamController.close();
    await _sinkController.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void destroy() {
    unawaited(close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _demoSftpDirectories = <String>{
  '/',
  '/home',
  '/home/reviewer',
  '/home/reviewer/work',
  '/home/reviewer/work/monkeyssh-demo',
  '/home/reviewer/work/monkeyssh-demo/logs',
  '/home/reviewer/work/monkeyssh-demo/src',
  '/home/reviewer/work/monkeyssh-demo/screenshots',
};

const _demoSftpFiles = <String, String>{
  '/home/reviewer/work/monkeyssh-demo/README.md': '''
# MonkeySSH App Review Demo

This is an in-app local demo workspace. It does not require a private SSH
server, but it behaves like a connected terminal for review.
''',
  '/home/reviewer/work/monkeyssh-demo/package.json': '''
{"scripts":{"dev":"vite --host 127.0.0.1","test":"flutter test"}}
''',
  '/home/reviewer/work/monkeyssh-demo/deploy-demo.sh': '''
#!/bin/sh
echo "dry-run deploy complete"
''',
  '/home/reviewer/work/monkeyssh-demo/logs/app.log': '''
01:08:22 connected local review shell
01:08:23 loaded MonkeyMux workspace metadata
01:08:24 opened sample SFTP tree
''',
  '/home/reviewer/work/monkeyssh-demo/src/main.dart': '''
void main() {
  print('MonkeySSH App Review Demo');
}
''',
};

String _demoInteractiveBanner(Host host) =>
    '''
\x1b]0;${host.label}\x07\x1b]7;file://localhost/home/reviewer/work/monkeyssh-demo\x07MonkeySSH App Review Demo

Connected locally for:
  ${_shortDemoHostLabel(host.label)}

No external SSH server or credentials are required.

Sample workspace: ~/work/monkeyssh-demo

Try:
  ls
  pwd
  cat README.md
  monkeymux windows
  copilot

''';

String _shortDemoHostLabel(String label) =>
    label.replaceFirst('${AppReviewDemoService.demoHostLabelPrefix} ', '');

String _normalizeDemoTerminalOutput(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

String _demoInteractiveCommandOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized == 'pwd') {
    return '/home/reviewer/work/monkeyssh-demo\r\n';
  }
  if (normalized == 'whoami') {
    return 'reviewer\r\n';
  }
  if (normalized == 'ls' || normalized == 'ls -la') {
    return 'README.md  deploy-demo.sh  logs  package.json  screenshots  src\r\n';
  }
  if (normalized == 'cat readme.md' ||
      normalized == 'cat README.md'.toLowerCase()) {
    return '${_demoSftpFiles['/home/reviewer/work/monkeyssh-demo/README.md']}\r\n';
  }
  if (normalized.contains('monkeymux') || normalized.contains('tmux')) {
    return '''
review-workspace
  0  Copilot CLI     planning App Review notes
  1  Claude Code    running focused tests
  2  OpenCode       editing README.md
  3  SFTP           browsing /home/reviewer/work/monkeyssh-demo
''';
  }
  if (normalized.contains('copilot')) {
    return '''
Copilot CLI demo
  ✓ inspected staged changes
  ✓ prepared review notes
  → ready for /deploy
''';
  }
  if (normalized.contains('deploy-demo')) {
    return 'dry-run deploy complete\r\n';
  }
  return 'demo shell: command "$command" completed locally\r\n';
}

String _demoExecOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized.contains('pwd')) {
    return '/home/reviewer/work/monkeyssh-demo\n';
  }
  if (normalized.contains('tmux') && normalized.contains('list')) {
    return 'review-workspace: 4 windows\n';
  }
  if (normalized.contains('command -v') ||
      normalized.contains('which ') ||
      normalized.contains('uname')) {
    return '';
  }
  return '';
}

String _demoForwardHttpResponse(String remoteHost, int remotePort) {
  const body = '''
<!doctype html>
<title>MonkeySSH App Review Demo</title>
<h1>MonkeySSH forwarded preview</h1>
<p>This page was served by the in-app demo tunnel.</p>
''';
  return 'HTTP/1.1 200 OK\r\n'
      'content-type: text/html; charset=utf-8\r\n'
      'content-length: ${utf8.encode(body).length}\r\n'
      'connection: close\r\n'
      '\r\n'
      '$body';
}

List<String> _demoSftpDirectoryChildren(
  String directory,
  Iterable<String> filePaths,
) {
  final children = <String>{};
  for (final path in [..._demoSftpDirectories, ...filePaths]) {
    if (path == directory || !path.startsWith('$directory/')) {
      continue;
    }
    final remainder = path.substring(
      directory == '/' ? 1 : directory.length + 1,
    );
    if (remainder.isEmpty || remainder.contains('/')) {
      continue;
    }
    children.add(remainder);
  }
  return children.toList()..sort();
}

String _normalizeDemoSftpPath(String input) {
  var path = input.trim();
  if (path.isEmpty || path == '.') {
    return _AppReviewDemoSftpClient._workspace;
  }
  if (path == '~') {
    return _AppReviewDemoSftpClient._home;
  }
  if (path.startsWith('~/')) {
    path = '${_AppReviewDemoSftpClient._home}/${path.substring(2)}';
  }
  if (!path.startsWith('/')) {
    path = '${_AppReviewDemoSftpClient._workspace}/$path';
  }
  while (path.contains('//')) {
    path = path.replaceAll('//', '/');
  }
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

String _joinDemoSftpPath(String directory, String child) =>
    directory == '/' ? '/$child' : '$directory/$child';

SftpFileAttrs _demoDirectoryAttrs() => SftpFileAttrs(
  size: 0,
  mode: const SftpFileMode.value(0x4000 | 0x01ED),
  modifyTime: 1783325486,
);

SftpFileAttrs _demoFileAttrs(int size) => SftpFileAttrs(
  size: size,
  mode: const SftpFileMode.value(0x8000 | 0x01A4),
  modifyTime: 1783325486,
);

String _telemetryAuthMethodFromHost(Host? host) {
  if (host == null) {
    return 'unknown';
  }
  final hasPassword = host.password?.isNotEmpty ?? false;
  final hasKey = host.keyId != null;
  if (hasPassword && hasKey) {
    return 'password_and_key';
  }
  if (hasKey) {
    return 'key';
  }
  if (hasPassword) {
    return 'password';
  }
  return 'none';
}

String _telemetryConnectionFailureCategory(String? error) {
  final normalized = error?.toLowerCase() ?? '';
  if (normalized.contains('host key')) {
    return 'host_key';
  }
  if (normalized.contains('auth') ||
      normalized.contains('password') ||
      normalized.contains('key') ||
      normalized.contains('credential')) {
    return 'authentication';
  }
  if (normalized.contains('timeout') || normalized.contains('timed out')) {
    return 'timeout';
  }
  if (normalized.contains('network') ||
      normalized.contains('socket') ||
      normalized.contains('connection refused') ||
      normalized.contains('unreachable')) {
    return 'network';
  }
  if (normalized.contains('setup')) {
    return 'setup';
  }
  return 'unknown';
}

/// Provider for [SshService].
final sshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    hostRepository: ref.watch(hostRepositoryProvider),
    keyRepository: ref.watch(keyRepositoryProvider),
    knownHostsRepository: ref.watch(knownHostsRepositoryProvider),
    hostKeyPromptHandler: ref.watch(hostKeyPromptHandlerProvider),
    interactiveAuthPromptHandler: ref.watch(
      interactiveAuthPromptHandlerProvider,
    ),
    wifiNetworkService: ref.watch(wifiNetworkServiceProvider),
  ),
);

/// Provider for tracking active SSH sessions.
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, Map<int, SshConnectionState>>(
      ActiveSessionsNotifier.new,
    );

/// Provider for host-level connection attempt progress.
final connectionAttemptProvider =
    Provider.family<ConnectionAttemptStatus?, int>((ref, hostId) {
      ref.watch(activeSessionsProvider);
      return ref
          .read(activeSessionsProvider.notifier)
          .getConnectionAttempt(hostId);
    });

/// Notifier for active SSH sessions state.
class ActiveSessionsNotifier extends Notifier<Map<int, SshConnectionState>> {
  static const _previewStateRefreshInterval = Duration(milliseconds: 150);
  static const _maxTerminalNotificationExpiries = 256;

  late final SshService _sshService;
  final Map<int, int> _connectionHostIds = {};
  final Map<int, String> _connectionSessionTitles = {};
  final Map<int, ConnectionAttemptStatus> _connectionAttempts = {};
  final Map<int, Set<SshConnectionCancellationToken>>
  _connectionCancellationTokens = {};
  final Map<int, StreamSubscription<void>> _disconnectSubscriptions = {};
  final Map<int, StreamSubscription<_SshConnectionHealthFailure>>
  _connectionHealthFailureSubscriptions = {};
  final Map<int, StreamSubscription<TerminalNotificationRequest>>
  _terminalNotificationSubscriptions = {};
  final Map<
    ({int connectionId, int notificationId}),
    _TerminalNotificationExpiry
  >
  _terminalNotificationExpiries = {};
  final Map<({int connectionId, int notificationId}), int>
  _terminalNotificationGenerations = {};
  final Map<int, _TerminalNotificationQueue> _terminalNotificationQueues = {};
  int _nextTerminalNotificationGeneration = 0;
  final Map<int, StreamSubscription<void>> _portForwardChangeSubscriptions = {};
  final Map<int, Set<RemoteTcpListenerKey>>
  _automaticForwardDesiredExclusionsByHost = {};
  final Map<String, Set<RemoteTcpListenerKey>>
  _automaticForwardShellOwnedByEndpoint = {};
  final Map<int, Future<void>> _automaticForwardHostReconfigurationQueues = {};
  final Map<String, Future<void>> _automaticForwardReconfigurationQueues = {};
  Timer? _previewStateRefreshTimer;
  Future<void> _backgroundStatusSyncQueue = Future<void>.value();

  @override
  Map<int, SshConnectionState> build() {
    _sshService = ref.watch(sshServiceProvider);
    ref.onDispose(() {
      _previewStateRefreshTimer?.cancel();
      _previewStateRefreshTimer = null;
      for (final subscription in _disconnectSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _disconnectSubscriptions.clear();
      for (final subscription in _connectionHealthFailureSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _connectionHealthFailureSubscriptions.clear();
      for (final subscription in _terminalNotificationSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _terminalNotificationSubscriptions.clear();
      for (final entry in _terminalNotificationExpiries.entries.toList()) {
        _expireTerminalNotification(entry.key, entry.value);
      }
      _terminalNotificationGenerations.clear();
      for (final queue in _terminalNotificationQueues.values) {
        queue.pending.clear();
      }
      _terminalNotificationQueues.clear();
      for (final subscription in _portForwardChangeSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _portForwardChangeSubscriptions.clear();
      _automaticForwardDesiredExclusionsByHost.clear();
      _automaticForwardShellOwnedByEndpoint.clear();
      _automaticForwardHostReconfigurationQueues.clear();
      _automaticForwardReconfigurationQueues.clear();
    });
    _connectionHostIds.clear();
    _connectionSessionTitles.clear();
    _connectionAttempts.clear();
    _connectionCancellationTokens.clear();
    return {};
  }

  /// Connect to a host.
  ///
  /// The cancellation token is registered before any `await` so a cancel
  /// request that arrives while the attempt is still warming up is honored,
  /// and it is torn down again once the attempt settles.
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    final cancellationToken = SshConnectionCancellationToken();
    _connectionCancellationTokens
        .putIfAbsent(hostId, () => <SshConnectionCancellationToken>{})
        .add(cancellationToken);

    final SshConnectionResult result;
    try {
      result = await _runConnectAttempt(
        hostId,
        forceNew: forceNew,
        useHostThemeOverrides: useHostThemeOverrides,
        cancellationToken: cancellationToken,
      );
    } finally {
      final tokens = _connectionCancellationTokens[hostId];
      if (tokens != null) {
        tokens.remove(cancellationToken);
        if (tokens.isEmpty) {
          _connectionCancellationTokens.remove(hostId);
        }
      }
    }

    if (!cancellationToken.isCancelled || result.cancelled) {
      return result;
    }

    // The attempt raced past cancellation (for example it was reusing an
    // existing session, or it finished while the request was in flight).
    // Honor the user's intent instead of handing back a live connection.
    final connectionId = result.connectionId;
    if (result.success && connectionId != null && !result.reusedConnection) {
      await disconnect(connectionId);
    }
    _updateConnectionAttempt(
      hostId,
      const ConnectionProgressUpdate(
        state: SshConnectionState.error,
        message: 'Connection cancelled',
      ),
      cancelled: true,
    );
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'connect_cancelled',
      fields: {'hostId': hostId, 'phase': 'post_attempt'},
    );
    return const SshConnectionResult.userCancelled();
  }

  Future<SshConnectionResult> _runConnectAttempt(
    int hostId, {
    required bool forceNew,
    required bool useHostThemeOverrides,
    required SshConnectionCancellationToken cancellationToken,
  }) async {
    final telemetry = ref.read(telemetryServiceProvider);
    final host = await _telemetryHostForConnection(hostId);
    if (!forceNew) {
      final existingConnectionId = getPreferredConnectionForHost(hostId);
      if (existingConnectionId != null) {
        DiagnosticsLogService.instance.info(
          'ssh.active',
          'reuse_connection',
          fields: {'hostId': hostId, 'connectionId': existingConnectionId},
        );
        unawaited(_queueBackgroundStatusSync());
        unawaited(
          telemetry.logTerminalSessionStarted(
            reusedConnection: true,
            usedBackgroundService: false,
          ),
        );
        unawaited(reconfigureAutomaticPortForwardingForHost(hostId));
        return SshConnectionResult(
          success: true,
          connectionId: existingConnectionId,
          reusedConnection: true,
        );
      }
    }

    final startedAt = DateTime.now();
    unawaited(
      telemetry.logConnectionAttempted(
        authMethod: _telemetryAuthMethodFromHost(host),
        usesJumpHost: host?.jumpHostId != null,
      ),
    );
    _updateConnectionAttempt(
      hostId,
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Preparing connection…',
      ),
      resetLog: true,
      cancelRequested: false,
    );

    final result = await _sshService.connectToHost(
      hostId,
      onProgress: (update) => _updateConnectionAttempt(hostId, update),
      useHostThemeOverrides: useHostThemeOverrides,
      cancellationToken: cancellationToken,
    );

    if (result.cancelled) {
      _updateConnectionAttempt(
        hostId,
        ConnectionProgressUpdate(
          state: SshConnectionState.error,
          message: result.error ?? 'Connection cancelled',
        ),
        cancelled: true,
      );
      unawaited(
        telemetry.logConnectionFailed(
          authMethod: _telemetryAuthMethodFromHost(host),
          usesJumpHost: host?.jumpHostId != null,
          duration: DateTime.now().difference(startedAt),
          failureCategory: 'cancelled',
        ),
      );
      DiagnosticsLogService.instance.info(
        'ssh.active',
        'connect_cancelled',
        fields: {'hostId': hostId},
      );
      return result;
    }

    if (result.success && result.connectionId != null) {
      final connectionId = result.connectionId!;
      _connectionHostIds[connectionId] = hostId;
      final session = _sshService.getSession(connectionId);
      if (session != null) {
        _attachSessionListeners(session);
      }
      state = {...state, connectionId: SshConnectionState.connected};
      if (session != null) {
        unawaited(reconfigureAutomaticPortForwardingForHost(hostId));
      }
      _updateConnectionAttempt(
        hostId,
        const ConnectionProgressUpdate(
          state: SshConnectionState.connected,
          message: 'Connection established. Opening terminal…',
        ),
      );
      unawaited(_queueBackgroundStatusSync());
      unawaited(
        telemetry.logConnectionSucceeded(
          authMethod: _telemetryAuthMethodFromHost(host),
          usesJumpHost: host?.jumpHostId != null,
          duration: DateTime.now().difference(startedAt),
        ),
      );
      unawaited(
        telemetry.logTerminalSessionStarted(
          reusedConnection: false,
          usedBackgroundService: false,
        ),
      );
    } else {
      _updateConnectionAttempt(
        hostId,
        ConnectionProgressUpdate(
          state: SshConnectionState.error,
          message: result.error ?? 'Connection failed',
        ),
      );
      unawaited(
        telemetry.logConnectionFailed(
          authMethod: _telemetryAuthMethodFromHost(host),
          usesJumpHost: host?.jumpHostId != null,
          duration: DateTime.now().difference(startedAt),
          failureCategory: _telemetryConnectionFailureCategory(result.error),
        ),
      );
    }

    DiagnosticsLogService.instance.info(
      'ssh.active',
      'connect_result',
      fields: {
        'hostId': hostId,
        'success': result.success,
        'connectionId': result.connectionId,
        'errorType': _diagnosticSshResultErrorKind(result.error),
      },
    );
    return result;
  }

  /// Disconnect from a connection.
  Future<void> disconnect(int connectionId) => _disconnect(connectionId);

  Future<void> _disconnect(int connectionId, {String? message}) async {
    final session = _sshService.getSession(connectionId);
    final hostId = _connectionHostIds[connectionId] ?? session?.hostId;
    final endpointKey = session == null
        ? null
        : _sshEndpointKey(session.config);
    if (message != null &&
        hostId == null &&
        session == null &&
        !state.containsKey(connectionId)) {
      DiagnosticsLogService.instance.debug(
        'ssh.active',
        'unexpected_disconnect_ignored',
        fields: {'connectionId': connectionId},
      );
      return;
    }
    if (message == null) {
      DiagnosticsLogService.instance.info(
        'ssh.active',
        'disconnect',
        fields: {'connectionId': connectionId},
      );
    } else {
      DiagnosticsLogService.instance.warning(
        'ssh.active',
        'unexpected_disconnect',
        fields: {'connectionId': connectionId, 'hostId': hostId},
      );
    }
    _detachConnection(
      connectionId,
      session,
      message == null ? 'user' : 'unexpected',
    );
    try {
      final closing = _sshService.disconnect(connectionId);
      state = {...state}..remove(connectionId);
      if (hostId != null && message != null) {
        reportConnectionAttemptError(hostId, message);
      }
      await closing;
    } finally {
      try {
        if (hostId != null) {
          await _reconfigureAutomaticPortForwardingAfterSessionRemoval(
            hostId,
            endpointKey,
          );
        }
      } finally {
        await _queueBackgroundStatusSync();
      }
    }
  }

  void _detachConnection(int connectionId, SshSession? session, String reason) {
    _detachSessionListeners(connectionId, session: session);
    if (session != null) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalSessionEnded(
              duration: DateTime.now().difference(session.createdAt),
              disconnectCategory: reason,
              usedBackgroundService: false,
            ),
      );
    }
    _connectionHostIds.remove(connectionId);
    _connectionSessionTitles.remove(connectionId);
  }

  /// Disconnect all active sessions.
  Future<void> disconnectAll() async {
    final sessions = _sshService.sessions;
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'disconnect_all',
      fields: {'connectionCount': sessions.length},
    );
    for (final session in sessions.values) {
      _detachConnection(session.connectionId, session, 'disconnect_all');
    }
    _connectionAttempts.clear();
    _automaticForwardDesiredExclusionsByHost.clear();
    _automaticForwardShellOwnedByEndpoint.clear();
    try {
      final closing = _sshService.disconnectAll();
      state = {...state}..removeWhere((id, _) => sessions.containsKey(id));
      await closing;
    } finally {
      try {
        await Future.wait(
          {
            for (final session in sessions.values)
              (session.hostId, _sshEndpointKey(session.config)),
          }.map(
            (endpoint) =>
                _reconfigureAutomaticPortForwardingAfterSessionRemoval(
                  endpoint.$1,
                  endpoint.$2,
                ),
          ),
        );
      } finally {
        await _queueBackgroundStatusSync();
      }
    }
  }

  /// Get the state of a connection.
  SshConnectionState getState(int connectionId) =>
      state[connectionId] ?? SshConnectionState.disconnected;

  /// Get a session.
  SshSession? getSession(int connectionId) =>
      _sshService.getSession(connectionId);

  /// Number of pending terminal notification expiration timers.
  @visibleForTesting
  int get debugTerminalNotificationExpiryTimerCount =>
      _terminalNotificationExpiries.length;

  /// Number of native notification operations with current generations.
  @visibleForTesting
  int get debugTerminalNotificationGenerationCount =>
      _terminalNotificationGenerations.length;

  /// Maximum retained terminal notification expiration records.
  @visibleForTesting
  int get debugTerminalNotificationExpiryLimit =>
      _maxTerminalNotificationExpiries;

  /// Maximum retained native notification operations per connection.
  @visibleForTesting
  int get debugTerminalNotificationQueueLimit =>
      _TerminalNotificationQueue.maxPending;

  /// Number of retained native notification operations for a connection.
  @visibleForTesting
  int debugTerminalNotificationQueueLength(int connectionId) =>
      _terminalNotificationQueues[connectionId]?.pending.length ?? 0;

  /// Cancels expiration and reports a native terminal-notification tap.
  void handleTerminalNotificationTap(TerminalNotificationPayload payload) {
    final notificationId =
        payload.platformNotificationId ??
        buildTerminalNotificationId(
          payload.connectionId,
          identifier: payload.notificationIdentifier,
        );
    final expiryKey = (
      connectionId: payload.connectionId,
      notificationId: notificationId,
    );
    _terminalNotificationExpiries.remove(expiryKey)?.timer.cancel();
    _terminalNotificationGenerations.remove(expiryKey);
    getSession(payload.connectionId)?.handleTerminalNotificationActivated(
      payload.notificationIdentifier,
      reportsActivation: payload.reportsActivation,
    );
  }

  /// Active tunnels owned by any connected session for [hostId].
  List<ActiveTunnelInfo> getActiveTunnelsForHost(int hostId) =>
      getConnectionsForHost(hostId)
          .map(getSession)
          .whereType<SshSession>()
          .expand((session) => session.activeTunnels)
          .toList(growable: false);

  /// Applies [host]'s automatic-forwarding settings to its connected sessions.
  ///
  /// Only the newest connection owns detected forwards so one host never creates
  /// duplicate local proxies when multiple terminals are open.
  Future<void> _applyAutomaticPortForwardingForHost(
    Host host, {
    required bool includeHostLevelListeners,
    Set<RemoteTcpListenerKey> additionalExcludedListeners = const {},
  }) async {
    final sessions = getConnectionsForHost(host.id)
        .where((connectionId) {
          final connectionState = getState(connectionId);
          return connectionState == SshConnectionState.connected ||
              connectionState == SshConnectionState.reconnecting;
        })
        .map(getSession)
        .whereType<SshSession>()
        .toList(growable: false);
    final connectedSessions = sessions
        .where(
          (session) =>
              getState(session.connectionId) == SshConnectionState.connected,
        )
        .toList(growable: false);
    final owner = connectedSessions.isEmpty ? null : connectedSessions.last;
    final processRoots = sessions
        .expand((session) => session.automaticPortForwardProcessRoots)
        .toSet();
    final activeManualRemoteListeners = _manualListenerExclusions(
      sessions.expand((session) => session.activeTunnels),
    );
    if (sessions.isEmpty) {
      _automaticForwardDesiredExclusionsByHost.remove(host.id);
      return;
    }
    late final Set<RemoteTcpListenerKey> savedRemoteListeners;
    try {
      final savedForwards = await ref
          .read(portForwardRepositoryProvider)
          .getByHostId(host.id);
      savedRemoteListeners = savedForwards
          .where(
            (forward) =>
                forward.forwardType == 'local' &&
                isPortForwardLoopbackHost(forward.remoteHost),
          )
          .expand(
            (forward) => remoteTcpListenerExclusionKeys(
              forward.remoteHost,
              forward.remotePort,
            ),
          )
          .toSet();
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'saved_forward_exclusions_load_failed',
        fields: {'hostId': host.id, 'errorType': error.runtimeType},
      );
      for (final session in sessions) {
        try {
          await session.configureAutomaticPortForwarding(enabled: false);
        } on Object catch (configureError) {
          DiagnosticsLogService.instance.warning(
            'ssh.forward',
            'automatic_configuration_failed',
            fields: {
              'connectionId': session.connectionId,
              'hostId': host.id,
              'errorType': configureError.runtimeType,
            },
          );
        }
      }
      _automaticForwardDesiredExclusionsByHost.remove(host.id);
      return;
    }
    final excludedRemoteListeners = {
      ...activeManualRemoteListeners,
      ...savedRemoteListeners,
      ...additionalExcludedListeners,
    };
    var configurationFailed = false;
    final customProxyName = normalizeOptionalPortProxyName(host.portProxyName);
    var resolvedProxyName = customProxyName;
    if (customProxyName == null) {
      resolvedProxyName = generatedPortProxyName(
        host.label,
        hostId: host.id,
        includeHostId: true,
      );
    }
    try {
      resolvedProxyName = await ref
          .read(hostRepositoryProvider)
          .resolveProxyName(
            hostId: host.id,
            label: host.label,
            customName: host.portProxyName,
          );
    } on PortProxyNameConflictException catch (error) {
      resolvedProxyName = null;
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'proxy_label_conflict',
        fields: {'hostId': host.id, 'nameLength': error.proxyName.length},
      );
    } on Object catch (error) {
      if (customProxyName != null) {
        resolvedProxyName = null;
      }
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'proxy_label_check_failed',
        fields: {'hostId': host.id, 'errorType': error.runtimeType},
      );
    }
    final proxyHost = host.autoForwardPorts && resolvedProxyName != null
        ? '$resolvedProxyName.localhost'
        : null;
    final shellLineageTokens = sessions
        .map((session) => session.shellLineageToken)
        .toSet();
    Future<void> configureSession(
      SshSession session, {
      required bool enabled,
    }) async {
      try {
        if (enabled) {
          await session.updateAutomaticPortForwardProcessRoots(processRoots);
        }
        await session.configureAutomaticPortForwarding(
          enabled: enabled,
          proxyHost: proxyHost,
          excludedRemoteListeners: excludedRemoteListeners,
          shellLineageTokens: shellLineageTokens,
          includeHostLevelListeners: includeHostLevelListeners,
        );
      } on Object catch (error) {
        configurationFailed = true;
        DiagnosticsLogService.instance.warning(
          'ssh.forward',
          'automatic_configuration_failed',
          fields: {
            'connectionId': session.connectionId,
            'hostId': host.id,
            'errorType': error.runtimeType,
          },
        );
      }
    }

    for (final session in sessions) {
      if (!identical(session, owner)) {
        await configureSession(session, enabled: false);
      }
    }
    if (owner != null) {
      await configureSession(
        owner,
        enabled: host.autoForwardPorts && proxyHost != null,
      );
    }
    if (configurationFailed) {
      _automaticForwardDesiredExclusionsByHost.remove(host.id);
    } else {
      _automaticForwardDesiredExclusionsByHost[host.id] = Set.unmodifiable(
        activeManualRemoteListeners,
      );
    }
  }

  /// Reloads and serially reapplies automatic forwarding for [hostId].
  Future<void> reconfigureAutomaticPortForwardingForHost(int hostId) {
    final previous =
        _automaticForwardHostReconfigurationQueues[hostId] ??
        Future<void>.value();
    late final Future<void> trackedOperation;
    final operation = previous.then((_) async {
      if (!ref.mounted) {
        return;
      }
      final triggerHost = await _telemetryHostForConnection(hostId);
      if (triggerHost != null && ref.mounted) {
        final endpointKeys = getConnectionsForHost(hostId)
            .map(getSession)
            .whereType<SshSession>()
            .map((session) => _sshEndpointKey(session.config))
            .toSet();
        for (final endpointKey in endpointKeys) {
          await _reconfigureAutomaticPortForwardingEndpoint(
            triggerHost,
            endpointKey: endpointKey,
          );
        }
      }
    });
    trackedOperation = operation.whenComplete(() {
      if (identical(
        _automaticForwardHostReconfigurationQueues[hostId],
        trackedOperation,
      )) {
        _automaticForwardHostReconfigurationQueues.remove(hostId);
      }
    });
    _automaticForwardHostReconfigurationQueues[hostId] = trackedOperation;
    return trackedOperation;
  }

  /// Reapplies automatic forwarding for every currently connected saved host.
  Future<void> reconfigureAutomaticPortForwardingForConnectedHosts() async {
    final hostIds =
        state.keys
            .map(getSession)
            .whereType<SshSession>()
            .map((session) => session.hostId)
            .toSet()
            .toList()
          ..sort();
    for (final hostId in hostIds) {
      await reconfigureAutomaticPortForwardingForHost(hostId);
    }
  }

  Future<void> _reconfigureAutomaticPortForwardingEndpoint(
    Host triggerHost, {
    required String endpointKey,
  }) {
    final previous =
        _automaticForwardReconfigurationQueues[endpointKey] ??
        Future<void>.value();
    late final Future<void> trackedOperation;
    final operation = previous.then((_) async {
      if (!ref.mounted) {
        return;
      }
      final siblingHostIds = <int>{triggerHost.id};
      final activeSessions = state.keys
          .map(getSession)
          .whereType<SshSession>()
          .toList(growable: false);
      for (final session in activeSessions) {
        if (_sshEndpointKey(session.config) == endpointKey) {
          siblingHostIds.add(session.hostId);
        }
      }
      final siblingHosts = <Host>[];
      for (final siblingHostId in siblingHostIds) {
        final host = await _telemetryHostForConnection(siblingHostId);
        if (host != null) {
          siblingHosts.add(host);
        }
      }
      siblingHosts.sort((left, right) => left.id.compareTo(right.id));
      final connectedHostIds = activeSessions
          .where(
            (session) =>
                _sshEndpointKey(session.config) == endpointKey &&
                getState(session.connectionId) == SshConnectionState.connected,
          )
          .map((session) => session.hostId)
          .toSet();
      final hostLevelOwnerCandidates = siblingHosts
          .where(
            (host) =>
                host.autoForwardPorts && connectedHostIds.contains(host.id),
          )
          .map((host) => host.id)
          .toList(growable: false);
      final hostLevelOwnerId = hostLevelOwnerCandidates.isEmpty
          ? null
          : hostLevelOwnerCandidates.first;
      siblingHosts.sort((left, right) {
        if (left.id == hostLevelOwnerId) {
          return 1;
        }
        if (right.id == hostLevelOwnerId) {
          return -1;
        }
        return left.id.compareTo(right.id);
      });
      for (final host in siblingHosts) {
        if (!ref.mounted) {
          return;
        }
        final siblingShellOwnedListeners = activeSessions
            .where(
              (session) =>
                  session.hostId != host.id &&
                  _sshEndpointKey(session.config) == endpointKey,
            )
            .expand((session) => session.activeTunnels)
            .where(
              (tunnel) =>
                  tunnel.isAutomatic && tunnel.isShellRelated && tunnel.isLocal,
            )
            .expand(
              (tunnel) => remoteTcpListenerExclusionKeys(
                tunnel.remoteHost,
                tunnel.remotePort,
              ),
            )
            .toSet();
        await _applyAutomaticPortForwardingForHost(
          host,
          includeHostLevelListeners: host.id == hostLevelOwnerId,
          additionalExcludedListeners: siblingShellOwnedListeners,
        );
      }
    });
    trackedOperation = operation.whenComplete(() {
      if (identical(
        _automaticForwardReconfigurationQueues[endpointKey],
        trackedOperation,
      )) {
        _automaticForwardReconfigurationQueues.remove(endpointKey);
      }
    });
    _automaticForwardReconfigurationQueues[endpointKey] = trackedOperation;
    return trackedOperation;
  }

  Future<void> _reconfigureAutomaticPortForwardingAfterSessionRemoval(
    int hostId,
    String? endpointKey,
  ) async {
    final triggerHost = await _telemetryHostForConnection(hostId);
    if (triggerHost != null && endpointKey != null) {
      await _reconfigureAutomaticPortForwardingEndpoint(
        triggerHost,
        endpointKey: endpointKey,
      );
      return;
    }
    await reconfigureAutomaticPortForwardingForHost(hostId);
  }

  /// Get active connection metadata for a single connection.
  ActiveConnection? getActiveConnection(int connectionId) {
    final session = _sshService.getSession(connectionId);
    final hostId = _connectionHostIds[connectionId];
    final connectionState = state[connectionId];
    if (session == null || hostId == null || connectionState == null) {
      return null;
    }
    final nativeFocusTitle = _activeNativeAcpConnectionTitle(session);
    return ActiveConnection(
      connectionId: connectionId,
      hostId: hostId,
      state: connectionState,
      createdAt: session.createdAt,
      config: session.config,
      preview: nativeFocusTitle == null
          ? session.terminalPreview
          : session.activeNativeAcpPreview,
      previewSnapshot: nativeFocusTitle == null
          ? session.terminalPreviewSnapshot
          : null,
      nativeAcpPreviewSnapshot: nativeFocusTitle == null
          ? null
          : session.activeNativeAcpPreviewSnapshot,
      terminalTheme: session.terminalTheme,
      sessionTitle: nativeFocusTitle ?? _connectionSessionTitles[connectionId],
      windowTitle: nativeFocusTitle == null ? session.windowTitle : null,
      iconName: nativeFocusTitle == null ? session.iconName : null,
      workingDirectory: nativeFocusTitle == null
          ? session.workingDirectory
          : null,
      shellStatus: nativeFocusTitle == null ? session.shellStatus : null,
      lastExitCode: nativeFocusTitle == null ? session.lastExitCode : null,
      remoteMuxBackend: session.remoteMuxBackend,
      remoteMuxSessionName: session.remoteMuxSessionName,
      terminalThemeLightId: session.terminalThemeLightId,
      terminalThemeDarkId: session.terminalThemeDarkId,
    );
  }

  /// Get the current connection attempt state for a host.
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) =>
      _connectionAttempts[hostId];

  /// Get all active connection IDs for a host.
  List<int> getConnectionsForHost(int hostId) {
    final matches = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      if (session.hostId == hostId) {
        matches.add(session);
      }
    }
    matches.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return matches
        .map((session) => session.connectionId)
        .toList(growable: false);
  }

  /// Get a preferred existing connection ID for a host.
  int? getPreferredConnectionForHost(int hostId) {
    final activeConnections = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      final connectionId = session.connectionId;
      final sessionHostId = _connectionHostIds[connectionId];
      final connectionState = state[connectionId];
      if (sessionHostId == hostId &&
          connectionState != null &&
          connectionState != SshConnectionState.error &&
          connectionState != SshConnectionState.disconnected) {
        activeConnections.add(session);
      }
    }
    if (activeConnections.isEmpty) {
      return null;
    }
    activeConnections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return activeConnections.first.connectionId;
  }

  /// Get the newest active connection that already owns a local forward.
  int? getConnectionForActiveLocalForward(int portForwardId) {
    final activeConnections = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      final connectionState = state[session.connectionId];
      if (connectionState == null ||
          connectionState == SshConnectionState.error ||
          connectionState == SshConnectionState.disconnected) {
        continue;
      }

      final hasLocalForward = session.activeTunnels.any(
        (tunnel) => tunnel.portForwardId == portForwardId && tunnel.isLocal,
      );
      if (hasLocalForward) {
        activeConnections.add(session);
      }
    }
    if (activeConnections.isEmpty) {
      return null;
    }
    activeConnections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return activeConnections.first.connectionId;
  }

  /// Get all active connection metadata for UI rendering.
  List<ActiveConnection> getActiveConnections() {
    final connections =
        state.keys
            .map(getActiveConnection)
            .whereType<ActiveConnection>()
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return connections;
  }

  /// Clear the current connection attempt state for a host.
  void clearConnectionAttempt(int hostId) {
    if (_connectionAttempts.remove(hostId) != null) {
      state = {...state};
    }
  }

  void _attachSessionListeners(SshSession session) {
    session
      ..removePreviewListener(_schedulePreviewStateRefresh)
      ..addPreviewListener(_schedulePreviewStateRefresh);
    unawaited(_disconnectSubscriptions.remove(session.connectionId)?.cancel());
    unawaited(
      _connectionHealthFailureSubscriptions
          .remove(session.connectionId)
          ?.cancel(),
    );
    _disconnectSubscriptions[session.connectionId] = session.client.done
        .asStream()
        .listen(
          (_) => unawaited(
            handleUnexpectedDisconnect(
              session.connectionId,
              message: 'Connection closed',
            ),
          ),
          onError: (Object error, StackTrace _) => unawaited(
            handleUnexpectedDisconnect(
              session.connectionId,
              message: 'Connection lost: $error',
            ),
          ),
        );
    _connectionHealthFailureSubscriptions[session.connectionId] = session
        ._connectionHealthFailureStream
        .listen(
          (failure) => unawaited(
            handleUnexpectedDisconnect(
              failure.connectionId,
              message: failure.message,
            ),
          ),
        );
    unawaited(
      _terminalNotificationSubscriptions.remove(session.connectionId)?.cancel(),
    );
    _terminalNotificationSubscriptions[session.connectionId] = session
        .terminalNotifications
        .listen((request) => _queueTerminalNotification(session, request));
    unawaited(
      _portForwardChangeSubscriptions.remove(session.connectionId)?.cancel(),
    );
    _portForwardChangeSubscriptions[session.connectionId] = session
        .portForwardChanges
        .listen((_) => _handleSessionPortForwardsChanged(session.hostId));
  }

  void _queueTerminalNotification(
    SshSession session,
    TerminalNotificationRequest request,
  ) {
    final connectionId = session.connectionId;
    final queue = _terminalNotificationQueues.putIfAbsent(
      connectionId,
      _TerminalNotificationQueue.new,
    );
    final shouldStart = !queue.isProcessing;
    queue
      ..add(request)
      ..isProcessing = true;
    if (!shouldStart) return;
    unawaited(_drainTerminalNotificationQueue(session, queue));
  }

  Future<void> _drainTerminalNotificationQueue(
    SshSession session,
    _TerminalNotificationQueue queue,
  ) async {
    final connectionId = session.connectionId;
    while (ref.mounted &&
        identical(_terminalNotificationQueues[connectionId], queue) &&
        queue.pending.isNotEmpty) {
      final request = queue.pending.removeAt(0);
      try {
        await _showTerminalNotification(session, request);
      } on Object catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'ssh_service',
            context: ErrorDescription(
              'while presenting a serialized terminal notification',
            ),
          ),
        );
      }
    }
    queue.isProcessing = false;
    if (identical(_terminalNotificationQueues[connectionId], queue) &&
        queue.pending.isEmpty) {
      _terminalNotificationQueues.remove(connectionId);
    }
  }

  Future<void> _showTerminalNotification(
    SshSession session,
    TerminalNotificationRequest request,
  ) async {
    if (!ref.mounted) return;
    if (request.action == TerminalNotificationAction.show &&
        !ref.read(terminalNotificationsNotifierProvider)) {
      return;
    }
    final notificationService = ref.read(localNotificationServiceProvider);
    final notificationId = buildTerminalNotificationId(
      session.connectionId,
      identifier: request.platformIdentifier,
    );
    final expiryKey = (
      connectionId: session.connectionId,
      notificationId: notificationId,
    );
    final generation = ++_nextTerminalNotificationGeneration;
    _terminalNotificationGenerations[expiryKey] = generation;
    _terminalNotificationExpiries.remove(expiryKey)?.timer.cancel();
    if (request.action == TerminalNotificationAction.close) {
      try {
        await notificationService.clearTerminalNotification(notificationId);
      } finally {
        _removeTerminalNotificationGeneration(expiryKey, generation);
      }
      return;
    }
    final title = request.title ?? await _resolveSessionLabel(session);
    if (!ref.mounted ||
        _terminalNotificationGenerations[expiryKey] != generation) {
      return;
    }
    final bool didShow;
    try {
      didShow = await notificationService.showTerminalNotification(
        notificationId: notificationId,
        title: title,
        body: request.body,
        urgency: request.urgency,
        sound: request.sound,
        timeout: request.timeout,
        payload: TerminalNotificationPayload(
          hostId: session.hostId,
          connectionId: session.connectionId,
          platformNotificationId: notificationId,
          notificationIdentifier: request.identifier,
          reportsActivation: request.reportsActivation,
          focusOnActivation: request.focusOnActivation,
        ),
      );
    } on Object {
      _removeTerminalNotificationGeneration(expiryKey, generation);
      rethrow;
    }
    if (_terminalNotificationGenerations[expiryKey] != generation) {
      if (didShow) {
        await notificationService.clearTerminalNotification(notificationId);
      }
      return;
    }
    if (!didShow) {
      _removeTerminalNotificationGeneration(expiryKey, generation);
      return;
    }
    session.markTerminalNotificationPresented(request);
    final timeout = request.timeout;
    if (timeout == null) {
      _removeTerminalNotificationGeneration(expiryKey, generation);
      return;
    }
    if (_terminalNotificationExpiries.length >=
        _maxTerminalNotificationExpiries) {
      final oldestKey = _terminalNotificationExpiries.keys.first;
      final oldest = _terminalNotificationExpiries[oldestKey]!;
      _expireTerminalNotification(oldestKey, oldest);
    }
    late final _TerminalNotificationExpiry expiry;
    expiry = _TerminalNotificationExpiry(
      timer: Timer(
        timeout,
        () => _expireTerminalNotification(expiryKey, expiry),
      ),
      session: session,
      notificationService: notificationService,
      identifier: request.identifier,
    );
    _terminalNotificationExpiries[expiryKey] = expiry;
  }

  void _expireTerminalNotification(
    ({int connectionId, int notificationId}) key,
    _TerminalNotificationExpiry expiry,
  ) {
    if (!identical(_terminalNotificationExpiries[key], expiry)) return;
    _terminalNotificationExpiries.remove(key);
    expiry.timer.cancel();
    _terminalNotificationGenerations.remove(key);
    expiry.session.markTerminalNotificationClosed(expiry.identifier);
    unawaited(
      expiry.notificationService.clearTerminalNotification(key.notificationId),
    );
  }

  void _removeTerminalNotificationGeneration(
    ({int connectionId, int notificationId}) key,
    int generation,
  ) {
    if (_terminalNotificationGenerations[key] == generation) {
      _terminalNotificationGenerations.remove(key);
    }
  }

  Future<String> _resolveSessionLabel(SshSession session) async {
    final windowTitle = session.windowTitle;
    if (windowTitle != null && windowTitle.trim().isNotEmpty) {
      return windowTitle.trim();
    }
    try {
      final host = await ref
          .read(hostRepositoryProvider)
          .getById(session.hostId);
      if (host != null && host.label.trim().isNotEmpty) {
        return host.label.trim();
      }
    } on Object {
      // Fall through to the generic label below.
    }
    return 'Terminal';
  }

  void _detachSessionListeners(int connectionId, {SshSession? session}) {
    (session ?? _sshService.getSession(connectionId))?.removePreviewListener(
      _schedulePreviewStateRefresh,
    );
    unawaited(_disconnectSubscriptions.remove(connectionId)?.cancel());
    unawaited(
      _connectionHealthFailureSubscriptions.remove(connectionId)?.cancel(),
    );
    unawaited(
      _terminalNotificationSubscriptions.remove(connectionId)?.cancel(),
    );
    final expiries = _terminalNotificationExpiries.entries
        .where((entry) => entry.key.connectionId == connectionId)
        .toList(growable: false);
    for (final entry in expiries) {
      _expireTerminalNotification(entry.key, entry.value);
    }
    _terminalNotificationGenerations.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _terminalNotificationQueues.remove(connectionId)?.pending.clear();
    unawaited(_portForwardChangeSubscriptions.remove(connectionId)?.cancel());
  }

  void _schedulePreviewStateRefresh() {
    if (!ref.mounted) {
      return;
    }
    if (_previewStateRefreshTimer?.isActive ?? false) {
      return;
    }
    _previewStateRefreshTimer = Timer(_previewStateRefreshInterval, () {
      _previewStateRefreshTimer = null;
      if (!ref.mounted) {
        return;
      }
      state = {...state};
    });
  }

  /// Update the active coding-agent session title attached to a connection.
  void updateConnectionSessionTitle(int connectionId, String? sessionTitle) {
    final normalizedTitle = _normalizeConnectionSessionTitle(sessionTitle);
    final currentTitle = _connectionSessionTitles[connectionId];
    if (normalizedTitle == currentTitle ||
        (normalizedTitle == null && currentTitle == null)) {
      return;
    }
    if (normalizedTitle == null) {
      _connectionSessionTitles.remove(connectionId);
    } else {
      _connectionSessionTitles[connectionId] = normalizedTitle;
    }
    state = {...state};
  }

  String? _normalizeConnectionSessionTitle(String? sessionTitle) {
    final trimmed = sessionTitle?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<Host?> _telemetryHostForConnection(int hostId) async {
    try {
      return await ref.read(hostRepositoryProvider).getById(hostId);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.active',
        'host_metadata_load_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      return null;
    }
  }

  void _handleSessionPortForwardsChanged(int hostId) {
    if (!ref.mounted) {
      return;
    }
    state = {...state};
    final hostSessions = getConnectionsForHost(
      hostId,
    ).map(getSession).whereType<SshSession>().toList(growable: false);
    final manualRemoteListeners = _manualListenerExclusions(
      hostSessions.expand((session) => session.activeTunnels),
    );
    final endpointSession = hostSessions.isEmpty ? null : hostSessions.first;
    final endpointKey = endpointSession == null
        ? null
        : _sshEndpointKey(endpointSession.config);
    final shellOwnedListeners = endpointKey == null
        ? const <RemoteTcpListenerKey>{}
        : state.keys
              .map(getSession)
              .whereType<SshSession>()
              .where(
                (session) => _sshEndpointKey(session.config) == endpointKey,
              )
              .expand((session) => session.activeTunnels)
              .where(
                (tunnel) =>
                    tunnel.isAutomatic &&
                    tunnel.isShellRelated &&
                    tunnel.isLocal,
              )
              .map(
                (tunnel) =>
                    remoteTcpListenerKey(tunnel.remoteHost, tunnel.remotePort),
              )
              .toSet();
    final manualUnchanged = setEquals(
      _automaticForwardDesiredExclusionsByHost[hostId],
      manualRemoteListeners,
    );
    final shellOwnershipUnchanged =
        endpointKey == null ||
        setEquals(
          _automaticForwardShellOwnedByEndpoint[endpointKey],
          shellOwnedListeners,
        );
    if (manualUnchanged && shellOwnershipUnchanged) {
      return;
    }
    _automaticForwardDesiredExclusionsByHost[hostId] = Set.unmodifiable(
      manualRemoteListeners,
    );
    if (endpointKey != null) {
      _automaticForwardShellOwnedByEndpoint[endpointKey] = Set.unmodifiable(
        shellOwnedListeners,
      );
    }
    unawaited(reconfigureAutomaticPortForwardingForHost(hostId));
  }

  void _updateConnectionAttempt(
    int hostId,
    ConnectionProgressUpdate update, {
    bool resetLog = false,
    bool? cancelRequested,
    bool cancelled = false,
  }) {
    final existing = resetLog ? null : _connectionAttempts[hostId];
    final nextLogLines = <String>[if (existing != null) ...existing.logLines];
    if (nextLogLines.isEmpty || nextLogLines.last != update.message) {
      nextLogLines.add(update.message);
    }
    if (nextLogLines.length > 8) {
      nextLogLines.removeRange(0, nextLogLines.length - 8);
    }

    _connectionAttempts[hostId] = ConnectionAttemptStatus(
      hostId: hostId,
      state: update.state,
      latestMessage: update.message,
      logLines: List.unmodifiable(nextLogLines),
      cancelRequested:
          cancelRequested ?? (existing?.cancelRequested ?? false) || cancelled,
      cancelled: cancelled,
    );
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'attempt_update',
      fields: {'hostId': hostId, 'state': update.state},
    );
    state = {...state};
  }

  /// Abandon the in-flight connection attempt(s) for [hostId].
  ///
  /// Returns `true` when at least one cancellable attempt was found. Every
  /// concurrent attempt for the host is cancelled, and each resolves with a
  /// cancelled [SshConnectionResult] shortly afterwards.
  bool cancelConnectionAttempt(int hostId) {
    final tokens = _connectionCancellationTokens[hostId];
    final cancellable =
        tokens?.where((token) => !token.isCancelled).toList(growable: false) ??
        const <SshConnectionCancellationToken>[];
    if (cancellable.isEmpty) {
      return false;
    }
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'attempt_cancel_requested',
      fields: {'hostId': hostId, 'attemptCount': cancellable.length},
    );
    final existing = _connectionAttempts[hostId];
    _updateConnectionAttempt(
      hostId,
      ConnectionProgressUpdate(
        state: existing?.state ?? SshConnectionState.connecting,
        message: 'Cancelling connection…',
      ),
      cancelRequested: true,
    );
    for (final token in cancellable) {
      token.cancel();
    }
    return true;
  }

  /// Surface an unexpected connection failure in the shared attempt state.
  void reportConnectionAttemptError(int hostId, String message) {
    _updateConnectionAttempt(
      hostId,
      ConnectionProgressUpdate(
        state: SshConnectionState.error,
        message: message,
      ),
    );
  }

  /// Remove a connection that closed outside the normal user disconnect path.
  Future<void> handleUnexpectedDisconnect(
    int connectionId, {
    required String message,
  }) => _disconnect(connectionId, message: message);

  /// Update the session-specific terminal theme for an active connection.
  void updateSessionTheme(
    int connectionId,
    String themeId, {
    required bool isDark,
  }) {
    final session = _sshService.getSession(connectionId);
    if (session == null) {
      return;
    }
    final changed = session.setTerminalThemeId(themeId, isDark: isDark);
    if (!changed) {
      return;
    }
    state = {...state};
  }

  /// Update the session-specific terminal font size for an active connection.
  void updateSessionFontSize(int connectionId, double fontSize) {
    final session = _sshService.getSession(connectionId);
    if (session == null) {
      return;
    }
    session.terminalFontSize = fontSize;
    state = {...state};
  }

  /// Updates the native ACP session focused inside an active connection.
  void updateSessionNativeAcpFocus(
    int connectionId, {
    required AcpSessionKey? key,
    String? displayTitle,
  }) {
    final session = getSession(connectionId);
    if (session == null ||
        (session.activeNativeAcpSessionKey == key &&
            session.activeNativeAcpDisplayTitle == displayTitle)) {
      return;
    }
    final focusChanged = session.activeNativeAcpSessionKey != key;
    session
      ..activeNativeAcpSessionKey = key
      ..activeNativeAcpDisplayTitle = displayTitle;
    if (focusChanged || key == null) {
      session
        ..activeNativeAcpPreview = null
        ..activeNativeAcpPreviewSnapshot = null;
    }
    state = {...state};
  }

  /// Updates the bounded preview for the focused native ACP session.
  void updateSessionNativeAcpPreview(int connectionId, String? preview) {
    final session = getSession(connectionId);
    if (session == null ||
        session.activeNativeAcpSessionKey == null ||
        session.activeNativeAcpPreview == preview) {
      return;
    }
    session.activeNativeAcpPreview = preview;
    state = {...state};
  }

  /// Updates the role-aware preview for the focused native ACP session.
  void updateSessionNativeAcpPreviewSnapshot(
    int connectionId,
    AcpNativePreviewSnapshot? snapshot,
  ) {
    final session = getSession(connectionId);
    if (session == null ||
        session.activeNativeAcpSessionKey == null ||
        session.activeNativeAcpPreviewSnapshot == snapshot) {
      return;
    }
    session.activeNativeAcpPreviewSnapshot = snapshot;
    state = {...state};
  }

  /// Update clipboard sharing on all active sessions.
  void updateClipboardSharing({
    required bool enabled,
    required bool allowLocalClipboardRead,
  }) {
    for (final session in _sshService.allSessions) {
      session
        ..clipboardSharingEnabled = enabled
        ..localClipboardReadEnabled = allowLocalClipboardRead;
    }
  }

  Future<void> _syncBackgroundStatus() async {
    final connections = getActiveConnections();
    if (connections.isEmpty) {
      await BackgroundSshService.stop();
      return;
    }

    final connectedCount = connections
        .where((connection) => connection.state == SshConnectionState.connected)
        .length;

    await BackgroundSshService.updateStatus(
      connectionCount: connections.length,
      connectedCount: connectedCount,
    );
  }

  /// Publish the current active-connection status to native keepalive surfaces.
  Future<void> syncBackgroundStatus() => _queueBackgroundStatusSync();

  Future<void> _queueBackgroundStatusSync() {
    final nextSync = _backgroundStatusSyncQueue
        .catchError((Object _) {})
        .then((_) => _syncBackgroundStatus());
    _backgroundStatusSyncQueue = nextSync;
    return nextSync;
  }
}

class _TerminalNotificationExpiry {
  const _TerminalNotificationExpiry({
    required this.timer,
    required this.session,
    required this.notificationService,
    required this.identifier,
  });

  final Timer timer;
  final SshSession session;
  final LocalNotificationService notificationService;
  final String? identifier;
}

class _TerminalNotificationQueue {
  static const maxPending = 64;

  final List<TerminalNotificationRequest> pending = [];
  bool isProcessing = false;

  void add(TerminalNotificationRequest request) {
    final identity = request.platformIdentifier;
    if (identity != null) {
      pending.removeWhere((queued) => queued.platformIdentifier == identity);
    }
    if (pending.length >= maxPending) {
      pending.removeAt(0);
    }
    pending.add(request);
  }
}
