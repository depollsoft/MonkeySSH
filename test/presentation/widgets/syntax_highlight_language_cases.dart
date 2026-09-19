import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_language.dart';

void registerSyntaxHighlightLanguageTests() {
  group('syntax_highlight_language', () {
    group('detectLanguageFromFilename', () {
      test('returns dart for .dart files', () {
        expect(detectLanguageFromFilename('main.dart'), 'dart');
      });

      test('returns javascript for .js files', () {
        expect(detectLanguageFromFilename('index.js'), 'javascript');
      });

      test('returns typescript for .ts files', () {
        expect(detectLanguageFromFilename('app.ts'), 'typescript');
      });

      test('returns python for .py files', () {
        expect(detectLanguageFromFilename('script.py'), 'python');
      });

      test('returns yaml for .yml files', () {
        expect(detectLanguageFromFilename('config.yml'), 'yaml');
      });

      test('returns yaml for .yaml files', () {
        expect(detectLanguageFromFilename('docker-compose.yaml'), 'yaml');
      });

      test('returns json for .json files', () {
        expect(detectLanguageFromFilename('package.json'), 'json');
      });

      test('returns xml for .html files', () {
        expect(detectLanguageFromFilename('index.html'), 'xml');
      });

      test('returns bash for .sh files', () {
        expect(detectLanguageFromFilename('deploy.sh'), 'bash');
      });

      test('returns sql for .sql files', () {
        expect(detectLanguageFromFilename('schema.sql'), 'sql');
      });

      test('returns markdown for .md files', () {
        expect(detectLanguageFromFilename('README.md'), 'markdown');
      });

      test('returns go for .go files', () {
        expect(detectLanguageFromFilename('main.go'), 'go');
      });

      test('returns rust for .rs files', () {
        expect(detectLanguageFromFilename('lib.rs'), 'rust');
      });

      test('returns c for .c files', () {
        expect(detectLanguageFromFilename('main.c'), 'c');
      });

      test('returns cpp for .cpp files', () {
        expect(detectLanguageFromFilename('app.cpp'), 'cpp');
      });

      test('returns java for .java files', () {
        expect(detectLanguageFromFilename('Main.java'), 'java');
      });

      test('returns swift for .swift files', () {
        expect(detectLanguageFromFilename('App.swift'), 'swift');
      });

      test('returns ruby for .rb files', () {
        expect(detectLanguageFromFilename('app.rb'), 'ruby');
      });

      test('returns css for .css files', () {
        expect(detectLanguageFromFilename('styles.css'), 'css');
      });

      test('returns dockerfile for .dockerfile extension', () {
        expect(detectLanguageFromFilename('app.dockerfile'), 'dockerfile');
      });

      test('returns null for unknown extensions', () {
        expect(detectLanguageFromFilename('data.xyz'), isNull);
      });

      test('returns null for extensionless unknown filenames', () {
        expect(detectLanguageFromFilename('RANDOMFILE'), isNull);
      });

      test('handles case insensitive extensions', () {
        expect(detectLanguageFromFilename('FILE.PY'), 'python');
        expect(detectLanguageFromFilename('FILE.Dart'), 'dart');
      });

      group('filename-based detection', () {
        test('returns dockerfile for Dockerfile', () {
          expect(detectLanguageFromFilename('Dockerfile'), 'dockerfile');
        });

        test('returns makefile for Makefile', () {
          expect(detectLanguageFromFilename('Makefile'), 'makefile');
        });

        test('returns ruby for Gemfile', () {
          expect(detectLanguageFromFilename('Gemfile'), 'ruby');
        });

        test('returns bash for .bashrc', () {
          expect(detectLanguageFromFilename('.bashrc'), 'bash');
        });

        test('returns bash for .zshrc', () {
          expect(detectLanguageFromFilename('.zshrc'), 'bash');
        });

        test('returns bash for .env', () {
          expect(detectLanguageFromFilename('.env'), 'bash');
        });
      });
    });
  });
}
