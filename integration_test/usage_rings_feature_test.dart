import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings.dart';
import 'package:monkeyssh/presentation/widgets/premium_badge.dart';

import '../tool/usage_rings_feature_preview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const device = String.fromEnvironment(
    'QUOTA_PREVIEW_DEVICE',
    defaultValue: 'phone',
  );
  var androidSurfaceReady = false;
  setUp(() => androidSurfaceReady = false);
  Future<void> capture(WidgetTester tester, String name) async {
    if (defaultTargetPlatform == TargetPlatform.android &&
        !androidSurfaceReady) {
      await binding.convertFlutterSurfaceToImage();
      androidSurfaceReady = true;
      await tester.pump();
    }
    await binding.takeScreenshot(name);
  }

  testWidgets(
    'weekly-only Codex is not displayed as an exhausted short-term quota',
    (tester) async {
      await tester.pumpWidget(
        const UsageRingsFeaturePreview(tool: AgentLaunchTool.codex),
      );
      await tester.pumpAndSettle();
      final rings = tester
          .widget<SplitUsageRing>(find.byType(SplitUsageRing))
          .rings;
      expect(rings.shortTerm, isNull);
      expect(rings.weekly, 77);
      expect(tester.takeException(), isNull);
      await capture(tester, '$device-codex-weekly-77-unreported-short-term');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('native Pro option controls the production usage rings', (
    tester,
  ) async {
    await tester.pumpWidget(const UsageRingsFeaturePreview());
    await tester.pumpAndSettle();
    expect(find.byType(SplitUsageRing), findsOneWidget);
    await capture(tester, '$device-pro-rings');
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
    await capture(tester, '$device-pro-options');
    await tester.tap(find.text('Show usage rings'));
    await tester.pumpAndSettle();
    expect(find.byType(SplitUsageRing), findsNothing);
    await capture(tester, '$device-rings-off');
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
    await capture(tester, '$device-free-options');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
