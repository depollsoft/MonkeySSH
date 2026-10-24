import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';

import '../controllers/platform_display_features_controller.dart';
import 'system_vertical_bar.dart';

/// A fold or hinge that currently splits the window into two pages.
///
/// iPhone Duo reports its fold only while the device is partly folded. Held
/// like a book, the fold runs top to bottom and the pages sit side by side.
/// Turned and propped up like a laptop, the fold runs across the window, with
/// a top page to read at a distance and a bottom page to touch.
@immutable
class DisplayFold {
  /// Creates a fold covering [bounds], in window coordinates.
  const DisplayFold({required this.bounds, required this.axis});

  /// The area the fold covers. It may be zero pixels thick.
  final Rect bounds;

  /// [Axis.vertical] when the fold runs top to bottom (pages side by side),
  /// [Axis.horizontal] when it runs left to right (pages stacked).
  final Axis axis;

  /// Whether the pages sit side by side.
  bool get isVertical => axis == Axis.vertical;

  /// Where the leading page (left or top) ends, measured from the window
  /// origin along the split direction.
  double get leadingPageExtent => isVertical ? bounds.left : bounds.top;

  /// Where the trailing page (right or bottom) starts, measured from the
  /// window origin along the split direction.
  double get trailingPageStart => isVertical ? bounds.right : bounds.bottom;

  /// The fold's thickness along the split direction.
  double get thickness => isVertical ? bounds.width : bounds.height;

  /// The left or top page of a [window]-sized view.
  Rect leadingPage(Size window) => isVertical
      ? Rect.fromLTRB(0, 0, bounds.left, window.height)
      : Rect.fromLTRB(0, 0, window.width, bounds.top);

  /// The right or bottom page of a [window]-sized view.
  Rect trailingPage(Size window) => isVertical
      ? Rect.fromLTRB(bounds.right, 0, window.width, window.height)
      : Rect.fromLTRB(0, bounds.bottom, window.width, window.height);

  @override
  bool operator ==(Object other) =>
      other is DisplayFold && other.bounds == bounds && other.axis == axis;

  @override
  int get hashCode => Object.hash(bounds, axis);

  @override
  String toString() => 'DisplayFold($axis, $bounds)';
}

/// Space, in logical pixels, kept between text and a fold, where the crease
/// bends the display.
const double displayFoldContentGutter = 8;

/// The smallest page, in logical pixels, a fold-aware layout splits into.
///
/// Below this the window is too small to be useful as two pages, so layouts
/// keep their single-page form.
const double displayFoldMinPageExtent = 280;

/// Returns the fold that splits this window into two usable pages, if any.
///
/// A hinge always separates content. A fold separates only while the device
/// is half opened; a flat fold is just a crease. The feature must also cross
/// the whole window and leave at least [displayFoldMinPageExtent] on each
/// side, so a fold that only clips a corner of a split-view window is ignored.
DisplayFold? resolveDisplayFold(MediaQueryData mediaQuery) {
  final size = mediaQuery.size;
  for (final feature in mediaQuery.displayFeatures) {
    if (!_separatesContent(feature)) continue;
    final bounds = feature.bounds;
    final spansHeight = bounds.top <= 0 && bounds.bottom >= size.height;
    final spansWidth = bounds.left <= 0 && bounds.right >= size.width;
    if (spansHeight &&
        bounds.width < bounds.height &&
        bounds.left >= displayFoldMinPageExtent &&
        size.width - bounds.right >= displayFoldMinPageExtent) {
      return DisplayFold(bounds: bounds, axis: Axis.vertical);
    }
    if (spansWidth &&
        bounds.height < bounds.width &&
        bounds.top >= displayFoldMinPageExtent &&
        size.height - bounds.bottom >= displayFoldMinPageExtent) {
      return DisplayFold(bounds: bounds, axis: Axis.horizontal);
    }
  }
  return null;
}

/// Media query data for content laid out on one [page] of a window.
///
/// The page gets its own size and keeps only the system insets along the
/// window edges it touches, so a page beside the status bar strip clears it
/// while the page across the fold does not. The fold is dropped, so content
/// inside a page lays out as a single screen.
MediaQueryData displayFoldPageMediaQuery(MediaQueryData window, Rect page) =>
    window.removeDisplayFeatures(page).copyWith(size: page.size);

