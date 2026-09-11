import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/iterm_color_scheme.dart';
import '../models/terminal_theme.dart';

const _schemesPathPrefix = 'schemes/';
const _schemesPathSuffix = '.itermcolors';

/// Error returned when live iTerm2 scheme data cannot be loaded.
class ItermColorSchemeException implements Exception {
  /// Creates a new iTerm2 scheme loading error.
  const ItermColorSchemeException(this.message);

  /// Human-readable failure message.
  final String message;

  @override
  String toString() => message;
}

/// Service for searching and loading live iTerm2 color schemes.
class ItermColorSchemeService {
  /// Creates a new [ItermColorSchemeService].
  ItermColorSchemeService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  List<ItermColorSchemeMetadata>? _cachedSchemes;
  Future<List<ItermColorSchemeMetadata>>? _pendingSchemes;
  final _cachedThemes = <String, TerminalThemeData>{};
  final _pendingThemes = <String, Future<TerminalThemeData>>{};

  /// Lists all live `.itermcolors` schemes from the upstream repository.
  Future<List<ItermColorSchemeMetadata>> listSchemes() async {
    if (_cachedSchemes != null) {
      return _cachedSchemes!;
    }
    if (_pendingSchemes != null) {
      return _pendingSchemes!;
    }

    final pendingSchemes = _fetchSchemes();
    _pendingSchemes = pendingSchemes;
    try {
      return await pendingSchemes;
    } finally {
      if (identical(_pendingSchemes, pendingSchemes)) {
        _pendingSchemes = null;
      }
    }
  }

  Future<List<ItermColorSchemeMetadata>> _fetchSchemes() async {
    final http.Response response;
    try {
      response = await _client.get(
        Uri.https(
          'api.github.com',
          '/repos/mbadolato/iTerm2-Color-Schemes/git/trees/master',
          {'recursive': '1'},
        ),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'MonkeySSH',
        },
      );
    } on http.ClientException catch (error) {
      throw ItermColorSchemeException(
        'Could not reach GitHub: ${error.message}',
      );
    }
    if (response.statusCode != 200) {
      throw ItermColorSchemeException(
        'GitHub returned HTTP ${response.statusCode} while loading themes.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GitHub tree response was not an object.');
    }
    if (decoded['truncated'] == true) {
      throw const ItermColorSchemeException(
        'GitHub tree response was truncated.',
      );
    }

    final tree = decoded['tree'];
    if (tree is! List<dynamic>) {
      throw const FormatException('GitHub tree response did not include tree.');
    }

    final schemes = <ItermColorSchemeMetadata>[];
    for (final item in tree) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      if (item['type'] != 'blob') {
        continue;
      }
      final path = item['path'];
      if (path is! String ||
          !path.startsWith(_schemesPathPrefix) ||
          !path.endsWith(_schemesPathSuffix)) {
        continue;
      }
      schemes.add(ItermColorSchemeMetadata.fromPath(path));
    }

    schemes.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    _cachedSchemes = List.unmodifiable(schemes);
    return _cachedSchemes!;
  }

  /// Searches live iTerm2 schemes by name.
  Future<List<ItermColorSchemeMetadata>> searchSchemes(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const [];
    }

    final terms = normalized
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList(growable: false);
    final schemes = await listSchemes();
    return schemes
        .where((scheme) {
          final name = scheme.name.toLowerCase();
          return terms.every(name.contains);
        })
        .toList(growable: false);
  }

  /// Downloads and parses a live iTerm2 color scheme.
  Future<TerminalThemeData> loadTheme(ItermColorSchemeMetadata scheme) async {
    final cachedTheme = _cachedThemes[scheme.path];
    if (cachedTheme != null) {
      return cachedTheme;
    }

    final pendingTheme = _pendingThemes[scheme.path];
    if (pendingTheme != null) {
      final theme = await pendingTheme;
      return theme;
    }

    final pendingThemeLoad = _fetchTheme(scheme);
    _pendingThemes[scheme.path] = pendingThemeLoad;
    try {
      final theme = await pendingThemeLoad;
      _cachedThemes[scheme.path] = theme;
      return theme;
    } finally {
      if (identical(_pendingThemes[scheme.path], pendingThemeLoad)) {
        final _ = _pendingThemes.remove(scheme.path);
      }
    }
  }

  Future<TerminalThemeData> _fetchTheme(ItermColorSchemeMetadata scheme) async {
    final http.Response response;
    try {
      response = await _client.get(scheme.rawUri);
    } on http.ClientException catch (error) {
      throw ItermColorSchemeException(
        'Could not reach GitHub: ${error.message}',
      );
    }
    if (response.statusCode != 200) {
      throw ItermColorSchemeException(
        'GitHub returned HTTP ${response.statusCode} while loading '
        '${scheme.name}.',
      );
    }
    try {
      return parseItermColorScheme(scheme: scheme, plist: response.body);
    } on XmlException catch (error) {
      throw ItermColorSchemeException(
        'Theme plist was invalid: ${error.message}',
      );
    } on FormatException catch (error) {
      throw ItermColorSchemeException(
        'Theme plist was missing colors: ${error.message}',
      );
    }
  }

  /// Releases resources owned by the service.
  void dispose() {
    _client.close();
  }
}

