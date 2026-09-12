import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_metadata.dart';
import '../models/agent_launch_preset.dart';
import 'diagnostics_log_service.dart';
import 'settings_service.dart';

/// Compile-time flag that allows Firebase-backed telemetry to initialize.
const isFirebaseTelemetryBuildEnabled = bool.fromEnvironment(
  'FLUTTY_FIREBASE_ENABLED',
);

/// Current Firebase telemetry availability for this app run.
enum TelemetryServiceStatus {
  /// Firebase is initialized and can receive opted-in events.
  ready,

  /// The build did not opt in to Firebase initialization.
  disabledByBuild,

  /// Firebase telemetry is not supported on this platform.
  unsupportedPlatform,

  /// Firebase initialization failed, usually because config is missing.
  initializationFailed,
}

/// Minimal analytics client seam used by [TelemetryService].
abstract interface class TelemetryAnalyticsClient {
  /// Enables or disables analytics collection in the underlying SDK.
  Future<void> setCollectionEnabled({required bool enabled});

  /// Clears SDK analytics identifiers and local analytics data when available.
  Future<void> resetAnalyticsData();

  /// Records a single allowlisted analytics event.
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  });
}

/// Minimal crash reporter seam used by [TelemetryService].
abstract interface class TelemetryCrashReporter {
  /// Enables or disables crash report collection in the underlying SDK.
  Future<void> setCollectionEnabled({required bool enabled});

  /// Deletes locally retained crash reports that have not been uploaded.
  Future<void> deleteUnsentReports();

  /// Records a sanitized Flutter framework error.
  Future<void> recordFlutterError(FlutterErrorDetails details);

  /// Records a sanitized Dart error.
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  });

  /// Sets a primitive custom key for later crash reports.
  Future<void> setCustomKey(String key, Object value);
}

/// Privacy-preserving telemetry facade for product analytics and crash reports.
class TelemetryService {
  /// Creates a telemetry service.
  TelemetryService({
    required TelemetryServiceStatus status,
    required bool collectionEnabled,
    required DiagnosticsLogger diagnosticsLogger,
    TelemetryAnalyticsClient? analyticsClient,
    TelemetryCrashReporter? crashReporter,
    AbsorbedErrorRateLimiter? absorbedErrorRateLimiter,
  }) : _status = status,
       _collectionEnabled = collectionEnabled,
       _diagnosticsLogger = diagnosticsLogger,
       _analyticsClient = analyticsClient,
       _crashReporter = crashReporter,
       _absorbedErrorRateLimiter =
           absorbedErrorRateLimiter ?? _processAbsorbedErrorRateLimiter;

  static final _processAbsorbedErrorRateLimiter = AbsorbedErrorRateLimiter();

  static final RegExp _safeNamePattern = RegExp('[^a-z0-9]+');
  static final _camelCasePattern = RegExp('([a-z0-9])([A-Z])');
  static final _edgeUnderscores = RegExp(r'^_|_$');
  static const int _maxFirebaseStringLength = 80;
  static const _allowedFeatureNames = <String>{
    'agents',
    'auth',
    'home',
    'host_editor',
    'hosts',
    'key_editor',
    'keys',
    'port_forward_browser',
    'port_forward_editor',
    'port_forwards',
    'settings',
    'sftp',
    'snippet_editor',
    'snippets',
    'terminal',
    'upgrade',
  };
  static const _allowedPromptTriggers = <String>{
    'launches',
    'settings',
    'successful_connection',
  };
  static const _allowedCreationMethods = <String>{
    'from_terminal',
    'generated',
    'import',
    'manual',
  };
  static const _allowedAuthMethods = <String>{
    'key',
    'none',
    'password',
    'password_and_key',
    'unknown',
  };
  static const _allowedTransferDirections = <String>{'download', 'upload'};
  static const _allowedFailureCategories = <String>{
    'authentication',
    'cancelled',
    'connection',
    'declined',
    'failed',
    'host_key',
    'local_file',
    'network',
    'remote_status',
    'setup',
    'timeout',
    'unavailable',
    'unreadable',
    'unknown',
  };
  static const _allowedMuxBackends = <String>{'auto', 'monkeymux', 'tmux'};
  static final Set<String> _allowedAgentTools = _buildAllowedAgentTools();
  static const _allowedPaywallFeatures = <String>{
    'agent_management',
    'agent_usage_rings',
    'agent_launch_presets',
    'auto_connect_automation',
    'encrypted_transfers',
    'host_specific_themes',
    'migration_import_export',
    'settings',
  };
  static const _allowedPaywallSources = <String>{'feature_gate', 'settings'};
  static const _allowedProductTypes = <String>{
    'annual',
    'lifetime',
    'monthly',
    'unknown',
  };
  static const _allowedDisconnectCategories = <String>{
    'disconnect_all',
    'unexpected',
    'user',
  };
  static const _allowedPasteSources = <String>{
    'clipboard_files',
    'clipboard_image',
    'clipboard_text',
    'picked_files',
    'picked_media',
  };
  static const _allowedSelectionActions = <String>{
    'copy',
    'create_snippet',
    'look_up',
    'paste',
    'search_web',
    'share',
  };
  static const _allowedAcpProviderCategories = <String>{
    'copilot_cli',
    'claude_agent',
    'codex',
    'opencode',
    'cursor_agent',
    'antigravity',
    'pi',
    'grok_build',
    'hermes',
    'openclaw',
    'custom',
    'unknown',
  };
  static const _allowedAcpSessionEndReasons = <String>{
    'stopped',
    'provider_exited',
    'transport_failed',
    'closed',
    'app_disposed',
  };
  static const _allowedAcpAttachmentCategories = <String>{
    'image',
    'audio',
    'resource',
    'unknown',
  };
  static const _allowedAcpPermissionOutcomes = <String>{
    'selected',
    'cancelled',
    'write_approved',
    'write_rejected',
  };
  static const _allowedAcpFailureCategories = <String>{
    'bridge_unavailable',
    'bridge_expired',
    'provider_exited',
    'authentication_required',
    'unsupported_capability',
    'command_not_approved',
    'transport',
    'protocol',
    'timeout',
    'concurrency_blocked',
    'unknown',
  };

