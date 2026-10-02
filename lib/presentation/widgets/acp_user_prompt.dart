import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_audio_player.dart';
import 'acp_chat_typography.dart';
import 'acp_inline_image.dart';
import 'acp_resource_chip.dart';

/// Renders a user prompt, preserving the order of its content parts.
///
/// Text parts render as selectable text, image parts render inline via
/// [AcpInlineImage], audio parts render as an [AcpAudioPlayer], and
/// file/resource parts render as [AcpResourceChip]s — the prompt is never
/// flattened to a single string.
class AcpUserPromptView extends StatelessWidget {
  /// Creates a user prompt view.
  const AcpUserPromptView({
    required this.entry,
    super.key,
    this.imageResolver,
    this.onTapImage,
    this.onOpenResource,
    this.onCopyResource,
    this.parts,
    this.segmentIndex,
    this.segmentCount,
  });

  /// The prompt entry to render.
  final AcpUserPromptEntry entry;

  /// Resolver for non-inline image parts.
  final AcpImageResolver? imageResolver;

  /// Called when an image part is tapped.
  final ValueChanged<AcpImageContent>? onTapImage;

  /// Called when a resource part is opened.
  final ValueChanged<AcpResourceRef>? onOpenResource;

  /// Called when a resource part is copied.
  final ValueChanged<AcpResourceRef>? onCopyResource;

  /// Ordered content rendered by this virtual segment.
  final List<AcpPromptPart>? parts;

  /// Zero-based virtual segment index, when this prompt is split.
  final int? segmentIndex;

  /// Total virtual segment count, when this prompt is split.
  final int? segmentCount;

  Widget _buildPart(BuildContext context, AcpPromptPart part) {
    switch (part) {
      case AcpTextPart(:final text):
        final theme = Theme.of(context);
        return SelectableText(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontSize: 15,
            height: 1.5,
          ),
        );
      case AcpImagePart(:final image):
        return Align(
          alignment: Alignment.centerLeft,
          child: AcpInlineImage(
            image: image,
            resolver: imageResolver,
            onTap: onTapImage,
          ),
        );
      case AcpAudioPart(:final clip):
        return Align(
          alignment: Alignment.centerLeft,
          child: AcpAudioPlayer(clip: clip),
        );
      case AcpResourcePart(:final resource):
        return Align(
          alignment: Alignment.centerLeft,
          child: AcpResourceChip(
            resource: resource,
            onOpen: onOpenResource,
            onCopy: onCopyResource,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visibleParts = parts ?? entry.parts;
    final index = segmentIndex;
    final count = segmentCount;
    final isFirstSegment = index == null || index == 0;
    final isLastSegment = index == null || count == null || index == count - 1;
    const radius = Radius.circular(FluttyTheme.radiusMd);
    final segmentDescription = index != null && count != null
        ? ', part ${index + 1} of $count'
        : '';

    return Semantics(
      container: true,
      label: entry.queued && isFirstSegment
          ? 'Your message, queued$segmentDescription'
          : 'Your message$segmentDescription',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.vertical(
            top: isFirstSegment ? radius : Radius.zero,
            bottom: isLastSegment ? radius : Radius.zero,
          ),
          border: Border.all(color: scheme.outline),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            14,
            isFirstSegment ? 14 : FluttyTheme.spacingSm,
            14,
            isLastSegment ? 14 : FluttyTheme.spacingSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.queued && isFirstSegment) ...[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FluttyTheme.spacingSm,
                      vertical: FluttyTheme.spacingXs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 13,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: FluttyTheme.spacingXs),
                        Text(
                          'queued',
                          style: AcpChatTypography.monoStyleOf(context)
                              .copyWith(
                                color: scheme.onPrimaryContainer,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingSm),
              ],
              for (var i = 0; i < visibleParts.length; i++) ...[
                if (i > 0) const SizedBox(height: FluttyTheme.spacingSm),
                _buildPart(context, visibleParts[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
