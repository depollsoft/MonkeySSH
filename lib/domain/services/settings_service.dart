import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../models/host_cli_launch_preferences.dart';
import '../models/terminal_theme.dart';
import '../models/terminal_themes.dart';

/// Keys for app settings.
abstract final class SettingKeys {
  /// Theme mode: 'system', 'light', 'dark'.
  static const themeMode = 'theme_mode';

  /// Whether terminal themes also style app chrome.
  static const terminalThemesApplyToApp = 'terminal_themes_apply_to_app';

  /// Terminal font family.
  static const terminalFont = 'terminal_font';

  /// Terminal font size.
  static const terminalFontSize = 'terminal_font_size';

  /// Default terminal theme ID for light mode.
  static const defaultTerminalThemeLight = 'default_terminal_theme_light';

  /// Default terminal theme ID for dark mode.
  static const defaultTerminalThemeDark = 'default_terminal_theme_dark';

  /// Custom terminal themes (JSON array).
  static const customTerminalThemes = 'custom_terminal_themes';

  /// Terminal cursor style.
  static const cursorStyle = 'cursor_style';

  /// Terminal bell sound enabled.
  static const bellSound = 'bell_sound';

  /// Whether the remote shell may post desktop notifications (OSC 9/777/99).
  static const terminalNotifications = 'terminal_notifications';

  /// Keep the device awake while a terminal is active.
  static const terminalWakeLock = 'terminal_wake_lock';

  /// Enable tapping terminal file paths to open SFTP.
  static const terminalPathLinks = 'terminal_path_links';

  /// Show underlines for clickable terminal file paths.
  static const terminalPathLinkUnderlines = 'terminal_path_link_badges';

  /// Open forwarded localhost links in the embedded browser.
  static const portForwardBrowserLinks = 'port_forward_browser_links';

  /// Whether legacy shared-origin WebView cookies have been cleared.
  static const portForwardBrowserCookieIsolationMigration =
      'port_forward_browser_cookie_isolation_v1';

  /// Enable shell completion popups while typing in the terminal.
  static const shellCompletions = 'shell_completions';

  /// Ask before closing a tmux or MonkeyMux terminal window.
  static const confirmMuxWindowClose = 'confirm_mux_window_close';

  /// Auto-lock timeout in minutes.
  static const autoLockTimeout = 'auto_lock_timeout';

  /// Whether MonkeySSH Pro is currently unlocked from the store.
  static const monetizationProUnlocked = 'monetization_pro_unlocked';

  /// Active product ID that most recently unlocked MonkeySSH Pro.
  static const monetizationActiveProductId = 'monetization_active_product_id';

  /// Active offer ID that most recently unlocked MonkeySSH Pro.
  static const monetizationActiveOfferId = 'monetization_active_offer_id';

  /// Timestamp of the most recent entitlement update.
  static const monetizationEntitlementUpdatedAt =
      'monetization_entitlement_updated_at';

  /// Debug-only local premium override.
  static const monetizationDebugUnlocked = 'monetization_debug_unlocked';

  /// Saved host-scoped coding-agent launch presets.
  static const agentLaunchPresets = 'agent_launch_presets';

  /// Show update prompts for agent CLIs and ACP adapters.
  static const agentUpdateNotifications = 'agent_update_notifications';

  /// Saved host IDs pinned into the app's home-screen shortcut set.
  static const homeScreenShortcutHostIds = 'home_screen_shortcut_host_ids';

  /// Saved host-scoped coding CLI launch preferences.
  static const hostCliLaunchPreferences = 'host_cli_launch_preferences';

  /// App-wide default for ACP-capable agent windows.
  static const agentWindowModePreference = 'agent_window_mode_preference';

  /// Saved user-defined ACP provider definitions (JSON array).
  static const acpCustomProviders = 'acp_custom_providers';

  /// Saved non-content references to recently used ACP sessions (JSON array).
  ///
  /// Only host/provider/bridge/session identifiers, an optional title and
  /// working directory, and activity timestamps are persisted; transcript
  /// content is never stored.
  static const acpRecentSessions = 'acp_recent_sessions';

  /// Canonical key of the last selected ACP session (JSON string).
  static const acpLastSelectedSession = 'acp_last_selected_session';

