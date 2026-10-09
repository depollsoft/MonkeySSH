// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// A [SettingsService] over a plain map, safe to use inside `testWidgets`
/// fake time. The database it hands to its superclass is never opened.
class MemorySettingsService extends SettingsService {
  MemorySettingsService()
    : super(AppDatabase.forTesting(NativeDatabase.memory()));

  final Map<String, String> values = <String, String>{};

  /// When set, reads wait for it to complete.
  Completer<void>? readGate;

  /// Number of writes and deletes performed.
  int writeCount = 0;

  @override
  Future<String?> getString(String key) async {
    await readGate?.future;
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    writeCount++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    writeCount++;
    values.remove(key);
  }

  @override
  Future<Map<String, String>> getStringsWithPrefix(String prefix) async {
    await readGate?.future;
    return <String, String>{
      for (final entry in values.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }
}
