import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import 'terminal_theme.dart';

/// Collection of built-in terminal themes.
///
/// Built-ins are a curated set of popular themes from the live
/// iTerm2-Color-Schemes repository used by iterm2colorschemes.com.
abstract final class TerminalThemes {
  /// Default theme ID for dark mode.
  static const defaultDarkThemeId = 'monkeyssh-dark';

  /// Default theme ID for light mode.
  static const defaultLightThemeId = 'monkeyssh-light';

  /// Default theme for dark mode.
  static const defaultDarkTheme = monkeyDark;

  /// Default theme for light mode.
  static const defaultLightTheme = monkeyLight;

  /// All built-in themes.
  static const List<TerminalThemeData> all = [...darkThemes, ...lightThemes];

  /// Dark themes collection.
  static const List<TerminalThemeData> darkThemes = [
    monkeyDark,
    dracula,
    catppuccinMocha,
    tokyoNightNight,
    gruvboxDark,
    solarizedDark,
    nord,
    atomOneDark,
    monokaiPro,
    ayu,
    nightOwl,
    githubDarkDefault,
  ];

  /// Light themes collection.
  static const List<TerminalThemeData> lightThemes = [
    monkeyLight,
    githubLightDefault,
    catppuccinLatte,
    tokyoNightDay,
    gruvboxLight,
    solarizedLight,
    nordLight,
    atomOneLight,
    ayuLight,
    nightOwlishLight,
    blulocoLight,
  ];

  static final Map<String, TerminalThemeData> _byId = {
    for (final theme in all) theme.id: theme,
  };

  static const _legacyThemeIdAliases = {
    'dracula': 'iterm2-dracula',
    'github-light': 'iterm2-github-light-default',
    'midnight-purple': defaultDarkThemeId,
    'slate': 'iterm2-atom-one-dark',
    'arctic': 'iterm2-nord',
    'city-lights': 'iterm2-tokyonight-night',
    'velvet': 'iterm2-catppuccin-mocha',
    'ember': 'iterm2-gruvbox-dark',
    'vivid': 'iterm2-monokai-pro',
    'golden-dark': 'iterm2-ayu',
    'charcoal': 'iterm2-atom-one-dark',
    'twilight': 'iterm2-tokyonight-night',
    'ink-wash': 'iterm2-ayu',
    'retrowave': 'iterm2-monokai-pro',
    'hacker': 'iterm2-night-owl',
    'neon-punk': 'iterm2-night-owl',
    'ocean-dark': 'iterm2-iterm2-solarized-dark',
    'storm-cloud': 'iterm2-tokyonight-night',
    'clean-white': defaultLightThemeId,
    'parchment': 'iterm2-iterm2-solarized-light',
    'daylight': defaultLightThemeId,
    'rose-milk': 'iterm2-catppuccin-latte',
    'wheat': 'iterm2-gruvbox-light',
    'sunrise': 'iterm2-ayu-light',
    'paper': 'iterm2-atom-one-light',
    'mint-green': 'iterm2-night-owlish-light',
  };

  /// Resolves legacy built-in theme IDs to their current iTerm2 theme IDs.
  static String resolveThemeId(String id) => _legacyThemeIdAliases[id] ?? id;

  /// Gets a theme by ID, returns null if not found.
  ///
  /// [additionalThemes] may include custom themes or a combined built-in/custom
  /// list; built-ins are checked first so duplicate built-in IDs are ignored.
  static TerminalThemeData? getById(
    String id, {
    Iterable<TerminalThemeData> additionalThemes = const [],
  }) {
    TerminalThemeData? lookup(String themeId) =>
        _byId[themeId] ??
        additionalThemes.firstWhereOrNull((theme) => theme.id == themeId);

    final theme = lookup(id);
    if (theme != null) return theme;
    final resolvedId = resolveThemeId(id);
    return resolvedId == id ? null : lookup(resolvedId);
  }

  /// Returns the built-in default theme ID for [brightness].
  static String defaultThemeIdForBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? defaultDarkThemeId : defaultLightThemeId;

  /// Returns the built-in default theme for [brightness].
  static TerminalThemeData defaultThemeForBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? defaultDarkTheme : defaultLightTheme;

  /// Resolves [themeId] against built-in and [additionalThemes].
  ///
  /// Falls back to the built-in default for [brightness] when the ID is null or
  /// unavailable.
  static TerminalThemeData resolveById({
    required Brightness brightness,
    required String? themeId,
    Iterable<TerminalThemeData> additionalThemes = const [],
  }) {
    if (themeId != null) {
      final theme = getById(themeId, additionalThemes: additionalThemes);
      if (theme != null) {
        return theme;
      }
    }

    return defaultThemeForBrightness(brightness);
  }

