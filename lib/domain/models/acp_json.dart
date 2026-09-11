/// Maximum UTF-16 code units accepted for provider-controlled identifiers.
///
/// Identifiers are retained in maps and rendered as widget keys, so they must
/// not be allowed to bypass the normal timeline memory budget.
const acpMaxIdentifierCharacters = 4096;

/// Maximum nested containers retained from provider-controlled JSON.
///
/// JSON decoding itself accepts deeply nested frames. Retained metadata and
/// extension fields are copied recursively, so this bound prevents malformed
/// providers from exhausting the app isolate's stack.
const acpMaxJsonNestingDepth = 64;

/// A JSON object used by the Agent Client Protocol.
typedef AcpJsonMap = Map<String, Object?>;

/// Safe JSON conversion helpers used by ACP parsers.
abstract final class AcpJson {
  /// Returns [value] as a string-keyed JSON object, or `null`.
  static AcpJsonMap? object(Object? value) {
    if (value is! Map) return null;
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) result[key] = entry.value;
    }
    return result;
  }

  /// Returns [value] as a JSON list, or `null`.
  static List<Object?>? list(Object? value) {
    if (value is! List) return null;
    return List<Object?>.unmodifiable(value.map(_freeze));
  }

  /// Parses object entries, applying [limit] before traversing discarded data.
  static List<T> objectList<T>(
    Object? value,
    T Function(AcpJsonMap) parse, {
    int? limit,
  }) {
    if (value is! List) return List<T>.unmodifiable(const []);
    final result = <T>[];
    for (final item in value) {
      if (limit != null && result.length >= limit) break;
      final json = object(item);
      if (json != null) result.add(parse(json));
    }
    return List<T>.unmodifiable(result);
  }

  /// Returns a JSON string field.
  static String? string(AcpJsonMap json, String key) {
    final value = json[key];
    return value is String ? value : null;
  }

  /// Returns a bounded provider-controlled identifier field.
  static String? identifier(AcpJsonMap json, String key) {
    final value = string(json, key);
    if (value == null || value.length > acpMaxIdentifierCharacters) {
      return null;
    }
    return value;
  }

  /// Returns a JSON boolean field.
  static bool? boolean(AcpJsonMap json, String key) {
    final value = json[key];
    return value is bool ? value : null;
  }

  /// Returns a JSON integer field.
  static int? integer(AcpJsonMap json, String key) {
    final value = json[key];
    return value is int ? value : null;
  }

  /// Returns a JSON numeric field.
  static num? number(AcpJsonMap json, String key) {
    final value = json[key];
    return value is num ? value : null;
  }

  /// Returns a nested JSON object field.
  static AcpJsonMap? objectField(AcpJsonMap json, String key) =>
      object(json[key]);

  /// Returns a nested JSON list field.
  static List<Object?>? listField(AcpJsonMap json, String key) =>
      list(json[key]);

  /// Returns a list containing only valid string items.
  static List<String> strings(Object? value) {
    final values = list(value);
    if (values == null) return const <String>[];
    return List<String>.unmodifiable(values.whereType<String>());
  }

  /// Returns the reserved ACP `_meta` object.
  static AcpJsonMap meta(AcpJsonMap json) =>
      immutableObject(objectField(json, '_meta') ?? const <String, Object?>{});

  /// Returns fields that are not recognized by the parser.
  static AcpJsonMap extensions(AcpJsonMap json, Iterable<String> knownFields) {
    final known = knownFields.toSet()..add('_meta');
    return immutableObject(
      Map<String, Object?>.fromEntries(
        json.entries.where((entry) => !known.contains(entry.key)),
      ),
    );
  }

  /// Returns an immutable copy suitable for retaining unknown protocol data.
  static AcpJsonMap immutableObject(AcpJsonMap json) =>
      Map<String, Object?>.unmodifiable(
        json.map((key, value) => MapEntry(key, _freeze(value))),
      );

  static Object? _freeze(Object? value, [int depth = 0]) {
    if (value is Map) {
      if (depth >= acpMaxJsonNestingDepth) return null;
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key case final String key) {
          result[key] = _freeze(entry.value, depth + 1);
        }
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    if (value is List) {
      if (depth >= acpMaxJsonNestingDepth) return null;
      return List<Object?>.unmodifiable(
        value.map((item) => _freeze(item, depth + 1)),
      );
    }
    return value;
  }
}

/// Shared extension data retained by forward-compatible ACP models.
abstract interface class AcpExtensible {
  /// ACP-reserved metadata that callers must treat as opaque.
  AcpJsonMap get meta;

  /// Unknown top-level fields retained by the parser.
  AcpJsonMap get extensions;
}