  /// Enable shared clipboard between device and remote session.
  ///
  /// The remote host can update the local clipboard through OSC 52 and remote
  /// clipboard utilities when available.
  static const sharedClipboard = 'shared_clipboard';

  /// Allow the remote host to read the local clipboard.
  static const sharedClipboardLocalRead = 'shared_clipboard_local_read';

  /// Whether tapping the terminal automatically shows the keyboard.
  ///
  /// When disabled, the keyboard can only be toggled via the toolbar button.
  static const tapToShowKeyboard = 'tap_to_show_keyboard';

  /// Whether anonymous analytics and crash reporting are enabled.
  static const telemetryCollection = 'telemetry_collection';

  /// State of the one-time telemetry opt-in prompt.
  static const telemetryOptInPromptState = 'telemetry_opt_in_prompt_state';

  /// Count of foreground app launches used to delay the telemetry prompt.
  static const telemetryAppLaunchCount = 'telemetry_app_launch_count';
}

/// Service for managing app settings.
class SettingsService {
  /// Creates a new [SettingsService].
  SettingsService(this._db);

  final AppDatabase _db;

  /// Get a string setting.
  Future<String?> getString(String key) async {
    final result = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return result?.value;
  }

  /// Get an int setting.
  Future<int?> getInt(String key) async {
    final value = await getString(key);
    return value != null ? int.tryParse(value) : null;
  }

  /// Get a bool setting.
  Future<bool> getBool(String key, {bool defaultValue = false}) async {
    final value = await getString(key);
    if (value == 'true') return true;
    if (value == 'false') return false;
    return defaultValue;
  }

  /// Get a JSON setting.
  Future<Map<String, dynamic>?> getJson(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Set a string setting.
  Future<void> setString(String key, String value) async {
    await _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  /// Set an int setting.
  Future<void> setInt(String key, int value) =>
      setString(key, value.toString());

  /// Set a bool setting.
  Future<void> setBool(String key, {required bool value}) =>
      setString(key, value.toString());

  /// Set a JSON setting.
  Future<void> setJson(String key, Map<String, dynamic> value) =>
      setString(key, jsonEncode(value));

  /// Atomically reads and updates a JSON setting.
  ///
  /// Returning null from [update] removes the setting. The transaction also
  /// serializes updates made through other services using this database.
  Future<void> updateJson(
    String key,
    Map<String, dynamic>? Function(Map<String, dynamic>? current) update,
  ) => _db.transaction(() async {
    final value = update(await getJson(key));
    if (value == null) {
      await delete(key);
    } else {
      await setJson(key, value);
    }
  });

  /// Delete a setting.
  Future<void> delete(String key) async {
    await (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go();
  }

  /// Get all settings.
  Future<Map<String, String>> getAll() async {
    final results = await _db.select(_db.settings).get();
    return Map.fromEntries(results.map((s) => MapEntry(s.key, s.value)));
  }

  /// Watch a setting.
  Stream<String?> watchString(String key) => (_db.select(
    _db.settings,
  )..where((s) => s.key.equals(key))).watchSingleOrNull().map((s) => s?.value);
}

/// Provider for [SettingsService].
final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(databaseProvider)),
);

abstract class _AsyncSettingsNotifier<T> extends Notifier<T> {
  late SettingsService _settings;
  bool _disposed = false;
  Future<void>? _initialization;
  var _stateRevision = 0;

  SettingsService get _settingsService => _settings;

  bool get _isDisposed => _disposed;

  T get _defaultValue;

  Future<T> _loadValue(SettingsService settings);

  @override
  T build() {
    _settings = ref.watch(settingsServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final initializationRevision = ++_stateRevision;
    final settings = _settings;
    _initialization = Future<void>.microtask(
      () => _init(initializationRevision, settings),
    );
    return _defaultValue;
  }

  Future<void> _init(
    int initializationRevision,
    SettingsService settings,
  ) async {
    if (_disposed || initializationRevision != _stateRevision) return;
    final value = await _loadValue(settings);
    if (_disposed || initializationRevision != _stateRevision) return;
    state = value;
  }

  /// Waits until this notifier has loaded its persisted value.
  Future<T> initializedValue() async {
    await _initialization;
    return state;
  }

  /// Publishes a user choice, including optimistic updates before persistence.
  ///
  /// Incrementing the revision prevents an older initialization read from
  /// replacing a newer user choice when both operations overlap.
  void _setPersistedState(T value) {
    _stateRevision++;
    state = value;
  }
}

abstract class _BooleanSettingsNotifier extends _AsyncSettingsNotifier<bool> {
  _BooleanSettingsNotifier(this._key, {required bool defaultValue})
    : _defaultValue = defaultValue;

