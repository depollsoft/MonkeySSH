import 'package:flutter/material.dart';

import '../../domain/models/terminal_theme.dart';

/// A visual preview card showing a terminal theme.
///
/// Displays the theme name, category badge, and a mini terminal mockup
/// with the theme's colors.
class ThemePreviewCard extends StatelessWidget {
  /// Creates a new [ThemePreviewCard].
  const ThemePreviewCard({
    required this.theme,
    required this.isSelected,
    required this.onTap,
    this.trailingIcon,
    this.onLongPress,
    super.key,
  });

  /// The theme to display.
  final TerminalThemeData theme;

  /// Whether this theme is currently selected.
  final bool isSelected;

  /// Called when the card is tapped.
  final VoidCallback onTap;

  /// Optional trailing icon shown in the card footer.
  final IconData? trailingIcon;

  /// Called when the card is long-pressed (for custom themes).
  final VoidCallback? onLongPress;

  TextStyle _getPreviewFontStyle({double fontSize = 8, Color? color}) {
    final baseStyle = TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: fontSize,
    );
    return color != null ? baseStyle.copyWith(color: color) : baseStyle;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outline,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: colorScheme.primary.withAlpha(40),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Mini terminal preview
              Expanded(
                child: Container(
                  color: theme.background,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Prompt line
                      _buildPromptLine(),
                      const SizedBox(height: 2),
                      // Sample output
                      _buildSampleLine('ls -la', theme.foreground),
                      const SizedBox(height: 2),
                      _buildColorSwatches(),
                    ],
                  ),
                ),
              ),
              // Theme name footer
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  border: Border(top: BorderSide(color: colorScheme.outline)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        theme.name,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailingIcon != null || theme.isCustom)
                      Icon(
                        trailingIcon ?? Icons.download_done_outlined,
                        size: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    if (isSelected)
                      Icon(
                        Icons.check_circle,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPromptLine() => Row(
    children: [
      Text('user@host', style: _getPreviewFontStyle(color: theme.green)),
      Text(':', style: _getPreviewFontStyle(color: theme.foreground)),
      Text('~', style: _getPreviewFontStyle(color: theme.blue)),
      Text(r'$', style: _getPreviewFontStyle(color: theme.foreground)),
    ],
  );

  Widget _buildSampleLine(String text, Color color) =>
      Text(text, style: _getPreviewFontStyle(color: color));

  Widget _buildColorSwatches() => Row(
    children: [
      _colorDot(theme.red),
      _colorDot(theme.green),
      _colorDot(theme.yellow),
      _colorDot(theme.blue),
      _colorDot(theme.magenta),
      _colorDot(theme.cyan),
    ],
  );

  Widget _colorDot(Color color) => Container(
    width: 8,
    height: 8,
    margin: const EdgeInsets.only(right: 3),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
