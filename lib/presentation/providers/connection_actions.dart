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
///
/// The services are read before the first await, so the caller may unmount
/// while the disconnect is in flight. A caller that can already be unmounted
/// should hold the services and call [disconnectAndClearMuxCaches].
Future<void> disconnectConnectionAndClearMuxCaches(
  WidgetRef ref,
  int connectionId,
) => disconnectAndClearMuxCaches(
  connectionId,
  tmuxService: ref.read(tmuxServiceProvider),
  monkeyMuxService: ref.read(monkeyMuxServiceProvider),
  sessions: ref.read(activeSessionsProvider.notifier),
);

/// [disconnectConnectionAndClearMuxCaches] for callers that hold the services,
/// such as a widget that may be unmounted by the time it disconnects.
Future<void> disconnectAndClearMuxCaches(
  int connectionId, {
  required TmuxService tmuxService,
  required MonkeyMuxService monkeyMuxService,
  required ActiveSessionsNotifier sessions,
}) async {
  await tmuxService.clearCache(connectionId);
  await monkeyMuxService.clearCache(connectionId);
  await sessions.disconnect(connectionId);
}