  final String _key;

  @override
  final bool _defaultValue;

  @override
  Future<bool> _loadValue(SettingsService settings) =>
      settings.getBool(_key, defaultValue: _defaultValue);

  /// Persists whether this setting is enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(_key, value: enabled);
    _setPersistedState(enabled);
  }
}

/// Notifier for the app-wide coding-agent window default.
class AgentWindowModePreferenceNotifier
    extends _AsyncSettingsNotifier<AgentWindowModePreference> {
  @override
  AgentWindowModePreference get _defaultValue =>
      AgentWindowModePreference.askEveryTime;

  @override
  Future<AgentWindowModePreference> _loadValue(
    SettingsService settings,
  ) async => AgentWindowModePreferencePresentation.fromStorageValue(
    await settings.getString(SettingKeys.agentWindowModePreference),
  );

  /// Persists the default used by ordinary taps on ACP-capable agents.
  Future<void> setPreference(AgentWindowModePreference preference) async {
    await _settingsService.setString(
      SettingKeys.agentWindowModePreference,
      preference.storageValue,
    );
    _setPersistedState(preference);
  }
}

/// App-wide coding-agent window default with write capability.
final agentWindowModePreferenceNotifierProvider =
    NotifierProvider<
      AgentWindowModePreferenceNotifier,
      AgentWindowModePreference
    >(AgentWindowModePreferenceNotifier.new);

/// Notifier for theme mode with write capability.
class ThemeModeNotifier extends _AsyncSettingsNotifier<ThemeMode> {
  @override
  ThemeMode get _defaultValue => ThemeMode.system;

  @override
  Future<ThemeMode> _loadValue(SettingsService settings) async {
    final value = await settings.getString(SettingKeys.themeMode) ?? 'system';
    return _parseThemeMode(value);
  }

  /// Set the theme mode.
  Future<void> setThemeMode(ThemeMode mode) async {
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _settingsService.setString(SettingKeys.themeMode, value);
    _setPersistedState(mode);
  }

  ThemeMode _parseThemeMode(String value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

/// Provider for theme mode with write capability.
final themeModeNotifierProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Notifier for terminal themes applying to app chrome.
class TerminalThemesApplyToAppNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.terminalThemesApplyToApp].
  TerminalThemesApplyToAppNotifier()
    : super(SettingKeys.terminalThemesApplyToApp, defaultValue: true);
}

/// Provider for terminal themes applying to app chrome with write capability.
final terminalThemesApplyToAppNotifierProvider =
    NotifierProvider<TerminalThemesApplyToAppNotifier, bool>(
      TerminalThemesApplyToAppNotifier.new,
    );

/// Notifier for font size with write capability.
class FontSizeNotifier extends _AsyncSettingsNotifier<double> {
  Future<void> _writeChain = Future<void>.value();
  int _latestWriteToken = 0;

  @override
  double get _defaultValue => 14;

  @override
  Future<double> _loadValue(SettingsService settings) async {
    final value = await settings.getInt(SettingKeys.terminalFontSize);
    return value?.toDouble() ?? 14.0;
  }

  /// Set the font size.
  Future<void> setFontSize(double size) async {
    _setPersistedState(size);
    final writeToken = ++_latestWriteToken;
    final nextWrite = _writeChain.catchError((Object _) {}).then((_) async {
      if (_isDisposed || writeToken != _latestWriteToken) {
        return;
      }
      await _settingsService.setInt(SettingKeys.terminalFontSize, size.round());
    });
    _writeChain = nextWrite;
    await nextWrite;
  }
}

/// Provider for font size with write capability.
final fontSizeNotifierProvider = NotifierProvider<FontSizeNotifier, double>(
  FontSizeNotifier.new,
);

/// Notifier for font family with write capability.
class FontFamilyNotifier extends _AsyncSettingsNotifier<String> {
  @override
  String get _defaultValue => 'monospace';

  @override
  Future<String> _loadValue(SettingsService settings) async =>
      await settings.getString(SettingKeys.terminalFont) ?? 'monospace';

