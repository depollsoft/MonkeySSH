import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/host_repository.dart';
import '../models/host_notifications.dart';

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
