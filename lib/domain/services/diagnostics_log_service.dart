import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_metadata.dart';

/// Severity for a diagnostics log entry.
enum DiagnosticsLogLevel {
  /// Verbose diagnostics useful when tracing event flow.
  debug,

  /// Informational lifecycle event.
  info,

  /// Recoverable unexpected behavior.
  warning,

  /// Error or failure path.
  error,
}

/// Minimal diagnostics logging seam for services that emit safe metadata.
abstract interface class DiagnosticsLogger {
  /// Records a debug event.
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  });

  /// Records an informational event.
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  });

  /// Records a warning event.
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  });

  /// Records an error event.
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  });
}

/// Diagnostics logger that drops all events.
class NoopDiagnosticsLogger implements DiagnosticsLogger {
  /// Creates a diagnostics logger that drops events.
  const NoopDiagnosticsLogger();

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}
}

/// A single sanitized diagnostics log entry.
@immutable
class DiagnosticsLogEntry {
  /// Creates a diagnostics log entry.
  const DiagnosticsLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.fields = const <String, Object?>{},
  });

  /// When the event was recorded.
  final DateTime timestamp;

  /// Event severity.
  final DiagnosticsLogLevel level;

  /// Short namespace for the event producer.
  final String category;

  /// Short event name.
  final String message;

  /// Sanitized key/value details.
  final Map<String, Object?> fields;

  /// Formats the entry as a single copy/paste-friendly line.
  String format() {
    final buffer = StringBuffer()
      ..write(timestamp.toUtc().toIso8601String())
      ..write(' ')
      ..write(level.name.toUpperCase())
      ..write(' ')
      ..write(category)
      ..write(' ')
      ..write(message);
    for (final entry in fields.entries) {
      buffer
        ..write(' ')
        ..write(entry.key)
        ..write('=')
        ..write(_formatValue(entry.value));
    }
    return buffer.toString();
  }

  static String _formatValue(Object? value) {
    if (value == null) return 'null';
    final text = value.toString();
    if (text.contains(' ') || text.contains('\n') || text.contains('\t')) {
      return '"${text.replaceAll('"', r'\"')}"';
    }
    return text;
  }
}

