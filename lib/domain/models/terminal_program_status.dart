import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'terminal_progress.dart';

/// OSC code of the Program Status Protocol, revision 0.3:
/// https://superlogical.com/rex/docs/build/program-status
const terminalProgramStatusOscCode = '7501';

/// Reply to OSC 7501 feature detection (`OSC 7501 ; ? ST`).
///
/// Programs such as Claude Code report nothing until a terminal sends it.
const terminalProgramStatusQueryReply = '\x1b]7501;?\x1b\\';

/// What a program reported it is doing through OSC 7501.
enum TerminalProgramState {
  /// At rest, waiting for input.
  idle,

  /// Running, optionally with progress.
  working,

  /// Cannot continue until the user acts.
  blocked,

  /// Finished, with a result the user has not seen yet.
  done,

  /// Failed and stopped.
  error,
}

/// What a blocked program needs from the user.
enum TerminalProgramBlockedKind {
  /// Approval to go ahead.
  permission,

  /// An answer to a question.
  question,

  /// Signing in.
  auth,
}

/// A program's self-reported status: one OSC 7501 record.
@immutable
class TerminalProgramStatus {
  /// Creates a program status.
  const TerminalProgramStatus({
    required this.state,
    this.kind,
    this.progress,
    this.app,
    this.title,
    this.message,
  });

  /// Parses the `programStatus` object of a MonkeyMux window snapshot.
  ///
  /// Returns null for anything that is not a known state, so a newer server
  /// cannot make an older app show a wrong status.
  static TerminalProgramStatus? fromJson(Object? value) {
    if (value is! Map) return null;
    final state = _stateNames[value['state']];
    if (state == null) return null;
    final progress = value['progress'];
    return TerminalProgramStatus(
      state: state,
      kind: state == TerminalProgramState.blocked
          ? _kindNames[value['kind']]
          : null,
      progress:
          (state == TerminalProgramState.working ||
                  state == TerminalProgramState.blocked) &&
              progress is int &&
              progress >= 0 &&
              progress <= 100
          ? progress
          : null,
      app: _nonEmptyString(value['app']),
      title: _nonEmptyString(value['title']),
      message: _nonEmptyString(value['msg']),
    );
  }

  /// The reported state.
  final TerminalProgramState state;

  /// What a [TerminalProgramState.blocked] program needs, when it said.
  final TerminalProgramBlockedKind? kind;

  /// Whole-number percentage for working or blocked programs, when known.
  final int? progress;

  /// Stable machine name of the reporting program, such as `claude-code`.
  final String? app;

  /// Short label of the record, used by programs that report several tasks.
  final String? title;

  /// One line of human-readable detail. Display it; never log it.
  final String? message;

  /// Short lowercase label for status pills, in the waiting/working
  /// vocabulary the rest of the mux list uses.
  String get label => switch (state) {
    TerminalProgramState.idle => 'waiting',
    TerminalProgramState.working => 'working',
    TerminalProgramState.blocked => switch (kind) {
      TerminalProgramBlockedKind.permission => 'approval',
      TerminalProgramBlockedKind.question => 'question',
      TerminalProgramBlockedKind.auth => 'sign in',
      null => 'blocked',
    },
    TerminalProgramState.done => 'done',
    TerminalProgramState.error => 'error',
  };

  /// Screen-reader phrase completing "terminal window …".
  String get semanticsLabel => switch (state) {
    TerminalProgramState.idle => 'is waiting for input',
    TerminalProgramState.working =>
      progress == null ? 'is working' : 'is working, $progress percent',
    TerminalProgramState.blocked => switch (kind) {
      TerminalProgramBlockedKind.permission => 'needs approval',
      TerminalProgramBlockedKind.question => 'has a question',
      TerminalProgramBlockedKind.auth => 'needs you to sign in',
      null => 'is waiting for you',
    },
    TerminalProgramState.done => 'is done',
    TerminalProgramState.error => 'failed',
  };

  /// The detail worth showing in place of a window's subtitle: what a blocked
  /// program is waiting for, or why it failed.
  String? get attentionMessage =>
      state == TerminalProgramState.blocked ||
          state == TerminalProgramState.error
      ? message
      : null;

  /// Projects work in progress onto the bar that also shows OSC 9;4 progress.
  ///
  /// A blocked program keeps its determinate progress in the warning color;
  /// one without progress shows no bar, since nothing is moving.
  TerminalProgress? get terminalProgress => switch (state) {
    TerminalProgramState.working =>
      progress == null
          ? const TerminalProgress(state: TerminalProgressState.indeterminate)
          : TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: progress,
            ),
    TerminalProgramState.blocked =>
      progress == null
          ? null
          : TerminalProgress(
              state: TerminalProgressState.pausedOrWarning,
              percentage: progress,
            ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalProgramStatus &&
          state == other.state &&
          kind == other.kind &&
          progress == other.progress &&
          app == other.app &&
          title == other.title &&
          message == other.message;

  @override
  int get hashCode => Object.hash(state, kind, progress, app, title, message);
}

/// The OSC 7501 records of a terminal the app itself draws, such as a plain
/// SSH shell. Inside MonkeyMux the server keeps records per window instead.
class TerminalProgramStatusRecords {
  final _records = <String, _ProgramStatusRecord>{};
  int _clock = 0;

