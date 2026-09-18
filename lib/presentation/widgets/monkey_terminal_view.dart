// Adapted from package:xterm 4.0.0 TerminalView internals to keep local
// terminal layout and trackpad/mobile gesture fixes. Keep this aligned with the
// pinned xterm dependency when upgrading.
// ignore_for_file: implementation_imports, public_member_api_docs, directives_ordering, always_put_required_named_parameters_first, cast_nullable_to_non_nullable, prefer_expression_function_bodies, sort_child_properties_last, use_if_null_to_convert_nulls_to_bools, avoid_bool_literals_in_conditional_expressions, avoid_setters_without_getters, prefer_int_literals, cascade_invocations, unnecessary_null_checks, invalid_use_of_internal_member

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        listEquals,
        mapEquals,
        visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/graphics_manager.dart';
import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

import 'monkey_terminal_gesture_handler.dart';
import 'monkey_terminal_scroll_gesture_handler.dart';
import 'terminal_key_input.dart';
import 'terminal_scroll_mouse_input.dart';
import 'terminal_selection_text.dart';
import 'terminal_wheel_scroll_calibrator.dart';

const _minimumFaintTextContrast = 4.5;
const _minimumCursorTextContrast = 4.5;
const _minimumCellTextContrast = 4.5;
const _minimumCellBackgroundContrast = 1.04;
const _maximumNeutralCellBackgroundContrast = 1.75;
const _backgroundAlphaCandidates = <int>[
  0x26,
  0x33,
  0x40,
  0x52,
  0x66,
  0x72,
  0x80,
  0x8F,
  0xA3,
  0xB8,
  0xCC,
];

/// A single Kitty Unicode-placeholder cell resolved for compositing.
///
/// Each cell carries both its on-screen position ([cellRow]/[cellCol]) and the
/// position it represents *within the source image* ([imgRow]/[imgCol], decoded
/// from the Kitty row/column diacritics). Painting per cell — rather than over a
/// single bounding region — keeps the image aligned even when it is partially
/// scrolled off, wrapped, or only sparsely redrawn by the application.
class _KittyPlaceholderCell {
  const _KittyPlaceholderCell({
    required this.imageKey,
    required this.imageId,
    required this.bitWidth,
    required this.cellRow,
    required this.cellCol,
    required this.imgRow,
    required this.imgCol,
  });

  final String imageKey;
  final int imageId;
  final int bitWidth;
  final int cellRow;
  final int cellCol;
  final int imgRow;
  final int imgCol;
}

/// Stride used to fold a (row, column) pair into a single int key. Larger than
/// any realistic terminal width or image column count so pairs never collide.
const _kittyGridStride = 100003;

/// Minimum density of live cells within their bounding box for a Kitty
/// Unicode-placeholder image to be composited. A solidly displayed image — or a
/// clean scroll crop where whole rows have scrolled off — fills its bounding box
/// (~1.0). A torn-down remnant, whose cells are overwritten in a scattered
/// pattern, leaves a box full of holes (well below this), so it is dismissed
/// rather than drawn as stale fragments/stripes.
const _kittyPlaceholderRenderThreshold = 0.85;

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}

bool _terminalThemesEqual(TerminalTheme a, TerminalTheme b) =>
    a.cursor == b.cursor &&
    a.selection == b.selection &&
    a.foreground == b.foreground &&
    a.background == b.background &&
    a.black == b.black &&
    a.red == b.red &&
    a.green == b.green &&
    a.yellow == b.yellow &&
    a.blue == b.blue &&
    a.magenta == b.magenta &&
    a.cyan == b.cyan &&
    a.white == b.white &&
    a.brightBlack == b.brightBlack &&
    a.brightRed == b.brightRed &&
    a.brightGreen == b.brightGreen &&
    a.brightYellow == b.brightYellow &&
    a.brightBlue == b.brightBlue &&
    a.brightMagenta == b.brightMagenta &&
    a.brightCyan == b.brightCyan &&
    a.brightWhite == b.brightWhite &&
    a.searchHitBackground == b.searchHitBackground &&
    a.searchHitBackgroundCurrent == b.searchHitBackgroundCurrent &&
    a.searchHitForeground == b.searchHitForeground &&
    mapEquals(a.paletteOverrides, b.paletteOverrides);

/// Resolves SGR 2 faint text while preserving readable contrast.
///
/// xterm paints faint text at 50% opacity, which drops many dark-theme
/// secondary labels below WCAG AA contrast. Keep 50% when it is readable, then
/// raise only as much as needed for the active foreground/background pair.
@visibleForTesting
Color resolveMonkeyTerminalFaintForegroundColor({
  required Color foreground,
  required Color background,
  double minimumContrast = _minimumFaintTextContrast,
}) {
  Color blendWithAlpha(double alpha) =>
      Color.alphaBlend(foreground.withAlpha((alpha * 255).round()), background);

  final defaultFaint = blendWithAlpha(0.5);
  if (_contrastRatio(defaultFaint, background) >= minimumContrast) {
    return defaultFaint;
  }

  if (_contrastRatio(foreground, background) < minimumContrast) {
    return foreground;
  }

  var low = 0.5;
  var high = 1.0;
  for (var iteration = 0; iteration < 12; iteration += 1) {
    final mid = (low + high) / 2;
    final candidate = blendWithAlpha(mid);
    if (_contrastRatio(candidate, background) >= minimumContrast) {
      high = mid;
    } else {
      low = mid;
    }
  }

  final readableFaint = blendWithAlpha(high);
  return _contrastRatio(readableFaint, background) >= minimumContrast
      ? readableFaint
      : foreground;
}

/// Resolves a readable glyph color for text covered by a focused block cursor.
@visibleForTesting
Color resolveMonkeyTerminalCursorForegroundColor({
  required Color cursor,
  required Color background,
  required Color foreground,
  Color? cellBackground,
  double minimumContrast = _minimumCursorTextContrast,
}) {
  final effectiveCellBackground = Color.alphaBlend(
    cellBackground ?? background,
    background,
  );
  final cursorBackground = Color.alphaBlend(cursor, effectiveCellBackground);
  Color resolveOpaque(Color color) =>
      Color.alphaBlend(color, effectiveCellBackground);

  final preferredCandidates = <Color>[
    if (cellBackground != null) resolveOpaque(cellBackground),
    resolveOpaque(background),
    resolveOpaque(foreground),
  ];

  for (final candidate in preferredCandidates) {
    if (_contrastRatio(candidate, cursorBackground) >= minimumContrast) {
      return candidate;
    }
  }

  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  final fallbackCandidates = <Color>[...preferredCandidates, black, white];

  return fallbackCandidates.reduce((best, candidate) {
    final bestContrast = _contrastRatio(best, cursorBackground);
    final candidateContrast = _contrastRatio(candidate, cursorBackground);
    return candidateContrast > bestContrast ? candidate : best;
  });
}

/// Resolves a readable paint color for explicit cell backgrounds.
@visibleForTesting
Color resolveMonkeyTerminalReadableBackgroundColor({
  required Color foreground,
  required Color background,
  required Color terminalBackground,
  double minimumTextContrast = _minimumCellTextContrast,
  double minimumBackgroundContrast = _minimumCellBackgroundContrast,
  double maximumNeutralBackgroundContrast =
      _maximumNeutralCellBackgroundContrast,
  bool toneNeutralBackgrounds = true,
}) {
  final effectiveForeground = Color.alphaBlend(foreground, terminalBackground);
  final effectiveBackground = Color.alphaBlend(background, terminalBackground);
  final textContrast = _contrastRatio(effectiveForeground, effectiveBackground);
  final backgroundContrast = _contrastRatio(
    effectiveBackground,
    terminalBackground,
  );
  // Neutral panels (for example a TUI composer surface that paints the same
  // gray behind muted hints, accent labels, and typed text) must resolve to a
  // single color across the whole panel. Their painted color must not depend on
  // the per-cell foreground: if it did, individual glyphs would blend the panel
  // toward the terminal background by different amounts and tear holes of
  // near-background colour into the surface (on a light theme this looks like
  // white patches behind the muted text). Resolve neutral backgrounds purely
  // from the panel/terminal relationship and leave glyph readability to the
  // foreground pass, which darkens or lightens the text against this same panel.
  if (toneNeutralBackgrounds && _isNeutralTerminalColor(background)) {
    if (backgroundContrast > maximumNeutralBackgroundContrast) {
      final neutralBackground = _resolveNeutralTerminalBackgroundColor(
        background: background,
        terminalBackground: terminalBackground,
        minimumBackgroundContrast: minimumBackgroundContrast,
        maximumBackgroundContrast: maximumNeutralBackgroundContrast,
      );
      if (neutralBackground != null) {
        return neutralBackground;
      }
    }
    return background;
  }

  if (textContrast >= minimumTextContrast) {
    return background;
  }

  if (_contrastRatio(effectiveForeground, terminalBackground) <
      minimumTextContrast) {
    return background;
  }

  for (final alpha in _backgroundAlphaCandidates) {
    final candidate = Color.alphaBlend(
      background.withAlpha(alpha),
      terminalBackground,
    );
    if (_contrastRatio(effectiveForeground, candidate) >= minimumTextContrast &&
        _contrastRatio(candidate, terminalBackground) >=
            minimumBackgroundContrast) {
      return candidate;
    }
  }

  return background;
}

Color? _resolveNeutralTerminalBackgroundColor({
  required Color background,
  required Color terminalBackground,
  required double minimumBackgroundContrast,
  required double maximumBackgroundContrast,
}) {
  for (final alpha in _backgroundAlphaCandidates.reversed) {
    final candidate = Color.alphaBlend(
      background.withAlpha(alpha),
      terminalBackground,
    );
    final contrast = _contrastRatio(candidate, terminalBackground);
    if (contrast >= minimumBackgroundContrast &&
        contrast <= maximumBackgroundContrast) {
      return candidate;
    }
  }
  return null;
}

bool _isNeutralTerminalColor(Color color) {
  final value = color.toARGB32();
  final red = (value >> 16) & 0xFF;
  final green = (value >> 8) & 0xFF;
  final blue = value & 0xFF;
  final maxChannel = math.max(red, math.max(green, blue));
  final minChannel = math.min(red, math.min(green, blue));
  return maxChannel - minChannel <= 24;
}

/// Resolves a readable paint color for text cells.
@visibleForTesting
Color resolveMonkeyTerminalReadableForegroundColor({
  required Color foreground,
  required Color background,
  required Color terminalForeground,
  required Color terminalBackground,
  double minimumContrast = _minimumCellTextContrast,
}) {
  if (_contrastRatio(foreground, background) >= minimumContrast) {
    return foreground;
  }

  if (_contrastRatio(terminalForeground, background) >= minimumContrast) {
    var low = 0.0;
    var high = 1.0;
    for (var iteration = 0; iteration < 12; iteration += 1) {
      final mid = (low + high) / 2;
      final candidate = Color.lerp(foreground, terminalForeground, mid)!;
      if (_contrastRatio(candidate, background) >= minimumContrast) {
        high = mid;
      } else {
        low = mid;
      }
    }

    final readableForeground = Color.lerp(
      foreground,
      terminalForeground,
      high,
    )!;
    return _contrastRatio(readableForeground, background) >= minimumContrast
        ? readableForeground
        : terminalForeground;
  }

  final candidates = <Color>[
    terminalForeground,
    terminalBackground,
    const Color(0xFF000000),
    const Color(0xFFFFFFFF),
  ];

  return candidates.reduce((best, candidate) {
    final bestContrast = _contrastRatio(best, background);
    final candidateContrast = _contrastRatio(candidate, background);
    return candidateContrast > bestContrast ? candidate : best;
  });
}

int _encodeRgbCellColor(Color color) =>
    (color.toARGB32() & CellColor.valueMask) | CellColor.rgb;

/// Terminal render padding.
///
/// Keep effective horizontal safe-area insets in landscape, but avoid adding
/// extra blank rows at the bottom or side gutters in portrait.
///
/// Some devices report larger lateral insets through [MediaQueryData.padding]
/// than [MediaQueryData.viewPadding] while the keyboard is visible. Use the
/// larger inset so the terminal stays aligned with the rest of the UI.
EdgeInsets resolveTerminalRenderPadding(MediaQueryData mediaQuery) {
  final viewportHeight = mediaQuery.size.height + mediaQuery.viewInsets.bottom;
  final isLandscape = mediaQuery.size.width > viewportHeight;
  if (!isLandscape) {
    return EdgeInsets.zero;
  }
  final leftInset = math.max(
    mediaQuery.padding.left,
    mediaQuery.viewPadding.left,
  );
  final rightInset = math.max(
    mediaQuery.padding.right,
    mediaQuery.viewPadding.right,
  );
  return EdgeInsets.only(left: leftInset, right: rightInset);
}

/// Whether terminal cell slack should be shifted off the trailing edges.
bool shouldAlignTerminalToTrailingEdges(MediaQueryData mediaQuery) {
  final viewportHeight = mediaQuery.size.height + mediaQuery.viewInsets.bottom;
  return mediaQuery.size.width > viewportHeight;
}

Widget _defaultSystemSelectionContextMenu(
  BuildContext _,
  SelectableRegionState selectableRegionState,
) => AdaptiveTextSelectionToolbar.selectableRegion(
  selectableRegionState: selectableRegionState,
);

/// Resolves the terminal grid origin inside the viewport.
@visibleForTesting
Offset resolveTerminalContentOrigin({
  required Size viewportSize,
  required Size cellSize,
  required int columns,
  required int rows,
  EdgeInsets padding = EdgeInsets.zero,
  bool alignToTrailingEdges = false,
}) {
  final availableWidth = math.max(0.0, viewportSize.width - padding.horizontal);
  final availableHeight = math.max(0.0, viewportSize.height - padding.vertical);
  final slackWidth = math.max(0.0, availableWidth - (columns * cellSize.width));
  final slackHeight = math.max(0.0, availableHeight - (rows * cellSize.height));
  return Offset(
    padding.left + (alignToTrailingEdges ? slackWidth : 0),
    padding.top + (alignToTrailingEdges ? slackHeight : 0),
  );
}

/// Terminal viewport padding applied outside the render object.
///
/// Horizontal safe-area insets are applied by the outer viewport container so
/// the terminal stays clear of cutouts while still filling the safe width.
EdgeInsets resolveTerminalViewportPadding(
  MediaQueryData mediaQuery, {
  EdgeInsets basePadding = EdgeInsets.zero,
}) {
  final renderPadding = resolveTerminalRenderPadding(mediaQuery);
  return EdgeInsets.fromLTRB(
    basePadding.left + renderPadding.left,
    basePadding.top + renderPadding.top,
    basePadding.right + renderPadding.right,
    basePadding.bottom + renderPadding.bottom,
  );
}

/// Slightly stretches the terminal horizontally to absorb the final remainder
/// when the viewport width does not divide evenly into whole cells.
@visibleForTesting
double resolveTerminalHorizontalFillScale({
  required double viewportWidth,
  required double cellWidth,
  required int columns,
}) {
  if (viewportWidth <= 0 || cellWidth <= 0 || columns <= 0) {
    return 1;
  }
  final contentWidth = cellWidth * columns;
  if (contentWidth <= 0) {
    return 1;
  }
  return (viewportWidth / contentWidth).clamp(1.0, 1.03);
}

