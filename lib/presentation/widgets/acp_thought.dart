import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_inline_image.dart';
import 'acp_markdown.dart';

/// Renders an assistant thought / reasoning group, collapsed by default.
///
/// The header shows a stream-aware label (`Thinking…` while streaming) and a
/// disclosure control. Expansion uses an [AnimatedSize] whose duration honours
/// the platform reduced-motion setting.
class AcpThoughtView extends StatefulWidget {
  /// Creates a thought view.
  const AcpThoughtView({
    required this.entry,
    super.key,
    this.initiallyExpanded = false,
    this.onTapLink,
    this.imageResolver,
  });

  /// The thought entry to render.
  final AcpThoughtEntry entry;

  /// Whether the thought is expanded initially. Defaults to collapsed.
  ///
  /// Turning it on after the view is built expands the thought too, which is
  /// how transcript search reveals a match inside it.
  final bool initiallyExpanded;

  /// Optional custom link handler forwarded to the inner Markdown.
  final void Function(String text, String? href, String title)? onTapLink;

  /// Optional image resolver forwarded to the inner Markdown.
  final AcpImageResolver? imageResolver;

  @override
  State<AcpThoughtView> createState() => _AcpThoughtViewState();
}

class _AcpThoughtViewState extends State<AcpThoughtView> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant AcpThoughtView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded && !oldWidget.initiallyExpanded) {
      _expanded = true;
    }
  }

  String get _headerLabel {
    if (widget.entry.status == AcpStreamStatus.streaming) {
      return 'Thinking…';
    }
    return widget.entry.title ?? 'Thought';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final streaming = widget.entry.status == AcpStreamStatus.streaming;

    return Semantics(
      container: true,
      label: 'Reasoning, $_headerLabel',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluttyTheme.spacingSm,
                  vertical: FluttyTheme.spacingSm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: Text(
                        _headerLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: streaming
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            _ThoughtBody(
              reduceMotion: reduceMotion,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FluttyTheme.spacingSm,
                        0,
                        FluttyTheme.spacingSm,
                        FluttyTheme.spacingSm,
                      ),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(color: scheme.onSurfaceVariant),
                        child: AcpMarkdown(
                          data: widget.entry.markdown,
                          onTapLink: widget.onTapLink,
                          imageResolver: widget.imageResolver,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reveals thought content, animating the size change only when the platform
/// allows motion (an [AnimatedSize] with a zero duration is invalid).
class _ThoughtBody extends StatelessWidget {
  const _ThoughtBody({required this.reduceMotion, required this.child});

  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) {
      return child;
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      alignment: Alignment.topCenter,
      curve: Curves.easeOut,
      child: child,
    );
  }
}