  /// Most records kept. The spec requires at least 64; past the cap the least
  /// recently updated record is evicted.
  static const maxRecords = 64;

  /// Whether [body], the text after `OSC 7501 ;`, is feature detection.
  static bool isQuery(String body) => body.startsWith('?');

  /// Number of records held.
  int get length => _records.length;

  /// The most urgent record: blocked, then error, working, done and idle,
  /// preferring the shallowest and then the most recently updated record. A
  /// record without an app inherits its nearest ancestor's.
  TerminalProgramStatus? get summary {
    MapEntry<String, _ProgramStatusRecord>? best;
    for (final entry in _records.entries) {
      if (best == null || _outranks(entry, best)) best = entry;
    }
    if (best == null) return null;
    final status = best.value.status;
    final app = _appFor(best.key);
    return app == status.app
        ? status
        : TerminalProgramStatus(
            state: status.state,
            kind: status.kind,
            progress: status.progress,
            app: app,
            title: status.title,
            message: status.message,
          );
  }

  /// Applies a report body. Malformed reports are ignored, as the spec
  /// requires. Returns whether [summary] may have changed.
  bool apply(String body) {
    final report = _parseReport(body);
    if (report == null) return false;
    if (report.status == null) {
      _clear(report.id);
      return true;
    }
    _records[report.id] = _ProgramStatusRecord(report.status!, ++_clock);
    while (_records.length > maxRecords) {
      final oldest = _records.entries.reduce(
        (a, b) => a.value.updated <= b.value.updated ? a : b,
      );
      _records.remove(oldest.key);
    }
    return true;
  }

  /// Drops the records of a program that has stopped running (idle, working
  /// and blocked) at a shell prompt; done and error outlive it.
  bool dropRunning() {
    final before = _records.length;
    _records.removeWhere(
      (_, record) => switch (record.status.state) {
        TerminalProgramState.idle ||
        TerminalProgramState.working ||
        TerminalProgramState.blocked => true,
        _ => false,
      },
    );
    return _records.length != before;
  }

  /// Removes every record.
  bool clear() {
    if (_records.isEmpty) return false;
    _records.clear();
    return true;
  }

  void _clear(String id) {
    if (id.isEmpty) {
      _records.clear();
      return;
    }
    _records.removeWhere((key, _) => key == id || key.startsWith('$id/'));
  }

  String? _appFor(String id) {
    var current = id;
    while (true) {
      final app = _records[current]?.status.app;
      if (app != null) return app;
      if (current.isEmpty) return null;
      final slash = current.lastIndexOf('/');
      current = slash < 0 ? '' : current.substring(0, slash);
    }
  }

  static bool _outranks(
    MapEntry<String, _ProgramStatusRecord> candidate,
    MapEntry<String, _ProgramStatusRecord> other,
  ) {
    final urgency = _urgency(candidate.value.status.state);
    final otherUrgency = _urgency(other.value.status.state);
    if (urgency != otherUrgency) return urgency > otherUrgency;
    final depth = _depth(candidate.key);
    final otherDepth = _depth(other.key);
    if (depth != otherDepth) return depth < otherDepth;
    return candidate.value.updated > other.value.updated;
  }

  static int _urgency(TerminalProgramState state) => switch (state) {
    TerminalProgramState.blocked => 4,
    TerminalProgramState.error => 3,
    TerminalProgramState.working => 2,
    TerminalProgramState.done => 1,
    TerminalProgramState.idle => 0,
  };

  static int _depth(String id) =>
      id.isEmpty ? 0 : '/'.allMatches(id).length + 1;
}

class _ProgramStatusRecord {
  const _ProgramStatusRecord(this.status, this.updated);