/// Lays [leading] and [trailing] out on the two pages of [fold], each with
/// its own page's media query, so neither crosses the crease.
///
/// Like the other fold layouts, it expects to start at the window's origin,
/// so the fold's window coordinates map onto it directly. When it gets less
/// than the window, as when a Scaffold makes room for the keyboard, each page
/// keeps only the part that is still on screen.
class DisplayFoldSpread extends StatelessWidget {
  /// Spreads [leading] and [trailing] across [fold].
  const DisplayFoldSpread({
    required this.fold,
    required this.leading,
    required this.trailing,
    super.key,
  });

  /// The fold between the pages.
  final DisplayFold fold;

  /// The left page held like a book, the top page propped up.
  final Widget leading;

  /// The right page held like a book, the bottom page propped up.
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Offset.zero & constraints.biggest;
        Widget page(Rect rect, Widget child) {
          final visible = rect.intersect(available);
          if (visible.isEmpty) return const SizedBox.shrink();
          return Positioned.fromRect(
            rect: visible,
            child: MediaQuery(
              data: displayFoldPageMediaQuery(mediaQuery, visible),
              child: child,
            ),
          );
        }

        return Stack(
          children: [
            page(fold.leadingPage(mediaQuery.size), leading),
            page(fold.trailingPage(mediaQuery.size), trailing),
          ],
        );
      },
    );
  }
}

bool _separatesContent(DisplayFeature feature) => switch (feature.type) {
  DisplayFeatureType.hinge => true,
  DisplayFeatureType.fold =>
    feature.state == DisplayFeatureState.postureHalfOpened,
  DisplayFeatureType.cutout || DisplayFeatureType.unknown => false,
};

/// Adds natively reported display features to [MediaQueryData] and provides
/// the system vertical bar through [SystemVerticalBarScope].
///
/// Installed once above the app's navigator, next to the keyboard inset
/// guard, so every route, dialog, and popup sees the fold. Flutter's dialogs
/// and menus already keep to one side of a display feature, and fold-aware
/// layouts read [resolveDisplayFold] from the same data. Features the engine
/// reported itself (Android) pass through untouched.
class PlatformDisplayFeaturesMediaQuery extends StatefulWidget {
  /// Creates a display feature boundary for [child].
  const PlatformDisplayFeaturesMediaQuery({required this.child, super.key});

  /// The subtree that should see platform-reported display features.
  final Widget child;

  @override
  State<PlatformDisplayFeaturesMediaQuery> createState() =>
      _PlatformDisplayFeaturesMediaQueryState();
}

class _PlatformDisplayFeaturesMediaQueryState
    extends State<PlatformDisplayFeaturesMediaQuery>
    with WidgetsBindingObserver {
  final _controller = PlatformDisplayFeaturesController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_handleFeaturesChanged);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleFeaturesChanged);
    super.dispose();
  }

  // The vertical bar appears with new safe area insets, which can come after
  // the first read at launch.
  @override
  void didChangeMetrics() => unawaited(_controller.refresh());

  void _handleFeaturesChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final platformFeatures = _controller.features;
    final mediaQuery = MediaQuery.of(context);
    // The MediaQuery stays whether or not there is a fold, so opening or
    // closing the device changes data only and the app below keeps its state.
    return MediaQuery(
      data: platformFeatures.isEmpty
          ? mediaQuery
          : mediaQuery.copyWith(
              displayFeatures: [
                ...mediaQuery.displayFeatures,
                for (final feature in platformFeatures)
                  _withoutFlatFoldBand(feature),
              ],
            ),
      child: SystemVerticalBarScope(
        bar: _controller.verticalBar,
        child: widget.child,
      ),
    );
  }
}

/// [feature], or for a fold that is open flat, its centre line.
///
/// iOS reports a fold as a band (40 pt on iPhone Duo) in every posture, and
/// Flutter's dialogs and menus keep clear of any feature with an area. Open
/// flat, the display runs straight across the fold, so a line stands in for
/// the band, as Android reports a flat fold.
DisplayFeature _withoutFlatFoldBand(DisplayFeature feature) {
  final bounds = feature.bounds;
  if (feature.type != DisplayFeatureType.fold ||
      feature.state == DisplayFeatureState.postureHalfOpened ||
      bounds.shortestSide == 0) {
    return feature;
  }
  return DisplayFeature(
    bounds: bounds.width <= bounds.height
        ? Rect.fromLTWH(bounds.center.dx, bounds.top, 0, bounds.height)
        : Rect.fromLTWH(bounds.left, bounds.center.dy, bounds.width, 0),
    type: feature.type,
    state: feature.state,
  );
}
