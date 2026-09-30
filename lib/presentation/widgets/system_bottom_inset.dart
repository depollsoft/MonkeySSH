import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../domain/services/diagnostics_log_service.dart';
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

/// How long a hidden-keyboard report must disagree with an unchanging IME inset
/// before that inset is treated as stale.
///
/// An ordinary dismissal shrinks the inset every frame until it reaches zero,
/// so this only matches geometry the platform stopped updating. It is longer
/// than the platform's keyboard hide animation, and it restarts whenever the
/// inset moves, so slow animations are never cut short.
const staleKeyboardInsetDelay = Duration(milliseconds: 500);

/// Replaces stale keyboard geometry with the platform-authoritative IME state.
///
/// Installed once above the app's navigator, so every route, sheet, and dialog
/// inherits the corrected [MediaQueryData.viewInsets]. Android's embedding can
/// keep reporting a keyboard-sized bottom inset after the IME closes, and every
/// [Scaffold] would then reserve an empty keyboard-sized gap. When the native channel reports the
/// keyboard hidden and the inset has not moved for [staleKeyboardInsetDelay],
/// the inset is dropped, the uncovered navigation-bar padding is restored, and
/// the platform is asked to dispatch fresh insets. Before the native channel
/// responds, or while it reports the keyboard visible, geometry passes through
/// unchanged.
class PlatformKeyboardInsetMediaQuery extends StatefulWidget {
  /// Creates a platform-aware keyboard-inset boundary for [child].
  const PlatformKeyboardInsetMediaQuery({required this.child, super.key});

  /// The subtree that should receive corrected keyboard geometry.
  final Widget child;

  @override
  State<PlatformKeyboardInsetMediaQuery> createState() =>
      _PlatformKeyboardInsetMediaQueryState();
}

class _PlatformKeyboardInsetMediaQueryState
    extends State<PlatformKeyboardInsetMediaQuery> {
  Timer? _staleTimer;
  double? _pendingInset;
  bool _insetIsStale = false;
  Stopwatch? _staleStopwatch;

  final _controller = SystemKeyboardVisibilityController.instance;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleVisibilityChanged);
    unawaited(_controller.initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _evaluate();
  }

  @override
  void dispose() {
    _controller.removeListener(_handleVisibilityChanged);
    _staleTimer?.cancel();
    super.dispose();
  }

  void _handleVisibilityChanged() => setState(_evaluate);

  void _evaluate() {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset <= 0 || _controller.visible != false) {
      _resetStaleTracking(recovered: inset <= 0);
      return;
    }
    if (_insetIsStale || (_staleTimer != null && _pendingInset == inset)) {
      return;
    }
    // Hidden per the platform, but the inset is new or still moving: wait for
    // it to settle. Re-read the live state once meanwhile in case the cached
    // report predates a missed show event.
    if (_staleTimer == null) unawaited(_controller.refresh());
    _pendingInset = inset;
    _staleTimer?.cancel();
    _staleTimer = Timer(staleKeyboardInsetDelay, _confirmStaleInset);
  }

  void _confirmStaleInset() {
    _staleTimer = null;
    if (!mounted) return;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset <= 0 || _controller.visible != false || inset != _pendingInset) {
      setState(_evaluate);
      return;
    }
    setState(() => _insetIsStale = true);
    _staleStopwatch = Stopwatch()..start();
    DiagnosticsLogService.instance.warning(
      'keyboard.inset',
      'stale_cleared',
      fields: {'insetDp': inset.round()},
    );
    unawaited(_controller.requestInsetsRefresh());
  }

  void _resetStaleTracking({required bool recovered}) {
    _staleTimer?.cancel();
    _staleTimer = null;
    _pendingInset = null;
    if (!_insetIsStale) return;
    _insetIsStale = false;
    DiagnosticsLogService.instance.info(
      'keyboard.inset',
      recovered ? 'stale_recovered' : 'stale_superseded',
      fields: {'durationMs': _staleStopwatch?.elapsedMilliseconds},
    );
    _staleStopwatch = null;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // Always build the same MediaQuery so toggling the correction never
    // remounts the navigator below.
    return MediaQuery(
      data: _insetIsStale
          ? mediaQuery.copyWith(
              viewInsets: mediaQuery.viewInsets.copyWith(bottom: 0),
              // Flutter derives padding from viewPadding minus viewInsets, so
              // the navigation bar the stale inset hid is uncovered again.
              padding: mediaQuery.padding.copyWith(
                bottom: mediaQuery.viewPadding.bottom,
              ),
            )
          : mediaQuery,
      child: widget.child,
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
