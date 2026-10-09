/// The post-connect setup checklist: a one-line hint on a host row, a card for
/// empty states, and a sheet that lists every step and runs the next one
/// through the flow that already exists for it.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/host_setup_checklist_service.dart';
import '../../domain/services/local_notification_service.dart'
    show buildAgentChatLocation;
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/ssh_exec_queue.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/tmux_service.dart';
import '../providers/entity_list_providers.dart';
import '../providers/host_setup_checklist_providers.dart';
import '../screens/agent_management_screen.dart';
import 'acp_connection_support.dart'
    show confirmAcpMonkeyMuxInstall, ensureAcpHostConnection;
import 'acp_new_session_sheet.dart';
import 'key_install_sheet.dart';
import 'premium_access.dart';

/// Short, lower-case name of a step for the one-line hint.
String hostSetupStepShortLabel(HostSetupStep step) => switch (step) {
  HostSetupStep.keyLogin => 'switch to key login',
  HostSetupStep.monkeyMux => 'install MonkeyMux',
  HostSetupStep.agents => 'install an agent',
  HostSetupStep.agentSignIn => 'sign in to an agent',
};

/// Title of a step in the checklist sheet.
String hostSetupStepTitle(HostSetupStep step) => switch (step) {
  HostSetupStep.keyLogin => 'Key login',
  HostSetupStep.monkeyMux => 'MonkeyMux installed',
  HostSetupStep.agents => 'Coding agent detected',
  HostSetupStep.agentSignIn => 'Agent signed in',
};

/// What a missing step needs, shown under its title.
String hostSetupStepHint(HostSetupStep step) => switch (step) {
  HostSetupStep.keyLogin =>
    'This host still signs in with a saved password. Install a key and '
        'check it works on its own.',
  HostSetupStep.monkeyMux =>
    'MonkeyMux keeps agent sessions and windows alive across reconnects.',
  HostSetupStep.agents =>
    'No coding-agent CLI was found. Install one from Agent Management, or '
        'in the terminal yourself.',
  HostSetupStep.agentSignIn =>
    'Start a native agent chat. It walks you through the agent’s sign-in.',
};

/// Label of the button that runs a step.
String hostSetupStepActionLabel(HostSetupStep step) => switch (step) {
  HostSetupStep.keyLogin => 'Set Up Key Login',
  HostSetupStep.monkeyMux => 'Install MonkeyMux',
  HostSetupStep.agents => 'Open Agent Management (Pro)',
  HostSetupStep.agentSignIn => 'Start Agent Chat',
};

/// The checklist hint inside a host row. Renders nothing when the host has no
/// known next step, and probes the host while it is connected.
class HostSetupChecklistLine extends ConsumerWidget {
  /// Creates the hint for [host].
  const HostSetupChecklistLine({required this.host, super.key});

  /// Host the row shows.
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checklist = ref.watch(hostSetupChecklistProvider(host.id));
    if (checklist == null) return const SizedBox.shrink();
    _probeWhenConnected(ref, checklist);
    final next = checklist.nextStep;
    if (!checklist.isVisible || next == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final total = HostSetupStep.values.length;
    final mutedStyle = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: FluttyTheme.spacingXs),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label:
                  'Setup ${checklist.doneCount} of $total done. Next: '
                  '${hostSetupStepShortLabel(next)}',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
                onTap: () => showHostSetupChecklistSheet(context, host.id),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Icon(
                        Icons.checklist_rounded,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${checklist.doneCount}/$total · ',
                        style: mutedStyle,
                      ),
                      Flexible(
                        child: Text(
                          hostSetupStepShortLabel(next),
                          overflow: TextOverflow.ellipsis,
                          style: mutedStyle.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Hide setup checklist',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            iconSize: 18,
            color: colorScheme.onSurfaceVariant,
            onPressed: () => unawaited(
              ref
                  .read(hostSetupPersistedStateProvider.notifier)
                  .dismiss(host.id),
            ),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

void _probeWhenConnected(WidgetRef ref, HostSetupChecklist checklist) {
  if (!checklist.needsProbe) return;
  final connectionId = ref.watch(
    hostConnectedConnectionIdProvider(checklist.hostId),
  );
  if (connectionId == null) return;
  final notifier = ref.read(hostSetupProbeResultsProvider.notifier);
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(notifier.ensureProbed(checklist.hostId, connectionId)),
  );
}

/// An empty-state card that points at the next setup step for the most
/// recently connected host that still has one.
class HostSetupEmptyStateCard extends ConsumerWidget {
  /// Creates the card.
  const HostSetupEmptyStateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(allHostsProvider).asData?.value ?? const <Host>[];
    final candidates =
        hosts.where((host) => host.lastConnectedAt != null).toList()
          ..sort((a, b) => b.lastConnectedAt!.compareTo(a.lastConnectedAt!));
    for (final host in candidates.take(5)) {
      final checklist = ref.watch(hostSetupChecklistProvider(host.id));
      final next = checklist?.nextStep;
      if (checklist == null || !checklist.isVisible || next == null) continue;
      return _EmptyStateCard(host: host, checklist: checklist, next: next);
    }
    return const SizedBox.shrink();
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
    required this.host,
    required this.checklist,
    required this.next,
  });

