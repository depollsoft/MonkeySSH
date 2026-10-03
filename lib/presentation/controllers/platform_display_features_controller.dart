import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/services/diagnostics_log_service.dart';

/// Display features reported by native code that the Flutter engine does not
/// report on its own.
///
/// Android foldables arrive through `MediaQueryData.displayFeatures` already.
/// iPhone Duo reports its fold as a UIKit reserved region instead, so the iOS
/// runner forwards the fold's division region over this channel in the Flutter
/// view's coordinate space (logical pixels).
class PlatformDisplayFeaturesController extends ChangeNotifier {
  PlatformDisplayFeaturesController._();

  /// Process-wide controller for the shared Flutter engine.
  static final instance = PlatformDisplayFeaturesController._();

  static const _channel = MethodChannel(
    'xyz.depollsoft.monkeyssh/display_features',
  );

  bool _initialized = false;
  List<DisplayFeature> _features = const <DisplayFeature>[];

  /// The features the platform reported most recently.
  List<DisplayFeature> get features => _features;

  /// Starts native delivery and reads the current features.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      final features = await _channel.invokeMethod<List<Object?>>(
        'getDisplayFeatures',
      );
      _setFeatures(parsePlatformDisplayFeatures(features));
    } on MissingPluginException {
      // Platforms without a bridge rely on the engine's own display features.
    } on PlatformException {
      // Display features only refine layout; keep the plain layout on failure.
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onDisplayFeaturesChanged') {
      _setFeatures(parsePlatformDisplayFeatures(call.arguments));
    }
    return null;
  }

  void _setFeatures(List<DisplayFeature> features) {
    if (listEquals(features, _features)) return;
    _features = List.unmodifiable(features);
    DiagnosticsLogService.instance.debug(
      'display.features',
      'changed',
      fields: {
        'count': features.length,
        'halfOpened': features
            .where(
              (feature) =>
                  feature.state == DisplayFeatureState.postureHalfOpened,
            )
            .length,
      },
    );
    notifyListeners();
  }

  /// Replaces the reported features in tests.
  @visibleForTesting
  void debugSetFeatures(List<DisplayFeature> features) =>
      _setFeatures(features);
}

/// Parses the native display feature payload.
///
/// Each entry is a map with `left`, `top`, `width`, and `height` in logical
/// pixels, a `type` of `fold`, `hinge`, or `cutout`, and a `state` of `flat`
/// or `halfOpened`. Malformed entries are skipped.
@visibleForTesting
List<DisplayFeature> parsePlatformDisplayFeatures(Object? payload) {
  if (payload is! List) return const <DisplayFeature>[];
  final features = <DisplayFeature>[];
  for (final entry in payload) {
    if (entry is! Map) continue;
    final left = entry['left'];
    final top = entry['top'];
    final width = entry['width'];
    final height = entry['height'];
    if (left is! num || top is! num || width is! num || height is! num) {
      continue;
    }
    if (width < 0 || height < 0) continue;
    features.add(
      DisplayFeature(
        bounds: Rect.fromLTWH(
          left.toDouble(),
          top.toDouble(),
          width.toDouble(),
          height.toDouble(),
        ),
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
  return features;
}
