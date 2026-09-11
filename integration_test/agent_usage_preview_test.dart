// Native visual proof uses illustrative quotas and never connects to SSH.
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

  testWidgets('account usage details remain readable when expanded', (
    tester,
  ) async {
    preview.main();
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    await binding.takeScreenshot('$device-ios');
    for (final id in ['claude', 'opencode', 'cursor', 'hermes']) {
      final heading = find.byKey(ValueKey('agent-details-cli:$id'));
      await Scrollable.ensureVisible(tester.element(heading), alignment: 0.05);
      await tester.pumpAndSettle();
      await tester.tap(heading);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(heading), alignment: 0.05);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (id == 'claude') {
        expect(find.text('Weekly · Fable · 85% remaining'), findsOneWidget);
      } else if (id == 'opencode') {
        expect(
          find.textContaining('Anthropic · Usage unavailable'),
          findsOneWidget,
        );
      } else if (id == 'cursor') {
        expect(find.text('Account access · Usage restricted'), findsOneWidget);
      } else {
        expect(
          find.text(r'Nous · Purchased balance · $12.34 remaining'),
          findsOneWidget,
        );
      }
      await binding.takeScreenshot('$device-$id-ios');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