  final TelemetryServiceStatus _status;
  final DiagnosticsLogger _diagnosticsLogger;
  final TelemetryAnalyticsClient? _analyticsClient;
  final TelemetryCrashReporter? _crashReporter;
  final AbsorbedErrorRateLimiter _absorbedErrorRateLimiter;
  bool _collectionEnabled;
  Future<void> _collectionUpdates = Future<void>.value();
  Future<void> _crashReports = Future<void>.value();
  int _collectionRevision = 0;

  /// Whether Firebase telemetry is available in this app run.
  bool get isAvailable => _status == TelemetryServiceStatus.ready;

  /// Whether the user has opted in to telemetry collection.
  bool get collectionEnabled => _collectionEnabled;

  /// Availability status for Settings UI and diagnostics.
  TelemetryServiceStatus get status => _status;

  /// Enables or disables analytics and crash reporting collection.
  Future<void> setCollectionEnabled({required bool enabled}) async {
    final wasEnabled = _collectionEnabled;
    _collectionEnabled = enabled;
    _collectionRevision += 1;
    // Gate events immediately, but apply native SDK changes in request order.
    // Otherwise a slow enable can finish after a newer opt-out.
    final operation = _collectionUpdates.then(
      (_) => _applyCollectionEnabled(enabled: enabled, wasEnabled: wasEnabled),
    );
    _collectionUpdates = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _applyCollectionEnabled({
    required bool enabled,
    required bool wasEnabled,
  }) async {
    if (!isAvailable) {
      _diagnosticsLogger.info(
        'telemetry',
        'collection_preference_stored',
        fields: {'enabled': enabled, 'status': _status},
      );
      return;
    }

    final analyticsClient = _analyticsClient;
    final crashReporter = _crashReporter;
    if (analyticsClient == null || crashReporter == null) {
      _diagnosticsLogger.warning(
        'telemetry',
        'client_missing',
        fields: {'enabled': enabled},
      );
      return;
    }

    await _runSdkUpdate(
      'analytics_collection_update_failed',
      fields: {'enabled': enabled},
      operation: () => analyticsClient.setCollectionEnabled(enabled: enabled),
    );
    await _runSdkUpdate(
      'crash_collection_update_failed',
      fields: {'enabled': enabled},
      operation: () => crashReporter.setCollectionEnabled(enabled: enabled),
    );
    if (!enabled && wasEnabled) {
      await _runSdkUpdate(
        'analytics_reset_failed',
        operation: analyticsClient.resetAnalyticsData,
      );
      await _runSdkUpdate(
        'crash_unsent_report_delete_failed',
        operation: crashReporter.deleteUnsentReports,
      );
    } else if (enabled) {
      await _runSdkUpdate(
        'crash_metadata_update_failed',
        operation: () => _setCrashMetadata(this),
      );
    }
  }

  /// Records a high-level app startup event.
  Future<void> logAppStarted({required AppMetadata appMetadata}) =>
      _logEvent('app_started', <String, Object?>{
        'platform': _normalizeToken(defaultTargetPlatform.name),
        'flutter_mode': _flutterMode(),
        'preview_build': appMetadata.isPreviewBuild,
        'diagnostics_enabled': isDiagnosticsLoggingEnabled,
      });

  /// Records a high-level feature-opened event.
  Future<void> logFeatureOpened({required String feature}) =>
      _logEvent('feature_opened', <String, Object?>{
        'feature': _allowlistedValue(feature, _allowedFeatureNames),
      });

  /// Records that the telemetry opt-in prompt was displayed.
  Future<void> logTelemetryPromptShown({required String trigger}) async {
    _diagnosticsLogger.info(
      'telemetry',
      'prompt_shown',
      fields: <String, Object?>{
        'trigger': _allowlistedValue(trigger, _allowedPromptTriggers),
      },
    );
  }

  /// Records that the telemetry opt-in prompt was accepted.
  Future<void> logTelemetryPromptAccepted({required String trigger}) =>
      _logEvent('telemetry_prompt_accepted', <String, Object?>{
        'trigger': _allowlistedValue(trigger, _allowedPromptTriggers),
      });

  /// Records that the telemetry opt-in prompt was dismissed.
  Future<void> logTelemetryPromptDismissed({required String trigger}) async {
    _diagnosticsLogger.info(
      'telemetry',
      'prompt_dismissed',
      fields: <String, Object?>{
        'trigger': _allowlistedValue(trigger, _allowedPromptTriggers),
      },
    );
  }

  /// Records creation of a saved host.
  Future<void> logHostCreated({
    required String method,
    required bool hasKey,
    required bool hasJumpHost,
    required bool hasAutoConnect,
    required bool hasAgentPreset,
  }) => _logEvent('host_created', <String, Object?>{
    'method': _allowlistedValue(method, _allowedCreationMethods),
    'has_key': hasKey,
    'has_jump_host': hasJumpHost,
    'has_auto_connect': hasAutoConnect,
    'has_agent_preset': hasAgentPreset,
  });

  /// Records creation of a saved SSH key.
  Future<void> logKeyAdded({required String method}) =>
      _logEvent('key_added', <String, Object?>{
        'method': _allowlistedValue(method, _allowedCreationMethods),
      });

  /// Records creation of a saved command snippet.
  Future<void> logSnippetCreated({required String method}) =>
      _logEvent('snippet_created', <String, Object?>{
        'method': _allowlistedValue(method, _allowedCreationMethods),
      });

  /// Records an SSH connection attempt.
  Future<void> logConnectionAttempted({
    required String authMethod,
    required bool usesJumpHost,
  }) => _logEvent('connection_attempted', <String, Object?>{
    'auth_method': _allowlistedValue(authMethod, _allowedAuthMethods),
    'uses_jump_host': usesJumpHost,
  });

  /// Records a successful SSH connection.
  Future<void> logConnectionSucceeded({
    required String authMethod,
    required bool usesJumpHost,
    required Duration duration,
  }) => _logEvent('connection_succeeded', <String, Object?>{
    'auth_method': _allowlistedValue(authMethod, _allowedAuthMethods),
    'uses_jump_host': usesJumpHost,
    'duration_bucket': durationBucket(duration),
  });

  /// Records a failed SSH connection.
  Future<void> logConnectionFailed({
    required String authMethod,
    required bool usesJumpHost,
    required Duration duration,
    required String failureCategory,
  }) => _logEvent('connection_failed', <String, Object?>{
    'auth_method': _allowlistedValue(authMethod, _allowedAuthMethods),
    'uses_jump_host': usesJumpHost,
    'duration_bucket': durationBucket(duration),
    'failure_category': _allowlistedValue(
      failureCategory,
      _allowedFailureCategories,
    ),
  });

  /// Records terminal session creation.
  Future<void> logTerminalSessionStarted({
    required bool reusedConnection,
    required bool usedBackgroundService,
  }) => _logEvent('terminal_session_started', <String, Object?>{
    'reused_connection': reusedConnection,
    'used_background_service': usedBackgroundService,
  });

  /// Records terminal session end.
  Future<void> logTerminalSessionEnded({
    required Duration duration,
    required String disconnectCategory,
    required bool usedBackgroundService,
  }) => _logEvent('terminal_session_ended', <String, Object?>{
    'duration_bucket': durationBucket(duration),
    'disconnect_category': _allowlistedValue(
      disconnectCategory,
      _allowedDisconnectCategories,
    ),
    'used_background_service': usedBackgroundService,
  });

  /// Records SFTP transfer start.
  Future<void> logSftpTransferStarted({
    required String direction,
    required int fileCount,
    required int? sizeBytes,
  }) => _logEvent('sftp_transfer_started', <String, Object?>{
    'direction': _allowlistedValue(direction, _allowedTransferDirections),
    'file_count_bucket': countBucket(fileCount),
    'size_bucket': sizeBucket(sizeBytes),
  });

  /// Records SFTP transfer completion.
  Future<void> logSftpTransferCompleted({
    required String direction,
    required int fileCount,
    required int? sizeBytes,
    required Duration duration,
  }) => _logEvent('sftp_transfer_completed', <String, Object?>{
    'direction': _allowlistedValue(direction, _allowedTransferDirections),
    'file_count_bucket': countBucket(fileCount),
    'size_bucket': sizeBucket(sizeBytes),
    'duration_bucket': durationBucket(duration),
  });

  /// Records SFTP transfer failure.
  Future<void> logSftpTransferFailed({
    required String direction,
    required int fileCount,
    required int? sizeBytes,
    required Duration duration,
    required String failureCategory,
  }) => _logEvent('sftp_transfer_failed', <String, Object?>{
    'direction': _allowlistedValue(direction, _allowedTransferDirections),
    'file_count_bucket': countBucket(fileCount),
    'size_bucket': sizeBucket(sizeBytes),
    'duration_bucket': durationBucket(duration),
    'failure_category': _allowlistedValue(
      failureCategory,
      _allowedFailureCategories,
    ),
  });

  /// Records remote multiplexer detection.
  Future<void> logMuxDetected({required String backend}) =>
      _logEvent('mux_detected', <String, Object?>{
        'backend': _allowlistedValue(backend, _allowedMuxBackends),
      });

  /// Records opening the remote window switcher.
  Future<void> logMuxNavigatorOpened({
    required String backend,
    required int windowCount,
  }) => _logEvent('mux_navigator_opened', <String, Object?>{
    'backend': _allowlistedValue(backend, _allowedMuxBackends),
    'window_count_bucket': countBucket(windowCount),
  });

  /// Records remote window switch usage.
  Future<void> logMuxWindowSwitched({required String backend}) =>
      _logEvent('mux_window_switched', <String, Object?>{
        'backend': _allowlistedValue(backend, _allowedMuxBackends),
      });

  /// Records opening the new remote window dialog.
  Future<void> logMuxNewWindowDialogOpened({required String backend}) =>
      _logEvent('mux_new_window_dialog_opened', <String, Object?>{
        'backend': _allowlistedValue(backend, _allowedMuxBackends),
      });

  /// Records remote window creation.
  Future<void> logMuxWindowCreated({
    required String backend,
    required bool hasCommand,
  }) => _logEvent('mux_window_created', <String, Object?>{
    'backend': _allowlistedValue(backend, _allowedMuxBackends),
    'has_command': hasCommand,
  });

  /// Records failure to install or use a remote multiplexer.
  Future<void> logMuxInstallFailed({
    required String backend,
    required String failureCategory,
  }) => _logEvent('mux_install_failed', <String, Object?>{
    'backend': _allowlistedValue(backend, _allowedMuxBackends),
    'failure_category': _allowlistedValue(
      failureCategory,
      _allowedFailureCategories,
    ),
  });

  /// Records agent session-history usage.
  Future<void> logSessionHistoryOpened({
    required String tool,
    required int sessionCount,
  }) => _logEvent('session_history_opened', <String, Object?>{
    'tool': _allowlistedValue(tool, _allowedAgentTools),
    'session_count_bucket': countBucket(sessionCount),
  });

  /// Records agent session-history selection.
  Future<void> logSessionHistorySelected({required String tool}) => _logEvent(
    'session_history_selected',
    <String, Object?>{'tool': _allowlistedValue(tool, _allowedAgentTools)},
  );

  /// Records agent-session detection results.
  Future<void> logAgentSessionsDetected({
    required String tool,
    required int sessionCount,
    required bool failed,
  }) => _logEvent('agent_sessions_detected', <String, Object?>{
    'tool': _allowlistedValue(tool, _allowedAgentTools),
    'session_count_bucket': countBucket(sessionCount),
    'failed': failed,
  });

  /// Records that an agent CLI was detected on the remote host.
  Future<void> logAgentToolDetected({required String tool}) => _logEvent(
    'agent_tool_detected',
    <String, Object?>{'tool': _allowlistedValue(tool, _allowedAgentTools)},
  );

  /// Records agent launch usage.
  Future<void> logAgentLaunchUsed({
    required String tool,
    required bool usedSessionHistory,
    required bool usesMux,
  }) => _logEvent('agent_launch_used', <String, Object?>{
    'tool': _allowlistedValue(tool, _allowedAgentTools),
    'used_session_history': usedSessionHistory,
    'uses_mux': usesMux,
  });

  /// Records paywall display.
  Future<void> logPaywallShown({
    required String feature,
    required String source,
  }) => _logEvent('paywall_shown', <String, Object?>{
    'feature': _allowlistedValue(feature, _allowedPaywallFeatures),
    'source': _allowlistedValue(source, _allowedPaywallSources),
  });

  /// Records purchase start.
  Future<void> logPurchaseStarted({required String productType}) =>
      _logEvent('purchase_started', <String, Object?>{
        'product_type': _allowlistedValue(productType, _allowedProductTypes),
      });

  /// Records purchase completion.
  Future<void> logPurchaseCompleted({required String productType}) =>
      _logEvent('purchase_completed', <String, Object?>{
        'product_type': _allowlistedValue(productType, _allowedProductTypes),
      });

  /// Records purchase failure or cancellation.
  Future<void> logPurchaseFailed({
    required String productType,
    required String failureCategory,
  }) => _logEvent('purchase_failed', <String, Object?>{
    'product_type': _allowlistedValue(productType, _allowedProductTypes),
    'failure_category': _allowlistedValue(
      failureCategory,
      _allowedFailureCategories,
    ),
  });

  /// Records terminal paste usage without paste contents.
  Future<void> logTerminalPasteUsed({
    required String source,
    required bool requiredReview,
  }) => _logEvent('terminal_paste_used', <String, Object?>{
    'source': _allowlistedValue(source, _allowedPasteSources),
    'required_review': requiredReview,
  });

  /// Records terminal selection action usage without selected text.
  Future<void> logTerminalSelectionAction({required String action}) =>
      _logEvent('terminal_selection_action', <String, Object?>{
        'action': _allowlistedValue(action, _allowedSelectionActions),
      });

  /// Records that a live ACP agent session was opened.
  ///
  /// [providerCategory] and no other identifying detail: never a provider
  /// command, hostname, cwd, or session title.
  Future<void> logAcpSessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) => _logEvent('acp_session_opened', <String, Object?>{
    'provider_category': _allowlistedValue(
      providerCategory,
      _allowedAcpProviderCategories,
    ),
    'is_reconnect': isReconnect,
  });

