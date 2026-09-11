import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FluttyTheme.debugUseSystemFonts = true;
  });

  tearDownAll(() {
    FluttyTheme.debugUseSystemFonts = false;
  });

  group('FluttyTheme', () {
    for (final allowRuntimeFetching in [false, true]) {
      testWidgets(
        'uses bundled fonts with runtime fetching $allowRuntimeFetching',
        (tester) async {
          final previousFetching = GoogleFonts.config.allowRuntimeFetching;
          final previousSystemFonts = FluttyTheme.debugUseSystemFonts;
          addTearDown(() {
            GoogleFonts.config.allowRuntimeFetching = previousFetching;
            FluttyTheme.debugUseSystemFonts = previousSystemFonts;
          });
          GoogleFonts.config.allowRuntimeFetching = allowRuntimeFetching;
          FluttyTheme.debugUseSystemFonts = false;

          for (final theme in [FluttyTheme.light, FluttyTheme.dark]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: Column(
                    children: [
                      const Text('Body'),
                      Text('Code', style: FluttyTheme.monoStyle),
                      Text('Title', style: FluttyTheme.displayMono()),
                    ],
                  ),
                ),
              ),
            );
            for (final (label, family) in [
              ('Body', 'Inter'),
              ('Code', 'JetBrains Mono'),
              ('Title', 'JetBrains Mono'),
            ]) {
              final richText = tester.widget<RichText>(
                find.descendant(
                  of: find.text(label),
                  matching: find.byType(RichText),
                ),
              );
              expect(richText.text.style?.fontFamily, family);
            }
            expect(
              theme.appBarTheme.titleTextStyle?.fontFamily,
              'JetBrains Mono',
            );
            expect(tester.takeException(), isNull);
          }
          // Any accidental GoogleFonts call must finish without a hidden load
          // failure, even when downloads are disabled and no cache is present.
          await GoogleFonts.pendingFonts();
        },
      );
    }

    test('preserves text metrics and the system-font test override', () {
      final previousSystemFonts = FluttyTheme.debugUseSystemFonts;
      addTearDown(() => FluttyTheme.debugUseSystemFonts = previousSystemFonts);
      for (final brightness in Brightness.values) {
        ThemeData buildTheme() => brightness == Brightness.dark
            ? FluttyTheme.dark
            : FluttyTheme.light;
        FluttyTheme.debugUseSystemFonts = true;
        final system = buildTheme();
        expect(system.textTheme.bodyMedium?.fontFamily, isNot('Inter'));
        expect(FluttyTheme.monoStyle.fontFamily, 'monospace');
        expect(FluttyTheme.displayMono().fontFamily, 'monospace');
        FluttyTheme.debugUseSystemFonts = false;
        final bundled = buildTheme();
        final systemStyles = _textStyles(system.textTheme);
        final bundledStyles = _textStyles(bundled.textTheme);
        for (var index = 0; index < systemStyles.length; index++) {
          final before = systemStyles[index]!;
          final after = bundledStyles[index]!;
          expect(after.fontFamily, 'Inter');
          expect(after.fontSize, before.fontSize);
          expect(after.fontWeight, before.fontWeight);
          expect(after.height, before.height);
          expect(after.letterSpacing, before.letterSpacing);
          expect(after.wordSpacing, before.wordSpacing);
          expect(after.textBaseline, before.textBaseline);
          expect(after.color, before.color);
        }
        expect(bundled.textTheme.headlineLarge?.fontWeight, FontWeight.w700);
        expect(bundled.textTheme.headlineMedium?.fontWeight, FontWeight.w600);
        expect(bundled.appBarTheme.titleTextStyle?.fontWeight, FontWeight.w600);
      }
    });

    test('bundles regular and italic fonts and their OFL notices', () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json'))
              as List<dynamic>;
      for (final (family, filename, license) in [
        ('Inter', 'Inter', 'OFL-Inter.txt'),
        ('JetBrains Mono', 'JetBrainsMono', 'OFL-JetBrainsMono.txt'),
      ]) {
        final entry = manifest.cast<Map<String, dynamic>>().singleWhere(
          (entry) => entry['family'] == family,
        );
        expect(entry['fonts'], [
          {'asset': 'assets/fonts/$filename.ttf'},
          {'asset': 'assets/fonts/$filename-Italic.ttf', 'style': 'italic'},
        ]);
        for (final suffix in ['', '-Italic']) {
          final data = await rootBundle.load(
            'assets/fonts/$filename$suffix.ttf',
          );
          expect(data.lengthInBytes, greaterThan(0));
        }
        expect(
          await rootBundle.loadString('assets/fonts/$license'),
          contains('SIL OPEN FONT LICENSE Version 1.1'),
        );
      }
    });

    test('builds app colors from a terminal palette', () {
      const terminalTheme = TerminalThemes.tokyoNightNight;

      final theme = FluttyTheme.fromTerminalTheme(
        terminalTheme,
        brightness: Brightness.dark,
      );

      expect(theme.scaffoldBackgroundColor, terminalTheme.background);
      expect(theme.appBarTheme.backgroundColor, terminalTheme.background);
      expect(theme.colorScheme.surface, terminalTheme.background);
      expect(theme.colorScheme.onSurface, terminalTheme.foreground);
      expect(theme.textTheme.titleLarge?.color, terminalTheme.foreground);
      expect(
        _terminalAccentCandidates(terminalTheme),
        contains(theme.colorScheme.primary),
      );
    });

    test('keeps the requested brightness for the Material theme slot', () {
      const terminalTheme = TerminalThemes.atomOneDark;

      final theme = FluttyTheme.fromTerminalTheme(
        terminalTheme,
        brightness: Brightness.light,
      );

      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, terminalTheme.background);
    });

    test('builds app theme from active terminal connection override', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      const overrideTheme = TerminalThemes.tokyoNightNight;

      final theme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: TerminalThemes.all,
        terminalAppThemeOverride: TerminalAppThemeOverride(
          owner: const Object(),
          darkThemeId: overrideTheme.id,
        ),
      );

      expect(theme.scaffoldBackgroundColor, overrideTheme.background);
      expect(theme.colorScheme.onSurface, overrideTheme.foreground);
    });

    test('uses Flutter predictive back transitions on Android', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      final themes = [
        FluttyTheme.dark,
        buildTerminalAppTheme(
          brightness: Brightness.dark,
          terminalThemeSettings: terminalThemeSettings,
          terminalThemes: TerminalThemes.all,
        ),
      ];

      for (final theme in themes) {
        final builder =
            theme.pageTransitionsTheme.builders[TargetPlatform.android];
        expect(builder, isA<PredictiveBackPageTransitionsBuilder>());
        final predictiveBuilder =
            builder! as PredictiveBackPageTransitionsBuilder;
        expect(predictiveBuilder.fallbackColor, theme.scaffoldBackgroundColor);
      }
    });

    test('falls back to global theme when override omits brightness', () {
      const terminalThemeSettings = TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      );
      const globalTheme = TerminalThemes.defaultDarkTheme;

      final theme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: TerminalThemes.all,
        terminalAppThemeOverride: TerminalAppThemeOverride(
          owner: const Object(),
          lightThemeId: TerminalThemes.defaultLightTheme.id,
        ),
      );

      expect(theme.scaffoldBackgroundColor, globalTheme.background);
      expect(theme.colorScheme.onSurface, globalTheme.foreground);
    });

    test(
      'uses the brand-teal cursor as Material primary for MonkeySSH themes',
      () {
        for (final terminalTheme in [
          TerminalThemes.monkeyDark,
          TerminalThemes.monkeyLight,
        ]) {
          final theme = FluttyTheme.fromTerminalTheme(
            terminalTheme,
            brightness: terminalTheme.isDark
                ? Brightness.dark
                : Brightness.light,
          );
          expect(
            theme.colorScheme.primary,
            terminalTheme.cursor,
            reason:
                '${terminalTheme.name} should drive Material primary from '
                'its saturated cursor color.',
          );
        }
      },
    );

    test('falls back to the candidate-scoring algorithm for low-saturation '
        'cursors', () {
      final theme = FluttyTheme.fromTerminalTheme(
        TerminalThemes.dracula,
        brightness: Brightness.dark,
      );
      // Dracula uses a near-white cursor (low saturation), so primary
      // should come from the saturated candidate list instead.
      expect(theme.colorScheme.primary, isNot(TerminalThemes.dracula.cursor));
      expect(
        _terminalAccentCandidates(TerminalThemes.dracula),
        contains(theme.colorScheme.primary),
      );
    });
  });
}

List<TextStyle?> _textStyles(TextTheme theme) => [
  theme.displayLarge,
  theme.displayMedium,
  theme.displaySmall,
  theme.headlineLarge,
  theme.headlineMedium,
  theme.headlineSmall,
  theme.titleLarge,
  theme.titleMedium,
  theme.titleSmall,
  theme.bodyLarge,
  theme.bodyMedium,
  theme.bodySmall,
  theme.labelLarge,
  theme.labelMedium,
  theme.labelSmall,
];

Set<Color> _terminalAccentCandidates(TerminalThemeData theme) => {
  theme.blue,
  theme.cyan,
  theme.magenta,
  theme.green,
  theme.brightBlue,
  theme.brightCyan,
  theme.brightMagenta,
  theme.cursor,
  theme.yellow,
  theme.red,
};
