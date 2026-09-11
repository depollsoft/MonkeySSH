import 'dart:async';

/// The output stream closed before a complete command marker arrived.
class CommandOutputMarkerMissingException implements Exception {
  /// Creates a missing-marker failure.
  const CommandOutputMarkerMissingException();
}

/// Reads marker-framed output, optionally retaining partial output on timeout.
/// Partial-output callers also retain output when the stream closes early.
Future<({String output, int? status})> readCommandOutputUntilMarker(
  Stream<String> chunks,
  String marker, {
  bool allowPartialOnTimeout = false,
  void Function(String chunk)? onChunk,
}) async {
  final pattern = RegExp('^${RegExp.escape(marker)}:([0-9]+)\$');
  final output = StringBuffer();
  final line = StringBuffer();
  var separator = '';
  try {
    await for (final chunk in chunks) {
      onChunk?.call(chunk);
      final parts = chunk.split('\n');
      for (final part in parts.take(parts.length - 1)) {
        line.write(part);
        final text = line.toString();
        line.clear();
        final match = pattern.firstMatch(text);
        if (match != null) {
          return (
            output: output.toString(),
            status: int.parse(match.group(1)!),
          );
        }
        output
          ..write(separator)
          ..write(text);
        separator = '\n';
      }
      line.write(parts.last);
    }
  } on TimeoutException {
    if (!allowPartialOnTimeout) rethrow;
  }
  if (!allowPartialOnTimeout) {
    throw const CommandOutputMarkerMissingException();
  }
  return (output: '$output$separator$line', status: null);
}
