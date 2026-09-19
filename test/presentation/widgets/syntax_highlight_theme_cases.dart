import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_theme.dart';

void registerSyntaxHighlightThemeTests() {
  group('syntax_highlight_theme', () {
    group('buildSyntaxThemeFromTerminal', () {
      const darkTheme = TerminalThemeData(
        id: 'test',
        name: 'Test',
        isDark: true,
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF000000),
        cursor: Color(0xFFCCCCCC),
        selection: Color(0xFF444444),
        black: Color(0xFF000000),
        red: Color(0xFFFF0000),
        green: Color(0xFF00FF00),
        yellow: Color(0xFFFFFF00),
        blue: Color(0xFF0000FF),
        magenta: Color(0xFFFF00FF),
        cyan: Color(0xFF00FFFF),
        white: Color(0xFFFFFFFF),
        brightBlack: Color(0xFF808080),
        brightRed: Color(0xFFFF8080),
        brightGreen: Color(0xFF80FF80),
        brightYellow: Color(0xFFFFFF80),
        brightBlue: Color(0xFF8080FF),
        brightMagenta: Color(0xFFFF80FF),
        brightCyan: Color(0xFF80FFFF),
        brightWhite: Color(0xFFFFFFFF),
      );

      const lightTheme = TerminalThemeData(
        id: 'test-light',
        name: 'Test Light',
        isDark: false,
        foreground: Color(0xFF222222),
        background: Color(0xFFFFFFFF),
        cursor: Color(0xFF222222),
        selection: Color(0x60CCCCCC),
        black: Color(0xFF000000),
        red: Color(0xFFAA0000),
        green: Color(0xFF008800),
        yellow: Color(0xFF886600),
        blue: Color(0xFF0055CC),
        magenta: Color(0xFF7A22AA),
        cyan: Color(0xFF007777),
        white: Color(0xFF666666),
        brightBlack: Color(0xFF999999),
        brightRed: Color(0xFFCC4444),
        brightGreen: Color(0xFF33AA55),
        brightYellow: Color(0xFFAA8844),
        brightBlue: Color(0xFF3388DD),
        brightMagenta: Color(0xFFAA66DD),
        brightCyan: Color(0xFF44AAAA),
        brightWhite: Color(0xFF888888),
      );

      late Map<String, TextStyle> syntaxTheme;
      late Map<String, TextStyle> lightSyntaxTheme;

      setUp(() {
        syntaxTheme = buildSyntaxThemeFromTerminal(darkTheme);
        lightSyntaxTheme = buildSyntaxThemeFromTerminal(lightTheme);
      });

      test('root uses foreground and background', () {
        final root = syntaxTheme['root']!;
        expect(root.color, darkTheme.foreground);
        expect(root.backgroundColor, darkTheme.background);
      });

      test('keyword uses magenta', () {
        expect(syntaxTheme['keyword']!.color, darkTheme.magenta);
      });

      test('string uses green', () {
        expect(syntaxTheme['string']!.color, darkTheme.green);
      });

      test('number uses yellow', () {
        expect(syntaxTheme['number']!.color, darkTheme.yellow);
      });

      test('type uses cyan', () {
        expect(syntaxTheme['type']!.color, darkTheme.cyan);
      });

      test('title uses blue', () {
        expect(syntaxTheme['title']!.color, darkTheme.blue);
      });

      test('dark theme comment uses brightBlack with italic', () {
        final comment = syntaxTheme['comment']!;
        expect(comment.color, darkTheme.brightBlack);
        expect(comment.fontStyle, FontStyle.italic);
      });

      test('light theme comment uses white with italic', () {
        final comment = lightSyntaxTheme['comment']!;
        expect(comment.color, lightTheme.white);
        expect(comment.fontStyle, FontStyle.italic);
        expect(lightSyntaxTheme['deletion']!.color, lightTheme.white);
        expect(lightSyntaxTheme['meta']!.color, lightTheme.white);
      });

      test('strong is bold', () {
        expect(syntaxTheme['strong']!.fontWeight, FontWeight.bold);
      });

      test('emphasis is italic', () {
        expect(syntaxTheme['emphasis']!.fontStyle, FontStyle.italic);
      });

      test('covers all standard highlight.js class names', () {
        const expectedKeys = [
          'root',
          'keyword',
          'selector-tag',
          'name',
          'string',
          'addition',
          'number',
          'literal',
          'bullet',
          'type',
          'built_in',
          'builtin-name',
          'selector-class',
          'selector-id',
          'title',
          'section',
          'symbol',
          'attribute',
          'attr',
          'variable',
          'template-variable',
          'selector-attr',
          'selector-pseudo',
          'comment',
          'deletion',
          'meta',
          'quote',
          'regexp',
          'link',
          'code',
          'tag',
          'subst',
          'params',
          'strong',
          'emphasis',
        ];
        for (final key in expectedKeys) {
          expect(
            syntaxTheme.containsKey(key),
            isTrue,
            reason: 'missing "$key"',
          );
        }
      });
    });

    group('defaultDarkSyntaxTheme', () {
      test('has a root entry with dark background', () {
        final root = defaultDarkSyntaxTheme['root']!;
        expect(root.backgroundColor, isNotNull);
        expect(root.color, isNotNull);
      });

      test('has keyword entry', () {
        expect(defaultDarkSyntaxTheme['keyword'], isNotNull);
      });
    });

    group('defaultLightSyntaxTheme', () {
      test('has a root entry with light background', () {
        final root = defaultLightSyntaxTheme['root']!;
        expect(root.backgroundColor, isNotNull);
        expect(root.color, isNotNull);
      });

      test('has keyword entry', () {
        expect(defaultLightSyntaxTheme['keyword'], isNotNull);
      });
    });
  });
}
