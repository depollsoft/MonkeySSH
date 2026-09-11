import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';

/// Number of diff lines rendered before a show-more control is offered.
///
/// Bounds the number of line widgets built for very large diffs; each
/// show-more reveals another page of the same size.
const int kAcpDiffInitialLineCap = 200;

/// Maximum number of source characters split into lines. Source longer than
/// this is truncated to a bounded prefix before splitting so a multi-megabyte
/// diff (or a single enormous line) never allocates an unbounded line list.
const int kAcpDiffMaxSourceChars = 256 * 1024; // 256K characters

enum _DiffLineKind { addition, deletion, hunk, meta, context }

_DiffLineKind _classifyDiffLine(String line) {
  if (line.startsWith('@@')) {
    return _DiffLineKind.hunk;
  }
  if (line.startsWith('+++') ||
      line.startsWith('---') ||
      line.startsWith('diff ') ||
      line.startsWith('index ')) {
    return _DiffLineKind.meta;
  }
  if (line.startsWith('+')) {
    return _DiffLineKind.addition;
  }
  if (line.startsWith('-')) {
    return _DiffLineKind.deletion;
  }
  return _DiffLineKind.context;
}

/// Renders a unified diff as coloured, monospace lines.
///
/// Additions and deletions are conveyed with both a `+`/`-` prefix and a
/// background tint (never colour alone), avoiding nested cards and coloured
/// side stripes per the design system. Long lines scroll horizontally.
///
/// Large diffs are bounded: only [initialLineCap] lines are built initially,
/// with an accessible show-more/show-less control to reveal further pages, so
/// a huge diff never eagerly builds an unbounded number of line widgets.
class AcpDiffView extends StatefulWidget {
  /// Creates a diff view.
  const AcpDiffView({
    required this.diff,
    super.key,
    this.initialLineCap = kAcpDiffInitialLineCap,
    this.maxSourceChars = kAcpDiffMaxSourceChars,
  });

  /// The diff to render.
  final AcpDiff diff;

  /// Number of lines shown before the show-more control appears.
  final int initialLineCap;

  /// Maximum number of source characters split into lines; longer source is
  /// truncated to this bounded prefix with a visible truncation notice.
  final int maxSourceChars;

  @override
  State<AcpDiffView> createState() => _AcpDiffViewState();
}

class _AcpDiffViewState extends State<AcpDiffView> {
  late List<String> _lines;
  late int _visibleCount;
  late bool _sourceTruncated;

  @override
  void initState() {
    super.initState();
    _prepareSource();
  }

  @override
  void didUpdateWidget(AcpDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff ||
        oldWidget.initialLineCap != widget.initialLineCap ||
        oldWidget.maxSourceChars != widget.maxSourceChars) {
      _prepareSource();
    }
  }

  void _prepareSource() {
    final source = widget.diff.unifiedDiff;
    final maxChars = math.max(1, widget.maxSourceChars);
    _sourceTruncated = source.length > maxChars;
    // Only ever split the bounded prefix so the line list stays bounded even
    // for a multi-megabyte source or a single enormous line.
    final bounded = _sourceTruncated ? source.substring(0, maxChars) : source;
    _lines = bounded.split('\n');
    _visibleCount = _initialCount;
  }

  int get _cap => math.max(1, widget.initialLineCap);

  int get _cappedChars => math.max(1, widget.maxSourceChars);

  int get _initialCount => math.min(_cap, _lines.length);

  void _showMore() => setState(
    () => _visibleCount = math.min(_visibleCount + _cap, _lines.length),
  );

  void _showLess() => setState(() => _visibleCount = _initialCount);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final additionColor = isDark
        ? const Color(0xFF3FB950)
        : const Color(0xFF1A7F37);
    final deletionColor = scheme.error;
    final monoBase = AcpChatTypography.monoStyleOf(
      context,
    ).copyWith(fontSize: 12, height: 1.4);

    final rows = <Widget>[];
    final visible = math.min(_visibleCount, _lines.length);
    for (var i = 0; i < visible; i++) {
      final line = _lines[i];
      final kind = _classifyDiffLine(line);
      final Color? background;
      final Color color;
      switch (kind) {
        case _DiffLineKind.addition:
          background = additionColor.withValues(alpha: 0.14);
          color = additionColor;
        case _DiffLineKind.deletion:
          background = deletionColor.withValues(alpha: 0.14);
          color = deletionColor;
        case _DiffLineKind.hunk:
          background = null;
          color = scheme.primary;
        case _DiffLineKind.meta:
          background = null;
          color = scheme.onSurfaceVariant;
        case _DiffLineKind.context:
          background = null;
          color = scheme.onSurface;
      }
      rows.add(
        Container(
          color: background,
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingSm,
            vertical: 1,
          ),
          child: Text(
            line.isEmpty ? ' ' : line,
            style: monoBase.copyWith(color: color),
          ),
        ),
      );
    }

    final remaining = _lines.length - visible;
    final truncated = _lines.length > _cap;

    final semanticsLabel = _sourceTruncated
        ? 'Diff for ${widget.diff.path}, truncated, '
              'first ${_lines.length} lines'
        : 'Diff for ${widget.diff.path}, ${_lines.length} lines';

    return Semantics(
      label: semanticsLabel,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          border: Border.all(color: scheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                color: scheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(
                  horizontal: FluttyTheme.spacingSm,
                  vertical: 6,
                ),
                child: Text(
                  widget.diff.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AcpChatTypography.monoStyleOf(context).copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: rows,
                  ),
                ),
              ),
              if (_sourceTruncated) _DiffTruncationNotice(limit: _cappedChars),
              if (truncated)
                _DiffPagingFooter(
                  visible: visible,
                  total: _lines.length,
                  remaining: remaining,
                  onShowMore: remaining > 0 ? _showMore : null,
                  onShowLess: visible > _initialCount ? _showLess : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffTruncationNotice extends StatelessWidget {
  const _DiffTruncationNotice({required this.limit});

  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: 'Diff truncated because it exceeds $limit characters',
      container: true,
      child: Container(
        width: double.infinity,
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(
          horizontal: FluttyTheme.spacingSm,
          vertical: FluttyTheme.spacingXs,
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 14, color: scheme.tertiary),
            const SizedBox(width: FluttyTheme.spacingXs),
            Expanded(
              child: Text(
                'Diff truncated (very large)',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffPagingFooter extends StatelessWidget {
  const _DiffPagingFooter({
    required this.visible,
    required this.total,
    required this.remaining,
    required this.onShowMore,
    required this.onShowLess,
  });

  final int visible;
  final int total;
  final int remaining;
  final VoidCallback? onShowMore;
  final VoidCallback? onShowLess;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: FluttyTheme.spacingSm,
        vertical: FluttyTheme.spacingXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Showing $visible of $total lines',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (onShowLess != null)
            TextButton(onPressed: onShowLess, child: const Text('Show less')),
          if (onShowMore != null)
            TextButton(
              onPressed: onShowMore,
              child: Text('Show more lines ($remaining remaining)'),
            ),
        ],
      ),
    );
  }
}
