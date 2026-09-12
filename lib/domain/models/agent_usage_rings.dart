import 'agent_launch_preset.dart';
import 'agent_usage.dart';

/// Account-wide allowances displayed above and below the current agent icon.
class AgentUsageRings {
  /// Creates a snapshot. A missing half is unknown, never zero or unlimited.
  const AgentUsageRings({this.shortTerm, this.weekly});

  /// The reported five-hour allowance, expressed as a remaining percentage.
  final double? shortTerm;

  /// The reported account-wide weekly allowance, expressed as a remaining percentage.
  final double? weekly;

  /// Whether at least one comparable allowance is available.
  bool get isAvailable => shortTerm != null || weekly != null;
}

/// Readers with unambiguous account-wide five-hour and weekly categories.
/// Multi-provider credential stores cannot identify the active account/model.
bool supportsAgentUsageRings(AgentLaunchTool tool) =>
    tool == AgentLaunchTool.claudeCode || tool == AgentLaunchTool.codex;

/// Projects only exact, account-wide quota categories, not model-specific caps.
AgentUsageRings? resolveAgentUsageRings(
  AgentLaunchTool tool,
  AgentUsage? usage, {
  required DateTime now,
}) {
  if (!supportsAgentUsageRings(tool) ||
      usage == null ||
      usage.status != AgentUsageStatus.available ||
      usage.checkedAt == null ||
      now.difference(usage.checkedAt!) > const Duration(minutes: 5) ||
      usage.notices.isNotEmpty) {
    return null;
  }

  double? remaining(String label) {
    final matches = usage.windows
        .where((window) => window.label == label)
        .toList();
    if (matches.length != 1) return null;
    final window = matches.single;
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

  final rings = AgentUsageRings(
    shortTerm: remaining('5 hours'),
    weekly: remaining('Weekly'),
  );
  return rings.isAvailable ? rings : null;
}
