import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../shortcuts/app_shortcuts.dart';

/// Hardware-keyboard navigation for a vertical list of focusable rows.
///
/// - Up and Down move focus to the previous or next visual row. A row is the
///   set of focusable widgets that share a vertical band, and the leftmost one
///   (the tile itself, not its trailing buttons) receives focus. With nothing
///   in the list focused, Down starts at the first row and Up at the last.
/// - Left and Right move between the focusable widgets of the focused row,
///   so trailing row buttons stay reachable even though they sit inside the
///   row's own bounds.
/// - Return and Space activate the focused row through its own
///   [ActivateIntent] handling, as a hardware keyboard flow, so a sheet or
///   dialog the row opens takes keyboard focus too.
/// - Esc runs [onEscape]. Without one it asks the enclosing route to dismiss
///   (closing a sheet), and failing that it returns focus to the list itself.
///
/// The focused row gets a 2 px ring in the theme's primary color while the
/// keyboard is driving focus, so focus never relies on a tint alone.
class KeyboardListNavigation extends StatefulWidget {
  /// Creates keyboard navigation for [child].
  const KeyboardListNavigation({
    required this.child,
    this.onEscape,
    this.autofocus = false,
    super.key,
  });

  /// The list.
  final Widget child;

  /// Called when Esc is pressed inside the list.
  final VoidCallback? onEscape;

  /// Lets the list itself take focus when nothing else in its scope has it,
  /// so the first arrow press lands in the list. Only applies while the
  /// enclosing route is the current one, so a list rebuilt under another
  /// route never pulls focus away from it.
  final bool autofocus;

  @override
  State<KeyboardListNavigation> createState() => KeyboardListNavigationState();
}