/// Resolves the pixel dimensions to report with terminal resize events.
@visibleForTesting
({int width, int height}) resolveTerminalResizePixelDimensions({
  required Size viewportSize,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  final width = math.max(0.0, viewportSize.width - padding.horizontal);
  final height = math.max(0.0, viewportSize.height - padding.vertical);
  return (width: width.round(), height: height.round());
}

/// How long to wait for keyboard inset animations to settle before resizing.
@visibleForTesting
const terminalKeyboardResizeDebounceDuration = Duration(milliseconds: 180);

const _terminalFocusInReport = '\x1b[I';
const _terminalFocusOutReport = '\x1b[O';
const _terminalFocusTransitionDelay = Duration(milliseconds: 50);

/// A terminal cell range rendered with text underline decoration.
typedef TerminalTextUnderline = ({int row, int startColumn, int endColumn});

/// Adapted xterm terminal view with a trackpad scroll fix for alt-buffer apps.
class MonkeyTerminalView extends StatefulWidget {
  const MonkeyTerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.resizeTerminalToViewport = true,
    this.notifyPixelSizeChanges = true,
    this.focusNode,
    this.cursorFocusNode,
    this.autofocus = false,
    this.onTapDown,
    this.onTapUp,
    this.onDoubleTapDown,
    this.onLongPressStart,
    this.suppressLongPressDragSelection = false,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.resolveLinkTap,
    this.onLinkTapDown,
    this.onLinkTap,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.touchScrollToTerminal = false,
    this.forceSgrTouchScroll = false,
    this.scrollResetGeneration = 0,
    this.liveOutputAutoScroll = true,
    this.useSystemSelection = false,
    this.systemSelectionContextMenuBuilder,
    this.onSystemSelectionChanged,
    this.onInsertText,
    this.onPasteText,
    this.onUserInput,
    this.inlineUnderlines = const <TerminalTextUnderline>[],
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Whether viewport changes should resize the terminal buffer itself.
  ///
  /// Disable this when a shared remote PTY owns the grid size. Viewport changes
  /// are still reported through [Terminal.onResize], while this widget clips the
  /// remote grid to its local bounds.
  final bool resizeTerminalToViewport;

  /// Whether a viewport pixel-size change that leaves the cell grid unchanged
  /// should emit [Terminal.onResize]. Shared-grid multiplexers can disable this
  /// to avoid making a remote TUI redraw for a sub-cell keyboard/layout change.
  final bool notifyPixelSizeChanges;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// Optional focus node used only for cursor focus painting.
  ///
  /// This is useful when a parent widget owns text input focus while this
  /// widget still owns pointer and hardware-keyboard focus handling.
  final FocusNode? cursorFocusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps down on the terminal.
  final void Function(TapDownDetails, CellOffset)? onTapDown;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Callback for when the user double taps on the terminal.
  final void Function(TapDownDetails, CellOffset)? onDoubleTapDown;

  /// Callback for when the user long presses on the terminal.
  final void Function(LongPressStartDetails, CellOffset)? onLongPressStart;

  /// When true, the terminal's built-in drag-to-extend selection on touch
  /// long-press is suppressed. When no [onLongPressStart] override is
  /// provided, the initial word selection on long-press start still occurs,
  /// but subsequent move updates do not extend the selection.
  final bool suppressLongPressDragSelection;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// Resolves a tappable link for the tapped terminal cell, if any.
  final String? Function(CellOffset offset)? resolveLinkTap;

  /// Called when a primary tap is recognized as a pending link tap.
  final void Function(TapDownDetails, CellOffset)? onLinkTapDown;

  /// Called when a primary tap should open a resolved terminal link.
  final ValueChanged<String>? onLinkTap;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Preferred on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  /// If true, vertical touch drags are converted into terminal scroll input
  /// instead of scrolling the Flutter viewport.
  final bool touchScrollToTerminal;

  /// If true, sends SGR wheel reports even when local mouse mode state is stale.
  final bool forceSgrTouchScroll;

  /// Bump this value to reset transient scroll gesture state.
  final int scrollResetGeneration;

  /// If true, the terminal keeps the viewport pinned to the newest output while
  /// it is already scrolled to the bottom.
  final bool liveOutputAutoScroll;

  /// True when Flutter's [SelectableRegion] should own terminal selection
  /// gestures and handles.
  final bool useSystemSelection;

  /// Builds the context menu for system terminal selection.
  final SelectableRegionContextMenuBuilder? systemSelectionContextMenuBuilder;

  /// Called when system terminal selection changes.
  final ValueChanged<SelectedContent?>? onSystemSelectionChanged;

  /// Called before inserted text is sent to the terminal.
  final Future<bool> Function(String text)? onInsertText;

  /// Called to handle paste shortcuts before xterm pastes clipboard text.
  final Future<void> Function()? onPasteText;

  /// Called immediately before accepted user input is sent to the terminal.
  final VoidCallback? onUserInput;

  /// Cell ranges that should be painted with inline text underlines.
  final List<TerminalTextUnderline> inlineUnderlines;

  @override
  State<MonkeyTerminalView> createState() => MonkeyTerminalViewState();
}

class MonkeyTerminalViewState extends State<MonkeyTerminalView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  String? _composingText;
  ScrollHoldController? _directTouchScrollHold;
  Drag? _directTouchScrollDrag;
  Offset _lastTouchScrollPosition = Offset.zero;
  double _touchScrollRemainder = 0;
  final _touchWheelCalibrator = TerminalWheelScrollCalibrator();
  late bool _touchScrollIsAltBuffer;
  late MouseMode _touchScrollMouseMode;
  late MouseReportMode _touchScrollMouseReportMode;
  final ListQueue<
    ({TerminalMouseButton button, CellOffset position, int count})
  >
  _pendingTouchScrollRuns = ListQueue();
  bool _touchScrollDrainScheduled = false;
  int _touchScrollDispatchGeneration = 0;
  int _touchScrollBacklogFrames = 0;
  late final Ticker _touchScrollInertiaTicker;
  late final Ticker _graphicsAnimationTicker;
  Simulation? _touchScrollInertiaSimulation;
  double _lastTouchScrollInertiaOffset = 0;
  Duration _lastGraphicsAnimationElapsed = Duration.zero;
  bool _graphicsAnimationsEnabled = true;
  bool _graphicsAnimationSyncScheduled = false;
  bool? _lastLoggedGraphicsAnimationActive;
  int _graphicsAnimationFrameLogAtMs = 0;
  int _lastTerminalViewWidth = 0;
  Timer? _pendingFocusInReportTimer;

  late TerminalController _controller;

  late ScrollController _scrollController;

  /// Cached action map passed to the [Actions] widget. Allocated once in
  /// [initState] so each [build] reuses the same map and action objects.
  late final Map<Type, Action<Intent>> _terminalActions;

  MonkeyRenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as MonkeyRenderTerminal;

  MonkeyRenderTerminal? get _renderTerminalOrNull {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    return renderObject is MonkeyRenderTerminal ? renderObject : null;
  }

  /// Number of frames the live terminal has painted, or null if the render
  /// object is not currently attached. Exposed for window-switch diagnostics.
  int? get terminalPaintCount => _renderTerminalOrNull?.paintCount;

  /// Number of terminal change notifications the live render object has seen,
  /// or null if it is not attached. Exposed for window-switch diagnostics.
  int? get terminalChangeCount => _renderTerminalOrNull?.terminalChangeCount;

  /// Whether the Kitty graphics frame ticker is currently running.
  @visibleForTesting
  bool get graphicsAnimationTickerActive => _graphicsAnimationTicker.isActive;

  /// Current local viewport dimensions in terminal cells.
  ({int columns, int rows})? get viewportCellSize {
    final viewportSize = _renderTerminalOrNull?.viewportSize;
    if (viewportSize == null) {
      return null;
    }
    return (columns: viewportSize.width, rows: viewportSize.height);
  }

  /// Forces the live terminal to relayout and repaint its current buffer.
  /// Used as a safety net after a multiplexer window switch.
  void forceFullRepaint() => _renderTerminalOrNull?.forceFullRepaint();

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _scrollController.addListener(_handleViewportScrolled);
    _lastTerminalViewWidth = widget.terminal.viewWidth;
    _touchScrollIsAltBuffer = widget.terminal.isUsingAltBuffer;
    _touchScrollMouseMode = widget.terminal.mouseMode;
    _touchScrollMouseReportMode = widget.terminal.mouseReportMode;
    widget.terminal.addListener(_handleTerminalMetricsChanged);
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    _terminalActions = {
      PasteTextIntent: CallbackAction<PasteTextIntent>(onInvoke: _onPasteText),
      CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
        onInvoke: _onCopySelectionText,
      ),
      SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
        onInvoke: _onSelectAllText,
      ),
    };
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _touchScrollInertiaTicker = createTicker(_onTouchScrollInertiaTick);
    _graphicsAnimationTicker = createTicker(_onGraphicsAnimationTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Terminal images are user-requested media, not UI transitions. Android
    // reports disableAnimations when developer/emulator animation scales are
    // zero, which must not freeze GIFs in the terminal. iOS exposes its actual
    // Reduce Motion preference separately, so honor that signal here.
    _updateGraphicsAnimationsEnabled();
  }

  @override
  void didChangeAccessibilityFeatures() {
    _updateGraphicsAnimationsEnabled();
    _scheduleGraphicsAnimationSync();
  }

  void _updateGraphicsAnimationsEnabled() {
    _graphicsAnimationsEnabled = !WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .reduceMotion;
    _syncGraphicsAnimationTicker();
  }

  @override
  void activate() {
    super.activate();
    _logAndroidBackLifecycle('activate');
    _scheduleGraphicsAnimationSync();
  }

  @override
  void deactivate() {
    _logAndroidBackLifecycle('deactivate');
    _stopGraphicsAnimationTicker();
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant MonkeyTerminalView oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      _cancelDirectTouchScrollDrag();
      oldWidget.terminal.removeListener(_handleTerminalMetricsChanged);
      _stopGraphicsAnimationTicker();
      _lastTerminalViewWidth = widget.terminal.viewWidth;
      widget.terminal.addListener(_handleTerminalMetricsChanged);
      _touchScrollIsAltBuffer = widget.terminal.isUsingAltBuffer;
      _touchScrollMouseMode = widget.terminal.mouseMode;
      _touchScrollMouseReportMode = widget.terminal.mouseReportMode;
      _touchWheelCalibrator.reset(forgetEstimate: true);
      _stopTouchScrollInertia();
      _resetTouchScrollDispatch();
      _scheduleGraphicsAnimationSync();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _cancelDirectTouchScrollDrag();
      _scrollController.removeListener(_handleViewportScrolled);
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
      _scrollController.addListener(_handleViewportScrolled);
      _scheduleGraphicsAnimationSync();
    }
    if (oldWidget.simulateScroll != widget.simulateScroll) {
      _touchWheelCalibrator.reset();
      _stopTouchScrollInertia();
      _resetTouchScrollDispatch();
    }
    if (oldWidget.touchScrollToTerminal != widget.touchScrollToTerminal) {
      _touchWheelCalibrator.reset();
      _cancelDirectTouchScrollDrag();
      _stopTouchScrollInertia();
      _resetTouchScrollDispatch();
    }
    if (oldWidget.forceSgrTouchScroll != widget.forceSgrTouchScroll) {
      _touchWheelCalibrator.reset();
      _stopTouchScrollInertia();
      _resetTouchScrollDispatch();
    }
    if (oldWidget.scrollResetGeneration != widget.scrollResetGeneration) {
      _touchWheelCalibrator.reset();
      _cancelDirectTouchScrollDrag();
      _stopTouchScrollInertia();
      _resetTouchScrollDispatch();
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
    _syncGraphicsAnimationTicker();
  }

  @override
  void dispose() {
    _logAndroidBackLifecycle('dispose');
    WidgetsBinding.instance.removeObserver(this);
    widget.terminal.removeListener(_handleTerminalMetricsChanged);
    _pendingFocusInReportTimer?.cancel();
    _cancelDirectTouchScrollDrag();
    _touchWheelCalibrator.dispose();
    _stopTouchScrollInertia();
    _resetTouchScrollDispatch();
    _touchScrollInertiaTicker.dispose();
    _stopGraphicsAnimationTicker();
    _graphicsAnimationTicker.dispose();
    _scrollController.removeListener(_handleViewportScrolled);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    super.dispose();
  }

  void _logAndroidBackLifecycle(String event) {
    final diagnostics = DiagnosticsLogService.instance;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !diagnostics.enabled) {
      return;
    }
    diagnostics.debug(
      'android.back',
      'terminal_view_lifecycle',
      fields: <String, Object?>{
        'event': event,
        'mounted': mounted,
        'terminalViewWidth': widget.terminal.viewWidth,
        'terminalViewHeight': widget.terminal.viewHeight,
        'hasFocus': _focusNode.hasFocus,
        'usesExternalFocusNode': widget.focusNode != null,
        'autoResize': widget.autoResize,
        'simulateScroll': widget.simulateScroll,
        'touchScrollToTerminal': widget.touchScrollToTerminal,
      },
    );
  }

  void _handleTerminalMetricsChanged() {
    final nextIsAltBuffer = widget.terminal.isUsingAltBuffer;
    final nextMouseMode = widget.terminal.mouseMode;
    final nextMouseReportMode = widget.terminal.mouseReportMode;
    final transportChanged =
        _touchScrollIsAltBuffer != nextIsAltBuffer ||
        _touchScrollMouseMode != nextMouseMode ||
        _touchScrollMouseReportMode != nextMouseReportMode;
    _touchScrollIsAltBuffer = nextIsAltBuffer;
    _touchScrollMouseMode = nextMouseMode;
    _touchScrollMouseReportMode = nextMouseReportMode;
    if (transportChanged) {
      _cancelDirectTouchScrollDrag();
      _touchWheelCalibrator.reset();
      _resetTouchScrollDispatch();
      _stopTouchScrollInertia();
    } else if (_touchWheelCalibrator.observingTerminalOutput) {
      _touchWheelCalibrator.terminalChanged(
        captureTerminalViewportLines(widget.terminal),
      );
    }

    _syncGraphicsAnimationTicker();
    _scheduleGraphicsAnimationSync();
    final currentViewWidth = widget.terminal.viewWidth;
    if (currentViewWidth == _lastTerminalViewWidth) {
      return;
    }
    _lastTerminalViewWidth = currentViewWidth;
    if (mounted) {
      setState(() {});
    }
  }

  void _handleViewportScrolled() => _scheduleGraphicsAnimationSync();

  void _scheduleGraphicsAnimationSync() {
    if (_graphicsAnimationSyncScheduled) {
      return;
    }
    _graphicsAnimationSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _graphicsAnimationSyncScheduled = false;
      if (mounted) {
        _syncGraphicsAnimationTicker();
      }
    });
  }

  void _syncGraphicsAnimationTicker() {
    final graphics = widget.terminal.graphics;
    final visibleImageIds =
        _renderTerminalOrNull?._paintedVisibleGraphicsImageIds;
    final shouldAnimate =
        _graphicsAnimationsEnabled &&
        (visibleImageIds == null
            ? graphics.hasActiveAnimations
            : graphics.hasActiveAnimationsFor(visibleImageIds));
    _maybeLogGraphicsAnimationState(shouldAnimate, graphics, visibleImageIds);
    if (shouldAnimate) {
      if (!_graphicsAnimationTicker.isActive) {
        _lastGraphicsAnimationElapsed = Duration.zero;
        _graphicsAnimationTicker.start();
      }
      return;
    }
    _stopGraphicsAnimationTicker();
  }

  void _stopGraphicsAnimationTicker() {
    if (_graphicsAnimationTicker.isActive) {
      _graphicsAnimationTicker.stop();
    }
    _lastGraphicsAnimationElapsed = Duration.zero;
  }

  void _onGraphicsAnimationTick(Duration elapsed) {
    final delta = elapsed - _lastGraphicsAnimationElapsed;
    _lastGraphicsAnimationElapsed = elapsed;
    if (!delta.isNegative) {
      final visibleImageIds =
          _renderTerminalOrNull?._paintedVisibleGraphicsImageIds;
      final changed = widget.terminal.graphics.advanceAnimations(
        delta,
        imageIds: visibleImageIds,
      );
      if (changed) {
        _maybeLogGraphicsAnimationFrame(visibleImageIds?.length);
      }
    }
    _syncGraphicsAnimationTicker();
  }

  void _maybeLogGraphicsAnimationState(
    bool active,
    GraphicsManager graphics,
    Set<int>? visibleImageIds,
  ) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled ||
        _lastLoggedGraphicsAnimationActive == active ||
        (!active &&
            _lastLoggedGraphicsAnimationActive == null &&
            graphics.animationImageCount == 0)) {
      return;
    }
    _lastLoggedGraphicsAnimationActive = active;
    diagnostics.debug(
      'terminal.graphics',
      'animation_ticker',
      fields: {
        'state': active ? 'running' : 'stopped',
        'reducedMotion': !_graphicsAnimationsEnabled,
        'tickerMuted': _graphicsAnimationTicker.muted,
        'animatedImages': graphics.animationImageCount,
        'visibleImages': visibleImageIds?.length ?? -1,
      },
    );
  }

  void _maybeLogGraphicsAnimationFrame(int? visibleImageCount) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _graphicsAnimationFrameLogAtMs < 1000) {
      return;
    }
    _graphicsAnimationFrameLogAtMs = nowMs;
    diagnostics.debug(
      'terminal.graphics',
      'animation_frame',
      fields: {
        'visibleImages': visibleImageCount ?? -1,
        'tickerMuted': _graphicsAnimationTicker.muted,
      },
    );
  }

  /// Re-sends focus reports after terminal state changes.
  ///
  /// TUIs such as Codex re-query terminal colors after focus-gained events. The
  /// app can use this after a theme change so those TUIs refresh cached
  /// foreground/background colors without waiting for a real focus transition.
  ///
  /// Set [force] to send the report even when [Terminal.reportFocusMode] is
  /// off. Inside tmux the outer xterm rarely sees the inner app's
  /// `CSI ? 1004 h` request because tmux intercepts and re-emits it for its
  /// own clients, so the outer xterm's tracking flag is unreliable as a gate.
  void refreshFocusReport({bool forceTransition = false, bool force = false}) {
    if (!force && !widget.terminal.reportFocusMode) {
      return;
    }
    _pendingFocusInReportTimer?.cancel();
    _pendingFocusInReportTimer = null;
    if (!forceTransition) {
      widget.terminal.onOutput?.call(_terminalFocusInReport);
      return;
    }
    widget.terminal.onOutput?.call(_terminalFocusOutReport);
    _pendingFocusInReportTimer = Timer(_terminalFocusTransitionDelay, () {
      _pendingFocusInReportTimer = null;
      if (!mounted) {
        return;
      }
      widget.terminal.onOutput?.call(_terminalFocusInReport);
    });
  }

  /// Reports the current terminal theme mode to focus-aware terminal muxers.
  void refreshThemeModeReport({required bool isDark}) {
    widget.terminal.onOutput?.call(
      buildTerminalThemeModeReport(isDark: isDark),
    );
  }

  /// Reports the current default foreground/background colors to a TUI.
  void refreshThemeDefaultColorReports(TerminalThemeData theme) {
    final reports = buildTerminalThemeDefaultColorReports(theme);
    if (reports.isEmpty) {
      return;
    }
    widget.terminal.onOutput?.call(reports);
  }

  /// Re-sends the current viewport dimensions to the attached terminal.
  ///
  /// When [flushKeyboardResize] is true, any debounced keyboard-inset resize is
  /// applied immediately before reporting the dimensions.
  void refreshTerminalSize({bool flushKeyboardResize = false}) {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    if (renderObject is MonkeyRenderTerminal) {
      renderObject._refreshTerminalSize(
        flushKeyboardResize: flushKeyboardResize,
      );
    }
  }

  /// Forces the visible terminal viewport to repaint after remote replay.
  void refreshTerminalDisplay({bool revealLatestOutput = false}) {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    if (renderObject is MonkeyRenderTerminal) {
      renderObject._refreshTerminalDisplay(
        revealLatestOutput: revealLatestOutput,
      );
    }
    if (!revealLatestOutput) {
      return;
    }

    _scrollToBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToBottom();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cursorFocusNode = widget.cursorFocusNode ?? _focusNode;
    final mediaQuery = MediaQuery.of(context);
    final terminalViewportPadding = resolveTerminalViewportPadding(
      mediaQuery,
      basePadding: widget.padding ?? EdgeInsets.zero,
    );
    final shouldFillHorizontalRemainder =
        terminalViewportPadding.left == 0 && terminalViewportPadding.right == 0;

    final inheritedScrollBehavior = ScrollConfiguration.of(context);
    final directScrollDragDevices = <PointerDeviceKind>{
      ...inheritedScrollBehavior.dragDevices,
    }..remove(PointerDeviceKind.touch);

    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      physics: widget.touchScrollToTerminal
          ? const NeverScrollableScrollPhysics()
          : null,
      viewportBuilder: (context, offset) {
        final mediaQuery = MediaQuery.of(context);
        Widget buildTerminalLeaf(BuildContext context) => _TerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: EdgeInsets.zero,
          alignToTrailingEdges: shouldAlignTerminalToTrailingEdges(mediaQuery),
          autoResize: widget.autoResize,
          resizeTerminalToViewport: widget.resizeTerminalToViewport,
          notifyPixelSizeChanges: widget.notifyPixelSizeChanges,
          resizeBottomInset: mediaQuery.viewInsets.bottom,
          liveOutputAutoScroll: widget.liveOutputAutoScroll,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          inlineUnderlines: widget.inlineUnderlines,
          focusNode: cursorFocusNode,
          cursorType: widget.cursorType,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
          selectionRegistrar: SelectionContainer.maybeOf(context),
        );
        return Builder(builder: buildTerminalLeaf);
      },
    );

    if (widget.useSystemSelection) {
      child = SelectionArea(
        focusNode: widget.hardwareKeyboardOnly ? _focusNode : null,
        contextMenuBuilder:
            widget.systemSelectionContextMenuBuilder ??
            _defaultSystemSelectionContextMenu,
        onSelectionChanged: widget.onSystemSelectionChanged,
        child: child,
      );
    }

    if (!widget.touchScrollToTerminal) {
      child = MonkeyTerminalScrollGestureHandler(
        key: ValueKey<int>(widget.scrollResetGeneration),
        terminal: widget.terminal,
        simulateScroll: widget.simulateScroll,
        forceSgr: widget.forceSgrTouchScroll,
        getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
        getLineHeight: () => renderTerminal.lineHeight,
        child: child,
      );
    }

    child = ScrollConfiguration(
      behavior: inheritedScrollBehavior.copyWith(
        dragDevices: directScrollDragDevices,
      ),
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        onInsert: _onInsert,
        onDelete: _onDelete,
        onComposing: _onComposing,
        onAction: _onTextInputAction,
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly && !widget.useSystemSelection) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = Actions(actions: _terminalActions, child: child);

    child = KeyboardVisibility(onKeyboardShow: _onKeyboardShow, child: child);

    child = MonkeyTerminalGestureHandler(
      key: ValueKey<int>(widget.scrollResetGeneration),
      terminalView: this,
      terminalController: _controller,
      onSingleTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onDoubleTapDown: widget.onDoubleTapDown != null ? _onDoubleTapDown : null,
      onLongPressStart: widget.onLongPressStart != null
          ? _onLongPressStart
          : null,
      suppressLongPressDragSelection: widget.suppressLongPressDragSelection,
      onSecondaryTapDown: widget.onSecondaryTapDown != null
          ? _onSecondaryTapDown
          : null,
      onSecondaryTapUp: widget.onSecondaryTapUp != null
          ? _onSecondaryTapUp
          : null,
      resolveLinkTap: widget.resolveLinkTap == null ? null : _resolveLinkTap,
      onLinkTapDown: widget.onLinkTapDown == null ? null : _onLinkTapDown,
      onLinkTap: widget.onLinkTap,
      onTouchScrollDown: _onTouchScrollDown,
      onTouchScrollStart: widget.touchScrollToTerminal
          ? _onTouchScrollStart
          : _onDirectTouchScrollStart,
      onTouchScrollUpdate: widget.touchScrollToTerminal
          ? _onTouchScrollUpdate
          : _onDirectTouchScrollUpdate,
      onTouchScrollEnd: widget.touchScrollToTerminal
          ? _onTouchScrollEnd
          : _onDirectTouchScrollEnd,
      onTouchScrollCancel: widget.touchScrollToTerminal
          ? _onTouchScrollCancel
          : _onDirectTouchScrollCancel,
      touchScrollVelocityTrackerBuilder: inheritedScrollBehavior
          .velocityTrackerBuilder(context),
      touchScrollMultitouchDragStrategy: inheritedScrollBehavior
          .getMultitouchDragStrategy(context),
      readOnly: widget.readOnly || widget.useSystemSelection,
      enableTerminalSelectionGestures: !widget.useSystemSelection,
      child: child,
    );

    child = MouseRegion(cursor: SystemMouseCursors.text, child: child);

    if (shouldFillHorizontalRemainder && _viewportKey.currentContext != null) {
      final horizontalFillScale = resolveTerminalHorizontalFillScale(
        viewportWidth: renderTerminal.size.width,
        cellWidth: renderTerminal.cellSize.width,
        columns: widget.terminal.viewWidth,
      );
      if (horizontalFillScale > 1) {
        child = Transform.scale(
          alignment: Alignment.centerLeft,
          scaleX: horizontalFillScale,
          child: child,
        );
      }
    }

    child = ClipRect(child: child);

    child = Container(
      color: widget.theme.background.withValues(alpha: 1),
      padding: terminalViewportPadding,
      child: child,
    );

    return child;
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  bool get shouldSendTerminalTapPointerInput =>
      !widget.readOnly && _controller.shouldSendPointerInput(PointerInput.tap);

  bool sendTerminalPrimaryTap(Offset globalPosition) {
    if (!shouldSendTerminalTapPointerInput) {
      return false;
    }

    final localPosition = renderTerminal.globalToLocal(globalPosition);
    final handledDown = renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      localPosition,
    );
    final handledUp = renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.up,
      localPosition,
    );
    return handledDown || handledUp;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  void _onTapDown(TapDownDetails details) {
    _stopTouchScrollInertia();
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else if (!widget.useSystemSelection) {
      _requestInputFocus();
    }

    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapDown?.call(details, offset);
  }

  void _requestInputFocus() {
    if (!widget.hardwareKeyboardOnly) {
      _customTextEditKey.currentState?.requestKeyboard();
    } else {
      _focusNode.requestFocus();
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onDoubleTapDown?.call(details, offset);
  }

  void _onLinkTapDown(TapDownDetails details) {
    _stopTouchScrollInertia();
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onLinkTapDown?.call(details, offset);
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onLongPressStart?.call(details, offset);
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  void _cancelDirectTouchScrollDrag() {
    _directTouchScrollHold?.cancel();
    _directTouchScrollHold = null;
    _directTouchScrollDrag?.cancel();
    _directTouchScrollDrag = null;
  }

  void _disposeDirectTouchScrollHold() {
    _directTouchScrollHold = null;
  }

  void _onTouchScrollDown(DragDownDetails details) {
    if (widget.touchScrollToTerminal || widget.terminal.isUsingAltBuffer) {
      _stopTouchScrollInertia();
      return;
    }
    _directTouchScrollHold?.cancel();
    final position = _scrollableKey.currentState?.position;
    if (position == null) {
      _directTouchScrollHold = null;
      return;
    }
    _directTouchScrollHold = position.hold(_disposeDirectTouchScrollHold);
  }

  void _onDirectTouchScrollStart(DragStartDetails details) {
    if (widget.terminal.isUsingAltBuffer) {
      _onTouchScrollStart(details);
      return;
    }
    _directTouchScrollDrag?.cancel();
    _directTouchScrollDrag = null;
    final position = _scrollableKey.currentState?.position;
    if (position == null) {
      _directTouchScrollHold?.cancel();
      _directTouchScrollHold = null;
      return;
    }
    _directTouchScrollDrag = position.drag(
      details,
      () => _directTouchScrollDrag = null,
    );
    _disposeDirectTouchScrollHold();
  }

  void _onDirectTouchScrollUpdate(DragUpdateDetails details) {
    if (widget.terminal.isUsingAltBuffer) {
      _onTouchScrollUpdate(details);
      return;
    }
    final primaryDelta = details.primaryDelta;
    final drag = _directTouchScrollDrag;
    if (primaryDelta == null || drag == null) {
      return;
    }
    drag.update(details);
  }

  void _onDirectTouchScrollEnd(DragEndDetails details) {
    if (widget.terminal.isUsingAltBuffer) {
      _onTouchScrollEnd(details);
      return;
    }
    final drag = _directTouchScrollDrag;
    if (drag == null) {
      return;
    }
    drag.end(details);
    _directTouchScrollDrag = null;
  }

  void _onDirectTouchScrollCancel() {
    if (widget.terminal.isUsingAltBuffer) {
      _onTouchScrollCancel();
      return;
    }
    _cancelDirectTouchScrollDrag();
  }

  void _onTouchScrollCancel() {
    _stopTouchScrollInertia();
    _resetTouchScrollDispatch();
  }

  void _onTouchScrollStart(DragStartDetails details) {
    _stopTouchScrollInertia();
    _lastTouchScrollPosition = details.localPosition;
    if (!_touchWheelCalibrator.waitingForResponse) {
      _touchWheelCalibrator.beginGesture();
      _resetTouchScrollDispatch(preserveRemainder: true);
    }
  }

  void _onTouchScrollUpdate(DragUpdateDetails details) {
    _lastTouchScrollPosition = details.localPosition;
    _applyTouchScrollDelta(details.delta.dy);
  }

  void _onTouchScrollEnd(DragEndDetails details) {
    final primaryVelocity = details.primaryVelocity;
    if (primaryVelocity == null) {
      return;
    }
    _startTouchScrollInertia(primaryVelocity);
  }

  Tolerance get _touchScrollTolerance {
    final devicePixelRatio = View.of(context).devicePixelRatio;
    return Tolerance(
      velocity: 1.0 / (0.050 * devicePixelRatio),
      distance: 1.0 / devicePixelRatio,
    );
  }

  double get _touchScrollStepHeight {
    final lineHeight = renderTerminal.lineHeight;
    if (lineHeight <= 0) {
      return 0;
    }
    return lineHeight * _touchWheelCalibrator.rowsPerEvent;
  }

  void _applyTouchScrollDelta(double delta) {
    _touchScrollRemainder += delta;
    final stepHeight = _touchScrollStepHeight;
    if (stepHeight <= 0 || _touchWheelCalibrator.waitingForResponse) {
      return;
    }
    final position = _resolveViewportMousePosition(_lastTouchScrollPosition);
    final canReportMouse =
        widget.forceSgrTouchScroll || widget.terminal.mouseMode.reportScroll;
    while (_touchScrollRemainder.abs() >= stepHeight) {
      final scrollUp = _touchScrollRemainder > 0;
      final scrollDirection = scrollUp ? 1 : -1;
      final lineHeight = renderTerminal.lineHeight;
      final calibrationStarted =
          canReportMouse &&
          _touchWheelCalibrator.needsMeasurement &&
          _touchWheelCalibrator.begin(
            before: captureTerminalViewportLines(widget.terminal),
            onSettled: (previousRows, rows) {
              if (!mounted) {
                return;
              }
              _touchScrollRemainder -=
                  scrollDirection * lineHeight * (rows - previousRows);
              _applyTouchScrollDelta(0);
            },
          );
      _enqueueTouchScrollRun(
        scrollUp ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        position,
      );
      _touchScrollRemainder += scrollUp ? -stepHeight : stepHeight;
      if (calibrationStarted) {
        break;
      }
    }
    _drainTouchScrollInput();
  }

  void _enqueueTouchScrollRun(TerminalMouseButton button, CellOffset position) {
    if (_pendingTouchScrollRuns.isNotEmpty) {
      final last = _pendingTouchScrollRuns.last;
      if (last.button == button &&
          last.position.x == position.x &&
          last.position.y == position.y) {
        _pendingTouchScrollRuns
          ..removeLast()
          ..add((button: button, position: position, count: last.count + 1));
        return;
      }
    }
    _pendingTouchScrollRuns.add((button: button, position: position, count: 1));
  }

  void _consumeTouchScrollRun(int count) {
    final run = _pendingTouchScrollRuns.removeFirst();
    if (run.count > count) {
      _pendingTouchScrollRuns.addFirst((
        button: run.button,
        position: run.position,
        count: run.count - count,
      ));
    }
  }

  void _drainTouchScrollInput() {
    if (_touchScrollDrainScheduled || _pendingTouchScrollRuns.isEmpty) {
      return;
    }
    final canBatchSgr =
        widget.forceSgrTouchScroll ||
        (widget.terminal.mouseMode.reportScroll &&
            widget.terminal.mouseReportMode == MouseReportMode.sgr);
    if (canBatchSgr) {
      // Start with one report so responsive applications can render each
      // increment. Increase throughput only while requested movement remains
      // queued across frames, then return to one as soon as caught up.
      var budget = math.min(1 + _touchScrollBacklogFrames, 6);
      while (budget > 0 && _pendingTouchScrollRuns.isNotEmpty) {
        final run = _pendingTouchScrollRuns.first;
        final count = math.min(run.count, budget);
        _sendTouchScrollMouseInput(
          run.button,
          run.position,
          repeatCount: count,
        );
        _consumeTouchScrollRun(count);
        budget -= count;
      }
      if (_pendingTouchScrollRuns.isEmpty) {
        _touchScrollBacklogFrames = 0;
      } else {
        _touchScrollBacklogFrames = math.min(_touchScrollBacklogFrames + 1, 5);
      }
      // Lock the frame-wide budget even when the queue is empty; pointer updates
      // received before this callback only append runs for the next frame.
      _scheduleTouchScrollDrain();
      return;
    }

    _touchScrollBacklogFrames = 0;
    while (_pendingTouchScrollRuns.isNotEmpty) {
      final run = _pendingTouchScrollRuns.first;
      final handled = _sendTouchScrollMouseInput(run.button, run.position);
      _consumeTouchScrollRun(1);
      if (!handled && widget.simulateScroll) {
        widget.terminal.keyInput(
          run.button == TerminalMouseButton.wheelUp
              ? TerminalKey.arrowUp
              : TerminalKey.arrowDown,
        );
      }
    }
  }

  void _scheduleTouchScrollDrain() {
    if (_touchScrollDrainScheduled || !mounted) {
      return;
    }
    _touchScrollDrainScheduled = true;
    final generation = _touchScrollDispatchGeneration;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _touchScrollDispatchGeneration) {
        return;
      }
      _touchScrollDrainScheduled = false;
      if (mounted) {
        _drainTouchScrollInput();
      }
    });
  }

  void _resetTouchScrollDispatch({bool preserveRemainder = false}) {
    _touchScrollDispatchGeneration += 1;
    _touchScrollDrainScheduled = false;
    _pendingTouchScrollRuns.clear();
    _touchScrollBacklogFrames = 0;
    if (!preserveRemainder) {
      _touchScrollRemainder = 0;
    }
  }

  void _startTouchScrollInertia(double velocity) {
    final clampedVelocity = velocity.clamp(
      -kMaxFlingVelocity,
      kMaxFlingVelocity,
    );
    if (clampedVelocity.abs() < kMinFlingVelocity) {
      return;
    }

    _stopTouchScrollInertia();
    _touchScrollInertiaSimulation = ClampingScrollSimulation(
      position: 0,
      velocity: clampedVelocity,
      tolerance: _touchScrollTolerance,
    );
    _touchScrollInertiaTicker.start();
  }

  void _stopTouchScrollInertia() {
    _touchScrollInertiaTicker.stop();
    _touchScrollInertiaSimulation = null;
    _lastTouchScrollInertiaOffset = 0;
  }

  void _onTouchScrollInertiaTick(Duration elapsed) {
    final simulation = _touchScrollInertiaSimulation;
    if (simulation == null) {
      _touchScrollInertiaTicker.stop();
      return;
    }

    final elapsedSeconds =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final scrollOffset = simulation.x(elapsedSeconds);
    _applyTouchScrollDelta(scrollOffset - _lastTouchScrollInertiaOffset);
    _lastTouchScrollInertiaOffset = scrollOffset;

    if (simulation.isDone(elapsedSeconds)) {
      _stopTouchScrollInertia();
    }
  }

  bool _sendTouchScrollMouseInput(
    TerminalMouseButton button,
    CellOffset position, {
    int repeatCount = 1,
  }) => sendTerminalScrollMouseInput(
    terminal: widget.terminal,
    button: button,
    position: position,
    forceSgr: widget.forceSgrTouchScroll,
    repeatCount: repeatCount,
  );

  CellOffset _resolveViewportMousePosition(Offset localPosition) {
    final cellSize = renderTerminal.cellSize;
    final cellWidth = cellSize.width <= 0 ? 1.0 : cellSize.width;
    final cellHeight = cellSize.height <= 0 ? 1.0 : cellSize.height;
    final maxColumn = widget.terminal.viewWidth - 1;
    final maxRow = widget.terminal.viewHeight - 1;

    return CellOffset(
      (localPosition.dx / cellWidth).floor().clamp(0, maxColumn),
      (localPosition.dy / cellHeight).floor().clamp(0, maxRow),
    );
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    unawaited(_handleInsert(text));
  }

  Future<void> _handleInsert(String text) async {
    if (widget.onInsertText != null) {
      final shouldInsert = await widget.onInsertText!(text);
      if (!mounted || !shouldInsert) {
        return;
      }
    }

    final key = charToTerminalKey(text.trim());
    widget.onUserInput?.call();

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent && !widget.terminal.kittyKeyboardMode) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final type = _terminalKeyEventType(event);
    final handled = key == TerminalKey.enter
        ? sendTerminalEnterInput(
            widget.terminal,
            shiftActive: shift,
            altActive: alt,
            ctrlActive: ctrl,
            metaActive: meta,
            type: type,
          )
        : widget.terminal.keyInput(
            key,
            ctrl: ctrl,
            alt: alt,
            shift: shift,
            meta: meta,
            type: type,
          );

    if (handled) {
      widget.onUserInput?.call();
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  TerminalKeyEventType _terminalKeyEventType(KeyEvent event) {
    if (event is KeyRepeatEvent) {
      return TerminalKeyEventType.repeat;
    }
    if (event is KeyUpEvent) {
      return TerminalKeyEventType.release;
    }
    return TerminalKeyEventType.press;
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  void _onDelete() {
    _scrollToBottom();
    widget.onUserInput?.call();
    widget.terminal.keyInput(TerminalKey.backspace);
  }

  void _onTextInputAction(TextInputAction action) {
    _scrollToBottom();
    if (action == TextInputAction.done) {
      widget.onUserInput?.call();
      widget.terminal.keyInput(TerminalKey.enter);
    }
  }

  String? _resolveLinkTap(Offset localPosition) =>
      widget.resolveLinkTap!(renderTerminal.getCellOffset(localPosition));

  Future<Object?> _onPasteText(PasteTextIntent intent) async {
    if (widget.onPasteText != null) {
      await widget.onPasteText!();
      return null;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null) {
      widget.terminal.paste(text);
      _controller.clearSelection();
    }
    return null;
  }

  Future<Object?> _onCopySelectionText(CopySelectionTextIntent intent) async {
    final selection = _controller.selection;
    if (selection == null) {
      return null;
    }
    final text = widget.terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    return null;
  }

  Object? _onSelectAllText(SelectAllTextIntent intent) {
    _controller.setSelection(
      widget.terminal.buffer.createAnchor(
        0,
        widget.terminal.buffer.height - widget.terminal.viewHeight,
      ),
      widget.terminal.buffer.createAnchor(
        widget.terminal.viewWidth,
        widget.terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
    return null;
  }

  void _scrollToBottom() {
    final position = _scrollableKey.currentState?.position;
    if (position != null) {
      position.jumpTo(position.maxScrollExtent);
    }
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.alignToTrailingEdges,
    required this.autoResize,
    required this.resizeTerminalToViewport,
    required this.notifyPixelSizeChanges,
    required this.resizeBottomInset,
    required this.liveOutputAutoScroll,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.inlineUnderlines,
    required this.focusNode,
    required this.cursorType,
    this.onEditableRect,
    this.composingText,
    this.selectionRegistrar,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool alignToTrailingEdges;

  final bool autoResize;

  final bool resizeTerminalToViewport;

  final bool notifyPixelSizeChanges;

  final double resizeBottomInset;

  final bool liveOutputAutoScroll;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final List<TerminalTextUnderline> inlineUnderlines;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  final SelectionRegistrar? selectionRegistrar;

  @override
  MonkeyRenderTerminal createRenderObject(BuildContext context) {
    return MonkeyRenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      alignToTrailingEdges: alignToTrailingEdges,
      autoResize: autoResize,
      resizeTerminalToViewport: resizeTerminalToViewport,
      notifyPixelSizeChanges: notifyPixelSizeChanges,
      resizeBottomInset: resizeBottomInset,
      liveOutputAutoScroll: liveOutputAutoScroll,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      inlineUnderlines: inlineUnderlines,
      focusNode: focusNode,
      cursorType: cursorType,
      onEditableRect: onEditableRect,
      composingText: composingText,
      selectionRegistrar: selectionRegistrar,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    MonkeyRenderTerminal renderObject,
  ) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..alignToTrailingEdges = alignToTrailingEdges
      ..autoResize = autoResize
      ..resizeTerminalToViewport = resizeTerminalToViewport
      ..notifyPixelSizeChanges = notifyPixelSizeChanges
      ..resizeBottomInset = resizeBottomInset
      ..liveOutputAutoScroll = liveOutputAutoScroll
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..inlineUnderlines = inlineUnderlines
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..onEditableRect = onEditableRect
      ..composingText = composingText
      ..selectionRegistrar = selectionRegistrar;
  }
}

class MonkeyTerminalPainter extends TerminalPainter {
  MonkeyTerminalPainter({
    required super.theme,
    required super.textStyle,
    required super.textScaler,
  });

  final _rectPaint = Paint();
  final _paragraphCache = ParagraphCache(10240);
  // Paragraphs for multi-cell foreground runs (see `_paintLineForegroundsInto`),
  // keyed by run text + resolved style. Kept separate from the per-cell
  // `_paragraphCache` so the two key spaces can never collide.
  final _runParagraphCache = ParagraphCache(4096);
  final _inlineUnderlineParagraphCache = ParagraphCache(1024);
  final _cursorCellData = CellData.empty();

  // OpenType features that turn adjacent glyphs into a single ligature or a
  // context-dependent alternate. A batched run concatenates several cells into
  // one paragraph, so these must stay disabled: the per-cell path can never
  // form a ligature (each cell is shaped alone), and letting one appear here
  // would both change the terminal's look and collapse two grid cells into one
  // glyph, drifting the rest of the run off the monospace grid.
  static const _ligatureDisablingFeatures = <FontFeature>[
    FontFeature.disable('liga'),
    FontFeature.disable('clig'),
    FontFeature.disable('calt'),
    FontFeature.disable('dlig'),
    FontFeature.disable('hlig'),
    FontFeature.disable('rlig'),
  ];

  // Cache of recorded per-line glyph pictures, keyed by a hash of the line's
  // cell content. Painting a full screen of text draws one paragraph per
  // non-blank cell; recording that once per distinct line and replaying it as a
  // single `drawPicture` turns the hot foreground pass into one draw call per
  // *unchanged* line — which is every line on a scroll frame, and the static
  // majority of a streaming TUI screen. Invalidated wholesale whenever the font,
  // theme or text scale changes (the same triggers that clear the paragraph
  // cache), since those change how a given cell content renders.
  final _foregroundPictureCache = <int, Picture>{};
  // Keep enough unique transcript lines for repeated page/fling navigation in
  // long text sessions while retaining a hard memory bound on mobile. The old
  // 512-line window thrashed after only a handful of terminal-sized jumps.
  static const _maxForegroundPictureCacheEntries = 2048;

  /// Number of foreground style-run paragraphs currently cached. A coalesced
  /// line of N same-style cells caches a single N-glyph run paragraph here (not
  /// N per-cell paragraphs), so tests can assert that batching actually occurs.
  @visibleForTesting
  int get runParagraphCacheLength => _runParagraphCache.length;

  @override
  set textStyle(TerminalStyle value) {
    if (value == textStyle) {
      return;
    }
    super.textStyle = value;
    _clearCaches();
  }

  @override
  set textScaler(TextScaler value) {
    if (value == textScaler) {
      return;
    }
    super.textScaler = value;
    _clearCaches();
  }

  @override
  set theme(TerminalTheme value) {
    if (_terminalThemesEqual(value, theme)) {
      return;
    }
    super.theme = value;
    _clearCaches();
  }

  @override
  void clearFontCache() {
    super.clearFontCache();
    _clearCaches();
  }

  void _clearCaches() {
    _paragraphCache.clear();
    _inlineUnderlineParagraphCache.clear();
    _runParagraphCache.clear();
    _foregroundPictureCache.clear();
  }

  @override
  void dispose() {
    _clearCaches();
    super.dispose();
  }

  void paintReadableCursor(
    Canvas canvas,
    Offset offset,
    CellData cellData, {
    required TerminalCursorType cursorType,
    required bool hasFocus,
  }) {
    paintCursor(canvas, offset, cursorType: cursorType, hasFocus: hasFocus);

    if (!hasFocus || cursorType != TerminalCursorType.block) {
      return;
    }

    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) {
      return;
    }

    _cursorCellData
      ..foreground = _encodeRgbCellColor(
        _resolveCursorForegroundColor(cellData),
      )
      ..background = _encodeRgbCellColor(theme.cursor)
      ..flags = cellData.flags & ~CellFlags.inverse & ~CellFlags.faint
      ..content = cellData.content;

    canvas
      ..save()
      ..clipRect(offset & cellSize);
    paintCellForeground(canvas, offset, _cursorCellData);
    canvas.restore();
  }

  Color _resolveCursorForegroundColor(CellData cellData) {
    final cellFlags = cellData.flags;
    final inverse = cellFlags & CellFlags.inverse != 0;
    final cellBackground = inverse
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);

    return resolveMonkeyTerminalCursorForegroundColor(
      cursor: theme.cursor,
      background: theme.background,
      foreground: theme.foreground,
      cellBackground: cellBackground,
    );
  }

  void paintLineInlineUnderlines(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    List<TerminalTextUnderline> inlineUnderlines,
  ) {
    final cellData = CellData.empty();
    final cellWidth = cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);
      if (_shouldUnderlineCell(i, inlineUnderlines)) {
        paintCellInlineUnderline(canvas, cellOffset, cellData);
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @override
  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    paintLineBackgrounds(canvas, offset, line);
    paintLineForegrounds(canvas, offset, line);
    paintLineCellUnderlines(canvas, offset, line);
  }

  /// Paints only the backgrounds (line fill, trailing run, and each cell's own
  /// background color) for [line].
  ///
  /// Backgrounds for every visible line are painted before any glyphs so that a
  /// following line's opaque background can never overdraw the previous line's
  /// descenders. Glyph ink for letters such as "g"/"y"/"p" can extend a pixel
  /// or two below the cell box, and the old single per-line pass clipped it
  /// behind the next row's background.
  void paintLineBackgrounds(Canvas canvas, Offset offset, BufferLine line) {
    paintLineBackground(canvas, offset, line);
    final cellData = CellData.empty();
    final cellWidth = cellSize.width;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final charWidth = cellData.content >> CellContent.widthShift;
      paintCellBackground(canvas, offset.translate(i * cellWidth, 0), cellData);
      if (charWidth == 2) {
        i++;
      }
    }
  }

  /// Paints only the glyphs for [line], in a pass run after every visible
  /// line's background so descenders that extend past the cell box are not
  /// clipped by the next row's background.
  void paintLineForegrounds(Canvas canvas, Offset offset, BufferLine line) {
    final hash = _lineForegroundHash(line);
    // remove+reinsert keeps the map in least-recently-used order (oldest first).
    var picture = _foregroundPictureCache.remove(hash);
    if (picture == null) {
      final recorder = PictureRecorder();
      _paintLineForegroundsInto(Canvas(recorder), line);
      picture = recorder.endRecording();
    }
    _foregroundPictureCache[hash] = picture;
    if (_foregroundPictureCache.length > _maxForegroundPictureCacheEntries) {
      // Drop the least-recently-used entry. The picture is not disposed: a
      // still-in-flight frame may reference it, and a raster of a disposed
      // picture crashes; dropping the reference lets the GC finalizer reclaim it
      // once nothing can draw it.
      _foregroundPictureCache.remove(_foregroundPictureCache.keys.first);
    }
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..drawPicture(picture)
      ..restore();
  }

  /// Draws [line]'s glyphs at the origin (each cell at `x = column * cellWidth`),
  /// for recording into a cached [Picture]. See [paintLineForegrounds].
  ///
  /// Consecutive width-1 text cells that share a foreground style are coalesced
  /// into a single paragraph and drawn with one `drawParagraph` (a "style run"),
  /// cutting draw-call overhead on dense, freshly rendered lines — the ones that
  /// miss the per-line picture cache during high-throughput output. Runs break
  /// on any style change and at cells that are positioned or painted specially,
  /// which fall back to the per-cell [paintCellForeground] so their exact
  /// placement and special drawing are preserved: Kitty placeholders, block
  /// elements, wide (2-cell) and zero-width (combining-mark) glyphs, concealed
  /// cells, undrawn blank cells, and any code point that is not
  /// [_isBatchableForegroundCodePoint] (complex/joining scripts and glyphs that
  /// may fall back to a non-monospace font, which would shape or advance
  /// differently once concatenated into one paragraph).
  void _paintLineForegroundsInto(Canvas canvas, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = cellSize.width;
    final length = line.length;

    // Accumulated style run: a maximal sequence of consecutive width-1 text
    // cells sharing one foreground style, starting at column [runStartColumn].
    var runStartColumn = -1;
    final runCharCodes = <int>[];
    var runColor = const Color(0x00000000);
    var runBold = false;
    var runItalic = false;
    var runOverline = false;
    var runStrikethrough = false;
    Color? runDecorationColor;

    void flushRun() {
      if (runStartColumn < 0) {
        return;
      }
      _flushForegroundRun(
        canvas,
        Offset(runStartColumn * cellWidth, 0),
        runCharCodes,
        color: runColor,
        bold: runBold,
        italic: runItalic,
        overline: runOverline,
        strikethrough: runStrikethrough,
        decorationColor: runDecorationColor,
      );
      runStartColumn = -1;
      runCharCodes.clear();
    }

    for (var i = 0; i < length; i++) {
      line.getCellData(i, cellData);
      final content = cellData.content;
      final charWidth = content >> CellContent.widthShift;
      final charCode = content & CellContent.codepointMask;
      final flags = cellData.flags;

      final overline = flags & CellFlags.overline != 0;
      final strikethrough = flags & CellFlags.strikethrough != 0;
      // Cells that draw nothing in the foreground pass: an empty cell, a Kitty
      // graphics placeholder, a concealed (SGR 8) cell, or a plain space whose
      // background/underline are handled by the other passes. Each ends the run
      // but is otherwise skipped, matching [paintCellForeground]'s early returns.
      final drawsNothing =
          charCode == 0 ||
          charCode == kittyGraphicsPlaceholderCodePoint ||
          flags & CellFlags.invisible != 0 ||
          (charCode == 0x20 && !overline && !strikethrough);
      // Cells that must be drawn individually at their exact column: block
      // elements (painted as rectangles), wide (2-cell) and zero-width
      // (combining-mark) glyphs — which shape and advance with their neighbours
      // inside one paragraph — and code points that are not safe to concatenate
      // (complex/joining scripts, non-monospace fallbacks). These break the run
      // and defer to the per-cell path, preserving the pre-batching output.
      final drawIndividually =
          charWidth != 1 ||
          _isRectPaintedBlockElement(charCode) ||
          !_isBatchableForegroundCodePoint(charCode);

      if (drawsNothing) {
        flushRun();
        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      if (drawIndividually) {
        flushRun();
        paintCellForeground(canvas, Offset(i * cellWidth, 0), cellData);
        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      final color = resolveMonkeyTerminalCellForegroundColor(cellData);
      final bold = flags & CellFlags.bold != 0;
      final italic = flags & CellFlags.italic != 0;
      // The decoration color only affects the paragraph when an overline or
      // strikethrough is drawn; keep it null otherwise so cells that differ only
      // in an unused underline color still coalesce.
      final decorationColor = (overline || strikethrough)
          ? (cellData.underlineColor != 0
                ? resolveForegroundColor(cellData.underlineColor)
                : null)
          : null;
      // Flutter will not draw an overline/strikethrough beneath a lone space, so
      // a decorated space is shaped as U+00A0 (same monospace advance) exactly
      // as the per-cell path does.
      final drawCharCode = (overline || strikethrough) && charCode == 0x20
          ? 0xA0
          : charCode;

      final continuesRun =
          runStartColumn >= 0 &&
          color == runColor &&
          bold == runBold &&
          italic == runItalic &&
          overline == runOverline &&
          strikethrough == runStrikethrough &&
          decorationColor == runDecorationColor;
      if (!continuesRun) {
        flushRun();
        runStartColumn = i;
        runColor = color;
        runBold = bold;
        runItalic = italic;
        runOverline = overline;
        runStrikethrough = strikethrough;
        runDecorationColor = decorationColor;
      }
      runCharCodes.add(drawCharCode);
    }
    flushRun();
  }

  /// Lays out (with caching) and draws one foreground style run: the glyphs in
  /// [charCodes] sharing the given style, at [offset]. Ligatures and contextual
  /// alternates are disabled so the run stays one glyph per cell, aligned to the
  /// monospace grid exactly as the per-cell path renders it.
  void _flushForegroundRun(
    Canvas canvas,
    Offset offset,
    List<int> charCodes, {
    required Color color,
    required bool bold,
    required bool italic,
    required bool overline,
    required bool strikethrough,
    required Color? decorationColor,
  }) {
    if (charCodes.isEmpty) {
      return;
    }
    final text = String.fromCharCodes(charCodes);
    final cacheKey = Object.hash(
      text,
      color,
      bold,
      italic,
      overline,
      strikethrough,
      decorationColor,
      textScaler,
    );
    var paragraph = _runParagraphCache.getLayoutFromCache(cacheKey);
    if (paragraph == null) {
      final style = textStyle
          .toTextStyle(
            color: color,
            bold: bold,
            italic: italic,
            // The underline is drawn manually in the underline pass so wavy/
            // dotted/dashed/double styles render and connect across cells.
            overline: overline,
            strikethrough: strikethrough,
            decorationColor: decorationColor,
          )
          .copyWith(fontFeatures: _ligatureDisablingFeatures);
      paragraph = _runParagraphCache.performAndCacheLayout(
        text,
        style,
        textScaler,
        cacheKey,
      );
    }
    canvas.drawParagraph(paragraph, offset);
  }

  /// A content hash of [line]'s cells, used to key the foreground picture cache.
  /// Two lines that render identical glyphs produce the same hash, so a scrolled
  /// or unchanged line reuses its recorded picture. Font/theme/scale changes
  /// clear the cache, so they need not enter the hash.
  ///
  /// Folds the raw cell fields (not `CellData.getHash()`, which narrows to ~29
  /// bits) so a single differing field in any cell changes the key — including
  /// `background`, since the readable-foreground resolution tints the glyph
  /// against the cell's background.
  int _lineForegroundHash(BufferLine line) {
    final cellData = CellData.empty();
    const mask = 0x3FFFFFFFFFFFFFFF;
    const prime = 0x100000001b3;
    final length = line.length;
    var hash = (0xcbf29ce484222325 ^ length) & mask;
    for (var i = 0; i < length; i++) {
      line.getCellData(i, cellData);
      hash = ((hash ^ cellData.content) * prime) & mask;
      hash = ((hash ^ cellData.foreground) * prime) & mask;
      hash = ((hash ^ cellData.background) * prime) & mask;
      hash = ((hash ^ cellData.flags) * prime) & mask;
      hash = ((hash ^ cellData.underlineColor) * prime) & mask;
    }
    return hash;
  }

  /// Draws the styled (SGR) cell underlines for [line] in a pass separate from
  /// the glyphs. Curly/dotted/etc. underlines extend into the descender space
  /// below the cell, so drawing them after every line's opaque background keeps
  /// the next line's background from clipping the wave's lower edge.
  void paintLineCellUnderlines(Canvas canvas, Offset offset, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = cellSize.width;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final charWidth = cellData.content >> CellContent.widthShift;
      final charCode = cellData.content & CellContent.codepointMask;
      final flags = cellData.flags;
      if (charCode != 0 &&
          flags & CellFlags.invisible == 0 &&
          flags & CellFlags.underline != 0) {
        final styleIndex =
            (flags & CellFlags.underlineStyleMask) >>
            CellFlags.underlineStyleShift;
        final underlineColor = cellData.underlineColor != 0
            ? resolveForegroundColor(cellData.underlineColor)
            : resolveMonkeyTerminalCellForegroundColor(cellData);
        paintTerminalCellUnderline(
          canvas,
          offset.translate(i * cellWidth, 0),
          cellSize,
          styleIndex,
          underlineColor,
        );
      }
      if (charWidth == 2) {
        i++;
      }
    }
  }

  void paintLineBackground(Canvas canvas, Offset offset, BufferLine line) {
    if (line.length == 0) {
      return;
    }

    canvas.drawRect(
      Rect.fromLTWH(
        offset.dx,
        offset.dy,
        line.length * cellSize.width,
        cellSize.height,
      ),
      _rectPaint..color = theme.background,
    );
  }

  @override
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    final colorType = _cellBackgroundColorType(cellData);
    if (cellData.flags & CellFlags.inverse == 0 &&
        colorType == CellColor.normal) {
      return;
    }

    final charCode = cellData.content & CellContent.codepointMask;
    final paint = _rectPaint
      ..color = _resolveCellBackgroundPaintColor(
        cellData,
        toneNeutralBackgrounds: !_isRectPaintedBlockElement(charCode),
      );
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(cellSize.width * widthScale + 1, cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  bool _shouldUnderlineCell(
    int column,
    List<TerminalTextUnderline> inlineUnderlines,
  ) {
    for (final underline in inlineUnderlines) {
      if (column >= underline.startColumn && column <= underline.endColumn) {
        return true;
      }
    }
    return false;
  }

  void paintCellInlineUnderline(
    Canvas canvas,
    Offset offset,
    CellData cellData,
  ) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) {
      return;
    }

    final cacheKey = cellData.getHash() ^ textScaler.hashCode;
    var paragraph = _inlineUnderlineParagraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;
      final style = textStyle
          .toTextStyle(
            color: Colors.transparent,
            bold: cellFlags & CellFlags.bold != 0,
            italic: cellFlags & CellFlags.italic != 0,
            underline: true,
          )
          .copyWith(
            decorationColor: resolveMonkeyTerminalCellForegroundColor(cellData),
          );

      var char = String.fromCharCode(charCode);
      if (charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _inlineUnderlineParagraphCache.performAndCacheLayout(
        char,
        style,
        textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  @override
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) {
      return;
    }
    // Kitty Unicode-placeholder cells are not real glyphs: they mark where a
    // graphics image is composited over the grid (see
    // `_paintKittyPlaceholderGraphics`). Drawing the placeholder code point as
    // text would show a box that bleeds through the image's transparent edges,
    // so never render it as a glyph.
    if (charCode == kittyGraphicsPlaceholderCodePoint) {
      return;
    }

    final cellFlags = cellData.flags;
    // Conceal (SGR 8): keep the cell content for selection/copy but do not
    // draw the glyph.
    if (cellFlags & CellFlags.invisible != 0) {
      return;
    }
    // A plain space paints no glyph: its background is filled in the background
    // pass and any underline in the underline pass, so shaping and drawing a
    // space paragraph is a wasted per-cell drawParagraph. Overline and
    // strikethrough do need a drawn run across the cell (below, a space is
    // swapped for U+00A0 so the line renders), so only skip when neither is set.
    // A typical terminal screen is mostly blank cells (indentation, padding,
    // gaps between columns), so skipping them is a large cut to the per-frame
    // paint that dominates build-thread time while a full-screen TUI redraws.
    if (charCode == 0x20 &&
        cellFlags & CellFlags.overline == 0 &&
        cellFlags & CellFlags.strikethrough == 0) {
      return;
    }
    final color = resolveMonkeyTerminalCellForegroundColor(cellData);
    if (_paintBlockElementForeground(
      canvas,
      offset,
      cellData,
      charCode,
      color,
    )) {
      return;
    }

    final cacheKey = cellData.getHash() ^ textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final overline = cellFlags & CellFlags.overline != 0;
      final strikethrough = cellFlags & CellFlags.strikethrough != 0;

      final style = textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        // The underline is drawn manually below so wavy/dotted/dashed/double
        // styles render and connect across cells; Flutter's per-glyph
        // decoration cannot.
        overline: overline,
        strikethrough: strikethrough,
        decorationColor: cellData.underlineColor != 0
            ? resolveForegroundColor(cellData.underlineColor)
            : null,
      );

      var char = String.fromCharCode(charCode);
      if ((overline || strikethrough) && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  bool _paintBlockElementForeground(
    Canvas canvas,
    Offset offset,
    CellData cellData,
    int charCode,
    Color color,
  ) {
    final widthScale = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
    final width = (cellSize.width * widthScale) + 1;
    final height = cellSize.height;
    final halfWidth = width / 2;
    final halfHeight = height / 2;
    final paint = _rectPaint..color = color;

    void drawRect(
      double left,
      double top,
      double rectWidth,
      double rectHeight,
    ) {
      canvas.drawRect(
        Rect.fromLTWH(offset.dx + left, offset.dy + top, rectWidth, rectHeight),
        paint,
      );
    }

    void drawQuadrants({
      bool upperLeft = false,
      bool upperRight = false,
      bool lowerLeft = false,
      bool lowerRight = false,
    }) {
      if (upperLeft) {
        drawRect(0, 0, halfWidth, halfHeight);
      }
      if (upperRight) {
        drawRect(halfWidth, 0, width - halfWidth, halfHeight);
      }
      if (lowerLeft) {
        drawRect(0, halfHeight, halfWidth, height - halfHeight);
      }
      if (lowerRight) {
        drawRect(halfWidth, halfHeight, width - halfWidth, height - halfHeight);
      }
    }

    if (charCode >= 0x2581 && charCode <= 0x2587) {
      final blockHeight = height * (charCode - 0x2580) / 8;
      drawRect(0, height - blockHeight, width, blockHeight);
      return true;
    }
    if (charCode >= 0x2589 && charCode <= 0x258F) {
      final blockWidth = width * (0x2590 - charCode) / 8;
      drawRect(0, 0, blockWidth, height);
      return true;
    }

    switch (charCode) {
      case 0x2580:
        drawRect(0, 0, width, halfHeight);
        return true;
      case 0x2588:
        drawRect(0, 0, width, height);
        return true;
      case 0x2590:
        drawRect(halfWidth, 0, width - halfWidth, height);
        return true;
      case 0x2594:
        drawRect(0, 0, width, height / 8);
        return true;
      case 0x2595:
        drawRect(width * 7 / 8, 0, width / 8, height);
        return true;
      case 0x2596:
        drawQuadrants(lowerLeft: true);
        return true;
      case 0x2597:
        drawQuadrants(lowerRight: true);
        return true;
      case 0x2598:
        drawQuadrants(upperLeft: true);
        return true;
      case 0x2599:
        drawQuadrants(upperLeft: true, lowerLeft: true, lowerRight: true);
        return true;
      case 0x259A:
        drawQuadrants(upperLeft: true, lowerRight: true);
        return true;
      case 0x259B:
        drawQuadrants(upperLeft: true, upperRight: true, lowerLeft: true);
        return true;
      case 0x259C:
        drawQuadrants(upperLeft: true, upperRight: true, lowerRight: true);
        return true;
      case 0x259D:
        drawQuadrants(upperRight: true);
        return true;
      case 0x259E:
        drawQuadrants(upperRight: true, lowerLeft: true);
        return true;
      case 0x259F:
        drawQuadrants(upperRight: true, lowerLeft: true, lowerRight: true);
        return true;
      default:
        return false;
    }
  }

  bool _isRectPaintedBlockElement(int charCode) =>
      (charCode >= 0x2580 && charCode <= 0x2590) ||
      charCode == 0x2594 ||
      charCode == 0x2595 ||
      (charCode >= 0x2596 && charCode <= 0x259F);

  /// Whether [charCode] may be coalesced into a batched foreground style run.
  ///
  /// A run concatenates several cells into a single paragraph, so only code
  /// points that shape identically whether laid out in isolation or in sequence
  /// — and that advance exactly one measured monospace cell — are eligible.
  /// This deliberately excludes:
  /// - cursive-joining and complex scripts (Arabic, Syriac, Indic, …), whose
  ///   glyphs would connect or reorder once concatenated (mandatory
  ///   `init`/`medi`/`fina`/`isol` shaping that [_ligatureDisablingFeatures]
  ///   cannot turn off);
  /// - code points likely to fall back to a proportional or differently-metric
  ///   font, whose advance would drift the rest of the run off the grid;
  /// - Box Drawing (U+2500–U+257F). Many platform `monospace` stacks (notably
  ///   Android) do not ship these glyphs in the primary mono face, so a long
  ///   run of `─`/`│`/rounded corners falls back to another family whose
  ///   advance ≠ the cell width measured from `m`. Concatenating them into one
  ///   paragraph makes the right border of TUI frames (e.g. Codex's startup
  ///   banner) land several cells left or right of the verticals. Per-cell
  ///   painting keeps each glyph anchored to `column * cellWidth`.
  ///
  /// Block Elements at 0x2580+ are handled separately as rectangles. Everything
  /// outside this set is drawn one cell at a time by [paintCellForeground],
  /// exactly as the pre-batching path did, so their placement and shaping are
  /// unchanged.
  static bool _isBatchableForegroundCodePoint(int charCode) {
    // Basic Latin (printable) — the dominant case for high-throughput output
    // such as `tail -f`/`yes`, logs, and source code.
    if (charCode >= 0x20 && charCode <= 0x7E) {
      return true;
    }
    // Latin-1 Supplement (printable), minus the soft hyphen (a zero-width
    // format character). This block holds no combining or cursive-joining code
    // points, so isolated and in-run shaping match; it includes U+00A0, which
    // decorated spaces are substituted with.
    if (charCode >= 0xA0 && charCode <= 0xFF && charCode != 0xAD) {
      return true;
    }
    return false;
  }

  @visibleForTesting
  Color resolveMonkeyTerminalCellForegroundColor(CellData cellData) {
    final cellFlags = cellData.flags;
    final inverse = cellFlags & CellFlags.inverse != 0;
    var color = inverse
        ? resolveBackgroundColor(cellData.background)
        : resolveForegroundColor(cellData.foreground);

    if (cellFlags & CellFlags.faint != 0) {
      final background = inverse
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);
      color = resolveMonkeyTerminalFaintForegroundColor(
        foreground: color,
        background: background,
      );
    }
    if (_isRectPaintedBlockElement(
      cellData.content & CellContent.codepointMask,
    )) {
      return color;
    }

    final background = _cellPaintsBackground(cellData)
        ? _resolveCellBackgroundPaintColor(cellData)
        : theme.background;
    return resolveMonkeyTerminalReadableForegroundColor(
      foreground: color,
      background: background,
      terminalForeground: theme.foreground,
      terminalBackground: theme.background,
    );
  }

  bool _cellPaintsBackground(CellData cellData) =>
      cellData.flags & CellFlags.inverse != 0 ||
      _cellBackgroundColorType(cellData) != CellColor.normal;

  Color _resolveCellBackgroundPaintColor(
    CellData cellData, {
    bool toneNeutralBackgrounds = true,
  }) {
    final cellFlags = cellData.flags;
    final inverse = cellFlags & CellFlags.inverse != 0;
    final background = inverse
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);
    final foreground = inverse
        ? resolveBackgroundColor(cellData.background)
        : resolveForegroundColor(cellData.foreground);
    return resolveMonkeyTerminalReadableBackgroundColor(
      foreground: foreground,
      background: background,
      terminalBackground: theme.background,
      toneNeutralBackgrounds: !inverse && toneNeutralBackgrounds,
    );
  }
}

