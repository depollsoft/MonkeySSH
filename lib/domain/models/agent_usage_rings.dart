import 'acp_protocol.dart';
import 'acp_provider.dart';
import 'acp_session_state.dart';
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
    this._segments = const [],
  });

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

// Names emitted by the existing Pi multi-provider quota probe.
const _piUsageProviders = {
  'anthropic': 'Anthropic',
  'openai': 'OpenAI',
  'openai-codex': 'OpenAI Codex',
  'github-copilot': 'GitHub Copilot',
  'google-antigravity': 'Google Antigravity',
  'google-gemini-cli': 'Google Gemini',
  'openrouter': 'OpenRouter',
  'nous': 'Nous',
};

/// Reads Pi's live provider-qualified model selection, never a saved default.
String? piUsageModelProvider(AcpSessionState? session) {
  if (session == null || session.key.providerId != AcpBuiltinProviderIds.pi) {
    return null;
  }
  final option = session.configOptions
      .whereType<AcpSelectConfigOption>()
      .where((option) => option.category?.toLowerCase() == 'model')
      .firstOrNull;
  final model = option?.currentValue ?? session.modelState?.currentModelId;
  if (model == null) return null;
  final separator = model.indexOf('/');
  if (separator <= 0 || separator == model.length - 1) return null;
  final provider = model.substring(0, separator);
  return _piUsageProviders.containsKey(provider) ? provider : null;
}

/// Agents with numerical quota readers, including Pi's known active provider.
bool supportsAgentUsageRings(AgentLaunchTool tool, {String? modelProvider}) =>
    switch (tool) {
      AgentLaunchTool.claudeCode ||
      AgentLaunchTool.codex ||
      AgentLaunchTool.antigravity ||
      AgentLaunchTool.grokBuild => true,
      AgentLaunchTool.pi => _piUsageProviders.containsKey(modelProvider),
      _ => false,
    };

bool _usesAccountWindows(AgentLaunchTool tool, String? modelProvider) =>
    tool == AgentLaunchTool.claudeCode ||
    tool == AgentLaunchTool.codex ||
    (tool == AgentLaunchTool.pi &&
        const {'anthropic', 'openai', 'openai-codex'}.contains(modelProvider));

String? _ringWindowLabel(
  AgentLaunchTool tool,
  AgentUsageWindow window,
  String? modelProvider,
) {
  if (tool != AgentLaunchTool.pi) return window.label;
  final provider = _piUsageProviders[modelProvider];
  if (provider == null || !window.label.startsWith('$provider · ')) return null;
  return window.label.substring(provider.length + 3);
}

/// Categories used by the ring and its reset scheduler.
/// Grok paid spending/prepaid balances remain separate from included credits.
bool isAgentUsageRingWindow(
  AgentLaunchTool tool,
  AgentUsageWindow window, {
  String? modelProvider,
}) {
  final label = _ringWindowLabel(tool, window, modelProvider);
  if (label == null) return false;
  if (_usesAccountWindows(tool, modelProvider)) {
    return label == '5 hours' || label == 'Weekly';
  }
  return switch (tool) {
    AgentLaunchTool.grokBuild => label == 'Included credits',
    AgentLaunchTool.antigravity || AgentLaunchTool.pi => true,
    _ => false,
  };
}

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
  String? modelProvider,
}) {
  final staleAfter = agentUsageSnapshotMaxAge(tool);
  if (!supportsAgentUsageRings(tool, modelProvider: modelProvider) ||
      usage == null ||
      usage.status != AgentUsageStatus.available ||
      usage.checkedAt == null ||
      now.difference(usage.checkedAt!) >= staleAfter ||
      usage.notices.any(
        (notice) =>
            tool != AgentLaunchTool.pi ||
            notice.provider == _piUsageProviders[modelProvider] ||
            notice.provider.startsWith(
              '${_piUsageProviders[modelProvider]} · ',
            ),
      )) {
    return null;
  }

  final eligible = usage.windows
      .where(
        (window) =>
            isAgentUsageRingWindow(tool, window, modelProvider: modelProvider),
      )
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
    final matches = eligible
        .where(
          (window) => _ringWindowLabel(tool, window, modelProvider) == label,
        )
        .toList();
    return matches.length == 1 ? remaining(matches.single) : null;
  }

  final AgentUsageRings rings;
  if (_usesAccountWindows(tool, modelProvider)) {
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