/// Parses an iTerm2 `.itermcolors` plist into [TerminalThemeData].
TerminalThemeData parseItermColorScheme({
  required ItermColorSchemeMetadata scheme,
  required String plist,
}) {
  final document = XmlDocument.parse(plist);
  final plistElement = document.rootElement;
  if (plistElement.name.local != 'plist') {
    throw const FormatException('Theme file root was not a plist.');
  }

  final rootDict = _firstElement(
    plistElement.findElements('dict'),
    'plist dictionary',
  );
  final colors = _readDict(rootDict);
  final background = _readColor(colors, 'Background Color');

  return TerminalThemeData(
    id: scheme.id,
    name: scheme.name,
    isDark: background.computeLuminance() < 0.5,
    isCustom: true,
    foreground: _readColor(colors, 'Foreground Color'),
    background: background,
    cursor: _readColor(colors, 'Cursor Color'),
    selection: _readColor(colors, 'Selection Color'),
    black: _readColor(colors, 'Ansi 0 Color'),
    red: _readColor(colors, 'Ansi 1 Color'),
    green: _readColor(colors, 'Ansi 2 Color'),
    yellow: _readColor(colors, 'Ansi 3 Color'),
    blue: _readColor(colors, 'Ansi 4 Color'),
    magenta: _readColor(colors, 'Ansi 5 Color'),
    cyan: _readColor(colors, 'Ansi 6 Color'),
    white: _readColor(colors, 'Ansi 7 Color'),
    brightBlack: _readColor(colors, 'Ansi 8 Color'),
    brightRed: _readColor(colors, 'Ansi 9 Color'),
    brightGreen: _readColor(colors, 'Ansi 10 Color'),
    brightYellow: _readColor(colors, 'Ansi 11 Color'),
    brightBlue: _readColor(colors, 'Ansi 12 Color'),
    brightMagenta: _readColor(colors, 'Ansi 13 Color'),
    brightCyan: _readColor(colors, 'Ansi 14 Color'),
    brightWhite: _readColor(colors, 'Ansi 15 Color'),
  );
}

XmlElement _firstElement(Iterable<XmlElement> elements, String description) {
  final iterator = elements.iterator;
  if (!iterator.moveNext()) {
    throw FormatException('Missing $description.');
  }
  return iterator.current;
}

Map<String, XmlElement> _readDict(XmlElement dictElement) {
  final result = <String, XmlElement>{};
  String? currentKey;
  for (final child in dictElement.children.whereType<XmlElement>()) {
    if (child.name.local == 'key') {
      currentKey = child.innerText.trim();
      continue;
    }
    if (currentKey case final key?) {
      result[key] = child;
      currentKey = null;
    }
  }
  return result;
}

Color _readColor(Map<String, XmlElement> plistDict, String key) {
  final colorElement = plistDict[key];
  if (colorElement == null) {
    throw FormatException('Missing $key.');
  }
  if (colorElement.name.local != 'dict') {
    throw FormatException('$key was not a color dictionary.');
  }

  final colorDict = _readDict(colorElement);
  return Color.fromARGB(
    _colorComponentToByte(_readNumber(colorDict, 'Alpha Component', 1)),
    _colorComponentToByte(_readNumber(colorDict, 'Red Component', 0)),
    _colorComponentToByte(_readNumber(colorDict, 'Green Component', 0)),
    _colorComponentToByte(_readNumber(colorDict, 'Blue Component', 0)),
  );
}

double _readNumber(
  Map<String, XmlElement> dict,
  String key,
  double defaultValue,
) {
  final element = dict[key];
  if (element == null) {
    return defaultValue;
  }
  final parsed = double.tryParse(element.innerText.trim());
  if (parsed == null) {
    throw FormatException('$key was not a number.');
  }
  return parsed;
}

int _colorComponentToByte(double value) => (value.clamp(0, 1) * 255).round();

/// Provider for [ItermColorSchemeService].
final itermColorSchemeServiceProvider = Provider<ItermColorSchemeService>((
  ref,
) {
  final service = ItermColorSchemeService();
  ref.onDispose(service.dispose);
  return service;
});

/// Provider for live iTerm2 scheme search results.
final itermColorSchemeSearchProvider = FutureProvider.autoDispose
    .family<List<ItermColorSchemeMetadata>, String>((ref, query) {
      final service = ref.watch(itermColorSchemeServiceProvider);
      return service.searchSchemes(query);
    });

/// Provider for a live iTerm2 scheme preview.
final itermColorSchemeThemeProvider = FutureProvider.autoDispose
    .family<TerminalThemeData, ItermColorSchemeMetadata>((ref, scheme) {
      final service = ref.watch(itermColorSchemeServiceProvider);
      return service.loadTheme(scheme);
    });
