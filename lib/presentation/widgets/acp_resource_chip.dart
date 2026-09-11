import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';

/// Formats a byte [size] into a short human-readable string.
String formatResourceSize(int size) {
  if (size < 1024) {
    return '$size B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = size / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = value >= 10 || value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

/// A compact chip representing a file or resource reference.
///
/// Shows the display name in monospace, optional MIME/size metadata, and
/// exposes open (tap) and copy actions. Path text uses the mono voice per the
/// design system.
class AcpResourceChip extends StatelessWidget {
  /// Creates a resource chip.
  const AcpResourceChip({
    required this.resource,
    super.key,
    this.onOpen,
    this.onCopy,
  });

  /// The resource to render.
  final AcpResourceRef resource;

  /// Called when the chip body is tapped (e.g. to open the resource).
  final ValueChanged<AcpResourceRef>? onOpen;

  /// Called after the resource URI is copied to the clipboard.
  final ValueChanged<AcpResourceRef>? onCopy;

  IconData get _icon {
    final mime = resource.mimeType ?? '';
    if (mime.startsWith('image/')) {
      return Icons.image_outlined;
    }
    if (mime.startsWith('text/') ||
        mime.contains('json') ||
        mime.contains('xml')) {
      return Icons.description_outlined;
    }
    final uri = resource.uri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      return Icons.link_rounded;
    }
    return Icons.insert_drive_file_outlined;
  }

  String? get _metadata {
    final parts = <String>[];
    final mime = resource.mimeType;
    if (mime != null && mime.isNotEmpty) {
      parts.add(mime);
    }
    final size = resource.sizeBytes;
    if (size != null && size >= 0) {
      parts.add(formatResourceSize(size));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: resource.uri));
    onCopy?.call(resource);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final metadata = _metadata;

    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FluttyTheme.spacingSm,
        vertical: 6,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: FluttyTheme.spacingSm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  resource.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AcpChatTypography.monoStyleOf(context).copyWith(
                    fontSize: 12,
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (metadata != null)
                  Text(
                    metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    final onOpen = this.onOpen;
    return Semantics(
      label:
          'File ${resource.displayName}'
          '${metadata != null ? ', $metadata' : ''}',
      button: onOpen != null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: onOpen == null
                  ? body
                  : InkWell(
                      onTap: () => onOpen(resource),
                      borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
                      child: body,
                    ),
            ),
            Tooltip(
              message: 'Copy path',
              child: InkWell(
                onTap: _copy,
                borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.all(FluttyTheme.spacingSm),
                  child: Icon(
                    Icons.copy_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                    semanticLabel: 'Copy path',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
