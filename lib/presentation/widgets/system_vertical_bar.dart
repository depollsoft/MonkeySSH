import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;

import '../../domain/models/terminal_theme.dart' show contrastRatio;
import '../controllers/platform_display_features_controller.dart';
import 'terminal_menu_style.dart';

export '../controllers/platform_display_features_controller.dart'
    show SystemVerticalBar, SystemVerticalBarEdge;

/// Provides the system vertical bar, if the display shows one, to a subtree.
///
/// iOS 27.1 runs a vertical bar down one edge of iPhone Duo's displays. It
/// holds the status bar, and native apps put their navigation and tab bar
/// items in it instead of in bars across the top and bottom. Screens read the
/// bar here to do the same, which gives their content the full height.
class SystemVerticalBarScope extends InheritedWidget {
  /// Provides [bar] to [child].
  const SystemVerticalBarScope({
    required this.bar,
    required super.child,
    super.key,
  });

  /// The vertical bar, or null when the display shows none.
  final SystemVerticalBar? bar;

  /// The vertical bar for [context], or null when the display shows none.
  static SystemVerticalBar? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SystemVerticalBarScope>()?.bar;

  @override
  bool updateShouldNotify(SystemVerticalBarScope oldWidget) =>
      oldWidget.bar != bar;
}

/// The size of one control in the vertical bar, matching the column UIKit
/// lays out for a native bar item.
const double verticalBarItemExtent = 44;

/// The space between controls in the vertical bar.
const double verticalBarItemGap = 8;

/// Space kept between the vertical bar's controls and the keyboard.
const double verticalBarKeyboardGap = 8;

/// The width the rail takes in the vertical bar, which leaves room for tab
/// labels under their icons.
const double verticalBarRailWidth = 72;

/// The contrast small text needs against what is behind it (WCAG AA).
const double _textContrast = 4.5;

/// The contrast an icon needs against what is behind it (WCAG AA).
const double _iconContrast = 3;

/// [color], moved toward black or white, whichever stands further from
/// [background], only as far as it takes to reach [minimumContrast], so its
/// hue stays recognizable.
///
/// Theme foregrounds are tuned for the page; the bar's controls sit on the
/// raised surface, where some terminal themes leave them too faint.
Color _legible(Color color, Color background, double minimumContrast) {
  if (contrastRatio(color, background) >= minimumContrast) return color;
  final ink =
      contrastRatio(Colors.white, background) >=
          contrastRatio(Colors.black, background)
      ? Colors.white
      : Colors.black;
  for (var step = 1; step < 20; step += 1) {
    final candidate = Color.lerp(color, ink, step / 20)!;
    if (contrastRatio(candidate, background) >= minimumContrast) {
      return candidate;
    }
  }
  return ink;
}

/// The part of the vertical bar's item column left for controls in a window
/// described by [mediaQuery].
///
/// With [avoidsKeyboard], the column ends above the system keyboard, which
/// covers the bottom of the bar on iPhone Duo's outer display.
Rect resolveVerticalBarColumn(
  SystemVerticalBar bar,
  MediaQueryData mediaQuery, {
  bool avoidsKeyboard = true,
}) {
  final column = bar.itemColumn;
  if (!avoidsKeyboard || mediaQuery.viewInsets.bottom <= 0) return column;
  final keyboardTop =
      mediaQuery.size.height -
      mediaQuery.viewInsets.bottom -
      verticalBarKeyboardGap;
  return Rect.fromLTRB(
    column.left,
    column.top,
    column.right,
    math.max(column.top, math.min(column.bottom, keyboardTop)),
  );
}

/// How many [verticalBarItemExtent] controls fit in [column].
int verticalBarItemCapacity(Rect column) => math.max(
  0,
  ((column.height + verticalBarItemGap) /
          (verticalBarItemExtent + verticalBarItemGap))
      .floor(),
);

