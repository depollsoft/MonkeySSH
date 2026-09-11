// ignore_for_file: implementation_imports, public_member_api_docs

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/xterm.dart';

({Color background, int sampledCells}) composerSurfaceForToken(
  Terminal terminal,
  TerminalThemeData theme,
  String token,
) {
  final xtermTheme = theme.toXtermTheme();
  final palette = PaletteBuilder(xtermTheme).build();
  final cell = CellData.empty();

  for (var row = 0; row < terminal.buffer.lines.length; row += 1) {
    final line = terminal.buffer.lines[row];
    final text = line.getText(0, terminal.buffer.viewWidth);
    final startColumn = text.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    line.getCellData(startColumn, cell);
    final tokenSurfaceColor = _effectiveBackgroundCellColor(cell);
    final background = effectiveCellColors(
      cell,
      xtermTheme,
      palette,
    ).background;
    var sampledCells = 0;

    for (var column = 0; column < terminal.buffer.viewWidth; column += 1) {
      line.getCellData(column, cell);
      if (_effectiveBackgroundCellColor(cell) == tokenSurfaceColor) {
        sampledCells += 1;
      }
    }

    return (background: background, sampledCells: sampledCells);
  }

  fail('Could not find token "$token" in terminal buffer.');
}

int _effectiveBackgroundCellColor(CellData cell) =>
    (cell.flags & CellFlags.inverse) == 0 ? cell.background : cell.foreground;

({Color foreground, Color background}) effectiveCellColors(
  CellData cell,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  var foreground = (cell.flags & CellFlags.inverse) == 0
      ? _resolveForegroundColor(cell.foreground, xtermTheme, palette)
      : _resolveBackgroundColor(cell.background, xtermTheme, palette);
  final background = (cell.flags & CellFlags.inverse) == 0
      ? _resolveBackgroundColor(cell.background, xtermTheme, palette)
      : _resolveForegroundColor(cell.foreground, xtermTheme, palette);

  if ((cell.flags & CellFlags.faint) != 0) {
    foreground = resolveMonkeyTerminalFaintForegroundColor(
      foreground: foreground,
      background: background,
    );
  }
  return (foreground: foreground, background: background);
}

Color _resolveForegroundColor(
  int cellColor,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  final colorType = cellColor & CellColor.typeMask;
  final colorValue = cellColor & CellColor.valueMask;
  return switch (colorType) {
    CellColor.normal => xtermTheme.foreground,
    CellColor.named || CellColor.palette => palette[colorValue],
    _ => Color.fromARGB(
      0xFF,
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
    ),
  };
}

Color _resolveBackgroundColor(
  int cellColor,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  final colorType = cellColor & CellColor.typeMask;
  final colorValue = cellColor & CellColor.valueMask;
  return switch (colorType) {
    CellColor.normal => xtermTheme.background,
    CellColor.named || CellColor.palette => palette[colorValue],
    _ => Color.fromARGB(
      0xFF,
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
    ),
  };
}

double contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}
