import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../controllers/acp_composer_controller.dart';

/// Marks a composer draft that came back from storage, so the user knows it
/// is still unsent and which attachments did not come back.
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

  /// Lost attachments named before the rest are only counted.
  static const _namedLimit = 2;

  /// Longest attachment name shown in full; longer ones keep their start and
  /// their extension.
  static const _nameLimit = 32;

  /// The banner's heading for [notice].
  static String headlineFor(AcpRestoredDraftNotice notice) =>
      notice.draftRestored
      ? 'unsent draft restored'
      : 'unsent draft not restored';

  /// The banner's explanatory line for [notice].
  static String detailFor(AcpRestoredDraftNotice notice) =>
      _detailParts(notice).map((part) => part.text).join();

  /// [detailFor] in parts, with attachment names marked so they can be set
  /// apart.
  static List<({String text, bool isName})> _detailParts(
    AcpRestoredDraftNotice notice,
  ) {
    final parts = <({String text, bool isName})>[];
    void plain(String text) => parts.add((text: text, isName: false));
    if (notice.fromEarlierRun) plain('Saved before MonkeySSH closed.');
    final count = notice.unavailableAttachmentCount;
    if (count <= 0) return parts;
    if (parts.isNotEmpty) plain(' ');
    final names = notice.unavailableAttachmentNames
        .take(count.clamp(0, _namedLimit))
        .map(_shortName)
        .toList(growable: false);
    final others = count - names.length;
    if (names.isEmpty) {
      plain(count == 1 ? '1 attachment' : '$count attachments');
    } else {
      for (var i = 0; i < names.length; i++) {
        if (i > 0) plain(i == names.length - 1 && others == 0 ? ' and ' : ', ');
        parts.add((text: names[i], isName: true));
      }
      if (others > 0) plain(' and $others more');
    }
    plain(
      count == 1
          ? ' couldn’t be restored and was removed.'
          : ' couldn’t be restored and were removed.',
    );
    return parts;
  }

  static String _shortName(String name) {
    final characters = name.characters;
    if (characters.length <= _nameLimit) return name;
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot).characters : null;
    final tail = extension != null && extension.length <= 8
        ? extension
        : characters.skip(characters.length - 8);
    return '${characters.take(_nameLimit - tail.length - 1)}…$tail';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = _detailParts(notice);
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
                      headlineFor(notice),
                      style: FluttyTheme.monoStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            for (final part in detail)
                              TextSpan(
                                text: part.text,
                                // Names as the attachment strip shows them.
                                style: part.isName
                                    ? TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      )
                                    : null,
                              ),
                          ],
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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
