import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/agent_usage_rings.dart';

void main() {
  final now = DateTime.utc(2026, 9, 8, 12);
  AgentUsage snapshot(List<AgentUsageWindow> windows, {DateTime? checkedAt}) =>
      AgentUsage(
        status: AgentUsageStatus.available,
        windows: windows,
        checkedAt: checkedAt ?? now,
      );
  AgentUsageRings? project(
    AgentUsage usage, {
    AgentLaunchTool tool = AgentLaunchTool.claudeCode,
  }) => resolveAgentUsageRings(tool, usage, now: now);

  test('projects account-wide windows and ignores scoped model caps', () {
    final usage = snapshot(const [
      AgentUsageWindow(label: '5 hours', usedPercent: 42),
      AgentUsageWindow(label: 'Weekly', usedPercent: 18),
      AgentUsageWindow(label: 'Weekly · Fable', usedPercent: 99),
    ]);
    for (final tool in [AgentLaunchTool.claudeCode, AgentLaunchTool.codex]) {
      final rings = project(usage, tool: tool)!;
      expect(rings.shortTerm, 58);
      expect(rings.weekly, 82);
    }
  });
  test('duplicate or model/account-prefixed categories are not guessed', () {
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: '5 hours', usedPercent: 42),
          AgentUsageWindow(label: '5 hours', usedPercent: 72),
          AgentUsageWindow(label: 'Other account · Weekly', usedPercent: 18),
        ]),
      ),
      isNull,
    );
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: 'Weekly · Fable', usedPercent: 99),
        ]),
      ),
      isNull,
    );
  });
  test(
    'multi-provider agents remain unknown rather than selecting a saved account',
    () {
      final usage = snapshot(const [
        AgentUsageWindow(label: 'Weekly', usedPercent: 25),
      ]);
      for (final tool in AgentLaunchTool.values.where(
        (tool) => !supportsAgentUsageRings(tool),
      )) {
        expect(project(usage, tool: tool), isNull);
      }
    },
  );
  test('zero and overage are empty, missing and unlimited are absent', () {
    final rings = project(
      snapshot(const [
        AgentUsageWindow(
          label: '5 hours',
          usedPercent: 125,
          overageAllowed: true,
        ),
        AgentUsageWindow(label: 'Weekly', unlimited: true),
      ]),
    )!;
    expect(rings.shortTerm, 0);
    expect(rings.weekly, isNull);
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: '5 hours', remaining: 20, unit: 'USD'),
        ]),
      ),
      isNull,
    );
  });
  test('an elapsed reset hides only that half and never replenishes it', () {
    final rings = project(
      snapshot([
        AgentUsageWindow(label: '5 hours', usedPercent: 100, resetsAt: now),
        AgentUsageWindow(
          label: 'Weekly',
          usedPercent: 36,
          resetsAt: now.add(const Duration(days: 1)),
        ),
      ]),
    )!;
    expect(rings.shortTerm, isNull);
    expect(rings.weekly, 64);
  });
  test(
    'stale, failed, partial, and nonfinite snapshots do not imply capacity',
    () {
      const windows = [AgentUsageWindow(label: '5 hours', usedPercent: 25)];
      expect(
        project(
          snapshot(
            windows,
            checkedAt: now.subtract(const Duration(minutes: 6)),
          ),
        ),
        isNull,
      );
      expect(
        project(
          const AgentUsage(
            status: AgentUsageStatus.available,
            windows: windows,
          ),
        ),
        isNull,
      );
      for (final status in AgentUsageStatus.values.where(
        (s) => s != AgentUsageStatus.available,
      )) {
        expect(
          project(AgentUsage(status: status, checkedAt: now, windows: windows)),
          isNull,
        );
      }
      expect(
        project(
          AgentUsage(
            status: AgentUsageStatus.available,
            checkedAt: now,
            windows: windows,
            notices: const [
              AgentUsageNotice(
                provider: 'Other',
                status: AgentUsageStatus.unavailable,
              ),
            ],
          ),
        ),
        isNull,
      );
      for (final value in [double.nan, double.infinity, -1.0]) {
        expect(
          project(
            snapshot([AgentUsageWindow(label: '5 hours', usedPercent: value)]),
          ),
          isNull,
        );
      }
    },
  );
}
