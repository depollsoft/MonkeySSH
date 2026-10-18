import 'package:flutter/material.dart';

import '../shortcuts/app_shortcuts.dart';

/// Returns the route focus policy for terminal-adjacent overlays.
///
/// Mobile overlays should not steal focus from the terminal text input client
/// because doing so hides the soft keyboard. Desktop and web keep Flutter's
/// default route focus behavior so keyboard navigation remains available.
/// Overlays opened by a hardware keyboard shortcut also keep the default, so
/// arrows, Return and Esc work in them; see [hardwareKeyboardOverlaysTakeFocus].
bool? terminalOverlayRouteRequestFocus(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return hardwareKeyboardOverlaysTakeFocus ? null : false;
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return null;
  }
}
