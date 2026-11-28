/// Shared helper for services that persist a JSON array in `SettingsService`.
library;

import 'dart:convert';

/// Decodes a persisted JSON array, treating missing, malformed, or non-array
/// storage as empty so one corrupt setting never surfaces as an error.
List<Object?> decodeJsonList(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded : const [];
  } on FormatException {
    return const [];
  }
}
