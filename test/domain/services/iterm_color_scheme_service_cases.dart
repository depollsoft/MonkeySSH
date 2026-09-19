import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:monkeyssh/domain/models/iterm_color_scheme.dart';
import 'package:monkeyssh/domain/services/iterm_color_scheme_service.dart';

void registerItermColorSchemeServiceTests() {
  group('iterm_color_scheme_service', () {
    group('ItermColorSchemeMetadata', () {
      test('derives local ID and raw URL from repository path', () {
        final scheme = ItermColorSchemeMetadata.fromPath(
          'schemes/GitHub Light Default.itermcolors',
        );

        expect(scheme.id, 'iterm2-github-light-default');
        expect(scheme.name, 'GitHub Light Default');
        expect(
          scheme.rawUri.toString(),
          'https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/schemes/GitHub%20Light%20Default.itermcolors',
        );
      });
    });

    group('parseItermColorScheme', () {
      test('parses required plist colors into a terminal theme', () {
        final scheme = ItermColorSchemeMetadata.fromPath(
          'schemes/Test Dark.itermcolors',
        );

        final theme = parseItermColorScheme(
          scheme: scheme,
          plist: _themePlist(),
        );

        expect(theme.id, 'iterm2-test-dark');
        expect(theme.name, 'Test Dark');
        expect(theme.isCustom, isTrue);
        expect(theme.isDark, isTrue);
        expect(theme.foreground, const Color(0xFFFFFFFF));
        expect(theme.background, const Color(0xFF000000));
        expect(theme.cursor, const Color(0xFF808080));
      });
    });

    group('ItermColorSchemeService', () {
      test('searchSchemes searches live tree paths by name terms', () async {
        final service = ItermColorSchemeService(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'tree': [
                  {'type': 'blob', 'path': 'schemes/Dracula.itermcolors'},
                  {
                    'type': 'blob',
                    'path': 'schemes/Solarized Dark.itermcolors',
                  },
                  {'type': 'blob', 'path': 'README.md'},
                  {'type': 'tree', 'path': 'schemes'},
                ],
              }),
              200,
            ),
          ),
        );
        addTearDown(service.dispose);

        final results = await service.searchSchemes('solar dark');

        expect(results, hasLength(1));
        expect(results.single.name, 'Solarized Dark');
        expect(results.single.id, 'iterm2-solarized-dark');
      });

      test('loadTheme downloads and parses selected scheme', () async {
        final scheme = ItermColorSchemeMetadata.fromPath(
          'schemes/Test Dark.itermcolors',
        );
        final service = ItermColorSchemeService(
          client: MockClient((request) async {
            expect(request.url.host, 'raw.githubusercontent.com');
            return http.Response(_themePlist(), 200);
          }),
        );
        addTearDown(service.dispose);

        final theme = await service.loadTheme(scheme);

        expect(theme.id, scheme.id);
        expect(theme.background, const Color(0xFF000000));
      });

      test(
        'loadTheme shares in-flight raw downloads and caches previews',
        () async {
          final scheme = ItermColorSchemeMetadata.fromPath(
            'schemes/Test Dark.itermcolors',
          );
          var requestCount = 0;
          final responseCompleter = Completer<http.Response>();
          final service = ItermColorSchemeService(
            client: MockClient((request) {
              requestCount += 1;
              return responseCompleter.future;
            }),
          );
          addTearDown(service.dispose);

          final first = service.loadTheme(scheme);
          final second = service.loadTheme(scheme);
          await Future<void>.delayed(Duration.zero);
          responseCompleter.complete(http.Response(_themePlist(), 200));

          final results = await Future.wait([first, second]);
          final cached = await service.loadTheme(scheme);

          expect(requestCount, 1);
          expect(identical(results.first, results.last), isTrue);
          expect(identical(results.first, cached), isTrue);
        },
      );

      test('listSchemes shares one cold in-flight GitHub request', () async {
        var requestCount = 0;
        final responseCompleter = Completer<http.Response>();
        final service = ItermColorSchemeService(
          client: MockClient((request) {
            requestCount += 1;
            return responseCompleter.future;
          }),
        );
        addTearDown(service.dispose);

        final first = service.searchSchemes('dracula');
        final second = service.searchSchemes('solarized');
        await Future<void>.delayed(Duration.zero);
        responseCompleter.complete(
          http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'schemes/Dracula.itermcolors'},
                {'type': 'blob', 'path': 'schemes/Solarized Dark.itermcolors'},
              ],
            }),
            200,
          ),
        );

        final results = await Future.wait([first, second]);

        expect(requestCount, 1);
        expect(results.first.single.name, 'Dracula');
        expect(results.last.single.name, 'Solarized Dark');
      });
    });
  });
}

String _themePlist() {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>')
    ..write('<plist version="1.0"><dict>')
    ..write('<key>Foreground Color</key>${_colorDict(1, 1, 1)}')
    ..write('<key>Background Color</key>${_colorDict(0, 0, 0)}')
    ..write('<key>Cursor Color</key>${_colorDict(0.5, 0.5, 0.5)}')
    ..write('<key>Selection Color</key>${_colorDict(0.25, 0.25, 0.25)}');

  for (var index = 0; index < 16; index += 1) {
    final component = index / 15;
    buffer.write(
      '<key>Ansi $index Color</key>${_colorDict(component, component, component)}',
    );
  }

  buffer.write('</dict></plist>');
  return buffer.toString();
}

String _colorDict(double red, double green, double blue) {
  final buffer = StringBuffer()
    ..write('<dict>')
    ..write('<key>Alpha Component</key><real>1</real>')
    ..write('<key>Blue Component</key><real>$blue</real>')
    ..write('<key>Color Space</key><string>sRGB</string>')
    ..write('<key>Green Component</key><real>$green</real>')
    ..write('<key>Red Component</key><real>$red</real>')
    ..write('</dict>');
  return buffer.toString();
}