  /// Records that a live ACP agent session ended for a safe, coarse reason.
  Future<void> logAcpSessionEnded({required String reason}) =>
      _logEvent('acp_session_ended', <String, Object?>{
        'reason': _allowlistedValue(reason, _allowedAcpSessionEndReasons),
      });

  /// Records the outcome of an ACP bridge/session reconnect attempt.
  Future<void> logAcpReconnectOutcome({
    required bool succeeded,
    String? failureCategory,
  }) => _logEvent('acp_reconnect_outcome', <String, Object?>{
    'succeeded': succeeded,
    if (failureCategory != null)
      'failure_category': _allowlistedValue(
        failureCategory,
        _allowedAcpFailureCategories,
      ),
  });

  /// Records a coarse attachment category/count sent in one ACP prompt turn.
  ///
  /// Never the attachment content, file name, or path.
  Future<void> logAcpAttachmentSent({
    required String category,
    required int count,
  }) => _logEvent('acp_attachment_sent', <String, Object?>{
    'category': _allowlistedValue(category, _allowedAcpAttachmentCategories),
    'count_bucket': countBucket(count),
  });

  /// Records the outcome of an ACP permission or pending-write decision.
  ///
  /// Never the tool call, path, or prompt the decision was about.
  Future<void> logAcpPermissionOutcome({required String outcome}) =>
      _logEvent('acp_permission_outcome', <String, Object?>{
        'outcome': _allowlistedValue(outcome, _allowedAcpPermissionOutcomes),
      });

