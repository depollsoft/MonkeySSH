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
    // Native platform capture can race the raster thread after provider updates.
    await tester.pump(const Duration(milliseconds: 200));
    await binding.takeScreenshot(name);
  }

  testWidgets(
    'one reported quota is full at zero used and drains as usage increases',
    (tester) async {
      for (final used in [0.0, 23.0, 75.0, 100.0]) {
        await tester.pumpWidget(
          UsageRingsFeaturePreview(
            tool: AgentLaunchTool.codex,
            codexUsedPercent: used,
          ),
        );
        await tester.pumpAndSettle();
        final rings = tester
            .widget<SplitUsageRing>(find.byType(SplitUsageRing))
            .rings;
        expect(rings.segments, [(label: 'weekly', remaining: 100 - used)]);
        expect(tester.takeException(), isNull);
        await capture(
          tester,
          '$device-codex-${(100 - used).round()}-remaining',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'Antigravity groups and Grok included credits render production rings',
    (tester) async {
      for (final tool in [
        AgentLaunchTool.antigravity,
        AgentLaunchTool.grokBuild,
      ]) {
        await tester.pumpWidget(UsageRingsFeaturePreview(tool: tool));
        await tester.pumpAndSettle();
        final rings = tester
            .widget<SplitUsageRing>(find.byType(SplitUsageRing))
            .rings;
        expect(rings.segments.first.remaining, 100);
        expect(
          rings.segments.length,
          tool == AgentLaunchTool.antigravity ? 4 : 1,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, '$device-${tool.name}-remaining');
        await tester.pumpWidget(const SizedBox.shrink());
      }
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