/// Preview/beta-only diagnostics log with strict field sanitization.
class DiagnosticsLogService extends ChangeNotifier
    implements DiagnosticsLogger {
  /// Creates a diagnostics logger.
  DiagnosticsLogService({
    required this.enabled,
    DateTime Function()? now,
    int maxEntries = 1200,
  }) : _now = now ?? DateTime.now,
       _maxEntries = maxEntries < 1 ? 1 : maxEntries;

  /// Shared diagnostics logger used by app services.
  static final instance = DiagnosticsLogService(
    enabled: isDiagnosticsLoggingEnabled,
  );

  static final _quietDebugZoneKey = Object();

  /// Runs [body] with the debug entries of its call chain dropped.
  ///
  /// For background polls that repeat every few seconds, whose routine
  /// install-cache, exec-queue and channel entries would otherwise evict
  /// useful history from the ring buffer. Info, warnings and errors are kept.
  static R runWithoutDebugEntries<R>(R Function() body) =>
      runZoned(body, zoneValues: {_quietDebugZoneKey: true});

  static const _redacted = '[redacted]';
  static const _maxStringLength = 160;
  static const _notifyDebounce = Duration(milliseconds: 250);

  static const _sensitiveFieldNames = <String>{
    'command',
    'cwd',
    'host',
    'hostname',
    'icon',
    'key',
    'name',
    'output',
    'pane',
    'passphrase',
    'password',
    'path',
    'privatekey',
    'rawcommand',
    'session',
    'sessionname',
    'stderr',
    'stdin',
    'stdout',
    'terminaloutput',
    'title',
    'token',
    'username',
    'windowname',
    'windowtitle',
    'workingdirectory',
  };

  static const _safeStringFieldNames = <String>{
    'action',
    'category',
    'commandkind',
    'errortype',
    'eventtype',
    'kind',
    'linekind',
    'mode',
    'platform',
    'reason',
    'result',
    'shellstatus',
    'state',
    'status',
  };

  static final _unsafeStringPattern = RegExp(
    r'(?:BEGIN [A-Z ]*PRIVATE KEY|ssh-[a-z0-9-]+ |\bfile://|/[^ ]+|\\[^ ]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)',
    caseSensitive: false,
  );
  static final _unsafeKeyPattern = RegExp('[^A-Za-z0-9_.-]+');
  static final _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F]');

  /// Whether logging is enabled for this build.
  final bool enabled;

  final DateTime Function() _now;
  final int _maxEntries;
  final Queue<DiagnosticsLogEntry> _entries = Queue<DiagnosticsLogEntry>();
  Timer? _notifyTimer;

  /// Number of retained entries.
  int get entryCount => _entries.length;

  /// Returns a copy of the currently retained log entries.
  List<DiagnosticsLogEntry> snapshot() => List.unmodifiable(_entries);

  /// Clears all retained diagnostics entries.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }

  /// Records a debug event.
  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _add(DiagnosticsLogLevel.debug, category, message, fields);

  /// Records an informational event.
  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _add(DiagnosticsLogLevel.info, category, message, fields);

  /// Records a warning event.
  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _add(DiagnosticsLogLevel.warning, category, message, fields);

  /// Records an error event.
  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _add(DiagnosticsLogLevel.error, category, message, fields);

  /// Formats retained diagnostics with a small safe metadata header.
  String exportText({AppMetadata? appMetadata}) {
    final buffer = StringBuffer()
      ..writeln('MonkeySSH diagnostics')
      ..writeln('generatedAt=${_now().toUtc().toIso8601String()}')
      ..writeln('entryCount=${_entries.length}')
      ..writeln('flutterMode=${_flutterMode()}')
      ..writeln('platform=${defaultTargetPlatform.name}');
    if (appMetadata != null) {
      buffer
        ..writeln('appVersion=${_sanitizeString(appMetadata.versionLabel)}')
        ..writeln(
          'previewBuild=${appMetadata.pullRequestNumber == null ? 'no' : 'PR #${appMetadata.pullRequestNumber}'}',
        );
    }
    buffer
      ..writeln()
      ..writeln(
        'Privacy: hostnames, usernames, commands, paths, window titles, terminal output, keys, passwords, and tokens are not recorded.',
      )
      ..writeln();
    for (final entry in _entries) {
      buffer.writeln(entry.format());
    }
    return buffer.toString();
  }

  void _add(
    DiagnosticsLogLevel level,
    String category,
    String message,
    Map<String, Object?> fields,
  ) {
    if (!enabled) return;
    if (level == DiagnosticsLogLevel.debug &&
        Zone.current[_quietDebugZoneKey] == true) {
      return;
    }
    final sanitizedFields = <String, Object?>{};
    for (final entry in fields.entries) {
      final key = _sanitizeKey(entry.key);
      sanitizedFields[key] = _sanitizeValue(key, entry.value);
    }
    _entries.addLast(
      DiagnosticsLogEntry(
        timestamp: _now(),
        level: level,
        category: _sanitizeKey(category),
        message: _sanitizeMessage(message),
        fields: Map.unmodifiable(sanitizedFields),
      ),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _scheduleNotifyListeners();
  }

  void _scheduleNotifyListeners() {
    if (_notifyTimer?.isActive ?? false) {
      return;
    }
    _notifyTimer = Timer(_notifyDebounce, () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  static String _sanitizeKey(String key) {
    final sanitized = key.replaceAll(_unsafeKeyPattern, '_').trim();
    if (sanitized.isEmpty) return 'field';
    return sanitized.length > 48 ? sanitized.substring(0, 48) : sanitized;
  }

  static String _sanitizeMessage(String message) {
    final sanitized = _sanitizeString(message);
    return sanitized.replaceAll(' ', '_');
  }

  static Object? _sanitizeValue(String key, Object? value) {
    if (value == null || value is bool || value is num) {
      return value;
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is Duration) {
      return '${value.inMilliseconds}ms';
    }
    if (value is Enum) {
      return value.name;
    }
    if (value is Iterable<Object?>) {
      return '${value.length}_items';
    }
    if (value is Map<Object?, Object?>) {
      return '${value.length}_entries';
    }

    final normalizedKey = key.toLowerCase();
    if (_isSensitiveKey(normalizedKey)) {
      return _redacted;
    }

    final sanitized = _sanitizeString(value.toString());
    if (!_safeStringFieldNames.contains(normalizedKey) &&
        _unsafeStringPattern.hasMatch(sanitized)) {
      return _redacted;
    }
    return sanitized;
  }

  static bool _isSensitiveKey(String key) {
    if (_sensitiveFieldNames.contains(key)) {
      return true;
    }
    return key.contains('password') ||
        key.contains('passphrase') ||
        key.contains('privatekey') ||
        key.contains('token') ||
        key.contains('secret') ||
        key.contains('hostname') ||
        key == 'username' ||
        key.endsWith('path') ||
        key.endsWith('command') ||
        key.endsWith('title');
  }

  static String _sanitizeString(String value) {
    final sanitized = value.replaceAll(_controlCharacterPattern, '').trim();
    if (sanitized.length <= _maxStringLength) {
      return sanitized;
    }
    return '${sanitized.substring(0, _maxStringLength)}...';
  }

  static String _flutterMode() {
    if (kReleaseMode) return 'release';
    if (kProfileMode) return 'profile';
    return 'debug';
  }
}

/// Provider for the preview diagnostics log.
final diagnosticsLogServiceProvider = Provider<DiagnosticsLogService>(
  (ref) => DiagnosticsLogService.instance,
);

/// Provider for injectable diagnostics logging seams.
final diagnosticsLoggerProvider = Provider<DiagnosticsLogger>(
  (ref) => ref.watch(diagnosticsLogServiceProvider),
);