  /// Records a safe, coarse ACP failure category.
  Future<void> logAcpFailure({required String category}) =>
      _logEvent('acp_failure', <String, Object?>{
        'category': _allowlistedValue(category, _allowedAcpFailureCategories),
      });

  /// Records the extra-keys toolbar being shown or hidden.
  Future<void> logKeyboardToolbarToggled({required bool enabled}) => _logEvent(
    'keyboard_toolbar_toggled',
    <String, Object?>{'enabled': enabled},
  );

  /// Records extra-keys toolbar key usage.
  Future<void> logKeyboardToolbarKeyPressed({required bool hasModifier}) =>
      _logEvent('keyboard_toolbar_key_pressed', <String, Object?>{
        'has_modifier': hasModifier,
      });

  /// Records explicit system-keyboard toggles from terminal UI.
  Future<void> logSystemKeyboardToggled({required bool visible}) => _logEvent(
    'system_keyboard_toggled',
    <String, Object?>{'visible': visible},
  );

  /// Records file-browser usage from terminal UI.
  Future<void> logSftpOpenedFromTerminal({
    required bool hasWorkingDirectory,
    required bool hasTmuxPaneDirectory,
  }) => _logEvent('sftp_opened_from_terminal', <String, Object?>{
    'has_working_directory': hasWorkingDirectory,
    'has_tmux_pane_directory': hasTmuxPaneDirectory,
  });

  /// Records terminal path-link usage without the path.
  Future<void> logTerminalPathLinkOpened() =>
      _logEvent('terminal_path_link_opened', const <String, Object?>{});

  /// Records a sanitized Flutter framework error as non-fatal.
  Future<void> recordFlutterError(FlutterErrorDetails details) =>
      _recordCrash(details.exception, details.stack, flutterDetails: details);

