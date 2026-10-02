import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../controllers/acp_composer_controller.dart';
import 'acp_resource_chip.dart';

/// A horizontal strip of the composer's ordered attachment drafts.
///
/// Each attachment is shown as an image thumbnail (when the bytes are already
/// in memory) or a compact file chip, with a remove control, an upload
/// progress indicator, and an accessible retry affordance when preparation
/// failed. It preserves attachment order and never nests cards.
class AcpAttachmentStrip extends StatelessWidget {
  /// Creates an attachment strip.
  const AcpAttachmentStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    super.key,
    this.enabled = true,
  });

  /// The ordered attachments to render.
  final List<AcpComposerAttachment> attachments;

  /// Called to remove the attachment with the given id.
  final ValueChanged<String> onRemove;

  /// Called to retry the failed attachment with the given id.
  final ValueChanged<String> onRetry;

  /// Whether the remove/retry controls are interactive.
  ///
  /// The strip is shown read-only while a prompt is being prepared, submitted,
  /// or streamed so the snapshotted draft cannot be mutated mid-flight.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingXs),
        itemCount: attachments.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: FluttyTheme.spacingSm),
        itemBuilder: (context, index) => _AttachmentTile(
          attachment: attachments[index],
          enabled: enabled,
          onRemove: () => onRemove(attachments[index].id),
          onRetry: () => onRetry(attachments[index].id),
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
    required this.enabled,
  });

  final AcpComposerAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = attachment.status == AcpComposerAttachmentStatus.failed;
    final uploading =
        attachment.status == AcpComposerAttachmentStatus.uploading;
    final sizeLabel = attachment.candidate.sizeBytes != null
        ? formatResourceSize(attachment.candidate.sizeBytes!)
        : null;

    return Semantics(
      label:
          'Attachment ${attachment.name}'
          '${failed ? ', failed to prepare' : ''}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
            border: Border.all(
              color: failed ? scheme.error : scheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingSm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Thumbnail(attachment: attachment),
                const SizedBox(width: FluttyTheme.spacingSm),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (uploading)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: FluttyTheme.spacingXs,
                          ),
                          child: LinearProgressIndicator(
                            value: attachment.progress,
                            minHeight: 3,
                          ),
                        )
                      else if (failed)
                        Text(
                          'Failed — tap retry',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.error,
                          ),
                        )
                      else if (sizeLabel != null)
                        Text(
                          sizeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (failed)
                  IconButton(
                    tooltip: 'Retry ${attachment.name}',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: enabled ? onRetry : null,
                  )
                else
                  IconButton(
                    tooltip: 'Remove ${attachment.name}',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: (enabled && !uploading) ? onRemove : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.attachment});

  final AcpComposerAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final candidate = attachment.candidate;
    Widget child;
    if (candidate is AcpMemoryAttachmentCandidate && attachment.isImage) {
      final cacheSize = (40 * MediaQuery.devicePixelRatioOf(context))
          .ceil()
          .clamp(40, 256);
      child = ClipRRect(
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm - 2),
        child: Image.memory(
          candidate.bytes,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _iconThumb(scheme),
        ),
      );
    } else {
      child = _iconThumb(scheme);
    }
    return SizedBox(width: 40, height: 40, child: child);
  }

  Widget _iconThumb(ColorScheme scheme) {
    final candidate = attachment.candidate;
    final IconData icon;
    if (attachment.isPastedText) {
      icon = Icons.notes_rounded;
    } else if (attachment.isImage) {
      icon = Icons.image_outlined;
    } else if (attachment.isAudio) {
      icon = Icons.audio_file_outlined;
    } else if (candidate.sourceKind == AcpAttachmentSourceKind.remoteFile) {
      icon = Icons.cloud_outlined;
    } else {
      icon = Icons.insert_drive_file_outlined;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm - 2),
      ),
      child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
    );
  }
}
