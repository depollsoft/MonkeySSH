import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_updates.dart';

/// A floating autocomplete list of ACP slash commands.
///
/// The picker is a pure function of [commands] and [highlightedIndex]; the
/// hosting composer owns keyboard navigation and updates the highlight, while
/// rows remain independently tappable for touch. It renders above the composer
/// field as its own floating surface (never a nested card) and bounds its own
/// height so a large, dynamically-reloaded command set stays scrollable.
class AcpSlashCommandPicker extends StatelessWidget {
  /// Creates a slash-command picker.
  const AcpSlashCommandPicker({
    required this.commands,
    required this.highlightedIndex,
    required this.onSelected,
    super.key,
    this.onHighlightChanged,
  });

  /// The ranked commands to display.
  final List<AcpAvailableCommand> commands;

  /// The index of the keyboard-highlighted command, or `-1` for none.
  final int highlightedIndex;

  /// Called when a command is chosen by touch or pointer.
  final ValueChanged<AcpAvailableCommand> onSelected;

  /// Called when a row is hovered, to sync the keyboard highlight.
  final ValueChanged<int>? onHighlightChanged;

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      label: 'Slash command suggestions',
      child: Material(
        color: scheme.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
              padding: const EdgeInsets.symmetric(
                vertical: FluttyTheme.spacingXs,
              ),
              itemCount: commands.length,
              itemBuilder: (context, index) {
                final command = commands[index];
                final highlighted = index == highlightedIndex;
                return _SlashCommandRow(
                  command: command,
                  highlighted: highlighted,
                  onTap: () => onSelected(command),
                  onHover: () => onHighlightChanged?.call(index),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SlashCommandRow extends StatelessWidget {
  const _SlashCommandRow({
    required this.command,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final AcpAvailableCommand command;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = command.input?.hint;
    return Semantics(
      button: true,
      selected: highlighted,
      label: '/${command.name}',
      hint: command.description.isEmpty ? null : command.description,
      child: InkWell(
        onTap: onTap,
        onHover: (hovering) {
          if (hovering) {
            onHover();
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          color: highlighted ? scheme.primary.withValues(alpha: 0.14) : null,
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingMd,
            vertical: FluttyTheme.spacingSm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '/${command.name}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                          if (hint != null && hint.isNotEmpty)
                            TextSpan(
                              text: ' $hint',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (command.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: FluttyTheme.spacingXs / 2,
                        ),
                        child: Text(
                          command.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
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
}
