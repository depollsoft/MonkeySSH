import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';
import 'package:monkeyssh/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CrashReporter reporter;
  late int previousCalls;

  setUp(() {
    final previousPlatform = PlatformDispatcher.instance.onError;
    final previousFlutter = FlutterError.onError;
    addTearDown(() {
      PlatformDispatcher.instance.onError = previousPlatform;
      FlutterError.onError = previousFlutter;
    });
    previousCalls = 0;
    PlatformDispatcher.instance.onError = (error, stack) {
      previousCalls += 1;
      return false;
    };
    FlutterError.onError = (_) {
      previousCalls += 1;
    };
    reporter = _CrashReporter();
    app.installTelemetryErrorHandlers(
      TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        crashReporter: reporter,
        absorbedErrorRateLimiter: AbsorbedErrorRateLimiter(),
      ),
    );
  });

  final absorbedCases = <String, (Object, StackTrace)>{
    'SSH channel open': (SSHChannelOpenError(1, 'denied'), StackTrace.empty),
    'SSH authentication': (
      SSHAuthAbortError('Connection closed before authentication'),
      StackTrace.empty,
    ),
    'SFTP status': (
      SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'),
      StackTrace.empty,
    ),
    'channel teardown': (
      SSHStateError('Transport is closed'),
      StackTrace.fromString('#0 SSHChannelController._uploadLoop'),
    ),
    'SSH socket': (
      const SocketException('Connection reset by peer'),
      StackTrace.fromString(
        '#0 connect (package:dartssh2/src/socket/ssh_socket_io.dart:1:2)',
      ),
    ),
    'optional font fetch': (
      Exception('Failed to load font with url https://private.example/font'),
      StackTrace.fromString(
        '#0 _httpFetchFontAndSaveToDevice (package:google_fonts/src/google_fonts_base.dart:1:2)',
      ),
    ),
  };

  for (final entry in absorbedCases.entries) {
    test(
      '${entry.key} is absorbed but reported non-fatal with its stack',
      () async {
        final (error, stack) = entry.value;
        final handler = PlatformDispatcher.instance.onError!;
        for (var i = 0; i < 10; i++) {
          expect(handler(error, stack), isTrue);
        }
        await Future<void>.delayed(Duration.zero);
        expect(previousCalls, 10);
        expect(reporter.errors, hasLength(3));
        for (final report in reporter.errors) {
          expect(report.fatal, isFalse);
          expect(report.stack, same(stack));
        }
        expect(reporter.keys['error_absorbed'], isTrue);
      },
    );
  }

  test(
    'unexpected failures retain fatal reporting and previous return value',
    () async {
      final handler = PlatformDispatcher.instance.onError!;
      expect(handler(StateError('bug'), StackTrace.empty), isFalse);
      expect(
        handler(const SocketException('unknown owner'), StackTrace.empty),
        isFalse,
      );
      expect(
        handler(
          StateError('font bug'),
          StackTrace.fromString(
            '#0 _httpFetchFontAndSaveToDevice (package:google_fonts/src/google_fonts_base.dart:1:2)',
          ),
        ),
        isFalse,
      );
      expect(
        handler(
          Exception('font bug'),
          StackTrace.fromString(
            '#0 googleFontsTextStyle (package:google_fonts/src/google_fonts_base.dart:1:2)',
          ),
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(reporter.errors, hasLength(4));
      expect(reporter.errors.every((report) => report.fatal), isTrue);
      expect(previousCalls, 4);
      expect(reporter.keys['error_absorbed'], isFalse);
    },
  );

  test(
    'framework handler preserves previous handler and sanitized report',
    () async {
      final stack = StackTrace.fromString(
        '#0 build (package:monkeyssh/app/app.dart:1:2)',
      );
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('private contents'),
          stack: stack,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(previousCalls, 1);
      expect(reporter.flutterErrors.single.stack, same(stack));
      expect(
        reporter.flutterErrors.single.context.toString(),
        'StateError: Bad state [redacted]',
      );
    },
  );

  test('absorbed errors respect disabled collection', () async {
    PlatformDispatcher.instance.onError = null;
    app.installTelemetryErrorHandlers(
      TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        crashReporter: reporter,
      ),
    );
    expect(
      PlatformDispatcher.instance.onError!(
        SSHStateError('Transport is closed'),
        StackTrace.empty,
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(reporter.errors, isEmpty);
    expect(reporter.keys, isEmpty);
  });
}

class _CrashReporter implements TelemetryCrashReporter {
  final errors = <({Object error, StackTrace stack, bool fatal})>[];
  final flutterErrors = <FlutterErrorDetails>[];
  final keys = <String, Object>{};

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {
    errors.add((error: error, stack: stackTrace, fatal: fatal));
  }

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    flutterErrors.add(details);
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    keys[key] = value;
  }

  @override
  Future<void> deleteUnsentReports() async {}

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}
}
