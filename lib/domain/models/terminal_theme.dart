import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Builds an xterm/tmux theme-mode report for the current terminal theme.
///
/// tmux uses this private DSR response to notice when the outer terminal
/// switches between dark and light themes. After receiving it, tmux re-queries
/// OSC 10/11 so panes that ask tmux for default colors don't keep stale values.
String buildTerminalThemeModeReport({required bool isDark}) =>
    isDark ? '\x1b[?997;1n' : '\x1b[?997;2n';

/// Builds safe unsolicited color reports used to refresh tmux after a theme
/// change.
///
/// tmux consumes OSC 10/11 and OSC 4 replies to refresh its default fg/bg and
/// ANSI palette caches. Other color-query replies (for example OSC 12/17/19)
/// are only sent when explicitly queried, because tmux does not consume them as
/// cache updates and unsolicited replies can reach the foreground pane.
String buildTerminalThemeRefreshReports(TerminalThemeData theme) =>
    buildTerminalThemeRefreshReportList(theme).join();

/// Builds terminal theme hints sent to MonkeyMux attach/control channels.
String buildTerminalThemeHintReports(TerminalThemeData theme) =>
    buildTerminalThemeModeReport(isDark: theme.isDark) +
    buildTerminalThemeRefreshReports(theme);

/// Builds safe unsolicited color reports as individual escape sequences.
///
/// These entries are useful for tests and call sites that need to inspect or
/// schedule individual reports. tmux cache refreshes should use the batched
/// [buildTerminalThemeRefreshReports] payload so the palette update is applied
/// atomically for a pane/client pair.
List<String> buildTerminalThemeRefreshReportList(TerminalThemeData theme) => [
  buildTerminalThemeOscResponse(theme: theme, code: '10', args: const ['?']),
  buildTerminalThemeOscResponse(theme: theme, code: '11', args: const ['?']),
  for (var index = 0; index < 16; index += 1)
    buildTerminalThemeOscResponse(
      theme: theme,
      code: '4',
      args: ['$index', '?'],
    ),
].whereType<String>().toList(growable: false);

/// Builds unsolicited default foreground/background reports.
///
/// These are safe to send to foreground TUIs that have just requested a theme
/// refresh. Unlike OSC 4 palette reports, OSC 10/11 responses are accepted by
/// Codex and OpenTUI without leaking palette fragments into the prompt.
String buildTerminalThemeDefaultColorReports(TerminalThemeData theme) => [
  buildTerminalThemeOscResponse(theme: theme, code: '10', args: const ['?']),
  buildTerminalThemeOscResponse(theme: theme, code: '11', args: const ['?']),
].whereType<String>().join();

/// Builds an xterm-compatible response for terminal theme OSC color queries.
///
/// Modern TUIs use these queries (notably `OSC 11;?`) to detect whether the
/// terminal background is light or dark. Returning `null` means the OSC
/// sequence is not a color query and should be handled by other OSC handlers.
String? buildTerminalThemeOscResponse({
  required TerminalThemeData theme,
  required String code,
  required List<String> args,
}) {
  switch (code) {
    case '4':
      return _buildAnsiPaletteOscResponse(theme, args);
    case '10':
    case '11':
    case '12':
    case '17':
    case '19':
      return _buildDynamicColorOscResponse(theme, int.parse(code), args);
    default:
      return null;
  }
}

String? _buildDynamicColorOscResponse(
  TerminalThemeData theme,
  int firstRole,
  List<String> args,
) {
  final responses = <String>[];
  for (var index = 0; index < args.length; index += 1) {
    if (args[index].trim() != '?') continue;
    final role = firstRole + index;
    final color = switch (role) {
      10 => theme.foreground,
      11 => theme.background,
      12 => theme.cursor,
      17 => theme.readableSelection,
      19 => theme.foreground,
      _ => null,
    };
    if (color != null) {
      responses.add(_formatOscColorResponse('$role', color));
    }
  }
  return responses.isEmpty ? null : responses.join();
}

