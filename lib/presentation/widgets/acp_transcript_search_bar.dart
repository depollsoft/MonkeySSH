/// Find bar shown above a native agent chat transcript.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../controllers/acp_transcript_search_controller.dart';
import '../models/acp_transcript_search.dart';
import 'acp_chat_typography.dart';

/// A compact search field with match count, older/newer navigation and the
/// active match's context, placed at the bottom of the chat in thumb reach.
///
/// The arrows follow the transcript: up moves to older messages, down to
/// newer ones. Return also moves to the next older match, since a new search
/// starts at the newest one.
class AcpTranscriptSearchBar extends StatefulWidget {
  /// Creates a search bar bound to [controller].
  const AcpTranscriptSearchBar({required this.controller, super.key});

  /// The search state to display and drive.
  final AcpTranscriptSearchController controller;

  @override
  State<AcpTranscriptSearchBar> createState() => _AcpTranscriptSearchBarState();
}

class _AcpTranscriptSearchBarState extends State<AcpTranscriptSearchBar> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.query,
  );
  late final FocusNode _focus = FocusNode(onKeyEvent: _handleKey);

  AcpTranscriptSearchController get _search => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _search.close();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        _submit(newer: HardwareKeyboard.instance.isShiftPressed);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Shows the first result of a search still waiting for typing to pause,
  /// otherwise steps to the next older (or, with [newer], newer) match.
  void _submit({bool newer = false}) {
    if (!_search.isSettled) {
      _search.searchNow();
    } else if (newer) {
      _search.next();
    } else {
      _search.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: _search,
      builder: (context, _) {
        final result = _search.result;
        final count = result.matches.length;
        final active = _search.activeIndex;
        final hasQuery = _search.query.trim().isNotEmpty;
        final canStep = count > 0;
        return Material(
          key: const ValueKey('acp-transcript-search-bar'),
          color: scheme.surfaceContainerHigh,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                FluttyTheme.spacingXs,
                FluttyTheme.spacingXs,
                FluttyTheme.spacingXs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasQuery && _search.isSettled)
                    _MatchContext(
                      match: _search.activeMatch,
                      empty: count == 0,
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('acp-transcript-search-field'),
                          controller: _text,
                          focusNode: _focus,
                          onChanged: _search.setQuery,
                          onSubmitted: (_) => _submit(),
                          textInputAction: TextInputAction.search,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search chat',
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            prefixIcon: Icon(
                              Icons.search,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 44,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      if (hasQuery)
                        Semantics(
                          liveRegion: true,
                          label: count == 0
                              ? 'No matches'
                              : 'Match ${(active ?? 0) + 1} of '
                                    '${result.capped ? 'more than ' : ''}'
                                    '$count',
                          child: ExcludeSemantics(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: FluttyTheme.spacingXs,
                              ),
                              child: Text(
                                count == 0
                                    ? '0/0'
                                    : '${(active ?? 0) + 1}/$count'
                                          '${result.capped ? '+' : ''}',
                                key: const ValueKey(
                                  'acp-transcript-search-count',
                                ),
                                style: AcpChatTypography.monoStyleOf(context)
                                    .copyWith(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      _BarButton(
                        key: const ValueKey('acp-transcript-search-older'),
                        tooltip: 'Older match',
                        icon: Icons.keyboard_arrow_up_rounded,
                        onPressed: canStep ? _search.previous : null,
                      ),
                      _BarButton(
                        key: const ValueKey('acp-transcript-search-newer'),
                        tooltip: 'Newer match',
                        icon: Icons.keyboard_arrow_down_rounded,
                        onPressed: canStep ? _search.next : null,
                      ),
                      _BarButton(
                        key: const ValueKey('acp-transcript-search-close'),
                        tooltip: 'Close search',
                        icon: Icons.close,
                        onPressed: _search.close,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: EdgeInsets.zero,
    icon: Icon(icon, size: 22),
  );
}

/// One line of context for the active match, or why there is none.
class _MatchContext extends StatelessWidget {
  const _MatchContext({required this.match, required this.empty});

  final AcpTranscriptMatch? match;
  final bool empty;

  static String _label(AcpTranscriptMatchSource source) => switch (source) {
    AcpTranscriptMatchSource.user => 'you',
    AcpTranscriptMatchSource.agent => 'agent',
    AcpTranscriptMatchSource.reasoning => 'reasoning',
    AcpTranscriptMatchSource.tool => 'tool',
    AcpTranscriptMatchSource.plan => 'plan',
    AcpTranscriptMatchSource.status => 'status',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final current = match;
    final Widget content;
    if (empty || current == null) {
      content = Text(
        'No matches in the loaded transcript',
        key: const ValueKey('acp-transcript-search-empty'),
        style: muted,
      );
    } else {
      final snippet = current.snippet;
      content = Row(
        children: [
          Text(
            _label(current.source),
            style: AcpChatTypography.monoStyleOf(context)
                .copyWith(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: snippet.before),
                  TextSpan(
                    text: snippet.match,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                      backgroundColor: scheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  TextSpan(text: snippet.after),
                ],
              ),
              key: const ValueKey('acp-transcript-search-snippet'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingXs,
        0,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingXs,
      ),
      child: content,
    );
  }
}
