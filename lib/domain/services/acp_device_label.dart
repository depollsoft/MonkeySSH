import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Shortest logical screen side at which a phone platform counts as a tablet.
const _tabletShortestSide = 600.0;

/// Describes this device for other clients of a native chat, such as `iPad`.
///
/// Only the platform and form factor are used. The device name is never read:
/// it often carries the owner's name.
String acpDeviceLabelFor(
  TargetPlatform platform, {
  required double shortestSide,
}) {
  final tablet = shortestSide >= _tabletShortestSide;
  return switch (platform) {
    TargetPlatform.iOS => tablet ? 'iPad' : 'iPhone',
    TargetPlatform.android => tablet ? 'Android tablet' : 'Android phone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.linux => 'Linux PC',
    TargetPlatform.fuchsia => 'Fuchsia device',
  };
}

/// [acpDeviceLabelFor] for the running app. It measures the display rather
/// than the window, so an iPad in split view still reads as an iPad.
String currentAcpDeviceLabel() =>
    acpDeviceLabelFor(defaultTargetPlatform, shortestSide: _shortestSide());

double _shortestSide() {
  final dispatcher = PlatformDispatcher.instance;
  for (final display in dispatcher.displays) {
    if (display.devicePixelRatio > 0 && !display.size.isEmpty) {
      final size = display.size / display.devicePixelRatio;
      return math.min(size.width, size.height);
    }
  }
  final view = dispatcher.implicitView;
  if (view == null || view.devicePixelRatio <= 0) return 0;
  final size = view.physicalSize / view.devicePixelRatio;
  return math.min(size.width, size.height);
}
