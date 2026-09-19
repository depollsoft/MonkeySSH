import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/terminal_osc_color_overrides.dart';

void registerTerminalOscColorOverridesTests() {
  group('terminal_osc_color_overrides', () {
    test('parses xterm color formats', () {
      expect(parseTerminalOscColor('#1aF'), const Color(0xFF11AAFF));
      expect(parseTerminalOscColor('#123456'), const Color(0xFF123456));
      expect(
        parseTerminalOscColor('rgb:ffff/8000/0000'),
        const Color(0xFFFF8000),
      );
      expect(parseTerminalOscColor('?'), isNull);
      expect(parseTerminalOscColor('not-a-color'), isNull);
    });

    test('sets and selectively resets ANSI palette colors', () {
      final overrides = TerminalOscColorOverrides();
      expect(overrides.handle('4', const ['1', '#123456', '2', 'rgb:0/f/0']), (
        handled: true,
        changed: true,
      ));
      var effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.red, const Color(0xFF123456));
      expect(effective.green, const Color(0xFF00FF00));

      expect(overrides.handle('104', const ['1']), (
        handled: true,
        changed: true,
      ));
      effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.red, TerminalThemes.dracula.red);
      expect(effective.green, const Color(0xFF00FF00));

      overrides.handle('104', const []);
      expect(overrides.isNotEmpty, isFalse);
    });

    test('sets and resets dynamic terminal colors', () {
      final overrides = TerminalOscColorOverrides();
      // Consecutive setter groups are intentionally separated by assertions.
      // ignore: cascade_invocations
      overrides
        ..handle('10', const ['#fedcba'])
        ..handle('11', const ['#102030'])
        ..handle('12', const ['#abcdef'])
        ..handle('17', const ['#334455']);
      var effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.foreground, const Color(0xFFFEDCBA));
      expect(effective.background, const Color(0xFF102030));
      expect(effective.cursor, const Color(0xFFABCDEF));
      expect(effective.selection, const Color(0xFF334455));

      overrides
        ..handle('110', const [])
        ..handle('111', const [])
        ..handle('112', const [])
        ..handle('117', const []);
      effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.foreground, TerminalThemes.dracula.foreground);
      expect(effective.background, TerminalThemes.dracula.background);
      expect(effective.cursor, TerminalThemes.dracula.cursor);
      expect(effective.selection, TerminalThemes.dracula.selection);
    });

    test('sets and queries consecutive dynamic color roles', () {
      final overrides = TerminalOscColorOverrides();
      expect(overrides.handle('10', const ['#112233', '#445566', '#778899']), (
        handled: true,
        changed: true,
      ));
      final effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.foreground, const Color(0xFF112233));
      expect(effective.background, const Color(0xFF445566));
      expect(effective.cursor, const Color(0xFF778899));
      expect(
        buildTerminalThemeOscResponse(
          theme: effective,
          code: '10',
          args: const ['?', '#000000', '?'],
        ),
        '\x1b]10;rgb:1111/2222/3333\x1b\\'
        '\x1b]12;rgb:7777/8888/9999\x1b\\',
      );
    });

    test('sets and selectively resets extended palette entries', () {
      final overrides = TerminalOscColorOverrides();
      expect(overrides.handle('4', const ['16', '#123456', '200', '#abcdef']), (
        handled: true,
        changed: true,
      ));
      var effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.paletteOverrides[16], const Color(0xFF123456));
      expect(effective.paletteOverrides[200], const Color(0xFFABCDEF));
      expect(
        terminalThemePaletteColor(effective, 200),
        const Color(0xFFABCDEF),
      );
      expect(
        buildTerminalThemeOscResponse(
          theme: effective,
          code: '4',
          args: const ['200', '?'],
        ),
        '\x1b]4;200;rgb:abab/cdcd/efef\x1b\\',
      );

      expect(overrides.handle('104', const ['16']), (
        handled: true,
        changed: true,
      ));
      effective = overrides.applyTo(TerminalThemes.dracula);
      expect(effective.paletteOverrides[16], isNull);
      expect(effective.paletteOverrides[200], const Color(0xFFABCDEF));

      overrides.handle('104', const []);
      expect(overrides.isNotEmpty, isFalse);
    });

    test('queries and out-of-range palette entries are not mutations', () {
      final overrides = TerminalOscColorOverrides();
      expect(overrides.handle('4', const ['1', '?']), (
        handled: false,
        changed: false,
      ));
      expect(overrides.handle('4', const ['256', '#ffffff']), (
        handled: false,
        changed: false,
      ));
    });
  });
}
