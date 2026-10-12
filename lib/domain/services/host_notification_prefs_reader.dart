import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/host_repository.dart';
import '../models/host_notifications.dart';
import 'push/push_event.dart';

/// Reads a saved host's notification preferences at the moment a
/// notification is about to show. A host that is gone or cannot be read
/// allows everything, as before per-host preferences existed.
final hostNotificationPrefsReaderProvider =
    Provider<Future<HostNotificationPrefs> Function(int hostId)>((ref) {
      final repository = ref.watch(hostRepositoryProvider);
      return (hostId) async {
        try {
          final host = await repository.getById(hostId);
          return host == null
              ? const HostNotificationPrefs()
              : HostNotificationPrefs.fromHost(host);
        } on Object {
          return const HostNotificationPrefs();
        }
      };
    });

/// A saved host's notification preferences as they change, for code that
/// must decide synchronously, such as the window bar keeping its alerts in
/// order with their close requests. A host that is gone allows everything.
final hostNotificationPrefsProvider =
    StreamProvider.family<HostNotificationPrefs, int>((ref, hostId) {
      final repository = ref.watch(hostRepositoryProvider);
      return repository.watchAll().map((hosts) {
        for (final host in hosts) {
          if (host.id == hostId) return HostNotificationPrefs.fromHost(host);
        }
        return const HostNotificationPrefs();
      });
    });

/// Whether a host's preferences allow a push of [kind]. An `alert` from a
/// helper that names its [alertCategories] shows when any of them is on;
/// one from an older helper, which does not say, shows only while both
/// window alerts and shell notifications are on. A test is always allowed.
bool pushKindAllowedByHost(
  PushEventKind kind,
  HostNotificationPrefs prefs, {
  Set<String>? alertCategories,
}) => switch (kind) {
  PushEventKind.permission || PushEventKind.input => prefs.agentAttention,
  PushEventKind.finished => prefs.agentFinished,
  PushEventKind.alert => switch (alertCategories) {
    final Set<String> categories when categories.isNotEmpty =>
      (categories.contains('bell') && prefs.windowAlerts) ||
          (categories.contains('notice') && prefs.shellNotifications),
    _ => prefs.windowAlerts && prefs.shellNotifications,
  },
  PushEventKind.test => true,
};
