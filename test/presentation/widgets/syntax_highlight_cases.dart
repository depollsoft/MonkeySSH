// ignore_for_file: public_member_api_docs

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_controller.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_language.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_theme.dart';

class _FakeBuildContext extends Fake implements BuildContext {}

void _expectChildrenDoNotSetFontSize(TextSpan span, double fontSize) {
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) {
      expect(child.style?.fontSize, isNot(fontSize));
      _expectChildrenDoNotSetFontSize(child, fontSize);
    }
  }
}

/// Registers tests from syntax_highlight_test.dart.
void registerPresentationWidgetsSyntaxHighlightTests() {
  group('SyntaxHighlightController', () {
    late SyntaxHighlightController controller;

    tearDown(() => controller.dispose());

    test('highlights Dart code and returns plain span for empty text', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
        },
        text: 'void main() { print("hello"); }',
        language: 'dart',
      );
      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.children, isNotEmpty);
      expect(span.toPlainText(), 'void main() { print("hello"); }');

      controller.text = '';
      final emptySpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(emptySpan.toPlainText(), isEmpty);
    });

    test('caches highlighted children across rebuilds and style changes', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
        },
        text: 'void main() { print("hello"); }',
        language: 'dart',
      );

      final smallSpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        style: const TextStyle(fontSize: 12),
        withComposing: false,
      );
      final largeSpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        style: const TextStyle(fontSize: 20),
        withComposing: false,
      );

      expect(smallSpan.style!.fontSize, 12);
      expect(largeSpan.style!.fontSize, 20);
      expect(largeSpan.children, same(smallSpan.children));
      _expectChildrenDoNotSetFontSize(largeSpan, 12);

      controller.text = 'final y = 2;';
      final updatedSpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(updatedSpan.toPlainText(), 'final y = 2;');
      expect(updatedSpan.children, isNot(same(smallSpan.children)));
    });

    test('skips highlighting when exceeding size limit, unknown language, or composing', () {
      final largeText = 'x' * (syntaxHighlightSizeLimit + 1);
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: largeText,
        language: 'dart',
      );
      expect(
        controller
            .buildTextSpan(context: _FakeBuildContext(), withComposing: false)
            .toPlainText(),
        largeText,
      );
      controller.dispose();

      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'some text',
        language: 'not_a_real_language_xyz',
      );
      expect(
        controller
            .buildTextSpan(context: _FakeBuildContext(), withComposing: false)
            .toPlainText(),
        'some text',
      );
      controller.dispose();

      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 4, end: 9),
      );
      expect(
        controller
            .buildTextSpan(context: _FakeBuildContext(), withComposing: true)
            .toPlainText(),
        'var x = 1;',
      );
    });
  });

  group('detectLanguageFromFilename', () {
    test('maps known extensions, case-insensitive names, special filenames, and unknowns', () {
      const cases = <String, String?>{
        'main.dart': 'dart',
        'index.js': 'javascript',
        'app.ts': 'typescript',
        'script.py': 'python',
        'config.yml': 'yaml',
        'docker-compose.yaml': 'yaml',
        'package.json': 'json',
        'index.html': 'xml',
        'deploy.sh': 'bash',
        'schema.sql': 'sql',
        'README.md': 'markdown',
        'main.go': 'go',
        'lib.rs': 'rust',
        'main.c': 'c',
        'app.cpp': 'cpp',
        'Main.java': 'java',
        'App.swift': 'swift',
        'app.rb': 'ruby',
        'styles.css': 'css',
        'app.dockerfile': 'dockerfile',
        'FILE.PY': 'python',
        'FILE.Dart': 'dart',
        'Dockerfile': 'dockerfile',
        'Makefile': 'makefile',
        'Gemfile': 'ruby',
        '.bashrc': 'bash',
        '.zshrc': 'bash',
        '.env': 'bash',
        'data.xyz': null,
        'RANDOMFILE': null,
      };
      for (final entry in cases.entries) {
        expect(
          detectLanguageFromFilename(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    });
  });

  group('buildSyntaxThemeFromTerminal', () {
    test('maps terminal colors and styles for dark and light themes', () {
      final dark = buildSyntaxThemeFromTerminal(
        TerminalThemes.defaultDarkTheme,
      );
      final light = buildSyntaxThemeFromTerminal(
        TerminalThemes.defaultLightTheme,
      );

      expect(dark['root']!.color, TerminalThemes.defaultDarkTheme.foreground);
      expect(
        dark['root']!.backgroundColor,
        TerminalThemes.defaultDarkTheme.background,
      );
      expect(dark['keyword']!.color, TerminalThemes.defaultDarkTheme.magenta);
      expect(dark['string']!.color, TerminalThemes.defaultDarkTheme.green);
      expect(dark['number']!.color, TerminalThemes.defaultDarkTheme.yellow);
      expect(dark['type']!.color, TerminalThemes.defaultDarkTheme.cyan);
      expect(dark['title']!.color, TerminalThemes.defaultDarkTheme.blue);
      expect(
        dark['comment']!.color,
        TerminalThemes.defaultDarkTheme.brightBlack,
      );
      expect(dark['comment']!.fontStyle, FontStyle.italic);
      expect(dark['strong']!.fontWeight, FontWeight.bold);
      expect(dark['emphasis']!.fontStyle, FontStyle.italic);

      expect(light['comment']!.color, TerminalThemes.defaultLightTheme.white);
      expect(light['comment']!.fontStyle, FontStyle.italic);
      expect(light['deletion']!.color, TerminalThemes.defaultLightTheme.white);
      expect(light['meta']!.color, TerminalThemes.defaultLightTheme.white);

      for (final key in const [
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
      ]) {
        expect(dark.containsKey(key), isTrue, reason: 'missing "$key"');
      }

      expect(defaultDarkSyntaxTheme['root']?.backgroundColor, isNotNull);
      expect(defaultDarkSyntaxTheme['keyword'], isNotNull);
      expect(defaultLightSyntaxTheme['root']?.backgroundColor, isNotNull);
      expect(defaultLightSyntaxTheme['keyword'], isNotNull);
    });
  });
}
