import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme.dart';

/// Buttons side by side at equal widths when every label fits on one line in
/// its share of the row, otherwise stacked at full width.
///
/// A pair of half-width buttons on a phone wraps one label onto two lines and
/// leaves the buttons at different heights; stacking keeps each label on one
/// line at any width or text scale.
class AdaptiveButtonRow extends MultiChildRenderObjectWidget {
  /// Creates the row.
  const AdaptiveButtonRow({
    required super.children,
    this.spacing = FluttyTheme.spacingSm,
    super.key,
  });

  /// Gap between buttons, across or down.
  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAdaptiveButtonRow(spacing);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderAdaptiveButtonRow).spacing = spacing;
}

class _ButtonRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAdaptiveButtonRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ButtonRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ButtonRowParentData> {
  _RenderAdaptiveButtonRow(this._spacing);

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ButtonRowParentData) {
      child.parentData = _ButtonRowParentData();
    }
  }

  Iterable<RenderBox> get _children sync* {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      yield child;
    }
  }

  double _share(double width) =>
      (width - _spacing * (childCount - 1)) / childCount;

  bool _fitsInRow(double width) {
    if (!width.isFinite) return true;
    final share = _share(width);
    return _children.every(
      (child) => child.getMaxIntrinsicWidth(double.infinity) <= share,
    );
  }

  /// Lays out (or, when [dry], measures) every child and returns the size.
  Size _layout(BoxConstraints constraints, {required bool dry}) {
    if (childCount == 0) return constraints.smallest;
    final width = constraints.maxWidth;
    Size sizeOf(RenderBox child, BoxConstraints childConstraints) => dry
        ? child.getDryLayout(childConstraints)
        : (child..layout(childConstraints, parentUsesSize: true)).size;

    if (_fitsInRow(width)) {
      final share = width.isFinite ? _share(width) : double.infinity;
      final measure = share.isFinite
          ? BoxConstraints.tightFor(width: share)
          : const BoxConstraints();
      final height = _children.fold<double>(
        0,
        (tallest, child) => math.max(tallest, sizeOf(child, measure).height),
      );
      var x = 0.0;
      for (final child in _children) {
        final childSize = sizeOf(
          child,
          share.isFinite
              ? BoxConstraints.tightFor(width: share, height: height)
              : BoxConstraints.tightFor(height: height),
        );
        if (!dry) {
          (child.parentData! as _ButtonRowParentData).offset = Offset(x, 0);
        }
        x += childSize.width + _spacing;
      }
      return constraints.constrain(Size(x - _spacing, height));
    }

    var y = 0.0;
    for (final child in _children) {
      final childSize = sizeOf(child, BoxConstraints.tightFor(width: width));
      if (!dry) {
        (child.parentData! as _ButtonRowParentData).offset = Offset(0, y);
      }
      y += childSize.height + _spacing;
    }
    return constraints.constrain(Size(width, y - _spacing));
  }

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) => _children.fold(
    0,
    (widest, child) => math.max(widest, child.getMinIntrinsicWidth(height)),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _children.fold<double>(
        0,
        (sum, child) => sum + child.getMaxIntrinsicWidth(height),
      ) +
      _spacing * math.max(0, childCount - 1);

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