  /// Records a sanitized Dart error.
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
    bool absorbed = false,
  }) => _recordCrash(error, stackTrace, fatal: fatal, absorbed: absorbed);

  Future<void> _recordCrash(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
    bool absorbed = false,
    FlutterErrorDetails? flutterDetails,
  }) async {
    final crashReporter = _crashReporter;
    if (!_canRecordCrash() || crashReporter == null) {
      return;
    }
    // Reserve before awaiting, so concurrent failures cannot bypass the limit.
    if (absorbed &&
        !_absorbedErrorRateLimiter.shouldRecord(error.runtimeType)) {
      return;
    }
    final sanitized = SanitizedTelemetryError.from(error);
    final revision = _collectionRevision;
    bool canRecord() => _canRecordCrash() && revision == _collectionRevision;
    // Crashlytics keys are shared mutable SDK state. Keep each report and its
    // keys together, and recheck consent after every asynchronous SDK call.
    final operation = _crashReports.then((_) async {
      for (final entry in <String, Object>{
        'error_type': sanitized.errorType,
        'error_absorbed': absorbed,
        'top_app_frame': _topAppFrame(stackTrace),
        'flutter_error_exception': sanitized.errorType,
      }.entries) {
        if (!canRecord()) return;
        await _runSdkUpdate(
          'crash_metadata_update_failed',
          operation: () => crashReporter.setCustomKey(entry.key, entry.value),
        );
      }
      if (!canRecord()) return;
      await _runSdkUpdate(
        'crash_report_failed',
        operation: () => flutterDetails != null
            ? crashReporter.recordFlutterError(
                FlutterErrorDetails(
                  exception: sanitized,
                  stack: stackTrace,
                  library: 'flutter',
                  context: ErrorDescription(sanitized.reason),
                ),
              )
            : crashReporter.recordError(
                sanitized,
                stackTrace ?? StackTrace.empty,
                fatal: fatal && !absorbed,
              ),
      );
    });
    return _crashReports = operation.catchError((Object _) {});
  }

  Future<void> _logEvent(String name, Map<String, Object?> parameters) async {
    if (!isAvailable || !_collectionEnabled) {
      return;
    }
    final analyticsClient = _analyticsClient;
    if (analyticsClient == null) {
      return;
    }
    try {
      await analyticsClient.logEvent(
        name: name,
        parameters: {
          for (final entry in parameters.entries)
            if (entry.value case final Object value)
              entry.key: value is bool ? (value ? 1 : 0) : value,
        },
      );
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'telemetry',
        'analytics_event_failed',
        fields: {'eventName': name, 'errorType': error.runtimeType},
      );
    }
  }

  Future<void> _runSdkUpdate(
    String failureEventName, {
    required Future<void> Function() operation,
    Map<String, Object?> fields = const <String, Object?>{},
  }) async {
    try {
      await operation();
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'telemetry',
        failureEventName,
        fields: <String, Object?>{...fields, 'errorType': error.runtimeType},
      );
    }
  }

  bool _canRecordCrash() => isAvailable && _collectionEnabled;

  static String _normalizeToken(String value) {
    final sanitized = value
        .replaceAllMapped(
          _camelCasePattern,
          (match) => '${match.group(1)}_${match.group(2)}',
        )
        .toLowerCase()
        .replaceAll(_safeNamePattern, '_')
        .replaceAll(_edgeUnderscores, '');
    return sanitized.length <= _maxFirebaseStringLength
        ? sanitized
        : sanitized.substring(0, _maxFirebaseStringLength);
  }

  String _allowlistedValue(String value, Set<String> allowedValues) {
    final sanitized = _normalizeToken(value);
    return allowedValues.contains(sanitized) ? sanitized : 'unknown';
  }

  /// Buckets durations so analytics cannot reconstruct exact activity timing.
  String durationBucket(Duration duration) {
    final seconds = duration.inSeconds;
    if (seconds < 1) {
      return 'lt_1s';
    }
    if (seconds < 5) {
      return '1_4s';
    }
    if (seconds < 15) {
      return '5_14s';
    }
    if (seconds < 60) {
      return '15_59s';
    }
    final minutes = duration.inMinutes;
    if (minutes < 5) {
      return '1_4m';
    }
    if (minutes < 15) {
      return '5_14m';
    }
    if (minutes < 60) {
      return '15_59m';
    }
    return 'gte_1h';
  }

  /// Buckets counts into coarse groups.
  String countBucket(int count) {
    if (count <= 0) {
      return '0';
    }
    if (count == 1) {
      return '1';
    }
    if (count <= 5) {
      return '2_5';
    }
    if (count <= 20) {
      return '6_20';
    }
    return 'gt_20';
  }

  /// Buckets byte sizes into coarse groups.
  String sizeBucket(int? sizeBytes) {
    if (sizeBytes == null || sizeBytes < 0) {
      return 'unknown';
    }
    if (sizeBytes == 0) {
      return '0';
    }
    if (sizeBytes < 1024 * 1024) {
      return 'lt_1mb';
    }
    if (sizeBytes < 10 * 1024 * 1024) {
      return '1_9mb';
    }
    if (sizeBytes < 100 * 1024 * 1024) {
      return '10_99mb';
    }
    return 'gte_100mb';
  }

  String _flutterMode() {
    if (kReleaseMode) {
      return 'release';
    }
    if (kProfileMode) {
      return 'profile';
    }
    return 'debug';
  }

  /// Builds the agent-tool analytics allowlist from [AgentLaunchTool].
  ///
  /// Uses [AgentLaunchTool.uiDisplayOrder] as the curated shipped-tool set so
  /// analytics stays aligned with product UI. Includes both snake_case and
  /// compacted legacy forms so older event values remain accepted.
  static Set<String> _buildAllowedAgentTools() {
    final allowed = <String>{'all', 'unknown'};
    for (final tool in AgentLaunchTool.uiDisplayOrder) {
      allowed
        ..addAll(_telemetryAllowlistTokens(tool.name))
        ..addAll(_telemetryAllowlistTokens(tool.commandName));
      final label = tool.discoveredSessionToolName;
      if (label != null) {
        allowed.addAll(_telemetryAllowlistTokens(label));
      }
      for (final command in tool.candidateCommandNames) {
        allowed.addAll(_telemetryAllowlistTokens(command));
      }
    }
    return Set<String>.unmodifiable(allowed);
  }

  static Set<String> _telemetryAllowlistTokens(String value) {
    final snake = _normalizeToken(value);
    return {snake, snake.replaceAll('_', '')};
  }
}

