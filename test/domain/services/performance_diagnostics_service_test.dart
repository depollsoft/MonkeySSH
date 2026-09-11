import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/performance_diagnostics_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

FrameTiming _frame({required int buildMicros, required int rasterMicros}) {
  // Build runs first on the UI thread, then raster on the GPU thread.
  const vsyncStart = 0;
  const buildStart = 0;
  final buildFinish = buildStart + buildMicros;
  final rasterStart = buildFinish;
  final rasterFinish = rasterStart + rasterMicros;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}

void main() {
  group('PerformanceDiagnosticsService frame jank', () {
    late RecordingDiagnosticsLogger logger;
    late PerformanceDiagnosticsService service;

    setUp(() {
      logger = RecordingDiagnosticsLogger();
      service = PerformanceDiagnosticsService(logger: logger);
    });

    test('ignores frames within budget', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 6000, rasterMicros: 5000),
      ]);
      expect(logger.events, isEmpty);
    });

    test('flags a UI-thread bound janky frame', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 1200 * 1000, rasterMicros: 4000),
      ]);
      expect(logger.events, hasLength(1));
      final event = logger.events.single;
      expect(event.category, 'perf.frame');
      expect(event.message, 'jank');
      expect(event.fields['bound'], 'ui');
      expect(event.fields['buildMs'], 1200);
    });

    test('flags a raster-thread bound janky frame', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 3000, rasterMicros: 900 * 1000),
      ]);
      expect(logger.events, hasLength(1));
      expect(logger.events.single.fields['bound'], 'raster');
      expect(logger.events.single.fields['rasterMs'], 900);
    });
  });
}
