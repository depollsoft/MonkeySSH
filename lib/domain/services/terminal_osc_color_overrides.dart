import 'package:flutter/material.dart';

import '../models/terminal_theme.dart';

/// Result of applying a terminal color mutation OSC command.
typedef TerminalOscColorMutation = ({bool handled, bool changed});

/// Per-session xterm color overrides set by remote OSC commands.
///
/// The user-selected theme remains the base. OSC 104/110/111/112/117 restore
/// individual roles (or the full ANSI palette) to that base without changing
/// saved theme settings.
class TerminalOscColorOverrides {
  final Map<int, Color> _ansi = <int, Color>{};
  Color? _foreground;
  Color? _background;
  Color? _cursor;
  Color? _selection;

  /// Whether any remote color override is active.
  bool get isNotEmpty =>
      _ansi.isNotEmpty ||
      _foreground != null ||
      _background != null ||
      _cursor != null ||
      _selection != null;

  /// Applies a supported OSC setter/reset command.
  TerminalOscColorMutation handle(String code, List<String> args) {
    switch (code) {
      case '4':
        var handled = false;
        var changed = false;
        for (var index = 0; index + 1 < args.length; index += 2) {
          final paletteIndex = int.tryParse(args[index].trim());
          final color = parseTerminalOscColor(args[index + 1]);
          if (paletteIndex == null ||
              paletteIndex < 0 ||
              paletteIndex > 255 ||
              color == null) {
            continue;
          }
          handled = true;
          if (_ansi[paletteIndex] != color) {
            _ansi[paletteIndex] = color;
            changed = true;
          }
        }
        return (handled: handled, changed: changed);
      case '10':
      case '11':
      case '12':
      case '17':
        return _setDynamicColors(int.parse(code), args);
      case '104':
        if (args.isEmpty || args.every((arg) => arg.trim().isEmpty)) {
          final changed = _ansi.isNotEmpty;
          _ansi.clear();
          return (handled: true, changed: changed);
        }
        var changed = false;
        var handled = false;
        for (final arg in args) {
          final paletteIndex = int.tryParse(arg.trim());
          if (paletteIndex == null || paletteIndex < 0 || paletteIndex > 255) {
            continue;
          }
          handled = true;
          changed = _ansi.remove(paletteIndex) != null || changed;
        }
        return (handled: handled, changed: changed);
      case '110':
        return _resetDynamicColor(_foreground, () => _foreground = null);
      case '111':
        return _resetDynamicColor(_background, () => _background = null);
      case '112':
        return _resetDynamicColor(_cursor, () => _cursor = null);
      case '117':
        return _resetDynamicColor(_selection, () => _selection = null);
      default:
        return (handled: false, changed: false);
    }
  }

  /// Clears all overrides, returning whether the effective theme can change.
  bool clear() {
    final changed = isNotEmpty;
    _ansi.clear();
    _foreground = null;
    _background = null;
    _cursor = null;
    _selection = null;
    return changed;
  }

  /// Applies active overrides to [base] without mutating it.
  TerminalThemeData applyTo(TerminalThemeData base) {
    final ansiColors = base.ansiColors;
    final extendedPalette = <int, Color>{...base.paletteOverrides};
    for (final entry in _ansi.entries) {
      if (entry.key < ansiColors.length) {
        ansiColors[entry.key] = entry.value;
      } else {
        extendedPalette[entry.key] = entry.value;
      }
    }
    return base
        .copyWithAnsiColors(ansiColors)
        .copyWith(
          foreground: _foreground,
          background: _background,
          cursor: _cursor,
          selection: _selection,
          paletteOverrides: Map<int, Color>.unmodifiable(extendedPalette),
        );
  }

  TerminalOscColorMutation _setDynamicColors(int firstRole, List<String> args) {
    var handled = false;
    var changed = false;
    for (var index = 0; index < args.length; index += 1) {
      final color = parseTerminalOscColor(args[index]);
      if (color == null) continue;
      switch (firstRole + index) {
        case 10:
          handled = true;
          if (_foreground != color) {
            _foreground = color;
            changed = true;
          }
        case 11:
          handled = true;
          if (_background != color) {
            _background = color;
            changed = true;
          }
        case 12:
          handled = true;
          if (_cursor != color) {
            _cursor = color;
            changed = true;
          }
        case 17:
          handled = true;
          if (_selection != color) {
            _selection = color;
            changed = true;
          }
      }
    }
    return (handled: handled, changed: changed);
  }

  TerminalOscColorMutation _resetDynamicColor(
    Color? previous,
    void Function() reset,
  ) {
    final changed = previous != null;
    if (changed) reset();
    return (handled: true, changed: changed);
  }
}

/// Parses xterm `#RGB`/`#RRGGBB` and `rgb:r/g/b` color specifications.
Color? parseTerminalOscColor(String value) {
  final candidate = value.trim();
  if (candidate == '?' || candidate.isEmpty) return null;
  if (candidate.startsWith('#')) {
    final hex = candidate.substring(1);
    if (hex.length == 3 && RegExp(r'^[0-9A-Fa-f]{3}$').hasMatch(hex)) {
      return Color(
        0xFF000000 |
            (int.parse(hex[0], radix: 16) * 17 << 16) |
            (int.parse(hex[1], radix: 16) * 17 << 8) |
            (int.parse(hex[2], radix: 16) * 17),
      );
    }
    if (hex.length == 6 && RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hex)) {
      return Color(0xFF000000 | int.parse(hex, radix: 16));
    }
    return null;
  }
  if (!candidate.startsWith('rgb:')) return null;
  final components = candidate.substring(4).split('/');
  if (components.length != 3) return null;
  final rgb = <int>[];
  for (final component in components) {
    if (component.isEmpty ||
        component.length > 4 ||
        !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(component)) {
      return null;
    }
    final raw = int.parse(component, radix: 16);
    final max = (1 << (component.length * 4)) - 1;
    rgb.add((raw * 255 / max).round());
  }
  return Color.fromARGB(0xFF, rgb[0], rgb[1], rgb[2]);
}
