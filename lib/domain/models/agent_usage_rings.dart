import 'agent_launch_preset.dart';
import 'agent_usage.dart';

/// One independently reported allowance, expressed as a percentage remaining.
typedef AgentUsageRingSegment = ({String label, double remaining});

/// Reported allowances around the current agent icon.
class AgentUsageRings {
  /// Creates the familiar five-hour/weekly pair or a provider's labeled groups.
  const AgentUsageRings({
    this.shortTerm,
    this.weekly,
    List<AgentUsageRingSegment> segments = const [],
  }) : _segments = segments;

  /// Reported five-hour percentage remaining, when applicable.
  final double? shortTerm;

  /// Reported account-wide weekly percentage remaining, when applicable.
  final double? weekly;

  final List<AgentUsageRingSegment> _segments;

  /// Actual reported quotas only. Missing quotas do not occupy empty segments.
  List<AgentUsageRingSegment> get segments => _segments.isNotEmpty
      ? _segments
      : [
          if (shortTerm != null) (label: '5-hour', remaining: shortTerm!),
          if (weekly != null) (label: 'weekly', remaining: weekly!),
        ];

  /// Whether at least one numerical allowance is available.
  bool get isAvailable =>
      shortTerm != null || weekly != null || _segments.isNotEmpty;
}

/// Agents with numerical quota readers that do not need an inferred provider.
bool supportsAgentUsageRings(AgentLaunchTool tool) => switch (tool) {
  AgentLaunchTool.claudeCode ||
  AgentLaunchTool.codex ||
  AgentLaunchTool.antigravity ||
  AgentLaunchTool.grokBuild => true,
  _ => false,
};

/// Categories used by the ring and its reset scheduler.
/// Grok paid spending/prepaid balances remain separate from included credits.
bool isAgentUsageRingWindow(AgentLaunchTool tool, AgentUsageWindow window) =>
    switch (tool) {
      AgentLaunchTool.claudeCode || AgentLaunchTool.codex =>
        window.label == '5 hours' || window.label == 'Weekly',
      AgentLaunchTool.grokBuild => window.label == 'Included credits',
      AgentLaunchTool.antigravity => true,
      _ => false,
    };

/// Hard display-age limit, independent of how long an SSH request is queued.
Duration agentUsageSnapshotMaxAge(AgentLaunchTool tool) {
  final refreshGrace =
      agentUsageRefreshInterval(tool) + const Duration(minutes: 1);
  return refreshGrace > const Duration(minutes: 5)
      ? refreshGrace
      : const Duration(minutes: 5);
}

/// Projects the same reported numerical allowances used by Agent Management.
/// Claude/Codex scoped model limits are not substitutes for account-wide limits.
/// Antigravity shows its reported groups rather than guessing an active model.
AgentUsageRings? resolveAgentUsageRings(
  AgentLaunchTool tool,
  AgentUsage? usage, {
  required DateTime now,
}) {
  final staleAfter = agentUsageSnapshotMaxAge(tool);
  if (!supportsAgentUsageRings(tool) ||
      usage == null ||
      usage.status != AgentUsageStatus.available ||
      usage.checkedAt == null ||
      now.difference(usage.checkedAt!) >= staleAfter ||
      usage.notices.isNotEmpty) {
    return null;
  }

  final eligible = usage.windows
      .where((window) => isAgentUsageRingWindow(tool, window))
      .toList();
  double? remaining(AgentUsageWindow window) {
    final used = window.usedPercent;
    if (window.unlimited ||
        used == null ||
        !used.isFinite ||
        used < 0 ||
        (window.resetsAt != null && !window.resetsAt!.isAfter(now))) {
      return null;
    }
    return (100 - used).clamp(0.0, 100.0);
  }

  double? named(String label) {
    final matches = eligible.where((window) => window.label == label).toList();
    return matches.length == 1 ? remaining(matches.single) : null;
  }

  final AgentUsageRings rings;
  if (tool == AgentLaunchTool.claudeCode || tool == AgentLaunchTool.codex) {
    rings = AgentUsageRings(
      shortTerm: named('5 hours'),
      weekly: named('Weekly'),
    );
  } else {
    final segments = <AgentUsageRingSegment>[];
    for (final window in eligible) {
      // Duplicate labels cannot be reliably associated with one meter.
      if (eligible.where((other) => other.label == window.label).length != 1) {
        continue;
      }
      final value = remaining(window);
      if (value != null) segments.add((label: window.label, remaining: value));
    }
    // API response order can change. Keep group positions stable between reads.
    segments.sort((a, b) => a.label.compareTo(b.label));
    rings = AgentUsageRings(segments: List.unmodifiable(segments));
  }
  return rings.isAvailable ? rings : null;
}
