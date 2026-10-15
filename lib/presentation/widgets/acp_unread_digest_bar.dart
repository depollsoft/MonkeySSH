/// One-line "since you left" digest above the native chat composer.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_unread.dart';

/// Below this width the Jump action shows only its icon, giving the digest
/// about 70 pt more room on a phone.
const double _narrowBarWidth = 400;

/// Side of the square action buttons, the minimum touch target.
const double _actionSize = 48;

/// Leading padding, icon and gap before the digest text.
const double _leadingWidth =
    FluttyTheme.spacingMd - FluttyTheme.spacingXs + _iconSize + _iconGap;

const double _iconSize = 18;

/// The space after a count, as in "2 replies".
final RegExp _countGap = RegExp(r'(\d) ');
const double _iconGap = FluttyTheme.spacingSm;

/// Summarises what arrived since the user left a chat, with a jump to the
/// unread divider. It sits above the composer, in thumb reach.
///
/// The digest drops its breakdown of tool calls by kind before it would
/// wrap past two lines, and moves its actions below the text when even the
/// shorter line does not fit beside them, as at large text sizes.
class AcpUnreadDigestBar extends StatelessWidget {
  /// Creates a digest bar for [state].
  const AcpUnreadDigestBar({
    required this.state,
    required this.onJump,
    required this.onDismiss,
    super.key,
  });

  /// The unread divider and digest to describe.
  final AcpUnreadState state;

  /// Scrolls the transcript to the unread divider.
  final VoidCallback onJump;

  /// Hides the bar for the rest of this visit.
  final VoidCallback onDismiss;

  /// The sentence shown, with or without the tool calls' breakdown by
  /// kind. Screen readers always get it with the breakdown.
  static String messageFor(AcpUnreadState state, {bool toolKinds = true}) {
    final digest = state.digest;
    if (digest == null) return 'Can’t tell what changed since you left.';
    return 'Since you left: ${digest.summaryWith(toolKinds: toolKinds)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final known = state.digest != null;
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface);
    final spoken = messageFor(state);
    // A count never wraps away from what it counts.
    String keepCounts(String text) =>
        text.replaceAllMapped(_countGap, (match) => '${match[1]}\u00A0');
    final full = keepCounts(spoken);
    final short = keepCounts(messageFor(state, toolKinds: false));
    final jumpable = state.dividerEntryIndex != null;
    // With the history before it gone, the divider is at the top of what is
    // loaded, so the action says where it goes.
    final toTop = state.earlierHistoryUnavailable;
    final jumpLabel = toTop ? 'Top' : 'Jump';
    final jumpTooltip = toTop
        ? 'Jump to the oldest loaded message'
        : 'Jump to first unread';
    // Not a single up arrow, which is the composer's Send just below.
    final jumpIcon = toTop
        ? Icons.vertical_align_top
        : Icons.keyboard_double_arrow_up;

    Widget message({required int preferredLines, required int maxLines}) =>
        LayoutBuilder(
          builder: (context, constraints) {
            final shown =
                _fits(
                  context,
                  full,
                  style,
                  constraints.maxWidth,
                  maxLines: preferredLines,
                )
                ? full
                : short;
            return Semantics(
              label: spoken,
              excludeSemantics: true,
              child: Text(
                shown,
                key: const ValueKey('acp-unread-digest-text'),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            );
          },
        );

    final icon = Icon(
      known ? Icons.mark_chat_unread_outlined : Icons.history_toggle_off,
      size: _iconSize,
      color: scheme.onSurfaceVariant,
    );
    final dismiss = IconButton(
      tooltip: 'Dismiss',
      constraints: const BoxConstraints(
        minWidth: _actionSize,
        minHeight: _actionSize,
      ),
      icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
      onPressed: onDismiss,
    );
    final labelledJump = Tooltip(
      message: jumpTooltip,
      child: TextButton.icon(
        key: const ValueKey('acp-unread-jump'),
        style: TextButton.styleFrom(
          minimumSize: const Size(_actionSize, _actionSize),
        ),
        onPressed: onJump,
        icon: Icon(jumpIcon, size: 16),
        label: Text(jumpLabel),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingSm,
        6,
        FluttyTheme.spacingSm,
        0,
      ),
      // A live region announces the bar when it appears. The counts below
      // are separate nodes (explicitChildNodes), so the live region's label
      // stays the same while they grow and streaming output is not
      // re-announced.
      child: Semantics(
        container: true,
        liveRegion: true,
        explicitChildNodes: true,
        label: known
            ? 'Unread since you left'
            : 'Earlier history not available',
        // A tonal strip without a border, so it does not read as a second
        // input stacked on the composer.
        child: DecoratedBox(
          key: const ValueKey('acp-unread-digest'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < _narrowBarWidth;
              final jumpWidth = !jumpable
                  ? 0.0
                  : narrow
                  ? _actionSize
                  : _labelledJumpWidth(context, jumpLabel);
              final besideActions =
                  constraints.maxWidth -
                  _leadingWidth -
                  _actionSize -
                  jumpWidth;
              final inline = _fits(
                context,
                short,
                style,
                besideActions,
                maxLines: 3,
              );
              if (inline) {
                return Padding(
                  padding: const EdgeInsets.only(
                    left: FluttyTheme.spacingMd - FluttyTheme.spacingXs,
                  ),
                  child: Row(
                    children: [
                      icon,
                      const SizedBox(width: _iconGap),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: FluttyTheme.spacingXs,
                          ),
                          child: message(preferredLines: 2, maxLines: 3),
                        ),
                      ),
                      if (jumpable)
                        if (narrow)
                          IconButton(
                            key: const ValueKey('acp-unread-jump'),
                            tooltip: jumpTooltip,
                            constraints: const BoxConstraints(
                              minWidth: _actionSize,
                              minHeight: _actionSize,
                            ),
                            icon: Icon(
                              jumpIcon,
                              size: 18,
                              color: scheme.primary,
                            ),
                            onPressed: onJump,
                          )
                        else
                          labelledJump,
                      dismiss,
                    ],
                  ),
                );
              }
              // Too little room beside the actions: the text takes the full
              // width and the actions sit on their own row below it.
              return Padding(
                padding: const EdgeInsets.only(
                  left: FluttyTheme.spacingMd - FluttyTheme.spacingXs,
                  top: FluttyTheme.spacingSm + FluttyTheme.spacingXs,
                  right: FluttyTheme.spacingMd - FluttyTheme.spacingXs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        icon,
                        const SizedBox(width: _iconGap),
                        Expanded(
                          child: message(preferredLines: 3, maxLines: 8),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [if (jumpable) labelledJump, dismiss],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Whether [text] fits [width] in at most [maxLines] lines.
bool _fits(
  BuildContext context,
  String text,
  TextStyle? style,
  double width, {
  required int maxLines,
}) {
  if (width <= 0) return false;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
  )..layout(maxWidth: width);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// About how wide the labelled Jump button is: its label, a 16 pt icon, the
/// gap between them and the button's side padding at their unscaled
/// sizes, which only shrink as text grows.
double _labelledJumpWidth(BuildContext context, String label) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: Theme.of(context).textTheme.labelLarge),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width + 16 + 8 + 2 * 12;
  painter.dispose();
  return width < _actionSize ? _actionSize : width;
}
