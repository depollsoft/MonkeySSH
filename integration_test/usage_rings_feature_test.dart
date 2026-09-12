import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings.dart';
import 'package:monkeyssh/presentation/widgets/premium_badge.dart';

import '../tool/usage_rings_feature_preview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const device = String.fromEnvironment(
    'QUOTA_PREVIEW_DEVICE',
    defaultValue: 'phone',
  );
  testWidgets('native Pro option controls the production usage rings', (
    tester,
  ) async {
    await tester.pumpWidget(const UsageRingsFeaturePreview());
    await tester.pumpAndSettle();
    expect(find.byType(SplitUsageRing), findsOneWidget);
    await binding.takeScreenshot('$device-pro-rings');
    Future<void> openOptions() async {
      await tester.tap(find.byKey(const ValueKey('preview-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
    }

    await openOptions();
    expect(
      tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton)).value,
      isTrue,
    );
    await binding.takeScreenshot('$device-pro-options');
    await tester.tap(find.text('Show usage rings'));
    await tester.pumpAndSettle();
    expect(find.byType(SplitUsageRing), findsNothing);
    await binding.takeScreenshot('$device-rings-off');
    await tester.tap(find.byKey(const ValueKey('preview-access')));
    await tester.pumpAndSettle();
    await openOptions();
    expect(find.byType(PremiumBadge), findsOneWidget);
    expect(
      tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton)).value,
      isFalse,
    );
    expect(find.byType(SplitUsageRing), findsNothing);
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('$device-free-options');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
