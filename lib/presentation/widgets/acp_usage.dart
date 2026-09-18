import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';

/// Renders token-usage and context-window metrics as unobtrusive, monospace
/// session metadata.
///
/// Renders nothing when [usage] carries no data.
class AcpUsageView extends StatelessWidget {
  /// Creates a usage view.
  const AcpUsageView({required this.usage, super.key});

  /// The usage metrics to render.
  final AcpUsage usage;

  String _formatTokens(int tokens) {
    if (tokens < 1000) {
      return '$tokens';
    }
    final thousands = tokens / 1000;
    final text = thousands >= 100 || thousands == thousands.roundToDouble()
        ? thousands.toStringAsFixed(0)
        : thousands.toStringAsFixed(1);
    return '${text}k';
  }

  @override
  Widget build(BuildContext context) {
    if (!usage.hasData) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = AcpChatTypography.monoStyleOf(context)
        .copyWith(fontSize: 11, color: scheme.onSurfaceVariant);

    final stats = <String>[];
    if (usage.inputTokens != null) {
      stats.add('↑ ${_formatTokens(usage.inputTokens!)}');
    }
    if (usage.outputTokens != null) {
      stats.add('↓ ${_formatTokens(usage.outputTokens!)}');
    }
    if (usage.totalTokens != null) {
      stats.add('Σ ${_formatTokens(usage.totalTokens!)}');
    }
    if (stats.isEmpty && usage.contextUsedTokens != null) {
      final used = usage.contextUsedTokens!;
      final window = usage.contextWindow;
      stats.add(
        window != null && window > 0
            ? '${_formatTokens(used)} / ${_formatTokens(window)} context'
            : '${_formatTokens(used)} context tokens',
      );
    }
    final fraction = usage.contextFraction;

    return Semantics(
      container: true,
      label:
          'Usage${fraction != null ? ', context '
                    '${(fraction * 100).round()} percent' : ''}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.data_usage_rounded,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: FluttyTheme.spacingXs),
          Flexible(
            child: Text(
              stats.join('   '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          if (fraction != null) ...[
            const SizedBox(width: FluttyTheme.spacingSm),
            SizedBox(
              width: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 4,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
            ),
            const SizedBox(width: FluttyTheme.spacingXs),
            Text('${(fraction * 100).round()}%', style: labelStyle),
          ],
        ],
      ),
    );
  }
}
