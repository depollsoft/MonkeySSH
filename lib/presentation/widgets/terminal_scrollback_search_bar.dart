import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

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
      // Past the cap the matches kept are those around the viewport, so a
      // position among them would not say where a match is in the buffer.
      if (search.isCapped) {
        return '$count+';
      }
      final current = search.currentIndex;
      return current == null ? '$count' : '${current + 1}/$count';
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
      if (search.isCapped) {
        return 'More than $count matches';
      }
      final current = search.currentIndex;
      return current == null
          ? '$count matches'
          : 'Match ${current + 1} of $count';
  }
}

/// Height the find bar covers of the terminal view at the bottom of a
/// terminal area whose media query is [data]: the bar at [data]'s text
/// scale plus the bottom safe-area padding it adds, less [reservedBottom],
/// space at the bottom of the area the terminal view already leaves free
/// (the tmux bar's handle).
double terminalSearchBarObscuredHeight(
  MediaQueryData data, {
  double reservedBottom = 0,
}) => math.max(
  0,
  TerminalScrollbackSearchBar.heightFor(data.textScaler) +
      data.padding.bottom -
      reservedBottom,
);

// The query's font size and line height. Both are fixed here so the bar's
// height can be worked out before it is laid out.
const _queryFontSize = 14.0;
const _queryLineHeight = 1.5;
// The query field is at least a 48 px tap target, with at least this much
// room above and below the text.
const _fieldMinHeight = 48.0;
const _fieldMinTextPadding = 4.0;
const _barVerticalPadding = 6.0;

TextScaler _barTextScaler(TextScaler system) =>
    system.clamp(maxScaleFactor: TerminalScrollbackSearchBar.maxTextScale);

// Rounded up: text layout rounds the line's height to whole pixels.
double _queryLineExtent(TextScaler barTextScaler) =>
    (barTextScaler.scale(_queryFontSize) * _queryLineHeight).ceilToDouble();

double _fieldTextPadding(double lineExtent) =>
    math.max(_fieldMinTextPadding, (_fieldMinHeight - lineExtent) / 2);

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
    this.reservedBottom = 0,
    super.key,
  });

  /// Space at the bottom of the area the terminal view already leaves free,
  /// such as the tmux bar's handle; see [terminalSearchBarObscuredHeight].
  final double reservedBottom;

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
      obscuredBottom: terminalSearchBarObscuredHeight(
        MediaQuery.of(context),
        reservedBottom: reservedBottom,
      ),
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
/// Enter steps up, Shift+Enter steps down and Escape closes the bar. Back is
/// left to the screen, which closes the bar before anything else.
class TerminalScrollbackSearchBar extends StatefulWidget {
  /// Creates the find bar for [controller].
  const TerminalScrollbackSearchBar({
    required this.controller,
    required this.onClose,
    this.onRevealRow,
    super.key,
  });

  /// Height of the bar at the default text size, excluding any bottom
  /// safe-area padding. Large text makes it taller; see [heightFor].
  static const height = 60.0;

  /// Largest text scale the bar follows. Past it the bar's text stops
  /// growing, so the bar never takes over a phone's terminal.
  static const maxTextScale = 2.0;