/// Limits absorbed reports by runtime type for the lifetime of this process.
class AbsorbedErrorRateLimiter {
  /// Creates a limiter with an optional monotonic clock for deterministic tests.
  AbsorbedErrorRateLimiter({Duration Function()? elapsed}) {
    final stopwatch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => stopwatch.elapsed);
  }

  late final Duration Function() _elapsed;
  final _reports = <Type, ({int count, Duration lastReport})>{};

  /// Allows the first three reports, then at most one every ten minutes.
  bool shouldRecord(Type errorType) {
    final now = _elapsed();
    final previous = _reports[errorType];
    if (previous != null &&
        previous.count >= 3 &&
        now - previous.lastReport < const Duration(minutes: 10)) {
      return false;
    }
    _reports[errorType] = (
      count: previous == null ? 1 : (previous.count + 1).clamp(1, 3),
      lastReport: now,
    );
    return true;
  }
}

/// Error type and an allowlisted summary, without dynamic exception contents.
@immutable
class SanitizedTelemetryError implements Exception {
  /// Creates a sanitized telemetry error from a normalized error type.
  const SanitizedTelemetryError(this.errorType, {this.summary = '[redacted]'});

  /// Creates a sanitized telemetry error from an arbitrary object.
  factory SanitizedTelemetryError.from(Object error) => SanitizedTelemetryError(
    _sanitizeErrorType(error),
    summary: _sanitizeErrorSummary(error),
  );

  /// Normalized exception type.
  final String errorType;

  /// Safe text derived from the first line of the original error.
  final String summary;

  /// Distinguishes failures without including user or server-provided strings.
  String get reason => '$errorType: $summary';

  @override
  String toString() => errorType;
}

