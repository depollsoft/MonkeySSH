import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../controllers/system_keyboard_visibility_controller.dart';

/// Resolves the bottom system inset (gesture handle or navigation bar) that
/// bottom-anchored chrome in this subtree still has to clear.
///
/// [MediaQueryData.padding] usually answers this on its own: Flutter subtracts
/// the on-screen keyboard from it, so it is zero exactly while the keyboard
/// covers the system bar. That only holds when the layout is actually lifted
/// above the keyboard. [Scaffold] strips the bottom view inset from its body
/// once it resizes for the keyboard, so a bottom view inset that survives into
/// this subtree means the layout was *not* lifted — `resizeToAvoidBottomInset`
/// is off, or the platform is reporting a stale inset after the keyboard
/// closed. In that state `padding.bottom` is zero while the navigation bar is
/// still on screen, and bottom chrome would be drawn underneath it.
double resolveSystemBottomInset(MediaQueryData mediaQuery) {
  final unliftedInset = mediaQuery.viewInsets.bottom > 0
      ? mediaQuery.viewPadding.bottom
      : 0.0;
  return math.max(mediaQuery.padding.bottom, unliftedInset);
}

/// Resolves an IME inset using native keyboard visibility when available.
///
/// Android can keep [MediaQueryData.viewInsets] after the IME closes. A native
/// hidden report therefore clears that stale geometry. Before the native channel
/// responds, the reported inset preserves Flutter's normal keyboard avoidance.
double resolvePlatformKeyboardInset({
  required double bottomInset,
  required bool? platformKeyboardVisible,
}) {
  if (bottomInset <= 0 || platformKeyboardVisible == false) return 0;
  return bottomInset;
}

/// Replaces stale keyboard geometry with the platform-authoritative IME state.
class PlatformKeyboardInsetMediaQuery extends StatelessWidget {
  /// Creates a platform-aware keyboard-inset boundary for [child].
  const PlatformKeyboardInsetMediaQuery({required this.child, super.key});

  /// The subtree that should receive corrected keyboard geometry.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final keyboardVisibility = SystemKeyboardVisibilityController.instance;
    return ListenableBuilder(
      listenable: keyboardVisibility,
      child: child,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardInset = resolvePlatformKeyboardInset(
          bottomInset: mediaQuery.viewInsets.bottom,
          platformKeyboardVisible: keyboardVisibility.visible,
        );
        return MediaQuery(
          data: mediaQuery.copyWith(
            viewInsets: mediaQuery.viewInsets.copyWith(bottom: keyboardInset),
          ),
          child: child!,
        );
      },
    );
  }
}

/// Drops the bottom system inset from [mediaQuery].
///
/// Use this for content stacked above chrome that already consumed the inset
/// resolved by [resolveSystemBottomInset], so the inset is not reserved twice.
/// The bottom view inset is left alone because it still describes the keyboard
/// for viewport measurements.
MediaQueryData removeSystemBottomInset(MediaQueryData mediaQuery) =>
    mediaQuery.copyWith(
      padding: mediaQuery.padding.copyWith(bottom: 0),
      viewPadding: mediaQuery.viewPadding.copyWith(bottom: 0),
    );
