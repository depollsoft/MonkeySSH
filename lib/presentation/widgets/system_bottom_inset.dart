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

/// How long a keyboard inset must stay unchanged before it is checked against
/// the platform's live keyboard state.
///
/// An ordinary show or dismissal moves the inset every frame, so this only
/// matches geometry that has settled. It is longer than the platform's keyboard
/// animation, and it restarts whenever the inset moves, so slow animations are
/// never cut short.
const staleKeyboardInsetDelay = Duration(milliseconds: 500);

/// Replaces stale keyboard geometry with the platform-authoritative IME state.
///
/// Installed once above the app's navigator, so every route, sheet, and dialog
/// inherits the corrected [MediaQueryData.viewInsets]. Android's embedding can
/// keep reporting a keyboard-sized bottom inset after the IME closes, and every
/// [Scaffold] would then reserve an empty keyboard-sized gap.
///
/// Once a bottom inset has settled for [staleKeyboardInsetDelay], the live
/// platform state is queried, whatever the cached visibility says, because a
/// missed hide event can leave that cache claiming a keyboard. Only a fresh
/// "hidden" answer drops the inset: the uncovered navigation-bar padding is
/// restored and the platform is asked to dispatch fresh insets. A confirmed
/// keyboard is not queried again until its inset or visibility changes. Before
/// the native channel responds, geometry passes through unchanged.
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
  final _controller = SystemKeyboardVisibilityController.instance;
  Timer? _settleTimer;
  // The state the settle timer, or the live query after it, is checking.
  double? _settlingInset;
  bool? _settlingVisible;
  bool _querying = false;
  // An inset the platform confirmed belongs to a visible keyboard.
  double? _confirmedInset;
  bool _insetIsStale = false;
  Stopwatch? _staleStopwatch;

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
    _settleTimer?.cancel();
    super.dispose();
  }

  void _handleVisibilityChanged() => setState(_evaluate);

  void _evaluate() {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final visible = _controller.visible;
    if (inset <= 0 || visible == null) {
      _confirmedInset = null;
      _resetStaleTracking(recovered: inset <= 0);
      return;
    }
    if (visible) {
      // The platform reports a keyboard, so its inset is shown again.
      if (_insetIsStale) _resetStaleTracking(recovered: false);
      if (inset == _confirmedInset) return;
    } else {
      _confirmedInset = null;
      if (_insetIsStale) return;
    }
    // A live query in flight answers for this inset whatever the cache says.
    if (_querying && inset == _settlingInset) return;
    if (_settleTimer != null &&
        inset == _settlingInset &&
        visible == _settlingVisible) {
      return;
    }
    // The inset or the platform's report is new: wait for both to settle.
    _settlingInset = inset;
    _settlingVisible = visible;
    _settleTimer?.cancel();
    _settleTimer = Timer(staleKeyboardInsetDelay, _checkSettledInset);
  }

  Future<void> _checkSettledInset() async {
    _settleTimer = null;
    final settledInset = _settlingInset;
    // Decide on the live platform state, not a cached report that may have
    // missed a show or hide event.
    _querying = true;
    final liveVisible = await _controller.refresh();
    _querying = false;
    // The inset moved while the platform answered, so a new wait is running.
    if (!mounted || _settleTimer != null || _insetIsStale) return;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset <= 0 || inset != settledInset) {
      setState(_evaluate);
      return;
    }
    if (liveVisible == true) {
      _confirmedInset = inset;
      return;
    }
    // Without a fresh "hidden" answer the inset may belong to a real keyboard.
    // Leave it until the next inset or visibility change asks again.
    if (liveVisible != false) return;
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
    _settleTimer?.cancel();
    _settleTimer = null;
    _settlingInset = null;
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