String? _buildAnsiPaletteOscResponse(
  TerminalThemeData theme,
  List<String> args,
) {
  final responses = <String>[];
  for (var index = 0; index + 1 < args.length; index += 2) {
    final colorIndex = int.tryParse(args[index].trim());
    if (colorIndex == null || args[index + 1].trim() != '?') {
      continue;
    }
    final color = terminalThemePaletteColor(theme, colorIndex);
    if (color == null) {
      continue;
    }
    responses.add(
      _formatOscColorResponse('4', color, paletteIndex: colorIndex),
    );
  }
  if (responses.isEmpty) {
    return null;
  }
  return responses.join();
}

/// Resolves an xterm palette color for [theme].
///
/// Indexes 0-15 are theme-controlled ANSI colors. Indexes 16-255 use the
/// fixed xterm 256-color cube and grayscale ramp.
Color? terminalThemePaletteColor(TerminalThemeData theme, int index) {
  final override = theme.paletteOverrides[index];
  if (override != null) return override;

  switch (index) {
    case 0:
      return theme.black;
    case 1:
      return theme.red;
    case 2:
      return theme.green;
    case 3:
      return theme.yellow;
    case 4:
      return theme.blue;
    case 5:
      return theme.magenta;
    case 6:
      return theme.cyan;
    case 7:
      return theme.white;
    case 8:
      return theme.brightBlack;
    case 9:
      return theme.brightRed;
    case 10:
      return theme.brightGreen;
    case 11:
      return theme.brightYellow;
    case 12:
      return theme.brightBlue;
    case 13:
      return theme.brightMagenta;
    case 14:
      return theme.brightCyan;
    case 15:
      return theme.brightWhite;
  }

  if (index >= 16 && index < 232) {
    final colorIndex = index - 16;
    final red = _xtermColorCubeComponent(colorIndex ~/ 36);
    final green = _xtermColorCubeComponent((colorIndex ~/ 6) % 6);
    final blue = _xtermColorCubeComponent(colorIndex % 6);
    return Color.fromARGB(0xFF, red, green, blue);
  }

  if (index >= 232 && index <= 255) {
    final level = 8 + ((index - 232) * 10);
    return Color.fromARGB(0xFF, level, level, level);
  }

  return null;
}

int _xtermColorCubeComponent(int value) => value == 0 ? 0 : 55 + (value * 40);

String _formatOscColorResponse(String code, Color color, {int? paletteIndex}) {
  final colorSpec = _formatOscRgbColor(color);
  final payload = paletteIndex == null
      ? '$code;$colorSpec'
      : '$code;$paletteIndex;$colorSpec';
  return '\x1b]$payload\x1b\\';
}

/// Formats [color] as a tmux-compatible six-digit RGB hex color.
String formatTerminalThemeRgbHex(Color color) {
  final value = color.toARGB32();
  final red = (value >> 16) & 0xFF;
  final green = (value >> 8) & 0xFF;
  final blue = value & 0xFF;
  return '#${_formatTwoDigitHex(red)}'
      '${_formatTwoDigitHex(green)}'
      '${_formatTwoDigitHex(blue)}';
}

String _formatOscRgbColor(Color color) {
  final value = color.toARGB32();
  final red = (value >> 16) & 0xFF;
  final green = (value >> 8) & 0xFF;
  final blue = value & 0xFF;
  return 'rgb:${_formatOscRgbComponent(red)}/'
      '${_formatOscRgbComponent(green)}/'
      '${_formatOscRgbComponent(blue)}';
}

String _formatOscRgbComponent(int value) {
  final hex = _formatTwoDigitHex(value);
  return '$hex$hex';
}

String _formatTwoDigitHex(int value) => value.toRadixString(16).padLeft(2, '0');

