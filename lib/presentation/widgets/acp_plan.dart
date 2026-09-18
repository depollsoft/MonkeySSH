import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';

/// Presentation helpers for [AcpPlanItemStatus].
extension AcpPlanItemStatusPresentation on AcpPlanItemStatus {
  /// Icon representing the item status.
  IconData get icon => switch (this) {
    AcpPlanItemStatus.pending => Icons.radio_button_unchecked,
    AcpPlanItemStatus.inProgress => Icons.adjust,
    AcpPlanItemStatus.completed => Icons.check_circle,
  };
}

/// Renders an ACP plan as a compact progress surface: a header with a
/// completion count and progress bar, followed by status-tagged items.
///
/// Status is conveyed with an icon and text, never colour alone.
class AcpPlanView extends StatelessWidget {
  /// Creates a plan view.
  const AcpPlanView({required this.plan, super.key});

  /// The plan to render.
  final AcpPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = plan.totalCount;
    final completed = plan.completedCount;

    return Semantics(
      container: true,
      label: 'Plan, $completed of $total complete',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          border: Border.all(color: scheme.outline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(FluttyTheme.spacingSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.checklist_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: FluttyTheme.spacingSm),
                  Expanded(
                    child: Text(
                      'Plan',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$completed/$total',
                    style: AcpChatTypography.monoStyleOf(context)
                        .copyWith(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              if (total > 0) ...[
                const SizedBox(height: FluttyTheme.spacingSm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: plan.progress,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                  ),
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingSm),
              for (final item in plan.items) _PlanItemRow(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanItemRow extends StatelessWidget {
  const _PlanItemRow({required this.item});

  final AcpPlanItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final completed = item.status == AcpPlanItemStatus.completed;
    final inProgress = item.status == AcpPlanItemStatus.inProgress;
    final iconColor = completed || inProgress
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(item.status.icon, size: 15, color: iconColor),
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text(
              item.title,
              style: theme.textTheme.bodySmall?.copyWith(
                color: completed ? scheme.onSurfaceVariant : scheme.onSurface,
                decoration: completed
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
                fontWeight: inProgress ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