  /// Height of the bar when the system text scale is [textScaler], excluding
  /// any bottom safe-area padding. It is [height] up to about 1.9x, where
  /// the query line no longer fits the 48 px field.
  static double heightFor(TextScaler textScaler) {
    final line = _queryLineExtent(_barTextScaler(textScaler));
    return line + 2 * _fieldTextPadding(line) + 2 * _barVerticalPadding;
  }

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
    extends State<TerminalScrollbackSearchBar>
    implements TerminalSearchFieldEditor {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.query,
  );
  final _fieldFocusNode = FocusNode(debugLabel: 'terminal-search-field');
  late int _handledRevealRequest = widget.controller.revealRequest;
  late int _handledUserUpdate = widget.controller.userUpdateCount;
  late int _handledFocusRequest = widget.controller.focusRequest;
  // Announce status changes the user caused (a new search or a step), not the
  // count updates that streaming output brings.
  bool _announceStatus = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleSearchChanged);
    widget.controller.fieldInput.attach(this);
    _fieldFocusNode.addListener(_handleFieldFocusChanged);
    // Autofocus does nothing while the terminal holds focus, and the menu
    // that opened the bar hands focus back to the terminal first. Without
    // this the query, and Enter, would go to the remote shell. Only when find
    // opens: a bar rebuilt after a native chat leaves focus where it is.
    if (!widget.controller.initialFocusDone) {
      widget.controller.initialFocusDone = true;
      _focusFieldAfterFrame();
    }
  }

  void _focusFieldAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fieldFocusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant TerminalScrollbackSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleSearchChanged);
      widget.controller.addListener(_handleSearchChanged);
      oldWidget.controller.fieldInput.detach(this);
      widget.controller.fieldInput.attach(this);
      // Its listeners rebuild, so they hear of the focus after this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleFieldFocusChanged();
        }
      });
      _handledRevealRequest = widget.controller.revealRequest;
      _handledUserUpdate = widget.controller.userUpdateCount;
      _text.text = widget.controller.query;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleSearchChanged);
    widget.controller.fieldInput.detach(this);
    _fieldFocusNode
      ..removeListener(_handleFieldFocusChanged)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  void _handleFieldFocusChanged() => widget.controller.fieldInput
      .fieldFocusChanged(hasFocus: _fieldFocusNode.hasFocus);

  @override
  void insertText(String text) {
    if (text.isEmpty) {
      return;
    }
    final value = _text.value;
    final length = value.text.length;
    final selection = value.selection;
    final start = selection.isValid ? selection.start.clamp(0, length) : length;
    final end = selection.isValid ? selection.end.clamp(start, length) : start;
    _text.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    // A change made here, not by typing, does not call onChanged.
    widget.controller.setQuery(_text.text);
    _fieldFocusNode.requestFocus();
  }

  @override
  void sendSpecialKey(TerminalKey key) {
    final search = widget.controller;
    switch (key) {
      case TerminalKey.escape:
        widget.onClose();
        return;
      case TerminalKey.enter || TerminalKey.arrowUp || TerminalKey.pageUp:
        search.showPrevious();
      case TerminalKey.arrowDown || TerminalKey.pageDown:
        search.showNext();
      case TerminalKey.arrowLeft:
        _moveCaret(forward: false);
      case TerminalKey.arrowRight:
        _moveCaret(forward: true);
      case TerminalKey.home:
        _text.selection = const TextSelection.collapsed(offset: 0);
      case TerminalKey.end:
        _text.selection = TextSelection.collapsed(offset: _text.text.length);
      default:
        // Tab and the rest mean nothing in a one-line query.
        break;
    }
    _fieldFocusNode.requestFocus();
  }

  /// Moves the caret one character, or collapses a selection to the edge it
  /// moves towards, as a text field does for the arrow keys.
  void _moveCaret({required bool forward}) {
    final text = _text.text;
    final selection = _text.selection;
    if (!selection.isValid) {
      _text.selection = TextSelection.collapsed(offset: text.length);
      return;
    }
    if (!selection.isCollapsed) {
      _text.selection = TextSelection.collapsed(
        offset: forward ? selection.end : selection.start,
      );
      return;
    }
    final range = CharacterRange.at(text, selection.baseOffset);
    final moved = forward ? range.moveNext() : range.moveBack();
    if (!moved) {
      return;
    }
    _text.selection = TextSelection.collapsed(
      offset: forward
          ? selection.baseOffset + range.current.length
          : selection.baseOffset - range.current.length,
    );
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
    if (search.focusRequest != _handledFocusRequest) {
      _handledFocusRequest = search.focusRequest;
      _focusFieldAfterFrame();
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
    final systemTextScaler = MediaQuery.textScalerOf(context);
    final queryLine = _queryLineExtent(_barTextScaler(systemTextScaler));

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
          fontSize: _queryFontSize,
          height: _queryLineHeight,
          color: colorScheme.onSurface,
        ),
        onChanged: search.setQuery,
        // The keyboard's Search key steps up like Enter and keeps the
        // keyboard up, instead of closing it (which would also resize the
        // terminal).
        onSubmitted: (_) => search.showPrevious(),
        onEditingComplete: () {},
        decoration: InputDecoration(
          // A bad or runaway pattern turns the field red, with the reason
          // spelled out beside the query.
          enabledBorder: errorBorder,
          focusedBorder: errorBorder,
          isDense: true,
          hintText: hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            fontSize: _queryFontSize,
            height: _queryLineHeight,
            color: colorScheme.onSurfaceVariant,
          ),
          constraints: const BoxConstraints(minHeight: _fieldMinHeight),
          // Large text eats into the padding before the field grows, so the
          // bar keeps its height up to about 1.9x.
          contentPadding: EdgeInsets.symmetric(
            vertical: _fieldTextPadding(queryLine),
          ),
          prefixIcon: _SearchOptionsButton(
            search: search,
            onClose: _fieldFocusNode.requestFocus,
          ),
          prefixIconConstraints: const BoxConstraints.tightFor(
            width: 48,
            height: 48,
          ),
          suffixIcon: _SearchStatus(search: search, announce: _announceStatus),
          suffixIconConstraints: const BoxConstraints(minHeight: 48),
        ),
      ),
    );

    return Material(
      key: const ValueKey<String>('terminal-search-bar'),
      color: colorScheme.surface,
      shape: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: TerminalScrollbackSearchBar.heightFor(systemTextScaler),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: _barVerticalPadding,
            ),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: TerminalScrollbackSearchBar.maxTextScale,
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
  const _SearchOptionsButton({required this.search, required this.onClose});

  final TerminalScrollbackSearchController search;

  /// Called when the menu closes, to give focus back to the field.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: TerminalMenuStyles.menuStyle(context),
    onClose: onClose,
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
            // Shrinks to fit large text, so both labels stay readable.
            : FittedBox(
                fit: BoxFit.scaleDown,
                child: DecoratedBox(
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
    // The count grows less than the query, which keeps the room it needs
    // at large text sizes. Screen readers get the full status.
    final textScaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: 1.5);
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
            textScaler: textScaler,
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
