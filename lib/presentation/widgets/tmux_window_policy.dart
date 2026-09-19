import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/host_cli_launch_preferences.dart';

/// Moves an available preferred tool first, preserving the remaining order.
List<AgentLaunchTool> orderedAgentLaunchTools(
  Iterable<AgentLaunchTool> tools, {
  AgentLaunchTool? preferredTool,
}) {
  final ordered = tools.toList(growable: false);
  if (preferredTool == null) {
    return ordered;
  }

  final preferredIndex = ordered.indexOf(preferredTool);
  if (preferredIndex <= 0) {
    return ordered;
  }

  return <AgentLaunchTool>[
    ordered[preferredIndex],
    ...ordered.take(preferredIndex),
    ...ordered.skip(preferredIndex + 1),
  ];
}

/// Filters detected tools in display order, using no tools on detection failure.
Future<List<AgentLaunchTool>> resolveTmuxNewWindowTools(
  Future<Set<AgentLaunchTool>>? installedToolsFuture, {
  AgentLaunchTool? preferredTool,
}) async {
  Iterable<AgentLaunchTool> availableTools;
  if (installedToolsFuture == null) {
    availableTools = AgentLaunchTool.uiDisplayOrder;
  } else {
    try {
      final installed = await installedToolsFuture;
      availableTools = AgentLaunchTool.uiDisplayOrder.where(installed.contains);
    } on Object {
      availableTools = const <AgentLaunchTool>[];
    }
  }
  return orderedAgentLaunchTools(availableTools, preferredTool: preferredTool);
}

/// Presentation mode for a supported coding-agent mux window.
enum AgentWindowMode {
  /// Run the agent's complete terminal CLI.
  terminal,

  /// Run the agent through its ACP-native conversation surface.
  nativeAcp,
}

/// Returns the automatic mode, or null when the user should choose.
AgentWindowMode? preferredAgentWindowMode({
  required AgentWindowModePreference preference,
  bool forcePicker = false,
  bool hasNativeProvider = true,
}) {
  if (!hasNativeProvider) return AgentWindowMode.terminal;
  if (forcePicker) return null;
  return switch (preference) {
    AgentWindowModePreference.preferNative => AgentWindowMode.nativeAcp,
    AgentWindowModePreference.preferTerminal => AgentWindowMode.terminal,
    AgentWindowModePreference.askEveryTime => null,
  };
}