  /// Set the font family.
  Future<void> setFontFamily(String family) async {
    await _settingsService.setString(SettingKeys.terminalFont, family);
    _setPersistedState(family);
  }
}

/// Provider for font family with write capability.
final fontFamilyNotifierProvider = NotifierProvider<FontFamilyNotifier, String>(
  FontFamilyNotifier.new,
);

/// Notifier for auto-lock timeout with write capability.
class AutoLockTimeoutNotifier extends _AsyncSettingsNotifier<int> {
  @override
  int get _defaultValue => 5;

  @override
  Future<int> _loadValue(SettingsService settings) async =>
      await settings.getInt(SettingKeys.autoLockTimeout) ?? 5;

  /// Set the auto-lock timeout in minutes.
  Future<void> setTimeout(int minutes) async {
    await _settingsService.setInt(SettingKeys.autoLockTimeout, minutes);
    _setPersistedState(minutes);
  }
}

/// Provider for auto-lock timeout with write capability.
final autoLockTimeoutNotifierProvider =
    NotifierProvider<AutoLockTimeoutNotifier, int>(AutoLockTimeoutNotifier.new);

/// Notifier for mux window close confirmations.
class ConfirmMuxWindowCloseNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.confirmMuxWindowClose].
  ConfirmMuxWindowCloseNotifier()
    : super(SettingKeys.confirmMuxWindowClose, defaultValue: true);
}

/// Provider for mux window close confirmations.
final confirmMuxWindowCloseNotifierProvider =
    NotifierProvider<ConfirmMuxWindowCloseNotifier, bool>(
      ConfirmMuxWindowCloseNotifier.new,
    );

/// Notifier for cursor style with write capability.
class CursorStyleNotifier extends _AsyncSettingsNotifier<String> {
  @override
  String get _defaultValue => 'block';

  @override
  Future<String> _loadValue(SettingsService settings) async =>
      await settings.getString(SettingKeys.cursorStyle) ?? 'block';

  /// Set the cursor style.
  Future<void> setCursorStyle(String style) async {
    await _settingsService.setString(SettingKeys.cursorStyle, style);
    _setPersistedState(style);
  }
}

/// Provider for cursor style with write capability.
final cursorStyleNotifierProvider =
    NotifierProvider<CursorStyleNotifier, String>(CursorStyleNotifier.new);

/// Notifier for bell sound with write capability.
class BellSoundNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.bellSound].
  BellSoundNotifier() : super(SettingKeys.bellSound, defaultValue: true);
}

/// Provider for bell sound with write capability.
final bellSoundNotifierProvider = NotifierProvider<BellSoundNotifier, bool>(
  BellSoundNotifier.new,
);

/// Notifier for terminal desktop notifications (OSC 9/777/99) with write
/// capability.
class TerminalNotificationsNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.terminalNotifications].
  TerminalNotificationsNotifier()
    : super(SettingKeys.terminalNotifications, defaultValue: true);
}

/// Provider for terminal desktop notifications with write capability.
final terminalNotificationsNotifierProvider =
    NotifierProvider<TerminalNotificationsNotifier, bool>(
      TerminalNotificationsNotifier.new,
    );

/// Notifier for coding-agent update indicators.
class AgentUpdateNotificationsNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.agentUpdateNotifications].
  AgentUpdateNotificationsNotifier()
    : super(SettingKeys.agentUpdateNotifications, defaultValue: true);
}

/// Provider for coding-agent update indicators.
final agentUpdateNotificationsNotifierProvider =
    NotifierProvider<AgentUpdateNotificationsNotifier, bool>(
      AgentUpdateNotificationsNotifier.new,
    );

/// Notifier for terminal wake lock with write capability.
class TerminalWakeLockNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.terminalWakeLock].
  TerminalWakeLockNotifier()
    : super(SettingKeys.terminalWakeLock, defaultValue: false);
}

/// Provider for terminal wake lock with write capability.
final terminalWakeLockNotifierProvider =
    NotifierProvider<TerminalWakeLockNotifier, bool>(
      TerminalWakeLockNotifier.new,
    );

/// Notifier for terminal file path links with write capability.
class TerminalPathLinksNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.terminalPathLinks].
  TerminalPathLinksNotifier()
    : super(SettingKeys.terminalPathLinks, defaultValue: true);
}

