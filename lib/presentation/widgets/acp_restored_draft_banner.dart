import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../controllers/acp_composer_controller.dart';

/// Marks a composer draft that came back after the app was closed, so the
/// user knows it is still unsent.
class AcpRestoredDraftBanner extends StatelessWidget {
  /// Creates a restored-draft banner.
  const AcpRestoredDraftBanner({
    required this.notice,
    required this.onDismiss,
    super.key,
  });

  /// What was restored.
  final AcpRestoredDraftNotice notice;

  /// Hides the banner; the draft stays in the composer.
  final VoidCallback onDismiss;

  /// The banner's explanatory line for [notice].
  static String detailFor(AcpRestoredDraftNotice notice) {
    final unavailable = notice.unavailableAttachmentCount;
    final attachments = switch (unavailable) {
      <= 0 => '',
      1 => ' 1 attachment couldn’t be restored and was removed.',
      _ => ' $unavailable attachments couldn’t be restored and were removed.',
    };
    return 'Saved when MonkeySSH closed. Not sent yet.$attachments';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        // Hairline only, no fill: the note annotates the draft below and
        // stays quieter than the composer it describes.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: FluttyTheme.spacingMd,
          top: FluttyTheme.spacingXs,
          bottom: FluttyTheme.spacingXs,
        ),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.edit_note_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: FluttyTheme.spacingXs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'unsent draft restored',
                      style: FluttyTheme.monoStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detailFor(notice),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Hide notice',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
