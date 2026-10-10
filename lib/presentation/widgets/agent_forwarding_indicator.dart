import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/services/ssh_agent_forwarding.dart';

/// The terminal title, with a badge after it while the connection forwards
/// the SSH agent.
///
/// The badge reads as a key icon plus a mono `ssh-agent` label, never colour
/// alone, and disappears once forwarding stops on the connection. The title
/// gives way first in a narrow title bar, then the label, leaving the key
/// icon at a 44-point tap target; with less room than that the badge hides
/// rather than shrink or overflow. Tapping it explains what the host can do
/// and how many signatures it has made.
class AgentForwardingTitleSlot extends StatelessWidget {
  /// Creates an [AgentForwardingTitleSlot].
  const AgentForwardingTitleSlot({
    required this.title,
    required this.forwarding,
    super.key,
  });

  /// The terminal title.
  final Widget title;

  /// The forwarding serving this connection, or null when there is none.
  final SshAgentForwarding? forwarding;

  // The label shows once the title keeps at least this much room beside it.
  static const _titleRoomForLabel = 80.0;
  static const _labelBadgeWidth = 88.0;
  // The smallest tap target the badge is shown with; narrower, it hides.
  static const _iconBadgeWidth = 44.0;

  @override
  Widget build(BuildContext context) {
    final forwarding = this.forwarding;
    if (forwarding == null) {
      return title;
    }
    return ValueListenableBuilder<SshAgentForwardingStatus>(
      valueListenable: forwarding.status,
      builder: (context, status, _) {
        if (!status.serving) {
          return title;
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            if (width < _iconBadgeWidth) {
              return title;
            }
            final showLabel = width >= _labelBadgeWidth + _titleRoomForLabel;
            final badgeWidth = showLabel ? null : _iconBadgeWidth;
            return Row(
              children: [
                Expanded(child: title),
                SizedBox(
                  width: badgeWidth,
                  child: _AgentForwardingBadge(
                    forwarding: forwarding,
                    showLabel: showLabel,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _AgentForwardingBadge extends StatelessWidget {
  const _AgentForwardingBadge({
    required this.forwarding,
    required this.showLabel,
  });

  final SshAgentForwarding forwarding;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    void showDetails() => unawaited(
      showAgentForwardingDetailsSheet(context: context, forwarding: forwarding),
    );
    return Semantics(
      container: true,
      button: true,
      label: 'SSH agent forwarding on. Show details',
      onTap: showDetails,
      excludeSemantics: true,
      child: Tooltip(
        message: 'SSH agent forwarding on',
        excludeFromSemantics: true,
        child: InkWell(
          key: const Key('agent-forwarding-indicator'),
          borderRadius: BorderRadius.circular(8),
          onTap: showDetails,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outline),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.key_rounded,
                        size: 14,
                        color: colorScheme.onSurface,
                      ),
                      if (showLabel) ...[
                        const SizedBox(width: 4),
                        Text(
                          'ssh-agent',
                          maxLines: 1,
                          softWrap: false,
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 11,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains what agent forwarding allows on this connection.
Future<void> showAgentForwardingDetailsSheet({
  required BuildContext context,
  required SshAgentForwarding forwarding,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _AgentForwardingDetails(forwarding: forwarding),
);

class _AgentForwardingDetails extends StatelessWidget {
  const _AgentForwardingDetails({required this.forwarding});

  final SshAgentForwarding forwarding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: ValueListenableBuilder<SshAgentForwardingStatus>(
            valueListenable: forwarding.status,
            builder: (context, status, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'agent forwarding',
                  style: FluttyTheme.displayMono(
                    fontSize: 16,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  status.serving
                      ? 'This host can use your selected keys while this '
                            'connection stays open, including while MonkeySSH '
                            'is in the background. Forwarding ends when the '
                            'connection closes.'
                      : 'Forwarding has stopped on this connection.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                _DetailRow(
                  icon: status.confirmEachSignature
                      ? Icons.front_hand_outlined
                      : Icons.bolt_outlined,
                  text: status.confirmEachSignature
                      ? 'Each signature asks you first.'
                      : 'Signatures are not confirmed.',
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: Icons.draw_outlined,
                  count: status.signatureCount,
                  text: status.signatureCount == 1
                      ? ' signature on this connection.'
                      : ' signatures on this connection.',
                ),
                const SizedBox(height: 16),
                Text(
                  'Turn it off, choose keys or change confirmation in the '
                  'host settings. Changes apply to this connection too.',
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text, this.count});

  final IconData icon;
  final String text;

  /// Leading numeral, set in mono.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = this.count;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                if (count != null)
                  TextSpan(
                    text: '$count',
                    style: FluttyTheme.monoStyle.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                TextSpan(text: text),
              ],
            ),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
