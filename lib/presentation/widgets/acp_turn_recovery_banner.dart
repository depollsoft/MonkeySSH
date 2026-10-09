/// Offers a submitted prompt back after its turn ended without a reply.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../controllers/acp_turn_recovery.dart';

/// A compact notice above the composer with an Edit action.
///
/// After a stop it offers the prompt back for editing. After a lost answer it
/// says the agent may still have run the prompt and offers no one-tap resend,
/// because sending it again could repeat what the agent already did.
class AcpTurnRecoveryBanner extends StatelessWidget {
  /// Creates a recovery banner.
  const AcpTurnRecoveryBanner({
    required this.recovery,
    required this.onEdit,
    required this.onDismiss,
    super.key,
  });

  /// The prompts that can be restored.
  final AcpTurnRecovery recovery;

  /// Puts the prompts back into the draft.
  final VoidCallback onEdit;

  /// Hides the banner without restoring anything.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final plural = recovery.drafts.length > 1;
    final (icon, iconColor, message) = switch (recovery.kind) {
      AcpTurnRecoveryKind.cancelled => (
        Icons.stop_circle_outlined,
        scheme.onSurfaceVariant,
        'Turn stopped.',
      ),
      AcpTurnRecoveryKind.unconfirmed => (
        Icons.sync_problem,
        scheme.tertiary,
        plural
            ? 'No reply arrived. The agent may have run these anyway.'
            : 'No reply arrived. The agent may have run this anyway.',
      ),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('acp-turn-recovery-banner'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          FluttyTheme.spacingXs,
          FluttyTheme.spacingXs,
          FluttyTheme.spacingXs,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('acp-turn-recovery-edit'),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              onPressed: onEdit,
              child: Text(plural ? 'Edit prompts' : 'Edit prompt'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