/// Returns whether two terminal themes resolve to the same rendered colors.
bool terminalThemesMatchForColors(
  TerminalThemeData previous,
  TerminalThemeData next,
) =>
    previous.id == next.id &&
    previous.isDark == next.isDark &&
    previous.foreground == next.foreground &&
    previous.background == next.background &&
    previous.cursor == next.cursor &&
    previous.selection == next.selection &&
    previous.black == next.black &&
    previous.red == next.red &&
    previous.green == next.green &&
    previous.yellow == next.yellow &&
    previous.blue == next.blue &&
    previous.magenta == next.magenta &&
    previous.cyan == next.cyan &&
    previous.white == next.white &&
    previous.brightBlack == next.brightBlack &&
    previous.brightRed == next.brightRed &&
    previous.brightGreen == next.brightGreen &&
    previous.brightYellow == next.brightYellow &&
    previous.brightBlue == next.brightBlue &&
    previous.brightMagenta == next.brightMagenta &&
    previous.brightCyan == next.brightCyan &&
    previous.brightWhite == next.brightWhite &&
    mapEquals(previous.paletteOverrides, next.paletteOverrides) &&
    previous.searchHitBackground == next.searchHitBackground &&
    previous.searchHitBackgroundCurrent == next.searchHitBackgroundCurrent &&
    previous.searchHitForeground == next.searchHitForeground;

const _minimumSelectionBackgroundContrast = 1.04;
const _minimumSelectionTextContrast = 3.5;
const _selectionAlphaCandidates = <int>[
  0x66,
  0x5C,
  0x52,
  0x48,
  0x40,
  0x36,
  0x2E,
  0x26,
  0x1E,
];

const _terminalThemeRequiredColorKeys = <String>[
  'foreground',
  'background',
  'cursor',
  'selection',
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'brightBlack',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
];

const _terminalThemeOptionalColorKeys = <String>[
  'searchHitBackground',
  'searchHitBackgroundCurrent',
  'searchHitForeground',
];

/// Data model for a terminal color theme.
///
/// Contains all 16 ANSI colors plus special colors for cursor, selection,
/// foreground, and background. Can be converted to xterm's [TerminalTheme].
@immutable
class TerminalThemeData {
  /// Creates a new [TerminalThemeData].
  const TerminalThemeData({
    required this.id,
    required this.name,
    required this.isDark,
    required this.foreground,
    required this.background,
    required this.cursor,
    required this.selection,
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
    this.isCustom = false,
    this.searchHitBackground,
    this.searchHitBackgroundCurrent,
    this.searchHitForeground,
    this.paletteOverrides = const <int, Color>{},
  });

  /// Creates a theme from a JSON map.
  factory TerminalThemeData.fromJson(Map<String, dynamic> json) =>
      TerminalThemeData(
        id: json['id'] as String,
        name: json['name'] as String,
        isDark: json['isDark'] as bool,
        isCustom: json['isCustom'] as bool? ?? true,
        foreground: Color(json['foreground'] as int),
        background: Color(json['background'] as int),
        cursor: Color(json['cursor'] as int),
        selection: Color(json['selection'] as int),
        black: Color(json['black'] as int),
        red: Color(json['red'] as int),
        green: Color(json['green'] as int),
        yellow: Color(json['yellow'] as int),
        blue: Color(json['blue'] as int),
        magenta: Color(json['magenta'] as int),
        cyan: Color(json['cyan'] as int),
        white: Color(json['white'] as int),
        brightBlack: Color(json['brightBlack'] as int),
        brightRed: Color(json['brightRed'] as int),
        brightGreen: Color(json['brightGreen'] as int),
        brightYellow: Color(json['brightYellow'] as int),
        brightBlue: Color(json['brightBlue'] as int),
        brightMagenta: Color(json['brightMagenta'] as int),
        brightCyan: Color(json['brightCyan'] as int),
        brightWhite: Color(json['brightWhite'] as int),
        searchHitBackground: json['searchHitBackground'] != null
            ? Color(json['searchHitBackground'] as int)
            : null,
        searchHitBackgroundCurrent: json['searchHitBackgroundCurrent'] != null
            ? Color(json['searchHitBackgroundCurrent'] as int)
            : null,
        searchHitForeground: json['searchHitForeground'] != null
            ? Color(json['searchHitForeground'] as int)
            : null,
      );