  /// MonkeySSH Dark — the signature MonkeySSH theme built around the logo
  /// teal `#14756c` and mint accent `#7CFF8A`. Designed to feel classy and
  /// readable: a cool deep teal-blue charcoal background, teal-tinted
  /// off-white text, and a measured palette that leans green/teal/cyan/blue
  /// while keeping semantic colors clearly distinct. The selection is a
  /// translucent teal so highlighted text remains readable through the
  /// overlay.
  static const monkeyDark = TerminalThemeData(
    id: 'monkeyssh-dark',
    name: 'MonkeySSH Dark',
    isDark: true,
    foreground: Color(0xFFD7E7E3),
    background: Color(0xFF0D1A20),
    cursor: Color(0xFF14756C),
    selection: Color(0x4014756C),
    black: Color(0xFF152228),
    red: Color(0xFFE27085),
    green: Color(0xFF5FCB85),
    yellow: Color(0xFFD6CC76),
    blue: Color(0xFF5BA8D1),
    magenta: Color(0xFFA99AD8),
    cyan: Color(0xFF3FB8AC),
    white: Color(0xFFC2CECC),
    brightBlack: Color(0xFF4D6260),
    brightRed: Color(0xFFF08F9F),
    brightGreen: Color(0xFF7CFF8A),
    brightYellow: Color(0xFFEAD881),
    brightBlue: Color(0xFF8BCBE5),
    brightMagenta: Color(0xFFC8B8E0),
    brightCyan: Color(0xFF5FE0CC),
    brightWhite: Color(0xFFF0F4F3),
  );

  /// MonkeySSH Light — the daytime companion to [monkeyDark]. Uses a cool
  /// near-white background with a faint mint undertone, a deep teal-charcoal
  /// foreground, and the signature logo teal `#14756c` as both the cursor
  /// and the cyan slot so the brand color drives Material's primary as well.
  /// The ANSI palette favors greens, teals, and blues for a calm, classy
  /// daytime surface; the selection is a translucent teal so selected text
  /// stays readable through the overlay.
  static const monkeyLight = TerminalThemeData(
    id: 'monkeyssh-light',
    name: 'MonkeySSH Light',
    isDark: false,
    foreground: Color(0xFF0D2B28),
    background: Color(0xFFEBF3F2),
    cursor: Color(0xFF14756C),
    selection: Color(0x4014756C),
    black: Color(0xFF0D2B28),
    red: Color(0xFFA82F45),
    green: Color(0xFF1F7A48),
    yellow: Color(0xFF7A6810),
    blue: Color(0xFF1A6FB0),
    magenta: Color(0xFF5B5C9C),
    cyan: Color(0xFF14756C),
    white: Color(0xFF5C736E),
    brightBlack: Color(0xFF2D403D),
    brightRed: Color(0xFFC44660),
    brightGreen: Color(0xFF2A9D5F),
    brightYellow: Color(0xFF967A1F),
    brightBlue: Color(0xFF2D8BC8),
    brightMagenta: Color(0xFF7373B5),
    brightCyan: Color(0xFF1AA298),
    brightWhite: Color(0xFFFCFEFD),
  );

  /// Dracula from iTerm2-Color-Schemes.
  static const dracula = TerminalThemeData(
    id: 'iterm2-dracula',
    name: 'Dracula',
    isDark: true,
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    cursor: Color(0xFFF8F8F2),
    selection: Color(0xFF44475A),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFFFA5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
  );

  /// Catppuccin Mocha from iTerm2-Color-Schemes.
  static const catppuccinMocha = TerminalThemeData(
    id: 'iterm2-catppuccin-mocha',
    name: 'Catppuccin Mocha',
    isDark: true,
    foreground: Color(0xFFCDD6F4),
    background: Color(0xFF1E1E2E),
    cursor: Color(0xFFF5E0DC),
    selection: Color(0xFF585B70),
    black: Color(0xFF45475A),
    red: Color(0xFFF38BA8),
    green: Color(0xFFA6E3A1),
    yellow: Color(0xFFF9E2AF),
    blue: Color(0xFF89B4FA),
    magenta: Color(0xFFF5C2E7),
    cyan: Color(0xFF94E2D5),
    white: Color(0xFFA6ADC8),
    brightBlack: Color(0xFF585B70),
    brightRed: Color(0xFFF37799),
    brightGreen: Color(0xFF89D88B),
    brightYellow: Color(0xFFEBD391),
    brightBlue: Color(0xFF74A8FC),
    brightMagenta: Color(0xFFF2AEDE),
    brightCyan: Color(0xFF6BD7CA),
    brightWhite: Color(0xFFBAC2DE),
  );

