import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_runtime_info.dart';
import '../../domain/models/agent_usage.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/ssh_service.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/agent_usage_summary.dart';
import '../widgets/premium_access.dart';

const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);

/// Manages coding-agent CLIs and ACP adapters on an active remote host.
class AgentManagementScreen extends ConsumerStatefulWidget {
  /// Creates the management screen for [session].
  const AgentManagementScreen({
    required this.session,
    this.service,
    this.onProvidersRefreshed,
    this.onRuntimesRefreshed,
    super.key,
  });

  /// Active remote SSH session.
  final SshSession session;

  /// Optional service override used by tests and embedded callers.
  final AgentManagementService? service;

  /// Called after remote probes invalidate and refresh provider discovery.
  final VoidCallback? onProvidersRefreshed;

  /// Publishes the latest runtime state for an existing update notice.
  final ValueChanged<List<AgentRuntimeInfo>>? onRuntimesRefreshed;

  @override
  ConsumerState<AgentManagementScreen> createState() =>
      _AgentManagementScreenState();
}

class _AgentManagementScreenState extends ConsumerState<AgentManagementScreen> {
  late List<AgentRuntimeInfo> _runtimes;
  final Set<String> _runningActions = <String>{};
  final Map<String, String> _actionOutput = <String, String>{};
  bool _refreshing = false;
  bool _checkingUsage = false;
  int _usageGeneration = 0;
  Map<String, AgentUsage> _usage = {};
  Timer? _usageClock;
  bool _updatingAll = false;
  String? _refreshError;
  final Set<String> _queuedActions = <String>{};
  final Set<String> _recheckingActions = <String>{};
  int _completedUpdates = 0;
  int _totalUpdates = 0;

  bool get _busy => _updatingAll || _runningActions.isNotEmpty;

  AgentManagementService get _service =>
      widget.service ?? ref.read(agentManagementServiceProvider);

