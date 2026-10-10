import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../widgets/cursor_block.dart';

/// State of the SOCKS route behind the in-app browser.
enum SocksBrowserRouteStatus {
  /// Starting the forward or pointing the browser at it.
  connecting,

  /// Pages load through the forward.
  ready,

  /// The forward stopped; the browser blocks pages.
  down,

  /// This device cannot route the browser through SOCKS.
  unsupported,
}

/// Full-surface status for a SOCKS browser that cannot load pages right now.
///
/// It is opaque so a page that loaded before the forward dropped is never
/// mistaken for a live one.
class SocksBrowserStatusPanel extends StatelessWidget {
  /// Creates a status panel.
  const SocksBrowserStatusPanel({
    required this.status,
    required this.forwardName,
    this.message,
    this.onRestart,
    this.onClose,
    super.key,
  });

  /// Route state to describe; [SocksBrowserRouteStatus.ready] renders nothing.
  final SocksBrowserRouteStatus status;

  /// Saved name of the SOCKS forward.
  final String forwardName;

  /// Extra detail, such as why the forward did not start.
  final String? message;

  /// Restarts the forward from the down state.
  final VoidCallback? onRestart;

  /// Closes the browser.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (title, body) = switch (status) {
      SocksBrowserRouteStatus.connecting => (
        'starting tunnel',
        'Routing the browser through $forwardName.',
      ),
      SocksBrowserRouteStatus.down => (
        'tunnel down',
        '$forwardName stopped, so this browser blocks pages instead of '
            'loading them over this device’s network.',
      ),
      SocksBrowserRouteStatus.unsupported => (
        'socks browsing unavailable',
        message ?? 'This device can’t route the browser through SOCKS.',
      ),
      SocksBrowserRouteStatus.ready => ('', ''),
    };
    if (status == SocksBrowserRouteStatus.ready) {
      return const SizedBox.shrink();
    }
    final detail = status == SocksBrowserRouteStatus.down ? message : null;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FluttyTheme.spacingLg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Semantics(
              liveRegion: true,
              container: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status == SocksBrowserRouteStatus.connecting)
                    const CursorBlock(size: 28)
                  else
                    Icon(
                      status == SocksBrowserRouteStatus.down
                          ? Icons.link_off_rounded
                          : Icons.info_outline_rounded,
                      size: 32,
                      color: status == SocksBrowserRouteStatus.down
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                  const SizedBox(height: FluttyTheme.spacingMd),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: FluttyTheme.displayMono(
                      fontSize: 16,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: FluttyTheme.spacingSm),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: FluttyTheme.spacingSm),
                    Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: FluttyTheme.spacingLg),
                  if (onRestart != null &&
                      status == SocksBrowserRouteStatus.down) ...[
                    FilledButton.icon(
                      onPressed: onRestart,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Restart forward'),
                    ),
                    const SizedBox(height: FluttyTheme.spacingSm),
                  ],
                  // Always offered, including while a connection attempt
                  // runs: the browser opens as a full-screen dialog with no
                  // swipe-back on iOS. Outlined, so the restart stays the one
                  // teal action.
                  if (onClose != null)
                    OutlinedButton(
                      onPressed: onClose,
                      child: const Text('Close browser'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// First screen of a SOCKS browser, shown until the first address loads.
class SocksBrowserStartPanel extends StatelessWidget {
  /// Creates the start panel.
  const SocksBrowserStartPanel({
    required this.forwardName,
    required this.port,
    this.hostLabel,
    super.key,
  });

  /// Saved name of the SOCKS forward.
  final String forwardName;

  /// Loopback port the browser routes through.
  final int? port;

  /// Saved label of the host that relays the pages.
  final String? hostLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final host = hostLabel?.trim().isNotEmpty ?? false ? hostLabel! : null;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FluttyTheme.spacingLg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'browse via $forwardName',
                  style: FluttyTheme.displayMono(
                    fontSize: 18,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  'Pages load from ${host ?? 'the host'}’s network, and the '
                  'host resolves their names. Enter an address it can reach, '
                  'such as http://10.0.0.5:8080.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  children: [
                    Icon(
                      Icons.lan_outlined,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Flexible(
                      child: Text(
                        port == null
                            ? 'routed · socks5'
                            : 'routed · socks5 127.0.0.1:$port',
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 12,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  'If the forward stops, pages are blocked rather than '
                  'loaded directly.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
