/// Shared scaffolding for services that persist a JSON array in
/// `SettingsService` and mutate it with read-modify-write cycles.
library;

import 'dart:convert';

/// Serializes read-modify-write cycles so two overlapping mutations can never
/// both read the same starting list and silently discard a change.
class SerializedMutations {
  Future<void> _queue = Future<void>.value();

  /// Runs [action] after every previously queued action has settled.
  ///
  /// A failed action rejects its own future without blocking later ones.
  Future<void> run(Future<void> Function() action) {
    final operation = _queue.then((_) => action());
    _queue = operation.catchError((_) {});
    return operation;
  }
}

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
