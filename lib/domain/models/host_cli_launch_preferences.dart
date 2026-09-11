/// App-wide default for launching ACP-capable coding agents.
enum AgentWindowModePreference {
  /// Ask whether to use the terminal or native chat for every launch.
  askEveryTime,

  /// Open ACP-capable agents in native chat by default.
  preferNative,

  /// Open ACP-capable agents in a terminal window by default.
  preferTerminal,
}

/// Persistence and presentation helpers for [AgentWindowModePreference].
extension AgentWindowModePreferencePresentation on AgentWindowModePreference {
  /// Stable settings value.
  String get storageValue => switch (this) {
    AgentWindowModePreference.askEveryTime => 'ask',
    AgentWindowModePreference.preferNative => 'native',
    AgentWindowModePreference.preferTerminal => 'terminal',
  };

  /// Human-readable label used in app settings.
  String get label => switch (this) {
    AgentWindowModePreference.askEveryTime => 'Ask every time',
    AgentWindowModePreference.preferNative => 'Prefer native chat',
    AgentWindowModePreference.preferTerminal => 'Prefer terminal',
  };

  /// Explains what selecting this default does for supported agents.
  String get explanation => switch (this) {
    AgentWindowModePreference.askEveryTime =>
      'Choose Terminal or Native chat for each new agent window.',
    AgentWindowModePreference.preferNative =>
      'Open the focused chat, tools, and permissions interface.',
    AgentWindowModePreference.preferTerminal =>
      'Open the agent’s full terminal CLI.',
  };

  /// Parses a stored preference, falling back safely for old or unknown data.
  static AgentWindowModePreference fromStorageValue(Object? value) =>
      switch (value) {
        'native' => AgentWindowModePreference.preferNative,
        'terminal' => AgentWindowModePreference.preferTerminal,
        _ => AgentWindowModePreference.askEveryTime,
      };
}

/// Host-scoped defaults for coding CLI launches.
class HostCliLaunchPreferences {
  /// Creates a new [HostCliLaunchPreferences].
  const HostCliLaunchPreferences({this.startInYoloMode = false});

  /// Decodes [HostCliLaunchPreferences] from JSON.
  factory HostCliLaunchPreferences.fromJson(Map<String, dynamic> json) =>
      HostCliLaunchPreferences(
        startInYoloMode: json['startInYoloMode'] == true,
      );

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startInYoloMode;

  /// Whether this preferences record has no saved overrides.
  bool get isEmpty => !startInYoloMode;

  /// Encodes this preferences record as JSON.
  Map<String, dynamic> toJson() => {
    if (startInYoloMode) 'startInYoloMode': true,
  };
}
