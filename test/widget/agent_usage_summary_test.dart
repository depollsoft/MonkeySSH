import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_summary.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12);
  Future<void> pump(
    WidgetTester tester,
    AgentUsage usage, {
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: SizedBox(
                width: 280,
                child: AgentUsageSummary(
                  usage: usage,
                  now: now,
                  expanded: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('past reset does not claim quota has been replenished', (
    tester,
  ) async {
    await pump(
      tester,
      AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          AgentUsageWindow(
            label: 'Weekly',
            usedPercent: 100,
            resetsAt: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      ),
    );
    expect(find.text('Weekly · 0% remaining'), findsOneWidget);
    expect(find.text('Reset time passed · re-check usage'), findsOneWidget);
    expect(find.textContaining('Limit reached'), findsNothing);
  });

  testWidgets('unknown and unlimited quotas never imply zero usage', (
    tester,
  ) async {
    await pump(tester, const AgentUsage(status: AgentUsageStatus.unavailable));
    expect(find.text('Usage unavailable · re-check to retry'), findsOneWidget);
    await pump(
      tester,
      const AgentUsage(
        status: AgentUsageStatus.available,
        windows: [AgentUsageWindow(label: 'Chat', unlimited: true)],
      ),
    );
    expect(find.text('Chat · Unlimited'), findsOneWidget);
    expect(find.textContaining('0%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('large text wraps limits, reset details, and paid overage', (
    tester,
  ) async {
    await pump(
      tester,
      AgentUsage(
        status: AgentUsageStatus.available,
        checkedAt: now,
        resetCredits: 2,
        windows: [
          AgentUsageWindow(
            label: 'Premium requests',
            usedPercent: 100,
            used: 300,
            limit: 300,
            overageAllowed: true,
            resetsAt: now.add(const Duration(days: 3)),
          ),
        ],
      ),
      scale: 2,
    );
    expect(find.textContaining('Limit reached'), findsOneWidget);
    expect(find.text('Additional paid usage allowed'), findsOneWidget);
    expect(find.text('2 resets available'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('balances, restriction-only quotas and partial failures wrap', (
    tester,
  ) async {
    await pump(
      tester,
      AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          AgentUsageWindow(
            label: 'Cursor',
            restricted: true,
            resetsAt: now.add(const Duration(days: 1)),
          ),
          const AgentUsageWindow(
            label: 'Nous balance',
            remaining: 12.34,
            unit: 'USD',
          ),
        ],
        notices: const [
          AgentUsageNotice(
            provider: 'Anthropic',
            status: AgentUsageStatus.signInRequired,
          ),
        ],
      ),
      scale: 2,
    );
    expect(find.text('Cursor · Usage restricted'), findsOneWidget);
    expect(find.text(r'Nous balance · $12.34 remaining'), findsOneWidget);
    expect(
      find.textContaining('Anthropic · Usage unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all failed providers remain visible with their individual status',
    (tester) async {
      await pump(
        tester,
        const AgentUsage(
          status: AgentUsageStatus.notReported,
          notices: [
            AgentUsageNotice(
              provider: 'OpenAI Codex',
              status: AgentUsageStatus.signInRequired,
            ),
            AgentUsageNotice(
              provider: 'OpenRouter',
              status: AgentUsageStatus.notReported,
            ),
          ],
        ),
      );
      expect(
        find.textContaining('OpenAI Codex · Usage unavailable'),
        findsOneWidget,
      );
      expect(
        find.text('OpenRouter · Quota not reported by provider'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'collapsed rows disclose additional quotas and expand to all of them',
    (tester) async {
      final usage = AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          for (var i = 1; i <= 5; i++)
            AgentUsageWindow(label: 'Quota $i', usedPercent: 20),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentUsageSummary(usage: usage)),
        ),
      );
      expect(find.text('Quota 4 · 80% remaining'), findsNothing);
      expect(find.text('2 more usage details · expand above'), findsOneWidget);
      await pump(tester, usage);
      expect(find.text('Quota 5 · 80% remaining'), findsOneWidget);
      expect(find.textContaining('more usage details'), findsNothing);
    },
  );
  testWidgets('bars show the remaining fraction and clamp paid overage', (
    tester,
  ) async {
    await pump(
      tester,
      const AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          AgentUsageWindow(label: 'Unused', usedPercent: 0),
          AgentUsageWindow(label: 'Partial', usedPercent: 27.5),
          AgentUsageWindow(label: 'Exhausted', usedPercent: 100),
          AgentUsageWindow(
            label: 'Overage',
            usedPercent: 120,
            overageAllowed: true,
          ),
        ],
      ),
    );
    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars.map((bar) => bar.value), [1.0, 0.725, 0.0, 0.0]);
    expect(bars[1].semanticsValue, '72.5%');
    expect(find.text('Partial · 72.5% remaining'), findsOneWidget);
    expect(find.text('120% used including overage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