/// Lays out controls in the vertical bar, the way native iOS 27.1 apps do.
///
/// [leading] controls (Back, or a screen's identity) start just below the
/// status cluster. [trailing] controls stack up from the bottom, nearest the
/// thumb, and list from top to bottom. When the column is too short for all
/// of them, as when the keyboard is up, the trailing controls listed first
/// are left out; screens that need every action reachable should check
/// [verticalBarItemCapacity] and move the rest into a menu.
///
/// Place it in a [Stack] that fills the window, such as the one
/// [VerticalBarRailPortal] provides.
class VerticalBarRail extends StatefulWidget {
  /// Creates a rail in [bar].
  const VerticalBarRail({
    required this.bar,
    this.leading = const <Widget>[],
    this.trailing = const <Widget>[],
    this.avoidsKeyboard = true,
    super.key,
  });

  /// The vertical bar the rail sits in.
  final SystemVerticalBar bar;

  /// Controls at the top of the bar, below the status cluster.
  final List<Widget> leading;

  /// Controls at the bottom of the bar, listed from top to bottom.
  final List<Widget> trailing;

  /// Whether the controls move above the system keyboard. Off for tab bars,
  /// which the keyboard covers, as on any iPhone.
  final bool avoidsKeyboard;

  @override
  State<VerticalBarRail> createState() => _VerticalBarRailState();
}

class _VerticalBarRailState extends State<VerticalBarRail> {
  // The controls the last layout had no room for. They stay mounted and keep
  // their state, but leave focus traversal and the semantics tree, so Tab
  // and VoiceOver cannot reach a control that is out of sight.
  Set<Object> _hidden = const {};

