import 'package:flutter/foundation.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

/// Recorded analytics event from [FakeTelemetryAnalyticsClient].
class RecordedTelemetryEvent {
  /// Creates a recorded analytics event.
  const RecordedTelemetryEvent({required this.name, required this.parameters});

  /// Event name.
  final String name;

  /// Event parameter map.
  final Map<String, Object> parameters;
}

/// Recorded error from [FakeTelemetryCrashReporter].
class RecordedTelemetryError {
  /// Creates a recorded crash-reporter error.
  const RecordedTelemetryError({
    required this.error,
    required this.stackTrace,
    required this.fatal,
    required this.keys,
  });

  /// Recorded error object.
  final Object error;

  /// Recorded stack trace.
  final StackTrace stackTrace;

  /// Whether the error was reported as fatal.
  final bool fatal;

  /// Snapshot of custom keys set when the error was recorded.
  final Map<String, Object> keys;

  /// Convenience getter for sanitized telemetry error reasons.
  String get reason => (error as SanitizedTelemetryError).reason;
}

/// Recording in-memory [TelemetryAnalyticsClient] for tests.
class FakeTelemetryAnalyticsClient implements TelemetryAnalyticsClient {
  /// Logged analytics events in order.
  final List<RecordedTelemetryEvent> events = <RecordedTelemetryEvent>[];

  /// History of [setCollectionEnabled] updates.
  final List<bool> collectionUpdates = <bool>[];

  /// Most recent collection state, if updated.
  bool? collectionEnabled;

  /// Number of [resetAnalyticsData] calls.
  int resetCount = 0;

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    events.add(RecordedTelemetryEvent(name: name, parameters: parameters));
  }

  @override
  Future<void> resetAnalyticsData() async {
    resetCount += 1;
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionUpdates.add(enabled);
    collectionEnabled = enabled;
  }
}

/// Recording in-memory [TelemetryCrashReporter] for tests.
class FakeTelemetryCrashReporter implements TelemetryCrashReporter {
  /// Errors passed to [recordError].
  final List<RecordedTelemetryError> recordedErrors =
      <RecordedTelemetryError>[];

  /// Flutter errors passed to [recordFlutterError].
  final List<FlutterErrorDetails> recordedFlutterErrors =
      <FlutterErrorDetails>[];

  /// Latest custom keys set via [setCustomKey].
  final Map<String, Object> customKeys = <String, Object>{};

  /// Most recent collection state, if updated.
  bool? collectionEnabled;

  /// Number of [deleteUnsentReports] calls.
  int deleteUnsentReportsCount = 0;

  @override
  Future<void> deleteUnsentReports() async {
    deleteUnsentReportsCount += 1;
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {
    recordedErrors.add(
      RecordedTelemetryError(
        error: error,
        stackTrace: stackTrace,
        fatal: fatal,
        keys: Map<String, Object>.of(customKeys),
      ),
    );
  }

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    recordedFlutterErrors.add(details);
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionEnabled = enabled;
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    customKeys[key] = value;
  }
}