  final Host host;
  final HostSetupChecklist checklist;
  final HostSetupStep next;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: FluttyTheme.spacingLg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusLg),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Finish setting up '),
                      TextSpan(
                        text: host.label,
                        style: FluttyTheme.displayMono(
                          fontSize: 16,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  'Next: ${hostSetupStepShortLabel(next)} (step '
                  '${checklist.doneCount + 1} of '
                  '${HostSetupStep.values.length}).',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingSm),
                OutlinedButton.icon(
                  onPressed: () =>
                      showHostSetupChecklistSheet(context, host.id),
                  icon: const Icon(Icons.checklist_rounded, size: 18),
                  label: const Text('Continue Setup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the checklist sheet for [hostId].
Future<void> showHostSetupChecklistSheet(BuildContext context, int hostId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => HostSetupChecklistSheet(hostId: hostId),
    );

/// Lists every step for one host and runs the next missing one.
class HostSetupChecklistSheet extends ConsumerStatefulWidget {
  /// Creates the sheet for [hostId].
  const HostSetupChecklistSheet({required this.hostId, super.key});

  /// Saved host ID.
  final int hostId;

  @override
  ConsumerState<HostSetupChecklistSheet> createState() =>
      _HostSetupChecklistSheetState();
}

class _HostSetupChecklistSheetState
    extends ConsumerState<HostSetupChecklistSheet> {
  var _running = false;

  @override
  void initState() {
    super.initState();
    // Pick up agent sessions started elsewhere since the list was read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(hostIdsWithAgentSessionsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final host = ref.watch(
      allHostsProvider.select(
        (hosts) => hosts.asData?.value.firstWhereOrNull(
          (host) => host.id == widget.hostId,
        ),
      ),
    );
    final checklist = ref.watch(hostSetupChecklistProvider(widget.hostId));
    if (host == null || checklist == null) {
      return const SizedBox(height: 120);
    }
    _probeWhenConnected(ref, checklist);
    final next = checklist.nextStep;
    final connected =
        ref.watch(hostConnectedConnectionIdProvider(widget.hostId)) != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        0,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Host Setup',
            style: FluttyTheme.displayMono(color: colorScheme.onSurface),
          ),
          const SizedBox(height: FluttyTheme.spacingXs),
          Text(
            '${host.label} · ${checklist.doneCount} of '
            '${HostSetupStep.values.length} done',
            style: FluttyTheme.monoStyle.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingMd),
          for (final step in HostSetupStep.values)
            _StepTile(
              step: step,
              status: checklist.statusOf(step),
              isNext: step == next,
              connected: connected,
            ),
          const SizedBox(height: FluttyTheme.spacingMd),
          if (next != null)
            FilledButton(
              onPressed: _running ? null : () => _run(host, next),
              child: Text(hostSetupStepActionLabel(next)),
            )
          else if (checklist.isComplete)
            Text(
              'All set. This host is ready for agents.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            )
          else
            Text(
              'Connect to this host to check the remaining steps.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          if (!checklist.dismissed && !checklist.isComplete) ...[
            const SizedBox(height: FluttyTheme.spacingSm),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
              onPressed: () {
                unawaited(
                  ref
                      .read(hostSetupPersistedStateProvider.notifier)
                      .dismiss(widget.hostId),
                );
                Navigator.of(context).pop();
              },
              child: const Text('Hide Checklist for This Host'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _run(Host host, HostSetupStep step) async {
    setState(() => _running = true);
    DiagnosticsLogService.instance.info(
      'onboarding.checklist',
      'step_started',
      fields: {'hostId': host.id, 'step': step.storageValue},
    );
    try {
      await runHostSetupStep(context, ref, host, step);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.step,
    required this.status,
    required this.isNext,
    required this.connected,
  });

  final HostSetupStep step;
  final HostSetupStepStatus status;
  final bool isNext;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (icon, color, label) = switch (status) {
      HostSetupStepStatus.done => (
        Icons.check_circle,
        colorScheme.onSurfaceVariant,
        'done',
      ),
      HostSetupStepStatus.missing => (
        isNext
            ? Icons.arrow_circle_right_outlined
            : Icons.radio_button_unchecked,
        colorScheme.onSurface,
        isNext ? 'next' : 'to do',
      ),
      HostSetupStepStatus.unknown => (
        Icons.help_outline,
        colorScheme.onSurfaceVariant,
        connected ? 'checking' : 'connect to check',
      ),
    };
    return Semantics(
      label: '${hostSetupStepTitle(step)}: $label',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hostSetupStepTitle(step),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: isNext ? FontWeight.w600 : null,
                    ),
                  ),
                  if (isNext)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        hostSetupStepHint(step),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            Text(
              label,
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Runs [step] for [host] through the flow the app already has for it.
Future<void> runHostSetupStep(
  BuildContext context,
  WidgetRef ref,
  Host host,
  HostSetupStep step,
) async {
  switch (step) {
    case HostSetupStep.keyLogin:
      await showKeyInstallSheet(context, host);
    case HostSetupStep.monkeyMux:
      await _installMonkeyMux(context, ref, host);
    case HostSetupStep.agents:
      await _openAgentManagement(context, ref, host);
    case HostSetupStep.agentSignIn:
      await _startAgentChat(context, ref, host);
  }
}

Future<SshSession?> _connectedSession(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final connection = await ensureAcpHostConnection(
    context,
    ref,
    host.id,
    knownHost: host,
  );
  final connectionId = connection.connectionId;
  if (!connection.success || connectionId == null) {
    if (context.mounted && !connection.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(connection.error ?? 'Couldn’t connect to this host.'),
        ),
      );
    }
    return null;
  }
  return ref.read(sshServiceProvider).getSession(connectionId);
}

Future<void> _installMonkeyMux(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final session = await _connectedSession(context, ref, host);
  if (session == null || !context.mounted) return;
  final installer = ref.read(monkeyMuxInstallerServiceProvider);
  final store = ref.read(hostSetupPersistedStateProvider.notifier);
  final probes = ref.read(hostSetupProbeResultsProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  NavigatorState? progressNavigator;
  var progressOpen = false;
  try {
    await installer.ensureInstalled(
      session,
      priority: SshExecPriority.normal,
      confirmInstall: (request) async {
        if (!context.mounted) return false;
        final confirmed = await confirmAcpMonkeyMuxInstall(context, request);
        if (confirmed && context.mounted) {
          progressNavigator = Navigator.of(context, rootNavigator: true);
          progressOpen = true;
          unawaited(
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _MonkeyMuxUploadDialog(
                installer: installer,
                connectionId: session.connectionId,
              ),
            ).whenComplete(() => progressOpen = false),
          );
        }
        return confirmed;
      },
    );
    await store.markDone(host.id, {HostSetupStep.monkeyMux});
    probes.forget(host.id);
    messenger.showSnackBar(
      const SnackBar(content: Text('MonkeyMux is installed on this host.')),
    );
  } on MonkeyMuxInstallDeclinedException {
    // The user chose "Not now".
  } on MonkeyMuxInstallException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } finally {
    if (progressOpen) progressNavigator?.pop();
  }
}

class _MonkeyMuxUploadDialog extends StatelessWidget {
  const _MonkeyMuxUploadDialog({
    required this.installer,
    required this.connectionId,
  });

  final MonkeyMuxInstallerService installer;
  final int connectionId;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<int, MonkeyMuxInstallProgress>>(
        valueListenable: installer.uploadProgress,
        builder: (context, progress, _) {
          final current = progress[connectionId];
          final fraction = current == null || current.totalBytes == 0
              ? null
              : current.uploadedBytes / current.totalBytes;
          return AlertDialog(
            title: const Text('Installing MonkeyMux'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: fraction),
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  fraction == null
                      ? 'Uploading…'
                      : 'Uploading ${(fraction * 100).round()}%',
                  style: FluttyTheme.monoStyle,
                ),
              ],
            ),
          );
        },
      );
}

