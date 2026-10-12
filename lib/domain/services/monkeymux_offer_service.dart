import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'serial_task_queue.dart';
import 'settings_service.dart';

const _pendingKey = 'monkeymux_offer_pending_hosts';

/// Remembers which new hosts should be offered MonkeyMux on their first
/// connection.
///
/// A host saved as a plain shell ("Do nothing") is marked when it is
/// created. Its first connection takes the mark, so the offer appears once,
/// whatever the answer, and never for hosts that existed before.
class MonkeyMuxOfferService {
  /// Creates the service over [settings].
  MonkeyMuxOfferService(this._settings);

  final SettingsService _settings;
  final _queue = SerialTaskQueue();

  /// Marks [hostId] to be offered MonkeyMux on its first connection.
  Future<void> markPending(int hostId) => _queue.run(() async {
    final pending = await _read();
    if (pending.add(hostId)) await _write(pending);
  });

  /// Whether [hostId] should be offered MonkeyMux now. Returns true at most
  /// once per mark.
  Future<bool> takePending(int hostId) => _queue.run(() async {
    final pending = await _read();
    if (!pending.remove(hostId)) return false;
    await _write(pending);
    return true;
  });

  Future<Set<int>> _read() async {
    final raw = await _settings.getString(_pendingKey);
    if (raw == null) return <int>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<int>().toSet() : <int>{};
    } on FormatException {
      return <int>{};
    }
  }

  Future<void> _write(Set<int> pending) =>
      _settings.setString(_pendingKey, jsonEncode(pending.toList()..sort()));
}

/// The [MonkeyMuxOfferService].
final monkeyMuxOfferServiceProvider = Provider<MonkeyMuxOfferService>(
  (ref) => MonkeyMuxOfferService(ref.watch(settingsServiceProvider)),
);
