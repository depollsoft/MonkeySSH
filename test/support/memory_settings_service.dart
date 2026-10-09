// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// Never opened; shared so tests do not create one database per instance.
final _unusedDatabase = AppDatabase.forTesting(NativeDatabase.memory());

/// A [SettingsService] over a plain map, safe to use inside `testWidgets`
/// fake time.
class MemorySettingsService extends SettingsService {
  MemorySettingsService([Map<String, String>? values])
    : values = values ?? <String, String>{},
      super(_unusedDatabase);

  final Map<String, String> values;

  /// When set, reads wait for it to complete.
  Completer<void>? readGate;

  /// When set, reads throw it.
  Object? readError;

  /// Keys written or deleted, in order.
  final List<String> writtenKeys = <String>[];

  int get writeCount => writtenKeys.length;

  Future<void> _read() async {
    await readGate?.future;
    final error = readError;
    // ignore: only_throw_errors
    if (error != null) throw error;
  }

  @override
  Future<String?> getString(String key) async {
    await _read();
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    writtenKeys.add(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    writtenKeys.add(key);
    values.remove(key);
  }

  @override
  Future<void> setStrings(Map<String, String?> values) async {
    for (final MapEntry(:key, :value) in values.entries) {
      if (value == null) {
        await delete(key);
      } else {
        await setString(key, value);
      }
    }
  }

  @override
  Future<List<String>> getKeysWithPrefix(String prefix) async {
    await _read();
    return [
      for (final key in values.keys)
        if (key.startsWith(prefix)) key,
    ];
  }

  @override
  Future<Map<String, String>> getStringsWithPrefix(
    String prefix, {
    int? valueLength,
  }) async {
    await _read();
    return <String, String>{
      for (final MapEntry(:key, :value) in values.entries)
        if (key.startsWith(prefix))
          key: valueLength == null || value.length <= valueLength
              ? value
              : value.substring(0, valueLength),
    };
  }
}
