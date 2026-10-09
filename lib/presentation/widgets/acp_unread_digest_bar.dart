/// One-line "since you left" digest above the native chat composer.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_unread.dart';

/// Summarises what arrived since the user left a chat, with a jump to the
/// unread divider. It sits above the composer, in thumb reach.
class AcpUnreadDigestBar extends StatelessWidget {
  /// Creates a digest bar for [state].
  const AcpUnreadDigestBar({
    required this.state,
    required this.onJump,
    required this.onDismiss,
    super.key,
  });

  /// The unread divider and digest to describe.
  final AcpUnreadState state;

  /// Scrolls the transcript to the unread divider.
  final VoidCallback onJump;

  /// Hides the bar for the rest of this visit.
  final VoidCallback onDismiss;

  /// The sentence shown, and read by screen readers.
  static String messageFor(AcpUnreadState state) {
    final digest = state.digest;
    if (digest == null) {
      return 'Earlier history isn’t available, so what changed since you '
          'left can’t be shown.';
    }
    return 'Since you left: ${digest.summary}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = messageFor(state);
    final known = state.digest != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingSm,
        6,
        FluttyTheme.spacingSm,
        0,
      ),
      // A live region announces the bar when it appears. Its label stays the
      // same while counts grow, so streaming output is not re-announced.
      child: Semantics(
        container: true,
        liveRegion: true,
        label: known
            ? 'Unread since you left'
            : 'Earlier history not available',
        child: DecoratedBox(
          key: const ValueKey('acp-unread-digest'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: FluttyTheme.spacingMd),
            child: Row(
              children: [
                Icon(
                  known
                      ? Icons.mark_chat_unread_outlined
                      : Icons.history_toggle_off,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: Text(
                    message,
                    key: const ValueKey('acp-unread-digest-text'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Jump to first unread',
                  child: TextButton.icon(
                    key: const ValueKey('acp-unread-jump'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                    ),
                    onPressed: onJump,
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    label: const Text('Jump'),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