  void _handleHiddenChanged(Set<Object> hidden) {
    if (setEquals(hidden, _hidden)) return;
    // Layout reports this mid-frame; apply it once the frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !setEquals(hidden, _hidden)) {
        setState(() => _hidden = hidden);
      }
    });
  }

  Widget _control(Object id, Widget control) {
    final hidden = _hidden.contains(id);
    return LayoutId(
      id: id,
      child: ExcludeFocus(
        excluding: hidden,
        child: ExcludeSemantics(
          excluding: hidden,
          child: control is ButtonStyleButton
              ? _VerticalBarTextKey(child: control)
              : control,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final column = resolveVerticalBarColumn(
      bar,
      MediaQuery.of(context),
      avoidsKeyboard: widget.avoidsKeyboard,
    );
    return Positioned(
      left: column.center.dx - verticalBarRailWidth / 2,
      width: verticalBarRailWidth,
      top: column.top,
      height: column.height,
      // The rail paints in the overlay, apart from the screen's Material, so
      // its ink needs a Material of its own.
      child: Material(
        type: MaterialType.transparency,
        child: VerticalBarButtonTheme(
          child: ClipRect(
            child: CustomMultiChildLayout(
              delegate: _VerticalBarRailLayout(
                leadingCount: widget.leading.length,
                trailingCount: widget.trailing.length,
                onHiddenChanged: _handleHiddenChanged,
              ),
              children: [
                for (final (index, control) in widget.leading.indexed)
                  _control(('leading', index), control),
                for (final (index, control) in widget.trailing.indexed)
                  _control(('trailing', index), control),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalBarRailLayout extends MultiChildLayoutDelegate {
  _VerticalBarRailLayout({
    required this.leadingCount,
    required this.trailingCount,
    required this.onHiddenChanged,
  });

  final int leadingCount;
  final int trailingCount;

  /// Receives the ids of the controls laid out of sight.
  final ValueChanged<Set<Object>> onHiddenChanged;

  // Controls that do not fit are laid out out of sight; the rail clips them
  // and their hit area falls outside its bounds.
  static const _hidden = Offset(0, -100000);

  @override
  void performLayout(Size size) {
    final constraints = BoxConstraints.loose(size);
    final hidden = <Object>{};
    double centered(Size child) => (size.width - child.width) / 2;
    var top = 0.0;
    for (var index = 0; index < leadingCount; index += 1) {
      final id = ('leading', index);
      final child = layoutChild(id, constraints);
      if (top + child.height > size.height) {
        positionChild(id, _hidden);
        hidden.add(id);
        continue;
      }
      positionChild(id, Offset(centered(child), top));
      top += child.height + verticalBarItemGap;
    }
    var bottom = size.height;
    var full = false;
    for (var index = trailingCount - 1; index >= 0; index -= 1) {
      final id = ('trailing', index);
      final child = layoutChild(id, constraints);
      if (full || bottom - child.height < top) {
        full = true;
        positionChild(id, _hidden);
        hidden.add(id);
        continue;
      }
      bottom -= child.height;
      positionChild(id, Offset(centered(child), bottom));
      bottom -= verticalBarItemGap;
    }
    onHiddenChanged(hidden);
  }

  @override
  bool shouldRelayout(_VerticalBarRailLayout oldDelegate) =>
      oldDelegate.leadingCount != leadingCount ||
      oldDelegate.trailingCount != trailingCount;
}

/// Styles [IconButton]s in [child] as vertical bar keys: 44 pt circles on the
/// raised surface with a hairline border, like the bar items native apps put
/// beside the status bar.
class VerticalBarButtonTheme extends StatelessWidget {
  /// Applies the vertical bar key style to [child].
  const VerticalBarButtonTheme({required this.child, super.key});

  /// The subtree whose icon buttons become vertical bar keys.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          fixedSize: const Size.square(verticalBarItemExtent),
          minimumSize: const Size.square(verticalBarItemExtent),
          maximumSize: const Size.square(verticalBarItemExtent),
          padding: EdgeInsets.zero,
          iconSize: 22,
          // 44 pt is the touch target iOS asks for, and the column UIKit
          // lays out for a bar item.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: colorScheme.surfaceContainerHighest,
          foregroundColor: colorScheme.onSurface,
          disabledBackgroundColor: colorScheme.surfaceContainerHighest
              .withAlpha(120),
          disabledForegroundColor: colorScheme.onSurface.withAlpha(90),
          shape: CircleBorder(side: BorderSide(color: colorScheme.outline)),
        ),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: colorScheme.onSurface, size: 22),
        child: child,
      ),
    );
  }
}

/// Gives a text, filled, outlined or elevated button in the vertical bar the
/// shape of the keys beside it: 44 pt tall, a stadium on the raised surface
/// with a hairline border, as wide as its label up to the rail's width. A
/// longer label shrinks to fit.
///
/// It themes one control, not the whole rail, because a menu that a rail
/// control opens builds its rows from text buttons too.
class _VerticalBarTextKey extends StatelessWidget {
  const _VerticalBarTextKey({required this.child});

  final ButtonStyleButton child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fill = colorScheme.surfaceContainerHighest;
    final style = TextButton.styleFrom(
      minimumSize: const Size.square(verticalBarItemExtent),
      maximumSize: const Size(verticalBarRailWidth, verticalBarItemExtent),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      elevation: 0,
      backgroundColor: fill,
      foregroundColor: _legible(colorScheme.onSurface, fill, _textContrast),
      disabledBackgroundColor: fill.withAlpha(120),
      disabledForegroundColor: colorScheme.onSurface.withAlpha(90),
      textStyle: theme.textTheme.labelLarge,
      shape: StadiumBorder(side: BorderSide(color: colorScheme.outline)),
      foregroundBuilder: (context, states, label) =>
          FittedBox(fit: BoxFit.scaleDown, child: label),
    );
    return TextButtonTheme(
      data: TextButtonThemeData(style: style),
      child: FilledButtonTheme(
        data: FilledButtonThemeData(style: style),
        child: OutlinedButtonTheme(
          data: OutlinedButtonThemeData(style: style),
          child: ElevatedButtonTheme(
            data: ElevatedButtonThemeData(style: style),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One destination in a [VerticalBarTabs] capsule.
@immutable
class VerticalBarTab {
  /// Creates a destination.
  const VerticalBarTab({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// The icon while the destination is not selected.
  final IconData icon;

  /// The icon while the destination is selected.
  final IconData selectedIcon;

  /// The destination's short name.
  final String label;
}

/// A tab bar standing in the vertical bar: one capsule holding each
/// destination's icon above its label.
///
/// It follows [NavigationBarTheme], so the selected destination gets the same
/// signal-teal indicator as the bottom navigation bar it replaces. Its
/// foregrounds are resolved against the capsule and the indicator, which sit
/// behind them here instead of the bottom bar's surface.
class VerticalBarTabs extends StatelessWidget {
  /// Creates a capsule of [tabs].
  const VerticalBarTabs({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  /// The destinations, from top to bottom.
  final List<VerticalBarTab> tabs;

  /// The selected destination.
  final int selectedIndex;

  /// Called with the index of the destination the user picks.
  final ValueChanged<int> onSelected;

  /// The height of one destination.
  static const double tabExtent = 58;

  /// The capsule's padding above and below its destinations.
  static const double padding = 8;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final navigationTheme = NavigationBarTheme.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.tabBar,
      child: Container(
        width: verticalBarRailWidth,
        padding: const EdgeInsets.symmetric(vertical: padding, horizontal: 2),
        decoration: ShapeDecoration(
          color: colorScheme.surfaceContainerHighest,
          shape: StadiumBorder(side: BorderSide(color: colorScheme.outline)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, tab) in tabs.indexed)
                _VerticalBarTabButton(
                  tab: tab,
                  index: index,
                  count: tabs.length,
                  selected: index == selectedIndex,
                  navigationTheme: navigationTheme,
                  onPressed: () => onSelected(index),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerticalBarTabButton extends StatelessWidget {
  const _VerticalBarTabButton({
    required this.tab,
    required this.index,
    required this.count,
    required this.selected,
    required this.navigationTheme,
    required this.onPressed,
  });

  final VerticalBarTab tab;
  final int index;
  final int count;
  final bool selected;
  final NavigationBarThemeData navigationTheme;
  final VoidCallback onPressed;

  // The label starts at iOS's smallest text size and follows the user's
  // text size up to 13 pt. Larger, the last label meets the capsule's
  // rounded end and the labels crowd the next destination; the long-press
  // label shows the name at full size instead.
  static const double _labelSize = 11;
  static const double _labelMaxSize = 13;
  static const double _labelLineHeight = 1.1;
  static const double _labelGap = 3;
  static const double _indicatorHeight = 28;

  // The label's width: the capsule's inside, less a point either side. A
  // label too long for it, such as "Connections", shrinks to fit.
  static const double _labelWidth = verticalBarRailWidth - 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fill = colorScheme.surfaceContainerHighest;
    final states = <WidgetState>{if (selected) WidgetState.selected};
    final iconTheme = navigationTheme.iconTheme?.resolve(states);
    final labelStyle =
        navigationTheme.labelTextStyle?.resolve(states) ??
        theme.textTheme.labelMedium;
    final indicator =
        navigationTheme.indicatorColor ?? colorScheme.secondaryContainer;
    // The selected label takes the ink and leaves the signal to the
    // indicator and its icon, so the capsule shows one teal mark.
    final labelColor = _legible(
      selected
          ? colorScheme.onSurface
          : labelStyle?.color ?? colorScheme.onSurfaceVariant,
      fill,
      _textContrast,
    );
    final iconColor = selected
        ? _legible(
            iconTheme?.color ?? colorScheme.primary,
            Color.alphaBlend(indicator, fill),
            _iconContrast,
          )
        : labelColor;
    final textScaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: _labelMaxSize / _labelSize);
    final localizations = MaterialLocalizations.of(context);
    return Semantics(
      container: true,
      role: SemanticsRole.tab,
      selected: selected,
      button: true,
      label:
          '${tab.label}\n'
          '${localizations.tabLabel(tabIndex: index + 1, tabCount: count)}',
      onTap: onPressed,
      excludeSemantics: true,
      // Stands in for UIKit's Large Content Viewer: a long press shows the
      // name at the user's full text size, beside the rail.
      child: Tooltip(
        message: tab.label,
        triggerMode: TooltipTriggerMode.longPress,
        excludeFromSemantics: true,
        positionDelegate: _besideRail,
        child: InkWell(
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: SizedBox(
            width: double.infinity,
            height: VerticalBarTabs.tabExtent,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: 44,
                  height: _indicatorHeight,
                  decoration: ShapeDecoration(
                    color: selected ? indicator : Colors.transparent,
                    shape: const StadiumBorder(),
                  ),
                  child: Icon(
                    selected ? tab.selectedIcon : tab.icon,
                    size: iconTheme?.size ?? 22,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: _labelGap),
                // Every label's box is as tall, so the destinations keep
                // one rhythm when a long label shrinks.
                SizedBox(
                  width: _labelWidth,
                  height: textScaler.scale(_labelSize) * _labelLineHeight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      textScaler: textScaler,
                      style: (labelStyle ?? const TextStyle()).copyWith(
                        fontSize: _labelSize,
                        height: _labelLineHeight,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: labelColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Centres the tooltip on the destination, on the side of the rail away
  /// from the screen's edge, where the thumb on the tab does not cover it.
  static Offset _besideRail(TooltipPositionContext context) {
    const gap = 8.0;
    final TooltipPositionContext(:target, :targetSize, :tooltipSize) = context;
    final overlay = context.overlaySize;
    final left = target.dx > overlay.width / 2
        ? target.dx - targetSize.width / 2 - gap - tooltipSize.width
        : target.dx + targetSize.width / 2 + gap;
    return Offset(
      left.clamp(gap, math.max(gap, overlay.width - tooltipSize.width - gap)),
      (target.dy - tooltipSize.height / 2).clamp(
        gap,
        math.max(gap, overlay.height - tooltipSize.height - gap),
      ),
    );
  }
}

/// Shows [rail] above the route's content, in the window's coordinates.
///
/// The rail lives in the navigator's overlay, so it stays still while route
/// transitions slide the page, and fades in and out with its route the way
/// native bar items cross-fade in the vertical bar.
class VerticalBarRailPortal extends StatefulWidget {
  /// Shows [rail] for the route that holds [child].
  const VerticalBarRailPortal({
    required this.rail,
    required this.child,
    super.key,
  });

  /// Builds the rail; it returns a [VerticalBarRail] or another positioned
  /// widget.
  final WidgetBuilder rail;

  /// The route content the rail belongs to.
  final Widget child;

  @override
  State<VerticalBarRailPortal> createState() => _VerticalBarRailPortalState();
}

class _VerticalBarRailPortalState extends State<VerticalBarRailPortal> {
  final _controller = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _controller.show();
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    return OverlayPortal(
      controller: _controller,
      // A stack that fills the window but has no hit area of its own, so
      // touches outside the rail reach the route below.
      overlayChildBuilder: (overlayContext) => Positioned.fill(
        child: _RouteFade(
          route: route,
          child: Stack(children: [widget.rail(overlayContext)]),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Fades a route's rail in over the start of the route's entrance, and out
/// over the start of its exit or of the entrance of a route above it, so the
/// rails of two routes cross-fade within [_duration] while the pages slide.
/// The rail takes taps once it is fully shown.
///
/// With reduced motion, the rail appears and disappears without a fade.
class _RouteFade extends StatefulWidget {
  const _RouteFade({required this.route, required this.child});

  final ModalRoute<Object?>? route;
  final Widget child;

  static const _duration = Duration(milliseconds: 150);

  @override
  State<_RouteFade> createState() => _RouteFadeState();
}

class _RouteFadeState extends State<_RouteFade> {
  // How far this route has come in, and how far a route above it has.
  CurvedAnimation? _entered;
  CurvedAnimation? _covered;
  bool? _reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _updateAnimations();
    }
  }

  @override
  void didUpdateWidget(_RouteFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route != widget.route) _updateAnimations();
  }

  @override
  void dispose() {
    _disposeAnimations();
    super.dispose();
  }

  void _disposeAnimations() {
    _entered?.dispose();
    _covered?.dispose();
    _entered = _covered = null;
  }

  void _updateAnimations() {
    _disposeAnimations();
    final route = widget.route;
    final animation = route?.animation;
    final secondaryAnimation = route?.secondaryAnimation;
    if (route == null || animation == null || secondaryAnimation == null) {
      return;
    }
    // The fade takes the start of each transition, as a share of the
    // route's own durations; a route pushed above it is assumed to take as
    // long.
    double share(Duration duration) => duration <= _RouteFade._duration
        ? 1
        : _RouteFade._duration.inMicroseconds / duration.inMicroseconds;
    final forward = share(route.transitionDuration);
    final reverse = share(route.reverseTransitionDuration);
    final (Curve curve, Curve reverseCurve) = _reduceMotion!
        // Shown as soon as an entrance starts, gone as soon as an exit does.
        ? (const Threshold(0), const Threshold(1))
        : (
            Interval(0, forward, curve: Curves.easeOut),
            Interval(1 - reverse, 1, curve: Curves.easeIn),
          );
    _entered = CurvedAnimation(
      parent: animation,
      curve: curve,
      reverseCurve: reverseCurve,
    );
    _covered = CurvedAnimation(
      parent: secondaryAnimation,
      curve: curve,
      reverseCurve: reverseCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entered = _entered;
    final covered = _covered;
    if (entered == null || covered == null) return widget.child;
    return AnimatedBuilder(
      animation: Listenable.merge([entered, covered]),
      child: widget.child,
      builder: (context, child) {
        final opacity = (entered.value * (1 - covered.value)).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: opacity < 1,
          child: Opacity(opacity: opacity, child: child),
        );
      },
    );
  }
}

/// An [AppBar] that hands its Back button and actions to the vertical bar
/// when the display has one, keeping only its title across the top.
///
/// Without a vertical bar it is [appBar] unchanged, so screens can wrap their
/// bars unconditionally.
class VerticalBarAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Adapts [appBar] to the vertical bar.
  const VerticalBarAppBar(this.appBar, {super.key});

  /// The bar this adapts.
  final AppBar appBar;

  @override
  Size get preferredSize => appBar.preferredSize;

  @override
  Widget build(BuildContext context) {
    final bar = SystemVerticalBarScope.maybeOf(context);
    // With no room in the bar for even one key, as under a Live Activity
    // with a very tall keyboard, the actions stay across the top.
    if (bar == null ||
        verticalBarItemCapacity(
              resolveVerticalBarColumn(bar, MediaQuery.of(context)),
            ) <
            1) {
      return appBar;
    }
    final leading = appBar.leading ?? _impliedLeading(context);
    final actions = appBar.actions ?? const <Widget>[];
    return VerticalBarRailPortal(
      rail: (context) {
        final (leadingKeys, trailingKeys) = _fit(
          context,
          leading,
          actions,
          math.max(
            1,
            verticalBarItemCapacity(
              resolveVerticalBarColumn(bar, MediaQuery.of(context)),
            ),
          ),
        );
        return VerticalBarRail(
          bar: bar,
          leading: leadingKeys,
          trailing: trailingKeys,
        );
      },
      child: _titleOnly(appBar),
    );
  }

  /// Fits [leading] and [actions] into [capacity] keys, the way native bars
  /// compress: the actions farthest from the thumb fold into a menu key in
  /// their place. A popup action always folds once there is a menu key, so
  /// the bar never shows two keys that open menus. With one key left,
  /// [leading] folds into that menu too, since a full-screen dialog or an
  /// unsaved-changes guard can leave no edge swipe to go back with.
  static (List<Widget>, List<Widget>) _fit(
    BuildContext context,
    Widget? leading,
    List<Widget> actions,
    int capacity,
  ) {
    if ((leading == null ? 0 : 1) + actions.length <= capacity) {
      return ([?leading], actions);
    }
    final entries = [
      for (final action in actions) _menuEntryFor(context, action),
    ];
    final kept = [
      for (final (index, action) in actions.indexed)
        if (entries[index] == null) action,
    ];
    final slots = capacity - (leading == null ? 0 : 1);
    if (slots >= 1 + kept.length) {
      // Fold the actions farthest from the thumb until the rest fit beside
      // the menu key, keeping the ones a menu cannot hold.
      final folded = {
        for (final (index, entry) in entries.indexed)
          if (entry?.section ?? false) index,
      };
      var shown = actions.length - folded.length;
      for (var index = 0; index < actions.length; index += 1) {
        if (shown <= slots - 1) break;
        if (entries[index] == null || folded.contains(index)) continue;
        folded.add(index);
        shown -= 1;
      }
      return (
        [?leading],
        [
          _menuKey(context, [
            for (final (index, entry) in entries.indexed)
              if (folded.contains(index)) entry!,
          ]),
          for (final (index, action) in actions.indexed)
            if (!folded.contains(index)) action,
        ],
      );
    }
    final leadingEntry = leading == null
        ? null
        : _menuEntryFor(context, leading);
    return (
      const <Widget>[],
      [
        _menuKey(context, [?leadingEntry, ...entries.nonNulls]),
        ...kept,
      ],
    );
  }

  /// Calls [popup]'s `onSelected` with [value]. The callback takes the
  /// popup's own item type, which a typed read through
  /// `PopupMenuButton<Object?>` would reject at run time, so it is read
  /// dynamically and called with the item's value of that type.
  static void _selectPopupValue(PopupMenuButton<Object?> popup, Object? value) {
    // ignore: avoid_dynamic_calls
    final Object? onSelected = (popup as dynamic).onSelected;
    if (onSelected is Function) Function.apply(onSelected, [value]);
  }

  /// The menu key holding [entries], styled like the app's other menus: the
  /// raised surface, a hairline, and 44 pt rows. A popup's items stand
  /// between dividers.
  static Widget _menuKey(BuildContext context, List<_MenuEntry> entries) =>
      MenuAnchor(
        style: TerminalMenuStyles.menuStyle(context).copyWith(
          side: WidgetStatePropertyAll(
            BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        menuChildren: [
          for (final (index, entry) in entries.indexed) ...[
            if (index > 0 && (entry.section || entries[index - 1].section))
              const Divider(height: 1),
            ...entry.rows,
          ],
        ],
        builder: (context, controller, _) => IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      );

  /// The menu rows that do what [action] does, for the kinds of action a
  /// menu can stand in for.
  static _MenuEntry? _menuEntryFor(BuildContext context, Widget action) {
    final localizations = MaterialLocalizations.of(context);
    final style = TerminalMenuStyles.itemButtonStyle(context);
    _MenuEntry row({
      required VoidCallback? onPressed,
      required Widget? child,
      Widget? leadingIcon,
    }) => (
      rows: [
        MenuItemButton(
          style: style,
          onPressed: onPressed,
          leadingIcon: leadingIcon,
          child: child,
        ),
      ],
      section: false,
    );
    return switch (action) {
      // Back and Close pop through the route's guards, as their keys do.
      BackButton(:final onPressed) => row(
        onPressed: onPressed ?? () => Navigator.maybePop(context),
        leadingIcon: const BackButtonIcon(),
        child: Text(localizations.backButtonTooltip),
      ),
      CloseButton(:final onPressed) => row(
        onPressed: onPressed ?? () => Navigator.maybePop(context),
        leadingIcon: const Icon(Icons.close),
        child: Text(localizations.closeButtonTooltip),
      ),
      IconButton(:final onPressed, :final icon, :final tooltip) => row(
        onPressed: onPressed,
        leadingIcon: icon,
        child: Text(tooltip ?? ''),
      ),
      ButtonStyleButton(:final onPressed, :final child) => row(
        onPressed: onPressed,
        child: child,
      ),
      PopupMenuButton<Object?>() => _popupEntry(context, action, style),
      _ => null,
    };
  }

  /// [popup]'s items as rows of the menu, in place of a submenu or a second
  /// menu key. A list tile item gives its row its icon and title, so the
  /// row is as tall as the others.
  static _MenuEntry _popupEntry(
    BuildContext context,
    PopupMenuButton<Object?> popup,
    ButtonStyle style,
  ) {
    final rows = <Widget>[
      for (final item in popup.itemBuilder(context))
        if (item is PopupMenuItem<Object?>)
          switch (item.child) {
            final ListTile tile => MenuItemButton(
              style: style,
              onPressed: popup.enabled && item.enabled && tile.enabled
                  ? () => _selectPopupItem(popup, item)
                  : null,
              leadingIcon: tile.leading,
              trailingIcon: tile.trailing,
              child: tile.title,
            ),
            final child => MenuItemButton(
              style: style,
              onPressed: popup.enabled && item.enabled
                  ? () => _selectPopupItem(popup, item)
                  : null,
              child: child,
            ),
          }
        else if (item is PopupMenuDivider)
          const Divider(height: 1),
    ];
    return (rows: rows, section: rows.isNotEmpty);
  }

  static void _selectPopupItem(
    PopupMenuButton<Object?> popup,
    PopupMenuItem<Object?> item,
  ) {
    item.onTap?.call();
    _selectPopupValue(popup, item.value);
  }

  Widget? _impliedLeading(BuildContext context) {
    if (!appBar.automaticallyImplyLeading) return null;
    final route = ModalRoute.of(context);
    if (route == null || !route.impliesAppBarDismissal) return null;
    return route is PageRoute && route.fullscreenDialog
        ? const CloseButton()
        : const BackButton();
  }
}

AppBar _titleOnly(AppBar appBar) => AppBar(
  key: appBar.key,
  automaticallyImplyLeading: false,
  title: appBar.title,
  flexibleSpace: appBar.flexibleSpace,
  bottom: appBar.bottom,
  elevation: appBar.elevation,
  scrolledUnderElevation: appBar.scrolledUnderElevation,
  notificationPredicate: appBar.notificationPredicate,
  shadowColor: appBar.shadowColor,
  surfaceTintColor: appBar.surfaceTintColor,
  shape: appBar.shape,
  backgroundColor: appBar.backgroundColor,
  foregroundColor: appBar.foregroundColor,
  iconTheme: appBar.iconTheme,
  primary: appBar.primary,
  centerTitle: appBar.centerTitle,
  excludeHeaderSemantics: appBar.excludeHeaderSemantics,
  titleSpacing: appBar.titleSpacing,
  toolbarOpacity: appBar.toolbarOpacity,
  bottomOpacity: appBar.bottomOpacity,
  toolbarHeight: appBar.toolbarHeight,
  toolbarTextStyle: appBar.toolbarTextStyle,
  titleTextStyle: appBar.titleTextStyle,
  systemOverlayStyle: appBar.systemOverlayStyle,
  forceMaterialTransparency: appBar.forceMaterialTransparency,
  clipBehavior: appBar.clipBehavior,
);

/// The menu rows standing in for one action folded into a vertical bar menu
/// key; a popup's items form a [section], set apart from the rows around
/// them by dividers.
typedef _MenuEntry = ({List<Widget> rows, bool section});
