import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_session_state.dart' as session;
import '../../domain/models/acp_updates.dart';
import 'acp_chat_typography.dart';

/// A user-decision surface abstracting both the session-manager permission
/// requests and the client-capability service's pending permissions/writes.
sealed class AcpPermissionPrompt {
  const AcpPermissionPrompt();

  /// Reconnect-stable identifier used to key the surface and dedupe actions.
  String get stableKey;

  /// A short, content-free title.
  String get title;
}

/// A pending tool-call permission with the agent's exact selectable options.
final class AcpToolPermissionPrompt extends AcpPermissionPrompt {
  /// Creates a tool permission prompt.
  const AcpToolPermissionPrompt({
    required this.stableKey,
    required this.title,
    required this.options,
    required this.onSelect,
    required this.onCancel,
    this.contextLine,
  });

  @override
  final String stableKey;

  @override
  final String title;

  /// A short safe tool/path context line.
  final String? contextLine;

  /// The exact options offered by the agent.
  final List<AcpPermissionOption> options;

  /// Answers with an exact agent option id.
  final Future<void> Function(String optionId) onSelect;

  /// Cancels the request without selecting an option.
  final Future<void> Function() onCancel;
}

/// A pending file write awaiting explicit local approval.
///
/// Only content-free metadata (a file name and byte count) is surfaced by
/// default; the write body is revealed only on explicit request and is never
/// logged.
final class AcpWritePermissionPrompt extends AcpPermissionPrompt {
  /// Creates a write permission prompt.
  const AcpWritePermissionPrompt({
    required this.stableKey,
    required this.fileName,
    required this.contentBytes,
    required this.onApprove,
    required this.onReject,
    this.revealContent,
  });

  @override
  final String stableKey;

  /// Basename of the target path, shown as metadata only.
  final String fileName;

  /// Size of the write body in bytes.
  final int contentBytes;

  /// Approves and performs the write.
  final Future<void> Function() onApprove;

  /// Refuses the write.
  final Future<void> Function() onReject;

  /// Returns the write body for explicit, on-demand review only.
  final String Function()? revealContent;

  @override
  String get title => 'Write to $fileName';
}

/// Builds a tool permission prompt from a session-manager pending permission.
AcpToolPermissionPrompt acpToolPromptFromSession(
  session.AcpPendingPermission pending, {
  required Future<void> Function(String optionId) onSelect,
  required Future<void> Function() onCancel,
  String? toolTitle,
}) => AcpToolPermissionPrompt(
  stableKey: 'session:${pending.sessionId}:${pending.requestKey}',
  title: toolTitle == null ? 'Allow this tool action?' : 'Allow $toolTitle?',
  contextLine: toolTitle ?? 'Tool ${pending.toolCallId}',
  options: pending.options,
  onSelect: onSelect,
  onCancel: onCancel,
);

/// Renders pending [AcpPermissionPrompt]s as an anchored action surface.
///
/// Each prompt is keyed by its reconnect-stable key so it stays put across
/// reconnects, and once an action is started for a prompt the surface disables
/// that prompt's controls to prevent duplicate resolution.
class AcpPermissionSurface extends StatefulWidget {
  /// Creates a permission surface.
  const AcpPermissionSurface({required this.prompts, super.key});

  /// The prompts awaiting a decision.
  final List<AcpPermissionPrompt> prompts;

  @override
  State<AcpPermissionSurface> createState() => _AcpPermissionSurfaceState();
}

class _AcpPermissionSurfaceState extends State<AcpPermissionSurface> {
  final Set<String> _resolving = <String>{};

  Future<void> _resolve(String key, Future<void> Function() action) async {
    if (_resolving.contains(key)) {
      return;
    }
    setState(() => _resolving.add(key));
    try {
      await action();
      await HapticFeedback.selectionClick();
    } finally {
      if (mounted) {
        setState(() => _resolving.remove(key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.prompts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final prompt in widget.prompts)
          Padding(
            key: ValueKey(prompt.stableKey),
            padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
            child: _PermissionCard(
              prompt: prompt,
              busy: _resolving.contains(prompt.stableKey),
              onResolve: (action) => _resolve(prompt.stableKey, action),
            ),
          ),
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.prompt,
    required this.busy,
    required this.onResolve,
  });

  final AcpPermissionPrompt prompt;
  final bool busy;
  final void Function(Future<void> Function() action) onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: prompt.title,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: switch (prompt) {
            AcpToolPermissionPrompt() => _buildTool(
              context,
              prompt as AcpToolPermissionPrompt,
            ),
            AcpWritePermissionPrompt() => _buildWrite(
              context,
              prompt as AcpWritePermissionPrompt,
            ),
          },
        ),
      ),
    );
  }

  Widget _buildTool(BuildContext context, AcpToolPermissionPrompt prompt) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(prompt.title, style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        if (prompt.contextLine != null) ...[
          const SizedBox(height: FluttyTheme.spacingXs),
          Text(
            prompt.contextLine!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AcpChatTypography.monoStyleOf(
              context,
            ).copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
        const SizedBox(height: FluttyTheme.spacingSm),
        Wrap(
          spacing: FluttyTheme.spacingSm,
          runSpacing: FluttyTheme.spacingXs,
          children: [
            for (final option in prompt.options)
              _optionButton(
                context,
                option: option,
                onPressed: busy
                    ? null
                    : () => onResolve(() => prompt.onSelect(option.id)),
              ),
            TextButton(
              onPressed: busy ? null : () => onResolve(prompt.onCancel),
              child: const Text('Cancel request'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionButton(
    BuildContext context, {
    required AcpPermissionOption option,
    required VoidCallback? onPressed,
  }) {
    final label = Text(option.name.isEmpty ? option.id : option.name);
    if (option.kind == AcpPermissionOptionKind.allowOnce) {
      return FilledButton(onPressed: onPressed, child: label);
    }
    if (option.kind == AcpPermissionOptionKind.allowAlways) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.all_inclusive, size: 16),
        label: label,
      );
    }
    if (option.kind == AcpPermissionOptionKind.rejectOnce ||
        option.kind == AcpPermissionOptionKind.rejectAlways) {
      return TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        onPressed: onPressed,
        child: label,
      );
    }
    return OutlinedButton(onPressed: onPressed, child: label);
  }

  Widget _buildWrite(BuildContext context, AcpWritePermissionPrompt prompt) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.edit_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(prompt.title, style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: FluttyTheme.spacingXs),
          child: Text(
            '${prompt.contentBytes} bytes',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (prompt.revealContent != null)
          _WriteContentReview(reveal: prompt.revealContent!),
        const SizedBox(height: FluttyTheme.spacingSm),
        Wrap(
          spacing: FluttyTheme.spacingSm,
          runSpacing: FluttyTheme.spacingXs,
          children: [
            FilledButton(
              onPressed: busy ? null : () => onResolve(prompt.onApprove),
              child: const Text('Approve write'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: busy ? null : () => onResolve(prompt.onReject),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Reject write'),
            ),
          ],
        ),
      ],
    );
  }
}

/// An explicit, on-demand reveal of a pending write's body.
class _WriteContentReview extends StatefulWidget {
  const _WriteContentReview({required this.reveal});

  final String Function() reveal;

  @override
  State<_WriteContentReview> createState() => _WriteContentReviewState();
}

class _WriteContentReviewState extends State<_WriteContentReview> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_shown) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _shown = true),
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('Review changes'),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: FluttyTheme.spacingXs),
      constraints: const BoxConstraints(maxHeight: 180),
      width: double.infinity,
      padding: const EdgeInsets.all(FluttyTheme.spacingSm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          widget.reveal(),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}
