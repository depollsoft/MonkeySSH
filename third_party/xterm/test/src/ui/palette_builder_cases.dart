import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/xterm.dart';

void registerPaletteBuilderTests() {
  test('ANSI index 15 uses the theme bright-white color', () {
    final theme = TerminalThemes.defaultTheme;

    expect(PaletteBuilder(theme).paletteColor(15), theme.brightWhite);
    expect(PaletteBuilder(theme).paletteColor(15), isNot(theme.white));
  });
}
