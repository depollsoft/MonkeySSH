import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';

import 'diagnostics_log_service.dart';
import 'settings_service.dart';
import 'telemetry_service.dart';

/// Platform rating API used by [AppReviewPromptService].
abstract interface class AppReviewClient {
  /// Whether the platform can show its rating sheet.
  Future<bool> isAvailable();

  /// Asks the platform to show its rating sheet.
  ///
  /// The OS decides whether the sheet appears and enforces its own quota, so
  /// this never reports whether the user saw or answered it.
  Future<void> requestReview();
}

class _InAppReviewClient implements AppReviewClient {
  const _InAppReviewClient();

  @override
  Future<bool> isAvailable() => InAppReview.instance.isAvailable();

  @override
  Future<void> requestReview() => InAppReview.instance.requestReview();
}

/// Asks for an App Store or Google Play rating after someone has used the app
/// for a while, when they come back to the home screen from a terminal they
/// spent real time in.
///
/// The thresholds are deliberately stricter than the OS limits: a request
/// needs [requiredConnectionDays] different days with a successful
/// connection, spread over at least [minimumTimeSinceFirstConnection], and
/// requests are at least [minimumRequestInterval] apart.
///
/// Only the system rating sheet is used. App Store Review Guideline 5.6.1
/// requires the system API, and Google Play forbids asking whether the user
/// is happy before deciding to show it.
class AppReviewPromptService {
  /// Creates an [AppReviewPromptService].
  AppReviewPromptService({
    required SettingsService settingsService,
    required DiagnosticsLogger diagnosticsLogger,
    required TelemetryService telemetryService,
    AppReviewClient client = const _InAppReviewClient(),
    DateTime Function() now = DateTime.now,
    bool Function()? isAppActive,
    bool? isSupportedPlatform,
  }) : _settingsService = settingsService,
       _diagnosticsLogger = diagnosticsLogger,
       _telemetryService = telemetryService,
       _client = client,
       _now = now,
       _isAppActive = isAppActive ?? _isAppResumed,
       _isSupportedPlatform =
           isSupportedPlatform ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.iOS ||
                   defaultTargetPlatform == TargetPlatform.android));

  /// Different days with a successful connection before any request.
  static const requiredConnectionDays = 5;

  /// Minimum time since the first successful connection before any request,
  /// so a burst of use in the first few days does not qualify.
  static const minimumTimeSinceFirstConnection = Duration(days: 7);

  /// Minimum time between requests: at most two in any 365 days, below the
  /// App Store limit of three. 180 days would allow days 0, 180 and 360.
  static const minimumRequestInterval = Duration(days: 183);

  /// Minimum foreground time on a live connection before leaving a terminal
  /// is a moment to ask.
  static const minimumConnectedTime = Duration(minutes: 3);

  final SettingsService _settingsService;
  final DiagnosticsLogger _diagnosticsLogger;
  final TelemetryService _telemetryService;
  final AppReviewClient _client;
  final DateTime Function() _now;
  final bool Function() _isAppActive;
  final bool _isSupportedPlatform;
  bool _requestInFlight = false;

  /// Counts today toward [requiredConnectionDays] after a successful
  /// connection. Repeat connections on the same day count once.
  Future<void> recordSuccessfulConnection() async {
    if (!_isSupportedPlatform) {
      return;
    }
    final now = _now();
    final today = _dayKey(now);
    try {
      await _settingsService.updateJson(SettingKeys.appReviewPrompt, (json) {
        final state = _AppReviewPromptState.fromJson(json);
        if (state.lastConnectionDay == today) {
          return json;
        }
        return state
            .copyWith(
              connectionDays: state.connectionDays + 1,
              lastConnectionDay: today,
              firstConnectionAt: state.firstConnectionAt ?? now,
            )
            .toJson();
      });
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'app_review',
        'record_connection_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  /// Whether [connectedTime] in a terminal is enough to ask after leaving it.
  bool isQualifyingConnectedTime(Duration connectedTime) =>
      _isSupportedPlatform && connectedTime >= minimumConnectedTime;

  /// Requests the system rating sheet if this user qualifies.
  ///
  /// Call only at a pause the user chose, such as returning to the home
  /// screen. Returns whether the request was passed to the platform.
  Future<bool> maybeRequestReview() async {
    if (!_isSupportedPlatform || _requestInFlight) {
      return false;
    }
    _requestInFlight = true;
    try {
      final now = _now();
      final stored = _AppReviewPromptState.fromJson(
        await _settingsService.getJson(SettingKeys.appReviewPrompt),
      );
      if (!_isEligible(stored, now)) {
        return false;
      }
      if (!await _client.isAvailable()) {
        _diagnosticsLogger.info('app_review', 'review_unavailable');
        return false;
      }
      // The sheet cannot appear over a backgrounded app, and claiming the
      // request then would spend the whole interval on nothing.
      if (!_isAppActive()) {
        return false;
      }
      // Claim the request before making it, so a failed or repeated call
      // cannot ask again inside the interval.
      var claimed = false;
      await _settingsService.updateJson(SettingKeys.appReviewPrompt, (json) {
        final state = _AppReviewPromptState.fromJson(json);
        if (!_isEligible(state, now)) {
          return json;
        }
        claimed = true;
        return state.copyWith(lastRequestedAt: now).toJson();
      });
      if (!claimed) {
        return false;
      }
      await _client.requestReview();
      _diagnosticsLogger.info(
        'app_review',
        'review_requested',
        fields: {'connectionDays': stored.connectionDays},
      );
      await _telemetryService.logReviewPromptRequested(
        connectionDays: stored.connectionDays,
      );
      return true;
    } on Object catch (error) {
      _diagnosticsLogger.warning(
        'app_review',
        'review_request_failed',
        fields: {'errorType': error.runtimeType},
      );
      return false;
    } finally {
      _requestInFlight = false;
    }
  }

  bool _isEligible(_AppReviewPromptState state, DateTime now) {
    final firstConnectionAt = state.firstConnectionAt;
    if (state.connectionDays < requiredConnectionDays ||
        firstConnectionAt == null ||
        now.difference(firstConnectionAt) < minimumTimeSinceFirstConnection) {
      return false;
    }
    final lastRequestedAt = state.lastRequestedAt;
    return lastRequestedAt == null ||
        now.difference(lastRequestedAt) >= minimumRequestInterval;
  }

  static bool _isAppResumed() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  static String _dayKey(DateTime time) {
    final local = time.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

@immutable
class _AppReviewPromptState {
  const _AppReviewPromptState({
    required this.connectionDays,
    this.firstConnectionAt,
    this.lastConnectionDay,
    this.lastRequestedAt,
  });

  factory _AppReviewPromptState.fromJson(Map<String, dynamic>? json) {
    final connectionDays = json?['connectionDays'];
    final lastConnectionDay = json?['lastConnectionDay'];
    return _AppReviewPromptState(
      connectionDays: connectionDays is int && connectionDays > 0
          ? connectionDays
          : 0,
      firstConnectionAt: _readTime(json?['firstConnectionAtMs']),
      lastConnectionDay: lastConnectionDay is String ? lastConnectionDay : null,
      lastRequestedAt: _readTime(json?['lastRequestedAtMs']),
    );
  }

  final int connectionDays;
  final DateTime? firstConnectionAt;
  final String? lastConnectionDay;
  final DateTime? lastRequestedAt;

  _AppReviewPromptState copyWith({
    int? connectionDays,
    DateTime? firstConnectionAt,
    String? lastConnectionDay,
    DateTime? lastRequestedAt,
  }) => _AppReviewPromptState(
    connectionDays: connectionDays ?? this.connectionDays,
    firstConnectionAt: firstConnectionAt ?? this.firstConnectionAt,
    lastConnectionDay: lastConnectionDay ?? this.lastConnectionDay,
    lastRequestedAt: lastRequestedAt ?? this.lastRequestedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connectionDays': connectionDays,
    if (firstConnectionAt case final firstAt?)
      'firstConnectionAtMs': firstAt.millisecondsSinceEpoch,
    'lastConnectionDay': ?lastConnectionDay,
    if (lastRequestedAt case final requestedAt?)
      'lastRequestedAtMs': requestedAt.millisecondsSinceEpoch,
  };

  static DateTime? _readTime(Object? milliseconds) => milliseconds is int
      ? DateTime.fromMillisecondsSinceEpoch(milliseconds)
      : null;
}

/// Provider for [AppReviewPromptService].
final appReviewPromptServiceProvider = Provider<AppReviewPromptService>(
  (ref) => AppReviewPromptService(
    settingsService: ref.watch(settingsServiceProvider),
    diagnosticsLogger: ref.watch(diagnosticsLoggerProvider),
    telemetryService: ref.watch(telemetryServiceProvider),
  ),
);