int _cellColorType(int cellColor) => cellColor & CellColor.typeMask;

int _cellBackgroundColorType(CellData cellData) =>
    _cellColorType(cellData.background);

class MonkeyRenderTerminal extends RenderBox
    with RelayoutWhenSystemFontsChangeMixin, Selectable, SelectionRegistrant {
  MonkeyRenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool alignToTrailingEdges,
    required bool autoResize,
    required bool resizeTerminalToViewport,
    required bool notifyPixelSizeChanges,
    required double resizeBottomInset,
    required bool liveOutputAutoScroll,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required List<TerminalTextUnderline> inlineUnderlines,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    EditableRectCallback? onEditableRect,
    String? composingText,
    SelectionRegistrar? selectionRegistrar,
  }) : _terminal = terminal,
       _controller = controller,
       _offset = offset,
       _padding = padding,
       _alignToTrailingEdges = alignToTrailingEdges,
       _autoResize = autoResize,
       _resizeTerminalToViewport = resizeTerminalToViewport,
       _notifyPixelSizeChanges = notifyPixelSizeChanges,
       _resizeBottomInset = resizeBottomInset,
       _liveOutputAutoScroll = liveOutputAutoScroll,
       _inlineUnderlines = inlineUnderlines,
       _focusNode = focusNode,
       _cursorType = cursorType,
       _onEditableRect = onEditableRect,
       _composingText = composingText,
       _selectionGeometry = SelectionGeometry(
         status: SelectionStatus.none,
         hasContent: terminal.buffer.lines.length > 0,
       ),
       _painter = MonkeyTerminalPainter(
         theme: theme,
         textStyle: textStyle,
         textScaler: textScaler,
       ) {
    registrar = selectionRegistrar;
  }

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _syncSelectableSelectionFromController();
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    _syncSelectableSelectionFromController();
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _alignToTrailingEdges;
  set alignToTrailingEdges(bool value) {
    if (value == _alignToTrailingEdges) return;
    _alignToTrailingEdges = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    if (!_autoResize) {
      _cancelPendingTerminalResize();
    }
    markNeedsLayout();
  }

  bool _resizeTerminalToViewport;
  set resizeTerminalToViewport(bool value) {
    if (value == _resizeTerminalToViewport) return;
    _resizeTerminalToViewport = value;
    if (!_resizeTerminalToViewport) {
      _cancelPendingTerminalResize();
    }
    markNeedsLayout();
  }

  bool _notifyPixelSizeChanges;
  set notifyPixelSizeChanges(bool value) {
    if (value == _notifyPixelSizeChanges) return;
    _notifyPixelSizeChanges = value;
    markNeedsLayout();
  }

  double _resizeBottomInset;
  set resizeBottomInset(double value) {
    if (value == _resizeBottomInset) return;
    final previousInset = _resizeBottomInset;
    _resizeBottomInset = math.max(0.0, value);
    if (previousInset > 0 || _resizeBottomInset > 0) {
      _debounceKeyboardResize();
    }
    markNeedsLayout();
  }

  /// Whether layout should keep the viewport pinned to the newest output while
  /// the user is already at the bottom.
  bool get liveOutputAutoScroll => _liveOutputAutoScroll;

  bool _liveOutputAutoScroll;
  set liveOutputAutoScroll(bool value) {
    if (value == _liveOutputAutoScroll) {
      return;
    }

    _liveOutputAutoScroll = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (_terminalThemesEqual(value, _painter.theme)) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  List<TerminalTextUnderline> _inlineUnderlines;
  set inlineUnderlines(List<TerminalTextUnderline> value) {
    if (listEquals(value, _inlineUnderlines)) return;
    _inlineUnderlines = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
  }

  set selectionRegistrar(SelectionRegistrar? value) {
    registrar = value;
  }

  TerminalSize? _viewportSize;

  TerminalSize? get viewportSize => _viewportSize;

  ({int width, int height})? _viewportPixelSize;

  Timer? _keyboardResizeDebounceTimer;

  bool _isDebouncingKeyboardResize = false;

  ({
    TerminalSize viewportSize,
    ({int width, int height}) pixelSize,
    bool resizeTerminal,
  })?
  _pendingTerminalResize;

  final MonkeyTerminalPainter _painter;
  final _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  final Set<int> _visibleGraphicsImageIds = <int>{};
  bool _hasPaintedGraphicsVisibility = false;

  Set<int>? get _paintedVisibleGraphicsImageIds =>
      _hasPaintedGraphicsVisibility ? _visibleGraphicsImageIds : null;

  var _stickToBottom = true;

  int? _selectionStartOffset;
  int? _selectionEndOffset;
  bool _isApplyingSelectableSelection = false;
  LayerLink? _startHandleLayerLink;
  LayerLink? _endHandleLayerLink;
  SelectionGeometry _selectionGeometry;
  bool _selectionGeometryNotificationScheduled = false;
  final Set<VoidCallback> _selectionListeners = <VoidCallback>{};

  int _lastKnownLineCount = -1;
  int _forceLayoutOnTerminalChangeCount = 0;
  final _cursorCellData = CellData.empty();

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    markNeedsPaint();
    if (_hasSelectableTextSelection) {
      _updateSelectionGeometry(deferNotification: true);
    }
    if (_onEditableRect != null) {
      _notifyEditableRect();
    }
  }

  void _onFocusChange() {
    if (_terminal.reportFocusMode) {
      _terminal.onOutput?.call(
        _focusNode.hasFocus ? _terminalFocusInReport : _terminalFocusOutReport,
      );
    }
    markNeedsPaint();
  }

  void _onTerminalChange() {
    _terminalChangeCount++;
    _syncSelectableSelectionFromController(deferNotification: true);
    final lineCount = _terminal.buffer.lines.length;
    if (_forceLayoutOnTerminalChangeCount > 0) {
      _forceLayoutOnTerminalChangeCount -= 1;
      _lastKnownLineCount = lineCount;
      markNeedsLayout();
    } else if (lineCount != _lastKnownLineCount) {
      _lastKnownLineCount = lineCount;
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
    if (_onEditableRect != null) {
      _notifyEditableRect();
    }
  }

  void _onControllerUpdate() {
    if (!_isApplyingSelectableSelection) {
      _syncSelectableSelectionFromController();
    }
    markNeedsLayout();
  }

  @override
  final isRepaintBoundary = true;

  int _paintCount = 0;

  /// Number of times this render object has painted a frame. Diagnostics use
  /// this together with [terminalChangeCount] to tell a frozen frame (the
  /// terminal changed but no paint followed) apart from a stalled write path.
  int get paintCount => _paintCount;

  int _terminalChangeCount = 0;

  /// Number of terminal change notifications observed (≈ one per write batch).
  /// See [paintCount].
  int get terminalChangeCount => _terminalChangeCount;

  /// Forces a full relayout and repaint of the current buffer.
  ///
  /// Safety net for multiplexer window switches: if a window-switch redraw is
  /// applied to the buffer but, for any reason, no frame is produced, the view
  /// can be left showing the previous window. Re-running layout and paint from
  /// the current buffer guarantees the visible content matches the buffer.
  void forceFullRepaint() {
    markNeedsLayout();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  void dispose() {
    _cancelPendingTerminalResize();
    _selectionListeners.clear();
    _painter.dispose();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  SelectionGeometry get value => _selectionGeometry;

  @override
  int get contentLength => _terminalSelectionContentLength;

  @override
  List<Rect> get boundingBoxes => <Rect>[Offset.zero & size];

  @override
  void addListener(VoidCallback listener) {
    _selectionListeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _selectionListeners.remove(listener);
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();
    _terminal.graphics.setCellPixelSize(
      _painter.cellSize.width,
      _painter.cellSize.height,
    );
    _updateScrollOffset();

    if (_liveOutputAutoScroll && _stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
    _updateSelectionGeometry(deferNotification: true);
  }

  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  double get _scrollOffset => _offset.pixels;

  double get lineHeight => _painter.cellSize.height;

  Offset get _contentOrigin => resolveTerminalContentOrigin(
    viewportSize: size,
    cellSize: _painter.cellSize,
    columns: _terminal.viewWidth,
    rows: _terminal.viewHeight,
    padding: _padding,
    alignToTrailingEdges: _alignToTrailingEdges,
  );

  Offset getOffset(CellOffset cellOffset) {
    final origin = _contentOrigin;
    return Offset(
      origin.dx + (cellOffset.x * _painter.cellSize.width),
      origin.dy + (cellOffset.y * _painter.cellSize.height) - _scrollOffset,
    );
  }

  CellOffset getCellOffset(Offset offset) {
    final origin = _contentOrigin;
    final x = offset.dx - origin.dx;
    final y = offset.dy - origin.dy + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;

    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  int get _lineSelectionStride => _terminal.viewWidth + 1;

  int get _terminalSelectionContentLength {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return 0;
    }
    return (lineCount * _lineSelectionStride) - 1;
  }

  int _clampSelectionOffset(int offset) =>
      offset.clamp(0, _terminalSelectionContentLength);

  bool get _hasSelectableTextSelection =>
      _selectionStartOffset != null && _selectionEndOffset != null;

  int _textOffsetForCell(CellOffset cellOffset) {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return 0;
    }
    final row = cellOffset.y.clamp(0, lineCount - 1);
    final column = cellOffset.x.clamp(0, _terminal.viewWidth);
    return _clampSelectionOffset((row * _lineSelectionStride) + column);
  }

  CellOffset _cellForTextOffset(int textOffset) {
    final lineCount = _terminal.buffer.lines.length;
    if (lineCount == 0 || _terminal.viewWidth <= 0) {
      return const CellOffset(0, 0);
    }
    final offset = _clampSelectionOffset(textOffset);
    final row = (offset ~/ _lineSelectionStride).clamp(0, lineCount - 1);
    final column = (offset % _lineSelectionStride).clamp(
      0,
      _terminal.viewWidth,
    );
    return CellOffset(column, row);
  }

  CellOffset _getSelectableCellOffset(Offset offset) {
    if (_terminal.buffer.lines.length == 0 || _terminal.viewWidth <= 0) {
      return const CellOffset(0, 0);
    }
    final origin = _contentOrigin;
    final x = offset.dx - origin.dx;
    final y = offset.dy - origin.dy + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  int _textOffsetForLocalPosition(Offset localPosition) {
    if (_terminalSelectionContentLength <= 0) {
      return 0;
    }
    return _textOffsetForCell(_getSelectableCellOffset(localPosition));
  }

  BufferRange _bufferRangeForTextOffsets(int start, int end) {
    final normalizedStart = math.min(start, end);
    final normalizedEnd = math.max(start, end);
    return BufferRangeLine(
      _cellForTextOffset(normalizedStart),
      _cellForTextOffset(normalizedEnd),
    );
  }

  ({int start, int end})? _wordTextOffsetsAt(Offset localPosition) {
    final cellOffset = getCellOffset(localPosition);
    final boundary = _terminal.buffer.getWordBoundary(cellOffset);
    if (boundary == null) {
      return null;
    }
    return (
      start: _textOffsetForCell(boundary.begin),
      end: _textOffsetForCell(boundary.end),
    );
  }

  ({int start, int end}) _lineTextOffsetsAt(Offset localPosition) {
    final cellOffset = _getSelectableCellOffset(localPosition);
    final row = cellOffset.y.clamp(0, _terminal.buffer.lines.length - 1);
    return (
      start: _textOffsetForCell(CellOffset(0, row)),
      end: _textOffsetForCell(CellOffset(_terminal.viewWidth, row)),
    );
  }

  void _applySelectableTextSelection(int start, int end) {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return;
    }
    final nextStart = _clampSelectionOffset(start);
    final nextEnd = _clampSelectionOffset(end);
    _selectionStartOffset = nextStart;
    _selectionEndOffset = nextEnd;
    _syncControllerSelectionFromSelectableOffsets();
    markNeedsPaint();
    _updateSelectionGeometry(forceNotify: true);
  }

  void _clearSelectableTextSelection() {
    if (_selectionStartOffset == null && _selectionEndOffset == null) {
      return;
    }
    _selectionStartOffset = null;
    _selectionEndOffset = null;
    _isApplyingSelectableSelection = true;
    try {
      _controller.clearSelection();
    } finally {
      _isApplyingSelectableSelection = false;
    }
    markNeedsPaint();
    _updateSelectionGeometry(forceNotify: true);
  }

  void _syncControllerSelectionFromSelectableOffsets() {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (start == null || end == null || _terminalSelectionContentLength <= 0) {
      return;
    }

    final selection = _controller.selection;
    final isControllerSelectionCurrent =
        selection != null &&
        _textOffsetForCell(selection.begin) == start &&
        _textOffsetForCell(selection.end) == end;
    if (isControllerSelectionCurrent) {
      return;
    }

    _isApplyingSelectableSelection = true;
    try {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(_cellForTextOffset(start)),
        _terminal.buffer.createAnchorFromOffset(_cellForTextOffset(end)),
        mode: SelectionMode.line,
      );
    } finally {
      _isApplyingSelectableSelection = false;
    }
  }

  void _syncSelectableSelectionFromController({
    bool deferNotification = false,
  }) {
    final selection = _controller.selection;
    if (selection == null) {
      if (_selectionStartOffset != null || _selectionEndOffset != null) {
        _selectionStartOffset = null;
        _selectionEndOffset = null;
        markNeedsPaint();
        _updateSelectionGeometry(
          deferNotification: deferNotification,
          forceNotify: true,
        );
      }
      return;
    }
    final nextStart = _textOffsetForCell(selection.begin);
    final nextEnd = _textOffsetForCell(selection.end);
    if (_selectionStartOffset == nextStart && _selectionEndOffset == nextEnd) {
      if (deferNotification) {
        _updateSelectionGeometry(deferNotification: true, forceNotify: true);
      }
      return;
    }
    _selectionStartOffset = nextStart;
    _selectionEndOffset = nextEnd;
    markNeedsPaint();
    _updateSelectionGeometry(
      deferNotification: deferNotification,
      forceNotify: true,
    );
  }

  Offset _localPositionForTextOffset(int textOffset) {
    final cellOffset = _cellForTextOffset(textOffset);
    return getOffset(cellOffset);
  }

  Offset _selectionPointForTextOffset(int textOffset) =>
      _localPositionForTextOffset(textOffset) +
      Offset(0, _painter.cellSize.height);

  List<Rect> _selectionRectsForOffsets(int start, int end) {
    if (start == end || _terminal.buffer.lines.length == 0) {
      return const <Rect>[];
    }
    final begin = _cellForTextOffset(math.min(start, end));
    final finish = _cellForTextOffset(math.max(start, end));
    final rects = <Rect>[];
    for (var row = begin.y; row <= finish.y; row++) {
      final startColumn = row == begin.y ? begin.x : 0;
      final endColumn = row == finish.y ? finish.x : _terminal.viewWidth;
      if (endColumn <= startColumn) {
        continue;
      }
      final topLeft = getOffset(CellOffset(startColumn, row));
      rects.add(
        Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          (endColumn - startColumn) * _painter.cellSize.width,
          _painter.cellSize.height,
        ),
      );
    }
    return rects;
  }

  SelectionGeometry _computeSelectionGeometry() {
    final hasContent = _terminalSelectionContentLength > 0;
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (!hasContent || start == null || end == null) {
      return SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: hasContent,
      );
    }

    final isCollapsed = start == end;
    final isReversed = start > end;
    final startHandleType = isCollapsed
        ? TextSelectionHandleType.collapsed
        : isReversed
        ? TextSelectionHandleType.right
        : TextSelectionHandleType.left;
    final endHandleType = isCollapsed
        ? TextSelectionHandleType.collapsed
        : isReversed
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;

    return SelectionGeometry(
      startSelectionPoint: SelectionPoint(
        localPosition: _selectionPointForTextOffset(start),
        lineHeight: _painter.cellSize.height,
        handleType: startHandleType,
      ),
      endSelectionPoint: SelectionPoint(
        localPosition: _selectionPointForTextOffset(end),
        lineHeight: _painter.cellSize.height,
        handleType: endHandleType,
      ),
      selectionRects: _selectionRectsForOffsets(start, end),
      status: isCollapsed
          ? SelectionStatus.collapsed
          : SelectionStatus.uncollapsed,
      hasContent: hasContent,
    );
  }

  void _updateSelectionGeometry({
    bool deferNotification = false,
    bool forceNotify = false,
  }) {
    final nextGeometry = _computeSelectionGeometry();
    final didChange = nextGeometry != _selectionGeometry;
    if (!didChange && !forceNotify) {
      return;
    }
    if (didChange) {
      _selectionGeometry = nextGeometry;
    }
    if (deferNotification) {
      _scheduleSelectionGeometryNotification();
      return;
    }
    _notifySelectionGeometryListeners();
  }

  void _scheduleSelectionGeometryNotification() {
    if (_selectionGeometryNotificationScheduled) {
      return;
    }
    _selectionGeometryNotificationScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _selectionGeometryNotificationScheduled = false;
      if (!attached) {
        return;
      }
      _notifySelectionGeometryListeners();
    });
  }

  void _notifySelectionGeometryListeners() {
    for (final listener in List<VoidCallback>.of(_selectionListeners)) {
      listener();
    }
  }

  @override
  SelectedContent? getSelectedContent() {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (start == null || end == null || start == end) {
      return null;
    }
    final text = _terminal.buffer.getText(
      _bufferRangeForTextOffsets(start, end),
    );
    final trimmedText = trimTerminalSelectionText(text);
    return trimmedText.isEmpty ? null : SelectedContent(plainText: trimmedText);
  }

  @override
  SelectedContentRange? getSelection() {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (start == null || end == null) {
      return null;
    }
    return SelectedContentRange(startOffset: start, endOffset: end);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final previousStart = _selectionStartOffset;
    final previousEnd = _selectionEndOffset;
    final result = switch (event.type) {
      SelectionEventType.clear => _handleSelectableClearSelection(),
      SelectionEventType.selectAll => _handleSelectableSelectAll(),
      SelectionEventType.selectWord => _handleSelectableSelectWord(
        event as SelectWordSelectionEvent,
      ),
      SelectionEventType.selectParagraph => _handleSelectableSelectParagraph(
        event as SelectParagraphSelectionEvent,
      ),
      SelectionEventType.startEdgeUpdate || SelectionEventType.endEdgeUpdate =>
        _handleSelectableEdgeUpdate(event as SelectionEdgeUpdateEvent),
      SelectionEventType.granularlyExtendSelection =>
        _handleSelectableGranularExtension(
          event as GranularlyExtendSelectionEvent,
        ),
      SelectionEventType.directionallyExtendSelection =>
        _handleSelectableDirectionalExtension(
          event as DirectionallyExtendSelectionEvent,
        ),
    };
    if (previousStart != _selectionStartOffset ||
        previousEnd != _selectionEndOffset) {
      _updateSelectionGeometry(forceNotify: true);
    }
    return result;
  }

  SelectionResult _handleSelectableClearSelection() {
    _clearSelectableTextSelection();
    return SelectionResult.none;
  }

  SelectionResult _handleSelectableSelectAll() {
    _applySelectableTextSelection(0, _terminalSelectionContentLength);
    return SelectionResult.none;
  }

  SelectionResult _handleSelectableSelectWord(SelectWordSelectionEvent event) {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return SelectionResult.none;
    }

    final localPosition = globalToLocal(event.globalPosition);
    final offsets = _wordTextOffsetsAt(localPosition);
    if (offsets == null) {
      final collapsedOffset = _textOffsetForLocalPosition(localPosition);
      _applySelectableTextSelection(collapsedOffset, collapsedOffset);
      return SelectionResult.end;
    }

    _applySelectableTextSelection(offsets.start, offsets.end);
    return SelectionResult.end;
  }

  SelectionResult _handleSelectableSelectParagraph(
    SelectParagraphSelectionEvent event,
  ) {
    final offsets = _lineTextOffsetsAt(globalToLocal(event.globalPosition));
    _applySelectableTextSelection(offsets.start, offsets.end);
    return SelectionResult.end;
  }

  SelectionResult _handleSelectableEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (_terminalSelectionContentLength <= 0) {
      _clearSelectableTextSelection();
      return SelectionResult.none;
    }
    final localPosition = globalToLocal(event.globalPosition);
    final adjustedPosition = _adjustSelectableDragPosition(localPosition);
    final hitOffset = event.granularity == TextGranularity.word
        ? _wordEdgeOffsetForPosition(
            adjustedPosition,
            updateEnd: event.type == SelectionEventType.endEdgeUpdate,
          )
        : _textOffsetForLocalPosition(adjustedPosition);
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _applySelectableTextSelection(
        hitOffset,
        _selectionEndOffset ?? hitOffset,
      );
    } else {
      _applySelectableTextSelection(
        _selectionStartOffset ?? hitOffset,
        hitOffset,
      );
    }
    return _selectionResultForDragPosition(localPosition, hitOffset);
  }

  Rect get _selectableContentRect {
    final origin = _contentOrigin;
    return Rect.fromLTWH(
      origin.dx,
      origin.dy - _scrollOffset,
      _terminal.viewWidth * _painter.cellSize.width,
      _terminalHeight,
    );
  }

  Offset _adjustSelectableDragPosition(Offset localPosition) {
    final contentRect = _selectableContentRect;
    if (contentRect.isEmpty) {
      return localPosition;
    }
    return Offset(
      localPosition.dx.clamp(contentRect.left, contentRect.right),
      localPosition.dy.clamp(contentRect.top, contentRect.bottom),
    );
  }

  SelectionResult _selectionResultForDragPosition(
    Offset localPosition,
    int hitOffset,
  ) {
    final contentRect = _selectableContentRect;
    if (contentRect.isEmpty) {
      return SelectionResult.none;
    }
    if (localPosition.dy < contentRect.top ||
        (hitOffset == 0 && localPosition.dx < contentRect.left)) {
      return SelectionResult.previous;
    }
    if (localPosition.dy > contentRect.bottom ||
        (hitOffset == _terminalSelectionContentLength &&
            localPosition.dx > contentRect.right)) {
      return SelectionResult.next;
    }
    return SelectionResult.end;
  }

  int _wordEdgeOffsetForPosition(
    Offset localPosition, {
    required bool updateEnd,
  }) {
    final offsets = _wordTextOffsetsAt(localPosition);
    if (offsets == null) {
      return _textOffsetForLocalPosition(localPosition);
    }
    final staticEdge = updateEnd ? _selectionStartOffset : _selectionEndOffset;
    if (staticEdge == null) {
      return updateEnd ? offsets.end : offsets.start;
    }
    final hit = _textOffsetForLocalPosition(localPosition);
    if (hit < staticEdge) {
      return offsets.start;
    }
    if (hit > staticEdge) {
      return offsets.end;
    }
    return updateEnd ? offsets.end : offsets.start;
  }

  SelectionResult _handleSelectableGranularExtension(
    GranularlyExtendSelectionEvent event,
  ) {
    final currentStart =
        _selectionStartOffset ??
        (event.forward ? 0 : _terminalSelectionContentLength);
    final currentEnd = _selectionEndOffset ?? currentStart;
    final movingOffset = event.isEnd ? currentEnd : currentStart;
    final nextOffset = event.forward
        ? (movingOffset + 1).clamp(0, _terminalSelectionContentLength)
        : (movingOffset - 1).clamp(0, _terminalSelectionContentLength);
    if (event.isEnd) {
      _applySelectableTextSelection(currentStart, nextOffset);
    } else {
      _applySelectableTextSelection(nextOffset, currentEnd);
    }
    return nextOffset == 0
        ? SelectionResult.previous
        : nextOffset == _terminalSelectionContentLength
        ? SelectionResult.next
        : SelectionResult.end;
  }

  SelectionResult _handleSelectableDirectionalExtension(
    DirectionallyExtendSelectionEvent event,
  ) {
    final currentStart =
        _selectionStartOffset ??
        (event.direction == SelectionExtendDirection.backward
            ? contentLength
            : 0);
    final currentEnd = _selectionEndOffset ?? currentStart;
    final movingOffset = event.isEnd ? currentEnd : currentStart;
    final movingCell = _cellForTextOffset(movingOffset);
    final nextCell = switch (event.direction) {
      SelectionExtendDirection.previousLine => CellOffset(
        (event.dx / _painter.cellSize.width).round().clamp(
          0,
          _terminal.viewWidth,
        ),
        (movingCell.y - 1).clamp(0, _terminal.buffer.lines.length - 1),
      ),
      SelectionExtendDirection.nextLine => CellOffset(
        (event.dx / _painter.cellSize.width).round().clamp(
          0,
          _terminal.viewWidth,
        ),
        (movingCell.y + 1).clamp(0, _terminal.buffer.lines.length - 1),
      ),
      SelectionExtendDirection.forward => CellOffset(
        (movingCell.x + 1).clamp(0, _terminal.viewWidth),
        movingCell.y,
      ),
      SelectionExtendDirection.backward => CellOffset(
        (movingCell.x - 1).clamp(0, _terminal.viewWidth),
        movingCell.y,
      ),
    };
    final nextOffset = _textOffsetForCell(nextCell);
    if (event.isEnd) {
      _applySelectableTextSelection(currentStart, nextOffset);
    } else {
      _applySelectableTextSelection(nextOffset, currentEnd);
    }
    return nextOffset == 0
        ? SelectionResult.previous
        : nextOffset == _terminalSelectionContentLength
        ? SelectionResult.next
        : SelectionResult.end;
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    var needsPaint = false;
    if (_startHandleLayerLink != startHandle) {
      _startHandleLayerLink = startHandle;
      needsPaint = true;
    }
    if (_endHandleLayerLink != endHandle) {
      _endHandleLayerLink = endHandle;
      needsPaint = true;
    }
    if (needsPaint && attached) {
      markNeedsPaint();
    }
  }

  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  void _updateViewportSize({bool notifyIfUnchanged = false}) {
    final availableWidth = size.width - _padding.horizontal;
    final availableHeight = _viewportHeight;
    final cellWidth = _painter.cellSize.width;
    final cellHeight = _painter.cellSize.height;
    // Bail on a degenerate or unusably small cell (e.g. a transient sub-pixel
    // or non-finite font size mid-pinch). Resizing the grid for such a cell
    // both divides by ~0 and can blow the grid up to thousands of cells, which
    // then crashes the buffer reflow on the way back down.
    const minUsableCell = 2.0;
    if (!cellWidth.isFinite ||
        !cellHeight.isFinite ||
        cellWidth < minUsableCell ||
        cellHeight < minUsableCell ||
        availableWidth <= cellWidth ||
        availableHeight <= cellHeight) {
      return;
    }

    final viewportSize = TerminalSize(
      availableWidth ~/ cellWidth,
      availableHeight ~/ cellHeight,
    );
    final pixelSize = resolveTerminalResizePixelDimensions(
      viewportSize: size,
      padding: _padding,
    );

    final terminalNeedsResize =
        _terminal.viewWidth != viewportSize.width ||
        _terminal.viewHeight != viewportSize.height;
    final hasCachedViewportSize = _viewportSize != null;
    final viewportSizeChanged = _viewportSize != viewportSize;
    final pixelSizeChanged = _viewportPixelSize != pixelSize;

    if (!_resizeTerminalToViewport) {
      _viewportSize = viewportSize;
      _viewportPixelSize = pixelSize;
      // The host owns the shared grid. Passive layout reports the initial or a
      // genuinely changed local viewport, but does not repeatedly reassert a
      // persistent host mismatch or a suppressed pixel-only change. Explicit
      // refresh/reconciliation still uses notifyIfUnchanged.
      if (!hasCachedViewportSize ||
          viewportSizeChanged ||
          (_notifyPixelSizeChanges && pixelSizeChanged) ||
          notifyIfUnchanged) {
        _notifyTerminalResizeIfNeeded(
          viewportSize: viewportSize,
          pixelSize: pixelSize,
        );
      }
      return;
    }

    if (terminalNeedsResize) {
      _resizeTerminalIfNeeded(viewportSize: viewportSize, pixelSize: pixelSize);
      return;
    }

    _viewportSize = viewportSize;
    _viewportPixelSize = pixelSize;

    if ((hasCachedViewportSize &&
            _notifyPixelSizeChanges &&
            pixelSizeChanged) ||
        notifyIfUnchanged) {
      _notifyTerminalResizeIfNeeded(
        viewportSize: viewportSize,
        pixelSize: pixelSize,
      );
    }
  }

  void _refreshTerminalSize({bool flushKeyboardResize = false}) {
    if (!hasSize) {
      markNeedsLayout();
      return;
    }
    if (flushKeyboardResize) {
      _cancelPendingTerminalResize();
    }
    _updateViewportSize(notifyIfUnchanged: true);
    markNeedsPaint();
  }

  void _refreshTerminalDisplay({bool revealLatestOutput = false}) {
    if (revealLatestOutput) {
      _stickToBottom = true;
      _lastKnownLineCount = -1;
      _forceLayoutOnTerminalChangeCount = 4;
    }
    if (!hasSize) {
      markNeedsLayout();
      return;
    }
    _updateViewportSize(notifyIfUnchanged: true);
    markNeedsLayout();
    markNeedsPaint();
  }

  void _resizeTerminalIfNeeded({
    TerminalSize? viewportSize,
    ({int width, int height})? pixelSize,
  }) {
    if (!_autoResize) {
      return;
    }
    final nextViewportSize = viewportSize ?? _viewportSize;
    if (nextViewportSize == null) {
      return;
    }
    final nextPixelSize =
        pixelSize ??
        resolveTerminalResizePixelDimensions(
          viewportSize: size,
          padding: _padding,
        );

    if (_isDebouncingKeyboardResize) {
      _pendingTerminalResize = (
        viewportSize: nextViewportSize,
        pixelSize: nextPixelSize,
        resizeTerminal: true,
      );
      return;
    }

    _applyTerminalResize(nextViewportSize, nextPixelSize);
  }

  void _notifyTerminalResizeIfNeeded({
    required TerminalSize viewportSize,
    required ({int width, int height}) pixelSize,
  }) {
    if (!_autoResize) {
      return;
    }

    if (_isDebouncingKeyboardResize) {
      final pendingResize = _pendingTerminalResize;
      if (pendingResize != null && pendingResize.resizeTerminal) {
        return;
      }
      _pendingTerminalResize = (
        viewportSize: viewportSize,
        pixelSize: pixelSize,
        resizeTerminal: false,
      );
      return;
    }

    _notifyTerminalResize(viewportSize, pixelSize);
  }

  void _applyTerminalResize(
    TerminalSize viewportSize,
    ({int width, int height}) pixelSize,
  ) {
    _viewportSize = viewportSize;
    _viewportPixelSize = pixelSize;
    _terminal.resize(
      viewportSize.width,
      viewportSize.height,
      pixelSize.width,
      pixelSize.height,
    );
    // Terminal.resize does not notify listeners. Recompute text offsets from
    // the reflowed anchors before layout updates the selection geometry.
    _syncSelectableSelectionFromController(deferNotification: true);
  }

  void _notifyTerminalResize(
    TerminalSize viewportSize,
    ({int width, int height}) pixelSize,
  ) {
    _viewportSize = viewportSize;
    _viewportPixelSize = pixelSize;
    _terminal.onResize?.call(
      viewportSize.width,
      viewportSize.height,
      pixelSize.width,
      pixelSize.height,
    );
  }

  void _debounceKeyboardResize() {
    _isDebouncingKeyboardResize = true;
    _keyboardResizeDebounceTimer?.cancel();
    _keyboardResizeDebounceTimer = Timer(
      terminalKeyboardResizeDebounceDuration,
      () {
        _keyboardResizeDebounceTimer = null;
        _isDebouncingKeyboardResize = false;
        final pendingResize = _pendingTerminalResize;
        _pendingTerminalResize = null;
        if (pendingResize == null || !_autoResize) {
          return;
        }
        if (pendingResize.resizeTerminal) {
          _applyTerminalResize(
            pendingResize.viewportSize,
            pendingResize.pixelSize,
          );
        } else {
          _notifyTerminalResize(
            pendingResize.viewportSize,
            pendingResize.pixelSize,
          );
        }
      },
    );
  }

  void _cancelPendingTerminalResize() {
    _keyboardResizeDebounceTimer?.cancel();
    _keyboardResizeDebounceTimer = null;
    _isDebouncingKeyboardResize = false;
    _pendingTerminalResize = null;
  }

  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText =>
      _composingText != null && _composingText!.isNotEmpty;

  bool get _shouldShowCursor => _terminal.cursorVisibleMode || _isComposingText;

  double get _viewportHeight => size.height - _padding.vertical;

  double get _maxScrollExtent =>
      math.max(_terminalHeight - _viewportHeight, 0.0);

  double get _lineOffset => -_scrollOffset + _contentOrigin.dy;

  Offset get cursorOffset => Offset(
    _contentOrigin.dx + (_terminal.buffer.cursorX * _painter.cellSize.width),
    (_terminal.buffer.absoluteCursorY * _painter.cellSize.height) + _lineOffset,
  );

  Size get cellSize => _painter.cellSize;

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintCount++;
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled) {
      _measureTerminalPaintPhases = false;
      _paint(context, offset);
      context.setWillChangeHint();
      return;
    }
    // Measure the whole terminal paint so a capture can attribute build-thread
    // jank to the terminal render (text shaping, image compositing) versus the
    // surrounding widget rebuild. Timing only.
    _measureTerminalPaintPhases = true;
    _lastForegroundPaintMicros = 0;
    final stopwatch = Stopwatch()..start();
    _paint(context, offset);
    _maybeLogTerminalPaint(stopwatch.elapsedMicroseconds);
    context.setWillChangeHint();
  }

  int _terminalPaintLogAtMs = 0;
  bool _measureTerminalPaintPhases = false;
  int _lastForegroundPaintMicros = 0;

  void _maybeLogTerminalPaint(int micros) {
    if (micros < 8000) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _terminalPaintLogAtMs < 1000) {
      return;
    }
    _terminalPaintLogAtMs = nowMs;
    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;
    final visibleRows = charHeight > 0 ? (size.height / charHeight).ceil() : 0;
    DiagnosticsLogService.instance.debug(
      'terminal.paint',
      'frame',
      fields: {
        'durationMs': (micros / 1000).round(),
        'foregroundMs': (_lastForegroundPaintMicros / 1000).round(),
        'visibleRows': visibleRows,
        'bufferLines': lines.length,
        'hasImages':
            _terminal.graphics.imageCount > 0 ||
            _terminal.graphics.hasPlaceholders,
      },
    );
  }

  void _paint(PaintingContext context, Offset offset) {
    _visibleGraphicsImageIds.clear();
    _hasPaintedGraphicsVisibility = true;
    final canvas = context.canvas;
    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;
    final origin = _contentOrigin;
    final firstLineOffset = _scrollOffset - origin.dy;
    final lastLineOffset = _scrollOffset - origin.dy + size.height;
    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;
    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);
    final visiblePhysicalPlacements = _terminal.graphics.placementsInRows(
      lines,
      effectFirstLine,
      effectLastLine,
    );

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLineBackgrounds(
        canvas,
        _linePaintOffset(offset, i),
        lines[i],
      );
    }

    // Images with a negative z-index render behind the terminal text.
    _paintGraphics(
      canvas,
      offset,
      effectFirstLine,
      effectLastLine,
      physicalPlacements: visiblePhysicalPlacements,
      belowText: true,
    );

    // Glyphs are drawn in a pass after every line's opaque background so a
    // descender (the bottom of "g"/"y"/"p") that extends past its cell box is
    // not clipped by the next line's background.
    final foregroundStopwatch = _measureTerminalPaintPhases
        ? (Stopwatch()..start())
        : null;
    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLineForegrounds(
        canvas,
        _linePaintOffset(offset, i),
        lines[i],
      );
    }
    if (foregroundStopwatch != null) {
      _lastForegroundPaintMicros = foregroundStopwatch.elapsedMicroseconds;
    }

    // Styled underlines are drawn as a separate pass, after every line's opaque
    // background, so a curly/dotted underline that dips into the descender space
    // below its cell is not clipped by the next line's background.
    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLineCellUnderlines(
        canvas,
        _linePaintOffset(offset, i),
        lines[i],
      );
    }

    _paintGraphics(
      canvas,
      offset,
      effectFirstLine,
      effectLastLine,
      physicalPlacements: visiblePhysicalPlacements,
    );

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      }

      if (_shouldShowCursor) {
        _paintCursor(canvas, offset + cursorOffset);
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    final selection = _selectionRangeForPaint;
    if (selection != null) {
      _paintSelection(canvas, selection, effectFirstLine, effectLastLine);
    }

    // Keep link affordances visible over opaque selection/highlight fills while
    // preserving each cell's own underline styling.
    _paintInlineUnderlines(canvas, offset, effectFirstLine, effectLastLine);

    _paintSelectionHandleLayers(context, offset);
  }

  Offset _linePaintOffset(Offset offset, int row) => offset.translate(
    _contentOrigin.dx,
    (row * _painter.cellSize.height + _lineOffset).truncateToDouble(),
  );

  /// Composites Kitty-graphics-protocol images over the cell grid for the
  /// visible rows ([firstLine]..[lastLine], inclusive).
  ///
  /// When [belowText] is true only placements with a negative z-index are drawn
  /// (these sit behind the terminal text); otherwise placements with a
  /// non-negative z-index and the Unicode placeholders are drawn on top.
  void _paintGraphics(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine, {
    required List<TerminalImagePlacement> physicalPlacements,
    bool belowText = false,
  }) {
    final graphics = _terminal.graphics;
    // A pending virtual image has neither a physical placement nor a decoded
    // image yet. Its foreground placeholder pass must run so visible cells can
    // trigger the deferred decode; the below-text pass has nothing to do.
    final hasPlaceholderGraphics = !belowText && graphics.hasPlaceholders;
    if (physicalPlacements.isEmpty &&
        graphics.imageCount == 0 &&
        !hasPlaceholderGraphics) {
      return;
    }

    final cellWidth = _painter.cellSize.width;
    final cellHeight = _painter.cellSize.height;
    // Guard against transient degenerate metrics (zero/non-finite cell size, or
    // a zero view width) that can occur during a relayout/pinch-zoom. Besides
    // the unsafe cell-size arithmetic, an auto-sized placement below computes
    // `(viewWidth - col).clamp(1, viewWidth)`, which throws when viewWidth <= 0
    // (lower limit above upper limit) — and that runs outside the draw try/catch.
    if (!cellWidth.isFinite ||
        !cellHeight.isFinite ||
        cellWidth <= 0 ||
        cellHeight <= 0 ||
        _terminal.viewWidth <= 0) {
      return;
    }

    // Draw lower z-indices first so higher ones stack on top; ties keep
    // insertion order (placement id increases monotonically).
    final placements =
        physicalPlacements.where((p) => belowText ? p.z < 0 : p.z >= 0).toList()
          ..sort((a, b) {
            final byZ = a.z.compareTo(b.z);
            return byZ != 0 ? byZ : a.placementId.compareTo(b.placementId);
          });

    for (final placement in placements) {
      if (!placement.attached) {
        continue;
      }
      final stored = graphics.imageForPlacement(placement.imageId);
      if (stored == null) {
        continue;
      }
      final image = stored.image;
      final imageWidth = image.width.toDouble();
      final imageHeight = image.height.toDouble();

      // Kitty crop coordinates use the original source dimensions. Encoded
      // images may have been downscaled while decoding, so map the logical crop
      // into the decoded image before painting it.
      final sourceWidth = stored.sourceWidth > 0
          ? stored.sourceWidth.toDouble()
          : imageWidth;
      final sourceHeight = stored.sourceHeight > 0
          ? stored.sourceHeight.toDouble()
          : imageHeight;
      final logicalSrcLeft = placement.srcX.toDouble().clamp(0.0, sourceWidth);
      final logicalSrcTop = placement.srcY.toDouble().clamp(0.0, sourceHeight);
      final logicalSrcWidth =
          (placement.srcWidth > 0
                  ? placement.srcWidth.toDouble()
                  : sourceWidth - logicalSrcLeft)
              .clamp(0.0, sourceWidth - logicalSrcLeft);
      final logicalSrcHeight =
          (placement.srcHeight > 0
                  ? placement.srcHeight.toDouble()
                  : sourceHeight - logicalSrcTop)
              .clamp(0.0, sourceHeight - logicalSrcTop);
      final scaleX = imageWidth / sourceWidth;
      final scaleY = imageHeight / sourceHeight;
      final srcLeft = logicalSrcLeft * scaleX;
      final srcTop = logicalSrcTop * scaleY;
      final srcWidth = logicalSrcWidth * scaleX;
      final srcHeight = logicalSrcHeight * scaleY;
      if (srcWidth <= 0 || srcHeight <= 0) {
        continue;
      }

      final double dstWidth;
      final double dstHeight;
      if (placement.cols > 0 && placement.rows > 0) {
        dstWidth = placement.cols * cellWidth;
        dstHeight = placement.rows * cellHeight;
      } else if (placement.cols > 0) {
        dstWidth = placement.cols * cellWidth;
        dstHeight = srcHeight * (dstWidth / srcWidth);
      } else if (placement.rows > 0) {
        dstHeight = placement.rows * cellHeight;
        dstWidth = srcWidth * (dstHeight / srcHeight);
      } else {
        // No explicit cell span: fit the (cropped) source width within the row.
        final maxWidth =
            (_terminal.viewWidth - placement.col).clamp(
              1,
              _terminal.viewWidth,
            ) *
            cellWidth;
        final scale = srcWidth > maxWidth ? maxWidth / srcWidth : 1.0;
        dstWidth = srcWidth * scale;
        dstHeight = srcHeight * scale;
      }
      if (!dstWidth.isFinite ||
          !dstHeight.isFinite ||
          dstWidth <= 0 ||
          dstHeight <= 0) {
        continue;
      }

      // Apply the in-cell pixel offset (X=,Y=) to the destination top-left.
      final topLeft = _linePaintOffset(offset, placement.row).translate(
        placement.col * cellWidth + placement.xOffset,
        placement.yOffset.toDouble(),
      );
      if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) {
        continue;
      }
      final destination = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        dstWidth,
        dstHeight,
      );
      if (!destination.overlaps(offset & size)) {
        continue;
      }
      _visibleGraphicsImageIds.add(stored.id);

      // Defense in depth: image compositing is non-essential overlay drawing,
      // but an exception here (e.g. a disposed image surfaced by an unexpected
      // race) would crash the whole terminal paint and tear down the user's
      // session. Skip the offending image for this frame instead.
      try {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(srcLeft, srcTop, srcWidth, srcHeight),
          destination,
          _imagePaint,
        );
      } on Object catch (_) {
        // Intentionally swallowed: a failed image draw must never crash the
        // terminal. The next frame re-attempts with fresh metrics.
      }
    }

    if (belowText) {
      return;
    }
    _paintKittyPlaceholderGraphics(
      canvas,
      offset,
      firstLine,
      lastLine,
      cellWidth,
      cellHeight,
    );
  }

  void _paintKittyPlaceholderGraphics(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
    double cellWidth,
    double cellHeight,
  ) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled) {
      _paintKittyPlaceholderGraphicsImpl(
        canvas,
        offset,
        firstLine,
        lastLine,
        cellWidth,
        cellHeight,
      );
      return;
    }
    // Measure the placeholder compositing cost so a diagnostics capture can
    // confirm whether an image-heavy window's build-thread jank comes from this
    // path and whether the viewport-bounded analysis keeps it cheap. Count and
    // timing only — never any cell content.
    final placeholderCount = _terminal.graphics.placeholderCount;
    _kittyResolvedInstances = 0;
    _kittyUnresolvedInstances = 0;
    _kittyFirstUnresolvedImageId = 0;
    _kittyFirstUnresolvedBitWidth = 0;
    final stopwatch = Stopwatch()..start();
    _paintKittyPlaceholderGraphicsImpl(
      canvas,
      offset,
      firstLine,
      lastLine,
      cellWidth,
      cellHeight,
    );
    _maybeLogKittyPlaceholderPaint(
      placeholderCount,
      _terminal.graphics.imageCount,
      firstLine,
      lastLine,
      stopwatch.elapsedMicroseconds,
    );
  }

  int _kittyPlaceholderPaintLogAtMs = 0;

  // Per-paint tallies (diagnostics only): how many on-screen placeholder runs
  // resolved to a ready image versus not (pending decode or missing). A window
  // that shows placeholder cells but resolves nothing — e.g. after a reattach
  // that restored the image bytes but never re-decoded/placed them — is the
  // "images blank until the CLI redraws" signature.
  int _kittyResolvedInstances = 0;
  int _kittyUnresolvedInstances = 0;
  // The protocol image id (and its placeholder bit width) of the first on-screen
  // placeholder run that could not resolve to a stored image this paint. With
  // the retained image ids present, a capture can tell whether the id is simply
  // missing (server skipped it / it was dropped) or present but not matched.
  int _kittyFirstUnresolvedImageId = 0;
  int _kittyFirstUnresolvedBitWidth = 0;

  void _maybeLogKittyPlaceholderPaint(
    int placeholderCount,
    int imageCount,
    int firstLine,
    int lastLine,
    int micros,
  ) {
    // Report the graphics state whenever the window holds any image bytes or
    // placeholder cells, throttled to at most one entry per second so a busy
    // scroll does not flood the ring buffer. Logging even when the paint is
    // cheap lets a capture confirm the window is image-heavy, that the
    // viewport-bounded analysis stays cheap, and — for the "images blank after
    // reconnect" report — whether placeholder cells are present at all and
    // whether they resolve to a ready image.
    if (placeholderCount == 0 && imageCount == 0) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _kittyPlaceholderPaintLogAtMs < 1000) {
      return;
    }
    _kittyPlaceholderPaintLogAtMs = nowMs;
    DiagnosticsLogService.instance.debug(
      'terminal.graphics',
      'placeholder_paint',
      fields: {
        'placeholders': placeholderCount,
        'images': imageCount,
        'visibleRows': lastLine - firstLine + 1,
        'durationMs': (micros / 1000).round(),
        'resolved': _kittyResolvedInstances,
        'unresolved': _kittyUnresolvedInstances,
        if (_kittyUnresolvedInstances > 0) ...{
          'missId': _kittyFirstUnresolvedImageId,
          'missBits': _kittyFirstUnresolvedBitWidth,
          'heldIds': _terminal.graphics
              .heldImageSignatures()
              .keys
              .take(8)
              .join(','),
        },
      },
    );
  }

  void _paintKittyPlaceholderGraphicsImpl(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
    double cellWidth,
    double cellHeight,
  ) {
    final graphics = _terminal.graphics;
    final buffer = _terminal.buffer;
    final placeholders = graphics.placeholdersInRows(
      buffer.lines,
      firstLine,
      lastLine,
    );
    if (placeholders.isEmpty) {
      return;
    }

    final lineCount = buffer.lines.length;

    bool cellIsLivePlaceholder(int cellRow, int cellCol) {
      if (cellRow < 0 || cellRow >= lineCount) {
        return false;
      }
      final line = buffer.lines[cellRow];
      if (cellCol < 0 || cellCol >= line.length) {
        return false;
      }
      return line.getCodePoint(cellCol) == kittyGraphicsPlaceholderCodePoint;
    }

    // Pass 1: group live placeholder cells into display *instances* and decide
    // which instances are coherent and current enough to paint.
    //
    // A Kitty Unicode-placeholder image is conceptually a solid rectangle:
    // clients (e.g. Copilot CLI) emit every cell of the grid. The same image id
    // can be displayed several times at different screen positions, and an image
    // can be partially scrolled off or partially overwritten. We group cells by
    // the placement offset they share — every cell of one on-screen placement
    // has the same `cellRow - imgRow` and `cellCol - imgCol` — so distinct
    // placements (and the holes punched by an app overwriting an image) fall
    // into separate groups. Each group is then judged on two axes:
    //
    //  * Density — a solid image or a clean scroll crop (whole rows scrolled
    //    off) fills its bounding box (~1.0); a torn remnant overwritten in a
    //    scattered pattern leaves a box full of holes. Sparse groups are
    //    dropped so stale fragments/stripes are not painted.
    //  * Recency — when an app re-displays an image (e.g. closing its full-screen
    //    viewer and redrawing) without clearing the previous copy's cells, the
    //    old copy lingers as a ghost. Among the surviving dense groups of one
    //    image id we keep only the most recently written placement.
    //
    // The instance grouping and lookup are scoped to visible buffer lines.
    // GraphicsManager resolves placeholders through each line's CellAnchors, so
    // a scroll frame never walks the thousands of off-screen cells retained by a
    // long agent transcript. Grid dimensions remain correct for cropped images:
    // every placeholder shares a small grid tracker that records the largest
    // row/column ever seen for that image, while virtual placements still win
    // when the protocol supplied explicit dimensions.
    final gridColsByImage = <int, int>{};
    final gridRowsByImage = <int, int>{};
    final instanceCellCount = <String, int>{};
    final instanceRowBounds = <String, List<int>>{};
    final instanceColBounds = <String, List<int>>{};
    // Recency of each instance: the highest monotonic placeholder sequence seen
    // for it, independent of visible row/anchor traversal order. A redraw that re-displays an image
    // elsewhere appends fresh placeholders, so the current placement has a
    // higher recency than a stale leftover (ghost) of the same image.
    final instanceRecency = <String, int>{};
    final instanceImageKey = <String, String>{};

    String instanceKeyFor(TerminalImagePlaceholder p, String imageKey) {
      final offsetRow = p.cellRow - p.row;
      final offsetCol = p.cellCol - p.col;
      return '$imageKey@$offsetRow,$offsetCol';
    }

    for (final placeholder in placeholders) {
      if (!placeholder.attached) {
        continue;
      }
      final virtualPlacement = graphics.virtualPlacementById(
        placeholder.imageId,
      );
      final imageIntKey =
          placeholder.imageId * 64 + placeholder.imageIdBitWidth;
      gridColsByImage[imageIntKey] = (virtualPlacement?.cols ?? 0) > 0
          ? virtualPlacement!.cols
          : placeholder.gridColumns;
      gridRowsByImage[imageIntKey] = (virtualPlacement?.rows ?? 0) > 0
          ? virtualPlacement!.rows
          : placeholder.gridRows;

      final cellRow = placeholder.cellRow;
      if (cellRow < firstLine || cellRow > lastLine) {
        continue;
      }
      if (!cellIsLivePlaceholder(cellRow, placeholder.cellCol)) {
        continue;
      }
      final key = '${placeholder.imageIdBitWidth}:${placeholder.imageId}';
      final instanceKey = instanceKeyFor(placeholder, key);
      instanceImageKey[instanceKey] = key;
      instanceCellCount[instanceKey] =
          (instanceCellCount[instanceKey] ?? 0) + 1;
      instanceRecency[instanceKey] = math.max(
        instanceRecency[instanceKey] ?? -1,
        placeholder.sequence,
      );
      final rowBounds = instanceRowBounds[instanceKey] ??= <int>[
        placeholder.row,
        placeholder.row,
      ];
      rowBounds[0] = math.min(rowBounds[0], placeholder.row);
      rowBounds[1] = math.max(rowBounds[1], placeholder.row);
      final colBounds = instanceColBounds[instanceKey] ??= <int>[
        placeholder.col,
        placeholder.col,
      ];
      colBounds[0] = math.min(colBounds[0], placeholder.col);
      colBounds[1] = math.max(colBounds[1], placeholder.col);
    }

    // Filter to instances that are dense enough to be a real display (not a
    // scattered torn remnant).
    final denseInstances = <String>[];
    for (final entry in instanceCellCount.entries) {
      final rowBounds = instanceRowBounds[entry.key];
      final colBounds = instanceColBounds[entry.key];
      if (rowBounds == null || colBounds == null) {
        continue;
      }
      final boxRows = rowBounds[1] - rowBounds[0] + 1;
      final boxCols = colBounds[1] - colBounds[0] + 1;
      final boxArea = boxRows * boxCols;
      if (boxArea <= 0) {
        continue;
      }
      if (entry.value >= boxArea * _kittyPlaceholderRenderThreshold) {
        denseInstances.add(entry.key);
      }
    }
    if (denseInstances.isEmpty) {
      return;
    }

    // Among dense instances of the same image id, keep only the most recently
    // drawn one. When the app re-displays an image (e.g. closing its full-screen
    // viewer and redrawing the conversation) without clearing the previous
    // copy's cells, the older copy lingers as a ghost; its placeholders were
    // written earlier, so it loses to the current placement here.
    final newestInstanceForImage = <String, String>{};
    for (final instanceKey in denseInstances) {
      final imageKey = instanceImageKey[instanceKey]!;
      final current = newestInstanceForImage[imageKey];
      if (current == null ||
          instanceRecency[instanceKey]! > instanceRecency[current]!) {
        newestInstanceForImage[imageKey] = instanceKey;
      }
    }
    final renderableInstances = newestInstanceForImage.values.toSet();
    if (renderableInstances.isEmpty) {
      return;
    }

    // Pass 2: collect the visible cells that belong to a renderable instance.
    // Keep at most one live cell per on-screen position. The visible-range check
    // runs first so off-screen placeholders cost nothing but an integer compare.
    final cellByPosition = <int, _KittyPlaceholderCell>{};
    for (final placeholder in placeholders) {
      if (!placeholder.attached) {
        continue;
      }
      final cellRow = placeholder.cellRow;
      if (cellRow < firstLine || cellRow > lastLine) {
        continue;
      }
      final key = '${placeholder.imageIdBitWidth}:${placeholder.imageId}';
      if (!renderableInstances.contains(instanceKeyFor(placeholder, key))) {
        continue;
      }
      final cellCol = placeholder.cellCol;
      if (!cellIsLivePlaceholder(cellRow, cellCol)) {
        continue;
      }
      cellByPosition[cellRow * _kittyGridStride +
          cellCol] = _KittyPlaceholderCell(
        imageKey: key,
        imageId: placeholder.imageId,
        bitWidth: placeholder.imageIdBitWidth,
        cellRow: cellRow,
        cellCol: cellCol,
        imgRow: placeholder.row,
        imgCol: placeholder.col,
      );
    }
    final visible = cellByPosition.values.toList();
    if (visible.isEmpty) {
      return;
    }

    // Sort so contiguous cells in the same screen row can be merged into a
    // single draw, then composite the matching slice of each source image.
    visible.sort((a, b) {
      final byImage = a.imageKey.compareTo(b.imageKey);
      if (byImage != 0) return byImage;
      if (a.cellRow != b.cellRow) return a.cellRow - b.cellRow;
      return a.cellCol - b.cellCol;
    });

    final imageCache = <String, TerminalImage?>{};

    var i = 0;
    while (i < visible.length) {
      final start = visible[i];
      var end = i;
      while (end + 1 < visible.length) {
        final cur = visible[end];
        final next = visible[end + 1];
        if (next.imageKey == cur.imageKey &&
            next.cellRow == cur.cellRow &&
            next.cellCol == cur.cellCol + 1 &&
            next.imgRow == cur.imgRow &&
            next.imgCol == cur.imgCol + 1) {
          end++;
        } else {
          break;
        }
      }
      final last = visible[end];
      i = end + 1;

      final stored = imageCache.putIfAbsent(
        start.imageKey,
        () => graphics.imageByPlaceholderColorId(
          start.imageId,
          bitWidth: start.bitWidth,
        ),
      );
      if (stored == null) {
        _kittyUnresolvedInstances++;
        if (_kittyFirstUnresolvedImageId == 0) {
          _kittyFirstUnresolvedImageId = start.imageId;
          _kittyFirstUnresolvedBitWidth = start.bitWidth;
        }
        continue;
      }
      _kittyResolvedInstances++;
      _visibleGraphicsImageIds.add(stored.id);
      final imageIntKey = start.imageId * 64 + start.bitWidth;
      final cols = gridColsByImage[imageIntKey] ?? 1;
      final rows = gridRowsByImage[imageIntKey] ?? 1;
      if (cols <= 0 || rows <= 0) {
        continue;
      }

      final image = stored.image;
      final srcCellWidth = image.width / cols;
      final srcCellHeight = image.height / rows;
      final srcRect = Rect.fromLTWH(
        start.imgCol * srcCellWidth,
        start.imgRow * srcCellHeight,
        (last.imgCol - start.imgCol + 1) * srcCellWidth,
        srcCellHeight,
      );

      final topLeft = _linePaintOffset(
        offset,
        start.cellRow,
      ).translate(start.cellCol * cellWidth, 0);
      final dstWidth = (last.cellCol - start.cellCol + 1) * cellWidth;
      if (!topLeft.dx.isFinite ||
          !topLeft.dy.isFinite ||
          !dstWidth.isFinite ||
          dstWidth <= 0 ||
          srcRect.width <= 0 ||
          srcRect.height <= 0) {
        continue;
      }
      try {
        canvas.drawImageRect(
          image,
          srcRect,
          Rect.fromLTWH(topLeft.dx, topLeft.dy, dstWidth, cellHeight),
          _imagePaint,
        );
      } on Object catch (_) {
        // Placeholder graphics are optional terminal adornment; never let a
        // failed image draw tear down the interactive session.
      }
    }
  }

  void _paintCursor(Canvas canvas, Offset offset) {
    final cellData = _cursorCellDataAtCursor();
    if (cellData == null) {
      _painter.paintCursor(
        canvas,
        offset,
        cursorType: _cursorType,
        hasFocus: _focusNode.hasFocus,
      );
      return;
    }

    _painter.paintReadableCursor(
      canvas,
      offset,
      cellData,
      cursorType: _cursorType,
      hasFocus: _focusNode.hasFocus,
    );
  }

  CellData? _cursorCellDataAtCursor() {
    final cursorY = _terminal.buffer.absoluteCursorY;
    if (cursorY < 0 || cursorY >= _terminal.buffer.lines.length) {
      return null;
    }

    final line = _terminal.buffer.lines[cursorY];
    final cursorX = _terminal.buffer.cursorX;
    if (cursorX < 0 || cursorX >= line.length) {
      return null;
    }

    line.getCellData(cursorX, _cursorCellData);
    return _cursorCellData;
  }

  void _paintInlineUnderlines(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
  ) {
    if (_inlineUnderlines.isEmpty) {
      return;
    }

    final lines = _terminal.buffer.lines;
    for (var i = firstLine; i <= lastLine; i++) {
      final lineUnderlines = _inlineUnderlinesForRow(i);
      if (lineUnderlines.isEmpty) {
        continue;
      }

      _painter.paintLineInlineUnderlines(
        canvas,
        _linePaintOffset(offset, i),
        lines[i],
        lineUnderlines,
      );
    }
  }

  List<TerminalTextUnderline> _inlineUnderlinesForRow(int row) {
    if (_inlineUnderlines.isEmpty) {
      return const <TerminalTextUnderline>[];
    }

    final columnCount = _terminal.viewWidth;
    if (columnCount <= 0) {
      return const <TerminalTextUnderline>[];
    }

    final lineUnderlines = <TerminalTextUnderline>[];
    for (final underline in _inlineUnderlines) {
      if (underline.row != row) {
        continue;
      }

      final startColumn = underline.startColumn.clamp(0, columnCount - 1);
      final endColumn = underline.endColumn.clamp(0, columnCount - 1);
      if (startColumn <= endColumn) {
        lineUnderlines.add((
          row: row,
          startColumn: startColumn,
          endColumn: endColumn,
        ));
      }
    }
    return lineUnderlines;
  }

  BufferRange? get _selectionRangeForPaint {
    final start = _selectionStartOffset;
    final end = _selectionEndOffset;
    if (registrar != null && start != null && end != null && start != end) {
      return _bufferRangeForTextOffsets(start, end);
    }
    return _controller.selection;
  }

  void _paintSelectionHandleLayers(PaintingContext context, Offset offset) {
    if (_startHandleLayerLink != null && value.startSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _startHandleLayerLink!,
          offset: offset + value.startSelectionPoint!.localPosition,
        ),
        (context, offset) {},
        Offset.zero,
      );
    }
    if (_endHandleLayerLink != null && value.endSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _endHandleLayerLink!,
          offset: offset + value.endSelectionPoint!.localPosition,
        ),
        (context, offset) {},
        Offset.zero,
      );
    }
  }

  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(style.getTextStyle(textScaler: _painter.textScaler));
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
    paragraph.dispose();
  }

  void _paintSelection(
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (final highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (final segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;
    final startOffset = Offset(
      _contentOrigin.dx + (start * _painter.cellSize.width),
      (segment.line * _painter.cellSize.height) + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}
