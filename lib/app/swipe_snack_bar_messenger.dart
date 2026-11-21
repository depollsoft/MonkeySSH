import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'theme.dart';

/// Adds horizontal dismissal to the default swipe-down snack bars.
class SwipeSnackBarMessenger extends ScaffoldMessenger {
  /// Creates a messenger for the app's scaffolds.
  const SwipeSnackBarMessenger({required super.child, super.key});

  @override
  ScaffoldMessengerState createState() => _SwipeSnackBarMessengerState();
}

class _SwipeSnackBarMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) => super.showSnackBar(
    snackBar.dismissDirection == null ? _SwipeSnackBar(snackBar) : snackBar,
    snackBarAnimationStyle: snackBarAnimationStyle,
  );
}

class _SwipeSnackBar extends SnackBar {
  // Scaffold reads the layout fields and ScaffoldMessenger reads the timeout
  // fields from the outer SnackBar; the original renders everything else.
  _SwipeSnackBar(this.original, {super.key})
    : super(
        content: original.content,
        behavior: original.behavior,
        width: original.width,
        duration: original.duration,
        persist: original.persist,
      );

  final SnackBar original;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) =>
      _SwipeSnackBar(
        original.withAnimation(newAnimation, fallbackKey: fallbackKey),
        key: fallbackKey,
      );

  @override
  State<SnackBar> createState() => _SwipeSnackBarState();
}

class _SwipeSnackBarState extends State<_SwipeSnackBar> {
  bool _dismissed = false;

  void _dismiss(DismissDirection direction) {
    if (_dismissed) return;
    _dismissed = true;
    ScaffoldMessenger.of(context)
        .removeCurrentSnackBar(reason: SnackBarClosedReason.swipe);
  }

  @override
  Widget build(BuildContext context) {
    final theme = SnackBarTheme.of(context);
    if (theme.dismissDirection != null) return widget.original;

    // Let the two axis-specific recognizers compete normally with each other
    // and with the action button. Keep Material's semantic dismiss action.
    return SnackBarTheme(
      data: theme.copyWith(dismissDirection: DismissDirection.none),
      child: ClipRect(
        child: Dismissible(
          key: const ValueKey(DismissDirection.horizontal),
          resizeDuration: null,
          behavior: HitTestBehavior.deferToChild,
          onDismissed: _dismiss,
          child: Dismissible(
            key: const ValueKey(DismissDirection.down),
            direction: DismissDirection.down,
            resizeDuration: null,
            behavior: HitTestBehavior.deferToChild,
            onDismissed: _dismiss,
            child: widget.original,
          ),
        ),
      ),
    );
  }
}

/// Lets the widget previewer exercise all three dismissal directions.
@Preview(name: 'Swipe to dismiss a message', size: Size(390, 240))
Widget swipeSnackBarPreview() => MaterialApp(
  theme: FluttyTheme.dark,
  builder: (context, child) => SwipeSnackBarMessenger(child: child!),
  home: Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => FilledButton(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Agent needs your attention'),
              action: SnackBarAction(label: 'Open', onPressed: () {}),
            ),
          ),
          child: const Text('Show message'),
        ),
      ),
    ),
  ),
);
