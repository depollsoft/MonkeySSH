// Simulated throttling only. Never queries the live Claude usage endpoint.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../tool/agent_management_preview.dart' as preview;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const device = String.fromEnvironment(
    'USAGE_PROOF_DEVICE',
    defaultValue: 'phone',
  );
  testWidgets('Claude rate-limit summary shows when usage checks can resume', (
    tester,
  ) async {
    preview.runAgentManagementPreview(
      claudeRateLimited: true,
      themeMode: ThemeMode.dark,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('Usage check rate limited'), findsOneWidget);
    expect(find.textContaining('Next usage check after'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await binding.convertFlutterSurfaceToImage();
    }
    await tester.pump(const Duration(milliseconds: 200));
    await binding.takeScreenshot('$device-claude-usage-cooldown');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