/// State for [KeyboardListNavigation].
class KeyboardListNavigationState extends State<KeyboardListNavigation> {
  late final FocusNode _containerNode = FocusNode(
    debugLabel: 'KeyboardListNavigation',
    skipTraversal: true,
  );
  final _ringRepaint = ValueNotifier<int>(0);
  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    DirectionalFocusIntent: _RowDirectionalFocusAction(this),
    DismissIntent: _ListDismissAction(this),
  };

  /// Whether keyboard focus is on a row inside the list.
  bool get hasFocusedRow {
    final primary = FocusManager.instance.primaryFocus;
    return primary != null &&
        !identical(primary, _containerNode) &&
        _containerNode.hasFocus;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance
      ..addListener(_handleFocusChanged)
      ..addHighlightModeListener(_handleHighlightModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance
      ..removeListener(_handleFocusChanged)
      ..removeHighlightModeListener(_handleHighlightModeChanged);
    _containerNode.dispose();
    _ringRepaint.dispose();
    super.dispose();
  }

  bool _ringShown = false;

  bool get _ringWanted =>
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
      hasFocusedRow;

  /// Repaints the ring only while it shows or as it hides, so focus changes
  /// elsewhere in the app never repaint the list.
  void _refreshRing() {
    final wanted = _ringWanted;
    if (wanted || _ringShown) {
      _ringShown = wanted;
      _ringRepaint.value++;
    }
  }

  void _handleFocusChanged() => _refreshRing();

  void _handleHighlightModeChanged(FocusHighlightMode _) => _refreshRing();

  /// Focuses the first row. Returns false when the list has no rows.
  bool focusFirstRow() => _focusRow(0);

  /// Moves focus [delta] rows. Returns false when the list has no rows.
  bool moveFocus(int delta) {
    final rows = _rows();
    if (rows.isEmpty) {
      return false;
    }
    final primary = FocusManager.instance.primaryFocus;
    final current = primary == null
        ? -1
        : rows.indexWhere((row) => row.any((node) => identical(node, primary)));
    final int target;
    if (current < 0) {
      target = delta >= 0 ? 0 : rows.length - 1;
    } else {
      target = (current + delta).clamp(0, rows.length - 1);
    }
    _requestFocus(rows[target].first, forward: delta >= 0);
    return true;
  }

  /// Focuses the first row whose leading node passes [test]. Returns false
  /// when no row does.
  bool focusRowWhere(bool Function(FocusNode node) test) {
    for (final row in _rows()) {
      if (test(row.first)) {
        _requestFocus(row.first, forward: true);
        return true;
      }
    }
    return false;
  }

  /// Moves focus [delta] widgets along the focused row. Returns false when
  /// focus is not on a row or the row has nothing in that direction.
  bool moveFocusWithinRow(int delta) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) {
      return false;
    }
    for (final row in _rows()) {
      final index = row.indexWhere((node) => identical(node, primary));
      if (index < 0) {
        continue;
      }
      final target = index + delta;
      if (target < 0 || target >= row.length) {
        return false;
      }
      _requestFocus(row[target], forward: delta >= 0);
      return true;
    }
    return false;
  }

  bool _focusRow(int index) {
    final rows = _rows();
    if (index < 0 || index >= rows.length) {
      return false;
    }
    _requestFocus(rows[index].first, forward: true);
    return true;
  }

  void _requestFocus(FocusNode node, {required bool forward}) {
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
      node,
      alignmentPolicy: forward
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  /// Focusable descendants grouped into visual rows, top to bottom. Each row
  /// lists its nodes left to right.
  List<List<FocusNode>> _rows() {
    final nodes = [
      for (final node in _containerNode.traversalDescendants)
        if (node.canRequestFocus &&
            node.context != null &&
            node.context!.mounted &&
            !node.rect.isEmpty)
          node,
    ]..sort((a, b) => a.rect.center.dy.compareTo(b.rect.center.dy));
    final rows = <List<FocusNode>>[];
    Rect? band;
    for (final node in nodes) {
      final center = node.rect.center.dy;
      if (band != null && center >= band.top && center <= band.bottom) {
        rows.last.add(node);
        band = band.expandToInclude(node.rect);
      } else {
        rows.add([node]);
        band = node.rect;
      }
    }
    for (final row in rows) {
      row.sort((a, b) => a.rect.left.compareTo(b.rect.left));
    }
    return rows;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !hasFocusedRow || _hasModifier()) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) {
      return KeyEventResult.ignored;
    }
    const intent = ActivateIntent();
    final action = Actions.maybeFind<ActivateIntent>(
      focusedContext,
      intent: intent,
    );
    if (action == null || !action.isEnabled(intent)) {
      return KeyEventResult.ignored;
    }
    runHardwareKeyboardFlow(
      () =>
          Actions.of(focusedContext)
              .invokeAction(action, intent, focusedContext),
    );
    return KeyEventResult.handled;
  }

  static bool _hasModifier() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed;
  }

  void _handleEscape(DismissIntent intent) {
    final onEscape = widget.onEscape;
    if (onEscape != null) {
      onEscape();
      return;
    }
    // This state's context sits above its own Actions, so the lookup finds
    // the enclosing route's dismiss action, if any.
    final outer = Actions.maybeFind<DismissIntent>(context, intent: intent);
    final outerEnabled = switch (outer) {
      null => false,
      final ContextAction<DismissIntent> action => action.isEnabled(
        intent,
        context,
      ),
      final Action<DismissIntent> action => action.isEnabled(intent),
    };
    if (outer != null && outerEnabled) {
      Actions.of(context).invokeAction(outer, intent, context);
    } else if (hasFocusedRow) {
      _containerNode.requestFocus();
    }
  }

  Rect? _focusRingRect(RenderBox box) {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional ||
        !hasFocusedRow) {
      return null;
    }
    final rect = FocusManager.instance.primaryFocus!.rect;
    if (rect.isEmpty || !box.attached) {
      return null;
    }
    final topLeft = box.globalToLocal(rect.topLeft);
    return topLeft & rect.size;
  }

  @override
  Widget build(BuildContext context) {
    final ringColor = Theme.of(context).colorScheme.primary;
    // Actions sit above the container's Focus so arrows reach them while the
    // list itself, not a row, holds focus.
    return Actions(
      actions: _actions,
      child: Focus(
        focusNode: _containerNode,
        autofocus:
            widget.autofocus && (ModalRoute.of(context)?.isCurrent ?? true),
        includeSemantics: false,
        onKeyEvent: _handleKeyEvent,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _refreshRing();
            return false;
          },
          child: _FocusRingPaint(
            repaint: _ringRepaint,
            color: ringColor,
            resolveRect: _focusRingRect,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _RowDirectionalFocusAction extends DirectionalFocusAction {
  _RowDirectionalFocusAction(this._state);

  final KeyboardListNavigationState _state;

  @override
  void invoke(DirectionalFocusIntent intent) {
    final handled = switch (intent.direction) {
      TraversalDirection.up => _state.moveFocus(-1),
      TraversalDirection.down => _state.moveFocus(1),
      TraversalDirection.left => _state.moveFocusWithinRow(-1),
      TraversalDirection.right => _state.moveFocusWithinRow(1),
    };
    if (!handled) {
      super.invoke(intent);
    }
  }
}

class _ListDismissAction extends Action<DismissIntent> {
  _ListDismissAction(this._state);

  final KeyboardListNavigationState _state;

  @override
  void invoke(DismissIntent intent) => _state._handleEscape(intent);
}

class _FocusRingPaint extends SingleChildRenderObjectWidget {
  const _FocusRingPaint({
    required this.repaint,
    required this.color,
    required this.resolveRect,
    required super.child,
  });

  final Listenable repaint;
  final Color color;
  final Rect? Function(RenderBox box) resolveRect;

  @override
  _RenderFocusRing createRenderObject(BuildContext context) => _RenderFocusRing(
    repaint: repaint,
    color: color,
    resolveRect: resolveRect,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderFocusRing renderObject) {
    renderObject
      ..repaint = repaint
      ..color = color
      ..resolveRect = resolveRect;
  }
}

class _RenderFocusRing extends RenderProxyBox {
  _RenderFocusRing({
    required Listenable repaint,
    required Color color,
    required this.resolveRect,
  }) : _repaint = repaint,
       _color = color;

  Listenable _repaint;
  Color _color;
  Rect? Function(RenderBox box) resolveRect;

  Listenable get repaint => _repaint;

  set repaint(Listenable value) {
    if (identical(value, _repaint)) {
      return;
    }
    if (attached) {
      _repaint.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _repaint = value;
  }

  Color get color => _color;

  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final local = resolveRect(this);
    if (local == null) {
      return;
    }
    final clipped = local.intersect(Offset.zero & size);
    if (clipped.isEmpty) {
      return;
    }
    final ring = RRect.fromRectAndRadius(
      clipped.shift(offset).deflate(1),
      const Radius.circular(8),
    );
    context.canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _color,
    );
  }
}