/// Initializes Firebase telemetry when this build and platform support it.
Future<TelemetryService> createTelemetryService({
  required SettingsService settingsService,
  DiagnosticsLogger? diagnosticsLogger,
  bool firebaseTelemetryEnabled = isFirebaseTelemetryBuildEnabled,
  bool isWeb = kIsWeb,
  TargetPlatform? targetPlatform,
}) async {
  final logger = diagnosticsLogger ?? DiagnosticsLogService.instance;
  final collectionEnabled = await settingsService.getBool(
    SettingKeys.telemetryCollection,
  );
  if (!firebaseTelemetryEnabled) {
    return TelemetryService(
      status: TelemetryServiceStatus.disabledByBuild,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }
  if (!isFirebaseTelemetrySupportedPlatform(
    isWeb: isWeb,
    targetPlatform: targetPlatform,
  )) {
    return TelemetryService(
      status: TelemetryServiceStatus.unsupportedPlatform,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    final service = TelemetryService(
      status: TelemetryServiceStatus.ready,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
      analyticsClient: _FirebaseTelemetryAnalyticsClient(
        FirebaseAnalytics.instance,
      ),
      crashReporter: _FirebaseTelemetryCrashReporter(
        FirebaseCrashlytics.instance,
      ),
    );
    await service.setCollectionEnabled(enabled: collectionEnabled);
    return service;
  } on FirebaseException catch (error) {
    logger.warning(
      'telemetry',
      'firebase_initialization_failed',
      fields: {'errorType': error.runtimeType, 'code': error.code},
    );
    return TelemetryService(
      status: TelemetryServiceStatus.initializationFailed,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  } on PlatformException catch (error) {
    logger.warning(
      'telemetry',
      'firebase_initialization_failed',
      fields: {'errorType': error.runtimeType, 'code': error.code},
    );
    return TelemetryService(
      status: TelemetryServiceStatus.initializationFailed,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }
}

/// Whether Firebase telemetry is supported for [targetPlatform].
bool isFirebaseTelemetrySupportedPlatform({
  required bool isWeb,
  TargetPlatform? targetPlatform,
}) {
  if (isWeb) {
    return false;
  }
  return switch (targetPlatform ?? defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => false,
  };
}

/// Provider for the app telemetry service.
final telemetryServiceProvider = Provider<TelemetryService>(
  (ref) => TelemetryService(
    status: TelemetryServiceStatus.disabledByBuild,
    collectionEnabled: false,
    diagnosticsLogger: ref.watch(diagnosticsLoggerProvider),
  ),
);

/// Notifier for the user telemetry collection preference.
class TelemetryCollectionNotifier extends Notifier<bool> {
  late SettingsService _settingsService;
  late TelemetryService _telemetryService;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _preferenceUpdates = Future<void>.value();

  @override
  bool build() {
    _settingsService = ref.watch(settingsServiceProvider);
    _telemetryService = ref.watch(telemetryServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final revision = ++_revision;
    Future.microtask(() => _init(revision));
    return _telemetryService.collectionEnabled;
  }

  /// Enables or disables telemetry collection.
  Future<void> setEnabled({required bool enabled}) async {
    // Invalidate initialization before the first await, not after persistence.
    final revision = ++_revision;
    final settings = _settingsService;
    final telemetry = _telemetryService;
    // Opt-out gates app events now, even if an older preference or SDK update
    // is blocked. Keep its native disable/reset/delete work in the SDK queue.
    final optOut = enabled
        ? null
        : telemetry.setCollectionEnabled(enabled: false);
    final operation = _preferenceUpdates.then((_) async {
      try {
        await settings.setBool(SettingKeys.telemetryCollection, value: enabled);
        if (enabled) {
          await settings.setString(
            SettingKeys.telemetryOptInPromptState,
            TelemetryOptInPromptChoice.accepted.name,
          );
          // Persistence must succeed before opt-in, and an older enable must
          // never reopen the event gate after a newer choice.
          if (revision == _revision) {
            await telemetry.setCollectionEnabled(enabled: true);
          }
        }
      } finally {
        // A failed preference write must not abandon opt-out cleanup.
        await optOut;
      }
      if (!_disposed && revision == _revision) {
        state = enabled;
      }
    });
    // A failed write must not prevent a later opt-out from being persisted.
    _preferenceUpdates = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _init(int revision) async {
    if (_disposed || revision != _revision) return;
    final telemetry = _telemetryService;
    final enabled = await _settingsService.getBool(
      SettingKeys.telemetryCollection,
    );
    if (_disposed || revision != _revision) return;
    await telemetry.setCollectionEnabled(enabled: enabled);
    if (_disposed || revision != _revision) return;
    state = enabled;
  }
}

/// Provider for the telemetry collection preference with write capability.
final telemetryCollectionNotifierProvider =
    NotifierProvider<TelemetryCollectionNotifier, bool>(
      TelemetryCollectionNotifier.new,
    );

/// User choice for the one-time telemetry opt-in prompt.
enum TelemetryOptInPromptChoice {
  /// The prompt has not been shown or answered.
  notShown,

  /// The prompt has been shown but not answered.
  shown,

  /// The user dismissed the prompt.
  dismissed,

  /// The user accepted telemetry collection.
  accepted,
}

/// Persistent state for the telemetry opt-in prompt.
@immutable
class TelemetryOptInPromptState {
  /// Creates telemetry prompt state.
  const TelemetryOptInPromptState({
    required this.choice,
    required this.appLaunchCount,
  });

  /// User's prompt choice.
  final TelemetryOptInPromptChoice choice;

  /// Number of recorded app launches.
  final int appLaunchCount;

  /// Whether the user has made a final prompt choice.
  bool get isResolved =>
      choice == TelemetryOptInPromptChoice.dismissed ||
      choice == TelemetryOptInPromptChoice.accepted;

  /// Creates a copy with updated fields.
  TelemetryOptInPromptState copyWith({
    TelemetryOptInPromptChoice? choice,
    int? appLaunchCount,
  }) => TelemetryOptInPromptState(
    choice: choice ?? this.choice,
    appLaunchCount: appLaunchCount ?? this.appLaunchCount,
  );
}

/// Notifier for delayed telemetry prompt state.
class TelemetryOptInPromptNotifier extends Notifier<TelemetryOptInPromptState> {
  /// Minimum number of launches before showing the prompt without a connection.
  static const int minimumLaunchCountForPrompt = 3;

  late SettingsService _settingsService;
  bool _disposed = false;

  @override
  TelemetryOptInPromptState build() {
    _settingsService = ref.watch(settingsServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future.microtask(_init);
    return const TelemetryOptInPromptState(
      choice: TelemetryOptInPromptChoice.notShown,
      appLaunchCount: 0,
    );
  }

  /// Records one app launch for prompt eligibility.
  Future<void> recordAppLaunch() async {
    final loadedState = await _loadState();
    if (loadedState.isResolved) {
      if (!_disposed) {
        state = loadedState;
      }
      return;
    }
    final nextLaunchCount = loadedState.appLaunchCount + 1;
    await _settingsService.setInt(
      SettingKeys.telemetryAppLaunchCount,
      nextLaunchCount,
    );
    if (_disposed) {
      return;
    }
    state = loadedState.copyWith(appLaunchCount: nextLaunchCount);
  }

  /// Accepts the prompt and enables telemetry collection.
  Future<void> accept({String trigger = 'unknown'}) async {
    await ref
        .read(telemetryCollectionNotifierProvider.notifier)
        .setEnabled(enabled: true);
    await ref
        .read(telemetryServiceProvider)
        .logTelemetryPromptAccepted(trigger: trigger);
    await _settingsService.setString(
      SettingKeys.telemetryOptInPromptState,
      TelemetryOptInPromptChoice.accepted.name,
    );
    if (_disposed) {
      return;
    }
    state = state.copyWith(choice: TelemetryOptInPromptChoice.accepted);
  }

  /// Records that the prompt has become visible.
  Future<void> markShown({required String trigger}) async {
    if (state.choice != TelemetryOptInPromptChoice.notShown) {
      return;
    }
    await ref
        .read(telemetryServiceProvider)
        .logTelemetryPromptShown(trigger: trigger);
    await _settingsService.setString(
      SettingKeys.telemetryOptInPromptState,
      TelemetryOptInPromptChoice.shown.name,
    );
    if (_disposed) {
      return;
    }
    state = state.copyWith(choice: TelemetryOptInPromptChoice.shown);
  }

  /// Dismisses the prompt without enabling telemetry collection.
  Future<void> dismiss({String trigger = 'unknown'}) async {
    await ref
        .read(telemetryServiceProvider)
        .logTelemetryPromptDismissed(trigger: trigger);
    await _settingsService.setString(
      SettingKeys.telemetryOptInPromptState,
      TelemetryOptInPromptChoice.dismissed.name,
    );
    if (_disposed) {
      return;
    }
    state = state.copyWith(choice: TelemetryOptInPromptChoice.dismissed);
  }

  Future<void> _init() async {
    final loadedState = await _loadState();
    if (_disposed) {
      return;
    }
    state = _mergeLoadedState(loadedState);
  }

  Future<TelemetryOptInPromptState> _loadState() async {
    final launchCount =
        await _settingsService.getInt(SettingKeys.telemetryAppLaunchCount) ?? 0;
    final collectionEnabled = await _settingsService.getBool(
      SettingKeys.telemetryCollection,
    );
    if (collectionEnabled) {
      return TelemetryOptInPromptState(
        choice: TelemetryOptInPromptChoice.accepted,
        appLaunchCount: launchCount,
      );
    }
    final choiceName = await _settingsService.getString(
      SettingKeys.telemetryOptInPromptState,
    );
    return TelemetryOptInPromptState(
      choice: _parsePromptChoice(choiceName),
      appLaunchCount: launchCount,
    );
  }

  TelemetryOptInPromptChoice _parsePromptChoice(String? value) =>
      switch (value) {
        'shown' => TelemetryOptInPromptChoice.shown,
        'dismissed' => TelemetryOptInPromptChoice.dismissed,
        'accepted' => TelemetryOptInPromptChoice.accepted,
        _ => TelemetryOptInPromptChoice.notShown,
      };

  TelemetryOptInPromptState _mergeLoadedState(
    TelemetryOptInPromptState loadedState,
  ) {
    final currentState = state;
    return TelemetryOptInPromptState(
      choice: currentState.isResolved
          ? currentState.choice
          : loadedState.choice,
      appLaunchCount: currentState.appLaunchCount > loadedState.appLaunchCount
          ? currentState.appLaunchCount
          : loadedState.appLaunchCount,
    );
  }
}

/// Provider for telemetry prompt state.
final telemetryOptInPromptNotifierProvider =
    NotifierProvider<TelemetryOptInPromptNotifier, TelemetryOptInPromptState>(
      TelemetryOptInPromptNotifier.new,
    );

class _FirebaseTelemetryAnalyticsClient implements TelemetryAnalyticsClient {
  const _FirebaseTelemetryAnalyticsClient(this._analytics);

  final FirebaseAnalytics _analytics;

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) => _analytics.logEvent(name: name, parameters: parameters);

  @override
  Future<void> resetAnalyticsData() => _analytics.resetAnalyticsData();

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _analytics.setAnalyticsCollectionEnabled(enabled);
}

class _FirebaseTelemetryCrashReporter implements TelemetryCrashReporter {
  const _FirebaseTelemetryCrashReporter(this._crashlytics);

  final FirebaseCrashlytics _crashlytics;

  @override
  Future<void> deleteUnsentReports() => _crashlytics.deleteUnsentReports();

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) => _crashlytics.recordError(
    error,
    stackTrace,
    reason: error is SanitizedTelemetryError ? error.reason : null,
    fatal: fatal,
  );

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) =>
      _crashlytics.recordFlutterError(details);

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _crashlytics.setCrashlyticsCollectionEnabled(enabled);

  @override
  Future<void> setCustomKey(String key, Object value) =>
      _crashlytics.setCustomKey(key, value);
}

Future<void> _setCrashMetadata(TelemetryService service) async {
  if (!service.isAvailable || !service.collectionEnabled) {
    return;
  }
  final crashReporter = service._crashReporter;
  if (crashReporter == null) {
    return;
  }
  await crashReporter.setCustomKey('platform', defaultTargetPlatform.name);
  await crashReporter.setCustomKey('flutter_mode', service._flutterMode());
  await crashReporter.setCustomKey(
    'diagnostics_enabled',
    isDiagnosticsLoggingEnabled,
  );
}

String _sanitizeErrorType(Object error) {
  final errorType = '${error.runtimeType}';
  final sanitized = errorType
      .replaceAll(RegExp('[^A-Za-z0-9_.-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (sanitized.isEmpty) {
    return 'UnknownError';
  }
  return sanitized.length <= 80 ? sanitized : sanitized.substring(0, 80);
}

String _sanitizeErrorSummary(Object error) {
  // Blacklisting URLs/password labels cannot protect arbitrary server replies,
  // commands, filenames, or user strings. Only retain known diagnostic phrases
  // from the first line; everything else is redacted, including bare secrets.
  const safePhrases = [
    'Transport is closed',
    'Connection closed before authentication',
    'Authentication timed out',
    'All authentication methods failed',
    'Connection reset by peer',
    'Connection refused',
    'Connection timed out',
    'Connection closed',
    'Broken pipe',
    'Network is unreachable',
    'No route to host',
    'Software caused connection abort',
    'Failed host lookup',
    'Permission denied',
    'Open failed',
    'No such file',
    'Directory not empty',
    'Administratively prohibited',
    'Resource shortage',
    'Handshake error in client',
    'CERTIFICATE_VERIFY_FAILED',
    'Cannot add event while adding a stream',
    'Cannot add new events after calling close',
    'StreamSink is closed',
    'Stream has already been listened to',
    'Failed to load font with url',
    'Bad state',
    'Invalid argument(s)',
  ];
  try {
    final firstLine = error.toString().split(RegExp(r'[\r\n]')).first;
    // These bounded protocol status codes are useful even when the server's
    // entire description is private. Do not retain arbitrary numeric values.
    final channelCode = RegExp(
      r'^SSHChannelOpenError\(([1-4]):',
    ).firstMatch(firstLine)?.group(1);
    final sftpCode = RegExp(
      r'^SftpStatusError: .*\(code ([0-8])\)$',
    ).firstMatch(firstLine)?.group(1);
    final code = channelCode ?? sftpCode;
    final codePrefix = code == null ? '' : 'code $code: ';
    var message = firstLine;
    final type = '${error.runtimeType}';
    if (message.startsWith('$type(') || message.startsWith('$type:')) {
      message = message.substring(type.length + 1).trim();
      if (firstLine.startsWith('$type(') && message.endsWith(')')) {
        message = message.substring(0, message.length - 1);
      }
    }
    for (final phrase in safePhrases) {
      if (message.toLowerCase() == phrase.toLowerCase()) {
        return '$codePrefix$phrase';
      }
      if (RegExp(
        '${RegExp.escape(phrase)}(?:[ :,(.]|\$)',
        caseSensitive: false,
      ).hasMatch(message)) {
        return '$codePrefix$phrase [redacted]';
      }
    }
    return '$codePrefix[redacted]';
  } on Object {
    // An exception's own toString can fail. Reporting must still retain its type.
    return '[unavailable]';
  }
}

String _topAppFrame(StackTrace? stackTrace) {
  if (stackTrace == null) return 'unknown';
  final frame = RegExp(
    r'^#\d+\s+([A-Za-z_$][A-Za-z0-9_$.<> ]*) \((package:monkeyssh/[A-Za-z0-9_./-]+\.dart:\d+(?::\d+)?)\)$',
  );
  for (final line in stackTrace.toString().split('\n')) {
    final match = frame.firstMatch(line.trim());
    if (match == null) continue;
    final location = match.group(2)!;
    // These are source locations, never local filesystem or SSH/SFTP paths.
    // Reporter frames are not the origin when the original stack is missing.
    if ((location.startsWith('package:monkeyssh/main.dart:') &&
            match.group(1)!.contains('installTelemetryErrorHandlers')) ||
        location.startsWith(
          'package:monkeyssh/domain/services/telemetry_service.dart:',
        )) {
      continue;
    }
    final value = '${match.group(1)} ($location)';
    return value.length <= 240 ? value : value.substring(0, 240);
  }
  return 'unknown';
}
