// Native simulator screenshots of the development-only visual comparison.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../tool/monkeymux_quota_preview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const device = String.fromEnvironment(
    'QUOTA_PREVIEW_DEVICE',
    defaultValue: 'phone',
  );
  testWidgets('compare concentric and split rings without quota navigation', (
    tester,
  ) async {
    await tester.pumpWidget(const QuotaComparisonApp());
    await tester.pumpAndSettle();
    expect(find.text('Concentric rings'), findsOneWidget);
    expect(find.text('Split ring'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('$device-split-healthy-dark');
    for (final sample in [QuotaSample.shortLow, QuotaSample.weekLow]) {
      await tester.tap(find.byKey(ValueKey('sample-${sample.name}')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot('$device-split-${sample.name}-dark');
    }
    await tester.tap(find.byKey(const ValueKey('toggle-theme')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('$device-split-weekLow-light');
    await tester.tap(find.byKey(const ValueKey('handle-split')));
    await tester.pumpAndSettle();
    expect(find.text('MonkeyMux windows'), findsOneWidget);
    expect(find.text('Claude account usage'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
