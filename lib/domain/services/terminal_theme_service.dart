import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../models/terminal_theme.dart';
import '../models/terminal_themes.dart';
import 'settings_service.dart';

/// Theme IDs from the foreground terminal connection that should drive app UI.
@immutable
class TerminalAppThemeOverride {
  /// Creates a new [TerminalAppThemeOverride].
  const TerminalAppThemeOverride({
    required this.owner,
    this.lightThemeId,
    this.darkThemeId,
  });

  /// Identity token used so screens only clear overrides they created.
  final Object owner;

  /// Light terminal theme ID for the foreground terminal connection.
  final String? lightThemeId;

  /// Dark terminal theme ID for the foreground terminal connection.
  final String? darkThemeId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalAppThemeOverride &&
          identical(owner, other.owner) &&
          lightThemeId == other.lightThemeId &&
          darkThemeId == other.darkThemeId;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(owner), lightThemeId, darkThemeId);
}

/// Notifier for the active terminal connection app-theme override.
class TerminalAppThemeOverrideNotifier
    extends Notifier<TerminalAppThemeOverride?> {
  /// Starts without an active terminal app-theme override.
  @override
  TerminalAppThemeOverride? build() => null;

  /// Current active terminal app-theme override.
  TerminalAppThemeOverride? get activeOverride => state;

  /// Updates the active terminal app-theme override.
  set activeOverride(TerminalAppThemeOverride override) {
    if (state == override) {
      return;
    }
    state = override;
  }

  /// Clears the active terminal app-theme override if [owner] created it.
  void clearForOwner(Object owner) {
    if (identical(state?.owner, owner)) {
      state = null;
    }
  }

  /// Clears any active terminal app-theme override.
  void clear() {
    if (state != null) {
      state = null;
    }
  }
}

/// Service for managing terminal themes.
///
/// Provides methods for resolving the appropriate theme for a host,
/// listing all available themes, and managing custom themes.
class TerminalThemeService {
  /// Creates a new [TerminalThemeService].
  TerminalThemeService(this._settings);

  final SettingsService _settings;

  /// Gets the theme for a host based on current brightness.
  ///
  /// Resolution order:
  /// 1. Host-specific override for the current brightness
  /// 2. Global default for the current brightness
  /// 3. Built-in default theme
  Future<TerminalThemeData> getThemeForHost(
    Host? host,
    Brightness brightness, {
    bool allowHostOverride = true,
  }) async {
    final isDark = brightness == Brightness.dark;

    if (allowHostOverride && host != null) {
      final hostThemeId = isDark
          ? host.terminalThemeDarkId
          : host.terminalThemeLightId;
      if (hostThemeId != null) {
        final theme = await getThemeById(hostThemeId);
        if (theme != null) {
          return theme;
        }
      }
    }

    final globalThemeId = isDark
        ? await _settings.getString(SettingKeys.defaultTerminalThemeDark)
        : await _settings.getString(SettingKeys.defaultTerminalThemeLight);

    if (globalThemeId != null) {
      final theme = await getThemeById(globalThemeId);
      if (theme != null) {
        return theme;
      }
    }

    return TerminalThemes.defaultThemeForBrightness(brightness);
  }

  /// Gets a theme by ID (checks built-in themes first, then custom).
  Future<TerminalThemeData?> getThemeById(String id) async {
    final builtIn = TerminalThemes.getById(id);
    if (builtIn != null && TerminalThemes.resolveThemeId(id) == id) {
      return builtIn;
    }

    final customThemes = await getCustomThemes();
    for (final theme in customThemes) {
      if (theme.id == id) {
        return theme;
      }
    }
    return builtIn;
  }

  /// Gets all available themes (built-in + custom).
  Future<List<TerminalThemeData>> getAllThemes() async {
    final custom = await getCustomThemes();
    return [...TerminalThemes.all, ...custom];
  }

  /// Gets all custom themes.
  Future<List<TerminalThemeData>> getCustomThemes() async {
    final json = await _settings.getString(SettingKeys.customTerminalThemes);
    if (json == null || json.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        return [];
      }

      return [for (final item in decoded) ?TerminalThemeData.tryFromJson(item)];
    } on FormatException {
      return [];
    }
  }

  /// Saves a custom theme.
  Future<void> saveCustomTheme(TerminalThemeData theme) async {
    final themes = await getCustomThemes();
    final index = themes.indexWhere(
      (existingTheme) => existingTheme.id == theme.id,
    );
    if (index >= 0) {
      themes[index] = theme;
    } else {
      themes.add(theme.copyWith(isCustom: true));
    }

    await _saveCustomThemes(themes);
  }

  /// Deletes a custom theme.
  Future<void> deleteCustomTheme(String themeId) async {
    final themes = await getCustomThemes();
    themes.removeWhere((theme) => theme.id == themeId);
    await _saveCustomThemes(themes);
  }

  Future<void> _saveCustomThemes(List<TerminalThemeData> themes) async {
    final json = jsonEncode(themes.map((theme) => theme.toJson()).toList());
    await _settings.setString(SettingKeys.customTerminalThemes, json);
  }
}

/// Provider for [TerminalThemeService].
final terminalThemeServiceProvider = Provider<TerminalThemeService>(
  (ref) => TerminalThemeService(ref.watch(settingsServiceProvider)),
);

/// Provider for all available themes.
final allTerminalThemesProvider = FutureProvider<List<TerminalThemeData>>((
  ref,
) {
  final service = ref.watch(terminalThemeServiceProvider);
  return service.getAllThemes();
});

/// Provider for custom themes only.
final customTerminalThemesProvider = FutureProvider<List<TerminalThemeData>>((
  ref,
) {
  final service = ref.watch(terminalThemeServiceProvider);
  return service.getCustomThemes();
});

/// Active terminal connection theme override for app-wide UI theming.
final terminalAppThemeOverrideProvider =
    NotifierProvider<
      TerminalAppThemeOverrideNotifier,
      TerminalAppThemeOverride?
    >(TerminalAppThemeOverrideNotifier.new);
