import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';

/// One diagnostics event with fields captured at logging time.
class RecordedDiagnosticsEvent {
  /// Creates a recorded event.
  const RecordedDiagnosticsEvent(
    this.level,
    this.category,
    this.message,
    this.fields,
  );

  /// Severity of the event.
  final DiagnosticsLogLevel level;

  /// Event category.
  final String category;

  /// Event name.
  final String message;

  /// Snapshot of the event metadata.
  final Map<String, Object?> fields;

  /// Text for privacy assertions across all event values.
  String get searchableText => [
    level.name,
    category,
    message,
    for (final entry in fields.entries) '${entry.key}=${entry.value}',
  ].join(' ');
}

/// Records diagnostics for assertions without writing to the app log.
class RecordingDiagnosticsLogger implements DiagnosticsLogger {
  /// Events in the order they were logged.
  final events = <RecordedDiagnosticsEvent>[];

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(DiagnosticsLogLevel.debug, category, message, fields);

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(DiagnosticsLogLevel.error, category, message, fields);

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(DiagnosticsLogLevel.info, category, message, fields);

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(DiagnosticsLogLevel.warning, category, message, fields);

  void _record(
    DiagnosticsLogLevel level,
    String category,
    String message,
    Map<String, Object?> fields,
  ) {
    events.add(
      RecordedDiagnosticsEvent(
        level,
        category,
        message,
        Map<String, Object?>.from(fields),
      ),
    );
  }
}
