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
    bool expanded = true,
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
                  expanded: expanded,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'throttled usage shows the next allowed check without a countdown timer',
    (tester) async {
      final retryAt = now.add(const Duration(minutes: 15));
      await pump(
        tester,
        AgentUsage(
          status: AgentUsageStatus.rateLimited,
          checkedAt: now,
          retryAt: retryAt,
        ),
        scale: 2,
      );
      expect(find.textContaining('Usage check rate limited'), findsOneWidget);
      expect(find.textContaining('Next usage check after'), findsOneWidget);
      final context = tester.element(find.byType(AgentUsageSummary));
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(retryAt.toLocal()));
      expect(find.textContaining(time), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await pump(
        tester,
        AgentUsage(
          status: AgentUsageStatus.available,
          checkedAt: now,
          retryAt: retryAt,
          windows: const [AgentUsageWindow(label: 'Weekly', usedPercent: 25)],
          notices: const [
            AgentUsageNotice(
              provider: 'Anthropic',
              status: AgentUsageStatus.rateLimited,
            ),
          ],
        ),
      );
      expect(find.textContaining('Next usage check after'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('failed accounts stay compact until expanded', (tester) async {
    const usage = AgentUsage(
      status: AgentUsageStatus.unavailable,
      notices: [
        AgentUsageNotice(
          provider: 'Anthropic',
          status: AgentUsageStatus.signInRequired,
        ),
        AgentUsageNotice(
          provider: 'OpenAI',
          status: AgentUsageStatus.unavailable,
        ),
      ],
    );
    await pump(tester, usage, expanded: false, scale: 2);
    expect(find.textContaining('Anthropic'), findsOneWidget);
    expect(find.textContaining('OpenAI'), findsNothing);
    expect(find.text('1 more usage detail · expand above'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await pump(tester, usage, scale: 2);
    expect(find.textContaining('OpenAI'), findsOneWidget);
    expect(find.textContaining('expand above'), findsNothing);
  });

  testWidgets('singular reset and hidden quota labels use singular nouns', (
    tester,
  ) async {
    const usage = AgentUsage(
      status: AgentUsageStatus.available,
      resetCredits: 1,
      windows: [
        AgentUsageWindow(label: 'A', unlimited: true),
        AgentUsageWindow(label: 'B', unlimited: true),
        AgentUsageWindow(label: 'C', unlimited: true),
        AgentUsageWindow(label: 'D', unlimited: true),
      ],
    );
    await pump(tester, usage, expanded: false);
    expect(find.text('1 more usage detail · expand above'), findsOneWidget);
    await pump(tester, usage);
    expect(find.text('1 reset available'), findsOneWidget);
  });

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
    expect(find.text('Reset time not reported'), findsNothing);
    expect(
      find.textContaining('Anthropic · Usage unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('balance reset hints appear only when a reset is supplied', (
    tester,
  ) async {
    await pump(
      tester,
      AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          AgentUsageWindow(
            label: 'Expiring credits',
            remaining: 5,
            resetsAt: now.add(const Duration(hours: 1)),
          ),
          const AgentUsageWindow(label: 'Weekly', usedPercent: 25),
        ],
      ),
    );
    expect(find.textContaining('Resets '), findsOneWidget);
    expect(find.text('Reset time not reported'), findsOneWidget);
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
