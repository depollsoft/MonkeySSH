import 'acp_updates.dart';

/// Longest subject line kept for a permission prompt.
const kAcpToolSubjectMaxCharacters = 160;

/// Raw-input keys that name what a tool acts on, most specific first.
///
/// ACP leaves `rawInput` opaque, but adapters converge on these names for the
/// command, file, or URL a tool targets.
const _subjectKeys = <String>[
  'command',
  'cmd',
  'file_path',
  'filePath',
  'path',
  'abs_path',
  'notebook_path',
  'url',
  'pattern',
  'query',
];

/// Returns a one-line description of what [toolCall] acts on, such as the
/// command it runs or the file it edits, or `null` when nothing is evident.
///
/// Prefers an explicit command or path in `rawInput`, then a diff's path, then
/// the first reported location. The result is for on-screen context only and
/// must never be logged.
String? acpToolCallSubject(AcpToolCallUpdate toolCall) {
  final rawInput = toolCall.rawInput;
  if (rawInput is Map) {
    for (final key in _subjectKeys) {
      final subject = _subjectText(rawInput[key]);
      if (subject != null) return subject;
    }
  }
  for (final content in toolCall.content ?? const <AcpToolContent>[]) {
    if (content is AcpToolDiff) {
      final subject = _subjectText(content.path);
      if (subject != null) return subject;
    }
  }
  final locations = toolCall.locations ?? const <AcpToolLocation>[];
  if (locations.isNotEmpty) {
    final location = locations.first;
    final line = location.line;
    return _subjectText(
      line == null ? location.path : '${location.path}:$line',
    );
  }
  return null;
}

String? _subjectText(Object? value) {
  final String text;
  if (value is String) {
    text = value;
  } else if (value is List && value.isNotEmpty && value.every(_isScalar)) {
    text = value.join(' ');
  } else {
    return null;
  }
  final firstLine = text
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (firstLine.isEmpty) return null;
  final collapsed = firstLine.replaceAll(RegExp(r'\s+'), ' ');
  final multiline = text.trim().contains('\n');
  if (collapsed.length > kAcpToolSubjectMaxCharacters) {
    return '${collapsed.substring(0, kAcpToolSubjectMaxCharacters - 1)}…';
  }
  return multiline ? '$collapsed …' : collapsed;
}

bool _isScalar(Object? value) => value is String || value is num;
