import 'package:flutter/material.dart';

/// Minimum contrast for a pill's label against its fill: the WCAG AA level
/// for small text, which every status pill label is.
const statusPillMinContrast = 4.5;

/// WCAG contrast ratio between two opaque colors.
double statusPillContrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (lighter, darker) = la > lb ? (la, lb) : (lb, la);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Returns [foreground] and a [background] it can be read on.
///
/// Theme container colors were not chosen for 10 px labels: white on the
/// default Alert Red is about 3.3:1. When the pair falls below
/// [statusPillMinContrast], the background is shaded away from the label
/// (darker under a light label, lighter under a dark one) only as far as it
/// takes, so the hue stays recognizable on every theme.
(Color, Color) legiblePillColors(Color foreground, Color background) {
  if (statusPillContrast(foreground, background) >= statusPillMinContrast) {
    return (foreground, background);
  }
  final towards =
      statusPillContrast(foreground, Colors.black) >=
          statusPillContrast(foreground, Colors.white)
      ? Colors.black
      : Colors.white;
  for (var step = 1; step <= 20; step++) {
    final shaded = Color.lerp(background, towards, step / 20)!;
    if (statusPillContrast(foreground, shaded) >= statusPillMinContrast) {
      return (foreground, shaded);
    }
  }
  return (foreground, towards);
}

/// Shared visual treatment for native and terminal MonkeyMux status pills.
class MuxWindowStatusBadge extends StatelessWidget {
  /// Creates a compact status pill with explicit semantic colors.
  const MuxWindowStatusBadge({
    required this.semanticsLabel,
    required this.label,
    required this.icon,
    required this.foregroundColor,
    required this.backgroundColor,
    super.key,
  });

  /// Screen-reader label that includes the kind of mux window.
  final String semanticsLabel;

  /// Short visible status label.
  final String label;

  /// Status icon shown before [label].
  final IconData icon;

  /// High-contrast content color.
  final Color foregroundColor;

  /// Semantic container color, shaded if needed so [label] stays legible.
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (foreground, background) = legiblePillColors(
      foregroundColor,
      backgroundColor,
    );
    return Semantics(
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: statusPillIconSize(context), color: foreground),
              const SizedBox(width: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon size for a status pill: 12 px, growing with the user's text size so
/// the icon keeps pace with its label, up to twice that.
double statusPillIconSize(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(12).clamp(12, 24).toDouble();
