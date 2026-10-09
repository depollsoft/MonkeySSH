import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import 'terminal_menu_style.dart';
import 'terminal_scrollback_search.dart';

/// Short status for the search bar: the match position, or why there is
/// none. Returns null when there is nothing to show.
String? describeTerminalSearchStatus(
  TerminalScrollbackSearchController search,
) {
  switch (search.status) {
    case TerminalSearchStatus.idle:
      return null;
    case TerminalSearchStatus.invalidPattern:
      return 'invalid';
    case TerminalSearchStatus.tooSlow:
      return 'too slow';
    case TerminalSearchStatus.failed:
      return 'failed';
    case TerminalSearchStatus.searching:
    case TerminalSearchStatus.ready:
      final count = search.matchCount;
      if (count == 0) {
        return search.status == TerminalSearchStatus.searching ? '…' : '0';
      }
      final total = search.isCapped ? '$count+' : '$count';
      final current = search.currentIndex;
      return current == null ? total : '${current + 1}/$total';
  }
}

/// Spoken status for the search bar, announced as it changes.
String? describeTerminalSearchStatusForSemantics(
  TerminalScrollbackSearchController search,
) {
  switch (search.status) {
    case TerminalSearchStatus.idle:
      return null;
    case TerminalSearchStatus.invalidPattern:
      return 'Invalid regular expression';
    case TerminalSearchStatus.tooSlow:
      return 'Search stopped: the regular expression took too long';
    case TerminalSearchStatus.failed:
      return 'Search failed';
    case TerminalSearchStatus.searching:
    case TerminalSearchStatus.ready:
      final count = search.matchCount;
      if (count == 0) {
        return search.status == TerminalSearchStatus.searching
            ? 'Searching'
            : 'No matches';
      }
      final total = search.isCapped ? 'more than $count' : '$count';
      final current = search.currentIndex;
      return current == null
          ? '$total matches'
          : 'Match ${current + 1} of $total';
  }
}

/// Lays the find bar for [search] over the bottom edge of [child], the
/// terminal area, and scrolls the terminal to each match it reveals. Shows
/// [child] alone when [search] is null.
class TerminalScrollbackSearchOverlay extends StatelessWidget {
  /// Creates the overlay.
  const TerminalScrollbackSearchOverlay({
    required this.search,
    required this.scrollController,
    required this.lineHeight,
    required this.onClose,
    required this.child,
    super.key,
  });

  /// The open search, or null when find is closed.
  final TerminalScrollbackSearchController? search;

  /// Scroll controller of the terminal view.
  final ScrollController scrollController;

  /// Returns the terminal's row height in pixels.
  final double Function() lineHeight;

  /// Called when the user closes the bar.
  final VoidCallback onClose;

  /// The terminal area.
  final Widget child;

  void _reveal(BuildContext context, int row) {
    if (!scrollController.hasClients) {
      return;
    }
    final position = scrollController.position;
    final target = resolveTerminalSearchRevealOffset(
      row: row,
      lineHeight: lineHeight(),
      viewportExtent: position.viewportDimension,
      currentOffset: position.pixels,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      obscuredBottom: TerminalScrollbackSearchBar.height,
    );
    if (target == null) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      scrollController.jumpTo(target);
      return;
    }
    unawaited(
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = this.search;
    if (search == null) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: TerminalScrollbackSearchBar(
            controller: search,
            onClose: onClose,
            onRevealRow: (row) => _reveal(context, row),
          ),
        ),
      ],
    );
  }
}

/// Find bar for the terminal scrollback.
///
/// It overlays the bottom edge of the terminal, right above the keyboard
/// toolbar, so it stays in thumb reach and the terminal keeps its size (a
/// resize would make the remote program redraw).
///
/// Up steps to older matches and down to newer ones. On a hardware keyboard,
/// Enter steps up, Shift+Enter steps down and Escape closes the bar.
class TerminalScrollbackSearchBar extends StatefulWidget {
  /// Creates the find bar for [controller].
  const TerminalScrollbackSearchBar({
    required this.controller,
    required this.onClose,
    this.onRevealRow,
    super.key,
  });

  /// Height of the bar, excluding any bottom safe-area padding.
  static const height = 60.0;

  /// The search this bar drives.
  final TerminalScrollbackSearchController controller;

  /// Called when the user closes the bar.
  final VoidCallback onClose;

  /// Called with the buffer row of the current match when the terminal should
  /// scroll to it.
  final ValueChanged<int>? onRevealRow;

  @override
  State<TerminalScrollbackSearchBar> createState() =>
      _TerminalScrollbackSearchBarState();
}