  final TerminalProgramStatus status;
  final int updated;
}

/// A parsed report; a null [status] is `state=clear`.
typedef _ProgramStatusReport = ({String id, TerminalProgramStatus? status});

// Hard caps from the spec. A report that breaks one is discarded whole.
const _maxSequenceBytes = 4096;
const _maxKeyBytes = 16;
const _maxMsgEncodedBytes = 2732;
const _maxMsgDecodedBytes = 2048;
const _maxTitleEncodedBytes = 256;
const _maxTitleDecodedBytes = 192;
const _maxNameBytes = 32;
const _maxIdBytes = 128;
const _maxIdDepth = 8;

const _stateNames = {
  'idle': TerminalProgramState.idle,
  'working': TerminalProgramState.working,
  'blocked': TerminalProgramState.blocked,
  'done': TerminalProgramState.done,
  'error': TerminalProgramState.error,
};

const _kindNames = {
  'permission': TerminalProgramBlockedKind.permission,
  'question': TerminalProgramBlockedKind.question,
  'auth': TerminalProgramBlockedKind.auth,
};

final _keyPattern = RegExp(r'^[a-z]+$');
final _valuePattern = RegExp(r'^[A-Za-z0-9_.,+/=-]*$');
final _namePattern = RegExp(r'^[A-Za-z0-9_.+-]{1,32}$');
final _base64Pattern = RegExp(r'^[A-Za-z0-9+/]*$');
final _progressPattern = RegExp(r'^[0-9]{1,3}$');

_ProgramStatusReport? _parseReport(String body) {
  // The cap is in bytes; a UTF-16 code unit is at least one UTF-8 byte.
  if (body.length > _maxSequenceBytes ||
      utf8.encode(body).length > _maxSequenceBytes) {
    return null;
  }
  final fields = <String, String>{};
  for (final pair in body.split(':')) {
    final separator = pair.indexOf('=');
    final key = _trim(separator < 0 ? pair : pair.substring(0, separator));
    if (!_keyPattern.hasMatch(key)) continue;
    if (key.length > _maxKeyBytes) return null;
    final value = separator < 0 ? null : _trim(pair.substring(separator + 1));
    if (value == null || !_valuePattern.hasMatch(value)) {
      // An id the report tried to set but got wrong must not fall back to
      // the root record.
      if (key == 'id') return null;
      continue;
    }
    fields[key] = value;
  }

  final stateName = fields['state'];
  final state = _stateNames[stateName];
  if (state == null && stateName != 'clear') return null;
  final id = fields['id'] ?? '';
  if (fields.containsKey('id') && !_validId(id)) return null;
  String? app;
  if (fields['app'] case final value?) {
    if (value.length > _maxNameBytes) return null;
    if (_namePattern.hasMatch(value)) app = value;
  }
  final title = _decodeText(
    fields['title'],
    _maxTitleEncodedBytes,
    _maxTitleDecodedBytes,
  );
  final message = _decodeText(
    fields['msg'],
    _maxMsgEncodedBytes,
    _maxMsgDecodedBytes,
  );
  if (title == null || message == null) return null;
  if (state == null) return (id: id, status: null);

  final progressText = fields['progress'];
  final progress =
      progressText != null && _progressPattern.hasMatch(progressText)
      ? int.parse(progressText)
      : null;
  final hasProgress =
      state == TerminalProgramState.working ||
      state == TerminalProgramState.blocked;
  return (
    id: id,
    status: TerminalProgramStatus(
      state: state,
      kind: state == TerminalProgramState.blocked
          ? _kindNames[fields['kind']]
          : null,
      progress: hasProgress && progress != null && progress <= 100
          ? progress
          : null,
      app: app,
      title: title.isEmpty ? null : title,
      message: message.isEmpty ? null : message,
    ),
  );
}

String _trim(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && (value[start] == ' ' || value[start] == '\t')) {
    start++;
  }
  while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) {
    end--;
  }
  return value.substring(start, end);
}

bool _validId(String id) {
  if (id.length > _maxIdBytes) return false;
  final segments = id.split('/');
  return segments.length <= _maxIdDepth &&
      segments.every(_namePattern.hasMatch);
}

/// Decodes a base64 `msg` or `title`; padding is optional. Returns null when
/// the report must be discarded, and '' when the value is absent.
String? _decodeText(String? value, int maxEncoded, int maxDecoded) {
  if (value == null || value.isEmpty) return '';
  if (value.length > maxEncoded) return null;
  var unpadded = value;
  while (unpadded.endsWith('=')) {
    unpadded = unpadded.substring(0, unpadded.length - 1);
  }
  final padding = value.length - unpadded.length;
  if (padding > 2 ||
      (padding > 0 && value.length % 4 != 0) ||
      unpadded.length % 4 == 1 ||
      !_base64Pattern.hasMatch(unpadded)) {
    return null;
  }
  final String text;
  try {
    final bytes = base64.decode(
      unpadded.padRight((unpadded.length + 3) ~/ 4 * 4, '='),
    );
    if (bytes.length > maxDecoded) return null;
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  final output = StringBuffer();
  for (final rune in text.runes) {
    if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) return null;
    // Bidirectional formatting characters could reorder the text around the
    // message, so they are removed rather than shown.
    if (rune == 0x061c ||
        rune == 0x200e ||
        rune == 0x200f ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069)) {
      continue;
    }
    output.writeCharCode(rune);
  }
  return output.toString();
}

String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
