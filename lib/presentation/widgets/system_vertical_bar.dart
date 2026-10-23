import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/platform_display_features_controller.dart';

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
class VerticalBarRail extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final column = resolveVerticalBarColumn(
      bar,
      MediaQuery.of(context),
      avoidsKeyboard: avoidsKeyboard,
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
                leadingCount: leading.length,
                trailingCount: trailing.length,
              ),
              children: [
                for (final (index, control) in leading.indexed)
                  LayoutId(id: ('leading', index), child: control),
                for (final (index, control) in trailing.indexed)
                  LayoutId(id: ('trailing', index), child: control),
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
  });

  final int leadingCount;
  final int trailingCount;

  // Controls that do not fit are laid out out of sight; the rail clips them
  // and their hit area falls outside its bounds.
  static const _hidden = Offset(0, -100000);

  @override
  void performLayout(Size size) {
    final constraints = BoxConstraints.loose(size);
    double centered(Size child) => (size.width - child.width) / 2;
    var top = 0.0;
    for (var index = 0; index < leadingCount; index += 1) {
      final id = ('leading', index);
      final child = layoutChild(id, constraints);
      if (top + child.height > size.height) {
        positionChild(id, _hidden);
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
        continue;
      }
      bottom -= child.height;
      positionChild(id, Offset(centered(child), bottom));
      bottom -= verticalBarItemGap;
    }
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
/// signal-teal indicator and label as the bottom navigation bar it replaces.
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
  static const double padding = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final navigationTheme = NavigationBarTheme.of(context);
    return Container(
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
                selected: index == selectedIndex,
                navigationTheme: navigationTheme,
                onPressed: () => onSelected(index),
              ),
          ],
        ),
      ),
    );
  }
}

class _VerticalBarTabButton extends StatelessWidget {
  const _VerticalBarTabButton({
    required this.tab,
    required this.selected,
    required this.navigationTheme,
    required this.onPressed,
  });

  final VerticalBarTab tab;
  final bool selected;
  final NavigationBarThemeData navigationTheme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{if (selected) WidgetState.selected};
    final iconTheme = navigationTheme.iconTheme?.resolve(states);
    final labelStyle = navigationTheme.labelTextStyle?.resolve(states);
    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: SizedBox(
          height: VerticalBarTabs.tabExtent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                width: 44,
                height: 28,
                decoration: ShapeDecoration(
                  color: selected
                      ? navigationTheme.indicatorColor
                      : Colors.transparent,
                  shape: const StadiumBorder(),
                ),
                child: Icon(
                  selected ? tab.selectedIcon : tab.icon,
                  size: iconTheme?.size ?? 22,
                  color: iconTheme?.color,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                textScaler: MediaQuery.textScalerOf(context)
                    .clamp(maxScaleFactor: 1.15),
                style: labelStyle?.copyWith(fontSize: 10, height: 1.1),
              ),
            ],
          ),
        ),
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

class _RouteFade extends StatelessWidget {
  const _RouteFade({required this.route, required this.child});

  final ModalRoute<Object?>? route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = route?.animation;
    final secondaryAnimation = route?.secondaryAnimation;
    if (animation == null || secondaryAnimation == null) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondaryAnimation]),
      child: child,
      builder: (context, child) {
        final opacity = (animation.value * (1 - secondaryAnimation.value))
            .clamp(0.0, 1.0);
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
    if (bar == null) return appBar;
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
  /// their place. With one key left, [leading] folds into that menu too,
  /// since a full-screen dialog or an unsaved-changes guard can leave no
  /// edge swipe to go back with.
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
      final folded = <int>{};
      var shown = actions.length;
      for (var index = 0; index < actions.length; index += 1) {
        if (shown <= slots - 1) break;
        if (entries[index] == null) continue;
        folded.add(index);
        shown -= 1;
      }
      return (
        [?leading],
        [
          _menuKey([for (final index in folded) entries[index]!]),
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
        _menuKey([?leadingEntry, ...entries.nonNulls]),
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

  static Widget _menuKey(List<Widget> entries) => MenuAnchor(
    menuChildren: entries,
    builder: (context, controller, _) => IconButton(
      icon: const Icon(Icons.more_vert),
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
  );

  /// A menu entry that does what [action] does, for the kinds of action a
  /// menu can stand in for.
  static Widget? _menuEntryFor(BuildContext context, Widget action) {
    final localizations = MaterialLocalizations.of(context);
    return switch (action) {
      // Back and Close pop through the route's guards, as their keys do.
      BackButton(:final onPressed) => MenuItemButton(
        onPressed: onPressed ?? () => Navigator.maybePop(context),
        leadingIcon: const BackButtonIcon(),
        child: Text(localizations.backButtonTooltip),
      ),
      CloseButton(:final onPressed) => MenuItemButton(
        onPressed: onPressed ?? () => Navigator.maybePop(context),
        leadingIcon: const Icon(Icons.close),
        child: Text(localizations.closeButtonTooltip),
      ),
      IconButton(:final onPressed, :final icon, :final tooltip) =>
        MenuItemButton(
          onPressed: onPressed,
          leadingIcon: icon,
          child: Text(tooltip ?? ''),
        ),
      ButtonStyleButton(:final onPressed, :final child) => MenuItemButton(
        onPressed: onPressed,
        child: child,
      ),
      PopupMenuButton<Object?>() => SubmenuButton(
        leadingIcon: action.icon ?? const Icon(Icons.more_horiz),
        menuChildren: [
          for (final item in action.itemBuilder(context))
            if (item is PopupMenuItem<Object?>)
              MenuItemButton(
                onPressed: item.enabled
                    ? () {
                        item.onTap?.call();
                        _selectPopupValue(action, item.value);
                      }
                    : null,
                child: item.child,
              )
            else if (item is PopupMenuDivider)
              const Divider(height: 1),
        ],
        child: Text(action.tooltip ?? localizations.showMenuTooltip),
      ),
      _ => null,
    };
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
