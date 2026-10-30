import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fades the ends of [child], a horizontal scroll view, where more of it lies
/// beyond, so a row wider than its box shows that it scrolls.
class ScrollEdgeFade extends StatefulWidget {
  /// Fades the ends of [child] that have more beyond them.
  const ScrollEdgeFade({required this.child, super.key});

  /// How far in from an edge the fade reaches.
  static const double extent = 24;

  /// The scroll view to fade.
  final Widget child;

  @override
  State<ScrollEdgeFade> createState() => ScrollEdgeFadeState();
}

/// The state of a [ScrollEdgeFade]: which of its edges fade.
class ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _fadesStart = false;
  bool _fadesEnd = false;

  /// Whether more of the scroll view lies before its start edge, which fades.
  bool get fadesStart => _fadesStart;

  /// Whether more of the scroll view lies past its end edge, which fades.
  bool get fadesEnd => _fadesEnd;

  bool _handleMetrics(ScrollMetrics metrics) {
    final fadesStart = metrics.extentBefore > 0;
    final fadesEnd = metrics.extentAfter > 0;
    if (fadesStart != _fadesStart || fadesEnd != _fadesEnd) {
      setState(() {
        _fadesStart = fadesStart;
        _fadesEnd = fadesEnd;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    // The mask stays in the tree when nothing fades, so the scroll view under
    // it keeps its state as the row starts or stops overflowing.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final stop = bounds.width <= 0
            ? 0.0
            : math.min(0.5, ScrollEdgeFade.extent / bounds.width);
        return LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: [
            if (_fadesStart) Colors.transparent else Colors.black,
            Colors.black,
            Colors.black,
            if (_fadesEnd) Colors.transparent else Colors.black,
          ],
          stops: [0, stop, 1 - stop, 1],
        ).createShader(bounds, textDirection: textDirection);
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) =>
            notification.depth == 0 && _handleMetrics(notification.metrics),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) =>
              notification.depth == 0 && _handleMetrics(notification.metrics),
          child: widget.child,
        ),
      ),
    );
  }
}
