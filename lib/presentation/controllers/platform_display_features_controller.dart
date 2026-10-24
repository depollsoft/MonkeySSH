import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../domain/services/diagnostics_log_service.dart';

/// The edge of the window that holds the system's vertical bar.
enum SystemVerticalBarEdge {
  /// The bar runs down the left edge.
  left,

  /// The bar runs down the right edge.
  right,
}

/// The strip iOS 27.1 draws down one edge of iPhone Duo's displays.
///
/// It holds the status bar and, in native apps, the navigation and tab bar
/// items, which sit in a column below the status cluster.
@immutable
class SystemVerticalBar {
  /// Creates a vertical bar on [edge] whose items sit in [itemColumn].
  const SystemVerticalBar({required this.edge, required this.itemColumn});

  /// The window edge the bar runs down.
  final SystemVerticalBarEdge edge;

  /// Where a native app lays out 44 pt bar items, in window coordinates. It
  /// starts below the status cluster, which grows while a Live Activity
  /// shows, and ends above the home indicator.
  final Rect itemColumn;

  @override
  bool operator ==(Object other) =>
      other is SystemVerticalBar &&
      other.edge == edge &&
      other.itemColumn == itemColumn;

  @override
  int get hashCode => Object.hash(edge, itemColumn);

  @override
  String toString() => 'SystemVerticalBar($edge, $itemColumn)';
}

/// Display geometry reported by native code that the Flutter engine does not
/// report on its own.
///
/// Android foldables arrive through `MediaQueryData.displayFeatures` already.
/// On iPhone Duo, UIKit reports the fold as a reserved region and the vertical
/// bar through its trait collection, so the iOS runner forwards both over this
/// channel in the Flutter view's coordinate space (logical pixels).
class PlatformDisplayFeaturesController extends ChangeNotifier {
  PlatformDisplayFeaturesController._();

  /// Process-wide controller for the shared Flutter engine.
  static final instance = PlatformDisplayFeaturesController._();

  static const _channel = MethodChannel(
    'xyz.depollsoft.monkeyssh/display_features',
  );

  bool _initialized = false;
  bool _bridgeMissing = false;
  List<DisplayFeature> _features = const <DisplayFeature>[];
  SystemVerticalBar? _verticalBar;

  /// The features the platform reported most recently.
  List<DisplayFeature> get features => _features;

  /// The vertical bar the platform reported most recently, if it shows one.
  SystemVerticalBar? get verticalBar => _verticalBar;

  /// Starts native delivery and reads the current state.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    await refresh();
  }

  /// Reads the current state from the platform.
  ///
  /// The platform also reports changes as they happen, but at launch the
  /// vertical bar settles after the first read, so the app reads again
  /// whenever the window's metrics change.
  Future<void> refresh() async {
    if (!_initialized || _bridgeMissing) return;
    try {
      final state = await _channel.invokeMethod<Object?>('getDisplayState');
      _setState(parsePlatformDisplayState(state));
    } on MissingPluginException {
      // Platforms without a bridge rely on the engine's own display features.
      _bridgeMissing = true;
    } on PlatformException {
      // Display state only refines layout; keep the plain layout on failure.
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onDisplayStateChanged') {
      _setState(parsePlatformDisplayState(call.arguments));
    }
    return null;
  }

  void _setState(PlatformDisplayState state) {
    if (listEquals(state.features, _features) &&
        state.verticalBar == _verticalBar) {
      return;
    }
    _features = List.unmodifiable(state.features);
    _verticalBar = state.verticalBar;
    DiagnosticsLogService.instance.debug(
      'display.features',
      'changed',
      fields: {
        'count': _features.length,
        'halfOpened': _features
            .where(
              (feature) =>
                  feature.state == DisplayFeatureState.postureHalfOpened,
            )
            .length,
        'verticalBar': _verticalBar?.edge.name ?? 'none',
      },
    );
    notifyListeners();
  }

  /// Replaces the reported state in tests.
  @visibleForTesting
  void debugSetState({
    List<DisplayFeature> features = const <DisplayFeature>[],
    SystemVerticalBar? verticalBar,
  }) => _setState(
    PlatformDisplayState(features: features, verticalBar: verticalBar),
  );
}

/// One native display state report.
@immutable
class PlatformDisplayState {
  /// Creates a display state report.
  const PlatformDisplayState({required this.features, this.verticalBar});

  /// Folds and other display features.
  final List<DisplayFeature> features;

  /// The system vertical bar, when the display shows one.
  final SystemVerticalBar? verticalBar;
}

/// Parses the native display state payload.
///
/// `features` lists maps with `left`, `top`, `width`, and `height` in logical
/// pixels, a `type` of `fold`, `hinge`, or `cutout`, and a `state` of `flat`
/// or `halfOpened`. `verticalBar`, when present, is a map with the item
/// column's `left`, `top`, `width`, and `height` and an `edge` of `left` or
/// `right`. Malformed entries are skipped.
@visibleForTesting
PlatformDisplayState parsePlatformDisplayState(Object? payload) {
  if (payload is! Map) {
    return const PlatformDisplayState(features: <DisplayFeature>[]);
  }
  final features = <DisplayFeature>[];
  final featureEntries = payload['features'];
  if (featureEntries is List) {
    for (final entry in featureEntries) {
      if (entry is! Map) continue;
      final bounds = _parseRect(entry);
      if (bounds == null) continue;
      features.add(
        DisplayFeature(
          bounds: bounds,
          type: switch (entry['type']) {
            'fold' => DisplayFeatureType.fold,
            'hinge' => DisplayFeatureType.hinge,
            'cutout' => DisplayFeatureType.cutout,
            _ => DisplayFeatureType.unknown,
          },
          state: switch (entry['state']) {
            'flat' => DisplayFeatureState.postureFlat,
            'halfOpened' => DisplayFeatureState.postureHalfOpened,
            _ => DisplayFeatureState.unknown,
          },
        ),
      );
    }
  }
  SystemVerticalBar? verticalBar;
  final barEntry = payload['verticalBar'];
  if (barEntry is Map) {
    final column = _parseRect(barEntry);
    final edge = switch (barEntry['edge']) {
      'left' => SystemVerticalBarEdge.left,
      'right' => SystemVerticalBarEdge.right,
      _ => null,
    };
    if (column != null && edge != null && !column.isEmpty) {
      verticalBar = SystemVerticalBar(edge: edge, itemColumn: column);
    }
  }
  return PlatformDisplayState(features: features, verticalBar: verticalBar);
}

Rect? _parseRect(Map<Object?, Object?> entry) {
  final left = entry['left'];
  final top = entry['top'];
  final width = entry['width'];
  final height = entry['height'];
  if (left is! num || top is! num || width is! num || height is! num) {
    return null;
  }
  if (width < 0 || height < 0) return null;
  return Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
}