  /// Safely creates a theme from decoded JSON, or null when invalid.
  static TerminalThemeData? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }

    final id = json['id'];
    if (id is! String || id.isEmpty || json['name'] is! String) {
      return null;
    }
    if (json['isDark'] is! bool) {
      return null;
    }
    final isCustom = json['isCustom'];
    if (isCustom != null && isCustom is! bool) {
      return null;
    }

    for (final key in _terminalThemeRequiredColorKeys) {
      if (json[key] is! int) {
        return null;
      }
    }
    for (final key in _terminalThemeOptionalColorKeys) {
      final value = json[key];
      if (value != null && value is! int) {
        return null;
      }
    }

    return TerminalThemeData.fromJson(Map<String, dynamic>.from(json));
  }

  /// Unique identifier for the theme.
  final String id;

  /// Display name of the theme.
  final String name;

  /// Whether this theme is designed for dark backgrounds.
  final bool isDark;

  /// Whether this is a user-created custom theme.
  final bool isCustom;

  /// Main text color.
  final Color foreground;

  /// Terminal background color.
  final Color background;

  /// Cursor color.
  final Color cursor;

  /// Selection highlight color.
  final Color selection;

  /// ANSI color 0 (black).
  final Color black;

  /// ANSI color 1 (red).
  final Color red;

  /// ANSI color 2 (green).
  final Color green;

  /// ANSI color 3 (yellow).
  final Color yellow;

  /// ANSI color 4 (blue).
  final Color blue;

  /// ANSI color 5 (magenta).
  final Color magenta;

  /// ANSI color 6 (cyan).
  final Color cyan;

  /// ANSI color 7 (white).
  final Color white;

  /// ANSI color 8 (bright black).
  final Color brightBlack;

  /// ANSI color 9 (bright red).
  final Color brightRed;

  /// ANSI color 10 (bright green).
  final Color brightGreen;

  /// ANSI color 11 (bright yellow).
  final Color brightYellow;

  /// ANSI color 12 (bright blue).
  final Color brightBlue;

  /// ANSI color 13 (bright magenta).
  final Color brightMagenta;

  /// ANSI color 14 (bright cyan).
  final Color brightCyan;

  /// ANSI color 15 (bright white).
  final Color brightWhite;

  /// Runtime-only overrides for arbitrary xterm 256-color palette indexes.
  ///
  /// These are intentionally excluded from persisted custom-theme JSON.
  final Map<int, Color> paletteOverrides;

  /// Background color for search hits.
  final Color? searchHitBackground;

  /// Background color for current search hit.
  final Color? searchHitBackgroundCurrent;

  /// Foreground color for search hits.
  final Color? searchHitForeground;

  /// Selection highlight adjusted for this app's single selected-text color.
  Color get readableSelection => normalizeTerminalSelectionColor(
    foreground: foreground,
    background: background,
    selection: selection,
  );

  /// Converts this theme data to xterm's [TerminalTheme].
  TerminalTheme toXtermTheme() => TerminalTheme(
    cursor: cursor,
    selection: readableSelection,
    foreground: foreground,
    background: background,
    black: black,
    red: red,
    green: green,
    yellow: yellow,
    blue: blue,
    magenta: magenta,
    cyan: cyan,
    white: white,
    brightBlack: brightBlack,
    brightRed: brightRed,
    brightGreen: brightGreen,
    brightYellow: brightYellow,
    brightBlue: brightBlue,
    brightMagenta: brightMagenta,
    brightCyan: brightCyan,
    brightWhite: brightWhite,
    paletteOverrides: paletteOverrides,
    searchHitBackground: searchHitBackground ?? const Color(0xFFFFDF5D),
    searchHitBackgroundCurrent:
        searchHitBackgroundCurrent ?? const Color(0xFFFF9632),
    searchHitForeground: searchHitForeground ?? const Color(0xFF000000),
  );

  /// Creates a copy of this theme with the given fields replaced.
  TerminalThemeData copyWith({
    String? id,
    String? name,
    bool? isDark,
    bool? isCustom,
    Color? foreground,
    Color? background,
    Color? cursor,
    Color? selection,
    Color? black,
    Color? red,
    Color? green,
    Color? yellow,
    Color? blue,
    Color? magenta,
    Color? cyan,
    Color? white,
    Color? brightBlack,
    Color? brightRed,
    Color? brightGreen,
    Color? brightYellow,
    Color? brightBlue,
    Color? brightMagenta,
    Color? brightCyan,
    Color? brightWhite,
    Map<int, Color>? paletteOverrides,
  }) => TerminalThemeData(
    id: id ?? this.id,
    name: name ?? this.name,
    isDark: isDark ?? this.isDark,
    isCustom: isCustom ?? this.isCustom,
    foreground: foreground ?? this.foreground,
    background: background ?? this.background,
    cursor: cursor ?? this.cursor,
    selection: selection ?? this.selection,
    black: black ?? this.black,
    red: red ?? this.red,
    green: green ?? this.green,
    yellow: yellow ?? this.yellow,
    blue: blue ?? this.blue,
    magenta: magenta ?? this.magenta,
    cyan: cyan ?? this.cyan,
    white: white ?? this.white,
    brightBlack: brightBlack ?? this.brightBlack,
    brightRed: brightRed ?? this.brightRed,
    brightGreen: brightGreen ?? this.brightGreen,
    brightYellow: brightYellow ?? this.brightYellow,
    brightBlue: brightBlue ?? this.brightBlue,
    brightMagenta: brightMagenta ?? this.brightMagenta,
    brightCyan: brightCyan ?? this.brightCyan,
    brightWhite: brightWhite ?? this.brightWhite,
    paletteOverrides: paletteOverrides ?? this.paletteOverrides,
    searchHitBackground: searchHitBackground,
    searchHitBackgroundCurrent: searchHitBackgroundCurrent,
    searchHitForeground: searchHitForeground,
  );

  /// Converts this theme to a JSON map for storage.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isDark': isDark,
    'isCustom': isCustom,
    'foreground': foreground.toARGB32(),
    'background': background.toARGB32(),
    'cursor': cursor.toARGB32(),
    'selection': selection.toARGB32(),
    'black': black.toARGB32(),
    'red': red.toARGB32(),
    'green': green.toARGB32(),
    'yellow': yellow.toARGB32(),
    'blue': blue.toARGB32(),
    'magenta': magenta.toARGB32(),
    'cyan': cyan.toARGB32(),
    'white': white.toARGB32(),
    'brightBlack': brightBlack.toARGB32(),
    'brightRed': brightRed.toARGB32(),
    'brightGreen': brightGreen.toARGB32(),
    'brightYellow': brightYellow.toARGB32(),
    'brightBlue': brightBlue.toARGB32(),
    'brightMagenta': brightMagenta.toARGB32(),
    'brightCyan': brightCyan.toARGB32(),
    'brightWhite': brightWhite.toARGB32(),
    if (searchHitBackground != null)
      'searchHitBackground': searchHitBackground!.toARGB32(),
    if (searchHitBackgroundCurrent != null)
      'searchHitBackgroundCurrent': searchHitBackgroundCurrent!.toARGB32(),
    if (searchHitForeground != null)
      'searchHitForeground': searchHitForeground!.toARGB32(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalThemeData &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Adjusts an iTerm-style selection color for readable selected text.
Color normalizeTerminalSelectionColor({
  required Color foreground,
  required Color background,
  required Color selection,
}) {
  if (_isUsableSelection(
    foreground: foreground,
    background: background,
    selection: selection,
  )) {
    return selection;
  }

  for (final alpha in _selectionAlphaCandidates) {
    final candidate = selection.withAlpha(alpha);
    if (_isUsableSelection(
      foreground: foreground,
      background: background,
      selection: candidate,
    )) {
      return candidate;
    }
  }

  for (final alpha in _selectionAlphaCandidates) {
    final candidate = foreground.withAlpha(alpha);
    if (_isUsableSelection(
      foreground: foreground,
      background: background,
      selection: candidate,
    )) {
      return candidate;
    }
  }

  return selection.withAlpha(_selectionAlphaCandidates.last);
}

bool _isUsableSelection({
  required Color foreground,
  required Color background,
  required Color selection,
}) {
  final compositedSelection = Color.alphaBlend(selection, background);
  return _contrastRatio(foreground, compositedSelection) >=
          _minimumSelectionTextContrast &&
      _contrastRatio(compositedSelection, background) >=
          _minimumSelectionBackgroundContrast;
}

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = luminanceA > luminanceB ? luminanceA : luminanceB;
  final darkest = luminanceA > luminanceB ? luminanceB : luminanceA;
  return (brightest + 0.05) / (darkest + 0.05);
}
