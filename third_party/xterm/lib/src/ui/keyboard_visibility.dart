import 'package:flutter/widgets.dart';

class KeyboardVisibility extends StatefulWidget {
  const KeyboardVisibility({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  final Widget child;

  final VoidCallback? onKeyboardShow;

  final VoidCallback? onKeyboardHide;

  @override
  KeyboardVisibilityState createState() => KeyboardVisibilityState();
}

class KeyboardVisibilityState extends State<KeyboardVisibility>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // A metrics change queued while the keyboard is hiding still arrives after
    // this state is deactivated (for example when the terminal tab holding it
    // is closed at that moment). `View.of(context)` throws once the element is
    // defunct, so bail out instead.
    if (!mounted) return;

    final bottomInset = View.of(context).viewInsets.bottom;

    if (bottomInset != _lastBottomInset) {
      if (bottomInset > 0) {
        widget.onKeyboardShow?.call();
      } else {
        widget.onKeyboardHide?.call();
      }
    }

    _lastBottomInset = bottomInset;

    super.didChangeMetrics();
  }

  var _lastBottomInset = 0.0;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