/// Provider for terminal file path links with write capability.
final terminalPathLinksNotifierProvider =
    NotifierProvider<TerminalPathLinksNotifier, bool>(
      TerminalPathLinksNotifier.new,
    );

/// Notifier for terminal file path underlines with write capability.
class TerminalPathLinkUnderlinesNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.terminalPathLinkUnderlines].
  TerminalPathLinkUnderlinesNotifier()
    : super(SettingKeys.terminalPathLinkUnderlines, defaultValue: true);
}

/// Provider for terminal file path underlines with write capability.
final terminalPathLinkUnderlinesNotifierProvider =
    NotifierProvider<TerminalPathLinkUnderlinesNotifier, bool>(
      TerminalPathLinkUnderlinesNotifier.new,
    );

/// Notifier for forwarded localhost links with write capability.
class PortForwardBrowserLinksNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.portForwardBrowserLinks].
  PortForwardBrowserLinksNotifier()
    : super(SettingKeys.portForwardBrowserLinks, defaultValue: true);
}

/// Provider for forwarded localhost links with write capability.
final portForwardBrowserLinksNotifierProvider =
    NotifierProvider<PortForwardBrowserLinksNotifier, bool>(
      PortForwardBrowserLinksNotifier.new,
    );

/// Notifier for terminal shell completion popups with write capability.
class ShellCompletionsNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.shellCompletions].
  ShellCompletionsNotifier()
    : super(SettingKeys.shellCompletions, defaultValue: true);
}

/// Provider for terminal shell completion popups with write capability.
final shellCompletionsNotifierProvider =
    NotifierProvider<ShellCompletionsNotifier, bool>(
      ShellCompletionsNotifier.new,
    );

/// State for terminal theme settings (light and dark).
class TerminalThemeSettings {
  /// Creates a new [TerminalThemeSettings].
  const TerminalThemeSettings({
    required this.lightThemeId,
    required this.darkThemeId,
  });

  /// Theme ID for light mode.
  final String lightThemeId;

  /// Theme ID for dark mode.
  final String darkThemeId;

  /// Creates a copy with the given fields replaced.
  TerminalThemeSettings copyWith({String? lightThemeId, String? darkThemeId}) =>
      TerminalThemeSettings(
        lightThemeId: lightThemeId ?? this.lightThemeId,
        darkThemeId: darkThemeId ?? this.darkThemeId,
      );
}

/// Notifier for terminal theme settings.
class TerminalThemeSettingsNotifier
    extends _AsyncSettingsNotifier<TerminalThemeSettings> {
  @override
  TerminalThemeSettings get _defaultValue => const TerminalThemeSettings(
    lightThemeId: TerminalThemes.defaultLightThemeId,
    darkThemeId: TerminalThemes.defaultDarkThemeId,
  );

  @override
  Future<TerminalThemeSettings> _loadValue(SettingsService settings) async {
    final light = await settings.getString(
      SettingKeys.defaultTerminalThemeLight,
    );
    final dark = await settings.getString(SettingKeys.defaultTerminalThemeDark);
    final customThemeIds = await _getCustomTerminalThemeIds(settings);
    final lightThemeId = _normalizeThemeId(
      light,
      brightness: Brightness.light,
      customThemeIds: customThemeIds,
    );
    final darkThemeId = _normalizeThemeId(
      dark,
      brightness: Brightness.dark,
      customThemeIds: customThemeIds,
    );
    if (_isDisposed) return state;
    await _persistNormalizedThemeId(
      settings,
      key: SettingKeys.defaultTerminalThemeLight,
      storedThemeId: light,
      normalizedThemeId: lightThemeId,
    );
    await _persistNormalizedThemeId(
      settings,
      key: SettingKeys.defaultTerminalThemeDark,
      storedThemeId: dark,
      normalizedThemeId: darkThemeId,
    );
    return TerminalThemeSettings(
      lightThemeId: lightThemeId,
      darkThemeId: darkThemeId,
    );
  }

  Future<Set<String>> _getCustomTerminalThemeIds(
    SettingsService settings,
  ) async {
    final json = await settings.getString(SettingKeys.customTerminalThemes);
    if (json == null || json.isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        return const {};
      }

      final themeIds = <String>{};
      for (final item in decoded) {
        final theme = TerminalThemeData.tryFromJson(item);
        if (theme != null) {
          themeIds.add(theme.id);
        }
      }
      return themeIds;
    } on FormatException {
      return const {};
    }
  }

  String _normalizeThemeId(
    String? themeId, {
    required Brightness brightness,
    required Set<String> customThemeIds,
  }) {
    final defaultThemeId = TerminalThemes.defaultThemeIdForBrightness(
      brightness,
    );
    if (themeId == null || themeId.isEmpty) {
      return defaultThemeId;
    }
    if (customThemeIds.contains(themeId)) {
      return themeId;
    }
    final resolvedThemeId = TerminalThemes.resolveThemeId(themeId);
    if (TerminalThemes.getById(resolvedThemeId) != null) {
      return resolvedThemeId;
    }
    return defaultThemeId;
  }

  Future<void> _persistNormalizedThemeId(
    SettingsService settings, {
    required String key,
    required String? storedThemeId,
    required String normalizedThemeId,
  }) async {
    if (storedThemeId != null && storedThemeId != normalizedThemeId) {
      await settings.setString(key, normalizedThemeId);
    }
  }

  /// Set the light mode theme.
  Future<void> setLightTheme(String themeId) async {
    await _settingsService.setString(
      SettingKeys.defaultTerminalThemeLight,
      themeId,
    );
    _setPersistedState(state.copyWith(lightThemeId: themeId));
  }

  /// Set the dark mode theme.
  Future<void> setDarkTheme(String themeId) async {
    await _settingsService.setString(
      SettingKeys.defaultTerminalThemeDark,
      themeId,
    );
    _setPersistedState(state.copyWith(darkThemeId: themeId));
  }
}

