import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// The MonkeySSH branded error state: a calm, serious placeholder for a
/// recoverable load failure, with a mono title, one plain line of context, and
/// a single retry affordance.
///
/// Unlike [BrandEmptyState], this surface carries **no wit** — it is reached
/// when something the user relies on failed, so it stays dead serious. Status
/// is conveyed by an icon plus text (never color alone), and the icon is muted
/// rather than alarm-red because the failure is recoverable.
class BrandErrorState extends StatelessWidget {
  /// Creates a [BrandErrorState].
  const BrandErrorState({
    required this.title,
    this.message,
    this.onRetry,
    this.icon = Icons.error_outline_rounded,
    super.key,
  });

  /// Mono title stating the failure plainly, e.g. `couldn't load keys`.
  final String title;

  /// Optional plain line of context beneath the title.
  final String? message;

  /// Retry handler. When null, no retry button is shown.
  final VoidCallback? onRetry;

  /// Leading status icon.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FluttyTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: colorScheme.onSurface.withAlpha(150)),
            const SizedBox(height: FluttyTheme.spacingMd),
            Text(
              title,
              textAlign: TextAlign.center,
              style: FluttyTheme.displayMono(
                fontSize: 16,
                color: colorScheme.onSurface.withAlpha(230),
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: FluttyTheme.spacingSm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withAlpha(170),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: FluttyTheme.spacingLg),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
