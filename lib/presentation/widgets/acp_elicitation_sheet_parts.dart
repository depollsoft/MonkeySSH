import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Shows an elicitation bottom sheet that closes when [withdrawn] completes.
///
/// The sheet's own route is closed, together with anything opened above it
/// from the sheet such as a date picker, so a withdrawal never pops an
/// unrelated route and the returned future always resolves (with `null`).
Future<T?> showAcpWithdrawableSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Future<void>? withdrawn,
}) {
  final navigator = Navigator.of(context);
  final localizations = MaterialLocalizations.of(context);
  final route = ModalBottomSheetRoute<T>(
    builder: builder,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(
      localizations.bottomSheetLabel,
    ),
    modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
  );
  unawaited(
    withdrawn?.then((_) {
      final routeNavigator = route.navigator;
      if (routeNavigator == null || !route.isActive) return;
      routeNavigator
        ..popUntil((candidate) => identical(candidate, route))
        ..pop();
    }),
  );
  return navigator.push(route);
}

/// Title row shared by the elicitation sheets, with an explicit dismiss
/// control so dismissing never depends on a drag gesture.
class AcpElicitationSheetHeader extends StatelessWidget {
  /// Creates a sheet header.
  const AcpElicitationSheetHeader({
    required this.title,
    required this.onDismiss,
    super.key,
  });

  /// Title naming the agent and what it asks for.
  final String title;

  /// Closes the sheet without answering.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingLg,
        0,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingXs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: FluttyTheme.displayMono(
                    fontSize: 18,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss without answering',
            icon: const Icon(Icons.close),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Bottom-anchored sheet actions within thumb reach, divided from the
/// scrolling content by a hairline.
class AcpElicitationSheetFooter extends StatelessWidget {
  /// Creates a sheet footer.
  const AcpElicitationSheetFooter({
    required this.secondary,
    required this.primary,
    this.notice,
    super.key,
  });

  /// The leading, lower-emphasis action.
  final Widget secondary;

  /// The trailing primary action.
  final Widget primary;

  /// Optional explanation shown above the actions.
  final String? notice;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingLg,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingLg,
          FluttyTheme.spacingSm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notice case final text?) ...[
              AcpElicitationNotice(icon: Icons.info_outline, text: text),
              const SizedBox(height: FluttyTheme.spacingSm),
            ],
            Row(children: [secondary, const Spacer(), primary]),
          ],
        ),
      ),
    ),
  );
}

/// A one-line notice paired with an icon, so its tone never relies on color.
class AcpElicitationNotice extends StatelessWidget {
  /// Creates a notice.
  const AcpElicitationNotice({
    required this.icon,
    required this.text,
    this.color,
    this.iconColor,
    super.key,
  });

  /// Leading icon.
  final IconData icon;

  /// Plain text; never linkified.
  final String text;

  /// Text color; defaults to the muted foreground.
  final Color? color;

  /// Icon color; defaults to [color].
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: iconColor ?? tone),
        ),
        const SizedBox(width: FluttyTheme.spacingSm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: tone),
          ),
        ),
      ],
    );
  }
}