/// Provider for terminal theme settings.
final terminalThemeSettingsProvider =
    NotifierProvider<TerminalThemeSettingsNotifier, TerminalThemeSettings>(
      TerminalThemeSettingsNotifier.new,
    );

/// Provider for shared clipboard setting.
final sharedClipboardProvider = FutureProvider<bool>((ref) async {
  final value = await ref
      .watch(sharedClipboardNotifierProvider.notifier)
      .initializedValue();
  // Watching the default before initialization can invalidate a pending read
  // with no listeners, leaving its future waiting for a rebuild indefinitely.
  if (!ref.mounted) return value;
  return ref.watch(sharedClipboardNotifierProvider);
});

/// Provider for local clipboard read sharing setting.
final sharedClipboardLocalReadProvider = FutureProvider<bool>((ref) async {
  final value = await ref
      .watch(sharedClipboardLocalReadNotifierProvider.notifier)
      .initializedValue();
  // Subscribe to changes only after the persisted value has been loaded.
  if (!ref.mounted) return value;
  return ref.watch(sharedClipboardLocalReadNotifierProvider);
});

/// Notifier for shared clipboard remote-to-local writes.
class SharedClipboardNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.sharedClipboard].
  SharedClipboardNotifier()
    : super(SettingKeys.sharedClipboard, defaultValue: false);
}

/// Provider for shared clipboard setting with write capability.
final sharedClipboardNotifierProvider =
    NotifierProvider<SharedClipboardNotifier, bool>(
      SharedClipboardNotifier.new,
    );

/// Notifier for local clipboard reads from the remote side.
class SharedClipboardLocalReadNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.sharedClipboardLocalRead].
  SharedClipboardLocalReadNotifier()
    : super(SettingKeys.sharedClipboardLocalRead, defaultValue: false);
}

/// Provider for local clipboard read sharing with write capability.
final sharedClipboardLocalReadNotifierProvider =
    NotifierProvider<SharedClipboardLocalReadNotifier, bool>(
      SharedClipboardLocalReadNotifier.new,
    );

/// Notifier for tap-to-show-keyboard with write capability.
class TapToShowKeyboardNotifier extends _BooleanSettingsNotifier {
  /// Creates the notifier for [SettingKeys.tapToShowKeyboard].
  TapToShowKeyboardNotifier()
    : super(SettingKeys.tapToShowKeyboard, defaultValue: true);
}

/// Provider for tap-to-show-keyboard setting with write capability.
final tapToShowKeyboardNotifierProvider =
    NotifierProvider<TapToShowKeyboardNotifier, bool>(
      TapToShowKeyboardNotifier.new,
    );