class _TerminalScrollbackSearchBarState
    extends State<TerminalScrollbackSearchBar> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.query,
  );
  final _fieldFocusNode = FocusNode(debugLabel: 'terminal-search-field');
  late int _handledRevealRequest = widget.controller.revealRequest;
  late int _handledUserUpdate = widget.controller.userUpdateCount;
  // Announce status changes the user caused (a new search or a step), not the
  // count updates that streaming output brings.
  bool _announceStatus = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleSearchChanged);
  }

  @override
  void didUpdateWidget(covariant TerminalScrollbackSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleSearchChanged);
      widget.controller.addListener(_handleSearchChanged);
      _handledRevealRequest = widget.controller.revealRequest;
      _handledUserUpdate = widget.controller.userUpdateCount;
      _text.text = widget.controller.query;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleSearchChanged);
    _text.dispose();
    _fieldFocusNode.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    if (!mounted) {
      return;
    }
    final search = widget.controller;
    final revealed = search.revealRequest != _handledRevealRequest;
    if (revealed) {
      _handledRevealRequest = search.revealRequest;
      final row = search.currentMatchRow;
      if (row != null) {
        widget.onRevealRow?.call(row);
      }
    }
    final userUpdated = search.userUpdateCount != _handledUserUpdate;
    _handledUserUpdate = search.userUpdateCount;
    setState(() {
      _announceStatus =
          userUpdated ||
          (search.status != TerminalSearchStatus.searching &&
              search.status != TerminalSearchStatus.ready);
    });
  }

  bool get _canStep => widget.controller.matchCount > 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final search = widget.controller;
    final errorBorder = _isErrorStatus(search.status)
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
            borderSide: BorderSide(color: colorScheme.error, width: 2),
          )
        : null;
    final hint = search.searchesAlternateScreen
        ? 'Find on screen'
        : 'Find in scrollback';

    final field = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): search.showPrevious,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            search.showPrevious,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            search.showNext,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
            search.showNext,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: TextField(
        key: const ValueKey<String>('terminal-search-field'),
        controller: _text,
        focusNode: _fieldFocusNode,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        textInputAction: TextInputAction.search,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 14,
          color: colorScheme.onSurface,
        ),
        onChanged: search.setQuery,
        decoration: InputDecoration(
          // A bad or runaway pattern turns the field red, with the reason
          // spelled out beside the query.
          enabledBorder: errorBorder,
          focusedBorder: errorBorder,
          isDense: true,
          hintText: hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          constraints: const BoxConstraints(minHeight: 48),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          prefixIcon: _SearchOptionsButton(search: search),
          prefixIconConstraints: const BoxConstraints.tightFor(
            width: 48,
            height: 48,
          ),
          suffixIcon: _SearchStatus(search: search, announce: _announceStatus),
          suffixIconConstraints: const BoxConstraints(minHeight: 48),
        ),
      ),
    );

    return PopScope(
      // Back closes the bar before it leaves the terminal.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          widget.onClose();
        }
      },
      child: Material(
        key: const ValueKey<String>('terminal-search-bar'),
        color: colorScheme.surface,
        shape: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: TerminalScrollbackSearchBar.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey<String>('terminal-search-previous'),
                    tooltip: 'Previous match',
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    onPressed: _canStep ? search.showPrevious : null,
                  ),
                  IconButton(
                    key: const ValueKey<String>('terminal-search-next'),
                    tooltip: 'Next match',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: _canStep ? search.showNext : null,
                  ),
                  // Keep Close clear of the step buttons a thumb is tapping.
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey<String>('terminal-search-close'),
                    tooltip: 'Close find',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _isErrorStatus(TerminalSearchStatus status) => switch (status) {
  TerminalSearchStatus.invalidPattern ||
  TerminalSearchStatus.tooSlow ||
  TerminalSearchStatus.failed => true,
  _ => false,
};

class _SearchOptionsButton extends StatelessWidget {
  const _SearchOptionsButton({required this.search});

  final TerminalScrollbackSearchController search;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: TerminalMenuStyles.menuStyle(context),
    menuChildren: [
      CheckboxMenuButton(
        key: const ValueKey<String>('terminal-search-match-case'),
        style: TerminalMenuStyles.itemButtonStyle(context),
        value: search.caseSensitive,
        onChanged: (value) => search.setCaseSensitive(value: value ?? false),
        child: const Text('Match case'),
      ),
      CheckboxMenuButton(
        key: const ValueKey<String>('terminal-search-regex'),
        style: TerminalMenuStyles.itemButtonStyle(context),
        value: search.regex,
        onChanged: (value) => search.setRegex(value: value ?? false),
        child: const Text('Regular expression'),
      ),
    ],
    builder: (context, menu, _) {
      final active = [if (search.caseSensitive) 'Aa', if (search.regex) '.*'];
      final colorScheme = Theme.of(context).colorScheme;
      return IconButton(
        key: const ValueKey<String>('terminal-search-options'),
        // Room for both option labels side by side.
        iconSize: 36,
        tooltip: active.isEmpty
            ? 'Search options'
            : 'Search options: ${[if (search.caseSensitive) 'match case', if (search.regex) 'regular expression'].join(', ')}',
        // Active options replace the icon, so the state is readable text on
        // the control that changes it, and the query keeps its width.
        icon: active.isEmpty
            ? const Icon(Icons.tune_rounded, size: 20)
            : DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outline),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 1,
                  ),
                  child: Text(
                    active.join(),
                    maxLines: 1,
                    softWrap: false,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 11,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      );
    },
  );
}

class _SearchStatus extends StatelessWidget {
  const _SearchStatus({required this.search, required this.announce});

  final TerminalScrollbackSearchController search;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = describeTerminalSearchStatus(search);
    final isError = _isErrorStatus(search.status);
    final mono = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: isError ? colorScheme.error : colorScheme.onSurfaceVariant,
    );
    final children = <Widget>[
      if (isError)
        Padding(
          padding: const EdgeInsets.only(left: 6, right: 2),
          child: Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: colorScheme.error,
          ),
        ),
      if (status != null)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            status,
            key: const ValueKey<String>('terminal-search-status'),
            style: mono,
          ),
        ),
    ];
    return Semantics(
      liveRegion: announce,
      label: describeTerminalSearchStatusForSemantics(search),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(left: 4, right: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}
