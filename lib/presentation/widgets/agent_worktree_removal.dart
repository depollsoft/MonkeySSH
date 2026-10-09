/// Offers to remove the git worktree a closed agent window ran in.
///
/// Removal is never automatic. A worktree with uncommitted changes is
/// refused with an explanation; a clean one is removed only after the user
/// confirms. Only worktrees MonkeySSH created for a preset launch are offered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_worktree.dart';
import '../../domain/services/agent_worktree_registry.dart';
import '../../domain/services/agent_worktree_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/ssh_service.dart';
import 'terminal_overlay_focus.dart';

/// Key of the confirm action in the removal dialog.
const agentWorktreeRemoveButtonKey = Key('agent-worktree-remove-button');

/// Key of the keep action in the removal dialog.
const agentWorktreeKeepButtonKey = Key('agent-worktree-keep-button');

/// Offers to remove the recorded worktree that [closedWindowDirectory] was
/// in, after its window closed on [session].
///
/// Nothing happens when the directory is not in a worktree MonkeySSH created,
/// or when another window in [remainingWindowDirectories] still uses it.
/// Never throws: closing the window has already succeeded.
Future<void> offerAgentWorktreeRemoval({
  required BuildContext context,
  required WidgetRef ref,
  required SshSession session,
  required String? closedWindowDirectory,
  Iterable<String?> remainingWindowDirectories = const [],
}) async {
  if (session.remoteIsWindows) {
    return;
  }
  final registry = ref.read(agentWorktreeRegistryProvider);
  final service = ref.read(agentWorktreeServiceProvider);
  try {
    await _offerRemoval(
      context: context,
      registry: registry,
      service: service,
      session: session,
      closedWindowDirectory: closedWindowDirectory,
      remainingWindowDirectories: remainingWindowDirectories,
    );
  } on Object catch (error) {
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'removal_offer_failed',
      fields: {'hostId': session.hostId, 'errorType': error.runtimeType},
    );
  }
}

Future<void> _offerRemoval({
  required BuildContext context,
  required AgentWorktreeRegistry registry,
  required AgentWorktreeService service,
  required SshSession session,
  required String? closedWindowDirectory,
  required Iterable<String?> remainingWindowDirectories,
}) async {
  final shell = SshAgentWorktreeShell(session);
  final record = await registry.findContaining(
    session.hostId,
    closedWindowDirectory,
  );
  if (record == null || remainingWindowDirectories.any(record.contains)) {
    return;
  }
  final AgentWorktreeStatus status;
  try {
    status = await service.status(shell, record);
  } on AgentWorktreeException catch (error) {
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'status_failed',
      fields: {'hostId': session.hostId, 'errorKind': error.kind.name},
    );
    return;
  }
  if (!status.exists) {
    await registry.remove(record);
    return;
  }
  if (!context.mounted) {
    return;
  }
  final remove = await showAgentWorktreeRemovalDialog(
    context: context,
    record: record,
    status: status,
  );
  DiagnosticsLogService.instance.info(
    'agent.worktree',
    'removal_offered',
    fields: {
      'hostId': session.hostId,
      'dirty': status.isDirty,
      'accepted': remove,
    },
  );
  if (!remove) {
    return;
  }
  String message;
  try {
    final removal = await service.remove(shell, record);
    await registry.remove(record);
    message = removal.branchDeleted
        ? 'Worktree and its unused branch removed.'
        : 'Worktree removed. Its branch keeps the commits.';
  } on AgentWorktreeException catch (error) {
    DiagnosticsLogService.instance.warning(
      'agent.worktree',
      'remove_failed',
      fields: {'hostId': session.hostId, 'errorKind': error.kind.name},
    );
    message = 'Worktree not removed. ${error.message}';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

/// Shows the removal dialog for [record] and returns whether to remove it.
///
/// A dirty worktree gets an explanation and no remove action.
Future<bool> showAgentWorktreeRemovalDialog({
  required BuildContext context,
  required AgentWorktreeRecord record,
  required AgentWorktreeStatus status,
}) async {
  final result = await showDialog<bool>(
    context: context,
    requestFocus: terminalOverlayRouteRequestFocus(context),
    builder: (context) =>
        _AgentWorktreeRemovalDialog(record: record, status: status),
  );
  return result ?? false;
}

class _AgentWorktreeRemovalDialog extends StatelessWidget {
  const _AgentWorktreeRemovalDialog({
    required this.record,
    required this.status,
  });

  final AgentWorktreeRecord record;
  final AgentWorktreeStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mono = FluttyTheme.monoStyle.copyWith(color: colorScheme.onSurface);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final dirty = status.isDirty;
    final changes = status.changedFiles;
    final ignored = status.ignoredEntries;

    return AlertDialog(
      icon: Icon(
        dirty ? Icons.warning_amber_rounded : Icons.account_tree_outlined,
        color: dirty ? colorScheme.error : colorScheme.onSurfaceVariant,
      ),
      title: Text(dirty ? 'Worktree kept' : 'Remove worktree?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              record.branch,
              style: mono.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              record.path,
              style: mono.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            if (dirty)
              Text(
                'It has $changes uncommitted '
                '${changes == 1 ? 'change' : 'changes'}, so MonkeySSH '
                'won’t remove it. Commit or discard them, then run '
                'git worktree remove in a terminal.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(
                'The agent’s window is closed. Removing deletes this folder.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              Text(
                status.branchHasNewCommits
                    ? 'The branch keeps its commits.'
                    : 'The branch has no new commits, so it is deleted too.',
                style: secondary,
              ),
              if (ignored > 0) ...[
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  '$ignored ignored ${ignored == 1 ? 'item' : 'items'}, '
                  'such as build output, will be deleted with it.',
                  style: secondary,
                ),
              ],
            ],
          ],
        ),
      ),
      actions: dirty
          ? [
              TextButton(
                key: agentWorktreeKeepButtonKey,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('OK'),
              ),
            ]
          : [
              TextButton(
                key: agentWorktreeKeepButtonKey,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              FilledButton(
                key: agentWorktreeRemoveButtonKey,
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove worktree'),
              ),
            ],
    );
  }
}