  @override
  void initState() {
    super.initState();
    _runtimes = [
      for (final definition in agentRuntimeDefinitions)
        AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.checking,
        ),
    ];
    _usageClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _usage.isNotEmpty) setState(() {});
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _usageClock?.cancel();
    super.dispose();
  }

  Future<void> _refreshUsage() async {
    final generation = ++_usageGeneration;
    setState(() => _checkingUsage = true);
    try {
      final usage = await _service.readUsage(widget.session, _runtimes);
      if (!mounted || generation != _usageGeneration) return;
      setState(() => _usage = usage);
    } on Object {
      if (!mounted || generation != _usageGeneration) return;
      setState(
        () => _usage = {
          for (final runtime in _runtimes)
            runtime.definition.id: const AgentUsage(
              status: AgentUsageStatus.unavailable,
            ),
        },
      );
    } finally {
      if (mounted && generation == _usageGeneration) {
        setState(() => _checkingUsage = false);
      }
    }
  }

  Future<bool> _canManageAgents() => ref
      .read(monetizationServiceProvider)
      .canUseFeature(MonetizationFeature.agentManagement);

  Future<void> _refresh({bool afterAction = false}) async {
    if (!await _canManageAgents() || !mounted) return;
    if (_refreshing || (_busy && !afterAction)) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      var usageStarted = false;
      final runtimes = await _service.refreshAll(
        widget.session,
        onDiscovered: (discovered) {
          if (!mounted) return;
          setState(() => _runtimes = discovered);
          usageStarted = true;
          unawaited(_refreshUsage());
        },
      );
      if (!mounted) return;
      setState(() => _runtimes = runtimes);
      widget.onRuntimesRefreshed?.call(runtimes);
      widget.onProvidersRefreshed?.call();
      if (!usageStarted) unawaited(_refreshUsage());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _refreshError = error.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _updateAll() async {
    if (!await _canManageAgents() || !mounted) return;
    final updates = _runtimes
        .where(
          (runtime) => runtime.hasUpdate && runtime.managedByPackageManager,
        )
        .toList(growable: false);
    if (updates.isEmpty || _busy || _refreshing) return;

    setState(() {
      _updatingAll = true;
      _completedUpdates = 0;
      _totalUpdates = updates.length;
      for (final runtime in updates) {
        _queuedActions.add(runtime.definition.id);
        _actionOutput[runtime.definition.id] = '';
      }
    });
    final failures = <String>[];
    try {
      for (final runtime in updates) {
        if (!mounted || !await _canManageAgents() || !mounted) break;
        final result = await _executeAction(runtime, refreshAfterAction: false);
        if (!result.succeeded) failures.add(runtime.definition.label);
        if (mounted) setState(() => _completedUpdates++);
      }
    } finally {
      if (mounted) {
        try {
          await _refresh(afterAction: true);
        } finally {
          if (mounted) {
            setState(() {
              _updatingAll = false;
              _queuedActions.clear();
            });
          }
        }
      }
    }
    if (!mounted || failures.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const Text('Some updates failed'),
        content: Text('Could not update ${failures.join(', ')}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(AgentRuntimeInfo runtime) async {
    if (!await _canManageAgents() || !mounted) return;
    if (_busy || _refreshing) return;
    final result = await _executeAction(runtime);
    if (!mounted) return;
    if (!result.succeeded) await _showActionResult(runtime, result);
  }

  Future<AgentRuntimeActionResult> _executeAction(
    AgentRuntimeInfo runtime, {
    bool refreshAfterAction = true,
  }) async {
    final id = runtime.definition.id;
    final update = runtime.status == AgentRuntimeStatus.updateAvailable;
    setState(() {
      _queuedActions.remove(id);
      _runningActions.add(id);
      _actionOutput[id] = '';
    });

    late final AgentRuntimeActionResult result;
    try {
      result = await _service.installOrUpdate(
        widget.session,
        runtime.definition,
        update: update,
        current: runtime,
        onOutput: (chunk) {
          if (!mounted) return;
          setState(() {
            final combined = '${_actionOutput[id] ?? ''}$chunk';
            _actionOutput[id] = combined.length <= 1200
                ? combined
                : combined.substring(combined.length - 1200);
          });
        },
      );
    } on Object catch (error) {
      result = AgentRuntimeActionResult(
        succeeded: false,
        output: 'The remote command could not be completed. $error',
      );
    } finally {
      if (mounted) {
        if (refreshAfterAction) await _refresh(afterAction: true);
        if (mounted) setState(() => _runningActions.remove(id));
      }
    }
    return result;
  }

  Future<void> _recheck(AgentRuntimeInfo runtime) async {
    if (!await _canManageAgents() || !mounted || _busy || _refreshing) return;
    final id = runtime.definition.id;
    setState(() {
      _runningActions.add(id);
      _recheckingActions.add(id);
      _actionOutput[id] = '';
    });
    try {
      final updated = await _service.inspect(
        widget.session,
        runtime.definition,
      );
      if (!mounted) return;
      if (updated.status == AgentRuntimeStatus.failed) {
        await _showActionResult(
          runtime,
          AgentRuntimeActionResult(
            succeeded: false,
            output:
                'Could not check this agent. ${updated.message ?? 'The probe failed.'}',
          ),
        );
        return;
      }
      setState(() {
        final index = _runtimes.indexWhere(
          (entry) => entry.definition.id == id,
        );
        if (index >= 0) _runtimes[index] = updated;
      });
      widget.onRuntimesRefreshed?.call(_runtimes);
      widget.onProvidersRefreshed?.call();
      unawaited(_refreshUsage());
    } on Object catch (error) {
      if (!mounted) return;
      await _showActionResult(
        runtime,
        AgentRuntimeActionResult(
          succeeded: false,
          output: 'Could not check this agent. $error',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _runningActions.remove(id);
          _recheckingActions.remove(id);
        });
      }
    }
  }

  Future<void> _showActionResult(
    AgentRuntimeInfo runtime,
    AgentRuntimeActionResult result,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        result.succeeded ? Icons.check_circle_outline : Icons.error_outline,
        color: result.succeeded
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(
        result.succeeded
            ? '${runtime.definition.label} ready'
            : '${runtime.definition.label} failed',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            result.output.isEmpty
                ? result.succeeded
                      ? 'The remote command completed successfully.'
                      : 'The remote command did not return output.'
                : result.output,
            style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final access =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    if (!access.allowsFeature(MonetizationFeature.agentManagement)) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Agent Management', style: FluttyTheme.displayMono()),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Agent Management requires Pro',
                      textAlign: TextAlign.center,
                      style: FluttyTheme.displayMono(fontSize: 18),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Install, repair, and update coding agents on your remote hosts.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () async {
                        if (await requireMonetizationFeatureAccess(
                              context: context,
                              ref: ref,
                              feature: MonetizationFeature.agentManagement,
                            ) &&
                            mounted) {
                          await _refresh();
                        }
                      },
                      child: const Text('Unlock Pro'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final updates = _runtimes.where((runtime) => runtime.hasUpdate).toList();
    final managedUpdates = updates
        .where((runtime) => runtime.managedByPackageManager)
        .length;
    final initiallyChecking =
        _runtimes.isNotEmpty &&
        _runtimes.every(
          (runtime) => runtime.status == AgentRuntimeStatus.checking,
        );
    Widget section(AgentRuntimeKind kind, String title, String subtitle) =>
        _RuntimeSection(
          title: title,
          subtitle: subtitle,
          runtimes: _runtimes
              .where((runtime) => runtime.definition.kind == kind)
              .toList(),
          runningActions: _runningActions,
          queuedActions: _queuedActions,
          recheckingActions: _recheckingActions,
          actionOutput: _actionOutput,
          usage: _usage,
          checkingUsage: _checkingUsage,
          locked: _busy || _refreshing,
          onAction: _runAction,
          onRecheck: _recheck,
        );
    final cliSection = section(
      AgentRuntimeKind.cli,
      'agent CLIs',
      'Launch and resume tools available on this host',
    );
    final acpSection = section(
      AgentRuntimeKind.acpAdapter,
      'ACP adapters',
      'Providers available to native agent windows',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Agent Management', style: FluttyTheme.displayMono()),
        actions: [
          IconButton(
            key: const ValueKey('agent-management-refresh'),
            tooltip: 'Refresh agents',
            onPressed: _refreshing || _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _refreshing
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    semanticsLabel: 'Checking agent versions',
                  )
                : null,
          ),
        ),
      ),
      bottomNavigationBar: updates.isNotEmpty || _updatingAll
          ? _UpdateBar(
              label: _updatingAll
                  ? 'Updating ${_completedUpdates + 1 > _totalUpdates ? _totalUpdates : _completedUpdates + 1} of $_totalUpdates'
                  : '${updates.length} ${updates.length == 1 ? 'update' : 'updates'} available',
              busy: _updatingAll,
              managedCount: managedUpdates,
              manualCount: updates.length - managedUpdates,
              onUpdate: _busy || _refreshing ? null : _updateAll,
            )
          : null,
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 760 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 19;
              final padding = constraints.maxWidth > 1200
                  ? (constraints.maxWidth - 1152) / 2
                  : constraints.maxWidth >= 700
                  ? 24.0
                  : 16.0;
              return ListView(
                key: const ValueKey('agent-management-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(padding, 16, padding, 24),
                children: [
                  if (_refreshError != null)
                    _ErrorBanner(
                      message: _refreshError!,
                      onRetry: _refreshing || _busy ? null : _refresh,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Semantics(
                        key: const ValueKey('agent-usage-announcement'),
                        liveRegion: true,
                        label: _checkingUsage
                            ? 'Checking account usage.'
                            : _usage.isNotEmpty
                            ? 'Account usage checks complete. Review each agent for results.'
                            : null,
                        child: Row(
                          children: [
                            Icon(
                              initiallyChecking
                                  ? Icons.sync_rounded
                                  : Icons.dns_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                initiallyChecking
                                    ? 'Checking installed agents…'
                                    : _refreshing
                                    ? 'Refreshing versions…'
                                    : 'Installed versions and account usage',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_runtimes.isEmpty && !_refreshing)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        'No agent information returned. Refresh to try again.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  else if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: constraints.maxWidth >= 1000 ? 3 : 1,
                          child: cliSection,
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          flex: constraints.maxWidth >= 1000 ? 2 : 1,
                          child: acpSection,
                        ),
                      ],
                    )
                  else ...[
                    cliSection,
                    const SizedBox(height: 24),
                    acpSection,
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _UpdateBar extends StatelessWidget {
  const _UpdateBar({
    required this.label,
    required this.busy,
    required this.onUpdate,
    required this.managedCount,
    required this.manualCount,
  });
  final int managedCount;
  final int manualCount;
  final String label;
  final bool busy;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            MediaQuery.sizeOf(context).width > 1200
                ? (MediaQuery.sizeOf(context).width - 1152) / 2
                : MediaQuery.sizeOf(context).width >= 700
                ? 24
                : 16,
            12,
            MediaQuery.sizeOf(context).width > 1200
                ? (MediaQuery.sizeOf(context).width - 1152) / 2
                : MediaQuery.sizeOf(context).width >= 700
                ? 24
                : 16,
            12,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final status = Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: FluttyTheme.displayMono(
                        fontSize: 13,
                        letterSpacing: 0,
                      ),
                    ),
                    if (manualCount > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$manualCount ${manualCount == 1 ? 'requires' : 'require'} a manual update on the host.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              );
              final button = FilledButton(
                key: const ValueKey('agent-update-all'),
                onPressed: onUpdate,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                child: Text(
                  busy
                      ? 'Updating…'
                      : manualCount > 0
                      ? 'Update $managedCount'
                      : 'Update all',
                ),
              );
              if (!busy && managedCount == 0) return status;
              if (constraints.maxWidth < 350 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [status, const SizedBox(height: 12), button],
                );
              }
              return Row(
                children: [
                  Expanded(child: status),
                  const SizedBox(width: 16),
                  button,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RuntimeSection extends StatelessWidget {
  const _RuntimeSection({
    required this.title,
    required this.subtitle,
    required this.runtimes,
    required this.runningActions,
    required this.queuedActions,
    required this.recheckingActions,
    required this.actionOutput,
    required this.usage,
    required this.checkingUsage,
    required this.locked,
    required this.onAction,
    required this.onRecheck,
  });
  final String title;
  final String subtitle;
  final List<AgentRuntimeInfo> runtimes;
  final Set<String> runningActions;
  final Set<String> queuedActions;
  final Set<String> recheckingActions;
  final Map<String, String> actionOutput;
  final Map<String, AgentUsage> usage;
  final bool checkingUsage;
  final bool locked;
  final ValueChanged<AgentRuntimeInfo> onAction;
  final ValueChanged<AgentRuntimeInfo> onRecheck;

  @override
  Widget build(BuildContext context) {
    if (runtimes.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: FluttyTheme.displayMono(fontSize: 15),
                    ),
                  ),
                  Text(
                    '${runtimes.length}',
                    style: FluttyTheme.monoStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Material(
          color: scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              for (var index = 0; index < runtimes.length; index++) ...[
                _RuntimeRow(
                  key: ValueKey(runtimes[index].definition.id),
                  runtime: runtimes[index],
                  usage: usage[runtimes[index].definition.id],
                  checkingUsage: checkingUsage,
                  busy: runningActions.contains(runtimes[index].definition.id),
                  queued: queuedActions.contains(runtimes[index].definition.id),
                  rechecking: recheckingActions.contains(
                    runtimes[index].definition.id,
                  ),
                  locked: locked,
                  actionOutput: actionOutput[runtimes[index].definition.id],
                  onAction: () => onAction(runtimes[index]),
                  onRecheck: () => onRecheck(runtimes[index]),
                ),
                if (index != runtimes.length - 1)
                  Divider(
                    height: 1,
                    indent: 12,
                    endIndent: 12,
                    color: scheme.outlineVariant,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RuntimeRow extends StatefulWidget {
  const _RuntimeRow({
    required this.runtime,
    required this.busy,
    required this.queued,
    required this.rechecking,
    required this.locked,
    required this.actionOutput,
    required this.usage,
    required this.checkingUsage,
    required this.onAction,
    required this.onRecheck,
    super.key,
  });
  final AgentRuntimeInfo runtime;
  final bool busy;
  final bool queued;
  final bool rechecking;
  final bool locked;
  final String? actionOutput;
  final AgentUsage? usage;
  final bool checkingUsage;
  final VoidCallback onAction;
  final VoidCallback onRecheck;

  @override
  State<_RuntimeRow> createState() => _RuntimeRowState();
}

class _RuntimeRowState extends State<_RuntimeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final scheme = Theme.of(context).colorScheme;
    final status = widget.queued
        ? _StatusPresentation(
            'Queued',
            Icons.schedule_rounded,
            scheme.onSurfaceVariant,
          )
        : widget.busy
        ? _StatusPresentation(
            widget.rechecking
                ? 'Checking…'
                : runtime.hasUpdate
                ? 'Updating…'
                : runtime.status == AgentRuntimeStatus.needsRepair
                ? 'Repairing…'
                : 'Installing…',
            Icons.sync_rounded,
            scheme.onSurfaceVariant,
          )
        : _statusPresentation(runtime, scheme);
    final repair =
        runtime.status == AgentRuntimeStatus.needsRepair &&
        runtime.definition.supportsManagedInstall;
    final canInstall =
        repair ||
        (runtime.status == AgentRuntimeStatus.notInstalled
            ? runtime.definition.supportsManagedInstall
            : runtime.hasUpdate && runtime.managedByPackageManager);
    final label = runtime.hasUpdate
        ? 'Update'
        : repair
        ? 'Repair'
        : 'Install';
    final Widget action;
    if (widget.busy) {
      action = SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: '${runtime.definition.label}: ${status.label}',
            ),
          ),
        ),
      );
    } else if (widget.queued) {
      action = const SizedBox(width: 48);
    } else if (canInstall) {
      action = Semantics(
        label: '$label ${runtime.definition.label}',
        button: true,
        child: OutlinedButton.icon(
          key: ValueKey('agent-action-${runtime.definition.id}'),
          onPressed: widget.locked ? null : widget.onAction,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            side: BorderSide(color: scheme.outline),
          ),
          icon: Icon(
            runtime.hasUpdate
                ? Icons.upgrade_rounded
                : repair
                ? Icons.build_outlined
                : Icons.download_rounded,
            size: 18,
          ),
          label: Text(label),
        ),
      );
    } else {
      action = IconButton(
        key: ValueKey('agent-recheck-${runtime.definition.id}'),
        tooltip: 'Re-check ${runtime.definition.label}',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed:
            widget.locked || runtime.status == AgentRuntimeStatus.checking
            ? null
            : widget.onRecheck,
        icon: const Icon(Icons.refresh_rounded, size: 20),
      );
    }
    return Padding(
      key: ValueKey('agent-runtime-${runtime.definition.id}'),
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 20;
          final heading = Semantics(
            button: true,
            expanded: _expanded,
            label: '${runtime.definition.label} details',
            child: InkWell(
              key: ValueKey('agent-details-${runtime.definition.id}'),
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    AgentToolIcon(
                      tool: runtime.definition.tool,
                      color: scheme.onSurfaceVariant,
                      fallbackIcon: Icons.hub_outlined,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        runtime.definition.label,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: heading),
                  if (!stacked) ...[const SizedBox(width: 8), action],
                ],
              ),
              const SizedBox(height: 4),
              Semantics(
                liveRegion: widget.busy || widget.queued,
                child: _StatusLabel(presentation: status),
              ),
              if (_sourceLine(runtime) case final String source
                  when !_expanded) ...[
                const SizedBox(height: 4),
                Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (runtime.message case final message?) ...[
                const SizedBox(height: 6),
                Text(
                  message,
                  maxLines: _expanded ? null : 2,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (runtime.status == AgentRuntimeStatus.installed ||
                  runtime.status == AgentRuntimeStatus.updateAvailable) ...[
                const SizedBox(height: 8),
                AgentUsageSummary(
                  usage: widget.usage,
                  checking: widget.checkingUsage,
                  expanded: _expanded,
                ),
              ],
              if (stacked)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(alignment: Alignment.centerRight, child: action),
                ),
              if (_expanded) ...[
                const SizedBox(height: 12),
                if (runtime.installedVersion case final value?)
                  _DetailLine(label: 'Installed version', value: value),
                if (runtime.latestVersion case final value?)
                  _DetailLine(label: 'Latest version', value: value),
                if (runtime.detectionSource case final value?)
                  _DetailLine(label: 'Install source', value: value),
                if (runtime.executablePath case final value?)
                  _DetailLine(
                    label: 'Executable',
                    value: _displayExecutablePath(value),
                  ),
                if (runtime.hasUpdate && !runtime.managedByPackageManager)
                  const Text(
                    'Update this installation on the host, then re-check its version.',
                  ),
                if (runtime.status == AgentRuntimeStatus.notInstalled &&
                    !runtime.definition.supportsManagedInstall)
                  const Text(
                    'Install this agent on the host, then re-check its version.',
                  ),
                if (runtime.executablePath == null &&
                    runtime.installedVersion == null &&
                    runtime.latestVersion == null)
                  const Text('No installation details detected yet.'),
              ],
              if (widget.busy &&
                  widget.actionOutput != null &&
                  widget.actionOutput!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 88),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      widget.actionOutput!.trim(),
                      style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
        ),
      ],
    ),
  );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.presentation});

  final _StatusPresentation presentation;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(presentation.icon, size: 14, color: presentation.color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          presentation.label,
          style: FluttyTheme.monoStyle.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not refresh agents. $message',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _StatusPresentation {
  const _StatusPresentation(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

_StatusPresentation _statusPresentation(
  AgentRuntimeInfo runtime,
  ColorScheme scheme,
) => switch (runtime.status) {
  AgentRuntimeStatus.checking => _StatusPresentation(
    'Checking…',
    Icons.sync_rounded,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.installed => _StatusPresentation(
    runtime.installedVersion == null
        ? 'Installed'
        : 'Installed v${runtime.installedVersion}',
    Icons.check_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.updateAvailable => _StatusPresentation(
    'Update v${runtime.installedVersion ?? '?'} → v${runtime.latestVersion ?? '?'}',
    Icons.upgrade_rounded,
    scheme.onSurface,
  ),
  AgentRuntimeStatus.notInstalled => _StatusPresentation(
    'Not installed${runtime.latestVersion == null ? '' : ' · latest v${runtime.latestVersion}'}',
    Icons.remove_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.needsRepair => _StatusPresentation(
    'Needs repair',
    Icons.build_circle_outlined,
    scheme.error,
  ),
  AgentRuntimeStatus.unavailable => _StatusPresentation(
    'Unavailable',
    Icons.block_outlined,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.failed => _StatusPresentation(
    'Check failed',
    Icons.error_outline,
    scheme.error,
  ),
};

String? _sourceLine(AgentRuntimeInfo runtime) {
  final path = runtime.executablePath;
  if (path == null) return null;
  final source = runtime.detectionSource;
  final displayPath = _displayExecutablePath(path);
  return source == null ? displayPath : '$source · $displayPath';
}

String _displayExecutablePath(String path) =>
    _redactStoreScreenshotIdentities ? path.split(RegExp(r'[/\\]')).last : path;
