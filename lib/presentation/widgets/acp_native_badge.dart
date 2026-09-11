import 'package:flutter/material.dart';

/// Places the compact native identity badge over an agent icon.
class AcpNativeBadgeOverlay extends StatelessWidget {
  /// Creates an overlaid native badge matching the MonkeyMux handle treatment.
  const AcpNativeBadgeOverlay({
    required this.child,
    required this.color,
    required this.badgeKey,
    this.size = 17,
    super.key,
  });

  /// Agent icon receiving the native badge.
  final Widget child;

  /// Agent accent shared with the underlying terminal/native tool icon.
  final Color color;

  /// Stable key for the overlaid badge.
  final Key badgeKey;

  /// Square icon slot dimension.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        child,
        Positioned(
          right: -3,
          bottom: -3,
          child: AcpNativeBadge(key: badgeKey, color: color),
        ),
      ],
    ),
  );
}

/// Compact identity badge distinguishing native ACP windows from terminals.
class AcpNativeBadge extends StatelessWidget {
  /// Creates a native-agent identity badge using [color] for its accent.
  const AcpNativeBadge({required this.color, this.size = 12, super.key});

  /// Accent shared by the same agent in terminal and native modes.
  final Color color;

  /// Square badge dimension.
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Native agent',
    child: Semantics(
      label: 'Native agent',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Icon(Icons.chat_bubble, size: size * 0.62, color: color),
        ),
      ),
    ),
  );
}
