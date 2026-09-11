import 'dart:async';

import 'package:flutter/material.dart';

/// The MonkeySSH brand mark: a terminal cursor block (`▮`) that can blink.
///
/// Used as the signature motif across the app — trailing the wordmark, marking
/// active states, and anchoring loading and empty states. It blinks like a live
/// terminal cursor, and honors the platform "reduce motion" setting by rendering
/// static when animations are disabled.
///
/// The blink is driven by a [Timer] (a hard on/off toggle, like a real terminal
/// cursor) rather than a repeating animation, so it never blocks
/// `WidgetTester.pumpAndSettle` in tests.
class CursorBlock extends StatefulWidget {
  /// Creates a [CursorBlock].
  const CursorBlock({super.key, this.color, this.size});

  /// Block color. Defaults to the theme's primary (Signal Teal).
  final Color? color;

  /// Block size (drives its width and height) in logical pixels. Defaults to
  /// the ambient text size.
  final double? size;

  @override
  State<CursorBlock> createState() => _CursorBlockState();
}

class _CursorBlockState extends State<CursorBlock> {
  Timer? _timer;
  bool _on = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!reduceMotion) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 530), (_) {
        if (mounted) {
          setState(() => _on = !_on);
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _on = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final fontSize =
        widget.size ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    // A geometric block (not a glyph) so its size and baseline are predictable
    // regardless of the ambient font. Rendered inside a WidgetSpan with
    // PlaceholderAlignment.baseline so its bottom sits on the text baseline,
    // filling upward like a real terminal cursor.
    return ExcludeSemantics(
      child: _CursorBox(
        width: fontSize * 0.5,
        height: fontSize * 0.92,
        radius: fontSize * 0.06,
        color: color,
        visible: _on,
      ),
    );
  }
}

/// Renders the cursor block as a leaf render object so it can report a baseline
/// (its bottom edge) and a dry baseline. This lets it live in a [WidgetSpan]
/// with [PlaceholderAlignment.baseline] inside intrinsic-height layouts (such
/// as `SliverFillRemaining`) without crashing — which a plain [Container]
/// (a `RenderDecoratedBox`, which has no dry baseline) cannot do.
class _CursorBox extends LeafRenderObjectWidget {
  const _CursorBox({
    required this.width,
    required this.height,
    required this.radius,
    required this.color,
    required this.visible,
  });

  final double width;
  final double height;
  final double radius;
  final Color color;
  final bool visible;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCursorBox(
    width: width,
    height: height,
    radius: radius,
    color: color,
    visible: visible,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderCursorBox renderObject) {
    renderObject
      ..boxWidth = width
      ..boxHeight = height
      ..radius = radius
      ..color = color
      ..visible = visible;
  }
}

class _RenderCursorBox extends RenderBox {
  _RenderCursorBox({
    required double width,
    required double height,
    required double radius,
    required Color color,
    required bool visible,
  }) : _boxWidth = width,
       _boxHeight = height,
       _radius = radius,
       _color = color,
       _visible = visible;

  double _boxWidth;
  double _boxHeight;
  double _radius;
  Color _color;
  bool _visible;

  double get boxWidth => _boxWidth;

  set boxWidth(double value) {
    if (value != _boxWidth) {
      _boxWidth = value;
      markNeedsLayout();
    }
  }

  double get boxHeight => _boxHeight;

  set boxHeight(double value) {
    if (value != _boxHeight) {
      _boxHeight = value;
      markNeedsLayout();
    }
  }

  double get radius => _radius;

  set radius(double value) {
    if (value != _radius) {
      _radius = value;
      markNeedsPaint();
    }
  }

  Color get color => _color;

  set color(Color value) {
    if (value != _color) {
      _color = value;
      markNeedsPaint();
    }
  }

  bool get visible => _visible;

  set visible(bool value) {
    if (value != _visible) {
      _visible = value;
      markNeedsPaint();
    }
  }

  Size get _boxSize => Size(_boxWidth, _boxHeight);

  @override
  double computeMinIntrinsicWidth(double height) => _boxWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _boxWidth;

  @override
  double computeMinIntrinsicHeight(double width) => _boxHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _boxHeight;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_boxSize);

  // The cursor straddles the baseline like a real terminal cell: most of the
  // block sits above the baseline (up to the cap height), with a small part
  // below it (the descender). Reporting the baseline ~78% down the box gives
  // that proportion.
  static const double _baselineFraction = 0.78;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      size.height * _baselineFraction;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => constraints.constrain(_boxSize).height * _baselineFraction;

  @override
  void performLayout() {
    size = constraints.constrain(_boxSize);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_visible) {
      return;
    }
    final rrect = RRect.fromRectAndRadius(
      offset & size,
      Radius.circular(_radius),
    );
    context.canvas.drawRRect(rrect, Paint()..color = _color);
  }
}
