import 'package:flutter/material.dart';

import '../../domain/models/acp_session_state.dart';
import 'acp_session_presentation.dart';
import 'mux_window_status_badge.dart';

/// Placeholder shown while a native window has no attached local session.
enum AcpMuxWindowFallback {
  /// A recent session that is not currently tracked.
  recent('recent', Icons.history),

  /// A native window whose local session has not attached yet.
  native('native', Icons.smart_toy_outlined);

  const AcpMuxWindowFallback(this.label, this.icon);

  /// Badge text.
  final String label;

  /// Badge icon.
  final IconData icon;
}

/// Compact waiting/running badge for a native ACP mux window.
class AcpMuxWindowStatusBadge extends StatelessWidget {
  /// Creates a badge for a live [session], or a [fallback] placeholder.
  const AcpMuxWindowStatusBadge({
    this.session,
    this.fallback = AcpMuxWindowFallback.recent,
    super.key,
  });

  /// Live session state. Null uses [fallback].
  final AcpSessionState? session;

  /// Status shown when the local ACP session has not attached yet.
  final AcpMuxWindowFallback fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = session == null
        ? AcpStatusDisplay(
            label: fallback.label,
            icon: fallback.icon,
            tone: AcpStatusTone.neutral,
          )
        : acpSessionMuxStatusDisplay(session!);
    final (foreground, background) = switch (display.tone) {
      AcpStatusTone.active => (
        theme.colorScheme.onPrimaryContainer,
        theme.colorScheme.primaryContainer,
      ),
      AcpStatusTone.warning => (
        theme.colorScheme.onTertiaryContainer,
        theme.colorScheme.tertiaryContainer,
      ),
      AcpStatusTone.error => (
        theme.colorScheme.onErrorContainer,
        theme.colorScheme.errorContainer,
      ),
      AcpStatusTone.neutral => (
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.surfaceContainerHighest,
      ),
    };

    return MuxWindowStatusBadge(
      semanticsLabel: 'native agent ${display.label}',
      label: display.label,
      icon: display.icon,
      foregroundColor: foreground,
      backgroundColor: background,
    );
  }
}
