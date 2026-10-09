import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/remote_multiplexer.dart';
import 'acp_elicitation_sheet_parts.dart';

/// What a launch-preset link would run, shown before anything starts.
@immutable
class AppLinkPresetReview {
  /// Creates a preset review.
  const AppLinkPresetReview({
    required this.hostLabel,
    required this.tool,
    required this.command,
    required this.yoloMode,
    this.yoloSwitches = const [],
    this.muxSessionName,
    this.muxBackend,
  });

  /// Saved host label, as the user named it.
  final String hostLabel;

  /// Agent CLI the preset starts.
  final AgentLaunchTool tool;

  /// The exact command the preset runs, YOLO flags included.
  final String command;

  /// Whether the preset starts the agent without approval prompts.
  final bool yoloMode;

  /// Remote window session the agent starts in, if the preset uses one.
  final String? muxSessionName;

  /// Backend for [muxSessionName].
  final RemoteMuxBackend? muxBackend;

  /// The parts of [command] that turn YOLO mode on, as they appear there.
  final List<String> yoloSwitches;
}

/// Shows the review sheet for a launch-preset link.
///
/// Resolves to `true` only when the user explicitly chooses Run. Dismissing
/// the sheet any other way, including the app locking underneath it,
/// resolves to `false`.
Future<bool> showAppLinkPresetSheet(
  BuildContext context,
  AppLinkPresetReview review,
) async {
  final launched = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) => AppLinkPresetSheet(review: review),
  );
  return launched ?? false;
}

/// Body of the launch-preset review sheet.
class AppLinkPresetSheet extends StatelessWidget {
  /// Creates the sheet body.
  const AppLinkPresetSheet({required this.review, super.key});

  /// What the link would run.
  final AppLinkPresetReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muxSessionName = review.muxSessionName;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
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
                        'Run launch preset?',
                        style: FluttyTheme.displayMono(
                          fontSize: 18,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingLg,
                FluttyTheme.spacingXs,
                FluttyTheme.spacingLg,
                FluttyTheme.spacingMd,
              ),
              children: [
                const AcpElicitationNotice(
                  icon: Icons.link,
                  text:
                      'A link asked to start this preset. Nothing runs until '
                      'you confirm.',
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                _ReviewField(label: 'host', value: review.hostLabel),
                _ReviewField(label: 'agent', value: review.tool.label),
                if (muxSessionName != null)
                  _ReviewField(
                    label: 'session',
                    value: switch (review.muxBackend) {
                      final backend? when backend != RemoteMuxBackend.auto =>
                        '$muxSessionName (${backend.label})',
                      _ => muxSessionName,
                    },
                  ),
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  'command',
                  style: FluttyTheme.monoStyle.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingXs),
                _CommandPanel(command: review.command),
                if (review.yoloMode) ...[
                  const SizedBox(height: FluttyTheme.spacingMd),
                  _YoloWarning(review: review),
                ],
                if (muxSessionName != null &&
                    review.muxBackend == RemoteMuxBackend.tmux) ...[
                  const SizedBox(height: FluttyTheme.spacingMd),
                  AcpElicitationNotice(
                    icon: Icons.info_outline,
                    text:
                        'If tmux session $muxSessionName is already running, '
                        'tmux attaches to it and does not start '
                        '${review.tool.label} again.',
                  ),
                ],
              ],
            ),
          ),
          _SheetActions(
            // Neutral, so the confirm action is the sheet's only teal.
            cancel: TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            run: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: Text(review.yoloMode ? 'Run in YOLO mode' : 'Run'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-anchored actions behind a hairline. They sit side by side and
/// stack, Run on top, when large text or a narrow window leaves no room.
class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.cancel, required this.run});

  final Widget cancel;
  final Widget run;

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
        child: OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          overflowDirection: VerticalDirection.up,
          overflowSpacing: FluttyTheme.spacingSm,
          children: [cancel, run],
        ),
      ),
    ),
  );
}

class _ReviewField extends StatelessWidget {
  const _ReviewField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                label,
                style: FluttyTheme.monoStyle.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: FluttyTheme.displayMono(
                  fontSize: 15,
                  color: scheme.onSurface,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The exact command, selectable and set in mono so every flag can be read.
class _CommandPanel extends StatelessWidget {
  const _CommandPanel({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(FluttyTheme.spacingSm + 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: SelectableText(
        command,
        key: const ValueKey<String>('app-link-preset-command'),
        style: FluttyTheme.monoStyle.copyWith(color: scheme.onSurface),
      ),
    );
  }
}

/// YOLO callout: an icon and words, never color alone.
class _YoloWarning extends StatelessWidget {
  const _YoloWarning({required this.review});

  final AppLinkPresetReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final switches = review.yoloSwitches.join(' ');
    return Container(
      key: const ValueKey<String>('app-link-preset-yolo'),
      padding: const EdgeInsets.all(FluttyTheme.spacingSm + 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        border: Border.all(color: scheme.tertiary),
      ),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: scheme.tertiary),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'YOLO mode is on',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${review.tool.label} will run commands and edit files '
                    'without asking first.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  if (switches.isNotEmpty) ...[
                    const SizedBox(height: FluttyTheme.spacingXs),
                    Text(
                      switches,
                      style: FluttyTheme.monoStyle.copyWith(
                        color: scheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