  /// TokyoNight Night from iTerm2-Color-Schemes.
  static const tokyoNightNight = TerminalThemeData(
    id: 'iterm2-tokyonight-night',
    name: 'TokyoNight Night',
    isDark: true,
    foreground: Color(0xFFC0CAF5),
    background: Color(0xFF1A1B26),
    cursor: Color(0xFFC0CAF5),
    selection: Color(0xFF283457),
    black: Color(0xFF15161E),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF414868),
    brightRed: Color(0xFFF7768E),
    brightGreen: Color(0xFF9ECE6A),
    brightYellow: Color(0xFFE0AF68),
    brightBlue: Color(0xFF7AA2F7),
    brightMagenta: Color(0xFFBB9AF7),
    brightCyan: Color(0xFF7DCFFF),
    brightWhite: Color(0xFFC0CAF5),
  );

  /// Gruvbox Dark from iTerm2-Color-Schemes.
  static const gruvboxDark = TerminalThemeData(
    id: 'iterm2-gruvbox-dark',
    name: 'Gruvbox Dark',
    isDark: true,
    foreground: Color(0xFFEBDBB2),
    background: Color(0xFF282828),
    cursor: Color(0xFFEBDBB2),
    selection: Color(0xFF665C54),
    black: Color(0xFF282828),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFFA89984),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFFFB4934),
    brightGreen: Color(0xFFB8BB26),
    brightYellow: Color(0xFFFABD2F),
    brightBlue: Color(0xFF83A598),
    brightMagenta: Color(0xFFD3869B),
    brightCyan: Color(0xFF8EC07C),
    brightWhite: Color(0xFFEBDBB2),
  );

  /// iTerm2 Solarized Dark from iTerm2-Color-Schemes.
  static const solarizedDark = TerminalThemeData(
    id: 'iterm2-iterm2-solarized-dark',
    name: 'iTerm2 Solarized Dark',
    isDark: true,
    foreground: Color(0xFF839496),
    background: Color(0xFF002B36),
    cursor: Color(0xFF839496),
    selection: Color(0xFF073642),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
  );

  /// Nord from iTerm2-Color-Schemes.
  static const nord = TerminalThemeData(
    id: 'iterm2-nord',
    name: 'Nord',
    isDark: true,
    foreground: Color(0xFFD8DEE9),
    background: Color(0xFF2E3440),
    cursor: Color(0xFFECEFF4),
    selection: Color(0xFFECEFF4),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFE5E9F0),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
  );

  /// Atom One Dark from iTerm2-Color-Schemes.
  static const atomOneDark = TerminalThemeData(
    id: 'iterm2-atom-one-dark',
    name: 'Atom One Dark',
    isDark: true,
    foreground: Color(0xFFABB2BF),
    background: Color(0xFF21252B),
    cursor: Color(0xFFABB2BF),
    selection: Color(0xFF323844),
    black: Color(0xFF21252B),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFABB2BF),
  );

  /// Monokai Pro from iTerm2-Color-Schemes.
  static const monokaiPro = TerminalThemeData(
    id: 'iterm2-monokai-pro',
    name: 'Monokai Pro',
    isDark: true,
    foreground: Color(0xFFFCFCFA),
    background: Color(0xFF2D2A2E),
    cursor: Color(0xFFC1C0C0),
    selection: Color(0xFF5B595C),
    black: Color(0xFF2D2A2E),
    red: Color(0xFFFF6188),
    green: Color(0xFFA9DC76),
    yellow: Color(0xFFFFD866),
    blue: Color(0xFFFC9867),
    magenta: Color(0xFFAB9DF2),
    cyan: Color(0xFF78DCE8),
    white: Color(0xFFFCFCFA),
    brightBlack: Color(0xFF727072),
    brightRed: Color(0xFFFF6188),
    brightGreen: Color(0xFFA9DC76),
    brightYellow: Color(0xFFFFD866),
    brightBlue: Color(0xFFFC9867),
    brightMagenta: Color(0xFFAB9DF2),
    brightCyan: Color(0xFF78DCE8),
    brightWhite: Color(0xFFFCFCFA),
  );

  /// Ayu from iTerm2-Color-Schemes.
  static const ayu = TerminalThemeData(
    id: 'iterm2-ayu',
    name: 'Ayu',
    isDark: true,
    foreground: Color(0xFFBFBDB6),
    background: Color(0xFF0B0E14),
    cursor: Color(0xFFE6B450),
    selection: Color(0xFF409FFF),
    black: Color(0xFF11151C),
    red: Color(0xFFEA6C73),
    green: Color(0xFF7FD962),
    yellow: Color(0xFFF9AF4F),
    blue: Color(0xFF53BDFA),
    magenta: Color(0xFFCDA1FA),
    cyan: Color(0xFF90E1C6),
    white: Color(0xFFC7C7C7),
    brightBlack: Color(0xFF686868),
    brightRed: Color(0xFFF07178),
    brightGreen: Color(0xFFAAD94C),
    brightYellow: Color(0xFFFFB454),
    brightBlue: Color(0xFF59C2FF),
    brightMagenta: Color(0xFFD2A6FF),
    brightCyan: Color(0xFF95E6CB),
    brightWhite: Color(0xFFFFFFFF),
  );

  /// Night Owl from iTerm2-Color-Schemes.
  static const nightOwl = TerminalThemeData(
    id: 'iterm2-night-owl',
    name: 'Night Owl',
    isDark: true,
    foreground: Color(0xFFD6DEEB),
    background: Color(0xFF011627),
    cursor: Color(0xFF7E57C2),
    selection: Color(0xFF5F7E97),
    black: Color(0xFF011627),
    red: Color(0xFFEF5350),
    green: Color(0xFF22DA6E),
    yellow: Color(0xFFADDB67),
    blue: Color(0xFF82AAFF),
    magenta: Color(0xFFC792EA),
    cyan: Color(0xFF21C7A8),
    white: Color(0xFFFFFFFF),
    brightBlack: Color(0xFF575656),
    brightRed: Color(0xFFEF5350),
    brightGreen: Color(0xFF22DA6E),
    brightYellow: Color(0xFFFFEB95),
    brightBlue: Color(0xFF82AAFF),
    brightMagenta: Color(0xFFC792EA),
    brightCyan: Color(0xFF7FDBCA),
    brightWhite: Color(0xFFFFFFFF),
  );

  /// GitHub Dark Default from iTerm2-Color-Schemes.
  static const githubDarkDefault = TerminalThemeData(
    id: 'iterm2-github-dark-default',
    name: 'GitHub Dark Default',
    isDark: true,
    foreground: Color(0xFFE6EDF3),
    background: Color(0xFF0D1117),
    cursor: Color(0xFF2F81F7),
    selection: Color(0xFFE6EDF3),
    black: Color(0xFF484F58),
    red: Color(0xFFFF7B72),
    green: Color(0xFF3FB950),
    yellow: Color(0xFFD29922),
    blue: Color(0xFF58A6FF),
    magenta: Color(0xFFBC8CFF),
    cyan: Color(0xFF39C5CF),
    white: Color(0xFFB1BAC4),
    brightBlack: Color(0xFF6E7681),
    brightRed: Color(0xFFFFA198),
    brightGreen: Color(0xFF56D364),
    brightYellow: Color(0xFFE3B341),
    brightBlue: Color(0xFF79C0FF),
    brightMagenta: Color(0xFFD2A8FF),
    brightCyan: Color(0xFF56D4DD),
    brightWhite: Color(0xFFFFFFFF),
  );

  /// GitHub Light Default from iTerm2-Color-Schemes.
  static const githubLightDefault = TerminalThemeData(
    id: 'iterm2-github-light-default',
    name: 'GitHub Light Default',
    isDark: false,
    foreground: Color(0xFF1F2328),
    background: Color(0xFFFFFFFF),
    cursor: Color(0xFF0969DA),
    selection: Color(0xFF1F2328),
    black: Color(0xFF24292F),
    red: Color(0xFFCF222E),
    green: Color(0xFF116329),
    yellow: Color(0xFF4D2D00),
    blue: Color(0xFF0969DA),
    magenta: Color(0xFF8250DF),
    cyan: Color(0xFF1B7C83),
    white: Color(0xFF6E7781),
    brightBlack: Color(0xFF57606A),
    brightRed: Color(0xFFA40E26),
    brightGreen: Color(0xFF1A7F37),
    brightYellow: Color(0xFF633C01),
    brightBlue: Color(0xFF218BFF),
    brightMagenta: Color(0xFFA475F9),
    brightCyan: Color(0xFF3192AA),
    brightWhite: Color(0xFF8C959F),
  );

  /// Catppuccin Latte from iTerm2-Color-Schemes.
  static const catppuccinLatte = TerminalThemeData(
    id: 'iterm2-catppuccin-latte',
    name: 'Catppuccin Latte',
    isDark: false,
    foreground: Color(0xFF4C4F69),
    background: Color(0xFFEFF1F5),
    cursor: Color(0xFFDC8A78),
    selection: Color(0xFFACB0BE),
    black: Color(0xFF5C5F77),
    red: Color(0xFFD20F39),
    green: Color(0xFF40A02B),
    yellow: Color(0xFFDF8E1D),
    blue: Color(0xFF1E66F5),
    magenta: Color(0xFFEA76CB),
    cyan: Color(0xFF179299),
    white: Color(0xFFACB0BE),
    brightBlack: Color(0xFF6C6F85),
    brightRed: Color(0xFFDE293E),
    brightGreen: Color(0xFF49AF3D),
    brightYellow: Color(0xFFEEA02D),
    brightBlue: Color(0xFF456EFF),
    brightMagenta: Color(0xFFFE85D8),
    brightCyan: Color(0xFF2D9FA8),
    brightWhite: Color(0xFFBCC0CC),
  );

  /// TokyoNight Day from iTerm2-Color-Schemes.
  static const tokyoNightDay = TerminalThemeData(
    id: 'iterm2-tokyonight-day',
    name: 'TokyoNight Day',
    isDark: false,
    foreground: Color(0xFF3760BF),
    background: Color(0xFFE1E2E7),
    cursor: Color(0xFF3760BF),
    selection: Color(0xFF99A7DF),
    black: Color(0xFFE9E9ED),
    red: Color(0xFFF52A65),
    green: Color(0xFF587539),
    yellow: Color(0xFF8C6C3E),
    blue: Color(0xFF2E7DE9),
    magenta: Color(0xFF9854F1),
    cyan: Color(0xFF007197),
    white: Color(0xFF6172B0),
    brightBlack: Color(0xFFA1A6C5),
    brightRed: Color(0xFFF52A65),
    brightGreen: Color(0xFF587539),
    brightYellow: Color(0xFF8C6C3E),
    brightBlue: Color(0xFF2E7DE9),
    brightMagenta: Color(0xFF9854F1),
    brightCyan: Color(0xFF007197),
    brightWhite: Color(0xFF3760BF),
  );

  /// Gruvbox Light from iTerm2-Color-Schemes.
  static const gruvboxLight = TerminalThemeData(
    id: 'iterm2-gruvbox-light',
    name: 'Gruvbox Light',
    isDark: false,
    foreground: Color(0xFF3C3836),
    background: Color(0xFFFBF1C7),
    cursor: Color(0xFF3C3836),
    selection: Color(0xFF3C3836),
    black: Color(0xFFFBF1C7),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFF7C6F64),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFF9D0006),
    brightGreen: Color(0xFF79740E),
    brightYellow: Color(0xFFB57614),
    brightBlue: Color(0xFF076678),
    brightMagenta: Color(0xFF8F3F71),
    brightCyan: Color(0xFF427B58),
    brightWhite: Color(0xFF3C3836),
  );

  /// iTerm2 Solarized Light from iTerm2-Color-Schemes.
  static const solarizedLight = TerminalThemeData(
    id: 'iterm2-iterm2-solarized-light',
    name: 'iTerm2 Solarized Light',
    isDark: false,
    foreground: Color(0xFF657B83),
    background: Color(0xFFFDF6E3),
    cursor: Color(0xFF657B83),
    selection: Color(0xFFEEE8D5),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
  );

  /// Nord Light from iTerm2-Color-Schemes.
  static const nordLight = TerminalThemeData(
    id: 'iterm2-nord-light',
    name: 'Nord Light',
    isDark: false,
    foreground: Color(0xFF414858),
    background: Color(0xFFE5E9F0),
    cursor: Color(0xFF88C0D0),
    selection: Color(0xFFD8DEE9),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFD8DEE9),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
  );

  /// Atom One Light from iTerm2-Color-Schemes.
  static const atomOneLight = TerminalThemeData(
    id: 'iterm2-atom-one-light',
    name: 'Atom One Light',
    isDark: false,
    foreground: Color(0xFF2A2C33),
    background: Color(0xFFF9F9F9),
    cursor: Color(0xFFBBBBBB),
    selection: Color(0xFFEDEDED),
    black: Color(0xFF000000),
    red: Color(0xFFDE3E35),
    green: Color(0xFF3F953A),
    yellow: Color(0xFFD2B67C),
    blue: Color(0xFF2F5AF3),
    magenta: Color(0xFF950095),
    cyan: Color(0xFF3F953A),
    white: Color(0xFFBBBBBB),
    brightBlack: Color(0xFF000000),
    brightRed: Color(0xFFDE3E35),
    brightGreen: Color(0xFF3F953A),
    brightYellow: Color(0xFFD2B67C),
    brightBlue: Color(0xFF2F5AF3),
    brightMagenta: Color(0xFFA00095),
    brightCyan: Color(0xFF3F953A),
    brightWhite: Color(0xFFFFFFFF),
  );

  /// Ayu Light from iTerm2-Color-Schemes.
  static const ayuLight = TerminalThemeData(
    id: 'iterm2-ayu-light',
    name: 'Ayu Light',
    isDark: false,
    foreground: Color(0xFF5C6166),
    background: Color(0xFFF8F9FA),
    cursor: Color(0xFFFFAA33),
    selection: Color(0xFF035BD6),
    black: Color(0xFF000000),
    red: Color(0xFFEA6C6D),
    green: Color(0xFF6CBF43),
    yellow: Color(0xFFECA944),
    blue: Color(0xFF3199E1),
    magenta: Color(0xFF9E75C7),
    cyan: Color(0xFF46BA94),
    white: Color(0xFFBABABA),
    brightBlack: Color(0xFF686868),
    brightRed: Color(0xFFF07171),
    brightGreen: Color(0xFF86B300),
    brightYellow: Color(0xFFF2AE49),
    brightBlue: Color(0xFF399EE6),
    brightMagenta: Color(0xFFA37ACC),
    brightCyan: Color(0xFF4CBF99),
    brightWhite: Color(0xFFD1D1D1),
  );

  /// Night Owlish Light from iTerm2-Color-Schemes.
  static const nightOwlishLight = TerminalThemeData(
    id: 'iterm2-night-owlish-light',
    name: 'Night Owlish Light',
    isDark: false,
    foreground: Color(0xFF403F53),
    background: Color(0xFFFFFFFF),
    cursor: Color(0xFF403F53),
    selection: Color(0xFFF2F2F2),
    black: Color(0xFF011627),
    red: Color(0xFFD3423E),
    green: Color(0xFF2AA298),
    yellow: Color(0xFFDAAA01),
    blue: Color(0xFF4876D6),
    magenta: Color(0xFF403F53),
    cyan: Color(0xFF08916A),
    white: Color(0xFF7A8181),
    brightBlack: Color(0xFF7A8181),
    brightRed: Color(0xFFF76E6E),
    brightGreen: Color(0xFF49D0C5),
    brightYellow: Color(0xFFDAC26B),
    brightBlue: Color(0xFF5CA7E4),
    brightMagenta: Color(0xFF697098),
    brightCyan: Color(0xFF00C990),
    brightWhite: Color(0xFF989FB1),
  );

  /// Bluloco Light from iTerm2-Color-Schemes.
  static const blulocoLight = TerminalThemeData(
    id: 'iterm2-bluloco-light',
    name: 'Bluloco Light',
    isDark: false,
    foreground: Color(0xFF373A41),
    background: Color(0xFFF9F9F9),
    cursor: Color(0xFFF32759),
    selection: Color(0xFFDAF0FF),
    black: Color(0xFF373A41),
    red: Color(0xFFD52753),
    green: Color(0xFF23974A),
    yellow: Color(0xFFDF631C),
    blue: Color(0xFF275FE4),
    magenta: Color(0xFF823FF1),
    cyan: Color(0xFF27618D),
    white: Color(0xFFBABBC2),
    brightBlack: Color(0xFF676A77),
    brightRed: Color(0xFFFF6480),
    brightGreen: Color(0xFF3CBC66),
    brightYellow: Color(0xFFC5A332),
    brightBlue: Color(0xFF0099E1),
    brightMagenta: Color(0xFFCE33C0),
    brightCyan: Color(0xFF6D93BB),
    brightWhite: Color(0xFFD3D3D3),
  );
}
