import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:xterm/xterm.dart';

import 'app/app.dart';
import 'app/app_metadata.dart';
import 'app/host_key_prompt.dart';
import 'app/interactive_auth_prompt.dart';
import 'data/database/database.dart';
import 'domain/services/diagnostics_log_service.dart';
import 'domain/services/host_key_prompt_handler_provider.dart';
import 'domain/services/interactive_auth_prompt.dart';
import 'domain/services/performance_diagnostics_service.dart';
import 'domain/services/settings_service.dart';
import 'domain/services/ssh_error_policy.dart';
import 'domain/services/telemetry_service.dart';

/// Entry point for the MonkeySSH client.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installBundledLicenses();
  _installPerformanceDiagnostics();
  final database = AppDatabase();
  final settingsService = SettingsService(database);
  final telemetryService = await createTelemetryService(
    settingsService: settingsService,
  );
  installTelemetryErrorHandlers(telemetryService);
  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsServiceProvider.overrideWithValue(settingsService),
        telemetryServiceProvider.overrideWithValue(telemetryService),
        hostKeyPromptHandlerProvider.overrideWith(
          (ref) => createHostKeyPromptHandler(),
        ),
        interactiveAuthPromptHandlerProvider.overrideWith(
          (ref) => createInteractiveAuthPromptHandler(),
        ),
      ],
      child: const FluttyApp(),
    ),
  );
}

/// Registers bundled licenses without starting the app in tests.
@visibleForTesting
void installBundledLicensesForTesting() => _installBundledLicenses();

void _installBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'remote/monkeymux/conpty/LICENSE.microsoft-terminal',
    );
    yield LicenseEntryWithLineBreaks(const [
      'Microsoft Windows Terminal ConPTY',
    ], license);
    final interLicense = await rootBundle.loadString(
      'assets/fonts/OFL-Inter.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['Inter'], interLicense);
    final jetBrainsMonoLicense = await rootBundle.loadString(
      'assets/fonts/OFL-JetBrainsMono.txt',
    );
    yield LicenseEntryWithLineBreaks(const [
      'JetBrains Mono',
    ], jetBrainsMonoLicense);
  });
}

void _installPerformanceDiagnostics() {
  if (!isDiagnosticsLoggingEnabled) {
    return;
  }
  // Frame jank monitor: discriminates UI-thread vs raster-thread stalls.
  PerformanceDiagnosticsService.instance.start();
  // Surface terminal image inflate/decode timing from the vendored xterm.
  terminalGraphicsDecodeObserver =
      ({
        required int payloadBytes,
        required int inflateMicros,
        required int decodeMicros,
        required bool compressed,
        required bool success,
        String? imageId,
        String? action,
        bool? reused,
      }) => logTerminalGraphicsDecode(
        TerminalGraphicsDecodeStats(
          payloadBytes: payloadBytes,
          inflateMicros: inflateMicros,
          decodeMicros: decodeMicros,
          compressed: compressed,
          success: success,
          imageId: imageId,
          action: action,
          reused: reused ?? false,
        ),
      );
}

/// Installs the last-resort reporters while preserving existing error handlers.
@visibleForTesting
void installTelemetryErrorHandlers(TelemetryService telemetryService) {
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    if (previousFlutterErrorHandler != null) {
      previousFlutterErrorHandler(details);
    } else {
      FlutterError.presentError(details);
    }
    unawaited(
      telemetryService.recordFlutterError(details).catchError((Object _) {}),
    );
  };

  final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    var absorbed = false;
    if (isExpectedSshChannelTeardownError(error, stackTrace)) {
      absorbed = true;
      DiagnosticsLogService.instance.info(
        'ssh.channel',
        'late_write_ignored',
        fields: {'errorType': error.runtimeType},
      );
    } else if (isExpectedSshOperationError(error, stackTrace)) {
      absorbed = true;
      DiagnosticsLogService.instance.warning(
        'ssh.operation',
        'unhandled_failure_absorbed',
        fields: {'errorType': error.runtimeType},
      );
    } else if (_isGoogleFontsLoadFailure(error, stackTrace)) {
      absorbed = true;
      DiagnosticsLogService.instance.warning(
        'fonts',
        'runtime_load_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    unawaited(
      telemetryService
          .recordError(error, stackTrace, fatal: !absorbed, absorbed: absorbed)
          .catchError((Object _) {}),
    );
    final previouslyHandled =
        previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
    return absorbed || previouslyHandled;
  };
}

// Google Fonts falls back to the platform font after an HTTP fetch failure.
bool _isGoogleFontsLoadFailure(Object error, StackTrace stackTrace) =>
    error is Exception &&
    stackTrace.toString().contains('_httpFetchFontAndSaveToDevice');
