// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';

void registerTerminalScreenZoomTests() {
  group('terminal_screen_zoom', () {
    group('terminal font zoom helpers', () {
      test('clamps font size to supported minimum and maximum', () {
        expect(clampTerminalFontSize(2), 8);
        expect(clampTerminalFontSize(18), 18);
        expect(clampTerminalFontSize(64), 32);
      });

      test('scales font size and keeps it in range', () {
        expect(scaleTerminalFontSize(14, 1.5), 21);
        expect(scaleTerminalFontSize(14, 0.1), 8);
        expect(scaleTerminalFontSize(14, 3), 32);
      });

      test('applies incremental scale deltas in both directions', () {
        expect(applyTerminalScaleDelta(14, 1, 0.85), closeTo(11.9, 0.001));
        expect(applyTerminalScaleDelta(11.9, 0.85, 0.95), closeTo(13.3, 0.1));
        expect(applyTerminalScaleDelta(13.3, 0.95, 0.75), closeTo(10.5, 0.1));
      });

      test('sanitizes non-finite font sizes instead of propagating NaN', () {
        // A NaN/Infinity font size must not reach the painter; it would crash
        // layout/paint integer math (e.g. `width ~/ cellSize.width`).
        expect(clampTerminalFontSize(double.nan).isFinite, isTrue);
        expect(clampTerminalFontSize(double.infinity).isFinite, isTrue);
        expect(clampTerminalFontSize(double.negativeInfinity).isFinite, isTrue);
        expect(scaleTerminalFontSize(14, double.nan).isFinite, isTrue);
      });

      test('ignores degenerate pinch frames and keeps the current size', () {
        // Coincident focal points can produce a zero or non-finite scale.
        expect(applyTerminalScaleDelta(18, 1, 0), 18);
        expect(applyTerminalScaleDelta(18, 1, double.nan), 18);
        expect(applyTerminalScaleDelta(18, 1, double.infinity), 18);
        expect(applyTerminalScaleDelta(18, double.nan, 1.2).isFinite, isTrue);
        expect(applyTerminalScaleDelta(18, 0, 1.2).isFinite, isTrue);
      });

      test('prefers session font size over the global default', () {
        expect(
          resolveTerminalFontSize(globalFontSize: 14, sessionFontSize: 18),
          18,
        );
      });

      test('prefers the in-progress pinch size over stored values', () {
        expect(
          resolveTerminalFontSize(
            globalFontSize: 14,
            sessionFontSize: 18,
            pinchFontSize: 20,
          ),
          20,
        );
      });
    });
  });
}
