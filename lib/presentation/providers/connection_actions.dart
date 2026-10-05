import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/monkeymux_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart';

/// Disconnects [connectionId] and drops the tmux and MonkeyMux caches that
/// were keyed on it.
///
/// Every disconnect path must clear both multiplexer caches before the
/// session goes away, or a later connection that reuses the same host can
/// observe stale window snapshots. Call this instead of repeating the three
/// steps at each call site.
Future<void> disconnectConnectionAndClearMuxCaches(
  WidgetRef ref,
  int connectionId,
) async {
  await ref.read(tmuxServiceProvider).clearCache(connectionId);
  await ref.read(monkeyMuxServiceProvider).clearCache(connectionId);
  await ref.read(activeSessionsProvider.notifier).disconnect(connectionId);
}
