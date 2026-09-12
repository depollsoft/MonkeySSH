import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';

import '../../tool/monkeymux_quota_preview.dart';

void main() {
  test(
    'split arcs retain fixed top and bottom positions and independent values',
    () {
      for (final sample in QuotaSample.values.where(
        (s) => s != QuotaSample.unknown,
      )) {
        final arcs = quotaRingArcs(QuotaTreatment.split, sample);
        expect(arcs, hasLength(2));
        final top = arcs[0];
        final bottom = arcs[1];
        expect(top.radius, bottom.radius);
        expect(top.radius, 13);
        expect(top.shortTerm, isTrue);
        expect(bottom.shortTerm, isFalse);
        expect(top.remaining, sample.shortRemaining);
        expect(bottom.remaining, sample.weekRemaining);
        expect(top.start, greaterThan(-math.pi));
        expect(top.start + top.sweep, lessThan(0));
        expect(bottom.start, greaterThan(0));
        expect(bottom.start + bottom.sweep, lessThan(math.pi));
        expect(top.sweep, bottom.sweep);
        expect(top.sweep, lessThan(math.pi));
      }
    },
  );
  test('split unknown has no arcs while exhausted retains its empty half', () {
    expect(quotaRingArcs(QuotaTreatment.split, QuotaSample.unknown), isEmpty);
    final exhausted = quotaRingArcs(QuotaTreatment.split, QuotaSample.empty);
    expect(exhausted[0].remaining, 0);
    expect(exhausted[1].remaining, 64);
    expect(exhausted[0].sweep, greaterThan(0));
  });
  test('ring and warning colors meet contrast in both themes', () {
    for (final theme in [FluttyTheme.light, FluttyTheme.dark]) {
      final scheme = theme.colorScheme;
      for (final source in [scheme.primary, scheme.tertiary, scheme.error]) {
        final color = quotaReadableColor(source, scheme);
        for (final background in [
          scheme.surface,
          scheme.surfaceContainerHighest,
        ]) {
          final a = color.computeLuminance();
          final b = background.computeLuminance();
          expect(
            (math.max(a, b) + .05) / (math.min(a, b) + .05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    }
  });
  test('single ring follows the limiting category', () {
    expect(QuotaSample.healthy.tightest, 58);
    expect(QuotaSample.weekLow.tightest, 8);
    expect(QuotaSample.weekLow.limitingLabel, 'Weekly');
    expect(QuotaSample.empty.tightest, 0);
    expect(QuotaSample.unknown.tightest, isNull);
  });
  testWidgets('quota rings preserve window navigation without usage actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const QuotaComparisonApp());
    await tester.pumpAndSettle();
    expect(find.text('Concentric rings'), findsOneWidget);
    expect(find.text('Split ring'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sample-shortLow')));
    await tester.pumpAndSettle();
    expect(find.text('12% left'), findsNothing);
    expect(find.text('5h 12% · weekly 64%'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('handle-split')));
    await tester.pumpAndSettle();
    expect(find.text('MonkeyMux windows'), findsOneWidget);
    expect(find.text('Claude account usage'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('handle-split')));
    await tester.pumpAndSettle();
    expect(find.text('MonkeyMux windows'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toggle-theme')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 402.0, 1194.0]) {
    testWidgets('all quota states fit at width $width with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final sample in QuotaSample.values) {
        await tester.pumpWidget(
          QuotaComparisonApp(key: ValueKey(sample), initialSample: sample),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: sample.name);
      }
    });
  }
  testWidgets('unknown and zero have distinct accessible meanings', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      for (final sample in [QuotaSample.unknown, QuotaSample.empty]) {
        await tester.pumpWidget(
          MaterialApp(
            home: QuotaRingIcon(
              treatment: QuotaTreatment.single,
              sample: sample,
            ),
          ),
        );
        final node = tester.getSemantics(find.byType(QuotaRingIcon));
        expect(
          node.value,
          sample == QuotaSample.unknown
              ? 'Account usage unavailable'
              : '5-hour account allowance, 0 percent remaining',
        );
      }
    } finally {
      handle.dispose();
    }
  });
}