Future<void> _openAgentManagement(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  if (!await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.agentManagement,
      ) ||
      !context.mounted) {
    return;
  }
  final session = await _connectedSession(context, ref, host);
  if (session == null || !context.mounted) return;
  final tmuxService = ref.read(tmuxServiceProvider);
  final probes = ref.read(hostSetupProbeResultsProvider.notifier);
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => AgentManagementScreen(
        session: session,
        onProvidersRefreshed: () =>
            tmuxService.invalidateInstalledAgentTools(session.connectionId),
      ),
    ),
  );
  tmuxService.invalidateInstalledAgentTools(session.connectionId);
  probes.forget(host.id);
}

Future<void> _startAgentChat(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final store = ref.read(hostSetupPersistedStateProvider.notifier);
  final router = GoRouter.of(context);
  final key = await showAcpNewSessionSheet(
    context,
    initialHostId: host.id,
    lockHost: true,
  );
  if (key == null) return;
  await store.markDone(host.id, {HostSetupStep.agentSignIn});
  ref.invalidate(hostIdsWithAgentSessionsProvider);
  if (context.mounted) await Navigator.of(context).maybePop();
  unawaited(
    router.push<void>(
      buildAgentChatLocation(
        hostId: key.host.hostId,
        providerId: key.provider.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
      ),
    ),
  );
}
