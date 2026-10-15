/// Offers a submitted prompt back after its turn ended without a reply.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../controllers/acp_turn_recovery.dart';

/// A compact notice above the composer with an Edit action.
///
/// After a stop it offers the prompt back for editing. After a lost answer,
/// or an agent error once work had started, it says the agent may have acted
/// on the prompt and offers no one-tap resend, because sending it again could
/// repeat what the agent already did.
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
      AcpTurnRecoveryKind.failedMidTurn => (
        Icons.error_outline,
        scheme.error,
        'The agent failed partway through. Check what it did before sending '
            'this again.',
      ),
    };
    final editLabel = plural ? 'Edit prompts' : 'Edit prompt';
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
        child: AcpNoticeLayout(
          icon: Icon(icon, size: 18, color: iconColor),
          message: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
          ),
          actionLabels: [editLabel],
          actions: [
            TextButton(
              key: const ValueKey('acp-turn-recovery-edit'),
              // The accent on this raised surface falls short of AA in the
              // dark theme; weight carries the emphasis instead.
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: scheme.onSurface,
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: onEdit,
              child: Text(editLabel),
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

/// Lays out a composer notice: an icon, a message, then its actions.
///
/// The actions sit beside the message while it keeps a readable width. On a
/// narrow screen or at a large text size they move under it, right-aligned
/// and wrapping, so the message is never squeezed to a few characters a
/// line or pushed out of the notice.
class AcpNoticeLayout extends StatelessWidget {
  /// Creates a notice layout.
  const AcpNoticeLayout({
    required this.icon,
    required this.message,
    required this.actions,
    required this.actionLabels,
    super.key,
  });

  /// The notice's status icon, 18 logical pixels wide.
  final Widget icon;

  /// What happened, in the theme's small body style.
  final Widget message;

  /// Text buttons followed by a 44 pt dismiss button.
  final List<Widget> actions;

  /// The text buttons' labels, measured to decide whether the actions fit
  /// beside the message.
  final List<String> actionLabels;

  /// Narrowest the message may get beside the actions, before text
  /// scaling: about ten words of the small body style a line.
  static const double _minMessageWidth = 120;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final scaler = MediaQuery.textScalerOf(context);
      final stacked =
          width.isFinite &&
          width - _actionsWidth(context) - _leadingWidth <
              scaler.scale(_minMessageWidth);
      if (!stacked) {
        return Row(
          children: [
            icon,
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(child: message),
            ...actions,
          ],
        );
      }
      return Column(
        key: const ValueKey('acp-notice-stacked'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              top: FluttyTheme.spacingSm,
              right: FluttyTheme.spacingSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Centred on the first line of the message.
                SizedBox(height: _firstLineHeight(context), child: icon),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(child: message),
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          ),
        ],
      );
    },
  );

  double _firstLineHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final size = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 12);
    return math.max(18, size * (style?.height ?? 1.3));
  }

  /// Icon and the gap after it.
  static const double _leadingWidth = 18 + FluttyTheme.spacingSm;

  /// The actions' width in a row: each label with a text button's padding,
  /// then the 44 pt dismiss button.
  double _actionsWidth(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var total = 44.0;
    for (final label in actionLabels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: style?.copyWith(fontWeight: FontWeight.w700),
        ),
        textScaler: scaler,
        textDirection: direction,
        maxLines: 1,
      )..layout();
      total += math.max(64, painter.width + 24);
      painter.dispose();
    }
    return total;
  }
}
