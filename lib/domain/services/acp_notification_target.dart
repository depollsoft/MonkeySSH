import '../models/acp_session_keys.dart';
import '../models/remote_multiplexer.dart';
import '../models/tmux_state.dart';
import 'diagnostics_log_service.dart';
import 'ssh_service.dart';

/// Finds the open connection whose MonkeyMux workspace owns a native window.
/// Prefers the connection already showing the chat when several share a
/// workspace, but verifies window membership before trusting saved focus.
Future<int?> resolveAcpNotificationConnection({
  required AcpSessionKey target,
  required Iterable<SshSession> sessions,
  required Future<List<TmuxWindow>> Function(SshSession, String) listWindows,
}) async {
  final candidates =
      sessions.where((session) => session.hostId == target.hostId).toList()
        ..sort((a, b) {
          final aFocused = a.activeNativeAcpSessionKey == target;
          final bFocused = b.activeNativeAcpSessionKey == target;
          if (aFocused == bFocused) return 0;
          return aFocused ? -1 : 1;
        });
  for (final session in candidates) {
    final workspace = session.remoteMuxSessionName;
    if (session.remoteMuxBackend != RemoteMuxBackend.monkeyMux ||
        workspace == null ||
        workspace.isEmpty) {
      continue;
    }
    try {
      final windows = await listWindows(session, workspace);
      if (windows.any(
        (window) =>
            window.nativeAcpBridgeId == target.bridgeId &&
            window.nativeAcpProviderId == target.providerId,
      )) {
        return session.connectionId;
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.notification',
        'window_lookup_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }
  for (final session in candidates) {
    if (session.activeNativeAcpSessionKey == target) {
      return session.connectionId;
    }
  }
  return null;
}
